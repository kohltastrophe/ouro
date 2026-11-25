---
title: Getting Started
description: Install Ouro with Wally, pesde, Rojo, or GitHub Releases and run your first script.
outline: deep
sidebar_position: 2
---

# Getting Started

Install Ouro in Roblox or standalone Luau and parse, compile, or sandbox your first chunk.

## Installation

### Wally

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

1. Download `Ouro.rbxm` or `Ouro-<version>-package.zip` (with `SHA256SUMS`) from [GitHub Releases](https://github.com/kohltastrophe/ouro/releases).
2. Drop `Ouro.rbxm` into Roblox Studio under `ReplicatedStorage`.

### Rojo or Standalone Luau

- **Rojo:** Build a `.rbxm` with `rojo build default.project.json --output build/Ouro.rbxm` or sync `src/` directly into `ReplicatedStorage`.
- **Standalone Luau:** Require the repository root directly (`local Ouro = require("./ouro")`).
- **Git subtree (`dist` branch):** Pull the runtime-only `dist` branch for `default.project.json`, `init.luau`, `src/`, `LICENSE.md`, and `UPSTREAM.json`:

```sh
git subtree add --prefix=Packages/Ouro https://github.com/kohltastrophe/ouro.git dist --squash
```

## First Steps

### 1. Parse and Reconstruct Source

```luau
--!strict
local Ouro = require("./ouro")

local source = "-- keep comments\nlocal x: number = 20 + 22\nreturn x"
local parsed = Ouro.parse(source, {
	profile = "studio",
	lossless = true,
})

if parsed.status == "ok" then
	print(parsed:kindName(parsed.root)) -- "AstStatBlock"
	assert(parsed:reconstruct() == source)
end
```

### 2. Compile to Luau Bytecode

```luau
local compiled = Ouro.compileResult("local a, b = ...\nreturn a * b + 2", {
	optimizationLevel = 2,
	dumpFlags = Ouro.Bytecode.DumpFlags.Code,
})

if compiled.status == "ok" and compiled.builder then
	print(compiled.builder:dumpEverything())
end
```

### 3. Execute Untrusted Code in a Sandbox

```luau
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

## Next Steps

- [Parsing & AST](/guide/pipeline/parsing): Configure parser profiles, lossless reconstruction, arena visitors, and yielding checkpoints.
- [Compiling & Bytecode](/guide/pipeline/compiling): Tune optimization levels, custom builtin callbacks, encoders, and disassembly.
- [Sandboxed VM](/guide/pipeline/vm): Configure isolated environments, instruction and time caps, global hooks, and debugger callbacks.
- [Benchmarks](/guide/benchmarks): Compare Ouro against Fiu and LuauCeption across VM execution, O2 compilation, and cold startup.
