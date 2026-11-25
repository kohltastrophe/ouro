#!/usr/bin/env python3
"""Prepare and test a release candidate without publishing or changing the pin. MIT."""
import argparse
import json
import pathlib
import shutil
import subprocess
import sys
import traceback

import fetch_upstream
import generate

ROOT = pathlib.Path(__file__).resolve().parents[1]


def evaluate(source, release, output, luau):
    baseline = json.loads((ROOT / 'UPSTREAM.json').read_text())
    hashes = generate.snapshot(source)
    changed = sorted(name for name in set(baseline['files']) | set(hashes)
                     if baseline['files'].get(name) != hashes.get(name))
    report = {'baseline': baseline['commit'], 'release': release, 'changedFiles': changed,
              'status': 'testing', 'conformancePassed': False,
              'limitation': 'Corpus conformance does not prove arbitrary language compatibility; handwritten Luau parser, compiler, or VM modules are maintained by hand.'}
    if release['commit'] == baseline['commit']:
        generate.verify(source)
        report.update(status='up-to-date', conformancePassed=None)
        return report
    candidate = output / 'candidate'
    shutil.copytree(ROOT, candidate, ignore=shutil.ignore_patterns(
        '.git', '.sert', 'benchmarks', 'build', 'dist', 'plexer', 'reports',
        'sert.local.toml', 'upstream', '__pycache__', '.differential-*'))
    if (ROOT / '.sert').is_dir():
        shutil.copytree(ROOT / '.sert', candidate / '.sert')
    try:
        if not (candidate / '.sert').is_dir():
            subprocess.run([sys.executable, str(candidate / 'tools/sert.py'), 'fetch'], check=True, timeout=120)
        for name, value in generate.generated(source, release['version'], release['commit']).items():
            path = candidate / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(value)
        command = [sys.executable, str(candidate / 'tools/check.py'), '--upstream', str(source),
                   '--luau', luau, '--build-dir', str(output / 'build'), '--report-dir', str(output / 'conformance')]
        with (output / 'conformance.log').open('w') as log:
            result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=1200)
        report['conformancePassed'] = result.returncode == 0
        data_only = {'Ast/src/Confusables.cpp', 'tests/Parser.test.cpp', 'tests/Compiler.test.cpp', 'LICENSE.txt', 'lua_LICENSE.txt'}
        needs_port = any(name not in data_only for name in changed)
        report['status'] = 'needs-port' if needs_port or result.returncode else 'candidate-passed'
    except Exception:
        report['status'] = 'needs-port'
        report['error'] = traceback.format_exc()
    return report


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--output', type=pathlib.Path, required=True)
    ap.add_argument('--luau', default='luau')
    ap.add_argument('--source', type=pathlib.Path)
    ap.add_argument('--release', type=pathlib.Path)
    args = ap.parse_args()
    if bool(args.source) != bool(args.release):
        ap.error('--source and --release must be supplied together')
    output = args.output.resolve()
    if output.exists():
        ap.error('Output must be a new directory')
    if output.is_relative_to(ROOT):
        ap.error('Output must be outside this repository')
    output.mkdir(parents=True)
    try:
        release = json.loads(args.release.read_text()) if args.release else fetch_upstream.latest()
        source = args.source.resolve() if args.source else output / 'upstream'
        if not args.source:
            fetch_upstream.fetch(release['commit'], source)
        report = evaluate(source, release, output, args.luau)
    except Exception:
        report = {'status': 'failed', 'error': traceback.format_exc()}
    (output / 'release-report.json').write_text(json.dumps(report, indent=2) + '\n')
    summary = '# Official Luau release check\n\nStatus: **' + report['status'] + '**\n\n'
    if 'release' in report:
        summary += 'Release: ' + report['release']['version'] + '\n\n'
    summary += 'Candidate artifacts require review before adoption. No repository changes are published.\n'
    (output / 'SUMMARY.md').write_text(summary)
    print(summary)
    if report['status'] in ('needs-port', 'failed'):
        raise SystemExit(1)


if __name__ == '__main__':
    main()
