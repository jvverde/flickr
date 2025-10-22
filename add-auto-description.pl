#!/usr/bin/perl
# =============================================================================
# Flickr Photo Organizer and Description Updater
#
# This script searches for all photos of the authenticated Flickr user,
# retrieves their metadata (title, description, tags, and photosets/sets),
# and updates the description of each photo by appending or replacing a block
# with links to relevant sets (country, order, family, species, date).
#
# Features:
#   - Filter photos by upload date, tags, or number of days.
#   - Dry-run mode for testing without making changes.
#   - Custom regex for matching set titles.
#   - Exponential backoff for Flickr API calls.
#   - Debug mode for detailed output.
#
# Usage:
#   ./script.pl [options]
#   See usage() for all options.
# =============================================================================

use strict;
use warnings;
use Getopt::Long;
use Flickr::API;
use POSIX qw(strftime);
use Time::Local 'timegm';
use Data::Dumper;  # For debug output

# Set output record and field separators for cleaner output
binmode(STDOUT, ':utf8');
$\ = "\n";  # Output record separator (auto-add newline to prints)
$, = " ";   # Output field separator (space between print arguments)

# Load Flickr API configuration from a storable config file
my $config_file = "$ENV{HOME}/saved-flickr.st";
my $flickr = Flickr::API->import_storable_config($config_file);

# Global debug flag (undef = off, 1+ = debug level for Data::Dumper depth)
my $debug;

# =============================================================================
# Subroutine: usage()
# Displays detailed help message and exits.
# =============================================================================
sub usage {
    print <<'END_USAGE';
Search all user photos on Flickr, retrieve title, description, tags, and photosets (sets) they belong to, and update the description of each photo by appending or replacing a specific block with links to relevant sets, including species.
Usage:
  $0 [--after <date>] [--before <date>] [--days <days>] [--max-photos <num>] [--tag <tag>]... [--page <num>] [--dry-run] [--country-regex <regex>] [--order-regex <regex>] [--family-regex <regex>] [--debug [<level>]]
  $0 [-a <date>] [-b <date>] [-d <days>] [-m <num>] [-t <tag>]... [-p <num>] [-n] [--country-regex <regex>] [--order-regex <regex>] [--family-regex <regex>] [--debug [<level>]]
  $0 --help
Options:
  -a, --after        Minimum upload date in YYYY-MM-DD format to include photos uploaded after or on this date
  -b, --before       Maximum upload date in YYYY-MM-DD format to include photos uploaded before or on this date
  -d, --days         Number of days to look back for photos uploaded in the last N days
  -m, --max-photos   Maximum number of photos to retrieve (optional)
  -t, --tag          Filter by tag (can be specified multiple times for multiple tags)
  -p, --page         Start from specific page number (optional)
  -n, --dry-run      Run in dry-run mode without actually updating descriptions on Flickr
  --country-regex    Custom regex for matching country sets (default: \(\d{4}.*\))
  --order-regex      Custom regex for matching order sets (default: .+FORMES)
  --family-regex     Custom regex for matching family sets (default: .+idae(?:\s+|$))
  --debug [<level>]  Enable debug output (level controls Dumper depth, default: 1)
  -h, --help         Display this help message and exit
The script searches for all photos of the authenticated user,
retrieves title, description, tags (as array), and sets (photosets titles as array).
It fetches current data from Flickr (filtered by date/tags if provided),
and updates the description on Flickr for each photo by appending or replacing the organization block if changes are needed.
In dry-run mode, it simulates the updates and reports what would be changed without modifying anything.
END_USAGE
    exit;
}

# =============================================================================
# Subroutine: debug_print()
# Prints debug messages and optionally dumps data using Data::Dumper.
# Only outputs when $debug is defined (set via --debug flag).
# =============================================================================
sub debug_print {
    return unless defined $debug;
    my ($message, $data) = @_;
    print "DEBUG: $message";
    # Only show Dumper output if debug level is 2 or higher
    if ($data && $debug > 1) {
        my $dumper = Data::Dumper->new([$data]);
        $dumper->Indent(1)->Terse(1)->Maxdepth($debug);
        print "DEBUG DATA: " . $dumper->Dump();
    }
}

# =============================================================================
# Subroutine: flickr_api_call()
# Makes a robust Flickr API call with exponential backoff for retries.
# Retries up to 5 times with increasing delays (1s, 8s, 64s, 512s, 4096s).
# Dies after max retries exceeded.
# =============================================================================
sub flickr_api_call {
    my ($method, $args) = @_;
    my $max_retries = 5;
    my $retry_delay = 1;  # Initial delay in seconds

    debug_print("API CALL: $method with args: ", $args);

    for my $attempt (1 .. $max_retries) {
        my $response = eval {
            $flickr->execute_method($method, $args)
        };

        # Check for errors in response or eval
        if ($@ || !$response->{success}) {
            my $error = $@ || $response->{error_message} || 'Unknown error';
            warn "Attempt $attempt failed for $method: $error";

            # Give up after max retries
            if ($attempt == $max_retries) {
                die "Failed to execute $method after $max_retries attempts: $error";
            }

            # Exponential backoff: wait before retrying
            sleep $retry_delay;
            $retry_delay *= 8;
            next;
        }

        debug_print("API RESPONSE: $method", $response->as_hash());

        return $response;
    }
}

# =============================================================================
# Subroutine: get_photo_sets()
# Retrieves the sets (photosets) a photo belongs to.
# Returns a hashref with set IDs as keys and titles as values.
# Returns undef on error (handled by caller with || {}).
# =============================================================================
sub get_photo_sets {
    my ($pid) = @_;

    debug_print("Getting sets for photo: $pid");

    my $response = eval {
        flickr_api_call('flickr.photos.getAllContexts', { photo_id => $pid })
    };

    if ($@) {
        warn "Failed to get contexts for photo $pid: $@";
        return undef;
    }

    my $hash = $response->as_hash();
    my $sets = $hash->{set} || [];
    # Normalize to array if single set returned
    $sets = [$sets] unless ref $sets eq 'ARRAY';

    debug_print("Found " . scalar(@$sets) . " sets for photo $pid", $sets);

    # Create hashref with set IDs as keys and titles as values
    return { map { 
        $_->{id} => { 
            title => $_->{title},
            cnt => $_->{count_photo}
        }
    } @$sets };
}

# =============================================================================
# Main Script: Parse command-line options and process photos
# =============================================================================

# Declare variables for command-line options
my ($after_date, $before_date, $days, $max_photos, $start_page, $dry_run);
my @tags;

# Declare regex variables with defaults for matching set titles
my $country_re = qr/\(\d{4}.*\)/;           # Matches "(2024...)" pattern
my $order_re   = qr/.+FORMES/;              # Matches taxonomic orders ending in "FORMES"
my $family_re  = qr/.+idae(?:\s+|$)/;       # Matches taxonomic families ending in "idae"

# Parse command-line options with optional debug level
GetOptions(
    "a|after=s"        => sub { die "Error: Date '$_[1]' must be in YYYY-MM-DD format\n" if $_[1] && $_[1] !~ /^\d{4}-\d{2}-\d{2}$/; $after_date = $_[1] },
    "b|before=s"       => sub { die "Error: Date '$_[1]' must be in YYYY-MM-DD format\n" if $_[1] && $_[1] !~ /^\d{4}-\d{2}-\d{2}$/; $before_date = $_[1] },
    "d|days=i"         => \$days,
    "m|max-photos=i"   => \$max_photos,
    "t|tag=s"          => \@tags,
    "p|page=i"         => \$start_page,
    "n|dry-run"        => \$dry_run,
    "country-regex=s"  => sub { eval { $country_re = qr/$_[1]/ } or die "Invalid country regex: $@ "; },
    "order-regex=s"    => sub { eval { $order_re = qr/$_[1]/ } or die "Invalid order regex: $@ "; },
    "family-regex=s"   => sub { eval { $family_re = qr/$_[1]/ } or die "Invalid family regex: $@ "; },
    "debug:i"          => \$debug,  # Optional integer argument for depth control
    "h|help"           => \&usage
) or usage();

# Validate date range and prevent conflicting date options
if (defined $after_date && defined $before_date && $after_date gt $before_date) {
    die "Error: After date ($after_date) cannot be after before date ($before_date)\n";
}
if (defined $days && defined $after_date) {
    die "Error: Cannot specify both --days and --after\n";
}
if (defined $days && defined $before_date) {
    die "Error: Cannot specify both --days and --before\n";
}

# Set default debug level if --debug is used without argument
if (defined $debug && $debug == 0) {
    $debug = 1;  # Default depth when --debug is used without value
}

# Debug mode announcement
if (defined $debug) {
    print "DEBUG MODE ENABLED (level: $debug)";
    debug_print("Command line options:", {
        after_date => $after_date,
        before_date => $before_date,
        days => $days,
        max_photos => $max_photos,
        start_page => $start_page,
        dry_run => $dry_run,
        tags => \@tags
    });
}

if ($dry_run) {
    print "Running in dry-run mode: No changes will be made to Flickr.";
}

# Build search arguments for Flickr API
my $search_args = {
    user_id  => 'me',
    per_page => 500,  # Maximum allowed by Flickr API
    extras   => 'date_upload,owner,title,description,tags',
    page     => $start_page || 1
};

# Add date filters (Flickr API accepts YYYY-MM-DD format directly)
$search_args->{min_upload_date} = time() - ($days * 86400) if defined $days;
$search_args->{min_upload_date} = $after_date if defined $after_date;
$search_args->{max_upload_date} = $before_date if defined $before_date;

# Add tag filters if specified (AND logic: all tags must match)
if (@tags) {
    $search_args->{tags} = join(',', @tags);
    $search_args->{tag_mode} = 'all';  # Require all tags (AND logic)
}

debug_print("Search arguments:", $search_args);

# Track changes across all pages
my %changes = (
    updated => 0,
    total_processed => 0
);

# Search for photos page by page, processing each page immediately
my $page = $start_page || 1;
my $pages = $page;  # Start with current page to ensure at least one iteration
my $photos_retrieved = 0;

while ($page <= $pages) {
    # Optimize per_page for the last page when max_photos is specified
    if (defined $max_photos && ($max_photos - $photos_retrieved) < 500) {
        $search_args->{per_page} = $max_photos - $photos_retrieved;
        debug_print("Adjusting per_page to $search_args->{per_page} for last page");
    }

    $search_args->{page} = $page;

    debug_print("Fetching page $page with per_page: $search_args->{per_page}");

    my $response = eval {
        flickr_api_call('flickr.photos.search', $search_args)
    };

    if ($@) {
        die "Failed to search photos: $@";
    }

    my $hash = $response->as_hash();
    my $photos = $hash->{photos}->{photo} || [];
    # Normalize to array if single photo returned
    $photos = [$photos] unless ref $photos eq 'ARRAY';

    my $photos_in_page = scalar(@$photos);
    $pages = $hash->{photos}->{pages} || 1;
    print "Processing page $page of $pages ($photos_in_page photos)";

    # Process each photo in this page
    foreach my $photo (@$photos) {
        my $id = $photo->{id};
        my $owner = $photo->{owner};
        my $title = $photo->{title} // '';
        # Handle both hash and string description formats from API
        my $current_desc = ref $photo->{description} eq 'HASH' ? $photo->{description}{_content} // '' : $photo->{description} // '';
        my $tags_str = $photo->{tags} // '';
        debug_print("Processing photo $id: '$title'");
        
        # Get all sets this photo belongs to (returns {} if none or error)
        my $sets = get_photo_sets($id) || {};

        # Find matching sets using ||= to keep only the FIRST match of each type
        my $country_set;
        my $order_set;
        my $family_set;
        my $species_set;
        my $date_set;

        foreach my $id (keys %$sets) {
            #my $set_title = $sets->{$id}{title};
            #my $cnt = $sets->{$id}{cnt} || '';
            my ($title, $cnt) = @{$sets->{$id}}{qw(title cnt)};
            # Use ||= to assign only if not already set (keeps first match)
            $country_set ||= {id => $id, title => $title, cnt => $cnt} if $title =~ $country_re;
            $order_set   ||= {id => $id, title => $title, cnt => $cnt} if $title =~ $order_re;
            $family_set  ||= {id => $id, title => $title, cnt => $cnt} if $title =~ $family_re;
            $species_set ||= {id => $id, title => $title, cnt => $cnt} if $title =~ /^[A-Z][a-z]+ [a-z]+$/;  # Binomial nomenclature
            $date_set    ||= {id => $id, title => $title, cnt => $cnt} if $title =~ m#\d{4}/\d{2}/\d{2}#;
        }

        # Build lines for each matching set type
        my $base = "https://www.flickr.com/photos/$owner/albums/";
        my @lines;
        push @lines, qq|  - All the photos for this trip <a href="$base/albums/$country_set->{id}">$country_set->{title}</a> ($country_set->{cnt})| if $country_set;
        push @lines, qq|  - All the photos for this order <a href="$base/$order_set->{id}">$order_set->{title}</a> ($order_set->{cnt})| if $order_set;
        push @lines, qq|  - All the photos for this family <a href="$base/$family_set->{id}">$family_set->{title}</a> ($family_set->{cnt})| if $family_set;
        push @lines, qq|  - All the photos for this species <a href="$base/$species_set->{id}">$species_set->{title}</a> ($species_set->{cnt})| if $species_set;
        push @lines, qq|  - All the photos taken this day <a href="$base/$date_set->{id}">$date_set->{title}</a> ($date_set->{cnt})| if $date_set;

        # Skip photo if no matching sets found
        next unless @lines;

        # Build the description block with markers for later replacement
        my $block = "==================***==================\n" .
                    "All my photos are now organized into sets by the country where they were taken, by taxonomic order, by family, by species (often with just one photo for the rarer ones), and by the date they were taken.\n" .
                    "So, you may find:\n" .
                    join("\n", @lines) . "\n" .
                    "==================***==================\n";

        # Check if block exists and build new description
        my $marker = "==================***==================";
        my $new_desc = $current_desc;
        if ($current_desc =~ /\Q$marker\E.*?\Q$marker\E/s) {
            # Replace existing block between markers
            $new_desc =~ s/\Q$marker\E.*?\Q$marker\E/$block/s;
        } else {
            # Append block if not exists (with newline separator if description exists)
            $new_desc .= ($current_desc ? "\n" : "") . $block;
        }

        # Skip if no changes needed
        next unless $new_desc ne $current_desc;

        # Update description on Flickr (or simulate in dry-run mode)
        unless ($dry_run) {
            eval {
                flickr_api_call('flickr.photos.setMeta', {
                    photo_id    => $id,
                    title       => $title,  # Keep existing title
                    description => $new_desc
                });
            };
            # Skip this photo if update failed (already warned in flickr_api_call)
            next if $@;
        }

        $changes{updated}++;
        print $dry_run 
            ? "Would update description for photo $title (dry-run):\n\t$new_desc"
            : "Updated description for photo $title ($id)";

    } continue {
        # Always execute: increment total processed counter even if 'next' was called
        $changes{total_processed}++;
        print "Total processed photos: $changes{total_processed}";
    }

    $photos_retrieved += $photos_in_page;

    print "Completed page $page of $pages (total: $photos_retrieved photos)";

    # Stop if we've reached max_photos limit
    last if (defined $max_photos && $photos_retrieved >= $max_photos);

    $page++;
}

# Exit early if no photos found
if ($changes{total_processed} == 0) {
    print "No photos found matching the specified criteria";
    exit;
}

# Final report
print "Processing completed:";
print "  - $changes{total_processed} photos processed in total";
my $update_msg = $dry_run ? "would be updated" : "updated";
print "  - $changes{updated} photos $update_msg";