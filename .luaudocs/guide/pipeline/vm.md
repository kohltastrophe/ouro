---
title: Sandboxed VM
description: Execute source or binary Luau bytecode in isolated environments with execution budgets and hooks.
outline: deep
sidebar_position: 3
---

# Sandboxed VM

[`Ouro.load`](/api/Ouro#load) runs raw source strings, binary bytecode (`string` or `buffer`), or a `ProtoModule` inside an isolated pure-Luau register VM. It supports bytecode versions `3` through `14` and returns `(fn, nil)` on success or `(nil, errorMessage)` on compile or verification errors (experimental `v100` class bytecode is rejected cleanly). Invalid argument types, unknown option keys, bad ranges, or `mode = "text"` with a `buffer` or `ProtoModule` throw immediately.

```luau
Ouro.load(
	chunk: string | buffer | ProtoModule,
	options: LoadOptions?
): (((...any) -> ...any)?, string?)
```

By default, `mode` treats `string` chunks as `"text"` rather than sniffing binary headers and treats `buffer` inputs as `"binary"`. Pass `mode = "binary"` to execute binary bytecode stored in a string, or `mode = "auto"` to detect bytecode headers automatically. Unnamed text chunks derive debug names from their source (`[string "..."]`), while binary inputs and `ProtoModule` tables default to `"=chunk"`.

When `options.env` is omitted, every `Ouro.load` call creates a fresh isolated `VM.createEnvironment()` table and never inherits an outer thread's globals. The VM also enforces default recursion and stack limits (`20,000` active call frames and `1,000,000` active stack slots) even when `callLimit` is unset.

## Lower-Level VM Helpers

All helpers live on [`Ouro.VM`](/api/VM):

- **Direct loading:** `VM.loadBytecode(bytecode, options?)` loads binary bytecode without pulling in `Compiler`, and `VM.loadProto(protoModule, options?)` instantiates closures directly from a `ProtoModule` (caching decoded templates on deeply frozen modules while snapshotting mutable ones).
- **Isolated environments:** `VM.createEnvironment(overrides?, options?)` constructs a clean standard-library table with guest-aware `debug.traceback`/`info`, `collectgarbage("count" | "collect")`, isolated per-environment 64-bit PCG32 `math.random` state (keeping `math.*` fastcalls intact), and locked metatables. `VM.sandbox(baseEnv?, overrides?)` builds a writable per-chunk overlay backed read-only by `baseEnv`.
- **Execution control & inspection:** `VM.resetBudget(fn)` resets instruction counts and clears the lazy `timeout` timer, `VM.traceback` formats guest stack traces, `VM.getCoverage(fn)` returns per-line hit counts (`coverageLevel` `1` or `2`), `VM.cloneFunction(fn, newEnv?, loadOptions?)` shares upvalues safely across cloned closures, and `VM.getUpvalues` / `VM.setUpvalue` inspect or update 1-based upvalue slots.

## Environments (`EnvironmentOptions`)

| Field | Type | Default / behavior |
| :--- | :--- | :--- |
| `inheritHost` | `boolean?` | `false`. Enables non-standard host or Roblox globals (`script` and `loadstring` stay omitted; `_G`, `getfenv`, `setfenv`, `debug`, `error`, and `xpcall` remain sandboxed). |
| `libraries` | `{ string }?` | `nil` (all libraries). Allowlist any subset of `"base"`, `"bit32"`, `"buffer"`, `"coroutine"`, `"debug"`, `"math"`, `"os"`, `"string"`, `"table"`, `"utf8"`, `"vector"`. |
| `readOnly` | `boolean?` | `false`. Returns a flat frozen table when `inheritHost = false`, or a locked read-only proxy when `inheritHost = true`. |
| `resourceLimits` | `ResourceLimits?` | Optional caps (`maxStringLength`, `maxTableSize`, `maxBufferSize`, `maxPatternLength`) attached with zero overhead when omitted. |

> [!NOTE]
> Inside VM environments on both hosts, `getmetatable("")` returns `"The metatable is locked"`. Because host Luau shares a single metatable across all strings, method calls such as `("abc"):upper()` still resolve through host string methods even if `"string"` is omitted from `libraries`.

## Execution Guards & Hooks {#execution-guards}

`LoadOptions` configures resource limits, global interception, and debugging without slowing down unguarded VM loops:

| Field | Type | Behavior |
| :--- | :--- | :--- |
| `name` | `string?` | Chunk name in stack traces and errors. |
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

Same-context `pcall` and `xpcall` cannot catch aborts from `instructionLimit`, `timeout`, or `interrupt`.

> [!WARNING]
> Host standard-library C calls (`string.rep`, `table.create`, `buffer.create`, regex/pattern backtracking) execute atomically outside `instructionLimit` and `timeout`. Enable `resourceLimits` (`maxStringLength`, `maxTableSize`, `maxBufferSize`, `maxPatternLength`) alongside instruction and time caps whenever executing untrusted code. `resourceLimits` guards stdlib constructors, pattern matching, and `CONCAT`/`NEWTABLE`/`DUPTABLE`/`SETLIST` allocations, though incremental array/dictionary growth (`t[i] = i`) and `O2` constant folding run outside it.
