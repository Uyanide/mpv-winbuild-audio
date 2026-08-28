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
for p in $PACKAGES; do
    vvar=$(ver_var "$p")
    cur=${!vvar}
    new=$(latest_version "$p" || true)
    if [ -z "$new" ]; then
        printf '%-12s %-12s %s\n' "$p" "$cur" "(lookup failed)"
        continue
    fi
    if [ "$cur" = "$new" ]; then
        printf '%-12s %-12s up to date\n' "$p" "$cur"
    else
        printf '%-12s %-12s -> %s\n' "$p" "$cur" "$new"
        changed=1
        if [ "$update" = 1 ]; then
            sed -i "s|^$vvar=.*|$vvar=$new|" "$ROOT/versions.env"
        fi
    fi
done

if [ "$update" = 1 ] && [ "$changed" = 1 ]; then
    echo
    echo "versions.env updated; refreshing checksums"
    "$ROOT/tools/refresh-sums.sh"
fi

exit 0
