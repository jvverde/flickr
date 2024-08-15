#!/usr/bin/perl
use strict;
use warnings;
use JSON;

my $json = JSON->new->utf8;


# Read in the input JSON hash from standard input
my $json_str = join("", <>);
my $hashes = $json->decode($json_str);

# Convert the hash to an array of hashes with the desired format
my %byids;
foreach my $k (keys %$hashes) {
  my $ids = $hashes->{$k}->{ids};
  foreach my $id (@$ids){
    $byids{$id} //= [];
    push @{$byids{$id}}, $k;
  }
}

# Output the array of hashes as a JSON array to standard output
print $json->pretty->encode(\%byids);