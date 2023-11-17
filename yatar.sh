#!/usr/local/bin/bash

# Check if script is run as root
if [[ $EUID -ne 0 ]]
then
    echo "Please run as root."
    exit 1
fi



# Create PID file
pidfile='/var/run/yatar.pid'
echo -n $$ > $pidfile

# First batch of variables and functions
OLDIFS=$IFS
IFS=$'\n'
tapesa=0
tapedev="/dev/nsa$tapesa"
taperewdev="/dev/sa$tapesa"
tapectldev="/dev/sa$tapesa.ctl"
ltokey='/var/keys/lto.key'
cloneds='data/appdata/yatar/clones'
clonemp='/tmp/yatar'

## Check if hardware encryption key is loaded (should be loaded on boot)
ltokeydesc="$(tail -n1 $ltokey)"
if [[ -z $(stenc | grep --color=never "$ltokeydesc") ]]
then
    echo "No hardware encryption key is loaded. Please fix that before running the script."
    exit 1
fi

function get_tapefilenum {
    mt -f $tapectldev ostatus | grep --color=never 'File Number' | cut -f1 | cut -d':' -f2 | cut -d' ' -f2
}

function get_taperecordnum {
    mt -f $tapectldev ostatus | grep --color=never 'Record Number' | cut -f2 | cut -d':' -f2 | cut -d' ' -f2
}

function moveto_file {
    # $1 = target filenum
    current=$(get_tapefilenum)
    currentrec=$(get_taperecordnum)
    new=$1
    if [[ $new -lt $current ]]                                  # Move backward
    then
        movenum=$((current - new + 1))
        write_logfile "Moving backward to file $1."
        mt -f $tapedev bsf $movenum
        mt -f $tapedev fsf 1
    elif [[ $new -gt $current ]]                                # Move forward
    then
        movenum=$((new - current))
        write_logfile "Moving forward to file $1."
        mt -f $tapedev fsf $movenum
    elif [[ $new -eq $current ]] && [[ $currentrec -gt 0 ]]     # Move to beginning of current file
    then
        write_logfile "Correct file, but not at beginning."
        write_logfile "Moving to the beginning of file."
        mt -f $tapedev bsf 1
        mt -f $tapedev fsf 1
    fi
}


# Get supplied parameters
optstring=":felw:"
autoload=0
eject=0
full=0
workingdir=''
while getopts ${optstring} arg
do
    case ${arg} in
        f)  # Do full backup
            full=1
            ;;
        e)  # Eject tape after job is complete
            eject=1
            ;;
        l)  # Automatically load the tape, if none is inserted
            autoload=1
            ;;
        w)  # Working directory
            workingdir=$OPTARG
            ;;
        \?) # Unknown options
            echo "Invalid option: -$OPTARG"
            exit 2
            ;;
        :)  # Catch supplied options without argument
            echo "Option -$OPTARG requires an argument."
            exit 2
            ;;
    esac
done


# Get files to backup
shift "$((OPTIND - 1))"
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


# Second batch of variables and functions
yatardir="${workingdir}/.yatar"
excludefile="${yatardir}/exclude.txt"
cores=$(sysctl -n hw.ncpu)
blocksize=$(sysctl -n kern.cam.sa.$tapesa.maxio)
blockingfactor=$((blocksize / 512))
dt=$(date +"%Y%m%d_%H%M%S")
dth=$(date)

# Create directories and files
jobdir="${workingdir}/${dt}"
logfile="${jobdir}/${dt}.log"
versionsfile="${jobdir}/${dt}.versions"
errorfile="${jobdir}/${dt}.error"
sumsfile="${jobdir}/${dt}.sums"
indexfile="${jobdir}/${dt}.index"
journalfile="${jobdir}/${dt}.journal"

function newline {
    echo ''
    echo '' >> $logfile
}

function get_tapelastfile {
    tail -n 1 $volfile | cut -d' ' -f1
}

function write_volfile {
    # $1 = tapefilenum, $2 = jobname
    echo $1 $2 >> $volfile
}

function write_logfile {
    # $1 = input
    echo $1
    echo $1 >> $logfile
}

function write_errorfile {
    echo "$errorcounterlog" >> $errorfile
}



# Actual Job Start
## Check if a tape is inserted
if [[ $(camcontrol attrib $tapedev -r attr_values -a 0x0401 -F text_esc) == '' ]]
then
    echo "No tape inserted in specified tape device."
    if [[ $autoload -eq 1 ]]
    then
        echo "Autoload is set, loading tape."
        echo ''
        mt -f $tapedev load
    else
        exit 1
    fi
fi

## Get tape id
tapeidbs=1048576
tapevendor=$(camcontrol attrib $tapedev -r attr_values -a 0x0400 -F text_esc)
tapeserial=$(camcontrol attrib $tapedev -r attr_values -a 0x0401 -F text_esc)
tapeid=${tapevendor}-${tapeserial}
volfile="${yatardir}/${tapeid}.vol"
mkdir -p $yatardir
touch $volfile

## Logfile header
mkdir -p $jobdir
touch $logfile
write_logfile "$dth - Starting job run."
newline
write_logfile "Path to logfile containing list of files: $indexfile"
write_logfile "Path to logfile containing checksums: $sumsfile"
write_logfile "Path to library file containing used tapes: $volfile"
write_logfile "Using blocksize of $blocksize Bytes."
newline

## Print versions to versionsfile
bsdtar --version >> $versionsfile
zstd --version >> $versionsfile
xxhsum --version 2>> $versionsfile
zfs --version >> $versionsfile

## Check if tape is empty or not and if it is known to yatar
if [[ ! -s $volfile ]]
then
    mt -f $taperewdev rewind
    tapeidontape=$(dd if=$taperewdev bs=$tapeidbs count=1 status=none 2> /dev/null)
    if [[ -n $tapeidontape ]]
    then
        echo "The tape may have been written to, but it is not known by yatar."
        echo "The tape could also belong to another job."
        echo "Continuing would overwrite all contents."
        echo "Please erase the tape before using it with yatar or insert another tape."
        rm -r $volfile $logfile $jobdir
        exit 3
    elif [[ -z $tapeidontape ]]
    then
        write_logfile "The inserted tape is either blank or has never been written to by yatar."
        write_logfile "Writing Tape-ID to file 0 of the tape, so it can be recognized."
        echo $tapeid | dd of=$taperewdev bs=$tapeidbs count=1 status=none
        write_logfile "The tape has the ID $tapeid."
        newline
        write_volfile 0 "Tape ID"
    fi
fi



# Writing the files to tape with BSD Tar
touch $indexfile

## Get the last file that was written to tape
lastfile=$(get_tapelastfile)
nextfile=$((lastfile + 1))
write_logfile "yatar wrote the previous job to tape file $lastfile."
write_logfile "So this job will be written to tape file $nextfile."
newline

## Move to the end of data, so that tar can append to the tape
moveto_file $nextfile
if [[ $(get_tapefilenum) -ne $nextfile ]]
then
    echo "Something went wrong while positioning the tape to the next file."
    exit 4
fi
newline

## Snapshot, hold, clone and mount datasets and get files that have been created or changed since the previous snapshot
diffs=()
mountpoints=()
write_logfile "Snapshotting, cloning and mounting ZFS datasets."
for dataset in ${datasets[@]}
do
    zpool="${dataset%%/*}"
    zpoolmp=$(zfs get -Ho value mountpoint ${zpool})
    oldmp=$(zfs get -Ho value mountpoint ${dataset})
    newmp="${oldmp/$zpoolmp/$clonemp}"
    mountpoints+=("$oldmp","$newmp")
    clonename="${dataset/$zpool\//}"
    clonename=${clonename//\//_}
    clone="${cloneds}/${clonename}"
    snapname="${dataset}@yatar_${dt}"
    prevsnap="$(zfs list -Ho name -t snapshot ${dataset} | grep '@yatar' | tail -n1)"
    zfs snapshot ${snapname}
    zfs hold yatar ${snapname}
    zfs clone -o canmount=noauto -o readonly=on -o mountpoint=${newmp} ${snapname} ${clone}
    zfs mount ${clone}
    if [[ $prevsnap != "" ]] && [[ $full -ne 1 ]]
    then
        diffs+=($(zfs diff -FHh ${prevsnap} ${snapname} | grep -E '^[+M]\s+F\s+' | cut -f3 | sed "s|${oldmp}|${newmp}|"))
    fi
done
diffs=($(printf "%s\n" "${diffs[@]}" | sort -u))
newline

## Find files located in the actual mountpoints
finds=()
write_logfile "Curating and filtering files, that need to be archived."
for file in ${files[@]}
do
    for mountpoint in ${mountpoints[@]}
    do
        oldmp="$(echo $mountpoint | cut -d',' -f1)"
        newmp="$(echo $mountpoint | cut -d',' -f2)"
        if [[ "$file" == *"$oldmp"* ]]
        then
            newfile=$(echo $file | sed "s|${oldmp}|${newmp}|")
        fi
        founds=()
        founds+=($(find ${newfile} -type f ! -iname "*._*" ! -iname "*.Trash*" ! -iname "*.DocumentRevisions-V100" ! -iname "*.fseventsd" ! -iname "*.Spotlight*" ! -iname "*.TemporaryItems" ! -iname "*RECYCLE.BIN" ! -iname "System Volume Information" ! -iname ".DS_Store" ! -iname "desktop.ini" ! -iname "Thumbs.db" -type f))
        for found in ${founds[@]}
        do
            finds+=($found)
        done
        founds=()
    done
done
finds=($(printf "%s\n" "${finds[@]}" | sort -u))
newline

## Get files from previously run jobs
prevjournals=()
lsjournals=()
lsjournals+=($(find $workingdir -type f -name "*.journal"))
if [[ ${#lsjournals[@]} -ne 0 ]] && [[ $full -ne 1 ]]
then
    for journal in ${lsjournals[@]}
    do
        prevjournals+=("$(cat $journal)")
    done
fi
prevjournals=($(printf "%s\n" "${prevjournals[@]}" | sort -u))

## Build final list of files and write to journalfile, which will be used by bsdtar
listoffiles=()
if [[ $full -eq 1 ]]
then
    listoffiles=($(printf "%s\n" "${finds[@]}" | sort -u))
else
    for find in ${finds[@]}
    do
        for diff in ${diffs[@]}
        do
            if [[ "$find" == "$diff" ]]
            then
                listoffiles+=($find)
            fi
        done
        if [[ ${#prevjournals[@]} -gt 0 ]]
        then
            count=0
            for prevjournal in ${prevjournals[@]}
            do
                if [[ "$find" == "$prevjournal" ]]
                then
                    ((++count))
                fi
            done
            if [[ $count -eq 0 ]]
            then
                listoffiles+=($find)
            fi
        else
            listoffiles+=($find)
        fi
    done
fi
listoffiles=($(printf "%s\n" "${listoffiles[@]}" | sort -u))

## Write final listoffiles to journalfile
touch $journalfile
for file in ${listoffiles[@]}
do
    echo $file >> $journalfile
done

## Actual writing
dtbegin=$(date +%s)
write_logfile "Beginning to write the specified data to tape."

bsdtar \
--block-size $blockingfactor \
--file - \
--files-from $journalfile \
-s:^${clonemp}/:: \
--totals \
--verbose \
--verbose \
--create \
2> $indexfile | \
zstd \
--quiet \
--threads=$cores | \
mbuffer -q \
-s $blocksize \
-m 25% \
-P 90 \
--tapeaware \
-o $tapedev

dtend=$(date +%s)
write_logfile "Finished writing data to tape."
duration=$((dtend - $dtbegin))
durationh=$(date -u -r $duration "+%H Hours %M Minutes %S Seconds")
write_logfile "This took $durationh."
newline
write_volfile $nextfile $dt

# Save drive temperature, TapeAlert flags and error counter log
drivetemp=$(smartctl7.3 -A /dev/pass2 | grep --color=never 'Current Drive Temperature' | grep --color=never --only-matching --extended-regexp '[0-9]+')
errorcounterlog=$(smartctl7.3 -l error /dev/pass2 | grep --color=never --after-context=5 'Error counter log')
tapealert=$(smartctl7.3 -l tapealert /dev/pass2 | grep --color=never TapeAlert | awk '{print $2}')

# Create checksums and write them to sumsfile
touch $sumsfile
if [[ -s $journalfile ]]
then
    dtbegin=$(date +%s)
    write_logfile "Calculating checksums. This can take some time."
    cat $journalfile | parallel --silent --jobs $cores xxhsum --quiet -H3 {} ::: | sort > $sumsfile
    dtend=$(date +%s)
    duration=$((dtend - $dtbegin))
    durationh=$(date -u -r $duration "+%H Hours %M Minutes %S Seconds")
    write_logfile "Checksums written."
    write_logfile "This took $durationh."
    newline
fi

# Write S.M.A.R.T. infos into logfile
touch $errorfile
if [[ $tapealert == 'OK' ]]
then
    write_logfile "The drives TapeAlert flags reported no error."
else
    write_logfile "The drives TapeAlert flags reported an error. File cohesion on the tape is not guaranteed. Please check."
fi
newline
write_logfile "The drive had a temperature of $drivetemp °C after writing completed."
newline
write_errorfile

# Unmount, release and destroy dataset
write_logfile "Unmounting and destroying the cloned ZFS snapshots."
for dataset in ${datasets[@]}
do
    zfs unmount ${clone}
    zfs destroy ${clone}
    if [[ $prevsnap != "" ]]
    then
        zfs release yatar ${prevsnap}
        zfs destroy ${prevsnap}
    fi
done
newline

# Eject the tape if specified
if [[ $eject -eq 1 ]]
then
    write_logfile "Ejecting tape as requested."
    mt -f $tapedev rewoffl
    newline
fi


# Finish
write_logfile "All done!"
newline
dth=$(date)
write_logfile "$dth - Finished job run."


# Cleanup
rm $pidfile
