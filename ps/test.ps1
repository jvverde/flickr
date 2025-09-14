#Requires -Version 5.1
# This PowerShell script adds tags to Flickr photos based on data from a JSON file.
# It searches for photos tagged with a specific key value and adds additional tags
# derived from the JSON data. Supports OAuth 1.0a authentication for Flickr API requests.
# Includes a dry-run option to simulate tagging without making API calls.

# Set encoding to UTF-8 for proper handling of international characters
$OutputEncoding = [System.Text.Encoding]::UTF8

param (
    [string]$Test
)
Write-Host "Test parameter: $Test"