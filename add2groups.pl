#!/usr/bin/perl
# add2groups.pl
#
# PURPOSE:
# Automated Flickr group posting system that intelligently shares photos from matching photosets
# to eligible groups while respecting rate limits, moderation queues, and cooldown periods.
#
# CORE FUNCTIONALITY:
# - Matches photosets using regex patterns
# - Filters groups based on permissions and user patterns  
# - Implements comprehensive cooldown system for moderated/rate-limited groups
# - Self-healing design with exponential backoff for API failures
# - Persistent history tracking across script restarts
#
# RELIABILITY FEATURES:
# - **MASTER RESTART LOOP:** Infinite self-healing loop with exponential backoff for fatal errors
# - **Robust API Wrapper:** Retry logic with exponential backoff for transient network issues
# - **File Locking (flock):** Prevents corruption of history and cache files during concurrent access
# - **Dynamic Cooldowns:** Smart tracking of rate-limited and moderated groups to prevent spam
# - **Multi-level Random Selection:** Efficient photo selection across sets, pages, and photos
#
# USAGE:
# perl add2groups.pl -f groups.json -H history.json -s "Set Title Pattern" -a 2
# perl add2groups.pl -l -f groups.json  <-- Modo de listagem simplificado
#
# CRITICAL DEPENDENCIES:
# - Flickr::API, JSON, Time::HiRes, Fcntl modules
# - Flickr authentication tokens in '$ENV{HOME}/saved-flickr.st'
# - Write permissions for groups.json and history.json files

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

# Set output record separator to always print a newline
$\ = "\n";

# --- OUTPUT BUFFERING FIX ---
$| = 1;
select(STDERR); $| = 1; select(STDOUT);

# Global API and User Variables
my $flickr;                
my $user_nsid;             
my $debug;                 
my $max_age_timestamp;     
my @all_eligible_groups;   
my @matching_sets;         


# --- Command-line options and defaults ---
my ($help, $dry_run, $groups_file, $set_pattern, $group_pattern, $exclude_pattern, $max_age_years, $timeout_max);
my ($persistent_exclude, $clean_excludes, $ignore_excludes, $list_groups, $history_file);

$timeout_max = 300;

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
    'i|ignore-excludes'   => \$ignore_excludes,
    'l|list-groups'       => \$list_groups,
);

# --- Constants ---
use constant GROUP_UPDATE_INTERVAL  => 24 * 60 * 60;  # Time until group list is considered stale (1 day)
use constant GROUP_EXHAUSTED_DELAY  => 60 * 60;       # Delay if no groups are eligible (1 hour)

use constant MODERATED_POST_TIMEOUT => 24 * 60 * 60; # Cooldown for a moderated group before checking if photo is visible (1 day)

use constant SECONDS_IN_DAY   => 24 * 60 * 60;
use constant SECONDS_IN_WEEK  => 7 * SECONDS_IN_DAY;
use constant SECONDS_IN_MONTH => 30 * SECONDS_IN_DAY;

use constant MAX_API_RETRIES      => 5;   # Max attempts for transient API calls
use constant API_RETRY_MULTIPLIER => 8;   # Delay multiplier for API retries (1, 8, 64, ...)

use constant MAX_RESTART_DELAY    => 24 * 60 * 60; # Maximum delay for the master restart loop (24 hours)
use constant RESTART_RETRY_BASE   => 60;           # Initial delay for master restart (60 seconds)
use constant RESTART_RETRY_FACTOR => 2;            # Multiplier for master restart delay
use constant MAX_TRIES => 100;                     # Max attempts to find a group/photo combo in a cycle

# --- Helper Subroutines ---

sub debug_print {
    return unless defined $debug;
    my ($message, $data) = @_;
    say "Debug: $message" . (defined $data && $debug > 2 ? Dumper($data) : '');
}

sub flickr_api_call {
    my ($method, $args) = @_;
    my $retry_delay = 1;

    say "Debug: API CALL: $method" if defined $debug and $debug > 0;

    for my $attempt (1 .. MAX_API_RETRIES) {
        my $response = eval { $flickr->execute_method($method, $args) };

        if ($@ || !defined $response || !$response->{success}) {
            
            my $error = $response->{error_message} || $@ || 'Unknown error';
            warn "Attempt $attempt failed for $method: $error"; 

            # Special case: Moderated groups often return an "error" but the post is accepted into the queue
            if ($method eq 'flickr.groups.pools.add' and $error =~ /Pending Queue for this Pool/i) {
                say "Debug: Moderated Group Success Detected: $error. Treating as successful and non-retryable." if defined $debug;
                return $response; # Success via moderation queue
            }

            # Special case: Group is full/limit reached (non-retryable error, requires cooldown/manual intervention)
            if ($method eq 'flickr.groups.pools.add' and $error =~ /Photo limit reached/i) {
                warn "Warning: Non-retryable Error detected for $method: $error. Aborting retries.";
                return $response; # Failure, but known and handled later
            }

            if ($attempt == MAX_API_RETRIES) {
                warn "FATAL: Failed to execute $method after " . MAX_API_RETRIES . " attempts: $error";
                return undef; # Fatal API failure
            }
            # Apply exponential backoff
            sleep $retry_delay;
            $retry_delay *= API_RETRY_MULTIPLIER;
            next;
        }
        return $response; # API call successful
    }
    return undef; # Should be unreachable if last attempt returns undef on error
}

# --- File I/O Utility Subroutines (Non-Fatal & Safe) ---

sub _write_file {
    my ($file_path, $content) = @_;
    my $fh; 

    unless (open $fh, '>:encoding(UTF-8)', $file_path) {
        warn "Warning: Cannot open $file_path for writing: $!"; 
        return undef;
    }

    # Acquire exclusive lock
    unless (flock($fh, LOCK_EX)) {
        warn "Warning: Failed to acquire exclusive lock on $file_path. Skipping write.";
        close $fh;
        return undef;
    }

    eval {
        print $fh $content;
    };
    
    flock($fh, LOCK_UN); # Release lock
    close $fh;

    if ($@) {
        warn "Warning: Error during writing to $file_path: $@";
        return undef;
    }
    
    return 1;
}

sub _read_file {
    my $file_path = shift;
    my $fh; 

    return undef unless -e $file_path;
    say "Debug: Accessing file $file_path" if defined $debug;

    unless (open $fh, '<:encoding(UTF-8)', $file_path) {
        warn "Warning: Cannot open $file_path for reading: $!"; 
        return undef;
    }

    # Acquire shared lock
    unless (flock($fh, LOCK_SH)) {
        say "Debug: Failed to acquire shared lock on $file_path. Skipping read." if defined $debug;
        close $fh;
        return undef;
    }

    my $content = eval { local $/; <$fh> };

    flock($fh, LOCK_UN); # Release lock
    close $fh;

    if ($@) {
        warn "Warning: Error reading $file_path: $@";
        return undef; 
    }
    
    return $content;
}

# --- High-Level File I/O Subroutines ---

sub save_groups {
    my $groups_ref = shift;
    my $json = JSON->new->utf8->pretty->encode({ groups => $groups_ref });
    unless (_write_file($groups_file, $json)) {
        warn "Warning: Failed to save group data to $groups_file. Current group state is not persisted.";
        return 0;
    }
    say "Info: Group list cache written to $groups_file" if defined $debug;
    return 1;
}

sub load_groups {
    say "Debug: Loading groups from $groups_file" if defined $debug;
    my $json_text = _read_file($groups_file) or return undef;
    my $data = eval { decode_json($json_text) };
    if ($@) {
           warn "Error decoding JSON from $groups_file: $@. Cannot load cached data." if defined $debug;
           return undef;
    }
    return $data->{groups} // [];
}

sub save_history {
    # Só salva se $history_file estiver definido (necessário apenas para modo de postagem)
    return unless defined $history_file; 
    
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
    say "Info: Cooldown history written to $history_file" if defined $debug;
    return 1;
}

sub load_history {
    # Só carrega se $history_file estiver definido (necessário apenas para modo de postagem)
    return unless defined $history_file; 
    
    say "Debug: Loading history from $history_file" if defined $debug;
    my $json_text = _read_file($history_file) or return;
    my $data = eval { decode_json($json_text) };
    if ($@) {
           warn "Error decoding JSON from $history_file: $@. Cannot load history data." if defined $debug;
           return;
    }
    %moderated_post_history = %{$data->{moderated} // {}};
    %rate_limit_history     = %{$data->{ratelimit} // {}};
    say "Debug: History loaded. Moderated count: " . scalar(keys %moderated_post_history) . ", Rate limit count: " . scalar(keys %rate_limit_history) if defined $debug;
}

# --- Main Logic Subroutines ---

sub show_usage {
    print "Usage: $0 [OPTIONS]";
    print "Options:";
    printf "  %-20s %s\n", "-h, --help", "Show help message and exit";
    printf "  %-20s %s\n", "-n, --dry-run", "Simulate adding without making changes (highly recommended for testing)";
    printf "  %-20s %s\n", "-d, --debug", "Set debug level. Prints verbose execution info (0-3)";
    printf "  %-20s %s\n", "-f, --groups-file", "Path to store/read group JSON data (Required for ALL modes)";
    printf "  %-20s %s\n", "-H, --history-file", "Path to store/read dynamic cooldown history (Required for posting mode)";
    printf "  %-20s %s\n", "-s, --set-pattern", "Regex pattern to match set titles (Required for posting mode)";
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

sub filter_eligible_groups {
    my ($groups_ref, $group_match_rx, $exclude_match_rx) = @_;
    return [ grep {
        my $g = $_;
        my $gname = $g->{name} || '';
        # Check static permissions/filters
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
    
    unless (defined $response) { # Changed: if (!defined $response)
        die "FATAL: Initial Flickr connection (flickr.test.login) failed after retries.";
    }
    
    $user_nsid = $response->as_hash->{user}->{id};
    say "Debug: Logged in as $user_nsid" if defined $debug;
    return 1;
}

sub update_and_store_groups {
    my $old_groups_ref = shift;
    # Load from file if not provided/empty
    $old_groups_ref = load_groups() // [] unless 'ARRAY' eq ref $old_groups_ref;
    say "Info: Refreshing group list from Flickr API..." if defined $debug;
    
    my $response = flickr_api_call('flickr.groups.pools.getGroups', {});
    unless (defined $response) { # Changed: if (!defined $response)
        warn "Warning: Failed to fetch complete group list from Flickr API. Returning existing cached list.";
        return $old_groups_ref; # Return old cache on API failure
    }
    
    my $new_groups_raw = $response->as_hash->{groups}->{group} || [];
    $new_groups_raw = [ $new_groups_raw ] unless ref $new_groups_raw eq 'ARRAY';
    my %old_groups_map = map { $_->{id} => $_ } @$old_groups_ref;
    my @results;
    my $timestamp_epoch = time();
    my $exclude_rx = qr/($exclude_pattern)/si if defined $exclude_pattern;
    
    # Iterate through all fetched groups and update their details one by one
    foreach my $g_raw (@$new_groups_raw) {
        my $gid   = $g_raw->{nsid};
        my $gname = $g_raw->{name};
        my $g_old = $old_groups_map{$gid};
        
        my $response = flickr_api_call('flickr.groups.getInfo', { group_id => $gid });
        unless (defined $response) { # Changed: if (!defined $response)
            warn "Warning: Failed to fetch info for group '$gname' ($gid). API failed after retries. Skipping this group.";
            next;
        }
        
        my $data = $response->as_hash->{group};
        my $throttle = $data->{throttle} || {};
        
        # Determine moderation status
        my $is_pool_moderated = 0 | $data->{ispoolmoderated} // 0;
        my $is_moderate_ok    = 0 | $data->{restrictions}->{moderate_ok} // 0;
        my $is_group_moderated = $is_pool_moderated || $is_moderate_ok;

        # Determine posting permissions
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
        
        # Preserve existing permanent exclusions if any
        $entry->{excluded} = $g_old->{excluded} if $g_old and $g_old->{excluded};
        delete $entry->{excluded} if $clean_excludes;

        # Apply new permanent exclusion if requested
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

sub check_posting_status {
    my ($group_id, $group_name) = @_;
    
    my $response = flickr_api_call('flickr.groups.getInfo', { group_id => $group_id });
    unless (defined $response) { # Changed: if (!defined $response)
        warn "Warning: Failed to fetch dynamic posting status for group '$group_name'. API failed after retries. Returning safe failure status.";
        return { can_post => 0, limit_mode => 'unknown_error', remaining => 0 };
    }
    
    my $data = $response->as_hash->{group};
    my $throttle = $data->{throttle} || {};
    my $limit_mode = $throttle->{mode} // 'none';
    my $remaining = $throttle->{remaining} // 0;
    
    # Check if we can post dynamically (i.e., not rate-limited out)
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

        say "Debug: Selected set: $selected_set->{title} ($set_id)" if defined $debug;

        # Remove set from the pool to avoid re-selecting it for this cycle
        splice(@sets_to_try, $set_index, 1);
        $used_set_ids{$set_id} = 1;

        next SET_LOOP if $total == 0; 
        
        $used_pages_by_set{$set_id} = {} unless exists $used_pages_by_set{$set_id};
        my $max_page = int(($total - 1) / $PHOTOS_PER_PAGE) + 1;
        my @pages_to_try = (1..$max_page);

        PAGE_LOOP: while (@pages_to_try) {
            my $page_index = int(rand(@pages_to_try));
            my $random_page = $pages_to_try[$page_index];
            
            # Remove page from the pool to avoid re-selecting it for this set
            splice(@pages_to_try, $page_index, 1);
            $used_pages_by_set{$set_id}->{$random_page} = 1;

            my $get_photos_params = { 
                photoset_id => $set_id, 
                per_page => $PHOTOS_PER_PAGE, 
                page => $random_page,
                privacy_filter => 1, # Only get public photos
                extras => 'date_taken',
            };

            my $response = flickr_api_call('flickr.photosets.getPhotos', $get_photos_params); 

            unless (defined $response) { # Changed: if (!defined $response)
                warn "Warning: Failed to fetch photos from set '$selected_set->{title}' ($set_id). API failed after retries. Skipping to next set.";
                last PAGE_LOOP; # Go to next SET_LOOP iteration
            }
            
            my $photos_on_page = $response->as_hash->{photoset}->{photo} || [];
            $photos_on_page = [ $photos_on_page ] unless ref $photos_on_page eq 'ARRAY';
            
            unless (@$photos_on_page) { # Changed: if (!@$photos_on_page)
                say "Debug: Page $random_page returned no public photos." if defined $debug;
                next PAGE_LOOP; 
            }

            my @photo_indices_to_try = (0..$#{$photos_on_page});
            
            PHOTO_LOOP: while (@photo_indices_to_try) {
                my $index_to_try = int(rand(@photo_indices_to_try));
                my $random_photo_index = $photo_indices_to_try[$index_to_try];
                my $selected_photo = $photos_on_page->[$random_photo_index];
                
                # Remove photo index to avoid re-selecting it for this page
                splice(@photo_indices_to_try, $index_to_try, 1);
                
                # Filter by max age if required
                if (defined $max_age_timestamp && $selected_photo->{datetaken}) {
                    my $date_taken = $selected_photo->{datetaken};
                    my $photo_timestamp;
                    
                    # Attempt to parse date_taken in known formats
                    if ($date_taken =~ /^(\d{4})-(\d{2})-(\d{2})\s+(\d{2}):(\d{2}):(\d{2})$/) {
                        $photo_timestamp = Time::Local::timelocal($6, $5, $4, $3, $2-1, $1-1900);
                    } 
                    elsif ($date_taken =~ /^(\d{4})-(\d{2})-(\d{2})$/) {
                        $photo_timestamp = Time::Local::timelocal(0, 0, 0, $3, $2-1, $1-1900);
                    }

                    if (defined $photo_timestamp && $photo_timestamp < $max_age_timestamp) {
                        say "Debug: Photo '$selected_photo->{title}' ($selected_photo->{id}) is too old. Retrying photo." if defined $debug;
                        next PHOTO_LOOP; 
                    }
                }

                # Found a suitable photo
                return {
                    id => $selected_photo->{id},
                    title => $selected_photo->{title} || 'Untitled Photo',
                    set_title => $selected_set->{title} || 'Untitled Set',
                    set_id => $set_id,
                };
            }
        }
    }
    
    warn "Warning: Exhausted all matching sets, pages, and photos. No photos found that meet the maximum age requirement." if defined $debug;
    return;
}

sub is_photo_in_group {
    my ($photo_id, $group_id) = @_;
    
    # Use getAllContexts to check if the photo is already in the target group pool
    my $response = flickr_api_call('flickr.photos.getAllContexts', { photo_id => $photo_id });
    unless (defined $response) { # Changed: if (!defined $response)
        warn "Warning: Failed to check photo context for photo $photo_id. API failed after retries. Returning undef to signal temporary failure.";
        return undef;
    }
    
    my $photo_pools = $response->as_hash->{pool} || [];
    $photo_pools = [ $photo_pools ] unless ref $photo_pools eq 'ARRAY';
    my $is_present = grep { $_->{id} eq $group_id } @$photo_pools;
    return $is_present; # 1 if present, 0 otherwise
}

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


# --- MAIN EXECUTION FLOW ---

my @missing_params;

if ($help) {
    show_usage();
    exit;
}

# 1. Check required parameters for ALL modes
unless ($groups_file) { # Changed: if (!$groups_file)
    push @missing_params, "-f (groups-file)";
}

# 2. Check required parameters for POSTING mode (when -l is NOT present)
unless ($list_groups) { # Changed: if (!$list_groups)
    unless ($history_file) { # Changed: if (!$history_file)
        push @missing_params, "-H (history-file)";
    }
    unless ($set_pattern) { # Changed: if (!$set_pattern)
        push @missing_params, "-s (set-pattern)";
    }
}

# Output specific error message if any parameters are missing
if (@missing_params) {
    print "ERRO FATAL: Os seguintes parâmetros obrigatórios estão em falta ou inválidos:";
    print "  " . join("\n  ", @missing_params);
    print "---";
    show_usage();
    exit 1; # Exit with error status
}


# Compile and validate user-provided regex patterns
my $group_match_rx = eval { qr/$group_pattern/i } if defined $group_pattern;
die "Invalid group pattern '$group_pattern': $@" if $@;
my $exclude_match_rx = eval { qr/$exclude_pattern/i } if defined $exclude_pattern;
die "Invalid exclude pattern '$exclude_pattern': $@" if $@;
# Only validate set pattern if it's required (i.e., not listing)
unless ($list_groups) { # Changed: if (!$list_groups)
    eval { qr/$set_pattern/ } if defined $set_pattern;
    die "Invalid set pattern '$set_pattern': $@" if $@;
}

my $force_refresh = $clean_excludes || $persistent_exclude;

# Handle list-groups mode (early exit)
if ($list_groups) {
    unless (init_flickr()) {
        die "FATAL: Initial Flickr connection failed. Cannot proceed.";
    }
    my $groups_list_ref = load_groups();
    # Refresh cache if forced, if cache doesn't exist, or if cache is empty
    $groups_list_ref = update_and_store_groups($groups_list_ref) unless defined $groups_list_ref and !@$groups_list_ref;
    die "Cannot list groups: Could not load or fetch group list." unless defined $groups_list_ref and @$groups_list_ref;
    list_groups_report($groups_list_ref, $group_match_rx, $exclude_match_rx);
    exit;
}

# --- MASTER RESTART LOOP (Self-Healing Core) ---
my $restart_attempt = 0;

RESTART_LOOP: while (1) {
    $restart_attempt++;

    eval {
        warn "\n--- Starting main script execution attempt #$restart_attempt ---\n" if $restart_attempt > 1; 
        
        # 1. Initialization and Setup
        unless (init_flickr()) { # Changed: if (!init_flickr())
            # This should trigger the fatal error handling if it fails after retries in init_flickr's dependency
            die "FATAL: Initial Flickr connection (flickr.test.login) failed after retries.";
        }
        
        # Load/update group list cache
        my $groups_list_ref = load_groups();
        $groups_list_ref = update_and_store_groups($groups_list_ref) unless defined $groups_list_ref and !@$groups_list_ref;

        # Apply user filters
        @all_eligible_groups = @{ filter_eligible_groups($groups_list_ref, $group_match_rx, $exclude_match_rx) };
        unless (@all_eligible_groups) {
            die "No groups match all required filters.";
        }
        say "Info: Found " . scalar(@all_eligible_groups) . " groups eligible for posting after initial filter." if defined $debug;

        # Fetch and filter photosets
        my $response = flickr_api_call('flickr.photosets.getList', { user_id => $user_nsid }); 
        unless (defined $response) { # Changed: if (!defined $response)
            die "FATAL: Failed to fetch photoset list from API after retries.";
        }
        
        my $all_sets = $response->as_hash->{photosets}->{photoset} || [];
        $all_sets = [ $all_sets ] unless ref $all_sets eq 'ARRAY';
        @matching_sets = grep { ($_->{title} || '') =~ qr/$set_pattern/i } @$all_sets;

        unless (@matching_sets) { # Changed: if (!@matching_sets)
            die "No sets matching pattern '$set_pattern' found.";
        }
        say "Info: Found " . scalar(@matching_sets) . " matching sets." if defined $debug;
        
        # Load cooldown history
        load_history();

        # 3. Main Continuous Posting Loop
        my $post_count = 0;
        my $moderated_wait_time = MODERATED_POST_TIMEOUT;

        POST_CYCLE_LOOP: while (1) { 
            
            # Check for stale group cache and refresh periodically
            if ($groups_list_ref->[0] and time() - $groups_list_ref->[0]->{timestamp} > GROUP_UPDATE_INTERVAL) {
                say "Info: Group list cache expired. Initiating update." if defined $debug;
                
                my $new_groups_ref = update_and_store_groups();
                if (defined $new_groups_ref) {
                    $groups_list_ref = $new_groups_ref;
                } else {
                    warn "Warning: Failed to update group list cache. Will continue with old cache for now.";
                }
                
                # Re-apply filters after cache update
                @all_eligible_groups = @{ filter_eligible_groups($groups_list_ref, $group_match_rx, $exclude_match_rx) };
                say "Info: Master group list refreshed and re-filtered. Found " . scalar(@all_eligible_groups) . " eligible groups." if defined $debug;
            }
            
            my @current_groups = @all_eligible_groups;
            
            # Check if there are any eligible groups left after all checks
            unless (@current_groups) {
                warn "Warning: All groups filtered out due to checks/patterns. Entering long pause before attempting a new cycle." if defined $debug;
                
                print "No eligible groups to post to. Pausing for " . GROUP_EXHAUSTED_DELAY . " seconds to await new group eligibility (e.g., expired cooldowns, group list refresh).";
                sleep GROUP_EXHAUSTED_DELAY;
                
                next POST_CYCLE_LOOP;
            }

            print "\n--- Starting new posting cycle (Post #$post_count). Groups to attempt: " . scalar(@current_groups) . " ---";

            # 4. Find a suitable group/photo combination
            POST_ATTEMPT_LOOP: for (1 .. MAX_TRIES) { 
                unless (scalar @current_groups) { # Changed: unless (scalar @current_groups)
                    last POST_ATTEMPT_LOOP; # Exit if group pool is exhausted for this cycle
                }

                my $random_index = int(rand(@current_groups));
                my $selected_group = $current_groups[$random_index];
                
                unless (defined $selected_group && defined $selected_group->{id}) { # Changed: if (!defined $selected_group && !defined $selected_group->{id})
                    warn "Warning: Selected group at index $random_index is undefined or missing ID. Removing and retrying.";
                    splice(@current_groups, $random_index, 1) if $random_index < scalar @current_groups;
                    next POST_ATTEMPT_LOOP;
                }

                my $group_id = $selected_group->{id};
                my $group_name = $selected_group->{name};
                
                # 1. Rate Limit Cooldown Check
                if (defined $rate_limit_history{$group_id}) {
                    my $wait_until = $rate_limit_history{$group_id}->{wait_until};
                    if (time() < $wait_until) { 
                        say "Debug: Skipping group '$group_name' ($group_id). Rate limit cooldown active until " . scalar(localtime($wait_until)) if defined $debug;
                        splice(@current_groups, $random_index, 1); # Remove from current pool for this cycle
                        next POST_ATTEMPT_LOOP;
                    } else { 
                        say "Debug: Cooldown cleared for '$group_name' ($group_id). Rate limit history expired." if defined $debug;
                        delete $rate_limit_history{$group_id}; 
                        save_history();
                    }
                }
                
                # 2. Moderated Cooldown Check
                if ($selected_group->{moderated} == 1 and defined $moderated_post_history{$group_id}) {
                    my $history = $moderated_post_history{$group_id};
                    my $wait_until = $history->{post_time} + $moderated_wait_time;
                    # Check if the photo is now visible in the group (i.e., approved)
                    my $context_check = is_photo_in_group($history->{photo_id}, $group_id);

                    unless (defined $context_check) { # Changed: unless (defined $context_check)
                        say "Debug: Group '$group_name' ($group_id) failed photo context check (API error) for previous post. Retrying group later in cycle." if defined $debug;
                        next POST_ATTEMPT_LOOP;
                    } elsif ($context_check) { # Photo is approved (found in group)
                        say "Debug: Cooldown cleared for '$group_name' ($group_id). Previously posted photo found in group." if defined $debug;
                        delete $moderated_post_history{$group_id}; 
                        save_history();
                    } elsif (time() < $wait_until) { # Photo not approved and cooldown still active
                        say "Debug: Skipping group '$group_name' ($group_id). Moderated cooldown active until " . scalar(localtime($wait_until)) . ". Photo not yet in group." if defined $debug;
                        splice(@current_groups, $random_index, 1); 
                        next POST_ATTEMPT_LOOP;
                    } else { # Cooldown expired but photo never approved
                        say "Debug: Cooldown expired for '$group_name' ($group_id). Photo not found. Clearing history." if defined $debug;
                        delete $moderated_post_history{$group_id}; 
                        save_history();
                    }
                }
                
                # 3. Real-Time API Status Check (Throttle)
                if ($selected_group->{limit_mode} ne 'none' || $selected_group->{moderated} == 1) {
                    my $status = check_posting_status($group_id, $group_name);
                    # Update local cache with real-time dynamic info
                    $selected_group->{limit_mode} = $status->{limit_mode};
                    $selected_group->{remaining} = $status->{remaining};
                    unless ($status->{can_post}) { 
                        say "Debug: Skipping group '$group_name' ($group_id). Dynamic status check shows can_post=0 (Mode: $status->{limit_mode}, Remaining: $status->{remaining})." if defined $debug;
                        splice(@current_groups, $random_index, 1); 
                        next POST_ATTEMPT_LOOP;
                    }
                }

                # 4. Check Last Poster (Avoid posting consecutively to the same group)
                my $response = flickr_api_call('flickr.groups.pools.getPhotos', { group_id => $group_id, per_page => 1 });
                unless (defined $response) { # Changed: unless (defined $response)
                    say "Debug: Failed to get photos from group '$group_name' ($group_id). Ignoring this group for now." if defined $debug;
                    splice(@current_groups, $random_index, 1); 
                    next POST_ATTEMPT_LOOP;
                }
                my $photos = $response->as_hash->{photos}->{photo} || [];
                $photos = [ $photos ] unless ref $photos eq 'ARRAY';
                if (@$photos and $photos->[0]->{owner} eq $user_nsid) { 
                    say "Debug: Skipping group '$group_name' ($group_id). Last photo poster was current user ($user_nsid)." if defined $debug;
                    splice(@current_groups, $random_index, 1); 
                    next POST_ATTEMPT_LOOP;
                }

                # 5. Select Photo and Check Context
                my $photo_data = find_random_photo(\@matching_sets);
                unless ($photo_data and $photo_data->{id}) { # Changed: unless ($photo_data and $photo_data->{id})
                    say "Debug: Failed to find a suitable photo or exhausted all sets/photos (Photo Age/Public Check)." if defined $debug;
                    # This means we must exit the POST_ATTEMPT_LOOP and wait for a new cycle
                    last POST_ATTEMPT_LOOP;
                }
                
                my ($photo_id, $photo_title, $set_title, $set_id) = @$photo_data{qw/id title set_title set_id/};
                
                # Double-check: is the selected photo already in the target group?
                my $in_group_check = is_photo_in_group($photo_id, $group_id);
                unless (defined $in_group_check) { # Changed: unless (defined $in_group_check)
                    say "Debug: Group '$group_name' ($group_id) failed photo context check for new photo (API error). Retrying." if defined $debug;
                    next POST_ATTEMPT_LOOP;
                } elsif ($in_group_check) { 
                    say "Debug: Photo '$photo_title' ($photo_id) is already in group '$group_name' ($group_id). Retrying photo/group combination." if defined $debug;
                    next POST_ATTEMPT_LOOP;
                }
                
                # --- 6. Post the photo! ---
                if ($dry_run) {
                    print "DRY RUN: Would add photo '$photo_title' ($photo_id) from set '$set_title' to group '$group_name' ($group_id)";
                    
                    $post_count++;
                    last POST_ATTEMPT_LOOP; # Exit attempt loop to apply post delay

                } else {
                    my $response = flickr_api_call('flickr.groups.pools.add', { photo_id => $photo_id, group_id => $group_id });
                    
                    unless (defined $response) { # Changed: unless (defined $response)
                        print "WARNING: Could not add photo '$photo_title' ($photo_id) to group '$group_name' ($group_id). API failed after all retries. Will skip current group and continue script execution.";
                        last POST_ATTEMPT_LOOP; 
                    } 
                    
                    # Check for "success" or "moderated pending" success
                    my $moderated_pending = (!$response->{success} && ($response->{error_message} // '') =~ /Pending Queue for this Pool/i);

                    if ($response->{success} || $moderated_pending) {
                        
                        unless ($moderated_pending) { # Changed: if ($response->{success}) { ... } else { ... }
                            print "SUCCESS: Added photo '$photo_title' ($photo_id) to group '$group_name' ($group_id)";
                        } else {
                            print "INFO: Added photo '$photo_title' ($photo_id) to group '$group_name' ($group_id). Status: Moderated - Pending Queue.";
                        }
                        
                        # Aplica cooldown para grupos moderados
                        if ($selected_group->{moderated} == 1) {
                             $moderated_post_history{$group_id} = { post_time => time(), photo_id  => $photo_id };
                             say "Info: Moderated post successful. Group '$group_name' set to $moderated_wait_time second cooldown." if defined $debug;
                             save_history();
                        }

                        # Aplica cooldown de limite de taxa
                        # Simplificado: Testamos apenas 'limit_mode' pois a condição de sucesso é garantida pelo bloco 'if' principal.
                        if ($selected_group->{limit_mode} ne 'none') {
                             my $limit = $selected_group->{limit_count} || 1; 
                             my $period_seconds = $selected_group->{limit_mode} eq 'day' ? SECONDS_IN_DAY : $selected_group->{limit_mode} eq 'week' ? SECONDS_IN_WEEK : $selected_group->{limit_mode} eq 'month' ? SECONDS_IN_MONTH : 0;

                            if ($limit > 0 && $period_seconds > 0) {
                                my $base_pause_time = $period_seconds / $limit;
                                my $random_multiplier = 0.7 + (rand() * 0.4); # Add randomness (70% to 110%)
                                my $pause_time = int($base_pause_time * $random_multiplier);
                                $pause_time = 1 unless $pause_time > 0;
                                my $wait_until = time() + $pause_time;
                                $rate_limit_history{$group_id} = { wait_until => $wait_until, limit_mode => $selected_group->{limit_mode} };
                                say "Info: Group '$group_name' posted to (limit $limit/$selected_group->{limit_mode}). Applying randomized $pause_time sec cooldown." if defined $debug;
                                save_history();
                            }
                        }                       
                        
                        $post_count++;
                        last POST_ATTEMPT_LOOP; # Exit attempt loop to apply post delay

                    } else {
                        my $error_msg = $response->{error_message} || 'Unknown API Error';
                        
                        print "WARNING: Could not add photo '$photo_title' ($photo_id) to group '$group_name' ($group_id): $error_msg";
                        
                        # Handle specific non-retryable error: photo limit reached
                        if ($error_msg =~ /Photo limit reached/i) {
                            my $pause_time = SECONDS_IN_DAY; # Cooldown for a full day as a safe measure
                            my $wait_until = time() + $pause_time;
                            $rate_limit_history{$group_id} = { wait_until => $wait_until, limit_mode => 'day' };
                            say "Info: Group '$group_name' hit Photo Limit. Applying $pause_time sec cooldown." if defined $debug;
                            save_history();
                        }
                        
                        next POST_ATTEMPT_LOOP; # Try next group/photo combo
                    }
                }
            } 

            # Apply random delay between posts
            my $sleep_time = int(rand($timeout_max + 1));
            print "Pausing for $sleep_time seconds before next attempt.";
            sleep $sleep_time;
        } 
    }; 
    
    my $fatal_error = $@;

    if ($fatal_error) {
        warn "\n\n!!! FATAL SCRIPT RESTART !!! (Attempt #$restart_attempt)";
        warn "REASON: $fatal_error";        
    }
    
    # Calculate exponential backoff delay, capped at MAX_RESTART_DELAY (24 hours)
    my $delay_base = RESTART_RETRY_BASE * (RESTART_RETRY_FACTOR ** ($restart_attempt - 1));
    my $delay = $delay_base;
    
    # Add randomness (80% to 120%) to the calculated delay to prevent thundering herd
    $delay = int($delay * (0.8 + (rand() * 0.4))); 
    $delay = MAX_RESTART_DELAY if $delay > MAX_RESTART_DELAY;

    print "The entire script will restart after pausing for $delay seconds (Max delay: " . MAX_RESTART_DELAY . "s).";
    
    sleep $delay;

}