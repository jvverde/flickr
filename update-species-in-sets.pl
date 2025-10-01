#!/usr/bin/perl
use strict;
use warnings;
use Getopt::Long;
use Data::Dumper;
use Flickr::API;
use List::Util qw(min);

#===============================================================================
# Script: update_flickr_sets.pl
#
# Purpose:
#   Updates the description of Flickr photosets by appending or replacing
#   a summary of bird species based on machine tags found in the photos.
#
# Behaviour:
#   - Looks for machine tags in the form:
#       <TAG>:seq=NUMBER
#       <TAG>:binomial=NAME
#       <TAG>:name=englishname
#   - Counts species and genera across all photos in each photoset.
#   - Creates a summary with totals and per-species counts.
#   - Inserts the summary into the photoset description:
#       - If a block already exists between delimiters, it is replaced.
#       - Otherwise, a new block is appended.
#
# Usage:
#   perl update_flickr_sets.pl -t bird -f "Portugal"
#
# Options:
#   -h, --help        Show help message
#   -f, --filter REG  Only process photosets whose titles match REG
#   -t, --tag TAG     Machine tag namespace to use (required)
#   -n, --dry-run     Simulate without making changes
#
# Examples:
#   # Update all sets with tag namespace "bird"
#   perl update_flickr_sets.pl -t bird
#
#   # Only update sets whose title includes "Portugal"
#   perl update_flickr_sets.pl -t bird -f "Portugal"
#
#   # Simulate changes without modifying Flickr
#   perl update_flickr_sets.pl -t bird -n
#
# Notes:
#   Requires Flickr API tokens saved in: $HOME/saved-flickr.st
#===============================================================================

# Output field separators (print will join with newline automatically)
($\, $,) = ("\n", "\n");

#------------------------------------------------------------------------------
# Parse command-line options
#------------------------------------------------------------------------------
my $help;                     # show help flag
my $filter_pattern = '.*';    # regex for filtering sets, default: match all
my $dry_run;                  # if true, do not update Flickr
my $tag;                      # machine tag namespace (required)

GetOptions(
    'h|help'   => \$help,
    'f|filter=s' => \$filter_pattern,
    'n|dry-run'  => \$dry_run,
    't|tag=s'    => \$tag,
);

#------------------------------------------------------------------------------
# Show help and exit
#------------------------------------------------------------------------------
if ($help) {
    print <<"HELP";
This script updates the description of Flickr photosets by appending/replacing
a species summary based on machine tags in photos.

Machine tags searched:
  <TAG>:seq=NUMBER
  <TAG>:binomial=NAME
  <TAG>:name=englishname

Usage: $0 [OPTIONS]

Options:
  -h, --help      Show this help message and exit
  -f, --filter    Filter photosets by regex (default: '.*')
  -t, --tag       Machine tag namespace to look for (required)
  -n, --dry-run   Simulate without making changes

Examples:
 $0 -h
 $0 -F Tan -t IOC151 -n
 $0 -F '^Tan' -t IOC151 -n
 $0 -F '^Tan' -t IOC151
 $0 -F '^Vidu.+dae\$|Plo.+dae$|Estri.+dae\$' -t IOC151
 $0 -F '^Estri.+dae\$' -t IOC151
 $0 -F '^Buphagi' -t IOC151
 $0 -F '^Ardeidae|Pelecani' -t IOC151
 $0 -F '^Cist|Arde|Cico' -t IOC151
 $0 -F 'Coraci|PIcif|Coracif|passerif|Fringi|Muscic|Alce' -t IOC151
 $0 -F 'Coraci|Estril|Picif|Coracif|passerif|Fringi|Muscic|Alce' -t IOC151
 $0 -F 'Plocei' -t IOC151
 $0 -F '^Passer' -t IOC151
 $0 -F '^Coli' -t IOC151
 $0 -F '^Coraci|Alce|Passe' -t IOC151
 $0 -F '^Coraci|Pici' -t IOC151
 $0 -F '^Pici' -t IOC151
 $0 -f '^Tanz' -t IOC151
 $0 -f '^20[012]' -t IOC151

NOTE: Flickr API tokens must be initialized in:
  $ENV{HOME}/saved-flickr.st
HELP
    exit;
}

#------------------------------------------------------------------------------
# Ensure tag is provided
#------------------------------------------------------------------------------
die "Error: Tag parameter (-t) is required\n"
  unless defined $tag && $tag ne '';

#------------------------------------------------------------------------------
# Initialize Flickr API using stored credentials
#------------------------------------------------------------------------------
my $config_file = "$ENV{HOME}/saved-flickr.st";
my $flickr      = Flickr::API->import_storable_config($config_file);

#------------------------------------------------------------------------------
# Compile regex filter
#------------------------------------------------------------------------------
my $re = qr/$filter_pattern/i;

#------------------------------------------------------------------------------
# Step 1: Retrieve all photosets that match the filter
#------------------------------------------------------------------------------
my $photosets = [];   # arrayref to collect sets
my $page      = 1;
my $pages     = 1;

while ($page <= $pages) {
    my $response = $flickr->execute_method('flickr.photosets.getList', {
        per_page => 500,
        page     => $page,
    });

    # retry if error
    warn "Error: $response->{error_message}" and redo
      unless $response->{success};

    # filter sets by title
    push @$photosets, grep { $_->{title} =~ $re }
      @{ $response->as_hash->{photosets}->{photoset} };

    # pagination control
    $pages = $response->as_hash->{photosets}->{pages};
    $page  = $response->as_hash->{photosets}->{page} + 1;
}

#------------------------------------------------------------------------------
# Step 2: Process each photoset
#------------------------------------------------------------------------------
my $total_sets_updated = 0;

foreach my $photoset (@$photosets) {
    print "Processing photoset: $photoset->{title}";

    #-- 2.1 Get photoset description
    my $info_response = $flickr->execute_method('flickr.photosets.getInfo', {
        photoset_id => $photoset->{id},
    });
    warn "Error getting info for $photoset->{title}: $info_response->{error_message}"
      and next
      unless $info_response->{success};

    my $current_desc = $info_response->as_hash->{photoset}->{description} || '';
    $current_desc = $current_desc->{_content} // ''
      if ref $current_desc eq 'HASH';  # some API calls return {_content}

    #-- 2.2 Collect all photos in this set
    my $photos      = [];
    my $photo_page  = 1;
    my $photo_pages = 1;

    while ($photo_page <= $photo_pages) {
        my $photo_response =
          $flickr->execute_method('flickr.photosets.getPhotos', {
            photoset_id => $photoset->{id},
            per_page    => 500,
            page        => $photo_page,
          });

        warn "Error getting photos from $photoset->{title}: $photo_response->{error_message}"
          and redo
          unless $photo_response->{success};

        my $bunch = $photo_response->as_hash->{photoset}->{photo};
        $bunch = [$bunch] unless ref $bunch eq 'ARRAY';
        push @$photos, @$bunch;

        $photo_pages = $photo_response->as_hash->{photoset}->{pages};
        $photo_page  = $photo_response->as_hash->{photoset}->{page} + 1;
    }

    #-- 2.3 Extract species info from tags
    my %species_data;  # key: species binomial => {count, min_seq, english_name}
    my %genera;        # key: genus => 1
    my $photos_processed = 0;

    foreach my $photo (@$photos) {
        # Fetch tags for photo
        my $tag_response = $flickr->execute_method('flickr.tags.getListPhoto', {
            photo_id => $photo->{id},
        });

        if (!$tag_response->{success}) {
            warn "Error getting tags for photo $photo->{id} in $photoset->{title}: $tag_response->{error_message}";
            next;
        }

        my $tags = $tag_response->as_hash->{photo}->{tags}->{tag} || [];
        $tags = [$tags] unless ref $tags eq 'ARRAY';

        # parse only machine tags with correct namespace
        my %machinetags;
        foreach my $t (@$tags) {
            if ($t->{machine_tag}
                && $t->{raw} =~ /^\Q$tag\E:([^=]+)=(.+)$/i)
            {
                my ($pred, $val) = ($1, $2);
                if ($val =~ /^"(.*)"$/) {
                    $val = $1;
                    $val =~ s/\\"/"/g;    # unescape quotes
                }
                $machinetags{$pred} = $val;
            }
        }

        # require both seq and binomial to consider valid species
        if (   exists $machinetags{seq}
            && $machinetags{seq} =~ /^\d+$/
            && exists $machinetags{binomial})
        {
            my $species      = $machinetags{binomial};
            my $seq          = $machinetags{seq};
            my $english_name = $machinetags{name} // 'Unknown';

            $species_data{$species}{count}++;
            $species_data{$species}{min_seq} =
              min($species_data{$species}{min_seq} // 999999, $seq);

            $species_data{$species}{english_name} = $english_name
              unless defined $species_data{$species}{english_name}
              && $species_data{$species}{english_name} ne 'Unknown';

            # extract genus = first word of binomial
            if ($species =~ /^(\w+)/) {
                $genera{$1} = 1;
            }
        }

        $photos_processed++;
        print "  Processed $photos_processed photos..."
          if $photos_processed % 10 == 0;
    }

    #-- 2.4 Skip if no species found
    if (!%species_data) {
        print "No species found in photoset: $photoset->{title}";
        next;
    }

    #-- 2.5 Generate species summary
    my $total_species = scalar keys %species_data;
    my $total_genera  = scalar keys %genera;

    my @sorted_species =
      sort { $species_data{$a}{min_seq} <=> $species_data{$b}{min_seq} }
      keys %species_data;

    my $species_list = join(",\n",
        map {
            "$_ // $species_data{$_}{english_name} ($species_data{$_}{count})"
        } @sorted_species);

    my $summary =
      "Total species: $total_species\nTotal genera: $total_genera\nSpecies in this set:\n$species_list";

    #-- Step 5: Insert or replace summary in description ----------------------
    my $delim_start = "--- Species Summary ---";
    my $delim_end   = "--- End Species Summary ---";

    my $new_desc = $current_desc;

    # Attempt to replace any *existing* summary block with the new $summary.
    # The regex looks for text between $delim_start and $delim_end:
    #
    #   (?<=\Q$delim_start\E)   Positive lookbehind — asserts that the match
    #                           is immediately preceded by the literal string
    #                           $delim_start.  \Q...\E escapes special chars.
    #
    #   \s*.*?\s*               The old summary content.  ".*?" is non-greedy,
    #                           so it matches the *shortest* possible text.
    #                           The \s* on both sides trims optional whitespace
    #                           or blank lines around it.
    #
    #   (?=\Q$delim_end\E)      Positive lookahead — asserts that the match
    #                           is immediately followed by the literal string
    #                           $delim_end.
    #
    #   /s modifier             Makes "." also match newlines, so the match
    #                           can span multiple lines of description.
    #
    # If the substitution succeeds (an old block was found), the old content
    # is replaced with "\n$summary\n".  
    # If it fails (no block found), we append a fresh block at the end instead.
    unless ($new_desc =~ s/(?<=\Q$delim_start\E)\s*.*?\s*(?=\Q$delim_end\E)/\n$summary\n/s) {
        # No summary block found — append a new one at the end.
        $new_desc .= "\n\n$delim_start\n$summary\n$delim_end\n";
    }

    #-- 2.6 Update description on Flickr or just show (dry-run)
    if ($dry_run) {
        print "DRY RUN: Would update description for $photoset->{title} to:\n$new_desc";
    } else {
        # remove leading/trailing newlines
        $new_desc =~ s/^\n+|\n+$//g;

        my $edit_response =
          $flickr->execute_method('flickr.photosets.editMeta', {
            photoset_id => $photoset->{id},
            title       => $photoset->{title},
            description => $new_desc,
          });

        if (!$edit_response->{success}) {
            warn "Error updating description for $photoset->{title}: $edit_response->{error_message}";
            next;
        }

        print "Updated description for photoset: $photoset->{title}";
        $total_sets_updated++;
    }
}

#------------------------------------------------------------------------------
# Final summary
#------------------------------------------------------------------------------
print "\nCompleted! Processed "
  . scalar(@$photosets)
  . " photosets."
  . ($dry_run ? "" : " Updated $total_sets_updated photosets.")
  . "\n";
