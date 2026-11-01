#requires -Version 7.0
<#
.SYNOPSIS
    Send point-of-sale transactions to UniFi Protect, live (demo) or in batches (high volume).

.DESCRIPTION
    Calls the Protect Integration API endpoint
        POST /proxy/protect/integration/v1/pos/cameras/{cameraId}/transactions

    Two modes:

      Live (default)  Each transaction is stamped with the actual send time. Optional pauses
                      between transactions (delayBeforeSeconds / -DelaySeconds). Made for demos.

      Batch (-Batch)  Each transaction keeps its real sale time (saleTime or timestamp in the
                      JSON), so the tag lands at the right moment on recorded footage even when
                      sent hours later. Paced below the rate limit, retried on 429/409/5xx,
                      checked against the 24 h window, and de-duplicated with a local ledger.

    Request bodies come from JSON:
      - a file holding one transaction { ... } or many [ { ... }, { ... } ]
      - a folder: every *.json in it, in name order
      - pasted in, if the path is not found

    Script-only JSON keys (read by this script, stripped before sending):
      customerMobile       unique customer identifier, used to build externalId
      delayBeforeSeconds   live mode only: pause before this transaction
      saleTime             when the sale happened: ISO 8601 ("2026-10-31T18:10:00+11:00"),
                           or relative "yesterday 18:10" / "today 09:30" (local time)
      cameraName           route this transaction to the camera with this name (multi-till)

    The API key is typed in masked and never saved. Camera IDs, event IDs and mobiles are
    masked on screen unless -ShowIds.

.PARAMETER Batch
    High-volume mode. See DESCRIPTION.

.PARAMETER MaxPerSecond
    Batch pacing. Default 8, hard cap 10 (the console's limit).

.PARAMETER MaxRetries
    Attempts per transaction on 429, 409, 5xx or network errors. Default 5.

.PARAMETER MaxAgeMinutes
    Reject transactions older than this before sending. Default 1435 (24 h minus a 5 min
    safety margin). The API rejects anything older than 24 h.

.PARAMETER LedgerPath
    Batch de-dupe ledger (externalIds already sent). Default .sent-ledger.json next to the
    script; it is git-ignored. Delete it to allow a full re-send.

.EXAMPLE
    ./Send-PosTransaction.ps1 -BodyPath .\samples\dry-clean -DryRun

.EXAMPLE
    ./Send-PosTransaction.ps1 -Batch -BodyPath .\samples\dry-clean-yesterday

.EXAMPLE
    ./Send-PosTransaction.ps1 -Batch -BodyPath .\samples\high-volume\generated-batch.json -MaxPerSecond 8
#>
[CmdletBinding()]
param(
    [string] $ConsoleAddress = 'https://192.168.1.1',
    [switch] $PromptConsole,

    [string] $BodyPath = (Join-Path $PSScriptRoot 'pos-transaction.sample.json'),

    [Alias('KeepJsonIds')]
    [switch] $KeepExternalId,

    [ValidateRange(0, 600)]
    [int] $DelaySeconds = 5,

    [switch] $Batch,

    [ValidateRange(0.1, 10)]
    [double] $MaxPerSecond = 8,

    [ValidateRange(1, 10)]
    [int] $MaxRetries = 5,

    [ValidateRange(1, 1440)]
    [int] $MaxAgeMinutes = 1435,

    [string] $LedgerPath = (Join-Path $PSScriptRoot '.sent-ledger.json'),

    [ValidateSet('sale', 'refund')]
    [string] $Type,

    [ValidateRange(0, [double]::MaxValue)]
    [double] $Amount,

    [ValidatePattern('^[A-Z]{3}$')]
    [string] $Currency,

    [string] $LocationId,
    [string] $LocationName,

    [switch] $DryRun,
    [switch] $ShowIds,

    # Consoles use a self-signed cert on the LAN. Equivalent of curl -k.
    [bool] $SkipCertificateCheck = $true
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# API limits (Protect 7.3.70 spec).
$script:ApiMaxAgeHours      = 24
$script:ApiMaxFutureMinutes = 5
$script:ApiMaxLineItems     = 200
$script:ApiMaxPaymentTypes  = 20
$script:ApiMaxIdLength      = 255

$script:Bound = $PSBoundParameters

# ---------------------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------------------

function Read-Masked([string] $Prompt) {
    $secure = Read-Host -Prompt $Prompt -AsSecureString
    $plain = [System.Net.NetworkCredential]::new('', $secure).Password
    if ([string]::IsNullOrWhiteSpace($plain)) { throw "$Prompt is required." }
    return $plain.Trim()
}

function Format-Id([string] $Id) {
    if ($ShowIds -or [string]::IsNullOrEmpty($Id)) { return $Id }
    if ($Id.Length -le 4) { return '****' }
    return ('*' * 8) + $Id.Substring($Id.Length - 4)
}

function Format-Mobile([string] $Text) {
    # 0491570156 -> 0491***156 in anything printed to screen.
    if ($ShowIds -or [string]::IsNullOrEmpty($Text)) { return $Text }
    return [regex]::Replace($Text, '(?<!\d)(\+?\d{4})\d{3}(\d{3})(?!\d)', '$1***$2')
}

function Read-PastedJson {
    Write-Host 'Paste the request JSON, then press Enter on an empty line:' -ForegroundColor Yellow
    $lines = [System.Collections.Generic.List[string]]::new()
    while ($true) {
        $line = Read-Host
        if ([string]::IsNullOrWhiteSpace($line)) {
            if ($lines.Count -gt 0) { break } else { continue }
        }
        $lines.Add($line)
    }
    return ($lines -join "`n")
}

function Resolve-SaleTime($Value, [string] $Name) {
    if ($null -eq $Value -or "$Value" -eq '') { return $null }
    # ConvertFrom-Json turns ISO strings into DateTime already; keep the instant.
    if ($Value -is [DateTime]) { return [DateTimeOffset]::new($Value) }
    if ($Value -is [DateTimeOffset]) { return $Value }
    if ($Value -is [long] -or $Value -is [int] -or $Value -is [double]) {
        return [DateTimeOffset]::FromUnixTimeMilliseconds([long] $Value)
    }
    $s = "$Value".Trim()
    if ($s -match '^(today|yesterday)\s+(\d{1,2}):(\d{2})$') {
        $day = if ($Matches[1] -eq 'yesterday') { [DateTime]::Today.AddDays(-1) } else { [DateTime]::Today }
        $local = $day.AddHours([int] $Matches[2]).AddMinutes([int] $Matches[3])
        return [DateTimeOffset]::new($local)
    }
    $parsed = [DateTimeOffset]::MinValue
    if ([DateTimeOffset]::TryParse($s, [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeLocal, [ref] $parsed)) {
        return $parsed
    }
    throw "${Name}: saleTime '$s' not understood. Use ISO 8601 or 'yesterday HH:mm' / 'today HH:mm'."
}

# ---------------------------------------------------------------------------------------
# Load and validate transactions
# ---------------------------------------------------------------------------------------

function Test-IsNumber($v) { return ($v -is [int] -or $v -is [long] -or $v -is [double] -or $v -is [decimal]) }

function Assert-PosBody([System.Collections.IDictionary] $Body, [string] $Name, [switch] $Final) {
    <#  Mirrors the API's posTransactionRequest schema (Protect 7.3.70), so a bad payload fails
        here with a clear message instead of a 400. -Final also requires externalId and
        timestamp, which the script adds just before sending. #>
    $allowed = 'type', 'externalId', 'amount', 'currency', 'lineItems', 'location', 'paymentTypes', 'timestamp'
    $unknown = @($Body.Keys | Where-Object { $_ -notin $allowed })
    if ($unknown.Count) { throw "${Name}: unknown field(s) $($unknown -join ', '). Allowed: $($allowed -join ', ')." }

    # type: required, enum
    if (-not $Body.Contains('type')) { throw "${Name}: missing required field 'type'." }
    if ($Body['type'] -cnotin 'sale', 'refund') { throw "${Name}: type must be 'sale' or 'refund' (lowercase)." }

    # amount: required, number >= 0
    if (-not $Body.Contains('amount')) { throw "${Name}: missing required field 'amount'." }
    if (-not (Test-IsNumber $Body['amount'])) { throw "${Name}: amount must be a number, not text." }
    if ([double] $Body['amount'] -lt 0) { throw "${Name}: amount must be >= 0." }

    # externalId: required at send, string 1-255
    if ($Body.Contains('externalId')) {
        $id = $Body['externalId']
        if ($id -isnot [string] -or $id.Length -lt 1 -or $id.Length -gt $script:ApiMaxIdLength) { throw "${Name}: externalId must be text, 1-255 characters." }
    }
    elseif ($Final) { throw "${Name}: missing required field 'externalId'." }

    # currency: optional, exactly 3 uppercase letters
    if ($Body.Contains('currency') -and ($Body['currency'] -isnot [string] -or $Body['currency'] -cnotmatch '^[A-Z]{3}$')) {
        throw "${Name}: currency must be 3 uppercase letters, e.g. AUD."
    }

    # lineItems: optional, <= 200 of { title 1-255, quantity integer >= 1 }, nothing else
    if ($Body.Contains('lineItems')) {
        $li = $Body['lineItems']
        if ($li -isnot [System.Collections.IList]) { throw "${Name}: lineItems must be an array." }
        if ($li.Count -gt $script:ApiMaxLineItems) { throw "${Name}: more than $script:ApiMaxLineItems line items." }
        foreach ($l in $li) {
            if ($l -isnot [System.Collections.IDictionary]) { throw "${Name}: each line item must be an object." }
            $extra = @($l.Keys | Where-Object { $_ -notin 'title', 'quantity' })
            if ($extra.Count) { throw "${Name}: line item field(s) $($extra -join ', ') not allowed. Only title and quantity." }
            $t = $l['title']
            if ($t -isnot [string] -or $t.Trim().Length -lt 1 -or $t.Length -gt 255) { throw "${Name}: line item title must be text, 1-255 characters." }
            $q = $l['quantity']
            if (-not (Test-IsNumber $q) -or [double] $q -ne [math]::Floor([double] $q) -or [double] $q -lt 1) {
                throw "${Name}: line item '$t' quantity must be a whole number >= 1."
            }
            $l['quantity'] = [long] $q   # send as an integer
        }
    }

    # location: optional, { id 1-255 required, name 1-255 optional }, nothing else
    if ($Body.Contains('location')) {
        $loc = $Body['location']
        if ($loc -isnot [System.Collections.IDictionary]) { throw "${Name}: location must be an object." }
        $extra = @($loc.Keys | Where-Object { $_ -notin 'id', 'name' })
        if ($extra.Count) { throw "${Name}: location field(s) $($extra -join ', ') not allowed. Only id and name." }
        if ($loc['id'] -isnot [string] -or $loc['id'].Length -lt 1 -or $loc['id'].Length -gt 255) { throw "${Name}: location.id is required, text, 1-255 characters." }
        if ($loc.Contains('name') -and ($loc['name'] -isnot [string] -or $loc['name'].Length -lt 1 -or $loc['name'].Length -gt 255)) {
            throw "${Name}: location.name must be text, 1-255 characters."
        }
    }

    # paymentTypes: optional, <= 20 strings of 1-255
    if ($Body.Contains('paymentTypes')) {
        $pt = $Body['paymentTypes']
        if ($pt -isnot [System.Collections.IList]) { throw "${Name}: paymentTypes must be an array of text." }
        if ($pt.Count -gt $script:ApiMaxPaymentTypes) { throw "${Name}: more than $script:ApiMaxPaymentTypes payment types." }
        foreach ($x in $pt) {
            if ($x -isnot [string] -or $x.Length -lt 1 -or $x.Length -gt 255) { throw "${Name}: each payment type must be text, 1-255 characters." }
        }
    }

    # timestamp: required at send, integer epoch ms >= 1
    if ($Body.Contains('timestamp')) {
        $ts = $Body['timestamp']
        if (-not ($ts -is [int] -or $ts -is [long]) -or $ts -lt 1) { throw "${Name}: timestamp must be whole epoch milliseconds." }
    }
    elseif ($Final) { throw "${Name}: missing timestamp." }
}

function ConvertTo-PosItem([System.Collections.IDictionary] $Obj, [string] $Name) {
    $mobile = $null; $delay = $null; $saleTime = $null; $cameraName = $null

    if ($Obj.Contains('customerMobile')) {
        $mobile = ("$($Obj['customerMobile'])" -replace '[\s\-()]', '')
        if ($mobile -notmatch '^\+?\d{8,15}$') { throw "${Name}: customerMobile '$mobile' is not a valid phone number." }
        $Obj.Remove('customerMobile')
    }
    if ($Obj.Contains('delayBeforeSeconds')) { $delay = [int] $Obj['delayBeforeSeconds']; $Obj.Remove('delayBeforeSeconds') }
    if ($Obj.Contains('cameraName'))        { $cameraName = "$($Obj['cameraName'])"; $Obj.Remove('cameraName') }
    if ($Obj.Contains('saleTime'))          { $saleTime = Resolve-SaleTime $Obj['saleTime'] $Name; $Obj.Remove('saleTime') }
    elseif ($Obj.Contains('timestamp'))     { $saleTime = Resolve-SaleTime $Obj['timestamp'] $Name; $Obj.Remove('timestamp') }   # re-set at send time
    foreach ($k in @($Obj.Keys | Where-Object { $_ -like '$*' })) { $Obj.Remove($k) }

    # Command-line overrides (only when explicitly passed).
    if ($script:Bound.ContainsKey('Type'))     { $Obj['type'] = $Type }
    if ($script:Bound.ContainsKey('Amount'))   { $Obj['amount'] = [math]::Round($Amount, 2) }
    if ($script:Bound.ContainsKey('Currency')) { $Obj['currency'] = $Currency }
    if ($script:Bound.ContainsKey('LocationId') -or $script:Bound.ContainsKey('LocationName')) {
        $loc = if ($Obj['location'] -is [System.Collections.IDictionary]) { $Obj['location'] } else { [ordered]@{} }
        if ($LocationId)   { $loc['id'] = $LocationId }
        if ($LocationName) { $loc['name'] = $LocationName }
        $Obj['location'] = $loc
    }

    Assert-PosBody $Obj $Name
    if ($KeepExternalId -and -not $Obj.Contains('externalId')) { throw "${Name}: -KeepExternalId needs externalId in the JSON." }

    [pscustomobject]@{
        Name = $Name; Body = $Obj; Mobile = $mobile; Delay = $delay
        SaleTime = $saleTime; CameraName = $cameraName
    }
}

function Add-ParsedJson($List, [string] $Raw, [string] $Source) {
    try { $parsed = ConvertFrom-Json -InputObject $Raw -AsHashtable -NoEnumerate }
    catch { throw "${Source}: invalid JSON. $($_.Exception.Message)" }

    if ($parsed -is [System.Collections.IDictionary]) {
        $List.Add((ConvertTo-PosItem $parsed $Source))
    }
    elseif ($parsed -is [System.Collections.IList]) {
        $i = 0
        foreach ($o in $parsed) {
            $i++
            if ($o -isnot [System.Collections.IDictionary]) { throw "${Source}[$i]: each array entry must be an object." }
            $List.Add((ConvertTo-PosItem $o "$Source[$i]"))
        }
    }
    else { throw "${Source}: JSON must be an object or an array of objects." }
}

function Get-PosItems {
    $list = [System.Collections.Generic.List[object]]::new()
    if (Test-Path -LiteralPath $BodyPath -PathType Container) {
        $files = @(Get-ChildItem -LiteralPath $BodyPath -Filter *.json -File | Sort-Object Name)
        if ($files.Count -eq 0) { throw "No .json files in folder: $BodyPath" }
        Write-Host "Source: folder $(Split-Path -Leaf $BodyPath) ($($files.Count) files)" -ForegroundColor DarkGray
        foreach ($f in $files) { Add-ParsedJson $list (Get-Content -LiteralPath $f.FullName -Raw) $f.Name }
    }
    elseif (Test-Path -LiteralPath $BodyPath -PathType Leaf) {
        Write-Host "Source: file $(Split-Path -Leaf $BodyPath)" -ForegroundColor DarkGray
        Add-ParsedJson $list (Get-Content -LiteralPath $BodyPath -Raw) (Split-Path -Leaf $BodyPath)
    }
    else {
        Write-Host "JSON file not found: $BodyPath" -ForegroundColor Yellow
        Add-ParsedJson $list (Read-PastedJson) 'pasted'
    }
    if ($list.Count -eq 0) { throw 'No transactions found.' }
    return , $list
}

# ---------------------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------------------

function Invoke-Protect {
    param([string] $Method, [string] $Path, $Body)
    $shownPath = [regex]::Replace($Path, '/cameras/([^/]+)', { param($m) '/cameras/' + (Format-Id $m.Groups[1].Value) })

    $req = @{
        Method               = $Method
        Uri                  = "$script:ApiBase$Path"
        Headers              = @{ 'X-API-KEY' = $script:ApiKey; 'Accept' = 'application/json' }
        SkipCertificateCheck = $SkipCertificateCheck
        TimeoutSec           = 20
        MaximumRedirection   = 0
    }
    if ($null -ne $Body) {
        $req.Body = ($Body | ConvertTo-Json -Depth 10 -Compress)
        $req.ContentType = 'application/json'
    }

    try {
        return Invoke-RestMethod @req
    }
    catch {
        $status = $null; $detail = $null; $retryAfter = $null
        if ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response) {
            $resp = $_.Exception.Response
            $status = [int] $resp.StatusCode
            try { if ($resp.Headers.RetryAfter.Delta) { $retryAfter = $resp.Headers.RetryAfter.Delta.TotalSeconds } } catch { }
        }
        if ($_.ErrorDetails) { $detail = $_.ErrorDetails.Message }
        if ($detail -and -not $ShowIds) {
            # Response bodies echo ids back; mask them on screen.
            $detail = [regex]::Replace($detail, '\b[0-9a-f]{24}\b', { param($m) Format-Id $m.Value })
        }
        if (-not $status -and -not $detail) { $detail = $_.Exception.Message }
        $hint = switch ($status) {
            401 { 'API key rejected. Create it on this console: Settings > Control Plane > Integrations.' }
            403 { 'Key is valid but lacks write access to this camera.' }
            404 { if ("$detail" -match 'camera') { 'Camera id not found on this console. Re-run and pick the camera again.' } else { 'Path not found. Check the console address and that Protect is 7.3 or later.' } }
            409 { 'Same externalId is already being processed.' }
            429 { 'Rate limited. Lower -MaxPerSecond.' }
            400 { 'Payload rejected. Check timestamp window (last 24 h), currency, amount, line items.' }
            default { '' }
        }
        $msg = "$Method $shownPath failed"
        if ($status) { $msg += " (HTTP $status)" }
        if ($detail) { $msg += "`n  Response: $detail" }
        if ($hint)   { $msg += "`n  Hint: $hint" }
        $ex = [System.Exception]::new($msg)
        $ex.Data['Status'] = $status
        $ex.Data['RetryAfter'] = $retryAfter
        throw $ex
    }
}

function Send-WithRetry([string] $Path, $Body) {
    for ($attempt = 1; ; $attempt++) {
        try {
            return Invoke-Protect -Method POST -Path $Path -Body $Body
        }
        catch {
            $status = $_.Exception.Data['Status']
            $retryable = ($null -eq $status) -or ($status -in 409, 429, 500, 502, 503, 504)
            if (-not $retryable -or $attempt -ge $MaxRetries) { throw }
            $wait = $_.Exception.Data['RetryAfter']
            if (-not $wait) { $wait = [math]::Min(30, [math]::Pow(2, $attempt - 1)) }   # 1, 2, 4, 8, 16 s
            Write-Host ("   retry {0}/{1} in {2}s (HTTP {3})" -f $attempt, ($MaxRetries - 1), $wait, ($status ?? 'network')) -ForegroundColor DarkYellow
            Start-Sleep -Milliseconds ([int] ($wait * 1000))
        }
    }
}

# ---------------------------------------------------------------------------------------
# Ledger (batch de-dupe)
# ---------------------------------------------------------------------------------------

function Get-Ledger {
    if ($Batch -and (Test-Path -LiteralPath $LedgerPath)) {
        try { return (Get-Content -LiteralPath $LedgerPath -Raw | ConvertFrom-Json -AsHashtable) ?? @{} }
        catch { Write-Host "Ledger unreadable, starting a new one: $LedgerPath" -ForegroundColor Yellow }
    }
    return @{}
}

function Save-Ledger($Ledger) {
    if (-not $Batch -or $DryRun -or -not $script:LedgerDirty) { return }
    $Ledger | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $LedgerPath -Encoding utf8
    $script:LedgerDirty = $false
}

# ---------------------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------------------

$ledger = @{}
$script:LedgerDirty = $false

try {
    Write-Host ''
    Write-Host 'UniFi Protect | Point-of-sale event ingestion' -ForegroundColor Cyan
    Write-Host ("Mode: {0}" -f ($Batch ? "batch (sale time kept, max $MaxPerSecond/s, $MaxRetries attempts)" : 'live (send time)')) -ForegroundColor DarkGray
    Write-Host ''

    if ($MaxPerSecond -gt 10) { throw '-MaxPerSecond cannot exceed 10.' }

    # 1. Load and validate everything before asking for the key ---------------------------
    $items = Get-PosItems
    Write-Host "Transactions: $($items.Count)" -ForegroundColor DarkGray
    if ($Batch) {
        $missing = @($items | Where-Object { $null -eq $_.SaleTime })
        if ($missing.Count -gt 0) { throw "Batch mode needs saleTime or timestamp on every transaction. Missing: $($missing[0].Name)" }
    }

    # 2. Connection ------------------------------------------------------------------------
    $console = if ($PromptConsole) { Read-Masked 'Console address (e.g. https://192.168.1.1)' } else { $ConsoleAddress }
    if ($console -notmatch '^https?://') { $console = "https://$console" }
    $script:ApiBase = $console.TrimEnd('/') + '/proxy/protect/integration'
    if (-not $PromptConsole) { Write-Host 'Console: local default' -ForegroundColor DarkGray }
    $script:ApiKey = Read-Masked 'Protect API key'

    # 3. Cameras: by name per transaction, or one picked camera -----------------------------
    Write-Host ''
    Write-Host 'GET /v1/cameras' -ForegroundColor Yellow
    # Invoke-RestMethod returns a JSON array as one object; enumerate it into single cameras.
    $cameras = @(Invoke-Protect -Method GET -Path '/v1/cameras' | ForEach-Object { $_ } |
        Where-Object { $_ -and $_.PSObject.Properties['id'] -and $_.id -is [string] })
    if ($cameras.Count -eq 0) { throw 'No cameras returned for this key.' }

    $byName = @{}
    foreach ($c in $cameras) { $byName[$c.name.ToLowerInvariant()] = $c }

    $defaultCamera = $null
    if (@($items | Where-Object { -not $_.CameraName }).Count -gt 0) {
        for ($i = 0; $i -lt $cameras.Count; $i++) {
            $c = $cameras[$i]
            '  [{0}] {1,-28} {2,-12} {3}' -f ($i + 1), $c.name, $c.state, (Format-Id $c.id) | Write-Host
        }
        $pick = Read-Host "Camera number (1-$($cameras.Count))"
        $idx = 0
        if (-not [int]::TryParse($pick, [ref] $idx) -or $idx -lt 1 -or $idx -gt $cameras.Count) { throw "Invalid choice: $pick" }
        $defaultCamera = $cameras[$idx - 1]
    }
    else {
        Write-Host 'Every transaction names its camera (multi-till routing).' -ForegroundColor DarkGray
    }

    $ledger = Get-Ledger

    # 4. Send ------------------------------------------------------------------------------
    $stats = [ordered]@{ created = 0; duplicateOnServer = 0; skippedInLedger = 0; rejected = 0; failed = 0 }
    $minInterval = [TimeSpan]::FromSeconds(1.0 / $MaxPerSecond)
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $nextSlot = [TimeSpan]::Zero
    $n = 0

    foreach ($item in $items) {
        $n++
        $body = $item.Body
        $tag = "[{0}/{1}]" -f $n, $items.Count

        # Camera for this transaction
        $camera = $defaultCamera
        if ($item.CameraName) {
            $camera = $byName[$item.CameraName.ToLowerInvariant()]
            if (-not $camera) {
                Write-Host "$tag REJECTED $($item.Name): no camera named '$($item.CameraName)'" -ForegroundColor Red
                $stats.rejected++; continue
            }
        }

        if ($Batch) {
            # Real sale time, checked against the API window
            $now = [DateTimeOffset]::Now
            $ageMin = ($now - $item.SaleTime).TotalMinutes
            if ($ageMin -gt $MaxAgeMinutes) {
                Write-Host ("$tag REJECTED {0}: sale {1:yyyy-MM-dd HH:mm} is {2:N1} h old (limit {3:N1} h)" -f $item.Name, $item.SaleTime.LocalDateTime, ($ageMin / 60), ($MaxAgeMinutes / 60)) -ForegroundColor Red
                $stats.rejected++; continue
            }
            if ($ageMin -lt -$script:ApiMaxFutureMinutes) {
                Write-Host ("$tag REJECTED {0}: sale {1:yyyy-MM-dd HH:mm} is more than {2} min in the future" -f $item.Name, $item.SaleTime.LocalDateTime, $script:ApiMaxFutureMinutes) -ForegroundColor Red
                $stats.rejected++; continue
            }
            $body['timestamp'] = $item.SaleTime.ToUnixTimeMilliseconds()

            # Stable externalId so a re-run is recognised as the same transaction
            if (-not $body.Contains('externalId') -or "$($body['externalId'])" -eq '') {
                $prefix = $item.Mobile ?? 'POS'
                $body['externalId'] = '{0}-{1}' -f $prefix, $item.SaleTime.LocalDateTime.ToString('yyyyMMdd-HHmmssfff')
            }

            $key = "$($camera.id)|$($body['externalId'])"
            if ($ledger.ContainsKey($key)) {
                Write-Host ("$tag skip   {0}  already sent" -f (Format-Mobile $body['externalId'])) -ForegroundColor DarkGray
                $stats.skippedInLedger++; continue
            }

            # Pace below the rate limit
            $wait = $nextSlot - $clock.Elapsed
            if ($wait -gt [TimeSpan]::Zero) { Start-Sleep -Milliseconds ([int] $wait.TotalMilliseconds) }
            $nextSlot = $clock.Elapsed + $minInterval
        }
        else {
            # Live demo: pauses, then actual send time
            $pause = if ($script:Bound.ContainsKey('DelaySeconds')) { $DelaySeconds } elseif ($null -ne $item.Delay) { $item.Delay } else { $DelaySeconds }
            if ($n -gt 1 -and $pause -gt 0 -and -not $DryRun) {
                for ($s = $pause; $s -gt 0; $s--) {
                    Write-Host "`rNext transaction in $s s " -NoNewline -ForegroundColor DarkGray
                    Start-Sleep -Seconds 1
                }
                Write-Host ''
            }
            elseif ($n -gt 1 -and $DryRun) { Write-Host "(would wait $pause s)" -ForegroundColor DarkGray }

            $sendTime = [DateTimeOffset]::UtcNow
            if (-not $KeepExternalId) {
                $prefix = $item.Mobile ?? 'DEMO'
                $body['externalId'] = '{0}-{1}' -f $prefix, $sendTime.ToLocalTime().ToString('yyyyMMdd-HHmmssfff')
            }
            $body['timestamp'] = $sendTime.ToUnixTimeMilliseconds()
        }

        if ($null -eq $camera -or $camera -is [array] -or $camera.id -isnot [string] -or $camera.id -match '\s') {
            throw 'Internal error: camera not resolved to a single camera id. Nothing sent.'
        }

        try { Assert-PosBody $body $item.Name -Final }
        catch { Write-Host "$tag REJECTED $($_.Exception.Message)" -ForegroundColor Red; $stats.rejected++; continue }

        $path = "/v1/pos/cameras/$($camera.id)/transactions"
        $when = [DateTimeOffset]::FromUnixTimeMilliseconds([long] $body['timestamp']).LocalDateTime
        $summary = '{0} {1,-6} {2} {3,8:N2}  {4:yyyy-MM-dd HH:mm:ss}  {5}' -f `
            (Format-Mobile $body['externalId']), $body['type'], ($body['currency'] ?? ''), [double] $body['amount'], $when, $camera.name

        if (-not $Batch -or $n -eq 1) {
            Write-Host ''
            Write-Host "$tag $($item.Name)" -ForegroundColor Cyan
            Write-Host "POST /v1/pos/cameras/$(Format-Id $camera.id)/transactions   (camera: $($camera.name))" -ForegroundColor Yellow
            Write-Host (Format-Mobile ($body | ConvertTo-Json -Depth 10))
            if ($Batch -and $items.Count -gt 1) { Write-Host '(remaining transactions shown one line each)' -ForegroundColor DarkGray }
        }

        if ($DryRun) {
            if ($Batch) { Write-Host "$tag plan   $summary" -ForegroundColor DarkGray }
            continue
        }

        try {
            $resp = Send-WithRetry -Path $path -Body $body
            if ($resp.created) {
                $stats.created++
                Write-Host "$tag ok     $summary  event $(Format-Id $resp.eventId)" -ForegroundColor Green
            }
            else {
                $stats.duplicateOnServer++
                Write-Host "$tag dup    $summary  (server already had it)" -ForegroundColor Yellow
            }
            if ($Batch) {
                $ledger["$($camera.id)|$($body['externalId'])"] = @{ eventId = $resp.eventId; sentAt = [DateTimeOffset]::Now.ToString('o') }
                $script:LedgerDirty = $true
                if (($stats.created + $stats.duplicateOnServer) % 50 -eq 0) { Save-Ledger $ledger }
            }
        }
        catch {
            $stats.failed++
            Write-Host "$tag FAILED $summary`n$($_.Exception.Message)" -ForegroundColor Red
        }
    }

    # 5. Summary ---------------------------------------------------------------------------
    $clock.Stop()
    Write-Host ''
    if ($DryRun) {
        Write-Host "Dry run: $($items.Count) transaction(s) checked, nothing sent. Rejected: $($stats.rejected), already in ledger: $($stats.skippedInLedger)." -ForegroundColor Yellow
        return
    }
    $done = $stats.created + $stats.duplicateOnServer
    $rate = if ($clock.Elapsed.TotalSeconds -gt 0) { $done / $clock.Elapsed.TotalSeconds } else { 0 }
    Write-Host ("Created {0} | Duplicate on server {1} | Skipped (ledger) {2} | Rejected {3} | Failed {4}" -f `
        $stats.created, $stats.duplicateOnServer, $stats.skippedInLedger, $stats.rejected, $stats.failed) `
        -ForegroundColor ($stats.failed + $stats.rejected -gt 0 ? 'Yellow' : 'Green')
    Write-Host ("Elapsed {0:mm\:ss}  ({1:N1} transactions/s)" -f $clock.Elapsed, $rate) -ForegroundColor DarkGray
    if ($stats.created -gt 0) { Write-Host 'Check the camera timeline in Protect at each sale time for the overlays.' -ForegroundColor Cyan }
    if ($stats.failed -gt 0) { exit 1 }
}
catch {
    Write-Host ''
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}
finally {
    Save-Ledger $ledger
    $script:ApiKey = $null
    $script:ApiBase = $null
}
