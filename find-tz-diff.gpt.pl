#!/usr/bin/perl

use strict;
use warnings;
use Getopt::Long;
use Flickr::API;
use LWP::UserAgent;
use JSON;
use POSIX qw(strftime);
use Time::Local;
use DateTime;

binmode(STDOUT, ':utf8');
$\ = "\n";

# GeoNames username
my $geonames_user = 'jvverde';

# Flickr API config
my $config_file = "$ENV{HOME}/saved-flickr.st";
my $flickr;
eval {
    $flickr = Flickr::API->import_storable_config($config_file);
};
if ($@) {
    die "Failed to load Flickr API config from $config_file: $@";
}

# ------------------------------
# Usage/help
sub usage {
    print <<'USAGE';
Usage:
  perl flickr_timezone.pl [options]

Options:
  -t, --tag <tag>       : Optional tag to search.
  -d, --days <num>      : Limit to photos uploaded in last <num> days.
  -h, --help            : Show this help.
USAGE
    exit;
}

# ------------------------------
# Parse command-line
my ($tag, $days);
GetOptions(
    "t|tag=s" => \$tag,
    "d|days=i" => \$days,
    "h|help" => \&usage,
);

# ------------------------------
# Prepare Flickr search
my %search_params = (
    user_id  => 'me',
    per_page => 500,
    page     => 1,
    extras   => 'geo,date_taken',  # get lat/lon and datetaken
);

$search_params{tags} = $tag if defined $tag;
$search_params{min_upload_date} = time - ($days*24*3600) if defined $days;

# ------------------------------
# Retrieve all matching photos
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

    last if scalar(@$photos) < $search_params{per_page};
    $page++;
}

# ------------------------------
# Prepare LWP user agent for GeoNames API
my $ua = LWP::UserAgent->new(timeout => 10);

# ------------------------------
# Process each photo
foreach my $photo (@matching_photos) {
    next unless $photo->{id} && $photo->{owner};

    my $lat = $photo->{latitude};
    my $lon = $photo->{longitude};
    next unless defined $lat && defined $lon;

    # ------------------------------
    # Date photo was taken
    my $datetaken_str = $photo->{datetaken} // '';
    my $ts;
    if ($datetaken_str =~ /^(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2})$/) {
        my ($y,$m,$d,$H,$M,$S) = ($1,$2,$3,$4,$5,$6);
        $ts = timegm($S,$M,$H,$d,$m-1,$y);  # convert to epoch
    } else {
        $ts = time;  # fallback
    }

    # ------------------------------
    # Query GeoNames for timezone at photo timestamp
    # Format: date=yyyy-MM-ddtHH:mm:ss.000Z (t lowercase)
    my $iso_time = strftime("%Y-%m-%dt%H:%M:%S.000Z", gmtime($ts));
    my $geo_url = "http://api.geonames.org/timezoneJSON?lat=$lat&lng=$lon&username=$geonames_user&date=$iso_time";
    my $geo_res = $ua->get($geo_url);

    my ($tz_name, $diff_hours) = ('unknown', 'unknown');
    if ($geo_res->is_success) {
        my $data = decode_json($geo_res->decoded_content);

        # timezoneId from root
        $tz_name = $data->{timezoneId} // 'unknown';

        # historical DST-aware offset from dates array
        my $photo_offset = $data->{gmtOffset}; #this is a fallback

        if ($data->{dates} && ref $data->{dates} eq 'ARRAY') {
            for my $entry (@{ $data->{dates} }) {
                if (exists $entry->{offsetToGmt}) {
                    $photo_offset = $entry->{offsetToGmt} + 0;
                    last;
                }
            }
        }
        print "Offset at $tz_name: $photo_offset";

        if (defined $photo_offset) {
            # Lisbon offset at same timestamp
            my $dt = DateTime->from_epoch(epoch => $ts, time_zone => 'Europe/Lisbon');
            my $lisbon_offset = $dt->offset / 3600;
            print "Offset at Lisbon: $lisbon_offset";

            $diff_hours = $photo_offset - $lisbon_offset;
        }
    }

    # ------------------------------
    # Photo URL
    my $url   = "https://www.flickr.com/photos/$photo->{owner}/$photo->{id}/";
    my $title = $photo->{title} // '(untitled)';

    # ------------------------------
    # Print info
    print "Photo: '$title' (ID: $photo->{id}) - $url";
    print "   Lat: $lat, Lon: $lon";
    print "   Taken at: $datetaken_str UTC";
    print "   Timezone: $tz_name (Diff vs Lisbon: ${diff_hours}h)";
}
