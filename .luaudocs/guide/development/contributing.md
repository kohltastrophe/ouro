---
title: Contributing
description: Set up Rokit, sert, the C++ conformance oracle, benchmarks, and LuauDocs to develop Ouro.
outline: deep
sidebar_position: 1
---

# Contributing to Ouro

This guide covers developing Ouro itself, including the pure-Luau parser, compiler, VM, test suites, C++ conformance oracle, documentation site, and release workflow. If you are integrating Ouro into a project, start with [Getting Started](/guide/introduction/getting-started). See [Implementation Contracts](/guide/development/contracts) for internal module invariants.

Bug reports and pull requests are welcome. Open an issue before starting large architectural changes, and verify all local checks below pass before opening a pull request.

## Setup

- [Rokit](https://github.com/rojo-rbx/rokit): Run `rokit install` to install the tools pinned in `rokit.toml` (`luau`, `rojo`, `stylua`, `luau-lsp`, `wally`, `pesde`).
- Python `3.11+`: Run `python3 tools/sert.py fetch` to populate `.sert/` with the pinned [sert](https://github.com/kohltastrophe/sert) test runner and engine definitions locked in `sert.lock`.
- Node.js `22.12+`: Needed only if you preview or rebuild the [LuauDocs](https://github.com/kohltastrophe/luaudocs) documentation site.

## Repository Layout

```text
init.luau                root standalone entrypoint forwarding `@self/src`
src/                     Ouro package (Rojo root, --!strict Luau)
  init.luau              public Ouro facade and lazy submodule loader table
  Bytecode.luau          public bytecode codec, disassembler, verifier, and opcode tables
  Ast.luau               lossless AST table materialization
  Profiles.luau          built-in upstream, studio, and experimental grammar profiles
  Compiler.luau          AST-to-bytecode lowering (+ CompilerBuiltins/Class/Expr/Folding/Inline/Types)
  Parser.luau            public parse, parseExpression, parseType, and newContext
  VM/                    register VM (init, Dispatch, DispatchGuarded, Fastcalls, Verifier, RuntimeEnv, HostEnv)
  ...                    lexer, arena, diagnostics, generated defs/tokens/confusables
tests/                   unit, differential, coverage, fuzz, and Roblox Studio/Cloud specs
  run.luau               headless test entrypoint (`luau tests/run.luau`)
  types/                 compile-time positive and negative (`fail/`) type probes
  studio/                Roblox engine specs and grammar profile validation
docs/
  benchmarks/            reproducible comparative suite (`run.luau`, `bench.py`, `chart.py`)
.luaudocs/               VitePress guides, landing page, custom CSS, and static logo
.github/                 workflows, pesde publish script, image assets, and GitHub doc stubs
tools/                   upstream sync, codegen (`generate.py`), C++ oracle build, and `sert.py`
```

Files marked as generated in headers (`src/Token.luau`, `src/Confusables.luau`, `src/Grammar.luau`, `src/BytecodeDefs.luau`) are emitted from official Luau sources by `tools/generate.py`. See [Upstream Tracking](/guide/development/upstream) before editing them.

## Verification

Run formatting, static type checks, unit tests, coverage (`>= 95%` required across `src/`), and tool tests:

```sh
stylua --check src tests init.luau docs/benchmarks/run.luau
python3 tools/sert.py lint
python3 tools/sert.py run --coverage --compact
python3 tools/sert.py coverage
luau --codegen tests/run.luau -a --compact
luau tests/types/Api.luau
python3 -m unittest discover -s tools/tests -v
```

`tools/sert.py lint` runs `stylua --check`, `luau-lsp analyze` under both old and new solvers across `standard` and `roblox` platforms, and verifies `tests/types/` passes while every line in `tests/types/fail/` fails cleanly.

### C++ Differential, Conformance & Fuzz Oracle

To build the checksum-guarded upstream C++ reference oracle (`Luau 0.748`) and verify parser, compiler, VM, and fuzzer parity:

```sh
python3 tools/fetch_upstream.py --output /tmp/luau-upstream
python3 tools/check.py --upstream /tmp/luau-upstream --build-dir /tmp/ouro-oracle --report-dir /tmp/ouro-check
```

See [Conformance Oracle](/guide/development/oracle) for standalone oracle flags, corpus breakdowns, and fuzz options.

### Roblox Studio & Open Cloud Lanes

```sh
python3 tools/sert.py studio    # run tests/studio/test.project.json in a local Studio session
python3 tools/sert.py cloud     # build test place and run specs via Roblox Open Cloud
```

Validate Studio grammar profile flags locally with `tests/studio/profile.luau`.

## Benchmarks

Verify parity or run the comparative suite locally (`--fiu` and `--luauception` are optional):

```sh
python3 docs/benchmarks/bench.py --verify
luau --codegen -O2 docs/benchmarks/run.luau
python3 docs/benchmarks/bench.py --fiu /path/to/Fiu/Source.lua --luauception /path/to/luauception
python3 docs/benchmarks/chart.py
```

The [`Benchmarks` workflow](https://github.com/kohltastrophe/ouro/blob/main/.github/workflows/benchmark.yml) verifies parity with `--verify` on pull requests and pushes to `main`, then publishes `chart.svg`, `chart-small.svg`, `chart-interp.svg`, and `results.json` to the orphan `assets` branch. Generated `.json` and `.svg` outputs under `docs/benchmarks/` stay gitignored on `main`; inspect rendered SVGs for text clipping whenever editing `chart.py`. Local ad-hoc benchmarks and Roblox Studio scripts live in `benchmarks/` (gitignored).

## Documentation Site & `llms.txt`

The documentation site in `.luaudocs/` is built with [LuauDocs](https://github.com/kohltastrophe/luaudocs) from `src/` doc comments and guides under `.luaudocs/guide/`:

```sh
npx --yes luaudocs@latest build --emit-only --strict   # verify public API extraction and links
npx --yes luaudocs@latest dev                          # preview locally with HMR
npx --yes luaudocs@latest build                        # build static VitePress site
npx --yes luaudocs@latest llms                         # regenerate root llms.txt
npx --yes luaudocs@latest llms --check                 # verify committed llms.txt is current
```

After changing any public API signature, doc comment, or guide page, run `npx --yes luaudocs@latest llms` (or `luaudocs build --emit-only --strict`) before committing. CI checks `llms.txt` freshness on pull requests and auto-updates it on pushes to `main`.

## Releasing

[`.github/workflows/release.yml`](https://github.com/kohltastrophe/ouro/blob/main/.github/workflows/release.yml) uses `kohltastrophe/release` to maintain a release PR on `main` that bumps `wally.toml`, `pesde.toml`, `src/init.luau`, and `.luaudocs/guide/introduction/getting-started.md` from Conventional Commits. Merging the release PR tags `v<version>`, verifies CI, builds `Ouro.rbxm` and `Ouro-<version>-package.zip` with `SHA256SUMS`, updates the runtime-only `dist` branch, and publishes to Wally and pesde (`roblox` and `luau` targets via [`.github/scripts/publish_pesde.py`](https://github.com/kohltastrophe/ouro/blob/main/.github/scripts/publish_pesde.py)).

To validate packaging locally without publishing:

```sh
rojo build default.project.json --output build/Ouro.rbxm
wally package --list
python3 .github/scripts/publish_pesde.py
```
