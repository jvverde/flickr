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
my $dry_run;                # Dry-run flag to simulate sorting without making changes
my $sort = 'datetaken';     # Default sorting criteria
my $rev;                    # Flag to reverse the sorting order

# Parse command-line options
GetOptions(
    'h|help' => \$help,             # Help flag
    'f|filter=s' => \$filter_pattern, # Filter photosets by a regular expression
    'n|dry-run' => \$dry_run,        # Dry-run mode
    's|sort=s' => \$sort,            # Sorting criteria
    'r|reverse' => \$rev,            # Reverse sorting order
);

# Validate the sorting parameter
die "Error: Sort parameter ('$sort') must be one of 'views', 'upload', 'lastupdate', '.+:seq'\n"
  unless $sort =~ /^(views|dateupload|lastupdate|datetaken|.+:seq)$/;

# Display help message and exit if help flag is set
if ($help) {
    print "This script reorders photos in all sets of the current user based on the specified criteria.\n";
    print "Usage: $0 [OPTIONS]\n";
    print "Options:\n";
    print "  -h, --help      Show this help message and exit\n";
    print "  -f, --filter    Filter photosets by a regular expression pattern (default: '.*')\n";
    print "  -s, --sort      Sort by 'views', 'dateupload', 'lastupdate', or 'datetaken' (default: 'datetaken')\n";
    print "                  You can also use a machine tag pattern like 'namespace:predicate:seq' for custom sorting.\n";
    print "  -r, --reverse   Reverse the sorting order\n";
    print "  -n, --dry-run   Simulate sorting without making changes\n";
    print "\nNOTE: This script assumes the user's Flickr API tokens are initialized in the file '$ENV{HOME}/saved-flickr.st'.\n";
    exit;
}

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

# If dry-run mode is enabled, print the photosets that would be sorted and exit
print map { "Photoset $_->{title} will be sorted by $sort\n" } @$photosets and exit if $dry_run;

# Sort photos inside each photoset
my $count = 0;
foreach my $photoset (@$photosets) {
    my $photos = [];
    my $page = 1;
    my $pages = 1;
    while ($page <= $pages) {
        # Fetch photos from the current photoset
        my $response = $flickr->execute_method('flickr.photosets.getPhotos', {
            photoset_id => $photoset->{id},
            per_page => 500,  # Fetch up to 500 photos per page
            page => $page,
            extras => 'views,date_upload,date_taken,last_update,machine_tags',  # Include additional metadata
        });

        # Handle errors and retry if necessary
        warn "Error at get photos from $photoset->{title}: $response->{error_message}" and redo unless $response->{success};
        my $bunch = $response->as_hash->{photoset}->{photo};
        $bunch = [ $bunch ] unless 'ARRAY' eq ref $bunch;  # Ensure the result is an array
        push @$photos, @$bunch;  # Add photos to the list
        $pages = $response->as_hash->{photoset}->{pages};  # Total number of pages
        $page = $response->as_hash->{photoset}->{page} + 1;  # Move to the next page
    }

    # Sort photos based on the specified criteria
    my @sorted_photos;
    if ($sort =~ /.+:seq/) {
        # Custom sorting using machine tags (e.g., 'namespace:predicate:seq')
        $sort =~ s/[^a-z0-9:]//i;  # Convert to Flickr canonical form
        foreach my $photo (@$photos) {
            my ($seq) = $photo->{machine_tags} =~ /$sort=(\d+)/i;  # Extract sequence number from machine tags
            $photo->{seq} = defined $seq ? $seq : 100000;  # Assign a high number if the tag is not found
        }
        @sorted_photos = sort {
            return $a->{seq} <=> $b->{seq} if $a->{seq} != $b->{seq};  # Sort by sequence number
            return $b->{datetaken} cmp $a->{datetaken};  # Fallback to datetaken if sequence numbers are the same
        } @$photos;
    } elsif ($sort eq 'datetaken') {
        # Sort by datetaken (string comparison)
        @sorted_photos = sort { $a->{$sort} cmp $b->{$sort} } @$photos;
    } else {
        # Sort by views, dateupload, or lastupdate (numeric comparison)
        @sorted_photos = sort { $a->{$sort} <=> $b->{$sort} } @$photos;
    }

    # Reverse the sorting order if the reverse flag is set
    @sorted_photos = reverse @sorted_photos if $rev;

    # Prepare the sorted photo IDs for the API call
    my $sorted_ids = join(',', map { $_->{id} } @sorted_photos);

    # Reorder photos in the photoset using the Flickr API
    my $response = $flickr->execute_method('flickr.photosets.reorderPhotos', {
        photoset_id => $photoset->{id},
        photo_ids => $sorted_ids,
    });

    # Handle errors and continue to the next photoset if sorting fails
    warn "Error at sort photos in $photoset->{title} ($photoset->{id}): $response->{error_message}" and next unless $response->{success};
    print "Photoset $photoset->{title} sorted by $sort.\n";
}