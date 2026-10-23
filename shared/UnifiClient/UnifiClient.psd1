@{
    RootModule        = 'UnifiClient.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'd2c7a9f1-4b6e-4a28-9c13-7f0e5b8a2d41'
    Author            = 'All AI Agents'
    Description       = 'Shared UniFi integration API client: config profiles, vault-backed API keys, REST plumbing.'
    PowerShellVersion = '7.0'
    FunctionsToExport = @(
        'Get-UnifiConfig',
        'Get-UnifiApiKey',
        'Clear-UnifiApiKeyCache',
        'Get-UnifiAppBaseUrl',
        'Invoke-UnifiRequest',
        'Wait-UnifiRateLimit',
        'Set-UnifiRateLimit',
        'Expand-UnifiResponse',
        'Get-UnifiProperty',
        'Get-UnifiPagedResult'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
