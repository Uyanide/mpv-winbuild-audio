#!/usr/bin/env bash
#
# Compare versions.env against the newest upstream release of every component.
#
#   ./tools/check-upstream.sh            report only
#   ./tools/check-upstream.sh --update   rewrite versions.env to the newest versions
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=versions.env
. "$ROOT/versions.env"
# shellcheck source=tools/upstream.sh
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

# vulkan-headers follows libplacebo, so resolve it after any libplacebo bump.
# shellcheck source=versions.env
[ "$update" = 1 ] && . "$ROOT/versions.env"
compare_one vulkan-headers

if [ "$update" = 1 ] && [ "$changed" = 1 ]; then
    echo
    echo "versions.env updated; refreshing checksums"
    "$ROOT/tools/refresh-sums.sh"
fi

exit 0
