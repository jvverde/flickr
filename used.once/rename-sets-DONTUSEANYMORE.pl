#!/usr/bin/perl

use Flickr::API;
use Data::Dumper;
exit; 
my $config_file = "$ENV{HOME}/saved-flickr.st";

my $flickr = Flickr::API->import_storable_config($config_file);

my $min_hex = 'FF';

my $response = $flickr->execute_method('flickr.photosets.getList');

my $sets = $response->as_hash();

#print Dumper $sets;
#exit;

my $per_page = 500;
my $page = 1;
my @sets;

while (1) {
    my $response = $flickr->execute_method('flickr.photosets.getList', {
        page => $page,
        per_page => $per_page
    });
    
    die "Error retrieving photosets: $response->{error_message}\n\n" unless $response->{success};

    my $sets_page = $response->as_hash()->{photosets}{photoset};
    foreach my $set (@$sets_page) {
        my $title = $set->{title};
        #print Dumper $set;
        if ($title =~ /A1\s+-\s+([0-9a-fA-F]{2})\s+(.+)$/) {
            my $hex = $1;
            if (hex($hex) >= hex($min_hex)) {
                my $new_hex = sprintf("%02X", hex($hex) - 1);
                my $new_title = "A1 - $new_hex $2";
                my $set_id = $set->{id};
                 my $res = $flickr->execute_method('flickr.photosets.editMeta', {
                    'photoset_id' => $set_id,
                   'title' => $new_title
                });
                die "Error retrieving photosets: $res->{error_message}\n\n" unless $res->{success}; 
                print "Renamed set $set_id from $title to $new_title\n";
            }
        }
    }

    last if scalar @$sets_page < $per_page;
    $page++;
}

