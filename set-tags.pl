#!/usr/bin/perl
use strict;
use warnings;
use Getopt::Long;
use Flickr::API;
use Data::Dumper;
use JSON;
use Time::Local;
use URI::Escape;
binmode(STDOUT, ':utf8');

$\ = "\n";
$, = ", ";
my $json = JSON->new->utf8;

# Import Flickr API configuration
my $config_file = "$ENV{HOME}/saved-flickr.st";
my $flickr = Flickr::API->import_storable_config($config_file);

# Usage subroutine to print help message
sub usage {
    print "Usage:\n";
    print "  $0 --file jsonfile --key keyname --tag tagkey1 [--tag tagkey2 ...]\n";
    print "  $0 -f jsonfile -k keyname -t tagkey1 [--t tagkey2 ...]\n";
    exit;
}

# Parse command line arguments
my ($file_name, $key_name, @tag_keys, $match, $list);
my $rev = undef;
my $days = undef;  # Option for number of days
GetOptions(
    "f|file=s" => \$file_name,
    "k|key=s" => \$key_name,
    "t|tag=s" => \@tag_keys,
    "r|reverse" => \$rev,
    "m|match=s" => \$match,
    "l|list=s" => \$list,
    "d|days=i" => \$days,  # Capture the days option
    "h|help" => \&usage
);

usage() unless $file_name && $key_name && @tag_keys;

# Read the data from json file
my $json_text = do {
    open(my $json_fh, "<", $file_name)
        or die("Can't open $file_name: $!");
    local $/;
    <$json_fh>
};

# Parse the JSON text to a Perl data structure
my $data = $json->decode($json_text);
$data = [reverse @$data] if defined $rev;

# Function to convert a tag to Flickr's canonical form
sub canonicalize_tag {
    my $tag = shift;
    #$tag =~ s/[^a-z0-9]/_/gi;      # Replace non-alphanumeric characters with underscores
    $tag =~ s/[^a-z0-9:]//gi;
    $tag = lc($tag);                # Convert to lowercase
    return $tag;
}

# Calculate the minimum upload date if the days option is provided
my $min_upload_date = undef;
if (defined $days) {
    my $time = time - ($days * 24 * 60 * 60);  # Convert days to seconds and subtract from the current time
    $min_upload_date = $time;  # Unix timestamp for min_upload_date

    # If the days option is provided, pre-fetch all photos uploaded in the last $days
    my %valid_tags;
    my $page = 0;
    my $pages = 1;
    
    while (++$page <= $pages) {
        my $response = $flickr->execute_method('flickr.photos.search', {
            user_id => 'me',
            min_upload_date => $min_upload_date,
            per_page => 500,
            page => $page,
            extras => 'tags',
        });

        warn "Error retrieving photos: $response->{error_message}\n\n" and last unless $response->{success};

        my $photos = $response->as_hash()->{photos}->{photo} // next; #next unless $photos;
        $photos = [ $photos ] unless ref $photos eq 'ARRAY';  # Handle the case where there is only 1 photo

        # Collect all unique raw tags from the photos
        foreach my $photo (@$photos) {
            my @tags = split ' ', $photo->{tags};  # Split tags by spaces
            $valid_tags{$_} = 1 for @tags;
        }

        $pages = $response->as_hash()->{photos}->{pages};
        #$page++;
    }

    # Filter @$data array if the key of each element is not one of the raw tags (converted to canonical form)
    @$data = grep { exists $valid_tags{ canonicalize_tag($_->{$key_name}) } } @$data;
}
# Loop through each hash in the filtered array
foreach my $hash (@$data) {
    my $key_value = $hash->{$key_name};
    next if $match && $key_value !~ m/\Q$match\E/i;

    # Search for photos with the key value and add tags to them
    my %search_params = (
        user_id => 'me',
        tags => $key_value,
        per_page => 500,
        page => 1,
    );
    
    # Include min_upload_date if days option is provided
    $search_params{min_upload_date} = $min_upload_date if defined $min_upload_date;

    my $response = $flickr->execute_method('flickr.photos.search', \%search_params);
    warn "Error retrieving photos: $response->{error_message}\n\n" and next unless $response->{success};

    my $photos = $response->as_hash()->{photos}->{photo};
    $photos = [ $photos ] unless ref $photos eq 'ARRAY';  # Just in case for a limit situation when there is only 1 photo

    foreach my $photo (@$photos) {
        print qq|No photos with tag $key_value|, Dumper($photo) and next unless $photo->{id};
        my @newtags = grep { $_ } @$hash{@tag_keys};
        my $tags = join ' ', map { qq|"$_"| } @newtags;
        if (defined $list) {
            $tags = join ' ', $tags, $list,
            qq|$list:seq="$hash->{'Seq.'}"|,
            qq|$list:binomial="$hash->{'species'}"|, 
            qq|$list:name="$hash->{'English'}"|;
        }
        my $response = $flickr->execute_method('flickr.photos.addTags', {
            photo_id => $photo->{id},
            tags => $tags
        });
        warn "Error while trying to set new tags ($tags) to '$photo->{title}': $response->{error_message}\n\n" and next unless $response->{success};
        print "Done new tag $tags on '$photo->{title}'";    
    }
}
