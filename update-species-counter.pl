#!/usr/bin/perl
use strict;
use warnings;
use Getopt::Long;
use Flickr::API;
use JSON;
use POSIX qw(strftime);
use Time::Local 'timegm';
binmode(STDOUT, ':utf8');

# Set output record and field separators
$\ = "\n";  # Output record separator (newline)
$, = " ";   # Output field separator (space)

# Initialize JSON parser with UTF-8 encoding
my $json = JSON->new->utf8;

# Load Flickr API configuration from storable config file
my $config_file = "$ENV{HOME}/saved-flickr.st";
my $flickr = Flickr::API->import_storable_config($config_file);

# Enhanced usage subroutine to display detailed help message
sub usage {
    print <<'END_USAGE';
Set sequence numbers for Flickr photo groups based on machine tags.

Usage:
  $0 --tag <tag> [--out <updatefile>] [--max-date <date>]
  $0 -t <tag> [-o <updatefile>] [-m <date>]
  $0 --help

Options:
  -t, --tag      The base tag to search for (e.g., IOC151) (required)
  -o, --out      Output JSON file to store updated data (optional; if not provided, output to stdout)
  -m, --max-date Maximum upload date in YYYY-MM-DD format to include photos uploaded before or on this date (optional)
  -h, --help     Display this help message and exit

The script searches for photos tagged with the provided tag (e.g., IOC151),
groups them by machine tags like IOC151:seq=NUMBER (case-insensitive),
extracts binomial names from machine tags like IOC151:binomial=NAME (case-insensitive),
initializes groups from the output file if it exists and --out is provided,
updates with new photos or new sequence numbers found,
and saves the updated data to the output JSON file only if changes are detected (or outputs to stdout if --out not provided).
The data is a hash indexed by seq number,
with values being hashes of photo_id => {date_upload, date_uploaded, photo_title, photo_page_url, binomial}.
END_USAGE
    exit;
}

# Read content from a file
sub readfile {
    my ($filename) = @_;
    open(my $fh, "<", $filename) or die("Cannot open $filename: $!");
    local $/;  # Enable slurp mode to read entire file
    my $content = <$fh>;
    close $fh;
    return $content;
}

# Write content to a file
sub writefile {
    my ($filename, $content) = @_;
    open(my $fh, ">", $filename) or die("Cannot open $filename for writing: $!");
    print $fh $content;
    close $fh;
}

# Declare variables for command-line options
my ($tag, $out, $max_date);

# Parse command-line options
GetOptions(
    "t|tag=s"      => \$tag,       # Base tag
    "o|out=s"      => \$out,       # Output JSON file
    "m|max-date=s" => \$max_date,  # Max upload date
    "h|help"       => \&usage      # Show help
) or usage();

# Validate required command-line arguments
usage() unless defined $tag;

# Validate and convert max_date if provided
if (defined $max_date) {
    unless ($max_date =~ m/^(\d{4})-(\d{2})-(\d{2})$/) {
        die "Invalid date format for --max-date. Must be YYYY-MM-DD.";
    }
    my ($y, $m, $d) = ($1, $2, $3);
    # Convert to Unix timestamp at end of the day (23:59:59 UTC)
    eval {
        $max_date = timegm(59, 59, 23, $d, $m - 1, $y);
    };
    if ($@) {
        die "Invalid date values for --max-date: $@";
    }
}

# Load existing groups from file if --out is provided and file exists
my %groups;
if (defined $out && -f $out && -s $out) {
    my $loaded = $json->decode(readfile($out));
    %groups = %$loaded if ref $loaded eq 'HASH';
}

# Search for all photos with the given tag, handling multiple pages
my $page = 1;
my @all_photos;
my $pages = 1;  # Initialize to enter loop
do {
    my $search_args = {
        user_id  => 'me',               # Search photos from authenticated user
        tags     => $tag,               # Base tag to search
        per_page => 500,                # Max photos per page
        extras   => 'date_upload,owner,title,machine_tags',  # Include necessary extras
        page     => $page               # Current page
    };
    $search_args->{max_upload_date} = $max_date if defined $max_date;

    my $response = eval {
        $flickr->execute_method('flickr.photos.search', $search_args)
    };
    if ($@ || !$response->{success}) {
        warn "Error retrieving photos for page $page: $@ or $response->{error_message}";
        sleep 1;
        redo;  # Retry the current page on failure
    }

    my $hash = $response->as_hash();
    my $photos = $hash->{photos}->{photo} || [];
    $photos = [$photos] unless ref $photos eq 'ARRAY';
    push @all_photos, @$photos;

    $pages = $hash->{photos}->{pages} || 1;
    print "Got $page of $pages page(s)";
    $page++;
} while ($page <= $pages);

# Skip if no photos found
if (!@all_photos) {
    print "No photos found for tag '$tag'";
    exit;
}

# Flags for changes
my $new_photos = 0;
my $new_seqs = 0;

# Update groups with photos from machine tags
foreach my $photo (@all_photos) {
    my $id = $photo->{id};
    my $page_url = "https://www.flickr.com/photos/$photo->{owner}/$id/";
    my $date_upload = $photo->{dateupload};

    my $machine_tags = $photo->{machine_tags} // '';
    my @mtags = split ' ', $machine_tags;
    my $number;
    my $binomial;
    foreach my $mt (@mtags) {
        if ($mt =~ /^\Q$tag\E:seq=(\d+)$/i) {
            $number = $1;
        } elsif ($mt =~ /^\Q$tag\E:binomial=(.+)$/i) {
            $binomial = $1;
        }
        last if defined $number && defined $binomial;  # Exit loop if both are found
    }
    warn "No seq found for photo $page_url" and next unless defined $number;

    if (!exists $groups{$number}) {
        $groups{$number} = {};
        $new_seqs++;
        print "New sequence number found: $number";
    }

    next if exists $groups{$number}{$id} and $groups{$number}{$id}{date_upload} == $date_upload;

    my $date_uploaded = strftime("%Y-%m-%d %H:%M:%S", localtime($date_upload));
    my $photo_title = $photo->{title} // '';

    if (!exists $groups{$number}{$id}) {
        print "New photo found for seq $number: $photo_title";
    } else {
        print "Date updated for photo $photo_title in seq $number: old=$groups{$number}{$id}{date_upload}, new=$date_upload";
    }
    $groups{$number}{$id} = {
        date_upload    => $date_upload,
        date_uploaded  => $date_uploaded,
        photo_title    => $photo_title,
        photo_page_url => $page_url,
        binomial       => $binomial // ''  # Store binomial if found, else empty string
    };
    $new_photos++;
}

# # Print progress
# my $cnt = 0;
# foreach my $num (sort { $a <=> $b } keys %groups) {
#     my $photo_count = scalar keys %{$groups{$num}};
#     print ++$cnt, "- For seq $num got $photo_count photos";
# }

# Prepare JSON output
my $json_output = $json->pretty->encode(\%groups);

# Write updated data to output file if --out provided and changes detected, or output to stdout if --out not provided
if (defined $out) {
    if ($new_photos || $new_seqs) {
        print "Changes detected. Updating JSON file at $out";
        writefile($out, $json_output);
    } else {
        print "No new photos or sequence numbers found. No update needed.";
    }
} else {
    print $json_output;
}