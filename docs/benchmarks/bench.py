#!/usr/bin/env python3
"""Run sequential Ouro comparative benchmarks and regenerate comparison SVG charts.

Works standalone (measuring Ouro only) or with optional Fiu and LuauCeption paths.
Stages temporary `@ouro`, `@fiu`, and `@lc` aliases in a temp directory so the
repository `.luaurc` remains untouched, and runs every measurement sequentially to
avoid CPU/cache contention.
"""

from __future__ import annotations

import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import json
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile
from typing import Any, Iterator

import chart

ROOT = Path(__file__).resolve().parents[2]
BENCH_DIR = Path(__file__).resolve().parent
RUN_LUAU = BENCH_DIR / "run.luau"
DEFAULT_OUT = BENCH_DIR / "results.json"


def _read_cpu_model() -> str:
    cpuinfo = Path("/proc/cpuinfo")
    if cpuinfo.is_file():
        for line in cpuinfo.read_text(encoding="utf-8", errors="ignore").splitlines():
            if line.lower().startswith("model name"):
                _, _, rhs = line.partition(":")
                return rhs.strip()
    return platform.processor() or platform.machine()


def _luau_version() -> str:
    upstream = ROOT / "UPSTREAM.json"
    if upstream.is_file():
        data = json.loads(upstream.read_text(encoding="utf-8"))
        if isinstance(data.get("version"), str):
            return data["version"]
    return "0.748"


def _run_luau(script: Path, flags: list[str], extra_args: list[str] | None = None, cwd: Path | None = None) -> str:
    cmd = ["luau", *flags, str(script)]
    if extra_args:
        cmd.extend(["-a", *extra_args])
    proc = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, check=False)
    if proc.returncode != 0:
        raise RuntimeError(
            f"command failed ({proc.returncode}): {' '.join(cmd)}\nstdout:\n{proc.stdout}\nstderr:\n{proc.stderr}"
        )
    return proc.stdout


def _probe_cold_require(stage_dir: Path, flags: list[str], expr: str, samples: int = 3) -> float:
    probe = stage_dir / "_cold_probe.luau"
    probe.write_text(
        f"local t0 = os.clock()\n{expr}\nprint(string.format('%.6f', (os.clock() - t0) * 1000))\n",
        encoding="utf-8",
    )
    vals: list[float] = []
    for _ in range(samples):
        out = _run_luau(probe, flags, cwd=stage_dir).strip().splitlines()[-1]
        vals.append(float(out))
    vals.sort()
    return vals[len(vals) // 2]


def _measure_cold_requires(stage_dir: Path, flags: list[str], has_fiu: bool, has_lc: bool) -> dict[str, Any]:
    ouro_root = _probe_cold_require(stage_dir, flags, 'local _ = require("@ouro")')

    inc_script = stage_dir / "_cold_ouro_steps.luau"
    inc_script.write_text(
        """
local t0 = os.clock(); local Ouro = require("@ouro"); local rootMs = (os.clock() - t0) * 1000
local t1 = os.clock(); local _ = Ouro.VM; local vmMs = (os.clock() - t1) * 1000
local t2 = os.clock(); local _ = Ouro.parse("return 1"); local parseMs = (os.clock() - t2) * 1000
local t3 = os.clock(); local _ = Ouro.Compiler; local compMs = (os.clock() - t3) * 1000
print(string.format("%.6f %.6f %.6f %.6f", rootMs, vmMs, parseMs, compMs))
""".strip()
        + "\n",
        encoding="utf-8",
    )
    root_samples: list[float] = []
    vm_samples: list[float] = []
    parse_samples: list[float] = []
    comp_samples: list[float] = []
    for _ in range(3):
        parts = [float(x) for x in _run_luau(inc_script, flags, cwd=stage_dir).strip().splitlines()[-1].split()]
        root_samples.append(parts[0])
        vm_samples.append(parts[1])
        parse_samples.append(parts[2])
        comp_samples.append(parts[3])
    for s in (root_samples, vm_samples, parse_samples, comp_samples):
        s.sort()

    res: dict[str, Any] = {
        "ouro_root_ms": round(ouro_root, 3),
        "ouro_vm_ms": round(vm_samples[1], 3),
        "ouro_parser_ms": round(parse_samples[1], 3),
        "ouro_compiler_ms": round(comp_samples[1], 3),
        "ouro_total_ms": round(root_samples[1] + vm_samples[1] + parse_samples[1] + comp_samples[1], 3),
    }
    if has_fiu:
        res["fiu_ms"] = round(_probe_cold_require(stage_dir, flags, 'local _ = require("@fiu")'), 3)
    if has_lc:
        res["luauception_full_ms"] = round(_probe_cold_require(stage_dir, flags, 'local _ = require("@lc/Full")'), 3)
        res["luauception_compiler_ms"] = round(
            _probe_cold_require(stage_dir, flags, 'local _ = require("@lc/Compiler")'), 3
        )
        res["luauception_vm_ms"] = round(_probe_cold_require(stage_dir, flags, 'local _ = require("@lc/VM")'), 3)
    return res


def _footprint(fiu_path: Path | None, lc_dir: Path | None) -> dict[str, Any]:
    src_files = sorted((ROOT / "src").rglob("*.luau"))
    src_bytes = sum(p.stat().st_size for p in src_files)
    fp: dict[str, Any] = {
        "ouro": {
            "files": len(src_files),
            "bytes": src_bytes,
        }
    }
    if fiu_path is not None and fiu_path.is_file():
        fp["fiu"] = {"files": 1, "bytes": fiu_path.stat().st_size}
    if lc_dir is not None and lc_dir.is_dir():
        full = lc_dir / "Full.luau"
        comp = lc_dir / "Compiler.luau"
        vm = lc_dir / "VM.luau"
        fp["luauception"] = {
            "full_bytes": full.stat().st_size if full.is_file() else None,
            "compiler_bytes": comp.stat().st_size if comp.is_file() else None,
            "vm_bytes": vm.stat().st_size if vm.is_file() else None,
        }
    return fp


def _resolve_inputs(fiu_path: Path | None, lc_dir: Path | None) -> tuple[Path | None, Path | None]:
    fiu_file: Path | None = None
    if fiu_path is not None:
        if not fiu_path.exists():
            raise FileNotFoundError(f"Fiu source not found: {fiu_path}")
        if fiu_path.is_dir():
            fiu_file = fiu_path / "Source.lua"
            if not fiu_file.is_file():
                fiu_file = fiu_path / "Source.luau"
        else:
            fiu_file = fiu_path
        if not fiu_file.is_file():
            raise FileNotFoundError(f"Fiu source file not found: {fiu_file}")
    if lc_dir is not None and not lc_dir.is_dir():
        raise FileNotFoundError(f"LuauCeption directory not found: {lc_dir}")
    return fiu_file, lc_dir


@contextmanager
def _staged_workspace(fiu_file: Path | None, lc_dir: Path | None) -> Iterator[tuple[Path, Path]]:
    with tempfile.TemporaryDirectory(prefix="ouro-bench-") as tmp:
        stage = Path(tmp)
        aliases: dict[str, str] = {"ouro": str(ROOT)}
        if fiu_file is not None:
            aliases["fiu"] = str(fiu_file)
        if lc_dir is not None:
            aliases["lc"] = str(lc_dir)

        (stage / ".luaurc").write_text(json.dumps({"aliases": aliases}, indent=2), encoding="utf-8")
        staged_run = stage / "run.luau"
        shutil.copy2(RUN_LUAU, staged_run)
        yield stage, staged_run


def _check_competitors(payload: dict[str, Any], expect_fiu: bool, expect_lc: bool) -> None:
    comps = payload.get("competitors") or {}
    if expect_fiu and not comps.get("fiu"):
        raise RuntimeError("Fiu was requested (--fiu) but failed to load in Luau")
    if expect_lc and not comps.get("luauception"):
        raise RuntimeError("LuauCeption was requested (--luauception) but failed to load in Luau")


def verify_suite(fiu_path: Path | None, lc_dir: Path | None) -> None:
    fiu_file, lc_resolved = _resolve_inputs(fiu_path, lc_dir)
    with _staged_workspace(fiu_file, lc_resolved) as (stage, staged_run):
        for mode_key, flags in (
            ("codegen", ["--codegen", "-O2"]),
            ("interp", ["-O2"]),
        ):
            print(f"[verify] checking {mode_key} ({' '.join(flags)})...")
            raw = _run_luau(staged_run, flags, ["--verify", "--json"], cwd=stage)
            payload = json.loads(raw.strip().splitlines()[-1])
            if payload.get("status") != "ok":
                raise RuntimeError(f"verification failed for {mode_key}: {payload}")
            _check_competitors(payload, fiu_file is not None, lc_resolved is not None)
            print(f"[verify] {mode_key} ok: {json.dumps(payload['checked'])}")


def run_suite(
    fiu_path: Path | None,
    lc_dir: Path | None,
    fiu_ref: str = "fa1983d",
    lc_version: str = "0.654",
) -> dict[str, Any]:
    fiu_file, lc_resolved = _resolve_inputs(fiu_path, lc_dir)

    with _staged_workspace(fiu_file, lc_resolved) as (stage, staged_run):
        modes: dict[str, Any] = {}
        for mode_key, flags in (
            ("codegen", ["--codegen", "-O2"]),
            ("interp", ["-O2"]),
        ):
            print(f"[bench] measuring {mode_key} ({' '.join(flags)})...")
            cold = _measure_cold_requires(stage, flags, has_fiu=fiu_file is not None, has_lc=lc_resolved is not None)
            raw = _run_luau(staged_run, flags, ["--json"], cwd=stage)
            suite_data = json.loads(raw.strip().splitlines()[-1])
            _check_competitors(suite_data, fiu_file is not None, lc_resolved is not None)
            suite_data["cold_require"] = cold
            modes[mode_key] = suite_data

    return {
        "meta": {
            "generated_at": datetime.now(timezone.utc).isoformat(),
            "luau_version": _luau_version(),
            "ouro_version": "0.1.0",
            "fiu_label": "fast",
            "fiu_ref": fiu_ref,
            "luauception_version": lc_version,
            "cpu": _read_cpu_model(),
            "os": f"{platform.system()} {platform.machine()}",
            "instruction_limit_guarded": 50_000_000,
            "footprint": _footprint(fiu_file, lc_resolved),
        },
        "modes": modes,
    }


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--fiu", type=Path, help="Path to Fiu Source.lua/luau (or directory containing it)")
    ap.add_argument("--luauception", type=Path, help="Path to extracted LuauCeption directory (Full.luau, Compiler.luau, VM.luau)")
    ap.add_argument("--fiu-ref", default="fa1983d", help="Pinned Fiu commit/ref label for metadata")
    ap.add_argument("--lc-version", default="0.654", help="Pinned LuauCeption version for metadata")
    ap.add_argument("--verify", action="store_true", help="Verify parity and correctness without running timings")
    ap.add_argument("--out", type=Path, default=DEFAULT_OUT, help="Output JSON results path")
    ap.add_argument("--out-dir", type=Path, default=BENCH_DIR, help="Output directory for generated SVG charts")
    ap.add_argument("--no-chart", action="store_true", help="Skip regenerating SVG charts")
    args = ap.parse_args()

    if args.verify:
        verify_suite(args.fiu, args.luauception)
        return

    results = run_suite(args.fiu, args.luauception, fiu_ref=args.fiu_ref, lc_version=args.lc_version)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(results, indent=2) + "\n", encoding="utf-8")
    print(f"wrote {args.out}")

    if not args.no_chart:
        chart.render_all(results_path=args.out, out_dir=args.out_dir)


if __name__ == "__main__":
    main()
