#!/usr/bin/perl
use strict;    # Enforce variable declaration and other strict checks
use warnings;  # Enable warnings for potential issues
use Getopt::Long;    # Module for command-line option parsing
use Flickr::API;     # Perl interface to the Flickr API
use File::Slurp;     # For easy file reading/writing
use Data::Dumper;    # For data structure debugging/dumping

# Set output to UTF-8 encoding to handle special characters properly
binmode(STDOUT, ':utf8');

# Set output record separator to newline for automatic line endings
$\ = "\n";

# Subroutine to display usage information and exit
sub usage {
    print "This script removes tags matching the given regular expression from the current user's photos.";
    print "Usage: $0 [OPTIONS] REGEX";
    print "Options:";
    print "  -h, --help    Show this help message and exit";
    print "REGEX must be a valid regular expression to match tags";
    print "\nNOTE: It assumes the user's tokens are initialized in the file '$ENV{HOME}/saved-flickr.st}'";
    exit;  # Exit the program after displaying help
}

# Parse command-line options
GetOptions(
    'h|help' => \&usage  # If -h or --help is provided, call usage subroutine
);

# Get the regular expression argument from the command line
my $regex = shift @ARGV;  # Extract the first non-option argument
die "No regular expression provided.\n" unless $regex;  # Exit if no regex provided

# Compile the regex pattern for efficient matching
# qr// compiles the regex and returns a regex object
$regex = qr/$regex/;

# Define the path to the Flickr authentication configuration file
my $config_file = "$ENV{HOME}/saved-flickr.st";

# Import Flickr API configuration from stored file
# This contains authentication tokens for API access
my $flickr = Flickr::API->import_storable_config($config_file);

# Get the list of all tags from the user's Flickr account
# Using getListUserRaw method to get raw tag data
my $response = $flickr->execute_method('flickr.tags.getListUserRaw');

# Error handling for API response
die "Error retrieving tags: $response->{error_message}" unless $response->{success};
die "Unexpected format" unless defined $response->{hash} 
    && defined $response->{hash}->{who} 
    && defined $response->{hash}->{who}->{tags} 
    && defined $response->{hash}->{who}->{tags}->{tag};

# Debug line (commented out) - can be used to inspect the full response structure
#print Dumper $response->{hash}->{who}->{tags};

# Extract the tags array reference from the nested response structure
my $tagsref = $response->{hash}->{who}->{tags}->{tag};
my @tags = ();  # Initialize empty array to store processed tags

# Process each tag object from the API response
foreach my $tag (@$tagsref) {
    # Extract raw tag strings (tags might be stored as array or single value)
    my $rawtags = $tag->{raw};
    
    # Ensure we always work with an array reference
    # If it's not already an array, wrap it in one
    $rawtags = [$rawtags] if 'ARRAY' ne ref $rawtags;
    
    # Add all raw tags to our master tags list
    push @tags, (@{$rawtags});
}

# Process each tag to find matches with the provided regex
foreach my $tag (@tags) {
    # Skip tags that don't match the regex pattern
    next unless $tag =~ /$regex/;

    # Notify user about matching tag found
    print "Found tag matching /$regex/: $tag";

    # Initialize pagination variables for photo search
    my $page = 0;           # Current page number (will be incremented)
    my $total_pages = 1;    # Total pages available (updated from API response)

    # Loop through all pages of photos containing this tag
    while (++$page <= $total_pages) {
        # Search for photos that have the current tag
        my $response = $flickr->execute_method('flickr.photos.search', {
            user_id => 'me',      # Search current user's photos
            text => $tag,         # Search by tag text
            per_page => 500,      # Maximum results per page (API limit)
            page => $page         # Current page number
        });

        # Handle API errors for photo search
        warn "Error retrieving photos (page $page): $response->{error_message}\n\n" and next unless $response->{success};

        # Convert API response to hash format for easier access
        my $data = $response->as_hash();
        
        # Validate response structure
        warn "No data in answer for tag $tag (page $page)" and next unless defined $data && defined $data->{photos};

        # Extract photos array from response
        my $photos = $data->{photos}->{photo};
        
        # Check if any photos were found
        warn "No more photos found with tag $tag" and next unless defined $photos;

        # Update total pages for pagination control
        $total_pages = $data->{photos}->{pages};

        # Ensure photos is always an array reference (API might return single object)
        $photos = [$photos] if 'ARRAY' ne ref $photos;

        # Extract photo IDs from the photos array
        # grep { $_ } filters out any undefined or empty IDs
        my @ids = grep { $_ } map { $_->{id} } @$photos;

        # Process each photo ID
        foreach my $id (@ids) {
            # Get all tags for this specific photo
            print "Get tags id for photo $id"; 
            my $response = $flickr->execute_method('flickr.tags.getListPhoto', { photo_id => $id });

            # Handle API errors for tag retrieval
            warn "Error retrieving tags for photo $id: $response->{error_message}\n" and next unless $response->{success};

            # Convert response to hash format
            my $data = $response->as_hash();

            # Check if tags data is present
            warn "No tags found for photo $id" and next unless defined $data && defined $data->{photo};

            # Extract tags array from response
            my $tags = $data->{photo}->{tags}->{tag};
            
            # Ensure tags is always an array reference
            $tags = [$tags] if 'ARRAY' ne ref $tags;
            
            # Check each tag on the photo and remove matching ones
            foreach my $phototag (@$tags) {
                # Debug line (commented out) - shows detailed tag structure
                #print Dumper $phototag;
                
                # Check if this photo tag matches our regex pattern
                if ($phototag->{raw} =~ /$regex/) {
                    # Notify user about tag removal
                    print "I am ready to remove $phototag->{raw} with id $phototag->{id}";
                    
                    # Call API to remove the matching tag using its ID
                    my $response = $flickr->execute_method('flickr.photos.removeTag', { tag_id => $phototag->{id} });
                    
                    # Handle removal errors
                    warn "Error removing tag: $response->{error_message}" unless $response->{success};
                }
            }
        }
    }
}