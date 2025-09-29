#!/usr/bin/perl
use strict;
use warnings;
use Getopt::Long;
use Data::Dumper;
use Flickr::API;

# Set output field separators
($\, $,) = ("\n", "\n");

# Command-line options
my $help;
my $filter_pattern = '.*';
my $dry_run;
my $tag;  # tag to search

GetOptions(
    'h|help' => \$help,
    'f|filter=s' => \$filter_pattern,
    'n|dry-run' => \$dry_run,
    't|tag=s' => \$tag,
);

if ($help) {
    print "This script generates a species count summary for Flickr sets based on a given tag.\n";
    print "Usage: $0 [OPTIONS]\n";
    print "Options:\n";
    print "  -h, --help      Show this help message and exit\n";
    print "  -f, --filter    Filter photosets by a regex (default: '.*')\n";
    print "  -t, --tag       Tag to search in photos (required)\n";
    print "  -n, --dry-run   Simulate without making changes\n";
    exit;
}

die "Error: Tag parameter (-t) is required\n" unless defined $tag && $tag ne '';

$tag = lc $tag;
# Load Flickr API config
my $config_file = "$ENV{HOME}/saved-flickr.st";
my $flickr = Flickr::API->import_storable_config($config_file);

my $re = qr/$filter_pattern/i;

# Retrieve photosets
my $photosets = [];
my $page = 1;
my $pages = 1;
while ($page <= $pages) {
    my $response = $flickr->execute_method('flickr.photosets.getList', {
        per_page => 500,
        page => $page,
    });
    warn "Error: $response->{error_message}" and redo unless $response->{success};

    push @$photosets, grep { $_->{title} =~ $re } @{$response->as_hash->{photosets}->{photoset}};
    $pages = $response->as_hash->{photosets}->{pages};
    $page = $response->as_hash->{photosets}->{page} + 1;
}

# Delimiter for summary in description
my $summary_start = "\n=== SPECIES SUMMARY START ===\n";
my $summary_end   = "\n=== SPECIES SUMMARY END ===\n";

foreach my $photoset (@$photosets) {
    print "Processing photoset: $photoset->{title}\n";

    # Fetch all photos
    my $photos = [];
    my $page = 1;
    my $pages = 1;
    while ($page <= $pages) {
        my $response = $flickr->execute_method('flickr.photosets.getPhotos', {
            photoset_id => $photoset->{id},
            per_page => 500,
            page => $page,
            extras => 'tags',  # important to fetch tags
        });
        warn "Error fetching photos: $response->{error_message}" and redo unless $response->{success};

        my $bunch = $response->as_hash->{photoset}->{photo};
        $bunch = [$bunch] unless 'ARRAY' eq ref $bunch;
        push @$photos, @$bunch;
        $pages = $response->as_hash->{photoset}->{pages};
        $page = $response->as_hash->{photoset}->{page} + 1;
    }

    # Count species
    my %species_count;
    foreach my $photo (@$photos) {
        print Dumper $photo->{tags};
        my @tags = split /\s+/, $photo->{tags};
        my ($seq_tag) = grep { /^$tag:seq=/ } @tags;
        my ($binomial_tag) = grep { /^$tag:binomial=/ } @tags;

        next unless $seq_tag && $binomial_tag;

        $binomial_tag =~ s/^$tag:binomial=//;
        $species_count{$binomial_tag}++;
    }

    # Create summary
    my $summary = $summary_start;
    $summary .= "Species count for photoset '$photoset->{title}':\n";
    foreach my $sp (sort keys %species_count) {
        $summary .= sprintf("  %s: %d\n", $sp, $species_count{$sp});
    }
    $summary .= $summary_end;

    # Get current description
    my $response = $flickr->execute_method('flickr.photosets.getInfo', {
        photoset_id => $photoset->{id},
    });
    warn "Error fetching photoset info: $response->{error_message}" and next unless $response->{success};
    print Dumper $response->as_hash->{photoset};
    my $description = $response->as_hash->{photoset}->{description} // '';

    # Remove previous summary if exists
    $description =~ s/\Q$summary_start\E.*?\Q$summary_end\E//s;

    # Append new summary
    my $new_description = $description . $summary;

    if ($dry_run) {
        print "DRY RUN: Would update photoset '$photoset->{title}' with summary:\n$summary";
        next;
    }

    if ($dry_run) {
        print "DRY RUN: Final description for photoset '$photoset->{title}':\n";
        print "------------------------------------------------------------\n";
        print $new_description;
        print "------------------------------------------------------------\n\n";
        next;
    }
    
    # Update photoset description
    my $update_resp = $flickr->execute_method('flickr.photosets.editMeta', {
        photoset_id => $photoset->{id},
        title => $photoset->{title},  # title must be passed
        description => $new_description,
    });
    if (!$update_resp->{success}) {
        warn "Error updating description for $photoset->{title}: $update_resp->{error_message}";
    } else {
        print "Updated description for photoset '$photoset->{title}'\n";
    }
}

print "\nCompleted species summaries for " . scalar(@$photosets) . " photosets.\n";
