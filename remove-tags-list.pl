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

    die "Error retrieving photos: $response->{error_message}\n\n" unless $response->{success};

    next unless defined $response->as_hash() && defined $response->as_hash()->{photos} && ref $response->as_hash()->{photos}->{photo} eq 'ARRAY';

    my @ids = map { $_->{id} } @{$response->as_hash()->{photos}->{photo}};

    foreach my $id (@ids) {
        my $response = $flickr->execute_method('flickr.tags.getListPhoto', { photo_id => $id });
        #my $response = $flickr->execute_method('flickr.photos.getInfo', { photo_id => $id });
        next unless defined $response->as_hash() && defined $response->as_hash()->{photo} && ref $response->as_hash()->{photo}->{tags}->{tag} eq 'ARRAY';

        my @phototags = grep {$_->{content} && $_->{content} eq $tag } @{$response->as_hash()->{photo}->{tags}->{tag}};
        foreach my $phototag (@phototags) {
            print "I am ready to remove $phototag->{content} with id $phototag->{id}";
            my $response = $flickr->execute_method('flickr.photos.removeTag', { tag_id => $phototag->{id} });
            next if $response->{success};
            print "Error removing tag: $response->{error_message}";
        }
    }

    # print Dumper \@ids;
}
