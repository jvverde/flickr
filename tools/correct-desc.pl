#!/usr/bin/perl
use strict;
use warnings;
use Getopt::Long;
use Flickr::API;

# Script para corrigir descrições de sets do Flickr (v3 - usando qr// para regex):
# 1. EVITA processar sets onde o token 'orderNO:=...' JÁ ESTÁ NO FINAL.
# 2. Remove qualquer texto de referência HASH(0x...) que possa ter sido injetado.
# 3. Move a linha do token 'orderNO:=...' do início ou meio para o fim da descrição.

# A única string que usa aspas duplas é o separador de linha (\n)
$\ = "\n"; 
my ($help, $dry_run, $count, $match);
my $TOKEN_TO_FIX = 'orderNO'; # Assumindo que este é o token a corrigir

GetOptions(
    'h|help' => \$help,
    'n|dry-run' => \$dry_run,
    'c|count=i' => \$count,
    'm|match=s' => \$match,
);

if ($help) {
    # Usar print <<'END_HELP' garante que o conteúdo é tratado como literal (sem interpolação)
    print <<'END_HELP';
flickr_correct_sets.pl - Corrigir Descrições de Sets do Flickr

Este script limpa descrições de sets do Flickr de strings indesejadas como HASH(0x...)
e move a linha do token 'orderNO:=...' do início para o fim da descrição.

Uso: $0 [OPÇÕES]

Opções:
  -h, --help        Mostrar esta mensagem de ajuda e sair.
  -n, --dry-run     Simular as alterações sem modificar o Flickr (ignora --count).
  -c, --count=NUM   Limitar as atualizações a NUM sets (ignorado em modo dry-run).
  -m, --match=REGEX Restringir o processamento a sets com títulos que correspondam ao regex fornecido.

Notas:
  - O script assume que o token a corrigir é 'orderNO'.
  - Requer o ficheiro de configuração da API do Flickr em $HOME/saved-flickr.st.
END_HELP
    exit;
}

unless ($dry_run) {
    # Valida o padrão de correspondência se fornecido
    if (defined $match) {
        eval { '' =~ /$match/ };
        if ($@) {
            warn 'Erro: Padrão regex inválido para --match: ' . $@;
            exit 1;
        }
    }
}

my $config_file = $ENV{HOME} . '/saved-flickr.st';
my $per_page = 500;
my $page = 1;
my $total_pages = 1;
my $flickr = Flickr::API->import_storable_config($config_file);
my $update_count = 0;

# --- DEFINIÇÃO DE PADRÕES COM qr// (MODIFICADORES APLICADOS NO USO) ---

# 1. Padrão para encontrar a linha do token em qualquer lugar.
my $token_pattern_qr = qr/^\s*$TOKEN_TO_FIX:=.+/; 

# 2. Padrão para verificar se o token JÁ ESTÁ NO FINAL.
my $token_at_end_pattern_qr = qr/\n*\s*$TOKEN_TO_FIX:=.+\s*$/;

# 3. Padrão para referências HASH/ARRAY.
my $hash_pattern_qr = qr/(?:HASH|ARRAY)\(0x[0-9a-f]+\)/; 

# ----------------------------------------------------------------------


# 1. Obter todos os sets, aplicando a filtragem --match
my $sets = [];
while ($page <= $total_pages) {
    my $response = $flickr->execute_method('flickr.photosets.getList', {
        per_page => $per_page,
        page => $page,
    });

    unless ($response->{success}) {
        warn 'Erro ao buscar sets: ' . $response->{error_message};
        sleep 1;
        redo;
    }

    my $s = $response->as_hash->{photosets}->{photoset};
    $s = [ $s ] unless ref $s eq 'ARRAY';
    my @filtered = @$s; 
    
    if (defined $match) {
        @filtered = grep { $_->{title} =~ /$match/ } @filtered;
    }

    push @$sets, @filtered;
    $total_pages = $response->as_hash->{photosets}->{pages};
    $page++;
}


# 2. Processar cada set e aplicar correções
foreach my $set (@$sets) {
    my $title = $set->{title};
    my $description = ref $set->{description} eq 'HASH' ? '' : $set->{description} || '';
    my $original_description = $description;
    my $token_line = '';
    my $is_updated = 0;

    # --- Verificação de Omissão (Skip Check) ---
    # Aplica-se o modificador /s (single line) para que $ corresponda ao fim da string
    if ($original_description =~ /$token_at_end_pattern_qr/s) { 
        print 'Set \'' . $title . '\' ignorado: O token \'' . $TOKEN_TO_FIX . '\' já está corretamente no final.';
        next;
    }

    # --- Correção 1: Limpar HASH(0x...) ---
    # Aplica-se o modificador /g (global) para substituir todas as ocorrências
    if ($description =~ $hash_pattern_qr) {
        $description =~ s/$hash_pattern_qr//g;
        $is_updated = 1;
        print 'Set \'' . $title . '\': Limpeza de referências HASH/ARRAY concluída.';
    }

    # --- Correção 2: Mover a linha do token para o fim ---
    # Aplica-se o modificador /m (multiline)
    if ($description =~ /$token_pattern_qr/m) {
        # 2a. Remover a linha do token do corpo principal
        ($token_line) = $description =~ /($token_pattern_qr)/m; 
        $description =~ s/$token_pattern_qr\n?//m;              
        $description =~ s/^\s+|\s+$//g;                      

        # 2b. Adicionar a linha do token no final
        if ($description) {
            # Uso de aspas duplas aqui para garantir que "\n\n" é processado como nova linha.
            $description .= "\n\n" . $token_line;
        } else {
            $description = $token_line;
        }
        $is_updated = 1;
        print 'Set \'' . $title . '\': Linha do token \'' . $TOKEN_TO_FIX . ':=...\' movida para o final.';
    }
    
    # Aplicar alterações se houver algo para atualizar
    if ($is_updated) {
        unless ($dry_run) {
            my $response = $flickr->execute_method('flickr.photosets.editMeta', {
                photoset_id => $set->{id},
                title => $title, 
                description => $description,
            });
            unless ($response->{success}) {
                warn 'Erro ao atualizar o set \'' . $title . '\': ' . $response->{error_message};
                sleep 1;
                redo; 
            }
            $update_count++;
            print 'Sucesso: Descrição do set \'' . $title . '\' atualizada.';
            last if defined $count && $update_count >= $count;
        } else {
            print 'Dry-run: Seria atualizada a descrição do set \'' . $title . '\'.';
        }
    }
}