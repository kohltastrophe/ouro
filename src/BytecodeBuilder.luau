--!strict
-- Luau 0.748 BytecodeBuilder port.
-- Upstream Luau is MIT licensed. See ../LICENSE.md and ../UPSTREAM.json.
local BytecodeCodec = require("./BytecodeCodec")
local BytecodeDefs = require("./BytecodeDefs")
local Types = require("./Types")

local cachedDisassembler: any = nil
local function getDisassembler(): any
	if not cachedDisassembler then
		cachedDisassembler = require("./BytecodeDisassembler")
	end
	return cachedDisassembler
end

local Opcodes = BytecodeDefs.Opcodes
local opLengths = BytecodeDefs.opLengths
local isJumpD = BytecodeDefs.isJumpD
local isSkipC = BytecodeDefs.isSkipC
local isFastCall = BytecodeDefs.isFastCall
local Tags = BytecodeDefs.Tags
local ProtoFlags = BytecodeDefs.ProtoFlags
local FeedbackTypes = BytecodeDefs.FeedbackTypes
local CompilerFlags = BytecodeDefs.CompilerFlags

local band = bit32.band
local bor = bit32.bor
local bxor = bit32.bxor
local lshift = bit32.lshift
local rshift = bit32.rshift

local LOP_RETURN = Opcodes.LOP_RETURN
local LOP_JUMP = Opcodes.LOP_JUMP
local LOP_JUMPX = Opcodes.LOP_JUMPX

local kMaxConstantCount = 2 ^ 23
local kMaxClosureCount = 2 ^ 15
local kMaxTableShapeLength = 32

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

export type TableShape = {
	keys: { number },
	constants: { number },
	length: number,
	hasConstants: boolean,
}

export type ClassShape = {
	className: number,
	numPrivateInstanceProps: number?,
	numPrivateStaticProps: number?,
	propertyNames: { number },
	methodNames: { number },
}

export type Constant = {
	type: number,
	valueBoolean: boolean?,
	valueNumber: number?,
	valueVectorf: { number }?,
	valueVectord: { number }?,
	value: number?, -- string 1-based index, import iid, table shape 0-based index, closure fid, or class shape 0-based index
}

export type DebugLocal = {
	name: number,
	reg: number,
	startpc: number,
	endpc: number,
}

export type DebugUpval = {
	name: number,
}

export type TypedLocal = {
	type: number,
	reg: number,
	startpc: number,
	endpc: number,
}

export type TypedUpval = {
	type: number,
}

export type Jump = {
	source: number,
	target: number,
}

export type BytecodeBuilderOptions = {
	serializeBytes: boolean?,
	retainProto: boolean?,
}

export type Proto = Types.Proto
export type ProtoModule = Types.ProtoModule

export type BytecodeBuilderImpl = {
	functions: { any },
	currentFunction: number,
	mainFunction: number,
	insnBuf: buffer,
	lineBuf: buffer,
	insnCap: number,
	insnCount: number,
	constTypes: { number },
	constVals: { any },
	protos: { number },
	jumpSources: { number },
	jumpTargets: { number },
	tableShapes: { TableShape },
	classShapes: { ClassShape },
	hasLongJumps: boolean,
	constantMap: { [string]: number },
	nilConstant: number,
	trueConstant: number,
	falseConstant: number,
	posZeroConstant: number,
	negZeroConstant: number,
	numberConstantMap: { [number]: number },
	stringConstantMap: { [number]: number },
	importConstantMap: { [number]: number },
	closureConstantMap: { [number]: number },
	tableShapeMap: { [number]: number | { number } },
	protoMap: { [number]: number },
	stringTable: { [string]: number },
	stringList: { string },
	dirtyConstantMap: boolean,
	dirtyNumberMap: boolean,
	dirtyStringMap: boolean,
	dirtyImportMap: boolean,
	dirtyClosureMap: boolean,
	dirtyTableShapeMap: boolean,
	dirtyProtoMap: boolean,
	debugLine: number,
	hasZeroLine: boolean,
	hadUndoEmit: boolean,
	noDebugLines: boolean,
	debugLocalNames: { number },
	debugLocalRegs: { number },
	debugLocalStartPcs: { number },
	debugLocalEndPcs: { number },
	debugLocalCount: number,
	debugUpvalNames: { number },
	debugUpvalCount: number,
	typedLocalTypes: { number },
	typedLocalRegs: { number },
	typedLocalStartPcs: { number },
	typedLocalEndPcs: { number },
	typedLocalCount: number,
	typedUpvalTypes: { number },
	typedUpvalCount: number,
	userdataTypes: { { name: string, nameRef: number, used: boolean } },
	fbKinds: { number },
	fbData: { number },
	fbCount: number,
	debugRemarks: { { fid: number, line: number, text: string } },
	encoder: any?,
	serializeBytes: boolean,
	retainProto: boolean,
	finalized: boolean,
	funcWriter: any?,
	capturedProtos: { Proto }?,
	resolvedProtoModule: ProtoModule?,
	bytecode: string,
	dumpFlags: number,
	dumpSourceLines: { string }?,
	functionTypeInfo: string,
	flags: { [string]: any },
	customFlagKeys: { [string]: boolean }?,
	beginFunction: (self: BytecodeBuilderImpl, numparams: number, isvararg: boolean?) -> number,
	endFunction: (
		self: BytecodeBuilderImpl,
		maxstacksize: number,
		nups: number,
		flags: number?,
		costModelLo: number?,
		costModelHi: number?
	) -> (),
	setMainFunction: (self: BytecodeBuilderImpl, fid: number) -> (),
	addStringTableEntry: (self: BytecodeBuilderImpl, value: string?) -> number,
	addConstantNil: (self: BytecodeBuilderImpl) -> number,
	addConstantBoolean: (self: BytecodeBuilderImpl, value: boolean) -> number,
	addConstantNumber: (self: BytecodeBuilderImpl, value: number) -> number,
	addConstantVectorf: (self: BytecodeBuilderImpl, x: number, y: number, z: number, w: number?) -> number,
	addConstantVectord: (self: BytecodeBuilderImpl, x: number, y: number, z: number, w: number?) -> number,
	addConstantString: (self: BytecodeBuilderImpl, value: string) -> number,
	addConstantStringRef: (self: BytecodeBuilderImpl, strRef: number) -> number,
	addImport: (self: BytecodeBuilderImpl, iid: number) -> number,
	addConstantTable: (self: BytecodeBuilderImpl, shape: TableShape) -> number,
	addConstantClosure: (self: BytecodeBuilderImpl, fid: number) -> number,
	addClassShape: (self: BytecodeBuilderImpl, shape: ClassShape) -> number,
	addChildFunction: (self: BytecodeBuilderImpl, fid: number) -> number,
	emitABC: (self: BytecodeBuilderImpl, opc: number, a: number, b: number, c: number) -> (),
	emitAD: (self: BytecodeBuilderImpl, opc: number, a: number, d: number) -> (),
	emitE: (self: BytecodeBuilderImpl, opc: number, e: number) -> (),
	emitAux: (self: BytecodeBuilderImpl, aux: number) -> (),
	undoEmit: (self: BytecodeBuilderImpl, opc: number) -> (),
	lastInstruction: (self: BytecodeBuilderImpl) -> number,
	emitLabel: (self: BytecodeBuilderImpl) -> number,
	patchJumpD: (self: BytecodeBuilderImpl, jumpLabel: number, targetLabel: number) -> boolean,
	patchSkipC: (self: BytecodeBuilderImpl, jumpLabel: number, targetLabel: number) -> boolean,
	patchAux: (self: BytecodeBuilderImpl, auxLabel: number, value: number) -> (),
	foldJumps: (self: BytecodeBuilderImpl) -> (),
	expandJumps: (self: BytecodeBuilderImpl) -> boolean,
	setDebugFunctionName: (self: BytecodeBuilderImpl, name: string?) -> (),
	setDebugFunctionLineDefined: (self: BytecodeBuilderImpl, line: number) -> (),
	setDebugLine: (self: BytecodeBuilderImpl, line: number) -> (),
	pushDebugLocal: (
		self: BytecodeBuilderImpl,
		name: string?,
		reg: number,
		startpc: number,
		endpc: number
	) -> (),
	pushDebugUpval: (self: BytecodeBuilderImpl, name: string?) -> (),
	getInstructionCount: (self: BytecodeBuilderImpl) -> number,
	pushLocalTypeInfo: (
		self: BytecodeBuilderImpl,
		ty: number,
		reg: number,
		startpc: number,
		endpc: number
	) -> (),
	pushUpvalTypeInfo: (self: BytecodeBuilderImpl, ty: number) -> (),
	setFunctionTypeInfo: (self: BytecodeBuilderImpl, value: string) -> (),
	addUserdataType: (self: BytecodeBuilderImpl, name: string) -> number,
	useUserdataType: (self: BytecodeBuilderImpl, index: number) -> (),
	addCallTargetSlot: (self: BytecodeBuilderImpl, pc: number) -> number,
	addConstructSlot: (self: BytecodeBuilderImpl, tableShapeCid: number) -> number,
	needsDebugRemarks: (self: BytecodeBuilderImpl) -> boolean,
	addDebugRemark: (self: BytecodeBuilderImpl, format: string, ...any) -> (),
	writeLineInfo: (self: BytecodeBuilderImpl, writer: any, _func: any) -> (number, number, number),
	buildTypeInfoBlob: (self: BytecodeBuilderImpl, rawTypeInfo: string) -> string,
	writeFunction: (self: BytecodeBuilderImpl, func: any, hasLinesArg: boolean?) -> (number?, number?, number),
	captureProto: (
		self: BytecodeBuilderImpl,
		funcId: number,
		func: any,
		hasLines: boolean,
		cachedGap: number?,
		cachedLineStart: number?,
		cachedLineLen: number?
	) -> (),
	getVersion: (self: BytecodeBuilderImpl) -> number,
	finalize: (self: BytecodeBuilderImpl) -> (),
	getBytecode: (self: BytecodeBuilderImpl) -> string,
	setDumpFlags: (self: BytecodeBuilderImpl, flags: number) -> (),
	setDumpSource: (self: BytecodeBuilderImpl, source: string) -> (),
	dumpCurrentFunction: (self: BytecodeBuilderImpl) -> string,
	dumpFunction: (self: BytecodeBuilderImpl, fid: number) -> string,
	dumpEverything: (self: BytecodeBuilderImpl) -> string,
	dumpSourceRemarks: (self: BytecodeBuilderImpl) -> string,
	dumpTypeInfo: (self: BytecodeBuilderImpl) -> string,
	toProtoModule: (self: BytecodeBuilderImpl) -> ProtoModule,
	setNoDebugLines: (self: BytecodeBuilderImpl, enabled: boolean) -> (),
	reset: (self: BytecodeBuilderImpl, encoder: any?, options: BytecodeBuilderOptions?) -> (),
}

local scratchBuf = buffer.create(264)

local insnOp = BytecodeCodec.insnOp
local insnC = BytecodeCodec.insnC
local insnD = BytecodeCodec.insnD

@native
local function varIntSize(v: number): number
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

@native
local function writeVarInt64ToBuf(buf: buffer, pos: number, lo: number, hi: number): number
	local curLo = lo % 0x100000000
	local curHi = hi % 0x100000000
	repeat
		local byte = band(curLo, 127)
		curLo = bor(rshift(curLo, 7), lshift(band(curHi, 127), 25))
		curHi = rshift(curHi, 7)
		if curLo ~= 0 or curHi ~= 0 then
			byte = bor(byte, 128)
		end
		buffer.writeu8(buf, pos, byte)
		pos += 1
	until curLo == 0 and curHi == 0
	return pos
end

type BufferWriter = {
	buf: buffer,
	offset: number,
	cap: number,
}

@native
local function ensureWriter(self: BufferWriter, extra: number)
	local pos = self.offset
	local cap = self.cap
	if pos + extra > cap then
		while pos + extra > cap do
			cap *= 2
		end
		local nextBuf = buffer.create(cap)
		buffer.copy(nextBuf, 0, self.buf, 0, pos)
		self.buf = nextBuf
		self.cap = cap
	end
end

@native
local function writeByte(self: BufferWriter, v: number)
	ensureWriter(self, 1)
	local pos = self.offset
	buffer.writeu8(self.buf, pos, band(v, 0xff))
	self.offset = pos + 1
end

@native
local function writeVarInt(self: BufferWriter, v: number)
	ensureWriter(self, 5)
	self.offset = writeVarIntToBuf(self.buf, self.offset, v)
end

@native
local function writeUIntArray(self: BufferWriter, arr: { number }, count: number)
	ensureWriter(self, count * 4)
	local buf = self.buf
	local pos = self.offset
	for i = 1, count do
		buffer.writeu32(buf, pos, arr[i])
		pos += 4
	end
	self.offset = pos
end

local function newBufferWriter(initialCapacity: number?): BufferWriter
	local cap = math.max(1, initialCapacity or 4096)
	return {
		buf = buffer.create(cap),
		offset = 0,
		cap = cap,
	}
end

local BytecodeBuilder = {}
BytecodeBuilder.__index = BytecodeBuilder

BytecodeBuilder.ConstantType = ConstantType
BytecodeBuilder.DumpFlags = DumpFlags
BytecodeBuilder.kMaxConstantCount = kMaxConstantCount
BytecodeBuilder.kMaxClosureCount = kMaxClosureCount
BytecodeBuilder.kMaxTableShapeLength = kMaxTableShapeLength

function BytecodeBuilder.newTableShape(): TableShape
	return {
		keys = {},
		constants = {},
		length = 0,
		hasConstants = false,
	}
end

--- Creates a new BytecodeBuilder with optional instruction encoder, compiler flags, and output options.
function BytecodeBuilder.new(
	encoder: any?,
	flags: { [string]: any }?,
	options: BytecodeBuilderOptions?
): BytecodeBuilderImpl
	local resolvedFlags: { [string]: any }
	local customFlagKeys: { [string]: boolean }? = nil
	if flags == nil then
		resolvedFlags = CompilerFlags :: { [string]: any }
	else
		resolvedFlags = table.clone(CompilerFlags :: { [string]: any })
		customFlagKeys = {}
		for k, v in flags do
			resolvedFlags[k] = v;
			(customFlagKeys :: { [string]: boolean })[k] = true
		end
	end

	local serializeBytes = if options ~= nil and options.serializeBytes ~= nil then options.serializeBytes else true
	local retainProto = if options ~= nil and options.retainProto ~= nil then options.retainProto else false
	local initCap = 256

	local self = setmetatable({
		functions = {},
		currentFunction = -1,
		mainFunction = -1,

		insnBuf = buffer.create(initCap * 4),
		lineBuf = buffer.create(initCap * 4),
		insnCap = initCap,
		insnCount = 0,
		constTypes = {},
		constVals = {},
		protos = {},
		jumpSources = {},
		jumpTargets = {},

		tableShapes = {},
		classShapes = {},

		hasLongJumps = false,

		constantMap = {},
		nilConstant = -1,
		trueConstant = -1,
		falseConstant = -1,
		posZeroConstant = -1,
		negZeroConstant = -1,
		numberConstantMap = {},
		stringConstantMap = {},
		importConstantMap = {},
		closureConstantMap = {},
		tableShapeMap = {},
		protoMap = {},
		stringTable = {},
		stringList = {},

		dirtyConstantMap = false,
		dirtyNumberMap = false,
		dirtyStringMap = false,
		dirtyImportMap = false,
		dirtyClosureMap = false,
		dirtyTableShapeMap = false,
		dirtyProtoMap = false,

		debugLine = 0,
		hasZeroLine = false,
		hadUndoEmit = false,
		noDebugLines = false,

		debugLocalNames = {},
		debugLocalRegs = {},
		debugLocalStartPcs = {},
		debugLocalEndPcs = {},
		debugLocalCount = 0,

		debugUpvalNames = {},
		debugUpvalCount = 0,

		typedLocalTypes = {},
		typedLocalRegs = {},
		typedLocalStartPcs = {},
		typedLocalEndPcs = {},
		typedLocalCount = 0,

		typedUpvalTypes = {},
		typedUpvalCount = 0,

		userdataTypes = {},

		fbKinds = {},
		fbData = {},
		fbCount = 0,

		debugRemarks = {},

		encoder = encoder,
		serializeBytes = serializeBytes,
		retainProto = retainProto,
		finalized = false,
		funcWriter = if serializeBytes then newBufferWriter(4096) else nil,
		capturedProtos = if retainProto then {} else nil,
		resolvedProtoModule = nil,
		bytecode = "",
		dumpFlags = 0,
		dumpSourceLines = nil,
		functionTypeInfo = "",
		flags = resolvedFlags,
		customFlagKeys = customFlagKeys,
	}, BytecodeBuilder)

	return (self :: any) :: BytecodeBuilderImpl
end

function BytecodeBuilder.setNoDebugLines(self: BytecodeBuilderImpl, enabled: boolean)
	self.noDebugLines = enabled
end

function BytecodeBuilder.reset(self: BytecodeBuilderImpl, encoder: any?, options: BytecodeBuilderOptions?)
	local serializeBytes = if options ~= nil and options.serializeBytes ~= nil then options.serializeBytes else true
	local retainProto = if options ~= nil and options.retainProto ~= nil then options.retainProto else false

	if #self.functions > 0 then
		table.clear(self.functions)
	end
	self.currentFunction = -1
	self.mainFunction = -1
	self.insnCount = 0
	if #self.constTypes > 0 then
		table.clear(self.constTypes)
		table.clear(self.constVals)
	end
	if #self.protos > 0 then
		table.clear(self.protos)
	end
	if #self.jumpSources > 0 then
		table.clear(self.jumpSources)
		table.clear(self.jumpTargets)
	end
	if #self.tableShapes > 0 then
		table.clear(self.tableShapes)
	end
	if #self.classShapes > 0 then
		table.clear(self.classShapes)
	end
	self.hasLongJumps = false

	if self.dirtyConstantMap or next(self.constantMap) ~= nil then
		table.clear(self.constantMap)
		self.dirtyConstantMap = false
	end
	self.nilConstant = -1
	self.trueConstant = -1
	self.falseConstant = -1
	self.posZeroConstant = -1
	self.negZeroConstant = -1
	if self.dirtyNumberMap or next(self.numberConstantMap) ~= nil then
		table.clear(self.numberConstantMap)
		self.dirtyNumberMap = false
	end
	if self.dirtyStringMap or next(self.stringConstantMap) ~= nil then
		table.clear(self.stringConstantMap)
		self.dirtyStringMap = false
	end
	if self.dirtyImportMap or next(self.importConstantMap) ~= nil then
		table.clear(self.importConstantMap)
		self.dirtyImportMap = false
	end
	if self.dirtyClosureMap or next(self.closureConstantMap) ~= nil then
		table.clear(self.closureConstantMap)
		self.dirtyClosureMap = false
	end
	if self.dirtyTableShapeMap or next(self.tableShapeMap) ~= nil then
		table.clear(self.tableShapeMap)
		self.dirtyTableShapeMap = false
	end
	if self.dirtyProtoMap or next(self.protoMap) ~= nil then
		table.clear(self.protoMap)
		self.dirtyProtoMap = false
	end
	if next(self.stringTable) ~= nil then
		table.clear(self.stringTable)
	end
	if #self.stringList > 0 then
		table.clear(self.stringList)
	end

	self.debugLine = 0
	self.hasZeroLine = false
	self.hadUndoEmit = false
	self.noDebugLines = false
	self.debugLocalCount = 0
	self.debugUpvalCount = 0
	self.typedLocalCount = 0
	self.typedUpvalCount = 0
	if #self.userdataTypes > 0 then
		table.clear(self.userdataTypes)
	end
	self.fbCount = 0
	if #self.debugRemarks > 0 then
		table.clear(self.debugRemarks)
	end

	self.encoder = encoder
	self.serializeBytes = serializeBytes
	self.retainProto = retainProto
	self.finalized = false
	if serializeBytes then
		if self.funcWriter ~= nil then
			(self.funcWriter :: BufferWriter).offset = 0
		else
			self.funcWriter = newBufferWriter(4096)
		end
	else
		self.funcWriter = nil
	end
	self.capturedProtos = if retainProto then {} else nil
	self.resolvedProtoModule = nil
	self.bytecode = ""
	self.dumpFlags = 0
	self.dumpSourceLines = nil
	self.functionTypeInfo = ""
	self.flags = CompilerFlags :: { [string]: any }
	self.customFlagKeys = nil
end

function BytecodeBuilder.beginFunction(self: BytecodeBuilderImpl, numparams: number, isvararg: boolean?): number
	assert(self.currentFunction == -1, "already inside a function")

	local id = #self.functions
	local func = {
		dataOffset = 0,
		dataLen = 0,
		maxstacksize = 0,
		numparams = numparams,
		nups = 0,
		isvararg = isvararg == true,
		flags = 0,
		debugname = 0,
		typeinfo = "",
		dump = "",
		dumpname = "",
		linedefined = 0,
		costModelLo = 0,
		costModelHi = 0,
	}
	self.functions[id + 1] = func
	self.currentFunction = id

	assert(self.insnCount == 0, "expected empty insns")
	assert(#self.constTypes == 0, "expected empty constants")
	assert(#self.protos == 0, "expected empty protos")
	assert(#self.jumpSources == 0, "expected empty jumps")
	assert(#self.tableShapes == 0, "expected empty tableShapes")
	assert(self.debugLocalCount == 0, "expected empty debugLocals")
	assert(self.debugUpvalCount == 0, "expected empty debugUpvals")
	assert(self.typedLocalCount == 0, "expected empty typedLocals")
	assert(self.typedUpvalCount == 0, "expected empty typedUpvals")
	assert(#self.functionTypeInfo == 0, "expected empty functionTypeInfo")
	assert(self.fbCount == 0, "expected empty feedback slots")

	self.hasLongJumps = false
	self.debugLine = 0
	self.hasZeroLine = false
	self.hadUndoEmit = false

	return id
end

@native
local function checkHasLines(self: BytecodeBuilderImpl): boolean
	local insnCount = self.insnCount
	if self.noDebugLines or insnCount == 0 then
		return false
	end
	if not self.hasZeroLine then
		return true
	end
	if not self.hadUndoEmit then
		return false
	end
	local lineBuf = self.lineBuf
	for i = 0, insnCount - 1 do
		if buffer.readi32(lineBuf, i * 4) == 0 then
			return false
		end
	end
	return true
end

function BytecodeBuilder.endFunction(
	self: BytecodeBuilderImpl,
	maxstacksize: number,
	nups: number,
	flags: number?,
	costModelLo: number?,
	costModelHi: number?
)
	assert(self.currentFunction >= 0, "not inside a function")

	local func = self.functions[self.currentFunction + 1]
	func.maxstacksize = maxstacksize
	func.nups = nups
	func.flags = flags or 0
	func.costModelLo = costModelLo or 0
	func.costModelHi = costModelHi or 0
	func.typeinfo = self.functionTypeInfo
	self.functionTypeInfo = ""

	if self.dumpFlags ~= 0 then
		func.dump = getDisassembler().dumpCurrentFunction(self)
	end

	local hasLines = checkHasLines(self)

	local cachedGap: number? = nil
	local cachedLineStart: number? = nil
	local cachedLineLen = 0
	if self.serializeBytes then
		cachedGap, cachedLineStart, cachedLineLen = self:writeFunction(func, hasLines)
	elseif self.retainProto or self.dumpFlags ~= 0 then
		func.typeinfo = self:buildTypeInfoBlob(func.typeinfo)
	else
		func.typeinfo = ""
	end

	if self.retainProto then
		self:captureProto(self.currentFunction, func, hasLines, cachedGap, cachedLineStart, cachedLineLen)
	end

	self.insnCount = 0
	if #self.constTypes > 0 then
		table.clear(self.constTypes)
		table.clear(self.constVals)
		if #self.tableShapes > 0 then
			table.clear(self.tableShapes)
		end
		if #self.classShapes > 0 then
			table.clear(self.classShapes)
		end
		if self.dirtyConstantMap then
			table.clear(self.constantMap)
			self.dirtyConstantMap = false
		end
		if self.dirtyNumberMap then
			table.clear(self.numberConstantMap)
			self.dirtyNumberMap = false
		end
		if self.dirtyStringMap then
			table.clear(self.stringConstantMap)
			self.dirtyStringMap = false
		end
		if self.dirtyImportMap then
			table.clear(self.importConstantMap)
			self.dirtyImportMap = false
		end
		if self.dirtyClosureMap then
			table.clear(self.closureConstantMap)
			self.dirtyClosureMap = false
		end
		if self.dirtyTableShapeMap then
			table.clear(self.tableShapeMap)
			self.dirtyTableShapeMap = false
		end
	end
	if #self.protos > 0 then
		table.clear(self.protos)
	end
	if self.dirtyProtoMap then
		table.clear(self.protoMap)
		self.dirtyProtoMap = false
	end
	self.debugLocalCount = 0
	self.debugUpvalCount = 0
	self.typedLocalCount = 0
	self.typedUpvalCount = 0
	if #self.jumpSources > 0 then
		table.clear(self.jumpSources)
		table.clear(self.jumpTargets)
	end
	self.fbCount = 0

	self.currentFunction = -1
	self.hasZeroLine = false
	self.hadUndoEmit = false
	self.nilConstant = -1
	self.trueConstant = -1
	self.falseConstant = -1
	self.posZeroConstant = -1
	self.negZeroConstant = -1
end

function BytecodeBuilder.setMainFunction(self: BytecodeBuilderImpl, fid: number)
	assert(fid >= 0 and fid < #self.functions, "invalid main function id")
	self.mainFunction = fid
end

@native
function BytecodeBuilder.addStringTableEntry(self: BytecodeBuilderImpl, value: string?): number
	if value == nil then
		return 0
	end
	local existing = self.stringTable[value]
	if existing then
		return existing
	end
	local index = #self.stringList + 1
	self.stringTable[value] = index
	self.stringList[index] = value
	return index
end

@native
local function appendConstant(self: BytecodeBuilderImpl, ctype: number, val: any): number
	local constTypes = self.constTypes
	local id = #constTypes
	if id >= kMaxConstantCount then
		return -1
	end
	local idx1 = id + 1
	constTypes[idx1] = ctype
	self.constVals[idx1] = val
	return id
end

@native
local function allocKeyedConstant(self: BytecodeBuilderImpl, key: string, ctype: number, val: any): number
	local id = appendConstant(self, ctype, val)
	if id >= 0 then
		self.constantMap[key] = id
		self.dirtyConstantMap = true
	end
	return id
end

@native
function BytecodeBuilder.addConstantNil(self: BytecodeBuilderImpl): number
	local existing = self.nilConstant
	if existing >= 0 then
		return existing
	end
	local id = appendConstant(self, ConstantType.Nil, false)
	if id >= 0 then
		self.nilConstant = id
	end
	return id
end

@native
function BytecodeBuilder.addConstantBoolean(self: BytecodeBuilderImpl, value: boolean): number
	if value then
		local existing = self.trueConstant
		if existing >= 0 then
			return existing
		end
		local id = appendConstant(self, ConstantType.Boolean, true)
		if id >= 0 then
			self.trueConstant = id
		end
		return id
	else
		local existing = self.falseConstant
		if existing >= 0 then
			return existing
		end
		local id = appendConstant(self, ConstantType.Boolean, false)
		if id >= 0 then
			self.falseConstant = id
		end
		return id
	end
end

@native
function BytecodeBuilder.addConstantNumber(self: BytecodeBuilderImpl, value: number): number
	if value == value then
		if value == 0 then
			if 1 / value < 0 then
				local existing = self.negZeroConstant
				if existing >= 0 then
					return existing
				end
				local id = appendConstant(self, ConstantType.Number, value)
				if id >= 0 then
					self.negZeroConstant = id
				end
				return id
			else
				local existing = self.posZeroConstant
				if existing >= 0 then
					return existing
				end
				local id = appendConstant(self, ConstantType.Number, 0)
				if id >= 0 then
					self.posZeroConstant = id
				end
				return id
			end
		end
		local existing = self.numberConstantMap[value]
		if existing ~= nil then
			return existing
		end
		local id = appendConstant(self, ConstantType.Number, value)
		if id >= 0 then
			self.numberConstantMap[value] = id
			self.dirtyNumberMap = true
		end
		return id
	end
	buffer.writeu8(scratchBuf, 0, ConstantType.Number)
	buffer.writef64(scratchBuf, 1, value)
	local key = buffer.readstring(scratchBuf, 0, 9)
	local existing = self.constantMap[key]
	if existing ~= nil then
		return existing
	end
	return allocKeyedConstant(self, key, ConstantType.Number, value)
end

@native
function BytecodeBuilder.addConstantVectorf(
	self: BytecodeBuilderImpl,
	x: number,
	y: number,
	z: number,
	w: number?
): number
	local wz = w or 0
	buffer.writeu8(scratchBuf, 0, ConstantType.Vectorf)
	buffer.writef32(scratchBuf, 1, x)
	buffer.writef32(scratchBuf, 5, y)
	buffer.writef32(scratchBuf, 9, z)
	buffer.writef32(scratchBuf, 13, wz)
	local key = buffer.readstring(scratchBuf, 0, 17)
	local existing = self.constantMap[key]
	if existing ~= nil then
		return existing
	end
	return allocKeyedConstant(self, key, ConstantType.Vectorf, {
		buffer.readf32(scratchBuf, 1),
		buffer.readf32(scratchBuf, 5),
		buffer.readf32(scratchBuf, 9),
		buffer.readf32(scratchBuf, 13),
	})
end

@native
function BytecodeBuilder.addConstantVectord(
	self: BytecodeBuilderImpl,
	x: number,
	y: number,
	z: number,
	w: number?
): number
	local wz = w or 0
	buffer.writeu8(scratchBuf, 0, ConstantType.Vectord)
	buffer.writef64(scratchBuf, 1, x)
	buffer.writef64(scratchBuf, 9, y)
	buffer.writef64(scratchBuf, 17, z)
	buffer.writef64(scratchBuf, 25, wz)
	local key = buffer.readstring(scratchBuf, 0, 33)
	local existing = self.constantMap[key]
	if existing ~= nil then
		return existing
	end
	return allocKeyedConstant(self, key, ConstantType.Vectord, { x, y, z, wz })
end

@native
function BytecodeBuilder.addConstantString(self: BytecodeBuilderImpl, value: string): number
	local stringTable = self.stringTable
	local strRef = stringTable[value]
	if strRef == nil then
		strRef = #self.stringList + 1
		stringTable[value] = strRef
		self.stringList[strRef] = value
	end
	local map = self.stringConstantMap
	local existing = map[strRef]
	if existing ~= nil then
		return existing
	end
	local id = appendConstant(self, ConstantType.String, strRef)
	if id >= 0 then
		map[strRef] = id
		self.dirtyStringMap = true
	end
	return id
end

@native
function BytecodeBuilder.addConstantStringRef(self: BytecodeBuilderImpl, strRef: number): number
	local map = self.stringConstantMap
	local existing = map[strRef]
	if existing ~= nil then
		return existing
	end
	local id = appendConstant(self, ConstantType.String, strRef)
	if id >= 0 then
		map[strRef] = id
		self.dirtyStringMap = true
	end
	return id
end

@native
function BytecodeBuilder.addImport(self: BytecodeBuilderImpl, iid: number): number
	local map = self.importConstantMap
	local existing = map[iid]
	if existing ~= nil then
		return existing
	end
	local id = appendConstant(self, ConstantType.Import, iid)
	if id >= 0 then
		map[iid] = id
		self.dirtyImportMap = true
	end
	return id
end

@native
local function mul32(a: number, b: number): number
	local lo = band(a, 0xffff) * b
	local hi = band(rshift(a, 16) * b, 0xffff)
	return (lo + hi * 65536) % 4294967296
end

@native
local function hashTableShape(keys: { number }, consts: { number }?, len: number, hasConstants: boolean): number
	local h = 2166136261
	h = mul32(bxor(h, len), 16777619)
	h = mul32(bxor(h, if hasConstants then 1 else 0), 16777619)
	for i = 1, len do
		h = mul32(bxor(h, band(keys[i], 0xffffffff)), 16777619)
	end
	if hasConstants and consts then
		for i = 1, len do
			h = mul32(bxor(h, band(consts[i], 0xffffffff)), 16777619)
		end
	end
	return h
end

@native
local function tableShapeMatches(
	existing: TableShape,
	keys: { number },
	consts: { number }?,
	len: number,
	hasConstants: boolean
): boolean
	if existing.length ~= len or existing.hasConstants ~= hasConstants then
		return false
	end
	local ekeys = existing.keys
	for i = 1, len do
		if ekeys[i] ~= keys[i] then
			return false
		end
	end
	if hasConstants then
		local econsts = existing.constants
		local sconsts = consts :: { number }
		for i = 1, len do
			if econsts[i] ~= sconsts[i] then
				return false
			end
		end
	end
	return true
end

@native
function BytecodeBuilder.addConstantTable(self: BytecodeBuilderImpl, shape: TableShape): number
	local len = shape.length
	local hasConstants = shape.hasConstants == true
	local keys = shape.keys
	local consts = shape.constants
	local h = hashTableShape(keys, consts, len, hasConstants)

	local tableShapeMap = self.tableShapeMap
	local tableShapes = self.tableShapes
	local constVals = self.constVals
	local bucket = tableShapeMap[h]

	if type(bucket) == "number" then
		local existingShape = tableShapes[(constVals[bucket + 1] :: number) + 1]
		if tableShapeMatches(existingShape, keys, consts, len, hasConstants) then
			return bucket
		end
	elseif bucket ~= nil then
		local bucketList = bucket :: { number }
		for i = 1, #bucketList do
			local cid = bucketList[i]
			local existingShape = tableShapes[(constVals[cid + 1] :: number) + 1]
			if tableShapeMatches(existingShape, keys, consts, len, hasConstants) then
				return cid
			end
		end
	end

	local shapeIdx = #tableShapes
	local ctype = if hasConstants then ConstantType.TableWithConstants else ConstantType.Table
	local cid = appendConstant(self, ctype, shapeIdx)
	if cid < 0 then
		return -1
	end

	local keysCopy: { number } = table.create(len) :: { number }
	table.move(keys, 1, len, 1, keysCopy)
	local constsCopy: { number }
	if hasConstants and consts then
		constsCopy = table.create(len) :: { number }
		table.move(consts, 1, len, 1, constsCopy)
	else
		constsCopy = {}
	end
	tableShapes[shapeIdx + 1] = {
		keys = keysCopy,
		constants = constsCopy,
		length = len,
		hasConstants = hasConstants,
	}

	if bucket == nil then
		tableShapeMap[h] = cid
	elseif type(bucket) == "number" then
		tableShapeMap[h] = { bucket, cid }
	else
		local bucketList = bucket :: { number }
		bucketList[#bucketList + 1] = cid
	end
	self.dirtyTableShapeMap = true
	return cid
end

@native
function BytecodeBuilder.addConstantClosure(self: BytecodeBuilderImpl, fid: number): number
	local map = self.closureConstantMap
	local existing = map[fid]
	if existing ~= nil then
		return existing
	end
	local id = appendConstant(self, ConstantType.Closure, fid)
	if id >= 0 then
		map[fid] = id
		self.dirtyClosureMap = true
	end
	return id
end

function BytecodeBuilder.addClassShape(self: BytecodeBuilderImpl, shape: ClassShape): number
	local constTypes = self.constTypes
	local cid = #constTypes
	if cid >= kMaxConstantCount then
		return -1
	end
	local shapeIdx = #self.classShapes
	self.classShapes[shapeIdx + 1] = {
		className = shape.className,
		numPrivateInstanceProps = shape.numPrivateInstanceProps or 0,
		numPrivateStaticProps = shape.numPrivateStaticProps or 0,
		propertyNames = table.clone(shape.propertyNames),
		methodNames = table.clone(shape.methodNames),
	}
	local idx1 = cid + 1
	constTypes[idx1] = ConstantType.Class
	self.constVals[idx1] = shapeIdx
	return cid
end

@native
function BytecodeBuilder.addChildFunction(self: BytecodeBuilderImpl, fid: number): number
	local existing = self.protoMap[fid]
	if existing ~= nil then
		return existing
	end
	local pid = #self.protos
	if pid >= kMaxClosureCount then
		return -1
	end
	self.protoMap[fid] = pid
	self.dirtyProtoMap = true
	self.protos[pid + 1] = fid
	return pid
end

@native
local function ensureInsnCapacity(self: BytecodeBuilderImpl, needCount: number)
	local cap = self.insnCap
	if needCount > cap then
		while needCount > cap do
			cap *= 2
		end
		local nextInsnBuf = buffer.create(cap * 4)
		local nextLineBuf = buffer.create(cap * 4)
		local byteCount = self.insnCount * 4
		if byteCount > 0 then
			buffer.copy(nextInsnBuf, 0, self.insnBuf, 0, byteCount)
			if not self.noDebugLines then
				buffer.copy(nextLineBuf, 0, self.lineBuf, 0, byteCount)
			end
		end
		self.insnBuf = nextInsnBuf
		self.lineBuf = nextLineBuf
		self.insnCap = cap
	end
end

@native
function BytecodeBuilder.emitABC(self: BytecodeBuilderImpl, opc: number, a: number, b: number, c: number)
	local insn = bor(band(opc, 0xff), lshift(band(a, 0xff), 8), lshift(band(b, 0xff), 16), lshift(band(c, 0xff), 24))
	local idx = self.insnCount
	local nextCount = idx + 1
	if nextCount > self.insnCap then
		ensureInsnCapacity(self, nextCount)
	end
	local off = idx * 4
	buffer.writeu32(self.insnBuf, off, insn)
	if not self.noDebugLines then
		local line = self.debugLine
		buffer.writei32(self.lineBuf, off, line)
		if line == 0 then
			self.hasZeroLine = true
		end
	end
	self.insnCount = nextCount
end

@native
function BytecodeBuilder.emitAD(self: BytecodeBuilderImpl, opc: number, a: number, d: number)
	local insn = bor(band(opc, 0xff), lshift(band(a, 0xff), 8), lshift(band(d, 0xffff), 16))
	local idx = self.insnCount
	local nextCount = idx + 1
	if nextCount > self.insnCap then
		ensureInsnCapacity(self, nextCount)
	end
	local off = idx * 4
	buffer.writeu32(self.insnBuf, off, insn)
	if not self.noDebugLines then
		local line = self.debugLine
		buffer.writei32(self.lineBuf, off, line)
		if line == 0 then
			self.hasZeroLine = true
		end
	end
	self.insnCount = nextCount
end

@native
function BytecodeBuilder.emitE(self: BytecodeBuilderImpl, opc: number, e: number)
	local insn = bor(band(opc, 0xff), lshift(band(e, 0xffffff), 8))
	local idx = self.insnCount
	local nextCount = idx + 1
	if nextCount > self.insnCap then
		ensureInsnCapacity(self, nextCount)
	end
	local off = idx * 4
	buffer.writeu32(self.insnBuf, off, insn)
	if not self.noDebugLines then
		local line = self.debugLine
		buffer.writei32(self.lineBuf, off, line)
		if line == 0 then
			self.hasZeroLine = true
		end
	end
	self.insnCount = nextCount
end

@native
function BytecodeBuilder.emitAux(self: BytecodeBuilderImpl, aux: number)
	local insn = aux % 0x100000000
	local idx = self.insnCount
	local nextCount = idx + 1
	if nextCount > self.insnCap then
		ensureInsnCapacity(self, nextCount)
	end
	local off = idx * 4
	buffer.writeu32(self.insnBuf, off, insn)
	if not self.noDebugLines then
		local line = self.debugLine
		buffer.writei32(self.lineBuf, off, line)
		if line == 0 then
			self.hasZeroLine = true
		end
	end
	self.insnCount = nextCount
end

@native
function BytecodeBuilder.undoEmit(self: BytecodeBuilderImpl, opc: number)
	local oldSize = self.insnCount
	assert(oldSize > 0, "no instructions to undo")
	local lastInsn = buffer.readu32(self.insnBuf, (oldSize - 1) * 4)
	assert(insnOp(lastInsn) == opc, "opcode mismatch in undoEmit")
	assert(opLengths[opc] == 1, "undoEmit only supports 1-word opcodes")

	local dlCount = self.debugLocalCount
	if dlCount > 0 then
		local dlNames = self.debugLocalNames
		local dlRegs = self.debugLocalRegs
		local dlStartPcs = self.debugLocalStartPcs
		local dlEndPcs = self.debugLocalEndPcs
		local w = 0
		for i = 1, dlCount do
			if dlStartPcs[i] ~= oldSize then
				w += 1
				if w ~= i then
					dlNames[w] = dlNames[i]
					dlRegs[w] = dlRegs[i]
					dlStartPcs[w] = dlStartPcs[i]
				end
				local epc = dlEndPcs[i]
				dlEndPcs[w] = if epc == oldSize then oldSize - 1 else epc
			end
		end
		self.debugLocalCount = w
	end

	local tlCount = self.typedLocalCount
	if tlCount > 0 then
		local tlTypes = self.typedLocalTypes
		local tlRegs = self.typedLocalRegs
		local tlStartPcs = self.typedLocalStartPcs
		local tlEndPcs = self.typedLocalEndPcs
		local w = 0
		for i = 1, tlCount do
			if tlStartPcs[i] ~= oldSize then
				w += 1
				if w ~= i then
					tlTypes[w] = tlTypes[i]
					tlRegs[w] = tlRegs[i]
					tlStartPcs[w] = tlStartPcs[i]
				end
				local epc = tlEndPcs[i]
				tlEndPcs[w] = if epc == oldSize then oldSize - 1 else epc
			end
		end
		self.typedLocalCount = w
	end

	self.insnCount = oldSize - 1
	self.hadUndoEmit = true
end

@native
function BytecodeBuilder.lastInstruction(self: BytecodeBuilderImpl): number
	assert(self.insnCount > 0, "no instructions emitted")
	return buffer.readu32(self.insnBuf, (self.insnCount - 1) * 4)
end

@native
function BytecodeBuilder.emitLabel(self: BytecodeBuilderImpl): number
	return self.insnCount
end

@native
function BytecodeBuilder.patchJumpD(self: BytecodeBuilderImpl, jumpLabel: number, targetLabel: number): boolean
	local insnCount = self.insnCount
	assert(jumpLabel < insnCount, "jumpLabel out of bounds")
	local off = jumpLabel * 4
	local insnBuf = self.insnBuf
	local insn = buffer.readu32(insnBuf, off)
	local op = insnOp(insn)
	assert(isJumpD[op], "expected JumpD opcode")
	assert(insnD(insn) == 0, "jump already patched")

	assert(targetLabel <= insnCount, "targetLabel out of bounds")
	local offset = targetLabel - jumpLabel - 1

	if offset >= -32768 and offset <= 32767 then
		buffer.writeu32(insnBuf, off, bor(band(insn, 0xffff), lshift(band(offset, 0xffff), 16)))
	elseif math.abs(offset) < 2 ^ 23 then
		self.hasLongJumps = true
	else
		return false
	end

	local idx = #self.jumpSources + 1
	self.jumpSources[idx] = jumpLabel
	self.jumpTargets[idx] = targetLabel
	return true
end

@native
function BytecodeBuilder.patchSkipC(self: BytecodeBuilderImpl, jumpLabel: number, targetLabel: number): boolean
	assert(jumpLabel < self.insnCount, "jumpLabel out of bounds")
	local off = jumpLabel * 4
	local insnBuf = self.insnBuf
	local insn = buffer.readu32(insnBuf, off)
	local op = insnOp(insn)
	assert(isSkipC[op] or isFastCall[op], "expected SkipC or FastCall opcode")
	assert(insnC(insn) == 0, "skipC already patched")

	local offset = targetLabel - jumpLabel - 1
	if offset < 0 or offset > 255 then
		return false
	end

	buffer.writeu32(insnBuf, off, bor(band(insn, 0x00ffffff), lshift(band(offset, 0xff), 24)))
	return true
end

function BytecodeBuilder.patchAux(self: BytecodeBuilderImpl, auxLabel: number, value: number)
	assert(auxLabel < self.insnCount, "auxLabel out of bounds")
	local off = auxLabel * 4
	local insnBuf = self.insnBuf
	assert(buffer.readu32(insnBuf, off) == 0xDEADBEEF, "expected dummy 0xDEADBEEF aux")
	buffer.writeu32(insnBuf, off, value % 0x100000000)
end

@native
function BytecodeBuilder.foldJumps(self: BytecodeBuilderImpl)
	if self.hasLongJumps then
		return
	end

	local insnBuf = self.insnBuf
	local insnCount = self.insnCount
	local jumpSources = self.jumpSources
	local jumpTargets = self.jumpTargets
	for idx = 1, #jumpSources do
		local jumpLabel = jumpSources[idx]
		local off = jumpLabel * 4
		local insn = buffer.readu32(insnBuf, off)
		local isJump = insnOp(insn) == LOP_JUMP
		local targetLabel = jumpLabel + 1 + insnD(insn)
		local targetInsn = if targetLabel >= 0 and targetLabel < insnCount
			then buffer.readu32(insnBuf, targetLabel * 4)
			else nil

		while targetInsn and insnOp(targetInsn) == LOP_JUMP and insnD(targetInsn) >= 0 do
			targetLabel = targetLabel + 1 + insnD(targetInsn)
			targetInsn = if targetLabel >= 0 and targetLabel < insnCount
				then buffer.readu32(insnBuf, targetLabel * 4)
				else nil
		end

		if isJump and targetInsn and insnOp(targetInsn) == LOP_RETURN then
			buffer.writeu32(insnBuf, off, targetInsn)
			jumpTargets[idx] = targetLabel
		else
			local offset = targetLabel - jumpLabel - 1
			if offset >= -32768 and offset <= 32767 then
				buffer.writeu32(insnBuf, off, bor(band(insn, 0xffff), lshift(band(offset, 0xffff), 16)))
			end
			jumpTargets[idx] = targetLabel
		end
	end
end

@native
local function siftDown(sources: { number }, targets: { number }, start: number, limit: number)
	local root = start
	while true do
		local child = lshift(root, 1)
		if child > limit then
			break
		end
		if child + 1 <= limit and sources[child] < sources[child + 1] then
			child += 1
		end
		if sources[root] >= sources[child] then
			break
		end
		sources[root], sources[child] = sources[child], sources[root]
		targets[root], targets[child] = targets[child], targets[root]
		root = child
	end
end

@native
local function sortJumps(sources: { number }, targets: { number })
	local n = #sources
	if n <= 1 then
		return
	end

	local ordered = true
	for i = 2, n do
		if sources[i] < sources[i - 1] then
			ordered = false
			break
		end
	end
	if ordered then
		return
	end

	if n <= 24 then
		for i = 2, n do
			local s = sources[i]
			local t = targets[i]
			local j = i - 1
			while j >= 1 and sources[j] > s do
				sources[j + 1] = sources[j]
				targets[j + 1] = targets[j]
				j -= 1
			end
			sources[j + 1] = s
			targets[j + 1] = t
		end
		return
	end

	-- Iterative heapsort for O(J log J) worst-case with zero allocations
	for start = rshift(n, 1), 1, -1 do
		siftDown(sources, targets, start, n)
	end

	for endIdx = n, 2, -1 do
		sources[1], sources[endIdx] = sources[endIdx], sources[1]
		targets[1], targets[endIdx] = targets[endIdx], targets[1]
		siftDown(sources, targets, 1, endIdx - 1)
	end
end

@native
local function computeJumpRemap(
	insnBuf: buffer,
	insnCount: number,
	jumpSources: { number },
	jumpTargets: { number }
): ({ number }, number)
	local jumpCount = #jumpSources
	local remap: { number } = table.create(insnCount + 1, 0)

	for idx = 1, jumpCount do
		local jumpLabel = jumpSources[idx]
		local insn = buffer.readu32(insnBuf, jumpLabel * 4)
		assert(isJumpD[insnOp(insn)], "jump instruction must be AD-format")

		local offset0 = jumpTargets[idx] - jumpLabel - 1
		if offset0 < -10921 or offset0 > 10921 then
			remap[jumpLabel + 1] += 2
		end
	end

	local extraAcc = 0
	for i = 1, insnCount do
		extraAcc += remap[i]
		remap[i] = (i - 1) + extraAcc
	end
	remap[insnCount + 1] = if insnCount > 0 then remap[insnCount] + 1 else 0

	local maxJumpOffset = 0
	for idx = 1, jumpCount do
		local newSource = remap[jumpSources[idx] + 1]
		local jumpTarget = jumpTargets[idx]
		local newTarget = if jumpTarget < insnCount then remap[jumpTarget + 1] else remap[insnCount + 1]
		maxJumpOffset = math.max(maxJumpOffset, math.abs(newTarget - newSource - 1) + 1)
	end

	return remap, maxJumpOffset
end

@native
local function applyJumpRemap(self: BytecodeBuilderImpl, remap: { number })
	local dlCount = self.debugLocalCount
	if dlCount > 0 then
		local dlStartPcs = self.debugLocalStartPcs
		local dlEndPcs = self.debugLocalEndPcs
		for i = 1, dlCount do
			local startpc = dlStartPcs[i]
			local endpc = dlEndPcs[i]
			dlEndPcs[i] = if startpc ~= endpc then remap[endpc] + 1 else remap[endpc + 1]
			dlStartPcs[i] = remap[startpc + 1]
		end
	end

	local tlCount = self.typedLocalCount
	if tlCount > 0 then
		local tlStartPcs = self.typedLocalStartPcs
		local tlEndPcs = self.typedLocalEndPcs
		for i = 1, tlCount do
			local startpc = tlStartPcs[i]
			local endpc = tlEndPcs[i]
			tlEndPcs[i] = if startpc ~= endpc then remap[endpc] + 1 else remap[endpc + 1]
			tlStartPcs[i] = remap[startpc + 1]
		end
	end

	local fbCount = self.fbCount
	if fbCount > 0 then
		local fbKinds = self.fbKinds
		local fbData = self.fbData
		for i = 1, fbCount do
			if fbKinds[i] == FeedbackTypes.LFT_CALLTARGET then
				fbData[i] = remap[fbData[i] + 1]
			end
		end
	end
end

@native
function BytecodeBuilder.expandJumps(self: BytecodeBuilderImpl): boolean
	if not self.hasLongJumps then
		return false
	end

	local insnBuf = self.insnBuf
	local lineBuf = self.lineBuf
	local insnCount = self.insnCount
	local jumpSources = self.jumpSources
	local jumpTargets = self.jumpTargets

	sortJumps(jumpSources, jumpTargets)

	local remap, maxJumpOffset = computeJumpRemap(insnBuf, insnCount, jumpSources, jumpTargets)
	if maxJumpOffset >= 2 ^ 23 then
		return true
	end

	local jumpCount = #jumpSources
	local estSize = remap[insnCount + 1]
	local nCap = math.max(self.insnCap, math.max(1, estSize))
	local nInsnBuf = buffer.create(nCap * 4)
	local nLineBuf = buffer.create(nCap * 4)
	local nCount = 0
	local currentJumpIndex = 1
	local i = 0
	while i < insnCount do
		local op = BytecodeCodec.insnOp(buffer.readu32(insnBuf, i * 4))
		local oplen = opLengths[op]
		assert(oplen, "unknown opcode length")

		if currentJumpIndex <= jumpCount and jumpSources[currentJumpIndex] == i then
			local jumpTarget = jumpTargets[currentJumpIndex]
			local newTarget = if jumpTarget < insnCount then remap[jumpTarget + 1] else remap[insnCount + 1]
			local insn = buffer.readu32(insnBuf, i * 4)
			local line = buffer.readi32(lineBuf, i * 4)
			local offset0 = jumpTarget - i - 1

			if offset0 < -10921 or offset0 > 10921 then
				-- Trampoline prefix matching C++ BytecodeBuilder::expandJumps:
				--   JUMP +1 (skips JUMPX)
				--   JUMPX <far>
				--   <jump insn> -2 (jumps back to JUMPX when taken)
				buffer.writeu32(nInsnBuf, nCount * 4, bor(LOP_JUMP, lshift(1, 16)))
				buffer.writei32(nLineBuf, nCount * 4, line)
				nCount += 1

				local offsetTrampoline = newTarget - nCount - 1
				buffer.writeu32(nInsnBuf, nCount * 4, bor(LOP_JUMPX, lshift(band(offsetTrampoline, 0xffffff), 8)))
				buffer.writei32(nLineBuf, nCount * 4, line)
				nCount += 1

				buffer.writeu32(nInsnBuf, nCount * 4, bor(band(insn, 0xffff), 0xfffe0000))
				buffer.writei32(nLineBuf, nCount * 4, line)
				nCount += 1
				if oplen == 2 then
					buffer.writeu32(nInsnBuf, nCount * 4, buffer.readu32(insnBuf, (i + 1) * 4))
					buffer.writei32(nLineBuf, nCount * 4, buffer.readi32(lineBuf, (i + 1) * 4))
					nCount += 1
				end
			else
				local newSource = nCount
				local offset = newTarget - newSource - 1
				assert(offset >= -32768 and offset <= 32767, "jump offset out of range")
				buffer.writeu32(nInsnBuf, nCount * 4, bor(band(insn, 0xffff), lshift(band(offset, 0xffff), 16)))
				buffer.writei32(nLineBuf, nCount * 4, line)
				nCount += 1
				if oplen == 2 then
					buffer.writeu32(nInsnBuf, nCount * 4, buffer.readu32(insnBuf, (i + 1) * 4))
					buffer.writei32(nLineBuf, nCount * 4, buffer.readi32(lineBuf, (i + 1) * 4))
					nCount += 1
				end
			end

			currentJumpIndex += 1
		else
			for j = 0, oplen - 1 do
				buffer.writeu32(nInsnBuf, nCount * 4, buffer.readu32(insnBuf, (i + j) * 4))
				buffer.writei32(nLineBuf, nCount * 4, buffer.readi32(lineBuf, (i + j) * 4))
				nCount += 1
			end
		end

		i += oplen
	end

	self.insnBuf = nInsnBuf
	self.lineBuf = nLineBuf
	self.insnCap = nCap
	self.insnCount = nCount
	applyJumpRemap(self, remap)
	return false
end

function BytecodeBuilder.setDebugFunctionName(self: BytecodeBuilderImpl, name: string?)
	local func = self.functions[self.currentFunction + 1]
	func.debugname = if not name or #name == 0 then 0 else self:addStringTableEntry(name)
	if self.dumpFlags ~= 0 then
		func.dumpname = name or ""
	end
end

function BytecodeBuilder.setDebugFunctionLineDefined(self: BytecodeBuilderImpl, line: number)
	local func = self.functions[self.currentFunction + 1]
	func.linedefined = line
end

@native
function BytecodeBuilder.setDebugLine(self: BytecodeBuilderImpl, line: number)
	self.debugLine = line
end

@native
function BytecodeBuilder.pushDebugLocal(
	self: BytecodeBuilderImpl,
	name: string?,
	reg: number,
	startpc: number,
	endpc: number
)
	local id = if not name or #name == 0 then 0 else self:addStringTableEntry(name)
	local c = self.debugLocalCount + 1
	self.debugLocalCount = c
	self.debugLocalNames[c] = id
	self.debugLocalRegs[c] = reg
	self.debugLocalStartPcs[c] = startpc
	self.debugLocalEndPcs[c] = endpc
end

@native
function BytecodeBuilder.pushDebugUpval(self: BytecodeBuilderImpl, name: string?)
	local id = if not name or #name == 0 then 0 else self:addStringTableEntry(name)
	local c = self.debugUpvalCount + 1
	self.debugUpvalCount = c
	self.debugUpvalNames[c] = id
end

@native
function BytecodeBuilder.getInstructionCount(self: BytecodeBuilderImpl): number
	return self.insnCount
end

@native
function BytecodeBuilder.pushLocalTypeInfo(
	self: BytecodeBuilderImpl,
	ty: number,
	reg: number,
	startpc: number,
	endpc: number
)
	local c = self.typedLocalCount + 1
	self.typedLocalCount = c
	self.typedLocalTypes[c] = ty
	self.typedLocalRegs[c] = reg
	self.typedLocalStartPcs[c] = startpc
	self.typedLocalEndPcs[c] = endpc
end

@native
function BytecodeBuilder.pushUpvalTypeInfo(self: BytecodeBuilderImpl, ty: number)
	local c = self.typedUpvalCount + 1
	self.typedUpvalCount = c
	self.typedUpvalTypes[c] = ty
end

function BytecodeBuilder.setFunctionTypeInfo(self: BytecodeBuilderImpl, value: string)
	self.functionTypeInfo = value
end

function BytecodeBuilder.addUserdataType(self: BytecodeBuilderImpl, name: string): number
	local index = #self.userdataTypes
	self.userdataTypes[index + 1] = {
		name = name,
		nameRef = 0,
		used = false,
	}
	return index
end

function BytecodeBuilder.useUserdataType(self: BytecodeBuilderImpl, index: number)
	local ud = self.userdataTypes[index + 1]
	if ud ~= nil then
		ud.used = true
	end
end

function BytecodeBuilder.addCallTargetSlot(self: BytecodeBuilderImpl, pc: number): number
	local c = self.fbCount
	local n = c + 1
	self.fbCount = n
	self.fbKinds[n] = FeedbackTypes.LFT_CALLTARGET
	self.fbData[n] = pc
	return c
end

function BytecodeBuilder.addConstructSlot(self: BytecodeBuilderImpl, tableShapeCid: number): number
	local c = self.fbCount
	local n = c + 1
	self.fbCount = n
	self.fbKinds[n] = FeedbackTypes.LFT_CONSTRUCT
	self.fbData[n] = tableShapeCid
	return c
end

function BytecodeBuilder.needsDebugRemarks(self: BytecodeBuilderImpl): boolean
	return band(self.dumpFlags, DumpFlags.Remarks) ~= 0
end

function BytecodeBuilder.addDebugRemark(self: BytecodeBuilderImpl, format: string, ...: any)
	if band(self.dumpFlags, DumpFlags.Remarks) == 0 then
		return
	end
	local msg = if select("#", ...) > 0 then string.format(format, ...) else format
	self.debugRemarks[#self.debugRemarks + 1] = {
		fid = self.currentFunction,
		line = self.debugLine,
		text = msg,
	}
end

@native
local function log2(v: number): number
	if v <= 1 then
		return 0
	end
	return 31 - bit32.countlz(v)
end

@native
local function calcLinesSpan(lineBuf: buffer, n: number): number
	local span = lshift(1, 24)
	local offset = 0
	while offset < n do
		local nextIdx = offset
		local minLine = buffer.readi32(lineBuf, offset * 4)
		local maxLine = minLine
		while nextIdx < n and nextIdx < offset + span do
			local line = buffer.readi32(lineBuf, nextIdx * 4)
			if line < minLine then
				minLine = line
			end
			if line > maxLine then
				maxLine = line
			end
			if maxLine - minLine > 255 then
				break
			end
			nextIdx += 1
		end
		if nextIdx < n and nextIdx - offset < span then
			span = lshift(1, log2(nextIdx - offset))
		end
		offset += span
	end
	return span
end

local lineBaselineScratch: { number } = {}

@native
local function computeLineBaseline(lineBuf: buffer, n: number): (number, { number }, number)
	local span = calcLinesSpan(lineBuf, n)
	local linegaplog2 = log2(span)
	local baselineSize = rshift(n - 1, linegaplog2) + 1
	local baseline = lineBaselineScratch
	local i = 0
	local bIdx = 1
	while i < n do
		local minLine = buffer.readi32(lineBuf, i * 4)
		local j = i + 1
		local limit = math.min(n, i + span)
		while j < limit do
			local l = buffer.readi32(lineBuf, j * 4)
			if l < minLine then
				minLine = l
			end
			j += 1
		end
		baseline[bIdx] = minLine
		bIdx += 1
		i += span
	end
	return linegaplog2, baseline, baselineSize
end

@native
function BytecodeBuilder.writeLineInfo(
	self: BytecodeBuilderImpl,
	writer: BufferWriter,
	_func: any
): (number, number, number)
	local lineBuf = self.lineBuf
	local n = self.insnCount
	assert(n > 0, "lines cannot be empty")

	if n <= 0x1000000 then
		local singleMin = buffer.readi32(lineBuf, 0)
		local singleMax = singleMin
		local singleSpan = true
		for i = 1, n - 1 do
			local l = buffer.readi32(lineBuf, i * 4)
			if l < singleMin then
				singleMin = l
				if singleMax - singleMin > 255 then
					singleSpan = false
					break
				end
			elseif l > singleMax then
				singleMax = l
				if singleMax - singleMin > 255 then
					singleSpan = false
					break
				end
			end
		end
		if singleSpan then
			ensureWriter(writer, 1 + n + 4)
			local buf = writer.buf
			local pos = writer.offset
			buffer.writeu8(buf, pos, 24)
			pos += 1
			local dataStart = pos
			local lastoffset = 0
			for i = 0, n - 1 do
				local rel = buffer.readi32(lineBuf, i * 4) - singleMin
				local offset = band(rel, 0xff)
				buffer.writeu8(buf, pos, band(offset - lastoffset, 0xff))
				pos += 1
				lastoffset = offset
			end
			buffer.writei32(buf, pos, singleMin)
			pos += 4
			writer.offset = pos
			return 24, dataStart, pos - dataStart
		end
	end

	local linegaplog2, baseline, baselineSize = computeLineBaseline(lineBuf, n)
	ensureWriter(writer, 1 + n + baselineSize * 4)
	local buf = writer.buf
	local pos = writer.offset
	buffer.writeu8(buf, pos, band(linegaplog2, 0xff))
	pos += 1
	local dataStart = pos

	local span = lshift(1, linegaplog2)
	local lastoffset = 0
	local startIdx = 0
	for bIdx = 1, baselineSize do
		local baseLine = baseline[bIdx]
		local endIdx = math.min(n, startIdx + span)
		for i = startIdx, endIdx - 1 do
			local rel = buffer.readi32(lineBuf, i * 4) - baseLine
			local offset = band(rel, 0xff)
			buffer.writeu8(buf, pos, band(offset - lastoffset, 0xff))
			pos += 1
			lastoffset = offset
		end
		startIdx = endIdx
	end

	local lastline = 0
	for i = 1, baselineSize do
		local line = baseline[i]
		buffer.writei32(buf, pos, line - lastline)
		pos += 4
		lastline = line
	end
	writer.offset = pos

	return linegaplog2, dataStart, pos - dataStart
end

@native
local function calcTypeInfoBlobSize(
	rawTypeInfo: string,
	upvalCount: number,
	localCount: number,
	tlStartPcs: { number },
	tlEndPcs: { number }
): number
	local rawLen = #rawTypeInfo
	if rawLen == 0 and upvalCount == 0 and localCount == 0 then
		return 0
	end
	local size = varIntSize(rawLen) + varIntSize(upvalCount) + varIntSize(localCount) + rawLen + upvalCount
	for i = 1, localCount do
		local spc = tlStartPcs[i]
		local epc = tlEndPcs[i]
		assert(epc >= spc, "endpc must be >= startpc")
		size += 2 + varIntSize(spc) + varIntSize(epc - spc)
	end
	return size
end

@native
local function writeTypeInfoPayload(
	writer: BufferWriter,
	rawTypeInfo: string,
	upvalCount: number,
	tuTypes: { number },
	localCount: number,
	tlTypes: { number },
	tlRegs: { number },
	tlStartPcs: { number },
	tlEndPcs: { number }
)
	local rawLen = #rawTypeInfo
	local buf = writer.buf
	local pos = writer.offset
	pos = writeVarIntToBuf(buf, pos, rawLen)
	pos = writeVarIntToBuf(buf, pos, upvalCount)
	pos = writeVarIntToBuf(buf, pos, localCount)
	if rawLen > 0 then
		buffer.writestring(buf, pos, rawTypeInfo)
		pos += rawLen
	end

	for i = 1, upvalCount do
		buffer.writeu8(buf, pos, band(tuTypes[i], 0xff))
		pos += 1
	end

	for i = 1, localCount do
		buffer.writeu8(buf, pos, band(tlTypes[i], 0xff))
		buffer.writeu8(buf, pos + 1, band(tlRegs[i], 0xff))
		local spc = tlStartPcs[i]
		pos = writeVarIntToBuf(buf, pos + 2, spc)
		pos = writeVarIntToBuf(buf, pos, tlEndPcs[i] - spc)
	end
	writer.offset = pos
end

local typeInfoScratch: BufferWriter? = nil

function BytecodeBuilder.buildTypeInfoBlob(self: BytecodeBuilderImpl, rawTypeInfo: string): string
	local upvalCount = self.typedUpvalCount
	local localCount = self.typedLocalCount
	local blobSize =
		calcTypeInfoBlobSize(rawTypeInfo, upvalCount, localCount, self.typedLocalStartPcs, self.typedLocalEndPcs)
	if blobSize == 0 then
		return ""
	end
	local writer = typeInfoScratch
	if writer == nil then
		writer = newBufferWriter(math.max(256, blobSize))
		typeInfoScratch = writer
	end
	local w = writer :: BufferWriter
	w.offset = 0
	ensureWriter(w, blobSize)
	writeTypeInfoPayload(
		w,
		rawTypeInfo,
		upvalCount,
		self.typedUpvalTypes,
		localCount,
		self.typedLocalTypes,
		self.typedLocalRegs,
		self.typedLocalStartPcs,
		self.typedLocalEndPcs
	)
	local str = buffer.readstring(w.buf, 0, w.offset)
	w.offset = 0
	return str
end

@native
local function writeFunctionTypeInfo(self: BytecodeBuilderImpl, writer: BufferWriter, func: any)
	local upvalCount = self.typedUpvalCount
	local localCount = self.typedLocalCount
	local rawTypeInfo: string = func.typeinfo
	local blobSize =
		calcTypeInfoBlobSize(rawTypeInfo, upvalCount, localCount, self.typedLocalStartPcs, self.typedLocalEndPcs)
	if blobSize > 0 then
		writeVarInt(writer, blobSize)
		local blobStart = writer.offset
		ensureWriter(writer, blobSize)
		writeTypeInfoPayload(
			writer,
			rawTypeInfo,
			upvalCount,
			self.typedUpvalTypes,
			localCount,
			self.typedLocalTypes,
			self.typedLocalRegs,
			self.typedLocalStartPcs,
			self.typedLocalEndPcs
		)
		if self.retainProto or self.dumpFlags ~= 0 then
			func.typeinfo = buffer.readstring(writer.buf, blobStart, blobSize)
		else
			func.typeinfo = ""
		end
	else
		func.typeinfo = ""
		writeByte(writer, 0)
	end
end

@native
local function writeFunctionConstants(self: BytecodeBuilderImpl, writer: BufferWriter)
	local constTypes = self.constTypes
	local count = #constTypes
	if count == 0 then
		writeByte(writer, 0)
		return
	end
	local constVals = self.constVals
	ensureWriter(writer, 5 + count * 10)
	local buf = writer.buf
	local cap = writer.cap
	local pos = writeVarIntToBuf(buf, writer.offset, count)
	for idx = 1, count do
		if pos + 36 > cap then
			writer.offset = pos
			ensureWriter(writer, 36)
			buf = writer.buf
			cap = writer.cap
		end
		local ctype = constTypes[idx]
		local cval = constVals[idx]
		if ctype == ConstantType.Nil then
			buffer.writeu8(buf, pos, Tags.LBC_CONSTANT_NIL)
			pos += 1
		elseif ctype == ConstantType.Boolean then
			buffer.writeu8(buf, pos, Tags.LBC_CONSTANT_BOOLEAN)
			buffer.writeu8(buf, pos + 1, if cval then 1 else 0)
			pos += 2
		elseif ctype == ConstantType.Number then
			buffer.writeu8(buf, pos, Tags.LBC_CONSTANT_NUMBER)
			buffer.writef64(buf, pos + 1, cval :: number)
			pos += 9
		elseif ctype == ConstantType.Vectorf then
			buffer.writeu8(buf, pos, Tags.LBC_CONSTANT_VECTOR)
			local vec = cval :: { number }
			buffer.writef32(buf, pos + 1, vec[1])
			buffer.writef32(buf, pos + 5, vec[2])
			buffer.writef32(buf, pos + 9, vec[3])
			buffer.writef32(buf, pos + 13, vec[4])
			pos += 17
		elseif ctype == ConstantType.Vectord then
			buffer.writeu8(buf, pos, Tags.LBC_CONSTANT_VECTORD)
			local vec = cval :: { number }
			buffer.writef64(buf, pos + 1, vec[1])
			buffer.writef64(buf, pos + 9, vec[2])
			buffer.writef64(buf, pos + 17, vec[3])
			buffer.writef64(buf, pos + 25, vec[4])
			pos += 33
		elseif ctype == ConstantType.String then
			buffer.writeu8(buf, pos, Tags.LBC_CONSTANT_STRING)
			pos = writeVarIntToBuf(buf, pos + 1, cval :: number)
		elseif ctype == ConstantType.Import then
			buffer.writeu8(buf, pos, Tags.LBC_CONSTANT_IMPORT)
			buffer.writeu32(buf, pos + 1, cval :: number)
			pos += 5
		elseif ctype == ConstantType.Table then
			local shape = self.tableShapes[(cval :: number) + 1]
			local len = shape.length
			local need = 6 + len * 5
			if pos + need > cap then
				writer.offset = pos
				ensureWriter(writer, need)
				buf = writer.buf
				cap = writer.cap
			end
			buffer.writeu8(buf, pos, Tags.LBC_CONSTANT_TABLE)
			pos = writeVarIntToBuf(buf, pos + 1, len)
			local keys = shape.keys
			for i = 1, len do
				pos = writeVarIntToBuf(buf, pos, keys[i])
			end
		elseif ctype == ConstantType.TableWithConstants then
			local shape = self.tableShapes[(cval :: number) + 1]
			local len = shape.length
			local need = 6 + len * 9
			if pos + need > cap then
				writer.offset = pos
				ensureWriter(writer, need)
				buf = writer.buf
				cap = writer.cap
			end
			buffer.writeu8(buf, pos, Tags.LBC_CONSTANT_TABLE_WITH_CONSTANTS)
			pos = writeVarIntToBuf(buf, pos + 1, len)
			local keys = shape.keys
			local consts = shape.constants
			for i = 1, len do
				pos = writeVarIntToBuf(buf, pos, keys[i])
				buffer.writei32(buf, pos, consts[i])
				pos += 4
			end
		elseif ctype == ConstantType.Closure then
			buffer.writeu8(buf, pos, Tags.LBC_CONSTANT_CLOSURE)
			pos = writeVarIntToBuf(buf, pos + 1, cval :: number)
		elseif ctype == ConstantType.Class then
			local shape = self.classShapes[(cval :: number) + 1]
			local props = shape.propertyNames
			local methods = shape.methodNames
			local numPrivInst = shape.numPrivateInstanceProps or 0
			local numPrivStat = shape.numPrivateStaticProps or 0
			local need = 18 + (#props + #methods) * 5
			if pos + need > cap then
				writer.offset = pos
				ensureWriter(writer, need)
				buf = writer.buf
				cap = writer.cap
			end
			buffer.writeu8(buf, pos, Tags.LBC_CONSTANT_CLASS_SHAPE)
			pos = writeVarIntToBuf(buf, pos + 1, shape.className)
			buffer.writeu8(buf, pos, band(numPrivInst, 0xff))
			buffer.writeu8(buf, pos + 1, band(numPrivStat, 0xff))
			pos = writeVarIntToBuf(buf, pos + 2, #props + numPrivInst)
			pos = writeVarIntToBuf(buf, pos, #methods + numPrivStat)
			for i = 1, #props do
				pos = writeVarIntToBuf(buf, pos, props[i])
			end
			for i = 1, #methods do
				pos = writeVarIntToBuf(buf, pos, methods[i])
			end
		end
	end
	writer.offset = pos
end

@native
local function writeFunctionDebugAndFeedback(self: BytecodeBuilderImpl, writer: BufferWriter, func: any)
	local dlCount = self.debugLocalCount
	local duCount = self.debugUpvalCount
	if dlCount > 0 or duCount > 0 then
		ensureWriter(writer, 11 + dlCount * 16 + duCount * 5)
		local dlNames = self.debugLocalNames
		local dlRegs = self.debugLocalRegs
		local dlStartPcs = self.debugLocalStartPcs
		local dlEndPcs = self.debugLocalEndPcs
		local duNames = self.debugUpvalNames
		local buf = writer.buf
		local pos = writer.offset
		buffer.writeu8(buf, pos, 1)
		pos = writeVarIntToBuf(buf, pos + 1, dlCount)
		for i = 1, dlCount do
			pos = writeVarIntToBuf(buf, pos, dlNames[i])
			pos = writeVarIntToBuf(buf, pos, dlStartPcs[i])
			pos = writeVarIntToBuf(buf, pos, dlEndPcs[i])
			buffer.writeu8(buf, pos, band(dlRegs[i], 0xff))
			pos += 1
		end
		pos = writeVarIntToBuf(buf, pos, duCount)
		for i = 1, duCount do
			pos = writeVarIntToBuf(buf, pos, duNames[i])
		end
		writer.offset = pos
	else
		writeByte(writer, 0)
	end

	local totalSlots = self.fbCount
	ensureWriter(writer, 15 + totalSlots * 6 + if band(func.flags, ProtoFlags.LPF_INLINABLE) ~= 0 then 10 else 0)
	local fbuf = writer.buf
	local fpos = writeVarIntToBuf(fbuf, writer.offset, totalSlots)
	if totalSlots > 0 then
		local fbKinds = self.fbKinds
		local fbData = self.fbData
		for i = 1, totalSlots do
			buffer.writeu8(fbuf, fpos, fbKinds[i])
			fpos = writeVarIntToBuf(fbuf, fpos + 1, fbData[i])
		end
	end
	if band(func.flags, ProtoFlags.LPF_INLINABLE) ~= 0 then
		fpos = writeVarInt64ToBuf(fbuf, fpos, func.costModelLo, func.costModelHi)
	end
	writer.offset = fpos
end

@native
function BytecodeBuilder.writeFunction(
	self: BytecodeBuilderImpl,
	func: any,
	hasLinesArg: boolean?
): (number?, number?, number)
	local writer: BufferWriter = self.funcWriter :: BufferWriter
	local startOffset = writer.offset

	ensureWriter(writer, 5)
	local hbuf = writer.buf
	buffer.writeu8(hbuf, startOffset, band(func.maxstacksize, 0xff))
	buffer.writeu8(hbuf, startOffset + 1, band(func.numparams, 0xff))
	buffer.writeu8(hbuf, startOffset + 2, band(func.nups, 0xff))
	buffer.writeu8(hbuf, startOffset + 3, if func.isvararg then 1 else 0)
	buffer.writeu8(hbuf, startOffset + 4, band(func.flags, 0xff))
	writer.offset = startOffset + 5

	writeFunctionTypeInfo(self, writer, func)

	local insnCount = self.insnCount
	writeVarInt(writer, insnCount)
	if insnCount > 0 then
		local encoder = self.encoder
		if encoder == nil then
			local byteCount = insnCount * 4
			ensureWriter(writer, byteCount)
			buffer.copy(writer.buf, writer.offset, self.insnBuf, 0, byteCount)
			writer.offset += byteCount
		elseif type(encoder) == "function" then
			local byteCount = insnCount * 4
			ensureWriter(writer, byteCount)
			local wbuf = writer.buf
			local base = writer.offset
			buffer.copy(wbuf, base, self.insnBuf, 0, byteCount)
			local encodeFn: (number) -> number = encoder
			local i = 0
			while i < insnCount do
				local pos = base + i * 4
				local op = buffer.readu8(wbuf, pos)
				buffer.writeu8(wbuf, pos, band(encodeFn(op), 0xff))
				i += opLengths[op] or 1
			end
			writer.offset = base + byteCount
		elseif type(encoder) == "table" and type(encoder.encode) == "function" then
			local insnBuf = self.insnBuf
			local copy = table.create(insnCount, 0)
			for i = 0, insnCount - 1 do
				copy[i + 1] = buffer.readu32(insnBuf, i * 4)
			end
			local encodeMethod: (any, { number }) -> () = encoder.encode
			encodeMethod(encoder, copy)
			writeUIntArray(writer, copy, insnCount)
		else
			error("Invalid BytecodeEncoder: expected function or { encode = function }", 0)
		end
	end

	writeFunctionConstants(self, writer)

	local protos = self.protos
	local protoCount = #protos
	ensureWriter(writer, 16 + protoCount * 5)
	local pbuf = writer.buf
	local ppos = writeVarIntToBuf(pbuf, writer.offset, protoCount)
	for i = 1, protoCount do
		ppos = writeVarIntToBuf(pbuf, ppos, protos[i])
	end
	ppos = writeVarIntToBuf(pbuf, ppos, func.linedefined)
	ppos = writeVarIntToBuf(pbuf, ppos, func.debugname)

	local hasLines: boolean
	if hasLinesArg ~= nil then
		hasLines = hasLinesArg
	else
		hasLines = checkHasLines(self)
	end

	local linegaplog2: number? = nil
	local lineDataStart: number? = nil
	local lineDataLen = 0
	if hasLines then
		buffer.writeu8(pbuf, ppos, 1)
		writer.offset = ppos + 1
		linegaplog2, lineDataStart, lineDataLen = self:writeLineInfo(writer, func)
	else
		buffer.writeu8(pbuf, ppos, 0)
		writer.offset = ppos + 1
	end

	writeFunctionDebugAndFeedback(self, writer, func)
	func.dataOffset = startOffset
	func.dataLen = writer.offset - startOffset
	return linegaplog2, lineDataStart, lineDataLen
end

local lineScratch: BufferWriter? = nil

local function resolveDebugInfo(
	dlCount: number,
	dlNames: { number },
	dlRegs: { number },
	dlStartPcs: { number },
	dlEndPcs: { number },
	duCount: number,
	duNames: { number },
	stringList: { string }
): ({ { varname: string?, startpc: number, endpc: number, reg: number } }, { string? })
	local lvars: { { varname: string?, startpc: number, endpc: number, reg: number } } = table.create(dlCount) :: any
	for j = 1, dlCount do
		local n = dlNames[j]
		lvars[j] = table.freeze({
			varname = if n == 0 then nil else stringList[n],
			startpc = dlStartPcs[j],
			endpc = dlEndPcs[j],
			reg = band(dlRegs[j], 0xff),
		}) :: any
	end
	table.freeze(lvars)
	local uvals: { string? } = table.create(duCount) :: { string? }
	for j = 1, duCount do
		local nameRef = duNames[j]
		uvals[j] = if nameRef == 0 then nil else stringList[nameRef]
	end
	table.freeze(uvals)
	return lvars, uvals
end

local CONSTANT_TYPE_TO_TAG: { [number]: number } = table.freeze({
	[ConstantType.Nil] = Tags.LBC_CONSTANT_NIL,
	[ConstantType.Boolean] = Tags.LBC_CONSTANT_BOOLEAN,
	[ConstantType.Number] = Tags.LBC_CONSTANT_NUMBER,
	[ConstantType.Vectorf] = Tags.LBC_CONSTANT_VECTOR,
	[ConstantType.Vectord] = Tags.LBC_CONSTANT_VECTORD,
	[ConstantType.String] = Tags.LBC_CONSTANT_STRING,
	[ConstantType.Import] = Tags.LBC_CONSTANT_IMPORT,
	[ConstantType.Table] = Tags.LBC_CONSTANT_TABLE,
	[ConstantType.Closure] = Tags.LBC_CONSTANT_CLOSURE,
	[ConstantType.TableWithConstants] = Tags.LBC_CONSTANT_TABLE_WITH_CONSTANTS,
	[ConstantType.Class] = Tags.LBC_CONSTANT_CLASS_SHAPE,
})

local function resolveProtoConstants(
	constTypes: { number },
	constVals: { any },
	tableShapes: { TableShape },
	classShapes: { ClassShape },
	stringList: { string }
): ({ number }, { any })
	local sizek = #constTypes
	local kTypes: { number } = table.create(sizek, 0) :: { number }
	local kValues: { any } = table.create(sizek) :: { any }

	for j = 1, sizek do
		local ctype = constTypes[j]
		local cval = constVals[j]
		local tag = CONSTANT_TYPE_TO_TAG[ctype]
		if tag == nil then
			error("Unexpected constant kind: " .. tostring(ctype), 0)
		end
		kTypes[j] = tag
		if ctype == ConstantType.Nil then
			kValues[j] = nil
		elseif ctype == ConstantType.Boolean then
			kValues[j] = cval == true
		elseif ctype == ConstantType.Number then
			kValues[j] = cval :: number
		elseif ctype == ConstantType.Vectorf or ctype == ConstantType.Vectord then
			kValues[j] = table.freeze(table.clone(cval :: { number }))
		elseif ctype == ConstantType.String then
			local strRef = cval :: number
			kValues[j] = if strRef == 0 then "" else (stringList[strRef] or "")
		elseif ctype == ConstantType.Import then
			kValues[j] = (cval :: number) % 0x100000000
		elseif ctype == ConstantType.Table then
			local shape = tableShapes[(cval :: number) + 1]
			local keysCount = shape.length
			local keys: { number } = table.create(keysCount, 0)
			for m = 1, keysCount do
				keys[m] = shape.keys[m]
			end
			kValues[j] = table.freeze({ keys = table.freeze(keys), length = keysCount })
		elseif ctype == ConstantType.TableWithConstants then
			local shape = tableShapes[(cval :: number) + 1]
			local keysCount = shape.length
			local keys: { number } = table.create(keysCount, 0)
			local constants: { number } = table.create(keysCount, 0)
			for m = 1, keysCount do
				keys[m] = shape.keys[m]
				constants[m] = shape.constants[m]
			end
			kValues[j] = table.freeze({
				keys = table.freeze(keys),
				constants = table.freeze(constants),
				length = keysCount,
			})
		elseif ctype == ConstantType.Closure then
			kValues[j] = cval :: number
		elseif ctype == ConstantType.Class then
			local shape = classShapes[(cval :: number) + 1]
			kValues[j] = table.freeze({
				className = shape.className,
				numPrivateInstanceProps = shape.numPrivateInstanceProps or 0,
				numPrivateStaticProps = shape.numPrivateStaticProps or 0,
				propertyNames = table.freeze(table.clone(shape.propertyNames)),
				methodNames = table.freeze(table.clone(shape.methodNames)),
			})
		end
	end
	table.freeze(kTypes)
	table.freeze(kValues)
	return kTypes, kValues
end

function BytecodeBuilder.captureProto(
	self: BytecodeBuilderImpl,
	funcId: number,
	func: any,
	hasLines: boolean,
	cachedGap: number?,
	cachedLineStart: number?,
	cachedLineLen: number?
)
	local sizecode = self.insnCount
	local insnBuf = self.insnBuf
	local insns: { number } = table.create(sizecode, 0)
	for i = 0, sizecode - 1 do
		insns[i + 1] = buffer.readu32(insnBuf, i * 4)
	end
	table.freeze(insns)

	local p = self.protos
	table.freeze(p)
	self.protos = {}

	local lineData: string? = nil
	local linegaplog2: number? = nil
	if hasLines and sizecode > 0 then
		if cachedGap ~= nil and cachedLineStart ~= nil then
			linegaplog2 = cachedGap
			lineData = buffer.readstring(self.funcWriter.buf, cachedLineStart, cachedLineLen or 0)
		else
			local writer = lineScratch
			if writer == nil then
				writer = newBufferWriter(512)
				lineScratch = writer
			end
			local w = writer :: BufferWriter
			w.offset = 0
			local gap, dataStart, dataLen = self:writeLineInfo(w, func)
			linegaplog2 = gap
			lineData = buffer.readstring(w.buf, dataStart, dataLen)
			w.offset = 0
		end
	end

	local stringList: { string } = self.stringList
	local dlCount = self.debugLocalCount
	local duCount = self.debugUpvalCount
	local locvars: { { varname: string?, startpc: number, endpc: number, reg: number } }? = nil
	local upvalues: { string? }? = nil
	if dlCount > 0 or duCount > 0 then
		locvars, upvalues = resolveDebugInfo(
			dlCount,
			self.debugLocalNames,
			self.debugLocalRegs,
			self.debugLocalStartPcs,
			self.debugLocalEndPcs,
			duCount,
			self.debugUpvalNames,
			stringList
		)
	end

	local kTypes, kValues =
		resolveProtoConstants(self.constTypes, self.constVals, self.tableShapes, self.classShapes, stringList)
	local typeinfoStr: string = func.typeinfo
	local capturedProtos = assert(self.capturedProtos)
	capturedProtos[funcId + 1] = table.freeze({
		id = funcId,
		maxstacksize = band(func.maxstacksize, 0xff),
		numparams = band(func.numparams, 0xff),
		nups = band(func.nups, 0xff),
		isvararg = func.isvararg == true,
		flags = band(func.flags, 0xff),
		code = insns,
		kTypes = kTypes,
		kValues = kValues,
		p = p,
		linedefined = func.linedefined,
		debugname = if func.debugname == 0 then nil else stringList[func.debugname],
		lineData = lineData,
		linegaplog2 = linegaplog2,
		locvars = locvars,
		upvalues = upvalues,
		typeinfo = if #typeinfoStr > 0 then typeinfoStr else nil,
	}) :: any
end

function BytecodeBuilder.getVersion(self: BytecodeBuilderImpl): number
	if self.flags.DebugLuauUserDefinedClasses then
		return Tags.LBC_VERSION_CLASSES
	end
	return Tags.LBC_VERSION_TARGET
end

@native
function BytecodeBuilder.finalize(self: BytecodeBuilderImpl)
	assert(not self.finalized, "already finalized")
	assert(self.currentFunction == -1, "function still open")
	assert(self.mainFunction >= 0 and self.mainFunction < #self.functions, "main function not set")
	self.finalized = true

	local userdataTypes: { { name: string, nameRef: number, used: boolean } } = self.userdataTypes
	for i = 1, #userdataTypes do
		local ud = userdataTypes[i]
		if ud.used and ud.nameRef == 0 then
			ud.nameRef = self:addStringTableEntry(ud.name)
		end
	end

	if not self.serializeBytes then
		return
	end

	local version = self:getVersion()
	local typesversion = Tags.LBC_TYPE_VERSION_TARGET
	local stringList: { string } = self.stringList
	local stringCount = #stringList
	local functions = self.functions
	local funcCount = #functions

	local totalSize = 2 + varIntSize(stringCount)
	for i = 1, stringCount do
		local slen = #stringList[i]
		totalSize += varIntSize(slen) + slen
	end
	if typesversion == 3 then
		for i = 1, #userdataTypes do
			local nameRef = userdataTypes[i].nameRef
			if nameRef ~= 0 then
				totalSize += 1 + varIntSize(nameRef)
			end
		end
		totalSize += 1
	end
	totalSize += varIntSize(funcCount)
	for i = 1, funcCount do
		local dataLen = functions[i].dataLen
		totalSize += varIntSize(dataLen) + dataLen
	end
	totalSize += varIntSize(self.mainFunction)

	local buf = buffer.create(totalSize)
	buffer.writeu8(buf, 0, band(version, 0xff))
	buffer.writeu8(buf, 1, band(typesversion, 0xff))
	local pos = writeVarIntToBuf(buf, 2, stringCount)

	for i = 1, stringCount do
		local s = stringList[i]
		local slen = #s
		pos = writeVarIntToBuf(buf, pos, slen)
		if slen > 0 then
			buffer.writestring(buf, pos, s)
			pos += slen
		end
	end

	if typesversion == 3 then
		for idx = 1, #userdataTypes do
			local nameRef = userdataTypes[idx].nameRef
			if nameRef ~= 0 then
				buffer.writeu8(buf, pos, band(idx, 0xff))
				pos = writeVarIntToBuf(buf, pos + 1, nameRef)
			end
		end
		buffer.writeu8(buf, pos, 0)
		pos += 1
	end

	pos = writeVarIntToBuf(buf, pos, funcCount)
	local funcBuf = self.funcWriter.buf
	for i = 1, funcCount do
		local func = functions[i]
		local dataLen = func.dataLen
		pos = writeVarIntToBuf(buf, pos, dataLen)
		if dataLen > 0 then
			buffer.copy(buf, pos, funcBuf, func.dataOffset, dataLen)
			pos += dataLen
		end
	end

	pos = writeVarIntToBuf(buf, pos, self.mainFunction)
	self.bytecode = buffer.readstring(buf, 0, pos)
end

function BytecodeBuilder.getBytecode(self: BytecodeBuilderImpl): string
	assert(self.finalized and self.serializeBytes and #self.bytecode > 0, "bytecode is not finalized")
	return self.bytecode
end

local stringHashCache: { [string]: number } = {}
local stringHashCacheCount = 0

--- Computes the Luau bytecode string hash for an identifier or string literal.
@native
function BytecodeBuilder.getStringHash(str: string): number
	local cached = stringHashCache[str]
	if cached ~= nil then
		return cached
	end
	local len = #str
	local h = len
	for i = len, 1, -1 do
		local b = string.byte(str, i)
		local shifted = (lshift(h, 5) + rshift(h, 2) + b) % 0x100000000
		h = bxor(h, shifted)
	end
	if len <= 64 then
		if stringHashCacheCount >= 8192 then
			table.clear(stringHashCache)
			stringHashCacheCount = 0
		end
		stringHashCache[str] = h
		stringHashCacheCount += 1
	end
	return h
end

--- Packs 1 to 3 string constant indices into a 32-bit `LOP_GETIMPORT` id.
@native
function BytecodeBuilder.getImportId(id0: number, id1: number?, id2: number?): number
	if id1 == nil then
		assert(band(id0, bit32.bnot(1023)) == 0, "import id0 out of range")
		return bor(0x40000000, lshift(id0, 20))
	elseif id2 == nil then
		assert(band(bor(id0, id1), bit32.bnot(1023)) == 0, "import id out of range")
		return bor(0x80000000, lshift(id0, 20), lshift(id1, 10))
	else
		assert(band(bor(id0, id1, id2), bit32.bnot(1023)) == 0, "import id out of range")
		return bor(0xc0000000, lshift(id0, 20), lshift(id1, 10), id2)
	end
end

function BytecodeBuilder.setDumpFlags(self: BytecodeBuilderImpl, flags: number)
	self.dumpFlags = flags
end

function BytecodeBuilder.setDumpSource(self: BytecodeBuilderImpl, source: string)
	local lines = string.split(source, "\n")
	for i = 1, #lines do
		local line = lines[i]
		local len = #line
		if len > 0 and string.byte(line, len) == 13 then
			lines[i] = string.sub(line, 1, len - 1)
		end
	end
	self.dumpSourceLines = lines
end

function BytecodeBuilder.dumpCurrentFunction(self: BytecodeBuilderImpl): string
	if self.currentFunction < 0 then
		return ""
	end
	return getDisassembler().dumpCurrentFunction(self)
end

function BytecodeBuilder.dumpFunction(self: BytecodeBuilderImpl, fid: number): string
	assert(fid >= 0 and fid < #self.functions, "invalid function id")
	return self.functions[fid + 1].dump
end

function BytecodeBuilder.dumpEverything(self: BytecodeBuilderImpl): string
	local parts = table.create(#self.functions)
	for i = 1, #self.functions do
		parts[i] = self.functions[i].dump
	end
	return table.concat(parts)
end

function BytecodeBuilder.dumpSourceRemarks(self: BytecodeBuilderImpl): string
	return getDisassembler().dumpSourceRemarks(self)
end

function BytecodeBuilder.dumpTypeInfo(self: BytecodeBuilderImpl): string
	return getDisassembler().dumpTypeInfo(self)
end

function BytecodeBuilder.toProtoModule(self: BytecodeBuilderImpl): ProtoModule
	if not self.retainProto then
		assert(self.encoder == nil, "toProtoModule requires retainProto = true when an encoder is configured")
		local mod, err = BytecodeCodec.deserialize(self:getBytecode())
		return assert(mod, err)
	end

	assert(self.finalized, "bytecode is not finalized")
	if self.resolvedProtoModule ~= nil then
		return self.resolvedProtoModule
	end

	local version = self:getVersion()
	local typesversion = Tags.LBC_TYPE_VERSION_TARGET
	local stringList: { string } = self.stringList
	local strings: { string } = table.freeze(table.clone(stringList))

	local userdataTypes: { string }? = nil
	if typesversion == 3 then
		local rawUd: { { name: string, nameRef: number, used: boolean } } = self.userdataTypes
		local udList: { string } = {}
		for idx = 1, #rawUd do
			local nameRef = rawUd[idx].nameRef
			if nameRef ~= 0 then
				udList[idx] = stringList[nameRef] or ""
			end
		end
		if next(udList) ~= nil then
			table.freeze(udList)
			userdataTypes = udList
		end
	end

	local protos: { Proto } = table.freeze(assert(self.capturedProtos))
	local mod: ProtoModule = (
		table.freeze({
			version = version,
			typesversion = typesversion,
			strings = strings,
			protos = protos,
			mainid = self.mainFunction,
			userdataTypes = userdataTypes,
		}) :: any
	) :: ProtoModule
	self.resolvedProtoModule = mod
	return mod
end

return table.freeze(BytecodeBuilder)
