#!/usr/bin/env bash
#
# Recompute every *_SHA256 in versions.env for the versions it currently pins.
# Run this after changing a *_VERSION by hand.
#
# It downloads through exactly the same tarball_url() the build uses, so the
# checksum can never end up describing a different file than the one fetched.
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/versions.env"
. "$ROOT/tools/upstream.sh"

DL=$ROOT/build/dl
mkdir -p "$DL"

for p in $PACKAGES; do
    url=$(tarball_url "$p")
    file=$(tarball_file "$p")
    var=$(sha_var "$p")
    old=${!var:-}

    if [ ! -f "$DL/$file" ]; then
        echo "fetching $file"
        curl -fL --retry 3 --max-time 900 -o "$DL/$file.part" "$url"
        mv -f "$DL/$file.part" "$DL/$file"
    fi

    new=$(sha256sum <"$DL/$file" | cut -d' ' -f1)
    if [ "$new" = "$old" ]; then
        printf '%-12s unchanged\n' "$p"
    else
        printf '%-12s %s\n' "$p" "$new"
        sed -i "s|^$var=.*|$var=$new|" "$ROOT/versions.env"
    fi
done
