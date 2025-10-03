#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use LWP::Simple;
use CAM::PDF;
use JSON::PP;
binmode STDOUT, ":encoding(UTF-8)";

# URL do PDF
my $url = "https://ec.europa.eu/translation/portuguese/magazine/documents/folha66_separata1_pt.pdf";

# Nome local para guardar o PDF
my $pdf_file = "folha66_separata1_pt.pdf";

# Baixar o PDF
print "A baixar PDF...\n";
getstore($url, $pdf_file) == 200
    or die "Falha ao baixar $url\n";

# Abrir PDF
my $pdf = CAM::PDF->new($pdf_file) or die "Não consegui abrir $pdf_file\n";

my (%ordens, %familias);

# Regex para ordens e famílias
my $ordem_regex   = qr/^Ordem\s+([A-Za-z]+)\s+([a-záéíóúãõç]+)$/i;
my $familia_regex = qr/^Família\s+([A-Za-z]+)\s+([a-záéíóúãõç]+)$/i;

# Iterar páginas
for my $page_num (1 .. $pdf->numPages) {
    my $text = $pdf->getPageText($page_num);
    for my $line (split /\n/, $text) {
        $line =~ s/^\s+|\s+$//g;  # trim
        if ($line =~ $ordem_regex) {
            my ($sci, $pt) = ($1, $2);
            $ordens{$sci} = $pt;
        }
        if ($line =~ $familia_regex) {
            my ($sci, $pt) = ($1, $2);
            $familias{$sci} = $pt;
        }
    }
}

# Criar JSON final
my %result = (
    ordens   => \%ordens,
    familias => \%familias,
);

print encode_json(\%result), "\n";
