use strict;
use warnings;
use FindBin qw($RealBin $Script);
use Test::More;
use Test::Deep;
use JSON;
use File::Temp qw/ tempfile /;

my $json = JSON->new->utf8->pretty;

# find the script to test with the same name as this script test
my $script_name = "$RealBin/../$Script";
$script_name =~ s/\.t$/.pl/;
ok(-e $script_name, "script $script_name exists");

# create temporary files for testing
my ($tag_fh, $tag_file) = tempfile();
print $tag_fh "Tag1\nTag3\nTag4\n";
close $tag_fh;

my ($json_fh, $json_file) = tempfile();
print $json_fh encode_json([
    {
        'id' => 1,
        'name' => 'Product A',
        'category' => 'Tag1'
    },
    {
        'id' => 2,
        'name' => 'Product B',
        'category' => 'Tag2'
    },
    {
        'id' => 3,
        'name' => 'Product C',
        'category' => 'Tag3'
    }
]);
close $json_fh;

# test the usage function
{
    my $output = `$script_name --help`;
    like($output, qr/Usage:/, 'usage message should be displayed');
}

# test the filter functionality
{
    my $key_name = 'category';

    my $expected_output = `$script_name $tag_file $json_file $key_name`;

    my $filtered_data = [
        {
            'id' => 1,
            'name' => 'Product A',
            'category' => 'Tag1'
        },
        {
            'id' => 3,
            'name' => 'Product C',
            'category' => 'Tag3'
        }
    ];

    cmp_deeply($json->decode($expected_output), $filtered_data, 'filtered data should match expected output');
}

# delete the temporary files
unlink $tag_file;
unlink $json_file;

done_testing();
