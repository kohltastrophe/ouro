--!strict
local Ouro = require("../../")

local options: Ouro.ParseOptions = {
	profile = "studio",
	lossless = true,
	captureComments = true,
	allowDeclarationSyntax = false,
	requireEOF = true,
	recursionLimit = 512,
	typeLengthLimit = 512,
	errorLimit = 50,
	noErrorLimit = false,
	checkpointInterval = 2048,
	checkpoint = function(byteOffset: number): boolean?
		return byteOffset >= 0
	end,
}

local versionStr: string = Ouro.version
local luauVer: string = Ouro.luauVersion
local revStr: string = Ouro.upstreamRevision
local flags: Ouro.GrammarFlags = {
	LuauExperimentalWhileLocalSyntax = true,
	LuauExperimentalIfLocalSyntax = false,
	LuauDeclarationFixCrashOnBadUnicode = true,
}

local result: Ouro.ParseResult = Ouro.parse("local x: number = 1", options)
local astTree: Ouro.AstTable? = Ouro.Ast.toTables(result)
local topExpr: Ouro.ParseResult = Ouro.parseExpression("1 + 2", options)
local topType: Ouro.ParseResult = Ouro.parseType("number?", options)
local studioFlags: Ouro.ResolvedFlags = Ouro.Profiles.resolve("studio")
local status: "ok" | "syntaxError" | "limit" | "cancelled" = result.status
local diagnostics: { Ouro.Diagnostic } = result.diagnostics
local comments: { Ouro.Comment } = result.comments
local hotcomments: { Ouro.HotComment } = result.hotcomments
local root: Ouro.NodeId = result.root
local kind: number = result:kind(root)
local kindName: string = result:kindName(root)
local startOffset: number, finishOffset: number = result:range(root)
local childCount: number = result:childCount(root)
local firstChild: Ouro.NodeId = result:childAt(root, 1)
local visitedCount = 0
local visitor: Ouro.AstVisitor = {
	enter = function(_nodeId: Ouro.NodeId, _nodeKind: number, _depth: number): boolean?
		visitedCount += 1
		return true
	end,
}
result:visit(visitor)
local directChildCount = 0
result:forEachChild(root, function(_childId: Ouro.NodeId): boolean?
	directChildCount += 1
	return true
end)
local line: number, column: number = result:position(0)
local offset: number = result:offset(line, column)
local reconstructed: string = result:reconstruct()
local firstDiag: Ouro.Diagnostic? = diagnostics[1]
local firstComment: Ouro.Comment? = comments[1]
local firstHot: Ouro.HotComment? = hotcomments[1]

local context: Ouro.ParserContext = Ouro.newContext({ profile = flags })
local exprResult: Ouro.ParseResult = context:parseExpression("1 + 2")
local typeResult: Ouro.ParseResult = context:parseType("number")
local isBusy: boolean = context.busy
context:reset()
local blockTag: number = Ouro.Kinds.AstStatBlock
local nameToken: number = Ouro.Tokens.Name
assert(
	visitedCount > 0
		and directChildCount > 0
		and #versionStr > 0
		and #luauVer > 0
		and #revStr > 0
		and nameToken > 255
		and status == "ok"
		and astTree ~= nil
		and (astTree :: Ouro.AstTable).type == "AstStatBlock"
		and topExpr.status == "ok"
		and topType.status == "ok"
		and studioFlags.LuauSolverV2 == true
		and exprResult.status == "ok"
		and typeResult.status == "ok"
		and finishOffset >= startOffset
		and firstDiag == nil
		and firstComment == nil
		and firstHot == nil,
	"expected ok parse results"
)

local constTag: Ouro.CompileConstant = { type = "number", value = 1 }
local compileOptions: Ouro.CompileOptions = {
	optimizationLevel = 2,
	debugLevel = 2,
	typeInfoLevel = 1,
	coverageLevel = 0,
	vectorLib = "vector",
	vectorCtor = "create",
	vectorType = "vector",
	mutableGlobals = { "customGlobal" },
	libraryMemberConstantCb = function(_lib: string, _member: string): Ouro.CompileConstant?
		return constTag
	end,
	parseOptions = options,
}
local maybeBytecode, compileErr = Ouro.compile("local x: number = 1 + 2; return x", compileOptions)
local bytecode = assert(maybeBytecode, compileErr)
local maybeFromAst, astCompileErr = Ouro.compile(result, compileOptions)
local bytecodeFromAst = assert(maybeFromAst, astCompileErr)
local compileRes: Ouro.CompileResult = Ouro.compileResult("return 40 + 2", compileOptions)
local compiledProtoMod, compiledProtoErr = Ouro.Compiler.compileProto(result, { optimizationLevel = 1 })
local builder: Ouro.BytecodeBuilder? = compileRes.builder
local errBc: string = Ouro.Bytecode.encodeError(":1: test error")
local decodedErr: string? = Ouro.Bytecode.decodeError(errBc)
local opNum: number = Ouro.Bytecode.insnOp(0x01020304)
local importId: number = Ouro.Bytecode.getImportId(1, 2)
local impCount: number, imp0: number = Ouro.Bytecode.decomposeImportId(importId)
local _hashVal: number = Ouro.Bytecode.getStringHash("math")
local _retOp: number = Ouro.Bytecode.Opcodes.LOP_RETURN
local _absBuiltin: number = Ouro.Bytecode.Builtins.LBF_MATH_ABS
local decoderFn: Ouro.BytecodeDecoder = function(op: number): number
	return op
end
local disasmText: string = Ouro.Bytecode.disassemble(bytecode, Ouro.Bytecode.DumpFlags.Code)
local disasmDecoded: string = Ouro.Bytecode.disassemble(bytecode, Ouro.Bytecode.DumpFlags.Code, nil, decoderFn)
assert(#disasmDecoded > 0)
local protoModule: Ouro.ProtoModule = assert(Ouro.Bytecode.deserialize(bytecode))
local verifyOk: boolean, verifyErr: string? = Ouro.Bytecode.verify(bytecode)
assert(verifyOk and verifyErr == nil)
local reserialized: string?, serializeErr: string? = Ouro.Bytecode.serialize(protoModule)
assert(reserialized ~= nil and serializeErr == nil)
local decodedProtoModule: Ouro.ProtoModule = assert(Ouro.Bytecode.deserialize(bytecode, decoderFn))
assert(decodedProtoModule.version == protoModule.version)
local mainProto: Ouro.Proto = protoModule.protos[protoModule.mainid + 1]
local _kTypes: { number } = mainProto.kTypes
local _kValues: { any } = mainProto.kValues
local _linfo, _absinfo = Ouro.Bytecode.decodeLineInfo(mainProto)
assert(#_kTypes >= 0 and #_kValues >= 0 and (_linfo == nil or #_linfo > 0))
local resLimits: Ouro.ResourceLimits = {
	maxStringLength = 4096,
	maxTableSize = 1024,
	maxBufferSize = 4096,
	maxPatternLength = 256,
}
local envOpts: Ouro.EnvironmentOptions = {
	inheritHost = false,
	libraries = { "base", "math", "string", "table", "buffer" },
	readOnly = true,
	resourceLimits = resLimits,
}
local sandboxEnv = Ouro.VM.sandbox(Ouro.VM.createEnvironment(nil, envOpts))
local decoderLoadOpts: Ouro.LoadOptions = {
	name = "=decoded",
	mode = "binary",
	env = sandboxEnv,
	decoder = decoderFn,
}
assert(decoderLoadOpts.decoder == decoderFn)
local loadMode: Ouro.LoadMode = "text"
local loadOptions: Ouro.LoadOptions = {
	name = "=api",
	env = sandboxEnv,
	compile = compileOptions,
	mode = loadMode,
	safeEnv = false,
	timeout = 5,
	instructionLimit = 10000,
	callLimit = 64,
	interruptInterval = 1024,
	interrupt = function(): boolean?
		return true
	end,
	getGlobal = function(k: string, envTable: { [any]: any }): any
		return rawget(envTable, k)
	end,
	setGlobal = function(k: string, val: any, envTable: { [any]: any })
		rawset(envTable, k, val)
	end,
	onCall = function(_info: Ouro.DebugFrameInfo) end,
	onReturn = function(_info: Ouro.DebugFrameInfo) end,
	onLine = function(_lineNum: number, _info: Ouro.DebugFrameInfo) end,
	onBreak = function(_lineNum: number, _info: Ouro.DebugFrameInfo) end,
	resourceLimits = resLimits,
}
local fn, loadErr = Ouro.load("local a = ...; return a + 1", loadOptions)
local checkedFn = assert(fn, loadErr)
local binFn = assert(Ouro.VM.loadBytecode(bytecode, { name = "=bin_api", env = sandboxEnv }))
local protoFn = assert(Ouro.VM.loadProto(assert(compiledProtoMod, compiledProtoErr), { name = "=proto_api" }))
local covBc = assert(Ouro.compile("return 1", { coverageLevel = 1 }))
local covFn = assert(Ouro.VM.loadBytecode(covBc, { name = "=cov_api" }))
local covRes = covFn()
local resetOk: boolean = Ouro.VM.resetBudget(checkedFn)
local cov: { Ouro.CoverageEntry } = assert(Ouro.VM.getCoverage(covFn))
local upvFactory = assert(Ouro.load("local v = ...; return function() return v end", { name = "=upv_api" }))
local upvFn = upvFactory(7)
local upvs: { Ouro.UpvalueInfo } = assert(Ouro.VM.getUpvalues(upvFn))
local setUpvOk: boolean = Ouro.VM.setUpvalue(upvFn, 1, 9)
local clonedUpvFn = assert(Ouro.VM.cloneFunction(upvFn, sandboxEnv, { instructionLimit = 500 }))
assert(
	compileRes.status == "ok"
		and #bytecodeFromAst > 0
		and impCount == 2
		and imp0 == 1
		and #disasmText > 0
		and decodedErr == ":1: test error"
		and opNum == 4
		and (builder == nil or (#builder:getBytecode() > 0 and #builder:toProtoModule().protos > 0))
		and mainProto.maxstacksize >= 1
		and binFn() == 3
		and protoFn() == nil
		and covRes == 1
		and resetOk
		and #cov == 1
		and cov[1].totalHits == 1
		and #upvs == 1
		and setUpvOk
		and clonedUpvFn() == 9,
	"expected ok compile and load"
)
assert(checkedFn(41) == 42, "expected VM execution to return 42")
local traceText: string = Ouro.VM.traceback("check")

return {
	status = status,
	kind = kind,
	kindName = kindName,
	startOffset = startOffset,
	finishOffset = finishOffset,
	childCount = childCount,
	firstChild = firstChild,
	offset = offset,
	reconstructed = reconstructed,
	exprResult = exprResult,
	typeResult = typeResult,
	isBusy = isBusy,
	blockTag = blockTag,
	bytecode = bytecode,
	compileRes = compileRes,
	protoModule = protoModule,
	traceText = traceText,
}
