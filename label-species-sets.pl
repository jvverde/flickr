#!/usr/bin/perl
# =============================================================================
# Flickr Bird Sets Processor - Scientific names only (safe title changes)
#
# Purpose:
#   Processes ONLY photosets whose title is a properly-formatted scientific name
#   → Genus starting uppercase, species ALL lowercase (e.g. "Falco tinnunculus")
#   → This pattern EXCLUDES common names like "Common Kestrel" (second word capitalized)
#
#   Adds/updates "orderNO:=A3-HHHH" (or custom token) at the VERY END of description.
#
#   Title correction (to exact raw IOC binomial) is ONLY performed when --force is used.
#   Without --force, any title mismatch is reported as a warning but the title is left unchanged.
#
# Token behaviour (independent of title):
#   • Correct token already at the end → skip set completely
#   • Wrong token value → WARNING + skip unless --force
#   • With --force → replace wrong token
#
# --force therefore controls TWO things:
#   1. Forcing token replacement when the existing value is wrong
#   2. Enabling automatic title correction when the title differs from the IOC raw binomial
#
# Options:
#   -i, --ioc PREFIX      IOC prefix (e.g. IOC151) → REQUIRED
#   -t, --token STR       Token name (default: orderNO)
#   -m, --match REGEX     Additional regex filter on title
#   -f, --force           REQUIRED for title changes AND to override wrong token values
#   -n, --dry-run         Simulate only
#   -d, --debug           Dump first two sets
#   -h, --help            This help
# =============================================================================

use strict;
use warnings;
use Getopt::Long;
use Flickr::API;
use Data::Dumper;

$\ = "\n";

my ($help, $dry_run, $debug, $ioc_prefix, $token, $match, $force);

GetOptions(
    'h|help'     => \$help,
    'n|dry-run'  => \$dry_run,
    'd|debug'    => \$debug,
    'i|ioc=s'    => \$ioc_prefix,
    't|token=s'  => \$token,
    'm|match=s'  => \$match,
    'f|force'    => \$force,
);

if ($help) {
    print <<'END';
Usage: perl flickr_orderNO_scientific_safe.pl -i PREFIX [OPTIONS]

Functionality:
  Processes only properly formatted scientific name sets
  (Genus uppercase start, species all lowercase → e.g. "Falco tinnunculus").

  Adds/updates orderNO:=A3-HHHH at the end of the description.

  Title correction is ONLY done when --force is used.
  Token override (when wrong value exists) also requires --force.

Options:
  -i, --ioc PREFIX      IOC tag prefix (e.g. IOC151) → REQUIRED
  -t, --token STR       Token name (default: orderNO)
  -m, --match=REGEX     Extra title filter
  -f, --force           REQUIRED for title changes AND to replace wrong token values
  -n, --dry-run         Simulate only
  -d, --debug           Dump first two sets
  -h, --help            This help

Examples:
  perl flickr_orderNO_scientific_safe.pl -i IOC151
  perl flickr_orderNO_scientific_safe.pl -i IOC151 --force   # titles will be corrected
END
    exit;
}

die "ERROR: --ioc PREFIX is required\n" unless $ioc_prefix;

if (defined $match) {
    eval { "" =~ /$match/ };
    die "ERROR: invalid regex in --match: $@\n" if $@;
}

$token //= 'orderNO';

my $config_file = "$ENV{HOME}/saved-flickr.st";
my $flickr = Flickr::API->import_storable_config($config_file);

my $per_page = 500;
my $page = 1;
my $total_pages = 1;

# Strict scientific name pattern - EXCLUDES common names
my $species_pattern = qr/^\s*[A-Z][a-z]+\s+[a-z]+\s*$/;
my $code_prefix     = 'A3';

# ----------------------------------------------------------------------
sub canonicalize_tag {
    my $tag = shift // '';
    $tag =~ s/[^a-z0-9:]//gi;
    return lc($tag);
}

sub get_raw_binomial {
    my ($photo_id, $ioc_prefix) = @_;
    my $response = $flickr->execute_method('flickr.tags.getListPhoto', {
        photo_id => $photo_id,
    });

    return undef unless $response->{success};

    my $tag_list = $response->as_hash->{photo}->{tags}->{tag};
    $tag_list = [ $tag_list ] unless ref $tag_list eq 'ARRAY';

    for my $tag (@$tag_list) {
        if ($tag->{raw} =~ /^$ioc_prefix:binomial=(.+)$/i) {
            return $1;
        }
    }
    return undef;
}
# ----------------------------------------------------------------------

my @sets;

while ($page <= $total_pages) {
    my $response = $flickr->execute_method('flickr.photosets.getList', {
        per_page             => $per_page,
        page                 => $page,
        primary_photo_extras => 'machine_tags',
    });

    if (!$response->{success}) {
        warn "Error fetching page $page: $response->{error_message} – retrying...\n";
        sleep 1;
        next;
    }

    my $list = $response->as_hash->{photosets}->{photoset};
    $list = [ $list ] unless ref $list eq 'ARRAY';

    print "Debug: Dumping first two sets", Dumper [@$list[0..1]] if $debug && $page == 1;

    my @matching = grep { $_->{title} =~ $species_pattern } @$list;

    if (defined $match) {
        @matching = grep { $_->{title} =~ /$match/ } @matching;
    }

    push @sets, @matching;

    $total_pages = $response->as_hash->{photosets}->{pages};
    $page++;
}

# ----------------------------------------------------------------------
foreach my $set (@sets) {
    my $title   = $set->{title};
    my $set_id  = $set->{id};
    my $primary = $set->{primary};

    my $mt = $set->{primary_photo_extras}->{machine_tags} || '';
    my %tags;
    for my $tag (split /\s+/, $mt) {
        if ($tag =~ /^$ioc_prefix:([^=]+)=(.+)$/i) {
            $tags{lc($1)} = $2;
        }
    }

    next unless exists $tags{binomial} && exists $tags{seq};
    next unless $tags{seq} =~ /^\d+$/;

    my $seq            = $tags{seq};
    my $hex_seq        = sprintf("%04X", $seq);
    my $sanitized_code = "${code_prefix}-${hex_seq}";
    my $correct_line   = "$token:=$sanitized_code";

    # ===== TITLE HANDLING - ONLY WITH --force =====
    my $new_title = $title;

    if (canonicalize_tag($title) ne canonicalize_tag($tags{binomial})) {
        if ($force) {
            my $raw = get_raw_binomial($primary, $ioc_prefix);
            if (defined $raw && $raw ne '') {
                $new_title = $raw;
            } else {
                print "WARNING: title mismatch in '$title' (ID $set_id) but raw binomial unavailable → skipping set";
                next;
            }
        } else {
            print "WARNING: title mismatch in '$title' (ID $set_id) but --force not used → title left unchanged";
        }
    }

    # ===== DESCRIPTION / TOKEN HANDLING =====
    my $desc_text = ref $set->{description} eq 'HASH'
        ? ($set->{description}{_content} || '')
        : ($set->{description} || '');

    my @lines       = split /\n/, $desc_text;
    my $last_line   = @lines ? $lines[-1] : '';
    my $has_correct = ($last_line eq $correct_line);
    my $has_any_token = grep { /^\Q$token:=\E/ } @lines;

    # Already perfect (correct token at end + title will be unchanged or already correct)
    if ($new_title eq $title && $has_correct) {
        print "Skipping '$title' (ID $set_id): already perfect" unless $dry_run;
        next;
    }

    # Wrong token value exists
    if ($has_any_token && !$has_correct) {
        my ($old) = grep { /^\Q$token:=\E/ } @lines;
        my $old_value = $old // '';
        $old_value =~ s/^\Q$token:=\E//;
        print "WARNING: token mismatch in '$title' (ID $set_id): old='$old_value' new='$sanitized_code'";
        unless ($force || $dry_run) {
            print "         Skipping set (use --force to replace token and/or correct title)";
            next;
        }
        print "         Forcing token replacement (--force)" if $force && !$dry_run;
    }

    # Build new description
    my @new_lines = grep { !/^\Q$token:=\E/ } @lines;
    push @new_lines, $correct_line;
    my $new_desc = join("\n", @new_lines);

    my $title_changed = $new_title ne $title;
    my $desc_changed  = $new_desc  ne $desc_text;

    next unless $title_changed || $desc_changed;

    if ($dry_run) {
        print "Dry-run: '$title' (ID $set_id)";
        print "         → new title : '$new_title'" if $title_changed;
        print "         → token line at end: '$correct_line'" if $desc_changed;
        next;
    }

    my %args = (
        photoset_id => $set_id,
        title       => ($title_changed ? $new_title : $title),
    );
    $args{description} = $new_desc if $desc_changed;

    my $resp = $flickr->execute_method('flickr.photosets.editMeta', \%args);

    if ($resp->{success}) {
        print "OK: '$title' (ID $set_id)";
        print "    → title changed to '$new_title'" if $title_changed;
        print "    → token updated to '$correct_line'" if $desc_changed;
    } else {
        warn "ERROR updating '$title' (ID $set_id): $resp->{error_message} – retrying...";
        sleep 1;
        redo;
    }
}

print "Processing complete!" unless $dry_run;