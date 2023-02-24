#!/usr/bin/perl
use strict;
use warnings;
use JSON;

my $json = JSON->new->utf8;


# Read in the input JSON hash from standard input
my ($key, $dup) = (shift, shift);
my $json_str = join("", <>);
my $file = $json->decode($json_str);

# Convert the hash to an array of hashes with the desired format
foreach my $elem (@$file) {
  $elem->{$dup} = $elem->{$key};
}

# Output the array of hashes as a JSON array to standard output
print $json->pretty->encode($file);