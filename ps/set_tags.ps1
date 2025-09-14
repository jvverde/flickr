#Requires -Version 5.1
# -----------------------------------------------------------------------------
# Bulk Add Tags to Flickr Photos from JSON
#
# FLOW OVERVIEW (how the script works):
#
#   JSON file (UTF-8, contains species/order/etc info)
#           │
#           ▼
#   Step 1: Load JSON → objects in PowerShell
#           │
#           ▼
#   Step 2: Build lookup table (hashtable)
#           key   = canonicalized tag (e.g. "passeriformes")
#           value = string of tags to add (space-delimited)
#           │
#           ▼
#   Step 3: Fetch photos from Flickr (flickr.photos.search)
#           │
#           ▼
#   Step 4: For each photo:
#              • Canonicalize its existing tags
#              • See if any match our lookup keys
#              • If match → call flickr.photos.addTags
#              • If -DryRun → just show what would happen
#
# -----------------------------------------------------------------------------
# IMPORTANT POINTS:
#   - Flickr requires OAuth 1.0 signed requests
#   - Tags must be passed as one string, with spaces between tags
#   - Multi-word tags must be quoted ("Red-tailed Hawk")
#   - PowerShell hashtables (@{...}) = key/value pairs
#   - PowerShell arrays (@(...))     = ordered lists of values
# -----------------------------------------------------------------------------

param (
    [string]$File,           # Path to the JSON file containing photo/tag data
    [string]$Key,            # JSON key to match against photo tags
    [string[]]$Tag,          # JSON keys whose values will be added as Flickr tags
    [switch]$Reverse,        # Optional: reverse JSON array order before processing
    [string]$Match,          # Optional: regex to filter key values
    [string]$List,           # Optional: prefix to add IOC-style tags
    [int]$Days,              # Optional: limit to photos uploaded in the last N days
    [switch]$DryRun,         # Optional: do not call Flickr API, just simulate
    [switch]$Help            # Optional: show usage message
)

# Ensure console output uses UTF-8 (important for special characters in tags)
$OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# --- Function: Show usage/help message ---
function Show-Usage {
    Write-Host @"
Usage:
  .\set_tags.ps1 -File <jsonfile> -Key <keyname> -Tag <tag1,tag2,...>

Options:
  -File <jsonfile>   : JSON file containing an array of objects
  -Key <keyname>     : JSON key whose value is used to match photo tags
  -Tag <tag1,tag2>   : JSON keys whose values are added as new tags. 
                        Multiple tags can be passed as a comma-separated list:
                        -Tag Order,Family
                        or using array syntax: -Tag @('Order','Family')
  -Reverse           : Reverse JSON array before processing
  -Match <pattern>   : Regex filter on key values
  -List <listname>   : Add IOC-style tags
  -Days <num>        : Limit to photos uploaded in last N days
  -DryRun            : Show what would happen but don’t call Flickr
  -Help              : Show this message
"@
    exit
}

# --- RFC 3986 URL encode for OAuth 1.0 ---
function UrlEncode-RFC3986 {
    param([string]$s)
    if ($null -eq $s) { return "" }

    $encoded = [System.Uri]::EscapeDataString($s)

    # EscapeDataString is close, but leaves some characters unencoded.
    $encoded = $encoded -replace '!', '%21'
    $encoded = $encoded -replace '\*', '%2A'
    $encoded = $encoded -replace "'", '%27'
    $encoded = $encoded -replace '\(', '%28'
    $encoded = $encoded -replace '\)', '%29'

    return $encoded
}

# --- Generate OAuth 1.0 signature ---
function Get-OAuthSignature {
    param (
        [string]$Method,
        [string]$Url,
        [hashtable]$Params,
        [string]$ConsumerSecret,
        [string]$TokenSecret
    )

    $sortedParams = ($Params.GetEnumerator() | Sort-Object Name | ForEach-Object {
        "$(UrlEncode-RFC3986 $_.Key)=$(UrlEncode-RFC3986 $_.Value)"
    }) -join '&'

    $baseString = "$Method&$(UrlEncode-RFC3986 $Url)&$(UrlEncode-RFC3986 $sortedParams)"
    $signingKey = "$(UrlEncode-RFC3986 $ConsumerSecret)&$(UrlEncode-RFC3986 $TokenSecret)"

    $hmac = New-Object System.Security.Cryptography.HMACSHA1
    $hmac.Key = [System.Text.Encoding]::ASCII.GetBytes($signingKey)
    [Convert]::ToBase64String($hmac.ComputeHash([System.Text.Encoding]::ASCII.GetBytes($baseString)))
}

# --- Call Flickr REST API ---
function Invoke-FlickrApi {
    param (
        [string]$MethodName,
        [hashtable]$Params,
        [string]$ApiKey,
        [string]$ApiSecret,
        [string]$AuthToken,
        [string]$TokenSecret,
        [bool]$DryRun=$false
    )

    $baseUrl = "https://api.flickr.com/services/rest"

    # Hashtable of OAuth parameters
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

    # Merge params (photo_id, tags, etc.)
    $allParams = $oauthParams.Clone()
    foreach ($key in $Params.Keys) { $allParams[$key] = $Params[$key] }

    $allParams['oauth_signature'] = Get-OAuthSignature -Method "GET" -Url $baseUrl -Params $allParams `
        -ConsumerSecret $ApiSecret -TokenSecret $TokenSecret

    $query = ($allParams.GetEnumerator() | Sort-Object Name | ForEach-Object {
        "$(UrlEncode-RFC3986 $_.Key)=$(UrlEncode-RFC3986 $_.Value)"
    }) -join '&'

    $url = "${baseUrl}?$query"

    if ($DryRun -and $MethodName -eq 'flickr.photos.addTags') {
        Write-Host "[Dry Run] Would call: $url"
        return @{ success=$true; dry_run=$true; data=$null }
    }

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

# --- Helper: canonicalize tags ---
function Canonicalize-Tag { 
    param([string]$Tag) 
    $Tag -replace '[^a-zA-Z0-9:]', '' | ForEach-Object { $_.ToLower() } 
}

# -----------------------------------------------------------------------------
# MAIN SCRIPT EXECUTION
# -----------------------------------------------------------------------------

if ($Help) { Show-Usage }
if (-not $File -or -not $Key -or -not $Tag) { Show-Usage }

# $configFile = Join-Path $env:USERPROFILE "flickr_config.json"
# if (-not (Test-Path $configFile)) { Write-Error "Config $configFile not found!"; exit }
# $config = Get-Content $configFile -Raw | ConvertFrom-Json
# $apiKey = $config.api_key
# $apiSecret = $config.api_secret
# $authToken = $config.auth_token
# $tokenSecret = $config.token_secret

# Retrieve the secret as a string
$apiKey = (Get-Secret -Name FlickrApiKey -AsPlainText)
$apiSecret = (Get-Secret -Name FlickrApiSecret -AsPlainText)
$authToken = (Get-Secret -Name FlickrAuthToken -AsPlainText)
$tokenSecret = (Get-Secret -Name FlickrTokenSecret -AsPlainText)



if ($DryRun) { Write-Host "Running in dry-run mode. No tags will be added to photos." }

try { $data = Get-Content $File -Raw -Encoding UTF8 | ConvertFrom-Json } catch { Write-Error "Cannot read ${File}: $_"; exit }
if ($Reverse) { $data = $data | Sort-Object { $_ } -Descending }

# --- Step 1: bulk fetch all photos from Flickr ---
$page = 1; $photos = @()
do {
    $searchParams = @{
        user_id = 'me'
        extras  = 'tags,date_upload'
        per_page = 500
        page    = $page
    }

    if ($Days) {
        $searchParams['min_upload_date'] = [int]([DateTime]::UtcNow.AddDays(-$Days).Subtract((Get-Date "1970-01-01")).TotalSeconds)
    }

    $response = Invoke-FlickrApi -MethodName 'flickr.photos.search' -Params $searchParams `
        -ApiKey $apiKey -ApiSecret $apiSecret -AuthToken $authToken -TokenSecret $tokenSecret -DryRun:$DryRun

    if (-not $response.success) { Write-Warning "Error fetching photos: $($response.error_message)"; break }

    $photos += $response.data.photos.photo
    $page++
    $pages = $response.data.photos.pages
} while ($page -le $pages)

Write-Host "Fetched $($photos.Count) photos from Flickr"

# --- Step 2: build lookup from JSON ---
$lookup = @{}
foreach ($item in $data) {
    $keyValue = Canonicalize-Tag -Tag $item.$Key
    if ($Match -and $keyValue -notmatch $Match) { continue }
    $newTags = $Tag | ForEach-Object { $item.$_ } | Where-Object { $_ }
    if ($List) { 
        $newTags += @(
            $List, 
            "$List`:seq=`"$($item.'Seq.')`"", 
            "$List`:binomial=`"$($item.species)`"", 
            "$List`:name=`"$($item.English)`""
        ) 
    }
    $lookup[$keyValue] = $newTags -join ' '
}

# --- Step 3: process photos ---
foreach ($photo in $photos) {
    $photoTags = ($photo.tags -split '\s+') | ForEach-Object { Canonicalize-Tag $_ }
    $matchedKeys = $lookup.Keys | Where-Object { $photoTags -contains $_ }

    foreach ($key in $matchedKeys) {
        $tagsToAdd = $lookup[$key]
        if ($DryRun) {
            Write-Host "[Dry Run] PhotoID=$($photo.id), Title='$($photo.title)'"
            Write-Host "           Tags to add: $tagsToAdd"
            continue
        }
        Write-Host "Tags to add: $tagsToAdd"
        $resp = Invoke-FlickrApi -MethodName 'flickr.photos.addTags' -Params @{
            photo_id = $photo.id
            tags     = $tagsToAdd
        } -ApiKey $apiKey -ApiSecret $apiSecret -AuthToken $authToken -TokenSecret $tokenSecret

        if ($resp.success) { Write-Host "Tags added ($tagsToAdd) to '$($photo.title)'" }
        else { Write-Warning "Failed to add tags to '$($photo.title)': $($resp.error_message)" }
    }
}
