--!strict
-- Luau 0.748 Compiler.cpp port.
-- Upstream Luau is MIT licensed; see ../LICENSE.md and ../UPSTREAM.json.
local Arena = require("./Arena")
local BytecodeBuilder = require("./BytecodeBuilder")
local BytecodeCodec = require("./BytecodeCodec")
local BytecodeDefs = require("./BytecodeDefs")
local CompilerBuiltins = require("./CompilerBuiltins")
local CompilerExpr = require("./CompilerExpr")
local CompilerFolding = require("./CompilerFolding")
local Diagnostics = require("./Diagnostics")
local Profiles = require("./Profiles")
local PublicTypes = require("./Types")

local K = Arena.Kinds
local Opcodes = BytecodeDefs.Opcodes
local Types = BytecodeDefs.Types
local ProtoFlags = BytecodeDefs.ProtoFlags

local CompilerFlags = BytecodeDefs.CompilerFlags

local TABLE_HASH = BytecodeBuilder.getStringHash("table")
local FREEZE_HASH = BytecodeBuilder.getStringHash("freeze")

local function makeProfileCompilerFlags(profileFlags: { [string]: any }): { [string]: any }
	local out = table.clone(CompilerFlags :: { [string]: any })
	for k, v in profileFlags do
		out[k] = v
	end
	return table.freeze(out)
end

local upstreamProfileFlags: { [string]: any }? = nil
local studioProfileFlags: { [string]: any }? = nil
local defaultUpstreamFlags: { [string]: any }? = nil
local defaultStudioFlags: { [string]: any }? = nil

local function ensureDefaultProfileFlags()
	if defaultUpstreamFlags == nil then
		local up = Profiles.resolve("upstream") :: { [string]: any }
		local st = Profiles.resolve("studio") :: { [string]: any }
		upstreamProfileFlags = up
		studioProfileFlags = st
		defaultUpstreamFlags = makeProfileCompilerFlags(up)
		defaultStudioFlags = makeProfileCompilerFlags(st)
	end
end

local CompilerClassMod: any = nil
local CompilerInlineMod: any = nil
local CompilerTypesMod: any = nil
local cachedModelCostList: any = nil
local cachedTryInlineCallExpr: any = nil
local cachedVisitAstLocalNode: any = nil
local cachedTryCompileUnrolledFor: any = nil
local ParserMod: any = nil

local function getParser(): any
	local mod = ParserMod
	if mod == nil then
		mod = require("./Parser")
		ParserMod = mod
	end
	return mod
end

local function getCompilerTypes(): any
	local mod = CompilerTypesMod
	if mod == nil then
		mod = require("./CompilerTypes")
		CompilerTypesMod = mod
		cachedModelCostList = mod.modelCostList
	end
	return mod
end

local sharedParserCtx: any = nil
local parserCtxBusy = false

local function parseSourceFast(source: string, resolvedParseOpts: any?): any
	local Parser = getParser()
	if resolvedParseOpts == nil and not parserCtxBusy then
		local pctx = sharedParserCtx
		if pctx == nil then
			pctx = Parser.newContext()
			sharedParserCtx = pctx
		end
		parserCtxBusy = true
		local ok, res = pcall(pctx.parse, pctx, source)
		parserCtxBusy = false
		if not ok then
			error(res, 0)
		end
		return res
	end
	return Parser.parse(source, resolvedParseOpts)
end

local EMPTY_EXPORTS = table.freeze({
	exportedClasses = table.freeze({} :: { [number]: number }),
	exportedFunctions = table.freeze({} :: { [number]: boolean }),
	exportedVariables = table.freeze({} :: { number }),
	exportedTableCid = -1,
	hasExports = false,
	hasTypeExports = false,
	hasModuleReturn = false,
}) :: any

local kMaxRegisterCount = 255
local kMaxUpvalueCount = 200
local kMaxLocalCount = 200
local kMaxInstructionCount = 1_000_000_000
local kInvalidReg = 255
local kDefaultAllocPc = 0xffffffff
local kInvalidUpvalue = -1

local LValueKind = table.freeze({
	Local = 1,
	Upvalue = 2,
	Global = 3,
	IndexName = 4,
	IndexNumber = 5,
	IndexExpr = 6,
	PrivateField = 7,
})

local LoopJumpType = table.freeze({
	Break = 0,
	Continue = 1,
})

local ReturnKind = table.freeze({
	None = 0,
	Expression = 1,
	Parameter = 2,
	Local = 3,
	Unknown = 4,
})

export type CompileConstant = PublicTypes.CompileConstant
type InternalConstant = CompilerBuiltins.Constant
export type CompileOptions = PublicTypes.CompileOptions
export type CompileResult = PublicTypes.CompileResult

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

local getCompilerClass: () -> any
local getCompilerInline: () -> any

local unrollConcats = CompilerExpr.unrollConcats
local isExprMultRet = CompilerExpr.isExprMultRet
local compileConditionValue = CompilerExpr.compileConditionValue
local compileExpr = CompilerExpr.compileExpr
local compileExprTemp = CompilerExpr.compileExprTemp
local compileExprAutoTemp = CompilerExpr.compileExprAutoTemp
local compileExprAuto = CompilerExpr.compileExprAuto
local compileExprSide = CompilerExpr.compileExprSide
local compileExprTempN = CompilerExpr.compileExprTempN
local compileExprListTemp = CompilerExpr.compileExprListTemp
local compileExprTempMultRet = CompilerExpr.compileExprTempMultRet
local compileExprTempTop = CompilerExpr.compileExprTempTop
local compileExprCall = CompilerExpr.compileExprCall
local compileExprFunction = CompilerExpr.compileExprFunction
local compileLValueUnboxed = CompilerExpr.compileLValueUnboxed
local compileLValueUseUnboxed = CompilerExpr.compileLValueUseUnboxed

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

local function hasAttribute(arena: any, attrsListId: number, targetType: string): boolean
	if attrsListId == 0 then
		return false
	end
	return Arena.listHasProp(arena, attrsListId, "type", targetType)
end

type AssignScratch = CompilerExpr.AssignScratch
type CompilerCtx = CompilerExpr.CompilerCtx

@native
local function acquireJumpList(ctx: CompilerCtx): { number }
	local pool = ctx.jumpListPool
	local n = #pool
	if n > 0 then
		local list = pool[n]
		pool[n] = nil
		return list
	end
	return {}
end

@native
local function releaseJumpList(ctx: CompilerCtx, list: { number })
	table.clear(list)
	local pool = ctx.jumpListPool
	pool[#pool + 1] = list
end

@native
local function acquireKeyValMap(ctx: CompilerCtx): { [number]: number }
	local pool = ctx.keyValMapPool
	local n = #pool
	if n > 0 then
		local map = pool[n]
		pool[n] = nil
		return map
	end
	return {}
end

@native
local function releaseKeyValMap(ctx: CompilerCtx, map: { [number]: number })
	table.clear(map)
	local pool = ctx.keyValMapPool
	pool[#pool + 1] = map
end

@native
local function acquireConcatList(ctx: CompilerCtx): { number }
	local pool = ctx.concatPool
	local n = #pool
	if n > 0 then
		local list = pool[n]
		pool[n] = nil
		return list
	end
	return {}
end

@native
local function releaseConcatList(ctx: CompilerCtx, list: { number })
	table.clear(list)
	local pool = ctx.concatPool
	pool[#pool + 1] = list
end

@native
local function acquireAssignScratch(ctx: CompilerCtx): AssignScratch
	local pool = ctx.assignScratchPool
	local n = #pool
	if n > 0 then
		local sc = pool[n]
		pool[n] = nil
		return sc
	end
	return {
		lvKinds = {},
		lvRegs = {},
		lvAuxs = {},
		lvNames = {},
		lvSymIds = {},
		lvStarts = {},
		lvFinishes = {},
		conflictRegs = {},
		valueRegs = {},
		conflict = {},
		assigned = {},
	}
end

@native
local function releaseAssignScratch(ctx: CompilerCtx, sc: AssignScratch)
	table.clear(sc.lvNames)
	local pool = ctx.assignScratchPool
	pool[#pool + 1] = sc
end

@native
local function getLine0(ctx: CompilerCtx, offset: number): number
	if offset >= ctx.lastLineStart and offset < ctx.lastLineEnd then
		return ctx.lastLineNum - 1
	end
	local starts = ctx.lineStarts
	local n = #starts
	local idx = ctx.lastLineIdx
	if offset >= starts[idx] then
		if idx == n or offset < starts[idx + 1] then
			ctx.lastLineStart = starts[idx]
			ctx.lastLineEnd = if idx < n then starts[idx + 1] else math.huge
			ctx.lastLineNum = idx
			return idx - 1
		end
		if idx + 1 == n or offset < starts[idx + 2] then
			local nextIdx = idx + 1
			ctx.lastLineIdx = nextIdx
			ctx.lastLineStart = starts[nextIdx]
			ctx.lastLineEnd = if nextIdx < n then starts[nextIdx + 1] else math.huge
			ctx.lastLineNum = nextIdx
			return idx
		end
	end
	local line, _ = Diagnostics.position(starts, offset)
	local newIdx = line + 1
	ctx.lastLineIdx = newIdx
	ctx.lastLineStart = starts[newIdx]
	ctx.lastLineEnd = if newIdx < n then starts[newIdx + 1] else math.huge
	ctx.lastLineNum = newIdx
	return line
end

local function raiseCompileError(ctx: CompilerCtx, offset: number, finish: number, msg: string): never
	error({
		compileError = true,
		line = getLine0(ctx, offset) + 1,
		start = offset,
		finish = finish,
		message = msg,
	}, 0)
end

@native
local function getOrAddSymbol(ctx: CompilerCtx, str: string): number
	local existing = ctx.symbolByName[str]
	if existing then
		return existing
	end
	local nextId = #ctx.symbols + 1
	ctx.symbols[nextId] = str
	ctx.symbolByName[str] = nextId
	return nextId
end

@native
local function getSymHash(ctx: CompilerCtx, symId: number, name: string): number
	local hashes = ctx.symbolHashes
	local cached = hashes[symId]
	if cached ~= nil then
		return cached
	end
	local h = BytecodeBuilder.getStringHash(name)
	hashes[symId] = h
	return h
end

local function isExportsEmpty(ctx: CompilerCtx): boolean
	return not ctx.exports.hasExports
		and next(ctx.exports.exportedClasses) == nil
		and next(ctx.exports.exportedFunctions) == nil
		and #ctx.exports.exportedVariables == 0
end

@native
local function getLocalReg(ctx: CompilerCtx, localId: number): number
	return if ctx.localAllocated[localId] then ctx.localReg[localId] else -1
end

@native
local function getUpval(ctx: CompilerCtx, localId: number): number
	local existing = ctx.upvalMap[localId]
	if existing ~= nil then
		return existing
	end
	local b = ctx.bindings[localId]
	local uid = #ctx.upvals
	if uid >= kMaxUpvalueCount then
		raiseCompileError(
			ctx,
			b.start,
			b.finish,
			string.format(
				"Out of upvalue registers when trying to allocate %s: exceeded limit %d",
				ctx.symbols[b.name] :: string,
				kMaxUpvalueCount
			)
		)
	end
	if ctx.vars.written[localId] then
		ctx.localCaptured[localId] = true
		if ctx.localAllocated[localId] then
			ctx.regCaptured[ctx.localReg[localId]] = true
		end
	end
	ctx.upvals[uid + 1] = localId
	ctx.upvalMap[localId] = uid
	return uid
end

@native
local function atTopLevel(ctx: CompilerCtx): boolean
	if ctx.currentFunctionId == 0 then
		return false
	end
	local fn = ctx.currentFunctionNode or ctx.nodes[ctx.currentFunctionId]
	return fn ~= nil and fn.functionDepth == 0 and ctx.blockDepth == 0 and ctx.loopDepth == 0
end

@native
local function checkExportedLocal(ctx: CompilerCtx, localId: number, start: number, finish: number)
	local b = ctx.bindings[localId]
	if b and b.isExported and not atTopLevel(ctx) then
		raiseCompileError(ctx, start, finish, "'export' may only be applied to top-level statements")
	end
end

@native
local function allocReg(ctx: CompilerCtx, nodeId: number, count: number): number
	local top = ctx.regTop
	if top + count > kMaxRegisterCount then
		local n = if nodeId == ctx.currentFunctionId
			then (ctx.currentFunctionNode or ctx.nodes[nodeId])
			else ctx.nodes[nodeId]
		raiseCompileError(
			ctx,
			if n then n.start else 0,
			if n then n.finish else 0,
			string.format(
				"Out of registers when trying to allocate %d registers: exceeded limit %d",
				count,
				kMaxRegisterCount
			)
		)
	end
	ctx.regTop = top + count
	if ctx.regTop > ctx.stackSize then
		ctx.stackSize = ctx.regTop
	end
	return top
end

@native
local function pushLocal(ctx: CompilerCtx, localId: number, reg: number, allocpc: number)
	local localStack = ctx.localStack
	local n = #localStack
	if ctx.activeLocals >= kMaxLocalCount then
		local b = ctx.bindings[localId]
		raiseCompileError(
			ctx,
			b.start,
			b.finish,
			string.format(
				"Out of local registers when trying to allocate %s: exceeded limit %d",
				ctx.symbols[b.name] :: string,
				kMaxLocalCount
			)
		)
	end
	local stackIdx = n + 1
	localStack[stackIdx] = localId
	ctx.activeLocals += 1
	assert(not ctx.localAllocated[localId], "local already allocated")
	ctx.localReg[localId] = reg
	ctx.localAllocated[localId] = true
	if ctx.recordDebug then
		local debugpc = ctx.bytecode.insnCount
		ctx.localDebugPc[localId] = debugpc
		ctx.localAllocPc[localId] = if allocpc == kDefaultAllocPc then debugpc else allocpc
	end
	local captured = ctx.localCaptured[localId] == true
	ctx.regCaptured[reg] = captured
	ctx.localUses[reg] = (ctx.localUses[reg] or 0) + 1

	local blockOwner = ctx.curBlockOwner
	if
		blockOwner ~= 0
		and ctx.optimizationLevel ~= 0
		and not captured
		and ctx.vars.owner[localId] == blockOwner
		and not ctx.vars.nonLexicalUse[localId]
	then
		local lastUsedId = ctx.vars.lastUsed[localId]
		local lastFinish = if lastUsedId == 0 then -1 else ctx.finishes[lastUsedId]
		local lc = ctx.blockLiveCount + 1
		ctx.blockLiveCount = lc
		ctx.blockLiveLocalIds[lc] = localId
		ctx.blockLiveStackIdx[lc] = stackIdx
		ctx.blockLiveFinishes[lc] = lastFinish
		if lastFinish < ctx.curBlockMinFinish then
			ctx.curBlockMinFinish = lastFinish
		end
	end
end

@native
local function recordLocalDebugInfo(
	ctx: CompilerCtx,
	localId: number,
	reg: number,
	debugpc: number,
	allocpc: number,
	isArgument: boolean,
	endpc: number
)
	if ctx.debugLevel >= 2 then
		local b = ctx.bindings[localId]
		ctx.bytecode:pushDebugLocal(ctx.symbols[b.name], reg, debugpc, endpc)
	end
	if ctx.typeInfoLevel >= 1 and not isArgument then
		local ty = ctx.localTypes[localId] or Types.LBC_TYPE_ANY
		ctx.bytecode:pushLocalTypeInfo(ty, reg, allocpc, endpc)
	end
end

@native
local function releaseLocal(ctx: CompilerCtx, localId: number, reg: number): boolean
	ctx.localAllocated[localId] = false
	assert(ctx.activeLocals ~= 0, "expected active locals")
	ctx.activeLocals -= 1
	ctx.regCaptured[reg] = false
	local uses = (ctx.localUses[reg] or 1) - 1
	ctx.localUses[reg] = uses
	return uses == 0
end

@native
local function insertFreeReg(
	ctx: CompilerCtx,
	reg: number,
	localId: number,
	debugpc: number,
	allocpc: number,
	isArg: boolean
)
	local fc = ctx.freeCount
	local freeRegs = ctx.freeRegs
	local freeAstLocals = ctx.freeAstLocals
	local freeDebugPcs = ctx.freeDebugPcs
	local freeAllocPcs = ctx.freeAllocPcs
	local freeIsArgs = ctx.freeIsArgs
	local idx = fc
	while idx >= 1 and freeRegs[idx] >= reg do
		idx -= 1
	end
	local insertPos = idx + 1
	for j = fc, insertPos, -1 do
		freeRegs[j + 1] = freeRegs[j]
		freeAstLocals[j + 1] = freeAstLocals[j]
		freeDebugPcs[j + 1] = freeDebugPcs[j]
		freeAllocPcs[j + 1] = freeAllocPcs[j]
		freeIsArgs[j + 1] = freeIsArgs[j]
	end
	freeRegs[insertPos] = reg
	freeAstLocals[insertPos] = localId
	freeDebugPcs[insertPos] = debugpc
	freeAllocPcs[insertPos] = allocpc
	freeIsArgs[insertPos] = isArg
	ctx.freeCount = fc + 1
end

@native
local function tryReuseLocalReg(ctx: CompilerCtx, localId: number): (boolean, number)
	local fc = ctx.freeCount
	if fc == 0 or ctx.bindings[localId].isExported then
		return false, 0
	end
	if ctx.vars.owner[localId] == nil or ctx.localCaptured[localId] then
		return false, 0
	end
	local reg = ctx.freeRegs[fc]
	ctx.freeCount = fc - 1
	if ctx.debugLevel >= 2 or ctx.typeInfoLevel >= 1 then
		recordLocalDebugInfo(
			ctx,
			ctx.freeAstLocals[fc],
			reg,
			ctx.freeDebugPcs[fc],
			ctx.freeAllocPcs[fc],
			ctx.freeIsArgs[fc],
			ctx.bytecode.insnCount
		)
	end
	return true, reg
end

@native
local function areLocalsCaptured(ctx: CompilerCtx, start: number): boolean
	local localStack = ctx.localStack
	local n = #localStack
	if n <= start then
		return false
	end
	local localCaptured = ctx.localCaptured
	for i = start + 1, n do
		if localCaptured[localStack[i]] then
			return true
		end
	end
	return false
end

@native
local function closeLocals(ctx: CompilerCtx, start: number)
	local localStack = ctx.localStack
	local n = #localStack
	if n <= start then
		return
	end
	local localCaptured = ctx.localCaptured
	local localReg = ctx.localReg
	local captured = false
	local captureReg = 255
	for i = start + 1, n do
		local localId = localStack[i]
		if localCaptured[localId] then
			captured = true
			local r = localReg[localId]
			if r < captureReg then
				captureReg = r
			end
		end
	end
	if captured then
		ctx.bytecode:emitABC(Opcodes.LOP_CLOSEUPVALS, captureReg, 0, 0)
	end
end

@native
local function popLocals(ctx: CompilerCtx, start: number)
	local localStack = ctx.localStack
	local n = #localStack
	if n <= start then
		return
	end
	local recordDebug = ctx.recordDebug
	local debugpc = if recordDebug then ctx.bytecode.insnCount else 0
	local localReg = ctx.localReg
	local localAllocated = ctx.localAllocated
	local localReused = ctx.localReused
	local localDebugPc = ctx.localDebugPc
	local localAllocPc = ctx.localAllocPc
	local argCount = ctx.argCount
	local freeRegs = ctx.freeRegs
	local freeAstLocals = ctx.freeAstLocals
	local freeDebugPcs = ctx.freeDebugPcs
	local freeAllocPcs = ctx.freeAllocPcs
	local freeIsArgs = ctx.freeIsArgs

	for i = start + 1, n do
		local localId = localStack[i]
		if localReused[localId] then
			local reg = localReg[localId]
			local fc = ctx.freeCount
			for idx = 1, fc do
				if freeRegs[idx] == reg then
					if recordDebug then
						recordLocalDebugInfo(
							ctx,
							freeAstLocals[idx],
							reg,
							freeDebugPcs[idx],
							freeAllocPcs[idx],
							freeIsArgs[idx],
							debugpc
						)
					end
					for j = idx, fc - 1 do
						freeRegs[j] = freeRegs[j + 1]
						freeAstLocals[j] = freeAstLocals[j + 1]
						freeDebugPcs[j] = freeDebugPcs[j + 1]
						freeAllocPcs[j] = freeAllocPcs[j + 1]
						freeIsArgs[j] = freeIsArgs[j + 1]
					end
					ctx.freeCount = fc - 1
					break
				end
			end
			localAllocated[localId] = false
			localReused[localId] = false
		elseif localAllocated[localId] then
			local reg = localReg[localId]
			releaseLocal(ctx, localId, reg)
			if recordDebug then
				recordLocalDebugInfo(
					ctx,
					localId,
					reg,
					localDebugPc[localId],
					localAllocPc[localId],
					(i - 1) < argCount,
					debugpc
				)
			end
		end
	end
	for i = n, start + 1, -1 do
		localStack[i] = nil
	end
end

@native
local function enterBlockLive(ctx: CompilerCtx, blockId: number): (number, number, number, number)
	local prevOwner = ctx.curBlockOwner
	local prevBase = ctx.curBlockBase
	local prevLiveCount = ctx.blockLiveCount
	local prevMinFinish = ctx.curBlockMinFinish
	ctx.curBlockOwner = blockId
	ctx.curBlockBase = prevLiveCount
	ctx.curBlockMinFinish = math.huge
	return prevOwner, prevBase, prevLiveCount, prevMinFinish
end

@native
local function leaveBlockLive(
	ctx: CompilerCtx,
	prevOwner: number,
	prevBase: number,
	prevLiveCount: number,
	prevMinFinish: number
)
	ctx.blockLiveCount = prevLiveCount
	ctx.curBlockOwner = prevOwner
	ctx.curBlockBase = prevBase
	ctx.curBlockMinFinish = prevMinFinish
end

@native
local function popStatLocals(ctx: CompilerCtx, beforeStatId: number)
	if ctx.optimizationLevel == 0 then
		return
	end
	local base = ctx.curBlockBase
	local liveCount = ctx.blockLiveCount
	if liveCount <= base then
		return
	end
	local statStartOffset = ctx.starts[beforeStatId]
	if statStartOffset <= ctx.curBlockMinFinish then
		return
	end

	local liveLocalIds = ctx.blockLiveLocalIds
	local liveStackIdx = ctx.blockLiveStackIdx
	local liveFinishes = ctx.blockLiveFinishes
	local localAllocated = ctx.localAllocated
	local localReused = ctx.localReused
	local localCaptured = ctx.localCaptured
	local localReg = ctx.localReg
	local localDebugPc = ctx.localDebugPc
	local localAllocPc = ctx.localAllocPc
	local argCount = ctx.argCount
	local recordDebug = ctx.recordDebug

	local writeIdx = base
	local newMinFinish = math.huge
	for i = base + 1, liveCount do
		local localId = liveLocalIds[i]
		if not localAllocated[localId] or localReused[localId] or localCaptured[localId] then
			continue
		end
		local lastFinish = liveFinishes[i]
		if statStartOffset > lastFinish then
			local reg = localReg[localId]
			local isArg = (liveStackIdx[i] - 1) < argCount
			if releaseLocal(ctx, localId, reg) then
				insertFreeReg(ctx, reg, localId, localDebugPc[localId], localAllocPc[localId], isArg)
				localReused[localId] = true
			elseif recordDebug then
				recordLocalDebugInfo(
					ctx,
					localId,
					reg,
					localDebugPc[localId],
					localAllocPc[localId],
					isArg,
					ctx.bytecode.insnCount
				)
			end
		else
			writeIdx += 1
			if writeIdx ~= i then
				liveLocalIds[writeIdx] = localId
				liveStackIdx[writeIdx] = liveStackIdx[i]
				liveFinishes[writeIdx] = lastFinish
			end
			if lastFinish < newMinFinish then
				newMinFinish = lastFinish
			end
		end
	end
	ctx.blockLiveCount = writeIdx
	ctx.curBlockMinFinish = newMinFinish
end

@native
local function setDebugLineOffset(ctx: CompilerCtx, offset: number)
	if ctx.debugLevel >= 1 then
		if offset >= ctx.lastLineStart and offset < ctx.lastLineEnd then
			ctx.bytecode.debugLine = ctx.lastLineNum
			return
		end
		ctx.bytecode.debugLine = getLine0(ctx, offset) + 1
	end
end

@native
local function setDebugLine(ctx: CompilerCtx, nodeId: number)
	if ctx.debugLevel >= 1 and nodeId ~= 0 then
		local offset = ctx.starts[nodeId]
		if offset ~= nil then
			if offset >= ctx.lastLineStart and offset < ctx.lastLineEnd then
				ctx.bytecode.debugLine = ctx.lastLineNum
				return
			end
			ctx.bytecode.debugLine = getLine0(ctx, offset) + 1
		end
	end
end

@native
local function setDebugLineEnd(ctx: CompilerCtx, nodeId: number)
	if ctx.debugLevel >= 1 and nodeId ~= 0 then
		local finish = ctx.finishes[nodeId]
		if finish ~= nil then
			setDebugLineOffset(ctx, finish)
		end
	end
end

@native
local function needsCoverage(ctx: CompilerCtx, nodeId: number): boolean
	local k = ctx.kinds[nodeId]
	return k ~= K.AstStatBlock and k ~= K.AstStatTypeAlias
end

@native
local function getExprLocal(ctx: CompilerCtx, nodeId: number): number
	local k = ctx.kinds[nodeId]
	if k == K.AstExprLocal then
		return nodeId
	elseif k ~= K.AstExprGroup and k ~= K.AstExprTypeAssertion then
		return 0
	end
	return CompilerFolding.unwrapExprOfType(ctx.arena, nodeId, K.AstExprLocal)
end

@native
local function getExprLocalReg(ctx: CompilerCtx, nodeId: number): number
	local k = ctx.kinds[nodeId]
	if k == K.AstExprLocal then
		local localId = ctx.nodes[nodeId]["local"]
		return if ctx.localAllocated[localId] then ctx.localReg[localId] else -1
	elseif k ~= K.AstExprGroup and k ~= K.AstExprTypeAssertion then
		return -1
	end
	local exprId = CompilerFolding.unwrapExprOfType(ctx.arena, nodeId, K.AstExprLocal)
	if exprId ~= 0 then
		local localId = ctx.nodes[exprId]["local"]
		return if ctx.localAllocated[localId] then ctx.localReg[localId] else -1
	end
	return -1
end

@native
local function hintTemporaryRegType(
	ctx: CompilerCtx,
	exprId: number,
	reg: number,
	expectedType: number,
	instLength: number
)
	local ty = ctx.exprTypes[exprId]
	if ty ~= nil and ty ~= expectedType then
		local pc = ctx.bytecode.insnCount
		ctx.bytecode:pushLocalTypeInfo(ty, reg, pc - instLength, pc)
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
	if ty ~= nil and ty ~= expectedType and getExprLocal(ctx, exprId) == 0 then
		local pc = ctx.bytecode.insnCount
		ctx.bytecode:pushLocalTypeInfo(ty, reg, pc - instLength, pc)
	end
end

@native
local function patchJump(ctx: CompilerCtx, nodeId: number, label: number, target: number)
	if not ctx.bytecode:patchJumpD(label, target) then
		local n = ctx.nodes[nodeId]
		raiseCompileError(ctx, n.start, n.finish, "Exceeded jump distance limit; simplify the code to compile")
	end
end

@native
local function patchSkipCOrThrow(ctx: CompilerCtx, errNode: any, jumpLabel: number, targetLabel: number)
	if not ctx.bytecode:patchSkipC(jumpLabel, targetLabel) then
		raiseCompileError(
			ctx,
			errNode.start,
			errNode.finish,
			"Exceeded jump distance limit; simplify the code to compile"
		)
	end
end

@native
local function patchJumps(ctx: CompilerCtx, nodeId: number, labels: { number }, target: number)
	for i = 1, #labels do
		patchJump(ctx, nodeId, labels[i], target)
	end
end

@native
local function patchLoopJumps(ctx: CompilerCtx, nodeId: number, oldJumps: number, endLabel: number, contLabel: number)
	local loopJumpTypes = ctx.loopJumpTypes
	local loopJumpLabels = ctx.loopJumpLabels
	local ljCount = ctx.loopJumpCount
	for i = oldJumps + 1, ljCount do
		if loopJumpTypes[i] == LoopJumpType.Break then
			patchJump(ctx, nodeId, loopJumpLabels[i], endLabel)
		elseif contLabel >= 0 then
			patchJump(ctx, nodeId, loopJumpLabels[i], contLabel)
		end
	end
	ctx.loopJumpCount = oldJumps
end

@native
local function checkConstantNode(ctx: CompilerCtx, cid: number, nodeId: number)
	if cid < 0 then
		local n = if nodeId == ctx.currentFunctionId
			then (ctx.currentFunctionNode or ctx.nodes[nodeId])
			else ctx.nodes[nodeId]
		raiseCompileError(
			ctx,
			if n then n.start else 0,
			if n then n.finish else 0,
			"Exceeded constant limit; simplify the code to compile"
		)
	end
end

@native
local function checkConstantBinding(ctx: CompilerCtx, cid: number, localId: number)
	if cid < 0 then
		local b = ctx.bindings[localId]
		raiseCompileError(ctx, b.start, b.finish, "Exceeded constant limit; simplify the code to compile")
	end
end

@native
local function isConstant(ctx: CompilerCtx, nodeId: number): boolean
	local cv = ctx.constants[nodeId]
	return cv ~= nil and cv.type ~= CompilerBuiltins.ConstantType.Unknown
end

@native
local function isConstantTrue(ctx: CompilerCtx, nodeId: number): boolean
	return CompilerFolding.isConstantTrue(ctx.constants, nodeId)
end

@native
local function isConstantFalse(ctx: CompilerCtx, nodeId: number): boolean
	return CompilerFolding.isConstantFalse(ctx.constants, nodeId)
end

@native
local function isConstantVector(ctx: CompilerCtx, nodeId: number): boolean
	local cv = ctx.constants[nodeId]
	return cv ~= nil
		and (cv.type == CompilerBuiltins.ConstantType.Vectorf or cv.type == CompilerBuiltins.ConstantType.Vectord)
end

@native
local function getConstant(ctx: CompilerCtx, nodeId: number): InternalConstant
	local cv = ctx.constants[nodeId]
	if cv then
		return cv
	end
	return CompilerBuiltins.UNKNOWN_CONSTANT
end

@native
local function getConstantNumber(ctx: CompilerCtx, nodeId: number): number
	local c = ctx.constants[nodeId]
	if c and c.type == CompilerBuiltins.ConstantType.Number then
		local cid = ctx.bytecode:addConstantNumber(c.valueNumber :: number)
		checkConstantNode(ctx, cid, nodeId)
		return cid
	end
	return -1
end

@native
local function getConstantIndex(ctx: CompilerCtx, nodeId: number, cv: InternalConstant?): number
	local c = cv or ctx.constants[nodeId]
	if not c or c.type == CompilerBuiltins.ConstantType.Unknown then
		return -1
	end
	local cid = -1
	if c.type == CompilerBuiltins.ConstantType.Nil then
		cid = ctx.bytecode:addConstantNil()
	elseif c.type == CompilerBuiltins.ConstantType.Boolean then
		cid = ctx.bytecode:addConstantBoolean(c.valueBoolean == true)
	elseif c.type == CompilerBuiltins.ConstantType.Number then
		cid = ctx.bytecode:addConstantNumber(c.valueNumber :: number)
	elseif c.type == CompilerBuiltins.ConstantType.Vectorf then
		local vf = c.valueVectorf :: { number }
		cid = ctx.bytecode:addConstantVectorf(vf[1], vf[2], vf[3], vf[4] or 0)
	elseif c.type == CompilerBuiltins.ConstantType.Vectord then
		local vd = c.valueVectord :: { number }
		cid = ctx.bytecode:addConstantVectord(vd[1], vd[2], vd[3], vd[4] or 0)
	elseif c.type == CompilerBuiltins.ConstantType.String then
		cid = ctx.bytecode:addConstantString(c.valueString or "")
	else
		error("Unexpected constant type")
	end
	checkConstantNode(ctx, cid, nodeId)
	return cid
end

@native
local function emitLoadK(ctx: CompilerCtx, target: number, cid: number)
	if cid < 32768 then
		ctx.bytecode:emitAD(Opcodes.LOP_LOADK, target, cid)
	else
		ctx.bytecode:emitAD(Opcodes.LOP_LOADKX, target, 0)
		ctx.bytecode:emitAux(cid)
	end
end

local function ensureExportTable(ctx: CompilerCtx, nodeId: number)
	ctx.exports.hasExports = true
	if ctx.localAllocated[ctx.exportTableLocalId] then
		return
	end
	local tableReg = allocReg(ctx, nodeId, 1)
	if
		ctx.flags.LuauOptimizeExportTable
		and ctx.exports.exportedTableCid ~= -1
		and ctx.exports.exportedTableCid < 32768
	then
		ctx.bytecode:emitAD(Opcodes.LOP_DUPTABLE, tableReg, ctx.exports.exportedTableCid)
	else
		ctx.bytecode:emitABC(Opcodes.LOP_NEWTABLE, tableReg, encodeHashSize(0), 0)
		ctx.bytecode:emitAux(0)
	end
	pushLocal(ctx, ctx.exportTableLocalId, tableReg, kDefaultAllocPc)
end

local function getExportTableReg(ctx: CompilerCtx, nodeId: number): number
	local reg = getLocalReg(ctx, ctx.exportTableLocalId)
	if reg >= 0 then
		return reg
	end
	local upval = getUpval(ctx, ctx.exportTableLocalId)
	local r = allocReg(ctx, nodeId, 1)
	ctx.bytecode:emitABC(Opcodes.LOP_GETUPVAL, r, upval, 0)
	return r
end

local function buildExportTableShape(ctx: CompilerCtx)
	if #ctx.exports.exportedVariables >= 32 then
		return
	end
	local scratchShape = ctx.scratchTableShape
	local keys = scratchShape.keys
	local shapeConstants = scratchShape.constants
	local length = 0
	local hasConstants = false
	local vars = ctx.vars
	local varOwner = vars.owner
	local varConstant = vars.constant
	local varWritten = vars.written
	local varInit = vars.init
	for i = 1, #ctx.exports.exportedVariables do
		local exportedLocalId = ctx.exports.exportedVariables[i]
		if varOwner[exportedLocalId] == nil then
			local b = ctx.bindings[exportedLocalId]
			raiseCompileError(ctx, b.start, b.finish, "Local does not have corresponding variable")
		end
		local keyCid = ctx.bytecode:addConstantString(ctx.symbols[ctx.bindings[exportedLocalId].name])
		if keyCid < 0 then
			return
		end
		length += 1
		keys[length] = keyCid
		shapeConstants[length] = -1
		if varInit[exportedLocalId] ~= 0 and varConstant[exportedLocalId] and not varWritten[exportedLocalId] then
			local valueCid = getConstantIndex(ctx, varInit[exportedLocalId])
			if valueCid < 0 then
				return
			end
			shapeConstants[length] = valueCid
			hasConstants = true
		end
	end
	if length > 0 then
		scratchShape.length = length
		scratchShape.hasConstants = hasConstants
		ctx.exports.exportedTableCid = ctx.bytecode:addConstantTable(scratchShape)
	end
end

local function compileExportTable(ctx: CompilerCtx)
	local locNodeId = ctx.currentFunctionId
	local tableReg: number
	if not isExportsEmpty(ctx) then
		ensureExportTable(ctx, ctx.currentFunctionId)
		tableReg = getLocalReg(ctx, ctx.exportTableLocalId)
		if ctx.flags.DebugLuauUserDefinedClasses then
			for classLocalId, classReg in ctx.exports.exportedClasses do
				local classSym = ctx.bindings[classLocalId].name
				local classNameStr = ctx.symbols[classSym]
				local classNameCid = ctx.bytecode:addConstantString(classNameStr)
				checkConstantNode(ctx, classNameCid, locNodeId)
				ctx.bytecode:emitABC(
					Opcodes.LOP_SETTABLEKS,
					classReg,
					tableReg,
					getSymHash(ctx, classSym, classNameStr)
				)
				ctx.bytecode:emitAux(classNameCid)
			end
		end
		if ctx.flags.LuauOptimizeExportTable then
			for funcLocalId in ctx.exports.exportedFunctions do
				local funcSym = ctx.bindings[funcLocalId].name
				local funcNameStr = ctx.symbols[funcSym]
				local cid = ctx.bytecode:addConstantString(funcNameStr)
				checkConstantBinding(ctx, cid, funcLocalId)
				local funcReg = getLocalReg(ctx, funcLocalId)
				ctx.bytecode:emitABC(Opcodes.LOP_SETTABLEKS, funcReg, tableReg, getSymHash(ctx, funcSym, funcNameStr))
				ctx.bytecode:emitAux(cid)
			end
		end
	else
		tableReg = allocReg(ctx, locNodeId, 1)
		ctx.bytecode:emitABC(Opcodes.LOP_NEWTABLE, tableReg, encodeHashSize(0), 0)
		ctx.bytecode:emitAux(0)
	end

	local freezeReg = allocReg(ctx, locNodeId, 2)
	local freezeCid = ctx.bytecode:addConstantString("freeze")
	checkConstantNode(ctx, freezeCid, locNodeId)
	local tableCid = ctx.bytecode:addConstantString("table")
	checkConstantNode(ctx, tableCid, locNodeId)

	local getGlobalFallback = true
	if tableCid < 1024 and freezeCid < 1024 then
		local iid = BytecodeBuilder.getImportId(tableCid, freezeCid)
		local cid = ctx.bytecode:addImport(iid)
		if cid >= 0 and cid < 32768 then
			ctx.bytecode:emitAD(Opcodes.LOP_GETIMPORT, freezeReg, cid)
			ctx.bytecode:emitAux(iid)
			getGlobalFallback = false
		end
	end

	if getGlobalFallback then
		ctx.bytecode:emitABC(Opcodes.LOP_GETGLOBAL, freezeReg, 0, TABLE_HASH)
		ctx.bytecode:emitAux(tableCid)
		ctx.bytecode:emitABC(Opcodes.LOP_GETTABLEKS, freezeReg, freezeReg, FREEZE_HASH)
		ctx.bytecode:emitAux(freezeCid)
	end

	ctx.bytecode:emitABC(Opcodes.LOP_MOVE, freezeReg + 1, tableReg, 0)
	ctx.bytecode:emitABC(Opcodes.LOP_CALL, freezeReg, 2, 2)

	closeLocals(ctx, 0)
	ctx.bytecode:emitABC(Opcodes.LOP_RETURN, freezeReg, 2, 0)
end

local compileStat: (CompilerCtx, number) -> ()

@native
local function isStatBreak(ctx: CompilerCtx, nodeId: number): boolean
	local k = ctx.kinds[nodeId]
	if k == K.AstStatBlock then
		local n = ctx.nodes[nodeId]
		if n.body ~= 0 then
			return ctx.listCounts[n.body] == 1 and ctx.kinds[ctx.listValues[ctx.listFirsts[n.body]]] == K.AstStatBreak
		end
		return false
	end
	return k == K.AstStatBreak
end

@native
local function extractStatContinue(ctx: CompilerCtx, blockId: number): number
	if ctx.kinds[blockId] == K.AstStatBlock then
		local block = ctx.nodes[blockId]
		if block.body ~= 0 and ctx.listCounts[block.body] == 1 then
			local stId = ctx.listValues[ctx.listFirsts[block.body]]
			if ctx.kinds[stId] == K.AstStatContinue then
				return stId
			end
		end
	end
	return 0
end

@native
local function compileStatIfLocal(ctx: CompilerCtx, statId: number)
	local stat = ctx.nodes[statId]
	assert(stat.conditionLocal ~= 0, "expected conditionLocal")
	local termCache = if #ctx.inlineFrames == 0 and ctx.trialDepth == 0 then ctx.alwaysTermCache else nil
	local thenTerminates = CompilerFolding.alwaysTerminates(ctx.arena, ctx.constants, stat.thenbody, termCache)
	local skipElse = isConstantTrue(ctx, stat.condition)
	local oldLocals = #ctx.localStack
	local elseJump = 0

	do
		local oldTop = ctx.regTop
		local reg = allocReg(ctx, statId, 1)
		local allocpc = ctx.bytecode.insnCount

		compileExprTemp(ctx, stat.condition, reg)
		pushLocal(ctx, stat.conditionLocal, reg, allocpc)

		if not skipElse then
			elseJump = ctx.bytecode:emitLabel()
			ctx.bytecode:emitAD(Opcodes.LOP_JUMPIFNOT, reg, 0)
		end

		compileStat(ctx, stat.thenbody)

		if not thenTerminates then
			closeLocals(ctx, oldLocals)
		end
		popLocals(ctx, oldLocals)
		ctx.regTop = oldTop
	end

	if skipElse then
		return
	end

	if stat.elsebody ~= 0 and not thenTerminates then
		local thenLabel = ctx.bytecode:emitLabel()
		ctx.bytecode:emitAD(Opcodes.LOP_JUMP, 0, 0)

		local elseLabel = ctx.bytecode:emitLabel()
		compileStat(ctx, stat.elsebody)
		local endLabel = ctx.bytecode:emitLabel()

		patchJump(ctx, statId, elseJump, elseLabel)
		patchJump(ctx, statId, thenLabel, endLabel)
	elseif stat.elsebody ~= 0 then
		local elseLabel = ctx.bytecode:emitLabel()
		compileStat(ctx, stat.elsebody)
		patchJump(ctx, statId, elseJump, elseLabel)
	else
		local endLabel = ctx.bytecode:emitLabel()
		patchJump(ctx, statId, elseJump, endLabel)
	end
end

@native
local function compileStatIf(ctx: CompilerCtx, statId: number)
	local stat = ctx.nodes[statId]
	if isConstantFalse(ctx, stat.condition) then
		if stat.elsebody ~= 0 then
			compileStat(ctx, stat.elsebody)
		end
		return
	end

	if ctx.kinds[stat.condition] == K.AstExprBinary then
		local condNode = ctx.nodes[stat.condition]
		if condNode.op == "And" and isConstantFalse(ctx, condNode.right) then
			compileExprSide(ctx, condNode.left)
			if stat.elsebody ~= 0 then
				compileStat(ctx, stat.elsebody)
			end
			return
		end
	end

	if ctx.flagExpIfLocal and stat.conditionLocal and stat.conditionLocal ~= 0 then
		compileStatIfLocal(ctx, statId)
		return
	end

	if
		stat.elsebody == 0
		and ctx.loopDepth > 0
		and isStatBreak(ctx, stat.thenbody)
		and not areLocalsCaptured(ctx, ctx.loopLocalOffsets[ctx.loopDepth])
	then
		local continueJump = acquireJumpList(ctx)
		compileConditionValue(ctx, stat.condition, nil, continueJump, true)
		local loopJumpTypes = ctx.loopJumpTypes
		local loopJumpLabels = ctx.loopJumpLabels
		local ljCount = ctx.loopJumpCount
		for i = 1, #continueJump do
			ljCount += 1
			loopJumpTypes[ljCount] = LoopJumpType.Break
			loopJumpLabels[ljCount] = continueJump[i]
		end
		ctx.loopJumpCount = ljCount
		releaseJumpList(ctx, continueJump)
		return
	end

	local contId = if stat.elsebody == 0 and ctx.loopDepth > 0 then extractStatContinue(ctx, stat.thenbody) else 0
	if contId ~= 0 and not areLocalsCaptured(ctx, ctx.loopLocalOffsetsContinue[ctx.loopDepth]) then
		local ld = ctx.loopDepth
		if ctx.loopContinueUsed[ld] == 0 then
			ctx.loopContinueUsed[ld] = contId
		end
		local continueJump = acquireJumpList(ctx)
		compileConditionValue(ctx, stat.condition, nil, continueJump, true)
		local loopJumpTypes = ctx.loopJumpTypes
		local loopJumpLabels = ctx.loopJumpLabels
		local ljCount = ctx.loopJumpCount
		for i = 1, #continueJump do
			ljCount += 1
			loopJumpTypes[ljCount] = LoopJumpType.Continue
			loopJumpLabels[ljCount] = continueJump[i]
		end
		ctx.loopJumpCount = ljCount
		releaseJumpList(ctx, continueJump)
		return
	end

	local elseJump = acquireJumpList(ctx)
	compileConditionValue(ctx, stat.condition, nil, elseJump, false)

	compileStat(ctx, stat.thenbody)

	local termCache = if #ctx.inlineFrames == 0 and ctx.trialDepth == 0 then ctx.alwaysTermCache else nil
	if stat.elsebody ~= 0 and #elseJump > 0 then
		if CompilerFolding.alwaysTerminates(ctx.arena, ctx.constants, stat.thenbody, termCache) then
			local elseLabel = ctx.bytecode:emitLabel()
			compileStat(ctx, stat.elsebody)
			patchJumps(ctx, statId, elseJump, elseLabel)
		else
			local thenLabel = ctx.bytecode:emitLabel()
			ctx.bytecode:emitAD(Opcodes.LOP_JUMP, 0, 0)
			local elseLabel = ctx.bytecode:emitLabel()
			compileStat(ctx, stat.elsebody)
			local endLabel = ctx.bytecode:emitLabel()
			patchJumps(ctx, statId, elseJump, elseLabel)
			patchJump(ctx, statId, thenLabel, endLabel)
		end
	else
		local endLabel = ctx.bytecode:emitLabel()
		patchJumps(ctx, statId, elseJump, endLabel)
	end
	releaseJumpList(ctx, elseJump)
end

@native
local function compileStatWhileLocal(ctx: CompilerCtx, statId: number)
	local stat = ctx.nodes[statId]
	assert(stat.conditionLocal ~= 0, "expected conditionLocal")
	if isConstantFalse(ctx, stat.condition) then
		return
	end

	local oldTop = ctx.regTop
	local oldLocals = #ctx.localStack
	local oldJumps = ctx.loopJumpCount
	local ld = ctx.loopDepth + 1
	ctx.loopDepth = ld
	ctx.loopLocalOffsets[ld] = oldLocals
	ctx.loopLocalOffsetsContinue[ld] = oldLocals
	ctx.loopContinueUsed[ld] = 0
	ctx.hasLoops = true

	local reg = allocReg(ctx, statId, 1)
	local allocpc = ctx.bytecode.insnCount

	local loopLabel = ctx.bytecode:emitLabel()

	compileExprTemp(ctx, stat.condition, reg)
	pushLocal(ctx, stat.conditionLocal, reg, allocpc)

	local exitJump = ctx.bytecode:emitLabel()
	ctx.bytecode:emitAD(Opcodes.LOP_JUMPIFNOT, reg, 0)

	compileStat(ctx, stat.body)

	closeLocals(ctx, oldLocals)
	popLocals(ctx, oldLocals)

	local contLabel = ctx.bytecode:emitLabel()
	local backLabel = ctx.bytecode:emitLabel()
	setDebugLine(ctx, stat.condition)
	ctx.bytecode:emitAD(Opcodes.LOP_JUMPBACK, 0, 0)

	local endLabel = ctx.bytecode:emitLabel()
	patchJump(ctx, statId, backLabel, loopLabel)
	patchJump(ctx, statId, exitJump, endLabel)
	patchLoopJumps(ctx, statId, oldJumps, endLabel, contLabel)
	ctx.loopDepth = ld - 1
	ctx.regTop = oldTop
end

@native
local function compileStatWhile(ctx: CompilerCtx, statId: number)
	local stat = ctx.nodes[statId]
	if ctx.flagExpWhileLocal and stat.conditionLocal and stat.conditionLocal ~= 0 then
		compileStatWhileLocal(ctx, statId)
		return
	end
	if isConstantFalse(ctx, stat.condition) then
		return
	end

	local oldLocals = #ctx.localStack
	local oldJumps = ctx.loopJumpCount
	local ld = ctx.loopDepth + 1
	ctx.loopDepth = ld
	ctx.loopLocalOffsets[ld] = oldLocals
	ctx.loopLocalOffsetsContinue[ld] = oldLocals
	ctx.loopContinueUsed[ld] = 0
	ctx.hasLoops = true

	local loopLabel = ctx.bytecode:emitLabel()
	local elseJump = acquireJumpList(ctx)
	compileConditionValue(ctx, stat.condition, nil, elseJump, false)

	compileStat(ctx, stat.body)

	local contLabel = ctx.bytecode:emitLabel()
	local backLabel = ctx.bytecode:emitLabel()
	setDebugLine(ctx, stat.condition)
	ctx.bytecode:emitAD(Opcodes.LOP_JUMPBACK, 0, 0)

	local endLabel = ctx.bytecode:emitLabel()
	patchJump(ctx, statId, backLabel, loopLabel)
	patchJumps(ctx, statId, elseJump, endLabel)
	releaseJumpList(ctx, elseJump)
	patchLoopJumps(ctx, statId, oldJumps, endLabel, contLabel)
	ctx.loopDepth = ld - 1
end

local validateContinueUntil: (CompilerCtx, number, number, number, number) -> ()
do
	local function onContinueUndefLocal(
		_ctx: CompilerCtx,
		_nodeId: number,
		n: any,
		definedLocals: { [number]: boolean },
		out: { number }
	): boolean
		if not n.upvalue and definedLocals[n["local"]] then
			out[1] = n["local"]
			return true
		end
		return false
	end

	local function onContinueUndefFunc(
		ctx: CompilerCtx,
		nodeId: number,
		n: any,
		definedLocals: { [number]: boolean },
		out: { number }
	): boolean
		local f = ctx.functions[nodeId]
		if f then
			for _, uv in f.upvals do
				if uv == kInvalidUpvalue then
					continue
				end
				if ctx.bindings[uv].functionDepth == n.functionDepth - 1 and definedLocals[uv] then
					out[1] = uv
					return true
				end
			end
		end
		return false
	end

	local function findContinueUndefLocal(
		ctx: CompilerCtx,
		exprId: number,
		definedLocals: { [number]: boolean }
	): number
		local out = { 0 }
		(cachedVisitAstLocalNode or getCompilerInline().visitAstLocalNode)(
			ctx,
			exprId,
			onContinueUndefLocal,
			definedLocals,
			out,
			false,
			onContinueUndefFunc
		)
		return out[1]
	end

	function validateContinueUntil(
		ctx: CompilerCtx,
		contId: number,
		conditionId: number,
		bodyId: number,
		startIdx: number
	)
		local bodyNode = ctx.nodes[bodyId]
		local bodyFirst = if bodyNode.body ~= 0 then ctx.listFirsts[bodyNode.body] else 0
		local bodyCount = if bodyNode.body ~= 0 then ctx.listCounts[bodyNode.body] else 0
		local definedLocals: { [number]: boolean } = {}

		local kinds = ctx.kinds
		for i = startIdx, bodyCount - 1 do
			local stId = ctx.listValues[bodyFirst + i]
			local stk = kinds[stId]
			if stk == K.AstStatLocal then
				local st = ctx.nodes[stId]
				if st.vars ~= 0 then
					local vlFirst = ctx.listFirsts[st.vars]
					local vlCount = ctx.listCounts[st.vars]
					for j = 0, vlCount - 1 do
						definedLocals[ctx.listValues[vlFirst + j]] = true
					end
				end
			elseif stk == K.AstStatLocalFunction then
				definedLocals[ctx.nodes[stId].name] = true
			elseif stk == K.AstStatClass then
				local st = ctx.nodes[stId]
				if st.declModifier ~= "None" then
					definedLocals[st.localName] = true
				end
			end
		end

		local undefLocalId = findContinueUndefLocal(ctx, conditionId, definedLocals)
		if undefLocalId ~= 0 then
			local condNode = ctx.nodes[conditionId]
			local name: string = ctx.symbols[ctx.bindings[undefLocalId].name]
			raiseCompileError(
				ctx,
				condNode.start,
				condNode.finish,
				string.format(
					"Local %s used in the repeat..until condition is undefined because continue statement on line %d jumps over it",
					name,
					getLine0(ctx, ctx.nodes[contId].start) + 1
				)
			)
		end
	end
end

@native
local function compileStatRepeat(ctx: CompilerCtx, statId: number)
	local oldJumps = ctx.loopJumpCount
	local oldLocals = #ctx.localStack
	local ld = ctx.loopDepth + 1
	ctx.loopDepth = ld
	ctx.loopLocalOffsets[ld] = oldLocals
	ctx.loopLocalOffsetsContinue[ld] = oldLocals
	ctx.loopContinueUsed[ld] = 0
	ctx.hasLoops = true

	local loopLabel = ctx.bytecode:emitLabel()
	local stat = ctx.nodes[statId]
	local body = ctx.nodes[stat.body]
	assert(ctx.kinds[stat.body] == K.AstStatBlock, "repeat body must be AstStatBlock")
	local bodyFirst = if body.body ~= 0 then ctx.listFirsts[body.body] else 0
	local bodyCount = if body.body ~= 0 then ctx.listCounts[body.body] else 0
	local listValues = ctx.listValues

	local oldTop = ctx.regTop
	local continueValidated = false
	local conditionLocals = 0

	local prevOwner, prevBase, prevLiveCount, prevMinFinish = enterBlockLive(ctx, stat.body)
	for i = 0, bodyCount - 1 do
		local bodyStatId = listValues[bodyFirst + i]
		popStatLocals(ctx, bodyStatId)
		compileStat(ctx, bodyStatId)
		if ctx.loopContinueUsed[ld] == 0 then
			ctx.loopLocalOffsetsContinue[ld] = #ctx.localStack
		end
		if ctx.loopContinueUsed[ld] ~= 0 and not continueValidated then
			validateContinueUntil(ctx, ctx.loopContinueUsed[ld], stat.condition, stat.body, i + 1)
			continueValidated = true
			conditionLocals = #ctx.localStack
		end
	end
	leaveBlockLive(ctx, prevOwner, prevBase, prevLiveCount, prevMinFinish)

	if continueValidated then
		setDebugLineEnd(ctx, listValues[bodyFirst + bodyCount - 1])
		closeLocals(ctx, conditionLocals)
		popLocals(ctx, conditionLocals)
	end

	local contLabel = ctx.bytecode:emitLabel()
	local endLabel: number
	setDebugLine(ctx, stat.condition)

	if isConstantTrue(ctx, stat.condition) then
		closeLocals(ctx, oldLocals)
		endLabel = ctx.bytecode:emitLabel()
	else
		local skipJump = acquireJumpList(ctx)
		compileConditionValue(ctx, stat.condition, nil, skipJump, true)
		closeLocals(ctx, oldLocals)

		local backLabel = ctx.bytecode:emitLabel()
		ctx.bytecode:emitAD(Opcodes.LOP_JUMPBACK, 0, 0)

		local skipLabel = ctx.bytecode:emitLabel()
		closeLocals(ctx, oldLocals)

		endLabel = ctx.bytecode:emitLabel()
		patchJump(ctx, statId, backLabel, loopLabel)
		patchJumps(ctx, statId, skipJump, skipLabel)
		releaseJumpList(ctx, skipJump)
	end

	popLocals(ctx, oldLocals)
	patchLoopJumps(ctx, statId, oldJumps, endLabel, contLabel)
	ctx.loopDepth = ld - 1
	ctx.regTop = oldTop
end

@native
local function compileInlineReturn(ctx: CompilerCtx, statId: number)
	setDebugLine(ctx, statId)
	local stat = ctx.nodes[statId]
	local frame = ctx.inlineFrames[#ctx.inlineFrames]
	compileExprListTemp(ctx, stat.list, frame.target, frame.targetCount, false)
	closeLocals(ctx, frame.oldLocals)
	local jumpLabel = ctx.bytecode:emitLabel()
	ctx.bytecode:emitAD(Opcodes.LOP_JUMP, 0, 0)
	local rj = frame.returnJumps
	rj[#rj + 1] = jumpLabel
end

@native
local function compileStatReturn(ctx: CompilerCtx, statId: number)
	local stat = ctx.nodes[statId]
	local listFirst = if stat.list ~= 0 then ctx.listFirsts[stat.list] else 0
	local listCount = if stat.list ~= 0 then ctx.listCounts[stat.list] else 0

	if listCount >= 255 then
		raiseCompileError(ctx, stat.start, stat.finish, "Exceeded return count limit; simplify the code to compile")
	end

	if ctx.flags.LuauExportedTypesParticipateInScc then
		local curFunc = ctx.currentFunctionNode
		if curFunc and curFunc.functionDepth == 0 and #ctx.inlineFrames == 0 then
			ctx.exports.hasModuleReturn = true
		end
	end

	local oldTop = ctx.regTop
	local temp = 0
	local consecutive = false
	local multRet = false
	local listValues = ctx.listValues

	local reg0 = if listCount > 0 then getExprLocalReg(ctx, listValues[listFirst]) else -1
	if reg0 >= 0 then
		temp = reg0
		consecutive = true
		local prefix = 1
		for i = 1, listCount - 1 do
			if getExprLocalReg(ctx, listValues[listFirst + i]) ~= temp + i then
				consecutive = false
				prefix = i
				break
			end
		end
		if not consecutive and temp + prefix == ctx.regTop then
			local tailRegs: { number } = table.create(listCount - prefix, 0)
			local allLocals = true
			for i = prefix, listCount - 1 do
				local r = getExprLocalReg(ctx, listValues[listFirst + i])
				if r == -1 then
					allLocals = false
					break
				end
				tailRegs[i - prefix + 1] = r
			end
			if allLocals then
				local tail = allocReg(ctx, statId, listCount - prefix)
				assert(tail == temp + prefix, "return tail reg mismatch")
				for i = 1, listCount - prefix do
					ctx.bytecode:emitABC(Opcodes.LOP_MOVE, temp + prefix - 1 + i, tailRegs[i], 0)
				end
				consecutive = true
			end
		end
	end

	if not consecutive and listCount == 1 and not isExprMultRet(ctx, listValues[listFirst]) then
		temp = allocReg(ctx, statId, 1)
		temp = compileExprAutoTemp(ctx, listValues[listFirst], temp)
	elseif not consecutive and listCount > 0 then
		temp = allocReg(ctx, statId, listCount)
		for i = 0, listCount - 1 do
			local itemId = listValues[listFirst + i]
			if i + 1 == listCount then
				multRet = compileExprTempMultRet(ctx, itemId, temp + i)
			else
				compileExprTempTop(ctx, itemId, temp + i)
			end
		end
	end

	closeLocals(ctx, 0)
	if multRet then
		ctx.hasMultiRet = true
	end
	ctx.bytecode:emitABC(Opcodes.LOP_RETURN, temp, if multRet then 0 else listCount + 1, 0)
	ctx.regTop = oldTop
end

@native
local function areLocalsRedundant(ctx: CompilerCtx, statId: number): boolean
	local stat = ctx.nodes[statId]
	local varsFirst = if stat.vars ~= 0 then ctx.listFirsts[stat.vars] else 0
	local varsCount = if stat.vars ~= 0 then ctx.listCounts[stat.vars] else 0
	local valsCount = if stat.values ~= 0 then ctx.listCounts[stat.values] else 0

	if valsCount > varsCount then
		return false
	end

	local listValues = ctx.listValues
	local varConstant = ctx.vars.constant
	local checkExports = ctx.flags.LuauExportValueSyntax
		and (not ctx.flags.LuauOptimizeExportTable or ctx.exports.exportedTableCid == -1)

	for i = 0, varsCount - 1 do
		local localId = listValues[varsFirst + i]
		if not varConstant[localId] then
			return false
		end
		if checkExports and ctx.bindings[localId].isExported then
			return false
		end
	end

	return true
end

@native
local function tryCompileStatLocalFast(ctx: CompilerCtx, var0Id: number, val0Id: number): boolean
	local reId = getExprLocal(ctx, val0Id)
	if reId ~= 0 then
		local reLocalId = ctx.nodes[reId]["local"]
		local reg = getExprLocalReg(ctx, reId)
		local varWritten = ctx.vars.written
		if
			reg >= 0
			and not varWritten[var0Id]
			and not varWritten[reLocalId]
			and not ctx.bindings[var0Id].isExported
			and not ctx.bindings[reLocalId].isExported
		then
			pushLocal(ctx, var0Id, reg, kDefaultAllocPc)
			return true
		end
	end

	if #ctx.inlineFrames > 0 and ctx.inlineFrames[#ctx.inlineFrames].resultLocal == var0Id then
		local target = ctx.inlineFrames[#ctx.inlineFrames].target
		compileExprTemp(ctx, val0Id, target)
		pushLocal(ctx, var0Id, target, kDefaultAllocPc)
		return true
	end

	local reused, target = tryReuseLocalReg(ctx, var0Id)
	if reused then
		local allocpc = ctx.bytecode.insnCount
		compileExprTemp(ctx, val0Id, target)
		pushLocal(ctx, var0Id, target, allocpc)
		return true
	end

	return false
end

@native
local function compileStatLocal(ctx: CompilerCtx, statId: number)
	local stat = ctx.nodes[statId]
	if ctx.optimizationLevel >= 1 and areLocalsRedundant(ctx, statId) then
		return
	end

	local varsFirst = if stat.vars ~= 0 then ctx.listFirsts[stat.vars] else 0
	local varsCount = if stat.vars ~= 0 then ctx.listCounts[stat.vars] else 0
	local valsFirst = if stat.values ~= 0 then ctx.listFirsts[stat.values] else 0
	local valsCount = if stat.values ~= 0 then ctx.listCounts[stat.values] else 0
	local listValues = ctx.listValues

	if ctx.optimizationLevel >= 1 and varsCount == 1 and valsCount == 1 then
		local var0Id = listValues[varsFirst]
		local val0Id = listValues[valsFirst]
		if tryCompileStatLocalFast(ctx, var0Id, val0Id) then
			return
		end
	end

	local vars = allocReg(ctx, statId, varsCount)
	local allocpc = ctx.bytecode.insnCount

	compileExprListTemp(ctx, stat.values, vars, varsCount, true)

	local varConstant = ctx.vars.constant
	for i = 0, varsCount - 1 do
		local localId = listValues[varsFirst + i]
		local b = ctx.bindings[localId]
		if
			ctx.flags.LuauExportValueSyntax
			and b.isExported
			and (
				not ctx.flags.LuauOptimizeExportTable
				or not varConstant[localId]
				or ctx.exports.exportedTableCid == -1
			)
		then
			ensureExportTable(ctx, statId)
			local lnameSym = b.name
			local lname = ctx.symbols[lnameSym]
			local cid = ctx.bytecode:addConstantString(lname)
			checkConstantBinding(ctx, cid, localId)
			local tableReg = getExportTableReg(ctx, statId)
			ctx.bytecode:emitABC(Opcodes.LOP_SETTABLEKS, vars + i, tableReg, getSymHash(ctx, lnameSym, lname))
			ctx.bytecode:emitAux(cid)
		else
			pushLocal(ctx, localId, vars + i, allocpc)
		end
	end
end

@native
local function compileStatFor(ctx: CompilerCtx, statId: number)
	local oldTop = ctx.regTop
	local stat = ctx.nodes[statId]

	if
		ctx.optimizationLevel >= 2
		and isConstant(ctx, stat.to)
		and isConstant(ctx, stat.from)
		and (stat.step == 0 or isConstant(ctx, stat.step))
	then
		if
			(cachedTryCompileUnrolledFor or getCompilerInline().tryCompileUnrolledFor)(
				ctx,
				statId,
				ctx.flags.LuauCompileLoopUnrollThreshold,
				ctx.flags.LuauCompileLoopUnrollThresholdMaxBoost
			)
		then
			ctx.regTop = oldTop
			return
		end
	end

	local oldLocals = #ctx.localStack
	local oldJumps = ctx.loopJumpCount
	local ld = ctx.loopDepth + 1
	ctx.loopDepth = ld
	ctx.loopLocalOffsets[ld] = oldLocals
	ctx.loopLocalOffsetsContinue[ld] = oldLocals
	ctx.loopContinueUsed[ld] = 0
	ctx.hasLoops = true

	local regs = allocReg(ctx, statId, 3)
	local varreg = regs + 2
	local varregallocpc = ctx.bytecode.insnCount

	if ctx.vars.written[stat.var] then
		varreg = allocReg(ctx, statId, 1)
	end

	compileExprTemp(ctx, stat.from, regs + 2)
	compileExprTemp(ctx, stat.to, regs + 0)
	if stat.step ~= 0 then
		compileExprTemp(ctx, stat.step, regs + 1)
	else
		ctx.bytecode:emitAD(Opcodes.LOP_LOADN, regs + 1, 1)
	end

	local forLabel = ctx.bytecode:emitLabel()
	ctx.bytecode:emitAD(Opcodes.LOP_FORNPREP, regs, 0)

	local loopLabel = ctx.bytecode:emitLabel()
	if varreg ~= regs + 2 then
		ctx.bytecode:emitABC(Opcodes.LOP_MOVE, varreg, regs + 2, 0)
	end

	pushLocal(ctx, stat.var, varreg, varregallocpc)
	compileStat(ctx, stat.body)

	closeLocals(ctx, oldLocals)
	popLocals(ctx, oldLocals)

	setDebugLine(ctx, statId)
	local contLabel = ctx.bytecode:emitLabel()
	local backLabel = ctx.bytecode:emitLabel()
	ctx.bytecode:emitAD(Opcodes.LOP_FORNLOOP, regs, 0)

	local endLabel = ctx.bytecode:emitLabel()
	patchJump(ctx, statId, forLabel, endLabel)
	patchJump(ctx, statId, backLabel, loopLabel)
	patchLoopJumps(ctx, statId, oldJumps, endLabel, contLabel)
	ctx.loopDepth = ld - 1
	ctx.regTop = oldTop
end

@native
local function compileStatForIn(ctx: CompilerCtx, statId: number)
	local oldTop = ctx.regTop
	local stat = ctx.nodes[statId]
	local varsFirst = if stat.vars ~= 0 then ctx.listFirsts[stat.vars] else 0
	local varsCount = if stat.vars ~= 0 then ctx.listCounts[stat.vars] else 0
	local valsFirst = if stat.values ~= 0 then ctx.listFirsts[stat.values] else 0
	local valsCount = if stat.values ~= 0 then ctx.listCounts[stat.values] else 0
	local listValues = ctx.listValues

	local oldLocals = #ctx.localStack
	local oldJumps = ctx.loopJumpCount
	local ld = ctx.loopDepth + 1
	ctx.loopDepth = ld
	ctx.loopLocalOffsets[ld] = oldLocals
	ctx.loopLocalOffsetsContinue[ld] = oldLocals
	ctx.loopContinueUsed[ld] = 0
	ctx.hasLoops = true

	local regs = allocReg(ctx, statId, 3)
	compileExprListTemp(ctx, stat.values, regs, 3, true)

	local vars = allocReg(ctx, statId, math.max(varsCount, 2))
	assert(vars == regs + 3, "for-in vars reg mismatch")
	local varsallocpc = ctx.bytecode.insnCount

	local skipOp = Opcodes.LOP_FORGPREP
	if ctx.optimizationLevel >= 1 and varsCount <= 2 then
		if valsCount == 1 and ctx.kinds[listValues[valsFirst]] == K.AstExprCall then
			local callNode = ctx.nodes[listValues[valsFirst]]
			local bObj, bMethod = CompilerBuiltins.getBuiltin(callNode.func, ctx.arena, ctx.globals, ctx.vars)
			if bObj == nil and bMethod == "ipairs" then
				skipOp = Opcodes.LOP_FORGPREP_INEXT
			elseif bObj == nil and bMethod == "pairs" then
				skipOp = Opcodes.LOP_FORGPREP_NEXT
			end
		elseif valsCount == 2 and (not ctx.getfenvUsed and not ctx.setfenvUsed) then
			local bObj, bMethod = CompilerBuiltins.getBuiltin(listValues[valsFirst], ctx.arena, ctx.globals, ctx.vars)
			if bObj == nil and bMethod == "next" then
				skipOp = Opcodes.LOP_FORGPREP_NEXT
			end
		end
	end

	local skipLabel = ctx.bytecode:emitLabel()
	ctx.bytecode:emitAD(skipOp, regs, 0)

	local loopLabel = ctx.bytecode:emitLabel()
	for i = 0, varsCount - 1 do
		pushLocal(ctx, listValues[varsFirst + i], vars + i, varsallocpc)
	end

	compileStat(ctx, stat.body)

	closeLocals(ctx, oldLocals)
	popLocals(ctx, oldLocals)

	setDebugLine(ctx, statId)
	local contLabel = ctx.bytecode:emitLabel()
	local backLabel = ctx.bytecode:emitLabel()

	ctx.bytecode:emitAD(Opcodes.LOP_FORGLOOP, regs, 0)
	ctx.bytecode:emitAux(bit32.bor(if skipOp == Opcodes.LOP_FORGPREP_INEXT then 0x80000000 else 0, varsCount))

	local endLabel = ctx.bytecode:emitLabel()
	patchJump(ctx, statId, skipLabel, backLabel)
	patchJump(ctx, statId, backLabel, loopLabel)
	patchLoopJumps(ctx, statId, oldJumps, endLabel, contLabel)
	ctx.loopDepth = ld - 1
	ctx.regTop = oldTop
end

local resolveAssignConflicts: (CompilerCtx, number, number, AssignScratch, number) -> ()
do
	local function markAssignedLocalConflict(
		ctx: CompilerCtx,
		_nodeId: number,
		n: any,
		assigned: { [number]: boolean },
		conflict: { [number]: boolean }
	): boolean
		local reg = getLocalReg(ctx, n["local"])
		if reg >= 0 and assigned[reg] then
			conflict[reg] = true
		end
		return false
	end

	local function visitConflictExpr(
		ctx: CompilerCtx,
		nodeId: number,
		assigned: { [number]: boolean },
		conflict: { [number]: boolean }
	)
		(cachedVisitAstLocalNode or getCompilerInline().visitAstLocalNode)(
			ctx,
			nodeId,
			markAssignedLocalConflict,
			assigned,
			conflict,
			false
		)
	end

	function resolveAssignConflicts(
		ctx: CompilerCtx,
		statId: number,
		varsCount: number,
		sc: AssignScratch,
		valuesListId: number
	)
		local conflict = sc.conflict
		local assigned = sc.assigned
		table.clear(conflict)
		table.clear(assigned)

		local lvKinds = sc.lvKinds
		local lvRegs = sc.lvRegs
		local lvAuxs = sc.lvAuxs
		local conflictRegs = sc.conflictRegs
		local listValues = ctx.listValues

		local valsFirst = if valuesListId ~= 0 then ctx.listFirsts[valuesListId] else 0
		local valsCount = if valuesListId ~= 0 then ctx.listCounts[valuesListId] else 0

		for i = 1, varsCount do
			if lvKinds[i] == LValueKind.Local then
				if i - 1 < valsCount then
					visitConflictExpr(ctx, listValues[valsFirst + i - 1], assigned, conflict)
				end
				assigned[lvRegs[i]] = true
			end
		end

		for i = 1, varsCount do
			if lvKinds[i] ~= LValueKind.Local and i - 1 < valsCount then
				visitConflictExpr(ctx, listValues[valsFirst + i - 1], assigned, conflict)
			end
		end

		for i = varsCount, valsCount - 1 do
			visitConflictExpr(ctx, listValues[valsFirst + i], assigned, conflict)
		end

		for i = 1, varsCount do
			local lk = lvKinds[i]
			local lr = lvRegs[i]
			if
				(
					lk == LValueKind.IndexName
					or lk == LValueKind.IndexNumber
					or lk == LValueKind.IndexExpr
					or (ctx.flagDebugClasses and lk == LValueKind.PrivateField)
				) and assigned[lr]
			then
				conflict[lr] = true
			end
			if lk == LValueKind.IndexExpr and assigned[lvAuxs[i]] then
				conflict[lvAuxs[i]] = true
			end
		end

		for i = 1, varsCount do
			if lvKinds[i] == LValueKind.Local and conflict[lvRegs[i]] then
				conflictRegs[i] = allocReg(ctx, statId, 1)
			end
		end
	end
end

@native
local function compileStatAssign(ctx: CompilerCtx, statId: number)
	local oldTop = ctx.regTop
	local stat = ctx.nodes[statId]
	local varsFirst = if stat.vars ~= 0 then ctx.listFirsts[stat.vars] else 0
	local varsCount = if stat.vars ~= 0 then ctx.listCounts[stat.vars] else 0
	local valsFirst = if stat.values ~= 0 then ctx.listFirsts[stat.values] else 0
	local valsCount = if stat.values ~= 0 then ctx.listCounts[stat.values] else 0
	local listValues = ctx.listValues

	if varsCount == 1 and valsCount == 1 then
		local var0Id = listValues[varsFirst]
		local val0Id = listValues[valsFirst]
		local lvKind, lvReg, lvAux, lvName, lvSymId, lvStart, lvFinish = compileLValueUnboxed(ctx, var0Id)
		if lvKind == LValueKind.Local then
			compileExpr(ctx, val0Id, lvReg)
		else
			local reg = compileExprAuto(ctx, val0Id)
			setDebugLine(ctx, var0Id)
			compileLValueUseUnboxed(ctx, lvKind, lvReg, lvAux, lvName, lvSymId, lvStart, lvFinish, reg, true, var0Id)
		end
		ctx.regTop = oldTop
		return
	end

	local sc = acquireAssignScratch(ctx)
	local lvKinds = sc.lvKinds
	local lvRegs = sc.lvRegs
	local lvAuxs = sc.lvAuxs
	local lvNames = sc.lvNames
	local lvSymIds = sc.lvSymIds
	local lvStarts = sc.lvStarts
	local lvFinishes = sc.lvFinishes
	local conflictRegs = sc.conflictRegs
	local valueRegs = sc.valueRegs

	for i = 0, varsCount - 1 do
		local idx = i + 1
		lvKinds[idx], lvRegs[idx], lvAuxs[idx], lvNames[idx], lvSymIds[idx], lvStarts[idx], lvFinishes[idx] =
			compileLValueUnboxed(ctx, listValues[varsFirst + i])
		conflictRegs[idx] = kInvalidReg
		valueRegs[idx] = kInvalidReg
	end

	resolveAssignConflicts(ctx, statId, varsCount, sc, stat.values)

	local limit = math.min(varsCount, valsCount)
	for i = 0, limit - 1 do
		local valueId = listValues[valsFirst + i]
		if i + 1 == valsCount and varsCount > valsCount then
			local rest = varsCount - valsCount + 1
			local temp = allocReg(ctx, statId, rest)
			compileExprTempN(ctx, valueId, temp, rest, true)
			for j = i, varsCount - 1 do
				valueRegs[j + 1] = temp + (j - i)
			end
		else
			local idx = i + 1
			if lvKinds[idx] == LValueKind.Local then
				local vreg = if conflictRegs[idx] == kInvalidReg then lvRegs[idx] else conflictRegs[idx]
				valueRegs[idx] = vreg
				compileExpr(ctx, valueId, vreg)
			else
				valueRegs[idx] = compileExprAuto(ctx, valueId)
			end
		end
	end

	for i = varsCount, valsCount - 1 do
		compileExprSide(ctx, listValues[valsFirst + i])
	end

	for i = 1, varsCount do
		local vreg = valueRegs[i]
		assert(vreg ~= kInvalidReg, "unassigned valueReg")
		if lvKinds[i] ~= LValueKind.Local then
			setDebugLineOffset(ctx, lvStarts[i])
			local targetExprId = listValues[varsFirst + i - 1]
			compileLValueUseUnboxed(
				ctx,
				lvKinds[i],
				lvRegs[i],
				lvAuxs[i],
				lvNames[i],
				lvSymIds[i],
				lvStarts[i],
				lvFinishes[i],
				vreg,
				true,
				targetExprId
			)
		end
	end

	for i = 1, varsCount do
		if lvKinds[i] == LValueKind.Local and valueRegs[i] ~= lvRegs[i] then
			ctx.bytecode:emitABC(Opcodes.LOP_MOVE, lvRegs[i], valueRegs[i], 0)
		end
	end
	releaseAssignScratch(ctx, sc)
	ctx.regTop = oldTop
end

@native
local function compileStatCompoundAssign(ctx: CompilerCtx, statId: number)
	local oldTop = ctx.regTop
	local stat = ctx.nodes[statId]
	local lvKind, lvReg, lvAux, lvName, lvSymId, lvStart, lvFinish = compileLValueUnboxed(ctx, stat.var)
	local target = if lvKind == LValueKind.Local then lvReg else allocReg(ctx, statId, 1)

	local op = stat.op
	if op == "Add" or op == "Sub" or op == "Mul" or op == "Div" or op == "FloorDiv" or op == "Mod" or op == "Pow" then
		if lvKind ~= LValueKind.Local then
			compileLValueUseUnboxed(
				ctx,
				lvKind,
				lvReg,
				lvAux,
				lvName,
				lvSymId,
				lvStart,
				lvFinish,
				target,
				false,
				stat.var
			)
		end
		local rc = getConstantNumber(ctx, stat.value)
		if rc >= 0 and rc <= 255 then
			ctx.bytecode:emitABC(BINARY_ARITHK_OPS[op], target, target, rc)
		else
			local rr = compileExprAuto(ctx, stat.value)
			ctx.bytecode:emitABC(BINARY_ARITH_OPS[op], target, target, rr)
			if lvKind ~= LValueKind.Local then
				hintTemporaryRegType(ctx, stat.var, target, Types.LBC_TYPE_NUMBER, 1)
			end
			hintTemporaryExprRegType(ctx, stat.value, rr, Types.LBC_TYPE_NUMBER, 1)
		end
	elseif op == "Concat" then
		local args = acquireConcatList(ctx)
		args[1] = stat.value
		unrollConcats(ctx, args)
		local argc = #args
		local regs = allocReg(ctx, statId, 1 + argc)
		compileLValueUseUnboxed(ctx, lvKind, lvReg, lvAux, lvName, lvSymId, lvStart, lvFinish, regs, false, stat.var)
		for i = 1, argc do
			compileExprTempTop(ctx, args[i], regs + i)
		end
		releaseConcatList(ctx, args)
		ctx.bytecode:emitABC(Opcodes.LOP_CONCAT, target, regs, regs + argc)
	else
		error("Unexpected compound assignment operation")
	end

	if lvKind ~= LValueKind.Local then
		compileLValueUseUnboxed(ctx, lvKind, lvReg, lvAux, lvName, lvSymId, lvStart, lvFinish, target, true, stat.var)
	end
	ctx.regTop = oldTop
end

@native
local function compileStatFunction(ctx: CompilerCtx, statId: number)
	local stat = ctx.nodes[statId]
	local reg = getExprLocalReg(ctx, stat.name)
	if reg >= 0 then
		compileExpr(ctx, stat.func, reg)
		return
	end

	local oldTop = ctx.regTop
	local temp = allocReg(ctx, statId, 1)
	compileExprTemp(ctx, stat.func, temp)
	local lvKind, lvReg, lvAux, lvName, lvSymId, lvStart, lvFinish = compileLValueUnboxed(ctx, stat.name)
	compileLValueUseUnboxed(ctx, lvKind, lvReg, lvAux, lvName, lvSymId, lvStart, lvFinish, temp, true, stat.name)
	ctx.regTop = oldTop
end

@native
local function compileStatBlock(ctx: CompilerCtx, nodeId: number, n: any)
	local oldTop = ctx.regTop
	local oldLocals = #ctx.localStack
	if ctx.flags.LuauExportValueSyntax then
		ctx.blockDepth += 1
	end

	local terminatesEarly = false
	local bodyFirst = if n.body ~= 0 then ctx.listFirsts[n.body] else 0
	local bodyCount = if n.body ~= 0 then ctx.listCounts[n.body] else 0
	local listValues = ctx.listValues
	local termCache = if #ctx.inlineFrames == 0 and ctx.trialDepth == 0 then ctx.alwaysTermCache else nil

	local kinds = ctx.kinds
	local prevOwner, prevBase, prevLiveCount, prevMinFinish = enterBlockLive(ctx, nodeId)
	for i = 0, bodyCount - 1 do
		local bodyStatId = listValues[bodyFirst + i]
		popStatLocals(ctx, bodyStatId)
		compileStat(ctx, bodyStatId)
		local sk = kinds[bodyStatId]
		if sk ~= nil then
			if sk == K.AstStatReturn or sk == K.AstStatBreak or sk == K.AstStatContinue then
				terminatesEarly = true
				break
			elseif
				(sk == K.AstStatBlock or sk == K.AstStatIf)
				and CompilerFolding.alwaysTerminates(ctx.arena, ctx.constants, bodyStatId, termCache)
			then
				terminatesEarly = true
				break
			end
		end
	end
	leaveBlockLive(ctx, prevOwner, prevBase, prevLiveCount, prevMinFinish)

	if ctx.flags.LuauExportValueSyntax then
		ctx.blockDepth -= 1
	end

	if not terminatesEarly then
		closeLocals(ctx, oldLocals)
	end

	popLocals(ctx, oldLocals)
	ctx.regTop = oldTop
end

@native
local function compileStatLocalFunction(ctx: CompilerCtx, nodeId: number, n: any)
	local b = ctx.bindings[n.name]
	if ctx.flags.LuauExportValueSyntax and not ctx.flags.LuauOptimizeExportTable and b.isExported then
		checkExportedLocal(ctx, n.name, n.start, n.finish)
		ensureExportTable(ctx, nodeId)
		local oldTop = ctx.regTop
		local var = allocReg(ctx, nodeId, 1)
		compileExprFunction(ctx, n.func, var)
		local lnameSym = b.name
		local lname = ctx.symbols[lnameSym]
		local cid = ctx.bytecode:addConstantString(lname)
		checkConstantBinding(ctx, cid, n.name)
		local tableReg = getExportTableReg(ctx, nodeId)
		ctx.bytecode:emitABC(Opcodes.LOP_SETTABLEKS, var, tableReg, getSymHash(ctx, lnameSym, lname))
		ctx.bytecode:emitAux(cid)
		ctx.regTop = oldTop
	else
		local var = kInvalidReg
		local reused, reusedReg = tryReuseLocalReg(ctx, n.name)
		if reused then
			var = reusedReg
		else
			var = allocReg(ctx, nodeId, 1)
		end
		pushLocal(ctx, n.name, var, kDefaultAllocPc)
		compileExprFunction(ctx, n.func, var)
		if ctx.recordDebug then
			ctx.localDebugPc[n.name] = ctx.bytecode.insnCount
		end
	end
end

@native
function compileStat(ctx: CompilerCtx, nodeId: number)
	local n = ctx.nodes[nodeId]
	if ctx.debugLevel >= 1 then
		local offset = n.start
		if offset >= ctx.lastLineStart and offset < ctx.lastLineEnd then
			ctx.bytecode.debugLine = ctx.lastLineNum
		else
			ctx.bytecode.debugLine = getLine0(ctx, offset) + 1
		end
	end
	local k = ctx.kinds[nodeId]

	if ctx.coverageLevel >= 1 and k ~= K.AstStatBlock and k ~= K.AstStatTypeAlias then
		ctx.bytecode:emitABC(Opcodes.LOP_COVERAGE, 0, 0, 0)
	end

	if k == K.AstStatBlock then
		compileStatBlock(ctx, nodeId, n)
	elseif k == K.AstStatIf then
		compileStatIf(ctx, nodeId)
	elseif k == K.AstStatWhile then
		compileStatWhile(ctx, nodeId)
	elseif k == K.AstStatRepeat then
		compileStatRepeat(ctx, nodeId)
	elseif k == K.AstStatBreak then
		local ld = ctx.loopDepth
		assert(ld > 0, "break outside loop")
		closeLocals(ctx, ctx.loopLocalOffsets[ld])
		local label = ctx.bytecode:emitLabel()
		ctx.bytecode:emitAD(Opcodes.LOP_JUMP, 0, 0)
		local lj = ctx.loopJumpCount + 1
		ctx.loopJumpCount = lj
		ctx.loopJumpTypes[lj] = LoopJumpType.Break
		ctx.loopJumpLabels[lj] = label
	elseif k == K.AstStatContinue then
		local ld = ctx.loopDepth
		assert(ld > 0, "continue outside loop")
		if ctx.loopContinueUsed[ld] == 0 then
			ctx.loopContinueUsed[ld] = nodeId
		end
		closeLocals(ctx, ctx.loopLocalOffsetsContinue[ld])
		local label = ctx.bytecode:emitLabel()
		ctx.bytecode:emitAD(Opcodes.LOP_JUMP, 0, 0)
		local lj = ctx.loopJumpCount + 1
		ctx.loopJumpCount = lj
		ctx.loopJumpTypes[lj] = LoopJumpType.Continue
		ctx.loopJumpLabels[lj] = label
	elseif k == K.AstStatReturn then
		if ctx.optimizationLevel >= 2 and #ctx.inlineFrames > 0 then
			compileInlineReturn(ctx, nodeId)
		else
			compileStatReturn(ctx, nodeId)
		end
	elseif k == K.AstStatExpr then
		if ctx.kinds[n.expr] == K.AstExprCall then
			compileExprCall(ctx, n.expr, ctx.regTop, 0)
		else
			compileExprSide(ctx, n.expr)
		end
	elseif k == K.AstStatLocal then
		if ctx.flags.LuauExportValueSyntax and n.vars ~= 0 then
			local vlFirst = ctx.listFirsts[n.vars]
			local vlCount = ctx.listCounts[n.vars]
			for i = 0, vlCount - 1 do
				checkExportedLocal(ctx, ctx.listValues[vlFirst + i], n.start, n.finish)
			end
		end
		compileStatLocal(ctx, nodeId)
	elseif k == K.AstStatFor then
		compileStatFor(ctx, nodeId)
	elseif k == K.AstStatForIn then
		compileStatForIn(ctx, nodeId)
	elseif k == K.AstStatAssign then
		compileStatAssign(ctx, nodeId)
	elseif k == K.AstStatCompoundAssign then
		compileStatCompoundAssign(ctx, nodeId)
	elseif k == K.AstStatFunction then
		compileStatFunction(ctx, nodeId)
	elseif k == K.AstStatLocalFunction then
		compileStatLocalFunction(ctx, nodeId, n)
	elseif k == K.AstStatTypeAlias then
		if ctx.flags.LuauExportedTypesParticipateInScc and n.exported and atTopLevel(ctx) then
			ctx.exports.hasTypeExports = true
		end
	elseif ctx.flagDebugClasses and k == K.AstStatClass then
		getCompilerClass().compileClassDeclaration(ctx, nodeId)
	elseif
		not (
			k == K.AstStatTypeFunction
			or k == K.AstStatDeclareGlobal
			or k == K.AstStatDeclareFunction
			or k == K.AstStatDeclareExternType
		)
	then
		error("Unknown statement type: " .. tostring(k))
	end
end

function getCompilerClass(): any
	local mod = CompilerClassMod
	if mod == nil then
		mod = require("./CompilerClass")
		mod.bind({
			raiseCompileError = raiseCompileError,
			checkConstantNode = checkConstantNode,
			allocReg = allocReg,
			pushLocal = pushLocal,
			checkExportedLocal = checkExportedLocal,
			ensureExportTable = ensureExportTable,
			getExprLocalReg = getExprLocalReg,
			compileExpr = compileExpr,
			compileExprFunction = compileExprFunction,
			compileLValueUnboxed = compileLValueUnboxed,
			compileLValueUseUnboxed = compileLValueUseUnboxed,
		})
		CompilerClassMod = mod
	end
	return mod
end

function getCompilerInline(): any
	local mod = CompilerInlineMod
	if mod == nil then
		mod = require("./CompilerInline")
		mod.bind({
			allocReg = allocReg,
			getLocalReg = getLocalReg,
			getExprLocal = getExprLocal,
			getExprLocalReg = getExprLocalReg,
			pushLocal = pushLocal,
			closeLocals = closeLocals,
			popLocals = popLocals,
			enterBlockLive = enterBlockLive,
			leaveBlockLive = leaveBlockLive,
			popStatLocals = popStatLocals,
			patchJump = patchJump,
			patchJumps = patchJumps,
			patchLoopJumps = patchLoopJumps,
			isConstant = isConstant,
			acquireJumpList = acquireJumpList,
			releaseJumpList = releaseJumpList,
			compileStat = compileStat,
			isExprMultRet = isExprMultRet,
			compileExprTemp = compileExprTemp,
			compileExprAutoTemp = CompilerExpr.compileExprAutoTemp,
			compileExprCall = compileExprCall,
			compileExprVarargs = CompilerExpr.compileExprVarargs,
			compileExprSide = compileExprSide,
			getFunctionExpr = CompilerExpr.getFunctionExpr,
		})
		CompilerInlineMod = mod
		cachedTryInlineCallExpr = mod.tryInlineCallExpr
		cachedVisitAstLocalNode = mod.visitAstLocalNode
		cachedTryCompileUnrolledFor = mod.tryCompileUnrolledFor
	end
	return mod
end

CompilerExpr.bind({
	raiseCompileError = raiseCompileError,
	allocReg = allocReg,
	getLocalReg = getLocalReg,
	getExprLocalReg = getExprLocalReg,
	getUpval = getUpval,
	setDebugLineOffset = setDebugLineOffset,
	needsCoverage = needsCoverage,
	hintTemporaryExprRegType = hintTemporaryExprRegType,
	patchJump = patchJump,
	patchJumps = patchJumps,
	patchSkipCOrThrow = patchSkipCOrThrow,
	checkConstantNode = checkConstantNode,
	isConstant = isConstant,
	isConstantTrue = isConstantTrue,
	isConstantVector = isConstantVector,
	getConstant = getConstant,
	getConstantNumber = getConstantNumber,
	getConstantIndex = getConstantIndex,
	emitLoadK = emitLoadK,
	acquireJumpList = acquireJumpList,
	releaseJumpList = releaseJumpList,
	acquireKeyValMap = acquireKeyValMap,
	releaseKeyValMap = releaseKeyValMap,
	acquireConcatList = acquireConcatList,
	releaseConcatList = releaseConcatList,
	getExportTableReg = getExportTableReg,
	closeLocals = closeLocals,
	pushLocal = pushLocal,
	popLocals = popLocals,
	tryInlineCallExpr = function(
		exprCtx: CompilerCtx,
		exprId: number,
		expr: any,
		target: number,
		targetCount: number,
		isMultRet: boolean
	): boolean
		if exprCtx.optimizationLevel < 2 then
			return false
		end
		return (cachedTryInlineCallExpr or getCompilerInline().tryInlineCallExpr)(
			exprCtx,
			exprId,
			expr,
			target,
			targetCount,
			isMultRet
		)
	end,
	computePrivateFieldInfo = function(
		exprCtx: CompilerCtx,
		indexSym: number,
		startPos: number,
		finishPos: number
	): (number, number, boolean)
		return getCompilerClass().computePrivateFieldInfo(exprCtx, indexSym, startPos, finishPos)
	end,
	compilePrivateFieldAccess = function(
		exprCtx: CompilerCtx,
		expr: any,
		target: number,
		selfReg: number,
		isWrite: boolean?
	)
		getCompilerClass().compilePrivateFieldAccess(exprCtx, expr, target, selfReg, isWrite)
	end,
})

local compileFunction: (CompilerCtx, number, number, any?) -> (number, number)
do
	type ReturnAnalysisState = {
		returnsOne: boolean,
		returnKind: number,
		returnLocal: number,
		funcArgFirst: number,
		funcArgCount: number,
	}

	local function analyzeReturnStatNode(ctx: CompilerCtx, n: any, st: ReturnAnalysisState)
		local first = if n.list ~= 0 then ctx.listFirsts[n.list] else 0
		local count = if n.list ~= 0 then ctx.listCounts[n.list] else 0
		if count == 1 and not isExprMultRet(ctx, ctx.listValues[first]) then
			local exprLocalId = getExprLocal(ctx, ctx.listValues[first])
			if exprLocalId ~= 0 then
				local exprLocal = ctx.nodes[exprLocalId]
				local kind = ReturnKind.Local
				local locId = exprLocal["local"]
				for i = 0, st.funcArgCount - 1 do
					if ctx.listValues[st.funcArgFirst + i] == locId then
						kind = ReturnKind.Parameter
						break
					end
				end
				if exprLocal.upvalue then
					kind = ReturnKind.Expression
					locId = 0
				end
				if st.returnKind == ReturnKind.None then
					st.returnKind = kind
					st.returnLocal = locId
				elseif st.returnKind ~= kind or st.returnLocal ~= locId then
					st.returnKind = ReturnKind.Unknown
					st.returnLocal = 0
				end
			else
				if st.returnKind == ReturnKind.None then
					st.returnKind = ReturnKind.Expression
				elseif st.returnKind ~= ReturnKind.Expression then
					st.returnKind = ReturnKind.Unknown
					st.returnLocal = 0
				end
			end
		else
			st.returnsOne = false
			st.returnKind = ReturnKind.Unknown
			st.returnLocal = 0
		end
	end

	@native
	local function visitAnalyzeReturnStat(ctx: CompilerCtx, nodeId: number, st: ReturnAnalysisState)
		if nodeId == 0 then
			return
		end
		local n = ctx.nodes[nodeId]
		local k = ctx.kinds[nodeId]
		if k == K.AstStatReturn then
			analyzeReturnStatNode(ctx, n, st)
		elseif k == K.AstStatBlock then
			if n.body ~= 0 then
				local first = ctx.listFirsts[n.body]
				local count = ctx.listCounts[n.body]
				for i = 0, count - 1 do
					visitAnalyzeReturnStat(ctx, ctx.listValues[first + i], st)
				end
			end
		elseif k == K.AstStatIf then
			visitAnalyzeReturnStat(ctx, n.thenbody, st)
			visitAnalyzeReturnStat(ctx, n.elsebody, st)
		elseif k == K.AstStatWhile or k == K.AstStatRepeat or k == K.AstStatFor or k == K.AstStatForIn then
			visitAnalyzeReturnStat(ctx, n.body, st)
		end
	end

	local function analyzeReturns(ctx: CompilerCtx, funcId: number): (boolean, number, number)
		local func = ctx.nodes[funcId]
		local funcArgFirst = if func.args ~= 0 then ctx.listFirsts[func.args] else 0
		local funcArgCount = if func.args ~= 0 then ctx.listCounts[func.args] else 0
		local st: ReturnAnalysisState = {
			returnsOne = true,
			returnKind = ReturnKind.None,
			returnLocal = 0,
			funcArgFirst = funcArgFirst,
			funcArgCount = funcArgCount,
		}
		visitAnalyzeReturnStat(ctx, func.body, st)
		return st.returnsOne, st.returnKind, st.returnLocal
	end

	local function emitFunctionBodyAndReturn(ctx: CompilerCtx, statId: number): boolean
		local stat = ctx.nodes[statId]
		local bodyFirst = if stat.body ~= 0 then ctx.listFirsts[stat.body] else 0
		local bodyCount = if stat.body ~= 0 then ctx.listCounts[stat.body] else 0
		local listValues = ctx.listValues
		local terminatesEarly = false
		local termCache = if #ctx.inlineFrames == 0 and ctx.trialDepth == 0 then ctx.alwaysTermCache else nil

		local kinds = ctx.kinds
		local prevOwner, prevBase, prevLiveCount, prevMinFinish = enterBlockLive(ctx, statId)
		for i = 0, bodyCount - 1 do
			local bodyStatId = listValues[bodyFirst + i]
			popStatLocals(ctx, bodyStatId)
			compileStat(ctx, bodyStatId)
			local sk = kinds[bodyStatId]
			if sk == K.AstStatReturn or sk == K.AstStatBreak or sk == K.AstStatContinue then
				terminatesEarly = true
				break
			elseif
				(sk == K.AstStatBlock or sk == K.AstStatIf)
				and CompilerFolding.alwaysTerminates(ctx.arena, ctx.constants, bodyStatId, termCache)
			then
				terminatesEarly = true
				break
			end
		end
		leaveBlockLive(ctx, prevOwner, prevBase, prevLiveCount, prevMinFinish)

		if
			ctx.flags.LuauExportValueSyntax
			and atTopLevel(ctx)
			and (
				not isExportsEmpty(ctx)
				or (
					ctx.flags.LuauExportedTypesParticipateInScc
					and ctx.exports.hasTypeExports
					and not ctx.exports.hasModuleReturn
				)
			)
		then
			setDebugLineEnd(ctx, statId)
			compileExportTable(ctx)
		elseif not terminatesEarly then
			setDebugLineEnd(ctx, statId)
			closeLocals(ctx, 0)
			ctx.bytecode:emitABC(Opcodes.LOP_RETURN, 0, 1, 0)
		end

		return terminatesEarly
	end

	local function emitFunctionDebugAndTypes(ctx: CompilerCtx, funcId: number, func: any)
		ctx.bytecode:setDebugFunctionLineDefined(getLine0(ctx, func.start) + 1)

		if ctx.debugLevel >= 1 and func.debugname and func.debugname ~= 0 then
			ctx.bytecode:setDebugFunctionName(ctx.symbols[func.debugname])
		end

		if ctx.debugLevel >= 2 and #ctx.upvals > 0 then
			if ctx.flagDebugClasses then
				local classes = ctx.enclosingClasses[funcId]
				for i = 1, #ctx.upvals do
					local l = ctx.upvals[i]
					if l == kInvalidUpvalue then
						assert(classes, "expected enclosing classes for dummy upval")
						ctx.bytecode:pushDebugUpval(getCompilerClass().getClassNodeName(ctx, ctx.nodes[classes[i]]))
					else
						ctx.bytecode:pushDebugUpval(ctx.symbols[ctx.bindings[l].name])
					end
				end
			else
				for _, l in ctx.upvals do
					ctx.bytecode:pushDebugUpval(ctx.symbols[ctx.bindings[l].name])
				end
			end
		end

		if ctx.typeInfoLevel >= 1 then
			for _, l in ctx.upvals do
				local ty = ctx.localTypes[l] or Types.LBC_TYPE_ANY
				ctx.bytecode:pushUpvalTypeInfo(ty)
			end
		end

		if ctx.optimizationLevel >= 1 then
			ctx.bytecode:foldJumps()
		end

		local hasLongJumpError = ctx.bytecode:expandJumps()
		if hasLongJumpError then
			raiseCompileError(
				ctx,
				func.start,
				func.finish,
				"Exceeded jump distance limit; simplify the code to compile"
			)
		end

		popLocals(ctx, 0)

		if ctx.bytecode.insnCount > kMaxInstructionCount then
			raiseCompileError(
				ctx,
				func.start,
				func.finish,
				"Exceeded function instruction limit; split the function into parts to compile"
			)
		end

		local funcType = ctx.functionTypes[funcId]
		if funcType ~= nil then
			ctx.bytecode:setFunctionTypeInfo(funcType)
		end
	end

	local function computeFunctionProtoFlags(
		ctx: CompilerCtx,
		func: any,
		protoflags: number,
		terminatesEarly: boolean
	): (number, boolean, number, number)
		if func.functionDepth == 0 and not ctx.hasLoops then
			protoflags = bit32.bor(protoflags, ProtoFlags.LPF_NATIVE_COLD)
		end
		if hasAttribute(ctx.arena, func.attributes, "Native") then
			protoflags = bit32.bor(protoflags, ProtoFlags.LPF_NATIVE_FUNCTION)
		end
		if ctx.flags.LuauExportValueSyntax and not isExportsEmpty(ctx) and func.functionDepth == 0 then
			protoflags = bit32.bor(protoflags, ProtoFlags.LPF_USES_EXPORT)
		end
		if
			ctx.flags.LuauExportedTypesParticipateInScc
			and ctx.exports.hasTypeExports
			and not ctx.exports.hasModuleReturn
			and func.functionDepth == 0
		then
			protoflags = bit32.bor(protoflags, ProtoFlags.LPF_USES_EXPORT)
		end

		local isInlinable = not ctx.hasMultiRet and not ctx.getfenvUsed and not ctx.setfenvUsed
		if ctx.flags.LuauCompileRequireNoInline and ctx.hasRequire then
			isInlinable = false
		end
		local hasCostModel = false
		local costModelLo = 0
		local costModelHi = 0
		local termCache = if #ctx.inlineFrames == 0 and ctx.trialDepth == 0 then ctx.alwaysTermCache else nil
		if isInlinable and #ctx.upvals == 0 then
			protoflags = bit32.bor(protoflags, ProtoFlags.LPF_INLINABLE)
			costModelLo, costModelHi = (cachedModelCostList or getCompilerTypes().modelCostList)(
				ctx.arena,
				func.body,
				func.args,
				ctx.builtins,
				ctx.constants,
				termCache
			)
			hasCostModel = true
		end

		return protoflags, hasCostModel, costModelLo, costModelHi
	end

	local EMPTY_UPVALS: { number } = table.freeze({} :: { number })

	local function recordCompiledFunctionInfo(
		ctx: CompilerCtx,
		funcId: number,
		func: any,
		fid: number,
		hasCostModel: boolean,
		costLo: number,
		costHi: number
	)
		local f = {
			id = fid,
			upvals = if #ctx.upvals == 0 then EMPTY_UPVALS else table.clone(ctx.upvals),
			costLo = costLo,
			costHi = costHi,
			stackSize = ctx.stackSize,
			canInline = false,
			returnsOne = false,
			returnKind = ReturnKind.None,
			returnLocal = 0,
			returnLocalCaptured = false,
		}
		ctx.functions[funcId] = f

		if
			ctx.optimizationLevel >= 2
			and not func.vararg
			and func.self == 0
			and not ctx.getfenvUsed
			and not ctx.setfenvUsed
		then
			if ctx.flags.DebugLuauNoInline and hasAttribute(ctx.arena, func.attributes, "DebugNoinline") then
				f.canInline = false
			else
				f.canInline = true
			end
			f.stackSize = ctx.stackSize
			local termCache = if #ctx.inlineFrames == 0 and ctx.trialDepth == 0 then ctx.alwaysTermCache else nil
			if not hasCostModel then
				f.costLo, f.costHi = (cachedModelCostList or getCompilerTypes().modelCostList)(
					ctx.arena,
					func.body,
					func.args,
					ctx.builtins,
					ctx.constants,
					termCache
				)
			end

			if CompilerFolding.alwaysTerminates(ctx.arena, ctx.constants, func.body, termCache) then
				local returnsOne, returnKind, returnLocal = analyzeReturns(ctx, funcId)
				f.returnsOne = returnsOne
				f.returnKind = returnKind
				f.returnLocal = returnLocal
				if returnLocal ~= 0 and ctx.localCaptured[returnLocal] then
					f.returnLocalCaptured = true
				end
			end
		end
	end

	@native
	function compileFunction(ctx: CompilerCtx, funcId: number, protoflags: number, nodeOverride: any?): (number, number)
		assert(ctx.functions[funcId] == nil, "function already compiled")
		assert(
			ctx.regTop == 0 and ctx.stackSize == 0 and #ctx.localStack == 0 and #ctx.upvals == 0,
			"non-empty function state at start"
		)
		assert(ctx.activeLocals == 0, "non-empty activeLocals at start")
		local oldTop = ctx.regTop
		local func = nodeOverride or ctx.nodes[funcId]
		ctx.currentFunctionId = funcId
		ctx.currentFunctionNode = func
		local selfCount = if func.self ~= 0 then 1 else 0
		local funcArgFirst = if func.args ~= 0 then ctx.listFirsts[func.args] else 0
		local funcArgCount = if func.args ~= 0 then ctx.listCounts[func.args] else 0

		local fid = ctx.bytecode:beginFunction(selfCount + funcArgCount, func.vararg)
		if nodeOverride ~= nil then
			setDebugLineOffset(ctx, func.start)
		else
			setDebugLine(ctx, funcId)
		end

		if ctx.flags.LuauExportValueSyntax and ctx.flags.LuauOptimizeExportTable and atTopLevel(ctx) then
			buildExportTableShape(ctx)
		end

		if ctx.flagDebugClasses then
			local classes = ctx.enclosingClasses[funcId]
			if classes then
				if #ctx.upvals + #classes > kMaxUpvalueCount then
					local dbgNameId = func.debugname
					local dbgName: string = if type(dbgNameId) == "number" and dbgNameId ~= 0
						then ctx.symbols[dbgNameId]
						else ""
					raiseCompileError(
						ctx,
						func.start,
						func.finish,
						string.format(
							"Out of upvalue registers when trying to allocate %s: exceeded limit %d",
							dbgName,
							kMaxUpvalueCount
						)
					)
				end
				for _ = 1, #classes do
					ctx.upvals[#ctx.upvals + 1] = kInvalidUpvalue
				end
			end
		end

		if func.vararg then
			ctx.bytecode:emitABC(Opcodes.LOP_PREPVARARGS, selfCount + funcArgCount, 0, 0)
		end

		local args = allocReg(ctx, funcId, selfCount + funcArgCount)
		if func.self ~= 0 then
			pushLocal(ctx, func.self, args, kDefaultAllocPc)
		end
		for i = 0, funcArgCount - 1 do
			pushLocal(ctx, ctx.listValues[funcArgFirst + i], args + selfCount + i, kDefaultAllocPc)
		end

		ctx.argCount = #ctx.localStack
		ctx.currentFunctionId = funcId
		local terminatesEarly = emitFunctionBodyAndReturn(ctx, func.body)

		emitFunctionDebugAndTypes(ctx, funcId, func)

		local hasCostModel: boolean
		local costModelLo: number
		local costModelHi: number
		protoflags, hasCostModel, costModelLo, costModelHi =
			computeFunctionProtoFlags(ctx, func, protoflags, terminatesEarly)

		ctx.bytecode:endFunction(ctx.stackSize, #ctx.upvals, protoflags, costModelLo, costModelHi)

		recordCompiledFunctionInfo(ctx, funcId, func, fid, hasCostModel, costModelLo, costModelHi)

		table.clear(ctx.upvals)
		table.clear(ctx.upvalMap)
		ctx.stackSize = 0
		ctx.freeCount = 0
		ctx.blockLiveCount = 0
		ctx.curBlockOwner = 0
		ctx.curBlockBase = 0
		ctx.curBlockMinFinish = math.huge
		ctx.argCount = 0
		ctx.hasLoops = false
		ctx.hasMultiRet = false
		ctx.hasRequire = false
		ctx.currentFunctionId = 0
		ctx.currentFunctionNode = nil
		ctx.regTop = oldTop

		return fid, protoflags
	end
end

local compile: (string | PublicTypes.ParseResult, CompileOptions?) -> (string?, string?)
local compileResult: (string | PublicTypes.ParseResult, CompileOptions?) -> CompileResult
local compileProto: (string | PublicTypes.ParseResult, CompileOptions?) -> (PublicTypes.ProtoModule?, string?)
do
	local function validateCompilerFlags(customFlags: { [string]: any })
		if type(customFlags) ~= "table" then
			error("Invalid CompileOptions.flags: expected table", 0)
		end
		for k, v in customFlags do
			local defaultVal = (CompilerFlags :: { [string]: any })[k]
			if defaultVal == nil then
				error("Unknown compiler flag: " .. tostring(k), 0)
			end
			if type(v) ~= type(defaultVal) then
				error("Invalid compiler flag value for " .. tostring(k), 0)
			end
			if type(v) == "number" and (v ~= v or v == math.huge or v == -math.huge or v < 0 or v ~= math.floor(v)) then
				error("Invalid compiler flag value for " .. tostring(k), 0)
			end
		end
	end

	local function validateCompileLevel(val: any, name: string, maxLevel: number)
		if val ~= nil then
			if type(val) ~= "number" or val ~= val or val < 0 or val > maxLevel or val ~= math.floor(val) then
				error(string.format("Invalid CompileOptions.%s: expected integer in 0..%d", name, maxLevel), 0)
			end
		end
	end

	local VALID_COMPILE_OPTION_KEYS: { [any]: boolean } = table.freeze({
		optimizationLevel = true,
		debugLevel = true,
		typeInfoLevel = true,
		coverageLevel = true,
		vectorLib = true,
		vectorCtor = true,
		vectorType = true,
		vectorPrecision = true,
		mutableGlobals = true,
		userdataTypes = true,
		librariesWithKnownMembers = true,
		libraryMemberTypeCb = true,
		libraryMemberConstantCb = true,
		disabledBuiltins = true,
		encoder = true,
		dumpFlags = true,
		flags = true,
		parseOptions = true,
	}) :: any

	local function validateStringListOption(val: any, name: string)
		if val ~= nil then
			if type(val) ~= "table" then
				error("Invalid CompileOptions." .. name .. ": expected array of strings", 2)
			end
			for k, item in val do
				if type(k) ~= "number" or k < 1 or math.floor(k) ~= k or type(item) ~= "string" then
					error("Invalid CompileOptions." .. name .. ": expected array of strings", 2)
				end
			end
		end
	end

	local function validateCompileOptions(inputOptions: CompileOptions?)
		if inputOptions == nil then
			return
		end
		if type(inputOptions) ~= "table" then
			error("Invalid CompileOptions: expected table", 2)
		end
		for k in inputOptions :: { [any]: any } do
			if not VALID_COMPILE_OPTION_KEYS[k] then
				error("Unknown CompileOptions key: " .. tostring(k), 2)
			end
		end
		validateCompileLevel(inputOptions.optimizationLevel, "optimizationLevel", 2)
		validateCompileLevel(inputOptions.debugLevel, "debugLevel", 2)
		validateCompileLevel(inputOptions.typeInfoLevel, "typeInfoLevel", 1)
		validateCompileLevel(inputOptions.coverageLevel, "coverageLevel", 2)
		validateCompileLevel(inputOptions.vectorPrecision, "vectorPrecision", 1)
		if inputOptions.vectorLib ~= nil and type(inputOptions.vectorLib) ~= "string" then
			error("Invalid CompileOptions.vectorLib: expected string", 2)
		end
		if inputOptions.vectorCtor ~= nil and type(inputOptions.vectorCtor) ~= "string" then
			error("Invalid CompileOptions.vectorCtor: expected string", 2)
		end
		if inputOptions.vectorType ~= nil and type(inputOptions.vectorType) ~= "string" then
			error("Invalid CompileOptions.vectorType: expected string", 2)
		end
		validateStringListOption(inputOptions.mutableGlobals, "mutableGlobals")
		validateStringListOption(inputOptions.userdataTypes, "userdataTypes")
		validateStringListOption(inputOptions.librariesWithKnownMembers, "librariesWithKnownMembers")
		validateStringListOption(inputOptions.disabledBuiltins, "disabledBuiltins")
		if inputOptions.libraryMemberTypeCb ~= nil and type(inputOptions.libraryMemberTypeCb) ~= "function" then
			error("Invalid CompileOptions.libraryMemberTypeCb: expected function", 2)
		end
		if inputOptions.libraryMemberConstantCb ~= nil and type(inputOptions.libraryMemberConstantCb) ~= "function" then
			error("Invalid CompileOptions.libraryMemberConstantCb: expected function", 2)
		end
		if
			inputOptions.dumpFlags ~= nil
			and (
				type(inputOptions.dumpFlags) ~= "number"
				or inputOptions.dumpFlags ~= inputOptions.dumpFlags
				or inputOptions.dumpFlags < 0
				or inputOptions.dumpFlags == math.huge
				or inputOptions.dumpFlags ~= math.floor(inputOptions.dumpFlags)
			)
		then
			error("Invalid CompileOptions.dumpFlags: expected non-negative integer", 2)
		end
		if
			inputOptions.encoder ~= nil
			and type(inputOptions.encoder) ~= "function"
			and not (type(inputOptions.encoder) == "table" and type(inputOptions.encoder.encode) == "function")
		then
			error("Invalid CompileOptions.encoder: expected function or { encode = function }", 2)
		end
		if inputOptions.flags ~= nil then
			validateCompilerFlags(inputOptions.flags)
		end
		if inputOptions.parseOptions ~= nil and type(inputOptions.parseOptions) ~= "table" then
			error("Invalid CompileOptions.parseOptions: expected table", 2)
		end
	end

	local function validateSourceOrParseResult(sourceOrParseResult: any)
		local st = type(sourceOrParseResult)
		if st == "string" then
			return
		end
		if
			st == "table"
			and type(sourceOrParseResult.arena) == "table"
			and type(sourceOrParseResult.root) == "number"
		then
			return
		end
		error("Expected source string or ParseResult table, got " .. st, 3)
	end

	local function initCompilerOptionsAndFlags(
		bytecode: any,
		parseResult: any,
		inputOptions: CompileOptions?
	): (
		CompileOptions,
		{ [string]: any },
		number,
		number,
		number,
		number,
		number,
		number
	)
		local opts: CompileOptions = if inputOptions then table.clone(inputOptions) else {}
		local optimizationLevel = if opts.optimizationLevel ~= nil then opts.optimizationLevel else 1
		local debugLevel = if opts.debugLevel ~= nil then opts.debugLevel else 1
		local typeInfoLevel = if opts.typeInfoLevel ~= nil then opts.typeInfoLevel else 0
		local coverageLevel = if opts.coverageLevel ~= nil then opts.coverageLevel else 0
		local vectorPrecision = if opts.vectorPrecision ~= nil then opts.vectorPrecision else 0

		local flags: { [string]: any } = bytecode.flags

		local mainFlags = 0
		if parseResult.hotcomments then
			for _, hc in parseResult.hotcomments do
				if hc.header and string.sub(hc.content, 1, 9) == "optimize " then
					local parsedNum = tonumber(string.match(string.sub(hc.content, 10), "^%s*([+-]?%d+)")) or 0
					optimizationLevel = math.clamp(parsedNum, 0, 2)
				end
				if hc.header and hc.content == "native" then
					mainFlags = bit32.bor(mainFlags, ProtoFlags.LPF_NATIVE_MODULE)
					optimizationLevel = 2
					typeInfoLevel = 1
				end
			end
		end

		return opts, flags, mainFlags, optimizationLevel, debugLevel, typeInfoLevel, coverageLevel, vectorPrecision
	end

	local function initExportTableBinding(ctx: CompilerCtx)
		local expSym = getOrAddSymbol(ctx, "__EXP")
		local lastId = #ctx.bindings
		local lastBinding = if lastId > 0 then ctx.bindings[lastId] else nil
		if lastBinding and lastBinding.name == expSym and lastBinding.start == 0 and lastBinding.finish == 0 then
			ctx.exportTableLocalId = lastId
			return
		end
		ctx.bindings[ctx.exportTableLocalId] = {
			name = expSym,
			start = 0,
			finish = 0,
			annotation = 0,
			shadow = 0,
			functionDepth = 0,
			loopDepth = 0,
			scopeDepth = 1,
			isConst = true,
			isExported = false,
		}
	end

	local function makeEmptyExports()
		return {
			exportedClasses = {} :: { [number]: number },
			exportedFunctions = {} :: { [number]: boolean },
			exportedVariables = {} :: { number },
			exportedTableCid = -1,
			hasExports = false,
			hasTypeExports = false,
			hasModuleReturn = false,
		}
	end

	local sharedCompilerCtx: CompilerCtx? = nil
	local compilerCtxBusy = false
	local DUMMY_EMPTY: any = table.freeze({})

	local function createCompilerCtx(
		bytecode: BytecodeBuilder.BytecodeBuilderImpl,
		parseResult: any,
		inputOptions: CompileOptions?
	): CompilerCtx
		local arena: Arena.ArenaImpl = parseResult.arena
		local lineStarts = parseResult.lineStarts
		if not (parseResult :: any).lineStartsComplete then
			if table.isfrozen(parseResult) or table.isfrozen(lineStarts) then
				lineStarts = table.clone(lineStarts)
				local lineCount = #lineStarts
				local source = parseResult.source
				local cursor = lineStarts[lineCount] + 1
				while true do
					local at = string.find(source, "\n", cursor, true)
					if not at then
						break
					end
					lineCount += 1
					lineStarts[lineCount] = at
					cursor = at + 1
				end
			else
				parseResult:position(0)
				lineStarts = parseResult.lineStarts
			end
		end
		local opts, flags, mainFlags, optLevel, dbgLevel, tiLevel, covLevel, vecPrec =
			initCompilerOptionsAndFlags(bytecode, parseResult, inputOptions)
		local arenaSymbolMap = (arena :: any).symbolMap :: { [string]: number }?
		local symbolByName: { [string]: number }
		if arenaSymbolMap ~= nil then
			symbolByName = arenaSymbolMap
		else
			symbolByName = {}
			for idx, str in arena.symbols do
				symbolByName[str] = idx
			end
		end
		local rootId = parseResult.root
		opts.optimizationLevel, opts.debugLevel, opts.typeInfoLevel, opts.coverageLevel =
			optLevel, dbgLevel, tiLevel, covLevel
		local useExports = flags.LuauExportValueSyntax == true
		local allocExports = useExports
			or flags.LuauOptimizeExportTable == true
			or flags.LuauExportedTypesParticipateInScc == true
			or flags.DebugLuauUserDefinedClasses == true
		local bindings = if useExports then table.clone(arena.bindings) else arena.bindings
		local symbols = if useExports then table.clone(arena.symbols) else arena.symbols
		if useExports and arenaSymbolMap ~= nil then
			symbolByName = table.clone(arenaSymbolMap)
			arenaSymbolMap = nil
		end
		local origNodeCount = #arena.nodes
		local origBindingCount = #bindings
		local origSymbolCount = #symbols
		local nLocals = origBindingCount + 1
		local exportTableLocalId = if useExports then nLocals else 0
		local recordDebug = dbgLevel >= 2 or tiLevel >= 1
		local ctx: CompilerCtx
		if not compilerCtxBusy and sharedCompilerCtx ~= nil then
			compilerCtxBusy = true
			ctx = sharedCompilerCtx
			ctx.bytecode = bytecode
			ctx.arena = arena
			ctx.arenaSymbolMap = arenaSymbolMap
			ctx.origNodeCount = origNodeCount
			ctx.origBindingCount = origBindingCount
			ctx.origSymbolCount = origSymbolCount
			ctx.nodes = arena.nodes
			ctx.kinds = arena.kinds
			ctx.starts = arena.starts
			ctx.finishes = arena.finishes
			ctx.listFirsts = arena.listFirsts
			ctx.listCounts = arena.listCounts
			ctx.listValues = arena.listValues
			ctx.bindings = bindings
			ctx.symbols = symbols
			ctx.symbolByName = symbolByName
			ctx.lineStarts = lineStarts
			ctx.lastLineIdx = 1
			ctx.lastLineStart = lineStarts[1] or 0
			ctx.lastLineEnd = lineStarts[2] or math.huge
			ctx.lastLineNum = 1
			ctx.opts = opts
			ctx.optimizationLevel = optLevel
			ctx.debugLevel = dbgLevel
			ctx.typeInfoLevel = tiLevel
			ctx.recordDebug = recordDebug
			ctx.coverageLevel = covLevel
			ctx.vectorPrecision = vecPrec
			ctx.flags = flags
			ctx.flagExpIfLocal = flags.LuauExperimentalIfLocalSyntax == true
			ctx.flagExpWhileLocal = flags.LuauExperimentalWhileLocalSyntax == true
			ctx.flagDebugClasses = flags.DebugLuauUserDefinedClasses == true
			ctx.mainFlags = mainFlags
			ctx.rootId = rootId
			ctx.getfenvUsed = false
			ctx.setfenvUsed = false
			ctx.hasTypeAliases = false
			ctx.hasClasses = false
			ctx.trialDepth = 0
			ctx.builtinsFold = nil
			ctx.builtinsFoldLibraryK = nil
			ctx.inlineBuiltinTop = 0
			ctx.inlineArgTop = 0
			ctx.exportTableLocalId = exportTableLocalId
			ctx.exports = if allocExports then makeEmptyExports() else EMPTY_EXPORTS
			ctx.regTop = 0
			ctx.stackSize = 0
			ctx.argCount = 0
			ctx.hasLoops = false
			ctx.hasMultiRet = false
			ctx.hasRequire = false
			ctx.currentFunctionId = 0
			ctx.currentFunctionNode = nil
			ctx.blockDepth = 0
			ctx.activeLocals = 0
			ctx.currClasses = nil
			ctx.loopJumpCount = 0
			ctx.loopDepth = 0
			ctx.scratchTableShape.length = 0
			ctx.scratchTableShape.hasConstants = false
			ctx.freeCount = 0
			ctx.curBlockOwner = 0
			ctx.curBlockBase = 0
			ctx.curBlockMinFinish = math.huge
			ctx.blockLiveCount = 0
		else
			if not compilerCtxBusy then
				compilerCtxBusy = true
			end
			local newCtx: CompilerCtx = {
				bytecode = bytecode,
				arena = arena,
				arenaSymbolMap = arenaSymbolMap,
				origNodeCount = origNodeCount,
				origBindingCount = origBindingCount,
				origSymbolCount = origSymbolCount,
				nodes = arena.nodes,
				kinds = arena.kinds,
				starts = arena.starts,
				finishes = arena.finishes,
				listFirsts = arena.listFirsts,
				listCounts = arena.listCounts,
				listValues = arena.listValues,
				bindings = bindings,
				symbols = symbols,
				symbolByName = symbolByName,
				symbolHashes = {},
				symbolStrRefs = {},
				lineStarts = lineStarts,
				lastLineIdx = 1,
				lastLineStart = lineStarts[1] or 0,
				lastLineEnd = lineStarts[2] or math.huge,
				lastLineNum = 1,
				opts = opts,
				optimizationLevel = optLevel,
				debugLevel = dbgLevel,
				typeInfoLevel = tiLevel,
				recordDebug = recordDebug,
				coverageLevel = covLevel,
				vectorPrecision = vecPrec,
				flags = flags,
				flagExpIfLocal = flags.LuauExperimentalIfLocalSyntax == true,
				flagExpWhileLocal = flags.LuauExperimentalWhileLocalSyntax == true,
				flagDebugClasses = flags.DebugLuauUserDefinedClasses == true,
				mainFlags = mainFlags,
				rootId = rootId,
				getfenvUsed = false,
				setfenvUsed = false,
				hasTypeAliases = false,
				hasClasses = false,
				funcHasCalls = {},
				funcReadTableLocal = {},
				alwaysTermCache = {},
				trialDepth = 0,
				functions = {},
				localReg = table.create(nLocals) :: { [number]: number },
				localAllocated = table.create(nLocals) :: { [number]: boolean },
				localCaptured = table.create(nLocals) :: { [number]: boolean },
				localReused = table.create(nLocals) :: { [number]: boolean },
				localDebugPc = table.create(nLocals) :: { [number]: number },
				localAllocPc = table.create(nLocals) :: { [number]: number },
				globals = {},
				vars = CompilerFolding.createVariables(origBindingCount),
				constants = {},
				locstants = table.create(origBindingCount) :: { [number]: CompilerBuiltins.Constant },
				tableConstants = {},
				tableShapes = {},
				builtins = {},
				builtinsFold = nil,
				builtinsFoldLibraryK = nil,
				userdataTypes = {},
				functionTypes = {},
				localTypes = table.create(nLocals) :: { [number]: number },
				exprTypes = {},
				inlineBuiltins = {},
				inlineBuiltinKeys = {},
				inlineBuiltinOldVals = {},
				inlineBuiltinTop = 0,
				inlineArgLocalIds = {},
				inlineArgRegs = {},
				inlineArgAllocPcs = {},
				inlineArgInits = {},
				inlineArgValues = {},
				inlineArgTop = 0,
				inlineFramePool = {},
				exprChanges = CompilerFolding.createChangeStack(false),
				localChanges = CompilerFolding.createChangeStack(true),
				exportTableLocalId = exportTableLocalId,
				exports = if allocExports then makeEmptyExports() else EMPTY_EXPORTS,
				regTop = 0,
				stackSize = 0,
				argCount = 0,
				hasLoops = false,
				hasMultiRet = false,
				hasRequire = false,
				currentFunctionId = 0,
				currentFunctionNode = nil,
				blockDepth = 0,
				localStack = {},
				regCaptured = {},
				activeLocals = 0,
				upvals = {},
				upvalMap = {},
				enclosingClasses = {},
				classPrivateFieldOffsets = {},
				currClasses = nil,
				inlineVarc = { false, false, false, false, false, false, false, false },
				loopJumpTypes = {},
				loopJumpLabels = {},
				loopJumpCount = 0,
				loopLocalOffsets = {},
				loopLocalOffsetsContinue = {},
				loopContinueUsed = {},
				loopDepth = 0,
				inlineFrames = {},
				captureTypes = {},
				captureData = {},
				jumpListPool = {},
				keyValMapPool = {},
				concatPool = {},
				assignScratchPool = {},
				scratchKeyValOrder = {},
				scratchTableShape = {
					keys = table.create(32, 0),
					constants = table.create(32, -1),
					length = 0,
					hasConstants = false,
				},
				localUses = {},
				freeCount = 0,
				freeRegs = {},
				freeAstLocals = {},
				freeDebugPcs = {},
				freeAllocPcs = {},
				freeIsArgs = {},
				curBlockOwner = 0,
				curBlockBase = 0,
				curBlockMinFinish = math.huge,
				blockLiveCount = 0,
				blockLiveLocalIds = {},
				blockLiveStackIdx = {},
				blockLiveFinishes = {},
			}
			if sharedCompilerCtx == nil then
				sharedCompilerCtx = newCtx
			end
			ctx = newCtx
		end
		if useExports then
			initExportTableBinding(ctx)
		end
		return ctx
	end

	local function releaseCompilerCtx(ctx: CompilerCtx)
		if ctx ~= sharedCompilerCtx then
			return
		end
		ctx.currentFunctionId = 0
		ctx.currentFunctionNode = nil
		if next(ctx.symbolHashes) ~= nil then
			table.clear(ctx.symbolHashes)
		end
		if next(ctx.symbolStrRefs) ~= nil then
			table.clear(ctx.symbolStrRefs)
		end
		if next(ctx.funcHasCalls) ~= nil then
			table.clear(ctx.funcHasCalls)
		end
		if next(ctx.funcReadTableLocal) ~= nil then
			table.clear(ctx.funcReadTableLocal)
		end
		if next(ctx.alwaysTermCache) ~= nil then
			table.clear(ctx.alwaysTermCache)
		end
		table.clear(ctx.functions)
		table.clear(ctx.localReg)
		table.clear(ctx.localAllocated)
		if next(ctx.localCaptured) ~= nil then
			table.clear(ctx.localCaptured)
		end
		if next(ctx.localReused) ~= nil then
			table.clear(ctx.localReused)
		end
		if next(ctx.localDebugPc) ~= nil then
			table.clear(ctx.localDebugPc)
		end
		if next(ctx.localAllocPc) ~= nil then
			table.clear(ctx.localAllocPc)
		end
		if next(ctx.globals) ~= nil then
			table.clear(ctx.globals)
		end
		CompilerFolding.clearVariables(ctx.vars)
		if next(ctx.constants) ~= nil then
			table.clear(ctx.constants)
		end
		if next(ctx.locstants) ~= nil then
			table.clear(ctx.locstants)
		end
		if next(ctx.tableConstants) ~= nil then
			table.clear(ctx.tableConstants)
		end
		if next(ctx.tableShapes) ~= nil then
			table.clear(ctx.tableShapes)
		end
		if next(ctx.builtins) ~= nil then
			table.clear(ctx.builtins)
		end
		if next(ctx.userdataTypes) ~= nil then
			table.clear(ctx.userdataTypes)
		end
		if next(ctx.functionTypes) ~= nil then
			table.clear(ctx.functionTypes)
		end
		if next(ctx.localTypes) ~= nil then
			table.clear(ctx.localTypes)
		end
		if next(ctx.exprTypes) ~= nil then
			table.clear(ctx.exprTypes)
		end
		if next(ctx.inlineBuiltins) ~= nil then
			table.clear(ctx.inlineBuiltins)
		end
		if #ctx.inlineBuiltinKeys > 0 then
			table.clear(ctx.inlineBuiltinKeys)
			table.clear(ctx.inlineBuiltinOldVals)
		end
		if #ctx.inlineArgLocalIds > 0 then
			table.clear(ctx.inlineArgLocalIds)
			table.clear(ctx.inlineArgRegs)
			table.clear(ctx.inlineArgAllocPcs)
			table.clear(ctx.inlineArgInits)
			table.clear(ctx.inlineArgValues)
		end
		if #ctx.inlineFramePool > 0 then
			table.clear(ctx.inlineFramePool)
		end
		ctx.exprChanges.top = 0
		if #ctx.exprChanges.keys > 0 then
			table.clear(ctx.exprChanges.keys)
			table.clear(ctx.exprChanges.prevs)
		end
		ctx.localChanges.top = 0
		if #ctx.localChanges.keys > 0 then
			table.clear(ctx.localChanges.keys)
			table.clear(ctx.localChanges.prevs)
			if ctx.localChanges.prevConsts then
				table.clear(ctx.localChanges.prevConsts)
			end
		end
		if #ctx.localStack > 0 then
			table.clear(ctx.localStack)
		end
		if next(ctx.regCaptured) ~= nil then
			table.clear(ctx.regCaptured)
		end
		if #ctx.upvals > 0 then
			table.clear(ctx.upvals)
		end
		if next(ctx.upvalMap) ~= nil then
			table.clear(ctx.upvalMap)
		end
		if next(ctx.enclosingClasses) ~= nil then
			table.clear(ctx.enclosingClasses)
		end
		if next(ctx.classPrivateFieldOffsets) ~= nil then
			table.clear(ctx.classPrivateFieldOffsets)
		end
		if #ctx.loopJumpTypes > 0 then
			table.clear(ctx.loopJumpTypes)
			table.clear(ctx.loopJumpLabels)
		end
		if #ctx.loopLocalOffsets > 0 then
			table.clear(ctx.loopLocalOffsets)
			table.clear(ctx.loopLocalOffsetsContinue)
			table.clear(ctx.loopContinueUsed)
		end
		if #ctx.inlineFrames > 0 then
			table.clear(ctx.inlineFrames)
		end
		if #ctx.captureTypes > 0 then
			table.clear(ctx.captureTypes)
			table.clear(ctx.captureData)
		end
		if #ctx.jumpListPool > 0 then
			table.clear(ctx.jumpListPool)
		end
		if #ctx.keyValMapPool > 0 then
			table.clear(ctx.keyValMapPool)
		end
		if #ctx.concatPool > 0 then
			table.clear(ctx.concatPool)
		end
		if #ctx.assignScratchPool > 0 then
			table.clear(ctx.assignScratchPool)
		end
		if #ctx.scratchKeyValOrder > 0 then
			table.clear(ctx.scratchKeyValOrder)
		end
		if next(ctx.localUses) ~= nil then
			table.clear(ctx.localUses)
		end
		if #ctx.freeRegs > 0 then
			table.clear(ctx.freeRegs)
			table.clear(ctx.freeAstLocals)
			table.clear(ctx.freeDebugPcs)
			table.clear(ctx.freeAllocPcs)
			table.clear(ctx.freeIsArgs)
		end
		if #ctx.blockLiveLocalIds > 0 then
			table.clear(ctx.blockLiveLocalIds)
			table.clear(ctx.blockLiveStackIdx)
			table.clear(ctx.blockLiveFinishes)
		end
		ctx.exports = EMPTY_EXPORTS
		ctx.currClasses = nil
		ctx.builtinsFold = nil
		ctx.builtinsFoldLibraryK = nil
		ctx.arenaSymbolMap = nil
		ctx.bytecode = DUMMY_EMPTY
		ctx.arena = DUMMY_EMPTY
		ctx.nodes = DUMMY_EMPTY
		ctx.kinds = DUMMY_EMPTY
		ctx.starts = DUMMY_EMPTY
		ctx.finishes = DUMMY_EMPTY
		ctx.listFirsts = DUMMY_EMPTY
		ctx.listCounts = DUMMY_EMPTY
		ctx.listValues = DUMMY_EMPTY
		ctx.bindings = DUMMY_EMPTY
		ctx.symbols = DUMMY_EMPTY
		ctx.symbolByName = DUMMY_EMPTY
		ctx.lineStarts = DUMMY_EMPTY
		ctx.opts = DUMMY_EMPTY
		ctx.flags = DUMMY_EMPTY
		compilerCtxBusy = false
	end

	local function configureBuiltinsFold(ctx: CompilerCtx)
		if ctx.optimizationLevel >= 2 and not ctx.getfenvUsed and not ctx.setfenvUsed then
			ctx.builtinsFold = ctx.builtins
			local mathSym = ctx.symbolByName["math"]
			local foldLibraryK = mathSym ~= nil
				and CompilerBuiltins.getGlobalState(ctx.globals, mathSym) == CompilerBuiltins.GlobalState.Default
			if not foldLibraryK and ctx.opts.librariesWithKnownMembers then
				for _, libName in ctx.opts.librariesWithKnownMembers do
					local sym = ctx.symbolByName[libName]
					if
						sym
						and CompilerBuiltins.getGlobalState(ctx.globals, sym)
							== CompilerBuiltins.GlobalState.Default
					then
						foldLibraryK = true
						break
					end
				end
			end
			ctx.builtinsFoldLibraryK = foldLibraryK
		end
	end

	local function runPrepassAnalyses(ctx: CompilerCtx, rootNode: any): { number }
		local trackExports = ctx.flags.LuauOptimizeExportTable
		local doO1 = ctx.optimizationLevel >= 1

		local function runTrack(enableO1: boolean): ({ number }, boolean)
			CompilerFolding.assignMutable(ctx.globals, ctx.symbolByName, ctx.opts.mutableGlobals)
			local funcNodeIds, hasNativeFunction, getfenvUsed, setfenvUsed, hasTypeAliases, funcHasCalls, hasClasses =
				CompilerFolding.trackValuesAndAnalyzeO1(
					ctx.arena,
					ctx.globals,
					ctx.vars,
					if trackExports then ctx.exports.exportedFunctions else nil,
					if trackExports then ctx.exports.exportedVariables else nil,
					ctx.rootId,
					ctx.flags,
					ctx.symbolByName,
					enableO1,
					ctx.builtins,
					ctx.tableConstants,
					ctx.tableShapes,
					ctx.opts
				)
			ctx.hasTypeAliases = hasTypeAliases
			ctx.hasClasses = hasClasses
			ctx.funcHasCalls = funcHasCalls
			if enableO1 then
				ctx.getfenvUsed = getfenvUsed
				ctx.setfenvUsed = setfenvUsed
			end
			return funcNodeIds, hasNativeFunction
		end

		local funcNodeIds, hasNativeFunction = runTrack(doO1)
		if hasNativeFunction then
			ctx.optimizationLevel = 2
			ctx.typeInfoLevel = 1
			ctx.recordDebug = true
			ctx.opts.optimizationLevel = 2
			ctx.opts.typeInfoLevel = 1
			if not doO1 then
				table.clear(ctx.globals)
				CompilerFolding.clearVariables(ctx.vars)
				if trackExports then
					table.clear(ctx.exports.exportedFunctions)
					table.clear(ctx.exports.exportedVariables)
				end
				funcNodeIds = runTrack(true)
			end
		end

		configureBuiltinsFold(ctx)

		if ctx.optimizationLevel >= 1 then
			CompilerFolding.foldConstants(
				ctx.arena,
				ctx.constants,
				ctx.vars,
				ctx.locstants,
				ctx.builtinsFold,
				ctx.builtinsFoldLibraryK,
				ctx.vectorPrecision == 1,
				ctx.opts.libraryMemberConstantCb,
				ctx.rootId,
				ctx.tableConstants,
				ctx.flags,
				nil,
				nil,
				ctx.funcReadTableLocal,
				ctx.globals
			)
		end

		if ctx.opts.userdataTypes then
			if #ctx.opts.userdataTypes > (Types.LBC_TYPE_TAGGED_USERDATA_END - Types.LBC_TYPE_TAGGED_USERDATA_BASE) then
				raiseCompileError(
					ctx,
					rootNode.start,
					rootNode.finish,
					"Exceeded userdata type limit in the compilation options"
				)
			end
			for _, udName in ctx.opts.userdataTypes do
				if ctx.symbolByName[udName] then
					ctx.userdataTypes[udName] = ctx.bytecode:addUserdataType(udName)
				end
			end
		end

		-- Parser populates arena.hasTypeAnnotations; typeInfoLevel == 0 skips annotation work inside CompilerTypes when false.
		if ctx.typeInfoLevel >= 1 or ctx.optimizationLevel >= 2 then
			getCompilerTypes().buildTypeMap(
				ctx.arena,
				ctx.functionTypes,
				ctx.localTypes,
				ctx.exprTypes,
				ctx.rootId,
				ctx.opts.vectorType,
				ctx.userdataTypes,
				ctx.builtins,
				ctx.globals,
				ctx.opts.libraryMemberTypeCb,
				ctx.bytecode,
				ctx.flags,
				ctx.hasTypeAliases,
				ctx.symbolByName
			)
		end

		return funcNodeIds
	end

	local function runCompilePipeline(ctx: CompilerCtx, bytecode: any): any
		local rootNode = ctx.nodes[ctx.rootId]
		local funcNodeIds = runPrepassAnalyses(ctx, rootNode)
		if ctx.flagDebugClasses and (ctx.arena.hasClasses or ctx.hasClasses) then
			getCompilerClass().runClassVisitor(ctx, ctx.rootId)
		end

		for _, exprId in funcNodeIds do
			if ctx.flagDebugClasses then
				ctx.currClasses = ctx.enclosingClasses[exprId]
			end
			local _, protoflags = compileFunction(ctx, exprId, 0)
			if ctx.flagDebugClasses then
				ctx.currClasses = nil
			end
			if
				bit32.band(protoflags, ProtoFlags.LPF_NATIVE_FUNCTION) ~= 0
				and bit32.band(ctx.mainFlags, ProtoFlags.LPF_NATIVE_MODULE) == 0
			then
				ctx.mainFlags = bit32.bor(ctx.mainFlags, ProtoFlags.LPF_NATIVE_FUNCTION)
			end
		end

		local mainNodeId = #ctx.nodes + 1
		local mainNode = {
			kind = K.AstExprFunction,
			start = rootNode.start,
			finish = rootNode.finish,
			attributes = 0,
			generics = 0,
			genericPacks = 0,
			self = 0,
			args = 0,
			vararg = true,
			varargLocation = nil,
			varargAnnotation = 0,
			body = ctx.rootId,
			functionDepth = 0,
			debugname = 0,
			returnAnnotation = 0,
		}

		local mainid, _ = compileFunction(ctx, mainNodeId, ctx.mainFlags, mainNode)
		local mainf = ctx.functions[mainNodeId]
		assert(mainf and #mainf.upvals == 0, "main function cannot have upvalues")

		bytecode:setMainFunction(mainid)
		bytecode:finalize()
		return nil
	end

	local function checkParseResultError(parseResult: any): any?
		if
			type(parseResult) ~= "table"
			or type(parseResult.arena) ~= "table"
			or type(parseResult.arena.nodes) ~= "table"
		then
			return {
				status = "parseError",
				line = 1,
				start = 0,
				finish = 0,
				message = "Invalid ParseResult",
			}
		end
		if type(parseResult.diagnostics) == "table" and #parseResult.diagnostics > 0 then
			local firstDiag = parseResult.diagnostics[1]
			local line = parseResult:position(firstDiag.start)
			return {
				status = "parseError",
				line = line + 1,
				start = firstDiag.start,
				finish = firstDiag.finish,
				message = firstDiag.message,
			}
		end
		if parseResult.status == "cancelled" then
			return {
				status = "parseError",
				line = 1,
				start = 0,
				finish = 0,
				message = "Parse cancelled",
			}
		end
		if parseResult.status ~= "ok" or parseResult.root == nil or parseResult.root == 0 then
			return {
				status = "parseError",
				line = 1,
				start = 0,
				finish = 0,
				message = "Parse failed without AST root",
			}
		end
		local rootNode = parseResult.arena.nodes[parseResult.root]
		if not rootNode or rootNode.kind ~= K.AstStatBlock then
			return {
				status = "parseError",
				line = 1,
				start = if rootNode then rootNode.start or 0 else 0,
				finish = if rootNode then rootNode.finish or 0 else 0,
				message = "Compile requires a chunk ParseResult with an AstStatBlock root",
			}
		end
		return nil
	end

	--- Compiles source code or a parsed AST into `bytecode`, raising a structured error table on failure.
	local function compileOrThrow(
		bytecode: any,
		sourceOrParseResult: any,
		inputOptions: CompileOptions?,
		applyDump: boolean?
	): any
		local resolvedParseOpts = if inputOptions then inputOptions.parseOptions else nil
		local parseResult: any = if type(sourceOrParseResult) == "string"
			then parseSourceFast(sourceOrParseResult, resolvedParseOpts)
			else sourceOrParseResult
		local parseErr = checkParseResultError(parseResult)
		if parseErr ~= nil then
			error({
				compileError = true,
				line = parseErr.line,
				start = parseErr.start,
				finish = parseErr.finish,
				message = parseErr.message,
			}, 0)
		end

		local customFlags = if inputOptions then inputOptions.flags else nil
		local hasCustomFlags = customFlags ~= nil
		local origBFlags = bytecode.flags
		local customKeys = bytecode.customFlagKeys
		local hasBuilderOverrides = customKeys ~= nil
			or (origBFlags ~= CompilerFlags and origBFlags ~= BytecodeDefs.CompilerFlags)
		ensureDefaultProfileFlags()
		if not hasBuilderOverrides and parseResult.flags == upstreamProfileFlags and not hasCustomFlags then
			bytecode.flags = defaultUpstreamFlags
		elseif not hasBuilderOverrides and parseResult.flags == studioProfileFlags and not hasCustomFlags then
			bytecode.flags = defaultStudioFlags
		else
			local bflags = table.clone(CompilerFlags :: { [string]: any })
			if parseResult.flags then
				for k, v in parseResult.flags :: { [string]: any } do
					bflags[k] = v
				end
			end
			if customKeys ~= nil then
				for k in customKeys do
					bflags[k] = origBFlags[k]
				end
			elseif hasBuilderOverrides then
				local bcbDefaults = BytecodeDefs.CompilerFlags :: { [string]: any }
				for k, v in origBFlags :: { [string]: any } do
					if v ~= bcbDefaults[k] then
						bflags[k] = v
					end
				end
			end
			if customFlags then
				for k, v in customFlags do
					bflags[k] = v
				end
			end
			bytecode.flags = bflags
		end
		if applyDump ~= false and inputOptions and inputOptions.dumpFlags then
			bytecode:setDumpFlags(inputOptions.dumpFlags)
			if
				bit32.btest(
					inputOptions.dumpFlags,
					bit32.bor(BytecodeBuilder.DumpFlags.Source, BytecodeBuilder.DumpFlags.Remarks)
				)
			then
				bytecode:setDumpSource(parseResult.source)
			end
		end

		local ctx = createCompilerCtx(bytecode, parseResult, inputOptions)
		local ok, err = pcall(runCompilePipeline, ctx, bytecode)
		if CompilerTypesMod ~= nil then
			CompilerTypesMod.releaseTypeScratch()
			CompilerTypesMod.releaseCostScratch()
		end
		CompilerFolding.releaseFoldScratch()
		releaseCompilerCtx(ctx)
		if not ok then
			error(err, 0)
		end
		return nil
	end

	local function formatError(line: number, msg: string): string
		return string.format(":%d: %s", line, msg)
	end

	local RESULT_BCB_OPTS = table.freeze({ serializeBytes = true, retainProto = false })
	local RESULT_ENCODED_BCB_OPTS = table.freeze({ serializeBytes = true, retainProto = true })
	local PROTO_BCB_OPTS = table.freeze({ serializeBytes = false, retainProto = true })

	local function compileWith(
		sourceOrParseResult: string | PublicTypes.ParseResult,
		compileOpts: CompileOptions?,
		bcbOpts: any?,
		skipValidate: boolean?
	): (boolean, any, any, PublicTypes.ParseResult)
		if not skipValidate then
			validateSourceOrParseResult(sourceOrParseResult)
			validateCompileOptions(compileOpts)
		end
		local resolvedParseOpts = if compileOpts then compileOpts.parseOptions else nil
		local resolvedEncoder = if compileOpts and bcbOpts ~= PROTO_BCB_OPTS then compileOpts.encoder else nil
		local parseResult: PublicTypes.ParseResult = if type(sourceOrParseResult) == "string"
			then parseSourceFast(sourceOrParseResult, resolvedParseOpts)
			else sourceOrParseResult
		local parseErr = checkParseResultError(parseResult)
		if parseErr ~= nil then
			return false, nil, parseErr, parseResult
		end

		local applyDump = bcbOpts == RESULT_BCB_OPTS or bcbOpts == RESULT_ENCODED_BCB_OPTS
		local bcb = BytecodeBuilder.new(resolvedEncoder, nil, bcbOpts)
		local ok, err = pcall(compileOrThrow, bcb, parseResult, compileOpts, applyDump)
		if not ok then
			local errObj = err :: any
			if type(errObj) == "table" and errObj.compileError then
				return false, nil, errObj, parseResult
			end
			error(err, 0)
		end
		return true, bcb, nil, parseResult
	end

	--- Compiles Luau source code or a parsed AST into a serialized bytecode string, returning `(bytecode, nil)` or `(nil, err)`.
	function compile(
		sourceOrParseResult: string | PublicTypes.ParseResult,
		compileOpts: CompileOptions?
	): (string?, string?)
		local ok, bcb, errObj = compileWith(sourceOrParseResult, compileOpts, nil)
		if not ok then
			return nil, formatError(errObj.line, errObj.message)
		end
		return bcb:getBytecode(), nil
	end

	--- Compiles Luau source code and returns a structured result with bytecode, diagnostics, and builder state.
	function compileResult(
		sourceOrParseResult: string | PublicTypes.ParseResult,
		compileOpts: CompileOptions?
	): CompileResult
		local bcbOpts = if compileOpts ~= nil and compileOpts.encoder ~= nil
			then RESULT_ENCODED_BCB_OPTS
			else RESULT_BCB_OPTS
		local ok, bcb, errObj, parseResult = compileWith(sourceOrParseResult, compileOpts, bcbOpts)
		if not ok then
			local errMsg = formatError(errObj.line, errObj.message)
			if errObj.status == "parseError" then
				local diags = if type(parseResult) == "table"
						and type((parseResult :: any).diagnostics) == "table"
						and #(parseResult :: any).diagnostics > 0
					then (parseResult :: any).diagnostics
					else {
						{
							start = errObj.start,
							finish = errObj.finish,
							message = errObj.message,
							code = if type(parseResult) == "table" and (parseResult :: any).status == "limit"
								then "limit"
								else "syntax",
						},
					}
				return {
					status = "parseError",
					bytecode = BytecodeCodec.encodeError(errMsg),
					error = errMsg,
					diagnostics = diags,
					parseResult = parseResult,
				}
			end
			return {
				status = "compileError",
				bytecode = BytecodeCodec.encodeError(errMsg),
				error = errMsg,
				diagnostics = {
					{
						start = errObj.start,
						finish = errObj.finish,
						message = errObj.message,
						code = "compile",
					},
				},
				parseResult = parseResult,
			}
		end

		return {
			status = "ok",
			bytecode = bcb:getBytecode(),
			builder = (bcb :: any) :: PublicTypes.BytecodeBuilder,
			diagnostics = {},
			parseResult = parseResult,
		}
	end

	--- Compiles Luau source code or a parsed AST directly into an in-memory `ProtoModule` without binary serialization.
	function compileProto(
		sourceOrParseResult: string | PublicTypes.ParseResult,
		compileOpts: CompileOptions?
	): (PublicTypes.ProtoModule?, string?)
		validateSourceOrParseResult(sourceOrParseResult)
		validateCompileOptions(compileOpts)
		if compileOpts ~= nil and compileOpts.encoder ~= nil then
			error(
				"Invalid CompileOptions.encoder: compileProto returns canonical ProtoModule IR; use compile() for encoded binary bytecode",
				0
			)
		end
		local ok, bcb, errObj = compileWith(sourceOrParseResult, compileOpts, PROTO_BCB_OPTS, true)
		if not ok then
			return nil, formatError(errObj.line, errObj.message)
		end
		return bcb:toProtoModule(), nil
	end
end

return table.freeze({
	CompilerFlags = CompilerFlags,
	compile = compile,
	compileResult = compileResult,
	compileProto = compileProto,
})
