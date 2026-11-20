#!/usr/bin/env bash
#
# Cross-build an audio-only, Vulkan-free libmpv-2.dll for x86_64 Windows.
#
#   ./build.sh                 build everything, then package into dist/
#   ./build.sh ffmpeg mpv      rebuild just those packages
#   ./build.sh -f mpv          rebuild even though the stamp says it is done
#   ./build.sh package         re-run only the packaging step
#
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=versions.env
. "$ROOT/versions.env"
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

# Stop libplacebo's `git describe` from finding this repo and baking our tag into the DLL.
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

    # Ubuntu ships no triplet pkg-config; ours also keeps host .pc files out.
    cat >"$TOOLS/$TARGET-pkg-config" <<EOF
#!/bin/sh
PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
PKG_CONFIG_PATH=
export PKG_CONFIG_LIBDIR PKG_CONFIG_PATH
exec pkg-config "\$@"
EOF
    chmod +x "$TOOLS/$TARGET-pkg-config"

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

    export CC=$TARGET-gcc CXX=$TARGET-g++ AR=$TARGET-ar RANLIB=$TARGET-ranlib
    export STRIP=$TARGET-strip WINDRES=$TARGET-windres NM=$TARGET-nm
    # strip otherwise stamps the PE header with the current time.
    export SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-0}

    export CFLAGS="-O2 -pipe -ffunction-sections -fdata-sections"
    export CXXFLAGS="$CFLAGS"
    export LDFLAGS="-static -static-libgcc"

    command -v "$TARGET-gcc" >/dev/null || die "$TARGET-gcc not found; run this inside ./dev.sh"
}

# -------------------------------------------------------------- packages ---

build_zlib() {
    fetch_pkg zlib

    record zlib "make -f win32/Makefile.gcc PREFIX=$TARGET- libz.a"
    make -C "$S" -f win32/Makefile.gcc -j"$JOBS" PREFIX="$TARGET-" \
        CFLAGS="$CFLAGS -DNO_FSEEKO" libz.a

    install -Dm644 "$S/zlib.h"  "$PREFIX/include/zlib.h"
    install -Dm644 "$S/zconf.h" "$PREFIX/include/zconf.h"
    install -Dm644 "$S/libz.a"  "$PREFIX/lib/libz.a"

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

    # harfbuzz=no breaks the freetype<->harfbuzz cycle.
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

    # Headers only: src/vulkan/stubs.c is compiled even with -Dvulkan=disabled.
    local vhfile vhdir
    vhfile=$(tarball_file vulkan-headers); vhdir=$(tarball_dir vulkan-headers)
    fetch "$(tarball_url vulkan-headers)" "$vhfile" "$VULKAN_HEADERS_SHA256"
    rm -rf "${SRC:?}/$vhdir" "$placebo/3rdparty/Vulkan-Headers"
    tar xf "$DL/$vhfile" -C "$SRC"
    mkdir -p "$placebo/3rdparty"
    mv "$SRC/$vhdir" "$placebo/3rdparty/Vulkan-Headers"
    S=$placebo

    meson_build libplacebo "$S" \
        --default-library=static \
        -Dvulkan=disabled -Dvk-proc-addr=disabled \
        -Dopengl=disabled -Dgl-proc-addr=disabled \
        -Dd3d11=disabled \
        -Dglslang=disabled -Dshaderc=disabled \
        -Dlcms=disabled -Ddovi=disabled -Dlibdovi=disabled -Dxxhash=disabled \
        -Dunwind=disabled \
        -Ddemos=false -Dtests=false -Dbench=false -Dfuzz=false

    # libplacebo.pc omits its C++ runtime. Absolute path, because -lstdc++ picks the .dll.a.
    local pc=$PREFIX/lib/pkgconfig/libplacebo.pc libstdcxx
    libstdcxx=$("$TARGET-g++" -print-file-name=libstdc++.a)
    [ -f "$libstdcxx" ] || die "no static libstdc++.a in the toolchain ($libstdcxx)"
    grep -q 'libstdc++\.a' "$pc" || sed -i "s|^Libs: .*|& $libstdcxx|" "$pc"
    info "patched libplacebo.pc: $(grep '^Libs:' "$pc")"
}

build_ffmpeg() {
    fetch_pkg ffmpeg

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
        # cover art
        png mjpeg bmp
    )
    local parsers=(
        aac aac_latm ac3 cook dca dolby_e flac gsm mlp mpegaudio opus tak vorbis xma
        png mjpeg
    )
    # abuffer/abuffersink are always built and have no CONFIG_ define.
    local filters=(
        aformat aresample anull atrim asetpts asettb aselect
        atempo volume pan channelmap channelsplit join amerge amix adelay
        dynaudnorm loudnorm acompressor alimiter equalizer bass treble
        highpass lowpass bandpass firequalizer superequalizer silencedetect astats
        anullsrc aevalsrc sine
        null format scale
    )
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
        --disable-avdevice

        --disable-encoders --disable-muxers --disable-devices --disable-hwaccels

        --disable-vaapi --disable-vdpau --disable-d3d11va --disable-d3d12va --disable-dxva2
        --disable-nvdec --disable-nvenc --disable-cuda-llvm --disable-amf
        --disable-mediafoundation --disable-vulkan

        --enable-w32threads --enable-schannel --enable-network

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

    # configure silently ignores unknown component names.
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

    # Same layout and names as shinchiro's mpv-dev archives.
    local implib=$PREFIX/lib/libmpv.dll.a
    [ -f "$implib" ] || implib=$(find "$PREFIX/lib" -name 'libmpv*.dll.a' -print -quit)
    [ -n "$implib" ] && [ -f "$implib" ] || die "no libmpv import library found under $PREFIX/lib"
    install -Dm644 "$implib" "$out/libmpv.dll.a"

    local h
    for h in client.h render.h render_gl.h stream_cb.h; do
        install -Dm644 "$PREFIX/include/mpv/$h" "$out/include/mpv/$h"
    done

    install_licenses "$out/licenses"
    write_buildinfo "$out/libmpv-2.dll" >"$out/BUILDINFO.txt"

    local sevenz; sevenz=$(command -v 7z || command -v 7zz) || die "no 7z/7zz on PATH"
    ( cd "$DIST" && rm -f "$name.7z" \
        && "$sevenz" a -mx=9 -mtm=off -mtc=off -mta=off -bso0 -bsp0 "$name.7z" "$name" >/dev/null )
    ( cd "$DIST" && sha256sum "$name.7z" >SHA256SUMS && cp "$name/BUILDINFO.txt" . )

    log "packaged"
    ls -l "$DIST/$name.7z"
    cat "$DIST/SHA256SUMS"
}

# install_licenses <dir> -- licence texts of everything linked into the DLL
install_licenses() {
    local out=$1 e pkg f src
    # GPL texts left out on purpose: nothing here is built under them.
    for e in \
        mpv:LICENSE.LGPL mpv:Copyright \
        ffmpeg:COPYING.LGPLv2.1 ffmpeg:LICENSE.md \
        libplacebo:LICENSE \
        fribidi:COPYING \
        libass:COPYING \
        harfbuzz:COPYING \
        freetype:LICENSE.TXT freetype:docs/FTL.TXT \
        zlib:LICENSE
    do
        pkg=${e%%:*} f=${e#*:}
        src=$SRC/$(tarball_dir "$pkg")/$f
        [ -s "$src" ] || die "licence file missing: $src (rebuild $pkg, or upstream moved it)"
        install -Dm644 "$src" "$out/$pkg/${f##*/}"
    done

    # Statically linked toolchain runtimes.
    for e in \
        mingw-w64-runtime:mingw-w64-x86-64-dev \
        gcc-runtime:gcc-mingw-w64-x86-64-win32
    do
        src=/usr/share/doc/${e#*:}/copyright
        [ -s "$src" ] || die "toolchain licence file missing: $src (package through ./dev.sh)"
        install -Dm644 "$src" "$out/${e%%:*}/copyright"
    done
}

write_buildinfo() {
    local dll=$1 origin commit cdate
    origin=$(git -C "$ROOT" config --get remote.origin.url 2>/dev/null) || origin=
    commit=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null) || commit=
    # Commit date, not build time, to keep the archive reproducible.
    cdate=$(git -C "$ROOT" log -1 --format=%cI 2>/dev/null) || cdate=

    cat <<EOF
libmpv-audio for Windows x86_64 -- audio-only, Vulkan-free, LGPL-2.1-or-later

recipe    ${origin:-(no git remote configured)}
commit    ${commit:-(not a git checkout)}
dated     ${cdate:-(unknown)}
dll       $(stat -c %s "$dll") bytes, sha256 $(sha256sum <"$dll" | cut -d' ' -f1)
licences  licenses/<component>/ inside the archive

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
