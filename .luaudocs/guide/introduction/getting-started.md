---
title: Getting Started
description: Install Ouro with Wally, pesde, Rojo, or GitHub Releases and run your first sandboxed Luau script.
outline: deep
sidebar_position: 2
---

# Getting Started

Install Ouro in Roblox or standalone Luau and run your first sandboxed script in a few lines.

## Installation

### Wally (Recommended)

Add `Ouro` to `[dependencies]` in `wally.toml` and run `wally install`:

```toml
[dependencies]
Ouro = "kohltastrophe/ouro@0.1.0"
```

Ouro installs as a `shared` dependency in `Packages`, available on both the Roblox server and client.

### pesde

Install Ouro with the pesde CLI:

```sh
pesde add kohltastrophe/ouro
```

Or add it directly to `[dependencies]` in `pesde.toml` and run `pesde install`:

```toml
[dependencies]
ouro = { name = "kohltastrophe/ouro", version = "^0.1.0" }
```

Ouro publishes both `roblox` and `luau` targets under the same version, so `pesde add` picks the matching build automatically.

### GitHub Releases (`.rbxm`)

1. Download `Ouro.rbxm` or `Ouro-<version>-package.zip` (with `SHA256SUMS`) from **[GitHub Releases](https://github.com/kohltastrophe/ouro/releases)**.
2. Drag `Ouro.rbxm` into Roblox Studio and place the `Ouro` module inside [`ReplicatedStorage`](https://create.roblox.com/docs/reference/engine/classes/ReplicatedStorage).

### Rojo, Standalone & `dist` Branch

Sync `src/` directly into your Rojo tree, require the repository root directly in standalone Luau (`local Ouro = require("./ouro")`), or vendor the runtime-only [`dist` branch](https://github.com/kohltastrophe/ouro/tree/dist):

```sh
git subtree add --prefix=Packages/Ouro https://github.com/kohltastrophe/ouro.git dist --squash
```

You can also build an `.rbxm` locally with Rojo (`rojo build default.project.json --output build/Ouro.rbxm`).

## Your First Sandbox

```luau
--!strict
local Ouro = require("./ouro")

local baseEnv = Ouro.VM.createEnvironment({ answer = 40 }, { readOnly = true })
local env = Ouro.VM.sandbox(baseEnv)

local fn, err = Ouro.load("return answer + bonus", {
	name = "=example",
	env = env,
	instructionLimit = 100_000,
	callLimit = 64,
	timeout = 1,
	safeEnv = true,
	resourceLimits = {
		maxStringLength = 65_536,
		maxTableSize = 10_000,
	},
	getGlobal = function(name, currentEnv)
		if name == "bonus" then
			return 2
		end
		return currentEnv[name]
	end,
})

if fn then
	print(fn()) -- 42
else
	warn(err)
end
```

### How It Works

1. **`Ouro.VM.createEnvironment(..., { readOnly = true })`** creates an isolated pure-Luau standard library environment with `answer = 40` and freezes it so guest scripts can't mutate shared globals.
2. **`Ouro.VM.sandbox(baseEnv)`** creates a fresh writable per-chunk overlay backed by `baseEnv`, including its own isolated `math.random` generator state.
3. **`Ouro.load(source, options)`** compiles the Luau source to bytecode and binds execution limits (`instructionLimit`, `callLimit`, `timeout`, `resourceLimits`) plus global interception (`getGlobal`).
4. **`fn()`** executes the closure inside the pure-Luau register VM and returns `42` without touching host globals.

## Parsing & Compiling Directly

You can also run the parser and compiler stages on their own to inspect ASTs or emit bytecode:

```luau
--!strict
local Ouro = require("./ouro")

local source = "-- keep comment\nlocal x: number = 20 + 22\nreturn x"
local parsed = Ouro.parse(source, { profile = "studio", lossless = true })

if parsed.status == "ok" then
	assert(parsed:reconstruct() == source)

	local bytecode = assert(Ouro.compile(parsed, { optimizationLevel = 2 }))
	print(Ouro.Bytecode.disassemble(bytecode))
end
```

Passing an existing `ParseResult` to [`Ouro.compile`](/api/Ouro#compile) skips re-lexing and reparsing the source string.

## Next Steps

- **[Parsing & AST](/guide/pipeline/parsing):** Parse scripts, expressions, and types, configure profiles, reconstruct bytes losslessly, and walk arenas.
- **[Compiling & Bytecode](/guide/pipeline/compiling):** Tune O0–O2 optimizations, intercept library constants, disassemble, serialize, and verify bytecode.
- **[Sandboxed VM](/guide/pipeline/vm):** Configure isolated environments, resource budgets, global hooks, coverage, and debuggers.
- **[Security & Sandbox](/guide/pipeline/security):** Review sandbox boundaries and copy a hardened production configuration.
- **[Benchmarks](/guide/benchmarks):** Compare Ouro against Fiu and LuauCeption across VM execution, O2 compilation, and cold startup.
- **[API Reference](/api/):** Browse full generated `--!strict` signatures for every public module and type.
