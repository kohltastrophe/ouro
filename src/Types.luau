--!strict
export type NodeId = number
export type ListId = number
export type SymbolId = number
export type BindingId = number
export type GrammarFlags = { [string]: boolean }
export type ResolvedFlags = { [string]: boolean }
export type ParseOptions = {
	profile: ("upstream" | "studio" | "experimental" | GrammarFlags)?,
	lossless: boolean?,
	captureComments: boolean?,
	allowDeclarationSyntax: boolean?,
	requireEOF: boolean?,
	noErrorLimit: boolean?,
	recursionLimit: number?,
	typeLengthLimit: number?,
	errorLimit: number?,
	checkpointInterval: number?,
	checkpoint: ((offset: number) -> boolean?)?,
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
export type AstVisitor = {
	enter: ((nodeId: NodeId, kind: number, depth: number) -> boolean?)?,
	leave: ((nodeId: NodeId, kind: number, depth: number) -> ())?,
}
export type ResourceLimits = {
	maxStringLength: number?,
	maxTableSize: number?,
	maxBufferSize: number?,
	maxPatternLength: number?,
}
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
export type ParseResult = {
	status: "ok" | "syntaxError" | "limit" | "cancelled",
	root: NodeId,
	arena: Arena,
	source: string,
	diagnostics: { Diagnostic },
	lineStarts: { number },
	comments: { Comment },
	hotcomments: { HotComment },
	tape: TokenTape?,
	profile: "upstream" | "studio" | "experimental" | "custom",
	flags: ResolvedFlags,
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
export type ParserContext = {
	busy: boolean,
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
export type CompileOptions = {
	optimizationLevel: number?,
	debugLevel: number?,
	typeInfoLevel: number?,
	coverageLevel: number?,
	vectorLib: string?,
	vectorCtor: string?,
	vectorType: string?,
	vectorPrecision: number?,
	mutableGlobals: { string }?,
	userdataTypes: { string }?,
	librariesWithKnownMembers: { string }?,
	libraryMemberTypeCb: ((library: string, member: string) -> number)?,
	libraryMemberConstantCb: ((library: string, member: string) -> CompileConstant?)?,
	disabledBuiltins: { string }?,
	encoder: BytecodeEncoder?,
	dumpFlags: number?,
	flags: { [string]: boolean | number }?,
	parseOptions: ParseOptions?,
}
export type BytecodeBuilder = {
	getBytecode: (self: BytecodeBuilder) -> string,
	toProtoModule: (self: BytecodeBuilder) -> ProtoModule,
	setDumpSource: (self: BytecodeBuilder, source: string) -> (),
	dumpFunction: (self: BytecodeBuilder, fid: number) -> string,
	dumpEverything: (self: BytecodeBuilder) -> string,
	dumpSourceRemarks: (self: BytecodeBuilder) -> string,
	dumpTypeInfo: (self: BytecodeBuilder) -> string,
}
export type EnvironmentOptions = {
	inheritHost: boolean?,
	libraries: { string }?,
	readOnly: boolean?,
	resourceLimits: ResourceLimits?,
}
export type DebugFrameInfo = {
	source: string,
	line: number,
	name: string?,
	numparams: number,
	isvararg: boolean,
	depth: number,
}
export type CoverageEntry = {
	name: string?,
	lineDefined: number,
	hits: { [number]: number },
	totalHits: number,
}
export type UpvalueInfo = {
	index: number,
	name: string?,
	value: any,
}
export type LoadMode = "text" | "binary" | "auto"
export type LoadOptions = {
	name: string?,
	env: { [any]: any }?,
	compile: CompileOptions?,
	decoder: BytecodeDecoder?,
	mode: LoadMode?,
	timeout: number?,
	instructionLimit: number?,
	callLimit: number?,
	interruptInterval: number?,
	interrupt: (() -> boolean?)?,
	getGlobal: ((name: string, env: { [any]: any }) -> any)?,
	setGlobal: ((name: string, value: any, env: { [any]: any }) -> ())?,
	safeEnv: boolean?,
	resourceLimits: ResourceLimits?,
	onCall: ((info: DebugFrameInfo) -> ())?,
	onReturn: ((info: DebugFrameInfo) -> ())?,
	onLine: ((line: number, info: DebugFrameInfo) -> ())?,
	onBreak: ((line: number, info: DebugFrameInfo) -> ())?,
}
export type CompileResult = {
	status: "ok" | "parseError" | "compileError",
	bytecode: string,
	builder: BytecodeBuilder?,
	error: string?,
	diagnostics: { Diagnostic },
	parseResult: ParseResult,
}
return {}
