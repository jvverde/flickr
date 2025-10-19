#!/usr/bin/perl
use strict;
use warnings;
use Getopt::Long;
use Flickr::API;

# Set UTF-8 encoding for output to handle special characters properly
binmode(STDOUT, ':utf8');
# Set output record separator to newline for cleaner output
$\ = "\n";

# Enhanced usage function with more detailed information
sub usage {
    print "This script removes all tags matching the pattern 'species:number=' from the current user's Flickr photos.";
    print "Usage: $0 [OPTIONS]";
    print "Options:";
    print "  -h, --help    Show this help message and exit";
    print "  -n, --dry-run Simulate the removal without actually deleting tags";
    print "";
    print "NOTE: The script requires Flickr API authentication tokens";
    print "      stored in the file: '$ENV{HOME}/saved-flickr.st'";
    print "";
    print "Example:";
    print "  $0";
    print "  $0 --dry-run";
    exit;
}

my $dry_run = 0;

# Parse command line options
GetOptions(
    'h|help' => \&usage,
    'n|dry-run' => \$dry_run
) or usage();  # Show usage if options parsing fails

# Load Flickr API configuration from stored authentication tokens
my $config_file = "$ENV{HOME}/saved-flickr.st";
my $flickr;
eval {
    $flickr = Flickr::API->import_storable_config($config_file);
};
die "Failed to load Flickr configuration from $config_file: $@\n" if $@;

# Search for all photos with machine tags matching 'species:number=*'
print "Searching for photos with machine tags 'species:number=*'", ($dry_run ? " (dry run)" : "");

my @ids;
my $page = 1;
my $pages = 1;  # Initialize to enter the loop
do {
    my $response = $flickr->execute_method('flickr.photos.search', {
        user_id => 'me',                # Search current user's photos
        machine_tags => 'species:number=*',  # Filter by machine tag pattern
        per_page => 500,                # Maximum results per page
        page => $page                   # Current page
    });

    # Handle API errors
    unless ($response->{success}) {
        warn "Error retrieving photos on page $page: $response->{error_message}\n\n";
        $page++;
        next;
    }

    my $data = $response->as_hash();
    
    # Skip if no valid data returned
    unless (defined $data && defined $data->{photos}) {
        warn "No photo data received on page $page";
        $page++;
        next;
    }

    # Update total pages after first response
    $pages = $data->{photos}->{pages} if $page == 1;

    my $photos = $data->{photos}->{photo};
    
    # Skip if no photos found on this page
    unless (defined $photos) {
        if ($page == 1) {
            print "No photos found with matching tags";
            exit;
        }
        $page++;
        next;
    }

    # Ensure photos is an array reference for consistent processing
    $photos = [$photos] if 'ARRAY' ne ref $photos;
    
    # Extract photo IDs from the search results
    push @ids, grep { $_ } map { $_->{id} } @$photos;

    $page++;
} while ($page <= $pages);

print "Found " . scalar(@ids) . " photos with matching tags.";

# Process each photo found
foreach my $id (@ids) {
    # Get all tags for the current photo
    my $response = $flickr->execute_method('flickr.tags.getListPhoto', { 
        photo_id => $id 
    });

    # Handle API errors for tag retrieval
    unless ($response->{success}) {
        warn "Error retrieving tags for photo $id: $response->{error_message}\n";
        next;
    }

    my $data = $response->as_hash();
    
    # Skip if no tag data received
    next unless defined $data && defined $data->{photo};

    my $tags = $data->{photo}->{tags}->{tag};
    
    # Ensure tags is an array reference
    $tags = [$tags] if 'ARRAY' ne ref $tags;
    
    # Filter tags to find only those that match the pattern
    my @phototags = grep { $_->{content} =~ /species:number=/ } @$tags;

    # Remove each matching tag from the photo
    foreach my $phototag (@phototags) {
        if ($dry_run) {
            print "Would remove tag '$phototag->{content}' from photo ID: $id";
            next;
        }
        
        print "Removing tag '$phototag->{content}' from photo ID: $id";
        
        my $response = $flickr->execute_method('flickr.photos.removeTag', { 
            tag_id => $phototag->{id} 
        });
        
        # Handle removal errors
        unless ($response->{success}) {
            warn "Error removing tag '$phototag->{content}': $response->{error_message}";
            next;
        }
    }
}

print(($dry_run ? "Dry run" : "Tag removal process") . " completed.");