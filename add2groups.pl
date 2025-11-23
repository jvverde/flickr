#!/usr/bin/perl
# add2groups.pl
#
# PURPOSE:
# Automated Flickr group posting system with self-healing capabilities,
# persistent caching, and robust rate-limit handling.
#
# The script selects a random photo from matching photosets and attempts to
# post it to eligible groups, respecting global and per-group cooldowns,
# rate limits, and moderation queues.
#
# FEATURES:
# - Self-healing restart loop with exponential backoff
# - Persistent photo and group membership cache (30-day validity)
# - Dynamic group eligibility checking with real-time throttle status
# - Multiple cooldown mechanisms (short-term, rate limit, moderated groups)
# - Configurable filters for sets, groups, and photo age
# - Dry-run mode for testing
# - Detailed debug logging with multiple verbosity levels
#
# USAGE EXAMPLES:
#
# 1. Normal posting mode (requires -f, -H, -s):
#    perl add2groups.pl -f groups.json -H history.json -s "Vacation|Travel" -g "Nature" -a 2 -d 1
#
# 2. List groups mode (requires -f):
#    perl add2groups.pl -f groups.json -l -g "Landscape"
#
# 3. Dump group info mode (requires -f and -g):
#    perl add2groups.pl -f groups.json --dump -g "Specific Group Name"
#
# 4. Dry-run simulation:
#    perl add2groups.pl -f groups.json -H history.json -s "Summer" -n -d 2
#
# 5. Clean cache and exclusions:
#    perl add2groups.pl --clean-cache -c
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
# Disable output buffering for STDOUT and STDERR to ensure immediate logging
$| = 1;
select(STDERR); $| = 1; select(STDOUT);

# --- Global Variables ---
my $flickr;                # Flickr API object
my $user_nsid;             # Authenticated user NSID
my $debug;                 # Debug level (0-3)
my $max_age_timestamp;     # Unix timestamp for filtering photos older than max-age
my @all_eligible_groups;   # List of groups matching static criteria
my @matching_sets;         # List of photosets matching the user pattern
my %photo_cache;           # In-memory storage for photo and group membership cache

# --- Command-line options variables ---
my ($help, $dry_run, $groups_file, $set_pattern, $group_pattern, $exclude_pattern, $max_age_years, $timeout_max);
my ($persistent_exclude, $clean_excludes, $ignore_excludes, $list_groups, $history_file);
my ($clean_cache); # Flag to clear photo cache on startup
my ($dump); # Flag to dump detailed group info

# DEFAULT TIMEOUT SET TO 100 seconds
$timeout_max = 100;

# Global history hashes for persistent cooldowns
my %moderated_post_history; # Stores last post time for moderated groups
my %rate_limit_history;     # Stores cooldown end time for rate-limited groups
my %short_cooldown_history; # Stores non-persistent (in-memory) cooldowns (20-60 min)

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
    'a|max-age:i'         => \$max_age_years,
    't|timeout:i'         => \$timeout_max,
    'p|persistent'        => \$persistent_exclude,
    'c|clean'             => \$clean_excludes,
    'clean-cache'         => \$clean_cache,      
    'i|ignore-excludes'   => \$ignore_excludes,
    'l|list-groups'       => \$list_groups,
    'dump'                => \$dump, 
);

# --- Constants ---
use constant GROUP_UPDATE_INTERVAL  => 24 * 60 * 60;  # Time before refreshing the group list cache (1 Day)
use constant GROUP_EXHAUSTED_DELAY  => 60 * 60;       # Sleep time when no groups are eligible (1 Hour)

use constant MODERATED_POST_TIMEOUT => 24 * 60 * 60; # Cooldown after posting to a moderated group (1 Day)

use constant SECONDS_IN_DAY   => 24 * 60 * 60;
use constant SECONDS_IN_WEEK  => 7 * SECONDS_IN_DAY;
use constant SECONDS_IN_MONTH => 30 * SECONDS_IN_DAY;

use constant MAX_API_RETRIES      => 5;   # Max attempts for API calls
use constant API_RETRY_MULTIPLIER => 8;   # Exponential backoff factor for API retries

use constant MAX_RESTART_DELAY    => 24 * 60 * 60; # Max delay for fatal script restart
use constant RESTART_RETRY_BASE   => 60;           # Base delay for restart loop
use constant RESTART_RETRY_FACTOR => 2;            # Factor for exponential restart backoff

# --- Cache Constants ---
use constant CACHE_FILE_PATH    => '/tmp/cache-add2groups.json'; # Path to persistent photo cache file
use constant CACHE_EXPIRATION   => 30 * 24 * 60 * 60; # Validity for photo and group membership cache (30 Days)

# --- Helper Subroutines for Colored Output & Timestamps ---

# Gets current timestamp string
sub get_timestamp {
    return "[" . localtime->strftime("%Y-%m-%d %H:%M:%S") . "]";
}

# Determines the context (file and line) of the actual calling subroutine, skipping logging wrappers
sub get_context {
    my $i = 1;
    my @log_subs = qw(
        get_context timestamp_message debug info success error fatal alert apply_short_cooldown
    );
    my %is_log_sub = map { $_ => 1 } @log_subs;

    while ($i < 10) { 
        my ($package, $file, $line, $sub) = caller($i);
        last unless defined $file;
        $sub =~ s/^.*::(\w+)$/$1/;
        unless (exists $is_log_sub{$sub}) {
            $file =~ s/^.+\///; 
            return "($file:$line)";
        }
        $i++;
    }
    
    my ($package, $file, $line) = caller(1);
    if (defined $file) {
        $file =~ s/^.+\///;
        return "($file:?)"; 
    }
    return "(unknown:?)";
}

# Prints a colored, timestamped message
sub timestamp_message {
    my ($level, $message, $color, $handle) = @_;
    my $context = get_context();
    
    my $colored_level;
    if (ref $color eq 'ARRAY') {
        $colored_level = colored([@$color], $level);
    } else {
        $colored_level = colored($level, $color);
    }
    
    print $handle get_timestamp() . " " . $colored_level . $context . ": " . $message . RESET;
}

# Debug logging. Prints only if $debug is defined. Prints $data if $debug > 2.
sub debug {
    my ($message, $data) = @_;
    return unless defined $debug;
    my $full_message = $message . (defined $data && $debug > 2 ? Dumper($data) : '');
    timestamp_message("DEBUG", $full_message, 'cyan', *STDOUT);
}

# Info level logging
sub info {
    my $message = shift;
    timestamp_message("INFO", $message, 'white', *STDOUT);
}

# Success level logging
sub success {
    my $message = shift;
    timestamp_message("SUCCESS", $message, 'green', *STDOUT);
}

# Error level logging (to STDERR)
sub error {
    my $message = shift;
    timestamp_message("ERROR", $message, 'red', *STDERR);
}

# Fatal error logging (to STDERR) and crash indication
sub fatal {
    my $message = shift;
    timestamp_message("FATAL", $message, ['bold', 'red'], *STDERR);
}

# Alert/Warning level logging (to STDERR)
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

# Executes a Flickr API method with built-in retry logic and exponential backoff
# Handles transient errors, moderated group responses, and permanent failures appropriately
sub flickr_api_call {
    my ($method, $args) = @_;
    my $retry_delay = 1;

    debug("API CALL: $method", $args);

    for my $attempt (1 .. MAX_API_RETRIES) {
        my $response = eval { $flickr->execute_method($method, $args) };

        if ($@ || !defined $response || !$response->{success}) {
            
            my $error = $response->{error_message} || $@ || 'Unknown error';

            # Handle known non-retryable errors or "soft errors"
            
            # Moderated groups return an "error" but the post is accepted into the queue
            if ($method eq 'flickr.groups.pools.add' and $error =~ /Pending Queue for this Pool/i) {
                debug("Moderated Group Success Detected: $error. Treating as successful and non-retryable.");
                return $response; 
            }

            # Group limit reached (non-retryable, specific cooldown needed)
            if ($method eq 'flickr.groups.pools.add' and $error =~ /Photo limit reached/i) {
                alert("Non-retryable Error detected for $method: $error. Aborting retries.");
                return $response; 
            }
            
            # Content Not Allowed (Non-transient, non-retryable)
            if ($method eq 'flickr.groups.pools.add' and $error =~ /Content not allowed/i) {
                alert("Non-retryable Error: '$error'. Aborting retries for $method.");
                return $response; 
            }

            if ($attempt == MAX_API_RETRIES) {
                fatal("Failed to execute $method after " . MAX_API_RETRIES . " attempts: $error");
                return undef; 
            }

            error("Attempt $attempt failed for $method: $error"); 

            # Apply exponential backoff before next retry
            sleep $retry_delay;
            $retry_delay *= API_RETRY_MULTIPLIER;
            next;
        }
        return $response; # Success
    }
    return undef; # All retries failed
}

# --- File I/O Utilities ---

# Writes content to a file with exclusive file locking (LOCK_EX)
# Returns 1 on success, undef on failure
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

# Reads content from a file with shared file locking (LOCK_SH)
# Returns file content on success, undef on failure
sub _read_file {
    my $file_path = shift;
    my $fh; 

    return undef unless -e $file_path;
    debug("Accessing file $file_path");

    unless (open $fh, '<:encoding(UTF-8)', $file_path) {
        alert("Cannot open $file_path for reading: $!"); 
        return undef;
    }
    unless (flock($fh, LOCK_SH)) {
        debug("Failed to acquire shared lock on $file_path. Skipping read.");
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

# Saves the current group list to the groups file
# Returns 1 on success, 0 on failure
sub save_groups {
    my $groups_ref = shift;
    my $json = JSON->new->utf8->pretty->encode({ groups => $groups_ref });
    unless (_write_file($groups_file, $json)) {
        alert("Failed to save group data to $groups_file.");
        return 0;
    }
    debug("Group list cache written to $groups_file");
    return 1;
}

# Loads the group list from the groups file
# Returns arrayref of groups on success, undef on failure
sub load_groups {
    debug("Loading groups from $groups_file");
    my $json_text = _read_file($groups_file) or return undef;
    my $data = eval { decode_json($json_text) };
    if ($@) {
           error("Error decoding JSON from $groups_file: $@.");
           return undef;
    }
    return $data->{groups} // [];
}

# Saves the history (cooldowns) to the history file
# Returns 1 on success, 0 on failure
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
    debug("Cooldown history written to $history_file") if defined $debug and $debug > 1;
    return 1;
}

# Loads the history (cooldowns) from the history file
sub load_history {
    return unless defined $history_file; 
    debug("Loading history from $history_file");
    my $json_text = _read_file($history_file) or return;
    my $data = eval { decode_json($json_text) };
    if ($@) {
           error("Error decoding JSON from $history_file: $@.");
           return;
    }
    %moderated_post_history = %{$data->{moderated} // {}};
    %rate_limit_history     = %{$data->{ratelimit} // {}};
    debug("History loaded. Moderated count: " . scalar(keys %moderated_post_history));
}

# --- Photo Cache Subroutines ---

# Saves the in-memory photo cache to the persistent cache file
# Returns 1 on success, 0 on failure
sub save_photo_cache {
    my $json = JSON->new->utf8->encode(\%photo_cache);
    unless (_write_file(CACHE_FILE_PATH, $json)) {
        error("Failed to save photo cache to " . CACHE_FILE_PATH);
        return 0;
    }
    return 1;
}

# Loads the persistent photo cache into memory
# Purges expired entries (older than CACHE_EXPIRATION) during load
sub load_photo_cache {
    unless (-e CACHE_FILE_PATH) {
        debug("Photo cache file not found. Creating new cache at " . CACHE_FILE_PATH);
        %photo_cache = (); 
        save_photo_cache(); 
        return;
    }

    debug("Loading photo cache from " . CACHE_FILE_PATH);
    
    my $json_text = _read_file(CACHE_FILE_PATH);
    return unless defined $json_text;

    my $data = eval { decode_json($json_text) };
    if ($@) {
        error("Error decoding photo cache JSON: $@. Starting with empty cache.");
        %photo_cache = (); 
        return;
    }
    %photo_cache = %{$data // {}};
    
    # Purge expired entries upon load (entries older than CACHE_EXPIRATION)
    my $now = time();
    my $expired_count = 0;
    foreach my $key (keys %photo_cache) {
        # Check general photo/page cache AND group membership cache expiration
        if (exists $photo_cache{$key}->{timestamp} && $now - $photo_cache{$key}->{timestamp} > CACHE_EXPIRATION) {
            delete $photo_cache{$key};
            $expired_count++;
        }
    }
    debug("Photo cache loaded. Entries: " . scalar(keys %photo_cache) . " (Purged $expired_count expired)");
}

# Forces an update to the group membership cache for a specific photo/group combination
# Used after successful posting to mark photo as member of group
sub update_group_membership_cache {
    my ($photo_id, $group_id, $is_member) = @_;
    my $cache_key = "groupcheck:$photo_id:$group_id";
    
    $photo_cache{$cache_key} = {
        timestamp => time(),
        is_member => $is_member ? 1 : 0, # 1 for member, 0 for not member
    };
    debug("Forced cache update: Photo $photo_id is_member=" . ($is_member ? '1' : '0') . " in Group $group_id") if defined $debug and $debug > 1;
    save_photo_cache();
}

# --- Short Cooldown Routine (20-60 min) ---
# Applies temporary non-persistent cooldowns for various blocking conditions
# These cooldowns are stored in memory only and lost on script restart
sub apply_short_cooldown {
    my ($group_id, $group_name, $reason) = @_;
    my $min_delay = 20 * 60;  # 1200 seconds (20 minutes)
    my $max_delay = 60 * 60;  # 3600 seconds (60 minutes)
    my $range = $max_delay - $min_delay;
    
    # Generate random time between min_delay and max_delay (inclusive)
    my $pause_time = int(rand($range + 1)) + $min_delay; 
    my $wait_until = time() + $pause_time;
    
    $short_cooldown_history{$group_id} = { 
        wait_until => $wait_until, 
        reason     => $reason || 'Unknown',
        post_time  => time(),
    };
    
    info("Group '$group_name' blocked (Reason: $reason). Applying non-persistent " . int($pause_time / 60) . " min cooldown.");
}

# --- Global Filtering Function ---

# Filters groups based on current cooldown history (rate limits and moderated post times)
# Returns arrayref of groups that are currently eligible for posting
sub filter_blocked_groups {
    my ($groups_ref) = @_;
    my $now = time();

    my @filtered = grep {
        my $item = $_; 
        sub {
            my $group_id = $item->{id};
            my $group_name = $item->{name};

            # 0. Short Cooldown Check (Non-Persistent, 20-60 min)
            if (exists $short_cooldown_history{$group_id}) {
                if ($now < $short_cooldown_history{$group_id}->{wait_until}) {
                    debug("Group $group_id blocked by non-persistent cooldown (Reason: $short_cooldown_history{$group_id}->{reason}).") if defined $debug and $debug > 1;
                    return 0; # Still blocked by short cooldown
                } else {
                    delete $short_cooldown_history{$group_id}; # Cooldown expired (removed from memory)
                }
            }
            
            # 1. Rate Limit Cooldown Check
            if (exists $rate_limit_history{$group_id}) {
                if ($now < $rate_limit_history{$group_id}->{wait_until}) {
                    return 0; # Still blocked by rate limit
                } else {
                    delete $rate_limit_history{$group_id}; # Cooldown expired
                }
            }

            # 2. Moderated Group Cooldown Check
            if ($item->{moderated} && exists $moderated_post_history{$group_id}) {
                my $wait_until = $moderated_post_history{$group_id}->{post_time} + MODERATED_POST_TIMEOUT;
                my $photo_id = $moderated_post_history{$group_id}->{photo_id};
                my $context_check = is_photo_in_group($photo_id, $group_id);
                unless (defined $context_check ) {
                    alert("Filtering out group '$group_name' ($group_id). Moderated check failed (API error)");
                } elsif ($context_check) {
                    debug("Photo $photo_id found in group '$group_name'. Clearing moderated cooldown.") if defined $debug and $debug > 1;
                    delete $moderated_post_history{$group_id}; # Cooldown expired
                } elsif ($now < $wait_until) {
                    return 0; # Still blocked by moderation cooldown
                } else {
                    debug("Moderated cooldown expired after timeout for '$group_name'") if defined $debug and $debug > 1;
                    delete $moderated_post_history{$group_id}; # Cooldown expired
                }
            }
            return 1; # Allowed
        }->(); 
    } @$groups_ref;

    # Save history if any cooldowns expired (implying changes in the history state)
    if (scalar @filtered != scalar @$groups_ref) {
        save_history();
    }
    
    return \@filtered;
}


# --- Core Logic Subroutines ---

# Prints the script usage and help message with detailed examples
sub show_usage {
    print "Usage: $0 [OPTIONS]";
    print "\nMAIN OPERATION MODES:";
    print "  Posting Mode:     perl $0 -f groups.json -H history.json -s \"Set Pattern\" [OPTIONS]";
    print "  List Groups Mode: perl $0 -f groups.json -l [GROUP OPTIONS]";
    print "  Dump Group Mode:  perl $0 -f groups.json --dump -g \"Group Pattern\"";
    print "  Cleanup Mode:     perl $0 --clean-cache [-c]";
    
    print "\nREQUIRED PARAMETERS (by mode):";
    print "  Posting Mode:     -f, -H, -s";
    print "  List Groups Mode: -f";
    print "  Dump Group Mode:  -f, -g";
    
    print "\nOPTIONS:";
    printf "  %-25s %s\n", "-h, --help", "Show this help message and exit";
    printf "  %-25s %s\n", "-n, --dry-run", "Simulate posting without making changes (default: off)";
    printf "  %-25s %s\n", "-d, --debug [LEVEL]", "Set debug level 0-3 (optional, default: 0)";
    printf "  %-25s %s\n", "-f, --groups-file FILE", "REQUIRED: Path to groups JSON file";
    printf "  %-25s %s\n", "-H, --history-file FILE", "REQUIRED for posting: Path to history JSON file";
    printf "  %-25s %s\n", "-s, --set-pattern PATTERN", "REQUIRED for posting: Regex for set titles";
    printf "  %-25s %s\n", "-g, --group-pattern PATTERN", "Regex for group names (optional)";
    printf "  %-25s %s\n", "-e, --exclude PATTERN", "Regex for temporary group exclusion (optional)";
    printf "  %-25s %s\n", "-a, --max-age [YEARS]", "Max photo age in years (optional, default: none)";
    printf "  %-25s %s\n", "-t, --timeout [SECONDS]", "Max pause between posts (optional, default: 100)";
    printf "  %-25s %s\n", "-p, --persistent", "Make -e exclusion permanent (updates groups file)";
    printf "  %-25s %s\n", "-c, --clean", "Remove all persistent exclusions from groups file";
    printf "  %-25s %s\n", "--clean-cache", "Remove photo cache file on startup";
    printf "  %-25s %s\n", "-i, --ignore-excludes", "Ignore all exclusion flags (temp/persistent)";
    printf "  %-25s %s\n", "-l, --list-groups", "List groups and exit (requires -f)";
    printf "  %-25s %s\n", "--dump", "Dump detailed group info (requires -f and -g)";
    
    print "\nOPTIONAL VALUE FLAGS (can be used without value for default):";
    print "  -d, --debug       (default: 0)";
    print "  -a, --max-age     (default: 1 year when used without value)";
    print "  -t, --timeout     (default: 100 seconds when used without value)";
    
    print "\nDETAILED EXAMPLES:";
    print "  Post to Nature groups from Vacation sets, max 2-year old photos:";
    print "    perl $0 -f groups.json -H history.json -s \"Vacation\" -g \"Nature\" -a 2 -d 1";
    print "  List all Landscape groups with eligibility status:";
    print "    perl $0 -f groups.json -l -g \"Landscape\"";
    print "  Dry-run test with debug output:";
    print "    perl $0 -f groups.json -H history.json -s \"Travel\" -g \"City\" -n -d 2";
    print "  Post excluding test groups, make exclusion permanent:";
    print "    perl $0 -f groups.json -H history.json -s \"My Photos\" -e \"test\" -p";
    print "  Clean cache and remove all exclusions:";
    print "    perl $0 --clean-cache -c";
    print "  Dump detailed info for specific group:";
    print "    perl $0 -f groups.json --dump -g \"Exact Group Name\"";
    
    print "\nNOTES:";
    print "  - Requires Flickr authentication tokens in '\$ENV{HOME}/saved-flickr.st'";
    print "  - Group list cache refreshes automatically every 24 hours";
    print "  - Photo cache persists for 30 days with automatic expiration";
    print "  - Script automatically restarts on fatal errors with exponential backoff";
}

# Filters the main group list based on command-line patterns and static eligibility checks
# Returns arrayref of groups that match all filter criteria
sub filter_eligible_groups {
    my ($groups_ref, $group_match_rx, $exclude_match_rx) = @_;
    return [ grep {
        my $g = $_;
        my $gname = $g->{name} || '';
        # 1. Must be able to post statically
        $g->{can_post} == 1 &&
        # 2. Must not be persistently excluded (unless --ignore-excludes is set)
        ( $ignore_excludes || !defined $g->{excluded} ) &&
        # 3. Must match the group pattern (-g)
        ( !defined $group_match_rx || $gname =~ $group_match_rx ) &&
        # 4. Must NOT match the temporary exclusion pattern (-e)
        ( !defined $exclude_match_rx || $gname !~ $exclude_match_rx )
    } @$groups_ref ];
}

# Initializes the Flickr API and retrieves the user NSID
# Returns 1 on success, 0 on failure
sub init_flickr {
    # Calculate max age timestamp if the max-age option is used
    if (defined $max_age_years) {
        $max_age_timestamp = time() - ($max_age_years * 365 * 24 * 60 * 60);
    }
    my $config_file = "$ENV{HOME}/saved-flickr.st";
    $flickr = Flickr::API->import_storable_config($config_file);
    
    # Test connection and authentication
    my $response = flickr_api_call('flickr.test.login', {}); 
    
    unless (defined $response) { 
        fatal("Initial Flickr connection (flickr.test.login) failed after retries.");
        return 0;
    }
    
    $user_nsid = $response->as_hash->{user}->{id};
    debug("Logged in as $user_nsid");
    return 1;
}

# Refreshes the list of groups, fetches detailed info (like moderation status and throttle)
# for each, and saves the updated list to the groups file.
# Returns arrayref of updated groups on success, cached list on failure
sub update_and_store_groups {
    my $old_groups_ref = shift;
    $old_groups_ref = load_groups() // [] unless 'ARRAY' eq ref $old_groups_ref;
    debug("Refreshing group list from Flickr API...");
    
    # Get the list of all groups the user is a member of
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
        
        # Get detailed group info (crucial for throttle and moderation data)
        my $response = flickr_api_call('flickr.groups.getInfo', { group_id => $gid });
        unless (defined $response) { 
            alert("Failed to fetch info for '$gname' ($gid). Skipping.");
            next;
        }

        my $data = $response->as_hash->{group};
        my $throttle = $data->{throttle} || {};
        
        # Determine moderation status
        my $is_pool_moderated = 0 | $data->{ispoolmoderated} // 0;
        my $is_moderate_ok    = 0 | $data->{restrictions}->{moderate_ok} // 0;
        my $is_group_moderated = $is_pool_moderated || $is_moderate_ok;

        # Determine static posting permissions
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
        
        # Preserve existing persistent exclusion status
        $entry->{excluded} = $g_old->{excluded} if $g_old and $g_old->{excluded};

        push @results, $entry;
    }
    save_groups(\@results);
    return \@results;
}

# Manages persistent group exclusions based on command-line flags (--clean, --persistent)
# Returns arrayref of updated groups
sub update_local_group_exclusions {
    my $groups_ref = load_groups() // [];
    my @results;
    my $changes_made = 0;
    my $exclude_rx = qr/($exclude_pattern)/si if defined $exclude_pattern;
    
    debug("Updating local group exclusion flags based on command-line arguments.");
    
    foreach my $entry (@$groups_ref) {
        my $gname = $entry->{name};
        my $original_excluded = $entry->{excluded};

        # 1. Handle --clean: removes all existing persistent exclusions
        if ($clean_excludes and defined $entry->{excluded}) {
            delete $entry->{excluded};
            $changes_made++;
            debug("CLEAN: Removed exclusion from '$gname'");
        }

        # 2. Handle --persistent: adds new exclusion based on -e pattern
        if ($persistent_exclude and defined $exclude_pattern and ($gname =~ $exclude_rx)) {
             # Add or overwrite the exclusion
             if (!defined $entry->{excluded} || $entry->{excluded}->{pattern} ne $exclude_pattern) {
                $entry->{excluded} = { pattern => $exclude_pattern, string => $1 };
                $changes_made++;
                debug("PERSISTENT: Added exclusion to '$gname'");
             }
        }
        
        push @results, $entry;
    }
    
    if ($changes_made) {
        info("Saved $changes_made exclusion changes to $groups_file (local update).");
        save_groups(\@results);
    } else {
        debug("No local exclusion changes detected.");
    }
    
    return \@results;
}

# Fetches and prints detailed real-time information for groups matching the -g pattern (dump mode)
sub dump_matching_group_info {
    my ($groups_list_ref, $group_match_rx) = @_;
    
    info("DUMP MODE: Searching for groups matching '$group_pattern'...");
    
    my @matching_groups = grep {
        my $gname = $_->{name} || '';
        $gname =~ $group_match_rx;
    } @$groups_list_ref;
    
    unless (@matching_groups) {
        alert("No groups found in $groups_file matching pattern '$group_pattern'.");
        return;
    }
    
    my $dump_count = 0;
    foreach my $group_entry (@matching_groups) {
        my $group_id = $group_entry->{id};
        my $group_name = $group_entry->{name};
        
        info("Fetching real-time data for '$group_name' ($group_id)...");
        
        my $response = flickr_api_call('flickr.groups.getInfo', { group_id => $group_id });
        
        if (defined $response) {
            info("DUMP RESULT for '$group_name' ($group_id):");
            print Dumper($response->as_hash);
            $dump_count++;
        } else {
            error("Failed to fetch info for '$group_name' ($group_id). API error.");
        }
    }
    
    info("Dump finished. Displayed info for $dump_count group(s).");
}

# Checks the real-time posting status and throttle limit for a group
# Returns hashref with current posting eligibility and limit information
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
    
    # Check if the user is currently allowed to post based on the remaining count
    my $can_post_current = ($limit_mode eq 'none') || ($remaining > 0);
    return { 
        can_post => $can_post_current, 
        limit_mode => $limit_mode,
        remaining => $remaining + 0,
    };
}

# Selects a random photo from the list of matching photosets, using cached set pages
# Returns hashref with photo data or undef if no suitable photo found
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

        debug("Selected set: $selected_set->{title} ($set_id)");

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

            # --- Photo Page Cache Logic ---
            my $cache_key = "$set_id:$random_page";
            my $photos_on_page; 

            # 1. Check if valid data exists in cache
            if (exists $photo_cache{$cache_key}) {
                my $entry = $photo_cache{$cache_key};
                if (time() - $entry->{timestamp} < CACHE_EXPIRATION) {
                    debug("CACHE HIT: Using cached photos for Set $set_id, Page $random_page") if defined $debug and $debug > 1;
                    $photos_on_page = $entry->{photos};
                } else {
                    debug("CACHE EXPIRED: Entry for Set $set_id, Page $random_page is too old.") if defined $debug and $debug > 1;
                    delete $photo_cache{$cache_key};
                }
            }

            # 2. Fetch from API if cache missed or expired
            unless (defined $photos_on_page) {
                debug("CACHE MISS: Fetching API for Set $set_id, Page $random_page") if defined $debug and $debug > 1;
                
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
                save_photo_cache(); 
            }
            
            unless (@$photos_on_page) { 
                info("Page $random_page returned no public photos.");
                next PAGE_LOOP; 
            }

            my @photo_indices_to_try = (0..$#{$photos_on_page});
            
            PHOTO_LOOP: while (@photo_indices_to_try) {
                my $index_to_try = int(rand(@photo_indices_to_try));
                my $random_photo_index = $photo_indices_to_try[$index_to_try];
                my $selected_photo = $photos_on_page->[$random_photo_index];
                
                splice(@photo_indices_to_try, $index_to_try, 1);
                
                debug("Trying photo index $random_photo_index (ID: $selected_photo->{id}, Title: $selected_photo->{title})");

                # Filter by max age
                if (defined $max_age_timestamp && $selected_photo->{datetaken}) {
                    my $date_taken = $selected_photo->{datetaken};
                    my $photo_timestamp;
                    
                    if ($date_taken =~ /^(\d{4})-(\d{2})-(\d{2})\s+(\d{2}):(\d{2}):(\d{2})$/) {
                        $photo_timestamp = Time::Local::timelocal($6, $5, $4, $3, $2-1, $1-1900);
                    } 
                    elsif ($date_taken =~ /^(\d{4})-(\d{2})-(\d{2})$/) {
                        $photo_timestamp = Time::Local::timelocal(0, 0, 0, $3, $2-1, $1-1900);
                    }

                    if (defined $photo_timestamp && $photo_timestamp < $max_age_timestamp) {
                        debug("PHOTO REJECTED: $selected_photo->{title} is older than max age filter (Epoch $photo_timestamp < $max_age_timestamp)") if defined $debug and $debug > 1;
                        next PHOTO_LOOP; 
                    }
                }

                # Return the selected photo data
                return {
                    id => $selected_photo->{id},
                    title => $selected_photo->{title} || 'Untitled Photo',
                    set_title => $selected_set->{title} || 'Untitled Set',
                    set_id => $set_id,
                };
            }
        }
    }
    
    alert("Exhausted all matching sets, pages, and photos.");
    return;
}

# Checks if a specific photo is already a member of a group, utilizing persistent cache
# for a 30-day validity period.
# Returns 1 if photo is in group, 0 if not, undef on API failure
sub is_photo_in_group {
    my ($photo_id, $group_id) = @_;
    my $cache_key = "groupcheck:$photo_id:$group_id";
    my $now = time();

    # 1. Check persistent cache for membership status
    if (exists $photo_cache{$cache_key}) {
        my $entry = $photo_cache{$cache_key};
        if ($now - $entry->{timestamp} < CACHE_EXPIRATION) {
            # Cache Hit: return cached result
            debug("CACHE HIT: Group membership for $photo_id in $group_id is " . ($entry->{is_member} ? 'YES' : 'NO')) if defined $debug and $debug > 1;
            return $entry->{is_member};
        } else {
            # Cache Expired: delete entry and continue to API call
            debug("CACHE EXPIRED: Group membership entry for $cache_key is too old.") if defined $debug and $debug > 1;
            delete $photo_cache{$cache_key};
        }
    }
    
    # 2. API Call: Check all contexts for the photo
    my $response = flickr_api_call('flickr.photos.getAllContexts', { photo_id => $photo_id });
    unless (defined $response) { 
        alert("Failed to check photo context for $photo_id. API failed.");
        return undef; # Return undef on API failure
    }
    
    # Check if the group_id is present in the list of pools/groups
    my $photo_pools = $response->as_hash->{pool} || [];
    $photo_pools = [ $photo_pools ] unless ref $photo_pools eq 'ARRAY';
    my $is_present = grep { $_->{id} eq $group_id } @$photo_pools;

    # 3. Cache the result for 30 days
    my $is_present_bool = $is_present ? 1 : 0;
    $photo_cache{$cache_key} = {
        timestamp => $now,
        is_member => $is_present_bool,
    };
    save_photo_cache();
    
    return $is_present_bool; 
}

# Prints a formatted report of all groups and their eligibility status (list mode)
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

# Check for required parameters based on execution mode
unless ($groups_file) { push @missing_params, "-f (groups-file)"; }

unless ($list_groups || $dump) {
    unless ($history_file) { push @missing_params, "-H (history-file)"; }
    unless ($set_pattern) { push @missing_params, "-s (set-pattern)"; }
}

if ($dump && !defined $group_pattern) {
    push @missing_params, "-g (group-pattern) is required for --dump";
}

if (@missing_params) {
    fatal("Missing required parameters:");
    error("  " . join("\n  ", @missing_params));
    show_usage();
    exit 1; 
}

# Compile regex patterns and check for errors
my $group_match_rx = eval { qr/$group_pattern/i } if defined $group_pattern;
fatal("Invalid group pattern: $@") if $@;
my $exclude_match_rx = eval { qr/$exclude_pattern/i } if defined $exclude_pattern;
fatal("Invalid exclude pattern: $@") if $@;
unless ($list_groups || $dump) { 
    eval { qr/$set_pattern/ } if defined $set_pattern;
    fatal("Invalid set pattern: $@") if $@;
}

# Handle local group exclusion updates before main loop starts
my $force_refresh = $clean_excludes || $persistent_exclude;
if ($force_refresh) {
    update_local_group_exclusions(); 
}

# ----------------------------------------------------
# 1. Handle DUMP Mode (Independent execution path)
# ----------------------------------------------------
if ($dump) {
    unless (init_flickr()) {
        fatal("Initial Flickr connection failed.");
    }
    my $groups_list_ref = load_groups();
    
    # Ensure groups list is recent before dumping
    if (!defined $groups_list_ref or !@$groups_list_ref or (time() - $groups_list_ref->[0]->{timestamp} > GROUP_UPDATE_INTERVAL)) {
        info("Group list cache is empty or expired. Refreshing from API...");
        $groups_list_ref = update_and_store_groups($groups_list_ref);
    }
    
    fatal("Cannot perform dump: Could not load or fetch group list.") unless defined $groups_list_ref and @$groups_list_ref;
    
    dump_matching_group_info($groups_list_ref, $group_match_rx);
    exit;
}
# ----------------------------------------------------
# 2. Handle LIST Mode (Independent execution path)
# ----------------------------------------------------
if ($list_groups) {
    unless (init_flickr()) {
        fatal("Initial Flickr connection failed.");
    }
    my $groups_list_ref = load_groups();
    # Ensure list is up-to-date
    $groups_list_ref = update_and_store_groups($groups_list_ref) unless defined $groups_list_ref and @$groups_list_ref;
    fatal("Cannot list groups: Could not load or fetch group list.") unless defined $groups_list_ref and @$groups_list_ref;
    list_groups_report($groups_list_ref, $group_match_rx, $exclude_match_rx);
    exit;
}

# ----------------------------------------------------
# 3. MASTER RESTART LOOP (Main Posting Flow)
# The entire posting logic is wrapped in this loop for self-healing/backoff.
# ----------------------------------------------------
my $restart_attempt = 0;

RESTART_LOOP: while (1) {
    $restart_attempt++;

    eval {
        alert("\n--- Starting main script execution attempt #$restart_attempt ---\n") if $restart_attempt > 1; 
        
        # 1. Initialization
        unless (init_flickr()) { 
            die "FATAL: Initial Flickr connection (flickr.test.login) failed."; 
        }
        
        # Load/update group list cache (refreshing if too old)
        my $groups_list_ref = load_groups();
        $groups_list_ref = update_and_store_groups($groups_list_ref) unless defined $groups_list_ref and @$groups_list_ref;

        # Apply user filters to get the initial list of eligible groups
        @all_eligible_groups = @{ filter_eligible_groups($groups_list_ref, $group_match_rx, $exclude_match_rx) };
        unless (@all_eligible_groups) {
            die "No groups match all required filters.";
        }
        debug("Found " . scalar(@all_eligible_groups) . " groups eligible for posting.");

        # Fetch and filter photosets based on set-pattern
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
        debug("Found " . scalar(@matching_sets) . " matching sets.");
        
        # Load persistent cooldown history and photo/group cache
        load_history();
        load_photo_cache(); 

        # 3. Main Continuous Posting Loop
        my $post_count = 0;

        POST_CYCLE_LOOP: while (1) { 
            
            # Check for stale group cache and refresh if needed
            if ($groups_list_ref->[0] and time() - $groups_list_ref->[0]->{timestamp} > GROUP_UPDATE_INTERVAL) {
                debug("Group list cache expired. Initiating update.");
                
                my $new_groups_ref = update_and_store_groups();
                if (defined $new_groups_ref) {
                    $groups_list_ref = $new_groups_ref;
                } else {
                    alert("Failed to update group list. Continuing with old cache.");
                }
                
                # Re-apply filters after refreshing the full list
                @all_eligible_groups = @{ filter_eligible_groups($groups_list_ref, $group_match_rx, $exclude_match_rx) };
                debug("Group list refreshed. Found " . scalar(@all_eligible_groups) . " eligible groups.");
            }
            
            # Filter groups against dynamic cooldowns (history)
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
                debug("Failed to find suitable photo in any matching sets.");
                my $short_sleep = int(rand(10)) + 5; 
                info("No suitable photo found. Pausing for $short_sleep seconds before restarting cycle.");
                sleep $short_sleep;
                next POST_CYCLE_LOOP; 
            }
            
            my ($photo_id, $photo_title, $set_title, $set_id) = @$photo_data{qw/id title set_title set_id/};
            info("Selected photo '$photo_title' from set '$set_title' for this cycle.");

            # 5. Main Posting Attempt Loop (Try the selected photo on groups)
            POST_ATTEMPT_LOOP: while (@current_groups) { 

                my $random_index = int(rand(@current_groups));
                my $selected_group = $current_groups[$random_index];
                
                unless (defined $selected_group && defined $selected_group->{id}) { 
                    alert("Unexpected: selected group is missing ID. Removing from current cycle.");
                    splice(@current_groups, $random_index, 1);
                    next POST_ATTEMPT_LOOP;
                }

                my $group_id = $selected_group->{id};
                my $group_name = $selected_group->{name};
                
                # Dynamic Status Check (Real-time throttle based on remaining count)
                if ($selected_group->{limit_mode} ne 'none' || $selected_group->{moderated} == 1) {
                    my $status = check_posting_status($group_id, $group_name);
                    $selected_group->{limit_mode} = $status->{limit_mode};
                    $selected_group->{remaining} = $status->{remaining};
                    unless ($status->{can_post}) { 
                        debug("Skipping '$group_name' (Dynamic Block: $status->{limit_mode} or Remaining=0)");
                        # Cooldown Curto para Dynamic Block
                        apply_short_cooldown($group_id, $group_name, "Dynamic Block ($status->{limit_mode} / $status->{remaining} remaining)"); 
                        splice(@current_groups, $random_index, 1); 
                        next POST_ATTEMPT_LOOP;
                    }
                }

                # Last Poster Check: Avoid posting if the user was the last to post in the group
                my $response = flickr_api_call('flickr.groups.pools.getPhotos', { group_id => $group_id, per_page => 1 });
                unless (defined $response) { 
                    alert("Failed to check last poster for group '$group_name'. Removing from current cycle.");
                    splice(@current_groups, $random_index, 1); 
                    next POST_ATTEMPT_LOOP;
                }
                my $photos = $response->as_hash->{photos}->{photo} || [];
                $photos = [ $photos ] unless ref $photos eq 'ARRAY';
                if (@$photos and $photos->[0]->{owner} eq $user_nsid) { 
                    debug("Skipping '$group_name' (You are last poster)");
                    # Cooldown Curto para Last Poster
                    apply_short_cooldown($group_id, $group_name, "Last Poster Detected"); 
                    splice(@current_groups, $random_index, 1); 
                    next POST_ATTEMPT_LOOP;
                }
                
                # Check if photo is ALREADY IN GROUP (Uses the 30-day persistent cache)
                my $in_group_check = is_photo_in_group($photo_id, $group_id);
                unless (defined $in_group_check) { 
                    alert("Failed to check group membership for photo '$photo_title' in group '$group_name'. Removing from current cycle.");
                    splice(@current_groups, $random_index, 1);
                    next POST_ATTEMPT_LOOP;
                }
                elsif ($in_group_check) { 
                    debug("Photo '$photo_title' already in '$group_name'.");
                    splice(@current_groups, $random_index, 1); # Remove group from this photo's cycle
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
                        
                        my $detailed_log_message = "photo '$photo_title' ($photo_id) to group '$group_name' ($group_id)";

                        if ($moderated_pending) {
                            info("Added " . $detailed_log_message . ". Status: Moderated - Pending Queue.");
                        } else {
                            success("Added " . $detailed_log_message);
                        }
                        
                        # Immediately update the group membership cache (status: member)
                        update_group_membership_cache($photo_id, $group_id, 1) unless $moderated_pending;

                        # Aplicar Cooldown Curto (20-60 min) para grupos não moderados e sem limite
                        if ($selected_group->{moderated} == 0 && $selected_group->{limit_mode} eq 'none' ) {
                            apply_short_cooldown($group_id, $group_name, "Successful Post (Non-Limited)");
                        }

                        # Apply cooldown for moderated groups (1 day timeout)
                        if ($selected_group->{moderated} == 1) {
                             $moderated_post_history{$group_id} = { post_time => time(), photo_id  => $photo_id };
                             save_history();
                             info("Moderated group detected. Group '$group_name' set to " . MODERATED_POST_TIMEOUT . " second cooldown.");
                        }

                        # Apply rate limit cooldown
                        if ($selected_group->{limit_mode} ne 'none') {
                             my $limit = $selected_group->{limit_count} || 1; 
                             my $period_seconds = $selected_group->{limit_mode} eq 'day' ? SECONDS_IN_DAY : $selected_group->{limit_mode} eq 'week' ? SECONDS_IN_WEEK : $selected_group->{limit_mode} eq 'month' ? SECONDS_IN_MONTH : 0;

                            if ($limit > 0 && $period_seconds > 0) {
                                # Calculate randomized pause time based on limit/period
                                my $base_pause_time = $period_seconds / $limit;
                                my $random_multiplier = 0.7 + (rand() * 0.4); 
                                my $pause_time = int($base_pause_time * $random_multiplier);
                                $pause_time = 1 unless $pause_time > 0;
                                my $wait_until = time() + $pause_time;
                                $rate_limit_history{$group_id} = { wait_until => $wait_until, limit_mode => $selected_group->{limit_mode} };
                                save_history();
                                info("Group '$group_name' posted to (limit $limit/$selected_group->{limit_mode}). Applying randomized $pause_time sec cooldown.");
                            }
                        }                       
                        $post_count++;
                        last POST_ATTEMPT_LOOP; # Photo successfully added to a group, move to the next photo cycle
                    } else {
                        my $error_msg = $response->{error_message} || 'Unknown API Error';
                        error("Failed to add photo: $error_msg");
                        
                        # Handle specific permanent/long-cooldown errors
                        if ($error_msg =~ /Photo limit reached/i) {
                            my $pause_time = SECONDS_IN_DAY; 
                            $rate_limit_history{$group_id} = { wait_until => time() + $pause_time, limit_mode => 'day' };
                            save_history();
                            alert("Group '$group_name' hit Photo limit. Applying day cooldown and removing group from cycle.");
                        } elsif ($error_msg =~ /Content not allowed/i) {
                            alert("Group '$group_name' rejected photo due to 'Content not allowed'. Removing group from cycle.");
                        } 
                        
                        # On any final failure, the group is removed from the current photo's cycle
                        splice(@current_groups, $random_index, 1); 
                        next POST_ATTEMPT_LOOP; 
                    }
                }
            } 

            # Apply random delay between posting attempts
            my $sleep_time = int(rand($timeout_max + 1));
            info("Pausing for $sleep_time seconds.");
            sleep $sleep_time;
        } 
    }; 
    
    my $fatal_error = $@;
    if ($fatal_error) {
        fatal("FATAL SCRIPT CRASH (Attempt #$restart_attempt): $fatal_error");        
    }
    
    # Calculate exponential backoff delay for the restart loop
    my $delay = int((RESTART_RETRY_BASE * (RESTART_RETRY_FACTOR ** ($restart_attempt - 1))) * (0.8 + rand() * 0.4));
    $delay = MAX_RESTART_DELAY if $delay > MAX_RESTART_DELAY;
    info("Restarting in $delay seconds...");
    sleep $delay;
}