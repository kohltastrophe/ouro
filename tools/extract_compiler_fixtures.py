#!/usr/bin/env python3
"""Extract standalone compile fixtures from upstream tests/Compiler.test.cpp. MIT."""
import argparse
import json
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parents[1]

COMPILE_CALL_NAMES = {
    'compileFunction',
    'compileFunction0',
    'compileFunctionConstants',
    'compileFunction0Constants',
    'compileFunction0Coverage',
    'compileTypeTable',
    'compileWithRemarks',
    'Luau::compile',
    'Luau::compileOrThrow',
}

HELPER_DEFS_END_MARKER = 'TEST_SUITE_BEGIN("Compiler")'


def cpp_bytes(value: str) -> bytes:
    output = bytearray()
    i = 0
    simple = {'a': 7, 'b': 8, 'f': 12, 'n': 10, 'r': 13, 't': 9, 'v': 11, '\\': 92, '"': 34, "'": 39, '?': 63}
    while i < len(value):
        if value[i] != '\\':
            output.extend(value[i].encode('utf-8'))
            i += 1
            continue
        i += 1
        escape = value[i]
        i += 1
        if escape in simple:
            output.append(simple[escape])
        elif escape == '\n':
            pass
        elif escape in '01234567':
            digits = escape
            while i < len(value) and len(digits) < 3 and value[i] in '01234567':
                digits += value[i]
                i += 1
            output.append(int(digits, 8) & 255)
        elif escape == 'x':
            start = i
            while i < len(value) and value[i] in '0123456789abcdefABCDEF':
                i += 1
            assert i > start, 'Empty C++ hex escape'
            output.append(int(value[start:i], 16) & 255)
        elif escape in ('u', 'U'):
            size = 4 if escape == 'u' else 8
            output.extend(chr(int(value[i:i + size], 16)).encode('utf-8'))
            i += size
        else:
            raise ValueError('Unsupported C++ escape: ' + escape)
    return bytes(output)


def discover_supported_flags(source: pathlib.Path) -> set[str]:
    parser_cpp = (source / 'Ast/src/Parser.cpp').read_text()
    grammar_flags = set(re.findall(r'^LUAU_(?:DYNAMIC_)?FASTFLAGVARIABLE\((\w+)', parser_cpp, re.M))
    bc_defs = (ROOT / 'src/BytecodeDefs.luau').read_text()
    m = re.search(r'BytecodeDefs\.CompilerFlags\s*=\s*table\.freeze\(\{(.*?)\}\)', bc_defs, re.S)
    assert m, 'Could not locate BytecodeDefs.CompilerFlags'
    compiler_flags = set(re.findall(r'(\w+)\s*=\s*(?:true|false)\b', m.group(1)))
    return grammar_flags | compiler_flags


def tokenize_cpp(text: str):
    """Yield (kind, value, start_offset) scanning comments, raw strings, strings, and punctuation."""
    n = len(text)
    i = 0
    while i < n:
        c = text[i]
        if c == '/' and i + 1 < n:
            if text[i + 1] == '/':
                nl = text.find('\n', i + 2)
                i = n if nl == -1 else nl + 1
                continue
            if text[i + 1] == '*':
                end = text.find('*/', i + 2)
                i = n if end == -1 else end + 2
                continue
        if c == 'R' and i + 1 < n and text[i + 1] == '"':
            paren = text.find('(', i + 2)
            if paren != -1 and paren - (i + 2) <= 16:
                delim = text[i + 2:paren]
                if all(ch.isalnum() or ch == '_' for ch in delim):
                    close_seq = ')' + delim + '"'
                    end = text.find(close_seq, paren + 1)
                    if end != -1:
                        yield ('RAW_STR', text[paren + 1:end], i)
                        i = end + len(close_seq)
                        continue
        if c == '"':
            j = i + 1
            while j < n:
                if text[j] == '\\':
                    j += 2
                elif text[j] == '"':
                    break
                else:
                    j += 1
            yield ('STR', text[i + 1:j], i)
            i = j + 1
            continue
        if c == "'":
            j = i + 1
            while j < n:
                if text[j] == '\\':
                    j += 2
                elif text[j] == "'":
                    break
                else:
                    j += 1
            i = j + 1
            continue
        if c in '{}();,=<>[]*':
            yield (c, c, i)
            i += 1
            continue
        if c.isalpha() or c == '_':
            j = i + 1
            while j < n and (text[j].isalnum() or text[j] == '_' or text[j:j + 2] == '::'):
                if text[j:j + 2] == '::':
                    j += 2
                else:
                    j += 1
            yield ('ID', text[i:j], i)
            i = j
            continue
        i += 1


def extract_fixtures(source: pathlib.Path, version: str) -> list[dict]:
    supported_flags = discover_supported_flags(source)
    cpp_path = source / 'tests/Compiler.test.cpp'
    text = cpp_path.read_text()
    suite_start = text.find(HELPER_DEFS_END_MARKER)
    assert suite_start != -1, 'Could not find TEST_SUITE_BEGIN("Compiler")'

    tokens = list(tokenize_cpp(text[suite_start:]))
    tokens = [(k, v, off + suite_start) for (k, v, off) in tokens]

    flag_scopes: list[dict[str, bool]] = [{}]
    var_scopes: list[dict[str, tuple[bytes, int]]] = [{}]

    def current_flags() -> dict[str, bool]:
        merged: dict[str, bool] = {}
        for s in flag_scopes:
            merged.update(s)
        return merged

    def lookup_var(name: str):
        for s in reversed(var_scopes):
            if name in s:
                return s[name]
        return None

    fixtures = []
    seen = set()
    i = 0
    ntok = len(tokens)

    while i < ntok:
        kind, val, off = tokens[i]
        if kind == '{':
            flag_scopes.append({})
            var_scopes.append({})
            i += 1
            continue
        if kind == '}':
            if len(flag_scopes) > 1:
                flag_scopes.pop()
                var_scopes.pop()
            i += 1
            continue

        # Track ScopedFastFlag var{FFlag::Name, bool}; and ScopedFastFlag sffs[] = {{FFlag::Name, bool}, ...};
        if kind == 'ID' and val == 'ScopedFastFlag':
            j = i + 1
            while j < ntok and tokens[j][0] != ';':
                if (
                    j + 4 < ntok
                    and tokens[j][0] == '{'
                    and tokens[j + 1][0] == 'ID'
                    and tokens[j + 2][0] == ','
                    and tokens[j + 3][1] in ('true', 'false')
                ):
                    flag_ref = tokens[j + 1][1]
                    if flag_ref.startswith(('FFlag::', 'DFFlag::')):
                        fname = flag_ref.split('::', 1)[1]
                        if fname in supported_flags:
                            flag_scopes[-1][fname] = tokens[j + 3][1] == 'true'
                j += 1
            i = j + 1 if j < ntok else ntok
            continue

        # Track variable definitions: std::string source = "..." / R"(...)" or const char* source = ...
        if kind == 'ID' and val in ('source', 'code') and i + 2 < ntok and tokens[i + 1][0] == '=':
            rhs_kind, rhs_val, rhs_off = tokens[i + 2]
            # Make sure it's a declaration and not a concatenation like source + "..."
            prev_val = tokens[i - 1][1] if i > 0 else ''
            is_decl = prev_val in ('string', 'std::string') or (prev_val == '*' and i >= 2 and tokens[i - 2][1] == 'char')
            if is_decl and rhs_kind in ('RAW_STR', 'STR'):
                # Exclude concatenated expressions (rhs followed by + or ;)
                after = tokens[i + 3][0] if i + 3 < ntok else ''
                if after == ';':
                    raw_bytes = rhs_val.encode('utf-8') if rhs_kind == 'RAW_STR' else cpp_bytes(rhs_val)
                    var_scopes[-1][val] = (raw_bytes, rhs_off)

        # Match compile calls
        if kind == 'ID' and val in COMPILE_CALL_NAMES and i + 1 < ntok and tokens[i + 1][0] == '(':
            # Extract argument tokens inside (...)
            arg_idx = i + 2
            # For Luau::compileOrThrow(bcb, source, ...) skip first argument bcb
            if val == 'Luau::compileOrThrow':
                depth = 0
                while arg_idx < ntok:
                    ak = tokens[arg_idx][0]
                    if ak == '(':
                        depth += 1
                    elif ak == ')':
                        if depth == 0:
                            break
                        depth -= 1
                    elif ak == ',' and depth == 0:
                        arg_idx += 1
                        break
                    arg_idx += 1

            if arg_idx < ntok:
                ak, av, aoff = tokens[arg_idx]
                next_k = tokens[arg_idx + 1][0] if arg_idx + 1 < ntok else ''
                raw_bytes = None
                src_off = aoff

                if ak in ('RAW_STR', 'STR') and next_k in (',', ')'):
                    raw_bytes = av.encode('utf-8') if ak == 'RAW_STR' else cpp_bytes(av)
                elif ak == 'ID' and av in ('source', 'code') and next_k in (',', ')'):
                    found = lookup_var(av)
                    if found is not None:
                        raw_bytes, src_off = found
                elif ak == 'ID' and av == 'source.c_str' and arg_idx + 3 < ntok and tokens[arg_idx + 1][0] == '(' and tokens[arg_idx + 2][0] == ')':
                    found = lookup_var('source')
                    if found is not None:
                        raw_bytes, src_off = found

                if raw_bytes is not None:
                    flags = current_flags()
                    dedup_key = (raw_bytes, tuple(sorted(flags.items())))
                    if dedup_key not in seen:
                        seen.add(dedup_key)
                        line = text.count('\n', 0, src_off) + 1
                        item = {'name': f'upstream_Compiler_line_{line}'}
                        try:
                            item['source'] = raw_bytes.decode('utf-8')
                        except UnicodeDecodeError:
                            item['source'] = raw_bytes.decode('utf-8', errors='replace')
                            item['sourceBytesHex'] = raw_bytes.hex()
                        if ak == 'STR' or any(b < 0x20 and b not in (9, 10, 13) for b in raw_bytes) or any(b >= 0x80 for b in raw_bytes):
                            item['sourceBytesHex'] = raw_bytes.hex()
                        item.update({
                            'profile': 'upstream',
                            'flags': flags,
                            'allowDeclarationSyntax': False,
                            'origin': f'Luau {version} tests/Compiler.test.cpp:{line}',
                        })
                        fixtures.append(item)
        i += 1

    fixtures.sort(key=lambda c: int(c['origin'].rsplit(':', 1)[1]))
    return fixtures


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--source', type=pathlib.Path, required=True, help='Luau source checkout directory')
    ap.add_argument('--output', type=pathlib.Path, required=True, help='Output JSON fixture manifest path')
    ap.add_argument('--version', default=json.loads((ROOT / 'UPSTREAM.json').read_text())['version'])
    args = ap.parse_args()

    fixtures = extract_fixtures(args.source, args.version)
    assert len(fixtures) >= 100, f'Unexpected compiler fixture count: {len(fixtures)}'
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(fixtures, indent=2) + '\n')
    print(f'Extracted {len(fixtures)} official compiler fixtures')


if __name__ == '__main__':
    main()
