#!/bin/bash

#Compare two lists and output ids of photos missing on second list

#find keys from first list missing on second list
missingkeys=$(jq -n --argfile file1 "$1" --argfile file2 "$2" '$file1 | keys as $keys1 |$file2 | keys as $keys2 | ($keys1 - $keys2)')

#extract only elementos missing on second list
elements=$(jq -n --argjson missingkeys "$missingkeys" --argfile hashtable "$1" '$missingkeys | map({ (.): $hashtable[.] }) | add')

#map to an array os ids associated to those (missing) keys
#checkids=$(jq -n --argjson first "$elements" 'reduce ($first | to_entries[]| .value.ids) as $array ([]; . + $array) | unique | map(tonumber)|sort')
#We only need first id ?!
checkids=$(jq -n --argjson first "$elements" 'reduce ($first | to_entries[]| .value.first) as $val ([]; . + [$val]) |unique | map(tonumber)|sort')

#map all ids on second list
allids=$(jq -n --argfile second "$2" '$second | to_entries|map(.value.ids)|reduce .[] as $array ([]; . + $array)|unique|map(tonumber)|sort')

#output the diference. Those photos are not present on second list 

[[ $3 ]] && {
  jq -n --argjson check "$checkids" --argjson ids "$allids" '($check - $ids)[]'| sed s,^,$3/,
} || {
  jq -n --argjson check "$checkids" --argjson ids "$allids" '($check - $ids)'
}


#USE EXAMPLE:
# ./tools/find-missings.sh data/species-counting.ioc131.json data/species-counting.ioc141.json "https://www.flickr.com/photos/jvverde/"
#or
# ./tools/find-missings.sh data/species-counting.ioc131.json data/species-counting.ioc141.json|jq '.[]|. |= tostring |"https://www.flickr.com/photos/jvverde/" + .'
