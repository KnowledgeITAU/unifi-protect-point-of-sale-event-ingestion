#requires -Version 7.0
<#
.SYNOPSIS
    Lists Protect cameras so you can pick the one POS events should attach to.

.DESCRIPTION
    POS events are ingested against a specific camera, so you need its real ID.
    Use -SetAsPosCamera to write the chosen ID straight into the config file.

.EXAMPLE
    ./Get-UnifiCameras.ps1

.EXAMPLE
    ./Get-UnifiCameras.ps1 -SetAsPosCamera -CameraId 61b3f2c4e4b0a1234567890a

.EXAMPLE
    ./Get-UnifiCameras.ps1 -Detailed | ConvertTo-Json -Depth 6
#>
[CmdletBinding()]
param(
    [string] $ConfigPath = (Join-Path $PSScriptRoot '..' 'config' 'unifi.config.json'),
    [string] $ProfileName,
    [switch] $Detailed,
    [switch] $SetAsPosCamera,
    [string] $CameraId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' '..' 'shared' 'UnifiClient' 'UnifiClient.psd1') -Force

$resolvedConfig = Resolve-Path -LiteralPath $ConfigPath
$prof = Get-UnifiConfig -ConfigPath $resolvedConfig -ProfileName $ProfileName

# /cameras may return a bare array or a { data: [...] } envelope depending on version.
$cameras = @(Invoke-UnifiRequest -Profile $prof -Application protect -Path '/cameras' | Expand-UnifiResponse)

if ($cameras.Count -eq 0) {
    Write-Warning 'No cameras returned by this console.'
    return
}

if ($Detailed) {
    return $cameras
}

# Field names vary by Protect version, so read every one defensively.
$view = foreach ($c in $cameras) {
    [PSCustomObject]@{
        Id    = Get-UnifiProperty $c -Name 'id', '_id' -Default ''
        Name  = Get-UnifiProperty $c -Name 'name', 'displayName' -Default ''
        Model = Get-UnifiProperty $c -Name 'modelKey', 'type', 'model' -Default ''
        State = Get-UnifiProperty $c -Name 'state', 'connectionState', 'status' -Default ''
        Mac   = Get-UnifiProperty $c -Name 'mac' -Default ''
    }
}

Write-Host ''
$view | Format-Table -AutoSize | Out-String | Write-Host

if ($SetAsPosCamera) {
    if (-not $CameraId) {
        throw 'Pass -CameraId with the ID of the camera to use. Copy it from the table above.'
    }
    if ($CameraId -notin $view.Id) {
        throw "Camera ID '$CameraId' is not in the list returned by the console."
    }

    $json = Get-Content -LiteralPath $resolvedConfig -Raw | ConvertFrom-Json
    $json.pos.cameraId = $CameraId
    $json | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $resolvedConfig -Encoding utf8

    $chosen = $view | Where-Object Id -eq $CameraId
    Write-Host "POS camera set to '$($chosen.Name)' ($CameraId) in $resolvedConfig" -ForegroundColor Green
}
else {
    Write-Host 'To wire one of these up as the POS camera:' -ForegroundColor Cyan
    Write-Host "  ./Get-UnifiCameras.ps1 -SetAsPosCamera -CameraId $($view[0].Id)" -ForegroundColor White
}
