#!/usr/bin/perl
use strict;
use warnings;
use Data::Dumper;
use JSON;
use Flickr::API;

$\ = "\n";

# Read the key from command line arguments
sub usage {
    print "Usage: $0 <json file>\n";
    exit 1;
}

usage() unless @ARGV == 1;

my $json_file = shift;

# Read the JSON file with the array of tags
my $json_text = do { local $/; open my $fh, '<', $json_file or die "Cannot open $json_file: $!"; <$fh> };
my $json = JSON->new->utf8;
my $tag_list = $json->decode($json_text);

# Read the config file to connect to Flickr
my $config_file = "$ENV{HOME}/saved-flickr.st";
my $flickr = Flickr::API->import_storable_config($config_file);

# Divide the tag list into chunks of 20 tags or fewer
my @tag_chunks = ();
my $chunk = [];
my %tags_map;

foreach my $tag (@{$tag_list}) {
    if (@{$chunk} >= 20) {
        push @tag_chunks, $chunk;
        $chunk = [];
    }
    push @{$chunk}, $tag;
    $tag = lc $tag;
    $tag =~ s/\s//g;
    $tags_map{$tag} = 0;
}
if (@{$chunk} > 0) {
    push @tag_chunks, $chunk;
}

# Search for photos with multiple tags from the list
my %photos_map;

foreach my $tag_chunk (@tag_chunks) {
    my $page = 1;
    while (1) {
        my $result = $flickr->execute_method('flickr.photos.search', {
            user_id => 'me',
            tags => join(',', @{$tag_chunk}),
            tag_mode => 'any',
            page => $page,
            per_page => 500,
            extras => 'tags,url_n',
        });
        last unless $result->is_success;
        my $response = $result->as_hash();
        my $photos = $response->{photos}->{photo};
        $photos = [ $photos ] unless 'ARRAY' eq ref $photos;
        foreach my $photo (grep { $_->{id} } @{$photos}) {
            #print Dumper $photo;
            my @tags = grep { exists $tags_map{$_} } split ' ', $photo->{'tags'};
            #print Dumper \@tags;
            my $photo_id = $photo->{id};
            my $owner = $photo->{owner};
            my $photo_url = qq|https://www.flickr.com/photos/$owner/$photo_id/|;
            my $title = $photo->{title};

            foreach my $tag (@tags) {
                $photos_map{$photo_id} //= {
                    id => $photo_id,
                    url => $photo_url,
                    title => $title,
                    tags => []
                };
                push @{$photos_map{$photo_id}->{tags}}, $tag;
            }
            #remove duplicated tags;
            my %seen;
            $photos_map{$photo_id}->{tags} = [ grep { !$seen{$_}++ } @{$photos_map{$photo_id}->{tags}} ];
            #print Dumper $photos_map{$photo_id} if @{$photos_map{$photo_id}->{tags}} > 1;
        }    
        last if $page >= $response->{photos}->{pages};
        $page++;
    }
}

# Print the list of photos with URLs and matched tags
#print Dumper \%photos_map;

my @dups = grep { @{$_->{tags}} > 1 } values %photos_map;
my %results;
foreach my $dup (@dups) {
    my $k = join '', sort @{$dup->{tags}};
    $results{$k} //= {
        tags => $dup->{tags},
        photos => []
    };
    push @{$results{$k}->{photos}}, { $dup->{title} => $dup->{url} }
}

print Dumper \%results;
