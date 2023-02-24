echo convert "data/ioc/12.2/Multiling IOC 12.2_b.csv" to data/ioc12_2.json
perl tools/csv2json.pl "data/ioc/12.2/Multiling IOC 12.2_b.csv" > data/ioc12_2.json
echo "add key 'species' with a value same as the value of IOC_12.2 and store it on data/ioc12_2.species.json"
perl tools/dupkey.pl IOC_12.2 species data/ioc12_2.json > data/ioc12_2.species.json
echo "get a list of (clean) tags and store in on data/tags.clean"
perl list-tags.pl > data/tags.clean
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
echo "Uniform ioc 5.3 old json format"
perl tools/uniform_IOC_5.3.pl data/ioc/5.3/IOC-multilingual-5.3.json > data/ioc5_3.species.json
echo "filter out ioc5_2.species.json by found 'species' tagged on data/tags.clean" 
perl tools/filter-out-by-tagsclean.pl data/tags.clean data/ioc5_3.species.json species > data/speciesOnFlickr_by_IOC_5.3.json
echo "filter out ioc5_3.species.json by found 'English' names tagged on data/tags.clean"
perl tools/filter-out-by-tagsclean.pl data/tags.clean data/ioc5_3.species.json English > data/speciesOnFlickr_by_English\(IOC_5.3\).json
echo "Find missing entries on speciesOnFlickr_by_IOC_5.3.json but present on speciesOnFlickr_by_English(IOC5.3).json"
perl tools/diff.pl data/speciesOnFlickr_by_IOC_5.3.json data/speciesOnFlickr_by_English\(IOC_5.3\).json species 1 > data/Species-not-found-on-species-on-fickr-by-IOC.5_3-tags.json
echo "Find species in IOC5.3 but not exist in IOC12.2"
perl tools/diff.pl data/speciesOnFlickr_by_IOC_5.3.json data/speciesOnFlickr_by_IOC_12.2.json species 2 > data/this.IOC5_3.species.doesnt.exist.in.IOC12_2.json
cat data/this.IOC5_3.species.doesnt.exist.in.IOC12_2.json | jq '.[]|{name:.English, species:.species}'