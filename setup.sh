#!/usr/bin/env bash
#
# setup.sh — install a custom terminal welcome message (MOTD) on any Linux host.
#
# What it does:
#   - Publishes a welcome message to /etc/motd so it shows on SSH and console login
#     (via pam_motd / login) on essentially every Linux distro.
#   - Installs a guarded shell snippet so the message ALSO shows in desktop GUI
#     terminal windows (non-login interactive shells, which pam_motd never covers).
#   - Keeps the message in sync with a GitHub file on a schedule (systemd timer,
#     cron fallback). Only the message TEXT is fetched — never executable code —
#     and the login path always reads the LOCAL /etc/motd, so it works offline.
#   - On Debian/Ubuntu it disables the stock dynamic banner (10-uname, etc.) so the
#     message REPLACES it rather than appending. Reversible via --uninstall.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/Carlboms-Data-AB/terminal-welcome-message/main/setup.sh | sudo bash
#   curl -fsSL .../setup.sh | sudo bash -s -- --interval 10
#   curl -fsSL .../setup.sh | sudo bash -s -- --uninstall
#
# Options:
#   --interval MINUTES   how often to re-sync the message (default 15)
#   --branch NAME        git branch to fetch message.txt from (default main)
#   --uninstall          remove everything this installer added and restore the box
#   -h, --help           show this header
#
set -euo pipefail

# ---- Configuration ----------------------------------------------------------

REPO_RAW="https://raw.githubusercontent.com/Carlboms-Data-AB/terminal-welcome-message"
BRANCH="main"
INTERVAL=15
DO_UNINSTALL=false

CONF_DIR=/etc/terminal-welcome
CONF_FILE="$CONF_DIR/welcome.conf"
MOTD_BACKUP="$CONF_DIR/motd.orig"
DISABLED_LIST="$CONF_DIR/disabled-motd.d"
UPDATER=/usr/local/sbin/terminal-welcome-update
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
        --uninstall) DO_UNINSTALL=true ;;
        -h|--help)  grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
    shift
done

[[ "$INTERVAL" =~ ^[0-9]+$ && "$INTERVAL" -ge 1 && "$INTERVAL" -le 59 ]] \
    || { echo "ERROR: --interval must be an integer 1..59 (minutes)" >&2; exit 1; }
[[ $EUID -eq 0 ]] || { echo "ERROR: run as root (sudo $0)" >&2; exit 1; }

MESSAGE_URL="$REPO_RAW/$BRANCH/message.txt"
has_systemd() { [[ -d /run/systemd/system ]]; }

# ---- Uninstall --------------------------------------------------------------

uninstall() {
    echo "Removing terminal-welcome ..."

    if has_systemd; then
        systemctl disable --now terminal-welcome.timer 2>/dev/null || true
        rm -f "$TIMER" "$SVC"
        systemctl daemon-reload 2>/dev/null || true
    fi
    rm -f "$CRON" "$UPDATER" "$PROFILE_SNIPPET"

    # Remove the source hook from /etc/bash.bashrc (marker-delimited block).
    if [[ -f "$BASHRC" ]] && grep -qF "$HOOK_MARK" "$BASHRC"; then
        sed -i "/$(printf '%s' "$HOOK_MARK" | sed 's/[.[*^$/]/\\&/g')/,/# <<< terminal-welcome hook <<</d" "$BASHRC"
    fi

    # Re-enable any stock update-motd.d scripts we disabled.
    if [[ -f "$DISABLED_LIST" ]]; then
        while IFS= read -r f; do [[ -e "$f" ]] && chmod +x "$f"; done < "$DISABLED_LIST"
    fi

    # Restore the original /etc/motd if we backed one up.
    if [[ -f "$MOTD_BACKUP" ]]; then
        rm -f /etc/motd; cp -a "$MOTD_BACKUP" /etc/motd
    else
        : > /etc/motd
    fi

    rm -rf "$CONF_DIR"
    echo "Done. (You may want to re-check /etc/motd and your update-motd.d scripts.)"
    exit 0
}
$DO_UNINSTALL && uninstall

# ---- Install ----------------------------------------------------------------

echo "Installing terminal-welcome (sync every ${INTERVAL} min from $MESSAGE_URL) ..."
mkdir -p "$CONF_DIR"

# Back up the existing /etc/motd once (records a symlink as text; copies a real file).
if [[ ! -e "$MOTD_BACKUP" ]]; then
    if [[ -L /etc/motd ]]; then
        printf 'symlink -> %s\n' "$(readlink /etc/motd)" > "$MOTD_BACKUP"
    elif [[ -f /etc/motd ]]; then
        cp -a /etc/motd "$MOTD_BACKUP"
    else
        : > "$MOTD_BACKUP"
    fi
fi

# Persist config so the updater knows where to fetch from (user-editable).
cat > "$CONF_FILE" <<EOF
# terminal-welcome configuration — managed by setup.sh, safe to edit.
MESSAGE_URL="$MESSAGE_URL"
EOF
chmod 0644 "$CONF_FILE"

# The updater: fetch message TEXT only, sanitize, publish atomically to /etc/motd.
# Runs as root on the timer. It never executes remote code and fails safe offline.
cat > "$UPDATER" <<'EOF'
#!/bin/sh
# terminal-welcome-update — publish the welcome message to /etc/motd.
# Fetches DATA only (no remote code execution) and keeps the last message on failure.
set -eu

CONF=/etc/terminal-welcome/welcome.conf
[ -r "$CONF" ] && . "$CONF"
: "${MESSAGE_URL:?MESSAGE_URL not set in $CONF}"

MOTD=/etc/motd
STATE=/etc/terminal-welcome/message

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

if command -v curl >/dev/null 2>&1; then
    curl -fsSL --max-time 15 --retry 2 "$MESSAGE_URL" -o "$tmp" \
        || { echo "terminal-welcome-update: fetch failed; keeping current /etc/motd" >&2; exit 0; }
elif command -v wget >/dev/null 2>&1; then
    wget -q -T 15 -t 2 -O "$tmp" "$MESSAGE_URL" \
        || { echo "terminal-welcome-update: fetch failed; keeping current /etc/motd" >&2; exit 0; }
else
    echo "terminal-welcome-update: need curl or wget" >&2; exit 0
fi

# Keep tab, newline, printable ASCII and UTF-8 bytes; drop ESC/CR/other control
# chars so a malicious message can't inject terminal escape sequences.
clean=$(LC_ALL=C tr -cd '\11\12\40-\176\200-\377' < "$tmp")

# If /etc/motd is a symlink (e.g. Ubuntu -> /run/motd.dynamic), replace it with a real file.
[ -L "$MOTD" ] && rm -f "$MOTD"

printf '%s\n' "$clean" > "$STATE.new" && mv -f "$STATE.new" "$STATE"
printf '%s\n' "$clean" > "$MOTD.new"  && mv -f "$MOTD.new"  "$MOTD"
chmod 0644 "$STATE" "$MOTD"
EOF
chmod 0755 "$UPDATER"; chown root:root "$UPDATER"

# Shell snippet: show the message in GUI terminal windows (non-login interactive
# shells), where pam_motd never runs. Guarded so it does not double-print on SSH
# / console logins (pam_motd owns those). See README for the known edge cases.
cat > "$PROFILE_SNIPPET" <<'EOF'
# terminal-welcome: fill the gap pam_motd leaves for desktop terminal windows.
# pam_motd already prints /etc/motd for SSH and console logins; this covers
# non-login interactive shells (GUI terminal emulators) without double-printing.
case $- in
  *i*)
    if [ -z "${__TW_SHOWN:-}" ] \
       && [ -n "${BASH_VERSION:-}" ] \
       && ! shopt -q login_shell \
       && [ -z "${SSH_CONNECTION:-}${SSH_TTY:-}${SSH_CLIENT:-}" ]; then
        [ -s /etc/motd ] && cat /etc/motd
        export __TW_SHOWN=1
    fi
    ;;
esac
EOF
chmod 0644 "$PROFILE_SNIPPET"

# On Debian/Ubuntu/Arch, non-login interactive shells read /etc/bash.bashrc but NOT
# /etc/profile.d/*. Source our snippet from there. (Fedora/RHEL get it via /etc/bashrc.)
if [[ -f "$BASHRC" ]] && ! grep -qF "$HOOK_MARK" "$BASHRC"; then
    cat >> "$BASHRC" <<EOF

$HOOK_MARK
[ -r "$PROFILE_SNIPPET" ] && . "$PROFILE_SNIPPET"
# <<< terminal-welcome hook <<<
EOF
fi

# Disable the stock dynamic banner so our message replaces it (Debian/Ubuntu).
# Reversible: we record what we disabled and restore it on --uninstall.
if [[ -d /etc/update-motd.d ]]; then
    : > "$DISABLED_LIST"
    for f in /etc/update-motd.d/*; do
        [[ -f "$f" && -x "$f" ]] || continue
        chmod -x "$f"
        echo "$f" >> "$DISABLED_LIST"
    done
fi

# Scheduling: prefer a systemd timer; fall back to cron.
if has_systemd; then
    rm -f "$CRON"
    cat > "$SVC" <<EOF
[Unit]
Description=Update terminal welcome message from GitHub
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$UPDATER
EOF
    cat > "$TIMER" <<EOF
[Unit]
Description=Periodically refresh the terminal welcome message

[Timer]
OnBootSec=1min
OnUnitActiveSec=${INTERVAL}min
Persistent=true
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
# terminal-welcome — refresh the welcome message every ${INTERVAL} min
*/${INTERVAL} * * * * root $UPDATER >/dev/null 2>&1
EOF
    chmod 0644 "$CRON"
    SCHED_DESC="cron (/etc/cron.d/terminal-welcome, every ${INTERVAL} min)"
fi

# First fetch now so the message is live immediately.
"$UPDATER" || echo "WARNING: initial fetch failed — will retry on schedule." >&2

echo
echo "Installed. Welcome message is now published to /etc/motd."
echo "  Schedule : $SCHED_DESC"
echo "  Source   : $MESSAGE_URL"
echo "  Preview  : cat /etc/motd   (or open a new terminal / re-SSH)"
echo "  Uninstall: curl -fsSL $REPO_RAW/$BRANCH/setup.sh | sudo bash -s -- --uninstall"
echo
echo "Current /etc/motd:"
echo "----------------------------------------"
cat /etc/motd 2>/dev/null || true
echo "----------------------------------------"
