#!/usr/bin/perl

# This script retrieves photos from Flickr with geolocation data, queries the GeoNames API to determine
# the timezone of each photo's location at the time it was taken, and calculates the time difference
# relative to Lisbon, Portugal. If the timezone offset differs from Lisbon's, it updates the photo's
# 'date_taken' field using the Flickr API to adjust from Lisbon time to the local time at the photo's
# location. It adds a 'datetakenchanged' tag (normalized by Flickr from date_taken_changed) and a machine
# tag 'date:taken=original_date_taken' (in double quotes using qq||) before updating the date, removing
# the tags if the update fails using a function that matches tags by regex. It excludes photos with the
# 'datetakenchanged' tag from searches to avoid reprocessing. A --dry-run option allows previewing changes
# without updating. It supports command-line arguments for specifying the GeoNames username, filtering
# photos by multiple tags (AND logic with tag_mode=all, handling spaces), text in title/description, date
# taken range (after and/or before), upload date, limiting the number of photos processed, enabling debug
# output, or enabling dry-run mode, and outputs update-related messages including photo title, URL,
# timezone, and time changes. The script uses strict and warnings for robust error handling, and relies on
# external APIs (Flickr and GeoNames) for data retrieval.

use strict;                      # Enforce strict variable declaration and scoping
use warnings;                    # Enable warning messages for potential issues
use Getopt::Long;                # For parsing command-line options
use Flickr::API;                 # Flickr API interface for retrieving and updating photo data
use LWP::UserAgent;              # HTTP client for making requests to GeoNames API
use JSON;                        # For parsing JSON responses from GeoNames
use POSIX qw(strftime);          # For formatting timestamps
use Time::Local;                 # For converting dates to epoch timestamps
use DateTime;                    # For handling timezone offsets and calculations
use Data::Dumper;                # For debug output of API responses

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
# Subroutine to validate date format (YYYY-MM-DD)
sub validate_date {
    my ($date, $option) = @_;
    if ($date && $date !~ /^\d{4}-\d{2}-\d{2}$/) {
        die "Invalid date format for $option: '$date'. Expected YYYY-MM-DD (e.g., 2023-01-01).";
    }
    return 1;
}

# ------------------------------
# Subroutine to convert YYYY-MM-DD to epoch timestamp
sub date_to_epoch {
    my ($date) = @_;
    if ($date =~ /^(\d{4})-(\d{2})-(\d{2})$/) {
        my ($y, $m, $d) = ($1, $2, $3);
        return timegm(0, 0, 0, $d, $m-1, $y);  # Start of day in UTC
    }
    return undef;  # Should not reach here due to prior validation
}

# ------------------------------
# Subroutine to add tags to a photo
sub add_tags {
    my ($photo_id, $tags, $flickr, $debug) = @_;
    my %tag_params = (
        photo_id => $photo_id,
        tags     => $tags,
    );
    my $response = $flickr->execute_method('flickr.photos.addTags', \%tag_params);
    print "DEBUG: flickr.photos.addTags response:\n", Dumper($response) if $debug;
    return $response;
}

# ------------------------------
# Subroutine to set the date_taken for a photo
sub set_photo_date {
    my ($photo_id, $date_taken, $flickr, $debug) = @_;
    my %set_date_params = (
        photo_id   => $photo_id,
        date_taken => $date_taken,
    );
    my $response = $flickr->execute_method('flickr.photos.setDates', \%set_date_params);
    print "DEBUG: flickr.photos.setDates response:\n", Dumper($response) if $debug;
    return $response;
}

# ------------------------------
# Subroutine to remove tags matching a list of regex patterns for a given photo
sub remove_tags_by_regex {
    my ($photo_id, $regexes, $flickr, $debug) = @_;
    my @regexes = ref $regexes eq 'ARRAY' ? @$regexes : ($regexes);  # Ensure regexes is an array

    # Get all tags for this specific photo
    my $response = $flickr->execute_method('flickr.tags.getListPhoto', { photo_id => $photo_id });
    print "DEBUG: flickr.tags.getListPhoto response:\n", Dumper($response) if $debug;

    # Handle API errors for tag retrieval
    unless ($response->{success}) {
        warn "Error retrieving tags for photo $photo_id: $response->{error_message}";
        return 0;  # Indicate failure
    }

    # Convert response to hash format
    my $data = $response->as_hash();

    # Check if tags data is present
    unless (defined $data && defined $data->{photo}) {
        warn "No tags found for photo $photo_id";
        return 0;  # Indicate failure
    }

    # Extract tags array from response
    my $tags = $data->{photo}->{tags}->{tag};
    $tags = [$tags] if ref $tags ne 'ARRAY';  # Ensure tags is an array reference

    my $success = 1;  # Track overall success
    foreach my $phototag (@$tags) {
        foreach my $regex (@regexes) {
            if ($phototag->{raw} =~ /$regex/) {
                print "Removing tag '$phototag->{raw}' with id $phototag->{id} from photo $photo_id";
                my $remove_response = $flickr->execute_method('flickr.photos.removeTag', { tag_id => $phototag->{id} });
                print "DEBUG: flickr.photos.removeTag response:\n", Dumper($remove_response) if $debug;
                unless ($remove_response->{success}) {
                    warn "Error removing tag '$phototag->{raw}' from photo $photo_id: $remove_response->{error_message}";
                    $success = 0;  # Mark as failed if any tag removal fails
                }
            }
        }
    }
    return $success;
}

# ------------------------------
# Subroutine to display usage information and exit
sub usage {
    print <<'USAGE';
Usage:
  perl flickr_timezone.pl [options]

Options:
  -u, --user <username>   : GeoNames username for API access (required).
  -t, --tags <tag>        : Optional tag to search (use quotes for tags with spaces, can be used multiple times, requires all tags).
  -p, --text <text>       : Optional text to search in photo title or description.
  -a, --after <YYYY-MM-DD>: Limit to photos taken on or after this date.
  -b, --before <YYYY-MM-DD>: Limit to photos taken on or before this date.
  -d, --days <num>        : Limit to photos uploaded in last <num> days.
  -c, --count <num>       : Limit the number of photos to process.
  -n, --dry-run           : Preview changes without updating photo dates.
      --debug             : Print debug output for API responses.
  -h, --help              : Show this help.

Note: --after and --before can be used independently or together, in YYYY-MM-DD format.
      Multiple --tags options require all tags to be present (AND logic).
USAGE
    exit;
}

# ------------------------------
# Parse command-line arguments
my ($geonames_user, @tags, $text, $after_date, $before_date, $days, $count, $dry_run, $debug);
GetOptions(
    "u|user=s" => \$geonames_user,     # Required GeoNames username
    "t|tags=s" => \@tags,              # Optional tags to filter photos (multiple allowed)
    "p|text=s" => \$text,              # Optional text to search in title/description
    "a|after=s" => \$after_date,       # Optional start date for photos taken
    "b|before=s" => \$before_date,     # Optional end date for photos taken
    "d|days=i" => \$days,              # Optional number of days to filter recent uploads
    "c|count=i" => \$count,            # Optional limit on number of photos to process
    "n|dry-run" => \$dry_run,          # Enable dry-run mode to preview changes
    "debug" => \$debug,              # Enable debug output for API responses
    "h|help" => \&usage,               # Display help and exit
) or usage();  # Exit with usage if GetOptions fails

# Ensure GeoNames username is provided
unless (defined $geonames_user) {
    warn "Error: GeoNames username is required.";
    usage();
}

# Validate date formats if provided
validate_date($after_date, "--after") if defined $after_date;
validate_date($before_date, "--before") if defined $before_date;

# ------------------------------
# Set up Flickr search parameters
my %search_params = (
    user_id  => 'me',            # Search for photos from authenticated user
    per_page => 500,             # Maximum photos per page (Flickr API limit)
    page     => 1,               # Start with first page
    has_geo  => 1,               # Require photos to have geolocation data
    extras   => 'geo,date_taken,tags', # Include latitude, longitude, date taken, and tags
);

# Add tag filter if provided, excluding photos with datetakenchanged
if (@tags) {
    # Enclose each tag in quotes if it contains spaces, then join with commas
    my @formatted_tags = map { $_ =~ /\s/ ? qq|"$_"| : $_ } @tags;
    $search_params{tags} = join(',', @formatted_tags, '-datetakenchanged');
    $search_params{tag_mode} = 'all';  # Require all tags (AND logic)
} else {
    $search_params{tags} = '-datetakenchanged';
}
# Add text search in title/description if provided
$search_params{text} = $text if defined $text;
# Add time filter for photos uploaded in the last <days> if provided
$search_params{min_upload_date} = time - ($days*24*3600) if defined $days;
# Add date taken range if provided
$search_params{min_taken_date} = $after_date if defined $after_date;
$search_params{max_taken_date} = $before_date if defined $before_date;

# ------------------------------
# Retrieve all matching photos from Flickr
my @matching_photos;  # Array to store all photos that pass filtering
my $page = 0;         # Initialize page counter (pre-incremented to start at 1)
while (1) {
    $search_params{page} = ++$page;  # Pre-increment page and set for API request
    # Execute Flickr photos.search API method
    my $response = $flickr->execute_method('flickr.photos.search', \%search_params);

    # Retry on API failure after a 1-second delay
    warn "Error retrieving photos: $response->{error_message}" and sleep 1 and redo unless $response->{success};

    # Convert response to hash format for easier access
    my $hash = $response->as_hash;

    # Extract photos from response, default to empty array if none
    my $photos = $hash->{photos}{photo} // [];

    # Extract total number of pages from response
    my $pages = $hash->{photos}{pages};

    # Validate that the returned page matches the requested page
    warn "Expected page $page is not returned from search method $hash->{photos}{page}" and last unless $page == $hash->{photos}{page};

    # Ensure photos is an array reference to prevent 'Not an ARRAY reference' errors
    $photos = [ $photos ] unless ref $photos eq 'ARRAY';

    # Calculate total number of photos in this page's response
    my $total = scalar @$photos;

    # Print debug output for the first 2 photos if --debug is enabled
    print "DEBUG: page $page of $pages, flickr.photos.search response (first 2 photos of $total):\n", Dumper([@$photos[0..1]]) if $debug;

    # Filter out photos with the datetakenchanged tag
    my @filtered_photos = grep { $_->{tags} && $_->{tags} !~ /\bdatetakenchanged\b/ } @$photos;

    # Calculate number of photos retained after filtering
    my $filtered_count = scalar @filtered_photos;

    # Print debug output for number of discarded photos if --debug is enabled
    printf "DEBUG: Discarded %d photos of %d total\n", $total - $filtered_count, $total if $debug;

    # Add filtered photos to the collection
    push @matching_photos, @filtered_photos;

    # Exit loop if all pages have been processed
    last if $page >= $pages;
}

# Trim matching photos to the first $count if specified
@matching_photos = @matching_photos[0..$count-1] if defined $count && @matching_photos > $count;

# ------------------------------
# Initialize LWP user agent for GeoNames API requests
my $ua = LWP::UserAgent->new(timeout => 10);  # Set 10-second timeout for HTTP requests

# ------------------------------
# Process each photo
foreach my $photo (@matching_photos) {
    # Skip photos without ID or owner
    next unless $photo->{id} && $photo->{owner};

    # Get photo title, default to '(untitled)'
    my $title = $photo->{title} // '(untitled)';

    # Get latitude and longitude
    my $lat = $photo->{latitude};
    my $lon = $photo->{longitude};
    # Skip if geolocation data is missing
    warn "No latitude or longitude for photo '$title'" and next unless defined $lat && defined $lon;

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

    # Construct photo URL for output
    my $url = "https://www.flickr.com/photos/$photo->{owner}/$photo->{id}/";

    # Query GeoNames for timezone at photo's timestamp
    # Format timestamp for GeoNames API (ISO 8601: yyyy-MM-ddtHH:mm:ss.000Z)
    my $iso_time = strftime("%Y-%m-%dt%H:%M:%S.000Z", gmtime($ts));
    # Construct GeoNames API URL with provided username
    my $geo_url = "http://api.geonames.org/timezoneJSON?lat=$lat&lng=$lon&username=$geonames_user&date=$iso_time";
    # Attempt GeoNames API call with one retry after a 1-second delay
    my $geo_res = $ua->get($geo_url);
    warn "Failed to get GeoNames data for photo '$title' ($url). I'll try after 1 second" and sleep 1 and redo unless $geo_res->is_success;

    # Parse JSON response from GeoNames
    my $data = decode_json($geo_res->decoded_content);

    # Get timezone ID
    my $tz_name = $data->{timezoneId} // 'unknown';

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
    # Commented out per user request
    # print "Offset at $tz_name: $photo_offset";

    # Skip if photo_offset is undefined
    next unless defined $photo_offset;

    # Calculate Lisbon offset for comparison
    my $dt = DateTime->from_epoch(epoch => $ts, time_zone => 'Europe/Lisbon');
    my $lisbon_offset = $dt->offset / 3600;  # Convert seconds to hours
    # Commented out per user request
    # print "Offset at Lisbon: $lisbon_offset";

    # Calculate time difference (local offset - Lisbon offset)
    my $diff_hours = $photo_offset - $lisbon_offset;

    # Skip if no date adjustment is needed
    print "No date update needed for photo '$title' ($url) in timezone '$tz_name' (offset difference is zero)" and next if $diff_hours == 0;

    # Adjust timestamp from Lisbon time to local time
    # Since the photo's date_taken is in Lisbon time, we add the offset
    # difference (local offset - Lisbon offset) to shift the time to the
    # local timezone at the photo's location. For example, if the local offset
    # is +3 and Lisbon's is +1, the difference is +2 hours, so we add 2 hours
    # to the timestamp to get the local time.
    my $adjusted_ts = $ts + ($diff_hours * 3600);  # Add hours difference in seconds

    # Format the adjusted timestamp for Flickr API (yyyy-mm-dd HH:mm:ss)
    my $adjusted_date = strftime("%Y-%m-%d %H:%M:%S", gmtime($adjusted_ts));

    # In dry-run mode, show the current and proposed date changes with URL and timezone
    print "Dry-run: Would update date_taken for photo '$title' ($url) in timezone '$tz_name'\n\tfrom $datetaken_str to $adjusted_date" and next if $dry_run;

    # Add tags: 'datetakenchanged' and machine tag 'date:taken="$datetaken_str"' (quoted)
    my $tags_to_add = qq|datetakenchanged,date:taken="$datetaken_str"|;
    my $tag_response = add_tags($photo->{id}, $tags_to_add, $flickr, $debug);

    # Skip if tag addition fails
    warn "Failed to add tags to photo '$title' ($url): $tag_response->{error_message}" and next unless $tag_response->{success};

    # Update date_taken
    my $set_date_response = set_photo_date($photo->{id}, $adjusted_date, $flickr, $debug);

    # Check if the date update was successful
    if ($set_date_response->{success}) {
        print "Updated date_taken for photo '$title' ($url) in timezone '$tz_name'\n\tfrom $datetaken_str to $adjusted_date";
        print qq|Added tags 'datetakenchanged' and 'date:taken="$datetaken_str"' to photo '$title' ($url)|;
    } else {
        # Remove tags if date update fails
        my $remove_success = remove_tags_by_regex($photo->{id}, [qw(^datetakenchanged$ ^date:taken=.*$)], $flickr, $debug);
        warn "Failed to update date_taken for photo '$title' ($url) in timezone '$tz_name': $set_date_response->{error_message}" .
             ($remove_success ? ". Tags removed." : ". Also failed to remove tags.");
    }
}