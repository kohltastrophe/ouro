#!/usr/bin/env python3
"""Deterministically generate upstream data, provenance, and conformance fixtures.

This is a data generator, not a C++ parser translator. MIT.
"""
import argparse
import hashlib
import json
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parents[1]


def snapshot(source):
    files = set()
    for folder in ('Ast', 'Common', 'Bytecode', 'Compiler'):
        files.update(p for p in (source / folder).rglob('*') if p.is_file())
    for name in ('CMakeLists.txt', 'Sources.cmake', 'LICENSE.txt', 'lua_LICENSE.txt',
                 'Analysis/src/AstJsonEncoder.cpp', 'tests/Parser.test.cpp', 'tests/Compiler.test.cpp'):
        files.add(source / name)
    if not files or not (source / 'Ast/src/Parser.cpp').is_file():
        raise ValueError('Not an official Luau source checkout')
    return {p.relative_to(source).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(files)}


def parse_enum(text, enum_name):
    match = re.search(rf'enum\s+{enum_name}\s*\{{(.*?)\}};', text, re.S)
    if not match:
        raise ValueError(f'Enum {enum_name} not found')
    body = re.sub(r'//[^\n]*|/\*.*?\*/', '', match[1], flags=re.S)
    values = {}
    current = -1
    for entry in body.split(','):
        entry = entry.strip()
        if not entry:
            continue
        m = re.fullmatch(r'(\w+)(?:\s*=\s*(.+))?', entry)
        if not m:
            raise ValueError(f'Unsupported enum entry in {enum_name}: {entry}')
        name, expr = m.groups()
        if expr:
            expr = expr.strip()
            if expr.isdecimal():
                current = int(expr)
            elif re.fullmatch(r'1\s*<<\s*(\d+)', expr):
                shift = int(re.fullmatch(r'1\s*<<\s*(\d+)', expr)[1])
                current = 1 << shift
            elif re.fullmatch(r'(\d+)\s*\+\s*(\d+)', expr):
                a, b = re.fullmatch(r'(\d+)\s*\+\s*(\d+)', expr).groups()
                current = int(a) + int(b)
            elif expr in values:
                current = values[expr]
            else:
                raise ValueError(f'Unsupported enum expression in {enum_name}: {entry}')
        else:
            current += 1
        values[name] = current
    return values


def parse_switch_cases(text, func_name):
    match = re.search(rf'inline\s+(?:int|bool)\s+{func_name}\s*\(LuauOpcode\s+\w+\)\s*\{{(.*?)\n\}}', text, re.S)
    if not match:
        raise ValueError(f'Function {func_name} not found')
    body = re.sub(r'//[^\n]*|/\*.*?\*/', '', match[1], flags=re.S)
    return re.findall(r'case\s+(LOP_\w+)\s*:', body)


def compiler_flags(source):
    bool_flags = {}
    int_flags = {}
    for folder in ('Compiler/src', 'Bytecode/src'):
        for path in sorted((source / folder).glob('*.cpp')):
            if path.name in ('BytecodeGraph.cpp', 'Sccp.cpp'):
                continue
            text = path.read_text()
            for name, default in re.findall(r'^LUAU_(?:DYNAMIC_)?FASTFLAGVARIABLE\((\w+)(?:,\s*(true|false))?\)', text, re.M):
                bool_flags[name] = default == 'true'
            for name, default in re.findall(r'^LUAU_(?:DYNAMIC_)?FASTINTVARIABLE\((\w+),\s*(-?\d+)\)', text, re.M):
                int_flags[name] = int(default)
    if not bool_flags or not int_flags:
        raise ValueError('No compiler flags discovered')
    return bool_flags, int_flags


def bytecode_defs(source, header):
    bc_text = (source / 'Common/include/Luau/Bytecode.h').read_text()
    util_text = (source / 'Common/include/Luau/BytecodeUtils.h').read_text()
    opcodes = parse_enum(bc_text, 'LuauOpcode')
    tags = parse_enum(bc_text, 'LuauBytecodeTag')
    types = parse_enum(bc_text, 'LuauBytecodeType')
    builtins = parse_enum(bc_text, 'LuauBuiltinFunction')
    captures = parse_enum(bc_text, 'LuauCaptureType')
    proto_flags = parse_enum(bc_text, 'LuauProtoFlag')
    feedback_types = parse_enum(bc_text, 'LuauFeedbackType')
    two_word_ops = set(parse_switch_cases(util_text, 'getOpLength'))
    jump_d_ops = set(parse_switch_cases(util_text, 'isJumpD'))
    fastcall_ops = set(parse_switch_cases(util_text, 'isFastCall'))
    skip_c_ops = set(parse_switch_cases(util_text, 'isSkipC'))
    c_bools, c_ints = compiler_flags(source)

    lines = [header.rstrip(), 'local BytecodeDefs = {}']
    lines.append('BytecodeDefs.Opcodes = table.freeze({')
    for name, val in opcodes.items():
        lines.append(f'\t{name} = {val},')
    lines.append('})')

    lines.append('BytecodeDefs.opcodeNames = table.freeze({')
    for name, val in opcodes.items():
        if name != 'LOP__COUNT':
            lines.append(f'\t[{val}] = "{name[4:]}",')
    lines.append('} :: { [number]: string })')

    lines.append('BytecodeDefs.opLengths = table.freeze({')
    for name, val in opcodes.items():
        if name != 'LOP__COUNT':
            length = 2 if name in two_word_ops else 1
            lines.append(f'\t[{val}] = {length},')
    lines.append('} :: { [number]: number })')

    for table_name, op_set in [
        ('isJumpD', jump_d_ops),
        ('isFastCall', fastcall_ops),
        ('isSkipC', skip_c_ops),
    ]:
        lines.append(f'BytecodeDefs.{table_name} = table.freeze({{')
        for name, val in opcodes.items():
            if name != 'LOP__COUNT' and name in op_set:
                lines.append(f'\t[{val}] = true,')
        lines.append('} :: { [number]: boolean })')

    for section_name, mapping in [
        ('Tags', tags),
        ('Types', types),
        ('Builtins', builtins),
        ('Captures', captures),
        ('ProtoFlags', proto_flags),
        ('FeedbackTypes', feedback_types),
    ]:
        lines.append(f'BytecodeDefs.{section_name} = table.freeze({{')
        for name, val in mapping.items():
            lines.append(f'\t{name} = {val},')
        lines.append('})')

    lines.append('BytecodeDefs.builtinNames = table.freeze({')
    for name, val in builtins.items():
        lines.append(f'\t[{val}] = "{name}",')
    lines.append('} :: { [number]: string })')

    lines.append('BytecodeDefs.CompilerFlags = table.freeze({')
    for name, val in c_bools.items():
        lines.append(f'\t{name} = {str(val).lower()},')
    for name, val in c_ints.items():
        lines.append(f'\t{name} = {val},')
    lines.append('})')

    lines.append('return table.freeze(BytecodeDefs)\n')
    return '\n'.join(lines)


def grammar_flags(source):
    text = (source / 'Ast/src/Parser.cpp').read_text()
    declarations = re.findall(r'^LUAU_(?:DYNAMIC_)?FASTFLAGVARIABLE\((\w+)(?:,\s*(true|false))?\)', text, re.M)
    if not declarations:
        raise ValueError('No parser flag declarations discovered')
    return {name: default == 'true' for name, default in declarations}


def tokens(source):
    text = (source / 'Ast/include/Luau/Lexer.h').read_text()
    match = re.search(r'enum Type\s*\{(.*?)\};', text, re.S)
    if not match:
        raise ValueError('Lexeme::Type not found')
    body = re.sub(r'//[^\n]*|/\*.*?\*/', '', match[1], flags=re.S)
    values = {}; current = -1
    for entry in body.split(','):
        entry = entry.strip()
        if not entry:
            continue
        declaration = re.fullmatch(r'(\w+)(?:\s*=\s*(\w+))?', entry)
        if not declaration:
            raise ValueError('Unsupported enum expression: ' + entry)
        name, expression = declaration.groups()
        if expression:
            current = int(expression) if expression.isdecimal() else values[expression]
        else:
            current += 1
        if name in values:
            raise ValueError('Duplicate token ' + name)
        values[name] = current
    if values.get('Eof') != 0 or values.get('Char_END') != 256 or 'Reserved_END' not in values:
        raise ValueError('Unexpected token layout')
    if max(values.values()) >= 4000:
        raise ValueError('Upstream tokens collide with lossless tape tokens')
    return values


def generated(source, version, commit):
    if not re.fullmatch(r'[0-9a-f]{40}', commit) or not re.fullmatch(r'\d+\.\d+', version):
        raise ValueError('Expected an official numeric release and full commit SHA')
    flags = grammar_flags(source)
    header = '--!strict\n-- Generated by tools/generate.py from official Luau; MIT LICENSE.md.\n'
    outputs = {}
    rows = [f'\t{name} = {str(value).lower()},' for name, value in flags.items()]
    outputs['src/Grammar.luau'] = (
        header
        + 'return table.freeze({\n\tversion = "'
        + version
        + '",\n\trevision = "'
        + commit
        + '",\n\tdefaults = table.freeze({\n'
        + '\n'.join('\t' + row for row in rows)
        + '\n\t}),\n})\n'
    )
    values = tokens(source)
    values.update(Whitespace=4000, Unparsed=4001)
    lines = [header.rstrip(), 'local Token = {']
    lines += [f'\t{name} = {value},' for name, value in values.items()]
    lines += [
        '}',
        'local names: { [number]: string } = {}',
        'for name, value in (Token :: any) :: { [string]: any } do',
        '\tif type(value) == "number" and name ~= "Char_END" and name ~= "Reserved_BEGIN" and name ~= "Reserved_END" then',
        '\t\tnames[value] = name',
        '\tend',
        'end',
        'Token.names = table.freeze(names)',
    ]
    outputs['src/Token.luau'] = '\n'.join(lines) + '\nreturn table.freeze(Token)\n'
    text = (source / 'Ast/src/Confusables.cpp').read_text()
    array = re.search(r'kConfusables\[\]\s*=\s*\{(.*?)\n\};', text, re.S)
    if not array:
        raise ValueError('Confusable data layout changed')
    entries = []
    for line in array[1].splitlines():
        line = line.strip()
        if not line or line.startswith('//'):
            continue
        entry = re.match(r'\{(\d+),\s*("(?:\\.|[^"\\])*")\},?\s*(?://.*)?$', line)
        if not entry:
            raise ValueError('Unsupported confusable entry: ' + line)
        # Current upstream strings are ASCII C++ literals with JSON-compatible escapes.
        value = json.loads(entry[2])
        if not value or not value.isascii():
            raise ValueError('Non-ASCII or empty confusable replacement requires generator support')
        if any(bad in value for bad in ('\t', '\n', '|', '[[', ']]')):
            raise ValueError('Confusable replacement collides with packed table delimiters: ' + repr(value))
        entries.append(f'{entry[1]}|{value}')
    if len(entries) < 100:
        raise ValueError('Unexpected confusable discovery count')
    packed_lines = []
    current = ''
    for item in entries:
        candidate = f'{current}\t{item}' if current else item
        if len(candidate) > 115 and current:
            packed_lines.append(current)
            current = item
        else:
            current = candidate
    if current:
        packed_lines.append(current)
    outputs['src/Confusables.luau'] = (
        header
        + 'local DATA = [[\n'
        + '\n'.join(packed_lines)
        + '\n]]\n'
        + 'local map: { [number]: string }? = nil\n'
        + 'local function getMap(): { [number]: string }\n'
        + '\tif not map then\n'
        + '\t\tlocal t: { [number]: string } = {}\n'
        + '\t\tfor code, rep in string.gmatch(DATA, "(%d+)|([^\\t\\n]+)") do\n'
        + '\t\t\tlocal n = tonumber(code)\n'
        + '\t\t\tif n ~= nil and rep ~= nil then\n'
        + '\t\t\t\tt[n] = rep\n'
        + '\t\t\tend\n'
        + '\t\tend\n'
        + '\t\tmap = table.freeze(t)\n'
        + '\tend\n'
        + '\treturn map :: { [number]: string }\n'
        + 'end\n'
        + 'return table.freeze(setmetatable({}, {\n'
        + '\t__index = function(_self: any, code: number): string?\n'
        + '\t\treturn getMap()[code]\n'
        + '\tend,\n'
        + '}) :: any) :: { [number]: string }\n'
    )
    outputs['src/BytecodeDefs.luau'] = bytecode_defs(source, header)
    manifest = dict(repository='https://github.com/luau-lang/luau', version=version,
                    commit=commit, license='MIT', files=snapshot(source))
    outputs['UPSTREAM.json'] = json.dumps(manifest, indent=2) + '\n'
    return outputs


def verify(source, root=ROOT):
    manifest = json.loads((root / 'UPSTREAM.json').read_text())
    actual = snapshot(source)
    if manifest['files'] != actual:
        changed = sorted(name for name in set(actual) | set(manifest['files'])
                         if actual.get(name) != manifest['files'].get(name))
        raise ValueError('Pinned-source checksum mismatch: ' + ', '.join(changed))
    return manifest


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--source', type=pathlib.Path, required=True)
    ap.add_argument('--version')
    ap.add_argument('--commit')
    ap.add_argument('--output', type=pathlib.Path, default=ROOT)
    ap.add_argument('--check', action='store_true')
    ap.add_argument('--verify-only', action='store_true')
    args = ap.parse_args()
    pin = json.loads((ROOT / 'UPSTREAM.json').read_text())
    if args.check or args.verify_only or not (args.version and args.commit):
        verify(args.source)
    if args.verify_only:
        print('Pinned source checksums verified')
        return
    outputs = generated(args.source, args.version or pin['version'], args.commit or pin['commit'])
    drift = []
    for name, value in outputs.items():
        path = args.output / name
        if args.check:
            if not path.is_file() or path.read_text() != value:
                drift.append(name)
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(value)
    if drift:
        raise SystemExit('Generated data drift: ' + ', '.join(drift))
    print(f'{len(outputs)} generated files ' + ('verified' if args.check else 'written'))


if __name__ == '__main__':
    main()
