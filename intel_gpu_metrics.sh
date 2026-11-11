#!/usr/bin/env bash
#
# intel_gpu_metrics.sh — metriche GPU Intel Arc (Pro B70 e altre Arc Pro) in InfluxDB
# line protocol, per Telegraf. Gemello di nvidia_gpu_metrics.sh: stessi field di base, così
# le query/i pannelli Grafana si riusano cambiando solo il measurement; in più potenza,
# temperature, frequenza e ventola.
#
# Output: una riga per GPU, es.
#   intel_gpu,gpu_index=0,gpu_uuid=...,gpu_name=Intel(R)\ Arc(TM)\ Pro\ B70\ Graphics utilization_gpu_pct=37.5,memory_free_mib=30123.4,memory_used_mib=2644.6,memory_total_mib=32768,power_draw_w=140.2,temperature_gpu_c=65,temperature_memory_c=70,clock_graphics_mhz=2400,fan_speed_pct=55
#
# Requisiti sulla macchina con le schede:
#  - xpu-smi >= 2.0 (Intel XPU Manager; la 1.x non ha --query-gpu né supporta le B70).
#    Non è negli archivi di Ubuntu/Debian: c'è solo nel PPA Intel, e solo per Ubuntu
#    24.04 e 26.04 amd64 (non per la 25.10). Il PPA fornisce anche le dipendenze
#    (libze1, libze-intel-gpu1, libigsc1):
#      sudo add-apt-repository ppa:kobuk-team/intel-graphics
#      sudo apt update
#      sudo apt install xpu-smi          # non xpu-smi-legacy, che è la 1.3.x
#    Il PPA può essere qualche versione indietro; l'ultima è nei .deb di
#    https://github.com/intel/xpumanager/releases (xpu-smi_<ver>-1.24.04_amd64.deb o
#    ...-1.26.04_amd64.deb), da installare con "sudo apt install ./xpu-smi_*.deb"
#    dopo aver aggiunto il PPA, che serve comunque per le dipendenze.
#    Non serve il demone xpumd: xpu-smi 2.x legge direttamente da Level Zero.
#  - l'utente di Telegraf deve poter aprire /dev/dri/*:
#      sudo usermod -aG render,video telegraf
#  - utilization.gpu richiede CAP_PERFMON (senza, xpu-smi stampa N/A e il field manca):
#      sudo systemctl edit telegraf
#        [Service]
#        AmbientCapabilities=CAP_PERFMON
#      sudo systemctl restart telegraf
#    La capability ambient passa a bash e a xpu-smi. In alternativa
#    "sudo setcap cap_perfmon+ep $(command -v xpu-smi)", che però si perde a ogni
#    aggiornamento del pacchetto.
#
# Input Telegraf corrispondente:
#   [[inputs.exec]]
#     commands    = ["/usr/local/bin/intel_gpu_metrics.sh"]
#     data_format = "influx"
#     timeout     = "10s"   # deve superare XPUSMI_TIMEOUT + 2 s (kill-after)
#
# Exit code: 0 = almeno una GPU letta; 1 = errore (messaggio su stderr, finisce nel log di Telegraf).

set -euo pipefail

MEASUREMENT=intel_gpu
XPUSMI_TIMEOUT=5   # secondi (init di Level Zero + finestra di campionamento di 200 ms)

# "<campo xpu-smi>=<nome field InfluxDB>"; elenco completo: xpu-smi --query-gpu (senza argomenti)
#  - utilization.gpu: % di tempo attivo delle EU (o, se non disponibile, del motore più
#    occupato), misurata da xpu-smi su una finestra di 200 ms: è un campione, non la
#    media sull'intervallo di Telegraf.
#  - i valori di memoria arrivano in MiB, anche con decimali.
METRICS=(
    "utilization.gpu=utilization_gpu_pct"
    "memory.free=memory_free_mib"
    "memory.used=memory_used_mib"
    "memory.total=memory_total_mib"
    # campi solo Intel (lo script NVIDIA non li ha); se la scheda non ne fornisce
    # uno, xpu-smi stampa N/A e quel field manca dalla riga:
    "power.draw=power_draw_w"                    # potenza di tutta la scheda (dominio card, W)
    "temperature.gpu=temperature_gpu_c"          # temperatura del core (°C)
    "temperature.memory=temperature_memory_c"    # temperatura della VRAM (°C)
    "clocks.current.graphics=clock_graphics_mhz" # frequenza attuale (MHz)
    "fan.speed=fan_speed_pct"                    # ventola, % del massimo (xpu-smi non dà gli RPM)
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

command -v xpu-smi >/dev/null 2>&1 || die "xpu-smi non trovato nel PATH"

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

# senza --id xpu-smi interroga tutte le GPU; stdout non è un terminale, quindi
# l'output è CSV (non la tabella allineata)
out=$(timeout -k 2 "$XPUSMI_TIMEOUT" xpu-smi --query-gpu="$query" --format=csv,noheader,nounits) \
    || die "xpu-smi fallito (exit $?; 124 = timeout; serve xpu-smi >= 2.0)"
[[ -n $out ]] || die "xpu-smi non ha restituito alcuna GPU"

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
    # per campo e nessun conflitto di tipo in InfluxDB; N/A scartati.
    # xpu-smi formatta i double nella forma più corta, che può essere esponenziale
    # (es. 1e+05): il line protocol la accetta.
    fields=
    for (( k = 0; k < nm; k++ )); do
        v=$(trim "${col[k+2]}")
        if [[ $v =~ ^-?[0-9]+([.][0-9]+)?([eE][-+]?[0-9]+)?$ ]]; then
            fields+=${fields:+,}${fnames[k]}=$v
        fi
    done
    if [[ -z $fields ]]; then
        warn "GPU $idx: nessun valore numerico"
        continue
    fi

    timestamp=$(/bin/date +%s)

    printf '%s,gpu_index=%s,gpu_uuid=%s,gpu_name=%s %s %d\n' "$MEASUREMENT" \
        "$idx" "$(esc_tag "$uuid")" "$(esc_tag "$name")" "$fields" "${timestamp}000000000"
    emitted=$((emitted + 1))
done <<< "$out"

(( emitted > 0 )) || die "nessuna metrica prodotta"
