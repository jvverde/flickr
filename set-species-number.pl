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
    print "  $0 --file jsonfile\n";
    print "  $0 -f jsonfile\n";
    exit;
}


my ($file_name);

GetOptions(
  "f|file=s" => \$file_name,
  "h|help" => \&usage
);

usage () unless defined $file_name;
# read the data from json file
my $json_text = do {
    open(my $json_fh, "<", $file_name)
        or die("Can't open $file_name: $!");
    local $/;
    <$json_fh>
};

# parse the json text to perl data structure
my $data = $json->decode($json_text);

# get the current user's id
#my $user_id = $flickr->execute_method('flickr.test.login')->{user}->{id};

# loop through each hash in the array

my @all;
my $cnt = 0;
foreach my $hash (@$data) {
    my $species = $hash->{species};

    # search for photos with the key value and add tags to them
    my $response = $flickr->execute_method('flickr.photos.search', {
        user_id => 'me',
        tags => $species,
        per_page => 500,
        extras => 'date_upload',
        page => 1
    });
    warn "Error retrieving photos: $response->{error_message}\n\n" and redo unless $response->{success};

    my $photos = $response->as_hash()->{photos}->{photo};
    $photos = [ $photos ] unless ref $photos eq 'ARRAY'; #Just in case for a limit situation when there is only 1 photo
    next unless exists $photos->[0]->{id}; 
    my @order = sort { $a->{dateupload} <=> $b->{dateupload} } @$photos;
    push @all, {
      first => $order[0]->{dateupload},
      photos => \@order
    };
    print ++$cnt, "- For '$species' got", scalar @$photos, 'photos';
}


my @order = sort { $a->{first} <=> $b->{first} } @all;
my $n = 0;
foreach my $species (@order) {
  $n++;
  my $tag = qq|species:number="$n"|;
  foreach my $photo (@{$species->{photos}}) {
    my $response = $flickr->execute_method('flickr.photos.addTags', {
        photo_id => $photo->{id},
        tags => $tag
    });
    warn "Error while try to set new machine:tag ($tag) to '$photo->{title}': $response->{error_message}\n\n" and next unless $response->{success};
    print "Done new machine:tag $tag on '$photo->{title}'";
  } 
}