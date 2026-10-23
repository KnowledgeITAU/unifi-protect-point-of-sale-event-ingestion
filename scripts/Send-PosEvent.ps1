#requires -Version 7.0
<#
.SYNOPSIS
    Builds and sends simulated point-of-sale events into UniFi Protect.

.DESCRIPTION
    Two transports, selectable with -Transport:

      pos     The native POS ingestion endpoint. Pass -EndpointPath with the path that
              Find-PosEndpoint.ps1 discovered on your console.
      alarm   The documented Alarm Manager webhook fallback
              (POST /alarm-manager/webhook/{id}, returns 204). Works on any Protect version
              with Alarm Manager, but surfaces the transaction as an alarm trigger rather
              than a rich POS record.

    Supports -WhatIf so you can inspect the exact payload before anything is sent.

.PARAMETER Scenario
    Which canned transaction to send from samples/sample-transactions.json. Use 'all' to
    replay the whole file in order.

.PARAMETER EndpointPath
    Override the POS endpoint path. Required for -Transport pos until the path is confirmed.

.EXAMPLE
    ./Send-PosEvent.ps1 -Transport alarm -Scenario sale -WhatIf

.EXAMPLE
    ./Send-PosEvent.ps1 -Transport pos -EndpointPath '/cameras/abc123/pos' -Scenario sale

.EXAMPLE
    ./Send-PosEvent.ps1 -Transport alarm -Scenario all -DelaySeconds 3
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [string] $ConfigPath = (Join-Path $PSScriptRoot '..' 'config' 'unifi.config.json'),
    [string] $ProfileName,

    [ValidateSet('pos', 'alarm')]
    [string] $Transport = 'alarm',

    [string] $EndpointPath,

    [string] $Scenario = 'sale',

    [string] $SamplePath = (Join-Path $PSScriptRoot '..' 'samples' 'sample-transactions.json'),

    [int] $DelaySeconds = 2
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' '..' 'shared' 'UnifiClient' 'UnifiClient.psd1') -Force

$resolvedConfig = Resolve-Path -LiteralPath $ConfigPath
$prof = Get-UnifiConfig -ConfigPath $resolvedConfig -ProfileName $ProfileName
$cfg = Get-Content -LiteralPath $resolvedConfig -Raw | ConvertFrom-Json

# --- Load scenarios ---------------------------------------------------------

if (-not (Test-Path -LiteralPath $SamplePath)) {
    throw "Sample transactions file not found: $SamplePath"
}
$samples = Get-Content -LiteralPath $SamplePath -Raw | ConvertFrom-Json

$toSend = if ($Scenario -eq 'all') {
    @($samples.transactions)
}
else {
    $match = @($samples.transactions | Where-Object { $_.scenario -eq $Scenario })
    if ($match.Count -eq 0) {
        $available = (@($samples.transactions.scenario) | Select-Object -Unique) -join ', '
        throw "Scenario '$Scenario' not found in $SamplePath. Available: $available, or 'all'."
    }
    $match
}

# --- Payload builders -------------------------------------------------------

function New-PosPayload {
    <#  Native POS ingestion shape. Field names follow the Protect PosTransactionType model;
        adjust here if your console's spec names them differently. #>
    param($Txn, [string] $CameraId, [string] $Timestamp)

    $items = foreach ($i in @($Txn.items)) {
        @{
            name       = $i.name
            quantity   = $i.quantity
            unitPrice  = $i.unitPrice
            totalPrice = [math]::Round($i.quantity * $i.unitPrice, 2)
        }
    }

    @{
        cameraId        = $CameraId
        transactionId   = $Txn.transactionId
        transactionType = $Txn.transactionType
        timestamp       = $Timestamp
        register        = $cfg.pos.registerName
        operator        = $Txn.operator
        currency        = $cfg.pos.currency
        subtotal        = $Txn.subtotal
        tax             = $Txn.tax
        total           = $Txn.total
        paymentMethod   = $Txn.paymentMethod
        items           = @($items)
    }
}

function New-AlarmPayload {
    <#  Alarm Manager webhook shape. Protect uses its own NVR timestamp for the alarm, so the
        transaction detail rides along as context rather than as a structured POS record. #>
    param($Txn, [string] $CameraId, [string] $Timestamp)

    $summary = '{0} {1}{2:N2} on {3}' -f $Txn.transactionType, $cfg.pos.currency, $Txn.total, $cfg.pos.registerName

    @{
        alarm = @{
            name      = "POS: $($Txn.transactionType)"
            sources   = @(@{ device = $CameraId; type = 'include' })
            triggers  = @(@{ key = 'pos'; device = $CameraId })
        }
        timestamp = $Timestamp
        pos       = @{
            transactionId = $Txn.transactionId
            type          = $Txn.transactionType
            register      = $cfg.pos.registerName
            operator      = $Txn.operator
            currency      = $cfg.pos.currency
            total         = $Txn.total
            summary       = $summary
            itemCount     = @($Txn.items).Count
        }
    }
}

# --- Resolve target ---------------------------------------------------------

$cameraId = $cfg.pos.cameraId
if ([string]::IsNullOrWhiteSpace($cameraId)) {
    throw "No POS camera configured. Run: ./Get-UnifiCameras.ps1 -SetAsPosCamera -CameraId <id>"
}

if ($Transport -eq 'pos') {
    if (-not $EndpointPath) {
        throw "Transport 'pos' needs -EndpointPath. Run ./Find-PosEndpoint.ps1 to discover it, or read it from your console's API reference."
    }
    $targetPath = $EndpointPath
}
else {
    if ([string]::IsNullOrWhiteSpace($cfg.pos.alarmTriggerId)) {
        throw "No alarmTriggerId configured. Set pos.alarmTriggerId in $resolvedConfig and create a matching Alarm Manager trigger in Protect."
    }
    $targetPath = "/alarm-manager/webhook/$($cfg.pos.alarmTriggerId)"
}

Write-Host ''
Write-Host "Transport : $Transport" -ForegroundColor Cyan
Write-Host "Endpoint  : POST $(Get-UnifiAppBaseUrl -Profile $prof -Application protect)$targetPath" -ForegroundColor Cyan
Write-Host "Camera    : $cameraId" -ForegroundColor Cyan
Write-Host "Events    : $(@($toSend).Count)" -ForegroundColor Cyan
Write-Host ''

# --- Send -------------------------------------------------------------------

$sent = 0
$failed = 0
$first = $true

foreach ($txn in $toSend) {
    if (-not $first -and $DelaySeconds -gt 0 -and $PSCmdlet.ShouldProcess('delay', 'wait between events')) {
        Start-Sleep -Seconds $DelaySeconds
    }
    $first = $false

    # Stamp at send time so events land on the live timeline, not in the past.
    $timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')

    $payload = $Transport -eq 'pos' `
        ? (New-PosPayload -Txn $txn -CameraId $cameraId -Timestamp $timestamp) `
        : (New-AlarmPayload -Txn $txn -CameraId $cameraId -Timestamp $timestamp)

    $json = $payload | ConvertTo-Json -Depth 10

    $label = "$($txn.scenario) / $($txn.transactionId) / $($cfg.pos.currency)$($txn.total)"

    if ($PSCmdlet.ShouldProcess($label, "POST $targetPath")) {
        try {
            $resp = Invoke-UnifiRequest -Profile $prof -Application protect -Path $targetPath `
                -Method POST -Body $payload -Raw

            Write-Host "  sent  $label  -> HTTP $($resp.StatusCode)" -ForegroundColor Green
            $sent++
        }
        catch {
            Write-Host "  FAIL  $label" -ForegroundColor Red
            Write-Host "        $($_.Exception.Message)" -ForegroundColor Red
            $failed++
        }
    }
    else {
        # -WhatIf: show exactly what would go on the wire.
        Write-Host "  would send $label" -ForegroundColor Yellow
        Write-Host $json -ForegroundColor DarkGray
        Write-Host ''
    }
}

if ($WhatIfPreference) { return }

Write-Host ''
Write-Host "Sent: $sent   Failed: $failed" -ForegroundColor ($failed -gt 0 ? 'Yellow' : 'Green')
if ($sent -gt 0) {
    Write-Host 'Check the Protect timeline for the POS camera to confirm the events landed.' -ForegroundColor Cyan
}
if ($failed -gt 0) { exit 1 }
