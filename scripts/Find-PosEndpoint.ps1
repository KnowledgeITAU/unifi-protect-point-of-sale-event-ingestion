#requires -Version 7.0
<#
.SYNOPSIS
    Discovers the exact Point-of-sale event ingestion endpoint on YOUR console.

.DESCRIPTION
    The Protect API reference is served behind console auth, and the POS ingestion paths are
    not publicly documented, so rather than guess we probe the live console:

      1. Try to pull an OpenAPI/Swagger spec from the console. If found, the POS paths and
         their exact request schema are read straight out of it. This is the reliable answer.
      2. If no spec is served, GET-probe a list of candidate paths. Nothing is written:
         every probe is a GET. The status code tells us what exists:
             404 -> path does not exist
             405 -> path EXISTS but does not accept GET (i.e. it is the POST ingestion path)
             200 -> path exists and is readable
             401/403 -> path exists but this key lacks scope

    Read-only. This script never sends a POS event.

.EXAMPLE
    ./Find-PosEndpoint.ps1

.EXAMPLE
    ./Find-PosEndpoint.ps1 -SaveSpec -Verbose
#>
[CmdletBinding()]
param(
    [string] $ConfigPath = (Join-Path $PSScriptRoot '..' 'config' 'unifi.config.json'),
    [string] $ProfileName,
    [switch] $SaveSpec
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' '..' 'shared' 'UnifiClient' 'UnifiClient.psd1') -Force

$resolvedConfig = Resolve-Path -LiteralPath $ConfigPath
$prof = Get-UnifiConfig -ConfigPath $resolvedConfig -ProfileName $ProfileName
$cfg = Get-Content -LiteralPath $resolvedConfig -Raw | ConvertFrom-Json
$base = Get-UnifiAppBaseUrl -Profile $prof -Application protect

Write-Host ''
Write-Host "Probing $base" -ForegroundColor Cyan
Write-Host 'Read-only: every probe below is a GET. No events are sent.' -ForegroundColor DarkGray
Write-Host ''

# Shared request options so the probes bypass the module's throw-on-error behaviour
# and let us inspect status codes directly.
$apiKey = Get-UnifiApiKey -Profile $prof
$common = @{
    Headers                 = @{ 'X-API-KEY' = $apiKey; 'Accept' = 'application/json' }
    TimeoutSec              = 15
    SkipHttpErrorCheck      = $true
    MaximumRedirection      = 0
    ErrorAction             = 'SilentlyContinue'
}
if ($prof.SkipCertificateCheck) { $common['SkipCertificateCheck'] = $true }

# --- 1. Look for a machine-readable spec ------------------------------------

Write-Host 'Step 1: looking for an OpenAPI spec...' -ForegroundColor White

$specCandidates = @(
    "$base/openapi.json"
    "$base/swagger.json"
    "$base/docs/openapi.json"
    "$($prof.BaseUrl)/proxy/protect/integration/openapi.json"
    "$($prof.BaseUrl)/proxy/protect/integration/v1/api-docs"
)

$spec = $null
foreach ($url in $specCandidates) {
    Write-Verbose "GET $url"
    $r = Invoke-WebRequest -Uri $url -Method GET @common
    if ($null -ne $r -and [int]$r.StatusCode -eq 200 -and $r.Content -match '"(openapi|swagger)"') {
        Write-Host "  Found spec: $url" -ForegroundColor Green
        try { $spec = $r.Content | ConvertFrom-Json } catch { Write-Warning "  Spec at $url did not parse: $($_.Exception.Message)" }
        if ($spec) {
            if ($SaveSpec) {
                $out = Join-Path $PSScriptRoot '..' 'reference' 'protect-openapi.json'
                New-Item -ItemType Directory -Force -Path (Split-Path $out) | Out-Null
                $r.Content | Set-Content -LiteralPath $out -Encoding utf8
                Write-Host "  Saved to $out" -ForegroundColor Green
            }
            break
        }
    }
    else {
        $code = $null -ne $r ? [int]$r.StatusCode : 'no response'
        Write-Verbose "  $code"
    }
}

if ($spec -and $spec.PSObject.Properties.Name -contains 'paths') {
    $posPaths = $spec.paths.PSObject.Properties |
        Where-Object { $_.Name -match '(?i)pos|point.of.sale|transaction' }

    if ($posPaths) {
        Write-Host ''
        Write-Host 'POS-related paths found in the spec:' -ForegroundColor Green
        foreach ($p in $posPaths) {
            foreach ($method in $p.Value.PSObject.Properties) {
                $op = $method.Value
                $summary = $op.PSObject.Properties.Name -contains 'summary' ? $op.summary : ''
                Write-Host ("  {0,-6} {1}  {2}" -f $method.Name.ToUpper(), $p.Name, $summary) -ForegroundColor White
            }
        }
        Write-Host ''
        Write-Host 'Use the path above in Send-PosEvent.ps1 -EndpointPath.' -ForegroundColor Cyan
        return
    }

    Write-Host '  Spec retrieved but it contains no POS-related paths.' -ForegroundColor Yellow
    Write-Host '  Your Protect version may predate POS ingestion. Check Settings > Updates.' -ForegroundColor Yellow
}
else {
    Write-Host '  No OpenAPI spec served by the console. Falling back to path probing.' -ForegroundColor Yellow
}

# --- 2. Probe candidate paths -----------------------------------------------

Write-Host ''
Write-Host 'Step 2: probing candidate paths...' -ForegroundColor White

$cameraId = $cfg.pos.cameraId
if ([string]::IsNullOrWhiteSpace($cameraId)) {
    $cams = @(Invoke-UnifiRequest -Profile $prof -Application protect -Path '/cameras' | Expand-UnifiResponse)

    if ($cams.Count -gt 0) {
        $cameraId = Get-UnifiProperty $cams[0] -Name 'id', '_id', 'cameraId'
        $camName = Get-UnifiProperty $cams[0] -Name 'name', 'displayName'
        if ($cameraId) {
            Write-Host "  Using camera '$camName' ($cameraId) for path probes" -ForegroundColor DarkGray
        }
        else {
            Write-Host '  Could not find an id field on the camera object. Fields present:' -ForegroundColor Yellow
            Write-Host "    $(@($cams[0].PSObject.Properties.Name) -join ', ')" -ForegroundColor Yellow
        }
    }
    else {
        Write-Host '  No cameras returned; camera-scoped paths will be skipped.' -ForegroundColor Yellow
    }
}

$candidates = @(
    '/pos/events'
    '/pos/transactions'
    '/pos/transaction'
    '/pos'
    '/point-of-sale/events'
    '/point-of-sale/transactions'
    '/point-of-sale'
    '/events/pos'
    '/events'
    '/transactions'
)
if ($cameraId) {
    $candidates += @(
        "/cameras/$cameraId/pos"
        "/cameras/$cameraId/pos-event"
        "/cameras/$cameraId/pos-events"
        "/cameras/$cameraId/pos/events"
        "/cameras/$cameraId/pos/transactions"
        "/cameras/$cameraId/pos-transaction"
        "/cameras/$cameraId/transactions"
        "/cameras/$cameraId/events"
    )
}
# The Alarm Manager webhook is the documented fallback transport for POS triggers.
$candidates += "/alarm-manager/webhook/$($cfg.pos.alarmTriggerId)"

# OPTIONS is deliberately not probed. Verified 18 Oct 2026: this console answers OPTIONS
# from generic CORS middleware with an identical "HEAD, GET, DELETE, PATCH, POST, PUT"
# Allow header on every path, including confirmed 404s. It carries no routing information.

$findings = [System.Collections.Generic.List[object]]::new()

function Invoke-Probe {
    <#  One throttled GET. Returns the status code, or -1 if there was no response.
        Retries a 429 once after a full window, so a transient limit does not poison
        the result the way it did on the first run. #>
    param([string] $Url)

    for ($attempt = 1; $attempt -le 2; $attempt++) {
        Wait-UnifiRateLimit
        $r = Invoke-WebRequest -Uri $Url -Method GET @common
        $code = $null -ne $r ? [int]$r.StatusCode : -1

        if ($code -ne 429) { return $code }
        Write-Verbose "429 on $Url, waiting out the window"
        Start-Sleep -Milliseconds 1200
    }
    return 429
}

$i = 0
foreach ($path in $candidates) {
    $i++
    Write-Progress -Activity 'Probing candidate paths' -Status $path -PercentComplete (100 * $i / $candidates.Count)

    $getCode = Invoke-Probe -Url "$base$path"

    $verdict = switch ($getCode) {
        200 { 'EXISTS (readable)' }
        204 { 'EXISTS (no content)' }
        400 { 'EXISTS, GET rejected as malformed -> likely a POST endpoint' }
        405 { 'EXISTS, GET not allowed -> POST ingestion path' }
        401 { 'auth rejected' }
        403 { 'exists, key lacks scope' }
        404 { 'not found' }
        429 { 'RATE LIMITED, result unknown' }
        -1 { 'no response' }
        default { "HTTP $getCode" }
    }

    $findings.Add([PSCustomObject]@{ Path = $path; GET = $getCode; Verdict = $verdict })
}
Write-Progress -Activity 'Probing candidate paths' -Completed

Write-Host ''
$findings | Sort-Object { $_.GET -eq 404 }, Path |
    Format-Table -AutoSize -Property Path, GET, Verdict |
    Out-String -Width 200 | Write-Host

$hits = @($findings | Where-Object { $_.GET -in 200, 204, 400, 405, 403 -or ($_.Allow -and $_.Allow -match 'POST') })

if ($hits.Count -gt 0) {
    Write-Host 'Candidate endpoint(s) found:' -ForegroundColor Green
    foreach ($h in $hits) {
        $extra = $h.Allow ? "  [Allow: $($h.Allow)]" : ''
        Write-Host "  $($h.Path)  ->  $($h.Verdict)$extra" -ForegroundColor White
    }
    Write-Host ''
    Write-Host "Try: ./Send-PosEvent.ps1 -Transport pos -EndpointPath `"$($hits[0].Path)`" -WhatIf" -ForegroundColor Cyan
}
else {
    Write-Host 'No candidate path responded as existing.' -ForegroundColor Yellow
}

# --- 3. Reconnaissance ------------------------------------------------------

# If the guesses missed, the most useful thing is a picture of what this console actually
# exposes. Field names and metadata often name the feature even when the path does not.

Write-Host ''
Write-Host 'Step 3: reconnaissance (share this output to pin down the endpoint)' -ForegroundColor White
Write-Host '-------------------------------------------------------------------' -ForegroundColor White

Write-Host ''
Write-Host 'meta/info:' -ForegroundColor Cyan
try {
    Invoke-UnifiRequest -Profile $prof -Application protect -Path '/meta/info' |
        ConvertTo-Json -Depth 6 | Write-Host
}
catch { Write-Host "  failed: $($_.Exception.Message)" -ForegroundColor Red }

Write-Host ''
Write-Host 'First camera, field names only (no values, to avoid leaking site detail):' -ForegroundColor Cyan
try {
    $c = @(Invoke-UnifiRequest -Profile $prof -Application protect -Path '/cameras' | Expand-UnifiResponse)
    if ($c.Count -gt 0) {
        Write-Host "  $(@($c[0].PSObject.Properties.Name) -join ', ')"
        $posish = @($c[0].PSObject.Properties.Name) | Where-Object { $_ -match '(?i)pos|transaction|overlay|retail' }
        if ($posish) {
            Write-Host "  POS-related fields present: $($posish -join ', ')" -ForegroundColor Green
            foreach ($f in $posish) {
                Write-Host "    $f = $($c[0].$f | ConvertTo-Json -Depth 4 -Compress)" -ForegroundColor Green
            }
        }
        else {
            Write-Host '  No POS-related field names on the camera object.' -ForegroundColor Yellow
        }
    }
}
catch { Write-Host "  failed: $($_.Exception.Message)" -ForegroundColor Red }

Write-Host ''
Write-Host 'Top-level collections that exist on this console:' -ForegroundColor Cyan
foreach ($coll in 'cameras', 'nvrs', 'viewers', 'lights', 'sensors', 'chimes', 'bridges', 'liveviews', 'alarm-manager', 'files', 'subscribe/events', 'device-assets') {
    $r = Invoke-WebRequest -Uri "$base/$coll" -Method GET @common
    $code = $null -ne $r ? [int]$r.StatusCode : -1
    $mark = $code -in 200, 204 ? 'yes' : ($code -eq 404 ? 'no' : "HTTP $code")
    Write-Host ("  {0,-18} {1}" -f $coll, $mark)
}

Write-Host ''
Write-Host 'If nothing above names the POS endpoint, read it from the console UI:' -ForegroundColor Yellow
Write-Host '  https://unifi.ui.com/consoles/<id>/unifi-api/protect  (log in, open' -ForegroundColor White
Write-Host '  "Point-of-sale event ingestion", copy the method and path), then:' -ForegroundColor White
Write-Host '    ./Send-PosEvent.ps1 -Transport pos -EndpointPath "/the/real/path" -WhatIf' -ForegroundColor White
