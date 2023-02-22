#!/usr/bin/perl

# Import necessary libraries
use strict;
use warnings;
use JSON;

# Create a JSON object with UTF-8 encoding
my $json = JSON->new->utf8;

# Define a usage function
sub usage {
    print << "END_USAGE";
Usage: $0 <filename> <key1> [<key2> ...]

This script reads in JSON data from the specified file and creates an indexed
structure based on the specified keys. Each JSON object in the input data is
indexed by the values of the specified keys, with the last key determining the
arrays of objects associated with each index value.

For example, if the input data is a list of person records, and the keys 'city'
and 'state' are specified, the output will be a nested hash structure that can be
used to look up person records by city and state.
END_USAGE
    exit;
}

# Check if the script was called with the "-h" or "--help" option
if (scalar @ARGV == 1 && ($ARGV[0] eq "-h" || $ARGV[0] eq "--help")) {
    usage();
}

# Check if the script was called with a file name and at least one key argument
usage() unless scalar @ARGV >= 2;

# Extract the file name and key arguments from the command line arguments
my $filename = $ARGV[0];
my @keys = @ARGV[1..$#ARGV];
my $lastkey = pop @keys;

# Open the input file for reading
open my $fh, "<", $filename or die "Could not open $filename: $!";

# Read in the JSON data from the file
my $json_data = $json->decode(join("", <$fh>));

# Transform the data into an indexed structure
my $indexed_data = {};
foreach my $hash (@$json_data) {
    my $target = $indexed_data;
    foreach my $key (@keys) {
        # Extract the value for the current key from the current hash
        my $value = $hash->{$key};
        # If the value for the current key does not exist yet in the target hash, create a new hash
        $target->{$value} //= {};
        # Update the target hash to point to the hash for the current value of the current key
        $target = $target->{$value};
    }
    # Extract the value for the last key from the current hash
    my $value = $hash->{$lastkey};
    # If the value for the last key does not exist yet in the target hash, create a new array
    $target->{$value} //= [];
    # Add the current hash to the array for the current value of the last key
    push @{$target->{$value}}, $hash;
}

# Output the indexed data in pretty JSON format
print $json->pretty->encode($indexed_data);

# End of script.
