#!/usr/bin/env python3
"""Extract raw-string parser fixtures from the pinned official tests. MIT."""
import argparse,json,pathlib,re

def cpp_bytes(value):
    output=bytearray();i=0
    simple={'a':7,'b':8,'f':12,'n':10,'r':13,'t':9,'v':11,'\\':92,'"':34,"'":39,'?':63}
    while i<len(value):
        if value[i]!='\\':output.extend(value[i].encode('utf-8'));i+=1;continue
        i+=1;escape=value[i];i+=1
        if escape in simple:output.append(simple[escape])
        elif escape=='\n':pass
        elif escape in '01234567':
            digits=escape
            while i<len(value) and len(digits)<3 and value[i] in '01234567':digits+=value[i];i+=1
            output.append(int(digits,8)&255)
        elif escape=='x':
            start=i
            while i<len(value) and value[i] in '0123456789abcdefABCDEF':i+=1
            assert i>start,'Empty C++ hex escape';output.append(int(value[start:i],16)&255)
        elif escape in ('u','U'):
            size=4 if escape=='u' else 8
            output.extend(chr(int(value[i:i+size],16)).encode('utf-8'));i+=size
        else:raise ValueError('Unsupported C++ escape: '+escape)
    return bytes(output)

def main():
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--source',type=pathlib.Path,required=True);ap.add_argument('--output',type=pathlib.Path,required=True);ap.add_argument('--version',default=json.loads((pathlib.Path(__file__).resolve().parents[1]/'UPSTREAM.json').read_text())['version']);ap.add_argument('--quoted',action='store_true',help='Also extract single ordinary C++ string literal arguments');a=ap.parse_args()
    text=(a.source/'tests/Parser.test.cpp').read_text();out=[]
    flags_source=(a.source/'Ast/src/Parser.cpp').read_text()
    grammar_flags=set(re.findall(r'^LUAU_(?:DYNAMIC_)?FASTFLAGVARIABLE\((\w+)',flags_source,re.M))
    assert grammar_flags,'No grammar flags discovered'
    def make_fixture(match, quoted=False):
        offset=match.start();start=text.rfind('TEST_CASE',0,offset);prefix=text[start:offset]
        flags={name:value=='true' for name,value in re.findall(r'(?:D?FFlag)::(\w+)\s*,\s*(true|false)',prefix) if name in grammar_flags}
        line=text.count('\n',0,offset)+1
        item={'name':f'upstream_Parser_{"quoted_" if quoted else ""}line_{line}'}
        if quoted:
            raw=cpp_bytes(match.group(2))
            item['source']=raw.decode('utf-8',errors='replace')
            item['sourceBytesHex']=raw.hex()
        else:
            item['source']=match.group(2)
        item.update({'profile':'upstream','flags':flags,'allowDeclarationSyntax':('opts.allowDeclarationSyntax = true' in prefix or match.group(1) in ('tryParse','parseEx')),'origin':f'Luau {a.version} tests/Parser.test.cpp:{line}'})
        return item
    # Exact raw strings only. C++ string concatenation/interpolation is deliberately excluded.
    for match in re.finditer(r'(parse|tryParse|parseEx)\(\s*R"\((.*?)\)"',text,re.S):
        out.append(make_fixture(match))
    if a.quoted:
        for match in re.finditer(r'(parse|tryParse|parseEx)\(\s*"((?:\\.|[^"\\])*)"',text,re.S):
            trailing=text[match.end():].lstrip()
            # A prefix of a concatenated or composed C++ expression is not the fixture input.
            if not trailing.startswith((')',',')):continue
            out.append(make_fixture(match,quoted=True))
        out.sort(key=lambda c:int(c['origin'].rsplit(':',1)[1]))
    assert len(out)>100,f'Unexpected fixture discovery: {len(out)}'
    a.output.write_text(json.dumps(out,indent=2)+'\n');print(f'Extracted {len(out)} official literal fixtures')
if __name__=='__main__':main()
