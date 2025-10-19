#!/usr/bin/perl
use strict;
use warnings;
use Getopt::Long;
use Flickr::API;
use JSON;
use POSIX qw(strftime);
use Time::Local 'timegm';
binmode(STDOUT, ':utf8');

# Set output record and field separators
$\ = "\n";
$, = " ";

# Initialize JSON parser with UTF-8 encoding
my $json = JSON->new->utf8;

# Load Flickr API configuration from storable config file
my $config_file = "$ENV{HOME}/saved-flickr.st";
my $flickr = Flickr::API->import_storable_config($config_file);

# Enhanced usage subroutine to display detailed help message
sub usage {
    print <<'END_USAGE';
Search all user photos on Flickr, retrieve title, description, tags, and photosets (sets) they belong to, and update a local JSON file.

Usage:
  $0 [--out <file>] [--after <date>] [--before <date>] [--days <days>] [--max-photos <num>] [--tag <tag>]...
  $0 [-o <file>] [-a <date>] [-b <date>] [-d <days>] [-m <num>] [-t <tag>]...
  $0 --help

Options:
  -o, --out          Output JSON file to store updated data (optional; if not provided, output to stdout)
  -a, --after        Minimum upload date in YYYY-MM-DD format to include photos uploaded after or on this date
  -b, --before       Maximum upload date in YYYY-MM-DD format to include photos uploaded before or on this date
  -d, --days         Number of days to look back for photos uploaded in the last N days
  -m, --max-photos   Maximum number of photos to retrieve (optional)
  -t, --tag          Filter by tag (can be specified multiple times for multiple tags)
  -h, --help         Display this help message and exit

The script searches for all photos of the authenticated user,
retrieves title, description, tags (as array), and sets (photosets titles as array),
builds a hash indexed by photo_id,
with values being hashes of {date_upload, date_uploaded, title, description, tags, sets, photo_page_url}.
It loads existing data from the output file if it exists and --out is provided,
fetches current data from Flickr (filtered by date/tags if provided),
and saves the updated data to the output JSON file only if changes are detected (or outputs to stdout if --out not provided).
END_USAGE
    exit;
}

# Read content from a file
sub readfile {
    my ($filename) = @_;
    open(my $fh, "<", $filename) or die("Cannot open $filename: $!");
    local $/;
    my $content = <$fh>;
    close $fh;
    return $content;
}

# Write content to a file
sub writefile {
    my ($filename, $content) = @_;
    open(my $fh, ">", $filename) or die("Cannot open $filename for writing: $!");
    print $fh $content;
    close $fh;
}

# Convert date string to timestamp (end of day for before, start of day for after)
sub date_to_timestamp {
    my ($date_string, $end_of_day) = @_;
    unless ($date_string =~ m/^(\d{4})-(\d{2})-(\d{2})$/) {
        die "Invalid date format: $date_string. Must be YYYY-MM-DD.";
    }
    my ($y, $m, $d) = ($1, $2, $3);
    eval {
        if ($end_of_day) {
            # End of day (23:59:59 UTC)
            return timegm(59, 59, 23, $d, $m - 1, $y);
        } else {
            # Start of day (00:00:00 UTC)
            return timegm(0, 0, 0, $d, $m - 1, $y);
        }
    };
    if ($@) {
        die "Invalid date values for $date_string: $@";
    }
}

# Declare variables for command-line options
my ($out, $after_date, $before_date, $days, $max_photos);
my @tags;

# Parse command-line options
GetOptions(
    "o|out=s"          => \$out,
    "a|after=s"        => \$after_date,
    "b|before=s"       => \$before_date,
    "d|days=i"         => \$days,
    "m|max-photos=i"   => \$max_photos,
    "t|tag=s"          => \@tags,
    "h|help"           => \&usage
) or usage();

# Validate date options
if (defined $after_date) {
    $after_date = date_to_timestamp($after_date, 0);  # Start of day
}
if (defined $before_date) {
    $before_date = date_to_timestamp($before_date, 1);  # End of day
}

# Handle --days option
if (defined $days) {
    my $now = time();
    my $days_ago = $now - ($days * 24 * 60 * 60);
    $after_date = $days_ago unless defined $after_date;
    
    # If only --days is specified, set before_date to now
    $before_date = $now unless defined $before_date;
}

# Validate that after_date is before before_date if both are specified
if (defined $after_date && defined $before_date && $after_date >= $before_date) {
    die "Error: --after date must be before --before date";
}

# Validate max_photos
if (defined $max_photos && $max_photos <= 0) {
    die "Error: --max-photos must be a positive number";
}

# Load existing photos from file if --out is provided and file exists
my %photos;
if (defined $out && -f $out && -s $out) {
    my $loaded = $json->decode(readfile($out));
    %photos = %$loaded if ref $loaded eq 'HASH';
}

# Build search arguments
my $search_args = {
    user_id  => 'me',
    per_page => 500,
    extras   => 'date_upload,owner,title,description,tags',
    page     => 1
};

# Add date filters
$search_args->{min_upload_date} = $after_date if defined $after_date;
$search_args->{max_upload_date} = $before_date if defined $before_date;

# Add tag filters if specified
if (@tags) {
    $search_args->{tags} = join(',', @tags);
    $search_args->{tag_mode} = 'all';  # Require all tags (AND logic)
}

# Search for all photos, handling multiple pages
my $page = 1;
my @all_photos;
my $pages = 1;
my $photos_retrieved = 0;

do {
    $search_args->{page} = $page;
    
    my $response = eval {
        $flickr->execute_method('flickr.photos.search', $search_args)
    };
    if ($@ || !$response->{success}) {
        warn "Error retrieving photos for page $page: $@ or $response->{error_message}";
        sleep 1;
        redo;
    }

    my $hash = $response->as_hash();
    my $photos_list = $hash->{photos}->{photo} || [];
    $photos_list = [$photos_list] unless ref $photos_list eq 'ARRAY';
    
    # Check if we've reached max_photos limit
    if (defined $max_photos) {
        my $remaining = $max_photos - $photos_retrieved;
        if (@$photos_list > $remaining) {
            # Take only what we need from this page
            push @all_photos, @$photos_list[0..$remaining-1];
            $photos_retrieved += $remaining;
            last;
        }
    }
    
    push @all_photos, @$photos_list;
    $photos_retrieved += scalar(@$photos_list);

    $pages = $hash->{photos}->{pages} || 1;
    print "Got page $page of $pages ($photos_retrieved photos so far)";
    
    # Stop if we've reached max_photos
    last if (defined $max_photos && $photos_retrieved >= $max_photos);
    
    $page++;
} while ($page <= $pages);

# Skip if no photos found
if (!@all_photos) {
    print "No photos found matching the specified criteria";
    exit;
}

print "Retrieved " . scalar(@all_photos) . " photos total";

# Build new photos data from Flickr
my %photos_new_flickr;
foreach my $photo (@all_photos) {
    my $id = $photo->{id};
    my $page_url = "https://www.flickr.com/photos/$photo->{owner}/$id/";
    my $date_upload = $photo->{dateupload};
    my $date_uploaded = strftime("%Y-%m-%d %H:%M:%S", localtime($date_upload));
    my $title = $photo->{title} // '';
    my $description = $photo->{description} // '';
    my $tags_str = $photo->{tags} // '';
    my @tags_array = split /,/, $tags_str;

    $photos_new_flickr{$id} = {
        date_upload     => $date_upload,
        date_uploaded   => $date_uploaded,
        title           => $title,
        description     => $description,
        tags            => \@tags_array,
        sets            => [],  # Now will store {id, title} objects
        photo_page_url  => $page_url
    };
}

# Use flickr.photos.getAllContexts to get sets for each photo
my @photo_ids = keys %photos_new_flickr;
my $total_photos = scalar(@photo_ids);

print "Getting sets for $total_photos photos using getAllContexts";

foreach my $pid (@photo_ids) {
    my $context_response = eval {
        $flickr->execute_method('flickr.photos.getAllContexts', { photo_id => $pid })
    };
    
    if ($@ || !$context_response->{success}) {
        warn "Error getting contexts for photo $pid: $@ or " . 
             ($context_response->{error_message} // 'Unknown error');
        sleep 1;
        redo;
    }
    
    my $context_hash = $context_response->as_hash();
    my $sets_list = $context_hash->{set} || [];
    $sets_list = [$sets_list] unless ref $sets_list eq 'ARRAY';
    
    my @sets_info;
    foreach my $set (@$sets_list) {
        my $set_id = $set->{id} // '';
        my $set_title = $set->{title} // '';
        if ($set_id && $set_title) {
            push @sets_info, {
                id => $set_id,
                title => $set_title
            };
        }
    }
    
    if (@sets_info) {
        # Sort by set ID for consistency
        @sets_info = sort { $a->{id} cmp $b->{id} } @sets_info;
        $photos_new_flickr{$pid}{sets} = \@sets_info;
    }
    
    print "Processed photo $pid";
}

# Merge existing data with new Flickr data, preserving history for title and description
my %photos_merged;
my $changes_detected = 0;
my $photos_updated = 0;
my $photos_added = 0;

foreach my $photo_id (keys %photos_new_flickr) {
    my $flickr_data = $photos_new_flickr{$photo_id};
    
    if (exists $photos{$photo_id}) {
        # Photo exists in old data - merge with history
        my $old_data = $photos{$photo_id};
        my $merged_data = {
            date_upload     => $flickr_data->{date_upload},
            date_uploaded   => $flickr_data->{date_uploaded},
            photo_page_url  => $flickr_data->{photo_page_url},
            tags            => $flickr_data->{tags},
            sets            => $flickr_data->{sets},  # Now includes both id and title
            title           => $flickr_data->{title},
            description     => $flickr_data->{description}
        };
        
        # Initialize history structure if it doesn't exist
        if (exists $old_data->{history}) {
            $merged_data->{history} = { %{$old_data->{history}} };
        } else {
            $merged_data->{history} = {};
        }
        
        # Check for title changes and update history
        my $title_changed = 0;
        my $current_old_title = $old_data->{title};
        
        if ($flickr_data->{title} ne $current_old_title) {
            $title_changed = 1;
            $changes_detected = 1;
            
            # Initialize titles array if it doesn't exist
            if (!exists $merged_data->{history}{titles}) {
                $merged_data->{history}{titles} = [];
            }
            
            # Add current old title to history if it's different from what we're about to set
            push @{$merged_data->{history}{titles}}, {
                date => strftime("%Y-%m-%d %H:%M:%S", localtime()),
                value => $current_old_title
            };
        }
        
        # Check for description changes and update history
        my $desc_changed = 0;
        my $current_old_description = $old_data->{description};
        
        if ($flickr_data->{description} ne $current_old_description) {
            $desc_changed = 1;
            $changes_detected = 1;
            
            # Initialize descriptions array if it doesn't exist
            if (!exists $merged_data->{history}{descriptions}) {
                $merged_data->{history}{descriptions} = [];
            }
            
            # Add current old description to history
            push @{$merged_data->{history}{descriptions}}, {
                date => strftime("%Y-%m-%d %H:%M:%S", localtime()),
                value => $current_old_description
            };
        }
        
        # Clean up empty history
        if (exists $merged_data->{history}) {
            if (exists $merged_data->{history}{titles} && !@{$merged_data->{history}{titles}}) {
                delete $merged_data->{history}{titles};
            }
            if (exists $merged_data->{history}{descriptions} && !@{$merged_data->{history}{descriptions}}) {
                delete $merged_data->{history}{descriptions};
            }
            if (!%{$merged_data->{history}}) {
                delete $merged_data->{history};
            }
        }
        
        $photos_merged{$photo_id} = $merged_data;
        $photos_updated++ if $title_changed || $desc_changed;
        
    } else {
        # New photo - no history needed initially
        $photos_merged{$photo_id} = { %$flickr_data };
        $photos_added++;
        $changes_detected = 1;
    }
}

# Report changes
if ($changes_detected) {
    print "Changes detected:";
    print "  - $photos_added new photos added";
    print "  - $photos_updated existing photos updated";
} else {
    print "No changes detected in title or description";
}

# Prepare pretty JSON output
my $json_output = $json->pretty->encode(\%photos_merged);

# Write if --out provided, else print to stdout
if (defined $out) {
    writefile($out, $json_output);
    print "Updated JSON file at $out";
} else {
    print $json_output;
}