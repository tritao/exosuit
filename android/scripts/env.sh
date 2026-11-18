# Source this (". android/scripts/env.sh") on macOS or Linux. It defaults the Android toolchain variables to the per-user
# folder that setup.sh fills, the same defaults env.ps1 uses on Windows:
#   macOS  ~/Library/Application Support/exosuit-android     Linux  ~/.local/share/exosuit-android
# EXOSUIT_ANDROID_HOME overrides the folder. Variables already set to an existing path are left alone.
# The Android app is built on Windows today (build.ps1); this file is for setup.sh, the emulator and adb on other systems.

exosuit_android_home() {
    if [ -n "${EXOSUIT_ANDROID_HOME:-}" ]; then
        printf '%s\n' "$EXOSUIT_ANDROID_HOME"
    elif [ "$(uname -s)" = "Darwin" ]; then
        printf '%s\n' "$HOME/Library/Application Support/exosuit-android"
    else
        printf '%s\n' "${XDG_DATA_HOME:-$HOME/.local/share}/exosuit-android"
    fi
}

exosuit_android_default() { # name default
    eval "current=\${$1:-}"
    if [ -z "$current" ] || [ ! -e "$current" ]; then
        export "$1=$2"
    fi
}

EXOSUIT_ANDROID_HOME_DIR="$(exosuit_android_home)"
exosuit_android_default ANDROID_HOME "$EXOSUIT_ANDROID_HOME_DIR/sdk"
exosuit_android_default GRADLE_USER_HOME "$EXOSUIT_ANDROID_HOME_DIR/gradle-home"
exosuit_android_default ANDROID_AVD_HOME "$EXOSUIT_ANDROID_HOME_DIR/avd"
exosuit_android_default ANDROID_USER_HOME "$EXOSUIT_ANDROID_HOME_DIR/user-home"
export ANDROID_SDK_ROOT="$ANDROID_HOME"

# JAVA_HOME: the toolchain's JDK (macOS archives nest it under Contents/Home).
if [ -z "${JAVA_HOME:-}" ] || [ ! -x "$JAVA_HOME/bin/java" ]; then
    for candidate in "$EXOSUIT_ANDROID_HOME_DIR"/jdk/*/Contents/Home "$EXOSUIT_ANDROID_HOME_DIR"/jdk/*; do
        if [ -x "$candidate/bin/java" ]; then
            export JAVA_HOME="$candidate"
            break
        fi
    done
fi

# cmake and ninja from the SDK's cmake package, then adb and the emulator.
for directory in "$ANDROID_HOME"/cmake/*/bin "$ANDROID_HOME/platform-tools" "$ANDROID_HOME/emulator" "$ANDROID_HOME/cmdline-tools/latest/bin" "${JAVA_HOME:+$JAVA_HOME/bin}"; do
    if [ -d "$directory" ]; then
        case ":$PATH:" in *":$directory:"*) ;; *) PATH="$directory:$PATH" ;; esac
    fi
done
export PATH
