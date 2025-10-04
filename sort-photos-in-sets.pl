#!/usr/bin/perl
# =============================================================================
# Script: sort-photos-in-sets.pl
#
# Purpose:
#   Reorders Flickr photosets by views, faves, comments or user-defined Perl expression.
#   This version uses plain eval() without Safe compartment.
#
# Usage:
#   perl sort-photos-in-sets.pl [OPTIONS]
#
# Requirements:
#   - Flickr API token at $HOME/saved-flickr.st
#   - Perl modules: Flickr::API, Data::Dumper
#
# WARNING:
#   Using plain eval() exposes risk if user expressions are untrusted.
#
# =============================================================================

use strict;
use warnings;
use Getopt::Long;
use Flickr::API;
use Data::Dumper;

($\, $,) = ("\n", "\n");

my ($help, $filter_pattern, $dry_run, $sort, $sort_expr, $rev, $debug);

$filter_pattern = '.*';
$sort = 'datetaken';

GetOptions(
    'h|help'            => \$help,
    'f|filter=s'        => \$filter_pattern,
    'n|dry-run'         => \$dry_run,
    's|sort=s'          => \$sort,
    'expr|sort-expr=s'  => \$sort_expr,
    'r|reverse'         => \$rev,
    'debug'             => \$debug,
) or die "Error in command line arguments\n";

if ($help) {
    print <<'HELP';
Usage: perl sort-photos-in-sets.pl [OPTIONS]

Options:
  -h, --help
      Show this help message and exit.

  -f, --filter=PATTERN
      Only process photosets whose title matches PATTERN (case-insensitive regex).
      [Default: .*] (all photosets)
      Example: --filter='Vacation'

  -s, --sort=KEY
      Sort photos within each photoset by the given key.
      [Default: datetaken]
      Common keys:
        views          - Number of views (numeric)
        datetaken      - Date/time taken (string "YYYY-MM-DD HH:MM:SS")
        dateupload     - Upload date/time (Unix timestamp)
        faves          - Number of favorites
        comments       - Number of comments

      Additional combination keys (precomputed metrics using views, faves, and comments):
        faves+comments          - Sum of faves and comments (e.g., for sorting by total engagement)
        faves/comments          - Ratio of faves to comments (faves divided by comments; uses a small default if comments=0 to avoid division by zero)
        views/comments          - Ratio of views to comments (views divided by comments)
        views/(faves+comments)  - Ratio of views to the sum of faves and comments (useful for sorting by "efficiency" of engagement per view)
        comments/faves          - Ratio of comments to faves (comments divided by faves)
        comments/views          - Ratio of comments to views (comments divided by views; e.g., for interaction rate)
        faves/views             - Ratio of faves to views (faves divided by views; e.g., for popularity rate)
        (faves+comments)/views  - Ratio of the sum of faves and comments to views (e.g., for overall engagement per view)

      Notes on combinations:
        - These keys are automatically computed for each photo and can be used directly without --sort-expr.
        - Ratios handle zero denominators gracefully by using a tiny value (0.00001) to prevent errors.
        - For example, use --sort='faves/views' to sort by fave rate (ascending: lowest rate first).
        - You can combine with --reverse for descending order (e.g., highest engagement first).
        - If your desired combination isn't listed, use --sort-expr for custom logic.

  --sort-expr=EXPR
      Sort by Perl expression using these variables:
        $views, $faves, $comments, $datetaken, $dateupload

      [Default: none]
      Notes:
        - $datetaken: "YYYY-MM-DD HH:MM:SS" string
        - $dateupload: integer (epoch seconds)
      Examples:
        --sort-expr='($faves + $comments * 100) / ($views || 1)'
            Sort by weighted combination (favorites and comments vs. views)
        --sort-expr='substr($datetaken, 0, 4)'
            Sort by year photo taken
        --sort-expr='$dateupload'
            Sort by upload date (newest or oldest)

  -r, --reverse
      Reverse the sorting order (descending rather than ascending).
      [Default: off]
      Example: --reverse

  -n, --dry-run
      Preview the changes; do not actually modify Flickr.
      [Default: off]
      Example: --dry-run

  --debug
      Print detailed debug info on comparisons.
      [Default: off]
      Example: --debug

Defaults:
  --filter='.*'       (matches all photosets)
  --sort=datetaken    (sort by date taken ascending)
  (no --sort-expr)    (uses --sort option instead)
  (no --reverse)      (ascending order)
  (no --dry-run)      (changes photoset order on Flickr)
  (no --debug)        (minimal output)

Examples:

  # Default: Sort by date taken ascending, all photosets
  perl sort-photos-in-sets.pl

  # Sort by views ascending (least viewed first)
  perl sort-photos-in-sets.pl --sort=views

  # Sort by date taken descending (most recent first)
  perl sort-photos-in-sets.pl --sort=datetaken --reverse

  # Filter sets by 'Trip' and sort using a custom metric
  perl sort-photos-in-sets.pl --filter='Trip' --sort-expr='($faves + $comments*10) / ($views || 1)' --reverse

  # Preview sorting (no changes made) and print debug info
  perl sort-photos-in-sets.pl --dry-run --debug

  # Sort by year taken within sets having '2023' in title
  perl sort-photos-in-sets.pl --filter='2023' --sort-expr='substr($datetaken,0,4)'

Important Notes:

  - Plain Perl eval is used for --sort-expr. DO NOT use untrusted expressions!
  - Requires Flickr API token at $HOME/saved-flickr.st
  - Some sort keys (faves, comments) may trigger extra API calls and slow down processing.
  - Large sets may take longer due to Flickr API limits.

HELP
    exit;
}



sub validate_sort_expr {
    my $expr = shift;
    die "Invalid characters in --sort-expr\n" if $expr =~ /[^ \d\$\+\-\*\/\%\(\)\.\:\?\>\<\=\!\&\|\^\w]/;
    my @forbidden = qw(system exec open unlink fork do eval use require package);
    die "Forbidden keyword in --sort-expr\n" if $expr =~ /\b(?:@forbidden)\b/;
}

if ($sort_expr) {
    eval { validate_sort_expr($sort_expr); };
    die "Sort expression validation failed: $@" if $@;
}

my $re_filter = qr/$filter_pattern/i;

my $config_file = "$ENV{HOME}/saved-flickr.st";
my $flickr = Flickr::API->import_storable_config($config_file);

my $photosets = [];
my ($page, $pages) = (1, 1);
while ($page <= $pages) {
    my $resp = $flickr->execute_method('flickr.photosets.getList', { per_page => 500, page => $page });
    warn "Error fetching photosets page $page: $resp->{error_message}" and sleep 1 and redo unless $resp->{success};
    push @$photosets, grep { $_->{title} =~ $re_filter } @{$resp->as_hash->{photosets}->{photoset}};
    $pages = $resp->as_hash->{photosets}->{pages};
    $page = $resp->as_hash->{photosets}->{page} + 1;
}

foreach my $photoset (@$photosets) {
    my $photos = [];
    ($page, $pages) = (1, 1);
    while ($page <= $pages) {
        my $resp = $flickr->execute_method('flickr.photosets.getPhotos', {
            photoset_id => $photoset->{id},
            extras      => 'views,date_upload,date_taken,last_update,machine_tags',
            per_page    => 500,
            page        => $page,
        });
        warn "Error fetching photos in '$photoset->{title}' page $page: $resp->{error_message}" and sleep 1 and redo unless $resp->{success};
        my $plist = $resp->as_hash->{photoset}->{photo};
        $plist = [ $plist ] unless ref($plist) eq 'ARRAY';
        push @$photos, @$plist;
        $pages = $resp->as_hash->{photoset}->{pages};
        $page = $resp->as_hash->{photoset}->{page} + 1;
    }

    foreach my $photo (@$photos) {
        $photo->{views}      //= 0;
        $photo->{faves}      //= 0;
        $photo->{comments}   //= 0;
        $photo->{dateupload} //= 0;

        if ($sort_expr || $sort =~ /faves|comments/) {
            my $fav_resp = $flickr->execute_method('flickr.photos.getFavorites', {
                photo_id => $photo->{id},
                per_page => 1,
            });
            $photo->{faves} = $fav_resp->as_hash->{photo}->{total} if $fav_resp->{success};
            $photo->{faves} //= 0;

            my $comm_resp = $flickr->execute_method('flickr.photos.comments.getList', { photo_id => $photo->{id} });
            my $comments = $comm_resp->as_hash->{comments}->{comment} if $comm_resp->{success};
            $comments //= [];
            $comments = [ $comments ] unless ref($comments) eq 'ARRAY';
            $photo->{comments} = scalar @$comments;
        }

        my $faves_den    = $photo->{faves}    || .00001;
        my $comments_den = $photo->{comments} || .00001;
        my $views_den    = $photo->{views}    || .00001;

        $photo->{'faves+comments'}          = $photo->{faves} + $photo->{comments};
        $photo->{'faves/comments'}          = $photo->{faves} / $comments_den;
        $photo->{'views/comments'}          = $photo->{views} / $comments_den;
        $photo->{'views/(faves+comments)'} = $photo->{'faves+comments'} > 0 ? $photo->{views} / $photo->{'faves+comments'} : 0;

        $photo->{'comments/faves'}          = $photo->{comments} / $faves_den;
        $photo->{'comments/views'}          = $photo->{comments} / $views_den;
        $photo->{'faves/views'}             = $photo->{faves} / $views_den;
        $photo->{'(faves+comments)/views'} = $photo->{'faves+comments'} / $views_den;

        if ($debug) {
            print "DEBUG Photo: $photo->{title} (ID=$photo->{id}) Views=$photo->{views} Faves=$photo->{faves} Comments=$photo->{comments}";
            print " ratios: comments/faves=$photo->{'comments/faves'} comments/views=$photo->{'comments/views'} faves/views=$photo->{'faves/views'} (faves+comments)/views=$photo->{'(faves+comments)/views'}";
        }
    }

    my @sorted;
    if ($sort_expr) {
        @sorted = sort {
            # Define a small helper subroutine to compute the sort value for a photo
            my $compute_val = sub {
                my ($photo) = @_;
                my ($views, $faves, $comments, $datetaken, $dateupload) =
                    @{$photo}{qw(views faves comments datetaken dateupload)};
                my $val = eval $sort_expr;
                warn $@ if $@;
                $val //= 0;
                return $val;
            };

            my $val_a = $compute_val->($a);
            my $val_b = $compute_val->($b);

            warn sprintf(
                "DEBUG sort cmp: A: title='%s' faves=%d views=%d comments=%d val=%.4f | B: title='%s' faves=%d views=%d comments=%d val=%.4f",
                $a->{title} // '', $a->{faves}, $a->{views}, $a->{comments}, $val_a,
                $b->{title} // '', $b->{faves}, $b->{views}, $b->{comments}, $val_b,
            ) if $debug;

            $val_a <=> $val_b;
        } @$photos;
    } elsif ($sort =~ /.+:seq/) {
        my $tag_pattern = $sort;
        $tag_pattern =~ s/[^a-z0-9:]//ig;
        foreach my $p (@$photos) {
            my ($seq) = $p->{machine_tags} =~ /$tag_pattern=(\d+)/i;
            $p->{seq} = defined $seq ? $seq : 100000;
        }
        @sorted = sort { $a->{seq} <=> $b->{seq} || $b->{datetaken} cmp $a->{datetaken} } @$photos;
    } elsif ($sort eq 'datetaken') {
        @sorted = sort { $a->{datetaken} cmp $b->{datetaken} } @$photos;
    } else {
        @sorted = sort { $a->{$sort} <=> $b->{$sort} } @$photos;
    }

    @sorted = reverse @sorted if $rev;

    if ($dry_run) {
        print "Dry-run mode: Photoset '$photoset->{title}' would be reordered as follows:";
        foreach my $photo (@sorted) {
            print "  " . ($photo->{title} // '(no title)') . " (ID: $photo->{id})";
        }
        next;
    }

    my $sorted_ids = join(',', map { $_->{id} } @sorted);
    my $resp = $flickr->execute_method('flickr.photosets.reorderPhotos', {
        photoset_id => $photoset->{id},
        photo_ids   => $sorted_ids,
    });
    warn "Failed reordering photoset '$photoset->{title}': $resp->{error_message}" and next unless $resp->{success};
    print "Photoset '$photoset->{title}' sorted by " . ($sort_expr ? "expr '$sort_expr'" : $sort) . ($rev ? " (reversed)" : "") . ".";
}
