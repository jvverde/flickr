#!/usr/bin/perl
use strict;
use warnings;
use JSON;

# Verificar se os argumentos foram fornecidos
die "Uso: perl script.pl <input.json>\n" unless @ARGV == 1;

# Ler o arquivo de entrada do argumento
my $input_file = $ARGV[0];
open my $fh, '<', $input_file or die "Não foi possível abrir o ficheiro $input_file: $!";
my $json_text = do { local $/; <$fh> };
close $fh;

# Parse do JSON
my $data = decode_json($json_text);

# Inicializar os contadores e valores anteriores
my ($last_family, $last_order) = (undef, undef);
my ($hex, $ord_no) = (0, 0);

# Processar os elementos
foreach my $item (@$data) {
    # Incrementar HEX se Family mudou
    if (!defined($last_family) || $item->{Family} ne $last_family) {
        $hex++;
    }
    # Incrementar Ord No se Order mudou
    if (!defined($last_order) || $item->{Order} ne $last_order) {
        $ord_no++;
    }

    # Atualizar os valores
    $item->{HEX} = sprintf("%02X", $hex);
    $item->{"Ord No"} = sprintf("%02X", $ord_no);
    $last_family = $item->{Family};
    $last_order = $item->{Order};
}

# Converter de volta para JSON e imprimir no stdout
print to_json($data, { pretty => 1 });
