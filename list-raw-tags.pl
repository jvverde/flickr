#!/usr/bin/perl
use strict;
use warnings;
use Getopt::Long;
use Flickr::API;
use Data::Dumper;
binmode(STDOUT, ':utf8');

$\ = "\n";

sub usage {
    print "This script lists all tags of the current user's photos.";
    print "Usage: $0 [OPTIONS]";
    print "Options:";
    print "  -h, --help    Show this help message and exit";
    print "\nNOTE: It assumes the user's tokens are initialized in the file '$ENV{HOME}/saved-flickr.st'";
    exit;
}

GetOptions(
    'h|help' => \&usage
);

my $config_file = "$ENV{HOME}/saved-flickr.st";
my $flickr = Flickr::API->import_storable_config($config_file);

my $response = $flickr->execute_method('flickr.tags.getListUserRaw');

die "Error retrieving tags: $response->{error_message}\n\n" unless $response->{success};

my $tags = $response->as_hash()->{who}->{tags}->{tag};

foreach my $tag (@$tags) {
  my $ref = ref $tag->{raw};
  if ($ref eq 'HASH') {
    print  $tag->{clean};
    next;
  } elsif ($ref eq 'ARRAY') {
    print foreach grep { !ref $_ } (@{$tag->{raw}})
  } elsif (!$ref) {
    print $tag->{raw};
  } else {
    print Dumper $tag->{raw};
  }
}
