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
#   - Perl modules: Flickr::API, Data::Dumper, Safe
#
# =============================================================================

use strict;
use warnings;
use Getopt::Long;
use Flickr::API;
use Data::Dumper;
use Safe;
use Scalar::Util qw(looks_like_number);

# Global variables
our ($views, $faves, $comments, $datetaken, $dateupload);

# Constants
use constant {
    MAX_RETRIES => 3,
    RETRY_DELAY => 2,
    PER_PAGE    => 500,
};

my ($help, $filter_pattern, $dry_run, $sort, $sort_expr, $rev, $debug);

# Default values
$filter_pattern = '.*';
$sort = 'datetaken';

main();
exit;

sub main {
    parse_command_line();
    
    my $flickr = initialize_flickr_api();
    my $photosets = fetch_photosets($flickr, $filter_pattern);
    
    process_photosets($flickr, $photosets);
}

sub parse_command_line {
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
        print_help();
        exit;
    }

    if ($sort_expr) {
        validate_sort_expression($sort_expr);
    }
}

sub print_help {
    print <<'HELP';
Usage: perl sort-photos-in-sets.pl [OPTIONS]

Options:
  -h, --help               Show this help.
  -f, --filter=PATTERN     Only sets whose title matches PATTERN (regex, case-insensitive).
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
}

sub validate_sort_expression {
    my $expr = shift;

    # More permissive but safer validation
    if ($expr =~ /[^ \d\$\+\-\*\/\%\(\)\.\:\?\>\<\=\!\&\|\^\,\_\w]/) {
        die "Invalid characters in --sort-expr: $expr\n";
    }

    my @forbidden_keywords = qw(
        system exec open unlink fork do eval use require package
        while until for foreach goto last next redo delete undef
        print warn die exit waitpid socket connect bind listen accept
        shmget msgget semop kill pipe truncate fcntl ioctl flock
        dbmopen dbmclose syscall dump chroot
    );
    
    foreach my $keyword (@forbidden_keywords) {
        if ($expr =~ /\b\Q$keyword\E\b/) {
            die "Forbidden keyword '$keyword' in --sort-expr\n";
        }
    }
}

sub initialize_flickr_api {
    my $config_file = "$ENV{HOME}/saved-flickr.st";
    
    unless (-f $config_file) {
        die "Flickr configuration file not found: $config_file\n";
    }

    my $flickr = eval {
        Flickr::API->import_storable_config($config_file);
    };
    
    if ($@ || !$flickr) {
        die "Failed to initialize Flickr API: $@\n";
    }

    return $flickr;
}

sub fetch_photosets {
    my ($flickr, $filter_pattern) = @_;
    my $re_filter = qr/$filter_pattern/i;
    my @photosets;
    
    my ($page, $pages) = (1, 1);
    while ($page <= $pages) {
        my $resp = execute_with_retry($flickr, 'flickr.photosets.getList', {
            per_page => PER_PAGE,
            page     => $page,
        });
        
        my $data = $resp->as_hash->{photosets} or next;
        push @photosets, grep { $_->{title} =~ $re_filter } @{$data->{photoset}};
        
        $pages = $data->{pages} || 1;
        $page = $data->{page} + 1;
    }
    
    print "Found " . scalar(@photosets) . " photosets matching filter\n" if $debug;
    return \@photosets;
}

sub fetch_photos_in_set {
    my ($flickr, $photoset) = @_;
    my @photos;
    
    my ($page, $pages) = (1, 1);
    while ($page <= $pages) {
        my $resp = execute_with_retry($flickr, 'flickr.photosets.getPhotos', {
            photoset_id => $photoset->{id},
            extras      => 'views,date_upload,date_taken,last_update,machine_tags',
            per_page    => PER_PAGE,
            page        => $page,
        });
        
        my $data = $resp->as_hash->{photoset} or next;
        my $photo_list = $data->{photo} || [];
        $photo_list = [$photo_list] unless ref($photo_list) eq 'ARRAY';
        
        push @photos, @$photo_list;
        
        $pages = $data->{pages} || 1;
        $page = $data->{page} + 1;
    }
    
    return \@photos;
}

sub execute_with_retry {
    my ($flickr, $method, $params) = @_;
    my $retries = MAX_RETRIES;
    
    while ($retries > 0) {
        my $resp = $flickr->execute_method($method, $params);
        
        if ($resp->{success}) {
            return $resp;
        }
        
        warn "API call failed ($method): $resp->{error_message}. Retries left: $retries\n";
        $retries--;
        
        if ($retries > 0) {
            sleep RETRY_DELAY;
        }
    }
    
    die "Failed to execute $method after " . MAX_RETRIES . " attempts\n";
}

sub enrich_photo_data {
    my ($flickr, $photo, $needs_social_data) = @_;
    
    # Initialize basic fields
    $photo->{views}      //= 0;
    $photo->{dateupload} //= 0;
    $photo->{faves}      //= 0;
    $photo->{comments}   //= 0;
    
    if ($needs_social_data) {
        $photo->{faves} = fetch_favorite_count($flickr, $photo->{id});
        $photo->{comments} = fetch_comment_count($flickr, $photo->{id});
    }
    
    calculate_photo_ratios($photo);
    
    if ($debug) {
        print_debug_photo_info($photo);
    }
}

sub fetch_favorite_count {
    my ($flickr, $photo_id) = @_;
    
    my $resp = $flickr->execute_method('flickr.photos.getFavorites', {
        photo_id => $photo_id,
        per_page => 1,
    });
    
    return $resp->{success} ? ($resp->as_hash->{photo}->{total} || 0) : 0;
}

sub fetch_comment_count {
    my ($flickr, $photo_id) = @_;
    
    my $resp = $flickr->execute_method('flickr.photos.comments.getList', {
        photo_id => $photo_id,
    });
    
    return 0 unless $resp->{success};
    
    my $comments = $resp->as_hash->{comments}->{comment} || [];
    $comments = [$comments] unless ref($comments) eq 'ARRAY';
    
    return scalar @$comments;
}

sub calculate_photo_ratios {
    my $photo = shift;
    
    my $faves_den    = $photo->{faves}    || 1;
    my $comments_den = $photo->{comments} || 1;
    my $views_den    = $photo->{views}    || 1;
    my $combined     = $photo->{faves} + $photo->{comments};

    $photo->{'faves+comments'}           = $combined;
    $photo->{'faves/comments'}           = $photo->{comments} > 0 ? $photo->{faves} / $comments_den : 0;
    $photo->{'views/comments'}           = $photo->{comments} > 0 ? $photo->{views} / $comments_den : 0;
    $photo->{'views/(faves+comments)'}   = $combined > 0 ? $photo->{views} / $combined : 0;
    $photo->{'comments/faves'}           = $photo->{faves} > 0 ? $photo->{comments} / $faves_den : 0;
    $photo->{'comments/views'}           = $photo->{views} > 0 ? $photo->{comments} / $views_den : 0;
    $photo->{'faves/views'}              = $photo->{views} > 0 ? $photo->{faves} / $views_den : 0;
    $photo->{'(faves+comments)/views'}   = $photo->{views} > 0 ? $combined / $views_den : 0;
}

sub print_debug_photo_info {
    my $photo = shift;
    
    print "DEBUG Photo: $photo->{title} (ID=$photo->{id}) " .
          "Views=$photo->{views} Faves=$photo->{faves} Comments=$photo->{comments} " .
          "ratios: comments/faves=$photo->{'comments/faves'} " .
          "comments/views=$photo->{'comments/views'} " .
          "faves/views=$photo->{'faves/views'} " .
          "(faves+comments)/views=$photo->{'(faves+comments)/views'}\n";
}

sub sort_photos {
    my ($photos, $sort_key, $sort_expr, $reverse) = @_;
    
    my @sorted;
    
    if ($sort_expr) {
        @sorted = sort_by_expression($photos, $sort_expr);
    } elsif ($sort_key =~ /.+:seq/) {
        @sorted = sort_by_machine_tag($photos, $sort_key);
    } elsif ($sort_key eq 'datetaken') {
        @sorted = sort { $a->{datetaken} cmp $b->{datetaken} } @$photos;
    } else {
        @sorted = sort { $a->{$sort_key} <=> $b->{$sort_key} } @$photos;
    }
    
    @sorted = reverse @sorted if $reverse;
    return @sorted;
}

sub sort_by_expression {
    my ($photos, $expr) = @_;
    my $compartment = Safe->new();
    $compartment->deny(qw(:default));
    $compartment->permit(qw(:base_core));
    
    return sort {
        local ($views, $faves, $comments, $datetaken, $dateupload) =
            ($a->{views}, $a->{faves}, $a->{comments}, $a->{datetaken}, $a->{dateupload});
        my $val_a = $compartment->reval($expr) // 0;

        local ($views, $faves, $comments, $datetaken, $dateupload) =
            ($b->{views}, $b->{faves}, $b->{comments}, $b->{datetaken}, $b->{dateupload});
        my $val_b = $compartment->reval($expr) // 0;

        # Handle both numeric and string comparisons
        if (looks_like_number($val_a) && looks_like_number($val_b)) {
            $val_a <=> $val_b;
        } else {
            ($val_a // '') cmp ($val_b // '');
        }
    } @$photos;
}

sub sort_by_machine_tag {
    my ($photos, $sort_key) = @_;
    my $tag_pattern = $sort_key;
    $tag_pattern =~ s/:seq$//;
    
    foreach my $photo (@$photos) {
        my ($seq) = $photo->{machine_tags} =~ /\b\Q$tag_pattern\E=(\d+)/i;
        $photo->{_seq} = defined $seq ? $seq : 100000;
    }
    
    return sort { 
        $a->{_seq} <=> $b->{_seq} || 
        $b->{datetaken} cmp $a->{datetaken} 
    } @$photos;
}

sub process_photosets {
    my ($flickr, $photosets) = @_;
    my $needs_social_data = $sort_expr || $sort =~ /faves|comments/;
    
    foreach my $photoset (@$photosets) {
        print "Processing photoset: $photoset->{title}\n";
        
        my $photos = fetch_photos_in_set($flickr, $photoset);
        print "  Found " . scalar(@$photos) . " photos\n" if $debug;
        
        # Enrich photo data
        foreach my $photo (@$photos) {
            enrich_photo_data($flickr, $photo, $needs_social_data);
        }
        
        my @sorted = sort_photos($photos, $sort, $sort_expr, $rev);
        
        if ($dry_run) {
            print_dry_run_results($photoset, \@sorted);
            next;
        }
        
        reorder_photoset($flickr, $photoset, \@sorted);
    }
}

sub print_dry_run_results {
    my ($photoset, $sorted_photos) = @_;
    
    print "Dry-run mode: Photoset '$photoset->{title}' would be reordered to the following photo titles in this order:\n";
    foreach my $photo (@$sorted_photos) {
        printf "  %s (ID: %s, Views: %d, Faves: %d, Comments: %d)\n",
            ($photo->{title} // '(no title)'),
            $photo->{id},
            $photo->{views},
            $photo->{faves},
            $photo->{comments};
    }
}

sub reorder_photoset {
    my ($flickr, $photoset, $sorted_photos) = @_;
    
    my $sorted_ids = join(',', map { $_->{id} } @$sorted_photos);
    
    my $resp = $flickr->execute_method('flickr.photosets.reorderPhotos', {
        photoset_id => $photoset->{id},
        photo_ids   => $sorted_ids,
    });
    
    if ($resp->{success}) {
        print "Photoset '$photoset->{title}' sorted by " . 
              ($sort_expr ? "expr '$sort_expr'" : $sort) . 
              ($rev ? " (reversed)" : "") . ".\n";
    } else {
        warn "Failed reordering photoset '$photoset->{title}': $resp->{error_message}\n";
    }
}