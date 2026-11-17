# Shared by build.ps1 and dev.ps1 (dot-source after env.ps1): compiles the Haxe module and stages ui.hl, ui.hli, ui.entries.

# Writes <out>/haxeon.json for the Android module (ExosuitApp on NativeKit) and returns its path.
function Write-HaxeProject([string]$out) {
    New-Item -ItemType Directory -Force $out | Out-Null
    $dependencies = [ordered]@{
        'haxeon-ui'       = @{ path = Join-Path $HaxeonRoot 'packages/ui' }
        'haxeon-platform' = @{ path = Join-Path $HaxeonRoot 'packages/platform' }
        'haxeon-gpu'      = @{ path = Join-Path $HaxeonRoot 'packages/gpu' }
        'haxeon-editor'   = @{ path = Join-Path $HaxeonRoot 'packages/editor' }
        'haxeon-compiler' = @{ path = Join-Path $HaxeonRoot 'embed' }
        'pluginhost'      = @{ path = Join-Path $RepoRoot 'native-packages/plugin-host' }
        'noisekit'        = @{ path = Join-Path $RepoRoot 'native-packages/noise' }
        'terminalsession' = @{ path = Join-Path $RepoRoot 'native-packages/terminal/session' }
        'textmateregex'   = @{ path = Join-Path $RepoRoot 'native-packages/oniguruma' }
    }
    $project = [ordered]@{
        version = 1; package = @{ name = 'exosuit-android' }; entry = 'Main'
        sourceRoots = @((Join-Path $AndroidRoot 'haxe/src'), (Join-Path $RepoRoot 'src'), (Join-Path $RepoRoot 'graphical/src'))
        scopeSourceRoots = $false; dependencies = $dependencies; target = 'host'; outputDir = 'output'
    }
    $projectPath = Join-Path $out 'haxeon.json'
    $json = $project | ConvertTo-Json -Depth 30
    # Rewriting an identical file would look like a project change to the resident compiler.
    if (-not (Test-Path $projectPath) -or [IO.File]::ReadAllText($projectPath) -ne $json) {
        [IO.File]::WriteAllText($projectPath, $json, [Text.UTF8Encoding]::new($false))
    }
    return $projectPath
}

# Compiles the project (--compiler-only: just the Haxe compiler runs; the native libraries come from native/CMakeLists.txt)
# and copies ui.hl, ui.hli and ui.entries into $assets. The haxeon CLI hands the compile to a per-project worker that stays
# resident for HAXEON_COMPILER_IDLE_SECONDS (90 by default) and recompiles only what changed.
function Invoke-HaxeCompile([string]$out, [string]$assets, [int]$timeout = 900, [switch]$Live) {
    $projectPath = Write-HaxeProject $out
    $env:HAXEON_HOME = $HaxeonRoot
    Invoke-Guarded $Hl ('"' + $Cli + '" build --compiler-only ' + $(if ($Live) { '--live ' } else { '' }) + '--project "' + $projectPath + '"') `
        (Join-Path $out 'compile.log') $timeout
    Publish-HaxeModule $out $assets
}

# Stages the compiled module of <out> (ui.hl, ui.hli, ui.entries) into $assets.
function Publish-HaxeModule([string]$out, [string]$assets) {
    $module = Join-Path $out 'output/host/main.hl'
    $identity = Get-Content -LiteralPath "$module.live.json" -Raw | ConvertFrom-Json
    $ids = foreach ($name in 'UiBridge.init', 'UiBridge.commandJSON', 'UiBridge.takeHostRequest') {
        $found = @($identity.identities | Where-Object name -CEQ $name)
        if ($found.Count -ne 1) { throw "Expected exactly one compiled entry $name" }
        [string]$found[0].id
    }
    # The optional live-patch hooks (UiBridge.liveRelease / liveRebuild) are lines 4 and 5 of ui.entries.
    foreach ($name in 'UiBridge.liveRelease', 'UiBridge.liveRebuild') {
        $found = @($identity.identities | Where-Object name -CEQ $name)
        if ($found.Count -eq 1) { $ids += [string]$found[0].id }
    }
    New-Item -ItemType Directory -Force $assets | Out-Null
    Copy-Item $module (Join-Path $assets 'ui.hl')
    Copy-Item "$module.hli" (Join-Path $assets 'ui.hli')
    [IO.File]::WriteAllText((Join-Path $assets 'ui.entries'), ($ids -join "`n") + "`n", [Text.UTF8Encoding]::new($false))
}

# A fingerprint of everything that is not Haxe: the JNI/native sources, the Kotlin host, the Gradle files, NativeKit's
# Android host and the native packages. build.ps1 records it after a full build; dev.ps1 compares it to decide whether the
# installed APK can still run a new ui.hl (same stamp) or a full build is needed. Path, size and write time only.
function Get-NativeStamp {
    $roots = @(
        (Join-Path $AndroidRoot 'native'), (Join-Path $AndroidRoot 'app/src'), (Join-Path $HaxeonRoot 'vendor/nativekit/android'),
        (Join-Path $HaxeonRoot 'native'), (Join-Path $RepoRoot 'native-packages')
    )
    $extensions = '.c', '.h', '.cpp', '.cc', '.hpp', '.txt', '.cmake', '.kt', '.java', '.xml', '.ttf'
    $lines = [Collections.Generic.List[string]]::new()
    foreach ($file in 'android/build.gradle.kts', 'android/app/build.gradle.kts', 'android/settings.gradle.kts', 'android/gradle.properties') {
        $path = Join-Path $RepoRoot $file
        if (Test-Path $path) { $lines.Add("$file " + (Get-Item $path).Length + ' ' + (Get-Item $path).LastWriteTimeUtc.Ticks) }
    }
    foreach ($root in $roots) {
        if (-not (Test-Path $root)) { continue }
        foreach ($path in [IO.Directory]::EnumerateFiles($root, '*', [IO.SearchOption]::AllDirectories)) {
            if ($extensions -notcontains [IO.Path]::GetExtension($path).ToLowerInvariant()) { continue }
            if ($path -match '[\/](build|\.git|\.cxx|vendor[\/]noise-c[\/]tests)[\/]') { continue }
            $info = [IO.FileInfo]::new($path)
            $lines.Add("$path $($info.Length) $($info.LastWriteTimeUtc.Ticks)")
        }
    }
    $lines.Sort([StringComparer]::Ordinal)
    $bytes = [Text.Encoding]::UTF8.GetBytes(($lines -join "`n"))
    return [BitConverter]::ToString([Security.Cryptography.SHA256]::HashData($bytes)).Replace('-', '').Substring(0, 24)
}
