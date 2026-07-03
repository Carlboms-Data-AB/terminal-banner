#!/usr/bin/env python3
"""Render a welcome-message template to an SVG "screenshot".

Mirrors the renderer in setup.sh: substitutes {{TOKENS}} with sample values,
drops label lines whose value is empty (colour-token aware), and turns the
{{COLOUR}} tokens into styled text. Output is a terminal-window SVG suitable
for embedding in the README.

Usage: tools/render-svg.py examples/server.txt docs/img/server.svg
"""
import html
import re
import sys

# Sample values matching the Ubuntu box from the README example.
SAMPLE = {
    "HOSTNAME": "cloud-server-10141984",
    "VPNIP": "100.91.68.49",
    "IP": "81.88.19.36 (ens3), 100.91.68.49 (wt0)",
    "UPTIME": "3 days, 4 hours",
    "LOAD": "0.08",
    "DISK": "19% of 96G",
    "MEMORY": "35%",
    "PORTS": "22, 80, 443",
    "CASAOS": "http://100.91.68.49",
    # The renderer wraps a pending reboot in red; reproduce that here.
    "REBOOT": "{{RED}}*** System restart required ***{{RESET}}",
}

COLOURS = {
    "RESET": None, "BOLD": "bold", "DIM": "dim",
    "RED": "#ff6b6b", "GREEN": "#5af78e", "YELLOW": "#f1fa8c",
    "BLUE": "#6cb6ff", "MAGENTA": "#ff6ac1", "CYAN": "#8be9fd", "WHITE": "#f8f8f2",
}
DEFAULT_FG = "#c9d1d9"
COLOUR_RE = re.compile(r"\{\{(" + "|".join(COLOURS) + r")\}\}")
ANY_COLOUR_RE = re.compile(r"\{\{(?:" + "|".join(COLOURS) + r")\}\}")

CHAR_W = 8.4      # px per monospace char at font-size 15
LINE_H = 21
PAD = 16
TITLE_H = 30


def substitute_data(text):
    for name, val in SAMPLE.items():
        text = text.replace("{{" + name + "}}", val)
    return text


def drop_empty_lines(text):
    out = []
    for line in text.split("\n"):
        probe = ANY_COLOUR_RE.sub("", line)
        if probe.strip() == "":
            continue
        if re.search(r":\s*$", probe):
            continue
        out.append(line)
    return out


def line_to_runs(line):
    """Yield (text, fg, bold, dim) runs, tracking colour state across tokens."""
    runs, fg, bold, dim, pos = [], DEFAULT_FG, False, False, 0
    for m in COLOUR_RE.finditer(line):
        if m.start() > pos:
            runs.append((line[pos:m.start()], fg, bold, dim))
        tok = m.group(1)
        if tok == "RESET":
            fg, bold, dim = DEFAULT_FG, False, False
        elif tok == "BOLD":
            bold = True
        elif tok == "DIM":
            dim = True
        else:
            fg = COLOURS[tok]
        pos = m.end()
    if pos < len(line):
        runs.append((line[pos:], fg, bold, dim))
    return runs


def render(template_path, svg_path):
    with open(template_path, encoding="utf-8") as fh:
        text = fh.read()
    lines = drop_empty_lines(substitute_data(text))
    parsed = [line_to_runs(ln) for ln in lines]

    width_chars = max((sum(len(t) for t, *_ in runs) for runs in parsed), default=1)
    w = int(width_chars * CHAR_W + 2 * PAD)
    h = int(TITLE_H + len(lines) * LINE_H + 2 * PAD)

    out = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" '
        f'viewBox="0 0 {w} {h}" font-family="ui-monospace,SFMono-Regular,Menlo,Consolas,'
        f'&quot;DejaVu Sans Mono&quot;,monospace" font-size="15">',
        f'<rect width="{w}" height="{h}" rx="8" fill="#0d1117"/>',
        f'<rect width="{w}" height="{TITLE_H}" rx="8" fill="#161b22"/>',
        f'<rect y="{TITLE_H-8}" width="{w}" height="8" fill="#161b22"/>',
        '<circle cx="18" cy="15" r="6" fill="#ff5f56"/>',
        '<circle cx="38" cy="15" r="6" fill="#ffbd2e"/>',
        '<circle cx="58" cy="15" r="6" fill="#27c93f"/>',
    ]
    y = TITLE_H + PAD + 12
    for runs in parsed:
        out.append(f'<text x="{PAD}" y="{y}" xml:space="preserve">')
        x = PAD
        for txt, fg, bold, dim in runs:
            style = f' fill="{fg}"'
            if bold:
                style += ' font-weight="700"'
            if dim:
                style += ' opacity="0.6"'
            out.append(
                f'<tspan x="{x}"{style}>{html.escape(txt)}</tspan>'
                if x == PAD else
                f'<tspan{style}>{html.escape(txt)}</tspan>'
            )
            x += len(txt) * CHAR_W
        out.append("</text>")
        y += LINE_H
    out.append("</svg>")

    with open(svg_path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(out) + "\n")
    print(f"wrote {svg_path}  ({w}x{h}, {len(lines)} lines)")


if __name__ == "__main__":
    render(sys.argv[1], sys.argv[2])
