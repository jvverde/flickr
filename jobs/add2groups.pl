#!/usr/bin/perl
# This script finds all groups of the user 'me' matching a given group pattern,
# selects a random group where the last photo is not from the current user,
# then searches for a random photo belonging to a set matching the provided set pattern,
# and adds it to the selected group, but only if the photo is not already in the group.
# It supports dry-run mode and debug output.
#
# Usage: perl flickr_add_to_random_group.pl [OPTIONS]
# Options:
#   -h, --help            Show help message and exit
#   -n, --dry-run         Simulate adding without making changes
#   -d, --debug           Print Dumper output for various API responses
#   -g, --group-pattern   Regex pattern to match group names (required)
#   -s, --set-pattern     Regex pattern to match set (photoset) titles (required)
#   -a, --max-age         Maximal age of photos in years (optional)
#
# Prerequisites:
# - Requires a Flickr API configuration file at $ENV{HOME}/saved-flickr.st
# - Uses Perl modules: Getopt::Long, Flickr::API, Data::Dumper
#
# Examples:
#   perl flickr_add_to_random_group.pl -g 'map.*' -s 'album.*'
#     Adds a random photo from a matching set to a random matching group if conditions are met.
#   perl flickr_add_to_random_group.pl -g 'map.*' -s 'album.*' -n
#     Dry-run mode: prints what would be added without making changes.
#   perl flickr_add_to_random_group.pl -g 'map.*' -s 'album.*' -d
#     Debug mode: dumps various API responses.
#   perl flickr_add_to_random_group.pl -g 'map.*' -s 'album.*' -a 2
#     Only considers photos up to 2 years old.

use strict;
use warnings;
use Getopt::Long;
use Flickr::API;
use Data::Dumper;
use Time::Local;

$\ = "\n";  # Set output record separator to newline
my ($help, $dry_run, $debug, $group_pattern, $set_pattern, $max_age_years);  # Command-line options

# Parse command-line options
GetOptions(
    'h|help'           => \$help,
    'n|dry-run'        => \$dry_run,
    'd|debug:i'        => \$debug,
    'g|group-pattern=s' => \$group_pattern,
    's|set-pattern=s'   => \$set_pattern,
    'a|max-age=i'       => \$max_age_years,
);

my $group_match = qr/$group_pattern/i;
my $set_match = qr/$set_pattern/i;

# Calculate max age timestamp if provided
my $max_age_timestamp;
if (defined $max_age_years) {
    $max_age_timestamp = time() - ($max_age_years * 365 * 24 * 60 * 60);
    print "Debug: Max age timestamp: $max_age_timestamp (photos after " . scalar(localtime($max_age_timestamp)) . ")" if $debug;
}

# Display help message if -h or --help is specified or required options missing
if ($help || !$group_pattern || !$set_pattern) {
    print "This script adds a random photo from a matching set to a random matching group if conditions are met";
    print "Usage: $0 [OPTIONS]";
    print "Options:";
    print "  -h, --help            Show this help message and exit";
    print "  -n, --dry-run         Simulate adding without making changes";
    print "  -d, --debug           Print Dumper output for various API responses";
    print "  -g, --group-pattern   Regex pattern to match group names (required)";
    print "  -s, --set-pattern     Regex pattern to match set (photoset) titles (required)";
    print "  -a, --max-age         Maximal age of photos in years (optional)";
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

# Get all photosets (sets) for the user
my $sets_response = $flickr->execute_method('flickr.photosets.getList', { user_id => $user_nsid });
die "Error fetching photosets: $sets_response->{error_message}" unless $sets_response->{success};
print "Debug: Dumping photosets response", Dumper($sets_response->as_hash) if defined $debug and $debug > 2;

my $all_sets = $sets_response->as_hash->{photosets}->{photoset} || [];
$all_sets = [ $all_sets ] unless ref $all_sets eq 'ARRAY';

# Filter matching sets
my @matching_sets = grep { ($_->{title} || '') =~ $set_match } @$all_sets;

if (!@matching_sets) {
    print "No sets matching pattern '$set_pattern' found.";
    exit;
}
print "Debug: Found " . scalar(@matching_sets) . " matching sets." if $debug;

# Get all groups for the user
my $groups_response = $flickr->execute_method('flickr.people.getGroups', { user_id => $user_nsid });
die "Error fetching groups: $groups_response->{error_message}" unless $groups_response->{success};
print "Debug: Dumping groups response", Dumper($groups_response->as_hash) if defined $debug and $debug > 2;

my $all_groups = $groups_response->as_hash->{groups}->{group} || [];
$all_groups = [ $all_groups ] unless ref $all_groups eq 'ARRAY';

# Filter matching groups
my @matching_groups = grep { ($_->{name} || '') =~ $group_match } @$all_groups;

if (!@matching_groups) {
    print "No groups matching pattern '$group_pattern' found.";
    exit;
}
print "Debug: Found " . scalar(@matching_groups) . " matching groups." if $debug;

# Try to find a suitable group and photo
my $max_tries = 20;
my $found = 0;
for (1 .. $max_tries) {
    # Select a random matching group
    last unless scalar @matching_groups;
    my $random_group_index = int(rand(@matching_groups));
    my $selected_group = $matching_groups[$random_group_index];
    my $group_id = $selected_group->{nsid};
    my $group_name = $selected_group->{name};
    print "Debug: Selected random group: $group_name ($group_id)" if $debug;

    # Get the latest photo in the group pool
    my $pool_response = $flickr->execute_method('flickr.groups.pools.getPhotos', {
        group_id => $group_id,
        per_page => 1,
    });
    unless ($pool_response->{success}) {
        warn "Error fetching group pool for $group_id: $pool_response->{error_message}";
        sleep 1;
        next;
    }
    print "Debug: Dumping pool response for group $group_id", Dumper($pool_response->as_hash) if defined $debug and $debug > 1;

    my $photos = $pool_response->as_hash->{photos}->{photo} || [];
    $photos = [ $photos ] unless ref $photos eq 'ARRAY';
    if (@$photos) {
        my $latest_owner = $photos->[0]->{owner};
        if ($latest_owner eq $user_nsid) {
            print "Debug: Last photo in group $group_id is from current user, skipping this group." if $debug;
            # Remove this group from @matching_groups so it won't be selected again
            splice(@matching_groups, $random_group_index, 1);
            next;
        }
    } else {
        print "Debug: Group $group_id has no photos, proceeding." if $debug;
    }

    # Select a random matching set
    my $random_set_index = int(rand(@matching_sets));
    my $selected_set = $matching_sets[$random_set_index];
    my $set_id = $selected_set->{id};
    my $set_title = $selected_set->{title} // '';
    my $total = $selected_set->{photos};
    print "Debug: Selected random set: $set_title ($set_id) with $total photos" if $debug;
    if ($total == 0) {
        print "Debug: Set $set_id has no photos, skipping." if $debug;
        next;
    }

    # Select a random page in the set
    my $random_page = int(rand($total)) + 1;

    # Build parameters for flickr.photosets.getPhotos
    my $get_photos_params = {
        photoset_id => $set_id,
        per_page    => 1,
        page        => $random_page,
    };
    
    # Add extras parameter if max_age is specified to get date_taken
    if (defined $max_age_timestamp) {
        $get_photos_params->{extras} = 'date_taken';
    }

    # Fetch the single photo on that page
    my $set_photos_response = $flickr->execute_method('flickr.photosets.getPhotos', $get_photos_params);
    unless ($set_photos_response->{success}) {
        warn "Error fetching photo from set $set_id: $set_photos_response->{error_message}";
        sleep 1;
        next;
    }
    print "Debug: Dumping set photos response for page $random_page in set $set_id", Dumper($set_photos_response->as_hash) if defined $debug and $debug > 1;

    my $set_photos = $set_photos_response->as_hash->{photoset}->{photo} || [];
    $set_photos = [ $set_photos ] unless ref $set_photos eq 'ARRAY';
    next unless $set_photos && @$set_photos;

    my $selected_photo = $set_photos->[0];
    my $photo_id = $selected_photo->{id};
    my $photo_title = $selected_photo->{title} // '';  # Use empty string if no title

    # Check photo age if max_age is specified
    if (defined $max_age_timestamp && $selected_photo->{datetaken}) {
        my $date_taken = $selected_photo->{datetaken};
        
        # Parse the date (format: "YYYY-MM-DD HH:MM:SS")
        if ($date_taken =~ /^(\d{4})-(\d{2})-(\d{2})\s+(\d{2}):(\d{2}):(\d{2})$/) {
            my ($year, $month, $day, $hour, $min, $sec) = ($1, $2, $3, $4, $5, $6);
            my $photo_timestamp = Time::Local::timelocal($sec, $min, $hour, $day, $month-1, $year-1900);
            
            if ($photo_timestamp < $max_age_timestamp) {
                print "Debug: Photo '$photo_title' ($photo_id) is too old (taken on $date_taken), skipping." if $debug;
                next;
            }
            print "Debug: Photo '$photo_title' ($photo_id) taken on $date_taken - within age limit" if $debug;
        } elsif ($date_taken =~ /^(\d{4})-(\d{2})-(\d{2})$/) {
            # Handle case where only date is provided (no time)
            my ($year, $month, $day) = ($1, $2, $3);
            my $photo_timestamp = Time::Local::timelocal(0, 0, 0, $day, $month-1, $year-1900);
            
            if ($photo_timestamp < $max_age_timestamp) {
                print "Debug: Photo '$photo_title' ($photo_id) is too old (taken on $date_taken), skipping." if $debug;
                next;
            }
            print "Debug: Photo '$photo_title' ($photo_id) taken on $date_taken - within age limit" if $debug;
        } else {
            print "Debug: Could not parse date taken for photo $photo_id: $date_taken" if $debug;
        }
    }

    # Check if photo is already in the group using getAllContexts
    my $contexts_response = $flickr->execute_method('flickr.photos.getAllContexts', { photo_id => $photo_id });
    unless ($contexts_response->{success}) {
        print "Error fetching contexts for photo $photo_id: $contexts_response->{error_message}";
        next;
    }
    print "Debug: Dumping contexts for photo $photo_id", Dumper($contexts_response->as_hash) if defined $debug and $debug > 1;

    my $photo_pools = $contexts_response->as_hash->{pool} || [];
    $photo_pools = [ $photo_pools ] unless ref $photo_pools eq 'ARRAY';
    my $already_in = grep { $_->{id} eq $group_id } @$photo_pools;

    if (!$already_in) {
        # Suitable photo and group found
        if ($dry_run) {
            print "Would add photo '$photo_title' ($photo_id) from set '$set_title' ($set_id) to group '$group_name' ($group_id)";
        } else {
            my $add_response = $flickr->execute_method('flickr.groups.pools.add', {
                photo_id => $photo_id,
                group_id => $group_id,
            });
            if ($add_response->{success}) {
                print "Added photo '$photo_title' ($photo_id) from set '$set_title' ($set_id) to group '$group_name' ($group_id)";
            } else {
                print "Error adding photo '$photo_title' ($photo_id) to group '$group_name' ($group_id): $add_response->{error_message}";
                splice(@matching_groups, $random_group_index, 1);
                sleep 1;
                next;
            }
        }
        $found = 1;
        last;
    }
    print "Debug: Photo '$photo_title' ($photo_id) already in group '$group_name' ($group_id), trying another.";
}

print "No suitable photo and group found" unless $found;
print "Processing complete!" unless $dry_run;  # Final message unless in dry-run mode