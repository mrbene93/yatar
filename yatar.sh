#!/usr/local/bin/bash

# Check if script is run as root
if [[ $EUID -ne 0 ]]
then
    echo "Please run as root."
    exit 1
fi



# First batch of variables and functions
OLDIFS=$IFS
IFS=$'\n'
tapesa=0
tapedev="/dev/nsa$tapesa"
taperewdev="/dev/sa$tapesa"
tapectldev="/dev/sa$tapesa.ctl"
ltokey='/var/keys/lto.key'

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
        f)  # Path to files to backup
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


# Second batch of variables and functions
yatardir="${workingdir}/.yatar"
excludefile="${yatardir}/exclude.txt"
cores=$(sysctl -n hw.ncpu)
blocksize=$(sysctl -n kern.cam.sa.$tapesa.maxio)
compresscmd="zstd --quiet --thread=$cores"
mbuffercmd="mbuffer -m 25% -s $blocksize -P90"
blockingfactor=$((blocksize / 512))
if [[ $full -eq 1 ]]
then
    snapfile='/dev/null'
else
    snapfile="${yatardir}/incremental.snap"
fi

dt=$(date +"%Y%m%d_%H%M%S")
dth=$(date)

# Create directories and files
jobdir="${workingdir}/${dt}"
logfile="${jobdir}/${dt}.log"
sumsfile="${jobdir}/${dt}.sums"
indexfile="${jobdir}/${dt}.index"

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
if [[ $snapfile == '/dev/null' ]]
then
    write_logfile "A full backup was requested, thus incremental snapfile is ignored."
else
    write_logfile "Path to file containing incremental metadata: $snapfile"
fi
write_logfile "Using blocksize of $blocksize Bytes."
newline

## Check if tape is empty or not and if it is known to yatar
if [[ ! -s $volfile ]]
then
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

# Creating exclude-file
cat <<EOF > $excludefile
*._*
*.Trash*
*.AppleDB
*.DocumentRevisions-V100
*.fseventsd
*.Spotlight*
*.TemporaryItems
*$RECYCLE.BIN
*System Volume Information
*.DS_Store
*desktop.ini
*Desktop.ini
*Thumbs.db
EOF


# Writing the files to tape with GNU Tar
touch $indexfile $snapfile

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

## Actual writing
dtbegin=$(date +%s)
write_logfile "Beginning to write the specified data to tape."

gtar \
--blocking-factor=$blockingfactor \
--exclude-from=$excludefile \
--file=- \
--format=gnu \
--index-file=$indexfile \
--listed-incremental=$snapfile \
--sort=name \
--use-compress-program="zstd --quiet --threads=$cores" \
--utc \
--verbose \
--create \
${files[@]} | \
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

# Create checksums and write them to sumsfile
dtbegin=$(date +%s)
write_logfile "Calculating checksums. This can take some time."
cat $indexfile | grep --color=never --invert-match '^d' | awk '{$1=$2=$3=$4=$5=""; print substr($0,6)}' | parallel --silent --jobs $cores xxhsum --quiet -H3 {} ::: | sort > $sumsfile
dtend=$(date +%s)
duration=$((dtend - $dtbegin))
durationh=$(date -u -r $duration "+%H Hours %M Minutes %S Seconds")
write_logfile "Checksums written."
write_logfile "This took $durationh."
newline


# Eject the tape if specified
if [[ $eject -eq 1 ]]
then
    write_logfile "Ejecting tape as requested."
    mt -f $tapedev rewoffl
    newline
fi

# Cleanup
rm $excludefile

# Finish
write_logfile "All done!"
newline
dth=$(date)
write_logfile "$dth - Finished job run."
