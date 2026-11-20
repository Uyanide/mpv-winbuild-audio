FROM ubuntu:24.04

COPY packages.txt /tmp/packages.txt

RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      $(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' /tmp/packages.txt) \
 && rm -rf /var/lib/apt/lists/*

# posix-threads default would import libwinpthread-1.dll
RUN update-alternatives --set x86_64-w64-mingw32-gcc /usr/bin/x86_64-w64-mingw32-gcc-win32 \
 && update-alternatives --set x86_64-w64-mingw32-g++ /usr/bin/x86_64-w64-mingw32-g++-win32

ENV WINEDEBUG=fixme-all
