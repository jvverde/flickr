#!/usr/bin/perl
use strict;
use warnings;
use Getopt::Long;
use Flickr::API;
use JSON;
use POSIX qw(strftime);
use Time::Local 'timegm';
use Data::Dumper;  # For debug output
binmode(STDOUT, ':utf8');

# Set output record and field separators
$\ = "\n";
$, = " ";

# Initialize JSON parser with UTF-8 encoding
my $json = JSON->new->utf8;

# Load Flickr API configuration from storable config file
my $config_file = "$ENV{HOME}/saved-flickr.st";
my $flickr = Flickr::API->import_storable_config($config_file);

# Global debug flag (undef = off, 1+ = debug level)
my $debug;

# Enhanced usage subroutine to display detailed help message
sub usage {
    print <<'END_USAGE';
Search all user photos on Flickr, retrieve title, description, tags, and photosets (sets) they belong to, and update a local JSON file.

Usage:
  $0 [--out <file>] [--after <date>] [--before <date>] [--days <days>] [--max-photos <num>] [--tag <tag>]... [--page <num>] [--debug [<level>]]
  $0 [-o <file>] [-a <date>] [-b <date>] [-d <days>] [-m <num>] [-t <tag>]... [-p <num>] [--debug [<level>]]
  $0 --help

Options:
  -o, --out          Output JSON file to store updated data (optional; if not provided, output to stdout)
  -a, --after        Minimum upload date in YYYY-MM-DD format to include photos uploaded after or on this date
  -b, --before       Maximum upload date in YYYY-MM-DD format to include photos uploaded before or on this date
  -d, --days         Number of days to look back for photos uploaded in the last N days
  -m, --max-photos   Maximum number of photos to retrieve (optional)
  -t, --tag          Filter by tag (can be specified multiple times for multiple tags)
  -p, --page         Start from specific page number (optional)
  --debug [<level>]  Enable debug output (level controls Dumper depth, default: 1)
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
            $retry_delay *= 3;  # Exponential backoff
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

# Get geo location information for a single photo
sub get_photo_geo {
    my ($pid) = @_;
    
    debug_print("Getting geo location for photo: $pid");
    
    my $response = eval {
        flickr_api_call('flickr.photos.geo.getLocation', { photo_id => $pid })
    };
    
    if ($@) {
        # It's normal for many photos to not have geo data, so only debug print
        debug_print("No geo location found for photo $pid (normal)");
        return undef;
    }
    
    my $hash = $response->as_hash();
    my $location = $hash->{photo}->{location} || {};
    
    # Extract relevant geo data
    my $geo_data = {};
    $geo_data->{latitude} = $location->{latitude} if exists $location->{latitude};
    $geo_data->{longitude} = $location->{longitude} if exists $location->{longitude};
    $geo_data->{accuracy} = $location->{accuracy} if exists $location->{accuracy};
    
    # Get location description if available - these are already strings
    if (exists $location->{locality} || exists $location->{county} || 
        exists $location->{region} || exists $location->{country}) {
        $geo_data->{location} = {};
        $geo_data->{location}{locality} = $location->{locality} 
            if exists $location->{locality};
        $geo_data->{location}{county} = $location->{county} 
            if exists $location->{county};
        $geo_data->{location}{region} = $location->{region} 
            if exists $location->{region};
        $geo_data->{location}{country} = $location->{country} 
            if exists $location->{country};
    }
    
    if (%$geo_data) {
        debug_print("Geo location found for photo $pid", $geo_data);
        return $geo_data;
    } else {
        debug_print("No geo location data for photo $pid");
        return undef;
    }
}

# Merge photo data with existing data and update history
sub merge_photo_data {
    my ($pid, $flickr_data, $photos_ref, $changes_ref) = @_;
    
    # Add info_update timestamp
    $flickr_data->{info_updated} = strftime("%Y-%m-%d %H:%M:%S", localtime());
    
    # Merge with existing data
    if (exists $photos_ref->{$pid}) {
        # Photo exists in old data - merge with history
        my $old_data = $photos_ref->{$pid};
        my $merged_data = {
            date_upload     => $flickr_data->{date_upload},
            date_uploaded   => $flickr_data->{date_uploaded},
            photo_page_url  => $flickr_data->{photo_page_url},
            tags            => $flickr_data->{tags},
            sets            => $flickr_data->{sets},
            title           => $flickr_data->{title},
            description     => $flickr_data->{description},
            geo             => $flickr_data->{geo},
            info_updated    => $flickr_data->{info_updated}
        };
        
        # Initialize history structure if it doesn't exist
        $merged_data->{history} = $old_data->{history} // {};
        
        # Check for title changes and update history
        my $title_changed = 0;
        my $current_old_title = $old_data->{title};
        
        if ($flickr_data->{title} ne $current_old_title) {
            $title_changed = 1;
            $changes_ref->{detected} = 1;
            debug_print("Title changed for photo $pid: '$current_old_title' -> '$flickr_data->{title}'");
            
            # Initialize titles object if it doesn't exist
            $merged_data->{history}{titles} //= {};
            
            # Add current old title to history using the old_data's info_updated timestamp
            my $old_timestamp = $old_data->{info_updated};
            $merged_data->{history}{titles}{$old_timestamp} = $current_old_title;
        }
        
        # Check for description changes and update history
        my $desc_changed = 0;
        my $current_old_description = $old_data->{description};
        
        if ($flickr_data->{description} ne $current_old_description) {
            $desc_changed = 1;
            $changes_ref->{detected} = 1;
            debug_print("Description changed for photo $pid");
            
            # Initialize descriptions object if it doesn't exist
            $merged_data->{history}{descriptions} //= {};
            
            # Add current old description to history using the old_data's info_updated timestamp
            my $old_timestamp = $old_data->{info_updated};
            $merged_data->{history}{descriptions}{$old_timestamp} = $current_old_description;
        }
        
        # Clean up empty history
        if (exists $merged_data->{history}) {
            delete $merged_data->{history}{titles} 
                if exists $merged_data->{history}{titles} && !%{$merged_data->{history}{titles}};
            delete $merged_data->{history}{descriptions} 
                if exists $merged_data->{history}{descriptions} && !%{$merged_data->{history}{descriptions}};
            delete $merged_data->{history} 
                if !%{$merged_data->{history}};
        }
        
        $photos_ref->{$pid} = $merged_data;
        $changes_ref->{updated}++ if $title_changed || $desc_changed;
        
    } else {
        # New photo - no history needed initially
        $photos_ref->{$pid} = { %$flickr_data };
        $changes_ref->{added}++;
        $changes_ref->{detected} = 1;
        debug_print("New photo added: $pid", $flickr_data);
    }
    
    return 1;
}

# Write JSON output to file or stdout
sub write_output {
    my ($photos_ref, $out_file) = @_;
    my $json_output = $json->pretty->encode($photos_ref);
    
    if (defined $out_file) {
        writefile($out_file, $json_output);
        print "Updated JSON file at $out_file";
    } else {
        print $json_output;
    }
}

# Declare variables for command-line options
my ($out, $after_date, $before_date, $days, $max_photos, $start_page);
my @tags;

# Parse command-line options with optional debug level
GetOptions(
    "o|out=s"          => \$out,
    "a|after=s"        => \$after_date,
    "b|before=s"       => \$before_date,
    "d|days=i"         => \$days,
    "m|max-photos=i"   => \$max_photos,
    "t|tag=s"          => \@tags,
    "p|page=i"         => \$start_page,
    "debug:i"          => \$debug,  # Optional integer argument
    "h|help"           => \&usage
) or usage();

# Set default debug level if --debug is used without argument
if (defined $debug && $debug == 0) {
    $debug = 1;  # Default depth when --debug is used without value
}

# Debug mode announcement
if (defined $debug) {
    print "DEBUG MODE ENABLED (level: $debug)";
    debug_print("Command line options:", {
        out => $out,
        after_date => $after_date,
        before_date => $before_date, 
        days => $days,
        max_photos => $max_photos,
        start_page => $start_page,
        tags => \@tags
    });
}

# Load existing photos from file if --out is provided and file exists
my %photos;
if (defined $out && -f $out && -s $out) {
    my $loaded = $json->decode(readfile($out));
    %photos = %$loaded if ref $loaded eq 'HASH';
    debug_print("Loaded " . scalar(keys %photos) . " existing photos from $out");
} elsif (defined $out) {
    debug_print("No existing photo file found at $out, starting fresh");
}

# Build search arguments - include geo extras if available
my $search_args = {
    user_id  => 'me',
    per_page => 500,
    extras   => 'date_upload,owner,title,description,tags,geo',
    page     => $start_page || 1
};

# Add date filters
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
    detected => 0,
    added => 0,
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
    print "Processing page $page of $pages ($photos_in_page photos)";
    
    # Process each photo in this page
    foreach my $photo (@$photos) {
        my $id = $photo->{id};
        my $page_url = "https://www.flickr.com/photos/$photo->{owner}/$id/";
        my $date_upload = $photo->{dateupload};
        my $date_uploaded = strftime("%Y-%m-%d %H:%M:%S", localtime($date_upload));
        my $title = $photo->{title} // '';
        my $description = $photo->{description} // '';
        my $tags_str = $photo->{tags} // '';
        my @tags_array = split /\s+/, $tags_str;

        debug_print("Processing photo $id: '$title'");

        my $flickr_data = {
            date_upload     => $date_upload,
            date_uploaded   => $date_uploaded,
            title           => $title,
            description     => $description,
            tags            => \@tags_array,
            sets            => get_photo_sets($id) || {},
            geo             => undef,  # Initialize as undef
            photo_page_url  => $page_url
        };
        
        # Only get geo location if the photo has geo data (check for geo permission flags)
        if (exists $photo->{geo_is_public} || exists $photo->{geo_is_contact} || exists $photo->{geo_is_family} || exists $photo->{geo_is_friend}) {
            $flickr_data->{geo} = get_photo_geo($id);
        } else {
            debug_print("Photo $id has no geo data, skipping geo API call");
        }
        
        # Merge with existing data
        if (merge_photo_data($id, $flickr_data, \%photos, \%changes)) {
            $changes{total_processed}++;
            print "Processed photo $id ($changes{total_processed} total)";
        }
        
        # Update output file after each photo if --out is provided
        if (defined $out && $changes{detected}) {
            write_output(\%photos, $out);
            # Reset detected flag after writing to avoid multiple writes for same change
            $changes{detected} = 0;
        }
    }
    
    $photos_retrieved += $photos_in_page;
    $pages = $hash->{photos}->{pages} || 1;
    
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
print "  - $changes{added} new photos added";
print "  - $changes{updated} existing photos updated";

# Final write to ensure all changes are saved (if output file specified)
if (defined $out) {
    write_output(\%photos, $out);
} else {
    # If no output file, print final JSON to stdout
    write_output(\%photos, undef);
}