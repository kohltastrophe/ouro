---
title: Overview
description: An introduction to Ouro, a self-hosted Luau 0.748 parser, compiler, and register VM in pure Luau.
outline: deep
sidebar_position: 1
---

# Overview

Ouro is a self-hosted Luau `0.748` lexer, lossless recursive-descent parser, bytecode compiler, and sandboxed register VM written in pure `--!strict` Luau. It runs in Roblox and standalone Luau without `loadstring`, FFI, or native plugins.

```luau
local Ouro = require("@ouro")

local run = assert(Ouro.load("local x = ...; return x * 2 + 2", {
	instructionLimit = 10_000,
	timeout = 0.5,
}))

print(run(20)) -- 42
```

## Architecture

Each stage works standalone or feeds the next:

- **Parse (`Ouro.parse`, `Ouro.parseExpression`, `Ouro.parseType`):** Lowers chunks, expressions, types, comments, hotcomments, and `.d.luau` declarations into flat numeric arenas with zero-based byte offsets. Enable `lossless = true` to retain a compact token and trivia tape for exact `reconstruct()` output, or `Ouro.Ast.toTables(result)` when you need conventional node tables.
- **Compile (`Ouro.compile`, `Ouro.compileResult`, `Ouro.Compiler.compileProto`):** Lowers source strings or existing `ParseResult` arenas into upstream Luau bytecode (`v14` default, `v100` for classes) across optimization levels `0`, `1`, and `2`, matching constant folding, builtin fastcalls, inlining, and loop specialization.
- **Bytecode Codec (`Ouro.Bytecode`):** Disassembles, verifies, hashes, serializes, and decodes binary bytecode (`v3`–`v14` and `v100`) or `ProtoModule` IR, with pluggable opcode `encoder` and `decoder` hooks.
- **Execute (`Ouro.load`, `Ouro.VM`):** Runs compiled bytecode or raw Luau source inside an isolated register VM with dual `@native` fast and guarded loops, pure standard libraries (`inheritHost = false` by default), instruction/call/time/allocation caps, global interception hooks, and line coverage or debugger callbacks.

## Lazy Submodule Loading

Requiring the root Ouro module only loads types and a thin lazy facade (`PUBLIC_LOADERS`). Submodules (`Ast`, `Profiles`, `Tokens`, `Kinds`, `Compiler`, `Bytecode`, and `VM`) load on first property access and cache on the package table.

> [!NOTE]
> When cloning Ouro's `ModuleScript` in Roblox Studio, keep the cloned instance parented until every needed submodule has been accessed. Because `VM` loads its helpers eagerly on first access, you can safely destroy a cloned package once `Ouro.VM` has loaded if you execute precompiled bytecode.

## Scope & Conformance

Differential runners verify lexer, parser, compiler, and VM parity against pinned upstream C++ `0.748` across targeted, upstream, conformance, and seeded fuzz suites. Type inference, incremental reparsing, and native machine code generation are outside this package.

Read [Getting Started](/guide/introduction/getting-started) to install Ouro and run your first sandboxed chunk.
