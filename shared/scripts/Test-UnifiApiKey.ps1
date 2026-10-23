#requires -Version 7.0
<#
.SYNOPSIS
    Works out why a UniFi API key is being rejected, without ever printing the key.

.DESCRIPTION
    A 401 from the console has several possible causes that look identical from the outside.
    This tests the key against every place it could legitimately work and infers which kind
    of key you actually have:

      local Protect   https://<gateway>/proxy/protect/integration/v1/meta/info
      local Network   https://<gateway>/proxy/network/integration/v1/info
      cloud Site Mgr  https://api.ui.com/v1/hosts

    Outcomes:
      local works                -> key is fine, the earlier failure was elsewhere
      only cloud works           -> you created a Site Manager key at unifi.ui.com. It will
                                    never authenticate against the local gateway. Create a
                                    local one: Settings > Control Plane > Integrations.
      Network works, Protect 401 -> key is scoped per application. Create a second key for
                                    Protect and store it under a different secretName.
      nothing works              -> key is wrong, revoked, or mangled on paste. The shape
                                    report below will show whitespace or truncation.

    The key value is never written to the console, a file, or the pipeline. Only its length,
    character classes and a short SHA256 fingerprint are shown, which is enough to tell
    whether two keys are the same without revealing either.

.EXAMPLE
    ./Test-UnifiApiKey.ps1

.EXAMPLE
    ./Test-UnifiApiKey.ps1 -ConfigPath ../../pos-ingestion/config/unifi.config.json -Interactive
#>
[CmdletBinding()]
param(
    [string] $ConfigPath = (Join-Path $PSScriptRoot '..' '..' 'pos-ingestion' 'config' 'unifi.config.json'),
    [string] $ProfileName,

    # Prompt for a key to test instead of reading the vault. Use this to check a freshly
    # created key before committing it to the vault.
    [switch] $Interactive
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' 'UnifiClient' 'UnifiClient.psd1') -Force

$prof = Get-UnifiConfig -ConfigPath (Resolve-Path -LiteralPath $ConfigPath) -ProfileName $ProfileName

# --- Obtain the key ---------------------------------------------------------

if ($Interactive) {
    $secure = Read-Host -AsSecureString -Prompt 'Paste the API key to test'
    $key = [System.Net.NetworkCredential]::new('', $secure).Password
}
else {
    Import-Module Microsoft.PowerShell.SecretManagement -ErrorAction Stop
    try {
        $secure = Get-Secret -Name $prof.SecretName -Vault $prof.VaultName -ErrorAction Stop
    }
    catch {
        Write-Host "Could not read '$($prof.SecretName)' from vault '$($prof.VaultName)'." -ForegroundColor Red
        Write-Host "If the vault is locked, run: Unlock-SecretStore" -ForegroundColor Yellow
        Write-Host "Or test a key without storing it:  ./Test-UnifiApiKey.ps1 -Interactive" -ForegroundColor Yellow
        throw
    }
    $key = [System.Net.NetworkCredential]::new('', $secure).Password
}

if ([string]::IsNullOrEmpty($key)) { throw 'Key is empty.' }

# --- Shape report -----------------------------------------------------------

$nl = [char]10
$cr = [char]13
$trimmed = $key.Trim()
$nonAlnum = [regex]::Replace($key, '[A-Za-z0-9]', '')
$fingerprint = [System.BitConverter]::ToString(
    [System.Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($key))
).Replace('-', '').Substring(0, 12)

Write-Host ''
Write-Host 'Key shape (the value itself is never shown)' -ForegroundColor White
Write-Host '-------------------------------------------' -ForegroundColor White
Write-Host ("  Length              : {0}" -f $key.Length)
Write-Host ("  SHA256 fingerprint  : {0}" -f $fingerprint)
Write-Host ("  Non-alphanumerics   : '{0}'" -f $nonAlnum)

$problems = @()
if ($key -ne $trimmed) { $problems += "has leading or trailing whitespace ($($key.Length - $trimmed.Length) chars)" }
if ($key.Contains(' ')) { $problems += 'contains an embedded space' }
if ($key.Contains($nl) -or $key.Contains($cr)) { $problems += 'contains a newline' }
if ($key.Length -lt 20) { $problems += "is suspiciously short ($($key.Length) chars); it may have been truncated on paste" }

if ($problems) {
    Write-Host ''
    foreach ($p in $problems) { Write-Host "  WARNING: key $p" -ForegroundColor Yellow }
    Write-Host '  A mangled paste is the most common cause of a 401.' -ForegroundColor Yellow
}
else {
    Write-Host '  No formatting problems detected.' -ForegroundColor Green
}

# --- Authentication matrix --------------------------------------------------

Write-Host ''
Write-Host 'Where does this key authenticate?' -ForegroundColor White
Write-Host '---------------------------------' -ForegroundColor White

function Test-Target {
    param([string] $Name, [string] $Uri, [bool] $SkipCert, [string] $KeyValue)

    $p = @{
        Uri                = $Uri
        Method             = 'GET'
        Headers            = @{ 'X-API-KEY' = $KeyValue; 'Accept' = 'application/json' }
        SkipHttpErrorCheck = $true
        TimeoutSec         = 15
        MaximumRedirection = 0
        ErrorAction        = 'SilentlyContinue'
    }
    if ($SkipCert) { $p['SkipCertificateCheck'] = $true }

    try {
        $r = Invoke-WebRequest @p
        $code = [int]$r.StatusCode
    }
    catch {
        return [PSCustomObject]@{ Target = $Name; Status = 'ERR'; Meaning = $_.Exception.Message }
    }

    $meaning = switch ($code) {
        200 { 'ACCEPTED' }
        204 { 'ACCEPTED' }
        401 { 'rejected (unauthorized)' }
        403 { 'authenticated but not permitted (scope)' }
        404 { 'not found / app not present' }
        default { "HTTP $code" }
    }
    [PSCustomObject]@{ Target = $Name; Status = $code; Meaning = $meaning }
}

$targets = @(
    @{ N = 'local Protect';      U = "$($prof.BaseUrl)/proxy/protect/integration/v1/meta/info"; C = $prof.SkipCertificateCheck }
    @{ N = 'local Network';      U = "$($prof.BaseUrl)/proxy/network/integration/v1/info";      C = $prof.SkipCertificateCheck }
    @{ N = 'local Network sites'; U = "$($prof.BaseUrl)/proxy/network/integration/v1/sites";    C = $prof.SkipCertificateCheck }
    @{ N = 'cloud Site Manager'; U = 'https://api.ui.com/v1/hosts';                             C = $false }
)

$results = foreach ($t in $targets) {
    Test-Target -Name $t.N -Uri $t.U -SkipCert $t.C -KeyValue $key
}

$results | Format-Table -AutoSize | Out-String | Write-Host

# --- Diagnosis --------------------------------------------------------------

$byName = @{}
foreach ($r in $results) { $byName[$r.Target] = $r }

$protectOk = $byName['local Protect'].Status -in 200, 204
$networkOk = $byName['local Network'].Status -in 200, 204 -or $byName['local Network sites'].Status -in 200, 204
$cloudOk = $byName['cloud Site Manager'].Status -in 200, 204

Write-Host 'Diagnosis' -ForegroundColor White
Write-Host '---------' -ForegroundColor White

if ($protectOk -and $networkOk) {
    Write-Host '  Key is valid for both Protect and Network on the local console.' -ForegroundColor Green
    Write-Host '  Re-run Test-UnifiConnection.ps1; the earlier failure was not the key.' -ForegroundColor Green
}
elseif ($protectOk) {
    Write-Host '  Key works for Protect but not Network.' -ForegroundColor Yellow
    Write-Host '  Objective 1 will work. For Objective 2, create a Network-scoped key and set a' -ForegroundColor Yellow
    Write-Host '  different secretName in network-iac/config/unifi.config.json.' -ForegroundColor Yellow
}
elseif ($networkOk) {
    Write-Host '  Key works for Network but Protect rejects it.' -ForegroundColor Yellow
    Write-Host '  This console issues per-application keys. Create a Protect key in' -ForegroundColor Yellow
    Write-Host '  Protect > Settings > Integrations, then store it under its own secretName.' -ForegroundColor Yellow
}
elseif ($cloudOk) {
    Write-Host '  This is a SITE MANAGER (cloud) key, not a local console key.' -ForegroundColor Red
    Write-Host '  It authenticates at api.ui.com but will never work against the local gateway.' -ForegroundColor Red
    Write-Host '  Create a local key: UniFi console > Settings > Control Plane > Integrations >' -ForegroundColor Red
    Write-Host '  API Keys, then re-run Initialize-UnifiSecret.ps1 to replace the stored value.' -ForegroundColor Red
}
else {
    Write-Host '  The key was rejected everywhere.' -ForegroundColor Red
    Write-Host '  Most likely: mangled on paste, revoked, or created on a different console.' -ForegroundColor Red
    Write-Host '  Create a fresh key and test it before storing:' -ForegroundColor Red
    Write-Host '    ./Test-UnifiApiKey.ps1 -Interactive' -ForegroundColor White
}

Write-Host ''
