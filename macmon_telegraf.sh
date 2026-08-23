#!/usr/bin/env bash
#
# macmon_telegraf.sh — macmon -> InfluxDB line protocol su stdout, per Telegraf.
#
#   (default)      un campione, stampa, esce   -> [[inputs.exec]]
#   --stream       stream continuo             -> [[inputs.execd]]
#   --power-only   solo measurement *_power
#   -i MS          finestra di campionamento (default 1000)
#   -H TAG         override del tag host
#   -p PREFIX      prefisso measurement (default "mac")
#
# Env: MACMON_INTERVAL_MS, MACMON_HOST_TAG, MACMON_PREFIX
# Dipendenze: macmon, jq (>= 1.6)
#
set -uo pipefail

sudo sed -i '' '/^set -uo pipefail$/a\
export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:$PATH"
' /usr/local/bin/macmon_telegraf.sh

INTERVAL_MS="${MACMON_INTERVAL_MS:-1000}"
RAW_HOST="${MACMON_HOST_TAG:-$(hostname -s 2>/dev/null || echo unknown)}"
RAW_PREFIX="${MACMON_PREFIX:-mac}"
STREAM=0
PO_JSON=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stream)      STREAM=1; shift ;;
    --power-only)  PO_JSON=true; shift ;;
    -i|--interval) INTERVAL_MS="${2:-}"; shift 2 ;;
    -H|--host-tag) RAW_HOST="${2:-}"; shift 2 ;;
    -p|--prefix)   RAW_PREFIX="${2:-}"; shift 2 ;;
    -h|--help)     grep '^#' "$0" | cut -c3-; exit 0 ;;
    *) printf 'macmon_telegraf: opzione sconosciuta: %s\n' "$1" >&2; exit 2 ;;
  esac
done

# Sanitizzazione tag/measurement: il ComputerName macOS puo' contenere virgole e
# spazi (es. "MacBookAir16,12 M4"), che rompono il line protocol.
HOST_TAG="$(printf '%s' "$RAW_HOST" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_')"
PREFIX="$(printf '%s'  "$RAW_PREFIX" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_')"
[[ -n "$HOST_TAG" ]] || HOST_TAG=unknown
[[ -n "$PREFIX"   ]] || PREFIX=mac

for bin in macmon jq; do
  command -v "$bin" >/dev/null 2>&1 \
    || { printf 'macmon_telegraf: %s non trovato nel PATH (%s)\n' "$bin" "$PATH" >&2; exit 1; }
done

[[ "$INTERVAL_MS" =~ ^[0-9]+$ ]] && (( INTERVAL_MS >= 100 )) \
  || { printf 'macmon_telegraf: intervallo non valido: %s\n' "$INTERVAL_MS" >&2; exit 2; }

# --- costruzione argv: -i/--interval non e' garantito su tutte le versioni ---
if (( STREAM )); then
  MACMON_ARGS=(pipe)          # senza -s: campionamento continuo
else
  MACMON_ARGS=(pipe -s 1)
fi
if macmon pipe --help 2>&1 | grep -qE '(^|[[:space:]])(-i,|--interval)'; then
  MACMON_ARGS+=(-i "$INTERVAL_MS")
fi

# --- traduttore JSON -> line protocol ---------------------------------------
# Il timestamp ns e' costruito come stringa: un double non rappresenta
# esattamente 1.8e18 e jq lo stamperebbe in notazione scientifica.
read -r -d '' JQ_PROG <<'EOF'
def pad3: tostring | ("00" + .) | .[-3:];
def r6:   (. * 1e6 | round) / 1e6;
def fl($k; $v): if ($v|type) == "number" then ["\($k)=\($v|r6)"]        else [] end;
def it($k; $v): if ($v|type) == "number" then ["\($k)=\($v|floor)i"]    else [] end;
def at($a; $i): if (($a|type) == "array") and (($a|length) > $i) then $a[$i] else null end;

def ts_ns:
  ( [ (.timestamp // "")
      | capture("^(?<b>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(?<f>\\.[0-9]+)?(?<o>Z|[+-][0-9]{2}:[0-9]{2})?$")
    ] | .[0] ) as $c
  | if $c == null then
      ( now as $n | "\($n|floor)\(((($n - ($n|floor)) * 1000)|floor|pad3))000000" )
    else
      ( ($c.b + "Z") | fromdateiso8601 ) as $base
      | ( if (($c.f // "") == "") then 0 else ($c.f | tonumber) end ) as $frac
      | ( if (($c.o // "Z") == "Z") then 0
          else ( (($c.o[1:3]|tonumber) * 3600) + (($c.o[4:6]|tonumber) * 60) )
               * (if ($c.o[0:1] == "-") then -1 else 1 end)
          end ) as $off
      | "\($base - $off)\(($frac * 1000)|floor|pad3)000000"
    end;

. as $d
| (ts_ns) as $ts
| "host=\($host),source=macmon" as $tags
| ( fl("sys_power";     $d.sys_power)
  + fl("all_power";     $d.all_power)
  + fl("cpu_power";     $d.cpu_power)
  + fl("gpu_power";     $d.gpu_power)
  + fl("ane_power";     $d.ane_power)
  + fl("ram_power";     $d.ram_power)
  + fl("gpu_ram_power"; $d.gpu_ram_power)
  ) as $pw
| ( fl("cpu_usage";     $d.cpu_usage_pct)
  + fl("ecpu_freq_mhz"; at($d.ecpu_usage; 0))
  + fl("ecpu_usage";    at($d.ecpu_usage; 1))
  + fl("pcpu_freq_mhz"; at($d.pcpu_usage; 0))
  + fl("pcpu_usage";    at($d.pcpu_usage; 1))
  + fl("gpu_freq_mhz";  at($d.gpu_usage;  0))
  + fl("gpu_usage";     at($d.gpu_usage;  1))
  + it("ram_total";     $d.memory.ram_total)
  + it("ram_usage";     $d.memory.ram_usage)
  + it("swap_total";    $d.memory.swap_total)
  + it("swap_usage";    $d.memory.swap_usage)
  ) as $soc
| ( fl("cpu_temp_c"; $d.temp.cpu_temp_avg)
  + fl("gpu_temp_c"; $d.temp.gpu_temp_avg)
  ) as $th
| [ (if ($pw|length) > 0
       then "\($pfx)_power,\($tags) \($pw|join(",")) \($ts)"   else empty end),
    (if ($power_only|not) and (($soc|length) > 0)
       then "\($pfx)_soc,\($tags) \($soc|join(",")) \($ts)"    else empty end),
    (if ($power_only|not) and (($th|length) > 0)
       then "\($pfx)_thermal,\($tags) \($th|join(",")) \($ts)" else empty end)
  ] | .[]
EOF

JQ_ARGS=(-r --arg host "$HOST_TAG" --arg pfx "$PREFIX" --argjson power_only "$PO_JSON")

if (( STREAM )); then
  trap 'exit 0' INT TERM
  macmon "${MACMON_ARGS[@]}" 2>/dev/null | jq --unbuffered "${JQ_ARGS[@]}" "$JQ_PROG"
  rc=${PIPESTATUS[0]}
  printf 'macmon_telegraf: stream terminato (macmon exit %s)\n' "$rc" >&2
  exit $(( rc == 0 ? 1 : rc ))    # exit != 0: fa scattare restart_delay di execd
else
  # bufferizzato: se jq fallisce a meta' non emettiamo righe tronche a Telegraf
  out="$(macmon "${MACMON_ARGS[@]}" 2>/dev/null | jq "${JQ_ARGS[@]}" "$JQ_PROG" 2>&1)"
  rc=$?
  if (( rc != 0 )) || [[ -z "$out" ]]; then
    printf 'macmon_telegraf: nessuna metrica (rc=%s): %s\n' "$rc" "${out:-vuoto}" >&2
    exit 1
  fi
  printf '%s\n' "$out"
fi
