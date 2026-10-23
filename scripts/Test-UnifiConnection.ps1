#requires -Version 7.0
<#
.SYNOPSIS
    Verifies the API key, TLS handling and base URL by calling Protect's /meta/info.

.DESCRIPTION
    The PowerShell equivalent of the curl in design.md:
        curl -k -X GET 'https://192.168.1.1/proxy/protect/integration/v1/meta/info' \
             -H 'X-API-KEY: YOUR_API_KEY' -H 'Accept: application/json'

    Run this first. If it fails, nothing else will work and the error will tell you why.

.EXAMPLE
    ./Test-UnifiConnection.ps1

.EXAMPLE
    ./Test-UnifiConnection.ps1 -ProfileName cloud -Verbose
#>
[CmdletBinding()]
param(
    [string] $ConfigPath = (Join-Path $PSScriptRoot '..' 'config' 'unifi.config.json'),
    [string] $ProfileName
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' '..' 'shared' 'UnifiClient' 'UnifiClient.psd1') -Force

$prof = Get-UnifiConfig -ConfigPath (Resolve-Path -LiteralPath $ConfigPath) -ProfileName $ProfileName

Write-Host ''
Write-Host "Profile : $($prof.Name)" -ForegroundColor Cyan
Write-Host "Target  : $(Get-UnifiAppBaseUrl -Profile $prof -Application protect)" -ForegroundColor Cyan
Write-Host "TLS     : $($prof.SkipCertificateCheck ? 'certificate check skipped (self-signed gateway)' : 'certificate validated')" -ForegroundColor Cyan
Write-Host ''

$results = [System.Collections.Generic.List[object]]::new()

function Test-Endpoint {
    param([string] $Label, [string] $Path)

    try {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $resp = Invoke-UnifiRequest -Profile $prof -Application protect -Path $Path
        $sw.Stop()
        $results.Add([PSCustomObject]@{ Check = $Label; Result = 'OK'; Ms = $sw.ElapsedMilliseconds })
        return $resp
    }
    catch {
        $results.Add([PSCustomObject]@{ Check = $Label; Result = 'FAILED'; Ms = $null })
        Write-Host "  $Label failed:" -ForegroundColor Red
        Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }
}

Write-Host 'Checking Protect integration API...' -ForegroundColor White
$info = Test-Endpoint -Label 'GET /meta/info' -Path '/meta/info'

if ($info) {
    Write-Host ''
    Write-Host 'Console responded:' -ForegroundColor Green
    $info | Format-List | Out-String | Write-Host
}

# Cameras are needed for POS events, so confirm we can enumerate them too.
$cameras = Test-Endpoint -Label 'GET /cameras' -Path '/cameras'
if ($null -ne $cameras) {
    $count = @($cameras | Expand-UnifiResponse).Count
    Write-Host "Cameras visible to this API key: $count" -ForegroundColor Green
    if ($count -eq 0) {
        Write-Warning 'No cameras returned. POS events attach to a camera, so you need at least one adopted camera.'
    }
}

Write-Host ''
$results | Format-Table -AutoSize | Out-String | Write-Host

if ($results.Where({ $_.Result -eq 'FAILED' }).Count -gt 0) {
    Write-Host 'Connection test did not fully pass. See the errors above.' -ForegroundColor Red
    exit 1
}

Write-Host 'Connection OK.' -ForegroundColor Green
Write-Host 'Next: ./Get-UnifiCameras.ps1 to pick a camera, then ./Find-PosEndpoint.ps1' -ForegroundColor Cyan
