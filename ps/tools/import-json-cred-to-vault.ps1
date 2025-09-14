# Requires PowerShell 5.1+
# This script migrates secrets from flickr_config.json into SecretManagement / SecretStore
# Opens a Windows file picker only if running on Windows
# Supports -Force to overwrite existing vault

param (
    [switch]$Force,
    [switch]$Help
)

# --- Function: Show usage/help message ---
function Show-Usage {
    Write-Host @"
Usage:
    .\migrate_flickr_secrets.ps1 [-Force] [-Help]

Options:
    -Force   : Overwrite existing SecretVault if it already exists.
    -Help    : Show this help message.

JSON file format expected (flickr_config.json):
{
    "api_key": "YOUR_API_KEY",
    "api_secret": "YOUR_API_SECRET",
    "auth_token": "YOUR_AUTH_TOKEN",
    "token_secret": "YOUR_TOKEN_SECRET"
}

Notes:
- The script will look for 'flickr_config.json' in your USERPROFILE by default.
- On Windows, if the file is not found, a file picker dialog will open.
- On other OSes, you will be prompted to enter the full path.
- Secrets will be stored in a SecretManagement vault named 'FlickrVault'.
- Use -Force to overwrite the vault if it already exists.
"@
    exit
}

if ($Help) { Show-Usage }

# --- 1. Locate config JSON ---
$configFileDefault = Join-Path $env:USERPROFILE "flickr_config.json"
$configFile = $null
$IsWindows = $env:OS -eq "Windows_NT"

if (Test-Path $configFileDefault) {
    $configFile = $configFileDefault
} else {
    if ($IsWindows) {
        Write-Host "flickr_config.json not found in $env:USERPROFILE."
        Add-Type -AssemblyName System.Windows.Forms

        $OpenFileDialog = New-Object System.Windows.Forms.OpenFileDialog
        $OpenFileDialog.Filter = "JSON files (*.json)|*.json|All files (*.*)|*.*"
        $OpenFileDialog.Title = "Select your flickr_config.json"

        do {
            $result = $OpenFileDialog.ShowDialog()
            if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
                $configFile = $OpenFileDialog.FileName
            } else {
                Write-Host "You must select a file to continue."
            }
        } while (-not (Test-Path $configFile))
    } else {
        # Non-Windows fallback: manual path input
        Write-Host "flickr_config.json not found. Please enter the full path:"
        do {
            $configFile = Read-Host "Path to flickr_config.json"
        } while (-not (Test-Path $configFile))
    }
}

# --- 2. Load JSON ---
try {
    $config = Get-Content -Path $configFile -Raw -Encoding UTF8 | ConvertFrom-Json
} catch {
    Write-Error "Failed to parse ${configFile}: $_"
    exit 1
}

Write-Host "Loaded config from ${configFile}"

# --- 3. Ensure required modules are installed ---
$modules = @("Microsoft.PowerShell.SecretManagement", "Microsoft.PowerShell.SecretStore")

foreach ($m in $modules) {
    if (-not (Get-Module -ListAvailable -Name $m)) {
        Write-Host "Installing module ${m}..."
        try {
            Install-Module -Name $m -Force -Scope CurrentUser -AllowClobber
        } catch {
            Write-Error "Failed to install module ${m}: $_"
            exit 1
        }
    }
}

Import-Module Microsoft.PowerShell.SecretManagement
Import-Module Microsoft.PowerShell.SecretStore

# --- 4. Register or overwrite the SecretStore vault ---
$vaultName = "FlickrVault"
$existingVault = Get-SecretVault | Where-Object Name -eq $vaultName

if ($existingVault) {
    if ($Force) {
        Write-Host "Vault '${vaultName}' already exists. Removing due to -Force..."
        try {
            Unregister-SecretVault -Name $vaultName -Force
        } catch {
            Write-Error "Failed to remove existing vault '${vaultName}': $_"
            exit 1
        }
    } else {
        Write-Warning "Vault '${vaultName}' already exists. Use -Force to overwrite."
        exit 1
    }
}

Write-Host "Registering SecretVault '${vaultName}'..."
try {
    Register-SecretVault -Name $vaultName -ModuleName Microsoft.PowerShell.SecretStore -DefaultVault
} catch {
    Write-Error "Failed to register vault '${vaultName}': $_"
    exit 1
}

# --- 5. Store secrets from JSON into SecretStore ---
Write-Host "Storing Flickr secrets into vault '${vaultName}'..."
Set-Secret -Name FlickrApiKey       -Secret $config.api_key      -Vault $vaultName
Set-Secret -Name FlickrApiSecret    -Secret $config.api_secret   -Vault $vaultName
Set-Secret -Name FlickrAuthToken    -Secret $config.auth_token   -Vault $vaultName
Set-Secret -Name FlickrTokenSecret  -Secret $config.token_secret -Vault $vaultName

Write-Host "✅ All secrets stored successfully in vault '${vaultName}'."
Write-Host "You can retrieve them later with: Get-Secret -Name FlickrApiKey -AsPlainText"
