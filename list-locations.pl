#!/usr/bin/perl

###############################################################################
# Script Name: flickr_outside_portugal.pl
#
# Description:
#   This script uses the Flickr API to search for photos (optionally filtered
#   by a tag and/or limited to recent uploads). It then retrieves each photo's
#   geolocation and lists only those photos that are located **outside Portugal**.
#
# Features:
#   - Uses Flickr API configuration stored in ~/saved-flickr.st.
#   - Supports optional search tag (--tag) and recent uploads limit (--days).
#   - Retrieves geolocation data for each photo.
#   - Prints photo title, ID, URL, and all available location fields
#     (country, region, county, locality, neighbourhood, latitude, longitude, accuracy).
#   - Skips undefined, empty, or invalid fields (e.g., neighbourhood = {}).
#
# Usage Examples:
#   perl flickr_outside_portugal.pl
#   perl flickr_outside_portugal.pl -t sunset
#   perl flickr_outside_portugal.pl -t bird -d 30
#
# Requirements:
#   - Perl modules: Getopt::Long, Flickr::API
#   - Flickr API configuration in ~/saved-flickr.st
#
# Author: <Your Name>
# Date  : 2025-09-27
###############################################################################

use strict;
use warnings;
use Getopt::Long;          # For command-line options
use Flickr::API;           # Flickr API interface
use Data::Dumper;          # For debugging (optional)
binmode(STDOUT, ':utf8');  # Ensure proper UTF-8 output

# Print newlines automatically after each print
$\ = "\n";

# Path to Flickr API config file
my $config_file = "$ENV{HOME}/saved-flickr.st";
my $flickr;
eval {
    $flickr = Flickr::API->import_storable_config($config_file);
};
if ($@) {
    die "Failed to load Flickr API config from $config_file: $@";
}

###############################################################################
# Subroutine: usage
# Prints help/usage instructions and exits
###############################################################################
sub usage {
    print <<'USAGE';
Usage:
  This script searches Flickr photos (optionally by a tag) and lists those
  with geolocation outside Portugal.

Options:
  -t, --tag <tagname>       : Optional tag to search for photos on Flickr.
  -d, --days <num>          : Limit to photos uploaded in the last <num> days.
  -h, --help                : Display this help message and exit.

Examples:
  perl flickr_outside_portugal.pl -t sunset -d 30
  perl flickr_outside_portugal.pl -d 7
  perl flickr_outside_portugal.pl

Notes:
  - Flickr API configuration must be in ~/saved-flickr.st.
  - Only photos with geolocation are listed.
  - Requires Perl modules: Getopt::Long, Flickr::API.
USAGE
    exit;
}

###############################################################################
# Parse command-line arguments
###############################################################################
my ($tag, $days);
GetOptions(
    "t|tag=s" => \$tag,
    "d|days=i" => \$days,
    "h|help" => \&usage
);

###############################################################################
# Prepare Flickr search parameters
###############################################################################
my %search_params = (
    user_id  => 'me',   # Current authenticated user
    per_page => 500,    # Maximum photos per page
    page     => 1,      # Start at page 1
);

# If tag is provided, add it (quote if contains spaces)
$search_params{tags} = $tag =~ /\s/ ? qq|"$tag"| : $tag if defined $tag;

# If days is provided, calculate minimum upload timestamp
$search_params{min_upload_date} = time - ($days * 24 * 60 * 60) if defined $days;

###############################################################################
# Retrieve all matching photos with pagination
###############################################################################
my @matching_photos;
my $page = 1;
while (1) {
    $search_params{page} = $page;
    my $response = $flickr->execute_method('flickr.photos.search', \%search_params);

    unless ($response->{success}) {
        warn "Error retrieving photos: $response->{error_message}";
        last;
    }

    my $photos = $response->as_hash->{photos}{photo} // [];
    $photos = [ $photos ] unless ref $photos eq 'ARRAY';
    push @matching_photos, @$photos;

    # Stop when fewer than per_page results (no more pages)
    last if scalar @$photos < $search_params{per_page};
    $page++;
}

###############################################################################
# Define the list of location fields we want to extract
###############################################################################
my @location_fields = qw(country region county locality neighbourhood latitude longitude accuracy);

###############################################################################
# Process each photo and list those outside Portugal
###############################################################################
foreach my $photo (@matching_photos) {
    next unless $photo->{id} && $photo->{owner};  # Safety check

    # Get geolocation info for the photo
    my $geo_response = $flickr->execute_method('flickr.photos.geo.getLocation', {
        photo_id => $photo->{id}
    });
    next unless $geo_response->{success};

    my $hash = $geo_response->as_hash;
    next unless $hash->{photo} && $hash->{photo}{location};
    my $location = $hash->{photo}{location};

    # Skip photos located in Portugal
    my $country = $location->{country} // '';
    next if $country eq 'Portugal';

    # Collect defined, non-empty fields
    my %fields;
    foreach my $f (@location_fields) {
        my $val = $location->{$f};
        # Only keep scalars (strings/numbers), ignore empty hashrefs (neighbourhood sometimes {})
        $fields{$f} = $val if defined $val && !ref($val) && $val ne '';
    }

    # Build Flickr photo URL
    my $url   = "https://www.flickr.com/photos/$photo->{owner}/$photo->{id}/";
    my $title = $photo->{title} // '(untitled)';

    # Print photo information
    print "Photo outside Portugal: '$title' (ID: $photo->{id}) - $url";
    foreach my $f (@location_fields) {
        print "   $f: $fields{$f}" if exists $fields{$f};
    }
    print ""; # Blank line for readability
}
