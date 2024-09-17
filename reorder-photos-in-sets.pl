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
my $sort = 'datetaken';
my $rev;

GetOptions(
    'h|help' => \$help,
    'f|filter=s' => \$filter_pattern,
    'n|dry-run' => \$dry_run,
    's|sort=s' => \$sort,
    'r|reverse' => \$rev,
);

die "Error: Sort parameter ('$sort') must be one of 'views', 'upload', 'lastupdate', '.+:seq'\n"
  unless $sort =~ /^(views|dateupload|lastupdate|datetaken|.+:seq)$/;

if ($help) {
    print "This script reorders photos in all sets of the current user";
    print "Usage: $0 [OPTIONS]";
    print "Options:";
    print "  -h, --help      Show this help message and exit";
    print "  -f, --filter    Filter photosets by a regular expression pattern";
    print "  -s, --sort      Sort by views, dateupload, lastupdate, or datetaken (the default)";
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

    warn "Error: $response->{error_message}" and redo unless $response->{success};

    push @$photosets, grep { $_->{title} =~ $re } @{$response->as_hash->{photosets}->{photoset}};
    $pages = $response->as_hash->{photosets}->{pages};
    $page = $response->as_hash->{photosets}->{page} + 1;
}

print map { "Photoset $_->{title} will be sorted by $sort" } @$photosets and exit if $dry_run;

# Sort photos inside each photoset
my $count = 0;
foreach my $photoset (@$photosets) {
    my $photos = [];
    my $page = 1;
    my $pages = 1;
    while ($page <= $pages) {
        my $response = $flickr->execute_method('flickr.photosets.getPhotos', {
            photoset_id => $photoset->{id},
            per_page => 500,
            page => $page,
            extras => 'views,date_upload,date_taken,last_update,machine_tags',
        });

        warn "Error at get photos from $photoset->{title}: $response->{error_message}" and redo unless $response->{success};
        my $bunch = $response->as_hash->{photoset}->{photo};
        $bunch = [ $bunch ] unless 'ARRAY' eq ref $bunch;
        push @$photos, @$bunch;
        $pages = $response->as_hash->{photoset}->{pages};
        $page = $response->as_hash->{photoset}->{page} + 1;
    }

    my @sorted_photos;
    if ($sort =~ /.+:seq/) {
        $sort =~ s/[^a-z0-9:]//i;  # Convert to Flickr canonical form
        foreach my $photo (@$photos) {
            my ($seq) = $photo->{machine_tags} =~ /$sort=(\d+)/i;
            $photo->{seq} = defined $seq ? $seq : 100000;  # Assign a high number if tag not found
        }
        @sorted_photos = sort {
            return $a->{seq} <=> $b->{seq} if $a->{seq} != $b->{seq};
            return $b->{datetaken} cmp $a->{datetaken};  # Fallback to datetaken if seq is the same
        } @$photos;
    } elsif ($sort eq 'datetaken') {
        @sorted_photos = sort { $a->{$sort} cmp $b->{$sort} } @$photos;
    } else {
        @sorted_photos = sort { $a->{$sort} <=> $b->{$sort} } @$photos;
    }

    @sorted_photos = reverse @sorted_photos if $rev;

    my $sorted_ids = join(',', map { $_->{id} } @sorted_photos);

    my $response = $flickr->execute_method('flickr.photosets.reorderPhotos', {
        photoset_id => $photoset->{id},
        photo_ids => $sorted_ids,
    });
    warn "Error at sort photos in $photoset->{title} ($photoset->{id}): $response->{error_message}" and next unless $response->{success};
    print "Photoset $photoset->{title} sorted by $sort.";
}
