import requests
import fitz  # PyMuPDF

pdf_path = "../data/paulo-paixao.pdf"

doc = fitz.open(pdf_path)

# Expressões regulares para identificar ordens e famílias
import re
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
        ordem = match.group(1)
        nome_portugues = match.group(2)
        ordens[ordem] = nome_portugues
    
    # Procurar por famílias
    for match in familia_pattern.finditer(text):
        familia = match.group(1)
        nome_portugues = match.group(2)
        familias[familia] = nome_portugues

# Escrever resultados em um arquivo com codificação UTF-8
with open("../data/families-e-ordens-em-portugues.txt", "w", encoding="utf-8") as f:
    f.write("Ordens encontradas:\n")
    for ordem, nome in ordens.items():
        f.write(f"{ordem}: {nome}\n")
    
    f.write("\nFamílias encontradas:\n")
    for familia, nome in familias.items():
        f.write(f"{familia}: {nome}\n")

# Também exibir na tela
print("Ordens encontradas:")
for ordem, nome in ordens.items():
    print(f"{ordem}: {nome}")

print("\nFamílias encontradas:")
for familia, nome in familias.items():
    print(f"{familia}: {nome}")