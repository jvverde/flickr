#!/usr/bin/perl
# This script interacts with the Flickr API to find photo sets with titles matching
# the pattern 'HH - anychar', where 'HH' is exactly two hexadecimal digits (0-9, A-F)
# and 'anychar' is any sequence that does not start with 'HH - ' or 'HHHH - ' (2 or 4
# hex digits followed by a hyphen and optional whitespace). It modifies matching titles
# to 'HH - 00 - anychar', inserting ' - 00 - ' after the initial 'HH'. The script
# supports pagination for fetching sets and includes a dry-run mode to simulate changes.
# It requires a Flickr API configuration file at $ENV{HOME}/saved-flickr.st.
#
# Examples:
# - Input: '6A - Zuro Loma' → Output: '6A - 00 - Zuro Loma'
# - Input: '21 - Suécia (2018+2019)' → Output: '21 - 00 - Suécia (2018+2019)'
# - Input: 'A1 - 02 - Rheidae' → Excluded (anychar starts with '02 - ')
# - Input: 'A3 - 0 - Motacilla yarrellii' → Output: 'A3 - 00 - 0 - Motacilla yarrellii'

use strict;                # Enforce strict variable declaration
use warnings;              # Enable warning messages for better debugging
use Getopt::Long;          # Parse command-line options
use Flickr::API;           # Interface with Flickr API

$\ = "\n";                 # Set output record separator to newline for print statements

# Declare variables for command-line options
my ($help, $dry_run);

# Parse command-line options
GetOptions(
    'h|help' => \$help,    # -h or --help: Show usage information
    'n|dry-run' => \$dry_run,  # -n or --dry-run: Simulate changes without applying them
);

# If help flag is set, display usage information and exit
if ($help) {
    print "This script finds Flickr sets with titles in the form 'HH - anychar'";
    print "where HH is a hexadecimal digit and anychar is any sequence not starting with HH - ";
    print "and modifies the title to 'HH - 00 - anychar'.";
    print "Usage: $0 [-h|--help] [-n|--dry-run]";
    exit;
}

# Configuration for Flickr API
my $config_file = "$ENV{HOME}/saved-flickr.st";  # Path to Flickr API config file
my $per_page = 500;                              # Number of sets to fetch per API call
my $page = 1;                                    # Current page number for pagination
my $total_pages = 1;                             # Total pages, updated after API call
my $flickr = Flickr::API->import_storable_config($config_file);  # Initialize Flickr API

# Regex pattern to match titles in the form 'HH - anychar'
# - ^([0-9A-F]{2}): Captures two hex digits (HH) into $1
# - \s*-: Matches a hyphen with optional whitespace before it
# - (?!\s*[0-9A-F]{2,4}\s*-\s*): Negative lookahead ensures anychar does not start with
#   2 or 4 hex digits followed by a hyphen and optional whitespace
# - \s*: Matches optional whitespace after the hyphen
# - (.+): Captures the anychar part into $2
# - $: Anchors the match at the end of the string
my $pattern = '^([0-9A-F]{2})\s*-(?!\s*[0-9A-F]{2,4}\s*-\s*)\s*(.+)$';

# Loop through pages of Flickr sets
while ($page <= $total_pages) {
    # Fetch a page of photo sets using the Flickr API
    my $response = $flickr->execute_method('flickr.photosets.getList', {
        per_page => $per_page,  # Number of sets per page
        page => $page,          # Current page number
    });

    # Check if the API call was successful
    unless ($response->{success}) {
        warn "Error fetching sets: $response->{error_message}";
        sleep 1;  # Wait 1 second before retrying
        redo;     # Retry the current page
    }

    # Extract the list of photo sets from the response
    my $sets = $response->as_hash->{photosets}->{photoset};
    # Ensure $sets is an array reference (handle single-set case)
    $sets = [ $sets ] unless ref $sets eq 'ARRAY';
    # Filter sets whose titles match the pattern
    my @filtered = grep { $_->{title} =~ /$pattern/ } @$sets;

    # Process each matching set
    for my $set (@filtered) {
        my $title = $set->{title};  # Get the current title
        # Extract HH and anychar from the title using the pattern
        my ($hex, $anychar) = $title =~ /$pattern/;
        
        # Construct the new title: HH - 00 - anychar
        my $new_title = "$hex - 00 - $anychar";
        
        # If dry-run mode, simulate the change
        if ($dry_run) {
            print "Dry-run: Would change title '$title' to '$new_title'";
        } else {
            # Update the set's title via the Flickr API
            my $response = $flickr->execute_method('flickr.photosets.editMeta', {
                photoset_id => $set->{id},         # ID of the photo set
                title => $new_title,               # New title
                description => $set->{description} || '',  # Preserve existing description
            });
            # Check if the update was successful
            unless ($response->{success}) {
                warn "Error updating set '$title': $response->{error_message}";
                sleep 1;  # Wait 1 second before retrying
                redo;     # Retry the update
            }
            print "Changed title '$title' to '$new_title'";
        }
    }

    # Update total pages from the API response and increment page number
    $total_pages = $response->as_hash->{photosets}->{pages};
    $page++;
}