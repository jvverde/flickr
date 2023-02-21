#!/usr/bin/perl

use strict;
use warnings;
use Getopt::Long;
use Flickr::API;
use Data::Dumper;
use JSON;

$\ = "\n";
my $help;

sub usage {
    print "This script list all flickr sets of current user";
    print "Usage: $0 [OPTIONS]";
    print "Options:";
    print "  -h, --help    Show this help message and exit";
    print "\nNOTE:It assumes the user's tokens are initialized on file '$ENV{HOME}/saved-flickr.st'";
    exit;
}

GetOptions(
    'h|help' => \&usage
);

exit;
my $config_file = "$ENV{HOME}/saved-flickr.st";
my $flickr = Flickr::API->import_storable_config($config_file);

my $per_page = 500;
my $page = 1;
my @sets;

while (1) {
    my $response = $flickr->execute_method('flickr.photosets.getList', {
        page => $page,
        per_page => $per_page
    });
    
    die "Error retrieving photosets: $response->{error_message}\n\n" unless $response->{success};

    my $sets_page = $response->as_hash()->{photosets}{photoset};
    push @sets, @$sets_page;

    last if scalar @$sets_page < $per_page;
    $page++;
}

print JSON->new->utf8->pretty->encode(\@sets);
