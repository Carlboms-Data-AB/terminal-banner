#!/usr/bin/env bash
#
# setup.sh - install a custom, dynamic terminal banner (MOTD) on Linux.
#
# Local by default: after install nothing is fetched (optional sync mode pulls the
# banner from a repo on a timer). The banner lives in /etc/terminal-banner/message
# on the host - a TEMPLATE with {{TOKENS}} that the renderer fills in with this
# host's live values at display time, plus {{COLOUR}} tokens for styling. Edit
# that file on the box and the change is immediate; re-running this installer
# never overwrites it.
#
# The renderer is installed once and treats the template as DATA (string
# substitution, no eval), stripping the ESC control byte so ANSI/OSC escape
# sequences can't render. See README for the token catalogue and security model.
#
# ONE command, no flags: run it in a terminal and you get a menu (install / edit /
# preview / uninstall). Piped with no terminal (automation), it just installs.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/Carlboms-Data-AB/terminal-banner/main/setup.sh | sudo bash
#
# After installing, reopen the menu on the host (no network) with:
#   sudo terminal-banner
#
set -euo pipefail

# ---- Configuration ----------------------------------------------------------

CONF_DIR=/etc/terminal-banner
CONF_FILE="$CONF_DIR/welcome.conf"         # legacy synced-install config - removed on install
CACHE_DIR=/var/lib/terminal-banner        # optional cache for {{PUBIP}}/{{UPDATES}}
STATE="$CONF_DIR/message"                  # the LOCAL template - edit this on the host
MOTD_BACKUP="$CONF_DIR/motd.orig"
DISABLED_LIST="$CONF_DIR/disabled-motd.d"
UPDATER=/usr/local/sbin/terminal-banner-update   # legacy sync job - removed on install
RENDERER=/usr/local/sbin/terminal-banner-render
LOCAL_UNINSTALL=/usr/local/sbin/terminal-banner-uninstall   # self-contained local remover (no network)
LAUNCHER=/usr/local/sbin/terminal-banner                    # the local menu (edit / preview / uninstall)
MOTDD_SCRIPT=/etc/update-motd.d/00-welcome
MOTDD_LEGACY=/etc/update-motd.d/00-carlboms-welcome   # pre-rename installs
PROFILE_SNIPPET=/etc/profile.d/zz-terminal-banner.sh
BASHRC=/etc/bash.bashrc
SVC=/etc/systemd/system/terminal-banner.service
TIMER=/etc/systemd/system/terminal-banner.timer
CRON=/etc/cron.d/terminal-banner
HOOK_MARK="# >>> terminal-banner hook >>>"

# GitHub-sync mode (optional, chosen from the menu): pull the banner from the repo
# on a timer. Local mode (the default) never touches these.
REPO_RAW="https://raw.githubusercontent.com/Carlboms-Data-AB/terminal-banner/main"
SYNC_URL="${TW_SYNC_URL:-$REPO_RAW/message.txt}"
SYNC_INTERVAL=15

[[ $EUID -eq 0 ]] || { echo "ERROR: run as root (sudo bash setup.sh)" >&2; exit 1; }

has_systemd() { [[ -d /run/systemd/system ]]; }
use_update_motd_d() { [[ -d /etc/update-motd.d ]]; }

# ---- Uninstall --------------------------------------------------------------

uninstall_body() {
    echo "Removing terminal-banner ..."
    if has_systemd; then
        systemctl disable --now terminal-banner.timer 2>/dev/null || true
        rm -f "$TIMER" "$SVC"; systemctl daemon-reload 2>/dev/null || true
    fi
    rm -f "$CRON" "$UPDATER" "$RENDERER" "$LOCAL_UNINSTALL" "$LAUNCHER" "$PROFILE_SNIPPET" "$MOTDD_SCRIPT" "$MOTDD_LEGACY"

    if [[ -f "$BASHRC" ]] && grep -qF "$HOOK_MARK" "$BASHRC"; then
        sed -i "/$(printf '%s' "$HOOK_MARK" | sed 's/[.[*^$/]/\\&/g')/,/# <<< terminal-banner hook <<</d" "$BASHRC"
    fi
    if [[ -f "$DISABLED_LIST" ]]; then
        while IFS= read -r f; do [[ -e "$f" ]] && chmod +x "$f"; done < "$DISABLED_LIST"
    fi
    # Restore the original /etc/motd (regular file copy, or recreate a symlink).
    if [[ -f "$MOTD_BACKUP" ]]; then
        if IFS= read -r first < "$MOTD_BACKUP" && [[ "$first" == symlink\ -\>\ * ]]; then
            rm -f /etc/motd; ln -s "${first#symlink -> }" /etc/motd
        else
            rm -f /etc/motd; cp -a "$MOTD_BACKUP" /etc/motd
        fi
    fi
    rm -rf "$CONF_DIR" "$CACHE_DIR"
    echo "Done."
}

# ---- GitHub sync (optional; chosen from the menu) ---------------------------

remove_sync() {
    if has_systemd; then systemctl disable --now terminal-banner.timer 2>/dev/null || true; fi
    rm -f "$TIMER" "$SVC" "$CRON" "$UPDATER" "$CONF_FILE"
    if has_systemd; then systemctl daemon-reload 2>/dev/null || true; fi
    return 0
}

install_sync() {
    cat > "$CONF_FILE" <<EOF
# terminal-banner sync config - managed by the installer.
MESSAGE_URL="$SYNC_URL"
RENDER_TO_MOTD=$RENDER_TO_MOTD
EOF
    chmod 0644 "$CONF_FILE"

    cat > "$UPDATER" <<'UPD_EOF'
#!/bin/sh
# terminal-banner-update - pull the banner from GitHub (DATA only) and refresh
# cached values. Fails safe when offline (keeps the last banner).
set -eu
CONF=/etc/terminal-banner/welcome.conf
[ -r "$CONF" ] && . "$CONF"
: "${MESSAGE_URL:?MESSAGE_URL not set}"
STATE=/etc/terminal-banner/message
CACHE=/var/lib/terminal-banner
RENDERER=/usr/local/sbin/terminal-banner-render
mkdir -p "$CACHE"
tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
if command -v curl >/dev/null 2>&1; then
    curl -fsSL --max-time 15 --retry 2 "$MESSAGE_URL" -o "$tmp" 2>/dev/null && ok=1 || ok=0
elif command -v wget >/dev/null 2>&1; then
    wget -q -T 15 -t 2 -O "$tmp" "$MESSAGE_URL" && ok=1 || ok=0
else ok=0; fi
if [ "$ok" = 1 ]; then
    LC_ALL=C tr -cd '\11\12\40-\176\200-\377' < "$tmp" > "$STATE.new" && mv -f "$STATE.new" "$STATE"
    chmod 0644 "$STATE"
fi
p=$(curl -fs --max-time 4 https://api.ipify.org 2>/dev/null || true)
case "$p" in ''|*[!0-9.]*) : ;; *) printf '%s' "$p" > "$CACHE/pubip" ;; esac
if [ -x /usr/lib/update-notifier/apt-check ]; then u=$(/usr/lib/update-notifier/apt-check 2>&1 | cut -d';' -f1)
elif command -v apt-get >/dev/null 2>&1; then u=$(apt-get -s upgrade 2>/dev/null | awk '/^Inst/{c++}END{print c+0}')
else u=0; fi
case "$u" in ''|0) : > "$CACHE/updates" ;; *) printf '%s updates' "$u" > "$CACHE/updates" ;; esac
if [ "${RENDER_TO_MOTD:-false}" = "true" ] && [ -x "$RENDERER" ] && [ -r "$STATE" ]; then
    [ -L /etc/motd ] && rm -f /etc/motd
    "$RENDERER" > /etc/motd.new 2>/dev/null && mv -f /etc/motd.new /etc/motd && chmod 0644 /etc/motd
fi
UPD_EOF
    chmod 0755 "$UPDATER"; chown root:root "$UPDATER"

    if has_systemd; then
        rm -f "$CRON"
        cat > "$SVC" <<EOF
[Unit]
Description=Sync terminal banner from GitHub
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=$UPDATER
EOF
        cat > "$TIMER" <<EOF
[Unit]
Description=Periodically sync the terminal banner
[Timer]
OnBootSec=1min
OnUnitActiveSec=${SYNC_INTERVAL}min
RandomizedDelaySec=60
[Install]
WantedBy=timers.target
EOF
        systemctl daemon-reload
        systemctl enable --now terminal-banner.timer
    elif command -v crontab >/dev/null 2>&1 || [ -d /etc/cron.d ] || mkdir -p /etc/cron.d 2>/dev/null; then
        rm -f "$SVC" "$TIMER"
        printf '*/%s * * * * root %s >/dev/null 2>&1\n' "$SYNC_INTERVAL" "$UPDATER" > "$CRON"
        chmod 0644 "$CRON"
    fi
    "$UPDATER" || echo "WARNING: initial sync failed - will retry on schedule." >&2
}

# ---- Install (one action of the menu) ---------------------------------------

do_install() {
local mode="${1:-local}"
RENDER_TO_MOTD=true
use_update_motd_d && RENDER_TO_MOTD=false

# Soft dependency check - tokens degrade to blank, but tell the user what's missing.
missing=''
for c in ip ss awk sed; do command -v "$c" >/dev/null 2>&1 || missing="$missing $c"; done
[[ -n "$missing" ]] && echo "NOTE: missing tools (some tokens will be blank):$missing" \
    "- install iproute2 / procps / coreutils / gawk for full output." >&2

printf '\n  \033[2mInstalling (%s)\342\200\246\033[0m\n' "$mode"
mkdir -p "$CONF_DIR" "$CACHE_DIR"

# Back up the existing /etc/motd once (records a symlink as text; copies a real file).
if [[ ! -e "$MOTD_BACKUP" ]]; then
    if [[ -L /etc/motd ]]; then printf 'symlink -> %s\n' "$(readlink /etc/motd)" > "$MOTD_BACKUP"
    elif [[ -f /etc/motd ]]; then cp -a /etc/motd "$MOTD_BACKUP"
    else : > "$MOTD_BACKUP"; fi
fi

# Seed the LOCAL template with a default ONLY if this host has none yet, so
# re-running the installer never clobbers edits you've made on the box.
if [[ ! -e "$STATE" ]]; then
    cat > "$STATE" <<'MSG_EOF'
Copyright Carlboms Data AB
----------------------------------------
 Host    : {{HOSTNAME}}
 OS      : {{OS}}
 IP      : {{IP}}
 VPN IP  : {{VPNIP}}
 CasaOS  : {{URL_WT0_PORT_80}}
 Uptime  : {{UPTIME}}
 Load    : {{LOAD1}} {{LOAD5}} {{LOAD15}}
 Disk /  : {{DISK}}
 Memory  : {{MEM}}
 Ports   : {{PORTS}}
 {{REBOOT}}
MSG_EOF
fi
chmod 0644 "$STATE"

# ---- Renderer: read the local template, substitute this host's live values,
#      read cached values for network/slow tokens, print. The template is never
#      executed (pure string substitution) so a hostile template can't run code.
cat > "$RENDERER" <<'RENDER_EOF'
#!/usr/bin/env bash
# terminal-banner-render - render the welcome banner for THIS host.
set -u
STATE=/etc/terminal-banner/message
CACHE=/var/lib/terminal-banner
[ -r "$STATE" ] || { echo "(no welcome template yet - re-run setup.sh)" >&2; exit 0; }
tpl=$(cat "$STATE")

# -- identity --
host=$(cat /proc/sys/kernel/hostname 2>/dev/null || hostname 2>/dev/null)
case "$host" in
  *.*) fqdn=$host ;;
  *)   fqdn=$(awk -v h="$host" '/^[ \t]*#/{next}{for(i=2;i<=NF;i++)if($i==h){for(j=2;j<=NF;j++)if($j~/\./){print $j;exit}}}' /etc/hosts 2>/dev/null) ;;
esac
os=$(awk -F= '$1=="PRETTY_NAME"||$1=="NAME"{v=$0;sub(/^[^=]*=/,"",v);gsub(/^["'\'']|["'\'']$/,"",v);a[$1]=v}END{print (("PRETTY_NAME" in a)?a["PRETTY_NAME"]:a["NAME"])}' /etc/os-release 2>/dev/null)
os_id=$(awk -F= '$1=="ID"{sub(/^[^=]*=/,"");gsub(/^["'\'']|["'\'']$/,"");print;exit}' /etc/os-release 2>/dev/null)
kernel=$(cat /proc/sys/kernel/osrelease 2>/dev/null || uname -r 2>/dev/null)
arch=$(uname -m 2>/dev/null)
model=$(tr -d '\0' 2>/dev/null < /sys/firmware/devicetree/base/model)
[ -n "$model" ] || model=$(tr -d '\0' 2>/dev/null < /proc/device-tree/model)
if [ -z "$model" ]; then
  mv=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null); mp=$(cat /sys/class/dmi/id/product_name 2>/dev/null)
  case "$mp" in ''|To\ be\ filled*|System\ Product\ Name|None|Default\ string|Not\ Applicable|Not\ Specified) mp= ;; esac
  case "$mv" in ''|To\ be\ filled*|System\ manufacturer|None|Default\ string) mv= ;; esac
  [ -n "$mv" ] && [ -n "$mp" ] && model="$mv $mp" || model="$mv$mp"
fi

# -- time --
date_v=$(date '+%Y-%m-%d %H:%M' 2>/dev/null)
time_v=$(date '+%H:%M' 2>/dev/null)
tz=$(cat /etc/timezone 2>/dev/null); [ -n "$tz" ] || tz=$(readlink /etc/localtime 2>/dev/null | sed 's#.*/zoneinfo/##'); [ -n "$tz" ] || tz=$(date '+%Z' 2>/dev/null)
up=$(uptime -p 2>/dev/null | sed 's/^up //')
booted=$(awk '/^btime/{print $2}' /proc/stat 2>/dev/null); [ -n "$booted" ] && booted=$(date -d "@$booted" '+%Y-%m-%d %H:%M' 2>/dev/null); [ -n "$booted" ] || booted=$(uptime -s 2>/dev/null)

# -- cpu --
cpu=$(sed -n 's/^model name[[:space:]]*: *//p' /proc/cpuinfo 2>/dev/null | head -n1)
[ -n "$cpu" ] || cpu=$(tr -d '\0' 2>/dev/null < /proc/device-tree/model)
cores=$(nproc 2>/dev/null); case "$cores" in ''|0) cores=$(grep -c '^processor' /proc/cpuinfo 2>/dev/null) ;; esac; case "$cores" in ''|0) cores='' ;; esac
load1=$(cut -d' ' -f1 /proc/loadavg 2>/dev/null); load5=$(cut -d' ' -f2 /proc/loadavg 2>/dev/null); load15=$(cut -d' ' -f3 /proc/loadavg 2>/dev/null)
temp=''
for z in /sys/class/thermal/thermal_zone*/type; do
  [ -e "$z" ] || continue
  case "$(cat "$z" 2>/dev/null)" in
    *cpu*|*soc*|*x86_pkg*|*coretemp*|*acpitz*)
      m=$(cat "${z%/type}/temp" 2>/dev/null)
      case "$m" in ''|*[!0-9-]*) : ;; *) temp=$(awk -v m="$m" 'BEGIN{printf "%.1f°C", m/1000}'); break ;; esac ;;
  esac
done
if [ -z "$temp" ] && command -v vcgencmd >/dev/null 2>&1; then
  temp=$(vcgencmd measure_temp 2>/dev/null | sed -n "s/^temp=\([0-9.]*\).*/\1°C/p")
fi
throttled=''
if command -v vcgencmd >/dev/null 2>&1; then
  tv=$(vcgencmd get_throttled 2>/dev/null | sed -n 's/^throttled=0x\([0-9A-Fa-f]*\).*/\1/p')
  if [ -n "$tv" ]; then n=$(printf '%d' "0x$tv" 2>/dev/null)
    if [ "${n:-0}" -ne 0 ] 2>/dev/null; then s=''
      [ $((n & 1)) -ne 0 ] && s="under-voltage"
      [ $((n & 4)) -ne 0 ] && s="${s:+$s, }throttled"
      [ $((n & 2)) -ne 0 ] && s="${s:+$s, }arm-capped"
      [ $((n & 8)) -ne 0 ] && s="${s:+$s, }soft-temp-limit"
      [ -n "$s" ] && throttled="{{YELLOW}}${s}{{RESET}}"
    fi
  fi
fi

# -- memory --
memory=$(awk '/^MemTotal:/{t=$2}/^MemAvailable:/{a=$2}/^MemFree:/{f=$2}END{if(t>0){u=(a!=""?t-a:t-f);printf "%d%%",u*100/t}}' /proc/meminfo 2>/dev/null)
_h='function h(k){if(k==0)return "0B";if(k>=1048576)return sprintf("%.1fGi",k/1048576);if(k>=1024)return sprintf("%.0fMi",k/1024);return sprintf("%dKi",k)}'
mem=$(awk "$_h"' /^MemTotal:/{t=$2}/^MemAvailable:/{a=$2}END{if(t>0&&a!="")printf "%s / %s",h(t-a),h(t)}' /proc/meminfo 2>/dev/null)
mem_free=$(awk "$_h"' /^MemAvailable:/{a=$2}END{if(a!="")printf "%s",h(a)}' /proc/meminfo 2>/dev/null)
swap=$(awk "$_h"' /^SwapTotal:/{t=$2}/^SwapFree:/{f=$2}END{if(t>0)printf "%s / %s",h(t-f),h(t)}' /proc/meminfo 2>/dev/null)

# -- disk (one df) --
dfl=$(df -hP / 2>/dev/null | awk 'NR==2')
disk=$(printf '%s' "$dfl" | awk '{print $5" of "$2}')
disk_free=$(printf '%s' "$dfl" | awk '{print $4}')
disk_total=$(printf '%s' "$dfl" | awk '{print $2}')

# -- network (one route lookup) --
route=$(ip -o route get 1.1.1.1 2>/dev/null)
ips=$(ip -4 -o addr show scope global 2>/dev/null | awk '{split($4,a,"/");ip=a[1];ifc=$2;if(ifc~/^(lo|veth|br-|docker|virbr|cni|flannel|cali|tap)/)next;if(ip~/^169\.254\./)next;printf "%s%s (%s)",(n++?", ":""),ip,ifc}')
ip4=$(printf '%s' "$route" | awk '{for(i=1;i<=NF;i++)if($i=="src"){print $(i+1);exit}}')
ipv6=$(ip -6 -o addr show scope global 2>/dev/null | awk '$0!~/temporary/{split($4,a,"/");print a[1];exit}')
[ -n "$ipv6" ] || ipv6=$(ip -6 -o addr show scope global 2>/dev/null | awk '{split($4,a,"/");print a[1];exit}')
vpnip=$(ip -4 -o addr show 2>/dev/null | awk '{split($4,a,"/");if($2~/^(wt0|netbird)/){print a[1];exit}}')
[ -n "$vpnip" ] || vpnip=$(ip -4 -o addr show scope global 2>/dev/null | awk '{split($4,a,"/");split(a[1],o,".");if(o[1]==100&&o[2]>=64&&o[2]<=127){print a[1];exit}}')
iface=$(printf '%s' "$route" | awk '{for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);exit}}')
[ -n "$iface" ] || iface=$(ip -o route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);exit}}')
gateway=$(printf '%s' "$route" | awk '{for(i=1;i<=NF;i++)if($i=="via"){print $(i+1);exit}}')
dns=''
if command -v resolvectl >/dev/null 2>&1; then
  dns=$(timeout 2 resolvectl dns 2>/dev/null | awk '{for(i=1;i<=NF;i++)if($i~/[.:]/&&$i~/^[0-9a-fA-F:.]+$/)print $i}' | awk '!s[$0]++' | paste -sd, - | sed 's/,/, /g')
fi
[ -n "$dns" ] || dns=$(awk '/^nameserver/{print $2}' /etc/resolv.conf 2>/dev/null | grep -v '^127\.0\.0\.53$' | awk '!s[$0]++' | paste -sd, - | sed 's/,/, /g')
mac=''; [ -n "$iface" ] && mac=$(cat /sys/class/net/"$iface"/address 2>/dev/null)
# ss without -H (portable to old iproute2); skip the header row in awk instead.
ports=$(ss -tln 2>/dev/null | awk 'NR>1{print $4}' | grep -vE '^(127\.|\[::1\])' | sed 's/.*://' | grep -E '^[0-9]+$' | sort -un | paste -sd, - | sed 's/,/, /g')

# -- services --
docker=''
for eng in docker podman; do
  command -v "$eng" >/dev/null 2>&1 || continue
  if names=$(timeout 2 "$eng" ps --format '{{.Names}}' 2>/dev/null); then
    c=$(printf '%s\n' "$names" | grep -c . )
    [ "${c:-0}" -gt 0 ] && docker="$c running ($(printf '%s' "$names" | paste -sd, - | sed 's/,/, /g'))"
    break
  fi
done
failed=''
if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
  fn=$(systemctl list-units --state=failed --no-legend --plain 2>/dev/null | awk 'END{print NR+0}')
  [ "${fn:-0}" -gt 0 ] && failed="{{YELLOW}}${fn} failed unit(s){{RESET}}"
fi
# -- sessions (one who) --
whoout=$(who 2>/dev/null)
users=$(printf '%s' "$whoout" | awk 'NF{u[$1]=1}END{n=0;for(k in u)n++;if(n>0)print n}')
sessions=$(printf '%s' "$whoout" | awk 'NF{n++}END{if(n>0)print n}')
who_list=$(printf '%s' "$whoout" | awk 'NF{print $1}' | sort -u | paste -sd, - | sed 's/,/, /g')
reboot=''
if [ -f /run/reboot-required ] || [ -f /var/run/reboot-required ]; then
  reboot='{{RED}}*** System restart required ***{{RESET}}'
elif command -v needs-restarting >/dev/null 2>&1 && ! timeout 3 needs-restarting -r >/dev/null 2>&1; then
  reboot='{{RED}}*** System restart required ***{{RESET}}'
fi

# -- cached (optional): {{PUBIP}}/{{UPDATES}}, empty unless you enable a refresh cron (see README) --
pubip=$(cat "$CACHE/pubip" 2>/dev/null)
updates=$(cat "$CACHE/updates" 2>/dev/null)

# Mark empty values with a sentinel byte so a line hides ONLY when its token(s)
# resolved to empty - a genuine static "Section:" header (no token) is kept.
SOH=$(printf '\001')
for _v in host fqdn os os_id kernel arch model date_v time_v tz up booted \
          cpu cores load1 load5 load15 temp throttled memory mem mem_free swap \
          disk disk_free disk_total ips ip4 ipv6 vpnip iface gateway dns mac ports \
          docker failed users sessions who_list reboot pubip updates; do
    declare -n _ref="$_v"; [ -n "$_ref" ] || _ref=$SOH; unset -n _ref
done

# -- substitute (pure string replacement; template never executed) --
out=$tpl
out=${out//'{{HOSTNAME}}'/$host};      out=${out//'{{FQDN}}'/$fqdn}
out=${out//'{{OS}}'/$os};              out=${out//'{{OS_ID}}'/$os_id}
out=${out//'{{KERNEL}}'/$kernel};      out=${out//'{{ARCH}}'/$arch}
out=${out//'{{MODEL}}'/$model}
out=${out//'{{DATE}}'/$date_v};        out=${out//'{{TIME}}'/$time_v}
out=${out//'{{TIMEZONE}}'/$tz};        out=${out//'{{UPTIME}}'/$up}
out=${out//'{{BOOTED}}'/$booted}
out=${out//'{{CPU}}'/$cpu};            out=${out//'{{CORES}}'/$cores}
out=${out//'{{LOAD}}'/$load1};         out=${out//'{{LOAD1}}'/$load1}
out=${out//'{{LOAD5}}'/$load5};        out=${out//'{{LOAD15}}'/$load15}
out=${out//'{{CPU_TEMP}}'/$temp};      out=${out//'{{THROTTLED}}'/$throttled}
out=${out//'{{MEMORY}}'/$memory};      out=${out//'{{MEM}}'/$mem}
out=${out//'{{MEM_FREE}}'/$mem_free};   out=${out//'{{SWAP}}'/$swap}
out=${out//'{{DISK}}'/$disk};          out=${out//'{{DISK_FREE}}'/$disk_free}
out=${out//'{{DISK_TOTAL}}'/$disk_total}
out=${out//'{{IP}}'/$ips};             out=${out//'{{IP4}}'/$ip4}
out=${out//'{{IPV6}}'/$ipv6};          out=${out//'{{VPNIP}}'/$vpnip}
out=${out//'{{IFACE}}'/$iface};        out=${out//'{{GATEWAY}}'/$gateway}
out=${out//'{{DNS}}'/$dns};            out=${out//'{{MAC}}'/$mac}
out=${out//'{{PORTS}}'/$ports}
out=${out//'{{DOCKER}}'/$docker};      out=${out//'{{FAILED}}'/$failed}
out=${out//'{{USERS}}'/$users};        out=${out//'{{SESSIONS}}'/$sessions}
out=${out//'{{WHO}}'/$who_list};       out=${out//'{{REBOOT}}'/$reboot}
out=${out//'{{PUBIP}}'/$pubip};        out=${out//'{{UPDATES}}'/$updates}

# -- generic, user-defined tokens resolved from the template itself --
#   {{IP_<IFACE>}}              -> that interface's IPv4  (e.g. {{IP_ETH0}}, {{IP_WG0}})
#   {{URL_<IFACE>_PORT_<PORT>}} -> a clickable service URL (443->https, 80->http, else http://ip:port)
for tok in $(printf '%s' "$out" | grep -oE '\{\{IP_[A-Z0-9]+\}\}' | sort -u); do
    ifc=$(printf '%s' "$tok" | sed -E 's/^\{\{IP_([A-Z0-9]+)\}\}$/\1/' | tr '[:upper:]' '[:lower:]')
    v=$(ip -4 -o addr show dev "$ifc" 2>/dev/null | awk '{split($4,a,"/");print a[1];exit}')
    [ -n "$v" ] || v=$SOH
    out=${out//"$tok"/$v}
done
for tok in $(printf '%s' "$out" | grep -oE '\{\{URL_[A-Z0-9]+_PORT_[0-9]+\}\}' | sort -u); do
    ifc=$(printf '%s' "$tok" | sed -E 's/^\{\{URL_([A-Z0-9]+)_PORT_[0-9]+\}\}$/\1/' | tr '[:upper:]' '[:lower:]')
    prt=$(printf '%s' "$tok" | sed -E 's/^.*_PORT_([0-9]+)\}\}$/\1/')
    hip=$(ip -4 -o addr show dev "$ifc" 2>/dev/null | awk '{split($4,a,"/");print a[1];exit}')
    v=$SOH
    if [ -n "$hip" ]; then
        case "$prt" in 443) v="https://$hip" ;; 80) v="http://$hip" ;; *) v="http://$hip:$prt" ;; esac
    fi
    out=${out//"$tok"/$v}
done

# Drop a line ONLY when a token in it resolved to empty (marked with the sentinel)
# and nothing else remains - whitespace-only, or "Label : " with an empty value.
# Static lines with no token (e.g. a "Section:" header) are always kept.
out=$(printf '%s\n' "$out" | awk -v S="$SOH" '
    { p=$0; gsub(/\{\{(RESET|BOLD|DIM|RED|GREEN|YELLOW|BLUE|MAGENTA|CYAN|WHITE)\}\}/,"",p)
      hasS=(index(p,S)>0); gsub(S,"",p)
      if (p ~ /^[[:space:]]*$/) next
      if (hasS && p ~ /:[[:space:]]*$/) next
      line=$0; gsub(S,"",line); print line }' | LC_ALL=C tr -cd '\11\12\40-\176\200-\377')

# Colour markup: this LOCAL, trusted renderer turns safe {{COLOUR}} tokens into
# SGR escapes AFTER sanitising - so no escape sequence ever travels from GitHub.
e=$(printf '\033')
c_reset="${e}[0m";  c_bold="${e}[1m";    c_dim="${e}[2m"
c_red="${e}[31m";   c_green="${e}[32m";  c_yellow="${e}[33m"
c_blue="${e}[34m";  c_magenta="${e}[35m"; c_cyan="${e}[36m"; c_white="${e}[37m"
out=${out//'{{RESET}}'/$c_reset};     out=${out//'{{BOLD}}'/$c_bold}
out=${out//'{{DIM}}'/$c_dim}
out=${out//'{{RED}}'/$c_red};         out=${out//'{{GREEN}}'/$c_green}
out=${out//'{{YELLOW}}'/$c_yellow};   out=${out//'{{BLUE}}'/$c_blue}
out=${out//'{{MAGENTA}}'/$c_magenta}; out=${out//'{{CYAN}}'/$c_cyan}
out=${out//'{{WHITE}}'/$c_white}
printf '%s%s\n\n' "$out" "$c_reset"
RENDER_EOF
chmod 0755 "$RENDERER"; chown root:root "$RENDERER"

# ---- Local uninstaller: a self-contained remover so uninstall needs no network.
#      Generated from the SAME uninstall_body the menu's Uninstall uses, with the
#      resolved paths baked in - so the two can never drift.
{ printf '#!/usr/bin/env bash\nset -u\n'
  # shellcheck disable=SC2016  # the $EUID is meant to be literal in the generated script
  printf '[[ $EUID -eq 0 ]] || { echo "run as root: sudo terminal-banner-uninstall" >&2; exit 1; }\n'
  declare -p CONF_DIR CACHE_DIR MOTD_BACKUP DISABLED_LIST UPDATER RENDERER \
             MOTDD_SCRIPT MOTDD_LEGACY PROFILE_SNIPPET BASHRC SVC TIMER CRON \
             HOOK_MARK LOCAL_UNINSTALL LAUNCHER
  declare -f has_systemd uninstall_body
  printf 'uninstall_body\n'
} > "$LOCAL_UNINSTALL"
chmod 0755 "$LOCAL_UNINSTALL"; chown root:root "$LOCAL_UNINSTALL"

# ---- No updater / sync job in local mode: nothing is fetched after install.
#      {{PUBIP}}/{{UPDATES}} are optional and refreshed only if you add the cron
#      shown in the README. Any legacy sync artifacts are removed above on install.

# ---- GUI terminal windows: render live from the shell (pam_motd never runs
#      there). Guarded so it does not double-print on SSH / console logins.
cat > "$PROFILE_SNIPPET" <<'EOF'
# terminal-banner: show the banner in desktop terminal windows (non-login
# interactive shells), where pam_motd never runs. Guarded to avoid double-print.
case $- in
  *i*)
    if [ -z "${__TW_SHOWN:-}" ] \
       && [ -n "${BASH_VERSION:-}" ] \
       && ! shopt -q login_shell \
       && [ -z "${SSH_CONNECTION:-}${SSH_TTY:-}${SSH_CLIENT:-}" ]; then
        [ -x /usr/local/sbin/terminal-banner-render ] && /usr/local/sbin/terminal-banner-render
        export __TW_SHOWN=1
    fi
    ;;
esac
EOF
chmod 0644 "$PROFILE_SNIPPET"

# Debian/Ubuntu/Arch: source the snippet for non-login interactive shells.
# (Fedora/RHEL reach /etc/profile.d/*.sh for non-login shells via /etc/bashrc.)
if [[ -f "$BASHRC" ]] && ! grep -qF "$HOOK_MARK" "$BASHRC"; then
    cat >> "$BASHRC" <<EOF
$HOOK_MARK
[ -r "$PROFILE_SNIPPET" ] && . "$PROFILE_SNIPPET"
# <<< terminal-banner hook <<<
EOF
fi

# ---- Debian/Ubuntu: render at each login via update-motd.d; disable the stock
#      banner/ad scripts (once) so ours replaces them; keep /etc/motd empty.
if use_update_motd_d; then
    if [[ ! -f "$DISABLED_LIST" ]]; then          # only on first install - keeps the ledger intact
        : > "$DISABLED_LIST"
        for f in /etc/update-motd.d/*; do
            [[ -f "$f" && -x "$f" ]] || continue
            [[ "$f" == "$MOTDD_SCRIPT" || "$f" == "$MOTDD_LEGACY" ]] && continue
            chmod -x "$f"; echo "$f" >> "$DISABLED_LIST"
        done
    fi
    rm -f "$MOTDD_LEGACY"
    printf '#!/bin/sh\nexec %s\n' "$RENDERER" > "$MOTDD_SCRIPT"; chmod 0755 "$MOTDD_SCRIPT"
    [[ -L /etc/motd ]] && rm -f /etc/motd
    : > /etc/motd
fi

# ---- Non-update-motd.d hosts (Fedora/RHEL/Arch): render the banner onto
#      /etc/motd now. It's a point-in-time snapshot there; live values still
#      show via the shell snippet in interactive terminals. update-motd.d hosts
#      (Debian/Ubuntu/RPi OS) render live at each login - no background job.
if [[ "$RENDER_TO_MOTD" == true ]]; then
    [[ -L /etc/motd ]] && rm -f /etc/motd
    "$RENDERER" > /etc/motd 2>/dev/null || true
    chmod 0644 /etc/motd 2>/dev/null || true
fi

# Turn GitHub sync on (this run) or off (local mode removes any sync job).
if [[ "$mode" == sync ]]; then install_sync; else remove_sync; fi

printf '\n'
if [[ "$mode" == sync ]]; then
    printf '  \033[32m\342\234\223 Installed\033[0m \342\200\224 syncing from %s every %s min.\n' "$SYNC_URL" "$SYNC_INTERVAL"
else
    printf '  \033[32m\342\234\223 Installed\033[0m \342\200\224 local, shows at every login.\n'
fi
printf '\n'
"$RENDERER" 2>/dev/null || true

# Install the local menu launcher so the whole thing stays one command on the
# host with no network. Built from the action functions so it can't drift.
{ printf '#!/usr/bin/env bash\nset -u\n'
  # shellcheck disable=SC2016  # $EUID is meant to be literal in the generated script
  printf '[[ $EUID -eq 0 ]] || { echo "run as root: sudo terminal-banner" >&2; exit 1; }\n'
  declare -p CONF_DIR CACHE_DIR STATE MOTD_BACKUP DISABLED_LIST UPDATER RENDERER \
             LOCAL_UNINSTALL LAUNCHER MOTDD_SCRIPT MOTDD_LEGACY PROFILE_SNIPPET \
             BASHRC SVC TIMER CRON HOOK_MARK
  declare -f has_systemd uninstall_body tw_clear tw_pause tw_header do_preview do_edit menu_local
  printf 'menu_local\n'
} > "$LAUNCHER"
chmod 0755 "$LAUNCHER"; chown root:root "$LAUNCHER"
}

# ---- Menu actions -----------------------------------------------------------

tw_clear() { command clear 2>/dev/null || printf '\033[2J\033[3J\033[H'; }
tw_pause() { printf '\n  \033[2m[enter] to continue\033[0m '; read -r _ <&3 || true; }

# Coloured ASCII header shown atop the menu.
tw_header() {
    printf '\n  \033[36m\342\224\214\342\224\200\342\224\200\342\224\200\342\224\200\342\224\200\342\224\200\342\224\200\342\224\200\342\224\220\033[0m\n'
    printf '  \033[36m\342\224\202\033[0m \033[1;32m\342\235\257_\033[0m     \033[36m\342\224\202\033[0m   \033[1;36mTERMINAL BANNER\033[0m\n'
    printf '  \033[36m\342\224\224\342\224\200\342\224\200\342\224\200\342\224\200\342\224\200\342\224\200\342\224\200\342\224\200\342\224\230\033[0m   \033[2mlive host info, shown at every login\033[0m\n\n'
}

# ONE install action: press enter = local; paste a RAW message-file URL = sync.
menu_install() {
    printf '\n  \033[1mInstall / update\033[0m\n'
    printf '  Press \033[1mEnter\033[0m for a local banner, or paste a raw message.txt URL to sync\n'
    printf '  \033[2m(e.g. https://raw.githubusercontent.com/USER/REPO/main/message.txt)\033[0m\n'
    printf '  \342\200\272 '
    read -r _u <&3 || _u=''
    case "$_u" in
        http://*|https://*) SYNC_URL="$_u"; do_install sync ;;
        *) do_install local ;;
    esac
}

do_preview() {
    if [[ -x "$RENDERER" ]]; then "$RENDERER" || true; else echo "(not installed yet — choose Install)"; fi
}

do_edit() {
    [[ -e "$STATE" ]] || { echo "Not installed yet — choose Install first."; return 0; }
    "${EDITOR:-nano}" "$STATE" </dev/tty >/dev/tty 2>&1 || true
    echo "----- preview -----"; "$RENDERER" 2>/dev/null || true
}

# Post-install menu, installed to the host as 'terminal-banner'.
# shellcheck disable=SC2329  # invoked indirectly from the generated launcher
menu_local() {
    exec 3</dev/tty 2>/dev/null || { echo "no terminal"; exit 1; }
    while true; do
        tw_clear
        tw_header
        printf '   \033[1;36m1\033[0m  Edit the banner\n   \033[1;36m2\033[0m  Preview\n   \033[1;36m3\033[0m  Uninstall\n   \033[1;36m4\033[0m  Quit\n\n'
        printf '  \033[2mchoose\033[0m \033[1;36m\342\235\257\033[0m '
        read -r c <&3 || c=4
        case "$c" in
            1) do_edit; tw_pause ;;
            2) do_preview; tw_pause ;;
            3) uninstall_body; exit 0 ;;
            4) exit 0 ;;
            *) : ;;
        esac
    done
}

# Full menu for the installer (adds Install / update + GitHub sync).
menu() {
    while true; do
        tw_clear
        tw_header
        printf '   \033[1;36m1\033[0m  Install / update\n   \033[1;36m2\033[0m  Edit the banner\n   \033[1;36m3\033[0m  Preview\n   \033[1;36m4\033[0m  Uninstall\n   \033[1;36m5\033[0m  Quit\n\n'
        printf '  \033[2mchoose\033[0m \033[1;36m\342\235\257\033[0m '
        read -r c <&3 || c=5
        case "$c" in
            1) menu_install; tw_pause ;;
            2) do_edit; tw_pause ;;
            3) do_preview; tw_pause ;;
            4) uninstall_body; exit 0 ;;
            5) exit 0 ;;
            *) : ;;
        esac
    done
}

# ---- Entry point: real terminal -> menu; piped/no terminal -> install --------
#      TW_SYNC=1 selects GitHub-sync mode non-interactively (for automation/CI).
if [[ -t 1 ]] && exec 3</dev/tty 2>/dev/null; then
    menu
elif [[ "${TW_SYNC:-}" == 1 ]]; then
    do_install sync
else
    do_install local
fi
