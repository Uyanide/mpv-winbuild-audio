#!/usr/bin/env bash
#
# Run anything from this repo inside the same Ubuntu 24.04 image CI uses.
# Nothing (mingw-w64, meson, wine, ...) has to be installed on the host.
#
#   ./dev.sh                     interactive shell in the build container
#   ./dev.sh ./build.sh          full cross build
#   ./dev.sh ./build.sh ffmpeg   rebuild one package
#   ./dev.sh ./verify/verify.sh  static assertions + wine smoke test
#
#   REBUILD=1 ./dev.sh ...       force a rebuild of the container image
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
IMAGE=${IMAGE:-mpv-winbuild-audio:ubuntu-24.04}

if [ "${REBUILD:-0}" = 1 ] || ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    docker build -t "$IMAGE" "$ROOT/docker"
fi

# HOME lives under build/ so wine's prefix and ccache survive between runs and
# stay out of the source tree. uid 1000 is the `ubuntu` account in the image, so
# the container has a real passwd entry and files land back owned by the host user.
mkdir -p "$ROOT/build/home" "$ROOT/build/ccache"

tty_flags=(-i)
[ -t 0 ] && tty_flags=(-i -t)

exec docker run --rm "${tty_flags[@]}" \
    --user "$(id -u):$(id -g)" \
    -v "$ROOT:/work" -w /work \
    -e HOME=/work/build/home \
    -e CCACHE_DIR=/work/build/ccache \
    -e WINEPREFIX=/work/build/home/.wine \
    -e WINEDEBUG=fixme-all \
    -e JOBS="${JOBS:-$(nproc)}" \
    "$IMAGE" \
    "${@:-bash}"
