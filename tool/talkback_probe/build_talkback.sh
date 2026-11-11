#!/usr/bin/env bash
# Builds the TalkBack debug APK from a pinned commit of github.com/google/talkback
# for the x86_64 emulator, for .github/workflows/talkback-probe.yml (order 621).
#
# Nothing from the TalkBack tree enters this repository: it is fetched into
# WORK_DIR, built there, and only the finished APK plus a text record of what
# built it is written to OUT_DIR. Re-running with the same inputs rebuilds the
# same tree from scratch (WORK_DIR is recreated first), so a second run changes
# nothing the first did not.
#
# What the TalkBack source says about building it (read at the pinned commit):
#   README.md           "run ./build.sh"
#   build.sh            needs ANDROID_SDK, `java`, `gradle` on PATH (there is no
#                       gradle wrapper in the tree), writes local.properties,
#                       runs `gradle assembleDebug`, then `find . -name *.apk`
#   build.gradle        AGP 8.11.1 (which refuses Gradle older than 8.13),
#                       Kotlin 1.9.23, applicationId com.android.talkback,
#                       productFlavors phone and wear
#   shared.gradle       compileSdkVersion 36, Java 17 source and target level,
#                       ndk.abiFilters "armeabi-v7a", "arm64-v8a"
#   braille/*/build.gradle  ndkVersion "21.4.7075529" (ndk-build, liblouis and
#                       brltty), so that exact NDK has to be installed
# This script does only the steps those files require, in the same order, and
# makes two changes that build.sh does not: it builds the phone flavour only
# (assemblePhoneDebug, not both flavours), and it narrows the ABI filter to
# x86_64 in the throwaway checkout, because the emulator is x86_64 and the
# upstream filter lists only the two ARM ABIs.
#
# Inputs (environment, all required; the workflow is the single place they are
# written down):
#   TALKBACK_SHA     full commit sha of google/talkback to build
#   GRADLE_VERSION   Gradle release to drive the build (no wrapper upstream)
#   GRADLE_SHA256    sha256 of gradle-$GRADLE_VERSION-bin.zip
#   ANDROID_SDK_ROOT path of the Android SDK (has cmdline-tools)
#   WORK_DIR         scratch directory, recreated on every run
#   OUT_DIR          receives talkback-debug.apk and talkback-build-info.txt
set -euo pipefail

: "${TALKBACK_SHA:?TALKBACK_SHA is required}"
: "${GRADLE_VERSION:?GRADLE_VERSION is required}"
: "${GRADLE_SHA256:?GRADLE_SHA256 is required}"
: "${ANDROID_SDK_ROOT:?ANDROID_SDK_ROOT is required}"
: "${WORK_DIR:?WORK_DIR is required}"
: "${OUT_DIR:?OUT_DIR is required}"

NDK_VERSION="21.4.7075529"
PLATFORM="platforms;android-36"
BUILD_TOOLS_VERSION="35.0.0"
TALKBACK_PACKAGE="com.android.talkback"
TALKBACK_SERVICE="com.google.android.marvin.talkback.TalkBackService"

say() { echo "build_talkback: $*"; }
die() { echo "build_talkback: FAILED: $*" >&2; exit 1; }

case "$TALKBACK_SHA" in
  *[!0-9a-f]*) die "TALKBACK_SHA is not a lowercase hex sha: $TALKBACK_SHA" ;;
esac
[ "${#TALKBACK_SHA}" -eq 40 ] || die "TALKBACK_SHA must be 40 characters, got ${#TALKBACK_SHA}"

SRC_DIR="$WORK_DIR/talkback"
GRADLE_DIR="$WORK_DIR/gradle"

say "recreating $WORK_DIR and $OUT_DIR"
rm -rf "$WORK_DIR" "$OUT_DIR"
mkdir -p "$WORK_DIR" "$OUT_DIR"

# 1. Source at the pinned commit. Fetching a single sha keeps the download small
# and, unlike a branch clone, cannot drift to a newer commit.
say "step 1: fetching google/talkback at $TALKBACK_SHA"
mkdir -p "$SRC_DIR"
git -C "$SRC_DIR" init -q
git -C "$SRC_DIR" remote add origin https://github.com/google/talkback.git
git -C "$SRC_DIR" fetch -q --depth 1 origin "$TALKBACK_SHA"
git -C "$SRC_DIR" checkout -q --detach FETCH_HEAD
GOT_SHA="$(git -C "$SRC_DIR" rev-parse HEAD)"
[ "$GOT_SHA" = "$TALKBACK_SHA" ] || die "checked out $GOT_SHA, wanted $TALKBACK_SHA"
say "step 1 done: tree is at $GOT_SHA"

# 2. JDK. AGP 8.11.1 and the Java 17 compile options need a 17 or newer JDK.
say "step 2: checking the JDK"
command -v java >/dev/null || die "java is not on PATH"
java -version 2>&1 | sed 's/^/build_talkback:   /'
JAVA_MAJOR="$(java -version 2>&1 | sed -n '1s/.*version "\([0-9]*\).*/\1/p')"
[ -n "$JAVA_MAJOR" ] || die "could not read the java major version"
[ "$JAVA_MAJOR" -ge 17 ] || die "java $JAVA_MAJOR is older than 17"

# 3. Gradle, from the official distribution, verified against a pinned sha256.
say "step 3: downloading gradle-$GRADLE_VERSION-bin.zip and verifying sha256"
GRADLE_ZIP="$WORK_DIR/gradle-$GRADLE_VERSION-bin.zip"
curl -fsSL --retry 3 --retry-delay 5 -o "$GRADLE_ZIP" \
  "https://services.gradle.org/distributions/gradle-$GRADLE_VERSION-bin.zip"
echo "$GRADLE_SHA256  $GRADLE_ZIP" | sha256sum -c - || die "gradle distribution checksum mismatch"
mkdir -p "$GRADLE_DIR"
unzip -q "$GRADLE_ZIP" -d "$GRADLE_DIR"
export PATH="$GRADLE_DIR/gradle-$GRADLE_VERSION/bin:$PATH"
gradle --version | sed 's/^/build_talkback:   /'

# 4. Android SDK pieces: the platform named by compileSdkVersion, the build-tools
# revision AGP 8.11.1 defaults to (read from its ToolsRevisionUtils), and the
# NDK revision the braille modules pin.
say "step 4: installing $PLATFORM, build-tools;$BUILD_TOOLS_VERSION, ndk;$NDK_VERSION"
SDKMANAGER="$ANDROID_SDK_ROOT/cmdline-tools/latest/bin/sdkmanager"
if [ ! -x "$SDKMANAGER" ]; then
  SDKMANAGER="$(ls "$ANDROID_SDK_ROOT"/cmdline-tools/*/bin/sdkmanager 2>/dev/null | head -n 1 || true)"
fi
[ -n "$SDKMANAGER" ] && [ -x "$SDKMANAGER" ] || die "sdkmanager not found under $ANDROID_SDK_ROOT/cmdline-tools"
say "step 4: using $SDKMANAGER"
"$SDKMANAGER" --licenses < <(yes) > "$WORK_DIR/sdk-licenses.log" 2>&1 || die "accepting SDK licences failed, see the tail of $WORK_DIR/sdk-licenses.log: $(tail -n 5 "$WORK_DIR/sdk-licenses.log")"
"$SDKMANAGER" --install "$PLATFORM" "build-tools;$BUILD_TOOLS_VERSION" "ndk;$NDK_VERSION" > "$WORK_DIR/sdk-install.log" 2>&1 \
  || die "sdkmanager install failed, tail: $(tail -n 10 "$WORK_DIR/sdk-install.log")"
[ -d "$ANDROID_SDK_ROOT/platforms/android-36" ] || die "platform android-36 missing after install"
[ -d "$ANDROID_SDK_ROOT/build-tools/$BUILD_TOOLS_VERSION" ] || die "build-tools $BUILD_TOOLS_VERSION missing after install"
[ -d "$ANDROID_SDK_ROOT/ndk/$NDK_VERSION" ] || die "ndk $NDK_VERSION missing after install"
say "step 4 done: platform, build-tools and ndk are present"

# 5. x86_64 only, applied to the throwaway checkout and verified.
say "step 5: narrowing ndk.abiFilters in shared.gradle to x86_64"
ABI_OLD='abiFilters "armeabi-v7a", "arm64-v8a"'
ABI_NEW='abiFilters "x86_64"'
[ "$(grep -cF "$ABI_OLD" "$SRC_DIR/shared.gradle")" -eq 1 ] || die "expected exactly one line '$ABI_OLD' in shared.gradle; the pinned tree no longer matches this script"
sed -i "s/$ABI_OLD/$ABI_NEW/" "$SRC_DIR/shared.gradle"
[ "$(grep -cF "$ABI_NEW" "$SRC_DIR/shared.gradle")" -eq 1 ] || die "abiFilters patch did not apply"
git -C "$SRC_DIR" diff --stat | sed 's/^/build_talkback:   /'

# 6. Build. local.properties is what build.sh writes; ANDROID_SDK_ROOT is also
# exported for tools that read the environment instead.
say "step 6: gradle assemblePhoneDebug"
echo "sdk.dir=$ANDROID_SDK_ROOT" > "$SRC_DIR/local.properties"
export ANDROID_SDK_ROOT ANDROID_HOME="$ANDROID_SDK_ROOT"
(
  cd "$SRC_DIR"
  gradle --no-daemon --console=plain --stacktrace \
    -Dorg.gradle.jvmargs=-Xmx4g \
    -Pkotlin.daemon.jvmargs=-Xmx2g \
    assemblePhoneDebug
) || die "gradle assemblePhoneDebug failed (the log above holds the reason)"
say "step 6 done: gradle finished"

# 7. Collect and check the APK. The output directory is the one AGP uses for
# flavour phone, build type debug under the root project.
say "step 7: locating the APK"
APK_DIR="$SRC_DIR/build/outputs/apk/phone/debug"
[ -d "$APK_DIR" ] || die "$APK_DIR does not exist; find output: $(find "$SRC_DIR" -name '*.apk' | head -n 5 | tr '\n' ' ')"
APK_COUNT="$(find "$APK_DIR" -maxdepth 1 -name '*.apk' | wc -l)"
[ "$APK_COUNT" -eq 1 ] || die "expected one APK in $APK_DIR, found $APK_COUNT"
APK_SRC="$(find "$APK_DIR" -maxdepth 1 -name '*.apk')"
cp "$APK_SRC" "$OUT_DIR/talkback-debug.apk"
APK_SHA256="$(sha256sum "$OUT_DIR/talkback-debug.apk" | cut -d' ' -f1)"

AAPT2="$ANDROID_SDK_ROOT/build-tools/$BUILD_TOOLS_VERSION/aapt2"
[ -x "$AAPT2" ] || die "aapt2 not found at $AAPT2"
"$AAPT2" dump badging "$OUT_DIR/talkback-debug.apk" > "$WORK_DIR/badging.txt"
grep -E "^package:|application-debuggable|^sdkVersion|^targetSdkVersion|^native-code" "$WORK_DIR/badging.txt" | sed 's/^/build_talkback:   /'
grep -q "^package: name='$TALKBACK_PACKAGE'" "$WORK_DIR/badging.txt" || die "APK package is not $TALKBACK_PACKAGE"
grep -q "application-debuggable" "$WORK_DIR/badging.txt" || die "APK is not debuggable, so run-as will not work on it"
"$AAPT2" dump xmltree --file AndroidManifest.xml "$OUT_DIR/talkback-debug.apk" > "$WORK_DIR/manifest-tree.txt"
grep -q "$TALKBACK_SERVICE" "$WORK_DIR/manifest-tree.txt" || die "merged manifest does not declare $TALKBACK_SERVICE"
say "native libraries in the APK:"
unzip -l "$OUT_DIR/talkback-debug.apk" | grep -E "lib/[a-z0-9_-]+/" | sed 's/^/build_talkback:   /' || true

{
  echo "talkback_sha=$TALKBACK_SHA"
  echo "gradle_version=$GRADLE_VERSION"
  echo "ndk_version=$NDK_VERSION"
  echo "build_tools_version=$BUILD_TOOLS_VERSION"
  echo "java_major=$JAVA_MAJOR"
  echo "apk_sha256=$APK_SHA256"
  echo "apk_bytes=$(stat -c %s "$OUT_DIR/talkback-debug.apk")"
} > "$OUT_DIR/talkback-build-info.txt"
sed 's/^/build_talkback:   /' "$OUT_DIR/talkback-build-info.txt"
say "done: $OUT_DIR/talkback-debug.apk"
