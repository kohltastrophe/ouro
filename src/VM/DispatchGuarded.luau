--!strict
-- Guarded @native register-VM dispatch for limits, resource caps, and debug hooks.
-- Upstream Luau is MIT licensed. See ../../LICENSE.md and ../../UPSTREAM.json.
local BytecodeDefs = require("../BytecodeDefs")
local Fastcalls = require("./Fastcalls")
local RuntimeEnv = require("./RuntimeEnv")
local Verifier = require("./Verifier")

type PredecodedProto = RuntimeEnv.PredecodedProto
type ModuleContext = RuntimeEnv.ModuleContext
type ClosureMeta = RuntimeEnv.ClosureMeta
type FrameState = RuntimeEnv.FrameState
type ThreadState = RuntimeEnv.ThreadState

export type GuardBridge = {
	stackOverflowMsg: (ctx: ModuleContext) -> string,
	ensureTimeoutClock: (ctx: ModuleContext) -> number,
	getPredecoded: (ctx: ModuleContext, proto: any) -> PredecodedProto,
	closeUpvals: (frame: FrameState, fromReg: number) -> (),
	spawnChildClosure: (frame: FrameState, pc: number, a: number, childFid: number, isDupClosure: boolean?) -> number,
	execCall: (tstate: ThreadState, frame: FrameState, a: number, b: number, nresults: number) -> (),
	execForGLoopSlow: (frame: FrameState, pc: number, a: number, nvars: number, targetPc: number) -> number,
	execForGPrep: (frame: FrameState, op: number, a: number, targetPc: number) -> number,
	execForNPrep: (frame: FrameState, pc: number, a: number, skipPc: number) -> number,
	execConcat: (stack: { [number]: any }, a: number, b: number, c: number, maxStrLen: number?) -> (),
	resolveNamecall: (meta: ClosureMeta, obj: any, methodName: any) -> any,
	stepColdOpcode: (frame: FrameState, pc: number, op: number, a: number) -> number,
	pushCalleeFrame: (
		tstate: ThreadState,
		callerFrame: FrameState,
		callerStack: { [number]: any },
		a: number,
		b: number,
		fn: (...any) -> ...any,
		meta: ClosureMeta
	) -> FrameState,
	pushInVmPcallFrame: (
		tstate: ThreadState,
		callerFrame: FrameState,
		callerStack: { [number]: any },
		a: number,
		callArgs: number,
		nresults: number,
		returnPc: number,
		argFn: (...any) -> ...any,
		argMeta: ClosureMeta
	) -> FrameState,
	returnFromPcallFrame: (
		tstate: ThreadState,
		calleeFrame: FrameState,
		calleeStack: { [number]: any },
		retA: number,
		retB: number,
		pcallCf: FrameState
	) -> FrameState,
	popCalleeAndCopyReturns: (
		tstate: ThreadState,
		calleeFrame: FrameState,
		calleeStack: { [number]: any },
		retA: number,
		retB: number
	) -> FrameState,
	unpackAndReleaseEntryFrame: (
		tstate: ThreadState,
		frame: FrameState,
		stack: { [number]: any },
		a: number,
		b: number
	) -> ...any,
}

-- Dense remapped VM opcodes (Tier 0..5); verified against `RuntimeEnv.VOP`.
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
local VOP_GETVARARGS = 77

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

do
	local VOP = RuntimeEnv.VOP
	local Builtins = BytecodeDefs.Builtins
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
			and VOP.GETVARARGS == VOP_GETVARARGS,
		"DispatchGuarded VOP mismatch"
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
		"DispatchGuarded builtin mismatch"
	)
	local _, sample = pcall(function()
		error("@", 1)
	end)
	local s = tostring(sample)
	local pfx = string.match(s, "^(.*):%d+: @$") or ""
	RuntimeEnv.registerVmChunkPrefix(pfx)
end

local EMPTY_VARARGS = table.freeze({}) :: { any }
local MAX_ACTIVE_STACK_SLOTS = 1_000_000
local typeofFn: (any) -> string = (typeof or type) :: any
local closureMeta = RuntimeEnv.closureMeta
local HOST_WRAPPERS = RuntimeEnv.HOST_WRAPPERS
local ROOT_BIT_PCALL = RuntimeEnv.ROOT_BIT_PCALL
local SAFE_INVALIDATION_KEYS = RuntimeEnv.SAFE_INVALIDATION_KEYS
local hostPcall = RuntimeEnv.hostPcall
local hostNext = RuntimeEnv.hostNext
local vmNext = RuntimeEnv.vmNext
local inext = Fastcalls.inext
local execFastcallOp = Fastcalls.execFastcallOp
local getActiveCalls = RuntimeEnv.getActiveCalls
local addActiveCall = RuntimeEnv.addActiveCall
local getLineForPc = RuntimeEnv.getLineForPc
local invalidateEnvRoot = RuntimeEnv.invalidateEnvRoot
local invalidateEnvAll = RuntimeEnv.invalidateEnvAll
local isTrackedEnv = RuntimeEnv.isTrackedEnv
local recordLockedMetatable = RuntimeEnv.recordLockedMetatable
local buildDebugFrameInfo = RuntimeEnv.buildDebugFrameInfo
local resolveGetImportSlow = RuntimeEnv.resolveGetImportSlow
local cloneDuptableSeed = Verifier.cloneDuptableSeed

local function createRunner(bridge: GuardBridge)
	local stackOverflowMsg = bridge.stackOverflowMsg
	local ensureTimeoutClock = bridge.ensureTimeoutClock
	local getPredecoded = bridge.getPredecoded
	local closeUpvals = bridge.closeUpvals
	local spawnChildClosure = bridge.spawnChildClosure
	local execCall = bridge.execCall
	local execForGLoopSlow = bridge.execForGLoopSlow
	local execForGPrep = bridge.execForGPrep
	local execForNPrep = bridge.execForNPrep
	local execConcat = bridge.execConcat
	local resolveNamecall = bridge.resolveNamecall
	local stepColdOpcode = bridge.stepColdOpcode
	local pushCalleeFrame = bridge.pushCalleeFrame
	local pushInVmPcallFrame = bridge.pushInVmPcallFrame
	local returnFromPcallFrame = bridge.returnFromPcallFrame
	local popCalleeAndCopyReturns = bridge.popCalleeAndCopyReturns
	local unpackAndReleaseEntryFrame = bridge.unpackAndReleaseEntryFrame

	local function checkBudgetSlow(ctx: ModuleContext, frame: FrameState, pc: number, checkIntr: boolean)
		if ctx.interrupted then
			frame.pc = pc
			error("execution interrupted", 0)
		end
		local count = ctx.insnCount
		local limit = ctx.insnLimit
		if limit and count > limit then
			frame.pc = pc
			error("instruction limit exceeded", 0)
		end
		if checkIntr and count >= ctx.nextInterrupt then
			ctx.nextInterrupt = count + ctx.interruptInterval
			local timeout = ctx.timeout
			if timeout ~= nil and (os.clock() - ensureTimeoutClock(ctx)) > timeout then
				frame.pc = pc
				error("execution timeout exceeded", 0)
			end
			local intr = ctx.interrupt
			if intr then
				frame.pc = pc
				if intr() == false then
					ctx.interrupted = true
					error("execution interrupted", 0)
				end
			end
		end
	end

	local function reloadBudget(
		ctx: ModuleContext,
		frame: FrameState,
		pc: number,
		curInsnCount: number,
		hasSlowIntr: boolean,
		curInsnLimit: number,
		checkIntr: boolean
	): (number, number, number)
		ctx.insnCount = curInsnCount
		frame.pc = pc
		checkBudgetSlow(ctx, frame, pc, checkIntr)
		local ni = ctx.nextInterrupt
		local thresh = if hasSlowIntr and ni < (curInsnLimit + 1) then ni else (curInsnLimit + 1)
		return ctx.insnCount, ni, thresh
	end

	@native
	local function runLoopGuarded(
		tstate: ThreadState,
		entryDepth: number,
		nestedCaller: boolean?,
		resumed: boolean?
	): ...any
		local frames = tstate.frames
		local frame = frames[tstate.depth]
		local meta = frame.meta
		local ctx = meta.ctx
		local stack = frame.stack
		local upvals = meta.upvals
		local pdata = meta.pdata :: PredecodedProto
		local ops = pdata.ops
		local argA = pdata.argA
		local argB = pdata.argB
		local argC = pdata.argC
		local argD = pdata.argD
		local auxVal = pdata.auxVal
		local fcRa = pdata.fcRa
		local pc = frame.pc
		local hasLimits = ctx.hasLimits
		local insnCount = ctx.insnCount
		local insnLimit = ctx.insnLimit or math.huge
		local hasSlowIntr = ctx.timeout ~= nil or ctx.interrupt ~= nil
		local nextInterrupt = ctx.nextInterrupt
		local checkThreshold = if hasSlowIntr and nextInterrupt < (insnLimit + 1)
			then nextInterrupt
			else (insnLimit + 1)
		local getGlobalHook = ctx.getGlobal
		local setGlobalHook = ctx.setGlobal
		local hasDebugHooks = ctx.hasDebugHooks
		local hasLineHook = ctx.hasLineHook
		local blockStartPc = pc
		if hasDebugHooks and not resumed then
			local onCallHook = ctx.onCall
			if onCallHook then
				if hasLimits then
					ctx.insnCount = insnCount
				end
				onCallHook(buildDebugFrameInfo(frame, tstate.depth, pc))
				if hasLimits then
					insnCount = ctx.insnCount
					insnLimit = ctx.insnLimit or math.huge
					hasSlowIntr = ctx.timeout ~= nil or ctx.interrupt ~= nil
					nextInterrupt = ctx.nextInterrupt
					checkThreshold = if hasSlowIntr and nextInterrupt < (insnLimit + 1)
						then nextInterrupt
						else (insnLimit + 1)
				end
			end
		end

		while true do
			if hasLineHook then
				frame.pc = pc
				local line = getLineForPc(meta.proto, pc)
				if line > 0 and line ~= frame.lastLine then
					frame.lastLine = line
					local onLineHook = ctx.onLine
					if onLineHook then
						if hasLimits then
							ctx.insnCount = insnCount
						end
						onLineHook(line, buildDebugFrameInfo(frame, tstate.depth, pc))
						if hasLimits then
							insnCount = ctx.insnCount
							insnLimit = ctx.insnLimit or math.huge
							hasSlowIntr = ctx.timeout ~= nil or ctx.interrupt ~= nil
							nextInterrupt = ctx.nextInterrupt
							checkThreshold = if hasSlowIntr and nextInterrupt < (insnLimit + 1)
								then nextInterrupt
								else (insnLimit + 1)
						end
					end
				end
			end
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
								local target = argD[pc]
								if hasLimits then
									local steps = pc - blockStartPc + 1
									insnCount += if steps > 0 then steps else 1
									if ctx.interrupted or insnCount >= checkThreshold then
										insnCount, nextInterrupt, checkThreshold =
											reloadBudget(ctx, frame, pc, insnCount, hasSlowIntr, insnLimit, true)
									end
									blockStartPc = target
								end
								pc = target
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
							val = if getGlobalHook ~= nil and type(k) == "string"
								then getGlobalHook(k, curEnv)
								else tbl[k]
							if val ~= nil and (type(val) == "function" or type(val) == "table") then
								val = HOST_WRAPPERS[val] or val
							end
						end
						local wr = ctx.resourceLimitWrappers
						if wr ~= nil and val ~= nil then
							val = wr[val] or val
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
							stack[a + 1] = obj
							stack[a] = resolveNamecall(meta, obj, methodName)
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
							local wr = ctx.resourceLimitWrappers
							if wr ~= nil and val ~= nil then
								val = wr[val] or val
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
						if hasLineHook then
							continue
						end
					end
					if hasLimits then
						local steps = pc - blockStartPc + 1
						insnCount += if steps > 0 then steps else 1
						if ctx.interrupted or insnCount >= checkThreshold then
							insnCount, nextInterrupt, checkThreshold =
								reloadBudget(ctx, frame, pc, insnCount, hasSlowIntr, insnLimit, true)
						end
					end
					local fn = stack[a]
					local b = argB[pc]
					local nresults = argC[pc]
					local calleeMeta = if fn ~= nil then closureMeta[fn] else nil
					if calleeMeta ~= nil then
						local calleeCtx = calleeMeta.ctx
						local calleeProto = calleeMeta.proto
						if not calleeProto.isvararg and b > 0 then
							local curDepth = tstate.depth
							local newDepth = curDepth + 1
							local limitBound = ctx.effectiveCallLimit + tstate.callLimitHeadroom
							if calleeCtx == ctx then
								if ctx.interrupted then
									frame.pc = pc
									ctx.insnCount = insnCount
									error("execution interrupted", 0)
								end
								if
									if ctx.callLimit ~= nil
										then (newDepth > limitBound or getActiveCalls(ctx) >= limitBound)
										else newDepth >= limitBound
								then
									frame.pc = pc
									ctx.insnCount = insnCount
									error(stackOverflowMsg(ctx), 0)
								end
							else
								local calleeLimitBound = calleeCtx.effectiveCallLimit + tstate.callLimitHeadroom
								if calleeCtx.interrupted or ctx.interrupted then
									frame.pc = pc
									ctx.insnCount = insnCount
									error("execution interrupted", 0)
								end
								if
									(
										if calleeCtx.callLimit ~= nil
											then (
												newDepth > calleeLimitBound
												or getActiveCalls(calleeCtx) >= calleeLimitBound
											)
											else newDepth >= calleeLimitBound
									)
									or (
										if ctx.callLimit ~= nil
											then (newDepth > limitBound or getActiveCalls(ctx) >= limitBound)
											else newDepth >= limitBound
									)
								then
									frame.pc = pc
									ctx.insnCount = insnCount
									error(
										if ctx.callLimit ~= nil or calleeCtx.callLimit ~= nil
											then "call stack overflow"
											else "stack overflow",
										0
									)
								end
							end
							local maxstack = calleeProto.maxstacksize
							if tstate.activeStackSlots + maxstack > MAX_ACTIVE_STACK_SLOTS then
								frame.pc = pc
								ctx.insnCount = insnCount
								error("call stack overflow", 0)
							end
							tstate.activeStackSlots += maxstack
							local calleePdata = calleeMeta.pdata
							if not calleePdata then
								calleePdata = getPredecoded(calleeCtx, calleeProto)
								calleeMeta.pdata = calleePdata
							end
							frame.pc = pc
							frame.returnPc = argD[pc]
							frame.callA = a
							frame.callNResults = nresults

							local callArgs = b - 1
							local numparams = calleeProto.numparams
							tstate.depth = newDepth
							local calleeFrame = frames[newDepth]
							local calleeStack
							if calleeFrame then
								calleeStack = calleeFrame.stack
								if calleeFrame.stackCap == 0 or calleeFrame.stackCap < maxstack then
									local stackCap = if maxstack <= 16
										then 16
										elseif maxstack <= 32 then 32
										else maxstack
									calleeStack = table.create(stackCap)
									calleeFrame.stack = calleeStack
									calleeFrame.stackCap = stackCap
								end
								calleeFrame.meta = calleeMeta
								calleeFrame.closure = fn
								calleeFrame.stackSlots = maxstack
								calleeFrame.top = numparams + 1
								calleeFrame.pc = 1
								calleeFrame.lastLine = 0
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
									stackSlots = maxstack,
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
							if calleeCtx.callLimit ~= nil then
								addActiveCall(calleeCtx, coroutine.running(), 1)
							end
							frame = calleeFrame
							stack = calleeStack
							if calleeMeta ~= meta then
								meta = calleeMeta
								if calleeCtx ~= ctx then
									if hasLimits then
										ctx.insnCount = insnCount
									end
									ctx = calleeCtx
									hasLimits = ctx.hasLimits
									insnCount = ctx.insnCount
									insnLimit = ctx.insnLimit or math.huge
									hasSlowIntr = ctx.timeout ~= nil or ctx.interrupt ~= nil
									nextInterrupt = ctx.nextInterrupt
									checkThreshold = if hasSlowIntr and nextInterrupt < (insnLimit + 1)
										then nextInterrupt
										else (insnLimit + 1)
									getGlobalHook = ctx.getGlobal
									setGlobalHook = ctx.setGlobal
									hasDebugHooks = ctx.hasDebugHooks
									hasLineHook = ctx.hasLineHook
								end
								upvals = calleeMeta.upvals
								pdata = calleePdata :: PredecodedProto
								ops = pdata.ops
								argA = pdata.argA
								argB = pdata.argB
								argC = pdata.argC
								argD = pdata.argD
								auxVal = pdata.auxVal
								fcRa = pdata.fcRa
							end
							pc = 1
							if hasLimits then
								blockStartPc = 1
							end
							if hasDebugHooks then
								local onCallHook = ctx.onCall
								if onCallHook then
									if hasLimits then
										ctx.insnCount = insnCount
									end
									onCallHook(buildDebugFrameInfo(frame, newDepth, 1))
									if hasLimits then
										insnCount = ctx.insnCount
										insnLimit = ctx.insnLimit or math.huge
										nextInterrupt = ctx.nextInterrupt
										checkThreshold = if hasSlowIntr and nextInterrupt < (insnLimit + 1)
											then nextInterrupt
											else (insnLimit + 1)
									end
								end
							end
							continue
						end
						frame.pc = pc
						frame.returnPc = argD[pc]
						frame.callA = a
						frame.callNResults = nresults
						if hasLimits then
							ctx.insnCount = insnCount
						end
						frame = pushCalleeFrame(tstate, frame, stack, a, b, fn, calleeMeta)
						stack = frame.stack
						if calleeMeta ~= meta then
							meta = calleeMeta
							if calleeCtx ~= ctx then
								ctx = calleeCtx
								hasLimits = ctx.hasLimits
								insnCount = ctx.insnCount
								insnLimit = ctx.insnLimit or math.huge
								hasSlowIntr = ctx.timeout ~= nil or ctx.interrupt ~= nil
								nextInterrupt = ctx.nextInterrupt
								checkThreshold = if hasSlowIntr and nextInterrupt < (insnLimit + 1)
									then nextInterrupt
									else (insnLimit + 1)
								getGlobalHook = ctx.getGlobal
								setGlobalHook = ctx.setGlobal
								hasDebugHooks = ctx.hasDebugHooks
								hasLineHook = ctx.hasLineHook
							end
							upvals = calleeMeta.upvals
							pdata = meta.pdata :: PredecodedProto
							ops = pdata.ops
							argA = pdata.argA
							argB = pdata.argB
							argC = pdata.argC
							argD = pdata.argD
							auxVal = pdata.auxVal
							fcRa = pdata.fcRa
						else
							if hasLimits then
								insnCount = ctx.insnCount
							end
						end
						pc = 1
						if hasLimits then
							blockStartPc = 1
						end
						if hasDebugHooks then
							local onCallHook = ctx.onCall
							if onCallHook then
								if hasLimits then
									ctx.insnCount = insnCount
								end
								onCallHook(buildDebugFrameInfo(frame, tstate.depth, 1))
								if hasLimits then
									insnCount = ctx.insnCount
									insnLimit = ctx.insnLimit or math.huge
									nextInterrupt = ctx.nextInterrupt
									checkThreshold = if hasSlowIntr and nextInterrupt < (insnLimit + 1)
										then nextInterrupt
										else (insnLimit + 1)
								end
							end
						end
						continue
					elseif fn == hostPcall then
						local callArgs = if b == 0 then (frame.top - (a + 1)) else (b - 1)
						local argFn = if callArgs >= 1 then stack[a + 1] else nil
						if argFn ~= nil then
							argFn = HOST_WRAPPERS[argFn] or argFn
							local wr = ctx.resourceLimitWrappers
							if wr ~= nil then
								argFn = wr[argFn] or argFn
							end
						end
						local argMeta = if type(argFn) == "function" then closureMeta[argFn] else nil
						if argMeta ~= nil then
							frame.pc = pc
							if hasLimits then
								ctx.insnCount = insnCount
							end
							frame = pushInVmPcallFrame(
								tstate,
								frame,
								stack,
								a,
								callArgs,
								nresults,
								argD[pc],
								argFn,
								argMeta
							)
							stack = frame.stack
							if argMeta ~= meta then
								meta = argMeta
								local calleeCtx = argMeta.ctx
								if calleeCtx ~= ctx then
									ctx = calleeCtx
									hasLimits = ctx.hasLimits
									insnCount = ctx.insnCount
									insnLimit = ctx.insnLimit or math.huge
									hasSlowIntr = ctx.timeout ~= nil or ctx.interrupt ~= nil
									nextInterrupt = ctx.nextInterrupt
									checkThreshold = if hasSlowIntr and nextInterrupt < (insnLimit + 1)
										then nextInterrupt
										else (insnLimit + 1)
									getGlobalHook = ctx.getGlobal
									setGlobalHook = ctx.setGlobal
									hasDebugHooks = ctx.hasDebugHooks
									hasLineHook = ctx.hasLineHook
								end
								upvals = argMeta.upvals
								pdata = meta.pdata :: PredecodedProto
								ops = pdata.ops
								argA = pdata.argA
								argB = pdata.argB
								argC = pdata.argC
								argD = pdata.argD
								auxVal = pdata.auxVal
								fcRa = pdata.fcRa
							else
								if hasLimits then
									insnCount = ctx.insnCount
								end
							end
							pc = 1
							if hasLimits then
								blockStartPc = 1
							end
							if hasDebugHooks then
								local onCallHook = ctx.onCall
								if onCallHook then
									if hasLimits then
										ctx.insnCount = insnCount
									end
									onCallHook(buildDebugFrameInfo(frame, tstate.depth, 1))
									if hasLimits then
										insnCount = ctx.insnCount
										insnLimit = ctx.insnLimit or math.huge
										nextInterrupt = ctx.nextInterrupt
										checkThreshold = if hasSlowIntr and nextInterrupt < (insnLimit + 1)
											then nextInterrupt
											else (insnLimit + 1)
									end
								end
							end
							continue
						end
					end
					frame.pc = pc
					if hasLimits then
						ctx.insnCount = insnCount
					end
					execCall(tstate, frame, a, b, nresults)
					if hasLimits then
						insnCount = ctx.insnCount
						insnLimit = ctx.insnLimit or math.huge
						hasSlowIntr = ctx.timeout ~= nil or ctx.interrupt ~= nil
						nextInterrupt = ctx.nextInterrupt
						checkThreshold = if hasSlowIntr and nextInterrupt < (insnLimit + 1)
							then nextInterrupt
							else (insnLimit + 1)
					end
					if ctx.interrupted then
						error("execution interrupted", 0)
					end
					if ctx.insnLimit ~= nil and insnCount > ctx.insnLimit then
						error("instruction limit exceeded", 0)
					end
					if ctx.timeout ~= nil and (os.clock() - ensureTimeoutClock(ctx)) > ctx.timeout then
						error("execution timeout exceeded", 0)
					end
					pc = argD[pc]
					if hasLimits then
						blockStartPc = pc
					end
				elseif op == VOP_RETURN then
					if hasLimits then
						local steps = pc - blockStartPc + 1
						insnCount += if steps > 0 then steps else 1
						ctx.insnCount = insnCount
						if ctx.interrupted or insnCount >= checkThreshold then
							frame.pc = pc
							checkBudgetSlow(ctx, frame, pc, false)
							insnCount = ctx.insnCount
						end
					end
					if hasDebugHooks then
						local onReturnHook = ctx.onReturn
						if onReturnHook then
							frame.pc = pc
							onReturnHook(buildDebugFrameInfo(frame, tstate.depth, pc))
							if hasLimits then
								insnCount = ctx.insnCount
							end
						end
					end
					if frame.hasOpenUpvals then
						closeUpvals(frame, 1)
					end
					local retB = argB[pc]
					local curDepth = tstate.depth
					if curDepth > entryDepth + 1 or (nestedCaller and curDepth >= entryDepth + 1) then
						local callerFrame = frames[curDepth - 1]
						if callerFrame.isPcall then
							frame = returnFromPcallFrame(tstate, frame, stack, a, retB, callerFrame)
							if nestedCaller and tstate.depth <= entryDepth then
								return
							end
							stack = frame.stack
							local callerMeta = frame.meta
							if callerMeta ~= meta then
								meta = callerMeta
								local callerCtx = meta.ctx
								if callerCtx ~= ctx then
									ctx = callerCtx
									hasLimits = ctx.hasLimits
									insnCount = ctx.insnCount
									insnLimit = ctx.insnLimit or math.huge
									hasSlowIntr = ctx.timeout ~= nil or ctx.interrupt ~= nil
									nextInterrupt = ctx.nextInterrupt
									checkThreshold = if hasSlowIntr and nextInterrupt < (insnLimit + 1)
										then nextInterrupt
										else (insnLimit + 1)
									getGlobalHook = ctx.getGlobal
									setGlobalHook = ctx.setGlobal
									hasDebugHooks = ctx.hasDebugHooks
									hasLineHook = ctx.hasLineHook
								end
								upvals = meta.upvals
								pdata = meta.pdata :: PredecodedProto
								ops = pdata.ops
								argA = pdata.argA
								argB = pdata.argB
								argC = pdata.argC
								argD = pdata.argD
								auxVal = pdata.auxVal
								fcRa = pdata.fcRa
							end
							pc = frame.pc
							if hasLimits then
								blockStartPc = pc
							end
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
							if nestedCaller and tstate.depth <= entryDepth then
								return
							end
							stack = frame.stack
							local callerMeta = frame.meta
							if callerMeta ~= meta then
								meta = callerMeta
								local callerCtx = meta.ctx
								if callerCtx ~= ctx then
									ctx = callerCtx
									hasLimits = ctx.hasLimits
									insnCount = ctx.insnCount
									insnLimit = ctx.insnLimit or math.huge
									hasSlowIntr = ctx.timeout ~= nil or ctx.interrupt ~= nil
									nextInterrupt = ctx.nextInterrupt
									checkThreshold = if hasSlowIntr and nextInterrupt < (insnLimit + 1)
										then nextInterrupt
										else (insnLimit + 1)
									getGlobalHook = ctx.getGlobal
									setGlobalHook = ctx.setGlobal
									hasDebugHooks = ctx.hasDebugHooks
									hasLineHook = ctx.hasLineHook
								end
								upvals = meta.upvals
								pdata = meta.pdata :: PredecodedProto
								ops = pdata.ops
								argA = pdata.argA
								argB = pdata.argB
								argC = pdata.argC
								argD = pdata.argD
								auxVal = pdata.auxVal
								fcRa = pdata.fcRa
							end
							pc = frame.pc
							if hasLimits then
								blockStartPc = pc
							end
							continue
						end
						table.clear(stack)
						if ctx.callLimit ~= nil then
							addActiveCall(ctx, coroutine.running(), -1)
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
						local retPc = callerFrame.returnPc
						callerFrame.pc = retPc
						if nestedCaller and tstate.depth <= entryDepth then
							return
						end
						frame = callerFrame
						stack = callerFrame.stack
						local callerMeta = callerFrame.meta
						if callerMeta ~= meta then
							meta = callerMeta
							local callerCtx = meta.ctx
							if callerCtx ~= ctx then
								ctx = callerCtx
								hasLimits = ctx.hasLimits
								insnCount = ctx.insnCount
								insnLimit = ctx.insnLimit or math.huge
								hasSlowIntr = ctx.timeout ~= nil or ctx.interrupt ~= nil
								nextInterrupt = ctx.nextInterrupt
								checkThreshold = if hasSlowIntr and nextInterrupt < (insnLimit + 1)
									then nextInterrupt
									else (insnLimit + 1)
								getGlobalHook = ctx.getGlobal
								setGlobalHook = ctx.setGlobal
								hasDebugHooks = ctx.hasDebugHooks
								hasLineHook = ctx.hasLineHook
							end
							upvals = meta.upvals
							pdata = meta.pdata :: PredecodedProto
							ops = pdata.ops
							argA = pdata.argA
							argB = pdata.argB
							argC = pdata.argC
							argD = pdata.argD
							auxVal = pdata.auxVal
							fcRa = pdata.fcRa
						end
						pc = retPc
						if hasLimits then
							blockStartPc = pc
						end
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
								local target = argD[pc]
								if hasLimits then
									local steps = pc - blockStartPc + 1
									insnCount += if steps > 0 then steps else 1
									if ctx.interrupted or insnCount >= checkThreshold then
										insnCount, nextInterrupt, checkThreshold = reloadBudget(
											ctx,
											frame,
											pc,
											insnCount,
											hasSlowIntr,
											insnLimit,
											target <= pc
										)
									end
									blockStartPc = target
								end
								pc = target
							else
								pc += 1
							end
						elseif op == VOP_JUMPIF then
							if stack[a] then
								local target = argD[pc]
								if hasLimits then
									local steps = pc - blockStartPc + 1
									insnCount += if steps > 0 then steps else 1
									if ctx.interrupted or insnCount >= checkThreshold then
										insnCount, nextInterrupt, checkThreshold = reloadBudget(
											ctx,
											frame,
											pc,
											insnCount,
											hasSlowIntr,
											insnLimit,
											target <= pc
										)
									end
									blockStartPc = target
								end
								pc = target
							else
								pc += 1
							end
						elseif op == VOP_JUMP then
							local target = argD[pc]
							if hasLimits then
								local steps = pc - blockStartPc + 1
								insnCount += if steps > 0 then steps else 1
								if ctx.interrupted or insnCount >= checkThreshold then
									insnCount, nextInterrupt, checkThreshold =
										reloadBudget(ctx, frame, pc, insnCount, hasSlowIntr, insnLimit, target <= pc)
								end
								blockStartPc = target
							end
							pc = target
						else -- VOP_JUMPBACK
							local target = argD[pc]
							if hasLimits then
								local steps = pc - blockStartPc + 1
								insnCount += if steps > 0 then steps else 1
								if ctx.interrupted or insnCount >= checkThreshold then
									insnCount, nextInterrupt, checkThreshold =
										reloadBudget(ctx, frame, pc, insnCount, hasSlowIntr, insnLimit, true)
								end
								blockStartPc = target
							end
							pc = target
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
							local target = argD[pc]
							if hasLimits then
								local steps = pc - blockStartPc + 1
								insnCount += if steps > 0 then steps else 1
								if ctx.interrupted or insnCount >= checkThreshold then
									insnCount, nextInterrupt, checkThreshold =
										reloadBudget(ctx, frame, pc, insnCount, hasSlowIntr, insnLimit, target <= pc)
								end
								blockStartPc = target
							end
							pc = target
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
							local wr = ctx.resourceLimitWrappers
							if wr ~= nil and val ~= nil then
								val = wr[val] or val
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
							local wr = ctx.resourceLimitWrappers
							if wr ~= nil and v ~= nil then
								v = wr[v] or v
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
									elseif a == LBF_TABLE_CREATE and ctx.maxTableSize == nil then
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
										if a == LBF_TABLE_INSERT and ctx.maxTableSize == nil then
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
									elseif a == LBF_TABLE_CREATE and ctx.maxTableSize == nil then
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
						local nextPc = execFastcallOp(frame, pc, op)
						if hasLimits and nextPc > pc + 2 then
							local steps = pc - blockStartPc + 1
							insnCount += if steps > 0 then steps else 1
							if ctx.interrupted or insnCount >= checkThreshold then
								insnCount, nextInterrupt, checkThreshold =
									reloadBudget(ctx, frame, pc, insnCount, hasSlowIntr, insnLimit, false)
							end
							blockStartPc = nextPc
						end
						pc = nextPc
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
						local nextPc = execFastcallOp(frame, pc, op)
						if hasLimits and nextPc > pc + 2 then
							local steps = pc - blockStartPc + 1
							insnCount += if steps > 0 then steps else 1
							if ctx.interrupted or insnCount >= checkThreshold then
								insnCount, nextInterrupt, checkThreshold =
									reloadBudget(ctx, frame, pc, insnCount, hasSlowIntr, insnLimit, false)
							end
							blockStartPc = nextPc
						end
						pc = nextPc
					else -- VOP_FASTCALL
						frame.pc = pc
						local nextPc = execFastcallOp(frame, pc, op)
						if hasLimits and nextPc > pc + 2 then
							local steps = pc - blockStartPc + 1
							insnCount += if steps > 0 then steps else 1
							if ctx.interrupted or insnCount >= checkThreshold then
								insnCount, nextInterrupt, checkThreshold =
									reloadBudget(ctx, frame, pc, insnCount, hasSlowIntr, insnLimit, false)
							end
							blockStartPc = nextPc
						end
						pc = nextPc
					end
				else
					if op == VOP_NEWCLOSURE then
						frame.pc = pc
						if hasLimits then
							local steps = pc - blockStartPc + 1
							insnCount += if steps > 0 then steps else 1
							if ctx.interrupted or insnCount >= checkThreshold then
								insnCount, nextInterrupt, checkThreshold =
									reloadBudget(ctx, frame, pc, insnCount, hasSlowIntr, insnLimit, false)
							end
						end
						pc = spawnChildClosure(frame, pc, a, argD[pc], false)
						if hasLimits then
							blockStartPc = pc
						end
					elseif op == VOP_FORGLOOP then
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
								if hasLimits then
									local steps = pc - blockStartPc + 1
									insnCount += if steps > 0 then steps else 1
									if ctx.interrupted or insnCount >= checkThreshold then
										insnCount, nextInterrupt, checkThreshold =
											reloadBudget(ctx, frame, pc, insnCount, hasSlowIntr, insnLimit, true)
									end
									blockStartPc = targetPc
								end
								pc = targetPc
							else
								stack[a + 3] = nil
								pc += 2
							end
						elseif (gen == hostNext or gen == vmNext) and nvars <= 2 and type(tbl) == "table" then
							local k1, v2 = hostNext(tbl, stack[a + 2])
							if k1 ~= nil then
								local wr = ctx.resourceLimitWrappers
								if type(k1) == "function" or type(k1) == "table" then
									k1 = HOST_WRAPPERS[k1] or k1
									if wr ~= nil then
										k1 = wr[k1] or k1
									end
								end
								stack[a + 3] = k1
								if nvars == 2 then
									if v2 ~= nil and (type(v2) == "function" or type(v2) == "table") then
										v2 = HOST_WRAPPERS[v2] or v2
										if wr ~= nil then
											v2 = wr[v2] or v2
										end
									end
									stack[a + 4] = v2
								end
								stack[a + 2] = k1
								if hasLimits then
									local steps = pc - blockStartPc + 1
									insnCount += if steps > 0 then steps else 1
									if ctx.interrupted or insnCount >= checkThreshold then
										insnCount, nextInterrupt, checkThreshold =
											reloadBudget(ctx, frame, pc, insnCount, hasSlowIntr, insnLimit, true)
									end
									blockStartPc = targetPc
								end
								pc = targetPc
							else
								stack[a + 3] = nil
								pc += 2
							end
						else
							if hasLimits then
								ctx.insnCount = insnCount
							end
							local nextPc = execForGLoopSlow(frame, pc, a, nvars, targetPc)
							if hasLimits then
								insnCount = ctx.insnCount
								if nextPc ~= pc + 2 then
									local steps = pc - blockStartPc + 1
									insnCount += if steps > 0 then steps else 1
									if ctx.interrupted or insnCount >= checkThreshold then
										insnCount, nextInterrupt, checkThreshold =
											reloadBudget(ctx, frame, pc, insnCount, hasSlowIntr, insnLimit, true)
									end
									blockStartPc = nextPc
								end
							end
							pc = nextPc
						end
					else
						frame.pc = pc
						if hasLimits then
							ctx.insnCount = insnCount
							local steps = pc - blockStartPc + 1
							ctx.insnCount += if steps > 0 then steps else 1
							if ctx.interrupted or ctx.insnCount >= checkThreshold then
								checkBudgetSlow(ctx, frame, pc, false)
							end
						end
						pc = stepColdOpcode(frame, pc, op, a)
						if hasLimits then
							insnCount = ctx.insnCount
							insnLimit = ctx.insnLimit or math.huge
							nextInterrupt = ctx.nextInterrupt
							checkThreshold = if hasSlowIntr and nextInterrupt < (insnLimit + 1)
								then nextInterrupt
								else (insnLimit + 1)
							blockStartPc = pc
						end
					end
				end
			else
				if op <= 65 then
					if op <= 55 then
						if op == VOP_DUPTABLE then
							local maxTbl = ctx.maxTableSize
							if maxTbl ~= nil then
								local tc = pdata.kValues[argD[pc]]
								if type(tc) == "table" and (tc :: { length: number }).length > maxTbl then
									frame.pc = pc
									error("table size limit exceeded", 0)
								end
							end
							stack[a] = table.clone(auxVal[pc])
							pc += 1
						elseif op == VOP_NEWTABLE then
							local maxTbl = ctx.maxTableSize
							local alloc = argD[pc]
							local bRaw = argB[pc] - 1
							if maxTbl ~= nil then
								local rawAux = pdata.code[pc + 1] or 0
								local hashSize = if bRaw > 0 then bit32.lshift(1, bRaw - 1) else 0
								if rawAux > maxTbl or hashSize > maxTbl or rawAux + hashSize > maxTbl then
									frame.pc = pc
									error("table size limit exceeded", 0)
								end
							end
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
							local maxTbl = ctx.maxTableSize
							if maxTbl ~= nil and cnt > 0 and (cnt > maxTbl or (aux + cnt - 1) > maxTbl) then
								error("table size limit exceeded", 0)
							end
							local tbl = stack[a]
							for i = 0, cnt - 1 do
								tbl[aux + i] = stack[bBase + i]
							end
							pc += 2
						elseif op == VOP_FORNPREP then
							frame.pc = pc
							local nextPc = execForNPrep(frame, pc, a, argD[pc])
							if hasLimits then
								local steps = pc - blockStartPc + 1
								insnCount += if steps > 0 then steps else 1
								if ctx.interrupted or insnCount >= checkThreshold then
									insnCount, nextInterrupt, checkThreshold =
										reloadBudget(ctx, frame, pc, insnCount, hasSlowIntr, insnLimit, nextPc <= pc)
								end
								blockStartPc = nextPc
							end
							pc = nextPc
						elseif op == VOP_FORGPREP then
							frame.pc = pc
							local nextPc = execForGPrep(frame, op, a, argD[pc])
							if hasLimits then
								local steps = pc - blockStartPc + 1
								insnCount += if steps > 0 then steps else 1
								if ctx.interrupted or insnCount >= checkThreshold then
									insnCount, nextInterrupt, checkThreshold =
										reloadBudget(ctx, frame, pc, insnCount, hasSlowIntr, insnLimit, nextPc <= pc)
								end
								blockStartPc = nextPc
							end
							pc = nextPc
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
									local wr = ctx.resourceLimitWrappers
									if wr ~= nil then
										argFn = wr[argFn] or argFn
									end
								end
								local argMeta = if type(argFn) == "function" then closureMeta[argFn] else nil
								if argMeta ~= nil then
									if hasLimits then
										local steps = pc - blockStartPc + 1
										insnCount += if steps > 0 then steps else 1
										if ctx.interrupted or insnCount >= checkThreshold then
											insnCount, nextInterrupt, checkThreshold =
												reloadBudget(ctx, frame, pc, insnCount, hasSlowIntr, insnLimit, true)
										else
											ctx.insnCount = insnCount
										end
									end
									frame.pc = pc
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
									if argMeta ~= meta then
										meta = argMeta
										local calleeCtx = argMeta.ctx
										if calleeCtx ~= ctx then
											ctx = calleeCtx
											hasLimits = ctx.hasLimits
											insnCount = ctx.insnCount
											insnLimit = ctx.insnLimit or math.huge
											hasSlowIntr = ctx.timeout ~= nil or ctx.interrupt ~= nil
											nextInterrupt = ctx.nextInterrupt
											checkThreshold = if hasSlowIntr and nextInterrupt < (insnLimit + 1)
												then nextInterrupt
												else (insnLimit + 1)
											getGlobalHook = ctx.getGlobal
											setGlobalHook = ctx.setGlobal
											hasDebugHooks = ctx.hasDebugHooks
											hasLineHook = ctx.hasLineHook
										end
										upvals = argMeta.upvals
										pdata = meta.pdata :: PredecodedProto
										ops = pdata.ops
										argA = pdata.argA
										argB = pdata.argB
										argC = pdata.argC
										argD = pdata.argD
										auxVal = pdata.auxVal
										fcRa = pdata.fcRa
									end
									pc = 1
									if hasLimits then
										blockStartPc = 1
									end
									if hasDebugHooks then
										local onCallHook = ctx.onCall
										if onCallHook then
											if hasLimits then
												ctx.insnCount = insnCount
											end
											onCallHook(buildDebugFrameInfo(frame, tstate.depth, 1))
											if hasLimits then
												insnCount = ctx.insnCount
												insnLimit = ctx.insnLimit or math.huge
												nextInterrupt = ctx.nextInterrupt
												checkThreshold = if hasSlowIntr
														and nextInterrupt < (insnLimit + 1)
													then nextInterrupt
													else (insnLimit + 1)
											end
										end
									end
									continue
								end
							end
							pc += 1
						elseif op == VOP_LOADNIL then
							stack[a] = nil
							pc += 1
						else -- VOP_LOADB
							if hasLimits then
								local steps = pc - blockStartPc + 1
								insnCount += if steps > 0 then steps else 1
								if ctx.interrupted or insnCount >= checkThreshold then
									insnCount, nextInterrupt, checkThreshold =
										reloadBudget(ctx, frame, pc, insnCount, hasSlowIntr, insnLimit, false)
								end
								blockStartPc = argC[pc]
							end
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
							execConcat(stack, a, argB[pc], argC[pc], ctx.maxStringLength)
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
							local target = argD[pc]
							if hasLimits then
								local steps = pc - blockStartPc + 1
								insnCount += if steps > 0 then steps else 1
								if ctx.interrupted or insnCount >= checkThreshold then
									insnCount, nextInterrupt, checkThreshold =
										reloadBudget(ctx, frame, pc, insnCount, hasSlowIntr, insnLimit, target <= pc)
								end
								blockStartPc = target
							end
							pc = target
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
					if hasLimits then
						ctx.insnCount = insnCount
					end
					local nextPc = stepColdOpcode(frame, pc, op, a)
					if hasLimits then
						insnCount = ctx.insnCount
						insnLimit = ctx.insnLimit or math.huge
						nextInterrupt = ctx.nextInterrupt
						checkThreshold = if hasSlowIntr and nextInterrupt < (insnLimit + 1)
							then nextInterrupt
							else (insnLimit + 1)
						if nextPc ~= pc + 1 and nextPc ~= pc + 2 then
							local steps = pc - blockStartPc + 1
							insnCount += if steps > 0 then steps else 1
							if ctx.interrupted or insnCount >= checkThreshold then
								insnCount, nextInterrupt, checkThreshold =
									reloadBudget(ctx, frame, pc, insnCount, hasSlowIntr, insnLimit, nextPc <= pc)
							end
							blockStartPc = nextPc
						end
					end
					pc = nextPc
				end
			end
		end
	end

	return runLoopGuarded
end

return table.freeze({
	createRunner = createRunner,
})
