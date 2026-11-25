--!strict
local Grammar = require("@self/Grammar")
local Types = require("@self/Types")

type ArenaModule = typeof(require("@self/Arena"))
type AstModule = typeof(require("@self/Ast"))
type BytecodeBuilderModule = typeof(require("@self/BytecodeBuilder"))
type BytecodeCodecModule = typeof(require("@self/BytecodeCodec"))
type BytecodeDefsModule = typeof(require("@self/BytecodeDefs"))
type CompilerModule = typeof(require("@self/Compiler"))
type ParserModule = typeof(require("@self/Parser"))
type ProfilesModule = typeof(require("@self/Profiles"))
type TokenModule = typeof(require("@self/Token"))
type VerifierModule = typeof(require("@self/VM/Verifier"))
type VMModule = typeof(require("@self/VM"))
type KindsTable = typeof(require("@self/Arena").Kinds)

export type NodeId = Types.NodeId
export type ListId = Types.ListId
export type SymbolId = Types.SymbolId
export type BindingId = Types.BindingId
export type GrammarFlags = Types.GrammarFlags
export type ResolvedFlags = Types.ResolvedFlags
export type ParseOptions = Types.ParseOptions
export type Diagnostic = Types.Diagnostic
export type Comment = Types.Comment
export type HotComment = Types.HotComment
export type TokenTape = Types.TokenTape
export type AstTable = Types.AstTable
export type AstVisitor = Types.AstVisitor
export type Node = Types.Node
export type Binding = Types.Binding
export type Arena = Types.Arena
export type ParseResult = Types.ParseResult
export type ParserContext = Types.ParserContext
export type CompileConstant = Types.CompileConstant
export type ProtoTableConstant = Types.ProtoTableConstant
export type ProtoClassConstant = Types.ProtoClassConstant
export type Proto = Types.Proto
export type ProtoModule = Types.ProtoModule
export type BytecodeEncoder = Types.BytecodeEncoder
export type BytecodeDecoder = Types.BytecodeDecoder
export type CompileOptions = Types.CompileOptions
export type BytecodeBuilder = Types.BytecodeBuilder
export type ResourceLimits = Types.ResourceLimits
export type EnvironmentOptions = Types.EnvironmentOptions
export type DebugFrameInfo = Types.DebugFrameInfo
export type CoverageEntry = Types.CoverageEntry
export type UpvalueInfo = Types.UpvalueInfo
export type LoadMode = Types.LoadMode
export type LoadOptions = Types.LoadOptions
export type CompileResult = Types.CompileResult

local loadPublicModule: (name: string) -> any
local cachedPublic: { [string]: any } = {}
local cachedParser: ParserModule? = nil

local function getParser(): ParserModule
	if cachedParser == nil then
		cachedParser = require("@self/Parser")
	end
	return cachedParser :: ParserModule
end

local cachedVerifier: VerifierModule? = nil

local function verifyBytecode(input: string | buffer | ProtoModule, decoder: BytecodeDecoder?): (boolean, string?)
	if cachedVerifier == nil then
		cachedVerifier = require("@self/VM/Verifier")
	end
	return (cachedVerifier :: VerifierModule).verify(input, decoder)
end

type BytecodeModule = {
	disassemble: (
		input: string | buffer | ProtoModule,
		dumpFlags: number?,
		source: string?,
		decoder: BytecodeDecoder?
	) -> string,
	deserialize: (bytecode: string | buffer, decoder: BytecodeDecoder?) -> (ProtoModule?, string?),
	serialize: (protoModule: ProtoModule, encoder: BytecodeEncoder?) -> (string?, string?),
	verify: (input: string | buffer | ProtoModule, decoder: BytecodeDecoder?) -> (boolean, string?),
	decodeLineInfo: (proto: Proto) -> ({ number }?, { number }?),
	encodeError: (message: string) -> string,
	decodeError: (bytecode: string | buffer) -> string?,
	getStringHash: (str: string) -> number,
	getImportId: (id0: number, id1: number?, id2: number?) -> number,
	decomposeImportId: (ids: number) -> (number, number, number, number),
	insnOp: (insn: number) -> number,
	insnA: (insn: number) -> number,
	insnB: (insn: number) -> number,
	insnC: (insn: number) -> number,
	insnD: (insn: number) -> number,
	insnE: (insn: number) -> number,
	Opcodes: typeof(require("@self/BytecodeDefs").Opcodes),
	opcodeNames: { [number]: string },
	opLengths: { [number]: number },
	Builtins: typeof(require("@self/BytecodeDefs").Builtins),
	builtinNames: { [number]: string },
	Tags: typeof(require("@self/BytecodeDefs").Tags),
	Types: typeof(require("@self/BytecodeDefs").Types),
	Captures: typeof(require("@self/BytecodeDefs").Captures),
	ProtoFlags: typeof(require("@self/BytecodeDefs").ProtoFlags),
	FeedbackTypes: typeof(require("@self/BytecodeDefs").FeedbackTypes),
	DumpFlags: typeof(require("@self/BytecodeBuilder").DumpFlags),
}

local function buildBytecodeTable(): BytecodeModule
	local BytecodeBuilder = require("@self/BytecodeBuilder") :: BytecodeBuilderModule
	local BytecodeCodec = require("@self/BytecodeCodec") :: BytecodeCodecModule
	local BytecodeDefs = require("@self/BytecodeDefs") :: BytecodeDefsModule
	local BytecodeDisassembler = require("@self/BytecodeDisassembler")
	local mod: BytecodeModule = {
		disassemble = BytecodeDisassembler.disassemble,
		deserialize = BytecodeCodec.deserialize,
		serialize = BytecodeCodec.serialize,
		verify = verifyBytecode,
		decodeLineInfo = BytecodeCodec.decodeLineInfo,
		encodeError = BytecodeCodec.encodeError,
		decodeError = BytecodeCodec.decodeError,
		getStringHash = BytecodeBuilder.getStringHash,
		getImportId = BytecodeBuilder.getImportId,
		decomposeImportId = BytecodeCodec.decomposeImportId,
		insnOp = BytecodeCodec.insnOp,
		insnA = BytecodeCodec.insnA,
		insnB = BytecodeCodec.insnB,
		insnC = BytecodeCodec.insnC,
		insnD = BytecodeCodec.insnD,
		insnE = BytecodeCodec.insnE,
		Opcodes = BytecodeDefs.Opcodes,
		opcodeNames = BytecodeDefs.opcodeNames,
		opLengths = BytecodeDefs.opLengths,
		Builtins = BytecodeDefs.Builtins,
		builtinNames = BytecodeDefs.builtinNames,
		Tags = BytecodeDefs.Tags,
		Types = BytecodeDefs.Types,
		Captures = BytecodeDefs.Captures,
		ProtoFlags = BytecodeDefs.ProtoFlags,
		FeedbackTypes = BytecodeDefs.FeedbackTypes,
		DumpFlags = BytecodeBuilder.DumpFlags,
	}
	return table.freeze(mod) :: any
end

local PUBLIC_LOADERS: { [string]: () -> any } = {
	Ast = function(): any
		return require("@self/Ast")
	end,
	Profiles = function(): any
		return require("@self/Profiles")
	end,
	Tokens = function(): any
		return require("@self/Token")
	end,
	Kinds = function(): any
		return (require("@self/Arena") :: ArenaModule).Kinds
	end,
	Compiler = function(): any
		return require("@self/Compiler")
	end,
	Bytecode = buildBytecodeTable,
	VM = function(): any
		return require("@self/VM")
	end,
}

function loadPublicModule(name: string): any
	local mod = cachedPublic[name]
	if mod == nil then
		mod = PUBLIC_LOADERS[name]()
		cachedPublic[name] = mod
	end
	return mod
end

local package: any = {}

package.version = "0.1.0"
package.luauVersion = Grammar.version
package.upstreamRevision = Grammar.revision

function package.parse(source: string, options: ParseOptions?): ParseResult
	return getParser().parse(source, options)
end

function package.parseExpression(source: string, options: ParseOptions?): ParseResult
	return getParser().parseExpression(source, options)
end

function package.parseType(source: string, options: ParseOptions?): ParseResult
	return getParser().parseType(source, options)
end

function package.newContext(options: ParseOptions?): ParserContext
	return getParser().newContext(options)
end

local function compileFn(source: string | ParseResult, options: CompileOptions?): (string?, string?)
	return (loadPublicModule("Compiler") :: CompilerModule).compile(source, options)
end

local function compileResultFn(source: string | ParseResult, options: CompileOptions?): CompileResult
	return (loadPublicModule("Compiler") :: CompilerModule).compileResult(source, options)
end

local function loadFn(chunk: string | buffer | ProtoModule, options: LoadOptions?): (((...any) -> ...any)?, string?)
	return (loadPublicModule("VM") :: VMModule).load(chunk, options)
end

--- Compiles Luau source or a ParseResult into binary bytecode, returning `(bytecode, nil)` or `(nil, err)`.
package.compile = compileFn
--- Compiles Luau source or a ParseResult and returns a structured CompileResult.
package.compileResult = compileResultFn
--- Compiles or deserializes a Luau chunk and loads it into a callable VM closure.
package.load = loadFn

setmetatable(
	package :: any,
	table.freeze({
		__index = function(_self: any, key: string): any
			local loader = PUBLIC_LOADERS[key]
			if loader then
				return loadPublicModule(key)
			end
			return nil
		end,
	})
)

return table.freeze(package :: any) :: {
	version: string,
	luauVersion: string,
	upstreamRevision: string,
	Ast: AstModule,
	Profiles: ProfilesModule,
	Tokens: TokenModule,
	Kinds: KindsTable,
	Compiler: CompilerModule,
	Bytecode: BytecodeModule,
	VM: VMModule,
	parse: (string, ParseOptions?) -> ParseResult,
	parseExpression: (string, ParseOptions?) -> ParseResult,
	parseType: (string, ParseOptions?) -> ParseResult,
	newContext: (ParseOptions?) -> ParserContext,
	compile: (string | ParseResult, CompileOptions?) -> (string?, string?),
	compileResult: (string | ParseResult, CompileOptions?) -> CompileResult,
	load: (string | buffer | ProtoModule, LoadOptions?) -> (((...any) -> ...any)?, string?),
}
