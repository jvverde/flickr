#!/usr/bin/perl

use strict;
use warnings;
use Data::Dumper;
use Text::CSV;
use JSON;
#binmode(STDOUT, ':utf8'); do no use! aboid double encondig. Use only json->utf8


$\ = "\n";

# Check for file argument
die "Usage: $0 <filename>\n" unless scalar @ARGV == 1;

# Open the input file
my $csv = Text::CSV->new({ binary => 1, auto_diag => 1, eol => $/ });
open my $fh, "<:encoding(utf8)", $ARGV[0] or die "$ARGV[0]: $!";

# Read the header line
my $header = $csv->getline($fh);
my @cols = grep {$header->[$_] ne ''} 0..@$header-1;

#print Dumper $header;
#print Dumper \@cols;
#exit;
# Read the data lines
my $data = [];
while (my $row = $csv->getline($fh)) {
    #push @$data, { map { $header->[$_] => $row->[$_] } 0..@$header-1 };
    push @$data, { map { $header->[$_] => $row->[$_] } grep { $row->[$_] ne '' } @cols };
}

# Close the input file
close $fh;

# Output the data in pretty JSON format
print JSON->new->utf8->pretty->encode($data);
