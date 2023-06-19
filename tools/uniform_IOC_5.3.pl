#!/usr/bin/perl
use strict;
use warnings;
use JSON;

my $json = JSON->new->utf8;


# Read in the input JSON hash from standard input
my $json_str = join("", <>);
my $input = $json->decode($json_str);

# Convert the hash to an array of hashes with the desired format
my @output;
foreach my $key (keys %{$input}) {
    my $hash = $input->{$key};
    my $vernacularNames = $hash->{vernacularNames};
    push @output, {
        "IOC_5.3" => $key,
        species => $key,
        Order => $hash->{ordo},
        Family => $hash->{familia},
        'Seq.' => $hash->{position},
        map { $_ => $vernacularNames->{$_} } keys %{$vernacularNames}
    };
}

# Output the array of hashes as a JSON array to standard output
print $json->pretty->encode(\@output);
