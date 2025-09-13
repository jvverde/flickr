#!/usr/bin/perl
use strict;
use warnings;
use Getopt::Long;
use Data::Dumper;
use Flickr::API;

# Set output field separators for printing
($\, $,) = ("\n", "\n");

# Declare variables for command-line options
my $help;
my $filter_pattern = '.*';  # Default filter pattern (matches all photosets)
my $dry_run;                # Dry-run flag to simulate without making changes
my $tag;                    # Tag to add to photos

# Parse command-line options
GetOptions(
    'h|help' => \$help,             # Help flag
    'f|filter=s' => \$filter_pattern, # Filter photosets by a regular expression
    'n|dry-run' => \$dry_run,        # Dry-run mode
    't|tag=s' => \$tag,              # Tag to add to photos (required)
);

# Display help message and exit if help flag is set
if ($help) {
    print "This script adds a specific tag to all photos in Flickr sets matching a given pattern.\n";
    print "Usage: $0 [OPTIONS]\n";
    print "Options:\n";
    print "  -h, --help      Show this help message and exit\n";
    print "  -f, --filter    Filter photosets by a regular expression pattern (default: '.*')\n";
    print "  -t, --tag       Tag to add to photos (required)\n";
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

# If dry-run mode is enabled, print the photosets that would be processed and exit
if ($dry_run) {
    print "DRY RUN: Would add tag '$tag' to photos in the following photosets:\n";
    print map { "  - $_->{title}\n" } @$photosets;
    exit;
}

# Process each photoset
my $total_photos_tagged = 0;
foreach my $photoset (@$photosets) {
    my $photos = [];
    my $page = 1;
    my $pages = 1;
    
    print "Processing photoset: $photoset->{title}\n";
    
    while ($page <= $pages) {
        # Fetch photos from the current photoset
        my $response = $flickr->execute_method('flickr.photosets.getPhotos', {
            photoset_id => $photoset->{id},
            per_page => 500,  # Fetch up to 500 photos per page
            page => $page,
        });

        # Handle errors and retry if necessary
        warn "Error getting photos from $photoset->{title}: $response->{error_message}" and redo unless $response->{success};
        
        my $bunch = $response->as_hash->{photoset}->{photo};
        $bunch = [ $bunch ] unless 'ARRAY' eq ref $bunch;  # Ensure the result is an array
        push @$photos, @$bunch;  # Add photos to the list
        $pages = $response->as_hash->{photoset}->{pages};  # Total number of pages
        $page = $response->as_hash->{photoset}->{page} + 1;  # Move to the next page
    }

    # Add tag to each photo in the photoset
    my $photos_tagged = 0;
    foreach my $photo (@$photos) {
        # Add the tag to the photo
        my $response = $flickr->execute_method('flickr.photos.addTags', {
            photo_id => $photo->{id},
            tags => $tag,
        });

        # Handle errors and continue to the next photo
        if (!$response->{success}) {
            warn "Error adding tag to photo $photo->{id} in $photoset->{title}: $response->{error_message}";
            redo;
        }
        
        $photos_tagged++;
        $total_photos_tagged++;
        
        # Print progress every 10 photos
        print "  Tagged $photos_tagged photos..." if $photos_tagged % 10 == 0;
    }
    
    print "Added tag '$tag' to $photos_tagged photos in photoset: $photoset->{title}\n";
}

print "\nCompleted! Added tag '$tag' to $total_photos_tagged photos across " . scalar(@$photosets) . " photosets.\n";