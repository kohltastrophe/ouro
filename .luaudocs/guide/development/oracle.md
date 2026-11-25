---
title: Conformance Oracle
description: Build and run the pinned C++ parser, compiler, bytecode, and VM conformance oracle and fuzzers.
outline: deep
sidebar_position: 3
---

# Conformance Oracle

The shipped Ouro runtime has no C++ dependency. This development oracle links the official Luau `Ast`, `Compiler`, `Bytecode`, and `VM` libraries plus an extended upstream JSON encoder.

```sh
cmake -S tools -B /tmp/ouro-build -G Ninja \
  -DLUAU_SOURCE_DIR=/tmp/luau-3d91c9d5c280c95bfc4be63aac46012cf861d394 \
  -DCMAKE_BUILD_TYPE=Release
cmake --build /tmp/ouro-build --target parser-oracle -j 4
python3 tests/differential.py --oracle /tmp/ouro-build/parser-oracle
python3 tests/differential.py --lex
python3 tests/differential.py --compile
python3 tests/differential.py --vm
```

Run the complete portable and differential suite (after `python3 tools/sert.py fetch`) with:

```sh
# With an already-built parser-oracle and pre-extracted fixtures in --build-dir:
python3 tools/check.py --report-dir /tmp/ouro-ci-report
# Or build the pinned oracle and extract fixtures from upstream source:
python3 tools/check.py --upstream /tmp/luau-3d91c9d5c280c95bfc4be63aac46012cf861d394
```

`tools/check.py` executes the portable suite (`tests/run.luau` over `tests/*.spec.luau`). Omitting `--upstream` requires an existing `parser-oracle` plus pre-extracted `differential-all-literals.json` and `compiler-fixtures.json` in `--build-dir`. It then runs all 9 differential modes (`targeted`, `upstream`, `entrypoints`, `all-literals`, `lexer`, `compiler-targeted`, `compiler-upstream`, `compiler-tests`, and `vm-targeted`), upstream conformance checks (`tests/conformance.py`, when `--upstream` or `/tmp/luau-src-0.748` is present), and seeded lexical and VM fuzzing (`tools/lex_fuzz.py`, `tools/vm_fuzz.py`). Optional `--report-dir` JSON reports record fixture and oracle binary fingerprints. No benchmark runs in ordinary correctness CI. Run `luau --codegen tests/run.luau -a --compact` for JIT codegen coverage and `python3 tools/sert.py lint` for `--!strict` typechecking under both old and new Luau solvers.

When `--upstream` is supplied, the check runner extracts `differential-all-literals.json` into `--build-dir` (gitignored if kept under `tests/`) and compiles every extracted literal with C++ to verify all 326 exact byte strings. You can run it directly with `extract_fixtures.py --source UPSTREAM --quoted --output /tmp/differential-all-literals.json` followed by `verify_fixture_bytes.py --source UPSTREAM --fixtures /tmp/differential-all-literals.json`.

CMake verifies every file listed in `UPSTREAM.json`, covering the complete `Ast`, `Common`, `Bytecode`, and `Compiler` trees, `CMakeLists.txt`, `Sources.cmake`, `LICENSE.txt`, `lua_LICENSE.txt`, `Analysis/src/AstJsonEncoder.cpp`, `tests/Parser.test.cpp`, and `tests/Compiler.test.cpp`. The oracle reports the manifest commit, and a mismatched revision fails differential tests.

`parser-oracle [--profile upstream|studio|experimental] [--mode chunk|expression|type] [--lex] [--compile] [--vm] [--declarations] [--opt N] [--debug N] [--type-info N] [--coverage N] [--dump MASK] [--vector-lib NAME] [--vector-ctor NAME] [--vector-type NAME] [--vector-precision N] [--mutable-global NAME] [--userdata-type NAME] [--disabled-builtin NAME] [--test-lib-constants] [--flag NAME=true|false] [--int NAME=VALUE] FILE` accepts `-` for binary stdin. It emits JSON on success, including parse and compile errors, and exits nonzero only on file, configuration, or build failures.

`upstream` uses all pinned default grammar flags. `studio` enables the three shipping Studio flags in `Profiles.luau`, validated against Roblox Studio via `tests/studio/profile.luau`. `experimental` enables all bool grammar flags linked by the driver. Declaration syntax in `parser-oracle` is enabled when `--declarations` is passed (`tools/oracle.cpp` sets `options.allowDeclarationSyntax` directly from that flag). The output includes exact active flags and the upstream revision.

The encoder is supplemented for type functions, expression instantiation, user classes, if-local and while-local bindings, and recovery-node metadata, and declaration-global output repairs an upstream duplicate `type` JSON key. Binding supplements include declarations, shadows, lexical depths, and reference/upvalue links. Node locations in the nested AST use upstream `line,column - line,column`, while diagnostic, binding, comment, and lexical spans use zero-based half-open byte offsets.

`--lex` emits non-whitespace tokens including comments and EOF, merging captured comments back into source order when comparing runtime tokens. Lossless whitespace reconstruction is tested by the portable Luau suite.

`--entrypoints` adds 15 expression and type API cases. The official expression and type entrypoints accept a prefix by design.

The `targeted` corpus runs 110 cases covering syntax, bindings, and error recovery alongside official parser excerpts. `--fixtures tests/differential-all-literals.json --raw-only` runs 279 extracted raw-string calls out of the 326 cases in `differential-all-literals.json` and applies per-test bool overrides and declaration options to both implementations. Extract the unified manifest on demand with `extract_fixtures.py --source UPSTREAM --quoted --output tests/differential-all-literals.json` (`tests/differential-all-literals.json` and `tests/differential-upstream.json` are gitignored). Concatenated or composed C++ source expressions are excluded, and exact bytes are retained as `sourceBytesHex`. Every parser comparison checks the full nested AST, diagnostics, comments, hotcomments, normalized bindings, shadows, lexical depths, reference/upvalue relationships, and recovery-node diagnostic indices. `--compile` compares 106 targeted, 136 upstream, and (with `--fixtures compiler-fixtures.json`) 691 extracted `Compiler.test.cpp` cases across O0, O1, and O2 bytecode, disassembly, compiler remarks, and typeinfo against `Luau::compile`. `--vm` compares 105 execution cases across O0, O1, and O2 (including normalized load and runtime errors) against `Luau.VM`, complemented by 34 standalone-compatible upstream conformance scripts in `tests/conformance.py` (with 23 host-dependent or forced-GC scripts skipped). `lex_fuzz.py` generates 6,000 malformed byte inputs using seed `7422026` (`--samples` and `--seed` configure alternate runs), and `vm_fuzz.py` differentially compiles and executes 200 seeded structured programs across O0, O1, and O2 (`--count` and `--seed` configure alternate runs).
