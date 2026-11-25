#!/usr/bin/env python3
"""Pinned C++ oracle versus pure Luau. MIT. Every mismatch fails the process."""
import hashlib
import argparse
import difflib
import json
import math
import pathlib
import re
import subprocess
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
REVISION = json.loads((HERE.parent / 'UPSTREAM.json').read_text())['commit']
PTR_RE = re.compile(r'\b(table|function|userdata|thread): 0x[0-9a-fA-F]+')
CHUNK_PREFIX_RE = re.compile(r'^(?:\[string "[^"]*"\]|chunk)(?=:)')
BARE_LINE_PREFIX_RE = re.compile(r'^:(?=\d+:)')


def sanitize_vm(value):
    if isinstance(value, str):
        return PTR_RE.sub(r'\1: <addr>', value)
    if isinstance(value, list):
        return [sanitize_vm(v) for v in value]
    if isinstance(value, dict):
        return {k: sanitize_vm(v) for k, v in value.items()}
    return value


def normalize_vm_error(err):
    err = PTR_RE.sub(r'\1: <addr>', err)
    err = CHUNK_PREFIX_RE.sub('<chunk>', err)
    return BARE_LINE_PREFIX_RE.sub('<chunk>:', err)

def source_bytes(case):
    return bytes.fromhex(case['sourceBytesHex']) if 'sourceBytesHex' in case else case['source'].encode('utf-8')

def luau_bytes(value):
    return '"' + ''.join('\\%03d' % byte for byte in value) + '"'

def luau_string(value):
    return '"' + ''.join('\\%03d' % byte for byte in value.encode('utf-8')) + '"'

def normalize(value):
    # Null optional fields and omitted optional fields carry the same AST meaning.
    if isinstance(value, dict):
        return {k: normalize(v) for k,v in value.items() if v is not None}
    if isinstance(value, list):
        return [normalize(v) for v in value]
    if isinstance(value, float) and math.isnan(value):
        return '<NaN>'
    return value

def binding_supplement(result):
    records=result['bindings']
    keys={b['id']:(b['name'],b['start'],b['finish']) for b in records}
    bindings=[]
    for b in records:
        item={k:v for k,v in b.items() if k not in ('id','shadow')}
        item['shadow']=keys.get(b.get('shadow',0))
        bindings.append(item)
    bindings.sort(key=lambda b:(b['start'],b['finish'],b['name']))
    refs=[{**r,'binding':keys[r['binding']]} for r in result['references']]
    refs.sort(key=lambda r:(r['start'],r['finish']))
    return {'bindings':bindings,'references':refs,'errorNodes':sorted(result['errorNodes'],key=lambda n:(n['start'],n['finish'],n['kind'],n['messageIndex']))}

def difference(expected, actual):
    return '\n'.join(difflib.unified_diff(json.dumps(normalize(expected),sort_keys=True,indent=2,ensure_ascii=True).splitlines(),json.dumps(normalize(actual),sort_keys=True,indent=2,ensure_ascii=True).splitlines(),fromfile='official',tofile='pure-luau',n=2))

def run_oracle(command, case, failures):
    reference=subprocess.run(command,input=source_bytes(case),capture_output=True,timeout=10)
    if reference.returncode:
        failures.append({'name':case['name'],'origin':case['origin'],'diff':'Oracle crashed, exit '+str(reference.returncode)+': '+reference.stderr.decode('utf-8',errors='replace')})
        print('ORACLE FAIL',case['name'],reference.returncode)
        return None
    expected=json.loads(reference.stdout.decode('latin-1'))
    assert expected['revision']==REVISION, 'Oracle revision does not match UPSTREAM.json'
    return expected

DEFAULT_BUILD_DIR = pathlib.Path(tempfile.gettempdir()) / 'ouro-build'

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--oracle',default=str(DEFAULT_BUILD_DIR / 'parser-oracle'))
    ap.add_argument('--luau',default='luau')
    ap.add_argument('--filter',default='')
    ap.add_argument('--fixtures',type=pathlib.Path,help='Explicit fixture manifest')
    ap.add_argument('--entrypoints',action='store_true',help='Compare expression/type entrypoints')
    ap.add_argument('--upstream-fixtures',action='store_true',help='Use every extracted official raw-string fixture')
    ap.add_argument('--raw-only',action='store_true',help='Exclude quoted C++ string fixtures from the selected manifest')
    ap.add_argument('--limit',type=int)
    ap.add_argument('--lex',action='store_true',help='Compare token kinds and byte ranges instead of AST')
    ap.add_argument('--compile',action='store_true',help='Compare compiled bytecode across O0, O1, and O2')
    ap.add_argument('--vm',action='store_true',help='Compare pure-Luau VM execution against official Luau.VM')
    ap.add_argument('--report',type=pathlib.Path)
    args=ap.parse_args()
    if args.fixtures:
        manifest=args.fixtures
    elif args.entrypoints:
        manifest=HERE/'differential-entrypoints.json'
    elif args.upstream_fixtures:
        candidates=(HERE/'differential-upstream.json',DEFAULT_BUILD_DIR / 'differential-all-literals.json')
        manifest=next((p for p in candidates if p.is_file()),None)
        if manifest is None:
            raise SystemExit('Upstream fixtures are generated on demand; pass --fixtures or run python3 tools/check.py --upstream <luau-source>')
        if manifest.name=='differential-all-literals.json':
            args.raw_only=True
    else:
        manifest=HERE/'differential-fixtures.json'
    cases=json.loads(manifest.read_text())
    if args.raw_only:
        cases=[c for c in cases if '_quoted_' not in c['name']]
    if args.compile or args.vm:
        cases=[c for c in cases if c.get('mode','chunk')=='chunk' and not c.get('allowDeclarationSyntax',False) and not (args.vm and c.get('skipVm',False))]
    cases=[c for c in cases if args.filter in c['name']]
    if args.limit is not None:cases=cases[:args.limit]
    assert cases,'No fixtures discovered'
    # One process amortizes runtime startup; oracle remains isolated per profile/case.
    rows=['{name='+luau_string(c['name'])+',source='+luau_bytes(source_bytes(c))+',profile='+luau_string(c['profile'])+',mode='+luau_string(c.get('mode','chunk'))+',flags={'+','.join('['+luau_string(k)+']='+str(v).lower() for k,v in c.get('flags',{}).items())+'},declarations='+str(c.get('allowDeclarationSyntax',False)).lower()+'}' for c in cases]
    script='''local encode=require("../differential-json")
local cases={%s}
''' % ',\n'.join(rows)
    if args.lex:
        script+='''local Lexer=require("../../src/Lexer")
for _,case in cases do
 local lexer=Lexer.new(case.source,{profile=case.profile,lossless=true});local tokens={}
 repeat local kind=lexer:next();tokens[#tokens+1]={kind=kind,start=lexer.start,finish=lexer.finish} until kind==0
 -- Include comments skipped by the parser-facing scanner in source order.
 for _,comment in lexer.comments do
  local exists=false;for _,t in tokens do if t.kind==comment.kind and t.start==comment.start and t.finish==comment.finish then exists=true;break end end
  if not exists then tokens[#tokens+1]=comment end
 end
 table.sort(tokens,function(a,b) if a.start==b.start then return a.finish<b.finish end return a.start<b.start end)
 print(encode({name=case.name,tokens=tokens}))
end
'''
    elif args.compile:
        script+='''local Compiler=require("../../src/Compiler")
local Profiles=require("../../src/Profiles")
local function grammarFlags(flags)
 local out={}
 for k,v in flags do if Profiles.named.upstream[k]~=nil then out[k]=v end end
 return if next(out) then out else nil
end
local function compilerFlags(flags)
 local out={}
 for k,v in flags do if Compiler.CompilerFlags[k]~=nil then out[k]=v end end
 return if next(out) then out else nil
end
local function toHex(s)
 local out=table.create(#s)
 for i=1,#s do out[i]=string.format("%02x",string.byte(s,i)) end
 return table.concat(out)
end
for _,case in cases do
 local success,payload=pcall(function()
  local parseOpts={profile=grammarFlags(case.flags) or case.profile,allowDeclarationSyntax=if case.declarations then true else nil}
  local cflags=compilerFlags(case.flags)
  local bc0=Compiler.compileResult(case.source,{optimizationLevel=0,debugLevel=1,flags=cflags,parseOptions=parseOpts}).bytecode
  local bc1=Compiler.compileResult(case.source,{optimizationLevel=1,debugLevel=1,flags=cflags,parseOptions=parseOpts}).bytecode
  local bc2=Compiler.compileResult(case.source,{optimizationLevel=2,debugLevel=1,flags=cflags,parseOptions=parseOpts}).bytecode
  return {name=case.name,O0=toHex(bc0),O1=toHex(bc1),O2=toHex(bc2)}
 end)
 print(encode(if success then payload else {name=case.name,runnerError=tostring(payload)}))
end
'''
    elif args.vm:
        script+='''local Compiler=require("../../src/Compiler")
local VM=require("../../src/VM")
local Profiles=require("../../src/Profiles")
local function grammarFlags(flags)
 local out={}
 for k,v in flags do if Profiles.named.upstream[k]~=nil then out[k]=v end end
 return if next(out) then out else nil
end
local function compilerFlags(flags)
 local out={}
 for k,v in flags do if Compiler.CompilerFlags[k]~=nil then out[k]=v end end
 return out
end
for _,case in cases do
 local success,payload=pcall(function()
  local vmProfile=table.clone(Profiles.resolve(grammarFlags(case.flags) or case.profile))
  if case.flags.DebugLuauUserDefinedClasses==nil then
   vmProfile.DebugLuauUserDefinedClasses=false
  end
  local parseOpts={profile=vmProfile,allowDeclarationSyntax=if case.declarations then true else nil}
  local compileFlags=compilerFlags(case.flags)
  local row={name=case.name}
  for _,opt in {0,1,2} do
   local bc=Compiler.compileResult(case.source,{optimizationLevel=opt,debugLevel=1,flags=compileFlags,parseOptions=parseOpts}).bytecode
   local outLines={}
   local env=VM.createEnvironment({
    print=function(...)
     local n=select("#",...)
     local parts=table.create(n)
     for i=1,n do parts[i]=tostring(select(i,...)) end
     outLines[#outLines+1]=table.concat(parts,"\t")
    end,
   })
   local fn,loadErr=VM.loadBytecode(bc,{name="=chunk",env=env})
   local optKey="O"..tostring(opt)
   if not fn then
    row[optKey]={status="loadError",error=loadErr or "load error",output=outLines,results={}}
   else
    local packed=table.pack(pcall(fn))
    if not packed[1] then
     row[optKey]={status="runtimeError",error=tostring(packed[2]),output=outLines,results={}}
    else
     local results={}
     for i=2,packed.n do results[#results+1]=tostring(packed[i]) end
     row[optKey]={status="ok",error="",output=outLines,results=results}
    end
   end
  end
  return row
 end)
 print(encode(if success then payload else {name=case.name,runnerError=tostring(payload)}))
end
'''
    else:
        script+='''local Profiles=require("../../src/Profiles")
local Parser=require("../../src/Parser")
local UpstreamAstAdapter=require("../UpstreamAstAdapter")
local Schema=require("../../src/Schema")
local function supplement(result)
 local arena=result.arena;local bindings,refs,errors={},{},{};local seen,used={},{}
 local function bind(id)
  if id==nil or id==0 or used[id] then return end
  used[id]=true;local b=arena.bindings[id]
  bindings[#bindings+1]={id=id,name=arena.symbols[b.name],start=b.start,finish=b.finish,shadow=b.shadow,functionDepth=b.functionDepth,loopDepth=b.loopDepth,isConst=b.isConst or false}
  bind(b.shadow)
 end
 local function visit(id)
  if id==0 or seen[id] then return end;seen[id]=true
  local n=arena.nodes[id];local kind=arena:kindName(id)
  if kind=="AstExprLocal" then refs[#refs+1]={start=n.start,finish=n.finish,binding=n["local"],upvalue=n.upvalue or false} end
  if kind=="AstExprError" or kind=="AstStatError" or kind=="AstTypeError" then errors[#errors+1]={kind=kind,start=n.start,finish=n.finish,messageIndex=n.messageIndex} end
  for _,field in Schema[kind] or {} do
   if field[2]=="b" then bind(n[field[1]]) elseif field[2]=="B" then for i=1,arena:listCount(n[field[1]] or 0) do bind(arena:listAt(n[field[1]],i)) end end
  end
  for i=1,result:childCount(id) do visit(result:childAt(id,i)) end
 end
 visit(result.root)
 return bindings,refs,errors
end
local function grammarFlags(flags)
 local out={}
 for k,v in flags do if Profiles.named.upstream[k]~=nil then out[k]=v end end
 return if next(out) then out else nil
end
for _,case in cases do
 local success,payload=pcall(function()
 local parse=if case.mode=="expression" then Parser.parseExpression elseif case.mode=="type" then Parser.parseType else Parser.parse
 local result=parse(case.source,{profile=grammarFlags(case.flags) or case.profile,allowDeclarationSyntax=if case.declarations then true else nil,lossless=true})
 local bindings,refs,errors=supplement(result)
 return {name=case.name,status=result.status,root=UpstreamAstAdapter.toTables(result),diagnostics=result.diagnostics,comments=result.comments,hotcomments=result.hotcomments,bindings=bindings,references=refs,errorNodes=errors}
 end)
 print(encode(if success then payload else {name=case.name,runnerError=tostring(payload)}))
end
'''
    with tempfile.TemporaryDirectory(prefix='.differential-',dir=HERE) as temp:
        path=pathlib.Path(temp)/'runner.luau';path.write_text(script)
        process=subprocess.run([args.luau,str(path)],capture_output=True,encoding='latin-1',timeout=90)
    if process.returncode:
        raise RuntimeError('Luau runner failed:\n'+process.stdout+process.stderr)
    outputs=[json.loads(line) for line in process.stdout.splitlines() if line.startswith('{')]
    assert len(outputs)==len(cases),f'runner returned {len(outputs)} of {len(cases)} fixtures'
    failures=[];passed=0
    for case,actual in zip(cases,outputs):
        base_command=[args.oracle,'--profile',case['profile'],'--mode',case.get('mode','chunk')]
        for key,value in case.get('flags',{}).items():base_command+=['--flag',key+'='+str(value).lower()]
        if case.get('allowDeclarationSyntax'):base_command+=['--declarations']
        if actual.get('runnerError'):
            delta='Runtime crash: '+actual['runnerError']
        elif args.compile:
            expected_bc={}
            for opt in (0,1,2):
                exp=run_oracle(base_command+['--compile','--opt',str(opt),'--debug','1','-'],case,failures)
                if exp is None:break
                expected_bc[f'O{opt}']=exp['bytecodeHex']
            if len(expected_bc)<3:continue
            got_bc={f'O{opt}':actual.get(f'O{opt}') for opt in (0,1,2)}
            delta=difference(expected_bc,got_bc)
        elif args.vm:
            expected_vm={}
            got_vm={}
            for opt in (0,1,2):
                vm_cmd=base_command+(['--flag','DebugLuauUserDefinedClasses=false'] if 'DebugLuauUserDefinedClasses' not in case.get('flags',{}) else [])+['--vm','--opt',str(opt),'--debug','1','-']
                expected=run_oracle(vm_cmd,case,failures)
                if expected is None:break
                opt_key=f'O{opt}'
                expected_vm[opt_key]={
                    'status':expected['status'],
                    'error':normalize_vm_error(expected.get('error','')),
                    'output':sanitize_vm(expected['output']),
                    'results':sanitize_vm(expected['results']),
                }
                act=actual.get(opt_key,{})
                got_vm[opt_key]={
                    'status':act.get('status'),
                    'error':normalize_vm_error(act.get('error','')),
                    'output':sanitize_vm(act.get('output',[])),
                    'results':sanitize_vm(act.get('results',[])),
                }
            if len(expected_vm)<3:continue
            delta=difference(expected_vm,got_vm)
        else:
            expected=run_oracle(base_command+(['--lex'] if args.lex else [])+['-'],case,failures)
            if expected is None:continue
            if args.lex:
                delta=difference(expected['tokens'],actual['tokens'])
            else:
                wanted={'root':expected['root'],'diagnostics':expected['diagnostics'],'comments':expected['comments'],'hotcomments':expected['hotcomments']}
                got={k:actual.get(k) for k in wanted}
                # Diagnostic codes are implementation-specific; oracle compares message and range.
                for diag in got['diagnostics']:diag.pop('code',None)
                wanted.update(binding_supplement(expected))
                got.update(binding_supplement(actual))
                delta=difference(wanted,got)
        if delta:
            failures.append({'name':case['name'],'origin':case['origin'],'diff':delta})
            print('FAIL',case['name'])
            if len(failures)<=3:print(delta[:8000])
        else:passed+=1
    mode_name='lex' if args.lex else 'compile' if args.compile else 'vm' if args.vm else 'ast'
    report={'fixtureSha256':hashlib.sha256(manifest.read_bytes()).hexdigest(),'oracleBinarySha256':hashlib.sha256(pathlib.Path(args.oracle).read_bytes()).hexdigest(),'revision':REVISION,'supplements':[] if (args.lex or args.compile or args.vm) else ['bindings','references','errorNodes'],'mode':mode_name,'fixtures':len(cases),'passed':passed,'failed':len(failures),'failures':failures}
    if args.report:args.report.write_text(json.dumps(report,indent=2)+'\n')
    print(f'Differential {report["mode"]}: {passed}/{len(cases)} passed; {len(failures)} mismatches')
    if failures:raise SystemExit(1)

if __name__=='__main__':main()
