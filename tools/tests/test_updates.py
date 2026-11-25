"""Fail-closed update tooling tests. MIT."""
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
import daily
import fetch_upstream
import generate


class Updates(unittest.TestCase):
    def test_enum_rejects_unhandled_cpp_expressions(self):
        with tempfile.TemporaryDirectory() as temp:
            source = pathlib.Path(temp)
            path = source / 'Ast/include/Luau/Lexer.h'
            path.parent.mkdir(parents=True)
            path.write_text('enum Type { Eof = 0, Char_END = 256, Reserved_END = Char_END + 1 };')
            with self.assertRaises(ValueError):
                generate.tokens(source)

    def test_enum_alias_and_reserved_boundary(self):
        with tempfile.TemporaryDirectory() as temp:
            source = pathlib.Path(temp)
            path = source / 'Ast/include/Luau/Lexer.h'
            path.parent.mkdir(parents=True)
            path.write_text('enum Type { Eof = 0, Char_END = 256, Token, Reserved_BEGIN, ReservedAnd = Reserved_BEGIN, Reserved_END };')
            values = generate.tokens(source)
            self.assertEqual(values['Token'], 257)
            self.assertEqual(values['ReservedAnd'], 258)
            self.assertEqual(values['Reserved_END'], 259)

    def test_new_dynamic_flag_is_retained(self):
        with tempfile.TemporaryDirectory() as temp:
            source = pathlib.Path(temp)
            path = source / 'Ast/src/Parser.cpp'
            path.parent.mkdir(parents=True)
            path.write_text('LUAU_FASTFLAGVARIABLE(OldFlag)\nLUAU_DYNAMIC_FASTFLAGVARIABLE(NewFlag, true)\n')
            self.assertEqual(generate.grammar_flags(source), {'OldFlag': False, 'NewFlag': True})

    def test_checksum_detects_new_and_modified_source(self):
        with tempfile.TemporaryDirectory() as temp:
            source = pathlib.Path(temp) / 'source'
            root = pathlib.Path(temp) / 'library'
            root.mkdir()
            for name in ('Ast/src/Parser.cpp', 'Common/src/Example.cpp', 'Bytecode/src/BytecodeBuilder.cpp',
                         'Compiler/src/Compiler.cpp', 'CMakeLists.txt', 'Sources.cmake',
                         'LICENSE.txt', 'lua_LICENSE.txt', 'Analysis/src/AstJsonEncoder.cpp',
                         'tests/Parser.test.cpp', 'tests/Compiler.test.cpp'):
                path = source / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text('original')
            manifest = {'files': generate.snapshot(source)}
            (root / 'UPSTREAM.json').write_text(json.dumps(manifest))
            generate.verify(source, root)
            (source / 'Ast/src/Parser.cpp').write_text('modified')
            with self.assertRaisesRegex(ValueError, 'Parser.cpp'):
                generate.verify(source, root)
            (source / 'Ast/src/Parser.cpp').write_text('original')
            (source / 'Ast/src/New.cpp').write_text('new')
            with self.assertRaisesRegex(ValueError, 'New.cpp'):
                generate.verify(source, root)

    def test_does_not_mark_changed_parser_compatible_when_corpus_passes(self):
        baseline = json.loads((daily.ROOT / 'UPSTREAM.json').read_text())
        hashes = dict(baseline['files'])
        hashes['Ast/src/Parser.cpp'] = 'changed'
        release = {'version': '0.743', 'commit': 'a' * 40}
        with tempfile.TemporaryDirectory() as temp, \
             mock.patch.object(generate, 'snapshot', return_value=hashes), \
             mock.patch.object(generate, 'generated', return_value={}), \
             mock.patch.object(subprocess, 'run', return_value=subprocess.CompletedProcess([], 0)):
            output = pathlib.Path(temp)
            result = daily.evaluate(output, release, output, 'luau')
            self.assertTrue(result['conformancePassed'])
            self.assertEqual(result['status'], 'needs-port')
        self.assertEqual(json.loads((daily.ROOT / 'UPSTREAM.json').read_text()), baseline)

    def test_oracle_failure_requires_port(self):
        baseline = json.loads((daily.ROOT / 'UPSTREAM.json').read_text())
        with tempfile.TemporaryDirectory() as temp, \
             mock.patch.object(generate, 'snapshot', return_value=baseline['files']), \
             mock.patch.object(generate, 'generated', return_value={}), \
             mock.patch.object(subprocess, 'run', return_value=subprocess.CompletedProcess([], 1)):
            output = pathlib.Path(temp)
            result = daily.evaluate(output, {'version': '0.743', 'commit': 'b' * 40}, output, 'luau')
            self.assertFalse(result['conformancePassed'])
            self.assertEqual(result['status'], 'needs-port')

    def test_latest_excludes_prerelease(self):
        with mock.patch.object(fetch_upstream, 'api', return_value={
                'tag_name': '0.743', 'draft': False, 'prerelease': True}):
            with self.assertRaises(ValueError):
                fetch_upstream.latest()

    def test_archive_fetch_requires_immutable_sha(self):
        with self.assertRaises(ValueError):
            fetch_upstream.fetch('master', pathlib.Path('/tmp/should-not-fetch'))

    def test_compact_bytecode_defs_omits_dead_tables_and_aliases(self):
        with tempfile.TemporaryDirectory() as temp:
            source = pathlib.Path(temp)
            (source / 'Common/include/Luau').mkdir(parents=True)
            (source / 'Compiler/src').mkdir(parents=True)
            (source / 'Bytecode/src').mkdir(parents=True)
            (source / 'Common/include/Luau/Bytecode.h').write_text(
                'enum LuauOpcode { LOP_NOP = 0, LOP_JUMP = 1, LOP__COUNT };\n'
                'enum LuauBytecodeTag { LBC_VERSION_MIN = 3 };\n'
                'enum LuauBytecodeType { LBC_TYPE_NIL = 0 };\n'
                'enum LuauBuiltinFunction { LBF_NONE = 0 };\n'
                'enum LuauCaptureType { LCT_VAL = 0 };\n'
                'enum LuauProtoFlag { LPF_NONE = 0 };\n'
                'enum LuauFeedbackType { LFT_NONE = 0 };\n'
            )
            (source / 'Common/include/Luau/BytecodeUtils.h').write_text(
                'inline int getOpLength(LuauOpcode op) {\n\tswitch (op) {\n\tdefault: return 1;\n\t}\n}\n'
                'inline bool isJumpD(LuauOpcode op) {\n\tswitch (op) {\n\tcase LOP_JUMP:\n\t\treturn true;\n\tdefault: return false;\n\t}\n}\n'
                'inline bool isFastCall(LuauOpcode op) {\n\tswitch (op) {\n\tdefault: return false;\n\t}\n}\n'
                'inline int isSkipC(LuauOpcode op) {\n\tswitch (op) {\n\tdefault: return 0;\n\t}\n}\n'
            )
            (source / 'Compiler/src/Compiler.cpp').write_text('LUAU_FASTFLAGVARIABLE(TestBool, true)\nLUAU_FASTINTVARIABLE(TestInt, 5)\n')
            out = generate.bytecode_defs(source, '-- header\n')
            self.assertIn('LOP_NOP = 0,', out)
            self.assertNotIn('\tNOP = 0,', out)
            self.assertNotIn('isFallthrough', out)
            self.assertNotIn('isLoopJump', out)

    def test_generate_rejects_malformed_confusables_and_missing_bytecode_enum(self):
        with tempfile.TemporaryDirectory() as temp:
            source = pathlib.Path(temp)
            for p in ('Ast/src', 'Ast/include/Luau', 'Common/include/Luau', 'Bytecode/src', 'Compiler/src', 'Analysis/src', 'tests'):
                (source / p).mkdir(parents=True, exist_ok=True)
            (source / 'Ast/src/Parser.cpp').write_text('LUAU_FASTFLAGVARIABLE(TestFlag, true)\n')
            (source / 'Ast/include/Luau/Lexer.h').write_text('enum Type { Eof = 0, Char_END = 256, Reserved_END };\n')
            (source / 'Common/include/Luau/Bytecode.h').write_text('// empty\n')
            (source / 'Common/include/Luau/BytecodeUtils.h').write_text(
                'inline int getOpLength(LuauOpcode op) {\n\tswitch (op) {\n\tdefault: return 1;\n\t}\n}\n'
                'inline bool isJumpD(LuauOpcode op) {\n\tswitch (op) {\n\tdefault: return false;\n\t}\n}\n'
                'inline bool isFastCall(LuauOpcode op) {\n\tswitch (op) {\n\tdefault: return false;\n\t}\n}\n'
                'inline int isSkipC(LuauOpcode op) {\n\tswitch (op) {\n\tdefault: return 0;\n\t}\n}\n'
            )
            with self.assertRaisesRegex(ValueError, 'LuauOpcode'):
                generate.bytecode_defs(source, '-- header\n')

            (source / 'Common/include/Luau/Bytecode.h').write_text(
                'enum LuauOpcode { LOP_NOP = 0, LOP__COUNT };\n'
                'enum LuauBytecodeTag { LBC_VERSION_MIN = 3 };\n'
                'enum LuauBytecodeType { LBC_TYPE_NIL = 0 };\n'
                'enum LuauBuiltinFunction { LBF_NONE = 0 };\n'
                'enum LuauCaptureType { LCT_VAL = 0 };\n'
                'enum LuauProtoFlag { LPF_NONE = 0 };\n'
                'enum LuauFeedbackType { LFT_NONE = 0 };\n'
            )
            (source / 'Compiler/src/Compiler.cpp').write_text('LUAU_FASTFLAGVARIABLE(TestBool, true)\nLUAU_FASTINTVARIABLE(TestInt, 5)\n')
            (source / 'Ast/src/Confusables.cpp').write_text('const Confusable kConfusables[] = {\n{65, "a\\tb"},\n};\n')
            with self.assertRaisesRegex(ValueError, 'delimiters'):
                generate.generated(source, '0.748', 'a' * 40)

    def test_daily_evaluate_up_to_date_candidate_passed_and_ignores_benchmarks(self):
        baseline = json.loads((daily.ROOT / 'UPSTREAM.json').read_text())
        with tempfile.TemporaryDirectory() as temp:
            output = pathlib.Path(temp)
            with mock.patch.object(generate, 'snapshot', return_value=baseline['files']), \
                 mock.patch.object(generate, 'verify', return_value=baseline):
                up_res = daily.evaluate(output, {'version': baseline['version'], 'commit': baseline['commit']}, output, 'luau')
            self.assertEqual(up_res['status'], 'up-to-date')
            self.assertIsNone(up_res['conformancePassed'])

        hashes = dict(baseline['files'])
        hashes['tests/Parser.test.cpp'] = 'data-only-update'
        with tempfile.TemporaryDirectory() as temp, \
             mock.patch.object(generate, 'snapshot', return_value=hashes), \
             mock.patch.object(generate, 'generated', return_value={}), \
             mock.patch.object(subprocess, 'run', return_value=subprocess.CompletedProcess([], 0)):
            output = pathlib.Path(temp)
            cand_res = daily.evaluate(output, {'version': '0.749', 'commit': 'c' * 40}, output, 'luau')
            self.assertEqual(cand_res['status'], 'candidate-passed')
            self.assertTrue(cand_res['conformancePassed'])
            self.assertTrue((output / 'candidate').is_dir())
            self.assertFalse((output / 'candidate/benchmarks').exists())


if __name__ == '__main__':
    unittest.main()
