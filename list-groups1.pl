#!/usr/bin/perl
# flickr_group_posting_info_json.pl
#
# Fetch all Flickr groups where the authenticated user can post photos,
# and output posting/restriction info as JSON.
#
# Usage:
#   perl flickr_group_posting_info_json.pl [--out <file>] [-d] [-p <pattern>]
#
# Options:
#   -h, --help          Show this help message and exit
#   -o, --out <file>    Write JSON output to specified file (default: stdout)
#   -d, --debug         Enable debug mode (prints diagnostic info to stderr)
#   -p, --pattern <reg> Regular expression to mark group as 'especial' (can be repeated)
#
# Requires: Flickr::API, Getopt::Long, JSON, Data::Dumper

use strict;
use warnings;
use utf8;
use open qw(:std :utf8);    # All input/output is UTF-8 by default
use Getopt::Long;
use Flickr::API;
use Data::Dumper;
use JSON;

$\ = "\n";  # newline output separator
my ($help, $debug, $outfile);
# New variable to hold the patterns
my @patterns;

GetOptions(
    'h|help'    => \$help,
    'd|debug:i' => \$debug,
    'o|out=s'   => \$outfile,
    'p|pattern=s' => \@patterns, # Use an array ref to capture multiple instances
);

if ($help) {
    print <<"USAGE";
Usage: $0 [OPTIONS]
  -h, --help          Show this help message and exit
  -o, --out <file>    Write JSON output to specified file (default: stdout)
  -d, --debug         Enable debug output (prints to stderr)
  -p, --pattern <reg> Regular expression to mark group as 'especial' (can be repeated)
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
# Check changed to 'defined $debug'
warn "Debug: Logged in as $user_nsid\n" if defined $debug;

# Pre-compile the patterns for efficiency and handle case-insensitivity
my @compiled_patterns;
warn "Debug: Using patterns: " . join(", ", @patterns) . "\n" if defined $debug and @patterns;
foreach my $p (@patterns) {
    # Store original pattern and compiled regex capturing the match
    push @compiled_patterns, { 
        original => $p, 
        regex => qr/($p)/i 
    };
}

# Fetch all groups where user can post
my $groups_response = $flickr->execute_method('flickr.groups.pools.getGroups', {});
die "Error fetching pool groups: $groups_response->{error_message}" unless $groups_response->{success};

# Check changed to 'defined $debug && $debug > 2'
warn Dumper($groups_response->as_hash) if defined $debug && $debug > 2;

my $groups = $groups_response->as_hash->{groups}->{group} || [];
$groups = [ $groups ] unless ref $groups eq 'ARRAY';

if (!@$groups) {
    print encode_json({ groups => [], message => "No groups found." });
    exit;
}

# Check changed to 'defined $debug'
warn "Debug: Found " . scalar(@$groups) . " groups.\n" if defined $debug;

my @results;

# Get the current time once outside the loop for consistency across entries
my $timestamp_epoch = time();
my $timestamp_human = scalar(localtime($timestamp_epoch));

foreach my $g (@$groups) {
    my $gid   = $g->{nsid};
    my $gname = $g->{name};

    my $info = $flickr->execute_method('flickr.groups.getInfo', { group_id => $gid });
    unless ($info->{success}) {
        warn "Error fetching info for $gname ($gid): $info->{error_message}\n";
        next;
    }
    # Check changed to 'defined $debug && $debug > 1'
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
    
    # Variables for especial tracking
    my $is_especial = 0;
    my $matched_pattern = undef;
    my $matched_substring = undef;
    
    # Check for 'especial' pattern match (loop handles empty array gracefully)
    foreach my $p_ref (@compiled_patterns) {
        # Check for a match using the compiled regex
        if ($gname =~ $p_ref->{regex}) {
            $is_especial = 1;
            $matched_pattern = $p_ref->{original};
            # The captured substring is automatically in $1 
            $matched_substring = $1; 
            last; # Stop on the first match
        }
    }
    # Check changed to 'defined $debug'
    warn "Debug: Group '$gname' is especial (Pattern: $matched_pattern, Substring: $matched_substring).\n" if defined $debug && $is_especial;

    my $entry = {
        # --- Timestamp fields added here ---
        timestamp_epoch => $timestamp_epoch,
        timestamp_human => $timestamp_human,
        # -----------------------------------
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
        # Use conditional hash slice to add fields only if a match occurred
        ( $is_especial ? (
            especial        => $is_especial, 
            matched_pattern => $matched_pattern,
            matched_substring => $matched_substring,
        ) : () ), 
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