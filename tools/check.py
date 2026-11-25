#!/usr/bin/env python3
"""Run every portable test suite and all pinned differential fixtures. MIT."""
import argparse,pathlib,subprocess,sys,tempfile,time
ROOT=pathlib.Path(__file__).resolve().parents[1]
DEFAULT_BUILD_DIR=pathlib.Path(tempfile.gettempdir())/'ouro-build'
DEFAULT_UPSTREAM_DIR=pathlib.Path(tempfile.gettempdir())/'luau-src-0.748'

def run(command):
    print('+ '+' '.join(map(str,command)),flush=True)
    result=subprocess.run(command,cwd=ROOT,timeout=600)
    if result.returncode:raise SystemExit(result.returncode)

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--luau',default='luau');ap.add_argument('--oracle',type=pathlib.Path,default=DEFAULT_BUILD_DIR/'parser-oracle')
    ap.add_argument('--upstream',type=pathlib.Path,help='Build the checksum-guarded oracle using this pinned source checkout')
    ap.add_argument('--build-dir',type=pathlib.Path,default=DEFAULT_BUILD_DIR)
    ap.add_argument('--report-dir',type=pathlib.Path,help='Write differential JSON reports here')
    a=ap.parse_args();started=time.monotonic()
    all_literals=a.build_dir/'differential-all-literals.json'
    compiler_fixtures=a.build_dir/'compiler-fixtures.json'
    if a.upstream:
        a.build_dir.mkdir(parents=True,exist_ok=True)
        run([sys.executable,str(ROOT/'tools/generate.py'),'--source',str(a.upstream),'--check'])
        run(['cmake','-S',str(ROOT/'tools'),'-B',str(a.build_dir),'-G','Ninja','-DLUAU_SOURCE_DIR='+str(a.upstream),'-DCMAKE_BUILD_TYPE=Release'])
        run(['cmake','--build',str(a.build_dir),'--target','parser-oracle','-j','4'])
        a.oracle=a.build_dir/'parser-oracle'
        run([sys.executable,str(ROOT/'tools/extract_fixtures.py'),'--source',str(a.upstream),'--quoted','--output',str(all_literals)])
        run([sys.executable,str(ROOT/'tools/verify_fixture_bytes.py'),'--source',str(a.upstream),'--fixtures',str(all_literals)])
        run([sys.executable,str(ROOT/'tools/extract_compiler_fixtures.py'),'--source',str(a.upstream),'--output',str(compiler_fixtures)])
    assert a.oracle.is_file(),'Build the pinned oracle or pass --upstream/--oracle'
    assert all_literals.is_file(),f'Extracted fixtures missing ({all_literals}); pass --upstream or run tools/extract_fixtures.py'
    assert compiler_fixtures.is_file(),f'Extracted compiler fixtures missing ({compiler_fixtures}); pass --upstream or run tools/extract_compiler_fixtures.py'
    suites=sorted((ROOT/'tests').glob('*.spec.luau'))
    assert len(suites)>=5,f'Unexpected portable test discovery: {len(suites)}'
    run([a.luau,str(ROOT/'tests/run.luau')])
    modes=[
        ('targeted',[]),
        ('upstream',['--fixtures',str(all_literals),'--raw-only']),
        ('entrypoints',['--entrypoints']),
        ('all-literals',['--fixtures',str(all_literals)]),
        ('lexer',['--lex','--fixtures',str(all_literals),'--raw-only']),
        ('compiler-targeted',['--compile']),
        ('compiler-upstream',['--compile','--fixtures',str(all_literals),'--raw-only']),
        ('compiler-tests',['--compile','--fixtures',str(compiler_fixtures)]),
        ('vm-targeted',['--vm']),
    ]
    if a.report_dir:a.report_dir.mkdir(parents=True,exist_ok=True)
    for name,flags in modes:
        command=[sys.executable,str(ROOT/'tests/differential.py'),'--oracle',str(a.oracle),'--luau',a.luau,*flags]
        if a.report_dir:command+=['--report',str(a.report_dir/(name+'.json'))]
        run(command)
    fuzz=[sys.executable,str(ROOT/'tools/lex_fuzz.py'),'--oracle',str(a.oracle),'--luau',a.luau]
    if a.report_dir:fuzz+=['--report',str(a.report_dir/'lex-fuzz.json')]
    run(fuzz)
    vm_fuzz=[sys.executable,str(ROOT/'tools/vm_fuzz.py'),'--oracle',str(a.oracle),'--luau',a.luau]
    if a.report_dir:vm_fuzz+=['--report',str(a.report_dir/'vm-fuzz.json')]
    run(vm_fuzz)
    conformance_source=a.upstream or (DEFAULT_UPSTREAM_DIR if DEFAULT_UPSTREAM_DIR.is_dir() else None)
    ran_conformance=False
    if conformance_source is not None:
        conformance=[sys.executable,str(ROOT/'tests/conformance.py'),'--source',str(conformance_source),'--luau',a.luau]
        if a.report_dir:conformance+=['--report',str(a.report_dir/'conformance.json')]
        run(conformance)
        ran_conformance=True
    else:
        print('Note: skipping upstream conformance suite (pass --upstream or populate /tmp/luau-src-0.748)',flush=True)
    conf_note='conformance, ' if ran_conformance else ''
    print(f'PASS: {len(suites)} portable suites, {len(modes)} differential modes, {conf_note}and seeded lex/vm fuzz in {time.monotonic()-started:.2f}s')

if __name__=='__main__':main()