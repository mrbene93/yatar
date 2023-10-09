# Notes
## gtar commands
gtar --blocking-factor=2048 --utc --sort=name --format=gnu --verbose --use-compress-program='zstd -T0' --index-file=<indexfile> --multi-volume --volno-file=<volno-file> --label=<label> --file=/dev/nsa0 --create ...


## zstd commands
zstd -T0 --adapt=min=3,max=9


## par2 commands
par2 create -r5 -n1 -s16777216 -t6 -T2 <file>


## split commands
split -d -b <chunk-size> - <filename>.tar.part
cat <files>.part* | tar -tvf


## mbuffer commands
mbuffer -m 25% -s <blocksize> -P90 > <outputfile>

## getopts
while getopts ${optstring} arg
do
    case ${arg} in
        w)  # working directory
            echo "Working directory."
            ;;
    esac
done
