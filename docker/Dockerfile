# Mirrors the GitHub Actions runner so a local build and a CI build are the same build.
FROM ubuntu:24.04

COPY packages.txt /tmp/packages.txt

RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      $(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' /tmp/packages.txt) \
 && rm -rf /var/lib/apt/lists/*

# Ubuntu defaults the mingw-w64 compilers to posix threads, which drags
# libwinpthread-1.dll and libgcc_s_seh-1.dll into everything they link.
# The win32-threads variant plus -static in the cross file is the belt and braces;
# verify/verify.sh is the third check that it actually worked.
RUN update-alternatives --set x86_64-w64-mingw32-gcc /usr/bin/x86_64-w64-mingw32-gcc-win32 \
 && update-alternatives --set x86_64-w64-mingw32-g++ /usr/bin/x86_64-w64-mingw32-g++-win32

# Keep err: lines (they name a DLL that failed to load); drop the fixme: spam.
ENV WINEDEBUG=fixme-all
