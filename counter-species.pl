#!/usr/bin/perl
use strict;
use warnings;
use Getopt::Long;
use JSON;
binmode(STDOUT, ':utf8');

# Set output record and field separators
$\ = "\n";  # Output record separator (newline)
$, = " ";   # Output field separator (space)

# Initialize JSON parser with UTF-8 encoding
my $json = JSON->new->utf8;

# Enhanced usage subroutine to display detailed help message
sub usage {
    print <<'END_USAGE';
Transform Flickr JSON data to include sequence counters.

Usage:
  $0 --in <inputfile> [--out <outputfile>] [--array]
  $0 -i <inputfile> [-o <outputfile>] [-a]
  $0 --help

Options:
  -i, --in    Input JSON file containing Flickr photo data (required)
  -o, --out   Output JSON file to store transformed data (optional)
  -a, --array Output an array sorted by counter (optional, default is hash)
  -h, --help  Display this help message and exit

The input JSON has sequence numbers as keys, each mapping to a hash of photo IDs
with details (date_upload, date_uploaded, photo_title, photo_page_url, binomial).
The script transforms this into a structure where each sequence number maps to
a hash with 'cnt' (a counter based on the earliest photo's date_upload) and
'photos' (the original photo hash). If --array is specified, outputs an array of
objects with 'seq', 'cnt', and 'photos', sorted by 'cnt'. The counter starts at 1
for the sequence with the oldest photo. If --out is not specified, output is sent
to STDOUT.
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
my ($in, $out, $array);

# Parse command-line options
GetOptions(
    "i|in=s"   => \$in,    # Input JSON file
    "o|out=s"  => \$out,   # Output JSON file (optional)
    "a|array"  => \$array, # Output as array (optional)
    "h|help"   => \&usage  # Show help
) or usage();

# Validate required command-line arguments
usage() unless defined $in;

# Read and parse input JSON file
my $json_text = readfile($in);
my $data = $json->decode($json_text);

# Validate JSON structure: must be a hash
die "Invalid JSON format: Must be a hash" unless ref $data eq 'HASH';

# Step 1: Find the minimum date_upload for each sequence
my %min_dates;
foreach my $seq (keys %$data) {
    my $photos = $data->{$seq};
    next unless ref $photos eq 'HASH' && %$photos;  # Skip empty sequences
    my $min_date = (sort { $a <=> $b } map { $_->{date_upload} } values %$photos)[0];
    $min_dates{$seq} = $min_date if defined $min_date;
}

# Step 2: Sort sequences by minimum date_upload and assign counters
my $counter = 1;
my %counters;
foreach my $seq (sort { $min_dates{$a} <=> $min_dates{$b} } keys %min_dates) {
    $counters{$seq} = $counter++;
}

# Step 3: Transform the data structure
my %transformed;
foreach my $seq (keys %$data) {
    $transformed{$seq} = {
        cnt    => $counters{$seq} // $counter++,  # Use existing counter or assign new
        photos => $data->{$seq}
    };
}

# Step 4: Prepare output based on array flag
my $output;
if ($array) {
    # Convert to array sorted by cnt
    my @array_output = map {
        {
            seq    => $_,
            cnt    => $transformed{$_}{cnt},
            photos => $transformed{$_}{photos}
        }
    } keys %transformed;
    @array_output = sort { $a->{cnt} <=> $b->{cnt} } @array_output;
    $output = $json->pretty->encode(\@array_output);
} else {
    # Output as hash
    $output = $json->pretty->encode(\%transformed);
}

# Step 5: Output the transformed data
if (defined $out) {
    print "Writing transformed JSON to $out";
    writefile($out, $output);
} else {
    print "Writing transformed JSON to STDOUT";
    print $output;
}