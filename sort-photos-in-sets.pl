#!/usr/bin/perl

# =============================================================================
# Script: sort-photos-in-sets.pl
#
# Description:
#   This Perl script reorders photos within Flickr photosets for the authenticated
#   user based on specified sorting criteria. It uses the Flickr API to fetch
#   photosets, retrieve photo metadata, sort the photos, and reorder them in the
#   sets. The script supports filtering photosets by title using a regex pattern,
#   various sorting keys (e.g., by date taken, views, upload date), and even
#   custom sorting via machine tags. A dry-run mode allows simulation without
#   making changes.
#
#   IMPORTANT: This script requires a pre-configured Flickr API token stored in
#   '$ENV{HOME}/saved-flickr.st'. You can generate this file using the Flickr::API
#   module's authentication tools (e.g., via a separate authentication script).
#
# Usage:
#   perl sort-photos-in-sets.pl [OPTIONS]
#
# Options:
#   -h, --help          Display this help message and exit.
#   -f, --filter=PATTERN
#                       Filter photosets by title using a regex pattern (case-insensitive).
#                       Default: '.*' (matches all photosets).
#   -s, --sort=KEY      Sorting criteria for photos within each set.
#                       Valid keys: 'views' (by view count, numeric),
#                                   'dateupload' (by upload date, numeric Unix timestamp),
#                                   'lastupdate' (by last update date, numeric Unix timestamp),
#                                   'datetaken' (by date taken, string comparison in YYYY-MM-DD HH:MM:SS format).
#                       Custom machine tag sorting: Use format 'namespace:predicate' to sort by
#                       a sequence number extracted from photo machine tags (e.g., 'album:order:seq').
#                       Falls back to 'datetaken' if sequences are equal or missing.
#                       Default: 'datetaken'.
#   -r, --reverse       Reverse the sorting order (e.g., descending instead of ascending).
#   -n, --dry-run      Simulate the sorting process: Print what would be done without
#                       making API calls to reorder photos.
#
# Examples:
#   1. Sort all photosets by date taken (default behavior):
#      perl sort-photos-in-sets.pl
#
#   2. Sort photosets with titles containing 'vacation' by views, in descending order:
#      perl sort-photos-in-sets.pl -f vacation -s views -r
#
#   3. Dry-run sort of all photosets by upload date:
#      perl sort-photos-in-sets.pl -s dateupload -n
#
#   4. Custom sorting using machine tags (e.g., tag like 'album:order=5'):
#      perl sort-photos-in-sets.pl -s 'album:order:seq' -f 'My Album'
#
#   5. Reverse sort by last update, filtering to photosets starting with '2023':
#      perl sort-photos-in-sets.pl -f '^2023' -s lastupdate -r
#
# Notes:
#   - The script fetches data in pages (up to 500 items per page) to handle large collections.
#   - Machine tags for custom sorting should be in the format 'namespace:predicate=value',
#     where value is a numeric sequence. Missing tags default to a high number (100000).
#   - Errors during API calls are logged to STDERR, and the script continues to the next set.
#   - Requires Perl modules: Getopt::Long, Data::Dumper, Flickr::API.
#
# Author: [Your Name or Anonymous]
# Version: 1.0
# Date: September 29, 2025
# =============================================================================

use strict;
use warnings;
use Getopt::Long;
use Data::Dumper;
use Flickr::API;

# Set output record and field separators for cleaner printing (newline for both)
($\, $,) = ("\n", "\n");

# Declare variables for command-line options with defaults
my $help;                   # Flag to display help
my $filter_pattern = '.*';  # Regex pattern to filter photoset titles (default: match all)
my $dry_run;                # Flag for dry-run mode (simulate without changes)
my $sort = 'datetaken';     # Sorting key (default: datetaken)
my $rev;                    # Flag to reverse sort order

# Parse command-line options using Getopt::Long
GetOptions(
    'h|help' => \$help,             # Help flag
    'f|filter=s' => \$filter_pattern, # Filter pattern for photoset titles
    'n|dry-run' => \$dry_run,        # Dry-run mode
    's|sort=s' => \$sort,            # Sorting key
    'r|reverse' => \$rev,            # Reverse order flag
);

# Validate the sorting key against allowed values
die "Error: Sort parameter ('$sort') must be one of 'views', 'dateupload', 'lastupdate', 'datetaken', or a machine tag pattern like 'namespace:predicate:seq'\n"
  unless $sort =~ /^(views|dateupload|lastupdate|datetaken|.+:seq)$/;

# If help flag is set, print detailed usage and exit
if ($help) {
    print <<'HELP';
This script reorders photos in Flickr photosets for the authenticated user based on specified criteria.
It fetches photosets, filters them by title regex, sorts photos within each set, and reorders via the API.

Usage: perl sort-photos-in-sets.pl [OPTIONS]

Options:
  -h, --help          Show this help message and exit.
  -f, --filter=PATTERN
                      Filter photosets by title using a case-insensitive regex pattern.
                      Default: '.*' (all photosets). Example: -f vacation (matches titles containing 'vacation').
  -s, --sort=KEY      Sort photos by:
                      - 'views': By view count (numeric, ascending).
                      - 'dateupload': By upload date (Unix timestamp, ascending).
                      - 'lastupdate': By last update date (Unix timestamp, ascending).
                      - 'datetaken': By date taken (string, YYYY-MM-DD HH:MM:SS, ascending).
                      Custom: 'namespace:predicate:seq' to sort by sequence from machine tags.
                      Default: 'datetaken'.
  -r, --reverse       Reverse the sort order (e.g., descending for numeric keys).
  -n, --dry-run      Simulate: Print photosets that would be sorted without reordering.

Examples:
  Sort all sets by date taken: perl sort-photos-in-sets.pl
  Sort '2023' sets by views descending: perl sort-photos-in-sets.pl -f '^2023' -s views -r
  Dry-run custom sort: perl sort-photos-in-sets.pl -s 'album:order:seq' -n

NOTE: Requires Flickr API tokens in '$ENV{HOME}/saved-flickr.st'.
HELP
    exit;
}

# Load Flickr API configuration from the stored token file
my $config_file = "$ENV{HOME}/saved-flickr.st";
my $flickr = Flickr::API->import_storable_config($config_file);

# Compile the filter pattern into a case-insensitive regex
my $re = qr/$filter_pattern/i;

# Initialize array to hold filtered photosets
my $photosets = [];

# Fetch photosets in paginated manner
my $page = 1;
my $pages = 1;
while ($page <= $pages) {
    # Call Flickr API to get list of photosets for the current page
    my $response = $flickr->execute_method('flickr.photosets.getList', {
        per_page => 500,  # Maximum per page to minimize API calls
        page => $page,
    });

    # If API call fails, warn and retry the current page
    warn "Error fetching photosets page $page: $response->{error_message}" and redo unless $response->{success};

    # Filter photosets by title regex and append to the list
    push @$photosets, grep { $_->{title} =~ $re } @{$response->as_hash->{photosets}->{photoset}};

    # Update pagination info
    $pages = $response->as_hash->{photosets}->{pages};
    $page = $response->as_hash->{photosets}->{page} + 1;
}

# In dry-run mode, print what would be sorted and exit
if ($dry_run) {
    print map { "Photoset $_->{title} will be sorted by $sort" . ($rev ? " (reversed)" : "") . "\n" } @$photosets;
    exit;
}

# Process each filtered photoset: fetch photos, sort, and reorder
foreach my $photoset (@$photosets) {
    # Initialize array to hold photos in the set
    my $photos = [];

    # Fetch photos in paginated manner
    my $page = 1;
    my $pages = 1;
    while ($page <= $pages) {
        # Call Flickr API to get photos in the set with extra metadata
        my $response = $flickr->execute_method('flickr.photosets.getPhotos', {
            photoset_id => $photoset->{id},
            per_page => 500,  # Maximum per page
            page => $page,
            extras => 'views,date_upload,date_taken,last_update,machine_tags',  # Metadata needed for sorting
        });

        # If API call fails, warn and retry the current page
        warn "Error fetching photos from $photoset->{title} (page $page): $response->{error_message}" and redo unless $response->{success};

        # Ensure the photo list is an array reference
        my $bunch = $response->as_hash->{photoset}->{photo};
        $bunch = [ $bunch ] unless 'ARRAY' eq ref $bunch;

        # Append photos to the list
        push @$photos, @$bunch;

        # Update pagination info
        $pages = $response->as_hash->{photoset}->{pages};
        $page = $response->as_hash->{photoset}->{page} + 1;
    }

    # Sort the photos based on the chosen key
    my @sorted_photos;
    if ($sort =~ /.+:seq/) {
        # Custom sorting via machine tags: extract sequence numbers
        my $tag_pattern = $sort;
        $tag_pattern =~ s/[^a-z0-9:]//ig;  # Sanitize to canonical form

        foreach my $photo (@$photos) {
            # Extract sequence from machine_tags like 'namespace:predicate=123'
            my ($seq) = $photo->{machine_tags} =~ /$tag_pattern=(\d+)/i;
            $photo->{seq} = defined $seq ? $seq : 100000;  # Default high value if missing
        }

        # Sort by sequence (numeric), fallback to datetaken (string) if ties
        @sorted_photos = sort {
            $a->{seq} <=> $b->{seq} || $b->{datetaken} cmp $a->{datetaken}
        } @$photos;
    } elsif ($sort eq 'datetaken') {
        # String comparison for datetaken (lexical order works for YYYY-MM-DD format)
        @sorted_photos = sort { $a->{$sort} cmp $b->{$sort} } @$photos;
    } else {
        # Numeric comparison for views, dateupload, lastupdate
        @sorted_photos = sort { $a->{$sort} <=> $b->{$sort} } @$photos;
    }

    # Apply reverse if flag is set
    @sorted_photos = reverse @sorted_photos if $rev;

    # Create comma-separated list of sorted photo IDs
    my $sorted_ids = join(',', map { $_->{id} } @sorted_photos);

    # Call API to reorder photos in the set
    my $response = $flickr->execute_method('flickr.photosets.reorderPhotos', {
        photoset_id => $photoset->{id},
        photo_ids => $sorted_ids,
    });

    # If reorder fails, warn and skip to next set
    warn "Error reordering photos in $photoset->{title} ($photoset->{id}): $response->{error_message}" and next unless $response->{success};

    # Print success message
    print "Photoset $photoset->{title} sorted by $sort" . ($rev ? " (reversed)" : "") . ".\n";
}