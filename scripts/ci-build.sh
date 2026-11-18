#!/bin/bash
# Kleinia CI build. Runs natively on the build runner (rootful podman,
# bluebuild, image-builder, QEMU straight from the host toolchain).
#
# One subcommand per workflow step. Each step logs to its own file, ends
# with an explicit status line (STEP OK / STEP FAILED / STEP SKIPPED) and
# writes its facts to /var/tmp/kleinia-ci/step-<step>.txt for the Report
# step. External components come from artifacts.yml (manifest); see the
# "artifacts" step.
#
#   prepare      self-heal the store, resolve the build proxy     no secrets
#   artifacts    pull + verify + alias the manifest images        no secrets
#   build        bluebuild image from recipe.yml                  no secrets
#   push         push :dev to the registry                        KLN_REGISTRY_* / github.token
#   sign         cosign sign + verify :dev by digest              KLN_COSIGN_* (or 1Password)
#   iso-build    generic-ISO + unsigned SHA256SUMS                no secrets
#   iso-sign     GPG-signed SHA256SUMS + public keys              OP_SERVICE_ACCOUNT_TOKEN
#   iso-archive  copy the release set to ISO_LOCAL_DIR            no secrets
#   iso-promote  promote a local ISO to R2 (dl.kleinia.io)        OP token + R2_* (release env)
#
# Environment:
#   KLN_ARTIFACT_REGISTRY  pull source for manifest images (default ghcr.io/kleinia-os)
#   KLN_REGISTRY           push target (default ghcr.io/$GITHUB_REPOSITORY_OWNER;
#                          a repo variable points it at the internal registry)
#   KLN_REGISTRY_USER / KLN_REGISTRY_PASSWORD
#                          push credentials; default on ghcr.io is the workflow
#                          GITHUB_TOKEN (forks push to their own namespace)
#   KLN_COSIGN_KEY / KLN_COSIGN_PASSWORD (+ KLN_COSIGN_PUB)
#                          cosign key material; unset -> 1Password -> step SKIPPED
#   KLN_REQUIRE_SIGN       "true" turns a skipped sign into a failure
#   ISO_LOCAL_DIR          local ISO archive (iso-archive target, iso-promote
#                          source); unset -> archive SKIPPED
#   ISO_PAYLOAD_REF        public payload ref embedded in the ISO
#   PROMOTE_*              release metadata for iso-promote (RUN, VERSION,
#                          CODENAME, SLUG, CHANNEL, BASE, IMAGE)
#   R2_ENDPOINT / R2_BUCKET / R2_ACCESS_KEY_ID / R2_SECRET_ACCESS_KEY
#                          R2 (S3 API) config — promote only; CI never touches R2
#   R2_PUBLIC_BASE_URL     public base (default https://dl.kleinia.io), verified
#                          over HTTPS after upload
#   KLN_WORK / KLN_CACHE / TOOLS, proxy vars
set -euo pipefail
MODE="${1:-}"
OUT=/var/tmp/kleinia-ci
GITHUB_RUN_ID="${GITHUB_RUN_ID:-0}"
LOG="$OUT/logs/${MODE}-$GITHUB_RUN_ID.log"
mkdir -p "$OUT/logs"
exec > >(tee "$LOG") 2>&1
ts() { echo "[$(date -Is)] $*"; }
ts "=== $MODE (run=$GITHUB_RUN_ID host=$(hostname) user=$(id -un)) ==="

# mirror lowercase proxy vars to uppercase for Go-based tools (op, cosign)
export HTTP_PROXY="${HTTP_PROXY:-${http_proxy:-}}" HTTPS_PROXY="${HTTPS_PROXY:-${https_proxy:-}}" NO_PROXY="${NO_PROXY:-${no_proxy:-}}"

REG="${KLN_REGISTRY:-ghcr.io/${GITHUB_REPOSITORY_OWNER:-kleinia-os}}"
ART_REG="${KLN_ARTIFACT_REGISTRY:-ghcr.io/kleinia-os}"
IMG="kleinia"
CHANNEL_TAG="dev"
ISO_PAYLOAD_REF="${ISO_PAYLOAD_REF:-ghcr.io/kleinia-os/kleinia:testing}"
RELEASE_DIR="${RELEASE_DIR:-/srv/kleinia-ci/out}"
GPG_FPR="665F21AB4C310F7E24421224662D88E6EFACD4B0"
VAULT="KleiniaOS"
OP_VERSION="v2.41.1"
OP_ZIP_SHA256="e52476700cba9202ac7469bdfb2648ecdbf3438ac85822010f77230139e74966"
COSIGN_VERSION="v3.1.4"
COSIGN_SHA256="424e2c97d0b45fd7a6b608a87f090f35633f4c23ece5f092d48bba11aaf4bbfa"

registry_opts() { # registry_opts <host> -> --tls-verify=false unless ghcr.io
  case "${1%%/*}" in ghcr.io) ;; *) echo --tls-verify=false ;; esac
}

# privilege shim: the runner is root; kept for running as a normal user
S=""
[ "$(id -u)" = 0 ] || S="sudo -n"
runas() { # like $S but preserves the environment (rclone config vars)
  if [ -n "$S" ]; then sudo -n -E "$@"; else "$@"; fi
}

# every failure exits through here with an unmissable status line
trap 'rc=$?; if [ "$rc" -ne 0 ] && [ -n "$MODE" ]; then echo "::error::STEP FAILED: $MODE (rc=$rc)"; ts "STEP FAILED: $MODE"; fi' EXIT
step_ok() { ts "STEP OK: $MODE"; }

summary() { # summary <line>...  -> append facts for the Report step
  for l in "$@"; do echo "$l" >> "$OUT/step-$MODE.txt"; done
}
: > "$OUT/step-$MODE.txt" 2>/dev/null || true

# ---------------------------------------------------------------------------
tools_bootstrap() { # pinned, checksummed op + cosign into $TOOLS
  TOOLS="${TOOLS:-/var/tmp/kleinia-ci-tools}"
  mkdir -p "$TOOLS"
  if ! sha256sum -c <<<"$OP_ZIP_SHA256  $TOOLS/op.zip" >/dev/null 2>&1 || [ ! -x "$TOOLS/op" ]; then
    curl -fsSL -o "$TOOLS/op.zip" \
      "https://cache.agilebits.com/dist/1P/op2/pkg/$OP_VERSION/op_linux_amd64_$OP_VERSION.zip"
    echo "$OP_ZIP_SHA256  $TOOLS/op.zip" | sha256sum -c - || { echo "FATAL: op.zip checksum mismatch"; exit 2; }
    python3 -m zipfile -e "$TOOLS/op.zip" "$TOOLS/op-unz"
    install -m 0755 "$TOOLS/op-unz/op" "$TOOLS/op"
    rm -rf "$TOOLS/op-unz"
  fi
  if ! sha256sum -c <<<"$COSIGN_SHA256  $TOOLS/cosign" >/dev/null 2>&1; then
    curl -fsSL -o "$TOOLS/cosign" \
      "https://github.com/sigstore/cosign/releases/download/$COSIGN_VERSION/cosign-linux-amd64"
    echo "$COSIGN_SHA256  $TOOLS/cosign" | sha256sum -c - || { echo "FATAL: cosign checksum mismatch"; exit 2; }
    chmod 0755 "$TOOLS/cosign"
  fi
  # offline (no-tlog) signing config: official public config minus rekor URLs
  if [ ! -s "$TOOLS/signing-config-notlog.json" ]; then
    curl -fsSL "https://raw.githubusercontent.com/sigstore/root-signing/refs/heads/main/targets/signing_config.v0.2.json" \
      | python3 -c 'import json,sys; d=json.load(sys.stdin); d.pop("rekorTlogUrls",None); json.dump(d,open("'"$TOOLS"'/signing-config-notlog.json","w"))'
  fi
  op() { timeout 180 "$TOOLS/op" "$@"; }   # guard the known op TLS hang
  cosign() { "$TOOLS/cosign" "$@"; }
  ts "tools ready: op $OP_VERSION, cosign $COSIGN_VERSION"
}

# tmpfs key staging + guaranteed cleanup
KEYS=""
cleanup() {
  if [ -n "$KEYS" ]; then shred -u "$KEYS"/* 2>/dev/null || true; rm -rf "$KEYS"; fi
  [ -n "${TOOLS:-}" ] && pkill -f "$TOOLS/op" 2>/dev/null || true
  return 0
}
keys_stage_cosign() {
  KEYS=$(mktemp -d /dev/shm/kleinia-ci-keys.XXXXXX); chmod 700 "$KEYS"
  if [ -n "${KLN_COSIGN_KEY:-}" ]; then
    printf '%s\n' "$KLN_COSIGN_KEY" > "$KEYS/cosign.key"
    printf '%s' "${KLN_COSIGN_PASSWORD:-}" > "$KEYS/cosign.pass"
    [ -s "$KEYS/cosign.pass" ] || { echo "FATAL: KLN_COSIGN_PASSWORD empty"; exit 2; }
    if [ -n "${KLN_COSIGN_PUB:-}" ]; then
      printf '%s\n' "$KLN_COSIGN_PUB" > "$KEYS/cosign.pub"
    else
      cosign public-key --key "$KEYS/cosign.key" > "$KEYS/cosign.pub"
    fi
  else
    [ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ] || { echo "FATAL: neither KLN_COSIGN_KEY nor OP_SERVICE_ACCOUNT_TOKEN provided"; exit 2; }
    export OP_SERVICE_ACCOUNT_TOKEN
    op read "op://$VAULT/cosign key passphrase/password" > "$KEYS/cosign.pass"
    op document get "cosign.key" --vault "$VAULT" --force --output "$KEYS/cosign.key"
    op document get "cosign.pub" --vault "$VAULT" --force --output "$KEYS/cosign.pub"
  fi
  [ -s "$KEYS/cosign.pass" ] || { echo "FATAL: empty cosign passphrase"; exit 2; }
  chmod 600 "$KEYS"/* 2>/dev/null || true
  ts "cosign keys staged"
}
keys_stage_gpg() {
  [ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ] || { echo "FATAL: OP_SERVICE_ACCOUNT_TOKEN not provided (GPG keys are vault-only)"; exit 2; }
  export OP_SERVICE_ACCOUNT_TOKEN
  KEYS=$(mktemp -d /dev/shm/kleinia-ci-keys.XXXXXX); chmod 700 "$KEYS"
  op read "op://$VAULT/GPG Release Key passphrase/password" > "$KEYS/gpg.pass"
  op document get "gpg-subkey-secret.asc" --vault "$VAULT" --force --output "$KEYS/gpg-subkey.asc"
  op document get "gpg-public.asc"        --vault "$VAULT" --force --output "$KEYS/gpg-public.asc"
  export GNUPGHOME="$KEYS/gnupg"; mkdir -m 700 -p "$GNUPGHOME"
  gpg --batch --import "$KEYS/gpg-subkey.asc" 2>/dev/null
  gpg --list-secret-keys --with-colons | grep -q "^ssb" || { echo "FATAL: GPG subkey import failed"; exit 2; }
  chmod 600 "$KEYS"/* 2>/dev/null || true
  ts "GPG keys staged"
}

registry_creds() { # -> user / pass on stdout (env pair, or github.token on ghcr)
  if [ -n "${KLN_REGISTRY_USER:-}" ] && [ -n "${KLN_REGISTRY_PASSWORD:-}" ]; then
    printf '%s\n%s\n' "$KLN_REGISTRY_USER" "$KLN_REGISTRY_PASSWORD"
    return 0
  fi
  if [ "${REG%%/*}" = ghcr.io ] && [ -n "${GITHUB_TOKEN:-}" ]; then
    printf '%s\n%s\n' "${GITHUB_REPOSITORY_OWNER:-kleinia-os}" "$GITHUB_TOKEN"
    return 0
  fi
  return 1
}

registry_login() {
  local creds user pass
  creds=$(registry_creds) || { echo "FATAL: no registry credentials (set KLN_REGISTRY_USER/PASSWORD or GITHUB_TOKEN)"; exit 2; }
  { read -r user; read -r pass; } <<< "$creds"
  echo "$pass" | $S podman login $(registry_opts "$REG") "$REG" -u "$user" --password-stdin >/dev/null 2>&1
  unset KLN_REGISTRY_PASSWORD
  ts "logged in to $REG"
}

# Self-heal the store before building: cancelled builds leave fuse-overlayfs
# mounts behind and the next build dies on "Transport endpoint is not
# connected" (KLN-64 forensics).
store_clean_stale_mounts() {
  $S bash -c '
    grep "containers/storage" /proc/self/mountinfo 2>/dev/null \
      | grep -vE " /var/lib/containers/storage(/overlay)? $" \
      | awk "{print \$5? \$5 : \$4}" | tac \
      | while read -r m; do umount -l "$m" 2>/dev/null; done
    n=$(grep -c "containers/storage/overlay/" /proc/self/mountinfo 2>/dev/null || true)
    echo "stale store mounts remaining: ${n:-0}"'
}

manifest_list() { # artifacts.yml -> "name<TAB>full-ref<TAB>verify-key-or-empty"
  python3 - "$ARTIFACTS_FILE" <<'PY'
import re, sys
def val(s):  # strip a trailing " # comment" (YAML inline comment)
    return re.split(r"\s+#", s, maxsplit=1)[0].strip()
root, comps, cur = {}, {}, None
for raw in open(sys.argv[1]):
    line = raw.rstrip("\n"); s = line.strip()
    if not s or s.startswith("#"): continue
    if not line[0].isspace():
        k, _, v = s.partition(":"); root[k.strip()] = val(v)
    else:
        indent = len(line) - len(line.lstrip())
        if indent == 2: cur = s.rstrip(":"); comps[cur] = {}
        elif indent == 4 and cur:
            k, _, v = s.partition(":"); comps[cur][k.strip()] = val(v)
reg = root.get("registry", "ghcr.io/kleinia-os")
for name, c in comps.items():
    ref = c["image"] + ("@" + c["digest"] if c.get("digest") else ":" + c["tag"])
    print("\t".join((name, f"{reg}/{ref}", c.get("verify", ""))))
PY
}

r2_env() {
  export RCLONE_CONFIG_R2_TYPE=s3
  export RCLONE_CONFIG_R2_PROVIDER=Cloudflare
  export RCLONE_CONFIG_R2_ENDPOINT="$R2_ENDPOINT"
  export RCLONE_CONFIG_R2_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
  export RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
  export RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true
  export RCLONE_CONFIG_R2_ACL=private
}

case "$MODE" in
# ===========================================================================
prepare)
  trap cleanup EXIT
  store_clean_stale_mounts
  # a leftover :testing alt-tag conflicts with bluebuild's re-tag of it
  $S podman image rm ghcr.io/kleinia-os/kleinia:testing >/dev/null 2>&1 || true
  # RUN steps execute in podman's BRIDGE network: the proxy must be addressed
  # by the VM's own IP. Hand the rewritten values to the build step via file.
  if [ -n "${http_proxy:-}" ]; then
    HOSTIP=$(ip route get 1.1.1.1 2>/dev/null \
      | awk '{for (i=1; i<=NF; i++) if ($i=="src") {print $(i+1); exit}}')
    HOSTIP="${HOSTIP:-$(hostname -I | awk '{print $1}')}"
    P="${http_proxy//127.0.0.1/$HOSTIP}"
    NP="${no_proxy:-${NO_PROXY:-localhost,127.0.0.1}}"
    {
      echo "# generated by ci-build.sh prepare (run=$GITHUB_RUN_ID)"
      printf 'export http_proxy=%q https_proxy=%q HTTP_PROXY=%q HTTPS_PROXY=%q\n' "$P" "$P" "$P" "$P"
      printf 'export NO_PROXY=%q no_proxy=%q\n' "$NP" "$NP"
    } > "$OUT/env-build.sh"
    ts "build proxy via $HOSTIP (bridge-reachable)"
  else
    printf '# generated by ci-build.sh prepare (run=%s) — no proxy\n' "$GITHUB_RUN_ID" > "$OUT/env-build.sh"
  fi
  step_ok
  ;;

# ===========================================================================
artifacts)
  trap cleanup EXIT
  ARTIFACTS_FILE="${GITHUB_WORKSPACE:-$PWD}/artifacts.yml"
  [ -f "$ARTIFACTS_FILE" ] || { echo "FATAL: artifacts.yml not found at $ARTIFACTS_FILE"; exit 2; }
  SRCROOT="$(cd "$(dirname "$ARTIFACTS_FILE")" && pwd)"
  ART_OPTS=($(registry_opts "$ART_REG"))
  [ "$REG" != "$ART_REG" ] && ts "artifact registry: $ART_REG (push target stays $REG)"
  needs_cosign=0
  while IFS=$'\t' read -r name ref verify; do
    ts "--- $name <- $ref"
    $S podman pull "${ART_OPTS[@]}" "$ref"
    DIGEST=$($S podman image inspect --format '{{.Digest}}' "$ref")
    if [ -n "$verify" ]; then
      KEYFILE="$SRCROOT/$verify"
      [ -f "$KEYFILE" ] || { echo "FATAL: verification key missing: $KEYFILE (see keys/README.md)"; exit 2; }
      [ "$needs_cosign" = 0 ] && { tools_bootstrap; needs_cosign=1; }
      COSIGN_OPTS=(--insecure-ignore-tlog)
      [ "${ART_OPTS[0]:-}" = --tls-verify=false ] && COSIGN_OPTS+=(--allow-insecure-registry)
      cosign verify "${COSIGN_OPTS[@]}" --key "$KEYFILE" "$ref" >/dev/null \
        && ts "$name: signature verified ($DIGEST)"
    fi
    $S podman tag "$ref" "localhost/$name:pin"
    summary "$name=$ref" "${name}_digest=$DIGEST"
    ts "$name: pinned as localhost/$name:pin ($DIGEST)"
  done < <(manifest_list)
  step_ok
  ;;

# ===========================================================================
build)
  trap cleanup EXIT
  [ -f "$OUT/env-build.sh" ] && source "$OUT/env-build.sh"
  # force the podman drivers (docker's BuildKit cannot see the podman store
  # and treats localhost/... as a registry host) and restore chroot isolation
  # (the VM's podman bridge egress is broken; RUN steps need host networking)
  export BB_BUILD_DRIVER=podman BB_INSPECT_DRIVER=podman BUILDAH_ISOLATION=chroot
  SRCROOT="${GITHUB_WORKSPACE:-$PWD}"
  export BB_SCHEMA_DIR="$SRCROOT/scripts/bluebuild-schemas"
  BUILD=/var/tmp/kleinia-build
  mkdir -p "$BUILD"
  cp -a "$SRCROOT/files" "$SRCROOT/recipe.yml" "$BUILD/"
  cd "$BUILD"
  bluebuild_build() { bluebuild build -r recipe.yml; }
  if ! bluebuild_build; then
    ts "RETRY 1/1: build failed — clearing package-manager cache mounts"
    $S podman image prune --build-cache -f >/dev/null 2>&1 || true
    bluebuild_build
    ts "RETRY 1/1: SUCCEEDED"
  fi
  BUILT=$($S podman images --format '{{.Repository}}:{{.Tag}}' \
            | grep -E "(^|/)$IMG:.*latest(-[0-9]+)?_linux_amd64$" | head -1)
  [ -n "$BUILT" ] || { echo "FATAL: built image not found in store"; exit 2; }
  echo "$BUILT" > "$OUT/image-ref-$GITHUB_RUN_ID"
  summary "image_built=$BUILT"
  ts "image built: $BUILT"
  step_ok
  ;;

# ===========================================================================
push)
  trap cleanup EXIT
  registry_login
  BUILT=$(cat "$OUT/image-ref-$GITHUB_RUN_ID" 2>/dev/null || echo "localhost/$IMG:latest_linux_amd64")
  $S podman push $(registry_opts "$REG") "$BUILT" "$REG/$IMG:$CHANNEL_TAG"
  summary "image_pushed=$REG/$IMG:$CHANNEL_TAG"
  step_ok
  ;;

# ===========================================================================
sign)
  trap cleanup EXIT
  if [ -z "${KLN_COSIGN_KEY:-}" ] && [ -z "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]; then
    if [ "${KLN_REQUIRE_SIGN:-false}" = true ]; then
      echo "FATAL: KLN_REQUIRE_SIGN=true but no signing key configured"; exit 2
    fi
    ts "STEP SKIPPED: sign (no signing key configured)"
    summary "image_signed=skipped (no key)"
    exit 0
  fi
  tools_bootstrap
  keys_stage_cosign
  # registry WRITE auth is explicit: cosign does not read podman's auth.json
  CREDS=$(registry_creds) || { echo "FATAL: no registry credentials for signature upload"; exit 2; }
  { read -r RUSER; read -r RPASS; } <<< "$CREDS"
  # sign by DIGEST: a tag can be re-pointed between resolve and sign
  RPATH="${REG#*/}"
  ACCEPT='application/vnd.oci.image.manifest.v1+json,application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.v2+json,application/vnd.docker.distribution.manifest.list.v2+json'
  REG_SCHEME=https; case "${REG%%/*}" in ghcr.io) ;; *) REG_SCHEME=http ;; esac
  DIGEST=$(curl -fsSI --user "$RUSER:$RPASS" -H "Accept: $ACCEPT" \
             "$REG_SCHEME://${REG%%/*}/v2/$RPATH/$IMG/manifests/$CHANNEL_TAG" \
           | awk 'tolower($1)=="docker-content-digest:"{gsub(/\r/,"");print $2}')
  [ -n "$DIGEST" ] || { echo "FATAL: could not resolve digest for :$CHANNEL_TAG"; exit 2; }
  ts "resolved :$CHANNEL_TAG -> $DIGEST"
  export COSIGN_PASSWORD="$(cat "$KEYS/cosign.pass")"
  COSIGN_OPTS=(--allow-insecure-registry)
  [ "${REG%%/*}" = ghcr.io ] && COSIGN_OPTS=()
  cosign sign "${COSIGN_OPTS[@]}" --key "$KEYS/cosign.key" \
    --signing-config "$TOOLS/signing-config-notlog.json" \
    --registry-username "$RUSER" --registry-password "$RPASS" \
    -y "$REG/$IMG@$DIGEST"
  unset COSIGN_PASSWORD RPASS KLN_REGISTRY_PASSWORD
  cosign verify "${COSIGN_OPTS[@]}" --key "$KEYS/cosign.pub" --insecure-ignore-tlog \
    "$REG/$IMG@$DIGEST" && ts "signature verified (digest-pinned)"
  summary "image_signed=$REG/$IMG@$DIGEST"
  step_ok
  ;;

# ===========================================================================
iso-build)
  trap cleanup EXIT
  ts "--- payload image ---"
  # always pull: a stale local tag silently shipped an outdated payload
  # into the ISO (the exists-check was a network-outage guard; the registry
  # is local zot, pulling is cheap)
  $S podman pull $(registry_opts "$REG") "$REG/$IMG:$CHANNEL_TAG"
  # the ISO carries the public payload name
  $S podman tag "$REG/$IMG:$CHANNEL_TAG" "$ISO_PAYLOAD_REF"
  OUTDIR=/var/tmp/iso-ci-$GITHUB_RUN_ID
  $S rm -rf "$OUTDIR"; mkdir -p "$OUTDIR"
  build_iso() {
    $S image-builder build \
      --bootc-ref "$REG/$IMG:$CHANNEL_TAG" \
      --bootc-installer-payload-ref "$ISO_PAYLOAD_REF" \
      --bootc-default-fs ext4 \
      --output-dir "$OUTDIR" \
      generic-iso
  }
  if ! build_iso; then
    ts "RETRY 1/1: image-builder failed — retrying"
    sleep 5
    build_iso
    ts "RETRY 1/1: SUCCEEDED"
  fi
  ISO=$(ls "$OUTDIR"/*.iso)
  HASH=$(sha256sum "$ISO" | awk '{print $1}')
  $S install -d "$RELEASE_DIR"
  ISO_NAME="kleinia-testing-$(date -u +%Y%m%d-%H%M)-r$GITHUB_RUN_ID.iso"
  $S install -m 0644 "$ISO" "$RELEASE_DIR/$ISO_NAME"
  REL=/var/tmp/kleinia-rel-$GITHUB_RUN_ID; rm -rf "$REL"; mkdir -p "$REL"; cd "$REL"
  printf '%s  %s\n' "$HASH" "$ISO_NAME" > SHA256SUMS
  $S install -m 0644 SHA256SUMS "$RELEASE_DIR/SHA256SUMS-$GITHUB_RUN_ID"
  echo "$ISO_NAME" > "$OUT/iso-name-$GITHUB_RUN_ID"
  echo "$HASH"    > "$OUT/iso-hash-$GITHUB_RUN_ID"
  summary "iso_sha256=$HASH" "iso_path=$RELEASE_DIR/$ISO_NAME" "payload=$ISO_PAYLOAD_REF"
  step_ok
  ;;

# ===========================================================================
iso-sign)
  trap cleanup EXIT
  if [ -z "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]; then
    if [ "${KLN_REQUIRE_SIGN:-false}" = true ]; then
      echo "FATAL: KLN_REQUIRE_SIGN=true but no OP_SERVICE_ACCOUNT_TOKEN"; exit 2
    fi
    ts "STEP SKIPPED: iso-sign (GPG keys are vault-only; no OP token)"
    summary "sums_signed=skipped (no key)"
    exit 0
  fi
  tools_bootstrap
  keys_stage_gpg
  REL=/var/tmp/kleinia-rel-$GITHUB_RUN_ID; cd "$REL"
  gpg --batch --yes --pinentry-mode loopback \
      --passphrase "$(cat "$KEYS/gpg.pass")" \
      --local-user "$GPG_FPR" --armor --detach-sign SHA256SUMS
  $S install -m 0644 SHA256SUMS.asc "$RELEASE_DIR/SHA256SUMS-$GITHUB_RUN_ID.asc"
  $S install -m 0644 "$KEYS/gpg-public.asc" "$RELEASE_DIR/kleinia-release.pub"
  $S install -m 0644 "$KEYS/cosign.pub"     "$RELEASE_DIR/kleinia-cosign.pub" 2>/dev/null || true
  summary "sums_signed=$RELEASE_DIR/SHA256SUMS-$GITHUB_RUN_ID{,.asc}"
  step_ok
  ;;

# ===========================================================================
iso-archive)
  trap cleanup EXIT
  if [ -z "${ISO_LOCAL_DIR:-}" ]; then
    ts "STEP SKIPPED: iso-archive (ISO_LOCAL_DIR not configured)"
    summary "iso_archived=skipped (no local dir)"
    exit 0
  fi
  ISO=$(ls "$RELEASE_DIR"/kleinia-testing-*-r"$GITHUB_RUN_ID".iso 2>/dev/null | head -1)
  [ -n "$ISO" ] || { echo "FATAL: no ISO for run $GITHUB_RUN_ID in $RELEASE_DIR (did iso-build run?)"; exit 2; }
  $S install -d "$ISO_LOCAL_DIR"
  for f in "$ISO" \
           "$RELEASE_DIR/SHA256SUMS-$GITHUB_RUN_ID" \
           "$RELEASE_DIR/SHA256SUMS-$GITHUB_RUN_ID.asc" \
           "$RELEASE_DIR/kleinia-release.pub" \
           "$RELEASE_DIR/kleinia-cosign.pub"; do
    [ -f "$f" ] && $S install -m 0644 "$f" "$ISO_LOCAL_DIR/"
  done
  NAME=$(basename "$ISO")
  HASH=$(awk -v n="$NAME" '$2==n{print $1}' "$RELEASE_DIR/SHA256SUMS-$GITHUB_RUN_ID")
  {
    echo "iso=$NAME"
    echo "sha256=$HASH"
    echo "payload=$ISO_PAYLOAD_REF"
    echo "built=$(date -u +%Y-%m-%dT%H:%MZ) run=$GITHUB_RUN_ID"
  } | $S tee "$ISO_LOCAL_DIR/LATEST.txt" >/dev/null
  $S ln -sfn "$NAME"                          "$ISO_LOCAL_DIR/latest.iso"
  $S ln -sfn "SHA256SUMS-$GITHUB_RUN_ID"      "$ISO_LOCAL_DIR/latest.SHA256SUMS"
  $S ln -sfn "SHA256SUMS-$GITHUB_RUN_ID.asc"  "$ISO_LOCAL_DIR/latest.SHA256SUMS.asc"
  # keep the newest 5 sets (names sort by embedded UTC date; promote may lag
  # several builds behind); ~4G per ISO
  ls -1 "$ISO_LOCAL_DIR"/kleinia-testing-*.iso 2>/dev/null | sort | head -n -5 \
    | while read -r old; do
        rid=${old##*-r}; rid=${rid%.iso}
        $S rm -f "$old" "$ISO_LOCAL_DIR/SHA256SUMS-$rid" "$ISO_LOCAL_DIR/SHA256SUMS-$rid.asc"
        ts "pruned $(basename "$old") (keep newest 5)"
      done
  summary "iso_archived=$ISO_LOCAL_DIR/$NAME" "latest=$ISO_LOCAL_DIR/latest.iso"
  # keep the SELinux type of the archive tree: files installed here by CI do
  # not always inherit the container label (seen: var_t), which makes the
  # filebrowser container (mounted :z) return 403 on them
  $S chcon -R -t container_file_t "$ISO_LOCAL_DIR" 2>/dev/null || true
  step_ok
  ;;

# ===========================================================================
iso-promote)
  # Promote a local-archived ISO to a public release on R2 (dl.kleinia.io):
  # verify the archive -> rename to the release name -> re-sign SHA256SUMS
  # -> upload (immutable) -> verify over HTTPS -> update releases.json last
  # (the switch point). Bucket lock is applied manually by an admin
  # afterwards; CI credentials cannot modify lock rules.
  trap cleanup EXIT
  for v in R2_ENDPOINT R2_BUCKET R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY \
           PROMOTE_RUN PROMOTE_VERSION PROMOTE_CODENAME ISO_LOCAL_DIR; do
    [ -n "${!v:-}" ] || { echo "FATAL: $v not set (promote is explicit; it does not skip)"; exit 2; }
  done
  command -v rclone >/dev/null || { echo "FATAL: rclone not installed on the runner"; exit 2; }
  command -v jq >/dev/null       || { echo "FATAL: jq not installed on the runner"; exit 2; }
  PROMOTE_SLUG="${PROMOTE_SLUG:-$(echo "$PROMOTE_CODENAME" | tr '[:upper:]' '[:lower:]')}"
  PROMOTE_CHANNEL="${PROMOTE_CHANNEL:-preview}"
  PROMOTE_BASE="${PROMOTE_BASE:-Fedora 44}"
  ARCH="x86_64"
  VER="$PROMOTE_VERSION"
  ISO_NAME="kleinia-$VER-$PROMOTE_SLUG-$ARCH.iso"
  BASE_URL="${R2_PUBLIC_BASE_URL:-https://dl.kleinia.io}"
  r2_env

  ts "--- locate r$PROMOTE_RUN in the local archive ---"
  ISO=$(ls "$ISO_LOCAL_DIR"/kleinia-testing-*-r"$PROMOTE_RUN".iso 2>/dev/null | head -1)
  [ -n "$ISO" ] || { echo "FATAL: no ISO for run $PROMOTE_RUN in $ISO_LOCAL_DIR"; exit 2; }
  SUMS="$ISO_LOCAL_DIR/SHA256SUMS-$PROMOTE_RUN"; ASC="$SUMS.asc"
  [ -f "$SUMS" ] && [ -f "$ASC" ] || { echo "FATAL: archived checksums/signature missing for r$PROMOTE_RUN"; exit 2; }

  ts "--- verify the archive ---"
  tools_bootstrap
  keys_stage_gpg
  HASH=$(sha256sum "$ISO" | awk '{print $1}')
  TESTING_NAME=$(basename "$ISO")
  grep -q "^$HASH  $TESTING_NAME$" "$SUMS" || { echo "FATAL: recomputed sha256 does not match the archived SHA256SUMS"; exit 2; }
  gpg --verify "$ASC" "$SUMS" >/dev/null 2>&1 || { echo "FATAL: archived SHA256SUMS.asc fails GPG verification"; exit 2; }

  ts "--- re-sign under the release name ($ISO_NAME) ---"
  REL=/var/tmp/kleinia-promote-$GITHUB_RUN_ID; rm -rf "$REL"; mkdir -p "$REL"
  printf '%s  %s\n' "$HASH" "$ISO_NAME" > "$REL/SHA256SUMS"
  gpg --batch --yes --pinentry-mode loopback \
      --passphrase "$(cat "$KEYS/gpg.pass")" \
      --local-user "$GPG_FPR" --armor --detach-sign "$REL/SHA256SUMS"

  ts "--- upload $VER/ (immutable) ---"
  DST="r2:$R2_BUCKET/$VER"
  # version directories are immutable: first client-side gate (bucket lock is the hard one)
  if runas rclone lsf "$DST/" --max-depth 1 2>/dev/null | grep -q .; then
    echo "FATAL: $DST already exists (releases are immutable)"; exit 2
  fi
  UPFLAGS=(--s3-chunk-size 64M --s3-upload-concurrency 8
           --header-upload "Cache-Control: public, max-age=31536000, immutable")
  runas rclone copyto "$ISO" "$DST/$ISO_NAME" --immutable \
    "${UPFLAGS[@]}" --header-upload "Content-Type: application/x-iso9660-image"
  runas rclone copyto "$REL/SHA256SUMS"     "$DST/SHA256SUMS"     --immutable "${UPFLAGS[@]}"
  runas rclone copyto "$REL/SHA256SUMS.asc" "$DST/SHA256SUMS.asc" --immutable "${UPFLAGS[@]}"

  ts "--- verify over HTTPS ($BASE_URL/$VER/) ---"
  curl -fsSL "$BASE_URL/$VER/SHA256SUMS" -o "$REL/remote-SHA256SUMS"
  curl -fsSL "$BASE_URL/$VER/SHA256SUMS.asc" -o "$REL/remote-SHA256SUMS.asc"
  gpg --verify "$REL/remote-SHA256SUMS.asc" "$REL/remote-SHA256SUMS" >/dev/null 2>&1 \
    || { echo "FATAL: remote SHA256SUMS.asc fails GPG verification"; exit 2; }
  grep -q "^$HASH  $ISO_NAME$" "$REL/remote-SHA256SUMS" || { echo "FATAL: remote SHA256SUMS content mismatch"; exit 2; }
  REMOTE_HASH=$(curl -fsSL "$BASE_URL/$VER/$ISO_NAME" | sha256sum | awk '{print $1}')
  [ "$REMOTE_HASH" = "$HASH" ] || { echo "FATAL: public ISO sha256 mismatch (downloaded: $REMOTE_HASH)"; exit 2; }

  ts "--- update releases.json (switch point, written last) ---"
  runas rclone cat "r2:$R2_BUCKET/releases.json" > "$REL/releases.json" 2>/dev/null \
    || printf '{"latest": null, "releases": []}\n' > "$REL/releases.json"
  SIZE=$(stat -c %s "$ISO")
  python3 - "$REL/releases.json" "$VER" "$PROMOTE_CODENAME" "$PROMOTE_SLUG" \
      "$PROMOTE_CHANNEL" "$PROMOTE_BASE" "$PROMOTE_IMAGE" "$ISO_NAME" "$HASH" "$SIZE" \
      > "$REL/releases.new.json" <<'PY'
import datetime, json, sys
(path, ver, codename, slug, channel, base, image, iso, sha, size) = sys.argv[1:11]
doc = json.load(open(path))
entry = {
    "version": ver,
    "codename": codename,
    "slug": slug,
    "date": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d"),
    "channel": channel,
    "base": base,
    "artifacts": [{
        "arch": "x86_64",
        "kind": "iso",
        "file": f"{ver}/{iso}",
        "size": int(size),
        "sha256": sha,
        "torrent": None,
    }],
    "checksums": f"{ver}/SHA256SUMS",
    "signature": f"{ver}/SHA256SUMS.asc",
}
if image:
    entry["image"] = image
doc["releases"] = [r for r in doc.get("releases", []) if r.get("version") != ver] + [entry]
doc["latest"] = ver
json.dump(doc, sys.stdout, indent=2)
print()
PY
  jq . "$REL/releases.new.json" >/dev/null || { echo "FATAL: generated releases.json is invalid"; exit 2; }
  runas rclone copyto "$REL/releases.new.json" "r2:$R2_BUCKET/releases.json" \
    --header-upload "Cache-Control: public, max-age=60"
  summary "release_promoted=$VER ($ISO_NAME)" "source_run=$PROMOTE_RUN" \
          "sha256=$HASH" "url=$BASE_URL/$VER/$ISO_NAME" \
          "manifest=$BASE_URL/releases.json"
  ts "NEXT (manual, admin): npx wrangler@4 r2 bucket lock add $R2_BUCKET ${VER//./-} $VER/ --retention-indefinite"
  step_ok
  ;;

*) echo "usage: $0 {prepare|artifacts|build|push|sign|iso-build|iso-sign|iso-archive|iso-promote}" >&2; exit 64 ;;
esac
