# API Reference

Ouro is written in pure `--!strict` Luau and exports a single frozen package table from `init.luau` (standalone) or `src/init.luau` (Rojo `ModuleScript`).

## Entrypoints & Lazy Loading

Requiring the root module loads types and a thin lazy facade. Submodules (`Ast`, `Profiles`, `Tokens`, `Kinds`, `Compiler`, `Bytecode`, and `VM`) plus internal parser helpers load on first access and are cached per package table.

| Member | Kind | Summary |
| :--- | :--- | :--- |
| `Ouro.parse(source, options?)` | Function | Parses a complete chunk into a `ParseResult`. |
| `Ouro.parseExpression(source, options?)` | Function | Parses a standalone expression (accepts a prefix unless `requireEOF = true`). |
| `Ouro.parseType(source, options?)` | Function | Parses a standalone type annotation (accepts a prefix unless `requireEOF = true`). |
| `Ouro.newContext(options?)` | Function | Creates a reusable `ParserContext` that recycles internal scratch tables. |
| `Ouro.compile(sourceOrParseResult, options?)` | Function | Compiles source or a `ParseResult` and returns `(bytecode, nil)` or `(nil, errorMessage)`. |
| `Ouro.compileResult(sourceOrParseResult, options?)` | Function | Compiles source or a `ParseResult` and returns a structured `CompileResult`. |
| `Ouro.load(chunk, options?)` | Function | Compiles or deserializes Luau source, bytecode, or a `ProtoModule` into a VM closure. |
| `Ouro.Ast` | Namespace | Lazy module exposing lossless `Ast.toTables(result)`. |
| `Ouro.Profiles` | Namespace | Lazy module exposing `Profiles.named` and `Profiles.resolve(nameOrTable?)`. |
| `Ouro.Tokens` | Table | Lazy immutable map of token names (such as `Eof` and `ReservedFunction`) to numeric token kinds. |
| `Ouro.Kinds` | Table | Strictly typed immutable map (`typeof(Arena.Kinds)`) from upstream AST node names to numeric node tags. |
| `Ouro.Compiler` | Namespace | Direct compiler module (`compile`, `compileResult`, `compileProto`, `CompilerFlags`). |
| `Ouro.Bytecode` | Namespace | Standalone disassembler (`disassemble`), serializer/deserializer (`serialize`, `deserialize`, `decodeLineInfo`), verifier (`verify`), codec helpers (`encodeError`, `decodeError`, `decomposeImportId`, `insnOp`–`insnE`), constant tables, and `DumpFlags`. |
| `Ouro.VM` | Namespace | Isolated register VM (`load`, `loadBytecode`, `loadProto`, `createEnvironment`, `sandbox`, `traceback`, `getCoverage`, `cloneFunction`, `getUpvalues`, `setUpvalue`, `resetBudget`). |
| `Ouro.version` | `string` | Package semantic version (`"0.1.0"`). |
| `Ouro.luauVersion` | `string` | Pinned upstream Luau release string (`"0.748"`). |
| `Ouro.upstreamRevision` | `string` | Pinned upstream Luau Git commit SHA from `UPSTREAM.json`. |

All public entrypoints validate argument types, option table keys, and option value ranges strictly. Invalid option keys, malformed option types, non-string parser sources, bad `encoder` or `decoder` callbacks, invalid `mode` selections (`mode = "text"` on a `buffer` or `ProtoModule`), and invalid traversal callbacks throw immediately. Source syntax errors, compile failures, corrupt binary bytecode (except in `Bytecode.disassemble`), and malformed `ProtoModule` table contents still return `(nil, errorMessage)`, `(false, errorMessage)`, or an error `status`.

> [!NOTE]
> When cloning the package `ModuleScript` in Roblox Studio, keep the cloned instance parented until every needed lazy submodule has been accessed. Because `src/VM/` loads its internal modules (including `HostEnv`) eagerly during `require`, destroying the cloned package after requiring `Ouro.VM` remains safe for precompiled bytecode.

## Parsing

`Ouro.parse(source: string, options: ParseOptions?): ParseResult` consumes a complete chunk and requires EOF. `Ouro.parseExpression` and `Ouro.parseType` follow the official Luau fragment APIs and accept a leading prefix by default; pass `requireEOF = true` when the entire input must match. Calling any parse entrypoint with a non-string source throws a validation error.

`Ouro.newContext(options: ParseOptions?): ParserContext` creates a stateful wrapper with `:parse(source)`, `:parseExpression(source)`, `:parseType(source)`, `:reset()`, and a `busy` boolean. A context reuses private scope, symbol, and recovery scratch tables across calls. Published `ParseResult` arenas are never recycled, and scratch capacity from inputs larger than 256 KiB (`262,144` bytes) is discarded on completion so one large file does not pin heap memory.

A context rejects overlapping or reentrant use while active. Independent contexts can interleave concurrently through yielding checkpoint callbacks.

## Parse Options & Profiles

`ParseOptions` configures grammar flags, limits, lossless capture, and cooperative yielding:

| Option | Default / behavior |
| :--- | :--- |
| `profile` | `"upstream"` (pinned C++ flag defaults), `"studio"`, `"experimental"`, or a custom `GrammarFlags` table. |
| `lossless` | `false`. When `true`, retains dense token and trivia span arrays for exact source reconstruction. |
| `captureComments` | Enabled automatically by `lossless = true`, otherwise `false` (explicit override supported). |
| `allowDeclarationSyntax` | `false`. Enables `.d.luau` `declare` syntax. |
| `requireEOF` | `false` for expression and type fragment entrypoints (chunks always require EOF). |
| `recursionLimit` | `1,000` nested parser frames. |
| `typeLengthLimit` | `1,000` items in a type list or union/intersection chain. |
| `errorLimit` | `100` reported diagnostics before aborting with `"limit"`. |
| `noErrorLimit` | `false`. Disables `errorLimit` when `true`. |
| `checkpointInterval` | `4,096` scanned bytes per lexer checkpoint (the parser also checkpoints every 256 token advances). |
| `checkpoint` | Optional `(offset: number) -> boolean?` callback. Return `false` to cancel or yield to suspend. |

Unknown `ParseOptions` keys (such as internal lexer options or compiler flags) throw a validation error.

### Named Profiles

The profile definitions live in `src/Profiles.luau`:

| Profile | Behavior |
| :--- | :--- |
| `upstream` | Uses the pinned official C++ parser boolean defaults from `UPSTREAM.json`. |
| `studio` | Enables the shipping Studio grammar flags (`LuauSolverV2`, `LuauSingleTypeOptionalPackReturnsAttributeParens`, and `LuauAllowGlobalDeclarationToBeCalledClass`) verified with native syntax probes on Studio `0.748.0.7481526`. |
| `experimental` | Enables every ported boolean grammar flag in `src/Grammar.luau`. Does not imply Studio support. |

Passing a custom `GrammarFlags` table validates every key against known grammar flags at runtime, checks boolean types, copies onto upstream defaults, and freezes the resolved table when configuring a parse or `ParserContext`.

### Lossless Tape & Checkpoints

When `lossless = true`, the lexer records a compact parallel tape (`kinds`, `starts`, `finishes`, `count`) referencing slices of the original `source` string instead of allocating a parallel CST. Calling `result:reconstruct()` asserts contiguous coverage with no gaps or overlaps and reproduces exact input bytes, including malformed code. If a parse halts on a limit or cancellation, the tape appends a `Token.Unparsed` sentinel covering the remaining tail, and `lineStarts` indexing past an early stop completes lazily on demand.

Checkpoint callbacks run inside the active parser or lexer context, including inside long string and comment scans. A callback may yield its coroutine so a Studio plugin can inspect document revisions and budget frame time, provided it never reenters the same `ParserContext`.

## Parse Results & Arena Storage

`ParseResult.status` is one of `"ok"`, `"syntaxError"`, `"limit"`, or `"cancelled"`:

- `"ok"`: Parsing succeeded with zero diagnostics.
- `"syntaxError"`: Recoverable syntax errors produced diagnostics; `result.root` points to an error-containing AST. Never treat a recovered tree as validated code.
- `"limit"` or `"cancelled"`: Fatal abort; `result.root` is `0`.

Application errors, invalid argument types, and exceptions raised by a checkpoint callback propagate directly to the caller.

Every `ParseResult` owns its original `source`, `arena`, `lineStarts`, `comments`, `hotcomments`, `tape` (when lossless), `diagnostics`, `profile`, and `flags`. Node, list, symbol, and binding IDs are integer indices local to that result (`0` means absent), not persistent document identities.

### Arena & AST Access

The arena stores tagged fixed-shape node records, parallel structure-of-arrays (SoA) node metadata (`kinds`, `starts`, `finishes`), module-level flags (`hasTypeAnnotations`, `hasClasses`), integer references, and dense flat child-list arrays (`listFirsts`, `listCounts`, `listValues`). Treat exposed arena tables as read-only:

- `result:kind(nodeId)`: Returns the numeric node kind tag (`0` if invalid/absent). Compare against `Ouro.Kinds`.
- `result:kindName(nodeId)`: Returns the upstream node name (for example `"AstStatBlock"`).
- `result:range(nodeId)`: Returns `(start, finish)` byte offsets.
- `result:childCount(nodeId)` / `result:childAt(nodeId, index)`: Traverse child nodes in schema order without allocating tables.
- `result:forEachChild(nodeId, callback)`: Iterates direct child `NodeId` values in schema order without allocating tables. Stops early if `callback(childId)` returns `false`, and throws on invalid node IDs or non-function callbacks.
- `result:visit(visitor)`: Walks the AST depth-first from `result.root` without allocating per-node tables. Accepts either a callback `(nodeId: NodeId, kind: number, depth: number) -> boolean?` or an `AstVisitor` table (`{ enter?: (nodeId, kind, depth) -> boolean?, leave?: (nodeId, kind, depth) -> () }`), throwing on unknown visitor keys or non-function callbacks. Returning `false` from `enter` (or the function shorthand) skips descending into that node's children while still calling `leave` when provided.

Binding records in `result.arena.bindings` preserve `name` (symbol ID), `start`, `finish`, `annotation`, `shadow` (prior shadowed `BindingId`), `functionDepth`, `loopDepth`, `scopeDepth`, `isConst`, and `isExported`.

Calling `Ouro.Ast.toTables(result)` validates `result` (throwing on non-`ParseResult` tables or non-tables) and returns `AstTable?` (`nil` when `result.root == 0`). Each materialized node carries `type` set to its arena kind name, zero-based `start` and `finish` byte offsets (plus binding and qualifier offsets), and preserved AST metadata (`access`, `args`, `isConst`, `isExported`, `typeArguments`, `hasParameterList`, `upvalue`, `privateAccess`, `parseResult`). Absent unnamed entries in `argNames` or `paramNames` are stored as `false`.

### Byte Offsets & Lines

All spans and diagnostics use zero-based, half-open (`[start, finish)`) byte offsets, not UTF-8 codepoint indices.

- `result:position(offset)` returns zero-based `(line, column)` byte coordinates.
- `result:offset(line, column)` converts zero-based `(line, column)` back to a byte offset.

Only LF (`\n`) advances line numbers; standalone CR (`\r`) does not. Raw source spans preserve original bytes separately from decoded long-string newline normalization.

## Compilation

`Ouro.compile` compiles source or a `ParseResult` (`LBC_VERSION_TARGET = 14`, or `v100` when emitting classes) and returns a `(bytecode, nil)` tuple on success or `(nil, errorMessage)` on parse or compile failure.

```luau
Ouro.compile(
	sourceOrParseResult: string | ParseResult,
	options: CompileOptions?
): (string?, string?)
```

`Ouro.compileResult` accepts the same arguments and returns a structured `CompileResult` containing `status` (`"ok" | "parseError" | "compileError"`), `bytecode` (prefixing `\0` on failure for wire interop, readable via `Ouro.Bytecode.decodeError`), `builder`, `error`, `diagnostics`, and `parseResult`. Call `assert(result.builder):toProtoModule()` to obtain a `ProtoModule` directly from a builder result. Passing an existing `ParseResult` skips reparsing and leaves `parseResult.arena` and `parseResult.lineStarts` unmodified, including frozen results. `Ouro.Compiler.compileProto` skips binary serialization and returns `(protoModule, nil)` or `(nil, err)` directly. Invalid `CompileOptions` keys, invalid option types or ranges, invalid compiler flags, invalid input types, and bad `encoder` values throw validation errors.

> [!NOTE]
> `ProtoModule` IR always uses unencoded canonical opcodes. `CompileOptions.encoder` applies only when serializing binary bytecode (`Ouro.compile` and `Ouro.compileResult(...).bytecode`); `Ouro.Compiler.compileProto` rejects `CompileOptions.encoder`.

| Compile option | Default / behavior |
| :--- | :--- |
| `optimizationLevel` | `1` (`0` = unoptimized, `1` = baseline constant folding, fastcalls, and upvalues, `2` = inlining and loop specialization). |
| `debugLevel` | `1` (`0` = stripped, `1` = line info and function names, `2` = local and upvalue debug tables). |
| `typeInfoLevel` | `0` (`0` = user-annotated functions only, `1` = emit type info for all functions). |
| `coverageLevel` | `0` (`0` = disabled, `1` = statements, `2` = statements and expressions). |
| `vectorLib` / `vectorCtor` / `vectorType` | Optional vector constructor lowering (for example `"Vector3"`, `"new"`, `"Vector3"`). |
| `vectorPrecision` | `0` (`0` = 32-bit float vectors, `1` = 64-bit double-precision vectors). |
| `mutableGlobals` | Optional `{ string }` list of globals excluded from immutable builtin assumptions. |
| `userdataTypes` | Optional `{ string }` list of known userdata type names for type-info emission. |
| `librariesWithKnownMembers` | Optional `{ string }` library names eligible for compile-time member callbacks. |
| `libraryMemberTypeCb` | Optional `(library: string, member: string) -> number` callback returning integer `Ouro.Bytecode.Types` tags (`0..255`). |
| `libraryMemberConstantCb` | Optional `(library: string, member: string) -> CompileConstant?` callback using the string-tagged union (`"nil"`, `"boolean"`, `"number"`, `"vectorf"`, `"vectord"`, `"string"`, `"table"`). |
| `disabledBuiltins` | Optional `{ string }` builtin names (or wildcards like `"math.*"` / `"*"`) to lower through normal global/table calls instead of fastcalls. |
| `encoder` | Optional `BytecodeEncoder` (`(opcode: number) -> number` or `{ encode: (self: any, code: { number }) -> () }`) used during binary serialization. |
| `dumpFlags` | Bitmask of `Ouro.Bytecode.DumpFlags` values for disassembly dumps and compiler remarks on `compileResult`. |
| `flags` | Optional compiler flag overrides matching `Ouro.Compiler.CompilerFlags` (matches upstream `0.748` defaults; rejects non-compiler or unknown flags). |
| `parseOptions` | Optional `ParseOptions` forwarded when parsing string input. |

## Bytecode Codec & Disassembly

`Ouro.Bytecode` exports standalone disassembly, binary serialization/decoding, hashing, instruction decoders, and bytecode constants:

- Functions: `disassemble(input: string | buffer | ProtoModule, dumpFlags?: number, source?: string, decoder?: BytecodeDecoder): string` (defaults `dumpFlags` to `DumpFlags.Code`), `deserialize(bytecode: string | buffer, decoder?: BytecodeDecoder): (ProtoModule?, string?)`, `serialize(protoModule: ProtoModule, encoder?: BytecodeEncoder): (string?, string?)`, `verify(input: string | buffer | ProtoModule, decoder?: BytecodeDecoder): (boolean, string?)`, `decodeLineInfo(proto: Proto): ({ number }?, { number }?)`, `encodeError(message)`, `decodeError(bytecode)`, `getStringHash(str)`, `getImportId(id0, id1?, id2?)`, `decomposeImportId(ids) -> (count, id0, id1, id2)`, `insnOp(insn)`, `insnA(insn)`, `insnB(insn)`, `insnC(insn)`, `insnD(insn)`, and `insnE(insn)`.
- Constant tables: `Opcodes`, `opcodeNames`, `opLengths`, `Builtins`, `builtinNames`, `Tags`, `Types`, `Captures`, `ProtoFlags`, and `FeedbackTypes`.
- Dump flags (`DumpFlags`): `Code`, `Lines`, `Source`, `Locals`, `Remarks`, `Types`, and `Constants`.

`BytecodeBuilder` instances (returned by `Ouro.compileResult(...).builder`) provide `:getBytecode()`, `:toProtoModule()`, `:setDumpSource(source)`, `:dumpFunction(fid)`, `:dumpEverything()`, `:dumpSourceRemarks()`, and `:dumpTypeInfo()`. `Bytecode.disassemble` validates arguments strictly and throws on invalid inputs or corrupt bytecode. `Bytecode.encodeError` and `Bytecode.decodeLineInfo` also validate arguments and throw on invalid types.

`deserialize` checks binary bytecode (`v3`–`v14` and `v100`) and builds an immutable `ProtoModule` with flat constants (`kTypes`, `kValues`) and compact `lineData`. Call `decodeLineInfo(proto)` to unpack line arrays on demand, and pass `decodeError(bytecode)` to read status-zero error strings. `deserialize` returns `(nil, errorMessage)` on invalid or status-zero payloads. `serialize` encodes a `ProtoModule` back into binary bytecode (`v3`–`v14` or `v100`) with an optional `encoder`, writing `cost = 0` and an empty feedback vector because `ProtoModule` omits per-proto feedback vectors. `verify` validates binary bytecode or a `ProtoModule` statically without instantiating a closure, returning `(true, nil)` or `(false, errorMessage)` while throwing on invalid `decoder` arguments. Pass `decoder` (`(opcode: number) -> number` or `{ decode: (self: any, code: { number }) -> () }`) to reverse a custom `CompileOptions.encoder` mapping.

## Register VM

`Ouro.load` accepts raw Luau source, binary bytecode (`string` or `buffer`), or a decoded `ProtoModule` plus an optional `LoadOptions` table. It returns `(fn, nil)` on success or `(nil, errorMessage)` on compilation or verification failure. Versions `3` through `14` are supported, and experimental class bytecode (`v100`) returns an error tuple. Invalid chunk types, unknown `LoadOptions` keys, invalid option types or ranges, bad `decoder` values, and `mode = "text"` with a `buffer` or `ProtoModule` throw validation errors.

```luau
Ouro.load(
	chunk: string | buffer | ProtoModule,
	options: LoadOptions?
): (((...any) -> ...any)?, string?)
```

By default, `options.mode` treats `string` inputs as `"text"` (compiling Luau source rather than sniffing binary bytecode) and `buffer` inputs as `"binary"`. Pass `mode = "binary"` to load binary bytecode stored in a `string`, or `mode = "auto"` to opt into header sniffing. `ProtoModule` tables always route through `loadProto`. When `options.name` is omitted, text source chunks format compile and runtime traces from the chunk source (`[string "..."]`), while binary bytecode and `ProtoModule` inputs default to `"=chunk"`.

When `options.env` is omitted, `Ouro.load` always creates a fresh isolated `VM.createEnvironment()` table and never implicitly inherits an outer VM thread environment. Host `loadstring` wrappers that want thread-environment inheritance must pass `env` explicitly (for example `env.getfenv(0)`). The VM also enforces default recursion and stack caps (`LUAI_MAXCALLS = 20,000` active frames and `1,000,000` active stack slots) even when `callLimit` is omitted.

Lower-level `Ouro.VM` exports:

- `VM.loadBytecode(bytecode: string | buffer, options: LoadOptions?)`: Bounds-checks and loads binary bytecode directly without requiring `Compiler`.
- `VM.loadProto(protoModule: ProtoModule, options: LoadOptions?)`: Validates operands and instantiates a closure from a `ProtoModule`, caching templates when deeply frozen and snapshotting mutable modules on load.
- `VM.createEnvironment(overrides?: { [any]: any }?, options: EnvironmentOptions?)`: Builds a fresh standard-library table with a guest-aware `debug` library (`traceback` and `info`), `collectgarbage("count" | "collect")`, and an isolated per-environment 64-bit PCG32 `math.random`/`math.randomseed` state (while preserving `math.*` fastcalls). Writable environments use a locked metatable (`__metatable = "locked"`). Setting `readOnly = true` returns a flat frozen table when `inheritHost = false`, or a locked proxy (`__metatable = "locked"`) when `inheritHost = true`. By default (`inheritHost = false`), only pure Luau standard libraries are exposed and host/Roblox globals never leak.
- `VM.sandbox(baseEnv?: { [any]: any }?, overrides?: { [any]: any }?)`: Creates a writable per-chunk overlay table with a locked metatable backed read-only by `baseEnv` (or pure standard libraries when omitted) and gives the overlay its own isolated `math.random`/`math.randomseed` state (unless overridden) while preserving fast paths for unmodified built-in roots present in the chain.
- `VM.resetBudget(fn): boolean`: Resets the instruction count and clears the `timeout` clock for the `ModuleContext` owning `fn` so `timeout` restarts lazily on the next call (returns `false` for non-VM functions).
- `VM.traceback(threadOrMsg?, message?, level?)`: Formats guest stack traces for host inspection.
- `VM.getCoverage(fn): { CoverageEntry }?`: Returns per-proto line hit counts when compiled with `coverageLevel` `1` or `2` (or `nil` for non-VM functions).
- `VM.cloneFunction(fn, newEnv?: { [any]: any }?, loadOptions: LoadOptions?)`: Clones a VM closure with shared upvalue references and optional `newEnv` / `loadOptions`. When `loadOptions` is omitted, clones inherit the source closure's limits and hooks with a fresh budget counter; passing `loadOptions` validates options strictly and applies overrides such as `name`. Returns `nil` on non-VM functions.
- `VM.getUpvalues(fn): { UpvalueInfo }?` / `VM.setUpvalue(fn, index: number, value: any): boolean`: Inspects and updates open or closed upvalues (`1`-based).

### Environments (`EnvironmentOptions`)

`EnvironmentOptions` configures `VM.createEnvironment(overrides?, options?)`:

| Field | Type | Default / behavior |
| :--- | :--- | :--- |
| `inheritHost` | `boolean?` | `false`. Set to `true` to inherit non-standard host or Roblox globals (excluding `script` and `loadstring`; wrapped `_G`, `getfenv`, `setfenv`, `debug`, `error`, and `xpcall` remain sandboxed). |
| `libraries` | `{ string }?` | `nil` (all libraries). Allowlist any subset of `"base"`, `"bit32"`, `"buffer"`, `"coroutine"`, `"debug"`, `"math"`, `"os"`, `"string"`, `"table"`, `"utf8"`, `"vector"`. |
| `readOnly` | `boolean?` | `false`. Returns a flat frozen table when `inheritHost = false` (or a locked read-only proxy when `inheritHost = true`) for shared `VM.sandbox` bases. |
| `resourceLimits` | `ResourceLimits?` | Optional opt-in caps (`maxStringLength`, `maxTableSize`, `maxBufferSize`, `maxPatternLength`) attached to the environment with zero overhead when omitted. |

> [!NOTE]
> Inside VM environments on both hosts, `getmetatable("")` returns `"The metatable is locked"`. In Luau, all strings share one host string metatable, so method calls such as `("abc"):upper()` still resolve through host `string` methods even when `"string"` is omitted from `libraries`.

### Execution Guards, Environment Hooks & Debugging (`LoadOptions`)

`LoadOptions` configures chunk loading, execution limits, global hooks, and debugging callbacks without runtime overhead when guards are absent:

| Field | Type | Behavior |
| :--- | :--- | :--- |
| `name` | `string?` | Chunk name for debug traces and errors (`[string "..."]` from source by default for text chunks; `"=chunk"` for binary bytecode and `ProtoModule`). |
| `env` | `{ [any]: any }?` | Custom global environment table (defaults to a fresh isolated `VM.createEnvironment()`). |
| `compile` | `CompileOptions?` | Compilation options used when loading text source chunks. |
| `decoder` | `BytecodeDecoder?` | Optional custom opcode decoder (`(opcode: number) -> number` or `{ decode: (self: any, code: { number }) -> () }`) applied when decoding binary bytecode. |
| `mode` | `LoadMode?` | `"text" \| "binary" \| "auto"`. Defaults to `"text"` for strings and `"binary"` for buffers. |
| `timeout` | `number?` | Wall-clock deadline in seconds (`os.clock()`), started lazily on the first invocation and checked at periodic interrupt intervals and call boundaries. |
| `instructionLimit` | `number?` | Maximum VM instructions before aborting execution. |
| `callLimit` | `number?` | Maximum active guest frames across the call stack and nested coroutines sharing a module context. |
| `interruptInterval` | `number?` | Instruction interval between `interrupt` and `timeout` checks (defaults to `4,096`). |
| `interrupt` | `(() -> boolean?)?` | Periodic callback; return `false` (or error or yield) to interrupt guest execution. |
| `getGlobal` | `((name: string, env: { [any]: any }) -> any)?` | Intercepts global lookups across `GETGLOBAL`, unresolved `GETIMPORT` paths, and string keys on `_G` (`_G.k`, `_G["k"]`). Disables built-in fast paths unless `safeEnv = true`. |
| `setGlobal` | `((name: string, value: any, env: { [any]: any }) -> ())?` | Intercepts global writes (`SETGLOBAL` and string keys via `_G[k] = v`) so hosts can transform, redirect, or reject assignments. |
| `safeEnv` | `boolean?` | Controls per-root `FASTCALL` and `GETIMPORT` optimization (`true` keeps unmodified built-in roots actually present in `env` fast alongside `getGlobal`; `false` disables all fast paths). |
| `resourceLimits` | `ResourceLimits?` | Optional opt-in caps (`maxStringLength`, `maxTableSize`, `maxBufferSize`, `maxPatternLength`) overriding any limits on `env`; runs with zero overhead when omitted. |
| `onCall` | `((info: DebugFrameInfo) -> ())?` | Fires when entering a VM closure frame. |
| `onReturn` | `((info: DebugFrameInfo) -> ())?` | Fires before returning from a VM closure frame. |
| `onLine` | `((line: number, info: DebugFrameInfo) -> ())?` | Fires when execution moves to a different source line. |
| `onBreak` | `((line: number, info: DebugFrameInfo) -> ())?` | Fires when executing a `LOP_BREAK` instruction. |

Same-context `pcall` and `xpcall` cannot catch errors raised by `instructionLimit`, `timeout`, or `interrupt` aborts.

Info table shapes returned by VM inspection hooks and helpers:

- `DebugFrameInfo`: `{ source: string, line: number, name: string?, numparams: number, isvararg: boolean, depth: number }`
- `CoverageEntry`: `{ name: string?, lineDefined: number, hits: { [number]: number }, totalHits: number }`
- `UpvalueInfo`: `{ index: number, name: string?, value: any }`

> [!NOTE]
> Host standard-library C calls (`string.rep`, `table.create`, `buffer.create`, pattern backtracking) run atomically outside `instructionLimit` and `timeout` checks. When running untrusted code, configure `resourceLimits` (`maxStringLength`, `maxTableSize`, `maxBufferSize`, `maxPatternLength`) alongside `instructionLimit` and `timeout`. `resourceLimits` guards stdlib constructors (`string.*`, `table.*`, `buffer.*`, `utf8.char`, `os.date`), pattern calls, and VM `CONCAT`/`NEWTABLE`/`DUPTABLE`/`SETLIST` allocations, though incremental key growth (`t[i] = i`) and O2 constant folding are outside it. Generalized `for-in` table iteration also delegates to host `next(t, k)` with zero wrapper allocation, so concurrent mutations across a rehash follow host Luau traversal order.

## Exported Types

`init.luau` exports all public Luau `--!strict` types at package root:

- Parser and AST: `NodeId`, `ListId`, `SymbolId`, `BindingId`, `GrammarFlags`, `ResolvedFlags`, `ParseOptions`, `Diagnostic`, `Comment`, `HotComment`, `TokenTape`, `Node`, `Binding`, `AstVisitor`, `Arena`, `ParseResult`, `AstTable`, `ParserContext`
- Compiler and Bytecode: `CompileConstant`, `ProtoTableConstant`, `ProtoClassConstant`, `Proto`, `ProtoModule`, `CompileOptions`, `CompileResult`, `BytecodeEncoder`, `BytecodeDecoder`, `BytecodeBuilder`
- VM and Sandbox: `ResourceLimits`, `EnvironmentOptions`, `DebugFrameInfo`, `CoverageEntry`, `UpvalueInfo`, `LoadMode`, `LoadOptions`
