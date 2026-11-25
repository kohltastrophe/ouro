#!/usr/bin/env python3
"""Validate extracted fixture bytes against actual C++ literal compilation. MIT."""
import argparse,json,pathlib,re,subprocess,tempfile
PATTERN=re.compile(r'(?:parse|tryParse|parseEx)\(\s*(R"\(.*?\)"|"(?:\\.|[^"\\])*")',re.S)

def main():
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--source',type=pathlib.Path,required=True);ap.add_argument('--fixtures',type=pathlib.Path,required=True);ap.add_argument('--cxx',default='c++');a=ap.parse_args()
    text=(a.source/'tests/Parser.test.cpp').read_text();literals={}
    for match in PATTERN.finditer(text):
        line=text.count('\n',0,match.start())+1
        kind='quoted_' if match.group(1).startswith('"') else ''
        literals[f'upstream_Parser_{kind}line_{line}']=match.group(1)
    fixtures=json.loads(a.fixtures.read_text());assert len(fixtures)>100
    source=['#include <iostream>','int main(){const char* digits="0123456789abcdef";']
    for i,fixture in enumerate(fixtures):
        literal=literals[fixture['name']]
        source.append('{const char value[]='+literal+';for(unsigned i=0;i<sizeof(value)-1;++i){unsigned byte=(unsigned char)value[i];std::cout<<digits[byte>>4]<<digits[byte&15];}std::cout<<"\\n";}')
    source.append('}')
    with tempfile.TemporaryDirectory(prefix='ouro-fixture-bytes-') as temp:
        path=pathlib.Path(temp);cpp=path/'literal.cpp';cpp.write_text('\n'.join(source));binary=path/'literal'
        build=subprocess.run([a.cxx,'-std=c++17',str(cpp),'-o',str(binary)],capture_output=True,text=True,timeout=120)
        if build.returncode:raise RuntimeError(build.stderr)
        run=subprocess.run([str(binary)],capture_output=True,text=True,check=True,timeout=60)
    actual=run.stdout.splitlines();assert len(actual)==len(fixtures)
    failures=[]
    for fixture,hexadecimal in zip(fixtures,actual):
        expected=fixture.get('sourceBytesHex') or fixture['source'].encode('utf-8').hex()
        if hexadecimal!=expected:failures.append(fixture['name'])
    assert not failures,'C++ literal byte mismatches: '+','.join(failures)
    print(f'Fixture bytes: {len(fixtures)}/{len(fixtures)} match compiled C++ literals')
if __name__=='__main__':main()
