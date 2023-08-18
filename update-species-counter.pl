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
    print "  $0 --file jsonfile --out updatefile\n";
    print "  $0 -f jsonfile -o updatefile\n";
    exit;
}

sub readfile {
    open(my $fh, "<", $_[0]) or die("Can't open $_[0]: $!");
    local $/;
    my $result = <$fh>;
    close $fh;
    return $result
}
sub writefile {
    my ($file, $content) = @_;
    open(my $fh, ">", $file) or die("Can't open $file: $!");
    print $fh $content;
    close $fh;
}

my ($file_name, $out);

GetOptions(
  "f|file=s" => \$file_name,
  "o|out=s" => \$out,
  "h|help" => \&usage
);

usage () unless defined $file_name and defined $out;
# read the data from json file
my $json_text = readfile($file_name);

# parse the json text to perl data structure
my $data = $json->decode($json_text);
die "Invalid file. It should be a json array of hashes with a key species" unless defined $data->[0] && exists $data->[0]->{species};

my @all;
my $cnt = 0;
foreach my $hash (@$data) {
    my $species = $hash->{species};

    # search for photos with the key value and add tags to them
    my $response = eval { # prevent a die from API
      $flickr->execute_method('flickr.photos.search', {
        user_id => 'me',
        tags => $species,
        per_page => 500,
        extras => 'date_upload',
        page => 1
      })
    } or warn "$@" and redo;
    warn "Error retrieving photos of '$species': $response->{error_message}\n\n" and redo unless $response->{success};

    my $photos = $response->as_hash()->{photos}->{photo};
    $photos = [ $photos ] unless ref $photos eq 'ARRAY'; #Just in case for a limit situation when there is only 1 photo
    next unless exists $photos->[0]->{id}; 
    my @order = sort { $a->{dateupload} <=> $b->{dateupload} } @$photos;
    push @all, {
      species => $species,
      date => $order[0]->{dateupload},
      first => $order[0]->{id},
      ids => [map { $_->{id} } @$photos]
    };
    print ++$cnt, "- For '$species' got", scalar @$photos, 'photos';
    #last if $cnt > 2;
}

my @order = sort { $a->{date} <=> $b->{date} } @all;

my $current = {};

if (-f $out) {
  $current = $json->decode(readfile($out))
}

my $number = 1;
foreach my $ele (@order) {
  my $species = $ele->{species};
  my $c = $current->{$species} // { n => 0 };
  if ($c->{n} > $number) {
    print "Previous was $c->{n} (> $number)";
    $number = $c->{n};
  }
  $ele->{n} = $number++;
  $current->{$species} = $ele;
}

print "Update json file on $out";

writefile($out, $json->pretty->encode($current));
