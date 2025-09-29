#!/usr/bin/perl
use strict;
use warnings;
use Getopt::Long;
use Flickr::API;
use Data::Dumper;

$\ = "\n";
my ($help, $desc_token, $dry_run);

GetOptions(
    'h|help'     => \$help,
    'd|desc=s'   => \$desc_token,
    'n|dry-run'  => \$dry_run,
);

if ($help) {
    print "This script lists and reorders Flickr sets of the current user";
    print "Usage: $0 [OPTIONS]";
    print "Options:";
    print "  -h, --help        Show this help message and exit";
    print "  -d, --desc token  Sort sets by the value of 'token:=value' in set description";
    print "  -n, --dry-run     Print sorted set order without reordering on Flickr";
    print "\nNOTE: It assumes the user's tokens are initialized in the file '$ENV{HOME}/saved-flickr.st'";
    print "      If --desc is not provided, sets are sorted by title.";
    exit;
}

my $config_file = "$ENV{HOME}/saved-flickr.st";
my $per_page = 500;
my $page = 1;
my $total_pages = 1;
my $flickr = Flickr::API->import_storable_config($config_file);

# Retrieve all the sets using pagination
my $sets = [];
while ($page <= $total_pages) {
    my $response = $flickr->execute_method('flickr.photosets.getList', {
        per_page => $per_page,
        page => $page,
    });

    die "Error fetching sets: $response->{error_message}" unless $response->{success};

    my $s = $response->as_hash->{photosets}->{photoset};
    $s = [ $s ] unless ref $s eq 'ARRAY';
    push @$sets, @$s;
    $total_pages = $response->as_hash->{photosets}->{pages};
    $page++;
}

# Sort the sets
my @sorted_sets;
if ($desc_token) {
    # Sort by token:=value in description
    @sorted_sets = sort {
        my $a_value = 'zzz'; # Default for sets without token
        my $b_value = 'zzz';
        
        # Extract value from description for token
        if ($a->{description} && $a->{description} =~ /^\s*$desc_token:=(\S+)/m) {
            $a_value = $1;
        }
        if ($b->{description} && $b->{description} =~ /^\s*$desc_token:=(\S+)/m) {
            $b_value = $1;
        }
        
        $a_value cmp $b_value || $a->{title} cmp $b->{title} # Fallback to title if values equal
    } @$sets;
} else {
    # Default sort by title
    @sorted_sets = sort { $a->{title} cmp $b->{title} } @$sets;
}

# Prepare the set IDs
my @set_ids = map { $_->{id} } @sorted_sets;

# Dry-run mode: print the sorted order and exit
if ($dry_run) {
    print "Dry-run mode: Sets will be ordered as follows (not applied to Flickr):";
    for my $i (0..$#sorted_sets) {
        my $set = $sorted_sets[$i];
        my $value = $desc_token && $set->{description} && $set->{description} =~ /^\s*$desc_token:=(\S+)/m ? $1 : 'N/A';
        print "Set ID: $set->{id}, Title: $set->{title}, " . ($desc_token ? "Token Value: $value" : "");
    }
    exit;
}

# Reorder the sets
my $ordered_set_ids = join(',', @set_ids);
my $order_response = $flickr->execute_method('flickr.photosets.orderSets', {
    photoset_ids => $ordered_set_ids,
});

die "Error reordering sets: $order_response->{error_message}" unless $order_response->{success};

print "Sets reordered successfully!";