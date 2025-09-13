#!/usr/bin/perl
use strict;
use warnings;
use Getopt::Long;
use Flickr::API;
use JSON;
binmode(STDOUT, ':utf8');

$\ = "\n";  # newline after print
$, = " ";   # space separator

my $json = JSON->new->utf8;

# Load Flickr API config
my $config_file = "$ENV{HOME}/saved-flickr.st";
my $flickr = Flickr::API->import_storable_config($config_file);

sub usage {
    print <<'END_USAGE';
Find all photos with a given tag (t1) which do NOT have another tag (t2).

Usage:
  $0 --t1 <tag1> --t2 <tag2>
  $0 -1 <tag1> -2 <tag2>
  $0 --help

Options:
  -1, --t1   Required. The tag that photos MUST have.
  -2, --t2   Required. The tag that photos must NOT have.
  -h, --help Show this help message.

The script fetches all photos of the authenticated user with tag t1,
and prints those that do not also contain tag t2.
Tag matching is case-insensitive (Flickr normalizes tags to lowercase).
END_USAGE
    exit;
}

# Command line args
my ($t1, $t2);
GetOptions(
    "1|t1=s" => \$t1,
    "2|t2=s" => \$t2,
    "h|help" => \&usage,
) or usage();

usage() unless defined $t1 && defined $t2;

# Normalize only for comparison
my $t2_lc = lc $t2;

# Search photos with t1
my $page  = 1;
my $pages = 1;
my @results;

do {
    my $response = eval {
        $flickr->execute_method('flickr.photos.search', {
            user_id  => 'me',
            tags     => $t1,
            per_page => 500,
            extras   => 'tags,title,date_upload',
            page     => $page,
        })
    };
    if ($@ || !$response->{success}) {
        warn "Error retrieving photos page $page: $@ or $response->{error_message}";
        redo;
    }
    my $hash   = $response->as_hash();
    my $photos = $hash->{photos}->{photo} || [];
    $photos    = [$photos] unless ref $photos eq 'ARRAY';

    foreach my $p (@$photos) {
        my $tags = $p->{tags} // '';
        my @tags = split /\s+/, $tags;
        my %tagset = map { lc($_) => 1 } @tags;  # lowercase keys for safe compare

        unless ($tagset{$t2_lc}) {
            my $url = "https://www.flickr.com/photos/$p->{owner}/$p->{id}/";
            push @results, {
                id    => $p->{id},
                title => $p->{title} // '',
                url   => $url,
                tags  => \@tags,   # keep original case returned
            };
        }
    }

    $pages = $hash->{photos}->{pages} || 1;
    print "Processed page $page of $pages";
    $page++;
} while ($page <= $pages);

if (@results) {
    print "Found " . scalar(@results) . " photos with tag '$t1' but not '$t2'";
    print $json->pretty->encode(\@results);
} else {
    print "No photos found with tag '$t1' that exclude '$t2'.";
}
