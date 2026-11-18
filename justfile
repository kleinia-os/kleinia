# Kleinia assembly repo — build entry
# `just build` = prepare + pull manifest artifacts (artifacts.yml) + bluebuild
# against recipe.yml, via scripts/ci-build.sh. Requires podman + bluebuild.

default: build

build:
    bash scripts/ci-build.sh prepare
    bash scripts/ci-build.sh artifacts
    bash scripts/ci-build.sh build
