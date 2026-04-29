#!/bin/bash

JAVA_HOME="/nix/store/xad649j61kwkh0id5wvyiab5rliprp4d-openjdk-17.0.15+6/lib/openjdk"
SYSPROF_DEV="/nix/store/0nhrfd0ggrim9h09a4n0awqzyk7w0c6i-sysprof-3.44.0-dev"
APPINDICATOR_DEV="/nix/store/0gfsfrizrf20m04fya53g8dbagdz3f2p-libappindicator-gtk3-12.10.1+20.10.20200706.1-dev"

export JAVA_HOME
export PKG_CONFIG_PATH="$SYSPROF_DEV/lib/pkgconfig:$APPINDICATOR_DEV/lib/pkgconfig:$PKG_CONFIG_PATH"

# Rebuild if binary doesn't exist
if [ ! -f "build/install_prefix/hamma" ]; then
  echo "Building Flutter Linux app..."
  mkdir -p build/install_prefix
  if [ -f "build/linux/x64/debug/CMakeCache.txt" ]; then
    sed -i 's|CMAKE_INSTALL_PREFIX:PATH=/var/empty/local|CMAKE_INSTALL_PREFIX:PATH=/home/runner/workspace/build/install_prefix|g' build/linux/x64/debug/CMakeCache.txt
    sed -i 's|_GNUInstallDirs_LAST_CMAKE_INSTALL_PREFIX:INTERNAL=/var/empty/local|_GNUInstallDirs_LAST_CMAKE_INSTALL_PREFIX:INTERNAL=/home/runner/workspace/build/install_prefix|g' build/linux/x64/debug/CMakeCache.txt
  fi
  flutter build linux --debug
fi

echo "Starting Hamma..."
cd build/install_prefix
export LD_LIBRARY_PATH="$PWD/lib:$LD_LIBRARY_PATH"

# Use Mesa software OpenGL rendering
export LIBGL_ALWAYS_SOFTWARE=1
export GALLIUM_DRIVER=llvmpipe

# Start app on virtual framebuffer with a proper screen size
exec xvfb-run -a --server-args="-screen 0 1280x800x24" ./hamma
