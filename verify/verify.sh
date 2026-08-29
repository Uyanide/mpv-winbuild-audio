#!/usr/bin/env bash
#
# Assert that the produced libmpv-2.dll is the thing we meant to produce.
#
# This file is the reason the repository exists. The Vulkan dependency that broke
# downstream CI was not a build failure -- it was a perfectly green build whose
# output could not be loaded on a machine without a GPU driver. Nothing but an
# explicit check on the artifact catches that class of bug.
#
#   ./verify/verify.sh                 verify dist/<latest>/libmpv-2.dll
#   ./verify/verify.sh path/to/dll     verify a specific DLL
#   SKIP_SMOKE=1 ./verify/verify.sh    static assertions only, no wine
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=versions.env
. "$ROOT/versions.env"

TARGET=x86_64-w64-mingw32
BUILD=${BUILD_DIR:-$ROOT/build}
DIST=${DIST_DIR:-$ROOT/dist}
OBJDUMP=$TARGET-objdump
MAX_SIZE_MB=${MAX_SIZE_MB:-25}

# fixme-all, not -all: the fixme spam goes away but err:module:import_dll stays,
# and that line is the whole point -- it names the DLL that could not be loaded.
export WINEDEBUG=${WINEDEBUG:-fixme-all}
export WINEPREFIX=${WINEPREFIX:-$BUILD/wineprefix}

PKG=$DIST/libmpv-audio-x86_64-v$MPV_VERSION-$BUILD_REV
DLL=${1:-$PKG/libmpv-2.dll}

pass=0 fail=0
ok()   { printf '  \033[32mok\033[0m   %s\n' "$*"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; fail=$((fail+1)); }
head_() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

[ -f "$DLL" ] || { echo "no DLL at $DLL -- run ./build.sh first" >&2; exit 1; }

# ------------------------------------------------------------ import table ---

# Dumped once into a variable on purpose: `objdump | grep -q` would SIGPIPE
# objdump the moment grep matches, and with `set -o pipefail` that turns a found
# match into a failed assertion -- a false negative on the checks that matter most.
DUMP=$($OBJDUMP -p "$DLL")

head_ "$(basename "$DLL") -- import table"
IMPORTS=$(sed -n 's/^[[:space:]]*DLL Name:[[:space:]]*//p' <<<"$DUMP" | tr '[:upper:]' '[:lower:]' | sort -u)
sed 's/^/     /' <<<"$IMPORTS"

# vulkan-1.dll is the original bug. The runtime DLLs are what Ubuntu's posix-threads
# mingw default would have added, and libstdc++-6.dll is what a plain -lstdc++ does.
# OPENGL32/d3d11/dxgi are the other ways a driver could sneak back in; dwrite.dll
# should never appear (libass LoadLibrary's it) and is listed as a cheap tripwire.
for f in vulkan-1.dll libwinpthread-1.dll libgcc_s_seh-1.dll libgcc_s_dw2-1.dll \
         libstdc++-6.dll opengl32.dll d3d11.dll d3d9.dll dxgi.dll dwrite.dll \
         libssp-0.dll libatomic-1.dll; do
    if grep -qxF "$f" <<<"$IMPORTS"; then
        bad "imports $f"
    else
        ok "does not import $f"
    fi
done

for r in kernel32.dll ws2_32.dll; do
    if grep -qxF "$r" <<<"$IMPORTS"; then ok "imports $r"; else bad "does not import $r"; fi
done

# A delay-imported vulkan-1.dll would pass every check above and still be a
# regression, so the directory has to stay empty outright.
head_ "delay imports"
if grep -q 'Delay Import Tables' <<<"$DUMP"; then
    bad "delay import directory is not empty:"
    sed -n '/Delay Import Tables/,$p' <<<"$DUMP" | sed -n 's/^[[:space:]]*DLL Name:/     /p'
else
    ok "delay import directory is empty"
fi

# ----------------------------------------------------------------- exports ---

head_ "exports"
EXPORTS=$(sed -n '/\[Ordinal\/Name Pointer\] Table/,$p' <<<"$DUMP" | sed -n 's/^[[:space:]]*\[[[:space:]]*[0-9]*\][[:space:]]*//p' | sort -u)
for s in mpv_client_api_version mpv_create mpv_initialize mpv_command \
         mpv_set_option_string mpv_set_property mpv_get_property \
         mpv_wait_event mpv_terminate_destroy mpv_error_string mpv_free; do
    if grep -qxF "$s" <<<"$EXPORTS"; then ok "exports $s"; else bad "does not export $s"; fi
done
ok "$(wc -l <<<"$EXPORTS") exported symbols total"

# -------------------------------------------------------------------- shape ---

head_ "binary shape"
fmt=$($OBJDUMP -f "$DLL" | sed -n 's/.*file format //p')
if [ "$fmt" = pei-x86-64 ]; then ok "file format $fmt"
else bad "file format is $fmt, expected pei-x86-64"; fi

bytes=$(stat -c %s "$DLL")
mb=$((bytes / 1024 / 1024))
if [ "$bytes" -lt $((MAX_SIZE_MB * 1024 * 1024)) ]; then
    ok "size ${mb}MB (limit ${MAX_SIZE_MB}MB)"
else
    bad "size ${mb}MB exceeds ${MAX_SIZE_MB}MB -- a whole-FFmpeg build looks exactly like this"
fi

# ------------------------------------------------------- ffmpeg components ---
#
# The wine matrix below can only test formats the host ffmpeg can encode, and it
# cannot encode APE at all. Reading the decoder list straight out of the FFmpeg
# build tree covers the rest, and catches a whitelist typo in seconds rather than
# after a full mpv rebuild.

# FFmpeg keeps build flags in config.h and per-component defines in
# config_components.h; both are needed here.
FFSRC=$BUILD/src/ffmpeg-$FFMPEG_VERSION
FFCONF=$FFSRC/config.h
FFCOMP=$FFSRC/config_components.h
[ -f "$FFCONF" ] && [ -f "$FFCOMP" ] || FFCONF="" 

head_ "ffmpeg components"
if [ -z "$FFCONF" ]; then
    echo "  (skipped: no FFmpeg config.h in $BUILD/src -- built elsewhere?)"
else
    ffdef() {   # <macro> <expected value>
        if grep -qxh "#define $1 $2" "$FFCONF" "$FFCOMP"; then ok "$1=$2"; else bad "$1 is not $2"; fi
    }
    ffon()  { ffdef "CONFIG_$1" 1; }
    ffoff() { ffdef "CONFIG_$1" 0; }
    for d in AAC_DECODER AC3_DECODER ALAC_DECODER APE_DECODER EAC3_DECODER FLAC_DECODER \
             MP3_DECODER MP3FLOAT_DECODER OPUS_DECODER VORBIS_DECODER WAVPACK_DECODER \
             TTA_DECODER WMAV2_DECODER WMAPRO_DECODER WMALOSSLESS_DECODER \
             PCM_S16LE_DECODER PCM_F32LE_DECODER PNG_DECODER MJPEG_DECODER; do ffon "$d"; done
    for d in AAC_DEMUXER APE_DEMUXER ASF_DEMUXER FLAC_DEMUXER HLS_DEMUXER IMAGE2_DEMUXER \
             MATROSKA_DEMUXER MOV_DEMUXER MP3_DEMUXER MPEGTS_DEMUXER OGG_DEMUXER WAV_DEMUXER; do ffon "$d"; done
    for f in ARESAMPLE_FILTER AFORMAT_FILTER ATEMPO_FILTER VOLUME_FILTER; do ffon "$f"; done

    # abuffer/abuffersink have no CONFIG_ define -- they are unconditional in
    # libavfilter. Without them mpv's lavfi bridge fails at runtime and nowhere
    # else, so assert the symbols rather than trusting that they are always there.
    avf_syms=$($TARGET-nm --defined-only "$BUILD/prefix/lib/libavfilter.a" 2>/dev/null || true)
    for sym in av_buffersrc_add_frame av_buffersink_get_frame; do
        if grep -q " T $sym\$" <<<"$avf_syms"; then ok "$sym"; else bad "$sym missing from libavfilter"; fi
    done
    for p in FILE_PROTOCOL HTTP_PROTOCOL HTTPS_PROTOCOL TLS_PROTOCOL; do ffon "$p"; done
    for b in AAC_ADTSTOASC_BSF EXTRACT_EXTRADATA_BSF; do ffon "$b"; done
    ffon SCHANNEL
    ffon ZLIB
    # Threading is a HAVE_ macro, not a CONFIG_ one. Windows-native threads are
    # what keep libwinpthread-1.dll out of the import table.
    ffdef HAVE_W32THREADS 1
    ffdef HAVE_PTHREADS 0
    # LGPL, and no GPU path at all.
    for o in GPL NONFREE VULKAN D3D11VA DXVA2 VAAPI VDPAU OPENSSL GNUTLS; do ffoff "$o"; done
fi

# ---------------------------------------------------------- wine smoke test ---

if [ "${SKIP_SMOKE:-0}" = 1 ]; then
    head_ "smoke test"
    echo "  (skipped: SKIP_SMOKE=1)"
else
    head_ "smoke test (wine)"
    if ! command -v wine >/dev/null 2>&1; then
        bad "wine is not installed -- run this through ./dev.sh"
    else
        RUN=$BUILD/smoketest
        rm -rf "$RUN"; mkdir -p "$RUN"

        inc=$(dirname "$DLL")/include
        implib=$(dirname "$DLL")/libmpv.dll.a
        [ -d "$inc" ] || inc=$BUILD/prefix/include
        [ -f "$implib" ] || implib=$BUILD/prefix/lib/libmpv.dll.a

        "$TARGET-gcc" -O2 -o "$RUN/smoke.exe" "$ROOT/verify/smoke.c" \
            -I"$inc" "$implib" -static -static-libgcc
        cp "$DLL" "$RUN/"

        # First use of a prefix prints a page of setup noise; get it out of the way.
        wineboot -i >/dev/null 2>&1 || true

        "$ROOT/verify/fixtures.sh" "$RUN" >/dev/null 2>"$RUN/fixtures.err" || {
            cat "$RUN/fixtures.err" >&2; bad "fixture generation failed"; }
        [ -s "$RUN/fixtures.err" ] && sed 's/^/  /' "$RUN/fixtures.err"

        mapfile -t files < <(cd "$RUN" && ls -1 -- *.wav *.flac *.mp3 *.ogg *.opus *.m4a *.wma *.tta *.wv *.mka 2>/dev/null)
        if [ ${#files[@]} -eq 0 ]; then
            bad "no fixtures were generated"
        else
            # Loading at all is the real assertion here: wine has no vulkan-1.dll,
            # exactly like the GitHub runner that started this.
            if ( cd "$RUN" && wine ./smoke.exe "${files[@]}" 2>&1 | sed 's/^/  /' ; exit "${PIPESTATUS[0]}" ); then
                ok "played ${#files[@]} fixtures under wine"
            else
                bad "wine smoke test failed"
            fi
        fi
    fi
fi

# ------------------------------------------------------------------ verdict ---

printf '\n\033[1m%d passed, %d failed\033[0m\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
