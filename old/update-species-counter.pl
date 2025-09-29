#!/usr/bin/perl
use strict;
use warnings;
use Getopt::Long;
use Flickr::API;
use Data::Dumper;
use JSON;
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
Set species number for Flickr photos based on JSON input.

Usage:
  $0 --file <jsonfile> --out <updatefile>
  $0 -f <jsonfile> -o <updatefile>
  $0 --help

Options:
  -f, --file  Input JSON file containing species data (required)
  -o, --out   Output JSON file to store updated data (required)
  -h, --help  Display this help message and exit

The input JSON file should be an array of hashes, each containing a 'species' key.
The script searches Flickr for photos tagged with each species, sorts them by upload date,
and assigns sequential numbers based on the earliest photo date.
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
my ($file_name, $out);

# Parse command-line options
GetOptions(
    "f|file=s" => \$file_name,  # Input JSON file
    "o|out=s"  => \$out,        # Output JSON file
    "h|help"   => \&usage       # Show help
) or usage();

# Validate required command-line arguments
usage() unless defined $file_name && defined $out;

# Read and parse input JSON file
my $json_text = readfile($file_name);
my $data = $json->decode($json_text);

# Validate JSON structure: must be an array of hashes with 'species' key
die "Invalid JSON format: Must be an array of hashes with a 'species' key"
    unless ref $data eq 'ARRAY' && @$data && exists $data->[0]->{species};

# Array to store processed species data
my @all;
my $cnt = 0;  # Counter for processed species

# Process each species in the input JSON
foreach my $hash (@$data) {
    my $species = $hash->{species};

    # Search Flickr for photos tagged with the species
    my $response = eval {
        $flickr->execute_method('flickr.photos.search', {
            user_id  => 'me',         # Search photos from authenticated user
            tags     => $species,     # Species tag to search
            per_page => 500,          # Max photos per page
            extras   => 'date_upload',# Include upload date in results
            page     => 1             # First page of results
        })
    };
    if ($@ || !$response->{success}) {
        warn "Error retrieving photos for '$species': $@ or $response->{error_message}";
        redo;  # Retry on failure
    }

    # Extract photos from response
    my $photos = $response->as_hash()->{photos}->{photo};
    $photos = [$photos] unless ref $photos eq 'ARRAY';  # Handle single photo case

    # Skip if no photos found
    next unless @$photos && exists $photos->[0]->{id};

    # Sort photos by upload date
    my @order = sort { $a->{dateupload} <=> $b->{dateupload} } @$photos;

    # Store species data with earliest photo date and IDs
    push @all, {
        species => $species,
        date    => $order[0]->{dateupload},
        first   => $order[0]->{id},
        ids     => [map { $_->{id} } @order]
    };

    # Print progress
    print ++$cnt, "- For '$species' got", scalar @order, 'photos';
    # Optional: Uncomment to limit processing for testing
    # last if $cnt > 2;
}

# Sort all species by earliest photo date
my @order = sort { $a->{date} <=> $b->{date} } @all;

# Load existing output file if it exists
my $current = {};
if (-f $out && -s $out) {
    $current = $json->decode(readfile($out));
}

# Assign sequential numbers to species based on earliest photo date
my $number = 1;
foreach my $ele (@order) {
    my $species = $ele->{species};
    my $c = $current->{$species} // { n => 0 };  # Get existing number or default to 0
    if ($c->{n} > $number) {
        print "Previous number for '$species' was $c->{n} (higher than $number)";
        $number = $c->{n};  # Use higher existing number
    }
    $ele->{n} = $number++;  # Assign new number and increment
    $current->{$species} = $ele;  # Update current data
}

# Write updated data to output file
print "Updating JSON file at $out";
writefile($out, $json->pretty->encode($current));