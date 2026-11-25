#!/usr/bin/env python3
"""Stage and package or publish Ouro for pesde's roblox and luau targets."""

from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import tomllib

TARGET_SECTION_RE = re.compile(r"(?ms)^\[target\]\r?\n.*?(?=^\[|\Z)")


def run_pesde(cmd: list[str], cwd: Path) -> tuple[int, str]:
    """Run a pesde CLI command in cwd, printing combined output."""
    proc = subprocess.run(cmd, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if proc.stdout:
        print(proc.stdout, end="" if proc.stdout.endswith("\n") else "\n")
    return proc.returncode, proc.stdout or ""


def process_target(repo_root: Path, raw_manifest: str, name: str, version: str, target: str, publish: bool) -> None:
    """Stage a single pesde target and dry-run package or publish it."""
    if target == "luau":
        manifest, count = TARGET_SECTION_RE.subn(
            '[target]\nenvironment = "luau"\nlib = "src/init.luau"\n\n', raw_manifest, count=1
        )
        if count != 1:
            raise RuntimeError("could not locate [target] section in pesde.toml")
    else:
        manifest = raw_manifest

    with tempfile.TemporaryDirectory(prefix=f"ouro-pesde-{target}-") as tmp:
        stage = Path(tmp)
        shutil.copytree(repo_root / "src", stage / "src")
        shutil.copy2(repo_root / "README.md", stage / "README.md")
        shutil.copy2(repo_root / "LICENSE.md", stage / "LICENSE.md")
        shutil.copy2(repo_root / "UPSTREAM.json", stage / "UPSTREAM.json")
        if (repo_root / "rokit.toml").is_file():
            # Rokit shims resolve rokit.toml from cwd when staging outside the repo.
            shutil.copy2(repo_root / "rokit.toml", stage / "rokit.toml")
        (stage / "pesde.toml").write_text(manifest, encoding="utf-8")

        if target == "roblox":
            rc, _ = run_pesde(["pesde", "install"], stage)
            if rc != 0:
                raise RuntimeError(f"pesde install failed for {target} (exit {rc})")

        cmd = ["pesde", "publish", "--yes"] + ([] if publish else ["--dry-run"])
        rc, out = run_pesde(cmd, stage)

        if not publish:
            archive = stage / "package.tar.gz"
            size = archive.stat().st_size if archive.is_file() else 0
            if rc != 0 or "occurred publishing" in out or size <= 0:
                raise RuntimeError(f"pesde dry-run failed for {target}")
            print(f"pesde package ({target}): {size} bytes")
            return

        if rc == 0 and "occurred publishing" not in out and f"published {name}@{version} {target}" in out:
            return
        if "package version already exists" in out:
            print(f"::notice::{name}@{version} ({target}) was already on pesde")
            return
        print(f"::error::pesde did not accept {name}@{version} ({target})")
        raise RuntimeError(f"pesde publish failed for {target}")


def main() -> int:
    """Validate CLI arguments and process both roblox and luau pesde targets."""
    if sys.argv[1:] not in ([], ["--publish"]):
        raise RuntimeError("usage: publish_pesde.py [--publish]")

    publish = sys.argv[1:] == ["--publish"]
    repo_root = Path(__file__).resolve().parents[2]
    raw_manifest = (repo_root / "pesde.toml").read_text(encoding="utf-8")
    manifest = tomllib.loads(raw_manifest)
    name, version = manifest["name"], manifest["version"]

    for target in ("roblox", "luau"):
        process_target(repo_root, raw_manifest, name, version, target, publish)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"error: {exc}", file=sys.stderr)
        raise SystemExit(1)
