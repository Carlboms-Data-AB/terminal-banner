# terminal-welcome-message

A custom login banner (MOTD) for Linux hosts, driven by a template in this repo.
Edit [`message.txt`](message.txt) on GitHub and every host that ran the installer
picks up the new layout automatically — while filling in **live, per-host values**
(IP, uptime, listening ports, reboot status …) locally at display time.

Shows on **SSH login**, **local console login**, and **desktop terminal windows**,
and always reads a **local** copy, so it works even when the host is offline.

<p align="center">
  <img src="docs/img/server.svg" alt="Full server banner with host info, VPN IP, ports, CasaOS link and reboot notice" width="460">
</p>

Ships with several ready-to-use templates in [`examples/`](examples/) — copy one
into `message.txt` to adopt it:

| Example | Looks like |
|---------|-----------|
| [`server.txt`](examples/server.txt) — full system summary | <img src="docs/img/server.svg" alt="server example" width="360"> |
| [`branded.txt`](examples/branded.txt) — coloured header + homelab links | <img src="docs/img/branded.svg" alt="branded example" width="360"> |
| [`ascii-art.txt`](examples/ascii-art.txt) — ASCII art + colour | <img src="docs/img/ascii-art.svg" alt="ascii-art example" width="300"> |
| [`minimal.txt`](examples/minimal.txt) — hostname + IP only | copyright, host, IP |
| [`plain.txt`](examples/plain.txt) — one static line | `Copyright Carlboms Data AB` |

> Screenshots are rendered from the example templates with sample data by
> [`tools/render-svg.py`](tools/render-svg.py); real hosts fill in their own values.

## Install

Runnable as-is on Raspberry Pi OS / Debian / Ubuntu / Fedora / RHEL / Arch:

```bash
curl -fsSL https://raw.githubusercontent.com/Carlboms-Data-AB/terminal-welcome-message/main/setup.sh | sudo bash
```

| Option | Default | Meaning |
|--------|---------|---------|
| `--interval MINUTES` | `15` | how often to re-sync the template (1–59) |
| `--branch NAME` | `main` | which branch to fetch `message.txt` from |
| `--uninstall` | — | undo the install and restore the box |

```bash
curl -fsSL .../setup.sh | sudo bash -s -- --interval 10     # sync every 10 min
curl -fsSL .../setup.sh | sudo bash -s -- --uninstall       # remove
```

## Editing the banner

Edit **`message.txt`** in this repo — it's a template. Static text is shown
as-is; `{{TOKENS}}` are replaced on each host with that host's live values.
A line whose token comes out **empty is omitted** (e.g. the CasaOS line only
appears where CasaOS is installed).

| Token | Expands to |
|-------|-----------|
| `{{HOSTNAME}}` | the host's name |
| `{{VPNIP}}` | NetBird VPN address (interface `wt0`/`netbird`, or a `100.64.0.0/10` address) |
| `{{IP}}` | all global IPv4 with interface, e.g. `81.88.19.36 (ens3), 100.91.68.49 (wt0)` |
| `{{UPTIME}}` | uptime, e.g. `3 days, 4 hours` |
| `{{LOAD}}` | 1-minute load average |
| `{{DISK}}` | root filesystem usage, e.g. `19% of 96G` |
| `{{MEMORY}}` | memory used, e.g. `35%` |
| `{{PORTS}}` | listening TCP ports reachable off-box (loopback-only excluded) |
| `{{CASAOS}}` | CasaOS dashboard URL via the VPN IP (only if CasaOS is installed) |
| `{{REBOOT}}` | `*** System restart required ***` when a reboot is pending, else nothing |

The `CasaOS` URL is a plain `http://…` link — modern terminals make it
Ctrl/Cmd-clickable. The port is read from `/etc/casaos/gateway.ini` (default 80).

Changes propagate on the sync timer (default 15 min; GitHub's raw CDN also caches
`main` for a few minutes). To apply immediately on a host:

```bash
sudo /usr/local/sbin/terminal-welcome-update   # re-sync the template now
sudo /usr/local/sbin/terminal-welcome-render   # preview this host's banner
```

## How it works

- **Login path (local, offline-safe).** On Debian/Ubuntu the banner is rendered
  at each login by `/etc/update-motd.d/00-carlboms-welcome`, so IP/reboot status
  are always current; the stock banner/ad scripts are disabled so this replaces
  them. On other distros the banner is rendered onto `/etc/motd` on the timer.
- **Desktop terminal windows** (non-login shells `pam_motd` never covers) render
  live via a guarded `/etc/profile.d` snippet, sourced from `/etc/bash.bashrc`
  (Debian/Ubuntu/Arch) or `/etc/bashrc` (Fedora/RHEL).
- **Sync path (background).** A systemd timer (cron fallback) fetches the template
  text, strips terminal escape sequences, and saves it locally. If GitHub is
  unreachable the last template stays in place.

## Security

Only the template **text** is fetched from GitHub — no executable code is pulled
or run at login or on the timer. The renderer is installed **once, locally**, and
the template is treated as **data**: tokens are string-substituted, the template
is **never executed** (no `eval`, no shell expansion), and it's stripped of
escape sequences before display. So even a compromised repo can only change the
banner text — never run code, even though the render runs as root at login.

## Known edge cases

SSH and console logins are always correct. The desktop-terminal snippet is a
best-effort heuristic: it covers `bash` only, intentionally skips shells started
inside `tmux`/`screen`, and `sudo -s` inside SSH can print the banner twice.
`{{PORTS}}` needs `iproute2` (`ss`); `{{VPNIP}}`/`{{CASAOS}}` are empty (and their
lines omitted) when there's no VPN / CasaOS.

## Files

| File | Role |
|------|------|
| `setup.sh` | installer / uninstaller; embeds the renderer, updater, shell snippet, and timer/cron unit |
| `message.txt` | the banner **template** — edit this to change what hosts show |
