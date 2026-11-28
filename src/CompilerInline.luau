--!strict
-- Luau 0.748 function inlining and constant-trip-count loop unrolling.
-- Upstream Luau is MIT licensed; see ../LICENSE.md and ../UPSTREAM.json.
local Arena = require("./Arena")
local BytecodeDefs = require("./BytecodeDefs")
local CompilerBuiltins = require("./CompilerBuiltins")
local CompilerExpr = require("./CompilerExpr")
local CompilerFolding = require("./CompilerFolding")
local CompilerTypes = require("./CompilerTypes")

local K = Arena.Kinds
local Opcodes = BytecodeDefs.Opcodes
local Builtins = BytecodeDefs.Builtins
local ConstantType = CompilerBuiltins.ConstantType

local kInvalidReg = 255
local kDefaultAllocPc = 0xffffffff

local LoopJumpType = {
	Break = 0,
	Continue = 1,
}

local ReturnKind = {
	Parameter = 2,
	Local = 3,
}

local EMPTY_JUMP_LIST: { number } = table.freeze({}) :: { number }
local SINGLE_TRUE_VARC: { boolean } = table.freeze({ true })

type CompilerCtx = CompilerExpr.CompilerCtx
type AstLocalVisitor = (CompilerCtx, number, any, any, any) -> boolean

local allocReg: (CompilerCtx, number, number) -> number
local getLocalReg: (CompilerCtx, number) -> number
local getExprLocal: (CompilerCtx, number) -> number
local getExprLocalReg: (CompilerCtx, number) -> number
local pushLocal: (CompilerCtx, number, number, number) -> ()
local closeLocals: (CompilerCtx, number) -> ()
local popLocals: (CompilerCtx, number) -> ()
local enterBlockLive: (CompilerCtx, number) -> (number, number, number, number)
local leaveBlockLive: (CompilerCtx, number, number, number, number) -> ()
local popStatLocals: (CompilerCtx, number) -> ()
local patchJump: (CompilerCtx, number, number, number) -> ()
local patchJumps: (CompilerCtx, number, { number }, number) -> ()
local patchLoopJumps: (CompilerCtx, number, number, number, number) -> ()
local isConstant: (CompilerCtx, number) -> boolean
local acquireJumpList: (CompilerCtx) -> { number }
local releaseJumpList: (CompilerCtx, { number }) -> ()
local compileStat: (CompilerCtx, number) -> ()
local isExprMultRet: (CompilerCtx, number) -> boolean
local compileExprTemp: (CompilerCtx, number, number) -> ()
local compileExprAutoTemp: (CompilerCtx, number, number, number?) -> number
local compileExprCall: (CompilerCtx, number, number, number, boolean?, boolean?) -> ()
local compileExprVarargs: (CompilerCtx, number, number, number, boolean?) -> ()
local compileExprSide: (CompilerCtx, number) -> ()
local getFunctionExpr: (CompilerCtx, number) -> number

local function bind(deps: {
	allocReg: (CompilerCtx, number, number) -> number,
	getLocalReg: (CompilerCtx, number) -> number,
	getExprLocal: (CompilerCtx, number) -> number,
	getExprLocalReg: (CompilerCtx, number) -> number,
	pushLocal: (CompilerCtx, number, number, number) -> (),
	closeLocals: (CompilerCtx, number) -> (),
	popLocals: (CompilerCtx, number) -> (),
	enterBlockLive: (CompilerCtx, number) -> (number, number, number, number),
	leaveBlockLive: (CompilerCtx, number, number, number, number) -> (),
	popStatLocals: (CompilerCtx, number) -> (),
	patchJump: (CompilerCtx, number, number, number) -> (),
	patchJumps: (CompilerCtx, number, { number }, number) -> (),
	patchLoopJumps: (CompilerCtx, number, number, number, number) -> (),
	isConstant: (CompilerCtx, number) -> boolean,
	acquireJumpList: (CompilerCtx) -> { number },
	releaseJumpList: (CompilerCtx, { number }) -> (),
	compileStat: (CompilerCtx, number) -> (),
	isExprMultRet: (CompilerCtx, number) -> boolean,
	compileExprTemp: (CompilerCtx, number, number) -> (),
	compileExprAutoTemp: (CompilerCtx, number, number, number?) -> number,
	compileExprCall: (CompilerCtx, number, number, number, boolean?, boolean?) -> (),
	compileExprVarargs: (CompilerCtx, number, number, number, boolean?) -> (),
	compileExprSide: (CompilerCtx, number) -> (),
	getFunctionExpr: (CompilerCtx, number) -> number,
})
	allocReg = deps.allocReg
	getLocalReg = deps.getLocalReg
	getExprLocal = deps.getExprLocal
	getExprLocalReg = deps.getExprLocalReg
	pushLocal = deps.pushLocal
	closeLocals = deps.closeLocals
	popLocals = deps.popLocals
	enterBlockLive = deps.enterBlockLive
	leaveBlockLive = deps.leaveBlockLive
	popStatLocals = deps.popStatLocals
	patchJump = deps.patchJump
	patchJumps = deps.patchJumps
	patchLoopJumps = deps.patchLoopJumps
	isConstant = deps.isConstant
	acquireJumpList = deps.acquireJumpList
	releaseJumpList = deps.releaseJumpList
	compileStat = deps.compileStat
	isExprMultRet = deps.isExprMultRet
	compileExprTemp = deps.compileExprTemp
	compileExprAutoTemp = deps.compileExprAutoTemp
	compileExprCall = deps.compileExprCall
	compileExprVarargs = deps.compileExprVarargs
	compileExprSide = deps.compileExprSide
	getFunctionExpr = deps.getFunctionExpr
end

local visitAstLocalNode: (CompilerCtx, number, AstLocalVisitor, any, any, boolean?, AstLocalVisitor?) -> boolean

@native
local function visitAstLocalList(
	ctx: CompilerCtx,
	listId: number,
	onLocal: AstLocalVisitor,
	arg1: any,
	arg2: any,
	skipFunctions: boolean?,
	onFunction: AstLocalVisitor?
): boolean
	if listId ~= 0 then
		local first = ctx.listFirsts[listId]
		local count = ctx.listCounts[listId]
		local listValues = ctx.listValues
		for i = 0, count - 1 do
			if visitAstLocalNode(ctx, listValues[first + i], onLocal, arg1, arg2, skipFunctions, onFunction) then
				return true
			end
		end
	end
	return false
end

@native
local function visitAstLocalStat(
	ctx: CompilerCtx,
	n: any,
	k: number,
	onLocal: AstLocalVisitor,
	arg1: any,
	arg2: any,
	skipFunctions: boolean?,
	onFunction: AstLocalVisitor?
): boolean
	if k == K.AstStatBlock then
		return visitAstLocalList(ctx, n.body, onLocal, arg1, arg2, skipFunctions, onFunction)
	elseif k == K.AstStatIf then
		return visitAstLocalNode(ctx, n.condition, onLocal, arg1, arg2, skipFunctions, onFunction)
			or visitAstLocalNode(ctx, n.thenbody, onLocal, arg1, arg2, skipFunctions, onFunction)
			or visitAstLocalNode(ctx, n.elsebody, onLocal, arg1, arg2, skipFunctions, onFunction)
	elseif k == K.AstStatWhile then
		return visitAstLocalNode(ctx, n.condition, onLocal, arg1, arg2, skipFunctions, onFunction)
			or visitAstLocalNode(ctx, n.body, onLocal, arg1, arg2, skipFunctions, onFunction)
	elseif k == K.AstStatRepeat then
		return visitAstLocalNode(ctx, n.body, onLocal, arg1, arg2, skipFunctions, onFunction)
			or visitAstLocalNode(ctx, n.condition, onLocal, arg1, arg2, skipFunctions, onFunction)
	elseif k == K.AstStatReturn then
		return visitAstLocalList(ctx, n.list, onLocal, arg1, arg2, skipFunctions, onFunction)
	elseif k == K.AstStatLocal then
		return visitAstLocalList(ctx, n.values, onLocal, arg1, arg2, skipFunctions, onFunction)
	elseif k == K.AstStatFor then
		return visitAstLocalNode(ctx, n.from, onLocal, arg1, arg2, skipFunctions, onFunction)
			or visitAstLocalNode(ctx, n.to, onLocal, arg1, arg2, skipFunctions, onFunction)
			or visitAstLocalNode(ctx, n.step, onLocal, arg1, arg2, skipFunctions, onFunction)
			or visitAstLocalNode(ctx, n.body, onLocal, arg1, arg2, skipFunctions, onFunction)
	elseif k == K.AstStatForIn then
		return visitAstLocalList(ctx, n.values, onLocal, arg1, arg2, skipFunctions, onFunction)
			or visitAstLocalNode(ctx, n.body, onLocal, arg1, arg2, skipFunctions, onFunction)
	elseif k == K.AstStatAssign then
		return visitAstLocalList(ctx, n.vars, onLocal, arg1, arg2, skipFunctions, onFunction)
			or visitAstLocalList(ctx, n.values, onLocal, arg1, arg2, skipFunctions, onFunction)
	elseif k == K.AstStatCompoundAssign then
		return visitAstLocalNode(ctx, n.var, onLocal, arg1, arg2, skipFunctions, onFunction)
			or visitAstLocalNode(ctx, n.value, onLocal, arg1, arg2, skipFunctions, onFunction)
	elseif k == K.AstStatFunction then
		return visitAstLocalNode(ctx, n.name, onLocal, arg1, arg2, skipFunctions, onFunction)
			or visitAstLocalNode(ctx, n.func, onLocal, arg1, arg2, skipFunctions, onFunction)
	elseif k == K.AstStatLocalFunction then
		return visitAstLocalNode(ctx, n.func, onLocal, arg1, arg2, skipFunctions, onFunction)
	end
	return false
end

@native
function visitAstLocalNode(
	ctx: CompilerCtx,
	nodeId: number,
	onLocal: AstLocalVisitor,
	arg1: any,
	arg2: any,
	skipFunctions: boolean?,
	onFunction: AstLocalVisitor?
): boolean
	if nodeId == 0 then
		return false
	end
	local k = ctx.kinds[nodeId]
	if
		k == nil
		or (k >= K.AstExprConstantNil and k <= K.AstExprConstantString)
		or k == K.AstExprGlobal
		or k == K.AstExprVarargs
		or k == K.AstStatBreak
		or k == K.AstStatContinue
		or k == K.AstStatTypeAlias
		or k == K.AstStatDeclareGlobal
		or k == K.AstStatDeclareFunction
		or k == K.AstStatDeclareExternType
	then
		return false
	end
	local n = ctx.nodes[nodeId]
	if k == K.AstExprLocal then
		return onLocal(ctx, nodeId, n, arg1, arg2)
	elseif k == K.AstExprFunction then
		if onFunction then
			return onFunction(ctx, nodeId, n, arg1, arg2)
		end
		return if skipFunctions
			then false
			else visitAstLocalNode(ctx, n.body, onLocal, arg1, arg2, skipFunctions, onFunction)
	elseif
		k == K.AstExprGroup
		or k == K.AstExprTypeAssertion
		or k == K.AstExprInstantiate
		or k == K.AstExprUnary
		or k == K.AstExprIndexName
		or k == K.AstStatExpr
	then
		return visitAstLocalNode(ctx, n.expr, onLocal, arg1, arg2, skipFunctions, onFunction)
	elseif k == K.AstExprIndexExpr then
		return visitAstLocalNode(ctx, n.expr, onLocal, arg1, arg2, skipFunctions, onFunction)
			or visitAstLocalNode(ctx, n.index, onLocal, arg1, arg2, skipFunctions, onFunction)
	elseif k == K.AstExprBinary then
		return visitAstLocalNode(ctx, n.left, onLocal, arg1, arg2, skipFunctions, onFunction)
			or visitAstLocalNode(ctx, n.right, onLocal, arg1, arg2, skipFunctions, onFunction)
	elseif k == K.AstExprIfElse then
		return visitAstLocalNode(ctx, n.condition, onLocal, arg1, arg2, skipFunctions, onFunction)
			or visitAstLocalNode(ctx, n.trueExpr, onLocal, arg1, arg2, skipFunctions, onFunction)
			or visitAstLocalNode(ctx, n.falseExpr, onLocal, arg1, arg2, skipFunctions, onFunction)
	elseif k == K.AstExprCall then
		return visitAstLocalNode(ctx, n.func, onLocal, arg1, arg2, skipFunctions, onFunction)
			or visitAstLocalList(ctx, n.args, onLocal, arg1, arg2, skipFunctions, onFunction)
	elseif k == K.AstExprTable then
		if n.items ~= 0 then
			local first = ctx.listFirsts[n.items]
			local count = ctx.listCounts[n.items]
			local listValues = ctx.listValues
			for i = 0, count - 1 do
				local item = listValues[first + i]
				if
					(item.key ~= 0 and visitAstLocalNode(ctx, item.key, onLocal, arg1, arg2, skipFunctions, onFunction))
					or visitAstLocalNode(ctx, item.value, onLocal, arg1, arg2, skipFunctions, onFunction)
				then
					return true
				end
			end
		end
		return false
	elseif k == K.AstExprInterpString or k == K.AstExprError then
		return visitAstLocalList(ctx, n.expressions, onLocal, arg1, arg2, skipFunctions, onFunction)
	else
		return visitAstLocalStat(ctx, n, k, onLocal, arg1, arg2, skipFunctions, onFunction)
	end
end

@native
local function canDeferCostModelUndo(ctx: CompilerCtx, expr: any, func: any): boolean
	if expr.finish >= func.start and expr.start <= func.finish then
		return false
	end
	if expr.args == 0 then
		return true
	end
	local kinds = ctx.kinds
	local listValues = ctx.listValues
	local callArgFirst = ctx.listFirsts[expr.args]
	local callArgCount = ctx.listCounts[expr.args]
	for i = 0, callArgCount - 1 do
		local argId = listValues[callArgFirst + i]
		if not isConstant(ctx, argId) then
			local ak = kinds[argId]
			if ak ~= K.AstExprLocal and ak ~= K.AstExprGlobal then
				return false
			end
		end
	end
	return true
end

@native
local function undoCostModelFold(ctx: CompilerCtx, funcId: number, oldExprTop: number, oldLocalTop: number)
	local func = ctx.nodes[funcId]
	if func.args ~= 0 then
		local listValues = ctx.listValues
		local funcArgFirst = ctx.listFirsts[func.args]
		local funcArgCount = ctx.listCounts[func.args]
		local locstantTypes = ctx.locstantTypes
		local locstantVals = ctx.locstantVals
		for i = 0, funcArgCount - 1 do
			local varId = listValues[funcArgFirst + i]
			if locstantTypes[varId] ~= nil then
				locstantTypes[varId] = ConstantType.Unknown
				locstantVals[varId] = nil
			end
		end
	end
	CompilerFolding.undoChanges(ctx.constTypes, ctx.constVals, ctx.exprChanges, oldExprTop)
	CompilerFolding.undoChanges(ctx.locstantTypes, ctx.locstantVals, ctx.localChanges, oldLocalTop, ctx.vars)
end

@native
local function costModelInlinedCall(
	ctx: CompilerCtx,
	exprId: number,
	funcId: number,
	fi: any,
	keepFold: boolean
): (number, number, boolean, number, number)
	local expr = ctx.nodes[exprId]
	local func = ctx.nodes[funcId]
	local funcArgFirst = if func.args ~= 0 then ctx.listFirsts[func.args] else 0
	local funcArgCount = if func.args ~= 0 then ctx.listCounts[func.args] else 0
	local callArgFirst = if expr.args ~= 0 then ctx.listFirsts[expr.args] else 0
	local callArgCount = if expr.args ~= 0 then ctx.listCounts[expr.args] else 0
	local listValues = ctx.listValues
	local varWritten = ctx.vars.written
	local locstantTypes = ctx.locstantTypes
	local locstantVals = ctx.locstantVals
	local constTypes = ctx.constTypes
	local constVals = ctx.constVals
	local hasConstArg = false

	for i = 0, funcArgCount - 1 do
		local varId = listValues[funcArgFirst + i]
		local argId = if i < callArgCount then listValues[callArgFirst + i] else 0
		if i + 1 == callArgCount and funcArgCount > callArgCount and isExprMultRet(ctx, argId) then
			break
		end
		if varWritten[varId] then
			continue
		end
		if argId == 0 then
			locstantTypes[varId] = ConstantType.Nil
			locstantVals[varId] = false
			hasConstArg = true
		elseif isConstant(ctx, argId) then
			locstantTypes[varId] = constTypes[argId]
			locstantVals[varId] = constVals[argId]
			hasConstArg = true
		end
	end

	if
		not hasConstArg
		and not ctx.funcReadTableLocal[funcId]
		and (#fi.upvals == 0 or (#ctx.inlineFrames == 0 and ctx.trialDepth == 0))
		and ctx.inlineBuiltinTop == 0
	then
		return fi.costLo, fi.costHi, false, 0, 0
	end

	local oldExprTop = ctx.exprChanges.top
	local oldLocalTop = ctx.localChanges.top

	CompilerFolding.foldConstants(
		ctx.arena,
		constTypes,
		constVals,
		ctx.vars,
		locstantTypes,
		locstantVals,
		ctx.builtinsFold,
		ctx.builtinsFoldLibraryK,
		ctx.vectorPrecision == 1,
		ctx.opts.libraryMemberConstantCb,
		func.body,
		ctx.tableConstants,
		ctx.flags,
		ctx.exprChanges,
		ctx.localChanges
	)

	local lo, hi = CompilerTypes.modelCostList(ctx.arena, func.body, func.args, ctx.builtins, constTypes, constVals)

	if keepFold then
		return lo, hi, true, oldExprTop, oldLocalTop
	end

	for i = 0, funcArgCount - 1 do
		local varId = listValues[funcArgFirst + i]
		if locstantTypes[varId] ~= nil then
			locstantTypes[varId] = ConstantType.Unknown
			locstantVals[varId] = nil
		end
	end

	CompilerFolding.undoChanges(constTypes, constVals, ctx.exprChanges, oldExprTop)
	CompilerFolding.undoChanges(locstantTypes, locstantVals, ctx.localChanges, oldLocalTop, ctx.vars)
	return lo, hi, false, 0, 0
end

@native
local function isLocalRegEqual(ctx: CompilerCtx, _nodeId: number, n: any, reg: number): boolean
	return getLocalReg(ctx, n["local"]) == reg
end

@native
local function isRegisterUsedInCallArguments(
	ctx: CompilerCtx,
	exprId: number,
	argId: number,
	startArgIndex: number,
	reg: number
): boolean
	local expr = ctx.nodes[exprId]
	if expr.args == 0 then
		return false
	end
	local argsFirst = ctx.listFirsts[expr.args]
	local argsCount = ctx.listCounts[expr.args]
	local listValues = ctx.listValues
	if argId ~= 0 and getExprLocalReg(ctx, argId) ~= reg then
		if visitAstLocalNode(ctx, listValues[argsFirst + startArgIndex], isLocalRegEqual, reg, nil, false) then
			return true
		end
	end
	for i = startArgIndex + 1, argsCount - 1 do
		if visitAstLocalNode(ctx, listValues[argsFirst + i], isLocalRegEqual, reg, nil, false) then
			return true
		end
	end
	return false
end

@native
local function pushInlineArg(
	ctx: CompilerCtx,
	localId: number,
	reg: number,
	ctype: number,
	cval: any,
	allocpc: number,
	initId: number
)
	local top = ctx.inlineArgTop + 1
	ctx.inlineArgTop = top
	ctx.inlineArgLocalIds[top] = localId
	ctx.inlineArgRegs[top] = reg
	ctx.inlineArgTypes[top] = ctype
	ctx.inlineArgVals[top] = cval
	ctx.inlineArgAllocPcs[top] = allocpc
	ctx.inlineArgInits[top] = initId
end

@native
local function bindInlinedWrittenArg(
	ctx: CompilerCtx,
	exprId: number,
	varId: number,
	argId: number,
	i: number,
	target: number,
	canUseParameterTarget: boolean
)
	local temp: number
	local allocpc: number
	if canUseParameterTarget and not isRegisterUsedInCallArguments(ctx, exprId, argId, i, target) then
		temp = target
		allocpc = kDefaultAllocPc
	else
		temp = allocReg(ctx, if argId ~= 0 then argId else exprId, 1)
		allocpc = ctx.bytecode.insnCount
	end
	if argId ~= 0 then
		compileExprTemp(ctx, argId, temp)
	else
		ctx.bytecode:emitABC(Opcodes.LOP_LOADNIL, temp, 0, 0)
	end
	pushInlineArg(ctx, varId, temp, ConstantType.Unknown, nil, allocpc, 0)
end

@native
local function bindInlinedUnwrittenArg(
	ctx: CompilerCtx,
	exprId: number,
	varId: number,
	argId: number,
	i: number,
	target: number,
	canUseParameterTarget: boolean
)
	if argId == 0 then
		pushInlineArg(ctx, varId, kInvalidReg, ConstantType.Nil, false, kDefaultAllocPc, 0)
	elseif isConstant(ctx, argId) then
		pushInlineArg(ctx, varId, kInvalidReg, ctx.constTypes[argId], ctx.constVals[argId], kDefaultAllocPc, 0)
	else
		local leId = getExprLocal(ctx, argId)
		local reLocalId = if leId ~= 0 then ctx.nodes[leId]["local"] else 0
		local reg = if leId ~= 0 then getExprLocalReg(ctx, leId) else -1
		local varWritten = ctx.vars.written
		if reg >= 0 and (reLocalId == 0 or not varWritten[reLocalId]) then
			local initId = if reLocalId ~= 0 and ctx.vars.owner[reLocalId] ~= nil then ctx.vars.init[reLocalId] else 0
			pushInlineArg(ctx, varId, reg, ConstantType.Unknown, nil, kDefaultAllocPc, initId)
		elseif canUseParameterTarget and not isRegisterUsedInCallArguments(ctx, exprId, argId, i, target) then
			compileExprTemp(ctx, argId, target)
			pushInlineArg(ctx, varId, target, ConstantType.Unknown, nil, kDefaultAllocPc, 0)
		else
			local temp = allocReg(ctx, argId, 1)
			local allocpc = ctx.bytecode.insnCount
			temp = compileExprAutoTemp(ctx, argId, temp, target)
			pushInlineArg(ctx, varId, temp, ConstantType.Unknown, nil, allocpc, argId)
		end
	end
end

@native
local function prepareInlinedCallArgs(
	ctx: CompilerCtx,
	exprId: number,
	funcArgFirst: number,
	funcArgCount: number,
	callArgFirst: number,
	callArgCount: number,
	target: number,
	fi: any,
	noTargetMoveElision: boolean
): (number, number)
	local argStart = ctx.inlineArgTop
	local listValues = ctx.listValues
	local varWritten = ctx.vars.written
	local retIsParam = fi.returnKind == ReturnKind.Parameter and not noTargetMoveElision
	local retLocal = fi.returnLocal

	for i = 0, funcArgCount - 1 do
		local varId = listValues[funcArgFirst + i]
		local argId = if i < callArgCount then listValues[callArgFirst + i] else 0
		local canUseParameterTarget = retIsParam and retLocal == varId

		if i + 1 == callArgCount and funcArgCount > callArgCount and isExprMultRet(ctx, argId) then
			local tail = (funcArgCount - callArgCount) + 1
			local temp = allocReg(ctx, argId, tail)
			local allocpc = ctx.bytecode.insnCount
			local ak = ctx.kinds[argId]
			if ak == K.AstExprCall then
				compileExprCall(ctx, argId, temp, tail, true)
			elseif ak == K.AstExprVarargs then
				compileExprVarargs(ctx, argId, temp, tail)
			else
				error("Unexpected expression type")
			end
			for j = i, funcArgCount - 1 do
				pushInlineArg(ctx, listValues[funcArgFirst + j], temp + (j - i), ConstantType.Unknown, nil, allocpc, 0)
			end
			break
		elseif varWritten[varId] then
			bindInlinedWrittenArg(ctx, exprId, varId, argId, i, target, canUseParameterTarget)
		else
			bindInlinedUnwrittenArg(ctx, exprId, varId, argId, i, target, canUseParameterTarget)
		end
	end

	for i = funcArgCount, callArgCount - 1 do
		compileExprSide(ctx, listValues[callArgFirst + i])
	end
	return argStart, ctx.inlineArgTop
end

@native
local function canResolveBuiltinInit(ctx: CompilerCtx, initId: number): boolean
	local nodes = ctx.nodes
	local kinds = ctx.kinds
	local varWritten = ctx.vars.written
	local varInit = ctx.vars.init
	local curId = initId
	while curId ~= 0 do
		local k = kinds[curId]
		if k == nil then
			return false
		end
		if k == K.AstExprLocal then
			local lid = nodes[curId]["local"]
			if not varWritten[lid] then
				local nextInit = varInit[lid]
				if nextInit and nextInit ~= 0 then
					curId = nextInit
					continue
				end
			end
			return false
		elseif k == K.AstExprGlobal then
			return true
		elseif k == K.AstExprIndexName then
			curId = nodes[curId].expr
			continue
		elseif k == K.AstExprBinary then
			local node = nodes[curId]
			if node.op == "Or" then
				return canResolveBuiltinInit(ctx, node.left) or canResolveBuiltinInit(ctx, node.right)
			end
		end
		return false
	end
	return false
end

@native
local function setupInlinedCallFrame(
	ctx: CompilerCtx,
	funcId: number,
	func: any,
	fi: any,
	argStart: number,
	argEnd: number,
	oldLocals: number,
	target: number,
	targetCount: number,
	resultLocal: number,
	alreadyFolded: boolean,
	foldedExprTop: number,
	foldedLocalTop: number
)
	local checkBuiltins = ctx.funcHasCalls[funcId] == true
	local hasBuiltinInitArg = false
	local hasConstArg = false
	local addedVarInit = false
	local argLocalIds = ctx.inlineArgLocalIds
	local argRegs = ctx.inlineArgRegs
	local argAllocPcs = ctx.inlineArgAllocPcs
	local argInits = ctx.inlineArgInits
	local argTypes = ctx.inlineArgTypes
	local argVals = ctx.inlineArgVals
	local varOwner = ctx.vars.owner
	local varInit = ctx.vars.init
	local locstantTypes = ctx.locstantTypes
	local locstantVals = ctx.locstantVals

	for idx = argStart + 1, argEnd do
		local ctype = argTypes[idx]
		local localId = argLocalIds[idx]
		if ctype == ConstantType.Unknown then
			pushLocal(ctx, localId, argRegs[idx], argAllocPcs[idx])
			local argInit = argInits[idx]
			if argInit ~= 0 then
				if varOwner[localId] ~= nil then
					varInit[localId] = argInit
					addedVarInit = true
				end
				if checkBuiltins and not hasBuiltinInitArg and canResolveBuiltinInit(ctx, argInit) then
					hasBuiltinInitArg = true
				end
			end
		else
			locstantTypes[localId] = ctype
			locstantVals[localId] = argVals[idx]
			hasConstArg = true
		end
	end
	ctx.inlineArgTop = argStart

	local oldBuiltinTop = ctx.inlineBuiltinTop
	local addedNewBuiltin = false
	if hasBuiltinInitArg then
		table.clear(ctx.inlineBuiltins)
		CompilerBuiltins.analyzeBuiltins(
			ctx.inlineBuiltins,
			ctx.globals,
			ctx.vars,
			ctx.opts,
			func.body,
			ctx.arena,
			ctx.flags
		)

		if next(ctx.inlineBuiltins) ~= nil then
			local builtinsMap = ctx.builtins
			local keys = ctx.inlineBuiltinKeys
			local oldVals = ctx.inlineBuiltinOldVals
			local bTop = oldBuiltinTop
			for callExprId, bfid in ctx.inlineBuiltins do
				local oldBuiltin = builtinsMap[callExprId] or Builtins.LBF_NONE
				if bfid ~= oldBuiltin then
					bTop += 1
					keys[bTop] = callExprId
					oldVals[bTop] = oldBuiltin
					builtinsMap[callExprId] = bfid
					addedNewBuiltin = true
				end
			end
			ctx.inlineBuiltinTop = bTop
			table.clear(ctx.inlineBuiltins)
		end
	end

	local oldExprChangeTop = if alreadyFolded then foldedExprTop else ctx.exprChanges.top
	local oldLocalChangeTop = if alreadyFolded then foldedLocalTop else ctx.localChanges.top

	local framePool = ctx.inlineFramePool
	local poolLen = #framePool
	local frame: any
	if poolLen > 0 then
		frame = framePool[poolLen]
		framePool[poolLen] = nil
		frame.func = funcId
		frame.oldLocals = oldLocals
		frame.target = target
		frame.targetCount = targetCount
		frame.resultLocal = resultLocal
		frame.returnJumps = acquireJumpList(ctx)
		frame.oldBuiltinTop = oldBuiltinTop
		frame.oldExprChangeTop = oldExprChangeTop
		frame.oldLocalChangeTop = oldLocalChangeTop
	else
		frame = {
			func = funcId,
			oldLocals = oldLocals,
			target = target,
			targetCount = targetCount,
			resultLocal = resultLocal,
			returnJumps = acquireJumpList(ctx),
			oldBuiltinTop = oldBuiltinTop,
			oldExprChangeTop = oldExprChangeTop,
			oldLocalChangeTop = oldLocalChangeTop,
		}
	end
	local inlineFrames = ctx.inlineFrames
	inlineFrames[#inlineFrames + 1] = frame

	local needFold = if alreadyFolded
		then (addedNewBuiltin or addedVarInit)
		else (
			hasConstArg
			or addedNewBuiltin
			or ctx.funcReadTableLocal[funcId]
			or (#fi.upvals > 0 and (#inlineFrames > 1 or ctx.trialDepth > 0))
		)
	if needFold then
		CompilerFolding.foldConstants(
			ctx.arena,
			ctx.constTypes,
			ctx.constVals,
			ctx.vars,
			locstantTypes,
			locstantVals,
			ctx.builtinsFold,
			ctx.builtinsFoldLibraryK,
			ctx.vectorPrecision == 1,
			ctx.opts.libraryMemberConstantCb,
			func.body,
			ctx.tableConstants,
			ctx.flags,
			ctx.exprChanges,
			ctx.localChanges
		)
	end
end

@native
local function teardownInlinedCallFrame(
	ctx: CompilerCtx,
	exprId: number,
	funcArgFirst: number,
	funcArgCount: number,
	oldLocals: number
)
	popLocals(ctx, oldLocals)

	local returnLabel = ctx.bytecode:emitLabel()
	local inlineFrames = ctx.inlineFrames
	local frameCount = #inlineFrames
	local currFrame = inlineFrames[frameCount]
	patchJumps(ctx, exprId, currFrame.returnJumps, returnLabel)
	inlineFrames[frameCount] = nil

	local oldBuiltinTop = currFrame.oldBuiltinTop
	local oldExprChangeTop = currFrame.oldExprChangeTop
	local oldLocalChangeTop = currFrame.oldLocalChangeTop
	releaseJumpList(ctx, currFrame.returnJumps)
	currFrame.returnJumps = EMPTY_JUMP_LIST
	local framePool = ctx.inlineFramePool
	framePool[#framePool + 1] = currFrame

	local listValues = ctx.listValues
	local locstantTypes = ctx.locstantTypes
	local locstantVals = ctx.locstantVals
	local varOwner = ctx.vars.owner
	local varInit = ctx.vars.init
	for i = 0, funcArgCount - 1 do
		local localId = listValues[funcArgFirst + i]
		if locstantTypes[localId] ~= nil then
			locstantTypes[localId] = ConstantType.Unknown
			locstantVals[localId] = nil
		end
		if varOwner[localId] ~= nil then
			varInit[localId] = 0
		end
	end

	if ctx.inlineBuiltinTop > oldBuiltinTop then
		local builtinsMap = ctx.builtins
		local keys = ctx.inlineBuiltinKeys
		local oldVals = ctx.inlineBuiltinOldVals
		for i = ctx.inlineBuiltinTop, oldBuiltinTop + 1, -1 do
			builtinsMap[keys[i]] = oldVals[i]
		end
		ctx.inlineBuiltinTop = oldBuiltinTop
	end

	if ctx.exprChanges.top > oldExprChangeTop then
		CompilerFolding.undoChanges(ctx.constTypes, ctx.constVals, ctx.exprChanges, oldExprChangeTop)
	end
	if ctx.localChanges.top > oldLocalChangeTop then
		CompilerFolding.undoChanges(locstantTypes, locstantVals, ctx.localChanges, oldLocalChangeTop, ctx.vars)
	end
end

@native
local function compileInlinedCall(
	ctx: CompilerCtx,
	exprId: number,
	funcId: number,
	target: number,
	targetCount: number,
	multRet: boolean,
	alreadyFolded: boolean,
	foldedExprTop: number,
	foldedLocalTop: number
)
	local oldTop = ctx.regTop
	assert(not multRet, "inlined call cannot be multRet")
	local oldLocals = #ctx.localStack

	local expr = ctx.nodes[exprId]
	local func = ctx.nodes[funcId]
	local funcArgFirst = if func.args ~= 0 then ctx.listFirsts[func.args] else 0
	local funcArgCount = if func.args ~= 0 then ctx.listCounts[func.args] else 0
	local callArgFirst = if expr.args ~= 0 then ctx.listFirsts[expr.args] else 0
	local callArgCount = if expr.args ~= 0 then ctx.listCounts[expr.args] else 0

	local fi = ctx.functions[funcId]
	assert(fi, "missing function info")

	local originalTarget = target
	if ctx.flags.LuauCompileCapturedCallTarget then
		for i = 0, targetCount - 1 do
			if ctx.regCaptured[target + i] then
				target = allocReg(ctx, exprId, targetCount)
				break
			end
		end
	end

	local noTargetMoveElision = fi.returnLocalCaptured or targetCount == 0 or ctx.regCaptured[target]

	local argStart, argEnd = prepareInlinedCallArgs(
		ctx,
		exprId,
		funcArgFirst,
		funcArgCount,
		callArgFirst,
		callArgCount,
		target,
		fi,
		noTargetMoveElision
	)

	local resultLocal: number = if fi.returnKind == ReturnKind.Local and not noTargetMoveElision
		then fi.returnLocal
		else 0

	setupInlinedCallFrame(
		ctx,
		funcId,
		func,
		fi,
		argStart,
		argEnd,
		oldLocals,
		target,
		targetCount,
		resultLocal,
		alreadyFolded,
		foldedExprTop,
		foldedLocalTop
	)

	local terminatesEarly = false
	local callerClasses = ctx.currClasses
	if ctx.flagDebugClasses then
		local calleeClasses = ctx.enclosingClasses[funcId]
		if calleeClasses then
			ctx.currClasses = calleeClasses
		end
	end

	local bodyNode = ctx.nodes[func.body]
	local bodyFirst = if bodyNode.body ~= 0 then ctx.listFirsts[bodyNode.body] else 0
	local bodyCount = if bodyNode.body ~= 0 then ctx.listCounts[bodyNode.body] else 0
	local listValues = ctx.listValues

	local prevOwner, prevBase, prevLiveCount, prevMinFinish = enterBlockLive(ctx, func.body)
	local kinds = ctx.kinds
	for i = 0, bodyCount - 1 do
		local statId = listValues[bodyFirst + i]
		popStatLocals(ctx, statId)
		compileStat(ctx, statId)
		local sk = kinds[statId]
		if sk ~= nil then
			if
				sk == K.AstStatReturn
				or sk == K.AstStatBreak
				or sk == K.AstStatContinue
				or (
					(sk == K.AstStatBlock or sk == K.AstStatIf)
					and CompilerFolding.alwaysTerminates(ctx.arena, ctx.constTypes, ctx.constVals, statId)
				)
			then
				terminatesEarly = true
				local currFrame = ctx.inlineFrames[#ctx.inlineFrames]
				local rj = currFrame.returnJumps
				if #rj > 0 and rj[#rj] == ctx.bytecode:emitLabel() - 1 then
					ctx.bytecode:undoEmit(Opcodes.LOP_JUMP)
					rj[#rj] = nil
				end
				break
			end
		end
	end
	leaveBlockLive(ctx, prevOwner, prevBase, prevLiveCount, prevMinFinish)

	ctx.currClasses = callerClasses

	if not terminatesEarly then
		for i = 0, targetCount - 1 do
			ctx.bytecode:emitABC(Opcodes.LOP_LOADNIL, target + i, 0, 0)
		end
		closeLocals(ctx, oldLocals)
	end

	teardownInlinedCallFrame(ctx, exprId, funcArgFirst, funcArgCount, oldLocals)

	if ctx.flags.LuauCompileCapturedCallTarget and target ~= originalTarget then
		for i = 0, targetCount - 1 do
			ctx.bytecode:emitABC(Opcodes.LOP_MOVE, originalTarget + i, target + i, 0)
		end
	end

	ctx.regTop = oldTop
end

@native
local function computeInlineProfit(
	ctx: CompilerCtx,
	exprId: number,
	funcId: number,
	fi: any,
	thresholdMaxBoost: number,
	keepFold: boolean
): (number, number, boolean, number, number)
	local expr = ctx.nodes[exprId]
	local func = ctx.nodes[funcId]
	local funcArgCount = if func.args ~= 0 then ctx.listCounts[func.args] else 0
	local callArgFirst = if expr.args ~= 0 then ctx.listFirsts[expr.args] else 0
	local callArgCount = if expr.args ~= 0 then ctx.listCounts[expr.args] else 0
	local listValues = ctx.listValues

	local varc = ctx.inlineVarc
	local hasConstant = false
	local limit = math.min(funcArgCount, callArgCount, 8)
	for i = 0, limit - 1 do
		if isConstant(ctx, listValues[callArgFirst + i]) then
			if not hasConstant then
				for idx = 1, 8 do
					varc[idx] = false
				end
				hasConstant = true
			end
			varc[i + 1] = true
		end
	end

	if callArgCount ~= 0 and not isExprMultRet(ctx, listValues[callArgFirst + callArgCount - 1]) then
		for i = callArgCount, math.min(funcArgCount, 8) - 1 do
			if not hasConstant then
				for idx = 1, 8 do
					varc[idx] = false
				end
				hasConstant = true
			end
			varc[i + 1] = true
		end
	end

	local inlinedCost: number
	local folded = false
	local foldedExprTop = 0
	local foldedLocalTop = 0
	if hasConstant then
		local callCostLo, callCostHi
		callCostLo, callCostHi, folded, foldedExprTop, foldedLocalTop =
			costModelInlinedCall(ctx, exprId, funcId, fi, keepFold)
		inlinedCost = CompilerTypes.computeCost(callCostLo, callCostHi, varc, math.min(funcArgCount, 8))
	else
		inlinedCost = CompilerTypes.computeCost(fi.costLo, fi.costHi, nil, 0)
	end
	local baselineCost = CompilerTypes.computeCost(fi.costLo, fi.costHi, nil, 0) + 3
	local inlineProfit = if inlinedCost == 0
		then thresholdMaxBoost
		else math.min(thresholdMaxBoost, math.floor(100 * baselineCost / inlinedCost))
	return inlinedCost, inlineProfit, folded, foldedExprTop, foldedLocalTop
end

@native
local function tryCompileInlinedCall(
	ctx: CompilerCtx,
	exprId: number,
	funcId: number,
	target: number,
	targetCount: number,
	multRet: boolean,
	thresholdBase: number,
	thresholdMaxBoost: number,
	depthLimit: number
): boolean
	local fi = ctx.functions[funcId]
	assert(fi, "missing function info")

	if ctx.regTop > 128 or fi.stackSize > 32 then
		if ctx.bytecode:needsDebugRemarks() then
			ctx.bytecode:addDebugRemark("inlining failed: high register pressure")
		end
		return false
	end
	if #ctx.inlineFrames >= depthLimit then
		if ctx.bytecode:needsDebugRemarks() then
			ctx.bytecode:addDebugRemark("inlining failed: too many inlined frames")
		end
		return false
	end
	for i = 1, #ctx.inlineFrames do
		if ctx.inlineFrames[i].func == funcId then
			if ctx.bytecode:needsDebugRemarks() then
				ctx.bytecode:addDebugRemark("inlining failed: can't inline recursive calls")
			end
			return false
		end
	end
	if ctx.flagDebugClasses then
		local calleeClasses = ctx.enclosingClasses[funcId]
		if calleeClasses then
			local callerClasses = ctx.currClasses
			local mismatch = callerClasses == nil or #calleeClasses > #callerClasses
			if not mismatch and callerClasses ~= nil then
				for i = 1, #calleeClasses do
					if calleeClasses[i] ~= callerClasses[i] then
						mismatch = true
						break
					end
				end
			end
			if mismatch then
				if ctx.bytecode:needsDebugRemarks() then
					ctx.bytecode:addDebugRemark("inlining failed: mismatched enclosing classes")
				end
				return false
			end
		end
	end
	if multRet then
		if ctx.bytecode:needsDebugRemarks() then
			ctx.bytecode:addDebugRemark("inlining failed: can't convert fixed returns to multret")
		end
		return false
	end

	local expr = ctx.nodes[exprId]
	local func = ctx.nodes[funcId]
	local keepFold = canDeferCostModelUndo(ctx, expr, func)
	local inlinedCost, inlineProfit, folded, foldedExprTop, foldedLocalTop =
		computeInlineProfit(ctx, exprId, funcId, fi, thresholdMaxBoost, keepFold)
	local threshold = math.floor(thresholdBase * inlineProfit / 100)
	local isIife = CompilerFolding.unwrapExprOfType(ctx.arena, expr.func, K.AstExprFunction) ~= 0

	if inlinedCost > threshold and not isIife then
		if folded then
			undoCostModelFold(ctx, funcId, foldedExprTop, foldedLocalTop)
		end
		if ctx.bytecode:needsDebugRemarks() then
			ctx.bytecode:addDebugRemark(
				string.format("inlining failed: too expensive (cost %d, profit %.2fx)", inlinedCost, inlineProfit / 100)
			)
		end
		return false
	end

	if ctx.bytecode:needsDebugRemarks() then
		ctx.bytecode:addDebugRemark(
			string.format(
				"inlining succeeded (cost %d, profit %.2fx, depth %d)",
				inlinedCost,
				inlineProfit / 100,
				#ctx.inlineFrames
			)
		)
	end

	compileInlinedCall(ctx, exprId, funcId, target, targetCount, multRet, folded, foldedExprTop, foldedLocalTop)
	return true
end

@native
local function tryInlineCallExpr(
	ctx: CompilerCtx,
	exprId: number,
	expr: any,
	target: number,
	targetCount: number,
	isMultRet: boolean
): boolean
	if ctx.optimizationLevel >= 2 and not expr.self then
		local funcId = getFunctionExpr(ctx, expr.func)
		local fi = if funcId ~= 0 then ctx.functions[funcId] else nil
		if
			fi
			and fi.canInline
			and tryCompileInlinedCall(
				ctx,
				exprId,
				funcId,
				target,
				targetCount,
				isMultRet,
				ctx.flags.LuauCompileInlineThreshold,
				ctx.flags.LuauCompileInlineThresholdMaxBoost,
				ctx.flags.LuauCompileInlineDepth
			)
		then
			return true
		end
		if funcId ~= 0 and not (fi and fi.canInline) and ctx.bytecode:needsDebugRemarks() then
			if ctx.nodes[funcId].vararg then
				ctx.bytecode:addDebugRemark("inlining failed: function is variadic")
			elseif not fi then
				ctx.bytecode:addDebugRemark("inlining failed: can't inline recursive calls")
			elseif ctx.getfenvUsed or ctx.setfenvUsed then
				ctx.bytecode:addDebugRemark("inlining failed: module uses getfenv/setfenv")
			end
		end
	end
	return false
end

@native
local function foldUnrolledForIteration(
	ctx: CompilerCtx,
	statId: number,
	varId: number,
	val: number,
	recordChanges: boolean
)
	ctx.locstantTypes[varId] = ConstantType.Number
	ctx.locstantVals[varId] = val

	CompilerFolding.foldConstants(
		ctx.arena,
		ctx.constTypes,
		ctx.constVals,
		ctx.vars,
		ctx.locstantTypes,
		ctx.locstantVals,
		ctx.builtinsFold,
		ctx.builtinsFoldLibraryK,
		ctx.vectorPrecision == 1,
		ctx.opts.libraryMemberConstantCb,
		statId,
		ctx.tableConstants,
		ctx.flags,
		if recordChanges then ctx.exprChanges else nil,
		if recordChanges then ctx.localChanges else nil
	)
end

@native
local function compileUnrolledFor(ctx: CompilerCtx, statId: number, tripCount: number, from: number, step: number)
	local stat = ctx.nodes[statId]
	local varId = stat.var
	local oldLocals = #ctx.localStack
	local oldJumps = ctx.loopJumpCount

	local ld = ctx.loopDepth + 1
	ctx.loopDepth = ld
	ctx.loopLocalOffsets[ld] = oldLocals
	ctx.loopLocalOffsetsContinue[ld] = oldLocals
	ctx.loopContinueUsed[ld] = 0

	ctx.exprChanges.top = 0
	ctx.localChanges.top = 0
	local inlineFrames = ctx.inlineFrames
	for i = 1, #inlineFrames do
		ctx.funcReadTableLocal[inlineFrames[i].func] = true
	end

	ctx.trialDepth += 1
	local negZeroFlag = ctx.flags.LuauCompileLoopUnrollNegativeZero
	local loopJumpTypes = ctx.loopJumpTypes
	local loopJumpLabels = ctx.loopJumpLabels
	for iv = 0, tripCount - 1 do
		local val = if negZeroFlag and iv == 0 then from else from + iv * step
		foldUnrolledForIteration(ctx, statId, varId, val, iv == 0)

		local iterJumps = ctx.loopJumpCount
		compileStat(ctx, stat.body)

		local contLabel = ctx.bytecode:emitLabel()
		for i = iterJumps + 1, ctx.loopJumpCount do
			if loopJumpTypes[i] == LoopJumpType.Continue then
				patchJump(ctx, statId, loopJumpLabels[i], contLabel)
			end
		end
	end
	ctx.trialDepth -= 1

	local endLabel = ctx.bytecode:emitLabel()
	patchLoopJumps(ctx, statId, oldJumps, endLabel, -1)
	ctx.loopDepth = ld - 1

	if ctx.locstantTypes[varId] ~= nil then
		ctx.locstantTypes[varId] = ConstantType.Unknown
		ctx.locstantVals[varId] = nil
	end

	CompilerFolding.undoChanges(ctx.constTypes, ctx.constVals, ctx.exprChanges, 0)
	CompilerFolding.undoChanges(ctx.locstantTypes, ctx.locstantVals, ctx.localChanges, 0, ctx.vars)
end

@native
local function tryCompileUnrolledFor(
	ctx: CompilerCtx,
	statId: number,
	thresholdBase: number,
	thresholdMaxBoost: number
): boolean
	local stat = ctx.nodes[statId]
	local constTypes = ctx.constTypes
	local constVals = ctx.constVals
	local fromT = constTypes[stat.from]
	local toT = constTypes[stat.to]
	local stepT = if stat.step ~= 0 then constTypes[stat.step] else ConstantType.Number

	if fromT ~= ConstantType.Number or toT ~= ConstantType.Number or stepT ~= ConstantType.Number then
		if ctx.bytecode:needsDebugRemarks() then
			ctx.bytecode:addDebugRemark("loop unroll failed: invalid iteration count")
		end
		return false
	end

	local fromNum = constVals[stat.from] :: number
	local toNum = constVals[stat.to] :: number
	local stepNum = if stat.step ~= 0 then constVals[stat.step] :: number else 1.0
	local tripCount = CompilerTypes.getTripCount(fromNum, toNum, stepNum)

	if tripCount < 0 then
		if ctx.bytecode:needsDebugRemarks() then
			ctx.bytecode:addDebugRemark("loop unroll failed: invalid iteration count")
		end
		return false
	end

	if tripCount == 0 then
		if ctx.bytecode:needsDebugRemarks() then
			ctx.bytecode:addDebugRemark("loop unroll succeeded: empty loop")
		end
		return true
	end

	if tripCount > thresholdBase then
		if ctx.bytecode:needsDebugRemarks() then
			ctx.bytecode:addDebugRemark(string.format("loop unroll failed: too many iterations (%d)", tripCount))
		end
		return false
	end

	if ctx.vars.written[stat.var] then
		if ctx.bytecode:needsDebugRemarks() then
			ctx.bytecode:addDebugRemark("loop unroll failed: mutable loop variable")
		end
		return false
	end

	local termCache = if #ctx.inlineFrames == 0 and ctx.trialDepth == 0 then ctx.alwaysTermCache else nil
	local costLo, costHi =
		CompilerTypes.modelCostSingleVar(ctx.arena, stat.body, stat.var, ctx.builtins, constTypes, constVals, termCache)
	local unrolledCost = CompilerTypes.computeCost(costLo, costHi, SINGLE_TRUE_VARC, 1) * tripCount
	local baselineCost = (CompilerTypes.computeCost(costLo, costHi, nil, 0) + 1) * tripCount
	local unrollProfit = if unrolledCost == 0
		then thresholdMaxBoost
		else math.min(thresholdMaxBoost, math.floor(100 * baselineCost / unrolledCost))

	local threshold = math.floor(thresholdBase * unrollProfit / 100)
	if unrolledCost > threshold then
		if ctx.bytecode:needsDebugRemarks() then
			ctx.bytecode:addDebugRemark(
				string.format(
					"loop unroll failed: too expensive (iterations %d, cost %d, profit %.2fx)",
					tripCount,
					unrolledCost,
					unrollProfit / 100
				)
			)
		end
		return false
	end

	if ctx.bytecode:needsDebugRemarks() then
		ctx.bytecode:addDebugRemark(
			string.format(
				"loop unroll succeeded (iterations %d, cost %d, profit %.2fx)",
				tripCount,
				unrolledCost,
				unrollProfit / 100
			)
		)
	end

	compileUnrolledFor(ctx, statId, tripCount, fromNum, stepNum)
	return true
end

return table.freeze({
	bind = bind,
	visitAstLocalNode = visitAstLocalNode,
	tryInlineCallExpr = tryInlineCallExpr,
	tryCompileUnrolledFor = tryCompileUnrolledFor,
})
