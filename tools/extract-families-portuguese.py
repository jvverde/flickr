#!/usr/bin/env python3
import sys
import re
import fitz # PyMuPDF

# 1. Verifica se o caminho do PDF foi fornecido como argumento
if len(sys.argv) < 2:
    print("Uso: ./processar_pdf.py <caminho_do_arquivo_pdf>")
    sys.exit(1)

pdf_path = sys.argv[1]

# 2. Tenta abrir o documento PDF
try:
    doc = fitz.open(pdf_path)
except fitz.FileNotFoundError:
    print(f"Erro: Arquivo não encontrado no caminho: {pdf_path}")
    sys.exit(1)
except Exception as e:
    print(f"Erro ao abrir o PDF: {e}")
    sys.exit(1)

# Expressões regulares para identificar ordens e famílias
ordem_pattern = re.compile(r"Ordem\s+([A-Za-z]+)\s+([a-záéíóúãõç]+)")
familia_pattern = re.compile(r"Família\s+([A-Za-z]+)\s+([a-záéíóúãõç]+)")

# Dicionários para armazenar as ordens e famílias
ordens = {}
familias = {}

# Processar cada página do PDF
for page_num in range(doc.page_count):
    page = doc.load_page(page_num)
    text = page.get_text("text")
    
    # Procurar por ordens
    for match in ordem_pattern.finditer(text):
        # O grupo 1 é o nome científico (Ordem) e o grupo 2 é o nome em português.
        ordem = match.group(1)
        nome_portugues = match.group(2)
        ordens[ordem] = nome_portugues
    
    # Procurar por famílias
    for match in familia_pattern.finditer(text):
        # O grupo 1 é o nome científico (Família) e o grupo 2 é o nome em português.
        familia = match.group(1)
        nome_portugues = match.group(2)
        familias[familia] = nome_portugues

doc.close()

# Escrever resultados em um arquivo com codificação UTF-8
output_file = "families-e-ordens-em-portugues.txt" # Ajustei o caminho para um local mais simples
try:
    with open(output_file, "w", encoding="utf-8") as f:
        f.write("Ordens encontradas:\n")
        for ordem, nome in ordens.items():
            f.write(f"{ordem}: {nome}\n")
        
        f.write("\nFamílias encontradas:\n")
        for familia, nome in familias.items():
            f.write(f"{familia}: {nome}\n")
    print(f"\nResultados salvos em: {output_file}")
except Exception as e:
    print(f"Erro ao escrever o arquivo de saída: {e}")


# Também exibir na tela
print("\nOrdens encontradas:")
for ordem, nome in ordens.items():
    print(f"{ordem}: {nome}")

print("\nFamílias encontradas:")
for familia, nome in familias.items():
    print(f"{familia}: {nome}")

print("\nProcessamento concluído.")
