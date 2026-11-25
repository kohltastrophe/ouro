---
title: Compiling & Bytecode
description: Lower ASTs to O0–O2 Luau bytecode and inspect, verify, serialize, or decode bytecode payloads.
outline: deep
sidebar_position: 2
---

# Compiling & Bytecode

[`Ouro.compile`](/api/Ouro#compile) lowers Luau source code or an existing `ParseResult` into binary Luau bytecode (`v14` default, or `v100` for classes) across optimization levels `0`, `1`, and `2`.

```luau
--!strict
local Ouro = require("./ouro")

local bytecode, err = Ouro.compile("local a, b = ...\nreturn a * b + 2", {
	optimizationLevel = 2,
	debugLevel = 1,
})

if bytecode then
	print(Ouro.Bytecode.disassemble(bytecode))
else
	warn(err)
end
```

## Compiling from an Arena & Inspecting IR

Use [`Ouro.compileResult`](/api/Ouro#compileresult-1) when you want structured diagnostics, compiler remarks, or access to the `BytecodeBuilder` IR (`builder:toProtoModule()`). Passing an existing `ParseResult` skips reparsing and leaves its `arena` and `lineStarts` unmodified, even if frozen:

```luau
local parsed = Ouro.parse("local x = 1 + 2\nreturn x")
local result = Ouro.compileResult(parsed, {
	optimizationLevel = 2,
	dumpFlags = Ouro.Bytecode.DumpFlags.Code + Ouro.Bytecode.DumpFlags.Remarks,
})

if result.status == "ok" and result.builder then
	print(result.builder:dumpEverything())
	local ir = result.builder:toProtoModule()
	print("Compiled protos:", #ir.protos)
else
	local wireMsg = Ouro.Bytecode.decodeError(result.bytecode)
	warn(result.error, wireMsg)
end
```

If you plan to pass compiled code straight to [`Ouro.load`](/api/Ouro#load) or `VM.loadProto` without needing binary bytes, call [`Ouro.Compiler.compileProto`](/api/Compiler#compileproto) to skip binary serialization altogether:

```luau
local protoModule, compileErr = Ouro.Compiler.compileProto("return 6 * 7", {
	optimizationLevel = 2,
})
```

> [!NOTE]
> `ProtoModule` IR always uses unencoded canonical opcodes. `CompileOptions.encoder` only applies during binary bytecode serialization (`Ouro.compile` and `Ouro.compileResult(...).bytecode`), so `Ouro.Compiler.compileProto` rejects `encoder`.

## Optimization & Host Callbacks

Configure vector constructor specialization, disabled fastcalls, compiler flags (`Ouro.Compiler.CompilerFlags`), and compile-time library member folding through `CompileOptions`:

```luau
local Bytecode = Ouro.Bytecode

local bytecode = assert(Ouro.compile("return Vector3.new(1, 2, 3), Env.ANSWER + math.sin(0)", {
	optimizationLevel = 2,
	vectorLib = "Vector3",
	vectorCtor = "new",
	vectorType = "Vector3",
	disabledBuiltins = { "math.sin" },
	librariesWithKnownMembers = { "Env" },
	libraryMemberTypeCb = function(_lib, _member)
		return Bytecode.Types.Number
	end,
	libraryMemberConstantCb = function(_lib, member)
		if member == "ANSWER" then
			return { type = "number", value = 42 }
		end
		return nil
	end,
}))
```

| Option | Default / Behavior |
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
| `libraryMemberTypeCb` | `(library: string, member: string) -> number` returning `Ouro.Bytecode.Types` tags (`0..255`). |
| `libraryMemberConstantCb` | `(library: string, member: string) -> CompileConstant?` constant folder. |
| `disabledBuiltins` | Optional `{ string }` builtin names or wildcards (`"math.*"`, `"*"`) excluded from fastcalls. |
| `encoder` | Optional `BytecodeEncoder` (`(opcode: number) -> number` or `{ encode: (self, code) -> () }`). |
| `dumpFlags` | Bitmask of `Ouro.Bytecode.DumpFlags` for disassembly and remarks on `CompileResult.builder`. |
| `flags` | Optional compiler overrides matching `Ouro.Compiler.CompilerFlags`. |
| `parseOptions` | Optional `ParseOptions` forwarded when compiling source text. |

## Bytecode Codec & Disassembly {#bytecode-codec-and-disassembly}

[`Ouro.Bytecode`](/api/Bytecode) works standalone without requiring the compiler module. Use it to verify untrusted payloads statically (`v3`–`v14`), decode and re-encode `ProtoModule` tables, disassemble listings, or apply custom opcode encoders and decoders:

```luau
local Bytecode = Ouro.Bytecode

-- Custom opcode encoding/decoding (for Roblox bytecode wire formats or obfuscation)
local function xorOpcode(op: number): number
	return bit32.bxor(op, 0x5A)
end

local encoded = assert(Ouro.compile("return 21 * 2", { encoder = xorOpcode }))

local valid, verifyErr = Bytecode.verify(encoded, xorOpcode)
assert(valid, verifyErr)

local protoModule = assert(Bytecode.deserialize(encoded, xorOpcode))
local canonical = assert(Bytecode.serialize(protoModule))
print(Bytecode.disassemble(canonical, Bytecode.DumpFlags.Code + Bytecode.DumpFlags.Constants))
```

`serialize` encodes canonical binary bytecode with `cost = 0` and empty feedback vectors (`ProtoModule` IR does not carry runtime feedback state). Note that `disassemble` throws on corrupt input, whereas `verify`, `deserialize`, and `serialize` return status tuples `(okOrValue, err)`.

For low-level inspection, `Ouro.Bytecode` also exports instruction decoders (`insnOp`, `insnA`, `insnB`, `insnC`, `insnD`, `insnE`), hash/import helpers (`getStringHash`, `getImportId`, `decomposeImportId`, `decodeLineInfo`, `encodeError`, `decodeError`), and constant tables (`Opcodes`, `opcodeNames`, `opLengths`, `Builtins`, `builtinNames`, `Tags`, `Types`, `Captures`, `ProtoFlags`, `FeedbackTypes`, and `DumpFlags`).
