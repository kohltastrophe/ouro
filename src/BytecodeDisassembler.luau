--!strict
-- Lazy-loaded Luau bytecode disassembler matching upstream BytecodeBuilder.cpp.
-- Upstream Luau is MIT licensed. See ../LICENSE.md and ../UPSTREAM.json.
local BytecodeCodec = require("./BytecodeCodec")
local BytecodeDefs = require("./BytecodeDefs")
local Types = require("./Types")

local Opcodes = BytecodeDefs.Opcodes
local opcodeNames = BytecodeDefs.opcodeNames
local opLengths = BytecodeDefs.opLengths
local isJumpD = BytecodeDefs.isJumpD
local isFastCall = BytecodeDefs.isFastCall
local isSkipC = BytecodeDefs.isSkipC
local BytecodeTypes = BytecodeDefs.Types
local Captures = BytecodeDefs.Captures
local builtinNames = BytecodeDefs.builtinNames

local band = bit32.band
local bnot = bit32.bnot
local btest = bit32.btest
local lshift = bit32.lshift
local rshift = bit32.rshift

local insnOp = BytecodeCodec.insnOp
local insnA = BytecodeCodec.insnA
local insnB = BytecodeCodec.insnB
local insnC = BytecodeCodec.insnC
local insnD = BytecodeCodec.insnD
local insnE = BytecodeCodec.insnE
local decomposeImportId = BytecodeCodec.decomposeImportId

local LOP_RETURN = Opcodes.LOP_RETURN
local LOP_JUMP = Opcodes.LOP_JUMP
local LOP_JUMPX = Opcodes.LOP_JUMPX

local ConstantType = table.freeze({
	Nil = 0,
	Boolean = 1,
	Number = 2,
	Vectorf = 3,
	Vectord = 4,
	String = 5,
	Import = 6,
	Table = 7,
	Closure = 8,
	TableWithConstants = 9,
	Class = 11,
})

local DumpFlags = table.freeze({
	Code = 1,
	Lines = 2,
	Source = 4,
	Locals = 8,
	Remarks = 16,
	Types = 32,
	Constants = 64,
})

local BASE_TYPE_NAMES: { [number]: string } = table.freeze({
	[BytecodeTypes.LBC_TYPE_NIL] = "nil",
	[BytecodeTypes.LBC_TYPE_BOOLEAN] = "boolean",
	[BytecodeTypes.LBC_TYPE_NUMBER] = "number",
	[BytecodeTypes.LBC_TYPE_STRING] = "string",
	[BytecodeTypes.LBC_TYPE_TABLE] = "table",
	[BytecodeTypes.LBC_TYPE_FUNCTION] = "function",
	[BytecodeTypes.LBC_TYPE_THREAD] = "thread",
	[BytecodeTypes.LBC_TYPE_USERDATA] = "userdata",
	[BytecodeTypes.LBC_TYPE_VECTOR] = "vector",
	[BytecodeTypes.LBC_TYPE_BUFFER] = "buffer",
	[BytecodeTypes.LBC_TYPE_CLASS] = "class",
	[BytecodeTypes.LBC_TYPE_OBJECT] = "object",
	[BytecodeTypes.LBC_TYPE_ANY] = "any",
})

local CONSTANT_TYPE_NAMES: { [number]: string } = table.freeze({
	[ConstantType.Nil] = "nil",
	[ConstantType.Boolean] = "boolean",
	[ConstantType.Number] = "number",
	[ConstantType.Vectorf] = "vectorf",
	[ConstantType.Vectord] = "vectord",
	[ConstantType.String] = "string",
	[ConstantType.Import] = "import",
	[ConstantType.Table] = "table",
	[ConstantType.TableWithConstants] = "table_with_constants",
	[ConstantType.Closure] = "closure",
	[ConstantType.Class] = "class",
})

local function resolveBaseTypeName(self: any, ty: number): string
	local tag = band(ty, bnot(BytecodeTypes.LBC_TYPE_OPTIONAL_BIT))
	if tag >= BytecodeTypes.LBC_TYPE_TAGGED_USERDATA_BASE and tag < BytecodeTypes.LBC_TYPE_TAGGED_USERDATA_END then
		local ud = self.userdataTypes[tag - BytecodeTypes.LBC_TYPE_TAGGED_USERDATA_BASE + 1]
		return if ud then ud.name else "userdata"
	end
	local name = BASE_TYPE_NAMES[tag]
	if name then
		return name
	end
	return string.format("unknown(%d)", tag)
end

local function formatStringConstant(s: string): string
	local len = #s
	local printable = true
	for i = 1, len do
		if string.byte(s, i) < 32 then
			printable = false
			break
		end
	end
	if printable then
		if len < 32 then
			return string.format("'%s'", s)
		end
		return string.format("'%s'...", string.sub(s, 1, 32))
	end
	local limit = math.min(len, 32)
	local parts = table.create(limit + 2)
	parts[1] = "'"
	for i = 1, limit do
		local b = string.byte(s, i)
		parts[i + 1] = if b < 32 then string.format("\\x%02X", b) else string.char(b)
	end
	parts[limit + 2] = if len >= 32 then "'..." else "'"
	return table.concat(parts)
end

local dumpK: (self: any, idx: number, visiting: { [any]: boolean }?) -> string
local dumpConstantPair: (self: any, ctype: number, cval: any, visiting: { [any]: boolean }?) -> string

local function dumpKeyName(self: any, keyIdx: number, visiting: { [any]: boolean }?): string
	if type(keyIdx) ~= "number" or keyIdx < 0 or keyIdx >= #self.constTypes then
		return ""
	end
	if self.constTypes[keyIdx + 1] == ConstantType.String then
		return self.stringList[self.constVals[keyIdx + 1] :: number] or ""
	end
	return dumpK(self, keyIdx, visiting)
end

local function dumpComplexConstant(self: any, ctype: number, cval: any, visiting: { [any]: boolean }?): string
	if ctype == ConstantType.Import then
		if type(cval) ~= "number" then
			return ""
		end
		local count, id0, id1, id2 = decomposeImportId(cval)
		local parts = {}
		if count >= 1 then
			parts[#parts + 1] = dumpKeyName(self, id0, visiting)
		end
		if count >= 2 then
			parts[#parts + 1] = dumpKeyName(self, id1, visiting)
		end
		if count >= 3 then
			parts[#parts + 1] = dumpKeyName(self, id2, visiting)
		end
		return table.concat(parts, ".")
	elseif ctype == ConstantType.Table then
		if type(cval) ~= "number" then
			return "{}"
		end
		local shape = self.tableShapes[cval + 1]
		if type(shape) ~= "table" or type(shape.keys) ~= "table" then
			return "{}"
		end
		local keys = shape.keys
		local len = if type(shape.length) == "number" and shape.length >= 0
			then math.min(shape.length, #keys)
			else #keys
		local parts = {}
		for i = 1, len do
			parts[#parts + 1] = dumpKeyName(self, keys[i], visiting)
		end
		return "{" .. table.concat(parts, ", ") .. "}"
	elseif ctype == ConstantType.TableWithConstants then
		if type(cval) ~= "number" then
			return "{}"
		end
		local shape = self.tableShapes[cval + 1]
		if type(shape) ~= "table" or type(shape.keys) ~= "table" then
			return "{}"
		end
		local seen = visiting or {}
		if seen[shape] then
			return "{...}"
		end
		seen[shape] = true
		local keys = shape.keys
		local constants = if type(shape.constants) == "table" then shape.constants else {}
		local len = if type(shape.length) == "number" and shape.length >= 0
			then math.min(shape.length, #keys)
			else #keys
		local parts = {}
		for i = 1, len do
			local kstr = dumpKeyName(self, keys[i], seen)
			local valConstIdx = constants[i]
			if type(valConstIdx) == "number" and valConstIdx >= 0 and valConstIdx < #self.constTypes then
				local valIdx = valConstIdx + 1
				kstr ..= ": " .. dumpConstantPair(self, self.constTypes[valIdx], self.constVals[valIdx], seen)
			end
			parts[#parts + 1] = kstr
		end
		seen[shape] = nil
		return "{" .. table.concat(parts, ", ") .. "}"
	elseif ctype == ConstantType.Closure then
		if type(cval) ~= "number" then
			return ""
		end
		local func = self.functions[cval + 1]
		return if func and #func.dumpname > 0 then string.format("'%s'", func.dumpname) else ""
	elseif ctype == ConstantType.Class then
		if type(cval) ~= "number" then
			return "class  {\n}"
		end
		local shape = self.classShapes[cval + 1]
		if type(shape) ~= "table" then
			return "class  {\n}"
		end
		local seen = visiting or {}
		if seen[shape] then
			return "class {...}"
		end
		seen[shape] = true
		local nameStr = dumpKeyName(self, shape.className, seen)
		local out = { "class " .. nameStr .. " {\n" }
		if type(shape.propertyNames) == "table" then
			for _, propIdx in shape.propertyNames do
				out[#out + 1] = "\tproperty " .. dumpKeyName(self, propIdx, seen) .. "\n"
			end
		end
		if type(shape.methodNames) == "table" then
			for _, methodIdx in shape.methodNames do
				out[#out + 1] = "\tmethod " .. dumpKeyName(self, methodIdx, seen) .. "\n"
			end
		end
		seen[shape] = nil
		out[#out + 1] = "}"
		return table.concat(out)
	end
	return ""
end

function dumpConstantPair(self: any, ctype: number, cval: any, visiting: { [any]: boolean }?): string
	if ctype == ConstantType.Nil then
		return "nil"
	elseif ctype == ConstantType.Boolean then
		return if cval then "true" else "false"
	elseif ctype == ConstantType.Number then
		if type(cval) ~= "number" then
			return "0"
		end
		return string.format("%.17g", cval)
	elseif ctype == ConstantType.Vectorf then
		if
			type(cval) ~= "table"
			or type(cval[1]) ~= "number"
			or type(cval[2]) ~= "number"
			or type(cval[3]) ~= "number"
		then
			return "0, 0, 0"
		end
		if cval[4] == nil or cval[4] == 0 then
			return string.format("%.9g, %.9g, %.9g", cval[1], cval[2], cval[3])
		end
		if type(cval[4]) ~= "number" then
			return string.format("%.9g, %.9g, %.9g", cval[1], cval[2], cval[3])
		end
		return string.format("%.9g, %.9g, %.9g, %.9g", cval[1], cval[2], cval[3], cval[4])
	elseif ctype == ConstantType.Vectord then
		if
			type(cval) ~= "table"
			or type(cval[1]) ~= "number"
			or type(cval[2]) ~= "number"
			or type(cval[3]) ~= "number"
		then
			return "0, 0, 0"
		end
		if cval[4] == nil or cval[4] == 0 then
			return string.format("%.17g, %.17g, %.17g", cval[1], cval[2], cval[3])
		end
		if type(cval[4]) ~= "number" then
			return string.format("%.17g, %.17g, %.17g", cval[1], cval[2], cval[3])
		end
		return string.format("%.17g, %.17g, %.17g, %.17g", cval[1], cval[2], cval[3], cval[4])
	elseif ctype == ConstantType.String then
		if type(cval) ~= "number" then
			return "''"
		end
		return formatStringConstant(self.stringList[cval] or "")
	end
	return dumpComplexConstant(self, ctype, cval, visiting)
end

function dumpK(self: any, idx: number, visiting: { [any]: boolean }?): string
	if type(idx) ~= "number" or idx < 0 or idx >= #self.constTypes then
		return ""
	end
	return dumpConstantPair(self, self.constTypes[idx + 1], self.constVals[idx + 1], visiting)
end

local function dumpControlFlowInstruction(
	self: any,
	op: number,
	opName: string,
	a: number,
	b: number,
	_c: number,
	d: number,
	aux: number,
	label: number
): (string?, number)
	if op == Opcodes.LOP_NEWCLOSURE then
		return string.format("%s R%d P%d\n", opName, a, d), 1
	elseif op == Opcodes.LOP_NAMECALL then
		return string.format("%s R%d R%d K%d [%s]\n", opName, a, b, aux, dumpK(self, aux)), 2
	elseif op == Opcodes.LOP_CALL then
		return string.format("%s R%d %d %d\n", opName, a, b - 1, _c - 1), 1
	elseif op == Opcodes.LOP_CALLFB then
		return string.format("%s R%d %d %d [%d]\n", opName, a, b - 1, _c - 1, aux), 2
	elseif op == LOP_RETURN then
		return string.format("%s R%d %d\n", opName, a, b - 1), 1
	elseif op == LOP_JUMP or op == Opcodes.LOP_JUMPBACK or op == LOP_JUMPX then
		return string.format("%s L%d\n", opName, label), 1
	elseif
		op == Opcodes.LOP_JUMPIF
		or op == Opcodes.LOP_JUMPIFNOT
		or op == Opcodes.LOP_FORNPREP
		or op == Opcodes.LOP_FORNLOOP
		or op == Opcodes.LOP_FORGPREP_INEXT
		or op == Opcodes.LOP_FORGPREP_NEXT
		or op == Opcodes.LOP_FORGPREP
		or op == Opcodes.LOP_FINCONSTRUCT
	then
		return string.format("%s R%d L%d\n", opName, a, label), 1
	elseif
		op == Opcodes.LOP_JUMPIFEQ
		or op == Opcodes.LOP_JUMPIFLE
		or op == Opcodes.LOP_JUMPIFLT
		or op == Opcodes.LOP_JUMPIFNOTEQ
		or op == Opcodes.LOP_JUMPIFNOTLE
		or op == Opcodes.LOP_JUMPIFNOTLT
	then
		return string.format("%s R%d R%d L%d\n", opName, a, aux, label), 2
	elseif op == Opcodes.LOP_FORGLOOP then
		local varCount = band(aux, 0xff)
		local ipairsTag = if band(aux, 0x80000000) ~= 0 then " [inext]" else ""
		return string.format("%s R%d L%d %d%s\n", opName, a, label, varCount, ipairsTag), 2
	elseif op == Opcodes.LOP_JUMPXEQKNIL then
		return string.format("%s R%d L%d%s\n", opName, a, label, if rshift(aux, 31) ~= 0 then " NOT" else ""), 2
	elseif op == Opcodes.LOP_JUMPXEQKB then
		local suffix = if rshift(aux, 31) ~= 0 then " NOT" else ""
		return string.format("%s R%d %d L%d%s\n", opName, a, band(aux, 1), label, suffix), 2
	elseif op == Opcodes.LOP_JUMPXEQKN or op == Opcodes.LOP_JUMPXEQKS then
		local kidx = band(aux, 0xffffff)
		local suffix = if rshift(aux, 31) ~= 0 then " NOT" else ""
		return string.format("%s R%d K%d L%d%s [%s]\n", opName, a, kidx, label, suffix, dumpK(self, kidx)), 2
	elseif op == Opcodes.LOP_CMPPROTO then
		return string.format("%s R%d #%d L%d\n", opName, a, aux, label), 2
	end
	return nil, 0
end

local function dumpFastCallAndClassInstruction(
	self: any,
	op: number,
	opName: string,
	a: number,
	b: number,
	c: number,
	aux: number,
	label: number
): (string?, number)
	if op == Opcodes.LOP_FASTCALL then
		return string.format("%s %d L%d [%s]\n", opName, a, label, builtinNames[a] or ""), 1
	elseif op == Opcodes.LOP_FASTPCALL then
		return string.format("%s %s L%d\n", opName, if a ~= 0 then "xpcall" else "pcall", label), 1
	elseif op == Opcodes.LOP_COVERAGE then
		return string.format("%s\n", opName), 1
	elseif op == Opcodes.LOP_CAPTURE then
		local ctype = if a == Captures.LCT_VAL
			then "VAL"
			elseif a == Captures.LCT_UPVAL then "UPVAL"
			elseif a == Captures.LCT_REF then "REF"
			else ""
		local regPrefix = if a == Captures.LCT_UPVAL then "U" else "R"
		return string.format("%s %s %s%d\n", opName, ctype, regPrefix, b), 1
	elseif op == Opcodes.LOP_FASTCALL1 then
		return string.format("%s %d R%d L%d [%s]\n", opName, a, b, label, builtinNames[a] or ""), 1
	elseif op == Opcodes.LOP_FASTCALL2 then
		return string.format("%s %d R%d R%d L%d [%s]\n", opName, a, b, aux, label, builtinNames[a] or ""), 2
	elseif op == Opcodes.LOP_FASTCALL2K then
		local bname = builtinNames[a] or ""
		return string.format("%s %d R%d K%d L%d [%s] [%s]\n", opName, a, b, aux, label, bname, dumpK(self, aux)), 2
	elseif op == Opcodes.LOP_FASTCALL3 then
		local bname = builtinNames[a] or ""
		local r2 = band(aux, 0xff)
		local r3 = band(rshift(aux, 8), 0xff)
		return string.format("%s %d R%d R%d R%d L%d [%s]\n", opName, a, b, r2, r3, label, bname), 2
	elseif op == Opcodes.LOP_NEWCLASS then
		local kstr = dumpK(self, aux)
		if b == 0xff then
			return string.format("%s R%d no_base %d K%d [%s]\n", opName, a, c, aux, kstr), 2
		else
			return string.format("%s R%d R%d %d K%d [%s]\n", opName, a, b, c, aux, kstr), 2
		end
	elseif op == Opcodes.LOP_NEWCLASSMEMBER then
		if b == 1 then
			return string.format("%s R%d R%d %d [private]\n", opName, a, c, band(aux, 0xff)), 2
		else
			return string.format("%s R%d R%d [public] [%s]\n", opName, a, c, dumpK(self, aux)), 2
		end
	elseif op == Opcodes.LOP_CONSTRUCT then
		return string.format("%s R%d R%d slot %d\n", opName, a, b, aux), 2
	elseif op == Opcodes.LOP_GETPRIVATEFIELD then
		local isStatic = band(rshift(aux, 8), 1) ~= 0
		local isNamecall = band(rshift(aux, 9), 1) ~= 0
		return string.format(
			"%s R%d R%d U%d %d [%s]%s\n",
			opName,
			a,
			b,
			c,
			band(aux, 0xff),
			if isStatic then "static" else "instance",
			if isNamecall then " [namecall]" else ""
		),
			2
	elseif op == Opcodes.LOP_SETPRIVATEFIELD then
		return string.format("%s R%d R%d U%d %d\n", opName, a, b, c, band(aux, 0xff)), 2
	end
	return nil, 0
end

local function dumpArithAndTableInstruction(
	self: any,
	op: number,
	opName: string,
	a: number,
	b: number,
	c: number,
	d: number,
	aux: number
): (string?, number)
	if
		op == Opcodes.LOP_ADD
		or op == Opcodes.LOP_SUB
		or op == Opcodes.LOP_MUL
		or op == Opcodes.LOP_DIV
		or op == Opcodes.LOP_IDIV
		or op == Opcodes.LOP_MOD
		or op == Opcodes.LOP_POW
		or op == Opcodes.LOP_AND
		or op == Opcodes.LOP_OR
		or op == Opcodes.LOP_CONCAT
	then
		return string.format("%s R%d R%d R%d\n", opName, a, b, c), 1
	elseif
		op == Opcodes.LOP_ADDK
		or op == Opcodes.LOP_SUBK
		or op == Opcodes.LOP_MULK
		or op == Opcodes.LOP_DIVK
		or op == Opcodes.LOP_IDIVK
		or op == Opcodes.LOP_MODK
		or op == Opcodes.LOP_POWK
		or op == Opcodes.LOP_ANDK
		or op == Opcodes.LOP_ORK
	then
		return string.format("%s R%d R%d K%d [%s]\n", opName, a, b, c, dumpK(self, c)), 1
	elseif op == Opcodes.LOP_SUBRK or op == Opcodes.LOP_DIVRK then
		return string.format("%s R%d K%d [%s] R%d\n", opName, a, b, dumpK(self, b), c), 1
	elseif op == Opcodes.LOP_NOT or op == Opcodes.LOP_MINUS or op == Opcodes.LOP_LENGTH then
		return string.format("%s R%d R%d\n", opName, a, b), 1
	elseif op == Opcodes.LOP_NEWTABLE then
		return string.format("%s R%d %d %d\n", opName, a, if b == 0 then 0 else lshift(1, b - 1), aux), 2
	elseif op == Opcodes.LOP_DUPTABLE then
		return string.format("%s R%d %d [%s]\n", opName, a, d, dumpK(self, d)), 1
	elseif op == Opcodes.LOP_SETLIST then
		return string.format("%s R%d R%d %d [%d]\n", opName, a, b, c - 1, aux), 2
	elseif op == Opcodes.LOP_GETVARARGS then
		return string.format("%s R%d %d\n", opName, a, b - 1), 1
	elseif op == Opcodes.LOP_DUPCLOSURE then
		return string.format("%s R%d K%d [%s]\n", opName, a, d, dumpK(self, d)), 1
	elseif op == Opcodes.LOP_PREPVARARGS then
		return string.format("%s %d\n", opName, a), 1
	elseif op == Opcodes.LOP_LOADKX then
		return string.format("%s R%d K%d [%s]\n", opName, a, aux, dumpK(self, aux)), 2
	end
	return nil, 0
end

local function dumpInstruction(self: any, idx0: number, label: number): (string, number)
	local insnBuf: buffer = self.insnBuf
	local insn: number = buffer.readu32(insnBuf, idx0 * 4)
	local op = insnOp(insn)
	local a = insnA(insn)
	local b = insnB(insn)
	local c = insnC(insn)
	local d = insnD(insn)
	local aux: number = if idx0 + 1 < self.insnCount then buffer.readu32(insnBuf, (idx0 + 1) * 4) else 0
	local opName: string = opcodeNames[op] or "UNKNOWN"

	if op == Opcodes.LOP_NOP then
		return string.format("%#08x\n", insn), 1
	elseif op == Opcodes.LOP_LOADNIL or op == Opcodes.LOP_CLOSEUPVALS then
		return string.format("%s R%d\n", opName, a), 1
	elseif op == Opcodes.LOP_LOADB then
		if c ~= 0 then
			if label >= 0 then
				return string.format("%s R%d %d L%d\n", opName, a, b, label), 1
			end
			return string.format("%s R%d %d +%d\n", opName, a, b, c), 1
		else
			return string.format("%s R%d %d\n", opName, a, b), 1
		end
	elseif op == Opcodes.LOP_LOADN then
		return string.format("%s R%d %d\n", opName, a, d), 1
	elseif op == Opcodes.LOP_LOADK then
		return string.format("%s R%d K%d [%s]\n", opName, a, d, dumpK(self, d)), 1
	elseif op == Opcodes.LOP_MOVE then
		return string.format("%s R%d R%d\n", opName, a, b), 1
	elseif op == Opcodes.LOP_GETGLOBAL or op == Opcodes.LOP_SETGLOBAL then
		return string.format("%s R%d K%d [%s]\n", opName, a, aux, dumpK(self, aux)), 2
	elseif op == Opcodes.LOP_GETUPVAL or op == Opcodes.LOP_SETUPVAL then
		return string.format("%s R%d U%d\n", opName, a, b), 1
	elseif op == Opcodes.LOP_GETIMPORT then
		return string.format("%s R%d %d [%s]\n", opName, a, d, dumpK(self, d)), 2
	elseif op == Opcodes.LOP_GETTABLE or op == Opcodes.LOP_SETTABLE then
		return string.format("%s R%d R%d R%d\n", opName, a, b, c), 1
	elseif op == Opcodes.LOP_GETTABLEKS or op == Opcodes.LOP_SETTABLEKS then
		return string.format("%s R%d R%d K%d [%s]\n", opName, a, b, aux, dumpK(self, aux)), 2
	elseif op == Opcodes.LOP_GETUDATAKS or op == Opcodes.LOP_SETUDATAKS or op == Opcodes.LOP_NAMECALLUDATA then
		local kidx = band(aux, 0xffff)
		return string.format("%s R%d R%d K%d [%s]\n", opName, a, b, kidx, dumpK(self, kidx)), 2
	elseif op == Opcodes.LOP_GETTABLEN or op == Opcodes.LOP_SETTABLEN then
		return string.format("%s R%d R%d %d\n", opName, a, b, c + 1), 1
	end

	local str, step = dumpControlFlowInstruction(self, op, opName, a, b, c, d, aux, label)
	if str then
		return str, step
	end
	str, step = dumpArithAndTableInstruction(self, op, opName, a, b, c, d, aux)
	if str then
		return str, step
	end
	str, step = dumpFastCallAndClassInstruction(self, op, opName, a, b, c, aux, label)
	if str then
		return str, step
	end

	return string.format("%s\n", opName), opLengths[op] or 1
end

local function dumpFunctionTypes(self: any, func: any, result: { string })
	if #func.typeinfo > 0 then
		result[#result + 1] = "("
		local typeSize = #func.typeinfo
		for i = 3, typeSize do
			local et = string.byte(func.typeinfo, i)
			local opt = if btest(et, BytecodeTypes.LBC_TYPE_OPTIONAL_BIT) then "?" else ""
			result[#result + 1] = resolveBaseTypeName(self, et) .. opt
			if i < typeSize then
				result[#result + 1] = ", "
			end
		end
		result[#result + 1] = ")\n"
	end

	local tuTypes = self.typedUpvalTypes
	for i = 1, self.typedUpvalCount do
		local et = tuTypes[i]
		local opt = if btest(et, BytecodeTypes.LBC_TYPE_OPTIONAL_BIT) then "?" else ""
		result[#result + 1] = string.format("U%d: %s%s\n", i - 1, resolveBaseTypeName(self, et), opt)
	end

	local tlTypes = self.typedLocalTypes
	local tlRegs = self.typedLocalRegs
	local tlStartPcs = self.typedLocalStartPcs
	local tlEndPcs = self.typedLocalEndPcs
	for i = 1, self.typedLocalCount do
		local et = tlTypes[i]
		local opt = if btest(et, BytecodeTypes.LBC_TYPE_OPTIONAL_BIT) then "?" else ""
		result[#result + 1] = string.format(
			"R%d: %s%s [from %d to %d]\n",
			tlRegs[i],
			resolveBaseTypeName(self, et),
			opt,
			tlStartPcs[i],
			tlEndPcs[i]
		)
	end
end

local function getJumpTarget(op: number, insn: number, i: number): number
	if isJumpD[op] then
		return i + 1 + insnD(insn)
	elseif op == LOP_JUMPX then
		return i + 1 + insnE(insn)
	elseif isFastCall[op] then
		return i + 2 + insnC(insn)
	elseif isSkipC[op] then
		local c = insnC(insn)
		if c ~= 0 then
			return i + 1 + c
		end
	end
	return -1
end

local function buildJumpLabels(insnBuf: buffer, insnCount: number): { number }
	local labels = table.create(insnCount + 1, -1)
	local i = 0
	while i < insnCount do
		local insn = buffer.readu32(insnBuf, i * 4)
		local op = insnOp(insn)
		local target = getJumpTarget(op, insn, i)
		if target >= 0 and target <= insnCount then
			labels[target + 1] = 0
		end
		i += opLengths[op] or 1
	end
	local nextLabel = 0
	for pc = 0, insnCount do
		if labels[pc + 1] == 0 then
			labels[pc + 1] = nextLabel
			nextLabel += 1
		end
	end
	return labels
end

local function dumpFunctionCode(self: any, labels: { number }, result: { string })
	local prevLine = -1
	local lastSourceLine = -1
	local nextRemark = 1
	while nextRemark <= #self.debugRemarks and self.debugRemarks[nextRemark].fid ~= self.currentFunction do
		nextRemark += 1
	end
	local sourceLines = self.dumpSourceLines :: { string }?
	local dumpLines = btest(self.dumpFlags, DumpFlags.Lines)
	local dumpSource = btest(self.dumpFlags, DumpFlags.Source) and sourceLines ~= nil
	local dumpRemarks = btest(self.dumpFlags, DumpFlags.Remarks)

	local insnBuf: buffer = self.insnBuf
	local lineBuf: buffer = self.lineBuf
	local insnCount: number = self.insnCount
	local i = 0
	while i < insnCount do
		local insn = buffer.readu32(insnBuf, i * 4)
		local line = buffer.readi32(lineBuf, i * 4)

		if dumpRemarks then
			while
				nextRemark <= #self.debugRemarks
				and self.debugRemarks[nextRemark].fid == self.currentFunction
				and self.debugRemarks[nextRemark].line <= line
			do
				result[#result + 1] = string.format("remark: %s\n", self.debugRemarks[nextRemark].text)
				nextRemark += 1
			end
		end

		if dumpSource and line > 0 and line ~= lastSourceLine then
			local srcLine = (sourceLines :: { string })[line]
			if srcLine ~= nil then
				result[#result + 1] = string.format("%5d: %s\n", line, srcLine)
				lastSourceLine = line
			end
		end

		if labels[i + 1] ~= -1 then
			result[#result + 1] = string.format("L%d:\n", labels[i + 1])
		end

		if dumpLines then
			if line ~= prevLine then
				result[#result + 1] = string.format("%5d: ", line)
				prevLine = line
			else
				result[#result + 1] = "       "
			end
		end

		local target = getJumpTarget(insnOp(insn), insn, i)
		local targetLabel = if target >= 0 and target <= insnCount then labels[target + 1] else -1
		local str, step = dumpInstruction(self, i, targetLabel)
		result[#result + 1] = str
		i += step
	end

	if dumpRemarks then
		while nextRemark <= #self.debugRemarks and self.debugRemarks[nextRemark].fid == self.currentFunction do
			result[#result + 1] = string.format("remark: %s\n", self.debugRemarks[nextRemark].text)
			nextRemark += 1
		end
	end

	if labels[insnCount + 1] ~= -1 then
		result[#result + 1] = string.format("L%d:\n", labels[insnCount + 1])
	end
end

local function dumpCurrentFunction(self: any): string
	if self.currentFunction == nil or self.currentFunction < 0 then
		return ""
	end
	local func = self.functions[self.currentFunction + 1]
	if func == nil then
		return ""
	end
	local result = {}

	if func.linedefined > 0 then
		result[#result + 1] =
			string.format("Function %d (%s): -- line %d\n", self.currentFunction, func.dumpname, func.linedefined)
	else
		result[#result + 1] = string.format("Function %d (%s):\n", self.currentFunction, func.dumpname)
	end

	if btest(self.dumpFlags, DumpFlags.Types) then
		dumpFunctionTypes(self, func, result)
	end

	if btest(self.dumpFlags, DumpFlags.Code) then
		local labels = buildJumpLabels(self.insnBuf, self.insnCount)
		dumpFunctionCode(self, labels, result)
	end

	if btest(self.dumpFlags, DumpFlags.Locals) then
		local stringList: { string } = self.stringList
		local dlNames: { number } = self.debugLocalNames
		local dlRegs: { number } = self.debugLocalRegs
		local dlStartPcs: { number } = self.debugLocalStartPcs
		local dlEndPcs: { number } = self.debugLocalEndPcs
		for i = 1, self.debugLocalCount do
			local lname: string = stringList[dlNames[i]] or ""
			result[#result + 1] =
				string.format("local %s: R%d [from %d to %d]\n", lname, dlRegs[i], dlStartPcs[i], dlEndPcs[i])
		end
		local duNames: { number } = self.debugUpvalNames
		for i = 1, self.debugUpvalCount do
			local uname: string = stringList[duNames[i]] or ""
			result[#result + 1] = string.format("upval %s: U%d\n", uname, i - 1)
		end
	end

	if btest(self.dumpFlags, DumpFlags.Constants) then
		local constTypes = self.constTypes
		local constVals = self.constVals
		for i = 1, #constTypes do
			local ctype = constTypes[i]
			local ktype: string = CONSTANT_TYPE_NAMES[ctype] or ""
			result[#result + 1] =
				string.format("K%d: %s [%s]\n", i - 1, ktype, dumpConstantPair(self, ctype, constVals[i]))
		end
	end

	result[#result + 1] = "\n"
	return table.concat(result)
end

local function readTypeBlobVarInt(blob: string, pos: number): (number, number)
	local len = #blob
	local result = 0
	local shift = 0
	while pos <= len do
		local b = string.byte(blob, pos)
		pos += 1
		local bits = if b >= 128 then b - 128 else b
		result += lshift(bits, shift)
		if b < 128 or shift >= 28 then
			return result, pos
		end
		shift += 7
	end
	return result, pos
end

local function dumpTypeInfo(self: any): string
	local result = {}
	for i, ud in ipairs(self.userdataTypes) do
		result[#result + 1] =
			string.format("U%d: %s (used %d)\n", i, ud.name, if ud.used or ud.nameRef ~= 0 then 1 else 0)
	end
	for i, f in ipairs(self.functions) do
		local tblob = f.typeinfo
		if type(tblob) == "string" and #tblob >= 1 then
			local blen = #tblob
			local pos = 1
			local rawLen, _upvalCount, _localCount: number
			rawLen, pos = readTypeBlobVarInt(tblob, pos)
			_upvalCount, pos = readTypeBlobVarInt(tblob, pos)
			_localCount, pos = readTypeBlobVarInt(tblob, pos)
			if rawLen > 0 and pos + rawLen - 1 <= blen then
				local tinfo = string.sub(tblob, pos, pos + rawLen - 1)
				local encodedType = string.byte(tinfo, 1)
				if encodedType == BytecodeTypes.LBC_TYPE_FUNCTION then
					local numparams = if #tinfo >= 2 then string.byte(tinfo, 2) else 0
					local maxParams = math.min(numparams, math.max(0, #tinfo - 2))
					local params = table.create(maxParams)
					for p = 1, maxParams do
						local et = string.byte(tinfo, 2 + p)
						local opt = if btest(et, BytecodeTypes.LBC_TYPE_OPTIONAL_BIT) then "?" else ""
						params[p] = resolveBaseTypeName(self, et) .. opt
					end
					result[#result + 1] = string.format("%d: function(%s)\n", i - 1, table.concat(params, ", "))
				else
					local opt = if btest(encodedType, BytecodeTypes.LBC_TYPE_OPTIONAL_BIT) then "?" else ""
					result[#result + 1] =
						string.format("%d: %s%s\n", i - 1, resolveBaseTypeName(self, encodedType), opt)
				end
			end
		end
	end
	return table.concat(result)
end

local function dumpSourceRemarks(self: any): string
	local sourceLines = self.dumpSourceLines :: { string }?
	if sourceLines == nil then
		local remarks = self.debugRemarks
		local n = #remarks
		if n == 0 then
			return ""
		end
		local parts = table.create(n)
		for i = 1, n do
			parts[i] = remarks[i].text .. "\n"
		end
		return table.concat(parts)
	end
	local remarks: { { line: number, text: string } } = {}
	for _, r in self.debugRemarks do
		if r.line > 0 then
			remarks[#remarks + 1] = { line = r.line, text = r.text }
		end
	end
	table.sort(remarks, function(a: { line: number, text: string }, b: { line: number, text: string }): boolean
		if a.line ~= b.line then
			return a.line < b.line
		end
		return a.text < b.text
	end)
	local result = {}
	local nextRemark = 1
	local lastLine = 0
	local lastText = ""
	local totalLines = #sourceLines
	for i = 1, totalLines do
		local line = sourceLines[i]
		local indent = string.match(line, "^[ \t]*") or ""
		while nextRemark <= #remarks and remarks[nextRemark].line == i do
			local r = remarks[nextRemark]
			if r.line ~= lastLine or r.text ~= lastText then
				result[#result + 1] = string.format("%s-- remark: %s\n", indent, r.text)
				lastLine = r.line
				lastText = r.text
			end
			nextRemark += 1
		end
		result[#result + 1] = line
		if i < totalLines then
			result[#result + 1] = "\n"
		end
	end
	return table.concat(result)
end

local function splitDumpSourceLines(source: string): { string }
	local lines = string.split(source, "\n")
	for i = 1, #lines do
		local line = lines[i]
		local len = #line
		if len > 0 and string.byte(line, len) == 13 then
			lines[i] = string.sub(line, 1, len - 1)
		end
	end
	return lines
end

--- Disassembles binary Luau bytecode (`string` / `buffer`) or an in-memory `ProtoModule`.
local function disassemble(
	input: string | buffer | Types.ProtoModule,
	dumpFlags: number?,
	source: string?,
	decoder: Types.BytecodeDecoder?
): string
	if
		dumpFlags ~= nil
		and (type(dumpFlags) ~= "number" or dumpFlags ~= dumpFlags or dumpFlags ~= math.floor(dumpFlags))
	then
		error("disassemble dumpFlags must be an integer", 2)
	end
	if source ~= nil and type(source) ~= "string" then
		error("disassemble source must be a string", 2)
	end
	if
		decoder ~= nil
		and type(decoder) ~= "function"
		and not (type(decoder) == "table" and type((decoder :: any).decode) == "function")
	then
		error("disassemble decoder must be a function or { decode = function }", 2)
	end
	local modAny: any
	if type(input) == "string" or type(input) == "buffer" then
		local mod, errMsg = BytecodeCodec.deserialize(input, decoder)
		if mod == nil then
			error(errMsg :: string, 0)
		end
		modAny = mod
	elseif type(input) == "table" then
		modAny = input
	else
		error("expected bytecode string, buffer, or ProtoModule", 2)
	end

	local flags: number = if dumpFlags == nil then DumpFlags.Code else dumpFlags
	local modStrings: any = modAny.strings
	local stringList: { string } = {}
	if type(modStrings) == "table" then
		for idx = 1, #modStrings do
			local s = modStrings[idx]
			stringList[idx] = if type(s) == "string" then s else ""
		end
	end
	local stringMap: { [string]: number } = {}
	for idx = 1, #stringList do
		stringMap[stringList[idx]] = idx
	end
	local function addStr(s: any): number
		if type(s) ~= "string" or s == "" then
			return 0
		end
		local existing = stringMap[s]
		if existing ~= nil then
			return existing
		end
		local idx = #stringList + 1
		stringList[idx] = s
		stringMap[s] = idx
		return idx
	end

	local userdataViews: { [number]: { name: string, nameRef: number, used: boolean } } = {}
	local modUd: any = modAny.userdataTypes
	if type(modUd) == "table" then
		for idx, udName in modUd do
			if type(idx) == "number" and type(udName) == "string" then
				userdataViews[idx] = { name = udName, nameRef = 1, used = true }
			end
		end
	end

	local protos: { any } = if type(modAny.protos) == "table" then modAny.protos else {}
	local protoCount = #protos
	local funcViews: { any } = table.create(protoCount)
	for i = 1, protoCount do
		local p = protos[i]
		local pTbl = if type(p) == "table" then p else {}
		funcViews[i] = {
			dumpname = if type(pTbl.debugname) == "string" then pTbl.debugname else "",
			linedefined = if type(pTbl.linedefined) == "number" then pTbl.linedefined else 0,
			typeinfo = "",
		}
	end

	local view: any = {
		dumpFlags = flags,
		dumpSourceLines = if source ~= nil then splitDumpSourceLines(source) else nil,
		debugRemarks = {},
		stringList = stringList,
		userdataTypes = userdataViews,
		functions = funcViews,
		currentFunction = 0,
		insnBuf = buffer.create(0),
		lineBuf = buffer.create(0),
		insnCount = 0,
		constTypes = {},
		constVals = {},
		tableShapes = {},
		classShapes = {},
		typedUpvalTypes = {},
		typedUpvalCount = 0,
		typedLocalTypes = {},
		typedLocalRegs = {},
		typedLocalStartPcs = {},
		typedLocalEndPcs = {},
		typedLocalCount = 0,
		debugLocalNames = {},
		debugLocalRegs = {},
		debugLocalStartPcs = {},
		debugLocalEndPcs = {},
		debugLocalCount = 0,
		debugUpvalNames = {},
		debugUpvalCount = 0,
	}

	local wantTypes = btest(flags, DumpFlags.Types)
	local wantLocals = btest(flags, DumpFlags.Locals)
	local wantLines = btest(flags, DumpFlags.Lines) or btest(flags, DumpFlags.Source)

	local parts: { string } = table.create(protoCount) :: { string }
	for i = 1, protoCount do
		local rawProto = protos[i]
		local p = if type(rawProto) == "table" then rawProto else {}
		local fv = funcViews[i]
		view.currentFunction = i - 1

		local code: { number } = if type(p.code) == "table" then p.code else {}
		local insnCount = #code
		view.insnCount = insnCount
		local insnBuf = buffer.create(insnCount * 4)
		for ci = 1, insnCount do
			local word = code[ci]
			buffer.writeu32(insnBuf, (ci - 1) * 4, if type(word) == "number" then word else 0)
		end
		view.insnBuf = insnBuf

		local lineBuf = buffer.create(insnCount * 4)
		if wantLines and insnCount > 0 and type(p.lineData) == "string" then
			local okLines, linfo, absinfo = pcall(BytecodeCodec.decodeLineInfo, p)
			local gap = p.linegaplog2
			if okLines and type(linfo) == "table" and type(absinfo) == "table" and type(gap) == "number" then
				for pc0 = 0, insnCount - 1 do
					local bval = absinfo[rshift(pc0, gap) + 1]
					local lval = linfo[pc0 + 1]
					local base: number = if type(bval) == "number" then bval else 0
					local line: number = base + (if type(lval) == "number" then lval else 0)
					buffer.writei32(lineBuf, pc0 * 4, line)
				end
			end
		end
		view.lineBuf = lineBuf

		local constTypes: { number } = {}
		local constVals: { any } = {}
		local tableShapes: { any } = {}
		local classShapes: { any } = {}
		local pkTypes: { any } = if type(p.kTypes) == "table" then p.kTypes else {}
		local pkValues: { any } = if type(p.kValues) == "table" then p.kValues else {}
		local Tags = BytecodeDefs.Tags
		for ki = 1, #pkTypes do
			local kt = pkTypes[ki]
			local kv = pkValues[ki]
			if kt == Tags.LBC_CONSTANT_NIL then
				constTypes[ki] = ConstantType.Nil
				constVals[ki] = false
			elseif kt == Tags.LBC_CONSTANT_BOOLEAN then
				constTypes[ki] = ConstantType.Boolean
				constVals[ki] = kv == true
			elseif kt == Tags.LBC_CONSTANT_NUMBER then
				constTypes[ki] = ConstantType.Number
				constVals[ki] = if type(kv) == "number" then kv else 0
			elseif kt == Tags.LBC_CONSTANT_VECTOR then
				constTypes[ki] = ConstantType.Vectorf
				constVals[ki] = kv
			elseif kt == Tags.LBC_CONSTANT_VECTORD then
				constTypes[ki] = ConstantType.Vectord
				constVals[ki] = kv
			elseif kt == Tags.LBC_CONSTANT_STRING then
				constTypes[ki] = ConstantType.String
				constVals[ki] = addStr(kv)
			elseif kt == Tags.LBC_CONSTANT_IMPORT then
				constTypes[ki] = ConstantType.Import
				constVals[ki] = if type(kv) == "number" then kv else 0
			elseif kt == Tags.LBC_CONSTANT_TABLE then
				constTypes[ki] = ConstantType.Table
				local sidx = #tableShapes
				local keys: { number } = if type(kv) == "table" and type(kv.keys) == "table" then kv.keys else {}
				tableShapes[sidx + 1] = {
					keys = keys,
					constants = {},
					length = if type(kv) == "table" and type(kv.length) == "number" then kv.length else #keys,
					hasConstants = false,
				}
				constVals[ki] = sidx
			elseif kt == Tags.LBC_CONSTANT_TABLE_WITH_CONSTANTS then
				constTypes[ki] = ConstantType.TableWithConstants
				local sidx = #tableShapes
				local keys: { number } = if type(kv) == "table" and type(kv.keys) == "table" then kv.keys else {}
				tableShapes[sidx + 1] = {
					keys = keys,
					constants = if type(kv) == "table" and type(kv.constants) == "table" then kv.constants else {},
					length = if type(kv) == "table" and type(kv.length) == "number" then kv.length else #keys,
					hasConstants = true,
				}
				constVals[ki] = sidx
			elseif kt == Tags.LBC_CONSTANT_CLOSURE then
				constTypes[ki] = ConstantType.Closure
				constVals[ki] = if type(kv) == "number" then kv else 0
			elseif kt == Tags.LBC_CONSTANT_CLASS_SHAPE then
				constTypes[ki] = ConstantType.Class
				local cidx = #classShapes
				local isTbl = type(kv) == "table"
				classShapes[cidx + 1] = {
					className = if isTbl and type(kv.className) == "number" then kv.className else 0,
					propertyNames = if isTbl and type(kv.propertyNames) == "table" then kv.propertyNames else {},
					methodNames = if isTbl and type(kv.methodNames) == "table" then kv.methodNames else {},
				}
				constVals[ki] = cidx
			else
				constTypes[ki] = ConstantType.Nil
				constVals[ki] = false
			end
		end
		view.constTypes = constTypes
		view.constVals = constVals
		view.tableShapes = tableShapes
		view.classShapes = classShapes

		view.typedUpvalCount = 0
		view.typedLocalCount = 0
		fv.typeinfo = ""
		if wantTypes and type(p.typeinfo) == "string" and #p.typeinfo > 0 then
			local tblob = p.typeinfo :: string
			if modAny.typesversion == 1 then
				fv.typeinfo = tblob
			else
				local blen = #tblob
				local pos = 1
				local rawLen, upvalCount, localCount: number
				rawLen, pos = readTypeBlobVarInt(tblob, pos)
				upvalCount, pos = readTypeBlobVarInt(tblob, pos)
				localCount, pos = readTypeBlobVarInt(tblob, pos)
				if rawLen > 0 and pos + rawLen - 1 <= blen then
					fv.typeinfo = string.sub(tblob, pos, pos + rawLen - 1)
					pos += rawLen
				end
				local tuTypes: { number } = view.typedUpvalTypes
				local tuCount = 0
				for _ = 1, upvalCount do
					if pos > blen then
						break
					end
					tuCount += 1
					tuTypes[tuCount] = string.byte(tblob, pos)
					pos += 1
				end
				view.typedUpvalCount = tuCount
				local tlTypes: { number } = view.typedLocalTypes
				local tlRegs: { number } = view.typedLocalRegs
				local tlStarts: { number } = view.typedLocalStartPcs
				local tlEnds: { number } = view.typedLocalEndPcs
				local tlCount = 0
				for _ = 1, localCount do
					if pos + 1 > blen then
						break
					end
					local lty = string.byte(tblob, pos)
					local lreg = string.byte(tblob, pos + 1)
					pos += 2
					local spc, delta: number
					spc, pos = readTypeBlobVarInt(tblob, pos)
					delta, pos = readTypeBlobVarInt(tblob, pos)
					tlCount += 1
					tlTypes[tlCount] = lty
					tlRegs[tlCount] = lreg
					tlStarts[tlCount] = spc
					tlEnds[tlCount] = spc + delta
				end
				view.typedLocalCount = tlCount
			end
		end

		view.debugLocalCount = 0
		view.debugUpvalCount = 0
		if wantLocals then
			local lvars: any = p.locvars
			if type(lvars) == "table" then
				local dlNames: { number } = view.debugLocalNames
				local dlRegs: { number } = view.debugLocalRegs
				local dlStarts: { number } = view.debugLocalStartPcs
				local dlEnds: { number } = view.debugLocalEndPcs
				local dlCount = 0
				for li = 1, #lvars do
					local lv = lvars[li]
					if type(lv) == "table" then
						dlCount += 1
						dlNames[dlCount] = addStr(lv.varname)
						dlRegs[dlCount] = if type(lv.reg) == "number" then lv.reg else 0
						dlStarts[dlCount] = if type(lv.startpc) == "number" then lv.startpc else 0
						dlEnds[dlCount] = if type(lv.endpc) == "number" then lv.endpc else 0
					end
				end
				view.debugLocalCount = dlCount
			end
			local uvals: any = p.upvalues
			if type(uvals) == "table" then
				local duNames: { number } = view.debugUpvalNames
				for ui = 1, #uvals do
					duNames[ui] = addStr(uvals[ui])
				end
				view.debugUpvalCount = #uvals
			end
		end

		parts[i] = dumpCurrentFunction(view)
	end

	return table.concat(parts)
end

return table.freeze({
	disassemble = disassemble,
	dumpConstantPair = dumpConstantPair,
	dumpInstruction = dumpInstruction,
	dumpCurrentFunction = dumpCurrentFunction,
	dumpTypeInfo = dumpTypeInfo,
	dumpSourceRemarks = dumpSourceRemarks,
})
