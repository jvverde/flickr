exit #Don't let it run. Is just a bunch of examples
echo "Generate data/ioc/12.2/ioc.species.json  -- don't forget to use utf-8"
echo Convert "data/ioc/12.2/sources/Multiling IOC 12.2_b.csv" to data/ioc/12.2/ioc12_2.json 
perl tools/csv2json.pl "data/ioc/12.2/sources/Multiling IOC 12.2_b.csv" > data/ioc/12.2/ioc.json
echo "Add key 'species' with the value of IOC_12.2 and store it on data/ioc/12.2/ioc.species.json"
perl tools/dupkey.pl IOC_12.2 species data/ioc/12.2/ioc.json > data/ioc/12.2/ioc.species.json
echo Done data/ioc/12.2/ioc.species.json

echo Generate data/ioc/5.3/ioc.species.json
echo "Uniform ioc 5.3 old json format"
#perl tools/uniform_IOC_5.3.pl data/ioc/5.3/sources/IOC-multilingual-5.3.json > data/ioc/5.3/ioc.species.json
perl tools/uniform_IOC_5.3.pl data/ioc/5.3/sources/IOC-multilingual-5.3+Seq.json > data/ioc/5.3/ioc.species.json
echo Done data/ioc/12.2/ioc.species.json

echo Used to add genus to json files
find . -type f -name '*.species.json' -exec sh -c 'jq "map(. + {genus: (.species | split(\" \")[0])})" "{}" > "$(dirname "{}")/$(basename "{}" .species.json).genus.json"' \;

echo "Get a list of (clean) tags and store in on data/tags.clean"
perl list-tags.pl > data/tags.clean

echo Generate tagged-by-species.json for each ioc.genus.json, using above tags found on flickr
find data/ioc/ -type f -iname 'ioc.genus.json' -printf "%h|%f\n"|
  while IFS='|' read dir file
  do
    tools/filter-out-by-tagsclean.pl data/tags.clean "$dir/$file" species > "$dir/tagged-by-species.json"
  done

echo Generate tagged-by-English.json for each ioc.genus.json, using above tags found on flickr
find data/ioc/ -type f -iname 'ioc.genus.json' -printf "%h|%f\n"|
  while IFS='|' read dir file
  do
    tools/filter-out-by-tagsclean.pl data/tags.clean "$dir/$file" English > "$dir/tagged-by-English.json"
  done

echo "Buy tag IOC_12.2 from data/ioc/12.2/ioc.species.json"
find data/ioc/5.3 -type f -iname 'tagged-by-*' -printf "%h|%f\n"|
  while IFS='|' read dir file
  do
    plus="$dir/${file%.json}-plus.json"
    diff="$dir/${file%.json}-diff.json"
    perl tools/buy-data-from.pl English "$dir/$file" data/ioc/12.2/ioc.species.json  > "$plus"
    jq '[.[] | select(has("IOC_12.2") and ."IOC_5.3" != ."IOC_12.2")]' "$plus" > "$diff"
  done

echo "Buy tag IOC_5.3 from data/ioc/5.3/ioc.species.json"
find data/ioc/12.2 -type f -iname 'tagged-by-*' -printf "%h|%f\n"|
  while IFS='|' read dir file
  do
    plus="$dir/${file%.json}-plus.json"
    diff="$dir/${file%.json}-diff.json"
    perl tools/buy-data-from.pl English "$dir/$file" data/ioc/5.3/ioc.species.json  > "$plus"
    jq '[.[] | select(has("IOC_5.3") and ."IOC_5.3" != ."IOC_12.2")]' "$plus" > "$diff"
  done

echo Add tags of 5.3 and 12_2 to photos with same english name but different scientific name. Also add the genus!
find data/ioc -type f -iname '*-diff.json' -print0 |
  xargs -r0I{} perl set-tags.pl -f "{}" -k species -t IOC_12.2 -t IOC_5.3 -t genus

exit

#Use ONLY this code if want to add tags IOC_5.3 e IOC_12.2 as well Order and Family

echo Add all tags including Order and Family, using only Families and Orders defined in IOC12

find data/ioc -type f -ipath '*/12.2/*' -iname '*-plus.json' -print0 |
  xargs -r0I{} perl set-tags.pl -f "{}" -k species -t IOC_12.2 -t IOC_5.3 -t English -t Portuguese -t Spanish -t Order -t Family

exit
exit
exit

THIS CODE BELLOW is not used(able)

echo "filter out ioc12_2.species.json by found 'species' tagged on data/tags.clean" 
perl tools/filter-out-by-tagsclean.pl data/tags.clean data/ioc12_2.species.json species > data/speciesOnFlickr_by_IOC_12.2.json
echo "filter out ioc12_2.species.json by found 'English' names tagged on data/tags.clean" 
perl tools/filter-out-by-tagsclean.pl data/tags.clean data/ioc12_2.species.json English > data/speciesOnFlickr_by_English.json
echo "Find missing entries on speciesOnFlickr_by_IOC_12.2.json but present on speciesOnFlickr_by_English.json"
perl tools/diff.pl data/speciesOnFlickr_by_IOC_12.2.json data/speciesOnFlickr_by_English.json species 1 > data/Species-not-found-on-species-on-fickr-by-IOC.12_2-tags.json
echo "Add tags on flickr for names in IOC_12.2 species Order Family Portuguese Spanish English"
perl set-tags.pl -f data/speciesOnFlickr_by_IOC_12.2.json -k species -t IOC_12.2 -t Order -t Family -t Portuguese -t Spanish -t English
echo "Add tags also for missing species on Species-not-found-on-species-on-fickr-by-IOC.12_2-tags.json"
perl set-tags.pl -f data/Species-not-found-on-species-on-fickr-by-IOC.12_2-tags.json -k species -t IOC_12.2 -t Order -t Family -t Portuguese -t Spanish -t English
echo "filter out ioc5_2.species.json by found 'species' tagged on data/tags.clean" 
perl tools/filter-out-by-tagsclean.pl data/tags.clean data/ioc5_3.species.json species > data/speciesOnFlickr_by_IOC_5.3.json
echo "filter out ioc5_3.species.json by found 'English' names tagged on data/tags.clean"
perl tools/filter-out-by-tagsclean.pl data/tags.clean data/ioc5_3.species.json English > data/speciesOnFlickr_by_English\(IOC_5.3\).json
echo "Find missing entries on speciesOnFlickr_by_IOC_5.3.json but present on speciesOnFlickr_by_English(IOC5.3).json"
perl tools/diff.pl data/speciesOnFlickr_by_IOC_5.3.json data/speciesOnFlickr_by_English\(IOC_5.3\).json species 1 > data/Species-not-found-on-species-on-fickr-by-IOC.5_3-tags.json
echo "Find species in IOC5.3 that not exist in IOC12.2"
perl tools/diff.pl data/speciesOnFlickr_by_IOC_5.3.json data/speciesOnFlickr_by_IOC_12.2.json species 2 > data/this.IOC5_3.species.doesnt.exist.in.IOC12_2.json
cat data/this.IOC5_3.species.doesnt.exist.in.IOC12_2.json | jq '.[]|{name:.English, species:.species}'
echo "Find species in IOC5.3(English) that not exist in IOC12.2"
perl tools/diff.pl data/speciesOnFlickr_by_IOC_12.2.json data/speciesOnFlickr_by_English\(IOC_5.3\).json English 1 > data/this.IOC5_3\(English\).species.doesnt.exist.in.IOC12_2.json
echo "Extract only English Name and species"
jq '[.[]| {name: .English, species: .species}]' data/this.IOC5_3\(English\).species.doesnt.exist.in.IOC12_2.json
echo "Buy from ioc12.2 keys=> values and merge ir on speciesOnFlickr_by_English\(IOC_5.3"
perl tools/buy-data-from.pl English data/speciesOnFlickr_by_English\(IOC_5.3\).json data/ioc12_2.species.json  > data/speciesOnFlickr_by_English\(IOC_5.3\)+json12_2.json
jq '.[] | select(has("IOC_12.2") and ."IOC5.3" != ."IOC_12.2")' data/speciesOnFlickr_by_English\(IOC_5.3\)+json12_2.json > data/diffs.json
jq '[.[]|select(has("Portuguese"))]| map(. + {FirstPortuguese: (."Portuguese" | split("-")[0])})' data/ioc/13.1/ioc.genus+lastEnglish.json > data/ioc/13.1/ioc.genus+lastEnglish+FirstPortuguese.json


jq '[.[]|select(has("Portuguese"))]| map(. + {FirstPortuguese: (."Portuguese" | split("-")[0])})' data/ioc/13.1/ioc.genus+lastEnglish.json > data/ioc/13.1/ioc.genus+lastEnglish+FirstPortuguese.json

jq '
  def firstDash(k): if has(k) then {("First" + k): (.[k]|split("-")[0])} else null end; 
  def firstWord(k): if has(k) then {("First" + k): (.[k]|split(" ")[0])} else null end; 
  def lastWord(k): if has(k) then {("Last" + k): (.[k]|split(" ")[-1])} else null end; 
  def genus(k): if has(k) then {("genus"): (.[k]|split(" ")[0])} else null end;
  map (. + { English: ."English name"} )| 
  map(.
    + firstDash("Portuguese")
    + firstWord("Spanish")
    + firstWord("French")
    + lastWord("English")
    + genus("species")
  )
' data/ioc/13.1/ioc.species.json

jq '
  def firstDash(k): if has(k) then {("First" + k): (.[k]|split("-")[0])} else null end;
  def firstWord(k): if has(k) then {("First" + k): (.[k]|split(" ")[0])} else null end;
  def lastWord(k): if has(k) then {("Last" + k): (.[k]|split(" ")[-1])} else null end;
  def genus(k): if has(k) then {("genus"): (.[k]|split(" ")[0])} else null end;
  map(.
     + genus("species") + firstDash("Portuguese") + lastWord("English")
  )
' data/ioc/5.3/ioc.species.json > data/ioc/5.3/ioc.genus+names-without-Seq.json

#jq '.|= reduce range(0;length) as $i (.; .[$i]."Seq." = 1+$i)' data/ioc/5.3/ioc.genus+names-without-Seq.json > data/ioc/5.3/ioc.genus+names.json

jq 'map(. 
  + { familyEnglish: (.FAMILY|capture("\\((?<fam>[^)(]+)").fam) } 
  + { familyName: (.FAMILY|capture("(?<fam>^[^)( ]+)").fam)})
' data/eBird/v2022/ebird.species.json > data/eBird/v2022/ebird.species+family.json
#perl set-tags.pl -f data/eBird/v2022/ebird.species+family.json -k SCI_NAME -t ORDER1 -t familyName -t familyEnglish -t PRIMARY_COM_NAME -m "Phoenicurus frontalis"
#perl set-tags.pl -f data/ioc/13.1/ioc.genus+names.json -t species -k English -t Order -t Family -t genus -t Portuguese -t French -t Spanish -t LastEnglish -t FirstPortuguese -t FirstSpanish -t FirstFrench -l IOC_131 -m "Blue-fronted Redstart"
#perl set-tags.pl -f data/ioc/5.3/ioc.genus+names.json -k English -t Order -t Family -t genus -t species -l IOC_53 -m 'Blue-fronted Redstart'


./tools/csv2json.pl data/ioc/14.1/sources/Multiling\ IOC\ 14.1.csv > ./data/ioc/14.1/ioc.json
 perl tools/dupkey.pl IOC_14.1 species data/ioc/14.1/ioc.json > data/ioc/14.1/ioc.species.json
  find data/ioc/14.1/ -type f -name '*.species.json' -exec echo sh -c 'jq "map(. + {genus: (.species | split(\" \")[0])})" "{}" > "$(dirname "{}")/$(basename "{}" .species.json).genus.json"' \;
./add_first-or-last_name.sh data/ioc/14.1/ioc.genus.json |tee data/ioc/14.1/ioc.genus+names.json
