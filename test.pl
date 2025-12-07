#!/usr/bin/env perl
use strict;
use warnings;

# Define o comando de filtro usando q|...| para evitar problemas de escaping
my $filter_cmd = 'perl -pe "use POSIX qw(strftime); print strftime(q|[%Y-%m-%d %H:%M:%S] |, localtime())"';

# Redireciona o STDOUT para o comando de filtro
open(STDOUT, "|-", $filter_cmd) 
    or die "Falha ao abrir o pipe para o filtro: $!";

# Desativa o buffering do STDOUT (muito importante em pipes)
$| = 1; 

END {
    close(STDOUT) or warn "Falha ao fechar STDOUT (Pipe): $!";         
}

# O resto do seu script...
print "Isto tem timestamp.\n";
print "FIM\n";