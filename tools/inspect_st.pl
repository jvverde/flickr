#!/usr/bin/perl

# Este script lê e exibe o conteúdo de um arquivo Storable para inspeção

use strict;
use warnings;
use Storable qw(retrieve);
use Data::Dumper;
use File::Spec;
binmode(STDOUT, ':utf8');

# Define o caminho do arquivo de entrada
my $input_file = File::Spec->catfile($ENV{HOME} || $ENV{USERPROFILE}, 'saved-flickr.st');

# Verifica se o arquivo existe
unless (-e $input_file) {
    die "Error: Input file '$input_file' does not exist!\n";
}

# Lê o arquivo Storable
my $config;
eval {
    $config = retrieve($input_file);
};
if ($@) {
    die "Error: Failed to read Storable file '$input_file': $@\n";
}

# Exibe a estrutura do arquivo
print "Conteúdo do arquivo '$input_file':\n";
print Dumper($config);