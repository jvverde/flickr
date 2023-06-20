#!/usr/bin/perl
use Flickr::API;
use Term::ReadLine;
use Data::Dumper;
 
my $config_file = "$ENV{HOME}/saved-flickr.st";
my $term   = Term::ReadLine->new('Testing Flickr::API');
$term->ornaments(0);
 
my $api = Flickr::API->import_storable_config($config_file);

my $response = $api->execute_method('flickr.auth.oauth.checkToken');
my $hash_ref = $response->as_hash();
print "----check----\n";
print Dumper $hash_ref;

$response    = $api->execute_method('flickr.prefs.getPrivacy');
my $rsp_node = $response->as_hash();
print "----privacy----\n";
print Dumper $rsp_node;