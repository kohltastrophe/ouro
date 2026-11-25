<div align="right">
<a href="https://discord.gg/kohl"><picture><source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/kohltastrophe/kohltastrophe/main/.github/img/link-discord-dark.svg"><img alt="Discord" src="https://raw.githubusercontent.com/kohltastrophe/kohltastrophe/main/.github/img/link-discord.svg"></picture></a>
</div>

<div align="center">

# Parse. Compile. Execute.

_Ouro is a self-hosted Luau 0.748 lexer, recursive-descent parser, bytecode compiler, and register VM written in pure `--!strict` Luau. It runs in standalone Luau and Roblox without FFI, `loadstring`, or native services._

[![CI](https://img.shields.io/github/actions/workflow/status/kohltastrophe/ouro/ci.yml?label=CI&style=for-the-badge)](https://github.com/kohltastrophe/ouro/actions/workflows/ci.yml) [![Coverage](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/kohltastrophe/ouro/badges/coverage.json&style=for-the-badge)](https://github.com/kohltastrophe/ouro/actions/workflows/ci.yml) [![Upstream](https://img.shields.io/github/actions/workflow/status/kohltastrophe/ouro/upstream.yml?label=Upstream&style=for-the-badge)](https://github.com/kohltastrophe/ouro/actions/workflows/upstream.yml) [![Luau 0.748](https://img.shields.io/badge/Luau-0.748-006AB4?style=for-the-badge)](UPSTREAM.json) [![License](https://img.shields.io/github/license/kohltastrophe/ouro?style=for-the-badge)](LICENSE.md) [![GitHub Release](https://img.shields.io/github/v/release/kohltastrophe/ouro?style=for-the-badge)](https://github.com/kohltastrophe/ouro/releases)

</div>

---

## Parse

```luau
local Ouro = require("./ouro")

local source = "-- keep comments\nlocal x: number = 20 + 22\nreturn x"
local parsed = Ouro.parse(source, {
	profile = "studio",
	lossless = true,
})

if parsed.status == "ok" then
	print(parsed:kindName(parsed.root)) -- "AstStatBlock"
	assert(parsed:reconstruct() == source)
	local tree = Ouro.Ast.toTables(parsed)
	if tree then
		print(tree.type, #tree.body) -- "AstStatBlock", 2
	end
end
```

`Ouro.parse` lowers Luau syntax, type annotations, and `.d.luau` declarations into a flat numeric arena with zero-based byte offsets, avoiding per-node table references until you opt into `Ouro.Ast.toTables`. Lossless mode records a compact token/trivia tape so `reconstruct()` restores exact input bytes, while `Ouro.newContext` reuses scratch tables and supports cooperative yielding through coroutine checkpoints.

---

## Compile

```luau
local Ouro = require("./ouro")

local compiled = Ouro.compileResult("local a, b = ...\nreturn a * b + 2", {
	optimizationLevel = 2,
	dumpFlags = Ouro.Bytecode.DumpFlags.Code,
})

if compiled.status == "ok" and compiled.builder then
	print(compiled.builder:dumpEverything())
	local protoModule = assert(Ouro.Bytecode.deserialize(compiled.bytecode))
	print(#protoModule.protos, protoModule.version)
end
```

The compiler emits Luau bytecode (v14 default, v100 for classes) across optimization levels 0, 1, and 2, matching upstream constant folding, builtin fastcalls, inlining, and loop specialization. Passing an existing `ParseResult` skips reparsing, and `Ouro.Bytecode` exposes opcode/builtin tables, disassembly dumps, compiler remarks, and binary `ProtoModule` decoding.

---

## Execute

```luau
local Ouro = require("./ouro")

local baseEnv = Ouro.VM.createEnvironment({ answer = 40 }, { readOnly = true })
local env = Ouro.VM.sandbox(baseEnv)
local chunk = assert(Ouro.load("return answer + bonus", {
	name = "=example",
	env = env,
	instructionLimit = 100_000,
	callLimit = 64,
	timeout = 1,
	safeEnv = true,
	getGlobal = function(name, currentEnv)
		if name == "bonus" then
			return 2
		end
		return currentEnv[name]
	end,
}))

print(chunk()) -- 42
```

`Ouro.load` runs raw source, compiled bytecode (with optional `decoder` callbacks), or a decoded `ProtoModule` inside an isolated pure-Luau register VM. When `options.env` is omitted, each load creates a fresh isolated environment (`inheritHost = false`) and locks `getmetatable("")` to `"The metatable is locked"`. Environments expose `collectgarbage("count" | "collect")`, per-environment isolated `math.random`/`math.randomseed` state, `libraries` allowlists, `readOnly` bases, and `VM.sandbox` overlays. Execution controls cover `getGlobal`/`setGlobal` hooks, closure cloning/upvalues/coverage, instruction and call caps, lazy `timeout` clocks (`VM.resetBudget`), and debug hooks (`onCall`, `onReturn`, `onLine`, `onBreak`). Invalid option keys or argument types throw validation errors, while syntax errors and malformed bytecode or `ProtoModule` data return `(nil, err)` (except `Ouro.Bytecode.disassemble`, which throws on corrupt bytecode).

---

## Batteries Included

Ouro covers the full frontend and runtime pipeline in pure Luau:

- Lexer and Lossless Parser: Parses chunks, fragments (`parseExpression`, `parseType`), comments, and hotcomments into flat numeric arenas with SoA metadata (`kinds`, `starts`, `finishes`), allocation-light schema traversal (`visit` and zero-alloc `forEachChild`), and exact [`reconstruct()`](docs/api.md#parsing) byte preservation.
- Profiles, Declarations, and AST: Switches between [`upstream`, `studio`, and `experimental`](docs/api.md#parse-options--profiles) profiles, enables `.d.luau` parsing via `allowDeclarationSyntax = true`, validates custom frozen flags, or materializes lossless tables with [`Ouro.Ast.toTables`](docs/api.md#parse-results--arena-storage).
- Compiler and Bytecode Codec: Lowers ASTs across O0/O1/O2 with `@native` type-info helpers, constant folding, builtin fastcalls, typed local specialization, inlining, and vector lowering without mutating input `ParseResult` arenas via [`CompileOptions`](docs/api.md#compilation). [`Ouro.Bytecode`](docs/api.md#bytecode-codec--disassembly) disassembles (throwing on corrupt input) and verifies, hashes, serializes, or decodes bytecode (`BytecodeDecoder`).
- Sandboxed Register VM: Executes raw source, `v3`–`v14` bytecode, or `ProtoModule` tables through dual `@native` fast/guarded loops inside isolated pure-stdlib or `VM.sandbox` environments with locked `getmetatable("")`, isolated `math.random`, `collectgarbage`, `getGlobal`/`setGlobal` hooks, `LoadOptions` guards, opt-in `ResourceLimits`, and debug inspection via [`Ouro.load` and `Ouro.VM`](docs/api.md#register-vm).

Root `require` keeps startup light via [`lazy submodule loading`](docs/api.md#entrypoints--lazy-loading) across `Ast`, `Profiles`, `Tokens`, `Kinds`, `Compiler`, `Bytecode`, and `VM`. Differential suites verify lexer, parser, compiler, and VM parity against pinned upstream C++ `0.748` across targeted, upstream, conformance, and fuzz corpora. See [tools/README.md](tools/README.md) for full harness breakdowns and counts.

Type inference, incremental reparsing, and native code generation are outside this package.

## Installation

- Wally or pesde: Add `kohltastrophe/ouro` in `wally.toml`, or install with `pesde add kohltastrophe/ouro` for either the `roblox` or `luau` target.
- GitHub Releases: Download `Ouro.rbxm` or `Ouro-<version>-package.zip` (with `SHA256SUMS`) from [Releases](https://github.com/kohltastrophe/ouro/releases).
- Roblox (Rojo): Build a `.rbxm` package with `rojo build default.project.json --output build/Ouro.rbxm` or sync `src/` directly into `ReplicatedStorage`.
- Standalone Luau: Require the repository root (`local Ouro = require("./ouro")`).
- Runtime-only subtree: Pull the `dist` branch via Git subtree (`git subtree add --prefix=Packages/Ouro <REPOSITORY_URL> dist --squash`) for `default.project.json`, `init.luau`, `src/`, `LICENSE.md`, and `UPSTREAM.json`.

## Documentation

| Document | Contents |
| :--- | :--- |
| [docs/api.md](docs/api.md) | Complete public API, `ParseOptions`, `CompileOptions`, `LoadOptions`, `Ouro.Bytecode`, `Ouro.VM`, arena rules, and exported types. |
| [CONTRACT.md](CONTRACT.md) | Internal module contracts across lexer, arena, state, parser, compiler, bytecode codec/builder, and VM. |
| [SECURITY.md](SECURITY.md) | Sandbox scope, string metatable limits, resource caps, and vulnerability reporting. |
| [UPDATES.md](UPDATES.md) | Upstream release tracking, code generation from `UPSTREAM.json`, and candidate adoption workflow. |
| [tools/README.md](tools/README.md) | Building the pinned C++ conformance oracle and running differential parser, compiler, VM, and fuzz suites. |

## Development & Verification

```sh
python3 tools/sert.py fetch
rojo build default.project.json --output build/Ouro.rbxm
luau tests/types/Api.luau
python3 tools/sert.py run
luau --codegen tests/run.luau -a --compact
python3 tools/sert.py lint
python3 tools/check.py --upstream /path/to/pinned/luau --report-dir /tmp/ouro-check
```

`tools/check.py` builds a checksum-guarded C++ reference oracle and runs the portable `sert` suite alongside 9 differential modes, upstream conformance checks, and seeded lexer/VM fuzzing. `sert.py lint` verifies formatting and `--!strict` typechecking under both old and new Luau solvers. Run Roblox engine specs with `python3 tools/sert.py studio` or `python3 tools/sert.py cloud` (`tests/studio/Roblox.spec.luau`), and validate Studio compiler grammar flags locally with `tests/studio/profile.luau`.

## Acknowledgments & Provenance

Ouro translates lexer, parser, compiler, bytecode, and VM algorithms and confusable mappings from official [Luau](https://github.com/luau-lang/luau), pinned to `0.748` ([`3d91c9d`](https://github.com/luau-lang/luau/tree/3d91c9d5c280c95bfc4be63aac46012cf861d394)) in [UPSTREAM.json](UPSTREAM.json). Arena storage, public APIs, lossless lexical tape, and coroutine checkpointing are adaptations for this pure-Luau port.

## Sponsors

Ouro is free and MIT-licensed. If Ouro is useful to you or your team, you can support its development through [GitHub Sponsors](https://github.com/sponsors/kohltastrophe) or [Ko-fi](https://ko-fi.com/kohltastrophe).

<p align="center">
  <a href="https://github.com/sponsors/kohltastrophe"><img src="https://raw.githubusercontent.com/kohltastrophe/kohltastrophe/badges/sponsor-github.svg" alt="GitHub Sponsors" /></a>&nbsp;&nbsp;<a href="https://ko-fi.com/kohltastrophe"><img src="https://raw.githubusercontent.com/kohltastrophe/kohltastrophe/badges/sponsor-kofi.svg" alt="Ko-fi" /></a>
  <a href="https://github.com/sponsors/kohltastrophe"><img src="https://raw.githubusercontent.com/kohltastrophe/kohltastrophe/badges/sponsors.svg" alt="Sponsors" /></a>
</p>

## License

MIT. See [LICENSE.md](LICENSE.md).
