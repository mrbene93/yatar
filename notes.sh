#!/usr/local/bin/bash

# find file in dataset
df <datei> | tail -n +2 | cut -d' ' -f1 | uniq

# zfs diff, find files that have changed
zfs diff -FH dataset@snapshotA dataset@snapshotB | grep -E '^[+M]\s+F\s+' | cut -f 3 | sort -u

# zfs clone
zfs clone -p -o readonly=on -o canmount=noauto -o mountpoint=/tmp/yatar/<datasetname> dataset@snapshot data/appdata/yatar/clones/<datasetname> 

# bsdtar
bsdtar --block-size $blockingfactor --file - --files-from $filesfrom --null --totals --use-compress-program "zstd --quiet --threads=$cores" --verbose --create | \
mbuffer -q -s $blocksize -m 25% -P 90 --tapeaware -o $tapedev &> $logfile

# find files in directory
find -s <dir> -type f ! -iname '*._*' ! -iname '*.Trash*' ! -iname '*.DocumentRevisions-V100' ! -iname '*.fseventsd' ! -iname '*.Spotlight*' ! -iname '*.TemporaryItems' ! -iname '*RECYCLE.BIN' ! -iname 'System Volume Information' ! -iname '.DS_Store' ! -iname 'desktop.ini' ! -iname 'Thumbs.db' -type f -print0 | uniq
