#!/usr/bin/perl
use strict;
use warnings;
use Getopt::Long;
use Flickr::API;
use Data::Dumper;
use JSON;

$\ = "\n";
my ($help, $url, $tag, $pattern);
my $lines = 4;

sub usage {
    print "This script searches for photos with a specific tag that match a pattern in the description field and adds them to a photoset specified by a URL.";
    print "Usage: $0 --url <photoset_url> --tag <tag> --pattern <pattern> [--lines <num_lines>]";
    print "Options:";
    print "  -u, --url       URL of the photoset to add photos to";
    print "  -t, --tag       Tag to search for in photos";
    print "  -p, --pattern   Pattern to match in the photo description field";
    print "  -l, --lines     Number of lines in the description to check for the pattern (default: 4)";
    print "  -h, --help      Show this help message and exit";
    print "\nNOTE: It assumes the user's tokens are initialized in the file '$ENV{HOME}/saved-flickr.st'";
    exit;
}

GetOptions(
    'u|url=s'     => \$url,
    't|tag=s'     => \$tag,
    'p|pattern=s' => \$pattern,
    'l|lines=i'   => \$lines,
    'h|help'      => \&usage
);

unless ($url && $tag && $pattern) {
    print "Error: --url, --tag, and --pattern are required.";
    usage();
}

my $config_file = "$ENV{HOME}/saved-flickr.st";
my $flickr = Flickr::API->import_storable_config($config_file);

# Extract photoset ID from the URL
my ($photoset_id) = $url =~ m%(?:sets|albums)/(\d+)/?$%;
die "Invalid photoset URL: $url\n" unless $photoset_id;

# Search for photos with the specified tag
my $per_page = 500;
my $page = 1;
my @matching_photos;

while (1) {
    my $response = $flickr->execute_method('flickr.photos.search', {
        tags        => $tag,
        text        => $pattern,
        per_page    => $per_page,
        page        => $page,
        extras      => 'description'
    });

    die "Error searching photos: $response->{error_message}\n" unless $response->{success};

    my $photos = $response->as_hash()->{photos}->{photo};

    # Filter photos based on pattern match in the first few lines of the description
    foreach my $photo (@$photos) {
        # Access the description field correctly
        my $description = $photo->{description} // '';
        my @description_lines = split /\n/, $description;
        my $max_index = $lines - 1;
        $max_index = $#description_lines if $max_index > $#description_lines;  # Ensure we don't exceed the array bounds
        my $first_lines = join "\n", @description_lines[0 .. $max_index];

        # Use /im modifiers for case-insensitive and multiline matching
        if ($first_lines =~ /$pattern/im) {
            push @matching_photos, $photo;
        }
    }

    last if scalar @$photos < $per_page;
    $page++;
}

# Add matching photos to the photoset
foreach my $photo (@matching_photos) {
    my $photo_id = $photo->{id};
    my $response = $flickr->execute_method('flickr.photosets.addPhoto', {
        photoset_id => $photoset_id,
        photo_id    => $photo_id
    });

    if ($response->{success}) {
        print "Added photo '$photo->{title}' to photoset $photoset_id";
    } else {
        print "Failed to add photo '$photo->{title}': $response->{error_message}";
    }
}
