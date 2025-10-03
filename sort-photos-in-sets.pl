#!/usr/bin/perl
# =============================================================================
# Script: sort-photos-in-sets.pl
#
# Description:
#   Reorders Flickr photosets by flexible sorting metrics: views, faves, comments,
#   combined ratios, or any user Perl expression on those fields.
#
# Usage:
#   perl sort-photos-in-sets.pl [OPTIONS]
#
# Options:
#   -h, --help               Show this help.
#   -f, --filter=PATTERN     Only process sets whose title matches PATTERN (regex, case-insensitive).
#   -s, --sort=KEY           Sort by: views, datetaken, dateupload, faves, comments, faves+comments,
#                            faves/comments, views/comments, comments/faves, comments/views,
#                            faves/views, (faves+comments)/views, ...
#   --sort-expr=EXPR         Perl expression on $views, $faves, $comments, $datetaken, $dateupload.
#       Examples:
#         --sort-expr '($faves + $comments)/($views || 1)'
#         --sort-expr 'substr($datetaken,0,4)'  # sort by year taken (datetaken format "YYYY-MM-DD HH:MM:SS")
#         --sort-expr '$dateupload'             # sort by upload timestamp (Unix time)
#   -r, --reverse            Reverse sorting direction.
#   -n, --dry-run            Print what would be done, no Flickr changes.
#   --debug                  Print extra debug info, including API response dumps.
#
# Requirements:
#   - API token saved in $HOME/saved-flickr.st
#   - Perl modules: Flickr::API, Data::Dumper
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
    'h|help'        => \$help,
    'f|filter=s'    => \$filter_pattern,
    'n|dry-run'     => \$dry_run,
    's|sort=s'      => \$sort,
    'expr|sort-expr=s' => \$sort_expr,
    'r|reverse'     => \$rev,
    'debug'         => \$debug,
);

if ($help) {
    print <<'HELP';
Usage: perl sort-photos-in-sets.pl [OPTIONS]

Options:
  -h, --help               Show this help.
  -f, --filter=PATTERN     Only sets whose title matches PATTERN.
  -s, --sort=KEY           Sort by keys such as:
                           views, datetaken (default), dateupload, faves, comments,
                           faves+comments, faves/comments, views/comments,
                           comments/faves, comments/views, faves/views,
                           (faves+comments)/views, ...
  --sort-expr=EXPR         Perl expression on:
       $views, $faves, $comments, $datetaken, $dateupload
     - $datetaken is string format "YYYY-MM-DD HH:MM:SS"
     - $dateupload is Unix timestamp (seconds since epoch)
     Example expressions:
       --sort-expr '($faves + $comments) / ($views || 1)'
       --sort-expr 'substr($datetaken,0,4)'   # sort by year taken
       --sort-expr '$dateupload'              # sort by upload time

  -r, --reverse            Reverse the sort order.
  -n, --dry-run            Show what would be done; do not update Flickr.
  --debug                  Print full API responses and debug info.

HELP
    exit;
}

my $config_file = "$ENV{HOME}/saved-flickr.st";
my $flickr = Flickr::API->import_storable_config($config_file);
my $re_filter = qr/$filter_pattern/i;

# Decide if favorites/comments data is needed based on --sort or --sort-expr
my $need_faves_comments = 0;
if ($sort_expr) {
    $need_faves_comments = 1;
} elsif ($sort =~ /faves|comments/) {
    $need_faves_comments = 1;
}

# Fetch all photosets matching filter
my $photosets = [];
my ($page, $pages) = (1, 1);
while ($page <= $pages) {
    my $resp = $flickr->execute_method('flickr.photosets.getList', { per_page => 500, page => $page });
    warn "Error fetching photosets page $page: $resp->{error_message}" and sleep 1 and redo unless $resp->{success};
    push @$photosets, grep { $_->{title} =~ $re_filter } @{$resp->as_hash->{photosets}->{photoset}};
    $pages = $resp->as_hash->{photosets}->{pages};
    $page = $resp->as_hash->{photosets}->{page} + 1;
}

if ($dry_run) {
    print map { "Photoset $_->{title} would be sorted by ".($sort_expr ? "expr '$sort_expr'" : $sort).($rev ? " (reversed)" : "") } @$photosets;
    exit;
}

foreach my $photoset (@$photosets) {
    # Fetch all photos for this photoset
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
        # Views from extras, default 0
        $photo->{views} = $photo->{views} // 0;

        # Unix timestamp for upload
        $photo->{dateupload} = $photo->{dateupload} // 0;

        if ($need_faves_comments) {
            # Fetch favorites with minimal data for total count
            my $fav_resp = $flickr->execute_method('flickr.photos.getFavorites', {
                photo_id => $photo->{id},
                per_page => 1,
            });
            if ($fav_resp->{success}) {
                $photo->{faves} = $fav_resp->as_hash->{photo}->{total} // 0;
                print Dumper($fav_resp->as_hash) if $debug;
            } else {
                warn "Failed to get favorites for photo $photo->{id}";
                $photo->{faves} = 0;
            }

            # Fetch comments list
            my $comm_resp = $flickr->execute_method('flickr.photos.comments.getList', {
                photo_id => $photo->{id},
            });
            if ($comm_resp->{success}) {
                my $comments = $comm_resp->as_hash->{comments}->{comment};
                $photo->{comments} = ref($comments) eq 'ARRAY' ? scalar(@$comments) : ($comments ? 1 : 0);
                print Dumper($comm_resp->as_hash) if $debug;
            } else {
                warn "Failed to get comments for photo $photo->{id}";
                $photo->{comments} = 0;
            }
        } else {
            # Defaults if no faves/comments needed
            $photo->{faves} = 0;
            $photo->{comments} = 0;
        }

        # Prevent division by zero denominators
        my $faves_den = $photo->{faves} == 0 ? 1 : $photo->{faves};
        my $views_den = $photo->{views} == 0 ? 1 : $photo->{views};

        # Derived metrics
        $photo->{'faves+comments'}            = $photo->{faves} + $photo->{comments};
        $photo->{'faves/comments'}            = $photo->{comments} > 0 ? $photo->{faves} / $photo->{comments} : 0;
        $photo->{'views/comments'}            = $photo->{comments} > 0 ? $photo->{views} / $photo->{comments} : 0;
        $photo->{'views/(faves+comments)'}    = $photo->{'faves+comments'} > 0 ? $photo->{views} / $photo->{'faves+comments'} : 0;

        # Your selected ratios with safe math
        $photo->{'comments/faves'}            = $photo->{comments} / $faves_den;
        $photo->{'comments/views'}            = $photo->{comments} / $views_den;
        $photo->{'faves/views'}               = $photo->{faves} / $views_den;
        $photo->{'(faves+comments)/views'}    = ($photo->{faves} + $photo->{comments}) / $views_den;

        if ($debug) {
            print "DEBUG Photo: $photo->{title} (ID=$photo->{id})";
            print " Views=$photo->{views} Faves=$photo->{faves} Comments=$photo->{comments}";
            print " comments/faves=$photo->{'comments/faves'}";
            print " comments/views=$photo->{'comments/views'}";
            print " faves/views=$photo->{'faves/views'}";
            print " (faves+comments)/views=$photo->{'(faves+comments)/views'}";
        }
    }

    # Sorting
    my @sorted;
    if ($sort_expr) {
        @sorted = sort {
            my ($views,$faves,$comments,$datetaken,$dateupload) = ($a->{views}, $a->{faves}, $a->{comments}, $a->{datetaken}, $a->{dateupload});
            my $val_a = eval $sort_expr; $val_a = 0 if $@;
            ($views,$faves,$comments,$datetaken,$dateupload) = ($b->{views}, $b->{faves}, $b->{comments}, $b->{datetaken}, $b->{dateupload});
            my $val_b = eval $sort_expr; $val_b = 0 if $@;
            ($val_a || 0) <=> ($val_b || 0);
        } @$photos;
    }
    elsif ($sort =~ /.+:seq/) {
        my $tag_pattern = $sort; $tag_pattern =~ s/[^a-z0-9:]//ig;
        foreach my $p (@$photos) {
            my ($seq) = $p->{machine_tags} =~ /$tag_pattern=(\d+)/i;
            $p->{seq} = defined $seq ? $seq : 100000;
        }
        @sorted = sort { $a->{seq} <=> $b->{seq} || $b->{datetaken} cmp $a->{datetaken} } @$photos;
    }
    elsif ($sort eq 'datetaken') {
        @sorted = sort { $a->{datetaken} cmp $b->{datetaken} } @$photos;
    }
    else {
        # Numeric fallback covers dateupload and numeric keys
        @sorted = sort { $a->{$sort} <=> $b->{$sort} } @$photos;
    }

    @sorted = reverse @sorted if $rev;

    # Reorder photoset
    my $sorted_ids = join(',', map { $_->{id} } @sorted);
    my $resp = $flickr->execute_method('flickr.photosets.reorderPhotos', {
        photoset_id => $photoset->{id},
        photo_ids   => $sorted_ids,
    });
    warn "Failed reordering photoset '$photoset->{title}': $resp->{error_message}" and next unless $resp->{success};
    print "Photoset '$photoset->{title}' sorted by ".($sort_expr ? "expr '$sort_expr'" : $sort).($rev ? " (reversed)" : "").".";
}
