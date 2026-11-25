# Shared implementation contracts

Reference: Luau 0.748, commit `3d91c9d5c280c95bfc4be63aac46012cf861d394`.
Runtime modules use relative `require("./Module")`, and entrypoints use `@self`
to address child modules on both hosts. Require the root module (`local Ouro = require("./ouro")`). Public submodules (`Ast`, `Profiles`, `Tokens`, `Kinds`, `Compiler`, `Bytecode`, `VM`) load lazily on first access. Internal helpers (`Lexer`, `Arena`, `State`, `Parser`, `RuntimeParser`, `TypeParser`, `Declarations`, `BytecodeBuilder`, `BytecodeDisassembler`) are kept decoupled from the root facade.
Keep a cloned Roblox package instance alive until needed
submodules have loaded. Only the `VM` folder loads its internal helpers eagerly during
`require(VM)`, so destroying a cloned package instance after requiring `VM` remains safe for precompiled bytecode. Source is portable `--!strict` Luau.

## Lexer (Lexer.luau)

`Lexer.new(source, options)` returns a private mutable context. `:next()` sets
`kind, start, finish, value, symbol, error` and returns the numeric kind. Initial
kind is EOF, and callers invoke `:next()` once to prime the stream. Spans are zero-based exclusive byte offsets.
`value` is the identifier string, numeric value (`nil` if malformed), or decoded string
(`nil` if invalid). `symbol` is the identifier's result-local symbol ID (`0` for punctuation).
`:lookahead()` returns `(kind, value)` without mutating public current-token fields.
The lexer never allocates transient token tables. Symbols are stored in `symbols` and `symbolMap`.
`lineStarts = { 0, ... }` tracks line offsets where each LF starts a new line.
`comments` records `{ kind, start, finish }`, and `hotcomments` records `{ header, content, start, finish }`.
When `options.lossless` is enabled, `tape` stores dense parallel arrays `kinds, starts, finishes, count`
covering the entire source (including whitespace and comments, excluding zero-width EOF), with `Token.Unparsed` for any fatal tail.
`options.checkpoint` is invoked at bounded work intervals (including inside long lexical tokens) and may return `false` to cancel via `{ parserSignal = "cancelled" }`.
There is no module-global mutable parser state.

## Arena (Arena.luau)

`Arena.new(symbols?, sourceBytes?, symbolMap?)` creates a result-local arena. Public `Arena` types expose read-only tables and inspection methods (`kind(id) -> number`, `kindName(id) -> string`, `listCount`, `listAt`, `listItems`), while internal parser and compiler helpers also use `listHasProp` and construct nodes via `:add(nodeRecord) -> NodeId` (with numeric `nodeRecord.kind` tags from `Arena.Kinds`) and `:list(values) -> ListId`.
Fields: `nodes`, parallel SoA arrays `kinds`, `starts`, and `finishes`, module flags `hasTypeAnnotations` and `hasClasses`, parallel `listFirsts` and `listCounts`, `listValues`, `bindings`, and `symbols`.
A `NodeId`, `ListId`, or `BindingId` of `0` means absent.
Binding records store `name = symbolId`, `start`, `finish`, `annotation = NodeId`, `shadow = BindingId`, `functionDepth`, `loopDepth`, `scopeDepth`, `isConst`, and `isExported`.
Every parse result owns its arena, and published nodes and lists are never reused.

## State (State.luau)

`State.new(lexer, arena, options, scratch?)` primes the lexer and initializes parser state.
Fields `kind, start, finish, value, symbol` mirror the current token alongside `previousStart` and `previousFinish`.
Methods: `:advance()`, `:peek() -> (kind, value)`, `:isName(text)`, `:consume(kind) -> boolean`,
`:expect(kind, context?)`, `:expectClose(expected, opener, begin, search?, endMatch?)`,
`:expectName(context?) -> (symbol, start, finish)`, `:symbolFor(text) -> SymbolId`,
`:report(start, finish, message, code?)`, `:node(record) -> NodeId`, `:list(values) -> ListId`,
`:mark() -> number`, `:restore(mark)`, `:bind(symbol, start, finish, annotation?, isConst?) -> BindingId`,
`:lookup(symbol) -> BindingId`, and `:enter(context?)` for recursion depth checks.
State fields include `source, arena, diagnostics, options, profile, functionDepth, loopDepth, blockDepth, vararg`.
`:report` suppresses duplicate locations and enforces the error limit via a structured signal.
`options.profile` resolves to an immutable feature flag table.

`Parser.luau` injects `state.parseType`, `state.parseTypePack`,
`state.parseGenerics`, `state.parseTypeStatement`, and `state.parseTypeParams` from `TypeParser.luau`, plus
`state.parseDeclaration` and `state.parseClass` from `Declarations.luau`.
It also injects `state.parseExpression`, `state.parseFunction`,
and `state.parseAttributes` from `RuntimeParser.luau`.

## RuntimeParser.luau

Exports `parseChunk(state) -> NodeId`, `expression(state, limit?) -> NodeId`,
`block(state, stopTokens?, scoped?) -> NodeId`,
`functionBody(state, start, isMethod?, passedGenerics?, attrs?, debugname?, localName?, keywordFinish?) -> (NodeId, BindingId)`,
`attributes(state) -> ListId`, and `parseClassReference(state) -> NodeId`.
Type statements and declarations dispatch to the injected callbacks on `state`.
Statement lists are stored as arena `ListId` values while preserving lexical scope, source spans, error recovery nodes, and semantic parser checks.

## Profiles (Profiles.luau)

`Profiles.resolve(nameOrTable?)` resolves named profiles (`upstream` for official C++ bool defaults,
`studio` for conservative shipping Studio grammar, and `experimental` with all ported grammar flags enabled) or validates and freezes a custom `GrammarFlags` table.
Pass `options.allowDeclarationSyntax = true` to enable `.d.luau` definition parsing.

## Parser.luau / result

Exports `parse`, `parseExpression`, `parseType`, and `newContext`. Non-string sources and unknown `ParseOptions` keys (including internal lexer flags or compiler flags) throw validation errors. `ParserContext:reset()` swaps fresh scratch tables and advances an active generation counter so abandoned yielded coroutines cannot corrupt subsequent parses.
`ParseResult` contains `status, root, arena, source, diagnostics, lineStarts, comments, hotcomments, tape, profile, flags`.
`status` is `"ok" | "syntaxError" | "limit" | "cancelled"`, with `root = 0` when unavailable.
Results provide `kind`, `kindName`, `range`, `childCount`, `childAt`, `forEachChild`, `visit`, `position`, `offset`, and `reconstruct` methods. `forEachChild` and `visit` traverse schema-ordered children without allocating per-node tables and throw on invalid callbacks, `AstVisitor` keys, or non-numeric node IDs.
`Ast.toTables(result)` throws on invalid inputs and returns `AstTable?` (`nil` when `root == 0`), emitting lossless upstream-named tables (`type`, numeric `start`/`finish`, all parsed metadata, and `false` for absent unnamed entries).
Diagnostics are `{ start, finish, message, code }`.

## BytecodeDefs, BytecodeBuilder, BytecodeCodec & BytecodeDisassembler

`BytecodeDefs.luau` is generated from official `Bytecode.h` and `Compiler.cpp` by `tools/generate.py` (excluding experimental `BytecodeGraph.cpp` and `Sccp.cpp`).
It exports `Opcodes`, `opcodeNames`, `opLengths`, `isJumpD`, `isFastCall`, `isSkipC`,
`Tags`, `Types`, `Builtins`, `Captures`, `ProtoFlags`,
`FeedbackTypes`, `builtinNames`, and `CompilerFlags`.
`BytecodeBuilder.luau` constructs and serializes Luau bytecode (`v14` by default, `v100` for classes) including string tables, constant pools, protos, debug info, and typeinfo. It exposes `new`, `newTableShape`, `ConstantType`, `kMaxConstantCount`, `kMaxClosureCount`, `kMaxTableShapeLength`, `getStringHash`, `getImportId`, and `DumpFlags` (`Code`, `Lines`, `Source`, `Locals`, `Remarks`, `Types`, `Constants`).
`BytecodeDisassembler.luau` exports standalone `disassemble(input, dumpFlags?, source?, decoder?)` alongside builder dump helpers for disassembly, source remarks, and typeinfo, throwing on corrupt bytecode or invalid arguments.
`BytecodeCodec.luau` exports instruction decoders (`insnOp`, `insnA`, `insnB`, `insnC`, `insnD`, `insnE`), `decomposeImportId`, `encodeError` (requires string), `decodeError`, `decodeLineInfo(proto)` (requires table), `serialize(protoModule, encoder?) -> (string?, string?)`, and `deserialize(data, decoder?) -> (ProtoModule?, string?)` producing flat `kTypes`/`kValues` constants and compact `lineData`/`linegaplog2`, validating constant references, child protos, debug indices, userdata indices, v11+/v12+ feedback/proto bounds, and EOF bounds. Because `ProtoModule` IR omits per-proto inline `cost` and feedback vectors, `serialize` encodes `cost = 0` and an empty feedback vector. `Ouro.Bytecode.verify(input, decoder?)` delegates to `VM/Verifier.verify` and throws on invalid `decoder` arguments.

## Compiler (`Compiler.luau` & compiler helper modules)

`Compiler.compile(sourceOrParseResult, compileOpts?) -> (string?, string?)`,
`Compiler.compileResult(sourceOrParseResult, compileOpts?)`, and
`Compiler.compileProto(sourceOrParseResult, compileOpts?) -> (ProtoModule?, string?)` lower parsed arenas to
Luau bytecode across optimization levels `0`, `1`, and `2`, matching official `Luau.Compiler`. Compiling an existing `ParseResult` leaves `parseResult.arena` and `lineStarts` unmodified, preserving frozen and shared parse results. `Compiler.CompilerFlags` matches official Luau `0.748` defaults (`LuauCompileCapturedCallTarget`, `LuauCompileLoopUnrollNegativeZero`, and `LuauCompileTableFoldFix` default `false`) and omits dead upstream flags. Unknown `CompileOptions` keys, invalid option types/ranges, invalid compiler flag keys/values, and non-string/non-`ParseResult` inputs throw validation errors.
Forward `ParseOptions` via `compileOpts.parseOptions` and custom binary opcode encoding via `compileOpts.encoder` (`compileProto` rejects `encoder` because `ProtoModule` IR always uses unencoded canonical opcodes).
Six helper modules keep compiler responsibilities separate:
- `CompilerBuiltins.luau` tracks mutable globals and resolves builtin fastcalls (`CompilerTypes` and `CompilerFolding` preserve `GlobalState.Default` per-global mutability checks, and `libraryMemberTypeCb` values must be integers in `0..255`).
- `CompilerClass.luau` emits class descriptors and lowers private field access.
- `CompilerExpr.luau` lowers expressions, locals, calls, and tables, enforcing exact `kMaxUpvalueCount` bounds.
- `CompilerFolding.luau` evaluates compile-time constants (`Constant`) and truthiness, cleaning scratch state via `pcall` if callbacks error.
- `CompilerInline.luau` models inlining cost and argument bindings, matching upstream Luau 0.748 loop-unroll folding and change-stack semantics inside `compileUnrolledFor`.
- `CompilerTypes.luau` encodes type info (`LBC_TYPE_*`), lowers vector constructors, and specializes typed locals using `@native` helpers, skipping annotation work when `typeInfoLevel == 0` and `arena.hasTypeAnnotations` is `false` and releasing scratch buffers on callback errors.

## VM (`VM/init.luau`, `Verifier`, `RuntimeEnv`, `Fastcalls`, `Dispatch`, `HostEnv`)

`VM.load(chunk, options?)`, `VM.loadBytecode(bytecode, options?)`,
`VM.loadProto(protoModule, options?)`, `VM.traceback(thread?, message?, level?)`, `VM.resetBudget(fn)`, and `VM.createEnvironment(overrides?, options?)`
execute Luau bytecode (`v3` through `v14`) in pure Luau and return an error tuple for experimental class bytecode (`v100`).
When `options.env` is omitted, `VM.load` always creates a fresh isolated `VM.createEnvironment()` rather than inheriting an outer VM thread environment. Unnamed text chunks format debug names from source (`[string "..."]`), while binary bytecode and `ProtoModule` inputs default to `"=chunk"`. Invalid chunk types, unknown `LoadOptions`/`EnvironmentOptions`/`ResourceLimits` keys, bad option types/ranges, and `mode = "text"` with `buffer` or `ProtoModule` throw validation errors.
`VM/Verifier.luau` validates proto headers (`upvalues` included), operand/constant types, `LOP_FASTPCALL` targets, jump targets, capture trailers, and child-proto bounds before instantiation. It freezes shared template tables, rejects `v100` classes regardless of binary vs `ProtoModule` origin, and pre-seeds `DUPTABLE` templates with power-of-2 hash seeds (`1..256` via `cloneDuptableSeed`). `VM/init.luau` caches templates only on deeply frozen `ProtoModule` inputs and snapshots mutable protos (`code`, constants, tables) on load.
`VM/RuntimeEnv.luau` builds isolated environments, tracks active guest call counts per coroutine via weak-key `activeThreads` (unwinding dead threads automatically), manages pooled call frames and synthetic C frames, computes strict per-root `safeRootsMask` fast paths, and enforces opt-in `ResourceLimits` (`maxStringLength`, `maxTableSize`, `maxBufferSize`, `maxPatternLength`) across stdlib calls, `rawget`, `next`, `xpcall`, `coroutine.create`/`wrap`, and `stepImportChain`. It formats guest stack traces (rejecting `NaN` levels in `debug.traceback`). Guest environments lock `getmetatable("")` to `"The metatable is locked"`. Writable and sandbox environments lock their own metatables (`__metatable = "locked"`), whereas `readOnly` returns a flat frozen table (`inheritHost = false`) or a locked proxy (`inheritHost = true`). It provides `collectgarbage("count" | "collect")`, gives each created environment and `VM.sandbox` overlay its own isolated 64-bit PCG32 `math.random` / `math.randomseed` state (blocking host `math` RNG leaks when `math = nil`), and enforces guest-only `getfenv`, `setfenv` (including `setfenv(0)` thread-env inheritance via `tstate.threadEnv` and non-C `xpcall` snapshot frame lookup), and `debug`.
`VM/Fastcalls.luau` executes built-in fastcalls (`LBF_GETMETATABLE` respects the locked string metatable; `LBF_RAWGET` wraps returned functions and respects `ResourceLimits`) and invalidates `safeRootsMask` when raw built-ins mutate the active environment.
`VM/Dispatch.luau` routes execution through dual `@native` loops (`runLoopFast` when `ctx.isGuarded` is `false`, `runLoopGuarded` when limits, hooks, or `ResourceLimits` are active) over predecoded parallel arrays (`ops`, `argA..argD`, `auxVal`, `fcRa`). It reuses persistent per-depth `frame.stack` tables across calls at the same depth, maintains open/closed upvalues, varargs, fast iterator prep, and `DUPTABLE` templates, enforces exact `callLimit` (`activeCalls > callLimit`) and default recursion/stack caps (`LUAI_MAXCALLS = 20,000` frames and `1,000,000` active stack slots), starts `timeout` clocks lazily on first call (`VM.resetBudget` clears `startClock`), and prevents same-context `pcall`/`xpcall` from swallowing `instructionLimit`, `timeout`, or `interrupt` aborts (and avoids duplicate `onCall` firing after recovery). Generalized `for-in` table traversal delegates directly to host `next(t, k)` while propagating `HOST_WRAPPERS` and `ResourceLimits`, so deleting and inserting keys concurrently across a table rehash follows host Luau `next` traversal order rather than upstream `LUA_TUPVAL` table-node traversal. It intercepts `setGlobal` across `SETGLOBAL`, `SETTABLE`, and `SETTABLEKS`, intercepts `getGlobal` across `GETGLOBAL`, `GETIMPORT`, and `_G` string lookups (`GETTABLE`/`GETTABLEKS`), reads `meta.env` directly after `setfenv`, validates `LoadOptions` in `cloneFunction`, and enforces `LoadOptions` budgets (`instructionLimit`, `callLimit`, `timeout`, `interrupt`, `interruptInterval`).
`VM/HostEnv.luau` isolates host `getfenv`/`setfenv` calls outside `Dispatch` so `@native` and `safeenv` stay intact, and `VM/` loads its helpers eagerly during `require` so cloned package instances remain safe to destroy before yielding `getfenv()` execution.
