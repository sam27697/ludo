#!/usr/bin/env bash
#
# Cloud Agent bootstrap for the Ludo repository.
#
# Installs the exact toolchains this repo is developed and tested against --
# Dart 3.13.1 and Flutter 3.47.1, the same pair the CI workflows pin (see
# .github/workflows/verify.yml) -- then resolves the pub workspace and the
# Flutter client's dependencies.
#
# The SDKs are installed under $HOME (which survives the fresh `git clone` of
# /workspace that a Cloud Agent build/boot performs) and then symlinked into
# the repo-root toolchains/ directory that bin/ludo-verify.sh already resolves
# (its resolve_dart / resolve_flutter fall back to /workspace/toolchains) and
# into /usr/local/bin so `dart` and `flutter` are on PATH for every shell.
#
# Idempotent by construction: an SDK that is already present is left in place,
# so a re-run -- or a run against a snapshot that already carries the SDKs --
# only refreshes the cheap symlinks and the dependencies instead of
# downloading ~1.7 GB again.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Persistent, no-sudo install location. Deliberately outside /workspace so it
# is not destroyed when the workspace is re-cloned on a fresh boot.
SDK_HOME="${LUDO_SDK_HOME:-$HOME/.local/share/ludo-toolchains}"

DART_VERSION="3.13.1"
FLUTTER_VERSION="3.47.1"
DART_SDK="$SDK_HOME/dart-sdk"
FLUTTER_SDK="$SDK_HOME/flutter"

DART_URL="https://storage.googleapis.com/dart-archive/channels/stable/release/${DART_VERSION}/sdk/dartsdk-linux-x64-release.zip"
FLUTTER_URL="https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz"

mkdir -p "$SDK_HOME"

# --- Dart SDK -------------------------------------------------------------
if [ -x "$DART_SDK/bin/dart" ]; then
  echo "Dart SDK already present at $DART_SDK"
else
  echo "Installing Dart SDK $DART_VERSION ..."
  tmp="$(mktemp -d)"
  curl -fsSL -o "$tmp/dart.zip" "$DART_URL"
  rm -rf "$DART_SDK"
  unzip -q "$tmp/dart.zip" -d "$SDK_HOME"   # unpacks to $SDK_HOME/dart-sdk
  rm -rf "$tmp"
fi

# --- Flutter SDK ----------------------------------------------------------
if [ -x "$FLUTTER_SDK/bin/flutter" ]; then
  echo "Flutter already present at $FLUTTER_SDK"
else
  echo "Installing Flutter $FLUTTER_VERSION ..."
  tmp="$(mktemp -d)"
  curl -fsSL -o "$tmp/flutter.tar.xz" "$FLUTTER_URL"
  rm -rf "$FLUTTER_SDK"
  tar -xf "$tmp/flutter.tar.xz" -C "$SDK_HOME"   # unpacks to $SDK_HOME/flutter
  rm -rf "$tmp"
fi

# Flutter is a git checkout; without this it warns about "dubious ownership"
# on every invocation and refuses to report its version.
git config --global --add safe.directory "$FLUTTER_SDK" >/dev/null 2>&1 || true

# --- Make the SDKs discoverable -------------------------------------------
# 1. bin/ludo-verify.sh resolves /workspace/toolchains/{dart-sdk,flutter} as a
#    fallback, so mirror the SDKs there via symlinks. These are recreated on
#    every run, which is why they cost nothing after a fresh clone wipes them.
mkdir -p "$REPO_ROOT/toolchains"
ln -sfn "$DART_SDK" "$REPO_ROOT/toolchains/dart-sdk"
ln -sfn "$FLUTTER_SDK" "$REPO_ROOT/toolchains/flutter"

# 2. Put `dart` and `flutter` on PATH for every shell via a directory that is
#    already on the default PATH. Best-effort; the toolchains/ symlinks above
#    and the environment's terminals cover the case where this is skipped.
link_dir="/usr/local/bin"
if [ -w "$link_dir" ]; then
  ln -sf "$DART_SDK/bin/dart" "$link_dir/dart"
  ln -sf "$FLUTTER_SDK/bin/flutter" "$link_dir/flutter"
elif command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
  sudo ln -sf "$DART_SDK/bin/dart" "$link_dir/dart"
  sudo ln -sf "$FLUTTER_SDK/bin/flutter" "$link_dir/flutter"
else
  echo "note: could not symlink dart/flutter into $link_dir; PATH still" \
       "resolves them through toolchains/ for bin/ludo-verify.sh"
fi

export PATH="$DART_SDK/bin:$FLUTTER_SDK/bin:$PATH"
export PUB_CACHE="${PUB_CACHE:-$HOME/.pub-cache}"

# Non-interactive, quiet Flutter (no analytics prompt, no animations).
flutter config --no-analytics --no-cli-animations >/dev/null 2>&1 || true
flutter --disable-analytics >/dev/null 2>&1 || true

# --- Dependencies ---------------------------------------------------------
echo "Resolving pub workspace dependencies (dart pub get) ..."
( cd "$REPO_ROOT" && dart pub get )

echo "Resolving Flutter client dependencies (flutter pub get) ..."
( cd "$REPO_ROOT/packages/ludo_client" && flutter pub get )

echo "Ludo environment ready."
dart --version
flutter --version | head -1
