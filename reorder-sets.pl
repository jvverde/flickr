#!/usr/bin/perl

use strict;
use warnings;
use Getopt::Long;
use Flickr::API;
use Data::Dumper;

$\ = "\n";
my $help;

GetOptions(
    'h|help' => \$help,
);

if ($help) {
    print "This script lists all Flickr sets of the current user";
    print "Usage: $0 [OPTIONS]";
    print "Options:";
    print "  -h, --help    Show this help message and exit";
    print "\nNOTE: It assumes the user's tokens are initialized in the file '$ENV{HOME}/saved-flickr.st'";
    exit;
}

my $config_file = "$ENV{HOME}/saved-flickr.st";
my $per_page = 500;
my $page = 1;
my $total_pages = 1;
my $flickr = Flickr::API->import_storable_config($config_file);

# Retrieve all the sets using pagination
my $sets = [];
while ($page <= $total_pages) {
    my $response = $flickr->execute_method('flickr.photosets.getList', {
        per_page => $per_page,
        page => $page,
    });

    die "Error: $response->{error_message}" unless $response->{success};

    #print Dumper $response->as_hash->{photosets}->{photoset};
    my $s = $response->as_hash->{photosets}->{photoset};
    $s = [ $s ] unless ref $s eq 'ARRAY';
    push @$sets, @$s;
    $total_pages = $response->as_hash->{photosets}->{pages};
    $page++;
}

# Sort the sets by title
my @sorted_sets = sort { $a->{title} cmp $b->{title} } @$sets;

# Reorder the sets
my @set_ids = map { $_->{id} } @sorted_sets;
my $ordered_set_ids = join(',', @set_ids);

my $order_response = $flickr->execute_method('flickr.photosets.orderSets', {
    photoset_ids => $ordered_set_ids,
});

die "Error: $order_response->{error_message}" unless $order_response->{success};

print "Sets reordered successfully!";
