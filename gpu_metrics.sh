#!/bin/bash
set -uo pipefail

host=$(/bin/hostname -s)
host=${host//,/\\,}     # MacStudio16,9 -> MacStudio16\,9

# campione singolo da 900 ms, solo sampler GPU
out=$(/usr/bin/powermetrics --samplers gpu_power -i 900 -n 1 2>/dev/null)

util=$(printf '%s\n' "$out" | awk -F'[:%]' '/GPU HW active residency/{gsub(/ /,"",$2);print $2;exit}')
freq=$(printf '%s\n' "$out" | awk -F'[: ]+'  '/GPU HW active frequency/{print $5;exit}')
power=$(printf '%s\n' "$out" | awk -F'[: ]+' '/GPU Power/{print $3;exit}')

util=${util:-0}; freq=${freq:-0}; power=${power:-0}

printf 'gpu,host=%s utilization=%s,frequency_mhz=%s,power_mw=%s\n' \
       "$host" "$util" "$freq" "$power"
