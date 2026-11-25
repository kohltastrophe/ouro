---
title: Overview
description: An introduction to Ouro, a self-hosted Luau 0.748 parser, compiler, and sandboxed register VM in pure Luau.
outline: deep
sidebar_position: 1
---

# Overview

Ouro is a self-hosted Luau `0.748` lexer, lossless parser, bytecode compiler, and sandboxed register VM written in pure `--!strict` Luau. It runs in Roblox and standalone Luau without `loadstring`, FFI, or native plugins.

```luau
local Ouro = require("./ouro")

local run = assert(Ouro.load("local x = ...; return x * 2 + 2", {
	instructionLimit = 10_000,
	timeout = 0.5,
}))

print(run(20)) -- 42
```

## Core Principles

### 1. Pure & Portable Luau

Every stage from lexing through VM execution runs in standard `--!strict` Luau on both Roblox and standalone Luau hosts. Differential conformance suites check parser, compiler, bytecode, and VM parity against pinned upstream C++ `0.748`. Type inference, incremental reparsing, and native machine code generation stay outside this package.

### 2. Flat Arenas & Lossless Reconstruction

The parser writes syntax nodes into flat numeric Structure-of-Arrays buffers (`kinds`, `starts`, `finishes`) using zero-based half-open byte offsets, so traversing large scripts does not require building nested node tables. Opting into `lossless = true` records a compact lexical tape for exact `reconstruct()` output, and [`Ouro.newContext`](/api/Ouro#newcontext) recycles scratch buffers across parses.

### 3. Dual Fast & Guarded VM

The register VM pairs separate `@native` fast and guarded dispatch loops. Chunks without execution caps, global interception hooks, or debugger callbacks run on the unguarded loop, while guarded chunks enforce instruction, call, timeout, memory, and global controls inside isolated pure-Luau environments.

### 4. Lazy Submodule Loading

Requiring the root module loads types and a thin lazy loader facade. Heavy submodules (`Ast`, `Profiles`, `Tokens`, `Kinds`, `Compiler`, `Bytecode`, and `VM`) load on first property access and cache on the package table, keeping cold `require` fast when you only use part of the pipeline.

> [!NOTE]
> When cloning Ouro's `ModuleScript` in Roblox Studio, keep the cloned instance parented until every needed submodule has been accessed. `Ouro.VM` loads its internal helpers eagerly on first access, so destroying a cloned package after loading `Ouro.VM` stays safe for precompiled bytecode.

## Batteries Included

- **[Parsing & AST](/guide/pipeline/parsing):** Parse chunks, expressions, types, and `.d.luau` declarations via [`Ouro.parse`](/api/Ouro#parse), preserve exact bytes with `lossless = true`, traverse arenas without allocating tables, or materialize tables with [`Ouro.Ast.toTables`](/api/Ast#totables).
- **[Grammar Profiles](/guide/pipeline/parsing#profiles):** Switch between `upstream`, `studio`, and `experimental` presets or validate custom flag tables through [`Ouro.Profiles`](/api/Profiles).
- **[Bytecode Compiler](/guide/pipeline/compiling):** Lower source text or an existing `ParseResult` across `O0`–`O2` with constant folding, inlining, loop unrolling, vector constructors, and builtin fastcalls via [`Ouro.compile`](/api/Ouro#compile) and [`Ouro.Compiler`](/api/Compiler).
- **[Bytecode Codec & Verifier](/guide/pipeline/compiling#bytecode-codec-and-disassembly):** Disassemble, serialize, deserialize, hash, and statically verify `v3`–`v14` (and decode `v100`) payloads through [`Ouro.Bytecode`](/api/Bytecode).
- **[Sandboxed VM](/guide/pipeline/vm):** Execute source, binary bytecode, or `ProtoModule` IR inside isolated environments (`PCG32` per-env `math.random` state), per-chunk sandboxes, resource budgets, line coverage, and debugger hooks through [`Ouro.load`](/api/Ouro#load) and [`Ouro.VM`](/api/VM).
- **[Security & Sandbox](/guide/pipeline/security):** Harden untrusted guest scripts with layered caps, verified bytecode loading, and explicit host boundaries.
- **[Benchmarks](/guide/benchmarks):** Compare VM execution, O2 compilation, cold load time, and cold startup against Fiu and LuauCeption.

See **[Getting Started](/guide/introduction/getting-started)** to install Ouro and run your first sandboxed chunk.
