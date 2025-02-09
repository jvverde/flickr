#!/usr/bin/perl
use strict;
use warnings;
use Getopt::Long;
use Flickr::API;
use Data::Dumper;
use JSON;
use Time::Local;
use URI::Escape;
binmode(STDOUT, ':utf8');

$\ = "\n";
$, = ", ";
my $json = JSON->new->utf8;

# Import Flickr API configuration
my $config_file = "$ENV{HOME}/saved-flickr.st";
my $flickr = Flickr::API->import_storable_config($config_file);

# Usage subroutine to print help message
sub usage {
    print "Usage:\n";
    print "  $0 --days n\n";
    exit;
}

# Parse command line arguments
my $days = undef;  # Option for number of days
GetOptions(
    "d|days=i" => \$days,  # Capture the days option
    "h|help"   => \&usage
);

usage() unless defined $days;

# Calculate the minimum upload date based on the number of days
my $min_upload_date = time - ($days * 24 * 60 * 60);  # Convert days to seconds

# Define distance range labels
my @distance_labels = (
    "0-10", "10-20", "20-30", "30-40", "40-50", "50-60", "60-70", "70-80", "80-90", "90-100", "faraway"
);

# Fetch all photos uploaded in the last $days
my $page = 0;
my $pages = 1;

while (++$page <= $pages) {
    my $response = $flickr->execute_method('flickr.photos.search', {
        user_id         => 'me',
        min_upload_date => $min_upload_date,
        per_page        => 500,
        page            => $page,
    });

    warn "Error retrieving photos: $response->{error_message}\n" and last unless $response->{success};

    my $photos = $response->as_hash()->{photos}->{photo} // next;
    $photos = [ $photos ] unless ref $photos eq 'ARRAY';  # Handle case with only 1 photo

    foreach my $photo (@$photos) {
        my $photo_id = $photo->{id};
        next unless $photo_id;

        # Get EXIF data for the photo
        my $exif_response = $flickr->execute_method('flickr.photos.getExif', { photo_id => $photo_id });
        warn "Error retrieving EXIF for photo $photo_id: $exif_response->{error_message}\n" and next unless $exif_response->{success};

        my $exif_data = $exif_response->as_hash()->{photo}->{exif};
        next unless $exif_data;

        #print Dumper $exif_data;
        # Extract "Subject Distance" and "Camera Model" from EXIF
        my $subject_distance;
        foreach my $tag (@$exif_data) {
            if ($tag->{label} eq "Subject Distance") {
                $subject_distance = $tag->{raw};  # Keep the scalar value (distance + unit)
                #last;
                next
            } elsif ($tag->{tag} eq 'Model') {
                my $model = $tag->{raw};
                            # Construct machine tags
                my $machine_tag = qq|camera:model=$model|;  # camera model

                my $tag_response = $flickr->execute_method('flickr.photos.addTags', {
                    photo_id => $photo_id,
                    tags     => $machine_tag,
                });
                warn "Error adding camera:model tag to photo $photo_id: $tag_response->{error_message}\n" and next unless $tag_response->{success};
                print "Added camera:model tag to photo $photo_id: $machine_tag";
            }
        }

        next unless defined $subject_distance;

        # Extract numeric value and units from subject distance
        if ($subject_distance =~ /^((?!0[^\d.]*$)[\d.]+)\s*(\w*)/) {
            my $distance = $1;       # Numeric value
            my $unit = $2 // '';     # Units (if present)
            my $index = int($distance / 10);  # Calculate index for mapping
            $index = $#distance_labels if $index > $#distance_labels;  # Clamp to last range if out of bounds
            my $distance_range = $distance_labels[$index];

            # Construct machine tags
            my @machine_tags = (
                qq|distance:subject=$distance$unit|,  # Exact distance with units
                qq|distance:range="$distance_range"|  # Range without units
            );

            # Add machine tags to the photo
            my $tags = join ' ', @machine_tags;
            my $tag_response = $flickr->execute_method('flickr.photos.addTags', {
                photo_id => $photo_id,
                tags     => $tags,
            });

            warn "Error adding tags to photo $photo_id: $tag_response->{error_message}\n" and next unless $tag_response->{success};
            print "Added machine tags to photo $photo_id: $tags";
        }
        else {
            warn "Could not parse Subject Distance for photo $photo_id: $subject_distance";
        }
    }

    $pages = $response->as_hash()->{photos}->{pages};
}
1;