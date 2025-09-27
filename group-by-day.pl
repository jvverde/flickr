#!/usr/bin/perl
# flickr_photoset_by_date.pl
#
# Purpose:
#   This script automates the organization of Flickr photos into photosets based on
#   their date taken and a specified machine tag (default: 'ioc151:seq=nnnn'). It
#   searches for photos with the given tag, groups them by date and sequence number,
#   and creates or updates a photoset named 'B0 - YYYY/MM/DD' for each date with at
#   least a minimum number of unique sequence numbers (default: 5). Photos are added
#   to the photoset, with the primary photo for new sets removed from the addition
#   list to avoid duplicate errors. With --last, filters photos by upload date.
#
# Functionality:
#   - Fetches photos with the specified machine tag using the Flickr API.
#   - Groups photos by date taken (YYYY-MM-DD) and sequence number from the tag.
#   - Skips dates with fewer than the minimum unique sequence numbers, logging skipped
#     photo titles.
#   - Creates a new photoset or uses an existing one for each qualifying date.
#   - Adds photos to the photoset, handling cases where photos are already in the set.
#   - Supports dry-run mode to simulate actions without making API calls.
#   - Uses photo titles in logs for readability, with 'Untitled' fallback for missing titles.
#
# Command-Line Options:
#   -h, --help        Display this help message and exit.
#   -d, --days N      Process photos from the last N days (date taken).
#   -a, --after DATE  Process photos taken after DATE (YYYY-MM-DD).
#   -b, --before DATE Process photos taken before DATE (YYYY-MM-DD).
#   -m, --min-photos N Minimum number of unique tag sequence values to create a set (default: 5).
#   -t, --tag TAG     Machine tag namespace to search (default: 'ioc151').
#   -n, --dry-run     Simulate actions without modifying Flickr data.
#   -l, --last N      Process photos uploaded in last N days.
#
# Usage Examples:
#   ./flickr_photoset_by_date.pl                  # Process all photos with ioc151:seq tags
#   ./flickr_photoset_by_date.pl -d 30 -n         # Dry-run for last 30 days (date taken)
#   ./flickr_photoset_by_date.pl -l 7             # Process photos uploaded in last 7 days
#   ./flickr_photoset_by_date.pl -a 2023-01-01 -t taxonomy  # Process photos after 2023-01-01 with taxonomy:seq tags
#   ./flickr_photoset_by_date.pl -a 2023-01-01 -b 2023-12-31 -m 10  # Process photos in 2023 with min 10 unique tags
#
# Assumptions:
#   - The Flickr API configuration is stored in '$ENV{HOME}/saved-flickr.st'.
#   - The Flickr::API module is installed and configured.
#   - Photos have a 'date_taken' field and may have a 'title' and 'machine_tags'.
#   - Machine tags follow the format '<tag>:seq=nnnn' (e.g., 'ioc151:seq=8530').
#
# Notes:
#   - The script uses lowercase tag searches (e.g., 'ioc151:seq=') and case-insensitive parsing.
#   - Primary photos for new sets are removed from the addition list to avoid 'Photo already in set' errors.
#   - Logs use photo titles for readability, with detailed messages for skipped, added, or already-in-set photos.
#   - The script handles pagination for large photo and photoset collections (up to 500 per page).
#   - Errors are logged with warnings, except for 'Photo already in set', which is logged as a status message.
#   - With --last, photos are filtered by upload date but grouped by date taken for photoset assignment.

use strict;
use warnings;
use Getopt::Long;      # For parsing command-line options
use Data::Dumper;      # For debugging data structures (not used in production)
use Flickr::API;       # Flickr API interface for photo and photoset operations
use POSIX qw(strftime mktime);  # For date formatting and time calculations

# Set output field and record separators to newlines for consistent printing
($\, $,) = ("\n", "\n");

# Declare variables for command-line options
my $help;                   # Flag to display help message
my $dry_run;                # Flag to simulate actions without API changes
my $days;                   # Number of recent days to process
my $after;                  # Earliest date for photos (YYYY-MM-DD)
my $before;                 # Latest date for photos (YYYY-MM-DD)
my $min_photos = 5;         # Minimum unique tag sequence values to create a set
my $tag = 'ioc151';         # Machine tag namespace (e.g., 'ioc151' for 'ioc151:seq=nnnn')
my $last;                   # Number of days for photos uploaded (for --last)

# Parse command-line options using Getopt::Long
GetOptions(
    'h|help' => \$help,             # Help flag
    'l|last=i' => \$last,           # Integer: Uploaded in last N days
    'd|days=i' => \$days,           # Integer: Taken in last N days
    'a|after=s' => \$after,         # String: date in YYYY-MM-DD
    'b|before=s' => \$before,       # String: date in YYYY-MM-DD
    'm|min-photos=i' => \$min_photos, # Integer: minimum unique tags
    't|tag=s' => \$tag,             # String: machine tag namespace
    'n|dry-run' => \$dry_run,       # Dry-run flag
);

# Display help message and exit if --help is specified
if ($help) {
    print "This script searches all Flickr photos for the user 'me' with machine tag '$tag:seq=nnnn',";
    print "groups them by the date taken and $tag:seq, and if more than $min_photos unique $tag:seq values";
    print "are found on the same date, creates a new photoset named 'B0 - YYYY/MM/DD' (or adds to existing)";
    print "and adds the relevant photos to it.";
    print "Usage: $0 [OPTIONS]";
    print "Options:";
    print "  -h, --help        Show this help message and exit";
    print "  -d, --days        Process photos from the last N days (date taken)";
    print "  -a, --after       Process photos taken after this date (YYYY-MM-DD)";
    print "  -b, --before      Process photos taken before this date (YYYY-MM-DD)";
    print "  -m, --min-photos  Minimum number of unique $tag:seq values to create a set (default: $min_photos)";
    print "  -t, --tag         Machine tag namespace to search (default: '$tag')";
    print "  -n, --dry-run     Simulate without making changes";
    print "  -l, --last        Process photos uploaded in last N days";
    print "";
    print "NOTE: This script assumes the user's Flickr API tokens are initialized in the file '$ENV{HOME}/saved-flickr.st'.";
    exit;
}

# Validate min_photos to ensure it's a positive integer
die "Error: --min-photos must be a positive integer" unless $min_photos > 0;

# Subroutine to validate date format (YYYY-MM-DD)
sub validate_date {
    my ($date, $option) = @_;
    return 1 if $date =~ /^\d{4}-\d{2}-\d{2}$/;
    die "Error: $option must be in YYYY-MM-DD format";
}

# Validate --after and --before options if provided
validate_date($after, '--after') if defined $after;
validate_date($before, '--before') if defined $before;
# Validate --days or --last if provided
die "Error: --days must be a positive integer" if defined $days && $days <= 0;
die "Error: --last must be a positive integer" if defined $last && $last <= 0;

# Calculate date range for photo filtering
my ($min_taken_date, $max_taken_date, $min_upload_date);
if (defined $days) {
    # If --days is specified, calculate date range from current time
    my $now = time;
    $min_taken_date = strftime("%Y-%m-%d", localtime($now - $days * 86400));
    $max_taken_date = strftime("%Y-%m-%d", localtime($now));
}
$min_upload_date = strftime("%Y-%m-%d", localtime(time - $last * 86400)) if defined $last;

# Override with --after or --before if specified
$min_taken_date = $after if defined $after;
$max_taken_date = $before if defined $before;

# Load Flickr API configuration from storable file
my $config_file = "$ENV{HOME}/saved-flickr.st";
my $flickr = Flickr::API->import_storable_config($config_file);

# Retrieve photos with the specified machine tag (e.g., 'ioc151:seq=nnnn')
my $all_photos = [];  # Array to store all fetched photos
my $page = 1;         # Current page for pagination
my $total_pages = 1;  # Total pages to fetch
my $search_params = {
    user_id => 'me',                    # Authenticated user
    machine_tags => lc("$tag:seq="),    # Lowercase tag filter (e.g., 'ioc151:seq=')
    per_page => 500,                    # Max photos per page
    page => $page,                      # Current page number
    extras => 'date_taken,machine_tags,title',  # Additional photo metadata
};
# Add date filters if specified
$search_params->{min_taken_date} = $min_taken_date if defined $min_taken_date;
$search_params->{max_taken_date} = $max_taken_date if defined $max_taken_date;
$search_params->{min_upload_date} = $min_upload_date if defined $min_upload_date;

# Fetch photos with pagination
while ($page <= $total_pages) {
    $search_params->{page} = $page;
    my $response = $flickr->execute_method('flickr.photos.search', $search_params);

    # Handle API errors by retrying the page
    warn "Error fetching photos page $page: $response->{error_message}" and redo unless $response->{success};

    # Extract photos from response
    my $bunch = $response->as_hash->{photos}->{photo};
    $bunch = [ $bunch ] unless 'ARRAY' eq ref $bunch;  # Ensure array reference
    push @$all_photos, @$bunch;  # Append photos to main array
    $total_pages = $response->as_hash->{photos}->{pages};  # Update total pages
    $page++;
}

# Log total photos fetched
print "Fetched " . scalar(@$all_photos) . " photos with $tag:seq machine tag.";

# Retrieve existing photosets to check for duplicates by title
my $all_photosets = [];  # Array to store all photosets
my $ps_page = 1;         # Current photoset page
my $ps_pages = 1;        # Total photoset pages
while ($ps_page <= $ps_pages) {
    my $response = $flickr->execute_method('flickr.photosets.getList', {
        per_page => 500,
        page => $ps_page,
    });

    # Handle API errors by retrying the page
    warn "Error fetching photosets page $ps_page: $response->{error_message}" and redo unless $response->{success};

    # Extract photosets from response
    my $ps_bunch = $response->as_hash->{photosets}->{photoset};
    $ps_bunch = [ $ps_bunch ] unless 'ARRAY' eq ref $ps_bunch;  # Ensure array reference
    push @$all_photosets, @$ps_bunch;  # Append photosets to main array
    $ps_pages = $response->as_hash->{photosets}->{pages};  # Update total pages
    $ps_page++;
}

# Create a hash of existing photoset titles to IDs for quick lookup
my %existing_sets;  # title => photoset_id
foreach my $ps (@$all_photosets) {
    $existing_sets{$ps->{title}} = $ps->{id};
}

# Group photos by date and sequence number
my %date_groups;  # date (YYYY-MM-DD) => { seq => [ {id => photo_id, title => photo_title}, ... ] }
foreach my $photo (@$all_photos) {
    # Skip photos without a date_taken
    my $date_taken = $photo->{datetaken} || next;
    # Extract YYYY-MM-DD from date_taken
    my ($date) = $date_taken =~ /^(\d{4}-\d{2}-\d{2})/ or next;

    # Get machine tags
    my $machine_tags_str = $photo->{machine_tags} || '';
    my @machine_tags = split /\s+/, $machine_tags_str;

    # Extract sequence number from machine tag (e.g., 'ioc151:seq=8530')
    # Initialize index
    my $i = 0;
    # Loop while tags remain and no match is found, incrementing index if condition is true
    $i++ while ($i < @machine_tags && $machine_tags[$i] !~ /^\Q$tag\E:seq=(?P<seq_num>\d+)$/i);
    next unless $i < @machine_tags;  # Skip if no valid sequence number
    # Assign sequence number if a match was found
    my $seq = $+{seq_num};

    # Store photo ID and title (with 'Untitled' fallback)
    push @{$date_groups{$date}{$seq}}, { id => $photo->{id}, title => $photo->{title} || 'Untitled' };
}

# Process each date group
my $total_sets_processed = 0;  # Count of date groups processed
my $total_sets_updated = 0;    # Count of photosets created or updated
my $total_photos_added = 0;    # Count of photos added to photosets
foreach my $date (sort keys %date_groups) {
    # Count unique sequence numbers for the date
    my $unique_seqs = scalar keys %{$date_groups{$date}};
    print "Processing date $date: $unique_seqs unique $tag:seq values.";

    $total_sets_processed++;

    # Skip dates with fewer than $min_photos unique sequence numbers
    if ($unique_seqs < $min_photos) {
        print "  Skipping: fewer than $min_photos unique $tag:seq values.";
        # Log each skipped photo with its title and sequence
        foreach my $seq (sort { $a <=> $b } keys %{$date_groups{$date}}) {
            foreach my $photo (@{$date_groups{$date}{$seq}}) {
                print "    Skipped photo '$photo->{title}' ($tag:seq=$seq).";
            }
        }
        next;
    }

    # Format photoset title as 'B0 - YYYY/MM/DD'
    my $formatted_date = $date;
    $formatted_date =~ s/-/\//g;
    my $set_title = "B0 - $formatted_date";

    # Check if photoset already exists
    my $set_id = $existing_sets{$set_title};

    if (!$set_id) {
        # Create new photoset
        my $primary_seq = (keys %{$date_groups{$date}})[0];  # Select first sequence
        # Ensure sequence exists and has photos before selecting primary photo
        next unless defined $date_groups{$date}{$primary_seq} && @{$date_groups{$date}{$primary_seq}};
        my $primary_photo = shift @{$date_groups{$date}{$primary_seq}};  # Remove primary photo
        my $primary_photo_id = $primary_photo->{id};  # Get primary photo ID
        # Simulate photoset creation in dry-run mode and skip to next date group
        $total_sets_updated++ and print "  DRY RUN: Would create new set '$set_title' with primary photo '$primary_photo->{title}' ($tag:seq=$primary_seq)." and next if $dry_run;
        # Create photoset via Flickr API
        my $create_response = $flickr->execute_method('flickr.photosets.create', {
            title => $set_title,
            primary_photo_id => $primary_photo_id,
        });
        # Warn and skip if photoset creation fails
        warn "Error creating set '$set_title': $create_response->{error_message}" and next unless $create_response->{success};
        $set_id = $create_response->as_hash->{photoset}->{id};
        print "  Created new set '$set_title' with primary photo '$primary_photo->{title}' ($tag:seq=$primary_seq).";
        # Remove empty sequence array if necessary
        delete $date_groups{$date}{$primary_seq} unless @{$date_groups{$date}{$primary_seq}};
        $total_sets_updated++;
    } else {
        # Use existing photoset
        print "  Using existing set '$set_title'.";
        $total_sets_updated++;
    }

    # Add remaining photos to the photoset
    my $photos_added = 0;  # Count photos added for this date
    foreach my $seq (keys %{$date_groups{$date}}) {
        foreach my $photo (@{$date_groups{$date}{$seq}}) {
            my $photo_id = $photo->{id};
            # Simulate adding photo in dry-run mode, increment count, and skip to next photo
            print "    DRY RUN: Would add photo '$photo->{title}' ($tag:seq=$seq) to set '$set_title'." and ++$photos_added and next if $dry_run;
            # Add photo to photoset via Flickr API
            my $add_response = $flickr->execute_method('flickr.photosets.addPhoto', {
                photoset_id => $set_id,
                photo_id => $photo_id,
            });
            if ($add_response->{success}) {
                $photos_added++;
                print "    Added photo '$photo->{title}' ($tag:seq=$seq) to set '$set_title'.";
            } else {
                my $msg = $add_response->{error_message};
                if ($msg !~ /Photo already in set/i) {
                    # Log unexpected errors as warnings
                    warn "Error adding photo '$photo->{title}' to set '$set_title': $msg";
                } else {
                    # Log 'already in set' as a status message
                    print "    Photo '$photo->{title}' ($tag:seq=$seq) already in set '$set_title'.";
                }
            }
        }
    }
    $total_photos_added += $photos_added;
    print "  Added/processed $photos_added photos to set '$set_title'.";
}

# Print summary of processing
print "Completed! Processed $total_sets_processed date groups.";
print ($dry_run ? "" : " Updated/created $total_sets_updated sets and added $total_photos_added photos.");