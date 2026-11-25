--!strict
-- Fastcall builtin dispatch table and fast ipairs iterator for the Luau VM.
-- Upstream Luau is MIT licensed. See ../../LICENSE.md and ../../UPSTREAM.json.
local BytecodeDefs = require("../BytecodeDefs")
local RuntimeEnv = require("./RuntimeEnv")

local HOST_WRAPPERS = RuntimeEnv.HOST_WRAPPERS
local invalidateEnvRoot = RuntimeEnv.invalidateEnvRoot
local invalidateEnvAll = RuntimeEnv.invalidateEnvAll
local isTrackedEnv = RuntimeEnv.isTrackedEnv
local recordLockedMetatable = RuntimeEnv.recordLockedMetatable

local Builtins = BytecodeDefs.Builtins
local Opcodes = BytecodeDefs.Opcodes
local LOP_FASTCALL1 = Opcodes.LOP_FASTCALL1
local LOP_FASTCALL2 = Opcodes.LOP_FASTCALL2
local LOP_FASTCALL2K = Opcodes.LOP_FASTCALL2K
local LOP_FASTCALL3 = Opcodes.LOP_FASTCALL3
local LOP_FASTCALL = Opcodes.LOP_FASTCALL

local band = bit32.band
local bor = bit32.bor
local bxor = bit32.bxor
local lshift = bit32.lshift
local rshift = bit32.rshift

local typeofFn: (any) -> string = (typeof or type) :: any
local hostInext: any = (ipairs :: any)({})

export type FastcallHandler = (
	frame: any,
	arg1: any,
	arg2: any,
	arg3: any,
	nargs: number,
	callNresults: number,
	ra: number
) -> (number, any, any)

export type FastcallDesc = {
	bfid: number,
	ra: number,
	callB: number,
	callNresults: number,
	afterCallPc: number,
	handler: FastcallHandler?,
	rootBit: number,
}

local function inext(tbl: { [any]: any }, idx: number?): (number?, any)
	local nextIdx = (idx or 0) + 1
	local v = rawget(tbl, nextIdx)
	if v ~= nil then
		return nextIdx, v
	end
	return nil, nil
end

local function isByte(v: any): boolean
	return type(v) == "number" and v >= 0 and v <= 255
end

local mathExt: { [string]: (...number) -> any } = (math :: unknown) :: { [string]: (...number) -> any }
local mathLerp: ((number, number, number) -> number)? = mathExt.lerp :: any
local mathIsnan: ((number) -> boolean)? = mathExt.isnan :: any
local mathIsinf: ((number) -> boolean)? = mathExt.isinf :: any
local mathIsfinite: ((number) -> boolean)? = mathExt.isfinite :: any
local vecLib: any = if vector then vector else nil
local vecCreate: ((number, number, number, number?) -> any)? = if vecLib then vecLib.create else nil
local vecLerp: ((any, any, number) -> any)? = if vecLib then vecLib.lerp else nil
local hasBufferLib: boolean = buffer ~= nil
local hostVectorSize: number = 0
if vecCreate then
	local okW, wVal = pcall(function()
		return (vecCreate(0, 0, 0, 1) :: any).w
	end)
	hostVectorSize = if okW and wVal == 1 then 4 else 3
end

local function makeUnaryNum(fn: (number) -> any): FastcallHandler
	return function(_frame, arg1, _arg2, _arg3, nargs): (number, any, any)
		if nargs >= 1 and type(arg1) == "number" then
			return 1, fn(arg1), nil
		end
		return -1, nil, nil
	end
end

local function makeBinaryNum(fn: (number, number) -> any): FastcallHandler
	return function(_frame, arg1, arg2, _arg3, nargs): (number, any, any)
		if nargs >= 2 and type(arg1) == "number" and type(arg2) == "number" then
			return 1, fn(arg1, arg2), nil
		end
		return -1, nil, nil
	end
end

local function makeTriNum(fn: (...number) -> any): FastcallHandler
	return function(_frame, arg1, arg2, arg3, nargs): (number, any, any)
		if nargs == 2 and type(arg1) == "number" and type(arg2) == "number" then
			return 1, fn(arg1, arg2), nil
		elseif nargs == 3 and type(arg1) == "number" and type(arg2) == "number" and type(arg3) == "number" then
			return 1, fn(arg1, arg2, arg3), nil
		end
		return -1, nil, nil
	end
end

local function makeUnaryVec(fn: (any) -> any): FastcallHandler
	return function(_frame, arg1, _arg2, _arg3, nargs): (number, any, any)
		if nargs >= 1 and type(arg1) == "vector" then
			return 1, fn(arg1), nil
		end
		return -1, nil, nil
	end
end

local function makeBinaryVec(fn: (any, any) -> any, exact2: boolean?): FastcallHandler
	return function(_frame, arg1, arg2, _arg3, nargs): (number, any, any)
		if (if exact2 then nargs == 2 else nargs >= 2) and type(arg1) == "vector" and type(arg2) == "vector" then
			return 1, fn(arg1, arg2), nil
		end
		return -1, nil, nil
	end
end

local function makeBufRead(fn: (buffer, number) -> number, width: number): FastcallHandler
	return function(_frame, arg1, arg2, _arg3, nargs): (number, any, any)
		if
			nargs >= 2
			and type(arg1) == "buffer"
			and type(arg2) == "number"
			and arg2 >= 0
			and arg2 + width <= buffer.len(arg1)
		then
			return 1, fn(arg1, arg2), nil
		end
		return -1, nil, nil
	end
end

local function makeBufWrite(fn: (buffer, number, number) -> (), width: number): FastcallHandler
	return function(_frame, arg1, arg2, arg3, nargs): (number, any, any)
		if
			nargs >= 3
			and type(arg1) == "buffer"
			and type(arg2) == "number"
			and arg2 >= 0
			and type(arg3) == "number"
			and arg2 + width <= buffer.len(arg1)
		then
			fn(arg1, arg2, arg3)
			return 0, nil, nil
		end
		return -1, nil, nil
	end
end

local function makeBufReadVec(lanes: number): FastcallHandler
	return function(_frame, arg1, arg2, _arg3, nargs): (number, any, any)
		local createVec = vecCreate
		if
			hasBufferLib
			and createVec
			and lanes <= hostVectorSize
			and nargs >= 2
			and type(arg1) == "buffer"
			and type(arg2) == "number"
			and arg2 == arg2
			and arg2 > -1
			and arg2 < 2147483648
		then
			local off = if arg2 >= 0 then math.floor(arg2) else 0
			if off + lanes * 4 <= buffer.len(arg1) then
				local x = buffer.readf32(arg1, off)
				local y = buffer.readf32(arg1, off + 4)
				local z = if lanes >= 3 then buffer.readf32(arg1, off + 8) else 0
				local w = if lanes >= 4 then buffer.readf32(arg1, off + 12) else 0
				return 1, (if hostVectorSize == 4 then createVec(x, y, z, w) else createVec(x, y, z)), nil
			end
		end
		return -1, nil, nil
	end
end

local function makeBufWriteVec(lanes: number): FastcallHandler
	return function(_frame, arg1, arg2, arg3, nargs): (number, any, any)
		if
			hasBufferLib
			and vecLib
			and lanes <= hostVectorSize
			and nargs >= 3
			and type(arg1) == "buffer"
			and type(arg2) == "number"
			and arg2 == arg2
			and arg2 > -1
			and arg2 < 2147483648
			and type(arg3) == "vector"
		then
			local off = if arg2 >= 0 then math.floor(arg2) else 0
			if off + lanes * 4 <= buffer.len(arg1) then
				local vec = arg3 :: any
				buffer.writef32(arg1, off, vec.x)
				buffer.writef32(arg1, off + 4, vec.y)
				if lanes >= 3 then
					buffer.writef32(arg1, off + 8, vec.z)
				end
				if lanes >= 4 then
					buffer.writef32(arg1, off + 12, vec.w)
				end
				return 0, nil, nil
			end
		end
		return -1, nil, nil
	end
end

local FASTCALL_HANDLERS: { [number]: FastcallHandler } = table.create(140) :: { [number]: FastcallHandler }

-- Numeric unary/binary/ternary math & bit32
FASTCALL_HANDLERS[Builtins.LBF_MATH_ABS] = makeUnaryNum(math.abs)
FASTCALL_HANDLERS[Builtins.LBF_MATH_ACOS] = makeUnaryNum(math.acos)
FASTCALL_HANDLERS[Builtins.LBF_MATH_ASIN] = makeUnaryNum(math.asin)
FASTCALL_HANDLERS[Builtins.LBF_MATH_ATAN] = makeUnaryNum(math.atan)
FASTCALL_HANDLERS[Builtins.LBF_MATH_CEIL] = makeUnaryNum(math.ceil)
FASTCALL_HANDLERS[Builtins.LBF_MATH_COS] = makeUnaryNum(math.cos)
FASTCALL_HANDLERS[Builtins.LBF_MATH_COSH] = makeUnaryNum(math.cosh)
FASTCALL_HANDLERS[Builtins.LBF_MATH_DEG] = makeUnaryNum(math.deg)
FASTCALL_HANDLERS[Builtins.LBF_MATH_EXP] = makeUnaryNum(math.exp)
FASTCALL_HANDLERS[Builtins.LBF_MATH_FLOOR] = makeUnaryNum(math.floor)
FASTCALL_HANDLERS[Builtins.LBF_MATH_LOG10] = makeUnaryNum(math.log10)
FASTCALL_HANDLERS[Builtins.LBF_MATH_RAD] = makeUnaryNum(math.rad)
FASTCALL_HANDLERS[Builtins.LBF_MATH_ROUND] = makeUnaryNum(math.round)
FASTCALL_HANDLERS[Builtins.LBF_MATH_SIGN] = makeUnaryNum(math.sign)
FASTCALL_HANDLERS[Builtins.LBF_MATH_SIN] = makeUnaryNum(math.sin)
FASTCALL_HANDLERS[Builtins.LBF_MATH_SINH] = makeUnaryNum(math.sinh)
FASTCALL_HANDLERS[Builtins.LBF_MATH_SQRT] = makeUnaryNum(math.sqrt)
FASTCALL_HANDLERS[Builtins.LBF_MATH_TAN] = makeUnaryNum(math.tan)
FASTCALL_HANDLERS[Builtins.LBF_MATH_TANH] = makeUnaryNum(math.tanh)
FASTCALL_HANDLERS[Builtins.LBF_BIT32_BNOT] = makeUnaryNum(bit32.bnot)
FASTCALL_HANDLERS[Builtins.LBF_BIT32_COUNTLZ] = makeUnaryNum(bit32.countlz)
FASTCALL_HANDLERS[Builtins.LBF_BIT32_COUNTRZ] = makeUnaryNum(bit32.countrz)
FASTCALL_HANDLERS[Builtins.LBF_BIT32_BYTESWAP] = makeUnaryNum(bit32.byteswap)
if mathIsnan then
	FASTCALL_HANDLERS[Builtins.LBF_MATH_ISNAN] = makeUnaryNum(mathIsnan)
end
if mathIsinf then
	FASTCALL_HANDLERS[Builtins.LBF_MATH_ISINF] = makeUnaryNum(mathIsinf)
end
if mathIsfinite then
	FASTCALL_HANDLERS[Builtins.LBF_MATH_ISFINITE] = makeUnaryNum(mathIsfinite)
end

FASTCALL_HANDLERS[Builtins.LBF_MATH_ATAN2] = makeBinaryNum(math.atan2)
FASTCALL_HANDLERS[Builtins.LBF_MATH_FMOD] = makeBinaryNum(math.fmod)
FASTCALL_HANDLERS[Builtins.LBF_MATH_POW] = makeBinaryNum(math.pow)
FASTCALL_HANDLERS[Builtins.LBF_MATH_LDEXP] = makeBinaryNum(math.ldexp)
FASTCALL_HANDLERS[Builtins.LBF_BIT32_LSHIFT] = makeBinaryNum(lshift)
FASTCALL_HANDLERS[Builtins.LBF_BIT32_RSHIFT] = makeBinaryNum(rshift)
FASTCALL_HANDLERS[Builtins.LBF_BIT32_ARSHIFT] = makeBinaryNum(bit32.arshift)
FASTCALL_HANDLERS[Builtins.LBF_BIT32_LROTATE] = makeBinaryNum(bit32.lrotate)
FASTCALL_HANDLERS[Builtins.LBF_BIT32_RROTATE] = makeBinaryNum(bit32.rrotate)

FASTCALL_HANDLERS[Builtins.LBF_MATH_MIN] = makeTriNum(math.min)
FASTCALL_HANDLERS[Builtins.LBF_MATH_MAX] = makeTriNum(math.max)
FASTCALL_HANDLERS[Builtins.LBF_BIT32_BAND] = makeTriNum(band)
FASTCALL_HANDLERS[Builtins.LBF_BIT32_BXOR] = makeTriNum(bxor)
FASTCALL_HANDLERS[Builtins.LBF_BIT32_BOR] = makeTriNum(bor)
FASTCALL_HANDLERS[Builtins.LBF_BIT32_BTEST] = makeTriNum(bit32.btest)

if vecLib then
	FASTCALL_HANDLERS[Builtins.LBF_VECTOR_MAGNITUDE] = makeUnaryVec(vecLib.magnitude)
	FASTCALL_HANDLERS[Builtins.LBF_VECTOR_NORMALIZE] = makeUnaryVec(vecLib.normalize)
	FASTCALL_HANDLERS[Builtins.LBF_VECTOR_FLOOR] = makeUnaryVec(vecLib.floor)
	FASTCALL_HANDLERS[Builtins.LBF_VECTOR_CEIL] = makeUnaryVec(vecLib.ceil)
	FASTCALL_HANDLERS[Builtins.LBF_VECTOR_ABS] = makeUnaryVec(vecLib.abs)
	FASTCALL_HANDLERS[Builtins.LBF_VECTOR_SIGN] = makeUnaryVec(vecLib.sign)
	FASTCALL_HANDLERS[Builtins.LBF_VECTOR_CROSS] = makeBinaryVec(vecLib.cross)
	FASTCALL_HANDLERS[Builtins.LBF_VECTOR_DOT] = makeBinaryVec(vecLib.dot)
	FASTCALL_HANDLERS[Builtins.LBF_VECTOR_MIN] = makeBinaryVec(vecLib.min, true)
	FASTCALL_HANDLERS[Builtins.LBF_VECTOR_MAX] = makeBinaryVec(vecLib.max, true)
end

if hasBufferLib then
	FASTCALL_HANDLERS[Builtins.LBF_BUFFER_READI8] = makeBufRead(buffer.readi8, 1)
	FASTCALL_HANDLERS[Builtins.LBF_BUFFER_READU8] = makeBufRead(buffer.readu8, 1)
	FASTCALL_HANDLERS[Builtins.LBF_BUFFER_READI16] = makeBufRead(buffer.readi16, 2)
	FASTCALL_HANDLERS[Builtins.LBF_BUFFER_READU16] = makeBufRead(buffer.readu16, 2)
	FASTCALL_HANDLERS[Builtins.LBF_BUFFER_READI32] = makeBufRead(buffer.readi32, 4)
	FASTCALL_HANDLERS[Builtins.LBF_BUFFER_READU32] = makeBufRead(buffer.readu32, 4)
	FASTCALL_HANDLERS[Builtins.LBF_BUFFER_READF32] = makeBufRead(buffer.readf32, 4)
	FASTCALL_HANDLERS[Builtins.LBF_BUFFER_READF64] = makeBufRead(buffer.readf64, 8)
	FASTCALL_HANDLERS[Builtins.LBF_BUFFER_WRITEU8] = makeBufWrite(buffer.writeu8, 1)
	FASTCALL_HANDLERS[Builtins.LBF_BUFFER_WRITEU16] = makeBufWrite(buffer.writeu16, 2)
	FASTCALL_HANDLERS[Builtins.LBF_BUFFER_WRITEU32] = makeBufWrite(buffer.writeu32, 4)
	FASTCALL_HANDLERS[Builtins.LBF_BUFFER_WRITEF32] = makeBufWrite(buffer.writef32, 4)
	FASTCALL_HANDLERS[Builtins.LBF_BUFFER_WRITEF64] = makeBufWrite(buffer.writef64, 8)
end

FASTCALL_HANDLERS[Builtins.LBF_BUFFER_READVECTORF32X2] = makeBufReadVec(2)
FASTCALL_HANDLERS[Builtins.LBF_BUFFER_READVECTORF32X3] = makeBufReadVec(3)
FASTCALL_HANDLERS[Builtins.LBF_BUFFER_READVECTORF32X4] = makeBufReadVec(4)
FASTCALL_HANDLERS[Builtins.LBF_BUFFER_WRITEVECTORF32X2] = makeBufWriteVec(2)
FASTCALL_HANDLERS[Builtins.LBF_BUFFER_WRITEVECTORF32X3] = makeBufWriteVec(3)
FASTCALL_HANDLERS[Builtins.LBF_BUFFER_WRITEVECTORF32X4] = makeBufWriteVec(4)

-- Individual specialized fastcalls
FASTCALL_HANDLERS[Builtins.LBF_ASSERT] = function(_frame, arg1, arg2, _arg3, nargs): (number, any, any)
	if nargs == 1 and arg1 then
		return 1, arg1, nil
	elseif nargs == 2 and arg1 then
		return 2, arg1, arg2
	end
	return -1, nil, nil
end

FASTCALL_HANDLERS[Builtins.LBF_MATH_LOG] = function(_frame, arg1, arg2, _arg3, nargs): (number, any, any)
	if nargs == 1 and type(arg1) == "number" then
		return 1, math.log(arg1), nil
	elseif nargs >= 2 and type(arg1) == "number" and type(arg2) == "number" then
		return 1, math.log(arg1, arg2), nil
	end
	return -1, nil, nil
end

FASTCALL_HANDLERS[Builtins.LBF_MATH_CLAMP] = function(_frame, arg1, arg2, arg3, nargs): (number, any, any)
	if nargs >= 3 and type(arg1) == "number" and type(arg2) == "number" and type(arg3) == "number" then
		return 1, math.clamp(arg1, arg2, arg3), nil
	end
	return -1, nil, nil
end

FASTCALL_HANDLERS[Builtins.LBF_MATH_FREXP] = function(_frame, arg1, _arg2, _arg3, nargs): (number, any, any)
	if nargs >= 1 and type(arg1) == "number" then
		local m, e = math.frexp(arg1)
		return 2, m, e
	end
	return -1, nil, nil
end

FASTCALL_HANDLERS[Builtins.LBF_MATH_MODF] = function(_frame, arg1, _arg2, _arg3, nargs): (number, any, any)
	if nargs >= 1 and type(arg1) == "number" then
		local ip, fp = math.modf(arg1)
		return 2, ip, fp
	end
	return -1, nil, nil
end

FASTCALL_HANDLERS[Builtins.LBF_MATH_LERP] = function(_frame, arg1, arg2, arg3, nargs): (number, any, any)
	local fn = mathLerp
	if fn and nargs >= 3 and type(arg1) == "number" and type(arg2) == "number" and type(arg3) == "number" then
		return 1, fn(arg1, arg2, arg3), nil
	end
	return -1, nil, nil
end

FASTCALL_HANDLERS[Builtins.LBF_BIT32_EXTRACT] = function(_frame, arg1, arg2, arg3, nargs): (number, any, any)
	if nargs == 2 and type(arg1) == "number" and type(arg2) == "number" then
		local f = math.floor(arg2)
		if f >= 0 and f < 32 then
			return 1, bit32.extract(arg1, f), nil
		end
	elseif nargs == 3 and type(arg1) == "number" and type(arg2) == "number" and type(arg3) == "number" then
		local f = math.floor(arg2)
		local w = math.floor(arg3)
		if f >= 0 and w > 0 and f + w <= 32 then
			return 1, bit32.extract(arg1, f, w), nil
		end
	end
	return -1, nil, nil
end

FASTCALL_HANDLERS[Builtins.LBF_BIT32_EXTRACTK] = function(_frame, arg1, arg2, _arg3, nargs): (number, any, any)
	if nargs >= 2 and type(arg1) == "number" and type(arg2) == "number" and arg2 == arg2 then
		local fw = math.floor(arg2)
		if fw >= 0 and fw < 1024 then
			local f = band(fw, 31)
			local w = rshift(fw, 5) + 1
			if f + w <= 32 then
				return 1, bit32.extract(arg1, f, w), nil
			end
		end
	end
	return -1, nil, nil
end

FASTCALL_HANDLERS[Builtins.LBF_BIT32_REPLACE] = function(_frame, arg1, arg2, arg3, nargs): (number, any, any)
	if nargs == 3 and type(arg1) == "number" and type(arg2) == "number" and type(arg3) == "number" then
		local f = math.floor(arg3)
		if f >= 0 and f < 32 then
			return 1, bit32.replace(arg1, arg2, f), nil
		end
	end
	return -1, nil, nil
end

FASTCALL_HANDLERS[Builtins.LBF_TYPE] = function(_frame, arg1, _arg2, _arg3, nargs): (number, any, any)
	if nargs >= 1 then
		return 1, type(arg1), nil
	end
	return -1, nil, nil
end

FASTCALL_HANDLERS[Builtins.LBF_TYPEOF] = function(_frame, arg1, _arg2, _arg3, nargs): (number, any, any)
	if nargs >= 1 then
		return 1, typeofFn(arg1), nil
	end
	return -1, nil, nil
end

FASTCALL_HANDLERS[Builtins.LBF_STRING_LEN] = function(_frame, arg1, _arg2, _arg3, nargs): (number, any, any)
	if nargs >= 1 and type(arg1) == "string" then
		return 1, #arg1, nil
	end
	return -1, nil, nil
end

FASTCALL_HANDLERS[Builtins.LBF_STRING_BYTE] = function(_frame, arg1, arg2, _arg3, nargs): (number, any, any)
	if type(arg1) == "string" then
		if nargs == 1 then
			local res = string.byte(arg1)
			if res ~= nil then
				return 1, res, nil
			end
		elseif nargs == 2 and type(arg2) == "number" then
			local res = string.byte(arg1, arg2)
			if res ~= nil then
				return 1, res, nil
			end
		end
	end
	return -1, nil, nil
end

FASTCALL_HANDLERS[Builtins.LBF_STRING_CHAR] = function(_frame, arg1, arg2, arg3, nargs): (number, any, any)
	if nargs == 1 and isByte(arg1) then
		return 1, string.char(arg1), nil
	elseif nargs == 2 and isByte(arg1) and isByte(arg2) then
		return 1, string.char(arg1, arg2), nil
	elseif nargs == 3 and isByte(arg1) and isByte(arg2) and isByte(arg3) then
		return 1, string.char(arg1, arg2, arg3), nil
	end
	return -1, nil, nil
end

FASTCALL_HANDLERS[Builtins.LBF_STRING_SUB] = function(_frame, arg1, arg2, arg3, nargs): (number, any, any)
	if type(arg1) == "string" and type(arg2) == "number" then
		if nargs == 2 then
			return 1, string.sub(arg1, arg2), nil
		elseif nargs >= 3 and type(arg3) == "number" then
			return 1, string.sub(arg1, arg2, arg3), nil
		end
	end
	return -1, nil, nil
end

FASTCALL_HANDLERS[Builtins.LBF_TABLE_INSERT] = function(_frame, arg1, arg2, _arg3, nargs): (number, any, any)
	if nargs == 2 and type(arg1) == "table" and not table.isfrozen(arg1) and getmetatable(arg1 :: any) == nil then
		table.insert(arg1, arg2)
		return 0, nil, nil
	end
	return -1, nil, nil
end

FASTCALL_HANDLERS[Builtins.LBF_TABLE_UNPACK] = function(
	frame,
	arg1: any,
	arg2: any,
	arg3: any,
	nargs,
	callNresults,
	ra
): (number, any, any)
	if callNresults < 0 and nargs >= 1 and type(arg1) == "table" and getmetatable(arg1 :: any) == nil then
		local tbl: { any } = arg1 :: any
		local n = -1
		if nargs == 1 then
			n = rawlen(tbl)
		elseif nargs == 3 and arg2 == 1 and type(arg3) == "number" then
			local v = if arg3 >= 0 then math.floor(arg3) else math.ceil(arg3)
			if v >= 0 then
				n = v
			end
		end
		if n >= 0 and n <= 255 and n <= rawlen(tbl) then
			local stack = frame.stack
			for i = 1, n do
				stack[ra + i - 1] = rawget(tbl, i)
			end
			frame.top = ra + n
			return -2, nil, nil
		end
	end
	return -1, nil, nil
end

FASTCALL_HANDLERS[Builtins.LBF_TABLE_CREATE] = function(_frame, arg1, arg2, _arg3, nargs): (number, any, any)
	if nargs >= 1 and type(arg1) == "number" and arg1 == arg1 and arg1 > -1 and arg1 <= 65536 then
		local size = if arg1 >= 0 then math.floor(arg1) else 0
		return 1, (if nargs >= 2 then table.create(size, arg2) else table.create(size)), nil
	end
	return -1, nil, nil
end

FASTCALL_HANDLERS[Builtins.LBF_TABLE_CLEAR] = function(frame, arg1, _arg2, _arg3, nargs): (number, any, any)
	if nargs >= 1 and type(arg1) == "table" and not table.isfrozen(arg1 :: any) then
		if RuntimeEnv.isReadOnlyProxy(arg1) then
			return -1, nil, nil
		end
		local meta = frame.meta
		local ctx = meta.ctx
		if arg1 == meta.env or arg1 == ctx.env or isTrackedEnv(arg1) then
			invalidateEnvAll(if arg1 == meta.env or arg1 == ctx.env then ctx else nil, arg1 :: any)
		end
		table.clear(arg1 :: any)
		return 0, nil, nil
	end
	return -1, nil, nil
end

FASTCALL_HANDLERS[Builtins.LBF_RAWGET] = function(frame, arg1: any, arg2: any, _arg3, nargs): (number, any, any)
	if nargs >= 2 and type(arg1) == "table" then
		local tbl: { [any]: any } = arg1 :: any
		local res = rawget(tbl, arg2)
		if res ~= nil and (type(res) == "function" or type(res) == "table") then
			res = HOST_WRAPPERS[res] or res
			local wr = frame.meta.ctx.resourceLimitWrappers
			if wr ~= nil then
				res = wr[res] or res
			end
		end
		return 1, res, nil
	end
	return -1, nil, nil
end

FASTCALL_HANDLERS[Builtins.LBF_RAWSET] = function(frame, arg1: any, arg2: any, arg3: any, nargs): (number, any, any)
	if
		nargs >= 3
		and type(arg1) == "table"
		and not table.isfrozen(arg1 :: any)
		and not RuntimeEnv.isReadOnlyProxy(arg1)
		and arg2 ~= nil
		and not (type(arg2) == "number" and arg2 ~= arg2)
	then
		local meta = frame.meta
		local ctx = meta.ctx
		if arg1 == meta.env or arg1 == ctx.env or isTrackedEnv(arg1) then
			invalidateEnvRoot(if arg1 == meta.env or arg1 == ctx.env then ctx else nil, arg1 :: any, arg2)
		end
		local tbl: { [any]: any } = arg1 :: any
		return 1, rawset(tbl, arg2, arg3), nil
	end
	return -1, nil, nil
end

FASTCALL_HANDLERS[Builtins.LBF_RAWEQUAL] = function(_frame, arg1, arg2, _arg3, nargs): (number, any, any)
	if nargs >= 2 then
		return 1, rawequal(arg1, arg2), nil
	end
	return -1, nil, nil
end

FASTCALL_HANDLERS[Builtins.LBF_RAWLEN] = function(_frame, arg1: any, _arg2, _arg3, nargs): (number, any, any)
	if nargs >= 1 and (type(arg1) == "table" or type(arg1) == "string") then
		return 1, rawlen(arg1 :: any), nil
	end
	return -1, nil, nil
end

FASTCALL_HANDLERS[Builtins.LBF_SELECT_VARARG] = function(
	frame,
	arg1: any,
	_arg2,
	_arg3,
	nargs,
	callNresults
): (number, any, any)
	if nargs ~= -1 or callNresults ~= 1 then
		return -1, nil, nil
	end
	local nvarargs = frame.nvarargs
	if type(arg1) == "string" and string.byte(arg1, 1) == 35 then
		return 1, nvarargs, nil
	elseif type(arg1) == "number" then
		local idx = if arg1 >= 0 then math.floor(arg1) else math.ceil(arg1)
		if idx >= 1 and idx <= nvarargs then
			return 1, frame.varargs[idx], nil
		end
	end
	return -1, nil, nil
end

FASTCALL_HANDLERS[Builtins.LBF_GETMETATABLE] = function(_frame, arg1: any, _arg2, _arg3, nargs): (number, any, any)
	if nargs >= 1 then
		if type(arg1) == "string" then
			return 1, "The metatable is locked", nil
		end
		return 1, getmetatable(arg1 :: any), nil
	end
	return -1, nil, nil
end

FASTCALL_HANDLERS[Builtins.LBF_SETMETATABLE] = function(frame, arg1, arg2, _arg3, nargs): (number, any, any)
	if nargs >= 2 and type(arg1) == "table" and not table.isfrozen(arg1) and (arg2 == nil or type(arg2) == "table") then
		local cur = getmetatable(arg1 :: any)
		if cur == nil or (type(cur) == "table" and rawget(cur, "__metatable") == nil) then
			local meta = frame.meta
			local ctx = meta.ctx
			if arg1 == meta.env or arg1 == ctx.env or isTrackedEnv(arg1) then
				invalidateEnvAll(if arg1 == meta.env or arg1 == ctx.env then ctx else nil, arg1 :: any)
			end
			local res = setmetatable(arg1 :: any, arg2 :: any)
			recordLockedMetatable(arg1, arg2)
			return 1, res, nil
		end
	end
	return -1, nil, nil
end

FASTCALL_HANDLERS[Builtins.LBF_TONUMBER] = function(_frame, arg1, _arg2, _arg3, nargs): (number, any, any)
	if nargs == 1 then
		return 1, tonumber(arg1), nil
	end
	return -1, nil, nil
end

FASTCALL_HANDLERS[Builtins.LBF_TOSTRING] = function(_frame, arg1, _arg2, _arg3, nargs): (number, any, any)
	if nargs >= 1 then
		return 1, tostring(arg1), nil
	end
	return -1, nil, nil
end

FASTCALL_HANDLERS[Builtins.LBF_VECTOR] = function(_frame, arg1, arg2, arg3, nargs): (number, any, any)
	if vecLib and nargs == 3 and type(arg1) == "number" and type(arg2) == "number" and type(arg3) == "number" then
		return 1, vecLib.create(arg1, arg2, arg3), nil
	end
	return -1, nil, nil
end

FASTCALL_HANDLERS[Builtins.LBF_VECTOR_CLAMP] = function(_frame, arg1, arg2, arg3, nargs): (number, any, any)
	if vecLib and nargs >= 3 and type(arg1) == "vector" and type(arg2) == "vector" and type(arg3) == "vector" then
		return 1, vecLib.clamp(arg1, arg2, arg3), nil
	end
	return -1, nil, nil
end

FASTCALL_HANDLERS[Builtins.LBF_VECTOR_LERP] = function(_frame, arg1, arg2, arg3, nargs): (number, any, any)
	local fn = vecLerp
	if fn and nargs >= 3 and type(arg1) == "vector" and type(arg2) == "vector" and type(arg3) == "number" then
		return 1, fn(arg1, arg2, arg3), nil
	end
	return -1, nil, nil
end

@native
local function execFastcallOp(frame: any, pc: number, op: number): number
	local step = if op == LOP_FASTCALL1 or op == LOP_FASTCALL then 1 else 2
	local meta = frame.meta
	local mask = meta.ctx.safeRootsMask
	if mask == 0 then
		return pc + step
	end

	local pdata = meta.pdata
	local fcInfo = pdata.fcInfo
	if not fcInfo then
		return pc + step
	end
	local fc: FastcallDesc? = fcInfo[pc]
	if not fc then
		return pc + step
	end
	local rbit = fc.rootBit
	if rbit == 0 or band(mask, rbit) ~= rbit then
		return pc + step
	end
	local handler = fc.handler
	if not handler then
		return pc + step
	end

	local stack = frame.stack
	local ra = fc.ra
	local callB = fc.callB
	local callNresults = fc.callNresults
	local afterCallPc = fc.afterCallPc
	local nargs: number
	if op == LOP_FASTCALL1 then
		if callB == 0 then
			nargs = -1
		elseif callB == 2 then
			nargs = 1
		else
			return pc + step
		end
	elseif op == LOP_FASTCALL2 or op == LOP_FASTCALL2K then
		if callB == 3 or (op == LOP_FASTCALL2K and callB == 4 and fc.bfid == Builtins.LBF_BIT32_EXTRACTK) then
			nargs = 2
		else
			return pc + step
		end
	elseif op == LOP_FASTCALL3 then
		if callB ~= 4 then
			return pc + step
		end
		nargs = 3
	else
		if callB == 0 then
			return pc + step
		end
		nargs = callB - 1
	end

	local arg1: any, arg2: any, arg3: any
	if op == LOP_FASTCALL1 then
		arg1 = stack[pdata.argB[pc]]
	elseif op == LOP_FASTCALL2 then
		arg1 = stack[pdata.argB[pc]]
		arg2 = stack[pdata.argC[pc]]
	elseif op == LOP_FASTCALL2K then
		arg1 = stack[pdata.argB[pc]]
		arg2 = pdata.auxVal[pc]
	elseif op == LOP_FASTCALL3 then
		arg1 = stack[pdata.argB[pc]]
		arg2 = stack[pdata.argC[pc]]
		arg3 = stack[pdata.argD[pc]]
	else
		arg1 = stack[ra + 1]
		arg2 = stack[ra + 2]
		arg3 = stack[ra + 3]
	end

	local resKind, res1, res2 = handler(frame, arg1, arg2, arg3, nargs, callNresults, ra)
	if resKind == 1 then
		if callNresults == 1 then
			stack[ra] = res1
		elseif callNresults < 0 then
			stack[ra] = res1
			frame.top = ra + 1
		elseif callNresults > 1 then
			stack[ra] = res1
			for i = 1, callNresults - 1 do
				stack[ra + i] = nil
			end
		end
		return afterCallPc
	elseif resKind == 0 then
		if callNresults < 0 then
			frame.top = ra
		else
			for i = 0, callNresults - 1 do
				stack[ra + i] = nil
			end
		end
		return afterCallPc
	elseif resKind == 2 then
		if callNresults < 0 then
			stack[ra] = res1
			stack[ra + 1] = res2
			frame.top = ra + 2
		else
			if callNresults >= 1 then
				stack[ra] = res1
			end
			if callNresults >= 2 then
				stack[ra + 1] = res2
			end
			for i = 3, callNresults do
				stack[ra + i - 1] = nil
			end
		end
		return afterCallPc
	elseif resKind == -2 then
		return afterCallPc
	end

	return pc + step
end

local chunkPrefix = ""
do
	local _, sample = pcall(function()
		error("@", 1)
	end)
	local s = tostring(sample)
	chunkPrefix = string.match(s, "^(.*):%d+: @$") or ""
end

return table.freeze({
	FASTCALL_HANDLERS = FASTCALL_HANDLERS,
	execFastcallOp = execFastcallOp,
	hostInext = hostInext,
	inext = inext,
	chunkPrefix = chunkPrefix,
})
