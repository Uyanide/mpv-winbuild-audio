# Where every upstream tarball comes from, and how to find out what the newest
# release is. Sourced by build.sh, tools/refresh-sums.sh and tools/check-upstream.sh
# so a checksum can never be computed over a different URL than the build fetches.
#
# Expects versions.env to have been sourced already.

# tarball_file <pkg> -- name under build/dl
tarball_file() {
    case $1 in
        zlib)       echo "zlib-$ZLIB_VERSION.tar.xz" ;;
        freetype)   echo "freetype-$FREETYPE_VERSION.tar.xz" ;;
        harfbuzz)   echo "harfbuzz-$HARFBUZZ_VERSION.tar.xz" ;;
        fribidi)    echo "fribidi-$FRIBIDI_VERSION.tar.xz" ;;
        libass)     echo "libass-$LIBASS_VERSION.tar.xz" ;;
        libplacebo) echo "libplacebo-v$LIBPLACEBO_VERSION.tar.gz" ;;
        ffmpeg)     echo "ffmpeg-$FFMPEG_VERSION.tar.xz" ;;
        mpv)        echo "mpv-v$MPV_VERSION.tar.gz" ;;
        vulkan-headers) echo "vulkan-headers-$VULKAN_HEADERS_VERSION.tar.gz" ;;
        *) return 1 ;;
    esac
}

# tarball_dir <pkg> -- top-level directory inside the tarball
tarball_dir() {
    case $1 in
        zlib)       echo "zlib-$ZLIB_VERSION" ;;
        freetype)   echo "freetype-$FREETYPE_VERSION" ;;
        harfbuzz)   echo "harfbuzz-$HARFBUZZ_VERSION" ;;
        fribidi)    echo "fribidi-$FRIBIDI_VERSION" ;;
        libass)     echo "libass-$LIBASS_VERSION" ;;
        libplacebo) echo "libplacebo-$LIBPLACEBO_VERSION" ;;
        ffmpeg)     echo "ffmpeg-$FFMPEG_VERSION" ;;
        mpv)        echo "mpv-$MPV_VERSION" ;;
        vulkan-headers) echo "Vulkan-Headers-$VULKAN_HEADERS_VERSION" ;;
        *) return 1 ;;
    esac
}

# tarball_url <pkg>
tarball_url() {
    case $1 in
        zlib)       echo "https://github.com/madler/zlib/releases/download/v$ZLIB_VERSION/zlib-$ZLIB_VERSION.tar.xz" ;;
        freetype)   echo "https://download.savannah.gnu.org/releases/freetype/freetype-$FREETYPE_VERSION.tar.xz" ;;
        harfbuzz)   echo "https://github.com/harfbuzz/harfbuzz/releases/download/$HARFBUZZ_VERSION/harfbuzz-$HARFBUZZ_VERSION.tar.xz" ;;
        fribidi)    echo "https://github.com/fribidi/fribidi/releases/download/v$FRIBIDI_VERSION/fribidi-$FRIBIDI_VERSION.tar.xz" ;;
        libass)     echo "https://github.com/libass/libass/releases/download/$LIBASS_VERSION/libass-$LIBASS_VERSION.tar.xz" ;;
        # libplacebo publishes no source tarball asset; the git archive is fine because
        # the 3rdparty/ submodules it omits are only read by backends we disable.
        libplacebo) echo "https://github.com/haasn/libplacebo/archive/refs/tags/v$LIBPLACEBO_VERSION.tar.gz" ;;
        ffmpeg)     echo "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz" ;;
        mpv)        echo "https://github.com/mpv-player/mpv/archive/refs/tags/v$MPV_VERSION.tar.gz" ;;
        vulkan-headers) echo "https://github.com/KhronosGroup/Vulkan-Headers/archive/$VULKAN_HEADERS_VERSION.tar.gz" ;;
        *) return 1 ;;
    esac
}

# sha_var <pkg> -- name of the versions.env variable holding its checksum
sha_var() { printf '%s_SHA256' "$(printf '%s' "$1" | tr '[:lower:]-' '[:upper:]_')"; }
ver_var() { printf '%s_VERSION' "$(printf '%s' "$1" | tr '[:lower:]-' '[:upper:]_')"; }

_gh() {
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        curl -sfL --max-time 30 -H "Authorization: Bearer $GITHUB_TOKEN" "$1"
    else
        curl -sfL --max-time 30 "$1"
    fi
}

_gh_latest_release() {
    _gh "https://api.github.com/repos/$1/releases/latest" \
        | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1
}

# latest_version <pkg> -- newest upstream release, normalised to our numbering
latest_version() {
    case $1 in
        zlib)       _gh_latest_release madler/zlib          | sed 's/^v//' ;;
        harfbuzz)   _gh_latest_release harfbuzz/harfbuzz ;;
        fribidi)    _gh_latest_release fribidi/fribidi      | sed 's/^v//' ;;
        libass)     _gh_latest_release libass/libass ;;
        libplacebo) _gh_latest_release haasn/libplacebo     | sed 's/^v//' ;;
        mpv)        _gh_latest_release mpv-player/mpv       | sed 's/^v//' ;;
        # Savannah has no release API; the GitHub mirror tags VER-2-14-3 style.
        freetype)   _gh "https://api.github.com/repos/freetype/freetype/tags?per_page=50" \
                        | sed -n 's/.*"name": *"VER-\([0-9-]*\)".*/\1/p' \
                        | tr '-' '.' | sort -V | tail -1 ;;
        # Stable tags only: nX.Y[.Z], never nX.Y-dev.
        ffmpeg)     _gh "https://api.github.com/repos/FFmpeg/FFmpeg/tags?per_page=100" \
                        | sed -n 's/.*"name": *"n\([0-9][0-9.]*\)".*/\1/p' \
                        | grep -E '^[0-9]+\.[0-9]+(\.[0-9]+)?$' | sort -V | tail -1 ;;
        # Not a released version: whatever commit this libplacebo pins.
        vulkan-headers) _gh "https://api.github.com/repos/haasn/libplacebo/contents/3rdparty?ref=v$LIBPLACEBO_VERSION" \
                            | tr ',' '\n' | grep -A5 '"name": *"Vulkan-Headers"' \
                            | sed -n 's/.*"sha": *"\([0-9a-f]*\)".*/\1/p' | head -1 ;;
        *) return 1 ;;
    esac
}

# Build steps, in dependency order.
PACKAGES="zlib freetype harfbuzz fribidi libass libplacebo ffmpeg mpv"
# Everything pinned by checksum. vulkan-headers is not a build step of its own;
# build_libplacebo unpacks it into that tree's 3rdparty/.
# Consumed by tools/, not by this file:
# shellcheck disable=SC2034
SOURCES="$PACKAGES vulkan-headers"
