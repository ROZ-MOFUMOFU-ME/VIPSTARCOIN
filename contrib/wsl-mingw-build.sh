#!/bin/bash
# Local Windows GUI build via MSYS2 + WSL interop. Replicates
# .github/workflows/wintest.yml against the local MSYS2 install at C:\msys64.
#
# Usage (from WSL):
#   ./contrib/wsl-mingw-build.sh             # rsync src + full build
#   ./contrib/wsl-mingw-build.sh make        # rsync src + `make` (incremental)
#   ./contrib/wsl-mingw-build.sh clean       # drop the Windows-side build copy
#
# Source tree edits live in WSL /home/aoi/VIPSTARCOIN; rsync copies them to
# a Windows-side NTFS path (windres.exe / cc1.exe / cmd.exe interop don't
# support //wsl.localhost UNC paths). One-time deps live in MSYS2 \$HOME
# (Windows-side) so they survive across re-runs. Output exes appear at
# C:\\msys64\\home\\ROZ\\vips-build\\src\\{qt\\VIPSTARCOIN-qt,VIPSTARCOIN{d,-cli,-tx}}.exe

set -euo pipefail

MSYS2_BASH=/mnt/c/msys64/usr/bin/bash.exe
[ -x "$MSYS2_BASH" ] || { echo "MSYS2 not found at C:\\msys64 — install first."; exit 1; }

ACTION="${1:-build}"
JOBS="${MAKEJOBS:--j$(( $(nproc) > 2 ? $(nproc) - 2 : 1 ))}"

# WSL source (where you edit) and Windows-side build copy (where it compiles).
SRC_WSL=/home/aoi/VIPSTARCOIN
BUILD_LINUX=/mnt/c/msys64/home/ROZ/vips-build   # Linux/WSL view
BUILD_WIN=/c/msys64/home/ROZ/vips-build         # MSYS2 view of the same dir

case "$ACTION" in
  clean)
    echo "Removing $BUILD_LINUX ..."
    rm -rf "$BUILD_LINUX"
    exit 0
    ;;
esac

# Sync WSL source -> Windows-side build copy. Prefer rsync (incremental,
# excludes); fall back to cp -au + tar pipe if rsync isn't installed.
mkdir -p "$BUILD_LINUX"
echo "=== sync WSL -> $BUILD_LINUX ==="
if command -v rsync >/dev/null 2>&1; then
  rsync -a --delete \
    --exclude=.git \
    --exclude='*.o' --exclude='*.lo' --exclude='*.la' --exclude='*.Po' \
    --exclude='.libs' --exclude='.deps' \
    --exclude=db4 --exclude=Makefile --exclude=config.log --exclude=config.status \
    "$SRC_WSL/" "$BUILD_LINUX/"
else
  (cd "$SRC_WSL" && \
   tar --exclude=.git --exclude='*.o' --exclude='*.lo' --exclude='*.la' --exclude='*.Po' \
       --exclude='.libs' --exclude='.deps' \
       --exclude=db4 --exclude=Makefile --exclude=config.log --exclude=config.status \
       -cf - .) | (cd "$BUILD_LINUX" && tar -xf -)
fi

# Script body written to a Windows-visible scratch file (MSYS2's /tmp = C:\tmp).
WIN_SCRATCH_DIR=/mnt/c/msys64/tmp
WIN_SCRATCH=$WIN_SCRATCH_DIR/vipstarcoin-build.sh
mkdir -p $WIN_SCRATCH_DIR

cat > "$WIN_SCRATCH" <<EOF
# /etc/profile expects non-fatal exits (e.g. reading the default-printer
# registry key may return non-zero); source it BEFORE turning on set -e.
export MSYSTEM=MINGW64
source /etc/profile
set -euo pipefail

QTS=/mingw64/qt5-static
mkdir -p "\$HOME/pb21" "\$HOME/qr"

# 1. Static protobuf 3.21 (only built once).
if [ ! -f "\$HOME/pb21/bin/protoc.exe" ]; then
  echo "=== build static protobuf 3.21 (~3-5min, one-time) ==="
  [ -d "\$HOME/pbsrc" ] || git clone --depth 1 -b v3.21.12 https://github.com/protocolbuffers/protobuf "\$HOME/pbsrc"
  cd "\$HOME/pbsrc"
  cmake -G Ninja -S . -B build -DCMAKE_BUILD_TYPE=Release \\
    -Dprotobuf_BUILD_TESTS=OFF -Dprotobuf_BUILD_SHARED_LIBS=OFF \\
    -Dprotobuf_WITH_ZLIB=OFF -DCMAKE_CXX_STANDARD=14 \\
    -DCMAKE_INSTALL_PREFIX="\$HOME/pb21"
  ninja -C build && ninja -C build install
fi

# 2. Static qrencode (only built once).
if [ ! -f "\$HOME/qr/lib/libqrencode.a" ]; then
  echo "=== build static qrencode 4.1.1 (~1-2min, one-time) ==="
  [ -d "\$HOME/qrsrc" ] || git clone --depth 1 -b v4.1.1 https://github.com/fukuchi/libqrencode "\$HOME/qrsrc"
  cmake -G Ninja -S "\$HOME/qrsrc" -B "\$HOME/qrsrc/build" \\
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCMAKE_BUILD_TYPE=Release \\
    -DBUILD_SHARED_LIBS=OFF -DWITH_TOOLS=NO -DWITH_TESTS=NO \\
    -DCMAKE_INSTALL_PREFIX="\$HOME/qr"
  ninja -C "\$HOME/qrsrc/build" && ninja -C "\$HOME/qrsrc/build" install
fi

# 3. Static BDB 4.8.
if [ ! -f "\$HOME/db4/lib/libdb_cxx-4.8.a" ]; then
  echo "=== build static BDB 4.8 (~5-10min, one-time) ==="
  mkdir -p "\$HOME/db4work"
  cp "$BUILD_WIN/contrib/install_db4.sh" "\$HOME/db4work/install_db4.sh"
  cd "\$HOME/db4work"
  bash ./install_db4.sh "\$HOME" --enable-mingw
fi
export BDB_PREFIX="\$HOME/db4"

# 4. Source tree (Windows-side copy).
cd "$BUILD_WIN"

# 5. Configure (only if Makefile is missing OR ACTION asked for full build).
if [ ! -f Makefile ] || [ "$ACTION" = "configure" ] || [ "$ACTION" = "build" ]; then
  if [ "$ACTION" != "make" ]; then
    echo "=== autogen + configure ==="
    ./autogen.sh

    export WANT_PKGCONFIG=yes
    export PKG_CONFIG_ALLOW_SYSTEM_LIBS=1 PKG_CONFIG_ALLOW_SYSTEM_CFLAGS=1
    export PKG_CONFIG="pkg-config --static"
    export PKG_CONFIG_PATH="\$QTS/lib/pkgconfig:\$HOME/pb21/lib/pkgconfig:/mingw64/lib/pkgconfig"
    export PATH="\$QTS/bin:\$HOME/pb21/bin:\$PATH"

    sed -i -E 's/-l:libzstd(\\.a)?/-lzstd/g; s/-l:libz(\\.a)?/-lz/g' "\$QTS"/lib/pkgconfig/*.pc

    SUPP=""
    for f in "\$QTS"/lib/libQt5*Support.a "\$QTS"/lib/libqtfreetype.a; do
      [ -e "\$f" ] || continue
      b=\$(basename "\$f" .a); SUPP="\$SUPP -l\${b#lib}"
    done
    export QTPLATFORM_CFLAGS=" "
    # Static QJpegPlugin (background.jpg) linked by full path — libtool drops a
    # bare -lqjpeg from the plugin -L path but keeps a full-path .a in position.
    JPEG_A=""
    for f in "\$QTS"/share/qt5/plugins/imageformats/libqjpeg.a "\$QTS"/lib/libqtlibjpeg.a; do
      [ -e "\$f" ] && JPEG_A="\$JPEG_A \$f"
    done
    export QTPLATFORM_LIBS="-L\$QTS/lib -Wl,--start-group\$SUPP -ldwrite -ld2d1 -lwtsapi32 -lwinspool -lshlwapi -ldwmapi -Wl,--end-group\$JPEG_A"

    export QR_CFLAGS="-I\$HOME/qr/include"
    export QR_LIBS="-L\$HOME/qr/lib -lqrencode"

    ./configure --with-gui=qt5 --without-miniupnpc --disable-reduce-exports --disable-shared \\
      --with-boost=/mingw64 --with-boost-libdir=/mingw64/lib \\
      --with-qt-plugindir="\$QTS/share/qt5/plugins" --with-qt-bindir="\$QTS/bin" \\
      --disable-tests --disable-bench \\
      CXXFLAGS="-std=c++14 -O2 -g -D_GLIBCXX_ASSERTIONS" \\
      PROTOC="\$HOME/pb21/bin/protoc.exe" \\
      MOC=\$QTS/bin/moc UIC=\$QTS/bin/uic RCC=\$QTS/bin/rcc \\
      LRELEASE=\$QTS/bin/lrelease LUPDATE=\$QTS/bin/lupdate \\
      LDFLAGS="-static -static-libgcc -static-libstdc++" \\
      BDB_LIBS="-L\$BDB_PREFIX/lib -ldb_cxx-4.8" BDB_CFLAGS="-I\$BDB_PREFIX/include"
  fi
fi

echo "=== make $JOBS ==="
make $JOBS

echo "=== output ==="
ls -lh src/VIPSTARCOIN{d,-cli,-tx}.exe src/qt/VIPSTARCOIN-qt.exe 2>&1 | tail -5
EOF

"$MSYS2_BASH" -lc 'bash /tmp/vipstarcoin-build.sh'
