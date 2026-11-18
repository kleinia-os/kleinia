# Signing public keys

Verification keys referenced by `artifacts.yml` (`verify:` field).

`kleinia-cosign.pub` — release signing key, export once from the KleiniaOS
vault and commit:

    op document get "cosign.pub" --vault KleiniaOS --force --output keys/kleinia-cosign.pub
