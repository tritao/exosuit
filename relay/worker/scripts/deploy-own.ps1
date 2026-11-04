<#
.SYNOPSIS
  Deploys the Exosuit relay Worker to YOUR Cloudflare account (the free plan is enough) and prints its URLs.

.DESCRIPTION
  Nothing in relay/worker is tied to an account: the account comes from `wrangler login` (or CLOUDFLARE_API_TOKEN, or
  -AccountId / CLOUDFLARE_ACCOUNT_ID when the login has several accounts). The Durable Object binding and its migration
  (v1, SQLite-backed MachineRelay) are declared in wrangler.jsonc, so the first deploy creates them.

  Steps: npm ci when node_modules is missing, `wrangler whoami` (stops with the one command to run when you are not
  logged in), `wrangler deploy`, then a probe of the deployed Worker that sends no Origin header, as the phone does.

  Run: pwsh -NoProfile -File relay/worker/scripts/deploy-own.ps1 [-Name exosuit-relay] [-AccountId id] [-DryRun]
  Then use the printed https URL as the relay URL in the editor (Settings: Remote access, or the Remote Access panel).
  The phone learns it from the pairing invitation; there is nothing to set on the phone.
#>
[CmdletBinding()]
param(
    # Worker name; the URL is https://<Name>.<your-subdomain>.workers.dev.
    [string]$Name = 'exosuit-relay',
    # Needed only when the login can reach more than one account.
    [string]$AccountId = $env:CLOUDFLARE_ACCOUNT_ID,
    # Comma-separated browser origins to allow (web client). Native clients send no Origin and are always accepted.
    [string]$AllowedOrigins,
    # Build and validate the bundle without uploading and without a login.
    [switch]$DryRun,
    # Run `wrangler login` (opens a browser) when not logged in, then carry on. Needs a person at the keyboard.
    [switch]$Login,
    [switch]$SkipVerify
)
$ErrorActionPreference = 'Stop'
$worker = Split-Path -Parent $PSScriptRoot
$wrangler = Join-Path $worker 'node_modules\wrangler\bin\wrangler.js'

function Say([string]$text) { Write-Host "deploy-own: $text" }

function Invoke-Wrangler([string[]]$Arguments) {
    # Merge stderr into the captured text so a failure shows wrangler's own message.
    $output = & node $wrangler @Arguments 2>&1 | ForEach-Object { "$_" }
    [pscustomobject]@{ Code = $LASTEXITCODE; Text = ($output -join "`n") }
}

Push-Location $worker
try {
    if (-not (Test-Path $wrangler)) {
        Say 'npm ci (the pinned wrangler)'
        & npm ci --no-audit --no-fund
        if ($LASTEXITCODE -ne 0) { throw 'npm ci failed' }
    }

    if (-not $DryRun) {
        $who = Invoke-Wrangler @('whoami')
        if (($who.Code -ne 0 -or $who.Text -match 'not authenticated') -and $Login) {
            Say 'not logged in: running wrangler login (a browser window opens)'
            & node $wrangler login
            if ($LASTEXITCODE -ne 0) { throw 'wrangler login failed' }
            $who = Invoke-Wrangler @('whoami')
        }
        if ($who.Code -ne 0 -or $who.Text -match 'not authenticated') {
            throw "Not logged in to Cloudflare. Run this once, in a terminal with a browser:`n    node `"$wrangler`" login`nthen run this script again."
        }
        $ids = @([regex]::Matches($who.Text, '\b[0-9a-f]{32}\b') | ForEach-Object { $_.Value } | Select-Object -Unique)
        if (-not $AccountId) {
            if ($ids.Count -gt 1) {
                throw "The login reaches $($ids.Count) accounts:`n$($who.Text)`nRun again with -AccountId <id> (or set CLOUDFLARE_ACCOUNT_ID)."
            }
            if ($ids.Count -eq 1) { $AccountId = $ids[0] }
        }
        if ($AccountId) { $env:CLOUDFLARE_ACCOUNT_ID = $AccountId }
        Say "logged in; account $(if ($AccountId) { $AccountId } else { '(from the API token)' })"
    }

    $arguments = @('deploy', '--name', $Name)
    if ($AllowedOrigins) { $arguments += @('--var', "ALLOWED_ORIGINS:$AllowedOrigins") }
    if ($DryRun) { $arguments += '--dry-run' }
    Say "wrangler $($arguments -join ' ')"
    $result = Invoke-Wrangler $arguments
    Write-Host $result.Text
    if ($result.Code -ne 0) {
        if ($result.Text -match 'subdomain') {
            throw "wrangler deploy failed because the account has no workers.dev subdomain yet. Open https://dash.cloudflare.com, Workers & Pages, pick a subdomain once, then run this script again.`n$($result.Text)"
        }
        throw "wrangler deploy failed (exit $($result.Code))"
    }
    if ($DryRun) { Say 'dry run done: the Worker bundles and its Durable Object binding and migration are valid. Nothing was uploaded.'; return }

    $match = [regex]::Match($result.Text, 'https://[A-Za-z0-9.-]+\.workers\.dev')
    if (-not $match.Success) { throw 'Deployed, but no workers.dev URL was printed. Open the Cloudflare dashboard, Workers, to find it.' }
    $https = $match.Value
    $wss = $https -replace '^https', 'wss'

    if (-not $SkipVerify) {
        # An unauthenticated ticket request with no Origin header: 401 means the Worker and its Durable Object answer and
        # native clients are accepted; 403 origin_not_allowed would mean the no-Origin rule is not deployed.
        $machine = -join (1..32 | ForEach-Object { '{0:x}' -f (Get-Random -Maximum 16) })
        $code = 0
        for ($try = 0; $try -lt 6 -and $code -ne 401; $try++) {
            try {
                Invoke-WebRequest -Method Post -Uri "$https/v1/machines/$machine/tickets" -UseBasicParsing | Out-Null
                $code = 200
            } catch {
                $code = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
            }
            if ($code -ne 401) { Start-Sleep -Seconds 5 }   # a new workers.dev name can take a few seconds to resolve
        }
        if ($code -ne 401) { throw "Probe of $https answered $code, expected 401." }
        Say 'probe ok: 401 for a request with no bearer and no Origin'
    }

    Write-Host ''
    Write-Host "Relay URL (editor setting 'remote/access/relay_url', or type it in the Remote Access panel):"
    Write-Host "  https: $https"
    Write-Host "  wss:   $wss"
} finally {
    Pop-Location
}
