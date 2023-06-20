#!/usr/bin/perl
use strict;
use warnings;
use Getopt::Long;
use Flickr::API;
use Data::Dumper;
binmode(STDOUT, ':utf8');

$\ = "\n";

sub usage {
    print "Find photos contaning a list of tags but not containing a list of  exclude tags";
    print "Usage: $0 [OPTIONS] FILENAME";
    print "Options:\n\t\t-i tag[-i tag[...]] -e tag [-e tag[...]]\n\t\t-h\thelp";
    print "Example: perl $0 -e ioc131 -i ioc53";
    print "\nNOTE: It assumes the user's tokens are initialized in the file '$ENV{HOME}/saved-flickr.st'";
    exit;
}

# parse command line arguments
my (@inc, @exc);
GetOptions(
    "e|exc=s" => \@exc,
    "i|inc=s" => \@inc,
    "h|help" => \&usage
);
usage() unless @inc or @exc;

my $config_file = "$ENV{HOME}/saved-flickr.st";
my $flickr = Flickr::API->import_storable_config($config_file);

# Get the filename argument from the command line

my $tags = join ',', map { qq|"$_"| } @inc;
$tags = join ',', $tags, map { qq|"-$_"| } @exc;
#print $tags;
#exit;
my $response = $flickr->execute_method('flickr.photos.search', {
    user_id => 'me',
    tags => $tags,
    tag_mode => 'all',
    extras => 'url, tags',
    per_page => 500,
    page => 1
});

warn "Error retrieving photos: $response->{error_message}\n\n" and next unless $response->{success};

my $data = $response->as_hash();

die "No photos in answer" unless defined $data && defined $data->{photos};

my $photos = $data->{photos}->{photo};

$photos = [$photos] if 'ARRAY' ne ref $photos;

#print Dumper $photos; 
foreach my $photo (grep { $_->{id} and $_->{owner} } @$photos) {
    my $photo_id = $photo->{id};
    my $owner = $photo->{owner};
    my $photo_url = qq|https://www.flickr.com/photos/$owner/$photo_id/|;
    print $photo_url;    
}
