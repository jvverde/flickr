#!/usr/bin/perl
use strict;
use warnings;
use Test::More;

# Distance calculation function
sub calculate_distance_range {
    my ($distance, $labels) = @_;
    my $index = int($distance / 10);
    $index = $#{$labels} if $index > $#{$labels};  # Clamp to max index
    return $labels->[$index];
}

# Distance labels
my @distance_labels = (
    "0-10", "10-20", "20-30", "30-40", "40-50", "50 or more"
);

# Test cases
is(calculate_distance_range(5, \@distance_labels), "0-10", 'Distance 5 in range 0-10');
is(calculate_distance_range(15, \@distance_labels), "10-20", 'Distance 15 in range 10-20');
is(calculate_distance_range(55, \@distance_labels), "50 or more", 'Distance 55 clamped to max range');

done_testing();
