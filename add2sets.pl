#!/usr/bin/perl
################################################################################
# add2sets.pl
#
# DESCRIÇÃO:
# Este script automatiza a organização de fotografias no Flickr através de 
# photosets (álbuns). Lê um ficheiro JSON com dados estruturados (contendo 
# tags, números de ordem, códigos HEX e famílias) e, para cada entrada:
#   1. Procura fotos no Flickr associadas a uma determinada tag
#   2. Cria ou identifica dois photosets com nomenclatura específica:
#      - A0 - [Ord No] - [Order]
#      - A1 - [HEX] - [Family]
#   3. Adiciona todas as fotos encontradas a ambos os photosets
#
# O script suporta filtragem opcional por regex e integra-se com a API do 
# Flickr usando credenciais armazenadas localmente.
#
# USO:
#   ./add2sets.pl <chave_json> <ficheiro.json> [--filter regex]
#
# EXEMPLO:
#   ./add2sets.pl "tag_field" dados.json --filter "^pattern"
#
# FORMATO DO JSON ESPERADO:
#   O ficheiro JSON deve conter um array de objetos, onde cada objeto tem:
#   - Uma chave especificada como primeiro argumento (usada como tag de pesquisa)
#   - 'Ord No': Número de ordem (usado no título do photoset A0)
#   - 'Order': Descrição da ordem (usado no título do photoset A0)
#   - 'HEX': Código hexadecimal (usado no título do photoset A1)
#   - 'Family': Nome da família (usado no título do photoset A1)
#
#   Exemplo de JSON:
#   [
#     {
#       "tag_field": "minha_tag_001",
#       "Ord No": "01",
#       "Order": "Lepidoptera",
#       "HEX": "1A",
#       "Family": "Papilionidae"
#     },
#     {
#       "tag_field": "minha_tag_002",
#       "Ord No": "02",
#       "Order": "Coleoptera",
#       "HEX": "2B",
#       "Family": "Scarabaeidae"
#     }
#   ]
#
# AUTOR: [Nome do autor original]
# DATA: [Data de criação]
################################################################################

use strict;
use warnings;
use Data::Dumper;      # Para debug e visualização de estruturas de dados
use JSON;              # Para parsing de ficheiros JSON
use Flickr::API;       # Interface com a API do Flickr
use Getopt::Long;      # Para processar argumentos de linha de comando

# Adiciona newline automático a todos os prints
$\ = "\n";

################################################################################
# FUNÇÕES AUXILIARES
################################################################################

# Exibe mensagem de uso correto do script
sub usage {
    print "Usage: $0 <key> <json file> [--filter keymatch]\n";
    exit 1;
}

################################################################################
# PROCESSAMENTO DE ARGUMENTOS
################################################################################

# Variável para armazenar a regex opcional de filtragem
my $filter_regex;

# Captura de argumentos opcionais (--filter)
GetOptions('filter=s' => \$filter_regex);

# Compila a regex se foi fornecida
$filter_regex = qr/$filter_regex/ if defined $filter_regex;

# Valida que foram passados exatamente 2 argumentos obrigatórios
usage() unless @ARGV == 2;

# Primeiro argumento: nome da chave no JSON a usar como tag de pesquisa
my $key = shift;

# Lê o conteúdo completo do ficheiro JSON
my $json_text = do { local $/; <> };
my $json = JSON->new->utf8;
my $data = $json->decode($json_text);

################################################################################
# CONFIGURAÇÃO DA CONEXÃO COM FLICKR
################################################################################

# Lê as credenciais do Flickr de um ficheiro de configuração guardado
my $config_file = "$ENV{HOME}/saved-flickr.st";
my $flickr = Flickr::API->import_storable_config($config_file);

################################################################################
# CARREGAMENTO DE PHOTOSETS EXISTENTES
################################################################################

# Hash para mapear títulos de photosets aos seus dados
my %photoset_titles;

# Array para armazenar todos os photosets
my $sets = [];
my $page = 0;
my $pages = 1;

# Itera por todas as páginas de photosets (paginação da API)
while ($page++ < $pages) {
    my $response = $flickr->execute_method('flickr.photosets.getList', {
        per_page => 500,  # Máximo de resultados por página
        page => $page,
    });

    # Verifica se a chamada à API foi bem-sucedida
    die "Error: $response->{error_message}" unless $response->{success};

    # Adiciona os photosets desta página ao array total
    push @$sets, @{$response->as_hash->{photosets}->{photoset}};
    
    # Atualiza informação de paginação
    $pages = $response->as_hash->{photosets}->{pages};
    $page = $response->as_hash->{photosets}->{page};
}

# Regex para identificar photosets com formato específico: A[0-9] - [HEX] -
my $re = qr/A[0-9]\s*-\s*[0-9A-F]{1,2}\s*-/i;

# Filtra photosets que correspondem ao padrão e indexa-os por título simplificado
foreach my $set (grep { $_->{title} =~ $re } @$sets) {
    my $index = $set->{'title'};
    # Extrai apenas a parte relevante do título (prefixo + primeira palavra)
    $index =~ s/($re\s*\w+).*/$1/i;
    # Remove espaços múltiplos
    $index =~ s/\s{2,}/ /;
    $photoset_titles{$index} = $set;
}

################################################################################
# PROCESSAMENTO PRINCIPAL
################################################################################

my $count = 0;

# Processa cada entrada do array JSON
foreach my $hash (@$data) {
    # Aplica filtro de regex se foi fornecido
    next if defined $filter_regex && $hash->{$key} !~ $filter_regex;

    # Procura fotos no Flickr com a tag especificada
    my $response = $flickr->execute_method(
        'flickr.photos.search',
        {
            'tags' => $hash->{$key},      # Tag a procurar
            'user_id' => 'me'             # Apenas fotos do utilizador autenticado
        }
    );
    
    # Avisa se houver erro e passa para a próxima entrada
    warn "Error searching photos: $response->{error_message}" and next unless $response->{success};
    
    my $photos = $response->as_hash->{'photos'}->{'photo'};

    # Garante que $photos é sempre um array (API pode retornar hash se for 1 foto)
    $photos = [$photos] unless 'ARRAY' eq ref $photos;
    
    # Avisa se não foram encontradas fotos com esta tag
    warn qq|Couldn't find any photo for tag $hash->{$key}| and next unless exists $photos->[0]->{id};

    # Constrói os títulos dos dois photosets baseados nos dados do JSON
    my $ordern = $hash->{'Ord No'};
    my $title1 = 'A0 - ' . $ordern . ' - ' . $hash->{'Order'};
    my $title2 = 'A1 - ' . $hash->{'HEX'} . ' - ' . $hash->{'Family'};

    # Verifica/cria o primeiro photoset
    my $set1 = check_or_create_photoset($title1, $photos->[0]->{id});

    # Verifica/cria o segundo photoset
    my $set2 = check_or_create_photoset($title2, $photos->[0]->{id});

    ############################################################################
    # ADIÇÃO DE FOTOS AOS PHOTOSETS
    ############################################################################
    
    my @sets = ($set1, $set2);
    
    # Para cada foto encontrada
    foreach my $photo (@$photos) {
        # Adiciona a foto a ambos os photosets
        foreach my $set (@sets) {
            # Valida que temos IDs válidos
            next unless $set->{id} && $photo->{id};
            
            # Executa a adição da foto ao photoset
            my $response = $flickr->execute_method(
                'flickr.photosets.addPhoto',
                {
                    photoset_id => $set->{id},
                    photo_id => $photo->{id}
                }
            );
            
            # Confirma sucesso
            print qq|Add photo $photo->{title} to $set->{title}| if $response->{success};
            
            # Avisa sobre erros (exceto se a foto já estiver no set)
            warn "Error adding photo $photo->{title} to set $set->{title}: $response->{error_message}" 
                unless $response->{success} || $response->{error_message} =~ /Photo already in set/;
        }
    }
}

################################################################################
# FUNÇÕES
################################################################################

# Verifica se um photoset existe; se não existir, cria-o
sub check_or_create_photoset {
    my ($title, $photo_id) = @_;
    
    # Retorna o photoset se já existir no cache
    return $photoset_titles{$title} if exists $photoset_titles{$title};
    
    # O photoset não existe, então cria um novo
    print "Not found set $title as so I am going to create it";
    
    my $response = $flickr->execute_method(
        'flickr.photosets.create',
        {
            title => $title,
            primary_photo_id => $photo_id  # Foto principal do álbum
        }
    );
    
    # Avisa sobre erro na criação e retorna hash vazio
    warn "Error creating the set $title : $response->{error_message}" and return {} 
        unless $response->{success};
    
    # Extrai dados do photoset criado
    my $set = $response->as_hash->{'photoset'};
    $set->{title} //= $title;  # Garante que o título está definido
    
    # Adiciona ao cache para futuras consultas
    $photoset_titles{$title} = $set;
    
    return $set;
}