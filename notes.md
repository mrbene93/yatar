# Notes
## gtar commands
gtar --blockind-factor=2048 --utc --sort=name --format=gnu --verbose --use-compress-program='zstd -T0' --index-file=<indexfile> --multi-volume --volno-file=<volno-file> --label=<label> --file=/dev/nsa0 --create ...


## par2 commands
par2 create -r5 -n1 -s16777216 -t6 -T2 <file>


## split commands
split -d -b <chunk-size> - <filename>.tar.part
cat <files>.part* | tar -tvf
