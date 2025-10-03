#!/usr/bin/perl
# =============================================================================
# Script: sort-photos-in-sets.pl
#
# Purpose:
#   Reorders Flickr photosets based on fields like views, faves, comments,
#   or any user-supplied Perl sort expression.
#
# Usage:
#   perl sort-photos-in-sets.pl [OPTIONS]
#
# Options:
#   -h, --help
#       Display this help message.
#
#   -f, --filter=PATTERN
#       Only process photosets whose title matches PATTERN (case-insensitive regex).
#
#   -s, --sort=KEY
#       Sort by a field or key, examples: views, datetaken (default), dateupload,
#       faves, comments, faves+comments, etc.
#
#   --sort-expr=EXPR
#       Sort by arbitrary Perl expression using variables:
#         $views, $faves, $comments, $datetaken, $dateupload
#
#       Expression examples:
#         --sort-expr '($faves + $comments * 100) / ($views || 1)'
#         --sort-expr 'substr($datetaken,0,4)'   # By year taken
#         --sort-expr '$dateupload'              # By upload timestamp
#
#   -r, --reverse
#       Reverse the sort order.
#
#   -n, --dry-run
#       Show what would be done, do not reorder photos on Flickr.
#
#   --debug
#       Print detailed debug information for each comparison.
#
# Requirements:
#   - Flickr API token saved in $HOME/saved-flickr.st
#   - Perl modules installed: Flickr::API, Data::Dumper
#
# Security note:
#   Since this version uses plain eval() for user expressions, do NOT use untrusted
#   expressions to avoid risk of code injection or damaging operations.
#
# =============================================================================

use strict;
use warnings;
use Getopt::Long;
use Flickr::API;
use Data::Dumper;

# Print record separator and output field separator as newline
($\, $,) = ("\n", "\n");

# Command-line options with defaults
my ($help, $filter_pattern, $dry_run, $sort, $sort_expr, $rev, $debug);
$filter_pattern = '.*';  # Match all sets by default
$sort = 'datetaken';     # Default sort key

GetOptions(
    'h|help'            => \$help,
    'f|filter=s'        => \$filter_pattern,
    'n|dry-run'         => \$dry_run,
    's|sort=s'          => \$sort,
    'expr|sort-expr=s'  => \$sort_expr,
    'r|reverse'         => \$rev,
    'debug'             => \$debug,
) or die "Error in command line arguments\n";

# Print help and exit
if ($help) {
    print <<'HELP';
Usage: perl sort-photos-in-sets.pl [OPTIONS]

Options:
  -h, --help
      Display this help message.

  -f, --filter=PATTERN
      Only process photosets with titles matching PATTERN (case-insensitive).

  -s, --sort=KEY
      Sort by a field/key (views, datetaken, dateupload, faves, comments, etc.)
      Default: datetaken

  --sort-expr=EXPR
      Sort by Perl expression using:
      $views, $faves, $comments, $datetaken, $dateupload

      Examples:
        --sort-expr '($faves + $comments * 10) / ($views || 1)'
        --sort-expr 'substr($datetaken,0,4)'  # sort by year taken
        --sort-expr '$dateupload'             # sort by upload timestamp

  -r, --reverse
      Reverse the sorting order.

  -n, --dry-run
      Show what would be done without changing Flickr.

  --debug
      Print detailed debug info on each comparison.
HELP
    exit;
}

# Validate sort expression to block dangerous code patterns
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

# Configure Flickr API from saved token/configuration
my $config_file = "$ENV{HOME}/saved-flickr.st";
my $flickr = Flickr::API->import_storable_config($config_file);

my $re_filter = qr/$filter_pattern/i;

# Fetch all photosets and filter by title pattern
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

    # Fetch all photos in this photoset (pagination supported)
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

    # Fill undefined fields with zero where appropriate
    foreach my $photo (@$photos) {
        $photo->{views}      //= 0;
        $photo->{faves}      //= 0;
        $photo->{comments}   //= 0;
        $photo->{dateupload} //= 0;

        # Optionally fetch faves and comments counts if needed for sort expression or keys
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
    }

    # Define a helper sub to calculate the user expression
    my $compute_val = sub {
        my ($photo) = @_;
        # Extract relevant fields with hash slice into lexicals
        my ($views, $faves, $comments, $datetaken, $dateupload) =
            @{$photo}{qw(views faves comments datetaken dateupload)};
        # Evaluate user expression in the current lexical scope
        my $val = eval $sort_expr;
        warn $@ if $@;  # Warn on eval errors but continue
        $val //= 0;     # Default undef to 0
        return $val;
    };

    my @sorted;
    if ($sort_expr) {
        # Sort photos using user-defined sort expression
        @sorted = sort {
            my $val_a = $compute_val->($a);
            my $val_b = $compute_val->($b);

            # Debug: shows data and computed values for current comparison
            warn sprintf(
                "DEBUG sort cmp: A: title='%s' faves=%d views=%d comments=%d val=%.4f | B: title='%s' faves=%d views=%d comments=%d val=%.4f",
                $a->{title} // '', $a->{faves}, $a->{views}, $a->{comments}, $val_a,
                $b->{title} // '', $b->{faves}, $b->{views}, $b->{comments}, $val_b,
            ) if $debug;

            # Numeric comparison, treating undef as zero
            ($val_a // 0) <=> ($val_b // 0);
        } @$photos;
    }
    # Other sorting methods (non-expression) can go here
    elsif ($sort eq 'datetaken') {
        @sorted = sort { $a->{datetaken} cmp $b->{datetaken} } @$photos;
    } else {
        @sorted = sort { $a->{$sort} <=> $b->{$sort} } @$photos;
    }

    # Reverse order if requested
    @sorted = reverse @sorted if $rev;

    if ($dry_run) {
        print "Dry-run: Photoset '$photoset->{title}' would be reordered as follows:";
        print "  " . ($_->{title} // '(no title)') . " (ID: $_->{id})" for @sorted;
        next;
    }

    # Submit the new photo order to Flickr
    my $sorted_ids = join(',', map { $_->{id} } @sorted);
    my $resp = $flickr->execute_method('flickr.photosets.reorderPhotos', {
        photoset_id => $photoset->{id},
        photo_ids   => $sorted_ids,
    });
    warn "Failed to reorder photoset '$photoset->{title}': $resp->{error_message}" and next unless $resp->{success};
    print "Photoset '$photoset->{title}' sorted by " . ($sort_expr ? "expression '$sort_expr'" : $sort) . ($rev ? " (reversed)" : "") . ".";
}
