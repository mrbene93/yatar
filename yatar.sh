#!/usr/local/bin/bash

# Check if script is run as root
if [[ $EUID -ne 0 ]]
then
    echo "Please run as root."
    exit 1
fi


# General settings
optstring=":d:w:"
cores=$(sysctl -n hw.ncpu)
tapedev='/dev/nsa0'
tapectldev='/dev/sa0.ctl'
blocksize=$(sysctl -n kern.cam.sa.0.maxio)
checksumcmd='xxhsum --quiet -H3'
compresslevel=9
compresscmd="zstd --quiet --threads=$cores --long --adapt=min=3,max=$compresslevel"
mbuffercmd="mbuffer -m 25% -s $blocksize -P90"
blockingfactor=$((blocksize / 512))
gtaropts="--blocking-factor=$blockingfactor --format=gnu --multi-volume --sort=name --use-compress-program=$compresscmd --utc --verbose"
workingdir=''
files=''


# Get supplied parameters
while getopts ${optstring} arg
do
    case ${arg} in
        d)  # Path to files to backup
            files=$OPTARG
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


