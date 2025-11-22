#!/usr/bin/perl
# add2groups.pl
#
# PURPOSE:
# Automated Flickr group posting system with self-healing capabilities,
# persistent caching, and robust rate-limit handling.
#
# USAGE:
# perl add2groups.pl -f groups.json -H history.json -s "Set Pattern" [OPTIONS]
# perl add2groups.pl --clean-cache  (To clear the photo cache)
#

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
use Fcntl qw(:flock); 
use feature 'say';    
use Time::Piece; 
use Term::ANSIColor qw(:constants colored); 

# Set output record separator to always print a newline
$\ = "\n";

# --- OUTPUT BUFFERING FIX ---
$| = 1;
select(STDERR); $| = 1; select(STDOUT);

# --- Global Variables ---
my $flickr;                
my $user_nsid;             
my $debug;                 
my $max_age_timestamp;     
my @all_eligible_groups;   
my @matching_sets;         
my %photo_cache;           # In-memory storage for photo cache

# --- Command-line options variables ---
my ($help, $dry_run, $groups_file, $set_pattern, $group_pattern, $exclude_pattern, $max_age_years, $timeout_max);
my ($persistent_exclude, $clean_excludes, $ignore_excludes, $list_groups, $history_file);
my ($clean_cache); # Flag to clean cache on startup

# DEFAULT TIMEOUT SET TO 100
$timeout_max = 100;

# Global history hashes
my %moderated_post_history; 
my %rate_limit_history;     

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
    'clean-cache'         => \$clean_cache,      
    'i|ignore-excludes'   => \$ignore_excludes,
    'l|list-groups'       => \$list_groups,
);

# --- Constants ---
use constant GROUP_UPDATE_INTERVAL  => 24 * 60 * 60;  # 1 Day
use constant GROUP_EXHAUSTED_DELAY  => 60 * 60;       # 1 Hour

use constant MODERATED_POST_TIMEOUT => 24 * 60 * 60; 

use constant SECONDS_IN_DAY   => 24 * 60 * 60;
use constant SECONDS_IN_WEEK  => 7 * SECONDS_IN_DAY;
use constant SECONDS_IN_MONTH => 30 * SECONDS_IN_DAY;

use constant MAX_API_RETRIES      => 5;   
use constant API_RETRY_MULTIPLIER => 8;   

use constant MAX_RESTART_DELAY    => 24 * 60 * 60; 
use constant RESTART_RETRY_BASE   => 60;           
use constant RESTART_RETRY_FACTOR => 2;            
# MAX_TRIES constant removed

# --- Cache Constants ---
use constant CACHE_FILE_PATH    => '/tmp/cache-add2groups.json';
use constant CACHE_EXPIRATION   => 30 * 24 * 60 * 60; # 30 Days in seconds

# --- Helper Subroutines for Colored Output & Timestamps ---

sub get_timestamp {
    return "[" . localtime->strftime("%Y-%m-%d %H:%M:%S") . "]";
}

sub get_context {
    my $i = 1;
    # Subroutines that are part of the logging system and should be skipped
    my @log_subs = qw(
        get_context
        timestamp_message
        debug
        info
        success
        error
        fatal
        alert
    );
    my %is_log_sub = map { $_ => 1 } @log_subs;

    # Iterate up the call stack to find the original caller's file and line
    while ($i < 10) { # Limit search depth to prevent infinite loop or performance hit
        my ($package, $file, $line, $sub) = caller($i);
        
        # Stop if no more stack frames (caller returns undef)
        last unless defined $file;
        
        # Extract just the subroutine name without the package prefix (e.g., 'main::info' -> 'info')
        $sub =~ s/^.*::(\w+)$/$1/;

        # If the subroutine is NOT a logging function, we found the true caller.
        unless (exists $is_log_sub{$sub}) {
            # Shorten path
            $file =~ s/^.+\///; 
            return "($file:$line)";
        }
        $i++;
    }
    
    # Fallback if the loop didn't find anything
    my ($package, $file, $line) = caller(1);
    if (defined $file) {
        $file =~ s/^.+\///;
        return "($file:?)"; 
    }
    return "(unknown:?)";
}

sub timestamp_message {
    my ($level, $message, $color, $handle) = @_;
    my $context = get_context();
    
    my $colored_level;
    # Handle scalar and array ref colors correctly
    if (ref $color eq 'ARRAY') {
        # Use Term::ANSIColor's list syntax for multiple attributes
        $colored_level = colored([@$color], $level);
    } else {
        # Use Term::ANSIColor's scalar syntax for single attribute
        $colored_level = colored($level, $color);
    }
    
    print $handle get_timestamp() . " " . $colored_level . $context . ": " . $message . RESET;
}

sub debug {
    my ($message, $data) = @_;
    return unless defined $debug;
    my $full_message = $message . (defined $data && $debug > 2 ? Dumper($data) : '');
    timestamp_message("DEBUG", $full_message, 'cyan', *STDOUT);
}

sub info {
    my $message = shift;
    timestamp_message("INFO", $message, 'white', *STDOUT);
}

sub success {
    my $message = shift;
    timestamp_message("SUCCESS", $message, 'green', *STDOUT);
}

sub error {
    my $message = shift;
    timestamp_message("ERROR", $message, 'red', *STDERR);
}

sub fatal {
    my $message = shift;
    timestamp_message("FATAL", $message, ['bold', 'red'], *STDERR);
}

sub alert {
    my $message = shift;
    timestamp_message("ALERT", $message, ['bold', 'yellow'], *STDERR);
}

# --- Cleanup Logic on Startup ---

if ($clean_cache) {
    if (-e CACHE_FILE_PATH) {
        unlink CACHE_FILE_PATH;
        info("Cache file removed as requested by --clean-cache.");
    } else {
        info("Cache cleanup requested, but no cache file found at " . CACHE_FILE_PATH);
    }
}

# --- Flickr API Wrapper ---

sub flickr_api_call {
    my ($method, $args) = @_;
    my $retry_delay = 1;

    debug("API CALL: $method", $args) if defined $debug and $debug > 0;

    for my $attempt (1 .. MAX_API_RETRIES) {
        my $response = eval { $flickr->execute_method($method, $args) };

        if ($@ || !defined $response || !$response->{success}) {
            
            my $error = $response->{error_message} || $@ || 'Unknown error';

            # Special case: Moderated groups often return an "error" but the post is accepted into the queue
            if ($method eq 'flickr.groups.pools.add' and $error =~ /Pending Queue for this Pool/i) {
                debug("Moderated Group Success Detected: $error. Treating as successful and non-retryable.") if defined $debug;
                return $response; 
            }

            # Special case: Group is full/limit reached (non-retryable)
            if ($method eq 'flickr.groups.pools.add' and $error =~ /Photo limit reached/i) {
                alert("Non-retryable Error detected for $method: $error. Aborting retries.");
                return $response; 
            }
            
            # NOVO Special case: Content Not Allowed (Non-transient, non-retryable)
            if ($method eq 'flickr.groups.pools.add' and $error =~ /Content not allowed/i) {
                alert("Non-retryable Error: '$error'. Aborting retries for $method.");
                return $response; 
            }
            # --- FIM NOVO SPECIAL CASE ---


            if ($attempt == MAX_API_RETRIES) {
                fatal("Failed to execute $method after " . MAX_API_RETRIES . " attempts: $error");
                return undef; 
            }

            error("Attempt $attempt failed for $method: $error"); 

            sleep $retry_delay;
            $retry_delay *= API_RETRY_MULTIPLIER;
            next;
        }
        return $response; 
    }
    return undef; 
}

# --- File I/O Utilities ---

sub _write_file {
    my ($file_path, $content) = @_;
    my $fh; 

    unless (open $fh, '>:encoding(UTF-8)', $file_path) {
        alert("Cannot open $file_path for writing: $!"); 
        return undef;
    }
    unless (flock($fh, LOCK_EX)) {
        alert("Failed to acquire exclusive lock on $file_path. Skipping write.");
        close $fh;
        return undef;
    }
    eval { print $fh $content; };
    flock($fh, LOCK_UN); 
    close $fh;

    if ($@) {
        alert("Error during writing to $file_path: $@");
        return undef;
    }
    return 1;
}

sub _read_file {
    my $file_path = shift;
    my $fh; 

    return undef unless -e $file_path;
    debug("Accessing file $file_path") if defined $debug;

    unless (open $fh, '<:encoding(UTF-8)', $file_path) {
        alert("Cannot open $file_path for reading: $!"); 
        return undef;
    }
    unless (flock($fh, LOCK_SH)) {
        debug("Failed to acquire shared lock on $file_path. Skipping read.") if defined $debug;
        close $fh;
        return undef;
    }
    my $content = eval { local $/; <$fh> };
    flock($fh, LOCK_UN); 
    close $fh;

    if ($@) {
        alert("Error reading $file_path: $@");
        return undef; 
    }
    return $content;
}

# --- Cache & Storage Subroutines ---

sub save_groups {
    my $groups_ref = shift;
    my $json = JSON->new->utf8->pretty->encode({ groups => $groups_ref });
    unless (_write_file($groups_file, $json)) {
        alert("Failed to save group data to $groups_file.");
        return 0;
    }
    debug("Group list cache written to $groups_file") if defined $debug;
    return 1;
}

sub load_groups {
    debug("Loading groups from $groups_file") if defined $debug;
    my $json_text = _read_file($groups_file) or return undef;
    my $data = eval { decode_json($json_text) };
    if ($@) {
           error("Error decoding JSON from $groups_file: $@.");
           return undef;
    }
    return $data->{groups} // [];
}

sub save_history {
    return unless defined $history_file; 
    my $data_to_write = {
        moderated => \%moderated_post_history,
        ratelimit => \%rate_limit_history,
        timestamp => time(),
    };
    my $json = JSON->new->utf8->pretty->encode($data_to_write);
    unless (_write_file($history_file, $json)) {
        alert("Failed to save history data to $history_file.");
        return 0;
    }
    debug("Cooldown history written to $history_file") if defined $debug;
    return 1;
}

sub load_history {
    return unless defined $history_file; 
    debug("Loading history from $history_file") if defined $debug;
    my $json_text = _read_file($history_file) or return;
    my $data = eval { decode_json($json_text) };
    if ($@) {
           error("Error decoding JSON from $history_file: $@.");
           return;
    }
    %moderated_post_history = %{$data->{moderated} // {}};
    %rate_limit_history     = %{$data->{ratelimit} // {}};
    debug("History loaded. Moderated count: " . scalar(keys %moderated_post_history)) if defined $debug;
}

# --- Photo Cache Subroutines ---

sub save_photo_cache {
    # Dump current memory hash to file (compact format)
    my $json = JSON->new->utf8->encode(\%photo_cache);
    unless (_write_file(CACHE_FILE_PATH, $json)) {
        error("Failed to save photo cache to " . CACHE_FILE_PATH);
        return 0;
    }
    return 1;
}

sub load_photo_cache {
    # If cache file does not exist, create it
    unless (-e CACHE_FILE_PATH) {
        info("Photo cache file not found. Creating new cache at " . CACHE_FILE_PATH);
        %photo_cache = (); # Initialize memory hash
        save_photo_cache(); # Create file on disk
        return;
    }

    debug("Loading photo cache from " . CACHE_FILE_PATH) if defined $debug;
    
    my $json_text = _read_file(CACHE_FILE_PATH);
    return unless defined $json_text;

    my $data = eval { decode_json($json_text) };
    if ($@) {
        error("Error decoding photo cache JSON: $@. Starting with empty cache.");
        %photo_cache = (); 
        return;
    }
    %photo_cache = %{$data // {}};
    
    # Optional: Purge expired entries immediately upon load to save memory
    my $now = time();
    my $expired_count = 0;
    foreach my $key (keys %photo_cache) {
        if ($now - $photo_cache{$key}->{timestamp} > CACHE_EXPIRATION) {
            delete $photo_cache{$key};
            $expired_count++;
        }
    }
    debug("Photo cache loaded. Entries: " . scalar(keys %photo_cache) . " (Purged $expired_count expired)") if defined $debug;
}

# --- Global Filtering Function ---

sub filter_blocked_groups {
    my ($groups_ref) = @_;
    my $now = time();

    my @filtered = grep {
        my $item = $_; # Alias do elemento atual do grep
        # Imediatamente Invoca Sub-rotina Anônima para escopar o 'return'
        sub {
            my $gid = $item->{id};

            # 1. Rate Limit Check
            if (exists $rate_limit_history{$gid}) {
                if ($now < $rate_limit_history{$gid}->{wait_until}) {
                    return 0; # Still Blocked
                } else {
                    delete $rate_limit_history{$gid}; # Expired
                }
            }

            # 2. Moderated Check
            if ($item->{moderated} && exists $moderated_post_history{$gid}) {
                my $wait_until = $moderated_post_history{$gid}->{post_time} + MODERATED_POST_TIMEOUT;
                if ($now < $wait_until) {
                    return 0; # Still Blocked
                } else {
                    delete $moderated_post_history{$gid}; # Expired
                }
            }
            return 1; # Allowed
        }->(); # Invoca a função anônima imediatamente
    } @$groups_ref;

    # Salva o histórico se o número de grupos difere (implica que um cooldown expirou)
    if (scalar @filtered != scalar @$groups_ref) {
        save_history();
    }
    
    return \@filtered;
}


# --- Core Logic Subroutines ---

sub show_usage {
    print "Usage: $0 [OPTIONS]";
    print "Options:";
    printf "  %-20s %s\n", "-h, --help", "Show help message";
    printf "  %-20s %s\n", "-n, --dry-run", "Simulate adding without changes";
    printf "  %-20s %s\n", "-d, --debug", "Set debug level (0-3)";
    printf "  %-20s %s\n", "-f, --groups-file", "Path to groups JSON file";
    printf "  %-20s %s\n", "-H, --history-file", "Path to history JSON file";
    printf "  %-20s %s\n", "-s, --set-pattern", "Regex for set titles";
    printf "  %-20s %s\n", "-g, --group-pattern", "Regex for group names";
    printf "  %-20s %s\n", "--clean-cache", "Remove photo cache file on startup";
    print "\nNOTE: Requires authentication tokens in '\$ENV{HOME}/saved-flickr.st'";
}

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

sub init_flickr {
    if (defined $max_age_years) {
        $max_age_timestamp = time() - ($max_age_years * 365 * 24 * 60 * 60);
    }
    my $config_file = "$ENV{HOME}/saved-flickr.st";
    $flickr = Flickr::API->import_storable_config($config_file);
    
    my $response = flickr_api_call('flickr.test.login', {}); 
    
    unless (defined $response) { 
        fatal("Initial Flickr connection (flickr.test.login) failed after retries.");
        return 0;
    }
    
    $user_nsid = $response->as_hash->{user}->{id};
    debug("Logged in as $user_nsid") if defined $debug;
    return 1;
}

sub update_and_store_groups {
    my $old_groups_ref = shift;
    $old_groups_ref = load_groups() // [] unless 'ARRAY' eq ref $old_groups_ref;
    info("Refreshing group list from Flickr API...") if defined $debug;
    
    my $response = flickr_api_call('flickr.groups.pools.getGroups', {});
    unless (defined $response) { 
        alert("Failed to fetch complete group list. Returning cached list.");
        return $old_groups_ref; 
    }
    
    my $new_groups_raw = $response->as_hash->{groups}->{group} || [];
    $new_groups_raw = [ $new_groups_raw ] unless ref $new_groups_raw eq 'ARRAY';
    my %old_groups_map = map { $_->{id} => $_ } @$old_groups_ref;
    my @results;
    my $timestamp_epoch = time();
    
    foreach my $g_raw (@$new_groups_raw) {
        my $gid   = $g_raw->{nsid};
        my $gname = $g_raw->{name};
        my $g_old = $old_groups_map{$gid};
        
        my $response = flickr_api_call('flickr.groups.getInfo', { group_id => $gid });
        unless (defined $response) { 
            alert("Failed to fetch info for '$gname' ($gid). Skipping.");
            next;
        }
        
        my $data = $response->as_hash->{group};
        my $throttle = $data->{throttle} || {};
        
        my $is_pool_moderated = 0 | $data->{ispoolmoderated} // 0;
        my $is_moderate_ok    = 0 | $data->{restrictions}->{moderate_ok} // 0;
        my $is_group_moderated = $is_pool_moderated || $is_moderate_ok;

        my $photos_ok = 0 | $data->{restrictions}->{photos_ok} // 1;
        my $limit_mode = $throttle->{mode} || 'none';
        my $remaining = $throttle->{remaining} // 0;
        my $can_post_static = $photos_ok && $limit_mode ne 'disabled';
        
        my $entry = {
            timestamp     => $timestamp_epoch,
            id            => $gid,
            name          => $gname,
            privacy       => { 1 => 'Private', 2 => 'Public (invite)', 3 => 'Public (open)', }->{$g_raw->{privacy} // 3} || "Unknown",
            photos_ok     => $photos_ok,
            moderated     => $is_group_moderated, 
            limit_mode    => $limit_mode,
            limit_count   => ($throttle->{count} // 0) + 0,
            remaining     => $remaining + 0,
            can_post      => $can_post_static ? 1 : 0,
            role          => $g_raw->{admin} ? "admin" : $g_raw->{moderator} ? "moderator" : "member",
        };
        
        # PRESERVAÇÃO LOCAL: Preserva o status de exclusão existente
        $entry->{excluded} = $g_old->{excluded} if $g_old and $g_old->{excluded};

        push @results, $entry;
    }
    save_groups(\@results);
    return \@results;
}

sub update_local_group_exclusions {
    my $groups_ref = load_groups() // [];
    my @results;
    my $changes_made = 0;
    my $exclude_rx = qr/($exclude_pattern)/si if defined $exclude_pattern;
    
    info("Updating local group exclusion flags based on command-line arguments.") if defined $debug;
    
    foreach my $entry (@$groups_ref) {
        my $gname = $entry->{name};
        my $original_excluded = $entry->{excluded};

        # 1. Handle --clean (removes all existing exclusions)
        if ($clean_excludes and defined $entry->{excluded}) {
            delete $entry->{excluded};
            $changes_made++;
            debug("CLEAN: Removed exclusion from '$gname'");
        }

        # 2. Handle --persistent (adds new exclusion based on -e pattern)
        if ($persistent_exclude and defined $exclude_pattern and ($gname =~ $exclude_rx)) {
             # Add or overwrite the exclusion
             if (!defined $entry->{excluded} || $entry->{excluded}->{pattern} ne $exclude_pattern) {
                $entry->{excluded} = { pattern => $exclude_pattern, string => $1 };
                $changes_made++;
                debug("PERSISTENT: Added exclusion to '$gname'");
             }
        }
        
        # Check if a change occurred and it wasn't already counted by --clean or --persistent
        if (defined $original_excluded && !defined $entry->{excluded} && $clean_excludes) {
             # Already counted by $changes_made++ in --clean block
        } elsif (!defined $original_excluded && defined $entry->{excluded} && $persistent_exclude) {
             # Already counted by $changes_made++ in --persistent block
        }
        
        # Re-add to results array (even if no change was made)
        push @results, $entry;
    }
    
    if ($changes_made) {
        info("Saved $changes_made exclusion changes to $groups_file (local update).");
        save_groups(\@results);
    } else {
        info("No local exclusion changes detected.");
    }
    
    return \@results;
}


sub check_posting_status {
    my ($group_id, $group_name) = @_;
    
    my $response = flickr_api_call('flickr.groups.getInfo', { group_id => $group_id });
    unless (defined $response) { 
        alert("Failed to fetch dynamic status for '$group_name'. Returning error.");
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

sub find_random_photo {
    my ($sets_ref) = @_;
    my $PHOTOS_PER_PAGE = 250;
    
    my %used_set_ids;
    my %used_pages_by_set;
    my @sets_to_try = @$sets_ref;
    
    SET_LOOP: while (@sets_to_try) {
        my $set_index = int(rand(@sets_to_try));
        my $selected_set = $sets_to_try[$set_index];
        my $set_id = $selected_set->{id};
        my $total = $selected_set->{photos};

        debug("Selected set: $selected_set->{title} ($set_id)") if defined $debug;

        splice(@sets_to_try, $set_index, 1);
        $used_set_ids{$set_id} = 1;

        next SET_LOOP if $total == 0; 
        
        $used_pages_by_set{$set_id} = {} unless exists $used_pages_by_set{$set_id};
        my $max_page = int(($total - 1) / $PHOTOS_PER_PAGE) + 1;
        my @pages_to_try = (1..$max_page);

        PAGE_LOOP: while (@pages_to_try) {
            my $page_index = int(rand(@pages_to_try));
            my $random_page = $pages_to_try[$page_index];
            
            splice(@pages_to_try, $page_index, 1);
            $used_pages_by_set{$set_id}->{$random_page} = 1;

            # --- CACHE LOGIC BEGIN ---
            my $cache_key = "$set_id:$random_page";
            my $photos_on_page; 

            # 1. Check if valid data exists in cache
            if (exists $photo_cache{$cache_key}) {
                my $entry = $photo_cache{$cache_key};
                if (time() - $entry->{timestamp} < CACHE_EXPIRATION) {
                    debug("CACHE HIT: Using cached photos for Set $set_id, Page $random_page") if defined $debug;
                    $photos_on_page = $entry->{photos};
                } else {
                    debug("CACHE EXPIRED: Entry for Set $set_id, Page $random_page is too old.") if defined $debug;
                    delete $photo_cache{$cache_key};
                }
            }

            # 2. Only fetch from API if we don't have defined photos yet
            unless (defined $photos_on_page) {
                debug("CACHE MISS: Fetching API for Set $set_id, Page $random_page") if defined $debug;
                
                my $get_photos_params = { 
                    photoset_id => $set_id, 
                    per_page => $PHOTOS_PER_PAGE, 
                    page => $random_page,
                    privacy_filter => 1, 
                    extras => 'date_taken',
                };

                my $response = flickr_api_call('flickr.photosets.getPhotos', $get_photos_params); 

                unless (defined $response) { 
                    alert("Failed to fetch photos from set ($set_id). API failed. Skipping.");
                    last PAGE_LOOP; 
                }
                
                $photos_on_page = $response->as_hash->{photoset}->{photo} || [];
                $photos_on_page = [ $photos_on_page ] unless ref $photos_on_page eq 'ARRAY';

                # Cache the result
                $photo_cache{$cache_key} = {
                    timestamp => time(),
                    photos => $photos_on_page
                };
                save_photo_cache(); # Persist to disk
            }
            # --- CACHE LOGIC END ---
            
            unless (@$photos_on_page) { 
                debug("Page $random_page returned no public photos.") if defined $debug;
                next PAGE_LOOP; 
            }

            my @photo_indices_to_try = (0..$#{$photos_on_page});
            
            PHOTO_LOOP: while (@photo_indices_to_try) {
                my $index_to_try = int(rand(@photo_indices_to_try));
                my $random_photo_index = $photo_indices_to_try[$index_to_try];
                my $selected_photo = $photos_on_page->[$random_photo_index];
                
                splice(@photo_indices_to_try, $index_to_try, 1);
                
                # --- DEBUG START (User Requested) ---
                debug("Trying photo index $random_photo_index (ID: $selected_photo->{id}, Title: $selected_photo->{title})");
                # --- DEBUG END ---

                # Filter by max age
                if (defined $max_age_timestamp && $selected_photo->{datetaken}) {
                    my $date_taken = $selected_photo->{datetaken};
                    my $photo_timestamp;
                    
                    if (defined $debug) {
                        debug("MAX_AGE CHECK: Date taken: $date_taken. Max Age Limit: " . scalar(localtime($max_age_timestamp)));
                    }
                    
                    if ($date_taken =~ /^(\d{4})-(\d{2})-(\d{2})\s+(\d{2}):(\d{2}):(\d{2})$/) {
                        $photo_timestamp = Time::Local::timelocal($6, $5, $4, $3, $2-1, $1-1900);
                        debug("Date format 1 matched (Full Date/Time). Photo Epoch: $photo_timestamp.") if defined $debug;
                    } 
                    elsif ($date_taken =~ /^(\d{4})-(\d{2})-(\d{2})$/) {
                        $photo_timestamp = Time::Local::timelocal(0, 0, 0, $3, $2-1, $1-1900);
                        debug("Date format 2 matched (Date only). Photo Epoch: $photo_timestamp.") if defined $debug;
                    }

                    if (defined $photo_timestamp && $photo_timestamp < $max_age_timestamp) {
                        # --- DEBUG START (User Requested) ---
                        debug("PHOTO REJECTED: $selected_photo->{title} is older than max age filter (Epoch $photo_timestamp < $max_age_timestamp)");
                        # --- DEBUG END ---
                        next PHOTO_LOOP; 
                    }
                }

                return {
                    id => $selected_photo->{id},
                    title => $selected_photo->{title} || 'Untitled Photo',
                    set_title => $selected_set->{title} || 'Untitled Set',
                    set_id => $set_id,
                };
            }
        }
    }
    
    alert("Exhausted all matching sets, pages, and photos.") if defined $debug;
    return;
}

sub is_photo_in_group {
    my ($photo_id, $group_id) = @_;
    
    my $response = flickr_api_call('flickr.photos.getAllContexts', { photo_id => $photo_id });
    unless (defined $response) { 
        alert("Failed to check photo context for $photo_id. API failed.");
        return undef;
    }
    
    my $photo_pools = $response->as_hash->{pool} || [];
    $photo_pools = [ $photo_pools ] unless ref $photo_pools eq 'ARRAY';
    my $is_present = grep { $_->{id} eq $group_id } @$photo_pools;
    return $is_present; 
}

sub list_groups_report {
    my ($groups_ref, $group_match_rx, $exclude_match_rx) = @_;
    print "\n" . get_timestamp() . colored(" ### Group Status Report (Data from $groups_file) ###", 'bold');
    print get_timestamp() . " Refresh Timestamp: " . scalar(localtime($groups_ref->[0]->{timestamp})) if @$groups_ref;
    print get_timestamp() . " ---";
    my @eligible = @{ filter_eligible_groups($groups_ref, $group_match_rx, $exclude_match_rx) };
    my %eligible_map = map { $_->{id} => 1 } @eligible;
    
    printf "%-40s | %-12s | %-12s | %-8s | %-12s | %s\n", 
        "**Group Name**", "**Can Post**", "**Limit Mode**", "**Remain**", "**Moderated**", "**Exclusion/Filter Status**";
    print "-" x 111;

    foreach my $g (sort { $a->{name} cmp $b->{name} } @$groups_ref) {
        my $status;
        if (exists $eligible_map{$g->{id}}) {
            $status = colored("ELIGIBLE", 'green');
        } elsif (!defined $g->{can_post} || $g->{can_post} == 0) {
            $status = colored("STATICALLY BLOCKED", 'red');
        } elsif (defined $g->{excluded}) {
            $status = colored("PERSISTENTLY EXCLUDED", 'yellow');
        } elsif (defined $group_match_rx && $g->{name} !~ $group_match_rx) {
            $status = "MISSED -g MATCH";
        } elsif (defined $exclude_match_rx && $g->{name} =~ $exclude_match_rx) {
            $status = colored("MATCHED -e EXCLUDE", 'yellow');
        } else {
            $status = "NOT ELIGIBLE";
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


# --- MAIN EXECUTION FLOW ---

my @missing_params;

if ($help) {
    show_usage();
    exit;
}

unless ($groups_file) { push @missing_params, "-f (groups-file)"; }

unless ($list_groups) { 
    unless ($history_file) { push @missing_params, "-H (history-file)"; }
    unless ($set_pattern) { push @missing_params, "-s (set-pattern)"; }
}

if (@missing_params) {
    fatal("Missing required parameters:");
    error("  " . join("\n  ", @missing_params));
    show_usage();
    exit 1; 
}

my $group_match_rx = eval { qr/$group_pattern/i } if defined $group_pattern;
fatal("Invalid group pattern: $@") if $@;
my $exclude_match_rx = eval { qr/$exclude_pattern/i } if defined $exclude_pattern;
fatal("Invalid exclude pattern: $@") if $@;
unless ($list_groups) { 
    eval { qr/$set_pattern/ } if defined $set_pattern;
    fatal("Invalid set pattern: $@") if $@;
}

my $force_refresh = $clean_excludes || $persistent_exclude;

# Força a atualização local do cache se for para limpar ou aplicar novas exclusões persistentes.
if ($force_refresh) {
    update_local_group_exclusions(); 
}

# Handle list-groups mode
if ($list_groups) {
    unless (init_flickr()) {
        fatal("Initial Flickr connection failed.");
    }
    my $groups_list_ref = load_groups(); # Carrega os grupos (agora já atualizados localmente se $force_refresh)
    # Refresh cache via API if no local data exists or local data is empty
    $groups_list_ref = update_and_store_groups($groups_list_ref) unless defined $groups_list_ref and @$groups_list_ref;
    fatal("Cannot list groups: Could not load or fetch group list.") unless defined $groups_list_ref and @$groups_list_ref;
    list_groups_report($groups_list_ref, $group_match_rx, $exclude_match_rx);
    exit;
}

# --- MASTER RESTART LOOP (Self-Healing Core) ---
my $restart_attempt = 0;

RESTART_LOOP: while (1) {
    $restart_attempt++;

    eval {
        alert("\n--- Starting main script execution attempt #$restart_attempt ---\n") if $restart_attempt > 1; 
        
        # 1. Initialization
        unless (init_flickr()) { 
            die "FATAL: Initial Flickr connection (flickr.test.login) failed."; 
        }
        
        # Load/update group list cache
        my $groups_list_ref = load_groups();
        # FIX: Update only if cache is undefined OR empty (load_groups já traz a data atualizada se $force_refresh correu)
        $groups_list_ref = update_and_store_groups($groups_list_ref) unless defined $groups_list_ref and @$groups_list_ref;

        # Apply user filters
        @all_eligible_groups = @{ filter_eligible_groups($groups_list_ref, $group_match_rx, $exclude_match_rx) };
        unless (@all_eligible_groups) {
            die "No groups match all required filters.";
        }
        info("Found " . scalar(@all_eligible_groups) . " groups eligible for posting.") if defined $debug;

        # Fetch and filter photosets
        my $response = flickr_api_call('flickr.photosets.getList', { user_id => $user_nsid }); 
        unless (defined $response) { 
            die "FATAL: Failed to fetch photoset list from API.";
        }
        
        my $all_sets = $response->as_hash->{photosets}->{photoset} || [];
        $all_sets = [ $all_sets ] unless ref $all_sets eq 'ARRAY';
        @matching_sets = grep { ($_->{title} || '') =~ qr/$set_pattern/i } @$all_sets;

        unless (@matching_sets) { 
            die "No sets matching pattern '$set_pattern' found.";
        }
        info("Found " . scalar(@matching_sets) . " matching sets.") if defined $debug;
        
        # Load caches
        load_history();
        load_photo_cache(); # Load persistent photo cache (Create if missing)

        # 3. Main Continuous Posting Loop
        my $post_count = 0;

        POST_CYCLE_LOOP: while (1) { 
            
            # Check for stale group cache
            if ($groups_list_ref->[0] and time() - $groups_list_ref->[0]->{timestamp} > GROUP_UPDATE_INTERVAL) {
                info("Group list cache expired. Initiating update.") if defined $debug;
                
                my $new_groups_ref = update_and_store_groups();
                if (defined $new_groups_ref) {
                    $groups_list_ref = $new_groups_ref;
                } else {
                    alert("Failed to update group list. Continuing with old cache.");
                }
                
                @all_eligible_groups = @{ filter_eligible_groups($groups_list_ref, $group_match_rx, $exclude_match_rx) };
                info("Group list refreshed. Found " . scalar(@all_eligible_groups) . " eligible groups.") if defined $debug;
            }
            
            # --- FILTER GROUPS: Remove blocked items (Rate Limit / Moderated) ---
            my @current_groups = @{ filter_blocked_groups(\@all_eligible_groups) };

            unless (@current_groups) {
                info("No eligible groups (all blocked or filtered). Pausing for " . GROUP_EXHAUSTED_DELAY . " seconds.");
                sleep GROUP_EXHAUSTED_DELAY;
                next POST_CYCLE_LOOP;
            }

            info("\n--- New posting cycle (Post #$post_count). Groups available: " . scalar(@current_groups) . " ---");

            # 4. Find ONE random photo for this cycle
            my $photo_data = find_random_photo(\@matching_sets);
            unless ($photo_data and $photo_data->{id}) { 
                debug("Failed to find suitable photo in any matching sets.") if defined $debug;
                my $short_sleep = int(rand(10)) + 5; 
                info("No suitable photo found. Pausing for $short_sleep seconds before restarting cycle.");
                sleep $short_sleep;
                next POST_CYCLE_LOOP; 
            }
            
            my ($photo_id, $photo_title, $set_title, $set_id) = @$photo_data{qw/id title set_title set_id/};
            info("Selected photo '$photo_title' from set '$set_title' for this cycle.");

            # 5. Main Posting Attempt Loop (Tenta a foto selecionada em grupos)
            POST_ATTEMPT_LOOP: while (@current_groups) { 

                my $random_index = int(rand(@current_groups));
                my $selected_group = $current_groups[$random_index];
                
                unless (defined $selected_group && defined $selected_group->{id}) { 
                    splice(@current_groups, $random_index, 1);
                    next POST_ATTEMPT_LOOP;
                }

                my $group_id = $selected_group->{id};
                my $group_name = $selected_group->{name};
                
                # Dynamic Status Check (Real-time throttle)
                if ($selected_group->{limit_mode} ne 'none' || $selected_group->{moderated} == 1) {
                    my $status = check_posting_status($group_id, $group_name);
                    $selected_group->{limit_mode} = $status->{limit_mode};
                    $selected_group->{remaining} = $status->{remaining};
                    unless ($status->{can_post}) { 
                        debug("Skipping '$group_name' (Dynamic Block: $status->{limit_mode})") if defined $debug;
                        splice(@current_groups, $random_index, 1); 
                        next POST_ATTEMPT_LOOP;
                    }
                }

                # Last Poster Check
                my $response = flickr_api_call('flickr.groups.pools.getPhotos', { group_id => $group_id, per_page => 1 });
                unless (defined $response) { 
                    splice(@current_groups, $random_index, 1); 
                    next POST_ATTEMPT_LOOP;
                }
                my $photos = $response->as_hash->{photos}->{photo} || [];
                $photos = [ $photos ] unless ref $photos eq 'ARRAY';
                if (@$photos and $photos->[0]->{owner} eq $user_nsid) { 
                    debug("Skipping '$group_name' (You are last poster)") if defined $debug;
                    splice(@current_groups, $random_index, 1); 
                    next POST_ATTEMPT_LOOP;
                }
                
                # Check if ALREADY IN GROUP (Usando a foto já selecionada)
                my $in_group_check = is_photo_in_group($photo_id, $group_id);
                unless (defined $in_group_check) { next POST_ATTEMPT_LOOP; } 
                elsif ($in_group_check) { 
                    debug("Photo '$photo_title' already in '$group_name'.") if defined $debug;
                    splice(@current_groups, $random_index, 1); # Remova o grupo desta tentativa de foto
                    next POST_ATTEMPT_LOOP;
                }
                
                # --- Post Photo ---
                if ($dry_run) {
                    info("DRY RUN: Add '$photo_title' to '$group_name'");
                    $post_count++;
                    last POST_ATTEMPT_LOOP; 
                } else {
                    info("Attempting to add photo '$photo_title' to group '$group_name'"); 
                    my $response = flickr_api_call('flickr.groups.pools.add', { photo_id => $photo_id, group_id => $group_id });
                    unless (defined $response) { 
                        error("API Fail: Add '$photo_title' to '$group_name'");
                        last POST_ATTEMPT_LOOP; 
                    } 
                    
                    my $moderated_pending = (!$response->{success} && ($response->{error_message} // '') =~ /Pending Queue/i);

                    if ($response->{success} || $moderated_pending) {
                        if ($moderated_pending) {
                            info("Added '$photo_title' to '$group_name' (Moderated Pending).");
                        } else {
                            success("Added '$photo_title' to '$group_name'.");
                        }
                        
                        if ($selected_group->{moderated} == 1) {
                             $moderated_post_history{$group_id} = { post_time => time(), photo_id  => $photo_id };
                             save_history();
                        }

                        if ($selected_group->{limit_mode} ne 'none') {
                             my $limit = $selected_group->{limit_count} || 1; 
                             my $period_seconds = $selected_group->{limit_mode} eq 'day' ? SECONDS_IN_DAY : $selected_group->{limit_mode} eq 'week' ? SECONDS_IN_WEEK : $selected_group->{limit_mode} eq 'month' ? SECONDS_IN_MONTH : 0;

                            if ($limit > 0 && $period_seconds > 0) {
                                my $base_pause_time = $period_seconds / $limit;
                                my $pause_time = int($base_pause_time * (0.7 + (rand() * 0.4)));
                                $pause_time = 1 unless $pause_time > 0;
                                $rate_limit_history{$group_id} = { wait_until => time() + $pause_time, limit_mode => $selected_group->{limit_mode} };
                                save_history();
                            }
                        }                       
                        $post_count++;
                        last POST_ATTEMPT_LOOP; 
                    } else {
                        my $error_msg = $response->{error_message} || 'Unknown API Error';
                        error("Failed to add photo: $error_msg");
                        
                        if ($error_msg =~ /Photo limit reached/i) {
                            my $pause_time = SECONDS_IN_DAY; 
                            $rate_limit_history{$group_id} = { wait_until => time() + $pause_time, limit_mode => 'day' };
                            save_history();
                            alert("Group '$group_name' hit Photo limit. Applying day cooldown and removing group from cycle.");
                        } elsif ($error_msg =~ /Content not allowed/i) {
                            # Rejeição permanente para esta foto.
                            alert("Group '$group_name' rejected photo due to 'Content not allowed'. Removing group from cycle.");
                        } 
                        
                        # Em caso de qualquer falha final, o grupo é removido do ciclo da foto.
                        splice(@current_groups, $random_index, 1); 
                        next POST_ATTEMPT_LOOP; 
                    }
                }
            } 

            my $sleep_time = int(rand($timeout_max + 1));
            info("Pausing for $sleep_time seconds.");
            sleep $sleep_time;
        } 
    }; 
    
    my $fatal_error = $@;
    if ($fatal_error) {
        fatal("FATAL SCRIPT CRASH (Attempt #$restart_attempt): $fatal_error");        
    }
    
    my $delay = int((RESTART_RETRY_BASE * (RESTART_RETRY_FACTOR ** ($restart_attempt - 1))) * (0.8 + rand() * 0.4));
    $delay = MAX_RESTART_DELAY if $delay > MAX_RESTART_DELAY;
    info("Restarting in $delay seconds...");
    sleep $delay;
}