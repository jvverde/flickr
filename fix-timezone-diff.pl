#!/usr/bin/perl

# This script retrieves photos from Flickr with geolocation data, queries the GeoNames API to determine
# the timezone of each photo's location at the time it was taken, and calculates the time difference
# relative to Lisbon, Portugal. It supports command-line arguments for specifying the GeoNames username,
# filtering photos by tag, or limiting by upload date, and outputs details such as photo title, URL,
# coordinates, timestamp, timezone, and time difference. The script uses strict and warnings for robust
# error handling, and relies on external APIs (Flickr and GeoNames) for data retrieval.

use strict;                      # Enforce strict variable declaration and scoping
use warnings;                    # Enable warning messages for potential issues
use Getopt::Long;                # For parsing command-line options
use Flickr::API;                 # Flickr API interface for retrieving photo data
use LWP::UserAgent;              # HTTP client for making requests to GeoNames API
use JSON;                        # For parsing JSON responses from GeoNames
use POSIX qw(strftime);          # For formatting timestamps
use Time::Local;                 # For converting dates to epoch timestamps
use DateTime;                    # For handling timezone offsets and calculations

# Set UTF-8 encoding for STDOUT to handle non-ASCII characters
binmode(STDOUT, ':utf8');
# Set newline as output record separator
$\ = "\n";

# Flickr API configuration file path
my $config_file = "$ENV{HOME}/saved-flickr.st";
my $flickr;
# Attempt to load Flickr API configuration from storable file
eval {
    $flickr = Flickr::API->import_storable_config($config_file);
};
# Handle errors if configuration loading fails
if ($@) {
    die "Failed to load Flickr API config from $config_file: $@";
}

# ------------------------------
# Subroutine to display usage information and exit
sub usage {
    print <<'USAGE';
Usage:
  perl flickr_timezone.pl [options]

Options:
  -u, --user <username> : GeoNames username for API access (required).
  -t, --tag <tag>       : Optional tag to search.
  -d, --days <num>      : Limit to photos uploaded in last <num> days.
  -h, --help            : Show this help.
USAGE
    exit;
}

# ------------------------------
# Parse command-line arguments
my ($geonames_user, $tag, $days);  # Variables to store GeoNames username, tag, and days options
GetOptions(
    "u|user=s" => \$geonames_user,   # Required GeoNames username
    "t|tag=s" => \$tag,              # Optional tag to filter photos
    "d|days=i" => \$days,            # Optional number of days to filter recent uploads
    "h|help" => \&usage,             # Display help and exit
) or usage();  # Exit with usage if GetOptions fails

# Ensure GeoNames username is provided
unless (defined $geonames_user) {
    warn "Error: GeoNames username is required.";
    usage();
}

# ------------------------------
# Set up Flickr search parameters
my %search_params = (
    user_id  => 'me',            # Search for photos from authenticated user
    per_page => 500,             # Maximum photos per page (Flickr API limit)
    page     => 1,               # Start with first page
    has_geo  => 1,               # Require photos to have geolocation data
    extras   => 'geo,date_taken',# Include latitude, longitude, and date taken
);

# Add tag filter if provided
$search_params{tags} = $tag if defined $tag;
# Add time filter for photos uploaded in the last <days> if provided
$search_params{min_upload_date} = time - ($days*24*3600) if defined $days;

# ------------------------------
# Retrieve all matching photos from Flickr
my @matching_photos;  # Array to store all retrieved photos
my $page = 1;         # Initialize page counter
while (1) {
    $search_params{page} = $page;  # Set current page for API request
    # Execute Flickr photos.search API method
    my $response = $flickr->execute_method('flickr.photos.search', \%search_params);

    # Check if API call was successful
    unless ($response->{success}) {
        warn "Error retrieving photos: $response->{error_message}";
        last;
    }

    # Extract photos from response
    my $photos = $response->as_hash->{photos}{photo} // [];
    # Ensure $photos is an array reference
    $photos = [ $photos ] unless ref $photos eq 'ARRAY';
    # Add photos to the collection
    push @matching_photos, @$photos;

    # Exit loop if fewer photos than per_page limit (end of results)
    last if scalar(@$photos) < $search_params{per_page};
    $page++;  # Increment page for next iteration
}

# ------------------------------
# Initialize LWP user agent for GeoNames API requests
my $ua = LWP::UserAgent->new(timeout => 10);  # Set 10-second timeout for HTTP requests

# ------------------------------
# Process each photo
foreach my $photo (@matching_photos) {
    # Skip photos without ID or owner
    next unless $photo->{id} && $photo->{owner};

    # Get latitude and longitude
    my $lat = $photo->{latitude};
    my $lon = $photo->{longitude};
    # Skip if geolocation data is missing
    next unless defined $lat && defined $lon;

    # ------------------------------
    # Extract and parse date photo was taken
    my $datetaken_str = $photo->{datetaken} // '';
    my $ts;  # Epoch timestamp
    if ($datetaken_str =~ /^(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2})$/) {
        my ($y, $m, $d, $H, $M, $S) = ($1, $2, $3, $4, $5, $6);
        # Convert to epoch time (UTC)
        $ts = timegm($S, $M, $H, $d, $m-1, $y);
    } else {
        # Fallback to current time if date is invalid
        $ts = time;
    }

    # ------------------------------
    # Query GeoNames for timezone at photo's timestamp
    # Format timestamp for GeoNames API (ISO 8601: yyyy-MM-ddtHH:mm:ss.000Z)
    my $iso_time = strftime("%Y-%m-%dt%H:%M:%S.000Z", gmtime($ts));
    # Construct GeoNames API URL with provided username
    my $geo_url = "http://api.geonames.org/timezoneJSON?lat=$lat&lng=$lon&username=$geonames_user&date=$iso_time";
    # Send HTTP GET request
    my $geo_res = $ua->get($geo_url);

    # Initialize variables for timezone and offset
    my ($tz_name, $diff_hours) = ('unknown', 'unknown');
    if ($geo_res->is_success) {
        # Parse JSON response from GeoNames
        my $data = decode_json($geo_res->decoded_content);

        # Get timezone ID
        $tz_name = $data->{timezoneId} // 'unknown';

        # Initialize offset with gmtOffset as a fallback
        my $photo_offset = $data->{gmtOffset};

        # Check the 'dates' array for a historical, DST-aware offset
        # The GeoNames API 'timezoneJSON' endpoint, when provided with a 'date' parameter,
        # includes a 'dates' array that accounts for historical timezone rules, including
        # Daylight Saving Time (DST) changes for the specified timestamp. The 'gmtOffset'
        # field, in contrast, provides the current standard offset without considering
        # historical DST rules at the photo's timestamp. To accurately determine the
        # timezone offset at the time the photo was taken, we prioritize 'offsetToGmt'
        # from the 'dates' array, which reflects the precise offset (including DST if
        # applicable) for the given date and location.
        if ($data->{dates} && ref $data->{dates} eq 'ARRAY') {
            for my $entry (@{ $data->{dates} }) {
                if (exists $entry->{offsetToGmt}) {
                    $photo_offset = $entry->{offsetToGmt} + 0;  # Ensure numeric value
                    last;  # Use the first valid offset found
                }
            }
        }
        print "Offset at $tz_name: $photo_offset";

        # Calculate Lisbon offset for comparison
        if (defined $photo_offset) {
            # Create DateTime object for Lisbon at the same timestamp
            my $dt = DateTime->from_epoch(epoch => $ts, time_zone => 'Europe/Lisbon');
            my $lisbon_offset = $dt->offset / 3600;  # Convert seconds to hours
            print "Offset at Lisbon: $lisbon_offset";

            # Calculate time difference
            $diff_hours = $photo_offset - $lisbon_offset;
        }
    }

    # ------------------------------
    # Construct photo URL
    my $url = "https://www.flickr.com/photos/$photo->{owner}/$photo->{id}/";
    # Get photo title, default to '(untitled)'
    my $title = $photo->{title} // '(untitled)';

    # ------------------------------
    # Output photo information
    print "Photo: '$title' (ID: $photo->{id}) - $url";
    print "   Lat: $lat, Lon: $lon";
    print "   Taken at: $datetaken_str UTC";
    print "   Timezone: $tz_name (Diff vs Lisbon: ${diff_hours}h)";
}