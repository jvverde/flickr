#!/usr/bin/perl

use Flickr::API;
use Term::ReadLine;
use Data::Dumper;
use Dotenv -load;
 
my $config_file = "$ENV{HOME}/saved-flickr.st";

my $term   = Term::ReadLine->new('Testing Flickr::API');
$term->ornaments(0);
 
my $api = Flickr::API->new({
  'consumer_key'    => $ENV{fkey},
  'consumer_secret' => $ENV{fsecret},
});
 
 
my $rt_rc =  $api->oauth_request_token( { 'callback' => 'https://127.0.0.1/' } );
 
my %request_token;
if ( $rt_rc eq 'ok' ) {
 
    my $uri = $api->oauth_authorize_uri({ 'perms' => 'write' });
 
    my $prompt = "\n\n$uri\n\n" .
        "Copy the above url to a browser, and authenticate with Flickr\n" .
        "Press [ENTER] once you get the redirect: ";
    my $input = $term->readline($prompt);
 
    $prompt = "\n\nCopy the redirect URL from your browser and enter it\nHere: ";
    $input = $term->readline($prompt);
 
    chomp($input);
 
    my ($callback_returned,$token_received) = split(/\?/,$input);
    my (@parms) = split(/\&/,$token_received);
    foreach my $pair (@parms) {
 
        my ($key,$val) = split(/=/,$pair);
        $key =~ s/oauth_//;
        $request_token{$key}=$val;
 
    }
}
 
my $ac_rc = $api->oauth_access_token(\%request_token);

if ( $ac_rc eq 'ok' ) {
 
    $api->export_storable_config($config_file);
 
    my $response = $api->execute_method('flickr.auth.oauth.checkToken');
    my $hash_ref = $response->as_hash();
 
    $response    = $api->execute_method('flickr.prefs.getPrivacy');
    my $rsp_node = $response->as_tree();
}