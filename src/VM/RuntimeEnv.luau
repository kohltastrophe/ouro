--!strict
-- Runtime environment, globals isolation, error formatting, and debug inspection for the Luau VM.
-- Upstream Luau is MIT licensed. See ../../LICENSE.md and ../../UPSTREAM.json.
local BytecodeCodec = require("../BytecodeCodec")
local BytecodeDefs = require("../BytecodeDefs")
local HostEnv = require("./HostEnv")
local Types = require("../Types")

type Proto = Types.Proto
type EnvironmentOptions = Types.EnvironmentOptions
type ResourceLimits = Types.ResourceLimits
type DebugFrameInfo = Types.DebugFrameInfo
type CoverageEntry = Types.CoverageEntry
type UpvalueInfo = Types.UpvalueInfo
type LoadOptions = Types.LoadOptions

-- Array tuple: [1] = store table (stack or self when closed), [2] = index (stack slot or 3 when closed), [3]? = closed value
export type Upval = { any }

export type ProtoTemplate = {
	code: { number },
	ops: { number },
	argA: { number },
	argB: { number },
	argC: { number },
	argD: { number },
	fcRa: { [number]: number }?,
	auxVal: { [number]: any },
	fcInfo: { [number]: any }?,
	kTypes: { number },
	kValues: { any },
	baseKVals: { [number]: any },
	importIndices: { number }?,
	hasOpenTop: boolean,
}

export type PredecodedProto = {
	code: { number },
	ops: { number },
	argA: { number },
	argB: { number },
	argC: { number },
	argD: { number },
	fcRa: { [number]: number }?,
	auxVal: { [number]: any },
	fcInfo: { [number]: any }?,
	kTypes: { number },
	kValues: { any },
	kVals: { [number]: any },
	importIndices: { number }?,
	hasOpenTop: boolean,
}

export type SnapshotFrame = {
	shortSrc: string,
	line: number,
	dname: string?,
	proto: Proto,
	closure: ((...any) -> ...any)?,
	isCFrame: boolean?,
}

export type DeadSnapshotFrame = {
	shortSrc: string,
	line: number,
	dname: string?,
	proto: Proto?,
	closure: ((...any) -> ...any)?,
	isCFrame: boolean?,
}

export type ModuleContext = {
	protos: { Proto },
	mainProto: Proto,
	templates: { [number]: ProtoTemplate },
	predecoded: { [number]: PredecodedProto },
	coverage: { [number]: { number } }?,
	env: { [any]: any },
	envGroup: { [ModuleContext]: boolean }?,
	safeenv: boolean,
	safeRootsMask: number,
	needsHostWrappers: boolean,
	dupClosureCache: { [number]: (...any) -> ...any }?,
	shortSrc: string,
	isGuarded: boolean,
	hasLimits: boolean,
	insnCount: number,
	insnLimit: number?,
	callLimit: number?,
	effectiveCallLimit: number,
	activeThreads: { [thread]: number }?,
	timeout: number?,
	startClock: number?,
	interrupt: (() -> boolean?)?,
	interruptInterval: number,
	nextInterrupt: number,
	interrupted: boolean,
	safeEnvOpt: boolean?,
	getGlobal: ((name: string, env: { [any]: any }) -> any)?,
	setGlobal: ((name: string, value: any, env: { [any]: any }) -> ())?,
	hasDebugHooks: boolean,
	hasLineHook: boolean,
	onCall: ((info: DebugFrameInfo) -> ())?,
	onReturn: ((info: DebugFrameInfo) -> ())?,
	onLine: ((line: number, info: DebugFrameInfo) -> ())?,
	onBreak: ((line: number, info: DebugFrameInfo) -> ())?,
	resourceLimits: ResourceLimits?,
	hasResourceLimits: boolean,
	maxStringLength: number?,
	maxTableSize: number?,
	maxBufferSize: number?,
	maxPatternLength: number?,
	resourceLimitWrappers: { [unknown]: unknown }?,
}

export type ClosureMeta = {
	ctx: ModuleContext,
	proto: Proto,
	pdata: PredecodedProto?,
	upvals: { Upval },
	env: { [any]: any },
}

export type FrameState = {
	meta: ClosureMeta,
	closure: ((...any) -> ...any)?,
	stack: { [number]: any },
	stackCap: number,
	stackSlots: number,
	varargs: { [number]: any },
	varargsBuf: { [number]: any }?,
	varargsCap: number,
	nvarargs: number,
	top: number,
	openUvRegs: { number }?,
	openUvObjs: { Upval }?,
	openUvCount: number,
	hasOpenUpvals: boolean,
	pc: number,
	returnPc: number,
	callA: number,
	callNResults: number,
	lastLine: number,
	isCFrame: boolean?,
	isPcall: boolean?,
	cFunc: any?,
	cName: (string | boolean)?,
	savedPcallDepth: number?,
	savedXpcallDepth: number?,
	savedXpcallSnapshot: { SnapshotFrame }?,
	savedXpcallInsertDepth: number?,
}

export type ThreadState = {
	frames: { [number]: FrameState },
	depth: number,
	pcallDepth: number,
	activeStackSlots: number,
	entryRetCount: number,
	entryRets: { [number]: unknown },
	threadEnv: { [any]: any }?,
	callLimitHeadroom: number,
	xpcallCaptureDepth: number,
	xpcallSnapshot: { SnapshotFrame }?,
	xpcallSnapshotInsertDepth: number,
	nonYieldableDepth: number,
}

local band = bit32.band
local bnot = bit32.bnot
local bor = bit32.bor
local btest = bit32.btest
local lshift = bit32.lshift
local rshift = bit32.rshift
local typeofFn: (any) -> string = (typeof or type) :: any
local hostError: (any, number?) -> () = error :: any
local hostPcall: (any, ...any) -> (boolean, ...any) = pcall :: any
local hostXpcall: (any, any, ...any) -> (boolean, ...any) = xpcall :: any
local hostDebug: { [string]: any }? = debug :: any
local hostTraceback: ((...any) -> string)? = if hostDebug then hostDebug.traceback else nil
local hostDebugInfo: ((...any) -> ...any)? = if hostDebug then hostDebug.info else nil
local hostGetfenv: ((any?) -> { [any]: any })? = HostEnv.getfenv
local hostSetfenv: ((any, { [any]: any }) -> any)? = HostEnv.setfenv
local hostGetmetatable: (any) -> any = getmetatable :: any
local hostRawget: ({ [any]: any }, any) -> any = rawget :: any
local hostNext: ({ [any]: any }, any?) -> (any, any) = next :: any

local instanceMethodCache: { [string]: any } = {}
local instanceClassMethodChecked: { [string]: boolean } = {}
local instanceMethodCacheCount = 0

local vmChunkPrefixes: { string } = {}
local function registerVmChunkPrefix(pfx: string)
	if #pfx > 0 and not table.find(vmChunkPrefixes, pfx) then
		vmChunkPrefixes[#vmChunkPrefixes + 1] = pfx
	end
end

do
	local _, sample = pcall(function()
		error("@", 1)
	end)
	local s = tostring(sample)
	local pfx = string.match(s, "^(.*):%d+: @$") or (if hostDebugInfo then hostDebugInfo(1, "s") else "")
	registerVmChunkPrefix(pfx)
	if hostDebugInfo then
		local bcSrc = hostDebugInfo(BytecodeCodec.deserialize, "s")
		if type(bcSrc) == "string" then
			registerVmChunkPrefix(bcSrc)
		end
		local heSrc = hostDebugInfo(HostEnv.getHostEnv, "s")
		if type(heSrc) == "string" then
			registerVmChunkPrefix(heSrc)
		end
	end
end

-- Weak keys+values (`__mode = "kv"`): each VM closure holds its `ClosureMeta` strongly via upvalue,
-- while `"kv"` allows Luau's non-ephemeron GC to collect unreachable cyclic closures (recursive locals / globals in `env`).
local closureMeta: { [(...any) -> ...any]: ClosureMeta } = setmetatable({}, { __mode = "kv" }) :: any
local threadStates: { [thread]: ThreadState } = setmetatable({}, { __mode = "kv" }) :: any
local deadSnapshots: { [thread]: { DeadSnapshotFrame } } = setmetatable({}, { __mode = "k" }) :: any
local decodedLazyLines: { [Proto]: { lineinfo: { number }, abslineinfo: { number }, gap: number } } = setmetatable(
	{},
	{ __mode = "k" }
) :: any
local registeredUnwindFrames: ((ThreadState, number, thread?) -> ())? = nil
local wrapExtractedValue: (val: any, rlWrappers: { [unknown]: unknown }?) -> any

local function getActiveThreadState(co: thread): ThreadState?
	local tstate = threadStates[co]
	if tstate ~= nil then
		if coroutine.status(co) == "dead" then
			if tstate.depth > 0 and registeredUnwindFrames ~= nil then
				registeredUnwindFrames(tstate, 0, co)
			end
			threadStates[co] = nil
			return nil
		end
		return tstate
	end
	return nil
end

local function getThreadState(): ThreadState
	local co = coroutine.running()
	local existing = threadStates[co]
	if existing ~= nil then
		return existing
	end
	local created: ThreadState = {
		frames = {},
		depth = 0,
		pcallDepth = 0,
		activeStackSlots = 0,
		entryRetCount = 0,
		entryRets = {},
		threadEnv = nil,
		callLimitHeadroom = 0,
		xpcallCaptureDepth = 0,
		xpcallSnapshot = nil :: { SnapshotFrame }?,
		xpcallSnapshotInsertDepth = 0,
		nonYieldableDepth = 0,
	}
	threadStates[co] = created
	return created
end

local function getLineForPc(proto: Proto, pc: number): number
	local cached = decodedLazyLines[proto]
	if cached == nil then
		local lineData = proto.lineData
		local gap = proto.linegaplog2
		if type(lineData) == "string" and type(gap) == "number" then
			local okLines, linfo, absinfo = pcall(BytecodeCodec.decodeLineInfo, proto)
			if okLines and type(linfo) == "table" and type(absinfo) == "table" then
				cached = {
					lineinfo = linfo,
					abslineinfo = absinfo,
					gap = gap,
				}
				decodedLazyLines[proto] = cached
			end
		end
	end
	if cached ~= nil and pc >= 1 and pc <= #cached.lineinfo then
		local pc0 = pc - 1
		local base = cached.abslineinfo[rshift(pc0, cached.gap) + 1] or 0
		return base + (cached.lineinfo[pc] or 0)
	end
	return 0
end

local function resolveShadowedInstanceMethod(obj: any, methodName: any, currentResolved: any): any
	if
		currentResolved == nil
		or type(currentResolved) ~= "userdata"
		or typeofFn(currentResolved) ~= "Instance"
		or typeofFn(obj) ~= "Instance"
	then
		return currentResolved
	end
	if type(methodName) ~= "string" then
		return currentResolved
	end
	local clsName: any = nil
	local okCls, clsRes = pcall(function()
		return obj.ClassName
	end)
	if okCls and type(clsRes) == "string" then
		clsName = clsRes
	end
	if clsName ~= nil then
		local clsKey = clsName .. "\0" .. methodName
		local clsCached = instanceMethodCache[clsKey]
		if clsCached ~= nil then
			return clsCached
		end
		if not instanceClassMethodChecked[clsKey] then
			if instanceMethodCacheCount >= 512 then
				table.clear(instanceMethodCache)
				table.clear(instanceClassMethodChecked)
				instanceMethodCacheCount = 0
			end
			instanceClassMethodChecked[clsKey] = true
			instanceMethodCacheCount += 1
			local hostEnv = HostEnv.getHostEnv()
			local hostInstance = hostEnv.Instance
			if hostInstance ~= nil and hostInstance.new then
				local okNew, tmp = pcall(hostInstance.new, clsName)
				if not okNew or tmp == nil then
					okNew, tmp = pcall(hostInstance.new, "Folder")
				end
				if okNew and tmp ~= nil then
					local okM, fnM = pcall(function()
						return tmp[methodName]
					end)
					pcall(function()
						tmp:Destroy()
					end)
					if okM and type(fnM) == "function" then
						instanceMethodCache[clsKey] = fnM
						return fnM
					end
				end
			end
		end
	end
	return currentResolved
end

local ROOT_BIT_IPAIRS = lshift(1, 19)
local ROOT_BIT_NEXT = lshift(1, 20)
local ROOT_BIT_VECTOR3 = lshift(1, 21)
local ROOT_BIT_PCALL = lshift(1, 22)
local ROOT_BIT_XPCALL = lshift(1, 23)
local ALL_SAFE_ROOTS = 0xffffff

local ROOT_BITS: { [string]: number } = table.freeze({
	assert = lshift(1, 0),
	getmetatable = lshift(1, 1),
	rawequal = lshift(1, 2),
	rawget = lshift(1, 3),
	rawlen = lshift(1, 4),
	rawset = lshift(1, 5),
	select = lshift(1, 6),
	setmetatable = lshift(1, 7),
	tonumber = lshift(1, 8),
	tostring = lshift(1, 9),
	type = lshift(1, 10),
	typeof = lshift(1, 11),
	unpack = lshift(1, 12),
	bit32 = lshift(1, 13),
	buffer = lshift(1, 14),
	math = lshift(1, 15),
	string = lshift(1, 16),
	table = lshift(1, 17),
	vector = lshift(1, 18),
	ipairs = ROOT_BIT_IPAIRS,
	next = ROOT_BIT_NEXT,
	Vector3 = ROOT_BIT_VECTOR3,
	pcall = ROOT_BIT_PCALL,
	xpcall = ROOT_BIT_XPCALL,
} :: { [string]: number })

local SAFE_INVALIDATION_KEYS: { [any]: boolean } = {
	_G = true,
}
for k in ROOT_BITS do
	SAFE_INVALIDATION_KEYS[k] = true
end
table.freeze(SAFE_INVALIDATION_KEYS)

local SAFE_ROOT_VALUES: { [string]: any } = {
	assert = assert,
	getmetatable = getmetatable,
	rawequal = rawequal,
	rawget = rawget,
	rawlen = rawlen,
	rawset = rawset,
	select = select,
	setmetatable = setmetatable,
	tonumber = tonumber,
	tostring = tostring,
	type = type,
	typeof = typeofFn,
	unpack = unpack or table.unpack,
	bit32 = bit32,
	buffer = buffer,
	math = math,
	string = string,
	table = table,
	vector = vector,
	ipairs = ipairs,
	next = next,
	pcall = pcall,
	xpcall = xpcall,
}

local BUILTIN_ROOT_BIT: { [number]: number } = {}
for bfid, bname in BytecodeDefs.builtinNames do
	local rb = 0
	if bname == "LBF_ASSERT" then
		rb = ROOT_BITS.assert
	elseif bname == "LBF_TYPE" then
		rb = ROOT_BITS.type
	elseif bname == "LBF_TYPEOF" then
		rb = ROOT_BITS.typeof
	elseif bname == "LBF_RAWSET" then
		rb = ROOT_BITS.rawset
	elseif bname == "LBF_RAWGET" then
		rb = ROOT_BITS.rawget
	elseif bname == "LBF_RAWEQUAL" then
		rb = ROOT_BITS.rawequal
	elseif bname == "LBF_RAWLEN" then
		rb = ROOT_BITS.rawlen
	elseif bname == "LBF_SELECT_VARARG" then
		rb = ROOT_BITS.select
	elseif bname == "LBF_GETMETATABLE" then
		rb = ROOT_BITS.getmetatable
	elseif bname == "LBF_SETMETATABLE" then
		rb = ROOT_BITS.setmetatable
	elseif bname == "LBF_TONUMBER" then
		rb = ROOT_BITS.tonumber
	elseif bname == "LBF_TOSTRING" then
		rb = ROOT_BITS.tostring
	elseif bname == "LBF_TABLE_UNPACK" then
		rb = bor(ROOT_BITS.table, ROOT_BITS.unpack)
	elseif bname == "LBF_VECTOR" or string.sub(bname, 1, 11) == "LBF_VECTOR_" then
		rb = ROOT_BITS.vector
	elseif string.sub(bname, 1, 9) == "LBF_MATH_" then
		rb = ROOT_BITS.math
	elseif string.sub(bname, 1, 10) == "LBF_BIT32_" then
		rb = ROOT_BITS.bit32
	elseif string.sub(bname, 1, 11) == "LBF_STRING_" then
		rb = ROOT_BITS.string
	elseif string.sub(bname, 1, 10) == "LBF_TABLE_" then
		rb = ROOT_BITS.table
	elseif string.sub(bname, 1, 11) == "LBF_BUFFER_" then
		rb = ROOT_BITS.buffer
	end
	BUILTIN_ROOT_BIT[bfid] = rb
end
table.freeze(BUILTIN_ROOT_BIT)

local vmErrorLastMsg: any = nil
local vmErrorLastThread: thread? = nil
local vmErrorIsRawLevel0 = false

local function clearErrorState()
	vmErrorLastMsg = nil
	vmErrorLastThread = nil
	vmErrorIsRawLevel0 = false
end

local HOST_FUNC_NAMES: { [any]: string } = setmetatable({}, { __mode = "k" }) :: any

local function resolveHostFuncName(fn: any): string
	if type(fn) ~= "function" then
		return ""
	end
	local cached = HOST_FUNC_NAMES[fn]
	if cached ~= nil then
		return cached
	end
	local resolved = ""
	if hostDebugInfo then
		local ok, name = pcall(hostDebugInfo, fn, "n")
		if ok and type(name) == "string" then
			resolved = name
		end
	end
	HOST_FUNC_NAMES[fn] = resolved
	return resolved
end

local function makeCProto(name: string?): Proto
	return {
		id = 0,
		maxstacksize = 0,
		numparams = 0,
		nups = 0,
		isvararg = true,
		flags = 0,
		code = {},
		kTypes = {},
		kValues = {},
		p = {},
		linedefined = -1,
		debugname = name,
	}
end

local function truncTowardZero(n: number): number
	return if n < 0 then math.ceil(n) else math.floor(n)
end

local invalidateEnvAll: (ctx: ModuleContext?, env: { [any]: any }?) -> ()
local guestDebugInfo: (arg1: any?, arg2: any?, arg3: any?) -> ...any

local function findNearestLuaFrame(tstate: ThreadState, startIdx: number?): FrameState?
	local idx = startIdx or tstate.depth
	while idx >= 1 do
		local f = tstate.frames[idx]
		if f ~= nil and not f.isCFrame and f.meta ~= nil then
			return f
		end
		idx -= 1
	end
	return nil
end

local function resolveStackFrameAt(
	tstate: ThreadState,
	level: number
): (
	boolean,
	boolean,
	ClosureMeta?,
	((...any) -> ...any)?,
	number,
	any?,
	string?,
	string?,
	number?,
	Proto?
)
	local snap = tstate.xpcallSnapshot
	local snapCount = if snap then #snap else 0
	local totalDepth = tstate.depth + snapCount
	if level < 0 or level >= totalDepth then
		return false, false, nil, nil, 0, nil, nil, nil, nil, nil
	end
	local insertDepth = tstate.xpcallSnapshotInsertDepth
	local idx = totalDepth - level
	if snap and idx > insertDepth and idx <= insertDepth + snapCount then
		local sf = snap[idx - insertDepth]
		local sfMeta = if not sf.isCFrame and sf.closure ~= nil then closureMeta[sf.closure] else nil
		return true, sf.isCFrame == true, sfMeta, sf.closure, 0, nil, sf.dname, sf.shortSrc, sf.line, sf.proto
	end
	local frameIdx = if snap and idx > insertDepth + snapCount then idx - snapCount else idx
	local f = tstate.frames[frameIdx]
	if not f then
		return false, false, nil, nil, 0, nil, nil, nil, nil, nil
	end
	if f.isCFrame then
		local cName = if type(f.cName) == "string" then f.cName else resolveHostFuncName(f.cFunc)
		return true, true, nil, f.cFunc, 0, f.cFunc, cName, "[C]", -1, makeCProto(cName)
	end
	if f.meta then
		local fMeta = f.meta
		local proto = fMeta.proto
		return true,
			false,
			fMeta,
			f.closure,
			f.pc,
			nil,
			proto.debugname,
			fMeta.ctx.shortSrc,
			getLineForPc(proto, f.pc),
			proto
	end
	return false, false, nil, nil, 0, nil, nil, nil, nil, nil
end

local function guestGetfenv(target: any?): { [any]: any }
	local co = coroutine.running()
	local tstate = getActiveThreadState(co)
	local activeDepth = if tstate then tstate.depth else 0
	if tstate and activeDepth >= 1 then
		local t: any = if target == nil then 1 else target
		if type(t) ~= "number" and type(t) ~= "function" then
			local coerced = tonumber(t)
			if coerced ~= nil then
				t = coerced
			end
		end
		if type(t) == "number" then
			local lvl = truncTowardZero(t :: number)
			local topLua = findNearestLuaFrame(tstate)
			local topMeta = if topLua then topLua.meta else nil
			if lvl == 0 then
				if topMeta then
					local env = tstate.threadEnv or topMeta.ctx.env
					invalidateEnvAll(topMeta.ctx, env)
					return env
				end
			else
				local found, isCFrame, meta = resolveStackFrameAt(tstate, lvl)
				if found then
					if isCFrame then
						if topMeta then
							local env = tstate.threadEnv or topMeta.ctx.env
							invalidateEnvAll(topMeta.ctx, env)
							return env
						end
					elseif meta then
						invalidateEnvAll(meta.ctx, meta.env)
						return meta.env
					end
				end
			end
			hostError("bad argument #1 to 'getfenv' (invalid level)", 2)
		elseif type(t) == "function" then
			local meta = closureMeta[t]
			if meta then
				invalidateEnvAll(meta.ctx, meta.env)
				return meta.env
			end
			local topLua = findNearestLuaFrame(tstate)
			if topLua then
				local topMeta = topLua.meta
				local env = tstate.threadEnv or topMeta.ctx.env
				invalidateEnvAll(topMeta.ctx, env)
				return env
			end
		end
		hostError("bad argument #1 to 'getfenv' (number or function expected)", 2)
	end
	if type(target) == "function" then
		local meta = closureMeta[target]
		if meta then
			invalidateEnvAll(meta.ctx, meta.env)
			return meta.env
		end
	end
	hostError("getfenv can only be called from VM code", 2)
	return {}
end

local function guestSetfenv(target: any, newEnv: { [any]: any }): any
	if type(newEnv) ~= "table" then
		hostError("bad argument #2 to 'setfenv' (table expected, got " .. typeofFn(newEnv) .. ")", 2)
	end
	local co = coroutine.running()
	local tstate = getActiveThreadState(co)
	local activeDepth = if tstate then tstate.depth else 0
	if tstate and activeDepth >= 1 then
		local t: any = target
		if type(t) ~= "number" and type(t) ~= "function" then
			local coerced = tonumber(t)
			if coerced ~= nil then
				t = coerced
			end
		end
		if type(t) == "number" then
			local lvl = truncTowardZero(t :: number)
			local topLua = findNearestLuaFrame(tstate)
			if lvl == 0 then
				if topLua then
					local ctx = topLua.meta.ctx
					local prevEnv = tstate.threadEnv or ctx.env
					tstate.threadEnv = newEnv
					invalidateEnvAll(ctx, prevEnv)
					invalidateEnvAll(nil, newEnv)
					ctx.needsHostWrappers = true
					ctx.dupClosureCache = nil
					return
				end
			else
				local found, isCFrame, meta, closure = resolveStackFrameAt(tstate, lvl)
				if found then
					if not isCFrame and meta ~= nil then
						local prevEnv = meta.env
						meta.env = newEnv
						invalidateEnvAll(meta.ctx, prevEnv)
						invalidateEnvAll(nil, newEnv)
						meta.ctx.needsHostWrappers = true
						meta.ctx.dupClosureCache = nil
						return closure
					end
					hostError("'setfenv' cannot change environment of given object", 2)
					return nil
				end
			end
			hostError("bad argument #1 to 'setfenv' (invalid level)", 2)
		elseif type(t) == "function" then
			local meta = closureMeta[t]
			if meta then
				local prevEnv = meta.env
				meta.env = newEnv
				invalidateEnvAll(meta.ctx, prevEnv)
				invalidateEnvAll(nil, newEnv)
				meta.ctx.needsHostWrappers = true
				meta.ctx.dupClosureCache = nil
				return t
			end
			hostError("'setfenv' cannot change environment of given object", 2)
		end
		hostError("bad argument #1 to 'setfenv' (number or function expected)", 2)
	end
	if type(target) == "function" then
		local meta = closureMeta[target]
		if meta then
			local prevEnv = meta.env
			meta.env = newEnv
			invalidateEnvAll(meta.ctx, prevEnv)
			invalidateEnvAll(nil, newEnv)
			meta.ctx.needsHostWrappers = true
			meta.ctx.dupClosureCache = nil
			return target
		end
	end
	hostError("setfenv can only be called from VM code", 2)
	return nil
end

local function vmError(msg: any, level: number?): ...any
	local lvl = 1
	if level ~= nil then
		if type(level) ~= "number" then
			local n = tonumber(level)
			if not n then
				hostError("bad argument #2 to 'error' (number expected, got " .. type(level) .. ")", 2)
			end
			lvl = n :: number
		else
			lvl = level
		end
		lvl = truncTowardZero(lvl)
	end

	local co = coroutine.running()
	if (type(msg) ~= "string" and type(msg) ~= "number") or lvl <= 0 then
		vmErrorLastThread = co
		vmErrorLastMsg = msg
		vmErrorIsRawLevel0 = true
		hostError(msg, 0)
		return
	end
	local tstate = getActiveThreadState(co)
	if tstate and tstate.depth >= 1 then
		local found, isCFrame, fMeta, _, fPc = resolveStackFrameAt(tstate, lvl)
		if found and not isCFrame and fMeta ~= nil then
			local line = getLineForPc(fMeta.proto, fPc)
			local formatted = if line > 0
				then string.format("%s:%d: %s", fMeta.ctx.shortSrc, line, tostring(msg))
				else tostring(msg)
			vmErrorLastThread = co
			vmErrorLastMsg = formatted
			vmErrorIsRawLevel0 = line <= 0
			hostError(formatted, 0)
			return
		elseif found and isCFrame then
			local formatted = tostring(msg)
			vmErrorLastThread = co
			vmErrorLastMsg = formatted
			vmErrorIsRawLevel0 = true
			hostError(formatted, 0)
			return
		end
	end
	local formatted = tostring(msg)
	vmErrorLastThread = co
	vmErrorLastMsg = formatted
	vmErrorIsRawLevel0 = true
	hostError(formatted, 0)
end

local function hasChunkLinePrefix(errStr: string): boolean
	local s, e = string.find(errStr, "^.-:%d+: ")
	if not s then
		return false
	end
	local pfx = string.sub(errStr, s, e)
	return string.find(pfx, "://", 1, true) == nil
end

local function formatVmError(frame: FrameState, err: any, keepRawForCaller: boolean?): any
	local co = coroutine.running()
	if vmErrorLastMsg ~= nil and err == vmErrorLastMsg and co == vmErrorLastThread then
		local wasRaw0 = vmErrorIsRawLevel0
		if not (wasRaw0 and keepRawForCaller) then
			vmErrorLastMsg = nil
			vmErrorLastThread = nil
			vmErrorIsRawLevel0 = false
		end
		return err
	end
	vmErrorLastMsg = nil
	vmErrorLastThread = nil
	vmErrorIsRawLevel0 = false
	if type(err) == "string" then
		local errStr: string = err
		local targetFrame: FrameState? = frame
		if targetFrame == nil or targetFrame.isCFrame or targetFrame.meta == nil then
			local tstate = getActiveThreadState(co)
			targetFrame = if tstate then findNearestLuaFrame(tstate) else nil
		end
		if targetFrame == nil or targetFrame.meta == nil then
			return err
		end
		local meta = targetFrame.meta
		local line: number = getLineForPc(meta.proto, targetFrame.pc)
		local shortSrc = meta.ctx.shortSrc
		for _, pfx in vmChunkPrefixes do
			local pfxLen = #pfx
			if string.sub(errStr, 1, pfxLen + 1) == pfx .. ":" then
				local stripped = string.match(errStr, "^:%d+: (.*)$", pfxLen + 1)
				if stripped then
					if line > 0 then
						return string.format("%s:%d: %s", shortSrc, line, stripped)
					end
					return stripped
				end
			end
		end
		if line > 0 and not hasChunkLinePrefix(errStr) then
			return string.format("%s:%d: %s", shortSrc, line, errStr)
		end
	end
	return err
end

local function formatTracebackImpl(
	allowHostFallback: boolean,
	arg1: any?,
	arg2: any?,
	arg3: any?,
	errLevel: number?
): any
	local throwLevel = errLevel or 3
	local hasThread = type(arg1) == "thread"
	local runningCo = coroutine.running()
	local targetThread: thread = if hasThread then arg1 :: thread else runningCo
	local msgArg: any = if hasThread then arg2 else arg1
	local lvlArg: any = if hasThread then arg3 else arg2
	local argBase = if hasThread then 2 else 1

	local msg: string? = nil
	if msgArg ~= nil then
		local mt = type(msgArg)
		if mt == "string" then
			msg = msgArg
		elseif mt == "number" then
			msg = tostring(msgArg)
		else
			hostError(
				string.format("bad argument #%d to 'traceback' (string expected, got %s)", argBase, typeofFn(msgArg)),
				throwLevel
			)
		end
	end

	local lvl = if hasThread and targetThread ~= runningCo then 0 else 1
	if lvlArg ~= nil then
		if type(lvlArg) ~= "number" then
			local n = tonumber(lvlArg)
			if not n then
				hostError(
					string.format(
						"bad argument #%d to 'traceback' (number expected, got %s)",
						argBase + 1,
						typeofFn(lvlArg)
					),
					throwLevel
				)
			end
			lvl = truncTowardZero(n :: number)
		else
			lvl = truncTowardZero(lvlArg)
		end
		if not (lvl >= 0) then
			hostError(
				string.format("bad argument #%d to 'traceback' (level can't be negative)", argBase + 1),
				throwLevel
			)
		end
	end

	local tstate = getActiveThreadState(targetThread)
	local snap = if tstate then tstate.xpcallSnapshot else nil
	local snapCount = if snap then #snap else 0
	local depth = if tstate then tstate.depth else 0
	local totalDepth = depth + snapCount

	if totalDepth == 0 then
		local deadSnap = if hasThread then deadSnapshots[targetThread] else nil
		if deadSnap ~= nil and #deadSnap > 0 then
			local parts: { string } = {}
			if msg ~= nil then
				parts[1] = msg
				parts[2] = "\n"
			end
			for idx = #deadSnap - lvl, 1, -1 do
				local sf = deadSnap[idx]
				if sf.isCFrame then
					continue
				end
				parts[#parts + 1] = sf.shortSrc
				if sf.line > 0 then
					parts[#parts + 1] = ":" .. tostring(sf.line)
				end
				local dname = sf.dname
				if dname and #dname > 0 and dname ~= "(main)" then
					parts[#parts + 1] = " function " .. dname
				end
				parts[#parts + 1] = "\n"
			end
			return table.concat(parts)
		end
		if allowHostFallback and hostTraceback then
			if hasThread then
				return hostTraceback(targetThread, msg, lvl)
			end
			return hostTraceback(msg, lvl)
		end
		return if msg ~= nil then msg .. "\n" else ""
	end

	-- Upstream luaL_traceback (laux.cpp:365-409)
	local parts: { string } = {}
	if msg ~= nil then
		parts[1] = msg
		parts[2] = "\n"
	end

	if tstate and totalDepth >= 1 then
		local startLvl = if allowHostFallback and targetThread == runningCo and lvl >= 1 then lvl - 1 else lvl
		for frameLvl = startLvl, totalDepth - 1 do
			local found, isCFrame, _, _, _, _, dname, shortSrc, line = resolveStackFrameAt(tstate, frameLvl)
			if found and not isCFrame and shortSrc ~= nil then
				parts[#parts + 1] = shortSrc
				if line ~= nil and line > 0 then
					parts[#parts + 1] = ":" .. tostring(line)
				end
				if dname and #dname > 0 and dname ~= "(main)" then
					parts[#parts + 1] = " function " .. dname
				end
				parts[#parts + 1] = "\n"
			end
		end
	end
	return table.concat(parts)
end

local function recordDeadSnapshot(co: thread, tstate: ThreadState)
	if tstate.depth <= 0 then
		return
	end
	local snap: { DeadSnapshotFrame } = {}
	for i = 1, tstate.depth do
		local f = tstate.frames[i]
		if f and f.isCFrame then
			local cName = if type(f.cName) == "string" then f.cName else resolveHostFuncName(f.cFunc)
			snap[#snap + 1] = {
				shortSrc = "[C]",
				line = -1,
				dname = cName,
				proto = makeCProto(cName),
				closure = f.cFunc,
				isCFrame = true,
			}
		elseif f and f.meta then
			local meta = f.meta
			local proto = meta.proto
			snap[#snap + 1] = {
				shortSrc = meta.ctx.shortSrc,
				line = getLineForPc(proto, f.pc),
				dname = proto.debugname,
				proto = proto,
				closure = f.closure,
				isCFrame = false,
			}
		end
	end
	if #snap > 0 then
		deadSnapshots[co] = snap
	end
end

local function guestDebugTraceback(arg1: any?, arg2: any?, arg3: any?): any
	return formatTracebackImpl(false, arg1, arg2, arg3, 3)
end

--- Formats a guest VM stack trace for a coroutine matching upstream Luau luaL_traceback.
local function vmTraceback(threadOrMsg: any?, message: any?, level: number?): string
	return tostring(formatTracebackImpl(true, threadOrMsg, message, level, 3))
end

local function extractDebugInfo(
	options: string,
	shortSrc: string,
	line: number,
	proto: Proto,
	fn: any,
	errLevel: number
): ...any
	local len = #options
	local out: { any } = table.create(len)
	local n = 0
	local seenS, seenL, seenN, seenA, seenF = false, false, false, false, false
	for i = 1, len do
		local c = string.sub(options, i, i)
		if c == "s" then
			if seenS then
				hostError("bad argument to 'info' (duplicate option)", errLevel)
			end
			seenS = true
			n += 1
			out[n] = shortSrc
		elseif c == "l" then
			if seenL then
				hostError("bad argument to 'info' (duplicate option)", errLevel)
			end
			seenL = true
			n += 1
			out[n] = line
		elseif c == "n" then
			if seenN then
				hostError("bad argument to 'info' (duplicate option)", errLevel)
			end
			seenN = true
			local dname = proto.debugname
			n += 1
			out[n] = if dname and #dname > 0 and dname ~= "(main)" then dname else ""
		elseif c == "a" then
			if seenA then
				hostError("bad argument to 'info' (duplicate option)", errLevel)
			end
			seenA = true
			out[n + 1] = proto.numparams
			out[n + 2] = proto.isvararg
			n += 2
		elseif c == "f" then
			if seenF then
				hostError("bad argument to 'info' (duplicate option)", errLevel)
			end
			seenF = true
			n += 1
			out[n] = fn
		else
			hostError("bad argument to 'info' (invalid option)", errLevel)
		end
	end
	return table.unpack(out, 1, n)
end

local DEBUG_INFO_PROTO: Proto = {
	id = 0,
	maxstacksize = 0,
	numparams = 0,
	nups = 0,
	isvararg = true,
	flags = 0,
	code = {},
	kTypes = {},
	kValues = {},
	p = {},
	linedefined = -1,
	debugname = "info",
}

local DEBUG_RESUME_PROTO: Proto = {
	id = 0,
	maxstacksize = 0,
	numparams = 0,
	nups = 0,
	isvararg = true,
	flags = 0,
	code = {},
	kTypes = {},
	kValues = {},
	p = {},
	linedefined = -1,
	debugname = "resume",
}

function guestDebugInfo(arg1: any?, arg2: any?, arg3: any?): ...any
	local hasThread = type(arg1) == "thread"
	local runningCo = coroutine.running()
	local targetThread: thread = if hasThread then arg1 :: thread else runningCo
	local target: any = if hasThread then arg2 else arg1
	local optionsAny: any = if hasThread then arg3 else arg2
	local targetArgIdx = if hasThread then 2 else 1

	local isFn = false
	local level = 0
	if type(target) == "function" then
		if hasThread then
			hostError("bad argument #2 to 'info' (function or level expected)", 2)
		end
		isFn = true
	else
		local numLevel: number? = if type(target) == "number" then target else tonumber(target)
		if numLevel == nil then
			hostError(string.format("bad argument #%d to 'info' (function or level expected)", targetArgIdx), 2)
		end
		level = truncTowardZero(numLevel :: number)
		if not (level >= 0) then
			hostError(string.format("bad argument #%d to 'info' (level can't be negative)", targetArgIdx), 2)
		end
	end

	if type(optionsAny) ~= "string" then
		if type(optionsAny) == "number" then
			optionsAny = tostring(optionsAny)
		else
			hostError(string.format("bad argument #%d to 'info' (string expected)", targetArgIdx + 1), 2)
		end
	end
	local options = optionsAny :: string

	if isFn then
		local meta = closureMeta[target]
		if meta then
			local proto = meta.proto
			return extractDebugInfo(options, meta.ctx.shortSrc, proto.linedefined or 0, proto, target, 3)
		end
		local cname = resolveHostFuncName(target)
		return extractDebugInfo(options, "[C]", -1, makeCProto(cname), target, 3)
	end

	local isForeign = hasThread and targetThread ~= runningCo
	local tstate = getActiveThreadState(targetThread)
	local snap = if tstate then tstate.xpcallSnapshot else nil
	local snapCount = if snap then #snap else 0
	local totalDepth = if tstate then tstate.depth + snapCount else 0
	if tstate and totalDepth >= 1 then
		local found, _, _, closure, _, _, _, shortSrc, line, proto = resolveStackFrameAt(tstate, level)
		if found and proto ~= nil and shortSrc ~= nil and line ~= nil then
			return extractDebugInfo(options, shortSrc, line, proto, closure, 3)
		end
		return
	end
	if hasThread then
		local deadSnap = deadSnapshots[targetThread]
		if deadSnap ~= nil and #deadSnap > 0 then
			local sf = deadSnap[#deadSnap - level]
			if sf ~= nil and sf.proto ~= nil then
				return extractDebugInfo(options, sf.shortSrc, sf.line, sf.proto, sf.closure, 3)
			end
			return
		end
	end
	if level == 0 then
		if isForeign then
			if coroutine.status(targetThread) == "normal" then
				return extractDebugInfo(options, "[C]", -1, DEBUG_RESUME_PROTO, coroutine.resume, 3)
			end
			return
		end
		return extractDebugInfo(options, "[C]", -1, DEBUG_INFO_PROTO, guestDebugInfo, 3)
	end
	return
end

local vmDebug: { [string]: any } = table.freeze({
	traceback = guestDebugTraceback,
	info = guestDebugInfo,
} :: { [string]: any })

local roProxyData: {
	[any]: {
		store: { [any]: any },
		overrideKeys: { [any]: boolean },
		mt: any,
		libBacking: { [string]: any }?,
		allowed: { [string]: boolean }?,
	},
} = setmetatable(
	{},
	{ __mode = "kv" }
) :: any
local envContexts: { [any]: { [ModuleContext]: boolean } } = setmetatable({}, { __mode = "kv" }) :: any
local cleanVmEnvs: { [any]: boolean } = setmetatable({}, { __mode = "k" }) :: any

local function isReadOnlyProxy(tbl: any): boolean
	return roProxyData[tbl] ~= nil
end

local function invalidatePredecodedRoot(targetCtx: ModuleContext, rb: number)
	targetCtx.safeRootsMask = band(targetCtx.safeRootsMask, bnot(rb))
	targetCtx.safeenv = targetCtx.safeRootsMask ~= 0
	for _, pdata in targetCtx.predecoded do
		local impIdx = pdata.importIndices
		if impIdx ~= nil then
			local kValues = pdata.kValues
			local kVals = pdata.kVals
			for _, ki in impIdx do
				local cnt, id0 = BytecodeCodec.decomposeImportId(kValues[ki])
				if cnt >= 1 and id0 >= 0 then
					local rootKey = kValues[id0 + 1]
					if type(rootKey) == "string" and ROOT_BITS[rootKey] == rb then
						kVals[ki] = nil
					end
				end
			end
		end
		local fcRa = pdata.fcRa
		local fcInfo = pdata.fcInfo
		if fcRa ~= nil and fcInfo ~= nil then
			for pcKey in fcRa do
				local fc = fcInfo[pcKey]
				if fc ~= nil and btest(fc.rootBit, rb) then
					fcRa[pcKey] = nil
				end
			end
		end
	end
end

function invalidateEnvAll(ctx: ModuleContext?, env: { [any]: any }?)
	if ctx ~= nil then
		ctx.safeRootsMask = 0
		ctx.safeenv = false
	end
	if env ~= nil then
		local group = envContexts[env]
		if group ~= nil then
			for siblingCtx in group do
				siblingCtx.safeRootsMask = 0
				siblingCtx.safeenv = false
			end
		end
	end
end

local function invalidateEnvRoot(ctx: ModuleContext?, env: { [any]: any }?, key: any)
	if key == "_G" then
		invalidateEnvAll(ctx, env)
		return
	end
	if type(key) ~= "string" then
		return
	end
	local rb = ROOT_BITS[key]
	if rb == nil then
		return
	end
	if ctx ~= nil and btest(ctx.safeRootsMask, rb) then
		invalidatePredecodedRoot(ctx, rb)
	end
	if env ~= nil then
		local group = envContexts[env]
		if group ~= nil then
			for siblingCtx in group do
				if btest(siblingCtx.safeRootsMask, rb) then
					invalidatePredecodedRoot(siblingCtx, rb)
				end
			end
		end
	end
end

local function getActiveRlWrappers(): { [unknown]: unknown }?
	local tstate = getActiveThreadState(coroutine.running())
	if tstate ~= nil then
		local topLua = findNearestLuaFrame(tstate)
		if topLua ~= nil then
			return topLua.meta.ctx.resourceLimitWrappers
		end
	end
	return nil
end

local hostCoroutine: { [string]: any }? = coroutine :: any
local hostCoroutineClose: ((thread) -> (boolean, any))? = if hostCoroutine then hostCoroutine.close else nil
local hostCoroutineYield: ((...any) -> ...any)? = if hostCoroutine then hostCoroutine.yield else nil
local hostCoroutineIsYieldable: ((thread?) -> boolean)? = if hostCoroutine then hostCoroutine.isyieldable else nil
local hostCoroutineCreate: ((any) -> thread)? = if hostCoroutine then hostCoroutine.create else nil
local hostCoroutineWrap: ((any) -> (...any) -> ...any)? = if hostCoroutine then hostCoroutine.wrap else nil
local vmCoroutine: { [string]: any } = {}
if hostCoroutine ~= nil then
	for k, v in hostCoroutine do
		vmCoroutine[k] = v
	end
	if hostCoroutineCreate ~= nil then
		local createFn = function(fn: any): thread
			if type(fn) == "function" then
				fn = wrapExtractedValue(fn, getActiveRlWrappers())
			end
			return hostCoroutineCreate(fn)
		end
		vmCoroutine.create = createFn
		HOST_FUNC_NAMES[createFn] = "create"
	end
	if hostCoroutineWrap ~= nil then
		local wrapFn = function(fn: any): (...any) -> ...any
			if type(fn) == "function" then
				fn = wrapExtractedValue(fn, getActiveRlWrappers())
			end
			return hostCoroutineWrap(fn)
		end
		vmCoroutine.wrap = wrapFn
		HOST_FUNC_NAMES[wrapFn] = "wrap"
	end
	if hostCoroutineClose ~= nil then
		local closeFn = function(co: thread): (boolean, any)
			if type(co) == "thread" then
				local st = coroutine.status(co)
				if st == "running" or st == "normal" then
					vmError("cannot close " .. st .. " coroutine", 1)
				end
				local ok, err = hostCoroutineClose(co)
				local tstate = threadStates[co]
				if tstate ~= nil and registeredUnwindFrames ~= nil then
					registeredUnwindFrames(tstate, 0, co)
				end
				threadStates[co] = nil
				deadSnapshots[co] = nil
				return ok, err
			end
			return hostCoroutineClose(co)
		end
		vmCoroutine.close = closeFn
		HOST_FUNC_NAMES[closeFn] = "close"
	end
	if hostCoroutineYield ~= nil then
		local yieldFn = function(...: any): ...any
			local co = coroutine.running()
			local tstate = getActiveThreadState(co)
			if tstate ~= nil and tstate.nonYieldableDepth > 0 then
				hostError("attempt to yield across metamethod/C-call boundary", 2)
			end
			return hostCoroutineYield(...)
		end
		vmCoroutine.yield = yieldFn
		HOST_FUNC_NAMES[yieldFn] = "yield"
	end
	if hostCoroutineIsYieldable ~= nil then
		local isYieldableFn = function(coArg: thread?): boolean
			local co = if coArg ~= nil then coArg else coroutine.running()
			if type(co) == "thread" then
				local tstate = getActiveThreadState(co)
				if tstate ~= nil and tstate.nonYieldableDepth > 0 then
					return false
				end
			end
			return hostCoroutineIsYieldable(coArg)
		end
		vmCoroutine.isyieldable = isYieldableFn
		HOST_FUNC_NAMES[isYieldableFn] = "isyieldable"
	end
end
table.freeze(vmCoroutine)

local lockedMetaMap: { [any]: { [any]: any } } = setmetatable({}, { __mode = "kv" }) :: any
local proxyMetaMap: { [any]: { [any]: any } } = setmetatable({}, { __mode = "kv" }) :: any
local isolatedMathTables: { [any]: boolean } = setmetatable({}, { __mode = "k" }) :: any

local function isTrackedEnv(tbl: any): boolean
	return envContexts[tbl] ~= nil
end

local hostNewproxy: ((boolean?) -> any)? = newproxy :: any
local hostRawset: ({ [any]: any }, any, any) -> { [any]: any } = rawset
local hostTableClear: (({ [any]: any }) -> ())? = if table then table.clear else nil
local hostSetmetatable: ({ [any]: any }, { [any]: any }?) -> { [any]: any } = setmetatable :: any

local function vmNewproxy(addMt: any): any
	if hostNewproxy == nil then
		hostError("newproxy is not available", 2)
		return nil
	end
	local u = hostNewproxy(addMt)
	local mt = getmetatable(u)
	if type(mt) == "table" then
		proxyMetaMap[u] = mt
	end
	return u
end

local function vmRawget(...: any): any
	if select("#", ...) < 2 then
		return (hostRawget :: any)(...)
	end
	local tbl, k = ...
	if type(tbl) ~= "table" then
		return (hostRawget :: any)(...)
	end
	local res = hostRawget(tbl, k)
	if res == nil then
		return nil
	end
	return wrapExtractedValue(res, getActiveRlWrappers())
end

local function vmNext(...: any): ...any
	if select("#", ...) == 0 then
		return (hostNext :: any)(...)
	end
	local tbl, k = ...
	if type(tbl) ~= "table" then
		return (hostNext :: any)(...)
	end
	local nk, nv = hostNext(tbl, k)
	if nk == nil then
		return nil
	end
	local rlWrappers = getActiveRlWrappers()
	return wrapExtractedValue(nk, rlWrappers), wrapExtractedValue(nv, rlWrappers)
end

local function vmGetmetatable(...: any): any
	if select("#", ...) == 0 then
		return (hostGetmetatable :: any)()
	end
	local obj = ...
	if type(obj) == "string" then
		return "The metatable is locked"
	end
	return (hostGetmetatable :: any)(...)
end

local function vmRawset(tbl: { [any]: any }, k: any, v: any): { [any]: any }
	if type(tbl) == "table" then
		if roProxyData[tbl] ~= nil then
			hostError("attempt to modify a readonly table", 2)
		end
		if envContexts[tbl] ~= nil then
			invalidateEnvRoot(nil, tbl, k)
		end
	end
	return hostRawset(tbl, k, v)
end

local function vmTableClear(tbl: { [any]: any })
	if type(tbl) == "table" then
		if roProxyData[tbl] ~= nil then
			hostError("attempt to modify a readonly table", 2)
		end
		if envContexts[tbl] ~= nil then
			invalidateEnvAll(nil, tbl)
		end
	end
	if hostTableClear ~= nil then
		hostTableClear(tbl)
	end
end

local function recordLockedMetatable(tbl: any, mt: any)
	if type(mt) == "table" and rawget(mt, "__metatable") ~= nil then
		lockedMetaMap[tbl] = mt
	elseif mt == nil then
		lockedMetaMap[tbl] = nil
	end
end

local function vmSetmetatable(tbl: { [any]: any }, mt: { [any]: any }?): { [any]: any }
	if type(tbl) == "table" and envContexts[tbl] ~= nil then
		invalidateEnvAll(nil, tbl)
	end
	local res = hostSetmetatable(tbl, mt)
	recordLockedMetatable(tbl, mt)
	return res
end

local function vmCollectgarbage(opt: any?): any
	if opt == nil then
		return
	end
	if type(opt) ~= "string" and type(opt) ~= "number" then
		hostError("bad argument #1 to 'collectgarbage' (string expected, got " .. typeofFn(opt) .. ")", 2)
	end
	local s = tostring(opt)
	if s == "count" then
		return gcinfo()
	elseif s == "collect" then
		return
	end
	hostError("collectgarbage must be called with 'count' or 'collect'", 2)
	return nil
end

local rngSeedCounter = 0
local rngBaseSeed = bit32.bxor(
	math.floor(os.clock() * 1000000) % 4294967296,
	((if os and os.time then os.time() else 0) * 0x45D9F3B) % 4294967296
)

@native
local function pcgNext(rng: { number }): number
	local oldLo = rng[1]
	local oldHi = rng[2]
	local a0 = band(oldLo, 0xffff)
	local a1 = rshift(oldLo, 16)
	local a2 = band(oldHi, 0xffff)
	local a3 = rshift(oldHi, 16)

	local t0 = a0 * 0x7F2D + 0x5BDB
	local r0 = t0 % 65536
	local t1 = a0 * 0x4C95 + a1 * 0x7F2D + 0x94B9 + math.floor(t0 / 65536)
	local r1 = t1 % 65536
	local t2 = a0 * 0xF42D + a1 * 0x4C95 + a2 * 0x7F2D + 0x39CB + math.floor(t1 / 65536)
	local r2 = t2 % 65536
	local t3 = (a0 * 0x5851 + a1 * 0xF42D + a2 * 0x4C95 + a3 * 0x7F2D + 0xDA3E + math.floor(t2 / 65536)) % 65536

	rng[1] = r0 + r1 * 65536
	rng[2] = r2 + t3 * 65536

	local xorshifted = bit32.bxor(bor(rshift(oldLo, 27), lshift(oldHi, 5)), rshift(oldHi, 13))
	local rot = rshift(oldHi, 27)
	return bit32.rrotate(xorshifted, rot)
end

@native
local function pcgSeed(rng: { number }, seedLo: number, seedHi: number)
	rng[1] = 0
	rng[2] = 0
	pcgNext(rng)
	local lo = rng[1] + band(seedLo, 0xffffffff)
	local carry = math.floor(lo / 4294967296)
	rng[1] = lo % 4294967296
	rng[2] = (rng[2] + band(seedHi, 0xffffffff) + carry) % 4294967296
	pcgNext(rng)
end

local function checkMathInt(v: any, argIdx: number, fnName: string): (boolean, number)
	local n = if type(v) == "number" then v else tonumber(v)
	if n == nil then
		hostError(string.format("bad argument #%d to '%s' (number expected, got %s)", argIdx, fnName, typeofFn(v)), 2)
	end
	local num = n :: number
	if num ~= num or num >= 2147483648 or num < -2147483648 then
		return false, 0
	end
	return true, truncTowardZero(num)
end

local function createIsolatedMath(): { [string]: any }
	rngSeedCounter += 1
	local rng = { 0, 0 }
	local clockTicks = math.floor(os.clock() * 1000000) % 4294967296
	pcgSeed(
		rng,
		bit32.bxor(rngBaseSeed, (rngSeedCounter * 0x9E3779B9) % 4294967296),
		bit32.bxor(clockTicks, (rngSeedCounter * 0x85EBCA6B) % 4294967296)
	)

	local function isoRandom(...: any): number
		local argc = select("#", ...)
		if argc == 0 then
			local rl = pcgNext(rng)
			local rh = pcgNext(rng)
			return (rshift(rh, 11) * 4294967296 + rl) * (2 ^ -53)
		elseif argc == 1 then
			local okU, u = checkMathInt((...), 1, "random")
			if not okU or u < 1 then
				hostError("bad argument #1 to 'random' (interval is empty)", 2)
			end
			return 1 + math.floor(u * (pcgNext(rng) / 4294967296))
		elseif argc == 2 then
			local lArg, uArg = ...
			local okL, l = checkMathInt(lArg, 1, "random")
			local okU, u = checkMathInt(uArg, 2, "random")
			if not okL or not okU or u < l then
				hostError("bad argument #2 to 'random' (interval is empty)", 2)
			end
			local ul = u - l
			if ul >= 4294967295 then
				hostError("bad argument #2 to 'random' (interval is too large)", 2)
			end
			return l + math.floor((ul + 1) * (pcgNext(rng) / 4294967296))
		end
		hostError("wrong number of arguments", 2)
		return 0
	end

	local function isoRandomseed(seedArg: any)
		local _, seedInt = checkMathInt(seedArg, 1, "randomseed")
		local sLo = band(seedInt, 0xffffffff)
		local sHi = if seedInt < 0 then 0xffffffff else 0
		pcgSeed(rng, sLo, sHi)
	end

	HOST_FUNC_NAMES[isoRandom] = "random"
	HOST_FUNC_NAMES[isoRandomseed] = "randomseed"

	local m: { [string]: any } = table.clone(math :: any)
	m.random = isoRandom
	m.randomseed = isoRandomseed
	table.freeze(m)
	isolatedMathTables[m] = true
	return m
end

local vmTable: { [string]: any } = {}
if table then
	for k, v in table :: { [string]: any } do
		vmTable[k] = v
	end
	if hostTableClear ~= nil then
		vmTable.clear = vmTableClear
	end
end
table.freeze(vmTable)

SAFE_ROOT_VALUES.getmetatable = vmGetmetatable
SAFE_ROOT_VALUES.next = vmNext
SAFE_ROOT_VALUES.rawget = vmRawget
SAFE_ROOT_VALUES.rawset = vmRawset
SAFE_ROOT_VALUES.setmetatable = vmSetmetatable
SAFE_ROOT_VALUES.table = vmTable

local HOST_WRAPPERS: { [any]: any } = {
	[hostError] = vmError,
	[hostGetmetatable] = vmGetmetatable,
	[hostNext] = vmNext,
	[hostRawget] = vmRawget,
	[hostRawset] = vmRawset,
	[hostSetmetatable] = vmSetmetatable,
}
if hostNewproxy ~= nil then
	HOST_WRAPPERS[hostNewproxy] = vmNewproxy
	HOST_FUNC_NAMES[vmNewproxy] = "newproxy"
end
HOST_FUNC_NAMES[vmError] = "error"
HOST_FUNC_NAMES[guestGetfenv] = "getfenv"
HOST_FUNC_NAMES[guestSetfenv] = "setfenv"
HOST_FUNC_NAMES[vmGetmetatable] = "getmetatable"
HOST_FUNC_NAMES[vmNext] = "next"
HOST_FUNC_NAMES[vmRawget] = "rawget"
HOST_FUNC_NAMES[guestDebugTraceback] = "traceback"
HOST_FUNC_NAMES[guestDebugInfo] = "info"
HOST_FUNC_NAMES[vmRawset] = "rawset"
HOST_FUNC_NAMES[vmTableClear] = "clear"
HOST_FUNC_NAMES[vmSetmetatable] = "setmetatable"
HOST_FUNC_NAMES[vmCollectgarbage] = "collectgarbage"
local hostCollectgarbage: any = HostEnv.getHostEnv().collectgarbage
if hostCollectgarbage ~= nil then
	HOST_WRAPPERS[hostCollectgarbage] = vmCollectgarbage
end
if hostGetfenv ~= nil then
	HOST_WRAPPERS[hostGetfenv] = guestGetfenv
end
if hostSetfenv ~= nil then
	HOST_WRAPPERS[hostSetfenv] = guestSetfenv
end
if hostDebug ~= nil then
	HOST_WRAPPERS[hostDebug] = vmDebug
end
if hostTraceback ~= nil then
	HOST_WRAPPERS[hostTraceback] = guestDebugTraceback
end
if hostDebugInfo ~= nil then
	HOST_WRAPPERS[hostDebugInfo] = guestDebugInfo
end
if hostCoroutine ~= nil then
	HOST_WRAPPERS[hostCoroutine] = vmCoroutine
end
if hostCoroutineCreate ~= nil then
	HOST_WRAPPERS[hostCoroutineCreate] = vmCoroutine.create
end
if hostCoroutineWrap ~= nil then
	HOST_WRAPPERS[hostCoroutineWrap] = vmCoroutine.wrap
end
if hostCoroutineClose ~= nil then
	HOST_WRAPPERS[hostCoroutineClose] = vmCoroutine.close
end
if hostCoroutineYield ~= nil then
	HOST_WRAPPERS[hostCoroutineYield] = vmCoroutine.yield
end
if hostCoroutineIsYieldable ~= nil then
	HOST_WRAPPERS[hostCoroutineIsYieldable] = vmCoroutine.isyieldable
end
if table ~= nil then
	HOST_WRAPPERS[table] = vmTable
end
if hostTableClear ~= nil then
	HOST_WRAPPERS[hostTableClear] = vmTableClear
end

wrapExtractedValue = function(val: any, rlWrappers: { [unknown]: unknown }?): any
	if val == nil then
		return nil
	end
	local t = type(val)
	if t == "function" or t == "table" then
		val = HOST_WRAPPERS[val] or val
		if rlWrappers ~= nil then
			val = rlWrappers[val] or val
		end
	end
	return val
end

local registeredXpcall: any = xpcall

local STD_BASE: { [string]: any } = {
	assert = assert,
	collectgarbage = vmCollectgarbage,
	error = vmError,
	gcinfo = gcinfo,
	getfenv = guestGetfenv,
	getmetatable = vmGetmetatable,
	ipairs = ipairs,
	loadstring = nil,
	newproxy = if hostNewproxy ~= nil then vmNewproxy else nil,
	next = vmNext,
	pairs = pairs,
	pcall = pcall,
	print = print,
	rawequal = rawequal,
	rawget = vmRawget,
	rawlen = rawlen,
	rawset = vmRawset,
	select = select,
	setfenv = guestSetfenv,
	setmetatable = vmSetmetatable,
	tonumber = tonumber,
	tostring = tostring,
	type = type,
	typeof = typeofFn,
	unpack = unpack or table.unpack,
	xpcall = xpcall,
	_VERSION = _VERSION,
}

local STD_LIBRARIES: { [string]: { [string]: any } } = {
	base = STD_BASE,
	bit32 = table.freeze({ bit32 = bit32 } :: { [string]: any }),
	buffer = table.freeze({ buffer = buffer } :: { [string]: any }),
	coroutine = table.freeze({ coroutine = vmCoroutine } :: { [string]: any }),
	debug = table.freeze({ debug = vmDebug } :: { [string]: any }),
	math = table.freeze({ math = math } :: { [string]: any }),
	os = table.freeze({ os = os } :: { [string]: any }),
	string = table.freeze({ string = string } :: { [string]: any }),
	table = table.freeze({ table = vmTable, unpack = unpack or table.unpack } :: { [string]: any }),
	utf8 = table.freeze({ utf8 = utf8 } :: { [string]: any }),
	vector = table.freeze({ vector = vector } :: { [string]: any }),
}

local STD_KEY_OWNER: { [any]: string } = {}
local pureGlobals: { [string]: any } = {}
local hostBackedGlobals: { [string]: any } = {}
for libName, libEntries in STD_LIBRARIES do
	for k, v in libEntries do
		if k == "unpack" and libName == "table" then
			continue
		end
		STD_KEY_OWNER[k] = libName
		if k ~= "math" then
			pureGlobals[k] = v
			hostBackedGlobals[k] = v
		end
	end
end
STD_KEY_OWNER["loadstring"] = "base"
table.freeze(STD_KEY_OWNER)

local function resolveHostGlobalFallback(k: any): any
	if k == "_G" or k == "script" or k == "loadstring" or k == "math" then
		return nil
	elseif k == "collectgarbage" then
		return vmCollectgarbage
	elseif k == "getfenv" then
		return guestGetfenv
	elseif k == "setfenv" then
		return guestSetfenv
	elseif k == "getmetatable" then
		return vmGetmetatable
	elseif k == "next" then
		return vmNext
	elseif k == "rawget" then
		return vmRawget
	elseif k == "debug" then
		return vmDebug
	elseif k == "error" then
		return vmError
	elseif k == "newproxy" then
		return if hostNewproxy ~= nil then vmNewproxy else nil
	elseif k == "xpcall" then
		return registeredXpcall
	elseif k == "rawset" then
		return vmRawset
	elseif k == "setmetatable" then
		return vmSetmetatable
	elseif k == "coroutine" then
		return vmCoroutine
	elseif k == "table" then
		return vmTable
	end
	return HostEnv.getHostEnv()[k]
end

local HOST_BACKED_META = table.freeze({
	__index = function(_tbl: unknown, k: unknown): unknown
		return resolveHostGlobalFallback(k)
	end,
})
setmetatable(hostBackedGlobals, HOST_BACKED_META)

local PURE_ENV_MT = table.freeze({
	__metatable = "locked",
	__index = pureGlobals,
})

local HOST_ENV_MT = table.freeze({
	__metatable = "locked",
	__index = hostBackedGlobals,
})

local envMetaMap: { [any]: any } = (setmetatable({}, { __mode = "kv" }) :: unknown) :: { [any]: any }
local envBackingTable: { [any]: { [any]: any } } = setmetatable({}, { __mode = "kv" }) :: any
local filteredHostEnv: { [any]: { backing: { [any]: any }, allowed: { [string]: boolean } } } = setmetatable(
	{},
	{ __mode = "kv" }
) :: any
local envResourceLimits: { [unknown]: ResourceLimits } = (setmetatable({}, { __mode = "k" }) :: unknown) :: {
	[unknown]: ResourceLimits,
}

local VALID_RESOURCE_LIMIT_KEYS: { [any]: boolean } = table.freeze({
	maxStringLength = true,
	maxTableSize = true,
	maxBufferSize = true,
	maxPatternLength = true,
}) :: any

local VALID_ENV_OPTION_KEYS: { [any]: boolean } = table.freeze({
	inheritHost = true,
	libraries = true,
	readOnly = true,
	resourceLimits = true,
}) :: any

local VALID_LOAD_OPTION_KEYS: { [any]: boolean } = table.freeze({
	name = true,
	env = true,
	compile = true,
	decoder = true,
	mode = true,
	timeout = true,
	instructionLimit = true,
	callLimit = true,
	interruptInterval = true,
	interrupt = true,
	getGlobal = true,
	setGlobal = true,
	safeEnv = true,
	resourceLimits = true,
	onCall = true,
	onReturn = true,
	onLine = true,
	onBreak = true,
}) :: any

local function validateResourceLimits(raw: unknown, errLevel: number): ResourceLimits
	if type(raw) ~= "table" then
		hostError("resourceLimits must be a table", errLevel)
	end
	for k in raw :: { [any]: any } do
		if not VALID_RESOURCE_LIMIT_KEYS[k] then
			hostError("unknown resourceLimits option: " .. tostring(k), errLevel)
		end
	end
	local rl = raw :: ResourceLimits
	local maxStr = rl.maxStringLength
	if maxStr ~= nil and (type(maxStr) ~= "number" or maxStr ~= maxStr or maxStr < 0 or maxStr == math.huge) then
		hostError("invalid maxStringLength: expected non-negative finite number", errLevel)
	end
	local maxTbl = rl.maxTableSize
	if maxTbl ~= nil and (type(maxTbl) ~= "number" or maxTbl ~= maxTbl or maxTbl < 0 or maxTbl == math.huge) then
		hostError("invalid maxTableSize: expected non-negative finite number", errLevel)
	end
	local maxBuf = rl.maxBufferSize
	if maxBuf ~= nil and (type(maxBuf) ~= "number" or maxBuf ~= maxBuf or maxBuf < 0 or maxBuf == math.huge) then
		hostError("invalid maxBufferSize: expected non-negative finite number", errLevel)
	end
	local maxPat = rl.maxPatternLength
	if maxPat ~= nil and (type(maxPat) ~= "number" or maxPat ~= maxPat or maxPat < 0 or maxPat == math.huge) then
		hostError("invalid maxPatternLength: expected non-negative finite number", errLevel)
	end
	local out: ResourceLimits = {
		maxStringLength = maxStr,
		maxTableSize = maxTbl,
		maxBufferSize = maxBuf,
		maxPatternLength = maxPat,
	}
	return out
end

local hostStringRep: (...unknown) -> string = (string.rep :: unknown) :: (...unknown) -> string
local hostStringFormat: (...unknown) -> string = (string.format :: unknown) :: (...unknown) -> string
local hostStringChar: (...unknown) -> string = (string.char :: unknown) :: (...unknown) -> string
local hostStringPack: ((...unknown) -> string)? = ((string :: unknown) :: { pack: ((...unknown) -> string)? }).pack
local hostStringSplit: ((...unknown) -> { string })? = ((string :: unknown) :: { split: ((...unknown) -> { string })? }).split
local hostStringFind: (...unknown) -> ...unknown = (string.find :: unknown) :: (...unknown) -> ...unknown
local hostStringMatch: (...unknown) -> ...unknown = (string.match :: unknown) :: (...unknown) -> ...unknown
local hostStringGmatch: (...unknown) -> ...unknown = (string.gmatch :: unknown) :: (...unknown) -> ...unknown
local hostStringGsub: (...unknown) -> (string, number) = (string.gsub :: unknown) :: (...unknown) -> (string, number)
local hostTableCreate: (number, unknown?) -> { unknown } = (table.create :: unknown) :: (
	number,
	unknown?
) -> { unknown }
local hostTableConcat: (...unknown) -> string = (table.concat :: unknown) :: (...unknown) -> string
local hostTableMove: (...unknown) -> { unknown } = (table.move :: unknown) :: (...unknown) -> { unknown }
local hostTablePack: (...unknown) -> { [number]: unknown, n: number } = (
	table.pack :: unknown
) :: (...unknown) -> { [number]: unknown, n: number }
local hostTableClone: (unknown) -> unknown = (table.clone :: unknown) :: (unknown) -> unknown
local hostUtf8Char: ((...unknown) -> string)? = if utf8 then (utf8.char :: unknown) :: (...unknown) -> string else nil
local hostOsDate: ((...unknown) -> unknown)? = if os ~= nil
	then ((os :: unknown) :: { date: ((...unknown) -> unknown)? }).date
	else nil
local hostBufferCreate: ((number) -> buffer)? = if buffer then buffer.create else nil
local hostBufferFromstring: ((string) -> buffer)? = if buffer then buffer.fromstring else nil
local hostBufferReadstring: ((buffer, number, number) -> string)? = if buffer then buffer.readstring else nil
local hostBufferTostring: ((buffer) -> string)? = if buffer then buffer.tostring else nil

local function checkPatternLimit(pat: unknown, limitPat: number)
	if type(pat) == "string" then
		if #(pat :: string) > limitPat then
			hostError("pattern length limit exceeded", 3)
		end
	elseif type(pat) == "number" then
		if #tostring(pat) > limitPat then
			hostError("pattern length limit exceeded", 3)
		end
	end
end

local function buildResourceLimitArtifacts(rl: ResourceLimits): ({ [unknown]: unknown }, { [string]: unknown }?, { [string]: unknown }?, {
	[string]: unknown,
}?, { [string]: unknown }?, { [string]: unknown }?)
	local maxStr = rl.maxStringLength
	local maxTbl = rl.maxTableSize
	local maxBuf = rl.maxBufferSize
	local maxPat = rl.maxPatternLength
	local wrappers: { [unknown]: unknown } = {}
	local wrappedString: { [string]: unknown }? = nil
	local wrappedTable: { [string]: unknown }? = nil
	local wrappedBuffer: { [string]: unknown }? = nil
	local wrappedUtf8: { [string]: unknown }? = nil
	local wrappedOs: { [string]: unknown }? = nil

	if maxStr ~= nil or maxPat ~= nil or maxTbl ~= nil then
		local sLib: { [string]: unknown } = table.clone((string :: unknown) :: { [string]: unknown })
		if maxStr ~= nil then
			local limitStr: number = maxStr
			local function guardedRep(s: unknown, n: unknown, sep: unknown?): string
				if (type(s) == "string" or type(s) == "number") and (type(n) == "number" or type(n) == "string") then
					local nNum = tonumber(n)
					if nNum ~= nil and nNum >= 1 then
						local reps = math.floor(nNum)
						local sLen = #tostring(s)
						local sepLen = if sep ~= nil and (type(sep) == "string" or type(sep) == "number")
							then #tostring(sep)
							else 0
						if (sLen > 0 and reps > limitStr / sLen) or (sepLen > 0 and (reps - 1) > limitStr / sepLen) then
							hostError("string length limit exceeded", 2)
						end
						if reps * sLen + (reps - 1) * sepLen > limitStr then
							hostError("string length limit exceeded", 2)
						end
					end
				end
				local res = if sep ~= nil then hostStringRep(s, n, sep) else hostStringRep(s, n)
				if #res > limitStr then
					hostError("string length limit exceeded", 2)
				end
				return res
			end
			local function guardedFormat(fmt: unknown, ...: unknown): string
				if type(fmt) == "string" or type(fmt) == "number" then
					local fmtStr = if type(fmt) == "string" then fmt :: string else tostring(fmt)
					if #fmtStr > limitStr then
						hostError("string length limit exceeded", 2)
					end
					local stripped = hostStringGsub(fmtStr, "%%%%", "")
					local totalBound = 0
					for w, p, conv in
						hostStringGmatch(stripped, "%%[-+ #0]*(%d*)%.?(%d*)([a-zA-Z]?)") :: () -> (string?, string?, string?)
					do
						local wn = if w ~= nil and #w > 0 then tonumber(w) else 0
						local pn = if p ~= nil and #p > 0 then tonumber(p) else 0
						if wn ~= nil and wn > limitStr then
							hostError("string length limit exceeded", 2)
						end
						local pMin = 0
						if
							pn ~= nil
							and conv ~= nil
							and #conv == 1
							and hostStringFind("diuoxXfeEaA", conv, 1, true) ~= nil
						then
							if pn > limitStr then
								hostError("string length limit exceeded", 2)
							end
							pMin = pn
						elseif pn ~= nil and (conv == "g" or conv == "G") and pn > limitStr then
							hostError("string length limit exceeded", 2)
						end
						local minOut = if (wn or 0) > pMin then (wn or 0) else pMin
						if minOut > 0 then
							totalBound += minOut
							if totalBound > limitStr then
								hostError("string length limit exceeded", 2)
							end
						end
					end
				end
				local res = hostStringFormat(fmt, ...)
				if #res > limitStr then
					hostError("string length limit exceeded", 2)
				end
				return res
			end
			local function guardedChar(...: unknown): string
				if select("#", ...) > limitStr then
					hostError("string length limit exceeded", 2)
				end
				return hostStringChar(...)
			end
			sLib.rep = guardedRep
			sLib.format = guardedFormat
			sLib.char = guardedChar
			wrappers[hostStringRep] = guardedRep
			wrappers[hostStringFormat] = guardedFormat
			wrappers[hostStringChar] = guardedChar
			HOST_FUNC_NAMES[guardedRep] = "rep"
			HOST_FUNC_NAMES[guardedFormat] = "format"
			HOST_FUNC_NAMES[guardedChar] = "char"
			local strPack = hostStringPack
			if strPack ~= nil then
				local function guardedPack(fmt: unknown, ...: unknown): string
					if type(fmt) == "string" then
						local totalFixed = 0
						for w in hostStringGmatch(fmt, "c(%d+)") :: () -> string? do
							local wn = tonumber(w)
							if wn ~= nil then
								if wn > limitStr then
									hostError("string length limit exceeded", 2)
								end
								totalFixed += wn
								if totalFixed > limitStr then
									hostError("string length limit exceeded", 2)
								end
							end
						end
					end
					local res = strPack(fmt, ...)
					if #res > limitStr then
						hostError("string length limit exceeded", 2)
					end
					return res
				end
				sLib.pack = guardedPack
				wrappers[strPack] = guardedPack
				HOST_FUNC_NAMES[guardedPack] = "pack"
			end
		end
		if maxPat ~= nil then
			local limitPat: number = maxPat
			local function guardedFind(s: unknown, pat: unknown, init: unknown?, plain: unknown?): ...unknown
				checkPatternLimit(pat, limitPat)
				return hostStringFind(s, pat, init, plain)
			end
			local function guardedMatch(s: unknown, pat: unknown, init: unknown?): ...unknown
				checkPatternLimit(pat, limitPat)
				return hostStringMatch(s, pat, init)
			end
			local function guardedGmatch(s: unknown, pat: unknown): ...unknown
				checkPatternLimit(pat, limitPat)
				return hostStringGmatch(s, pat)
			end
			sLib.find = guardedFind
			sLib.match = guardedMatch
			sLib.gmatch = guardedGmatch
			wrappers[hostStringFind] = guardedFind
			wrappers[hostStringMatch] = guardedMatch
			wrappers[hostStringGmatch] = guardedGmatch
			HOST_FUNC_NAMES[guardedFind] = "find"
			HOST_FUNC_NAMES[guardedMatch] = "match"
			HOST_FUNC_NAMES[guardedGmatch] = "gmatch"
		end
		if maxPat ~= nil or maxStr ~= nil then
			local function guardedGsub(s: unknown, pat: unknown, repl: unknown, n: unknown?): (string, number)
				if maxPat ~= nil then
					checkPatternLimit(pat, maxPat)
				end
				if maxStr ~= nil and (type(repl) == "string" or type(repl) == "number") then
					local replStr = if type(repl) == "string" then repl :: string else tostring(repl)
					local replLen = #replStr
					if replLen > maxStr then
						hostError("string length limit exceeded", 2)
					end
					if type(s) == "string" or type(s) == "number" then
						local sStr = if type(s) == "string" then s :: string else tostring(s)
						if type(pat) == "string" or type(pat) == "number" then
							local patStr = if type(pat) == "string" then pat :: string else tostring(pat)
							local sLen = #sStr
							local maxRepl = sLen + 1
							if n ~= nil then
								local nNum = tonumber(n)
								if nNum ~= nil then
									if nNum <= 0 then
										maxRepl = 0
									elseif nNum < maxRepl then
										maxRepl = math.floor(nNum)
									end
								end
							end
							local _, backrefCount = hostStringGsub(hostStringGsub(replStr, "%%%%", ""), "%%[0-9]", "")
							local worstUnit = replLen + backrefCount * sLen
							if maxRepl > 0 and worstUnit > maxStr / maxRepl then
								local pos = 1
								local matches = 0
								local emitted = 0
								local totalMatched = 0
								local lastEnd = -1
								while matches < maxRepl and pos <= sLen + 1 do
									local mStart, mEnd = hostStringFind(sStr, patStr, pos)
									if mStart == nil then
										break
									end
									local ms = mStart :: number
									local me = mEnd :: number
									if me < ms and ms == lastEnd + 1 and pos > 1 then
										pos += 1
										continue
									end
									matches += 1
									local matchBytes = if me >= ms then (me - ms + 1) else 0
									totalMatched += matchBytes
									emitted += replLen + backrefCount * matchBytes
									if emitted > maxStr then
										hostError("string length limit exceeded", 2)
									end
									if me >= ms then
										lastEnd = me
										pos = me + 1
									else
										lastEnd = -1
										pos = ms + 1
									end
								end
								if sLen - totalMatched + emitted > maxStr then
									hostError("string length limit exceeded", 2)
								end
							end
						end
					end
				end
				local res, cnt = hostStringGsub(s, pat, repl, n)
				if maxStr ~= nil and #res > maxStr then
					hostError("string length limit exceeded", 2)
				end
				return res, cnt
			end
			sLib.gsub = guardedGsub
			wrappers[hostStringGsub] = guardedGsub
			HOST_FUNC_NAMES[guardedGsub] = "gsub"
		end
		local strSplit = hostStringSplit
		if maxTbl ~= nil and strSplit ~= nil then
			local limitTbl: number = maxTbl
			local function guardedSplit(s: unknown, sep: unknown?): { string }
				if type(s) == "string" and (sep == nil or type(sep) == "string") then
					local sStr = s :: string
					local sepStr = if sep ~= nil then sep :: string else ","
					local sepLen = #sepStr
					if sepLen == 0 then
						if #sStr > limitTbl then
							hostError("table size limit exceeded", 2)
						end
					elseif math.floor(#sStr / sepLen) + 1 > limitTbl then
						local parts = 1
						local pos = 1
						while true do
							local mStart, mEnd = hostStringFind(sStr, sepStr, pos, true)
							if mStart == nil then
								break
							end
							parts += 1
							if parts > limitTbl then
								hostError("table size limit exceeded", 2)
							end
							pos = (mEnd :: number) + 1
						end
					end
				end
				local res = strSplit(s, sep)
				if #res > limitTbl then
					hostError("table size limit exceeded", 2)
				end
				return res
			end
			sLib.split = guardedSplit
			wrappers[strSplit] = guardedSplit
			HOST_FUNC_NAMES[guardedSplit] = "split"
		end
		table.freeze(sLib)
		wrappedString = sLib
		wrappers[string] = sLib
	end

	if maxTbl ~= nil or maxStr ~= nil then
		local tLib: { [string]: unknown } = table.clone((vmTable :: unknown) :: { [string]: unknown })
		if maxTbl ~= nil then
			local limitTbl: number = maxTbl
			local function guardedCreate(count: unknown, ...: unknown): { unknown }
				local cntNum = tonumber(count)
				if cntNum ~= nil and cntNum > limitTbl then
					hostError("table size limit exceeded", 2)
				end
				return if select("#", ...) >= 1
					then hostTableCreate(count :: number, (...))
					else hostTableCreate(count :: number)
			end
			local function guardedMove(src: unknown, a: unknown, b: unknown, t: unknown, ...: unknown): { unknown }
				local aN = tonumber(a)
				local bN = tonumber(b)
				local tN = tonumber(t)
				if aN ~= nil and bN ~= nil and tN ~= nil then
					local cnt = math.floor(bN) - math.floor(aN) + 1
					local tInt = math.floor(tN)
					if cnt > 0 and (cnt > limitTbl or (tInt >= 1 and tInt + cnt - 1 > limitTbl)) then
						hostError("table size limit exceeded", 2)
					end
				end
				return if select("#", ...) >= 1 then hostTableMove(src, a, b, t, (...)) else hostTableMove(src, a, b, t)
			end
			local function guardedPack(...: unknown): { [number]: unknown, n: number }
				if select("#", ...) > limitTbl then
					hostError("table size limit exceeded", 2)
				end
				return hostTablePack(...)
			end
			local function guardedClone(t: unknown): unknown
				if type(t) == "table" then
					local srcTbl: { [any]: any } = t :: any
					if #srcTbl > limitTbl then
						hostError("table size limit exceeded", 2)
					end
					local count = 0
					local k = hostNext(srcTbl, nil)
					while k ~= nil do
						count += 1
						if count > limitTbl then
							hostError("table size limit exceeded", 2)
						end
						k = hostNext(srcTbl, k)
					end
					return hostTableClone(t)
				end
				return hostTableClone(t)
			end
			tLib.create = guardedCreate
			tLib.move = guardedMove
			tLib.pack = guardedPack
			tLib.clone = guardedClone
			wrappers[hostTableCreate] = guardedCreate
			wrappers[hostTableMove] = guardedMove
			wrappers[hostTablePack] = guardedPack
			wrappers[hostTableClone] = guardedClone
			HOST_FUNC_NAMES[guardedCreate] = "create"
			HOST_FUNC_NAMES[guardedMove] = "move"
			HOST_FUNC_NAMES[guardedPack] = "pack"
			HOST_FUNC_NAMES[guardedClone] = "clone"
		end
		local function guardedConcat(list: unknown, sep: unknown?, i: unknown?, j: unknown?): string
			if type(list) == "table" then
				local listTbl: { [any]: any } = list :: any
				local listLen = #listTbl
				if maxTbl ~= nil and listLen > maxTbl then
					hostError("table size limit exceeded", 2)
				end
				local iN = if i ~= nil then tonumber(i) else 1
				local jN = if j ~= nil then tonumber(j) else listLen
				if iN ~= nil and jN ~= nil then
					local startIdx = math.floor(iN)
					local endIdx = math.floor(jN)
					local cnt = endIdx - startIdx + 1
					if maxTbl ~= nil and cnt > maxTbl then
						hostError("table size limit exceeded", 2)
					end
					if maxStr ~= nil and cnt >= 1 then
						local sepLen = if sep ~= nil and (type(sep) == "string" or type(sep) == "number")
							then #tostring(sep)
							else 0
						if cnt > 1 and sepLen > 0 and (cnt - 1) > maxStr / sepLen then
							hostError("string length limit exceeded", 2)
						end
						local totalLen = if cnt > 1 then (cnt - 1) * sepLen else 0
						for idx = startIdx, endIdx do
							local v = listTbl[idx]
							if type(v) == "string" then
								totalLen += #(v :: string)
							elseif type(v) == "number" then
								totalLen += #tostring(v)
							else
								break
							end
							if totalLen > maxStr then
								hostError("string length limit exceeded", 2)
							end
						end
					end
				end
			end
			local res = hostTableConcat(list, sep, i, j)
			if maxStr ~= nil and #res > maxStr then
				hostError("string length limit exceeded", 2)
			end
			return res
		end
		tLib.concat = guardedConcat
		wrappers[hostTableConcat] = guardedConcat
		HOST_FUNC_NAMES[guardedConcat] = "concat"
		table.freeze(tLib)
		wrappedTable = tLib
		wrappers[table] = tLib
		wrappers[vmTable] = tLib
	end

	local bufCreate = hostBufferCreate
	local bufFromstring = hostBufferFromstring
	local bufReadstring = hostBufferReadstring
	local bufTostring = hostBufferTostring
	if (maxBuf ~= nil or maxStr ~= nil) and buffer ~= nil then
		local bLib: { [string]: unknown } = table.clone((buffer :: unknown) :: { [string]: unknown })
		if maxBuf ~= nil and bufCreate ~= nil and bufFromstring ~= nil then
			local limitBuf: number = maxBuf
			local function guardedBufCreate(size: unknown): buffer
				local szNum = tonumber(size)
				if szNum ~= nil and szNum > limitBuf then
					hostError("buffer size limit exceeded", 2)
				end
				return bufCreate(size :: number)
			end
			local function guardedBufFromstring(str: unknown): buffer
				if type(str) == "string" or type(str) == "number" then
					local len = if type(str) == "string" then #(str :: string) else #tostring(str)
					if len > limitBuf then
						hostError("buffer size limit exceeded", 2)
					end
				end
				return bufFromstring(str :: string)
			end
			bLib.create = guardedBufCreate
			bLib.fromstring = guardedBufFromstring
			wrappers[bufCreate] = guardedBufCreate
			wrappers[bufFromstring] = guardedBufFromstring
			HOST_FUNC_NAMES[guardedBufCreate] = "create"
			HOST_FUNC_NAMES[guardedBufFromstring] = "fromstring"
		end
		if maxStr ~= nil then
			local limitStr: number = maxStr
			if bufReadstring ~= nil then
				local function guardedBufReadstring(b: unknown, offset: unknown, count: unknown): string
					local cntNum = tonumber(count)
					if cntNum ~= nil and cntNum > limitStr then
						hostError("string length limit exceeded", 2)
					end
					local res = bufReadstring(b :: buffer, offset :: number, count :: number)
					if #res > limitStr then
						hostError("string length limit exceeded", 2)
					end
					return res
				end
				bLib.readstring = guardedBufReadstring
				wrappers[bufReadstring] = guardedBufReadstring
				HOST_FUNC_NAMES[guardedBufReadstring] = "readstring"
			end
			if bufTostring ~= nil then
				local function guardedBufTostring(b: unknown): string
					if type(b) == "buffer" and buffer.len(b) > limitStr then
						hostError("string length limit exceeded", 2)
					end
					local res = bufTostring(b :: buffer)
					if #res > limitStr then
						hostError("string length limit exceeded", 2)
					end
					return res
				end
				bLib.tostring = guardedBufTostring
				wrappers[bufTostring] = guardedBufTostring
				HOST_FUNC_NAMES[guardedBufTostring] = "tostring"
			end
		end
		table.freeze(bLib)
		wrappedBuffer = bLib
		wrappers[buffer] = bLib
	end

	local utf8Char = hostUtf8Char
	if maxStr ~= nil and utf8 ~= nil and utf8Char ~= nil then
		local limitStr: number = maxStr
		local uLib: { [string]: unknown } = table.clone((utf8 :: unknown) :: { [string]: unknown })
		local function guardedUtf8Char(...: unknown): string
			if select("#", ...) > limitStr then
				hostError("string length limit exceeded", 2)
			end
			local res = utf8Char(...)
			if #res > limitStr then
				hostError("string length limit exceeded", 2)
			end
			return res
		end
		uLib.char = guardedUtf8Char
		wrappers[utf8Char] = guardedUtf8Char
		HOST_FUNC_NAMES[guardedUtf8Char] = "char"
		table.freeze(uLib)
		wrappedUtf8 = uLib
		wrappers[utf8] = uLib
	end

	local osDate = hostOsDate
	if maxStr ~= nil and os ~= nil and osDate ~= nil then
		local limitStr: number = maxStr
		local oLib: { [string]: unknown } = table.clone((os :: unknown) :: { [string]: unknown })
		local function guardedOsDate(...: unknown): unknown
			local res = osDate(...)
			if type(res) == "string" and #(res :: string) > limitStr then
				hostError("string length limit exceeded", 2)
			end
			return res
		end
		oLib.date = guardedOsDate
		wrappers[osDate] = guardedOsDate
		HOST_FUNC_NAMES[guardedOsDate] = "date"
		table.freeze(oLib)
		wrappedOs = oLib
		wrappers[os] = oLib
	end

	table.freeze(wrappers)
	return wrappers, wrappedString, wrappedTable, wrappedBuffer, wrappedUtf8, wrappedOs
end

local function getInternalMetatable(obj: any): { [any]: any }?
	local t = type(obj)
	if t ~= "table" and t ~= "userdata" then
		return nil
	end
	local rawMt = getmetatable(obj)
	if type(rawMt) == "table" then
		return rawMt
	end
	return envMetaMap[obj] or lockedMetaMap[obj] or proxyMetaMap[obj]
end

local function hasHostWrapperValue(tbl: { [any]: any }): boolean
	for _, v in tbl do
		if (type(v) == "function" or type(v) == "table") and HOST_WRAPPERS[v] ~= nil then
			return true
		end
	end
	return false
end

local function envNeedsHostWrappers(env: any): boolean
	if type(env) ~= "table" or not cleanVmEnvs[env] then
		return true
	end
	if table.isfrozen(env) or roProxyData[env] ~= nil then
		return false
	end
	local count = 0
	for _, v in env do
		count += 1
		if count > 32 then
			return true
		end
		if (type(v) == "function" or type(v) == "table") and HOST_WRAPPERS[v] ~= nil then
			return true
		end
	end
	return false
end

--- Creates an isolated VM global environment backed by pure Luau stdlib or optional host globals.
local function createEnvironment(overrides: { [any]: any }?, options: EnvironmentOptions?): { [any]: any }
	if overrides == nil and options == nil then
		local env: { [any]: any } = {}
		env._G = env
		env.math = createIsolatedMath()
		envMetaMap[env] = PURE_ENV_MT
		cleanVmEnvs[env] = true
		return setmetatable(env, PURE_ENV_MT) :: any
	end
	if overrides ~= nil and type(overrides) ~= "table" then
		hostError("environment overrides must be a table", 2)
	end
	if options ~= nil then
		if type(options) ~= "table" then
			hostError("environment options must be a table", 2)
		end
		for k in options :: { [any]: any } do
			if not VALID_ENV_OPTION_KEYS[k] then
				hostError("unknown environment option: " .. tostring(k), 2)
			end
		end
	end
	local inheritHost = if options ~= nil and options.inheritHost ~= nil then options.inheritHost else false
	local readOnly = if options ~= nil and options.readOnly ~= nil then options.readOnly else false
	local libraries = if options ~= nil then options.libraries else nil
	local rawResourceLimits = if options ~= nil then options.resourceLimits else nil
	if type(inheritHost) ~= "boolean" then
		hostError("environment inheritHost must be a boolean", 2)
	end
	if type(readOnly) ~= "boolean" then
		hostError("environment readOnly must be a boolean", 2)
	end
	if libraries ~= nil and type(libraries) ~= "table" then
		hostError("environment libraries must be a table", 2)
	end
	local resourceLimits: ResourceLimits? = if rawResourceLimits ~= nil
		then validateResourceLimits(rawResourceLimits, 2)
		else nil
	local rlString: { [string]: unknown }? = nil
	local rlTable: { [string]: unknown }? = nil
	local rlBuffer: { [string]: unknown }? = nil
	local rlUtf8: { [string]: unknown }? = nil
	local rlOs: { [string]: unknown }? = nil
	if resourceLimits ~= nil then
		local _
		_, rlString, rlTable, rlBuffer, rlUtf8, rlOs = buildResourceLimitArtifacts(resourceLimits)
	end

	local libBacking: { [string]: any }? = nil
	local allowed: { [string]: boolean }? = nil
	if libraries ~= nil then
		local lb: { [string]: any } = {}
		local al: { [string]: boolean } = {}
		for _, libName in libraries do
			local libTable = STD_LIBRARIES[libName]
			if not libTable then
				hostError("unknown standard library: " .. tostring(libName), 2)
			end
			al[libName] = true
			for k, v in libTable do
				if k ~= "math" then
					lb[k] = v
				end
			end
		end
		if rlString ~= nil and al["string"] then
			lb["string"] = rlString
		end
		if rlTable ~= nil and al["table"] then
			lb["table"] = rlTable
		end
		if rlBuffer ~= nil and al["buffer"] then
			lb["buffer"] = rlBuffer
		end
		if rlUtf8 ~= nil and al["utf8"] then
			lb["utf8"] = rlUtf8
		end
		if rlOs ~= nil and al["os"] then
			lb["os"] = rlOs
		end
		table.freeze(lb)
		table.freeze(al)
		libBacking = lb
		allowed = al
	end

	local wantIsolatedMath = (allowed == nil or allowed["math"] == true)
		and (overrides == nil or (overrides :: { [any]: any }).math == nil)

	if readOnly then
		if not inheritHost then
			local env: { [any]: any } = {}
			local src = libBacking or pureGlobals
			for k, v in src do
				env[k] = v
			end
			if libBacking == nil then
				if rlString ~= nil then
					env.string = rlString
				end
				if rlTable ~= nil then
					env.table = rlTable
				end
				if rlBuffer ~= nil then
					env.buffer = rlBuffer
				end
				if rlUtf8 ~= nil then
					env.utf8 = rlUtf8
				end
				if rlOs ~= nil then
					env.os = rlOs
				end
			end
			if wantIsolatedMath then
				env.math = createIsolatedMath()
			end
			env._G = env
			if overrides then
				for k, v in overrides do
					env[k] = v
				end
			end
			if overrides == nil or not hasHostWrapperValue(overrides) then
				cleanVmEnvs[env] = true
			end
			if resourceLimits ~= nil then
				envResourceLimits[env] = resourceLimits
			end
			return table.freeze(env)
		end

		local store: { [any]: any } = {}
		local overrideKeys: { [any]: boolean } = { _G = true, script = true, loadstring = true }
		if wantIsolatedMath then
			overrideKeys.math = true
			store.math = createIsolatedMath()
		end
		if rlString ~= nil and (allowed == nil or allowed["string"]) then
			overrideKeys.string = true
			store.string = rlString
		end
		if rlTable ~= nil and (allowed == nil or allowed["table"]) then
			overrideKeys.table = true
			store.table = rlTable
		end
		if rlBuffer ~= nil and (allowed == nil or allowed["buffer"]) then
			overrideKeys.buffer = true
			store.buffer = rlBuffer
		end
		if rlUtf8 ~= nil and (allowed == nil or allowed["utf8"]) then
			overrideKeys.utf8 = true
			store.utf8 = rlUtf8
		end
		if rlOs ~= nil and (allowed == nil or allowed["os"]) then
			overrideKeys.os = true
			store.os = rlOs
		end
		if overrides then
			for k, v in overrides do
				overrideKeys[k] = true
				store[k] = v
			end
		end
		local proxy: { [any]: any } = {}
		if overrides == nil or (overrides :: { [any]: any })._G == nil then
			store._G = proxy
		end
		table.freeze(store)
		table.freeze(overrideKeys)

		local roInfo = {
			store = store,
			overrideKeys = overrideKeys,
			mt = nil :: any,
			libBacking = libBacking,
			allowed = allowed,
		}
		local mt = table.freeze({
			__metatable = "locked",
			__index = function(_self: any, k: any): any
				if roInfo.overrideKeys[k] then
					return roInfo.store[k]
				end
				if roInfo.libBacking ~= nil and roInfo.allowed ~= nil then
					local bv = rawget(roInfo.libBacking, k)
					if bv ~= nil then
						return bv
					end
					local owner = STD_KEY_OWNER[k]
					if owner ~= nil and not roInfo.allowed[owner] then
						return nil
					end
					return resolveHostGlobalFallback(k)
				end
				return hostBackedGlobals[k]
			end,
			__newindex = function()
				hostError("attempt to modify a readonly table", 2)
			end,
		})
		roInfo.mt = mt
		table.freeze(roInfo)
		roProxyData[proxy] = roInfo :: any
		envMetaMap[proxy] = mt
		if libBacking ~= nil and allowed ~= nil then
			filteredHostEnv[mt] = table.freeze({ backing = libBacking, allowed = allowed }) :: any
		end
		if resourceLimits ~= nil then
			envResourceLimits[proxy] = resourceLimits
		end
		return setmetatable(proxy, mt) :: any
	end

	local env: { [any]: any } = {}
	env._G = env
	if wantIsolatedMath then
		env.math = createIsolatedMath()
	end
	if libBacking == nil then
		if rlString ~= nil then
			env.string = rlString
		end
		if rlTable ~= nil then
			env.table = rlTable
		end
		if rlBuffer ~= nil then
			env.buffer = rlBuffer
		end
		if rlUtf8 ~= nil then
			env.utf8 = rlUtf8
		end
		if rlOs ~= nil then
			env.os = rlOs
		end
	end
	if overrides then
		for k, v in overrides do
			env[k] = v
		end
	end
	if resourceLimits ~= nil then
		envResourceLimits[env] = resourceLimits
	end

	if libBacking == nil or allowed == nil then
		local mt = if inheritHost then HOST_ENV_MT else PURE_ENV_MT
		envMetaMap[env] = mt
		setmetatable(env, mt)
	else
		if inheritHost then
			local fh = table.freeze({ backing = libBacking, allowed = allowed })
			local indexFn = function(_tbl: any, k: any): any
				local bv = rawget(fh.backing, k)
				if bv ~= nil then
					return bv
				end
				local owner = STD_KEY_OWNER[k]
				if owner ~= nil and not fh.allowed[owner] then
					return nil
				end
				return resolveHostGlobalFallback(k)
			end
			local mt = table.freeze({ __metatable = "locked", __index = indexFn })
			filteredHostEnv[mt] = fh :: any
			envMetaMap[env] = mt
			setmetatable(env, mt)
		else
			local lb = libBacking
			local mt = table.freeze({ __metatable = "locked", __index = lb })
			envBackingTable[mt] = lb
			envMetaMap[env] = mt
			setmetatable(env, mt)
		end
	end

	if not inheritHost and (overrides == nil or not hasHostWrapperValue(overrides)) then
		cleanVmEnvs[env] = true
	end
	return env
end

--- Creates a writable per-chunk overlay environment backed read-only by `baseEnv` (or pure stdlib).
local function sandbox(baseEnv: { [any]: any }?, overrides: { [any]: any }?): { [any]: any }
	if baseEnv ~= nil and type(baseEnv) ~= "table" then
		hostError("sandbox baseEnv must be a table", 2)
	end
	if overrides ~= nil and type(overrides) ~= "table" then
		hostError("sandbox overrides must be a table", 2)
	end
	local backing: { [any]: any } = if baseEnv ~= nil then baseEnv else pureGlobals
	local env: { [any]: any } = {}
	env._G = env
	local hasOverrideMath = overrides ~= nil and (overrides :: { [any]: any }).math ~= nil
	local hideBackingMath = false
	if not hasOverrideMath then
		if baseEnv == nil then
			env.math = createIsolatedMath()
		else
			local baseMath = backing.math
			if baseMath == math or isolatedMathTables[baseMath] == true then
				env.math = createIsolatedMath()
				hideBackingMath = true
			end
		end
	end
	if overrides then
		for k, v in overrides do
			env[k] = v
		end
	end
	local idxFn: any = if baseEnv ~= nil
		then function(_self: any, k: any): any
			if k == "_G" or (hideBackingMath and k == "math") then
				return nil
			end
			return backing[k]
		end
		else backing
	local mt = table.freeze({
		__metatable = "locked",
		__index = idxFn,
	})
	envBackingTable[mt] = backing
	envMetaMap[env] = mt
	if baseEnv ~= nil and envResourceLimits[baseEnv] ~= nil then
		envResourceLimits[env] = envResourceLimits[baseEnv]
	end
	if (baseEnv == nil or cleanVmEnvs[baseEnv]) and (overrides == nil or not hasHostWrapperValue(overrides)) then
		cleanVmEnvs[env] = true
	end
	return setmetatable(env, mt) :: any
end

@native
local function lookupEnvChainStatic(env: { [any]: any }, key: string): (any, boolean)
	local cur: any = env
	for _ = 1, 8 do
		if type(cur) ~= "table" then
			return nil, false
		end
		local roInfo = roProxyData[cur]
		if roInfo ~= nil then
			if roInfo.overrideKeys[key] then
				return roInfo.store[key], true
			end
			if roInfo.libBacking ~= nil and roInfo.allowed ~= nil then
				local bv = rawget(roInfo.libBacking, key)
				if bv ~= nil then
					return bv, true
				end
				local owner = STD_KEY_OWNER[key]
				if owner ~= nil and not roInfo.allowed[owner] then
					return nil, true
				end
				return resolveHostGlobalFallback(key), true
			end
			cur = hostBackedGlobals
			continue
		end
		local v = rawget(cur, key)
		if v ~= nil then
			return v, true
		end
		if cur == pureGlobals then
			return nil, true
		elseif cur == hostBackedGlobals then
			if key == "_G" then
				return nil, false
			end
			return resolveHostGlobalFallback(key), true
		end
		local mt = envMetaMap[cur] or getmetatable(cur)
		if mt == nil then
			return nil, true
		elseif mt == PURE_ENV_MT then
			cur = pureGlobals
		elseif mt == HOST_ENV_MT then
			cur = hostBackedGlobals
		elseif type(mt) ~= "table" then
			return nil, false
		else
			local fh = filteredHostEnv[mt]
			if fh ~= nil then
				local bv = rawget(fh.backing, key)
				if bv ~= nil then
					return bv, true
				end
				local owner = STD_KEY_OWNER[key]
				if owner ~= nil and not fh.allowed[owner] then
					return nil, true
				end
				if key == "_G" then
					return nil, false
				end
				return resolveHostGlobalFallback(key), true
			end
			local backing = envBackingTable[mt]
			if backing ~= nil then
				if backing ~= pureGlobals and not table.isfrozen(backing) and roProxyData[backing] == nil then
					return nil, false
				end
				cur = backing
			else
				if not table.isfrozen(mt) or (rawget(mt, "__metatable") == nil and not table.isfrozen(cur)) then
					return nil, false
				end
				local idx = rawget(mt, "__index")
				if idx == nil then
					return nil, true
				elseif type(idx) == "table" then
					if
						idx ~= pureGlobals
						and idx ~= hostBackedGlobals
						and not table.isfrozen(idx)
						and roProxyData[idx] == nil
					then
						return nil, false
					end
					cur = idx
				else
					return nil, false
				end
			end
		end
	end
	return nil, false
end

local function isSafeRootMatch(rootName: string, val: any, expected: any): boolean
	if rootName == "math" and isolatedMathTables[val] == true then
		return true
	end
	if val == expected then
		return if type(expected) == "table" then table.isfrozen(expected) else true
	end
	if rootName == "table" and val == vmTable then
		return true
	elseif rootName == "rawset" and val == vmRawset then
		return true
	elseif rootName == "setmetatable" and val == vmSetmetatable then
		return true
	elseif rootName == "getmetatable" and val == vmGetmetatable then
		return true
	elseif rootName == "rawget" and val == vmRawget then
		return true
	elseif rootName == "next" and val == vmNext then
		return true
	end
	return false
end

local defaultPureSafeRootsMask: number? = nil

@native
local function computeDefaultSafeRootsMask(loadOpts: LoadOptions?): number
	if loadOpts ~= nil then
		if loadOpts.safeEnv == false then
			return 0
		end
		if loadOpts.getGlobal ~= nil and loadOpts.safeEnv ~= true then
			return 0
		end
	end
	local base = defaultPureSafeRootsMask
	if base == nil then
		local m = 0
		for rootName, bit in ROOT_BITS do
			if rootName == "math" then
				m = bor(m, bit)
			else
				local expected = SAFE_ROOT_VALUES[rootName]
				if expected ~= nil and isSafeRootMatch(rootName, pureGlobals[rootName], expected) then
					m = bor(m, bit)
				end
			end
		end
		defaultPureSafeRootsMask = m
		base = m
	end
	local mask = base :: number
	local rl = if loadOpts ~= nil then loadOpts.resourceLimits else nil
	if rl ~= nil and type(rl) == "table" then
		if rl.maxStringLength ~= nil or rl.maxPatternLength ~= nil or rl.maxTableSize ~= nil then
			mask = band(mask, bnot(ROOT_BITS.string))
		end
		if rl.maxTableSize ~= nil or rl.maxStringLength ~= nil then
			mask = band(mask, bnot(ROOT_BITS.table))
		end
		if rl.maxBufferSize ~= nil or rl.maxStringLength ~= nil then
			mask = band(mask, bnot(ROOT_BITS.buffer))
		end
	end
	return mask
end

@native
local function computeSafeRootsMask(env: any, loadOpts: LoadOptions?): number
	if loadOpts ~= nil then
		if loadOpts.safeEnv == false then
			return 0
		end
		if loadOpts.getGlobal ~= nil and loadOpts.safeEnv ~= true then
			return 0
		end
	end
	if type(env) ~= "table" then
		return 0
	end

	local forceDynamicSafe = loadOpts ~= nil and loadOpts.safeEnv == true
	local mask = 0
	for rootName, bit in ROOT_BITS do
		local expected = SAFE_ROOT_VALUES[rootName]
		if expected ~= nil then
			local v, staticOk = lookupEnvChainStatic(env, rootName)
			if staticOk then
				if isSafeRootMatch(rootName, v, expected) then
					mask = bor(mask, bit)
				end
			elseif forceDynamicSafe then
				local rv = rawget(env, rootName)
				if isSafeRootMatch(rootName, rv, expected) then
					mask = bor(mask, bit)
				end
			end
		end
	end

	local hostV3 = HostEnv.getHostEnv().Vector3
	if hostV3 ~= nil then
		local v3, ok3 = lookupEnvChainStatic(env, "Vector3")
		if ok3 then
			if v3 == hostV3 then
				mask = bor(mask, ROOT_BIT_VECTOR3)
			end
		elseif forceDynamicSafe then
			if rawget(env, "Vector3") == hostV3 then
				mask = bor(mask, ROOT_BIT_VECTOR3)
			end
		end
	end

	local rl = if loadOpts ~= nil and loadOpts.resourceLimits ~= nil
		then loadOpts.resourceLimits
		else envResourceLimits[env]
	if rl ~= nil and type(rl) == "table" then
		if rl.maxStringLength ~= nil or rl.maxPatternLength ~= nil or rl.maxTableSize ~= nil then
			mask = band(mask, bnot(ROOT_BITS.string))
		end
		if rl.maxTableSize ~= nil or rl.maxStringLength ~= nil then
			mask = band(mask, bnot(ROOT_BITS.table))
		end
		if rl.maxBufferSize ~= nil or rl.maxStringLength ~= nil then
			mask = band(mask, bnot(ROOT_BITS.buffer))
		end
	end

	return mask
end

local function stepImportChain(
	ctx: ModuleContext,
	kValues: { [number]: any },
	env: { [any]: any },
	count: number,
	id0: number,
	id1: number,
	id2: number
): any
	local rootKey = kValues[id0 + 1]
	if rootKey == "_G" then
		invalidateEnvAll(ctx, env)
	end
	local getGlobalHook = ctx.getGlobal
	local wr = ctx.resourceLimitWrappers
	local r = if getGlobalHook ~= nil then getGlobalHook(rootKey, env) else env[rootKey]
	r = wrapExtractedValue(r, wr)
	if count == 1 then
		return r
	end
	r = r[kValues[id1 + 1]]
	r = wrapExtractedValue(r, wr)
	if count == 2 then
		return r
	end
	r = r[kValues[id2 + 1]]
	return wrapExtractedValue(r, wr)
end

local function resolveImportConstant(proto: Proto, env: { [any]: any }, iid: number, safeRootsMask: number): any
	local count, id0, id1, id2 = BytecodeCodec.decomposeImportId(iid)
	if count < 1 then
		return nil
	end
	local kValues = proto.kValues
	local rootKey = kValues[id0 + 1]
	if type(rootKey) ~= "string" then
		return nil
	end
	local rb = ROOT_BITS[rootKey]
	if rb == nil or not btest(safeRootsMask, rb) then
		return nil
	end
	local r: any
	if rootKey == "math" then
		local envMath, okMath = lookupEnvChainStatic(env, "math")
		r = if okMath and envMath ~= nil then envMath else SAFE_ROOT_VALUES.math
	elseif rootKey == "Vector3" then
		r = HostEnv.getHostEnv().Vector3
	else
		r = SAFE_ROOT_VALUES[rootKey]
	end
	if count == 1 then
		return r
	end
	if type(r) ~= "table" or not table.isfrozen(r) or getmetatable(r :: any) ~= nil then
		return nil
	end
	r = r[kValues[id1 + 1]]
	if count == 2 then
		return r
	end
	if type(r) ~= "table" or not table.isfrozen(r) or getmetatable(r :: any) ~= nil then
		return nil
	end
	return r[kValues[id2 + 1]]
end

local function resolveGetImportSlow(frame: FrameState, ctx: ModuleContext, pdata: PredecodedProto, pc: number): any
	local count, id0, id1, id2 = BytecodeCodec.decomposeImportId(pdata.auxVal[pc])
	return stepImportChain(ctx, pdata.kValues, frame.meta.env, count, id0, id1, id2)
end

local function formatChunkSrc(name: string): string
	local prefix = string.sub(name, 1, 1)
	if prefix == "=" then
		return string.sub(name, 2, 256)
	elseif prefix == "@" then
		if #name - 1 <= 255 then
			return string.sub(name, 2)
		end
		return "..." .. string.sub(name, #name - 251)
	end
	local nl = string.find(name, "[\r\n]")
	local maxInline = 241
	local preview: string
	if nl then
		local take = if nl - 1 <= maxInline then nl - 1 else maxInline
		preview = string.sub(name, 1, take) .. "..."
	elseif #name > maxInline then
		preview = string.sub(name, 1, maxInline) .. "..."
	else
		preview = name
	end
	return string.format('[string "%s"]', preview)
end

local WEAK_KEY_META = table.freeze({ __mode = "k" })

local function getActiveCalls(ctx: ModuleContext): number
	local activeThreads = ctx.activeThreads
	if activeThreads == nil then
		return 0
	end
	local total = 0
	for co, count in activeThreads do
		if coroutine.status(co) == "dead" then
			activeThreads[co] = nil
		else
			total += count
		end
	end
	return total
end

local function addActiveCall(ctx: ModuleContext, co: thread, delta: number)
	local activeThreads = ctx.activeThreads
	if delta > 0 then
		if activeThreads == nil then
			activeThreads = setmetatable({}, WEAK_KEY_META :: any) :: any
			ctx.activeThreads = activeThreads
		end
		local tbl = activeThreads :: { [thread]: number }
		tbl[co] = (tbl[co] or 0) + delta
	elseif activeThreads ~= nil then
		local nextCount = (activeThreads[co] or 0) + delta
		if nextCount > 0 then
			activeThreads[co] = nextCount
		else
			activeThreads[co] = nil
		end
	end
end

local function checkFiniteNonNegNumber(val: any, name: string, errLevel: number)
	if val ~= nil and (type(val) ~= "number" or val ~= val or val < 0 or val == math.huge) then
		hostError("invalid " .. name .. ": expected non-negative finite number", errLevel)
	end
end

local function checkOptionalFunction(val: any, name: string, errLevel: number)
	if val ~= nil and type(val) ~= "function" then
		hostError("invalid " .. name .. ": expected function", errLevel)
	end
end

local function validateLoadOptions(raw: unknown, errLevel: number)
	if raw == nil then
		return
	end
	if type(raw) ~= "table" then
		hostError("invalid load options: expected table", errLevel)
	end
	for k in raw :: { [any]: any } do
		if not VALID_LOAD_OPTION_KEYS[k] then
			hostError("unknown load option: " .. tostring(k), errLevel)
		end
	end
	local loadOpts = raw :: LoadOptions
	if loadOpts.name ~= nil and type(loadOpts.name) ~= "string" then
		hostError("invalid chunk name: expected string", errLevel)
	end
	if loadOpts.env ~= nil and type(loadOpts.env) ~= "table" then
		hostError("invalid env table", errLevel)
	end
	if loadOpts.compile ~= nil and type(loadOpts.compile) ~= "table" then
		hostError("invalid compile options: expected table", errLevel)
	end
	if loadOpts.decoder ~= nil then
		local dt = type(loadOpts.decoder)
		if dt ~= "function" and (dt ~= "table" or type((loadOpts.decoder :: any).decode) ~= "function") then
			hostError("invalid decoder: expected function or table with decode method", errLevel)
		end
	end
	if loadOpts.mode ~= nil and loadOpts.mode ~= "text" and loadOpts.mode ~= "binary" and loadOpts.mode ~= "auto" then
		hostError("invalid load mode: " .. tostring(loadOpts.mode), errLevel)
	end
	checkFiniteNonNegNumber(loadOpts.instructionLimit, "instructionLimit", errLevel)
	checkFiniteNonNegNumber(loadOpts.callLimit, "callLimit", errLevel)
	checkFiniteNonNegNumber(loadOpts.timeout, "timeout", errLevel)
	if loadOpts.interruptInterval ~= nil then
		local ii = loadOpts.interruptInterval
		if type(ii) ~= "number" or ii ~= ii or ii < 1 or ii == math.huge or math.floor(ii) ~= ii then
			hostError("invalid interruptInterval: expected positive finite integer", errLevel)
		end
	end
	if loadOpts.safeEnv ~= nil and type(loadOpts.safeEnv) ~= "boolean" then
		hostError("invalid safeEnv: expected boolean", errLevel)
	end
	checkOptionalFunction(loadOpts.interrupt, "interrupt", errLevel)
	checkOptionalFunction(loadOpts.getGlobal, "getGlobal", errLevel)
	checkOptionalFunction(loadOpts.setGlobal, "setGlobal", errLevel)
	checkOptionalFunction(loadOpts.onCall, "onCall", errLevel)
	checkOptionalFunction(loadOpts.onReturn, "onReturn", errLevel)
	checkOptionalFunction(loadOpts.onLine, "onLine", errLevel)
	checkOptionalFunction(loadOpts.onBreak, "onBreak", errLevel)
	if loadOpts.resourceLimits ~= nil then
		validateResourceLimits(loadOpts.resourceLimits, errLevel)
	end
end

local function createModuleContext(
	protos: { Proto },
	mainProto: Proto,
	templates: { [number]: ProtoTemplate },
	shortSrc: string,
	env: { [any]: any },
	safeRootsMask: number,
	needsHostWrappers: boolean,
	loadOpts: LoadOptions?
): ModuleContext
	local insnLimit: number? = nil
	local callLimit: number? = nil
	local timeout: number? = nil
	local interrupt: (() -> boolean?)? = nil
	local interruptInterval = 4096
	local getGlobal: ((name: string, env: { [any]: any }) -> any)? = nil
	local setGlobal: ((name: string, value: any, env: { [any]: any }) -> ())? = nil
	local onCall: ((info: DebugFrameInfo) -> ())? = nil
	local onReturn: ((info: DebugFrameInfo) -> ())? = nil
	local onLine: ((line: number, info: DebugFrameInfo) -> ())? = nil
	local onBreak: ((line: number, info: DebugFrameInfo) -> ())? = nil
	local safeEnvOpt: boolean? = nil
	local loadResourceLimits: ResourceLimits? = nil

	if loadOpts ~= nil then
		validateLoadOptions(loadOpts, 0)
		if loadOpts.interruptInterval ~= nil then
			interruptInterval = loadOpts.interruptInterval :: number
		end
		if loadOpts.resourceLimits ~= nil then
			loadResourceLimits = validateResourceLimits(loadOpts.resourceLimits, 0)
		end

		insnLimit = loadOpts.instructionLimit
		callLimit = loadOpts.callLimit
		timeout = loadOpts.timeout
		interrupt = loadOpts.interrupt
		getGlobal = loadOpts.getGlobal
		setGlobal = loadOpts.setGlobal
		onCall = loadOpts.onCall
		onReturn = loadOpts.onReturn
		onLine = loadOpts.onLine
		onBreak = loadOpts.onBreak
		safeEnvOpt = loadOpts.safeEnv
	end

	local effectiveResourceLimits: ResourceLimits? = loadResourceLimits or envResourceLimits[env]
	local resourceLimitWrappers: { [unknown]: unknown }? = nil
	if effectiveResourceLimits ~= nil then
		resourceLimitWrappers = buildResourceLimitArtifacts(effectiveResourceLimits)
	end

	local hasLimits = insnLimit ~= nil or interrupt ~= nil or timeout ~= nil or callLimit ~= nil
	local hasLineHook = onLine ~= nil
	local hasDebugHooks = onCall ~= nil or onReturn ~= nil or hasLineHook or onBreak ~= nil
	local hasResourceLimits = effectiveResourceLimits ~= nil
	local isGuarded = hasLimits or hasDebugHooks or hasResourceLimits

	local ctx: ModuleContext = {
		protos = protos,
		mainProto = mainProto,
		templates = templates,
		predecoded = {},
		coverage = nil,
		env = env,
		envGroup = nil,
		safeenv = safeRootsMask ~= 0,
		safeRootsMask = safeRootsMask,
		needsHostWrappers = needsHostWrappers,
		dupClosureCache = nil,
		shortSrc = shortSrc,
		isGuarded = isGuarded,
		hasLimits = hasLimits,
		insnCount = 0,
		insnLimit = insnLimit,
		callLimit = callLimit,
		effectiveCallLimit = callLimit or 20000,
		activeThreads = nil,
		timeout = timeout,
		startClock = nil,
		interrupt = interrupt,
		interruptInterval = interruptInterval,
		nextInterrupt = interruptInterval,
		interrupted = false,
		safeEnvOpt = safeEnvOpt,
		getGlobal = getGlobal,
		setGlobal = setGlobal,
		hasDebugHooks = hasDebugHooks,
		hasLineHook = hasLineHook,
		onCall = onCall,
		onReturn = onReturn,
		onLine = onLine,
		onBreak = onBreak,
		resourceLimits = effectiveResourceLimits,
		hasResourceLimits = hasResourceLimits,
		maxStringLength = if effectiveResourceLimits then effectiveResourceLimits.maxStringLength else nil,
		maxTableSize = if effectiveResourceLimits then effectiveResourceLimits.maxTableSize else nil,
		maxBufferSize = if effectiveResourceLimits then effectiveResourceLimits.maxBufferSize else nil,
		maxPatternLength = if effectiveResourceLimits then effectiveResourceLimits.maxPatternLength else nil,
		resourceLimitWrappers = resourceLimitWrappers,
	}

	if not table.isfrozen(env) and roProxyData[env] == nil then
		local group = envContexts[env]
		if group == nil then
			group = setmetatable({}, { __mode = "k" }) :: any
			envContexts[env] = group
		end
		(group :: { [ModuleContext]: boolean })[ctx] = true
		ctx.envGroup = group
	end

	return ctx
end

--- Resets the instruction count and timeout clock for the ModuleContext owning `fn`.
local function vmResetBudget(fn: any): boolean
	if type(fn) ~= "function" then
		return false
	end
	local meta = closureMeta[fn]
	if not meta then
		return false
	end
	local ctx = meta.ctx
	ctx.insnCount = 0
	ctx.startClock = nil
	ctx.nextInterrupt = ctx.interruptInterval
	ctx.interrupted = false
	return true
end

local function buildDebugFrameInfo(frame: FrameState, depth: number, pc: number): DebugFrameInfo
	local meta = frame.meta
	local proto = meta.proto
	local dname = proto.debugname
	return {
		source = meta.ctx.shortSrc,
		line = getLineForPc(proto, pc),
		name = if dname and #dname > 0 and dname ~= "(main)" then dname else nil,
		numparams = proto.numparams,
		isvararg = proto.isvararg,
		depth = depth,
	}
end

local OP_LENGTHS = BytecodeDefs.opLengths
local LOP_COVERAGE_CODE = BytecodeDefs.Opcodes.LOP_COVERAGE

--- Returns line-by-line coverage counts for all instrumented protos in `fn`'s module.
local function vmGetCoverage(fn: any): { CoverageEntry }?
	if type(fn) ~= "function" then
		return nil
	end
	local meta = closureMeta[fn]
	if not meta then
		return nil
	end
	local ctx = meta.ctx
	local covMap = ctx.coverage
	local entries: { CoverageEntry } = {}
	for _, proto in ctx.protos do
		local code = proto.code
		local clen = #code
		local protoCov = if covMap then covMap[proto.id + 1] else nil
		local hits: { [number]: number }? = nil
		local totalHits = 0
		local pc = 1
		while pc <= clen do
			local op = band(code[pc], 0xff)
			if op == LOP_COVERAGE_CODE then
				local map: { [number]: number } = if hits ~= nil then hits else {}
				if hits == nil then
					hits = map
				end
				local line = getLineForPc(proto, pc)
				local count = if protoCov then (protoCov[pc] or 0) else 0
				map[line] = (map[line] or 0) + count
				totalHits += count
			end
			pc += OP_LENGTHS[op] or 1
		end
		if hits ~= nil then
			entries[#entries + 1] = {
				name = proto.debugname,
				lineDefined = proto.linedefined or 0,
				hits = hits,
				totalHits = totalHits,
			}
		end
	end
	return entries
end

--- Returns index, optional debug name, and current value for each upvalue captured by `fn`.
local function vmGetUpvalues(fn: any): { UpvalueInfo }?
	if type(fn) ~= "function" then
		return nil
	end
	local meta = closureMeta[fn]
	if not meta then
		return nil
	end
	local upvals = meta.upvals
	local names = meta.proto.upvalues
	local count = #upvals
	local out: { UpvalueInfo } = table.create(count) :: { UpvalueInfo }
	for i = 1, count do
		local uv = upvals[i]
		out[i] = {
			index = i,
			name = if names then names[i] else nil,
			value = (uv[1] :: { any })[uv[2] :: number],
		}
	end
	return out
end

--- Mutates an open or closed upvalue slot (`1`-based) on a VM closure.
local function vmSetUpvalue(fn: any, index: number, value: any): boolean
	if type(fn) ~= "function" or type(index) ~= "number" or index ~= math.floor(index) or index < 1 then
		return false
	end
	local meta = closureMeta[fn]
	if not meta then
		return false
	end
	local uv = meta.upvals[index]
	if not uv then
		return false
	end
	uv[1][uv[2]] = value
	uv[4] = nil
	meta.ctx.dupClosureCache = nil
	return true
end

local function registerXpcall(vmXpcallFn: (fn: any, errHandler: any, ...any) -> (boolean, ...any))
	registeredXpcall = vmXpcallFn
	SAFE_ROOT_VALUES.xpcall = vmXpcallFn
	if not table.isfrozen(STD_BASE) then
		STD_BASE.xpcall = vmXpcallFn
		table.freeze(STD_BASE)
	end
	if not table.isfrozen(STD_LIBRARIES) then
		table.freeze(STD_LIBRARIES)
	end
	if not table.isfrozen(pureGlobals) then
		pureGlobals.xpcall = vmXpcallFn
		table.freeze(pureGlobals)
	end
	if not table.isfrozen(hostBackedGlobals :: any) then
		hostBackedGlobals.xpcall = vmXpcallFn
		table.freeze(hostBackedGlobals)
	end
	if hostXpcall ~= nil then
		HOST_WRAPPERS[hostXpcall] = vmXpcallFn
		HOST_FUNC_NAMES[vmXpcallFn] = "xpcall"
	end
end

local function registerUnwindFrames(unwindFn: (tstate: ThreadState, targetDepth: number, co: thread?) -> ())
	registeredUnwindFrames = unwindFn
end

local VOP = table.freeze({
	-- Tier 0 (0..15): hottest inner-loop ops
	MOVE = 0,
	LOADN = 1,
	LOADK = 2,
	ADDK = 3,
	SUBK = 4,
	MULK = 5,
	MODK = 6,
	FORNLOOP = 7,
	GETTABLEKS = 8,
	SETTABLEKS = 9,
	CALL = 10,
	NAMECALL_CALL = 11,
	GETTABLEKS_CALL = 12,
	GETIMPORT_CALL = 13,
	RETURN = 14,
	ADD = 15,
	-- Tier 1 (16..31)
	SUB = 16,
	MUL = 17,
	MOD = 18,
	JUMPIFNOT = 19,
	JUMPIF = 20,
	JUMP = 21,
	JUMPBACK = 22,
	JUMPIFLT = 23,
	JUMPIFLE = 24,
	JUMPIFEQ = 25,
	JUMPIFNOTEQ = 26,
	JUMPIFNOTLE = 27,
	JUMPIFNOTLT = 28,
	GETIMPORT = 29,
	GETTABLE = 30,
	SETTABLE = 31,
	-- Tier 2 (32..47)
	GETTABLEN = 32,
	SETTABLEN = 33,
	GETUPVAL = 34,
	SETUPVAL = 35,
	GETGLOBAL = 36,
	SETGLOBAL = 37,
	NAMECALL = 38,
	FASTCALL1 = 39,
	FASTCALL2 = 40,
	FASTCALL2K = 41,
	FASTCALL3 = 42,
	FASTCALL = 43,
	NEWCLOSURE = 44,
	DUPCLOSURE = 45,
	CLOSEUPVALS = 46,
	FORGLOOP = 47,
	-- Tier 3 (48..63)
	DUPTABLE = 48,
	NEWTABLE = 49,
	SETLIST = 50,
	FORNPREP = 51,
	FORGPREP = 52,
	FASTPCALL = 53,
	LOADNIL = 54,
	LOADB = 55,
	DIV = 56,
	POW = 57,
	IDIV = 58,
	DIVK = 59,
	POWK = 60,
	IDIVK = 61,
	AND = 62,
	OR = 63,
	-- Tier 4 (64..74)
	ANDK = 64,
	ORK = 65,
	NOT = 66,
	MINUS = 67,
	LENGTH = 68,
	CONCAT = 69,
	PREPVARARGS = 70,
	JUMPXEQKNIL = 71,
	JUMPXEQKB = 72,
	JUMPXEQKN = 73,
	JUMPXEQKS = 74,
	-- Tier 5 (75+): cold ops
	FORGPREP_INEXT = 75,
	FORGPREP_NEXT = 76,
	GETVARARGS = 77,
	LOADKX = 78,
	JUMPX = 79,
	SUBRK = 80,
	DIVRK = 81,
	GETUDATAKS = 82,
	SETUDATAKS = 83,
	NAMECALLUDATA = 84,
	CMPPROTO = 85,
	COVERAGE = 86,
	BREAK = 87,
	CAPTURE = 88,
	NOP = 89,
	NATIVECALL = 90,
	CALLFB = 10,
	NEWCLASSMEMBER = 92,
	NEWCLASS = 93,
	CONSTRUCT = 94,
	FINCONSTRUCT = 95,
	GETPRIVATEFIELD = 96,
	SETPRIVATEFIELD = 97,
})

local RAW_TO_VOP: { number } = table.create(128, 89)
do
	local Opcodes = (BytecodeDefs.Opcodes :: unknown) :: { [string]: number }
	for name, opId in Opcodes do
		local bare = string.sub(name, 5)
		local v = (VOP :: { [string]: number })[bare]
		if v ~= nil then
			RAW_TO_VOP[opId + 1] = v
		end
	end
	table.freeze(RAW_TO_VOP)
end

return table.freeze({
	VOP = VOP,
	RAW_TO_VOP = RAW_TO_VOP,
	closureMeta = closureMeta,
	threadStates = threadStates,
	ROOT_BITS = ROOT_BITS,
	ROOT_BIT_IPAIRS = ROOT_BIT_IPAIRS,
	ROOT_BIT_PCALL = ROOT_BIT_PCALL,
	ROOT_BIT_XPCALL = ROOT_BIT_XPCALL,
	SAFE_INVALIDATION_KEYS = SAFE_INVALIDATION_KEYS,
	ALL_SAFE_ROOTS = ALL_SAFE_ROOTS,
	BUILTIN_ROOT_BIT = BUILTIN_ROOT_BIT,
	HOST_WRAPPERS = HOST_WRAPPERS,
	HOST_FUNC_NAMES = HOST_FUNC_NAMES,
	resolveHostFuncName = resolveHostFuncName,
	findNearestLuaFrame = findNearestLuaFrame,
	hostError = hostError,
	hostPcall = hostPcall,
	hostXpcall = hostXpcall,
	hostDebug = hostDebug,
	hostCoroutine = hostCoroutine,
	hostTable = table,
	hostGetmetatable = hostGetmetatable,
	hostRawget = hostRawget,
	hostNext = hostNext,
	defaultGlobals = pureGlobals,
	getThreadState = getThreadState,
	getActiveThreadState = getActiveThreadState,
	getActiveCalls = getActiveCalls,
	addActiveCall = addActiveCall,
	getLineForPc = getLineForPc,
	resolveShadowedInstanceMethod = resolveShadowedInstanceMethod,
	createEnvironment = createEnvironment,
	sandbox = sandbox,
	isReadOnlyProxy = isReadOnlyProxy,
	isTrackedEnv = isTrackedEnv,
	getInternalMetatable = getInternalMetatable,
	recordLockedMetatable = recordLockedMetatable,
	computeDefaultSafeRootsMask = computeDefaultSafeRootsMask,
	computeSafeRootsMask = computeSafeRootsMask,
	envNeedsHostWrappers = envNeedsHostWrappers,
	wrapExtractedValue = wrapExtractedValue,
	invalidateEnvRoot = invalidateEnvRoot,
	invalidateEnvAll = invalidateEnvAll,
	resolveImportConstant = resolveImportConstant,
	resolveGetImportSlow = resolveGetImportSlow,
	formatChunkSrc = formatChunkSrc,
	validateLoadOptions = validateLoadOptions,
	createModuleContext = createModuleContext,
	buildDebugFrameInfo = buildDebugFrameInfo,
	recordDeadSnapshot = recordDeadSnapshot,
	vmGetCoverage = vmGetCoverage,
	vmGetUpvalues = vmGetUpvalues,
	vmSetUpvalue = vmSetUpvalue,
	vmResetBudget = vmResetBudget,
	vmError = vmError,
	formatVmError = formatVmError,
	clearErrorState = clearErrorState,
	vmGetfenv = guestGetfenv,
	vmSetfenv = guestSetfenv,
	vmGetmetatable = vmGetmetatable,
	vmRawget = vmRawget,
	vmNext = vmNext,
	vmTracebackRaw = guestDebugTraceback,
	vmTraceback = vmTraceback,
	vmDebugInfo = guestDebugInfo,
	vmDebug = vmDebug,
	registerVmChunkPrefix = registerVmChunkPrefix,
	registerXpcall = registerXpcall,
	registerUnwindFrames = registerUnwindFrames,
})
