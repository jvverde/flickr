#!/usr/bin/perl
use strict;
use warnings;
use Getopt::Long;
use Flickr::API;
use Data::Dumper;

# ------------------------------------------------------------------------------
# Script: sort-sets.pl
#
# Description:
#   This script retrieves all Flickr photosets (albums) for the authenticated user,
#   sorts them based on either a specified token value in the set description (default: 'orderNO')
#   or the set title if the --title flag is provided, and reorders them on Flickr using the
#   Flickr API. It supports pagination to handle large numbers of sets and includes a dry-run
#   mode to preview the sort order without making changes.
#
# Usage:
#   perl flickr_sort-sets.pl [OPTIONS]
#
# Options:
#   -h, --help        Display this help message and exit.
#   -d, --desc token  Sort sets by the value in the format 'token:=value' found in
#                     the set description. The value is matched using the regex
#                     /^\s*token:=(\S+)/m, capturing non-whitespace characters.
#                     Defaults to 'orderNO' if not specified.
#   -t, --title       Sort sets by title instead of the description token.
#   -n, --dry-run     Print the sorted set order without applying changes to Flickr.
#
# Requirements:
#   - Perl modules: Getopt::Long, Flickr::API, Data::Dumper
#   - A Flickr API configuration file at $ENV{HOME}/saved-flickr.st with valid
#     authentication tokens.
#   - The user must have write permissions for the Flickr account to reorder sets.
#
# Examples:
#   1. Sort sets by 'orderNO:=value' in descriptions and reorder on Flickr:
#      perl flickr_sort-sets.pl
#   2. Sort sets by the value of 'priority:=value' in descriptions:
#      perl flickr_sort-sets.pl --desc priority
#   3. Sort sets by title:
#      perl flickr_sort-sets.pl --title
#   4. Preview sort order by 'orderNO:=value' without reordering:
#      perl flickr_sort-sets.pl --dry-run
#   5. Preview sort order by 'priority:=value' without reordering:
#      perl flickr_sort-sets.pl --desc priority --dry-run
#
# Notes:
#   - Sorting is lexicographical (ASCII order) for token values and titles.
#   - If a set lacks the specified token, it is assigned a default value of 'zzz'
#     and sorts after sets with valid token values.
#   - Non-ASCII values (e.g., 'orderNO:=é') are captured but sorted by UTF-8 byte
#     order, which may not match linguistic expectations.
#   - The script uses pagination (500 sets per page) to handle large collections.
# ------------------------------------------------------------------------------

# Set output record separator to newline for cleaner printing
$\ = "\n";

# Declare variables for command-line options
my ($help, $desc_token, $dry_run, $sort_by_title);

# Parse command-line options
GetOptions(
    'h|help'     => \$help,        # Show help message
    'd|desc=s'   => \$desc_token,  # Token for sorting by description
    't|title'    => \$sort_by_title, # Sort by title
    'n|dry-run'  => \$dry_run,     # Enable dry-run mode
);

# Display help message if requested
if ($help) {
    print <<"END_HELP";
flickr_sort-sets.pl - Sort and reorder Flickr photosets

Description:
  Retrieves all Flickr photosets for the authenticated user, sorts them by either
  a specified token value in the format 'token:=value' in the set description
  (default: 'orderNO') or by set title if --title is specified, and reorders them
  on Flickr. Supports pagination and dry-run mode.

Usage:
  $0 [OPTIONS]

Options:
  -h, --help        Display this help message and exit.
  -d, --desc token  Sort sets by the value of 'token:=value' in the set description.
                    Defaults to 'orderNO'. Example: 'orderNO:=2' sorts before
                    'orderNO:=10' (lexicographical order).
  -t, --title       Sort sets by title instead of description token.
  -n, --dry-run     Print the sorted set order (ID, title, and token value if applicable)
                    without reordering sets on Flickr.

Examples:
  1. Sort by 'orderNO:=value' and reorder:
     $0
  2. Sort by 'priority:=value' in descriptions:
     $0 --desc priority
  3. Sort by title:
     $0 --title
  4. Preview sort order for 'orderNO:=value' without changes:
     $0 --dry-run
  5. Preview sort order for 'priority:=value' without changes:
     $0 --desc priority --dry-run

Requirements:
  - Flickr API configuration file at $ENV{HOME}/saved-flickr.st with valid tokens.
  - Perl modules: Getopt::Long, Flickr::API, Data::Dumper.
  - Write permissions for the Flickr account to reorder sets.

Notes:
  - Uses lexicographical sorting (ASCII order).
  - Sets without the specified token are assigned 'zzz' and sort last.
  - Non-ASCII values are sorted by UTF-8 byte order.
END_HELP
    exit;
}

# Configuration for Flickr API
my $config_file = "$ENV{HOME}/saved-flickr.st"; # Path to Flickr API config file
my $per_page = 500;                             # Number of sets per API page
my $page = 1;                                   # Current page number
my $total_pages = 1;                            # Total pages, updated by API
my $flickr = Flickr::API->import_storable_config($config_file); # Initialize API client

# Retrieve all photosets using pagination
my $sets = []; # Array to store all photosets
while ($page <= $total_pages) {
    # Call Flickr API to get a page of photosets
    my $response = $flickr->execute_method('flickr.photosets.getList', {
        per_page => $per_page,
        page => $page,
    });

    # Check for API errors
    die "Error fetching sets: $response->{error_message}" unless $response->{success};

    # Extract photosets from response
    my $s = $response->as_hash->{photosets}->{photoset};
    # Ensure $s is an array reference (API may return a single hash if only one set)
    $s = [ $s ] unless ref $s eq 'ARRAY';
    # Append photosets to the main array
    push @$sets, @$s;
    # Update total pages from response
    $total_pages = $response->as_hash->{photosets}->{pages};
    $page++; # Move to next page
}

# Set default description token if not specified
$desc_token = 'orderNO' unless $desc_token || $sort_by_title;

# Sort the photosets
my @sorted_sets;
if ($sort_by_title) {
    # Sort by title in lexicographical order
    @sorted_sets = sort { $a->{title} cmp $b->{title} } @$sets;
} else {
    # Sort by token:=value in description
    @sorted_sets = sort {
        # Default value for sets without the token (sorts last)
        my $a_value = 'zzz';
        my $b_value = 'zzz';
        
        # Extract value from description if token exists
        if ($a->{description} && $a->{description} =~ /^\s*$desc_token:=(\S+)/m) {
            $a_value = $1; # Capture value after token:=
        }
        if ($b->{description} && $b->{description} =~ /^\s*$desc_token:=(\S+)/m) {
            $b_value = $1; # Capture value after token:=
        }
        
        # Compare token values; fallback to title if equal
        $a_value cmp $b_value || $a->{title} cmp $b->{title}
    } @$sets;
}

# Extract set IDs for reordering
my @set_ids = map { $_->{id} } @sorted_sets;

# Dry-run mode: print sorted order and exit
if ($dry_run) {
    print "Dry-run mode: Sets will be ordered as follows (not applied to Flickr):";
    for my $i (0..$#sorted_sets) {
        my $set = $sorted_sets[$i];
        # Extract token value for display, if applicable
        my $value = $desc_token && $set->{description} && $set->{description} =~ /^\s*$desc_token:=(\S+)/m ? $1 : 'N/A';
        # Print set details
        print "Set ID: $set->{id}, Title: $set->{title}, " . ($desc_token ? "Token Value: $value" : "");
    }
    exit;
}

# Reorder sets on Flickr
my $ordered_set_ids = join(',', @set_ids); # Join set IDs into a comma-separated string
my $order_response = $flickr->execute_method('flickr.photosets.orderSets', {
    photoset_ids => $ordered_set_ids,
});

# Check for API errors during reordering
die "Error reordering sets: $order_response->{error_message}" unless $order_response->{success};

# Confirm successful reordering
print "Sets reordered successfully!";