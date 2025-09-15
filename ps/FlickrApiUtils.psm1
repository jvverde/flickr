# -----------------------------------------------------------------------------
# Module: FlickrApiUtils.psm1
#
# Purpose: Provides reusable functions for interacting with the Flickr API.
#          Includes utilities for OAuth 1.0 authentication, URL encoding, and
#          tag normalization. Designed for use in PowerShell scripts that need
#          to make authenticated Flickr API calls.
#
# Exported Functions:
#   - UrlEncode-RFC3986: Encodes strings for OAuth 1.0 compatibility
#   - Get-OAuthSignature: Generates OAuth 1.0 HMAC-SHA1 signatures
#   - Invoke-FlickrApi: Makes authenticated Flickr API calls
#   - Canonicalize-Tag: Normalizes tags for consistent matching
#
# Usage:
#   Save this file as FlickrApiUtils.psm1 in a module directory (e.g., $env:PSModulePath).
#   Import into a script using: Import-Module -Name FlickrApiUtils
#
# Prerequisites:
#   - PowerShell 5.1 or higher
#   - Flickr API credentials (API key, secret, auth token, token secret)
#
# Notes:
#   - Ensure Flickr API credentials are securely stored (e.g., using Secret Management).
#   - This module does not handle credential retrieval; scripts must provide credentials.
# -----------------------------------------------------------------------------

# --- Function: UrlEncode-RFC3986 ---
# Encodes a string according to RFC 3986 for OAuth 1.0 compatibility
# Necessary for Flickr API, which requires specific URL encoding
function UrlEncode-RFC3986 {
    param(
        [Parameter(Mandatory=$true, HelpMessage="String to URL-encode")]
        [AllowEmptyString()]
        [string]$s
    )
    if ([string]::IsNullOrEmpty($s)) { return "" }

    # Use .NET's URI encoding, then fix specific characters for OAuth compliance
    # Explanation: System.Uri.EscapeDataString encodes most characters, but OAuth 1.0
    # requires additional encoding for !, *, ', (, and ) to match RFC 3986
    $encoded = [System.Uri]::EscapeDataString($s)
    $encoded = $encoded -replace '!', '%21' `
                       -replace '\*', '%2A' `
                       -replace "'", '%27' `
                       -replace '\(', '%28' `
                       -replace '\)', '%29'
    return $encoded
}

# --- Function: Get-OAuthSignature ---
# Generates an OAuth 1.0 HMAC-SHA1 signature for secure Flickr API requests
# Combines method, URL, and parameters into a signed string
function Get-OAuthSignature {
    param (
        [Parameter(Mandatory=$true, HelpMessage="HTTP method (e.g., GET)")]
        [string]$Method,

        [Parameter(Mandatory=$true, HelpMessage="Base URL for the API request")]
        [string]$Url,

        [Parameter(Mandatory=$true, HelpMessage="Hashtable of request parameters")]
        [hashtable]$Params,

        [Parameter(Mandatory=$true, HelpMessage="Flickr API consumer secret")]
        [string]$ConsumerSecret,

        [Parameter(Mandatory=$true, HelpMessage="OAuth token secret")]
        [string]$TokenSecret
    )

    # Sort and encode parameters for the signature base string
    # Explanation: Parameters are sorted by key to ensure consistent signature generation
    # Each key and value is URL-encoded using RFC 3986, then joined with '&'
    $sortedParams = ($Params.GetEnumerator() | Sort-Object Name | ForEach-Object {
        "$(UrlEncode-RFC3986 $_.Key)=$(UrlEncode-RFC3986 $_.Value)"
    }) -join '&'

    # Create base string and signing key for HMAC-SHA1
    # Explanation: The base string combines the HTTP method, URL, and sorted parameters
    $baseString = "$Method&$(UrlEncode-RFC3986 $Url)&$(UrlEncode-RFC3986 $sortedParams)"
    $signingKey = "$(UrlEncode-RFC3986 $ConsumerSecret)&$(UrlEncode-RFC3986 $TokenSecret)"

    # Compute HMAC-SHA1 signature
    # Explanation: HMAC-SHA1 is a cryptographic algorithm that generates a secure hash
    # The signing key is used to hash the base string, producing a Base64-encoded signature
    $hmac = New-Object System.Security.Cryptography.HMACSHA1
    $hmac.Key = [System.Text.Encoding]::ASCII.GetBytes($signingKey)
    $signature = [Convert]::ToBase64String($hmac.ComputeHash([System.Text.Encoding]::ASCII.GetBytes($baseString)))
    return $signature
}

# --- Function: Invoke-FlickrApi ---
# Calls Flickr REST API with OAuth 1.0 authentication
# Handles both actual API calls and dry-run simulation
function Invoke-FlickrApi {
    param (
        [Parameter(Mandatory=$true, HelpMessage="Flickr API method name")]
        [string]$MethodName,

        [Parameter(Mandatory=$true, HelpMessage="Hashtable of API parameters")]
        [hashtable]$Params,

        [Parameter(Mandatory=$true, HelpMessage="Flickr API key")]
        [string]$ApiKey,

        [Parameter(Mandatory=$true, HelpMessage="Flickr API secret")]
        [string]$ApiSecret,

        [Parameter(Mandatory=$true, HelpMessage="OAuth authentication token")]
        [string]$AuthToken,

        [Parameter(Mandatory=$true, HelpMessage="OAuth token secret")]
        [string]$TokenSecret,

        [Parameter(HelpMessage="Simulate API call without execution")]
        [bool]$DryRun=$false
    )

    $baseUrl = "https://api.flickr.com/services/rest"

    # Define OAuth parameters required for Flickr API authentication
    # Explanation: These parameters are required for OAuth 1.0 authentication
    # - oauth_timestamp: Current Unix timestamp
    # - oauth_nonce: Unique identifier for the request
    $oauthParams = @{
        oauth_consumer_key     = $ApiKey
        oauth_token            = $AuthToken
        oauth_signature_method = "HMAC-SHA1"
        oauth_timestamp        = [int]([DateTime]::UtcNow - (Get-Date "1970-01-01")).TotalSeconds
        oauth_nonce            = [Guid]::NewGuid().ToString("N")
        oauth_version          = "1.0"
        method                 = $MethodName
        format                 = "json"
        nojsoncallback         = "1"
    }

    # Merge OAuth parameters with method-specific parameters
    # Explanation: Combines OAuth parameters with additional parameters (e.g., photo_id, tags)
    $allParams = $oauthParams.Clone()
    foreach ($key in $Params.Keys) { $allParams[$key] = $Params[$key] }

    # Generate OAuth signature for the request
    $allParams['oauth_signature'] = Get-OAuthSignature -Method "GET" -Url $baseUrl -Params $allParams `
        -ConsumerSecret $ApiSecret -TokenSecret $TokenSecret

    # Build the query string for the API request
    # Explanation: Parameters are sorted and URL-encoded to form a valid query string
    $query = ($allParams.GetEnumerator() | Sort-Object Name | ForEach-Object {
        "$(UrlEncode-RFC3986 $_.Key)=$(UrlEncode-RFC3986 $_.Value)"
    }) -join '&'

    $url = "${baseUrl}?$query"

    # Simulate API call in dry-run mode for tag addition
    if ($DryRun -and $MethodName -eq 'flickr.photos.addTags') {
        Write-Host "[Dry Run] Would call: $url"
        return @{ success=$true; dry_run=$true; data=$null }
    }

    # Execute the API call and handle response
    try {
        $response = Invoke-RestMethod -Uri $url -Method Get
        if ($response.stat -eq 'ok') {
            return @{ success=$true; data=$response }
        } else {
            $errMsg = if ($null -ne $response.message) { $response.message } else { (ConvertTo-Json $response -Depth 5) }
            Write-Warning "API call error: $errMsg"
            return @{ success=$false; error_message=$errMsg }
        }
    } catch {
        Write-Warning "API call failed: $_"
        return @{ success=$false; error_message=$_ }
    }
}

# --- Function: Canonicalize-Tag ---
# Normalizes tags by removing non-alphanumeric characters and converting to lowercase
# Ensures consistent tag matching across Flickr and JSON data
function Canonicalize-Tag { 
    param(
        [Parameter(Mandatory=$true, HelpMessage="Tag to canonicalize")]
        [string]$Tag
    ) 
    # Remove all characters except letters, numbers, and colons, then convert to lowercase
    # Example: "Red-Tailed Hawk!" becomes "redtailedhawk"
    $Tag -replace '[^a-zA-Z0-9:]', '' | ForEach-Object { $_.ToLower() } 
}

# Export the functions to make them available when the module is imported
Export-ModuleMember -Function UrlEncode-RFC3986, Get-OAuthSignature, Invoke-FlickrApi, Canonicalize-Tag