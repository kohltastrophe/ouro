--!strict
export type NodeId = number
export type ListId = number
export type SymbolId = number
export type BindingId = number
export type GrammarFlags = { [string]: boolean }
export type ResolvedFlags = { [string]: boolean }
--- Configuration options for `Ouro.parse`, `parseExpression`, `parseType`, and `newContext`.
export type ParseOptions = {
	profile: ("upstream" | "studio" | "experimental" | GrammarFlags)?, -- grammar profile name or explicit flag map
	lossless: boolean?, -- retain compact token/trivia tape for `reconstruct()`
	captureComments: boolean?, -- collect comments separately (auto-enabled by `lossless`)
	allowDeclarationSyntax: boolean?, -- enable `.d.luau` `declare` syntax
	requireEOF: boolean?, -- require trailing EOF on fragment entrypoints
	noErrorLimit: boolean?, -- disable `errorLimit` cap when `true`
	recursionLimit: number?, -- maximum nested parser recursion depth (default `1,000`)
	typeLengthLimit: number?, -- maximum items in a type list or union/intersection chain (default `1,000`)
	errorLimit: number?, -- maximum diagnostics before aborting with `"limit"` (default `100`)
	checkpointInterval: number?, -- scanned byte interval between `checkpoint` calls (default `4,096`)
	checkpoint: ((offset: number) -> boolean?)?, -- cooperative yield or cancel callback (`false` cancels)
}
export type Diagnostic = { start: number, finish: number, message: string, code: "syntax" | "limit" | "compile" }
export type Comment = { kind: number, start: number, finish: number }
export type HotComment = { header: boolean, content: string, start: number, finish: number }
export type TokenTape = { kinds: { number }, starts: { number }, finishes: { number }, count: number }
export type AstTable = { [string]: any }
-- Kind-specific fields are discriminated by numeric kind; all references are IDs.
export type Node = { kind: number, start: number, finish: number, [string]: any }
export type Binding = {
	name: SymbolId,
	start: number,
	finish: number,
	annotation: NodeId,
	shadow: BindingId,
	functionDepth: number,
	loopDepth: number,
	scopeDepth: number,
	isConst: boolean,
	isExported: boolean,
}
--- Visitor callbacks for `ParseResult:visit`. Return `false` from `enter` to skip child traversal.
export type AstVisitor = {
	enter: ((nodeId: NodeId, kind: number, depth: number) -> boolean?)?,
	leave: ((nodeId: NodeId, kind: number, depth: number) -> ())?,
}
--- Opt-in allocation and pattern caps enforced by VM standard libraries and constructors.
export type ResourceLimits = {
	maxStringLength: number?, -- maximum string byte length produced by stdlib calls or `CONCAT`
	maxTableSize: number?, -- maximum element count in constructors (`table.create`, `NEWTABLE`, `SETLIST`)
	maxBufferSize: number?, -- maximum buffer size allocated through `buffer` helpers
	maxPatternLength: number?, -- maximum pattern length passed to `string.find`/`match`/`gmatch`/`gsub`
}
--- Read-only AST arena returned on `ParseResult.arena`.
export type Arena = {
	nodes: { Node },
	kinds: { number },
	starts: { number },
	finishes: { number },
	hasTypeAnnotations: boolean,
	hasClasses: boolean,
	listFirsts: { number },
	listCounts: { number },
	listValues: { any },
	bindings: { Binding },
	symbols: { string },
	kind: (Arena, NodeId) -> number,
	kindName: (Arena, NodeId) -> string,
	listCount: (Arena, ListId) -> number,
	listAt: (Arena, ListId, number) -> any,
	listItems: (Arena, ListId) -> { any },
}
--- Structured result returned by `Ouro.parse`, `parseExpression`, and `parseType`.
export type ParseResult = {
	status: "ok" | "syntaxError" | "limit" | "cancelled", -- parse outcome (`root == 0` on `"limit"` or `"cancelled"`)
	root: NodeId, -- root AST node ID (`0` if aborted)
	arena: Arena, -- flat SoA + record AST arena owned by this result
	source: string, -- original source string passed to the parser
	diagnostics: { Diagnostic }, -- reported syntax, limit, or compile errors
	lineStarts: { number }, -- zero-based byte offsets where each LF-delimited line starts
	comments: { Comment }, -- captured comments when `captureComments` or `lossless` is enabled
	hotcomments: { HotComment }, -- parsed `--!` / header hotcomments
	tape: TokenTape?, -- lossless lexical tape when `lossless = true`
	profile: "upstream" | "studio" | "experimental" | "custom", -- resolved grammar profile name
	flags: ResolvedFlags, -- frozen grammar boolean map active during the parse
	kind: (ParseResult, NodeId) -> number,
	kindName: (ParseResult, NodeId) -> string,
	range: (ParseResult, NodeId) -> (number, number),
	position: (ParseResult, number) -> (number, number),
	offset: (ParseResult, number, number) -> number,
	childCount: (ParseResult, NodeId) -> number,
	childAt: (ParseResult, NodeId, number) -> NodeId,
	forEachChild: (ParseResult, NodeId, (NodeId) -> boolean?) -> (),
	visit: (ParseResult, AstVisitor | ((NodeId, number, number) -> boolean?)) -> (),
	reconstruct: (ParseResult) -> string,
}
--- Reusable parser context that recycles internal scratch tables across calls.
export type ParserContext = {
	busy: boolean, -- true while a parse (possibly suspended at a checkpoint) is active
	options: ParseOptions,
	reset: (ParserContext) -> (),
	parse: (ParserContext, string) -> ParseResult,
	parseExpression: (ParserContext, string) -> ParseResult,
	parseType: (ParserContext, string) -> ParseResult,
}
export type CompileConstant =
	{ type: "nil" }
	| { type: "boolean", value: boolean }
	| { type: "number", value: number }
	| { type: "vectorf", value: { number } }
	| { type: "vectord", value: { number } }
	| { type: "string", value: string }
	| { type: "table", value: { [string]: CompileConstant } }
export type ProtoTableConstant = {
	keys: { number },
	constants: { number }?,
	length: number,
}
export type ProtoClassConstant = {
	className: number,
	numPrivateInstanceProps: number,
	numPrivateStaticProps: number,
	propertyNames: { number },
	methodNames: { number },
}
export type Proto = {
	id: number,
	maxstacksize: number,
	numparams: number,
	nups: number,
	isvararg: boolean,
	flags: number,
	code: { number },
	kTypes: { number },
	kValues: { any },
	p: { number },
	linedefined: number,
	debugname: string?,
	lineData: string?,
	linegaplog2: number?,
	locvars: { { varname: string?, startpc: number, endpc: number, reg: number } }?,
	upvalues: { string? }?,
	typeinfo: string?,
}
--- In-memory decoded bytecode module produced by `Bytecode.deserialize` and `Compiler.compileProto`.
export type ProtoModule = {
	version: number,
	typesversion: number,
	strings: { string },
	protos: { Proto },
	mainid: number,
	userdataTypes: { string }?,
}
export type BytecodeEncoder = ((number) -> number) | { encode: (self: any, code: { number }) -> () }
export type BytecodeDecoder = ((number) -> number) | { decode: (self: any, code: { number }) -> () }
--- Configuration options for `Ouro.compile`, `Ouro.compileResult`, and `Ouro.Compiler.compileProto`.
export type CompileOptions = {
	optimizationLevel: number?, -- `0` = none, `1` = baseline folding & fastcalls (default), `2` = inlining & unrolling
	debugLevel: number?, -- `0` = stripped, `1` = line info & function names (default), `2` = locals & upvalues
	typeInfoLevel: number?, -- `0` = annotated functions only (default), `1` = all functions
	coverageLevel: number?, -- `0` = disabled (default), `1` = statements, `2` = statements & expressions
	vectorLib: string?, -- global library name for vector constructor lowering (e.g. `"Vector3"`)
	vectorCtor: string?, -- constructor member name on `vectorLib` (e.g. `"new"`)
	vectorType: string?, -- vector annotation name used for typed local specialization
	vectorPrecision: number?, -- `0` = 32-bit float vectors (default), `1` = 64-bit doubles
	mutableGlobals: { string }?, -- globals excluded from immutable builtin optimization
	userdataTypes: { string }?, -- known host userdata type names for type-info emission
	librariesWithKnownMembers: { string }?, -- library names eligible for `libraryMember*Cb` callbacks
	libraryMemberTypeCb: ((library: string, member: string) -> number)?, -- returns `Ouro.Bytecode.Types` tag (`0..255`)
	libraryMemberConstantCb: ((library: string, member: string) -> CompileConstant?)?,
	disabledBuiltins: { string }?, -- builtin names or wildcards (`"math.*"`, `"*"`) excluded from fastcalls
	encoder: BytecodeEncoder?, -- custom instruction opcode encoder for serialized bytecode
	dumpFlags: number?, -- bitmask of `Ouro.Bytecode.DumpFlags` for remarks and disassembly dumps
	flags: { [string]: boolean | number }?, -- overrides matching `Ouro.Compiler.CompilerFlags`
	parseOptions: ParseOptions?, -- forwarded to the parser when input is source text
}
--- Mutable bytecode builder returned on `CompileResult.builder`.
export type BytecodeBuilder = {
	getBytecode: (self: BytecodeBuilder) -> string,
	toProtoModule: (self: BytecodeBuilder) -> ProtoModule,
	setDumpSource: (self: BytecodeBuilder, source: string) -> (),
	dumpFunction: (self: BytecodeBuilder, fid: number) -> string,
	dumpEverything: (self: BytecodeBuilder) -> string,
	dumpSourceRemarks: (self: BytecodeBuilder) -> string,
	dumpTypeInfo: (self: BytecodeBuilder) -> string,
}
--- Configuration options for `Ouro.VM.createEnvironment`.
export type EnvironmentOptions = {
	inheritHost: boolean?, -- inherit non-standard host or Roblox globals (defaults `false`, excludes `script` and `loadstring`)
	libraries: { string }?, -- stdlib allowlist (`"base"`, `"bit32"`, `"buffer"`, `"coroutine"`, `"debug"`, `"math"`, `"os"`, `"string"`, `"table"`, `"utf8"`, `"vector"`)
	readOnly: boolean?, -- freeze environment or wrap host inheritance in a locked read-only proxy
	resourceLimits: ResourceLimits?, -- opt-in stdlib and constructor caps (`nil` for zero overhead)
}
--- Frame snapshot passed to `LoadOptions` debug callbacks (`onCall`, `onReturn`, `onLine`, `onBreak`).
export type DebugFrameInfo = {
	source: string,
	line: number,
	name: string?,
	numparams: number,
	isvararg: boolean,
	depth: number,
}
--- Per-function line execution counts returned by `Ouro.VM.getCoverage`.
export type CoverageEntry = {
	name: string?,
	lineDefined: number,
	hits: { [number]: number },
	totalHits: number,
}
--- Captured upvalue metadata returned by `Ouro.VM.getUpvalues`.
export type UpvalueInfo = {
	index: number,
	name: string?,
	value: any,
}
export type LoadMode = "text" | "binary" | "auto"
--- Execution environment, resource budget, global hook, and debug hook options for `Ouro.load`.
export type LoadOptions = {
	name: string?, -- chunk name for stack traces (`"=chunk"` for binary inputs, `[string "..."]` for text)
	env: { [any]: any }?, -- custom global environment (defaults to a fresh isolated `VM.createEnvironment()`)
	compile: CompileOptions?, -- compiler options when loading text source chunks
	decoder: BytecodeDecoder?, -- reverses a custom `CompileOptions.encoder` on binary bytecode
	mode: LoadMode?, -- `"text"`, `"binary"`, or `"auto"` header sniffing (defaults `"text"` for strings, `"binary"` for buffers)
	timeout: number?, -- lazy wall-clock deadline in seconds (`os.clock()`) started on first invocation
	instructionLimit: number?, -- maximum VM instructions executed before aborting
	callLimit: number?, -- maximum active guest call frames across nested calls and coroutines
	interruptInterval: number?, -- instruction interval between `interrupt` and `timeout` checks (default `4,096`)
	interrupt: (() -> boolean?)?, -- periodic callback; return `false`, yield, or error to abort execution
	getGlobal: ((name: string, env: { [any]: any }) -> any)?, -- intercepts global reads (`GETGLOBAL`, unresolved `GETIMPORT`, `_G[k]`)
	setGlobal: ((name: string, value: any, env: { [any]: any }) -> ())?, -- intercepts global writes (`SETGLOBAL`, `_G[k] = v`)
	safeEnv: boolean?, -- preserve fast paths on unmodified built-in roots present in `env` alongside `getGlobal`
	resourceLimits: ResourceLimits?, -- overrides `env` resource caps for this chunk
	onCall: ((info: DebugFrameInfo) -> ())?, -- fires when entering a VM closure frame
	onReturn: ((info: DebugFrameInfo) -> ())?, -- fires before exiting a VM closure frame
	onLine: ((line: number, info: DebugFrameInfo) -> ())?, -- fires when execution advances to a different source line
	onBreak: ((line: number, info: DebugFrameInfo) -> ())?, -- fires on `LOP_BREAK` instructions
}
--- Structured result returned by `Ouro.compileResult`.
export type CompileResult = {
	status: "ok" | "parseError" | "compileError",
	bytecode: string, -- compiled bytecode, or status-zero encoded error readable via `Bytecode.decodeError`
	builder: BytecodeBuilder?,
	error: string?,
	diagnostics: { Diagnostic },
	parseResult: ParseResult,
}
return {}
