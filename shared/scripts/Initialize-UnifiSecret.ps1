#requires -Version 7.0
<#
.SYNOPSIS
    One-time setup: installs the SecretManagement vault and stores your UniFi API key in it.

.DESCRIPTION
    Run this once per profile. The key is typed into a masked prompt, held only as a
    SecureString, and written to an encrypted SecretStore vault. It is never written to a
    config file, never echoed to the console, and never enters your shell history.

    Upgrade path: this uses the local SecretStore vault. To move to a shared vault later
    (Azure Key Vault, 1Password, etc.) register that vault under the same name and nothing
    in the scripts changes.

.PARAMETER ConfigPath
    Config file whose profile defines the vault and secret name.

.PARAMETER ProfileName
    Profile to store a key for. Defaults to the config's activeProfile.

.PARAMETER NoPassword
    Configure the SecretStore to unlock without a password (still encrypted at rest, scoped
    to your Windows user). Convenient for scheduled/unattended runs; slightly weaker than a
    password-protected store. Omit for an interactive-password store.

.EXAMPLE
    ./Initialize-UnifiSecret.ps1 -ConfigPath ../../pos-ingestion/config/unifi.config.json

.EXAMPLE
    ./Initialize-UnifiSecret.ps1 -ConfigPath ../../pos-ingestion/config/unifi.config.json -ProfileName cloud
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $ConfigPath,
    [string] $ProfileName,
    [switch] $NoPassword
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' 'UnifiClient' 'UnifiClient.psd1') -Force

# --- 1. Modules -------------------------------------------------------------

foreach ($m in 'Microsoft.PowerShell.SecretManagement', 'Microsoft.PowerShell.SecretStore') {
    if (-not (Get-Module -ListAvailable -Name $m)) {
        Write-Host "Installing $m for the current user..." -ForegroundColor Cyan
        Install-Module -Name $m -Scope CurrentUser -Force -AcceptLicense -Repository PSGallery
    }
    else {
        Write-Verbose "$m already installed."
    }
    Import-Module $m -ErrorAction Stop
}

# --- 2. Resolve the target profile ------------------------------------------

$resolved = Resolve-Path -LiteralPath $ConfigPath
$prof = Get-UnifiConfig -ConfigPath $resolved -ProfileName $ProfileName

Write-Host ''
Write-Host "Profile : $($prof.Name)"      -ForegroundColor Green
Write-Host "Base URL: $($prof.BaseUrl)"   -ForegroundColor Green
Write-Host "Vault   : $($prof.VaultName)" -ForegroundColor Green
Write-Host "Secret  : $($prof.SecretName)" -ForegroundColor Green
Write-Host ''

# --- 3. Register the vault --------------------------------------------------

if (-not (Get-SecretVault -Name $prof.VaultName -ErrorAction SilentlyContinue)) {
    Write-Host "Registering SecretStore vault '$($prof.VaultName)'..." -ForegroundColor Cyan

    if ($NoPassword) {
        # Still AES-encrypted at rest and scoped to this Windows user; just no interactive prompt.
        Set-SecretStoreConfiguration -Authentication None -Interaction None -Scope CurrentUser -Confirm:$false
        Write-Warning 'SecretStore configured WITHOUT a password. The key is encrypted at rest and readable only by your Windows account, but anyone with a session as you can read it.'
    }

    Register-SecretVault -Name $prof.VaultName -ModuleName Microsoft.PowerShell.SecretStore -ErrorAction Stop
    Write-Host 'Vault registered.' -ForegroundColor Green
}
else {
    Write-Host "Vault '$($prof.VaultName)' already registered." -ForegroundColor Green
}

# --- 4. Capture the key -----------------------------------------------------

$existing = Get-Secret -Name $prof.SecretName -Vault $prof.VaultName -ErrorAction SilentlyContinue
if ($existing) {
    $answer = Read-Host "A secret named '$($prof.SecretName)' already exists. Overwrite? (y/N)"
    if ($answer -notmatch '^[Yy]') {
        Write-Host 'Left unchanged.' -ForegroundColor Yellow
        return
    }
}

Write-Host ''
Write-Host 'Paste your UniFi API key. Input is masked and is not stored in history.' -ForegroundColor Cyan
Write-Host 'Create one at: UniFi console > Settings > Control Plane > Integrations > API Keys' -ForegroundColor DarkGray
$apiKey = Read-Host -AsSecureString -Prompt 'API key'

$probe = [System.Net.NetworkCredential]::new('', $apiKey).Password
if ([string]::IsNullOrWhiteSpace($probe)) {
    throw 'No key entered. Nothing was stored.'
}
$keyLength = $probe.Length
$probe = $null   # drop the plaintext copy immediately

Set-Secret -Name $prof.SecretName -SecureString $apiKey -Vault $prof.VaultName -ErrorAction Stop

Write-Host ''
Write-Host "Stored a $keyLength-character key as '$($prof.SecretName)' in vault '$($prof.VaultName)'." -ForegroundColor Green
Write-Host ''
Write-Host 'Next step: verify connectivity with' -ForegroundColor Cyan
Write-Host '  pos-ingestion/scripts/Test-UnifiConnection.ps1' -ForegroundColor White
