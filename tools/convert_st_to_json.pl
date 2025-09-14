#!/usr/bin/perl

# Este script converte um arquivo de configuração Flickr no formato Storable (.st)
# para um arquivo JSON compatível com o script PowerShell.
# Ele extrai explicitamente as chaves consumer_key, consumer_secret, access_token->token
# e access_token->token_secret com base na estrutura fornecida do arquivo .st.

use strict;                # Enforce strict syntax checking for safer code
use warnings;              # Enable warnings for potential issues
use Storable qw(retrieve); # Module to deserialize Storable files
use JSON;                  # Module for JSON encoding
use File::Spec;            # Module for cross-platform file path handling
binmode(STDOUT, ':utf8');  # Set STDOUT to UTF-8 encoding for proper handling of international characters

# Define input and output file paths
my $input_file = File::Spec->catfile($ENV{HOME} || $ENV{USERPROFILE}, 'saved-flickr.st');
my $output_file = File::Spec->catfile($ENV{HOME} || $ENV{USERPROFILE}, 'flickr_config.json');

# Subroutine to print usage information and exit
sub usage {
    print <<'USAGE';
Usage:
  $0 [--input <storable_file>] [--output <json_file>]

  Converte um arquivo de configuração Flickr no formato Storable (.st) para JSON.

  Options:
    --input <storable_file>  : Path to the input Storable file (default: ~/saved-flickr.st)
    --output <json_file>     : Path to the output JSON file (default: ~/flickr_config.json)
    --help                   : Display this help message and exit

  Example:
    $0 --input ~/saved-flickr.st --output ~/flickr_config.json

  Notes:
    - Requires Perl modules: Storable, JSON, File::Spec.
    - The input .st file is expected to contain Flickr API configuration with keys
      consumer_key, consumer_secret, and access_token (containing token and token_secret fields).
    - The output JSON file will contain api_key, api_secret, auth_token, and token_secret
      in a format suitable for PowerShell.
USAGE
    exit;
}

# Parse command-line arguments
use Getopt::Long;
my $help;
GetOptions(
    'input=s'  => \$input_file,
    'output=s' => \$output_file,
    'help'     => \$help
);

# Show usage if --help is specified
usage() if $help;

# Verify that the input file exists
unless (-e $input_file) {
    die "Error: Input file '$input_file' does not exist!\n";
}

# Read the Storable file
my $config;
eval {
    $config = retrieve($input_file);
};
if ($@) {
    die "Error: Failed to read Storable file '$input_file': $@\n";
}

# Ensure the retrieved data is a hash reference
unless (ref($config) eq 'HASH') {
    die "Error: Storable file '$input_file' does not contain a hash structure!\n";
}

# Create a new hash with the required fields, mapping from the actual structure
my %json_config;
# Map consumer_key to api_key
if (exists $config->{consumer_key}) {
    $json_config{api_key} = $config->{consumer_key};
} else {
    warn "Warning: Key 'consumer_key' not found in Storable configuration.\n";
}

# Map consumer_secret to api_secret
if (exists $config->{consumer_secret}) {
    $json_config{api_secret} = $config->{consumer_secret};
} else {
    warn "Warning: Key 'consumer_secret' not found in Storable configuration.\n";
}

# Map access_token->{token} to auth_token
if (exists $config->{token}) {
    $json_config{auth_token} = $config->{token};
} else {
    warn "Warning: Key 'access_tokenn' not found in Storable configuration.\n";
}

# Map access_token->{token_secret} to token_secret
if (exists $config->{token_secret}) {
    $json_config{token_secret} = $config->{token_secret};
} else {
    warn "Warning: Key 'token_secret' not found in Storable configuration.\n";
}

# Check if we have at least one required key
unless (%json_config) {
    die "Error: No required keys (api_key, api_secret, auth_token, token_secret) found in Storable configuration!\n";
}

# Warn if any key is missing
foreach my $key (qw(api_key api_secret auth_token token_secret)) {
    unless (exists $json_config{$key}) {
        warn "Warning: Key '$key' not found in final JSON configuration.\n";
    }
}

# Create a JSON object with pretty printing and UTF-8 support
my $json = JSON->new->utf8->pretty;

# Convert the configuration to JSON
my $json_text;
eval {
    $json_text = $json->encode(\%json_config);
};
if ($@) {
    die "Error: Failed to encode configuration to JSON: $@\n";
}

# Write the JSON to the output file
open(my $fh, '>:encoding(UTF-8)', $output_file)
    or die "Error: Cannot open output file '$output_file' for writing: $!\n";
print $fh $json_text;
close($fh);

# Print success message
print "Successfully converted '$input_file' to '$output_file'\n";

# Print the JSON content for verification
print "\nContent of the generated JSON file:\n";
print $json_text;