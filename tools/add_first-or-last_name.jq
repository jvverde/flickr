map(
  ."Seq." = (.seq // "") |
  .species = (."IOC_15.1" // "") |
  .genus = (.species | split(" ")[0]?) |
  .LastEnglish = ((."English" // "") | split(" ")[-1]?) |
  .FirstFrench = ((."French" // "") | split(" ")[0]?) |
  .FirstSpanish = ((."Spanish" // "") | split(" ")[0]?) |
  ."FirstPortuguese (Lusophone)" = ((."Portuguese (Lusophone)" // "") | split("-")[0]?) |
  ."FirstPortuguese (Portuguese)" = ((."Portuguese (Portuguese)" // "") | split("-")[0]?)
)
