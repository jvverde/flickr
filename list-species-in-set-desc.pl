#!/usr/bin/perl
use strict;
use warnings;
use Getopt::Long;
use Data::Dumper;
use Flickr::API;
use List::Util qw(min);

# Set output field separators for printing
($\, $,) = ("\n", "\n");

# Declare variables for command-line options
my $help;
my $filter_pattern = '.*';  # Default filter pattern (matches all photosets)
my $dry_run;                # Dry-run flag to simulate without making changes
my $tag;                    # Machine tag namespace to look for

# Parse command-line options
GetOptions(
    'h|help' => \$help,             # Help flag
    'f|filter=s' => \$filter_pattern, # Filter photosets by a regular expression
    'n|dry-run' => \$dry_run,        # Dry-run mode
    't|tag=s' => \$tag,              # Machine tag namespace (required)
);

# Display help message and exit if help flag is set
if ($help) {
    print "This script updates the description of Flickr photosets by appending/replacing a species summary based on machine tags in photos.\n";
    print "It looks for machine tags in the form <TAG>:seq=NUMBER, <TAG>:binomial=NAME, and <TAG>:name=englishname in photos, counts species and genera, and updates the set description.\n";
    print "Usage: $0 [OPTIONS]\n";
    print "Options:\n";
    print "  -h, --help      Show this help message and exit\n";
    print "  -f, --filter    Filter photosets by a regular expression pattern (default: '.*')\n";
    print "  -t, --tag       Machine tag namespace to look for (required)\n";
    print "  -n, --dry-run   Simulate without making changes\n";
    print "\nNOTE: This script assumes the user's Flickr API tokens are initialized in the file '$ENV{HOME}/saved-flickr.st'.\n";
    exit;
}

# Check if tag is provided
die "Error: Tag parameter (-t) is required\n" unless defined $tag && $tag ne '';

# Load Flickr API configuration from the stored file
my $config_file = "$ENV{HOME}/saved-flickr.st";
my $flickr = Flickr::API->import_storable_config($config_file);

# Compile the filter pattern into a regular expression
my $re = qr/$filter_pattern/i;

# Retrieve all photosets matching the filter pattern
my $photosets = [];
my $page = 1;
my $pages = 1;
while ($page <= $pages) {
    my $response = $flickr->execute_method('flickr.photosets.getList', {
        per_page => 500,  # Fetch up to 500 photosets per page
        page => $page,
    });

    # Handle errors and retry if necessary
    warn "Error: $response->{error_message}" and redo unless $response->{success};

    # Filter photosets based on the provided pattern and add them to the list
    push @$photosets, grep { $_->{title} =~ $re } @{$response->as_hash->{photosets}->{photoset}};
    $pages = $response->as_hash->{photosets}->{pages};  # Total number of pages
    $page = $response->as_hash->{photosets}->{page} + 1;  # Move to the next page
}

# Process each photoset
my $total_sets_updated = 0;
foreach my $photoset (@$photosets) {
    print "Processing photoset: $photoset->{title}\n";

    # Get current photoset info
    my $info_response = $flickr->execute_method('flickr.photosets.getInfo', {
        photoset_id => $photoset->{id},
    });
    warn "Error getting info for $photoset->{title}: $info_response->{error_message}" and next unless $info_response->{success};
    my $current_desc = $info_response->as_hash->{photoset}->{description} || '';
    $current_desc = $current_desc->{_content} // '' if ref $current_desc eq 'HASH';

    # Get all photos in the photoset
    my $photos = [];
    my $photo_page = 1;
    my $photo_pages = 1;
    while ($photo_page <= $photo_pages) {
        my $photo_response = $flickr->execute_method('flickr.photosets.getPhotos', {
            photoset_id => $photoset->{id},
            per_page => 500,  # Fetch up to 500 photos per page
            page => $photo_page,
        });

        # Handle errors and retry if necessary
        warn "Error getting photos from $photoset->{title}: $photo_response->{error_message}" and redo unless $photo_response->{success};
        
        my $bunch = $photo_response->as_hash->{photoset}->{photo};
        $bunch = [ $bunch ] unless 'ARRAY' eq ref $bunch;  # Ensure the result is an array
        push @$photos, @$bunch;  # Add photos to the list
        $photo_pages = $photo_response->as_hash->{photoset}->{pages};  # Total number of pages
        $photo_page = $photo_response->as_hash->{photoset}->{page} + 1;  # Move to the next page
    }

    # Collect species data
    my %species_data;  # species => { count => n, min_seq => m, english_name => str }
    my %genera;        # genus => 1 (for counting unique genera)
    my $photos_processed = 0;
    foreach my $photo (@$photos) {
        # Get tags for the photo
        my $tag_response = $flickr->execute_method('flickr.tags.getListPhoto', {
            photo_id => $photo->{id},
        });
        if (!$tag_response->{success}) {
            warn "Error getting tags for photo $photo->{id} in $photoset->{title}: $tag_response->{error_message}";
            next;
        }
        my $tags = $tag_response->as_hash->{photo}->{tags}->{tag} || [];
        $tags = [ $tags ] unless 'ARRAY' eq ref $tags;

        # Parse machine tags with the given namespace
        my %machinetags;
        foreach my $t (@$tags) {
            if ($t->{machine_tag} && $t->{raw} =~ /^\Q$tag\E:([^=]+)=(.+)$/i) {
                my ($pred, $val) = ($1, $2);
                # Unquote value if quoted
                if ($val =~ /^"(.*)"$/) {
                    $val = $1;
                    $val =~ s/\\"/"/g;
                }
                $machinetags{$pred} = $val;
            }
        }

        # Check for seq, binomial, and name
        if (exists $machinetags{seq} && $machinetags{seq} =~ /^\d+$/ && exists $machinetags{binomial}) {
            my $species = $machinetags{binomial};
            my $seq = $machinetags{seq};
            my $english_name = $machinetags{name} // 'Unknown';
            $species_data{$species}{count}++;
            $species_data{$species}{min_seq} = min($species_data{$species}{min_seq} // 999999, $seq);
            $species_data{$species}{english_name} = $english_name unless defined $species_data{$species}{english_name} && $species_data{$species}{english_name} ne 'Unknown';
            # Extract genus (first word of binomial name)
            if ($species =~ /^(\w+)/) {
                $genera{$1} = 1;
            }
        }

        $photos_processed++;
        print "  Processed $photos_processed photos..." if $photos_processed % 10 == 0;
    }

    # If no species found, skip update
    if (!%species_data) {
        print "No species found in photoset: $photoset->{title}\n";
        next;
    }

    # Generate summary
    my $total_species = scalar keys %species_data;
    my $total_genera = scalar keys %genera;
    my @sorted_species = sort { $species_data{$a}{min_seq} <=> $species_data{$b}{min_seq} } keys %species_data;
    my $species_list = join(",\n", map { "$_ // $species_data{$_}{english_name} ($species_data{$_}{count})" } @sorted_species);
    my $summary = "Total species: $total_species\nTotal genera: $total_genera\nSpecies in this set:\n$species_list";

    # Delimiters for the summary section
    my $delim_start = "--- Species Summary ---";
    my $delim_end = "--- End Species Summary ---";

    # Update description
    my $new_desc = $current_desc;
    unless ($new_desc =~ s/(?<=\Q$delim_start\E).*(?=\Q$delim_end\E)/\n$summary\n/s) {
        $new_desc .= "\n\n$delim_start\n" . $summary . "\n$delim_end\n" 
    }

    if ($dry_run) {
        print "DRY RUN: Would update description for $photoset->{title} to:\n$new_desc\n";
    } else {
        # Update the photoset metadata
        $new_desc =~ s/^\n+|\n+$//g; 
        my $edit_response = $flickr->execute_method('flickr.photosets.editMeta', {
            photoset_id => $photoset->{id},
            title => $photoset->{title},
            description => $new_desc,
        });
        if (!$edit_response->{success}) {
            warn "Error updating description for $photoset->{title}: $edit_response->{error_message}";
            next;
        }
        print "Updated description for photoset: $photoset->{title}\n";
        $total_sets_updated++;
    }
}

print "\nCompleted! Processed " . scalar(@$photosets) . " photosets." . ($dry_run ? "" : " Updated $total_sets_updated photosets.") . "\n";