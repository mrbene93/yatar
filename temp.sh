#!/usr/local/bin/bash


# Vars
dt=$(date +"%Y%m%d_%H%M%S")
journalfile='/tmp/yatar/yatar.journal'

# Get files and directories from handover
files=()
for arg in "$@"
do
    files+=(${arg})
done


# Get involved ZFS datasets
datasets=()
for file in ${files[@]}
do
    if [[ -f $file ]]
    then
        datasets+=($(df $file | tail -n +2 | cut -d' ' -f1))
    elif [[ -d $file ]]
    then
        dataset=$(df $file | tail -n +2 | cut -d' ' -f1)
        for ds in $(zfs list -Ho name -rt filesystem $dataset)
        do
            datasets+=${ds}
        done
    fi
done


# Snapshot, hold, clone and mount dataset
cloneds='data/appdata/yatar/clones'
clonemp='/tmp/yatar'
for dataset in ${datasets[@]}
do
    zpool="${dataset%%/*}"
    zpoolmp=$(zfs get -Ho value mountpoint ${zpool})
    oldmp=$(zfs get -Ho value mountpoint ${dataset})
    newmp="${oldmp/$zpoolmp/$clonemp}"
    clonename="${dataset/$zpool\//}"
    clonename=${clonename//\//_}
    clone="${cloneds}/${clonename}"
    snapname="${dataset}@yatar_${dt}"
    prevsnap="$(zfs list -Ho name -t snapshot ${dataset} | tail -n1)"
    zfs snapshot ${snapname}
    zfs hold 'yatar' ${snapname}
    zfs clone -o canmount=noauto -o readonly=on -o mountpoint=${newmp} ${snapname} ${clone}
    zfs mount ${clone}

    # Get files that have been created or changed since the previous snapshot
    zfs diff -FH ${prevsnap} ${snapname} | grep -E '^[+M]\s+F\s+' | cut -f3 >> ${journalfile}
done

# find files list
for file in ${files[@]}
do
    find ${file} -type f ! -iname '*._*' ! -iname '*.Trash*' ! -iname '*.DocumentRevisions-V100' ! -iname '*.fseventsd' ! -iname '*.Spotlight*' ! -iname '*.TemporaryItems' ! -iname '*RECYCLE.BIN' ! -iname 'System Volume Information' ! -iname '.DS_Store' ! -iname 'desktop.ini' ! -iname 'Thumbs.db' -type f >> ${journalfile}
# mit grep in journal files der vorherigen jobs nachschauen, ob datei schon im backup vorhanden ist oder nicht und entsprechend nur die finds ausgeben, die nicht von grep gefunden wurden
done

# Unmount, release and destroy dataset
for dataset in ${datasets[@]}
do
    # Unmount and destroy the clone, release the previous snapshot and destroy it
    zfs unmount ${clone}
    zfs destroy ${clone}
    if [[ $prevsnap != "" ]]
    then
        zfs release 'yatar' ${prevsnap}
        zfs destroy ${prevsnap}
    fi
done

