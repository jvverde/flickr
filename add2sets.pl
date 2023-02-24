#!/usr/bin/perl
use strict;
use warnings;
use Data::Dumper;
use JSON;
use Flickr::API;

$\ = "\n";
# Read the key from command line arguments
sub usage {
    print "Usage: $0 <key> <json file>\n";
    exit 1;
}

usage() unless @ARGV == 2;

my $key = shift;
# Read the JSON file with the array of hashes
my $json_text = do { local $/; <> };
my $json = JSON->new->utf8;
my $data = $json->decode($json_text);

# Read the config file to connect to Flickr
my $config_file = "$ENV{HOME}/saved-flickr.st";
my $flickr = Flickr::API->import_storable_config($config_file);

# Get the list of existing photosets and store the titles in a hash
my %photoset_titles;

# Retrieve all the sets using pagination
my $sets = [];
my $page = 0;
my $pages = 1;
while ($page++ < $pages) {
    my $response = $flickr->execute_method('flickr.photosets.getList', {
        per_page => 500,
        page => $page,
    });

    die "Error: $response->{error_message}" unless $response->{success};

    push @$sets, @{$response->as_hash->{photosets}->{photoset}};
    $pages = $response->as_hash->{photosets}->{pages};
    $page = $response->as_hash->{photosets}->{page};
}

my $re = qr/A[0-9]\s*-\s*[0-9A-F]{1,2}\s*-/i;
foreach my $set (grep { $_->{title} =~ $re } @$sets) {
    my $index = $set->{'title'};
    $index =~ s/($re\s*\w+).*/$1/i;
    $index =~ s/\s{2,}/ /;
    $photoset_titles{$index} = $set;
}
#print Dumper [keys %photoset_titles];
#exit;
my $count = 0;

# Loop over each hash in the array
foreach my $hash (@$data) {

  # Find all photos tagged with the key from the hash
  my $response = $flickr->execute_method(
    'flickr.photos.search',
    {
      'tags' => $hash->{$key},
      'user_id' => 'me'
    }
  );
  warn "Error searching photos: $response->{error_message}" and next unless $response->{success};
  my $photos = $response->as_hash->{'photos'}->{'photo'};

  $photos = [$photos] unless 'ARRAY' eq ref $photos;
  warn qq|Couldn't find any photo for tag $hash->{$key}| and next unless exists $photos->[0]->{id};

  # Construct the titles for the two photosets
  my $ordern = sprintf("%02X", $hash->{'Ord No'});
  my $title1 = 'A0 - ' . $ordern . ' - ' . $hash->{'Order'};
  my $title2 = 'A1 - ' . $hash->{'HEX'} . ' - ' . $hash->{'Family'};

  # Check if the first photoset exists and create it if it doesn't
  my $set1 = check_or_create_photoset($title1, $photos->[0]->{id});

  # Check if the second photoset exists and create it if it doesn't
  my $set2 = check_or_create_photoset($title2, $photos->[0]->{id});
  #print Dumper $set1;
  #print Dumper $set2;

  #exit if $count++ > 10;
  # Add all photos to both photosets
  my @sets = ($set1, $set2);
  foreach my $photo (@$photos) {
    foreach my $set (@sets) {
        next unless $set->{id} && $photo->{id};
        my $response = $flickr->execute_method(
            'flickr.photosets.addPhoto',
            {
                photoset_id => $set->{id},
                photo_id => $photo->{id}
            }
        );
        print qq|Add photo $photo->{title} to $set->{title}| if $response->{success};
        warn "Error adding photo $photo->{title} to set $set->{title}: $response->{error_message}" unless $response->{success} || $response->{error_message} =~ /Photo already in set/;
    }
  }
}
# Function to check if a photoset exists and create it if it doesn't
sub check_or_create_photoset {
    my ($title, $photo_id) = @_;
    return $photoset_titles{$title} if exists $photoset_titles{$title};
    # The photoset doesn't exist, so create it
    print "Not found set $title as so I am going to create it";
    my $response = $flickr->execute_method(
        'flickr.photosets.create',
        {
            title => $title,
            primary_photo_id => $photo_id
        }
    );
    warn "Error creating the set $title : $response->{error_message}" and return {} unless $response->{success};
    my $set = $response->as_hash->{'photoset'};
    $set->{title} //= $title;
    $photoset_titles{$title} = $set;
    return $set;
}