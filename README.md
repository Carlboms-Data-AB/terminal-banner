# terminal-welcome-message

A custom login banner (MOTD) for Linux hosts, driven by a single file in this
repo. Edit [`message.txt`](message.txt) on GitHub and every host that ran the
installer picks up the change automatically — while still reading a **local**
copy at login, so it works even when the host is offline.

Shows on **SSH login**, **local console login**, and **desktop terminal windows**.

## Install

Runnable as-is on Raspberry Pi OS / Debian / Ubuntu / Fedora / RHEL / Arch:

```bash
curl -fsSL https://raw.githubusercontent.com/Carlboms-Data-AB/terminal-welcome-message/main/setup.sh | sudo bash
```

Options (pass after `bash -s --`):

```bash
# sync every 10 minutes instead of the default 15
curl -fsSL .../setup.sh | sudo bash -s -- --interval 10

# remove everything and restore the box
curl -fsSL .../setup.sh | sudo bash -s -- --uninstall
```

| Option | Default | Meaning |
|--------|---------|---------|
| `--interval MINUTES` | `15` | how often to re-sync the message (1–59) |
| `--branch NAME` | `main` | which branch to fetch `message.txt` from |
| `--uninstall` | — | undo the install (restores `/etc/motd` and the disabled banner scripts) |

## Change the message

Edit **`message.txt`** in this repo and commit. Each host refreshes on its
schedule (default every 15 min; GitHub's raw CDN also caches `main` for a few
minutes). To see it immediately on a host:

```bash
sudo /usr/local/sbin/terminal-welcome-update   # fetch now
cat /etc/motd                                   # preview
```

## How it works

Two paths are deliberately kept separate:

- **Login path (always local, always offline-safe).** The message lives in
  `/etc/motd`. On SSH and console login `pam_motd` / `login` print it — the
  network is never touched at login.
- **Sync path (background).** A systemd timer (cron fallback) runs a small local
  updater that fetches `message.txt`, strips any terminal control/escape
  characters, and atomically rewrites `/etc/motd`. If GitHub is unreachable the
  existing message stays put.

For **desktop terminal windows** (which open a non-login shell that `pam_motd`
never covers), the installer adds a guarded snippet at
`/etc/profile.d/zz-terminal-welcome.sh`, sourced from `/etc/bash.bashrc` on
Debian/Ubuntu/Arch and via `/etc/bashrc` on Fedora/RHEL. The guard prints the
banner only in interactive, non-login, non-SSH `bash` shells so it never
double-prints where `pam_motd` already showed it.

On Debian/Ubuntu the stock dynamic banner (`/etc/update-motd.d/10-uname`, …) is
disabled so the message **replaces** it rather than appending. `--uninstall`
re-enables them.

## Security

Only the message **text** is ever fetched from GitHub — no executable code is
pulled or run at login or on the timer. The updater is installed once, locally,
and runs as root; changing it means re-running `setup.sh`. This is deliberate:
`/etc/update-motd.d` scripts run **as root at every login**, so auto-pulling and
executing remote code would turn any GitHub/branch/account compromise into root
code execution. Fetching data instead caps the worst case at "someone edited the
banner text" — and even that text is stripped of escape sequences before it's
displayed.

## Known edge cases

The desktop-terminal snippet is a best-effort heuristic (SSH and console logins
are always correct via `pam_motd`):

- Only `bash` is covered for GUI terminals; `zsh`/`fish` are not.
- Shells started inside `tmux`/`screen` are login shells, so the banner is not
  repeated there (usually what you want).
- `sudo -s` / `sudo bash` inside an SSH session can print the banner a second
  time, because `sudo` resets the environment the guard relies on.

## Files

| File | Role |
|------|------|
| `setup.sh` | installer / uninstaller; embeds the updater, the shell snippet, and the timer/cron unit |
| `message.txt` | the banner text — **edit this to change what hosts show** |
