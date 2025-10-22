#!/usr/bin/perl
# This script lists Flickr photosets with identical titles. It groups sets by
# exact title and outputs sets with the same title, including their IDs, primary
# photo IDs, and number of photos in each set. It supports pagination and debug
# output.
#
# Usage: perl flickr_list_duplicate_sets.pl [OPTIONS]
# Options:
#   -h, --help        Show help message and exit
#   -d, --debug       Print Dumper output for the first two sets from flickr.photosets.getList
#
# Prerequisites:
# - Requires a Flickr API configuration file at $ENV{HOME}/saved-flickr.st
# - Uses Perl modules: Getopt::Long, Flickr::API, Data::Dumper
#
# Examples:
#   perl flickr_list_duplicate_sets.pl
#     Lists all sets with duplicate titles and their photo counts.
#   perl flickr_list_duplicate_sets.pl -d
#     Debug mode: dumps the first two sets from flickr.photosets.getList response.

use strict;
use warnings;
use Getopt::Long;
use Flickr::API;
use Data::Dumper;

$\ = "\n";  # Set output record separator to newline
my ($help, $debug);  # Command-line options

# Parse command-line options
GetOptions(
    'h|help'     => \$help,
    'd|debug'    => \$debug,
);

# Display help message if -h or --help is specified
if ($help) {
    print "This script lists Flickr sets with identical titles and their photo counts";
    print "Usage: $0 [OPTIONS]";
    print "Options:";
    print "  -h, --help        Show this help message and exit";
    print "  -d, --debug       Print Dumper output for the first two sets of flickr.photosets.getList";
    print "\nNOTE: It assumes the user's tokens are initialized in the file '$ENV{HOME}/saved-flickr.st'";
    exit;
}

# Initialize Flickr API configuration
my $config_file = "$ENV{HOME}/saved-flickr.st";  # Path to Flickr API config file
my $per_page = 500;  # Number of sets per API page
my $page = 1;  # Current page number
my $total_pages = 1;  # Total pages, updated after each API call
my $flickr = Flickr::API->import_storable_config($config_file);  # Initialize Flickr API client

# Retrieve all sets using pagination
my $sets = [];  # Array to store all sets
while ($page <= $total_pages) {
    # Fetch a page of photosets
    my $response = $flickr->execute_method('flickr.photosets.getList', {
        per_page => $per_page,
        page     => $page++,  # Increment page after use
    });

    die "Error: $response->{error_message}" unless $response->{success};  # Exit on API error

    my $s = $response->as_hash->{photosets}->{photoset};  # Extract photosets
    $s = [ $s ] unless ref $s eq 'ARRAY';  # Convert single photoset to array if needed
    print "Debug: Dumping first two sets from flickr.photosets.getList response", Dumper [@$s[0..1]] if $debug;  # Debug output for first two sets
    push @$sets, @$s;  # Add all sets to main array
    $total_pages = $response->as_hash->{photosets}->{pages};  # Update total pages
}

# Group sets by exact title
my %sets_by_title;
foreach my $set (@$sets) {
    my $title = $set->{title};
    push @{$sets_by_title{$title}}, {
        id => $set->{id},
        title => $title,
        primary_photo_id => $set->{primary},
        photo_count => $set->{photos},  # Number of photos in the set
    };
}

# List sets with duplicate titles and their photo counts
my $has_duplicates = 0;
foreach my $title (sort keys %sets_by_title) {
    my $sets = $sets_by_title{$title};
    if (@$sets > 1) {  # Only print titles with multiple sets
        $has_duplicates = 1;
        print "Duplicate title '$title':";
        foreach my $set (@$sets) {
            print "  Set ID: $set->{id}, Title: '$set->{title}', Primary Photo ID: $set->{primary_photo_id}, Photos: $set->{photo_count}";
        }
    }
}

# Print message if no duplicates found
print "No duplicate titles found." unless $has_duplicates;

print "Processing complete!";