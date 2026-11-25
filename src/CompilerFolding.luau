--!strict
-- Luau 0.748 ValueTracking, ConstantFolding, TableShape, and Utils port.
-- Upstream Luau is MIT licensed; see ../LICENSE.md and ../UPSTREAM.json.
local Arena = require("./Arena")
local BytecodeDefs = require("./BytecodeDefs")
local CompilerBuiltins = require("./CompilerBuiltins")

local K = Arena.Kinds
local Builtins = BytecodeDefs.Builtins
local ConstantType = CompilerBuiltins.ConstantType
local GlobalState = CompilerBuiltins.GlobalState
local roundf = CompilerBuiltins.roundf
local analyzeCallBuiltin = CompilerBuiltins.analyzeCallBuiltin

export type TableConstVal = CompilerBuiltins.TableConstVal

export type VariableTable = {
	init: { [number]: number },
	owner: { [number]: number },
	lastUsed: { [number]: number },
	written: { [number]: boolean },
	constant: { [number]: boolean },
	nonLexicalUse: { [number]: boolean },
}

export type TableShapePrediction = {
	arraySize: number,
	hashSize: number,
}

export type ChangeStack = {
	keys: { number },
	prevTypes: { number },
	prevVals: { any },
	prevConsts: { boolean }?,
	top: number,
}

local function createVariables(bindingCount: number): VariableTable
	return {
		init = table.create(bindingCount) :: { [number]: number },
		owner = table.create(bindingCount) :: { [number]: number },
		lastUsed = table.create(bindingCount) :: { [number]: number },
		written = table.create(bindingCount) :: { [number]: boolean },
		constant = table.create(bindingCount) :: { [number]: boolean },
		nonLexicalUse = table.create(bindingCount) :: { [number]: boolean },
	}
end

local function clearVariables(vars: VariableTable)
	table.clear(vars.init)
	table.clear(vars.owner)
	table.clear(vars.lastUsed)
	table.clear(vars.written)
	table.clear(vars.constant)
	table.clear(vars.nonLexicalUse)
end

local function createChangeStack(withConsts: boolean): ChangeStack
	return {
		keys = {},
		prevTypes = {},
		prevVals = {},
		prevConsts = if withConsts then {} else nil,
		top = 0,
	}
end

local TableConstantKind = table.freeze({
	NotConstant = 0,
	ConstantTable = 1,
})

@native
local function isTruthfulVal(ct: number, cv: any): boolean
	assert(ct ~= ConstantType.Unknown, "expected known constant")
	return ct ~= ConstantType.Nil and not (ct == ConstantType.Boolean and cv == false)
end

@native
local function isConstantTrue(constTypes: { [number]: number }, constVals: { [number]: any }, nodeId: number): boolean
	local ct = constTypes[nodeId]
	return ct ~= nil and ct ~= ConstantType.Unknown and isTruthfulVal(ct, constVals[nodeId])
end

@native
local function isConstantFalse(constTypes: { [number]: number }, constVals: { [number]: any }, nodeId: number): boolean
	local ct = constTypes[nodeId]
	return ct ~= nil and ct ~= ConstantType.Unknown and not isTruthfulVal(ct, constVals[nodeId])
end

@native
local function alwaysTerminates(
	arena: Arena.ArenaImpl,
	constTypes: { [number]: number },
	constVals: { [number]: any },
	nodeId: number,
	cache: { [number]: boolean }?
): boolean
	if nodeId == 0 then
		return false
	end
	local k = arena.kinds[nodeId]
	if k == K.AstStatReturn or k == K.AstStatBreak or k == K.AstStatContinue then
		return true
	elseif k ~= K.AstStatBlock and k ~= K.AstStatIf then
		return false
	end
	if cache then
		local hit = cache[nodeId]
		if hit ~= nil then
			return hit
		end
	end
	local node = arena.nodes[nodeId]
	if not node then
		return false
	end
	local res = false
	if k == K.AstStatBlock then
		if node.body ~= 0 then
			local first = arena.listFirsts[node.body]
			local count = arena.listCounts[node.body]
			local listValues = arena.listValues
			local kinds = arena.kinds
			for i = 0, count - 1 do
				local statId = listValues[first + i]
				local sk = kinds[statId]
				if sk == K.AstStatReturn or sk == K.AstStatBreak or sk == K.AstStatContinue then
					res = true
					break
				elseif
					(sk == K.AstStatBlock or sk == K.AstStatIf)
					and alwaysTerminates(arena, constTypes, constVals, statId, cache)
				then
					res = true
					break
				end
			end
		end
	else
		local elsebody = node.elsebody
		if elsebody == 0 then
			res = isConstantTrue(constTypes, constVals, node.condition)
				and alwaysTerminates(arena, constTypes, constVals, node.thenbody, cache)
		elseif isConstantTrue(constTypes, constVals, node.condition) then
			res = alwaysTerminates(arena, constTypes, constVals, node.thenbody, cache)
		elseif isConstantFalse(constTypes, constVals, node.condition) then
			res = alwaysTerminates(arena, constTypes, constVals, elsebody, cache)
		else
			res = alwaysTerminates(arena, constTypes, constVals, node.thenbody, cache)
				and alwaysTerminates(arena, constTypes, constVals, elsebody, cache)
		end
	end
	if cache then
		cache[nodeId] = res
	end
	return res
end

@native
local function unwrapExprOfType(arena: Arena.ArenaImpl, nodeId: number, targetKind: number): number
	if nodeId == 0 then
		return 0
	end
	local kinds = arena.kinds
	local k = kinds[nodeId]
	if k == nil then
		return 0
	end
	if k == targetKind then
		return nodeId
	end
	if k ~= K.AstExprGroup and k ~= K.AstExprTypeAssertion then
		return 0
	end
	local nodes = arena.nodes
	local cur = nodes[nodeId].expr
	while cur ~= 0 do
		k = kinds[cur]
		if k == nil then
			return 0
		end
		if k == targetKind then
			return cur
		elseif k == K.AstExprGroup or k == K.AstExprTypeAssertion then
			cur = nodes[cur].expr
		else
			return 0
		end
	end
	return 0
end

local function assignMutable(
	globals: { [number]: number },
	symbolByName: { [string]: number },
	mutableGlobals: { string }?
)
	local g = symbolByName["_G"]
	if g then
		globals[g] = GlobalState.Mutable
	end
	if not mutableGlobals then
		return
	end
	for _, name in mutableGlobals do
		local sym = symbolByName[name]
		if sym then
			globals[sym] = GlobalState.Mutable
		end
	end
end

@native
local function getOrCreateShape(shapes: { [number]: TableShapePrediction }, targetTable: number): TableShapePrediction
	local sh = shapes[targetTable]
	if not sh then
		sh = { arraySize = 0, hashSize = 0 }
		shapes[targetTable] = sh
	end
	return sh
end

@native
local function trackShapeAssign(
	nodes: { [number]: any },
	kinds: { number },
	tables: { [number]: number },
	fields: { [number]: { [number]: boolean } },
	loops: { [number]: number },
	shapes: { [number]: TableShapePrediction },
	varExprId: number
)
	local varKind = kinds[varExprId]
	if varKind == nil then
		return
	end
	if varKind == K.AstExprIndexName then
		local varExpr = nodes[varExprId]
		local innerId = varExpr.expr
		if kinds[innerId] == K.AstExprLocal then
			local targetTable = tables[nodes[innerId]["local"]]
			if targetTable then
				local tfields = fields[targetTable]
				if not tfields then
					tfields = {}
					fields[targetTable] = tfields
				end
				if not tfields[varExpr.index] then
					tfields[varExpr.index] = true
					local sh = getOrCreateShape(shapes, targetTable)
					sh.hashSize += 1
				end
			end
		end
	elseif varKind == K.AstExprIndexExpr then
		local varExpr = nodes[varExprId]
		local innerId = varExpr.expr
		local idxId = varExpr.index
		local idxKind = kinds[idxId]
		if kinds[innerId] == K.AstExprLocal and idxKind ~= nil then
			local targetTable = tables[nodes[innerId]["local"]]
			if targetTable then
				if idxKind == K.AstExprConstantNumber then
					local sh = getOrCreateShape(shapes, targetTable)
					if nodes[idxId].value == sh.arraySize + 1 then
						sh.arraySize += 1
					end
				elseif idxKind == K.AstExprLocal then
					local loopBound = loops[nodes[idxId]["local"]]
					if loopBound then
						local sh = getOrCreateShape(shapes, targetTable)
						if sh.arraySize == 0 then
							sh.arraySize = loopBound
						end
					end
				end
			end
		end
	end
end

type TrackValuesCtx = {
	arena: Arena.ArenaImpl,
	nodes: { [number]: any },
	kinds: { number },
	listFirsts: { number },
	listCounts: { number },
	listValues: { [number]: any },
	bindings: { [number]: any },
	symbols: { string },
	globals: { [number]: number },
	variables: VariableTable,
	varOwner: { [number]: number },
	varLastUsed: { [number]: number },
	varNonLexical: { [number]: boolean },
	exportedFunctions: { [number]: boolean }?,
	exportedVariables: { number }?,
	flags: any,
	checkExported: boolean,
	flagExpIfLocal: boolean,
	flagExpWhileLocal: boolean,
	flagTableFoldFix: boolean,
	currentBlock: number,
	getfenvSym: number?,
	setfenvSym: number?,
	functions: { number },
	hasNativeFunction: boolean,
	getfenvUsed: boolean,
	setfenvUsed: boolean,
	hasTypeAliases: boolean,
	hasClasses: boolean,
	funcHasCalls: { [number]: boolean },
	curFuncHasCalls: boolean,
	doO1: boolean,
	builtins: { [number]: number }?,
	tableConstants: { [number]: number }?,
	shapes: { [number]: TableShapePrediction }?,
	options: any,
	tables: { [number]: number }?,
	fields: { [number]: { [number]: boolean } }?,
	loops: { [number]: number }?,
	tableConstCandidates: { number }?,
	foundBuiltinCalls: { number }?,
	disabledById: any?,
}

@native
local function pushTrackedLocal(ctx: TrackValuesCtx, varId: number, initId: number, ownerId: number)
	local vars = ctx.variables
	vars.init[varId] = initId
	vars.owner[varId] = ownerId
	vars.lastUsed[varId] = 0
end

@native
local function writeTrackedVar(ctx: TrackValuesCtx, nodeId: number)
	local nodes = ctx.nodes
	local kinds = ctx.kinds
	local vars = ctx.variables
	local varOwner = vars.owner
	local varInit = vars.init
	local varWritten = vars.written
	local varLastUsed = vars.lastUsed
	local varNonLexical = vars.nonLexicalUse
	local cur = nodeId
	while cur ~= 0 do
		local k = kinds[cur]
		if k == nil then
			return
		end
		local node = nodes[cur]
		if k == K.AstExprLocal then
			local localId = node["local"]
			if varOwner[localId] == nil then
				varOwner[localId] = 0
				varInit[localId] = 0
			end
			varWritten[localId] = true
			varLastUsed[localId] = cur
			if node.upvalue or ctx.bindings[localId].isExported then
				varNonLexical[localId] = true
			end
			return
		elseif k == K.AstExprGlobal then
			ctx.globals[node.name] = GlobalState.Written
			return
		elseif k == K.AstExprGroup or k == K.AstExprTypeAssertion or k == K.AstExprInstantiate then
			cur = node.expr
		else
			return
		end
	end
end

local visitTrackedStat: (TrackValuesCtx, number) -> ()
local visitTrackedExpr: (TrackValuesCtx, number) -> ()

@native
local function visitTrackedExprList(ctx: TrackValuesCtx, listId: number)
	if listId == 0 then
		return
	end
	local first = ctx.listFirsts[listId]
	local count = ctx.listCounts[listId]
	local listValues = ctx.listValues
	for i = 0, count - 1 do
		visitTrackedExpr(ctx, listValues[first + i])
	end
end

@native
local function markEscaped(ctx: TrackValuesCtx, exprId: number)
	local nodes = ctx.nodes
	local kinds = ctx.kinds
	local tableConstants = ctx.tableConstants :: { [number]: number }
	while exprId ~= 0 do
		local k = kinds[exprId]
		if k == nil then
			return
		end
		if k == K.AstExprLocal then
			tableConstants[nodes[exprId]["local"]] = TableConstantKind.NotConstant
			return
		elseif k == K.AstExprGroup or k == K.AstExprTypeAssertion or k == K.AstExprInstantiate then
			exprId = nodes[exprId].expr
		elseif k == K.AstExprIfElse then
			local node = nodes[exprId]
			markEscaped(ctx, node.trueExpr)
			exprId = node.falseExpr
		elseif k == K.AstExprBinary then
			local node = nodes[exprId]
			local op = node.op
			if op == "And" or op == "Or" then
				markEscaped(ctx, node.left)
				exprId = node.right
			else
				return
			end
		else
			return
		end
	end
end

@native
local function markEscapedTableIndex(ctx: TrackValuesCtx, exprId: number, isLvalueDeprecated: boolean)
	local k = ctx.kinds[exprId]
	if k == nil then
		return
	end
	if k == K.AstExprIndexName then
		markEscaped(ctx, ctx.nodes[exprId].expr)
	elseif k == K.AstExprIndexExpr then
		local node = ctx.nodes[exprId]
		markEscaped(ctx, node.expr)
		if not ctx.flags.LuauCompileTableFoldFix and isLvalueDeprecated then
			markEscaped(ctx, node.index)
		end
	end
end

@native
local function markEscapedBinaryOp(ctx: TrackValuesCtx, lhsId: number, rhsId: number, op: string)
	if
		op == "CompareLt"
		or op == "CompareLe"
		or op == "CompareGt"
		or op == "CompareGe"
		or op == "CompareEq"
		or op == "CompareNe"
		or op == "And"
		or op == "Or"
	then
		return
	end
	markEscaped(ctx, lhsId)
	markEscaped(ctx, rhsId)
end

@native
function visitTrackedExpr(ctx: TrackValuesCtx, nodeId: number)
	if nodeId == 0 then
		return
	end
	local k = ctx.kinds[nodeId]
	if k == nil then
		return
	end
	if k >= K.AstExprConstantNil and k <= K.AstExprConstantString then
		return
	end
	if k == K.AstExprIndexName then
		while k == K.AstExprIndexName do
			nodeId = ctx.nodes[nodeId].expr
			if nodeId == 0 then
				return
			end
			k = ctx.kinds[nodeId]
			if k == nil then
				return
			end
		end
		if k >= K.AstExprConstantNil and k <= K.AstExprConstantString then
			return
		end
	end
	local node = ctx.nodes[nodeId]
	if k == K.AstExprLocal then
		local localId = node["local"]
		if ctx.varOwner[localId] == nil then
			ctx.varOwner[localId] = 0
			ctx.variables.init[localId] = 0
		end
		ctx.varLastUsed[localId] = nodeId
		if node.upvalue or (ctx.checkExported and ctx.bindings[localId].isExported) then
			ctx.varNonLexical[localId] = true
		end
	elseif k == K.AstExprCall then
		ctx.curFuncHasCalls = true
		if ctx.doO1 then
			if node.args ~= 0 then
				local first = ctx.listFirsts[node.args]
				local count = ctx.listCounts[node.args]
				local listValues = ctx.listValues
				for i = 0, count - 1 do
					markEscaped(ctx, listValues[first + i])
				end
			end
			if node.self then
				markEscapedTableIndex(ctx, node.func, false)
			end
		end
		visitTrackedExpr(ctx, node.func)
		visitTrackedExprList(ctx, node.args)
		if ctx.doO1 and not node.self then
			analyzeCallBuiltin(ctx, nodeId, node)
			local builtinsMap = ctx.builtins :: { [number]: number }
			if builtinsMap[nodeId] then
				local fc = ctx.foundBuiltinCalls :: { number }
				fc[#fc + 1] = nodeId
			end
		end
	elseif k == K.AstExprBinary then
		if ctx.doO1 and ctx.flagTableFoldFix then
			markEscapedBinaryOp(ctx, node.left, node.right, node.op)
		end
		visitTrackedExpr(ctx, node.left)
		visitTrackedExpr(ctx, node.right)
	elseif k == K.AstExprIndexExpr then
		if ctx.doO1 and ctx.flagTableFoldFix then
			markEscaped(ctx, node.index)
		end
		visitTrackedExpr(ctx, node.expr)
		visitTrackedExpr(ctx, node.index)
	elseif k == K.AstExprGlobal then
		local name = node.name
		if name == ctx.getfenvSym then
			ctx.getfenvUsed = true
		elseif name == ctx.setfenvSym then
			ctx.setfenvUsed = true
		end
	elseif k == K.AstExprTable then
		if node.items ~= 0 then
			local first = ctx.listFirsts[node.items]
			local count = ctx.listCounts[node.items]
			local listValues = ctx.listValues
			local doO1 = ctx.doO1
			for i = 0, count - 1 do
				local item = listValues[first + i]
				if doO1 then
					if item.key ~= 0 then
						markEscaped(ctx, item.key)
					end
					markEscaped(ctx, item.value)
				end
				if item.key ~= 0 then
					visitTrackedExpr(ctx, item.key)
				end
				visitTrackedExpr(ctx, item.value)
			end
		end
	elseif k == K.AstExprGroup or k == K.AstExprTypeAssertion or k == K.AstExprInstantiate or k == K.AstExprUnary then
		visitTrackedExpr(ctx, node.expr)
	elseif k == K.AstExprFunction then
		local prevHasCalls = ctx.curFuncHasCalls
		ctx.curFuncHasCalls = false
		if node.self and node.self ~= 0 then
			pushTrackedLocal(ctx, node.self, 0, 0)
		end
		if node.args ~= 0 then
			local first = ctx.listFirsts[node.args]
			local count = ctx.listCounts[node.args]
			local listValues = ctx.listValues
			for i = 0, count - 1 do
				pushTrackedLocal(ctx, listValues[first + i], 0, 0)
			end
		end
		visitTrackedStat(ctx, node.body)
		local funcs = ctx.functions
		funcs[#funcs + 1] = nodeId
		local bodyHasCalls = ctx.curFuncHasCalls
		ctx.funcHasCalls[nodeId] = bodyHasCalls
		ctx.curFuncHasCalls = prevHasCalls or bodyHasCalls
		if
			not ctx.hasNativeFunction
			and node.attributes ~= 0
			and Arena.listHasProp(ctx.arena, node.attributes, "type", "Native")
		then
			ctx.hasNativeFunction = true
		end
	elseif k == K.AstExprIfElse then
		visitTrackedExpr(ctx, node.condition)
		if ctx.flags.LuauExperimentalIfLocalSyntax and node.conditionLocal and node.conditionLocal ~= 0 then
			pushTrackedLocal(ctx, node.conditionLocal, node.condition, 0)
			if ctx.doO1 then
				markEscaped(ctx, node.condition)
			end
		end
		visitTrackedExpr(ctx, node.trueExpr)
		visitTrackedExpr(ctx, node.falseExpr)
	elseif k == K.AstExprInterpString or k == K.AstExprError then
		visitTrackedExprList(ctx, node.expressions)
	end
end

@native
local function visitTrackedStatLocal(ctx: TrackValuesCtx, node: any)
	local listFirsts = ctx.listFirsts
	local listCounts = ctx.listCounts
	local listValues = ctx.listValues
	local kinds = ctx.kinds
	if ctx.doO1 and node.vars ~= 0 and node.values ~= 0 then
		if listCounts[node.vars] == 1 and listCounts[node.values] == 1 then
			local nodes = ctx.nodes
			local varId = listValues[listFirsts[node.vars]]
			local valId = listValues[listFirsts[node.values]]
			local valKind = kinds[valId]
			if valKind ~= nil then
				if valKind == K.AstExprTable then
					local valNode = nodes[valId]
					if valNode.items == 0 or listCounts[valNode.items] == 0 then
						(ctx.tables :: { [number]: number })[varId] = valId
					end
				elseif valKind == K.AstExprCall then
					local valNode = nodes[valId]
					if not valNode.self and valNode.args ~= 0 then
						local argsCount = listCounts[valNode.args]
						local funcId = valNode.func
						if
							argsCount == 2
							and kinds[funcId] == K.AstExprGlobal
							and ctx.symbols[nodes[funcId].name] == "setmetatable"
						then
							local arg0Id = listValues[listFirsts[valNode.args]]
							if kinds[arg0Id] == K.AstExprTable then
								local arg0Node = nodes[arg0Id]
								if arg0Node.items == 0 or listCounts[arg0Node.items] == 0 then
									(ctx.tables :: { [number]: number })[varId] = arg0Id
								end
							end
						end
					end
				end
			end
		end
	end

	local varsFirst = if node.vars ~= 0 then listFirsts[node.vars] else 0
	local varsCount = if node.vars ~= 0 then listCounts[node.vars] else 0
	local valsFirst = if node.values ~= 0 then listFirsts[node.values] else 0
	local valsCount = if node.values ~= 0 then listCounts[node.values] else 0

	if ctx.doO1 and varsCount > 0 and valsCount > 0 then
		local bound = if varsCount < valsCount then varsCount else valsCount
		for i = 0, bound - 1 do
			markEscaped(ctx, listValues[valsFirst + i])
		end
	end

	visitTrackedExprList(ctx, node.values)

	local bindings = ctx.bindings
	local exportedVariables = ctx.exportedVariables
	local trackExports = ctx.flags.LuauOptimizeExportTable and exportedVariables ~= nil

	local bound = if varsCount < valsCount then varsCount else valsCount
	for i = 0, bound - 1 do
		local varId = listValues[varsFirst + i]
		pushTrackedLocal(ctx, varId, listValues[valsFirst + i], ctx.currentBlock)
		if trackExports and exportedVariables and bindings[varId].isExported then
			exportedVariables[#exportedVariables + 1] = varId
		end
	end
	for i = valsCount, varsCount - 1 do
		local varId = listValues[varsFirst + i]
		pushTrackedLocal(ctx, varId, 0, ctx.currentBlock)
		if trackExports and exportedVariables and bindings[varId].isExported then
			exportedVariables[#exportedVariables + 1] = varId
		end
	end

	if ctx.doO1 and varsCount > 0 then
		local vars = ctx.variables
		local varOwner = vars.owner
		local varWritten = vars.written
		local varInit = vars.init
		local tableConstants = ctx.tableConstants :: { [number]: number }
		local cands = ctx.tableConstCandidates :: { number }
		for i = 0, varsCount - 1 do
			local localId = listValues[varsFirst + i]
			if varOwner[localId] ~= nil and not varWritten[localId] then
				local initId = varInit[localId]
				if
					initId ~= 0
					and unwrapExprOfType(ctx.arena, initId, K.AstExprTable) ~= 0
					and tableConstants[localId] == nil
				then
					cands[#cands + 1] = localId
				end
			end
		end
	end
end

@native
local function visitTrackedStatAssignAndDecls(ctx: TrackValuesCtx, k: number, node: any)
	local nodes = ctx.nodes
	local kinds = ctx.kinds
	local listFirsts = ctx.listFirsts
	local listCounts = ctx.listCounts
	local listValues = ctx.listValues
	if k == K.AstStatAssign then
		if node.vars ~= 0 then
			local first = listFirsts[node.vars]
			local count = listCounts[node.vars]
			local doO1 = ctx.doO1
			for i = 0, count - 1 do
				local varExpr = listValues[first + i]
				writeTrackedVar(ctx, varExpr)
				if doO1 then
					trackShapeAssign(
						nodes,
						kinds,
						ctx.tables :: { [number]: number },
						ctx.fields :: { [number]: { [number]: boolean } },
						ctx.loops :: { [number]: number },
						ctx.shapes :: { [number]: TableShapePrediction },
						varExpr
					)
					markEscapedTableIndex(ctx, varExpr, true)
				end
				visitTrackedExpr(ctx, varExpr)
			end
		end
		if ctx.doO1 and node.values ~= 0 then
			local first = listFirsts[node.values]
			local count = listCounts[node.values]
			for i = 0, count - 1 do
				markEscaped(ctx, listValues[first + i])
			end
		end
		visitTrackedExprList(ctx, node.values)
	elseif k == K.AstStatCompoundAssign then
		writeTrackedVar(ctx, node.var)
		if ctx.doO1 then
			markEscapedTableIndex(ctx, node.var, true)
			if ctx.flags.LuauCompileTableFoldFix then
				markEscapedBinaryOp(ctx, node.var, node.value, node.op)
			end
		end
		visitTrackedExpr(ctx, node.var)
		visitTrackedExpr(ctx, node.value)
	elseif k == K.AstStatFunction then
		writeTrackedVar(ctx, node.name)
		if ctx.doO1 then
			trackShapeAssign(
				nodes,
				kinds,
				ctx.tables :: { [number]: number },
				ctx.fields :: { [number]: { [number]: boolean } },
				ctx.loops :: { [number]: number },
				ctx.shapes :: { [number]: TableShapePrediction },
				node.name
			)
			markEscapedTableIndex(ctx, node.name, true)
		end
		visitTrackedExpr(ctx, node.name)
		visitTrackedExpr(ctx, node.func)
	elseif k == K.AstStatLocalFunction then
		pushTrackedLocal(ctx, node.name, node.func, ctx.currentBlock)
		if ctx.bindings[node.name].isExported then
			ctx.variables.nonLexicalUse[node.name] = true
			local exportedFunctions = ctx.exportedFunctions
			if ctx.flags.LuauOptimizeExportTable and exportedFunctions then
				exportedFunctions[node.name] = true
				local exportedVariables = ctx.exportedVariables
				if exportedVariables then
					exportedVariables[#exportedVariables + 1] = node.name
				end
			end
		end
		visitTrackedExpr(ctx, node.func)
	elseif k == K.AstStatTypeAlias then
		ctx.hasTypeAliases = true
	elseif k == K.AstStatClass then
		ctx.hasClasses = true
		if node.declModifier == "None" then
			writeTrackedVar(ctx, node.exprName)
			if ctx.doO1 then
				markEscapedTableIndex(ctx, node.exprName, true)
			end
			visitTrackedExpr(ctx, node.exprName)
		end
		if node.super ~= 0 then
			visitTrackedExpr(ctx, node.super)
		end
		if node.members ~= 0 then
			local first = listFirsts[node.members]
			local count = listCounts[node.members]
			for i = 0, count - 1 do
				local mId = listValues[first + i]
				if kinds[mId] == K.AstClassMethod then
					visitTrackedExpr(ctx, nodes[mId]["function"])
				end
			end
		end
	elseif k == K.AstStatError then
		visitTrackedExprList(ctx, node.expressions)
		if node.statements ~= 0 then
			local first = listFirsts[node.statements]
			local count = listCounts[node.statements]
			for i = 0, count - 1 do
				visitTrackedStat(ctx, listValues[first + i])
			end
		end
	end
end

@native
function visitTrackedStat(ctx: TrackValuesCtx, nodeId: number)
	if nodeId == 0 then
		return
	end
	local kinds = ctx.kinds
	local k = kinds[nodeId]
	if k == nil or k == K.AstStatBreak or k == K.AstStatContinue then
		return
	end
	if k == K.AstStatTypeAlias then
		ctx.hasTypeAliases = true
		return
	end
	local nodes = ctx.nodes
	local node = nodes[nodeId]
	if not node then
		return
	end
	local listFirsts = ctx.listFirsts
	local listCounts = ctx.listCounts
	local listValues = ctx.listValues
	if k == K.AstStatBlock then
		local oldBlock = ctx.currentBlock
		ctx.currentBlock = nodeId
		if node.body ~= 0 then
			local first = listFirsts[node.body]
			local count = listCounts[node.body]
			for i = 0, count - 1 do
				visitTrackedStat(ctx, listValues[first + i])
			end
		end
		ctx.currentBlock = oldBlock
	elseif k == K.AstStatIf then
		visitTrackedExpr(ctx, node.condition)
		if ctx.flagExpIfLocal and node.conditionLocal and node.conditionLocal ~= 0 then
			pushTrackedLocal(ctx, node.conditionLocal, node.condition, 0)
			if ctx.doO1 then
				markEscaped(ctx, node.condition)
			end
		end
		visitTrackedStat(ctx, node.thenbody)
		if node.elsebody ~= 0 then
			visitTrackedStat(ctx, node.elsebody)
		end
	elseif k == K.AstStatRepeat then
		visitTrackedStat(ctx, node.body)
		visitTrackedExpr(ctx, node.condition)
	elseif k == K.AstStatWhile then
		visitTrackedExpr(ctx, node.condition)
		if ctx.flagExpWhileLocal and node.conditionLocal and node.conditionLocal ~= 0 then
			pushTrackedLocal(ctx, node.conditionLocal, 0, 0)
			if ctx.doO1 then
				markEscaped(ctx, node.condition)
			end
		end
		visitTrackedStat(ctx, node.body)
	elseif k == K.AstStatReturn then
		if ctx.doO1 and node.list ~= 0 then
			local first = listFirsts[node.list]
			local count = listCounts[node.list]
			for i = 0, count - 1 do
				markEscaped(ctx, listValues[first + i])
			end
		end
		visitTrackedExprList(ctx, node.list)
	elseif k == K.AstStatExpr then
		visitTrackedExpr(ctx, node.expr)
	elseif k == K.AstStatLocal then
		visitTrackedStatLocal(ctx, node)
	elseif k == K.AstStatFor then
		pushTrackedLocal(ctx, node.var, 0, 0)
		if ctx.doO1 then
			if
				node.step == 0
				and kinds[node.from] == K.AstExprConstantNumber
				and kinds[node.to] == K.AstExprConstantNumber
			then
				local fromVal = nodes[node.from].value
				local toVal = nodes[node.to].value
				if fromVal == 1.0 and toVal >= 1.0 and toVal <= 16.0 then
					(ctx.loops :: { [number]: number })[node.var] = math.floor(toVal)
				end
			end
		end
		visitTrackedExpr(ctx, node.from)
		visitTrackedExpr(ctx, node.to)
		if node.step ~= 0 then
			visitTrackedExpr(ctx, node.step)
		end
		visitTrackedStat(ctx, node.body)
	elseif k == K.AstStatForIn then
		if node.vars ~= 0 then
			local first = listFirsts[node.vars]
			local count = listCounts[node.vars]
			for i = 0, count - 1 do
				pushTrackedLocal(ctx, listValues[first + i], 0, 0)
			end
		end
		if ctx.doO1 and node.values ~= 0 then
			local first = listFirsts[node.values]
			local count = listCounts[node.values]
			for i = 0, count - 1 do
				markEscaped(ctx, listValues[first + i])
			end
		end
		visitTrackedExprList(ctx, node.values)
		visitTrackedStat(ctx, node.body)
	else
		visitTrackedStatAssignAndDecls(ctx, k, node)
	end
end

@native
local function finalizeFusedO1(ctx: TrackValuesCtx)
	local vars = ctx.variables
	local varOwner = vars.owner
	local varWritten = vars.written
	local varInit = vars.init
	local cands = ctx.tableConstCandidates
	if cands and #cands > 0 then
		local tableConstants = ctx.tableConstants :: { [number]: number }
		for i = 1, #cands do
			local localId = cands[i]
			if varOwner[localId] ~= nil and not varWritten[localId] and tableConstants[localId] == nil then
				tableConstants[localId] = TableConstantKind.ConstantTable
			end
		end
	end

	local foundCalls = ctx.foundBuiltinCalls
	if foundCalls and #foundCalls > 0 then
		local nodes = ctx.nodes
		local kinds = ctx.kinds
		local globals = ctx.globals
		local builtinsMap = ctx.builtins :: { [number]: number }
		local opts = ctx.options
		local disabledSet = if opts and opts.disabledBuiltins
			then CompilerBuiltins.buildDisabledSet(opts.disabledBuiltins, ctx.arena, globals, opts, ctx.flags)
			else nil
		for i = 1, #foundCalls do
			local callId = foundCalls[i]
			local invalidated = false
			local callNode = nodes[callId]
			if disabledSet then
				local bObj, bMethod = CompilerBuiltins.getBuiltin(callNode.func, ctx.arena, globals, ctx.variables)
				if CompilerBuiltins.isBuiltinDisabled(disabledSet, bObj, bMethod, builtinsMap[callId]) then
					invalidated = true
				end
			end
			if not invalidated then
				local curId = callNode.func
				while curId ~= 0 do
					local fk = kinds[curId]
					if fk == nil then
						break
					end
					local fn = nodes[curId]
					if fk == K.AstExprLocal then
						local localId = fn["local"]
						local initId = varInit[localId]
						if varOwner[localId] == nil or varWritten[localId] or not initId or initId == 0 then
							invalidated = true
							break
						end
						curId = initId
					elseif fk == K.AstExprIndexName then
						local exprId = fn.expr
						local exprKind = kinds[exprId]
						if exprKind == nil then
							invalidated = true
						elseif exprKind == K.AstExprLocal then
							local exprNode = nodes[exprId]
							local localId = exprNode["local"]
							local initId = varInit[localId]
							if varOwner[localId] == nil or varWritten[localId] or not initId or initId == 0 then
								invalidated = true
							else
								local initKind = kinds[initId]
								local objNode: any = nil
								if initKind == K.AstExprGlobal then
									objNode = nodes[initId]
								elseif initKind == K.AstExprBinary then
									local initNode = nodes[initId]
									if initNode.op == "Or" and kinds[initNode.left] == K.AstExprGlobal then
										objNode = nodes[initNode.left]
									end
								end
								if
									not objNode
									or (globals[objNode.name] or GlobalState.Default) ~= GlobalState.Default
								then
									invalidated = true
								end
							end
						elseif exprKind == K.AstExprGlobal then
							if (globals[nodes[exprId].name] or GlobalState.Default) ~= GlobalState.Default then
								invalidated = true
							end
						else
							invalidated = true
						end
						break
					elseif fk == K.AstExprGlobal then
						if (globals[fn.name] or GlobalState.Default) ~= GlobalState.Default then
							invalidated = true
						end
						break
					else
						break
					end
				end
			end
			if invalidated then
				builtinsMap[callId] = nil
			end
		end
	end
end

local borrowedTrackCtx: TrackValuesCtx? = nil

local function trackValuesAndAnalyzeO1(
	arena: Arena.ArenaImpl,
	globals: { [number]: number },
	variables: VariableTable,
	exportedFunctions: { [number]: boolean }?,
	exportedVariables: { number }?,
	rootId: number,
	flags: any,
	symbolByName: { [string]: number }?,
	doO1: boolean,
	builtins: { [number]: number },
	tableConstants: { [number]: number },
	shapes: { [number]: TableShapePrediction },
	options: any
): ({ number }, boolean, boolean, boolean, boolean, { [number]: boolean }, boolean)
	local ctx = borrowedTrackCtx
	if ctx ~= nil then
		borrowedTrackCtx = nil
		ctx.arena = arena
		ctx.nodes = arena.nodes
		ctx.kinds = arena.kinds
		ctx.listFirsts = arena.listFirsts
		ctx.listCounts = arena.listCounts
		ctx.listValues = arena.listValues
		ctx.bindings = arena.bindings
		ctx.symbols = arena.symbols
		ctx.globals = globals
		ctx.variables = variables
		ctx.varOwner = variables.owner
		ctx.varLastUsed = variables.lastUsed
		ctx.varNonLexical = variables.nonLexicalUse
		ctx.exportedFunctions = exportedFunctions
		ctx.exportedVariables = exportedVariables
		ctx.flags = flags
		ctx.checkExported = flags.LuauExportValueSyntax == true
		ctx.flagExpIfLocal = flags.LuauExperimentalIfLocalSyntax == true
		ctx.flagExpWhileLocal = flags.LuauExperimentalWhileLocalSyntax == true
		ctx.flagTableFoldFix = flags.LuauCompileTableFoldFix == true
		ctx.currentBlock = 0
		ctx.getfenvSym = if symbolByName then symbolByName["getfenv"] else nil
		ctx.setfenvSym = if symbolByName then symbolByName["setfenv"] else nil
		ctx.functions = {}
		ctx.hasNativeFunction = false
		ctx.getfenvUsed = false
		ctx.setfenvUsed = false
		ctx.hasTypeAliases = false
		ctx.hasClasses = false
		ctx.funcHasCalls = {}
		ctx.curFuncHasCalls = false
		ctx.doO1 = doO1
		ctx.builtins = if doO1 then builtins else nil
		ctx.tableConstants = if doO1 then tableConstants else nil
		ctx.shapes = if doO1 then shapes else nil
		ctx.options = if doO1 then options else nil
		ctx.disabledById = false
	else
		ctx = {
			arena = arena,
			nodes = arena.nodes,
			kinds = arena.kinds,
			listFirsts = arena.listFirsts,
			listCounts = arena.listCounts,
			listValues = arena.listValues,
			bindings = arena.bindings,
			symbols = arena.symbols,
			globals = globals,
			variables = variables,
			varOwner = variables.owner,
			varLastUsed = variables.lastUsed,
			varNonLexical = variables.nonLexicalUse,
			exportedFunctions = exportedFunctions,
			exportedVariables = exportedVariables,
			flags = flags,
			checkExported = flags.LuauExportValueSyntax == true,
			flagExpIfLocal = flags.LuauExperimentalIfLocalSyntax == true,
			flagExpWhileLocal = flags.LuauExperimentalWhileLocalSyntax == true,
			flagTableFoldFix = flags.LuauCompileTableFoldFix == true,
			currentBlock = 0,
			getfenvSym = if symbolByName then symbolByName["getfenv"] else nil,
			setfenvSym = if symbolByName then symbolByName["setfenv"] else nil,
			functions = {},
			hasNativeFunction = false,
			getfenvUsed = false,
			setfenvUsed = false,
			hasTypeAliases = false,
			hasClasses = false,
			funcHasCalls = {},
			curFuncHasCalls = false,
			doO1 = doO1,
			builtins = if doO1 then builtins else nil,
			tableConstants = if doO1 then tableConstants else nil,
			shapes = if doO1 then shapes else nil,
			options = if doO1 then options else nil,
			tables = {},
			fields = {},
			loops = {},
			tableConstCandidates = {},
			foundBuiltinCalls = {},
			disabledById = false,
		}
	end
	local tc = ctx :: TrackValuesCtx
	visitTrackedStat(tc, rootId)
	if doO1 then
		finalizeFusedO1(tc)
		table.clear(tc.tables :: { [number]: number })
		table.clear(tc.fields :: { [number]: { [number]: boolean } })
		table.clear(tc.loops :: { [number]: number })
		table.clear(tc.tableConstCandidates :: { number })
		table.clear(tc.foundBuiltinCalls :: { number })
	end
	local functions = tc.functions
	local hasNativeFunction = tc.hasNativeFunction
	local getfenvUsed = tc.getfenvUsed
	local setfenvUsed = tc.setfenvUsed
	local hasTypeAliases = tc.hasTypeAliases
	local hasClasses = tc.hasClasses
	local funcHasCalls = tc.funcHasCalls
	local cached: any = tc
	cached.arena = nil
	cached.nodes = nil
	cached.kinds = nil
	cached.listFirsts = nil
	cached.listCounts = nil
	cached.listValues = nil
	cached.bindings = nil
	cached.symbols = nil
	cached.globals = nil
	cached.variables = nil
	cached.varOwner = nil
	cached.varLastUsed = nil
	cached.varNonLexical = nil
	cached.exportedFunctions = nil
	cached.exportedVariables = nil
	cached.flags = nil
	cached.functions = nil
	cached.funcHasCalls = nil
	cached.builtins = nil
	cached.tableConstants = nil
	cached.shapes = nil
	cached.options = nil
	borrowedTrackCtx = cached
	return functions, hasNativeFunction, getfenvUsed, setfenvUsed, hasTypeAliases, funcHasCalls, hasClasses
end

@native
local function constantsEqualVal(t1: number, v1: any, t2: number, v2: any): boolean
	if t1 ~= t2 then
		return false
	end
	if t1 == ConstantType.Nil then
		return true
	elseif
		t1 == ConstantType.Boolean
		or t1 == ConstantType.Number
		or t1 == ConstantType.String
		or t1 == ConstantType.Table
	then
		return v1 == v2
	elseif t1 == ConstantType.Vectorf or t1 == ConstantType.Vectord then
		local vec1 = v1 :: { number }
		local vec2 = v2 :: { number }
		return vec1[1] == vec2[1] and vec1[2] == vec2[2] and vec1[3] == vec2[3] and vec1[4] == vec2[4]
	end
	return false
end

@native
local function numbersIdentical(a: number, b: number): boolean
	return a == b and (a ~= 0 or (1 / a) == (1 / b))
end

@native
local function constantsIdenticalVal(t1: number, v1: any, t2: number, v2: any): boolean
	if t1 ~= t2 then
		return false
	end
	if t1 == ConstantType.Number then
		return numbersIdentical(v1 :: number, v2 :: number)
	elseif t1 == ConstantType.Vectorf or t1 == ConstantType.Vectord then
		local vec1 = v1 :: { number }
		local vec2 = v2 :: { number }
		return numbersIdentical(vec1[1], vec2[1])
			and numbersIdentical(vec1[2], vec2[2])
			and numbersIdentical(vec1[3], vec2[3])
			and numbersIdentical(vec1[4], vec2[4])
	end
	return constantsEqualVal(t1, v1, t2, v2)
end

@native
local function foldUnaryVal(op: string, argType: number, argVal: any): (number, any)
	assert(argType ~= ConstantType.Unknown, "expected known constant")
	if op == "Not" then
		return ConstantType.Boolean, not isTruthfulVal(argType, argVal)
	elseif op == "Minus" then
		if argType == ConstantType.Number then
			return ConstantType.Number, -(argVal :: number)
		elseif argType == ConstantType.Vectorf then
			local v = argVal :: { number }
			return ConstantType.Vectorf, { roundf(-v[1]), roundf(-v[2]), roundf(-v[3]), roundf(-v[4]) }
		elseif argType == ConstantType.Vectord then
			local v = argVal :: { number }
			return ConstantType.Vectord, { -v[1], -v[2], -v[3], -v[4] }
		end
	elseif op == "Len" then
		if argType == ConstantType.String then
			return ConstantType.Number, #(argVal :: string)
		end
	end
	return ConstantType.Unknown, nil
end

@native
local function makeVecf(x: number, y: number, z: number, w: number): { number }
	return { roundf(x), roundf(y), roundf(z), roundf(w) }
end

@native
local function foldBinaryAddSubVal(op: string, lType: number, lVal: any, rType: number, rVal: any): (number, any)
	local isAdd = op == "Add"
	if lType == ConstantType.Number and rType == ConstantType.Number then
		local l = lVal :: number
		local r = rVal :: number
		return ConstantType.Number, if isAdd then l + r else l - r
	elseif lType == ConstantType.Vectorf and rType == ConstantType.Vectorf then
		local lv = lVal :: { number }
		local rv = rVal :: { number }
		return ConstantType.Vectorf,
			makeVecf(
				if isAdd then lv[1] + rv[1] else lv[1] - rv[1],
				if isAdd then lv[2] + rv[2] else lv[2] - rv[2],
				if isAdd then lv[3] + rv[3] else lv[3] - rv[3],
				if isAdd then lv[4] + rv[4] else lv[4] - rv[4]
			)
	elseif lType == ConstantType.Vectord and rType == ConstantType.Vectord then
		local lv = lVal :: { number }
		local rv = rVal :: { number }
		return ConstantType.Vectord,
			{
				if isAdd then lv[1] + rv[1] else lv[1] - rv[1],
				if isAdd then lv[2] + rv[2] else lv[2] - rv[2],
				if isAdd then lv[3] + rv[3] else lv[3] - rv[3],
				if isAdd then lv[4] + rv[4] else lv[4] - rv[4],
			}
	end
	return ConstantType.Unknown, nil
end

local function foldBinaryMulDivVecVal(
	isDouble: boolean,
	isMul: boolean,
	lType: number,
	lVal: any,
	rType: number,
	rVal: any
): (number, any)
	local vecType = if isDouble then ConstantType.Vectord else ConstantType.Vectorf
	if lType == vecType and rType == vecType then
		local lv = lVal :: { number }
		local rv = rVal :: { number }
		local hadW = lv[4] ~= 0.0 or rv[4] ~= 0.0
		local rw = if isMul then lv[4] * rv[4] else lv[4] / rv[4]
		if isDouble then
			if rw == 0.0 or hadW then
				return ConstantType.Vectord,
					{
						if isMul then lv[1] * rv[1] else lv[1] / rv[1],
						if isMul then lv[2] * rv[2] else lv[2] / rv[2],
						if isMul then lv[3] * rv[3] else lv[3] / rv[3],
						rw,
					}
			end
		else
			local rwF = roundf(rw)
			if rwF == 0.0 or hadW then
				return ConstantType.Vectorf,
					makeVecf(
						if isMul then lv[1] * rv[1] else lv[1] / rv[1],
						if isMul then lv[2] * rv[2] else lv[2] / rv[2],
						if isMul then lv[3] * rv[3] else lv[3] / rv[3],
						rwF
					)
			end
		end
	elseif lType == ConstantType.Number and rType == vecType then
		local s = if isDouble then lVal :: number else roundf(lVal :: number)
		local rv = rVal :: { number }
		local hadW = rv[4] ~= 0.0
		local rw = if isMul then s * rv[4] else s / rv[4]
		if isDouble then
			if rw == 0.0 or hadW then
				return ConstantType.Vectord,
					{
						if isMul then s * rv[1] else s / rv[1],
						if isMul then s * rv[2] else s / rv[2],
						if isMul then s * rv[3] else s / rv[3],
						rw,
					}
			end
		else
			local rwF = roundf(rw)
			if rwF == 0.0 or hadW then
				return ConstantType.Vectorf,
					makeVecf(
						if isMul then s * rv[1] else s / rv[1],
						if isMul then s * rv[2] else s / rv[2],
						if isMul then s * rv[3] else s / rv[3],
						rwF
					)
			end
		end
	elseif lType == vecType and rType == ConstantType.Number then
		local lv = lVal :: { number }
		local s = if isDouble then rVal :: number else roundf(rVal :: number)
		local hadW = lv[4] ~= 0.0
		local rw = if isMul then lv[4] * s else lv[4] / s
		if isDouble then
			if rw == 0.0 or hadW then
				return ConstantType.Vectord,
					{
						if isMul then lv[1] * s else lv[1] / s,
						if isMul then lv[2] * s else lv[2] / s,
						if isMul then lv[3] * s else lv[3] / s,
						rw,
					}
			end
		else
			local rwF = roundf(rw)
			if rwF == 0.0 or hadW then
				return ConstantType.Vectorf,
					makeVecf(
						if isMul then lv[1] * s else lv[1] / s,
						if isMul then lv[2] * s else lv[2] / s,
						if isMul then lv[3] * s else lv[3] / s,
						rwF
					)
			end
		end
	end
	return ConstantType.Unknown, nil
end

local function foldBinaryFloorDivVecVal(
	isDouble: boolean,
	lType: number,
	lVal: any,
	rType: number,
	rVal: any
): (number, any)
	local vecType = if isDouble then ConstantType.Vectord else ConstantType.Vectorf
	if lType == vecType and rType == vecType then
		local lv = lVal :: { number }
		local rv = rVal :: { number }
		local hadW = lv[4] ~= 0.0 or rv[4] ~= 0.0
		if isDouble then
			local rw = math.floor(lv[4] / rv[4])
			if rw == 0.0 or hadW then
				return ConstantType.Vectord,
					{ math.floor(lv[1] / rv[1]), math.floor(lv[2] / rv[2]), math.floor(lv[3] / rv[3]), rw }
			end
		else
			local rwF = roundf(math.floor(roundf(lv[4] / rv[4])))
			if rwF == 0.0 or hadW then
				return ConstantType.Vectorf,
					makeVecf(
						math.floor(roundf(lv[1] / rv[1])),
						math.floor(roundf(lv[2] / rv[2])),
						math.floor(roundf(lv[3] / rv[3])),
						rwF
					)
			end
		end
	elseif lType == ConstantType.Number and rType == vecType then
		local s = if isDouble then lVal :: number else roundf(lVal :: number)
		local rv = rVal :: { number }
		local hadW = rv[4] ~= 0.0
		if isDouble then
			local rw = math.floor(s / rv[4])
			if rw == 0.0 or hadW then
				return ConstantType.Vectord, { math.floor(s / rv[1]), math.floor(s / rv[2]), math.floor(s / rv[3]), rw }
			end
		else
			local rwF = roundf(math.floor(roundf(s / rv[4])))
			if rwF == 0.0 or hadW then
				return ConstantType.Vectorf,
					makeVecf(
						math.floor(roundf(s / rv[1])),
						math.floor(roundf(s / rv[2])),
						math.floor(roundf(s / rv[3])),
						rwF
					)
			end
		end
	elseif lType == vecType and rType == ConstantType.Number then
		local lv = lVal :: { number }
		local s = if isDouble then rVal :: number else roundf(rVal :: number)
		local hadW = lv[4] ~= 0.0
		if isDouble then
			local rw = math.floor(lv[4] / s)
			if rw == 0.0 or hadW then
				return ConstantType.Vectord, { math.floor(lv[1] / s), math.floor(lv[2] / s), math.floor(lv[3] / s), rw }
			end
		else
			local rwF = roundf(math.floor(roundf(lv[4] / s)))
			if rwF == 0.0 or hadW then
				return ConstantType.Vectorf,
					makeVecf(
						math.floor(roundf(lv[1] / s)),
						math.floor(roundf(lv[2] / s)),
						math.floor(roundf(lv[3] / s)),
						rwF
					)
			end
		end
	end
	return ConstantType.Unknown, nil
end

local function foldBinaryFloorDivVal(lType: number, lVal: any, rType: number, rVal: any): (number, any)
	if lType == ConstantType.Number and rType == ConstantType.Number then
		return ConstantType.Number, math.floor((lVal :: number) / (rVal :: number))
	elseif lType == ConstantType.Vectorf or rType == ConstantType.Vectorf then
		return foldBinaryFloorDivVecVal(false, lType, lVal, rType, rVal)
	elseif lType == ConstantType.Vectord or rType == ConstantType.Vectord then
		return foldBinaryFloorDivVecVal(true, lType, lVal, rType, rVal)
	end
	return ConstantType.Unknown, nil
end

@native
local function foldBinaryCompareEqNeVal(op: string, lType: number, lVal: any, rType: number, rVal: any): (number, any)
	if
		lType == ConstantType.Unknown
		or rType == ConstantType.Unknown
		or (lType == ConstantType.Table and (lVal :: TableConstVal).fromLibrary)
		or (rType == ConstantType.Table and (rVal :: TableConstVal).fromLibrary)
	then
		return ConstantType.Unknown, nil
	end
	if lType == rType and (lType == ConstantType.Vectorf or lType == ConstantType.Vectord) then
		local v1 = lVal :: { number }
		local v2 = rVal :: { number }
		if v1[1] == v2[1] and v1[2] == v2[2] and v1[3] == v2[3] and v1[4] ~= v2[4] then
			return ConstantType.Unknown, nil
		end
	end
	local eq = constantsEqualVal(lType, lVal, rType, rVal)
	return ConstantType.Boolean, if op == "CompareEq" then eq else not eq
end

@native
local function foldBinaryCompareOrderVal(op: string, lType: number, lVal: any, rType: number, rVal: any): (number, any)
	if lType ~= ConstantType.Number or rType ~= ConstantType.Number then
		return ConstantType.Unknown, nil
	end
	local l = lVal :: number
	local r = rVal :: number
	return ConstantType.Boolean,
		if op == "CompareLt"
			then l < r
			elseif op == "CompareLe" then l <= r
			elseif op == "CompareGt" then l > r
			else l >= r
end

@native
local function foldBinaryVal(op: string, lType: number, lVal: any, rType: number, rVal: any): (number, any)
	assert(lType ~= ConstantType.Unknown, "expected known lhs constant")

	if op == "Add" or op == "Sub" then
		return foldBinaryAddSubVal(op, lType, lVal, rType, rVal)
	elseif op == "Mul" or op == "Div" then
		local isMul = op == "Mul"
		if lType == ConstantType.Number and rType == ConstantType.Number then
			local l = lVal :: number
			local r = rVal :: number
			return ConstantType.Number, if isMul then l * r else l / r
		elseif lType == ConstantType.Vectorf or rType == ConstantType.Vectorf then
			return foldBinaryMulDivVecVal(false, isMul, lType, lVal, rType, rVal)
		elseif lType == ConstantType.Vectord or rType == ConstantType.Vectord then
			return foldBinaryMulDivVecVal(true, isMul, lType, lVal, rType, rVal)
		end
	elseif op == "FloorDiv" then
		return foldBinaryFloorDivVal(lType, lVal, rType, rVal)
	elseif op == "Mod" then
		if lType == ConstantType.Number and rType == ConstantType.Number then
			return ConstantType.Number, (lVal :: number) % (rVal :: number)
		end
	elseif op == "Pow" then
		if lType == ConstantType.Number and rType == ConstantType.Number then
			return ConstantType.Number, (lVal :: number) ^ (rVal :: number)
		end
	elseif op == "Concat" then
		if lType == ConstantType.String and rType == ConstantType.String then
			local ls = lVal :: string
			local rs = rVal :: string
			if #ls + #rs <= 4096 then
				return ConstantType.String, ls .. rs
			end
		end
	elseif op == "CompareNe" or op == "CompareEq" then
		return foldBinaryCompareEqNeVal(op, lType, lVal, rType, rVal)
	elseif op == "CompareLt" or op == "CompareLe" or op == "CompareGt" or op == "CompareGe" then
		return foldBinaryCompareOrderVal(op, lType, lVal, rType, rVal)
	elseif op == "And" then
		if isTruthfulVal(lType, lVal) then
			return rType, rVal
		else
			return lType, lVal
		end
	elseif op == "Or" then
		if isTruthfulVal(lType, lVal) then
			return lType, lVal
		else
			return rType, rVal
		end
	end

	return ConstantType.Unknown, nil
end

@native
local function undoChanges(
	mapTypes: { [number]: number },
	mapVals: { [number]: any },
	stack: ChangeStack,
	targetTop: number,
	variables: VariableTable?
)
	local keys = stack.keys
	local prevTypes = stack.prevTypes
	local prevVals = stack.prevVals
	local prevConsts = stack.prevConsts
	local varConstant = if variables then variables.constant else nil
	for i = stack.top, targetTop + 1, -1 do
		local key = keys[i]
		mapTypes[key] = prevTypes[i]
		mapVals[key] = prevVals[i]
		if varConstant and prevConsts then
			varConstant[key] = prevConsts[i]
		end
	end
	stack.top = targetTop
end

type FoldConstantsCtx = {
	arena: Arena.ArenaImpl,
	nodes: { [number]: any },
	kinds: { number },
	listFirsts: { number },
	listCounts: { number },
	listValues: { [number]: any },
	symbols: { [number]: string },
	bindings: { [number]: any },
	constTypes: { [number]: number },
	constVals: { [number]: any },
	variables: VariableTable,
	locstantTypes: { [number]: number },
	locstantVals: { [number]: any },
	builtinsMap: { [number]: number }?,
	foldLibraryK: any,
	vectorDouble: boolean,
	libraryMemberConstantCb: ((string, string) -> any)?,
	tableConstants: { [number]: number },
	tableLocals: { [number]: TableConstVal },
	tableLocalsDirty: boolean,
	flags: any,
	exprChanges: ChangeStack?,
	localChanges: ChangeStack?,
	wasEmpty: boolean,
	directWrite: boolean,
	builtinArgTypes: { number },
	builtinArgVals: { any },
	builtinArgTop: number,
	funcReadTableLocal: { [number]: boolean }?,
	curFuncReadTableLocal: boolean,
	globals: { [number]: number }?,
}

@native
local function recordConstantValueVal(
	mapTypes: { [number]: number },
	mapVals: { [number]: any },
	changes: ChangeStack?,
	key: number,
	ct: number,
	cv: any
)
	local prevType = mapTypes[key]
	if prevType == nil or prevType == ConstantType.Unknown then
		if ct == ConstantType.Unknown then
			return
		end
		if changes then
			local top = changes.top + 1
			changes.top = top
			changes.keys[top] = key
			changes.prevTypes[top] = ConstantType.Unknown
			changes.prevVals[top] = nil
		end
		mapTypes[key] = ct
		mapVals[key] = cv
		return
	end
	local prevVal = mapVals[key]
	if constantsIdenticalVal(prevType, prevVal, ct, cv) then
		return
	end
	if changes then
		local top = changes.top + 1
		changes.top = top
		changes.keys[top] = key
		changes.prevTypes[top] = prevType
		changes.prevVals[top] = prevVal
	end
	mapTypes[key] = ct
	mapVals[key] = cv
end

@native
local function recordLocalVarConstantVal(
	ctx: FoldConstantsCtx,
	varId: number,
	ct: number,
	cv: any,
	newConstant: boolean
)
	local varConstant = ctx.variables.constant
	local wasConst = varConstant[varId] == true
	varConstant[varId] = newConstant
	local locstantTypes = ctx.locstantTypes
	local locstantVals = ctx.locstantVals
	local prevType = locstantTypes[varId]
	local prevVal = if prevType ~= nil and prevType ~= ConstantType.Unknown then locstantVals[varId] else nil
	local valChanged = if prevType == nil or prevType == ConstantType.Unknown
		then ct ~= ConstantType.Unknown
		else not constantsIdenticalVal(prevType, prevVal, ct, cv)
	if valChanged or wasConst ~= newConstant then
		local changes = ctx.localChanges
		if changes then
			local top = changes.top + 1
			changes.top = top
			changes.keys[top] = varId
			changes.prevTypes[top] = prevType or ConstantType.Unknown
			changes.prevVals[top] = prevVal
			local prevConsts = changes.prevConsts
			if prevConsts then
				prevConsts[top] = wasConst
			end
		end
		if valChanged then
			locstantTypes[varId] = ct
			locstantVals[varId] = cv
		end
	end
end

@native
local function clearLocalConstant(ctx: FoldConstantsCtx, varId: number)
	local varConstant = ctx.variables.constant
	local wasConst = varConstant[varId] == true
	varConstant[varId] = false
	if ctx.wasEmpty then
		return
	end
	local locstantTypes = ctx.locstantTypes
	local locstantVals = ctx.locstantVals
	local prevType = locstantTypes[varId]
	local hadPrev = prevType ~= nil and prevType ~= ConstantType.Unknown
	if hadPrev or wasConst then
		local changes = ctx.localChanges
		if changes then
			local top = changes.top + 1
			changes.top = top
			changes.keys[top] = varId
			changes.prevTypes[top] = if hadPrev then prevType else ConstantType.Unknown
			changes.prevVals[top] = if hadPrev then locstantVals[varId] else nil
			local prevConsts = changes.prevConsts
			if prevConsts then
				prevConsts[top] = wasConst
			end
		end
		if hadPrev then
			locstantTypes[varId] = ConstantType.Unknown
			locstantVals[varId] = nil
		end
	end
end

@native
local function recordConditionLocal(ctx: FoldConstantsCtx, conditionLocal: number?, ct: number, cv: any)
	if not (ctx.flags.LuauExperimentalIfLocalSyntax and conditionLocal and conditionLocal ~= 0) then
		return
	end
	local vars = ctx.variables
	if vars.owner[conditionLocal] ~= nil and not vars.written[conditionLocal] and vars.init[conditionLocal] ~= 0 then
		if ct == ConstantType.Table then
			clearLocalConstant(ctx, conditionLocal)
			if ctx.tableConstants[conditionLocal] == TableConstantKind.ConstantTable then
				ctx.tableLocals[conditionLocal] = cv :: TableConstVal
				ctx.tableLocalsDirty = true
			end
		elseif ct ~= ConstantType.Unknown then
			recordLocalVarConstantVal(ctx, conditionLocal, ct, cv, true)
		else
			clearLocalConstant(ctx, conditionLocal)
		end
	end
end

local analyzeFoldExpr: (FoldConstantsCtx, number) -> (number, any)
local visitFoldStat: (FoldConstantsCtx, number) -> ()

@native
local function visitFoldExprList(ctx: FoldConstantsCtx, listId: number)
	if listId == 0 then
		return
	end
	local first = ctx.listFirsts[listId]
	local count = ctx.listCounts[listId]
	local listValues = ctx.listValues
	for i = 0, count - 1 do
		analyzeFoldExpr(ctx, listValues[first + i])
	end
end

@native
local function analyzeCallExpr(ctx: FoldConstantsCtx, _nodeId: number, node: any, bfid: number): (number, any)
	analyzeFoldExpr(ctx, node.func)
	local argsFirst = if node.args ~= 0 then ctx.listFirsts[node.args] else 0
	local argCount = if node.args ~= 0 then ctx.listCounts[node.args] else 0
	local listValues = ctx.listValues
	local resType = ConstantType.Unknown
	local resVal: any = nil
	local builtinArgTypes = ctx.builtinArgTypes
	local builtinArgVals = ctx.builtinArgVals
	local base = ctx.builtinArgTop
	ctx.builtinArgTop = base + argCount
	local allKnown = true
	for i = 0, argCount - 1 do
		local act, acv = analyzeFoldExpr(ctx, listValues[argsFirst + i])
		if act == ConstantType.Unknown or act == ConstantType.Table then
			allKnown = false
		elseif allKnown then
			builtinArgTypes[base + i + 1] = act
			builtinArgVals[base + i + 1] = acv
		end
	end
	ctx.builtinArgTop = base
	if allKnown then
		resType, resVal =
			CompilerBuiltins.foldBuiltinRaw(bfid, builtinArgTypes, builtinArgVals, argCount, ctx.vectorDouble, base)
	end
	return resType, resVal
end

@native
local function analyzeIndexNameExpr(ctx: FoldConstantsCtx, node: any): (number, any)
	local varType, varVal = analyzeFoldExpr(ctx, node.expr)
	if varType == ConstantType.Unknown then
		if ctx.foldLibraryK and ctx.kinds[node.expr] == K.AstExprGlobal then
			local gsym = ctx.nodes[node.expr].name
			local gstate = if ctx.globals ~= nil
				then (ctx.globals[gsym] or GlobalState.Default)
				else GlobalState.Default
			if gstate == GlobalState.Default then
				local symbols = ctx.symbols
				local iname = symbols[node.index]
				local gname = symbols[gsym]
				local rt: number, rv: any = ConstantType.Unknown, nil
				if gname == "math" then
					rt, rv = CompilerBuiltins.foldBuiltinMathRaw(iname)
				end
				if rt == ConstantType.Unknown and ctx.libraryMemberConstantCb then
					local rawC = ctx.libraryMemberConstantCb(gname, iname)
					local ct, cv = CompilerBuiltins.fromCompileConstantRaw(rawC, ctx.vectorDouble)
					if ct ~= ConstantType.Unknown then
						return ct, cv
					end
				end
				return rt, rv
			end
		end
		return ConstantType.Unknown, nil
	end
	local iname = ctx.symbols[node.index]
	if varType == ConstantType.Vectorf or varType == ConstantType.Vectord then
		local v = varVal :: { number }
		if iname == "x" or iname == "X" then
			return ConstantType.Number, v[1]
		elseif iname == "y" or iname == "Y" then
			return ConstantType.Number, v[2]
		elseif iname == "z" or iname == "Z" then
			return ConstantType.Number, v[3]
		end
	elseif varType == ConstantType.Table then
		local tbl = varVal :: TableConstVal
		local ft = tbl.types[iname]
		if ft ~= nil then
			return ft, tbl.vals[iname]
		end
	end
	return ConstantType.Unknown, nil
end

local EMPTY_TABLE_VAL: TableConstVal = table.freeze({
	types = table.freeze({}) :: { [string]: number },
	vals = table.freeze({}) :: { [string]: any },
	fromLibrary = false,
} :: any) :: TableConstVal

@native
local function analyzeTableExpr(ctx: FoldConstantsCtx, node: any): (number, any)
	if node.items == 0 then
		return ConstantType.Table, EMPTY_TABLE_VAL
	end
	local itemCount = ctx.listCounts[node.items]
	if itemCount == 0 then
		return ConstantType.Table, EMPTY_TABLE_VAL
	end
	local tableTypes: { [string]: number }? = nil
	local tableVals: { [string]: any }? = nil
	local uniqueKeys = 0
	local canBeConstant = true
	local first = ctx.listFirsts[node.items]
	local listValues = ctx.listValues
	for i = 0, itemCount - 1 do
		local item = listValues[first + i]
		local valType, valVal = analyzeFoldExpr(ctx, item.value)
		if item.key ~= 0 then
			local keyType, keyVal = analyzeFoldExpr(ctx, item.key)
			if
				canBeConstant
				and keyType == ConstantType.String
				and #(keyVal :: string) > 0
				and valType ~= ConstantType.Unknown
				and valType ~= ConstantType.Table
			then
				local tmap: { [string]: number }
				local vmap: { [string]: any }
				if tableTypes ~= nil then
					tmap = tableTypes
					vmap = tableVals :: { [string]: any }
				else
					tmap = {}
					vmap = {}
					tableTypes = tmap
					tableVals = vmap
				end
				local kstr = keyVal :: string
				if tmap[kstr] == nil then
					uniqueKeys += 1
				end
				tmap[kstr] = valType
				vmap[kstr] = valVal
			else
				canBeConstant = false
			end
		else
			canBeConstant = false
		end
	end
	if canBeConstant and uniqueKeys == itemCount and tableTypes ~= nil then
		local tblConst: TableConstVal = {
			types = tableTypes,
			vals = tableVals :: { [string]: any },
			fromLibrary = false,
		}
		return ConstantType.Table, tblConst
	end
	return ConstantType.Unknown, nil
end

@native
local function computeFoldExpr(ctx: FoldConstantsCtx, nodeId: number, k: number, node: any): (number, any)
	if k == K.AstExprLocal then
		local localId = node["local"]
		local lt = ctx.locstantTypes[localId]
		if lt ~= nil and lt ~= ConstantType.Unknown then
			return lt, ctx.locstantVals[localId]
		end
		if ctx.tableLocalsDirty then
			local tl = ctx.tableLocals[localId]
			if tl ~= nil then
				ctx.curFuncReadTableLocal = true
				return ConstantType.Table, tl
			end
		end
		return ConstantType.Unknown, nil
	elseif k == K.AstExprConstantNumber then
		return ConstantType.Number, node.value
	elseif k == K.AstExprConstantString then
		return ConstantType.String, node.value
	elseif k == K.AstExprIndexName then
		return analyzeIndexNameExpr(ctx, node)
	elseif k == K.AstExprCall then
		local builtinsMap = ctx.builtinsMap
		local bfid = if builtinsMap then builtinsMap[nodeId] else nil
		if bfid and bfid ~= Builtins.LBF_NONE then
			return analyzeCallExpr(ctx, nodeId, node, bfid)
		end
		analyzeFoldExpr(ctx, node.func)
		visitFoldExprList(ctx, node.args)
		return ConstantType.Unknown, nil
	elseif k == K.AstExprBinary then
		local lt, lv = analyzeFoldExpr(ctx, node.left)
		local rt, rv = analyzeFoldExpr(ctx, node.right)
		if lt ~= ConstantType.Unknown then
			local op = node.op
			if rt ~= ConstantType.Unknown or op == "And" or op == "Or" then
				return foldBinaryVal(op, lt, lv, rt, rv)
			end
		end
	elseif k == K.AstExprConstantBool then
		return ConstantType.Boolean, node.value == true
	elseif k == K.AstExprConstantNil then
		return ConstantType.Nil, false
	elseif k == K.AstExprIndexExpr then
		local vt, vv = analyzeFoldExpr(ctx, node.expr)
		local it, iv = analyzeFoldExpr(ctx, node.index)
		if vt == ConstantType.Table and it == ConstantType.String and #(iv :: string) > 0 then
			local tbl = vv :: TableConstVal
			local keyStr = iv :: string
			local ft = tbl.types[keyStr]
			if ft ~= nil then
				return ft, tbl.vals[keyStr]
			end
		end
	elseif k == K.AstExprTable then
		return analyzeTableExpr(ctx, node)
	elseif k == K.AstExprUnary then
		local at, av = analyzeFoldExpr(ctx, node.expr)
		if at ~= ConstantType.Unknown then
			return foldUnaryVal(node.op, at, av)
		end
	elseif k == K.AstExprGlobal then
		return ConstantType.Unknown, nil
	elseif k == K.AstExprFunction then
		local prevRead = ctx.curFuncReadTableLocal
		ctx.curFuncReadTableLocal = false
		visitFoldStat(ctx, node.body)
		local childRead = ctx.curFuncReadTableLocal
		if childRead and ctx.funcReadTableLocal ~= nil then
			ctx.funcReadTableLocal[nodeId] = true
		end
		ctx.curFuncReadTableLocal = prevRead or childRead
	elseif k == K.AstExprGroup or k == K.AstExprTypeAssertion or k == K.AstExprInstantiate then
		return analyzeFoldExpr(ctx, node.expr)
	elseif k == K.AstExprIfElse then
		local ct, cv = analyzeFoldExpr(ctx, node.condition)
		recordConditionLocal(ctx, node.conditionLocal, ct, cv)
		local tt, tv = analyzeFoldExpr(ctx, node.trueExpr)
		local ft, fv = analyzeFoldExpr(ctx, node.falseExpr)
		if ct ~= ConstantType.Unknown then
			if isTruthfulVal(ct, cv) then
				return tt, tv
			else
				return ft, fv
			end
		end
	elseif k == K.AstExprInterpString then
		local exprsList = node.expressions
		local strsList = node.strings
		local exprsCount = if exprsList ~= 0 then ctx.listCounts[exprsList] else 0
		local strsCount = if strsList ~= 0 then ctx.listCounts[strsList] else 0
		local exprsFirst = if exprsList ~= 0 then ctx.listFirsts[exprsList] else 0
		local listValues = ctx.listValues
		local onlyConstantSubExpr = (strsCount == exprsCount + 1)
		for i = 0, exprsCount - 1 do
			local act = analyzeFoldExpr(ctx, listValues[exprsFirst + i])
			if act ~= ConstantType.String then
				onlyConstantSubExpr = false
			end
		end
		if onlyConstantSubExpr then
			local strsFirst = ctx.listFirsts[strsList]
			local constVals = ctx.constVals
			local resultLen = 0
			for i = 0, strsCount - 1 do
				resultLen += #(listValues[strsFirst + i] :: string)
			end
			for i = 0, exprsCount - 1 do
				resultLen += #(constVals[listValues[exprsFirst + i]] :: string)
			end
			if resultLen <= 4096 then
				if resultLen == 0 then
					return ConstantType.String, ""
				elseif exprsCount == 0 then
					return ConstantType.String, listValues[strsFirst] :: string
				else
					local parts = table.create(strsCount + exprsCount)
					local p = 0
					for i = 0, exprsCount - 1 do
						p += 1
						parts[p] = listValues[strsFirst + i] :: string
						p += 1
						parts[p] = constVals[listValues[exprsFirst + i]] :: string
					end
					p += 1
					parts[p] = listValues[strsFirst + exprsCount] :: string
					return ConstantType.String, table.concat(parts)
				end
			end
		end
	elseif k == K.AstExprError then
		visitFoldExprList(ctx, node.expressions)
	end
	return ConstantType.Unknown, nil
end

@native
function analyzeFoldExpr(ctx: FoldConstantsCtx, nodeId: number): (number, any)
	if nodeId == 0 then
		return ConstantType.Unknown, nil
	end
	local k = ctx.kinds[nodeId]
	if k == nil then
		return ConstantType.Unknown, nil
	end
	if k == K.AstExprGlobal or k == K.AstExprVarargs then
		if not ctx.wasEmpty then
			local ot = ctx.constTypes[nodeId]
			if ot ~= nil and ot ~= ConstantType.Unknown then
				recordConstantValueVal(
					ctx.constTypes,
					ctx.constVals,
					ctx.exprChanges,
					nodeId,
					ConstantType.Unknown,
					nil
				)
			end
		end
		return ConstantType.Unknown, nil
	elseif k == K.AstExprConstantNil then
		if ctx.wasEmpty and not ctx.exprChanges then
			ctx.constTypes[nodeId] = ConstantType.Nil
			ctx.constVals[nodeId] = false
		else
			recordConstantValueVal(ctx.constTypes, ctx.constVals, ctx.exprChanges, nodeId, ConstantType.Nil, false)
		end
		return ConstantType.Nil, false
	end
	local node = ctx.nodes[nodeId]
	if not node then
		return ConstantType.Unknown, nil
	end
	local rt: number
	local rv: any
	if k == K.AstExprLocal then
		local localId = node["local"]
		local lt = ctx.locstantTypes[localId]
		if lt ~= nil and lt ~= ConstantType.Unknown then
			rt = lt
			rv = ctx.locstantVals[localId]
		elseif ctx.tableLocalsDirty then
			local tl = ctx.tableLocals[localId]
			if tl ~= nil then
				ctx.curFuncReadTableLocal = true
				return ConstantType.Table, tl
			end
			if not ctx.wasEmpty then
				local ot = ctx.constTypes[nodeId]
				if ot ~= nil and ot ~= ConstantType.Unknown then
					recordConstantValueVal(
						ctx.constTypes,
						ctx.constVals,
						ctx.exprChanges,
						nodeId,
						ConstantType.Unknown,
						nil
					)
				end
			end
			return ConstantType.Unknown, nil
		else
			if not ctx.wasEmpty then
				local ot = ctx.constTypes[nodeId]
				if ot ~= nil and ot ~= ConstantType.Unknown then
					recordConstantValueVal(
						ctx.constTypes,
						ctx.constVals,
						ctx.exprChanges,
						nodeId,
						ConstantType.Unknown,
						nil
					)
				end
			end
			return ConstantType.Unknown, nil
		end
	elseif k == K.AstExprConstantNumber then
		local v = node.value
		if ctx.directWrite then
			ctx.constTypes[nodeId] = ConstantType.Number
			ctx.constVals[nodeId] = v
			return ConstantType.Number, v
		end
		rt, rv = ConstantType.Number, v
	elseif k == K.AstExprConstantBool then
		local v = node.value == true
		if ctx.directWrite then
			ctx.constTypes[nodeId] = ConstantType.Boolean
			ctx.constVals[nodeId] = v
			return ConstantType.Boolean, v
		end
		rt, rv = ConstantType.Boolean, v
	elseif k == K.AstExprConstantString then
		local v = node.value
		if ctx.directWrite then
			ctx.constTypes[nodeId] = ConstantType.String
			ctx.constVals[nodeId] = v
			return ConstantType.String, v
		end
		rt, rv = ConstantType.String, v
	elseif k == K.AstExprGroup or k == K.AstExprTypeAssertion or k == K.AstExprInstantiate then
		rt, rv = analyzeFoldExpr(ctx, node.expr)
	else
		rt, rv = computeFoldExpr(ctx, nodeId, k, node)
	end
	if rt ~= ConstantType.Table then
		if rt == ConstantType.Unknown then
			if not ctx.wasEmpty then
				local ot = ctx.constTypes[nodeId]
				if ot ~= nil and ot ~= ConstantType.Unknown then
					recordConstantValueVal(ctx.constTypes, ctx.constVals, ctx.exprChanges, nodeId, rt, rv)
				end
			end
		elseif ctx.wasEmpty and not ctx.exprChanges then
			ctx.constTypes[nodeId] = rt
			ctx.constVals[nodeId] = rv
		else
			recordConstantValueVal(ctx.constTypes, ctx.constVals, ctx.exprChanges, nodeId, rt, rv)
		end
	end
	return rt, rv
end

@native
local function visitFoldStatLocal(ctx: FoldConstantsCtx, node: any)
	local listFirsts = ctx.listFirsts
	local listCounts = ctx.listCounts
	local listValues = ctx.listValues
	local varsFirst = if node.vars ~= 0 then listFirsts[node.vars] else 0
	local varsCount = if node.vars ~= 0 then listCounts[node.vars] else 0
	local valsFirst = if node.values ~= 0 then listFirsts[node.values] else 0
	local valsCount = if node.values ~= 0 then listCounts[node.values] else 0

	local vars = ctx.variables
	local varOwner = vars.owner
	local varWritten = vars.written
	local bound = if varsCount < valsCount then varsCount else valsCount
	for i = 0, bound - 1 do
		local varId = listValues[varsFirst + i]
		local valId = listValues[valsFirst + i]
		local ct, cv = analyzeFoldExpr(ctx, valId)
		if varOwner[varId] ~= nil and not varWritten[varId] then
			if ct == ConstantType.Table then
				clearLocalConstant(ctx, varId)
				if ctx.tableConstants[varId] == TableConstantKind.ConstantTable then
					ctx.tableLocals[varId] = cv :: TableConstVal
					ctx.tableLocalsDirty = true
				end
			elseif ct ~= ConstantType.Unknown then
				recordLocalVarConstantVal(ctx, varId, ct, cv, true)
			else
				clearLocalConstant(ctx, varId)
			end
		end
	end

	if varsCount > valsCount then
		local lastExpr = if valsCount > 0 then listValues[valsFirst + valsCount - 1] else 0
		local lastKind = if lastExpr ~= 0 then ctx.kinds[lastExpr] else 0
		if valsCount == 0 or (lastKind ~= K.AstExprCall and lastKind ~= K.AstExprVarargs) then
			for i = valsCount, varsCount - 1 do
				local varId = listValues[varsFirst + i]
				if varOwner[varId] ~= nil and not varWritten[varId] then
					recordLocalVarConstantVal(ctx, varId, ConstantType.Nil, false, true)
				end
			end
		end
	else
		for i = varsCount, valsCount - 1 do
			analyzeFoldExpr(ctx, listValues[valsFirst + i])
		end
	end
end

@native
function visitFoldStat(ctx: FoldConstantsCtx, nodeId: number)
	if nodeId == 0 then
		return
	end
	local k = ctx.kinds[nodeId]
	if k == nil or k == K.AstStatBreak or k == K.AstStatContinue or k == K.AstStatTypeAlias then
		return
	end
	local nodes = ctx.nodes
	local node = nodes[nodeId]
	if not node then
		return
	end
	local listFirsts = ctx.listFirsts
	local listCounts = ctx.listCounts
	local listValues = ctx.listValues
	if k == K.AstStatBlock then
		if node.body ~= 0 then
			local first = listFirsts[node.body]
			local count = listCounts[node.body]
			for i = 0, count - 1 do
				visitFoldStat(ctx, listValues[first + i])
			end
		end
	elseif k == K.AstStatIf then
		local ct, cv = analyzeFoldExpr(ctx, node.condition)
		if node.conditionLocal and node.conditionLocal ~= 0 then
			recordConditionLocal(ctx, node.conditionLocal, ct, cv)
		end
		visitFoldStat(ctx, node.thenbody)
		if node.elsebody ~= 0 then
			visitFoldStat(ctx, node.elsebody)
		end
	elseif k == K.AstStatWhile then
		analyzeFoldExpr(ctx, node.condition)
		visitFoldStat(ctx, node.body)
	elseif k == K.AstStatRepeat then
		visitFoldStat(ctx, node.body)
		analyzeFoldExpr(ctx, node.condition)
	elseif k == K.AstStatReturn then
		visitFoldExprList(ctx, node.list)
	elseif k == K.AstStatExpr then
		analyzeFoldExpr(ctx, node.expr)
	elseif k == K.AstStatLocal then
		visitFoldStatLocal(ctx, node)
	elseif k == K.AstStatFor then
		analyzeFoldExpr(ctx, node.from)
		analyzeFoldExpr(ctx, node.to)
		if node.step ~= 0 then
			analyzeFoldExpr(ctx, node.step)
		end
		visitFoldStat(ctx, node.body)
	elseif k == K.AstStatForIn then
		visitFoldExprList(ctx, node.values)
		visitFoldStat(ctx, node.body)
	elseif k == K.AstStatAssign then
		visitFoldExprList(ctx, node.vars)
		visitFoldExprList(ctx, node.values)
	elseif k == K.AstStatCompoundAssign then
		analyzeFoldExpr(ctx, node.var)
		analyzeFoldExpr(ctx, node.value)
	elseif k == K.AstStatFunction then
		analyzeFoldExpr(ctx, node.name)
		analyzeFoldExpr(ctx, node.func)
	elseif k == K.AstStatLocalFunction then
		analyzeFoldExpr(ctx, node.func)
	elseif k == K.AstStatClass then
		if node.super ~= 0 then
			analyzeFoldExpr(ctx, node.super)
		end
		if node.members ~= 0 then
			local first = listFirsts[node.members]
			local count = listCounts[node.members]
			local kinds = ctx.kinds
			for i = 0, count - 1 do
				local mId = listValues[first + i]
				if kinds[mId] == K.AstClassMethod then
					analyzeFoldExpr(ctx, nodes[mId]["function"])
				end
			end
		end
	elseif k == K.AstStatError then
		visitFoldExprList(ctx, node.expressions)
		if node.statements ~= 0 then
			local first = listFirsts[node.statements]
			local count = listCounts[node.statements]
			for i = 0, count - 1 do
				visitFoldStat(ctx, listValues[first + i])
			end
		end
	end
end

local borrowedFoldCtx: FoldConstantsCtx? = nil
local foldCtxInUse = false
local EMPTY_FOLD_ANY: any = table.freeze({})

local function foldConstants(
	arena: Arena.ArenaImpl,
	constTypes: { [number]: number },
	constVals: { [number]: any },
	variables: VariableTable,
	locstantTypes: { [number]: number },
	locstantVals: { [number]: any },
	builtinsMap: { [number]: number }?,
	foldLibraryK: any,
	vectorDouble: boolean,
	libraryMemberConstantCb: ((string, string) -> any)?,
	rootId: number,
	tableConstants: { [number]: number },
	flags: any,
	exprChanges: ChangeStack?,
	localChanges: ChangeStack?,
	funcReadTableLocal: { [number]: boolean }?,
	globals: { [number]: number }?
)
	local wasEmpty = next(constTypes) == nil and next(locstantTypes) == nil
	local borrow = not foldCtxInUse
	local ctx: FoldConstantsCtx
	if borrow and borrowedFoldCtx ~= nil then
		foldCtxInUse = true
		ctx = borrowedFoldCtx
		ctx.arena = arena
		ctx.nodes = arena.nodes
		ctx.kinds = arena.kinds
		ctx.listFirsts = arena.listFirsts
		ctx.listCounts = arena.listCounts
		ctx.listValues = arena.listValues
		ctx.symbols = arena.symbols
		ctx.bindings = arena.bindings
		ctx.constTypes = constTypes
		ctx.constVals = constVals
		ctx.variables = variables
		ctx.locstantTypes = locstantTypes
		ctx.locstantVals = locstantVals
		ctx.builtinsMap = builtinsMap
		ctx.foldLibraryK = foldLibraryK
		ctx.vectorDouble = vectorDouble
		ctx.libraryMemberConstantCb = libraryMemberConstantCb
		ctx.tableConstants = tableConstants
		if ctx.tableLocalsDirty then
			table.clear(ctx.tableLocals)
			ctx.tableLocalsDirty = false
		end
		ctx.flags = flags
		ctx.exprChanges = exprChanges
		ctx.localChanges = localChanges
		ctx.wasEmpty = wasEmpty
		ctx.directWrite = wasEmpty and exprChanges == nil
		ctx.builtinArgTop = 0
		ctx.funcReadTableLocal = funcReadTableLocal
		ctx.curFuncReadTableLocal = false
		ctx.globals = globals
	else
		if borrow then
			foldCtxInUse = true
		end
		local newCtx: FoldConstantsCtx = {
			arena = arena,
			nodes = arena.nodes,
			kinds = arena.kinds,
			listFirsts = arena.listFirsts,
			listCounts = arena.listCounts,
			listValues = arena.listValues,
			symbols = arena.symbols,
			bindings = arena.bindings,
			constTypes = constTypes,
			constVals = constVals,
			variables = variables,
			locstantTypes = locstantTypes,
			locstantVals = locstantVals,
			builtinsMap = builtinsMap,
			foldLibraryK = foldLibraryK,
			vectorDouble = vectorDouble,
			libraryMemberConstantCb = libraryMemberConstantCb,
			tableConstants = tableConstants,
			tableLocals = {},
			tableLocalsDirty = false,
			flags = flags,
			exprChanges = exprChanges,
			localChanges = localChanges,
			wasEmpty = wasEmpty,
			directWrite = wasEmpty and exprChanges == nil,
			builtinArgTypes = {},
			builtinArgVals = {},
			builtinArgTop = 0,
			funcReadTableLocal = funcReadTableLocal,
			curFuncReadTableLocal = false,
			globals = globals,
		}
		if borrow then
			borrowedFoldCtx = newCtx
		end
		ctx = newCtx
	end
	local okFold, foldErr = pcall(visitFoldStat :: any, ctx, rootId)
	if ctx.tableLocalsDirty then
		table.clear(ctx.tableLocals)
		ctx.tableLocalsDirty = false
	end
	if #ctx.builtinArgVals > 0 then
		table.clear(ctx.builtinArgVals)
		ctx.builtinArgTop = 0
	end
	if borrow then
		foldCtxInUse = false
	end
	if not okFold then
		error(foldErr, 0)
	end
end

local function releaseFoldScratch()
	foldCtxInUse = false
	local c = borrowedFoldCtx :: any
	if c ~= nil then
		c.arena = EMPTY_FOLD_ANY
		c.nodes = EMPTY_FOLD_ANY
		c.kinds = EMPTY_FOLD_ANY
		c.listFirsts = EMPTY_FOLD_ANY
		c.listCounts = EMPTY_FOLD_ANY
		c.listValues = EMPTY_FOLD_ANY
		c.symbols = EMPTY_FOLD_ANY
		c.bindings = EMPTY_FOLD_ANY
		c.constTypes = EMPTY_FOLD_ANY
		c.constVals = EMPTY_FOLD_ANY
		c.variables = EMPTY_FOLD_ANY
		c.locstantTypes = EMPTY_FOLD_ANY
		c.locstantVals = EMPTY_FOLD_ANY
		c.builtinsMap = nil
		c.foldLibraryK = nil
		c.libraryMemberConstantCb = nil
		c.tableConstants = EMPTY_FOLD_ANY
		c.flags = EMPTY_FOLD_ANY
		c.exprChanges = nil
		c.localChanges = nil
		if #c.builtinArgTypes > 0 then
			table.clear(c.builtinArgTypes)
		end
		if #c.builtinArgVals > 0 then
			table.clear(c.builtinArgVals)
		end
		c.builtinArgTop = 0
		c.funcReadTableLocal = nil
		c.curFuncReadTableLocal = false
		c.globals = nil
	end
end

return table.freeze({
	TableConstantKind = TableConstantKind,
	createVariables = createVariables,
	clearVariables = clearVariables,
	createChangeStack = createChangeStack,
	isTruthfulVal = isTruthfulVal,
	isConstantTrue = isConstantTrue,
	isConstantFalse = isConstantFalse,
	alwaysTerminates = alwaysTerminates,
	unwrapExprOfType = unwrapExprOfType,
	assignMutable = assignMutable,
	trackValuesAndAnalyzeO1 = trackValuesAndAnalyzeO1,
	undoChanges = undoChanges,
	foldConstants = foldConstants,
	releaseFoldScratch = releaseFoldScratch,
})
