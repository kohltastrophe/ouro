--!strict
-- Luau 0.748 Builtins and BuiltinFolding port.
-- Upstream Luau is MIT licensed; see ../LICENSE.md and ../UPSTREAM.json.
local Arena = require("./Arena")
local BytecodeDefs = require("./BytecodeDefs")

local K = Arena.Kinds
local Builtins = BytecodeDefs.Builtins

local band = bit32.band
local bor = bit32.bor
local bxor = bit32.bxor
local bnot = bit32.bnot
local lshift = bit32.lshift
local rshift = bit32.rshift
local arshift = bit32.arshift
local lrotate = bit32.lrotate
local rrotate = bit32.rrotate

local ConstantType = table.freeze({
	Unknown = 0,
	Nil = 1,
	Boolean = 2,
	Number = 3,
	Vectorf = 5,
	Vectord = 6,
	String = 7,
	Table = 8,
})

local GlobalState = table.freeze({
	Default = 0,
	Mutable = 1,
	Written = 2,
})

export type Constant = {
	type: number,
	valueBoolean: boolean?,
	valueNumber: number?,
	valueVectorf: { number }?,
	valueVectord: { number }?,
	valueString: string?,
	valueTable: { [string]: Constant }?,
	fromLibrary: boolean?,
}

export type Builtin = {
	object: string?,
	method: string?,
}

export type BuiltinInfo = {
	params: number,
	results: number,
	flags: number,
}

local Flag_NoneSafe = 1

local f32Buf = buffer.create(16)

@native
local function roundf(v: number): number
	buffer.writef32(f32Buf, 0, v)
	return buffer.readf32(f32Buf, 0)
end

local UNKNOWN_CONSTANT: Constant = table.freeze({ type = ConstantType.Unknown }) :: Constant
local NIL_CONSTANT: Constant = table.freeze({ type = ConstantType.Nil }) :: Constant
local TRUE_CONSTANT: Constant = table.freeze({ type = ConstantType.Boolean, valueBoolean = true }) :: Constant
local FALSE_CONSTANT: Constant = table.freeze({ type = ConstantType.Boolean, valueBoolean = false }) :: Constant
local EMPTY_STR_CONSTANT: Constant = table.freeze({ type = ConstantType.String, valueString = "" }) :: Constant

@native
local function isInt32Range(v: number): boolean
	return v == v and v >= -2147483648.0 and v <= 2147483647.0
end

@native
local function cvarNil(): Constant
	return NIL_CONSTANT
end

@native
local function cvarBool(v: boolean): Constant
	return if v then TRUE_CONSTANT else FALSE_CONSTANT
end

local NEG_ZERO_CONSTANT: Constant = table.freeze({ type = ConstantType.Number, valueNumber = -0.0 }) :: Constant
local SMALL_INT_CONSTANTS: { [number]: Constant } = {}
for i = -1, 256 do
	SMALL_INT_CONSTANTS[i] = table.freeze({ type = ConstantType.Number, valueNumber = i }) :: Constant
end
table.freeze(SMALL_INT_CONSTANTS)

@native
local function cvarNum(v: number): Constant
	local cached = SMALL_INT_CONSTANTS[v]
	if cached ~= nil then
		if v == 0 and 1 / v < 0 then
			return NEG_ZERO_CONSTANT
		end
		return cached
	end
	return { type = ConstantType.Number, valueNumber = v }
end

@native
local function cvarVecf(x: number, y: number, z: number, w: number): Constant
	return {
		type = ConstantType.Vectorf,
		valueVectorf = { roundf(x), roundf(y), roundf(z), roundf(w) },
	}
end

@native
local function cvarVecd(x: number, y: number, z: number, w: number): Constant
	return {
		type = ConstantType.Vectord,
		valueVectord = { x, y, z, w },
	}
end

@native
local function cvarStr(v: string): Constant
	if v == "" then
		return EMPTY_STR_CONSTANT
	end
	return { type = ConstantType.String, valueString = v }
end

local function fromCompileConstant(c: any, vectorDouble: boolean?): Constant
	if c == nil then
		return UNKNOWN_CONSTANT
	end
	local t = c.type
	if t == "nil" then
		return NIL_CONSTANT
	elseif t == "boolean" then
		return cvarBool(c.value == true)
	elseif t == "number" then
		if type(c.value) == "number" then
			return cvarNum(c.value)
		end
	elseif t == "vectorf" then
		local v = c.value
		if type(v) == "table" then
			if vectorDouble then
				return cvarVecd(v[1] or 0, v[2] or 0, v[3] or 0, v[4] or 0)
			end
			return cvarVecf(v[1] or 0, v[2] or 0, v[3] or 0, v[4] or 0)
		end
	elseif t == "vectord" then
		local v = c.value
		if type(v) == "table" then
			if vectorDouble == false then
				return cvarVecf(v[1] or 0, v[2] or 0, v[3] or 0, v[4] or 0)
			end
			return cvarVecd(v[1] or 0, v[2] or 0, v[3] or 0, v[4] or 0)
		end
	elseif t == "string" then
		if type(c.value) == "string" then
			return cvarStr(c.value)
		end
	elseif t == "table" then
		local tbl = c.value
		if type(tbl) == "table" then
			local out: { [string]: Constant } = {}
			for k, v in tbl do
				if type(k) == "string" then
					local cv = fromCompileConstant(v, vectorDouble)
					if cv.type ~= ConstantType.Unknown then
						out[k] = cv
					end
				end
			end
			return { type = ConstantType.Table, valueTable = out, fromLibrary = true }
		end
	end
	return UNKNOWN_CONSTANT
end

@native
local function getGlobalState(globals: { [number]: number }, nameSymbol: number): number
	return globals[nameSymbol] or GlobalState.Default
end

@native
local function getBuiltin(
	nodeId: number,
	arena: Arena.ArenaImpl,
	globals: { [number]: number },
	variables: any
): (string?, string?)
	local nodes = arena.nodes
	local kinds = arena.kinds
	local varWritten = variables.written
	local varInit = variables.init
	local curId = nodeId
	while true do
		local kind = kinds[curId]
		if kind == nil then
			return nil, nil
		end
		if kind == K.AstExprLocal then
			local localId = nodes[curId]["local"]
			if not varWritten[localId] then
				local initId = varInit[localId]
				if initId and initId ~= 0 then
					curId = initId
					continue
				end
			end
			return nil, nil
		elseif kind == K.AstExprIndexName then
			local node = nodes[curId]
			local exprId = node.expr
			local exprKind = kinds[exprId]
			if exprKind ~= nil then
				local symbols = arena.symbols
				if exprKind == K.AstExprLocal then
					local exprNode = nodes[exprId]
					local localId = exprNode["local"]
					if not varWritten[localId] then
						local initId = varInit[localId]
						if initId and initId ~= 0 then
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
							if objNode and getGlobalState(globals, objNode.name) == GlobalState.Default then
								return symbols[objNode.name], symbols[node.index]
							end
						end
					end
				elseif exprKind == K.AstExprGlobal then
					local exprNode = nodes[exprId]
					if getGlobalState(globals, exprNode.name) == GlobalState.Default then
						return symbols[exprNode.name], symbols[node.index]
					end
				end
			end
			return nil, nil
		elseif kind == K.AstExprGlobal then
			local node = nodes[curId]
			if getGlobalState(globals, node.name) == GlobalState.Default then
				return nil, arena.symbols[node.name]
			end
			return nil, nil
		end
		return nil, nil
	end
end

local GLOBAL_BUILTINS: { [string]: number } = table.freeze({
	assert = Builtins.LBF_ASSERT,
	type = Builtins.LBF_TYPE,
	typeof = Builtins.LBF_TYPEOF,
	rawset = Builtins.LBF_RAWSET,
	rawget = Builtins.LBF_RAWGET,
	rawequal = Builtins.LBF_RAWEQUAL,
	rawlen = Builtins.LBF_RAWLEN,
	unpack = Builtins.LBF_TABLE_UNPACK,
	select = Builtins.LBF_SELECT_VARARG,
	getmetatable = Builtins.LBF_GETMETATABLE,
	setmetatable = Builtins.LBF_SETMETATABLE,
	tonumber = Builtins.LBF_TONUMBER,
	tostring = Builtins.LBF_TOSTRING,
} :: { [string]: number })

local MATH_BUILTINS: { [string]: number } = table.freeze({
	abs = Builtins.LBF_MATH_ABS,
	acos = Builtins.LBF_MATH_ACOS,
	asin = Builtins.LBF_MATH_ASIN,
	atan2 = Builtins.LBF_MATH_ATAN2,
	atan = Builtins.LBF_MATH_ATAN,
	ceil = Builtins.LBF_MATH_CEIL,
	cosh = Builtins.LBF_MATH_COSH,
	cos = Builtins.LBF_MATH_COS,
	deg = Builtins.LBF_MATH_DEG,
	exp = Builtins.LBF_MATH_EXP,
	floor = Builtins.LBF_MATH_FLOOR,
	fmod = Builtins.LBF_MATH_FMOD,
	frexp = Builtins.LBF_MATH_FREXP,
	ldexp = Builtins.LBF_MATH_LDEXP,
	log10 = Builtins.LBF_MATH_LOG10,
	log = Builtins.LBF_MATH_LOG,
	max = Builtins.LBF_MATH_MAX,
	min = Builtins.LBF_MATH_MIN,
	modf = Builtins.LBF_MATH_MODF,
	pow = Builtins.LBF_MATH_POW,
	rad = Builtins.LBF_MATH_RAD,
	sinh = Builtins.LBF_MATH_SINH,
	sin = Builtins.LBF_MATH_SIN,
	sqrt = Builtins.LBF_MATH_SQRT,
	tanh = Builtins.LBF_MATH_TANH,
	tan = Builtins.LBF_MATH_TAN,
	clamp = Builtins.LBF_MATH_CLAMP,
	sign = Builtins.LBF_MATH_SIGN,
	round = Builtins.LBF_MATH_ROUND,
	lerp = Builtins.LBF_MATH_LERP,
	isnan = Builtins.LBF_MATH_ISNAN,
	isinf = Builtins.LBF_MATH_ISINF,
	isfinite = Builtins.LBF_MATH_ISFINITE,
} :: { [string]: number })

local BIT32_BUILTINS: { [string]: number } = table.freeze({
	arshift = Builtins.LBF_BIT32_ARSHIFT,
	band = Builtins.LBF_BIT32_BAND,
	bnot = Builtins.LBF_BIT32_BNOT,
	bor = Builtins.LBF_BIT32_BOR,
	bxor = Builtins.LBF_BIT32_BXOR,
	btest = Builtins.LBF_BIT32_BTEST,
	extract = Builtins.LBF_BIT32_EXTRACT,
	lrotate = Builtins.LBF_BIT32_LROTATE,
	lshift = Builtins.LBF_BIT32_LSHIFT,
	replace = Builtins.LBF_BIT32_REPLACE,
	rrotate = Builtins.LBF_BIT32_RROTATE,
	rshift = Builtins.LBF_BIT32_RSHIFT,
	countlz = Builtins.LBF_BIT32_COUNTLZ,
	countrz = Builtins.LBF_BIT32_COUNTRZ,
	byteswap = Builtins.LBF_BIT32_BYTESWAP,
} :: { [string]: number })

local STRING_BUILTINS: { [string]: number } = table.freeze({
	byte = Builtins.LBF_STRING_BYTE,
	char = Builtins.LBF_STRING_CHAR,
	len = Builtins.LBF_STRING_LEN,
	sub = Builtins.LBF_STRING_SUB,
} :: { [string]: number })

local TABLE_BUILTINS: { [string]: number } = table.freeze({
	insert = Builtins.LBF_TABLE_INSERT,
	unpack = Builtins.LBF_TABLE_UNPACK,
} :: { [string]: number })

local BUFFER_BUILTINS: { [string]: number } = table.freeze({
	readi8 = Builtins.LBF_BUFFER_READI8,
	readu8 = Builtins.LBF_BUFFER_READU8,
	writei8 = Builtins.LBF_BUFFER_WRITEU8,
	writeu8 = Builtins.LBF_BUFFER_WRITEU8,
	readi16 = Builtins.LBF_BUFFER_READI16,
	readu16 = Builtins.LBF_BUFFER_READU16,
	writei16 = Builtins.LBF_BUFFER_WRITEU16,
	writeu16 = Builtins.LBF_BUFFER_WRITEU16,
	readi32 = Builtins.LBF_BUFFER_READI32,
	readu32 = Builtins.LBF_BUFFER_READU32,
	writei32 = Builtins.LBF_BUFFER_WRITEU32,
	writeu32 = Builtins.LBF_BUFFER_WRITEU32,
	readf32 = Builtins.LBF_BUFFER_READF32,
	writef32 = Builtins.LBF_BUFFER_WRITEF32,
	readf64 = Builtins.LBF_BUFFER_READF64,
	writef64 = Builtins.LBF_BUFFER_WRITEF64,
} :: { [string]: number })

local VECTOR_BUILTINS: { [string]: number } = table.freeze({
	create = Builtins.LBF_VECTOR,
	magnitude = Builtins.LBF_VECTOR_MAGNITUDE,
	normalize = Builtins.LBF_VECTOR_NORMALIZE,
	cross = Builtins.LBF_VECTOR_CROSS,
	dot = Builtins.LBF_VECTOR_DOT,
	floor = Builtins.LBF_VECTOR_FLOOR,
	ceil = Builtins.LBF_VECTOR_CEIL,
	abs = Builtins.LBF_VECTOR_ABS,
	sign = Builtins.LBF_VECTOR_SIGN,
	clamp = Builtins.LBF_VECTOR_CLAMP,
	min = Builtins.LBF_VECTOR_MIN,
	max = Builtins.LBF_VECTOR_MAX,
	lerp = Builtins.LBF_VECTOR_LERP,
} :: { [string]: number })

local BUILTIN_LIBS: { [string]: { [string]: number } } = table.freeze({
	math = MATH_BUILTINS,
	bit32 = BIT32_BUILTINS,
	string = STRING_BUILTINS,
	table = TABLE_BUILTINS,
	vector = VECTOR_BUILTINS,
} :: { [string]: { [string]: number } })

local function lookupBuiltinId(bObject: string?, bMethod: string, options: any, flags: any): number
	local id = Builtins.LBF_NONE
	if not bObject then
		id = GLOBAL_BUILTINS[bMethod] or Builtins.LBF_NONE
	elseif bObject == "table" then
		if flags and flags.LuauCompileTableBuiltinsCreateClear then
			if bMethod == "create" then
				id = Builtins.LBF_TABLE_CREATE
			elseif bMethod == "clear" then
				id = Builtins.LBF_TABLE_CLEAR
			end
		end
		if id == Builtins.LBF_NONE then
			id = TABLE_BUILTINS[bMethod] or Builtins.LBF_NONE
		end
	elseif bObject == "buffer" then
		if flags and flags.DebugLuauBufferVectorFastcalls then
			if bMethod == "readvectorf32x2" then
				id = Builtins.LBF_BUFFER_READVECTORF32X2
			elseif bMethod == "readvectorf32x3" then
				id = Builtins.LBF_BUFFER_READVECTORF32X3
			elseif bMethod == "readvectorf32x4" then
				id = Builtins.LBF_BUFFER_READVECTORF32X4
			elseif bMethod == "writevectorf32x2" then
				id = Builtins.LBF_BUFFER_WRITEVECTORF32X2
			elseif bMethod == "writevectorf32x3" then
				id = Builtins.LBF_BUFFER_WRITEVECTORF32X3
			elseif bMethod == "writevectorf32x4" then
				id = Builtins.LBF_BUFFER_WRITEVECTORF32X4
			end
		end
		if id == Builtins.LBF_NONE then
			id = BUFFER_BUILTINS[bMethod] or Builtins.LBF_NONE
		end
	else
		local lib = BUILTIN_LIBS[bObject]
		if lib then
			id = lib[bMethod] or Builtins.LBF_NONE
		end
	end

	if id == Builtins.LBF_NONE and options and options.vectorCtor then
		if bObject then
			if options.vectorLib and bObject == options.vectorLib and bMethod == options.vectorCtor then
				id = Builtins.LBF_VECTOR
			end
		else
			if not options.vectorLib and bMethod == options.vectorCtor then
				id = Builtins.LBF_VECTOR
			end
		end
	end

	return id
end

export type DisabledBuiltins = {
	all: boolean,
	libs: { [string]: boolean },
	exact: { [string]: boolean },
	ids: { [number]: boolean },
}

local function buildDisabledSet(
	disabledBuiltins: { string }?,
	arena: any?,
	globals: { [number]: number }?,
	options: any?,
	flags: any?
): DisabledBuiltins?
	if not disabledBuiltins or #disabledBuiltins == 0 then
		return nil
	end
	local symbolMap = if arena then arena.symbolMap else nil
	local disabled: DisabledBuiltins? = nil
	local function ensure(): DisabledBuiltins
		if not disabled then
			disabled = { all = false, libs = {}, exact = {}, ids = {} }
		end
		return disabled :: DisabledBuiltins
	end
	for _, name in disabledBuiltins do
		if name == "*" then
			ensure().all = true
			break
		end
		local dot = string.find(name, ".", 1, true)
		if dot then
			local libStr = string.sub(name, 1, dot - 1)
			local methodStr = string.sub(name, dot + 1)
			local allow = true
			if symbolMap and globals then
				local libSym = symbolMap[libStr]
				allow = libSym == nil or getGlobalState(globals, libSym) == GlobalState.Default
			end
			if allow then
				if methodStr == "*" then
					ensure().libs[libStr] = true
				else
					local d = ensure()
					d.exact[libStr .. "\0" .. methodStr] = true
					local bfid = lookupBuiltinId(libStr, methodStr, options, flags)
					if bfid > 0 then
						d.ids[bfid] = true
					end
				end
			end
		else
			local allow = true
			if symbolMap and globals then
				local nameSym = symbolMap[name]
				allow = nameSym == nil or getGlobalState(globals, nameSym) == GlobalState.Default
			end
			if allow then
				local d = ensure()
				d.exact["\0" .. name] = true
				local bfid = lookupBuiltinId(nil, name, options, flags)
				if bfid > 0 then
					d.ids[bfid] = true
				end
			end
		end
	end
	return disabled
end

local function isBuiltinDisabled(
	disabled: DisabledBuiltins?,
	bObject: string?,
	bMethod: string?,
	bfid: number?
): boolean
	if not disabled or not bMethod then
		return false
	end
	if disabled.all then
		return true
	end
	if bfid ~= nil and bfid > 0 and disabled.ids[bfid] then
		return true
	end
	if bObject then
		if disabled.libs[bObject] then
			return true
		end
		return disabled.exact[bObject .. "\0" .. bMethod] == true
	end
	return disabled.exact["\0" .. bMethod] == true
end

local function getBuiltinFunctionIdUnboxed(bObject: string?, bMethod: string?, options: any, flags: any): number
	if not bMethod then
		return Builtins.LBF_NONE
	end
	local id = lookupBuiltinId(bObject, bMethod, options, flags)
	if id <= 0 then
		return Builtins.LBF_NONE
	end
	if options and options.disabledBuiltins then
		local disabled = buildDisabledSet(options.disabledBuiltins, nil, nil, options, flags)
		if isBuiltinDisabled(disabled, bObject, bMethod, id) then
			return Builtins.LBF_NONE
		end
	end
	return id
end

local function getBuiltinFunctionId(b: Builtin, options: any, flags: any): number
	return getBuiltinFunctionIdUnboxed(b.object, b.method, options, flags)
end

type BuiltinsVariableTable = {
	init: { [number]: number },
	owner: { [number]: number },
	lastUsed: { [number]: number },
	written: { [number]: boolean },
	constant: { [number]: boolean },
	nonLexicalUse: { [number]: boolean },
}

type AnalyzeBuiltinsCtx = {
	builtins: { [number]: number },
	globals: { [number]: number },
	variables: BuiltinsVariableTable,
	options: any,
	arena: Arena.ArenaImpl,
	flags: any,
	nodes: { [number]: any },
	kinds: { number },
	listFirsts: { number },
	listCounts: { number },
	listValues: { [number]: any },
	symbols: { string },
	disabledById: DisabledBuiltins | false | nil,
}

@native
local function analyzeCallBuiltin(ctx: any, nodeId: number, node: any)
	if node.self then
		return
	end

	local bObject, bMethod = getBuiltin(node.func, ctx.arena, ctx.globals, ctx.variables)
	if not bMethod then
		return
	end

	local bfid = lookupBuiltinId(bObject, bMethod, ctx.options, ctx.flags)

	local disabled = ctx.disabledById
	if disabled == nil then
		local opts = ctx.options
		if opts and opts.disabledBuiltins then
			disabled = buildDisabledSet(opts.disabledBuiltins, ctx.arena, ctx.globals, opts, ctx.flags) or false
		else
			disabled = false
		end
		ctx.disabledById = disabled
	end
	if bfid > 0 and disabled and isBuiltinDisabled(disabled :: DisabledBuiltins, bObject, bMethod, bfid) then
		bfid = Builtins.LBF_NONE
	end

	if bfid == Builtins.LBF_SELECT_VARARG then
		local argCount = if node.args ~= 0 then ctx.listCounts[node.args] else 0
		if not (argCount == 2 and ctx.kinds[ctx.listValues[ctx.listFirsts[node.args] + 1]] == K.AstExprVarargs) then
			bfid = Builtins.LBF_NONE
		end
	end

	if bfid > 0 then
		ctx.builtins[nodeId] = bfid
	end
end

local visitBuiltinStat: (AnalyzeBuiltinsCtx, number) -> ()
local visitBuiltinExpr: (AnalyzeBuiltinsCtx, number) -> ()

@native
local function visitBuiltinExprList(ctx: AnalyzeBuiltinsCtx, listId: number)
	if listId == 0 then
		return
	end
	local first = ctx.listFirsts[listId]
	local count = ctx.listCounts[listId]
	local listValues = ctx.listValues
	for i = 0, count - 1 do
		visitBuiltinExpr(ctx, listValues[first + i])
	end
end

@native
function visitBuiltinExpr(ctx: AnalyzeBuiltinsCtx, nodeId: number)
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
	local nodes = ctx.nodes
	local node = nodes[nodeId]
	local listFirsts = ctx.listFirsts
	local listCounts = ctx.listCounts
	local listValues = ctx.listValues
	if k == K.AstExprCall then
		visitBuiltinExpr(ctx, node.func)
		visitBuiltinExprList(ctx, node.args)
		analyzeCallBuiltin(ctx, nodeId, node)
	elseif
		k == K.AstExprGroup
		or k == K.AstExprTypeAssertion
		or k == K.AstExprInstantiate
		or k == K.AstExprUnary
		or k == K.AstExprIndexName
	then
		visitBuiltinExpr(ctx, node.expr)
	elseif k == K.AstExprIndexExpr then
		visitBuiltinExpr(ctx, node.expr)
		visitBuiltinExpr(ctx, node.index)
	elseif k == K.AstExprBinary then
		visitBuiltinExpr(ctx, node.left)
		visitBuiltinExpr(ctx, node.right)
	elseif k == K.AstExprIfElse then
		visitBuiltinExpr(ctx, node.condition)
		visitBuiltinExpr(ctx, node.trueExpr)
		visitBuiltinExpr(ctx, node.falseExpr)
	elseif k == K.AstExprInterpString or k == K.AstExprError then
		visitBuiltinExprList(ctx, node.expressions)
	elseif k == K.AstExprTable then
		if node.items ~= 0 then
			local first = listFirsts[node.items]
			local count = listCounts[node.items]
			for i = 0, count - 1 do
				local item = listValues[first + i]
				if item.key ~= 0 then
					visitBuiltinExpr(ctx, item.key)
				end
				visitBuiltinExpr(ctx, item.value)
			end
		end
	elseif k == K.AstExprFunction then
		visitBuiltinStat(ctx, node.body)
	end
end

@native
function visitBuiltinStat(ctx: AnalyzeBuiltinsCtx, nodeId: number)
	if nodeId == 0 then
		return
	end
	local k = ctx.kinds[nodeId]
	if k == nil then
		return
	end
	local nodes = ctx.nodes
	local listFirsts = ctx.listFirsts
	local listCounts = ctx.listCounts
	local listValues = ctx.listValues
	local node = nodes[nodeId]
	if k == K.AstStatBlock then
		if node.body ~= 0 then
			local first = listFirsts[node.body]
			local count = listCounts[node.body]
			for i = 0, count - 1 do
				visitBuiltinStat(ctx, listValues[first + i])
			end
		end
	elseif k == K.AstStatIf then
		visitBuiltinExpr(ctx, node.condition)
		visitBuiltinStat(ctx, node.thenbody)
		if node.elsebody ~= 0 then
			visitBuiltinStat(ctx, node.elsebody)
		end
	elseif k == K.AstStatWhile then
		visitBuiltinExpr(ctx, node.condition)
		visitBuiltinStat(ctx, node.body)
	elseif k == K.AstStatRepeat then
		visitBuiltinStat(ctx, node.body)
		visitBuiltinExpr(ctx, node.condition)
	elseif k == K.AstStatReturn then
		visitBuiltinExprList(ctx, node.list)
	elseif k == K.AstStatExpr then
		visitBuiltinExpr(ctx, node.expr)
	elseif k == K.AstStatLocal or k == K.AstStatForIn then
		visitBuiltinExprList(ctx, node.values)
		if k == K.AstStatForIn then
			visitBuiltinStat(ctx, node.body)
		end
	elseif k == K.AstStatFor then
		visitBuiltinExpr(ctx, node.from)
		visitBuiltinExpr(ctx, node.to)
		if node.step ~= 0 then
			visitBuiltinExpr(ctx, node.step)
		end
		visitBuiltinStat(ctx, node.body)
	elseif k == K.AstStatAssign then
		visitBuiltinExprList(ctx, node.vars)
		visitBuiltinExprList(ctx, node.values)
	elseif k == K.AstStatCompoundAssign then
		visitBuiltinExpr(ctx, node.var)
		visitBuiltinExpr(ctx, node.value)
	elseif k == K.AstStatFunction then
		visitBuiltinExpr(ctx, node.name)
		visitBuiltinExpr(ctx, node.func)
	elseif k == K.AstStatLocalFunction then
		visitBuiltinExpr(ctx, node.func)
	elseif k == K.AstStatClass then
		if node.super ~= 0 then
			visitBuiltinExpr(ctx, node.super)
		end
		if node.members ~= 0 then
			local first = listFirsts[node.members]
			local count = listCounts[node.members]
			local kinds = ctx.kinds
			for i = 0, count - 1 do
				local mId = listValues[first + i]
				if kinds[mId] == K.AstClassMethod then
					visitBuiltinExpr(ctx, nodes[mId]["function"])
				end
			end
		end
	elseif k == K.AstStatError then
		visitBuiltinExprList(ctx, node.expressions)
		if node.statements ~= 0 then
			local first = listFirsts[node.statements]
			local count = listCounts[node.statements]
			for i = 0, count - 1 do
				visitBuiltinStat(ctx, listValues[first + i])
			end
		end
	end
end

local function analyzeBuiltins(
	builtins: { [number]: number },
	globals: { [number]: number },
	variables: BuiltinsVariableTable,
	options: any,
	rootId: number,
	arena: Arena.ArenaImpl,
	flags: any
)
	local disabledSet: DisabledBuiltins | false = if options and options.disabledBuiltins
		then buildDisabledSet(options.disabledBuiltins, arena, globals, options, flags) or false
		else false
	local ctx: AnalyzeBuiltinsCtx = {
		builtins = builtins,
		globals = globals,
		variables = variables,
		options = options,
		arena = arena,
		flags = flags,
		nodes = arena.nodes,
		kinds = arena.kinds,
		listFirsts = arena.listFirsts,
		listCounts = arena.listCounts,
		listValues = arena.listValues,
		symbols = arena.symbols,
		disabledById = disabledSet,
	}
	visitBuiltinStat(ctx, rootId)
end

local BUILTIN_INFOS: { [number]: BuiltinInfo } = {}
do
	local function set(ids: { number }, params: number, results: number, fl: number)
		local rawInfo = { params = params, results = results, flags = fl }
		local info: BuiltinInfo = rawInfo
		table.freeze(rawInfo)
		for _, id in ids do
			BUILTIN_INFOS[id] = info
		end
	end

	set({
		Builtins.LBF_MATH_ABS,
		Builtins.LBF_MATH_ACOS,
		Builtins.LBF_MATH_ASIN,
		Builtins.LBF_MATH_ATAN,
		Builtins.LBF_MATH_CEIL,
		Builtins.LBF_MATH_COSH,
		Builtins.LBF_MATH_COS,
		Builtins.LBF_MATH_DEG,
		Builtins.LBF_MATH_EXP,
		Builtins.LBF_MATH_FLOOR,
		Builtins.LBF_MATH_LOG10,
		Builtins.LBF_MATH_RAD,
		Builtins.LBF_MATH_SINH,
		Builtins.LBF_MATH_SIN,
		Builtins.LBF_MATH_SQRT,
		Builtins.LBF_MATH_TANH,
		Builtins.LBF_MATH_TAN,
		Builtins.LBF_MATH_SIGN,
		Builtins.LBF_MATH_ROUND,
		Builtins.LBF_MATH_ISNAN,
		Builtins.LBF_MATH_ISINF,
		Builtins.LBF_MATH_ISFINITE,
		Builtins.LBF_BIT32_BNOT,
		Builtins.LBF_BIT32_COUNTLZ,
		Builtins.LBF_BIT32_COUNTRZ,
		Builtins.LBF_BIT32_BYTESWAP,
		Builtins.LBF_STRING_LEN,
		Builtins.LBF_RAWLEN,
		Builtins.LBF_VECTOR_MAGNITUDE,
		Builtins.LBF_VECTOR_NORMALIZE,
		Builtins.LBF_VECTOR_FLOOR,
		Builtins.LBF_VECTOR_CEIL,
		Builtins.LBF_VECTOR_ABS,
		Builtins.LBF_VECTOR_SIGN,
	}, 1, 1, Flag_NoneSafe)

	set({
		Builtins.LBF_TYPE,
		Builtins.LBF_TYPEOF,
		Builtins.LBF_GETMETATABLE,
		Builtins.LBF_TOSTRING,
	}, 1, 1, 0)

	set({
		Builtins.LBF_MATH_ATAN2,
		Builtins.LBF_MATH_FMOD,
		Builtins.LBF_MATH_LDEXP,
		Builtins.LBF_MATH_POW,
		Builtins.LBF_BIT32_ARSHIFT,
		Builtins.LBF_BIT32_LROTATE,
		Builtins.LBF_BIT32_LSHIFT,
		Builtins.LBF_BIT32_RROTATE,
		Builtins.LBF_BIT32_RSHIFT,
		Builtins.LBF_VECTOR_CROSS,
		Builtins.LBF_VECTOR_DOT,
		Builtins.LBF_BUFFER_READI8,
		Builtins.LBF_BUFFER_READU8,
		Builtins.LBF_BUFFER_READI16,
		Builtins.LBF_BUFFER_READU16,
		Builtins.LBF_BUFFER_READI32,
		Builtins.LBF_BUFFER_READU32,
		Builtins.LBF_BUFFER_READF32,
		Builtins.LBF_BUFFER_READF64,
		Builtins.LBF_BUFFER_READVECTORF32X2,
		Builtins.LBF_BUFFER_READVECTORF32X3,
		Builtins.LBF_BUFFER_READVECTORF32X4,
	}, 2, 1, Flag_NoneSafe)

	set({
		Builtins.LBF_RAWGET,
		Builtins.LBF_RAWEQUAL,
		Builtins.LBF_SETMETATABLE,
	}, 2, 1, 0)

	set({
		Builtins.LBF_MATH_CLAMP,
		Builtins.LBF_MATH_LERP,
		Builtins.LBF_BIT32_EXTRACTK,
		Builtins.LBF_VECTOR_CLAMP,
		Builtins.LBF_VECTOR_LERP,
	}, 3, 1, Flag_NoneSafe)

	set({
		Builtins.LBF_RAWSET,
	}, 3, 1, 0)

	set({
		Builtins.LBF_BUFFER_WRITEU8,
		Builtins.LBF_BUFFER_WRITEU16,
		Builtins.LBF_BUFFER_WRITEU32,
		Builtins.LBF_BUFFER_WRITEF32,
		Builtins.LBF_BUFFER_WRITEF64,
		Builtins.LBF_BUFFER_WRITEVECTORF32X2,
		Builtins.LBF_BUFFER_WRITEVECTORF32X3,
		Builtins.LBF_BUFFER_WRITEVECTORF32X4,
	}, 3, 0, Flag_NoneSafe)

	set({
		Builtins.LBF_TABLE_CLEAR,
	}, 1, 0, 0)

	set({
		Builtins.LBF_TABLE_INSERT,
	}, -1, 0, 0)

	set({
		Builtins.LBF_MATH_FREXP,
		Builtins.LBF_MATH_MODF,
	}, 1, 2, Flag_NoneSafe)

	set({
		Builtins.LBF_MATH_LOG,
		Builtins.LBF_BIT32_BAND,
		Builtins.LBF_BIT32_BOR,
		Builtins.LBF_BIT32_BXOR,
		Builtins.LBF_BIT32_BTEST,
		Builtins.LBF_BIT32_EXTRACT,
		Builtins.LBF_BIT32_REPLACE,
		Builtins.LBF_MATH_MAX,
		Builtins.LBF_MATH_MIN,
		Builtins.LBF_STRING_CHAR,
		Builtins.LBF_STRING_SUB,
		Builtins.LBF_TABLE_CREATE,
		Builtins.LBF_VECTOR,
		Builtins.LBF_TONUMBER,
		Builtins.LBF_VECTOR_MIN,
		Builtins.LBF_VECTOR_MAX,
	}, -1, 1, 0)
end

local rawDefaultInfo = { params = -1, results = -1, flags = 0 }
local DEFAULT_BUILTIN_INFO: BuiltinInfo = rawDefaultInfo
table.freeze(rawDefaultInfo)

@native
local function getBuiltinInfo(bfid: number): BuiltinInfo
	return BUILTIN_INFOS[bfid] or DEFAULT_BUILTIN_INFO
end

@native
local function bit32U(v: number): number
	if v > -9223372036854775808.0 and v < 9223372036854775808.0 then
		local t = if v < 0 then math.ceil(v) else math.floor(v)
		return (t % 0x100000000) + 0
	end
	return 0
end

@native
local function bit32S(v: number): number
	if v >= -2147483648.0 and v <= 2147483647.0 then
		if v < 0 then
			return math.ceil(v)
		else
			return math.floor(v)
		end
	end
	return -2147483648
end

type FoldHandler = ({ Constant }, number, boolean?) -> Constant

local function unaryNum(fn: (number) -> number): FoldHandler
	return function(args, count)
		if count == 1 and args[1].type == ConstantType.Number then
			return cvarNum(fn(args[1].valueNumber :: number))
		end
		return UNKNOWN_CONSTANT
	end
end

local function unaryNumBool(fn: (number) -> boolean): FoldHandler
	return function(args, count)
		if count == 1 and args[1].type == ConstantType.Number then
			return cvarBool(fn(args[1].valueNumber :: number))
		end
		return UNKNOWN_CONSTANT
	end
end

local function binaryNum(fn: (number, number) -> number): FoldHandler
	return function(args, count)
		if count == 2 and args[1].type == ConstantType.Number and args[2].type == ConstantType.Number then
			return cvarNum(fn(args[1].valueNumber :: number, args[2].valueNumber :: number))
		end
		return UNKNOWN_CONSTANT
	end
end

local function mathMinMax(isMax: boolean): FoldHandler
	return function(args, count)
		if count < 1 then
			return UNKNOWN_CONSTANT
		end
		for i = 1, count do
			if args[i].type ~= ConstantType.Number then
				return UNKNOWN_CONSTANT
			end
		end
		local r = args[1].valueNumber :: number
		for i = 2, count do
			local a = args[i].valueNumber :: number
			if (isMax and a > r) or (not isMax and a < r) then
				r = a
			end
		end
		return cvarNum(r)
	end
end

local function bit32Unary(fn: (number) -> number): FoldHandler
	return function(args, count)
		if count == 1 and args[1].type == ConstantType.Number then
			return cvarNum(fn(bit32U(args[1].valueNumber :: number)))
		end
		return UNKNOWN_CONSTANT
	end
end

local function bit32Rotate(fn: (number, number) -> number): FoldHandler
	return function(args, count)
		if count == 2 and args[1].type == ConstantType.Number and args[2].type == ConstantType.Number then
			local s = args[2].valueNumber :: number
			if isInt32Range(s) then
				return cvarNum(fn(bit32U(args[1].valueNumber :: number), band(bit32S(s), 31)))
			end
		end
		return UNKNOWN_CONSTANT
	end
end

local function bit32Shift(fn: (number, number) -> number): FoldHandler
	return function(args, count)
		if count == 2 and args[1].type == ConstantType.Number and args[2].type == ConstantType.Number then
			local s = bit32S(args[2].valueNumber :: number)
			if s >= 0 and s < 32 then
				return cvarNum(fn(bit32U(args[1].valueNumber :: number), s))
			end
		end
		return UNKNOWN_CONSTANT
	end
end

local function bit32OrXor(fn: (number, number) -> number): FoldHandler
	return function(args, count)
		if count < 1 then
			return UNKNOWN_CONSTANT
		end
		local r = 0
		for i = 1, count do
			if args[i].type ~= ConstantType.Number then
				return UNKNOWN_CONSTANT
			end
			r = fn(r, bit32U(args[i].valueNumber :: number))
		end
		return cvarNum(r)
	end
end

local function bit32BandBtest(isTest: boolean): FoldHandler
	return function(args, count)
		if count < 1 then
			return UNKNOWN_CONSTANT
		end
		local r = 0xffffffff
		for i = 1, count do
			if args[i].type ~= ConstantType.Number then
				return UNKNOWN_CONSTANT
			end
			r = band(r, bit32U(args[i].valueNumber :: number))
		end
		return if isTest then cvarBool(r ~= 0) else cvarNum(r)
	end
end

local function constTypeLookup(tableMap: { [number]: Constant }): FoldHandler
	return function(args, count)
		if count == 1 then
			return tableMap[args[1].type] or UNKNOWN_CONSTANT
		end
		return UNKNOWN_CONSTANT
	end
end

local CONSTANT_TYPE_CONSTANTS: { [number]: Constant } = table.freeze({
	[ConstantType.Nil] = table.freeze({ type = ConstantType.String, valueString = "nil" }) :: Constant,
	[ConstantType.Boolean] = table.freeze({ type = ConstantType.String, valueString = "boolean" }) :: Constant,
	[ConstantType.Number] = table.freeze({ type = ConstantType.String, valueString = "number" }) :: Constant,
	[ConstantType.Vectorf] = table.freeze({ type = ConstantType.String, valueString = "vector" }) :: Constant,
	[ConstantType.Vectord] = table.freeze({ type = ConstantType.String, valueString = "vector" }) :: Constant,
	[ConstantType.String] = table.freeze({ type = ConstantType.String, valueString = "string" }) :: Constant,
})

local CONSTANT_TYPEOF_CONSTANTS: { [number]: Constant } = table.freeze({
	[ConstantType.Nil] = table.freeze({ type = ConstantType.String, valueString = "nil" }) :: Constant,
	[ConstantType.Boolean] = table.freeze({ type = ConstantType.String, valueString = "boolean" }) :: Constant,
	[ConstantType.Number] = table.freeze({ type = ConstantType.String, valueString = "number" }) :: Constant,
	[ConstantType.String] = table.freeze({ type = ConstantType.String, valueString = "string" }) :: Constant,
})

local function foldStringSub(args: { Constant }, count: number): Constant
	if count == 2 and args[1].type == ConstantType.String and args[2].type == ConstantType.Number then
		local v1 = args[2].valueNumber :: number
		if not isInt32Range(v1) then
			return UNKNOWN_CONSTANT
		end
		local s = args[1].valueString :: string
		local len = #s
		local startIdx = bit32S(v1)
		if startIdx < 0 then
			startIdx += len + 1
		end
		startIdx = math.max(startIdx, 1)
		return cvarStr(if startIdx <= len then string.sub(s, startIdx, len) else "")
	elseif
		count >= 3
		and args[1].type == ConstantType.String
		and args[2].type == ConstantType.Number
		and args[3].type == ConstantType.Number
	then
		local v1 = args[2].valueNumber :: number
		local v2 = args[3].valueNumber :: number
		if not (isInt32Range(v1) and isInt32Range(v2)) then
			return UNKNOWN_CONSTANT
		end
		local s = args[1].valueString :: string
		local len = #s
		local startIdx = bit32S(v1)
		local endIdx = bit32S(v2)
		if startIdx < 0 then
			startIdx += len + 1
		end
		if endIdx < 0 then
			endIdx += len + 1
		end
		if endIdx <= 0 then
			return EMPTY_STR_CONSTANT
		end
		startIdx = math.max(startIdx, 1)
		endIdx = math.min(endIdx, len)
		return cvarStr(if startIdx <= endIdx then string.sub(s, startIdx, endIdx) else "")
	end
	return UNKNOWN_CONSTANT
end

local foldHandlers: { [number]: FoldHandler }? = nil
local foldArgScratch: { Constant } = table.create(8) :: { Constant }

local function getFoldHandlers(): { [number]: FoldHandler }
	if foldHandlers ~= nil then
		return foldHandlers
	end
	local handlers = table.freeze({
		[Builtins.LBF_MATH_ABS] = unaryNum(math.abs),
		[Builtins.LBF_MATH_ACOS] = unaryNum(math.acos),
		[Builtins.LBF_MATH_ASIN] = unaryNum(math.asin),
		[Builtins.LBF_MATH_ATAN] = unaryNum(math.atan),
		[Builtins.LBF_MATH_CEIL] = unaryNum(math.ceil),
		[Builtins.LBF_MATH_COSH] = unaryNum(math.cosh),
		[Builtins.LBF_MATH_COS] = unaryNum(math.cos),
		[Builtins.LBF_MATH_DEG] = unaryNum(math.deg),
		[Builtins.LBF_MATH_EXP] = unaryNum(math.exp),
		[Builtins.LBF_MATH_FLOOR] = unaryNum(math.floor),
		[Builtins.LBF_MATH_LOG10] = unaryNum(math.log10),
		[Builtins.LBF_MATH_RAD] = unaryNum(math.rad),
		[Builtins.LBF_MATH_SINH] = unaryNum(math.sinh),
		[Builtins.LBF_MATH_SIN] = unaryNum(math.sin),
		[Builtins.LBF_MATH_SQRT] = unaryNum(math.sqrt),
		[Builtins.LBF_MATH_TANH] = unaryNum(math.tanh),
		[Builtins.LBF_MATH_TAN] = unaryNum(math.tan),
		[Builtins.LBF_MATH_ROUND] = unaryNum(math.round),
		[Builtins.LBF_MATH_SIGN] = unaryNum(function(v)
			return if v > 0.0 then 1.0 elseif v < 0.0 then -1.0 else 0.0
		end),
		[Builtins.LBF_MATH_ISNAN] = unaryNumBool(function(x)
			return x ~= x
		end),
		[Builtins.LBF_MATH_ISINF] = unaryNumBool(function(x)
			return math.abs(x) == math.huge
		end),
		[Builtins.LBF_MATH_ISFINITE] = unaryNumBool(function(x)
			return x == x and math.abs(x) ~= math.huge
		end),
		[Builtins.LBF_MATH_ATAN2] = binaryNum(math.atan2),
		[Builtins.LBF_MATH_FMOD] = binaryNum(math.fmod),
		[Builtins.LBF_MATH_POW] = binaryNum(function(a, b)
			return a ^ b
		end),
		[Builtins.LBF_MATH_LDEXP] = function(args: { Constant }, count: number): Constant
			if count == 2 and args[1].type == ConstantType.Number and args[2].type == ConstantType.Number then
				local v2 = args[2].valueNumber :: number
				if v2 >= -2147483648.0 and v2 <= 2147483647.0 then
					local exp = if v2 < 0 then math.ceil(v2) else math.floor(v2)
					return cvarNum(math.ldexp(args[1].valueNumber :: number, exp))
				end
			end
			return UNKNOWN_CONSTANT
		end,
		[Builtins.LBF_MATH_LOG] = function(args: { Constant }, count: number): Constant
			if count == 1 and args[1].type == ConstantType.Number then
				return cvarNum(math.log(args[1].valueNumber :: number))
			elseif count == 2 and args[1].type == ConstantType.Number and args[2].type == ConstantType.Number then
				local v1 = args[1].valueNumber :: number
				local v2 = args[2].valueNumber :: number
				if v2 == 2.0 then
					return cvarNum(math.log(v1, 2))
				elseif v2 == 10.0 then
					return cvarNum(math.log10(v1))
				else
					return cvarNum(math.log(v1) / math.log(v2))
				end
			end
			return UNKNOWN_CONSTANT
		end,
		[Builtins.LBF_MATH_MAX] = mathMinMax(true),
		[Builtins.LBF_MATH_MIN] = mathMinMax(false),
		[Builtins.LBF_MATH_CLAMP] = function(args: { Constant }, count: number): Constant
			if
				count == 3
				and args[1].type == ConstantType.Number
				and args[2].type == ConstantType.Number
				and args[3].type == ConstantType.Number
			then
				local min = args[2].valueNumber :: number
				local max = args[3].valueNumber :: number
				if min <= max then
					local v = args[1].valueNumber :: number
					v = if v < min then min elseif v > max then max else v
					return cvarNum(v)
				end
			end
			return UNKNOWN_CONSTANT
		end,
		[Builtins.LBF_MATH_LERP] = function(args: { Constant }, count: number): Constant
			if
				count == 3
				and args[1].type == ConstantType.Number
				and args[2].type == ConstantType.Number
				and args[3].type == ConstantType.Number
			then
				local a = args[1].valueNumber :: number
				local b = args[2].valueNumber :: number
				local t = args[3].valueNumber :: number
				return cvarNum(if t == 1.0 then b else a + (b - a) * t)
			end
			return UNKNOWN_CONSTANT
		end,

		[Builtins.LBF_BIT32_BAND] = bit32BandBtest(false),
		[Builtins.LBF_BIT32_BTEST] = bit32BandBtest(true),
		[Builtins.LBF_BIT32_BOR] = bit32OrXor(bor),
		[Builtins.LBF_BIT32_BXOR] = bit32OrXor(bxor),
		[Builtins.LBF_BIT32_BNOT] = bit32Unary(bnot),
		[Builtins.LBF_BIT32_LROTATE] = bit32Rotate(lrotate),
		[Builtins.LBF_BIT32_RROTATE] = bit32Rotate(rrotate),
		[Builtins.LBF_BIT32_ARSHIFT] = bit32Shift(arshift),
		[Builtins.LBF_BIT32_LSHIFT] = bit32Shift(lshift),
		[Builtins.LBF_BIT32_RSHIFT] = bit32Shift(rshift),
		[Builtins.LBF_BIT32_EXTRACT] = function(args: { Constant }, count: number): Constant
			if
				count >= 2
				and args[1].type == ConstantType.Number
				and args[2].type == ConstantType.Number
				and (count == 2 or args[3].type == ConstantType.Number)
			then
				local u = bit32U(args[1].valueNumber :: number)
				local f = bit32S(args[2].valueNumber :: number)
				local w = if count == 2 then 1 else bit32S(args[3].valueNumber :: number)
				if f >= 0 and w > 0 and f + w <= 32 then
					return cvarNum(bit32.extract(u, f, w))
				end
			end
			return UNKNOWN_CONSTANT
		end,
		[Builtins.LBF_BIT32_REPLACE] = function(args: { Constant }, count: number): Constant
			if
				count >= 3
				and args[1].type == ConstantType.Number
				and args[2].type == ConstantType.Number
				and args[3].type == ConstantType.Number
				and (count == 3 or args[4].type == ConstantType.Number)
			then
				local u = bit32U(args[1].valueNumber :: number)
				local v = bit32U(args[2].valueNumber :: number)
				local f = bit32S(args[3].valueNumber :: number)
				local w = if count == 3 then 1 else bit32S(args[4].valueNumber :: number)
				if f >= 0 and w > 0 and f + w <= 32 then
					return cvarNum(bit32.replace(u, v, f, w))
				end
			end
			return UNKNOWN_CONSTANT
		end,

		[Builtins.LBF_TYPE] = constTypeLookup(CONSTANT_TYPE_CONSTANTS),
		[Builtins.LBF_TYPEOF] = constTypeLookup(CONSTANT_TYPEOF_CONSTANTS),
		[Builtins.LBF_STRING_BYTE] = function(args: { Constant }, count: number): Constant
			if count == 1 and args[1].type == ConstantType.String then
				local s = args[1].valueString :: string
				if #s >= 1 then
					return cvarNum(string.byte(s, 1))
				end
			elseif count == 2 and args[1].type == ConstantType.String and args[2].type == ConstantType.Number then
				local s = args[1].valueString :: string
				local i = bit32S(args[2].valueNumber :: number)
				if i > 0 and i <= #s then
					return cvarNum(string.byte(s, i))
				end
			end
			return UNKNOWN_CONSTANT
		end,
		[Builtins.LBF_STRING_CHAR] = function(args: { Constant }, count: number): Constant
			if count <= 127 then
				local chars: { number } = {}
				for i = 1, count do
					if args[i].type ~= ConstantType.Number then
						return UNKNOWN_CONSTANT
					end
					local ch = bit32S(args[i].valueNumber :: number)
					if ch < 0 or ch > 255 then
						return UNKNOWN_CONSTANT
					end
					chars[i] = ch
				end
				return cvarStr(string.char(table.unpack(chars)))
			end
			return UNKNOWN_CONSTANT
		end,
		[Builtins.LBF_STRING_LEN] = function(args: { Constant }, count: number): Constant
			if count == 1 and args[1].type == ConstantType.String then
				return cvarNum(#(args[1].valueString :: string))
			end
			return UNKNOWN_CONSTANT
		end,
		[Builtins.LBF_STRING_SUB] = foldStringSub,
		[Builtins.LBF_VECTOR] = function(args: { Constant }, count: number, vectorDouble: boolean?): Constant
			if count >= 2 and count <= 4 then
				for i = 1, count do
					if args[i].type ~= ConstantType.Number then
						return UNKNOWN_CONSTANT
					end
				end
				local x = args[1].valueNumber :: number
				local y = args[2].valueNumber :: number
				local z = if count >= 3 then args[3].valueNumber :: number else 0.0
				local w = if count == 4 then args[4].valueNumber :: number else 0.0
				return if vectorDouble then cvarVecd(x, y, z, w) else cvarVecf(x, y, z, w)
			end
			return UNKNOWN_CONSTANT
		end,
	} :: { [number]: FoldHandler })
	foldHandlers = handlers
	return handlers
end

@native
local function foldBuiltin(
	bfid: number,
	args: { Constant },
	count: number,
	vectorDouble: boolean?,
	argBase: number?
): Constant
	local fn = (foldHandlers or getFoldHandlers())[bfid]
	if fn == nil then
		return UNKNOWN_CONSTANT
	end
	if argBase ~= nil and argBase > 0 then
		for i = 1, count do
			foldArgScratch[i] = args[argBase + i]
		end
		local res = fn(foldArgScratch, count, vectorDouble)
		for i = 1, count do
			foldArgScratch[i] = nil :: any
		end
		return res
	end
	return fn(args, count, vectorDouble)
end

local kPi = 3.14159265358979323846
local kTau = 6.28318530717958647692
local kE = 2.71828182845904523536
local kGoldenRatio = 1.61803398874989484820
local kSqrt2 = 1.41421356237309504880

local MATH_CONSTANTS: { [string]: Constant } = table.freeze({
	e = table.freeze(cvarNum(kE)),
	huge = table.freeze(cvarNum(math.huge)),
	nan = table.freeze(cvarNum(0 / 0)),
	phi = table.freeze(cvarNum(kGoldenRatio)),
	pi = table.freeze(cvarNum(kPi)),
	sqrt2 = table.freeze(cvarNum(kSqrt2)),
	tau = table.freeze(cvarNum(kTau)),
} :: { [string]: Constant })

local function foldBuiltinMath(index: string): Constant
	return MATH_CONSTANTS[index] or UNKNOWN_CONSTANT
end

return table.freeze({
	ConstantType = ConstantType,
	GlobalState = GlobalState,
	Flag_NoneSafe = Flag_NoneSafe,
	UNKNOWN_CONSTANT = UNKNOWN_CONSTANT,
	NIL_CONSTANT = NIL_CONSTANT,
	TRUE_CONSTANT = TRUE_CONSTANT,
	FALSE_CONSTANT = FALSE_CONSTANT,
	cvarNil = cvarNil,
	cvarBool = cvarBool,
	cvarNum = cvarNum,
	cvarVecf = cvarVecf,
	cvarVecd = cvarVecd,
	cvarStr = cvarStr,
	fromCompileConstant = fromCompileConstant,
	roundf = roundf,
	getGlobalState = getGlobalState,
	getBuiltin = getBuiltin,
	getBuiltinFunctionId = getBuiltinFunctionId,
	buildDisabledSet = buildDisabledSet,
	isBuiltinDisabled = isBuiltinDisabled,
	analyzeCallBuiltin = analyzeCallBuiltin,
	analyzeBuiltins = analyzeBuiltins,
	getBuiltinInfo = getBuiltinInfo,
	foldBuiltin = foldBuiltin,
	foldBuiltinMath = foldBuiltinMath,
})
