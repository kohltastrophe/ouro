--!strict
-- Unified @native register-VM dispatch, frame pooling, and invocation lifecycle.
-- Upstream Luau is MIT licensed. See ../../LICENSE.md and ../../UPSTREAM.json.
local BytecodeDefs = require("../BytecodeDefs")
local Fastcalls = require("./Fastcalls")
local RuntimeEnv = require("./RuntimeEnv")
local Types = require("../Types")
local Verifier = require("./Verifier")

type Proto = Types.Proto
type DebugFrameInfo = Types.DebugFrameInfo
type LoadOptions = Types.LoadOptions
type Upval = RuntimeEnv.Upval
type ProtoTemplate = RuntimeEnv.ProtoTemplate
type PredecodedProto = RuntimeEnv.PredecodedProto
type SnapshotFrame = RuntimeEnv.SnapshotFrame
type ModuleContext = RuntimeEnv.ModuleContext
type ClosureMeta = RuntimeEnv.ClosureMeta
type FrameState = RuntimeEnv.FrameState
type ThreadState = RuntimeEnv.ThreadState

-- Compile-time literals allow Luau -O2 constant propagation inside `runLoop`; verified below against `RuntimeEnv.VOP`.
local VOP_MOVE = 0
local VOP_LOADN = 1
local VOP_LOADK = 2
local VOP_ADDK = 3
local VOP_SUBK = 4
local VOP_MULK = 5
local VOP_MODK = 6
local VOP_FORNLOOP = 7
local VOP_GETTABLEKS = 8
local VOP_SETTABLEKS = 9
local VOP_CALL = 10
local VOP_NAMECALL_CALL = 11
local VOP_GETTABLEKS_CALL = 12
local VOP_GETIMPORT_CALL = 13
local VOP_RETURN = 14
local VOP_ADD = 15
local VOP_SUB = 16
local VOP_MUL = 17
local VOP_MOD = 18
local VOP_JUMPIFNOT = 19
local VOP_JUMPIF = 20
local VOP_JUMP = 21
local VOP_JUMPBACK = 22
local VOP_JUMPIFLT = 23
local VOP_JUMPIFLE = 24
local VOP_JUMPIFEQ = 25
local VOP_JUMPIFNOTEQ = 26
local VOP_JUMPIFNOTLE = 27
local VOP_GETIMPORT = 29
local VOP_GETTABLE = 30
local VOP_SETTABLE = 31
local VOP_GETTABLEN = 32
local VOP_SETTABLEN = 33
local VOP_GETUPVAL = 34
local VOP_SETUPVAL = 35
local VOP_GETGLOBAL = 36
local VOP_SETGLOBAL = 37
local VOP_NAMECALL = 38
local VOP_FASTCALL1 = 39
local VOP_FASTCALL2 = 40
local VOP_FASTCALL2K = 41
local VOP_FASTCALL3 = 42
local VOP_FASTCALL = 43
local VOP_NEWCLOSURE = 44
local VOP_DUPCLOSURE = 45
local VOP_CLOSEUPVALS = 46
local VOP_FORGLOOP = 47
local VOP_DUPTABLE = 48
local VOP_NEWTABLE = 49
local VOP_SETLIST = 50
local VOP_FORNPREP = 51
local VOP_FORGPREP = 52
local VOP_FASTPCALL = 53
local VOP_LOADNIL = 54
local VOP_LOADB = 55
local VOP_DIV = 56
local VOP_POW = 57
local VOP_IDIV = 58
local VOP_DIVK = 59
local VOP_POWK = 60
local VOP_IDIVK = 61
local VOP_AND = 62
local VOP_OR = 63
local VOP_ANDK = 64
local VOP_NOT = 66
local VOP_MINUS = 67
local VOP_LENGTH = 68
local VOP_CONCAT = 69
local VOP_PREPVARARGS = 70
local VOP_JUMPXEQKNIL = 71
local VOP_JUMPXEQKB = 72
local VOP_JUMPXEQKN = 73
local VOP_JUMPXEQKS = 74
local VOP_FORGPREP_INEXT = 75
local VOP_FORGPREP_NEXT = 76
local VOP_GETVARARGS = 77
local VOP_LOADKX = 78
local VOP_JUMPX = 79
local VOP_SUBRK = 80
local VOP_DIVRK = 81
local VOP_GETUDATAKS = 82
local VOP_SETUDATAKS = 83
local VOP_NAMECALLUDATA = 84
local VOP_CMPPROTO = 85
local VOP_COVERAGE = 86
local VOP_BREAK = 87
local VOP_CAPTURE = 88
local VOP_NOP = 89

local LBF_MATH_ABS = 2
local LBF_MATH_CEIL = 7
local LBF_MATH_COS = 9
local LBF_MATH_FLOOR = 12
local LBF_MATH_MAX = 18
local LBF_MATH_MIN = 19
local LBF_MATH_SIN = 24
local LBF_MATH_SQRT = 25
local LBF_BIT32_BAND = 29
local LBF_BIT32_BNOT = 30
local LBF_BIT32_BOR = 31
local LBF_BIT32_BXOR = 32
local LBF_BIT32_BTEST = 33
local LBF_BIT32_LSHIFT = 36
local LBF_BIT32_RSHIFT = 39
local LBF_TYPE = 40
local LBF_STRING_BYTE = 41
local LBF_STRING_LEN = 43
local LBF_TYPEOF = 44
local LBF_STRING_SUB = 45
local LBF_MATH_CLAMP = 46
local LBF_MATH_SIGN = 47
local LBF_MATH_ROUND = 48
local LBF_RAWEQUAL = 51
local LBF_TABLE_INSERT = 52
local LBF_SELECT_VARARG = 57
local LBF_GETMETATABLE = 60
local LBF_SETMETATABLE = 61
local LBF_TONUMBER = 62
local LBF_TOSTRING = 63
local LBF_TABLE_CREATE = 133

local LCT_VAL = 0
local LCT_REF = 1

do
	local VOP = RuntimeEnv.VOP
	local Builtins = BytecodeDefs.Builtins
	local Captures = BytecodeDefs.Captures
	assert(
		VOP.MOVE == VOP_MOVE
			and VOP.LOADN == VOP_LOADN
			and VOP.LOADK == VOP_LOADK
			and VOP.ADDK == VOP_ADDK
			and VOP.SUBK == VOP_SUBK
			and VOP.MULK == VOP_MULK
			and VOP.MODK == VOP_MODK
			and VOP.FORNLOOP == VOP_FORNLOOP
			and VOP.GETTABLEKS == VOP_GETTABLEKS
			and VOP.SETTABLEKS == VOP_SETTABLEKS
			and VOP.CALL == VOP_CALL
			and VOP.NAMECALL_CALL == VOP_NAMECALL_CALL
			and VOP.GETTABLEKS_CALL == VOP_GETTABLEKS_CALL
			and VOP.GETIMPORT_CALL == VOP_GETIMPORT_CALL
			and VOP.RETURN == VOP_RETURN
			and VOP.ADD == VOP_ADD
			and VOP.SUB == VOP_SUB
			and VOP.MUL == VOP_MUL
			and VOP.MOD == VOP_MOD
			and VOP.JUMPIFNOT == VOP_JUMPIFNOT
			and VOP.JUMPIF == VOP_JUMPIF
			and VOP.JUMP == VOP_JUMP
			and VOP.JUMPBACK == VOP_JUMPBACK
			and VOP.JUMPIFLT == VOP_JUMPIFLT
			and VOP.JUMPIFLE == VOP_JUMPIFLE
			and VOP.JUMPIFEQ == VOP_JUMPIFEQ
			and VOP.JUMPIFNOTEQ == VOP_JUMPIFNOTEQ
			and VOP.JUMPIFNOTLE == VOP_JUMPIFNOTLE
			and VOP.GETIMPORT == VOP_GETIMPORT
			and VOP.GETTABLE == VOP_GETTABLE
			and VOP.SETTABLE == VOP_SETTABLE
			and VOP.GETTABLEN == VOP_GETTABLEN
			and VOP.SETTABLEN == VOP_SETTABLEN
			and VOP.GETUPVAL == VOP_GETUPVAL
			and VOP.SETUPVAL == VOP_SETUPVAL
			and VOP.GETGLOBAL == VOP_GETGLOBAL
			and VOP.SETGLOBAL == VOP_SETGLOBAL
			and VOP.NAMECALL == VOP_NAMECALL
			and VOP.FASTCALL1 == VOP_FASTCALL1
			and VOP.FASTCALL2 == VOP_FASTCALL2
			and VOP.FASTCALL2K == VOP_FASTCALL2K
			and VOP.FASTCALL3 == VOP_FASTCALL3
			and VOP.FASTCALL == VOP_FASTCALL
			and VOP.NEWCLOSURE == VOP_NEWCLOSURE
			and VOP.DUPCLOSURE == VOP_DUPCLOSURE
			and VOP.CLOSEUPVALS == VOP_CLOSEUPVALS
			and VOP.FORGLOOP == VOP_FORGLOOP
			and VOP.DUPTABLE == VOP_DUPTABLE
			and VOP.NEWTABLE == VOP_NEWTABLE
			and VOP.SETLIST == VOP_SETLIST
			and VOP.FORNPREP == VOP_FORNPREP
			and VOP.FORGPREP == VOP_FORGPREP
			and VOP.FASTPCALL == VOP_FASTPCALL
			and VOP.LOADNIL == VOP_LOADNIL
			and VOP.LOADB == VOP_LOADB
			and VOP.DIV == VOP_DIV
			and VOP.POW == VOP_POW
			and VOP.IDIV == VOP_IDIV
			and VOP.DIVK == VOP_DIVK
			and VOP.POWK == VOP_POWK
			and VOP.IDIVK == VOP_IDIVK
			and VOP.AND == VOP_AND
			and VOP.OR == VOP_OR
			and VOP.ANDK == VOP_ANDK
			and VOP.NOT == VOP_NOT
			and VOP.MINUS == VOP_MINUS
			and VOP.LENGTH == VOP_LENGTH
			and VOP.CONCAT == VOP_CONCAT
			and VOP.PREPVARARGS == VOP_PREPVARARGS
			and VOP.JUMPXEQKNIL == VOP_JUMPXEQKNIL
			and VOP.JUMPXEQKB == VOP_JUMPXEQKB
			and VOP.JUMPXEQKN == VOP_JUMPXEQKN
			and VOP.JUMPXEQKS == VOP_JUMPXEQKS
			and VOP.FORGPREP_INEXT == VOP_FORGPREP_INEXT
			and VOP.FORGPREP_NEXT == VOP_FORGPREP_NEXT
			and VOP.GETVARARGS == VOP_GETVARARGS
			and VOP.LOADKX == VOP_LOADKX
			and VOP.JUMPX == VOP_JUMPX
			and VOP.SUBRK == VOP_SUBRK
			and VOP.DIVRK == VOP_DIVRK
			and VOP.GETUDATAKS == VOP_GETUDATAKS
			and VOP.SETUDATAKS == VOP_SETUDATAKS
			and VOP.NAMECALLUDATA == VOP_NAMECALLUDATA
			and VOP.CMPPROTO == VOP_CMPPROTO
			and VOP.COVERAGE == VOP_COVERAGE
			and VOP.BREAK == VOP_BREAK
			and VOP.CAPTURE == VOP_CAPTURE
			and VOP.NOP == VOP_NOP,
		"Dispatch VOP literal mismatch"
	)
	assert(
		Builtins.LBF_MATH_ABS == LBF_MATH_ABS
			and Builtins.LBF_MATH_CEIL == LBF_MATH_CEIL
			and Builtins.LBF_MATH_COS == LBF_MATH_COS
			and Builtins.LBF_MATH_FLOOR == LBF_MATH_FLOOR
			and Builtins.LBF_MATH_MAX == LBF_MATH_MAX
			and Builtins.LBF_MATH_MIN == LBF_MATH_MIN
			and Builtins.LBF_MATH_SIN == LBF_MATH_SIN
			and Builtins.LBF_MATH_SQRT == LBF_MATH_SQRT
			and Builtins.LBF_BIT32_BAND == LBF_BIT32_BAND
			and Builtins.LBF_BIT32_BNOT == LBF_BIT32_BNOT
			and Builtins.LBF_BIT32_BOR == LBF_BIT32_BOR
			and Builtins.LBF_BIT32_BXOR == LBF_BIT32_BXOR
			and Builtins.LBF_BIT32_BTEST == LBF_BIT32_BTEST
			and Builtins.LBF_BIT32_LSHIFT == LBF_BIT32_LSHIFT
			and Builtins.LBF_BIT32_RSHIFT == LBF_BIT32_RSHIFT
			and Builtins.LBF_TYPE == LBF_TYPE
			and Builtins.LBF_STRING_BYTE == LBF_STRING_BYTE
			and Builtins.LBF_STRING_LEN == LBF_STRING_LEN
			and Builtins.LBF_TYPEOF == LBF_TYPEOF
			and Builtins.LBF_STRING_SUB == LBF_STRING_SUB
			and Builtins.LBF_MATH_CLAMP == LBF_MATH_CLAMP
			and Builtins.LBF_MATH_SIGN == LBF_MATH_SIGN
			and Builtins.LBF_MATH_ROUND == LBF_MATH_ROUND
			and Builtins.LBF_RAWEQUAL == LBF_RAWEQUAL
			and Builtins.LBF_TABLE_INSERT == LBF_TABLE_INSERT
			and Builtins.LBF_SELECT_VARARG == LBF_SELECT_VARARG
			and Builtins.LBF_GETMETATABLE == LBF_GETMETATABLE
			and Builtins.LBF_SETMETATABLE == LBF_SETMETATABLE
			and Builtins.LBF_TONUMBER == LBF_TONUMBER
			and Builtins.LBF_TOSTRING == LBF_TOSTRING
			and Builtins.LBF_TABLE_CREATE == LBF_TABLE_CREATE,
		"Dispatch builtin literal mismatch"
	)
	assert(Captures.LCT_VAL == LCT_VAL and Captures.LCT_REF == LCT_REF, "Dispatch capture literal mismatch")
end

local typeofFn: (any) -> string = (typeof or type) :: any
local closureMeta = RuntimeEnv.closureMeta
local findNearestLuaFrame = RuntimeEnv.findNearestLuaFrame
local getInternalMetatable = RuntimeEnv.getInternalMetatable
local HOST_WRAPPERS = RuntimeEnv.HOST_WRAPPERS
local ROOT_BIT_IPAIRS = RuntimeEnv.ROOT_BIT_IPAIRS
local ROOT_BIT_PCALL = RuntimeEnv.ROOT_BIT_PCALL
local SAFE_INVALIDATION_KEYS = RuntimeEnv.SAFE_INVALIDATION_KEYS
local hostError = RuntimeEnv.hostError
local vmError = RuntimeEnv.vmError
local hostPcall = RuntimeEnv.hostPcall
local hostXpcall = RuntimeEnv.hostXpcall
local hostInext = Fastcalls.hostInext
local inext = Fastcalls.inext
local execFastcallOp = Fastcalls.execFastcallOp
local getThreadState = RuntimeEnv.getThreadState
local getActiveThreadState = RuntimeEnv.getActiveThreadState
local getActiveCalls = RuntimeEnv.getActiveCalls
local addActiveCall = RuntimeEnv.addActiveCall
local validateLoadOptions = RuntimeEnv.validateLoadOptions
local formatChunkSrc = RuntimeEnv.formatChunkSrc
local hostNext = RuntimeEnv.hostNext
local vmNext = RuntimeEnv.vmNext
local getLineForPc = RuntimeEnv.getLineForPc
local invalidateEnvRoot = RuntimeEnv.invalidateEnvRoot
local invalidateEnvAll = RuntimeEnv.invalidateEnvAll
local isTrackedEnv = RuntimeEnv.isTrackedEnv
local recordLockedMetatable = RuntimeEnv.recordLockedMetatable
local recordDeadSnapshot = RuntimeEnv.recordDeadSnapshot
local buildDebugFrameInfo = RuntimeEnv.buildDebugFrameInfo
local computeSafeRootsMask = RuntimeEnv.computeSafeRootsMask
local createModuleContext = RuntimeEnv.createModuleContext
local formatVmError = RuntimeEnv.formatVmError
local resolveGetImportSlow = RuntimeEnv.resolveGetImportSlow
local resolveHostFuncName = RuntimeEnv.resolveHostFuncName
local resolveShadowedInstanceMethod = RuntimeEnv.resolveShadowedInstanceMethod
local clearErrorState = RuntimeEnv.clearErrorState

do
	local _, sample = pcall(function()
		error("@", 1)
	end)
	local s = tostring(sample)
	local pfx = string.match(s, "^(.*):%d+: @$") or ""
	RuntimeEnv.registerVmChunkPrefix(pfx)
	RuntimeEnv.registerVmChunkPrefix(Fastcalls.chunkPrefix)
end

local EMPTY_UPVALS: { Upval } = table.freeze({}) :: any
local EMPTY_VARARGS = table.freeze({}) :: { any }
local MAX_ACTIVE_STACK_SLOTS = 1_000_000
local cloneDuptableSeed = Verifier.cloneDuptableSeed

local function stackOverflowMsg(ctx: ModuleContext): string
	return if ctx.callLimit ~= nil then "call stack overflow" else "stack overflow"
end

local function ensureTimeoutClock(ctx: ModuleContext): number
	local sc = ctx.startClock
	if sc ~= nil then
		return sc
	end
	local now = os.clock()
	ctx.startClock = now
	return now
end

local function isBudgetAborted(ctx: ModuleContext, err: unknown?): boolean
	if ctx.interrupted then
		return true
	end
	if ctx.insnLimit ~= nil and ctx.insnCount > ctx.insnLimit then
		return true
	end
	if ctx.timeout ~= nil and (os.clock() - ensureTimeoutClock(ctx)) > ctx.timeout then
		return true
	end
	return err == "execution interrupted" or err == "instruction limit exceeded" or err == "execution timeout exceeded"
end

local function getPredecoded(ctx: ModuleContext, proto: Proto): PredecodedProto
	local idx = proto.id + 1
	local pdata = ctx.predecoded[idx]
	if not pdata then
		local tmpl = ctx.templates[idx]
		if not tmpl then
			tmpl = Verifier.predecodeProtoTemplate(proto)
			ctx.templates[idx] = tmpl
		end
		pdata = Verifier.instantiatePredecoded(tmpl, proto, ctx.env, ctx.safeRootsMask)
		ctx.predecoded[idx] = pdata
	end
	return pdata
end

@native
local function getOpenUpval(frame: FrameState, reg: number): Upval
	local regs = frame.openUvRegs
	local objs = frame.openUvObjs
	local count = frame.openUvCount
	if count == 1 then
		if (regs :: { number })[1] == reg then
			return (objs :: { Upval })[1]
		end
	elseif count > 1 then
		local r = regs :: { number }
		for i = 1, count do
			if r[i] == reg then
				return (objs :: { Upval })[i]
			end
		end
	end
	if regs == nil then
		local newRegs: { number } = table.create(4) :: { number }
		local newObjs: { Upval } = table.create(4) :: { Upval }
		regs = newRegs
		objs = newObjs
		frame.openUvRegs = newRegs
		frame.openUvObjs = newObjs
	end
	local created: Upval = { frame.stack, reg, false }
	local nextCount = count + 1
	local rArr = regs :: { number }
	local oArr = objs :: { Upval }
	rArr[nextCount] = reg
	oArr[nextCount] = created
	frame.openUvCount = nextCount
	frame.hasOpenUpvals = true
	return created
end

@native
local function closeUpvals(frame: FrameState, fromReg: number)
	local count = frame.openUvCount
	if count == 0 then
		frame.hasOpenUpvals = false
		return
	end
	local regs = frame.openUvRegs :: { number }
	local objs = frame.openUvObjs :: { Upval }
	local stack = frame.stack
	if count == 1 then
		if regs[1] >= fromReg then
			local uv = objs[1]
			uv[3] = stack[regs[1]]
			uv[1] = uv
			uv[2] = 3
			objs[1] = nil :: any
			frame.openUvCount = 0
			frame.hasOpenUpvals = false
		end
		return
	end
	local i = 1
	while i <= count do
		local reg = regs[i]
		if reg >= fromReg then
			local uv = objs[i]
			uv[3] = stack[reg]
			uv[1] = uv
			uv[2] = 3
			if i ~= count then
				regs[i] = regs[count]
				objs[i] = objs[count]
			end
			objs[count] = nil :: any
			count -= 1
		else
			i += 1
		end
	end
	frame.openUvCount = count
	frame.hasOpenUpvals = count > 0
end

local instantiateClosure: (ctx: ModuleContext, proto: Proto, upvals: { Upval }, env: { [any]: any }) -> (...any) -> ...any
local unwindFrames: (tstate: ThreadState, targetDepth: number, co: thread?) -> ()

@native
local function canReuseDupClosure(
	kcl: (...any) -> ...any,
	argA: { number },
	argB: { number },
	pc: number,
	nups: number,
	stack: { [number]: any },
	upvals: { Upval },
	ctxEnv: { [any]: any }
): boolean
	local kclMeta = closureMeta[kcl]
	if not kclMeta or kclMeta.env ~= ctxEnv then
		return false
	end
	local kclUpvals = kclMeta.upvals
	for ui = 1, nups do
		local capIdx = pc + ui
		local capType = argA[capIdx]
		local capReg = argB[capIdx]
		local prevU = kclUpvals[ui]
		if capType == LCT_VAL then
			if not (prevU[4] == true and rawequal(prevU[3], stack[capReg])) then
				return false
			end
		else
			local uv = upvals[capReg]
			if not (prevU == uv or (prevU[4] == true and uv[4] == true and rawequal(prevU[3], uv[3]))) then
				return false
			end
		end
	end
	return true
end

@native
local function spawnChildClosure(
	frame: FrameState,
	pc: number,
	a: number,
	childFid: number,
	isDupClosure: boolean?
): number
	local meta = frame.meta
	local ctx = meta.ctx
	local stack = frame.stack
	local upvals = meta.upvals
	local pdata = meta.pdata :: PredecodedProto
	local argA = pdata.argA
	local argB = pdata.argB
	local childProto = ctx.protos[childFid + 1]
	local nups = childProto.nups

	if isDupClosure and meta.env == ctx.env then
		local cache = ctx.dupClosureCache
		if cache then
			local cachedFn = cache[childFid]
			if cachedFn ~= nil then
				if nups == 0 then
					stack[a] = cachedFn
					return pc + 1
				end
				local prevSlot = stack[a]
				stack[a] = cachedFn
				if canReuseDupClosure(cachedFn, argA, argB, pc, nups, stack, upvals, meta.env) then
					return pc + 1 + nups
				end
				stack[a] = prevSlot
			end
		end
	end

	if nups == 0 then
		local newFn = instantiateClosure(ctx, childProto, EMPTY_UPVALS, meta.env)
		stack[a] = newFn
		if isDupClosure and meta.env == ctx.env then
			local cache = ctx.dupClosureCache
			if not cache then
				cache = {}
				ctx.dupClosureCache = cache
			end
			if (cache :: { [number]: (...any) -> ...any })[childFid] == nil then
				(cache :: { [number]: (...any) -> ...any })[childFid] = newFn
			end
		end
		return pc + 1
	elseif nups == 1 then
		local childUpvals: { Upval } = table.create(1) :: { Upval }
		local newFn = instantiateClosure(ctx, childProto, childUpvals, meta.env)
		stack[a] = newFn
		local capIdx = pc + 1
		local capType = argA[capIdx]
		local capReg = argB[capIdx]
		if capType == LCT_VAL then
			local u: Upval = { false, 3, stack[capReg], true }
			u[1] = u
			childUpvals[1] = u
		elseif capType == LCT_REF then
			childUpvals[1] = getOpenUpval(frame, capReg)
		else
			childUpvals[1] = upvals[capReg]
		end
		if isDupClosure and meta.env == ctx.env then
			local cache = ctx.dupClosureCache
			if not cache then
				cache = {}
				ctx.dupClosureCache = cache
			end
			if (cache :: { [number]: (...any) -> ...any })[childFid] == nil then
				(cache :: { [number]: (...any) -> ...any })[childFid] = newFn
			end
		end
		return pc + 2
	end

	local childUpvals: { Upval } = table.create(nups) :: { Upval }
	local newFn = instantiateClosure(ctx, childProto, childUpvals, meta.env)
	stack[a] = newFn
	for ui = 1, nups do
		local capIdx = pc + ui
		local capType = argA[capIdx]
		local capReg = argB[capIdx]
		if capType == LCT_VAL then
			local u: Upval = { false, 3, stack[capReg], true }
			u[1] = u
			childUpvals[ui] = u
		elseif capType == LCT_REF then
			childUpvals[ui] = getOpenUpval(frame, capReg)
		else
			childUpvals[ui] = upvals[capReg]
		end
	end
	if isDupClosure and meta.env == ctx.env then
		local cache = ctx.dupClosureCache
		if not cache then
			cache = {}
			ctx.dupClosureCache = cache
		end
		if (cache :: { [number]: (...any) -> ...any })[childFid] == nil then
			(cache :: { [number]: (...any) -> ...any })[childFid] = newFn
		end
	end
	return pc + 1 + nups
end

local function callFixed(fn: any, stack: { [number]: any }, a: number, callArgs: number): (any, any, any)
	if callArgs == 0 then
		return fn()
	elseif callArgs == 1 then
		return fn(stack[a + 1])
	elseif callArgs == 2 then
		return fn(stack[a + 1], stack[a + 2])
	elseif callArgs == 3 then
		return fn(stack[a + 1], stack[a + 2], stack[a + 3])
	else
		return fn(table.unpack(stack, a + 1, a + callArgs))
	end
end

local function pushCFrame(tstate: ThreadState, fn: any, cName: string?): FrameState
	local cDepth = tstate.depth + 1
	tstate.depth = cDepth
	local frames = tstate.frames
	local cf = frames[cDepth]
	local nameVal: string | boolean = cName or false
	if cf then
		cf.isCFrame = true
		cf.isPcall = false
		cf.cFunc = fn
		cf.cName = nameVal
		cf.meta = (nil :: any) :: ClosureMeta
		cf.closure = nil
		cf.openUvCount = 0
		cf.hasOpenUpvals = false
		cf.pc = 0
		cf.savedPcallDepth = nil
		cf.savedXpcallDepth = nil
		cf.savedXpcallSnapshot = nil
		cf.savedXpcallInsertDepth = nil
	else
		cf = (
			{
				isCFrame = true,
				isPcall = false,
				cFunc = fn,
				cName = nameVal,
				meta = (nil :: any) :: ClosureMeta,
				closure = nil,
				stack = EMPTY_VARARGS,
				stackCap = 0,
				stackSlots = 0,
				varargs = EMPTY_VARARGS,
				varargsBuf = nil,
				varargsCap = 0,
				nvarargs = 0,
				top = 0,
				openUvRegs = nil,
				openUvObjs = nil,
				openUvCount = 0,
				hasOpenUpvals = false,
				pc = 0,
				returnPc = 1,
				callA = 1,
				callNResults = 0,
				lastLine = 0,
				savedPcallDepth = nil,
				savedXpcallDepth = nil,
				savedXpcallSnapshot = nil,
				savedXpcallInsertDepth = nil,
			} :: any
		) :: FrameState
		frames[cDepth] = cf
	end
	return cf
end

local function popCFrame(tstate: ThreadState, targetDepth: number, cf: FrameState)
	if cf.isPcall then
		tstate.pcallDepth = cf.savedPcallDepth or 0
		cf.savedPcallDepth = nil
	end
	cf.isCFrame = false
	cf.isPcall = false
	cf.cFunc = false
	cf.cName = false
	cf.savedXpcallDepth = nil
	cf.savedXpcallSnapshot = nil
	cf.savedXpcallInsertDepth = nil
	tstate.depth = targetDepth
end

local function callPcallWrapped(target: any, stack: { [number]: any }, a: number, callArgs: number): ...any
	if callArgs == 1 then
		return hostPcall(target)
	elseif callArgs == 2 then
		return hostPcall(target, stack[a + 2])
	elseif callArgs == 3 then
		return hostPcall(target, stack[a + 2], stack[a + 3])
	else
		return hostPcall(target, table.unpack(stack, a + 2, a + callArgs))
	end
end

local function storeFixedOrPackResults(
	tstate: ThreadState,
	stack: { [number]: any },
	frame: FrameState,
	a: number,
	nresults: number,
	...: any
)
	if nresults == 0 then
		return
	elseif nresults == 1 then
		stack[a] = (...)
	else
		local rets = table.pack(...)
		local nret = rets.n
		if nresults < 0 then
			if tstate.activeStackSlots + nret > MAX_ACTIVE_STACK_SLOTS then
				error("too many results to unpack", 0)
			end
			for i = 1, nret do
				stack[a + i - 1] = rets[i]
			end
			frame.top = a + nret
		else
			for i = 1, nresults do
				stack[a + i - 1] = rets[i]
			end
		end
	end
end

local function execCall(tstate: ThreadState, frame: FrameState, a: number, b: number, nresults: number)
	local stack = frame.stack
	local callArgs = if b == 0 then (frame.top - (a + 1)) else (b - 1)
	local fn = stack[a]
	local ctx = frame.meta.ctx
	local wr = ctx.resourceLimitWrappers
	if fn ~= nil then
		fn = HOST_WRAPPERS[fn] or fn
		if wr ~= nil then
			fn = wr[fn] or fn
		end
	end

	local savedDepth = tstate.depth
	local limitBound = ctx.effectiveCallLimit + tstate.callLimitHeadroom
	if
		if ctx.callLimit ~= nil
			then (savedDepth + 1 > limitBound or getActiveCalls(ctx) >= limitBound)
			else savedDepth + 1 >= limitBound
	then
		error(stackOverflowMsg(ctx), 0)
	end
	local outerCf = pushCFrame(tstate, fn, if fn == hostPcall then "pcall" else nil)

	if fn == hostPcall then
		local argFn = if callArgs >= 1 then stack[a + 1] else nil
		if argFn ~= nil then
			argFn = HOST_WRAPPERS[argFn] or argFn
			if wr ~= nil then
				argFn = wr[argFn] or argFn
			end
		end
		local prevCaptureDepth = tstate.xpcallCaptureDepth
		local prevSnapshot = tstate.xpcallSnapshot
		local prevInsertDepth = tstate.xpcallSnapshotInsertDepth
		tstate.xpcallCaptureDepth = 0
		tstate.xpcallSnapshot = nil
		tstate.xpcallSnapshotInsertDepth = 0
		if callArgs >= 1 then
			if type(argFn) == "function" and closureMeta[argFn] == nil then
				local innerCf = pushCFrame(tstate, argFn, nil)
				storeFixedOrPackResults(tstate, stack, frame, a, nresults, callPcallWrapped(argFn, stack, a, callArgs))
				popCFrame(tstate, savedDepth + 1, innerCf)
			else
				storeFixedOrPackResults(tstate, stack, frame, a, nresults, callPcallWrapped(argFn, stack, a, callArgs))
			end
		else
			storeFixedOrPackResults(tstate, stack, frame, a, nresults, hostPcall())
		end
		tstate.xpcallCaptureDepth = prevCaptureDepth
		tstate.xpcallSnapshot = prevSnapshot
		tstate.xpcallSnapshotInsertDepth = prevInsertDepth
		popCFrame(tstate, savedDepth, outerCf)
		clearErrorState()
		return
	end

	if nresults == 0 then
		callFixed(fn, stack, a, callArgs)
	elseif nresults == 1 then
		local r1 = callFixed(fn, stack, a, callArgs)
		stack[a] = r1
	elseif nresults == 2 then
		local r1, r2 = callFixed(fn, stack, a, callArgs)
		stack[a] = r1
		stack[a + 1] = r2
	elseif nresults == 3 then
		local r1, r2, r3 = callFixed(fn, stack, a, callArgs)
		stack[a] = r1
		stack[a + 1] = r2
		stack[a + 2] = r3
	else
		local rets = table.pack(fn(table.unpack(stack, a + 1, a + callArgs)))
		local nret = rets.n
		if nresults < 0 then
			if tstate.activeStackSlots + nret > MAX_ACTIVE_STACK_SLOTS then
				error("too many results to unpack", 0)
			end
			for i = 1, nret do
				stack[a + i - 1] = rets[i]
			end
			frame.top = a + nret
		else
			for i = 1, nresults do
				stack[a + i - 1] = rets[i]
			end
		end
	end

	popCFrame(tstate, savedDepth, outerCf)
	clearErrorState()
end

@native
local function execForGLoopSlow(frame: FrameState, pc: number, a: number, nvars: number, targetPc: number): number
	local stack = frame.stack
	local gen = stack[a]
	local state = stack[a + 1]
	local idx = stack[a + 2]
	if nvars == 1 then
		stack[a + 3] = gen(state, idx)
	elseif nvars == 2 then
		local v1, v2 = gen(state, idx)
		stack[a + 3] = v1
		stack[a + 4] = v2
	elseif nvars == 3 then
		local v1, v2, v3 = gen(state, idx)
		stack[a + 3] = v1
		stack[a + 4] = v2
		stack[a + 5] = v3
	else
		local rets = table.pack(gen(state, idx))
		for i = 1, nvars do
			stack[a + 2 + i] = rets[i]
		end
	end
	if stack[a + 3] ~= nil then
		stack[a + 2] = stack[a + 3]
		return targetPc
	else
		return pc + 2
	end
end

@native
local function execForGPrep(frame: FrameState, op: number, a: number, targetPc: number): number
	local stack = frame.stack
	local gen: any = stack[a]
	if op == VOP_FORGPREP then
		if type(gen) ~= "function" then
			local tgen = type(gen)
			local mt = if tgen == "table" or tgen == "userdata" then getInternalMetatable(gen) else nil
			local iterMm: ((any) -> (any, any, any))? = if mt ~= nil
				then rawget(mt, "__iter") :: ((any) -> (any, any, any))?
				else nil
			if iterMm ~= nil then
				local tstate = getActiveThreadState(coroutine.running())
				if tstate ~= nil then
					tstate.nonYieldableDepth += 1
				end
				local okIter, g, s, initIdx = hostPcall(iterMm, gen)
				if tstate ~= nil then
					tstate.nonYieldableDepth -= 1
				end
				if not okIter then
					error(g, 0)
				end
				stack[a] = g
				stack[a + 1] = s
				stack[a + 2] = initIdx
				if g == nil then
					error("attempt to call a nil value", 0)
				end
			elseif mt ~= nil and rawget(mt, "__call") ~= nil then
				-- Callable table or userdata handled during FORGLOOP
			elseif tgen == "table" then
				stack[a + 1] = gen
				stack[a] = vmNext
				stack[a + 2] = nil
			elseif tgen == "userdata" and getmetatable(gen) ~= nil and mt == nil then
				-- Opaque host userdata handled during FORGLOOP
			else
				error("attempt to iterate over a " .. typeofFn(gen) .. " value", 0)
			end
		end
	elseif op == VOP_FORGPREP_INEXT then
		if
			bit32.btest(frame.meta.ctx.safeRootsMask, ROOT_BIT_IPAIRS)
			and gen == hostInext
			and type(stack[a + 1]) == "table"
			and stack[a + 2] == 0
		then
			stack[a] = inext
		elseif type(gen) ~= "function" then
			error("attempt to iterate over a " .. typeofFn(gen) .. " value", 0)
		end
	else -- VOP_FORGPREP_NEXT
		if type(gen) ~= "function" then
			error("attempt to iterate over a " .. typeofFn(gen) .. " value", 0)
		end
	end
	return targetPc
end

@native
local function execForNPrep(frame: FrameState, pc: number, a: number, skipPc: number): number
	local stack = frame.stack
	local rawInit = stack[a + 2]
	local idx = tonumber(rawInit)
	if not idx then
		error("invalid 'for' initial value (number expected, got " .. typeofFn(rawInit) .. ")", 0)
	end
	local rawLimit = stack[a]
	local limit = tonumber(rawLimit)
	if not limit then
		error("invalid 'for' limit (number expected, got " .. typeofFn(rawLimit) .. ")", 0)
	end
	local rawStep = stack[a + 1]
	local step = tonumber(rawStep)
	if not step then
		error("invalid 'for' step (number expected, got " .. typeofFn(rawStep) .. ")", 0)
	end
	stack[a] = limit
	stack[a + 1] = step
	stack[a + 2] = idx
	if not (if step > 0 then idx <= limit else limit <= idx) then
		return skipPc
	end
	return pc + 1
end

@native
local function execConcat(stack: { [number]: any }, a: number, b: number, c: number, maxStrLen: number?)
	local count = c - b + 1
	if count >= 3 then
		local allFast = true
		local totalLen = 0
		for i = b, c do
			local v = stack[i]
			local vt = type(v)
			if vt == "string" then
				totalLen += #v
			elseif vt == "number" then
				totalLen += #tostring(v)
			else
				allFast = false
				break
			end
		end
		if allFast then
			if maxStrLen ~= nil and totalLen > maxStrLen then
				error("string length limit exceeded", 0)
			end
			if a < b or a > c then
				stack[a] = nil
			end
			stack[a] = table.concat(stack :: { any }, "", b, c)
			return
		end
	end
	if maxStrLen ~= nil then
		local totalLen = 0
		local allFast = true
		for i = b, c do
			local v = stack[i]
			local vt = type(v)
			if vt == "string" then
				totalLen += #v
			elseif vt == "number" then
				totalLen += #tostring(v)
			else
				allFast = false
				break
			end
		end
		if allFast and totalLen > maxStrLen then
			error("string length limit exceeded", 0)
		end
	end
	local acc = stack[c]
	for i = c - 1, b, -1 do
		acc = stack[i] .. acc
	end
	if maxStrLen ~= nil and type(acc) == "string" and #acc > maxStrLen then
		error("string length limit exceeded", 0)
	end
	stack[a] = acc
end

@native
local function resolveNamecall(meta: ClosureMeta, obj: any, methodName: any): any
	if type(obj) == "userdata" then
		local mt = getInternalMetatable(obj)
		if mt ~= nil then
			local nc = rawget(mt, "__namecall")
			if nc ~= nil then
				return nc
			end
		end
	end
	local ctx = meta.ctx
	local getGlobalHook = ctx.getGlobal
	local wr = ctx.resourceLimitWrappers
	local resolved: any
	if obj == meta.env and getGlobalHook ~= nil and type(methodName) == "string" then
		resolved = getGlobalHook(methodName, meta.env)
	else
		resolved = obj[methodName]
	end
	if resolved == nil then
		error("attempt to call missing method '" .. tostring(methodName) .. "' of " .. typeofFn(obj), 0)
	end
	if type(resolved) == "userdata" and typeofFn(resolved) == "Instance" then
		resolved = resolveShadowedInstanceMethod(obj, methodName, resolved)
	end
	if type(resolved) == "function" or type(resolved) == "table" then
		resolved = HOST_WRAPPERS[resolved] or resolved
		if wr ~= nil then
			resolved = wr[resolved] or resolved
		end
	end
	return resolved
end

@native
local function stepColdOpcode(frame: FrameState, pc: number, op: number, a: number): number
	local stack = frame.stack
	local meta = frame.meta
	local ctx = meta.ctx
	local pdata = meta.pdata :: PredecodedProto
	local auxVal = pdata.auxVal

	if op == VOP_NEWCLOSURE then
		return spawnChildClosure(frame, pc, a, pdata.argD[pc], false)
	elseif op == VOP_DUPCLOSURE then
		return spawnChildClosure(frame, pc, a, pdata.argD[pc], true)
	elseif op == VOP_CLOSEUPVALS then
		closeUpvals(frame, a)
		return pc + 1
	elseif op == VOP_CONCAT then
		execConcat(stack, a, pdata.argB[pc], pdata.argC[pc], ctx.maxStringLength)
		return pc + 1
	elseif op == VOP_GETVARARGS then
		local b = pdata.argB[pc]
		local nvarargs = frame.nvarargs
		local varargs = frame.varargs
		local cnt = if b == 0 then nvarargs else (b - 1)
		for i = 1, cnt do
			stack[a + i - 1] = varargs[i]
		end
		if b == 0 then
			frame.top = a + nvarargs
		end
		return pc + 1
	elseif op == VOP_FORGPREP_INEXT or op == VOP_FORGPREP_NEXT or op == VOP_FORGPREP then
		return execForGPrep(frame, op, a, pdata.argD[pc])
	elseif op == VOP_LOADKX then
		stack[a] = auxVal[pc]
		return pc + 2
	elseif op == VOP_JUMPX then
		return pdata.argD[pc]
	elseif op == VOP_SUBRK then
		stack[a] = auxVal[pc] - stack[pdata.argC[pc]]
		return pc + 1
	elseif op == VOP_DIVRK then
		stack[a] = auxVal[pc] / stack[pdata.argC[pc]]
		return pc + 1
	elseif op == VOP_GETUDATAKS then
		local tbl = stack[pdata.argB[pc]]
		local k = auxVal[pc]
		local getGlobalHook = ctx.getGlobal
		local val = if tbl == meta.env
				and getGlobalHook ~= nil
				and type(k) == "string"
			then getGlobalHook(k, meta.env)
			else tbl[k]
		if tbl == meta.env and val ~= nil and (type(val) == "function" or type(val) == "table") then
			val = HOST_WRAPPERS[val] or val
		end
		local wr = ctx.resourceLimitWrappers
		if wr ~= nil and val ~= nil then
			val = wr[val] or val
		end
		stack[a] = val
		return pc + 2
	elseif op == VOP_SETUDATAKS then
		local tbl = stack[pdata.argB[pc]]
		local k = auxVal[pc]
		local val = stack[a]
		local setGlobalHook = ctx.setGlobal
		if tbl == meta.env then
			if SAFE_INVALIDATION_KEYS[k] ~= nil then
				invalidateEnvRoot(ctx, meta.env, k)
			end
			if
				not ctx.needsHostWrappers
				and (type(val) == "function" or type(val) == "table")
				and HOST_WRAPPERS[val] ~= nil
			then
				ctx.needsHostWrappers = true
			end
			if setGlobalHook ~= nil and type(k) == "string" then
				setGlobalHook(k, val, meta.env)
			else
				tbl[k] = val
			end
		else
			if isTrackedEnv(tbl) and pdata.argC[pc] ~= 0 then
				invalidateEnvRoot(nil, tbl, k)
			end
			tbl[k] = val
		end
		return pc + 2
	elseif op == VOP_NAMECALLUDATA then
		local obj = stack[pdata.argB[pc]]
		local methodName = auxVal[pc]
		stack[a + 1] = obj
		stack[a] = resolveNamecall(meta, obj, methodName)
		return pc + 2
	elseif op == VOP_CMPPROTO then
		local fn = stack[a]
		local expectedFunid = auxVal[pc]
		local cmeta = if fn ~= nil then closureMeta[fn] else nil
		if
			cmeta ~= nil
			and (
				(cmeta.proto :: any).funid == expectedFunid
				or ((cmeta.proto :: any).funid == nil and cmeta.ctx == ctx and cmeta.proto.id == expectedFunid)
			)
		then
			return pc + 2
		end
		return pdata.argD[pc]
	elseif op == VOP_COVERAGE then
		local covMap = ctx.coverage
		if not covMap then
			covMap = {}
			ctx.coverage = covMap
		end
		local pid = meta.proto.id + 1
		local protoCov = (covMap :: { [number]: { number } })[pid]
		if not protoCov then
			protoCov = {}
			(covMap :: { [number]: { number } })[pid] = protoCov
		end
		local hits = protoCov[pc] or 0
		if hits < 0x7fffff then
			protoCov[pc] = hits + 1
		end
		return pc + 1
	elseif op == VOP_BREAK then
		local onBreakHook = ctx.onBreak
		if onBreakHook then
			local tstate = getActiveThreadState(coroutine.running())
			local depth = if tstate then tstate.depth else 1
			onBreakHook(getLineForPc(meta.proto, pc), buildDebugFrameInfo(frame, depth, pc))
		end
		return pc + 1
	elseif op == VOP_CAPTURE or op == VOP_FASTPCALL or op == VOP_NOP then
		return pc + 1
	else
		error("unsupported opcode: " .. tostring(op), 0)
	end
end

local function acquireDepthStack(tstate: ThreadState, depth: number, minCap: number): ({ [number]: any }, number)
	local f = tstate.frames[depth]
	if f ~= nil and f.stackCap > 0 and f.stackCap >= minCap then
		return f.stack, f.stackCap
	end
	local cap = if minCap <= 16 then 16 elseif minCap <= 32 then 32 else minCap
	return table.create(cap), cap
end

local function releaseTopFrame(tstate: ThreadState, frame: FrameState, stack: { [number]: any }, co: thread?)
	if frame.isCFrame then
		if frame.isPcall then
			tstate.pcallDepth = frame.savedPcallDepth or 0
			frame.savedPcallDepth = nil
		end
		frame.isCFrame = false
		frame.isPcall = false
		frame.cFunc = false
		frame.cName = false
		frame.savedXpcallDepth = nil
		frame.savedXpcallSnapshot = nil
		frame.savedXpcallInsertDepth = nil
		tstate.depth -= 1
		return
	end
	table.clear(stack)

	local fmeta = frame.meta
	if fmeta ~= nil then
		local fctx = fmeta.ctx
		if fctx.callLimit ~= nil then
			addActiveCall(fctx, co or coroutine.running(), -1)
		end
	end
	tstate.activeStackSlots -= frame.stackSlots
	frame.stackSlots = 0
	local newDepth = tstate.depth - 1
	tstate.depth = newDepth
	if newDepth <= 0 then
		tstate.threadEnv = nil
	end
	frame.meta = nil :: any
	frame.closure = nil
	local nva = frame.nvarargs
	if nva > 0 then
		local va = frame.varargs
		if va == frame.varargsBuf then
			for i = 1, nva do
				va[i] = nil
			end
		end
		frame.varargs = EMPTY_VARARGS
		frame.nvarargs = 0
	end
end

local function acquireVarargsBuf(frame: FrameState?, nvarargs: number): ({ [number]: any }, number)
	if frame ~= nil and frame.varargsBuf ~= nil and frame.varargsCap >= nvarargs then
		return frame.varargsBuf, frame.varargsCap
	end
	local vcap = if nvarargs <= 8 then 8 else nvarargs
	local vbuf = table.create(vcap)
	if frame ~= nil then
		frame.varargsBuf = vbuf
		frame.varargsCap = vcap
	end
	return vbuf, vcap
end

local function initFrame(
	tstate: ThreadState,
	meta: ClosureMeta,
	closure: (...any) -> ...any,
	stack: { [number]: any },
	stackCap: number,
	varargs: { [number]: any },
	varargsCap: number,
	nvarargs: number,
	numparams: number
): FrameState
	local frameSlots = meta.proto.maxstacksize + nvarargs
	if tstate.activeStackSlots + frameSlots > MAX_ACTIVE_STACK_SLOTS then
		error(if nvarargs > 0 or frameSlots > 255 then "too many results to unpack" else "call stack overflow", 0)
	end
	tstate.activeStackSlots += frameSlots
	local newDepth = tstate.depth + 1
	tstate.depth = newDepth
	if meta.ctx.callLimit ~= nil then
		addActiveCall(meta.ctx, coroutine.running(), 1)
	end
	local frames = tstate.frames
	local frame = frames[newDepth]
	if frame then
		frame.isCFrame = false
		frame.isPcall = false
		frame.cFunc = false
		frame.cName = false
		frame.meta = meta
		frame.closure = closure
		frame.stack = stack
		frame.stackCap = stackCap
		frame.stackSlots = frameSlots
		frame.varargs = varargs
		frame.nvarargs = nvarargs
		frame.top = numparams + 1
		frame.openUvCount = 0
		frame.hasOpenUpvals = false
		frame.pc = 1
		frame.lastLine = 0
	else
		frame = (
			{
				isCFrame = false,
				isPcall = false,
				cFunc = false,
				cName = false,
				meta = meta,
				closure = closure,
				stack = stack,
				stackCap = stackCap,
				stackSlots = frameSlots,
				varargs = varargs,
				varargsBuf = if varargsCap > 0 then varargs else nil,
				varargsCap = varargsCap,
				nvarargs = nvarargs,
				top = numparams + 1,
				openUvRegs = nil,
				openUvObjs = nil,
				openUvCount = 0,
				hasOpenUpvals = false,
				pc = 1,
				returnPc = 1,
				callA = 1,
				callNResults = 0,
				lastLine = 0,
				savedPcallDepth = nil,
				savedXpcallDepth = nil,
				savedXpcallSnapshot = nil,
				savedXpcallInsertDepth = nil,
			} :: any
		) :: FrameState
		frames[newDepth] = frame
	end
	return frame
end

@native
local function pushCalleeFrame(
	tstate: ThreadState,
	callerFrame: FrameState,
	callerStack: { [number]: any },
	a: number,
	b: number,
	fn: (...any) -> ...any,
	meta: ClosureMeta
): FrameState
	local calleeCtx = meta.ctx
	local callerCtx = callerFrame.meta.ctx
	if calleeCtx.interrupted or callerCtx.interrupted then
		error("execution interrupted", 0)
	end
	local newDepth = tstate.depth + 1
	local headroom = tstate.callLimitHeadroom
	local calleeLimit = calleeCtx.effectiveCallLimit + headroom
	local callerLimit = callerCtx.effectiveCallLimit + headroom
	if
		(
			if calleeCtx.callLimit ~= nil
				then (newDepth > calleeLimit or getActiveCalls(calleeCtx) >= calleeLimit)
				else newDepth >= calleeLimit
		)
		or (
			if callerCtx.callLimit ~= nil
				then (newDepth > callerLimit or getActiveCalls(callerCtx) >= callerLimit)
				else newDepth >= callerLimit
		)
	then
		error(
			if callerCtx.callLimit ~= nil or calleeCtx.callLimit ~= nil then "call stack overflow" else "stack overflow",
			0
		)
	end
	local calleeProto = meta.proto
	if not meta.pdata then
		meta.pdata = getPredecoded(calleeCtx, calleeProto)
	end

	local callArgs = if b == 0 then (callerFrame.top - (a + 1)) else (b - 1)
	local numparams = calleeProto.numparams
	local nvarargs = if calleeProto.isvararg and callArgs > numparams then callArgs - numparams else 0
	local frameSlots = calleeProto.maxstacksize + nvarargs
	if tstate.activeStackSlots + frameSlots > MAX_ACTIVE_STACK_SLOTS then
		error(if nvarargs > 0 or frameSlots > 255 then "too many results to unpack" else "call stack overflow", 0)
	end
	local calleeStack, stackCap = acquireDepthStack(tstate, newDepth, calleeProto.maxstacksize)

	local copyParams = if callArgs < numparams then callArgs else numparams
	if copyParams == 1 then
		calleeStack[1] = callerStack[a + 1]
	elseif copyParams == 2 then
		calleeStack[1] = callerStack[a + 1]
		calleeStack[2] = callerStack[a + 2]
	elseif copyParams > 2 then
		for i = 1, copyParams do
			calleeStack[i] = callerStack[a + i]
		end
	end

	local varargs = EMPTY_VARARGS
	local vcap = 0
	if nvarargs > 0 then
		varargs, vcap = acquireVarargsBuf(tstate.frames[newDepth], nvarargs)
		for i = 1, nvarargs do
			varargs[i] = callerStack[a + i + numparams]
		end
	end

	return initFrame(tstate, meta, fn, calleeStack, stackCap, varargs, vcap, nvarargs, numparams)
end

@native
local function pushInVmPcallFrame(
	tstate: ThreadState,
	callerFrame: FrameState,
	callerStack: { [number]: any },
	a: number,
	callArgs: number,
	nresults: number,
	returnPc: number,
	argFn: (...any) -> ...any,
	argMeta: ClosureMeta
): FrameState
	local callerCtx = callerFrame.meta.ctx
	local headroom = tstate.callLimitHeadroom
	local callerLimit = callerCtx.effectiveCallLimit + headroom
	if
		if callerCtx.callLimit ~= nil
			then (tstate.depth + 1 > callerLimit or getActiveCalls(callerCtx) >= callerLimit)
			else tstate.depth + 1 >= callerLimit
	then
		error(stackOverflowMsg(callerCtx), 0)
	end
	local outerCf = pushCFrame(tstate, hostPcall, "pcall")
	outerCf.isPcall = true
	outerCf.savedPcallDepth = tstate.pcallDepth
	tstate.pcallDepth = tstate.depth
	outerCf.callA = a
	outerCf.callNResults = nresults
	outerCf.returnPc = returnPc
	if tstate.xpcallCaptureDepth > 0 or tstate.xpcallSnapshot ~= nil then
		outerCf.savedXpcallDepth = tstate.xpcallCaptureDepth
		outerCf.savedXpcallSnapshot = tstate.xpcallSnapshot
		outerCf.savedXpcallInsertDepth = tstate.xpcallSnapshotInsertDepth
		tstate.xpcallCaptureDepth = 0
		tstate.xpcallSnapshot = nil
		tstate.xpcallSnapshotInsertDepth = 0
	end

	local calleeCtx = argMeta.ctx
	if calleeCtx.interrupted or callerCtx.interrupted then
		error("execution interrupted", 0)
	end
	local calleeLimit = calleeCtx.effectiveCallLimit + headroom
	local newDepth = tstate.depth + 1
	if
		(
			if calleeCtx.callLimit ~= nil
				then (newDepth > calleeLimit or getActiveCalls(calleeCtx) >= calleeLimit)
				else newDepth >= calleeLimit
		) or (if callerCtx.callLimit ~= nil then newDepth > callerLimit else newDepth >= callerLimit)
	then
		error(
			if callerCtx.callLimit ~= nil or calleeCtx.callLimit ~= nil then "call stack overflow" else "stack overflow",
			0
		)
	end
	local calleeProto = argMeta.proto
	if not argMeta.pdata then
		argMeta.pdata = getPredecoded(calleeCtx, calleeProto)
	end

	local argCallArgs = callArgs - 1
	if argCallArgs < 0 then
		argCallArgs = 0
	end
	local numparams = calleeProto.numparams
	local nvarargs = if calleeProto.isvararg and argCallArgs > numparams then argCallArgs - numparams else 0
	local frameSlots = calleeProto.maxstacksize + nvarargs
	if tstate.activeStackSlots + frameSlots > MAX_ACTIVE_STACK_SLOTS then
		error(if nvarargs > 0 or frameSlots > 255 then "too many results to unpack" else "call stack overflow", 0)
	end
	local calleeStack, stackCap = acquireDepthStack(tstate, newDepth, calleeProto.maxstacksize)

	local copyParams = if argCallArgs < numparams then argCallArgs else numparams
	if copyParams == 1 then
		calleeStack[1] = callerStack[a + 2]
	elseif copyParams == 2 then
		calleeStack[1] = callerStack[a + 2]
		calleeStack[2] = callerStack[a + 3]
	elseif copyParams > 2 then
		for i = 1, copyParams do
			calleeStack[i] = callerStack[a + 1 + i]
		end
	end

	local varargs = EMPTY_VARARGS
	local vcap = 0
	if nvarargs > 0 then
		varargs, vcap = acquireVarargsBuf(tstate.frames[newDepth], nvarargs)
		for i = 1, nvarargs do
			varargs[i] = callerStack[a + 1 + numparams + i]
		end
	end

	return initFrame(tstate, argMeta, argFn, calleeStack, stackCap, varargs, vcap, nvarargs, numparams)
end

@native
local function returnFromPcallFrame(
	tstate: ThreadState,
	calleeFrame: FrameState,
	calleeStack: { [number]: any },
	retA: number,
	retB: number,
	pcallCf: FrameState
): FrameState
	local actualRets = if retB == 0 then (calleeFrame.top - retA) else (retB - 1)
	if actualRets < 0 then
		actualRets = 0
	end
	local curDepth = tstate.depth
	local realCaller = tstate.frames[curDepth - 2]
	local realStack = realCaller.stack
	local pA = pcallCf.callA
	local pNRes = pcallCf.callNResults

	if pNRes == 1 then
		realStack[pA] = true
	elseif pNRes == 2 then
		realStack[pA] = true
		realStack[pA + 1] = if actualRets >= 1 then calleeStack[retA] else nil
	elseif pNRes > 2 then
		realStack[pA] = true
		local nCopy = if actualRets < pNRes - 1 then actualRets else (pNRes - 1)
		for i = 1, nCopy do
			realStack[pA + i] = calleeStack[retA + i - 1]
		end
		for i = nCopy + 1, pNRes - 1 do
			realStack[pA + i] = nil
		end
	elseif pNRes < 0 then
		if tstate.activeStackSlots + actualRets + 1 > MAX_ACTIVE_STACK_SLOTS then
			error("too many results to unpack", 0)
		end
		realStack[pA] = true
		for i = 1, actualRets do
			realStack[pA + i] = calleeStack[retA + i - 1]
		end
		realCaller.top = pA + 1 + actualRets
	end

	if pcallCf.savedXpcallDepth ~= nil then
		tstate.xpcallCaptureDepth = pcallCf.savedXpcallDepth
		tstate.xpcallSnapshot = pcallCf.savedXpcallSnapshot
		tstate.xpcallSnapshotInsertDepth = pcallCf.savedXpcallInsertDepth or 0
	end

	local retPc = pcallCf.returnPc
	releaseTopFrame(tstate, calleeFrame, calleeStack)
	popCFrame(tstate, curDepth - 2, pcallCf)
	realCaller.pc = retPc
	return realCaller
end

@native
local function popCalleeAndCopyReturns(
	tstate: ThreadState,
	calleeFrame: FrameState,
	calleeStack: { [number]: any },
	retA: number,
	retB: number
): FrameState
	local actualRets = if retB == 0 then (calleeFrame.top - retA) else (retB - 1)
	if actualRets < 0 then
		actualRets = 0
	end
	local callerFrame = tstate.frames[tstate.depth - 1]
	local callerStack = callerFrame.stack
	local callA = callerFrame.callA
	local callNResults = callerFrame.callNResults

	if callNResults == 1 then
		callerStack[callA] = if actualRets >= 1 then calleeStack[retA] else nil
	elseif callNResults > 1 then
		local copyCount = if actualRets < callNResults then actualRets else callNResults
		for i = 0, copyCount - 1 do
			callerStack[callA + i] = calleeStack[retA + i]
		end
		for i = copyCount, callNResults - 1 do
			callerStack[callA + i] = nil
		end
	elseif callNResults < 0 then
		if tstate.activeStackSlots + actualRets > MAX_ACTIVE_STACK_SLOTS then
			error("too many results to unpack", 0)
		end
		for i = 0, actualRets - 1 do
			callerStack[callA + i] = calleeStack[retA + i]
		end
		callerFrame.top = callA + actualRets
	end

	releaseTopFrame(tstate, calleeFrame, calleeStack)
	callerFrame.pc = callerFrame.returnPc
	return callerFrame
end

local function unpackAndReleaseEntryFrame(
	tstate: ThreadState,
	frame: FrameState,
	stack: { [number]: any },
	a: number,
	b: number
): ...any
	local nret = if b == 0 then (frame.top - a) else (b - 1)
	if nret <= 0 then
		tstate.entryRetCount = 0
		releaseTopFrame(tstate, frame, stack)
		return
	elseif nret == 1 then
		local r1 = stack[a]
		tstate.entryRetCount = 1
		releaseTopFrame(tstate, frame, stack)
		return r1
	elseif nret == 2 then
		local r1, r2 = stack[a], stack[a + 1]
		tstate.entryRetCount = 2
		releaseTopFrame(tstate, frame, stack)
		return r1, r2
	elseif nret == 3 then
		local r1, r2, r3 = stack[a], stack[a + 1], stack[a + 2]
		tstate.entryRetCount = 3
		releaseTopFrame(tstate, frame, stack)
		return r1, r2, r3
	elseif nret == 4 then
		local r1, r2, r3, r4 = stack[a], stack[a + 1], stack[a + 2], stack[a + 3]
		tstate.entryRetCount = 4
		releaseTopFrame(tstate, frame, stack)
		return r1, r2, r3, r4
	else
		local rets = tstate.entryRets
		table.move(stack, a, a + nret - 1, 1, rets)
		tstate.entryRetCount = nret
		releaseTopFrame(tstate, frame, stack)
		return
	end
end

local guardBridge: any = nil
local guardedRunner: ((ThreadState, number, boolean?, boolean?) -> ...any)? = nil

local function getGuardedRunner(): (ThreadState, number, boolean?, boolean?) -> ...any
	local runner = guardedRunner
	if runner ~= nil then
		return runner
	end
	local DispatchGuarded = require("./DispatchGuarded")
	if guardBridge == nil then
		guardBridge = {
			stackOverflowMsg = stackOverflowMsg,
			ensureTimeoutClock = ensureTimeoutClock,
			getPredecoded = getPredecoded,
			closeUpvals = closeUpvals,
			spawnChildClosure = spawnChildClosure,
			execCall = execCall,
			execForGLoopSlow = execForGLoopSlow,
			execForGPrep = execForGPrep,
			execForNPrep = execForNPrep,
			execConcat = execConcat,
			resolveNamecall = resolveNamecall,
			stepColdOpcode = stepColdOpcode,
			pushCalleeFrame = pushCalleeFrame,
			pushInVmPcallFrame = pushInVmPcallFrame,
			returnFromPcallFrame = returnFromPcallFrame,
			popCalleeAndCopyReturns = popCalleeAndCopyReturns,
			unpackAndReleaseEntryFrame = unpackAndReleaseEntryFrame,
		}
	end
	runner = DispatchGuarded.createRunner(guardBridge)
	guardedRunner = runner
	return runner :: (ThreadState, number, boolean?, boolean?) -> ...any
end

@native
local function runLoopFast(tstate: ThreadState, entryDepth: number): ...any
	local frames = tstate.frames
	local frame = frames[tstate.depth]
	local curClosure = frame.closure
	local meta = frame.meta
	local curProto = meta.proto
	local curMaxstack = curProto.maxstacksize
	local curNumparams = curProto.numparams
	local curFixed = not curProto.isvararg
	local ctx = meta.ctx
	local stack = frame.stack
	local upvals = meta.upvals
	local pdata = meta.pdata :: PredecodedProto
	local curHasOpenTop = pdata.hasOpenTop
	local ops = pdata.ops
	local argA = pdata.argA
	local argB = pdata.argB
	local argC = pdata.argC
	local argD = pdata.argD
	local auxVal = pdata.auxVal
	local fcRa = pdata.fcRa
	local pc = frame.pc
	local getGlobalHook = ctx.getGlobal
	local setGlobalHook = ctx.setGlobal

	while true do
		local op = ops[pc]
		local a = argA[pc]

		if op <= 15 then
			if op <= 7 then
				if op <= 3 then
					if op == VOP_MOVE then
						stack[a] = stack[argB[pc]]
						pc += 1
					elseif op == VOP_LOADN then
						stack[a] = argD[pc]
						pc += 1
					elseif op == VOP_LOADK then
						stack[a] = auxVal[pc]
						pc += 1
					else -- VOP_ADDK
						frame.pc = pc
						stack[a] = stack[argB[pc]] + auxVal[pc]
						pc += 1
					end
				else
					if op == VOP_SUBK then
						frame.pc = pc
						stack[a] = stack[argB[pc]] - auxVal[pc]
						pc += 1
					elseif op == VOP_MULK then
						frame.pc = pc
						stack[a] = stack[argB[pc]] * auxVal[pc]
						pc += 1
					elseif op == VOP_MODK then
						frame.pc = pc
						stack[a] = stack[argB[pc]] % auxVal[pc]
						pc += 1
					else -- VOP_FORNLOOP
						local step = stack[a + 1]
						local idx = stack[a + 2] + step
						stack[a + 2] = idx
						if if step > 0 then idx <= stack[a] else stack[a] <= idx then
							pc = argD[pc]
						else
							pc += 1
						end
					end
				end
			elseif op <= 9 then
				if op == VOP_GETTABLEKS then
					frame.pc = pc
					local tbl = stack[argB[pc]]
					local k = auxVal[pc]
					local curEnv = meta.env
					local val: unknown
					if tbl ~= curEnv then
						val = tbl[k]
					else
						val = if getGlobalHook ~= nil and type(k) == "string" then getGlobalHook(k, curEnv) else tbl[k]
						if val ~= nil and (type(val) == "function" or type(val) == "table") then
							val = HOST_WRAPPERS[val] or val
						end
					end
					stack[a] = val
					pc += 2
				else -- VOP_SETTABLEKS
					frame.pc = pc
					local tbl = stack[argB[pc]]
					local k = auxVal[pc]
					local val = stack[a]
					local curEnv = meta.env
					if tbl == curEnv then
						if argC[pc] ~= 0 then
							invalidateEnvRoot(ctx, curEnv, k)
						end
						if
							not ctx.needsHostWrappers
							and (type(val) == "function" or type(val) == "table")
							and HOST_WRAPPERS[val] ~= nil
						then
							ctx.needsHostWrappers = true
						end
						if setGlobalHook ~= nil and type(k) == "string" then
							setGlobalHook(k, val, curEnv)
						else
							tbl[k] = val
						end
					else
						if argC[pc] ~= 0 and isTrackedEnv(tbl) then
							invalidateEnvRoot(nil, tbl, k)
						end
						tbl[k] = val
					end
					pc += 2
				end
			elseif op <= 13 then
				if op ~= VOP_CALL then
					frame.pc = pc
					if op == VOP_NAMECALL_CALL then
						local obj = stack[argB[pc]]
						local methodName = auxVal[pc]
						local curEnv = meta.env
						if type(obj) == "table" and obj ~= curEnv then
							local resolved = obj[methodName]
							if resolved ~= nil then
								if type(resolved) == "function" or type(resolved) == "table" then
									resolved = HOST_WRAPPERS[resolved] or resolved
								elseif type(resolved) == "userdata" and typeofFn(resolved) == "Instance" then
									resolved = resolveShadowedInstanceMethod(obj, methodName, resolved)
								end
								stack[a + 1] = obj
								stack[a] = resolved
							else
								stack[a + 1] = obj
								stack[a] = resolveNamecall(meta, obj, methodName)
							end
						else
							stack[a + 1] = obj
							stack[a] = resolveNamecall(meta, obj, methodName)
						end
					elseif op == VOP_GETTABLEKS_CALL then
						local tbl = stack[argB[pc]]
						local k = auxVal[pc]
						local curEnv = meta.env
						local val: unknown
						if tbl ~= curEnv then
							val = tbl[k]
						else
							val = if getGlobalHook ~= nil and type(k) == "string"
								then getGlobalHook(k, curEnv)
								else tbl[k]
							if val ~= nil and (type(val) == "function" or type(val) == "table") then
								val = HOST_WRAPPERS[val] or val
							end
						end
						stack[a] = val
					else -- VOP_GETIMPORT_CALL
						local v = if ctx.safeenv then pdata.kVals[argD[pc]] else nil
						if v ~= nil then
							stack[a] = v
						else
							stack[a] = resolveGetImportSlow(frame, ctx, pdata, pc)
						end
					end
					pc += 2
				end
				local fn = stack[a]
				local b = argB[pc]
				local nresults = argC[pc]
				if fn ~= nil and fn == curClosure and curFixed and b > 0 then
					local curDepth = tstate.depth
					local newDepth = curDepth + 1
					if newDepth >= 20000 + tstate.callLimitHeadroom then
						frame.pc = pc
						error("stack overflow", 0)
					end
					local newSlots = tstate.activeStackSlots + curMaxstack
					if newSlots > MAX_ACTIVE_STACK_SLOTS then
						frame.pc = pc
						error("call stack overflow", 0)
					end
					tstate.activeStackSlots = newSlots
					frame.pc = pc
					frame.returnPc = argD[pc]
					frame.callA = a
					frame.callNResults = nresults
					tstate.depth = newDepth
					local calleeFrame = frames[newDepth]
					local calleeStack
					if calleeFrame then
						calleeStack = calleeFrame.stack
						if calleeFrame.stackCap == 0 or calleeFrame.stackCap < curMaxstack then
							local stackCap = if curMaxstack <= 16
								then 16
								elseif curMaxstack <= 32 then 32
								else curMaxstack
							calleeStack = table.create(stackCap)
							calleeFrame.stack = calleeStack
							calleeFrame.stackCap = stackCap
						end
						calleeFrame.meta = meta
						calleeFrame.closure = fn
						calleeFrame.stackSlots = curMaxstack
						calleeFrame.top = curNumparams + 1
						calleeFrame.pc = 1
					else
						local stackCap = if curMaxstack <= 16 then 16 elseif curMaxstack <= 32 then 32 else curMaxstack
						calleeStack = table.create(stackCap)
						calleeFrame = {
							isCFrame = false,
							isPcall = false,
							cFunc = false,
							cName = false,
							meta = meta,
							closure = fn,
							stack = calleeStack,
							stackCap = stackCap,
							stackSlots = curMaxstack,
							varargs = EMPTY_VARARGS,
							varargsBuf = nil,
							varargsCap = 0,
							nvarargs = 0,
							top = curNumparams + 1,
							openUvRegs = nil,
							openUvObjs = nil,
							openUvCount = 0,
							hasOpenUpvals = false,
							pc = 1,
							returnPc = 1,
							callA = 1,
							callNResults = 0,
							lastLine = 0,
							savedPcallDepth = nil,
							savedXpcallDepth = nil,
							savedXpcallSnapshot = nil,
							savedXpcallInsertDepth = nil,
						} :: FrameState
						frames[newDepth] = calleeFrame
					end
					local callArgs = b - 1
					local copyParams = if callArgs < curNumparams then callArgs else curNumparams
					if copyParams == 1 then
						calleeStack[1] = stack[a + 1]
					elseif copyParams == 2 then
						calleeStack[1] = stack[a + 1]
						calleeStack[2] = stack[a + 2]
					elseif copyParams > 2 then
						for i = 1, copyParams do
							calleeStack[i] = stack[a + i]
						end
					end
					frame = calleeFrame
					stack = calleeStack
					pc = 1
					continue
				end
				local calleeMeta = if fn ~= nil then closureMeta[fn] else nil
				if calleeMeta ~= nil then
					local calleeCtx = calleeMeta.ctx
					if calleeCtx ~= ctx and calleeCtx.isGuarded then
						frame.pc = pc
						frame.returnPc = argD[pc]
						frame.callA = a
						frame.callNResults = nresults
						local callerDepth = tstate.depth
						pushCalleeFrame(tstate, frame, stack, a, b, fn, calleeMeta)
						getGuardedRunner()(tstate, callerDepth, true)
						frame = frames[callerDepth]
						stack = frame.stack
						pc = frame.pc
						continue
					end
					local calleeProto = calleeMeta.proto
					local curDepth = tstate.depth
					local newDepth = curDepth + 1
					if newDepth >= 20000 + tstate.callLimitHeadroom then
						frame.pc = pc
						error("stack overflow", 0)
					end
					local callArgs = if b == 0 then (frame.top - (a + 1)) else (b - 1)
					local numparams = calleeProto.numparams
					local nvarargs = if calleeProto.isvararg and callArgs > numparams then callArgs - numparams else 0
					local maxstack = calleeProto.maxstacksize
					local frameSlots = maxstack + nvarargs
					if tstate.activeStackSlots + frameSlots > MAX_ACTIVE_STACK_SLOTS then
						frame.pc = pc
						error(
							if nvarargs > 0 or frameSlots > 255
								then "too many results to unpack"
								else "call stack overflow",
							0
						)
					end
					tstate.activeStackSlots += frameSlots
					local calleePdata = calleeMeta.pdata
					if not calleePdata then
						calleePdata = getPredecoded(calleeCtx, calleeProto)
						calleeMeta.pdata = calleePdata
					end
					frame.pc = pc
					frame.returnPc = argD[pc]
					frame.callA = a
					frame.callNResults = nresults

					tstate.depth = newDepth
					local calleeFrame = frames[newDepth]
					local calleeStack
					if calleeFrame then
						calleeStack = calleeFrame.stack
						if calleeFrame.stackCap == 0 or calleeFrame.stackCap < maxstack then
							local stackCap = if maxstack <= 16 then 16 elseif maxstack <= 32 then 32 else maxstack
							calleeStack = table.create(stackCap)
							calleeFrame.stack = calleeStack
							calleeFrame.stackCap = stackCap
						end
						calleeFrame.meta = calleeMeta
						calleeFrame.closure = fn
						calleeFrame.stackSlots = frameSlots
						calleeFrame.top = numparams + 1
						calleeFrame.pc = 1
					else
						local stackCap = if maxstack <= 16 then 16 elseif maxstack <= 32 then 32 else maxstack
						calleeStack = table.create(stackCap)
						calleeFrame = {
							isCFrame = false,
							isPcall = false,
							cFunc = false,
							cName = false,
							meta = calleeMeta,
							closure = fn,
							stack = calleeStack,
							stackCap = stackCap,
							stackSlots = frameSlots,
							varargs = EMPTY_VARARGS,
							varargsBuf = nil,
							varargsCap = 0,
							nvarargs = 0,
							top = numparams + 1,
							openUvRegs = nil,
							openUvObjs = nil,
							openUvCount = 0,
							hasOpenUpvals = false,
							pc = 1,
							returnPc = 1,
							callA = 1,
							callNResults = 0,
							lastLine = 0,
							savedPcallDepth = nil,
							savedXpcallDepth = nil,
							savedXpcallSnapshot = nil,
							savedXpcallInsertDepth = nil,
						} :: FrameState
						frames[newDepth] = calleeFrame
					end
					local copyParams = if callArgs < numparams then callArgs else numparams
					if copyParams == 1 then
						calleeStack[1] = stack[a + 1]
					elseif copyParams == 2 then
						calleeStack[1] = stack[a + 1]
						calleeStack[2] = stack[a + 2]
					elseif copyParams > 2 then
						for i = 1, copyParams do
							calleeStack[i] = stack[a + i]
						end
					end
					if nvarargs > 0 then
						local vbuf = calleeFrame.varargsBuf
						if vbuf == nil or calleeFrame.varargsCap < nvarargs then
							local vcap = if nvarargs <= 8 then 8 else nvarargs
							vbuf = table.create(vcap)
							calleeFrame.varargsBuf = vbuf
							calleeFrame.varargsCap = vcap
						end
						for i = 1, nvarargs do
							(vbuf :: { [number]: any })[i] = stack[a + i + numparams]
						end
						calleeFrame.varargs = vbuf :: { [number]: any }
						calleeFrame.nvarargs = nvarargs
					end
					frame = calleeFrame
					stack = calleeStack
					curClosure = fn
					if calleeMeta ~= meta then
						meta = calleeMeta
						curProto = calleeProto
						curMaxstack = maxstack
						curNumparams = numparams
						curFixed = not calleeProto.isvararg
						if calleeCtx ~= ctx then
							ctx = calleeCtx
							getGlobalHook = ctx.getGlobal
							setGlobalHook = ctx.setGlobal
						end
						upvals = calleeMeta.upvals
						pdata = calleePdata :: PredecodedProto
						curHasOpenTop = pdata.hasOpenTop
						ops = pdata.ops
						argA = pdata.argA
						argB = pdata.argB
						argC = pdata.argC
						argD = pdata.argD
						auxVal = pdata.auxVal
						fcRa = pdata.fcRa
					end
					pc = 1
					continue
				elseif fn == hostPcall then
					local callArgs = if b == 0 then (frame.top - (a + 1)) else (b - 1)
					local argFn = if callArgs >= 1 then stack[a + 1] else nil
					if argFn ~= nil then
						argFn = HOST_WRAPPERS[argFn] or argFn
					end
					local argMeta = if type(argFn) == "function" then closureMeta[argFn] else nil
					if argMeta ~= nil then
						frame.pc = pc
						local calleeCtx = argMeta.ctx
						if calleeCtx.isGuarded then
							local callerDepth = tstate.depth
							pushInVmPcallFrame(tstate, frame, stack, a, callArgs, nresults, argD[pc], argFn, argMeta)
							getGuardedRunner()(tstate, callerDepth, true)
							frame = frames[callerDepth]
							stack = frame.stack
							pc = frame.pc
							continue
						end
						frame =
							pushInVmPcallFrame(tstate, frame, stack, a, callArgs, nresults, argD[pc], argFn, argMeta)
						stack = frame.stack
						curClosure = argFn
						if argMeta ~= meta then
							meta = argMeta
							curProto = meta.proto
							curMaxstack = curProto.maxstacksize
							curNumparams = curProto.numparams
							curFixed = not curProto.isvararg
							if calleeCtx ~= ctx then
								ctx = calleeCtx
								getGlobalHook = ctx.getGlobal
								setGlobalHook = ctx.setGlobal
							end
							upvals = argMeta.upvals
							pdata = meta.pdata :: PredecodedProto
							curHasOpenTop = pdata.hasOpenTop
							ops = pdata.ops
							argA = pdata.argA
							argB = pdata.argB
							argC = pdata.argC
							argD = pdata.argD
							auxVal = pdata.auxVal
							fcRa = pdata.fcRa
						end
						pc = 1
						continue
					end
				elseif
					(fn == vmError or fn == hostError)
					and tstate.pcallDepth > entryDepth
					and tstate.xpcallCaptureDepth == 0
				then
					local pcallDepth = tstate.pcallDepth
					local pcallCf = frames[pcallDepth]
					local realCaller = frames[pcallDepth - 1]
					local callArgs = if b == 0 then (frame.top - (a + 1)) else (b - 1)
					local rawLvl = if callArgs >= 2 then stack[a + 2] else 1
					if
						pcallCf ~= nil
						and pcallCf.isPcall
						and realCaller ~= nil
						and not realCaller.isCFrame
						and realCaller.meta ~= nil
						and not realCaller.meta.ctx.isGuarded
						and callArgs <= 2
						and (callArgs < 2 or rawLvl == nil or rawLvl == 0 or rawLvl == 1)
					then
						local msg = if callArgs >= 1 then stack[a + 1] else nil
						local formatted: any
						if (type(msg) ~= "string" and type(msg) ~= "number") or rawLvl == 0 then
							formatted = msg
						else
							local line = getLineForPc(curProto, pc)
							formatted = if line > 0
								then string.format("%s:%d: %s", ctx.shortSrc, line, tostring(msg))
								else tostring(msg)
						end
						frame.pc = pc
						unwindFrames(tstate, pcallDepth)
						local realStack = realCaller.stack
						local pA = pcallCf.callA
						local pNRes = pcallCf.callNResults
						if pNRes == 1 then
							realStack[pA] = false
						elseif pNRes == 2 then
							realStack[pA] = false
							realStack[pA + 1] = formatted
						elseif pNRes > 2 then
							realStack[pA] = false
							realStack[pA + 1] = formatted
							for i = 2, pNRes - 1 do
								realStack[pA + i] = nil
							end
						elseif pNRes < 0 then
							realStack[pA] = false
							realStack[pA + 1] = formatted
							realCaller.top = pA + 2
						end
						if pcallCf.savedXpcallDepth ~= nil then
							tstate.xpcallCaptureDepth = pcallCf.savedXpcallDepth
							tstate.xpcallSnapshot = pcallCf.savedXpcallSnapshot
							tstate.xpcallSnapshotInsertDepth = pcallCf.savedXpcallInsertDepth or 0
						end
						local retPc = pcallCf.returnPc
						popCFrame(tstate, pcallDepth - 1, pcallCf)
						realCaller.pc = retPc
						frame = realCaller
						stack = realStack
						curClosure = realCaller.closure
						local callerMeta = realCaller.meta
						if callerMeta ~= meta then
							meta = callerMeta
							curProto = meta.proto
							curMaxstack = curProto.maxstacksize
							curNumparams = curProto.numparams
							curFixed = not curProto.isvararg
							local callerCtx = meta.ctx
							if callerCtx ~= ctx then
								ctx = callerCtx
								getGlobalHook = ctx.getGlobal
								setGlobalHook = ctx.setGlobal
							end
							upvals = meta.upvals
							pdata = meta.pdata :: PredecodedProto
							curHasOpenTop = pdata.hasOpenTop
							ops = pdata.ops
							argA = pdata.argA
							argB = pdata.argB
							argC = pdata.argC
							argD = pdata.argD
							auxVal = pdata.auxVal
							fcRa = pdata.fcRa
						end
						pc = retPc
						continue
					end
				end
				frame.pc = pc
				execCall(tstate, frame, a, b, nresults)
				pc = argD[pc]
			elseif op == VOP_RETURN then
				if frame.hasOpenUpvals then
					closeUpvals(frame, 1)
				end
				local retB = argB[pc]
				local curDepth = tstate.depth
				if curDepth > entryDepth + 1 then
					local callerFrame = frames[curDepth - 1]
					if callerFrame.isPcall then
						frame = returnFromPcallFrame(tstate, frame, stack, a, retB, callerFrame)
						stack = frame.stack
						curClosure = frame.closure
						local callerMeta = frame.meta
						if callerMeta ~= meta then
							meta = callerMeta
							curProto = meta.proto
							curMaxstack = curProto.maxstacksize
							curNumparams = curProto.numparams
							curFixed = not curProto.isvararg
							local callerCtx = meta.ctx
							if callerCtx ~= ctx then
								ctx = callerCtx
								getGlobalHook = ctx.getGlobal
								setGlobalHook = ctx.setGlobal
							end
							upvals = meta.upvals
							pdata = meta.pdata :: PredecodedProto
							curHasOpenTop = pdata.hasOpenTop
							ops = pdata.ops
							argA = pdata.argA
							argB = pdata.argB
							argC = pdata.argC
							argD = pdata.argD
							auxVal = pdata.auxVal
							fcRa = pdata.fcRa
						end
						pc = frame.pc
						continue
					end
					local callNResults = callerFrame.callNResults
					if callNResults == 1 then
						local callerStack = callerFrame.stack
						local callA = callerFrame.callA
						if retB == 1 then
							callerStack[callA] = nil
						elseif retB == 0 then
							callerStack[callA] = if frame.top - a >= 1 then stack[a] else nil
						else
							callerStack[callA] = stack[a]
						end
					elseif callNResults ~= 0 then
						frame = popCalleeAndCopyReturns(tstate, frame, stack, a, retB)
						stack = frame.stack
						curClosure = frame.closure
						local callerMeta = frame.meta
						if callerMeta ~= meta then
							meta = callerMeta
							curProto = meta.proto
							curMaxstack = curProto.maxstacksize
							curNumparams = curProto.numparams
							curFixed = not curProto.isvararg
							local callerCtx = meta.ctx
							if callerCtx ~= ctx then
								ctx = callerCtx
								getGlobalHook = ctx.getGlobal
								setGlobalHook = ctx.setGlobal
							end
							upvals = meta.upvals
							pdata = meta.pdata :: PredecodedProto
							curHasOpenTop = pdata.hasOpenTop
							ops = pdata.ops
							argA = pdata.argA
							argB = pdata.argB
							argC = pdata.argC
							argD = pdata.argD
							auxVal = pdata.auxVal
							fcRa = pdata.fcRa
						end
						pc = frame.pc
						continue
					end
					if not curHasOpenTop and curMaxstack <= 8 then
						for r = 1, curMaxstack do
							stack[r] = nil
						end
					else
						table.clear(stack)
					end
					tstate.activeStackSlots -= frame.stackSlots
					frame.stackSlots = 0
					tstate.depth = curDepth - 1
					frame.meta = nil :: any
					frame.closure = nil
					local nva = frame.nvarargs
					if nva > 0 then
						local va = frame.varargs
						if va == frame.varargsBuf then
							for i = 1, nva do
								va[i] = nil
							end
						end
						frame.varargs = EMPTY_VARARGS
						frame.nvarargs = 0
					end
					frame = callerFrame
					stack = callerFrame.stack
					curClosure = callerFrame.closure
					local callerMeta = callerFrame.meta
					if callerMeta ~= meta then
						meta = callerMeta
						curProto = meta.proto
						curMaxstack = curProto.maxstacksize
						curNumparams = curProto.numparams
						curFixed = not curProto.isvararg
						local callerCtx = meta.ctx
						if callerCtx ~= ctx then
							ctx = callerCtx
							getGlobalHook = ctx.getGlobal
							setGlobalHook = ctx.setGlobal
						end
						upvals = meta.upvals
						pdata = meta.pdata :: PredecodedProto
						curHasOpenTop = pdata.hasOpenTop
						ops = pdata.ops
						argA = pdata.argA
						argB = pdata.argB
						argC = pdata.argC
						argD = pdata.argD
						auxVal = pdata.auxVal
						fcRa = pdata.fcRa
					end
					pc = callerFrame.returnPc
					continue
				end
				return unpackAndReleaseEntryFrame(tstate, frame, stack, a, retB)
			else -- VOP_ADD
				frame.pc = pc
				stack[a] = stack[argB[pc]] + stack[argC[pc]]
				pc += 1
			end
		elseif op <= 47 then
			if op <= 31 then
				if op <= 22 then
					if op <= 18 then
						frame.pc = pc
						if op == VOP_SUB then
							stack[a] = stack[argB[pc]] - stack[argC[pc]]
						elseif op == VOP_MUL then
							stack[a] = stack[argB[pc]] * stack[argC[pc]]
						else -- VOP_MOD
							stack[a] = stack[argB[pc]] % stack[argC[pc]]
						end
						pc += 1
					elseif op == VOP_JUMPIFNOT then
						if not stack[a] then
							pc = argD[pc]
						else
							pc += 1
						end
					elseif op == VOP_JUMPIF then
						if stack[a] then
							pc = argD[pc]
						else
							pc += 1
						end
					elseif op == VOP_JUMP then
						pc = argD[pc]
					else -- VOP_JUMPBACK
						pc = argD[pc]
					end
				elseif op <= 28 then
					frame.pc = pc
					local lhs = stack[a]
					local rhs = stack[argC[pc]]
					local taken: boolean
					if op <= 25 then
						if op == VOP_JUMPIFLT then
							taken = lhs < rhs
						elseif op == VOP_JUMPIFLE then
							taken = lhs <= rhs
						else -- VOP_JUMPIFEQ
							taken = lhs == rhs
						end
					else
						if op == VOP_JUMPIFNOTEQ then
							taken = lhs ~= rhs
						elseif op == VOP_JUMPIFNOTLE then
							taken = not (lhs <= rhs)
						else -- VOP_JUMPIFNOTLT
							taken = not (lhs < rhs)
						end
					end
					if taken then
						pc = argD[pc]
					else
						pc += 2
					end
				else
					if op == VOP_GETIMPORT then
						local v = if ctx.safeenv then pdata.kVals[argD[pc]] else nil
						if v ~= nil then
							stack[a] = v
						else
							frame.pc = pc
							stack[a] = resolveGetImportSlow(frame, ctx, pdata, pc)
						end
						pc += 2
					elseif op == VOP_GETTABLE then
						frame.pc = pc
						local tbl = stack[argB[pc]]
						local k = stack[argC[pc]]
						local curEnv = meta.env
						local val: unknown
						if tbl ~= curEnv then
							val = tbl[k]
						else
							val = if getGlobalHook ~= nil and type(k) == "string"
								then getGlobalHook(k, curEnv)
								else tbl[k]
							if val ~= nil and (type(val) == "function" or type(val) == "table") then
								val = HOST_WRAPPERS[val] or val
							end
						end
						stack[a] = val
						pc += 1
					else -- VOP_SETTABLE
						frame.pc = pc
						local tbl = stack[argB[pc]]
						local k = stack[argC[pc]]
						local val = stack[a]
						local curEnv = meta.env
						if tbl == curEnv then
							if SAFE_INVALIDATION_KEYS[k] ~= nil then
								invalidateEnvRoot(ctx, curEnv, k)
							end
							if
								not ctx.needsHostWrappers
								and (type(val) == "function" or type(val) == "table")
								and HOST_WRAPPERS[val] ~= nil
							then
								ctx.needsHostWrappers = true
							end
							if setGlobalHook ~= nil and type(k) == "string" then
								setGlobalHook(k, val, curEnv)
							else
								tbl[k] = val
							end
						else
							if type(k) == "string" and SAFE_INVALIDATION_KEYS[k] ~= nil and isTrackedEnv(tbl) then
								invalidateEnvRoot(nil, tbl, k)
							end
							tbl[k] = val
						end
						pc += 1
					end
				end
			elseif op <= 38 then
				if op <= 35 then
					if op == VOP_GETTABLEN then
						frame.pc = pc
						stack[a] = stack[argB[pc]][argC[pc]]
						pc += 1
					elseif op == VOP_SETTABLEN then
						frame.pc = pc
						stack[argB[pc]][argC[pc]] = stack[a]
						pc += 1
					elseif op == VOP_GETUPVAL then
						local uv = upvals[argB[pc]]
						stack[a] = uv[1][uv[2]]
						pc += 1
					else -- VOP_SETUPVAL
						local uv = upvals[argB[pc]]
						uv[1][uv[2]] = stack[a]
						pc += 1
					end
				else
					if op == VOP_GETGLOBAL then
						frame.pc = pc
						local key = auxVal[pc]
						local curEnv = meta.env
						if argC[pc] ~= 0 then
							invalidateEnvAll(ctx, curEnv)
						end
						local v = if getGlobalHook ~= nil then getGlobalHook(key, curEnv) else curEnv[key]
						if v ~= nil and (type(v) == "function" or type(v) == "table") then
							v = HOST_WRAPPERS[v] or v
						end
						stack[a] = v
						pc += 2
					elseif op == VOP_SETGLOBAL then
						frame.pc = pc
						local key = auxVal[pc]
						local val = stack[a]
						local curEnv = meta.env
						if argC[pc] ~= 0 then
							invalidateEnvRoot(ctx, curEnv, key)
						end
						if
							not ctx.needsHostWrappers
							and (type(val) == "function" or type(val) == "table")
							and HOST_WRAPPERS[val] ~= nil
						then
							ctx.needsHostWrappers = true
						end
						if setGlobalHook ~= nil then
							setGlobalHook(key, val, curEnv)
						else
							curEnv[key] = val
						end
						pc += 2
					else -- VOP_NAMECALL
						frame.pc = pc
						local obj = stack[argB[pc]]
						local methodName = auxVal[pc]
						stack[a + 1] = obj
						stack[a] = resolveNamecall(meta, obj, methodName)
						pc += 2
					end
				end
			elseif op <= 43 then
				if op <= VOP_FASTCALL2K then
					if ctx.safeenv and fcRa ~= nil then
						local ra = fcRa[pc]
						if ra ~= nil then
							if op == VOP_FASTCALL1 then
								local v1 = stack[argB[pc]]
								if a == LBF_MATH_ABS then
									if type(v1) == "number" then
										stack[ra] = math.abs(v1)
										pc = argD[pc]
										continue
									end
								elseif a == LBF_MATH_FLOOR then
									if type(v1) == "number" then
										stack[ra] = math.floor(v1)
										pc = argD[pc]
										continue
									end
								elseif a == LBF_MATH_CEIL then
									if type(v1) == "number" then
										stack[ra] = math.ceil(v1)
										pc = argD[pc]
										continue
									end
								elseif a == LBF_MATH_SQRT then
									if type(v1) == "number" then
										stack[ra] = math.sqrt(v1)
										pc = argD[pc]
										continue
									end
								elseif a == LBF_MATH_ROUND then
									if type(v1) == "number" then
										stack[ra] = math.round(v1)
										pc = argD[pc]
										continue
									end
								elseif a == LBF_MATH_SIN then
									if type(v1) == "number" then
										stack[ra] = math.sin(v1)
										pc = argD[pc]
										continue
									end
								elseif a == LBF_MATH_COS then
									if type(v1) == "number" then
										stack[ra] = math.cos(v1)
										pc = argD[pc]
										continue
									end
								elseif a == LBF_MATH_SIGN then
									if type(v1) == "number" then
										stack[ra] = math.sign(v1)
										pc = argD[pc]
										continue
									end
								elseif a == LBF_BIT32_BNOT then
									if type(v1) == "number" then
										stack[ra] = bit32.bnot(v1)
										pc = argD[pc]
										continue
									end
								elseif a == LBF_STRING_LEN then
									if type(v1) == "string" then
										stack[ra] = #v1
										pc = argD[pc]
										continue
									end
								elseif a == LBF_STRING_BYTE then
									if type(v1) == "string" then
										local res = string.byte(v1)
										if res ~= nil then
											stack[ra] = res
											pc = argD[pc]
											continue
										end
									end
								elseif a == LBF_TYPE then
									stack[ra] = type(v1)
									pc = argD[pc]
									continue
								elseif a == LBF_TYPEOF then
									stack[ra] = typeofFn(v1)
									pc = argD[pc]
									continue
								elseif a == LBF_SELECT_VARARG then
									if v1 == "#" or (type(v1) == "string" and string.byte(v1, 1) == 35) then
										stack[ra] = frame.nvarargs
										pc = argD[pc]
										continue
									elseif type(v1) == "number" then
										local idx = if v1 >= 0 then math.floor(v1) else math.ceil(v1)
										if idx >= 1 and idx <= frame.nvarargs then
											stack[ra] = frame.varargs[idx]
											pc = argD[pc]
											continue
										end
									end
								elseif a == LBF_GETMETATABLE then
									stack[ra] = if type(v1) == "string"
										then "The metatable is locked"
										else getmetatable(v1 :: any)
									pc = argD[pc]
									continue
								elseif a == LBF_TOSTRING then
									stack[ra] = tostring(v1)
									pc = argD[pc]
									continue
								elseif a == LBF_TONUMBER then
									stack[ra] = tonumber(v1)
									pc = argD[pc]
									continue
								elseif a == LBF_TABLE_CREATE then
									if type(v1) == "number" and v1 == v1 and v1 > -1 and v1 <= 65536 then
										stack[ra] = table.create(if v1 >= 0 then math.floor(v1) else 0)
										pc = argD[pc]
										continue
									end
								end
							else
								local v1 = stack[argB[pc]]
								local v2 = if op == VOP_FASTCALL2 then stack[argC[pc]] else auxVal[pc]
								if ra == 0 then
									if a == LBF_TABLE_INSERT then
										if
											type(v1) == "table"
											and not table.isfrozen(v1)
											and getmetatable(v1 :: any) == nil
										then
											table.insert(v1, v2)
											pc = argD[pc]
											continue
										end
									elseif a == LBF_SETMETATABLE then
										if
											type(v1) == "table"
											and not table.isfrozen(v1)
											and (v2 == nil or type(v2) == "table")
										then
											local cur = getmetatable(v1 :: any)
											if
												cur == nil
												or (type(cur) == "table" and rawget(cur, "__metatable") == nil)
											then
												local curEnv = meta.env
												if v1 == curEnv or v1 == ctx.env or isTrackedEnv(v1) then
													invalidateEnvAll(
														if v1 == curEnv or v1 == ctx.env then ctx else nil,
														v1 :: any
													)
												end
												setmetatable(v1 :: any, v2 :: any)
												if v2 ~= nil and rawget(v2, "__metatable") ~= nil then
													recordLockedMetatable(v1, v2)
												elseif v2 == nil and cur ~= nil then
													recordLockedMetatable(v1, nil)
												end
												pc = argD[pc]
												continue
											end
										end
									end
								elseif a == LBF_STRING_BYTE then
									if type(v1) == "string" and type(v2) == "number" then
										local res = string.byte(v1, v2)
										if res ~= nil then
											stack[ra] = res
											pc = argD[pc]
											continue
										end
									end
								elseif a == LBF_STRING_SUB then
									if type(v1) == "string" and type(v2) == "number" then
										stack[ra] = string.sub(v1, v2)
										pc = argD[pc]
										continue
									end
								elseif a == LBF_RAWEQUAL then
									stack[ra] = rawequal(v1, v2)
									pc = argD[pc]
									continue
								elseif a == LBF_TABLE_CREATE then
									if type(v1) == "number" and v1 == v1 and v1 > -1 and v1 <= 65536 then
										stack[ra] = table.create((if v1 >= 0 then math.floor(v1) else 0), v2)
										pc = argD[pc]
										continue
									end
								elseif a == LBF_SETMETATABLE then
									if
										type(v1) == "table"
										and not table.isfrozen(v1)
										and (v2 == nil or type(v2) == "table")
									then
										local cur = getmetatable(v1 :: any)
										if
											cur == nil or (type(cur) == "table" and rawget(cur, "__metatable") == nil)
										then
											local curEnv = meta.env
											if v1 == curEnv or v1 == ctx.env or isTrackedEnv(v1) then
												invalidateEnvAll(
													if v1 == curEnv or v1 == ctx.env then ctx else nil,
													v1 :: any
												)
											end
											local res = setmetatable(v1 :: any, v2 :: any)
											if v2 ~= nil and rawget(v2, "__metatable") ~= nil then
												recordLockedMetatable(v1, v2)
											elseif v2 == nil and cur ~= nil then
												recordLockedMetatable(v1, nil)
											end
											stack[ra] = res
											pc = argD[pc]
											continue
										end
									end
								elseif type(v1) == "number" and type(v2) == "number" then
									if a == LBF_BIT32_BXOR then
										stack[ra] = bit32.bxor(v1, v2)
										pc = argD[pc]
										continue
									elseif a == LBF_BIT32_BAND then
										stack[ra] = bit32.band(v1, v2)
										pc = argD[pc]
										continue
									elseif a == LBF_BIT32_BOR then
										stack[ra] = bit32.bor(v1, v2)
										pc = argD[pc]
										continue
									elseif a == LBF_BIT32_LSHIFT then
										stack[ra] = bit32.lshift(v1, v2)
										pc = argD[pc]
										continue
									elseif a == LBF_BIT32_RSHIFT then
										stack[ra] = bit32.rshift(v1, v2)
										pc = argD[pc]
										continue
									elseif a == LBF_BIT32_BTEST then
										stack[ra] = bit32.btest(v1, v2)
										pc = argD[pc]
										continue
									elseif a == LBF_MATH_MIN then
										stack[ra] = math.min(v1, v2)
										pc = argD[pc]
										continue
									elseif a == LBF_MATH_MAX then
										stack[ra] = math.max(v1, v2)
										pc = argD[pc]
										continue
									end
								end
							end
						end
					end
					frame.pc = pc
					pc = execFastcallOp(frame, pc, op)
				elseif op == VOP_FASTCALL3 then
					if ctx.safeenv and fcRa ~= nil then
						local ra = fcRa[pc]
						if ra ~= nil then
							local v1 = stack[argB[pc]]
							local v2 = stack[argC[pc]]
							local v3 = stack[argB[pc + 1]]
							if a == LBF_STRING_SUB then
								if type(v1) == "string" and type(v2) == "number" and type(v3) == "number" then
									stack[ra] = string.sub(v1, v2, v3)
									pc = argD[pc]
									continue
								end
							elseif a == LBF_MATH_CLAMP then
								if
									type(v1) == "number"
									and type(v2) == "number"
									and type(v3) == "number"
									and v2 <= v3
								then
									stack[ra] = math.clamp(v1, v2, v3)
									pc = argD[pc]
									continue
								end
							end
						end
					end
					frame.pc = pc
					pc = execFastcallOp(frame, pc, op)
				else -- VOP_FASTCALL
					frame.pc = pc
					pc = execFastcallOp(frame, pc, op)
				end
			else
				if op == VOP_NEWCLOSURE then
					frame.pc = pc
					pc = spawnChildClosure(frame, pc, a, argD[pc], false)
				elseif op == VOP_DUPCLOSURE then
					frame.pc = pc
					pc = spawnChildClosure(frame, pc, a, argD[pc], true)
				elseif op == VOP_CLOSEUPVALS then
					if frame.hasOpenUpvals then
						closeUpvals(frame, a)
					end
					pc += 1
				else -- VOP_FORGLOOP
					frame.pc = pc
					local gen = stack[a]
					local nvars = argC[pc]
					local targetPc = argD[pc]
					local tbl = stack[a + 1]
					if gen == inext and nvars <= 2 and type(tbl) == "table" then
						local nextIdx = (stack[a + 2] or 0) + 1
						local v2 = rawget(tbl, nextIdx)
						if v2 ~= nil then
							stack[a + 3] = nextIdx
							if nvars == 2 then
								stack[a + 4] = v2
							end
							stack[a + 2] = nextIdx
							pc = targetPc
						else
							stack[a + 3] = nil
							pc += 2
						end
					elseif (gen == hostNext or gen == vmNext) and nvars <= 2 and type(tbl) == "table" then
						local k1, v2 = hostNext(tbl, stack[a + 2])
						if k1 ~= nil then
							if type(k1) == "function" or type(k1) == "table" then
								k1 = HOST_WRAPPERS[k1] or k1
							end
							stack[a + 3] = k1
							if nvars == 2 then
								if v2 ~= nil and (type(v2) == "function" or type(v2) == "table") then
									v2 = HOST_WRAPPERS[v2] or v2
								end
								stack[a + 4] = v2
							end
							stack[a + 2] = k1
							pc = targetPc
						else
							stack[a + 3] = nil
							pc += 2
						end
					else
						pc = execForGLoopSlow(frame, pc, a, nvars, targetPc)
					end
				end
			end
		else
			if op <= 65 then
				if op <= 55 then
					if op == VOP_DUPTABLE then
						stack[a] = table.clone(auxVal[pc])
						pc += 1
					elseif op == VOP_NEWTABLE then
						local alloc = argD[pc]
						local bRaw = argB[pc] - 1
						if alloc > 0 then
							stack[a] = table.create(alloc)
						elseif bRaw > 0 then
							stack[a] = cloneDuptableSeed(bit32.lshift(1, bRaw - 1))
						else
							stack[a] = {}
						end
						pc += 2
					elseif op == VOP_SETLIST then
						frame.pc = pc
						local bBase = argB[pc]
						local cRaw = argC[pc]
						local aux = argD[pc]
						local cnt = if cRaw == 0 then (frame.top - bBase) else (cRaw - 1)
						local tbl = stack[a]
						for i = 0, cnt - 1 do
							tbl[aux + i] = stack[bBase + i]
						end
						pc += 2
					elseif op == VOP_FORNPREP then
						frame.pc = pc
						pc = execForNPrep(frame, pc, a, argD[pc])
					elseif op == VOP_FORGPREP then
						frame.pc = pc
						pc = execForGPrep(frame, op, a, argD[pc])
					elseif op == VOP_FASTPCALL then
						if a == 0 and bit32.btest(ctx.safeRootsMask, ROOT_BIT_PCALL) then
							local ra = auxVal[pc]
							local callB = argB[pc]
							local callNresults = argC[pc]
							local afterCallPc = argD[pc]
							local callArgs = if callB == 0 then (frame.top - (ra + 1)) else (callB - 1)
							local argFn = if callArgs >= 1 then stack[ra + 1] else nil
							if argFn ~= nil then
								argFn = HOST_WRAPPERS[argFn] or argFn
							end
							local argMeta = if type(argFn) == "function" then closureMeta[argFn] else nil
							if argMeta ~= nil then
								frame.pc = pc
								local calleeCtx = argMeta.ctx
								if calleeCtx.isGuarded then
									local callerDepth = tstate.depth
									pushInVmPcallFrame(
										tstate,
										frame,
										stack,
										ra,
										callArgs,
										callNresults,
										afterCallPc,
										argFn,
										argMeta
									)
									getGuardedRunner()(tstate, callerDepth, true)
									frame = frames[callerDepth]
									stack = frame.stack
									pc = frame.pc
									continue
								end
								frame = pushInVmPcallFrame(
									tstate,
									frame,
									stack,
									ra,
									callArgs,
									callNresults,
									afterCallPc,
									argFn,
									argMeta
								)
								stack = frame.stack
								curClosure = argFn
								if argMeta ~= meta then
									meta = argMeta
									curProto = meta.proto
									curMaxstack = curProto.maxstacksize
									curNumparams = curProto.numparams
									curFixed = not curProto.isvararg
									if calleeCtx ~= ctx then
										ctx = calleeCtx
										getGlobalHook = ctx.getGlobal
										setGlobalHook = ctx.setGlobal
									end
									upvals = argMeta.upvals
									pdata = meta.pdata :: PredecodedProto
									curHasOpenTop = pdata.hasOpenTop
									ops = pdata.ops
									argA = pdata.argA
									argB = pdata.argB
									argC = pdata.argC
									argD = pdata.argD
									auxVal = pdata.auxVal
									fcRa = pdata.fcRa
								end
								pc = 1
								continue
							end
						end
						pc += 1
					elseif op == VOP_LOADNIL then
						stack[a] = nil
						pc += 1
					else -- VOP_LOADB
						stack[a] = argB[pc] ~= 0
						pc = argC[pc]
					end
				elseif op <= 61 then
					frame.pc = pc
					if op == VOP_DIV then
						stack[a] = stack[argB[pc]] / stack[argC[pc]]
					elseif op == VOP_IDIV then
						stack[a] = stack[argB[pc]] // stack[argC[pc]]
					elseif op == VOP_DIVK then
						stack[a] = stack[argB[pc]] / auxVal[pc]
					elseif op == VOP_IDIVK then
						stack[a] = stack[argB[pc]] // auxVal[pc]
					elseif op == VOP_POW then
						stack[a] = stack[argB[pc]] ^ stack[argC[pc]]
					else -- VOP_POWK
						local lhs = stack[argB[pc]]
						local rhs = auxVal[pc]
						stack[a] = if rhs == 0.5 and type(lhs) == "number" then math.sqrt(lhs) else lhs ^ rhs
					end
					pc += 1
				else
					if op == VOP_AND then
						stack[a] = stack[argB[pc]] and stack[argC[pc]]
					elseif op == VOP_OR then
						stack[a] = stack[argB[pc]] or stack[argC[pc]]
					elseif op == VOP_ANDK then
						stack[a] = stack[argB[pc]] and auxVal[pc]
					else -- VOP_ORK
						stack[a] = stack[argB[pc]] or auxVal[pc]
					end
					pc += 1
				end
			elseif op <= 74 then
				if op <= 70 then
					if op == VOP_NOT then
						stack[a] = not stack[argB[pc]]
						pc += 1
					elseif op == VOP_MINUS then
						frame.pc = pc
						stack[a] = -stack[argB[pc]]
						pc += 1
					elseif op == VOP_LENGTH then
						frame.pc = pc
						stack[a] = #stack[argB[pc]]
						pc += 1
					elseif op == VOP_CONCAT then
						frame.pc = pc
						local b = argB[pc]
						local c = argC[pc]
						if c == b + 1 then
							stack[a] = stack[b] .. stack[c]
						else
							execConcat(stack, a, b, c, nil)
						end
						pc += 1
					else -- VOP_PREPVARARGS
						pc += 1
					end
				else
					frame.pc = pc
					local taken: boolean
					local notFlag = argC[pc] ~= 0
					if op == VOP_JUMPXEQKNIL then
						taken = (stack[a] == nil) ~= notFlag
					else
						taken = (stack[a] == auxVal[pc]) ~= notFlag
					end
					if taken then
						pc = argD[pc]
					else
						pc += 2
					end
				end
			elseif op == VOP_GETVARARGS then
				local b = argB[pc]
				local nvarargs = frame.nvarargs
				local varargs = frame.varargs
				local cnt = if b == 0 then nvarargs else (b - 1)
				for i = 1, cnt do
					stack[a + i - 1] = varargs[i]
				end
				if b == 0 then
					frame.top = a + nvarargs
				end
				pc += 1
			else
				frame.pc = pc
				pc = stepColdOpcode(frame, pc, op, a)
			end
		end
	end
end

local function runLoop(tstate: ThreadState, entryDepth: number, resumed: boolean?): ...any
	local topFrame = tstate.frames[tstate.depth]
	if not topFrame.meta.ctx.isGuarded then
		return runLoopFast(tstate, entryDepth)
	end
	return getGuardedRunner()(tstate, entryDepth, nil, resumed)
end

unwindFrames = function(tstate: ThreadState, targetDepth: number, co: thread?)
	while tstate.depth > targetDepth do
		local f = tstate.frames[tstate.depth]
		if not f.isCFrame and f.hasOpenUpvals then
			closeUpvals(f, 1)
		end
		releaseTopFrame(tstate, f, f.stack, co)
	end
end

local function pushEntryFrame(tstate: ThreadState, meta: ClosureMeta, closure: (...any) -> ...any, ...: any): FrameState
	local ctx = meta.ctx
	local proto = meta.proto
	if not meta.pdata then
		meta.pdata = getPredecoded(ctx, proto)
	end

	local nargs = select("#", ...)
	local numparams = proto.numparams
	local newDepth = tstate.depth + 1
	local stack, stackCap = acquireDepthStack(tstate, newDepth, proto.maxstacksize)
	local varargs: { [number]: any } = EMPTY_VARARGS
	local vcap = 0
	local nvarargs = 0

	if nargs > 0 then
		if nargs <= 4 and not (proto.isvararg and nargs > numparams) then
			local a1, a2, a3, a4 = ...
			local n = if nargs < numparams then nargs else numparams
			if n >= 1 then
				stack[1] = a1
			end
			if n >= 2 then
				stack[2] = a2
			end
			if n >= 3 then
				stack[3] = a3
			end
			if n >= 4 then
				stack[4] = a4
			end
		elseif nargs <= 4 then
			local a1, a2, a3, a4 = ...
			if numparams >= 1 then
				stack[1] = a1
			end
			if numparams >= 2 then
				stack[2] = a2
			end
			if numparams >= 3 then
				stack[3] = a3
			end
			nvarargs = nargs - numparams
			varargs, vcap = acquireVarargsBuf(tstate.frames[newDepth], nvarargs)
			if numparams == 0 then
				varargs[1], varargs[2], varargs[3], varargs[4] = a1, a2, a3, a4
			elseif numparams == 1 then
				varargs[1], varargs[2], varargs[3] = a2, a3, a4
			elseif numparams == 2 then
				varargs[1], varargs[2] = a3, a4
			else
				varargs[1] = a4
			end
		else
			local packed = table.pack(...)
			local n = if nargs < numparams then nargs else numparams
			for i = 1, n do
				stack[i] = packed[i]
			end
			if proto.isvararg and nargs > numparams then
				nvarargs = nargs - numparams
				varargs, vcap = acquireVarargsBuf(tstate.frames[newDepth], nvarargs)
				table.move(packed, numparams + 1, nargs, 1, varargs)
			end
		end
	end

	return initFrame(tstate, meta, closure, stack, stackCap, varargs, vcap, nvarargs, numparams)
end

local function appendSnapshotFrame(out: { SnapshotFrame }, f: FrameState?)
	if f == nil then
		return
	end
	if f.isCFrame then
		local cName = if type(f.cName) == "string" then f.cName else resolveHostFuncName(f.cFunc)
		out[#out + 1] = {
			shortSrc = "[C]",
			line = -1,
			dname = cName,
			proto = {
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
				debugname = cName,
			},
			closure = f.cFunc,
			isCFrame = true,
		}
	elseif f.meta then
		local fmeta = f.meta
		out[#out + 1] = {
			shortSrc = fmeta.ctx.shortSrc,
			line = getLineForPc(fmeta.proto, f.pc),
			dname = fmeta.proto.debugname,
			proto = fmeta.proto,
			closure = f.closure,
			isCFrame = false,
		}
	end
end

local function captureXpcallSnapshot(tstate: ThreadState, entryDepth: number)
	if tstate.depth <= entryDepth then
		return
	end
	local existing = tstate.xpcallSnapshot
	if existing ~= nil then
		local prevIns = tstate.xpcallSnapshotInsertDepth
		if entryDepth >= prevIns then
			return
		end
		local upper = if tstate.depth < prevIns then tstate.depth else prevIns
		local merged: { SnapshotFrame } = {}
		for i = entryDepth + 1, upper do
			appendSnapshotFrame(merged, tstate.frames[i])
		end
		for _, sf in existing do
			merged[#merged + 1] = sf
		end
		tstate.xpcallSnapshot = merged
		tstate.xpcallSnapshotInsertDepth = entryDepth
		return
	end
	local snap: { SnapshotFrame } = {}
	for i = entryDepth + 1, tstate.depth do
		appendSnapshotFrame(snap, tstate.frames[i])
	end
	tstate.xpcallSnapshot = snap
	tstate.xpcallSnapshotInsertDepth = entryDepth
end

local function tryRecoverInVmPcall(tstate: ThreadState, entryDepth: number, err: unknown): boolean
	local frames = tstate.frames
	local pcallDepth = 0
	for d = tstate.depth, entryDepth + 1, -1 do
		if frames[d].isPcall then
			pcallDepth = d
			break
		end
	end
	if pcallDepth == 0 then
		return false
	end
	local topLua = findNearestLuaFrame(tstate)
	local callerFrame = frames[pcallDepth - 1]
	local callerCtx = if callerFrame ~= nil
			and not callerFrame.isCFrame
			and callerFrame.meta ~= nil
		then callerFrame.meta.ctx
		else nil
	if topLua ~= nil then
		local topCtx = topLua.meta.ctx
		if
			isBudgetAborted(topCtx, err)
			and (callerCtx == nil or callerCtx == topCtx or isBudgetAborted(callerCtx, err))
		then
			return false
		end
	elseif callerCtx ~= nil and isBudgetAborted(callerCtx, err) then
		return false
	end
	local formatted = if topLua then formatVmError(topLua, err, false) else err
	unwindFrames(tstate, pcallDepth)
	local pcallCf = frames[pcallDepth]
	local realCaller = frames[pcallDepth - 1]
	local realStack = realCaller.stack
	local pA = pcallCf.callA
	local pNRes = pcallCf.callNResults
	if pNRes == 1 then
		realStack[pA] = false
	elseif pNRes == 2 then
		realStack[pA] = false
		realStack[pA + 1] = formatted
	elseif pNRes > 2 then
		realStack[pA] = false
		realStack[pA + 1] = formatted
		for i = 2, pNRes - 1 do
			realStack[pA + i] = nil
		end
	elseif pNRes < 0 then
		realStack[pA] = false
		realStack[pA + 1] = formatted
		realCaller.top = pA + 2
	end
	if pcallCf.savedXpcallDepth ~= nil then
		tstate.xpcallCaptureDepth = pcallCf.savedXpcallDepth
		tstate.xpcallSnapshot = pcallCf.savedXpcallSnapshot
		tstate.xpcallSnapshotInsertDepth = pcallCf.savedXpcallInsertDepth or 0
	end
	local retPc = pcallCf.returnPc
	popCFrame(tstate, pcallDepth - 1, pcallCf)
	realCaller.pc = retPc
	clearErrorState()
	return true
end

local function invokeClosure(meta: ClosureMeta, closure: (...any) -> ...any, ...: any): ...any
	local tstate = getThreadState()
	local entryDepth = tstate.depth
	local ctx = meta.ctx
	if ctx.interrupted then
		if entryDepth >= 1 then
			error(formatVmError(tstate.frames[entryDepth], "execution interrupted", false), 0)
		end
		error(string.format("%s:%d: execution interrupted", ctx.shortSrc, meta.proto.linedefined or 0), 0)
	end
	if ctx.timeout ~= nil and (os.clock() - ensureTimeoutClock(ctx)) > ctx.timeout then
		if entryDepth >= 1 then
			error(formatVmError(tstate.frames[entryDepth], "execution timeout exceeded", false), 0)
		end
		error(string.format("%s:%d: execution timeout exceeded", ctx.shortSrc, meta.proto.linedefined or 0), 0)
	end
	local newDepth = entryDepth + 1
	local limitBound = ctx.effectiveCallLimit + tstate.callLimitHeadroom
	if
		if ctx.callLimit ~= nil
			then ((entryDepth >= 1 and newDepth > limitBound) or getActiveCalls(ctx) >= limitBound)
			else (entryDepth >= 1 and newDepth >= limitBound)
	then
		local ovMsg = stackOverflowMsg(ctx)
		if entryDepth >= 1 then
			error(formatVmError(tstate.frames[entryDepth], ovMsg, false), 0)
		end
		error(string.format("%s:%d: %s", ctx.shortSrc, meta.proto.linedefined or 0, ovMsg), 0)
	end
	pushEntryFrame(tstate, meta, closure, ...)
	local resumed = false
	while true do
		local ok, r1, r2, r3, r4 = pcall(runLoop, tstate, entryDepth, resumed)
		if ok then
			local nret = tstate.entryRetCount
			if nret == 0 then
				return
			elseif nret == 1 then
				return r1
			elseif nret == 2 then
				return r1, r2
			elseif nret == 3 then
				return r1, r2, r3
			elseif nret == 4 then
				return r1, r2, r3, r4
			else
				return table.unpack(tstate.entryRets, 1, nret)
			end
		end
		if not tryRecoverInVmPcall(tstate, entryDepth, r1) then
			local topLua = findNearestLuaFrame(tstate)
			local formatted = if topLua then formatVmError(topLua, r1, entryDepth > 0) else r1
			if tstate.xpcallCaptureDepth > 0 then
				captureXpcallSnapshot(tstate, entryDepth)
			end
			if entryDepth == 0 and tstate.depth > 0 then
				recordDeadSnapshot(coroutine.running(), tstate)
			end
			unwindFrames(tstate, entryDepth)
			error(formatted, 0)
		end
		resumed = true
	end
end

local function computeErrorHeadroom(limit: number): number
	if limit < math.huge then
		return math.max(16, math.floor(limit / 8))
	end
	return 16
end

local function vmXpcall(fn: any, errHandler: any, ...: any): (boolean, ...any)
	if type(errHandler) ~= "function" then
		if errHandler == nil and select("#", ...) == 0 then
			hostError("missing argument #2 to 'xpcall' (function expected)", 2)
		end
		hostError("invalid argument #2 to 'xpcall' (function expected, got " .. typeofFn(errHandler) .. ")", 2)
	end
	errHandler = HOST_WRAPPERS[errHandler] or errHandler
	local meta = if fn ~= nil then closureMeta[fn] else nil
	if not meta then
		local co = coroutine.running()
		local tstate = getActiveThreadState(co)
		local topLua = if tstate then findNearestLuaFrame(tstate) else nil
		if tstate and topLua ~= nil then
			local topMeta = topLua.meta
			local topCtx = topMeta.ctx
			if fn ~= nil then
				fn = HOST_WRAPPERS[fn] or fn
			end
			local wr = topCtx.resourceLimitWrappers
			if wr ~= nil then
				if fn ~= nil then
					fn = wr[fn] or fn
				end
				errHandler = wr[errHandler] or errHandler
			end
			meta = if fn ~= nil then closureMeta[fn] else nil
			if meta == nil then
				local prevSnapshot = tstate.xpcallSnapshot
				local prevInsertDepth = tstate.xpcallSnapshotInsertDepth
				tstate.xpcallSnapshot = nil
				tstate.xpcallSnapshotInsertDepth = 0
				tstate.xpcallCaptureDepth += 1
				local headroom = computeErrorHeadroom(topCtx.effectiveCallLimit)
				local abortedErr: unknown = nil
				local wrappedHandler = function(rawErr: any)
					if isBudgetAborted(topCtx, rawErr) then
						abortedErr = rawErr
						return rawErr
					end
					local activeTop = findNearestLuaFrame(tstate)
					local formatted = if activeTop then formatVmError(activeTop, rawErr, false) else rawErr
					local prevHeadroom = tstate.callLimitHeadroom
					if headroom > prevHeadroom then
						tstate.callLimitHeadroom = headroom
					end
					local hOk, hRes = pcall(errHandler, formatted)
					tstate.callLimitHeadroom = prevHeadroom
					return if hOk then hRes else "error in error handling"
				end
				local savedDepth = tstate.depth
				local results: { [any]: any }
				if type(fn) == "function" then
					local innerCf = pushCFrame(tstate, fn, nil)
					results = table.pack(hostXpcall(fn, wrappedHandler, ...))
					popCFrame(tstate, savedDepth, innerCf)
				else
					results = table.pack(hostXpcall(fn, wrappedHandler, ...))
				end
				tstate.xpcallCaptureDepth -= 1
				tstate.xpcallSnapshot = prevSnapshot
				tstate.xpcallSnapshotInsertDepth = prevInsertDepth
				clearErrorState()
				if abortedErr ~= nil then
					error(abortedErr, 0)
				end
				return table.unpack(results, 1, results.n)
			end
		else
			return hostXpcall(fn, errHandler, ...)
		end
	end

	local tstate = getThreadState()
	local entryDepth = tstate.depth
	local callerFrame = if entryDepth >= 1 then tstate.frames[entryDepth] else nil
	local callerCtx = if callerFrame ~= nil
			and not callerFrame.isCFrame
			and callerFrame.meta ~= nil
		then callerFrame.meta.ctx
		else nil
	local ctx = (meta :: ClosureMeta).ctx
	do
		local wr = ctx.resourceLimitWrappers or (if callerCtx ~= nil then callerCtx.resourceLimitWrappers else nil)
		if wr ~= nil then
			errHandler = wr[errHandler] or errHandler
		end
	end
	if ctx.interrupted then
		error("execution interrupted", 0)
	end
	if ctx.timeout ~= nil and (os.clock() - ensureTimeoutClock(ctx)) > ctx.timeout then
		error("execution timeout exceeded", 0)
	end
	local limitBound = ctx.effectiveCallLimit + tstate.callLimitHeadroom
	local headroom = computeErrorHeadroom(ctx.effectiveCallLimit)
	if
		if ctx.callLimit ~= nil
			then ((entryDepth >= 1 and entryDepth + 1 > limitBound) or getActiveCalls(ctx) >= limitBound)
			else (entryDepth >= 1 and entryDepth + 1 >= limitBound)
	then
		local topLua = findNearestLuaFrame(tstate, entryDepth)
		local ovMsg = stackOverflowMsg(ctx)
		local formatted = if topLua ~= nil
			then formatVmError(topLua, ovMsg, false)
			else string.format("%s:%d: %s", ctx.shortSrc, (meta :: ClosureMeta).proto.linedefined or 0, ovMsg)
		local prevHeadroom = tstate.callLimitHeadroom
		if headroom > prevHeadroom then
			tstate.callLimitHeadroom = headroom
		end
		local hOk, hRes = pcall(errHandler, formatted)
		tstate.callLimitHeadroom = prevHeadroom
		clearErrorState()
		return false, if hOk then hRes else "error in error handling"
	end

	local prevSnapshot = tstate.xpcallSnapshot
	local prevInsertDepth = tstate.xpcallSnapshotInsertDepth
	tstate.xpcallSnapshot = nil
	tstate.xpcallSnapshotInsertDepth = 0
	tstate.xpcallCaptureDepth += 1
	pushEntryFrame(tstate, meta :: ClosureMeta, fn, ...)
	local abortedErr: unknown = nil
	local results = table.pack(xpcall(function(): ...unknown
		local resumed = false
		while true do
			local ok, r1, r2, r3, r4 = pcall(runLoop, tstate, entryDepth, resumed)
			if ok then
				local nret = tstate.entryRetCount
				if nret == 0 then
					return
				elseif nret == 1 then
					return r1
				elseif nret == 2 then
					return r1, r2
				elseif nret == 3 then
					return r1, r2, r3
				elseif nret == 4 then
					return r1, r2, r3, r4
				else
					return table.unpack(tstate.entryRets, 1, nret)
				end
			end
			if not tryRecoverInVmPcall(tstate, entryDepth, r1) then
				error(r1, 0)
			end
			resumed = true
		end
	end, function(rawErr: any)
		if
			isBudgetAborted(ctx, rawErr)
			and (callerCtx == nil or callerCtx == ctx or isBudgetAborted(callerCtx, rawErr))
		then
			abortedErr = if ctx.interrupted
				then "execution interrupted"
				elseif ctx.insnLimit ~= nil and ctx.insnCount > ctx.insnLimit then "instruction limit exceeded"
				elseif
					ctx.timeout ~= nil and (os.clock() - ensureTimeoutClock(ctx)) > ctx.timeout
				then "execution timeout exceeded"
				else rawErr
			return abortedErr
		end
		local activeTop = findNearestLuaFrame(tstate)
		local formatted = if activeTop then formatVmError(activeTop, rawErr, false) else rawErr
		local prevHeadroom = tstate.callLimitHeadroom
		if headroom > prevHeadroom then
			tstate.callLimitHeadroom = headroom
		end
		local hOk, hRes = pcall(errHandler, formatted)
		tstate.callLimitHeadroom = prevHeadroom
		return if hOk then hRes else "error in error handling"
	end))
	tstate.xpcallCaptureDepth -= 1
	tstate.xpcallSnapshot = prevSnapshot
	tstate.xpcallSnapshotInsertDepth = prevInsertDepth
	clearErrorState()
	if abortedErr ~= nil then
		unwindFrames(tstate, entryDepth)
		error(abortedErr, 0)
	end
	if not results[1] then
		unwindFrames(tstate, entryDepth)
		return false, results[2]
	end
	return true, table.unpack(results, 2, results.n)
end

RuntimeEnv.registerXpcall(vmXpcall)
RuntimeEnv.registerUnwindFrames(unwindFrames)

instantiateClosure = function(
	ctx: ModuleContext,
	proto: Proto,
	upvals: { Upval },
	env: { [any]: any }
): (...any) -> ...any
	local meta: ClosureMeta = {
		ctx = ctx,
		proto = proto,
		pdata = ctx.predecoded[proto.id + 1] or getPredecoded(ctx, proto),
		upvals = upvals,
		env = env,
	}
	local fn: (...any) -> ...any
	fn = function(...: any): ...any
		return invokeClosure(meta, fn, ...)
	end
	closureMeta[fn] = meta
	return fn
end

local function cloneFunction(
	fn: (...any) -> ...any,
	newEnv: { [any]: any }?,
	loadOpts: LoadOptions?
): ((...any) -> ...any)?
	if newEnv ~= nil and type(newEnv) ~= "table" then
		hostError("cloneFunction newEnv must be a table", 2)
	end
	if loadOpts ~= nil then
		if type(loadOpts) ~= "table" then
			hostError("cloneFunction loadOptions must be a table", 2)
		end
		validateLoadOptions(loadOpts, 2)
	end
	if type(fn) ~= "function" then
		return nil
	end
	local meta = closureMeta[fn]
	if not meta then
		return nil
	end
	local origCtx = meta.ctx
	local upvals = if #meta.upvals == 0 then EMPTY_UPVALS else table.clone(meta.upvals)
	if
		newEnv == nil
		and loadOpts == nil
		and not origCtx.hasLimits
		and not origCtx.hasResourceLimits
		and origCtx.callLimit == nil
		and origCtx.getGlobal == nil
		and origCtx.setGlobal == nil
		and not origCtx.hasDebugHooks
	then
		return instantiateClosure(origCtx, meta.proto, upvals, meta.env)
	end
	local resolvedOpts: LoadOptions = if loadOpts ~= nil
		then loadOpts
		else {
			instructionLimit = origCtx.insnLimit,
			callLimit = origCtx.callLimit,
			timeout = origCtx.timeout,
			interruptInterval = origCtx.interruptInterval,
			interrupt = origCtx.interrupt,
			getGlobal = origCtx.getGlobal,
			setGlobal = origCtx.setGlobal,
			safeEnv = origCtx.safeEnvOpt,
			resourceLimits = origCtx.resourceLimits,
			onCall = origCtx.onCall,
			onReturn = origCtx.onReturn,
			onLine = origCtx.onLine,
			onBreak = origCtx.onBreak,
		} :: LoadOptions
	local optEnv = if loadOpts ~= nil then loadOpts.env else nil
	if optEnv ~= nil and type(optEnv) ~= "table" then
		hostError("invalid env table", 2)
	end
	local env = if newEnv ~= nil then newEnv else (optEnv or meta.env)
	local safeRootsMask = computeSafeRootsMask(env, resolvedOpts)
	local needsHostWrappers = (newEnv ~= nil or optEnv ~= nil)
		or origCtx.needsHostWrappers
		or (resolvedOpts.getGlobal ~= nil)
	local shortSrc = if loadOpts ~= nil and loadOpts.name ~= nil
		then formatChunkSrc(loadOpts.name)
		else origCtx.shortSrc
	local newCtx = createModuleContext(
		origCtx.protos,
		origCtx.mainProto,
		origCtx.templates,
		shortSrc,
		env,
		safeRootsMask,
		needsHostWrappers,
		resolvedOpts
	)
	local protoIdx = meta.proto.id + 1
	local tmpl = newCtx.templates[protoIdx]
	if tmpl == nil then
		tmpl = Verifier.predecodeProtoTemplate(meta.proto)
		newCtx.templates[protoIdx] = tmpl
	end
	newCtx.predecoded[protoIdx] = Verifier.instantiatePredecoded(tmpl, meta.proto, env, newCtx.safeRootsMask)
	return instantiateClosure(newCtx, meta.proto, upvals, env)
end

return table.freeze({
	EMPTY_UPVALS = EMPTY_UPVALS,
	instantiateClosure = instantiateClosure,
	cloneFunction = cloneFunction,
})
