param(
    [string]$RunsDirectory = (Join-Path $PSScriptRoot 'runs'),
    [string]$Gallery = (Join-Path $PSScriptRoot '../../design/ui-gallery.html')
)

$ErrorActionPreference = 'Stop'
$items = @(Get-ChildItem -LiteralPath $RunsDirectory -Filter frame.png -Recurse |
    Sort-Object FullName | ForEach-Object {
        $name = $_.Directory.Name
        $current = $name -match '^(ide-sessions-|chat-syntax-|composer-reference-|folder-icons-|sticky-|failed-tool-output-|parity-code-|html-ui-end-to-end$|svg-ui-end-to-end$|svg-(dark|light)-rendered$|remote-image-lifecycle$)'
        $category = if ($name -match '^composer-reference-') { 'Updated composer' }
            elseif ($name -match '^(ide-sessions-|folder-icons-)') { 'Workbench' }
            elseif ($name -match 'chat-syntax|diff|tool-output|emphasis|parity-code') { 'Code and output' }
            elseif ($name -match 'image|svg|html') { 'Images and artifacts' }
            elseif ($name -match 'questions|history|repository|workflow') { 'Chat and workflows' }
            else { 'Earlier captures' }
        $theme = if ($name -match 'light') { 'light' }
            elseif ($name -match 'dark') { 'dark' } else { 'unspecified' }
        $bytes = [System.IO.File]::ReadAllBytes($_.FullName)
        if ($bytes.Length -lt 24 -or [BitConverter]::ToString($bytes, 0, 8) -ne '89-50-4E-47-0D-0A-1A-0A') {
            throw "Invalid screenshot PNG: $($_.FullName)"
        }
        [ordered]@{
            name = $name
            category = $category
            theme = $theme
            final = $current
            featured = $name -match '^(ide-sessions-|chat-syntax-)'
            surface = if ($name -match '^ide-sessions-') { 'Full IDE with fixture conversation' }
                elseif ($name -match '^(folder-icons-|ide-)') { 'Full IDE' }
                elseif ($name -match '^(composer-reference-|chat-syntax-)') { 'Sessions pane only' }
                else { 'Feature fixture' }
            width = [System.Net.IPAddress]::NetworkToHostOrder([BitConverter]::ToInt32($bytes, 16))
            height = [System.Net.IPAddress]::NetworkToHostOrder([BitConverter]::ToInt32($bytes, 20))
            src = 'data:image/png;base64,' + [Convert]::ToBase64String($bytes)
        }
    })
if ($items.Count -eq 0) { throw 'No screenshot frames were found.' }
$json = ConvertTo-Json -InputObject $items -Depth 4 -Compress
$html = [System.IO.File]::ReadAllText($Gallery)
$pattern = '(?s)(<script id="screenshots" type="application/json">).*?(</script>)'
if (-not [regex]::IsMatch($html, $pattern)) { throw 'Gallery screenshot data element is missing.' }
$html = [regex]::Replace($html, $pattern, [System.Text.RegularExpressions.MatchEvaluator]{
    param($match)
    $match.Groups[1].Value + $json + $match.Groups[2].Value
})
[System.IO.File]::WriteAllText($Gallery, $html, [System.Text.UTF8Encoding]::new($false))
Write-Output "Updated $Gallery with $($items.Count) embedded screenshots."
