#!/usr/bin/perl
#
# ------------------------------------------------------------------------------
# Flickr Description Filter & Optional Photoset Manager
# ------------------------------------------------------------------------------
#
# Description:
#   This script scans your Flickr photos and finds those whose description
#   length exceeds a given threshold.
#
#   It performs the following:
#     - Fetches all your photos (paginated)
#     - Cleans descriptions (removes marked blocks)
#     - Skips unwanted/generated descriptions
#     - Filters by description length
#
#   Behavior depends on whether --set is provided:
#
#   WITHOUT --set:
#     - Acts as a "dry-run"
#     - Prints matching photos and their descriptions
#
#   WITH --set:
#     - Finds (or creates) the given photoset
#     - Adds matching photos to that set
#     - Prints actions performed
#
# Requirements:
#   - Flickr::API configured with authentication
#   - Config file: ~/saved-flickr.st
#
# Usage examples:
#   List photos with descriptions longer than 500 chars:
#     perl script.pl --length 500
#
#   Add those photos to a set:
#     perl script.pl --length 500 --set "Long Descriptions"
#
# ------------------------------------------------------------------------------

use strict;
use warnings;
use Getopt::Long;
use Flickr::API;
use Data::Dumper;


binmode(STDOUT, ':utf8');

# ------------------------------------------------------------------------------
# Configuration
# ------------------------------------------------------------------------------

my $config_file = "$ENV{HOME}/saved-flickr.st";
my $flickr = Flickr::API->import_storable_config($config_file);

# Verify authentication
my $login_response = $flickr->execute_method('flickr.test.login');
die "Error logging in: $login_response->{error_message}" unless $login_response->{success};
my $user_nsid = $login_response->as_hash->{user}->{id};
warn "Debug: Logged in as $user_nsid\n";
#print Dumper $login_response->as_hash;

my ($length, $set_spec, $help);

# ------------------------------------------------------------------------------
# Usage / Help
# ------------------------------------------------------------------------------

sub usage {
    print <<"END_USAGE";
Usage:
  $0 --length N [--set SETTITLE_OR_ID]

Options:
  -l, --length N   Minimum description length (required)
  -s, --set S      Photoset title or ID (optional)
  -h, --help       Show this help

Behavior:
  Without --set:
    Lists matching photos (dry-run mode)

  With --set:
    Adds matching photos to the given set
    Creates the set if it does not exist
END_USAGE
    exit;
}

# ------------------------------------------------------------------------------
# Flickr API wrapper with retry logic
# ------------------------------------------------------------------------------

sub flickrapicall {
    my ($method, $args) = @_;

    my $maxretries = 5;
    my $delay = 1;

    for my $attempt (1 .. $maxretries) {
        my $response = eval { $flickr->execute_method($method, $args) };

        if ($@ || !$response || !$response->success) {
            my $err = $@ || ($response ? $response->error_message : 'Unknown error');
            warn "Attempt $attempt failed for $method: $err\n";

            die "Giving up after $maxretries attempts\n"
                if $attempt == $maxretries;

            sleep $delay;
            $delay *= 2;
            next;
        }

        return $response->as_hash;
    }
}

# ------------------------------------------------------------------------------
# Remove marked blocks from description
# ------------------------------------------------------------------------------

sub strip_marked_block {
    my ($desc) = @_;
    return '' unless defined $desc;

    my $marker = "==================***==================";

    if ($desc =~ /(.*?)\Q$marker\E.*?\Q$marker\E(.*)/s) {
        return $1 . $2;
    }

    return $desc;
}

# ------------------------------------------------------------------------------
# Filter out unwanted descriptions (auto-generated, multilingual, etc.)
# ------------------------------------------------------------------------------

sub contains_other_names_block {
    my ($desc) = @_;
    return 0 unless defined $desc;

    return 1 if $desc =~ /Logos Dictionary/i;
    return 1 if $desc =~ /My\s+creation\s+.+\d+/i;
    return 1 if $desc =~ /bighugelabs\.com/i;
    return 1 if $desc =~ /flagrantdisregard\.com/i;
    return 1 if $desc =~ /Excerpt from a conversation with ChatGPT/i;

    my $langs = 0;
    $langs++ if $desc =~ /^\s*(Portuguese|French|English|German|Italian|Spanish|Finnish|Dutch|Danish)\s*:/mi;

    return $langs >= 3;
}

# ------------------------------------------------------------------------------
# Extract clean description text
# ------------------------------------------------------------------------------

sub get_description_text {
    my ($photo) = @_;

    my $desc = ref($photo->{description}) eq 'HASH'
        ? ($photo->{description}->{content} // '')
        : ($photo->{description} // '');

    $desc = strip_marked_block($desc);
    $desc =~ s/\r\n/\n/g;
    $desc =~ s/\s+$//;

    return $desc;
}

# ------------------------------------------------------------------------------
# Get all photosets
# ------------------------------------------------------------------------------

sub get_all_photosets {
    my ($page, $pages) = (1, 1);
    my @sets;

    while ($page <= $pages) {
        my $res = $flickr->execute_method('flickr.photosets.getList', {
            user_id => $user_nsid,
            per_page => 500,
            page     => $page,
        });

        die "Error fetching sets\n" unless $res->{success};

        my $data = $res->as_hash->{photosets}->{photoset};
        $data = [$data] unless ref($data) eq 'ARRAY';

        push @sets, @$data;

        $pages = $res->as_hash->{photosets}->{pages} || 1;
        $page++;
    }

    return \@sets;
}

# ------------------------------------------------------------------------------
# Resolve photoset by title or ID
# ------------------------------------------------------------------------------

sub resolve_photoset {
    my ($set_spec) = @_;
    return undef unless defined $set_spec && length $set_spec;

    # If numeric → treat as ID
    if ($set_spec =~ /^\d+$/) {
        my $res = flickrapicall('flickr.photosets.getInfo', {
            user_id => $user_nsid,
            photoset_id => $set_spec
        });

        my $set = $res->{photoset};
        return {
            id    => $set_spec,
            title => $set->{title} // 'Unknow set',
        };
    }

    # Otherwise search by title
    my $sets = get_all_photosets();

    for my $s (@$sets) {
        my $title = $s->{title} // '';
        return { id => $s->{id}, title => $title }
            if $title eq $set_spec;
    }

    return undef;
}

# ------------------------------------------------------------------------------
# Create photoset if it does not exist
# ------------------------------------------------------------------------------

sub check_or_create_photoset {
    my ($title, $photo_id) = @_;

    print "Set '$title' not found. Creating it using photo $photo_id...\n";

    my $res = $flickr->execute_method('flickr.photosets.create', {
        title            => $title,
        primary_photo_id => $photo_id
    });

    unless ($res->{success}) {
        warn "Error creating set '$title'\n";
        return undef;
    }

    return $res->as_hash->{photoset};
}

# ------------------------------------------------------------------------------
# Add photo to set
# ------------------------------------------------------------------------------

sub add_photo_to_set {
    my ($photo_id, $set) = @_;
    return unless $set && $set->{id};

    my $res = eval {
        $flickr->execute_method('flickr.photosets.addPhoto', {
            photoset_id => $set->{id},
            photo_id    => $photo_id,
        });
    };

    if ($@ || !$res) {
        warn $@ and return undef;
    }

    if ($res->success) {
        print "Added photo $photo_id to set '$set->{title}' ($set->{id})\n";
    } else {
        my $msg = $res->{error_message};
        if ($msg !~ /Photo already in set/i) {
            # Log unexpected errors as warnings
            warn "Error adding photo '$photo_id' to set '$set->{title}': $msg";
        } else {
            # Log 'already in set' as a status message
            print "Photo '$photo_id' already in set '$set->{title}'.";
        }
        return;
    }

}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------

GetOptions(
    'length|l=i' => \$length,
    'set|s=s'    => \$set_spec,
    'help|h'     => \$help,
) or usage();

usage() if $help;
usage() unless defined $length && $length >= 0;

my $selected_set = resolve_photoset($set_spec);

my ($page, $pages) = (1, 1);

while ($page <= $pages) {
    my $res = flickrapicall('flickr.photos.search', {
        user_id => $user_nsid,
        per_page => 500,
        page     => $page,
        extras   => 'title,description,owner',
    });

    my $photos = $res->{photos}->{photo} || [];
    $photos = [$photos] unless ref($photos) eq 'ARRAY';

    $pages = $res->{photos}->{pages} || 1;

    for my $p (@$photos) {
        my $id    = $p->{id};
        my $title = $p->{title};
        my $desc  = get_description_text($p);

        next if contains_other_names_block($desc);
        next unless length($desc) > $length;

        my $len = length($desc);

        # Dry-run mode
        if (!defined $set_spec || !length $set_spec) {
            print "$len chars in photo: $title ($id),\n";
            next;
        }

        # Action mode
        my $set_obj = $selected_set;

        if ($set_spec !~ /^\d+$/ && (!$set_obj || !$set_obj->{id})) {
            $set_obj = check_or_create_photoset($set_spec, $id);
            $selected_set = $set_obj if $set_obj;
        }

        add_photo_to_set($id, $set_obj);
    }

    $page++;
}

exit 0;