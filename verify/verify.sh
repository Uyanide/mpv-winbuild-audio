#!/usr/bin/env bash
#
# Check the built libmpv-2.dll.
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

# keep err:module:import_dll, which names a DLL that failed to load
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

# Not piped into grep -q: SIGPIPE + pipefail would turn a match into a failure.
DUMP=$($OBJDUMP -p "$DLL")

head_ "$(basename "$DLL") -- import table"
IMPORTS=$(sed -n 's/^[[:space:]]*DLL Name:[[:space:]]*//p' <<<"$DUMP" | tr '[:upper:]' '[:lower:]' | sort -u)
sed 's/^/     /' <<<"$IMPORTS"

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

    # abuffer/abuffersink have no CONFIG_ define
    avf_syms=$($TARGET-nm --defined-only "$BUILD/prefix/lib/libavfilter.a" 2>/dev/null || true)
    for sym in av_buffersrc_add_frame av_buffersink_get_frame; do
        if grep -q " T $sym\$" <<<"$avf_syms"; then ok "$sym"; else bad "$sym missing from libavfilter"; fi
    done
    for p in FILE_PROTOCOL HTTP_PROTOCOL HTTPS_PROTOCOL TLS_PROTOCOL; do ffon "$p"; done
    for b in AAC_ADTSTOASC_BSF EXTRACT_EXTRADATA_BSF; do ffon "$b"; done
    ffon SCHANNEL
    ffon ZLIB
    ffdef HAVE_W32THREADS 1
    ffdef HAVE_PTHREADS 0
    for o in GPL NONFREE VULKAN D3D11VA DXVA2 VAAPI VDPAU OPENSSL GNUTLS; do ffoff "$o"; done
fi

# ----------------------------------------------------------------- licences ---

LIC=$(dirname "$DLL")/licenses
if [ -f "$(dirname "$DLL")/BUILDINFO.txt" ]; then
    head_ "licence texts"
    for c in mpv ffmpeg libplacebo fribidi libass harfbuzz freetype zlib \
             mingw-w64-runtime gcc-runtime; do
        if [ -n "$(find "$LIC/$c" -type f -size +0 -print -quit 2>/dev/null)" ]; then
            ok "licenses/$c"
        else
            bad "licenses/$c is missing or empty"
        fi
    done
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

        wineboot -i >/dev/null 2>&1 || true

        "$ROOT/verify/fixtures.sh" "$RUN" >/dev/null 2>"$RUN/fixtures.err" || {
            cat "$RUN/fixtures.err" >&2; bad "fixture generation failed"; }
        [ -s "$RUN/fixtures.err" ] && sed 's/^/  /' "$RUN/fixtures.err"

        mapfile -t files < <(cd "$RUN" && ls -1 -- *.wav *.flac *.mp3 *.ogg *.opus *.m4a *.wma *.tta *.wv *.mka 2>/dev/null)
        if [ ${#files[@]} -eq 0 ]; then
            bad "no fixtures were generated"
        else
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
