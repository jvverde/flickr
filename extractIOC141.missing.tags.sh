grep -a IOC141 data/diff.ioc.txt| cut -d'|' -f2|sort -u|grep -v '^\s*$'|perl -lape 's/^\s+|\s+$//g'|paste -sd '|' -
