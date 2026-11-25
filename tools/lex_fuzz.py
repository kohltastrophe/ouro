#!/usr/bin/env python3
"""Seeded malformed-token differential corpus; exact byte inputs, no skipped mismatches. MIT."""
import argparse,json,pathlib,random,subprocess,sys,tempfile,time
ROOT=pathlib.Path(__file__).resolve().parents[1]

def main():
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--samples',type=int,default=6000);ap.add_argument('--seed',type=int,default=7422026);ap.add_argument('--oracle',default=str(pathlib.Path(tempfile.gettempdir())/'ouro-build'/'parser-oracle'));ap.add_argument('--luau',default='luau');ap.add_argument('--report',type=pathlib.Path);a=ap.parse_args();assert a.samples>0
    rng=random.Random(a.seed)
    fragments=[b'local',b'continue',b'and',b'a_1',b'=',b'==',b'...',b'..=',b'//=',b'::',b'->',b'(',b')',b'{',b'}',b'[',b']',b'1',b'.5',b'1e+',b'0x',b'0b101',b'1_000',b'0xffi',b'"a"',b'"\\z \n x"',b'"\\u{1f600}"',b'"\\x0g"',b"'",b'`hi {',b'`plain`',b'`{x} {',b'\\',b'-- comment\n',b'--[=[foo]=]',b'--[[ unfinished',b'[=[foo]=]',b'[==[',b'@native',b'@[',b'\r\n',b'\t',b' ',b'\x00',b'\xff',b'\xc3\xa9',b'\xe2\x80\x8b']
    cases=[]
    for i in range(a.samples):
        source=b''.join(rng.choice(fragments) for _ in range(rng.randrange(1,24)))
        cases.append({'name':f'lex_seed_{a.seed}_{i}','source':'','sourceBytesHex':source.hex(),'profile':'upstream','origin':f'lex_fuzz.py seed={a.seed} sample={i}'})
    with tempfile.TemporaryDirectory(prefix='ouro-lex-fuzz-') as temp:
        fixture=pathlib.Path(temp)/'fixtures.json';fixture.write_text(json.dumps(cases))
        command=[sys.executable,str(ROOT/'tests/differential.py'),'--fixtures',str(fixture),'--lex','--oracle',a.oracle,'--luau',a.luau]
        if a.report:command+=['--report',str(a.report)]
        result=subprocess.run(command,cwd=ROOT,timeout=300)
    raise SystemExit(result.returncode)
if __name__=='__main__':main()
