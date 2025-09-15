#Requires -Version 5.1
#Requires -Modules Microsoft.PowerShell.SecretManagement
# -----------------------------------------------------------------------------
# Script: Get Flickr OAuth Tokens and Update Vault
#
# Purpose: Guides the user through Flickr's OAuth 1.0 authentication flow to obtain
#          an access token and token secret, then stores them in a PowerShell Secret
#          Management vault for use in other Flickr API scripts.
#
# FLOW OVERVIEW:
#   1. Import FlickrApiUtils module for OAuth 1.0 utilities
#   2. Validate or retrieve Flickr API key and secret
#   3. Request an OAuth request token from Flickr (flickr.auth.oauth.getRequestToken)
#   4. Generate an authorization URL and prompt the user to authorize the app
#   5. Exchange the authorized request token for an access token and token secret
#   6. Store the tokens in the specified Secret Management vault
#
# Prerequisites:
#   - PowerShell 5.1 or higher
#   - Microsoft.PowerShell.SecretManagement module installed
#   - A registered Secret Management vault (e.g., LocalVault or SecretStore)
#   - FlickrApiUtils.psm1 module in a module path or same directory
#   - Flickr API key and secret (provided via parameters or stored in vault)
#
# Key Features:
#   - Uses OAuth 1.0 for secure Flickr API authentication
#   - Stores tokens securely using PowerShell Secret Management
#   - Provides user-friendly prompts for the OAuth authorization step
#   - Leverages FlickrApiUtils for consistent API handling
#
# Limitations:
#   - Requires user interaction to complete OAuth authorization
#   - Assumes a valid Secret Management vault is configured
#   - Flickr API rate limits apply
# -----------------------------------------------------------------------------

param (
    [Parameter(Mandatory=$true, HelpMessage="Flickr API key (or name of secret containing the key)")]
    [string]$ApiKey,

    [Parameter(Mandatory=$true, HelpMessage="Flickr API secret (or name of secret containing the secret)")]
    [string]$ApiSecret,

    [Parameter(Mandatory=$true, HelpMessage="Name of the Secret Management vault to store tokens")]
    [string]$VaultName,

    [Parameter(HelpMessage="Display usage information")]
    [switch]$Help
)

# Ensure console output uses UTF-8 to properly display special characters
$OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Import the FlickrApiUtils module
# Explanation: Loads reusable Flickr API functions (UrlEncode-RFC3986, Get-OAuthSignature, Invoke-FlickrApi)
try {
    Import-Module -Name FlickrApiUtils -ErrorAction Stop
} catch {
    Write-Error "Failed to import FlickrApiUtils module: $_"
    exit
}

# --- Function: Show-Usage ---
# Displays usage instructions and exits the script
# Provides examples and detailed parameter descriptions for clarity
function Show-Usage {
    Write-Host @"
Get Flickr OAuth Tokens and Update Vault

Usage:
  .\get_flickr_tokens.ps1 -ApiKey <key> -ApiSecret <secret> -VaultName <vault>

Parameters:
  -ApiKey <key>      : Flickr API key or name of secret containing the key
  -ApiSecret <secret>: Flickr API secret or name of secret containing the secret
  -VaultName <vault> : Name of the Secret Management vault to store tokens
  -Help              : Show this usage message

Example:
  .\get_flickr_tokens.ps1 -ApiKey FlickrApiKey -ApiSecret FlickrApiSecret -VaultName LocalVault
"@
    exit
}

# --- Function: Get-SecretOrValue ---
# Retrieves a secret from the vault if it exists, otherwise treats the input as the value
# Explanation: Allows flexibility to pass either a secret name or direct value for ApiKey and ApiSecret
function Get-SecretOrValue {
    param (
        [Parameter(Mandatory=$true, HelpMessage="Secret name or value")]
        [string]$InputValue,

        [Parameter(Mandatory=$true, HelpMessage="Vault name")]
        [string]$VaultName
    )
    try {
        # Attempt to retrieve the secret from the vault
        $secret = Get-Secret -Name $InputValue -Vault $VaultName -ErrorAction SilentlyContinue
        if ($null -ne $secret) {
            return $secret | ConvertFrom-SecureString -AsPlainText
        }
        # If no secret is found, treat the input as the value
        return $InputValue
    } catch {
        Write-Warning "Failed to retrieve secret '$InputValue' from vault '$VaultName': $_"
        return $InputValue
    }
}

# -----------------------------------------------------------------------------
# MAIN SCRIPT EXECUTION
# -----------------------------------------------------------------------------

# Display usage if help is requested
if ($Help) { Show-Usage }

# Validate vault existence
# Explanation: Checks if the specified Secret Management vault is registered
try {
    $vault = Get-SecretVault -Name $VaultName -ErrorAction Stop
    if (-not $vault) {
        Write-Error "Vault '$VaultName' is not registered."
        exit
    }
} catch {
    Write-Error "Failed to access vault '$VaultName': $_"
    exit
}

# Retrieve or use provided API key and secret
# Explanation: Allows ApiKey and ApiSecret to be either secret names or direct values
$apiKeyValue = Get-SecretOrValue -InputValue $ApiKey -VaultName $VaultName
$apiSecretValue = Get-SecretOrValue -InputValue $ApiSecret -VaultName $VaultName

# --- Step 1: Request OAuth Request Token ---
# Explanation: Calls flickr.auth.oauth.getRequestToken to start the OAuth flow
$requestParams = @{
    oauth_callback = "oob" # Out-of-band callback for desktop apps
}
$response = Invoke-FlickrApi -MethodName "flickr.auth.oauth.getRequestToken" -Params $requestParams `
    -ApiKey $apiKeyValue -ApiSecret $apiSecretValue -AuthToken "" -TokenSecret "" -DryRun:$false

if (-not $response.success) {
    Write-Error "Failed to obtain request token: $($response.error_message)"
    exit
}

# Parse the request token response
# Explanation: Flickr returns a URL-encoded string (e.g., oauth_token=abc&oauth_token_secret=xyz)
$requestTokenData = $response.data.Split('&') | ForEach-Object { $_.Split('=') } | 
    ForEach-Object { @{ $_.[0] = $_.[1] } } | ForEach-Object { $_ } | ConvertTo-Hashtable
$requestToken = $requestTokenData.oauth_token
$requestTokenSecret = $requestTokenData.oauth_token_secret

if (-not $requestToken -or -not $requestTokenSecret) {
    Write-Error "Failed to parse request token or secret from response"
    exit
}

Write-Host "Request token obtained: $requestToken"

# --- Step 2: Generate Authorization URL and Prompt User ---
# Explanation: Constructs the URL for the user to authorize the app on Flickr
$authUrl = "https://www.flickr.com/services/oauth/authorize?oauth_token=$([System.Uri]::EscapeDataString($requestToken))"
Write-Host "Please visit the following URL in your browser to authorize the application:"
Write-Host $authUrl
Write-Host "After authorizing, you will receive a verifier code (9 digits)."

# Prompt user for the OAuth verifier code
# Explanation: Flickr provides a verifier code after user authorization
$verifier = Read-Host -Prompt "Enter the OAuth verifier code"

if (-not $verifier) {
    Write-Error "No verifier code provided. Authorization cannot proceed."
    exit
}

# --- Step 3: Exchange Request Token for Access Token ---
# Explanation: Calls flickr.auth.oauth.getAccessToken with the verifier code
$accessParams = @{
    oauth_verifier = $verifier
}
$response = Invoke-FlickrApi -MethodName "flickr.auth.oauth.getAccessToken" -Params $accessParams `
    -ApiKey $apiKeyValue -ApiSecret $apiSecretValue -AuthToken $requestToken -TokenSecret $requestTokenSecret -DryRun:$false

if (-not $response.success) {
    Write-Error "Failed to obtain access token: $($response.error_message)"
    exit
}

# Parse the access token response
# Explanation: Flickr returns a URL-encoded string (e.g., oauth_token=abc&oauth_token_secret=xyz)
$accessTokenData = $response.data.Split('&') | ForEach-Object { $_.Split('=') } | 
    ForEach-Object { @{ $_.[0] = $_.[1] } } | ForEach-Object { $_ } | ConvertTo-Hashtable
$accessToken = $accessTokenData.oauth_token
$accessTokenSecret = $accessTokenData.oauth_token_secret

if (-not $accessToken -or -not $accessTokenSecret) {
    Write-Error "Failed to parse access token or secret from response"
    exit
}

Write-Host "Access token obtained: $accessToken"

# --- Step 4: Store Tokens in Secret Management Vault ---
# Explanation: Saves the access token and token secret as secrets in the specified vault
try {
    Set-Secret -Name FlickrAuthToken -Secret $accessToken -Vault $VaultName -ErrorAction Stop
    Set-Secret -Name FlickrTokenSecret -Secret $accessTokenSecret -Vault $VaultName -ErrorAction Stop
    Write-Host "Successfully stored FlickrAuthToken and FlickrTokenSecret in vault '$VaultName'"
} catch {
    Write-Error "Failed to store tokens in vault '$VaultName': $_"
    exit
}

# --- Step 5: Store API Key and Secret if Provided as Values ---
# Explanation: If ApiKey or ApiSecret were provided as values (not secret names), store them
if ($ApiKey -eq $apiKeyValue) {
    try {
        Set-Secret -Name FlickrApiKey -Secret $apiKeyValue -Vault $VaultName -ErrorAction Stop
        Write-Host "Stored FlickrApiKey in vault '$VaultName'"
    } catch {
        Write-Warning "Failed to store FlickrApiKey in vault '$VaultName': $_"
    }
}
if ($ApiSecret -eq $apiSecretValue) {
    try {
        Set-Secret -Name FlickrApiSecret -Secret $apiSecretValue -Vault $VaultName -ErrorAction Stop
        Write-Host "Stored FlickrApiSecret in vault '$VaultName'"
    } catch {
        Write-Warning "Failed to store FlickrApiSecret in vault '$VaultName': $_"
    }
}

Write-Host "Flickr OAuth tokens successfully obtained and stored. You can now use them in other scripts."