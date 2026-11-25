---
title: Security & Sandbox
description: Sandbox trust boundaries, resource caps, bytecode verification, and vulnerability reporting.
outline: deep
sidebar_position: 4
---

# Security & Sandbox

Ouro runs guest code inside a pure-Luau register VM (`v3`–`v14`) with isolated environments, execution budgets, allocation caps, and static bytecode verification.

## Hardened Sandbox Baseline

Enable allowlisted `libraries`, a `readOnly` base environment wrapped in `VM.sandbox`, instruction/call/time limits, and `resourceLimits` together whenever running untrusted guest code:

```luau
--!strict
local Ouro = require("./ouro")

local limits: Ouro.ResourceLimits = {
	maxStringLength = 65_536,
	maxTableSize = 10_000,
	maxBufferSize = 65_536,
	maxPatternLength = 256,
}

local baseEnv = Ouro.VM.createEnvironment(nil, {
	libraries = { "base", "bit32", "coroutine", "math", "string", "table", "utf8" },
	readOnly = true,
	resourceLimits = limits,
})

local guestFn, err = Ouro.load(untrustedSource, {
	name = "=untrusted",
	env = Ouro.VM.sandbox(baseEnv),
	mode = "text", -- never auto-load untrusted strings as binary unless intended
	instructionLimit = 200_000,
	callLimit = 64,
	timeout = 0.1,
	resourceLimits = limits,
})
```

Passing an explicit `mode = "text"` keeps user-submitted text from being interpreted as binary bytecode even if it starts with bytecode header bytes. If you load precompiled bytecode supplied by a caller, verify or decode it first with [`Ouro.Bytecode.verify`](/api/Bytecode#verify) and [`Ouro.VM.loadBytecode`](/api/VM#loadbytecode).

## Supported Versions

Ouro tracks pinned official Luau releases (`0.748` for `v0.1.0`). Security fixes target the latest `0.1.x` release on `main` and the runtime-only `dist` branch.

## Sandbox Boundaries

See [Sandboxed VM](/guide/pipeline/vm) for full environment and budget options. Keep these boundaries in mind when sandboxing untrusted code:

- **Environments:** [`Ouro.load`](/api/Ouro#load) creates a fresh pure-Luau standard library environment by default (`inheritHost = false`) and never inherits an outer VM or host thread environment unless you pass `options.env` explicitly.
- **String Metatable:** Inside VM environments on both hosts, `getmetatable("")` returns `"The metatable is locked"`. Because host Luau shares one string metatable across all strings, method syntax such as `("abc"):upper()` still resolves host `string` methods even if `"string"` is omitted from `libraries`.
- **Budgets & DoS Controls:** Combine `instructionLimit`, `timeout`, `callLimit`, and `resourceLimits` (`maxStringLength`, `maxTableSize`, `maxBufferSize`, `maxPatternLength`) together. Host C calls run atomically outside per-instruction limits, and incremental table growth (`t[i] = i`) and `O2` compile-time constant folding run outside `resourceLimits`. Same-context `pcall` and `xpcall` cannot catch limit or timeout aborts.
- **Bytecode Verification:** Untrusted binary bytecode (`v3`–`v14`) and `ProtoModule` tables pass static header, bounds, constant, jump, and capture checks before any closure is instantiated. Experimental class bytecode (`v100`) is rejected cleanly.

## Reporting a Vulnerability

Please open a private [GitHub Security Advisory](https://github.com/kohltastrophe/ouro/security/advisories/new) with a minimal reproducer, expected behavior, and observed impact instead of filing a public issue.
