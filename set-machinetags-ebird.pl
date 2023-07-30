#!/usr/bin/perl
use strict;
use warnings;
use Getopt::Long;
use Flickr::API;
use Data::Dumper;
use JSON;
binmode(STDOUT, ':utf8');


$\ = "\n";
$, = ", ";
my $json = JSON->new->utf8;
# import Flickr API configuration
my $config_file = "$ENV{HOME}/saved-flickr.st";
my $flickr = Flickr::API->import_storable_config($config_file);

# usage subroutine to print help message
sub usage {
    print "Usage:\n";
    print "  $0 --file jsonfile --key keyname --tag tagkey1 [--tag tagkey2 ...]\n";
    print "  $0 -f jsonfile -k keyname -t tagkey1 [--t tagkey2 ...]\n";
    exit;
}

# parse command line arguments
my ($file_name, $key_name, @tag_keys, $match, $list);
my $rev = undef;
GetOptions(
    "f|file=s" => \$file_name,
    "k|key=s" => \$key_name,
    "t|tag=s" => \@tag_keys,
    "r|reverse" => \$rev,
    "m|match=s" => \$match,
    "l|list=s", => \$list,
    "h|help" => \&usage
);

usage () unless $file_name && $key_name && @tag_keys;

# read the data from json file
my $json_text = do {
    open(my $json_fh, "<", $file_name)
        or die("Can't open $file_name: $!");
    local $/;
    <$json_fh>
};

# parse the json text to perl data structure
my $data = $json->decode($json_text);
$data = [reverse @$data] if defined $rev;

# get the current user's id
#my $user_id = $flickr->execute_method('flickr.test.login')->{user}->{id};

# loop through each hash in the array

foreach my $hash (@$data) {
    my $key_value = $hash->{$key_name};
    next if $match && $key_value !~ m/\Q$match\E/i;

    # search for photos with the key value and add tags to them
    my $response = $flickr->execute_method('flickr.photos.search', {
        user_id => 'me',
        tags => $key_value,
        per_page => 500,
        page => 1
    });
    warn "Error retrieving photos: $response->{error_message}\n\n" and next unless $response->{success};

    my $photos = $response->as_hash()->{photos}->{photo};
    $photos = [ $photos ] unless ref $photos eq 'ARRAY'; #Just in case for a limit situation when there is only 1 photo

    foreach my $photo (@$photos) {
        print qq|No photos with tag $key_value|, Dumper $photo and next unless $photo->{id};
        my @newtags = grep { $_ } @$hash{@tag_keys};
        my $tags = join ' ', map { qq|"$_"| } @newtags;
        if ( defined $list) {
            $tags = join ' ', $tags, $list,
            qq|$list:seq="$hash->{'Seq.'}"|,
            qq|$list:binomial="$hash->{'species'}"|, 
            qq|$list:name="$hash->{'English'}"|;
        }
        my $response = $flickr->execute_method('flickr.photos.addTags', {
            photo_id => $photo->{id},
            tags => $tags
        });
        warn "Error while try to set new tags ($tags) to '$photo->{title}': $response->{error_message}\n\n" and next unless $response->{success};
        print "Done new tag $tags on '$photo->{title}'";    
    }
}
