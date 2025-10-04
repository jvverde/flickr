#!/usr/bin/perl
# This script selects a random geo-tagged photo from the user's photostream that has a machine tag in the form *:seq=* 
# and adds it to the Flickr group 'mapbirds', but only if the last photo in the group is not from the current user. 
# It checks if the photo is already in the group and selects another if necessary. It supports dry-run mode and debug output.
#
# Usage: perl flickr_add_to_mapbirds.pl [OPTIONS]
# Options:
#   -h, --help        Show help message and exit
#   -n, --dry-run     Simulate adding without making changes
#   -d, --debug       Print Dumper output for various API responses
#
# Prerequisites:
# - Requires a Flickr API configuration file at $ENV{HOME}/saved-flickr.st
# - Uses Perl modules: Getopt::Long, Flickr::API, Data::Dumper
#
# Examples:
#   perl flickr_add_to_mapbirds.pl
#     Adds a random geo-tagged photo with *:seq=* machine tag to the group if conditions are met.
#   perl flickr_add_to_mapbirds.pl -n
#     Dry-run mode: prints what would be added without making changes.
#   perl flickr_add_to_mapbirds.pl -d
#     Debug mode: dumps various API responses.

use strict;
use warnings;
use Getopt::Long;
use Flickr::API;
use Data::Dumper;

$\ = "\n";  # Set output record separator to newline
my ($help, $dry_run, $debug);  # Command-line options

# Parse command-line options
GetOptions(
    'h|help'     => \$help,
    'n|dry-run'  => \$dry_run,
    'd|debug'    => \$debug,
);

# Display help message if -h or --help is specified
if ($help) {
    print "This script adds a random geo-tagged photo with *:seq=* machine tag to the Flickr group 'mapbirds' if conditions are met";
    print "Usage: $0 [OPTIONS]";
    print "Options:";
    print "  -h, --help        Show this help message and exit";
    print "  -n, --dry-run     Simulate adding without making changes";
    print "  -d, --debug       Print Dumper output for various API responses";
    print "\nNOTE: It assumes the user's tokens are initialized in the file '$ENV{HOME}/saved-flickr.st'";
    exit;
}

# Initialize Flickr API configuration
my $config_file = "$ENV{HOME}/saved-flickr.st";  # Path to Flickr API config file
my $flickr = Flickr::API->import_storable_config($config_file);  # Initialize Flickr API client

# Get current user NSID
my $login_response = $flickr->execute_method('flickr.test.login');
die "Error logging in: $login_response->{error_message}" unless $login_response->{success};
my $user_nsid = $login_response->as_hash->{user}->{id};
print "Debug: Current user NSID: $user_nsid" if $debug;

# Get group NSID for 'mapbirds'
my $group_url = 'https://www.flickr.com/groups/mapbirds/';
my $group_response = $flickr->execute_method('flickr.urls.lookupGroup', { url => $group_url });
die "Error looking up group: $group_response->{error_message}" unless $group_response->{success};
my $group_id = $group_response->as_hash->{group}->{id};
print "Debug: Dumping group lookup response", Dumper($group_response->as_hash) if $debug;

# Get the latest photo in the group pool
my $pool_response = $flickr->execute_method('flickr.groups.pools.getPhotos', {
    group_id => $group_id,
    per_page => 1,
});
die "Error fetching group pool: $pool_response->{error_message}" unless $pool_response->{success};
print "Debug: Dumping pool response", Dumper($pool_response->as_hash) if $debug;

my $photos = $pool_response->as_hash->{photos}->{photo} || [];
$photos = [ $photos ] unless ref $photos eq 'ARRAY';
if (@$photos) {
    my $latest_owner = $photos->[0]->{owner};
    if ($latest_owner eq $user_nsid) {
        print "Last photo in group is from current user, skipping.";
        exit;
    }
} else {
    print "Group has no photos, proceeding to add." if $debug;
}

# Get total number of geo-tagged photos with *:seq=* machine tag in user's photostream
my $search_params = {
    user_id       => 'me',
    has_geo       => 1,
    machine_tags  => '*:seq=*',
    per_page      => 1,
};
my $total_response = $flickr->execute_method('flickr.photos.search', $search_params);
die "Error searching photos: $total_response->{error_message}" unless $total_response->{success};
my $total = $total_response->as_hash->{photos}->{total};
print "Debug: Total geo-tagged photos with *:seq=*: $total" if $debug;
if ($total == 0) {
    print "No qualifying photos found in photostream.";
    exit;
}

# Try to find a suitable photo (not already in group)
my $max_tries = 20;
my $found = 0;
for (1 .. $max_tries) {
    # Select a random page (1 to total)
    my $random_page = int(rand($total)) + 1;

    # Fetch the single photo on that page
    $search_params->{per_page} = 1;
    $search_params->{page} = $random_page;
    my $page_response = $flickr->execute_method('flickr.photos.search', $search_params);
    die "Error fetching photo page: $page_response->{error_message}" unless $page_response->{success};
    print "Debug: Dumping page response for page $random_page", Dumper($page_response->as_hash) if $debug;

    my $page_photos = $page_response->as_hash->{photos}->{photo} || [];
    $page_photos = [ $page_photos ] unless ref $page_photos eq 'ARRAY';
    next unless $page_photos && @$page_photos;

    my $selected_photo = $page_photos->[0];
    my $photo_id = $selected_photo->{id};

    # Check if photo is already in the group using getAllContexts
    my $contexts_response = $flickr->execute_method('flickr.photos.getAllContexts', { photo_id => $photo_id });
    unless ($contexts_response->{success}) {
        print "Error fetching contexts for photo $photo_id: $contexts_response->{error_message}";
        next;
    }
    print "Debug: Dumping contexts for photo $photo_id", Dumper($contexts_response->as_hash) if $debug;

    my $photo_pools = $contexts_response->as_hash->{pool} || [];
    $photo_pools = [ $photo_pools ] unless ref $photo_pools eq 'ARRAY';
    my $already_in = grep { $_->{id} eq $group_id } @$photo_pools;

    if (!$already_in) {
        # Suitable photo found
        if ($dry_run) {
            print "Would add photo $photo_id to group $group_id";
        } else {
            my $add_response = $flickr->execute_method('flickr.groups.pools.add', {
                photo_id => $photo_id,
                group_id => $group_id,
            });
            if ($add_response->{success}) {
                print "Added photo $photo_id to group $group_id";
            } else {
                print "Error adding photo $photo_id: $add_response->{error_message}";
            }
        }
        $found = 1;
        last;
    }
}

print "No suitable photo found after $max_tries tries." unless $found;
print "Processing complete!" unless $dry_run;  # Final message unless in dry-run mode