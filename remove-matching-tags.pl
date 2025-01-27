#!/usr/bin/perl
use strict;
use warnings;
use Getopt::Long;
use Flickr::API;
use File::Slurp;
use Data::Dumper;
binmode(STDOUT, ':utf8');

$\ = "\n";

sub usage {
    print "This script removes tags matching the given regular expression from the current user's photos.";
    print "Usage: $0 [OPTIONS] REGEX";
    print "Options:";
    print "  -h, --help    Show this help message and exit";
    print "REGEX must be a valid regular expression to match tags";
    print "\nNOTE: It assumes the user's tokens are initialized in the file '$ENV{HOME}/saved-flickr.st}'";
    exit;
}

GetOptions(
    'h|help' => \&usage
);

# Get the regular expression argument from the command line
my $regex = shift @ARGV;
die "No regular expression provided.\n" unless $regex;

# Escape dangerous characters in the regex
$regex = qr/$regex/;

my $config_file = "$ENV{HOME}/saved-flickr.st";
my $flickr = Flickr::API->import_storable_config($config_file);

# Get the list of tags from the Flickr account using 'flickr.tags.getListUser'
my $response = $flickr->execute_method('flickr.tags.getListUserRaw');

# Check if the response was successful and contains tags
die "Error retrieving tags: $response->{error_message}" unless $response->{success};
die "Unexpected format" unless defined $response->{hash} 
    && defined $response->{hash}->{who} 
    && defined $response->{hash}->{who}->{tags} 
    && defined $response->{hash}->{who}->{tags}->{tag};

#print Dumper $response->{hash}->{who}->{tags};

my $tagsref = $response->{hash}->{who}->{tags}->{tag};
my @tags = ();

foreach my $tag (@$tagsref) {
    my $rawtags = $tag->{raw};
    $rawtags = [$rawtags] if 'ARRAY' ne ref $rawtags;
    push @tags, (@{$rawtags});
}

foreach my $tag (@tags) {
    # Match the tag with the provided regular expression
    next unless $tag =~ /$regex/;

    print "Found tag matching /$regex/: $tag";

    # Initialize pagination variables
    my $page = 0;
    my $total_pages = 1;

    # Loop through all pages of photos
    while (++$page <= $total_pages) {
        my $response = $flickr->execute_method('flickr.photos.search', {
            user_id => 'me',
            text => $tag,
            per_page => 500,
            page => $page
        });

        warn "Error retrieving photos (page $page): $response->{error_message}\n\n" and next unless $response->{success};

        my $data = $response->as_hash();
        warn "No data in answer for tag $tag (page $page)" and next unless defined $data && defined $data->{photos};

        my $photos = $data->{photos}->{photo};
        warn "No more photos found with tag $tag" and next unless defined $photos;

        # Set the total number of pages for pagination
        $total_pages = $data->{photos}->{pages};

        # Convert to array if it's a single photo
        $photos = [$photos] if 'ARRAY' ne ref $photos;

        my @ids = grep { $_ } map { $_->{id} } @$photos;

        foreach my $id (@ids) {
            # Get the list of tags for each photo
            print "Get tags id for photo $id"; 
            my $response = $flickr->execute_method('flickr.tags.getListPhoto', { photo_id => $id });

            warn "Error retrieving tags for photo $id: $response->{error_message}\n" and next unless $response->{success};

            my $data = $response->as_hash();

            warn "No tags found for photo $id" and next unless defined $data && defined $data->{photo};

            my $tags = $data->{photo}->{tags}->{tag};
            $tags = [$tags] if 'ARRAY' ne ref $tags;
            
            # Check and remove tags matching the regular expression
            foreach my $phototag (@$tags) {
                #print Dumper $phototag;
                if ($phototag->{raw} =~ /$regex/) {
                    print "I am ready to remove $phototag->{raw} with id $phototag->{id}";
                    my $response = $flickr->execute_method('flickr.photos.removeTag', { tag_id => $phototag->{id} });
                    warn "Error removing tag: $response->{error_message}" unless $response->{success};
                }
            }
        }
    }
}
