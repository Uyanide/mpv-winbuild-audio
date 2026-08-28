#!/usr/bin/env bash
#
# Generate one short sample per container/codec the Windows build has to handle,
# using the *host* ffmpeg -- never the cross-built one, or the test would just be
# checking that our build agrees with itself.
#
# Formats ffmpeg cannot encode (APE) are covered instead by the config.h assertions
# in verify.sh, which read the decoder list straight out of the FFmpeg build tree.
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
OUT=${1:-$ROOT/build/fixtures}
FF=${FFMPEG:-ffmpeg}

mkdir -p "$OUT"

# A tone rather than silence: a decoder that silently produces nothing still
# reports a codec name, but a listener-visible signal keeps the fixture honest
# if we ever add sample-value assertions.
src=(-f lavfi -i "sine=frequency=440:duration=1:sample_rate=48000" -ac 2)

gen() {
    local name=$1; shift
    if [ -f "$OUT/$name" ]; then
        echo "  cached $name"
        return
    fi
    if "$FF" -hide_banner -loglevel error -y "${src[@]}" "$@" "$OUT/$name" 2>"$OUT/$name.log"; then
        echo "  ok     $name"
        rm -f "$OUT/$name.log"
    else
        echo "  SKIP   $name (host ffmpeg cannot encode it)" >&2
        sed 's/^/         /' "$OUT/$name.log" >&2 || true
        rm -f "$OUT/$name" "$OUT/$name.log"
    fi
}

echo "generating fixtures in $OUT"
gen tone.wav  -c:a pcm_s16le
gen tone.flac -c:a flac
gen tone.mp3  -c:a libmp3lame -b:a 128k
gen tone.ogg  -c:a libvorbis  -b:a 128k
gen tone.opus -c:a libopus    -b:a 96k
gen tone.m4a  -c:a aac        -b:a 128k
gen alac.m4a  -c:a alac
gen tone.wma  -c:a wmav2      -b:a 128k
gen tone.tta  -c:a tta
gen tone.wv   -c:a wavpack
gen tone.mka  -c:a flac

# Embedded cover art: mpv opens an attached picture as a video stream even with
# vo=null, so this is the case that needs the png decoder.
#
# Two passes on purpose. Encoding audio and the cover in one command needs
# -frames:v 1 to stop the video stream, and that ends the whole output after a
# couple of audio frames -- the resulting file is 0.05s long and mpv rejects it.
# Muxing a finished PNG onto finished audio with -c copy is the reliable recipe.
if [ ! -f "$OUT/cover.mp3" ] && [ -f "$OUT/tone.mp3" ]; then
    if "$FF" -hide_banner -loglevel error -y \
            -f lavfi -i "color=c=blue:s=64x64" -frames:v 1 "$OUT/cover.png" \
       && "$FF" -hide_banner -loglevel error -y \
            -i "$OUT/tone.mp3" -i "$OUT/cover.png" \
            -map 0:a -map 1:v -c copy -id3v2_version 3 \
            -metadata:s:v title="Album cover" -disposition:v attached_pic \
            "$OUT/cover.mp3"; then
        echo "  ok     cover.mp3"
    else
        echo "  SKIP   cover.mp3" >&2
        rm -f "$OUT/cover.mp3"
    fi
    rm -f "$OUT/cover.png"
fi

echo
ls -l "$OUT"
