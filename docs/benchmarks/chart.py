#!/usr/bin/env python3
"""Render Ouro comparative benchmark results to adaptive light/dark SVGs.

Writes `.luaudocs/public/benchmark-small.svg` (hero geometric-mean card for
README.md and the LuauDocs home page) and `.luaudocs/public/benchmark.svg`
(hero geometric means + all per-workload bars).
"""

from __future__ import annotations

import argparse
from collections.abc import Sequence
from dataclasses import dataclass, field
import html
import json
import math
from pathlib import Path
from typing import Any

BENCH_DIR = Path(__file__).resolve().parent
ROOT = BENCH_DIR.parents[1]
DEFAULT_RESULTS = BENCH_DIR / "results.json"
DEFAULT_OUT = ROOT / ".luaudocs" / "public" / "benchmark.svg"
DEFAULT_OUT_SMALL = ROOT / ".luaudocs" / "public" / "benchmark-small.svg"

W = 960
M_L = 24
M_R = 24
M_T = 22
GUTTER = 228
X0 = M_L + GUTTER  # 252
X1 = W - M_R  # 936
PLOT_W = X1 - X0  # 684

MAX_REL = 10.0
TICKS = (1, 2, 4, 6, 8, 10)

BAR_H = 14
BAR_GAP = 4
GROUP_PAD = 10
SECTION_HEAD = 28
HERO_BAR_H = 22
HERO_GAP = 7

# WCAG AA >= 4.5:1 against white text inside bars
COLORS: dict[str, str] = {
    "ouro": "#006AB4",
    "ouro_guarded": "#007A6B",
    "fiu_fast": "#A25100",
    "luauception": "#6851C3",
}

PARTICIPANT_ORDER = ("ouro", "ouro_guarded", "fiu_fast", "luauception")
COMPILE_ORDER = ("ouro", "luauception")


@dataclass(frozen=True)
class ParticipantMeta:
    key: str
    short_name: str
    scope: str
    repo_name: str
    tag: str
    url: str | None


PARTICIPANTS: dict[str, ParticipantMeta] = {
    "ouro": ParticipantMeta(
        key="ouro",
        short_name="ouro",
        scope="kohltastrophe/",
        repo_name="ouro",
        tag="0.1.0",
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
        tag="fast",
        url="https://github.com/rce-incorporated/Fiu",
    ),
    "luauception": ParticipantMeta(
        key="luauception",
        short_name="LuauCeption",
        scope="RadiatedExodus/",
        repo_name="LuauCeption",
        tag="0.654",
        url="https://github.com/RadiatedExodus/LuauCeption",
    ),
}


@dataclass
class Canvas:
    behind: list[str] = field(default_factory=list)
    front: list[str] = field(default_factory=list)
    group_index: int = 0


def esc(val: object) -> str:
    return html.escape(str(val), quote=True)


def xrel(v: float) -> float:
    return X0 + min(max(v, 0.0), MAX_REL) / MAX_REL * PLOT_W


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


def make_defs(theme: str) -> str:
    base = (
        "text{font-family:'Inter','Segoe UI',system-ui,-apple-system,sans-serif;"
        "-webkit-font-smoothing:antialiased}"
        ".mono{font-family:ui-monospace,'SF Mono',Menlo,Consolas,monospace}"
        ".b{font-weight:700}.b6{font-weight:600}"
        ".e{text-anchor:end}.m{text-anchor:middle}"
        ".o9{opacity:.92}.o7{opacity:.76}"
        ".lnk{text-decoration:none;text-decoration-thickness:.6px}"
        ".s95{font-size:9.5px}.s93{font-size:9.3px}.s85{font-size:8.5px}"
        ".s83{font-size:8.3px}.s10{font-size:10px}.s11{font-size:11px}"
        ".s125{font-size:12.5px}.s13{font-size:13px}"
        ".tw{fill:#ffffff}"
        ".dnfln{stroke-width:2}"
        ".dnfr{fill:url(#dnf);stroke-width:.8px}"
        ".dnf{font-weight:700;paint-order:stroke;stroke-width:2.6px;stroke-linejoin:round}"
    )
    light = (
        ".bg{fill:#ffffff}"
        ".tt{fill:#11181c}.tm{fill:#697177}.tl{fill:#3a4248}"
        ".grid{stroke:#e6e9ed;stroke-width:1;stroke-dasharray:2 4}"
        ".gridkey{stroke:#c3cbd2;stroke-width:1}"
        ".zebra{fill:#11181c;opacity:.022}"
        ".lnk:hover{fill:#11181c}"
        ".dnfbg{fill:#f6e4e3}.dnfln{stroke:#d99b98}"
        ".dnf{fill:#9b1c1c;stroke:#f6e4e3}"
        ".dnfr{stroke:#d99b98}"
    )
    dark = (
        ".bg{fill:#0d1117}"
        ".tt{fill:#e6edf3}.tm{fill:#8b949e}.tl{fill:#c3cbd6}"
        ".grid{stroke:#21262d;stroke-width:1;stroke-dasharray:2 4}"
        ".gridkey{stroke:#3a434d;stroke-width:1}"
        ".zebra{fill:#ffffff;opacity:.028}"
        ".lnk:hover{fill:#e6edf3}"
        ".dnfbg{fill:#2b1517}.dnfln{stroke:#6e2c30}"
        ".dnfr{stroke:#6e2c30}.dnf{fill:#ffb4af;stroke:#2b1517}"
    )
    if theme == "light":
        css = base + light
    elif theme == "dark":
        css = base + dark
    else:
        css = f"{base}{light}@media (prefers-color-scheme:dark){{{dark}}}"

    return (
        "<defs>"
        f"<style>{css}</style>"
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


def document(body: str, h: int, theme: str, aria_label: str) -> str:
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{h}" '
        f'viewBox="0 0 {W} {h}" role="img" aria-label="{esc(aria_label)}">'
        + make_defs(theme)
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


def _draw_bar(canvas: Canvas, by: float, color: str, rel: float, h: int = BAR_H, rx: int = 3) -> float:
    w = max(2.5, xrel(rel) - X0)
    mask = ' mask="url(#capfade)"' if rel > MAX_REL else ""
    canvas.front.append(
        f'<rect x="{X0}" y="{by:.1f}" width="{w:.1f}" height="{h}" rx="{rx}" fill="{color}"{mask}/>'
    )
    return w


def _draw_bar_label(
    canvas: Canvas,
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
            f'<text x="{X0 + 9}" y="{cy:.1f}" class="tw s93">'
            f'<tspan class="o9">{esc(name)}</tspan>'
            f'<tspan class="b" dx="5">{esc(mult)}</tspan>'
            f'<tspan class="o7 s83" dx="5">{esc(amount)}{esc(extra)}</tspan></text>'
        )
    else:
        canvas.front.append(
            f'<text x="{X0 + w + 7:.1f}" y="{cy:.1f}" class="tl s93">'
            f"<tspan>{esc(name)}</tspan>"
            f'<tspan class="tt b" dx="5">{esc(mult)}</tspan>'
            f'<tspan class="tm s83" dx="5">{esc(amount)}{esc(extra)}</tspan></text>'
        )


def _render_header(canvas: Canvas, title: str, meta: dict[str, Any], flag_label: str) -> float:
    canvas.front.append(
        f'<text x="{M_L}" y="{16 + M_T}" font-size="23" font-weight="800" class="tt">{esc(title)}</text>'
    )
    cpu = str(meta.get("cpu", "")).replace("AMD ", "").replace(" 8-Core Processor", "")
    luau_ver = meta.get("luau_version", "0.748")
    canvas.front.append(
        f'<text x="{M_L}" y="{37 + M_T}" class="tm s125">headless luau {esc(luau_ver)} '
        f'<tspan class="mono">{esc(flag_label)}</tspan>'
        f" · {esc(cpu)} · normalized per workload to fastest (shorter = faster)</text>"
    )
    y = 60 + M_T
    for t in TICKS:
        canvas.front.append(f'<text x="{xrel(t):.1f}" y="{y}" class="tm mono m s95">{t}×</text>')
    canvas.front.append(
        f'<text x="{X0 - 14}" y="{y}" class="tm e s95">relative time (lower is faster)</text>'
    )
    return y + 8


def _render_hero_block(
    canvas: Canvas,
    y: float,
    heading: str,
    sublabel: str,
    keys: Sequence[str],
    geos: dict[str, float | None],
    dnfs: dict[str, int],
    notes: dict[str, str] | None = None,
) -> float:
    present = [k for k in keys if geos.get(k) is not None]
    ordered = sorted(present, key=lambda k: (geos[k] or 0.0, k))

    y += 14
    canvas.front.append(
        f'<text x="{M_L}" y="{y:.1f}" class="tl b s11" letter-spacing="0.5">{esc(heading)}</text>'
    )
    canvas.front.append(
        f'<text x="{X1}" y="{y:.1f}" class="tm e s10">{esc(sublabel)}</text>'
    )
    y += 12

    for k in ordered:
        g = geos[k]
        assert g is not None
        meta = PARTICIPANTS[k]
        cy = y + HERO_BAR_H / 2 + 4.5
        canvas.front.append(
            f'<text x="{X0 - 12}" y="{cy:.1f}" class="tt b e s125">{_format_hero_label(meta)}</text>'
        )
        w = _draw_bar(canvas, y, COLORS[k], g, HERO_BAR_H, 4)
        label = fmt_hero_mult(g)
        suffix = notes.get(k, "") if notes else ""
        if dnfs.get(k, 0) > 0:
            suffix = f" ({dnfs[k]} DNF)" + (f" · {suffix}" if suffix else "")
        if suffix and w > 22 + 7.2 * len(label) + 5.8 * len(suffix):
            canvas.front.append(
                f'<text x="{X0 + 10}" y="{cy:.1f}" class="tw b s125">{esc(label)}'
                f'<tspan class="o7 s95" font-weight="500" dx="6">{esc(suffix.strip(" ·"))}</tspan></text>'
            )
        elif w > 18 + 7.2 * len(label):
            canvas.front.append(f'<text x="{X0 + 10}" y="{cy:.1f}" class="tw b s125">{esc(label)}</text>')
            if suffix:
                canvas.front.append(
                    f'<text x="{X0 + w + 8:.1f}" y="{cy:.1f}" class="tm s95">{esc(suffix.strip(" ·"))}</text>'
                )
        else:
            canvas.front.append(
                f'<text x="{X0 + w + 8:.1f}" y="{cy:.1f}" class="tt b s125">{esc(label)}'
                + (f'<tspan class="tm s95" font-weight="500" dx="6">{esc(suffix.strip(" ·"))}</tspan>' if suffix else "")
                + "</text>"
            )
        y += HERO_BAR_H + HERO_GAP

    return y


def _render_grid(y_top: float, y_bottom: float) -> list[str]:
    return [
        f'<line x1="{xrel(t):.1f}" y1="{y_top:.1f}" x2="{xrel(t):.1f}" y2="{y_bottom:.1f}" '
        f'class="{"gridkey" if t == 1 else "grid"}"/>'
        for t in TICKS
    ]


def _render_group(
    canvas: Canvas,
    y: float,
    row: dict[str, Any],
    keys: Sequence[str],
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
            f'<rect x="{M_L}" y="{y - 4:.1f}" width="{W - M_L - M_R}" '
            f'height="{gh + 8:.1f}" rx="4" class="zebra"/>'
        )
    canvas.group_index += 1

    label = row.get("name", "")
    sub = fmt_ms(best) if best is not None else ""
    if extra_label:
        sub = f"{extra_label} · {sub}" if sub else extra_label
    canvas.front.append(
        f'<text x="{X0 - 14}" y="{y + gh / 2 + 1:.1f}" class="tl mono e b6 s11">{esc(label)}</text>'
    )
    if sub:
        canvas.front.append(
            f'<text x="{X0 - 14}" y="{y + gh / 2 + 13:.1f}" class="tm mono e s85">{esc(sub)}</text>'
        )

    # Keep consistent fastest-first or canonical order per group (fastest completed first, then DNF)
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
        meta = PARTICIPANTS[k]
        if cell.get("status") != "ok" or best is None:
            canvas.front.append(
                f'<rect x="{X0}" y="{by:.1f}" width="{PLOT_W}" height="{BAR_H}" rx="3" class="dnfr"/>'
                f'<text x="{X0 + 9}" y="{by + BAR_H - 3.8:.1f}" class="dnf s93">'
                f"{esc(meta.short_name)} · DNF (error)</text>"
            )
        else:
            ms = float(cell["p50Ms"])
            rel = ms / max(best, 1e-9)
            w = _draw_bar(canvas, by, COLORS[k], rel)
            _draw_bar_label(canvas, by, meta.short_name, fmt_mult(rel), fmt_ms(ms), w)
        by += BAR_H + BAR_GAP

    return y + gh + GROUP_PAD


def _render_section_head(canvas: Canvas, y: float, title: str, sub: str) -> float:
    canvas.front.append(
        f'<text x="{M_L}" y="{y + 14:.1f}" class="tt b s13">{esc(title)}'
        f'<tspan class="tm s11" font-weight="500" dx="8">{esc(sub)}</tspan></text>'
    )
    return y + SECTION_HEAD


def _render_footer(total_h: int, meta: dict[str, Any], include_footprint: bool) -> str:
    fp = meta.get("footprint", {})
    ouro_fp = fp.get("ouro", {})
    fiu_fp = fp.get("fiu", {})
    lc_fp = fp.get("luauception", {})
    lines = [
        "Normalized per row to the fastest implementation (1.0×, shorter = faster) · median p50 of 7 warmed runs (5 for fib-24 and 250 KiB).",
        "Faded bars exceed 10× (true multiple labeled) · Ouro (guarded) sets instructionLimit = 50M; Fiu sets errorHandling = false, reuseClosures = true, useImportConstants = true.",
    ]
    if include_footprint and ouro_fp and fiu_fp and lc_fp.get("full_bytes"):
        lines.append(
            f"Footprint: Ouro {ouro_fp['files']} modular files ({fmt_size_bytes(ouro_fp['bytes'])}) · "
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
        out.append(f'<text x="{M_L}" y="{start_y + i * 14}" class="tm s95">{esc(line)}</text>')
    return "".join(out)


def render_pair(
    results: dict[str, Any],
    mode: str = "codegen",
    theme: str = "auto",
) -> tuple[str, str, int, int]:
    meta = results["meta"]
    mode_data = results["modes"][mode]
    flag_label = "--codegen -O2" if mode == "codegen" else "-O2"

    vm_rows = mode_data["vm"]
    compile_rows = mode_data["compile"]
    cold_row = mode_data["cold_load_run"]

    vm_geo, vm_done, vm_dnf = compute_geomeans(vm_rows, PARTICIPANT_ORDER)
    comp_geo, comp_done, comp_dnf = compute_geomeans(compile_rows, COMPILE_ORDER)

    vm_notes = {k: f"over {vm_done[k]} workloads" for k in ("luauception",) if vm_dnf.get(k, 0) > 0}
    comp_notes = {"ouro": "VM-only Fiu not included"}

    # ---- Compact hero SVG (README & landing page) ----
    small = Canvas()
    s_axis_top = _render_header(small, "Ouro vs Fiu vs LuauCeption", meta, flag_label)
    sy = _render_hero_block(
        small,
        s_axis_top + 6,
        "VM EXECUTION · GEOMETRIC MEAN",
        f"13 workloads (LuauCeption: {vm_done.get('luauception', 0)} + {vm_dnf.get('luauception', 0)} DNF)",
        PARTICIPANT_ORDER,
        vm_geo,
        vm_dnf,
        vm_notes,
    )
    sy = _render_hero_block(
        small,
        sy + 10,
        "O2 COMPILATION · GEOMETRIC MEAN",
        f"{len(compile_rows)} corpora · source to O2 bytecode",
        COMPILE_ORDER,
        comp_geo,
        comp_dnf,
        comp_notes,
    )
    small_h = int(math.ceil(sy + 62))
    small_grid = _render_grid(s_axis_top - 2, sy - 4)
    small_svg = document(
        "".join(small_grid) + "".join(small.front) + _render_footer(small_h, meta, include_footprint=False),
        small_h,
        theme,
        "Ouro vs Fiu vs LuauCeption geometric-mean comparison benchmark, lower is faster",
    )

    # ---- Full breakdown SVG (Benchmarks guide) ----
    full = Canvas()
    f_axis_top = _render_header(full, "Ouro vs Fiu vs LuauCeption", meta, flag_label)
    fy = _render_hero_block(
        full,
        f_axis_top + 6,
        "VM EXECUTION · GEOMETRIC MEAN",
        f"13 workloads (LuauCeption: {vm_done.get('luauception', 0)} + {vm_dnf.get('luauception', 0)} DNF)",
        PARTICIPANT_ORDER,
        vm_geo,
        vm_dnf,
        vm_notes,
    )
    fy = _render_hero_block(
        full,
        fy + 10,
        "O2 COMPILATION · GEOMETRIC MEAN",
        f"{len(compile_rows)} corpora · source to O2 bytecode",
        COMPILE_ORDER,
        comp_geo,
        comp_dnf,
        comp_notes,
    )

    fy += 18
    full.front.append(f'<text x="{M_L}" y="{fy:.1f}" class="tl b s11" letter-spacing="0.5">PER-BENCHMARK</text>')
    fy += 12

    fy = _render_section_head(full, fy, "vm execution", "warm persistent state, O2 bytecode (p50 ms)")
    for row in vm_rows:
        fy = _render_group(full, fy, row, PARTICIPANT_ORDER)
    fy += 6

    fy = _render_section_head(full, fy, "o2 compilation", "parse + O2 bytecode lowering (p50 ms)")
    for row in compile_rows:
        fy = _render_group(full, fy, row, COMPILE_ORDER)
    fy += 6

    fy = _render_section_head(full, fy, "cold startup", "fresh environment or state per load + 1k loop (p50 ms)")
    fy = _render_group(full, fy, cold_row, ("ouro", "fiu_fast", "luauception"), extra_label="load + run")

    grid_bottom = fy - GROUP_PAD + 4
    full_h = int(math.ceil(fy + 62))
    full_grid = _render_grid(f_axis_top - 2, grid_bottom)
    full_svg = document(
        "".join(full.behind)
        + "".join(full_grid)
        + "".join(full.front)
        + _render_footer(full_h, meta, include_footprint=True),
        full_h,
        theme,
        "Ouro vs Fiu vs LuauCeption full benchmark breakdown, lower is faster",
    )

    return full_svg, small_svg, full_h, small_h


def render_files(
    results_path: Path = DEFAULT_RESULTS,
    out_path: Path = DEFAULT_OUT,
    out_small_path: Path = DEFAULT_OUT_SMALL,
    mode: str = "codegen",
    theme: str = "auto",
) -> None:
    results = json.loads(results_path.read_text(encoding="utf-8"))
    full_svg, small_svg, full_h, small_h = render_pair(results, mode=mode, theme=theme)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_small_path.parent.mkdir(parents=True, exist_ok=True)
    out_small_path.write_text(small_svg, encoding="utf-8")
    out_path.write_text(full_svg, encoding="utf-8")
    print(f"wrote {out_small_path} ({W}x{small_h}px)")
    print(f"wrote {out_path} ({W}x{full_h}px)")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--results", type=Path, default=DEFAULT_RESULTS, help="Input results.json path")
    ap.add_argument("--out", type=Path, default=DEFAULT_OUT, help="Full SVG output path")
    ap.add_argument("--out-small", type=Path, default=DEFAULT_OUT_SMALL, help="Compact hero SVG output path")
    ap.add_argument("--mode", choices=("codegen", "interp"), default="codegen", help="Benchmark mode to render")
    ap.add_argument("--theme", choices=("auto", "light", "dark"), default="auto", help="Theme mode")
    args = ap.parse_args()
    render_files(args.results, args.out, args.out_small, mode=args.mode, theme=args.theme)


if __name__ == "__main__":
    main()
