--!optimize 2
-- Portable comparative benchmark suite for Ouro (pipeline, O2 compilation, cold startup,
-- and 13 warm VM workloads across Host Luau, Ouro unbounded, Ouro guarded, and optional Fiu / LuauCeption).
-- Run directly with `luau --codegen -O2 docs/benchmarks/run.luau` for human tables,
-- or pass `--json` (used by `docs/benchmarks/bench.py`) for structured JSON output.

local function tryRequire(mod: string): (boolean, any)
	return pcall(require, mod)
end

local okOuro, Ouro = tryRequire("@ouro")
if not okOuro then
	Ouro = require("../../")
end

local VM = Ouro.VM
local Compiler = Ouro.Compiler
local LexerOk, Lexer = tryRequire("@ouro/src/Lexer")
local ParserOk, Parser = tryRequire("@ouro/src/Parser")
local CodecOk, BytecodeCodec = tryRequire("@ouro/src/BytecodeCodec")
if not LexerOk then
	Lexer = require("../../src/Lexer")
end
if not ParserOk then
	Parser = require("../../src/Parser")
end
if not CodecOk then
	BytecodeCodec = require("../../src/BytecodeCodec")
end

local okLc, LC: any = tryRequire("@lc/Full")
local okFiu, Fiu: any = tryRequire("@fiu")

local cliArgs = { ... }
local jsonMode = false
local verifyMode = false
for _, a in cliArgs do
	if a == "--json" then
		jsonMode = true
	elseif a == "--verify" then
		verifyMode = true
	end
end

local function nowMs(): number
	return os.clock() * 1000
end

local function sampleStats(samples: { number }): (number, number)
	table.sort(samples)
	local n = #samples
	local p50 = if n % 2 == 1 then samples[(n + 1) // 2] else (samples[n // 2] + samples[n // 2 + 1]) * 0.5
	return p50, samples[1]
end

local function bench(iters: number, warmup: number, fn: () -> ()): (number, number)
	for _ = 1, warmup do
		fn()
	end
	local times = table.create(iters)
	for i = 1, iters do
		local t0 = nowMs()
		fn()
		times[i] = nowMs() - t0
	end
	return sampleStats(times)
end

local function makeCorpus(unit: string, targetBytes: number): string
	local reps = math.max(1, math.floor((targetBytes - 3) / #unit))
	local s = string.rep(unit, reps)
	if #s < targetBytes then
		s ..= "--" .. string.rep("x", targetBytes - #s - 3) .. "\n"
	end
	return s
end

local function firstLine(err: any): string
	local s = tostring(err)
	return string.match(s, "[^\r\n]+") or s
end

local runtimeUnit = "do local x=1; local function f(y) return x+y end; x=f(x); if x>1 then x+=1 end end\n"
local typesUnit = "type Item<T,U...> = {value:T,call:(T,U...)->(T,U...)}\n"

-- 1. O2 Compilation (5 corpora) + Ouro pipeline breakdown
local compileCases = {
	{
		name = "tiny-120B",
		desc = "small loop chunk",
		iters = 7,
		src = "local s = 0; for i = 1, 100 do s += i * 2 end; return s\n",
	},
	{
		name = "runtime-10KiB",
		desc = "10 KiB runtime code",
		iters = 7,
		src = makeCorpus(runtimeUnit, 10 * 1024),
	},
	{
		name = "runtime-50KiB",
		desc = "50 KiB runtime code",
		iters = 7,
		src = makeCorpus(runtimeUnit, 50 * 1024),
	},
	{
		name = "runtime-250KiB",
		desc = "250 KiB runtime code",
		iters = 5,
		src = makeCorpus(runtimeUnit, 250 * 1024),
	},
	{
		name = "types-50KiB",
		desc = "50 KiB generics & types",
		iters = 7,
		src = makeCorpus(typesUnit, 50 * 1024),
	},
}

local compileResults = {}
for _, c in compileCases do
	local bcCheck = assert(Ouro.compile(c.src, { optimizationLevel = 2, debugLevel = 1 }))
	assert(string.byte(bcCheck, 1) ~= 0, "Ouro compile failed on " .. c.name)

	local ouroP50, ouroMin = bench(c.iters, 2, function()
		Ouro.compile(c.src, { optimizationLevel = 2, debugLevel = 1 })
	end)
	local lexP50 = bench(c.iters, 1, function()
		local l = Lexer.new(c.src)
		repeat
		until l:next() == 0
	end)
	local parseP50 = bench(c.iters, 1, function()
		Parser.parse(c.src)
	end)
	local ast = Parser.parse(c.src)
	local compileOnlyO2P50 = bench(c.iters, 1, function()
		Compiler.compile(ast, { optimizationLevel = 2, debugLevel = 1 })
	end)

	local row: { [string]: any } = {
		name = c.name,
		desc = c.desc,
		bytes = #c.src,
		bytecodeBytes = #bcCheck,
		lex_p50_ms = lexP50,
		parse_p50_ms = parseP50,
		compile_only_o2_p50_ms = compileOnlyO2P50,
		ouro = { status = "ok", p50Ms = ouroP50, minMs = ouroMin },
	}
	if okLc then
		local lbcCheck = LC.luau_compile(c.src, 2, 1, 0, 0)
		assert(string.byte(lbcCheck, 1) ~= 0, "LC compile failed on " .. c.name)
		local lcP50, lcMin = bench(c.iters, 1, function()
			LC.luau_compile(c.src, 2, 1, 0, 0)
		end)
		row.luauception = { status = "ok", p50Ms = lcP50, minMs = lcMin }
	end
	table.insert(compileResults, row)
end

-- 2. Bytecode deserialize & loadBytecode
local deserializeResults = {}
for _, kib in { 10, 50, 250 } do
	local src = makeCorpus(runtimeUnit, kib * 1024)
	local bc = assert(Ouro.compile(src, { optimizationLevel = 2, debugLevel = 1 }))
	local iters = if kib >= 250 then 5 else 9
	local deserP50, deserMin = bench(iters, 2, function()
		local pm = assert(BytecodeCodec.deserialize(bc))
		assert(#pm.protos > 0)
	end)
	local loadP50, loadMin = bench(iters, 2, function()
		local fn = assert(VM.loadBytecode(bc))
		assert(type(fn) == "function")
	end)
	table.insert(deserializeResults, {
		name = "runtime-" .. tostring(kib) .. "KiB",
		bytecodeBytes = #bc,
		deserialize = { status = "ok", p50Ms = deserP50, minMs = deserMin },
		loadBytecode = { status = "ok", p50Ms = loadP50, minMs = loadMin },
	})
end

-- 3. Warm VM Execution (13 workloads)
local vmWorkloads = {
	{
		name = "vm-suite",
		desc = "mixed loop/fib/meta/co",
		iters = 7,
		src = [[
return function()
	local function sumLoop(n) local s = 0 for i = 1, n do s += (i * 3 - 1) % 97 end return s end
	local function fib(n) if n < 2 then return n end return fib(n - 1) + fib(n - 2) end
	local function closures(n)
		local total = 0
		for i = 1, n do
			local x = i
			local f = function(y) x += y return x end
			total += f(2) + f(3)
		end
		return total
	end
	local function tablesAndMeta(n)
		local mt = { __add = function(a, b) return setmetatable({ v = a.v + b.v }, getmetatable(a)) end }
		local acc = setmetatable({ v = 0 }, mt)
		for i = 1, n do acc = acc + setmetatable({ v = i }, mt) end
		return acc.v
	end
	local function coroutines(n)
		local co = coroutine.create(function() for i = 1, n do coroutine.yield(i * 2) end return 999 end)
		local s = 0
		while true do
			local ok, v = coroutine.resume(co)
			if not ok then error(v) end
			s += v
			if coroutine.status(co) == "dead" then break end
		end
		return s
	end
	return sumLoop(20000) + fib(18) + closures(2000) + tablesAndMeta(1000) + coroutines(500)
end
]],
	},
	{
		name = "arith-100k",
		desc = "100k arithmetic loop",
		iters = 7,
		src = [[ return function() local s = 0 for i = 1, 100000 do s = s + (i * 3 - 1) % 97 end return s end ]],
	},
	{
		name = "fib-24",
		desc = "recursive fib(24)",
		iters = 5,
		src = [[ return function() local function fib(n) if n < 2 then return n end return fib(n - 1) + fib(n - 2) end return fib(24) end ]],
	},
	{
		name = "closures-20k",
		desc = "20k upvalue closures",
		iters = 7,
		src = [[ return function() local total = 0 for i = 1, 20000 do local x = i local function add(y) x += y return x end total += add(2) + add(3) end return total end ]],
	},
	{
		name = "tables-meta-5k",
		desc = "5k metatable & method ops",
		iters = 7,
		src = [[ return function() local mt = {} mt.__index = mt function mt:add(v) return setmetatable({ v = self.v + v }, mt) end mt.__add = function(a, b) return setmetatable({ v = a.v + b.v }, mt) end local acc = setmetatable({ v = 0 }, mt) for i = 1, 5000 do acc = (acc + setmetatable({ v = i }, mt)):add(1) end return acc.v end ]],
	},
	{
		name = "imports-20k",
		desc = "20k math builtins & imports",
		iters = 7,
		src = [[ return function() local s = 0 for i = 1, 20000 do s += math.floor(math.abs(math.sin(i)) * 100) + math.max(i % 7, 3) end return s end ]],
	},
	{
		name = "globals-20k",
		desc = "20k global reads & writes",
		iters = 7,
		src = [[ return function() g = 0 for i = 1, 20000 do g = g + i end return g end ]],
	},
	{
		name = "pcall-2k",
		desc = "2k protected calls (25% throw)",
		iters = 7,
		src = [[ return function() local function f(i) if i % 4 == 0 then error("boom") end return i * 2 end local okc, sum = 0, 0 for i = 1, 2000 do local ok, r = pcall(f, i) if ok then okc += 1 sum += r end end return okc * 1000000 + sum end ]],
	},
	{
		name = "forin-gen-20k",
		desc = "20k ipairs table scans",
		iters = 7,
		src = [[ return function() local t = table.create(200) for i = 1, 200 do t[i] = i end local s = 0 for _ = 1, 100 do for i, v in ipairs(t) do s += i + v end end return s end ]],
	},
	{
		name = "quicksort-2k",
		desc = "quicksort 2,000 numbers",
		iters = 7,
		src = [[ return function() local a = table.create(2000) local x = 12345 for i = 1, 2000 do x = (x * 1103515245 + 12345) % 2147483648 a[i] = x end local function qs(lo, hi) if lo >= hi then return end local p = a[(lo + hi) // 2] local i, j = lo, hi while i <= j do while a[i] < p do i += 1 end while a[j] > p do j -= 1 end if i <= j then a[i], a[j] = a[j], a[i] i += 1 j -= 1 end end if lo < j then qs(lo, j) end if i < hi then qs(i, hi) end end qs(1, 2000) return a[1] + a[1000] + a[2000] end ]],
	},
	{
		name = "string-ops-10k",
		desc = "10k concat & string calls",
		iters = 7,
		src = [[ return function() local s = 0 for i = 1, 10000 do local str = "item_" .. tostring(i) .. "_val" s += #str + (string.byte(str, 6) or 0) + #string.sub(str, 1, 7) end return s end ]],
	},
	{
		name = "varargs-10k",
		desc = "10k vararg select loops",
		iters = 7,
		src = [[ return function() local function sum(...) local n = select("#", ...) local s = 0 for i = 1, n do s += select(i, ...) end return s end local t = 0 for i = 1, 10000 do t += sum(i, i + 1, i + 2, i + 3) end return t end ]],
	},
	{
		name = "table-dict-20k",
		desc = "20k dictionary field ops",
		iters = 7,
		src = [[ return function() local t = { a = 1, b = 2, c = 3, d = 4 } local s = 0 for i = 1, 20000 do t.a = (t.b + i) % 1000 t.b = (t.c + t.a) % 1000 t.c = (t.d + t.b) % 1000 t.d = (t.a + t.c) % 1000 s += t.d end return s end ]],
	},
}

local function makeStdEnv(): { [string]: any }
	return {
		assert = assert,
		error = error,
		getmetatable = getmetatable,
		ipairs = ipairs,
		next = next,
		pairs = pairs,
		pcall = pcall,
		rawequal = rawequal,
		rawget = rawget,
		rawlen = rawlen,
		rawset = rawset,
		select = select,
		setmetatable = setmetatable,
		tonumber = tonumber,
		tostring = tostring,
		type = type,
		unpack = table.unpack,
		xpcall = xpcall,
		bit32 = bit32,
		buffer = buffer,
		coroutine = coroutine,
		math = math,
		string = string,
		table = table,
		utf8 = utf8,
		vector = vector,
	}
end

local function makeFiuSettings(fast: boolean, staticEnv: { [any]: any }?)
	local s = Fiu.luau_newsettings()
	if Vector3 then
		s.vectorCtor = Vector3.new
		s.vectorSize = 3
	elseif vector and vector.create then
		s.vectorCtor = vector.create
		s.vectorSize = 3
	end
	if fast then
		s.errorHandling = false
		s.reuseClosures = true
		if staticEnv ~= nil then
			s.useImportConstants = true
			s.staticEnvironment = staticEnv
		end
	end
	return s
end

local function encodeJson(val: any): string
	local t = type(val)
	if t == "nil" then
		return "null"
	elseif t == "boolean" then
		return if val then "true" else "false"
	elseif t == "number" then
		if val ~= val or val == math.huge or val == -math.huge then
			return "null"
		end
		return string.format("%.6g", val)
	elseif t == "string" then
		local escaped = val:gsub('[%c\\"]', function(ch)
			if ch == "\\" then
				return "\\\\"
			elseif ch == '"' then
				return '\\"'
			elseif ch == "\n" then
				return "\\n"
			elseif ch == "\r" then
				return "\\r"
			elseif ch == "\t" then
				return "\\t"
			end
			return string.format("\\u%04x", string.byte(ch))
		end)
		return '"' .. escaped .. '"'
	elseif t == "table" then
		local n = #val
		local isArray = true
		local count = 0
		for _ in val do
			count += 1
		end
		if count ~= n then
			isArray = false
		elseif n == 0 then
			isArray = false
		end
		if isArray then
			local items = table.create(n)
			for i = 1, n do
				items[i] = encodeJson(val[i])
			end
			return "[" .. table.concat(items, ",") .. "]"
		end
		local keys = {}
		for k in val do
			table.insert(keys, tostring(k))
		end
		table.sort(keys)
		local pairsOut = table.create(#keys)
		for i, k in keys do
			pairsOut[i] = encodeJson(k) .. ":" .. encodeJson(val[k])
		end
		return "{" .. table.concat(pairsOut, ",") .. "}"
	end
	return "null"
end

if verifyMode then
	for _, c in compileCases do
		local bc = assert(Ouro.compile(c.src, { optimizationLevel = 2, debugLevel = 1 }))
		assert(string.byte(bc, 1) ~= 0, "Ouro compile failed on " .. c.name)
		if okLc then
			local lbc = LC.luau_compile(c.src, 2, 1, 0, 0)
			assert(string.byte(lbc, 1) ~= 0, "LC compile failed on " .. c.name)
		end
	end

	local rt10Src = makeCorpus(runtimeUnit, 10 * 1024)
	local rt10Bc = assert(Ouro.compile(rt10Src, { optimizationLevel = 2, debugLevel = 1 }))
	local pm = assert(BytecodeCodec.deserialize(rt10Bc))
	assert(#pm.protos > 0, "deserialize protos empty")
	local rtFn = assert(VM.loadBytecode(rt10Bc))
	assert(type(rtFn) == "function", "loadBytecode did not return function")

	local lcExpectedDNF = 0
	for _, w in vmWorkloads do
		local bc = assert(Ouro.compile(w.src, { optimizationLevel = 2 }))
		local hostLoader = (loadstring :: any) :: (string, string?) -> () -> () -> any
		local hostFn = hostLoader(w.src, "=" .. w.name)()
		local expected = hostFn()

		local ouroChunk = assert(VM.loadBytecode(bc, { name = "=" .. w.name }))
		local ouroFn = (ouroChunk :: any)()
		assert(ouroFn() == expected, w.name .. " Ouro mismatch")

		local guardChunk = assert(VM.loadBytecode(bc, {
			name = "=" .. w.name .. "_guarded",
			instructionLimit = 50_000_000,
		}))
		local guardFn = (guardChunk :: any)()
		assert(guardFn() == expected, w.name .. " Ouro guarded mismatch")

		local isSafe = w.name ~= "globals-20k"
		if okFiu then
			local fiuDefFn = Fiu.luau_load(bc, makeStdEnv(), makeFiuSettings(false, nil))()
			assert(fiuDefFn() == expected, w.name .. " Fiu default mismatch")
			local fiuFastEnv = makeStdEnv()
			local fiuFastFn = Fiu.luau_load(bc, fiuFastEnv, makeFiuSettings(true, if isSafe then fiuFastEnv else nil))()
			assert(fiuFastFn() == expected, w.name .. " Fiu fast mismatch")
		end

		if okLc then
			local okRun, lcErr = pcall(function()
				local lbc = LC.luau_compile(w.src, 2, 1, 0, 0)
				local cfns = LC.wasm.cfns
				local macros = LC.macros
				local cstr = LC.wasm.cstr
				local L = cfns.luaL_newstate()
				cfns.luaL_openlibs(L)
				if isSafe then
					cfns.luaL_sandbox(L)
				end
				local bPtr, cPtr = cstr(lbc), cstr("=" .. w.name)
				assert(cfns.luau_load(L, cPtr, bPtr, #lbc, 0) == 0)
				cfns.free(bPtr)
				cfns.free(cPtr)
				assert(cfns.lua_pcall(L, 0, 1, 0) == 0)
				cfns.lua_pushvalue(L, 1)
				assert(cfns.lua_pcall(L, 0, 1, 0) == 0)
				local v = macros.lua_tonumberx(L, -1)
				macros.lua_pop(L, 1)
				cfns.lua_close(L)
				assert(v == expected, w.name .. " LC mismatch")
			end)
			if not okRun then
				if w.name == "pcall-2k" and not string.find(tostring(lcErr), "LC mismatch", 1, true) then
					lcExpectedDNF += 1
				else
					error(tostring(lcErr))
				end
			end
		end
	end

	local coldSrc = "local s = 0; for i = 1, 1000 do s += i end; return s"
	local coldBc = assert(Ouro.compile(coldSrc, { optimizationLevel = 2 }))
	local coldOuroFn = assert(VM.loadBytecode(coldBc, { name = "=cold" }))
	assert((coldOuroFn :: any)() == 500500, "cold-load-run Ouro mismatch")
	if okFiu then
		assert(
			Fiu.luau_load(coldBc, makeStdEnv(), makeFiuSettings(false, nil))() == 500500,
			"cold Fiu default mismatch"
		)
		local env = makeStdEnv()
		assert(Fiu.luau_load(coldBc, env, makeFiuSettings(true, env))() == 500500, "cold Fiu fast mismatch")
	end
	if okLc then
		local coldLbc = LC.luau_compile(coldSrc, 2, 1, 0, 0)
		assert(LC.luau_run(coldLbc, "=cold", true))
	end

	if jsonMode then
		print(encodeJson({
			status = "ok",
			competitors = { fiu = okFiu, luauception = okLc },
			checked = {
				compile = #compileCases,
				deserialize = 1,
				vm = #vmWorkloads,
				cold = 1,
				lcExpectedDNF = lcExpectedDNF,
			},
		}))
	else
		print(
			string.format("verify ok (compile=%d, vm=%d, lcExpectedDNF=%d)", #compileCases, #vmWorkloads, lcExpectedDNF)
		)
	end
	return
end

local vmResults = {}
for _, w in vmWorkloads do
	local bc = assert(Ouro.compile(w.src, { optimizationLevel = 2 }))
	local hostLoader = (loadstring :: any) :: (string, string?) -> () -> () -> any
	local hostFn = hostLoader(w.src, "=" .. w.name)()
	local expected = hostFn()

	local ouroChunk = assert(VM.loadBytecode(bc, { name = "=" .. w.name }))
	local ouroFn = (ouroChunk :: any)()
	assert(ouroFn() == expected, w.name .. " Ouro mismatch")

	local guardChunk = assert(VM.loadBytecode(bc, {
		name = "=" .. w.name .. "_guarded",
		instructionLimit = 50_000_000,
	}))
	local guardFn = (guardChunk :: any)()
	assert(guardFn() == expected, w.name .. " Ouro guarded mismatch")

	local hostP50, hostMin = bench(w.iters, 2, function()
		hostFn()
	end)
	local ouroP50, ouroMin = bench(w.iters, 2, function()
		ouroFn()
	end)
	for _ = 1, 2 do
		guardFn()
	end
	VM.resetBudget(guardChunk)
	local guardTimes = table.create(w.iters)
	for i = 1, w.iters do
		local t0 = nowMs()
		guardFn()
		guardTimes[i] = nowMs() - t0
	end
	local guardP50, guardMin = sampleStats(guardTimes)

	local row: { [string]: any } = {
		name = w.name,
		desc = w.desc,
		host = { status = "ok", p50Ms = hostP50, minMs = hostMin },
		ouro = { status = "ok", p50Ms = ouroP50, minMs = ouroMin },
		ouro_guarded = { status = "ok", p50Ms = guardP50, minMs = guardMin },
	}

	local isSafe = w.name ~= "globals-20k"
	if okFiu then
		local fiuDefFn = Fiu.luau_load(bc, makeStdEnv(), makeFiuSettings(false, nil))()
		assert(fiuDefFn() == expected, w.name .. " Fiu default mismatch")
		local fiuFastEnv = makeStdEnv()
		local fiuFastFn = Fiu.luau_load(bc, fiuFastEnv, makeFiuSettings(true, if isSafe then fiuFastEnv else nil))()
		assert(fiuFastFn() == expected, w.name .. " Fiu fast mismatch")
		local fiuDefP50, fiuDefMin = bench(w.iters, 1, function()
			fiuDefFn()
		end)
		local fiuFastP50, fiuFastMin = bench(w.iters, 1, function()
			fiuFastFn()
		end)
		row.fiu_default = { status = "ok", p50Ms = fiuDefP50, minMs = fiuDefMin }
		row.fiu_fast = { status = "ok", p50Ms = fiuFastP50, minMs = fiuFastMin }
	end

	if okLc then
		local okRun, lcP50OrErr, lcMin = pcall(function(): (number, number)
			local lbc = LC.luau_compile(w.src, 2, 1, 0, 0)
			local cfns = LC.wasm.cfns
			local macros = LC.macros
			local cstr = LC.wasm.cstr
			local L = cfns.luaL_newstate()
			cfns.luaL_openlibs(L)
			if isSafe then
				cfns.luaL_sandbox(L)
			end
			local bPtr, cPtr = cstr(lbc), cstr("=" .. w.name)
			assert(cfns.luau_load(L, cPtr, bPtr, #lbc, 0) == 0)
			cfns.free(bPtr)
			cfns.free(cPtr)
			assert(cfns.lua_pcall(L, 0, 1, 0) == 0)
			local function callLc(): any
				cfns.lua_pushvalue(L, 1)
				assert(cfns.lua_pcall(L, 0, 1, 0) == 0)
				local v = macros.lua_tonumberx(L, -1)
				macros.lua_pop(L, 1)
				return v
			end
			assert(callLc() == expected, w.name .. " LC mismatch")
			local p50, mn = bench(w.iters, 1, function()
				callLc()
			end)
			cfns.lua_close(L)
			return p50, mn
		end)
		if okRun then
			row.luauception = { status = "ok", p50Ms = lcP50OrErr, minMs = lcMin }
		else
			row.luauception = { status = "error", error = firstLine(lcP50OrErr) }
		end
	end

	table.insert(vmResults, row)
end

-- 4. Cold Load + Run (fresh environment / state per call, 1k arithmetic loop)
local coldSrc = "local s = 0; for i = 1, 1000 do s += i end; return s"
local coldBc = assert(Ouro.compile(coldSrc, { optimizationLevel = 2 }))
local coldOuroP50, coldOuroMin = bench(9, 2, function()
	local fn = assert(VM.loadBytecode(coldBc, { name = "=cold" }))
	assert((fn :: any)() == 500500)
end)
local coldResults: { [string]: any } = {
	name = "cold-load-run",
	desc = "fresh env + 1k loop",
	ouro = { status = "ok", p50Ms = coldOuroP50, minMs = coldOuroMin },
}
if okFiu then
	local coldFiuDefOpts = makeFiuSettings(false, nil)
	local coldFiuDefP50, coldFiuDefMin = bench(9, 2, function()
		local fn = Fiu.luau_load(coldBc, makeStdEnv(), coldFiuDefOpts)
		assert(fn() == 500500)
	end)
	local coldFiuFastP50, coldFiuFastMin = bench(9, 2, function()
		local env = makeStdEnv()
		local fn = Fiu.luau_load(coldBc, env, makeFiuSettings(true, env))
		assert(fn() == 500500)
	end)
	coldResults.fiu_default = { status = "ok", p50Ms = coldFiuDefP50, minMs = coldFiuDefMin }
	coldResults.fiu_fast = { status = "ok", p50Ms = coldFiuFastP50, minMs = coldFiuFastMin }
end
if okLc then
	local coldLbc = LC.luau_compile(coldSrc, 2, 1, 0, 0)
	local coldLcP50, coldLcMin = bench(9, 2, function()
		assert(LC.luau_run(coldLbc, "=cold", true))
	end)
	coldResults.luauception = { status = "ok", p50Ms = coldLcP50, minMs = coldLcMin }
end

if jsonMode then
	print(encodeJson({
		competitors = { fiu = okFiu, luauception = okLc },
		compile = compileResults,
		deserialize = deserializeResults,
		vm = vmResults,
		cold_load_run = coldResults,
	}))
else
	print("=== O2 COMPILATION (p50 ms) ===")
	for _, r in compileResults do
		local line = string.format(
			"%-15s | %6d B -> %5d B bc | Lex %5.2f | Parse %5.2f | Ouro FullO2 %6.3f ms",
			r.name,
			r.bytes,
			r.bytecodeBytes,
			r.lex_p50_ms,
			r.parse_p50_ms,
			r.ouro.p50Ms
		)
		if r.luauception then
			line ..= string.format(" | LC %7.3f ms (%.2fx)", r.luauception.p50Ms, r.luauception.p50Ms / r.ouro.p50Ms)
		end
		print(line)
	end

	print("\n=== BYTECODE DESERIALIZE & loadBytecode (p50 ms) ===")
	for _, r in deserializeResults do
		print(
			string.format(
				"%-15s | %6d B | deserialize %6.3f ms | loadBytecode %6.3f ms",
				r.name,
				r.bytecodeBytes,
				r.deserialize.p50Ms,
				r.loadBytecode.p50Ms
			)
		)
	end

	print("\n=== WARM VM EXECUTION (p50 ms, O2) ===")
	for _, r in vmResults do
		local line = string.format(
			"%-15s | Host %7.4f | Ouro %7.3f | Guard %7.3f",
			r.name,
			r.host.p50Ms,
			r.ouro.p50Ms,
			r.ouro_guarded.p50Ms
		)
		if r.fiu_fast then
			line ..= string.format(" | FiuFast %7.3f", r.fiu_fast.p50Ms)
		end
		if r.luauception then
			if r.luauception.status == "ok" then
				line ..= string.format(" | LC %8.3f", r.luauception.p50Ms)
			else
				line ..= " | LC    ERROR"
			end
		end
		print(line)
	end

	print("\n=== COLD LOAD + RUN (1k loop, p50 ms) ===")
	local coldLine = string.format("Ouro %6.3f ms", coldResults.ouro.p50Ms)
	if coldResults.fiu_fast then
		coldLine ..= string.format(" | FiuFast %6.3f ms", coldResults.fiu_fast.p50Ms)
	end
	if coldResults.luauception then
		coldLine ..= string.format(" | LC %6.3f ms", coldResults.luauception.p50Ms)
	end
	print(coldLine)
end
