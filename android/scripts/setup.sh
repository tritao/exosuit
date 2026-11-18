#!/usr/bin/env bash
# Installs the whole Android toolchain, pinned by android/toolchain.json, into a per-user folder outside every checkout:
#   macOS  ~/Library/Application Support/exosuit-android     Linux  ~/.local/share/exosuit-android
# (sdk, jdk, gradle-home, avd, user-home, downloads). The same job as setup.ps1 on Windows.
#
#   android/scripts/setup.sh [--check] [--force] [--skip-avd]
#
#   (no flag)   installs what is missing: cmdline-tools, JDK 21, the SDK packages (platform-tools, emulator, platform,
#               build-tools, NDK, cmake with ninja, the system image), then the AVD exosuit-s8. Idempotent and resumable:
#               finished items are skipped, an interrupted download continues, a half-extracted folder is redone.
#               It accepts the Android SDK licenses (https://developer.android.com/studio/terms) as sdkmanager --licenses would.
#   --check     installs nothing; prints each item as ok or MISSING; exit 1 when anything is missing.
#   --force     installs the SDK packages again even when present.
#   --skip-avd  leaves the emulator image and the AVD out.
#
# Apple silicon and arm64 Linux get the arm64-v8a system image, everything else x86_64. Needs bash, curl, tar, unzip, python3.
set -euo pipefail

CHECK=0; FORCE=0; SKIP_AVD=0
for argument in "$@"; do
    case "$argument" in
        --check) CHECK=1 ;;
        --force) FORCE=1 ;;
        --skip-avd) SKIP_AVD=1 ;;
        *) echo "unknown argument: $argument" >&2; exit 2 ;;
    esac
done

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="$HERE/../toolchain.json"
# shellcheck source=env.sh
. "$HERE/env.sh"
HOME_DIR="$EXOSUIT_ANDROID_HOME_DIR"
SDK="$ANDROID_HOME"
DOWNLOADS="$HOME_DIR/downloads"
LOGS="$HOME_DIR/logs"

case "$(uname -s)" in Darwin) OS=macos ;; Linux) OS=linux ;; *) echo "unsupported system: $(uname -s) (Windows uses setup.ps1)" >&2; exit 2 ;; esac
case "$(uname -m)" in arm64|aarch64) ARCH=arm64 ;; x86_64|amd64) ARCH=x64 ;; *) echo "unsupported CPU: $(uname -m)" >&2; exit 2 ;; esac
PLATFORM="$OS-$ARCH"

# manifest <python expression over m>: prints a value of the manifest.
manifest() { python3 -c "import json,sys; m=json.load(open(sys.argv[1])); print($1)" "$MANIFEST"; }

ABI="$(manifest "m['avd']['systemImageByPlatform']['$PLATFORM']")"
IMAGE="$(manifest "m['avd']['systemImage']['$ABI']")"
AVD_NAME="$(manifest "m['avd']['name']")"
AVD_DEVICE="$(manifest "m['avd']['device']")"
CMAKE_VERSION="$(manifest "m['cmake']")"
JDK_VERSION="$(manifest "m['jdk']['version']")"
PACKAGES=()
while IFS= read -r line; do PACKAGES+=("$line"); done < <(manifest "'\n'.join(m['sdkPackages'])")
if [ "$SKIP_AVD" -eq 0 ]; then PACKAGES+=("$IMAGE"); fi

package_marker() { printf '%s/%s/package.xml' "$SDK" "$(printf '%s' "$1" | tr ';' '/')"; }
find_jdk() {
    for candidate in "$HOME_DIR"/jdk/*/Contents/Home "$HOME_DIR"/jdk/*; do
        [ -x "$candidate/bin/java" ] && { printf '%s' "$candidate"; return 0; }
    done
    return 1
}

missing=0
report() { # name present(0/1)
    if [ "$2" -eq 0 ]; then echo "  ok       $1"; else echo "  MISSING  $1"; missing=$((missing + 1)); fi
}

if [ "$CHECK" -eq 1 ]; then
    echo "Android toolchain folder: $HOME_DIR"
    if [ -x "$SDK/cmdline-tools/latest/bin/sdkmanager" ]; then report "cmdline-tools" 0; else report "cmdline-tools" 1; fi
    if find_jdk >/dev/null; then report "jdk $JDK_VERSION" 0; else report "jdk $JDK_VERSION" 1; fi
    for package in "${PACKAGES[@]}"; do
        if [ -f "$(package_marker "$package")" ]; then report "$package" 0; else report "$package" 1; fi
    done
    for tool in cmake ninja; do
        if [ -x "$SDK/cmake/$CMAKE_VERSION/bin/$tool" ]; then report "$tool" 0; else report "$tool (in package cmake;$CMAKE_VERSION)" 1; fi
    done
    if [ "$SKIP_AVD" -eq 0 ]; then
        if [ -f "$ANDROID_AVD_HOME/$AVD_NAME.ini" ]; then report "avd $AVD_NAME" 0; else report "avd $AVD_NAME" 1; fi
    fi
    if [ "$missing" -gt 0 ]; then echo "$missing item(s) missing: run android/scripts/setup.sh"; exit 1; fi
    echo "Android toolchain is complete."
    exit 0
fi

mkdir -p "$HOME_DIR" "$DOWNLOADS" "$LOGS" "$GRADLE_USER_HOME" "$ANDROID_AVD_HOME" "$ANDROID_USER_HOME" "$SDK"

# download <url> <algorithm: sha1|sha256> <expected> -> prints the path of the verified file (resumes a partial one).
download() {
    local url="$1" algorithm="$2" expected="$3" name path actual
    name="$(basename "${url%%\?*}")"
    path="$DOWNLOADS/$name"
    if [ -f "$path.verified" ] && [ "$(cat "$path.verified")" = "$expected" ] && [ -f "$path" ]; then printf '%s' "$path"; return 0; fi
    echo "  downloading $name" >&2
    curl -L --fail -sS -C - --retry 3 --retry-delay 5 --max-time 3600 -o "$path" "$url" >&2 \
        || { rm -f "$path"; curl -L --fail -sS --retry 3 --max-time 3600 -o "$path" "$url" >&2; }
    if [ "$algorithm" = sha1 ]; then
        if command -v sha1sum >/dev/null; then actual="$(sha1sum "$path" | cut -d' ' -f1)"; else actual="$(shasum -a 1 "$path" | cut -d' ' -f1)"; fi
    else
        if command -v sha256sum >/dev/null; then actual="$(sha256sum "$path" | cut -d' ' -f1)"; else actual="$(shasum -a 256 "$path" | cut -d' ' -f1)"; fi
    fi
    if [ "$actual" != "$expected" ]; then
        rm -f "$path"
        echo "$name has $algorithm $actual, the manifest pins $expected (deleted; run setup again)" >&2
        exit 1
    fi
    printf '%s' "$expected" > "$path.verified"
    printf '%s' "$path"
}

# extract_top <archive> <target>: unpacks into <target>.partial and renames its single top folder to <target>.
extract_top() {
    local archive="$1" target="$2" partial="$2.partial"
    rm -rf "$partial"; mkdir -p "$partial"
    case "$archive" in
        *.zip) unzip -q "$archive" -d "$partial" ;;
        *) tar -xzf "$archive" -C "$partial" ;;
    esac
    local entries=("$partial"/*)
    [ "${#entries[@]}" -eq 1 ] || { echo "$archive does not hold exactly one top folder" >&2; exit 1; }
    rm -rf "$target"
    mv "${entries[0]}" "$target"
    rmdir "$partial"
}

if [ ! -x "$SDK/cmdline-tools/latest/bin/sdkmanager" ]; then
    echo "== cmdline-tools"
    url="$(manifest "m['cmdlineTools']['$PLATFORM']['url']")"
    sum="$(manifest "m['cmdlineTools']['$PLATFORM']['sha1']")"
    archive="$(download "$url" sha1 "$sum")"
    mkdir -p "$SDK/cmdline-tools"
    extract_top "$archive" "$SDK/cmdline-tools/latest"
fi

if ! find_jdk >/dev/null; then
    echo "== jdk $JDK_VERSION"
    url="$(manifest "m['jdk']['$PLATFORM']['url']")"
    sum="$(manifest "m['jdk']['$PLATFORM']['sha256']")"
    archive="$(download "$url" sha256 "$sum")"
    mkdir -p "$HOME_DIR/jdk"
    extract_top "$archive" "$HOME_DIR/jdk/temurin-${JDK_VERSION//+/_}"
fi

# Pick up the JDK just installed (env.sh ran before it existed).
. "$HERE/env.sh"
[ -n "${JAVA_HOME:-}" ] || { echo "the JDK is missing after its install step" >&2; exit 1; }
SDKMANAGER="$SDK/cmdline-tools/latest/bin/sdkmanager"
AVDMANAGER="$SDK/cmdline-tools/latest/bin/avdmanager"

pending=()
for package in "${PACKAGES[@]}"; do
    if [ "$FORCE" -eq 1 ] || [ ! -f "$(package_marker "$package")" ]; then pending+=("$package"); fi
done
if [ "${#pending[@]}" -gt 0 ]; then
    echo "== accepting SDK licenses"
    yes 2>/dev/null | "$SDKMANAGER" --sdk_root="$SDK" --licenses > "$LOGS/licenses.log" 2>&1 || true
    for package in "${pending[@]}"; do
        echo "== $package"
        "$SDKMANAGER" --sdk_root="$SDK" "$package" > "$LOGS/$(printf '%s' "$package" | tr -c 'A-Za-z0-9.-' '_').log" 2>&1 \
            || { echo "sdkmanager failed for $package; see $LOGS" >&2; exit 1; }
        [ -f "$(package_marker "$package")" ] || { echo "$package is not at $(package_marker "$package") after sdkmanager" >&2; exit 1; }
    done
fi

if [ "$SKIP_AVD" -eq 0 ] && [ ! -f "$ANDROID_AVD_HOME/$AVD_NAME.ini" ]; then
    echo "== avd $AVD_NAME"
    echo no | "$AVDMANAGER" create avd -n "$AVD_NAME" -k "$IMAGE" -d "$AVD_DEVICE" --force > "$LOGS/avd.log" 2>&1 \
        || { echo "avdmanager failed; see $LOGS/avd.log" >&2; exit 1; }
fi

if [ "$SKIP_AVD" -eq 1 ]; then exec "$0" --check --skip-avd; else exec "$0" --check; fi
