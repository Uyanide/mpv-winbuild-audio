# mpv-winbuild-audio

An audio-only, Vulkan-free, LGPL `libmpv-2.dll` for Windows x86_64, cross-built
from Linux and published with a fixed tag and a checksum.

## Why

The prebuilt `mpv-dev-x86_64` packages everyone uses link `vulkan-1.dll` in the
**normal import table**, not as a delay import. On a machine with no GPU driver —
a CI runner, a VM, an RDP session, Windows Server, an old iGPU — the loader
rejects the process before `main()` runs. The failure is
`0xC0000135 STATUS_DLL_NOT_FOUND`, which looks like a silent crash with exit code
`-1073741515` and says nothing about Vulkan.

For a player that only ever runs `vo=null`, that dependency buys nothing. Neither
does the 120 MB of video decoders, GPU backends and shader compilers around it.

So this repository builds the smallest thing that still is libmpv:

| | shinchiro `mpv-dev` | this |
| --- | --- | --- |
| `vulkan-1.dll` import | yes | no |
| size | ~120 MB | see the release |
| licence | GPL | LGPL-2.1-or-later |
| pinned | "latest" via a SourceForge RSS feed, no checksum | tag + sha256 |
| video | full | none |

## What a release contains

```
libmpv-audio-x86_64-v<mpv>-<rev>.7z
├── libmpv-2.dll
├── libmpv.dll.a
├── include/mpv/{client.h,render.h,render_gl.h,stream_cb.h}
└── BUILDINFO.txt
```

plus `SHA256SUMS` and `BUILDINFO.txt` as separate release assets. The layout
matches the `mpv-dev` packages on purpose, so a consumer that already unpacks
those needs no change beyond the download URL.

`BUILDINFO.txt` records every upstream version and checksum, the full
configure/meson command line of every component, and the toolchain versions.

## What it deliberately cannot do

Removing things is the point, so it is worth being explicit:

- **No video.** No video decoders, no VO, no GPU backend of any kind.
- **No subtitle font resolution.** libass is built with no font provider at all
  (no fontconfig, no DirectWrite), because DirectWrite would put `dwrite.dll` in
  the import table. libass is still linked — mpv requires it unconditionally.
- **No Lua, no JavaScript, no libarchive, no libbluray, no cdda/dvd.**
- **No SMTC** (Windows media transport controls) — it needs C++/WinRT.
- **No OpenSSL or GnuTLS.** HTTPS goes through Schannel, i.e. the Windows system
  TLS stack. This is what keeps the dependency list short.
- **Audio formats are a whitelist**, not everything FFmpeg can do. See
  `build_ffmpeg` in [`build.sh`](build.sh). Adding a format means adding its
  demuxer, decoder and parser, and a fixture in [`verify/fixtures.sh`](verify/fixtures.sh).

## Using it

Download a fixed tag and check the hash — never "latest":

```powershell
$ver  = 'v0.41.0-1'
$file = "libmpv-audio-x86_64-$ver.7z"
Invoke-WebRequest "https://github.com/<owner>/mpv-winbuild-audio/releases/download/$ver/$file" -OutFile $file
if ((Get-FileHash $file -Algorithm SHA256).Hash -ne $expected) { throw 'checksum mismatch' }
```

If you are guarding against this class of regression on your own side, the
one-line check is:

```powershell
# must print nothing
(objdump -p libmpv-2.dll) -split "\r?\n" | Select-String 'vulkan-1\.dll'
```

Splitting on newlines matters: `objdump -p` on a large DLL is hundreds of
thousands of lines, and piping it to `Select-String` as one giant string from
`Out-String` echoes the whole thing back into the log.

## Building

Everything runs in an Ubuntu 24.04 container that mirrors the CI runner, so the
only host requirements are `docker` and `git`.

```sh
./dev.sh ./build.sh          # full cross build -> dist/
./dev.sh ./verify/verify.sh  # static assertions + wine smoke test
./dev.sh ./build.sh ffmpeg   # rebuild a single package
./dev.sh                     # a shell in the build container
```

`docker/packages.txt` is the single source of truth for the package list, used by
both `docker/Dockerfile` and the workflow, so the two environments cannot drift.

A cold build is roughly 25–45 minutes; ccache (persisted in `build/ccache`) makes
repeat builds much faster.

### How the pieces fit

`versions.env` pins every upstream tarball by version **and** sha256.
`tools/upstream.sh` maps a package name to its URL and is shared by `build.sh`,
`tools/refresh-sums.sh` and `tools/check-upstream.sh`, so a checksum can never
describe a different file than the build fetches.

Build order, all static, wired together only through pkg-config:

```
zlib -> freetype -> harfbuzz -> fribidi -> libass -.
                                                   +-> mpv -> libmpv-2.dll
                          libplacebo --------------'
                          ffmpeg ------------------'
```

libass, libplacebo, libswscale and their transitive dependencies cannot be
dropped: `meson.build` in mpv requires them unconditionally. They are configured
down to nothing instead.

Two entries in that graph look wrong at a glance and are not:

- **harfbuzz** is there because libass 0.17.5 removed `--disable-harfbuzz`; it is
  now a hard dependency. It is the only C++ in the tree, hence `-static-libstdc++`.
- **Vulkan headers** are unpacked into libplacebo's `3rdparty/`, because
  `src/vulkan/stubs.c` is compiled even with `-Dvulkan=disabled`. Headers only —
  nothing links against Vulkan, and `verify.sh` asserts that on the finished DLL.

## Verifying

This is the part whose absence let the Vulkan dependency ship in the first place.
A build that produces an unloadable DLL is still a green build; only an assertion
on the artifact catches it.

`verify/verify.sh` checks, in order:

1. **Import table** — `vulkan-1.dll`, `libwinpthread-1.dll`, `libgcc_s_seh-1.dll`,
   `libstdc++-6.dll`, `OPENGL32.dll`, `d3d11.dll`, `dwrite.dll` and friends must
   be absent; `KERNEL32.dll` and `WS2_32.dll` must be present.
2. **Delay imports** — the directory must be empty, so nothing sneaks back in as
   a delay-loaded dependency and passes check 1.
3. **Exports** — the `mpv_*` entry points a consumer actually calls.
4. **Shape** — `pei-x86-64`, and under 25 MB. A full FFmpeg build trips this
   immediately.
5. **FFmpeg components** — read straight out of the FFmpeg build tree's
   `config.h`. This catches a whitelist typo in seconds instead of after a full
   mpv rebuild, and covers formats the host ffmpeg cannot encode (APE).
6. **Wine smoke test** — `verify/smoke.c` is cross-compiled against the produced
   import library and plays every fixture to completion under wine. Wine has no
   `vulkan-1.dll` either, so this reproduces the original CI environment.

## Releasing

Only a human-pushed tag publishes anything.

```sh
git tag v0.41.0-1 && git push origin v0.41.0-1
```

The tag is `v<mpv version>-<BUILD_REV>`. Bump `BUILD_REV` for a rebuild that keeps
the same mpv version; reset it to 1 when `MPV_VERSION` changes.

The monthly cron does two jobs and publishes neither:

- `build` runs unconditionally, as a bit-rot check — a vanished upstream tarball
  or a toolchain change in `ubuntu-24.04` surfaces then, not months later when
  someone needs a release.
- `bump` compares `versions.env` against upstream and opens a PR.

Bumping by hand:

```sh
$EDITOR versions.env          # change a *_VERSION
./tools/refresh-sums.sh       # rewrite the matching *_SHA256
./tools/check-upstream.sh     # what else is behind?
```

## License

The build scripts in this repository are MIT ([`LICENSE`](LICENSE)).

The **produced `libmpv-2.dll` is a combined work under LGPL-2.1-or-later.** mpv
is built with `-Dgpl=false` and FFmpeg without `--enable-gpl` or
`--enable-nonfree`. The gpl-gated mpv features are `cdda`, `dvbin`, `dvda`,
`dvdnav`, `jack`, `oss-audio`, `caca`, `direct3d` and `x11` — none of which exist
on a Windows audio path, so LGPL costs nothing here.

Statically linked into that DLL:

| component | license |
| --- | --- |
| mpv (libmpv, `-Dgpl=false`) | LGPL-2.1-or-later |
| FFmpeg (no `--enable-gpl`) | LGPL-2.1-or-later |
| libplacebo | LGPL-2.1-or-later |
| fribidi | LGPL-2.1-or-later |
| libass | ISC |
| harfbuzz | MIT (Old) |
| freetype | FTL or GPL-2.0-or-later (dual) |
| zlib | Zlib |

Distributing the DLL therefore carries LGPL obligations, in particular that
recipients can relink against a modified libmpv. The import library is shipped in
every archive, `BUILDINFO.txt` names the exact sources and flags, and this
repository is the complete build recipe.
