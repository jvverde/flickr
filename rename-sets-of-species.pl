#!/usr/bin/perl
use strict;
use warnings;
use Getopt::Long;
use Flickr::API;
use Data::Dumper;

$\ = "\n";
my ($help, $dry_run, $debug, $ioc_prefix);

GetOptions(
    'h|help'     => \$help,
    'n|dry-run'  => \$dry_run,
    'd|debug'    => \$debug,
    'i|ioc=s'    => \$ioc_prefix,
);

if ($help) {
    print "This script processes Flickr sets with titles matching bird species pattern";
    print "Usage: $0 -i PREFIX [OPTIONS]";
    print "Options:";
    print "  -h, --help        Show this help message and exit";
    print "  -n, --dry-run     Simulate the renaming without making changes";
    print "  -d, --debug       Print Dumper output for the first two sets of flickr.photosets.getList";
    print "  -i, --ioc PREFIX  Specify the IOC machine tag prefix (e.g., IOC151) [REQUIRED]";
    print "\nNOTE: It assumes the user's tokens are initialized in the file '$ENV{HOME}/saved-flickr.st'";
    exit;
}

# Ensure ioc_prefix is provided
die "Error: --ioc PREFIX is required" unless defined $ioc_prefix;

my $config_file = "$ENV{HOME}/saved-flickr.st";
my $per_page = 500;
my $page = 1;
my $total_pages = 1;
my $flickr = Flickr::API->import_storable_config($config_file);

# Function to canonicalize a tag for comparison
sub canonicalize_tag {
    my $tag = shift;
    $tag =~ s/[^a-z0-9:]//gi;  # Remove unwanted characters (global, case-insensitive)
    $tag = lc($tag);           # Lowercase the tag
    return $tag;
}

$ioc_prefix = canonicalize_tag($ioc_prefix);
# Retrieve all sets using pagination
my $sets = [];
while ($page <= $total_pages) {
    my $response = $flickr->execute_method('flickr.photosets.getList', {
        per_page => $per_page,
        page     => $page++,
        primary_photo_extras => 'machine_tags',  # Fetch machine tags for primary photo
    });

    die "Error: $response->{error_message}" unless $response->{success};

    my $s = $response->as_hash->{photosets}->{photoset};
    $s = [ $s ] unless ref $s eq 'ARRAY';
    # Filter sets matching the bird species pattern
    my @filtered_sets = grep { $_->{title} =~ /^\s*[A-Z][a-z]+\s+[a-z]+\s*$/ } @$s;

    print "Debug: Dumping first two sets from flickr.photosets.getList response", Dumper [@filtered_sets[0..1]] if $debug;

    push @$sets, @filtered_sets;
    $total_pages = $response->as_hash->{photosets}->{pages};
}

# Process each set
foreach my $set (@$sets) {
    my $title = $set->{title};

    # Canonicalize the set title
    my $canon_title = canonicalize_tag($title);

    # Get primary photo's machine tags
    my $machine_tags = $set->{primary_photo_extras}->{machine_tags} || '';
    my %tags;
    foreach my $tag (split /\s+/, $machine_tags) {
        print "Check tag=$tag" if $debug;
        if ($tag =~ /^$ioc_prefix:([^=]+)=(.+)$/) {
            $tags{lc($1)} = $2;  # Store tag key-value pairs, lowercasing the key
            print Dumper \%tags if $debug;
        }
    }

    # Compare canonicalized title with IOC:binomial machine tag and ensure seq exists
    next unless exists $tags{binomial} && $canon_title eq canonicalize_tag($tags{binomial}) && exists $tags{seq};

    # Get IOC:seq for the hexadecimal value
    my $seq = $tags{seq};
    next unless $seq =~ /^\d+$/;  # Ensure seq is numeric
    my $hex_seq = sprintf("%04X", $seq);  # Convert to 4-digit hexadecimal
    my $new_title = "A3 - $hex_seq - $title";

    if ($dry_run) {
        print "Would rename set '$title' (ID: $set->{id}) to '$new_title'";
        next;
    }

    # Rename the set
    my $edit_response = $flickr->execute_method('flickr.photosets.editMeta', {
        photoset_id => $set->{id},
        title       => $new_title,
    });

    if ($edit_response->{success}) {
        print "Renamed set '$title' (ID: $set->{id}) to '$new_title'";
    } else {
        print "Error renaming set '$title' (ID: $set->{id}): $edit_response->{error_message}";
    }
}

print "Processing complete!" unless $dry_run;