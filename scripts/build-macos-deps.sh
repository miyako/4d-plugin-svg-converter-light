#!/bin/bash
# Builds the static libraries the Xcode project links from a/, as universal
# (arm64 + x86_64) archives, from pinned official source releases:
#   cairo 1.12.14  -> libcairo.a     (= include/cairo/*.h, CAIRO_VERSION 1.12.14)
#   pixman 0.42.2  -> libpixman-1.a  (private to cairo; last autotools release)
#   libpng 1.6.59  -> libpng16.a     (include/libpng16 says 1.6.3, the old archive was
#                                     1.6.15; the 1.6 API/ABI is stable and png_struct
#                                     is opaque, so a current 1.6 patch release is used)
#   libjpeg 9      -> libjpeg.a      (= include/jpeglib.h, JPEG_LIB_VERSION 90, MINOR 0)
#
# cairo is configured like the committed include/cairo/cairo-features.h
# (Quartz surface + Quartz fonts, PDF/PS/SVG/script/XML surfaces, PNG) minus
# FreeType, fontconfig and GObject: on macOS the toy font API (cairo_select_font_face,
# used by libsvg-cairo for text) uses the Quartz font backend whenever it is built,
# so FreeType/fontconfig were never on the text path, and nothing uses GObject.
# That drops libfreetype, libfontconfig, libharfbuzz, libglib-2.0, libintl and
# libbz2. zlib, libxml2 and libiconv come from the SDK (libz.tbd, libxml2.tbd),
# so they are not built here.
#
# The committed headers in include/ are shared with the Windows build and are
# not modified.
#
# usage: scripts/build-macos-deps.sh [output-dir]   (default: a/)
# WORK (default build/deps) holds downloads and per-arch builds; a rerun reuses them.
# Needs: Xcode command line tools, curl, cmake, pkg-config.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/a}"
case "$OUT" in /*) ;; *) OUT="$ROOT/$OUT" ;; esac
WORK="${WORK:-$ROOT/build/deps}"
MIN="${MACOSX_DEPLOYMENT_TARGET:-11.5}"
JOBS="$(sysctl -n hw.ncpu)"
ARCHS="arm64 x86_64"
SDK="$(xcrun --sdk macosx --show-sdk-path)"

CAIRO_URL=https://cairographics.org/releases/cairo-1.12.14.tar.xz
CAIRO_SHA=96d0d1e3f9b74d2ca3469ff187c5e5f25649b1ad35cf06f4f3a83847dff4ac13
PIXMAN_URL=https://cairographics.org/releases/pixman-0.42.2.tar.gz
PIXMAN_SHA=ea1480efada2fd948bc75366f7c349e1c96d3297d09a3fe62626e38e234a625e
PNG_URL=https://github.com/pnggroup/libpng/archive/refs/tags/v1.6.59.tar.gz
PNG_SHA=2540302a1844ad2b2b501977abecfa850f265f97b78f065a712ab4074a89f5b5
JPEG_URL=https://www.ijg.org/files/jpegsrc.v9.tar.gz
JPEG_SHA=6e004d72f9108014caccf434095514c139478c72b6b1873a3e3807ea5bec5c59

# keep Homebrew headers and libraries out of the build
unset CPATH LIBRARY_PATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH PKG_CONFIG_PATH || true
export MACOSX_DEPLOYMENT_TARGET="$MIN"
command -v pkg-config >/dev/null || { echo "::error::pkg-config is required (cairo's configure)"; exit 1; }

# fail on C code that only compiled because old compilers allowed it
WERR="-Werror=implicit-function-declaration -Werror=implicit-int"

mkdir -p "$WORK/dl" "$OUT"

# fetch <url> <sha256> <file>: download with retries, verify the checksum
fetch() {
  local f="$WORK/dl/$3" i
  if [ -f "$f" ] && echo "$2  $f" | shasum -a 256 -c - >/dev/null 2>&1; then
    return 0
  fi
  for i in 1 2 3; do
    curl -fsSL --retry 3 -o "$f.tmp" "$1" && break
    [ "$i" = 3 ] && { echo "::error::download failed: $1"; return 1; }
    echo "download $1 failed, retrying"; sleep 10
  done
  echo "$2  $f.tmp" | shasum -a 256 -c - || { echo "::error::checksum mismatch: $1"; rm -f "$f.tmp"; return 1; }
  mv "$f.tmp" "$f"
}

# unpack <archive> <dest dir>: fresh extraction into dest
unpack() {
  rm -rf "${2:?}"; mkdir -p "$2"
  tar -xf "$WORK/dl/$1" -C "$2" --strip-components 1
}

host_for() { case "$1" in arm64) echo aarch64-apple-darwin ;; x86_64) echo x86_64-apple-darwin ;; esac; }

fetch "$CAIRO_URL"  "$CAIRO_SHA"  cairo-1.12.14.tar.xz
fetch "$PIXMAN_URL" "$PIXMAN_SHA" pixman-0.42.2.tar.gz
fetch "$PNG_URL"    "$PNG_SHA"    libpng-1.6.59.tar.gz
fetch "$JPEG_URL"   "$JPEG_SHA"   jpegsrc.v9.tar.gz

# libpng: CMake builds both archs in one pass. Hardware (NEON/SSE) code is
# off so one configuration serves both slices. zlib is the SDK's.
PNGP="$WORK/png-prefix"
if [ ! -f "$PNGP/lib/libpng16.a" ]; then
  echo "::group::libpng"
  unpack libpng-1.6.59.tar.gz "$WORK/libpng"
  rm -rf "$WORK/libpng-build"
  cmake -S "$WORK/libpng" -B "$WORK/libpng-build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$PNGP" \
    -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN" \
    -DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;/usr/local" \
    -DZLIB_INCLUDE_DIR="$SDK/usr/include" -DZLIB_LIBRARY="$SDK/usr/lib/libz.tbd" \
    -DCMAKE_C_FLAGS="$WERR" \
    -DPNG_SHARED=OFF -DPNG_STATIC=ON -DPNG_FRAMEWORK=OFF \
    -DPNG_TESTS=OFF -DPNG_TOOLS=OFF -DPNG_HARDWARE_OPTIMIZATIONS=OFF
  cmake --build "$WORK/libpng-build" -j "$JOBS"
  cmake --install "$WORK/libpng-build"
  echo "::endgroup::"
fi
cp "$PNGP/lib/libpng16.a" "$OUT/libpng16.a"

# autotools projects: one build per arch, then lipo (ar can't archive fat objects)
for A in $ARCHS; do
  P="$WORK/$A/prefix"
  CF="-arch $A -mmacosx-version-min=$MIN -O2 $WERR"
  LF="-arch $A -mmacosx-version-min=$MIN"
  mkdir -p "$P"

  # pixman 0.42.2 ships a 2022 config.sub/config.guess that knows
  # aarch64-apple-darwin; jpeg 9 and cairo 1.12.14 (2012/2013) get that pair.
  CFG="$WORK/$A/pixman-cfg"; unpack pixman-0.42.2.tar.gz "$CFG"

  if [ ! -f "$P/lib/libjpeg.a" ]; then
    echo "::group::libjpeg $A"
    S="$WORK/$A/jpeg"; unpack jpegsrc.v9.tar.gz "$S"
    cp "$CFG/config.sub" "$CFG/config.guess" "$S/"
    (cd "$S" && ./configure --prefix="$P" --host="$(host_for "$A")" \
        --enable-static --disable-shared \
        CC=clang CFLAGS="$CF" LDFLAGS="$LF" \
      && make -j"$JOBS" libjpeg.la && make install-libLTLIBRARIES install-includeHEADERS)
    echo "::endgroup::"
  fi

  if [ ! -f "$P/lib/libpixman-1.a" ]; then
    echo "::group::pixman $A"
    S="$WORK/$A/pixman"; unpack pixman-0.42.2.tar.gz "$S"
    # the A64 NEON assembly is GNU-as syntax that Apple's assembler rejects;
    # the 32-bit ARM paths don't apply to arm64. x86_64 keeps SSE2/SSSE3.
    (cd "$S" && ./configure --prefix="$P" --host="$(host_for "$A")" \
        --enable-static --disable-shared --disable-openmp \
        --disable-gtk --disable-libpng --disable-arm-a64-neon \
        --disable-arm-simd --disable-arm-neon --disable-arm-iwmmxt \
        CC=clang CFLAGS="$CF" LDFLAGS="$LF" \
      && make -C pixman -j"$JOBS" && make -C pixman install && make install-pkgconfigDATA)
    echo "::endgroup::"
  fi

  if [ ! -f "$P/lib/libcairo.a" ]; then
    echo "::group::cairo $A"
    S="$WORK/$A/cairo"; unpack cairo-1.12.14.tar.xz "$S"
    cp "$CFG/config.sub" "$CFG/config.guess" "$S/build/"
    # only our pixman and libpng (and the SDK's zlib, which libpng16.pc
    # requires) are visible to pkg-config
    mkdir -p "$WORK/sdk-pc"
    printf 'Name: zlib\nDescription: SDK zlib\nVersion: 1.2.12\nLibs: -lz\nCflags:\n' > "$WORK/sdk-pc/zlib.pc"
    (cd "$S" && PKG_CONFIG_LIBDIR="$P/lib/pkgconfig:$PNGP/lib/pkgconfig:$WORK/sdk-pc" ./configure \
        --prefix="$P" --host="$(host_for "$A")" \
        --enable-static --disable-shared \
        --enable-quartz=yes --enable-quartz-font=yes --enable-quartz-image=yes \
        --enable-png=yes --enable-pdf=yes --enable-ps=yes --enable-svg=yes \
        --enable-script=yes --enable-xml=yes \
        --enable-ft=no --enable-fc=no --enable-gobject=no \
        --enable-xlib=no --enable-xlib-xrender=no --enable-xcb=no --enable-xlib-xcb=no \
        --enable-xcb-shm=no --enable-gl=no --enable-glesv2=no --enable-egl=no --enable-glx=no \
        --enable-interpreter=no --enable-trace=no --enable-symbol-lookup=no \
        --disable-valgrind --disable-gtk-doc \
        CC=clang CFLAGS="$CF" \
        LDFLAGS="$LF -L$PNGP/lib" \
      && make -C src -j"$JOBS" libcairo.la)
    grep -q '^#define CAIRO_HAS_QUARTZ_FONT 1' "$S/src/cairo-features.h"
    grep -q '^#define CAIRO_HAS_PDF_SURFACE 1' "$S/src/cairo-features.h"
    grep -q '^#define CAIRO_HAS_PNG_FUNCTIONS 1' "$S/src/cairo-features.h"
    if grep -q '^#define CAIRO_HAS_FT_FONT 1' "$S/src/cairo-features.h"; then
      echo "::error::cairo picked up FreeType"; exit 1
    fi
    mkdir -p "$P/lib"
    cp "$S/src/.libs/libcairo.a" "$P/lib/libcairo.a"
    echo "::endgroup::"
  fi
done

for L in libjpeg libpixman-1 libcairo; do
  lipo -create "$WORK"/arm64/prefix/lib/$L.a "$WORK"/x86_64/prefix/lib/$L.a -output "$OUT/$L.a"
done

# every output must carry both slices
for L in libcairo libpixman-1 libpng16 libjpeg; do
  for A in $ARCHS; do
    lipo "$OUT/$L.a" -verify_arch "$A" || { echo "::error::$L.a lacks $A"; exit 1; }
  done
  echo "$L.a: $(lipo -archs "$OUT/$L.a")"
done
