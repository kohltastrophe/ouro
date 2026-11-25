---
title: Compiling & Bytecode
description: Lower ASTs to O0–O2 Luau bytecode and inspect, verify, serialize, or decode bytecode payloads.
outline: deep
sidebar_position: 2
---

# Compiling & Bytecode

[`Ouro.compile`](/api/Ouro#compile) accepts either a Luau source string or an existing `ParseResult` and emits binary Luau bytecode (`v14` default, or `v100` for classes), returning `(bytecode, nil)` on success or `(nil, errorMessage)` on parse or compile failure.

[`Ouro.compileResult`](/api/Ouro#compileresult) returns a structured `CompileResult` containing `status` (`"ok" | "parseError" | "compileError"`), `bytecode` (`\0`-prefixed wire error on failure, readable with `Ouro.Bytecode.decodeError`), `builder`, `error`, `diagnostics`, and `parseResult`. Call `assert(result.builder):toProtoModule()` to inspect IR directly, or call [`Ouro.Compiler.compileProto`](/api/Compiler#compileproto) to skip binary serialization altogether. Passing an existing `ParseResult` skips reparsing and leaves its `arena` and `lineStarts` untouched, even when frozen.

> [!NOTE]
> `ProtoModule` IR always uses unencoded canonical opcodes. `CompileOptions.encoder` only applies during binary bytecode serialization (`Ouro.compile` and `Ouro.compileResult(...).bytecode`), so `Ouro.Compiler.compileProto` rejects `encoder`.

## Compile Options

| Option | Default / behavior |
| :--- | :--- |
| `optimizationLevel` | `1` (`0` = unoptimized, `1` = constant folding, fastcalls, and upvalues, `2` = inlining and loop unrolling). |
| `debugLevel` | `1` (`0` = stripped, `1` = line info and function names, `2` = local and upvalue debug tables). |
| `typeInfoLevel` | `0` (`0` = user-annotated functions only, `1` = emit type info for all functions). |
| `coverageLevel` | `0` (`0` = disabled, `1` = statements, `2` = statements and expressions). |
| `vectorLib` / `vectorCtor` / `vectorType` | Optional vector constructor lowering (for example `"Vector3"`, `"new"`, `"Vector3"`). |
| `vectorPrecision` | `0` (`0` = 32-bit float vectors, `1` = 64-bit doubles). |
| `mutableGlobals` | Optional `{ string }` list excluded from immutable builtin optimization. |
| `userdataTypes` | Optional `{ string }` list of host userdata type names for type info. |
| `librariesWithKnownMembers` | Optional `{ string }` libraries eligible for compile-time member callbacks. |
| `libraryMemberTypeCb` | Optional `(library: string, member: string) -> number` returning `Ouro.Bytecode.Types` tags (`0..255`). |
| `libraryMemberConstantCb` | Optional `(library: string, member: string) -> CompileConstant?` constant folder. |
| `disabledBuiltins` | Optional `{ string }` builtin names or wildcards (`"math.*"`, `"*"`) excluded from fastcalls. |
| `encoder` | Optional `BytecodeEncoder` (`(opcode: number) -> number` or `{ encode: (self, code) -> () }`). |
| `dumpFlags` | Bitmask of `Ouro.Bytecode.DumpFlags` for disassembly and remarks on `CompileResult.builder`. |
| `flags` | Optional compiler overrides matching `Ouro.Compiler.CompilerFlags`. |
| `parseOptions` | Optional `ParseOptions` forwarded when compiling source text. |

## Bytecode Codec & Disassembly

[`Ouro.Bytecode`](/api/Bytecode) exposes standalone disassembly, serialization, verification, and instruction-word helpers without requiring the compiler:

- **Disassembly & Inspection:** `disassemble(input, dumpFlags?, source?, decoder?)` (defaults to `DumpFlags.Code`; throws on corrupt bytecode), `decodeLineInfo(proto)`, `encodeError(message)`, and `decodeError(bytecode)`.
- **Codec & Verification:** `deserialize(bytecode, decoder?)` parses `v3`–`v14` and `v100` bytecode into an immutable `ProtoModule` (`kTypes`, `kValues`, `lineData`), `serialize(protoModule, encoder?)` re-encodes binary bytecode (`cost = 0`, empty feedback vector), and `verify(input, decoder?)` validates bounds, jumps, captures, and constants statically without instantiating closures.
- **Bit Helpers & Tables:** `getStringHash`, `getImportId`, `decomposeImportId`, `insnOp`, `insnA`, `insnB`, `insnC`, `insnD`, `insnE`, plus constant tables `Opcodes`, `opcodeNames`, `opLengths`, `Builtins`, `builtinNames`, `Tags`, `Types`, `Captures`, `ProtoFlags`, `FeedbackTypes`, and `DumpFlags`.

When using a custom `CompileOptions.encoder`, pass the matching `decoder` (`(opcode: number) -> number` or `{ decode: (self, code) -> () }`) to `deserialize`, `verify`, `disassemble`, or `Ouro.load`.
