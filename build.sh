#!/usr/bin/env bash
#
# Cross-build an audio-only, Vulkan-free libmpv-2.dll for x86_64 Windows.
#
#   ./build.sh                 build everything, then package into dist/
#   ./build.sh ffmpeg mpv      rebuild just those packages
#   ./build.sh -f mpv          rebuild even though the stamp says it is done
#   ./build.sh package         re-run only the packaging step
#
# Every package installs static libs into build/prefix and is wired to the next
# one purely through pkg-config; nothing from the host prefix can leak in.
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=versions.env
. "$ROOT/versions.env"
# tarball_url/tarball_file/tarball_dir live here so that tools/refresh-sums.sh
# can never compute a checksum over a different URL than this script fetches.
# shellcheck source=tools/upstream.sh
. "$ROOT/tools/upstream.sh"

TARGET=x86_64-w64-mingw32
BUILD=${BUILD_DIR:-$ROOT/build}
DIST=${DIST_DIR:-$ROOT/dist}
DL=$BUILD/dl
SRC=$BUILD/src
PREFIX=$BUILD/prefix
STAMP=$BUILD/stamp
TOOLS=$BUILD/tools
ARGS=$BUILD/args
JOBS=${JOBS:-$(nproc)}

# Sources are unpacked under $ROOT, so a `git describe` run inside one of them
# walks up and finds *this* repository. libplacebo's src/version.py does exactly
# that and bakes the answer into the DLL as "v7.360.1 (<our tag>)", which made the
# artifact depend on our tag state -- and on `--dirty`, so an uncommitted edit here
# would ship inside libmpv. A ceiling at $ROOT stops the walk; git never excludes
# the working directory itself, so write_buildinfo's own `git -C "$ROOT"` still works.
export GIT_CEILING_DIRECTORIES=$ROOT

# ---------------------------------------------------------------- helpers ---

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\n\033[1;31m!!! %s\033[0m\n' "$*" >&2; exit 1; }

# fetch <url> <filename> <sha256>
fetch() {
    local url=$1 f=$DL/$2 want=$3 got
    if [ -f "$f" ]; then
        got=$(sha256sum <"$f" | cut -d' ' -f1)
        [ "$got" = "$want" ] && { info "cached $2"; return; }
        info "checksum changed, refetching $2"
    fi
    info "fetch $url"
    curl -fL --no-progress-meter --retry 3 --retry-delay 2 --max-time 900 -o "$f.part" "$url"
    got=$(sha256sum <"$f.part" | cut -d' ' -f1)
    [ "$got" = "$want" ] || die "sha256 mismatch for $2
  expected $want
  actual   $got"
    mv -f "$f.part" "$f"
}

# unpack <filename> <expected-top-level-dir>   -> sets $S
unpack() {
    S=$SRC/$2
    rm -rf "$S"
    mkdir -p "$SRC"
    tar xf "$DL/$1" -C "$SRC"
    [ -d "$S" ] || die "$1 did not unpack to $2"
}

# fetch_pkg <pkg> -- checksum-verified download and unpack; sets $S
fetch_pkg() {
    local sv; sv=$(sha_var "$1")
    fetch "$(tarball_url "$1")" "$(tarball_file "$1")" "${!sv}"
    unpack "$(tarball_file "$1")" "$(tarball_dir "$1")"
}

# record <name> <argv...> — kept verbatim for BUILDINFO.txt
record() {
    local name=$1; shift
    mkdir -p "$ARGS"
    printf '%s\n' "$@" >"$ARGS/$name.txt"
}

# check_components <SUFFIX> <names...> -- appends unknown ones to $missing
check_components() {
    local suffix=$1 n up; shift
    for n in "$@"; do
        case $n in *'*'*) continue ;; esac   # globs are expanded by configure itself
        up=$(printf '%s' "$n" | tr '[:lower:]' '[:upper:]')
        grep -qx "#define CONFIG_${up}_${suffix} 1" "$S/config_components.h" \
            || missing+=("$n ($suffix)")
    done
}

# meson_build <name> <srcdir> <argv...>
meson_build() {
    local name=$1 src=$2; shift 2
    local b=$BUILD/meson-$name
    rm -rf "$b"
    record "$name" "meson setup --cross-file cross/mingw64.ini --prefix=<prefix> --buildtype=release --wrap-mode=nodownload $*"
    meson setup "$b" "$src" \
        --cross-file "$ROOT/cross/mingw64.ini" \
        --prefix="$PREFIX" \
        --buildtype=release \
        --wrap-mode=nodownload \
        "$@"
    meson compile -C "$b" -j "$JOBS"
    meson install -C "$b" --no-rebuild
}

# ------------------------------------------------------------- toolchain ---

setup_toolchain() {
    mkdir -p "$DL" "$SRC" "$PREFIX/lib/pkgconfig" "$PREFIX/include" "$STAMP" "$TOOLS" "$ARGS"

    # Ubuntu's mingw-w64 ships no x86_64-w64-mingw32-pkg-config. Supplying our own
    # is not just convenience: PKG_CONFIG_LIBDIR pinned to our prefix is what makes
    # it impossible for a host .pc file to be picked up by a cross build.
    cat >"$TOOLS/$TARGET-pkg-config" <<EOF
#!/bin/sh
PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
PKG_CONFIG_PATH=
export PKG_CONFIG_LIBDIR PKG_CONFIG_PATH
exec pkg-config "\$@"
EOF
    chmod +x "$TOOLS/$TARGET-pkg-config"

    # Transparent ccache shims: both meson (via the cross file) and ffmpeg's
    # configure (via --cross-prefix) find these on PATH without knowing about them.
    if command -v ccache >/dev/null 2>&1; then
        local cc; cc=$(command -v ccache)
        ln -sf "$cc" "$TOOLS/$TARGET-gcc"
        ln -sf "$cc" "$TOOLS/$TARGET-g++"
        info "ccache enabled"
    fi

    export PATH="$TOOLS:$PATH"
    export PKG_CONFIG="$TARGET-pkg-config"
    export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
    export PKG_CONFIG_PATH=

    # For the autotools packages only; meson takes all of this from the cross file.
    export CC=$TARGET-gcc CXX=$TARGET-g++ AR=$TARGET-ar RANLIB=$TARGET-ranlib
    export STRIP=$TARGET-strip WINDRES=$TARGET-windres NM=$TARGET-nm
    # binutils stamps the PE header with the current time when strip rewrites the
    # file, which is enough to change the sha256 of an otherwise identical build.
    # With this and -Wl,--no-insert-timestamp in the cross file, two builds of the
    # same versions.env produce a byte-identical DLL.
    export SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-0}

    export CFLAGS="-O2 -pipe -ffunction-sections -fdata-sections"
    export CXXFLAGS="$CFLAGS"
    export LDFLAGS="-static -static-libgcc"

    command -v "$TARGET-gcc" >/dev/null || die "$TARGET-gcc not found; run this inside ./dev.sh"
}

# -------------------------------------------------------------- packages ---

build_zlib() {
    fetch_pkg zlib

    # zlib's ./configure cannot cross-compile; win32/Makefile.gcc is the supported way.
    record zlib "make -f win32/Makefile.gcc PREFIX=$TARGET- libz.a"
    make -C "$S" -f win32/Makefile.gcc -j"$JOBS" PREFIX="$TARGET-" \
        CFLAGS="$CFLAGS -DNO_FSEEKO" libz.a

    install -Dm644 "$S/zlib.h"  "$PREFIX/include/zlib.h"
    install -Dm644 "$S/zconf.h" "$PREFIX/include/zconf.h"
    install -Dm644 "$S/libz.a"  "$PREFIX/lib/libz.a"

    # That makefile installs no .pc file, but freetype/ffmpeg/mpv all look for one.
    sed -e "s|@prefix@|$PREFIX|g" \
        -e "s|@exec_prefix@|\${prefix}|g" \
        -e "s|@libdir@|\${exec_prefix}/lib|g" \
        -e "s|@sharedlibdir@|\${libdir}|g" \
        -e "s|@includedir@|\${prefix}/include|g" \
        -e "s|@VERSION@|$ZLIB_VERSION|g" \
        "$S/zlib.pc.in" >"$PREFIX/lib/pkgconfig/zlib.pc"
}

build_freetype() {
    fetch_pkg freetype

    # harfbuzz=no breaks the freetype<->harfbuzz cycle; harfbuzz is built against
    # this freetype right after. png/brotli/bzip2 only matter for fonts we never load.
    local opts=(
        --host="$TARGET" --prefix="$PREFIX"
        --enable-static --disable-shared
        --with-zlib=yes --with-harfbuzz=no --with-brotli=no --with-png=no --with-bzip2=no
    )
    record freetype "./configure ${opts[*]}"
    ( cd "$S" && ./configure "${opts[@]}" && make -j"$JOBS" && make install )
}

build_harfbuzz() {
    fetch_pkg harfbuzz

    # Only what libass calls (hb-ft shaping) is kept. directwrite/gdi would each add
    # a system DLL import; subset/raster/vector/gpu are pure size for a shaping-only user.
    meson_build harfbuzz "$S" \
        --default-library=static \
        -Dfreetype=enabled \
        -Dglib=disabled -Dgobject=disabled -Dcairo=disabled -Dchafa=disabled \
        -Dpng=disabled -Dzlib=disabled -Dicu=disabled \
        -Dgraphite=disabled -Dgraphite2=disabled -Dfontations=disabled -Dharfrust=disabled \
        -Dgdi=disabled -Ddirectwrite=disabled -Dcoretext=disabled -Dkbts=disabled -Dwasm=disabled \
        -Draster=disabled -Dvector=disabled -Dgpu=disabled -Dgpu_demo=disabled \
        -Dsubset=disabled -Dtests=disabled -Dintrospection=disabled -Ddocs=disabled \
        -Ddoc_tests=false -Dutilities=disabled -Dbenchmark=disabled
}

build_fribidi() {
    fetch_pkg fribidi

    meson_build fribidi "$S" \
        --default-library=static \
        -Ddocs=false -Dbin=false -Dtests=false
}

build_libass() {
    fetch_pkg libass

    # No font provider at all. fontconfig is a Unix thing, and DirectWrite -- which
    # libass reaches via LoadLibraryW("Dwrite.dll"), so it is a runtime lookup rather
    # than an import -- only matters for resolving font names, which a player that
    # never renders a subtitle never does. Dropping both keeps the failure modes of a
    # minimal Windows install out of the picture entirely, and libass allows it via
    # --disable-require-system-font-provider.
    local opts=(
        --host="$TARGET" --prefix="$PREFIX"
        --enable-static --disable-shared
        --disable-fontconfig --disable-directwrite --disable-coretext
        --disable-libunibreak --disable-require-system-font-provider
    )
    record libass "./configure ${opts[*]}"
    ( cd "$S" && ./configure "${opts[@]}" && make -j"$JOBS" && make install )
}

build_libplacebo() {
    fetch_pkg libplacebo
    local placebo=$S

    # src/vulkan/stubs.c is compiled even with -Dvulkan=disabled, and libplacebo's
    # public vulkan.h includes <vulkan/vulkan.h>. Supplying the headers upstream
    # expects in 3rdparty/ is the honest fix; adding -I/usr/include to a cross build
    # would not be. Headers only: nothing links against Vulkan, and verify.sh checks
    # the finished DLL to prove no import came of it.
    local vhfile vhdir
    vhfile=$(tarball_file vulkan-headers); vhdir=$(tarball_dir vulkan-headers)
    fetch "$(tarball_url vulkan-headers)" "$vhfile" "$VULKAN_HEADERS_SHA256"
    rm -rf "${SRC:?}/$vhdir" "$placebo/3rdparty/Vulkan-Headers"
    tar xf "$DL/$vhfile" -C "$SRC"
    mkdir -p "$placebo/3rdparty"
    mv "$SRC/$vhdir" "$placebo/3rdparty/Vulkan-Headers"
    S=$placebo

    # mpv links libplacebo unconditionally, so it cannot be dropped -- but with every
    # GPU backend off it reduces to colorspace/tonemapping math that mpv never calls
    # on an audio-only path. Turning off glslang/shaderc is the single biggest size win
    # in the whole tree, and -Dvulkan=disabled here is half of why vulkan-1.dll is gone
    # (the other half is mpv's own -Dvulkan=disabled).
    #
    # The release tarball ships empty 3rdparty/ submodule dirs, and that is still fine:
    # glad and Vulkan-Headers are only read by the disabled backends, src/meson.build
    # guards fast_float behind fs.is_dir(), and the jinja/markupsafe the GLSL
    # preprocessor needs come from python3-jinja2 in docker/packages.txt.
    # So: no git clone --recursive, and every source stays sha256-pinned.
    meson_build libplacebo "$S" \
        --default-library=static \
        -Dvulkan=disabled -Dvk-proc-addr=disabled \
        -Dopengl=disabled -Dgl-proc-addr=disabled \
        -Dd3d11=disabled \
        -Dglslang=disabled -Dshaderc=disabled \
        -Dlcms=disabled -Ddovi=disabled -Dlibdovi=disabled -Dxxhash=disabled \
        -Dunwind=disabled \
        -Ddemos=false -Dtests=false -Dbench=false -Dfuzz=false

    # src/convert.cc calls std::to_chars/std::from_chars, but the installed .pc
    # declares no C++ runtime at all -- it has no Libs.private line. mpv links
    # libmpv-2.dll with the C driver, so without this the final link ends in four
    # undefined std:: symbols. Appending to Libs puts -lstdc++ right after
    # -lplacebo, which is the order static resolution needs. -static in the cross
    # file keeps it libstdc++.a, and verify.sh asserts no libstdc++-6.dll import.
    #
    # It has to be the archive's absolute path, not -lstdc++: mingw ld searches
    # libstdc++.dll.a before libstdc++.a, and -static does not change that, so
    # -lstdc++ silently produces a libstdc++-6.dll import instead.
    local pc=$PREFIX/lib/pkgconfig/libplacebo.pc libstdcxx
    libstdcxx=$("$TARGET-g++" -print-file-name=libstdc++.a)
    [ -f "$libstdcxx" ] || die "no static libstdc++.a in the toolchain ($libstdcxx)"
    grep -q 'libstdc++\.a' "$pc" || sed -i "s|^Libs: .*|& $libstdcxx|" "$pc"
    info "patched libplacebo.pc: $(grep '^Libs:' "$pc")"
}

build_ffmpeg() {
    fetch_pkg ffmpeg

    # --disable-everything plus explicit whitelists. This is the one place tied to
    # what a downstream consumer actually opens: every format it can encounter has to
    # appear below, or it fails at runtime with a perfectly green build behind it.
    # verify/ drives a wine playback matrix that fails loudly when an entry is
    # missing, which is the only reliable way to converge these lists.
    local demuxers=(
        aac ac3 aiff ape asf au caf dsf dts eac3 flac hls image2 matroska mov mp3
        mpc mpc8 mpegts ogg rm spdif tak truehd tta voc w64 wav wv xwma
        'pcm_*'
    )
    local decoders=(
        aac aac_fixed aac_latm ac3 alac ape atrac3 atrac3al atrac3p atrac3pal atrac9
        cook dca dolby_e eac3 flac gsm gsm_ms mlp mp1 mp1float mp2 mp2float mp3
        mp3adu mp3adufloat mp3float mp3on4 mp3on4float mpc7 mpc8 opus ra_144 ra_288
        ralf shorten sipr speex tak truehd tta vorbis wavpack wmalossless wmapro
        wmav1 wmav2 wmavoice
        'pcm_*' 'adpcm_*' 'dsd_*'
        # cover art embedded in tags, and standalone cover files next to the track
        png mjpeg bmp
    )
    local parsers=(
        aac aac_latm ac3 cook dca dolby_e flac gsm mlp mpegaudio opus tak vorbis xma
        png mjpeg
    )
    # abuffer/abuffersink -- what mpv's libavfilter bridge instantiates -- are NOT
    # listed: they live in libavfilter's unconditional OBJS and have no CONFIG_ define
    # at all, so naming them here would be a no-op that the cross-check below then
    # reports as missing. verify.sh asserts their symbols in libavfilter.a instead.
    local filters=(
        aformat aresample anull atrim asetpts asettb aselect
        atempo volume pan channelmap channelsplit join amerge amix adelay
        dynaudnorm loudnorm acompressor alimiter equalizer bass treble
        highpass lowpass firequalizer superequalizer silencedetect astats
        anullsrc aevalsrc sine
        null format scale
    )
    # No 'hls' protocol: HLS is a demuxer that runs over http/https. And there is no
    # 'flac_header' bitstream filter in FFmpeg -- FLAC headers are the demuxer's job.
    local protocols=(
        file http https tcp tls crypto data pipe httpproxy async cache concat
    )
    local bsfs=( aac_adtstoasc extract_extradata null )

    join() { local IFS=,; echo "$*"; }

    local opts=(
        --prefix="$PREFIX"
        --cross-prefix="$TARGET-" --arch=x86_64 --target-os=mingw32
        --enable-cross-compile --host-cc=gcc
        --pkg-config="$TARGET-pkg-config" --pkg-config-flags=--static
        --extra-cflags="$CFLAGS"

        --disable-shared --enable-static --enable-pic
        --disable-programs --disable-doc --disable-debug
        # No --disable-postproc: libpostproc was removed outright in FFmpeg 8.
        --disable-avdevice

        # LGPL: no --enable-gpl, no --enable-nonfree.
        --disable-encoders --disable-muxers --disable-devices --disable-hwaccels

        # No GPU/driver-backed path may exist; that is the entire point of this build.
        --disable-vaapi --disable-vdpau --disable-d3d11va --disable-d3d12va --disable-dxva2
        --disable-nvdec --disable-nvenc --disable-cuda-llvm --disable-amf
        --disable-mediafoundation --disable-vulkan

        # Windows-native threads and TLS: keeps libwinpthread and OpenSSL/GnuTLS out.
        --enable-w32threads --enable-schannel --enable-network

        # No host library may be picked up implicitly.
        --disable-autodetect --enable-zlib

        --disable-everything
        "--enable-demuxer=$(join "${demuxers[@]}")"
        "--enable-decoder=$(join "${decoders[@]}")"
        "--enable-parser=$(join "${parsers[@]}")"
        "--enable-filter=$(join "${filters[@]}")"
        "--enable-protocol=$(join "${protocols[@]}")"
        "--enable-bsf=$(join "${bsfs[@]}")"
    )
    record ffmpeg "./configure ${opts[*]}"
    ( cd "$S" && ./configure "${opts[@]}" )

    # FFmpeg's configure silently ignores component names it does not recognise, so a
    # typo above would drop a format and still produce a perfectly green build. Check
    # every non-glob entry actually became a component before spending the compile.
    missing=()
    check_components DEMUXER  "${demuxers[@]}"
    check_components DECODER  "${decoders[@]}"
    check_components PARSER   "${parsers[@]}"
    check_components FILTER   "${filters[@]}"
    check_components PROTOCOL "${protocols[@]}"
    check_components BSF      "${bsfs[@]}"
    [ ${#missing[@]} -eq 0 ] || die "not components in FFmpeg $FFMPEG_VERSION (typo, or renamed upstream): ${missing[*]}"

    make -C "$S" -j"$JOBS"
    make -C "$S" install
}

build_mpv() {
    fetch_pkg mpv

    # -Dvulkan=disabled is the fix this whole repository exists for.
    # -Dgpl=false costs nothing here: the only gpl-gated features are
    # cdda/dvbin/dvdnav/jack/oss-audio/caca/direct3d/x11, none on a Windows audio path.
    # -Dwin32-smtc=disabled keeps the chain free of C++/WinRT.
    # -Dbuild-date=false makes the output reproducible.
    meson_build mpv "$S" \
        --default-library=shared \
        -Dlibmpv=true -Dcplayer=false -Dtests=false -Dgpl=false -Dbuild-date=false \
        -Dvulkan=disabled -Dgl=disabled -Dplain-gl=disabled \
        -Dd3d11=disabled -Ddirect3d=disabled -Degl=disabled \
        -Degl-angle=disabled -Degl-angle-lib=disabled -Degl-angle-win32=disabled \
        -Dgl-dxinterop=disabled -Dgl-dxinterop-d3d9=disabled -Dgl-win32=disabled \
        -Dshaderc=disabled -Dspirv-cross=disabled -Dsixel=disabled -Dcaca=disabled \
        -Dd3d-hwaccel=disabled -Dd3d9-hwaccel=disabled \
        -Dcuda-hwaccel=disabled -Dcuda-interop=disabled -Dvaapi-win32=disabled \
        -Dwasapi=enabled -Dwin32-threads=enabled \
        -Dsdl2-audio=disabled -Dsdl2-video=disabled -Dsdl2-gamepad=disabled \
        -Dopenal=disabled -Djack=disabled -Dsndio=disabled \
        -Dlua=disabled -Djavascript=disabled -Dcplugins=disabled \
        -Dlibarchive=disabled -Dlibavdevice=disabled -Dlibbluray=disabled \
        -Duchardet=disabled -Drubberband=disabled -Dzimg=disabled -Djpeg=disabled \
        -Dlcms2=disabled -Dvapoursynth=disabled -Diconv=disabled \
        -Dcdda=disabled -Ddvbin=disabled -Ddvdnav=disabled -Duwp=disabled \
        -Dwin32-smtc=disabled \
        -Dmanpage-build=disabled -Dhtml-build=disabled -Dpdf-build=disabled
}

# ------------------------------------------------------------- packaging ---

do_package() {
    local name="libmpv-audio-x86_64-v$MPV_VERSION-$BUILD_REV"
    local out=$DIST/$name
    rm -rf "$out"
    mkdir -p "$out/include/mpv"

    local dll=$PREFIX/bin/libmpv-2.dll
    [ -f "$dll" ] || dll=$(find "$PREFIX" -name 'libmpv-*.dll' -print -quit)
    [ -n "$dll" ] && [ -f "$dll" ] || die "no libmpv DLL found under $PREFIX"

    install -Dm755 "$dll" "$out/libmpv-2.dll"
    "$TARGET-strip" --strip-unneeded "$out/libmpv-2.dll"

    # The archive mirrors shinchiro's mpv-dev layout so that a downstream already
    # unpacking those needs no change beyond the URL. That means the import library
    # has to keep that exact name even if meson picks another.
    local implib=$PREFIX/lib/libmpv.dll.a
    [ -f "$implib" ] || implib=$(find "$PREFIX/lib" -name 'libmpv*.dll.a' -print -quit)
    [ -n "$implib" ] && [ -f "$implib" ] || die "no libmpv import library found under $PREFIX/lib"
    install -Dm644 "$implib" "$out/libmpv.dll.a"

    local h
    for h in client.h render.h render_gl.h stream_cb.h; do
        install -Dm644 "$PREFIX/include/mpv/$h" "$out/include/mpv/$h"
    done

    write_buildinfo "$out/libmpv-2.dll" >"$out/BUILDINFO.txt"

    local sevenz; sevenz=$(command -v 7z || command -v 7zz) || die "no 7z/7zz on PATH"
    # -mtm/-mtc/-mta=off: without them the archive stores mtimes, so the DLL can be
    # byte-identical and the .7z still hash differently on every build.
    ( cd "$DIST" && rm -f "$name.7z" \
        && "$sevenz" a -mx=9 -mtm=off -mtc=off -mta=off -bso0 -bsp0 "$name.7z" "$name" >/dev/null )
    ( cd "$DIST" && sha256sum "$name.7z" >SHA256SUMS && cp "$name/BUILDINFO.txt" . )

    log "packaged"
    ls -l "$DIST/$name.7z"
    cat "$DIST/SHA256SUMS"
}

write_buildinfo() {
    local dll=$1 origin commit cdate
    # Each of these can legitimately be absent (a fresh clone with no remote, an
    # export with no .git); an empty substitution must not silently become a URL.
    origin=$(git -C "$ROOT" config --get remote.origin.url 2>/dev/null) || origin=
    commit=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null) || commit=
    # The commit date, not the build clock: this file goes inside the archive, and a
    # wall-clock timestamp here would be the one thing keeping two builds of the same
    # commit from producing a byte-identical .7z.
    cdate=$(git -C "$ROOT" log -1 --format=%cI 2>/dev/null) || cdate=

    cat <<EOF
libmpv-audio for Windows x86_64 -- audio-only, Vulkan-free, LGPL-2.1-or-later

recipe    ${origin:-(no git remote configured)}
commit    ${commit:-(not a git checkout)}
dated     ${cdate:-(unknown)}
dll       $(stat -c %s "$dll") bytes, sha256 $(sha256sum <"$dll" | cut -d' ' -f1)

=== upstream sources ===
EOF
    grep -E '^[A-Z_]+=' "$ROOT/versions.env"
    cat <<EOF

=== toolchain ===
$($TARGET-gcc --version | head -1)
$($TARGET-ld --version | head -1)
$(meson --version | sed 's/^/meson /')
$(ninja --version | sed 's/^/ninja /')
$(nasm -v 2>/dev/null | head -1)

=== configure / meson arguments ===
EOF
    local f
    for f in $PACKAGES; do
        [ -f "$ARGS/$f.txt" ] || continue
        printf -- '--- %s ---\n' "$f"
        cat "$ARGS/$f.txt"
        echo
    done
}

# ------------------------------------------------------------------ main ---

# Print the header comment block, whatever length it grows to.
usage() { awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "$0"; }

main() {
    local force=0 targets=() a
    for a in "$@"; do
        case $a in
            -f|--force) force=1 ;;
            -h|--help)  usage; exit 0 ;;
            -*)         die "unknown flag $a" ;;
            *)          targets+=("$a") ;;
        esac
    done
    [ ${#targets[@]} -eq 0 ] && read -r -a targets <<<"$PACKAGES package"

    setup_toolchain

    local t
    for t in "${targets[@]}"; do
        if [ "$t" = package ]; then
            log "package"
            do_package
            continue
        fi
        case " $PACKAGES " in *" $t "*) ;; *) die "unknown package '$t' (have: $PACKAGES package)" ;; esac
        if [ -f "$STAMP/$t" ] && [ "$force" -eq 0 ]; then
            log "$t (already built, use -f to force)"
            continue
        fi
        log "$t"
        rm -f "$STAMP/$t"
        "build_$t"
        touch "$STAMP/$t"
    done

    log "done"
}

main "$@"
