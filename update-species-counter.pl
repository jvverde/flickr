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
# This assumes the user has already authenticated and saved config to $HOME/saved-flickr.st
my $config_file = "$ENV{HOME}/saved-flickr.st";
my $flickr = Flickr::API->import_storable_config($config_file);

# Enhanced usage subroutine to display detailed help message
sub usage {
    print <<'END_USAGE';
Set sequence numbers for Flickr photo groups based on machine tags.

Usage:
  $0 --tag <tag> [--out <updatefile>] [--max-date <date>] [--min-date <date>] [--last-photos <count>]
  $0 -t <tag> [-o <updatefile>] [-m <date>] [-i <date>] [-l <count>]
  $0 --help

Options:
  -t, --tag      The base tag to search for (e.g., IOC151) (required)
  -o, --out      Output JSON file to store updated data (optional; if not provided, output to stdout)
  -m, --max-date Maximum upload date in YYYY-MM-DD format to include photos uploaded before or on this date (optional)
  -i, --min-date Minimum upload date in YYYY-MM-DD format to include photos uploaded on or after this date (optional)
  -l, --last-photos Number of last photos to retrieve, ordered by date uploaded (optional, acts as a countdown variable)
  -h, --help     Display this help message and exit

The script searches for photos tagged with the provided tag (e.g., IOC151),
groups them by machine tags like IOC151:seq=NUMBER (case-insensitive),
and extracts binomial names (e.g., IOC151:binomial=NAME).
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
my ($tag, $out, $max_date, $min_date, $last_photos);

# Parse command-line options
GetOptions(
    "t|tag=s"      => \$tag,       
    "o|out=s"      => \$out,       
    "m|max-date=s" => \$max_date,  
    "i|min-date=s" => \$min_date,  
    "l|last-photos=i" => \$last_photos, 
    "h|help"       => \&usage      
) or usage();

# Validate required command-line arguments
usage() unless defined $tag;

# Validate and convert max_date (YYYY-MM-DD to Unix timestamp at 23:59:59 UTC)
if (defined $max_date) {
    unless ($max_date =~ m/^(\d{4})-(\d{2})-(\d{2})$/) {
        die "Invalid date format for --max-date. Must be YYYY-MM-DD.";
    }
    my ($y, $m, $d) = ($1, $2, $3);
    eval {
        $max_date = timegm(59, 59, 23, $d, $m - 1, $y);
    };
    if ($@) {
        die "Invalid date values for --max-date: $@";
    }
}

# Validate and convert min_date (YYYY-MM-DD to Unix timestamp at 00:00:00 UTC)
if (defined $min_date) {
    unless ($min_date =~ m/^(\d{4})-(\d{2})-(\d{2})$/) {
        die "Invalid date format for --min-date. Must be YYYY-MM-DD.";
    }
    my ($y, $m, $d) = ($1, $2, $3);
    eval {
        $min_date = timegm(0, 0, 0, $d, $m - 1, $y);
    };
    if ($@) {
        die "Invalid date values for --min-date: $@";
    }
}


# Load existing groups from file if --out is provided and file exists
my %groups;
if (defined $out && -f $out && -s $out) {
    my $loaded = $json->decode(readfile($out));
    %groups = %$loaded if ref $loaded eq 'HASH';
}

# --- Optimized Photo Search Block ---
my $page = 1;
my @all_photos;
my $pages = 1;  # Initialize to enter loop
my $per_page = 500; # Max items per page for Flickr API

while ($page <= $pages) {
    # Optimization: If the remaining required photos ($last_photos) is less than the max per page (500),
    # adjust the request size to avoid needing to trim the array later.
    $per_page = $last_photos if defined $last_photos and $last_photos > 0 and $last_photos < $per_page;

    my $search_args = {
        user_id  => 'me',               # Search photos from authenticated user
        tags     => $tag,               # Base tag to search
        per_page => $per_page,          # Max photos per page (dynamically adjusted)
        extras   => 'date_upload,owner,title,machine_tags',  # Include necessary extras
        page     => $page               # Current page
    };
    $search_args->{max_upload_date} = $max_date if defined $max_date;
    $search_args->{min_upload_date} = $min_date if defined $min_date;

    my $response = eval {
        $flickr->execute_method('flickr.photos.search', $search_args)
    };
    # Retry logic on API failure
    if ($@ || !$response->{success}) {
        warn "Error retrieving photos for page $page: $@ or $response->{error_message}";
        sleep 1;
        redo;  # Retry the current page on failure
    }

    my $hash = $response->as_hash();
    my $photos = $hash->{photos}->{photo} || [];
    $photos = [$photos] unless ref $photos eq 'ARRAY';
    
    # Add photos to the final list
    push @all_photos, @$photos;

    # Update the total number of pages from the API response
    $pages = $hash->{photos}->{pages} || 1;
    
    # Progress printing and stopping condition for --last-photos
    if (defined $last_photos) {
      # This subtraction must happen after the push to track the exact quota consumption
      $last_photos -= scalar @$photos;
      print "Got " . scalar(@all_photos) . " photos" ;
      
      # Stop the loop immediately if the quota is met or exceeded ($last_photos <= 0)
      last if $last_photos <= 0;
    } else {
      # Normal pagination progress
      print "Got $page of $pages (total) page(s)" ;
    }
    $page++;
} # End of while loop
# --- End Optimized Photo Search Block ---


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

    # Skip if photo already exists with the same upload date
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