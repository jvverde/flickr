#!/usr/bin/perl
#!/usr/bin/perl

use strict;
use warnings;
use JSON;

# Create a JSON object
my $json = JSON->new->utf8;

my $key = $ARGV[0];
my $file1 = $ARGV[1];
my $file2 = $ARGV[2];

# Load the contents of the JSON files
open(my $fh1, '<', $file1) or die "Can't open file '$file1': $!";
my $json1 = $json->decode(join '', <$fh1>);
close $fh1;

open(my $fh2, '<', $file2) or die "Can't open file '$file2': $!";
my $json2 = $json->decode(join '', <$fh2>);
close $fh2;

# Create a hash to hold the merged data
my %merged;

# Merge the data from the first file
foreach my $item (@$json1) {
    my $key_value = $item->{$key};
    $merged{$key_value} = $item;
}

# Merge the data from the second file
my @result;
foreach my $item (@$json2) {
  my $key_value = $item->{$key};
  next unless exists $merged{$key_value};
  # Merge the items if they have the same key value
  foreach my $key (keys %$item) {
    $merged{$key_value}->{$key} //= $item->{$key};
  }
}

# Output the merged data
print $json->pretty->encode([values %merged]);
