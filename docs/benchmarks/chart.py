#!/usr/bin/env python3
"""Render Ouro comparative benchmark results to adaptive light/dark transparent SVGs.

Writes `chart-small.svg` (codegen geometric-mean card), `chart.svg` (full
`--codegen -O2` breakdown), and `chart-interp.svg` (full `-O2` interpreter
breakdown) into `--out-dir` (default: `docs/benchmarks`).
"""

from __future__ import annotations

import argparse
from collections.abc import Sequence
from dataclasses import dataclass, field
import html
import json
import math
from pathlib import Path
import re
from typing import Any

BENCH_DIR = Path(__file__).resolve().parent
DEFAULT_RESULTS = BENCH_DIR / "results.json"

W = 960
M_T_TRANS = 8
M_L_TRANS = 0
M_R_TRANS = 8
M_T_OPAQUE = 24
M_L_OPAQUE = 24
M_R_OPAQUE = 24
GUTTER = 232

MAX_REL = 10.0
TICKS = (1, 2, 4, 6, 8, 10)

BAR_H = 14
BAR_GAP = 4
GROUP_PAD = 10
SECTION_HEAD = 28
HERO_BAR_H = 22
HERO_GAP = 7

PARTICIPANT_ORDER = ("ouro", "ouro_guarded", "fiu_fast", "luauception")
COMPILE_ORDER = ("ouro", "luauception")


@dataclass(frozen=True)
class Layout:
    opaque: bool
    m_t: int
    m_l: int
    m_r: int
    x0: int
    x1: int
    plot_w: int

    def xrel(self, v: float) -> float:
        return self.x0 + min(max(v, 0.0), MAX_REL) / MAX_REL * self.plot_w


@dataclass(frozen=True)
class ParticipantMeta:
    key: str
    short_name: str
    scope: str
    repo_name: str
    tag: str
    url: str | None


@dataclass
class Canvas:
    behind: list[str] = field(default_factory=list)
    front: list[str] = field(default_factory=list)
    group_index: int = 0


def make_layout(opaque: bool = False) -> Layout:
    m_t = M_T_OPAQUE if opaque else M_T_TRANS
    m_l = M_L_OPAQUE if opaque else M_L_TRANS
    m_r = M_R_OPAQUE if opaque else M_R_TRANS
    x0 = m_l + GUTTER
    x1 = W - m_r
    return Layout(opaque=opaque, m_t=m_t, m_l=m_l, m_r=m_r, x0=x0, x1=x1, plot_w=x1 - x0)


def _oklch_to_hex(L: float, C: float, H: float) -> str:
    h = math.radians(H)
    a, b = C * math.cos(h), C * math.sin(h)

    l_ = L + 0.3963377774 * a + 0.2158037573 * b
    m_ = L - 0.1055613458 * a - 0.0638541728 * b
    s_ = L - 0.0894841775 * a - 1.2914855480 * b
    l, m, s = l_**3, m_**3, s_**3

    r = +4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
    g = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
    bl = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s

    def to_srgb(u: float) -> int:
        u = max(0.0, min(1.0, u))
        u = 1.055 * u ** (1 / 2.4) - 0.055 if u > 0.0031308 else 12.92 * u
        return round(max(0.0, min(1.0, u)) * 255)

    return f"#{to_srgb(r):02X}{to_srgb(g):02X}{to_srgb(bl):02X}"


def rainbow(n: int, L: float = 0.52, C: float = 0.17) -> list[str]:
    """Generate `n` perceptual Oklch bar colors with WCAG AA contrast against white text."""
    if n <= 0:
        return []
    return [_oklch_to_hex(L, C, 360.0 * (i / n)) for i in range(n)]


def build_participants(meta: dict[str, Any]) -> dict[str, ParticipantMeta]:
    ouro_ver = str(meta.get("ouro_version") or "0.1.0")
    fiu_label = str(meta.get("fiu_label") or "fast")
    lc_ver = str(meta.get("luauception_version") or "0.654")
    return {
        "ouro": ParticipantMeta(
            key="ouro",
            short_name="ouro",
            scope="kohltastrophe/",
            repo_name="ouro",
            tag=ouro_ver,
            url="https://github.com/kohltastrophe/ouro",
        ),
        "ouro_guarded": ParticipantMeta(
            key="ouro_guarded",
            short_name="ouro (guarded)",
            scope="kohltastrophe/",
            repo_name="ouro (guarded)",
            tag="50M cap",
            url="https://ouro.kohl.gg/guide/pipeline/vm#execution-guards",
        ),
        "fiu_fast": ParticipantMeta(
            key="fiu_fast",
            short_name="Fiu",
            scope="rce-incorporated/",
            repo_name="Fiu",
            tag=fiu_label,
            url="https://github.com/rce-incorporated/Fiu",
        ),
        "luauception": ParticipantMeta(
            key="luauception",
            short_name="LuauCeption",
            scope="RadiatedExodus/",
            repo_name="LuauCeption",
            tag=lc_ver,
            url="https://github.com/RadiatedExodus/LuauCeption",
        ),
    }


def esc(val: object) -> str:
    return html.escape(str(val), quote=True)


def fmt_mult(v: float) -> str:
    if v >= 10:
        return f"{v:.1f}×" if v < 20 else f"{v:.0f}×"
    return f"{v:.2f}×" if v < 2 else f"{v:.1f}×"


def fmt_hero_mult(v: float) -> str:
    if v >= 10:
        return f"{v:.1f}×"
    return f"{v:.2f}×"


def fmt_ms(ms: float) -> str:
    if ms >= 1000:
        return f"{ms:.0f} ms"
    if ms >= 100:
        return f"{ms:.1f} ms"
    if ms >= 1:
        return f"{ms:.2f} ms"
    return f"{ms:.3f} ms"


def fmt_size_bytes(n: int) -> str:
    if n >= 1048576:
        return f"{n / 1048576:.2f} MiB"
    return f"{n / 1024:.0f} KiB"


def format_cpu(raw: str) -> str:
    cpu = raw.replace("(R)", "").replace("(TM)", "")
    cpu = re.sub(r"\b\d+-Core Processor\b", "", cpu, flags=re.IGNORECASE)
    cpu = re.sub(r"\bProcessor\b", "", cpu, flags=re.IGNORECASE)
    cpu = re.sub(r"\bCPU\s*@.*$", "", cpu)
    cpu = re.sub(r"\s+", " ", cpu).strip()
    if len(cpu) > 34:
        cpu = cpu[:34].rstrip()
    return cpu


def make_defs(opaque: bool) -> str:
    bg_light = ".bg{fill:#fff}" if opaque else ".bg{fill:none}"
    bg_dark = ".bg{fill:#0d1117}" if opaque else ""
    style = (
        "<style>"
        "text{font-family:'Inter','Segoe UI',system-ui,-apple-system,sans-serif;"
        "-webkit-font-smoothing:antialiased}"
        ".mono{font-family:ui-monospace,'SF Mono',Menlo,Consolas,monospace}"
        f"{bg_light}"
        ".tt{fill:#11181c}.tm{fill:#697177}.tl{fill:#3a4248}.tw{fill:#fff}"
        ".grid{stroke:#e6e9ed;stroke-width:1;stroke-dasharray:2 4}"
        ".gridkey{stroke:#c3cbd2;stroke-width:1}"
        ".zebra{fill:#11181c;opacity:.022}"
        ".b{font-weight:700}.b6{font-weight:600}"
        ".e{text-anchor:end}.m{text-anchor:middle}"
        ".o9{opacity:.9}.o7{opacity:.72}"
        ".lnk{text-decoration:none;text-decoration-thickness:.6px}"
        ".lnk:hover{fill:#11181c}"
        ".s95{font-size:9.5px}.s93{font-size:9.3px}.s85{font-size:8.5px}"
        ".s83{font-size:8.3px}.s10{font-size:10px}.s11{font-size:11px}"
        ".s125{font-size:12.5px}.s13{font-size:13px}"
        ".dnfbg{fill:#f6e4e3}.dnfln{stroke:#d99b98;stroke-width:2}"
        ".dnfr{fill:url(#dnf);stroke:#d99b98;stroke-width:.8px}"
        ".dnf{fill:#9b1c1c;font-weight:700;paint-order:stroke;stroke:#f6e4e3;"
        "stroke-width:2.6px;stroke-linejoin:round}"
        "@media (prefers-color-scheme:dark){"
        ".tt{fill:#e6edf3}.tm{fill:#8b949e}.tl{fill:#c3cbd6}"
        ".grid{stroke:#21262d}.gridkey{stroke:#3a434d}"
        ".zebra{fill:#ffffff;opacity:.025}"
        ".lnk:hover{fill:#e6edf3}"
        ".dnfbg{fill:#2b1517}.dnfln{stroke:#6e2c30}"
        ".dnfr{stroke:#6e2c30}.dnf{fill:#ff8e88;stroke:#2b1517}"
        f"{bg_dark}"
        "}"
        "</style>"
    )
    return (
        "<defs>"
        f"{style}"
        '<linearGradient id="capgrad" x1="0" y1="0" x2="1" y2="0">'
        '<stop offset="0" stop-color="#fff"/>'
        '<stop offset="0.86" stop-color="#fff"/>'
        '<stop offset="1" stop-color="#fff" stop-opacity="0.18"/>'
        "</linearGradient>"
        '<mask id="capfade" maskContentUnits="objectBoundingBox">'
        '<rect width="1" height="1" fill="url(#capgrad)"/></mask>'
        '<pattern id="dnf" width="6" height="6" patternUnits="userSpaceOnUse" '
        'patternTransform="rotate(45)"><rect width="6" height="6" class="dnfbg"/>'
        '<line x1="0" y1="0" x2="0" y2="6" class="dnfln"/>'
        "</pattern></defs>"
    )


def document(body: str, h: int, opaque: bool, aria_label: str) -> str:
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{h}" '
        f'viewBox="0 0 {W} {h}" role="img" aria-label="{esc(aria_label)}">'
        + make_defs(opaque)
        + f'<rect x="0" y="0" width="{W}" height="{h}" class="bg"/>'
        + body
        + "</svg>\n"
    )


def compute_geomeans(
    rows: Sequence[dict[str, Any]],
    keys: Sequence[str],
) -> tuple[dict[str, float | None], dict[str, int], dict[str, int]]:
    """Compute geometric mean of per-row relative time (normalized to fastest in row)."""
    logs: dict[str, list[float]] = {k: [] for k in keys}
    completed: dict[str, int] = {k: 0 for k in keys}
    dnfs: dict[str, int] = {k: 0 for k in keys}

    for row in rows:
        ok_vals = [
            float(row[k]["p50Ms"])
            for k in keys
            if isinstance(row.get(k), dict) and row[k].get("status") == "ok"
        ]
        if not ok_vals:
            continue
        best = min(ok_vals)
        for k in keys:
            cell = row.get(k)
            if not isinstance(cell, dict):
                continue
            if cell.get("status") == "ok":
                val = max(float(cell["p50Ms"]), 1e-9)
                logs[k].append(math.log(val / max(best, 1e-9)))
                completed[k] += 1
            else:
                dnfs[k] += 1

    geos = {k: math.exp(sum(xs) / len(xs)) if xs else None for k, xs in logs.items()}
    return geos, completed, dnfs


def _format_hero_label(meta: ParticipantMeta) -> str:
    if meta.scope:
        name_svg = f'<tspan class="tm">{esc(meta.scope)}</tspan>{esc(meta.repo_name)}'
    else:
        name_svg = esc(meta.repo_name)
    if meta.url:
        name_svg = f'<a href="{esc(meta.url)}" class="lnk" target="_blank">{name_svg}</a>'
    tag_svg = f'<tspan class="tm s85" font-weight="500" dx="5">{esc(meta.tag)}</tspan>' if meta.tag else ""
    return f"{name_svg}{tag_svg}"


def _draw_bar(
    canvas: Canvas,
    layout: Layout,
    by: float,
    color: str,
    rel: float,
    h: int = BAR_H,
    rx: int = 3,
) -> float:
    w = max(2.5, layout.xrel(rel) - layout.x0)
    mask = ' mask="url(#capfade)"' if rel > MAX_REL else ""
    canvas.front.append(
        f'<rect x="{layout.x0}" y="{by:.1f}" width="{w:.1f}" height="{h}" rx="{rx}" fill="{color}"{mask}/>'
    )
    return w


def _draw_bar_label(
    canvas: Canvas,
    layout: Layout,
    by: float,
    name: str,
    mult: str,
    amount: str,
    w: float,
    extra: str = "",
) -> None:
    cy = by + BAR_H / 2 + 3.3
    full = f"{name} {mult} {amount}{extra}"
    inside = w > 18 + 5.5 * len(full)
    if inside:
        canvas.front.append(
            f'<text x="{layout.x0 + 9}" y="{cy:.1f}" class="tw s93">'
            f'<tspan class="o9">{esc(name)}</tspan>'
            f'<tspan class="b" dx="5">{esc(mult)}</tspan>'
            f'<tspan class="o7 s83" dx="5">{esc(amount)}{esc(extra)}</tspan></text>'
        )
    else:
        canvas.front.append(
            f'<text x="{layout.x0 + w + 7:.1f}" y="{cy:.1f}" class="tl s93">'
            f"<tspan>{esc(name)}</tspan>"
            f'<tspan class="tt b" dx="5">{esc(mult)}</tspan>'
            f'<tspan class="tm s83" dx="5">{esc(amount)}{esc(extra)}</tspan></text>'
        )


def _render_header(canvas: Canvas, layout: Layout, title: str, meta: dict[str, Any], flag_label: str) -> float:
    canvas.front.append(
        f'<text x="{layout.m_l}" y="{16 + layout.m_t}" font-size="23" font-weight="800" class="tt">{esc(title)}</text>'
    )
    cpu = format_cpu(str(meta.get("cpu", "")))
    luau_ver = meta.get("luau_version", "0.748")
    cpu_seg = f" · {esc(cpu)}" if cpu else ""
    canvas.front.append(
        f'<text x="{layout.m_l}" y="{37 + layout.m_t}" class="tm s125">headless luau {esc(luau_ver)} '
        f'<tspan class="mono">{esc(flag_label)}</tspan>'
        f"{cpu_seg} · normalized per row to fastest (shorter = faster)</text>"
    )
    y = 60 + layout.m_t
    for t in TICKS:
        canvas.front.append(f'<text x="{layout.xrel(t):.1f}" y="{y}" class="tm mono m s95">{t}×</text>')
    canvas.front.append(
        f'<text x="{layout.x0 - 14}" y="{y}" class="tm e s95">relative time (lower is faster)</text>'
    )
    return y + 8


def _render_hero_block(
    canvas: Canvas,
    layout: Layout,
    y: float,
    heading: str,
    sublabel: str,
    keys: Sequence[str],
    geos: dict[str, float | None],
    dnfs: dict[str, int],
    colors: dict[str, str],
    participants: dict[str, ParticipantMeta],
    notes: dict[str, str] | None = None,
) -> float:
    present = [k for k in keys if geos.get(k) is not None]
    ordered = sorted(present, key=lambda k: (geos[k] or 0.0, k))

    y += 14
    canvas.front.append(
        f'<text x="{layout.m_l}" y="{y:.1f}" class="tl b s11" letter-spacing="0.5">{esc(heading)}</text>'
    )
    canvas.front.append(
        f'<text x="{layout.x1}" y="{y:.1f}" class="tm e s10">{esc(sublabel)}</text>'
    )
    y += 12

    for k in ordered:
        g = geos[k]
        assert g is not None
        pmeta = participants[k]
        cy = y + HERO_BAR_H / 2 + 4.5
        canvas.front.append(
            f'<text x="{layout.x0 - 12}" y="{cy:.1f}" class="tt b e s125">{_format_hero_label(pmeta)}</text>'
        )
        w = _draw_bar(canvas, layout, y, colors[k], g, HERO_BAR_H, 4)
        label = fmt_hero_mult(g)
        suffix = notes.get(k, "") if notes else ""
        if dnfs.get(k, 0) > 0:
            suffix = f" ({dnfs[k]} DNF)" + (f" · {suffix}" if suffix else "")
        if suffix and w > 22 + 7.2 * len(label) + 5.8 * len(suffix):
            canvas.front.append(
                f'<text x="{layout.x0 + 10}" y="{cy:.1f}" class="tw b s125">{esc(label)}'
                f'<tspan class="o7 s95" font-weight="500" dx="6">{esc(suffix.strip(" ·"))}</tspan></text>'
            )
        elif w > 18 + 7.2 * len(label):
            canvas.front.append(f'<text x="{layout.x0 + 10}" y="{cy:.1f}" class="tw b s125">{esc(label)}</text>')
            if suffix:
                canvas.front.append(
                    f'<text x="{layout.x0 + w + 8:.1f}" y="{cy:.1f}" class="tm s95">{esc(suffix.strip(" ·"))}</text>'
                )
        else:
            canvas.front.append(
                f'<text x="{layout.x0 + w + 8:.1f}" y="{cy:.1f}" class="tt b s125">{esc(label)}'
                + (
                    f'<tspan class="tm s95" font-weight="500" dx="6">{esc(suffix.strip(" ·"))}</tspan>'
                    if suffix
                    else ""
                )
                + "</text>"
            )
        y += HERO_BAR_H + HERO_GAP

    return y


def _render_grid(layout: Layout, y_top: float, y_bottom: float) -> list[str]:
    return [
        f'<line x1="{layout.xrel(t):.1f}" y1="{y_top:.1f}" x2="{layout.xrel(t):.1f}" y2="{y_bottom:.1f}" '
        f'class="{"gridkey" if t == 1 else "grid"}"/>'
        for t in TICKS
    ]


def _render_group(
    canvas: Canvas,
    layout: Layout,
    y: float,
    row: dict[str, Any],
    keys: Sequence[str],
    colors: dict[str, str],
    participants: dict[str, ParticipantMeta],
    extra_label: str = "",
) -> float:
    present = [k for k in keys if isinstance(row.get(k), dict)]
    if not present:
        return y

    ok_vals = [float(row[k]["p50Ms"]) for k in present if row[k].get("status") == "ok"]
    best = min(ok_vals) if ok_vals else None

    gh = len(present) * BAR_H + max(0, len(present) - 1) * BAR_GAP
    if canvas.group_index % 2 == 1:
        canvas.behind.append(
            f'<rect x="{layout.m_l}" y="{y - 4:.1f}" width="{W - layout.m_l - layout.m_r}" '
            f'height="{gh + 8:.1f}" rx="4" class="zebra"/>'
        )
    canvas.group_index += 1

    label = row.get("name", "")
    sub = fmt_ms(best) if best is not None else ""
    if extra_label:
        sub = f"{extra_label} · {sub}" if sub else extra_label
    canvas.front.append(
        f'<text x="{layout.x0 - 14}" y="{y + gh / 2 + 1:.1f}" class="tl mono e b6 s11">{esc(label)}</text>'
    )
    if sub:
        canvas.front.append(
            f'<text x="{layout.x0 - 14}" y="{y + gh / 2 + 13:.1f}" class="tm mono e s85">{esc(sub)}</text>'
        )

    ordered = sorted(
        present,
        key=lambda k: (
            0 if row[k].get("status") == "ok" else 1,
            float(row[k]["p50Ms"]) if row[k].get("status") == "ok" else float("inf"),
            PARTICIPANT_ORDER.index(k),
        ),
    )

    by = y
    for k in ordered:
        cell = row[k]
        pmeta = participants[k]
        if cell.get("status") != "ok" or best is None:
            canvas.front.append(
                f'<rect x="{layout.x0}" y="{by:.1f}" width="{layout.plot_w}" height="{BAR_H}" rx="3" class="dnfr"/>'
                f'<text x="{layout.x0 + 9}" y="{by + BAR_H - 3.8:.1f}" class="dnf s93">'
                f"{esc(pmeta.short_name)} · DNF (error)</text>"
            )
        else:
            ms = float(cell["p50Ms"])
            rel = ms / max(best, 1e-9)
            w = _draw_bar(canvas, layout, by, colors[k], rel)
            _draw_bar_label(canvas, layout, by, pmeta.short_name, fmt_mult(rel), fmt_ms(ms), w)
        by += BAR_H + BAR_GAP

    return y + gh + GROUP_PAD


def _render_section_head(canvas: Canvas, layout: Layout, y: float, title: str, sub: str) -> float:
    canvas.front.append(
        f'<text x="{layout.m_l}" y="{y + 14:.1f}" class="tt b s13">{esc(title)}'
        f'<tspan class="tm s11" font-weight="500" dx="8">{esc(sub)}</tspan></text>'
    )
    return y + SECTION_HEAD


def _render_footer(layout: Layout, total_h: int, meta: dict[str, Any], include_footprint: bool) -> str:
    fp = meta.get("footprint", {})
    ouro_fp = fp.get("ouro", {})
    fiu_fp = fp.get("fiu", {})
    lc_fp = fp.get("luauception", {})
    lines = [
        "Normalized per row to fastest (1.0×, shorter = faster) · median p50 of 7 warmed runs (5 for fib-24 and 250 KiB).",
        "Faded bars exceed 10× (true multiple labeled) · Ouro (guarded) sets instructionLimit = 50M; Fiu sets errorHandling = false, reuseClosures = true, useImportConstants = true.",
    ]
    if include_footprint and ouro_fp and fiu_fp and lc_fp.get("full_bytes"):
        lines.append(
            f"Footprint: Ouro {ouro_fp['files']} files ({fmt_size_bytes(ouro_fp['bytes'])}) · "
            f"Fiu VM-only ({fmt_size_bytes(fiu_fp['bytes'])}) · "
            f"LuauCeption Full ({fmt_size_bytes(lc_fp['full_bytes'])}). LuauCeption errors on pcall-2k (±10% run-to-run noise)."
        )
    else:
        lines.append(
            "LuauCeption errors on pcall-2k (Infinity), so its VM geomean covers the 12 workloads it completes · ±10% run-to-run noise."
        )

    out = []
    start_y = total_h - 11 - (len(lines) - 1) * 14
    for i, line in enumerate(lines):
        out.append(f'<text x="{layout.m_l}" y="{start_y + i * 14}" class="tm s95">{esc(line)}</text>')
    return "".join(out)


def render_mode_svgs(
    results: dict[str, Any],
    mode: str = "codegen",
    opaque: bool = False,
) -> tuple[str, str, int, int]:
    """Render `(full_svg, small_svg, full_h, small_h)` for `mode`."""
    layout = make_layout(opaque)
    meta = results["meta"]
    participants = build_participants(meta)
    mode_data = results["modes"][mode]
    flag_label = "--codegen -O2" if mode == "codegen" else "-O2"

    vm_rows = mode_data["vm"]
    compile_rows = mode_data["compile"]
    cold_row = mode_data["cold_load_run"]

    present_vm = [
        k
        for k in PARTICIPANT_ORDER
        if any(isinstance(r.get(k), dict) for r in vm_rows)
    ]
    present_compile = [k for k in COMPILE_ORDER if k in present_vm]

    vm_geo, vm_done, vm_dnf = compute_geomeans(vm_rows, present_vm)
    comp_geo, comp_done, comp_dnf = compute_geomeans(compile_rows, present_compile)

    ranked_participants = sorted(
        [k for k in present_vm if vm_geo.get(k) is not None],
        key=lambda k: (vm_geo[k] or 0.0, PARTICIPANT_ORDER.index(k)),
    )
    for k in PARTICIPANT_ORDER:
        if k not in ranked_participants:
            ranked_participants.append(k)
    colors = dict(zip(ranked_participants, rainbow(len(ranked_participants))))

    vm_notes = {k: f"over {vm_done[k]} workloads" for k in ("luauception",) if vm_dnf.get(k, 0) > 0}
    comp_notes = {"ouro": "VM-only Fiu not included"}

    # ---- Compact hero SVG ----
    small = Canvas()
    s_axis_top = _render_header(small, layout, "Ouro vs Fiu vs LuauCeption", meta, flag_label)
    lc_sub = (
        f"13 workloads (LuauCeption: {vm_done.get('luauception', 0)} + {vm_dnf.get('luauception', 0)} DNF)"
        if "luauception" in present_vm
        else "13 workloads"
    )
    sy = _render_hero_block(
        small,
        layout,
        s_axis_top + 6,
        "VM EXECUTION · GEOMETRIC MEAN",
        lc_sub,
        present_vm,
        vm_geo,
        vm_dnf,
        colors,
        participants,
        vm_notes,
    )
    sy = _render_hero_block(
        small,
        layout,
        sy + 10,
        "O2 COMPILATION · GEOMETRIC MEAN",
        f"{len(compile_rows)} corpora · source to O2 bytecode",
        present_compile,
        comp_geo,
        comp_dnf,
        colors,
        participants,
        comp_notes,
    )
    small_h = int(math.ceil(sy + 62))
    small_grid = _render_grid(layout, s_axis_top - 2, sy - 4)
    small_svg = document(
        "".join(small_grid) + "".join(small.front) + _render_footer(layout, small_h, meta, include_footprint=False),
        small_h,
        layout.opaque,
        "Ouro vs Fiu vs LuauCeption geometric-mean comparison benchmark, lower is faster",
    )

    # ---- Full breakdown SVG ----
    full = Canvas()
    f_axis_top = _render_header(full, layout, "Ouro vs Fiu vs LuauCeption", meta, flag_label)
    fy = _render_hero_block(
        full,
        layout,
        f_axis_top + 6,
        "VM EXECUTION · GEOMETRIC MEAN",
        lc_sub,
        present_vm,
        vm_geo,
        vm_dnf,
        colors,
        participants,
        vm_notes,
    )
    fy = _render_hero_block(
        full,
        layout,
        fy + 10,
        "O2 COMPILATION · GEOMETRIC MEAN",
        f"{len(compile_rows)} corpora · source to O2 bytecode",
        present_compile,
        comp_geo,
        comp_dnf,
        colors,
        participants,
        comp_notes,
    )

    fy += 18
    full.front.append(f'<text x="{layout.m_l}" y="{fy:.1f}" class="tl b s11" letter-spacing="0.5">PER-BENCHMARK</text>')
    fy += 12

    fy = _render_section_head(full, layout, fy, "vm execution", "warm persistent state, O2 bytecode (p50 ms)")
    for row in vm_rows:
        fy = _render_group(full, layout, fy, row, present_vm, colors, participants)
    fy += 6

    fy = _render_section_head(full, layout, fy, "o2 compilation", "parse + O2 bytecode lowering (p50 ms)")
    for row in compile_rows:
        fy = _render_group(full, layout, fy, row, present_compile, colors, participants)
    fy += 6

    fy = _render_section_head(
        full,
        layout,
        fy,
        "cold startup",
        "fresh env / state load + 1k loop, and cold root require (p50 ms)",
    )
    cold_keys = [k for k in ("ouro", "fiu_fast", "luauception") if k in present_vm]
    fy = _render_group(full, layout, fy, cold_row, cold_keys, colors, participants, extra_label="load + run")

    cold_req = mode_data.get("cold_require")
    if isinstance(cold_req, dict) and cold_req.get("ouro_root_ms") is not None:
        req_row: dict[str, Any] = {
            "name": "cold-require",
            "ouro": {"status": "ok", "p50Ms": float(cold_req["ouro_root_ms"])},
        }
        if cold_req.get("fiu_ms") is not None:
            req_row["fiu_fast"] = {"status": "ok", "p50Ms": float(cold_req["fiu_ms"])}
        if cold_req.get("luauception_full_ms") is not None:
            req_row["luauception"] = {"status": "ok", "p50Ms": float(cold_req["luauception_full_ms"])}
        fy = _render_group(full, layout, fy, req_row, cold_keys, colors, participants, extra_label="root require")

    grid_bottom = fy - GROUP_PAD + 4
    full_h = int(math.ceil(fy + 62))
    full_grid = _render_grid(layout, f_axis_top - 2, grid_bottom)
    full_svg = document(
        "".join(full.behind)
        + "".join(full_grid)
        + "".join(full.front)
        + _render_footer(layout, full_h, meta, include_footprint=True),
        full_h,
        layout.opaque,
        "Ouro vs Fiu vs LuauCeption full benchmark breakdown, lower is faster",
    )

    return full_svg, small_svg, full_h, small_h


def render_all(
    results_path: Path = DEFAULT_RESULTS,
    out_dir: Path = BENCH_DIR,
    opaque: bool = False,
) -> None:
    """Render `chart-small.svg`, `chart.svg`, and `chart-interp.svg` from `results_path`."""
    results = json.loads(results_path.read_text(encoding="utf-8"))
    out_dir.mkdir(parents=True, exist_ok=True)

    full_codegen, small_codegen, cg_h, sm_h = render_mode_svgs(results, mode="codegen", opaque=opaque)
    small_path = out_dir / "chart-small.svg"
    full_path = out_dir / "chart.svg"
    small_path.write_text(small_codegen, encoding="utf-8")
    full_path.write_text(full_codegen, encoding="utf-8")
    print(f"wrote {small_path} ({W}x{sm_h}px)")
    print(f"wrote {full_path} ({W}x{cg_h}px)")

    if "interp" in results.get("modes", {}):
        full_interp, _, interp_h, _ = render_mode_svgs(results, mode="interp", opaque=opaque)
        interp_path = out_dir / "chart-interp.svg"
        interp_path.write_text(full_interp, encoding="utf-8")
        print(f"wrote {interp_path} ({W}x{interp_h}px)")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--results", type=Path, default=DEFAULT_RESULTS, help="Input results.json path")
    ap.add_argument("--out-dir", type=Path, default=BENCH_DIR, help="Directory for chart-small.svg, chart.svg, and chart-interp.svg")
    ap.add_argument("--opaque", action="store_true", help="Render opaque light/dark card background instead of transparent")
    args = ap.parse_args()
    render_all(args.results, args.out_dir, opaque=args.opaque)


if __name__ == "__main__":
    main()
