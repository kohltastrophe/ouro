--!strict
-- Luau 0.748 Types and CostModel port.
-- Upstream Luau is MIT licensed; see ../LICENSE.md and ../UPSTREAM.json.
local Arena = require("./Arena")
local BytecodeDefs = require("./BytecodeDefs")
local CompilerBuiltins = require("./CompilerBuiltins")
local CompilerFolding = require("./CompilerFolding")

local K = Arena.Kinds
local Types = BytecodeDefs.Types
local Builtins = BytecodeDefs.Builtins
local ConstantType = CompilerBuiltins.ConstantType
local GlobalState = CompilerBuiltins.GlobalState

export type Constant = CompilerBuiltins.Constant

-- Synthetic node IDs representing BuiltinAstTypes (never match AstStatTypeAlias by symbol ID).
local BUILTIN_BOOLEAN = -1
local BUILTIN_NUMBER = -2
local BUILTIN_STRING = -4
local BUILTIN_VECTOR = -5

local BUILTIN_BYTECODE_TYPES: { number } = table.freeze({
	Types.LBC_TYPE_BOOLEAN,
	Types.LBC_TYPE_NUMBER,
	Types.LBC_TYPE_ANY,
	Types.LBC_TYPE_STRING,
	Types.LBC_TYPE_VECTOR,
})

local PRIMITIVE_TYPES: { [string]: number } = table.freeze({
	["nil"] = Types.LBC_TYPE_NIL,
	["boolean"] = Types.LBC_TYPE_BOOLEAN,
	["number"] = Types.LBC_TYPE_NUMBER,
	["string"] = Types.LBC_TYPE_STRING,
	["thread"] = Types.LBC_TYPE_THREAD,
	["buffer"] = Types.LBC_TYPE_BUFFER,
	["vector"] = Types.LBC_TYPE_VECTOR,
	["any"] = Types.LBC_TYPE_ANY,
	["unknown"] = Types.LBC_TYPE_ANY,
} :: { [string]: number })

local BINARY_COMPARISON_OPS: { [string]: boolean } = table.freeze({
	["CompareNe"] = true,
	["CompareEq"] = true,
	["CompareLt"] = true,
	["CompareLe"] = true,
	["CompareGt"] = true,
	["CompareGe"] = true,
} :: { [string]: boolean })

local BUILTIN_RETURN_TYPES: { [number]: number } = table.freeze({
	[Builtins.LBF_MATH_ABS] = BUILTIN_NUMBER,
	[Builtins.LBF_MATH_ACOS] = BUILTIN_NUMBER,
	[Builtins.LBF_MATH_ASIN] = BUILTIN_NUMBER,
	[Builtins.LBF_MATH_ATAN2] = BUILTIN_NUMBER,
	[Builtins.LBF_MATH_ATAN] = BUILTIN_NUMBER,
	[Builtins.LBF_MATH_CEIL] = BUILTIN_NUMBER,
	[Builtins.LBF_MATH_COSH] = BUILTIN_NUMBER,
	[Builtins.LBF_MATH_COS] = BUILTIN_NUMBER,
	[Builtins.LBF_MATH_DEG] = BUILTIN_NUMBER,
	[Builtins.LBF_MATH_EXP] = BUILTIN_NUMBER,
	[Builtins.LBF_MATH_FLOOR] = BUILTIN_NUMBER,
	[Builtins.LBF_MATH_FMOD] = BUILTIN_NUMBER,
	[Builtins.LBF_MATH_FREXP] = BUILTIN_NUMBER,
	[Builtins.LBF_MATH_LDEXP] = BUILTIN_NUMBER,
	[Builtins.LBF_MATH_LOG10] = BUILTIN_NUMBER,
	[Builtins.LBF_MATH_LOG] = BUILTIN_NUMBER,
	[Builtins.LBF_MATH_MAX] = BUILTIN_NUMBER,
	[Builtins.LBF_MATH_MIN] = BUILTIN_NUMBER,
	[Builtins.LBF_MATH_MODF] = BUILTIN_NUMBER,
	[Builtins.LBF_MATH_POW] = BUILTIN_NUMBER,
	[Builtins.LBF_MATH_RAD] = BUILTIN_NUMBER,
	[Builtins.LBF_MATH_SINH] = BUILTIN_NUMBER,
	[Builtins.LBF_MATH_SIN] = BUILTIN_NUMBER,
	[Builtins.LBF_MATH_SQRT] = BUILTIN_NUMBER,
	[Builtins.LBF_MATH_TANH] = BUILTIN_NUMBER,
	[Builtins.LBF_MATH_TAN] = BUILTIN_NUMBER,
	[Builtins.LBF_BIT32_ARSHIFT] = BUILTIN_NUMBER,
	[Builtins.LBF_BIT32_BAND] = BUILTIN_NUMBER,
	[Builtins.LBF_BIT32_BNOT] = BUILTIN_NUMBER,
	[Builtins.LBF_BIT32_BOR] = BUILTIN_NUMBER,
	[Builtins.LBF_BIT32_BXOR] = BUILTIN_NUMBER,
	[Builtins.LBF_BIT32_BTEST] = BUILTIN_NUMBER,
	[Builtins.LBF_BIT32_EXTRACT] = BUILTIN_NUMBER,
	[Builtins.LBF_BIT32_LROTATE] = BUILTIN_NUMBER,
	[Builtins.LBF_BIT32_LSHIFT] = BUILTIN_NUMBER,
	[Builtins.LBF_BIT32_REPLACE] = BUILTIN_NUMBER,
	[Builtins.LBF_BIT32_RROTATE] = BUILTIN_NUMBER,
	[Builtins.LBF_BIT32_RSHIFT] = BUILTIN_NUMBER,
	[Builtins.LBF_STRING_BYTE] = BUILTIN_NUMBER,
	[Builtins.LBF_STRING_LEN] = BUILTIN_NUMBER,
	[Builtins.LBF_MATH_CLAMP] = BUILTIN_NUMBER,
	[Builtins.LBF_MATH_SIGN] = BUILTIN_NUMBER,
	[Builtins.LBF_MATH_ROUND] = BUILTIN_NUMBER,
	[Builtins.LBF_BIT32_COUNTLZ] = BUILTIN_NUMBER,
	[Builtins.LBF_BIT32_COUNTRZ] = BUILTIN_NUMBER,
	[Builtins.LBF_RAWLEN] = BUILTIN_NUMBER,
	[Builtins.LBF_BIT32_EXTRACTK] = BUILTIN_NUMBER,
	[Builtins.LBF_TONUMBER] = BUILTIN_NUMBER,
	[Builtins.LBF_BIT32_BYTESWAP] = BUILTIN_NUMBER,
	[Builtins.LBF_BUFFER_READI8] = BUILTIN_NUMBER,
	[Builtins.LBF_BUFFER_READU8] = BUILTIN_NUMBER,
	[Builtins.LBF_BUFFER_READI16] = BUILTIN_NUMBER,
	[Builtins.LBF_BUFFER_READU16] = BUILTIN_NUMBER,
	[Builtins.LBF_BUFFER_READI32] = BUILTIN_NUMBER,
	[Builtins.LBF_BUFFER_READU32] = BUILTIN_NUMBER,
	[Builtins.LBF_BUFFER_READF32] = BUILTIN_NUMBER,
	[Builtins.LBF_BUFFER_READF64] = BUILTIN_NUMBER,
	[Builtins.LBF_VECTOR_MAGNITUDE] = BUILTIN_NUMBER,
	[Builtins.LBF_VECTOR_DOT] = BUILTIN_NUMBER,
	[Builtins.LBF_MATH_LERP] = BUILTIN_NUMBER,

	[Builtins.LBF_TYPE] = BUILTIN_STRING,
	[Builtins.LBF_STRING_CHAR] = BUILTIN_STRING,
	[Builtins.LBF_TYPEOF] = BUILTIN_STRING,
	[Builtins.LBF_STRING_SUB] = BUILTIN_STRING,
	[Builtins.LBF_TOSTRING] = BUILTIN_STRING,

	[Builtins.LBF_MATH_ISNAN] = BUILTIN_BOOLEAN,
	[Builtins.LBF_MATH_ISINF] = BUILTIN_BOOLEAN,
	[Builtins.LBF_MATH_ISFINITE] = BUILTIN_BOOLEAN,
	[Builtins.LBF_RAWEQUAL] = BUILTIN_BOOLEAN,

	[Builtins.LBF_VECTOR] = BUILTIN_VECTOR,
	[Builtins.LBF_VECTOR_NORMALIZE] = BUILTIN_VECTOR,
	[Builtins.LBF_VECTOR_CROSS] = BUILTIN_VECTOR,
	[Builtins.LBF_VECTOR_FLOOR] = BUILTIN_VECTOR,
	[Builtins.LBF_VECTOR_CEIL] = BUILTIN_VECTOR,
	[Builtins.LBF_VECTOR_ABS] = BUILTIN_VECTOR,
	[Builtins.LBF_VECTOR_SIGN] = BUILTIN_VECTOR,
	[Builtins.LBF_VECTOR_CLAMP] = BUILTIN_VECTOR,
	[Builtins.LBF_VECTOR_MIN] = BUILTIN_VECTOR,
	[Builtins.LBF_VECTOR_MAX] = BUILTIN_VECTOR,
	[Builtins.LBF_VECTOR_LERP] = BUILTIN_VECTOR,
	[Builtins.LBF_BUFFER_READVECTORF32X2] = BUILTIN_VECTOR,
	[Builtins.LBF_BUFFER_READVECTORF32X3] = BUILTIN_VECTOR,
	[Builtins.LBF_BUFFER_READVECTORF32X4] = BUILTIN_VECTOR,
})

type TypeMapCtx = {
	arena: Arena.ArenaImpl,
	nodes: { [number]: any },
	kinds: { number },
	listFirsts: { number },
	listCounts: { number },
	listValues: { [number]: any },
	bindings: { [number]: any },
	symbols: { [number]: string },
	functionTypes: { [number]: string },
	localTypes: { [number]: number },
	exprTypes: { [number]: number },
	hostVectorType: string?,
	userdataTypes: { [string]: number },
	builtinCalls: { [number]: number },
	globals: { [number]: number },
	libraryMemberTypeCb: ((string, string) -> number)?,
	bytecode: any,
	hasTypeAliases: boolean,
	hasTypeAnnotations: boolean,
	typeAliases: { [number]: number },
	typeAliasStackNames: { number },
	typeAliasStackPrev: { number },
	resolvedLocals: { [number]: number },
	resolvedExprs: { [number]: number },
	resolvedTypeBcCache: { [number]: number },
	functionReturnTypes: { [number]: number },
	seenAliases: { [number]: boolean },
	vectorSym: number?,
	zeroSym: number?,
	oneSym: number?,
	ipairsSym: number?,
	pairsSym: number?,
	compX: number?,
	compY: number?,
	compZ: number?,
	compXU: number?,
	compYU: number?,
	compZU: number?,
}

@native
local function resolveNonAliasTypeReference(ctx: TypeMapCtx, ty: any, genericsListId: number): number
	if genericsListId ~= 0 and Arena.listHasProp(ctx.arena, genericsListId, "name", ty.name) then
		return Types.LBC_TYPE_ANY
	end

	local nameStr = ctx.symbols[ty.name]
	if ctx.hostVectorType and nameStr == ctx.hostVectorType then
		return Types.LBC_TYPE_VECTOR
	end

	local prim = PRIMITIVE_TYPES[nameStr]
	if prim ~= nil then
		return prim
	end

	local userdataIndex = ctx.userdataTypes[nameStr]
	if userdataIndex ~= nil then
		ctx.bytecode:useUserdataType(userdataIndex)
		return Types.LBC_TYPE_TAGGED_USERDATA_BASE + userdataIndex
	end

	return Types.LBC_TYPE_USERDATA
end

@native
local function getType(
	ctx: TypeMapCtx,
	tyId: number,
	genericsListId: number,
	seenAliases: { [number]: boolean }
): number
	if tyId < 0 then
		return BUILTIN_BYTECODE_TYPES[-tyId] or Types.LBC_TYPE_ANY
	elseif tyId == 0 then
		return Types.LBC_TYPE_ANY
	end

	local k = ctx.kinds[tyId]
	if k == nil then
		return Types.LBC_TYPE_ANY
	end
	local nodes = ctx.nodes
	local ty = nodes[tyId]

	if k == K.AstTypeReference then
		if ty.prefix ~= 0 then
			return Types.LBC_TYPE_ANY
		end
		if ctx.hasTypeAliases then
			local aliasId = ctx.typeAliases[ty.name]
			if aliasId and aliasId ~= 0 then
				local aliasNode = nodes[aliasId]
				if seenAliases[aliasNode.name] then
					return Types.LBC_TYPE_ANY
				end
				seenAliases[ty.name] = true
				local resolved = getType(ctx, aliasNode.type, aliasNode.generics, seenAliases)
				seenAliases[ty.name] = nil
				return resolved
			end
		end
		return resolveNonAliasTypeReference(ctx, ty, genericsListId)
	elseif k == K.AstTypeTable then
		return Types.LBC_TYPE_TABLE
	elseif k == K.AstTypeFunction then
		return Types.LBC_TYPE_FUNCTION
	elseif k == K.AstTypeUnion then
		local optional = false
		local resolvedType = Types.LBC_TYPE_INVALID
		if ty.types ~= 0 then
			local first = ctx.listFirsts[ty.types]
			local count = ctx.listCounts[ty.types]
			local listValues = ctx.listValues
			for i = 0, count - 1 do
				local et = getType(ctx, listValues[first + i], genericsListId, seenAliases)
				if et == Types.LBC_TYPE_NIL then
					optional = true
				elseif resolvedType == Types.LBC_TYPE_INVALID then
					resolvedType = et
				elseif resolvedType ~= et then
					return Types.LBC_TYPE_ANY
				end
			end
		end
		if resolvedType == Types.LBC_TYPE_INVALID then
			return Types.LBC_TYPE_ANY
		end
		return bit32.bor(
			resolvedType,
			if optional and resolvedType ~= Types.LBC_TYPE_ANY then Types.LBC_TYPE_OPTIONAL_BIT else 0
		)
	elseif k == K.AstTypeIntersection then
		return Types.LBC_TYPE_ANY
	elseif k == K.AstTypeGroup then
		return getType(ctx, ty.type, genericsListId, seenAliases)
	elseif k == K.AstTypeOptional then
		return Types.LBC_TYPE_NIL
	elseif k == K.AstTypeSingletonBool then
		return Types.LBC_TYPE_BOOLEAN
	elseif k == K.AstTypeSingletonString then
		return Types.LBC_TYPE_STRING
	end

	return Types.LBC_TYPE_ANY
end

local typeScratchBuf = buffer.create(64)
local typeScratchCap = 64

@native
local function getFunctionType(ctx: TypeMapCtx, funcNode: any): string
	if not ctx.hasTypeAnnotations or funcNode.args == 0 then
		return ""
	end
	local argsFirst = ctx.listFirsts[funcNode.args]
	local argsCount = ctx.listCounts[funcNode.args]
	if argsCount == 0 then
		return ""
	end
	local listValues = ctx.listValues
	local bindings = ctx.bindings
	local anyAnnotated = false
	for i = 0, argsCount - 1 do
		if bindings[listValues[argsFirst + i]].annotation ~= 0 then
			anyAnnotated = true
			break
		end
	end
	if not anyAnnotated then
		return ""
	end

	local hasSelf = funcNode.self ~= 0
	local totalBytes = argsCount + (if hasSelf then 3 else 2)
	if totalBytes > typeScratchCap then
		while totalBytes > typeScratchCap do
			typeScratchCap *= 2
		end
		typeScratchBuf = buffer.create(typeScratchCap)
	end

	local buf = typeScratchBuf
	buffer.writeu8(buf, 0, Types.LBC_TYPE_FUNCTION)
	buffer.writeu8(buf, 1, bit32.band((if hasSelf then 1 else 0) + argsCount, 0xff))
	local pos = 2
	if hasSelf then
		buffer.writeu8(buf, 2, Types.LBC_TYPE_TABLE)
		pos = 3
	end

	local haveNonAnyParam = false
	local seenAliases = ctx.seenAliases
	local hasAliases = ctx.hasTypeAliases
	for i = 0, argsCount - 1 do
		local argBinding = bindings[listValues[argsFirst + i]]
		local ty = Types.LBC_TYPE_ANY
		if argBinding.annotation ~= 0 then
			if hasAliases then
				table.clear(seenAliases)
			end
			ty = getType(ctx, argBinding.annotation, funcNode.generics, seenAliases)
		end
		if ty ~= Types.LBC_TYPE_ANY then
			haveNonAnyParam = true
		end
		buffer.writeu8(buf, pos, ty)
		pos += 1
	end

	if not haveNonAnyParam then
		return ""
	end
	return buffer.readstring(buf, 0, pos)
end

@native
local function pushTypeAliases(ctx: TypeMapCtx, blockId: number): number
	local names = ctx.typeAliasStackNames
	local prevs = ctx.typeAliasStackPrev
	local typeAliases = ctx.typeAliases
	local nodes = ctx.nodes
	local kinds = ctx.kinds
	local aliasStackTop = #names
	local blockNode = nodes[blockId]
	if blockNode and blockNode.body ~= 0 then
		local first = ctx.listFirsts[blockNode.body]
		local count = ctx.listCounts[blockNode.body]
		local listValues = ctx.listValues
		for i = 0, count - 1 do
			local statId = listValues[first + i]
			if kinds[statId] == K.AstStatTypeAlias then
				local stat = nodes[statId]
				local prevAlias = typeAliases[stat.name] or 0
				names[#names + 1] = stat.name
				prevs[#prevs + 1] = prevAlias
				typeAliases[stat.name] = statId
			end
		end
	end
	return aliasStackTop
end

@native
local function popTypeAliases(ctx: TypeMapCtx, aliasStackTop: number)
	local names = ctx.typeAliasStackNames
	local prevs = ctx.typeAliasStackPrev
	local typeAliases = ctx.typeAliases
	while #names > aliasStackTop do
		local topIdx = #names
		local nameSym = names[topIdx]
		local prevAlias = prevs[topIdx]
		typeAliases[nameSym] = prevAlias
		names[topIdx] = nil
		prevs[topIdx] = nil
	end
end

@native
local function resolveAliases_DEPRECATED(ctx: TypeMapCtx, tyId: number): number
	if tyId <= 0 then
		return tyId
	end
	if ctx.kinds[tyId] == K.AstTypeReference then
		local nodes = ctx.nodes
		local ty = nodes[tyId]
		if ty.prefix ~= 0 then
			return tyId
		end
		local aliasId = ctx.typeAliases[ty.name]
		if aliasId and aliasId ~= 0 then
			return nodes[aliasId].type
		end
	end
	return tyId
end

@native
local function tryGetTableIndexer(ctx: TypeMapCtx, exprId: number): any?
	local resolvedTyId = ctx.resolvedExprs[exprId]
	if resolvedTyId and resolvedTyId > 0 then
		if ctx.kinds[resolvedTyId] == K.AstTypeTable then
			local nodes = ctx.nodes
			local tableTy = nodes[resolvedTyId]
			if tableTy.indexer ~= 0 then
				return nodes[tableTy.indexer]
			end
		end
	end
	return nil
end

@native
local function recordResolvedType(
	ctx: TypeMapCtx,
	resolvedMap: { [number]: number },
	typeMap: { [number]: number },
	id: number,
	tyId: number,
	writeAny: boolean
): number
	if tyId == 0 then
		return Types.LBC_TYPE_ANY
	end
	local bty: number
	if tyId < 0 then
		bty = BUILTIN_BYTECODE_TYPES[-tyId] or Types.LBC_TYPE_ANY
		resolvedMap[id] = tyId
	else
		if ctx.hasTypeAliases then
			tyId = resolveAliases_DEPRECATED(ctx, tyId)
			table.clear(ctx.seenAliases)
			resolvedMap[id] = tyId
			bty = getType(ctx, tyId, 0, ctx.seenAliases)
		else
			resolvedMap[id] = tyId
			local cache = ctx.resolvedTypeBcCache
			local cached = cache[tyId]
			if cached ~= nil then
				bty = cached
			else
				bty = getType(ctx, tyId, 0, ctx.seenAliases)
				cache[tyId] = bty
			end
		end
	end
	if writeAny or bty ~= Types.LBC_TYPE_ANY then
		typeMap[id] = bty
	end
	return bty
end

@native
local function recordResolvedExprType(ctx: TypeMapCtx, exprId: number, tyId: number): number
	return recordResolvedType(ctx, ctx.resolvedExprs, ctx.exprTypes, exprId, tyId, true)
end

@native
local function recordResolvedLocalType(ctx: TypeMapCtx, localId: number, tyId: number): number
	return recordResolvedType(ctx, ctx.resolvedLocals, ctx.localTypes, localId, tyId, false)
end

@native
local function recordConditionLocalType(ctx: TypeMapCtx, node: any)
	if node.conditionLocal and node.conditionLocal ~= 0 and ctx.bindings[node.conditionLocal].annotation == 0 then
		local condTyId = ctx.resolvedExprs[node.condition]
		if condTyId ~= nil then
			ctx.resolvedLocals[node.conditionLocal] = condTyId
		end
	end
end

local visitTypeStat: (TypeMapCtx, number) -> ()
local visitTypeExpr: (TypeMapCtx, number) -> ()

@native
local function visitTypeExprList(ctx: TypeMapCtx, listId: number)
	if listId == 0 then
		return
	end
	local first = ctx.listFirsts[listId]
	local count = ctx.listCounts[listId]
	local listValues = ctx.listValues
	for i = 0, count - 1 do
		visitTypeExpr(ctx, listValues[first + i])
	end
end

local BYTECODE_TO_BUILTIN_TY: { [number]: number } = table.freeze({
	[Types.LBC_TYPE_BOOLEAN] = BUILTIN_BOOLEAN,
	[Types.LBC_TYPE_NUMBER] = BUILTIN_NUMBER,
	[Types.LBC_TYPE_STRING] = BUILTIN_STRING,
	[Types.LBC_TYPE_VECTOR] = BUILTIN_VECTOR,
})

@native
local function visitTypeExprIndexName(ctx: TypeMapCtx, nodeId: number, node: any)
	visitTypeExpr(ctx, node.expr)
	local nodes = ctx.nodes
	local kinds = ctx.kinds
	local symbols = ctx.symbols
	local idxSym = node.index
	local exprResolvedTyId = ctx.resolvedExprs[node.expr]
	if exprResolvedTyId and exprResolvedTyId > 0 then
		if kinds[exprResolvedTyId] == K.AstTypeTable then
			local tableTy = nodes[exprResolvedTyId]
			if tableTy.props ~= 0 then
				local first = ctx.listFirsts[tableTy.props]
				local count = ctx.listCounts[tableTy.props]
				local listValues = ctx.listValues
				for i = 0, count - 1 do
					local prop = nodes[listValues[first + i]]
					if prop.name == idxSym then
						recordResolvedExprType(ctx, nodeId, prop.type)
						return
					end
				end
			end
		end
	end

	local exprBcType = ctx.exprTypes[node.expr]
	if exprBcType == Types.LBC_TYPE_VECTOR then
		if
			idxSym == ctx.compX
			or idxSym == ctx.compY
			or idxSym == ctx.compZ
			or idxSym == ctx.compXU
			or idxSym == ctx.compYU
			or idxSym == ctx.compZU
		then
			ctx.resolvedExprs[nodeId] = BUILTIN_NUMBER
			ctx.exprTypes[nodeId] = Types.LBC_TYPE_NUMBER
			return
		end
	end

	local cb = ctx.libraryMemberTypeCb
	if (cb ~= nil or ctx.vectorSym ~= nil) and kinds[node.expr] == K.AstExprGlobal then
		local object = nodes[node.expr]
		if
			object.name == ctx.vectorSym
			and (idxSym == ctx.zeroSym or idxSym == ctx.oneSym)
			and (ctx.globals[object.name] or GlobalState.Default) == GlobalState.Default
		then
			ctx.resolvedExprs[nodeId] = BUILTIN_VECTOR
			ctx.exprTypes[nodeId] = Types.LBC_TYPE_VECTOR
			return
		end
		if cb and (ctx.globals[object.name] or GlobalState.Default) == GlobalState.Default then
			local ty = cb(symbols[object.name], symbols[idxSym])
			if type(ty) == "number" and ty >= 0 and ty <= 255 and math.floor(ty) == ty then
				if ty ~= Types.LBC_TYPE_ANY and ty ~= Types.LBC_TYPE_INTEGER_DEPRECATED then
					if
						ty >= Types.LBC_TYPE_TAGGED_USERDATA_BASE
						and ty < Types.LBC_TYPE_TAGGED_USERDATA_END
						and ctx.bytecode
					then
						local udIdx = ty - Types.LBC_TYPE_TAGGED_USERDATA_BASE
						if udIdx + 1 <= #ctx.bytecode.userdataTypes then
							ctx.bytecode:useUserdataType(udIdx)
						end
					end
					local builtinTy = BYTECODE_TO_BUILTIN_TY[ty]
					if builtinTy then
						ctx.resolvedExprs[nodeId] = builtinTy
					end
					ctx.exprTypes[nodeId] = ty
					return
				end
			end
		end
	end
end

@native
local function visitTypeExprBinary(ctx: TypeMapCtx, nodeId: number, node: any)
	visitTypeExpr(ctx, node.left)
	visitTypeExpr(ctx, node.right)
	local op = node.op
	if BINARY_COMPARISON_OPS[op] then
		ctx.resolvedExprs[nodeId] = BUILTIN_BOOLEAN
		ctx.exprTypes[nodeId] = Types.LBC_TYPE_BOOLEAN
		return
	end
	if op == "Concat" or op == "And" or op == "Or" then
		return
	end
	local leftTyId = ctx.resolvedExprs[node.left]
	local leftBcTy = ctx.exprTypes[node.left]
	local rightTyId = ctx.resolvedExprs[node.right]
	local rightBcTy = ctx.exprTypes[node.right]
	if leftTyId == nil or leftBcTy == nil or rightTyId == nil or rightBcTy == nil then
		return
	end
	if
		leftBcTy == Types.LBC_TYPE_VECTOR
		or (leftBcTy == Types.LBC_TYPE_NUMBER and rightBcTy == Types.LBC_TYPE_NUMBER)
	then
		recordResolvedExprType(ctx, nodeId, leftTyId)
	elseif rightBcTy == Types.LBC_TYPE_VECTOR then
		recordResolvedExprType(ctx, nodeId, rightTyId)
	end
end

@native
local function visitTypeExprCall(ctx: TypeMapCtx, nodeId: number, node: any)
	local bfid = ctx.builtinCalls[nodeId]
	if bfid ~= nil and bfid ~= Builtins.LBF_NONE then
		local retTy = BUILTIN_RETURN_TYPES[bfid]
		if retTy ~= nil then
			recordResolvedExprType(ctx, nodeId, retTy)
		end
	else
		if ctx.hasTypeAnnotations and ctx.kinds[node.func] == K.AstExprLocal then
			local retTyId = ctx.functionReturnTypes[ctx.nodes[node.func]["local"]]
			if retTyId ~= nil then
				recordResolvedExprType(ctx, nodeId, retTyId)
			end
		end
	end
	visitTypeExpr(ctx, node.func)
	visitTypeExprList(ctx, node.args)
end

@native
local function visitTypeExprIfElseAndTable(ctx: TypeMapCtx, k: number, nodeId: number, node: any)
	if k == K.AstExprIfElse then
		visitTypeExpr(ctx, node.condition)
		if node.conditionLocal and node.conditionLocal ~= 0 then
			recordConditionLocalType(ctx, node)
		end
		visitTypeExpr(ctx, node.trueExpr)
		visitTypeExpr(ctx, node.falseExpr)
		local trueTyId = ctx.resolvedExprs[node.trueExpr]
		local trueBcTy = ctx.exprTypes[node.trueExpr]
		local falseBcTy = ctx.exprTypes[node.falseExpr]
		if trueTyId ~= nil and trueBcTy ~= nil and trueBcTy == falseBcTy then
			recordResolvedExprType(ctx, nodeId, trueTyId)
		end
	elseif k == K.AstExprTable then
		if node.items ~= 0 then
			local first = ctx.listFirsts[node.items]
			local count = ctx.listCounts[node.items]
			local listValues = ctx.listValues
			for i = 0, count - 1 do
				local item = listValues[first + i]
				if item.key ~= 0 then
					visitTypeExpr(ctx, item.key)
				end
				visitTypeExpr(ctx, item.value)
			end
		end
	end
end

@native
function visitTypeExpr(ctx: TypeMapCtx, nodeId: number)
	if nodeId == 0 then
		return
	end
	local k = ctx.kinds[nodeId]
	if k == nil then
		return
	end
	local resolvedExprs = ctx.resolvedExprs
	local exprTypes = ctx.exprTypes
	if k == K.AstExprConstantNumber then
		resolvedExprs[nodeId] = BUILTIN_NUMBER
		exprTypes[nodeId] = Types.LBC_TYPE_NUMBER
		return
	elseif k == K.AstExprConstantString then
		resolvedExprs[nodeId] = BUILTIN_STRING
		exprTypes[nodeId] = Types.LBC_TYPE_STRING
		return
	elseif k == K.AstExprConstantBool then
		resolvedExprs[nodeId] = BUILTIN_BOOLEAN
		exprTypes[nodeId] = Types.LBC_TYPE_BOOLEAN
		return
	elseif k == K.AstExprConstantNil or k == K.AstExprGlobal or k == K.AstExprVarargs then
		return
	end
	local node = ctx.nodes[nodeId]
	if k == K.AstExprLocal then
		local localId = node["local"]
		if ctx.hasTypeAnnotations then
			local b = ctx.bindings[localId]
			if b.annotation ~= 0 then
				local ty = recordResolvedExprType(ctx, nodeId, b.annotation)
				if ty ~= Types.LBC_TYPE_ANY then
					ctx.localTypes[localId] = ty
				end
				return
			end
		end
		local resolvedTyId = ctx.resolvedLocals[localId]
		if resolvedTyId ~= nil then
			local bty = if resolvedTyId < 0
				then BUILTIN_BYTECODE_TYPES[-resolvedTyId] or Types.LBC_TYPE_ANY
				else recordResolvedExprType(ctx, nodeId, resolvedTyId)
			if resolvedTyId < 0 then
				resolvedExprs[nodeId] = resolvedTyId
				exprTypes[nodeId] = bty
			end
			ctx.localTypes[localId] = bty
		end
	elseif k == K.AstExprInterpString then
		resolvedExprs[nodeId] = BUILTIN_STRING
		exprTypes[nodeId] = Types.LBC_TYPE_STRING
	elseif k == K.AstExprIndexName then
		visitTypeExprIndexName(ctx, nodeId, node)
	elseif k == K.AstExprCall then
		visitTypeExprCall(ctx, nodeId, node)
	elseif k == K.AstExprBinary then
		visitTypeExprBinary(ctx, nodeId, node)
	elseif k == K.AstExprIndexExpr then
		visitTypeExpr(ctx, node.expr)
		visitTypeExpr(ctx, node.index)
		local indexer = tryGetTableIndexer(ctx, node.expr)
		if indexer then
			recordResolvedExprType(ctx, nodeId, indexer.resultType)
		end
	elseif k == K.AstExprIfElse or k == K.AstExprTable then
		visitTypeExprIfElseAndTable(ctx, k, nodeId, node)
	elseif k == K.AstExprUnary then
		visitTypeExpr(ctx, node.expr)
		local op = node.op
		if op == "Not" then
			ctx.resolvedExprs[nodeId] = BUILTIN_BOOLEAN
			ctx.exprTypes[nodeId] = Types.LBC_TYPE_BOOLEAN
		elseif op == "Minus" then
			local innerTyId = ctx.resolvedExprs[node.expr]
			local innerBcTy = ctx.exprTypes[node.expr]
			if innerTyId ~= nil and (innerBcTy == Types.LBC_TYPE_VECTOR or innerBcTy == Types.LBC_TYPE_NUMBER) then
				recordResolvedExprType(ctx, nodeId, innerTyId)
			end
		elseif op == "Len" then
			ctx.resolvedExprs[nodeId] = BUILTIN_NUMBER
			ctx.exprTypes[nodeId] = Types.LBC_TYPE_NUMBER
		end
	elseif k == K.AstExprFunction then
		if ctx.hasTypeAnnotations then
			local ft = getFunctionType(ctx, node)
			if ft ~= "" then
				ctx.functionTypes[nodeId] = ft
			end
		end
		visitTypeStat(ctx, node.body)
	elseif k == K.AstExprGroup then
		visitTypeExpr(ctx, node.expr)
		local innerTyId = ctx.resolvedExprs[node.expr]
		if innerTyId ~= nil then
			recordResolvedExprType(ctx, nodeId, innerTyId)
		end
	elseif k == K.AstExprTypeAssertion then
		visitTypeExpr(ctx, node.expr)
		recordResolvedExprType(ctx, nodeId, node.annotation)
	elseif k == K.AstExprInstantiate then
		visitTypeExpr(ctx, node.expr)
	elseif k == K.AstExprError then
		visitTypeExprList(ctx, node.expressions)
	end
end

@native
local function visitTypeStatForIn(ctx: TypeMapCtx, node: any)
	visitTypeExprList(ctx, node.values)
	local listFirsts = ctx.listFirsts
	local listCounts = ctx.listCounts
	local listValues = ctx.listValues
	local nodes = ctx.nodes
	local kinds = ctx.kinds
	local varsFirst = if node.vars ~= 0 then listFirsts[node.vars] else 0
	local varsCount = if node.vars ~= 0 then listCounts[node.vars] else 0
	local valsFirst = if node.values ~= 0 then listFirsts[node.values] else 0
	local valsCount = if node.values ~= 0 then listCounts[node.values] else 0

	if varsCount == 2 and valsCount == 1 then
		local val0Id = listValues[valsFirst]
		if kinds[val0Id] == K.AstExprCall then
			local val0 = nodes[val0Id]
			if val0.args ~= 0 and listCounts[val0.args] == 1 then
				local argId = listValues[listFirsts[val0.args]]
				if kinds[val0.func] == K.AstExprGlobal then
					local funcNode = nodes[val0.func]
					if (ctx.globals[funcNode.name] or GlobalState.Default) == GlobalState.Default then
						if funcNode.name == ctx.ipairsSym then
							local indexer = tryGetTableIndexer(ctx, argId)
							if indexer then
								recordResolvedLocalType(ctx, listValues[varsFirst], BUILTIN_NUMBER)
								recordResolvedLocalType(ctx, listValues[varsFirst + 1], indexer.resultType)
							end
						elseif funcNode.name == ctx.pairsSym then
							local indexer = tryGetTableIndexer(ctx, argId)
							if indexer then
								recordResolvedLocalType(ctx, listValues[varsFirst], indexer.indexType)
								recordResolvedLocalType(ctx, listValues[varsFirst + 1], indexer.resultType)
							end
						end
					end
				end
			end
		else
			local indexer = tryGetTableIndexer(ctx, val0Id)
			if indexer then
				recordResolvedLocalType(ctx, listValues[varsFirst], indexer.indexType)
				recordResolvedLocalType(ctx, listValues[varsFirst + 1], indexer.resultType)
			end
		end
	end

	if varsCount > 0 and ctx.hasTypeAnnotations then
		local bindings = ctx.bindings
		for i = 0, varsCount - 1 do
			local varId = listValues[varsFirst + i]
			local b = bindings[varId]
			if b.annotation ~= 0 then
				recordResolvedLocalType(ctx, varId, b.annotation)
			end
		end
	end

	visitTypeStat(ctx, node.body)
end

@native
local function visitTypeStatLocal(ctx: TypeMapCtx, node: any)
	visitTypeExprList(ctx, node.values)
	if node.vars == 0 or node.values == 0 then
		return
	end
	local listFirsts = ctx.listFirsts
	local listCounts = ctx.listCounts
	local listValues = ctx.listValues
	local varsFirst = listFirsts[node.vars]
	local varsCount = listCounts[node.vars]
	local valsFirst = listFirsts[node.values]
	local valsCount = listCounts[node.values]
	local count = if varsCount < valsCount then varsCount else valsCount
	local resolvedExprs = ctx.resolvedExprs
	local resolvedLocals = ctx.resolvedLocals

	if ctx.hasTypeAnnotations then
		local bindings = ctx.bindings
		for i = 0, count - 1 do
			local varId = listValues[varsFirst + i]
			if bindings[varId].annotation == 0 then
				local valTyId = resolvedExprs[listValues[valsFirst + i]]
				if valTyId ~= nil then
					resolvedLocals[varId] = valTyId
				end
			end
		end
	else
		for i = 0, count - 1 do
			local valTyId = resolvedExprs[listValues[valsFirst + i]]
			if valTyId ~= nil then
				resolvedLocals[listValues[varsFirst + i]] = valTyId
			end
		end
	end
end

@native
function visitTypeStat(ctx: TypeMapCtx, nodeId: number)
	if nodeId == 0 then
		return
	end
	local k = ctx.kinds[nodeId]
	if
		k == nil
		or k == K.AstStatBreak
		or k == K.AstStatContinue
		or k == K.AstStatTypeAlias
		or k == K.AstStatDeclareGlobal
		or k == K.AstStatDeclareFunction
		or k == K.AstStatDeclareExternType
	then
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
		local hasAliases = ctx.hasTypeAliases
		local top = if hasAliases then pushTypeAliases(ctx, nodeId) else 0
		if node.body ~= 0 then
			local first = listFirsts[node.body]
			local count = listCounts[node.body]
			for i = 0, count - 1 do
				visitTypeStat(ctx, listValues[first + i])
			end
		end
		if hasAliases then
			popTypeAliases(ctx, top)
		end
	elseif k == K.AstStatLocal then
		visitTypeStatLocal(ctx, node)
	elseif k == K.AstStatIf then
		visitTypeExpr(ctx, node.condition)
		if node.conditionLocal and node.conditionLocal ~= 0 then
			recordConditionLocalType(ctx, node)
		end
		visitTypeStat(ctx, node.thenbody)
		if node.elsebody ~= 0 then
			visitTypeStat(ctx, node.elsebody)
		end
	elseif k == K.AstStatAssign then
		visitTypeExprList(ctx, node.vars)
		visitTypeExprList(ctx, node.values)
	elseif k == K.AstStatExpr then
		visitTypeExpr(ctx, node.expr)
	elseif k == K.AstStatReturn then
		visitTypeExprList(ctx, node.list)
	elseif k == K.AstStatCompoundAssign then
		visitTypeExpr(ctx, node.var)
		visitTypeExpr(ctx, node.value)
	elseif k == K.AstStatFor then
		ctx.resolvedLocals[node.var] = BUILTIN_NUMBER
		ctx.localTypes[node.var] = Types.LBC_TYPE_NUMBER
		visitTypeExpr(ctx, node.from)
		visitTypeExpr(ctx, node.to)
		if node.step ~= 0 then
			visitTypeExpr(ctx, node.step)
		end
		visitTypeStat(ctx, node.body)
	elseif k == K.AstStatLocalFunction then
		if ctx.hasTypeAnnotations then
			local funcNode = nodes[node.func]
			if funcNode and funcNode.returnAnnotation ~= 0 then
				local retId = funcNode.returnAnnotation
				if ctx.kinds[retId] == K.AstTypePackExplicit then
					local retPack = nodes[retId]
					if retPack.types ~= 0 and listCounts[retPack.types] >= 1 then
						ctx.functionReturnTypes[node.name] = listValues[listFirsts[retPack.types]]
					end
				end
			end
		end
		visitTypeExpr(ctx, node.func)
	elseif k == K.AstStatFunction then
		visitTypeExpr(ctx, node.name)
		visitTypeExpr(ctx, node.func)
	elseif k == K.AstStatForIn then
		visitTypeStatForIn(ctx, node)
	elseif k == K.AstStatWhile then
		visitTypeExpr(ctx, node.condition)
		visitTypeStat(ctx, node.body)
	elseif k == K.AstStatRepeat then
		local hasAliases = ctx.hasTypeAliases
		local top = if hasAliases then pushTypeAliases(ctx, node.body) else 0
		local bodyNode = nodes[node.body]
		if bodyNode and bodyNode.body ~= 0 then
			local first = listFirsts[bodyNode.body]
			local count = listCounts[bodyNode.body]
			for i = 0, count - 1 do
				visitTypeStat(ctx, listValues[first + i])
			end
		end
		visitTypeExpr(ctx, node.condition)
		if hasAliases then
			popTypeAliases(ctx, top)
		end
	elseif k == K.AstStatTypeFunction then
		if node.body ~= 0 then
			visitTypeExpr(ctx, node.body)
		end
	elseif k == K.AstStatClass then
		if node.declModifier == "None" and node.exprName ~= 0 then
			visitTypeExpr(ctx, node.exprName)
		end
		if node.super ~= 0 then
			visitTypeExpr(ctx, node.super)
		end
		if node.members ~= 0 then
			local first = listFirsts[node.members]
			local count = listCounts[node.members]
			local kinds = ctx.kinds
			for i = 0, count - 1 do
				local memberId = listValues[first + i]
				if kinds[memberId] == K.AstClassMethod then
					local member = nodes[memberId]
					if member["function"] ~= 0 then
						visitTypeExpr(ctx, member["function"])
					end
				end
			end
		end
	elseif k == K.AstStatError then
		visitTypeExprList(ctx, node.expressions)
		if node.statements ~= 0 then
			local first = listFirsts[node.statements]
			local count = listCounts[node.statements]
			for i = 0, count - 1 do
				visitTypeStat(ctx, listValues[first + i])
			end
		end
	end
end

@native
local function runTypeMapRoot(ctx: TypeMapCtx, rootId: number)
	local rootKind = ctx.kinds[rootId]
	if rootKind ~= nil then
		if rootKind == K.AstExprFunction then
			visitTypeExpr(ctx, rootId)
		else
			visitTypeStat(ctx, rootId)
		end
	end
end

local borrowedTypeCtx: TypeMapCtx? = nil
local typeMapInUse = false
local EMPTY_TYPE_ANY: any = table.freeze({})

local function buildTypeMap(
	arena: Arena.ArenaImpl,
	functionTypes: { [number]: string },
	localTypes: { [number]: number },
	exprTypes: { [number]: number },
	rootId: number,
	hostVectorType: string?,
	userdataTypes: { [string]: number },
	builtinCalls: { [number]: number },
	globals: { [number]: number },
	libraryMemberTypeCb: ((string, string) -> number)?,
	bytecode: any,
	flags: { [string]: boolean }?,
	hasTypeAliases: boolean?,
	symbolByName: { [string]: number }?
)
	local symbolMap = symbolByName or arena.symbolMap
	if symbolMap == nil then
		local map: { [string]: number } = {}
		for idx, str in arena.symbols do
			map[str] = idx
		end
		symbolMap = map
	end
	local sm = symbolMap :: { [string]: number }
	local resolvedAliases = if hasTypeAliases == nil then true else hasTypeAliases
	local hasAnns = arena.hasTypeAnnotations
	local borrow = not typeMapInUse
	local ctx: TypeMapCtx
	if borrow and borrowedTypeCtx ~= nil then
		typeMapInUse = true
		local c = borrowedTypeCtx
		c.arena = arena
		c.nodes = arena.nodes
		c.kinds = arena.kinds
		c.listFirsts = arena.listFirsts
		c.listCounts = arena.listCounts
		c.listValues = arena.listValues
		c.bindings = arena.bindings
		c.symbols = arena.symbols
		c.functionTypes = functionTypes
		c.localTypes = localTypes
		c.exprTypes = exprTypes
		c.hostVectorType = hostVectorType
		c.userdataTypes = userdataTypes
		c.builtinCalls = builtinCalls
		c.globals = globals
		c.libraryMemberTypeCb = libraryMemberTypeCb
		c.bytecode = bytecode
		c.hasTypeAliases = resolvedAliases
		c.hasTypeAnnotations = hasAnns
		c.vectorSym = sm["vector"]
		c.zeroSym = sm["zero"]
		c.oneSym = sm["one"]
		c.ipairsSym = sm["ipairs"]
		c.pairsSym = sm["pairs"]
		c.compX = sm["x"]
		c.compY = sm["y"]
		c.compZ = sm["z"]
		c.compXU = sm["X"]
		c.compYU = sm["Y"]
		c.compZU = sm["Z"]
		ctx = c
	else
		if borrow then
			typeMapInUse = true
		end
		local newCtx: TypeMapCtx = {
			arena = arena,
			nodes = arena.nodes,
			kinds = arena.kinds,
			listFirsts = arena.listFirsts,
			listCounts = arena.listCounts,
			listValues = arena.listValues,
			bindings = arena.bindings,
			symbols = arena.symbols,
			functionTypes = functionTypes,
			localTypes = localTypes,
			exprTypes = exprTypes,
			hostVectorType = hostVectorType,
			userdataTypes = userdataTypes,
			builtinCalls = builtinCalls,
			globals = globals,
			libraryMemberTypeCb = libraryMemberTypeCb,
			bytecode = bytecode,
			hasTypeAliases = resolvedAliases,
			hasTypeAnnotations = hasAnns,
			typeAliases = {},
			typeAliasStackNames = {},
			typeAliasStackPrev = {},
			resolvedLocals = table.create(#arena.bindings) :: { [number]: number },
			resolvedExprs = {},
			resolvedTypeBcCache = {},
			functionReturnTypes = {},
			seenAliases = {},
			vectorSym = sm["vector"],
			zeroSym = sm["zero"],
			oneSym = sm["one"],
			ipairsSym = sm["ipairs"],
			pairsSym = sm["pairs"],
			compX = sm["x"],
			compY = sm["y"],
			compZ = sm["z"],
			compXU = sm["X"],
			compYU = sm["Y"],
			compZU = sm["Z"],
		}
		if borrow then
			borrowedTypeCtx = newCtx
		end
		ctx = newCtx
	end

	local okTypeMap, typeMapErr = pcall(runTypeMapRoot :: any, ctx, rootId)

	if borrow then
		table.clear(ctx.typeAliases)
		table.clear(ctx.typeAliasStackNames)
		table.clear(ctx.typeAliasStackPrev)
		table.clear(ctx.resolvedLocals)
		table.clear(ctx.resolvedExprs)
		if next(ctx.resolvedTypeBcCache) ~= nil then
			table.clear(ctx.resolvedTypeBcCache)
		end
		table.clear(ctx.functionReturnTypes)
		table.clear(ctx.seenAliases)
		ctx.arena = EMPTY_TYPE_ANY
		ctx.nodes = EMPTY_TYPE_ANY
		ctx.kinds = EMPTY_TYPE_ANY
		ctx.listFirsts = EMPTY_TYPE_ANY
		ctx.listCounts = EMPTY_TYPE_ANY
		ctx.listValues = EMPTY_TYPE_ANY
		ctx.bindings = EMPTY_TYPE_ANY
		ctx.symbols = EMPTY_TYPE_ANY
		ctx.functionTypes = EMPTY_TYPE_ANY
		ctx.localTypes = EMPTY_TYPE_ANY
		ctx.exprTypes = EMPTY_TYPE_ANY
		ctx.userdataTypes = EMPTY_TYPE_ANY
		ctx.builtinCalls = EMPTY_TYPE_ANY
		ctx.globals = EMPTY_TYPE_ANY
		ctx.libraryMemberTypeCb = nil
		ctx.bytecode = nil
		typeMapInUse = false
	end
	if not okTypeMap then
		error(typeMapErr, 0)
	end
end

local function releaseTypeScratch()
	typeMapInUse = false
	local c = borrowedTypeCtx :: any
	if c ~= nil then
		table.clear(c.typeAliases)
		table.clear(c.typeAliasStackNames)
		table.clear(c.typeAliasStackPrev)
		table.clear(c.resolvedLocals)
		table.clear(c.resolvedExprs)
		if next(c.resolvedTypeBcCache) ~= nil then
			table.clear(c.resolvedTypeBcCache)
		end
		table.clear(c.functionReturnTypes)
		table.clear(c.seenAliases)
		c.arena = EMPTY_TYPE_ANY
		c.nodes = EMPTY_TYPE_ANY
		c.kinds = EMPTY_TYPE_ANY
		c.listFirsts = EMPTY_TYPE_ANY
		c.listCounts = EMPTY_TYPE_ANY
		c.listValues = EMPTY_TYPE_ANY
		c.bindings = EMPTY_TYPE_ANY
		c.symbols = EMPTY_TYPE_ANY
		c.functionTypes = EMPTY_TYPE_ANY
		c.localTypes = EMPTY_TYPE_ANY
		c.exprTypes = EMPTY_TYPE_ANY
		c.userdataTypes = EMPTY_TYPE_ANY
		c.builtinCalls = EMPTY_TYPE_ANY
		c.globals = EMPTY_TYPE_ANY
		c.libraryMemberTypeCb = nil
		c.bytecode = nil
	end
end

local band = bit32.band
local bor = bit32.bor
local bxor = bit32.bxor
local lshift = bit32.lshift
local rshift = bit32.rshift
local btest = bit32.btest

local K_LITERAL = 0xff

local EXTRA_LO: { number } = table.create(256, 0)
local EXTRA_HI: { number } = table.create(256, 0)
for m = 0, 254 do
	EXTRA_LO[m + 1] = 1
		+ (if btest(m, 2) then 0x100 else 0)
		+ (if btest(m, 4) then 0x10000 else 0)
		+ (if btest(m, 8) then 0x1000000 else 0)
	EXTRA_HI[m + 1] = (if btest(m, 16) then 1 else 0)
		+ (if btest(m, 32) then 0x100 else 0)
		+ (if btest(m, 64) then 0x10000 else 0)
		+ (if btest(m, 128) then 0x1000000 else 0)
end
EXTRA_LO[256] = 0
EXTRA_HI[256] = 0
table.freeze(EXTRA_LO)
table.freeze(EXTRA_HI)

@native
local function parallelAddSat32(x: number, y: number): number
	local r = x + y
	local s = band(r, 0x80808080)
	return bor(bxor(r, s), s - rshift(s, 7))
end

@native
local function addCost(hasParams: boolean, x: number, y: number): number
	if not hasParams then
		local s = x + y
		return if s > 0x7f then 0x7f else s
	end
	local r = x + y
	local s = band(r, 0x80808080)
	return bor(bxor(r, s), s - rshift(s, 7))
end

@native
local function parallelMulSat32(a: number, b: number): number
	local bs = if b < 127 then b else 127
	local l = bs * band(a, 0x007f007f)
	local h = bs * band(rshift(a, 8), 0x007f007f)
	local ls = l + 0x7f807f80
	local hs = h + 0x7f807f80
	local s = bor(band(hs, 0x80008000), rshift(band(ls, 0x80008000), 8))
	local r = bor(lshift(band(h, 0x007f007f), 8), band(l, 0x007f007f))
	return bor(r, s - rshift(s, 7))
end

type CostCtx = {
	arena: Arena.ArenaImpl,
	nodes: { [number]: any },
	kinds: { number },
	listFirsts: { number },
	listCounts: { number },
	listValues: { [number]: any },
	builtins: { [number]: number },
	hasBuiltins: boolean,
	constTypes: { [number]: number },
	constVals: { [number]: any },
	hasConstants: boolean,
	varMasks: { [number]: number },
	hasParams: boolean,
	resLo: number,
	resHi: number,
	termCache: { [number]: boolean }?,
}

local borrowedCostCtx: CostCtx? = nil
local borrowedVarMasks: { [number]: number } = {}
local costCtxInUse = false

@native
local function getTripCount(from: number, to: number, step: number): number
	local fromi = if from >= -32767 and from <= 32767 and math.modf(from) == from then from else nil
	local toi = if to >= -32767 and to <= 32767 and math.modf(to) == to then to else nil
	local stepi = if step >= -32767 and step <= 32767 and math.modf(step) == step then step else nil

	if fromi == nil or toi == nil or stepi == nil or stepi == 0 then
		return -1
	end

	if (stepi < 0 and toi > fromi) or (stepi > 0 and toi < fromi) then
		return 0
	end

	return math.modf((toi - fromi) / stepi) + 1
end

@native
local function getCostNumber(ctx: CostCtx, nodeId: number): number?
	if ctx.constTypes[nodeId] == ConstantType.Number then
		return ctx.constVals[nodeId] :: number
	end
	return nil
end

local visitCostStat: (CostCtx, number) -> ()

@native
local function modelExprCost(ctx: CostCtx, nodeId: number): (number, number, number)
	if ctx.hasConstants and ctx.constTypes[nodeId] ~= nil then
		return 0, 0, K_LITERAL
	end

	local k = ctx.kinds[nodeId]
	if k == nil then
		return 0, 0, 0
	end

	if k >= K.AstExprConstantNil and k <= K.AstExprConstantString then
		return 0, 0, K_LITERAL
	elseif k == K.AstExprGlobal then
		return 1, 0, 0
	elseif k == K.AstExprFunction then
		return 10, 0, 0
	elseif k == K.AstExprVarargs then
		return 3, 0, 0
	end

	local hasParams = ctx.hasParams
	local node = ctx.nodes[nodeId]
	if k == K.AstExprLocal then
		return 0, 0, ctx.varMasks[node["local"]] or 0
	elseif k == K.AstExprIndexName then
		local innerId = node.expr
		if ctx.kinds[innerId] == K.AstExprLocal and not (ctx.hasConstants and ctx.constTypes[innerId] ~= nil) then
			return 1, 0, 0
		end
		local eLo, eHi = modelExprCost(ctx, innerId)
		return if eLo == 0 then 1 else addCost(hasParams, eLo, 1), eHi, 0
	elseif k == K.AstExprCall then
		local bfid = if ctx.hasBuiltins then ctx.builtins[nodeId] else nil
		local isBuiltin = bfid ~= nil and bfid ~= Builtins.LBF_NONE
		local argsFirst = if node.args ~= 0 then ctx.listFirsts[node.args] else 0
		local argsCount = if node.args ~= 0 then ctx.listCounts[node.args] else 0
		local builtinShort = isBuiltin and argsCount <= 3

		local cLo = if isBuiltin then 2 else 3
		local cHi = 0
		if not isBuiltin then
			local fLo, fHi = modelExprCost(ctx, node.func)
			if fLo ~= 0 then
				cLo = addCost(hasParams, cLo, fLo)
			end
			if fHi ~= 0 then
				cHi = parallelAddSat32(cHi, fHi)
			end
		end
		if argsCount > 0 then
			local listValues = ctx.listValues
			for i = 0, argsCount - 1 do
				local aLo, aHi = modelExprCost(ctx, listValues[argsFirst + i])
				if aLo == 0 and aHi == 0 and not builtinShort then
					cLo = addCost(hasParams, cLo, 1)
				else
					if aLo ~= 0 then
						cLo = addCost(hasParams, cLo, aLo)
					end
					if aHi ~= 0 then
						cHi = parallelAddSat32(cHi, aHi)
					end
				end
			end
		end
		return cLo, cHi, 0
	elseif k == K.AstExprBinary then
		local lLo, lHi, lMask = modelExprCost(ctx, node.left)
		local rLo, rHi, rMask = modelExprCost(ctx, node.right)
		local newMask = band(lMask, rMask)
		local oLo = if lLo == 0 then rLo elseif rLo == 0 then lLo else addCost(hasParams, lLo, rLo)
		local oHi = if lHi == 0 then rHi elseif rHi == 0 then lHi else parallelAddSat32(lHi, rHi)
		if newMask ~= K_LITERAL then
			local exLo = EXTRA_LO[newMask + 1]
			oLo = if oLo == 0 then exLo else addCost(hasParams, oLo, exLo)
			if newMask >= 16 then
				local exHi = EXTRA_HI[newMask + 1]
				oHi = if oHi == 0 then exHi else parallelAddSat32(oHi, exHi)
			end
		end
		return oLo, oHi, newMask
	elseif k == K.AstExprIndexExpr then
		local eLo, eHi = modelExprCost(ctx, node.expr)
		local iLo, iHi = modelExprCost(ctx, node.index)
		local sLo = if eLo == 0 then iLo elseif iLo == 0 then eLo else addCost(hasParams, eLo, iLo)
		return if sLo == 0 then 1 else addCost(hasParams, sLo, 1),
			if eHi == 0 then iHi elseif iHi == 0 then eHi else parallelAddSat32(eHi, iHi),
			0
	elseif k == K.AstExprTable then
		local cLo = 10
		local cHi = 0
		if node.items ~= 0 then
			local first = ctx.listFirsts[node.items]
			local count = ctx.listCounts[node.items]
			local listValues = ctx.listValues
			for i = 0, count - 1 do
				local item = listValues[first + i]
				if item.key ~= 0 then
					local kLo, kHi = modelExprCost(ctx, item.key)
					if kLo ~= 0 then
						cLo = addCost(hasParams, cLo, kLo)
					end
					if kHi ~= 0 then
						cHi = if cHi == 0 then kHi else parallelAddSat32(cHi, kHi)
					end
				end
				local vLo, vHi = modelExprCost(ctx, item.value)
				cLo = addCost(hasParams, cLo, if vLo == 0 then 1 else addCost(hasParams, vLo, 1))
				if vHi ~= 0 then
					cHi = if cHi == 0 then vHi else parallelAddSat32(cHi, vHi)
				end
			end
		end
		return cLo, cHi, 0
	elseif k == K.AstExprUnary then
		local eLo, eHi, eMask = modelExprCost(ctx, node.expr)
		if eMask == K_LITERAL then
			return eLo, eHi, K_LITERAL
		end
		local exLo = EXTRA_LO[eMask + 1]
		return if eLo == 0 then exLo elseif exLo == 0 then eLo else addCost(hasParams, eLo, exLo),
			if eMask >= 16 then parallelAddSat32(eHi, EXTRA_HI[eMask + 1]) else eHi,
			eMask
	elseif k == K.AstExprGroup or k == K.AstExprTypeAssertion or k == K.AstExprInstantiate then
		return modelExprCost(ctx, node.expr)
	elseif k == K.AstExprIfElse then
		local cLo, cHi, cMask = modelExprCost(ctx, node.condition)
		if node.conditionLocal and node.conditionLocal ~= 0 and cMask ~= 0 then
			ctx.varMasks[node.conditionLocal] = cMask
		end
		local tLo, tHi = modelExprCost(ctx, node.trueExpr)
		local fLo, fHi = modelExprCost(ctx, node.falseExpr)
		local oLo = if cLo == 0 then tLo elseif tLo == 0 then cLo else addCost(hasParams, cLo, tLo)
		local fPlus2 = if fLo == 0 then 2 else addCost(hasParams, fLo, 2)
		oLo = if oLo == 0 then fPlus2 else addCost(hasParams, oLo, fPlus2)
		local oHi = if cHi == 0 then tHi elseif tHi == 0 then cHi else parallelAddSat32(cHi, tHi)
		if fHi ~= 0 then
			oHi = if oHi == 0 then fHi else parallelAddSat32(oHi, fHi)
		end
		return oLo, oHi, 0
	elseif k == K.AstExprInterpString then
		local cLo = 3
		local cHi = 0
		if node.expressions ~= 0 then
			local first = ctx.listFirsts[node.expressions]
			local count = ctx.listCounts[node.expressions]
			local listValues = ctx.listValues
			for i = 0, count - 1 do
				local sLo, sHi = modelExprCost(ctx, listValues[first + i])
				if sLo ~= 0 then
					cLo = addCost(hasParams, cLo, sLo)
				end
				if sHi ~= 0 then
					cHi = if cHi == 0 then sHi else parallelAddSat32(cHi, sHi)
				end
			end
		end
		return cLo, cHi, 0
	end

	return 0, 0, 0
end

@native
local function assignCostVar(ctx: CostCtx, exprId: number)
	if ctx.kinds[exprId] == K.AstExprLocal then
		local locId = ctx.nodes[exprId]["local"]
		if ctx.varMasks[locId] ~= nil then
			ctx.varMasks[locId] = 0
		end
	end
end

@native
local function loopCost(ctx: CostCtx, bodyId: number, iterLo: number, iterHi: number, factor: number?)
	local savedLo = ctx.resLo
	local savedHi = ctx.resHi
	ctx.resLo = 0
	ctx.resHi = 0

	visitCostStat(ctx, bodyId)

	local f = factor or 3
	local hasParams = ctx.hasParams
	local curLo = ctx.resLo
	local sumLo = if curLo == 0 then iterLo elseif iterLo == 0 then curLo else addCost(hasParams, curLo, iterLo)
	local bodyLo: number
	if sumLo == 0 then
		bodyLo = 0
	elseif not hasParams then
		local m = sumLo * (if f < 127 then f else 127)
		bodyLo = if m > 0x7f then 0x7f else m
	else
		bodyLo = parallelMulSat32(sumLo, f)
	end
	ctx.resLo = if savedLo == 0 then bodyLo elseif bodyLo == 0 then savedLo else addCost(hasParams, savedLo, bodyLo)

	local curHi = ctx.resHi
	if curHi ~= 0 or iterHi ~= 0 then
		local sumHi = if curHi == 0 then iterHi elseif iterHi == 0 then curHi else parallelAddSat32(curHi, iterHi)
		local bodyHi = parallelMulSat32(sumHi, f)
		ctx.resHi = if savedHi == 0 then bodyHi else parallelAddSat32(savedHi, bodyHi)
	else
		ctx.resHi = savedHi
	end
end

@native
local function visitCostStatAssign(ctx: CostCtx, node: any)
	local listFirsts = ctx.listFirsts
	local listCounts = ctx.listCounts
	local listValues = ctx.listValues
	local varsFirst = if node.vars ~= 0 then listFirsts[node.vars] else 0
	local varsCount = if node.vars ~= 0 then listCounts[node.vars] else 0
	local valsFirst = if node.values ~= 0 then listFirsts[node.values] else 0
	local valsCount = if node.values ~= 0 then listCounts[node.values] else 0
	if varsCount > 0 then
		for i = 0, varsCount - 1 do
			assignCostVar(ctx, listValues[varsFirst + i])
		end
	end
	local hasParams = ctx.hasParams
	local resLo = ctx.resLo
	local resHi = ctx.resHi
	local maxCount = if varsCount > valsCount then varsCount else valsCount
	for i = 0, maxCount - 1 do
		local acLo = 0
		local acHi = 0
		if i < varsCount then
			local vLo, vHi = modelExprCost(ctx, listValues[varsFirst + i])
			acLo = vLo
			acHi = vHi
		end
		if i < valsCount then
			local eLo, eHi = modelExprCost(ctx, listValues[valsFirst + i])
			if eLo ~= 0 then
				acLo = if acLo == 0 then eLo else addCost(hasParams, acLo, eLo)
			end
			if eHi ~= 0 then
				acHi = if acHi == 0 then eHi else parallelAddSat32(acHi, eHi)
			end
		end
		if band(acLo, 0x7f) == 0 then
			resLo = if resLo == 0 then 1 else addCost(hasParams, resLo, 1)
		else
			resLo = if resLo == 0 then acLo else addCost(hasParams, resLo, acLo)
			if acHi ~= 0 then
				resHi = if resHi == 0 then acHi else parallelAddSat32(resHi, acHi)
			end
		end
	end
	ctx.resLo = resLo
	ctx.resHi = resHi
end

@native
local function visitCostStatIf(ctx: CostCtx, node: any)
	local constTypes = ctx.constTypes
	local constVals = ctx.constVals
	if node.conditionLocal and node.conditionLocal ~= 0 then
		local _, _, argMask = modelExprCost(ctx, node.condition)
		if argMask ~= 0 then
			ctx.varMasks[node.conditionLocal] = argMask
		end
	end
	if CompilerFolding.isConstantFalse(constTypes, constVals, node.condition) then
		if node.elsebody ~= 0 then
			visitCostStat(ctx, node.elsebody)
		end
		return
	end
	if CompilerFolding.isConstantTrue(constTypes, constVals, node.condition) then
		visitCostStat(ctx, node.thenbody)
		return
	end
	local hasParams = ctx.hasParams
	local extra = 1 + (if node.elsebody ~= 0 and ctx.kinds[node.elsebody] ~= K.AstStatIf then 1 else 0)
	local condLo, condHi = modelExprCost(ctx, node.condition)
	local addLo = if condLo == 0 then extra else addCost(hasParams, condLo, extra)
	ctx.resLo = if ctx.resLo == 0 then addLo else addCost(hasParams, ctx.resLo, addLo)
	if condHi ~= 0 then
		ctx.resHi = if ctx.resHi == 0 then condHi else parallelAddSat32(ctx.resHi, condHi)
	end
	visitCostStat(ctx, node.thenbody)
	if node.elsebody ~= 0 then
		visitCostStat(ctx, node.elsebody)
	end
end

@native
local function visitCostStatFor(ctx: CostCtx, node: any)
	local hasParams = ctx.hasParams
	local fLo, fHi = modelExprCost(ctx, node.from)
	local tLo, tHi = modelExprCost(ctx, node.to)
	local resLo = ctx.resLo
	if fLo ~= 0 then
		resLo = if resLo == 0 then fLo else addCost(hasParams, resLo, fLo)
	end
	if tLo ~= 0 then
		resLo = if resLo == 0 then tLo else addCost(hasParams, resLo, tLo)
	end
	local resHi = ctx.resHi
	if fHi ~= 0 then
		resHi = if resHi == 0 then fHi else parallelAddSat32(resHi, fHi)
	end
	if tHi ~= 0 then
		resHi = if resHi == 0 then tHi else parallelAddSat32(resHi, tHi)
	end

	if node.step ~= 0 then
		local sLo, sHi = modelExprCost(ctx, node.step)
		if sLo ~= 0 then
			resLo = if resLo == 0 then sLo else addCost(hasParams, resLo, sLo)
		end
		if sHi ~= 0 then
			resHi = if resHi == 0 then sHi else parallelAddSat32(resHi, sHi)
		end
	end
	ctx.resLo = resLo
	ctx.resHi = resHi

	local tripCount = -1
	local fromVal = getCostNumber(ctx, node.from)
	local toVal = getCostNumber(ctx, node.to)
	local stepVal = if node.step ~= 0 then getCostNumber(ctx, node.step) else 1
	if fromVal ~= nil and toVal ~= nil and stepVal ~= nil then
		tripCount = getTripCount(fromVal, toVal, stepVal)
	end
	loopCost(ctx, node.body, 1, 0, if tripCount < 0 then 3 else tripCount)
end

@native
function visitCostStat(ctx: CostCtx, nodeId: number)
	if nodeId == 0 then
		return
	end
	local hasParams = ctx.hasParams
	if (not hasParams and ctx.resLo == 0x7f) or (ctx.resLo == 0x7f7f7f7f and ctx.resHi == 0x7f7f7f7f) then
		return
	end
	local kinds = ctx.kinds
	local k = kinds[nodeId]
	if k == nil then
		return
	end
	if k == K.AstStatBreak or k == K.AstStatContinue then
		ctx.resLo = if ctx.resLo == 0 then 1 else addCost(hasParams, ctx.resLo, 1)
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
			local constTypes = ctx.constTypes
			local constVals = ctx.constVals
			local termCache = ctx.termCache
			for i = 0, count - 1 do
				if (not hasParams and ctx.resLo == 0x7f) or (ctx.resLo == 0x7f7f7f7f and ctx.resHi == 0x7f7f7f7f) then
					break
				end
				local statId = listValues[first + i]
				visitCostStat(ctx, statId)
				if i < count - 1 then
					local sk = kinds[statId]
					if sk == K.AstStatReturn or sk == K.AstStatBreak or sk == K.AstStatContinue then
						break
					elseif
						(sk == K.AstStatBlock or sk == K.AstStatIf)
						and CompilerFolding.alwaysTerminates(ctx.arena, constTypes, constVals, statId, termCache)
					then
						break
					end
				end
			end
		end
	elseif k == K.AstStatLocal then
		if node.values ~= 0 then
			local valsFirst = listFirsts[node.values]
			local valsCount = listCounts[node.values]
			local varsFirst = if node.vars ~= 0 then listFirsts[node.vars] else 0
			local varsCount = if node.vars ~= 0 then listCounts[node.vars] else 0
			local resLo = ctx.resLo
			local resHi = ctx.resHi
			for i = 0, valsCount - 1 do
				local aLo, aHi, aMask = modelExprCost(ctx, listValues[valsFirst + i])
				if aMask ~= 0 and varsCount > 0 and i < varsCount then
					ctx.varMasks[listValues[varsFirst + i]] = aMask
				end
				if aLo ~= 0 then
					resLo = if resLo == 0 then aLo else addCost(hasParams, resLo, aLo)
				end
				if aHi ~= 0 then
					resHi = if resHi == 0 then aHi else parallelAddSat32(resHi, aHi)
				end
			end
			ctx.resLo = resLo
			ctx.resHi = resHi
		end
	elseif k == K.AstStatIf then
		visitCostStatIf(ctx, node)
	elseif k == K.AstStatAssign then
		visitCostStatAssign(ctx, node)
	elseif k == K.AstStatExpr then
		local eLo, eHi = modelExprCost(ctx, node.expr)
		if eLo ~= 0 then
			ctx.resLo = if ctx.resLo == 0 then eLo else addCost(hasParams, ctx.resLo, eLo)
		end
		if eHi ~= 0 then
			ctx.resHi = if ctx.resHi == 0 then eHi else parallelAddSat32(ctx.resHi, eHi)
		end
	elseif k == K.AstStatReturn then
		if node.list ~= 0 then
			local first = listFirsts[node.list]
			local count = listCounts[node.list]
			local resLo = ctx.resLo
			local resHi = ctx.resHi
			for i = 0, count - 1 do
				local eLo, eHi = modelExprCost(ctx, listValues[first + i])
				if eLo ~= 0 then
					resLo = if resLo == 0 then eLo else addCost(hasParams, resLo, eLo)
				end
				if eHi ~= 0 then
					resHi = if resHi == 0 then eHi else parallelAddSat32(resHi, eHi)
				end
			end
			ctx.resLo = resLo
			ctx.resHi = resHi
		end
	elseif k == K.AstStatCompoundAssign then
		assignCostVar(ctx, node.var)
		local extra = if kinds[node.var] == K.AstExprLocal then 1 else 2
		local varLo, varHi = modelExprCost(ctx, node.var)
		local valLo, valHi = modelExprCost(ctx, node.value)
		local resLo = if ctx.resLo == 0 then extra else addCost(hasParams, ctx.resLo, extra)
		if varLo ~= 0 then
			resLo = addCost(hasParams, resLo, varLo)
		end
		if valLo ~= 0 then
			resLo = addCost(hasParams, resLo, valLo)
		end
		ctx.resLo = resLo
		if varHi ~= 0 or valHi ~= 0 then
			local resHi = ctx.resHi
			if varHi ~= 0 then
				resHi = if resHi == 0 then varHi else parallelAddSat32(resHi, varHi)
			end
			if valHi ~= 0 then
				resHi = if resHi == 0 then valHi else parallelAddSat32(resHi, valHi)
			end
			ctx.resHi = resHi
		end
	elseif k == K.AstStatFor then
		visitCostStatFor(ctx, node)
	elseif k == K.AstStatLocalFunction then
		local fLo, fHi = modelExprCost(ctx, node.func)
		if fLo ~= 0 then
			ctx.resLo = if ctx.resLo == 0 then fLo else addCost(hasParams, ctx.resLo, fLo)
		end
		if fHi ~= 0 then
			ctx.resHi = if ctx.resHi == 0 then fHi else parallelAddSat32(ctx.resHi, fHi)
		end
	elseif k == K.AstStatFunction then
		local nLo, nHi = modelExprCost(ctx, node.name)
		local fLo, fHi = modelExprCost(ctx, node.func)
		local resLo = ctx.resLo
		if nLo ~= 0 then
			resLo = if resLo == 0 then nLo else addCost(hasParams, resLo, nLo)
		end
		if fLo ~= 0 then
			resLo = if resLo == 0 then fLo else addCost(hasParams, resLo, fLo)
		end
		ctx.resLo = resLo
		if nHi ~= 0 or fHi ~= 0 then
			local resHi = ctx.resHi
			if nHi ~= 0 then
				resHi = if resHi == 0 then nHi else parallelAddSat32(resHi, nHi)
			end
			if fHi ~= 0 then
				resHi = if resHi == 0 then fHi else parallelAddSat32(resHi, fHi)
			end
			ctx.resHi = resHi
		end
	elseif k == K.AstStatForIn then
		if node.values ~= 0 then
			local first = listFirsts[node.values]
			local count = listCounts[node.values]
			local resLo = ctx.resLo
			local resHi = ctx.resHi
			for i = 0, count - 1 do
				local vLo, vHi = modelExprCost(ctx, listValues[first + i])
				if vLo ~= 0 then
					resLo = if resLo == 0 then vLo else addCost(hasParams, resLo, vLo)
				end
				if vHi ~= 0 then
					resHi = if resHi == 0 then vHi else parallelAddSat32(resHi, vHi)
				end
			end
			ctx.resLo = resLo
			ctx.resHi = resHi
		end
		loopCost(ctx, node.body, 1, 0, 3)
	elseif k == K.AstStatWhile then
		local condLo, condHi, condMask = modelExprCost(ctx, node.condition)
		if node.conditionLocal and node.conditionLocal ~= 0 and condMask ~= 0 then
			ctx.varMasks[node.conditionLocal] = condMask
		end
		loopCost(ctx, node.body, condLo, condHi, 3)
	elseif k == K.AstStatRepeat then
		local condLo, condHi = modelExprCost(ctx, node.condition)
		loopCost(ctx, node.body, condLo, condHi, 3)
	elseif k == K.AstStatTypeFunction then
		if node.body ~= 0 then
			local fLo, fHi = modelExprCost(ctx, node.body)
			if fLo ~= 0 then
				ctx.resLo = if ctx.resLo == 0 then fLo else addCost(hasParams, ctx.resLo, fLo)
			end
			if fHi ~= 0 then
				ctx.resHi = if ctx.resHi == 0 then fHi else parallelAddSat32(ctx.resHi, fHi)
			end
		end
	elseif k == K.AstStatClass then
		local resLo = ctx.resLo
		local resHi = ctx.resHi
		if node.declModifier == "None" and node.exprName ~= 0 then
			local nLo, nHi = modelExprCost(ctx, node.exprName)
			resLo = addCost(hasParams, resLo, nLo)
			resHi = parallelAddSat32(resHi, nHi)
		end
		if node.super ~= 0 then
			local sLo, sHi = modelExprCost(ctx, node.super)
			resLo = addCost(hasParams, resLo, sLo)
			resHi = parallelAddSat32(resHi, sHi)
		end
		if node.members ~= 0 then
			local first = listFirsts[node.members]
			local count = listCounts[node.members]
			for i = 0, count - 1 do
				local memberId = listValues[first + i]
				if kinds[memberId] == K.AstClassMethod then
					local member = nodes[memberId]
					if member["function"] ~= 0 then
						local fLo, fHi = modelExprCost(ctx, member["function"])
						resLo = addCost(hasParams, resLo, fLo)
						resHi = parallelAddSat32(resHi, fHi)
					end
				end
			end
		end
		ctx.resLo = resLo
		ctx.resHi = resHi
	end
end

@native
local function runCostModelWithMasks(
	arena: Arena.ArenaImpl,
	rootId: number,
	varMasks: { [number]: number },
	hasParams: boolean,
	builtins: { [number]: number },
	constTypes: { [number]: number },
	constVals: { [number]: any },
	termCache: { [number]: boolean }?,
	borrowed: boolean
): (number, number)
	local ctx: CostCtx
	local hasConst = next(constTypes) ~= nil
	if borrowed then
		costCtxInUse = true
		local c = borrowedCostCtx
		if c == nil then
			local newCtx: CostCtx = {
				arena = arena,
				nodes = arena.nodes,
				kinds = arena.kinds,
				listFirsts = arena.listFirsts,
				listCounts = arena.listCounts,
				listValues = arena.listValues,
				builtins = builtins,
				hasBuiltins = next(builtins) ~= nil,
				constTypes = constTypes,
				constVals = constVals,
				hasConstants = hasConst,
				varMasks = varMasks,
				hasParams = hasParams,
				resLo = 0,
				resHi = 0,
				termCache = termCache,
			}
			borrowedCostCtx = newCtx
			ctx = newCtx
		else
			c.arena = arena
			c.nodes = arena.nodes
			c.kinds = arena.kinds
			c.listFirsts = arena.listFirsts
			c.listCounts = arena.listCounts
			c.listValues = arena.listValues
			c.builtins = builtins
			c.hasBuiltins = next(builtins) ~= nil
			c.constTypes = constTypes
			c.constVals = constVals
			c.hasConstants = hasConst
			c.varMasks = varMasks
			c.hasParams = hasParams
			c.resLo = 0
			c.resHi = 0
			c.termCache = termCache
			ctx = c
		end
	else
		ctx = {
			arena = arena,
			nodes = arena.nodes,
			kinds = arena.kinds,
			listFirsts = arena.listFirsts,
			listCounts = arena.listCounts,
			listValues = arena.listValues,
			builtins = builtins,
			hasBuiltins = next(builtins) ~= nil,
			constTypes = constTypes,
			constVals = constVals,
			hasConstants = hasConst,
			varMasks = varMasks,
			hasParams = hasParams,
			resLo = 0,
			resHi = 0,
			termCache = termCache,
		}
	end
	local okCost, costErr = pcall(visitCostStat :: any, ctx, rootId)
	local lo, hi = ctx.resLo, ctx.resHi
	if borrowed then
		costCtxInUse = false
	end
	if not okCost then
		error(costErr, 0)
	end
	return lo, hi
end

@native
local function modelCostList(
	arena: Arena.ArenaImpl,
	rootId: number,
	varsListId: number,
	builtins: { [number]: number },
	constTypes: { [number]: number },
	constVals: { [number]: any },
	termCache: { [number]: boolean }?
): (number, number)
	local borrowed = not costCtxInUse
	local varMasks: { [number]: number }
	if borrowed then
		varMasks = borrowedVarMasks
	else
		varMasks = {}
	end
	local hasParams = false
	if varsListId ~= 0 then
		local count = arena.listCounts[varsListId]
		if count > 0 then
			hasParams = true
			local listValues = arena.listValues
			local first = arena.listFirsts[varsListId]
			local limit = if count < 7 then count else 7
			for i = 0, limit - 1 do
				varMasks[listValues[first + i]] = lshift(1, i + 1)
			end
		end
	end
	local lo, hi =
		runCostModelWithMasks(arena, rootId, varMasks, hasParams, builtins, constTypes, constVals, termCache, borrowed)
	if borrowed then
		table.clear(borrowedVarMasks)
	end
	return lo, hi
end

@native
local function modelCostSingleVar(
	arena: Arena.ArenaImpl,
	rootId: number,
	varId: number,
	builtins: { [number]: number },
	constTypes: { [number]: number },
	constVals: { [number]: any },
	termCache: { [number]: boolean }?
): (number, number)
	local borrowed = not costCtxInUse
	local varMasks: { [number]: number }
	if borrowed then
		varMasks = borrowedVarMasks
	else
		varMasks = {}
	end
	local hasParams = varId ~= 0
	if hasParams then
		varMasks[varId] = 2
	end
	local lo, hi =
		runCostModelWithMasks(arena, rootId, varMasks, hasParams, builtins, constTypes, constVals, termCache, borrowed)
	if borrowed then
		table.clear(borrowedVarMasks)
	end
	return lo, hi
end

local function releaseCostScratch()
	costCtxInUse = false
	table.clear(borrowedVarMasks)
	local c = borrowedCostCtx :: any
	if c ~= nil then
		c.arena = EMPTY_TYPE_ANY
		c.nodes = EMPTY_TYPE_ANY
		c.kinds = EMPTY_TYPE_ANY
		c.listFirsts = EMPTY_TYPE_ANY
		c.listCounts = EMPTY_TYPE_ANY
		c.listValues = EMPTY_TYPE_ANY
		c.builtins = EMPTY_TYPE_ANY
		c.constTypes = EMPTY_TYPE_ANY
		c.constVals = EMPTY_TYPE_ANY
		c.varMasks = EMPTY_TYPE_ANY
		c.termCache = nil
	end
end

@native
local function computeCost(lo: number, hi: number, varsConst: { boolean }?, varCount: number): number
	local cost = band(lo, 0x7f)
	if cost == 0x7f or not varsConst then
		return cost
	end
	local limit = if varCount < 7 then varCount else 7
	if limit >= 1 and varsConst[1] then
		cost -= band(rshift(lo, 8), 0x7f)
	end
	if limit >= 2 and varsConst[2] then
		cost -= band(rshift(lo, 16), 0x7f)
	end
	if limit >= 3 and varsConst[3] then
		cost -= band(rshift(lo, 24), 0x7f)
	end
	if limit >= 4 and varsConst[4] then
		cost -= band(hi, 0x7f)
	end
	if limit >= 5 and varsConst[5] then
		cost -= band(rshift(hi, 8), 0x7f)
	end
	if limit >= 6 and varsConst[6] then
		cost -= band(rshift(hi, 16), 0x7f)
	end
	if limit >= 7 and varsConst[7] then
		cost -= band(rshift(hi, 24), 0x7f)
	end
	return cost
end

return table.freeze({
	buildTypeMap = buildTypeMap,
	modelCostList = modelCostList,
	modelCostSingleVar = modelCostSingleVar,
	computeCost = computeCost,
	getTripCount = getTripCount,
	releaseCostScratch = releaseCostScratch,
	releaseTypeScratch = releaseTypeScratch,
})
