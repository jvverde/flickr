#!/usr/bin/perl
use strict;
use warnings;
use Getopt::Long;
use Flickr::API;
use Data::Dumper;

$\ = "\n";
my ($help, $token, $dry_run, $remove, $count, $match);

GetOptions(
    'h|help' => \$help,
    't|token=s' => \$token,
    'n|dry-run' => \$dry_run,
    'r|remove' => \$remove,
    'c|count=i' => \$count,
    'm|match=s' => \$match,
);

if ($help) {
    print "This script processes Flickr set titles and descriptions";
    print "Usage: $0 [OPTIONS]";
    print "Options:";
    print "  -h, --help        Show this help message and exit";
    print "  -t, --token=STR   Token to prepend to pattern in description";
    print "  -n, --dry-run     Simulate changes without applying them";
    print "  -r, --remove      Remove pattern from set title";
    print "  -c, --count=NUM   Limit the number of sets to update (ignored in dry-run)";
    print "  -m, --match=REGEX Further restrict sets to those with titles matching the given regex";
    print "\nNOTE: It assumes the user's tokens are initialized in the file '$ENV{HOME}/saved-flickr.st'";
    exit;
}

unless ($token || $remove) {
    warn "Error: Either --token or --remove must be specified";
    exit 1;
}

# Validate match pattern if provided
if (defined $match) {
    eval { "" =~ /$match/ };
    if ($@) {
        warn "Error: Invalid regex pattern for --match: $@";
        exit 1;
    }
}

my $config_file = "$ENV{HOME}/saved-flickr.st";
my $per_page = 500;
my $page = 1;
my $total_pages = 1;
my $flickr = Flickr::API->import_storable_config($config_file);
my $update_count = 0;

# Retrieve all the sets using pagination, filtering by title pattern
my $sets = [];
my $pattern = '^\s*[0-9A-F]{2}\s*-\s*[0-9A-F]{2,4}\s*-\s*';
while ($page <= $total_pages) {
    my $response = $flickr->execute_method('flickr.photosets.getList', {
        per_page => $per_page,
        page => $page,
    });

    unless ($response->{success}) {
        warn "Error fetching sets: $response->{error_message}";
        sleep 1;
        redo;
    }

    my $s = $response->as_hash->{photosets}->{photoset};
    $s = [ $s ] unless ref $s eq 'ARRAY';
    my @filtered = grep { $_->{title} =~ /$pattern/ } @$s;
    if (defined $match) {
        @filtered = grep { $_->{title} =~ /$match/ } @filtered;
    }
    push @$sets, @filtered;
    $total_pages = $response->as_hash->{photosets}->{pages};
    $page++;
}

# Process each set
foreach my $set (@$sets) {
    my $title = $set->{title};
    my $description = $set->{description} || '';
    my $new_title = $title;
    my $new_description = $description;

    # Extract pattern from title (guaranteed to match due to grep)
    my ($matched) = $title =~ /($pattern)/;
    next unless defined $matched;

    # Sanitize matched pattern by removing all whitespace and trailing hyphens
    my $sanitized = $matched;
    $sanitized =~ s/\s+//g;
    $sanitized =~ s/-+$//;

    # Prepare the token line
    my $token_line = "$token:=$sanitized" if $token;

    # Update description if token is provided
    if ($token) {
        # Check if description already has a line starting with token:=
        if ($description =~ /^$token:=.+$/m) {
            # Replace all existing token lines
            $new_description =~ s/^$token:=.+$/$token_line/gm;
        } else {
            # Add token line at the top
            $new_description = "$token_line\n$new_description";
        }
    }

    # Remove pattern from title if requested
    if ($remove) {
        $new_title =~ s/$pattern//;
    }

    # Apply changes unless dry-run
    unless ($dry_run) {
        if (($token && $new_description ne $description) || ($remove && $new_title ne $title)) {
            my $response = $flickr->execute_method('flickr.photosets.editMeta', {
                photoset_id => $set->{id},
                title => $new_title,
                description => $new_description,
            });
            unless ($response->{success}) {
                warn "Error updating set '$title': $response->{error_message}";
                sleep 1;
                redo;
            }
            $update_count++;
            if ($token && $new_description ne $description) {
                print "Updated description for set '$title' to include '$token:=$sanitized'";
            }
            if ($remove && $new_title ne $title) {
                print "Updated title for set '$title' to '$new_title'";
            }
            last if defined $count && $update_count >= $count;
        }
    } else {
        if ($token && $new_description ne $description) {
            print "Dry-run: Would update description for set '$title' to include '$token:=$sanitized'";
        }
        if ($remove && $new_title ne $title) {
            print "Dry-run: Would remove pattern from title '$title' to '$new_title'";
        }
    }
}