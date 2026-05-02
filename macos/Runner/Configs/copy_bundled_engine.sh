#!/usr/bin/env bash
# Copy the bundled inference engine side-car (libllama.dylib) into
# Runner.app/Contents/Frameworks during the macOS Xcode build.
#
# Wired into the Runner target as a "Run Script" build phase.
# Idempotent — silently no-ops when no side-car has been dropped into
# native/macos/, which is the normal case for contributors who don't
# need the built-in engine.
#
# See native/README.md for how to build libllama.dylib.

set -euo pipefail

SRC_DIR="${SRCROOT}/../native/macos"
DEST_DIR="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}"

if [ ! -d "${SRC_DIR}" ]; then
  echo "note: no native/macos directory; skipping bundled engine copy"
  exit 0
fi

mkdir -p "${DEST_DIR}"

shopt -s nullglob
LIBS=("${SRC_DIR}"/libllama*.dylib)
shopt -u nullglob
for lib in "${LIBS[@]}"; do
  echo "Copying $(basename "${lib}") into Frameworks/"
  cp -f "${lib}" "${DEST_DIR}/"
done

if [ -f "${SRC_DIR}/llama-server" ]; then
  echo "Copying llama-server into Frameworks/"
  cp -f "${SRC_DIR}/llama-server" "${DEST_DIR}/"
  chmod +x "${DEST_DIR}/llama-server"
fi

if [ ${#LIBS[@]} -eq 0 ] && [ ! -f "${SRC_DIR}/llama-server" ]; then
  echo "note: no llama-server or libllama.dylib in native/macos/; "\
       "bundled engine disabled at runtime"
fi
