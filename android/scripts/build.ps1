<#
Builds the Android app: the Haxe module (ExosuitApp on NativeKit), the native libraries for each ABI, and the APK.

  pwsh -NoProfile -File android/scripts/build.ps1 [-Abi x86_64,arm64-v8a] [-SkipHaxe] [-SkipNative] [-SkipApk]

Output: android/app/build/outputs/apk/debug/app-debug.apk
Needs the toolchain from scripts/bootstrap.ps1 and a built haxeon (the VM and haxeon-cli.hl in the directory `python scripts/haxeon_paths.py` prints).
#>
param(
    [ValidateSet('x86_64', 'arm64-v8a')][string[]]$Abi = @('x86_64', 'arm64-v8a'),
    [switch]$SkipHaxe,
    [switch]$SkipNative,
    [switch]$SkipApk
)
. (Join-Path $PSScriptRoot 'env.ps1')
. (Join-Path $PSScriptRoot 'haxe-lib.ps1')
Assert-Toolchain
$stage = Join-Path $BuildRoot 'stage'
$assets = Join-Path $stage 'assets'

function Build-HaxeModule {
    $out = Join-Path $BuildRoot 'haxe'
    # Keep the output: the resident compiler's incremental state and the project file stay valid, so a rebuild retypes only edits.
    Invoke-HaxeCompile $out $assets
    New-Item -ItemType Directory -Force (Join-Path $assets 'fonts') | Out-Null
    foreach ($font in 'IBMPlexSans-Regular.ttf', 'IBMPlexMono-Regular.ttf') {
        Copy-Item (Join-Path $HaxeonRoot "packages/ui/vendor/skribidi/example/data/$font") (Join-Path $assets 'fonts')
    }
}

function Build-Native([string]$abi) {
    $out = Join-Path $BuildRoot "native/$abi"
    $libs = Join-Path $stage "jniLibs/$abi"
    $toolchain = (Join-Path $Ndk 'build/cmake/android.toolchain.cmake').Replace('\', '/')
    $configure = '"' + (Join-Path $AndroidRoot 'native').Replace('\', '/') + '" -B "' + $out.Replace('\', '/') + '" -G Ninja "-DCMAKE_MAKE_PROGRAM=' + $Ninja.Replace('\', '/') +
        '" "-DCMAKE_TOOLCHAIN_FILE=' + $toolchain + '" -DANDROID_ABI=' + $abi + ' -DANDROID_PLATFORM=android-34 -DANDROID_STL=c++_shared -DCMAKE_BUILD_TYPE=Release'
    Invoke-Guarded $Cmake $configure (Join-Path $out 'configure.log') 600
    Invoke-Guarded $Cmake ('--build "' + $out + '" --parallel 4') (Join-Path $out 'build.log') 1800
    New-Item -ItemType Directory -Force $libs | Out-Null
    Get-ChildItem (Join-Path $out 'libs') -Filter '*.so' | Copy-Item -Destination $libs
    $triple = if ($abi -eq 'x86_64') { 'x86_64-linux-android' } else { 'aarch64-linux-android' }
    Copy-Item (Join-Path $Ndk "toolchains/llvm/prebuilt/windows-x86_64/sysroot/usr/lib/$triple/libc++_shared.so") $libs
}

# NativeKit's Android host classes (NativeKitHost, ...) are built as the :nativekit module from a fresh copy.
function Copy-NativeKitJava {
    $source = Join-Path $HaxeonRoot 'vendor/nativekit/android/nativekit/src/main'
    $target = Join-Path $AndroidRoot 'nativekit/src/main'
    Remove-Item -Recurse -Force $target -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force $target | Out-Null
    foreach ($item in 'java', 'res', 'AndroidManifest.xml') { Copy-Item (Join-Path $source $item) $target -Recurse }
}

if (-not $SkipHaxe) { Build-HaxeModule }
if (-not $SkipNative) { foreach ($abi in $Abi) { Build-Native $abi } }
if (-not $SkipApk) {
    Copy-NativeKitJava
    $env:GRADLE_OPTS = '-Dorg.gradle.daemon=false'
    Invoke-Guarded $env:ComSpec ('/d /s /c ""' + (Join-Path $AndroidRoot 'gradlew.bat') + '" -p "' + $AndroidRoot + '" --no-daemon assembleDebug"') `
        (Join-Path $BuildRoot 'gradle.log') 1200 $AndroidRoot
    $apk = Join-Path $AndroidRoot 'app/build/outputs/apk/debug/app-debug.apk'
    Write-Host ("APK: $apk ({0:N1} MB)" -f ((Get-Item $apk).Length / 1MB))
}

# dev.ps1 reuses this APK for a new ui.hl as long as the non-Haxe sources still match (haxe-lib.ps1, Get-NativeStamp).
if (-not $SkipNative -and -not $SkipApk -and -not $SkipHaxe) {
    [IO.File]::WriteAllText((Join-Path $BuildRoot 'native.stamp'), (Get-NativeStamp))
}
