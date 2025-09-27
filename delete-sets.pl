#!/usr/bin/perl
use strict;
use warnings;
use Flickr::API;
use Getopt::Long;
use Term::ReadKey;

$\ = "\n";

# Command-line options
my $regex;
my $dry_run = 0;
my $help = 0;
my $all = 0;
GetOptions(
    'regex|r=s' => \$regex,
    'dry-run|n' => \$dry_run,
    'help|h'    => \$help,
    'all'       => \$all,
) or die "Invalid arguments\n";

# Display help and exit if -h|--help is specified
if ($help) {
    print <<'HELP';
delete_photosets_by_regex.pl - Delete Flickr photosets with titles matching a regular expression

Usage:
    delete_photosets_by_regex.pl [-r|--regex <regex>] [-n|--dry-run] [--all] [-h|--help]

Options:
    -r, --regex <regex>    Regular expression to match photoset titles
    -n, --dry-run          Simulate deletion without modifying photosets
    --all                  Delete all matching photosets without prompting
    -h, --help             Display this help message

Examples:
    Delete photosets with "Summer" in the title (prompts for each, single keypress y/N):
        perl delete_photosets_by_regex.pl --regex "Summer"

    Delete all matching photosets without prompting:
        perl delete_photosets_by_regex.pl --regex "Summer" --all

    Simulate deletion of photosets from 2023:
        perl delete_photosets_by_regex.pl -r "2023" --dry-run

    Display help:
        perl delete_photosets_by_regex.pl --help
HELP
    exit 1;
}

die "Missing required --regex parameter\n" unless defined $regex;

# Validate regex
qr/$regex/ or die "Invalid regular expression: $!\n";

# Read the config file to connect to Flickr
my $config_file = "$ENV{HOME}/saved-flickr.st";
my $flickr = Flickr::API->import_storable_config($config_file);

# Get the list of existing photosets
my $sets = [];
my $page = 0;
my $pages = 1;
while ($page++ < $pages) {
    my $response = $flickr->execute_method('flickr.photosets.getList', {
        per_page => 500,
        page => $page,
    }) or die "Failed to execute flickr.photosets.getList: $!";
    warn "Error retrieving photosets: $response->{error_message}" and sleep 5 and redo unless $response->{success};

    push @$sets, @{$response->as_hash->{photosets}->{photoset}};
    $pages = $response->as_hash->{photosets}->{pages};
    $page = $response->as_hash->{photosets}->{page};
}

# Main logic: delete or simulate deletion of photosets matching the regex
print "Dry run mode enabled: no photosets will be deleted" if $dry_run;
my $count = 0;
foreach my $set (@$sets) {
    next unless $set->{title} =~ /$regex/i; # Skip non-matching titles

    printf "Match found: Photoset ID: %s, Title: %s\n", $set->{id}, $set->{title};
    $count++;

    print "Would delete photoset: $set->{title}" and next if $dry_run;

    # Prompt for deletion unless --all is specified
    unless ($all) {
        print "Delete photoset '$set->{title}'? [y/N] ";
        ReadMode('cbreak'); # Enable single-character input
        my $input = ReadKey(0); # Read one character without Enter
        ReadMode('normal'); # Restore normal input mode
        print $input; # Echo the input for visibility
        next unless $input =~ /^[yY]$/;
    }

    my $response = $flickr->execute_method('flickr.photosets.delete', { photoset_id => $set->{id} })
        or die "Failed to execute flickr.photosets.delete: $!";
    warn "Error deleting photoset $set->{title}: $response->{error_message}" and next unless $response->{success};

    print "Successfully deleted photoset: $set->{title}";
}

print "Found $count photoset(s) matching regex '$regex'." . ($dry_run ? " (Dry run, no deletions performed)" : "");