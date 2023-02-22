#!/usr/bin/perl

use strict;
use warnings;
use Data::Dumper;
use JSON;

$\ ="\n";

sub usage {
    print "Usage: $0 <file1.json> <file2.json> <key> [<type>]";
    print "Filters out elements missing values in <file1.json> and/or <file2.json>";
    print "and prints the remaining elements in JSON format.";
    print "Arguments:";
    print "  <file1.json>   The path to the first JSON file.";
    print "  <file2.json>   The path to the second JSON file.";
    print "  <key>          The key to use for comparison.";
    print "  <type>         Optional. The type of comparison to perform. Defaults to 3.";
    print "                   1 - Show missing values from <file1.json>.";
    print "                   2 - Show missing values from <file2.json>.";
    print "                   3 - Show non-common values.";
    exit;
}


my ($file1, $file2, $key, $type) = @ARGV;
usage() unless ($file1 && $file2 && $key);
$type = 3 unless defined $type;

# Create a JSON object
my $json = JSON->new->utf8;

# Read the contents of the first file into a hash
open(my $fh1, '<', $file1) or die "Could not open file '$file1': $!";
my $json1 = $json->decode(join("", <$fh1>));
my %hash1 = map { $_->{$key} => 1 } @$json1;
close($fh1);

# Filter out elements from the second file that are already in the first file
open(my $fh2, '<', $file2) or die "Could not open file '$file2': $!";
my $json2 = $json->decode(join("", <$fh2>));
my %hash2 = map { $_->{$key} => 1 } @$json2;
close($fh2);


my @filtered;
if ($type == 1) {
    # Show missing values from file 1
    @filtered = grep { !exists $hash1{$_->{$key}} } @$json2;
} elsif ($type == 2) {
    # Show missing values from file 2
    @filtered = grep { !exists $hash2{$_->{$key}} } @$json1;
} else {
    # Show non-common values
    my %union = (%hash1, %hash2);
    my %intersection = ();
    my %difference = ();
    foreach my $element (keys %union) {
        if (exists $hash1{$element} && exists $hash2{$element}) {
            $intersection{$element} = 1;
        } else {
            $difference{$element} = 1;
        }
    }
    #@filtered = grep { exists $difference{$_->{$key}} } (@$json1, @$json2);
    my %seen;
    @filtered = grep { exists $difference{$_->{$key}} && !$seen{$_->{$key}}++ } (@$json1, @$json2);
}

# Print the filtered elements in JSON format
print $json->pretty->encode(\@filtered);
