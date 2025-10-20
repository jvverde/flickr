#!/usr/bin/perl
use strict;
use warnings;
use Getopt::Long;
use Flickr::API;
use POSIX qw(strftime);
use Time::Local 'timegm';
use Data::Dumper;  # For debug output
binmode(STDOUT, ':utf8');

# Set output record and field separators
$\ = "\n";
$, = " ";

# Load Flickr API configuration from storable config file
my $config_file = "$ENV{HOME}/saved-flickr.st";
my $flickr = Flickr::API->import_storable_config($config_file);

# Global debug flag (undef = off, 1+ = debug level)
my $debug;

# Enhanced usage subroutine to display detailed help message
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

# Debug print function
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

# Robust Flickr API call with exponential backoff
sub flickr_api_call {
    my ($method, $args) = @_;
    my $max_retries = 5;
    my $retry_delay = 1;
    
    debug_print("API CALL: $method with args: ", $args);
    
    for my $attempt (1 .. $max_retries) {
        my $response = eval {
            $flickr->execute_method($method, $args)
        };
        
        if ($@ || !$response->{success}) {
            my $error = $@ || $response->{error_message} || 'Unknown error';
            warn "Attempt $attempt failed for $method: $error";
            
            if ($attempt == $max_retries) {
                die "Failed to execute $method after $max_retries attempts: $error";
            }
            
            sleep $retry_delay;
            $retry_delay *= 8;  # Exponential backoff
            next;
        }
        
        debug_print("API RESPONSE: $method", $response->as_hash());
        
        return $response;
    }
}

# Get sets information for a single photo
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
    $sets = [$sets] unless ref $sets eq 'ARRAY';
    
    debug_print("Found " . scalar(@$sets) . " sets for photo $pid");
    
    # Create object with set IDs as keys and titles as values
    my %sets_obj = map { $_->{id} => $_->{title} } @$sets;
    
    return \%sets_obj;
}

# Declare variables for command-line options
my ($after_date, $before_date, $days, $max_photos, $start_page, $dry_run, $country_regex, $order_regex, $family_regex);
my @tags;

# Parse command-line options with optional debug level
GetOptions(
    "a|after=s"        => sub { die "Error: Date '$_[1]' must be in YYYY-MM-DD format\n" if $_[1] && $_[1] !~ /^\d{4}-\d{2}-\d{2}$/; $after_date = $_[1] },
    "b|before=s"       => sub { die "Error: Date '$_[1]' must be in YYYY-MM-DD format\n" if $_[1] && $_[1] !~ /^\d{4}-\d{2}-\d{2}$/; $before_date = $_[1] },
    "d|days=i"         => \$days,
    "m|max-photos=i"   => \$max_photos,
    "t|tag=s"          => \@tags,
    "p|page=i"         => \$start_page,
    "n|dry-run"        => \$dry_run,
    "country-regex=s"  => \$country_regex,
    "order-regex=s"    => \$order_regex,
    "family-regex=s"   => \$family_regex,
    "debug:i"          => \$debug,  # Optional integer argument
    "h|help"           => \&usage
) or usage();

if (defined $after_date && defined $before_date && $after_date gt $before_date) {
    die "Error: After date ($after_date) cannot be after before date ($before_date)\n";
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
        country_regex => $country_regex,
        order_regex => $order_regex,
        family_regex => $family_regex,
        tags => \@tags
    });
}

if ($dry_run) {
    print "Running in dry-run mode: No changes will be made to Flickr.";
}

# Compile regexes, with defaults and sanitization
my $country_re = qr/\(\d{4}.*\)/;
eval { $country_re = qr/$country_regex/; } or die "Invalid $country_regex: $@ " if defined $country_regex;


my $order_re = qr/.+FORMES/;
eval { $order_re = qr/$order_regex/; } or die "Invalid $order_regex: $@ " if defined $order_regex;

my $family_re = qr/.+idae(?:\s+|$)/;
eval { $family_re = qr/$family_regex/; } or die "Invalid $family_regex: $@ " if defined $family_regex;

# Build search arguments
my $search_args = {
    user_id  => 'me',
    per_page => 500,
    extras   => 'date_upload,owner,title,description,tags',
    page     => $start_page || 1
};

# Add date filters as timestamps
$search_args->{min_upload_date} = time() - ($days * 86400) if defined $days;

$search_args->{min_upload_date} = $after_date if defined $after_date;

$search_args->{max_upload_date} = $before_date if defined $before_date;

# Add tag filters if specified
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
    $photos = [$photos] unless ref $photos eq 'ARRAY';
    
    my $photos_in_page = scalar(@$photos);

    $pages = $hash->{photos}->{pages} || 1;

    print "Processing page $page of $pages ($photos_in_page photos)";
    
    # Process each photo in this page
    foreach my $photo (@$photos) {
        my $id = $photo->{id};
        my $owner = $photo->{owner};
        my $title = $photo->{title} // '';
        my $current_desc = ref $photo->{description} eq 'HASH' ? $photo->{description}{_content} // '' : $photo->{description} // '';
        my $tags_str = $photo->{tags} // '';

        debug_print("Processing photo $id: '$title'");

        my $sets = get_photo_sets($id) || {};

        # Find matching sets
        my $country_set;
        my $order_set;
        my $family_set;
        my $species_set;
        my $date_set;
        foreach my $set_id (keys %$sets) {
            my $set_title = $sets->{$set_id};
            if ($set_title =~ $country_re) {
                $country_set ||= {id => $set_id, title => $set_title};  # Take first match
            }
            if ($set_title =~ $order_re) {
                $order_set ||= {id => $set_id, title => $set_title};
            }
            if ($set_title =~ $family_re) {
                $family_set ||= {id => $set_id, title => $set_title};
            }
            if ($set_title =~ /^[A-Z][a-z]+ [a-z]+$/) {
                $species_set ||= {id => $set_id, title => $set_title};
            }
            if ($set_title =~ m#\d{4}/\d{2}/\d{2}#) {
                $date_set ||= {id => $set_id, title => $set_title};
            }
        }

        # Build lines if matches found
        my @lines;
        if ($country_set) {
            my $link = "https://www.flickr.com/photos/$owner/albums/$country_set->{id}";
            push @lines, qq|  - All the photos for this trip <a href="$link">$country_set->{title}</a>|;
        }
        if ($order_set) {
            my $link = "https://www.flickr.com/photos/$owner/albums/$order_set->{id}";
            push @lines, qq|  - All the photos for this order <a href="$link">$order_set->{title}</a>|;
        }
        if ($family_set) {
            my $link = "https://www.flickr.com/photos/$owner/albums/$family_set->{id}";
            push @lines, qq|  - All the photos for this family <a href="$link">$family_set->{title}</a>|;
        }
        if ($species_set) {
            my $link = "https://www.flickr.com/photos/$owner/albums/$species_set->{id}";
            push @lines, qq|  - All the photos for this species <a href="$link">$species_set->{title}</a>|;
        }
        if ($date_set) {
            my $link = "https://www.flickr.com/photos/$owner/albums/$date_set->{id}";
            push @lines, qq|  - All the photos taken this day <a href="$link">$date_set->{title}</a>|;
        }

        if (@lines) {
            my $block = "==================***==================\n" .
                        "All my photos are now organized into sets by the country where they were taken, by taxonomic order, by family, by species (often with just one photo for the rarer ones), and by the date they were taken.\n" .
                        "So, you may find:\n" .
                        join("\n", @lines) . "\n" .
                        "==================***==================\n";

            # Check if block exists and build new description
            my $marker = "==================***==================";
            my $new_desc = $current_desc;
            if ($current_desc =~ /\Q$marker\E.*?\Q$marker\E/s) {
                # Replace existing block
                $new_desc =~ s/\Q$marker\E.*?\Q$marker\E/$block/s;
            } else {
                # Append if not exists
                $new_desc .= ($current_desc ? "\n" : "") . $block;
            }

            # Update if changed
            if ($new_desc ne $current_desc) {
                if (!$dry_run) {
                    eval {
                        flickr_api_call('flickr.photos.setMeta', {
                            photo_id    => $id,
                            title       => $title,  # Keep same
                            description => $new_desc
                        });
                    };
                    if ($@) {
                        warn "Failed to update photo $id: $@";
                    } else {
                        $changes{updated}++;
                        print "Updated description for photo $title ($id)";
                    }
                } else {
                    $changes{updated}++;
                    print "Would update description for photo $title (dry-run):\n\t$new_desc";
                }
            } else {
                debug_print("No change needed for photo $id");
            }
        } else {
            debug_print("No relevant sets for photo $id, skipping");
        }

        $changes{total_processed}++;
        print "Processed photo $id ($changes{total_processed} total)";
    }
    
    $photos_retrieved += $photos_in_page;
    
    print "Completed page $page of $pages (total: $photos_retrieved photos)";
    
    # Stop if we've reached max_photos
    last if (defined $max_photos && $photos_retrieved >= $max_photos);
    
    $page++;
}

# Skip if no photos found
if ($changes{total_processed} == 0) {
    print "No photos found matching the specified criteria";
    exit;
}

# Final report
print "Processing completed:";
print "  - $changes{total_processed} photos processed in total";
my $update_msg = $dry_run ? "would be updated" : "updated";
print "  - $changes{updated} photos $update_msg";