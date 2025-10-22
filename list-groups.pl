#!/usr/bin/perl
# flickr_group_posting_info_json.pl
#
# Fetch all Flickr groups where the authenticated user can post photos,
# and output posting/restriction info as JSON.
#
# Usage:
#   perl flickr_group_posting_info_json.pl [--out <file>] [-d]
#
# Options:
#   -h, --help          Show this help message and exit
#   -o, --out <file>    Write JSON output to specified file (default: stdout)
#   -d, --debug         Enable debug mode (prints diagnostic info to stderr)
#
# Requires: Flickr::API, Getopt::Long, JSON, Data::Dumper

use strict;
use warnings;
use utf8;
use open qw(:std :utf8);   # All input/output is UTF-8 by default
use Getopt::Long;
use Flickr::API;
use Data::Dumper;
use JSON;

$\ = "\n";  # newline output separator
my ($help, $debug, $outfile);

GetOptions(
    'h|help'    => \$help,
    'd|debug:i' => \$debug,
    'o|out=s'   => \$outfile,
);

if ($help) {
    print <<"USAGE";
Usage: $0 [OPTIONS]
  -h, --help          Show this help message and exit
  -o, --out <file>    Write JSON output to specified file (default: stdout)
  -d, --debug         Enable debug output (prints to stderr)
USAGE
    exit;
}

# Load Flickr API config
my $config_file = "$ENV{HOME}/saved-flickr.st";
my $flickr = Flickr::API->import_storable_config($config_file);

# Verify authentication
my $login_response = $flickr->execute_method('flickr.test.login');
die "Error logging in: $login_response->{error_message}" unless $login_response->{success};
my $user_nsid = $login_response->as_hash->{user}->{id};
warn "Debug: Logged in as $user_nsid\n" if $debug;

# Fetch all groups where user can post
my $groups_response = $flickr->execute_method('flickr.groups.pools.getGroups', {});
die "Error fetching pool groups: $groups_response->{error_message}" unless $groups_response->{success};

warn Dumper($groups_response->as_hash) if defined $debug && $debug > 2;

my $groups = $groups_response->as_hash->{groups}->{group} || [];
$groups = [ $groups ] unless ref $groups eq 'ARRAY';

if (!@$groups) {
    print encode_json({ groups => [], message => "No groups found." });
    exit;
}

warn "Debug: Found " . scalar(@$groups) . " groups.\n" if $debug;

my @results;

foreach my $g (@$groups) {
    my $gid   = $g->{nsid};
    my $gname = $g->{name};

    my $info = $flickr->execute_method('flickr.groups.getInfo', { group_id => $gid });
    unless ($info->{success}) {
        warn "Error fetching info for $gname ($gid): $info->{error_message}\n";
        next;
    }
    warn Dumper($info->as_hash) if defined $debug && $debug > 1;

    my $data = $info->as_hash->{group};

    my $privacy_code = $g->{privacy} // 3;
    my $privacy = {
        1 => 'Private',
        2 => 'Public (invite to join)',
        3 => 'Public (open)',
    }->{$privacy_code} || "Unknown";

    my $throttle = $data->{throttle} || {};
    my $limit_mode = $throttle->{mode} // 'none';
    my $limit_count = $throttle->{count} // 0;
    my $remaining = $throttle->{remaining} // 0;

    my $entry = {
        id            => $gid,
        name          => $gname,
        privacy       => $privacy,
        photos_ok     => 0 | $data->{restrictions}->{photos_ok} // 1,
        moderated     => 0 | $data->{ispoolmoderated} // 0,
        limit_mode    => $limit_mode,
        limit_count   => $limit_count + 0,
        remaining     => $remaining + 0,
        can_post      => (($data->{restrictions}->{photos_ok} // 1)
                           && ($limit_mode eq 'none' || $remaining > 0)) ? 1 : 0,
        role          => $g->{admin} ? "admin" : $g->{moderator} ? "moderator" : "member",
    };

    my $desc = $data->{description} // '';
    if ($desc =~ /invit(?:e|ation)\s*only/i || $desc =~ /do\s*not\s*add/i) {
        $entry->{note} = "Invitation only (based on description)";
    }

    push @results, $entry;
}

my $json = JSON->new->utf8->pretty->encode({ groups => \@results });

if ($outfile) {
    open my $fh, '>:encoding(UTF-8)', $outfile or die "Cannot write to $outfile: $!";
    print $fh $json;
    close $fh;
    print "Output written to $outfile";
} else {
    print $json;
}

exit 0;
