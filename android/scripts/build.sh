#!/usr/bin/env bash
# macOS and Linux counterpart of build.ps1: the Haxe module, the native libraries per ABI, and the APK.
#
#   android/scripts/build.sh [--abi arm64-v8a[,x86_64]] [--skip-haxe] [--skip-native] [--skip-apk]
#
# Output: android/app/build/outputs/apk/debug/app-debug.apk. Logs: android/build/. Needs setup.sh's toolchain and a built haxeon
# (haxeon/scripts/bootstrap-tools.sh, then build-native.sh). The default ABI is the one this machine's emulator runs
# (arm64-v8a on Apple silicon and arm64 Linux, x86_64 otherwise).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANDROID_ROOT="$(cd "$HERE/.." && pwd)"
REPO_ROOT="$(cd "$ANDROID_ROOT/.." && pwd)"
HAXEON_ROOT="$REPO_ROOT/haxeon"
BUILD_ROOT="$ANDROID_ROOT/build"
. "$HERE/env.sh"

case "$(uname -m)" in arm64|aarch64) ABIS=arm64-v8a ;; *) ABIS=x86_64 ;; esac
SKIP_HAXE=0; SKIP_NATIVE=0; SKIP_APK=0
while [ $# -gt 0 ]; do
    case "$1" in
        --abi) ABIS="$2"; shift ;;
        --skip-haxe) SKIP_HAXE=1 ;;
        --skip-native) SKIP_NATIVE=1 ;;
        --skip-apk) SKIP_APK=1 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

NDK_VERSION="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['ndk'])" "$ANDROID_ROOT/toolchain.json")"
NDK="$ANDROID_HOME/ndk/$NDK_VERSION"
[ -f "$NDK/build/cmake/android.toolchain.cmake" ] || { echo "NDK $NDK_VERSION is missing: run android/scripts/setup.sh" >&2; exit 1; }
command -v ninja >/dev/null || { echo "ninja is not on PATH: run android/scripts/setup.sh (it comes with the SDK cmake package)" >&2; exit 1; }
[ -x "${JAVA_HOME:-/nonexistent}/bin/java" ] || { echo "JAVA_HOME is not set: run android/scripts/setup.sh" >&2; exit 1; }
VM_DIR="$(python3 "$REPO_ROOT/scripts/haxeon_paths.py" "$HAXEON_ROOT" | head -n 1)"
HL="$VM_DIR/hl"; CLI="$VM_DIR/haxeon-cli.hl"
STAGE="$BUILD_ROOT/stage"; ASSETS="$STAGE/assets"
mkdir -p "$BUILD_ROOT"

build_haxe() {
    local out="$BUILD_ROOT/haxe"
    [ -x "$HL" ] && [ -f "$CLI" ] || { echo "haxeon is not built ($HL / $CLI); see haxeon/scripts/build-native.sh" >&2; exit 1; }
    mkdir -p "$out" "$ASSETS/fonts"
    python3 - "$out/haxeon.json" "$HAXEON_ROOT" "$REPO_ROOT" "$ANDROID_ROOT" <<'PY'
import json, os, sys
path, haxeon, repo, android = sys.argv[1:]
j = lambda *p: os.path.join(*p)
project = {
    "version": 1, "package": {"name": "exosuit-android"}, "entry": "Main",
    "sourceRoots": [j(android, "haxe/src"), j(repo, "src"), j(repo, "graphical/src")],
    "scopeSourceRoots": False,
    "dependencies": {
        "haxeon-ui": {"path": j(haxeon, "packages/ui")}, "haxeon-platform": {"path": j(haxeon, "packages/platform")},
        "haxeon-gpu": {"path": j(haxeon, "packages/gpu")}, "haxeon-editor": {"path": j(haxeon, "packages/editor")},
        "haxeon-compiler": {"path": j(haxeon, "embed")}, "pluginhost": {"path": j(repo, "native-packages/plugin-host")},
        "noisekit": {"path": j(repo, "native-packages/noise")}, "terminalsession": {"path": j(repo, "native-packages/terminal/session")},
        "textmateregex": {"path": j(repo, "native-packages/oniguruma")},
    },
    "target": "host", "outputDir": "output",
}
text = json.dumps(project, indent=2)
# Rewriting an identical file would look like a project change to the resident compiler.
if not os.path.exists(path) or open(path).read() != text:
    open(path, "w").write(text)
PY
    HAXEON_HOME="$HAXEON_ROOT" DYLD_LIBRARY_PATH="$HAXEON_ROOT/out:${DYLD_LIBRARY_PATH:-}" LD_LIBRARY_PATH="$HAXEON_ROOT/out:${LD_LIBRARY_PATH:-}" \
        "$HL" "$CLI" build --compiler-only --project "$out/haxeon.json" > "$out/compile.log" 2>&1 || { tail -40 "$out/compile.log" >&2; exit 1; }
    python3 - "$out/output/host/main.hl" "$ASSETS" <<'PY'
import json, shutil, sys
module, assets = sys.argv[1:]
identities = json.load(open(module + ".live.json"))["identities"]
ids = []
for name in ("UiBridge.init", "UiBridge.commandJSON", "UiBridge.takeHostRequest"):
    found = [i for i in identities if i["name"] == name]
    if len(found) != 1: sys.exit("Expected exactly one compiled entry " + name)
    ids.append(str(found[0]["id"]))
for name in ("UiBridge.liveRelease", "UiBridge.liveRebuild"):
    found = [i for i in identities if i["name"] == name]
    if len(found) == 1: ids.append(str(found[0]["id"]))
shutil.copy(module, assets + "/ui.hl"); shutil.copy(module + ".hli", assets + "/ui.hli")
open(assets + "/ui.entries", "w").write("\n".join(ids) + "\n")
PY
    for font in IBMPlexSans-Regular.ttf IBMPlexMono-Regular.ttf; do
        cp "$HAXEON_ROOT/packages/ui/vendor/skribidi/example/data/$font" "$ASSETS/fonts/"
    done
}

build_native() {
    local abi="$1" out="$BUILD_ROOT/native/$1" libs="$STAGE/jniLibs/$1"
    mkdir -p "$out" "$libs"
    cmake "$ANDROID_ROOT/native" -B "$out" -G Ninja "-DCMAKE_MAKE_PROGRAM=$(command -v ninja)" \
        "-DCMAKE_TOOLCHAIN_FILE=$NDK/build/cmake/android.toolchain.cmake" -DANDROID_ABI="$abi" -DANDROID_PLATFORM=android-34 \
        -DANDROID_STL=c++_shared -DCMAKE_BUILD_TYPE=Release > "$out/configure.log" 2>&1 || { tail -40 "$out/configure.log" >&2; exit 1; }
    cmake --build "$out" --parallel 4 > "$out/build.log" 2>&1 || { tail -60 "$out/build.log" >&2; exit 1; }
    cp "$out"/libs/*.so "$libs/"
    local triple=aarch64-linux-android
    [ "$abi" = x86_64 ] && triple=x86_64-linux-android
    local prebuilt; prebuilt="$(ls -d "$NDK"/toolchains/llvm/prebuilt/* | head -n 1)"
    cp "$prebuilt/sysroot/usr/lib/$triple/libc++_shared.so" "$libs/"
}

copy_nativekit_java() {
    local source="$HAXEON_ROOT/vendor/nativekit/android/nativekit/src/main" target="$ANDROID_ROOT/nativekit/src/main"
    rm -rf "$target"; mkdir -p "$target"
    for item in java res AndroidManifest.xml; do cp -R "$source/$item" "$target/"; done
}

[ "$SKIP_HAXE" -eq 1 ] || build_haxe
if [ "$SKIP_NATIVE" -eq 0 ]; then for abi in ${ABIS//,/ }; do build_native "$abi"; done; fi
if [ "$SKIP_APK" -eq 0 ]; then
    copy_nativekit_java
    GRADLE_OPTS="-Dorg.gradle.daemon=false" "$ANDROID_ROOT/gradlew" -p "$ANDROID_ROOT" --no-daemon assembleDebug > "$BUILD_ROOT/gradle.log" 2>&1 \
        || { tail -60 "$BUILD_ROOT/gradle.log" >&2; exit 1; }
    ls -l "$ANDROID_ROOT/app/build/outputs/apk/debug/app-debug.apk"
fi
