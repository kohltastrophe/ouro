--!strict
--- Self-hosted Luau 0.748 lexer, lossless parser, bytecode compiler, and sandboxed register VM in pure Luau.
local Grammar = require("@self/Grammar")
local Types = require("@self/Types")

type ArenaModule = typeof(require("@self/Arena"))
type AstModule = typeof(require("@self/Ast"))
type BytecodeModule = typeof(require("@self/Bytecode"))
type CompilerModule = typeof(require("@self/Compiler"))
type ParserModule = typeof(require("@self/Parser"))
type ProfilesModule = typeof(require("@self/Profiles"))
type TokenModule = typeof(require("@self/Token"))
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
	Bytecode = function(): any
		return require("@self/Bytecode")
	end,
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

type PublicApi = {
	--- Package semantic version string.
	version: string,
	--- Pinned upstream Luau release version (`"0.748"`).
	luauVersion: string,
	--- Pinned upstream Luau Git commit SHA from `UPSTREAM.json`.
	upstreamRevision: string,
	--- Lossless AST table serializer (`Ast.toTables`).
	Ast: typeof(require("@self/Ast")),
	--- Built-in grammar flag profiles (`upstream`, `studio`, `experimental`) and resolver.
	Profiles: typeof(require("@self/Profiles")),
	--- Immutable map of token names (`Eof`, `Name`, `ReservedFunction`, ...) to numeric token kinds.
	Tokens: typeof(require("@self/Token")),
	--- Immutable map of upstream AST node names (such as `AstStatBlock`) to numeric node kind tags.
	Kinds: typeof(require("@self/Arena").Kinds),
	--- Bytecode compiler module (`compile`, `compileResult`, `compileProto`, `CompilerFlags`).
	Compiler: typeof(require("@self/Compiler")),
	--- Bytecode codec, disassembler, verifier, and instruction tables.
	Bytecode: typeof(require("@self/Bytecode")),
	--- Sandboxed register VM, isolated environments, execution limits, and debug hooks.
	VM: typeof(require("@self/VM")),
	--- Parses a Luau source chunk into an arena-backed `ParseResult`.
	parse: (string, ParseOptions?) -> ParseResult,
	--- Parses a standalone Luau expression into an arena-backed `ParseResult`.
	parseExpression: (string, ParseOptions?) -> ParseResult,
	--- Parses a standalone Luau type annotation into an arena-backed `ParseResult`.
	parseType: (string, ParseOptions?) -> ParseResult,
	--- Creates a reusable `ParserContext` that recycles internal scratch tables across parses.
	newContext: (ParseOptions?) -> ParserContext,
	--- Compiles Luau source or a `ParseResult` into binary bytecode, returning `(bytecode, nil)` or `(nil, err)`.
	compile: (string | ParseResult, CompileOptions?) -> (string?, string?),
	--- Compiles Luau source or a `ParseResult` and returns a structured `CompileResult`.
	compileResult: (string | ParseResult, CompileOptions?) -> CompileResult,
	--- Compiles or deserializes a Luau chunk and loads it into a callable sandboxed VM closure.
	load: (string | buffer | ProtoModule, LoadOptions?) -> (((...any) -> ...any)?, string?),
}

local package = {} :: any

--- Package semantic version string.
package.version = "0.1.0"
--- Pinned upstream Luau release version (`"0.748"`).
package.luauVersion = Grammar.version
--- Pinned upstream Luau Git commit SHA from `UPSTREAM.json`.
package.upstreamRevision = Grammar.revision

--- Parses a Luau source chunk into an arena-backed `ParseResult`.
function package.parse(source: string, options: ParseOptions?): ParseResult
	return getParser().parse(source, options)
end

--- Parses a standalone Luau expression into an arena-backed `ParseResult`.
function package.parseExpression(source: string, options: ParseOptions?): ParseResult
	return getParser().parseExpression(source, options)
end

--- Parses a standalone Luau type annotation into an arena-backed `ParseResult`.
function package.parseType(source: string, options: ParseOptions?): ParseResult
	return getParser().parseType(source, options)
end

--- Creates a reusable `ParserContext` that recycles internal scratch tables across parses.
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

--- Compiles Luau source or a `ParseResult` into binary bytecode, returning `(bytecode, nil)` or `(nil, err)`.
package.compile = compileFn
--- Compiles Luau source or a `ParseResult` and returns a structured `CompileResult`.
package.compileResult = compileResultFn
--- Compiles or deserializes a Luau chunk and loads it into a callable sandboxed VM closure.
package.load = loadFn

setmetatable(
	package,
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

return table.freeze(package :: any) :: PublicApi
