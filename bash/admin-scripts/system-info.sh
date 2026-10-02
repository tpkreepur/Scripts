#!/usr/bin/env bash
set -u
export LC_ALL=C

if ! command -v dmidecode >/dev/null 2>&1; then
    echo "Error: dmidecode is required. Install it with: apt install dmidecode" >&2
    exit 1
fi

if [ "$(id -u)" -eq 0 ]; then
    DMI=(dmidecode)
elif command -v sudo >/dev/null 2>&1; then
    DMI=(sudo dmidecode)
else
    echo "Error: run as root or install sudo." >&2
    exit 1
fi

if ! "${DMI[@]}" -s system-product-name >/dev/null 2>&1; then
    echo "Error: unable to read DMI data. Run as root or configure sudo." >&2
    exit 1
fi

if [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
    RUN_USER="$SUDO_USER"
else
    RUN_USER="$(id -un)"
fi

RUN_HOME="$(getent passwd "$RUN_USER" | cut -d: -f6)"
RUN_HOME="${RUN_HOME:-${HOME:-/tmp}}"
[ -d "$RUN_HOME" ] || RUN_HOME="${HOME:-/tmp}"
OUT_FILE="${RUN_HOME}/SYSTEM-INFO.md"

trim() { sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'; }
md_escape() { sed 's/|/\\|/g'; }

dmi_get() {
    local value
    value=$("${DMI[@]}" -s "$1" 2>/dev/null | head -n1 | trim)
    case "$value" in
        ""|"Unknown"|"Not Specified"|"To Be Filled By O.E.M."|"Default string"|"Not Applicable"|"None"|"N/A")
            printf 'Unknown'
            ;;
        *)
            printf '%s' "$value"
            ;;
    esac
}

product="$(dmi_get system-product-name)"
vendor="$(dmi_get system-manufacturer)"
model="$(dmi_get system-version)"

if [ "$model" = "Unknown" ]; then
    model="$(dmi_get baseboard-product-name)"
fi

bios="$(dmi_get bios-version)"

cpu_model=""
sockets=1
cores=1

if command -v lscpu >/dev/null 2>&1; then
    cpu_model="$(lscpu 2>/dev/null | awk -F': *' '/^Model name:/ {print $2; exit}' | trim)"
    sockets="$(lscpu 2>/dev/null | awk -F': *' '/^Socket\(s\):/ {gsub(/[[:space:]]/, "", $2); print $2; exit}')"
    cores="$(lscpu 2>/dev/null | awk -F': *' '/^Core\(s\) per socket:/ {gsub(/[[:space:]]/, "", $2); print $2; exit}')"
fi

if [ -z "$cpu_model" ]; then
    cpu_model="$(grep -m1 '^model name' /proc/cpuinfo | cut -d: -f2- | trim)"
fi

[[ "$sockets" =~ ^[0-9]+$ ]] || sockets=1
[[ "$cores" =~ ^[0-9]+$ ]] || cores=1
physical_cores=$(( sockets * cores ))

case "$physical_cores" in
    1) core_word="Single" ;;
    2) core_word="Dual" ;;
    3) core_word="Triple" ;;
    4) core_word="Quad" ;;
    6) core_word="Six" ;;
    8) core_word="Eight" ;;
    10) core_word="Ten" ;;
    12) core_word="Twelve" ;;
    16) core_word="Sixteen" ;;
    24) core_word="Twenty-Four" ;;
    32) core_word="Thirty-Two" ;;
    *) core_word="$physical_cores" ;;
esac

cpu="$(printf '%s' "$cpu_model" | sed -e 's/(R)//g' -e 's/(TM)//g' -e 's/(r)//g' -e 's/(tm)//g' -e 's/[[:space:]]\{1,\}/ /g' | trim)"

if [ "$physical_cores" -gt 1 ] && [[ "$cpu" == *" Core"* ]]; then
    cpu="${cpu/ Core/ $core_word Core}"
fi

[ -n "$cpu" ] || cpu="Unknown"

mem_dmi="$("${DMI[@]}" -t memory 2>/dev/null || true)"

mem_parts="$(printf '%s\n' "$mem_dmi" | awk '
BEGIN { RS=""; FS="\n" }
{
    if ($0 !~ /Memory Device/) next

    type=""; speed=""; form=""; size=""

    for (i = 1; i <= NF; i++) {
        line=$i

        if (line ~ /^[[:space:]]*Type:[[:space:]]/ && line !~ /Type Detail/) {
            sub(/^[[:space:]]*Type:[[:space:]]*/, "", line)
            type=line
        }

        if (line ~ /^[[:space:]]*Speed:[[:space:]]/ && line !~ /Configured/) {
            sub(/^[[:space:]]*Speed:[[:space:]]*/, "", line)
            speed=line
        }

        if (line ~ /^[[:space:]]*Form Factor:[[:space:]]/) {
            sub(/^[[:space:]]*Form Factor:[[:space:]]*/, "", line)
            form=line
        }

        if (line ~ /^[[:space:]]*Size:[[:space:]]/) {
            sub(/^[[:space:]]*Size:[[:space:]]*/, "", line)
            size=line
        }
    }

    if (size != "" && size !~ /No Module Installed/ && type != "" && type != "Unknown") {
        sub(/^[[:space:]]+/, "", type)
        sub(/[[:space:]]+$/, "", type)
        sub(/^[[:space:]]+/, "", speed)
        sub(/[[:space:]]+$/, "", speed)
        sub(/^[[:space:]]+/, "", form)
        sub(/[[:space:]]+$/, "", form)

        print type "|" speed "|" form
        exit
    }
}')"

IFS='|' read -r mem_type mem_speed mem_form <<< "$mem_parts"
mem_type="${mem_type:-Unknown}"
mem_speed="${mem_speed:-}"
mem_form="${mem_form:-}"

[ "$mem_speed" = "Unknown" ] && mem_speed=""
[ "$mem_form" = "Unknown" ] && mem_form=""

mem_speed="$(printf '%s' "$mem_speed" | sed -e 's/ MT\/s/ MHz/' -e 's/ mt\/s/ MHz/' | trim)"
mem_form="$(printf '%s' "$mem_form" | sed 's/SODIMM/SO-DIMM/' | trim)"

speed_num="$(printf '%s' "$mem_speed" | grep -oE '[0-9]+' | head -n1 || true)"

if [ -n "$speed_num" ]; then
    mem_speed="${speed_num} MHz"
fi

pc=""

if [ -n "$speed_num" ]; then
    case "$mem_type" in
        DDR3)
            case "$speed_num" in
                800) pc="PC3-6400" ;;
                1066) pc="PC3-8500" ;;
                1333) pc="PC3-10600" ;;
                1600) pc="PC3-12800" ;;
                1866) pc="PC3-14900" ;;
                2133) pc="PC3-17000" ;;
            esac
            ;;
        DDR4)
            case "$speed_num" in
                2133) pc="PC4-17000" ;;
                2400) pc="PC4-19200" ;;
                2666) pc="PC4-21300" ;;
                2933) pc="PC4-23400" ;;
                3200) pc="PC4-25600" ;;
            esac
            ;;
        DDR5)
            case "$speed_num" in
                4800) pc="PC5-38400" ;;
                5600) pc="PC5-44800" ;;
                6400) pc="PC5-51200" ;;
            esac
            ;;
    esac
fi

if [ "$mem_type" = "Unknown" ]; then
    memory_type="Unknown"
elif [ -n "$pc" ] && [ -n "$mem_speed" ] && [ -n "$mem_form" ]; then
    memory_type="$mem_type $pc ($mem_speed) $mem_form"
elif [ -n "$mem_speed" ] && [ -n "$mem_form" ]; then
    memory_type="$mem_type ($mem_speed) $mem_form"
elif [ -n "$mem_speed" ]; then
    memory_type="$mem_type ($mem_speed)"
elif [ -n "$mem_form" ]; then
    memory_type="$mem_type $mem_form"
else
    memory_type="$mem_type"
fi

installed="$(awk '/^MemTotal:/ {printf "%.0fGB", ($2 / 1024 / 1024) + 0.5}' /proc/meminfo)"

max="$(printf '%s\n' "$mem_dmi" | awk '
/Maximum Capacity:/ {
    line=$0
    sub(/.*Maximum Capacity:[[:space:]]*/, "", line)

    if (line ~ /[Uu]nknown/) next

    if (match(line, /[0-9.]+[[:space:]]*[TtGgMmKk][Bb]/)) {
        token=substr(line, RSTART, RLENGTH)

        match(token, /[0-9.]+/)
        val=substr(token, RSTART, RLENGTH) + 0

        unit=substr(token, RSTART + RLENGTH)
        gsub(/[[:space:]]/, "", unit)
        unit=toupper(unit)

        if (unit ~ /^TB/) sum += val * 1024
        else if (unit ~ /^GB/) sum += val
        else if (unit ~ /^MB/) sum += val / 1024
        else if (unit ~ /^KB/) sum += val / 1024 / 1024

        found=1
    }
}
END {
    if (found) printf "%.0fGB", sum
}')"

[ -n "$max" ] || max="$installed"

{
    echo "### Hardware Information"
    echo
    echo "|||"
    echo "|:---|:--|"
    echo "|**Product Name**:|$(printf '%s' "$product" | md_escape)|"
    echo "|**Vendor**:|$(printf '%s' "$vendor" | md_escape)|"
    echo "|**Model**:|$(printf '%s' "$model" | md_escape)|"
    echo "|**BIOS Version**:|$(printf '%s' "$bios" | md_escape)|"
    echo "|**CPU Info**:|$(printf '%s' "$cpu" | md_escape)|"
    echo
    echo "### Memory"
    echo
    echo "|||"
    echo "|:---|:--|"
    echo "|**Type**:|$(printf '%s' "$memory_type" | md_escape)|"
    echo "|**Installed Memory**:|$(printf '%s' "$installed" | md_escape)|"
    echo "|**Max Memory**:|$(printf '%s' "$max" | md_escape)|"
} > "$OUT_FILE"

if [ "$(id -u)" -eq 0 ] && [ "$RUN_USER" != "root" ]; then
    chown "$RUN_USER" "$OUT_FILE" 2>/dev/null || true
fi

echo "Created $OUT_FILE"