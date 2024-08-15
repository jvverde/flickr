exit #don't allow this to run. Is just a memory refresh for me
perl tools/csv2json.pl data\ IOC\ 12.2_b.csv > data/ioc12_2.json
perl tools/bykeys.pl data/ioc12_2.json Order Family > data/ioc12_2.by-order-and-family.json 
perl tools/filter-out.pl data/tags.raw data/ioc12_2.json IOC_12.2 > data/speciesOnFlickr_by_IOC_12.2.json
perl tools/filter-out.pl data/tags.raw data/ioc12_2.json English > data/speciesOnFlickr_by_EnglishName.json
perl tools/diff.pl data/speciesOnFlickr_by_IOC_12.2.json data/speciesOnFlickr_by_EnglishName.json IOC_12.2 1 > data/missing_IOC_12_2.tags.json
perl tools/diff.pl data/speciesOnFlickr_by_IOC_12.2.json data/speciesOnFlickr_by_EnglishName.json IOC_12.2 2 > data/missing_English.tags.json
perl tools/diff.pl data/speciesOnFlickr_by_IOC_12.2.json data/speciesOnFlickr_by_EnglishName.json IOC_12.2 3 > data/missing_IOC_12_2_or_English.tags.json
perl -lane 'print if /[^ -~\xA0-\xFF]+/i' data/tags.clean > data/tags2remove.txt
perl tools/filter-out.pl data/tags.raw data/ioc12_2.json IOC_12.2
perl set-tags.pl data/missing_IOC_12_2.tags.json English IOC_12.2 Order Family Portuguese Spanish
perl set-tags.pl data/missing_English.tags.json IOC_12.2 English Order Family Portuguese Spanish
perl set-tags.pl data/speciesOnFlickr_by_IOC_12.2.json IOC_12.2 Order Family Portuguese Spanish English
perl set-tags.pl -f data/speciesOnFlickr_by_IOC_12.2.json -k IOC_12.2 -t Order -t Family -t Portuguese -t Spanish -t English -r
perl ../../../tools/filter-out.pl ../../tags.raw ioc5_3.json IOC5.3 > speciesOnFlickr_by_IOC_5.3.json
#fuplicat keys from IOCxx to species
perl tools/dupkey.pl IOC_12.2 species data/ioc12_2.json > data/ioc12_2.species.json
perl tools/dupkey.pl IOC5.3 species data/ioc/5.3/ioc5_3.json > data/ioc/5.3/ioc5_3.species.json
#obtain raw tags (the ones which should be used in filter out)
perl list-raw-tags.pl > data/tags.raw
perl tools/filter-out.pl data/tags.raw data/ioc12_2.species.json species > data/speciesOnFlickr_by_IOC_12.2.json
perl tools/filter-out.pl data/tags.raw data/ioc12_2.species.json English > data/speciesOnFlickr_by_EnglishName.json
perl tools/filter-out.pl data/tags.raw data/ioc/5.3/ioc5_3.species.json species > data/speciesOnFlickr_by_IOC_5.3.json
#19-05-2024
 ./add_first-or-last_name.sh data/ioc/14.1/ioc.genus.json |tee data/ioc/14.1/ioc.genus+names.json

 ./tools/by-photo-id.pl data/species-counting.ioc141.json |jq 'with_entries(select(.value | length > 1))'|jq 'with_entries(.key |= "https://www.flickr.com/photos/jvverde/" + .)'