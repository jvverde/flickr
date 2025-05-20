#!/usr/bin/perl
use strict;
use warnings;
use Flickr::API;
use JSON;
use Data::Dumper;

$\ = "\n";

# Check arguments
sub usage {
    print "Usage: $0 <tag1> <tag2>\n";
    exit 1;
}

usage() unless @ARGV == 2;

my ($tag1, $tag2) = @ARGV;

# Flickr config
my $config_file = "$ENV{HOME}/saved-flickr.st";
my $flickr = Flickr::API->import_storable_config($config_file);

# Search for photos with either of the tags
my $page = 1;

while (1) {
    my $result = $flickr->execute_method('flickr.photos.search', {
        tags     => "$tag1,$tag2",
        tag_mode => 'any',
        per_page => 500,
        page     => $page,
        extras   => 'tags,description',
    });

    last unless $result->is_success;

    my $response = $result->as_hash();
    my $photos = $response->{photos}->{photo};
    $photos = [$photos] unless ref $photos eq 'ARRAY';

    foreach my $photo (@$photos) {
        next unless $photo->{id};
        my @tags = split ' ', $photo->{tags};
        my %tagset = map { $_ => 1 } @tags;

        my $has_tag1 = exists $tagset{lc $tag1};
        my $has_tag2 = exists $tagset{lc $tag2};

        next if $has_tag1 && $has_tag2;     # skip if both
        next unless $has_tag1 || $has_tag2; # skip if neither

        my $page_url = "https://www.flickr.com/photos/$photo->{owner}/$photo->{id}/";
        my $title = $photo->{title};

        my $desc = $photo->{description} // '';
        my ($first_line) = split /\n/, $desc;
        my $sci_name = '';
        if ($first_line && $first_line =~ /\(<i>([^<]+)<\/i>\)/) {
            $sci_name = $1;
        }

        my $mesg = $has_tag1 ? "(Missing $tag2)" : "(Missing $tag1)";
        print "$mesg | $sci_name | $title | $page_url";
    }

    last if $page >= $response->{photos}->{pages};
    $page++;
}
