--!strict
-- Bytecode module verification and predecoding for the Luau VM.
-- Upstream Luau is MIT licensed. See ../../LICENSE.md and ../../UPSTREAM.json.
local BytecodeCodec = require("../BytecodeCodec")
local BytecodeDefs = require("../BytecodeDefs")
local Fastcalls = require("./Fastcalls")
local RuntimeEnv = require("./RuntimeEnv")
local Types = require("../Types")

type Proto = Types.Proto
type ProtoModule = Types.ProtoModule
type FastcallDesc = Fastcalls.FastcallDesc
type ProtoTemplate = RuntimeEnv.ProtoTemplate
type PredecodedProto = RuntimeEnv.PredecodedProto

local band = bit32.band
local rshift = bit32.rshift

local Opcodes = BytecodeDefs.Opcodes
local Tags = BytecodeDefs.Tags
local Captures = BytecodeDefs.Captures

local LBC_CONSTANT_NIL = Tags.LBC_CONSTANT_NIL
local LBC_CONSTANT_BOOLEAN = Tags.LBC_CONSTANT_BOOLEAN
local LBC_CONSTANT_NUMBER = Tags.LBC_CONSTANT_NUMBER
local LBC_CONSTANT_STRING = Tags.LBC_CONSTANT_STRING
local LBC_CONSTANT_IMPORT = Tags.LBC_CONSTANT_IMPORT
local LBC_CONSTANT_TABLE = Tags.LBC_CONSTANT_TABLE
local LBC_CONSTANT_CLOSURE = Tags.LBC_CONSTANT_CLOSURE
local LBC_CONSTANT_VECTOR = Tags.LBC_CONSTANT_VECTOR
local LBC_CONSTANT_TABLE_WITH_CONSTANTS = Tags.LBC_CONSTANT_TABLE_WITH_CONSTANTS
local LBC_CONSTANT_CLASS_SHAPE = Tags.LBC_CONSTANT_CLASS_SHAPE
local LBC_CONSTANT_VECTORD = Tags.LBC_CONSTANT_VECTORD
local FASTCALL_HANDLERS = Fastcalls.FASTCALL_HANDLERS
local BUILTIN_ROOT_BIT = RuntimeEnv.BUILTIN_ROOT_BIT
local ROOT_BITS = RuntimeEnv.ROOT_BITS
local ALL_SAFE_ROOTS = RuntimeEnv.ALL_SAFE_ROOTS
local SAFE_INVALIDATION_KEYS = RuntimeEnv.SAFE_INVALIDATION_KEYS
local VOP = RuntimeEnv.VOP
local RAW_TO_VOP = RuntimeEnv.RAW_TO_VOP
local VOP_CALL = VOP.CALL
local VOP_CAPTURE = VOP.CAPTURE
local VOP_NAMECALL = VOP.NAMECALL
local VOP_GETTABLEKS = VOP.GETTABLEKS
local VOP_GETIMPORT = VOP.GETIMPORT
local VOP_NAMECALL_CALL = VOP.NAMECALL_CALL
local VOP_GETTABLEKS_CALL = VOP.GETTABLEKS_CALL
local VOP_GETIMPORT_CALL = VOP.GETIMPORT_CALL

do
	local _, sample = pcall(function()
		error("@", 1)
	end)
	local s = tostring(sample)
	local pfx = string.match(s, "^(.*):%d+: @$") or ""
	RuntimeEnv.registerVmChunkPrefix(pfx)
end

local LOP__COUNT = Opcodes.LOP__COUNT
local LOP_LOADNIL = Opcodes.LOP_LOADNIL
local LOP_LOADB = Opcodes.LOP_LOADB
local LOP_LOADN = Opcodes.LOP_LOADN
local LOP_LOADK = Opcodes.LOP_LOADK
local LOP_MOVE = Opcodes.LOP_MOVE
local LOP_GETGLOBAL = Opcodes.LOP_GETGLOBAL
local LOP_SETGLOBAL = Opcodes.LOP_SETGLOBAL
local LOP_GETUPVAL = Opcodes.LOP_GETUPVAL
local LOP_SETUPVAL = Opcodes.LOP_SETUPVAL
local LOP_CLOSEUPVALS = Opcodes.LOP_CLOSEUPVALS
local LOP_GETIMPORT = Opcodes.LOP_GETIMPORT
local LOP_GETTABLE = Opcodes.LOP_GETTABLE
local LOP_SETTABLE = Opcodes.LOP_SETTABLE
local LOP_GETTABLEKS = Opcodes.LOP_GETTABLEKS
local LOP_SETTABLEKS = Opcodes.LOP_SETTABLEKS
local LOP_GETTABLEN = Opcodes.LOP_GETTABLEN
local LOP_SETTABLEN = Opcodes.LOP_SETTABLEN
local LOP_NEWCLOSURE = Opcodes.LOP_NEWCLOSURE
local LOP_NAMECALL = Opcodes.LOP_NAMECALL
local LOP_CALL = Opcodes.LOP_CALL
local LOP_RETURN = Opcodes.LOP_RETURN
local LOP_JUMP = Opcodes.LOP_JUMP
local LOP_JUMPBACK = Opcodes.LOP_JUMPBACK
local LOP_JUMPIF = Opcodes.LOP_JUMPIF
local LOP_JUMPIFNOT = Opcodes.LOP_JUMPIFNOT
local LOP_JUMPIFEQ = Opcodes.LOP_JUMPIFEQ
local LOP_JUMPIFLE = Opcodes.LOP_JUMPIFLE
local LOP_JUMPIFLT = Opcodes.LOP_JUMPIFLT
local LOP_JUMPIFNOTEQ = Opcodes.LOP_JUMPIFNOTEQ
local LOP_JUMPIFNOTLE = Opcodes.LOP_JUMPIFNOTLE
local LOP_JUMPIFNOTLT = Opcodes.LOP_JUMPIFNOTLT
local LOP_ADD = Opcodes.LOP_ADD
local LOP_SUB = Opcodes.LOP_SUB
local LOP_MUL = Opcodes.LOP_MUL
local LOP_DIV = Opcodes.LOP_DIV
local LOP_MOD = Opcodes.LOP_MOD
local LOP_POW = Opcodes.LOP_POW
local LOP_ADDK = Opcodes.LOP_ADDK
local LOP_SUBK = Opcodes.LOP_SUBK
local LOP_MULK = Opcodes.LOP_MULK
local LOP_DIVK = Opcodes.LOP_DIVK
local LOP_MODK = Opcodes.LOP_MODK
local LOP_POWK = Opcodes.LOP_POWK
local LOP_AND = Opcodes.LOP_AND
local LOP_OR = Opcodes.LOP_OR
local LOP_ANDK = Opcodes.LOP_ANDK
local LOP_ORK = Opcodes.LOP_ORK
local LOP_CONCAT = Opcodes.LOP_CONCAT
local LOP_NOT = Opcodes.LOP_NOT
local LOP_MINUS = Opcodes.LOP_MINUS
local LOP_LENGTH = Opcodes.LOP_LENGTH
local LOP_NEWTABLE = Opcodes.LOP_NEWTABLE
local LOP_DUPTABLE = Opcodes.LOP_DUPTABLE
local LOP_SETLIST = Opcodes.LOP_SETLIST
local LOP_FORNPREP = Opcodes.LOP_FORNPREP
local LOP_FORNLOOP = Opcodes.LOP_FORNLOOP
local LOP_FORGLOOP = Opcodes.LOP_FORGLOOP
local LOP_FORGPREP_INEXT = Opcodes.LOP_FORGPREP_INEXT
local LOP_FASTCALL3 = Opcodes.LOP_FASTCALL3
local LOP_FORGPREP_NEXT = Opcodes.LOP_FORGPREP_NEXT
local LOP_NATIVECALL = Opcodes.LOP_NATIVECALL
local LOP_GETVARARGS = Opcodes.LOP_GETVARARGS
local LOP_DUPCLOSURE = Opcodes.LOP_DUPCLOSURE
local LOP_LOADKX = Opcodes.LOP_LOADKX
local LOP_JUMPX = Opcodes.LOP_JUMPX
local LOP_FASTCALL = Opcodes.LOP_FASTCALL
local LOP_CAPTURE = Opcodes.LOP_CAPTURE
local LOP_SUBRK = Opcodes.LOP_SUBRK
local LOP_DIVRK = Opcodes.LOP_DIVRK
local LOP_FASTCALL1 = Opcodes.LOP_FASTCALL1
local LOP_FASTCALL2 = Opcodes.LOP_FASTCALL2
local LOP_FASTCALL2K = Opcodes.LOP_FASTCALL2K
local LOP_FORGPREP = Opcodes.LOP_FORGPREP
local LOP_JUMPXEQKNIL = Opcodes.LOP_JUMPXEQKNIL
local LOP_JUMPXEQKB = Opcodes.LOP_JUMPXEQKB
local LOP_JUMPXEQKN = Opcodes.LOP_JUMPXEQKN
local LOP_JUMPXEQKS = Opcodes.LOP_JUMPXEQKS
local LOP_IDIV = Opcodes.LOP_IDIV
local LOP_IDIVK = Opcodes.LOP_IDIVK
local LOP_GETUDATAKS = Opcodes.LOP_GETUDATAKS
local LOP_SETUDATAKS = Opcodes.LOP_SETUDATAKS
local LOP_NAMECALLUDATA = Opcodes.LOP_NAMECALLUDATA
local LOP_NEWCLASSMEMBER = Opcodes.LOP_NEWCLASSMEMBER
local LOP_CALLFB = Opcodes.LOP_CALLFB
local LOP_CMPPROTO = Opcodes.LOP_CMPPROTO
local LOP_FASTPCALL = Opcodes.LOP_FASTPCALL
local LOP_NEWCLASS = Opcodes.LOP_NEWCLASS
local LOP_CONSTRUCT = Opcodes.LOP_CONSTRUCT
local LOP_FINCONSTRUCT = Opcodes.LOP_FINCONSTRUCT
local LOP_GETPRIVATEFIELD = Opcodes.LOP_GETPRIVATEFIELD
local LOP_SETPRIVATEFIELD = Opcodes.LOP_SETPRIVATEFIELD

local LBF_MATH_ABS = BytecodeDefs.Builtins.LBF_MATH_ABS
local LBF_MATH_COS = BytecodeDefs.Builtins.LBF_MATH_COS
local LBF_MATH_FLOOR = BytecodeDefs.Builtins.LBF_MATH_FLOOR
local LBF_MATH_CEIL = BytecodeDefs.Builtins.LBF_MATH_CEIL
local LBF_MATH_SIN = BytecodeDefs.Builtins.LBF_MATH_SIN
local LBF_MATH_SIGN = BytecodeDefs.Builtins.LBF_MATH_SIGN
local LBF_MATH_SQRT = BytecodeDefs.Builtins.LBF_MATH_SQRT
local LBF_MATH_ROUND = BytecodeDefs.Builtins.LBF_MATH_ROUND
local LBF_TYPE = BytecodeDefs.Builtins.LBF_TYPE
local LBF_TYPEOF = BytecodeDefs.Builtins.LBF_TYPEOF
local LBF_BIT32_BNOT = BytecodeDefs.Builtins.LBF_BIT32_BNOT
local LBF_BIT32_BTEST = BytecodeDefs.Builtins.LBF_BIT32_BTEST
local LBF_BIT32_BXOR = BytecodeDefs.Builtins.LBF_BIT32_BXOR
local LBF_BIT32_BAND = BytecodeDefs.Builtins.LBF_BIT32_BAND
local LBF_BIT32_BOR = BytecodeDefs.Builtins.LBF_BIT32_BOR
local LBF_BIT32_LSHIFT = BytecodeDefs.Builtins.LBF_BIT32_LSHIFT
local LBF_BIT32_RSHIFT = BytecodeDefs.Builtins.LBF_BIT32_RSHIFT
local LBF_STRING_BYTE = BytecodeDefs.Builtins.LBF_STRING_BYTE
local LBF_STRING_LEN = BytecodeDefs.Builtins.LBF_STRING_LEN
local LBF_STRING_SUB = BytecodeDefs.Builtins.LBF_STRING_SUB
local LBF_RAWEQUAL = BytecodeDefs.Builtins.LBF_RAWEQUAL
local LBF_MATH_MIN = BytecodeDefs.Builtins.LBF_MATH_MIN
local LBF_MATH_MAX = BytecodeDefs.Builtins.LBF_MATH_MAX
local LBF_MATH_CLAMP = BytecodeDefs.Builtins.LBF_MATH_CLAMP
local LBF_TABLE_INSERT = BytecodeDefs.Builtins.LBF_TABLE_INSERT
local LBF_TABLE_CREATE = BytecodeDefs.Builtins.LBF_TABLE_CREATE
local LBF_SELECT_VARARG = BytecodeDefs.Builtins.LBF_SELECT_VARARG
local LBF_GETMETATABLE = BytecodeDefs.Builtins.LBF_GETMETATABLE
local LBF_SETMETATABLE = BytecodeDefs.Builtins.LBF_SETMETATABLE
local LBF_TONUMBER = BytecodeDefs.Builtins.LBF_TONUMBER
local LBF_TOSTRING = BytecodeDefs.Builtins.LBF_TOSTRING
local LBF_VECTOR = BytecodeDefs.Builtins.LBF_VECTOR

local TWO_WORD_OP_ARR: { boolean } = table.create(256, false)
local JUMP_D_OP_ARR: { boolean } = table.create(256, false)
local CLASS_OPCODE_ARR: { boolean } = table.create(256, false)
do
	local opLengths = BytecodeDefs.opLengths
	local isJumpD = BytecodeDefs.isJumpD
	for op = 0, 255 do
		if opLengths[op] == 2 then
			TWO_WORD_OP_ARR[op + 1] = true
		end
		if isJumpD[op] then
			JUMP_D_OP_ARR[op + 1] = true
		end
	end
	CLASS_OPCODE_ARR[LOP_NEWCLASS + 1] = true
	CLASS_OPCODE_ARR[LOP_NEWCLASSMEMBER + 1] = true
	CLASS_OPCODE_ARR[LOP_CONSTRUCT + 1] = true
	CLASS_OPCODE_ARR[LOP_FINCONSTRUCT + 1] = true
	CLASS_OPCODE_ARR[LOP_GETPRIVATEFIELD + 1] = true
	CLASS_OPCODE_ARR[LOP_SETPRIVATEFIELD + 1] = true
end

local function isScalarTag(kt: any): boolean
	return kt == LBC_CONSTANT_NIL
		or kt == LBC_CONSTANT_BOOLEAN
		or kt == LBC_CONSTANT_NUMBER
		or kt == LBC_CONSTANT_STRING
		or kt == LBC_CONSTANT_VECTOR
		or kt == LBC_CONSTANT_VECTORD
end

local function isValidProtoHeader(p: any): boolean
	if type(p) ~= "table" or getmetatable(p) ~= nil then
		return false
	end
	local maxstack = p.maxstacksize
	local numparams = p.numparams
	local nups = p.nups
	local linedefined = p.linedefined
	local linegap = p.linegaplog2
	return type(maxstack) == "number"
		and math.floor(maxstack) == maxstack
		and maxstack >= 0
		and maxstack <= 255
		and type(numparams) == "number"
		and math.floor(numparams) == numparams
		and numparams >= 0
		and numparams <= maxstack
		and type(nups) == "number"
		and math.floor(nups) == nups
		and nups >= 0
		and nups <= 255
		and (linedefined == nil or (type(linedefined) == "number" and linedefined >= 0 and linedefined < math.huge and math.floor(
			linedefined
		) == linedefined))
		and (p.debugname == nil or type(p.debugname) == "string")
		and (p.lineData == nil or type(p.lineData) == "string")
		and (linegap == nil or (type(linegap) == "number" and linegap >= 0 and linegap <= 31 and math.floor(linegap) == linegap))
		and (p.upvalues == nil or (type(p.upvalues) == "table" and getmetatable(p.upvalues) == nil))
		and type(p.code) == "table"
		and getmetatable(p.code) == nil
		and type(p.kTypes) == "table"
		and getmetatable(p.kTypes) == nil
		and type(p.kValues) == "table"
		and getmetatable(p.kValues) == nil
		and type(p.p) == "table"
		and getmetatable(p.p) == nil
end

local function hasNaNVectorComponent(vec: any): boolean
	return vec[1] ~= vec[1] or vec[2] ~= vec[2] or vec[3] ~= vec[3] or (vec[4] ~= nil and vec[4] ~= vec[4])
end

local scratchBuf = buffer.create(1024)
local jumpTargetsBuf = buffer.create(1024)
local scratchCap = 1024
local pendingTargets: { number } = {}
local fuseCandidates: { number } = {}

@native
local function ensureScratchCap(clen: number): (buffer, buffer)
	local need = clen + 1
	if need > scratchCap then
		local cap = scratchCap
		while cap < need do
			cap *= 2
		end
		scratchCap = cap
		scratchBuf = buffer.create(cap)
		jumpTargetsBuf = buffer.create(cap)
	end
	local buf = scratchBuf
	local jbuf = jumpTargetsBuf
	buffer.fill(buf, 0, 0, need)
	buffer.fill(jbuf, 0, 0, need)
	return buf, jbuf
end

local function verifyProtoConstantsAndChildren(proto: Proto, protos: { Proto }): string?
	local kTypes: { number } = proto.kTypes
	local kValues: { any } = proto.kValues
	local pList = proto.p
	local sizek = #kTypes
	local sizep = #pList
	local nprotos = #protos

	for i = 1, sizep do
		local fid = pList[i]
		if type(fid) ~= "number" or fid < 0 or fid >= nprotos or math.floor(fid) ~= fid then
			return "child proto id out of bounds"
		end
	end

	for ki = 1, sizek do
		local kt = kTypes[ki]
		local kv = kValues[ki]
		if kt == LBC_CONSTANT_NIL then
			if kv ~= nil then
				return "invalid nil constant"
			end
		elseif kt == LBC_CONSTANT_BOOLEAN then
			if type(kv) ~= "boolean" then
				return "invalid boolean constant"
			end
		elseif kt == LBC_CONSTANT_NUMBER then
			if type(kv) ~= "number" then
				return "invalid number constant"
			end
		elseif kt == LBC_CONSTANT_STRING then
			if type(kv) ~= "string" then
				return "invalid string constant"
			end
		elseif kt == LBC_CONSTANT_CLOSURE then
			if type(kv) ~= "number" or kv < 0 or kv >= nprotos or math.floor(kv) ~= kv then
				return "closure constant proto id out of bounds"
			end
		elseif kt == LBC_CONSTANT_VECTOR or kt == LBC_CONSTANT_VECTORD then
			if
				type(kv) ~= "table"
				or getmetatable(kv) ~= nil
				or type(kv[1]) ~= "number"
				or type(kv[2]) ~= "number"
				or type(kv[3]) ~= "number"
				or (kv[4] ~= nil and type(kv[4]) ~= "number")
			then
				return "invalid vector constant"
			end
		elseif kt == LBC_CONSTANT_IMPORT then
			if type(kv) ~= "number" then
				return "invalid import constant"
			end
			local cnt, id0, id1, id2 = BytecodeCodec.decomposeImportId(kv)
			if
				cnt < 1
				or cnt > 3
				or id0 < 0
				or id0 >= sizek
				or (cnt >= 2 and (id1 < 0 or id1 >= sizek))
				or (cnt >= 3 and (id2 < 0 or id2 >= sizek))
			then
				return "import constant index out of bounds"
			end
			if
				(kTypes[id0 + 1] ~= LBC_CONSTANT_STRING or type(kValues[id0 + 1]) ~= "string")
				or (cnt >= 2 and (kTypes[id1 + 1] ~= LBC_CONSTANT_STRING or type(kValues[id1 + 1]) ~= "string"))
				or (cnt >= 3 and (kTypes[id2 + 1] ~= LBC_CONSTANT_STRING or type(kValues[id2 + 1]) ~= "string"))
			then
				return "import constant piece must be string"
			end
		elseif kt == LBC_CONSTANT_TABLE then
			if type(kv) ~= "table" or getmetatable(kv) ~= nil then
				return "invalid table constant"
			end
			local keys = kv.keys
			local len = kv.length
			if
				type(keys) ~= "table"
				or getmetatable(keys) ~= nil
				or type(len) ~= "number"
				or math.floor(len) ~= len
				or len < 0
				or len > #keys
			then
				return "invalid table constant"
			end
			for m = 1, len do
				local kid = keys[m]
				if type(kid) ~= "number" or kid < 0 or kid >= sizek or math.floor(kid) ~= kid then
					return "table constant key index out of bounds"
				end
				local kdt = kTypes[kid + 1]
				local kdv = kValues[kid + 1]
				if kdt == nil or kdt == LBC_CONSTANT_NIL then
					return "table constant key cannot be nil"
				elseif not isScalarTag(kdt) then
					return "table constant key must be scalar"
				end
				if kdt == LBC_CONSTANT_NUMBER and (type(kdv) ~= "number" or kdv ~= kdv) then
					return "table constant key cannot be NaN"
				end
				if
					(kdt == LBC_CONSTANT_VECTOR or kdt == LBC_CONSTANT_VECTORD)
					and (type(kdv) ~= "table" or hasNaNVectorComponent(kdv))
				then
					return "table constant key cannot be NaN"
				end
			end
		elseif kt == LBC_CONSTANT_TABLE_WITH_CONSTANTS then
			if type(kv) ~= "table" or getmetatable(kv) ~= nil then
				return "invalid table constant"
			end
			local keys = kv.keys
			local consts = kv.constants
			local len = kv.length
			if
				type(keys) ~= "table"
				or getmetatable(keys) ~= nil
				or type(consts) ~= "table"
				or getmetatable(consts) ~= nil
				or type(len) ~= "number"
				or math.floor(len) ~= len
				or len < 0
				or len > #keys
				or len > #consts
			then
				return "invalid table constant"
			end
			for m = 1, len do
				local kid = keys[m]
				local cid = consts[m]
				if
					type(kid) ~= "number"
					or kid < 0
					or kid >= sizek
					or math.floor(kid) ~= kid
					or type(cid) ~= "number"
					or cid >= sizek
					or cid < -1
					or math.floor(cid) ~= cid
				then
					return "table constant index out of bounds"
				end
				local kdt = kTypes[kid + 1]
				local kdv = kValues[kid + 1]
				if kdt == nil or kdt == LBC_CONSTANT_NIL then
					return "table constant key cannot be nil"
				elseif not isScalarTag(kdt) then
					return "table constant key must be scalar"
				end
				if kdt == LBC_CONSTANT_NUMBER and (type(kdv) ~= "number" or kdv ~= kdv) then
					return "table constant key cannot be NaN"
				end
				if
					(kdt == LBC_CONSTANT_VECTOR or kdt == LBC_CONSTANT_VECTORD)
					and (type(kdv) ~= "table" or hasNaNVectorComponent(kdv))
				then
					return "table constant key cannot be NaN"
				end
				if cid >= 0 then
					if not isScalarTag(kTypes[cid + 1]) then
						return "invalid table constant value type"
					end
				end
			end
		elseif kt == LBC_CONSTANT_CLASS_SHAPE then
			-- Class descriptor constant allowed here; execution rejects v100 or class opcodes
		else
			return "invalid constant entry"
		end
	end
	return nil
end

@native
local function verifyProtoBody(proto: Proto, protos: { Proto }, fromBinary: boolean?): string?
	local maxstack = proto.maxstacksize
	local nups = proto.nups
	local kTypes: { number } = proto.kTypes
	local kValues: { any } = proto.kValues
	local pList = proto.p
	local pcode = proto.code

	local sizek = #kTypes
	local sizep = #pList
	local clen = #pcode
	if clen <= 0 then
		return "empty proto code"
	end

	if not fromBinary then
		local constErr = verifyProtoConstantsAndChildren(proto, protos)
		if constErr then
			return constErr
		end
	end

	local insnStartsBuf = ensureScratchCap(clen)
	local pend = pendingTargets
	local npend = 0
	local ci = 1
	local lastInsnCi = 1
	while ci <= clen do
		local insn = pcode[ci]
		if not fromBinary and (type(insn) ~= "number" or insn ~= math.floor(insn)) then
			return "invalid instruction"
		end
		local op = band(insn, 0xff)
		if op >= LOP__COUNT then
			return "unsupported opcode: " .. tostring(op)
		end
		if CLASS_OPCODE_ARR[op + 1] then
			return "unsupported experimental class bytecode (v100)"
		end
		if op == LOP_NATIVECALL then
			return "unsupported opcode: " .. tostring(op)
		end
		if op == LOP_CAPTURE then
			return "unexpected standalone LOP_CAPTURE"
		end
		local isTwoWord = TWO_WORD_OP_ARR[op + 1]
		local aux = 0
		if isTwoWord then
			if ci + 1 > clen then
				return "truncated two-word instruction"
			end
			aux = pcode[ci + 1]
			if not fromBinary and (type(aux) ~= "number" or aux ~= math.floor(aux) or aux < 0 or aux > 0xffffffff) then
				return "invalid instruction aux word"
			end
		end

		buffer.writeu8(insnStartsBuf, ci, 1)
		lastInsnCi = ci

		local a = band(rshift(insn, 8), 0xff)
		local b = band(rshift(insn, 16), 0xff)
		local c = band(rshift(insn, 24), 0xff)
		local u = rshift(insn, 16)
		local d = if u >= 0x8000 then u - 0x10000 else u

		if JUMP_D_OP_ARR[op + 1] then
			local target = ci + 1 + d
			if target < 1 or target > clen then
				return "jump target out of bounds"
			end
			if target <= ci then
				if buffer.readu8(insnStartsBuf, target) == 0 then
					return "misaligned jump target"
				end
			else
				npend += 1
				pend[npend] = target
			end
		end

		local nextCi = ci + (if isTwoWord then 2 else 1)

		if
			op == LOP_LOADNIL
			or op == LOP_LOADN
			or op == LOP_NEWTABLE
			or op == LOP_JUMPIF
			or op == LOP_JUMPIFNOT
			or op == LOP_JUMPXEQKNIL
			or op == LOP_JUMPXEQKB
			or op == LOP_CMPPROTO
		then
			if a >= maxstack then
				return "register out of bounds"
			end
		elseif op == LOP_CLOSEUPVALS then
			if a > maxstack then
				return "register out of bounds"
			end
		elseif op == LOP_LOADB then
			if a >= maxstack then
				return "register out of bounds"
			end
			if c ~= 0 then
				local target = ci + 1 + c
				if target < 1 or target > clen then
					return "jump target out of bounds"
				end
				npend += 1
				pend[npend] = target
			end
		elseif op == LOP_LOADK then
			if a >= maxstack then
				return "register out of bounds"
			end
			if d < 0 or d >= sizek then
				return "constant index out of bounds"
			end
			if not isScalarTag(kTypes[d + 1]) then
				return "invalid constant type for LOADK"
			end
		elseif op == LOP_GETIMPORT then
			if a >= maxstack then
				return "register out of bounds"
			end
			if d < 0 or d >= sizek then
				return "constant index out of bounds"
			end
			if kTypes[d + 1] ~= LBC_CONSTANT_IMPORT then
				return "invalid constant type for GETIMPORT"
			end
			local cnt, id0, id1, id2 = BytecodeCodec.decomposeImportId(aux)
			if
				cnt < 1
				or cnt > 3
				or id0 < 0
				or id0 >= sizek
				or (cnt >= 2 and (id1 < 0 or id1 >= sizek))
				or (cnt >= 3 and (id2 < 0 or id2 >= sizek))
			then
				return "import aux constant index out of bounds"
			end
			if
				kTypes[id0 + 1] ~= LBC_CONSTANT_STRING
				or (cnt >= 2 and kTypes[id1 + 1] ~= LBC_CONSTANT_STRING)
				or (cnt >= 3 and kTypes[id2 + 1] ~= LBC_CONSTANT_STRING)
			then
				return "import aux piece must be string"
			end
		elseif op == LOP_DUPTABLE then
			if a >= maxstack then
				return "register out of bounds"
			end
			if d < 0 or d >= sizek then
				return "constant index out of bounds"
			end
			local ctype = kTypes[d + 1]
			if ctype ~= LBC_CONSTANT_TABLE and ctype ~= LBC_CONSTANT_TABLE_WITH_CONSTANTS then
				return "invalid duptable constant"
			end
		elseif
			op == LOP_MOVE
			or op == LOP_NOT
			or op == LOP_MINUS
			or op == LOP_LENGTH
			or op == LOP_GETTABLEN
			or op == LOP_SETTABLEN
		then
			if a >= maxstack or b >= maxstack then
				return "register out of bounds"
			end
		elseif op == LOP_GETGLOBAL or op == LOP_SETGLOBAL then
			if a >= maxstack then
				return "register out of bounds"
			end
			if aux < 0 or aux >= sizek then
				return "constant index out of bounds"
			end
			if kTypes[aux + 1] ~= LBC_CONSTANT_STRING then
				return "global name constant must be string"
			end
		elseif op == LOP_LOADKX then
			if a >= maxstack then
				return "register out of bounds"
			end
			if aux < 0 or aux >= sizek then
				return "constant index out of bounds"
			end
			if not isScalarTag(kTypes[aux + 1]) then
				return "invalid constant type for LOADKX"
			end
		elseif op == LOP_GETUPVAL or op == LOP_SETUPVAL then
			if a >= maxstack then
				return "register out of bounds"
			end
			if b >= nups then
				return "upvalue index out of bounds"
			end
		elseif
			op == LOP_GETTABLE
			or op == LOP_SETTABLE
			or op == LOP_ADD
			or op == LOP_SUB
			or op == LOP_MUL
			or op == LOP_DIV
			or op == LOP_MOD
			or op == LOP_POW
			or op == LOP_AND
			or op == LOP_OR
			or op == LOP_IDIV
		then
			if a >= maxstack or b >= maxstack or c >= maxstack then
				return "register out of bounds"
			end
		elseif op == LOP_CONCAT then
			if a >= maxstack or b >= maxstack or c >= maxstack or b > c then
				return "register out of bounds"
			end
		elseif op == LOP_GETTABLEKS or op == LOP_SETTABLEKS then
			if a >= maxstack or b >= maxstack then
				return "register out of bounds"
			end
			local kidx = band(aux, 0xffffff)
			if kidx >= sizek then
				return "constant index out of bounds"
			end
			if kTypes[kidx + 1] ~= LBC_CONSTANT_STRING then
				return "table key constant must be string"
			end
		elseif op == LOP_GETUDATAKS or op == LOP_SETUDATAKS then
			if a >= maxstack or b >= maxstack then
				return "register out of bounds"
			end
			local kidx = band(aux, 0xffff)
			if kidx >= sizek then
				return "constant index out of bounds"
			end
			if kTypes[kidx + 1] ~= LBC_CONSTANT_STRING then
				return "userdata key constant must be string"
			end
		elseif op == LOP_NAMECALL then
			if a + 1 >= maxstack or b >= maxstack then
				return "register out of bounds"
			end
			local kidx = band(aux, 0xffffff)
			if kidx >= sizek then
				return "constant index out of bounds"
			end
			if kTypes[kidx + 1] ~= LBC_CONSTANT_STRING then
				return "namecall method constant must be string"
			end
		elseif op == LOP_NAMECALLUDATA then
			if a + 1 >= maxstack or b >= maxstack then
				return "register out of bounds"
			end
			local kidx = band(aux, 0xffff)
			if kidx >= sizek then
				return "constant index out of bounds"
			end
			if kTypes[kidx + 1] ~= LBC_CONSTANT_STRING then
				return "userdata method constant must be string"
			end
		elseif op == LOP_NEWCLOSURE then
			if a >= maxstack then
				return "register out of bounds"
			end
			if d < 0 or d >= sizep then
				return "child proto index out of bounds"
			end
			local childProto = protos[pList[d + 1] + 1]
			if not childProto or ci + childProto.nups > clen then
				return "invalid child closure"
			end
			local childNups = childProto.nups
			for ui = 1, childNups do
				local capInsn = pcode[ci + ui]
				if
					(not fromBinary and (type(capInsn) ~= "number" or capInsn ~= math.floor(capInsn)))
					or band(capInsn, 0xff) ~= LOP_CAPTURE
				then
					return "expected LOP_CAPTURE after closure instruction"
				end
				local capA = band(rshift(capInsn, 8), 0xff)
				local capB = band(rshift(capInsn, 16), 0xff)
				if capA == Captures.LCT_VAL or capA == Captures.LCT_REF then
					if capB >= maxstack then
						return "capture register out of bounds"
					end
				elseif capA == Captures.LCT_UPVAL then
					if capB >= nups then
						return "capture upvalue out of bounds"
					end
				else
					return "invalid capture type"
				end
			end
			nextCi = ci + 1 + childNups
		elseif op == LOP_DUPCLOSURE then
			if a >= maxstack then
				return "register out of bounds"
			end
			if d < 0 or d >= sizek then
				return "constant index out of bounds"
			end
			if kTypes[d + 1] ~= LBC_CONSTANT_CLOSURE then
				return "invalid closure constant"
			end
			local childProto = protos[kValues[d + 1] + 1]
			if not childProto or ci + childProto.nups > clen then
				return "invalid child closure"
			end
			local childNups = childProto.nups
			for ui = 1, childNups do
				local capInsn = pcode[ci + ui]
				if
					(not fromBinary and (type(capInsn) ~= "number" or capInsn ~= math.floor(capInsn)))
					or band(capInsn, 0xff) ~= LOP_CAPTURE
				then
					return "expected LOP_CAPTURE after closure instruction"
				end
				local capA = band(rshift(capInsn, 8), 0xff)
				if capA == Captures.LCT_REF then
					return "DUPCLOSURE cannot capture by reference"
				end
				local capB = band(rshift(capInsn, 16), 0xff)
				if capA == Captures.LCT_VAL then
					if capB >= maxstack then
						return "capture register out of bounds"
					end
				elseif capA == Captures.LCT_UPVAL then
					if capB >= nups then
						return "capture upvalue out of bounds"
					end
				else
					return "invalid capture type"
				end
			end
			nextCi = ci + 1 + childNups
		elseif op == LOP_CALL or op == LOP_CALLFB then
			if a >= maxstack then
				return "register out of bounds"
			end
			if (b > 1 and a + b - 1 >= maxstack) or (c > 1 and a + c - 2 >= maxstack) then
				return "call register out of bounds"
			end
		elseif op == LOP_RETURN or op == LOP_GETVARARGS then
			if b == 0 then
				if a > maxstack then
					return "register out of bounds"
				end
			elseif b > 1 and a + b - 2 >= maxstack then
				return "register out of bounds"
			end
		elseif op == LOP_JUMPXEQKN then
			if a >= maxstack then
				return "register out of bounds"
			end
			local kidx = band(aux, 0xffffff)
			if kidx >= sizek then
				return "constant index out of bounds"
			end
			if kTypes[kidx + 1] ~= LBC_CONSTANT_NUMBER then
				return "JUMPXEQKN constant must be number"
			end
		elseif op == LOP_JUMPXEQKS then
			if a >= maxstack then
				return "register out of bounds"
			end
			local kidx = band(aux, 0xffffff)
			if kidx >= sizek then
				return "constant index out of bounds"
			end
			if kTypes[kidx + 1] ~= LBC_CONSTANT_STRING then
				return "JUMPXEQKS constant must be string"
			end
		elseif
			op == LOP_JUMPIFEQ
			or op == LOP_JUMPIFLE
			or op == LOP_JUMPIFLT
			or op == LOP_JUMPIFNOTEQ
			or op == LOP_JUMPIFNOTLE
			or op == LOP_JUMPIFNOTLT
		then
			if a >= maxstack or aux < 0 or aux >= maxstack then
				return "register out of bounds"
			end
		elseif
			op == LOP_ADDK
			or op == LOP_SUBK
			or op == LOP_MULK
			or op == LOP_DIVK
			or op == LOP_MODK
			or op == LOP_POWK
			or op == LOP_IDIVK
		then
			if a >= maxstack or b >= maxstack then
				return "register out of bounds"
			end
			if c >= sizek then
				return "constant index out of bounds"
			end
			if kTypes[c + 1] ~= LBC_CONSTANT_NUMBER then
				return "arithmetic K constant must be number"
			end
		elseif op == LOP_ANDK or op == LOP_ORK then
			if a >= maxstack or b >= maxstack then
				return "register out of bounds"
			end
			if c >= sizek then
				return "constant index out of bounds"
			end
			if not isScalarTag(kTypes[c + 1]) then
				return "invalid constant type for logical op"
			end
		elseif op == LOP_SUBRK or op == LOP_DIVRK then
			if a >= maxstack or c >= maxstack then
				return "register out of bounds"
			end
			if b >= sizek then
				return "constant index out of bounds"
			end
			if kTypes[b + 1] ~= LBC_CONSTANT_NUMBER then
				return "arithmetic RK constant must be number"
			end
		elseif op == LOP_SETLIST then
			if a >= maxstack then
				return "register out of bounds"
			end
			if c == 0 then
				if b > maxstack then
					return "register out of bounds"
				end
			elseif c > 1 and b + c - 2 >= maxstack then
				return "register out of bounds"
			end
		elseif
			op == LOP_FORNPREP
			or op == LOP_FORNLOOP
			or op == LOP_FORGPREP_INEXT
			or op == LOP_FORGPREP_NEXT
			or op == LOP_FORGPREP
		then
			if a + 2 >= maxstack then
				return "for-loop register out of bounds"
			end
		elseif op == LOP_FORGLOOP then
			local nvars = band(aux, 0xff)
			if nvars < 1 or a + 2 + nvars >= maxstack then
				return "for-loop register out of bounds"
			end
		elseif op == LOP_JUMPX then
			local eu = rshift(insn, 8)
			local e = if eu >= 0x800000 then eu - 0x1000000 else eu
			local target = ci + 1 + e
			if target < 1 or target > clen then
				return "jump target out of bounds"
			end
			if target <= ci then
				if buffer.readu8(insnStartsBuf, target) == 0 then
					return "misaligned jump target"
				end
			else
				npend += 1
				pend[npend] = target
			end
		elseif
			op == LOP_FASTCALL
			or op == LOP_FASTCALL1
			or op == LOP_FASTCALL2
			or op == LOP_FASTCALL2K
			or op == LOP_FASTCALL3
		then
			local callPc = ci + 1 + c
			if callPc < 1 or callPc > clen then
				return "fastcall target out of bounds"
			end
			npend += 1
			pend[npend] = -callPc
			if op ~= LOP_FASTCALL and b >= maxstack then
				return "fastcall register out of bounds"
			end
			if op == LOP_FASTCALL2 then
				if aux < 0 or aux >= maxstack then
					return "fastcall register out of bounds"
				end
			elseif op == LOP_FASTCALL2K then
				if aux < 0 or aux >= sizek then
					return "fastcall constant index out of bounds"
				end
				if not isScalarTag(kTypes[aux + 1]) then
					return "invalid fastcall constant type"
				end
			elseif op == LOP_FASTCALL3 then
				if band(aux, 0xff) >= maxstack or band(rshift(aux, 8), 0xff) >= maxstack then
					return "fastcall register out of bounds"
				end
			end
		elseif op == LOP_FASTPCALL then
			local target = ci + 1 + c
			if target < 1 or target > clen then
				return "jump target out of bounds"
			end
			npend += 1
			pend[npend] = target + 0x40000000
		end

		ci = nextCi
	end

	local lastOp = band(pcode[lastInsnCi], 0xff)
	if lastOp ~= LOP_RETURN and lastOp ~= LOP_JUMP and lastOp ~= LOP_JUMPBACK and lastOp ~= LOP_JUMPX then
		return "proto does not terminate cleanly"
	end

	for k = 1, npend do
		local t = pend[k]
		if t < 0 then
			local callPc = -t
			if buffer.readu8(insnStartsBuf, callPc) == 0 then
				return "fastcall target is not an instruction boundary"
			end
			local callOp = band(pcode[callPc], 0xff)
			if callOp ~= LOP_CALL and callOp ~= LOP_CALLFB then
				return "fastcall target is not CALL"
			end
		elseif t >= 0x40000000 then
			local target = t - 0x40000000
			if buffer.readu8(insnStartsBuf, target) == 0 then
				return "misaligned jump target"
			end
			local callOp = band(pcode[target], 0xff)
			if callOp ~= LOP_CALL and callOp ~= LOP_CALLFB then
				return "fastpcall target is not CALL"
			end
		else
			if buffer.readu8(insnStartsBuf, t) == 0 then
				return "misaligned jump target"
			end
		end
	end

	return nil
end

local function verifyProto(proto: Proto, protos: { Proto }): string?
	if not isValidProtoHeader(proto) then
		return "malformed proto header"
	end
	return verifyProtoBody(proto, protos)
end

@native
local function verifyModule(protoModule: ProtoModule, skipProtoCheck: boolean, fromBinary: boolean?): string?
	if protoModule.version == Tags.LBC_VERSION_CLASSES then
		return "unsupported experimental class bytecode (v100)"
	end
	if not fromBinary then
		if type(protoModule) ~= "table" or getmetatable(protoModule :: any) ~= nil then
			return "invalid proto module"
		end
	end
	local protos = protoModule.protos
	local mainid = protoModule.mainid
	if not fromBinary then
		if type(protos) ~= "table" or getmetatable(protos :: any) ~= nil or #protos == 0 then
			return "invalid protos table"
		end
		if type(mainid) ~= "number" or mainid ~= math.floor(mainid) then
			return "invalid main proto id"
		end
	end
	local mainProto = protos[mainid + 1]
	if not mainProto then
		return "invalid main proto id"
	end
	if skipProtoCheck then
		return nil
	end
	local nprotos = #protos
	if not fromBinary then
		for i = 1, nprotos do
			local p = protos[i]
			if
				type(p) ~= "table"
				or type(p.id) ~= "number"
				or p.id < 0
				or p.id >= nprotos
				or math.floor(p.id) ~= p.id
				or protos[p.id + 1] ~= p
				or not isValidProtoHeader(p)
			then
				return "malformed proto header"
			end
		end
	end
	if mainProto.nups ~= 0 then
		return "main proto cannot have upvalues"
	end
	for i = 1, nprotos do
		local verifyErr = verifyProtoBody(protos[i], protos, fromBinary)
		if verifyErr then
			return verifyErr
		end
	end
	return nil
end

local DUPTABLE_SEEDS: { [number]: { [unknown]: unknown } } = {}
do
	local function makeSeed(t: { [unknown]: unknown }): { [unknown]: unknown }
		table.clear(t)
		return table.freeze(t)
	end
	DUPTABLE_SEEDS[0] = table.freeze({} :: { [unknown]: unknown })
	DUPTABLE_SEEDS[1] = makeSeed({ _1 = true })
	DUPTABLE_SEEDS[2] = makeSeed({ _1 = true, _2 = true })
	DUPTABLE_SEEDS[4] = makeSeed({ _1 = true, _2 = true, _3 = true, _4 = true })
	DUPTABLE_SEEDS[8] = makeSeed({
		_1 = true,
		_2 = true,
		_3 = true,
		_4 = true,
		_5 = true,
		_6 = true,
		_7 = true,
		_8 = true,
	})
	DUPTABLE_SEEDS[16] = makeSeed({
		_1 = true,
		_2 = true,
		_3 = true,
		_4 = true,
		_5 = true,
		_6 = true,
		_7 = true,
		_8 = true,
		_9 = true,
		_10 = true,
		_11 = true,
		_12 = true,
		_13 = true,
		_14 = true,
		_15 = true,
		_16 = true,
	})
	DUPTABLE_SEEDS[32] = makeSeed({
		_1 = true,
		_2 = true,
		_3 = true,
		_4 = true,
		_5 = true,
		_6 = true,
		_7 = true,
		_8 = true,
		_9 = true,
		_10 = true,
		_11 = true,
		_12 = true,
		_13 = true,
		_14 = true,
		_15 = true,
		_16 = true,
		_17 = true,
		_18 = true,
		_19 = true,
		_20 = true,
		_21 = true,
		_22 = true,
		_23 = true,
		_24 = true,
		_25 = true,
		_26 = true,
		_27 = true,
		_28 = true,
		_29 = true,
		_30 = true,
		_31 = true,
		_32 = true,
	})
	DUPTABLE_SEEDS[64] = makeSeed({
		_1 = true,
		_2 = true,
		_3 = true,
		_4 = true,
		_5 = true,
		_6 = true,
		_7 = true,
		_8 = true,
		_9 = true,
		_10 = true,
		_11 = true,
		_12 = true,
		_13 = true,
		_14 = true,
		_15 = true,
		_16 = true,
		_17 = true,
		_18 = true,
		_19 = true,
		_20 = true,
		_21 = true,
		_22 = true,
		_23 = true,
		_24 = true,
		_25 = true,
		_26 = true,
		_27 = true,
		_28 = true,
		_29 = true,
		_30 = true,
		_31 = true,
		_32 = true,
		_33 = true,
		_34 = true,
		_35 = true,
		_36 = true,
		_37 = true,
		_38 = true,
		_39 = true,
		_40 = true,
		_41 = true,
		_42 = true,
		_43 = true,
		_44 = true,
		_45 = true,
		_46 = true,
		_47 = true,
		_48 = true,
		_49 = true,
		_50 = true,
		_51 = true,
		_52 = true,
		_53 = true,
		_54 = true,
		_55 = true,
		_56 = true,
		_57 = true,
		_58 = true,
		_59 = true,
		_60 = true,
		_61 = true,
		_62 = true,
		_63 = true,
		_64 = true,
	})
	DUPTABLE_SEEDS[128] = makeSeed({
		_1 = true,
		_2 = true,
		_3 = true,
		_4 = true,
		_5 = true,
		_6 = true,
		_7 = true,
		_8 = true,
		_9 = true,
		_10 = true,
		_11 = true,
		_12 = true,
		_13 = true,
		_14 = true,
		_15 = true,
		_16 = true,
		_17 = true,
		_18 = true,
		_19 = true,
		_20 = true,
		_21 = true,
		_22 = true,
		_23 = true,
		_24 = true,
		_25 = true,
		_26 = true,
		_27 = true,
		_28 = true,
		_29 = true,
		_30 = true,
		_31 = true,
		_32 = true,
		_33 = true,
		_34 = true,
		_35 = true,
		_36 = true,
		_37 = true,
		_38 = true,
		_39 = true,
		_40 = true,
		_41 = true,
		_42 = true,
		_43 = true,
		_44 = true,
		_45 = true,
		_46 = true,
		_47 = true,
		_48 = true,
		_49 = true,
		_50 = true,
		_51 = true,
		_52 = true,
		_53 = true,
		_54 = true,
		_55 = true,
		_56 = true,
		_57 = true,
		_58 = true,
		_59 = true,
		_60 = true,
		_61 = true,
		_62 = true,
		_63 = true,
		_64 = true,
		_65 = true,
		_66 = true,
		_67 = true,
		_68 = true,
		_69 = true,
		_70 = true,
		_71 = true,
		_72 = true,
		_73 = true,
		_74 = true,
		_75 = true,
		_76 = true,
		_77 = true,
		_78 = true,
		_79 = true,
		_80 = true,
		_81 = true,
		_82 = true,
		_83 = true,
		_84 = true,
		_85 = true,
		_86 = true,
		_87 = true,
		_88 = true,
		_89 = true,
		_90 = true,
		_91 = true,
		_92 = true,
		_93 = true,
		_94 = true,
		_95 = true,
		_96 = true,
		_97 = true,
		_98 = true,
		_99 = true,
		_100 = true,
		_101 = true,
		_102 = true,
		_103 = true,
		_104 = true,
		_105 = true,
		_106 = true,
		_107 = true,
		_108 = true,
		_109 = true,
		_110 = true,
		_111 = true,
		_112 = true,
		_113 = true,
		_114 = true,
		_115 = true,
		_116 = true,
		_117 = true,
		_118 = true,
		_119 = true,
		_120 = true,
		_121 = true,
		_122 = true,
		_123 = true,
		_124 = true,
		_125 = true,
		_126 = true,
		_127 = true,
		_128 = true,
	})
	DUPTABLE_SEEDS[256] = makeSeed({
		_1 = true,
		_2 = true,
		_3 = true,
		_4 = true,
		_5 = true,
		_6 = true,
		_7 = true,
		_8 = true,
		_9 = true,
		_10 = true,
		_11 = true,
		_12 = true,
		_13 = true,
		_14 = true,
		_15 = true,
		_16 = true,
		_17 = true,
		_18 = true,
		_19 = true,
		_20 = true,
		_21 = true,
		_22 = true,
		_23 = true,
		_24 = true,
		_25 = true,
		_26 = true,
		_27 = true,
		_28 = true,
		_29 = true,
		_30 = true,
		_31 = true,
		_32 = true,
		_33 = true,
		_34 = true,
		_35 = true,
		_36 = true,
		_37 = true,
		_38 = true,
		_39 = true,
		_40 = true,
		_41 = true,
		_42 = true,
		_43 = true,
		_44 = true,
		_45 = true,
		_46 = true,
		_47 = true,
		_48 = true,
		_49 = true,
		_50 = true,
		_51 = true,
		_52 = true,
		_53 = true,
		_54 = true,
		_55 = true,
		_56 = true,
		_57 = true,
		_58 = true,
		_59 = true,
		_60 = true,
		_61 = true,
		_62 = true,
		_63 = true,
		_64 = true,
		_65 = true,
		_66 = true,
		_67 = true,
		_68 = true,
		_69 = true,
		_70 = true,
		_71 = true,
		_72 = true,
		_73 = true,
		_74 = true,
		_75 = true,
		_76 = true,
		_77 = true,
		_78 = true,
		_79 = true,
		_80 = true,
		_81 = true,
		_82 = true,
		_83 = true,
		_84 = true,
		_85 = true,
		_86 = true,
		_87 = true,
		_88 = true,
		_89 = true,
		_90 = true,
		_91 = true,
		_92 = true,
		_93 = true,
		_94 = true,
		_95 = true,
		_96 = true,
		_97 = true,
		_98 = true,
		_99 = true,
		_100 = true,
		_101 = true,
		_102 = true,
		_103 = true,
		_104 = true,
		_105 = true,
		_106 = true,
		_107 = true,
		_108 = true,
		_109 = true,
		_110 = true,
		_111 = true,
		_112 = true,
		_113 = true,
		_114 = true,
		_115 = true,
		_116 = true,
		_117 = true,
		_118 = true,
		_119 = true,
		_120 = true,
		_121 = true,
		_122 = true,
		_123 = true,
		_124 = true,
		_125 = true,
		_126 = true,
		_127 = true,
		_128 = true,
		_129 = true,
		_130 = true,
		_131 = true,
		_132 = true,
		_133 = true,
		_134 = true,
		_135 = true,
		_136 = true,
		_137 = true,
		_138 = true,
		_139 = true,
		_140 = true,
		_141 = true,
		_142 = true,
		_143 = true,
		_144 = true,
		_145 = true,
		_146 = true,
		_147 = true,
		_148 = true,
		_149 = true,
		_150 = true,
		_151 = true,
		_152 = true,
		_153 = true,
		_154 = true,
		_155 = true,
		_156 = true,
		_157 = true,
		_158 = true,
		_159 = true,
		_160 = true,
		_161 = true,
		_162 = true,
		_163 = true,
		_164 = true,
		_165 = true,
		_166 = true,
		_167 = true,
		_168 = true,
		_169 = true,
		_170 = true,
		_171 = true,
		_172 = true,
		_173 = true,
		_174 = true,
		_175 = true,
		_176 = true,
		_177 = true,
		_178 = true,
		_179 = true,
		_180 = true,
		_181 = true,
		_182 = true,
		_183 = true,
		_184 = true,
		_185 = true,
		_186 = true,
		_187 = true,
		_188 = true,
		_189 = true,
		_190 = true,
		_191 = true,
		_192 = true,
		_193 = true,
		_194 = true,
		_195 = true,
		_196 = true,
		_197 = true,
		_198 = true,
		_199 = true,
		_200 = true,
		_201 = true,
		_202 = true,
		_203 = true,
		_204 = true,
		_205 = true,
		_206 = true,
		_207 = true,
		_208 = true,
		_209 = true,
		_210 = true,
		_211 = true,
		_212 = true,
		_213 = true,
		_214 = true,
		_215 = true,
		_216 = true,
		_217 = true,
		_218 = true,
		_219 = true,
		_220 = true,
		_221 = true,
		_222 = true,
		_223 = true,
		_224 = true,
		_225 = true,
		_226 = true,
		_227 = true,
		_228 = true,
		_229 = true,
		_230 = true,
		_231 = true,
		_232 = true,
		_233 = true,
		_234 = true,
		_235 = true,
		_236 = true,
		_237 = true,
		_238 = true,
		_239 = true,
		_240 = true,
		_241 = true,
		_242 = true,
		_243 = true,
		_244 = true,
		_245 = true,
		_246 = true,
		_247 = true,
		_248 = true,
		_249 = true,
		_250 = true,
		_251 = true,
		_252 = true,
		_253 = true,
		_254 = true,
		_255 = true,
		_256 = true,
	})
end

local function cloneDuptableSeed(len: number): { [unknown]: unknown }
	if len <= 0 then
		return {}
	elseif len <= 1 then
		return table.clone(DUPTABLE_SEEDS[1])
	elseif len <= 2 then
		return table.clone(DUPTABLE_SEEDS[2])
	elseif len <= 4 then
		return table.clone(DUPTABLE_SEEDS[4])
	elseif len <= 8 then
		return table.clone(DUPTABLE_SEEDS[8])
	elseif len <= 16 then
		return table.clone(DUPTABLE_SEEDS[16])
	elseif len <= 32 then
		return table.clone(DUPTABLE_SEEDS[32])
	elseif len <= 64 then
		return table.clone(DUPTABLE_SEEDS[64])
	elseif len <= 128 then
		return table.clone(DUPTABLE_SEEDS[128])
	elseif len <= 256 then
		return table.clone(DUPTABLE_SEEDS[256])
	end
	return table.clone(DUPTABLE_SEEDS[256])
end

@native
local function predecodeBaseConstants(proto: Proto): ({ [number]: any }, { number }?)
	local kTypes: { number } = proto.kTypes
	local kValues: { any } = proto.kValues
	local sizek = #kTypes
	local kv: { [number]: any } = table.create(sizek)
	local hasComposite = false
	local importIndices: { number }? = nil

	for ki = 1, sizek do
		local kt = kTypes[ki]
		if kt == LBC_CONSTANT_NIL then
			kv[ki] = nil
		elseif kt == LBC_CONSTANT_BOOLEAN or kt == LBC_CONSTANT_NUMBER or kt == LBC_CONSTANT_STRING then
			kv[ki] = kValues[ki]
		elseif kt == LBC_CONSTANT_VECTOR or kt == LBC_CONSTANT_VECTORD then
			local v = kValues[ki]
			if vector and vector.create then
				local vecCreate: (number, number, number, number) -> vector = (vector.create :: unknown) :: (
					number,
					number,
					number,
					number
				) -> vector
				if v[4] ~= nil then
					kv[ki] = vecCreate(v[1], v[2], v[3], v[4])
				else
					kv[ki] = (vecCreate :: any)(v[1], v[2], v[3])
				end
			else
				kv[ki] = v
			end
		elseif kt == LBC_CONSTANT_IMPORT then
			if importIndices then
				importIndices[#importIndices + 1] = ki
			else
				importIndices = { ki }
			end
		elseif kt == LBC_CONSTANT_TABLE or kt == LBC_CONSTANT_TABLE_WITH_CONSTANTS then
			hasComposite = true
		end
	end

	if hasComposite then
		for ki = 1, sizek do
			local kt = kTypes[ki]
			if kt == LBC_CONSTANT_TABLE then
				local c = kValues[ki]
				local tmpl = cloneDuptableSeed(c.length)
				local keys = c.keys
				for m = 1, c.length do
					local k = kv[keys[m] + 1]
					if k ~= nil then
						tmpl[k] = true
					end
				end
				table.clear(tmpl)
				table.freeze(tmpl)
				kv[ki] = tmpl
			elseif kt == LBC_CONSTANT_TABLE_WITH_CONSTANTS then
				local c = kValues[ki]
				local tmpl = cloneDuptableSeed(c.length)
				local keys = c.keys
				local consts = c.constants
				for m = 1, c.length do
					local k = kv[keys[m] + 1]
					if k ~= nil then
						tmpl[k] = true
					end
				end
				table.clear(tmpl)
				for m = 1, c.length do
					local cid = consts[m]
					if cid >= 0 then
						local k = kv[keys[m] + 1]
						if k ~= nil then
							tmpl[k] = kv[cid + 1]
						end
					end
				end
				table.freeze(tmpl)
				kv[ki] = tmpl
			end
		end
	end

	return kv, importIndices
end

local INLINE_FC1_ARR: { boolean } = table.create(256, false)
local INLINE_FC2_ARR: { boolean } = table.create(256, false)
for _, id in
	{
		LBF_MATH_ABS,
		LBF_MATH_FLOOR,
		LBF_MATH_CEIL,
		LBF_MATH_SQRT,
		LBF_MATH_ROUND,
		LBF_MATH_SIN,
		LBF_MATH_COS,
		LBF_MATH_SIGN,
		LBF_TYPE,
		LBF_TYPEOF,
		LBF_STRING_BYTE,
		LBF_STRING_LEN,
		LBF_BIT32_BNOT,
		LBF_GETMETATABLE,
		LBF_TONUMBER,
		LBF_TOSTRING,
		LBF_TABLE_CREATE,
	}
do
	INLINE_FC1_ARR[id + 1] = true
end
for _, id in
	{
		LBF_BIT32_BXOR,
		LBF_BIT32_BAND,
		LBF_BIT32_BOR,
		LBF_BIT32_LSHIFT,
		LBF_BIT32_RSHIFT,
		LBF_BIT32_BTEST,
		LBF_MATH_MIN,
		LBF_MATH_MAX,
		LBF_STRING_BYTE,
		LBF_STRING_SUB,
		LBF_RAWEQUAL,
		LBF_SETMETATABLE,
		LBF_TABLE_CREATE,
	}
do
	INLINE_FC2_ARR[id + 1] = true
end

@native
local function canInlineFastcall(op: number, bfid: number, callB: number, callNresults: number): number
	if callNresults == 1 then
		if op == LOP_FASTCALL1 then
			if (callB == 2 and INLINE_FC1_ARR[bfid + 1]) or (callB == 0 and bfid == LBF_SELECT_VARARG) then
				return 1
			end
		elseif (op == LOP_FASTCALL2 or op == LOP_FASTCALL2K) and callB == 3 then
			if INLINE_FC2_ARR[bfid + 1] then
				return 1
			end
		elseif op == LOP_FASTCALL3 and callB == 4 then
			if bfid == LBF_STRING_SUB or bfid == LBF_MATH_CLAMP then
				return 1
			end
		end
	elseif callNresults == 0 then
		if (op == LOP_FASTCALL2 or op == LOP_FASTCALL2K) and callB == 3 then
			if bfid == LBF_TABLE_INSERT or bfid == LBF_SETMETATABLE then
				return 0
			end
		end
	end
	return -1
end

@native
local function fuseCallSuperinstructions(
	ops: { number },
	argA: { number },
	fuseCands: { number },
	nFuse: number,
	jTargetsBuf: buffer,
	clen: number
)
	for fi = 1, nFuse do
		local fpc = fuseCands[fi]
		local callPc = fpc + 2
		if
			callPc <= clen
			and ops[callPc] == VOP_CALL
			and argA[callPc] == argA[fpc]
			and buffer.readu8(jTargetsBuf, callPc) == 0
		then
			local fop = ops[fpc]
			if fop == VOP_NAMECALL then
				ops[fpc] = VOP_NAMECALL_CALL
			elseif fop == VOP_GETTABLEKS then
				ops[fpc] = VOP_GETTABLEKS_CALL
			elseif fop == VOP_GETIMPORT then
				ops[fpc] = VOP_GETIMPORT_CALL
			end
		end
	end
end

@native
local function predecodeProtoTemplate(proto: Proto): ProtoTemplate
	local pcode = proto.code
	local clen = #pcode
	local _, jTargetsBuf = ensureScratchCap(clen)
	local fuseCands = fuseCandidates
	local nFuse = 0
	local ops: { number } = table.create(clen, 0) :: { number }
	local argA: { number } = table.create(clen, 0) :: { number }
	local argB: { number } = table.create(clen, 0) :: { number }
	local argC: { number } = table.create(clen, 0) :: { number }
	local argD: { number } = table.create(clen, 0) :: { number }
	local auxVal: { [number]: any } = table.create(clen)
	local kv, importIndices = predecodeBaseConstants(proto)
	local kValues = proto.kValues
	local fcInfo: { [number]: FastcallDesc }? = nil
	local fcRa: { [number]: number }? = nil
	local hasOpenTop = false

	local ci = 1
	while ci <= clen do
		local insn = pcode[ci]
		local op = band(insn, 0xff)
		local aRaw = band(rshift(insn, 8), 0xff)
		local bRaw = band(rshift(insn, 16), 0xff)
		local cRaw = band(rshift(insn, 24), 0xff)
		local du = rshift(insn, 16)
		local dRaw = if du >= 0x8000 then du - 0x10000 else du

		local vop = RAW_TO_VOP[op + 1]
		ops[ci] = vop
		argA[ci] = aRaw + 1
		argB[ci] = bRaw + 1
		argC[ci] = cRaw + 1
		if JUMP_D_OP_ARR[op + 1] then
			local target = ci + 1 + dRaw
			argD[ci] = target
			if target >= 1 and target <= clen then
				buffer.writeu8(jTargetsBuf, target, 1)
			end
		else
			argD[ci] = dRaw
		end

		if op == LOP_CALL or op == LOP_CALLFB then
			ops[ci] = VOP_CALL
			argB[ci] = bRaw
			argC[ci] = cRaw - 1
			argD[ci] = ci + (if op == LOP_CALLFB then 2 else 1)
			if cRaw == 0 then
				hasOpenTop = true
			end
		elseif op == LOP_LOADK or op == LOP_DUPTABLE then
			local ki = dRaw + 1
			argD[ci] = ki
			auxVal[ci] = kv[ki]
		elseif op == LOP_GETIMPORT then
			argD[ci] = dRaw + 1
			nFuse += 1
			fuseCands[nFuse] = ci
		elseif op == LOP_GETTABLEKS or op == LOP_NAMECALL then
			nFuse += 1
			fuseCands[nFuse] = ci
		elseif op == LOP_NEWCLOSURE then
			argD[ci] = proto.p[dRaw + 1]
		elseif op == LOP_DUPCLOSURE then
			argD[ci] = kValues[dRaw + 1]
		elseif
			op == LOP_ADDK
			or op == LOP_SUBK
			or op == LOP_MULK
			or op == LOP_DIVK
			or op == LOP_MODK
			or op == LOP_POWK
			or op == LOP_ANDK
			or op == LOP_ORK
			or op == LOP_IDIVK
		then
			auxVal[ci] = kv[cRaw + 1]
		elseif op == LOP_SUBRK or op == LOP_DIVRK then
			auxVal[ci] = kv[bRaw + 1]
		elseif op == LOP_GETTABLEN or op == LOP_SETTABLEN then
			argC[ci] = cRaw + 1
		elseif op == LOP_LOADB then
			argB[ci] = bRaw
			local target = ci + 1 + cRaw
			argC[ci] = target
			if cRaw ~= 0 and target >= 1 and target <= clen then
				buffer.writeu8(jTargetsBuf, target, 1)
			end
		elseif op == LOP_RETURN or op == LOP_GETVARARGS then
			argA[ci] = aRaw + 1
			argB[ci] = bRaw
			if op == LOP_GETVARARGS and bRaw == 0 then
				hasOpenTop = true
			end
		elseif op == LOP_CLOSEUPVALS then
			argA[ci] = aRaw + 1
		elseif op == LOP_SETLIST then
			argB[ci] = bRaw + 1
			argC[ci] = cRaw
		elseif op == LOP_CAPTURE then
			ops[ci] = VOP_CAPTURE
			argA[ci] = aRaw
			argB[ci] = bRaw + 1
		elseif op == LOP_JUMPX then
			local eu = rshift(insn, 8)
			local eRaw = if eu >= 0x800000 then eu - 0x1000000 else eu
			local target = ci + 1 + eRaw
			argD[ci] = target
			if target >= 1 and target <= clen then
				buffer.writeu8(jTargetsBuf, target, 1)
			end
		elseif
			op == LOP_FASTCALL
			or op == LOP_FASTCALL1
			or op == LOP_FASTCALL2
			or op == LOP_FASTCALL2K
			or op == LOP_FASTCALL3
		then
			argA[ci] = aRaw
		elseif op == LOP_FASTPCALL then
			local callPc = ci + 1 + cRaw
			if callPc >= 1 and callPc <= clen then
				buffer.writeu8(jTargetsBuf, callPc, 1)
			end
			local callInsn = pcode[callPc]
			local callOp = band(callInsn, 0xff)
			local ra = band(rshift(callInsn, 8), 0xff) + 1
			local callB = band(rshift(callInsn, 16), 0xff)
			local callNresults = band(rshift(callInsn, 24), 0xff) - 1
			local afterCallPc = callPc + (if callOp == LOP_CALLFB then 2 else 1)
			argA[ci] = aRaw
			argB[ci] = callB
			argC[ci] = callNresults
			argD[ci] = afterCallPc
			auxVal[ci] = ra
		end

		local isTwoWord = TWO_WORD_OP_ARR[op + 1]
		if isTwoWord then
			local aux = pcode[ci + 1] or 0
			if op == LOP_GETTABLEKS or op == LOP_NAMECALL then
				auxVal[ci] = kv[band(aux, 0xffffff) + 1]
			elseif op == LOP_SETTABLEKS then
				local k = kv[band(aux, 0xffffff) + 1]
				auxVal[ci] = k
				argC[ci] = if SAFE_INVALIDATION_KEYS[k] ~= nil then 1 else 0
			elseif op == LOP_GETUDATAKS or op == LOP_NAMECALLUDATA then
				auxVal[ci] = kv[band(aux, 0xffff) + 1]
			elseif op == LOP_SETUDATAKS then
				local k = kv[band(aux, 0xffff) + 1]
				auxVal[ci] = k
				argC[ci] = if SAFE_INVALIDATION_KEYS[k] ~= nil then 1 else 0
			elseif op == LOP_GETGLOBAL then
				local k = kv[aux + 1]
				auxVal[ci] = k
				argC[ci] = if k == "_G" then 1 else 0
			elseif op == LOP_SETGLOBAL then
				local k = kv[aux + 1]
				auxVal[ci] = k
				argC[ci] = if SAFE_INVALIDATION_KEYS[k] ~= nil then 1 else 0
			elseif op == LOP_LOADKX or op == LOP_FASTCALL2K then
				auxVal[ci] = kv[aux + 1]
			elseif
				op == LOP_JUMPIFEQ
				or op == LOP_JUMPIFLE
				or op == LOP_JUMPIFLT
				or op == LOP_JUMPIFNOTEQ
				or op == LOP_JUMPIFNOTLE
				or op == LOP_JUMPIFNOTLT
			then
				argC[ci] = aux + 1
			elseif op == LOP_JUMPXEQKN or op == LOP_JUMPXEQKS then
				auxVal[ci] = kv[band(aux, 0xffffff) + 1]
				argC[ci] = if band(aux, 0x80000000) ~= 0 then 1 else 0
			elseif op == LOP_JUMPXEQKB then
				auxVal[ci] = band(aux, 1) ~= 0
				argC[ci] = if band(aux, 0x80000000) ~= 0 then 1 else 0
			elseif op == LOP_JUMPXEQKNIL then
				argC[ci] = if band(aux, 0x80000000) ~= 0 then 1 else 0
			elseif op == LOP_FASTCALL2 then
				argC[ci] = aux + 1
			elseif op == LOP_FASTCALL3 then
				argC[ci] = band(aux, 0xff) + 1
				argB[ci + 1] = band(rshift(aux, 8), 0xff) + 1
			elseif op == LOP_NEWTABLE then
				argD[ci] = if aux > 65536 then 65536 else aux
			elseif op == LOP_SETLIST then
				argD[ci] = aux
			elseif op == LOP_FORGLOOP then
				argC[ci] = band(aux, 0xff)
			else
				auxVal[ci] = aux
			end
		end

		if
			op == LOP_FASTCALL
			or op == LOP_FASTCALL1
			or op == LOP_FASTCALL2
			or op == LOP_FASTCALL2K
			or op == LOP_FASTCALL3
		then
			local callPc = ci + 1 + cRaw
			if callPc >= 1 and callPc <= clen then
				buffer.writeu8(jTargetsBuf, callPc, 1)
			end
			local callInsn = pcode[callPc]
			local callOp = band(callInsn, 0xff)
			local ra = band(rshift(callInsn, 8), 0xff) + 1
			local callB = band(rshift(callInsn, 16), 0xff)
			local callNresults = band(rshift(callInsn, 24), 0xff) - 1
			local afterCallPc = callPc + (if callOp == LOP_CALLFB then 2 else 1)
			local handler: Fastcalls.FastcallHandler? = FASTCALL_HANDLERS[aRaw]
			local rootBit = BUILTIN_ROOT_BIT[aRaw] or 0
			if handler ~= nil and aRaw == LBF_VECTOR then
				local nextPc = ci + (if isTwoWord then 2 else 1)
				if nextPc + 1 <= callPc and band(pcode[nextPc], 0xff) == LOP_GETIMPORT then
					local cnt, id0, id1 = BytecodeCodec.decomposeImportId(pcode[nextPc + 1])
					local rootName = if cnt == 2 and id0 >= 0 then kValues[id0 + 1] else nil
					local memName = if cnt == 2 and id1 >= 0 then kValues[id1 + 1] else nil
					if rootName == "Vector3" and memName == "new" then
						rootBit = ROOT_BITS.Vector3
					elseif not (rootName == "vector" and memName == "create") then
						handler = nil
					end
				else
					handler = nil
				end
			end
			local desc: FastcallDesc = {
				bfid = aRaw,
				ra = ra,
				callB = callB,
				callNresults = callNresults,
				afterCallPc = afterCallPc,
				handler = handler,
				rootBit = rootBit,
			}
			if fcInfo then
				fcInfo[ci] = desc
			else
				fcInfo = { [ci] = desc }
			end

			local inlineKind = canInlineFastcall(op, aRaw, callB, callNresults)
			if inlineKind >= 0 then
				local raEnc = if inlineKind == 1 then ra else 0
				if fcRa then
					fcRa[ci] = raEnc
				else
					fcRa = { [ci] = raEnc }
				end
				argD[ci] = afterCallPc
			end
		end

		ci += if isTwoWord then 2 else 1
	end

	if nFuse > 0 then
		fuseCallSuperinstructions(ops, argA, fuseCands, nFuse, jTargetsBuf, clen)
	end

	return {
		code = pcode,
		ops = ops,
		argA = argA,
		argB = argB,
		argC = argC,
		argD = argD,
		fcRa = fcRa,
		auxVal = auxVal,
		fcInfo = fcInfo,
		kTypes = proto.kTypes,
		kValues = kValues,
		baseKVals = kv,
		importIndices = importIndices,
		hasOpenTop = hasOpenTop,
	}
end

@native
local function verifyAndPredecodeProto(proto: Proto, protos: { Proto }, fromBinary: boolean?): (ProtoTemplate?, string?)
	local maxstack = proto.maxstacksize
	local nups = proto.nups
	local kTypes: { number } = proto.kTypes
	local kValues: { any } = proto.kValues
	local pList = proto.p
	local pcode = proto.code

	local sizek = #kTypes
	local sizep = #pList
	local clen = #pcode
	if clen <= 0 then
		return nil, "empty proto code"
	end

	if not fromBinary then
		local constErr = verifyProtoConstantsAndChildren(proto, protos)
		if constErr then
			return nil, constErr
		end
	end

	local insnStartsBuf, jTargetsBuf = ensureScratchCap(clen)
	local pend = pendingTargets
	local npend = 0
	local fuseCands = fuseCandidates
	local nFuse = 0

	local ops: { number } = table.create(clen, 0) :: { number }
	local argA: { number } = table.create(clen, 0) :: { number }
	local argB: { number } = table.create(clen, 0) :: { number }
	local argC: { number } = table.create(clen, 0) :: { number }
	local argD: { number } = table.create(clen, 0) :: { number }
	local auxVal: { [number]: any } = table.create(clen)
	local kv, importIndices = predecodeBaseConstants(proto)
	local fcInfo: { [number]: FastcallDesc }? = nil
	local fcRa: { [number]: number }? = nil
	local hasOpenTop = false

	local ci = 1
	local lastInsnCi = 1
	while ci <= clen do
		local insn = pcode[ci]
		if not fromBinary and (type(insn) ~= "number" or insn ~= math.floor(insn)) then
			return nil, "invalid instruction"
		end
		local op = band(insn, 0xff)
		if op >= LOP__COUNT then
			return nil, "unsupported opcode: " .. tostring(op)
		end
		if CLASS_OPCODE_ARR[op + 1] then
			return nil, "unsupported experimental class bytecode (v100)"
		end
		if op == LOP_NATIVECALL then
			return nil, "unsupported opcode: " .. tostring(op)
		end
		if op == LOP_CAPTURE then
			return nil, "unexpected standalone LOP_CAPTURE"
		end
		local isTwoWord = TWO_WORD_OP_ARR[op + 1]
		local aux = 0
		if isTwoWord then
			if ci + 1 > clen then
				return nil, "truncated two-word instruction"
			end
			aux = pcode[ci + 1]
			if not fromBinary and (type(aux) ~= "number" or aux ~= math.floor(aux) or aux < 0 or aux > 0xffffffff) then
				return nil, "invalid instruction aux word"
			end
		end

		buffer.writeu8(insnStartsBuf, ci, 1)
		lastInsnCi = ci

		local aRaw = band(rshift(insn, 8), 0xff)
		local bRaw = band(rshift(insn, 16), 0xff)
		local cRaw = band(rshift(insn, 24), 0xff)
		local u = rshift(insn, 16)
		local dRaw = if u >= 0x8000 then u - 0x10000 else u

		ops[ci] = RAW_TO_VOP[op + 1]
		argA[ci] = aRaw + 1
		argB[ci] = bRaw + 1
		argC[ci] = cRaw + 1
		local nextCi = ci + (if isTwoWord then 2 else 1)

		if JUMP_D_OP_ARR[op + 1] then
			local target = ci + 1 + dRaw
			if target < 1 or target > clen then
				return nil, "jump target out of bounds"
			end
			if target <= ci then
				if buffer.readu8(insnStartsBuf, target) == 0 then
					return nil, "misaligned jump target"
				end
			else
				npend += 1
				pend[npend] = target
			end
			buffer.writeu8(jTargetsBuf, target, 1)
			argD[ci] = target
		else
			argD[ci] = dRaw
		end

		if op == LOP_LOADNIL or op == LOP_LOADN or op == LOP_JUMPIF or op == LOP_JUMPIFNOT or op == LOP_CMPPROTO then
			if aRaw >= maxstack then
				return nil, "register out of bounds"
			end
		elseif op == LOP_NEWTABLE then
			if aRaw >= maxstack then
				return nil, "register out of bounds"
			end
			argD[ci] = if aux > 65536 then 65536 else aux
		elseif op == LOP_CLOSEUPVALS then
			if aRaw > maxstack then
				return nil, "register out of bounds"
			end
		elseif op == LOP_LOADB then
			if aRaw >= maxstack then
				return nil, "register out of bounds"
			end
			if cRaw ~= 0 then
				local target = ci + 1 + cRaw
				if target < 1 or target > clen then
					return nil, "jump target out of bounds"
				end
				npend += 1
				pend[npend] = target
				buffer.writeu8(jTargetsBuf, target, 1)
			end
			argB[ci] = bRaw
			argC[ci] = ci + 1 + cRaw
		elseif op == LOP_LOADK then
			if aRaw >= maxstack then
				return nil, "register out of bounds"
			end
			if dRaw < 0 or dRaw >= sizek then
				return nil, "constant index out of bounds"
			end
			if not isScalarTag(kTypes[dRaw + 1]) then
				return nil, "invalid constant type for LOADK"
			end
			local ki = dRaw + 1
			argD[ci] = ki
			auxVal[ci] = kv[ki]
		elseif op == LOP_GETIMPORT then
			if aRaw >= maxstack then
				return nil, "register out of bounds"
			end
			if dRaw < 0 or dRaw >= sizek then
				return nil, "constant index out of bounds"
			end
			if kTypes[dRaw + 1] ~= LBC_CONSTANT_IMPORT then
				return nil, "invalid constant type for GETIMPORT"
			end
			local cnt, id0, id1, id2 = BytecodeCodec.decomposeImportId(aux)
			if
				cnt < 1
				or cnt > 3
				or id0 < 0
				or id0 >= sizek
				or (cnt >= 2 and (id1 < 0 or id1 >= sizek))
				or (cnt >= 3 and (id2 < 0 or id2 >= sizek))
			then
				return nil, "import aux constant index out of bounds"
			end
			if
				kTypes[id0 + 1] ~= LBC_CONSTANT_STRING
				or (cnt >= 2 and kTypes[id1 + 1] ~= LBC_CONSTANT_STRING)
				or (cnt >= 3 and kTypes[id2 + 1] ~= LBC_CONSTANT_STRING)
			then
				return nil, "import aux piece must be string"
			end
			argD[ci] = dRaw + 1
			auxVal[ci] = aux
			nFuse += 1
			fuseCands[nFuse] = ci
		elseif op == LOP_DUPTABLE then
			if aRaw >= maxstack then
				return nil, "register out of bounds"
			end
			if dRaw < 0 or dRaw >= sizek then
				return nil, "constant index out of bounds"
			end
			local ctype = kTypes[dRaw + 1]
			if ctype ~= LBC_CONSTANT_TABLE and ctype ~= LBC_CONSTANT_TABLE_WITH_CONSTANTS then
				return nil, "invalid duptable constant"
			end
			local ki = dRaw + 1
			argD[ci] = ki
			auxVal[ci] = kv[ki]
		elseif
			op == LOP_MOVE
			or op == LOP_NOT
			or op == LOP_MINUS
			or op == LOP_LENGTH
			or op == LOP_GETTABLEN
			or op == LOP_SETTABLEN
		then
			if aRaw >= maxstack or bRaw >= maxstack then
				return nil, "register out of bounds"
			end
		elseif op == LOP_GETGLOBAL then
			if aRaw >= maxstack then
				return nil, "register out of bounds"
			end
			if aux < 0 or aux >= sizek then
				return nil, "constant index out of bounds"
			end
			if kTypes[aux + 1] ~= LBC_CONSTANT_STRING then
				return nil, "global name constant must be string"
			end
			local k = kv[aux + 1]
			auxVal[ci] = k
			argC[ci] = if k == "_G" then 1 else 0
		elseif op == LOP_SETGLOBAL then
			if aRaw >= maxstack then
				return nil, "register out of bounds"
			end
			if aux < 0 or aux >= sizek then
				return nil, "constant index out of bounds"
			end
			if kTypes[aux + 1] ~= LBC_CONSTANT_STRING then
				return nil, "global name constant must be string"
			end
			local k = kv[aux + 1]
			auxVal[ci] = k
			argC[ci] = if SAFE_INVALIDATION_KEYS[k] ~= nil then 1 else 0
		elseif op == LOP_LOADKX then
			if aRaw >= maxstack then
				return nil, "register out of bounds"
			end
			if aux < 0 or aux >= sizek then
				return nil, "constant index out of bounds"
			end
			if not isScalarTag(kTypes[aux + 1]) then
				return nil, "invalid constant type for LOADKX"
			end
			auxVal[ci] = kv[aux + 1]
		elseif op == LOP_GETUPVAL or op == LOP_SETUPVAL then
			if aRaw >= maxstack then
				return nil, "register out of bounds"
			end
			if bRaw >= nups then
				return nil, "upvalue index out of bounds"
			end
		elseif
			op == LOP_GETTABLE
			or op == LOP_SETTABLE
			or op == LOP_ADD
			or op == LOP_SUB
			or op == LOP_MUL
			or op == LOP_DIV
			or op == LOP_MOD
			or op == LOP_POW
			or op == LOP_AND
			or op == LOP_OR
			or op == LOP_IDIV
		then
			if aRaw >= maxstack or bRaw >= maxstack or cRaw >= maxstack then
				return nil, "register out of bounds"
			end
		elseif op == LOP_CONCAT then
			if aRaw >= maxstack or bRaw >= maxstack or cRaw >= maxstack or bRaw > cRaw then
				return nil, "register out of bounds"
			end
		elseif op == LOP_GETTABLEKS then
			if aRaw >= maxstack or bRaw >= maxstack then
				return nil, "register out of bounds"
			end
			local kidx = band(aux, 0xffffff)
			if kidx >= sizek then
				return nil, "constant index out of bounds"
			end
			if kTypes[kidx + 1] ~= LBC_CONSTANT_STRING then
				return nil, "table key constant must be string"
			end
			auxVal[ci] = kv[kidx + 1]
			nFuse += 1
			fuseCands[nFuse] = ci
		elseif op == LOP_SETTABLEKS then
			if aRaw >= maxstack or bRaw >= maxstack then
				return nil, "register out of bounds"
			end
			local kidx = band(aux, 0xffffff)
			if kidx >= sizek then
				return nil, "constant index out of bounds"
			end
			if kTypes[kidx + 1] ~= LBC_CONSTANT_STRING then
				return nil, "table key constant must be string"
			end
			local k = kv[kidx + 1]
			auxVal[ci] = k
			argC[ci] = if SAFE_INVALIDATION_KEYS[k] ~= nil then 1 else 0
		elseif op == LOP_GETUDATAKS then
			if aRaw >= maxstack or bRaw >= maxstack then
				return nil, "register out of bounds"
			end
			local kidx = band(aux, 0xffff)
			if kidx >= sizek then
				return nil, "constant index out of bounds"
			end
			if kTypes[kidx + 1] ~= LBC_CONSTANT_STRING then
				return nil, "userdata key constant must be string"
			end
			auxVal[ci] = kv[kidx + 1]
		elseif op == LOP_SETUDATAKS then
			if aRaw >= maxstack or bRaw >= maxstack then
				return nil, "register out of bounds"
			end
			local kidx = band(aux, 0xffff)
			if kidx >= sizek then
				return nil, "constant index out of bounds"
			end
			if kTypes[kidx + 1] ~= LBC_CONSTANT_STRING then
				return nil, "userdata key constant must be string"
			end
			local k = kv[kidx + 1]
			auxVal[ci] = k
			argC[ci] = if SAFE_INVALIDATION_KEYS[k] ~= nil then 1 else 0
		elseif op == LOP_NAMECALL then
			if aRaw + 1 >= maxstack or bRaw >= maxstack then
				return nil, "register out of bounds"
			end
			local kidx = band(aux, 0xffffff)
			if kidx >= sizek then
				return nil, "constant index out of bounds"
			end
			if kTypes[kidx + 1] ~= LBC_CONSTANT_STRING then
				return nil, "namecall method constant must be string"
			end
			auxVal[ci] = kv[kidx + 1]
			nFuse += 1
			fuseCands[nFuse] = ci
		elseif op == LOP_NAMECALLUDATA then
			if aRaw + 1 >= maxstack or bRaw >= maxstack then
				return nil, "register out of bounds"
			end
			local kidx = band(aux, 0xffff)
			if kidx >= sizek then
				return nil, "constant index out of bounds"
			end
			if kTypes[kidx + 1] ~= LBC_CONSTANT_STRING then
				return nil, "userdata method constant must be string"
			end
			auxVal[ci] = kv[kidx + 1]
		elseif op == LOP_NEWCLOSURE then
			if aRaw >= maxstack then
				return nil, "register out of bounds"
			end
			if dRaw < 0 or dRaw >= sizep then
				return nil, "child proto index out of bounds"
			end
			local childFid = pList[dRaw + 1]
			local childProto = protos[childFid + 1]
			if not childProto or ci + childProto.nups > clen then
				return nil, "invalid child closure"
			end
			argD[ci] = childFid
			local childNups = childProto.nups
			for ui = 1, childNups do
				local capCi = ci + ui
				local capInsn = pcode[capCi]
				if
					(not fromBinary and (type(capInsn) ~= "number" or capInsn ~= math.floor(capInsn)))
					or band(capInsn, 0xff) ~= LOP_CAPTURE
				then
					return nil, "expected LOP_CAPTURE after closure instruction"
				end
				local capA = band(rshift(capInsn, 8), 0xff)
				local capB = band(rshift(capInsn, 16), 0xff)
				if capA == Captures.LCT_VAL or capA == Captures.LCT_REF then
					if capB >= maxstack then
						return nil, "capture register out of bounds"
					end
				elseif capA == Captures.LCT_UPVAL then
					if capB >= nups then
						return nil, "capture upvalue out of bounds"
					end
				else
					return nil, "invalid capture type"
				end
				ops[capCi] = VOP_CAPTURE
				argA[capCi] = capA
				argB[capCi] = capB + 1
			end
			nextCi = ci + 1 + childNups
		elseif op == LOP_DUPCLOSURE then
			if aRaw >= maxstack then
				return nil, "register out of bounds"
			end
			if dRaw < 0 or dRaw >= sizek then
				return nil, "constant index out of bounds"
			end
			if kTypes[dRaw + 1] ~= LBC_CONSTANT_CLOSURE then
				return nil, "invalid closure constant"
			end
			local childFid = kValues[dRaw + 1]
			local childProto = protos[childFid + 1]
			if not childProto or ci + childProto.nups > clen then
				return nil, "invalid child closure"
			end
			argD[ci] = childFid
			local childNups = childProto.nups
			for ui = 1, childNups do
				local capCi = ci + ui
				local capInsn = pcode[capCi]
				if
					(not fromBinary and (type(capInsn) ~= "number" or capInsn ~= math.floor(capInsn)))
					or band(capInsn, 0xff) ~= LOP_CAPTURE
				then
					return nil, "expected LOP_CAPTURE after closure instruction"
				end
				local capA = band(rshift(capInsn, 8), 0xff)
				if capA == Captures.LCT_REF then
					return nil, "DUPCLOSURE cannot capture by reference"
				end
				local capB = band(rshift(capInsn, 16), 0xff)
				if capA == Captures.LCT_VAL then
					if capB >= maxstack then
						return nil, "capture register out of bounds"
					end
				elseif capA == Captures.LCT_UPVAL then
					if capB >= nups then
						return nil, "capture upvalue out of bounds"
					end
				else
					return nil, "invalid capture type"
				end
				ops[capCi] = VOP_CAPTURE
				argA[capCi] = capA
				argB[capCi] = capB + 1
			end
			nextCi = ci + 1 + childNups
		elseif op == LOP_CALL or op == LOP_CALLFB then
			if aRaw >= maxstack then
				return nil, "register out of bounds"
			end
			if (bRaw > 1 and aRaw + bRaw - 1 >= maxstack) or (cRaw > 1 and aRaw + cRaw - 2 >= maxstack) then
				return nil, "call register out of bounds"
			end
			ops[ci] = VOP_CALL
			argB[ci] = bRaw
			argC[ci] = cRaw - 1
			argD[ci] = ci + (if op == LOP_CALLFB then 2 else 1)
			if cRaw == 0 then
				hasOpenTop = true
			end
			if isTwoWord then
				auxVal[ci] = aux
			end
		elseif op == LOP_RETURN or op == LOP_GETVARARGS then
			if op == LOP_GETVARARGS and bRaw == 0 then
				hasOpenTop = true
			end
			if bRaw == 0 then
				if aRaw > maxstack then
					return nil, "register out of bounds"
				end
			elseif bRaw > 1 and aRaw + bRaw - 2 >= maxstack then
				return nil, "register out of bounds"
			end
			argB[ci] = bRaw
		elseif op == LOP_JUMPXEQKN then
			if aRaw >= maxstack then
				return nil, "register out of bounds"
			end
			local kidx = band(aux, 0xffffff)
			if kidx >= sizek then
				return nil, "constant index out of bounds"
			end
			if kTypes[kidx + 1] ~= LBC_CONSTANT_NUMBER then
				return nil, "JUMPXEQKN constant must be number"
			end
			auxVal[ci] = kv[kidx + 1]
			argC[ci] = if band(aux, 0x80000000) ~= 0 then 1 else 0
		elseif op == LOP_JUMPXEQKS then
			if aRaw >= maxstack then
				return nil, "register out of bounds"
			end
			local kidx = band(aux, 0xffffff)
			if kidx >= sizek then
				return nil, "constant index out of bounds"
			end
			if kTypes[kidx + 1] ~= LBC_CONSTANT_STRING then
				return nil, "JUMPXEQKS constant must be string"
			end
			auxVal[ci] = kv[kidx + 1]
			argC[ci] = if band(aux, 0x80000000) ~= 0 then 1 else 0
		elseif op == LOP_JUMPXEQKB then
			if aRaw >= maxstack then
				return nil, "register out of bounds"
			end
			auxVal[ci] = band(aux, 1) ~= 0
			argC[ci] = if band(aux, 0x80000000) ~= 0 then 1 else 0
		elseif op == LOP_JUMPXEQKNIL then
			if aRaw >= maxstack then
				return nil, "register out of bounds"
			end
			argC[ci] = if band(aux, 0x80000000) ~= 0 then 1 else 0
		elseif
			op == LOP_JUMPIFEQ
			or op == LOP_JUMPIFLE
			or op == LOP_JUMPIFLT
			or op == LOP_JUMPIFNOTEQ
			or op == LOP_JUMPIFNOTLE
			or op == LOP_JUMPIFNOTLT
		then
			if aRaw >= maxstack or aux < 0 or aux >= maxstack then
				return nil, "register out of bounds"
			end
			argC[ci] = aux + 1
		elseif
			op == LOP_ADDK
			or op == LOP_SUBK
			or op == LOP_MULK
			or op == LOP_DIVK
			or op == LOP_MODK
			or op == LOP_POWK
			or op == LOP_IDIVK
		then
			if aRaw >= maxstack or bRaw >= maxstack then
				return nil, "register out of bounds"
			end
			if cRaw >= sizek then
				return nil, "constant index out of bounds"
			end
			if kTypes[cRaw + 1] ~= LBC_CONSTANT_NUMBER then
				return nil, "arithmetic K constant must be number"
			end
			auxVal[ci] = kv[cRaw + 1]
		elseif op == LOP_ANDK or op == LOP_ORK then
			if aRaw >= maxstack or bRaw >= maxstack then
				return nil, "register out of bounds"
			end
			if cRaw >= sizek then
				return nil, "constant index out of bounds"
			end
			if not isScalarTag(kTypes[cRaw + 1]) then
				return nil, "invalid constant type for logical op"
			end
			auxVal[ci] = kv[cRaw + 1]
		elseif op == LOP_SUBRK or op == LOP_DIVRK then
			if aRaw >= maxstack or cRaw >= maxstack then
				return nil, "register out of bounds"
			end
			if bRaw >= sizek then
				return nil, "constant index out of bounds"
			end
			if kTypes[bRaw + 1] ~= LBC_CONSTANT_NUMBER then
				return nil, "arithmetic RK constant must be number"
			end
			auxVal[ci] = kv[bRaw + 1]
		elseif op == LOP_SETLIST then
			if aRaw >= maxstack then
				return nil, "register out of bounds"
			end
			if cRaw == 0 then
				if bRaw > maxstack then
					return nil, "register out of bounds"
				end
			elseif cRaw > 1 and bRaw + cRaw - 2 >= maxstack then
				return nil, "register out of bounds"
			end
			argC[ci] = cRaw
			argD[ci] = aux
		elseif
			op == LOP_FORNPREP
			or op == LOP_FORNLOOP
			or op == LOP_FORGPREP_INEXT
			or op == LOP_FORGPREP_NEXT
			or op == LOP_FORGPREP
		then
			if aRaw + 2 >= maxstack then
				return nil, "for-loop register out of bounds"
			end
		elseif op == LOP_FORGLOOP then
			local nvars = band(aux, 0xff)
			if nvars < 1 or aRaw + 2 + nvars >= maxstack then
				return nil, "for-loop register out of bounds"
			end
			argC[ci] = nvars
		elseif op == LOP_JUMPX then
			local eu = rshift(insn, 8)
			local e = if eu >= 0x800000 then eu - 0x1000000 else eu
			local target = ci + 1 + e
			if target < 1 or target > clen then
				return nil, "jump target out of bounds"
			end
			if target <= ci then
				if buffer.readu8(insnStartsBuf, target) == 0 then
					return nil, "misaligned jump target"
				end
			else
				npend += 1
				pend[npend] = target
			end
			argD[ci] = target
			buffer.writeu8(jTargetsBuf, target, 1)
		elseif
			op == LOP_FASTCALL
			or op == LOP_FASTCALL1
			or op == LOP_FASTCALL2
			or op == LOP_FASTCALL2K
			or op == LOP_FASTCALL3
		then
			local callPc = ci + 1 + cRaw
			if callPc < 1 or callPc > clen then
				return nil, "fastcall target out of bounds"
			end
			npend += 1
			pend[npend] = -callPc
			buffer.writeu8(jTargetsBuf, callPc, 1)
			if op ~= LOP_FASTCALL and bRaw >= maxstack then
				return nil, "fastcall register out of bounds"
			end
			argA[ci] = aRaw
			if op == LOP_FASTCALL2 then
				if aux < 0 or aux >= maxstack then
					return nil, "fastcall register out of bounds"
				end
				argC[ci] = aux + 1
			elseif op == LOP_FASTCALL2K then
				if aux < 0 or aux >= sizek then
					return nil, "fastcall constant index out of bounds"
				end
				if not isScalarTag(kTypes[aux + 1]) then
					return nil, "invalid fastcall constant type"
				end
				auxVal[ci] = kv[aux + 1]
			elseif op == LOP_FASTCALL3 then
				if band(aux, 0xff) >= maxstack or band(rshift(aux, 8), 0xff) >= maxstack then
					return nil, "fastcall register out of bounds"
				end
				argC[ci] = band(aux, 0xff) + 1
				argB[ci + 1] = band(rshift(aux, 8), 0xff) + 1
			end

			local callInsn = pcode[callPc]
			if type(callInsn) == "number" then
				local callOp = band(callInsn, 0xff)
				local ra = band(rshift(callInsn, 8), 0xff) + 1
				local callB = band(rshift(callInsn, 16), 0xff)
				local callNresults = band(rshift(callInsn, 24), 0xff) - 1
				local afterCallPc = callPc + (if callOp == LOP_CALLFB then 2 else 1)
				local handler: Fastcalls.FastcallHandler? = FASTCALL_HANDLERS[aRaw]
				local rootBit = BUILTIN_ROOT_BIT[aRaw] or 0
				if handler ~= nil and aRaw == LBF_VECTOR then
					local nextPc = ci + (if isTwoWord then 2 else 1)
					if
						nextPc + 1 <= callPc
						and type(pcode[nextPc]) == "number"
						and band(pcode[nextPc], 0xff) == LOP_GETIMPORT
					then
						local auxImp = pcode[nextPc + 1]
						if type(auxImp) == "number" then
							local cnt, id0, id1 = BytecodeCodec.decomposeImportId(auxImp)
							local rootName = if cnt == 2 and id0 >= 0 then kValues[id0 + 1] else nil
							local memName = if cnt == 2 and id1 >= 0 then kValues[id1 + 1] else nil
							if rootName == "Vector3" and memName == "new" then
								rootBit = ROOT_BITS.Vector3
							elseif not (rootName == "vector" and memName == "create") then
								handler = nil
							end
						else
							handler = nil
						end
					else
						handler = nil
					end
				end
				local desc: FastcallDesc = {
					bfid = aRaw,
					ra = ra,
					callB = callB,
					callNresults = callNresults,
					afterCallPc = afterCallPc,
					handler = handler,
					rootBit = rootBit,
				}
				if fcInfo then
					fcInfo[ci] = desc
				else
					fcInfo = { [ci] = desc }
				end

				local inlineKind = canInlineFastcall(op, aRaw, callB, callNresults)
				if inlineKind >= 0 then
					local raEnc = if inlineKind == 1 then ra else 0
					if fcRa then
						fcRa[ci] = raEnc
					else
						fcRa = { [ci] = raEnc }
					end
					argD[ci] = afterCallPc
				end
			end
		elseif op == LOP_FASTPCALL then
			local target = ci + 1 + cRaw
			if target < 1 or target > clen then
				return nil, "jump target out of bounds"
			end
			npend += 1
			pend[npend] = target + 0x40000000
			buffer.writeu8(jTargetsBuf, target, 1)
			local callInsn = pcode[target]
			if type(callInsn) == "number" then
				local callOp = band(callInsn, 0xff)
				local ra = band(rshift(callInsn, 8), 0xff) + 1
				local callB = band(rshift(callInsn, 16), 0xff)
				local callNresults = band(rshift(callInsn, 24), 0xff) - 1
				local afterCallPc = target + (if callOp == LOP_CALLFB then 2 else 1)
				argA[ci] = aRaw
				argB[ci] = callB
				argC[ci] = callNresults
				argD[ci] = afterCallPc
				auxVal[ci] = ra
			end
		elseif isTwoWord then
			auxVal[ci] = aux
		end

		ci = nextCi
	end

	local lastOp = band(pcode[lastInsnCi], 0xff)
	if lastOp ~= LOP_RETURN and lastOp ~= LOP_JUMP and lastOp ~= LOP_JUMPBACK and lastOp ~= LOP_JUMPX then
		return nil, "proto does not terminate cleanly"
	end

	for k = 1, npend do
		local t = pend[k]
		if t < 0 then
			local callPc = -t
			if buffer.readu8(insnStartsBuf, callPc) == 0 then
				return nil, "fastcall target is not an instruction boundary"
			end
			local callOp = band(pcode[callPc], 0xff)
			if callOp ~= LOP_CALL and callOp ~= LOP_CALLFB then
				return nil, "fastcall target is not CALL"
			end
		elseif t >= 0x40000000 then
			local target = t - 0x40000000
			if buffer.readu8(insnStartsBuf, target) == 0 then
				return nil, "misaligned jump target"
			end
			local callOp = band(pcode[target], 0xff)
			if callOp ~= LOP_CALL and callOp ~= LOP_CALLFB then
				return nil, "fastpcall target is not CALL"
			end
		else
			if buffer.readu8(insnStartsBuf, t) == 0 then
				return nil, "misaligned jump target"
			end
		end
	end

	if nFuse > 0 then
		fuseCallSuperinstructions(ops, argA, fuseCands, nFuse, jTargetsBuf, clen)
	end

	return {
		code = pcode,
		ops = ops,
		argA = argA,
		argB = argB,
		argC = argC,
		argD = argD,
		fcRa = fcRa,
		auxVal = auxVal,
		fcInfo = fcInfo,
		kTypes = kTypes,
		kValues = kValues,
		baseKVals = kv,
		importIndices = importIndices,
		hasOpenTop = hasOpenTop,
	},
		nil
end

@native
local function instantiatePredecoded(
	tmpl: ProtoTemplate,
	proto: Proto,
	env: { [any]: any },
	safeRootsMask: number
): PredecodedProto
	local importIndices = tmpl.importIndices
	local kv: { [number]: any }
	local auxVal = tmpl.auxVal
	if importIndices then
		kv = table.clone(tmpl.baseKVals)
		local kValues = tmpl.kValues
		for _, ki in importIndices do
			if safeRootsMask ~= 0 then
				kv[ki] = RuntimeEnv.resolveImportConstant(proto, env, kValues[ki], safeRootsMask)
			end
		end
	else
		kv = tmpl.baseKVals
	end
	local fcRa = tmpl.fcRa
	if fcRa ~= nil then
		if safeRootsMask == ALL_SAFE_ROOTS then
			fcRa = table.clone(fcRa)
		elseif safeRootsMask == 0 then
			fcRa = nil
		else
			local fcInfo = tmpl.fcInfo
			local filtered: { [number]: number }? = nil
			if fcInfo ~= nil then
				for pcKey, raVal in fcRa do
					local fc = fcInfo[pcKey]
					local rbit = if fc then fc.rootBit else 0
					if rbit ~= 0 and band(safeRootsMask, rbit) == rbit then
						if filtered == nil then
							filtered = { [pcKey] = raVal }
						else
							filtered[pcKey] = raVal
						end
					end
				end
			end
			fcRa = filtered
		end
	end
	return {
		code = tmpl.code,
		ops = tmpl.ops,
		argA = tmpl.argA,
		argB = tmpl.argB,
		argC = tmpl.argC,
		argD = tmpl.argD,
		fcRa = fcRa,
		auxVal = auxVal,
		fcInfo = tmpl.fcInfo,
		kTypes = tmpl.kTypes,
		kValues = tmpl.kValues,
		kVals = kv,
		importIndices = importIndices,
		hasOpenTop = tmpl.hasOpenTop,
	}
end

--- Verifies binary bytecode (string or buffer) or an in-memory ProtoModule without instantiating a closure.
local function verify(input: string | buffer | ProtoModule, decoder: Types.BytecodeDecoder?): (boolean, string?)
	if
		decoder ~= nil
		and type(decoder) ~= "function"
		and not (type(decoder) == "table" and type((decoder :: any).decode) == "function")
	then
		error("invalid bytecode decoder", 2)
	end
	local t = type(input)
	if t == "string" or t == "buffer" then
		local protoMod, deserErr = BytecodeCodec.deserialize(input :: string | buffer, decoder)
		if not protoMod then
			return false, deserErr or "invalid bytecode"
		end
		local verifyErr = verifyModule(protoMod, false, decoder == nil)
		if verifyErr then
			return false, verifyErr
		end
		return true, nil
	elseif t == "table" then
		local verifyErr = verifyModule(input :: ProtoModule, false, false)
		if verifyErr then
			return false, verifyErr
		end
		return true, nil
	end
	return false, "expected bytecode string, buffer, or ProtoModule"
end

return table.freeze({
	verify = verify,
	verifyProto = verifyProto,
	verifyProtoBody = verifyProtoBody,
	verifyModule = verifyModule,
	verifyAndPredecodeProto = verifyAndPredecodeProto,
	cloneDuptableSeed = cloneDuptableSeed,
	predecodeProtoTemplate = predecodeProtoTemplate,
	instantiatePredecoded = instantiatePredecoded,
})
