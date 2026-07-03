#!/usr/bin/env bash
#
# setup.sh — install a custom, dynamic terminal welcome message (MOTD) on Linux.
#
# What it does:
#   - Publishes a welcome banner that shows on SSH login, local console login,
#     and desktop GUI terminal windows, across Debian/Ubuntu/Fedora/RHEL/Arch.
#   - The banner is a TEMPLATE (message.txt in the repo) with tokens like
#     {{IP}} and {{REBOOT}}. Each host fills those in LOCALLY, at display time,
#     from its own system state — so the IP/uptime/reboot status is always this
#     host's and always fresh.
#   - Keeps the template in sync with GitHub on a schedule (systemd timer, cron
#     fallback). Only the template TEXT is fetched — never executable code — and
#     the login path is 100% local, so it works offline.
#   - On Debian/Ubuntu it renders at each login via /etc/update-motd.d/ and
#     disables the stock banner/ad scripts so the message REPLACES them.
#
# Security model:
#   - The renderer is installed ONCE, locally, and pinned. It is never re-fetched.
#   - The fetched template is DATA: it is string-substituted, never executed
#     (no eval / no shell expansion), and stripped of terminal escape sequences.
#     A compromised repo can therefore only change banner TEXT, not run code.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/Carlboms-Data-AB/terminal-welcome-message/main/setup.sh | sudo bash
#   curl -fsSL .../setup.sh | sudo bash -s -- --interval 10
#   curl -fsSL .../setup.sh | sudo bash -s -- --uninstall
#
# Options:
#   --interval MINUTES   how often to re-sync the template (default 15, range 1-59)
#   --branch NAME        git branch to fetch message.txt from (default main)
#   --url URL            fetch the template from a custom URL (self-host / testing)
#   --uninstall          remove everything and restore the box
#   -h, --help           show this header
#
set -euo pipefail

# ---- Configuration ----------------------------------------------------------

REPO_RAW="https://raw.githubusercontent.com/Carlboms-Data-AB/terminal-welcome-message"
BRANCH="main"
INTERVAL=15
DO_UNINSTALL=false
MESSAGE_URL_OVERRIDE=""

CONF_DIR=/etc/terminal-welcome
CONF_FILE="$CONF_DIR/welcome.conf"
MOTD_BACKUP="$CONF_DIR/motd.orig"
DISABLED_LIST="$CONF_DIR/disabled-motd.d"
UPDATER=/usr/local/sbin/terminal-welcome-update
RENDERER=/usr/local/sbin/terminal-welcome-render
MOTDD_SCRIPT=/etc/update-motd.d/00-carlboms-welcome
PROFILE_SNIPPET=/etc/profile.d/zz-terminal-welcome.sh
BASHRC=/etc/bash.bashrc
SVC=/etc/systemd/system/terminal-welcome.service
TIMER=/etc/systemd/system/terminal-welcome.timer
CRON=/etc/cron.d/terminal-welcome
HOOK_MARK="# >>> terminal-welcome hook >>>"

# ---- Option parsing ---------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case "$1" in
        --interval) INTERVAL="${2:?--interval needs a number}"; shift ;;
        --branch)   BRANCH="${2:?--branch needs a name}"; shift ;;
        --url)      MESSAGE_URL_OVERRIDE="${2:?--url needs a URL}"; shift ;;
        --uninstall) DO_UNINSTALL=true ;;
        -h|--help)  grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
    shift
done

[[ "$INTERVAL" =~ ^[0-9]+$ && "$INTERVAL" -ge 1 && "$INTERVAL" -le 59 ]] \
    || { echo "ERROR: --interval must be an integer 1..59 (minutes)" >&2; exit 1; }
[[ $EUID -eq 0 ]] || { echo "ERROR: run as root (sudo $0)" >&2; exit 1; }

MESSAGE_URL="${MESSAGE_URL_OVERRIDE:-$REPO_RAW/$BRANCH/message.txt}"
has_systemd() { [[ -d /run/systemd/system ]]; }
# Debian/Ubuntu render at login via update-motd.d; others render onto /etc/motd.
use_update_motd_d() { [[ -d /etc/update-motd.d ]]; }

# ---- Uninstall --------------------------------------------------------------

uninstall() {
    echo "Removing terminal-welcome ..."
    if has_systemd; then
        systemctl disable --now terminal-welcome.timer 2>/dev/null || true
        rm -f "$TIMER" "$SVC"; systemctl daemon-reload 2>/dev/null || true
    fi
    rm -f "$CRON" "$UPDATER" "$RENDERER" "$PROFILE_SNIPPET" "$MOTDD_SCRIPT"

    if [[ -f "$BASHRC" ]] && grep -qF "$HOOK_MARK" "$BASHRC"; then
        sed -i "/$(printf '%s' "$HOOK_MARK" | sed 's/[.[*^$/]/\\&/g')/,/# <<< terminal-welcome hook <<</d" "$BASHRC"
    fi
    if [[ -f "$DISABLED_LIST" ]]; then
        while IFS= read -r f; do [[ -e "$f" ]] && chmod +x "$f"; done < "$DISABLED_LIST"
    fi
    if [[ -f "$MOTD_BACKUP" ]] && ! grep -q '^symlink ->' "$MOTD_BACKUP"; then
        rm -f /etc/motd; cp -a "$MOTD_BACKUP" /etc/motd
    fi
    rm -rf "$CONF_DIR"
    echo "Done."
    exit 0
}
$DO_UNINSTALL && uninstall

# ---- Install ----------------------------------------------------------------

RENDER_TO_MOTD=true
use_update_motd_d && RENDER_TO_MOTD=false

echo "Installing terminal-welcome (sync every ${INTERVAL} min from $MESSAGE_URL) ..."
mkdir -p "$CONF_DIR"

# Back up the existing /etc/motd once.
if [[ ! -e "$MOTD_BACKUP" ]]; then
    if [[ -L /etc/motd ]]; then printf 'symlink -> %s\n' "$(readlink /etc/motd)" > "$MOTD_BACKUP"
    elif [[ -f /etc/motd ]]; then cp -a /etc/motd "$MOTD_BACKUP"
    else : > "$MOTD_BACKUP"; fi
fi

cat > "$CONF_FILE" <<EOF
# terminal-welcome configuration — managed by setup.sh, safe to edit.
MESSAGE_URL="$MESSAGE_URL"
RENDER_TO_MOTD=$RENDER_TO_MOTD
EOF
chmod 0644 "$CONF_FILE"

# --- Renderer: read the local template, substitute this host's live values,
#     print to stdout. Pure string replacement — the template is NEVER executed.
cat > "$RENDERER" <<'EOF'
#!/usr/bin/env bash
# terminal-welcome-render — render the welcome banner for THIS host.
# Substitutes {{TOKENS}} in the local template with live values. It never
# executes the template (no eval), so a hostile template can only change text.
set -u

STATE=/etc/terminal-welcome/message
[ -r "$STATE" ] || exit 0
tpl=$(cat "$STATE")

host=$(hostname 2>/dev/null || cat /proc/sys/kernel/hostname 2>/dev/null || echo '?')

# All global IPv4 with interface, e.g. "81.88.19.36 (ens3), 100.91.68.49 (wt0)".
ips=$(ip -4 -o addr show scope global 2>/dev/null \
      | awk '{split($4,a,"/"); printf "%s%s (%s)", (NR>1?", ":""), a[1], $2}')
[ -n "$ips" ] || ips='(none)'

# VPN IP: prefer the NetBird interface (wt0/netbird*), else any 100.64.0.0/10 addr.
vpnip=$(ip -4 -o addr show 2>/dev/null \
        | awk '{split($4,a,"/"); if ($2 ~ /^(wt0|netbird)/) {print a[1]; exit}}')
if [ -z "$vpnip" ]; then
    vpnip=$(ip -4 -o addr show scope global 2>/dev/null | awk '
        {split($4,a,"/"); split(a[1],o,".");
         if (o[1]==100 && o[2]>=64 && o[2]<=127) {print a[1]; exit}}')
fi

up=$(uptime -p 2>/dev/null | sed 's/^up //'); [ -n "$up" ] || up='?'
load=$(cut -d' ' -f1 /proc/loadavg 2>/dev/null || echo '?')
disk=$(df -h / 2>/dev/null | awk 'NR==2{print $5" of "$2}'); [ -n "$disk" ] || disk='?'
mem=$(free -m 2>/dev/null | awk '/^Mem:/{printf "%d%%", ($2>0?$3*100/$2:0)}'); [ -n "$mem" ] || mem='?'

# Listening TCP ports reachable off-box (skip loopback-only listeners).
ports=$(ss -tlnH 2>/dev/null | awk '{print $4}' \
        | grep -vE '^(127\.0\.0\.1|\[::1\]):' \
        | sed 's/.*://' | grep -E '^[0-9]+$' | sort -un | paste -sd',' - | sed 's/,/, /g')

# CasaOS dashboard URL (only if CasaOS is installed), reachable via the VPN IP.
casaos=''
if [ -f /etc/casaos/gateway.ini ] || command -v casaos >/dev/null 2>&1; then
    cport=$(awk -F= '/^[[:space:]]*[Pp]ort[[:space:]]*=/{gsub(/[^0-9]/,"",$2); print $2; exit}' \
            /etc/casaos/gateway.ini 2>/dev/null)
    [ -n "$cport" ] || cport=80
    chost=${vpnip:-$(printf '%s' "$ips" | sed 's/ .*//')}
    if [ -n "$chost" ]; then
        [ "$cport" = 80 ] && casaos="http://$chost" || casaos="http://$chost:$cport"
    fi
fi

if [ -f /run/reboot-required ] || [ -f /var/run/reboot-required ]; then
    reboot='{{RED}}*** System restart required ***{{RESET}}'
else
    reboot=''
fi

out=$tpl
out=${out//'{{HOSTNAME}}'/$host}
out=${out//'{{VPNIP}}'/$vpnip}
out=${out//'{{IP}}'/$ips}
out=${out//'{{UPTIME}}'/$up}
out=${out//'{{LOAD}}'/$load}
out=${out//'{{DISK}}'/$disk}
out=${out//'{{MEMORY}}'/$mem}
out=${out//'{{PORTS}}'/$ports}
out=${out//'{{CASAOS}}'/$casaos}
out=${out//'{{REBOOT}}'/$reboot}

# Drop lines that are effectively empty — whitespace-only, or "Label : " with an
# empty value — even when they still carry colour tokens. Then strip stray bytes.
out=$(printf '%s\n' "$out" | awk '
    { p=$0; gsub(/\{\{(RESET|BOLD|DIM|RED|GREEN|YELLOW|BLUE|MAGENTA|CYAN|WHITE)\}\}/,"",p)
      if (p ~ /^[[:space:]]*$/) next
      if (p ~ /:[[:space:]]*$/)  next
      print }' | LC_ALL=C tr -cd '\11\12\40-\176\200-\377')

# Colour markup for ASCII art: this LOCAL, trusted renderer turns safe {{COLOR}}
# tokens into SGR escapes AFTER sanitising — so no escape sequence ever travels
# from the template/GitHub. A reset is always appended so the terminal restores.
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
EOF
chmod 0755 "$RENDERER"; chown root:root "$RENDERER"

# --- Updater: fetch template TEXT only, sanitize, save locally; re-render onto
#     /etc/motd where we don't have update-motd.d. Fails safe when offline.
cat > "$UPDATER" <<'EOF'
#!/bin/sh
# terminal-welcome-update — sync the welcome template from GitHub (DATA only).
set -eu
CONF=/etc/terminal-welcome/welcome.conf
[ -r "$CONF" ] && . "$CONF"
: "${MESSAGE_URL:?MESSAGE_URL not set in $CONF}"
STATE=/etc/terminal-welcome/message
RENDERER=/usr/local/sbin/terminal-welcome-render

tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
if command -v curl >/dev/null 2>&1; then
    curl -fsSL --max-time 15 --retry 2 "$MESSAGE_URL" -o "$tmp" \
        || { echo "terminal-welcome-update: fetch failed; keeping current template" >&2; exit 0; }
elif command -v wget >/dev/null 2>&1; then
    wget -q -T 15 -t 2 -O "$tmp" "$MESSAGE_URL" \
        || { echo "terminal-welcome-update: fetch failed; keeping current template" >&2; exit 0; }
else
    echo "terminal-welcome-update: need curl or wget" >&2; exit 0
fi

# Keep tab, newline, printable ASCII and UTF-8; drop escape/control bytes so the
# template cannot inject terminal escape sequences.
clean=$(LC_ALL=C tr -cd '\11\12\40-\176\200-\377' < "$tmp")
printf '%s\n' "$clean" > "$STATE.new" && mv -f "$STATE.new" "$STATE"
chmod 0644 "$STATE"

if [ "${RENDER_TO_MOTD:-false}" = "true" ] && [ -x "$RENDERER" ]; then
    [ -L /etc/motd ] && rm -f /etc/motd
    "$RENDERER" > /etc/motd.new && mv -f /etc/motd.new /etc/motd
    chmod 0644 /etc/motd
fi
EOF
chmod 0755 "$UPDATER"; chown root:root "$UPDATER"

# --- GUI terminal windows: pam_motd never runs there, so render live from the
#     shell. Guarded so it does not double-print on SSH / console logins.
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

if [[ -f "$BASHRC" ]] && ! grep -qF "$HOOK_MARK" "$BASHRC"; then
    cat >> "$BASHRC" <<EOF

$HOOK_MARK
[ -r "$PROFILE_SNIPPET" ] && . "$PROFILE_SNIPPET"
# <<< terminal-welcome hook <<<
EOF
fi

# --- Debian/Ubuntu: render at each login via update-motd.d; disable the stock
#     banner/ad scripts so ours replaces them; keep /etc/motd empty (avoids a
#     double-print, since pam_motd prints the dynamic part AND /etc/motd).
if use_update_motd_d; then
    : > "$DISABLED_LIST"
    for f in /etc/update-motd.d/*; do
        [[ -f "$f" && -x "$f" ]] || continue
        [[ "$f" == "$MOTDD_SCRIPT" ]] && continue
        chmod -x "$f"; echo "$f" >> "$DISABLED_LIST"
    done
    cat > "$MOTDD_SCRIPT" <<EOF
#!/bin/sh
exec $RENDERER
EOF
    chmod 0755 "$MOTDD_SCRIPT"
    [[ -L /etc/motd ]] && rm -f /etc/motd
    : > /etc/motd
fi

# --- Scheduling: prefer a systemd timer, fall back to cron.
if has_systemd; then
    rm -f "$CRON"
    cat > "$SVC" <<EOF
[Unit]
Description=Sync terminal welcome template from GitHub
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$UPDATER
EOF
    cat > "$TIMER" <<EOF
[Unit]
Description=Periodically sync the terminal welcome template

[Timer]
OnBootSec=1min
OnUnitActiveSec=${INTERVAL}min
RandomizedDelaySec=60

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now terminal-welcome.timer
    SCHED_DESC="systemd timer (every ${INTERVAL} min, +boot, jittered)"
else
    rm -f "$SVC" "$TIMER"
    cat > "$CRON" <<EOF
# terminal-welcome — sync the welcome template every ${INTERVAL} min
*/${INTERVAL} * * * * root $UPDATER >/dev/null 2>&1
EOF
    chmod 0644 "$CRON"
    SCHED_DESC="cron (every ${INTERVAL} min)"
fi

# First sync now so the banner is live immediately.
"$UPDATER" || echo "WARNING: initial fetch failed — will retry on schedule." >&2

echo
echo "Installed. Banner is live."
echo "  Render   : $( use_update_motd_d && echo 'at each login via /etc/update-motd.d (always fresh)' || echo 'onto /etc/motd on the timer' )"
echo "  Schedule : $SCHED_DESC"
echo "  Template : edit message.txt in the repo; hosts pick it up on the timer"
echo "  Preview  : sudo $RENDERER   (or open a new terminal / re-SSH)"
echo "  Uninstall: curl -fsSL $REPO_RAW/$BRANCH/setup.sh | sudo bash -s -- --uninstall"
echo
echo "Current banner on this host:"
echo "----------------------------------------"
"$RENDERER" 2>/dev/null || true
echo "----------------------------------------"
