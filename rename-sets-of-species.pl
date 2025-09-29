#!/usr/bin/perl
# This script processes Flickr photosets whose titles match a bird species pattern
# (e.g., "Common Sparrow"). It checks if the canonicalized title matches the
# ioc151:binomial machine tag of the set's primary photo. If they match, the set
# is renamed to "A3 - HHHH - <original title>", where HHHH is the hexadecimal
# value of the ioc151:seq tag. If they don't match but ioc151:seq exists, it
# fetches the raw binomial name via flickr.tags.getListPhoto and renames to
# "A3 - HHHH - <raw binomial>". The script supports pagination, dry-run mode,
# and debug output.
#
# Usage: perl flickr_bird_sets.pl -i PREFIX [OPTIONS]
# Options:
#   -h, --help        Show help message and exit
#   -n, --dry-run     Simulate renaming without making changes
#   -d, --debug       Print Dumper output for the first two sets from flickr.photosets.getList
#   -i, --ioc PREFIX  Specify the IOC machine tag prefix (e.g., IOC151) [REQUIRED]
#
# Prerequisites:
# - Requires a Flickr API configuration file at $ENV{HOME}/saved-flickr.st
# - Uses Perl modules: Getopt::Long, Flickr::API, Data::Dumper
#
# Examples:
#   perl flickr_bird_sets.pl -i IOC151
#     Processes all sets, renaming those with matching titles (e.g., "Common Kestrel")
#     to "A3 - 0FCA - Common Kestrel" if binomial matches, or "A3 - 0FCA - falcotinnunculus"
#     if it doesn't but seq exists.
#   perl flickr_bird_sets.pl -i IOC151 -n
#     Dry-run mode: prints what would be renamed without making changes.
#   perl flickr_bird_sets.pl -i IOC151 -d
#     Debug mode: dumps the first two sets from flickr.photosets.getList response.

use strict;
use warnings;
use Getopt::Long;
use Flickr::API;
use Data::Dumper;

$\ = "\n";  # Set output record separator to newline
my ($help, $dry_run, $debug, $ioc_prefix);  # Command-line options

# Parse command-line options
GetOptions(
    'h|help'     => \$help,
    'n|dry-run'  => \$dry_run,
    'd|debug'    => \$debug,
    'i|ioc=s'    => \$ioc_prefix,
);

# Display help message if -h or --help is specified
if ($help) {
    print "This script processes Flickr sets with titles matching bird species pattern";
    print "Usage: $0 -i PREFIX [OPTIONS]";
    print "Options:";
    print "  -h, --help        Show this help message and exit";
    print "  -n, --dry-run     Simulate the renaming without making changes";
    print "  -d, --debug       Print Dumper output for the first two sets of flickr.photosets.getList";
    print "  -i, --ioc PREFIX  Specify the IOC machine tag prefix (e.g., IOC151) [REQUIRED]";
    print "\nNOTE: It assumes the user's tokens are initialized in the file '$ENV{HOME}/saved-flickr.st'";
    exit;
}

# Ensure ioc_prefix is provided
die "Error: --ioc PREFIX is required" unless defined $ioc_prefix;

# Initialize Flickr API configuration
my $config_file = "$ENV{HOME}/saved-flickr.st";  # Path to Flickr API config file
my $per_page = 500;  # Number of sets per API page
my $page = 1;  # Current page number
my $total_pages = 1;  # Total pages, updated after each API call
my $flickr = Flickr::API->import_storable_config($config_file);  # Initialize Flickr API client

# Function to canonicalize a tag for comparison
# Removes non-alphanumeric characters (except ':') and converts to lowercase
sub canonicalize_tag {
    my $tag = shift;
    $tag =~ s/[^a-z0-9:]//gi;  # Remove unwanted characters (global, case-insensitive)
    $tag = lc($tag);           # Lowercase the tag
    return $tag;
}

# Function to get raw binomial name from flickr.tags.getListPhoto
# Calls Flickr API to fetch tags for a photo and extracts the raw binomial value
sub get_raw_binomial {
    my ($photo_id, $ioc_prefix) = @_;  # Photo ID and IOC prefix
    my $response = $flickr->execute_method('flickr.tags.getListPhoto', {
        photo_id => $photo_id,
    });

    unless ($response->{success}) {
        print "Error fetching tags for photo $photo_id: $response->{error_message}";
        return undef;
    }

    my $tag_list = $response->as_hash->{photo}->{tags}->{tag};  # Get tag list
    $tag_list = [ $tag_list ] unless ref $tag_list eq 'ARRAY';  # Ensure array reference

    foreach my $tag (@$tag_list) {
        my $raw_tag = $tag->{raw};  # Raw tag value
        if ($raw_tag =~ /^$ioc_prefix:binomial=(.+)$/i) {  # Match binomial tag, case-insensitive
            return $1;  # Return raw binomial value
        }
    }

    return undef;  # Return undef if binomial tag not found
}

# Retrieve all sets using pagination
my $sets = [];  # Array to store all filtered sets
while ($page <= $total_pages) {
    # Fetch a page of photosets with machine tags for primary photos
    my $response = $flickr->execute_method('flickr.photosets.getList', {
        per_page => $per_page,
        page     => $page++,  # Increment page after use
        primary_photo_extras => 'machine_tags',  # Fetch machine tags for primary photo
    });

    die "Error: $response->{error_message}" unless $response->{success};  # Exit on API error

    my $s = $response->as_hash->{photosets}->{photoset};  # Extract photosets
    $s = [ $s ] unless ref $s eq 'ARRAY';  # Convert single photoset to array if needed
    print "Debug: Dumping first two sets from flickr.photosets.getList response", Dumper [@$s[0..1]] if $debug;  # Debug output for first two sets
    # Filter sets matching the bird species pattern (e.g., "Common Sparrow")
    my @filtered_sets = grep { $_->{title} =~ /^\s*[A-Z][a-z]+\s+[a-z]+\s*$/ } @$s;
    push @$sets, @filtered_sets;  # Add filtered sets to main array
    $total_pages = $response->as_hash->{photosets}->{pages};  # Update total pages
}

# Process each set
foreach my $set (@$sets) {
    my $title = $set->{title};  # Get set title

    # Canonicalize the set title for comparison
    my $canon_title = canonicalize_tag($title);

    # Get primary photo's machine tags from primary_photo_extras
    my $machine_tags = $set->{primary_photo_extras}->{machine_tags} || '';  # Default to empty string if missing
    my %tags;
    foreach my $tag (split /\s+/, $machine_tags) {
        if ($tag =~ /^$ioc_prefix:([^=]+)=(.+)$/i) {
            $tags{lc($1)} = $2;  # Store tag key-value pairs, lowercasing the key
        }
    }

    # Compare canonicalized title with IOC:binomial machine tag and ensure seq exists
    next unless exists $tags{binomial} && exists $tags{seq};

    # Get IOC:seq for the hexadecimal value
    my $seq = $tags{seq};
    next unless $seq =~ /^\d+$/;  # Ensure seq is numeric
    my $hex_seq = sprintf("%04X", $seq);  # Convert to 4-digit hexadecimal

    # Determine the title to use for renaming
    my $new_title_base = ($canon_title eq canonicalize_tag($tags{binomial}))
        ? $title
        : get_raw_binomial($set->{primary}, $ioc_prefix);  # Fetch raw binomial if no match
    next unless defined $new_title_base;  # Skip if no valid title or binomial

    my $new_title = "A3 - $hex_seq - $new_title_base";  # Construct new title

    if ($dry_run) {
        print "Would rename set '$title' (ID: $set->{id}) to '$new_title'";  # Dry-run output
        next;
    }

    # Rename the set
    my $edit_response = $flickr->execute_method('flickr.photosets.editMeta', {
        photoset_id => $set->{id},
        title       => $new_title,
    });

    if ($edit_response->{success}) {
        print "Renamed set '$title' (ID: $set->{id}) to '$new_title'";  # Success message
    } else {
        print "Error renaming set '$title' (ID: $set->{id}): $edit_response->{error_message}";  # Error message
    }
}

print "Processing complete!" unless $dry_run;  # Final message unless in dry-run mode