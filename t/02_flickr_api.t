#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use Test::MockObject;

# Mock Flickr::API
my $mock_flickr = Test::MockObject->new;
$mock_flickr->mock(
    'execute_method',
    sub {
        my ($self, $method, $params) = @_;
        if ($method eq 'flickr.photos.search') {
            return bless {
                success => 1,
                as_hash => sub {
                    return { photos => { photo => [ { id => '12345' } ], pages => 1 } };
                },
            }, 'MockResponse';
        }
        elsif ($method eq 'flickr.photos.getExif') {
            return bless {
                success => 1,
                as_hash => sub {
                    return {
                        photo => {
                            exif => [
                                { label => 'Subject Distance', raw => '15 m' },
                            ],
                        },
                    };
                },
            }, 'MockResponse';
        }
        elsif ($method eq 'flickr.photos.addTags') {
            return bless { success => 1 }, 'MockResponse';
        }
        return bless { success => 0, error_message => 'API error' }, 'MockResponse';
    }
);

# MockResponse class definition
{
    package MockResponse;
    sub as_hash {
        my $self = shift;
        return $self->{as_hash}->();
    }
}

# Test Flickr API mock
my $response = $mock_flickr->execute_method('flickr.photos.search', {});
ok($response->{success}, 'Flickr search API success');

my $exif_response = $mock_flickr->execute_method('flickr.photos.getExif', { photo_id => '12345' });
ok($exif_response->{success}, 'Flickr EXIF API success');

my $exif_data = $exif_response->as_hash()->{photo}->{exif};
is($exif_data->[0]->{raw}, '15 m', 'Subject Distance EXIF parsed correctly');

done_testing();
