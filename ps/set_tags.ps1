#Requires -Version 5.1
# -----------------------------------------------------------------------------
# Script: Bulk Add Tags to Flickr Photos from JSON
#
# Purpose: Automates the process of adding tags to Flickr photos based on data
#          from a JSON file. Matches existing photo tags against a specified JSON
#          key and applies additional tags defined in the JSON.
#
# FLOW OVERVIEW:
#   1. Load JSON file (UTF-8, contains species/order/etc info) into PowerShell objects
#   2. Build a lookup table (hashtable) where:
#      - Key: Canonicalized tag (e.g., "passeriformes")
#      - Value: Space-delimited string of tags to add
#   3. Fetch photos from Flickr using flickr.photos.search API
#   4. For each photo:
#      - Canonicalize its existing tags
#      - Check for matches against lookup table keys
#      - If matched, add new tags via flickr.photos.addTags
#      - If -DryRun is specified, simulate without making API calls
#
# Prerequisites:
#   - PowerShell 5.1 or higher
#   - Flickr API credentials stored in Secret Management (FlickrApiKey, FlickrApiSecret, FlickrAuthToken, FlickrTokenSecret)
#   - JSON file with consistent structure (array of objects)
#
# Key Features:
#   - Supports OAuth 1.0 for secure Flickr API authentication
#   - Canonicalizes tags to ensure consistent matching
#   - Handles multi-word tags with proper quoting
#   - Provides dry-run mode for testing
#   - Supports regex filtering and IOC-style tag additions
#   - Processes photos uploaded within a specified time frame
#
# Limitations:
#   - Requires valid Flickr API credentials
#   - JSON file must be UTF-8 encoded
#   - Tags are case-insensitive after canonicalization
#   - Flickr API rate limits apply
# -----------------------------------------------------------------------------

param (
    [Parameter(Mandatory=$true, HelpMessage="Path to JSON file containing photo/tag data")]
    [string]$File,

    [Parameter(Mandatory=$true, HelpMessage="JSON key to match against photo tags")]
    [string]$Key,

    [Parameter(Mandatory=$true, HelpMessage="JSON keys whose values will be added as Flickr tags (comma-separated)")]
    [string[]]$Tag,

    [Parameter(HelpMessage="Reverse JSON array order before processing")]
    [switch]$Reverse,

    [Parameter(HelpMessage="Regex pattern to filter key values")]
    [string]$Match,

    [Parameter(HelpMessage="Prefix for IOC-style tags")]
    [string]$List,

    [Parameter(HelpMessage="Limit to photos uploaded in the last N days")]
    [int]$Days,

    [Parameter(HelpMessage="Simulate actions without calling Flickr API")]
    [switch]$DryRun,

    [Parameter(HelpMessage="Display usage information")]
    [switch]$Help
)

# Ensure console output uses UTF-8 to properly display special characters in tags
$OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# --- Function: Show-Usage ---
# Displays usage instructions and exits the script
# Provides examples and detailed parameter descriptions for clarity
function Show-Usage {
    Write-Host @"
Bulk Add Tags to Flickr Photos

Usage:
  .\set_tags.ps1 -File <jsonfile> -Key <keyname> -Tag <tag1,tag2,...>

Parameters:
  -File <jsonfile>   : Path to JSON file containing an array of objects
  -Key <keyname>     : JSON key whose value is used to match existing photo tags
  -Tag <tag1,tag2>   : JSON keys whose values are added as new Flickr tags
                       Example: -Tag Order,Family or -Tag @('Order','Family')
  -Reverse           : Process JSON array in reverse order
  -Match <pattern>   : Apply regex filter to key values before processing
  -List <listname>   : Add IOC-style tags (e.g., listname:binomial="species")
  -Days <num>        : Limit to photos uploaded in the last N days
  -DryRun            : Simulate tag addition without modifying Flickr photos
  -Help              : Show this usage message

Example:
  .\set_tags.ps1 -File birds.json -Key species -Tag Order,Family -DryRun
"@
    exit
}

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
    $sortedParams = ($Params.GetEnumerator() | Sort-Object Name | ForEach-Object {
        "$(UrlEncode-RFC3986 $_.Key)=$(UrlEncode-RFC3986 $_.Value)"
    }) -join '&'

    # Create base string and signing key for HMAC-SHA1
    $baseString = "$Method&$(UrlEncode-RFC3986 $Url)&$(UrlEncode-RFC3986 $sortedParams)"
    $signingKey = "$(UrlEncode-RFC3986 $ConsumerSecret)&$(UrlEncode-RFC3986 $TokenSecret)"

    # Compute HMAC-SHA1 signature
    # Explanation: HMAC-SHA1 is a cryptographic algorithm that generates a secure hash
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

# -----------------------------------------------------------------------------
# MAIN SCRIPT EXECUTION
# -----------------------------------------------------------------------------

# Display usage if help is requested or required parameters are missing
if ($Help) { Show-Usage }
if (-not $File -or -not $Key -or -not $Tag) { Show-Usage }

# Retrieve Flickr API credentials from Secret Management
# These credentials are required for authenticating with the Flickr API
try {
    $apiKey = (Get-Secret -Name FlickrApiKey -AsPlainText)
    $apiSecret = (Get-Secret -Name FlickrApiSecret -AsPlainText)
    $authToken = (Get-Secret -Name FlickrAuthToken -AsPlainText)
    $tokenSecret = (Get-Secret -Name FlickrTokenSecret -AsPlainText)
} catch {
    Write-Error "Failed to retrieve Flickr API credentials: $_"
    exit
}

# Notify user if running in dry-run mode (no actual changes will be made)
if ($DryRun) { Write-Host "Running in dry-run mode. No tags will be added to photos." }

# Load and parse JSON file, ensuring it is UTF-8 encoded
try {
    $data = Get-Content $File -Raw -Encoding UTF8 | ConvertFrom-Json
} catch {
    Write-Error "Cannot read ${File}: $_"
    exit
}

# Reverse JSON array order if -Reverse switch is specified
# Useful for processing newer entries first if JSON is chronologically ordered
if ($Reverse) {
    # Explanation: Sort-Object with -Descending reverses the array order
    $data = $data | Sort-Object { $_ } -Descending
}

# --- Step 1: Bulk fetch all photos from Flickr ---
$page = 1
$photos = @()
do {
    # Define parameters for Flickr photos.search API
    $searchParams = @{
        user_id = 'me'              # Fetch photos from the authenticated user
        extras  = 'tags,date_upload' # Include tags and upload date in response
        per_page = 500              # Fetch up to 500 photos per page (Flickr API limit)
        page    = $page             # Current page number
    }

    # Add time filter if -Days parameter is specified
    if ($Days) {
        # Calculate timestamp for photos uploaded within the last N days
        # Explanation: Converts current time minus N days to Unix timestamp (seconds since 1970-01-01)
        $searchParams['min_upload_date'] = [int]([DateTime]::UtcNow.AddDays(-$Days).Subtract((Get-Date "1970-01-01")).TotalSeconds)
    }

    # Call Flickr API to fetch photos
    $response = Invoke-FlickrApi -MethodName 'flickr.photos.search' -Params $searchParams `
        -ApiKey $apiKey -ApiSecret $apiSecret -AuthToken $authToken -TokenSecret $tokenSecret -DryRun:$DryRun

    if (-not $response.success) {
        Write-Warning "Error fetching photos: $($response.error_message)"
        break
    }

    # Add fetched photos to the array
    $photos += $response.data.photos.photo
    $page++
    $pages = $response.data.photos.pages
} while ($page -le $pages) # Continue until all pages are fetched

Write-Host "Fetched $($photos.Count) photos from Flickr"

# --- Step 2: Build lookup table from JSON ---
$lookup = @{}
foreach ($item in $data) {
    # Canonicalize the value of the specified JSON key for matching
    $keyValue = Canonicalize-Tag -Tag $item.$Key

    # Skip if regex filter (-Match) is specified and the key value doesn't match
    if ($Match -and $keyValue -notmatch $Match) { continue }

    # Extract values from JSON object for each tag key specified in -Tag parameter
    # Explanation of the pipeline:
    # - $Tag: Array of JSON keys (e.g., @('Order', 'Family'))
    # - ForEach-Object { $item.$_ }: Iterates over each key in $Tag
    #   - $_ represents the current key (e.g., 'Order')
    #   - $item.$_ dynamically accesses the property of $item named by $_ (e.g., $item.Order)
    # - Where-Object { $_ }: Filters out any null or empty values to ensure only valid tags are included
    # Example: If $Tag = @('Order', 'Family') and $item.Order = 'Passeriformes', $item.Family = 'Paridae',
    #          $newTags will contain @('Passeriformes', 'Paridae')
    $newTags = $Tag | ForEach-Object { $item.$_ } | Where-Object { $_ }

    # Add IOC-style tags if -List parameter is specified
    # These tags follow a structured format (e.g., listname:binomial="species")
    # Example: If $List = 'IOC', adds tags like 'IOC', 'IOC:seq="123"', 'IOC:binomial="Parus major"'
    if ($List) { 
        $newTags += @(
            $List,                          # Base list name (e.g., "IOC")
            "$List`:seq=`"$($item.'Seq.')`"", # Sequence number
            "$List`:binomial=`"$($item.species)`"", # Scientific name
            "$List`:name=`"$($item.English)`""     # Common name
        ) 
    }

    # Join tags into a single space-separated string for Flickr API
    # Example: ['Passeriformes', 'Paridae', 'IOC'] becomes 'Passeriformes Paridae IOC'
    $lookup[$keyValue] = $newTags -join ' '
}

# --- Step 3: Process photos and add tags ---
foreach ($photo in $photos) {
    # Split and canonicalize existing photo tags for matching
    # Explanation: $photo.tags is a space-separated string of tags
    # -split '\s+' splits the string into an array based on whitespace
    # ForEach-Object applies Canonicalize-Tag to each tag
    # Example: 'Red-Tailed Hawk passeriformes' becomes @('redtailedhawk', 'passeriformes')
    $photoTags = ($photo.tags -split '\s+') | ForEach-Object { Canonicalize-Tag $_ }
    
    # Find lookup table keys that match the photo's canonicalized tags
    # Explanation of the pipeline:
    # - $lookup.Keys: Retrieves all keys from the lookup hashtable (e.g., @('passeriformes', 'corvidae'))
    # - Where-Object { $photoTags -contains $_ }: Filters keys to those present in $photoTags
    #   - $_ represents the current key being evaluated
    #   - $photoTags -contains $_ checks if the key exists in the photo's tags
    # Example: If $photoTags = @('redtailedhawk', 'passeriformes') and $lookup.Keys = @('passeriformes', 'corvidae'),
    #          $matchedKeys will be @('passeriformes')
    $matchedKeys = $lookup.Keys | Where-Object { $photoTags -contains $_ }

    foreach ($key in $matchedKeys) {
        $tagsToAdd = $lookup[$key]
        
        if ($DryRun) {
            # In dry-run mode, log the action without making changes
            Write-Host "[Dry Run] PhotoID=$($photo.id), Title='$($photo.title)'"
            Write-Host "           Tags to add: $tagsToAdd"
            continue
        }

        # Log the action before making the API call
        Write-Host "Adding tags to PhotoID=$($photo.id), Title='$($photo.title)'"
        Write-Host "Tags to add: $tagsToAdd"

        # Call Flickr API to add tags to the photo
        $resp = Invoke-FlickrApi -MethodName 'flickr.photos.addTags' -Params @{
            photo_id = $photo.id
            tags     = $tagsToAdd
        } -ApiKey $apiKey -ApiSecret $apiSecret -AuthToken $authToken -TokenSecret $tokenSecret

        if ($resp.success) {
            Write-Host "Successfully added tags ($tagsToAdd) to '$($photo.title)'"
        } else {
            Write-Warning "Failed to add tags to '$($photo.title)': $($resp.error_message)"
        }
    }
}