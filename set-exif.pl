#!/usr/bin/perl
use strict;
use warnings;
use Getopt::Long;
use Flickr::API;
use JSON;
use Time::Local;
use URI::Escape;

binmode(STDOUT, ':utf8');
$\ = "\n";
$, = ", ";

my $json = JSON->new->utf8;

my $distance_labels = ["0-10", "10-20", "20-30", "30-40", "40-50", "50-60", "60-70", "70-80", "80-90", "90-100", "faraway"];

# Consolidated EXIF field definitions with direct mapping to subroutines
my %handlers = (
    Model             => { tags => ['Model'], handler => \&add_camera_model_tag },
    SubjectDistance   => { tags => ['SubjectDistance'], handler => \&add_subject_distance_tags },
    LensModel         => { tags => ['Lens'], handler => \&add_lens_model_tag },
    FocalLength       => { tags => ['FocalLength'], handler => \&add_focal_length_tag },
    FNumber           => { tags => ['FNumber'], handler => \&add_aperture_tag },
    ExposureTime      => { tags => ['ExposureTime'], handler => \&add_shutter_speed_tag },
    ISOSpeedRatings   => { tags => ['ISO'], handler => \&add_iso_tag },
    ExposureBiasValue => { tags => ['ExposureCompensation'], handler => \&add_exposure_comp_tag },
    DateTimeOriginal  => { tags => ['DateTimeOriginal'], handler => \&add_date_taken_tag },
    WhiteBalance      => { tags => ['WhiteBalance'], handler => \&add_white_balance_tag },
    MeteringMode      => { tags => ['MeteringMode'], handler => \&add_metering_mode_tag },
    Flash             => { tags => ['Flash'], handler => \&add_flash_tag },
);

sub valid_fields {
    print "Valid EXIF fields for --exif option:";
    print "  $_: " . join(', ', @{$handlers{$_}{tags}}) for sort keys %handlers;
    exit;
}

sub usage {
    print <<'END_USAGE';
Usage: perl flickr_photo_tagger.pl [options]
Options:
  -d, --days <number>    Number of days to look back for photos (required)
  -e, --exif <field>     EXIF fields to tag (multiple allowed, required)
  -n, --dry-run          Simulate tagging without API calls
  -l, --list             List valid EXIF fields and exit
  -h, --help             Display help message
  --debug                Print debug messages
END_USAGE
    exit;
}

# Command line parsing
my ($days, $dry_run, $debug);
my @fields;
GetOptions(
    "d|days=i"   => \$days,
    "e|exif=s@"  => \@fields,
    "n|dry-run"  => \$dry_run,
    "l|list"     => \&valid_fields,
    "h|help"     => \&usage,
    "debug"      => \$debug
);

usage() unless defined $days && @fields;

# Validate EXIF fields
my @invalid = grep { !exists $handlers{$_} } @fields;
if (@invalid) {
    warn "Invalid EXIF fields: @invalid\n";
    usage();
}

# Main execution
my $flickr = Flickr::API->import_storable_config("$ENV{HOME}/saved-flickr.st");
my $min_upload_date = time - ($days * 86400); # 24*60*60

my $page = 0;
my $pages = 1;

while (++$page <= $pages) {
    my $response = $flickr->execute_method('flickr.photos.search', {
        user_id         => 'me',
        min_upload_date => $min_upload_date,
        per_page        => 500,
        page            => $page,
    });

    unless ($response->{success}) {
        warn "Error retrieving photos: $response->{error_message}\n";
        last;
    }

    my $photos = $response->as_hash()->{photos}->{photo} or next;
    $photos = [ $photos ] unless ref $photos eq 'ARRAY';

    foreach my $photo (@$photos) {
        my $photo_id = $photo->{id} or next;

        my $response = $flickr->execute_method('flickr.photos.getExif', { photo_id => $photo_id });
        unless ($response->{success}) {
            warn "Error retrieving EXIF for photo $photo_id: $response->{error_message}\n";
            next;
        }

        my $exif = $response->as_hash()->{photo}->{exif} or next;
        
        # Build EXIF lookup hash
        my %tags;
        $tags{$_->{tag} || $_->{label}} = $_->{raw} for @$exif;

        # Process requested fields
        foreach my $field (@fields) {
            my $handler_info = $handlers{$field};
            my $tag_value;
            
            # Find first available tag value
            for my $tag_name (@{$handler_info->{tags}}) {
                if (exists $tags{$tag_name}) {
                    $tag_value = $tags{$tag_name};
                    last;
                }
            }
            
            if (defined $tag_value) {
                $handler_info->{handler}->($photo_id, $tag_value);
            } elsif ($debug) {
                print "Debug: No value found for $field in photo $photo_id";
            }
        }
    }

    $pages = $response->as_hash()->{photos}->{pages};
}

# Tagging subroutines - consolidated parameter checks and debug logging
sub add_tags {
    my ($photo_id, $tags) = @_;
    return unless defined $photo_id && defined $tags;
    
    print "Debug: add_tags for photo $photo_id: $tags" if $debug;
    
    if ($dry_run) {
        print "Dry-run: Would add tags to photo $photo_id: $tags";
        return 1;
    }
    
    my $tag_response = $flickr->execute_method('flickr.photos.addTags', {
        photo_id => $photo_id,
        tags     => $tags,
    });
    
    if ($tag_response->{success}) {
        print "Added tags to photo $photo_id: $tags";
        return 1;
    }
    
    warn "Error adding tags to photo $photo_id: $tag_response->{error_message}\n";
    return 0;
}

sub add_camera_model_tag {
    my ($photo_id, $model) = @_;
    return unless defined $model;
    $model =~ s/[^a-z0-9]+//ig;
    add_tags($photo_id, qq|camera:model="$model"|);
}

sub add_subject_distance_tags {
    my ($photo_id, $subject_distance) = @_;
    return unless defined $subject_distance;
    
    if ($subject_distance =~ /^((?!0[^\d.]*$)[\d.]+)\s*(\w*)/) {
        my ($distance, $unit) = ($1, $2 // '');
        my $index = int($distance / 10);
        $index = $#$distance_labels if $index > $#$distance_labels;

        my $distance_range = $distance_labels->[$index];
        
        my $tags = join ' ', (
            qq|distance:subject=$distance$unit|,
            qq|distance:range="$distance_range"|
        );
        add_tags($photo_id, $tags);
    } else {
        warn "Could not parse Subject Distance for photo $photo_id: $subject_distance";
    }
}

sub add_lens_model_tag {
    my ($photo_id, $lens_model) = @_;
    return unless defined $lens_model;
    $lens_model =~ s/[^a-z0-9\s-]+//ig;
    add_tags($photo_id, qq|lens:model="$lens_model"|);
}

sub add_focal_length_tag {
    my ($photo_id, $focal_length) = @_;
    return unless defined $focal_length;
    
    if ($focal_length =~ /^([\d.]+)\s*(\w*)/) {
        my ($value, $unit) = ($1, $2 // 'mm');
        add_tags($photo_id, qq|lens:focallength="$value$unit"|);
    } else {
        warn "Could not parse Focal Length for photo $photo_id: $focal_length";
    }
}

sub add_aperture_tag {
    my ($photo_id, $aperture) = @_;
    return unless defined $aperture;
    $aperture =~ s/[^0-9.]+//g;
    add_tags($photo_id, qq|camera:aperture="f$aperture"|);
}

sub add_shutter_speed_tag {
    my ($photo_id, $shutter_speed) = @_;
    return unless defined $shutter_speed;
    $shutter_speed =~ s/\//_/;
    $shutter_speed =~ s/\s*s$//;
    add_tags($photo_id, qq|camera:shutterspeed="$shutter_speed"|);
}

sub add_iso_tag {
    my ($photo_id, $iso) = @_;
    return unless defined $iso;
    $iso =~ s/[^0-9]//g;
    add_tags($photo_id, qq|camera:iso="$iso"|) if $iso =~ /^\d+$/;
}

sub add_exposure_comp_tag {
    my ($photo_id, $exposure_comp) = @_;
    return unless defined $exposure_comp;
    
    if ($exposure_comp =~ /^([+-]?\d+\/\d+)$/) {
        my ($num, $den) = split('/', $1);
        $exposure_comp = sprintf("%.2f", $num / $den) if $den != 0;
    }
    $exposure_comp =~ s/[^-+0-9.]//g;
    add_tags($photo_id, qq|camera:exposurecomp="$exposure_comp"|);
}

sub add_date_taken_tag {
    my ($photo_id, $date_taken) = @_;
    return unless defined $date_taken;
    
    if ($date_taken =~ /^(\d{4}):(\d{2}):(\d{2})/) {
        add_tags($photo_id, qq|photo:datetaken="$1/$2/$3"|);
    } else {
        warn "Could not parse Date Taken for photo $photo_id: $date_taken";
    }
}

sub add_white_balance_tag {
    my ($photo_id, $white_balance) = @_;
    return unless defined $white_balance;
    $white_balance =~ s/[^a-z0-9]+//ig;
    add_tags($photo_id, qq|camera:whitebalance="$white_balance"|);
}

sub add_metering_mode_tag {
    my ($photo_id, $metering_mode) = @_;
    return unless defined $metering_mode;
    $metering_mode =~ s/[^a-z0-9\s-]+//ig;
    add_tags($photo_id, qq|camera:metering="$metering_mode"|);
}

sub add_flash_tag {
    my ($photo_id, $flash) = @_;
    return unless defined $flash;
    $flash = $flash =~ /fired/i ? "Fired" : "Off";
    add_tags($photo_id, qq|camera:flash="$flash"|);
}

1;