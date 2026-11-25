--!strict
-- Luau 0.748 expression, table, fastcall, closure, and lvalue compiler.
-- Upstream Luau is MIT licensed; see ../LICENSE.md and ../UPSTREAM.json.
local Arena = require("./Arena")
local BytecodeBuilder = require("./BytecodeBuilder")
local BytecodeCodec = require("./BytecodeCodec")
local BytecodeDefs = require("./BytecodeDefs")
local CompilerBuiltins = require("./CompilerBuiltins")
local CompilerFolding = require("./CompilerFolding")
local PublicTypes = require("./Types")

local K = Arena.Kinds
local Opcodes = BytecodeDefs.Opcodes
local Builtins = BytecodeDefs.Builtins
local Types = BytecodeDefs.Types
local CaptureTypes = BytecodeDefs.Captures
local ConstantType = CompilerBuiltins.ConstantType
local GlobalState = CompilerBuiltins.GlobalState

local kInvalidReg = 255
local kInvalidUpvalue = -1
local kMaxUpvalueCount = 200
local EMPTY_TABLE_SHAPE: CompilerFolding.TableShapePrediction = { arraySize = 0, hashSize = 0 }
local FORMAT_HASH = BytecodeBuilder.getStringHash("format")
local bcbEmitABC = BytecodeBuilder.emitABC
local bcbEmitAD = BytecodeBuilder.emitAD
local bcbEmitAux = BytecodeBuilder.emitAux
local bcbEmitLabel = BytecodeBuilder.emitLabel
local bcbAddConstStr = BytecodeBuilder.addConstantString
local bcbAddConstNum = BytecodeBuilder.addConstantNumber

local LValueKind = {
	Local = 1,
	Upvalue = 2,
	Global = 3,
	IndexName = 4,
	IndexNumber = 5,
	IndexExpr = 6,
	PrivateField = 7,
}

local UNARY_OPS: { [string]: number } = table.freeze({
	["Not"] = Opcodes.LOP_NOT,
	["Minus"] = Opcodes.LOP_MINUS,
	["Len"] = Opcodes.LOP_LENGTH,
} :: { [string]: number })

local BINARY_ARITH_OPS: { [string]: number } = table.freeze({
	["Add"] = Opcodes.LOP_ADD,
	["Sub"] = Opcodes.LOP_SUB,
	["Mul"] = Opcodes.LOP_MUL,
	["Div"] = Opcodes.LOP_DIV,
	["FloorDiv"] = Opcodes.LOP_IDIV,
	["Mod"] = Opcodes.LOP_MOD,
	["Pow"] = Opcodes.LOP_POW,
} :: { [string]: number })

local BINARY_ARITHK_OPS: { [string]: number } = table.freeze({
	["Add"] = Opcodes.LOP_ADDK,
	["Sub"] = Opcodes.LOP_SUBK,
	["Mul"] = Opcodes.LOP_MULK,
	["Div"] = Opcodes.LOP_DIVK,
	["FloorDiv"] = Opcodes.LOP_IDIVK,
	["Mod"] = Opcodes.LOP_MODK,
	["Pow"] = Opcodes.LOP_POWK,
} :: { [string]: number })

export type AssignScratch = {
	lvKinds: { number },
	lvRegs: { number },
	lvAuxs: { number },
	lvNames: { string? },
	lvSymIds: { number },
	lvStarts: { number },
	lvFinishes: { number },
	conflictRegs: { number },
	valueRegs: { number },
	conflict: { [number]: boolean },
	assigned: { [number]: boolean },
}

export type InlineFrame = {
	func: number,
	oldLocals: number,
	target: number,
	targetCount: number,
	resultLocal: number,
	returnJumps: { number },
	oldBuiltinTop: number,
	oldExprChangeTop: number,
	oldLocalChangeTop: number,
}

export type CompilerCtx = {
	bytecode: BytecodeBuilder.BytecodeBuilderImpl,
	arena: Arena.ArenaImpl,
	arenaSymbolMap: { [string]: number }?,
	origNodeCount: number,
	origBindingCount: number,
	origSymbolCount: number,
	nodes: { [number]: PublicTypes.Node },
	kinds: { number },
	starts: { number },
	finishes: { number },
	listFirsts: { number },
	listCounts: { number },
	listValues: { [number]: any },
	bindings: { [number]: PublicTypes.Binding },
	symbols: { [number]: string },
	symbolByName: { [string]: number },
	symbolHashes: { [number]: number },
	symbolStrRefs: { [number]: number },
	lineStarts: { number },
	lastLineIdx: number,
	lastLineStart: number,
	lastLineEnd: number,
	lastLineNum: number,
	opts: PublicTypes.CompileOptions,
	optimizationLevel: number,
	debugLevel: number,
	typeInfoLevel: number,
	recordDebug: boolean,
	coverageLevel: number,
	vectorPrecision: number,
	flags: { [string]: any },
	flagExpIfLocal: boolean,
	flagExpWhileLocal: boolean,
	flagDebugClasses: boolean,
	mainFlags: number,
	rootId: number,
	getfenvUsed: boolean,
	setfenvUsed: boolean,
	hasTypeAliases: boolean,
	hasClasses: boolean,
	funcHasCalls: { [number]: boolean },
	funcReadTableLocal: { [number]: boolean },
	alwaysTermCache: { [number]: boolean },
	trialDepth: number,
	functions: { [number]: any },
	localReg: { [number]: number },
	localAllocated: { [number]: boolean },
	localCaptured: { [number]: boolean },
	localReused: { [number]: boolean },
	localDebugPc: { [number]: number },
	localAllocPc: { [number]: number },
	globals: { [number]: number },
	vars: CompilerFolding.VariableTable,
	constTypes: { [number]: number },
	constVals: { [number]: any },
	locstantTypes: { [number]: number },
	locstantVals: { [number]: any },
	tableConstants: { [number]: number },
	tableShapes: { [number]: CompilerFolding.TableShapePrediction },
	builtins: { [number]: number },
	builtinsFold: { [number]: number }?,
	builtinsFoldLibraryK: boolean?,
	userdataTypes: { [string]: number },
	functionTypes: { [number]: string },
	localTypes: { [number]: number },
	exprTypes: { [number]: number },
	inlineBuiltins: { [number]: number },
	inlineBuiltinKeys: { number },
	inlineBuiltinOldVals: { number },
	inlineBuiltinTop: number,
	inlineArgLocalIds: { number },
	inlineArgRegs: { number },
	inlineArgAllocPcs: { number },
	inlineArgInits: { number },
	inlineArgTypes: { number },
	inlineArgVals: { any },
	inlineArgTop: number,
	inlineFramePool: { InlineFrame },
	exprChanges: CompilerFolding.ChangeStack,
	localChanges: CompilerFolding.ChangeStack,
	exportTableLocalId: number,
	exports: {
		exportedClasses: { [number]: number },
		exportedFunctions: { [number]: boolean },
		exportedVariables: { number },
		exportedTableCid: number,
		hasExports: boolean,
		hasTypeExports: boolean,
		hasModuleReturn: boolean,
	},
	regTop: number,
	stackSize: number,
	argCount: number,
	hasLoops: boolean,
	hasMultiRet: boolean,
	hasRequire: boolean,
	currentFunctionId: number,
	currentFunctionNode: any?,
	blockDepth: number,
	localStack: { number },
	regCaptured: { [number]: boolean },
	activeLocals: number,
	upvals: { number },
	upvalMap: { [number]: number },
	enclosingClasses: { [number]: { number } },
	classPrivateFieldOffsets: { [number]: { [number]: { offset: number, isStatic: boolean } } },
	currClasses: { number }?,
	inlineVarc: { boolean },
	loopJumpTypes: { number },
	loopJumpLabels: { number },
	loopJumpCount: number,
	loopLocalOffsets: { number },
	loopLocalOffsetsContinue: { number },
	loopContinueUsed: { number },
	loopDepth: number,
	inlineFrames: { InlineFrame },
	captureTypes: { number },
	captureData: { number },
	jumpListPool: { { number } },
	keyValMapPool: { { [number]: number } },
	concatPool: { { number } },
	assignScratchPool: { AssignScratch },
	scratchKeyValOrder: { number },
	scratchTableShape: BytecodeBuilder.TableShape,
	localUses: { [number]: number },
	freeCount: number,
	freeRegs: { number },
	freeAstLocals: { number },
	freeDebugPcs: { number },
	freeAllocPcs: { number },
	freeIsArgs: { boolean },
	curBlockOwner: number,
	curBlockBase: number,
	curBlockMinFinish: number,
	blockLiveCount: number,
	blockLiveLocalIds: { number },
	blockLiveStackIdx: { number },
	blockLiveFinishes: { number },
}

local raiseCompileError: (CompilerCtx, number, number, string) -> never
local allocReg: (CompilerCtx, number, number) -> number
local getLocalReg: (CompilerCtx, number) -> number
local getExprLocalReg: (CompilerCtx, number) -> number
local getUpval: (CompilerCtx, number) -> number
local setDebugLineOffset: (CompilerCtx, number) -> ()
local needsCoverage: (CompilerCtx, number) -> boolean
local boundHintTemporaryExprRegType: (CompilerCtx, number, number, number, number) -> ()
local patchJump: (CompilerCtx, number, number, number) -> ()
local patchJumps: (CompilerCtx, number, { number }, number) -> ()
local patchSkipCOrThrow: (CompilerCtx, any, number, number) -> ()
local boundCheckConstantNode: (CompilerCtx, number, number) -> ()
local isConstant: (CompilerCtx, number) -> boolean
local isConstantTrue: (CompilerCtx, number) -> boolean
local isConstantVector: (CompilerCtx, number) -> boolean
local getConstant: (CompilerCtx, number) -> (number, any)
local getConstantNumber: (CompilerCtx, number) -> number
local getConstantIndex: (CompilerCtx, number, number?, any?) -> number
local emitLoadK: (CompilerCtx, number, number) -> ()
local acquireJumpList: (CompilerCtx) -> { number }
local releaseJumpList: (CompilerCtx, { number }) -> ()
local acquireKeyValMap: (CompilerCtx) -> { [number]: number }
local releaseKeyValMap: (CompilerCtx, { [number]: number }) -> ()
local acquireConcatList: (CompilerCtx) -> { number }
local releaseConcatList: (CompilerCtx, { number }) -> ()
local getExportTableReg: (CompilerCtx, number) -> number
local closeLocals: (CompilerCtx, number) -> ()
local pushLocal: (CompilerCtx, number, number, number) -> ()
local popLocals: (CompilerCtx, number) -> ()
local tryInlineCallExpr: (CompilerCtx, number, any, number, number, boolean) -> boolean
local computePrivateFieldInfo: (CompilerCtx, number, number, number) -> (number, number, boolean)
local compilePrivateFieldAccess: (CompilerCtx, any, number, number, boolean?) -> ()

local function bind(deps: {
	raiseCompileError: (CompilerCtx, number, number, string) -> never,
	allocReg: (CompilerCtx, number, number) -> number,
	getLocalReg: (CompilerCtx, number) -> number,
	getExprLocalReg: (CompilerCtx, number) -> number,
	getUpval: (CompilerCtx, number) -> number,
	setDebugLineOffset: (CompilerCtx, number) -> (),
	needsCoverage: (CompilerCtx, number) -> boolean,
	hintTemporaryExprRegType: (CompilerCtx, number, number, number, number) -> (),
	patchJump: (CompilerCtx, number, number, number) -> (),
	patchJumps: (CompilerCtx, number, { number }, number) -> (),
	patchSkipCOrThrow: (CompilerCtx, any, number, number) -> (),
	checkConstantNode: (CompilerCtx, number, number) -> (),
	isConstant: (CompilerCtx, number) -> boolean,
	isConstantTrue: (CompilerCtx, number) -> boolean,
	isConstantVector: (CompilerCtx, number) -> boolean,
	getConstant: (CompilerCtx, number) -> (number, any),
	getConstantNumber: (CompilerCtx, number) -> number,
	getConstantIndex: (CompilerCtx, number, number?, any?) -> number,
	emitLoadK: (CompilerCtx, number, number) -> (),
	acquireJumpList: (CompilerCtx) -> { number },
	releaseJumpList: (CompilerCtx, { number }) -> (),
	acquireKeyValMap: (CompilerCtx) -> { [number]: number },
	releaseKeyValMap: (CompilerCtx, { [number]: number }) -> (),
	acquireConcatList: (CompilerCtx) -> { number },
	releaseConcatList: (CompilerCtx, { number }) -> (),
	getExportTableReg: (CompilerCtx, number) -> number,
	closeLocals: (CompilerCtx, number) -> (),
	pushLocal: (CompilerCtx, number, number, number) -> (),
	popLocals: (CompilerCtx, number) -> (),
	tryInlineCallExpr: (CompilerCtx, number, any, number, number, boolean) -> boolean,
	computePrivateFieldInfo: (CompilerCtx, number, number, number) -> (number, number, boolean),
	compilePrivateFieldAccess: (CompilerCtx, any, number, number, boolean?) -> (),
})
	raiseCompileError = deps.raiseCompileError
	allocReg = deps.allocReg
	getLocalReg = deps.getLocalReg
	getExprLocalReg = deps.getExprLocalReg
	getUpval = deps.getUpval
	setDebugLineOffset = deps.setDebugLineOffset
	needsCoverage = deps.needsCoverage
	boundHintTemporaryExprRegType = deps.hintTemporaryExprRegType
	patchJump = deps.patchJump
	patchJumps = deps.patchJumps
	patchSkipCOrThrow = deps.patchSkipCOrThrow
	boundCheckConstantNode = deps.checkConstantNode
	isConstant = deps.isConstant
	isConstantTrue = deps.isConstantTrue
	isConstantVector = deps.isConstantVector
	getConstant = deps.getConstant
	getConstantNumber = deps.getConstantNumber
	getConstantIndex = deps.getConstantIndex
	emitLoadK = deps.emitLoadK
	acquireJumpList = deps.acquireJumpList
	releaseJumpList = deps.releaseJumpList
	acquireKeyValMap = deps.acquireKeyValMap
	releaseKeyValMap = deps.releaseKeyValMap
	acquireConcatList = deps.acquireConcatList
	releaseConcatList = deps.releaseConcatList
	getExportTableReg = deps.getExportTableReg
	closeLocals = deps.closeLocals
	pushLocal = deps.pushLocal
	popLocals = deps.popLocals
	tryInlineCallExpr = deps.tryInlineCallExpr
	computePrivateFieldInfo = deps.computePrivateFieldInfo
	compilePrivateFieldAccess = deps.compilePrivateFieldAccess
end

@native
local function fastExprLocalReg(ctx: CompilerCtx, nodeId: number): number
	local k = ctx.kinds[nodeId]
	if k == K.AstExprLocal then
		local localId = ctx.nodes[nodeId]["local"]
		return if ctx.localAllocated[localId] then ctx.localReg[localId] else -1
	elseif k ~= K.AstExprGroup and k ~= K.AstExprTypeAssertion then
		return -1
	end
	return getExprLocalReg(ctx, nodeId)
end

@native
local function fastDebugLineOffset(ctx: CompilerCtx, offset: number)
	if ctx.debugLevel >= 1 then
		if offset >= ctx.lastLineStart and offset < ctx.lastLineEnd then
			ctx.bytecode.debugLine = ctx.lastLineNum
			return
		end
		setDebugLineOffset(ctx, offset)
	end
end

@native
local function fastDebugLine(ctx: CompilerCtx, nodeId: number)
	if ctx.debugLevel >= 1 and nodeId ~= 0 then
		local offset = ctx.starts[nodeId]
		if offset ~= nil then
			if offset >= ctx.lastLineStart and offset < ctx.lastLineEnd then
				ctx.bytecode.debugLine = ctx.lastLineNum
				return
			end
			setDebugLineOffset(ctx, offset)
		end
	end
end

@native
local function fastDebugLineEnd(ctx: CompilerCtx, nodeId: number)
	if ctx.debugLevel >= 1 and nodeId ~= 0 then
		local finish = ctx.finishes[nodeId]
		if finish ~= nil then
			if finish >= ctx.lastLineStart and finish < ctx.lastLineEnd then
				ctx.bytecode.debugLine = ctx.lastLineNum
				return
			end
			setDebugLineOffset(ctx, finish)
		end
	end
end

@native
local function getSymHash(ctx: CompilerCtx, symId: number, name: string): number
	local hashes = ctx.symbolHashes
	local h = hashes[symId]
	if h == nil then
		h = BytecodeBuilder.getStringHash(name)
		hashes[symId] = h
	end
	return h
end

@native
local function addConstantSym(ctx: CompilerCtx, symId: number): (number, number)
	local strRef = ctx.symbolStrRefs[symId]
	if strRef ~= nil then
		local h = ctx.symbolHashes[symId]
		if h ~= nil then
			return ctx.bytecode:addConstantStringRef(strRef), h
		end
	end
	local name = ctx.symbols[symId]
	local bc = ctx.bytecode
	if strRef == nil then
		strRef = bc:addStringTableEntry(name)
		ctx.symbolStrRefs[symId] = strRef
	end
	local h = ctx.symbolHashes[symId]
	if h == nil then
		h = BytecodeBuilder.getStringHash(name)
		ctx.symbolHashes[symId] = h
	end
	return bc:addConstantStringRef(strRef), h
end

@native
local function checkConstantNode(ctx: CompilerCtx, cid: number, nodeId: number)
	if cid < 0 then
		boundCheckConstantNode(ctx, cid, nodeId)
	end
end

@native
local function hintTemporaryExprRegType(
	ctx: CompilerCtx,
	exprId: number,
	reg: number,
	expectedType: number,
	instLength: number
)
	local ty = ctx.exprTypes[exprId]
	if ty ~= nil and ty ~= expectedType then
		boundHintTemporaryExprRegType(ctx, exprId, reg, expectedType, instLength)
	end
end

local compileExpr: (CompilerCtx, number, number, boolean?) -> ()
local compileExprTemp: (CompilerCtx, number, number) -> ()
local compileExprAutoTemp: (CompilerCtx, number, number, number?) -> number
local compileExprAuto: (CompilerCtx, number) -> number
local compileExprTempMultRet: (CompilerCtx, number, number) -> boolean
local compileExprTempTop: (CompilerCtx, number, number) -> ()
local compileExprVarargs: (CompilerCtx, number, number, number, boolean?) -> ()
local compileExprCall: (CompilerCtx, number, number, number, boolean?, boolean?) -> ()
local compileExprFunction: (CompilerCtx, number, number, number?) -> ()
local compileExprTable: (CompilerCtx, number, number, boolean, number) -> ()
local compileLValueIndexUnboxed: (CompilerCtx, number, number) -> (number, number, number, string?, number, number, number)
local compileLValueUnboxed: (CompilerCtx, number) -> (number, number, number, string?, number, number, number)
local compileLValueUseUnboxed: (
	CompilerCtx,
	number,
	number,
	number,
	string?,
	number,
	number,
	number,
	number,
	boolean,
	number
) -> ()

@native
local function getJumpOpCompare(op: string, notFlag: boolean): number
	if op == "CompareNe" then
		return if notFlag then Opcodes.LOP_JUMPIFEQ else Opcodes.LOP_JUMPIFNOTEQ
	elseif op == "CompareEq" then
		return if notFlag then Opcodes.LOP_JUMPIFNOTEQ else Opcodes.LOP_JUMPIFEQ
	elseif op == "CompareLt" or op == "CompareGt" then
		return if notFlag then Opcodes.LOP_JUMPIFNOTLT else Opcodes.LOP_JUMPIFLT
	elseif op == "CompareLe" or op == "CompareGe" then
		return if notFlag then Opcodes.LOP_JUMPIFNOTLE else Opcodes.LOP_JUMPIFLE
	end
	return Opcodes.LOP_NOP
end

@native
local function encodeHashSize(hashSize: number): number
	if hashSize == 0 then
		return 0
	end
	local hashSizeLog2 = 0
	while bit32.lshift(1, hashSizeLog2) < hashSize do
		hashSizeLog2 += 1
	end
	return hashSizeLog2 + 1
end

local function escapePercent(s: string): string
	if string.find(s, "%", 1, true) then
		return (string.gsub(s, "%%", "%%%%"))
	end
	return s
end

@native
local function moveCallResults(ctx: CompilerCtx, target: number, regs: number, targetCount: number)
	local bytecode = ctx.bytecode
	for i = 0, targetCount - 1 do
		bytecode:emitABC(Opcodes.LOP_MOVE, target + i, regs + i, 0)
	end
end

@native
local function tryIndexConstantTable(ctx: CompilerCtx, exprId: number): number
	local expr = ctx.nodes[exprId]
	local tableLocalId = CompilerFolding.unwrapExprOfType(ctx.arena, expr.expr, K.AstExprLocal)
	if tableLocalId == 0 then
		return 0
	end
	local localId = ctx.nodes[tableLocalId]["local"]
	if ctx.vars.owner[localId] == nil or ctx.vars.written[localId] then
		return 0
	end
	local initId = ctx.vars.init[localId]
	if initId == 0 then
		return 0
	end
	local tableKind = ctx.tableConstants[localId]
	if tableKind ~= CompilerFolding.TableConstantKind.ConstantTable then
		return 0
	end
	local tblId = CompilerFolding.unwrapExprOfType(ctx.arena, initId, K.AstExprTable)
	if tblId == 0 then
		return 0
	end
	local tblNode = ctx.nodes[tblId]
	if tblNode.items == 0 then
		return 0
	end
	local itemsFirst = ctx.listFirsts[tblNode.items]
	local itemsCount = ctx.listCounts[tblNode.items]
	local indexStr = ctx.symbols[expr.index]
	local listValues = ctx.listValues
	local constTypes = ctx.constTypes
	local constVals = ctx.constVals
	local match = 0
	for i = 0, itemsCount - 1 do
		local item = listValues[itemsFirst + i]
		if item.kind == "Record" or item.kind == "General" then
			local kt = constTypes[item.key]
			if kt == nil or kt == ConstantType.Unknown then
				match = 0
			elseif kt == ConstantType.String then
				local ks = (constVals[item.key] :: string?) or ""
				if #ks ~= 0 and ks == indexStr then
					match = item.value
				end
			end
		end
	end
	return match
end

@native
local function getFunctionExpr(ctx: CompilerCtx, nodeId: number): number
	local k = ctx.kinds[nodeId]
	if k == K.AstExprLocal then
		local localId = ctx.nodes[nodeId]["local"]
		if ctx.vars.owner[localId] == nil or ctx.vars.written[localId] then
			return 0
		end
		local initId = ctx.vars.init[localId]
		if initId == 0 then
			return 0
		end
		return getFunctionExpr(ctx, initId)
	elseif k == K.AstExprIndexName then
		local node = ctx.nodes[nodeId]
		if not ctx.flagDebugClasses or not node.privateAccess then
			local valueId = tryIndexConstantTable(ctx, nodeId)
			if valueId ~= 0 then
				return getFunctionExpr(ctx, valueId)
			end
		end
		return 0
	elseif k == K.AstExprGroup or k == K.AstExprTypeAssertion or k == K.AstExprInstantiate then
		return getFunctionExpr(ctx, ctx.nodes[nodeId].expr)
	elseif k == K.AstExprFunction then
		return nodeId
	else
		return 0
	end
end

@native
local function isExprMultRet(ctx: CompilerCtx, nodeId: number): boolean
	local k = ctx.kinds[nodeId]
	if k ~= K.AstExprCall then
		return k == K.AstExprVarargs
	end
	if ctx.optimizationLevel <= 1 then
		return true
	end
	if isConstant(ctx, nodeId) then
		return false
	end
	if ctx.optimizationLevel >= 2 then
		local bfid = ctx.builtins[nodeId]
		if bfid and bfid ~= Builtins.LBF_NONE then
			return CompilerBuiltins.getBuiltinInfo(bfid).results ~= 1
		end
	end
	local funcId = getFunctionExpr(ctx, ctx.nodes[nodeId].func)
	local fi = if funcId ~= 0 then ctx.functions[funcId] else nil
	if fi and fi.returnsOne then
		return false
	end
	return true
end

@native
local function compileCompareJump(ctx: CompilerCtx, exprId: number, not_: boolean?): number
	local isNot = not_ == true
	local oldTop = ctx.regTop
	local expr = ctx.nodes[exprId]
	local op = expr.op
	local isEq = op == "CompareEq" or op == "CompareNe"
	local leftId = expr.left
	local rightId = expr.right

	local operandIsConstant = isConstant(ctx, rightId)
	if isEq and not operandIsConstant then
		operandIsConstant = isConstant(ctx, leftId)
		if operandIsConstant then
			leftId, rightId = rightId, leftId
		end
	end

	if operandIsConstant and isConstantVector(ctx, rightId) then
		operandIsConstant = false
	end

	local rl = compileExprAuto(ctx, leftId)

	if isEq and operandIsConstant then
		local ct = ctx.constTypes[rightId]
		local opc = Opcodes.LOP_NOP
		local cid = -1
		local flip = if (op == "CompareEq") == isNot then 0x80000000 else 0

		if ct == ConstantType.Nil then
			opc = Opcodes.LOP_JUMPXEQKNIL
			cid = 0
		elseif ct == ConstantType.Boolean then
			opc = Opcodes.LOP_JUMPXEQKB
			cid = if ctx.constVals[rightId] then 1 else 0
		elseif ct == ConstantType.Number then
			opc = Opcodes.LOP_JUMPXEQKN
			cid = getConstantIndex(ctx, rightId)
		elseif ct == ConstantType.String then
			opc = Opcodes.LOP_JUMPXEQKS
			cid = getConstantIndex(ctx, rightId)
		else
			error("Unexpected constant type")
		end

		checkConstantNode(ctx, cid, exprId)

		local bc = ctx.bytecode
		local jumpLabel = bcbEmitLabel(bc)
		bcbEmitAD(bc, opc, rl, 0)
		bcbEmitAux(bc, bit32.bor(cid, flip))
		ctx.regTop = oldTop
		return jumpLabel
	else
		local opc = getJumpOpCompare(op, isNot)
		local rr = compileExprAuto(ctx, rightId)
		local bc = ctx.bytecode
		local jumpLabel = bcbEmitLabel(bc)
		if op == "CompareGt" or op == "CompareGe" then
			bcbEmitAD(bc, opc, rr, 0)
			bcbEmitAux(bc, rl)
		else
			bcbEmitAD(bc, opc, rl, 0)
			bcbEmitAux(bc, rr)
		end
		ctx.regTop = oldTop
		return jumpLabel
	end
end

@native
local function compileConditionValue(
	ctx: CompilerCtx,
	nodeId: number,
	target: number?,
	skipJump: { number },
	onlyTruth: boolean
)
	local ct = ctx.constTypes[nodeId]
	if ct ~= nil and ct ~= ConstantType.Unknown then
		if CompilerFolding.isTruthfulVal(ct, ctx.constVals[nodeId]) == onlyTruth then
			if target ~= nil then
				compileExprTemp(ctx, nodeId, target)
			end
			local bc = ctx.bytecode
			skipJump[#skipJump + 1] = bcbEmitLabel(bc)
			bcbEmitAD(bc, Opcodes.LOP_JUMP, 0, 0)
		end
		return
	end

	local node = ctx.nodes[nodeId]
	local k = ctx.kinds[nodeId]
	if k == K.AstExprBinary then
		local op = node.op
		if op == "And" or op == "Or" then
			if onlyTruth == (op == "And") then
				local elseJump = acquireJumpList(ctx)
				compileConditionValue(ctx, node.left, nil, elseJump, not onlyTruth)
				compileConditionValue(ctx, node.right, target, skipJump, onlyTruth)
				local elseLabel = ctx.bytecode:emitLabel()
				patchJumps(ctx, nodeId, elseJump, elseLabel)
				releaseJumpList(ctx, elseJump)
			else
				compileConditionValue(ctx, node.left, target, skipJump, onlyTruth)
				compileConditionValue(ctx, node.right, target, skipJump, onlyTruth)
			end
			return
		elseif
			op == "CompareNe"
			or op == "CompareEq"
			or op == "CompareLt"
			or op == "CompareLe"
			or op == "CompareGt"
			or op == "CompareGe"
		then
			if target ~= nil then
				ctx.bytecode:emitABC(Opcodes.LOP_LOADB, target, if onlyTruth then 1 else 0, 0)
			end
			skipJump[#skipJump + 1] = compileCompareJump(ctx, nodeId, not onlyTruth)
			return
		end
	elseif k == K.AstExprUnary then
		if target == nil and node.op == "Not" then
			compileConditionValue(ctx, node.expr, target, skipJump, not onlyTruth)
			return
		end
	elseif k == K.AstExprGroup then
		compileConditionValue(ctx, node.expr, target, skipJump, onlyTruth)
		return
	end

	local oldTop = ctx.regTop
	local reg: number
	if target ~= nil then
		reg = target
		compileExprTemp(ctx, nodeId, reg)
	else
		reg = compileExprAuto(ctx, nodeId)
	end
	skipJump[#skipJump + 1] = ctx.bytecode:emitLabel()
	ctx.bytecode:emitAD(if onlyTruth then Opcodes.LOP_JUMPIF else Opcodes.LOP_JUMPIFNOT, reg, 0)
	ctx.regTop = oldTop
end

@native
local function isConditionFast(ctx: CompilerCtx, nodeId: number): boolean
	local ct = ctx.constTypes[nodeId]
	if ct ~= nil and ct ~= ConstantType.Unknown then
		return true
	end
	local k = ctx.kinds[nodeId]
	if k == K.AstExprBinary then
		local op = ctx.nodes[nodeId].op
		return op == "And"
			or op == "Or"
			or op == "CompareNe"
			or op == "CompareEq"
			or op == "CompareLt"
			or op == "CompareLe"
			or op == "CompareGt"
			or op == "CompareGe"
	elseif k == K.AstExprGroup then
		return isConditionFast(ctx, ctx.nodes[nodeId].expr)
	end
	return false
end

@native
local function compileExprAndOr(ctx: CompilerCtx, exprId: number, target: number, targetTemp: boolean)
	local expr = ctx.nodes[exprId]
	local and_ = expr.op == "And"
	local oldTop = ctx.regTop

	local clt = ctx.constTypes[expr.left]
	if clt ~= nil and clt ~= ConstantType.Unknown then
		compileExpr(
			ctx,
			if and_ == CompilerFolding.isTruthfulVal(clt, ctx.constVals[expr.left]) then expr.right else expr.left,
			target,
			targetTemp
		)
		ctx.regTop = oldTop
		return
	end

	if not isConditionFast(ctx, expr.left) then
		local reg = fastExprLocalReg(ctx, expr.right)
		if reg >= 0 then
			local lr = compileExprAuto(ctx, expr.left)
			ctx.bytecode:emitABC(if and_ then Opcodes.LOP_AND else Opcodes.LOP_OR, target, lr, reg)
			ctx.regTop = oldTop
			return
		end

		local cid = getConstantIndex(ctx, expr.right)
		if cid >= 0 and cid <= 255 then
			local lr = compileExprAuto(ctx, expr.left)
			ctx.bytecode:emitABC(if and_ then Opcodes.LOP_ANDK else Opcodes.LOP_ORK, target, lr, cid)
			ctx.regTop = oldTop
			return
		end
	end

	local reg = if targetTemp then target else allocReg(ctx, exprId, 1)
	local skipJump = acquireJumpList(ctx)
	compileConditionValue(ctx, expr.left, reg, skipJump, not and_)
	compileExprTemp(ctx, expr.right, reg)
	local moveLabel = ctx.bytecode:emitLabel()
	patchJumps(ctx, exprId, skipJump, moveLabel)
	releaseJumpList(ctx, skipJump)
	if target ~= reg then
		ctx.bytecode:emitABC(Opcodes.LOP_MOVE, target, reg, 0)
	end
	ctx.regTop = oldTop
end

@native
local function compileExprUnary(ctx: CompilerCtx, exprId: number, target: number)
	local oldTop = ctx.regTop
	local expr = ctx.nodes[exprId]
	local re = compileExprAuto(ctx, expr.expr)
	ctx.bytecode:emitABC(UNARY_OPS[expr.op], target, re, 0)
	ctx.regTop = oldTop
end

@native
local function unrollConcats(ctx: CompilerCtx, args: { number })
	local nodes = ctx.nodes
	local kinds = ctx.kinds
	while true do
		local n = #args
		local backId = args[n]
		if kinds[backId] ~= K.AstExprBinary then
			break
		end
		local be = nodes[backId]
		if be.op ~= "Concat" then
			break
		end
		args[n] = be.left
		args[n + 1] = be.right
	end
end

@native
local function compileExprBinary(ctx: CompilerCtx, exprId: number, target: number, targetTemp: boolean)
	local oldTop = ctx.regTop
	local expr = ctx.nodes[exprId]
	local op = expr.op
	if op == "Add" or op == "Sub" or op == "Mul" or op == "Div" or op == "FloorDiv" or op == "Mod" or op == "Pow" then
		local rc = getConstantNumber(ctx, expr.right)
		if rc >= 0 and rc <= 255 then
			local rl = compileExprAuto(ctx, expr.left)
			ctx.bytecode:emitABC(BINARY_ARITHK_OPS[op], target, rl, rc)
			hintTemporaryExprRegType(ctx, expr.left, rl, Types.LBC_TYPE_NUMBER, 1)
		else
			if op == "Sub" or op == "Div" then
				local lc = getConstantNumber(ctx, expr.left)
				if lc >= 0 and lc <= 255 then
					local rr = compileExprAuto(ctx, expr.right)
					local opc = if op == "Sub" then Opcodes.LOP_SUBRK else Opcodes.LOP_DIVRK
					ctx.bytecode:emitABC(opc, target, lc, rr)
					hintTemporaryExprRegType(ctx, expr.right, rr, Types.LBC_TYPE_NUMBER, 1)
					ctx.regTop = oldTop
					return
				end
			elseif ctx.optimizationLevel >= 2 and (op == "Add" or op == "Mul") then
				local ty = ctx.exprTypes[exprId]
				if ty == Types.LBC_TYPE_NUMBER or (ty == Types.LBC_TYPE_VECTOR and op == "Mul") then
					local lc = getConstantNumber(ctx, expr.left)
					if lc >= 0 and lc <= 255 then
						local rr = compileExprAuto(ctx, expr.right)
						ctx.bytecode:emitABC(BINARY_ARITHK_OPS[op], target, rr, lc)
						hintTemporaryExprRegType(ctx, expr.right, rr, Types.LBC_TYPE_NUMBER, 1)
						ctx.regTop = oldTop
						return
					end
				end
			end

			local rl = compileExprAuto(ctx, expr.left)
			local rr = compileExprAuto(ctx, expr.right)
			ctx.bytecode:emitABC(BINARY_ARITH_OPS[op], target, rl, rr)
			hintTemporaryExprRegType(ctx, expr.left, rl, Types.LBC_TYPE_NUMBER, 1)
			hintTemporaryExprRegType(ctx, expr.right, rr, Types.LBC_TYPE_NUMBER, 1)
		end
	elseif op == "Concat" then
		local args = acquireConcatList(ctx)
		args[1] = expr.left
		args[2] = expr.right
		unrollConcats(ctx, args)
		local argc = #args
		local regs = allocReg(ctx, exprId, argc)
		for i = 1, argc do
			compileExprTempTop(ctx, args[i], regs + i - 1)
		end
		releaseConcatList(ctx, args)
		ctx.bytecode:emitABC(Opcodes.LOP_CONCAT, target, regs, regs + argc - 1)
	elseif
		op == "CompareNe"
		or op == "CompareEq"
		or op == "CompareLt"
		or op == "CompareLe"
		or op == "CompareGt"
		or op == "CompareGe"
	then
		local jumpLabel = compileCompareJump(ctx, exprId, false)
		ctx.bytecode:emitABC(Opcodes.LOP_LOADB, target, 0, 1)
		local thenLabel = ctx.bytecode:emitLabel()
		ctx.bytecode:emitABC(Opcodes.LOP_LOADB, target, 1, 0)
		patchJump(ctx, exprId, jumpLabel, thenLabel)
	elseif op == "And" or op == "Or" then
		compileExprAndOr(ctx, exprId, target, targetTemp)
	else
		error("Unexpected binary operation")
	end
	ctx.regTop = oldTop
end

local function compileExprIfElseAndOr(ctx: CompilerCtx, and_: boolean, creg: number, otherId: number, target: number)
	local cid = getConstantIndex(ctx, otherId)
	if cid >= 0 and cid <= 255 then
		ctx.bytecode:emitABC(if and_ then Opcodes.LOP_ANDK else Opcodes.LOP_ORK, target, creg, cid)
	else
		local oldTop = ctx.regTop
		local oreg = compileExprAuto(ctx, otherId)
		ctx.bytecode:emitABC(if and_ then Opcodes.LOP_AND else Opcodes.LOP_OR, target, creg, oreg)
		ctx.regTop = oldTop
	end
end

local function compileExprIfElseLocal(ctx: CompilerCtx, exprId: number, target: number, targetTemp: boolean)
	local expr = ctx.nodes[exprId]
	local skipElse = isConstantTrue(ctx, expr.condition)
	local oldLocals = #ctx.localStack
	local elseJump = 0

	do
		local oldTop = ctx.regTop
		local reg = allocReg(ctx, exprId, 1)
		local allocpc = ctx.bytecode.insnCount

		compileExprTemp(ctx, expr.condition, reg)
		pushLocal(ctx, expr.conditionLocal, reg, allocpc)

		if not skipElse then
			elseJump = ctx.bytecode:emitLabel()
			ctx.bytecode:emitAD(Opcodes.LOP_JUMPIFNOT, reg, 0)
		end

		compileExpr(ctx, expr.trueExpr, target, targetTemp)

		closeLocals(ctx, oldLocals)
		popLocals(ctx, oldLocals)
		ctx.regTop = oldTop
	end

	if skipElse then
		return
	end

	local thenLabel = ctx.bytecode:emitLabel()
	ctx.bytecode:emitAD(Opcodes.LOP_JUMP, 0, 0)

	local elseLabel = ctx.bytecode:emitLabel()
	compileExpr(ctx, expr.falseExpr, target, targetTemp)
	local endLabel = ctx.bytecode:emitLabel()

	patchJump(ctx, exprId, elseJump, elseLabel)
	patchJump(ctx, exprId, thenLabel, endLabel)
end

local function compileExprIfElse(ctx: CompilerCtx, exprId: number, target: number, targetTemp: boolean)
	local expr = ctx.nodes[exprId]
	if ctx.flagExpIfLocal and expr.conditionLocal and expr.conditionLocal ~= 0 then
		compileExprIfElseLocal(ctx, exprId, target, targetTemp)
		return
	end

	if isConstant(ctx, expr.condition) then
		if isConstantTrue(ctx, expr.condition) then
			compileExpr(ctx, expr.trueExpr, target, targetTemp)
		else
			compileExpr(ctx, expr.falseExpr, target, targetTemp)
		end
	else
		local creg = fastExprLocalReg(ctx, expr.condition)
		if creg >= 0 then
			if
				creg == fastExprLocalReg(ctx, expr.trueExpr)
				and (fastExprLocalReg(ctx, expr.falseExpr) >= 0 or isConstant(ctx, expr.falseExpr))
			then
				compileExprIfElseAndOr(ctx, false, creg, expr.falseExpr, target)
				return
			elseif
				creg == fastExprLocalReg(ctx, expr.falseExpr)
				and (fastExprLocalReg(ctx, expr.trueExpr) >= 0 or isConstant(ctx, expr.trueExpr))
			then
				compileExprIfElseAndOr(ctx, true, creg, expr.trueExpr, target)
				return
			end
		end

		local elseJump = acquireJumpList(ctx)
		compileConditionValue(ctx, expr.condition, nil, elseJump, false)
		compileExpr(ctx, expr.trueExpr, target, targetTemp)

		local thenLabel = ctx.bytecode:emitLabel()
		ctx.bytecode:emitAD(Opcodes.LOP_JUMP, 0, 0)

		local elseLabel = ctx.bytecode:emitLabel()
		compileExpr(ctx, expr.falseExpr, target, targetTemp)
		local endLabel = ctx.bytecode:emitLabel()

		patchJumps(ctx, exprId, elseJump, elseLabel)
		releaseJumpList(ctx, elseJump)
		patchJump(ctx, exprId, thenLabel, endLabel)
	end
end

local function compileExprInterpString(ctx: CompilerCtx, exprId: number, target: number, targetTemp: boolean)
	local expr = ctx.nodes[exprId]
	local strFirst = if expr.strings ~= 0 then ctx.listFirsts[expr.strings] else 0
	local strCount = if expr.strings ~= 0 then ctx.listCounts[expr.strings] else 0
	local expFirst = if expr.expressions ~= 0 then ctx.listFirsts[expr.expressions] else 0
	local expCount = if expr.expressions ~= 0 then ctx.listCounts[expr.expressions] else 0
	local listValues = ctx.listValues
	local constTypes = ctx.constTypes
	local constVals = ctx.constVals

	local skippedSubExpr = 0
	for i = 0, expCount - 1 do
		if constTypes[listValues[expFirst + i]] == ConstantType.String then
			skippedSubExpr += 1
		end
	end

	local parts = table.create(strCount + expCount)
	local p = 0
	for idx = 0, strCount - 1 do
		p += 1
		parts[p] = escapePercent(listValues[strFirst + idx])
		if idx < expCount then
			local subId = listValues[expFirst + idx]
			p += 1
			if constTypes[subId] == ConstantType.String then
				parts[p] = escapePercent((constVals[subId] :: string?) or "")
			else
				parts[p] = "%*"
			end
		end
	end

	local formatString = table.concat(parts)
	local formatStringIndex = bcbAddConstStr(ctx.bytecode, formatString)
	checkConstantNode(ctx, formatStringIndex, exprId)

	local oldTop = ctx.regTop
	local regCount = 2 + expCount - skippedSubExpr
	local targetTop = targetTemp and target == ctx.regTop - 1
	local baseReg = if targetTop then allocReg(ctx, exprId, regCount - 1) - 1 else allocReg(ctx, exprId, regCount)

	emitLoadK(ctx, baseReg, formatStringIndex)

	local skipped = 0
	for idx = 0, expCount - 1 do
		local subExprId = listValues[expFirst + idx]
		if constTypes[subExprId] ~= ConstantType.String then
			compileExprTempTop(ctx, subExprId, baseReg + 2 + idx - skipped)
		else
			skipped += 1
		end
	end

	local bc = ctx.bytecode
	local formatMethodIndex = bcbAddConstStr(bc, "format")
	checkConstantNode(ctx, formatMethodIndex, exprId)

	bcbEmitABC(bc, Opcodes.LOP_NAMECALL, baseReg, baseReg, FORMAT_HASH)
	bcbEmitAux(bc, formatMethodIndex)
	bcbEmitABC(bc, Opcodes.LOP_CALL, baseReg, expCount + 2 - skippedSubExpr, 2)
	if target ~= baseReg then
		bcbEmitABC(bc, Opcodes.LOP_MOVE, target, baseReg, 0)
	end
	ctx.regTop = oldTop
end

local function countTableShape(
	ctx: CompilerCtx,
	itemsFirst: number,
	itemCount: number
): (number, number, number, number)
	local arraySize = 0
	local hashSize = 0
	local recordSize = 0
	local indexSize = 0
	local listValues = ctx.listValues

	for i = 0, itemCount - 1 do
		local item = listValues[itemsFirst + i]
		if item.kind == "List" then
			arraySize += 1
		else
			hashSize += 1
			if item.kind == "Record" then
				recordSize += 1
			end
		end
	end

	if arraySize == 0 and hashSize > 0 then
		local constTypes = ctx.constTypes
		local constVals = ctx.constVals
		for i = 0, itemCount - 1 do
			local item = listValues[itemsFirst + i]
			if constTypes[item.key] == ConstantType.Number and constVals[item.key] == indexSize + 1 then
				indexSize += 1
			end
		end
		if hashSize == recordSize + indexSize then
			hashSize = recordSize
		else
			indexSize = 0
		end
	end

	return arraySize, hashSize, recordSize, indexSize
end

local function tryEmitTableTemplate(
	ctx: CompilerCtx,
	exprId: number,
	reg: number,
	constructReg: number,
	itemsFirst: number,
	itemCount: number,
	hashSize: number,
	encodedHashSize: number
): ({ [number]: number }, boolean)
	local lastKeyValMap = acquireKeyValMap(ctx)
	local lastKeyValOrder = ctx.scratchKeyValOrder
	table.clear(lastKeyValOrder)
	local listValues = ctx.listValues
	local nodes = ctx.nodes
	local bytecode = ctx.bytecode

	for i = 0, itemCount - 1 do
		local item = listValues[itemsFirst + i]
		local ckey = nodes[item.key]
		local keyCid = bytecode:addConstantString(ckey.value)
		checkConstantNode(ctx, keyCid, item.key)

		local valueCid = getConstantIndex(ctx, item.value)
		if lastKeyValMap[keyCid] ~= nil and lastKeyValMap[keyCid] == -1 then
			continue
		end
		if lastKeyValMap[keyCid] == nil then
			lastKeyValOrder[#lastKeyValOrder + 1] = keyCid
		end
		lastKeyValMap[keyCid] = valueCid
	end

	local shapeLength = #lastKeyValOrder
	local hasLastKeyVal = shapeLength > 0
	local scratchShape = ctx.scratchTableShape
	local shapeKeys = scratchShape.keys
	local shapeConstants = scratchShape.constants
	local shapeHasConstants = false

	for i = 1, shapeLength do
		local keyCid = lastKeyValOrder[i]
		local valueCid = lastKeyValMap[keyCid]
		shapeKeys[i] = keyCid
		shapeConstants[i] = valueCid
		if valueCid >= 0 then
			shapeHasConstants = true
		end
	end
	table.clear(lastKeyValOrder)

	scratchShape.length = shapeLength
	scratchShape.hasConstants = shapeHasConstants
	local tid = bytecode:addConstantTable(scratchShape)
	checkConstantNode(ctx, tid, exprId)

	if bytecode:needsDebugRemarks() then
		bytecode:addDebugRemark(string.format("allocation: table template %d", hashSize))
	end

	if ctx.flagDebugClasses and constructReg ~= kInvalidReg then
		local fbSlot = bytecode:addConstructSlot(tid)
		bytecode:emitABC(Opcodes.LOP_CONSTRUCT, reg, constructReg, 0)
		bytecode:emitAux(fbSlot)
	elseif tid < 32768 then
		bytecode:emitAD(Opcodes.LOP_DUPTABLE, reg, tid)
	else
		table.clear(lastKeyValMap)
		hasLastKeyVal = false
		bytecode:emitABC(Opcodes.LOP_NEWTABLE, reg, encodedHashSize, 0)
		bytecode:emitAux(0)
	end

	return lastKeyValMap, hasLastKeyVal
end

local function emitNewTableAlloc(
	ctx: CompilerCtx,
	reg: number,
	itemsFirst: number,
	itemCount: number,
	arraySize: number,
	hashSize: number,
	indexSize: number,
	encodedHashSize: number
)
	local lastItem = if itemCount > 0 then ctx.listValues[itemsFirst + itemCount - 1] else nil
	local trailingVarargs = lastItem ~= nil
		and lastItem.kind == "List"
		and ctx.kinds[lastItem.value] == K.AstExprVarargs
	local arrayAllocation = arraySize - (if trailingVarargs then 1 else 0) + indexSize

	if ctx.bytecode:needsDebugRemarks() then
		if hashSize == 0 then
			ctx.bytecode:addDebugRemark(string.format("allocation: table array %d", arrayAllocation))
		elseif arrayAllocation == 0 then
			ctx.bytecode:addDebugRemark(string.format("allocation: table hash %d", hashSize))
		else
			ctx.bytecode:addDebugRemark(string.format("allocation: table hash %d array %d", hashSize, arrayAllocation))
		end
	end

	ctx.bytecode:emitABC(Opcodes.LOP_NEWTABLE, reg, encodedHashSize, 0)
	ctx.bytecode:emitAux(arrayAllocation)
end

local function populateTableItems(
	ctx: CompilerCtx,
	exprId: number,
	reg: number,
	itemsFirst: number,
	itemCount: number,
	arraySize: number,
	lastKeyValMap: { [number]: number }?,
	hasLastKeyVal: boolean
)
	local arrayChunkSize = math.min(16, arraySize)
	local arrayChunkReg = allocReg(ctx, exprId, arrayChunkSize)
	local arrayChunkCurrent = 0
	local arrayIndex = 1
	local multRet = false
	local listValues = ctx.listValues
	local nodes = ctx.nodes
	local bytecode = ctx.bytecode

	for i = 0, itemCount - 1 do
		local item = listValues[itemsFirst + i]
		local keyId = item.key
		local valueId = item.value

		if hasLastKeyVal and lastKeyValMap ~= nil and keyId ~= 0 and ctx.kinds[keyId] == K.AstExprConstantString then
			local ckey = nodes[keyId]
			local keyCid = bytecode:addConstantString(ckey.value)
			local valueCid = lastKeyValMap[keyCid]
			if valueCid ~= nil and valueCid >= 0 then
				continue
			end
		end

		fastDebugLine(ctx, valueId)
		if ctx.coverageLevel >= 2 then
			bytecode:emitABC(Opcodes.LOP_COVERAGE, 0, 0, 0)
		end

		if arrayChunkCurrent > 0 and (keyId ~= 0 or arrayChunkCurrent == arrayChunkSize) then
			bytecode:emitABC(Opcodes.LOP_SETLIST, reg, arrayChunkReg, arrayChunkCurrent + 1)
			bytecode:emitAux(arrayIndex)
			arrayIndex += arrayChunkCurrent
			arrayChunkCurrent = 0
		end

		if keyId ~= 0 then
			local rsiTop = ctx.regTop
			local lvKind, lvReg, lvAux, lvName, lvSymId, lvStart, lvFinish = compileLValueIndexUnboxed(ctx, reg, keyId)
			local rv = compileExprAuto(ctx, valueId)
			compileLValueUseUnboxed(ctx, lvKind, lvReg, lvAux, lvName, lvSymId, lvStart, lvFinish, rv, true, 0)
			ctx.regTop = rsiTop
		else
			local temp = arrayChunkReg + arrayChunkCurrent
			if i + 1 == itemCount then
				multRet = compileExprTempMultRet(ctx, valueId, temp)
			else
				compileExprTempTop(ctx, valueId, temp)
			end
			arrayChunkCurrent += 1
		end
	end

	if arrayChunkCurrent > 0 then
		bytecode:emitABC(Opcodes.LOP_SETLIST, reg, arrayChunkReg, if multRet then 0 else arrayChunkCurrent + 1)
		bytecode:emitAux(arrayIndex)
	end
end

function compileExprTable(ctx: CompilerCtx, exprId: number, target: number, targetTemp: boolean, constructReg: number)
	local expr = ctx.nodes[exprId]
	local itemsFirst = if expr.items ~= 0 then ctx.listFirsts[expr.items] else 0
	local itemCount = if expr.items ~= 0 then ctx.listCounts[expr.items] else 0
	if itemCount == 0 then
		local shape = ctx.tableShapes[exprId] or EMPTY_TABLE_SHAPE
		if ctx.bytecode:needsDebugRemarks() then
			ctx.bytecode:addDebugRemark(string.format("allocation: table hash %d", shape.hashSize))
		end
		ctx.bytecode:emitABC(Opcodes.LOP_NEWTABLE, target, encodeHashSize(shape.hashSize), 0)
		ctx.bytecode:emitAux(shape.arraySize)
		return
	end

	local arraySize, hashSize, recordSize, indexSize = countTableShape(ctx, itemsFirst, itemCount)
	local encodedHashSize = encodeHashSize(hashSize)
	local oldTop = ctx.regTop
	local reg = if targetTemp then target else allocReg(ctx, exprId, 1)

	local lastKeyValMap: { [number]: number }? = nil
	local hasLastKeyVal = false

	if arraySize == 0 and indexSize == 0 and hashSize == recordSize and recordSize >= 1 and recordSize <= 32 then
		lastKeyValMap, hasLastKeyVal =
			tryEmitTableTemplate(ctx, exprId, reg, constructReg, itemsFirst, itemCount, hashSize, encodedHashSize)
	else
		emitNewTableAlloc(ctx, reg, itemsFirst, itemCount, arraySize, hashSize, indexSize, encodedHashSize)
	end

	populateTableItems(ctx, exprId, reg, itemsFirst, itemCount, arraySize, lastKeyValMap, hasLastKeyVal)
	if lastKeyValMap ~= nil then
		releaseKeyValMap(ctx, lastKeyValMap)
	end

	if target ~= reg then
		ctx.bytecode:emitABC(Opcodes.LOP_MOVE, target, reg, 0)
	end
	ctx.regTop = oldTop
end

local function canImport(ctx: CompilerCtx, exprId: number): boolean
	return ctx.optimizationLevel >= 1
		and CompilerBuiltins.getGlobalState(ctx.globals, ctx.nodes[exprId].name) ~= GlobalState.Written
end

local function canImportChain(ctx: CompilerCtx, exprId: number): boolean
	return ctx.optimizationLevel >= 1
		and CompilerBuiltins.getGlobalState(ctx.globals, ctx.nodes[exprId].name) == GlobalState.Default
end

@native
local function compileExprIndexName(ctx: CompilerCtx, exprId: number, target: number, targetTemp: boolean?)
	local isTargetTemp = targetTemp == true
	fastDebugLine(ctx, exprId)
	local expr = ctx.nodes[exprId]

	local importRootId = 0
	local import1Id = 0
	local import2Id = 0

	local kinds = ctx.kinds
	local innerKind = kinds[expr.expr]
	if innerKind == K.AstExprIndexName then
		local inner = ctx.nodes[expr.expr]
		if kinds[inner.expr] == K.AstExprGlobal then
			importRootId = inner.expr
			import1Id = expr.expr
			import2Id = exprId
		end
	elseif innerKind == K.AstExprGlobal then
		importRootId = expr.expr
		import1Id = exprId
	end

	if importRootId ~= 0 and canImportChain(ctx, importRootId) then
		if
			ctx.flagDebugClasses
			and (ctx.nodes[import1Id].privateAccess or (import2Id ~= 0 and ctx.nodes[import2Id].privateAccess))
		then
			raiseCompileError(ctx, expr.start, expr.finish, "Attempt to access private field of a global")
		end
		local id0 = ctx.bytecode:addConstantString(ctx.symbols[ctx.nodes[importRootId].name])
		local id1 = ctx.bytecode:addConstantString(ctx.symbols[ctx.nodes[import1Id].index])
		local id2 = if import2Id ~= 0
			then ctx.bytecode:addConstantString(ctx.symbols[ctx.nodes[import2Id].index])
			else -1

		if id0 < 0 or id1 < 0 or (import2Id ~= 0 and id2 < 0) then
			raiseCompileError(ctx, expr.start, expr.finish, "Exceeded constant limit; simplify the code to compile")
		end

		if id0 < 1024 and id1 < 1024 and id2 < 1024 then
			local iid = if import2Id ~= 0
				then BytecodeBuilder.getImportId(id0, id1, id2)
				else BytecodeBuilder.getImportId(id0, id1)
			local cid = ctx.bytecode:addImport(iid)
			if cid >= 0 and cid < 32768 then
				ctx.bytecode:emitAD(Opcodes.LOP_GETIMPORT, target, cid)
				ctx.bytecode:emitAux(iid)
				return
			end
		end
	end

	local oldTop = ctx.regTop
	local reg = target
	local localReg = fastExprLocalReg(ctx, expr.expr)
	if localReg >= 0 then
		reg = localReg
	elseif isTargetTemp then
		reg = compileExprAutoTemp(ctx, expr.expr, target)
	else
		reg = compileExprAuto(ctx, expr.expr)
	end

	fastDebugLineOffset(ctx, expr.indexStart or expr.start)

	if ctx.flagDebugClasses and expr.privateAccess then
		compilePrivateFieldAccess(ctx, expr, target, reg, false)
		ctx.regTop = oldTop
		return
	end

	local cid, h = addConstantSym(ctx, expr.index)
	checkConstantNode(ctx, cid, exprId)

	ctx.bytecode:emitABC(Opcodes.LOP_GETTABLEKS, target, reg, h)
	ctx.bytecode:emitAux(cid)

	hintTemporaryExprRegType(ctx, expr.expr, reg, Types.LBC_TYPE_TABLE, 2)
	ctx.regTop = oldTop
end

@native
local function compileExprIndexExpr(ctx: CompilerCtx, exprId: number, target: number)
	local oldTop = ctx.regTop
	local expr = ctx.nodes[exprId]
	local ct, cv = getConstant(ctx, expr.index)

	if
		ct == ConstantType.Number
		and (cv :: number) >= 1
		and (cv :: number) <= 256
		and math.floor(cv :: number) == cv
	then
		local i = (cv :: number) - 1
		local rt = compileExprAuto(ctx, expr.expr)
		fastDebugLine(ctx, expr.index)
		bcbEmitABC(ctx.bytecode, Opcodes.LOP_GETTABLEN, target, rt, i)
		hintTemporaryExprRegType(ctx, expr.expr, rt, Types.LBC_TYPE_TABLE, 1)
	elseif ct == ConstantType.String then
		local iname = (cv :: string?) or ""
		local cid = bcbAddConstStr(ctx.bytecode, iname)
		checkConstantNode(ctx, cid, exprId)
		local rt = compileExprAuto(ctx, expr.expr)
		fastDebugLine(ctx, expr.index)
		local bc = ctx.bytecode
		bcbEmitABC(bc, Opcodes.LOP_GETTABLEKS, target, rt, BytecodeBuilder.getStringHash(iname))
		bcbEmitAux(bc, cid)
		hintTemporaryExprRegType(ctx, expr.expr, rt, Types.LBC_TYPE_TABLE, 2)
	else
		local rt = compileExprAuto(ctx, expr.expr)
		local ri = compileExprAuto(ctx, expr.index)
		bcbEmitABC(ctx.bytecode, Opcodes.LOP_GETTABLE, target, rt, ri)
		hintTemporaryExprRegType(ctx, expr.expr, rt, Types.LBC_TYPE_TABLE, 1)
		hintTemporaryExprRegType(ctx, expr.index, ri, Types.LBC_TYPE_NUMBER, 1)
	end
	ctx.regTop = oldTop
end

@native
local function compileExprGlobal(ctx: CompilerCtx, exprId: number, target: number)
	local expr = ctx.nodes[exprId]
	local gsym = expr.name
	local gname = ctx.symbols[gsym]
	if canImport(ctx, exprId) then
		local bc = ctx.bytecode
		local id0 = bcbAddConstStr(bc, gname)
		checkConstantNode(ctx, id0, exprId)
		if id0 < 1024 then
			local iid = BytecodeBuilder.getImportId(id0)
			local cid = bc:addImport(iid)
			if cid >= 0 and cid < 32768 then
				bcbEmitAD(bc, Opcodes.LOP_GETIMPORT, target, cid)
				bcbEmitAux(bc, iid)
				return
			end
		end
	end

	local cid, h = addConstantSym(ctx, gsym)
	checkConstantNode(ctx, cid, exprId)
	local bc = ctx.bytecode
	bcbEmitABC(bc, Opcodes.LOP_GETGLOBAL, target, 0, h)
	bcbEmitAux(bc, cid)
end

@native
local function compileExprConstant(ctx: CompilerCtx, nodeId: number, ct: number, cv: any, target: number)
	if ct == ConstantType.Nil then
		bcbEmitABC(ctx.bytecode, Opcodes.LOP_LOADNIL, target, 0, 0)
	elseif ct == ConstantType.Boolean then
		bcbEmitABC(ctx.bytecode, Opcodes.LOP_LOADB, target, if cv then 1 else 0, 0)
	else
		if ct == ConstantType.Number then
			local d = cv :: number
			if d >= -32768 and d <= 32767 and math.floor(d) == d and (d ~= 0 or 1 / d > 0) then
				bcbEmitAD(ctx.bytecode, Opcodes.LOP_LOADN, target, d)
				return
			end
		end
		local cid = getConstantIndex(ctx, nodeId, ct, cv)
		if cid >= 0 then
			emitLoadK(ctx, target, cid)
		end
	end
end

@native
local function compileExprLocal(ctx: CompilerCtx, nodeId: number, node: PublicTypes.Node, target: number)
	local localId = node["local"]
	local b = ctx.bindings[localId]
	if
		ctx.flags.LuauExportValueSyntax
		and b.isExported
		and not ctx.exports.exportedClasses[localId]
		and (not ctx.flags.LuauOptimizeExportTable or not ctx.exports.exportedFunctions[localId])
	then
		local nameSym = b.name
		local nameStr = ctx.symbols[nameSym]
		local cid = ctx.bytecode:addConstantString(nameStr)
		checkConstantNode(ctx, cid, nodeId)
		local nameHash = getSymHash(ctx, nameSym, nameStr)
		local tableReg = getLocalReg(ctx, ctx.exportTableLocalId)
		if tableReg >= 0 then
			ctx.bytecode:emitABC(Opcodes.LOP_GETTABLEKS, target, tableReg, nameHash)
			ctx.bytecode:emitAux(cid)
		else
			local upval = getUpval(ctx, ctx.exportTableLocalId)
			ctx.bytecode:emitABC(Opcodes.LOP_GETUPVAL, target, upval, 0)
			ctx.bytecode:emitABC(Opcodes.LOP_GETTABLEKS, target, target, nameHash)
			ctx.bytecode:emitAux(cid)
		end
	else
		local reg = fastExprLocalReg(ctx, nodeId)
		if reg >= 0 then
			if ctx.optimizationLevel == 0 or target ~= reg then
				ctx.bytecode:emitABC(Opcodes.LOP_MOVE, target, reg, 0)
			end
		else
			local uid = getUpval(ctx, localId)
			ctx.bytecode:emitABC(Opcodes.LOP_GETUPVAL, target, uid, 0)
		end
	end
end

@native
function compileExprVarargs(ctx: CompilerCtx, exprId: number, target: number, targetCount: number, multRet: boolean?)
	fastDebugLine(ctx, exprId)
	ctx.bytecode:emitABC(Opcodes.LOP_GETVARARGS, target, if multRet then 0 else targetCount + 1, 0)
end

@native
function compileExpr(ctx: CompilerCtx, nodeId: number, target: number, targetTemp: boolean?)
	local isTargetTemp = targetTemp == true
	fastDebugLine(ctx, nodeId)
	if ctx.coverageLevel >= 2 and needsCoverage(ctx, nodeId) then
		ctx.bytecode:emitABC(Opcodes.LOP_COVERAGE, 0, 0, 0)
	end

	local ct = ctx.constTypes[nodeId]
	if ct ~= nil and ct ~= ConstantType.Unknown then
		compileExprConstant(ctx, nodeId, ct, ctx.constVals[nodeId], target)
		return
	end

	local node = ctx.nodes[nodeId]
	local k = ctx.kinds[nodeId]
	if k == K.AstExprGroup or k == K.AstExprTypeAssertion or k == K.AstExprInstantiate then
		compileExpr(ctx, node.expr, target, isTargetTemp)
	elseif k == K.AstExprConstantNil then
		bcbEmitABC(ctx.bytecode, Opcodes.LOP_LOADNIL, target, 0, 0)
	elseif k == K.AstExprConstantBool then
		bcbEmitABC(ctx.bytecode, Opcodes.LOP_LOADB, target, if node.value then 1 else 0, 0)
	elseif k == K.AstExprConstantNumber then
		local cid = bcbAddConstNum(ctx.bytecode, node.value)
		checkConstantNode(ctx, cid, nodeId)
		emitLoadK(ctx, target, cid)
	elseif k == K.AstExprConstantString then
		local cid = bcbAddConstStr(ctx.bytecode, node.value)
		checkConstantNode(ctx, cid, nodeId)
		emitLoadK(ctx, target, cid)
	elseif k == K.AstExprLocal then
		compileExprLocal(ctx, nodeId, node, target)
	elseif k == K.AstExprGlobal then
		compileExprGlobal(ctx, nodeId, target)
	elseif k == K.AstExprVarargs then
		compileExprVarargs(ctx, nodeId, target, 1)
	elseif k == K.AstExprCall then
		if isTargetTemp and target == ctx.regTop - 1 then
			compileExprCall(ctx, nodeId, target, 1, true)
		else
			compileExprCall(ctx, nodeId, target, 1)
		end
	elseif k == K.AstExprIndexName then
		compileExprIndexName(ctx, nodeId, target, isTargetTemp)
	elseif k == K.AstExprIndexExpr then
		compileExprIndexExpr(ctx, nodeId, target)
	elseif k == K.AstExprFunction then
		compileExprFunction(ctx, nodeId, target)
	elseif k == K.AstExprTable then
		compileExprTable(ctx, nodeId, target, isTargetTemp, kInvalidReg)
	elseif k == K.AstExprUnary then
		compileExprUnary(ctx, nodeId, target)
	elseif k == K.AstExprBinary then
		compileExprBinary(ctx, nodeId, target, isTargetTemp)
	elseif k == K.AstExprIfElse then
		compileExprIfElse(ctx, nodeId, target, isTargetTemp)
	elseif k == K.AstExprInterpString then
		compileExprInterpString(ctx, nodeId, target, isTargetTemp)
	else
		error("Unknown expression type: " .. tostring(k))
	end
end

@native
function compileExprTemp(ctx: CompilerCtx, nodeId: number, target: number)
	compileExpr(ctx, nodeId, target, true)
end

@native
function compileExprAutoTemp(ctx: CompilerCtx, nodeId: number, target: number, forbiddenSourceReg: number?): number
	local forbidden = forbiddenSourceReg or kInvalidReg
	if ctx.optimizationLevel == 0 then
		compileExprTemp(ctx, nodeId, target)
		return target
	end

	local marker = ctx.bytecode:emitLabel()
	compileExprTemp(ctx, nodeId, target)

	if ctx.bytecode:emitLabel() == marker + 1 then
		local insn = ctx.bytecode:lastInstruction()
		if BytecodeCodec.insnOp(insn) == Opcodes.LOP_MOVE and BytecodeCodec.insnA(insn) == target then
			local src = BytecodeCodec.insnB(insn)
			if not ctx.regCaptured[src] and src ~= forbidden then
				ctx.bytecode:undoEmit(Opcodes.LOP_MOVE)
				target = src
			end
		end
	end
	return target
end

@native
function compileExprAuto(ctx: CompilerCtx, nodeId: number): number
	local reg = fastExprLocalReg(ctx, nodeId)
	if reg >= 0 then
		return reg
	end
	local r = allocReg(ctx, nodeId, 1)
	return compileExprAutoTemp(ctx, nodeId, r)
end

@native
local function compileExprSide(ctx: CompilerCtx, nodeId: number)
	local k = ctx.kinds[nodeId]
	if
		k == K.AstExprLocal
		or k == K.AstExprGlobal
		or k == K.AstExprVarargs
		or k == K.AstExprFunction
		or isConstant(ctx, nodeId)
	then
		return
	end
	if k ~= K.AstExprCall and ctx.bytecode:needsDebugRemarks() then
		ctx.bytecode:addDebugRemark("expression only compiled for side effects")
	end
	local oldTop = ctx.regTop
	compileExprAuto(ctx, nodeId)
	ctx.regTop = oldTop
end

@native
local function compileExprTempN(
	ctx: CompilerCtx,
	nodeId: number,
	target: number,
	targetCount: number,
	targetTop: boolean
)
	if targetCount == 255 then
		raiseCompileError(
			ctx,
			ctx.starts[nodeId],
			ctx.finishes[nodeId],
			"Exceeded result count limit; simplify the code to compile"
		)
	end
	local k = ctx.kinds[nodeId]
	if k == K.AstExprCall then
		compileExprCall(ctx, nodeId, target, targetCount, targetTop)
	elseif k == K.AstExprVarargs then
		compileExprVarargs(ctx, nodeId, target, targetCount)
	else
		compileExprTemp(ctx, nodeId, target)
		for i = 1, targetCount - 1 do
			ctx.bytecode:emitABC(Opcodes.LOP_LOADNIL, target + i, 0, 0)
		end
	end
end

@native
local function compileExprListTemp(
	ctx: CompilerCtx,
	listId: number,
	target: number,
	targetCount: number,
	targetTop: boolean
)
	local first = if listId ~= 0 then ctx.listFirsts[listId] else 0
	local size = if listId ~= 0 then ctx.listCounts[listId] else 0
	local listValues = ctx.listValues
	if size == targetCount then
		for i = 0, size - 1 do
			compileExprTemp(ctx, listValues[first + i], target + i)
		end
	elseif size > targetCount then
		for i = 0, targetCount - 1 do
			compileExprTemp(ctx, listValues[first + i], target + i)
		end
		for i = targetCount, size - 1 do
			compileExprSide(ctx, listValues[first + i])
		end
	elseif size > 0 then
		for i = 0, size - 2 do
			compileExprTemp(ctx, listValues[first + i], target + i)
		end
		compileExprTempN(ctx, listValues[first + size - 1], target + size - 1, targetCount - (size - 1), targetTop)
	else
		for i = 0, targetCount - 1 do
			ctx.bytecode:emitABC(Opcodes.LOP_LOADNIL, target + i, 0, 0)
		end
	end
end

@native
function compileExprTempMultRet(ctx: CompilerCtx, nodeId: number, target: number): boolean
	local k = ctx.kinds[nodeId]
	if k == K.AstExprCall then
		if ctx.optimizationLevel >= 2 and not isExprMultRet(ctx, nodeId) then
			compileExprTemp(ctx, nodeId, target)
			return false
		end
		local oldTop = ctx.regTop
		ctx.regTop = target
		compileExprCall(ctx, nodeId, target, 0, true, true)
		ctx.regTop = oldTop
		return true
	elseif k == K.AstExprVarargs then
		local oldTop = ctx.regTop
		ctx.regTop = target
		compileExprVarargs(ctx, nodeId, target, 0, true)
		ctx.regTop = oldTop
		return true
	else
		compileExprTemp(ctx, nodeId, target)
		return false
	end
end

@native
function compileExprTempTop(ctx: CompilerCtx, nodeId: number, target: number)
	local oldTop = ctx.regTop
	ctx.regTop = target + 1
	compileExprTemp(ctx, nodeId, target)
	ctx.regTop = oldTop
end

local function compileExprSelectVararg(
	ctx: CompilerCtx,
	exprId: number,
	target: number,
	targetCount: number,
	targetTop: boolean,
	multRet: boolean,
	regs: number
)
	assert(not multRet, "select vararg cannot be multRet")
	assert(targetCount == 1, "select vararg requires targetCount == 1")
	local expr = ctx.nodes[exprId]
	assert(not expr.self, "select vararg cannot be method call")
	assert(expr.args ~= 0 and ctx.listCounts[expr.args] == 2, "select vararg requires 2 arguments")

	local arg0Id = ctx.listValues[ctx.listFirsts[expr.args]]
	local argreg: number
	local localReg = fastExprLocalReg(ctx, arg0Id)
	if localReg >= 0 then
		argreg = localReg
	else
		argreg = regs + 1
		compileExprTempTop(ctx, arg0Id, argreg)
	end

	local fastcallLabel = ctx.bytecode:emitLabel()
	ctx.bytecode:emitABC(Opcodes.LOP_FASTCALL1, Builtins.LBF_SELECT_VARARG, argreg, 0)

	compileExprTemp(ctx, expr.func, regs)

	if argreg ~= regs + 1 then
		ctx.bytecode:emitABC(Opcodes.LOP_MOVE, regs + 1, argreg, 0)
	end

	ctx.bytecode:emitABC(Opcodes.LOP_GETVARARGS, regs + 2, 0, 0)

	local callLabel = ctx.bytecode:emitLabel()
	patchSkipCOrThrow(ctx, ctx.nodes[expr.func], fastcallLabel, callLabel)

	ctx.bytecode:emitABC(Opcodes.LOP_CALL, regs, 0, if multRet then 0 else targetCount + 1)

	if not targetTop then
		moveCallResults(ctx, target, regs, targetCount)
	end
end

@native
local function prepareFastcallArgs(
	ctx: CompilerCtx,
	exprId: number,
	argsFirst: number,
	argsCount: number,
	opc: number,
	regs: number
): (number, number, number)
	local arg0 = 0
	local arg1 = 0
	local arg2 = 0
	local listValues = ctx.listValues
	for i = 0, argsCount - 1 do
		local argId = listValues[argsFirst + i]
		local val: number
		if i > 0 and opc == Opcodes.LOP_FASTCALL2K then
			local cid = getConstantIndex(ctx, argId)
			checkConstantNode(ctx, cid, exprId)
			val = cid
		else
			local reg = fastExprLocalReg(ctx, argId)
			if reg >= 0 then
				val = reg
			else
				local dst = regs + 1 + i
				local savedTop = ctx.regTop
				ctx.regTop = dst + 1
				val = compileExprAutoTemp(ctx, argId, dst)
				ctx.regTop = savedTop
			end
		end
		if i == 0 then
			arg0 = val
		elseif i == 1 then
			arg1 = val
		else
			arg2 = val
		end
	end
	return arg0, arg1, arg2
end

@native
local function compileExprFastcallN(
	ctx: CompilerCtx,
	exprId: number,
	target: number,
	targetCount: number,
	targetTop: boolean,
	multRet: boolean,
	regs: number,
	bfid: number,
	bfk: number?
)
	local k = bfk or -1
	local expr = ctx.nodes[exprId]
	assert(not expr.self, "fastcall cannot be method call")
	local argsFirst = if expr.args ~= 0 then ctx.listFirsts[expr.args] else 0
	local argsCount = if expr.args ~= 0 then ctx.listCounts[expr.args] else 0
	assert(argsCount >= 1 and argsCount <= 3, "fastcall requires 1..3 arguments")
	assert(bfid == Builtins.LBF_BIT32_EXTRACTK or k < 0, "invalid fastcall constant")

	local opc = Opcodes.LOP_NOP
	if argsCount == 1 then
		opc = Opcodes.LOP_FASTCALL1
	elseif k >= 0 or (argsCount == 2 and isConstant(ctx, ctx.listValues[argsFirst + 1])) then
		opc = Opcodes.LOP_FASTCALL2K
	elseif argsCount == 2 then
		opc = Opcodes.LOP_FASTCALL2
	else
		opc = Opcodes.LOP_FASTCALL3
	end

	local arg0, arg1, arg2 = prepareFastcallArgs(ctx, exprId, argsFirst, argsCount, opc, regs)

	local fastcallLabel = ctx.bytecode:emitLabel()
	ctx.bytecode:emitABC(opc, bfid, arg0, 0)
	if opc == Opcodes.LOP_FASTCALL3 then
		assert(k < 0, "fastcall3 cannot use constant k")
		ctx.bytecode:emitAux(bit32.bor(arg1, bit32.lshift(arg2, 8)))
	elseif opc ~= Opcodes.LOP_FASTCALL1 then
		ctx.bytecode:emitAux(if k >= 0 then k else arg1)
	end

	if arg0 ~= regs + 1 then
		ctx.bytecode:emitABC(Opcodes.LOP_MOVE, regs + 1, arg0, 0)
	end
	if argsCount >= 2 then
		if opc == Opcodes.LOP_FASTCALL2K then
			emitLoadK(ctx, regs + 2, arg1)
		elseif arg1 ~= regs + 2 then
			ctx.bytecode:emitABC(Opcodes.LOP_MOVE, regs + 2, arg1, 0)
		end
	end
	if argsCount >= 3 then
		if opc == Opcodes.LOP_FASTCALL2K then
			emitLoadK(ctx, regs + 3, arg2)
		elseif arg2 ~= regs + 3 then
			ctx.bytecode:emitABC(Opcodes.LOP_MOVE, regs + 3, arg2, 0)
		end
	end

	compileExprTemp(ctx, expr.func, regs)

	local callLabel = ctx.bytecode:emitLabel()
	patchSkipCOrThrow(ctx, ctx.nodes[expr.func], fastcallLabel, callLabel)

	ctx.bytecode:emitABC(Opcodes.LOP_CALL, regs, argsCount + 1, if multRet then 0 else targetCount + 1)

	if not targetTop then
		moveCallResults(ctx, target, regs, targetCount)
	end
end

local function emitBuiltinRemark(ctx: CompilerCtx, expr: PublicTypes.Node, argsFirst: number, argsCount: number)
	local bObj, bMethod = CompilerBuiltins.getBuiltin(expr.func, ctx.arena, ctx.globals, ctx.vars)
	local lastMult: boolean = argsCount > 0 and isExprMultRet(ctx, ctx.listValues[argsFirst + argsCount - 1])
	local suffix = if lastMult then "+" else ""
	if bObj ~= nil then
		local m = bMethod or ""
		ctx.bytecode:addDebugRemark("builtin " .. bObj .. "." .. m .. "/" .. tostring(argsCount) .. suffix)
	elseif bMethod ~= nil then
		ctx.bytecode:addDebugRemark("builtin " .. bMethod .. "/" .. tostring(argsCount) .. suffix)
	end
end

@native
local function tryCompileFastcallExpr(
	ctx: CompilerCtx,
	exprId: number,
	bfid: number,
	argsFirst: number,
	argsCount: number,
	target: number,
	targetCount: number,
	isTargetTop: boolean,
	isMultRet: boolean,
	regs: number
): (boolean, number)
	if bfid == Builtins.LBF_SELECT_VARARG then
		if not isMultRet and targetCount == 1 then
			compileExprSelectVararg(ctx, exprId, target, targetCount, isTargetTop, isMultRet, regs)
			return true, bfid
		else
			bfid = -1
		end
	end

	if
		bfid == Builtins.LBF_BIT32_EXTRACT
		and argsCount == 3
		and isConstant(ctx, ctx.listValues[argsFirst + 1])
		and isConstant(ctx, ctx.listValues[argsFirst + 2])
	then
		local ft, fv = getConstant(ctx, ctx.listValues[argsFirst + 1])
		local wt, wv = getConstant(ctx, ctx.listValues[argsFirst + 2])
		local fi = if ft == ConstantType.Number then math.modf(fv :: number) else -1
		local wi = if wt == ConstantType.Number then math.modf(wv :: number) else -1
		if fi >= 0 and wi > 0 and fi + wi <= 32 then
			local fwp = bit32.bor(fi, bit32.lshift(wi - 1, 5))
			local cid = ctx.bytecode:addConstantNumber(fwp)
			checkConstantNode(ctx, cid, exprId)
			compileExprFastcallN(
				ctx,
				exprId,
				target,
				targetCount,
				isTargetTop,
				isMultRet,
				regs,
				Builtins.LBF_BIT32_EXTRACTK,
				cid
			)
			return true, bfid
		end
	end

	local maxFastcallArgs = 2
	if bfid >= 0 and argsCount == 3 then
		local listValues = ctx.listValues
		for i = 0, argsCount - 1 do
			if fastExprLocalReg(ctx, listValues[argsFirst + i]) >= 0 then
				maxFastcallArgs = 3
				break
			end
		end
	end

	if bfid >= 0 and argsCount >= 1 and argsCount <= maxFastcallArgs then
		if not isExprMultRet(ctx, ctx.listValues[argsFirst + argsCount - 1]) then
			compileExprFastcallN(ctx, exprId, target, targetCount, isTargetTop, isMultRet, regs, bfid)
			return true, bfid
		elseif ctx.optimizationLevel >= 2 then
			local info = CompilerBuiltins.getBuiltinInfo(bfid)
			if argsCount == info.params and bit32.band(info.flags, CompilerBuiltins.Flag_NoneSafe) ~= 0 then
				compileExprFastcallN(ctx, exprId, target, targetCount, isTargetTop, isMultRet, regs, bfid)
				return true, bfid
			end
		end
	end

	return false, bfid
end

@native
local function compileCallFuncAndArgs(
	ctx: CompilerCtx,
	expr: PublicTypes.Node,
	bfid: number,
	fastPcallId: number,
	regs: number,
	selfOffset: number,
	argsFirst: number,
	argsCount: number
): (number, boolean, boolean)
	local selfreg = 0
	if expr.self then
		assert(ctx.kinds[expr.func] == K.AstExprIndexName, "method call func must be IndexName")
		local fi = ctx.nodes[expr.func]
		local reg = fastExprLocalReg(ctx, fi.expr)
		if reg >= 0 then
			selfreg = reg
		else
			selfreg = regs
			compileExprTempTop(ctx, fi.expr, selfreg)
		end
	elseif bfid < 0 and fastPcallId < 0 then
		compileExprTempTop(ctx, expr.func, regs)
	end

	local multCall = false
	local constructCall = false

	if ctx.flags.DebugLuauUserDefinedClasses and not expr.self and expr.tableCall and bfid < 0 and fastPcallId < 0 then
		assert(argsCount == 1, "table call requires 1 argument")
		local arg0Id = ctx.listValues[argsFirst]
		assert(ctx.kinds[arg0Id] == K.AstExprTable, "table call argument must be AstExprTable")
		local arg = regs + 1
		local savedTop = ctx.regTop
		ctx.regTop = arg + 1
		compileExprTable(ctx, arg0Id, arg, true, regs)
		ctx.regTop = savedTop
		constructCall = true
	else
		local listValues = ctx.listValues
		for i = 0, argsCount - 1 do
			local argId = listValues[argsFirst + i]
			local dst = regs + 1 + selfOffset + i
			if i + 1 == argsCount then
				multCall = compileExprTempMultRet(ctx, argId, dst)
			else
				compileExprTempTop(ctx, argId, dst)
			end
		end
	end

	return selfreg, multCall, constructCall
end

@native
local function emitCallPreambles(
	ctx: CompilerCtx,
	expr: PublicTypes.Node,
	bfid: number,
	fastPcallId: number,
	regs: number,
	selfreg: number,
	argsCount: number,
	multCall: boolean
)
	fastDebugLineEnd(ctx, expr.func)

	if expr.self then
		assert(ctx.kinds[expr.func] == K.AstExprIndexName, "method call func must be IndexName")
		local fi = ctx.nodes[expr.func]
		if fi.indexStart ~= nil then
			fastDebugLineOffset(ctx, fi.indexStart)
		end
		if ctx.flagDebugClasses and fi.privateAccess then
			compilePrivateFieldAccess(ctx, fi, regs, selfreg, true)
		else
			local cid, h = addConstantSym(ctx, fi.index)
			checkConstantNode(ctx, cid, expr.func)

			ctx.bytecode:emitABC(Opcodes.LOP_NAMECALL, regs, selfreg, h)
			ctx.bytecode:emitAux(cid)

			hintTemporaryExprRegType(ctx, fi.expr, selfreg, Types.LBC_TYPE_TABLE, 2)
		end
	elseif bfid >= 0 or fastPcallId >= 0 then
		local fastcallLabel = ctx.bytecode:emitLabel()
		if fastPcallId >= 0 then
			local explicitArgs = argsCount - (if multCall then 1 else 0)
			ctx.bytecode:emitABC(Opcodes.LOP_FASTPCALL, fastPcallId, explicitArgs, 0)
		else
			ctx.bytecode:emitABC(Opcodes.LOP_FASTCALL, bfid, 0, 0)
		end

		compileExprTemp(ctx, expr.func, regs)

		local callLabel = ctx.bytecode:emitLabel()
		patchSkipCOrThrow(ctx, ctx.nodes[expr.func], fastcallLabel, callLabel)
	end
end

@native
local function emitCallInstruction(
	ctx: CompilerCtx,
	expr: PublicTypes.Node,
	bfid: number,
	fastPcallId: number,
	regs: number,
	selfOffset: number,
	argsCount: number,
	targetCount: number,
	multCall: boolean,
	isMultRet: boolean,
	constructCall: boolean
)
	local jumpLabel = ctx.bytecode:emitLabel()
	if constructCall then
		assert(not expr.self, "construct call cannot be method call")
		ctx.bytecode:emitABC(Opcodes.LOP_FINCONSTRUCT, regs + 1, 0, 0)
	end

	local callLabel = ctx.bytecode:emitLabel()
	local curFunc = ctx.currentFunctionNode
	local canInline = (curFunc ~= nil and curFunc.functionDepth ~= 0) and not multCall and not isMultRet
	if (bfid < 0 and fastPcallId < 0) and canInline and not constructCall then
		local fbSlot = ctx.bytecode:addCallTargetSlot(ctx.bytecode.insnCount)
		ctx.bytecode:emitABC(
			Opcodes.LOP_CALLFB,
			regs,
			if multCall then 0 else selfOffset + argsCount + 1,
			if isMultRet then 0 else targetCount + 1
		)
		ctx.bytecode:emitAux(fbSlot)
	else
		ctx.bytecode:emitABC(
			Opcodes.LOP_CALL,
			regs,
			if multCall then 0 else selfOffset + argsCount + 1,
			if isMultRet then 0 else targetCount + 1
		)
	end

	if constructCall then
		patchSkipCOrThrow(ctx, expr, jumpLabel, callLabel)
	end
end

@native
local function resolveBuiltinCallId(
	ctx: CompilerCtx,
	exprId: number,
	expr: PublicTypes.Node,
	argsFirst: number,
	argsCount: number
): number
	local bfid = -1
	if ctx.optimizationLevel >= 1 and not expr.self then
		local id = ctx.builtins[exprId]
		if id ~= nil and id ~= Builtins.LBF_NONE then
			bfid = id
		end
	end
	if bfid >= 0 and ctx.bytecode:needsDebugRemarks() then
		emitBuiltinRemark(ctx, expr, argsFirst, argsCount)
	end
	return bfid
end

@native
local function detectFastPcall(ctx: CompilerCtx, expr: PublicTypes.Node, argsCount: number): number
	if ctx.optimizationLevel >= 1 and not expr.self then
		if ctx.kinds[expr.func] == K.AstExprGlobal then
			local fnNode = ctx.nodes[expr.func]
			if CompilerBuiltins.getGlobalState(ctx.globals, fnNode.name) ~= GlobalState.Written then
				local gname = ctx.symbols[fnNode.name]
				if gname == "pcall" and argsCount >= 1 or gname == "xpcall" and argsCount >= 2 then
					return if gname == "pcall" then 0 else 1
				end
			end
		end
	end
	return -1
end

@native
function compileExprCall(
	ctx: CompilerCtx,
	exprId: number,
	target: number,
	targetCount: number,
	targetTop: boolean?,
	multRet: boolean?
)
	local isTargetTop = targetTop == true
	local isMultRet = multRet == true
	assert(targetCount < 255, "targetCount must be < 255")
	assert(not isTargetTop or target + targetCount == ctx.regTop, "targetTop mismatch")

	fastDebugLine(ctx, exprId)
	local expr = ctx.nodes[exprId]

	if ctx.flags.LuauCompileRequireNoInline and not expr.self then
		if ctx.kinds[expr.func] == K.AstExprGlobal and ctx.symbols[ctx.nodes[expr.func].name] == "require" then
			ctx.hasRequire = true
		end
	end

	if
		ctx.optimizationLevel >= 2
		and not expr.self
		and tryInlineCallExpr(ctx, exprId, expr, target, targetCount, isMultRet)
	then
		return
	end

	local oldTop = ctx.regTop
	local argsFirst = if expr.args ~= 0 then ctx.listFirsts[expr.args] else 0
	local argsCount = if expr.args ~= 0 then ctx.listCounts[expr.args] else 0
	local selfOffset = if expr.self then 1 else 0
	local regCount = math.max(1 + selfOffset + argsCount, targetCount)

	local regs = if isTargetTop
		then allocReg(ctx, exprId, regCount - targetCount) - targetCount
		else allocReg(ctx, exprId, regCount)

	local bfid = resolveBuiltinCallId(ctx, exprId, expr, argsFirst, argsCount)
	local handledFastcall: boolean
	handledFastcall, bfid = tryCompileFastcallExpr(
		ctx,
		exprId,
		bfid,
		argsFirst,
		argsCount,
		target,
		targetCount,
		isTargetTop,
		isMultRet,
		regs
	)
	if handledFastcall then
		ctx.regTop = oldTop
		return
	end

	local fastPcallId = detectFastPcall(ctx, expr, argsCount)
	local selfreg, multCall, constructCall =
		compileCallFuncAndArgs(ctx, expr, bfid, fastPcallId, regs, selfOffset, argsFirst, argsCount)

	emitCallPreambles(ctx, expr, bfid, fastPcallId, regs, selfreg, argsCount, multCall)
	emitCallInstruction(
		ctx,
		expr,
		bfid,
		fastPcallId,
		regs,
		selfOffset,
		argsCount,
		targetCount,
		multCall,
		isMultRet,
		constructCall
	)

	if not isTargetTop then
		moveCallResults(ctx, target, regs, targetCount)
	end
	ctx.regTop = oldTop
end

@native
local function shouldShareClosure(ctx: CompilerCtx, funcId: number): boolean
	local f = ctx.functions[funcId]
	if not f then
		return false
	end
	if ctx.flagDebugClasses and ctx.enclosingClasses[funcId] ~= nil then
		return false
	end
	local vars = ctx.vars
	local varOwner = vars.owner
	local varWritten = vars.written
	local varInit = vars.init
	for _, uv in f.upvals do
		if uv == kInvalidUpvalue then
			continue
		end
		if varOwner[uv] == nil or varWritten[uv] then
			return false
		end
		local b = ctx.bindings[uv]
		if b.functionDepth ~= 0 or b.loopDepth ~= 0 then
			local initId = varInit[uv]
			local uf = if initId ~= 0 and ctx.kinds[initId] == K.AstExprFunction then initId else 0
			if uf == 0 then
				return false
			end
			if uf ~= funcId and not shouldShareClosure(ctx, uf) then
				return false
			end
		end
	end
	return true
end

@native
function compileExprFunction(ctx: CompilerCtx, exprId: number, target: number, classReg: number?)
	local oldTop = ctx.regTop
	local expr = ctx.nodes[exprId]
	local f = ctx.functions[exprId]
	assert(f, "missing function info")

	local pid = ctx.bytecode:addChildFunction(f.id)
	if pid < 0 then
		raiseCompileError(ctx, expr.start, expr.finish, "Exceeded closure limit; simplify the code to compile")
	end

	local upvals = f.upvals
	local upvalCount = #upvals
	local captureTypes = ctx.captureTypes
	local captureData = ctx.captureData
	if upvalCount > 0 then
		local resolvedClassReg = if classReg ~= nil then classReg else kInvalidReg
		local startUpval = 1
		if ctx.flagDebugClasses then
			local classes = ctx.enclosingClasses[exprId]
			if classes then
				local classCount = #classes
				for j = 1, classCount - 1 do
					captureTypes[j] = CaptureTypes.LCT_UPVAL
					captureData[j] = j - 1
				end
				if resolvedClassReg ~= kInvalidReg then
					captureTypes[classCount] = CaptureTypes.LCT_VAL
					captureData[classCount] = resolvedClassReg
				else
					captureTypes[classCount] = CaptureTypes.LCT_UPVAL
					captureData[classCount] = classCount - 1
				end
				startUpval = classCount + 1
			end
		end

		local varWritten = ctx.vars.written
		for i = startUpval, upvalCount do
			local uv = upvals[i]
			local b = ctx.bindings[uv]
			assert(b.functionDepth < expr.functionDepth, "invalid upvalue function depth")
			local reg = getLocalReg(ctx, uv)
			if reg >= 0 then
				local immutable = not varWritten[uv]
				captureTypes[i] = if immutable then CaptureTypes.LCT_VAL else CaptureTypes.LCT_REF
				captureData[i] = reg
			elseif ctx.locstantTypes[uv] ~= nil and ctx.locstantTypes[uv] ~= ConstantType.Unknown then
				local ut = ctx.locstantTypes[uv]
				local uc = ctx.locstantVals[uv]
				local cReg = allocReg(ctx, exprId, 1)
				compileExprConstant(ctx, exprId, ut, uc, cReg)
				captureTypes[i] = CaptureTypes.LCT_VAL
				captureData[i] = cReg
			else
				assert(b.functionDepth < expr.functionDepth - 1, "invalid transitive upvalue function depth")
				local uid = getUpval(ctx, uv)
				captureTypes[i] = CaptureTypes.LCT_UPVAL
				captureData[i] = uid
			end
		end

		if ctx.flagDebugClasses and upvalCount >= kMaxUpvalueCount then
			local dbgNameId = expr.debugname
			local dbgName: string = if type(dbgNameId) == "number" and dbgNameId ~= 0
				then ctx.symbols[dbgNameId]
				else ""
			raiseCompileError(
				ctx,
				expr.start,
				expr.finish,
				string.format(
					"Out of upvalue registers when trying to allocate %s: exceeded limit %d",
					dbgName,
					kMaxUpvalueCount
				)
			)
		end
	end

	local shared = -1
	if ctx.optimizationLevel >= 1 and shouldShareClosure(ctx, exprId) and not ctx.setfenvUsed then
		local cid = ctx.bytecode:addConstantClosure(f.id)
		if cid >= 0 and cid < 32768 then
			shared = cid
		end
	end

	if shared < 0 and ctx.bytecode:needsDebugRemarks() then
		ctx.bytecode:addDebugRemark(string.format("allocation: closure with %d upvalues", upvalCount))
	end

	if shared >= 0 then
		ctx.bytecode:emitAD(Opcodes.LOP_DUPCLOSURE, target, shared)
	else
		ctx.bytecode:emitAD(Opcodes.LOP_NEWCLOSURE, target, pid)
	end

	for i = 1, upvalCount do
		ctx.bytecode:emitABC(Opcodes.LOP_CAPTURE, captureTypes[i], captureData[i], 0)
	end
	ctx.regTop = oldTop
end

@native
function compileLValueIndexUnboxed(
	ctx: CompilerCtx,
	reg: number,
	indexId: number
): (number, number, number, string?, number, number, number)
	local ct, cv = getConstant(ctx, indexId)
	local indexNode = ctx.nodes[indexId]
	if ct == ConstantType.Number then
		local numVal = cv :: number
		if numVal >= 1 and numVal <= 256 and math.floor(numVal) == numVal then
			return LValueKind.IndexNumber, reg, math.floor(numVal) - 1, nil, 0, indexNode.start, indexNode.finish
		end
	elseif ct == ConstantType.String then
		return LValueKind.IndexName, reg, 0, cv :: string, 0, indexNode.start, indexNode.finish
	end
	return LValueKind.IndexExpr, reg, compileExprAuto(ctx, indexId), nil, 0, indexNode.start, indexNode.finish
end

@native
function compileLValueUnboxed(
	ctx: CompilerCtx,
	nodeId: number
): (number, number, number, string?, number, number, number)
	fastDebugLine(ctx, nodeId)
	local n = ctx.nodes[nodeId]
	local k = n.kind
	if k == K.AstExprLocal then
		local localId = n["local"]
		local b = ctx.bindings[localId]
		if
			ctx.flags.LuauExportValueSyntax
			and b.isExported
			and (not ctx.flags.LuauOptimizeExportTable or not ctx.exports.exportedFunctions[localId])
		then
			local tableReg = getExportTableReg(ctx, nodeId)
			return LValueKind.IndexName, tableReg, 0, ctx.symbols[b.name], b.name, n.start, n.finish
		end
		local reg = fastExprLocalReg(ctx, nodeId)
		if reg >= 0 then
			return LValueKind.Local, reg, 0, nil, 0, n.start, n.finish
		else
			assert(n.upvalue, "expected upvalue")
			return LValueKind.Upvalue, 0, getUpval(ctx, localId), nil, 0, n.start, n.finish
		end
	elseif k == K.AstExprGlobal then
		return LValueKind.Global, 0, 0, ctx.symbols[n.name], n.name, n.start, n.finish
	elseif k == K.AstExprIndexName then
		if ctx.flagDebugClasses and n.privateAccess then
			return LValueKind.PrivateField, compileExprAuto(ctx, n.expr), n.index, nil, 0, n.start, n.finish
		end
		return LValueKind.IndexName, compileExprAuto(ctx, n.expr), 0, ctx.symbols[n.index], n.index, n.start, n.finish
	elseif k == K.AstExprIndexExpr then
		local reg = compileExprAuto(ctx, n.expr)
		return compileLValueIndexUnboxed(ctx, reg, n.index)
	else
		error("Unknown assignment expression")
	end
end

@native
function compileLValueUseUnboxed(
	ctx: CompilerCtx,
	k: number,
	lvReg: number,
	lvAux: number,
	lvName: string?,
	lvSymId: number,
	lvStart: number,
	lvFinish: number,
	reg: number,
	set: boolean,
	targetExprId: number
)
	fastDebugLineOffset(ctx, lvStart)
	if k == LValueKind.Local then
		if set then
			ctx.bytecode:emitABC(Opcodes.LOP_MOVE, lvReg, reg, 0)
		else
			ctx.bytecode:emitABC(Opcodes.LOP_MOVE, reg, lvReg, 0)
		end
	elseif k == LValueKind.Upvalue then
		ctx.bytecode:emitABC(if set then Opcodes.LOP_SETUPVAL else Opcodes.LOP_GETUPVAL, reg, lvAux, 0)
	elseif k == LValueKind.Global then
		local cid: number
		local h: number
		if lvSymId ~= 0 then
			cid, h = addConstantSym(ctx, lvSymId)
		else
			local name = lvName :: string
			cid = ctx.bytecode:addConstantString(name)
			h = BytecodeBuilder.getStringHash(name)
		end
		if cid < 0 then
			raiseCompileError(ctx, lvStart, lvFinish, "Exceeded constant limit; simplify the code to compile")
		end
		ctx.bytecode:emitABC(if set then Opcodes.LOP_SETGLOBAL else Opcodes.LOP_GETGLOBAL, reg, 0, h)
		ctx.bytecode:emitAux(cid)
	elseif k == LValueKind.IndexName then
		local cid: number
		local h: number
		if lvSymId ~= 0 then
			cid, h = addConstantSym(ctx, lvSymId)
		else
			local name = lvName :: string
			cid = ctx.bytecode:addConstantString(name)
			h = BytecodeBuilder.getStringHash(name)
		end
		if cid < 0 then
			raiseCompileError(ctx, lvStart, lvFinish, "Exceeded constant limit; simplify the code to compile")
		end
		ctx.bytecode:emitABC(if set then Opcodes.LOP_SETTABLEKS else Opcodes.LOP_GETTABLEKS, reg, lvReg, h)
		ctx.bytecode:emitAux(cid)
		if targetExprId ~= 0 and ctx.kinds[targetExprId] == K.AstExprIndexName then
			hintTemporaryExprRegType(ctx, ctx.nodes[targetExprId].expr, lvReg, Types.LBC_TYPE_TABLE, 2)
		end
	elseif k == LValueKind.IndexNumber then
		ctx.bytecode:emitABC(if set then Opcodes.LOP_SETTABLEN else Opcodes.LOP_GETTABLEN, reg, lvReg, lvAux)
		if targetExprId ~= 0 and ctx.kinds[targetExprId] == K.AstExprIndexExpr then
			hintTemporaryExprRegType(ctx, ctx.nodes[targetExprId].expr, lvReg, Types.LBC_TYPE_TABLE, 1)
		end
	elseif k == LValueKind.IndexExpr then
		ctx.bytecode:emitABC(if set then Opcodes.LOP_SETTABLE else Opcodes.LOP_GETTABLE, reg, lvReg, lvAux)
		if targetExprId ~= 0 and ctx.kinds[targetExprId] == K.AstExprIndexExpr then
			local te = ctx.nodes[targetExprId]
			hintTemporaryExprRegType(ctx, te.expr, lvReg, Types.LBC_TYPE_TABLE, 1)
			hintTemporaryExprRegType(ctx, te.index, lvAux, Types.LBC_TYPE_NUMBER, 1)
		end
	elseif k == LValueKind.PrivateField then
		assert(ctx.flagDebugClasses, "classes flag must be enabled")
		local offset, classNest, isStatic = computePrivateFieldInfo(ctx, lvAux, lvStart, lvFinish)
		if isStatic and set then
			raiseCompileError(ctx, lvStart, lvFinish, "Attempt to assign static field of a class")
		end
		ctx.bytecode:emitABC(
			if set then Opcodes.LOP_SETPRIVATEFIELD else Opcodes.LOP_GETPRIVATEFIELD,
			reg,
			lvReg,
			classNest
		)
		ctx.bytecode:emitAux(offset)
	end
end

return table.freeze({
	bind = bind,
	unrollConcats = unrollConcats,
	tryIndexConstantTable = tryIndexConstantTable,
	getFunctionExpr = getFunctionExpr,
	isExprMultRet = isExprMultRet,
	compileConditionValue = compileConditionValue,
	compileExpr = compileExpr,
	compileExprTemp = compileExprTemp,
	compileExprAutoTemp = compileExprAutoTemp,
	compileExprAuto = compileExprAuto,
	compileExprSide = compileExprSide,
	compileExprTempN = compileExprTempN,
	compileExprListTemp = compileExprListTemp,
	compileExprTempMultRet = compileExprTempMultRet,
	compileExprTempTop = compileExprTempTop,
	compileExprVarargs = compileExprVarargs,
	compileExprCall = compileExprCall,
	compileExprFunction = compileExprFunction,
	compileLValueIndexUnboxed = compileLValueIndexUnboxed,
	compileLValueUnboxed = compileLValueUnboxed,
	compileLValueUseUnboxed = compileLValueUseUnboxed,
})
