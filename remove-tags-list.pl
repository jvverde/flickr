use strict;
use warnings;
use Getopt::Long;
use Flickr::API;
use File::Slurp;
use Data::Dumper;
binmode(STDOUT, ':utf8');

$\ = "\n";

sub usage {
    print "This script removes tags from the current user's photos.";
    print "Usage: $0 [OPTIONS] FILENAME";
    print "Options:";
    print "  -h, --help    Show this help message and exit";
    print "FILENAME must contains a list of RAW tags to remove";
    print "\nNOTE: It assumes the user's tokens are initialized in the file '$ENV{HOME}/saved-flickr.st'";
    exit;
}

GetOptions(
    'h|help' => \&usage
);

my $config_file = "$ENV{HOME}/saved-flickr.st";
my $flickr = Flickr::API->import_storable_config($config_file);

# Get the filename argument from the command line
my $filename = shift @ARGV;
die "No filename provided.\n" unless $filename;
die "File not found: $filename\n" unless -e $filename;

# Read the list of tags from the file
my @alltags = read_file($filename, chomp => 1, binmode => ':utf8');


foreach my $tag (reverse @alltags) {
    my $response = $flickr->execute_method('flickr.photos.search', {
        user_id => 'me',
        tags => $tag,
        per_page => 500,
        page => 1
    });

    warn "Error retrieving photos: $response->{error_message}\n\n" and next unless $response->{success};

    my $data = $response->as_hash();

    warn "No data in answer for tag $tag" and next unless defined $data && defined $data->{photos};

    my $photos = $data->{photos}->{photo};
    next unless defined $photos;

    $photos = [$photos] if 'ARRAY' ne ref $photos;
    my @ids = grep { $_ } map { $_->{id} } @$photos;

    foreach my $id (@ids) {
        my $response = $flickr->execute_method('flickr.tags.getListPhoto', { photo_id => $id });

        warn "Error retrieving tags for photo $id ($tag): $response->{error_message}\n" and next unless $response->{success};

        my $data = $response->as_hash();

        next unless defined $data && defined $data->{photo};

        my $tags = $data->{photo}->{tags}->{tag};
        $tags = [$tags] if 'ARRAY' ne ref $tags;
        my @phototags = grep {$_->{content} && $_->{content} eq $tag } @$tags;
        foreach my $phototag (@phototags) {
            print "I am ready to remove $phototag->{content} with id $phototag->{id}";
            my $response = $flickr->execute_method('flickr.photos.removeTag', { tag_id => $phototag->{id} });
            next if $response->{success};
            print "Error removing tag: $response->{error_message}";
        }
    }
}
