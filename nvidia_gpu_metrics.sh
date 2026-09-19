#!/usr/bin/env bash
#
# gpu_metrics.sh — metriche GPU NVIDIA in InfluxDB line protocol, per Telegraf.
#
# Output: una riga per GPU, es.
#   nvidia_gpu,gpu_index=0,gpu_uuid=GPU-...,gpu_name=NVIDIA\ GeForce\ RTX\ 4060\ Ti utilization_gpu_pct=37,memory_free_mib=14982,memory_used_mib=1068,memory_total_mib=16380
#
# Input Telegraf corrispondente:
#   [[inputs.exec]]
#     commands    = ["/usr/local/bin/gpu_metrics.sh"]
#     data_format = "influx"
#     timeout     = "10s"   # deve superare NVSMI_TIMEOUT + 2 s (kill-after)
#
# Exit code: 0 = almeno una GPU letta; 1 = errore (messaggio su stderr, finisce nel log di Telegraf).

set -euo pipefail

MEASUREMENT=nvidia_gpu
NVSMI_TIMEOUT=5   # secondi

# "<campo nvidia-smi>=<nome field InfluxDB>"; altri campi: nvidia-smi --help-query-gpu
#  - utilization.gpu: % di tempo con almeno un kernel attivo nell'ultimo periodo di
#    campionamento del driver (tra 1/6 e 1 s): è un campione, non la media sull'intervallo di Telegraf.
#  - con driver recenti free + used < total: la differenza è memoria riservata a
#    driver/firmware (campo memory.reserved).
METRICS=(
    "utilization.gpu=utilization_gpu_pct"
    "memory.free=memory_free_mib"
    "memory.used=memory_used_mib"
    "memory.total=memory_total_mib"
)

prog=${0##*/}
warn() { printf '%s: %s\n' "$prog" "$*" >&2; }
die()  { warn "$*"; exit 1; }

# rimuove spazi iniziali e finali
trim() {
    local s=$1
    s=${s#"${s%%[![:space:]]*}"}
    printf '%s' "${s%"${s##*[![:space:]]}"}"
}

# escape di un tag value nel line protocol: virgola, spazio, uguale
esc_tag() {
    local s=$1
    s=${s//,/\\,}
    s=${s// /\\ }
    s=${s//=/\\=}
    printf '%s' "$s"
}

command -v nvidia-smi >/dev/null 2>&1 || die "nvidia-smi non trovato nel PATH"

# query: index, uuid, metriche, name — name per ultimo, così un'eventuale
# virgola nel nome non sposta le altre colonne
query=index,uuid
fnames=()
for m in "${METRICS[@]}"; do
    query+=",${m%%=*}"
    fnames+=("${m#*=}")
done
query+=,name
nm=${#fnames[@]}

out=$(timeout -k 2 "$NVSMI_TIMEOUT" nvidia-smi --query-gpu="$query" --format=csv,noheader,nounits) \
    || die "nvidia-smi fallito (exit $?; 124 = timeout)"
[[ -n $out ]] || die "nvidia-smi non ha restituito alcuna GPU"

emitted=0
while IFS= read -r line; do
    [[ -n $line ]] || continue
    IFS=',' read -r -a col <<< "$line"
    idx=$(trim "${col[0]-}")
    uuid=$(trim "${col[1]-}")
    name=$(IFS=,; trim "${col[*]:nm+2}")
    if (( ${#col[@]} < nm + 3 )) || [[ ! $idx =~ ^[0-9]+$ || -z $uuid || -z $name ]]; then
        warn "riga non riconosciuta: $line"
        continue
    fi

    # tutti i valori come float (senza suffisso "i"): nessun tipo da dichiarare
    # per campo e nessun conflitto di tipo in InfluxDB; [N/A], [Not Supported] scartati
    fields=
    for (( k = 0; k < nm; k++ )); do
        v=$(trim "${col[k+2]}")
        if [[ $v =~ ^-?[0-9]+([.][0-9]+)?$ ]]; then
            fields+=${fields:+,}${fnames[k]}=$v
        fi
    done
    if [[ -z $fields ]]; then
        warn "GPU $idx: nessun valore numerico"
        continue
    fi

    printf '%s,gpu_index=%s,gpu_uuid=%s,gpu_name=%s %s\n' "$MEASUREMENT" \
        "$idx" "$(esc_tag "$uuid")" "$(esc_tag "$name")" "$fields"
    emitted=$((emitted + 1))
done <<< "$out"

(( emitted > 0 )) || die "nessuna metrica prodotta"
