#!/usr/bin/perl
# This script finds Flickr photo sets where the title contains a scientific bird
# family name (ending in 'idae') and formats it as 'Scientific Name (Portuguese Name)'.
# It applies the change ONLY if the Portuguese name from the JSON map ends in 'ídeos'.
#
# The path to the JSON map file must be provided as the first positional argument.
#
# Usage: $0 [-h|--help] [-n|--dry-run] <path/to/map.json>
#
# JSON format example (map.json):
# {
#    "Motacillidae": "Alvéolas e Petinhas",
#    "Tinamidae": "Inambus e macucões",
#    "Rheidae": "reídeos" <-- SERÁ CAPITALIZADO PARA "Reídeos"
# }

use strict;
use warnings;
use utf8;       # NECESSÁRIO para que o Perl interprete o literal 'ídeos' como UTF-8
use Getopt::Long;
use Flickr::API;
use JSON;

$\ = "\n"; # Define o separador de registro de saída para nova linha

# Declare variáveis para opções de linha de comando
my ($help, $dry_run);

# 1. Processar Flags
# GetOptions processa e remove as flags encontradas de @ARGV
GetOptions(
    'h|help' => \$help,
    'n|dry-run' => \$dry_run,
) or die "Erro nos argumentos de linha de comando.\n";

# 2. Atribuir o Primeiro Argumento Posicional restante a $map_file
my $map_file = shift @ARGV;

# Se a flag de ajuda estiver definida ou o arquivo de mapeamento estiver faltando
if ($help || !$map_file) {
    # Melhoria na apresentação do USAGE
    print <<"END_USAGE";
    Descrição:
        Este script encontra e atualiza títulos de sets de fotos do Flickr que contêm
        um nome de família científica (terminado em 'idae').

        A alteração (reformatar para 'Nome Científico (Nome em Português)') é aplicada
        APENAS se o Nome em Português, conforme mapeado no JSON, terminar em 'ídeos'.

    Uso:
        $0 [-h|--help] [-n|--dry-run] <caminho/para/map.json>

        Opções:
          -h, --help    Exibe esta mensagem de ajuda e sai.
          -n, --dry-run Simula as alterações sem as aplicar no Flickr.

    Exemplo:
        $0 -n ./bird_families.json
END_USAGE
    exit;
}

# ---
## ⚙️ Carregar Mapeamento JSON
# ---

my $json_text;
eval {
    # Ler o arquivo como bytes brutos. O módulo JSON fará a decodificação de bytes para Unicode.
    local $/;
    open my $fh, '<', $map_file or die "Não foi possível abrir o arquivo JSON '$map_file': $!";
    $json_text = <$fh>;
    close $fh;
};
die "Erro ao ler o arquivo JSON: $@" if $@;

my $family_map;
eval {
    $family_map = decode_json($json_text);
};
die "Erro ao analisar dados JSON: $@. Verifique o formato do arquivo." if $@;

# ---
## 🌐 Configuração e Execução do Flickr
# ---

my $config_file = "$ENV{HOME}/saved-flickr.st";
my $per_page = 500;
my $page = 1;
my $total_pages = 1;
my $flickr = Flickr::API->import_storable_config($config_file);
die "Não foi possível inicializar a API do Flickr. Verifique o arquivo de configuração: $config_file" unless $flickr;

print $dry_run ? "**Modo Dry-Run Ativo:** Nenhuma alteração será feita." : "**Alterações serão APLICADAS.**";
print "Processando sets do Flickr...";

# PADRÃO IDAE: foca no final do título.
# ([A-Z][a-z]+idae): Captura o Nome Científico em $1
# \s*(?:\(.*\))?: Corresponde opcionalmente a espaços, parênteses e seu conteúdo
# \s*$: Corresponde a espaços finais até o fim da string
my $pattern = '([A-Z][a-z]+idae)\s*(?:\(.*\))?\s*$';

# Loop através das páginas de sets do Flickr
while ($page <= $total_pages) {
    my $response = $flickr->execute_method('flickr.photosets.getList', {
        per_page => $per_page,
        page => $page,
    });

    unless ($response->{success}) {
        warn "Erro ao buscar sets na página $page: $response->{error_message}";
        sleep 1;
        redo;
    }

    my $sets = $response->as_hash->{photosets}->{photoset};
    $sets = [ $sets ] unless ref $sets eq 'ARRAY';

    # Processa cada set
    for my $set (@$sets) {
        my $title = $set->{title};
        my $scientific_name;

        # Tenta corresponder ao padrão 'idae'
        if ($title =~ /$pattern/) {
            $scientific_name = $1;
        }

        # 1. Verifica se o nome científico foi encontrado e se está no mapa JSON
        my $portuguese_name = $scientific_name ? $family_map->{$scientific_name} : undef;

        if ($scientific_name && $portuguese_name) {
            
            # --- VALIDAÇÃO: Verifica se o nome em português termina em 'ídeos' ---
            # O /ídeos$/i é seguro devido ao 'use utf8' no início do script.
            if ($portuguese_name !~ /ídeos$/i) {
                # O nome em português NÃO termina em 'ídeos'. Emite um warning e pula.
                warn "Set '$title' (ID $set->{id}): Nome em português '$portuguese_name' para $scientific_name NÃO termina em 'ídeos'. Pulando alteração.";
                next;
            }
            
            # --- MELHORIA: Capitaliza a primeira letra do nome em português ---
            # Garante que 'reídeos' se torne 'Reídeos' (o \u funciona graças ao 'use utf8').
            $portuguese_name =~ s/^(\S)/\u$1/;
            # --------------------------------------------------------------------
            
            # 2. Constrói o novo título
            
            # Remove a parte da família (com ou sem parênteses) do final do título original para obter o prefixo.
            (my $original_prefix = $title) =~ s/$pattern//;
            $original_prefix =~ s/\s+$//; # Remove espaços à direita do prefixo
            
            # Constrói o novo título: (Prefixo) NomeCientífico (Nome em Português)
            my $new_title = ($original_prefix ? "$original_prefix " : "") . "$scientific_name ($portuguese_name)";
            
            # Evita atualizar se o título já estiver na formatação correta
            unless ($new_title eq $title) {
                
                # --- Lógica de Atualização ---
                if ($dry_run) {
                    print "Dry-run: Set ID $set->{id}: Mudaria título '$title' para '$new_title'";
                } else {
                    my $update_response = $flickr->execute_method('flickr.photosets.editMeta', {
                        photoset_id => $set->{id},
                        title => $new_title,
                        description => $set->{description} || '',
                    });
                    
                    unless ($update_response->{success}) {
                        warn "Erro ao atualizar set '$title' (ID $set->{id}): $update_response->{error_message}";
                        sleep 1;
                        next;
                    }
                    print "Set ID $set->{id}: Título alterado de '$title' para '$new_title'";
                }
                # --- Fim Lógica de Atualização ---
            }
        }
    }

    $total_pages = $response->as_hash->{photosets}->{pages} || 1;
    print "Página $page de $total_pages processada." if $total_pages > 1;
    $page++;
}

print "Processamento de todos os sets concluído.";
