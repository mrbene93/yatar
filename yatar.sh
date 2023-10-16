#!/usr/local/bin/bash

# Check if script is run as root
if [[ $EUID -ne 0 ]]
then
    echo "Please run as root."
    exit 1
fi



# First batch of variables and functions
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
    new=$1
    if [[ $new -lt $current ]]      # Move backward
    then
        movenum=$((current - new + 1))
        write_logfile "Moving backward to file $1."
        mt -f $tapedev bsf $movenum
        mt -f $tapedev fsf 1
    elif [[ $new -gt $current ]]    # Move forward
    then
        movenum=$((new - current))
        write_logfile "Moving forward to file $1."
        mt -f $tapedev fsf $movenum
    fi
}



# Get supplied parameters
optstring=":f:elw:"
autoload=0
eject=0
files=''
workingdir=''
while getopts ${optstring} arg
do
    case ${arg} in
        f)  # Path to files to backup
            files=$OPTARG
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


# Second batch of variables and functions
yatardir="${workingdir}/.yatar"
excludefile="${yatardir}/exclude.txt"
snapfile="${yatardir}/incremental.snap"
cores=$(sysctl -n hw.ncpu)
blocksize=$(sysctl -n kern.cam.sa.0.maxio)
compresscmd="zstd --quiet --thread=$cores"
mbuffercmd="mbuffer -m 25% -s $blocksize -P90"
blockingfactor=$((blocksize / 512))

dt=$(date +"%Y%m%d_%H%M%S")


# Create directories and files
jobdir="${workingdir}/${dt}"
logfile="${jobdir}/${dt}.log"
indexfile="${jobdir}/${dt}.index"
sumsfile="${jobdir}/${dt}.sums"

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
mt -f $tapedev rewind
tapevendor=$(camcontrol attrib $tapedev -r attr_values -a 0x0400 -F text_esc)
tapeserial=$(camcontrol attrib $tapedev -r attr_values -a 0x0401 -F text_esc)
tapeid=${tapevendor}-${tapeserial}
tapeidontape=$(dd if=$taperewdev bs=$tapeidbs status=none 2> /dev/null)
volfile="${yatardir}/${tapeid}.vol"
mkdir -p $yatardir
touch $volfile

## Check if tape is empty or not and if it is known to yatar
if [[ -n $tapeidontape ]] && [[ ! -s $volfile ]]
then
    echo "The tape may have been written to, but it is not known by yatar."
    echo "Continuing would overwrite all contents."
    echo "Please erase the tape before using it with yatar or insert another tape."
    rm $volfile
    exit 3
fi

## Logfile header
mkdir -p $jobdir
touch $logfile
write_logfile "Starting job-run on date and time $dt."
newline
write_logfile "Path to logfile containing list of files: $indexfile"
write_logfile "Path to logfile containing checksums: $sumsfile"
write_logfile "Path to library file containing used tapes: $volfile"
write_logfile "Path to file containing incremental metadata: $snapfile"
write_logfile "Using blocksize of $blocksize Bytes."
newline

## Compare tape id in CAM to id written on tape
if [[ $tapeid != $tapeidontape ]] 
then
    write_logfile "The inserted tape is either blank or has never been written to by yatar."
    write_logfile "Writing Tape-ID to file 0 of the tape, so it can be recognized."
    echo $tapeid | dd of=$taperewdev bs=$tapeidbs status=none
    write_logfile "The tape has the ID $tapeid."
    newline
    write_volfile 0 "Tape ID"
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
write_logfile "$(date -f %s +%Y%m%d_%H%M%S $dtbegin) Beginning to write the specified data to tape."

gtar \
--blocking-factor=$blockingfactor \
--exclude-from=$excludefile \
--format=gnu \
--index-file=$indexfile \
--listed-incremental=$snapfile \
--sort=name \
--use-compress-program="zstd --quiet --threads=$cores" \
--utc \
--verbose \
--create \
"$files"

dtend=$(date +%s)
write_logfile "$(date -f %s +%Y%m%d_%H%M%S $dtend) Finished writing data to tape."
duration=$((dtend - $dtbegin))
durationh=$(date -u -r $duration "+%H Hours %M Minutes %S Seconds")
write_logfile "This took $durationh."
newline
write_volfile $nextfile $dt

# Create checksums and write them to sumsfile
write_logfile "Calculating checksums. This can take some time."
cat $indexfile | grep --color=never --invert-match '^d' | awk '{$1=$2=$3=$4=$5=""; print substr($0,6)}' | parallel --silent --jobs $cores xxhsum --quiet -H3 {} ::: | sort > $sumsfile
write_logfile "Checksums written to $sumsfile."
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
