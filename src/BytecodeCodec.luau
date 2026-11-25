--!strict
-- Bytecode decoding, error payload helpers, instruction unpackers, and hardened binary deserializer.
-- Upstream Luau is MIT licensed. See ../LICENSE.md and ../UPSTREAM.json.
local BytecodeDefs = require("./BytecodeDefs")
local Types = require("./Types")

local Tags = BytecodeDefs.Tags
local LBC_VERSION_MIN = Tags.LBC_VERSION_MIN
local LBC_VERSION_MAX = Tags.LBC_VERSION_MAX
local LBC_VERSION_CLASSES = Tags.LBC_VERSION_CLASSES
local LBC_TYPE_VERSION_MIN = Tags.LBC_TYPE_VERSION_MIN
local LBC_TYPE_VERSION_MAX = Tags.LBC_TYPE_VERSION_MAX

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

local FeedbackTypes = BytecodeDefs.FeedbackTypes
local LFT_CALLTARGET = FeedbackTypes.LFT_CALLTARGET
local LFT_CONSTRUCT = FeedbackTypes.LFT_CONSTRUCT
local LPF_INLINABLE = BytecodeDefs.ProtoFlags.LPF_INLINABLE
local opLengths = BytecodeDefs.opLengths

local band = bit32.band
local bor = bit32.bor
local btest = bit32.btest
local lshift = bit32.lshift
local rshift = bit32.rshift

export type Proto = Types.Proto
export type ProtoTableConstant = Types.ProtoTableConstant
export type ProtoClassConstant = Types.ProtoClassConstant
export type ProtoModule = Types.ProtoModule
export type BytecodeEncoder = Types.BytecodeEncoder
export type BytecodeDecoder = Types.BytecodeDecoder
type LocVar = { varname: string?, startpc: number, endpc: number, reg: number }

type EncoderTable = { encode: (self: any, code: { number }) -> () }
type DecoderTable = { decode: (self: any, code: { number }) -> () }

local function insnOp(insn: number): number
	return band(insn, 0xff)
end

local function insnA(insn: number): number
	return band(rshift(insn, 8), 0xff)
end

local function insnB(insn: number): number
	return band(rshift(insn, 16), 0xff)
end

local function insnC(insn: number): number
	return band(rshift(insn, 24), 0xff)
end

local function insnD(insn: number): number
	local u = rshift(insn, 16)
	return if u >= 0x8000 then u - 0x10000 else u
end

local function insnE(insn: number): number
	local u = rshift(insn, 8)
	return if u >= 0x800000 then u - 0x1000000 else u
end

--- Unpacks a 32-bit `LOP_GETIMPORT` id into `(count, id0, id1, id2)`.
local function decomposeImportId(ids: number): (number, number, number, number)
	local count = rshift(ids, 30)
	local id0 = if count > 0 then band(rshift(ids, 20), 1023) else -1
	local id1 = if count > 1 then band(rshift(ids, 10), 1023) else -1
	local id2 = if count > 2 then band(ids, 1023) else -1
	return count, id0, id1, id2
end

--- Formats a compiler/parser error message as a status-zero bytecode payload.
local function encodeError(message: string): string
	if type(message) ~= "string" then
		error("encodeError message must be a string", 2)
	end
	return "\0" .. message
end

--- Extracts the error message from a status-zero bytecode payload, or nil if bytecode does not carry status 0.
local function decodeError(bytecode: string | buffer): string?
	if type(bytecode) == "buffer" then
		local len = buffer.len(bytecode)
		if len >= 1 and buffer.readu8(bytecode, 0) == 0 then
			return buffer.readstring(bytecode, 1, len - 1)
		end
		return nil
	elseif type(bytecode) == "string" then
		if #bytecode >= 1 and string.byte(bytecode, 1) == 0 then
			return string.sub(bytecode, 2)
		end
		return nil
	end
	error("expected bytecode string or buffer", 0)
end

@native
local function readVarIntRest(buf: buffer, size: number, offset: number, result: number): (number, number)
	local shift = 7
	local byte: number
	repeat
		if offset >= size then
			error("unexpected EOF in bytecode", 0)
		end
		if shift > 28 then
			error("invalid varint in bytecode", 0)
		end
		byte = buffer.readu8(buf, offset)
		offset += 1
		local bits = if byte >= 128 then byte - 128 else byte
		if shift < 28 then
			result = bor(result, lshift(bits, shift))
		else
			if bits >= 16 then
				error("invalid varint in bytecode", 0)
			end
			result += bits * 0x10000000
		end
		shift += 7
	until byte < 128
	return result, offset
end

@native
local function readVarInt(buf: buffer, size: number, offset: number): (number, number)
	if offset >= size then
		error("unexpected EOF in bytecode", 0)
	end
	local byte = buffer.readu8(buf, offset)
	offset += 1
	if byte < 128 then
		return byte, offset
	end
	return readVarIntRest(buf, size, offset, byte - 128)
end

@native
local function skipVarInt64(buf: buffer, size: number, offset: number): number
	for i = 1, 10 do
		if offset >= size then
			error("unexpected EOF in bytecode", 0)
		end
		local byte = buffer.readu8(buf, offset)
		offset += 1
		if i == 10 and byte > 1 then
			error("invalid varint in bytecode", 0)
		end
		if byte < 128 then
			return offset
		end
	end
	error("invalid varint in bytecode", 0)
end

local function checkBound(count: number, remaining: number, stride: number?)
	local factor = stride or 1
	if count < 0 or count > remaining or count * factor > remaining then
		error("unexpected EOF in bytecode", 0)
	end
end

local function readStringById(strings: { string }, stringCount: number, id: number): string
	if id <= 0 or id > stringCount then
		error("invalid string index in bytecode", 0)
	end
	return strings[id]
end

local function readOptionalStringById(strings: { string }, stringCount: number, id: number): string?
	if id == 0 then
		return nil
	end
	if id < 0 or id > stringCount then
		error("invalid string index in bytecode", 0)
	end
	return strings[id]
end

local function hasNaNComponent(v: { number }): boolean
	return v[1] ~= v[1] or v[2] ~= v[2] or v[3] ~= v[3] or (v[4] ~= nil and v[4] ~= v[4])
end

local function validateTableKeyConstant(ktype: number, kval: any)
	if
		ktype ~= LBC_CONSTANT_BOOLEAN
		and ktype ~= LBC_CONSTANT_NUMBER
		and ktype ~= LBC_CONSTANT_STRING
		and ktype ~= LBC_CONSTANT_VECTOR
		and ktype ~= LBC_CONSTANT_VECTORD
	then
		error("invalid table constant key type in bytecode", 0)
	end
	if
		(ktype == LBC_CONSTANT_NUMBER and kval ~= kval)
		or ((ktype == LBC_CONSTANT_VECTOR or ktype == LBC_CONSTANT_VECTORD) and hasNaNComponent(kval))
	then
		error("table constant key cannot be NaN", 0)
	end
end

local function deferStringRef(deferred: { number }?, idx: number, sizek: number): { number }
	if idx < 0 or idx >= sizek then
		error("invalid string constant reference in bytecode", 0)
	end
	if deferred then
		deferred[#deferred + 1] = idx
		return deferred
	end
	return { idx }
end

@native
local function readProtoConstants(
	buf: buffer,
	size: number,
	offset: number,
	strings: { string },
	stringCount: number,
	sizek: number,
	protoId: number
): ({ number }, { any }, number)
	checkBound(sizek, size - offset)
	local kTypes: { number } = table.create(sizek, 0) :: { number }
	local kValues: { any } = table.create(sizek) :: { any }
	local deferredStringCheck: { number }? = nil
	for j = 1, sizek do
		if offset >= size then
			error("unexpected EOF in bytecode", 0)
		end
		local ktag = buffer.readu8(buf, offset)
		offset += 1
		kTypes[j] = ktag
		if ktag == LBC_CONSTANT_NIL then
			kValues[j] = nil
		elseif ktag == LBC_CONSTANT_BOOLEAN then
			if offset >= size then
				error("unexpected EOF in bytecode", 0)
			end
			local b = buffer.readu8(buf, offset)
			offset += 1
			kValues[j] = b ~= 0
		elseif ktag == LBC_CONSTANT_NUMBER then
			if offset + 8 > size then
				error("unexpected EOF in bytecode", 0)
			end
			kValues[j] = buffer.readf64(buf, offset)
			offset += 8
		elseif ktag == LBC_CONSTANT_VECTOR then
			if offset + 16 > size then
				error("unexpected EOF in bytecode", 0)
			end
			local vec = {
				buffer.readf32(buf, offset),
				buffer.readf32(buf, offset + 4),
				buffer.readf32(buf, offset + 8),
				buffer.readf32(buf, offset + 12),
			}
			offset += 16
			table.freeze(vec)
			kValues[j] = vec
		elseif ktag == LBC_CONSTANT_VECTORD then
			if offset + 32 > size then
				error("unexpected EOF in bytecode", 0)
			end
			local vec = {
				buffer.readf64(buf, offset),
				buffer.readf64(buf, offset + 8),
				buffer.readf64(buf, offset + 16),
				buffer.readf64(buf, offset + 24),
			}
			offset += 32
			table.freeze(vec)
			kValues[j] = vec
		elseif ktag == LBC_CONSTANT_STRING then
			local id: number
			id, offset = readVarInt(buf, size, offset)
			kValues[j] = readStringById(strings, stringCount, id)
		elseif ktag == LBC_CONSTANT_IMPORT then
			if offset + 4 > size then
				error("unexpected EOF in bytecode", 0)
			end
			local iid = buffer.readu32(buf, offset)
			offset += 4
			local icount, id0, id1, id2 = decomposeImportId(iid)
			if icount < 1 or icount > 3 then
				error("invalid import constant count in bytecode", 0)
			end
			deferredStringCheck = deferStringRef(deferredStringCheck, id0, sizek)
			if icount >= 2 then
				deferredStringCheck = deferStringRef(deferredStringCheck, id1, sizek)
			end
			if icount >= 3 then
				deferredStringCheck = deferStringRef(deferredStringCheck, id2, sizek)
			end
			kValues[j] = iid
		elseif ktag == LBC_CONSTANT_TABLE then
			local keysCount: number
			keysCount, offset = readVarInt(buf, size, offset)
			checkBound(keysCount, size - offset)
			local keys = table.create(keysCount)
			for m = 1, keysCount do
				local kid: number
				kid, offset = readVarInt(buf, size, offset)
				if kid < 0 or kid >= j - 1 then
					error("invalid table constant key index in bytecode", 0)
				end
				validateTableKeyConstant(kTypes[kid + 1], kValues[kid + 1])
				keys[m] = kid
			end
			table.freeze(keys)
			kValues[j] = table.freeze({ keys = keys, length = keysCount })
		elseif ktag == LBC_CONSTANT_TABLE_WITH_CONSTANTS then
			local keysCount: number
			keysCount, offset = readVarInt(buf, size, offset)
			checkBound(keysCount, size - offset, 5)
			local keys = table.create(keysCount)
			local constants = table.create(keysCount)
			for m = 1, keysCount do
				local kid: number
				kid, offset = readVarInt(buf, size, offset)
				if kid < 0 or kid >= j - 1 then
					error("invalid table constant key index in bytecode", 0)
				end
				validateTableKeyConstant(kTypes[kid + 1], kValues[kid + 1])
				keys[m] = kid
				if offset + 4 > size then
					error("unexpected EOF in bytecode", 0)
				end
				local cidx = buffer.readi32(buf, offset)
				offset += 4
				if cidx < -1 or cidx >= j - 1 then
					error("invalid table constant value index in bytecode", 0)
				end
				if cidx >= 0 then
					local vtype = kTypes[cidx + 1]
					if
						vtype == LBC_CONSTANT_TABLE
						or vtype == LBC_CONSTANT_TABLE_WITH_CONSTANTS
						or vtype == LBC_CONSTANT_CLOSURE
						or vtype == LBC_CONSTANT_CLASS_SHAPE
						or vtype == LBC_CONSTANT_IMPORT
					then
						error("invalid table constant value type in bytecode", 0)
					end
				end
				constants[m] = cidx
			end
			table.freeze(keys)
			table.freeze(constants)
			kValues[j] = table.freeze({ keys = keys, constants = constants, length = keysCount })
		elseif ktag == LBC_CONSTANT_CLOSURE then
			local fid: number
			fid, offset = readVarInt(buf, size, offset)
			if fid < 0 or fid >= protoId then
				error("invalid closure constant proto id in bytecode", 0)
			end
			kValues[j] = fid
		elseif ktag == LBC_CONSTANT_CLASS_SHAPE then
			local cnid: number
			local numProperties: number
			local numMethods: number
			cnid, offset = readVarInt(buf, size, offset)
			deferredStringCheck = deferStringRef(deferredStringCheck, cnid, sizek)
			if offset + 2 > size then
				error("unexpected EOF in bytecode", 0)
			end
			local numPrivateInstanceProps = buffer.readu8(buf, offset)
			local numPrivateStaticProps = buffer.readu8(buf, offset + 1)
			offset += 2
			numProperties, offset = readVarInt(buf, size, offset)
			numMethods, offset = readVarInt(buf, size, offset)
			if numProperties < numPrivateInstanceProps or numMethods < numPrivateStaticProps then
				error("invalid class shape private member count", 0)
			end
			local numPublicProps = numProperties - numPrivateInstanceProps
			local numPublicMethods = numMethods - numPrivateStaticProps
			checkBound(numPublicProps + numPublicMethods, size - offset)
			local propNames = table.create(numPublicProps)
			local methodNames = table.create(numPublicMethods)
			for m = 1, numPublicProps do
				local pid: number
				pid, offset = readVarInt(buf, size, offset)
				deferredStringCheck = deferStringRef(deferredStringCheck, pid, sizek)
				propNames[m] = pid
			end
			for m = 1, numPublicMethods do
				local mid: number
				mid, offset = readVarInt(buf, size, offset)
				deferredStringCheck = deferStringRef(deferredStringCheck, mid, sizek)
				methodNames[m] = mid
			end
			table.freeze(propNames)
			table.freeze(methodNames)
			kValues[j] = table.freeze({
				className = cnid,
				numPrivateInstanceProps = numPrivateInstanceProps,
				numPrivateStaticProps = numPrivateStaticProps,
				propertyNames = propNames,
				methodNames = methodNames,
			})
		else
			error("Unexpected constant kind: " .. tostring(ktag), 0)
		end
	end
	if deferredStringCheck then
		for _, strConstId in deferredStringCheck do
			if kTypes[strConstId + 1] ~= LBC_CONSTANT_STRING then
				error("expected string constant reference in bytecode", 0)
			end
		end
	end
	table.freeze(kTypes)
	table.freeze(kValues)
	return kTypes, kValues, offset
end

@native
local function decodeLineInfoUnchecked(
	buf: buffer,
	offset: number,
	sizecode: number,
	gap: number
): ({ number }, { number }, number)
	local intervals = if sizecode > 0 then rshift(sizecode - 1, gap) + 1 else 0
	local linfo: { number } = table.create(sizecode) :: { number }
	local lastoffset = 0
	for j = 1, sizecode do
		local s = lastoffset + buffer.readu8(buf, offset)
		offset += 1
		lastoffset = if s >= 256 then s - 256 else s
		linfo[j] = lastoffset
	end
	local absinfo: { number } = table.create(intervals) :: { number }
	local lastline = 0
	for j = 1, intervals do
		lastline += buffer.readi32(buf, offset)
		offset += 4
		absinfo[j] = lastline
	end
	return linfo, absinfo, offset
end

local function decodeLineInfo(proto: Proto): ({ number }?, { number }?)
	if type(proto) ~= "table" then
		error("decodeLineInfo expected a Proto table", 2)
	end
	if type(proto.code) ~= "table" then
		error("invalid lineinfo bounds in bytecode", 0)
	end
	local lineData = proto.lineData
	if lineData == nil then
		return nil, nil
	end
	local gap = proto.linegaplog2
	if type(lineData) ~= "string" or type(gap) ~= "number" or math.floor(gap) ~= gap or gap < 0 or gap > 31 then
		error("invalid lineinfo bounds in bytecode", 0)
	end
	local sizecode = #proto.code
	local intervals = if sizecode > 0 then rshift(sizecode - 1, gap) + 1 else 0
	if #lineData ~= sizecode + intervals * 4 then
		error("invalid lineinfo bounds in bytecode", 0)
	end
	local buf = buffer.fromstring(lineData)
	local linfo, absinfo = decodeLineInfoUnchecked(buf, 0, sizecode, gap)
	return linfo, absinfo
end

@native
local function readProtoLineAndDebugInfo(
	buf: buffer,
	size: number,
	offset: number,
	strings: { string },
	stringCount: number,
	sizecode: number,
	nups: number
): (string?, number?, { LocVar }?, { string? }?, number)
	if offset >= size then
		error("unexpected EOF in bytecode", 0)
	end
	local hasLineInfo = buffer.readu8(buf, offset) ~= 0
	offset += 1
	local lineData: string? = nil
	local linegaplog2: number? = nil

	if hasLineInfo then
		if offset >= size then
			error("unexpected EOF in bytecode", 0)
		end
		local gap = buffer.readu8(buf, offset)
		offset += 1
		if gap > 31 then
			error("invalid lineinfo gap in bytecode", 0)
		end
		linegaplog2 = gap
		local intervals = if sizecode > 0 then rshift(sizecode - 1, gap) + 1 else 0
		if sizecode > size - offset or intervals * 4 > size - offset - sizecode then
			error("unexpected EOF in bytecode", 0)
		end
		local lineBytes = sizecode + intervals * 4
		lineData = buffer.readstring(buf, offset, lineBytes)
		offset += lineBytes
	end

	if offset >= size then
		error("unexpected EOF in bytecode", 0)
	end
	local hasDebugInfo = buffer.readu8(buf, offset) ~= 0
	offset += 1
	local locvars: { { varname: string?, startpc: number, endpc: number, reg: number } }? = nil
	local upvalues: { string? }? = nil

	if hasDebugInfo then
		local sizelocvars: number
		sizelocvars, offset = readVarInt(buf, size, offset)
		checkBound(sizelocvars, size - offset, 4)
		local lvars: { LocVar } = table.create(sizelocvars) :: { LocVar }
		for j = 1, sizelocvars do
			local nameId: number, startpc: number, endpc: number
			nameId, offset = readVarInt(buf, size, offset)
			startpc, offset = readVarInt(buf, size, offset)
			endpc, offset = readVarInt(buf, size, offset)
			if offset >= size then
				error("unexpected EOF in bytecode", 0)
			end
			local reg = buffer.readu8(buf, offset)
			offset += 1
			local item = {
				varname = readOptionalStringById(strings, stringCount, nameId),
				startpc = startpc,
				endpc = endpc,
				reg = reg,
			}
			table.freeze(item)
			lvars[j] = item :: any
		end
		table.freeze(lvars)
		locvars = lvars

		local sizeupvalues: number
		sizeupvalues, offset = readVarInt(buf, size, offset)
		if sizeupvalues ~= nups then
			error("invalid upvalue count in bytecode", 0)
		end
		checkBound(sizeupvalues, size - offset)
		local uvals: { string? } = table.create(sizeupvalues) :: { string? }
		for j = 1, sizeupvalues do
			local uid: number
			uid, offset = readVarInt(buf, size, offset)
			uvals[j] = readOptionalStringById(strings, stringCount, uid)
		end
		table.freeze(uvals)
		upvalues = uvals
	end

	return lineData, linegaplog2, locvars, upvalues, offset
end

@native
local function decodeProtoCode(code: { number }, sizecode: number, decoder: BytecodeDecoder)
	if type(decoder) == "function" then
		local decodeFn: (number) -> number = decoder
		local j = 1
		while j <= sizecode do
			local insn = code[j]
			local decOp = decodeFn(band(insn, 0xff))
			if
				type(decOp) ~= "number"
				or decOp < 0
				or decOp > 255
				or math.floor(decOp) ~= decOp
				or opLengths[decOp] == nil
			then
				error("invalid decoded opcode in bytecode", 0)
			end
			code[j] = bor(band(insn, 0xffffff00), decOp)
			j += opLengths[decOp]
		end
	elseif type(decoder) == "table" and type((decoder :: DecoderTable).decode) == "function" then
		(decoder :: DecoderTable):decode(code)
	else
		error("invalid bytecode decoder", 0)
	end
end

@native
local function readProto(
	buf: buffer,
	size: number,
	offset: number,
	strings: { string },
	stringCount: number,
	protoId: number,
	protoCount: number,
	version: number,
	typesversion: number,
	decoder: BytecodeDecoder?
): (Proto, number)
	local protoSize = 0
	if version >= 12 then
		protoSize, offset = readVarInt(buf, size, offset)
	end
	local protoStartOffset = offset

	if offset + 4 > size then
		error("unexpected EOF in bytecode", 0)
	end
	local maxstacksize = buffer.readu8(buf, offset)
	local numparams = buffer.readu8(buf, offset + 1)
	if numparams > maxstacksize then
		error("invalid numparams in bytecode", 0)
	end
	local nups = buffer.readu8(buf, offset + 2)
	local is_vararg = buffer.readu8(buf, offset + 3) ~= 0
	offset += 4
	local flags = 0
	local typeinfo: string? = nil

	if version >= 4 then
		if offset >= size then
			error("unexpected EOF in bytecode", 0)
		end
		flags = buffer.readu8(buf, offset)
		offset += 1
		if typesversion == 1 or typesversion == 2 or typesversion == 3 then
			local typesize: number
			typesize, offset = readVarInt(buf, size, offset)
			if typesize > 0 then
				if typesize > size - offset then
					error("unexpected EOF in typeinfo", 0)
				end
				typeinfo = buffer.readstring(buf, offset, typesize)
				offset += typesize
			end
		end
	end

	local sizecode: number
	sizecode, offset = readVarInt(buf, size, offset)
	checkBound(sizecode, size - offset, 4)
	local code: { number } = table.create(sizecode) :: { number }
	for j = 1, sizecode do
		code[j] = buffer.readu32(buf, offset)
		offset += 4
	end
	if decoder ~= nil then
		decodeProtoCode(code, sizecode, decoder)
	end
	table.freeze(code)

	local sizek: number
	sizek, offset = readVarInt(buf, size, offset)
	local kTypes: { number }, kValues: { any }
	kTypes, kValues, offset = readProtoConstants(buf, size, offset, strings, stringCount, sizek, protoId)

	local sizep: number
	sizep, offset = readVarInt(buf, size, offset)
	checkBound(sizep, size - offset)
	local p: { number } = table.create(sizep) :: { number }
	for j = 1, sizep do
		local pid: number
		pid, offset = readVarInt(buf, size, offset)
		if pid < 0 or pid >= protoId then
			error("invalid child proto id in bytecode", 0)
		end
		p[j] = pid
	end
	table.freeze(p)

	local linedefined: number
	linedefined, offset = readVarInt(buf, size, offset)
	local debugnameId: number
	debugnameId, offset = readVarInt(buf, size, offset)
	local debugname = readOptionalStringById(strings, stringCount, debugnameId)

	local lineData: string?, linegaplog2: number?, locvars: { { varname: string?, startpc: number, endpc: number, reg: number } }?, upvalues: { string? }?
	lineData, linegaplog2, locvars, upvalues, offset =
		readProtoLineAndDebugInfo(buf, size, offset, strings, stringCount, sizecode, nups)

	if version >= 12 and protoStartOffset + protoSize < offset then
		error("invalid proto size in bytecode", 0)
	end

	if version >= 11 then
		local feedbackvecsize: number
		feedbackvecsize, offset = readVarInt(buf, size, offset)
		checkBound(feedbackvecsize, size - offset)
		for _ = 1, feedbackvecsize do
			if offset >= size then
				error("unexpected EOF in bytecode", 0)
			end
			local slottype = buffer.readu8(buf, offset)
			offset += 1
			if slottype == LFT_CALLTARGET or slottype == LFT_CONSTRUCT then
				local _: number
				_, offset = readVarInt(buf, size, offset)
			else
				error("invalid feedback slot type in bytecode", 0)
			end
		end
	end

	if version >= 12 then
		if btest(flags, LPF_INLINABLE) then
			offset = skipVarInt64(buf, size, offset)
		end
		local protoEnd = protoStartOffset + protoSize
		if protoEnd < offset then
			error("invalid proto size in bytecode", 0)
		end
		if protoEnd > size then
			error("unexpected EOF in bytecode", 0)
		end
		offset = protoEnd
	end

	local proto: Proto = table.freeze({
		id = protoId,
		maxstacksize = maxstacksize,
		numparams = numparams,
		nups = nups,
		isvararg = is_vararg,
		flags = flags,
		code = code,
		kTypes = kTypes,
		kValues = kValues,
		p = p,
		linedefined = linedefined,
		debugname = debugname,
		lineData = lineData,
		linegaplog2 = linegaplog2,
		locvars = locvars,
		upvalues = upvalues,
		typeinfo = typeinfo,
	}) :: Proto
	return proto, offset
end

local function readHeaderVersions(buf: buffer, size: number, offset: number): (number, number, number)
	if offset >= size then
		error("unexpected EOF in bytecode", 0)
	end
	local version = buffer.readu8(buf, offset)
	offset += 1
	if version == 0 then
		local errMsg = buffer.readstring(buf, offset, size - offset)
		error(errMsg, 0)
	end

	if (version < LBC_VERSION_MIN or version > LBC_VERSION_MAX) and version ~= LBC_VERSION_CLASSES then
		error(
			string.format(
				"bytecode version mismatch (expected [%d..%d], got %d)",
				LBC_VERSION_MIN,
				LBC_VERSION_MAX,
				version
			),
			0
		)
	end

	local typesversion = 0
	if version >= 4 then
		if offset >= size then
			error("unexpected EOF in bytecode", 0)
		end
		typesversion = buffer.readu8(buf, offset)
		offset += 1
		if typesversion < LBC_TYPE_VERSION_MIN or typesversion > LBC_TYPE_VERSION_MAX then
			error(
				string.format(
					"bytecode type version mismatch (expected [%d..%d], got %d)",
					LBC_TYPE_VERSION_MIN,
					LBC_TYPE_VERSION_MAX,
					typesversion
				),
				0
			)
		end
	end
	return version, typesversion, offset
end

@native
local function deserializeInternal(data: string | buffer, decoder: BytecodeDecoder?): ProtoModule
	if
		decoder ~= nil
		and type(decoder) ~= "function"
		and not (type(decoder) == "table" and type((decoder :: DecoderTable).decode) == "function")
	then
		error("invalid bytecode decoder", 0)
	end
	local buf: buffer
	local size: number
	if type(data) == "string" then
		size = #data
		buf = buffer.fromstring(data)
	elseif type(data) == "buffer" then
		buf = data
		size = buffer.len(buf)
	else
		error("expected bytecode string or buffer", 0)
	end

	if size < 1 then
		error("empty bytecode", 0)
	end

	local version: number, typesversion: number, offset: number = readHeaderVersions(buf, size, 0)

	local stringCount: number
	stringCount, offset = readVarInt(buf, size, offset)
	checkBound(stringCount, size - offset)
	local strings: { string } = table.create(stringCount) :: { string }
	for i = 1, stringCount do
		local len: number
		if offset >= size then
			error("unexpected EOF in bytecode", 0)
		end
		local b0 = buffer.readu8(buf, offset)
		offset += 1
		if b0 < 128 then
			len = b0
		else
			len, offset = readVarIntRest(buf, size, offset, b0 - 128)
		end
		if len > size - offset then
			error("unexpected EOF in string table", 0)
		end
		strings[i] = buffer.readstring(buf, offset, len)
		offset += len
	end
	table.freeze(strings)

	local userdataTypes: { string }? = nil
	if typesversion == 3 then
		if offset >= size then
			error("unexpected EOF in bytecode", 0)
		end
		local maxUdIndex = BytecodeDefs.Types.LBC_TYPE_TAGGED_USERDATA_END
			- BytecodeDefs.Types.LBC_TYPE_TAGGED_USERDATA_BASE
		local index = buffer.readu8(buf, offset)
		offset += 1
		if index ~= 0 then
			local udList: { string } = {}
			while index ~= 0 do
				if index < 1 or index > maxUdIndex then
					error("invalid userdata type index in bytecode", 0)
				end
				local nameId: number
				nameId, offset = readVarInt(buf, size, offset)
				if nameId == 0 then
					error("invalid userdata type name index in bytecode", 0)
				end
				udList[index] = readStringById(strings, stringCount, nameId)
				if offset >= size then
					error("unexpected EOF in bytecode", 0)
				end
				index = buffer.readu8(buf, offset)
				offset += 1
			end
			if next(udList) ~= nil then
				table.freeze(udList)
				userdataTypes = udList
			end
		end
	end

	local protoCount: number
	protoCount, offset = readVarInt(buf, size, offset)
	checkBound(protoCount, size - offset)
	local protos: { Proto } = table.create(protoCount) :: { Proto }
	for i = 1, protoCount do
		local proto: Proto
		proto, offset =
			readProto(buf, size, offset, strings, stringCount, i - 1, protoCount, version, typesversion, decoder)
		protos[i] = proto
	end
	table.freeze(protos)

	local mainid: number
	mainid, offset = readVarInt(buf, size, offset)
	if mainid < 0 or mainid >= protoCount then
		error("invalid main proto id", 0)
	end
	if offset ~= size then
		error("trailing data in bytecode", 0)
	end

	return (
		table.freeze({
			version = version,
			typesversion = typesversion,
			strings = strings,
			protos = protos,
			mainid = mainid,
			userdataTypes = userdataTypes,
		}) :: any
	) :: ProtoModule
end

@native
local function writeVarIntSize(v: number): number
	local value = if v < 0 then v + 0x100000000 else v
	if value < 0x80 then
		return 1
	elseif value < 0x4000 then
		return 2
	elseif value < 0x200000 then
		return 3
	elseif value < 0x10000000 then
		return 4
	else
		return 5
	end
end

@native
local function writeVarIntToBuf(buf: buffer, pos: number, v: number): number
	local value = if v < 0 then v + 0x100000000 else v
	repeat
		local b = band(value, 127)
		value = rshift(value, 7)
		if value > 0 then
			b = bor(b, 128)
		end
		buffer.writeu8(buf, pos, b)
		pos += 1
	until value == 0
	return pos
end

type CodecWriter = {
	buf: buffer,
	offset: number,
	cap: number,
}

@native
local function ensureCodecWriter(w: CodecWriter, extra: number)
	local pos = w.offset
	local cap = w.cap
	if pos + extra > cap then
		while pos + extra > cap do
			cap *= 2
		end
		local nextBuf = buffer.create(cap)
		buffer.copy(nextBuf, 0, w.buf, 0, pos)
		w.buf = nextBuf
		w.cap = cap
	end
end

local function checkUintRange(v: any, maxVal: number, errMsg: string): number
	if type(v) ~= "number" or v < 0 or v > maxVal or math.floor(v) ~= v then
		error(errMsg, 0)
	end
	return v
end

local function internCodecString(strings: { string }, stringToId: { [string]: number }, str: string): number
	local id = stringToId[str]
	if id ~= nil then
		return id
	end
	local nextId = #strings + 1
	strings[nextId] = str
	stringToId[str] = nextId
	return nextId
end

local function validateAndInternOptionalString(
	strings: { string },
	stringToId: { [string]: number },
	val: any,
	errMsg: string
): number
	if val == nil then
		return 0
	end
	if type(val) ~= "string" then
		error(errMsg, 0)
	end
	if #val == 0 then
		return 0
	end
	return internCodecString(strings, stringToId, val)
end

local function checkProtoStringRef(kTypes: { number }, sizek: number, idx: any, errMsg: string): number
	if type(idx) ~= "number" or idx < 0 or idx >= sizek or math.floor(idx) ~= idx then
		error(errMsg, 0)
	end
	if kTypes[idx + 1] ~= LBC_CONSTANT_STRING then
		error("expected string constant reference in ProtoModule", 0)
	end
	return idx
end

local function writeProtoCode(w: CodecWriter, code: { number }, sizecode: number, encoder: BytecodeEncoder?)
	ensureCodecWriter(w, 5 + sizecode * 4)
	local pos = writeVarIntToBuf(w.buf, w.offset, sizecode)
	if sizecode == 0 then
		w.offset = pos
		return
	end
	local buf = w.buf
	if encoder == nil then
		for j = 1, sizecode do
			local insn = checkUintRange(code[j], 0xffffffff, "invalid instruction in Proto.code")
			buffer.writeu32(buf, pos, insn)
			pos += 4
		end
	elseif type(encoder) == "function" then
		local encodeFn: (number) -> number = encoder
		local j = 1
		while j <= sizecode do
			local insn = checkUintRange(code[j], 0xffffffff, "invalid instruction in Proto.code")
			local op = band(insn, 0xff)
			local opLen = opLengths[op]
			if opLen == nil then
				error("invalid opcode in Proto.code", 0)
			end
			local encOp = encodeFn(op)
			if type(encOp) ~= "number" or encOp ~= math.floor(encOp) then
				error("invalid encoded opcode in Proto.code", 0)
			end
			buffer.writeu32(buf, pos, bor(band(insn, 0xffffff00), band(encOp, 0xff)))
			pos += 4
			for extra = 1, opLen - 1 do
				local idx = j + extra
				if idx > sizecode then
					error("truncated multi-word instruction in Proto.code", 0)
				end
				local aux = checkUintRange(code[idx], 0xffffffff, "invalid aux word in Proto.code")
				buffer.writeu32(buf, pos, aux)
				pos += 4
			end
			j += opLen
		end
	else
		local copy = table.create(sizecode, 0)
		for j = 1, sizecode do
			copy[j] = checkUintRange(code[j], 0xffffffff, "invalid instruction in Proto.code")
		end
		(encoder :: EncoderTable):encode(copy)
		for j = 1, sizecode do
			local insn = checkUintRange(copy[j], 0xffffffff, "invalid encoded instruction in Proto.code")
			buffer.writeu32(buf, pos, insn)
			pos += 4
		end
	end
	w.offset = pos
end

local function writeProtoConstants(
	w: CodecWriter,
	kTypes: { number },
	kValues: { any },
	strings: { string },
	stringToId: { [string]: number },
	protoId: number
)
	local sizek = #kTypes
	ensureCodecWriter(w, 5 + sizek * 10)
	local buf = w.buf
	local cap = w.cap
	local pos = writeVarIntToBuf(buf, w.offset, sizek)
	for j = 1, sizek do
		if pos + 36 > cap then
			w.offset = pos
			ensureCodecWriter(w, 36)
			buf = w.buf
			cap = w.cap
		end
		local ktag = kTypes[j]
		local kval = kValues[j]
		if ktag == LBC_CONSTANT_NIL then
			buffer.writeu8(buf, pos, ktag)
			pos += 1
		elseif ktag == LBC_CONSTANT_BOOLEAN then
			if type(kval) ~= "boolean" then
				error("invalid boolean constant in ProtoModule", 0)
			end
			buffer.writeu8(buf, pos, ktag)
			buffer.writeu8(buf, pos + 1, if kval then 1 else 0)
			pos += 2
		elseif ktag == LBC_CONSTANT_NUMBER then
			if type(kval) ~= "number" then
				error("invalid number constant in ProtoModule", 0)
			end
			buffer.writeu8(buf, pos, ktag)
			buffer.writef64(buf, pos + 1, kval)
			pos += 9
		elseif ktag == LBC_CONSTANT_VECTOR then
			if type(kval) ~= "table" then
				error("invalid vector constant in ProtoModule", 0)
			end
			local x, y, z, wv = kval[1], kval[2], kval[3], if kval[4] ~= nil then kval[4] else 0
			if type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" or type(wv) ~= "number" then
				error("invalid vector component in ProtoModule", 0)
			end
			buffer.writeu8(buf, pos, ktag)
			buffer.writef32(buf, pos + 1, x)
			buffer.writef32(buf, pos + 5, y)
			buffer.writef32(buf, pos + 9, z)
			buffer.writef32(buf, pos + 13, wv)
			pos += 17
		elseif ktag == LBC_CONSTANT_VECTORD then
			if type(kval) ~= "table" then
				error("invalid vectord constant in ProtoModule", 0)
			end
			local x, y, z, wv = kval[1], kval[2], kval[3], if kval[4] ~= nil then kval[4] else 0
			if type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" or type(wv) ~= "number" then
				error("invalid vectord component in ProtoModule", 0)
			end
			buffer.writeu8(buf, pos, ktag)
			buffer.writef64(buf, pos + 1, x)
			buffer.writef64(buf, pos + 9, y)
			buffer.writef64(buf, pos + 17, z)
			buffer.writef64(buf, pos + 25, wv)
			pos += 33
		elseif ktag == LBC_CONSTANT_STRING then
			if type(kval) ~= "string" then
				error("invalid string constant in ProtoModule", 0)
			end
			local strId = internCodecString(strings, stringToId, kval)
			buffer.writeu8(buf, pos, ktag)
			pos = writeVarIntToBuf(buf, pos + 1, strId)
		elseif ktag == LBC_CONSTANT_IMPORT then
			local iid = checkUintRange(kval, 0xffffffff, "invalid import constant in ProtoModule")
			local icount, id0, id1, id2 = decomposeImportId(iid)
			if icount < 1 or icount > 3 then
				error("invalid import constant count in ProtoModule", 0)
			end
			checkProtoStringRef(kTypes, sizek, id0, "invalid import string constant reference in ProtoModule")
			if icount >= 2 then
				checkProtoStringRef(kTypes, sizek, id1, "invalid import string constant reference in ProtoModule")
			end
			if icount >= 3 then
				checkProtoStringRef(kTypes, sizek, id2, "invalid import string constant reference in ProtoModule")
			end
			buffer.writeu8(buf, pos, ktag)
			buffer.writeu32(buf, pos + 1, iid)
			pos += 5
		elseif ktag == LBC_CONSTANT_TABLE then
			if type(kval) ~= "table" or type(kval.keys) ~= "table" then
				error("invalid table constant in ProtoModule", 0)
			end
			local keys = kval.keys
			local len = if kval.length ~= nil
				then checkUintRange(kval.length, #keys, "invalid table constant length")
				else #keys
			local need = 6 + len * 5
			if pos + need > cap then
				w.offset = pos
				ensureCodecWriter(w, need)
				buf = w.buf
				cap = w.cap
			end
			buffer.writeu8(buf, pos, ktag)
			pos = writeVarIntToBuf(buf, pos + 1, len)
			for m = 1, len do
				local kid = checkUintRange(keys[m], j - 2, "invalid table constant key index in ProtoModule")
				validateTableKeyConstant(kTypes[kid + 1], kValues[kid + 1])
				pos = writeVarIntToBuf(buf, pos, kid)
			end
		elseif ktag == LBC_CONSTANT_TABLE_WITH_CONSTANTS then
			if type(kval) ~= "table" or type(kval.keys) ~= "table" or type(kval.constants) ~= "table" then
				error("invalid table_with_constants in ProtoModule", 0)
			end
			local keys = kval.keys
			local consts = kval.constants
			local len = if kval.length ~= nil
				then checkUintRange(kval.length, math.min(#keys, #consts), "invalid table constant length")
				else math.min(#keys, #consts)
			local need = 6 + len * 9
			if pos + need > cap then
				w.offset = pos
				ensureCodecWriter(w, need)
				buf = w.buf
				cap = w.cap
			end
			buffer.writeu8(buf, pos, ktag)
			pos = writeVarIntToBuf(buf, pos + 1, len)
			for m = 1, len do
				local kid = checkUintRange(keys[m], j - 2, "invalid table constant key index in ProtoModule")
				validateTableKeyConstant(kTypes[kid + 1], kValues[kid + 1])
				local cidx = consts[m]
				if type(cidx) ~= "number" or math.floor(cidx) ~= cidx or cidx < -1 or cidx >= j - 1 then
					error("invalid table constant value index in ProtoModule", 0)
				end
				if cidx >= 0 then
					local vtype = kTypes[cidx + 1]
					if
						vtype == LBC_CONSTANT_TABLE
						or vtype == LBC_CONSTANT_TABLE_WITH_CONSTANTS
						or vtype == LBC_CONSTANT_CLOSURE
						or vtype == LBC_CONSTANT_CLASS_SHAPE
						or vtype == LBC_CONSTANT_IMPORT
					then
						error("invalid table constant value type in ProtoModule", 0)
					end
				end
				pos = writeVarIntToBuf(buf, pos, kid)
				buffer.writei32(buf, pos, cidx)
				pos += 4
			end
		elseif ktag == LBC_CONSTANT_CLOSURE then
			local fid = checkUintRange(kval, protoId - 1, "invalid closure constant proto id in ProtoModule")
			buffer.writeu8(buf, pos, ktag)
			pos = writeVarIntToBuf(buf, pos + 1, fid)
		elseif ktag == LBC_CONSTANT_CLASS_SHAPE then
			if type(kval) ~= "table" or type(kval.propertyNames) ~= "table" or type(kval.methodNames) ~= "table" then
				error("invalid class shape constant in ProtoModule", 0)
			end
			local cnid =
				checkProtoStringRef(kTypes, sizek, kval.className, "invalid class name reference in ProtoModule")
			local numPrivInst = checkUintRange(
				if kval.numPrivateInstanceProps ~= nil then kval.numPrivateInstanceProps else 0,
				255,
				"invalid private instance property count in ProtoModule"
			)
			local numPrivStat = checkUintRange(
				if kval.numPrivateStaticProps ~= nil then kval.numPrivateStaticProps else 0,
				255,
				"invalid private static method count in ProtoModule"
			)
			local props = kval.propertyNames
			local methods = kval.methodNames
			local need = 18 + (#props + #methods) * 5
			if pos + need > cap then
				w.offset = pos
				ensureCodecWriter(w, need)
				buf = w.buf
				cap = w.cap
			end
			buffer.writeu8(buf, pos, ktag)
			pos = writeVarIntToBuf(buf, pos + 1, cnid)
			buffer.writeu8(buf, pos, numPrivInst)
			buffer.writeu8(buf, pos + 1, numPrivStat)
			pos = writeVarIntToBuf(buf, pos + 2, #props + numPrivInst)
			pos = writeVarIntToBuf(buf, pos, #methods + numPrivStat)
			for m = 1, #props do
				local pid =
					checkProtoStringRef(kTypes, sizek, props[m], "invalid class property reference in ProtoModule")
				pos = writeVarIntToBuf(buf, pos, pid)
			end
			for m = 1, #methods do
				local mid =
					checkProtoStringRef(kTypes, sizek, methods[m], "invalid class method reference in ProtoModule")
				pos = writeVarIntToBuf(buf, pos, mid)
			end
		else
			error("Unexpected constant kind: " .. tostring(ktag), 0)
		end
	end
	w.offset = pos
end

local function writeProtoBody(
	w: CodecWriter,
	proto: Proto,
	protoId: number,
	version: number,
	typesversion: number,
	strings: { string },
	stringToId: { [string]: number },
	encoder: BytecodeEncoder?
): (number, number)
	if type(proto) ~= "table" then
		error("invalid proto in ProtoModule", 0)
	end
	if proto.id ~= nil then
		checkUintRange(proto.id, protoId, "invalid proto id in ProtoModule")
		if proto.id ~= protoId then
			error("invalid proto id in ProtoModule", 0)
		end
	end
	local maxstacksize = checkUintRange(proto.maxstacksize, 255, "invalid maxstacksize in ProtoModule")
	local numparams = checkUintRange(proto.numparams, 255, "invalid numparams in ProtoModule")
	if numparams > maxstacksize then
		error("invalid numparams in ProtoModule", 0)
	end
	local nups = checkUintRange(proto.nups, 255, "invalid nups in ProtoModule")
	if type(proto.isvararg) ~= "boolean" then
		error("invalid isvararg in ProtoModule", 0)
	end
	local flags = 0
	if version >= 4 then
		flags = checkUintRange(if proto.flags ~= nil then proto.flags else 0, 255, "invalid proto flags in ProtoModule")
	end

	local startOffset = w.offset
	ensureCodecWriter(w, 5)
	local hbuf = w.buf
	buffer.writeu8(hbuf, startOffset, maxstacksize)
	buffer.writeu8(hbuf, startOffset + 1, numparams)
	buffer.writeu8(hbuf, startOffset + 2, nups)
	buffer.writeu8(hbuf, startOffset + 3, if proto.isvararg then 1 else 0)
	local hpos = startOffset + 4
	if version >= 4 then
		buffer.writeu8(hbuf, hpos, flags)
		hpos += 1
	end
	w.offset = hpos

	if version >= 4 and (typesversion == 1 or typesversion == 2 or typesversion == 3) then
		local typeinfo = proto.typeinfo
		if typeinfo ~= nil then
			if type(typeinfo) ~= "string" then
				error("invalid typeinfo in ProtoModule", 0)
			end
			local tlen = #typeinfo
			ensureCodecWriter(w, 5 + tlen)
			local tpos = writeVarIntToBuf(w.buf, w.offset, tlen)
			if tlen > 0 then
				buffer.writestring(w.buf, tpos, typeinfo)
				tpos += tlen
			end
			w.offset = tpos
		else
			ensureCodecWriter(w, 1)
			buffer.writeu8(w.buf, w.offset, 0)
			w.offset += 1
		end
	end

	if type(proto.code) ~= "table" then
		error("invalid code table in ProtoModule", 0)
	end
	local sizecode = #proto.code
	writeProtoCode(w, proto.code, sizecode, encoder)

	if type(proto.kTypes) ~= "table" or type(proto.kValues) ~= "table" then
		error("invalid constant tables in ProtoModule", 0)
	end
	writeProtoConstants(w, proto.kTypes, proto.kValues, strings, stringToId, protoId)

	if type(proto.p) ~= "table" then
		error("invalid child proto table in ProtoModule", 0)
	end
	local p = proto.p
	local sizep = #p
	local linedefined = checkUintRange(proto.linedefined, 0xffffffff, "invalid linedefined in ProtoModule")
	local debugnameId =
		validateAndInternOptionalString(strings, stringToId, proto.debugname, "invalid debugname in ProtoModule")

	ensureCodecWriter(w, 16 + sizep * 5)
	local pbuf = w.buf
	local ppos = writeVarIntToBuf(pbuf, w.offset, sizep)
	for j = 1, sizep do
		local pid = checkUintRange(p[j], protoId - 1, "invalid child proto id in ProtoModule")
		ppos = writeVarIntToBuf(pbuf, ppos, pid)
	end
	ppos = writeVarIntToBuf(pbuf, ppos, linedefined)
	ppos = writeVarIntToBuf(pbuf, ppos, debugnameId)

	local lineData = proto.lineData
	if lineData ~= nil then
		local gap = proto.linegaplog2
		if type(lineData) ~= "string" or type(gap) ~= "number" or math.floor(gap) ~= gap or gap < 0 or gap > 31 then
			error("invalid lineinfo bounds in ProtoModule", 0)
		end
		local intervals = if sizecode > 0 then rshift(sizecode - 1, gap) + 1 else 0
		local lineBytes = sizecode + intervals * 4
		if #lineData ~= lineBytes then
			error("invalid lineinfo bounds in ProtoModule", 0)
		end
		w.offset = ppos
		ensureCodecWriter(w, 2 + lineBytes)
		local lbuf = w.buf
		local lpos = w.offset
		buffer.writeu8(lbuf, lpos, 1)
		buffer.writeu8(lbuf, lpos + 1, gap)
		if lineBytes > 0 then
			buffer.writestring(lbuf, lpos + 2, lineData)
		end
		w.offset = lpos + 2 + lineBytes
	else
		if proto.linegaplog2 ~= nil then
			error("invalid lineinfo bounds in ProtoModule", 0)
		end
		buffer.writeu8(pbuf, ppos, 0)
		w.offset = ppos + 1
	end

	local locvars = proto.locvars
	local upvalues = proto.upvalues
	if locvars ~= nil or upvalues ~= nil then
		if locvars ~= nil and type(locvars) ~= "table" then
			error("invalid locvars in ProtoModule", 0)
		end
		if upvalues ~= nil and type(upvalues) ~= "table" then
			error("invalid upvalues in ProtoModule", 0)
		end
		local sizelocvars = if locvars ~= nil then #locvars else 0
		local sizeupvalues = if upvalues ~= nil then #upvalues else 0
		if sizeupvalues ~= nups then
			error("invalid upvalue count in ProtoModule", 0)
		end
		ensureCodecWriter(w, 11 + sizelocvars * 16 + sizeupvalues * 5)
		local dbuf = w.buf
		local dpos = w.offset
		buffer.writeu8(dbuf, dpos, 1)
		dpos = writeVarIntToBuf(dbuf, dpos + 1, sizelocvars)
		if locvars ~= nil then
			for j = 1, sizelocvars do
				local lv = locvars[j]
				if type(lv) ~= "table" then
					error("invalid locvar entry in ProtoModule", 0)
				end
				local nameId = validateAndInternOptionalString(
					strings,
					stringToId,
					lv.varname,
					"invalid locvar name in ProtoModule"
				)
				local startpc = checkUintRange(lv.startpc, 0xffffffff, "invalid locvar startpc in ProtoModule")
				local endpc = checkUintRange(lv.endpc, 0xffffffff, "invalid locvar endpc in ProtoModule")
				local reg = checkUintRange(lv.reg, 255, "invalid locvar reg in ProtoModule")
				dpos = writeVarIntToBuf(dbuf, dpos, nameId)
				dpos = writeVarIntToBuf(dbuf, dpos, startpc)
				dpos = writeVarIntToBuf(dbuf, dpos, endpc)
				buffer.writeu8(dbuf, dpos, reg)
				dpos += 1
			end
		end
		dpos = writeVarIntToBuf(dbuf, dpos, sizeupvalues)
		if upvalues ~= nil then
			for j = 1, sizeupvalues do
				local uid = validateAndInternOptionalString(
					strings,
					stringToId,
					upvalues[j],
					"invalid upvalue name in ProtoModule"
				)
				dpos = writeVarIntToBuf(dbuf, dpos, uid)
			end
		end
		w.offset = dpos
	else
		ensureCodecWriter(w, 1)
		buffer.writeu8(w.buf, w.offset, 0)
		w.offset += 1
	end

	if version >= 11 then
		ensureCodecWriter(w, 1)
		buffer.writeu8(w.buf, w.offset, 0)
		w.offset += 1
	end
	if version >= 12 and btest(flags, LPF_INLINABLE) then
		ensureCodecWriter(w, 1)
		buffer.writeu8(w.buf, w.offset, 0)
		w.offset += 1
	end

	return startOffset, w.offset - startOffset
end

local function serializeInternal(protoModule: ProtoModule, encoder: BytecodeEncoder?): string
	if type(protoModule) ~= "table" then
		error("expected ProtoModule table", 0)
	end
	if
		encoder ~= nil
		and type(encoder) ~= "function"
		and not (type(encoder) == "table" and type((encoder :: EncoderTable).encode) == "function")
	then
		error("invalid bytecode encoder", 0)
	end

	local version = protoModule.version
	if
		type(version) ~= "number"
		or math.floor(version) ~= version
		or ((version < LBC_VERSION_MIN or version > LBC_VERSION_MAX) and version ~= LBC_VERSION_CLASSES)
	then
		error("bytecode version mismatch in ProtoModule", 0)
	end

	local typesversion = 0
	if version >= 4 then
		local tv = protoModule.typesversion
		if type(tv) ~= "number" or math.floor(tv) ~= tv or tv < LBC_TYPE_VERSION_MIN or tv > LBC_TYPE_VERSION_MAX then
			error("bytecode type version mismatch in ProtoModule", 0)
		end
		typesversion = tv
	else
		local tv = protoModule.typesversion
		if tv ~= nil and tv ~= 0 then
			error("bytecode type version mismatch for v3 ProtoModule", 0)
		end
	end

	if type(protoModule.strings) ~= "table" then
		error("invalid strings table in ProtoModule", 0)
	end
	local rawStrings = protoModule.strings
	local rawStrCount = #rawStrings
	local strings: { string } = table.create(rawStrCount, "")
	local stringToId: { [string]: number } = {}
	for i = 1, rawStrCount do
		local s = rawStrings[i]
		if type(s) ~= "string" then
			error("invalid string entry in ProtoModule.strings", 0)
		end
		strings[i] = s
		if stringToId[s] == nil then
			stringToId[s] = i
		end
	end

	if type(protoModule.protos) ~= "table" or #protoModule.protos == 0 then
		error("invalid protos table in ProtoModule", 0)
	end
	local protos = protoModule.protos
	local protoCount = #protos
	local mainid = checkUintRange(protoModule.mainid, protoCount - 1, "invalid main proto id")

	local udIndices: { number }? = nil
	local udNameIds: { number }? = nil
	if protoModule.userdataTypes ~= nil then
		if type(protoModule.userdataTypes) ~= "table" then
			error("invalid userdataTypes in ProtoModule", 0)
		end
		if typesversion ~= 3 then
			if next(protoModule.userdataTypes) ~= nil then
				error("userdataTypes requires typesversion 3", 0)
			end
		else
			local maxUdIndex = BytecodeDefs.Types.LBC_TYPE_TAGGED_USERDATA_END
				- BytecodeDefs.Types.LBC_TYPE_TAGGED_USERDATA_BASE
			local indices: { number } = {}
			for idx, name in protoModule.userdataTypes do
				if type(idx) ~= "number" or math.floor(idx) ~= idx or idx < 1 or idx > maxUdIndex then
					error("invalid userdata type index in ProtoModule", 0)
				end
				if type(name) ~= "string" or #name == 0 then
					error("invalid userdata type name in ProtoModule", 0)
				end
				indices[#indices + 1] = idx
			end
			if #indices > 0 then
				table.sort(indices)
				local nameIds: { number } = table.create(#indices, 0)
				for k = 1, #indices do
					nameIds[k] = internCodecString(strings, stringToId, protoModule.userdataTypes[indices[k]])
				end
				udIndices = indices
				udNameIds = nameIds
			end
		end
	end

	local writer: CodecWriter = {
		buf = buffer.create(1024),
		offset = 0,
		cap = 1024,
	}
	local protoOffsets: { number } = table.create(protoCount, 0)
	local protoLengths: { number } = table.create(protoCount, 0)
	for i = 1, protoCount do
		protoOffsets[i], protoLengths[i] =
			writeProtoBody(writer, protos[i], i - 1, version, typesversion, strings, stringToId, encoder)
	end

	local stringCount = #strings
	local totalSize = (if version >= 4 then 2 else 1) + writeVarIntSize(stringCount)
	for i = 1, stringCount do
		local slen = #strings[i]
		totalSize += writeVarIntSize(slen) + slen
	end
	if typesversion == 3 then
		if udIndices ~= nil and udNameIds ~= nil then
			for k = 1, #udNameIds do
				totalSize += 1 + writeVarIntSize(udNameIds[k])
			end
		end
		totalSize += 1
	end
	totalSize += writeVarIntSize(protoCount)
	for i = 1, protoCount do
		local plen = protoLengths[i]
		totalSize += (if version >= 12 then writeVarIntSize(plen) else 0) + plen
	end
	totalSize += writeVarIntSize(mainid)

	local outBuf = buffer.create(totalSize)
	buffer.writeu8(outBuf, 0, version)
	local pos = 1
	if version >= 4 then
		buffer.writeu8(outBuf, 1, typesversion)
		pos = 2
	end
	pos = writeVarIntToBuf(outBuf, pos, stringCount)
	for i = 1, stringCount do
		local s = strings[i]
		local slen = #s
		pos = writeVarIntToBuf(outBuf, pos, slen)
		if slen > 0 then
			buffer.writestring(outBuf, pos, s)
			pos += slen
		end
	end
	if typesversion == 3 then
		if udIndices ~= nil and udNameIds ~= nil then
			for k = 1, #udIndices do
				buffer.writeu8(outBuf, pos, udIndices[k])
				pos = writeVarIntToBuf(outBuf, pos + 1, udNameIds[k])
			end
		end
		buffer.writeu8(outBuf, pos, 0)
		pos += 1
	end
	pos = writeVarIntToBuf(outBuf, pos, protoCount)
	local pbuf = writer.buf
	local hasProtoSize = version >= 12
	for i = 1, protoCount do
		local plen = protoLengths[i]
		if hasProtoSize then
			pos = writeVarIntToBuf(outBuf, pos, plen)
		end
		if plen > 0 then
			buffer.copy(outBuf, pos, pbuf, protoOffsets[i], plen)
			pos += plen
		end
	end
	pos = writeVarIntToBuf(outBuf, pos, mainid)
	return buffer.readstring(outBuf, 0, pos)
end

--- Deserializes binary Luau bytecode (v3–v14 and v100) into an immutable `ProtoModule`, returning `(module, nil)` or `(nil, err)`.
local function deserialize(data: string | buffer, decoder: BytecodeDecoder?): (ProtoModule?, string?)
	if
		decoder ~= nil
		and type(decoder) ~= "function"
		and not (type(decoder) == "table" and type((decoder :: DecoderTable).decode) == "function")
	then
		error("invalid bytecode decoder", 2)
	end
	local ok, modOrErr = pcall(deserializeInternal, data, decoder)
	if not ok then
		return nil, tostring(modOrErr)
	end
	return modOrErr :: ProtoModule, nil
end

--- Serializes a `ProtoModule` into binary Luau bytecode, returning `(bytecode, nil)` or `(nil, err)`.
--- Note: `ProtoModule` IR does not carry per-proto inline `cost` or feedback-slot metadata, so `serialize` encodes `cost = 0` and an empty feedback vector (round-tripping identically through `deserialize`).
local function serialize(protoModule: ProtoModule, encoder: BytecodeEncoder?): (string?, string?)
	if
		encoder ~= nil
		and type(encoder) ~= "function"
		and not (type(encoder) == "table" and type((encoder :: EncoderTable).encode) == "function")
	then
		error("invalid bytecode encoder", 2)
	end
	local ok, bytesOrErr = pcall(serializeInternal, protoModule, encoder)
	if not ok then
		return nil, tostring(bytesOrErr)
	end
	return bytesOrErr :: string, nil
end

return table.freeze({
	insnOp = insnOp,
	insnA = insnA,
	insnB = insnB,
	insnC = insnC,
	insnD = insnD,
	insnE = insnE,
	decomposeImportId = decomposeImportId,
	encodeError = encodeError,
	decodeError = decodeError,
	decodeLineInfo = decodeLineInfo,
	deserialize = deserialize,
	serialize = serialize,
})
