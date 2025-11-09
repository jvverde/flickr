#!/usr/bin/perl
# flickr_autopost_groups.pl
#
# DESCRIPTION:
# This script is a robust tool designed to automate the process of posting photos 
# from specific Flickr sets (identified by a regex pattern) to eligible Flickr groups.
# It employs sophisticated error handling and cooldown mechanisms to comply with 
# Flickr's API limits and group rules.
#
# KEY RELIABILITY IMPROVEMENTS:
# - **Robust API Wrapper:** 'flickr_api_call' includes retry logic with exponential backoff 
#   to handle transient network errors or temporary API throttling.
# - **File Locking:** Uses 'flock' with both shared (LOCK_SH) and exclusive (LOCK_EX) 
#   locks for the groups cache and the cooldown history files, preventing race conditions.
# - **Fault Tolerance:** API calls are wrapped in `eval` blocks to catch fatal errors (`die`) 
#   on persistent failures, allowing the script to log the issue and continue.
# - **Persistent History:** Cooldowns for rate-limited or moderated groups are tracked 
#   and stored in a JSON file, maintaining state across script runs.
# - **Photo Filtering:** Filters photos by maximum age and skips groups if the last 
#   poster was the current user.
#
# USAGE:
# perl flickr_autopost_groups.pl -f groups.json -H history.json -s "Set Title Pattern" -a 2
#
# REQUIREMENTS:
# - Perl environment with necessary modules: Flickr::API, Data::Dumper, JSON, Time::Local, Time::HiRes, Fcntl.
# - Authentication tokens must be stored in '$ENV{HOME}/saved-flickr.st' after initial authentication.

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
use Fcntl qw(:flock); # Required for file locking and robust file I/O

# Set output record separator to always print a newline
$\ = "\n";

# Global API and User Variables
my $flickr;                # Flickr::API object instance
my $user_nsid;             # Current user's Flickr NSID
my $debug;                 # Debug level (0: off, 1: info, 2: call/response, 3+: Dumper output)
my $max_age_timestamp;     # Unix timestamp representing the oldest acceptable photo date

# --- Command-line options and defaults ---
my ($help, $dry_run, $groups_file, $set_pattern, $group_pattern, $exclude_pattern, $max_age_years, $timeout_max);
my ($persistent_exclude, $clean_excludes, $ignore_excludes, $list_groups, $history_file);

# Default timeout for random pauses between post attempts
$timeout_max = 300;

# Global history hashes for internal cooldowns:
my %moderated_post_history; # Tracks posts to moderated groups waiting for acceptance
my %rate_limit_history;     # Tracks groups placed on dynamic cooldown based on limits

# Process command-line options
GetOptions(
    'h|help'              => \$help,               # Display help message
    'n|dry-run'           => \$dry_run,            # Simulate posting without making API calls
    'd|debug:i'           => \$debug,              # Enable debug output (integer level)
    'f|groups-file=s'     => \$groups_file,        # Path to cached group JSON data
    'H|history-file=s'    => \$history_file,       # Path to persistent cooldown history JSON
    's|set-pattern=s'     => \$set_pattern,        # Regex pattern to match photoset titles
    'g|group-pattern=s'   => \$group_pattern,      # Regex pattern to match target group names
    'e|exclude=s'         => \$exclude_pattern,    # Negative regex pattern to exclude group names
    'a|max-age=i'         => \$max_age_years,      # Maximal photo age in years
    't|timeout:i'         => \$timeout_max,        # Maximum random delay between posts (seconds)
    'p|persistent'        => \$persistent_exclude, # Permanently mark groups matching -e as excluded
    'c|clean'             => \$clean_excludes,     # Remove all persistent excludes from JSON data
    'ignore-excludes'     => \$ignore_excludes,    # Temporarily ignore groups marked as excluded in JSON
    'l|list-groups'       => \$list_groups,        # List group status and exit
);

# --- Constants ---
use constant GROUP_UPDATE_INTERVAL  => 24 * 60 * 60;  # Time (seconds) before refreshing the group list from Flickr
use constant MODERATED_POST_TIMEOUT => 24 * 60 * 60;  # Time (seconds) to wait before re-checking a moderated group's status
use constant SECONDS_IN_DAY   => 24 * 60 * 60;
use constant SECONDS_IN_WEEK  => 7 * SECONDS_IN_DAY;
use constant SECONDS_IN_MONTH => 30 * SECONDS_IN_DAY;

# --- Helper Subroutines ---

## Simple wrapper for conditional debug output
sub debug_print {
    return unless defined $debug;
    my ($message, $data) = @_;
    # Only print Dumper output for debug level 3 or higher
    warn "Debug: $message" . (defined $data && $debug > 2 ? Dumper($data) : '');
}

## Robust API call with retry and exponential backoff logic
# This function abstracts error handling and ensures persistent failure before die-ing.
sub flickr_api_call {
    my ($method, $args) = @_;
    my $max_retries = 5;
    my $retry_delay = 1;

    warn "Debug: API CALL: $method" if defined $debug and $debug > 0;
    debug_print("API CALL: $method with args: ", $args);

    for my $attempt (1 .. $max_retries) {
        # Execute the method. The outer 'eval' catches fatal errors (e.g., network timeout)
        my $response = eval { $flickr->execute_method($method, $args) };

        # Check for failure: 
        # 1. $@ is set (fatal error caught by eval) OR
        # 2. $response is defined but indicates failure (!success)
        if ($@ || !$response->{success}) {
            my $error = $@ || $response->{error_message} || 'Unknown error';
            warn "Attempt $attempt failed for $method: $error";

            if ($attempt == $max_retries) {
                # On final attempt, die to allow the caller's eval block to catch it
                die "Failed to execute $method after $max_retries attempts: $error";
            }

            # Exponential backoff for retry
            sleep $retry_delay;
            $retry_delay *= 8; 
            next;
        }

        debug_print("API RESPONSE: $method", $response->as_hash());

        # Success!
        return $response;
    }
}

# --- File I/O Subroutines with Locking ---

## Write the groups data structure to the local JSON file with an exclusive lock (LOCK_EX)
sub write_groups_to_file {
    my $groups_ref = shift;
    
    my $json = JSON->new->utf8->pretty->encode({ groups => $groups_ref });
    
    # Open file for writing, create if necessary
    open my $fh, '>:encoding(UTF-8)', $groups_file or die "Cannot open $groups_file for writing: $!";

    # Acquire an exclusive lock to prevent concurrent modification
    unless (flock($fh, LOCK_EX)) {
        close $fh;
        die "FATAL: Failed to acquire exclusive lock on $groups_file. Aborting write.";
    }

    print $fh $json;
    
    # Release the lock and close the file
    flock($fh, LOCK_UN);
    close $fh;
    warn "Info: Group list written to $groups_file" if defined $debug;
}

## Load groups from the local JSON file with a shared lock (LOCK_SH)
sub load_groups {
    return undef unless -e $groups_file;
    warn "Debug: Loading groups from $groups_file" if defined $debug;
    
    open my $fh, '<:encoding(UTF-8)', $groups_file or return undef;
    
    # Acquire a shared lock to prevent the file from being written to while reading
    unless (flock($fh, LOCK_SH)) {
        warn "Error: Failed to acquire shared lock on $groups_file. Skipping read." if defined $debug;
        close $fh;
        return undef;
    }

    my $json_text = do { local $/; <$fh> };
    
    flock($fh, LOCK_UN);
    close $fh;

    # Safely decode JSON
    my $data = eval { decode_json($json_text) };
    if ($@) {
           warn "Error decoding JSON from $groups_file: $@. Cannot load cached data." if defined $debug;
           return undef;
    }
    
    return $data->{groups} // [];
}

## Write the history data structure (moderated posts and rate limits) with exclusive lock
sub write_history_to_file {
    my ($moderated_ref, $rate_limit_ref) = @_;
    
    my $data_to_write = {
        moderated => $moderated_ref,
        ratelimit => $rate_limit_ref,
        timestamp => time(),
    };

    my $json = JSON->new->utf8->pretty->encode($data_to_write);
    
    open my $fh, '>:encoding(UTF-8)', $history_file or die "Cannot open $history_file for writing: $!";

    # Acquire exclusive lock
    unless (flock($fh, LOCK_EX)) {
        close $fh;
        die "FATAL: Failed to acquire exclusive lock on $history_file. Aborting write.";
    }

    print $fh $json;
    
    flock($fh, LOCK_UN);
    close $fh;
    warn "Info: History written to $history_file" if defined $debug;
}

## Load history from the local JSON file with shared lock
sub load_history {
    return unless -e $history_file;
    warn "Debug: Loading history from $history_file" if defined $debug;
    
    open my $fh, '<:encoding(UTF-8)', $history_file or return;
    
    # Acquire shared lock
    unless (flock($fh, LOCK_SH)) {
        warn "Error: Failed to acquire shared lock on $history_file. Skipping read." if defined $debug;
        close $fh;
        return;
    }

    my $json_text = do { local $/; <$fh> };
    
    flock($fh, LOCK_UN);
    close $fh;

    my $data = eval { decode_json($json_text) };
    if ($@) {
           warn "Error decoding JSON from $history_file: $@. Cannot load history data." if defined $debug;
           return;
    }
    
    # Populate global hashes from the loaded data
    %moderated_post_history = %{$data->{moderated} // {}};
    %rate_limit_history     = %{$data->{ratelimit} // {}};
    warn "Debug: History loaded. Moderated count: " . scalar(keys %moderated_post_history) . ", Rate limit count: " . scalar(keys %rate_limit_history) if defined $debug;
}


# --- Main Logic Subroutines ---

## Display Formatted Usage instructions
sub show_usage {
    print "Usage: $0 [OPTIONS]";
    print "Options:";
    printf "  %-20s %s\n", "-h, --help", "Show help message and exit";
    printf "  %-20s %s\n", "-n, --dry-run", "Simulate adding without making changes";
    printf "  %-20s %s\n", "-d, --debug", "Print Dumper output for various API responses";
    printf "  %-20s %s\n", "-f, --groups-file", "Path to store/read group JSON data (required)";
    printf "  %-20s %s\n", "-H, --history-file", "Path to store/read dynamic cooldown history (required).";
    printf "  %-20s %s\n", "-s, --set-pattern", "Regex pattern to match set titles (required, unless -l is used)";
    printf "  %-20s %s\n", "-g, --group-pattern", "Regex pattern to match group names (optional)";
    printf "  %-20s %s\n", "-e, --exclude", "Negative regex pattern to exclude group names (optional)";
    printf "  %-20s %s\n", "-p, --persistent", "If -e matches, permanently mark group as excluded in JSON.";
    printf "  %-20s %s\n", "-c, --clean", "Clean (remove) all existing persistent excludes from JSON data.";
    printf "  %-20s %s\n", "--ignore-excludes", "Temporarily ignore groups marked as excluded in JSON.";
    printf "  %-20s %s\n", "-l, --list-groups", "List all groups from the cache and exit.";
    printf "  %-20s %s\n", "-a, --max-age", "Maximal age of photos in years (optional)";
    printf "  %-20s %s\n", "-t, --timeout <sec>", "Maximum random delay between posts (default: $timeout_max sec)";
    print "\nNOTE: Requires authentication tokens in '$ENV{HOME}/saved-flickr.st'";
}

## Initialization and Authentication
sub init_flickr {
    # Calculate the oldest acceptable Unix timestamp based on max_age_years
    if (defined $max_age_years) {
        $max_age_timestamp = time() - ($max_age_years * 365 * 24 * 60 * 60);
        warn "Debug: Max age timestamp: $max_age_timestamp (photos after " . scalar(localtime($max_age_timestamp)) . ")" if defined $debug;
    }

    my $config_file = "$ENV{HOME}/saved-flickr.st";
    # Load the authentication configuration from the storable file
    $flickr = Flickr::API->import_storable_config($config_file);

    # Test the login credentials via an API call using the robust wrapper
    my $response = flickr_api_call('flickr.test.login', {}); 

    # Extract and store the user's NSID (required for various calls)
    $user_nsid = $response->as_hash->{user}->{id};
    warn "Debug: Logged in as $user_nsid" if defined $debug;
}

## Filter the master list of groups based on current script parameters
sub filter_eligible_groups {
    my ($groups_ref, $group_match_rx, $exclude_match_rx) = @_;
    
    return [ grep {
        my $g = $_;
        my $gname = $g->{name} || '';
        
        # 1. STATIC ELIGIBILITY CHECK: Must be a group where posting is permitted
        $g->{can_post} == 1 &&
        
        # 2. Exclusion logic: Skip if marked as excluded, unless --ignore-excludes is set
        ( $ignore_excludes || !defined $g->{excluded} ) &&
        
        # 3. Conditional Group Pattern Matching: Match against -g argument
        ( !defined $group_match_rx || $gname =~ $group_match_rx ) &&
        
        # 4. Conditional Exclude Pattern Matching: Must NOT match against -e argument
        ( !defined $exclude_match_rx || $gname !~ $exclude_match_rx )
    } @$groups_ref ];
}

## Fetch the latest group data from Flickr API, process it, and store it
sub update_and_store_groups {
    my $old_groups_ref = shift;
    $old_groups_ref = load_groups() // [] unless 'ARRAY' eq ref $old_groups_ref;

    warn "Info: Refreshing group list from Flickr API..." if defined $debug;
    
    # Get a list of all groups the user is a member of
    my $response = flickr_api_call('flickr.groups.pools.getGroups', {}); 

    my $new_groups_raw = $response->as_hash->{groups}->{group} || [];
    $new_groups_raw = [ $new_groups_raw ] unless ref $new_groups_raw eq 'ARRAY';

    my %old_groups_map = map { $_->{id} => $_ } @$old_groups_ref;

    my @results;
    my $timestamp_epoch = time();
    
    my $exclude_rx = qr/($exclude_pattern)/si if defined $exclude_pattern;
    
    foreach my $g_raw (@$new_groups_raw) {
        my $gid   = $g_raw->{nsid};
        my $gname = $g_raw->{name};
        my $g_old = $old_groups_map{$gid};

        # 1. Fetch detailed group info to get moderation and throttle limits
        my $response = eval { flickr_api_call('flickr.groups.getInfo', { group_id => $gid }) };

        # Handle API failure for a single group info fetch
        if ($@) {
            warn "Warning: Failed to fetch info for group '$gname' ($gid). API died: $@. Skipping this group.";
            next; 
        }
        
        my $data = $response->as_hash->{group};
        my $throttle = $data->{throttle} || {};
        
        # Determine static posting eligibility
        my $photos_ok = 0 | $data->{restrictions}->{photos_ok} // 1;
        my $limit_mode = $throttle->{mode} // 'none';
        my $remaining = $throttle->{remaining} // 0;
        
        # Group is statically eligible if 'photos_ok' is true and the limit mode is not 'disabled'
        my $can_post_static = $photos_ok && $limit_mode ne 'disabled';
        
        # Build the new group entry for the cache
        my $entry = {
            timestamp     => $timestamp_epoch,
            id            => $gid,
            name          => $gname,
            privacy       => { 1 => 'Private', 2 => 'Public (invite to join)', 3 => 'Public (open)', }->{$g_raw->{privacy} // 3} || "Unknown",
            photos_ok     => $photos_ok,
            moderated     => 0 | $data->{ispoolmoderated} // 0, # Is the pool moderated?
            limit_mode    => $limit_mode,      # 'day', 'week', 'month', or 'none'
            limit_count   => ($throttle->{count} // 0) + 0, # Total limit count (e.g., 2 per day)
            remaining     => $remaining + 0,   # Remaining posts (only accurate at time of call)
            
            can_post      => $can_post_static ? 1 : 0, # Static eligibility flag

            role          => $g_raw->{admin} ? "admin" : $g_raw->{moderator} ? "moderator" : "member",
        };

        # 2. Handle Persistent Exclusions from the old data
        
        # Preserve any existing persistent exclusion flag
        $entry->{excluded} = $g_old->{excluded} if $g_old and $g_old->{excluded};

        # Remove persistent exclusion if the --clean flag is used
        warn "Debug: Cleaned existing excluded object from $gname" if defined $debug and $clean_excludes and $g_old and $g_old->{excluded};
        delete $entry->{excluded} if $clean_excludes;

        # Apply a new persistent exclusion if the --persistent (-p) flag is used and the name matches -e
        if ($persistent_exclude and defined $exclude_pattern and ($gname =~ $exclude_rx)) {
             $entry->{excluded} = { 
                 pattern => $exclude_pattern, 
                 string => $1 # Captures the matched substring for reference
             };
             warn "Info: Persistently excluding group '$gname' due to pattern '$exclude_pattern'." if defined $debug;
        }

        push @results, $entry;
    }

    # 3. Write the updated list back to the JSON cache file
    write_groups_to_file(\@results);

    return \@results;
}

## Check the dynamic posting status of a single group via API (REAL-TIME CHECK)
sub check_posting_status {
    my ($group_id, $group_name) = @_;
    
    # Use the robust wrapper inside an eval block to fetch the latest throttle status
    my $response = eval { flickr_api_call('flickr.groups.getInfo', { group_id => $group_id }) };
    
    # Check for API failure
    if ($@) {
        warn "Warning: Failed to fetch dynamic posting status for group '$group_name'. API died after retries: $@. Returning safe failure status.";
        # Return a safe failure status: cannot post, unknown limit, 0 remaining
        return { 
            can_post => 0, 
            limit_mode => 'unknown_error',
            remaining => 0,
        };
    }
    
    # Process the dynamic status
    my $data = $response->as_hash->{group};
    my $throttle = $data->{throttle} || {};
    my $limit_mode = $throttle->{mode} // 'none';
    my $remaining = $throttle->{remaining} // 0;
    
    # The group can be posted to if limit_mode is 'none' or remaining posts > 0
    my $can_post_current = ($limit_mode eq 'none') || ($remaining > 0);
    
    warn "Debug: Group '$group_name' status: mode=$limit_mode, rem=$remaining. Can Post: " . ($can_post_current ? 'TRUE' : 'FALSE') . "." if defined $debug;
    
    return { 
        can_post => $can_post_current, 
        limit_mode => $limit_mode,
        remaining => $remaining + 0,
    };
}

## Find a random, eligible photo from the matching sets
sub find_random_photo {
    my ($sets_ref) = @_;
    
    my $PHOTOS_PER_PAGE = 250;
    
    my @sets_to_try = @$sets_ref;
    
    # OUTER LOOP: Iterate through sets randomly until a suitable photo is found
    while (@sets_to_try) {
        
        my $set_index = int(rand(@sets_to_try));
        my $selected_set = $sets_to_try[$set_index];
        my $set_id = $selected_set->{id};
        my $total = $selected_set->{photos};

        # Remove this set from the pool to avoid re-selecting it in this cycle
        splice(@sets_to_try, $set_index, 1);
        next if $total == 0;
        
        my $max_page = int(($total - 1) / $PHOTOS_PER_PAGE) + 1;
        my @pages_to_try = (1..$max_page);

        # MIDDLE LOOP: Retry pages within the current set
        while (@pages_to_try) {
            
            my $page_index = int(rand(@pages_to_try));
            my $random_page = $pages_to_try[$page_index];
            
            # Remove this page from the pool
            splice(@pages_to_try, $page_index, 1);

            # Get the photos on that random page 
            my $get_photos_params = {
                photoset_id => $set_id,
                per_page => $PHOTOS_PER_PAGE,
                page => $random_page,
                privacy_filter => 1, # Only get public photos
                extras => 'date_taken',
            };

            # API call to get photos for a page
            my $response = eval { flickr_api_call('flickr.photosets.getPhotos', $get_photos_params) }; 

            if ($@) {
                warn "Warning: Failed to fetch photos from set '$selected_set->{title}' ($set_id). API died: $@. Skipping to next set.";
                last; # Exit the current page loop (MIDDLE LOOP) to try the next set (OUTER LOOP)
            }
            
            my $photos_on_page = $response->as_hash->{photoset}->{photo} || [];
            $photos_on_page = [ $photos_on_page ] unless ref $photos_on_page eq 'ARRAY';
            
            unless (@$photos_on_page) {
                warn "Warning: Page $random_page returned no public photos." if defined $debug;
                next; # Try another page
            }

            # 3. INNER LOOP: Retry photos on the current page
            my @photo_indices_to_try = (0..$#{$photos_on_page});
            
            while (@photo_indices_to_try) {
                
                my $index_to_try = int(rand(@photo_indices_to_try));
                my $random_photo_index = $photo_indices_to_try[$index_to_try];
                my $selected_photo = $photos_on_page->[$random_photo_index];
                
                # Remove this photo from the pool
                splice(@photo_indices_to_try, $index_to_try, 1);
                
                # --- Age Check ---
                if (defined $max_age_timestamp && $selected_photo->{datetaken}) {
                    my $date_taken = $selected_photo->{datetaken};
                    my $photo_timestamp;
                    
                    # Attempt to parse date in YYYY-MM-DD HH:MM:SS format
                    if ($date_taken =~ /^(\d{4})-(\d{2})-(\d{2})\s+(\d{2}):(\d{2}):(\d{2})$/) {
                        my ($year, $month, $day, $hour, $min, $sec) = ($1, $2, $3, $4, $5, $6);
                        $photo_timestamp = Time::Local::timelocal($sec, $min, $hour, $day, $month-1, $year-1900);
                    } 
                    # Attempt to parse date in YYYY-MM-DD format
                    elsif ($date_taken =~ /^(\d{4})-(\d{2})-(\d{2})$/) {
                        my ($year, $month, $day) = ($1, $2, $3);
                        $photo_timestamp = Time::Local::timelocal(0, 0, 0, $day, $month-1, $year-1900);
                    }

                    # Compare the photo's timestamp to the maximum allowed age
                    if (defined $photo_timestamp && $photo_timestamp < $max_age_timestamp) {
                        warn "Debug: Photo '$selected_photo->{title}' ($selected_photo->{id}) is too old. Retrying photo." if defined $debug;
                        next;
                    }
                }

                # --- Photo is Valid and Not Too Old ---
                return {
                    id => $selected_photo->{id},
                    title => $selected_photo->{title} // 'Untitled Photo',
                    set_title => $selected_set->{title} // 'Untitled Set',
                    set_id => $set_id,
                };
            }
        }
    }
    warn "Warning: Exhausted all matching sets, pages, and photos. No photos found that meet the maximum age requirement." if defined $debug;
    return;
}

## Check if a specific photo is present in a group's pool using its context information
sub is_photo_in_group {
    my ($photo_id, $group_id) = @_;
    
    # Fetch all groups (pools) the photo has been added to
    my $response = eval { flickr_api_call('flickr.photos.getAllContexts', { photo_id => $photo_id }) };
    
    # Check for API failure
    if ($@) {
        warn "Warning: Failed to check photo context for photo $photo_id. API died after retries: $@. Returning undef to signal temporary failure.";
        return undef; # Return undef on fatal API error (allows main loop to skip attempt)
    }
    
    my $photo_pools = $response->as_hash->{pool} || [];
    $photo_pools = [ $photo_pools ] unless ref $photo_pools eq 'ARRAY';
    
    # Check if any pool ID matches the target group ID
    my $is_present = grep { $_->{id} eq $group_id } @$photo_pools;
    return $is_present; 
}

## Generate a formatted report of group statuses based on cached data
sub list_groups_report {
    my ($groups_ref, $group_match_rx, $exclude_match_rx) = @_;

    print "\n### Group Status Report (Data from $groups_file)";
    print "Refresh Timestamp: " . scalar(localtime($groups_ref->[0]->{timestamp})) if @$groups_ref;
    print "---";

    # Get the list of groups currently eligible based on all filters
    my @eligible = @{ filter_eligible_groups($groups_ref, $group_match_rx, $exclude_match_rx) };
    my %eligible_map = map { $_->{id} => 1 } @eligible;
    
    printf "%-40s | %-12s | %-12s | %-8s | %s\n", 
        "**Group Name**", "**Can Post**", "**Limit Mode**", "**Remain**", "**Exclusion/Filter Status**";
    print "-" x 96;

    # Iterate through all known groups, sorted by name
    foreach my $g (sort { $a->{name} cmp $b->{name} } @$groups_ref) {
        my $status;

        # Determine the reason for eligibility or ineligibility
        if (exists $eligible_map{$g->{id}}) {
            $status = "ELIGIBLE";
        } elsif (!defined $g->{can_post} || $g->{can_post} == 0) {
            $status = "STATICALLY BLOCKED (photos_ok=0)";
        } elsif (defined $g->{excluded}) {
            $status = "PERSISTENTLY EXCLUDED (Pattern: $g->{excluded}->{pattern})";
        } elsif (defined $group_match_rx && $g->{name} !~ $group_match_rx) {
            $status = "MISSED -g MATCH";
        } elsif (defined $exclude_match_rx && $g->{name} =~ $exclude_match_rx) {
            $status = "MATCHED -e EXCLUDE";
        } else {
            $status = "NOT ELIGIBLE (Unknown Reason)";
        }

        # Print the formatted line
        printf "%-40s | %-12s | %-12s | %-8s | %s\n",
            $g->{name},
            $g->{can_post} ? "Yes" : "No",
            $g->{limit_mode} || 'none',
            $g->{remaining} || '-',
            $status;
    }
}


# --- Main Logic Execution ---

# 0. Setup and Validation
if ($help || !$groups_file || !$history_file || (!$list_groups && !$set_pattern)) {
    show_usage();
    exit;
}

init_flickr();

# Compile regex patterns from command line arguments
my $group_match_rx = qr/$group_pattern/si if defined $group_pattern;
my $exclude_match_rx = qr/$exclude_pattern/si if defined $exclude_pattern;

# A. Load History for dynamic cooldowns
load_history();

# 1. Load or Fetch Groups (Cached vs. Live Update)
my $groups_list_ref;

# Force refresh if flags related to persistent exclusions are used
if ($clean_excludes || $persistent_exclude) {
    warn "Info: Flags -c or -p detected. Forcing group list refresh and write back." if defined $debug;
    $groups_list_ref = update_and_store_groups();
} else {
    my $needs_update = !-e $groups_file;
    if (-e $groups_file) {
        my $temp_groups = load_groups();
        # Check if cache is older than the update interval
        if ($temp_groups && @$temp_groups && time() - $temp_groups->[0]->{timestamp} > GROUP_UPDATE_INTERVAL) {
            $needs_update = 1;
        }
        $groups_list_ref = $temp_groups;
    }
    
    # Fetch live data if cache is missing or stale
    if ($needs_update) {
        $groups_list_ref = update_and_store_groups();
    } elsif (!$groups_list_ref) {
        # Fallback if loading failed but no update was strictly needed
        $groups_list_ref = update_and_store_groups();
    }

    die "Could not load or fetch group list." unless defined $groups_list_ref and @$groups_list_ref;
}

# --- List-Groups execution path ---
if ($list_groups) {
    list_groups_report($groups_list_ref, $group_match_rx, $exclude_match_rx);
    exit;
}
# --- End of List-Groups execution path ---


# 2. Initial Filter (Applies static eligibility and persistent/CLI filters)
my @all_eligible_groups = @{ filter_eligible_groups($groups_list_ref, $group_match_rx, $exclude_match_rx) };

die "No groups match all required filters." unless @all_eligible_groups;
warn "Info: Found " . scalar(@all_eligible_groups) . " groups eligible for posting after initial filter." if defined $debug;

# 3. Get Photosets
my $response = flickr_api_call('flickr.photosets.getList', { user_id => $user_nsid }); 
my $all_sets = $response->as_hash->{photosets}->{photoset} || [];
$all_sets = [ $all_sets ] unless ref $all_sets eq 'ARRAY';
# Filter sets based on the user-provided pattern
my @matching_sets = grep { ($_->{title} || '') =~ qr/$set_pattern/i } @$all_sets;

die "No sets matching pattern '$set_pattern' found." unless @matching_sets;
warn "Info: Found " . scalar(@matching_sets) . " matching sets." if defined $debug;

# 4. Main Continuous Posting Loop (The core script functionality)
my $post_count = 0;
my $max_tries = 20;
my $moderated_wait_time = MODERATED_POST_TIMEOUT;

while (1) {
    # A. Reset the current pool of groups for this cycle (groups that passed all static filters)
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

        # 1. Select a random group from the current pool
        my $random_index = int(rand(@current_groups));
        my $selected_group = $current_groups[$random_index];
        my $group_id = $selected_group->{id};
        my $group_name = $selected_group->{name};
        
        warn "Debug: Selected random group: $group_name ($group_id)" if defined $debug;

        # --- DYNAMIC CHECK 1: Rate Limit Cooldown Check (Internal History) ---
        my $history_changed = 0;

        if (defined $rate_limit_history{$group_id}) {
            my $wait_until = $rate_limit_history{$group_id}->{wait_until};
            if (time() < $wait_until) { 
                warn "Debug: Rate-limited group '$group_name' in internal cooldown. Skipping." if defined $debug; 
                splice(@current_groups, $random_index, 1); 
                next; 
            } else { 
                warn "Info: Rate-limit cooldown for '$group_name' expired. Clearing history." if defined $debug; 
                delete $rate_limit_history{$group_id};
                $history_changed = 1; 
            }
        }

        # --- DYNAMIC CHECK 2: Moderated Group Cooldown Check (Internal History) ---
        if ($selected_group->{moderated} == 1 and defined $moderated_post_history{$group_id}) {
            my $history = $moderated_post_history{$group_id};
            my $wait_until = $history->{post_time} + $moderated_wait_time;

            # Check photo status in group pool (is_photo_in_group returns 1, 0, or undef on API failure)
            my $context_check = is_photo_in_group($history->{photo_id}, $group_id);

            if (not defined $context_check) { 
                # API failure, skip attempt, preserve history
                warn "Warning: API failure during context check for $group_name. Trying next group/photo." if defined $debug;
                next; 
            } elsif ($context_check) {  
                # Photo IS present (1): Moderation complete and accepted. Clear history.
                warn "Info: Moderated group '$group_name' photo accepted. Cooldown cleared." if defined $debug; 
                delete $moderated_post_history{$group_id};
                $history_changed = 1; 
            } elsif (time() < $wait_until) {  
                # Photo NOT present (0) AND still in cooldown period: Still waiting for moderation.
                warn "Debug: Moderated group '$group_name' in queue cooldown. Skipping." if defined $debug; 
                splice(@current_groups, $random_index, 1); 
                next; 
            } else {  
                # Photo NOT present (0) AND cooldown period expired: Timeout expired, assume rejection/removal.
                warn "Info: Moderated group '$group_name' post queue timeout expired. Re-checking status." if defined $debug; 
                delete $moderated_post_history{$group_id};
                $history_changed = 1; 
            }
        }
        
        # Persist history changes if any cooldown was cleared
        write_history_to_file(\%moderated_post_history, \%rate_limit_history) if $history_changed;

        # --- DYNAMIC CHECK 3: API Status (Remaining Posts Check) ---
        # Only run this expensive check for groups with known limits or moderation
        if ($selected_group->{limit_mode} ne 'none' || $selected_group->{moderated} == 1) {
            my $status = check_posting_status($group_id, $group_name);
            
            # Update local cache with the real-time status
            $selected_group->{limit_mode} = $status->{limit_mode};
            $selected_group->{remaining} = $status->{remaining};
            
            unless ($status->{can_post}) {
                warn "Debug: Group '$group_name' failed dynamic API check (no remaining posts or API error). Skipping." if defined $debug;
                splice(@current_groups, $random_index, 1);
                next;
            }
        }

        # 2. Check last poster - Get the most recent photo in the pool
        my $response = eval { flickr_api_call('flickr.groups.pools.getPhotos', { group_id => $group_id, per_page => 1 }) };
        
        if ($@) {
            warn "Warning: Failed to check last poster for group '$group_name' ($group_id). API died: $@. Skipping to next group attempt.";
            splice(@current_groups, $random_index, 1); # Remove this group from the current attempt pool
            next; 
        }
        
        my $photos = $response->as_hash->{photos}->{photo} || [];
        $photos = [ $photos ] unless ref $photos eq 'ARRAY';
        
        # Skip if the last post was by the current user
        if (@$photos and $photos->[0]->{owner} eq $user_nsid) {
            warn "Debug: Last photo in group $group_id is from current user, skipping this group." if defined $debug;
            splice(@current_groups, $random_index, 1);
            next;
        }

        # 3. Select Photo, Check Age, Check Context
        my $photo_data = find_random_photo(\@matching_sets);
        # If no photo found (e.g., all too old, or no public photos) break this loop and try a full cycle reset
        next unless $photo_data and $photo_data->{id}; 
        
        my ($photo_id, $photo_title, $set_title, $set_id) = @$photo_data{qw/id title set_title set_id/};
        
        # Final check: is the photo already in the group?
        my $in_group_check = is_photo_in_group($photo_id, $group_id);
        if (not defined $in_group_check) {
            warn "Warning: API failure during final photo context check. Skipping attempt." if defined $debug;
            next;
        } elsif ($in_group_check) {
            warn "Debug: Photo '$photo_title' ($photo_id) already in group '$group_name', trying another." if defined $debug;
            next;
        }
        
        # 4. Post the photo!
        if ($dry_run) {
            print "DRY RUN: Would add photo '$photo_title' ($photo_id) from set '$set_title' to group '$group_name' ($group_id)";
        } else {
            # Attempt to add the photo to the group pool
            my $response = eval { flickr_api_call('flickr.groups.pools.add', { photo_id => $photo_id, group_id => $group_id }) };
            
            # Check for failure: $@ is set if flickr_api_call died after max retries
            # The check is correctly simplified to 'if ($@)' as discussed.
            if ($@) {
                print "FATAL ERROR: Could not add photo '$photo_title' ($photo_id) to group '$group_name' ($group_id) after max retries: $@";
            } else {
                print "SUCCESS: Added photo '$photo_title' ($photo_id) to group '$group_name' ($group_id)";
                
                # Apply Cooldowns if the post was successful
                my $cooldown_applied = 0;
                
                # Cooldown for moderated groups (wait for moderation status check)
                if ($selected_group->{moderated} == 1) {
                    $moderated_post_history{$group_id} = { 
                        post_time => time(), 
                        photo_id  => $photo_id, 
                    };
                    warn "Info: Moderated post successful. Group '$group_name' set to $moderated_wait_time second cooldown." if defined $debug;
                    $cooldown_applied = 1;
                }

                # Cooldown for rate-limited groups (apply a dynamic pause)
                if ($selected_group->{limit_mode} eq 'day' || $selected_group->{limit_mode} eq 'week' || $selected_group->{limit_mode} eq 'month') {
                    my $limit = $selected_group->{limit_count} || 1; 
                    my $period_seconds = $selected_group->{limit_mode} eq 'day'   ? SECONDS_IN_DAY   : 
                                         $selected_group->{limit_mode} eq 'week'  ? SECONDS_IN_WEEK  : 
                                         $selected_group->{limit_mode} eq 'month' ? SECONDS_IN_MONTH : 0;

                    if ($limit > 0 && $period_seconds > 0) {
                        # Calculate an average pause time and randomize it slightly (70% to 130% of average)
                        my $base_pause_time = $period_seconds / $limit;
                        my $random_multiplier = 0.7 + rand(0.6); 
                        my $pause_time = int($base_pause_time * $random_multiplier);
                        $pause_time = 1 unless $pause_time > 0;
                        my $wait_until = time() + $pause_time;
                        
                        $rate_limit_history{$group_id} = { 
                            wait_until => $wait_until, 
                            limit_mode => $selected_group->{limit_mode}, 
                        };
                        warn "Info: Group '$group_name' posted to (limit $limit/$selected_group->{limit_mode}). Applying randomized $pause_time sec cooldown." if defined $debug;
                        $cooldown_applied = 1;
                    }
                }
                
                # *** PERSIST HISTORY ***
                write_history_to_file(\%moderated_post_history, \%rate_limit_history) if $cooldown_applied;
            }
        }
        
        $post_count++;
        last; # Exit the inner loop on a successful post (real or dry-run)
    }

    # C. Pause and Check for Daily Update
    my $sleep_time = int(rand($timeout_max + 1));
    print "Pausing for $sleep_time seconds before next attempt.";
    sleep $sleep_time;
    
    # Check if the cached group list is stale and needs a refresh
    if (time() - $groups_list_ref->[0]->{timestamp} > GROUP_UPDATE_INTERVAL) {
        warn "Info: Group list cache expired. Initiating update." if defined $debug;
        
        $groups_list_ref = update_and_store_groups();
        
        # Re-filter the master group list after the refresh
        @all_eligible_groups = @{ filter_eligible_groups($groups_list_ref, $group_match_rx, $exclude_match_rx) };
        
        warn "Info: Master group list refreshed and re-filtered. Found " . scalar(@all_eligible_groups) . " eligible groups." if defined $debug;
    }
}

print "Posting loop finished! Total posts made/simulated: $post_count";