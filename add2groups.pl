#!/usr/bin/perl
# flickr_autopost_groups.pl
#
# DESCRIPTION:
# This script automates the process of posting photos from specific Flickr sets
# (identified by a regex pattern) to eligible Flickr groups.
#
# OPTIMIZATION GOAL:
# To achieve maximum efficiency and minimize unnecessary Flickr API calls, 
# static group eligibility rules (e.g., photos_ok status, 'disabled' mode) are 
# checked and cached when the groups file is updated. The main posting loop only 
# performs dynamic API checks (to get the current 'remaining' post count) for 
# groups that are rate-limited or moderated.
#
# USAGE:
# perl flickr_autopost_groups.pl -f groups.json -s "Set Title Pattern" -a 2
#
# OPTIONS:
# -h, --help            Show help message.
# -n, --dry-run         Simulate posting without making changes.
# -d, --debug           Print detailed debug information.
# -f, --groups-file     Path to store/read cached group JSON data (required).
# -s, --set-pattern     Regex pattern to match photoset titles (required).
# -g, --group-pattern   Regex pattern to match group names (optional).
# -e, --exclude         Negative regex pattern to exclude group names (optional).
# -p, --persistent      If -e matches, permanently mark group as excluded in JSON.
# -c, --clean           Remove all existing persistent excludes from JSON data.
# --ignore-excludes     Temporarily ignore groups marked as excluded in JSON.
# -a, --max-age         Maximal age of photos in years (e.g., -a 2 for photos posted in the last 2 years).
# -t, --timeout <sec>   Maximum random delay between posts (default: 300 sec).
#
# REQUIREMENTS:
# - Perl environment with modules: Flickr::API, Data::Dumper, JSON, Time::Local, Time::HiRes.
# - Authentication tokens stored in '$ENV{HOME}/saved-flickr.st'.

use strict;
use warnings;
use utf8;
use open qw(:std :utf8);
use Getopt::Long;
use Flickr::API;
use Data::Dumper;
use JSON;
use Time::Local;
use Time::HiRes qw(sleep);

$\ = "\n"; 

# Global API and User Variables
my $flickr;
my $user_nsid;
my $debug;
my $max_age_timestamp;

# --- Command-line options and defaults ---
my ($help, $dry_run, $groups_file, $set_pattern, $group_pattern, $exclude_pattern, $max_age_years, $timeout_max);
my ($persistent_exclude, $clean_excludes, $ignore_excludes); 

# Default timeout for pauses between attempts
$timeout_max = 300; 

# Global history hashes for internal cooldowns:
# %moderated_post_history: Tracks posts to moderated groups waiting for admin approval.
# %rate_limit_history: Tracks groups that have recently been posted to, applying an internal cooldown.
my %moderated_post_history; 
my %rate_limit_history; 

GetOptions(
    'h|help'            => \$help,
    'n|dry-run'         => \$dry_run,
    'd|debug:i'         => \$debug,
    'f|groups-file=s'   => \$groups_file,
    's|set-pattern=s'   => \$set_pattern,
    'g|group-pattern=s' => \$group_pattern,
    'e|exclude=s'       => \$exclude_pattern,
    'a|max-age=i'       => \$max_age_years,
    't|timeout:i'       => \$timeout_max,
    'p|persistent'      => \$persistent_exclude,
    'c|clean'           => \$clean_excludes,
    'ignore-excludes'   => \$ignore_excludes,
);

# --- Constants ---
# Interval for forcing a full API update of the groups list (24 hours)
use constant GROUP_UPDATE_INTERVAL  => 24 * 60 * 60; 
# Timeout for waiting on a single post to a moderated group before trying again
use constant MODERATED_POST_TIMEOUT => 24 * 60 * 60; 
# Time constants used for calculating dynamic cooldowns based on limit_mode
use constant SECONDS_IN_DAY   => 24 * 60 * 60;
use constant SECONDS_IN_WEEK  => 7 * SECONDS_IN_DAY;
use constant SECONDS_IN_MONTH => 30 * SECONDS_IN_DAY; # Standardized 30-day month


# --- Subroutines ---

## Display Formatted Usage
sub show_usage {
    print "Usage: $0 [OPTIONS]";
    print "Options:";
    printf "  %-20s %s\n", "-h, --help", "Show help message and exit";
    printf "  %-20s %s\n", "-n, --dry-run", "Simulate adding without making changes";
    printf "  %-20s %s\n", "-d, --debug", "Print Dumper output for various API responses";
    printf "  %-20s %s\n", "-f, --groups-file", "Path to store/read group JSON data (required)";
    printf "  %-20s %s\n", "-s, --set-pattern", "Regex pattern to match set titles (required)";
    printf "  %-20s %s\n", "-g, --group-pattern", "Regex pattern to match group names (optional)";
    printf "  %-20s %s\n", "-e, --exclude", "Negative regex pattern to exclude group names (optional)";
    printf "  %-20s %s\n", "-p, --persistent", "If -e matches, permanently mark group as excluded in JSON.";
    printf "  %-20s %s\n", "-c, --clean", "Clean (remove) all existing persistent excludes from JSON data.";
    printf "  %-20s %s\n", "--ignore-excludes", "Temporarily ignore groups marked as excluded in JSON.";
    printf "  %-20s %s\n", "-a, --max-age", "Maximal age of photos in years (optional)";
    printf "  %-20s %s\n", "-t, --timeout <sec>", "Maximum random delay between posts (default: $timeout_max sec)";
    print "\nNOTE: Requires authentication tokens in '$ENV{HOME}/saved-flickr.st'";
}

## Initialization and Authentication
sub init_flickr {
    # Calculate the oldest allowable photo timestamp based on --max-age
    if (defined $max_age_years) {
        $max_age_timestamp = time() - ($max_age_years * 365 * 24 * 60 * 60);
        warn "Debug: Max age timestamp: $max_age_timestamp (photos after " . scalar(localtime($max_age_timestamp)) . ")" if defined $debug;
    }

    # Authenticate with Flickr API using storable config file
    my $config_file = "$ENV{HOME}/saved-flickr.st";
    $flickr = Flickr::API->import_storable_config($config_file);

    my $login_response = $flickr->execute_method('flickr.test.login');
    die "Error logging in: $login_response->{error_message}" unless $login_response->{success};
    $user_nsid = $login_response->as_hash->{user}->{id};
    warn "Debug: Logged in as $user_nsid" if defined $debug;
}

## Filter the master list of groups based on current script parameters
# This is the FIRST and MOST IMPORTANT filter. It uses the cached static data 
# to quickly discard ineligible groups without needing further API checks.
sub filter_eligible_groups {
    my ($groups_ref, $group_match_rx, $exclude_match_rx) = @_;
    
    return [ grep {
        my $g = $_;
        my $gname = $g->{name} || '';
        
        # 1. STATIC ELIGIBILITY CHECK (Uses 'can_post' which is photos_ok AND mode != disabled)
        $g->{can_post} == 1 &&
        
        # 2. Exclusion logic (check for persistent excludes, unless --ignore-excludes is set)
        ( $ignore_excludes || !defined $g->{excluded} ) &&
        
        # 3. Conditional Group Pattern Matching
        ( !defined $group_match_rx || $gname =~ $group_match_rx ) &&
        
        # 4. Conditional Exclude Pattern Matching
        ( !defined $exclude_match_rx || $gname !~ $exclude_match_rx )
    } @$groups_ref ];
}

## Fetch and store the latest groups from Flickr API (Concise Type Check)
# This function is responsible for: 
# 1. Calling the API to get the user's groups.
# 2. Getting detailed info for each group.
# 3. Performing the STATIC ELIGIBILITY check and saving it as 'can_post'.
# 4. Handling persistent exclusions.
# 5. Writing the complete, updated list to the JSON cache file.
sub update_and_store_groups {
    # Handle the case where the function is called without a previous group list
    my $old_groups_ref = shift;
    $old_groups_ref = load_groups() // [] unless 'ARRAY' eq ref $old_groups_ref;

    warn "Info: Refreshing group list from Flickr API..." if defined $debug;
    
    # Get all groups the user is a member of
    my $groups_response = $flickr->execute_method('flickr.groups.pools.getGroups', {});
    die "Error fetching pool groups: $groups_response->{error_message}" unless $groups_response->{success};

    my $new_groups_raw = $groups_response->as_hash->{groups}->{group} || [];
    $new_groups_raw = [ $new_groups_raw ] unless ref $new_groups_raw eq 'ARRAY';

    # Map old groups for carrying over existing data (like 'excluded')
    my %old_groups_map = map { $_->{id} => $_ } @$old_groups_ref; 

    my @results;
    my $timestamp_epoch = time();
    
    my $exclude_rx = qr/($exclude_pattern)/si if defined $exclude_pattern;
    
    foreach my $g_raw (@$new_groups_raw) {
        my $gid   = $g_raw->{nsid};
        my $gname = $g_raw->{name};
        my $g_old = $old_groups_map{$gid};

        # 1. Fetch group details (required for moderation status and throttling info)
        my $info = $flickr->execute_method('flickr.groups.getInfo', { group_id => $gid });
        unless ($info->{success}) {
            warn "Error fetching info for $gname ($gid): $info->{error_message}";
            next;
        }

        my $data = $info->as_hash->{group};
        my $throttle = $data->{throttle} || {};
        
        my $photos_ok = 0 | $data->{restrictions}->{photos_ok} // 1;
        my $limit_mode = $throttle->{mode} // 'none';
        my $remaining = $throttle->{remaining} // 0;
        
        # *** STATIC ELIGIBILITY RULE ***
        # A group is statically eligible if photos are OK AND the limit mode is NOT 'disabled'.
        # This prevents posting to groups explicitly closed by the admin.
        my $can_post_static = $photos_ok && $limit_mode ne 'disabled';
        
        # Build new entry for caching
        my $entry = {
            timestamp     => $timestamp_epoch,
            id            => $gid,
            name          => $gname,
            privacy       => { 1 => 'Private', 2 => 'Public (invite to join)', 3 => 'Public (open)', }->{$g_raw->{privacy} // 3} || "Unknown",
            photos_ok     => $photos_ok,
            moderated     => 0 | $data->{ispoolmoderated} // 0,
            limit_mode    => $limit_mode,
            limit_count   => ($throttle->{count} // 0) + 0,
            remaining     => $remaining + 0,
            
            # Statically determined eligibility (1 or 0)
            can_post      => $can_post_static ? 1 : 0, 

            role          => $g_raw->{admin} ? "admin" : $g_raw->{moderator} ? "moderator" : "member",
        };

        # 2. Handle Persistent Exclusions (Carry over and process flags)
        
        # Carry over existing exclusion data
        $entry->{excluded} = $g_old->{excluded} if $g_old and $g_old->{excluded};

        # Process the --clean flag 
        warn "Debug: Cleaned existing excluded object from $gname" if defined $debug and $clean_excludes and $g_old and $g_old->{excluded};
        delete $entry->{excluded} if $clean_excludes;

        # Process the persistent exclusion flag (-p and -e)
        if ($persistent_exclude and defined $exclude_pattern and ($gname =~ $exclude_rx)) {
             $entry->{excluded} = { 
                 pattern => $exclude_pattern, 
                 string => $1 # Captures the matched substring
             };
             warn "Info: Persistently excluding group '$gname' due to pattern '$exclude_pattern'." if defined $debug;
        }

        push @results, $entry;
    }

    # 3. Write to JSON file
    my $json = JSON->new->utf8->pretty->encode({ groups => \@results });
    open my $fh, '>:encoding(UTF-8)', $groups_file or die "Cannot write to $groups_file: $!";
    print $fh $json;
    close $fh;
    warn "Info: Group list updated and written to $groups_file" if defined $debug;

    return \@results;
}

## Load groups from the local JSON file
sub load_groups {
    # Check if file exists before attempting to load
    return undef unless -e $groups_file;
    warn "Debug: Loading groups from $groups_file" if defined $debug;
    
    open my $fh, '<:encoding(UTF-8)', $groups_file or return undef;
    my $json_text = do { local $/; <$fh> };
    close $fh;

    my $data = eval { decode_json($json_text) };
    if ($@) {
         warn "Error decoding JSON from $groups_file: $@. Cannot load cached data." if defined $debug;
         return undef; 
    }
    
    return $data->{groups} // []; 
}

## Check the dynamic posting status of a single group via API (PURELY DYNAMIC)
# This function queries the live API for the current 'remaining' post count.
# It relies on static filtering (photos_ok, mode != disabled) being done beforehand.
sub check_posting_status {
    my ($group_id, $group_name) = @_;
    
    # Execute the API call
    my $info_response = $flickr->execute_method('flickr.groups.getInfo', { group_id => $group_id });
    
    # --- API Error Handling ---
    unless ($info_response->{success}) {
        warn "Error checking status for $group_name ($group_id): $info_response->{error_message}";
        # Treat API error as 'can_post' failure and report 0 remaining.
        return { can_post => 0, limit_mode => 'error', remaining => 0 }; 
    }
    
    my $data = $info_response->as_hash->{group};
    my $throttle = $data->{throttle} || {};
    my $limit_mode = $throttle->{mode} // 'none';
    my $remaining = $throttle->{remaining} // 0;
    
    # --- PURELY DYNAMIC LOGIC ---
    # The group is dynamically eligible if the mode is 'none' (unlimited) 
    # OR if there are remaining posts available.
    my $can_post_current = ($limit_mode eq 'none') || ($remaining > 0);
    
    warn "Debug: Group '$group_name' status: mode=$limit_mode, rem=$remaining. Can Post: " . ($can_post_current ? 'TRUE' : 'FALSE') . "." if defined $debug;
    
    return { 
        can_post => $can_post_current, 
        limit_mode => $limit_mode,
        remaining => $remaining + 0,
    };
}

## Find a random photo from matching sets (Optimized for true randomness)
# Selects a random set, a random page, and a random photo on that page.
sub find_random_photo {
    my ($sets_ref) = @_;
    
    my $PHOTOS_PER_PAGE = 250; 
    
    # 1. Select a random set
    my $random_set_index = int(rand(@$sets_ref));
    my $selected_set = $sets_ref->[$random_set_index];
    my $set_id = $selected_set->{id};
    my $total = $selected_set->{photos};
        
    return if $total == 0; # Concise check
    warn "Debug: Set $set_id has no photos, skipping set." if defined $debug and $total == 0;
    
    # Calculate the maximum page number
    my $max_page = int(($total - 1) / $PHOTOS_PER_PAGE) + 1;
    
    # 2. Select a random page
    my $random_page = int(rand($max_page)) + 1;

    # 3. Get the photos on that random page
    my $get_photos_params = { 
        photoset_id => $set_id, 
        per_page => $PHOTOS_PER_PAGE, 
        page => $random_page,
        privacy_filter => 1, # Public photos only
        extras => 'date_taken',
    };

    my $set_photos_response = $flickr->execute_method('flickr.photosets.getPhotos', $get_photos_params);
    unless ($set_photos_response->{success}) {
        warn "Error fetching photos from set $set_id: $set_photos_response->{error_message}";
        return;
    }
    
    my $photos_on_page = $set_photos_response->as_hash->{photoset}->{photo} || [];
    $photos_on_page = [ $photos_on_page ] unless ref $photos_on_page eq 'ARRAY';
    
    unless (@$photos_on_page) {
        warn "Warning: Page $random_page returned no public photos, skipping set." if defined $debug;
        return;
    }

    # 4. Select a truly random photo from the results on the page
    my $random_photo_index = int(rand(@$photos_on_page));
    my $selected_photo = $photos_on_page->[$random_photo_index];
    
    # 5. Check photo age
    if (defined $max_age_timestamp && $selected_photo->{datetaken}) {
        my $date_taken = $selected_photo->{datetaken};
        my $photo_timestamp;
        
        # Parse different date formats
        if ($date_taken =~ /^(\d{4})-(\d{2})-(\d{2})\s+(\d{2}):(\d{2}):(\d{2})$/) {
            my ($year, $month, $day, $hour, $min, $sec) = ($1, $2, $3, $4, $5, $6);
            $photo_timestamp = Time::Local::timelocal($sec, $min, $hour, $day, $month-1, $year-1900);
        } elsif ($date_taken =~ /^(\d{4})-(\d{2})-(\d{2})$/) {
            my ($year, $month, $day) = ($1, $2, $3);
            $photo_timestamp = Time::Local::timelocal(0, 0, 0, $day, $month-1, $year-1900);
        }

        if (defined $photo_timestamp && $photo_timestamp < $max_age_timestamp) {
            warn "Debug: Photo '$selected_photo->{title}' ($selected_photo->{id}) is too old, skipping." if defined $debug;
            return;
        }
    }

    # 6. Return the selected photo data
    return {
        id => $selected_photo->{id},
        title => $selected_photo->{title} // 'Untitled Photo',
        set_title => $selected_set->{title} // 'Untitled Set',
        set_id => $set_id,
    };
}

## Check if a specific photo is present in a group's pool (Context check)
sub is_photo_in_group {
    my ($photo_id, $group_id) = @_;
    
    # Use getAllContexts to see where the photo has been posted
    my $contexts_response = $flickr->execute_method('flickr.photos.getAllContexts', { photo_id => $photo_id });
    unless ($contexts_response->{success}) {
        warn "Error fetching contexts for photo $photo_id: $contexts_response->{error_message}";
        return 0;
    }
    
    my $photo_pools = $contexts_response->as_hash->{pool} || [];
    $photo_pools = [ $photo_pools ] unless ref $photo_pools eq 'ARRAY';
    
    # Check if the target group ID is in the list of pools
    my $is_present = grep { $_->{id} eq $group_id } @$photo_pools;
    return $is_present;
}


# --- Main Logic Execution ---

# 0. Setup and Validation
if ($help || !$groups_file || !$set_pattern) { show_usage(); exit; }
init_flickr();

# Compile regex patterns conditionally
my $group_match_rx = qr/$group_pattern/si if defined $group_pattern;
my $exclude_match_rx = qr/$exclude_pattern/si if defined $exclude_pattern; 

# 1. Load or Fetch Groups 
my $groups_list_ref;

# Handle --clean or --persistent flags by forcing a full update and write
if ($clean_excludes || $persistent_exclude) {
    warn "Info: Flags -c or -p detected. Forcing group list refresh and write back." if defined $debug;
    $groups_list_ref = update_and_store_groups();
} else {
    # Try to load cached list, fall back to API update if cache is missing/corrupt
    $groups_list_ref = load_groups() // update_and_store_groups();
}

# 2. Initial Filter (Uses CACHED static eligibility: $g->{can_post} == 1)
my @all_eligible_groups = @{ filter_eligible_groups($groups_list_ref, $group_match_rx, $exclude_match_rx) };

die "No groups match all required filters." unless @all_eligible_groups;
warn "Info: Found " . scalar(@all_eligible_groups) . " groups eligible for posting after initial filter." if defined $debug;

# 3. Get Photosets
my $sets_response = $flickr->execute_method('flickr.photosets.getList', { user_id => $user_nsid });
die "Error fetching photosets: $sets_response->{error_message}" unless $sets_response->{success};
my $all_sets = $sets_response->as_hash->{photosets}->{photoset} || [];
$all_sets = [ $all_sets ] unless ref $all_sets eq 'ARRAY';
my @matching_sets = grep { ($_->{title} || '') =~ qr/$set_pattern/i } @$all_sets;

die "No sets matching pattern '$set_pattern' found." unless @matching_sets;
warn "Info: Found " . scalar(@matching_sets) . " matching sets." if defined $debug;


# 4. Main Continuous Posting Loop
my $post_count = 0;
my $max_tries = 20;
my $moderated_wait_time = MODERATED_POST_TIMEOUT;

while (1) {
    # A. Reset the current pool of groups for this cycle.
    # Start with all statically eligible groups
    my @current_groups = @all_eligible_groups;
    
    unless (@current_groups) {
        warn "Warning: All groups filtered out due to initial checks/patterns. Sleeping for $timeout_max seconds." if defined $debug;
        sleep $timeout_max;
        next;
    }

    warn "\n--- Starting new posting cycle (Post #$post_count). Groups to attempt: " . scalar(@current_groups) . " ---" if defined $debug;

    # B. Attempt to find a suitable group/photo combination
    for (1 .. $max_tries) {
        last unless scalar @current_groups;

        # 1. Select a random group
        my $random_index = int(rand(@current_groups));
        my $selected_group = $current_groups[$random_index];
        my $group_id = $selected_group->{id};
        my $group_name = $selected_group->{name};
        
        warn "Debug: Selected random group: $group_name ($group_id)" if defined $debug;

        # --- DYNAMIC CHECK 1: Rate-Limit Cooldown Check (Internal History) ---
        # Check if the script imposed a temporary cooldown on this group
        if (defined $rate_limit_history{$group_id}) {
            my $wait_until = $rate_limit_history{$group_id}->{wait_until};
            
            if (time() < $wait_until) {
                warn "Debug: Rate-limited group '$group_name' in internal cooldown until " . scalar(localtime($wait_until)) . ". Skipping." if defined $debug;
                splice(@current_groups, $random_index, 1);
                next; 
            } else {
                warn "Info: Rate-limit cooldown for '$group_name' expired. Clearing history." if defined $debug;
                delete $rate_limit_history{$group_id}; 
            }
        }

        # --- DYNAMIC CHECK 2: Moderated Wait Timeout (Internal History) ---
        # Check if the group is moderated and we are waiting for post approval
        if ($selected_group->{moderated} == 1 and defined $moderated_post_history{$group_id}) {
            my $history = $moderated_post_history{$group_id};
            my $wait_until = $history->{post_time} + $moderated_wait_time;
            
            # Re-check if the photo has been accepted (i.e., is now in the pool)
            if (is_photo_in_group($history->{photo_id}, $group_id)) {
                warn "Info: Moderated group '$group_name' photo accepted. Cooldown cleared." if defined $debug;
                delete $moderated_post_history{$group_id};
            } elsif (time() < $wait_until) {
                warn "Debug: Moderated group '$group_name' in queue cooldown. Skipping." if defined $debug;
                splice(@current_groups, $random_index, 1);
                next; 
            } else {
                warn "Info: Moderated group '$group_name' post queue timeout expired. Re-checking status." if defined $debug;
                delete $moderated_post_history{$group_id}; 
            }
        }
        
        # --- DYNAMIC CHECK 3: API Status (Remaining Posts Check) ---
        # ONLY call the API if the group is rate-limited (mode != 'none') or moderated.
        # This saves API calls for truly unlimited groups.
        if ($selected_group->{limit_mode} ne 'none' || $selected_group->{moderated} == 1) {
            my $status = check_posting_status($group_id, $group_name);
            
            # Update group status fields based on live API data (critical for cooldown logic)
            $selected_group->{limit_mode} = $status->{limit_mode};
            $selected_group->{remaining} = $status->{remaining};
            
            # Use the immediate result for the skip decision (checks for capacity or API error)
            unless ($status->{can_post}) {
                warn "Debug: Group '$group_name' failed dynamic API check (no remaining posts or API error). Skipping." if defined $debug;
                splice(@current_groups, $random_index, 1);
                next;
            }
        }

        # 2. Check last poster (Do not spam the group)
        my $pool_response = $flickr->execute_method('flickr.groups.pools.getPhotos', { group_id => $group_id, per_page => 1 });
        my $photos = $pool_response->as_hash->{photos}->{photo} || [];
        $photos = [ $photos ] unless ref $photos eq 'ARRAY';
        
        if ($pool_response->{success} and @$photos and $photos->[0]->{owner} eq $user_nsid) {
            warn "Debug: Last photo in group $group_id is from current user, skipping this group." if defined $debug;
            splice(@current_groups, $random_index, 1);
            next;
        }

        # 3. Select Photo, Check Age, Check Context
        my $photo_data = find_random_photo(\@matching_sets);
        next unless $photo_data and $photo_data->{id};
        
        my ($photo_id, $photo_title, $set_title, $set_id) = @$photo_data{qw/id title set_title set_id/};
        
        # Final check: is the photo already in the target group?
        if (is_photo_in_group($photo_id, $group_id)) {
            warn "Debug: Photo '$photo_title' ($photo_id) already in group '$group_name', trying another." if defined $debug;
            next;
        }
        
        # 4. Post the photo!
        if ($dry_run) {
            print "DRY RUN: Would add photo '$photo_title' ($photo_id) from set '$set_title' to group '$group_name' ($group_id)";
        } else {
            my $add_response = $flickr->execute_method('flickr.groups.pools.add', { photo_id => $photo_id, group_id => $group_id });
            if ($add_response->{success}) {
                print "SUCCESS: Added photo '$photo_title' ($photo_id) to group '$group_name' ($group_id)";
                
                # Apply Moderated Cooldown (if group is moderated)
                if ($selected_group->{moderated} == 1) {
                    $moderated_post_history{$group_id} = {
                        post_time => time(),
                        photo_id  => $photo_id,
                    };
                    warn "Info: Moderated post successful. Group '$group_name' set to $moderated_wait_time second cooldown." if defined $debug;
                }

                # Apply Dynamic Rate-Limit Cooldown with Jitter (if group is limited)
                if ($selected_group->{limit_mode} eq 'day' || $selected_group->{limit_mode} eq 'week' || $selected_group->{limit_mode} eq 'month') {
                    # Safety check for limit_count
                    my $limit = $selected_group->{limit_count} || 1; 
                    
                    # Determine the period in seconds for the group's limit mode
                    my $period_seconds = 
                        $selected_group->{limit_mode} eq 'day'   ? SECONDS_IN_DAY   : 
                        $selected_group->{limit_mode} eq 'week'  ? SECONDS_IN_WEEK  : 
                        $selected_group->{limit_mode} eq 'month' ? SECONDS_IN_MONTH : 
                        0;

                    if ($limit > 0 && $period_seconds > 0) {
                        # 1. Calculate the minimum required pause time (Period / Limit Count)
                        my $base_pause_time = $period_seconds / $limit;
                        
                        # 2. Add Random Jitter (±30%) for more natural posting timing
                        my $random_multiplier = 0.7 + rand(0.6); 
                        
                        # Calculate randomized pause time
                        my $pause_time = int($base_pause_time * $random_multiplier);
                        $pause_time = 1 unless $pause_time > 0;
                        
                        my $wait_until = time() + $pause_time;
                        
                        # Store cooldown history
                        $rate_limit_history{$group_id} = {
                            wait_until => $wait_until,
                            limit_mode => $selected_group->{limit_mode},
                        };
                        warn "Info: Group '$group_name' posted to (limit $limit/$selected_group->{limit_mode}). Applying randomized $pause_time sec cooldown." if defined $debug;
                    }
                }

            } else {
                print "ERROR: Could not add photo '$photo_title' ($photo_id) to group '$group_name' ($group_id): $add_response->{error_message}";
            }
        }
        
        $post_count++;
        last; # Exit the inner 'max_tries' loop after a successful post/dry run
    }

    # C. Pause and Check for Daily Update
    my $sleep_time = int(rand($timeout_max + 1)); # Default random sleep
    print "Pausing for $sleep_time seconds before next attempt.";
    sleep $sleep_time;
    
    # Check if a daily update is needed after the sleep (to refresh static data)
    if (time() - $groups_list_ref->[0]->{timestamp} > GROUP_UPDATE_INTERVAL) {
        warn "Info: Group list cache expired. Initiating update." if defined $debug;
        
        $groups_list_ref = update_and_store_groups();
        
        # Re-filter the master list by calling the new function
        @all_eligible_groups = @{ filter_eligible_groups($groups_list_ref, $group_match_rx, $exclude_match_rx) };
        
        warn "Info: Master group list refreshed and re-filtered. Found " . scalar(@all_eligible_groups) . " eligible groups." if defined $debug;
    }
}

print "Posting loop finished! Total posts made/simulated: $post_count";