#!/usr/bin/perl
# add2groups.pl
#
# DESCRIPTION:
# This script automates the process of posting photos from specific Flickr sets 
# (matched by a regex pattern) to eligible Flickr groups, managing group limits, 
# cooldowns, and moderated status for robust, continuous operation.
#
# KEY RELIABILITY FEATURES:
# - **MASTER RESTART LOOP:** Uses an eval/while loop with exponential backoff for complete self-healing 
#   against fatal errors (network failures, unhandled exceptions). Runs infinitely until external interruption.
# - **Robust API Wrapper:** `flickr_api_call` includes retry logic and exponential backoff for transient network issues.
# - **File Locking (flock):** Guarantees file integrity for history and cache files during read/write operations.
# - **Dynamic Cooldowns:** Tracks history for rate-limited groups and moderated groups to prevent spamming.
#
# USAGE:
# perl add2groups.pl -f groups.json -H history.json -s "Set Title Pattern" -a 2
#
# REQUIREMENTS:
# - Perl environment with modules: Flickr::API, Data::Dumper, JSON, Time::Local, Time::HiRes, Fcntl.
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
use Fcntl qw(:flock); # Required for file locking constants

# Set output record separator to always print a newline
$\ = "\n";

# --- BUFFERING FIX ---
# Disable output buffering on STDOUT and STDERR for immediate logging.
$| = 1;
select(STDERR); $| = 1; select(STDOUT);

# Global API and User Variables
my $flickr;                # Flickr::API object instance for all calls
my $user_nsid;             # Current authenticated user's Flickr NSID
my $debug;                 # Debug level (0: off, 1: info, 2: call/response, 3+: Dumper output)
my $max_age_timestamp;     # Unix timestamp for the oldest photo date allowed
my @all_eligible_groups;   # Stores groups passing static filters
my @matching_sets;         # Stores photosets matching the user-defined pattern


# --- Command-line options and defaults ---
my ($help, $dry_run, $groups_file, $set_pattern, $group_pattern, $exclude_pattern, $max_age_years, $timeout_max);
my ($persistent_exclude, $clean_excludes, $ignore_excludes, $list_groups, $history_file);

# Default maximum random pause between successful posts
$timeout_max = 300;

# Global history hashes for internal cooldowns, loaded/saved from history_file
my %moderated_post_history; # Tracks posts to moderated groups waiting for acceptance
my %rate_limit_history;     # Tracks groups placed on dynamic cooldown based on limits or temporary API errors

# Process command-line options
GetOptions(
    'h|help'              => \$help,
    'n|dry-run'           => \$dry_run,
    'd|debug:i'           => \$debug,
    'f|groups-file=s'     => \$groups_file,
    'H|history-file=s'    => \$history_file,
    's|set-pattern=s'     => \$set_pattern,
    'g|group-pattern=s'   => \$group_pattern,
    'e|exclude=s'         => \$exclude_pattern,
    'a|max-age=i'         => \$max_age_years,
    't|timeout:i'         => \$timeout_max,
    'p|persistent'        => \$persistent_exclude,
    'c|clean'             => \$clean_excludes,
    'i|ignore-excludes'   => \$ignore_excludes,
    'l|list-groups'       => \$list_groups,
);

# --- Constants ---
use constant GROUP_UPDATE_INTERVAL  => 24 * 60 * 60;  # Time until group cache is considered stale
use constant GROUP_EXHAUSTED_DELAY  => 60 * 60;   # 1 hour wait when no eligible groups remain
use constant MODERATED_POST_TIMEOUT => 24 * 60 * 60;  # Cooldown period for a moderated group post
use constant SECONDS_IN_DAY   => 24 * 60 * 60;
use constant SECONDS_IN_WEEK  => 7 * SECONDS_IN_DAY;
use constant SECONDS_IN_MONTH => 30 * SECONDS_IN_DAY;

# API Retry Constants
use constant MAX_API_RETRIES      => 5;   # Max attempts for transient Flickr API errors
use constant API_RETRY_MULTIPLIER => 8;   # Exponential backoff factor (e.g., 1, 8, 64, ...)

# Master Restart Constants
use constant MAX_RESTART_DELAY    => 24 * 60 * 60; # Maximum restart delay for fatal script errors
use constant RESTART_RETRY_BASE   => 60;           # Base delay in seconds (1 minute) for the first retry
use constant RESTART_RETRY_FACTOR => 2;            # Exponential factor for increasing restart delays
use constant MAX_TRIES => 20;                      # Max attempts to find a valid photo/group combination per cycle

# --- Helper Subroutines ---

# Debug printing utility, outputting Data::Dumper dump for high debug levels
sub debug_print {
    return unless defined $debug;
    my ($message, $data) = @_;
    warn "Debug: $message" . (defined $data && $debug > 2 ? Dumper($data) : '');
}

# Robust Flickr API call wrapper with exponential backoff and retry logic.
# Handles transient errors, but returns failure for non-retryable errors (e.g., photo limit reached).
# RETURNS: Response object on success/non-fatal failure, or undef on fatal, unrecoverable API failure.
sub flickr_api_call {
    my ($method, $args) = @_;
    my $retry_delay = 1;

    warn "Debug: API CALL: $method" if defined $debug and $debug > 0;

    # Use constant MAX_API_RETRIES directly in the loop condition
    for my $attempt (1 .. MAX_API_RETRIES) { # Single loop, no label needed
        my $response = eval { $flickr->execute_method($method, $args) };

        # Check for Perl exception ($@), undef response, or API failure
        if ($@ || !defined $response || !$response->{success}) {
            
            # Prioritize API error message over Perl exception
            my $error = $response->{error_message} || $@ || 'Unknown error';
            warn "Attempt $attempt failed for $method: $error";

            # Treat "Pending Queue" message as successful for moderated groups (non-retryable success)
            if ($method eq 'flickr.groups.pools.add' and $error =~ /Pending Queue for this Pool/i) {
                warn "Debug: Moderated Group Success Detected: $error. Treating as successful and non-retryable." if defined $debug;
                return $response; 
            }

            # Check for non-retryable, permanent errors specific to 'add' method.
            if ($method eq 'flickr.groups.pools.add' and $error =~ /Photo limit reached/i) {
                warn "Warning: Non-retryable Error detected for $method: $error. Aborting retries.";
                return $response; # Return failure response object for handling
            }

            # If max retries reached, fail fatally for the script (return undef)
            if ($attempt == MAX_API_RETRIES) {
                # Use constant directly in the warning message
                warn "FATAL: Failed to execute $method after " . MAX_API_RETRIES . " attempts: $error";
                return undef; 
            }
            sleep $retry_delay;
            $retry_delay *= API_RETRY_MULTIPLIER;  # Exponential backoff
            next; # Continue to next retry attempt (no label, non-nested loop)
        }
        return $response; # API call was successful
    }
    return undef; 
}

# --- File I/O Utility Subroutines (Non-Fatal & Safe) ---

# General utility to write content to a file with an exclusive lock (LOCK_EX)
sub _write_file {
    my ($file_path, $content) = @_;
    my $fh; 

    unless (open $fh, '>:encoding(UTF-8)', $file_path) {
        warn "Warning: Cannot open $file_path for writing: $!";
        return undef;
    }

    # Acquire an exclusive lock (blocks other processes)
    unless (flock($fh, LOCK_EX)) {
        warn "Warning: Failed to acquire exclusive lock on $file_path. Skipping write.";
        close $fh;
        return undef;
    }

    eval {
        print $fh $content;
    };
    
    flock($fh, LOCK_UN); # Release the lock
    close $fh;

    if ($@) {
        warn "Warning: Error during writing to $file_path: $@";
        return undef;
    }
    
    return 1;
}

# General utility to read content from a file with a shared lock (LOCK_SH)
sub _read_file {
    my $file_path = shift;
    my $fh; 

    return undef unless -e $file_path;
    warn "Debug: Accessing file $file_path" if defined $debug;

    unless (open $fh, '<:encoding(UTF-8)', $file_path) {
        warn "Warning: Cannot open $file_path for reading: $!";
        return undef;
    }

    # Acquire a shared lock (allows other readers)
    unless (flock($fh, LOCK_SH)) {
        warn "Warning: Failed to acquire shared lock on $file_path. Skipping read." if defined $debug;
        close $fh;
        return undef;
    }

    # Slurp the entire file content
    my $content = eval { local $/; <$fh> };

    flock($fh, LOCK_UN); # Release the lock
    close $fh;

    if ($@) {
        warn "Warning: Error reading $file_path: $@";
        return undef; 
    }
    
    return $content;
}

# --- High-Level File I/O Subroutines ---

# Serializes the groups array reference to JSON and saves it to the groups file.
sub save_groups {
    my $groups_ref = shift;
    my $json = JSON->new->utf8->pretty->encode({ groups => $groups_ref });
    unless (_write_file($groups_file, $json)) {
        warn "Warning: Failed to save group data to $groups_file. Current group state is not persisted.";
        return 0;
    }
    warn "Info: Group list cache written to $groups_file" if defined $debug;
    return 1;
}

# Loads and decodes groups data from the JSON cache file.
# RETURNS: Array reference of cached groups or undef on failure/file absence.
sub load_groups {
    warn "Debug: Loading groups from $groups_file" if defined $debug;
    my $json_text = _read_file($groups_file) or return undef;
    my $data = eval { decode_json($json_text) };
    if ($@) {
           warn "Error decoding JSON from $groups_file: $@. Cannot load cached data." if defined $debug;
           return undef;
    }
    return $data->{groups} // [];
}

# Saves the current state of dynamic cooldown history hashes to the history file.
sub save_history {
    my $data_to_write = {
        moderated => \%moderated_post_history,
        ratelimit => \%rate_limit_history,
        timestamp => time(),
    };
    my $json = JSON->new->utf8->pretty->encode($data_to_write);
    unless (_write_file($history_file, $json)) {
        warn "Warning: Failed to save history data to $history_file. Cooldown state is not persisted.";
        return 0;
    }
    warn "Info: Cooldown history written to $history_file" if defined $debug;
    return 1;
}

# Loads cooldown history from the JSON file into global hashes.
sub load_history {
    warn "Debug: Loading history from $history_file" if defined $debug;
    my $json_text = _read_file($history_file) or return;
    my $data = eval { decode_json($json_text) };
    if ($@) {
           warn "Error decoding JSON from $history_file: $@. Cannot load history data." if defined $debug;
           return;
    }
    %moderated_post_history = %{$data->{moderated} // {}};
    %rate_limit_history     = %{$data->{ratelimit} // {}};
    warn "Debug: History loaded. Moderated count: " . scalar(keys %moderated_post_history) . ", Rate limit count: " . scalar(keys %rate_limit_history) if defined $debug;
}

# --- Main Logic Subroutines ---

# Display comprehensive usage information
sub show_usage {
    print "Usage: $0 [OPTIONS]";
    print "Options:";
    printf "  %-20s %s\n", "-h, --help", "Show help message and exit";
    printf "  %-20s %s\n", "-n, --dry-run", "Simulate adding without making changes (highly recommended for testing)";
    printf "  %-20s %s\n", "-d, --debug", "Set debug level. Prints verbose execution info (0-3)";
    printf "  %-20s %s\n", "-f, --groups-file", "Path to store/read group JSON data (required for cache)";
    printf "  %-20s %s\n", "-H, --history-file", "Path to store/read dynamic cooldown history (required)";
    printf "  %-20s %s\n", "-s, --set-pattern", "Regex pattern to match set titles (required, unless -l is used)";
    printf "  %-20s %s\n", "-g, --group-pattern", "Regex pattern to match target group names (optional filter)";
    printf "  %-20s %s\n", "-e, --exclude", "Negative regex pattern to exclude group names (optional filter)";
    printf "  %-20s %s\n", "-p, --persistent", "If -e matches, permanently mark group as excluded in JSON cache";
    printf "  %-20s %s\n", "-c, --clean", "Clean (remove) all existing persistent excludes from JSON data";
    printf "  %-20s %s\n", "-i, --ignore-excludes", "Temporarily ignore groups marked as excluded in JSON cache";
    printf "  %-20s %s\n", "-l, --list-groups", "List all groups from the cache and exit (forces refresh if cache is old)";
    printf "  %-20s %s\n", "-a, --max-age", "Maximal age of photos in years (optional, filters old photos)";
    printf "  %-20s %s\n", "-t, --timeout <sec>", "Maximum random delay between posts (default: $timeout_max sec)";
    print "\nNOTE: Requires authentication tokens in '\$ENV{HOME}/saved-flickr.st'";
}

# Initializes the Flickr API connection and authenticates the user.
sub init_flickr {
    if (defined $max_age_years) {
        $max_age_timestamp = time() - ($max_age_years * 365 * 24 * 60 * 60);
    }
    my $config_file = "$ENV{HOME}/saved-flickr.st";
    $flickr = Flickr::API->import_storable_config($config_file);
    
    my $response = flickr_api_call('flickr.test.login', {}); 
    
    # Check for fatal API error after retries
    unless (defined $response) {
        # This is a master failure, caught by the master RESTART_LOOP
        die "FATAL: Initial Flickr connection (flickr.test.login) failed after retries.";
    }
    
    # Extract the user NSID for subsequent calls
    $user_nsid = $response->as_hash->{user}->{id};
    warn "Debug: Logged in as $user_nsid" if defined $debug;
    return 1;
}

# Filters the master list of groups based on static API permission and user-defined patterns.
# Note: Dynamic limits (throttles/cooldowns) are checked later.
sub filter_eligible_groups {
    my ($groups_ref, $group_match_rx, $exclude_match_rx) = @_;
    return [ grep {
        my $g = $_;
        my $gname = $g->{name} || '';
        # 1. Must have static permission to post photos
        $g->{can_post} == 1 &&
        # 2. Must not be persistently excluded (unless --ignore-excludes is set)
        ( $ignore_excludes || !defined $g->{excluded} ) &&
        # 3. Must match the user's positive pattern (-g)
        ( !defined $group_match_rx || $gname =~ $group_match_rx ) &&
        # 4. Must NOT match the user's negative pattern (-e)
        ( !defined $exclude_match_rx || $gname !~ $exclude_match_rx )
    } @$groups_ref ];
}

# Fetches the latest group membership data from Flickr, combines it with detailed group info,
# applies persistent exclusion logic, and updates the local JSON cache file.
sub update_and_store_groups {
    my $old_groups_ref = shift;
    $old_groups_ref = load_groups() // [] unless 'ARRAY' eq ref $old_groups_ref;
    warn "Info: Refreshing group list from Flickr API..." if defined $debug;
    
    # 1. Get list of all groups the user is a member of
    my $response = flickr_api_call('flickr.groups.pools.getGroups', {});
    unless (defined $response) {
        warn "Warning: Failed to fetch complete group list from Flickr API. Returning existing cached list.";
        return $old_groups_ref; 
    }
    
    my $new_groups_raw = $response->as_hash->{groups}->{group} || [];
    $new_groups_raw = [ $new_groups_raw ] unless ref $new_groups_raw eq 'ARRAY';
    my %old_groups_map = map { $_->{id} => $_ } @$old_groups_ref;
    my @results;
    my $timestamp_epoch = time();
    my $exclude_rx = qr/($exclude_pattern)/si if defined $exclude_pattern;
    
    # 2. Iterate through each group to get detailed info and restrictions
    foreach my $g_raw (@$new_groups_raw) { # Single loop, no label needed
        my $gid   = $g_raw->{nsid};
        my $gname = $g_raw->{name};
        my $g_old = $old_groups_map{$gid};
        
        my $response = flickr_api_call('flickr.groups.getInfo', { group_id => $gid });
        unless (defined $response) {
            warn "Warning: Failed to fetch info for group '$gname' ($gid). API failed after retries. Skipping this group.";
            next; # No label, non-nested loop
        }
        
        my $data = $response->as_hash->{group};
        my $throttle = $data->{throttle} || {};
        
        # Determine if the group requires moderation (post is queued)
        my $is_pool_moderated = 0 | $data->{ispoolmoderated} // 0;
        my $is_moderate_ok    = 0 | $data->{restrictions}->{moderate_ok} // 0;
        my $is_group_moderated = $is_pool_moderated || $is_moderate_ok;

        # Determine static posting permission
        my $photos_ok = 0 | $data->{restrictions}->{photos_ok} // 1;
        my $limit_mode = $throttle->{mode} || 'none';
        my $remaining = $throttle->{remaining} // 0;
        my $can_post_static = $photos_ok && $limit_mode ne 'disabled';
        
        my $entry = {
            timestamp     => $timestamp_epoch,
            id            => $gid,
            name          => $gname,
            privacy       => { 1 => 'Private', 2 => 'Public (invite to join)', 3 => 'Public (open)', }->{$g_raw->{privacy} // 3} || "Unknown",
            photos_ok     => $photos_ok,
            moderated     => $is_group_moderated, 
            limit_mode    => $limit_mode,
            limit_count   => ($throttle->{count} // 0) + 0,
            remaining     => $remaining + 0,
            can_post      => $can_post_static ? 1 : 0,
            role          => $g_raw->{admin} ? "admin" : $g_raw->{moderator} ? "moderator" : "member",
        };
        
        # Preserve old exclusion status unless the user requests a clean
        $entry->{excluded} = $g_old->{excluded} if $g_old and $g_old->{excluded};
        delete $entry->{excluded} if $clean_excludes;

        # Apply new persistent exclusion if flag is set and pattern matches
        if ($persistent_exclude and defined $exclude_pattern and ($gname =~ $exclude_rx)) {
             $entry->{excluded} = { 
                 pattern => $exclude_pattern, 
                 string => $1
             };
        }
        push @results, $entry;
    }
    save_groups(\@results);
    return \@results;
}

# Checks the group's real-time posting throttle status (remaining posts).
sub check_posting_status {
    my ($group_id, $group_name) = @_;
    
    my $response = flickr_api_call('flickr.groups.getInfo', { group_id => $group_id });
    unless (defined $response) {
        warn "Warning: Failed to fetch dynamic posting status for group '$group_name'. API failed after retries. Returning safe failure status.";
        return { can_post => 0, limit_mode => 'unknown_error', remaining => 0 };
    }
    
    my $data = $response->as_hash->{group};
    my $throttle = $data->{throttle} || {};
    my $limit_mode = $throttle->{mode} // 'none';
    my $remaining = $throttle->{remaining} // 0;
    
    # Can post if mode is 'none' or if there are remaining posts
    my $can_post_current = ($limit_mode eq 'none') || ($remaining > 0);
    return { 
        can_post => $can_post_current, 
        limit_mode => $limit_mode,
        remaining => $remaining + 0,
    };
}

# Finds a random photo from matching photosets that meets the age requirement
# and is not already in the group (implicitly checked later).
# Uses a three-level nested loop structure for efficient random selection.
sub find_random_photo {
    my ($sets_ref) = @_;
    my $PHOTOS_PER_PAGE = 250;
    
    my %used_set_ids;
    my %used_pages_by_set;
    my @sets_to_try = @$sets_ref;
    
    # Outer Loop: Iterate over all matching sets
    SET_LOOP: while (@sets_to_try) {
        my $set_index = int(rand(@sets_to_try));
        my $selected_set = $sets_to_try[$set_index];
        my $set_id = $selected_set->{id};
        my $total = $selected_set->{photos};

        # Remove the selected set from the list to avoid immediate re-selection
        splice(@sets_to_try, $set_index, 1);
        $used_set_ids{$set_id} = 1;

        # Skip sets with no photos
        next SET_LOOP if $total == 0; 
        
        $used_pages_by_set{$set_id} = {} unless exists $used_pages_by_set{$set_id};
        my $max_page = int(($total - 1) / $PHOTOS_PER_PAGE) + 1;
        my @pages_to_try = (1..$max_page);

        # Middle Loop: Iterate over pages within the current set
        PAGE_LOOP: while (@pages_to_try) {
            my $page_index = int(rand(@pages_to_try));
            my $random_page = $pages_to_try[$page_index];
            
            # Remove selected page from list to avoid re-selection
            splice(@pages_to_try, $page_index, 1);
            $used_pages_by_set{$set_id}->{$random_page} = 1;

            my $get_photos_params = { 
                photoset_id => $set_id, 
                per_page => $PHOTOS_PER_PAGE, 
                page => $random_page,
                privacy_filter => 1, # Only select public photos
                extras => 'date_taken',
            };

            my $response = flickr_api_call('flickr.photosets.getPhotos', $get_photos_params); 

            unless (defined $response) { 
                warn "Warning: Failed to fetch photos from set '$selected_set->{title}' ($set_id). API failed after retries. Skipping to next set.";
                last PAGE_LOOP; # Explicitly break middle loop to continue outer SET_LOOP
            }
            
            my $photos_on_page = $response->as_hash->{photoset}->{photo} || [];
            $photos_on_page = [ $photos_on_page ] unless ref $photos_on_page eq 'ARRAY';
            
            unless (@$photos_on_page) { 
                warn "Debug: Page $random_page returned no public photos." if defined $debug; 
                next PAGE_LOOP; # Explicitly continue middle loop
            }

            my @photo_indices_to_try = (0..$#{$photos_on_page});
            
            # Inner Loop: Iterate over photos on the current page
            PHOTO_LOOP: while (@photo_indices_to_try) {
                my $index_to_try = int(rand(@photo_indices_to_try));
                my $random_photo_index = $photo_indices_to_try[$index_to_try];
                my $selected_photo = $photos_on_page->[$random_photo_index];
                
                splice(@photo_indices_to_try, $index_to_try, 1);
                
                # Check photo age requirement if max_age_years is set
                if (defined $max_age_timestamp && $selected_photo->{datetaken}) {
                    my $date_taken = $selected_photo->{datetaken};
                    my $photo_timestamp;
                    
                    # Attempt to parse Flickr date formats (YYYY-MM-DD HH:MM:SS or YYYY-MM-DD)
                    if ($date_taken =~ /^(\d{4})-(\d{2})-(\d{2})\s+(\d{2}):(\d{2}):(\d{2})$/) {
                        $photo_timestamp = Time::Local::timelocal($6, $5, $4, $3, $2-1, $1-1900);
                    } 
                    elsif ($date_taken =~ /^(\d{4})-(\d{2})-(\d{2})$/) {
                        $photo_timestamp = Time::Local::timelocal(0, 0, 0, $3, $2-1, $1-1900);
                    }

                    if (defined $photo_timestamp && $photo_timestamp < $max_age_timestamp) {
                        warn "Debug: Photo '$selected_photo->{title}' ($selected_photo->{id}) is too old. Retrying photo." if defined $debug;
                        next PHOTO_LOOP; # Explicitly continue inner loop
                    }
                }

                # Found a suitable photo that meets age and public status requirements
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

# Checks if a photo is already in the group by examining its contexts (where it has been posted).
# RETURNS: 1 if present, 0 if not present, undef if API call fails.
sub is_photo_in_group {
    my ($photo_id, $group_id) = @_;
    
    my $response = flickr_api_call('flickr.photos.getAllContexts', { photo_id => $photo_id });
    unless (defined $response) {
        warn "Warning: Failed to check photo context for photo $photo_id. API failed after retries. Returning undef to signal temporary failure.";
        return undef;
    }
    
    my $photo_pools = $response->as_hash->{pool} || [];
    $photo_pools = [ $photo_pools ] unless ref $photo_pools eq 'ARRAY';
    my $is_present = grep { $_->{id} eq $group_id } @$photo_pools;
    return $is_present; 
}

# Generates a formatted summary table of all groups and their eligibility status.
sub list_groups_report {
    my ($groups_ref, $group_match_rx, $exclude_match_rx) = @_;
    print "\n### Group Status Report (Data from $groups_file)";
    print "Refresh Timestamp: " . scalar(localtime($groups_ref->[0]->{timestamp})) if @$groups_ref;
    print "---";
    my @eligible = @{ filter_eligible_groups($groups_ref, $group_match_rx, $exclude_match_rx) };
    my %eligible_map = map { $_->{id} => 1 } @eligible;
    
    printf "%-40s | %-12s | %-12s | %-8s | %-12s | %s\n", 
        "**Group Name**", "**Can Post**", "**Limit Mode**", "**Remain**", "**Moderated**", "**Exclusion/Filter Status**";
    print "-" x 111;

    foreach my $g (sort { $a->{name} cmp $b->{name} } @$groups_ref) {
        my $status;
        if (exists $eligible_map{$g->{id}}) {
            $status = "ELIGIBLE";
        } elsif (!defined $g->{can_post} || $g->{can_post} == 0) {
            $status = "STATICALLY BLOCKED (photos_ok=0)";
        } elsif (defined $g->{excluded}) {
            $status = "PERSISTENTLY EXCLUDED";
        } elsif (defined $group_match_rx && $g->{name} !~ $group_match_rx) {
            $status = "MISSED -g MATCH";
        } elsif (defined $exclude_match_rx && $g->{name} =~ $exclude_match_rx) {
            $status = "MATCHED -e EXCLUDE";
        } else {
            $status = "NOT ELIGIBLE (Unknown Reason)";
        }
        
        printf "%-40s | %-12s | %-12s | %-12s | %-12s | %s\n",
            $g->{name},
            $g->{can_post} ? "Yes" : "No",
            $g->{limit_mode} || 'none',
            $g->{remaining} || '-',
            $g->{moderated} ? "Yes" : "No",
            $status;
    }
}


# --- Main Logic Execution ---

# 1. Initial setup and validation
if ($help || !$groups_file || !$history_file || (!$list_groups && !$set_pattern)) {
    show_usage();
    exit;
}

# Compile and validate user-provided regex patterns
my $group_match_rx = eval { qr/$group_pattern/i } if defined $group_pattern;
die "Invalid group pattern '$group_pattern': $@" if $@;
my $exclude_match_rx = eval { qr/$exclude_pattern/i } if defined $exclude_pattern;
die "Invalid exclude pattern '$exclude_pattern': $@" if $@;
eval { qr/$set_pattern/ };
die "Invalid set pattern '$set_pattern': $@" if $@;

my $force_refresh = $clean_excludes || $persistent_exclude;

# Handle list-groups mode (this is the only way the script exits intentionally)
if ($list_groups) {
    unless (init_flickr()) {
        die "FATAL: Initial Flickr connection failed. Cannot proceed.";
    }
    my $groups_list_ref = load_groups();
    # Refresh cache if forced or if cache is missing/empty
    $groups_list_ref = update_and_store_groups($groups_list_ref) if $force_refresh or !defined $groups_list_ref or !@$groups_list_ref;
    die "Cannot list groups: Could not load or fetch group list." unless defined $groups_list_ref and @$groups_list_ref;
    list_groups_report($groups_list_ref, $group_match_rx, $exclude_match_rx);
    exit;
}

# --- MASTER RESTART LOOP (Self-Healing Core) ---
# This loop handles all fatal script errors and restarts the entire process indefinitely.
my $restart_attempt = 0;

RESTART_LOOP: while (1) {
    $restart_attempt++;

    eval {
        warn "\n--- Starting main script execution attempt #$restart_attempt ---\n" if $restart_attempt > 1;
        
        # 2. Initialization and Group/Set Fetch
        unless (init_flickr()) {
            # This 'die' is caught by the master RESTART_LOOP
            die "FATAL: Initial Flickr connection (flickr.test.login) failed after retries.";
        }
        
        # Load cached groups and update from API if cache is empty
        my $groups_list_ref = load_groups();
        $groups_list_ref = update_and_store_groups($groups_list_ref) unless defined $groups_list_ref and @$groups_list_ref;

        # Apply static filtering (can_post, persistent excludes, user patterns)
        @all_eligible_groups = @{ filter_eligible_groups($groups_list_ref, $group_match_rx, $exclude_match_rx) };
        unless (@all_eligible_groups) {
            die "No groups match all required filters.";
        }
        warn "Info: Found " . scalar(@all_eligible_groups) . " groups eligible for posting after initial filter." if defined $debug;

        # Get photosets matching the pattern
        my $response = flickr_api_call('flickr.photosets.getList', { user_id => $user_nsid }); 
        unless (defined $response) {
            die "FATAL: Failed to fetch photoset list from API after retries.";
        }
        
        my $all_sets = $response->as_hash->{photosets}->{photoset} || [];
        $all_sets = [ $all_sets ] unless ref $all_sets eq 'ARRAY';
        @matching_sets = grep { ($_->{title} || '') =~ qr/$set_pattern/i } @$all_sets;

        unless (@matching_sets) {
            die "No sets matching pattern '$set_pattern' found.";
        }
        warn "Info: Found " . scalar(@matching_sets) . " matching sets." if defined $debug;
        
        # Load dynamic cooldown history
        load_history();

        # 3. Main Continuous Posting Loop
        my $post_count = 0;
        my $moderated_wait_time = MODERATED_POST_TIMEOUT;

        # This loop runs a full cycle of posting attempts, then pauses and repeats.
        POST_CYCLE_LOOP: while (1) { 
            
            # Check for Daily Update and Refresh Cache (Stale check)
            if ($groups_list_ref->[0] and time() - $groups_list_ref->[0]->{timestamp} > GROUP_UPDATE_INTERVAL) {
                warn "Info: Group list cache expired. Initiating update." if defined $debug;
                
                my $new_groups_ref = update_and_store_groups();
                if (defined $new_groups_ref) {
                    $groups_list_ref = $new_groups_ref;
                } else {
                    warn "Warning: Failed to update group list cache. Will continue with old cache for now.";
                }
                
                @all_eligible_groups = @{ filter_eligible_groups($groups_list_ref, $group_match_rx, $exclude_match_rx) };
                warn "Info: Master group list refreshed and re-filtered. Found " . scalar(@all_eligible_groups) . " eligible groups." if defined $debug;
            }
            
            my @current_groups = @all_eligible_groups;
            
            # Long pause when no groups are eligible
            unless (@current_groups) {
                warn "Warning: All groups filtered out due to checks/patterns. Entering long pause before attempting a new cycle." if defined $debug;
                
                # Using the constant directly for fixed-duration sleeps
                print "No eligible groups to post to. Pausing for " . GROUP_EXHAUSTED_DELAY . " seconds to await new group eligibility (e.g., expired cooldowns, group list refresh).";
                sleep GROUP_EXHAUSTED_DELAY;
                
                next POST_CYCLE_LOOP; # Explicitly jump to the next iteration of the continuous post cycle
            }

            warn "\n--- Starting new posting cycle (Post #$post_count). Groups to attempt: " . scalar(@current_groups) . " ---" if defined $debug;

            # 4. Find a suitable group/photo combination
            # Using the constant MAX_TRIES directly.
            POST_ATTEMPT_LOOP: for (1 .. MAX_TRIES) { 
                # Exit if the list of groups to try has been exhausted
                last POST_ATTEMPT_LOOP unless scalar @current_groups; 

                my $random_index = int(rand(@current_groups));
                my $selected_group = $current_groups[$random_index];
                my $group_id = $selected_group->{id};
                my $group_name = $selected_group->{name};
                
                # --- DYNAMIC CHECK 1: Rate Limit Cooldown Check ---
                if (defined $rate_limit_history{$group_id}) {
                    my $wait_until = $rate_limit_history{$group_id}->{wait_until};
                    if (time() < $wait_until) { 
                        warn "Debug: Skipping group '$group_name' ($group_id). Rate limit cooldown active until " . scalar(localtime($wait_until)) if defined $debug;
                        splice(@current_groups, $random_index, 1); 
                        next POST_ATTEMPT_LOOP; # Explicitly continue inner loop (nested)
                    } else { 
                        warn "Debug: Cooldown cleared for '$group_name' ($group_id). Rate limit history expired." if defined $debug;
                        delete $rate_limit_history{$group_id}; 
                        save_history();
                    }
                }
                
                # --- DYNAMIC CHECK 2: Moderated Cooldown Check ---
                if ($selected_group->{moderated} == 1 and defined $moderated_post_history{$group_id}) {
                    my $history = $moderated_post_history{$group_id};
                    my $wait_until = $history->{post_time} + $moderated_wait_time;
                    my $context_check = is_photo_in_group($history->{photo_id}, $group_id);

                    unless (defined $context_check) { 
                        warn "Debug: Group '$group_name' ($group_id) failed photo context check (API error) for previous post. Retrying group later in cycle." if defined $debug;
                        next POST_ATTEMPT_LOOP; # Explicitly continue inner loop (nested)
                    } elsif ($context_check) { 
                        warn "Debug: Cooldown cleared for '$group_name' ($group_id). Previously posted photo found in group." if defined $debug;
                        delete $moderated_post_history{$group_id}; 
                        save_history();
                    } elsif (time() < $wait_until) { 
                        warn "Debug: Skipping group '$group_name' ($group_id). Moderated cooldown active until " . scalar(localtime($wait_until)) . ". Photo not yet in group." if defined $debug;
                        splice(@current_groups, $random_index, 1); 
                        next POST_ATTEMPT_LOOP; # Explicitly continue inner loop (nested)
                    } else { 
                        warn "Debug: Cooldown expired for '$group_name' ($group_id). Photo not found. Clearing history." if defined $debug;
                        delete $moderated_post_history{$group_id}; 
                        save_history();
                    }
                }
                
                # --- DYNAMIC CHECK 3: Real-Time API Status Check (Throttle) ---
                if ($selected_group->{limit_mode} ne 'none' || $selected_group->{moderated} == 1) {
                    my $status = check_posting_status($group_id, $group_name);
                    $selected_group->{limit_mode} = $status->{limit_mode};
                    $selected_group->{remaining} = $status->{remaining};
                    unless ($status->{can_post}) { 
                        warn "Debug: Skipping group '$group_name' ($group_id). Dynamic status check shows can_post=0 (Mode: $status->{limit_mode}, Remaining: $status->{remaining})." if defined $debug;
                        splice(@current_groups, $random_index, 1); 
                        next POST_ATTEMPT_LOOP; # Explicitly continue inner loop (nested)
                    }
                }

                # --- DYNAMIC CHECK 4: Check Last Poster ---
                my $response = flickr_api_call('flickr.groups.pools.getPhotos', { group_id => $group_id, per_page => 1 });
                unless (defined $response) {
                    warn "Debug: Failed to get photos from group '$group_name' ($group_id). Ignore this group from now on" if defined $debug;
                    splice(@current_groups, $random_index, 1); 
                    next POST_ATTEMPT_LOOP; # Explicitly continue inner loop (nested)
                }
                my $photos = $response->as_hash->{photos}->{photo} || [];
                $photos = [ $photos ] unless ref $photos eq 'ARRAY';
                if (@$photos and $photos->[0]->{owner} eq $user_nsid) { 
                    warn "Debug: Skipping group '$group_name' ($group_id). Last photo poster was current user ($user_nsid)." if defined $debug;
                    splice(@current_groups, $random_index, 1); 
                    next POST_ATTEMPT_LOOP; # Explicitly continue inner loop (nested)
                }

                # --- DYNAMIC CHECK 5: Select Photo and Check Context ---
                my $photo_data = find_random_photo(\@matching_sets);
                unless ($photo_data and $photo_data->{id}) {
                    warn "Debug: Failed to find a suitable photo or exhausted all sets/photos (Photo Age/Public Check)." if defined $debug;
                    next POST_ATTEMPT_LOOP; # Explicitly continue inner loop (nested)
                }
                
                my ($photo_id, $photo_title, $set_title, $set_id) = @$photo_data{qw/id title set_title set_id/};
                
                my $in_group_check = is_photo_in_group($photo_id, $group_id);
                unless (defined $in_group_check) { 
                    warn "Debug: Group '$group_name' ($group_id) failed photo context check for new photo (API error). Retrying." if defined $debug;
                    next POST_ATTEMPT_LOOP; # Explicitly continue inner loop (nested)
                } elsif ($in_group_check) { 
                    warn "Debug: Photo '$photo_title' ($photo_id) is already in group '$group_name' ($group_id). Retrying photo/group combination." if defined $debug;
                    next POST_ATTEMPT_LOOP; # Explicitly continue inner loop (nested)
                }
                
                # --- 5. Post the photo! ---
                if ($dry_run) {
                    print "DRY RUN: Would add photo '$photo_title' ($photo_id) from set '$set_title' to group '$group_name' ($group_id)";
                    
                    $post_count++;
                    last POST_ATTEMPT_LOOP; # Exit the inner loop on success (real or dry-run)

                } else {
                    my $response = flickr_api_call('flickr.groups.pools.add', { photo_id => $photo_id, group_id => $group_id });
                    
                    # Check for Fatal API Error (undef)
                    unless (defined $response) {
                        print "WARNING: Could not add photo '$photo_title' ($photo_id) to group '$group_name' ($group_id). API failed after all retries. Will skip current group and continue script execution.";
                        last POST_ATTEMPT_LOOP; # Exit the inner loop
                    } 
                    
                    # Check for SUCCESS or Moderated Pending Queue Status
                    my $moderated_pending = (!$response->{success} && $response->{error_message} =~ /Pending Queue for this Pool/i);

                    if ($response->{success} || $moderated_pending) {
                        
                        if ($response->{success}) {
                            print "SUCCESS: Added photo '$photo_title' ($photo_id) to group '$group_name' ($group_id)";
                        } else {
                            print "INFO: Added photo '$photo_title' ($photo_id) to group '$group_name' ($group_id). Status: Moderated - Pending Queue.";
                        }
                        
                        # Apply cooldown for moderated groups
                        if ($selected_group->{moderated} == 1) {
                             $moderated_post_history{$group_id} = { post_time => time(), photo_id  => $photo_id };
                             warn "Info: Moderated post successful. Group '$group_name' set to $moderated_wait_time second cooldown." if defined $debug;
                             save_history();
                        }

                        # Apply cooldown for rate-limited groups
                        if ($response->{success} && $selected_group->{limit_mode} ne 'none') {
                             my $limit = $selected_group->{limit_count} || 1; 
                             my $period_seconds = $selected_group->{limit_mode} eq 'day' ? SECONDS_IN_DAY : $selected_group->{limit_mode} eq 'week' ? SECONDS_IN_WEEK : $selected_group->{limit_mode} eq 'month' ? SECONDS_IN_MONTH : 0;

                            if ($limit > 0 && $period_seconds > 0) {
                                my $base_pause_time = $period_seconds / $limit;
                                my $random_multiplier = 0.7 + rand(0.6); 
                                my $pause_time = int($base_pause_time * $random_multiplier);
                                $pause_time = 1 unless $pause_time > 0;
                                my $wait_until = time() + $pause_time;
                                $rate_limit_history{$group_id} = { wait_until => $wait_until, limit_mode => $selected_group->{limit_mode} };
                                warn "Info: Group '$group_name' posted to (limit $limit/$selected_group->{limit_mode}). Applying randomized $pause_time sec cooldown." if defined $debug;
                                save_history();
                            }
                        }                       
                        
                        $post_count++;
                        last POST_ATTEMPT_LOOP; # Exit the inner loop on success

                    } else {
                        # Non-Fatal Error (Photo limit reached, Group Closed, etc.)
                        my $error_msg = $response->{error_message} || 'Unknown API Error';
                        
                        print "WARNING: Could not add photo '$photo_title' ($photo_id) to group '$group_name' ($group_id): $error_msg";
                        
                        # Special handling for "Photo limit reached" error: apply a 24-hour cooldown
                        if ($error_msg =~ /Photo limit reached/i) {
                            my $pause_time = SECONDS_IN_DAY; 
                            my $wait_until = time() + $pause_time;
                            $rate_limit_history{$group_id} = { wait_until => $wait_until, limit_mode => 'day' };
                            warn "Info: Group '$group_name' hit Photo Limit. Applying $pause_time sec cooldown." if defined $debug;
                            save_history();
                        }
                        
                        last POST_ATTEMPT_LOOP; # Exit the inner loop on non-fatal error
                    }
                }
            } # End of POST_ATTEMPT_LOOP

            # Pause between posting attempts
            my $sleep_time = int(rand($timeout_max + 1));
            print "Pausing for $sleep_time seconds before next attempt.";
            sleep $sleep_time;
        } # End of POST_CYCLE_LOOP
    }; # End of eval block
    
    # --- Error Handling and Exponential Backoff (After eval) ---
    my $fatal_error = $@;

    if ($fatal_error) {
        warn "\n\n!!! FATAL SCRIPT RESTART !!! (Attempt #$restart_attempt)";
        warn "REASON: $fatal_error";        
    }
    
    # Calculate exponential backoff delay, capped at MAX_RESTART_DELAY (24 hours)
    # This delay is applied unconditionally to ensure the script pauses between full cycles
    # and provides the required self-healing backoff when a fatal error occurs.
    my $delay_base = RESTART_RETRY_BASE * (RESTART_RETRY_FACTOR ** ($restart_attempt - 1));
    my $delay = $delay_base;
    
    # Add randomness (80% to 120% of calculated delay) to avoid thundering herd
    $delay = int($delay * (0.8 + rand(0.4))); 
    $delay = MAX_RESTART_DELAY if $delay > MAX_RESTART_DELAY;

    print "The entire script will restart after pausing for $delay seconds (Max delay: " . MAX_RESTART_DELAY . "s).";
    
    sleep $delay;

} # End of the master RESTART_LOOP
