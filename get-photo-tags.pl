use strict;
use warnings;
use Flickr::API;
use File::Slurp;
use Data::Dumper;
binmode(STDOUT, ':utf8');

$\ = "\n";

sub usage {
    print "This script removes tags from the current user's photos.";
    print "Usage: $0 photo_id";
    exit;
}

my $config_file = "$ENV{HOME}/saved-flickr.st";
my $flickr = Flickr::API->import_storable_config($config_file);

# Get the filename argument from the command line
my $photo_id = shift @ARGV;
die "No photo id provided.\n" unless $photo_id;

my $response = $flickr->execute_method('flickr.tags.getListPhoto', { photo_id => $photo_id });

die "Error retrieving tags for $photo_id: $response->{error_message}\n" unless $response->{success};

my $data = $response->as_hash();

die 'No data retrived' unless defined $data && defined $data->{photo};

die 'No tags found' unless defined $data->{photo}->{tags};

my $tags = $data->{photo}->{tags}->{tag};
$tags = [$tags] if 'ARRAY' ne ref $tags;

print $_->{content} foreach (@$tags);
