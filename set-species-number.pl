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
    print "  $0 --file countingFile [--min N] [--max N] [--dry-run]\n";
    print "  $0 -f countingFile [--min N] [--max N] [-n]\n";
    print "\nOptions:\n";
    print "  -f, --file FILE    JSON file with counting data (required)\n";
    print "  --min NUM          Minimum species number (default: 0)\n";
    print "  --max NUM          Maximum species number (default: 20000)\n";
    print "  -n, --dry-run      Simulate without adding tags\n";
    print "  -h, --help         Show this help message\n";
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
my ($min, $max) = (0, 20000);
my $dry_run = 0;

GetOptions(
  "f|file=s" => \$file_name,
  "min=i" => \$min,
  "max=i" => \$max,
  "n|dry-run" => \$dry_run,
  "h|help" => \&usage
);

usage () unless defined $file_name;
# read the data from json file
my $json_text = readfile($file_name);

# parse the json text to perl data structure
my $counting = $json->decode($json_text);

foreach my $elem (@$counting) {
  my $n = $elem->{cnt};
  next unless $n > $min && $n < $max;
  my $photos = $elem->{photos};
  my @ids = keys %$photos;
  next unless @ids;
  my $species = $photos->{$ids[0]}->{binomial};
  my $tag = qq|species:number="$n"|;
  foreach my $id (@ids) {
    if ($dry_run) {
      print "Dry run: Would add machine:tag $tag to photo $id for '$species'";
      next;
    }
    my $response = eval {
      $flickr->execute_method('flickr.photos.addTags', {
        photo_id => $id,
        tags => $tag
      })
    } or warn "$@" and sleep 1 and redo;
    warn "Error while try to set new machine:tag ($tag) to '$species': $response->{error_message}\n\n" and sleep 1 and redo unless $response->{success};
    print "Done new machine:tag $tag on '$species'";
  }
}