#!/usr/bin/perl

# This script uses the Flickr API to add tags to photos based on data from a JSON file.
# It processes a list of items from the JSON, searches for photos tagged with a specific key value,
# and adds additional tags derived from the JSON data to those photos.
# Optional filters include matching patterns, reversing the order, limiting to recent uploads,
# and adding specialized list-based tags.

use strict;                # Enforces strict syntax checking for safer code
use warnings;              # Enables warnings for potential issues
use Getopt::Long;          # Module for parsing command-line options
use Flickr::API;           # Flickr API interface
use Data::Dumper;          # Utility for dumping data structures (used for debugging)
use JSON;                  # JSON parsing module
use Time::Local;           # Module for time calculations (though not directly used here, included for potential extensions)
use URI::Escape;           # Module for URI escaping (not used in this script, possibly legacy)
binmode(STDOUT, ':utf8');  # Sets STDOUT to UTF-8 encoding for proper handling of international characters

$\ = "\n";                 # Sets the output record separator to newline
$, = ", ";                 # Sets the output field separator to comma-space (though not heavily used)
my $json = JSON->new->utf8;  # Creates a JSON object with UTF-8 support

# Import Flickr API configuration from a storable file in the user's home directory
# This file should contain API keys and authentication details
my $config_file = "$ENV{HOME}/saved-flickr.st";
my $flickr = Flickr::API->import_storable_config($config_file);

# Subroutine to print detailed usage information and exit
sub usage {
    print <<'USAGE';
Usage:
  This script adds tags to Flickr photos based on data from a JSON file.
  It searches for photos tagged with a 'key' value from each JSON object
  and appends additional tags specified by the provided tag keys.

  Basic syntax:
    $0 --file <jsonfile> --key <keyname> --tag <tagkey1> [--tag <tagkey2> ...]

  Short options:
    $0 -f <jsonfile> -k <keyname> -t <tagkey1> [--t <tagkey2> ...]

  Options:
    -f, --file <jsonfile>     : Path to the JSON file containing an array of hashes.
                                Each hash represents an item with keys for tagging.
    -k, --key <keyname>       : The key in each JSON hash whose value will be used
                                as the search tag for finding photos on Flickr.
    -t, --tag <tagkey>        : One or more keys from the JSON hashes whose values
                                will be added as new tags to the matching photos.
                                Can be specified multiple times.
    -r, --reverse             : Reverse the order of the JSON array before processing.
    -m, --match <pattern>     : Only process items where the key value matches this regex (case-insensitive).
    -l, --list <listname>     : Add specialized tags in the format:
                                <listname>, <listname>:seq="<Seq.>", <listname>:binomial="<species>",
                                <listname>:name="<English>".
                                Assumes JSON has 'Seq.', 'species', and 'English' keys.
    -d, --days <num>          : Limit processing to photos uploaded in the last <num> days.
                                Also pre-filters JSON items to only those with valid tags from recent photos.
    -h, --help                : Display this help message and exit.

  Example:
    $0 -f data.json -k species -t common_name -t habitat -d 30 -l birdlist

  Notes:
    - The JSON file should be an array of objects (hashes).
    - Flickr API configuration must be set up in ~/saved-flickr.st.
    - Tags are added with quotes if they contain spaces.
    - Canonicalization of tags: lowercase, remove non-alphanumeric except ':'.
    - Requires Perl modules: Getopt::Long, Flickr::API, JSON, etc.
USAGE
    exit;
}

# Parse command-line arguments using Getopt::Long
my ($file_name, $key_name, @tag_keys, $match, $list);
my $rev = undef;           # Flag for reversing the data array
my $days = undef;          # Optional number of days to limit photo uploads
GetOptions(
    "f|file=s" => \$file_name,
    "k|key=s" => \$key_name,
    "t|tag=s" => \@tag_keys,
    "r|reverse" => \$rev,
    "m|match=s" => \$match,
    "l|list=s" => \$list,
    "d|days=i" => \$days,  # Capture the days option (integer)
    "h|help" => \&usage    # Call usage sub if help is requested
);

# Ensure required options are provided; otherwise, show usage
usage() unless $file_name && $key_name && @tag_keys;

# Read the entire JSON file into a string
my $json_text = do {
    open(my $json_fh, "<", $file_name)
        or die("Can't open $file_name: $!");  # Die on file open error
    local $/;                                 # Slurp mode (read entire file)
    <$json_fh>
};

# Decode the JSON string into a Perl data structure (array of hashes)
my $data = $json->decode($json_text);

# Reverse the array if the --reverse option is set
$data = [reverse @$data] if defined $rev;

# Function to canonicalize a tag for comparison:
# - Remove all non-alphanumeric characters except ':'
# - Convert to lowercase
sub canonicalize_tag {
    my $tag = shift;
    $tag =~ s/[^a-z0-9:]//gi;  # Remove unwanted characters (global, case-insensitive)
    $tag = lc($tag);           # Lowercase the tag
    return $tag;
}

# If --days is provided, calculate the minimum upload date (Unix timestamp)
# and pre-filter the JSON data based on tags from recent photos
my $min_upload_date = undef;
if (defined $days) {
    my $time = time - ($days * 24 * 60 * 60);  # Subtract days in seconds from current time
    $min_upload_date = $time;                  # Set min_upload_date

    # Pre-fetch all unique raw tags from photos uploaded in the last $days days
    my %valid_tags;                            # Hash to store unique tags
    my $page = 0;                              # Start from page 0 (incremented before use)
    my $pages = 1;                             # Initial pages assumption

    # Loop through all pages of search results
    while (++$page <= $pages) {
        # Call Flickr API to search for photos
        my $response = $flickr->execute_method('flickr.photos.search', {
            user_id => 'me',                   # Current authenticated user
            min_upload_date => $min_upload_date,  # Filter by upload date
            per_page => 500,                   # Max per page for efficiency
            page => $page,                     # Current page
            extras => 'tags',                  # Include tags in response
        });

        # Warn and break if API call fails
        warn "Error retrieving photos: $response->{error_message}\n\n" and last unless $response->{success};

        # Extract photos array from response
        my $photos = $response->as_hash()->{photos}->{photo} // next;  # Skip if no photos
        $photos = [ $photos ] unless ref $photos eq 'ARRAY';          # Ensure array ref even if single photo

        # Collect unique raw tags from each photo
        foreach my $photo (@$photos) {
            my @tags = split ' ', $photo->{tags};  # Split space-separated tags
            $valid_tags{$_} = 1 for @tags;        # Add to hash (keys are unique)
        }

        # Update total pages from response
        $pages = $response->as_hash()->{photos}->{pages};
    }

    # Filter the JSON data to only include items where the canonicalized key value
    # matches one of the valid tags from recent photos
    @$data = grep { exists $valid_tags{ canonicalize_tag($_->{$key_name}) } } @$data;
}

# Process each item (hash) in the (possibly filtered) data array
foreach my $hash (@$data) {
    my $key_value = $hash->{$key_name};  # Get the value for the search key

    # Skip this item if --match is set and the key_value doesn't match the pattern (case-insensitive)
    next if $match && $key_value !~ m/$match/i;

    # Prepare search parameters for Flickr photo search
    my %search_params = (
        user_id => 'me',         # Current user
        tags => $key_value,      # Search for photos with this tag
        per_page => 500,         # Max results per page
        page => 1,               # Start at page 1 (single page assumed, but could be paginated if needed)
    );
    
    # Add min_upload_date to search if --days is provided
    $search_params{min_upload_date} = $min_upload_date if defined $min_upload_date;

    # Execute the photo search API call
    my $response = $flickr->execute_method('flickr.photos.search', \%search_params);

    # Warn and skip if search fails
    warn "Error retrieving photos: $response->{error_message}\n\n" and next unless $response->{success};

    # Extract photos from response
    my $photos = $response->as_hash()->{photos}->{photo};
    $photos = [ $photos ] unless ref $photos eq 'ARRAY';  # Ensure array ref

    # Process each matching photo
    foreach my $photo (@$photos) {
        # Skip if no photo ID (unlikely, but safety check)
        print qq|No photos with tag $key_value|, Dumper($photo) and next unless $photo->{id};

        # Collect new tags from the specified tag_keys in the hash, filtering out undef/empty
        my @newtags = grep { $_ } @$hash{@tag_keys};

        # Join tags with quotes (for multi-word tags)
        my $tags = join ' ', map { qq|"$_"| } @newtags;

        # If --list is provided, append additional structured tags
        if (defined $list) {
            $tags = join ' ', $tags, $list,
            qq|$list:seq="$hash->{'Seq.'}"|,   # Assumes 'Seq.' key exists
            qq|$list:binomial="$hash->{'species'}"|,  # Assumes 'species' key
            qq|$list:name="$hash->{'English'}"|;      # Assumes 'English' key
        }

        # Execute API call to add the new tags to the photo
        my $response = $flickr->execute_method('flickr.photos.addTags', {
            photo_id => $photo->{id},  # Photo ID to tag
            tags => $tags               # Space-separated tags for Flickr
        });

        # Warn if tagging fails, otherwise print success
        warn "Error while trying to set new tags ($tags) to '$photo->{title}': $response->{error_message}\n\n" and next unless $response->{success};
        print "Done new tag $tags on '$photo->{title}'";    
    }
}