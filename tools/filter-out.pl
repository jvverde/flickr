#!/usr/bin/perl

use strict;
use warnings;
use Getopt::Long;
use JSON;

my $json = JSON->new->utf8;

my $help;

# Parse command line options
GetOptions(
    "help|h" => \$help,
) or usage();

usage() if $help;

my ($tag_file, $json_file, $key_name) = @ARGV;
usage() unless defined $tag_file and defined $json_file and defined $key_name;

# Read in the list of tags
open my $tag_fh, '<:encoding(utf8)', $tag_file or die "Cannot open $tag_file: $!";
my %tag_hash;
while (my $tag = <$tag_fh>) {
    chomp $tag;
    $tag_hash{$tag} = 1;
}
close $tag_fh;

# Read in the JSON array of hashes
open my $json_fh, '<', $json_file or die "Cannot open $json_file: $!";
my $json_string = join '', <$json_fh>;
close $json_fh;

my $data = $json->decode($json_string);

# Filter out the hashes whose value of the given key exists on the tag list

my @filtered_data = grep { defined $_->{$key_name} && $tag_hash{$_->{$key_name}} } @$data;


# Print the filtered data as a JSON array
print $json->pretty->encode(\@filtered_data);

sub usage {
    print "Usage: $0 tag_file json_file key_name\n";
    print "Filters out hashes from a JSON array whose value of the given key exists on the tag list.\n";
    exit;
}
