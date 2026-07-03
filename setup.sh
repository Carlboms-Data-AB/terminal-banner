#!/usr/bin/env bash
#
# setup.sh - install a custom, dynamic terminal welcome message (MOTD) on Linux.
#
# Fully LOCAL: the install bootstraps from GitHub (this script), but AFTER that
# nothing is ever fetched again. The banner lives in /etc/terminal-welcome/message
# on the host - a TEMPLATE with {{TOKENS}} that the renderer fills in with this
# host's live values at display time, plus {{COLOUR}} tokens for styling. Edit
# that file on the box and the change is immediate; re-running this installer
# never overwrites it.
#
# The renderer is installed once and treats the template as DATA (string
# substitution, no eval), stripping the ESC control byte so ANSI/OSC escape
# sequences can't render. See README for the token catalogue and security model.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/Carlboms-Data-AB/terminal-welcome-message/main/setup.sh | sudo bash
#   curl -fsSL .../setup.sh | sudo bash -s -- --uninstall
#
# Options:
#   --uninstall          remove everything and restore the box
#   -h, --help           show this header
#
set -euo pipefail

# ---- Configuration ----------------------------------------------------------

REPO_RAW="https://raw.githubusercontent.com/Carlboms-Data-AB/terminal-welcome-message/main"  # docs/uninstall link only; never fetched after install
DO_UNINSTALL=false

CONF_DIR=/etc/terminal-welcome
CONF_FILE="$CONF_DIR/welcome.conf"         # legacy synced-install config - removed on install
CACHE_DIR=/var/lib/terminal-welcome        # optional cache for {{PUBIP}}/{{UPDATES}}
STATE="$CONF_DIR/message"                  # the LOCAL template - edit this on the host
MOTD_BACKUP="$CONF_DIR/motd.orig"
DISABLED_LIST="$CONF_DIR/disabled-motd.d"
UPDATER=/usr/local/sbin/terminal-welcome-update   # legacy sync job - removed on install
RENDERER=/usr/local/sbin/terminal-welcome-render
MOTDD_SCRIPT=/etc/update-motd.d/00-welcome
MOTDD_LEGACY=/etc/update-motd.d/00-carlboms-welcome   # pre-rename installs
PROFILE_SNIPPET=/etc/profile.d/zz-terminal-welcome.sh
BASHRC=/etc/bash.bashrc
SVC=/etc/systemd/system/terminal-welcome.service
TIMER=/etc/systemd/system/terminal-welcome.timer
CRON=/etc/cron.d/terminal-welcome
HOOK_MARK="# >>> terminal-welcome hook >>>"

# ---- Option parsing ---------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case "$1" in
        --uninstall) DO_UNINSTALL=true ;;
        -h|--help)
            if [[ -r "$0" && "$0" != bash && "$0" != -bash && "$0" != sh ]]; then
                grep '^#' "$0" | sed 's/^# \{0,1\}//'
            else
                echo "terminal-welcome-message — options: --uninstall | -h"
                echo "docs: https://github.com/Carlboms-Data-AB/terminal-welcome-message"
            fi
            exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
    shift
done

[[ $EUID -eq 0 ]] || { echo "ERROR: run as root (sudo $0)" >&2; exit 1; }

has_systemd() { [[ -d /run/systemd/system ]]; }
use_update_motd_d() { [[ -d /etc/update-motd.d ]]; }

# ---- Uninstall --------------------------------------------------------------

uninstall() {
    echo "Removing terminal-welcome ..."
    if has_systemd; then
        systemctl disable --now terminal-welcome.timer 2>/dev/null || true
        rm -f "$TIMER" "$SVC"; systemctl daemon-reload 2>/dev/null || true
    fi
    rm -f "$CRON" "$UPDATER" "$RENDERER" "$PROFILE_SNIPPET" "$MOTDD_SCRIPT" "$MOTDD_LEGACY"

    if [[ -f "$BASHRC" ]] && grep -qF "$HOOK_MARK" "$BASHRC"; then
        sed -i "/$(printf '%s' "$HOOK_MARK" | sed 's/[.[*^$/]/\\&/g')/,/# <<< terminal-welcome hook <<</d" "$BASHRC"
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
    exit 0
}
$DO_UNINSTALL && uninstall

# ---- Install ----------------------------------------------------------------

RENDER_TO_MOTD=true
use_update_motd_d && RENDER_TO_MOTD=false

# Soft dependency check - tokens degrade to blank, but tell the user what's missing.
missing=''
for c in ip ss awk sed; do command -v "$c" >/dev/null 2>&1 || missing="$missing $c"; done
[[ -n "$missing" ]] && echo "NOTE: missing tools (some tokens will be blank):$missing" \
    "- install iproute2 / procps / coreutils / gawk for full output." >&2

echo "Installing terminal-welcome (local; no GitHub sync) ..."
mkdir -p "$CONF_DIR" "$CACHE_DIR"

# Migrate any older 'GitHub-synced' install to local-only: stop and remove the
# sync timer/cron/updater and its config so nothing is ever fetched again.
if has_systemd; then systemctl disable --now terminal-welcome.timer 2>/dev/null || true; fi
rm -f "$TIMER" "$SVC" "$CRON" "$UPDATER" "$CONF_FILE"
has_systemd && { systemctl daemon-reload 2>/dev/null || true; }

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
# terminal-welcome-render - render the welcome banner for THIS host.
set -u
STATE=/etc/terminal-welcome/message
CACHE=/var/lib/terminal-welcome
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
printf '%s%s\n' "$out" "$c_reset"
RENDER_EOF
chmod 0755 "$RENDERER"; chown root:root "$RENDERER"

# ---- No updater / sync job in local mode: nothing is fetched after install.
#      {{PUBIP}}/{{UPDATES}} are optional and refreshed only if you add the cron
#      shown in the README. Any legacy sync artifacts are removed above on install.

# ---- GUI terminal windows: render live from the shell (pam_motd never runs
#      there). Guarded so it does not double-print on SSH / console logins.
cat > "$PROFILE_SNIPPET" <<'EOF'
# terminal-welcome: show the banner in desktop terminal windows (non-login
# interactive shells), where pam_motd never runs. Guarded to avoid double-print.
case $- in
  *i*)
    if [ -z "${__TW_SHOWN:-}" ] \
       && [ -n "${BASH_VERSION:-}" ] \
       && ! shopt -q login_shell \
       && [ -z "${SSH_CONNECTION:-}${SSH_TTY:-}${SSH_CLIENT:-}" ]; then
        [ -x /usr/local/sbin/terminal-welcome-render ] && /usr/local/sbin/terminal-welcome-render
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
# <<< terminal-welcome hook <<<
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

echo
echo "Installed. Banner is live — fully local, no GitHub sync."
echo "  Render   : $( use_update_motd_d && echo 'live at each login (/etc/update-motd.d)' || echo 'onto /etc/motd now (snapshot on this distro; live in interactive shells)' )"
echo "  Edit     : sudo nano $STATE"
echo "             (takes effect immediately; re-running setup.sh won't overwrite it)"
echo "  Preview  : sudo $RENDERER"
echo "  Uninstall: curl -fsSL $REPO_RAW/setup.sh | sudo bash -s -- --uninstall"
echo
echo "Current banner on this host:"
echo "----------------------------------------"
"$RENDERER" 2>/dev/null || true
echo "----------------------------------------"
