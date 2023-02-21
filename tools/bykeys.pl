#!/usr/bin/perl

use strict;
use warnings;
use JSON;
#binmode(STDOUT, ':utf8'); do not use double encondig. Use only json utf8

my $json = JSON->new->utf8;
# Check for file and key arguments
die "Usage: $0 <filename> <key1> [<key2> ...]\n" unless scalar @ARGV >= 2;
my $filename = $ARGV[0];
my @keys = @ARGV[1..$#ARGV];
my $lastkey = pop @keys;

# Open the input file
open my $fh, "<", $filename or die "Could not open $filename: $!";

# Read in the JSON data
my $json_data = $json->decode(join("", <$fh>));

# Transform the data
my $indexed_data = {};
foreach my $hash (@$json_data) {
    my $target = $indexed_data;
    foreach my $key (@keys) {
        my $value = $hash->{$key};
        $target->{$value} //= {};
        $target = $target->{$value};
    }
    my $value = $hash->{$lastkey};
    $target->{$value} //= [];
    push @{$target->{$value}}, $hash;
}

# Output the indexed data in pretty JSON format
print $json->pretty->encode($indexed_data);
