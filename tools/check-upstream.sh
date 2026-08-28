#!/usr/bin/env bash
#
# Compare versions.env against the newest upstream release of every component.
#
#   ./tools/check-upstream.sh            report only
#   ./tools/check-upstream.sh --update   rewrite versions.env to the newest versions
#
# The monthly workflow runs this with --update and opens a PR. It deliberately does
# not release anything: a human still reviews and tags. FFmpeg major bumps in
# particular drop deprecated APIs and need a look at whether mpv has caught up.
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/versions.env"
. "$ROOT/tools/upstream.sh"

update=0
[ "${1:-}" = --update ] && update=1

changed=0

compare_one() {
    local p=$1 vvar cur new
    vvar=$(ver_var "$p")
    cur=${!vvar}
    new=$(latest_version "$p" || true)

    if [ -z "$new" ]; then
        printf '%-15s %-14s %s\n' "$p" "${cur:0:14}" "(lookup failed)"
        return
    fi
    if [ "$cur" = "$new" ]; then
        printf '%-15s %-14s up to date\n' "$p" "${cur:0:14}"
        return
    fi

    printf '%-15s %-14s -> %s\n' "$p" "${cur:0:14}" "$new"
    changed=1
    [ "$update" = 1 ] && sed -i "s|^$vvar=.*|$vvar=$new|" "$ROOT/versions.env"
}

for p in $PACKAGES; do
    compare_one "$p"
done

# vulkan-headers is not an independent release -- it tracks whatever commit the
# current libplacebo pins. So resolve it last, and re-read versions.env first so
# that a libplacebo bump made just above is the one it follows.
[ "$update" = 1 ] && . "$ROOT/versions.env"
compare_one vulkan-headers

if [ "$update" = 1 ] && [ "$changed" = 1 ]; then
    echo
    echo "versions.env updated; refreshing checksums"
    "$ROOT/tools/refresh-sums.sh"
fi

exit 0
