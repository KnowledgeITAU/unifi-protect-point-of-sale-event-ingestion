<#
.SYNOPSIS
    Shared UniFi API client for the POS ingestion and Network IaC projects.

.DESCRIPTION
    Single place that knows how to:
      - load a connection profile from JSON (LAN or cloud, switchable),
      - fetch the API key from a SecretManagement vault (never from disk in plaintext),
      - build the right base URL per UniFi application (protect / network),
      - issue REST calls with sane error reporting.

    Requires PowerShell 7+ (uses -SkipCertificateCheck and ternary syntax).
#>

Set-StrictMode -Version Latest

$script:ApiKeyCache = @{}

#region Configuration ---------------------------------------------------------

function Get-UnifiConfig {
    <#
    .SYNOPSIS
        Loads a connection profile from a config JSON file.
    .PARAMETER ConfigPath
        Path to unifi.config.json. Defaults to ../config/unifi.config.json relative to the caller's project.
    .PARAMETER ProfileName
        Profile to use. Defaults to the file's activeProfile value.
    .OUTPUTS
        PSCustomObject with Name, BaseUrl, SkipCertificateCheck, VaultName, SecretName, SiteName.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ConfigPath,
        [string] $ProfileName
    )

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "Config file not found: $ConfigPath"
    }

    try {
        $raw = Get-Content -LiteralPath $ConfigPath -Raw -ErrorAction Stop
        $cfg = $raw | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "Config file '$ConfigPath' is not valid JSON: $($_.Exception.Message)"
    }

    # A local override file sitting next to the main config wins, so machine-specific
    # values (console IDs, internal hostnames) stay out of version control.
    $localPath = [IO.Path]::ChangeExtension($ConfigPath, $null) + 'local.json'
    if (Test-Path -LiteralPath $localPath) {
        Write-Verbose "Merging local override: $localPath"
        $local = Get-Content -LiteralPath $localPath -Raw | ConvertFrom-Json
        foreach ($p in $local.PSObject.Properties) { $cfg | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force }
    }

    # Note: StrictMode makes a missing property throw, so probe via PSObject.Properties
    # and use the -contains operator. A dotted .Contains() would do a substring match
    # whenever an object has exactly one property.
    if (-not $ProfileName) {
        $ProfileName = $cfg.PSObject.Properties['activeProfile'] ? $cfg.activeProfile : $null
    }
    if (-not $ProfileName) {
        throw "No profile specified and 'activeProfile' is missing from $ConfigPath"
    }

    if (-not $cfg.PSObject.Properties['profiles']) {
        throw "Config file '$ConfigPath' has no 'profiles' object."
    }

    # $-prefixed keys are documentation/templates, not selectable profiles.
    $available = @($cfg.profiles.PSObject.Properties.Name | Where-Object { -not $_.StartsWith('$') })
    if ($ProfileName -notin $available) {
        throw "Profile '$ProfileName' not found in $ConfigPath. Available: $($available -join ', ')"
    }

    $p = $cfg.profiles.$ProfileName
    $fields = @($p.PSObject.Properties.Name)

    foreach ($required in 'baseUrl', 'secretName') {
        if ($fields -notcontains $required -or [string]::IsNullOrWhiteSpace([string]$p.$required)) {
            throw "Profile '$ProfileName' is missing required field '$required'."
        }
    }

    if ($p.baseUrl -match '<.+>|CHANGEME|CONSOLE-LAN-IP') {
        throw "Profile '$ProfileName' baseUrl still contains a placeholder: $($p.baseUrl). Edit $ConfigPath (or a .local.json override) and set the real value."
    }
    if ($p.secretName -match 'CHANGEME') {
        throw "Profile '$ProfileName' secretName is still the placeholder '$($p.secretName)'. Give this console its own secret name."
    }

    [PSCustomObject]@{
        Name                 = $ProfileName
        BaseUrl              = $p.baseUrl.TrimEnd('/')
        SkipCertificateCheck = [bool](($fields -contains 'skipCertificateCheck') -and $p.skipCertificateCheck)
        VaultName            = ($fields -contains 'vaultName') ? $p.vaultName : 'UnifiPoc'
        SecretName           = $p.secretName
        SiteName             = ($fields -contains 'siteName') ? $p.siteName : 'default'
        ConfigPath           = $ConfigPath
    }
}

#endregion

#region Secrets ---------------------------------------------------------------

function Get-UnifiApiKey {
    <#
    .SYNOPSIS
        Retrieves the API key for a profile from the SecretManagement vault.
    .DESCRIPTION
        The key is only ever held as a SecureString in the vault and converted to plaintext
        in-memory at the moment of the request. It is never written to disk and never echoed.
        Cached per-process so a long run does not re-prompt for the vault password.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject] $Profile,
        [switch] $Force
    )

    $cacheKey = "$($Profile.VaultName)/$($Profile.SecretName)"
    if (-not $Force -and $script:ApiKeyCache.ContainsKey($cacheKey)) {
        return $script:ApiKeyCache[$cacheKey]
    }

    if (-not (Get-Module -ListAvailable -Name Microsoft.PowerShell.SecretManagement)) {
        throw "Microsoft.PowerShell.SecretManagement is not installed. Run: shared/scripts/Initialize-UnifiSecret.ps1"
    }
    Import-Module Microsoft.PowerShell.SecretManagement -ErrorAction Stop

    $vault = Get-SecretVault -Name $Profile.VaultName -ErrorAction SilentlyContinue
    if (-not $vault) {
        throw "Secret vault '$($Profile.VaultName)' is not registered. Run: shared/scripts/Initialize-UnifiSecret.ps1"
    }

    try {
        $secure = Get-Secret -Name $Profile.SecretName -Vault $Profile.VaultName -ErrorAction Stop
    }
    catch {
        throw "Secret '$($Profile.SecretName)' not found in vault '$($Profile.VaultName)'. Run: shared/scripts/Initialize-UnifiSecret.ps1 -ProfileName $($Profile.Name)"
    }

    $plain = $secure -is [System.Security.SecureString] `
        ? [System.Net.NetworkCredential]::new('', $secure).Password `
        : [string]$secure

    if ([string]::IsNullOrWhiteSpace($plain)) {
        throw "Secret '$($Profile.SecretName)' resolved to an empty value."
    }

    $script:ApiKeyCache[$cacheKey] = $plain
    return $plain
}

function Clear-UnifiApiKeyCache {
    [CmdletBinding()]
    param()
    $script:ApiKeyCache.Clear()
    Write-Verbose 'API key cache cleared.'
}

#endregion

#region Rate limiting ---------------------------------------------------------

# The console enforces 10 requests per 1000ms per API key and returns
# TOO_MANY_REQUESTS_ERROR beyond that. Observed on Protect 7.3.70, 18 Oct 2026.
# Default to 8/sec so bursts keep headroom; override with Set-UnifiRateLimit.
$script:RateLimitMax = 8
$script:RateLimitWindowMs = 1000
$script:RequestTimes = [System.Collections.Generic.Queue[datetime]]::new()

function Set-UnifiRateLimit {
    <#
    .SYNOPSIS
        Adjusts the client-side request throttle.
    .PARAMETER MaxPerWindow
        Requests allowed per window. Keep below the console's limit of 10.
    #>
    [CmdletBinding()]
    param(
        [ValidateRange(1, 100)][int] $MaxPerWindow = 8,
        [ValidateRange(100, 60000)][int] $WindowMs = 1000
    )
    $script:RateLimitMax = $MaxPerWindow
    $script:RateLimitWindowMs = $WindowMs
    Write-Verbose "Rate limit set to $MaxPerWindow requests per ${WindowMs}ms."
}

function Wait-UnifiRateLimit {
    <#
    .SYNOPSIS
        Blocks until issuing another request would stay inside the window.
    .DESCRIPTION
        Sliding window over recent request timestamps. Call immediately before every
        outbound request, including raw Invoke-WebRequest calls that bypass
        Invoke-UnifiRequest, or the throttle will not hold.
    #>
    [CmdletBinding()]
    param()

    $now = Get-Date
    $cutoff = $now.AddMilliseconds(-$script:RateLimitWindowMs)

    while ($script:RequestTimes.Count -gt 0 -and $script:RequestTimes.Peek() -lt $cutoff) {
        [void]$script:RequestTimes.Dequeue()
    }

    if ($script:RequestTimes.Count -ge $script:RateLimitMax) {
        $oldest = $script:RequestTimes.Peek()
        $waitMs = [int]($script:RateLimitWindowMs - ($now - $oldest).TotalMilliseconds) + 20
        if ($waitMs -gt 0) {
            Write-Verbose "Throttling: sleeping ${waitMs}ms to stay under $($script:RateLimitMax)/$($script:RateLimitWindowMs)ms."
            Start-Sleep -Milliseconds $waitMs
        }
        $now = Get-Date
        $cutoff = $now.AddMilliseconds(-$script:RateLimitWindowMs)
        while ($script:RequestTimes.Count -gt 0 -and $script:RequestTimes.Peek() -lt $cutoff) {
            [void]$script:RequestTimes.Dequeue()
        }
    }

    $script:RequestTimes.Enqueue((Get-Date))
}

#endregion

#region Request plumbing ------------------------------------------------------

function Get-UnifiAppBaseUrl {
    <#
    .SYNOPSIS
        Builds the base URL for a given UniFi application.
    .PARAMETER Application
        protect  -> /proxy/protect/integration/v1
        network  -> /proxy/network/integration/v1
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject] $Profile,
        [Parameter(Mandatory)][ValidateSet('protect', 'network')][string] $Application
    )

    $suffix = switch ($Application) {
        'protect' { '/proxy/protect/integration/v1' }
        'network' { '/proxy/network/integration/v1' }
    }
    return "$($Profile.BaseUrl)$suffix"
}

function Invoke-UnifiRequest {
    <#
    .SYNOPSIS
        Issues an authenticated request against a UniFi integration API.
    .PARAMETER Path
        Path relative to the application base, e.g. '/meta/info' or '/cameras'.
    .PARAMETER Raw
        Return the full response object (status code + content) instead of the parsed body.
        Needed for endpoints like the Alarm Manager webhook that return 204 with no body.
    .EXAMPLE
        Invoke-UnifiRequest -Profile $p -Application protect -Path '/meta/info'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject] $Profile,
        [Parameter(Mandatory)][ValidateSet('protect', 'network')][string] $Application,
        [Parameter(Mandatory)][string] $Path,
        [ValidateSet('GET', 'POST', 'PUT', 'PATCH', 'DELETE')][string] $Method = 'GET',
        [object] $Body,
        [hashtable] $Query,
        [switch] $Raw,
        [int] $TimeoutSec = 30
    )

    $base = Get-UnifiAppBaseUrl -Profile $Profile -Application $Application
    $uri = "$base/$($Path.TrimStart('/'))"

    if ($Query -and $Query.Count -gt 0) {
        $pairs = foreach ($k in $Query.Keys) {
            '{0}={1}' -f [uri]::EscapeDataString([string]$k), [uri]::EscapeDataString([string]$Query[$k])
        }
        $uri = "$uri`?$($pairs -join '&')"
    }

    $params = @{
        Uri             = $uri
        Method          = $Method
        Headers         = @{
            'X-API-KEY' = Get-UnifiApiKey -Profile $Profile
            'Accept'    = 'application/json'
        }
        TimeoutSec      = $TimeoutSec
        ErrorAction     = 'Stop'
        MaximumRedirection = 0
    }

    if ($Profile.SkipCertificateCheck) {
        # The gateway presents a self-signed cert on the LAN. Equivalent to curl -k.
        $params['SkipCertificateCheck'] = $true
    }

    if ($null -ne $Body) {
        $params['ContentType'] = 'application/json'
        $params['Body'] = ($Body -is [string]) ? $Body : ($Body | ConvertTo-Json -Depth 12 -Compress)
    }

    Write-Verbose "$Method $uri"

    # Retry on 429 with exponential backoff. The proactive throttle should prevent these,
    # but a shared key used elsewhere at the same time can still push us over.
    $maxAttempts = 4
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {

        Wait-UnifiRateLimit

        try {
            if ($Raw) {
                $resp = Invoke-WebRequest @params
                return [PSCustomObject]@{
                    StatusCode = [int]$resp.StatusCode
                    Content    = $resp.Content
                    Headers    = $resp.Headers
                }
            }
            return Invoke-RestMethod @params
        }
        catch {
            $status = $null
            if ($_.Exception.PSObject.Properties.Name -contains 'Response' -and $_.Exception.Response) {
                $status = [int]$_.Exception.Response.StatusCode
            }

            if ($status -eq 429 -and $attempt -lt $maxAttempts) {
                $backoffMs = [int](250 * [math]::Pow(2, $attempt - 1))

                # Honour Retry-After when the server sends one.
                try {
                    $ra = $_.Exception.Response.Headers | Where-Object { $_.Key -ieq 'Retry-After' } | Select-Object -First 1
                    if ($ra) {
                        $raVal = [int]($ra.Value | Select-Object -First 1)
                        if ($raVal -gt 0) { $backoffMs = $raVal * 1000 }
                    }
                }
                catch { }

                Write-Verbose "429 on attempt $attempt; backing off ${backoffMs}ms."
                Start-Sleep -Milliseconds $backoffMs
                continue
            }

            throw (Resolve-UnifiError -ErrorRecord $_ -Uri $uri -Method $Method)
        }
    }
}

function Resolve-UnifiError {
    <#
    .SYNOPSIS
        Turns an HTTP failure into a message that says what to actually do about it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $ErrorRecord,
        [string] $Uri,
        [string] $Method
    )

    $status = $null
    if ($ErrorRecord.Exception.PSObject.Properties.Name -contains 'Response' -and $ErrorRecord.Exception.Response) {
        $status = [int]$ErrorRecord.Exception.Response.StatusCode
    }

    $detail = ''
    if ($ErrorRecord.PSObject.Properties.Name -contains 'ErrorDetails' -and $ErrorRecord.ErrorDetails) {
        $detail = $ErrorRecord.ErrorDetails.Message
    }

    $hint = switch ($status) {
        401 { 'API key rejected. Confirm the key is current and was created on this console (Settings > Control Plane > Integrations > API Keys).' }
        403 { 'Authenticated but not permitted. The API key may lack the required application scope, or the Integrations API is disabled for this application.' }
        404 { 'Endpoint not found. Either the path is wrong for your Protect/Network version, or that application is not installed on this console.' }
        429 { 'Rate limited. Back off and retry.' }
        default { $null }
    }

    $msg = "UniFi API $Method $Uri failed"
    if ($status) { $msg += " (HTTP $status)" }
    $msg += ": $($ErrorRecord.Exception.Message)"
    if ($detail) { $msg += "`n  Response: $detail" }
    if ($hint) { $msg += "`n  Hint: $hint" }

    if ($ErrorRecord.Exception.Message -match 'trust|SSL|certificate') {
        $msg += "`n  Hint: the gateway uses a self-signed certificate. Set `"skipCertificateCheck`": true on this profile in your config."
    }

    return $msg
}

#endregion

#region Response shaping ------------------------------------------------------

function Expand-UnifiResponse {
    <#
    .SYNOPSIS
        Normalises a response to a plain array of items.
    .DESCRIPTION
        Some UniFi endpoints return a bare JSON array, others wrap it in a pagination
        envelope { offset, limit, count, totalCount, data: [...] }. Callers should not have
        to care which, and under StrictMode guessing wrong throws.
    #>
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline)] $Response)

    process {
        $items = @($Response)
        if ($items.Count -eq 1 -and $items[0] -is [PSCustomObject] -and $items[0].PSObject.Properties['data']) {
            return @($items[0].data)
        }
        return $items
    }
}

function Get-UnifiProperty {
    <#
    .SYNOPSIS
        Reads the first property that exists from a list of candidate names.
    .DESCRIPTION
        Field names drift between UniFi versions (id vs _id, name vs displayName), and
        StrictMode turns a missing property into a terminating error. Always read through
        this when the field name is not guaranteed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $InputObject,
        [Parameter(Mandatory)][string[]] $Name,
        $Default = $null
    )

    if ($null -eq $InputObject) { return $Default }
    $have = @($InputObject.PSObject.Properties.Name)
    foreach ($n in $Name) {
        if ($have -contains $n -and $null -ne $InputObject.$n) { return $InputObject.$n }
    }
    return $Default
}

#endregion

#region Pagination ------------------------------------------------------------

function Get-UnifiPagedResult {
    <#
    .SYNOPSIS
        Walks a paginated UniFi integration endpoint and returns every item.
    .DESCRIPTION
        The Network integration API returns { offset, limit, count, totalCount, data: [...] }.
        Endpoints that return a bare array are passed through unchanged.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject] $Profile,
        [Parameter(Mandatory)][ValidateSet('protect', 'network')][string] $Application,
        [Parameter(Mandatory)][string] $Path,
        [int] $PageSize = 200,
        [int] $MaxPages = 100
    )

    $all = [System.Collections.Generic.List[object]]::new()
    $offset = 0

    for ($page = 0; $page -lt $MaxPages; $page++) {
        $resp = Invoke-UnifiRequest -Profile $Profile -Application $Application -Path $Path `
            -Query @{ offset = $offset; limit = $PageSize }

        # Bare array response: no pagination envelope, we are done.
        if ($resp -is [System.Array] -or $null -eq $resp.PSObject.Properties['data']) {
            foreach ($i in @($resp)) { $all.Add($i) }
            break
        }

        foreach ($i in @($resp.data)) { $all.Add($i) }

        $total = $resp.PSObject.Properties['totalCount'] ? [int]$resp.totalCount : $all.Count
        $offset += $PageSize
        if ($offset -ge $total -or @($resp.data).Count -eq 0) { break }

        if ($page -eq $MaxPages - 1) {
            Write-Warning "Stopped paginating $Path after $MaxPages pages ($($all.Count) of $total items). Raise -MaxPages if you need the rest."
        }
    }

    return $all
}

#endregion

Export-ModuleMember -Function `
    Get-UnifiConfig, `
    Get-UnifiApiKey, `
    Clear-UnifiApiKeyCache, `
    Get-UnifiAppBaseUrl, `
    Invoke-UnifiRequest, `
    Wait-UnifiRateLimit, `
    Set-UnifiRateLimit, `
    Expand-UnifiResponse, `
    Get-UnifiProperty, `
    Get-UnifiPagedResult
