#!/usr/bin/perl
use strict;
use warnings;
use Getopt::Long;
use Flickr::API;
use Data::Dumper;
use JSON;
binmode(STDOUT, ':utf8');


$\ = "\n";
$, = " ";
my $json = JSON->new->utf8;
# import Flickr API configuration
my $config_file = "$ENV{HOME}/saved-flickr.st";
my $flickr = Flickr::API->import_storable_config($config_file);

# usage subroutine to print help message
sub usage {
    print "Set species number\nUsage:\n";
    print "  $0 [-m minimal] --file countingFile\n";
    print "  $0 [-m minimal] -f countingFile\n";
    exit;
}

sub readfile {
    open(my $fh, "<", $_[0]) or die("Can't open $_[0]: $!");
    local $/;
    my $result = <$fh>;
    close $fh;
    return $result
}

my ($file_name);
my $min = 0;

GetOptions(
  "f|file=s" => \$file_name,
  "m=i" => \$min,
  "h|help" => \&usage
);

usage () unless defined $file_name;
# read the data from json file
my $json_text = readfile($file_name);

# parse the json text to perl data structure
my $counting = $json->decode($json_text);

foreach my $species (grep { $counting->{$_}->{n} > $min } keys %$counting) {
  my $elem = $counting->{$species};
  my $n = $elem->{n};
  my $tag = qq|species:number="$n"|;
  foreach my $id (@{$elem->{ids}}) {
    my $response = eval {
      $flickr->execute_method('flickr.photos.addTags', {
        photo_id => $id,
        tags => $tag
      })
    } or warn "$@" and redo;
    warn "Error while try to set new machine:tag ($tag) to '$species': $response->{error_message}\n\n" and next unless $response->{success};
    print "Done new machine:tag $tag on '$species'";
  }
}