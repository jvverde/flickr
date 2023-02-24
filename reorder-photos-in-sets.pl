#!/usr/bin/perl

use strict;
use warnings;
use Getopt::Long;
use Data::Dumper;
use Flickr::API;

($\, $,) = ("\n", "\n");
my $help;
my $filter_pattern = '.*';
my $dry_run;

GetOptions(
    'h|help' => \$help,
    'f|filter=s' => \$filter_pattern,
    'n|dry-run' => \$dry_run,
);

if ($help) {
    print "This script reorder photos on all set of a user";
    print "Usage: $0 [OPTIONS]";
    print "Options:";
    print "  -h, --help      Show this help message and exit";
    print "  -f, --filter    Filter photosets by a regular expression pattern";
    print "\nNOTE: It assumes the user's tokens are initialized in the file '$ENV{HOME}/saved-flickr.st'";
    exit;
}

my $config_file = "$ENV{HOME}/saved-flickr.st";
my $flickr = Flickr::API->import_storable_config($config_file);

my $re = qr/$filter_pattern/i;

# Retrieve all the photosets
my $photosets = [];
my $page = 1;
my $pages = 1;
while ($page <= $pages) {
    my $response = $flickr->execute_method('flickr.photosets.getList', {
        per_page => 500,
        page => $page,
    });

    die "Error: $response->{error_message}" unless $response->{success};

    push @$photosets, grep { $_->{title} =~ $re } @{$response->as_hash->{photosets}->{photoset}};
    $pages = $response->as_hash->{photosets}->{pages};
    $page = $response->as_hash->{photosets}->{page} + 1;
}

print map { "Photoset $_->{title} will be sorted by number of views." } @$photosets and exit if $dry_run;
# Sort photos inside each photoset by number of views
my $count = 0;
foreach my $photoset (@$photosets) {
    # print Dumper $photoset;
    my $photos = [];
    my $page = 1;
    my $pages = 1;
    while ($page <= $pages) {
        my $response = $flickr->execute_method('flickr.photosets.getPhotos', {
            photoset_id => $photoset->{id},
            per_page => 500,
            page => $page,
            extras => 'views',
        });

        last "Error at get photos from $photoset->{title}: $response->{error_message}" unless $response->{success};
        my $bunch = $response->as_hash->{photoset}->{photo};
        $bunch = [ $bunch ] unless 'ARRAY' eq ref $bunch;
        #print Dumper $bunch;
        push @$photos, @$bunch;
        $pages = $response->as_hash->{photoset}->{pages};
        $page = $response->as_hash->{photoset}->{page} + 1;
    }

    my @sorted_photos = sort { $b->{views} <=> $a->{views} } @$photos;
    #print Dumper \@sorted_photos;
    my $sorted_ids = join(',', map { $_->{id} } @sorted_photos);

    # Reorder photoset using sorted photo IDs
    #print $sorted_ids;
    my $response = $flickr->execute_method('flickr.photosets.reorderPhotos', {
        photoset_id => $photoset->{id},
        photo_ids => $sorted_ids,
    });
    warn "Error at sort photos in $photoset->{title} ($photoset->{id}): $response->{error_message}" and next unless $response->{success};
    print "Photoset $photoset->{title} sorted by number of views.";
}
