#!/usr/bin/env bash
#
# Cloud Agent bootstrap for the Ludo repository.
#
# Installs the exact toolchains this repo is developed and tested against --
# Dart 3.13.1 and Flutter 3.47.1, the same pair the CI workflows pin (see
# .github/workflows/verify.yml) -- into the repo-root `toolchains/` directory
# that bin/ludo-verify.sh already knows how to find (its resolve_dart /
# resolve_flutter fall back to /workspace/toolchains), then resolves the pub
# workspace and the Flutter client's dependencies.
#
# Idempotent by construction: an SDK that is already present is left in place,
# so a re-run -- or a run against a snapshot that already carries the
# toolchains -- only refreshes dependencies instead of downloading ~1.7 GB
# again.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLCHAINS="$REPO_ROOT/toolchains"

DART_VERSION="3.13.1"
FLUTTER_VERSION="3.47.1"
DART_SDK="$TOOLCHAINS/dart-sdk"
FLUTTER_SDK="$TOOLCHAINS/flutter"

DART_URL="https://storage.googleapis.com/dart-archive/channels/stable/release/${DART_VERSION}/sdk/dartsdk-linux-x64-release.zip"
FLUTTER_URL="https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz"

mkdir -p "$TOOLCHAINS"

# --- Dart SDK -------------------------------------------------------------
if [ -x "$DART_SDK/bin/dart" ]; then
  echo "Dart SDK already present at $DART_SDK"
else
  echo "Installing Dart SDK $DART_VERSION ..."
  tmp="$(mktemp -d)"
  curl -fsSL -o "$tmp/dart.zip" "$DART_URL"
  rm -rf "$DART_SDK"
  unzip -q "$tmp/dart.zip" -d "$TOOLCHAINS"   # unpacks to $TOOLCHAINS/dart-sdk
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
  tar -xf "$tmp/flutter.tar.xz" -C "$TOOLCHAINS"   # unpacks to $TOOLCHAINS/flutter
  rm -rf "$tmp"
fi

# Flutter is a git checkout; without this it warns about "dubious ownership"
# on every invocation and refuses to report its version.
git config --global --add safe.directory "$FLUTTER_SDK" >/dev/null 2>&1 || true

export PATH="$DART_SDK/bin:$FLUTTER_SDK/bin:$PATH"
export PUB_CACHE="${PUB_CACHE:-$HOME/.pub-cache}"

# Put `dart` and `flutter` on PATH for every future shell via symlinks in a
# directory that is already on the default PATH. Best-effort: bin/ludo-verify.sh
# resolves the toolchains from toolchains/ directly even if this step is
# skipped, and the environment's terminals set PATH explicitly too.
link_dir="/usr/local/bin"
if [ -w "$link_dir" ]; then
  ln -sf "$DART_SDK/bin/dart" "$link_dir/dart"
  ln -sf "$FLUTTER_SDK/bin/flutter" "$link_dir/flutter"
elif command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
  sudo ln -sf "$DART_SDK/bin/dart" "$link_dir/dart"
  sudo ln -sf "$FLUTTER_SDK/bin/flutter" "$link_dir/flutter"
else
  echo "note: could not symlink dart/flutter into $link_dir; add" \
       "$DART_SDK/bin and $FLUTTER_SDK/bin to PATH manually if needed"
fi

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
