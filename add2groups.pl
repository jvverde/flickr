#!/usr/bin/perl
# add2groups.pl
#
# DESCRIPTION:
# This script is a robust tool designed to automate the process of posting photos 
# from specific Flickr sets (identified by a regex pattern) to eligible Flickr groups.
#
# KEY RELIABILITY IMPROVEMENTS:
# - **MASTER RESTART LOOP:** Wraps all execution logic in an eval/while loop for complete self-healing 
#   with exponential backoff against fatal errors (network, API, runtime bugs).
# - **Robust API Wrapper:** 'flickr_api_call' includes retry logic and exponential backoff.
# - **File Locking & Guaranteed Cleanup:** Uses 'flock' with guaranteed release and 
#   handle closure, even if I/O operations fail.
# - **Non-Fatal I/O:** File read/write failures result in a warning and script continuation.
# - **Fail-Safe Caching:** Group list update now falls back to cached data on API failure.
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
use Fcntl qw(:flock); # Required for file locking and robust file I/O

# Set output record separator to always print a newline
$\ = "\n";

# --- BUFFERING FIX ---
# Disable output buffering on STDOUT. This ensures 'print' messages are visible immediately, 
# which is critical when piping output to commands like 'tee'.
$| = 1;

# Global API and User Variables
my $flickr;                # Flickr::API object instance
my $user_nsid;             # Current user's Flickr NSID
my $debug;                 # Debug level (0: off, 1: info, 2: call/response, 3+: Dumper output)
my $max_age_timestamp;     # Unix timestamp representing the oldest acceptable photo date
my @all_eligible_groups;   # Stores filtered groups (initialized in the RESTART_LOOP)
my @matching_sets;         # Stores filtered photosets (initialized in the RESTART_LOOP)


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
use constant GROUP_UPDATE_INTERVAL  => 24 * 60 * 60;  # 24 hours in seconds
use constant MODERATED_POST_TIMEOUT => 24 * 60 * 60;  # 24 hours in seconds
use constant SECONDS_IN_DAY   => 24 * 60 * 60;        # Seconds in one day
use constant SECONDS_IN_WEEK  => 7 * SECONDS_IN_DAY;  # Seconds in one week
use constant SECONDS_IN_MONTH => 30 * SECONDS_IN_DAY; # Seconds in one month (approximate)

# API Retry Constants
use constant MAX_API_RETRIES      => 5;   # Maximum number of API retry attempts
use constant API_RETRY_MULTIPLIER => 8;   # Exponential backoff multiplier for API retries

# Master Restart Constants
use constant MAX_RESTART_DELAY    => 24 * 60 * 60; # Maximum restart delay (24 hours)
use constant RESTART_RETRY_BASE   => 60;           # Base restart delay in seconds (1 minute)
use constant RESTART_RETRY_FACTOR => 2;            # Exponential factor for restart delays
use constant MAX_TRIES => 20;                      # Maximum tries for photo/group matching

# --- Helper Subroutines ---

# Debug printing utility with conditional Data::Dumper output for high debug levels
# Only shows Data::Dumper output when debug level is 3 or higher
sub debug_print {
    return unless defined $debug;
    my ($message, $data) = @_;
    warn "Debug: $message" . (defined $data && $debug > 2 ? Dumper($data) : '');
}

# Robust Flickr API call wrapper with exponential backoff retry logic
# Handles network failures, rate limits, and temporary API errors
sub flickr_api_call {
    my ($method, $args) = @_;
    my $max_retries = MAX_API_RETRIES; 
    my $retry_delay = 1;  # Start with 1 second delay

    warn "Debug: API CALL: $method" if defined $debug and $debug > 0;

    for my $attempt (1 .. $max_retries) {
        my $response = eval { $flickr->execute_method($method, $args) };

        if ($@ || !$response->{success}) {
            my $error = $@ || $response->{error_message} || 'Unknown error';
            warn "Attempt $attempt failed for $method: $error";

            if ($attempt == $max_retries) {
                # This die will be caught by the outer RESTART_LOOP's eval
                die "Failed to execute $method after $max_retries attempts: $error"; 
            }
            sleep $retry_delay;
            $retry_delay *= API_RETRY_MULTIPLIER;  # Exponential backoff: 1, 8, 64, 512, 4096 seconds
            next;
        }
        return $response;
    }
}

# --- File I/O Utility Subroutines (Non-Fatal & Safe) ---

# General utility to write content to a file with an exclusive lock (LOCK_EX)
# Uses guaranteed cleanup to ensure file handles and locks are always released
# Returns 1 on success, undef on non-fatal failure (script continues)
sub _write_file {
    my ($file_path, $content) = @_;
    my $fh; 

    # 1. Open file (non-fatal failure)
    unless (open $fh, '>:encoding(UTF-8)', $file_path) {
        warn "Warning: Cannot open $file_path for writing: $!";
        return undef;
    }

    # 2. Acquire exclusive lock (non-fatal failure)
    unless (flock($fh, LOCK_EX)) {
        warn "Warning: Failed to acquire exclusive lock on $file_path. Skipping write.";
        close $fh;
        return undef;
    }

    # 3. Use eval for the write operation.
    eval {
        print $fh $content;
    };
    
    # 4. Guaranteed Cleanup (release lock and close handle) - ALWAYS executes
    flock($fh, LOCK_UN);
    close $fh;

    # 5. Handle write error caught by eval (Non-Fatal)
    if ($@) {
        warn "Warning: Error during writing to $file_path: $@";
        return undef;
    }
    
    return 1;
}

# General utility to read content from a file with a shared lock (LOCK_SH)
# Uses guaranteed cleanup to ensure file handles and locks are always released
# Returns content on success, undef on non-fatal failure (script continues)
sub _read_file {
    my $file_path = shift;
    my $fh; 

    return undef unless -e $file_path;
    warn "Debug: Accessing file $file_path" if defined $debug;

    # 1. Open file (non-fatal failure)
    unless (open $fh, '<:encoding(UTF-8)', $file_path) {
        warn "Warning: Cannot open $file_path for reading: $!";
        return undef;
    }

    # 2. Acquire shared lock (non-fatal failure)
    unless (flock($fh, LOCK_SH)) {
        warn "Warning: Failed to acquire shared lock on $file_path. Skipping read." if defined $debug;
        close $fh;
        return undef;
    }

    # 3. Use concise eval for the read operation.
    my $content = eval { local $/; <$fh> };

    # 4. Guaranteed Cleanup (release lock and close handle) - ALWAYS executes
    flock($fh, LOCK_UN);
    close $fh;

    # 5. Handle read error caught by eval (Non-Fatal)
    if ($@) {
        warn "Warning: Error reading $file_path: $@";
        return undef; 
    }
    
    return $content;
}

# --- High-Level File I/O Subroutines ---

# Save groups data to JSON file with proper encoding and formatting
# Wrapper around _write_file with groups-specific error handling
sub save_groups {
    my $groups_ref = shift;
    my $json = JSON->new->utf8->pretty->encode({ groups => $groups_ref });
    unless (_write_file($groups_file, $json)) {
        warn "Warning: Failed to save group data to $groups_file. Current group state is not persisted.";
        return 0;
    }
    warn "Info: Group list written to $groups_file" if defined $debug;
    return 1;
}

# Load groups data from JSON cache file
# Returns arrayref of groups or undef on failure
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

# Save cooldown history to JSON file (uses global hashes %moderated_post_history and %rate_limit_history)
# Includes timestamp for cache expiration checking
sub save_history {
    # Uses global %moderated_post_history and %rate_limit_history
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
    warn "Info: History written to $history_file" if defined $debug;
    return 1;
}

# Load cooldown history from JSON file into global hashes
# Restores moderated post history and rate limit cooldowns after script restart
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

# Display comprehensive usage information with formatted option descriptions
sub show_usage {
    print "Usage: $0 [OPTIONS]";
    print "Options:";
    printf "  %-20s %s\n", "-h, --help", "Show help message and exit";
    printf "  %-20s %s\n", "-n, --dry-run", "Simulate adding without making changes";
    printf "  %-20s %s\n", "-d, --debug", "Print Dumper output for various API responses";
    printf "  %-20s %s\n", "-f, --groups-file", "Path to store/read group JSON data (required)";
    printf "  %-20s %s\n", "-H, --history-file", "Path to store/read dynamic cooldown history (required).";
    printf "  %-20s %s\n", "-s, --set-pattern", "Regex pattern to match set titles (required, unless -l is used)";
    printf "  %-20s %s\n", "-g, --group-pattern", "Regex pattern to match target group names (optional)";
    printf "  %-20s %s\n", "-e, --exclude", "Negative regex pattern to exclude group names (optional)";
    printf "  %-20s %s\n", "-p, --persistent", "If -e matches, permanently mark group as excluded in JSON.";
    printf "  %-20s %s\n", "-c, --clean", "Clean (remove) all existing persistent excludes from JSON data.";
    printf "  %-20s %s\n", "-i, --ignore-excludes", "Temporarily ignore groups marked as excluded in JSON.";
    printf "  %-20s %s\n", "-l, --list-groups", "List all groups from the cache and exit.";
    printf "  %-20s %s\n", "-a, --max-age", "Maximal age of photos in years (optional)";
    printf "  %-20s %s\n", "-t, --timeout <sec>", "Maximum random delay between posts (default: $timeout_max sec)";
    print "\nNOTE: Requires authentication tokens in '\$ENV{HOME}/saved-flickr.st'";
}

# Initialize Flickr API connection and authenticate user
# Loads authentication from stored configuration and tests login
sub init_flickr {
    if (defined $max_age_years) {
        $max_age_timestamp = time() - ($max_age_years * 365 * 24 * 60 * 60);
    }
    my $config_file = "$ENV{HOME}/saved-flickr.st";
    $flickr = Flickr::API->import_storable_config($config_file);
    my $response = flickr_api_call('flickr.test.login', {}); 
    $user_nsid = $response->as_hash->{user}->{id};
    warn "Debug: Logged in as $user_nsid" if defined $debug;
}

# Filter groups based on static eligibility and pattern matching
# Applies multiple filter criteria: static can_post flag, exclusion patterns, include patterns
sub filter_eligible_groups {
    my ($groups_ref, $group_match_rx, $exclude_match_rx) = @_;
    return [ grep {
        my $g = $_;
        my $gname = $g->{name} || '';
        $g->{can_post} == 1 &&
        ( $ignore_excludes || !defined $g->{excluded} ) &&
        ( !defined $group_match_rx || $gname =~ $group_match_rx ) &&
        ( !defined $exclude_match_rx || $gname !~ $exclude_match_rx )
    } @$groups_ref ];
}

# Fetch latest group data from Flickr API and update local cache
# Falls back to cached data if API calls fail
sub update_and_store_groups {
    my $old_groups_ref = shift;
    $old_groups_ref = load_groups() // [] unless 'ARRAY' eq ref $old_groups_ref;
    warn "Info: Refreshing group list from Flickr API..." if defined $debug;
    my $response = eval { flickr_api_call('flickr.groups.pools.getGroups', {}) };
    if ($@) {
        warn "Warning: Failed to fetch complete group list from Flickr API: $@. Returning existing cached list.";
        return $old_groups_ref; 
    }
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
        my $response = eval { flickr_api_call('flickr.groups.getInfo', { group_id => $gid }) };
        if ($@) {
            warn "Warning: Failed to fetch info for group '$gname' ($gid). API died: $@. Skipping this group.";
            next; 
        }
        my $data = $response->as_hash->{group};
        my $throttle = $data->{throttle} || {};
        my $photos_ok = 0 | $data->{restrictions}->{photos_ok} // 1;
        my $limit_mode = $throttle->{mode} // 'none';
        my $remaining = $throttle->{remaining} // 0;
        my $can_post_static = $photos_ok && $limit_mode ne 'disabled';
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
            can_post      => $can_post_static ? 1 : 0,
            role          => $g_raw->{admin} ? "admin" : $g_raw->{moderator} ? "moderator" : "member",
        };
        $entry->{excluded} = $g_old->{excluded} if $g_old and $g_old->{excluded};
        delete $entry->{excluded} if $clean_excludes;
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

# Check current posting status for a group (dynamic eligibility check)
# Makes real-time API call to verify remaining posts and current limits
sub check_posting_status {
    my ($group_id, $group_name) = @_;
    my $response = eval { flickr_api_call('flickr.groups.getInfo', { group_id => $group_id }) };
    if ($@) {
        warn "Warning: Failed to fetch dynamic posting status for group '$group_name'. API died after retries: $@. Returning safe failure status.";
        return { can_post => 0, limit_mode => 'unknown_error', remaining => 0 };
    }
    my $data = $response->as_hash->{group};
    my $throttle = $data->{throttle} || {};
    my $limit_mode = $throttle->{mode} // 'none';
    my $remaining = $throttle->{remaining} // 0;
    my $can_post_current = ($limit_mode eq 'none') || ($remaining > 0);
    return { 
        can_post => $can_post_current, 
        limit_mode => $limit_mode,
        remaining => $remaining + 0,
    };
}

# Find a random photo from matching sets that meets age requirements
# Uses triple-nested random selection: set -> page -> photo for true randomness
# Implements exhaustive search with multiple fallback levels
sub find_random_photo {
    my ($sets_ref) = @_;
    my $PHOTOS_PER_PAGE = 250;  # Maximum photos per page for API efficiency
    
    # Track which sets and pages have been tried to avoid repeats
    my %used_set_ids;
    my %used_pages_by_set;
    
    # Start with all matching sets available for selection
    my @sets_to_try = @$sets_ref;
    
    # LEVEL 1: Outer loop - Try different sets randomly until exhausted
    while (@sets_to_try) {
        
        # Randomly select a set from remaining untried sets
        my $set_index = int(rand(@sets_to_try));
        my $selected_set = $sets_to_try[$set_index];
        my $set_id = $selected_set->{id};
        my $total = $selected_set->{photos};  # Total photos in this set

        # Remove this set from future consideration in this search
        splice(@sets_to_try, $set_index, 1);
        $used_set_ids{$set_id} = 1;

        # Skip empty sets
        next if $total == 0; 
        
        # Initialize page tracking for this set if not already done
        $used_pages_by_set{$set_id} = {} unless exists $used_pages_by_set{$set_id};
        
        # Calculate total pages needed for this set (ceil(total/PHOTOS_PER_PAGE))
        my $max_page = int(($total - 1) / $PHOTOS_PER_PAGE) + 1;
        
        # Create list of all pages available for random selection
        my @pages_to_try = (1..$max_page);

        # LEVEL 2: Middle loop - Try different pages within current set randomly
        while (@pages_to_try) {
            
            # Randomly select a page from remaining untried pages
            my $page_index = int(rand(@pages_to_try));
            my $random_page = $pages_to_try[$page_index];
            
            # Remove this page from future consideration in this set
            splice(@pages_to_try, $page_index, 1);
            $used_pages_by_set{$set_id}->{$random_page} = 1;

            # Prepare API parameters for fetching photos from this specific page
            my $get_photos_params = { 
                photoset_id => $set_id, 
                per_page => $PHOTOS_PER_PAGE, 
                page => $random_page,
                privacy_filter => 1,  # Only public photos
                extras => 'date_taken',  # Include date for age checking
            };

            # Fetch photos from the randomly selected page
            my $response = eval { flickr_api_call('flickr.photosets.getPhotos', $get_photos_params) }; 

            # Handle API failures for this page - skip to next page
            if ($@) {
                warn "Warning: Failed to fetch photos from set '$selected_set->{title}' ($set_id). API died: $@. Skipping to next set.";
                last;  # Break out of page loop, move to next set
            }
            
            # Extract photos from API response
            my $photos_on_page = $response->as_hash->{photoset}->{photo} || [];
            $photos_on_page = [ $photos_on_page ] unless ref $photos_on_page eq 'ARRAY';
            
            # Skip empty pages
            unless (@$photos_on_page) { 
                warn "Warning: Page $random_page returned no public photos." if defined $debug; 
                next; # Try another page in this set
            }

            # Create list of all photo indices available for random selection
            my @photo_indices_to_try = (0..$#{$photos_on_page});
            
            # LEVEL 3: Inner loop - Try different photos on current page randomly
            while (@photo_indices_to_try) {
                
                # Randomly select a photo index from remaining untried photos
                my $index_to_try = int(rand(@photo_indices_to_try));
                my $random_photo_index = $photo_indices_to_try[$index_to_try];
                my $selected_photo = $photos_on_page->[$random_photo_index];
                
                # Remove this photo from future consideration on this page
                splice(@photo_indices_to_try, $index_to_try, 1);
                
                # --- Photo Age Validation Check ---
                # Skip photos that are older than the maximum age limit
                if (defined $max_age_timestamp && $selected_photo->{datetaken}) {
                    my $date_taken = $selected_photo->{datetaken};
                    my $photo_timestamp;
                    
                    # Parse datetime string in "YYYY-MM-DD HH:MM:SS" format
                    if ($date_taken =~ /^(\d{4})-(\d{2})-(\d{2})\s+(\d{2}):(\d{2}):(\d{2})$/) {
                        # Convert to Unix timestamp (sec, min, hour, day, month-1, year-1900)
                        $photo_timestamp = Time::Local::timelocal($6, $5, $4, $3, $2-1, $1-1900);
                    } 
                    # Parse date string in "YYYY-MM-DD" format  
                    elsif ($date_taken =~ /^(\d{4})-(\d{2})-(\d{2})$/) {
                        # Convert to Unix timestamp at midnight
                        $photo_timestamp = Time::Local::timelocal(0, 0, 0, $3, $2-1, $1-1900);
                    }

                    # Check if photo is too old based on max_age_timestamp
                    if (defined $photo_timestamp && $photo_timestamp < $max_age_timestamp) {
                        warn "Debug: Photo '$selected_photo->{title}' ($selected_photo->{id}) is too old. Retrying photo." if defined $debug;
                        next;  # Skip this photo, try another on same page
                    }
                }

                # --- Photo is Valid and Not Too Old ---
                # Return photo data structure with all necessary metadata
                return {
                    id => $selected_photo->{id},
                    title => $selected_photo->{title} // 'Untitled Photo',
                    set_title => $selected_set->{title} // 'Untitled Set',
                    set_id => $set_id,
                };
            }
            
            # All photos on this page have been tried, continue to next page
        }
        
        # All pages in this set have been tried, continue to next set
    }
    
    # Exhausted all sets, pages, and photos - no suitable photo found
    warn "Warning: Exhausted all matching sets, pages, and photos. No photos found that meet the maximum age requirement." if defined $debug;
    return;  # Return undef to indicate no photo found
}

# Check if a specific photo is already in a group's pool
# Uses Flickr's getAllContexts API to check photo group membership
sub is_photo_in_group {
    my ($photo_id, $group_id) = @_;
    my $response = eval { flickr_api_call('flickr.photos.getAllContexts', { photo_id => $photo_id }) };
    if ($@) {
        warn "Warning: Failed to check photo context for photo $photo_id. API died after retries: $@. Returning undef to signal temporary failure.";
        return undef;
    }
    my $photo_pools = $response->as_hash->{pool} || [];
    $photo_pools = [ $photo_pools ] unless ref $photo_pools eq 'ARRAY';
    my $is_present = grep { $_->{id} eq $group_id } @$photo_pools;
    return $is_present; 
}

# Generate a formatted report of group status and eligibility
# Shows which groups are eligible and why others are excluded
sub list_groups_report {
    my ($groups_ref, $group_match_rx, $exclude_match_rx) = @_;
    print "\n### Group Status Report (Data from $groups_file)";
    print "Refresh Timestamp: " . scalar(localtime($groups_ref->[0]->{timestamp})) if @$groups_ref;
    print "---";
    my @eligible = @{ filter_eligible_groups($groups_ref, $group_match_rx, $exclude_match_rx) };
    my %eligible_map = map { $_->{id} => 1 } @eligible;
    
    printf "%-40s | %-12s | %-12s | %-8s | %s\n", 
        "**Group Name**", "**Can Post**", "**Limit Mode**", "**Remain**", "**Exclusion/Filter Status**";
    print "-" x 96;

    foreach my $g (sort { $a->{name} cmp $b->{name} } @$groups_ref) {
        my $status;
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
        printf "%-40s | %-12s | %-12s | %-12s | %s\n",
            $g->{name},
            $g->{can_post} ? "Yes" : "No",
            $g->{limit_mode} || 'none',
            $g->{remaining} || '-',
            $status;
    }
}


# --- Main Logic Execution ---

# Validate command line arguments and show usage if requirements not met
if ($help || !$groups_file || !$history_file || (!$list_groups && !$set_pattern)) {
    show_usage();
    exit;
}


# Compile regex patterns from command line arguments with validation
# Dies immediately if patterns are invalid to avoid runtime errors
my $group_match_rx = eval { qr/$group_pattern/i } if defined $group_pattern;
die "Invalid set pattern '$group_pattern': $@" if $@;
my $exclude_match_rx = eval { qr/$exclude_pattern/i } if defined $exclude_pattern;
die "Invalid set pattern '$exclude_pattern': $@" if $@;
eval { qr/$set_pattern/ };
die "Invalid set pattern '$set_pattern': $@" if $@;

my $force_refresh = $clean_excludes || $persistent_exclude;

# Handle list-groups mode: display report and exit
if ($list_groups) {
    init_flickr();
    my $groups_list_ref = load_groups();
    $groups_list_ref = update_and_store_groups($groups_list_ref) if $force_refresh or !defined $groups_list_ref or !@$groups_list_ref;
    die "Cannot list groups: Could not load or fetch group list." unless defined $groups_list_ref and @$groups_list_ref;
    list_groups_report($groups_list_ref, $group_match_rx, $exclude_match_rx);
    exit;
}

# --- MASTER RESTART LOOP (Self-Healing Core) ---
# Wraps entire script execution in error recovery with exponential backoff
# Survives network outages, API failures, and unexpected errors
my $restart_attempt = 0;

RESTART_LOOP: while (1) {
    $restart_attempt++;

    # Wrap *all* execution logic (Setup and Continuous Run) in an eval block
    # Any fatal error caught here triggers the restart mechanism
    eval {
        warn "\n--- Starting main script execution attempt #$restart_attempt ---\n" if $restart_attempt > 1;
        
        # Re-initialize Flickr API on each restart attempt
        init_flickr();
        my $groups_list_ref = load_groups();
        $groups_list_ref = update_and_store_groups($groups_list_ref) unless defined $groups_list_ref and @$groups_list_ref;

        
        @all_eligible_groups = @{ filter_eligible_groups($groups_list_ref, $group_match_rx, $exclude_match_rx) };
        unless (@all_eligible_groups) {
            die "No groups match all required filters.";
        }
        warn "Info: Found " . scalar(@all_eligible_groups) . " groups eligible for posting after initial filter." if defined $debug;

        # Get photosets matching the pattern
        my $response = flickr_api_call('flickr.photosets.getList', { user_id => $user_nsid }); 
        my $all_sets = $response->as_hash->{photosets}->{photoset} || [];
        $all_sets = [ $all_sets ] unless ref $all_sets eq 'ARRAY';
        @matching_sets = grep { ($_->{title} || '') =~ qr/$set_pattern/i } @$all_sets;

        unless (@matching_sets) {
            die "No sets matching pattern '$set_pattern' found.";
        }
        warn "Info: Found " . scalar(@matching_sets) . " matching sets." if defined $debug;
        
        # Main Continuous Posting Loop
        my $post_count = 0;
        my $max_tries = MAX_TRIES;
        my $moderated_wait_time = MODERATED_POST_TIMEOUT;

        load_history();

        while (1) {
            
            # Check for Daily Update and Refresh Cache (Stale check)
            if ($groups_list_ref->[0] and time() - $groups_list_ref->[0]->{timestamp} > GROUP_UPDATE_INTERVAL) {
                warn "Info: Group list cache expired. Initiating update." if defined $debug;
                
                eval { $groups_list_ref = update_and_store_groups(); };
                if ($@) {
                    warn "Warning: Failed to update group list cache: $@. Will continue with old cache for now.";
                }
                
                @all_eligible_groups = @{ filter_eligible_groups($groups_list_ref, $group_match_rx, $exclude_match_rx) };
                warn "Info: Master group list refreshed and re-filtered. Found " . scalar(@all_eligible_groups) . " eligible groups." if defined $debug;
            }
            
            # Reset the current pool of groups for this cycle
            my @current_groups = @all_eligible_groups;
            
            unless (@current_groups) {
                warn "Warning: All groups filtered out due to checks/patterns. End this cycle." if defined $debug;
                last;
            }

            warn "\n--- Starting new posting cycle (Post #$post_count). Groups to attempt: " . scalar(@current_groups) . " ---" if defined $debug;

            # Attempt to find a suitable group/photo combination
            for (1 .. $max_tries) {
                last unless scalar @current_groups;

                # Select a random group
                my $random_index = int(rand(@current_groups));
                my $selected_group = $current_groups[$random_index];
                my $group_id = $selected_group->{id};
                my $group_name = $selected_group->{name};
                
                # --- DYNAMIC CHECK 1 & 2: Cooldown Checks (Internal History) ---
                
                # Rate Limit Check - skip groups in cooldown period
                if (defined $rate_limit_history{$group_id}) {
                    my $wait_until = $rate_limit_history{$group_id}->{wait_until};
                    if (time() < $wait_until) { 
                        warn "Debug: Skipping group '$group_name' ($group_id). Rate limit cooldown active until " . scalar(localtime($wait_until)) if defined $debug;
                        splice(@current_groups, $random_index, 1); 
                        next;
                    } else { 
                        delete $rate_limit_history{$group_id}; 
                        save_history(); # Save immediately when cooldown expires
                    }
                }
                
                # Moderated Group Check - handle moderated group posting rules
                if ($selected_group->{moderated} == 1 and defined $moderated_post_history{$group_id}) {
                    my $history = $moderated_post_history{$group_id};
                    my $wait_until = $history->{post_time} + $moderated_wait_time;
                    my $context_check = is_photo_in_group($history->{photo_id}, $group_id);

                    if (not defined $context_check) { 
                        warn "Debug: Group '$group_name' ($group_id) failed photo context check (API error) for previous post. Retrying group later in cycle." if defined $debug;
                        next; 
                    } elsif ($context_check) { 
                        warn "Debug: Cooldown cleared for '$group_name' ($group_id). Previously posted photo found in group." if defined $debug;
                        delete $moderated_post_history{$group_id}; 
                        save_history(); # Save immediately when cooldown clears
                    } elsif (time() < $wait_until) { 
                        warn "Debug: Skipping group '$group_name' ($group_id). Moderated cooldown active until " . scalar(localtime($wait_until)) . ". Photo not yet in group." if defined $debug;
                        splice(@current_groups, $random_index, 1); 
                        next; 
                    } else { 
                        warn "Debug: Cooldown expired for '$group_name' ($group_id). Photo not found. Clearing history." if defined $debug;
                        delete $moderated_post_history{$group_id}; 
                        save_history(); # Save immediately when expired cooldown is cleared
                    }
                }
                
                # --- DYNAMIC CHECK 3: API Status (Remaining Posts Check) ---
                if ($selected_group->{limit_mode} ne 'none' || $selected_group->{moderated} == 1) {
                    my $status = check_posting_status($group_id, $group_name);
                    $selected_group->{limit_mode} = $status->{limit_mode};
                    $selected_group->{remaining} = $status->{remaining};
                    unless ($status->{can_post}) { 
                        warn "Debug: Skipping group '$group_name' ($group_id). Dynamic status check shows can_post=0 (Mode: $status->{limit_mode}, Remaining: $status->{remaining})." if defined $debug;
                        splice(@current_groups, $random_index, 1); 
                        next; 
                    }
                }

                # Check last poster in group to avoid consecutive posts
                my $response = eval { flickr_api_call('flickr.groups.pools.getPhotos', { group_id => $group_id, per_page => 1 }) };
                if ($@) {
                    warn "Debug: Failed to get photos from group '$group_name' ($group_id). Ignore this group from now on" if defined $debug;
                    splice(@current_groups, $random_index, 1); 
                    next;                     
                }
                my $photos = $response->as_hash->{photos}->{photo} || [];
                $photos = [ $photos ] unless ref $photos eq 'ARRAY';
                if (@$photos and $photos->[0]->{owner} eq $user_nsid) { 
                    warn "Debug: Skipping group '$group_name' ($group_id). Last photo poster was current user ($user_nsid)." if defined $debug;
                    splice(@current_groups, $random_index, 1); 
                    next; 
                }

                # Select Photo, Check Age, Check Context
                my $photo_data = find_random_photo(\@matching_sets);
                unless ($photo_data and $photo_data->{id}) {
                    warn "Debug: Failed to find a suitable photo or exhausted all sets/photos (Photo Age Check/No public photo)." if defined $debug;
                    next;
                }
                
                my ($photo_id, $photo_title, $set_title, $set_id) = @$photo_data{qw/id title set_title set_id/};
                
                my $in_group_check = is_photo_in_group($photo_id, $group_id);
                if (not defined $in_group_check) { 
                    warn "Debug: Group '$group_name' ($group_id) failed photo context check for new photo (API error). Retrying." if defined $debug;
                    next; 
                } elsif ($in_group_check) { 
                    warn "Debug: Photo '$photo_title' ($photo_id) is already in group '$group_name' ($group_id). Retrying photo/group combination." if defined $debug;
                    next; 
                }
                
                # Post the photo!
                if ($dry_run) {
                    print "DRY RUN: Would add photo '$photo_title' ($photo_id) from set '$set_title' to group '$group_name' ($group_id)";
                } else {
                    my $response = eval { flickr_api_call('flickr.groups.pools.add', { photo_id => $photo_id, group_id => $group_id }) };
                    
                    if ($@) {
                        print "ERROR: Could not add photo '$photo_title' ($photo_id) to group '$group_name' ($group_id): $@";
                    } else {
                        print "SUCCESS: Added photo '$photo_title' ($photo_id) to group '$group_name' ($group_id)";
                        
                        # Apply cooldown for moderated groups
                        if ($selected_group->{moderated} == 1) {
                             $moderated_post_history{$group_id} = { post_time => time(), photo_id  => $photo_id };
                             warn "Info: Moderated post successful. Group '$group_name' set to $moderated_wait_time second cooldown." if defined $debug;
                             save_history(); # Save cooldown state immediately
                        }

                        # Apply cooldown for rate-limited groups
                        if ($selected_group->{limit_mode} ne 'none') {
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
                                save_history(); # Save cooldown state immediately
                            }
                        }                       
                    }
                }
                
                $post_count++;
                last; # Exit the inner loop on a successful post (real or dry-run)
            }

            # Pause between posting attempts
            my $sleep_time = int(rand($timeout_max + 1));
            print "Pausing for $sleep_time seconds before next attempt.";
            sleep $sleep_time;
        }
    };
    
    # --- Error Handling and Exponential Backoff (After eval) ---
    my $fatal_error = $@;

    # Calculate exponential backoff delay, capped at MAX_RESTART_DELAY (24 hours)
    my $delay_base = RESTART_RETRY_BASE * (RESTART_RETRY_FACTOR ** ($restart_attempt - 1));
    my $delay = $delay_base;
    
    # Add randomness (80% to 120% of calculated delay) to avoid thundering herd
    $delay = int($delay * (0.8 + rand(0.4))); 
    $delay = MAX_RESTART_DELAY if $delay > MAX_RESTART_DELAY;

    if ($fatal_error) {
        warn "\n\n!!! FATAL SCRIPT RESTART !!! (Attempt #$restart_attempt)";
        warn "REASON: $fatal_error";        
    }
    print "The entire script will restart after pausing for $delay seconds (Max delay: " . MAX_RESTART_DELAY . "s).";
    
    sleep $delay;
}