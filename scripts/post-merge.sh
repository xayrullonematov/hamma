#!/bin/bash
# Post-merge setup for Hamma (Flutter project).
#
# Runs automatically after a task agent's branch is merged into main.
# Keep it idempotent, non-interactive, and fast.
#
# What this does:
#   - Refreshes Dart/Flutter package dependencies (`flutter pub get`).
#     This catches any pubspec.yaml / pubspec.lock changes the merged
#     task introduced.
#
# What this deliberately does NOT do:
#   - `flutter build linux` is left to `run.sh`, which already rebuilds
#     on demand when `build/install_prefix/hamma` is missing. Running a
#     full Flutter build here would blow past any reasonable post-merge
#     budget on every merge.
#   - Native side-car binaries under native/<os>/ are produced by CI
#     per release tag, not by this script.
set -euo pipefail

cd "$(dirname "$0")/.."

echo "[post-merge] flutter pub get"
flutter pub get

echo "[post-merge] done"
