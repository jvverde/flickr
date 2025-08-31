#!/usr/bin/perl
use strict;
use warnings;
use Getopt::Long;
use Flickr::API;
use File::Slurp;
use Data::Dumper;

# Set UTF-8 encoding for output to handle special characters properly
binmode(STDOUT, ':utf8');
# Set output record separator to newline for cleaner output
$\ = "\n";

# Enhanced usage function with more detailed information
sub usage {
    print "This script removes specific tags from the current user's Flickr photos.";
    print "Usage: $0 [OPTIONS] FILENAME";
    print "Options:";
    print "  -h, --help    Show this help message and exit";
    print "";
    print "FILENAME must contain a list of tags to remove (one per line)";
    print "Only tags matching the pattern 'species:number=' will be processed";
    print "";
    print "NOTE: The script requires Flickr API authentication tokens";
    print "      stored in the file: '$ENV{HOME}/saved-flickr.st'";
    print "";
    print "Example:";
    print "  $0 tags_to_remove.txt";
    exit;
}

# Parse command line options
GetOptions(
    'h|help' => \&usage
) or usage();  # Show usage if options parsing fails

# Check if filename argument is provided
my $filename = shift @ARGV;
usage() unless $filename;  # Show usage instead of die for better UX
die "File not found: $filename\n" unless -e $filename;

# Load Flickr API configuration from stored authentication tokens
my $config_file = "$ENV{HOME}/saved-flickr.st";
my $flickr;
eval {
    $flickr = Flickr::API->import_storable_config($config_file);
};
die "Failed to load Flickr configuration from $config_file: $@\n" if $@;

# Read and filter tags from the input file
# Only process tags that match the pattern 'species:number='
my @alltags = grep { /species:number=/ } read_file($filename, chomp => 1, binmode => ':utf8');

# Create a hash for quick lookup of tags to remove
my %taglist = map { $_ => 1 } @alltags;

# Process each tag sequentially
foreach my $tag (sort @alltags) {
    print "Searching for photos with tag: '$tag'";
    
    # Search for photos belonging to the current user with the specific tag
    my $response = $flickr->execute_method('flickr.photos.search', {
        user_id => 'me',          # Search current user's photos
        tags => $tag,             # Filter by the specific tag
        per_page => 500,          # Maximum results per page
        page => 1                 # Start with first page
    });

    # Handle API errors with retry capability
    unless ($response->{success}) {
        warn "Error retrieving photos: $response->{error_message}\n\n";
        redo;  # Retry the same tag
    }

    my $data = $response->as_hash();
    
    # Skip if no valid data returned
    unless (defined $data && defined $data->{photos}) {
        warn "No photo data received for tag: $tag";
        next;
    }

    my $photos = $data->{photos}->{photo};
    
    # Skip if no photos found with this tag
    unless (defined $photos) {
        print "No photos found with tag: $tag";
        next;
    }

    # Ensure photos is an array reference for consistent processing
    $photos = [$photos] if 'ARRAY' ne ref $photos;
    
    # Extract photo IDs from the search results
    my @ids = grep { $_ } map { $_->{id} } @$photos;

    # Process each photo found with the current tag
    foreach my $id (@ids) {
        # Get all tags for the current photo
        my $response = $flickr->execute_method('flickr.tags.getListPhoto', { 
            photo_id => $id 
        });

        # Handle API errors for tag retrieval
        unless ($response->{success}) {
            warn "Error retrieving tags for photo $id ($tag): $response->{error_message}\n";
            redo;  # Retry the same photo
        }

        my $data = $response->as_hash();
        
        # Skip if no tag data received
        next unless defined $data && defined $data->{photo};

        my $tags = $data->{photo}->{tags}->{tag};
        
        # Ensure tags is an array reference
        $tags = [$tags] if 'ARRAY' ne ref $tags;
        
        # Filter tags to find only those that match our removal list
        my @phototags = grep { exists $taglist{$_->{content}} } @$tags;

        # Remove each matching tag from the photo
        my $retry = 0;
        foreach my $phototag (@phototags) {
            print "Removing tag '$phototag->{content}' from photo ID: $id";
            
            my $response = $flickr->execute_method('flickr.photos.removeTag', { 
                tag_id => $phototag->{id} 
            });
            
            # Handle removal errors with retry mechanism (max 10 retries)
            unless ($response->{success}) {
                warn "Error removing tag '$phototag->{content}': $response->{error_message}";
                if ($retry < 10) {
                    $retry++;
                    redo;  # Retry the same tag removal
                } else {
                    warn "Maximum retries exceeded for tag removal";
                    $retry = 0;
                    next;
                }
            }
            
            $retry = 0;  # Reset retry counter after successful operation
        }
    }
}

print "Tag removal process completed.";