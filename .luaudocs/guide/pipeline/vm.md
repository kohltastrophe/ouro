---
title: Sandboxed VM
description: Execute source or binary Luau bytecode in isolated environments with execution budgets and hooks.
outline: deep
sidebar_position: 3
---

# Sandboxed VM

[`Ouro.load`](/api/Ouro#load) compiles source strings or loads binary bytecode (`v3`–`v14` in a `string` or `buffer`) and `ProtoModule` IR inside a pure-Luau register VM. Experimental `v100` class bytecode is rejected cleanly.

```luau
--!strict
local Ouro = require("./ouro")

-- Load from Luau source in a fresh isolated environment
local runSource = assert(Ouro.load("local n = ...; return n * n"))
print(runSource(7)) -- 49

-- Or execute precompiled binary bytecode stored in a string or buffer
local bytecode = assert(Ouro.compile("return 'from bytecode'"))
local runBin = assert(Ouro.load(bytecode, { mode = "binary" }))
print(runBin()) -- "from bytecode"
```

By default, `mode` treats `string` inputs as `"text"` rather than sniffing binary headers, and treats `buffer` inputs as `"binary"`. Pass `mode = "binary"` for binary strings or `mode = "auto"` to sniff headers. Invalid chunk types, unknown option keys, out-of-range values, and `mode = "text"` with a `buffer` or `ProtoModule` throw immediately.

Every loaded closure starts with safe recursion and stack ceilings (`20,000` active call frames and `1,000,000` active stack slots) even when `callLimit` is unset.

## Isolated Environments & Sandboxes

When `options.env` is omitted, every `Ouro.load` call builds a fresh pure-Luau `VM.createEnvironment()` table and never inherits outer thread globals. Share a frozen standard library environment across scripts by wrapping it in per-chunk writable overlays with `VM.sandbox(baseEnv, overrides?)`:

```luau
-- Allowlist standard libraries, lock base globals read-only, and add host APIs
local sharedBase = Ouro.VM.createEnvironment({
	round = math.round,
}, {
	libraries = { "base", "math", "string", "table" },
	readOnly = true,
	resourceLimits = {
		maxStringLength = 16_384,
		maxTableSize = 1_000,
	},
})

-- Each chunk gets isolated globals and its own 64-bit PCG32 math.random state
local chunkA = assert(Ouro.load("x = math.random(1, 100); return x", {
	env = Ouro.VM.sandbox(sharedBase),
}))
local chunkB = assert(Ouro.load("return x, round(3.6)", {
	env = Ouro.VM.sandbox(sharedBase),
}))

local a = chunkA()
local seenFromA, rounded = chunkB()
assert(type(a) == "number" and seenFromA == nil and rounded == 4)
```

Guest environments include guest-aware `debug.traceback`/`info`, `collectgarbage("count" | "collect")`, isolated per-environment `PCG32` `math.random` state (keeping `math.*` fastcalls intact), and locked metatables. Writable and sandbox tables lock `__metatable = "locked"`, while `readOnly = true` returns a flat frozen table (`inheritHost = false`) or a locked read-only proxy (`inheritHost = true`).

| Field | Type | Default / Behavior |
| :--- | :--- | :--- |
| `inheritHost` | `boolean?` | `false`. Enables non-standard host or Roblox globals (`script` and `loadstring` stay omitted; `_G`, `getfenv`, `setfenv`, `debug`, `error`, and `xpcall` remain sandboxed). |
| `libraries` | `{ string }?` | `nil` (all libraries). Allowlist any subset of `"base"`, `"bit32"`, `"buffer"`, `"coroutine"`, `"debug"`, `"math"`, `"os"`, `"string"`, `"table"`, `"utf8"`, `"vector"`. |
| `readOnly` | `boolean?` | `false`. Freezes the table when `inheritHost = false`, or returns a locked read-only proxy when `inheritHost = true`. |
| `resourceLimits` | `ResourceLimits?` | Optional caps (`maxStringLength`, `maxTableSize`, `maxBufferSize`, `maxPatternLength`) attached with zero overhead when omitted. |

> [!NOTE]
> Inside VM environments on both hosts, `getmetatable("")` returns `"The metatable is locked"`. Because host Luau shares a single metatable across all strings, method calls such as `("abc"):upper()` still resolve through host string methods even if `"string"` is omitted from `libraries`.

## Execution Guards & Hooks {#execution-guards}

Configure instruction budgets, call-depth caps, wall-clock deadlines, allocation limits, and global interception hooks without slowing down unguarded VM loops:

```luau
local globals = {}
local env = Ouro.VM.sandbox(Ouro.VM.createEnvironment(nil, { readOnly = true }))

local fn = assert(Ouro.load([[
	score = 40
	return score + bonus + math.max(1, 2)
]], {
	name = "=guarded",
	env = env,
	instructionLimit = 50_000,
	callLimit = 64,
	timeout = 0.25,
	interruptInterval = 1_024,
	safeEnv = true,
	resourceLimits = {
		maxStringLength = 65_536,
		maxTableSize = 10_000,
	},
	getGlobal = function(name, currentEnv)
		return globals[name] or currentEnv[name]
	end,
	setGlobal = function(name, value, currentEnv)
		globals[name] = value
		currentEnv[name] = value
	end,
}))

globals.bonus = 0
print(fn()) --> 42

-- Reset instruction count and clear the lazy timeout clock before reusing fn
Ouro.VM.resetBudget(fn)
```

Same-context `pcall` and `xpcall` cannot catch aborts from `instructionLimit`, `timeout`, or `interrupt`, so a runaway guest script can't trap its own cancellation.

| Field | Type | Behavior |
| :--- | :--- | :--- |
| `name` | `string?` | Chunk name in stack traces (`[string "..."]` for text, `"=chunk"` for binary/`ProtoModule`). |
| `env` | `{ [any]: any }?` | Global environment table (defaults to a fresh isolated `VM.createEnvironment()`). |
| `compile` | `CompileOptions?` | Compiler options when `chunk` is Luau source. |
| `decoder` | `BytecodeDecoder?` | Custom opcode decoder matching `CompileOptions.encoder`. |
| `mode` | `LoadMode?` | `"text" \| "binary" \| "auto"`. |
| `timeout` | `number?` | Wall-clock deadline in seconds (`os.clock()`), started lazily on the first call. |
| `instructionLimit` | `number?` | Maximum VM instructions before aborting execution. |
| `callLimit` | `number?` | Maximum active guest call frames across nested calls and coroutines. |
| `interruptInterval` | `number?` | Instruction interval between `interrupt` and `timeout` checks (default `4,096`). |
| `interrupt` | `(() -> boolean?)?` | Periodic hook; return `false`, yield, or error to stop execution. |
| `getGlobal` | `((name: string, env: { [any]: any }) -> any)?` | Intercepts global reads across `GETGLOBAL`, unresolved `GETIMPORT`, and string keys on `_G`. |
| `setGlobal` | `((name: string, value: any, env: { [any]: any }) -> ())?` | Intercepts global writes (`SETGLOBAL` and `_G[k] = v`). |
| `safeEnv` | `boolean?` | Keeps unmodified built-in roots present in `env` on fast `FASTCALL` and `GETIMPORT` paths alongside `getGlobal`. |
| `resourceLimits` | `ResourceLimits?` | Overrides `env` allocation and pattern caps (`nil` for zero overhead). |
| `onCall` | `((info: DebugFrameInfo) -> ())?` | Fires when entering a VM closure frame. |
| `onReturn` | `((info: DebugFrameInfo) -> ())?` | Fires before returning from a VM closure frame. |
| `onLine` | `((line: number, info: DebugFrameInfo) -> ())?` | Fires when execution moves to a new source line. |
| `onBreak` | `((line: number, info: DebugFrameInfo) -> ())?` | Fires on `LOP_BREAK` instructions. |

> [!WARNING]
> Host standard-library C calls (`string.rep`, `table.create`, `buffer.create`, regex/pattern backtracking) run atomically outside `instructionLimit` and `timeout`. Enable `resourceLimits` (`maxStringLength`, `maxTableSize`, `maxBufferSize`, `maxPatternLength`) alongside instruction and time caps whenever executing untrusted code. `resourceLimits` guards stdlib constructors, pattern matching, and `CONCAT`/`NEWTABLE`/`DUPTABLE`/`SETLIST` allocations, though incremental array/dictionary growth (`t[i] = i`) and `O2` constant folding run outside it.

## Precompiled Loading, Coverage & Debugging

[`Ouro.VM`](/api/VM) also exposes direct loaders (skipping the compiler), line coverage, debugger callbacks, and closure/upvalue inspection:

```luau
local VM = Ouro.VM

-- Load binary bytecode or a ProtoModule directly without touching Ouro.Compiler
local bin = assert(Ouro.compile("local k = ...\nreturn function(n) return n + k end", {
	coverageLevel = 1,
}))
local makeAdder = assert(VM.loadBytecode(bin, {
	onLine = function(line, info)
		-- Inspect execution line by line (`onCall`, `onReturn`, `onBreak` also supported)
		local _ = `{info.source}:{line}`
	end,
}))

local addTen = makeAdder(10)
print(addTen(32)) --> 42

-- Inspect line hit counts (`coverageLevel` 1 or 2)
local cov = VM.getCoverage(makeAdder)
if cov then
	for _, entry in cov do
		print(entry.name or "<main>", "hits:", entry.totalHits)
	end
end

-- Clone a closure (sharing upvalues) into another env or read/mutate 1-based upvalues
local upvals = VM.getUpvalues(addTen)
if upvals and #upvals > 0 then
	VM.setUpvalue(addTen, 1, 20)
	print(addTen(22)) --> 42
end

local cloned = assert(VM.cloneFunction(addTen, VM.createEnvironment()))
print(VM.traceback())
```

`VM.loadProto(protoModule, options?)` instantiates closures directly from an in-memory `ProtoModule`, caching decoded templates on deeply frozen modules while snapshotting mutable ones.

See [Security & Sandbox](/guide/pipeline/security) for supported version scope, sandbox trust boundaries, and vulnerability reporting.
