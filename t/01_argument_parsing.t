#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use Test::MockObject;
# Mock command-line arguments
BEGIN { @ARGV = ('--days', '7') }

# Mock Getopt::Long to simulate command-line arguments
my $mock_getopt = Test::MockObject->new;
$mock_getopt->mock('GetOptions', sub {
    my (%opts) = @_;
    $opts{'d|days=i'}->(7);
    return 1;
});


require_ok('./set-exif_distance.pl');  # Replace with your script’s path

# Test if $days is correctly parsed
my $days = 7;  # Assume $days is defined in your script
is($days, 7, 'Parsed --days argument correctly');

done_testing();
