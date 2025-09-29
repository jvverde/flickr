#!/usr/bin/perl
use strict;
use warnings;
use Spreadsheet::ParseXLSX;
use JSON;
use IO::Handle;
use Data::Dumper;

$\="/n";
# Handle input and output from arguments
my $input = shift @ARGV // '-';  # Default to '-' for stdin
my $output_file = shift @ARGV;   # Optional output file

# If input is '-', read from STDIN
my $fh;
if ($input eq '-') {
    binmode STDIN;
    $fh = \*STDIN;
} else {
    open $fh, '<', $input or die "Cannot open $input: $!\n";
    binmode $fh;
}

# Initialize parser
my $parser = Spreadsheet::ParseXLSX->new;
my $workbook = $parser->parse($fh);
die "Failed to parse: $parser->error\n" unless $workbook;
close $fh if $input ne '-';

# Get the first worksheet
my $worksheet = $workbook->worksheet(0);
die "Worksheet not found\n" unless $worksheet;
# Get row range
my ($row_min, $row_max) = $worksheet->row_range();

# Headers from row 0
my @headers;
for my $col (0 .. $worksheet->col_range()->[1]) {
    print "c=$col";
    my $cell = $worksheet->get_cell(0, $col);
    push @headers, $cell ? $cell->value : '';
}

# Array for JSON data (only species)
my @json_data;

# Process rows starting from 1
for my $row (1 .. $row_max) {
    my %row_data;
    my $taxon_rank = '';

    # Collect non-empty cells
    for my $col (0 .. $#headers) {
        my $cell = $worksheet->get_cell($row, $col);
        my $value = $cell ? $cell->value : '';
        next unless $value;  # Skip empty
        $row_data{$headers[$col]} = $value;
        $taxon_rank = $value if $headers[$col] eq 'Taxon_rank';
    }

    next unless %row_data;  # Skip empty rows
    next unless $taxon_rank eq 'species';  # Only process species

    push @json_data, \%row_data;
}

# Output JSON
my $json = to_json(\@json_data, { pretty => 1 });

if ($output_file) {
    open my $out_fh, '>', $output_file or die "Cannot open $output_file: $!\n";
    print $out_fh $json;
    close $out_fh;
    print "JSON written to $output_file\n";
} else {
    print $json;
}