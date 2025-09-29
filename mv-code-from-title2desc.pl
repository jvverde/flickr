#!/usr/bin/perl
use strict;
use warnings;
use Getopt::Long;
use Flickr::API;
use Data::Dumper;

# This script updates Flickr photoset titles and descriptions based on a specific
# pattern in the title. It extracts a pattern from the title, optionally adds it
# to the description with a user-specified token, and optionally removes the
# pattern from the title. The script processes sets in batches using Flickr API
# pagination and supports dry-run mode for testing changes without applying them.
#
# Default Pattern:
#   The script matches titles starting with the pattern:
#     ^\s*[0-9A-F]{2}\s*-\s*[0-9A-F]{2,4}\s*-\s*
#   Example: "A3 - 2BED - Tangara inornata" matches, with "A3 - 2BED - " extracted.
#
# Features:
#   - Extracts the pattern and sanitizes it (removes whitespace and trailing hyphens).
#   - Adds or replaces a line in the description with "<token>:=<sanitized_pattern>".
#   - Removes the pattern from the title if --remove is specified.
#   - Supports --dry-run to simulate changes without modifying Flickr.
#   - Limits updates to a specified number of sets with --count (ignored in dry-run).
#   - Further restricts processed sets with --match to filter titles by a custom regex.
#   - Handles API errors by warning, sleeping for 1 second, and retrying.
#   - Requires a Flickr API config file at $ENV{HOME}/saved-flickr.st.
#
# Command-Line Options:
#   -h, --help        Display this help message and exit.
#   -t, --token=STR   Prepend the specified token to the sanitized pattern in the description.
#   -n, --dry-run     Simulate changes without calling the Flickr API.
#   -r, --remove      Remove the matched pattern from the set title.
#   -c, --count=NUM   Limit updates to NUM sets (ignored in dry-run).
#   -m, --match=REGEX Only process sets with titles matching the given regex (applied after default pattern).
#
# Example Commands:
#   1. Add token to description:
#      ./flickr_sets.pl --token=orderNO
#      - For title "A3 - 2BED - Tangara inornata", adds "orderNO:=A3-2BED" to description.
#      Output: Updated description for set 'A3 - 2BED - Tangara inornata' to include 'orderNO:=A3-2BED'
#
#   2. Remove pattern from title and add token:
#      ./flickr_sets.pl --token=orderNO --remove
#      - For title "B0 - 123 - Album", updates title to "Album" and adds "orderNO:=B0-123" to description.
#      Output: Updated title for set 'B0 - 123 - Album' to 'Album'
#              Updated description for set 'B0 - 123 - Album' to include 'orderNO:=B0-123'
#
#   3. Restrict to titles starting with "B0":
#      ./flickr_sets.pl --token=orderNO --match="^B0"
#      - Only processes sets like "B0 - 123 - Album", ignoring "A3 - 2BED - Tangara inornata".
#      Output: Updated description for set 'B0 - 123 - Album' to include 'orderNO:=B0-123'
#
#   4. Dry-run with count limit:
#      ./flickr_sets.pl --token=orderNO --dry-run --count=1
#      - Simulates updating one set without API calls.
#      Output: Dry-run: Would update description for set 'A3 - 2BED - Tangara inornata' to include 'orderNO:=A3-2BED'
#
# Notes:
#   - The script assumes the Flickr API config file exists at $ENV{HOME}/saved-flickr.st.
#   - Invalid --match patterns cause the script to exit with an error.
#   - API errors trigger a warning, 1-second sleep, and retry (use with caution to avoid infinite loops).

$\ = "\n";
my ($help, $token, $dry_run, $remove, $count, $match);

GetOptions(
    'h|help' => \$help,
    't|token=s' => \$token,
    'n|dry-run' => \$dry_run,
    'r|remove' => \$remove,
    'c|count=i' => \$count,
    'm|match=s' => \$match,
);

if ($help) {
    print <<'END_HELP';
flickr_sets.pl - Update Flickr photoset titles and descriptions

This script processes Flickr photosets whose titles match a specific pattern,
optionally updating their descriptions with a token and sanitized pattern, and
optionally removing the pattern from the title. It uses the Flickr API and
requires a configuration file at $HOME/saved-flickr.st.

Usage: $0 [OPTIONS]

Options:
  -h, --help        Display this help message and exit.
  -t, --token=STR   Add or replace a line in the description with "<token>:=<sanitized_pattern>",
                    where the pattern is extracted from the title and sanitized (whitespace and
                    trailing hyphens removed).
  -n, --dry-run     Simulate changes without modifying Flickr (ignores --count).
  -r, --remove      Remove the matched pattern from the set title.
  -c, --count=NUM   Limit updates to NUM sets (ignored in dry-run mode).
  -m, --match=REGEX Further restrict processing to sets with titles matching the given regex,
                    applied after the default pattern (^\\s*[0-9A-F]{2}\\s*-\\s*[0-9A-F]{2,4}\\s*-\\s*).

Default Pattern:
  The script matches titles starting with:
    ^\\s*[0-9A-F]{2}\\s*-\\s*[0-9A-F]{2,4}\\s*-\\s*
  Example: "A3 - 2BED - Tangara inornata" matches, extracting "A3 - 2BED - ".

Examples:
  1. Add token to description:
     $0 --token=orderNO
     - Updates description of "A3 - 2BED - Tangara inornata" to include "orderNO:=A3-2BED".

  2. Remove pattern and add token:
     $0 --token=orderNO --remove
     - Updates title "B0 - 123 - Album" to "Album" and adds "orderNO:=B0-123" to description.

  3. Restrict to titles starting with "B0":
     $0 --token=orderNO --match="^B0"
     - Only processes sets like "B0 - 123 - Album".

  4. Simulate changes:
     $0 --token=orderNO --dry-run --count=1
     - Shows what would happen for one set without making API calls.

Notes:
  - Requires either --token or --remove to be specified.
  - Invalid --match regex patterns will cause the script to exit with an error.
  - API errors trigger a warning, 1-second sleep, and retry.
END_HELP
    exit;
}

unless ($token || $remove) {
    warn "Error: Either --token or --remove must be specified";
    exit 1;
}

# Validate match pattern if provided
if (defined $match) {
    eval { "" =~ /$match/ };
    if ($@) {
        warn "Error: Invalid regex pattern for --match: $@";
        exit 1;
    }
}

my $config_file = "$ENV{HOME}/saved-flickr.st";
my $per_page = 500;
my $page = 1;
my $total_pages = 1;
my $flickr = Flickr::API->import_storable_config($config_file);
my $update_count = 0;

# Retrieve all the sets using pagination, filtering by title pattern
my $sets = [];
my $pattern = '^\s*[0-9A-F]{2}\s*-\s*[0-9A-F]{2,4}\s*-\s*';
while ($page <= $total_pages) {
    my $response = $flickr->execute_method('flickr.photosets.getList', {
        per_page => $per_page,
        page => $page,
    });

    unless ($response->{success}) {
        warn "Error fetching sets: $response->{error_message}";
        sleep 1;
        redo;
    }

    my $s = $response->as_hash->{photosets}->{photoset};
    $s = [ $s ] unless ref $s eq 'ARRAY';
    my @filtered = grep { $_->{title} =~ /$pattern/ } @$s;
    if (defined $match) {
        @filtered = grep { $_->{title} =~ /$match/ } @filtered;
    }
    push @$sets, @filtered;
    $total_pages = $response->as_hash->{photosets}->{pages};
    $page++;
}

# Process each set
foreach my $set (@$sets) {
    my $title = $set->{title};
    my $description = $set->{description} || '';
    my $new_title = $title;
    my $new_description = $description;

    # Extract pattern from title (guaranteed to match due to grep)
    my ($matched) = $title =~ /($pattern)/;
    next unless defined $matched;

    # Sanitize matched pattern by removing all whitespace and trailing hyphens
    my $sanitized = $matched;
    $sanitized =~ s/\s+//g;
    $sanitized =~ s/-+$//;

    # Prepare the token line
    my $token_line = "$token:=$sanitized" if $token;

    # Update description if token is provided
    if ($token) {
        # Check if description already has a line starting with token:=
        if ($description =~ /^$token:=.+$/m) {
            # Replace all existing token lines
            $new_description =~ s/^$token:=.+$/$token_line/gm;
        } else {
            # Add token line at the top
            $new_description = "$token_line\n$new_description";
        }
    }

    # Remove pattern from title if requested
    if ($remove) {
        $new_title =~ s/$pattern//;
    }

    # Apply changes unless dry-run
    unless ($dry_run) {
        if (($token && $new_description ne $description) || ($remove && $new_title ne $title)) {
            my $response = $flickr->execute_method('flickr.photosets.editMeta', {
                photoset_id => $set->{id},
                title => $new_title,
                description => $new_description,
            });
            unless ($response->{success}) {
                warn "Error updating set '$title': $response->{error_message}";
                sleep 1;
                redo;
            }
            $update_count++;
            if ($token && $new_description ne $description) {
                print "Updated description for set '$title' to include '$token:=$sanitized'";
            }
            if ($remove && $new_title ne $title) {
                print "Updated title for set '$title' to '$new_title'";
            }
            last if defined $count && $update_count >= $count;
        }
    } else {
        if ($token && $new_description ne $description) {
            print "Dry-run: Would update description for set '$title' to include '$token:=$sanitized'";
        }
        if ($remove && $new_title ne $title) {
            print "Dry-run: Would remove pattern from title '$title' to '$new_title'";
        }
    }
}