#requires -Version 7.0
<#
.SYNOPSIS
    Generate a high-volume batch of synthetic dry clean transactions for load testing.

.DESCRIPTION
    Writes one JSON array file that Send-PosTransaction.ps1 -Batch can send. Sales are spread
    across several tills over the last few hours, each with its real saleTime, so they land
    at the right moment on the footage. Nothing is sent by this script.

.PARAMETER Count
    Number of transactions. Default 500.

.PARAMETER Tills
    Number of tills (registers). Default 4.

.PARAMETER HoursBack
    Spread sales across this many hours ending 5 minutes ago. Max 23 so every sale is
    inside the API's 24 h window when sent soon after. Default 8.

.PARAMETER CameraNames
    Optional. One camera name per till, in till order (exact names as in Protect). When
    given, each transaction is routed to its till's camera. When omitted, the sender asks
    for one camera for everything.

.PARAMETER Mobiles
    Customer mobiles to cycle through as identifiers.

.PARAMETER RefundPercent
    Share of transactions that are refunds. Default 5.

.EXAMPLE
    ./New-PosBatch.ps1 -Count 1000 -Tills 6 -HoursBack 10

.EXAMPLE
    ./New-PosBatch.ps1 -Count 200 -Tills 2 -CameraNames 'Counter Left','Counter Right'
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 100000)] [int] $Count = 500,
    [ValidateRange(1, 100)]    [int] $Tills = 4,
    [ValidateRange(1, 23)]     [int] $HoursBack = 8,
    [string[]] $CameraNames,
    [string[]] $Mobiles = @('0491570156', '0491570157'),
    [ValidateRange(0, 100)]    [int] $RefundPercent = 5,
    [string] $Currency = 'AUD',
    [string] $OutPath = (Join-Path $PSScriptRoot 'samples' 'high-volume' 'generated-batch.json'),
    [int] $Seed
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($CameraNames -and $CameraNames.Count -ne $Tills) {
    throw "-CameraNames has $($CameraNames.Count) names but -Tills is $Tills. Give one name per till."
}

$rng = if ($PSBoundParameters.ContainsKey('Seed')) { [Random]::new($Seed) } else { [Random]::new() }

# Catalogue: title and unit price (AUD)
$catalogue = @(
    [pscustomobject]@{ Title = 'Business Shirt - Launder and Press'; Price = 4.50 },
    [pscustomobject]@{ Title = 'Two-Piece Suit - Dry Clean'; Price = 24.00 },
    [pscustomobject]@{ Title = 'Trousers - Dry Clean'; Price = 12.00 },
    [pscustomobject]@{ Title = 'Dress - Dry Clean'; Price = 22.00 },
    [pscustomobject]@{ Title = 'Wool Overcoat - Dry Clean'; Price = 32.00 },
    [pscustomobject]@{ Title = 'Tie - Dry Clean'; Price = 7.50 },
    [pscustomobject]@{ Title = 'Doona Queen - Clean'; Price = 45.00 },
    [pscustomobject]@{ Title = 'Curtain Panel - Dry Clean'; Price = 18.00 },
    [pscustomobject]@{ Title = 'Trouser Hem'; Price = 15.00 },
    [pscustomobject]@{ Title = 'Zip Replacement'; Price = 25.00 },
    [pscustomobject]@{ Title = 'Express Same-Day Service'; Price = 16.00 }
)
$payments = @('card', 'card', 'card', 'eftpos', 'cash', 'apple pay')

$end = [DateTimeOffset]::Now.AddMinutes(-5)
$start = $end.AddHours(-$HoursBack)
$spanMs = ($end - $start).TotalMilliseconds

$times = 1..$Count | ForEach-Object { $start.AddMilliseconds($rng.NextDouble() * $spanMs) } | Sort-Object

$out = [System.Collections.Generic.List[object]]::new()
$seq = 0
foreach ($t in $times) {
    $seq++
    $till = $rng.Next(1, $Tills + 1)
    $isRefund = $rng.Next(100) -lt $RefundPercent

    $lines = @()
    $total = 0.0
    $nLines = if ($isRefund) { 1 } else { $rng.Next(1, 5) }
    $picked = @($catalogue | Sort-Object { $rng.Next() } | Select-Object -First $nLines)
    foreach ($p in $picked) {
        $qty = if ($p.Title -like 'Business Shirt*') { $rng.Next(1, 8) } else { $rng.Next(1, 3) }
        $lines += [ordered]@{ title = $p.Title; quantity = $qty }
        $total += $qty * $p.Price
    }

    $txn = [ordered]@{
        customerMobile = $Mobiles[$rng.Next($Mobiles.Count)]
        saleTime       = $t.ToString('yyyy-MM-ddTHH:mm:ss.fffzzz')
        externalId     = 'TILL{0:00}-{1:yyyyMMdd-HHmmss}-{2:000000}' -f $till, $t.LocalDateTime, $seq
        type           = $isRefund ? 'refund' : 'sale'
        amount         = [math]::Round($total, 2)
        currency       = $Currency
        lineItems      = $lines
        location       = [ordered]@{ id = ('till-{0:00}' -f $till); name = "Till $till" }
        paymentTypes   = @($payments[$rng.Next($payments.Count)])
    }
    if ($CameraNames) { $txn['cameraName'] = $CameraNames[$till - 1] }
    $out.Add($txn)
}

$dir = Split-Path -Parent $OutPath
if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
ConvertTo-Json -InputObject $out -Depth 6 | Set-Content -LiteralPath $OutPath -Encoding utf8

$minutes = [math]::Max(1, $Count / 8 / 60)
Write-Host "Wrote $Count transactions across $Tills tills, $($start.LocalDateTime.ToString('ddd HH:mm')) to $($end.LocalDateTime.ToString('ddd HH:mm'))" -ForegroundColor Green
Write-Host "File: $OutPath" -ForegroundColor DarkGray
Write-Host ("At 8/s this takes about {0:N1} min to send. Send within {1} h, before the oldest sale passes 24 h." -f $minutes, (24 - $HoursBack)) -ForegroundColor DarkGray
Write-Host "Next: ./Send-PosTransaction.ps1 -Batch -BodyPath `"$OutPath`" -DryRun" -ForegroundColor Cyan
