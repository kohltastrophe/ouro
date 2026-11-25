--!strict
local BytecodeBuilder = require("../src/BytecodeBuilder")
local BytecodeCodec = require("../src/BytecodeCodec")
local BytecodeDefs = require("../src/BytecodeDefs")
local Helpers = require("./Helpers")
local Parser = require("../")
local VM = require("../src/VM")
local sert = require("@sert") :: any

local Opcodes = BytecodeDefs.Opcodes
local Tags = BytecodeDefs.Tags

local describe = sert.describe
local test = sert.test
local expect = sert
local gen = sert.gen
local laws = sert.laws

local function drainWeak(weakTbl: { [number]: any }, count: number)
	for _batch = 1, 15 do
		for _ = 1, 10000 do
			local _pressure = table.create(64, 1)
		end
		local cleared = true
		for i = 1, count do
			if weakTbl[i] ~= nil then
				cleared = false
				break
			end
		end
		if cleared then
			return
		end
	end
end

local function runAtAllOptLevels(source: string, env: { [any]: any }?, ...: any): ...any
	local firstResults: { any }? = nil
	local firstCount = 0
	for _, opt in { 0, 1, 2 } do
		local res = Parser.compileResult(source, { optimizationLevel = opt })
		assert(res.status == "ok", res.error or "compile failed")
		local fnFromBc, errBc = VM.loadBytecode(res.bytecode, { name = "=vmtest", env = env })
		assert(fnFromBc, errBc)
		local protoMod = assert(res.builder, "missing builder"):toProtoModule()
		local fnFromProto, errProto = VM.loadProto(protoMod, { name = "=vmtest", env = env })
		assert(fnFromProto, errProto)

		local r1 = table.pack(fnFromBc(...))
		local r2 = table.pack(fnFromProto(...))
		sert.eq(r1.n, r2.n)
		for i = 1, r1.n do
			expect(Helpers.sameValue(r1[i], r2[i]), `bytecode vs proto mismatch at #{i}`)
		end

		if firstResults == nil then
			firstResults = r1
			firstCount = r1.n
		else
			sert.eq(r1.n, firstCount)
			for i = 1, firstCount do
				expect(Helpers.sameValue(r1[i], firstResults[i]), `opt level {opt} mismatch at #{i}`)
			end
		end
	end
	return table.unpack(firstResults :: { any }, 1, firstCount)
end

describe("VM", function()
	test("loads source strings, binary bytecode, and ProtoModules", function()
		local fn1, err1 = Parser.load("local a, b = ...; return a + b", { name = "=add" })
		expect(fn1 ~= nil and err1 == nil, "loaded from source")
		sert.eq((fn1 :: any)(19, 23), 42)

		local bc = assert(Parser.compile("return 'ok'"))
		local fn2, err2 = Parser.load(bc, { name = "=bc", mode = "binary" })
		expect(fn2 ~= nil and err2 == nil, "loaded from bytecode")
		sert.eq((fn2 :: any)(), "ok")

		local badFn, badErr = Parser.load("local x =", { name = "=bad" })
		sert.eq(badFn, nil)
		expect(badErr ~= nil and string.find(badErr, ":1:", 1, true) ~= nil, "reports parse error")
	end)

	test("executes arithmetic, relational jumps, logical ops, and string interpolation across O0/O1/O2", function()
		local a, b, c, d = runAtAllOptLevels(
			[[
			local x, y = ...
			local cmp = if x == 10 then "ten" elseif x < 10 then "lt" else "gt"
			local logic = (nil or false or (x and y))
			local arith = (100 - x) / 2 + (x // 3) * (y % 5) + 2 ^ 3
			local interp = `x={x}, cmp={cmp}, logic={logic}`
			return cmp, logic, arith, interp
		]],
			nil,
			10,
			7
		)
		sert.eq(a, "ten")
		sert.eq(b, 7)
		sert.eq(c, 59)
		sert.eq(d, "x=10, cmp=ten, logic=7")
	end)

	test("handles open/closed upvalues, per-iteration loop closures, and recursive local functions", function()
		local sum, fib10, counterVal = runAtAllOptLevels([[
			local closures = {}
			for i = 1, 5 do
				local captured = i * 10
				closures[i] = function(add)
					captured += add
					return captured
				end
			end

			local total = 0
			for i = 1, 5 do
				total += closures[i](i)
			end

			local function fib(n)
				if n <= 1 then
					return n
				end
				return fib(n - 1) + fib(n - 2)
			end

			local function makeCounter(start)
				local count = start
				local function inc(step)
					count += step
					return function()
						return count
					end
				end
				return inc
			end
			local inc = makeCounter(100)
			local reader = inc(23)

			return total, fib(10), reader()
		]])
		sert.eq(sum, 11 + 22 + 33 + 44 + 55)
		sert.eq(fib10, 55)
		sert.eq(counterVal, 123)
	end)

	test("supports varargs, select, and multi-return calls in tables, arguments, and returns", function()
		local n, s2, tLen, t4 = runAtAllOptLevels([[
			local function tail(...)
				return ...
			end
			local function collect(first, ...)
				local count = select("#", ...)
				local second = select(2, ...)
				local tbl = { first, tail(...) }
				return count, second, #tbl, tbl[4]
			end
			return collect("a", "b", "c", "d")
		]])
		sert.eq(n, 3)
		sert.eq(s2, "c")
		sert.eq(tLen, 4)
		sert.eq(t4, "d")
	end)

	test("supports generalized iteration, pairs, ipairs, next, and __iter metamethods", function()
		local genSum, ipairsSum, pairsSum, metaSum = runAtAllOptLevels([[
			local arr = { 10, 20, 30, 40 }
			local s1 = 0
			for idx, val in arr do
				s1 += idx * val
			end

			local s2 = 0
			for idx, val in ipairs(arr) do
				if idx == 3 then
					continue
				end
				s2 += val
			end

			local dict = { a = 3, b = 7, c = 11 }
			local s3 = 0
			for _, val in pairs(dict) do
				s3 += val
			end

			local custom = setmetatable({ items = { 5, 15, 25 } }, {
				__iter = function(self)
					local i = 0
					return function()
						i += 1
						if i <= #self.items then
							return i, self.items[i]
						end
						return nil
					end
				end,
			})
			local s4 = 0
			for i, v in custom do
				s4 += i + v
			end

			return s1, s2, s3, s4
		]])
		sert.eq(genSum, 1 * 10 + 2 * 20 + 3 * 30 + 4 * 40)
		sert.eq(ipairsSum, 10 + 20 + 40)
		sert.eq(pairsSum, 21)
		sert.eq(metaSum, (1 + 5) + (2 + 15) + (3 + 25))
	end)

	test("executes builtin fastcalls and falls back when custom environment overrides globals", function()
		local fastResult, fastU16 = runAtAllOptLevels(
			[[
			local v, lo, hi, r, pos, bits = ...
			local x = math.clamp(v, lo, hi)
			local y = bit32.replace(0, r, pos, 3)
			local z = bit32.extract(y, pos, 3)
			local b = buffer.create(8)
			buffer.writeu32(b, 0, bits)
			local u = buffer.readu16(b, 2)
			return x + z, u
		]],
			nil,
			15,
			0,
			10,
			0b101,
			2,
			0x12345678
		)
		sert.eq(fastResult, 15)
		sert.eq(fastU16, 0x1234)

		-- Custom environment overriding `math.abs`: fastcall must fall back to custom `env.math.abs`
		local customEnv = VM.createEnvironment({
			math = {
				abs = function(v: number)
					return v * 100
				end,
			},
		})
		local overridden = runAtAllOptLevels(
			[[
			local arg = ...
			local function compute(n)
				return math.abs(n)
			end
			return compute(arg)
		]],
			customEnv,
			-7
		)
		sert.eq(overridden, -700)
	end)

	test("supports coroutines yielding across VM frames and line-accurate runtime errors", function()
		local y1, y2, y3 = runAtAllOptLevels([[
			local function helper(v)
				return coroutine.yield(v * 2)
			end
			local co = coroutine.create(function(start)
				local r1 = helper(start)
				local r2 = helper(r1 + 1)
				return r2 + 100
			end)
			local _, a = coroutine.resume(co, 5)
			local _, b = coroutine.resume(co, a + 3)
			local _, c = coroutine.resume(co, b * 2)
			return a, b, c
		]])
		sert.eq(y1, 10)
		sert.eq(y2, 28)
		sert.eq(y3, 156)

		local fn = assert(Parser.load("local a = 1\nlocal b = nil\nreturn a + b", { name = "=linecheck" }))
		local ok, err = pcall(fn)
		sert.eq(ok, false)
		expect(string.find(tostring(err), "linecheck:3:", 1, true) ~= nil, "error includes chunkname and line 3")
	end)

	sert.prop("evaluates polynomial expressions identically across O0, O1, O2, and host Luau", function(g)
		local a: number = g:draw(gen.int(-20, 20))
		local b: number = g:draw(gen.int(-20, 20))
		local c: number = g:draw(gen.int(-20, 20))
		local src = [[
				local x, y, z = ...
				local acc = 0
				for i = 1, 3 do
					acc += (x * i - y) + z * (i + 1)
				end
				return acc
			]]
		local expected = 0
		for i = 1, 3 do
			expected += (a * i - b) + c * (i + 1)
		end
		local actual = runAtAllOptLevels(src, nil, a, b, c)
		sert.eq(actual, expected)
	end, { runs = 35 })

	-- Recursive AST generator + direct Luau oracle for differential compiler+VM laws
	type ExprNode = {
		kind: "var" | "lit" | "unop" | "binop" | "ifelse",
		varIdx: number?,
		val: number?,
		op: string?,
		left: ExprNode?,
		right: ExprNode?,
		condOp: string?,
		condLeft: ExprNode?,
		condRight: ExprNode?,
	}

	local function genExprAst(g: any, depth: number): ExprNode
		if depth <= 0 or g:bool(0.35) then
			if g:bool(0.6) then
				return { kind = "var", varIdx = g:int(1, 3) }
			else
				return { kind = "lit", val = gen.boundaryInt(-50, 50)(g) }
			end
		end
		local choice = g:int(1, 5)
		if choice == 1 then
			return { kind = "unop", op = "-", left = genExprAst(g, depth - 1) }
		elseif choice == 2 then
			return {
				kind = "ifelse",
				condOp = g:pick({ "<", "<=", "==", "~=" }),
				condLeft = genExprAst(g, depth - 1),
				condRight = genExprAst(g, depth - 1),
				left = genExprAst(g, depth - 1),
				right = genExprAst(g, depth - 1),
			}
		else
			return {
				kind = "binop",
				op = g:pick({ "+", "-", "*", "/", "//", "%" }),
				left = genExprAst(g, depth - 1),
				right = genExprAst(g, depth - 1),
			}
		end
	end

	local function exprToSource(node: ExprNode): string
		if node.kind == "var" then
			return `x{node.varIdx}`
		elseif node.kind == "lit" then
			local v = node.val :: number
			return if v < 0 then `({v})` else tostring(v)
		elseif node.kind == "unop" then
			return `(-({exprToSource(node.left :: ExprNode)}))`
		elseif node.kind == "ifelse" then
			local cl = exprToSource(node.condLeft :: ExprNode)
			local cr = exprToSource(node.condRight :: ExprNode)
			local tb = exprToSource(node.left :: ExprNode)
			local fb = exprToSource(node.right :: ExprNode)
			return `(if ({cl}) {node.condOp} ({cr}) then ({tb}) else ({fb}))`
		else
			local l = exprToSource(node.left :: ExprNode)
			local r = exprToSource(node.right :: ExprNode)
			return `(({l}) {node.op} ({r}))`
		end
	end

	local function evalExprOracle(node: ExprNode, vars: { number }): number
		if node.kind == "var" then
			return vars[node.varIdx :: number]
		elseif node.kind == "lit" then
			return node.val :: number
		elseif node.kind == "unop" then
			return -evalExprOracle(node.left :: ExprNode, vars)
		elseif node.kind == "ifelse" then
			local cl = evalExprOracle(node.condLeft :: ExprNode, vars)
			local cr = evalExprOracle(node.condRight :: ExprNode, vars)
			local cond = if node.condOp == "<"
				then cl < cr
				elseif node.condOp == "<=" then cl <= cr
				elseif node.condOp == "==" then cl == cr
				else cl ~= cr
			return if cond
				then evalExprOracle(node.left :: ExprNode, vars)
				else evalExprOracle(node.right :: ExprNode, vars)
		else
			local l = evalExprOracle(node.left :: ExprNode, vars)
			local r = evalExprOracle(node.right :: ExprNode, vars)
			local op = node.op
			if op == "+" then
				return l + r
			elseif op == "-" then
				return l - r
			elseif op == "*" then
				return l * r
			elseif op == "/" then
				return l / r
			elseif op == "//" then
				return l // r
			else
				return l % r
			end
		end
	end

	laws.differential("compiled arithmetic & conditional AST expressions vs Luau oracle", {
		gen = function(g: any)
			return {
				ast = genExprAst(g, 3),
				x1 = gen.boundaryFloat(-1000, 1000)(g),
				x2 = gen.boundaryInt(-1000, 1000)(g),
				x3 = gen.boundaryFloat(-100, 100)(g),
			}
		end,
		sut = function(inp: any): number
			local src = `local x1, x2, x3 = ...; return {exprToSource(inp.ast)}`
			return (runAtAllOptLevels(src, nil, inp.x1, inp.x2, inp.x3)) :: number
		end,
		oracle = function(inp: any): number
			return evalExprOracle(inp.ast, { inp.x1, inp.x2, inp.x3 })
		end,
		eq = Helpers.sameValue,
	}, { runs = 100 })

	laws.differential("compiled bitwise and boolean logic vs Luau oracle", {
		gen = function(g)
			return {
				a = gen.boundaryInt()(g),
				b = gen.boundaryInt()(g),
				sh = g:int(-35, 35),
				f = g:int(0, 15),
				w = g:int(1, 16),
				b1 = g:bool(),
				b2 = g:bool(),
			}
		end,
		sut = function(inp)
			local src = [[
				local a, b, sh, f, w, b1, b2 = ...
				local r1 = bit32.bxor(bit32.band(a, b), bit32.bor(a, bit32.bnot(b)))
				local r2 = bit32.lshift(a, sh) + bit32.rshift(b, sh) + bit32.arshift(a, sh)
				local r3 = bit32.lrotate(a, sh) - bit32.rrotate(b, sh)
				local r4 = bit32.extract(a, f, w)
				local r5 = bit32.replace(a, b, f, w)
				local r6 = bit32.countlz(a) + bit32.countrz(b) + bit32.byteswap(a)
				local r7 = bit32.btest(a, b)
				local r8 = (b1 and not b2) or (not b1 and b2)
				return r1, r2, r3, r4, r5, r6, r7, r8
			]]
			return table.pack(runAtAllOptLevels(src, nil, inp.a, inp.b, inp.sh, inp.f, inp.w, inp.b1, inp.b2))
		end,
		oracle = function(inp)
			local a, b, sh, f, w, b1, b2 = inp.a, inp.b, inp.sh, inp.f, inp.w, inp.b1, inp.b2
			local r1 = bit32.bxor(bit32.band(a, b), bit32.bor(a, bit32.bnot(b)))
			local r2 = bit32.lshift(a, sh) + bit32.rshift(b, sh) + bit32.arshift(a, sh)
			local r3 = bit32.lrotate(a, sh) - bit32.rrotate(b, sh)
			local r4 = bit32.extract(a, f, w)
			local r5 = bit32.replace(a, b, f, w)
			local r6 = bit32.countlz(a) + bit32.countrz(b) + bit32.byteswap(a)
			local r7 = bit32.btest(a, b)
			local r8 = (b1 and not b2) or (not b1 and b2)
			return table.pack(r1, r2, r3, r4, r5, r6, r7, r8)
		end,
		eq = function(got: any, want: any)
			local n: number = got.n
			if n ~= want.n then
				return false
			end
			for i = 1, n do
				if not Helpers.sameValue(got[i], want[i]) then
					return false
				end
			end
			return true
		end,
	}, { runs = 100 })

	laws.differential("compiled table constructors, sparse tables, and string operations vs Luau oracle", {
		gen = function(g)
			return {
				v1 = gen.boundaryInt(-500, 500)(g),
				v2 = gen.boundaryInt(-500, 500)(g),
				s1 = g:string("abcdef0123", 0, 12),
				s2 = g:string("xyz_", 0, 8),
				subStart = gen.boundaryInt(-15, 15)(g),
				subEnd = gen.boundaryInt(-15, 15)(g),
				sparse = gen.sparseTable(gen.boundaryInt(-50, 50))(g),
			}
		end,
		sut = function(inp)
			local src = [[
				local v1, v2, s1, s2, i, j, sparse = ...
				local t = { v1, v2, key = s1, [v1] = s2, nested = { a = v1 + v2 } }
				local cat = `{s1}:{s2}:{v1}` .. string.sub(s1, i, j)
				local sum = #t + t.nested.a + #cat + string.len(s2)
				for _, sv in pairs(sparse) do
					if type(sv) == "number" then
						sum += sv
					end
				end
				return cat, sum, t[1], t.key, t[v1], s1 < s2, s1 == s2
			]]
			return table.pack(
				runAtAllOptLevels(src, nil, inp.v1, inp.v2, inp.s1, inp.s2, inp.subStart, inp.subEnd, inp.sparse)
			)
		end,
		oracle = function(inp: any)
			local v1: number, v2: number, s1: string, s2: string, i: number, j: number, sparse: { [any]: any } =
				inp.v1, inp.v2, inp.s1, inp.s2, inp.subStart, inp.subEnd, inp.sparse
			local t: { [any]: any } = { [1] = v1, [2] = v2, key = s1, [v1] = s2, nested = { a = v1 + v2 } }
			local cat = `{s1}:{s2}:{v1}` .. string.sub(s1, i, j)
			local sum = #t + t.nested.a + #cat + string.len(s2)
			for _, sv in pairs(sparse) do
				if type(sv) == "number" then
					sum += sv
				end
			end
			return table.pack(cat, sum, t[1], t.key, t[v1], s1 < s2, s1 == s2)
		end,
		eq = function(got: any, want: any)
			local n: number = got.n
			if n ~= want.n then
				return false
			end
			for i = 1, n do
				if not Helpers.sameValue(got[i], want[i]) then
					return false
				end
			end
			return true
		end,
	}, { runs = 80 })

	laws.differential("compiled control flow, loops, closures, and upvalues vs Luau oracle", {
		gen = function(g)
			return {
				startVal = gen.boundaryInt(-100, 100)(g),
				limit = g:int(1, 8),
				skipAt = g:int(1, 8),
				stopAt = g:int(1, 10),
				mult = gen.boundaryInt(-20, 20)(g),
			}
		end,
		sut = function(inp)
			local src = [[
				local startVal, limit, skipAt, stopAt, mult = ...
				local acc = startVal
				local closures = {}
				for i = 1, limit do
					local localStep = i * mult
					closures[i] = function(delta)
						localStep += delta
						acc += localStep
						return localStep
					end
				end
				local k = 1
				while k <= limit do
					if k == skipAt then
						k += 1
						continue
					elseif k == stopAt then
						break
					end
					closures[k](k)
					k += 1
				end
				local rep = 0
				repeat
					rep += 1
					acc += rep
				until rep >= 3
				return acc, rep, k
			]]
			return table.pack(runAtAllOptLevels(src, nil, inp.startVal, inp.limit, inp.skipAt, inp.stopAt, inp.mult))
		end,
		oracle = function(inp: any)
			local startVal: number, limit: number, skipAt: number, stopAt: number, mult: number =
				inp.startVal, inp.limit, inp.skipAt, inp.stopAt, inp.mult
			local acc = startVal
			local closures: { [number]: (number) -> number } = {}
			for i = 1, limit do
				local localStep = i * mult
				closures[i] = function(delta: number): number
					localStep += delta
					acc += localStep
					return localStep
				end
			end
			local k = 1
			while k <= limit do
				if k == skipAt then
					k += 1
					continue
				elseif k == stopAt then
					break
				end
				closures[k](k)
				k += 1
			end
			local rep = 0
			repeat
				rep += 1
				acc += rep
			until rep >= 3
			return table.pack(acc, rep, k)
		end,
		eq = function(got, want)
			return got[1] == want[1] and got[2] == want[2] and got[3] == want[3]
		end,
	}, { runs = 80 })

	local vmXorFn = assert(Parser.load("local a, b = ...; return bit32.bxor(a, b)", { name = "=xor" }))
	laws.algebra("VM bit32.bxor abelian group", {
		gen = gen.map(gen.boundaryInt(0, 0x7fffffff), function(n)
			return bit32.band(n, 0xffffffff)
		end),
		op = function(a: number, b: number): number
			return vmXorFn(a, b)
		end,
		identity = 0,
		associative = true,
		commutative = true,
		inverse = function(a: number): number
			return a
		end,
	}, { runs = 60 })

	test("executes remaining VM fastcalls, vector/buffer ops, RK arithmetic, vararg select, and generic for", function()
		local r1, r2, r3, r4, r5, r6, r7 = runAtAllOptLevels(
			[[
			local x, y, modfArg, f32Val, f64Val = ...
			-- assert, type, typeof, rawget, rawset, rawequal, rawlen, tonumber, tostring, getmetatable, setmetatable
			local a1 = assert(x, "ok")
			local m, e = math.frexp(x)
			local i, f = math.modf(modfArg)
			local l1 = math.log(x) + math.log(x, y) + math.atan2(x, y) + math.ldexp(m, e)
			local ex = bit32.extract(255, y) + bit32.extract(255, y, 2)
			local rp = bit32.replace(0, 1, y) + bit32.replace(0, 3, y, 2)
			local sb = string.byte("XYZ") + string.byte("XYZ", y)
			local sc = string.char(65) .. string.char(66, 67) .. string.char(68, 69, 70)
			local ss = string.sub(sc, y, 4)

			local t = { 10, 20 }
			table.insert(t, 30)
			local u1, u2, u3 = table.unpack(t, 1, 3)
			rawset(t, 4, 40)
			local rg = rawget(t, 4) + (if rawequal(u1, 10) then rawlen(t) else 0)

			-- Vector fastcalls
			local v1 = vector.create(3, 4, 5)
			local v2 = vector.create(1, 2, 2)
			local vm = vector.magnitude(v1) + vector.dot(v1, v2)
			local vc = vector.cross(v1, v2) + vector.normalize(v1) + vector.floor(v1) + vector.ceil(v2)
			local va = vector.abs(-v1) + vector.sign(v1) + vector.min(v1, v2) + vector.max(v1, v2)
			local vcl = vector.clamp(v1, v2, v1) + vector.lerp(v1, v2, 0.5)

			-- Buffer fastcalls
			local buf = buffer.create(32)
			buffer.writei8(buf, 0, -5)
			buffer.writeu8(buf, 1, 200)
			buffer.writei16(buf, 2, -1000)
			buffer.writeu16(buf, 4, 50000)
			buffer.writei32(buf, 8, -100000)
			buffer.writeu32(buf, 12, 3000000000)
			buffer.writef32(buf, 16, f32Val)
			buffer.writef64(buf, 24, f64Val)
			local bsum = buffer.readi8(buf, 0) + buffer.readu8(buf, 1) + buffer.readi16(buf, 2) + buffer.readu16(buf, 4)
				+ buffer.readi32(buf, 8) + buffer.readu32(buf, 12) + buffer.readf32(buf, 16) + buffer.readf64(buf, 24)

			-- RK arithmetic (SUBRK, DIVRK), POWK, ANDK, ORK, negative select, 3-var generic for
			local rk = (100 - x) + (100 / x) + (x ^ 3)
			local ak = (x and 99) + (false or 11)
			local function negSel(...)
				return select(-1, ...)
			end
			local ns = negSel(10, 20, 30)

			local triSum = 0
			local function triIter(st, k)
				if k == nil then
					return 1, 10, 100
				end
				return nil
			end
			for k1, k2, k3 in triIter, nil, nil do
				triSum += k1 + k2 + k3
			end

			return a1 + i + f + ex + rp + sb + rg, sc .. ss, u1 + u2 + u3, vm + vc.x + va.x + vcl.x, bsum, rk + ak + ns + triSum, l1
		]],
			nil,
			8,
			2,
			3.75,
			1.5,
			2.25
		)
		local hv1 = vector.create(3, 4, 5)
		local hv2 = vector.create(1, 2, 2)
		local hvm = vector.magnitude(hv1) + vector.dot(hv1, hv2)
		local hvc = vector.cross(hv1, hv2) + vector.normalize(hv1) + vector.floor(hv1) + vector.ceil(hv2)
		local hva = vector.abs(-hv1) + vector.sign(hv1) + vector.min(hv1, hv2) + vector.max(hv1, hv2)
		local hvcl = vector.clamp(hv1, hv2, hv1) + vector.lerp(hv1, hv2, 0.5)
		local expectedR4 = hvm + hvc.x + hva.x + hvcl.x
		local hm, he = math.frexp(8)
		local expectedR7 = math.log(8) + math.log(8, 2) + math.atan2(8, 2) + math.ldexp(hm, he)
		sert.eq(r1, 8 + 3 + 0.75 + 4 + 16 + (88 + 89) + (40 + 4))
		sert.eq(r2, "ABCDEFBCD")
		sert.eq(r3, 60)
		expect(math.abs(r4 - expectedR4) <= 1e-6, `vector result {r4} ~= {expectedR4}`)
		sert.eq(r5, -5 + 200 - 1000 + 50000 - 100000 + 3000000000 + 1.5 + 2.25)
		sert.eq(r6, (92 + 12.5 + 512) + (99 + 11) + 30 + (1 + 10 + 100))
		expect(math.abs(r7 - expectedR7) <= 1e-12, `math log/atan2/ldexp {r7} ~= {expectedR7}`)
	end)

	test("enforces coverage fastcall error paths, chunknames, and numeric-for runtime type checks", function()
		-- Non- =/@ chunkname formatting
		local fnChunk = assert(Parser.load("return 1", { name = "plain_chunk" }))
		sert.eq(fnChunk(), 1)

		-- Coverage opcode, global set/get, and fastcall error paths while safeenv is true
		local covRes = Parser.compileResult(
			[[
			local a, b, c = ...
			local mt = {}
			local tbl = setmetatable({ 10, 20 }, mt)
			local gm = getmetatable(tbl) == mt
			local tn = tonumber("42")
			local ts = tostring(42)
			local mx3 = math.max(a, b, c)
			local mn3 = math.min(a, b, c)
			local function varSel(idx, ...)
				return select(idx, ...)
			end
			local vs = varSel(-1, 10, 20, 30)
			local ipSum = 0
			for i, v, extra in ipairs({ 10, 20 }) do
				ipSum += i + v
			end
			local function quadIter(st, k)
				if k == nil then
					return 1, 2, 3, 4
				end
				return nil
			end
			for k1, k2, k3, k4 in quadIter, nil, nil do
				ipSum += k1 + k2 + k3 + k4
			end
			local badArg: any = "not_num"
			local errChecks = {
				function() return string.byte({}) end,
				function() return string.char(999) end,
				function() return string.len({}) end,
				function() return string.sub({}, 1) end,
				function() return rawset({}, nil, 1) end,
				function() return rawget(123, 1) end,
				function() return rawlen(123) end,
				function() return assert(false) end,
				function() return math.abs(badArg) end,
				function() return math.atan2(badArg, 1) end,
				function() return math.clamp(badArg, 0, 1) end,
				function() return math.max(badArg, 1) end,
				function() return math.frexp(badArg) end,
				function() return math.log(badArg) end,
				function() return math.modf(badArg) end,
				function() return bit32.extract(1, 50) end,
				function() return bit32.extract(badArg, 1) end,
				function() return bit32.replace(1, 1, 50) end,
				function() return vector.abs(badArg) end,
				function() return vector.dot(badArg, badArg) end,
				function() return buffer.readu8(badArg, 0) end,
				function() return buffer.writeu8(badArg, 0, 1) end,
			}
			local errMsgs = {}
			for idx = 1, #errChecks do
				local ok, err = pcall(errChecks[idx])
				errMsgs[idx] = { ok = ok, err = err }
			end
			globalVar = 100
			local gv = globalVar
			return gv + (tn or 0) + #ts + mx3 + mn3 + vs + ipSum + (if gm then 1 else 0), errMsgs
		]],
			{ optimizationLevel = 2, coverageLevel = 2 }
		)
		assert(covRes.status == "ok", covRes.error)
		local covFn = assert(VM.loadBytecode(covRes.bytecode, { name = "=cov" }))
		local covSum, fcErrMsgs = covFn(1, 5, 3)
		sert.eq(covSum, 224)
		sert.eq(#fcErrMsgs, 22)
		for idx, item in fcErrMsgs do
			sert.eq(item.ok, false, `fastcall error case #{idx} failed to throw`)
			expect(type(item.err) == "string" and #item.err > 0, `fastcall error case #{idx} message`)
		end

		for _, badFor in
			{
				"local lim = 'bad'; for i = 1, lim do end",
				"local stp = 'bad'; for i = 1, 5, stp do end",
				"local ini = 'bad'; for i = ini, 5 do end",
			}
		do
			local fnBad = assert(Parser.load(badFor, { name = "for_err" }))
			local ok, err = pcall(fnBad)
			sert.eq(ok, false)
			expect(string.find(tostring(err), "number expected", 1, true) ~= nil, "reports numeric for type error")
		end
	end)

	test("executes direct low-level opcodes and rejects unsupported opcodes", function()
		local bcb = BytecodeBuilder.new()
		local fid = bcb:beginFunction(2, false)
		local kFn = bcb:addConstantString("fn")
		local kVal = bcb:addConstantNumber(77)
		local kProp = bcb:addConstantString("prop")
		-- R0 = arg0 (table), R1 = arg1 (fn)
		bcb:emitABC(Opcodes.LOP_NOP, 0, 0, 0)
		bcb:emitABC(Opcodes.LOP_BREAK, 0, 0, 0)
		bcb:emitAD(Opcodes.LOP_LOADKX, 2, 0)
		bcb:emitAux(kVal)
		bcb:emitABC(Opcodes.LOP_SETTABLEN, 2, 0, 0) -- R0[1] = 77
		bcb:emitABC(Opcodes.LOP_SETUDATAKS, 2, 0, 0)
		bcb:emitAux(kProp)
		bcb:emitABC(Opcodes.LOP_GETUDATAKS, 3, 0, 0)
		bcb:emitAux(kProp)
		bcb:emitABC(Opcodes.LOP_NAMECALLUDATA, 4, 0, 0)
		bcb:emitAux(kFn)
		bcb:emitABC(Opcodes.LOP_CALLFB, 4, 2, 2)
		bcb:emitAux(0)
		bcb:emitE(Opcodes.LOP_JUMPX, 0)
		bcb:emitAD(Opcodes.LOP_CMPPROTO, 0, 1)
		bcb:emitAux(0)
		bcb:emitABC(Opcodes.LOP_RETURN, 4, 2, 0)
		bcb:endFunction(8, 0, 0, 0, 0)
		bcb:setMainFunction(fid)
		bcb:finalize()

		local customFn = assert(VM.loadProto(bcb:toProtoModule(), { name = "=custom_ops" }))
		local obj = {
			fn = function(self: any)
				return (self[1] or 0) + (self.prop or 0)
			end,
		}
		sert.eq(customFn(obj), 154)

		-- Unsupported opcode is rejected during static proto verification
		local badMod = table.clone(bcb:toProtoModule())
		badMod.protos = table.clone(badMod.protos)
		local badProto = table.clone(badMod.protos[1])
		badProto.code = table.clone(badProto.code)
		badProto.code[1] = Helpers.encodeABC(255, 0, 0, 0)
		badMod.protos[1] = badProto
		local badOpFn, errOp = VM.loadProto(badMod, { name = "=bad_op" })
		sert.eq(badOpFn, nil)
		expect(string.find(tostring(errOp), "unsupported opcode", 1, true) ~= nil, "unsupported opcode error")
	end)

	test("supports VM.load(bytecode, options), smart safeenv, and virtualized getfenv/setfenv", function()
		-- 1. VM.load(bytecode, { mode = "binary" }) and VM.load(source, options)
		local bc =
			assert(Parser.compile("return math.abs(-19) + bit32.band(7, 3) + customGlobal", { optimizationLevel = 2 }))
		local fenvLike = setmetatable({ customGlobal = 100 }, { __index = VM.createEnvironment() })
		local fn = assert(VM.load(bc, { name = "=kohls_script", env = fenvLike, mode = "binary" }))
		sert.eq(fn(), 122)

		-- 2. Non-builtin SETGLOBAL preserves safeenv; builtin/imported SETGLOBAL invalidates safeenv dynamically
		local dynBc = assert(Parser.compile(
			[[
				nonBuiltin = 50
				local before = math.abs(-10) + nonBuiltin
				math = { abs = function(x) return 999 end }
				local after = math.abs(-10) + nonBuiltin
				return before, after
			]],
			{ optimizationLevel = 1 }
		))
		local env2: { [string]: any } = setmetatable({} :: { [string]: any }, { __index = VM.createEnvironment() })
		local b, a = assert(VM.load(dynBc, { name = "=dyn_safeenv", env = env2, mode = "binary" }))()
		sert.eq(b, 60)
		sert.eq(a, 1049)
		sert.eq(env2.nonBuiltin, 50)

		-- 3. Virtualized getfenv and setfenv inside VM closures
		local fenvSrc = [[
			local function helper()
				return magicVal
			end
			local e0 = getfenv(0)
			local e1 = getfenv(1)
			local ef = getfenv(helper)
			assert(e0 == e1 and e1 == ef, "initial env matches")
			setfenv(helper, { magicVal = 777 })
			local fromHelper = helper()
			setfenv(1, { magicVal = 333, getfenv = getfenv })
			return fromHelper, magicVal, getfenv(1).magicVal
		]]
		local fenvFn = assert(VM.load(fenvSrc, {
			name = "=fenv_test",
			env = setmetatable({ magicVal = 111 }, { __index = VM.createEnvironment() }),
		}))
		local r1, r2, r3 = fenvFn()
		sert.eq(r1, 777)
		sert.eq(r2, 333)
		sert.eq(r3, 333)
	end)

	test("isolates concurrent yielding coroutines across nested VM calls and getfenv/setfenv", function()
		local workerSrc = [[
			local baseEnv = getfenv(1)
			local function inner(tag, step)
				local callerEnv = getfenv(2)
				local resumed = coroutine.yield(tag .. ":" .. tostring(callerEnv.slot) .. ":" .. tostring(step))
				local implicitNil
				assert(implicitNil == nil, "recycled stack slots must be cleared")
				return resumed + (callerEnv.slot or 0), getfenv(2).owner
			end

			local function outer(owner, slotA, slotB)
				setfenv(1, setmetatable({ owner = owner, slot = slotA }, { __index = baseEnv }))
				local v1, o1 = inner(owner, 1)
				setfenv(1, setmetatable({ owner = owner, slot = slotB }, { __index = baseEnv }))
				local v2, o2 = inner(owner, 2)
				return v1 + v2, o1, o2, getfenv(1).slot
			end

			return outer(...)
		]]

		local fnA = assert(VM.load(workerSrc, { name = "=co_a" }))
		local fnB = assert(VM.load(workerSrc, { name = "=co_b" }))
		local coA = coroutine.create(fnA)
		local coB = coroutine.create(fnB)

		local okA1, yA1 = coroutine.resume(coA, "A", 10, 20)
		local okB1, yB1 = coroutine.resume(coB, "B", 100, 200)
		sert.eq(okA1, true)
		sert.eq(yA1, "A:10:1")
		sert.eq(okB1, true)
		sert.eq(yB1, "B:100:1")

		local okA2, yA2 = coroutine.resume(coA, 5)
		local okB2, yB2 = coroutine.resume(coB, 50)
		sert.eq(okA2, true)
		sert.eq(yA2, "A:20:2")
		sert.eq(okB2, true)
		sert.eq(yB2, "B:200:2")

		local okA3, sumA, oA1, oA2, slotA = coroutine.resume(coA, 7)
		local okB3, sumB, oB1, oB2, slotB = coroutine.resume(coB, 70)
		sert.eq(okA3, true)
		sert.eq(sumA, (5 + 10) + (7 + 20))
		sert.eq(oA1, "A")
		sert.eq(oA2, "A")
		sert.eq(slotA, 20)

		sert.eq(okB3, true)
		sert.eq(sumB, (50 + 100) + (70 + 200))
		sert.eq(oB1, "B")
		sert.eq(oB2, "B")
		sert.eq(slotB, 200)
	end)

	test("collects unreachable VM closures, recursive functions, and environments via weak closureMeta", function()
		local weakRefs: { [number]: any } = setmetatable({}, { __mode = "v" }) :: any

		local function createAndRunEphemeral()
			local env = VM.createEnvironment({ secret = 42 })
			local chunk = assert(VM.load(
				[[
				local function fact(n)
					if n <= 1 then
						return 1
					end
					return n * fact(n - 1)
				end
				function globalHelper()
					return secret + fact(4)
				end
				return globalHelper(), globalHelper
			]],
				{ name = "=gc_test", env = env }
			))
			local val, childFn = chunk()
			sert.eq(val, 66)
			weakRefs[1] = chunk
			weakRefs[2] = childFn
			weakRefs[3] = env
		end

		createAndRunEphemeral()

		drainWeak(weakRefs, 3)

		sert.eq(weakRefs[1], nil)
		sert.eq(weakRefs[2], nil)
		sert.eq(weakRefs[3], nil)
	end)

	test("enforces LoadOptions instructionLimit, callLimit, and yieldable interrupt callbacks", function()
		-- 1. instructionLimit stops infinite loops and cannot be bypassed via guest pcall
		local infLoop = assert(VM.load(
			[[
			pcall(function()
				while true do
				end
			end)
			while true do
			end
		]],
			{ name = "=budget_loop", instructionLimit = 500 }
		))
		local okLoop, errLoop = pcall(infLoop)
		sert.eq(okLoop, false)
		expect(
			string.find(tostring(errLoop), "instruction limit exceeded", 1, true) ~= nil,
			"instructionLimit stops infinite loop"
		)

		-- 2. callLimit stops flat VM-to-VM infinite recursion cleanly and unwinds frames
		local infRec = assert(VM.load(
			[[
			local function dive(n)
				return dive(n + 1) + 1
			end
			return dive(1)
		]],
			{ name = "=budget_rec", callLimit = 25 }
		))
		local okRec, errRec = pcall(infRec)
		sert.eq(okRec, false)
		expect(string.find(tostring(errRec), "call stack overflow", 1, true) ~= nil, "callLimit stops recursion")

		-- Subsequent call on the same thread succeeds after stack unwind
		local shallowOk = assert(VM.load("local function f(x) return x + 1 end return f(41)", {
			name = "=ok_after_overflow",
			callLimit = 10,
		}))
		sert.eq(shallowOk(), 42)

		-- 3. interrupt cancels execution when returning false
		local ticks = 0
		local cancelFn = assert(VM.load(
			[[
			local s = 0
			while true do
				s += 1
			end
			return s
		]],
			{
				name = "=intr_cancel",
				interruptInterval = 64,
				interrupt = function(): boolean?
					ticks += 1
					if ticks >= 3 then
						return false
					end
					return true
				end,
			}
		))
		local okCancel, errCancel = pcall(cancelFn)
		sert.eq(okCancel, false)
		sert.eq(ticks, 3)
		expect(string.find(tostring(errCancel), "execution interrupted", 1, true) ~= nil, "interrupt cancels loop")

		-- 4. interrupt supports yielding across loop backedges
		local yieldCount = 0
		local yieldLoop = assert(VM.load(
			[[
			local total = 0
			for i = 1, 200 do
				total += i
			end
			return total
		]],
			{
				name = "=intr_yield",
				interruptInterval = 80,
				interrupt = function(): boolean?
					yieldCount += 1
					local action = coroutine.yield("paused", yieldCount)
					if action == "stop" then
						return false
					end
					return true
				end,
			}
		))
		local co = coroutine.create(yieldLoop)
		local pauses = 0
		local finalSum: any = nil
		while coroutine.status(co) ~= "dead" do
			local okStep, tag, val = coroutine.resume(co, "continue")
			sert.eq(okStep, true)
			if tag == "paused" then
				pauses += 1
				sert.eq(val, pauses)
			else
				finalSum = tag
			end
		end
		expect(pauses >= 1, "loop yielded via interrupt callback")
		sert.eq(finalSum, 200 * 201 / 2)
	end)

	test(
		"formats clean guest stack traces in debug.traceback, xpcall, and VM.traceback without VM.luau frames",
		function()
			local traceSrc = [[
			local function gamma(mode)
				if mode == "trace" then
					return debug.traceback("guest msg"), debug.traceback("skip top", 2)
				end
				error("kaboom")
			end
			local function beta(mode)
				local r1, r2 = gamma(mode)
				return r1, r2
			end
			local function alpha(mode)
				local r1, r2 = beta(mode)
				return r1, r2
			end

			local tb1, tb2 = alpha("trace")
			local xOk, xTrace = xpcall(function()
				return alpha("boom")
			end, debug.traceback)
			return tb1, tb2, xOk, xTrace
		]]

			local fn = assert(VM.load(traceSrc, { name = "=guest_trace" }))
			local tb1, tb2, xOk, xTrace = fn()

			expect(
				string.find(tb1, "guest msg\nguest_trace:3 function gamma\n", 1, true) ~= nil,
				"header and gamma frame"
			)
			expect(string.find(tb1, "function beta\n", 1, true) ~= nil, "includes beta frame")
			expect(string.find(tb1, "function alpha\n", 1, true) ~= nil, "includes alpha frame")
			expect(string.find(tb1, "guest_trace:16\n", 1, true) ~= nil, "includes main frame")
			sert.eq(string.find(tb1, "stack traceback:", 1, true), nil, "matches 0.748 luaL_traceback without header")
			sert.eq(string.find(tb1, "VM.luau", 1, true), nil, "never leaks internal VM.luau frames")
			sert.eq(string.find(tb1, "VM/", 1, true), nil, "never leaks internal VM/* frames")

			expect(string.find(tb2, "function gamma", 1, true) == nil, "level 2 skips gamma frame")
			expect(string.find(tb2, "function beta\n", 1, true) ~= nil, "level 2 starts at beta frame")

			sert.eq(xOk, false)
			expect(string.find(xTrace, "guest_trace:5: kaboom\n", 1, true) ~= nil, "xpcall formats guest error line")
			expect(
				string.find(xTrace, "guest_trace:5 function gamma\n", 1, true) ~= nil,
				"xpcall preserves gamma frame before unwind"
			)
			expect(
				string.find(xTrace, "function alpha\n", 1, true) ~= nil,
				"xpcall preserves alpha frame before unwind"
			)
			sert.eq(string.find(xTrace, "VM.luau", 1, true), nil, "xpcall traceback never leaks VM.luau")
			sert.eq(string.find(xTrace, "VM/", 1, true), nil, "xpcall traceback never leaks VM/*")

			-- Host VM.traceback(co, msg) on a suspended guest coroutine
			local yieldFn = assert(VM.load(
				[[
			local function leaf()
				coroutine.yield("ready")
			end
			local function stem()
				leaf()
			end
			stem()
		]],
				{ name = "=suspended_guest" }
			))
			local co = coroutine.create(yieldFn)
			local okY, statusY = coroutine.resume(co)
			sert.eq(okY, true)
			sert.eq(statusY, "ready")
			local hostTb = VM.traceback(co, "suspended check")
			expect(string.find(hostTb, "suspended check\n", 1, true) ~= nil, "host traceback includes message")
			expect(string.find(hostTb, "suspended_guest:2 function leaf\n", 1, true) ~= nil, "includes leaf")
			expect(string.find(hostTb, "function stem\n", 1, true) ~= nil, "includes stem")
			sert.eq(string.find(hostTb, "VM.luau", 1, true), nil, "host VM.traceback never leaks VM.luau")
			sert.eq(string.find(hostTb, "VM/", 1, true), nil, "host VM.traceback never leaks VM/*")
		end
	)

	test("preserves host environment isolation across VM.createEnvironment, HostEnv, and guest getfenv", function()
		local HostEnv = require("../src/VM/HostEnv")
		sert.eq(table.isfrozen(HostEnv), true)
		local hostTbl = HostEnv.getHostEnv()
		expect(type(hostTbl) == "table", "HostEnv.getHostEnv returns table")

		-- Default inheritHost = false blocks host globals while keeping pure stdlib isolated
		local hostAny: any = hostTbl
		hostAny.__ouroHostIsolationTestMarker = "host_secret"
		local okHostTest, errHostTest = pcall(function()
			local isolatedEnv = VM.createEnvironment()
			sert.eq(isolatedEnv.__ouroHostIsolationTestMarker, nil)
			sert.eq(isolatedEnv.require, nil)

			local loadDefaultFn = assert(
				VM.load(
					"return __ouroHostIsolationTestMarker == nil and require == nil and math.abs(-4) == 4",
					{ name = "default_isolated" }
				)
			)
			sert.eq(loadDefaultFn(), true)

			local inheritEnv = VM.createEnvironment(nil, { inheritHost = true })
			sert.eq(inheritEnv.__ouroHostIsolationTestMarker, "host_secret")
			local inheritFn = assert(
				VM.load(
					"return __ouroHostIsolationTestMarker == 'host_secret' and script == nil",
					{ name = "inherit_host", env = inheritEnv }
				)
			)
			sert.eq(inheritFn(), true)
		end)
		hostAny.__ouroHostIsolationTestMarker = nil
		assert(okHostTest, tostring(errHostTest))

		local env1 = VM.createEnvironment()
		expect(getmetatable(env1 :: any) ~= nil, "default VM env has fallback metatable")
		env1.vmOnlyMarker = 42
		sert.eq((_G :: any).vmOnlyMarker, nil)
		sert.eq(VM.createEnvironment().vmOnlyMarker, nil)

		local guestBc = assert(Parser.compile(
			[[
				local xorL, xorR, absIn = ...
				vmGuestLeakCheck = 99
				setfenv(1, { x = 7, math = math, bit32 = bit32 })
				return x + bit32.bxor(xorL, xorR) + math.abs(absIn)
			]],
			{ optimizationLevel = 2 }
		))
		local fn1 = assert(VM.load(guestBc, { name = "guest_fenv", mode = "binary" }))
		sert.eq(fn1(5, 3, -4), 17)
		sert.eq((_G :: any).vmGuestLeakCheck, nil)

		local cleanBc = assert(
			Parser.compile(
				"local xorL, xorR, absIn = ...; return vmGuestLeakCheck == nil and bit32.bxor(xorL, xorR) + math.abs(absIn) == 10",
				{ optimizationLevel = 2 }
			)
		)
		local fn2 = assert(VM.load(cleanBc, { name = "clean_after", mode = "binary" }))
		sert.eq(fn2(5, 3, -4), true)
	end)

	test("caches frozen ProtoModules and re-verifies mutable ProtoModules on in-place mutation", function()
		local bc = assert(Parser.compile("local a = 40; return a + 2", { optimizationLevel = 2 }))
		local frozenMod = assert(BytecodeCodec.deserialize(bc))
		sert.eq(table.isfrozen(frozenMod :: any), true)
		local fnFrozen1 = assert(VM.loadProto(frozenMod, { name = "cached_proto" }))
		local fnFrozen2 = assert(VM.loadProto(frozenMod, { name = "cached_proto" }))
		sert.eq(fnFrozen1(), 42)
		sert.eq(fnFrozen2(), 42)

		local mod = table.clone(frozenMod)
		mod.protos = table.clone(frozenMod.protos)
		local mainIdx = mod.mainid + 1
		local mainProto = table.clone(mod.protos[mainIdx])
		mainProto.code = table.clone(mainProto.code)
		mod.protos[mainIdx] = mainProto

		local fn1 = assert(VM.loadProto(mod, { name = "mutable_proto" }))
		sert.eq(fn1(), 42)

		-- Mutate instruction word in place and verify mutable modules re-verify and reject invalid register
		local origWord = mainProto.code[1]
		mainProto.code[1] = Helpers.encodeABC(Opcodes.LOP_LOADNIL, 250, 0, 0)
		local badFn, badErr = VM.loadProto(mod, { name = "mutable_proto" })
		sert.eq(badFn, nil)
		expect(type(badErr) == "string", "mutated opcode triggers verification error")

		-- Restore instruction word and verify mutable module succeeds again
		mainProto.code[1] = origWord
		local fn3 = assert(VM.loadProto(mod, { name = "mutable_proto" }))
		sert.eq(fn3(), 42)

		-- Mutate mainid out of bounds and verify immediate rejection
		mod.mainid = 999
		local badMainFn, badMainErr = VM.loadProto(mod, { name = "mutable_proto" })
		sert.eq(badMainFn, nil)
		sert.eq(badMainErr, "invalid main proto id")
	end)

	test("executes full opcode and builtin mix accurately under LoadOptions instructionLimit", function()
		local src = [[
			local function exercise(a, b, c)
				local nl = nil
				local bt = (a > b)
				local bf = (a < b)
				local arr = { 10, 20, 30, a = 1, b = 2 }
				arr[1] = 11
				local idx = 2
				arr[idx] = arr[idx] + arr[1]
				arr.b = arr.a + arr[3]

				local up = 5
				local fns = {
					function(delta)
						up = up + delta
						return up
					end,
				}
				local u1 = fns[1](3)
				local u2 = fns[1](-1)

				gVar = gVar + 4
				local g = gVar

				local la = bt and a
				local lo = bf or b
				local lak = bt and 9
				local lok = bf or 9
				local ln = not bf
				local lm = -b
				local ll = #"hello"
				local dynList = { a, b, math.abs(-b) }
				local tag = if c == 3 then "yes" else "no"
				local tagMatch = 0
				if tag == "yes" and nl == nil then
					tagMatch = 1
				end

				local arith = ((a + b) - (a - b) * c / 2) + (a % 3) + (b ^ 2) + (a // 2)
				local arithK = (a + 7) + (5 - a) + (b * 5) + (a / 2) + (a % 4) + (b ^ 3) + (a // 3)

				local cmpAcc = 0
				if a > 0 and b ~= 0 then
					cmpAcc += 1
				else
					cmpAcc += 100
				end
				if a >= 5 then
					cmpAcc += 2
				end
				if b < 10 then
					cmpAcc += 4
				end
				if b <= 2 then
					cmpAcc += 8
				end
				if a == 5 then
					cmpAcc += 16
				end
				if not bf and bt and nl == nil then
					cmpAcc += 32
				end

				local sumFor = 0
				for i = 1, a do
					sumFor += i
				end
				for _, v in ipairs({ 1, b, c }) do
					sumFor += v
				end

				local fc = math.round(math.atan(1 / b) + math.atan2(1, b) + math.asin(0.5 / 1) + math.acos(1 / b))
					+ math.round(math.sinh(b / 10) + math.cosh(b / 10) + math.tanh(b / 10))
					+ math.round(math.cos(c / 10) + math.sin(c / 10) + math.tan(c / 10))
					+ math.round(math.deg(1 / b) + math.rad(a * 18) + math.sign(-a) + math.round(b + 0.6))
					+ math.round(math.log(b ^ c, b) + math.log10(b * 50) + math.exp(1 / b) + math.ldexp(1, c))
					+ math.min(a, b)
					+ math.max(a, b)
				local feM, feE = math.frexp(2 ^ c)
				local mInt, mFrac = math.modf(c + 0.25)
				local fm = math.fmod(a + b, 4)
				local btOk = if bit32.btest(a, 1) and bit32.extract(a * 0x30, 4, 4) == a then 1 else 0
				local sb = string.byte("AB", b)
				local pOk, pVal = pcall(math.abs, -a)
				local xOk, xVal = xpcall(function()
					return a + b
				end, tostring)
				local fe = getfenv(1)
				local feOk = if fe and fe.gVar ~= nil then 1 else 0
				local minMaxSum = math.min(a * b, 4) + math.max(b, c * 2)

				return math.floor(
					arith
						+ arithK
						+ cmpAcc
						+ sumFor
						+ u1
						+ u2
						+ g
						+ fc
						+ feM
						+ feE
						+ mInt
						+ mFrac
						+ fm
						+ btOk
						+ sb
						+ arr.b
						+ arr[2]
						+ (if la then la else 0)
						+ (if lo then lo else 0)
						+ (if lak then lak else 0)
						+ (if lok then lok else 0)
						+ (if ln then 1 else 0)
						+ lm
						+ ll
						+ dynList[3]
						+ tagMatch
						+ (if pOk then pVal else 0)
						+ (if xOk then xVal else 0)
						+ feOk
						+ minMaxSum
				)
			end
			return exercise(5, 2, 3)
		]]
		for _, optLevel in { 0, 1, 2 } do
			local bc = assert(Parser.compile(src, { optimizationLevel = optLevel }))
			local envUnlimited = VM.createEnvironment({ gVar = 5 })
			local envLimited = VM.createEnvironment({ gVar = 5 })
			local fnUnlimited = assert(VM.load(bc, { name = "=limit_mix_unlim", env = envUnlimited, mode = "binary" }))
			local fnLimited = assert(VM.load(bc, {
				name = "=limit_mix_lim",
				env = envLimited,
				mode = "binary",
				instructionLimit = 100000,
			}))
			local resUnlimited = fnUnlimited()
			local resLimited = fnLimited()
			sert.eq(resLimited, resUnlimited)
			sert.eq(envLimited.gVar, envUnlimited.gVar)
		end
		-- Also exercise CALLFB fallback under instructionLimit when safeenv is false
		local fallbackBc = assert(Parser.compile("local x, a, b = ...; return math.abs(x) + math.min(a, b)", {
			optimizationLevel = 2,
		}))
		local envCustomLimited: { [string]: any } = {
			math = {
				abs = function(v: number)
					return v * 100
				end,
				min = math.min,
			},
		}
		local fnCustomLimited = assert(VM.load(fallbackBc, {
			name = "=limit_fallback",
			env = envCustomLimited,
			mode = "binary",
			instructionLimit = 5000,
		}))
		sert.eq(fnCustomLimited(-7, 3, 5), -697)
	end)

	test(
		"handles mutable GETIMPORT chains, missing import roots, buffer loads, error levels, and debug.info",
		function()
			-- 1. Mutable containers / non-builtin roots must never freeze stale GETIMPORT values
			local sharedTable = { value = 10 }
			local dynamicEnv = VM.createEnvironment({ sharedTbl = sharedTable })
			local dynBc = assert(Parser.compile(
				[[
			local function readVal()
				return sharedTbl.value
			end
			local a = readVal()
			sharedTbl.value = 25
			local b = readVal()
			return a, b
		]],
				{ optimizationLevel = 2 }
			))
			local dynFn = assert(VM.loadBytecode(dynBc, { name = "=mutable_import", env = dynamicEnv }))
			local a, b = dynFn()
			sert.eq(a, 10)
			sert.eq(b, 25)

			-- 2. Missing-root 2/3-part GETIMPORT throws index nil error at runtime instead of returning nil
			local missingFn = assert(VM.load("return MissingRootGlobal.Field", { name = "=missing_import" }))
			local okMiss, errMiss = pcall(missingFn)
			sert.eq(okMiss, false)
			expect(
				string.find(tostring(errMiss), "MissingRootGlobal", 1, true) ~= nil
					or string.find(tostring(errMiss), "nil", 1, true) ~= nil,
				"missing import throws index error"
			)

			-- 3. SETTABLEKS after setfenv does not serve stale 1-part GETIMPORT
			local fenvMutFn = assert(VM.load(
				[[
			local t = { Foo = 11 }
			setfenv(1, t)
			local function readFoo()
				return Foo
			end
			local v1 = readFoo()
			t.Foo = 99
			local v2 = readFoo()
			return v1, v2
		]],
				{ name = "=setfenv_settableks" }
			))
			local f1, f2 = fenvMutFn()
			sert.eq(f1, 11)
			sert.eq(f2, 99)

			-- 4. Callable __call table iteration and custom ipairs override
			local iterSrc = [[
			local functor = setmetatable({ a = 1, b = 2 }, {
				__call = function() return nil end,
			})
			local calls = 0
			for _ in functor do
				calls += 1
			end
			local function customIpairs(t)
				local i = 0
				return function()
					i += 1
					if i <= #t then
						return i, t[i] * 10
					end
					return nil
				end, t, 0
			end
			local ipairs = customIpairs
			local sum = 0
			for _, v in ipairs({ 1, 2, 3 }) do
				sum += v
			end
			return calls, sum
		]]
			local cCalls, cSum = runAtAllOptLevels(iterSrc)
			sert.eq(cCalls, 0)
			sert.eq(cSum, 60)

			-- 5. error(msg, 0/1/2), non-string error objects, colon-containing error strings, and debug.info
			local errFn = assert(VM.load(
				[[
			local ok0, e0 = pcall(function()
				error("raw_msg", 0)
			end)
			local function thrower()
				error("caller_msg", 2)
			end
			local function caller()
				thrower() -- line 8
			end
			local ok2, e2 = pcall(caller)
			local okObj, eObj = pcall(function()
				error({ code = 7 }, 1)
			end)
			local okCol, eCol = pcall(function()
				error("10:20: msg", 1)
			end)
			local okPcallErr, ePcallErr = pcall(error, "direct", 0)
			local d = debug
			local tb = d.traceback("custom")
			local sFn, lFn, nFn, npFn, vaFn, fnRef = d.info(thrower, "slnaf")
			local sLvl, nLvl = debug.info(1, "sn")
			return ok0, e0, ok2, e2, okObj, eObj.code, okCol, eCol, okPcallErr, ePcallErr, tb, sFn, lFn, nFn, npFn, vaFn, fnRef == thrower, sLvl, nLvl
		]],
				{ name = "=err_dbg_test" }
			))
			local ok0, e0, ok2, e2, okObj, eCode, okCol, eCol, okPE, ePE, tb, sFn, lFn, nFn, npFn, vaFn, sameRef, sLvl, nLvl =
				errFn()
			sert.eq(ok0, false)
			sert.eq(e0, "raw_msg")
			sert.eq(ok2, false)
			expect(
				string.find(tostring(e2), "err_dbg_test:8: caller_msg", 1, true) ~= nil,
				"level 2 blames caller line 8"
			)
			sert.eq(okObj, false)
			sert.eq(eCode, 7)
			sert.eq(okCol, false)
			expect(string.find(tostring(eCol), "err_dbg_test:", 1, true) ~= nil, "error with colons gets line prefix")
			sert.eq(okPE, false)
			sert.eq(ePE, "direct")
			sert.eq(string.find(tostring(tb), "VM/", 1, true), nil)
			sert.eq(sFn, "err_dbg_test")
			sert.eq(lFn, 4)
			sert.eq(nFn, "thrower")
			sert.eq(npFn, 0)
			sert.eq(vaFn, false)
			sert.eq(sameRef, true)
			sert.eq(sLvl, "err_dbg_test")
			sert.eq(nLvl, "")

			-- 6. Buffer bytecode loading, chunkname truncation, and DUPCLOSURE 0-upval identity
			local bcBuf = buffer.fromstring(assert(Parser.compile(
				[[
			local funcs = {}
			for i = 1, 2 do
				funcs[i] = function(x) return x + 1 end
			end
			return funcs[1] == funcs[2], funcs[1](41)
		]],
				{ optimizationLevel = 2 }
			)))
			local fnFromBuf = assert(VM.load(bcBuf, { name = string.rep("x", 80) .. "\nsecond_line" }))
			local sameDup, dupVal = fnFromBuf()
			sert.eq(sameDup, true)
			sert.eq(dupVal, 42)
			local fnErrBuf, errBufMsg = VM.load(buffer.fromstring("\0buf_compile_err"))
			sert.eq(fnErrBuf, nil)
			sert.eq(errBufMsg, "buf_compile_err")

			local longFailFn = assert(VM.load("error('boom')", { name = string.rep("abc", 100) .. "\nline2" }))
			local okLong, errLong = pcall(longFailFn)
			sert.eq(okLong, false)
			expect(
				#tostring(errLong) < 280 and string.find(tostring(errLong), "...", 1, true) ~= nil,
				"truncates long plain chunkname"
			)
		end
	)

	test("supports re-entrant pcall and deep recursion beyond 256 stack slots with open upvalues", function()
		local fn = assert(VM.load(
			[[
			local acc = 0
			local function deep(n, bump)
				local localVal = n
				local function reader()
					return localVal
				end
				if n <= 0 then
					local ok, inner = pcall(function()
						return reader() + bump()
					end)
					assert(ok)
					return inner
				end
				return deep(n - 1, bump) + localVal
			end
			return deep(90, function()
				acc += 1
				return acc
			end), acc
		]],
			{ name = "=deep_reentrant" }
		))
		local total, accVal = fn()
		sert.eq(total, 90 * 91 / 2 + 1)
		sert.eq(accVal, 1)
	end)

	test("loadBytecode lazy line decoding reports exact runtime error lines and tracebacks", function()
		local Compiler = require("../src/Compiler")
		local bc = assert(Compiler.compile(
			[[
local a = 1
local function inner()
	local b = 2
	error("lazy_line_boom")
end
inner()
]],
			{ optimizationLevel = 2, debugLevel = 2 }
		))
		local fn, err = VM.loadBytecode(bc, { name = "=lazy_chunk" })
		sert.eq(err, nil)
		local ok, runErr = pcall(fn :: any)
		sert.eq(ok, false)
		expect(string.find(tostring(runErr), "lazy_chunk:4: lazy_line_boom", 1, true) ~= nil, tostring(runErr))

		local tracedFn, err2 = VM.loadBytecode(
			buffer.fromstring(assert(Compiler.compile(
				[[
local function outer()
	local function inner()
		return debug.traceback("trace_here", 1)
	end
	return inner()
end
return outer()
]],
				{ optimizationLevel = 2, debugLevel = 2 }
			))),
			{ name = "=lazy_trace" }
		)
		sert.eq(err2, nil)
		local trace = (tracedFn :: any)()
		expect(string.find(trace, "lazy_trace:3 function inner\n", 1, true) ~= nil, trace)
		expect(string.find(trace, "lazy_trace:5 function outer\n", 1, true) ~= nil, trace)
	end)

	test(
		"executes 0.748 table.create/clear and buffer vector fastcalls plus private class opcode/shape validation",
		function()
			-- 1. table.create & table.clear fastcall paths + fallbacks (compiled with -O2)
			local tblOpts: Parser.CompileOptions = {
				optimizationLevel = 2,
				flags = { LuauCompileTableBuiltinsCreateClear = true },
			}
			local tblBc = assert(Parser.compile(
				[[
				local a = table.create(3, 7)
				local sum = a[1] + a[2] + a[3]
				table.clear(a)
				local nAfterClear = #a
				local b = table.create(2)
				local c = table.create(1.7, 9)
				local d = table.create(-0.5, 5)
				return sum, nAfterClear, type(b), #c, c[1], #d
			]],
				tblOpts
			))
			local tblFn = assert(VM.loadBytecode(tblBc, { name = "=tbl_fc" }))
			local s, afterClear, bType, cLen, c1, dLen = tblFn()
			sert.eq(s, 21)
			sert.eq(afterClear, 0)
			sert.eq(bType, "table")
			sert.eq(cLen, 1)
			sert.eq(c1, 9)
			sert.eq(dLen, 0)

			local badSizeFn = assert(
				VM.loadBytecode(assert(Parser.compile("return table.create(-1)", tblOpts)), { name = "=tbl_neg" })
			)
			local okNeg, errNeg = pcall(badSizeFn)
			sert.eq(okNeg, false)
			expect(string.find(tostring(errNeg), "out of range", 1, true) ~= nil, tostring(errNeg))

			local frozenClearFn = assert(
				VM.loadBytecode(
					assert(Parser.compile("local t = table.freeze({ 1 }); table.clear(t)", tblOpts)),
					{ name = "=tbl_frozen" }
				)
			)
			local okFrz, errFrz = pcall(frozenClearFn)
			sert.eq(okFrz, false)
			expect(string.find(tostring(errFrz), "readonly", 1, true) ~= nil, tostring(errFrz))

			-- 2. buffer.readvectorf32x* / buffer.writevectorf32x* fastcalls + x4 fallback
			local vecBc = assert(Parser.compile(
				[[
				local buf = buffer.create(16)
				buffer.writevectorf32x2(buf, 0, vector.create(1.5, -2.5, 99))
				local v2 = buffer.readvectorf32x2(buf, -0.5)
				buffer.writevectorf32x3(buf, 0, vector.create(3.5, 4.5, -5.5))
				local v3 = buffer.readvectorf32x3(buf, 0)
				return v2.x, v2.y, v2.z, v3.x, v3.y, v3.z
			]],
				{ optimizationLevel = 2, flags = { DebugLuauBufferVectorFastcalls = true } }
			))
			local vecFn = assert(VM.loadBytecode(vecBc, { name = "=vec_buf_fc" }))
			local x2, y2, z2, x3, y3, z3 = vecFn()
			sert.eq(x2, 1.5)
			sert.eq(y2, -2.5)
			sert.eq(z2, 0)
			sert.eq(x3, 3.5)
			sert.eq(y3, 4.5)
			sert.eq(z3, -5.5)

			-- x4 falls back on 3-wide host and out-of-bounds falls back cleanly
			local x4Env = VM.createEnvironment({
				buffer = table.freeze({
					create = buffer.create,
					len = buffer.len,
					readf32 = buffer.readf32,
					writef32 = buffer.writef32,
					readvectorf32x4 = function()
						return "fallback_x4"
					end,
				}),
			})
			local x4Fn = assert(
				VM.loadBytecode(
					assert(
						Parser.compile(
							"local b = buffer.create(16); return buffer.readvectorf32x4(b, 0)",
							{ optimizationLevel = 2, flags = { DebugLuauBufferVectorFastcalls = true } }
						)
					),
					{ name = "=vec_x4_fb", env = x4Env }
				)
			)
			sert.eq(x4Fn(), "fallback_x4")

			-- 3. Class shape private counts & LOP_GETPRIVATEFIELD/LOP_SETPRIVATEFIELD verification + v100 rejection
			local bcb = BytecodeBuilder.new(nil, { DebugLuauUserDefinedClasses = true })
			local fid = bcb:beginFunction(0, false)
			local kClsName = bcb:addConstantString("PrivBox")
			local kPubProp = bcb:addConstantString("pubProp")
			local kPubMeth = bcb:addConstantString("pubMeth")
			local _kCls = bcb:addClassShape({
				className = kClsName,
				numPrivateInstanceProps = 1,
				numPrivateStaticProps = 1,
				propertyNames = { kPubProp },
				methodNames = { kPubMeth },
			})
			bcb:emitABC(Opcodes.LOP_GETPRIVATEFIELD, 0, 1, 0)
			bcb:emitAux(0x0300)
			bcb:emitABC(Opcodes.LOP_SETPRIVATEFIELD, 0, 1, 0)
			bcb:emitAux(0)
			bcb:emitAD(Opcodes.LOP_LOADN, 0, 77)
			bcb:emitABC(Opcodes.LOP_RETURN, 0, 2, 0)
			bcb:endFunction(4, 1, 0, 0, 0)
			bcb:setMainFunction(fid)
			bcb:finalize()

			local v100Bc = bcb:getBytecode()
			local v100Mod = assert(BytecodeCodec.deserialize(v100Bc))
			sert.eq(v100Mod.version, BytecodeDefs.Tags.LBC_VERSION_CLASSES)

			local privFn, privErr = VM.loadBytecode(v100Bc, { name = "=priv_stub" })
			sert.eq(privFn, nil)
			sert.eq(privErr, "unsupported experimental class bytecode (v100)")

			local protoFn, protoErr = VM.loadProto(bcb:toProtoModule(), { name = "=priv_proto" })
			sert.eq(protoFn, nil)
			sert.eq(protoErr, "unsupported experimental class bytecode (v100)")

			-- Even when spoofed with a non-v100 header, individual class opcodes are rejected by the verifier
			for _, clsOp in
				{
					Opcodes.LOP_NEWCLASS,
					Opcodes.LOP_NEWCLASSMEMBER,
					Opcodes.LOP_CONSTRUCT,
					Opcodes.LOP_FINCONSTRUCT,
					Opcodes.LOP_GETPRIVATEFIELD,
					Opcodes.LOP_SETPRIVATEFIELD,
				}
			do
				local badClsMod = {
					version = BytecodeDefs.Tags.LBC_VERSION_TARGET,
					typesversion = BytecodeDefs.Tags.LBC_TYPE_VERSION_TARGET,
					strings = {},
					mainid = 0,
					protos = {
						{
							id = 0,
							maxstacksize = 4,
							numparams = 0,
							nups = 0,
							isvararg = false,
							flags = 0,
							code = { clsOp, 0, Opcodes.LOP_RETURN },
							kTypes = {},
							kValues = {},
							p = {},
							linedefined = 1,
						},
					},
				}
				local clsFn, clsErr = VM.loadProto(badClsMod :: any, { name = "=cls_op" })
				sert.eq(clsFn, nil)
				sert.eq(clsErr, "unsupported experimental class bytecode (v100)")
			end
		end
	)

	test("enforces 0.748 getfenv/setfenv isolation, CMPPROTO matching, and _G safeenv deoptimization", function()
		-- 1. getfenv / setfenv sandbox isolation (no host fallback on active VM thread)
		local fenvIsoFn = assert(VM.load(
			[[
				local function inner()
					local ok99, e99 = pcall(getfenv, 99)
					local okNeg, eNeg = pcall(getfenv, -1)
					local okHostFn, resHostFn = pcall(getfenv, print)
					local okFrac, resFrac = pcall(getfenv, 1.5)
					local okSetHost, errSetHost = pcall(setfenv, print, {})
					local okSet99, errSet99 = pcall(setfenv, 99, {})
					return ok99, e99, okNeg, eNeg, okHostFn, resHostFn == _G, okFrac, resFrac == getfenv(1), okSetHost, errSetHost, okSet99, errSet99
				end
				return inner()
			]],
			{ name = "=fenv_iso" }
		))
		local ok99, e99, okNeg, eNeg, okHF, sameG, okFr, sameSelf, okSH, errSH, okS99, errS99 = fenvIsoFn()
		sert.eq(ok99, false)
		expect(string.find(tostring(e99), "invalid level", 1, true) ~= nil, tostring(e99))
		sert.eq(okNeg, false)
		expect(string.find(tostring(eNeg), "invalid level", 1, true) ~= nil, tostring(eNeg))
		sert.eq(okHF, true)
		sert.eq(sameG, true)
		sert.eq(okFr, true)
		sert.eq(sameSelf, true)
		sert.eq(okSH, false)
		expect(string.find(tostring(errSH), "cannot change environment", 1, true) ~= nil, tostring(errSH))
		sert.eq(okS99, false)
		expect(string.find(tostring(errS99), "invalid level", 1, true) ~= nil, tostring(errS99))

		-- 2. LOP_CMPPROTO hit and miss (matching proto, mismatched proto, non-function, and cross-module closure)
		local cmpBcb = BytecodeBuilder.new()
		local fChildA = cmpBcb:beginFunction(0, false)
		cmpBcb:emitABC(Opcodes.LOP_RETURN, 0, 1, 0)
		cmpBcb:endFunction(1, 0, 0)
		local fChildB = cmpBcb:beginFunction(0, false)
		cmpBcb:emitABC(Opcodes.LOP_RETURN, 0, 1, 0)
		cmpBcb:endFunction(1, 0, 0)
		local fMain = cmpBcb:beginFunction(1, false)
		local childPidA = cmpBcb:addChildFunction(fChildA)
		local childPidB = cmpBcb:addChildFunction(fChildB)
		-- R0 = arg; if arg == nil build childA/childB, else test arg directly
		local lblTestArg = cmpBcb:emitLabel()
		cmpBcb:emitAD(Opcodes.LOP_JUMPIF, 0, 0)
		cmpBcb:emitAD(Opcodes.LOP_NEWCLOSURE, 0, childPidA) -- R0 = childA
		local lblCmp = cmpBcb:emitLabel()
		cmpBcb:emitAD(Opcodes.LOP_CMPPROTO, 0, 0) -- if mismatch jump to LOADN R0, 222
		cmpBcb:emitAux(fChildA)
		cmpBcb:emitAD(Opcodes.LOP_LOADN, 0, 111)
		cmpBcb:emitABC(Opcodes.LOP_RETURN, 0, 2, 0)
		local lblMiss = cmpBcb:emitLabel()
		cmpBcb:emitAD(Opcodes.LOP_LOADN, 0, 222)
		cmpBcb:emitABC(Opcodes.LOP_RETURN, 0, 2, 0)
		assert(cmpBcb:patchJumpD(lblTestArg, lblCmp))
		assert(cmpBcb:patchJumpD(lblCmp, lblMiss))
		cmpBcb:endFunction(2, 0, 0)
		cmpBcb:setMainFunction(fMain)
		cmpBcb:finalize()

		local cmpRunner = assert(VM.loadProto(cmpBcb:toProtoModule(), { name = "=cmpproto" }))
		-- Hit with own childA; miss with other-module closure (whose id is 0/1 too) and non-function
		sert.eq(cmpRunner(), 111)
		sert.eq(cmpRunner(123), 222)
		local otherClosure = assert(VM.load("return function() end", { name = "=other_cmp" }))()
		sert.eq(cmpRunner(otherClosure), 222)
		local mismatchMod = table.clone(cmpBcb:toProtoModule())
		mismatchMod.protos = table.clone(mismatchMod.protos)
		local mainCopy = table.clone(mismatchMod.protos[fMain + 1])
		mainCopy.code = table.clone(mainCopy.code)
		mainCopy.code[2] = Helpers.encodeAD(Opcodes.LOP_NEWCLOSURE, 0, childPidB) -- proto.p[2] == childB
		mismatchMod.protos[fMain + 1] = mainCopy
		sert.eq(assert(VM.loadProto(mismatchMod, { name = "=cmp_b" }))(), 222)

		-- 3. _G mutation deoptimizes safeenv
		local gDeoptFn = assert(VM.load(
			[[
				local x, a, b = ...
				local before = math.abs(x)
				_G.math = { abs = function(_) return 555 end }
				local afterDot = math.abs(x)
				_G["bit32"] = { bxor = function() return 444 end }
				local afterBracket = bit32.bxor(a, b)
				return before, afterDot, afterBracket
			]],
			{ name = "=g_deopt", compile = { optimizationLevel = 2 } }
		))
		local gb, gad, gab = gDeoptFn(-9, 1, 2)
		sert.eq(gb, 9)
		sert.eq(gad, 555)
		sert.eq(gab, 444)
	end)

	test("enforces 0.748 ipairs/FORGPREP errors, fastcall edge fixes, and NAMECALL evaluation order", function()
		-- 1. ipairs with __index terminates without infinite loop + FORGPREP header errors
		local iterCheckFn = assert(VM.load(
			[[
				local t = setmetatable({ 10, 20 }, {
					__index = function() return 999 end,
				})
				local s = 0
				for i, v in ipairs(t) do
					s += i * 100 + v
				end
				local okNum, errNum = pcall(function()
					for _ in (123 :: any) do end
				end)
				local badObj = setmetatable({}, {
					__iter = function() return nil, {}, 0 end,
				})
				local okNilGen, errNilGen = pcall(function()
					for _ in badObj do end
				end)
				local okIpairsBad, errIpairsBad = pcall(function()
					for _ in ipairs("bad" :: any) do end
				end)
				local origIpairs = _G.ipairs
				_G.ipairs = function()
					return 123
				end
				local okIpairsGen, errIpairsGen = pcall(function()
					for _ in ipairs({}) do end
				end)
				_G.ipairs = origIpairs
				return s, okNum, errNum, okNilGen, errNilGen, okIpairsBad, errIpairsBad, okIpairsGen, errIpairsGen
			]],
			{ name = "=iter_checks", compile = { optimizationLevel = 2 } }
		))
		local isum, okN, errN, okNG, errNG, okIB, errIB, okIG, errIG = iterCheckFn()
		sert.eq(isum, 330)
		sert.eq(okN, false)
		expect(string.find(tostring(errN), "attempt to iterate over", 1, true) ~= nil, tostring(errN))
		sert.eq(okNG, false)
		expect(string.find(tostring(errNG), "attempt to call a nil value", 1, true) ~= nil, tostring(errNG))
		sert.eq(okIB, false)
		expect(string.find(tostring(errIB), "table expected", 1, true) ~= nil, tostring(errIB))
		sert.eq(okIG, false)
		expect(string.find(tostring(errIG), "attempt to iterate over", 1, true) ~= nil, tostring(errIG))

		-- 2. Fastcall fixes: table.unpack, select multiret & negative frac, empty string.byte
		local fcFixesFn = assert(VM.load(
			[[
				local a, b, c = table.unpack({ 10, 20, 30 })
				local x, y = table.unpack({ 7, 8, 9 }, 1, 2)
				local function selMulti(...)
					local r1, r2 = select(1, ...)
					return r1, r2
				end
				local m1, m2 = selMulti(5, 6)
				local okNegSel, errNegSel = pcall(function(...)
					return select(-0.5, ...)
				end, 1, 2)
				local emptyByteCount = select("#", string.byte(""))
				return a, b, c, x, y, m1, m2, okNegSel, errNegSel, emptyByteCount
			]],
			{ name = "=fc_fixes", compile = { optimizationLevel = 2 } }
		))
		local f1, f2, f3, f4, f5, sm1, sm2, okNS, errNS, ebc = fcFixesFn()
		sert.eq(f1, 10)
		sert.eq(f2, 20)
		sert.eq(f3, 30)
		sert.eq(f4, 7)
		sert.eq(f5, 8)
		sert.eq(sm1, 5)
		sert.eq(sm2, 6)
		sert.eq(okNS, false)
		expect(string.find(tostring(errNS), "index out of range", 1, true) ~= nil, tostring(errNS))
		sert.eq(ebc, 0)

		-- 3. NAMECALL evaluates call arguments first, then raises missing method before CALL
		local ncOrderFn = assert(VM.load(
			[[
				local hits = 0
				local function bump()
					hits += 1
					return 1
				end
				local tbl = {}
				local ok, err = pcall(function()
					return (tbl :: any):missingMethod(bump())
				end)
				return hits, ok, err
			]],
			{ name = "=nc_order" }
		))
		local ncHits, okNC, errNC = ncOrderFn()
		sert.eq(ncHits, 1)
		sert.eq(okNC, false)
		expect(
			string.find(tostring(errNC), "attempt to call missing method 'missingMethod' of table", 1, true) ~= nil,
			tostring(errNC)
		)
	end)

	test("enforces 0.748 debug.traceback/debug.info checks, closed coroutines, and xpcall stack unwind", function()
		-- 1. debug.traceback(nil, 2), debug.info(0, "f"), duplicate opts, nested level-0 error, pcall(error, msg, 1)
		local dbgFn = assert(VM.load(
			[[
				local function innerTrace()
					return debug.traceback(nil, 2)
				end
				local function callerTrace()
					return innerTrace()
				end
				local skipTb = callerTrace()
				local okBadMsg, errBadMsg = pcall(debug.traceback, {}, 1)
				local okNegLvl, errNegLvl = pcall(debug.traceback, "m", -1)
				local s0, l0, n0, np0, va0, fn0 = debug.info(0, "slnaf")
				local okDup, errDup = pcall(debug.info, 1, "ss")
				local okThreadFn, errThreadFn = pcall(debug.info, coroutine.running(), callerTrace, "s")
				local okSortErr0, errSort0 = pcall(function()
					table.sort({ 2, 1 }, function()
						error("boom", 0)
					end)
				end)
				local okPcallDirect1, errPcallDirect1 = pcall(error, "direct", 1)
				return skipTb, okBadMsg, errBadMsg, okNegLvl, errNegLvl, s0, l0, n0, np0, va0, fn0 == debug.info, okDup, errDup, okThreadFn, errThreadFn, okSortErr0, errSort0, okPcallDirect1, errPcallDirect1
			]],
			{ name = "=dbg_sec" }
		))
		local sTb, okBM, errBM, okNL, errNL, s0, l0, n0, np0, va0, eqDI, okDup, errDup, okTF, errTF, okSE0, errSE0, okPD1, errPD1 =
			dbgFn()
		expect(string.find(sTb, "function innerTrace", 1, true) == nil, sTb)
		expect(string.find(sTb, "function callerTrace\n", 1, true) ~= nil, sTb)
		expect(string.sub(sTb, 1, 2) ~= "2\n", "arg1==nil did not shift level 2 into msg")
		sert.eq(okBM, false)
		expect(string.find(tostring(errBM), "string expected", 1, true) ~= nil, tostring(errBM))
		sert.eq(okNL, false)
		expect(string.find(tostring(errNL), "negative", 1, true) ~= nil, tostring(errNL))
		sert.eq(s0, "[C]")
		sert.eq(l0, -1)
		sert.eq(n0, "info")
		sert.eq(np0, 0)
		sert.eq(va0, true)
		sert.eq(eqDI, true)
		sert.eq(okDup, false)
		expect(string.find(tostring(errDup), "duplicate option", 1, true) ~= nil, tostring(errDup))
		sert.eq(okTF, false)
		expect(string.find(tostring(errTF), "function or level expected", 1, true) ~= nil, tostring(errTF))
		sert.eq(okSE0, false)
		sert.eq(errSE0, "boom")
		sert.eq(okPD1, false)
		sert.eq(errPD1, "direct")

		-- Closed coroutine leaves zero phantom frames
		local deadCoFn = assert(VM.load(
			[[
				local function step() coroutine.yield("pause") end
				step()
			]],
			{ name = "=dead_co" }
		))
		local coDead = coroutine.create(deadCoFn)
		assert(coroutine.resume(coDead))
		coroutine.close(coDead)
		sert.eq(VM.traceback(coDead), "")

		-- 2. xpcall stack-overflow headroom + host-callback snapshot
		local xpOvFn = assert(VM.load(
			[[
				local function dive(n)
					return dive(n + 1) + 1
				end
				return xpcall(function()
					return dive(1)
				end, function(err)
					local prefix = "handled:"
					return prefix .. tostring(err)
				end)
			]],
			{ name = "=xp_overflow", callLimit = 8 }
		))
		local okXOv, resXOv = xpOvFn()
		sert.eq(okXOv, false)
		expect(string.find(tostring(resXOv), "^handled:.*call stack overflow") ~= nil, tostring(resXOv))

		local xpHostFn = assert(VM.load(
			[[
				local function sortCmp(a, b)
					error("sort_boom")
				end
				return xpcall(table.sort, debug.traceback, { 2, 1 }, sortCmp)
			]],
			{ name = "=xp_host" }
		))
		local okXHost, resXHost = xpHostFn()
		sert.eq(okXHost, false)
		expect(string.find(tostring(resXHost), "function sortCmp\n", 1, true) ~= nil, tostring(resXHost))
	end)

	test("enforces 0.748 DUPCLOSURE upvalue identity, FORNPREP error order, and frozen COVERAGE execution", function()
		local dupUpFn = assert(VM.load(
			[[
				local immutableVal = ...
				local pair = {}
				for i = 1, 2 do
					pair[i] = function()
						return immutableVal
					end
				end
				local varying = {}
				for i = 1, 2 do
					varying[i] = function()
						return i
					end
				end
				return pair[1] == pair[2], pair[1](), varying[1] == varying[2], varying[1](), varying[2]()
			]],
			{ name = "=dup_upval", compile = { optimizationLevel = 2 } }
		))
		local dupSame, pairVal, dupDiff, v1, v2 = dupUpFn(42)
		sert.eq(dupSame, true)
		sert.eq(pairVal, 42)
		sert.eq(dupDiff, false)
		sert.eq(v1, 1)
		sert.eq(v2, 2)

		local fnOrd = assert(VM.load(
			[[
				local ini, lim = "bad_i", "bad_l"
				for i = (ini :: any), (lim :: any) do end
			]],
			{ name = "=forn_order" }
		))
		local okOrd, errOrd = pcall(fnOrd)
		sert.eq(okOrd, false)
		expect(
			string.find(tostring(errOrd), "invalid 'for' initial value (number expected, got string)", 1, true) ~= nil,
			tostring(errOrd)
		)

		local covBc = assert(
			Parser.compile(
				"local function add1(x) return x + 1 end return add1(4)",
				{ optimizationLevel = 2, coverageLevel = 2 }
			)
		)
		local frozenCovMod = assert(BytecodeCodec.deserialize(covBc))
		sert.eq(table.isfrozen(frozenCovMod.protos[1].code :: any), true)
		local covRunner = assert(VM.loadProto(frozenCovMod, { name = "=frozen_cov" }))
		sert.eq(covRunner(), 5)
		sert.eq(covRunner(), 5)
		sert.eq(table.isfrozen(frozenCovMod.protos[1].code :: any), true)
	end)

	test("supports EnvironmentOptions libraries allowlists, readOnly, and inheritHost", function()
		local HostEnv = require("../src/VM/HostEnv")
		local mathOnlyEnv = VM.createEnvironment(nil, { libraries = { "base", "math" } })
		local fn = assert(
			VM.load(
				"return math.abs(-12), os == nil, debug == nil, bit32 == nil, string == nil, table == nil",
				{ name = "=libs_allow", env = mathOnlyEnv }
			)
		)
		local absVal, noOs, noDbg, noBit, noStr, noTbl = fn()
		sert.eq(absVal, 12)
		sert.eq(noOs, true)
		sert.eq(noDbg, true)
		sert.eq(noBit, true)
		sert.eq(noStr, true)
		sert.eq(noTbl, true)

		local okBadLib, errBadLib = pcall(function()
			return VM.createEnvironment(nil, { libraries = { "nonexistent_lib" } })
		end)
		sert.eq(okBadLib, false)
		expect(string.find(tostring(errBadLib), "unknown standard library", 1, true) ~= nil, tostring(errBadLib))

		local roEnv = VM.createEnvironment({ seed = 7 }, { readOnly = true })
		sert.eq(table.isfrozen(roEnv), true)
		local readFn = assert(VM.load("return seed + math.abs(-3)", { name = "=ro_read", env = roEnv }))
		sert.eq(readFn(), 10)
		local writeFn = assert(VM.load("mutated = 1", { name = "=ro_write", env = roEnv }))
		local okRoWrite, errRoWrite = pcall(writeFn)
		sert.eq(okRoWrite, false)
		expect(string.find(tostring(errRoWrite), "readonly", 1, true) ~= nil, tostring(errRoWrite))

		local hostTbl = HostEnv.getHostEnv();
		(hostTbl :: any).__ouroLibHostProbe = 55
		local okMix, errMix = pcall(function()
			local mixEnv = VM.createEnvironment(nil, { libraries = { "base", "math" }, inheritHost = true })
			local mixFn = assert(
				VM.load(
					"return math.abs(-5), __ouroLibHostProbe, os == nil, bit32 == nil",
					{ name = "=libs_host", env = mixEnv }
				)
			)
			local a, b, c, d = mixFn()
			sert.eq(a, 5)
			sert.eq(b, 55)
			sert.eq(c, true)
			sert.eq(d, true)
		end);
		(hostTbl :: any).__ouroLibHostProbe = nil
		assert(okMix, tostring(errMix))
	end)

	test("supports VM.sandbox isolated overlays sharing a frozen base environment", function()
		local baseEnv = VM.createEnvironment({ sharedConst = 7 }, { readOnly = true })
		local sbA = VM.sandbox(baseEnv, { tag = "A" })
		local sbB = VM.sandbox(baseEnv)

		local fnA = assert(
			VM.load(
				"chunkSecret = 123; return tag, sharedConst + math.abs(-3) + bit32.bxor(6, 3)",
				{ name = "=sb_a", env = sbA }
			)
		)
		local tagA, sumA = fnA()
		sert.eq(tagA, "A")
		sert.eq(sumA, 15)
		sert.eq(baseEnv.chunkSecret, nil)

		local fnB = assert(
			VM.load(
				"return tag == nil and chunkSecret == nil and sharedConst == 7 and _G.chunkSecret == nil",
				{ name = "=sb_b", env = sbB }
			)
		)
		sert.eq(fnB(), true)

		local defSb = VM.sandbox()
		local fnDef = assert(VM.load("localSide = 9; return math.abs(-4) + localSide, _G.localSide", {
			name = "=sb_def",
			env = defSb,
		}))
		local s1, s2 = fnDef()
		sert.eq(s1, 13)
		sert.eq(s2, 9)
	end)

	test("supports custom LoadOptions.getGlobal, setGlobal, safeEnv, and host wrappers", function()
		local strictGets: { string } = {}
		local fakeTree = { sub = { leaf = 88 } }
		local strictFn =
			assert(VM.load("local x, s = ...; return customVal + pkg.sub.leaf + math.abs(x) + tonumber(s)", {
				name = "=get_strict",
				env = {},
				compile = { optimizationLevel = 2 },
				getGlobal = function(name: string, _env: { [any]: any }): any
					table.insert(strictGets, name)
					if name == "customVal" then
						return 10
					elseif name == "pkg" then
						return fakeTree
					elseif name == "math" then
						return math
					elseif name == "tonumber" then
						return tonumber
					end
					return nil
				end,
			}))
		sert.eq(strictFn(-4, "5"), 107)
		expect(table.find(strictGets, "customVal") ~= nil, "strict getGlobal saw customVal")
		expect(table.find(strictGets, "pkg") ~= nil, "strict getGlobal saw 3-part import pkg")
		expect(table.find(strictGets, "math") ~= nil, "strict getGlobal intercepted math")
		expect(table.find(strictGets, "tonumber") ~= nil, "strict getGlobal intercepted tonumber")

		-- safeEnv = true on default env keeps unmodified builtins on fast path; empty env = {} never leaks absent builtins
		local safeStdGets: { string } = {}
		local safeStdEnv = VM.createEnvironment()
		local safeStdFn =
			assert(VM.load("local x, xorA, xorB = ...; return customSeed + math.abs(x) + bit32.bxor(xorA, xorB)", {
				name = "=safe_std",
				env = safeStdEnv,
				compile = { optimizationLevel = 2 },
				safeEnv = true,
				getGlobal = function(name: string, _env: { [any]: any }): any
					table.insert(safeStdGets, name)
					if name == "customSeed" then
						return 20
					end
					return nil
				end,
			}))
		sert.eq(safeStdFn(-9, 5, 3), 35)
		sert.eq(table.find(safeStdGets, "customSeed") ~= nil, true)
		sert.eq(table.find(safeStdGets, "math"), nil)
		sert.eq(table.find(safeStdGets, "bit32"), nil)

		local safeEmptyGets: { string } = {}
		local safeEmptyFn = assert(VM.load("local x = ...; return math.abs(x)", {
			name = "=safe_empty",
			env = {},
			compile = { optimizationLevel = 2 },
			safeEnv = true,
			getGlobal = function(name: string, _env: { [any]: any }): any
				table.insert(safeEmptyGets, name)
				return nil
			end,
		}))
		local okEmpty, _errEmpty = pcall(safeEmptyFn, -9)
		sert.eq(okEmpty, false)
		sert.eq(table.find(safeEmptyGets, "math") ~= nil, true)

		-- Explicit override in sandbox/env with safeEnv = true disables only the overridden root fastcall
		local safeOverrideGets: { string } = {}
		local overrideEnv = VM.sandbox(nil, {
			math = {
				abs = function(n: number)
					return n * 100
				end,
			},
		})
		local safeOverrideFn = assert(VM.load("local x, y = ...; return math.abs(x) + bit32.bxor(y, x) + bonus", {
			name = "=safe_override",
			env = overrideEnv,
			compile = { optimizationLevel = 2 },
			safeEnv = true,
			getGlobal = function(name: string, env: { [any]: any }): any
				table.insert(safeOverrideGets, name)
				if name == "bonus" then
					return 4
				end
				return env[name]
			end,
		}))
		sert.eq(safeOverrideFn(3, 5), 310)
		sert.eq(table.find(safeOverrideGets, "bit32"), nil)

		-- safeEnv = false disables fastcalls and import caching even without hooks
		local counter = 0
		local dynEnv = setmetatable({
			fakeNum = 1,
		}, {
			__index = function(_self: any, k: any): any
				if k == "math" then
					counter += 1
					return {
						abs = function(x: number)
							return x + counter * 10
						end,
					}
				end
				return nil
			end,
		})
		local noSafeFn = assert(VM.load("local x = ...; local a = math.abs(x); local b = math.abs(x); return a, b", {
			name = "=nosafe",
			env = dynEnv,
			compile = { optimizationLevel = 2 },
			safeEnv = false,
		}))
		local ns1, ns2 = noSafeFn(1)
		sert.eq(ns1, 11)
		sert.eq(ns2, 21)

		-- setGlobal intercepts, transforms, and rejects writes
		local store: { [string]: any } = {}
		local rawTarget = VM.createEnvironment()
		local setFn = assert(VM.load("scaled = 21; return 1", {
			name = "=set_hook",
			env = rawTarget,
			compile = { optimizationLevel = 2 },
			setGlobal = function(name: string, value: any, _env: { [any]: any })
				if name == "blocked" then
					error("write blocked", 0)
				end
				store[name] = (value :: number) * 2
			end,
		}))
		sert.eq(setFn(), 1)
		sert.eq(store.scaled, 42)
		sert.eq(rawTarget.scaled, nil)
		local rejectFn = assert(VM.load("blocked = 5", {
			name = "=set_reject",
			env = {},
			compile = { optimizationLevel = 2 },
			setGlobal = function(name: string, _value: any, _env: { [any]: any })
				if name == "blocked" then
					error("write blocked", 0)
				end
			end,
		}))
		local okRej, errRej = pcall(rejectFn)
		sert.eq(okRej, false)
		expect(string.find(tostring(errRej), "write blocked", 1, true) ~= nil, tostring(errRej))

		-- HOST_WRAPPERS applies when getGlobal returns host debug or error
		local wrapFn = assert(VM.load(
			[[
					local function inner()
						return debug.traceback("mark", 1)
					end
					local fns = { inner }
					local tb = fns[1]()
					local okErr, msg = pcall(function()
						error("guest_err", 0)
					end)
					return tb, okErr, msg
				]],
			{
				name = "=hook_wrappers",
				env = {},
				compile = { optimizationLevel = 2 },
				getGlobal = function(name: string, _env: { [any]: any }): any
					if name == "debug" then
						return debug
					elseif name == "error" then
						return error
					elseif name == "pcall" then
						return pcall
					end
					return nil
				end,
			}
		))
		local wTb, wOk, wMsg = wrapFn()
		sert.eq(wOk, false)
		sert.eq(wMsg, "guest_err")
		sert.eq(string.find(tostring(wTb), "inner", 1, true) ~= nil, true)
		sert.eq(string.find(tostring(wTb), "Dispatch", 1, true), nil)
		sert.eq(string.find(tostring(wTb), "RuntimeEnv", 1, true), nil)
	end)

	test("enforces per-root safeRootsMask invalidation and static chain lookup", function()
		local partialEnv = VM.createEnvironment({
			math = {
				abs = function(x: number)
					return x + 1000
				end,
			},
		})
		local partialFn = assert(VM.load("local a, b, c = ...; return math.abs(a), bit32.bxor(b, 5), string.byte(c)", {
			name = "=partial_roots",
			env = partialEnv,
			compile = { optimizationLevel = 2 },
		}))
		local mVal, bVal, sVal = partialFn(5, 9, "Z")
		sert.eq(mVal, 1005)
		sert.eq(bVal, 12)
		sert.eq(sVal, 90)

		-- Dynamic mutation of unrelated global keeps builtins; mutating math invalidates math without breaking bit32/ipairs
		local dynEnv = VM.createEnvironment()
		local dynFn = assert(VM.load(
			[[
					local x1, x2 = ...
					foo = 42
					local a1 = math.abs(x1)
					math = { abs = function(x) return x + 200 end }
					local a2 = math.abs(x2)
					local b = bit32.bxor(6, x2)
					local sum = 0
					for _, v in ipairs({ 10, 20 }) do
						sum += v
					end
					return foo, a1, a2, b, sum
				]],
			{
				name = "=dyn_roots",
				env = dynEnv,
				compile = { optimizationLevel = 2 },
			}
		))
		local fooVal, a1, a2, b, ipSum = dynFn(-3, 7)
		sert.eq(fooVal, 42)
		sert.eq(a1, 3)
		sert.eq(a2, 207)
		sert.eq(b, 1)
		sert.eq(ipSum, 30)

		-- Table-only __index chain
		local chainParent = VM.createEnvironment({ chainSeed = 33 })
		local chainEnv = setmetatable({}, { __index = chainParent })
		local chainFn =
			assert(VM.load("local x, xorA, xorB = ...; return chainSeed + math.abs(x) + bit32.bxor(xorA, xorB)", {
				name = "=chain_roots",
				env = chainEnv,
				compile = { optimizationLevel = 2 },
			}))
		sert.eq(chainFn(-4, 5, 3), 43)
	end)

	test("supports VM.getCoverage across coverage levels and multi-proto modules", function()
		sert.eq(VM.getCoverage(print), nil)
		sert.eq(VM.getCoverage(123 :: any), nil)

		local noCovFn = assert(VM.load("return 1", { name = "=nocov", compile = { coverageLevel = 0 } }))
		noCovFn()
		local emptyCov = assert(VM.getCoverage(noCovFn))
		sert.eq(#emptyCov, 0)

		local covSrc = [[
local function helper(flag)
	if flag then
		return 10
	else
		return 20
	end
end
local calls = { helper }
local f1, f2 = ...
return calls[1](f1) + calls[1](f2)
]]
		for _, level in { 1, 2 } do
			local covFn = assert(VM.load(covSrc, {
				name = "=cov_mod",
				compile = { optimizationLevel = 2, coverageLevel = level },
			}))
			sert.eq(covFn(true, true), 20)
			local entries = assert(VM.getCoverage(covFn))
			expect(#entries >= 2, "expected entries for helper and main chunk")
			local foundHelper = false
			for _, entry in entries do
				local sum = 0
				for _, cnt in entry.hits do
					sum += cnt
				end
				sert.eq(entry.totalHits, sum)
				if entry.name == "helper" then
					foundHelper = true
					sert.eq(entry.lineDefined, 1)
					sert.eq(entry.hits[2], 2)
					sert.eq(entry.hits[3], 2 * level)
					sert.eq(entry.hits[5], 0)
				end
			end
			expect(foundHelper, "expected helper proto coverage entry")

			-- Now execute the else branch and verify line 5 accumulates coverage
			sert.eq(covFn(false, true), 30)
			local entriesAfter = assert(VM.getCoverage(covFn))
			local foundElse = false
			for _, entry in entriesAfter do
				if entry.name == "helper" then
					foundElse = true
					sert.eq(entry.hits[2], 4)
					sert.eq(entry.hits[3], 3 * level)
					sert.eq(entry.hits[5], level)
				end
			end
			expect(foundElse, "expected helper coverage entry after else branch")
		end
	end)

	test("supports VM.cloneFunction with independent env, limits, and shared upvalues", function()
		sert.eq(VM.cloneFunction(print :: any), nil)

		local envA = VM.createEnvironment({ tag = "orig" })
		local envB = VM.createEnvironment({ tag = "cloned" })
		local origFn = assert(VM.load(
			[[
					local count = 0
					return function(overrideEnv)
						if overrideEnv then
							setfenv(1, overrideEnv)
						end
						count += 1
						return count, tag
					end
				]],
			{
				name = "=clone_src",
				env = envA,
				compile = { debugLevel = 2, optimizationLevel = 1 },
			}
		))()

		local c1, t1 = origFn()
		sert.eq(c1, 1)
		sert.eq(t1, "orig")

		-- Default clone shares upvalue cell and isolates setfenv
		local cloneSame = assert(VM.cloneFunction(origFn))
		local c2, t2 = cloneSame({ tag = "fenv_isolated" })
		sert.eq(c2, 2)
		sert.eq(t2, "fenv_isolated")
		local c3, t3 = origFn()
		sert.eq(c3, 3)
		sert.eq(t3, "orig")

		-- Clone with newEnv + new LoadOptions enforces new limits without affecting origFn
		local cloneIsolated = assert(VM.cloneFunction(origFn, envB, { instructionLimit = 500 }))
		local c4, t4 = cloneIsolated()
		sert.eq(c4, 4)
		sert.eq(t4, "cloned")

		-- Mutate shared upvalue cell through clone
		sert.eq(VM.setUpvalue(cloneIsolated, 1, 99), true)
		local c5, _ = origFn()
		sert.eq(c5, 100)
	end)

	test("supports VM.getUpvalues and VM.setUpvalue on open and closed upvalues", function()
		sert.eq(VM.getUpvalues(print), nil)
		sert.eq(VM.getUpvalues("not_fn"), nil)
		sert.eq(VM.setUpvalue(print, 1, 10), false)

		local hostBridge = {
			inspectOpen = function(inner: () -> number)
				local uvs = assert(VM.getUpvalues(inner))
				sert.eq(#uvs, 1)
				sert.eq(uvs[1].name, "openVal")
				sert.eq(uvs[1].value, 5)
				sert.eq(VM.setUpvalue(inner, 1, 50), true)
			end,
		}
		local env = VM.createEnvironment({ bridge = hostBridge })
		local makePair = assert(VM.load(
			[[
					local openVal = 5
					local function readOpen()
						openVal += 1
						return openVal
					end
					bridge.inspectOpen(readOpen)
					local afterOpen = openVal
					local closedCount = 10
					return afterOpen, function()
						closedCount += 1
						return closedCount
					end
				]],
			{
				name = "=upvals",
				env = env,
				compile = { debugLevel = 2, optimizationLevel = 0 },
			}
		))
		local afterOpen, closedFn = makePair()
		sert.eq(afterOpen, 50)

		local uvs = assert(VM.getUpvalues(closedFn))
		sert.eq(#uvs, 1)
		sert.eq(uvs[1].index, 1)
		sert.eq(uvs[1].name, "closedCount")
		sert.eq(uvs[1].value, 10)

		sert.eq(VM.setUpvalue(closedFn, 0, 99), false)
		sert.eq(VM.setUpvalue(closedFn, 1.5, 99), false)
		sert.eq(VM.setUpvalue(closedFn, 2, 99), false)
		sert.eq(VM.setUpvalue(closedFn, 1, 41), true)
		sert.eq(closedFn(), 42)
	end)

	test("supports LoadOptions debug hooks (onCall, onReturn, onLine, onBreak) and unwinds errors cleanly", function()
		type CallLogEntry = {
			name: string?,
			depth: number,
			line: number,
			source: string,
			numparams: number,
			isvararg: boolean,
		}
		type ReturnLogEntry = { name: string?, depth: number }
		type LineLogEntry = { line: number, name: string?, depth: number }

		local callLog: { CallLogEntry } = {}
		local returnLog: { ReturnLogEntry } = {}
		local lineLog: { LineLogEntry } = {}

		local hookFn = assert(VM.load(
			[[local function add(a, b)
	local s = a + b
	return s
end
local r = add(20, 22)
return r]],
			{
				name = "=dbg_hooks",
				compile = { optimizationLevel = 0, debugLevel = 2 },
				onCall = function(info)
					local entry: CallLogEntry = {
						name = info.name,
						depth = info.depth,
						line = info.line,
						source = info.source,
						numparams = info.numparams,
						isvararg = info.isvararg,
					}
					table.insert(callLog, entry)
				end,
				onReturn = function(info)
					local entry: ReturnLogEntry = { name = info.name, depth = info.depth }
					table.insert(returnLog, entry)
				end,
				onLine = function(line, info)
					local entry: LineLogEntry = { line = line, name = info.name, depth = info.depth }
					table.insert(lineLog, entry)
				end,
			}
		))
		sert.eq(hookFn(), 42)
		sert.eq(#callLog, 2)
		sert.eq(callLog[1].depth, 1)
		sert.eq(callLog[1].source, "dbg_hooks")
		sert.eq(callLog[2].name, "add")
		sert.eq(callLog[2].depth, 2)
		sert.eq(callLog[2].numparams, 2)
		sert.eq(callLog[2].isvararg, false)
		sert.eq(#returnLog, 2)
		sert.eq(returnLog[1].name, "add")
		sert.eq(returnLog[1].depth, 2)
		sert.eq(returnLog[2].depth, 1)
		local expectedSeq = { { 1, 1 }, { 5, 1 }, { 2, 2 }, { 3, 2 }, { 6, 1 } }
		sert.eq(#lineLog, #expectedSeq)
		for i, pair in expectedSeq do
			sert.eq(lineLog[i].line, pair[1], `onLine step #{i} line`)
			sert.eq(lineLog[i].depth, pair[2], `onLine step #{i} depth`)
		end

		-- onBreak via BytecodeBuilder emitting LOP_BREAK
		local bcb = BytecodeBuilder.new()
		local fid = bcb:beginFunction(0, false)
		bcb:setDebugFunctionName("brk")
		bcb:setDebugFunctionLineDefined(10)
		bcb:setDebugLine(11)
		bcb:emitAD(Opcodes.LOP_LOADN, 0, 42)
		bcb:setDebugLine(12)
		bcb:emitABC(Opcodes.LOP_BREAK, 0, 0, 0)
		bcb:setDebugLine(13)
		bcb:emitABC(Opcodes.LOP_RETURN, 0, 2, 0)
		bcb:endFunction(2, 0, 0)
		bcb:setMainFunction(fid)
		bcb:finalize()

		local breakLines: { number } = {}
		local breakNames: { string? } = {}
		local brkFn = assert(VM.loadBytecode(bcb:getBytecode(), {
			name = "=brk_chunk",
			onBreak = function(line, info)
				table.insert(breakLines, line)
				table.insert(breakNames, info.name)
			end,
		}))
		sert.eq(brkFn(), 42)
		sert.eq(#breakLines, 1)
		sert.eq(breakLines[1], 12)
		sert.eq(breakNames[1], "brk")

		-- Errors inside hooks unwind frames cleanly without leaving stale thread state
		for _, hookField in { "onCall", "onLine", "onReturn", "onBreak" } do
			local opts: any = {
				name = "=err_" .. hookField,
				compile = { optimizationLevel = 0 },
			}
			opts[hookField] = function()
				error("hook_abort_" .. hookField, 0)
			end
			local targetFn = if hookField == "onBreak"
				then assert(VM.loadBytecode(bcb:getBytecode(), opts))
				else assert(VM.load("local function f() return 1 end return f()", opts))
			local okHook, errHook = pcall(targetFn)
			sert.eq(okHook, false)
			expect(string.find(tostring(errHook), "hook_abort_" .. hookField, 1, true) ~= nil, tostring(errHook))
		end

		-- Thread depth remains clean after hook unwinds
		local postDepth = 0
		local postFn = assert(VM.load("return 99", {
			name = "=post_unwind",
			onCall = function(info)
				postDepth = info.depth
			end,
		}))
		sert.eq(postFn(), 99)
		sert.eq(postDepth, 1)
	end)

	test(
		"tracks upvalues after loadBytecode, DUPCLOSURE signed zero, LBF_SELECT_VARARG, coroutine debug.info, and custom vectorLib",
		function()
			-- 1. VM.getUpvalues names after loadBytecode, VM.setUpvalue invalidating DUPCLOSURE cache, and DUPCLOSURE +0.0 vs -0.0
			local Compiler = require("../src/Compiler")
			local uvBc = assert(Compiler.compile(
				[[
				local seed = ...
				local pair = {}
				for i = 1, 2 do
					pair[i] = function()
						return seed
					end
				end
				return pair[1], pair[2]
			]],
				{ optimizationLevel = 2, debugLevel = 2 }
			))
			local uvFactory = assert(VM.loadBytecode(uvBc, { name = "=uv_bc" }))
			local readerFn, dupFn = uvFactory(10)
			sert.eq(readerFn == dupFn, true)
			local uvs = assert(VM.getUpvalues(readerFn))
			sert.eq(#uvs, 1)
			sert.eq(uvs[1].name, "seed")
			sert.eq(uvs[1].value, 10)
			sert.eq(VM.setUpvalue(readerFn, 1, 99), true)
			sert.eq(readerFn(), 99)
			-- VM.setUpvalue must invalidate DUPCLOSURE cache so next factory call gets fresh upvalue 10
			local freshReader, freshDup = uvFactory(10)
			sert.eq(freshReader == readerFn, false)
			sert.eq(freshReader == freshDup, true)
			sert.eq(freshReader(), 10)

			-- Two distinct upvalue values (+0.0 vs -0.0) across calls to DUPCLOSURE must never alias in dupClosureCache
			local posZeroFn = uvFactory(0.0)
			local negZeroFn = uvFactory(-0.0)
			sert.eq(posZeroFn == negZeroFn, false)
			sert.eq(1 / posZeroFn() > 0, true)
			sert.eq(1 / negZeroFn() < 0, true)

			-- 2. LBF_SELECT_VARARG fastcall path and xpcall frame ordering
			local selXpFn = assert(VM.load(
				[[
				local function selCount(...)
					return select("#", ...)
				end
				local function selAt(i, ...)
					return select(i, ...)
				end
				local function innerErr()
					error("xp_inner")
				end
				local function outerXp(...)
					return xpcall(function()
						return innerErr()
					end, function(msg)
						return msg .. "!!" .. debug.traceback("snap", 1)
					end)
				end
				local xOk, xMsg = outerXp()
				return selCount(), selCount("a", "b", "c"), selAt(2, 10, 20, 30), xOk, xMsg
			]],
				{ name = "=sel_xp", compile = { optimizationLevel = 2 } }
			))
			local sc0, sc3, sa2, xOk, xMsg = selXpFn()
			sert.eq(sc0, 0)
			sert.eq(sc3, 3)
			sert.eq(sa2, 20)
			sert.eq(xOk, false)
			local xMsgStr = tostring(xMsg)
			local innerPos = string.find(xMsgStr, "function innerErr", 1, true)
			local outerPos = string.find(xMsgStr, "function outerXp", 1, true)
			expect(innerPos ~= nil, xMsgStr)
			expect(outerPos ~= nil, xMsgStr)
			expect((innerPos :: number) < (outerPos :: number), xMsgStr)
			expect(string.find(xMsgStr, "function innerErr", (innerPos :: number) + 1, true) == nil, xMsgStr)

			-- 3. debug.info(co, 0) & debug.traceback(co, nil, 1) on unstarted and suspended coroutines
			local coProbeFn = assert(VM.load(
				[[
				local function inner()
					coroutine.yield("paused")
				end
				local function outer()
					inner()
				end
				local co = coroutine.create(outer)
				local unS = debug.info(co, 0, "s")
				coroutine.resume(co)
				local s0, l0, n0, _, _, fn0 = debug.info(co, 0, "slnaf")
				local s1, n1 = debug.info(co, 1, "sn")
				local tb1 = debug.traceback(co, nil, 1)
				return unS == nil, s0, l0, n0, fn0 == coroutine.yield, s1, n1, tb1
			]],
				{ name = "=co_dbg" }
			))
			local isUnNil, s0, l0, n0, isYieldFn, s1, n1, tb1 = coProbeFn()
			sert.eq(isUnNil, true)
			sert.eq(s0, "[C]")
			sert.eq(l0, -1)
			sert.eq(n0, "yield")
			sert.eq(isYieldFn, true)
			sert.eq(s1, "co_dbg")
			sert.eq(n1, "inner")
			expect(string.find(tostring(tb1), "function inner\n", 1, true) ~= nil, tostring(tb1))
			expect(string.find(tostring(tb1), "function outer", 1, true) ~= nil, tostring(tb1))

			-- 4. LBF_VECTOR with custom vectorLib & vectorCtor
			local customVecFn = assert(VM.load(
				[[
				local x = ...
				local v = CustomVec.make(x, 4, 5)
				return v[1], v[2], v[3]
			]],
				{
					name = "=custom_vec",
					env = VM.createEnvironment({
						CustomVec = {
							make = function(x: number, y: number, z: number)
								return { x * 10, y * 10, z * 10 }
							end,
						},
					}),
					compile = {
						optimizationLevel = 2,
						vectorLib = "CustomVec",
						vectorCtor = "make",
						vectorType = "CustomVec",
					},
				}
			))
			local cv1, cv2, cv3 = customVecFn(3)
			sert.eq(cv1, 30)
			sert.eq(cv2, 40)
			sert.eq(cv3, 50)
		end
	)

	test("routes _G SETTABLE to setGlobal and inherits LoadOptions in VM.cloneFunction", function()
		-- 1. _G[k] = v via SETTABLEKS and runtime SETTABLE routes string keys to setGlobal, non-string keys bypass it
		local gSetLog: { [any]: any } = {}
		local gSetEnv = VM.createEnvironment()
		local gSetFn = assert(VM.load(
			[[
				local dynKey = ...
				_G.dotKey = 11
				_G[dynKey] = 22
				_G[1] = 33
				return _G[1]
			]],
			{
				name = "=g_settable",
				env = gSetEnv,
				setGlobal = function(name: string, val: any, _env: { [any]: any })
					gSetLog[name] = val
				end,
			}
		))
		sert.eq(gSetFn("bracketKey"), 33)
		sert.eq(gSetLog.dotKey, 11)
		sert.eq(gSetLog.bracketKey, 22)
		sert.eq(gSetLog[1], nil)
		sert.eq(gSetEnv[1], 33)

		-- 2. VM.cloneFunction inherits LoadOptions limits and hooks when loadOptions == nil
		local cloneCalls = 0
		local origLimited = assert(VM.load(
			[[
				return function(n)
					local s = 0
					for i = 1, n do
						s += i
					end
					return s
				end
			]],
			{
				name = "=clone_inherit",
				instructionLimit = 80,
				onCall = function(_info)
					cloneCalls += 1
				end,
			}
		))()
		local clonedInherited = assert(VM.cloneFunction(origLimited))
		cloneCalls = 0
		sert.eq(clonedInherited(3), 6)
		sert.eq(cloneCalls, 1)
		local okInheritedLimit, errInheritedLimit = pcall(clonedInherited, 200)
		sert.eq(okInheritedLimit, false)
		expect(
			string.find(tostring(errInheritedLimit), "instruction limit exceeded", 1, true) ~= nil,
			tostring(errInheritedLimit)
		)
	end)

	test("invalidates safeRootsMask on rawset/table.clear and supports callable pairs/ipairs overrides", function()
		-- 1. rawset(env) and table.clear(env) invalidate safeRootsMask dynamically
		local rawMutEnv = VM.createEnvironment()
		local rawMutFn = assert(VM.load(
			[[
				local x = ...
				local before = math.abs(x)
				rawset(_G, "math", { abs = function() return 777 end })
				local afterRawset = math.abs(x)
				table.clear(_G)
				local okCleared, bitVal = pcall(function()
					return bit32.bxor(x, 2)
				end)
				return before, afterRawset, okCleared, bitVal
			]],
			{
				name = "=rawset_clear",
				env = rawMutEnv,
				compile = { optimizationLevel = 2, flags = { LuauCompileTableBuiltinsCreateClear = true } },
			}
		))
		local rb, ra, okClr, bitVal = rawMutFn(-5)
		sert.eq(rb, 5)
		sert.eq(ra, 777)
		sert.eq(okClr, true) -- _G falls back to metatable __index pureGlobals.bit32 after table.clear raw keys
		sert.eq(bitVal, bit32.bxor(-5, 2))

		local baseWithCustomMath = VM.createEnvironment({
			math = {
				abs = function(v: number)
					return v * 1000
				end,
			},
		}, { readOnly = true })
		local rawOverrideEnv = VM.sandbox(baseWithCustomMath, { math = math })
		local rawClrOvFn = assert(VM.load(
			[[
				local x = ...
				local fastVal = math.abs(x)
				math = { abs = function() return 888 end }
				local overridden = math.abs(x)
				table.clear(_G)
				local restored = math.abs(x)
				return fastVal, overridden, restored
			]],
			{
				name = "=rawset_override_clear",
				env = rawOverrideEnv,
				compile = { optimizationLevel = 2, flags = { LuauCompileTableBuiltinsCreateClear = true } },
			}
		))
		local fv, ov1, ov2 = rawClrOvFn(-2)
		sert.eq(fv, 2)
		sert.eq(ov1, 888)
		sert.eq(ov2, -2000)

		-- 2. Callable table pairs/ipairs override in FORGPREP_NEXT / FORGPREP_INEXT
		local callableIterFn = assert(VM.load(
			[[
				local nextSpy = setmetatable({}, {
					__call = function(_, t, k)
						if k == nil then
							return "only", 42
						end
						return nil
					end,
				})
				local pairs = function(t)
					return nextSpy, t, nil
				end
				local gotK, gotV
				for k, v in pairs({ a = 1 }) do
					gotK, gotV = k, v
				end
				local ipairs = function(t)
					return nextSpy, t, nil
				end
				local ipK, ipV
				for k, v in ipairs({ 10 }) do
					ipK, ipV = k, v
				end
				return gotK, gotV, ipK, ipV
			]],
			{ name = "=callable_iter", compile = { optimizationLevel = 2 } }
		))
		local gk, gv, ik, iv = callableIterFn()
		sert.eq(gk, "only")
		sert.eq(gv, 42)
		sert.eq(ik, "only")
		sert.eq(iv, 42)
	end)

	test("isolates xpcall error handlers across nested pcall and multiple host boundaries", function()
		local bridgeCalls = 0
		local env = VM.createEnvironment({
			hostBridge = function(fn: () -> ...any)
				bridgeCalls += 1
				return fn()
			end,
		})
		local fn = assert(VM.load(
			[[
			local function leaf(shouldFail)
				if shouldFail then
					error("leaf_boom")
				end
				return 99
			end
			local function mid2(shouldFail)
				return hostBridge(function()
					return leaf(shouldFail)
				end)
			end
			local function mid1(shouldFail)
				return mid2(shouldFail)
			end
			local function outer(shouldFail)
				return hostBridge(function()
					return mid1(shouldFail)
				end)
			end

			local handlerHits = 0
			local handlerSelfName = nil
			local function errHandler(errMsg)
				handlerHits += 1
				local _, n = debug.info(1, "sn")
				handlerSelfName = n
				return errMsg .. "|" .. debug.traceback("snap", 1)
			end

			local okOuter, resOuter = xpcall(function()
				local okInner, errInner = pcall(hostBridge, function()
					return leaf(true)
				end)
				assert(not okInner and string.find(tostring(errInner), "leaf_boom", 1, true) ~= nil)
				return outer(true)
			end, errHandler)
			return okOuter, resOuter, handlerHits, handlerSelfName
		]],
			{ name = "=xp_multi_host", env = env }
		))
		local okOuter, resOuter, handlerHits, handlerSelfName = fn()
		sert.eq(okOuter, false)
		sert.eq(handlerHits, 1)
		sert.eq(handlerSelfName, "errHandler")
		sert.eq(bridgeCalls, 3)

		local traceStr = tostring(resOuter)
		expect(string.find(traceStr, "leaf_boom", 1, true) ~= nil, traceStr)
		local pLeaf = string.find(traceStr, "function leaf\n", 1, true)
		local pMid2 = string.find(traceStr, "function mid2\n", 1, true)
		local pMid1 = string.find(traceStr, "function mid1\n", 1, true)
		local pOuter = string.find(traceStr, "function outer\n", 1, true)
		expect(pLeaf ~= nil and pMid2 ~= nil and pMid1 ~= nil and pOuter ~= nil, traceStr)
		expect(
			(pLeaf :: number) < (pMid2 :: number)
				and (pMid2 :: number) < (pMid1 :: number)
				and (pMid1 :: number) < (pOuter :: number),
			traceStr
		)
		sert.eq(string.find(traceStr, "Dispatch.luau", 1, true), nil)
		sert.eq(string.find(traceStr, "RuntimeEnv.luau", 1, true), nil)
		sert.eq(string.find(traceStr, "VM/", 1, true), nil)
	end)

	test("prevents internal .luau file path leaks across error and debug API paths", function()
		local leakCheckFn = assert(VM.load(
			[[
			local calls = {
				function() return (xpcall :: any)(1, 2) end,
				function() return debug.traceback({} :: any, 1) end,
				function() return debug.traceback("", -1) end,
				function() return debug.info(0, "z") end,
				function() return debug.info(0, "ss") end,
			}
			local errs = {}
			for i = 1, #calls do
				local ok, err = pcall(calls[i])
				errs[i] = { ok = ok, err = tostring(err) }
			end
			return errs
		]],
			{ name = "=no_leak_paths" }
		))
		local errs = leakCheckFn()
		sert.eq(#errs, 5)
		for i, entry in errs do
			sert.eq(entry.ok, false, `error path #{i} must fail`)
			sert.eq(string.find(entry.err, "Dispatch.luau", 1, true), nil, entry.err)
			sert.eq(string.find(entry.err, "RuntimeEnv.luau", 1, true), nil, entry.err)
			sert.eq(string.find(entry.err, "VM/init.luau", 1, true), nil, entry.err)
			sert.eq(string.find(entry.err, "src/VM", 1, true), nil, entry.err)
		end
	end)

	test(
		"enforces nested coroutine callLimit, sticky interrupt, vmXpcall timeout, limit validation, threadEnv isolation, and coroutine.close cleanup",
		function()
			-- 1. callLimit enforced across nested coroutines sharing module context
			local coLimitFn = assert(VM.load(
				[[
				local function spawnAndResume(depth)
					if depth <= 0 then
						return 1
					end
					local co = coroutine.create(function()
						return spawnAndResume(depth - 1) + 1
					end)
					local ok, res = coroutine.resume(co)
					if not ok then
						error(res, 0)
					end
					return res
				end
				return spawnAndResume(...)
			]],
				{ name = "=co_limit", callLimit = 4 }
			))
			local okCoLim, errCoLim = pcall(coLimitFn, 10)
			sert.eq(okCoLim, false)
			expect(string.find(tostring(errCoLim), "call stack overflow", 1, true) ~= nil, tostring(errCoLim))

			-- 2. Sticky interrupt surviving pcall loops + vmXpcall timeout
			local intrCalls = 0
			local stickyFn = assert(VM.load(
				[[
				local loops = 0
				while true do
					loops += 1
					pcall(function()
						while true do
						end
					end)
				end
				return loops
			]],
				{
					name = "=sticky_intr",
					interruptInterval = 32,
					interrupt = function(): boolean?
						intrCalls += 1
						return false
					end,
				}
			))
			local okSticky, errSticky = pcall(stickyFn)
			sert.eq(okSticky, false)
			sert.eq(intrCalls, 1)
			expect(string.find(tostring(errSticky), "execution interrupted", 1, true) ~= nil, tostring(errSticky))

			local xpTimeoutFn = assert(VM.load(
				[[
				return xpcall(function()
					local s = 0
					for i = 1, 1000000 do
						s += i
					end
					return s
				end, function(e)
					return "caught:" .. tostring(e)
				end)
			]],
				{
					name = "=xp_timeout",
					timeout = 0,
					interruptInterval = 64,
				}
			))
			local okXpTo, errXpTo = pcall(xpTimeoutFn)
			sert.eq(okXpTo, false)
			expect(
				string.find(tostring(errXpTo), "execution interrupted", 1, true) ~= nil
					or string.find(tostring(errXpTo), "timeout", 1, true) ~= nil,
				tostring(errXpTo)
			)

			-- 3. NaN / negative budget and interval rejections
			local badOptCases: { { opts: any, match: string } } = {
				{ opts = { name = 123 }, match = "invalid chunk name" },
				{ opts = { instructionLimit = -1 }, match = "invalid instructionLimit" },
				{ opts = { instructionLimit = 0 / 0 }, match = "invalid instructionLimit" },
				{ opts = { instructionLimit = "10" }, match = "invalid instructionLimit" },
				{ opts = { callLimit = -1 }, match = "invalid callLimit" },
				{ opts = { callLimit = 0 / 0 }, match = "invalid callLimit" },
				{ opts = { timeout = -0.1 }, match = "invalid timeout" },
				{ opts = { timeout = 0 / 0 }, match = "invalid timeout" },
				{ opts = { interruptInterval = 0 }, match = "invalid interruptInterval" },
				{ opts = { interruptInterval = 1.5 }, match = "invalid interruptInterval" },
				{ opts = { interruptInterval = math.huge }, match = "invalid interruptInterval" },
				{ opts = { interruptInterval = 0 / 0 }, match = "invalid interruptInterval" },
				{ opts = { safeEnv = "yes" }, match = "invalid safeEnv" },
				{ opts = { interrupt = "no" }, match = "invalid interrupt" },
				{ opts = { getGlobal = "no" }, match = "invalid getGlobal" },
				{ opts = { setGlobal = "no" }, match = "invalid setGlobal" },
				{ opts = { onCall = 1 }, match = "invalid onCall" },
				{ opts = { onReturn = 1 }, match = "invalid onReturn" },
				{ opts = { onLine = 1 }, match = "invalid onLine" },
				{ opts = { onBreak = 1 }, match = "invalid onBreak" },
			}
			for _, tc in badOptCases do
				sert.throws(function()
					VM.load("return 1", tc.opts)
				end, tc.match)
			end

			-- 4. tstate.threadEnv isolation across top-level chunks on same host thread
			local mutThreadFn = assert(VM.load(
				[[
				setfenv(0, { poisoned = 999 })
				return true
			]],
				{ name = "=set_thread_env" }
			))
			sert.eq(mutThreadFn(), true)
			local nextCleanFn = assert(VM.load("return poisoned", { name = "=clean_thread_env" }))
			sert.eq(nextCleanFn(), nil)

			-- 5. coroutine.close closes open upvalues & releases self-referencing coroutine + sibling locals
			local weakCoRefs: { [number]: any } = setmetatable({}, { __mode = "v" }) :: any
			local readerUpval: (() -> number)? = nil
			do
				local coCreator = assert(VM.load(
					[[
					local hold = ...
					local co = coroutine.create(function(box)
						local siblingLocal = { tag = "sibling_secret" }
						local up = 10
						local function inc()
							up += 1
							return up
						end
						local selfCo = coroutine.running()
						box.self = selfCo
						box.sib = siblingLocal
						coroutine.yield(inc)
						return selfCo, siblingLocal.tag
					end)
					local okY, incFn = coroutine.resume(co, hold)
					assert(okY)
					coroutine.close(co)
					return incFn, co
				]],
					{ name = "=co_close_gc" }
				))
				local hold: { [string]: any } = {}
				local incFn, closedCo = coCreator(hold)
				sert.eq(coroutine.status(closedCo), "dead")
				sert.eq(incFn(), 11)
				sert.eq(incFn(), 12)
				readerUpval = incFn
				weakCoRefs[1] = closedCo
				weakCoRefs[2] = hold.sib
				hold.self = nil
				hold.sib = nil
			end
			sert.eq((readerUpval :: () -> number)(), 13)
			drainWeak(weakCoRefs, 2)
			sert.eq(weakCoRefs[1], nil)
			sert.eq(weakCoRefs[2], nil)
		end
	)

	test(
		"handles shared env safeRootsMask invalidation, getGlobal on _G keys, LBF_VECTOR, BIT32_EXTRACTK edges, locked-MT iterables, duplicate table constants, error formatting, and coroutine debug edge cases",
		function()
			-- 1. Shared mutable env invalidates across chunks via setmetatable and aliased rawset/table.clear
			local sharedEnv = VM.createEnvironment()
			local chunkRead = assert(VM.load("local x = ...; return math.abs(x)", {
				name = "=shared_read",
				env = sharedEnv,
				compile = { optimizationLevel = 2 },
			}))
			local chunkMutRaw = assert(VM.load(
				[[
				local rs = rawset
				rs(_G, "math", { abs = function() return 404 end })
			]],
				{ name = "=shared_mut_raw", env = sharedEnv }
			))
			local chunkMutMt = assert(VM.load(
				[[
				setmetatable(_G, { __index = function(_, k) if k == "bit32" then return { bxor = function() return 909 end } end return nil end })
			]],
				{ name = "=shared_mut_mt", env = sharedEnv }
			))
			local chunkBit = assert(VM.load("local a, b = ...; return bit32.bxor(a, b)", {
				name = "=shared_bit",
				env = sharedEnv,
				compile = { optimizationLevel = 2 },
			}))
			sert.eq(chunkRead(-5), 5)
			chunkMutRaw()
			sert.eq(chunkRead(-5), 404)
			sert.eq(chunkBit(5, 3), 6)
			local aliasedClearEnv = VM.createEnvironment()
			local clearReader = assert(VM.load("local x = ...; return bit32.band(x, 15)", {
				name = "=clear_reader",
				env = aliasedClearEnv,
				compile = { optimizationLevel = 2 },
			}))
			local clearMut = assert(VM.load(
				[[
				local x = ...
				local tc = table.clear
				_G.bit32 = { band = function() return 303 end }
				local before = bit32.band(x, 15)
				tc(_G)
				return before, bit32.band(x, 15), math
			]],
				{
					name = "=aliased_clear",
					env = aliasedClearEnv,
					compile = { optimizationLevel = 2, flags = { LuauCompileTableBuiltinsCreateClear = true } },
				}
			))
			sert.eq(clearReader(25), 9)
			local bClr, aClr, afterMath = clearMut(25)
			sert.eq(bClr, 303)
			sert.eq(aClr, 9)
			sert.eq(afterMath, nil)
			sert.eq(clearReader(25), 9)
			-- Separate mutable env chunk verifies setmetatable on plain table invalidates sibling chunk
			local plainShared: { [any]: any } =
				{ rawset = rawset, setmetatable = setmetatable, math = math, bit32 = bit32 }
			plainShared._G = plainShared
			local plainRead = assert(VM.load("local a, b = ...; return bit32.bxor(a, b)", {
				name = "=plain_read",
				env = plainShared,
				compile = { optimizationLevel = 2 },
			}))
			local plainMut = assert(
				VM.load(
					"rawset(_G, 'bit32', nil); setmetatable(_G, { __index = { bit32 = { bxor = function() return 707 end } } })",
					{ name = "=plain_mut", env = plainShared }
				)
			)
			sert.eq(plainRead(5, 3), 6)
			plainMut()
			sert.eq(plainRead(5, 3), 707)
			-- Suppress unused warning if chunkMutMt requires writable mt on plain table
			local okMutLockedMt = pcall(chunkMutMt)
			sert.eq(okMutLockedMt, false)

			-- 2. getGlobal intercepts _G.k and _G["k"]
			local gKeyLog: { string } = {}
			local gKeyFn = assert(VM.load(
				[[
				local k = ...
				return _G.dotGlobal, _G[k]
			]],
				{
					name = "=g_key_get",
					getGlobal = function(name: string, env: { [any]: any }): any
						table.insert(gKeyLog, name)
						if name == "dotGlobal" then
							return 111
						elseif name == "dynGlobal" then
							return 222
						end
						return env[name]
					end,
				}
			))
			local gv1, gv2 = gKeyFn("dynGlobal")
			sert.eq(gv1, 111)
			sert.eq(gv2, 222)
			expect(
				table.find(gKeyLog, "dotGlobal") ~= nil and table.find(gKeyLog, "dynGlobal") ~= nil,
				"getGlobal saw _G keys"
			)

			-- 3. LBF_VECTOR (Vector3.new pure and overridden) & LBF_BIT32_EXTRACTK edge cases
			local vec3PureEnv = VM.createEnvironment({
				Vector3 = {
					new = function(x: number, y: number, z: number)
						return { x = x, y = y, z = z }
					end,
				},
			})
			local vec3Fn = assert(VM.load("local x = ...; local v = Vector3.new(x, 2, 3); return v.x, v.y, v.z", {
				name = "=vec3_custom",
				env = vec3PureEnv,
				compile = {
					optimizationLevel = 2,
					vectorLib = "Vector3",
					vectorCtor = "new",
					vectorType = "Vector3",
				},
			}))
			local vx, vy, vz = vec3Fn(1)
			sert.eq(vx, 1)
			sert.eq(vy, 2)
			sert.eq(vz, 3)

			local extEdgeFn = assert(VM.load(
				[[
				local x, nanVal = ...
				local fromNan = bit32.extract(nanVal, 0, 1)
				local okOob, errOob = pcall(function()
					return bit32.extract(x, 20, 20)
				end)
				return fromNan, okOob, errOob
			]],
				{ name = "=ext_edge", compile = { optimizationLevel = 2 } }
			))
			local fnNan, okExtOob, errExtOob = extEdgeFn(0xff, 0 / 0)
			sert.eq(fnNan, bit32.extract(0 / 0, 0, 1))
			sert.eq(okExtOob, false)
			expect(
				string.find(tostring(errExtOob), "trying to access non-existent bits", 1, true) ~= nil,
				tostring(errExtOob)
			)

			-- 4. FORGPREP / FORGPREP_NEXT / FORGPREP_INEXT on locked-metatable callables
			local lockedIterFn = assert(VM.load(
				[[
				local lockedCallable = setmetatable({}, {
					__metatable = "locked",
					__call = function(_, st, k)
						if k == nil then
							return 1, 77
						end
						return nil
					end,
				})
				local s1 = 0
				for k, v in lockedCallable do
					s1 += k + v
				end
				local pairs = function(t) return lockedCallable, t, nil end
				local s2 = 0
				for k, v in pairs({ 1 }) do
					s2 += k + v
				end
				local ipairs = function(t) return lockedCallable, t, nil end
				local s3 = 0
				for k, v in ipairs({ 1 }) do
					s3 += k + v
				end
				return s1, s2, s3
			]],
				{ name = "=locked_iter", compile = { optimizationLevel = 2 } }
			))
			local ls1, ls2, ls3 = lockedIterFn()
			sert.eq(ls1, 78)
			sert.eq(ls2, 78)
			sert.eq(ls3, 78)

			-- 5. table_with_constants duplicate key handling
			local dupTblMod = {
				version = BytecodeDefs.Tags.LBC_VERSION_TARGET,
				typesversion = BytecodeDefs.Tags.LBC_TYPE_VERSION_TARGET,
				strings = { "a" },
				mainid = 0,
				protos = {
					{
						id = 0,
						maxstacksize = 4,
						numparams = 0,
						nups = 0,
						isvararg = false,
						flags = 0,
						code = {
							Helpers.encodeAD(Opcodes.LOP_DUPTABLE, 0, 2),
							Helpers.encodeABC(Opcodes.LOP_RETURN, 0, 2, 0),
						},
						kTypes = {
							Tags.LBC_CONSTANT_STRING,
							Tags.LBC_CONSTANT_NUMBER,
							Tags.LBC_CONSTANT_TABLE_WITH_CONSTANTS,
							Tags.LBC_CONSTANT_NUMBER,
						},
						kValues = {
							"a",
							1,
							{ keys = { 0, 0 }, constants = { 1, 3 }, length = 2 },
							2,
						},
						p = {},
						linedefined = 1,
					},
				},
			}
			local dupTblFn = assert(VM.loadProto(dupTblMod :: any, { name = "=dup_tbl_k" }))
			local dupTblRes = dupTblFn()
			sert.eq(dupTblRes.a, 2)

			-- 6. error(msg, 99) across host boundary, numeric error stringification, and dead/normal coroutine debug
			local edgeErrFn = assert(VM.load(
				[[
				local okSort99, errSort99 = pcall(function()
					table.sort({ 2, 1 }, function()
						error("unbounded_99", 99)
					end)
				end)
				local okNumErr, errNumErr = pcall(function()
					error(123, 1)
				end)
				local deadCo = coroutine.create(function() return 1 end)
				coroutine.resume(deadCo)
				local deadTb = debug.traceback(deadCo, "done")

				local normalResult = nil
				local outerCo = coroutine.running()
				local childCo = coroutine.create(function()
					normalResult = { debug.info(outerCo, 0, "sn") }
					return true
				end)
				coroutine.resume(childCo)
				return okSort99, errSort99, okNumErr, errNumErr, deadTb, normalResult[1], normalResult[2]
			]],
				{ name = "=edge_err_dbg" }
			))
			local okS99, errS99, okNE, errNE, deadTb, normS, normN = edgeErrFn()
			sert.eq(okS99, false)
			sert.eq(errS99, "unbounded_99")
			sert.eq(okNE, false)
			expect(string.find(tostring(errNE), "edge_err_dbg:", 1, true) ~= nil, tostring(errNE))
			expect(string.find(tostring(errNE), ": 123", 1, true) ~= nil, tostring(errNE))
			sert.eq(deadTb, "done\n")
			sert.eq(normS, "[C]")
			sert.eq(normN, "resume")
		end
	)

	test(
		"dispatches full VM metamethod suite including arithmetic, relational, multi-arg concat, len, newindex, and call",
		function()
			local mmSrc = [[
			local mt
			local function wrap(v)
				return setmetatable({ val = v }, mt)
			end
			mt = {
				__add = function(a, b) return wrap((if type(a) == "table" then a.val else a) + (if type(b) == "table" then b.val else b)) end,
				__sub = function(a, b) return wrap((if type(a) == "table" then a.val else a) - (if type(b) == "table" then b.val else b)) end,
				__mul = function(a, b) return wrap((if type(a) == "table" then a.val else a) * (if type(b) == "table" then b.val else b)) end,
				__div = function(a, b) return wrap((if type(a) == "table" then a.val else a) / (if type(b) == "table" then b.val else b)) end,
				__idiv = function(a, b) return wrap((if type(a) == "table" then a.val else a) // (if type(b) == "table" then b.val else b)) end,
				__mod = function(a, b) return wrap((if type(a) == "table" then a.val else a) % (if type(b) == "table" then b.val else b)) end,
				__pow = function(a, b) return wrap((if type(a) == "table" then a.val else a) ^ (if type(b) == "table" then b.val else b)) end,
				__unm = function(a) return wrap(-a.val) end,
				__concat = function(a, b)
					local sa = if type(a) == "table" then tostring(a.val) else tostring(a)
					local sb = if type(b) == "table" then tostring(b.val) else tostring(b)
					return wrap(sa .. ":" .. sb)
				end,
				__len = function(a) return a.val + 100 end,
				__eq = function(a, b) return a.val == b.val end,
				__lt = function(a, b) return a.val < b.val end,
				__le = function(a, b) return a.val <= b.val end,
				__newindex = function(self, k, v)
					rawset(self, "ni_" .. tostring(k), v * 2)
				end,
				__call = function(self, delta, factor)
					return self.val * factor + delta
				end,
			}

			local x = wrap(10)
			local y = wrap(3)
			local xCopy = wrap(10)
			local arithSum = (x + y).val + (x - y).val + (x * y).val + (x / 2).val + (x // y).val + (x % y).val + (y ^ 2).val + (-y).val
			local cat2 = (x .. y).val
			local cat3 = (x .. "-" .. y).val
			x.extra = 21
			return arithSum, cat2, cat3, #x, x == xCopy, x ~= y, y < x, y <= x, y <= wrap(3), x.ni_extra, x(5, 4)
		]]
			local aSum, cat2, cat3, xLen, eqSame, neqDiff, ltRes, leLt, leEq, niVal, callVal = runAtAllOptLevels(mmSrc)
			sert.eq(aSum, 13 + 7 + 30 + 5 + 3 + 1 + 9 - 3)
			sert.eq(cat2, "10:3")
			sert.eq(cat3, "10:-:3")
			sert.eq(xLen, 110)
			sert.eq(eqSame, true)
			sert.eq(neqDiff, true)
			sert.eq(ltRes, true)
			sert.eq(leLt, true)
			sert.eq(leEq, true)
			sert.eq(niVal, 42)
			sert.eq(callVal, 45)
		end
	)

	test("validates bad inputs across Ouro.load, VM.cloneFunction, and VM.sandbox", function()
		local validBc = assert(Parser.compile("return 42"))
		local validBuf = buffer.fromstring(validBc)
		local validFn = assert(Parser.load("return 1", { name = "=valid_src" }))

		local loadMatrix: { { chunk: any, opts: any, match: string } } = {
			{ chunk = validBuf, opts = { mode = "text" }, match = "buffer cannot be loaded in text mode" },
			{ chunk = "return 1", opts = { mode = "bogus" }, match = "invalid load mode" },
			{ chunk = 123, opts = nil, match = "expected source string" },
			{ chunk = "return 1", opts = "bad_opts", match = "invalid load options" },
			{ chunk = validBc, opts = { mode = "binary", env = "bad_env" }, match = "invalid env table" },
			{ chunk = "return 1", opts = { env = 123 }, match = "invalid env table" },
		}
		for _, tc in loadMatrix do
			sert.throws(function()
				Parser.load(tc.chunk, tc.opts)
			end, tc.match)
		end

		-- mode = "auto" handles text source and binary bytecode cleanly
		local autoText = assert(Parser.load("return 7 * 6", { mode = "auto", name = "=auto_text" }))
		sert.eq(autoText(), 42)
		local autoBin = assert(Parser.load(validBc, { mode = "auto", name = "=auto_bin" }))
		sert.eq(autoBin(), 42)

		sert.throws(function()
			VM.cloneFunction(validFn, "not_table" :: any)
		end, "newEnv must be a table")
		sert.throws(function()
			VM.cloneFunction(validFn, {}, "not_table" :: any)
		end, "loadOptions must be a table")
		sert.throws(function()
			VM.sandbox("not_table" :: any)
		end, "baseEnv must be a table")
		sert.throws(function()
			VM.sandbox(nil, "not_table" :: any)
		end, "overrides must be a table")
	end)

	test("blocks read-only proxy and frozen environment escapes via GETIMPORT, wrap, and table.clear", function()
		local cases = {
			VM.createEnvironment({ hostMarker = 7 }, { inheritHost = true, readOnly = true }),
			VM.createEnvironment({ hostMarker = 7 }, { inheritHost = false, readOnly = true }),
		}
		for idx, env in cases do
			local src = [[
				local sameRawset = (rawset == getfenv(1).rawset)
				local okDirect = pcall(function()
					rawset(getfenv(1), "pwned", 1)
				end)
				local okWrap = pcall(coroutine.wrap(function()
					rawset(getfenv(1), "pwned", 2)
				end))
				local okClear = pcall(table.clear, getfenv(1))
				return sameRawset, okDirect, okWrap, okClear, getfenv(1).pwned, hostMarker
			]]
			for _, opt in { 0, 1, 2 } do
				local fn =
					assert(VM.load(src, { name = "=ro_" .. idx, env = env, compile = { optimizationLevel = opt } }))
				local sameRawset, okDirect, okWrap, okClear, pwned, marker = fn()
				sert.eq(sameRawset, true)
				sert.eq(okDirect, false)
				sert.eq(okWrap, false)
				sert.eq(okClear, false)
				sert.eq(pwned, nil)
				sert.eq(marker, 7)
			end
		end
	end)

	test(
		"handles generalized iteration over _G, locked metatables, non-yieldable __iter, and FORGPREP_NEXT/INEXT guards",
		function()
			local sumRes, hasMath = runAtAllOptLevels([[
			local hasMath = false
			for k, _ in _G do
				if k == "math" then
					hasMath = true
				end
			end
			local lockedPlain = setmetatable({ a = 4, b = 6 }, { __metatable = "locked" })
			local plainSum = 0
			for _, v in lockedPlain do
				plainSum += v
			end
			local lockedIter = setmetatable({ 10, 20 }, {
				__metatable = "locked",
				__iter = function(self)
					local i = 0
					return function()
						i += 1
						return if i <= #self then i else nil, self[i]
					end
				end,
			})
			local iterSum = 0
			for _, v in lockedIter do
				iterSum += v
			end
			return plainSum + iterSum, hasMath
		]])
			sert.eq(sumRes, 40)
			sert.eq(hasMath, true)

			-- __iter runs synchronously in a non-yieldable boundary
			local co = coroutine.create(function()
				local fn = assert(VM.load([[
				local seenYieldable = true
				local t = setmetatable({}, {
					__iter = function()
						seenYieldable = coroutine.isyieldable()
						coroutine.yield()
						return function() return nil end
					end,
				})
				local ok, err = pcall(function()
					for _ in t do end
				end)
				return ok, err, seenYieldable
			]]))
				return fn()
			end)
			local coOk, okIter, errIter, seenYieldable = coroutine.resume(co)
			sert.eq(coOk, true)
			sert.eq(okIter, false)
			expect(string.find(tostring(errIter), "yield", 1, true) ~= nil, tostring(errIter))
			sert.eq(seenYieldable, false)

			-- String iteration errors cleanly via FORGPREP
			local strOk, strErr = pcall(
				runAtAllOptLevels,
				[[
			for _ in ("abc" :: any) do end
		]],
				nil
			)
			sert.eq(strOk, false)
			expect(
				string.find(tostring(strErr), "attempt to iterate over a string value", 1, true) ~= nil,
				tostring(strErr)
			)

			-- FORGPREP_NEXT and FORGPREP_INEXT reject __call tables (O1/O2; O0 uses FORGPREP which calls __call)
			for _, opt in { 0, 1, 2 } do
				local nextEnv = VM.createEnvironment({
					next = setmetatable({}, {
						__call = function()
							return nil
						end,
					}),
				})
				local nextFn = assert(VM.load("for k, v in next, { a = 1 } do end", {
					name = "=forprep_next",
					env = nextEnv,
					compile = { optimizationLevel = opt },
				}))
				local okNext, errNext = pcall(nextFn)
				if opt == 0 then
					sert.eq(okNext, true)
				else
					sert.eq(okNext, false)
					expect(
						string.find(tostring(errNext), "attempt to iterate over a table value", 1, true) ~= nil,
						tostring(errNext)
					)
				end

				local inextEnv = VM.createEnvironment({
					ipairs = function()
						return setmetatable({}, {
							__call = function()
								return nil
							end,
						}),
							{},
							0
					end,
				})
				local inextFn = assert(VM.load("for i, v in ipairs({ 1 }) do end", {
					name = "=forprep_inext",
					env = inextEnv,
					compile = { optimizationLevel = opt },
				}))
				local okInext, errInext = pcall(inextFn)
				if opt == 0 then
					sert.eq(okInext, true)
				else
					sert.eq(okInext, false)
					expect(
						string.find(tostring(errInext), "attempt to iterate over a table value", 1, true) ~= nil,
						tostring(errInext)
					)
				end
			end
		end
	)

	test("protects running and normal coroutines on coroutine.close and clears errored traceback", function()
		local rUp, rOk, rErr, childOk, parentOk, parentErr, tbBefore, closeOk, tbAfter = runAtAllOptLevels([[
			local up = 10
			local cRun = coroutine.create(function()
				local ok, err = pcall(coroutine.close, coroutine.running())
				up += 5
				return up, ok, err
			end)
			local _, u, o, e = coroutine.resume(cRun)

			local parentRef
			local cChild = coroutine.create(function()
				return pcall(coroutine.close, parentRef)
			end)
			local cParent = coroutine.create(function()
				parentRef = coroutine.running()
				local r1, r2, r3 = coroutine.resume(cChild)
				return "parent_alive", r1, r2, r3
			end)
			local _, pAlive, cResOk, cCloseOk, cCloseErr = coroutine.resume(cParent)

			local cDead = coroutine.create(function()
				local dieHere, recurseHelper
				function recurseHelper()
					return dieHere()
				end
				function dieHere()
					if false then
						recurseHelper()
					end
					error("boom_close")
				end
				dieHere()
			end)
			local _, _ = coroutine.resume(cDead)
			local before = debug.traceback(cDead)
			local closedOk = coroutine.close(cDead)
			local after = debug.traceback(cDead)
			return u, o, e, cResOk, cCloseOk, cCloseErr, string.find(before, "dieHere", 1, true) ~= nil, closedOk, after, pAlive
		]])
		sert.eq(rUp, 15)
		sert.eq(rOk, false)
		expect(string.find(tostring(rErr), "cannot close running coroutine", 1, true) ~= nil, tostring(rErr))
		sert.eq(childOk, true)
		sert.eq(parentOk, false)
		expect(string.find(tostring(parentErr), "cannot close normal coroutine", 1, true) ~= nil, tostring(parentErr))
		sert.eq(tbBefore, true)
		sert.eq(closeOk, false)
		expect(string.find(tostring(tbAfter), "dieHere", 1, true) == nil, tostring(tbAfter))
	end)

	test("matches Luau C-frame setfenv/debug.info, debugLevel = 0, URL errors, and formatChunkSrc rules", function()
		local okSf2, errSf2, okSf1, errSf1, okDi2, s2, n2, cs, cl, cn, ca, cv, _cf, badOptOk, ds0, dl0, ds1, dn1, tb0, tb1, tb2, isPrint =
			runAtAllOptLevels([[
				local ok1, e1 = pcall(function() return setfenv(2, {}) end)
				local ok2, e2 = pcall(setfenv, 1, {})
				local ok3, src2, name2 = pcall(function() return debug.info(2, "sn") end)
				local s, l, n, a, v, f = debug.info(print, "slnaf")
				local okBad = pcall(debug.info, print, "z")
				local co = coroutine.create(function()
					local function dieHere(flag)
						if flag then
							dieHere(false)
						end
						error("co_fail")
					end
					dieHere(false)
				end)
				coroutine.resume(co)
				local d0s, d0l = debug.info(co, 0, "sl")
				local d1s, d1n = debug.info(co, 1, "sn")
				local t0 = debug.traceback(co, nil, 0)
				local t1 = debug.traceback(co, nil, 1)
				local t2 = debug.traceback(co, nil, 2)
				return ok1, e1, ok2, e2, ok3, src2, name2, s, l, n, a, v, f, okBad, d0s, d0l, d1s, d1n, t0, t1, t2, f == print
			]])
		sert.eq(okSf2, false)
		expect(
			string.find(tostring(errSf2), "cannot change environment of given object", 1, true) ~= nil,
			tostring(errSf2)
		)
		sert.eq(okSf1, false)
		expect(
			string.find(tostring(errSf1), "cannot change environment of given object", 1, true) ~= nil,
			tostring(errSf1)
		)
		sert.eq(okDi2, true)
		sert.eq(s2, "[C]")
		sert.eq(n2, "pcall")
		sert.eq(cs, "[C]")
		sert.eq(cl, -1)
		sert.eq(cn, "print")
		sert.eq(ca, 0)
		sert.eq(cv, true)
		sert.eq(isPrint, true)
		sert.eq(badOptOk, false)
		sert.eq(ds0, "[C]")
		sert.eq(dl0, -1)
		sert.eq(ds1, "vmtest")
		sert.eq(dn1, "dieHere")
		sert.eq(tb0, tb1)
		expect(string.find(tostring(tb0), "dieHere", 1, true) ~= nil, tostring(tb0))
		expect(string.find(tostring(tb2), "dieHere", 1, true) == nil, tostring(tb2))

		-- debugLevel = 0 returns line 0 and leaves error message unprefixed; debugLevel = 1 prefixes URL errors
		local d0Fn =
			assert(VM.load("local l = debug.info(1, 'l')\nlocal _, e = pcall(error, 'raw_boom')\nreturn l, e", {
				name = "=dbg0",
				compile = { optimizationLevel = 1, debugLevel = 0 },
			}))
		local l0, rawErr = d0Fn()
		sert.eq(l0, 0)
		sert.eq(rawErr, "raw_boom")

		local urlFn = assert(VM.load("error('http://host:8080: fail')", {
			name = "=urlchk",
			compile = { optimizationLevel = 1, debugLevel = 1 },
		}))
		local uOk, uErr = pcall(urlFn)
		sert.eq(uOk, false)
		expect(string.sub(tostring(uErr), 1, 9) == "urlchk:1:", tostring(uErr))

		-- formatChunkSrc 256-byte chunk naming rules
		local eqName = "=" .. string.rep("x", 300)
		local eqFn = assert(VM.load("return debug.info(1, 's')", { name = eqName }))
		local eqSrc = eqFn()
		sert.eq(#eqSrc, 255)
		sert.eq(eqSrc, string.rep("x", 255))

		local atFitName = "@" .. string.rep("a", 255)
		local atFitFn = assert(VM.load("return debug.info(1, 's')", { name = atFitName }))
		sert.eq(atFitFn(), string.rep("a", 255))

		local atLongName = "@" .. string.rep("p", 300) .. "tail"
		local atLongFn = assert(VM.load("return debug.info(1, 's')", { name = atLongName }))
		local atLongSrc = atLongFn()
		sert.eq(#atLongSrc, 255)
		sert.eq(string.sub(atLongSrc, 1, 3), "...")
		sert.eq(string.sub(atLongSrc, -4), "tail")

		local multiFn = assert(VM.load("return debug.info(1, 's')", { name = "abc\ndef" }))
		sert.eq(multiFn(), '[string "abc..."]')

		local plainLongFn = assert(VM.load("return debug.info(1, 's')", { name = string.rep("q", 300) }))
		local plainLongSrc = plainLongFn()
		sert.eq(#plainLongSrc, 255)
		sert.eq(string.sub(plainLongSrc, 1, 9), '[string "')
		sert.eq(string.sub(plainLongSrc, -5), '..."]')
	end)

	test("resolves newproxy __namecall before __index and honors getGlobal on _G:method()", function()
		local resNc, lockedMt = runAtAllOptLevels([[
			local u = newproxy(true)
			local mt = getmetatable(u)
			mt.__namecall = function(self, n)
				return "namecall:" .. tostring(n)
			end
			mt.__index = function()
				return function() return "index" end
			end
			mt.__metatable = "locked"
			return u:ping(42), getmetatable(u)
		]])
		sert.eq(resNc, "namecall:42")
		sert.eq(lockedMt, "locked")

		local gNcFn = assert(VM.load("return _G:ping(9)", {
			name = "=gnc",
			getGlobal = function(k, env)
				if k == "_G" then
					return env
				elseif k == "ping" then
					return function(_self, x)
						return x * 10
					end
				end
				return nil
			end,
		}))
		sert.eq(gNcFn(), 90)
	end)

	test(
		"enforces cross-chunk safeenv invalidation, DUPCLOSURE reuse, POWK sqrt, CALLFB interrupt, EXTRACTK, collectgarbage, and table unpack",
		function()
			-- 1. Cross-chunk safeenv invalidation via SETGLOBAL, rawset, setmetatable, getfenv
			local sharedEnv = VM.createEnvironment()
			local reader = assert(VM.load("return function(x) return math.abs(x) end", {
				name = "=reader",
				env = sharedEnv,
				compile = { optimizationLevel = 2 },
			}))()
			sert.eq(reader(-5), 5)
			local writer = assert(VM.load(
				[[
			local fake = { abs = function() return 999 end }
			rawset(getfenv(1), "math", fake)
		]],
				{ name = "=writer", env = sharedEnv, compile = { optimizationLevel = 2 } }
			))
			writer()
			sert.eq(reader(-5), 999)

			-- 2. LOP_DUPCLOSURE self-capturing recursive closure reuse at O1/O2 (NEWCLOSURE at O0)
			local dupSrc = [[
			local function outer()
				local function rec(n)
					if n <= 0 then
						return 0
					end
					return 1 + rec(n - 1)
				end
				return rec
			end
			local f1, f2 = outer(), outer()
			return f1 == f2, f1(4)
		]]
			for _, opt in { 0, 1, 2 } do
				local dfn = assert(VM.load(dupSrc, { name = "=dup", compile = { optimizationLevel = opt } }))
				local eq1, callRes = dfn()
				sert.eq(eq1, opt > 0)
				sert.eq(callRes, 4)
			end

			-- 3. LOP_POWK 0.5 uses sqrt parity for -inf and -0.0 at O1
			local powkFn = assert(VM.load(
				[[
			local function fk(x)
				return x ^ 0.5
			end
			local a = (-math.huge) ^ 0.5
			local b = fk(-math.huge)
			local c = fk(-0.0)
			return a ~= a, b ~= b, 1 / c < 0
		]],
				{ name = "=powk", compile = { optimizationLevel = 1 } }
			))
			local pNaNConst, pNaNDyn, pNegZero = powkFn()
			sert.eq(pNaNConst, true)
			sert.eq(pNaNDyn, true)
			sert.eq(pNegZero, true)

			-- 4. LOP_CALLFB checks ctx.interrupted when a host callback catches an interrupted VM callee
			local p2Bcb = BytecodeBuilder.new()
			local pSpin = p2Bcb:beginFunction(0, false)
			p2Bcb:emitABC(Opcodes.LOP_LOADN, 0, 1, 0)
			p2Bcb:emitABC(Opcodes.LOP_NOP, 0, 0, 0)
			p2Bcb:emitABC(Opcodes.LOP_RETURN, 0, 2, 0)
			p2Bcb:endFunction(1, 0)
			local pMain = p2Bcb:beginFunction(1, false) -- R0 = hostCatcher
			p2Bcb:emitAD(Opcodes.LOP_DUPCLOSURE, 1, p2Bcb:addConstantClosure(pSpin))
			p2Bcb:emitABC(Opcodes.LOP_CALLFB, 0, 2, 1) -- hostCatcher(spin)
			p2Bcb:emitAux(0)
			p2Bcb:emitABC(Opcodes.LOP_LOADN, 0, 42, 0)
			p2Bcb:emitABC(Opcodes.LOP_RETURN, 0, 2, 0)
			p2Bcb:endFunction(3, 0)
			p2Bcb:setMainFunction(pMain)
			p2Bcb:finalize()
			local p2Fn = assert(VM.loadProto(p2Bcb:toProtoModule(), {
				name = "=p2_callfb",
				interruptInterval = 1,
				interrupt = function()
					return false
				end,
			}))
			local okP2, errP2 = pcall(p2Fn, function(inner)
				pcall(inner) -- sets ctx.interrupted = true inside same ctx without unwinding p2Fn
			end)
			sert.eq(okP2, false)
			expect(string.find(tostring(errP2), "execution interrupted", 1, true) ~= nil, tostring(errP2))

			-- 5. LBF_BIT32_EXTRACTK 3-arg fastcall + collectgarbage + table-only unpack
			local ex2, ex3, exFallback = runAtAllOptLevels([[
			local function f2(x) return bit32.extract(x, 4) end
			local function f3(x) return bit32.extract(x, 4, 8) end
			local function ffb(x) return bit32.extract(x, 28, 8) end
			return f2(0x1234), f3(0x1234), pcall(ffb, 0x1234)
		]])
			sert.eq(ex2, 1)
			sert.eq(ex3, 0x23)
			sert.eq(exFallback, false)

			local cgValid, cgCollect, cgNil, okBad, errBad, okTbl, errTbl = runAtAllOptLevels([[
			local c = collectgarbage("count")
			local a = collectgarbage("collect")
			local b = collectgarbage()
			local ok1, e1 = pcall(collectgarbage, "bad")
			local ok2, e2 = pcall(collectgarbage, {})
			return type(c) == "number" and c >= 0, a, b, ok1, e1, ok2, e2
		]])
			sert.eq(cgValid, true)
			sert.eq(cgCollect, nil)
			sert.eq(cgNil, nil)
			sert.eq(okBad, false)
			expect(
				string.find(tostring(errBad), "collectgarbage must be called with 'count' or 'collect'", 1, true) ~= nil,
				tostring(errBad)
			)
			sert.eq(okTbl, false)
			expect(
				string.find(tostring(errTbl), "bad argument #1 to 'collectgarbage'", 1, true) ~= nil,
				tostring(errTbl)
			)

			local tableOnlyEnv = VM.createEnvironment(nil, { libraries = { "table" } })
			local uFn = assert(VM.load("return unpack({ 7, 8 })", { name = "=tbl_unpack", env = tableOnlyEnv }))
			local u1, u2 = uFn()
			sert.eq(u1, 7)
			sert.eq(u2, 8)
		end
	)

	test(
		"isolates math.random/math.randomseed per environment and sandbox while keeping math fastcalls active",
		function()
			local rngSrc = [[
			math.randomseed(42)
			local a = math.random()
			local b = math.random(10)
			local c = math.random(-3, 3)
			math.randomseed(42)
			local a2 = math.random()
			local b2 = math.random(10)
			local c2 = math.random(-3, 3)
			local absVal = math.abs(-5)
			local rangeOk = true
			for _ = 1, 500 do
				local r = math.random()
				if r < 0 or r >= 1 then
					rangeOk = false
					break
				end
			end
			local emptyOk = pcall(math.random, 0)
			return a, b, c, a2, b2, c2, absVal, rangeOk, emptyOk
		]]
			math.randomseed(999)
			local hostNext = math.random()
			math.randomseed(999)

			local env1 = VM.createEnvironment()
			local fn1 = assert(VM.load(rngSrc, { name = "=iso1", env = env1, compile = { optimizationLevel = 2 } }))
			local a, b, c, a2, b2, c2, absVal, rangeOk, emptyOk = fn1()
			sert.eq(a, a2)
			sert.eq(b, b2)
			sert.eq(c, c2)
			sert.eq(absVal, 5)
			sert.eq(rangeOk, true)
			sert.eq(emptyOk, false)
			sert.eq(math.random(), hostNext)

			-- Sibling sandboxes backed by a frozen base do not share PRNG state
			local frozenBase = VM.createEnvironment(nil, { readOnly = true })
			local sb1 = VM.sandbox(frozenBase)
			local sb2 = VM.sandbox(frozenBase)
			local seqSrc = "math.randomseed(...); return math.random(), math.random()"
			local fSb1 = assert(VM.load(seqSrc, { name = "=sb1", env = sb1 }))
			local fSb2 = assert(VM.load(seqSrc, { name = "=sb2", env = sb2 }))
			local x1, x2 = fSb1(7)
			local _, _ = fSb2(12345)
			local fSb1Next = assert(VM.load("return math.random()", { name = "=sb1n", env = sb1 }))
			local fSb1Replay = assert(
				VM.load(
					"math.randomseed(7); math.random(); math.random(); return math.random()",
					{ name = "=sb1r", env = VM.createEnvironment() }
				)
			)
			sert.eq(fSb1Next(), fSb1Replay())
			expect(x1 >= 0 and x1 < 1 and x2 >= 0 and x2 < 1, "sandbox draws strictly in [0, 1)")
		end
	)

	test(
		"rejects NaN vector keys, string id 0, malformed Proto headers; supports 3-element vector constants and decoder round-trips",
		function()
			-- 1. NaN vector key in binary bytecode and VM.loadProto
			local bcbVec = BytecodeBuilder.new()
			local vfid = bcbVec:beginFunction(0, false)
			local kNanVec = bcbVec:addConstantVectorf(0 / 0, 1, 2, 0)
			local kNanTbl = bcbVec:addConstantTable({
				keys = { kNanVec },
				constants = {},
				length = 1,
				hasConstants = false,
			})
			bcbVec:emitAD(Opcodes.LOP_LOADK, 0, kNanTbl)
			bcbVec:emitABC(Opcodes.LOP_RETURN, 0, 2, 0)
			bcbVec:endFunction(1, 0)
			bcbVec:setMainFunction(vfid)
			bcbVec:finalize()
			local nanVecBc = bcbVec:getBytecode()
			local nanDeser, nanDeserErr = BytecodeCodec.deserialize(nanVecBc)
			sert.eq(nanDeser, nil)
			expect(string.find(tostring(nanDeserErr), "NaN", 1, true) ~= nil, tostring(nanDeserErr))
			local nanFn, nanErr = VM.loadBytecode(nanVecBc, { name = "=nanvec_bc" })
			sert.eq(nanFn, nil)
			expect(type(nanErr) == "string" and #nanErr > 0, "loadBytecode rejects NaN vector key binary")

			local badProtoNan: any = {
				version = 14,
				typesversion = 3,
				mainid = 0,
				strings = {},
				userdataTypes = {},
				protos = {
					{
						id = 0,
						maxstacksize = 1,
						numparams = 0,
						nups = 0,
						isvararg = false,
						flags = 0,
						linedefined = 1,
						code = { Opcodes.LOP_LOADK + 0x00010000, Opcodes.LOP_RETURN + 0x00020000 },
						kTypes = { BytecodeDefs.Tags.LBC_CONSTANT_VECTOR, BytecodeDefs.Tags.LBC_CONSTANT_TABLE },
						kValues = {
							{ 0 / 0, 1, 2, 0 },
							{ keys = { 0 }, length = 1 },
						},
						p = {},
					},
				},
			}
			local npFn, npErr = VM.loadProto(badProtoNan, { name = "=nanvec_proto" })
			sert.eq(npFn, nil)
			expect(string.find(tostring(npErr), "NaN", 1, true) ~= nil, tostring(npErr))

			-- 2. LBC_CONSTANT_STRING with string id 0 rejected
			local badStrIdBc = string.char(
				14,
				3,
				0,
				0,
				1,
				20, -- header + userdataTypes=0 + protoCount=1 + protoSize=20
				1,
				0,
				0,
				0,
				0,
				0, -- proto header
				1,
				Opcodes.LOP_RETURN,
				0,
				1,
				0, -- code
				1,
				BytecodeDefs.Tags.LBC_CONSTANT_STRING,
				0, -- k[1]: string id 0!
				0,
				0,
				0,
				0,
				0,
				0, -- sizep, linedefined, debugname, lineinfo, debuginfo, feedback
				0 -- mainid
			)
			local s0Mod, s0DeserErr = BytecodeCodec.deserialize(badStrIdBc)
			sert.eq(s0Mod, nil)
			expect(string.find(tostring(s0DeserErr), "string index", 1, true) ~= nil, tostring(s0DeserErr))
			local s0Fn, s0Err = VM.loadBytecode(badStrIdBc, { name = "=str0" })
			sert.eq(s0Fn, nil)
			expect(type(s0Err) == "string" and #s0Err > 0, "loadBytecode rejects LBC_CONSTANT_STRING id 0")

			-- 3. Malformed Proto linedefined / debugname rejected by loadProto
			local badLineMod: any = {
				version = 14,
				typesversion = 3,
				mainid = 0,
				strings = {},
				userdataTypes = {},
				protos = {
					{
						id = 0,
						maxstacksize = 1,
						numparams = 0,
						nups = 0,
						isvararg = false,
						flags = 0,
						linedefined = -1,
						code = { Opcodes.LOP_RETURN + 0x00010000 },
						kTypes = {},
						kValues = {},
						p = {},
					},
				},
			}
			local blFn, blErr = VM.loadProto(badLineMod)
			sert.eq(blFn, nil)
			expect(type(blErr) == "string", "malformed linedefined rejected")

			badLineMod.protos[1].linedefined = 1
			badLineMod.protos[1].debugname = 123 :: any
			local bdFn, bdErr = VM.loadProto(badLineMod)
			sert.eq(bdFn, nil)
			expect(type(bdErr) == "string", "malformed debugname rejected")

			-- 4. 3-element vector constant loads and runs cleanly in loadProto
			local vec3Mod: any = {
				version = 14,
				typesversion = 3,
				mainid = 0,
				strings = {},
				userdataTypes = {},
				protos = {
					{
						id = 0,
						maxstacksize = 2,
						numparams = 0,
						nups = 0,
						isvararg = false,
						flags = 0,
						linedefined = 1,
						code = {
							Opcodes.LOP_LOADK, -- R0 = K0
							Opcodes.LOP_RETURN + 0x00020000, -- return R0
						},
						kTypes = { BytecodeDefs.Tags.LBC_CONSTANT_VECTOR },
						kValues = { { 1.5, 2.5, 3.5 } },
						p = {},
					},
				},
			}
			local v3Fn = assert(VM.loadProto(vec3Mod, { name = "=vec3" }))
			local vecVal = v3Fn()
			sert.eq(vecVal.X, 1.5)
			sert.eq(vecVal.Y, 2.5)
			sert.eq(vecVal.Z, 3.5)

			-- 5. Custom encoder + decoder (function & table forms) round-trip across deserialize, loadBytecode, and VM.load
			local encodeOp = function(op: number): number
				return (op * 227) % 256
			end
			local decodeOp = function(op: number): number
				return (op * 203) % 256
			end
			local tableDecoder = {
				decode = function(_self: any, code: { number })
					local opLengths = BytecodeDefs.opLengths
					local j = 1
					while j <= #code do
						local insn = code[j]
						local dec = decodeOp(bit32.band(insn, 0xff))
						code[j] = bit32.bor(bit32.band(insn, 0xffffff00), dec)
						j += opLengths[dec]
					end
				end,
			}
			local roundSrc = "local sum = 0; for i = 1, 5 do sum += math.abs(-i) end; return sum"
			local encBc = assert(Parser.compile(roundSrc, { optimizationLevel = 2, encoder = encodeOp }))
			local decModFn = assert(BytecodeCodec.deserialize(encBc, decodeOp))
			local decModTbl = assert(BytecodeCodec.deserialize(encBc, tableDecoder))
			sert.eq(#decModFn.protos, #decModTbl.protos)

			local f1 = assert(VM.loadBytecode(encBc, { name = "=dec_fn", decoder = decodeOp }))
			local f2 = assert(VM.loadBytecode(encBc, { name = "=dec_tbl", decoder = tableDecoder }))
			local f3 = assert(VM.load(roundSrc, {
				name = "=dec_src",
				compile = { optimizationLevel = 2, encoder = encodeOp },
				decoder = decodeOp,
			}))
			sert.eq(f1(), 15)
			sert.eq(f2(), 15)
			sert.eq(f3(), 15)

			local missingDecFn, missingDecErr = VM.load(roundSrc, {
				name = "=enc_no_dec",
				compile = { optimizationLevel = 2, encoder = encodeOp },
			})
			sert.eq(missingDecFn, nil)
			expect(
				type(missingDecErr) == "string" and #missingDecErr > 0,
				"encoded load without matching decoder fails cleanly"
			)
		end
	)

	test(
		"exercises inline safeenv fastcalls, cross-chunk CALLFB, entry-frame varargs, xpcall snapshot merge, and inheritHost/static safeenv chains",
		function()
			-- 1. Safeenv inline FASTCALL1/2/2K paths (math.floor/ceil/sqrt/round, type/typeof, bit32.band/bor/lshift/rshift, math.min/max)
			local fcSrc = [[
local function run(x: number, y: number, k: number)
	return math.floor(x),
		math.ceil(x),
		math.sqrt(y),
		math.round(x),
		type(k),
		typeof(k),
		bit32.band(k, 0xff),
		bit32.bor(k, 0x0f),
		bit32.lshift(k, 2),
		bit32.rshift(k, 1),
		bit32.band(k, y),
		bit32.bor(k, y),
		bit32.lshift(y, 1),
		bit32.rshift(y, 1),
		math.min(x, y),
		math.max(x, y)
end
return run(3.6, 16, 0x123)
]]
			local fcFn =
				assert(VM.loadBytecode(assert(Parser.compile(fcSrc, { optimizationLevel = 2 })), { name = "=fc" }))
			local r1, r2, r3, r4, r5, r6, r7, r8, r9, r10, r11, r12, r13, r14, r15, r16 = fcFn()
			sert.eq(r1, 3)
			sert.eq(r2, 4)
			sert.eq(r3, 4)
			sert.eq(r4, 4)
			sert.eq(r5, "number")
			sert.eq(r6, "number")
			sert.eq(r7, 0x23)
			sert.eq(r8, 0x12f)
			sert.eq(r9, 0x48c)
			sert.eq(r10, 0x91)
			sert.eq(r11, 0)
			sert.eq(r12, 0x133)
			sert.eq(r13, 32)
			sert.eq(r14, 8)
			sert.eq(r15, 3.6)
			sert.eq(r16, 16)

			-- 2. Cross-chunk CALLFB (calleeCtx ~= ctx) updating active hooks/getGlobal and restoring caller context
			local calleeChunk = assert(
				VM.loadBytecode(
					assert(Parser.compile("return function(v) return v + hiddenBonus end", { optimizationLevel = 2 })),
					{
						name = "=callee_chunk",
						env = VM.createEnvironment(),
						safeEnv = false,
						getGlobal = function(name)
							return if name == "hiddenBonus" then 100 else nil
						end,
					}
				)
			)
			local calleeClosure = calleeChunk()
			local callerChunk = assert(
				VM.loadBytecode(
					assert(
						Parser.compile(
							"local function callOther(fn, v) local out = fn(v); return out + ownBonus end; return callOther",
							{ optimizationLevel = 2 }
						)
					),
					{
						name = "=caller_chunk",
						env = VM.createEnvironment(),
						safeEnv = false,
						getGlobal = function(name)
							return if name == "ownBonus" then 7 else nil
						end,
					}
				)
			)
			local callOther = callerChunk()
			sert.eq(callOther(calleeClosure, 5), 112)

			-- 3. Entry-frame vararg packing for numparams = 0..3 with <= 4 args
			local vaFactory = assert(VM.loadBytecode(
				assert(Parser.compile(
					[[
return function()
	local f0 = function(...) return select("#", ...), ... end
	local f1 = function(a, ...) return a, select("#", ...), ... end
	local f2 = function(a, b, ...) return a, b, select("#", ...), ... end
	local f3 = function(a, b, c, ...) return a, b, c, select("#", ...), ... end
	return f0, f1, f2, f3
end
]],
					{ optimizationLevel = 2 }
				)),
				{ name = "=va_factory" }
			))()
			local f0, f1, f2, f3 = vaFactory()
			local n0, a0, b0, c0, d0 = f0(10, 20, 30, 40)
			sert.eq(n0, 4)
			sert.eq(a0 + b0 + c0 + d0, 100)
			local p1, n1, x1, y1, z1 = f1(10, 20, 30, 40)
			sert.eq(p1, 10)
			sert.eq(n1, 3)
			sert.eq(x1 + y1 + z1, 90)
			local p2a, p2b, n2, x2, y2 = f2(10, 20, 30, 40)
			sert.eq(p2a + p2b, 30)
			sert.eq(n2, 2)
			sert.eq(x2 + y2, 70)
			local p3a, p3b, p3c, n3, x3 = f3(10, 20, 30, 40)
			sert.eq(p3a + p3b + p3c, 60)
			sert.eq(n3, 1)
			sert.eq(x3, 40)

			-- 4. Nested host-interleaved xpcall snapshot merging
			local mergedTb: string = ""
			local function hostBounce(cb: () -> ()): (boolean, any)
				return xpcall(cb, function(e)
					mergedTb = debug.traceback(tostring(e), 1)
					return mergedTb
				end)
			end
			local xpEnv = VM.createEnvironment({ hostBounce = hostBounce })
			local xpFn = assert(VM.loadBytecode(
				assert(Parser.compile(
					[[
local function innerBoom()
	error("deepboom")
end
local function mid()
	return xpcall(innerBoom, function(err)
		return err
	end)
end
local function outer()
	return hostBounce(function()
		local ok, msg = mid()
		assert(ok, msg)
	end)
end
return outer()
]],
					{ optimizationLevel = 1 }
				)),
				{ name = "=xp_merge", env = xpEnv }
			))
			local xok = xpFn()
			sert.eq(xok, false)
			expect(string.find(mergedTb, "deepboom", 1, true) ~= nil, mergedTb)

			-- 5. inheritHost = true fallback globals + custom frozen __index safeRootsMask chains
			local inheritEnv = VM.createEnvironment(nil, { inheritHost = true })
			local inheritFn = assert(VM.loadBytecode(
				assert(Parser.compile(
					[[
local t = { 1, 2 }
table.insert(t, 3)
local ok, _ = xpcall(function() return 1 end, function(e) return e end)
local co = coroutine.create(function() return 1 end)
return _G == getfenv(0)
	and _G ~= nil
	and script == nil
	and loadstring == nil
	and collectgarbage("count") >= 0
	and getfenv ~= nil
	and setfenv ~= nil
	and debug.info(1, "s") ~= nil
	and error ~= nil
	and ok == true
	and rawset ~= nil
	and setmetatable ~= nil
	and coroutine.status(co) == "suspended"
	and #t == 3
]],
					{ optimizationLevel = 2 }
				)),
				{ name = "=inherit_host", env = inheritEnv }
			))
			sert.eq(inheritFn(), true)

			local roBase = VM.createEnvironment(nil, { readOnly = true })
			local layer1 = table.freeze(setmetatable({}, table.freeze({ __index = roBase })) :: any)
			local customEnv = setmetatable({}, table.freeze({ __metatable = true, __index = layer1 })) :: any
			local chainFn = assert(
				VM.loadBytecode(
					assert(Parser.compile("return math.abs(-9) + bit32.band(15, 6)", { optimizationLevel = 2 })),
					{ name = "=safe_chain", env = customEnv }
				)
			)
			sert.eq(chainFn(), 15)

			local dynamicSafeEnv =
				{ math = roBase.math, table = roBase.table, rawset = roBase.rawset, setmetatable = roBase.setmetatable }
			local dynFn =
				assert(VM.loadBytecode(assert(Parser.compile("return math.abs(-8)", { optimizationLevel = 2 })), {
					name = "=dyn_safe",
					env = dynamicSafeEnv,
					safeEnv = true,
					getGlobal = function(k, e)
						return e[k]
					end,
				}))
			sert.eq(dynFn(), 8)

			-- 6. Fastcall multret unpack + fallback paths, debug/getfenv/setfenv/traceback errors, host proxy checks, and Verifier/loadProto validations
			local unpackFn = assert(VM.loadBytecode(
				assert(Parser.compile(
					[[
local t = { 10, 20, 30, 40 }
local function f()
	return table.unpack(t, 1, 3)
end
local function g()
	return table.unpack(t)
end
local okBad, _ = pcall(function() return math.sqrt("bad" :: any) end)
local okExt, _ = pcall(function() return bit32.extract("bad" :: any, 0) end)
local okTup, _ = pcall(function() return typeof(t) == "table" and math.min("a" :: any, "b" :: any) end)
return okBad, okExt, okTup, f(), select("#", g())
]],
					{ optimizationLevel = 2 }
				)),
				{ name = "=fc_edges" }
			))
			local uBad, uExt, uTup, u1, uCnt = unpackFn()
			sert.eq(uBad, false)
			sert.eq(uExt, false)
			sert.eq(uTup, false)
			sert.eq(u1, 10)
			sert.eq(uCnt, 4)

			local hostDbgEnv = VM.createEnvironment(nil, { libraries = { "base", "coroutine", "debug" } })
			local dbgHooksChunk = assert(VM.loadBytecode(
				assert(Parser.compile(
					[[
local deadCo = coroutine.create(function()
	error("deaderr")
end)
coroutine.resume(deadCo)
local deadTb = debug.traceback(deadCo, "deadhdr", 0)
local deadS = debug.info(deadCo, 0, "s")
local s0, n0 = debug.info(0, "sn")
local normCo
local coOuter = coroutine.create(function()
	local r1, r2 = debug.info(normCo, 0, "sn")
	return r1, r2
end)
normCo = coOuter
local ok1 = pcall(function() return debug.info(1, "ss") end)
local ok2 = pcall(function() return debug.info(1, "ll") end)
local ok3 = pcall(function() return debug.info(1, "nn") end)
local ok4 = pcall(function() return debug.info(1, "aa") end)
local ok5 = pcall(function() return debug.info(1, "ff") end)
local ok6 = pcall(function() return debug.info(1, "z") end)
local ok7 = pcall(function() return debug.info(1, 123 :: any) end)
local ok8 = pcall(function() return debug.info(coOuter, function() end, "s") end)
local ok9 = pcall(function() return debug.info({}, "s") end)
local ok10 = pcall(function() return debug.info(1, -1) end)
local okTb1 = pcall(function() return debug.traceback({} :: any) end)
local okTb2 = pcall(function() return debug.traceback("m", "x" :: any) end)
local okTb3 = pcall(function() return debug.traceback("m", -1) end)
local okGf1 = pcall(function() return getfenv({}) end)
local okGf2 = pcall(function() return getfenv(-1) end)
local okSf1 = pcall(function() return setfenv(1, "x" :: any) end)
local okSf2 = pcall(function() return setfenv({}, {}) end)
local okSf3 = pcall(function() return setfenv(-1, {}) end)
local guestSample = function() return FLAG end
return deadTb,
	deadS,
	s0,
	n0,
	getfenv,
	setfenv,
	guestSample,
	ok1 or ok2 or ok3 or ok4 or ok5 or ok6 or ok7 or ok8 or ok9 or ok10 or okTb1 or okTb2 or okTb3 or okGf1 or okGf2 or okSf1 or okSf2 or okSf3
]],
					{ optimizationLevel = 1 }
				)),
				{ name = "=dbg_errs", env = hostDbgEnv }
			))
			local deadTb, deadS, dbgS0, dbgN0, gGetfenv, gSetfenv, guestSample, anyOk = dbgHooksChunk()
			expect(string.find(deadTb, "deadhdr", 1, true) ~= nil, deadTb)
			sert.eq(deadS, "[C]")
			sert.eq(dbgS0, "[C]")
			sert.eq(dbgN0, "info")
			sert.eq(anyOk, false)
			sert.eq(gSetfenv(guestSample, { FLAG = 99 }), guestSample)
			sert.eq(guestSample(), 99)
			sert.eq(gGetfenv(guestSample).FLAG, 99)
			sert.eq(pcall(gGetfenv, {}), false)
			sert.eq(pcall(gSetfenv, {}, {}), false)

			-- Verifier & loadProto defensive validation coverage
			local validMod = assert(Parser.Compiler.compileProto("return 1"))
			sert.eq(VM.loadProto({} :: any) == nil, true)
			sert.eq(VM.loadProto(setmetatable({}, {}) :: any) == nil, true)
			sert.throws(function()
				VM.loadProto(validMod, 123 :: any)
			end, "invalid load options")
			sert.throws(function()
				VM.loadProto(validMod, { env = 123 :: any })
			end, "invalid env table")
			local badModCases: { any } = {
				{
					id = 0,
					linedefined = 1,
					maxstacksize = -1,
					numparams = 0,
					nups = 0,
					isvararg = false,
					flags = 0,
					code = { 1 },
					kTypes = {},
					kValues = {},
					p = {},
				},
				{
					id = 0,
					linedefined = 1,
					maxstacksize = 1,
					numparams = 0,
					nups = 1,
					isvararg = false,
					flags = 0,
					code = { Opcodes.LOP_RETURN + 0x00010000 },
					kTypes = {},
					kValues = {},
					p = {},
				},
				{
					id = 0,
					linedefined = 1,
					maxstacksize = 1,
					numparams = 0,
					nups = 0,
					isvararg = false,
					flags = 0,
					code = {},
					kTypes = {},
					kValues = {},
					p = {},
				},
				{
					id = 0,
					linedefined = 1,
					maxstacksize = 1,
					numparams = 0,
					nups = 0,
					isvararg = false,
					flags = 0,
					code = { 1 },
					kTypes = {},
					kValues = {},
					p = { 9 },
				},
				{
					id = 0,
					linedefined = 1,
					maxstacksize = 1,
					numparams = 0,
					nups = 0,
					isvararg = false,
					flags = 0,
					code = { 1 },
					kTypes = { "bad_const" },
					kValues = { nil },
					p = {},
				},
				{
					id = 0,
					linedefined = 1,
					maxstacksize = 1,
					numparams = 0,
					nups = 0,
					isvararg = false,
					flags = 0,
					code = { 1 },
					kTypes = { Tags.LBC_CONSTANT_BOOLEAN },
					kValues = { 1 },
					p = {},
				},
				{
					id = 0,
					linedefined = 1,
					maxstacksize = 1,
					numparams = 0,
					nups = 0,
					isvararg = false,
					flags = 0,
					code = { 1 },
					kTypes = { Tags.LBC_CONSTANT_NUMBER },
					kValues = { "x" },
					p = {},
				},
				{
					id = 0,
					linedefined = 1,
					maxstacksize = 1,
					numparams = 0,
					nups = 0,
					isvararg = false,
					flags = 0,
					code = { 1 },
					kTypes = { Tags.LBC_CONSTANT_STRING },
					kValues = { 1 },
					p = {},
				},
				{
					id = 0,
					linedefined = 1,
					maxstacksize = 1,
					numparams = 0,
					nups = 0,
					isvararg = false,
					flags = 0,
					code = { 1 },
					kTypes = { Tags.LBC_CONSTANT_CLOSURE },
					kValues = { 99 },
					p = {},
				},
				{
					id = 0,
					linedefined = 1,
					maxstacksize = 1,
					numparams = 0,
					nups = 0,
					isvararg = false,
					flags = 0,
					code = { 1 },
					kTypes = { Tags.LBC_CONSTANT_VECTOR },
					kValues = { { "x" } },
					p = {},
				},
				{
					id = 0,
					linedefined = 1,
					maxstacksize = 1,
					numparams = 0,
					nups = 0,
					isvararg = false,
					flags = 0,
					code = { 1 },
					kTypes = { Tags.LBC_CONSTANT_IMPORT },
					kValues = { "bad" },
					p = {},
				},
				{
					id = 0,
					linedefined = 1,
					maxstacksize = 1,
					numparams = 0,
					nups = 0,
					isvararg = false,
					flags = 0,
					code = { 1 },
					kTypes = { Tags.LBC_CONSTANT_IMPORT },
					kValues = { bit32.lshift(1, 30) },
					p = {},
				},
				{
					id = 0,
					linedefined = 1,
					maxstacksize = 1,
					numparams = 0,
					nups = 0,
					isvararg = false,
					flags = 0,
					code = { 1 },
					kTypes = { Tags.LBC_CONSTANT_NIL, Tags.LBC_CONSTANT_IMPORT },
					kValues = { nil, bit32.lshift(1, 30) },
					p = {},
				},
				{
					id = 0,
					linedefined = 1,
					maxstacksize = 1,
					numparams = 0,
					nups = 0,
					isvararg = false,
					flags = 0,
					code = { 1 },
					kTypes = { Tags.LBC_CONSTANT_TABLE },
					kValues = { { keys = {}, length = 1 } },
					p = {},
				},
				{
					id = 0,
					linedefined = 1,
					maxstacksize = 1,
					numparams = 0,
					nups = 0,
					isvararg = false,
					flags = 0,
					code = { 1 },
					kTypes = { Tags.LBC_CONSTANT_NIL, Tags.LBC_CONSTANT_TABLE },
					kValues = { nil, { keys = { 0 }, length = 1 } },
					p = {},
				},
				{
					id = 0,
					linedefined = 1,
					maxstacksize = 1,
					numparams = 0,
					nups = 0,
					isvararg = false,
					flags = 0,
					code = { 1 },
					kTypes = { Tags.LBC_CONSTANT_TABLE_WITH_CONSTANTS },
					kValues = { { keys = {}, constants = {}, length = 1 } },
					p = {},
				},
				{
					id = 0,
					linedefined = 1,
					maxstacksize = 1,
					numparams = 0,
					nups = 0,
					isvararg = false,
					flags = 0,
					code = { 1 },
					kTypes = {
						Tags.LBC_CONSTANT_STRING,
						Tags.LBC_CONSTANT_TABLE,
						Tags.LBC_CONSTANT_TABLE_WITH_CONSTANTS,
					},
					kValues = {
						"k",
						{ keys = {}, length = 0 },
						{ keys = { 0 }, constants = { 1 }, length = 1 },
					},
					p = {},
				},
				{
					id = 0,
					linedefined = 1,
					maxstacksize = 1,
					numparams = 0,
					nups = 0,
					isvararg = false,
					flags = 0,
					code = { 1 },
					kTypes = { 99 },
					kValues = { nil },
					p = {},
				},
				{
					id = 0,
					linedefined = 1,
					maxstacksize = 2,
					numparams = 0,
					nups = 0,
					isvararg = false,
					flags = 0,
					code = {
						Opcodes.LOP_JUMP + 0x00010000, -- jumps +1 into aux word of GETGLOBAL
						Opcodes.LOP_GETGLOBAL,
						0,
						Opcodes.LOP_RETURN + 0x00010000,
					},
					kTypes = { Tags.LBC_CONSTANT_STRING },
					kValues = { "g" },
					p = {},
				},
				{
					id = 0,
					linedefined = 1,
					maxstacksize = 1,
					numparams = 0,
					nups = 0,
					isvararg = false,
					flags = 0,
					code = { Opcodes.LOP_RETURN + 0x00010000 },
					kTypes = { Tags.LBC_CONSTANT_NIL, Tags.LBC_CONSTANT_TABLE_WITH_CONSTANTS },
					kValues = {
						nil,
						{ keys = { 0 }, constants = { -1 }, length = 1 },
					},
					p = {},
				},
				{
					id = 0,
					linedefined = 1,
					maxstacksize = 1,
					numparams = 0,
					nups = 0,
					isvararg = false,
					flags = 0,
					code = { Opcodes.LOP_RETURN + 0x00010000 },
					kTypes = { Tags.LBC_CONSTANT_TABLE, Tags.LBC_CONSTANT_TABLE_WITH_CONSTANTS },
					kValues = {
						{ keys = {}, length = 0 },
						{ keys = { 0 }, constants = { -1 }, length = 1 },
					},
					p = {},
				},
				{
					id = 0,
					linedefined = 1,
					maxstacksize = 1,
					numparams = 0,
					nups = 0,
					isvararg = false,
					flags = 0,
					code = { Opcodes.LOP_RETURN + 0x00010000 },
					kTypes = { Tags.LBC_CONSTANT_NUMBER, Tags.LBC_CONSTANT_TABLE_WITH_CONSTANTS },
					kValues = {
						0 / 0,
						{ keys = { 0 }, constants = { -1 }, length = 1 },
					},
					p = {},
				},
				{
					id = 0,
					linedefined = 1,
					maxstacksize = 1,
					numparams = 0,
					nups = 0,
					isvararg = false,
					flags = 0,
					code = { Opcodes.LOP_RETURN + 0x00010000 },
					kTypes = { Tags.LBC_CONSTANT_VECTOR, Tags.LBC_CONSTANT_TABLE_WITH_CONSTANTS },
					kValues = {
						{ 0 / 0, 0, 0, 0 },
						{ keys = { 0 }, constants = { -1 }, length = 1 },
					},
					p = {},
				},
			}
			for _, badProto in badModCases do
				local fnBad, errBad = VM.loadProto({
					version = 14,
					typesversion = 3,
					mainid = 0,
					strings = {},
					protos = { badProto },
				} :: any)
				sert.eq(fnBad, nil)
				expect(type(errBad) == "string", "bad proto rejected")
			end

			-- Non-frozen ProtoModule checks, filteredHostEnv proxy, error("boom", "2"), and multi-return cross-chunk CALL hooks
			local unfrozenMod: any = {
				version = 14,
				typesversion = 3,
				mainid = 0,
				strings = {},
				protos = {
					{
						id = 0,
						maxstacksize = 2,
						numparams = 0,
						nups = 0,
						isvararg = false,
						flags = 0,
						linedefined = 1,
						code = { Opcodes.LOP_LOADN + 0x00050000, Opcodes.LOP_RETURN + 0x00020000 },
						kTypes = { Tags.LBC_CONSTANT_TABLE },
						kValues = { { keys = {}, length = 0 } },
						p = {},
					},
				},
			}
			sert.eq(assert(VM.loadProto(unfrozenMod))(), 5)

			local filteredMathEnv = VM.createEnvironment(nil, {
				libraries = { "math" },
				inheritHost = true,
				readOnly = true,
			})
			local filteredFn = assert(
				VM.loadBytecode(
					assert(
						Parser.compile(
							"return math.abs(-4), string == nil, MissingHostGlobal == nil",
							{ optimizationLevel = 2 }
						)
					),
					{ name = "=filt_ro", env = filteredMathEnv }
				)
			)
			local fm1, fm2, fm3 = filteredFn()
			sert.eq(fm1, 4)
			sert.eq(fm2, true)
			sert.eq(fm3, true)

			local customMtNoLock = setmetatable({}, table.freeze({ __index = roBase })) :: any
			local customMtFnIdx = setmetatable(
				{},
				table.freeze({
					__metatable = true,
					__index = function(_self: any, k: any)
						return roBase[k]
					end,
				})
			) :: any
			for _, eMt in { customMtNoLock, customMtFnIdx } do
				local mtFn = assert(
					VM.loadBytecode(
						assert(Parser.compile("local x = ...; return type(x)", { optimizationLevel = 1 })),
						{ name = "=mt_safe", env = eMt }
					)
				)
				sert.eq(mtFn(1), "number")
			end

			local coErrFn = assert(VM.loadBytecode(
				assert(Parser.compile(
					[[
local ok, err = pcall(function()
	error("coerced", "2" :: any)
end)
return ok, err
]],
					{ optimizationLevel = 1 }
				)),
				{ name = "=err_coerced" }
			))
			local ceOk, ceMsg = coErrFn()
			sert.eq(ceOk, false)
			expect(string.find(tostring(ceMsg), "coerced", 1, true) ~= nil, tostring(ceMsg))

			local hookCalls, hookRets = 0, 0
			local callee2 = assert(
				VM.loadBytecode(
					assert(Parser.compile("return function(x) return x + 1, x + 2 end", { optimizationLevel = 1 })),
					{
						name = "=c2_multi",
						onCall = function()
							hookCalls += 1
						end,
						onReturn = function()
							hookRets += 1
						end,
					}
				)
			)()
			local caller2 = assert(
				VM.loadBytecode(
					assert(
						Parser.compile(
							"local fn = ...; local function invoke() local a, b = fn(10); return a + b end; return invoke()",
							{ optimizationLevel = 1 }
						)
					),
					{
						name = "=caller2_multi",
						onCall = function()
							hookCalls += 1
						end,
						onReturn = function()
							hookRets += 1
						end,
					}
				)
			)
			sert.eq(caller2(callee2), 23)
			expect(hookCalls >= 2 and hookRets >= 2, "cross-chunk multi-ret hooks fired")

			-- 7. Partial-frozen ProtoModule checks (isDeepFrozenModule branches)
			local Tags = BytecodeDefs.Tags
			local function makePartialFrozenMod(mutator: (any, any) -> ()): any
				local p: any = {
					id = 0,
					maxstacksize = 2,
					numparams = 0,
					nups = 0,
					isvararg = false,
					flags = 0,
					linedefined = 1,
					code = { Opcodes.LOP_LOADN + 0x00050000, Opcodes.LOP_RETURN + 0x00020000 },
					kTypes = {},
					kValues = {},
					p = {},
				}
				local m: any = {
					version = 14,
					typesversion = 3,
					mainid = 0,
					strings = { "s" },
					protos = { p },
				}
				mutator(m, p)
				local function freezeIfNeeded(t: any)
					if type(t) == "table" and not table.isfrozen(t) then
						table.freeze(t)
					end
				end
				freezeIfNeeded(p.code)
				freezeIfNeeded(p.p)
				freezeIfNeeded(p.kTypes)
				freezeIfNeeded(p.kValues)
				freezeIfNeeded(p)
				freezeIfNeeded(m.protos)
				return table.freeze(m)
			end
			sert.eq(assert(VM.loadProto(makePartialFrozenMod(function() end)))(), 5)
			sert.eq(
				assert(VM.loadProto(makePartialFrozenMod(function(m, p)
					table.freeze(m.strings)
					p.kValues = { 123 } -- unfrozen kValues
				end)))(),
				5
			)
			sert.eq(
				assert(VM.loadProto(makePartialFrozenMod(function(m, p)
					table.freeze(m.strings)
					p.kTypes = { Tags.LBC_CONSTANT_TABLE }
					p.kValues = { table.freeze({ keys = {}, length = 0 }) }
				end)))(),
				5
			)
			sert.eq(
				assert(VM.loadProto(makePartialFrozenMod(function(m, p)
					table.freeze(m.strings)
					p.kTypes = { Tags.LBC_CONSTANT_STRING, Tags.LBC_CONSTANT_NIL }
					p.kValues = { "a", nil }
				end)))(),
				5
			)
			sert.eq(
				assert(VM.loadProto(makePartialFrozenMod(function(m, p)
					table.freeze(m.strings)
					p.kTypes = { Tags.LBC_CONSTANT_TABLE_WITH_CONSTANTS }
					p.kValues = { table.freeze({ keys = table.freeze({}), constants = {}, length = 0 }) }
				end)))(),
				5
			)
			sert.eq(
				assert(VM.loadProto(makePartialFrozenMod(function(m, p)
					table.freeze(m.strings)
					p.kTypes = { Tags.LBC_CONSTANT_VECTOR }
					p.kValues = { { 1, 2, 3, 0 } }
				end)))(),
				5
			)
			sert.eq(
				assert(VM.loadProto(makePartialFrozenMod(function(m, p)
					table.freeze(m.strings)
					p.kTypes = { Tags.LBC_CONSTANT_STRING, Tags.LBC_CONSTANT_CLASS_SHAPE }
					p.kValues = {
						"Box",
						table.freeze({
							className = 0,
							numPrivateInstanceProps = 0,
							numPrivateStaticProps = 0,
							propertyNames = {},
							methodNames = table.freeze({}),
						}),
					}
				end)))(),
				5
			)
			sert.eq(
				assert(VM.loadProto(makePartialFrozenMod(function(m, p)
					table.freeze(m.strings)
					p.kTypes = { Tags.LBC_CONSTANT_STRING, Tags.LBC_CONSTANT_CLASS_SHAPE }
					p.kValues = {
						"Box",
						table.freeze({
							className = 0,
							numPrivateInstanceProps = 0,
							numPrivateStaticProps = 0,
							propertyNames = table.freeze({}),
							methodNames = {},
						}),
					}
				end)))(),
				5
			)

			-- 8. lookupEnvChainStatic frozen metatable __index chains
			local frozenParent = table.freeze({ math = math, seed = 42 })
			local staticMtNil = setmetatable({}, table.freeze({ __metatable = true })) :: any
			local staticMtFrozen = setmetatable({}, table.freeze({ __metatable = true, __index = frozenParent })) :: any
			local staticMtUnfrozen =
				setmetatable({}, table.freeze({ __metatable = true, __index = { math = math, seed = 43 } })) :: any
			sert.eq(
				assert(
					VM.loadBytecode(
						assert(Parser.compile("return math.abs(-9)", { optimizationLevel = 2 })),
						{ name = "=mt_frozen", env = staticMtFrozen }
					)
				)(),
				9
			)
			sert.eq(
				assert(
					VM.loadBytecode(
						assert(Parser.compile("return MissingVar == nil", { optimizationLevel = 2 })),
						{ name = "=mt_nil", env = staticMtNil }
					)
				)(),
				true
			)
			sert.eq(
				assert(
					VM.loadBytecode(
						assert(Parser.compile("return math.abs(-11) + seed", { optimizationLevel = 2 })),
						{ name = "=mt_unfrozen", env = staticMtUnfrozen }
					)
				)(),
				54
			)

			-- 9. LOP_SETUDATAKS & LOP_GETUDATAKS on env and non-env targets, plus non-simple vararg cross-chunk CALL
			local udataEnv = VM.createEnvironment()
			local setLog: { [string]: any } = {}
			local udataMod: any = {
				version = 14,
				typesversion = 3,
				mainid = 0,
				strings = {},
				protos = {
					{
						id = 0,
						linedefined = 1,
						maxstacksize = 4,
						numparams = 2,
						nups = 0,
						isvararg = false,
						flags = 0,
						code = {
							Opcodes.LOP_SETUDATAKS + 1 * 256 + 0 * 65536, -- reg1 -> tbl[reg0]["math"]
							0,
							Opcodes.LOP_SETUDATAKS + 1 * 256 + 0 * 65536, -- reg1 -> tbl[reg0]["print"]
							1,
							Opcodes.LOP_GETUDATAKS + 2 * 256 + 0 * 65536, -- reg2 <- tbl[reg0]["print"]
							1,
							Opcodes.LOP_RETURN + 2 * 256 + 2 * 65536,
						},
						kTypes = { Tags.LBC_CONSTANT_STRING, Tags.LBC_CONSTANT_STRING },
						kValues = { "math", "print" },
						p = {},
					},
				},
			}
			local udataFnHooked = assert(VM.loadProto(udataMod, {
				env = udataEnv,
				setGlobal = function(k: string, v: any)
					setLog[k] = v
				end,
				getGlobal = function(k: string)
					return setLog[k]
				end,
			}))
			local gotPrintWrapped = udataFnHooked(udataEnv, print)
			expect(type(gotPrintWrapped) == "function", "udata env get/set worked with hooks")
			expect(setLog.math == print and setLog.print == print, "udata env setGlobal recorded")

			local udataFnDirect = assert(VM.loadProto(udataMod, { env = udataEnv }))
			local otherTbl: { [string]: any } = {}
			local gotDirect = udataFnDirect(otherTbl, print)
			sert.eq(gotDirect, print)
			sert.eq(otherTbl.math, print)
			local udataEnvDirectRet = udataFnDirect(udataEnv, print)
			expect(type(udataEnvDirectRet) == "function", "udata env direct set/get")

			local varargCallee = assert(
				VM.loadBytecode(
					assert(Parser.compile("return function(...) local a, b = ...; return (a or 0) + (b or 0) end")),
					{
						name = "=va_callee",
						onCall = function()
							hookCalls += 1
						end,
					}
				)
			)()
			local varargCaller = assert(VM.loadBytecode(assert(Parser.compile("local f = ...; return f(7, 8, 9)")), {
				name = "=va_caller",
				onCall = function()
					hookCalls += 1
				end,
			}))
			sert.eq(varargCaller(varargCallee), 15)

			-- Per-root safeenv preservation: mutating an unrelated root keeps math/bit32 fastpaths alive
			local perRootEnv = VM.createEnvironment()
			local perRootFn = assert(VM.load(
				[[
				local a = math.abs(-5)
				rawset = function(t, k, v)
					t[k] = v
					return t
				end
				local tbl = {}
				rawset(tbl, "ok", true)
				local b = math.abs(-7) + bit32.bxor(3, 5)
				return a, b, tbl.ok
			]],
				{ env = perRootEnv, compile = { optimizationLevel = 2 } }
			))
			local sr1, sr2, sr3 = perRootFn()
			sert.eq(sr1, 5)
			sert.eq(sr2, 13)
			sert.eq(sr3, true)

			-- Lazy cName resolution works on host function errors, debug.info, and callable tables
			local callableErr = setmetatable({}, {
				__call = function()
					error("callable boom", 0)
				end,
			})
			local lazyNameFn = assert(VM.load([[
				local c = ...
				local _, e1 = pcall(function()
					return string.sub({} :: any, 1)
				end)
				local _, e2 = pcall(function()
					return c()
				end)
				local n
				local ok3 = xpcall(function()
					return tonumber()
				end, function()
					n = debug.info(2, "n")
				end)
				return e1, e2, ok3, n
			]]))
			local le1, le2, lok3, ln = lazyNameFn(callableErr)
			expect(
				type(le1) == "string" and string.find(le1, "invalid argument", 1, true) ~= nil,
				"host error formatted: " .. tostring(le1)
			)
			expect(
				type(le2) == "string" and string.find(le2, "callable boom", 1, true) ~= nil,
				"callable error: " .. tostring(le2)
			)
			sert.eq(lok3, false)
			sert.eq(ln, "tonumber")
		end
	)

	test(
		"matches Luau 0.748 conformance: LUAI_MAXCALLS/pcall stackover, unpack cap, debug.info arg order, DUPTABLE/NEWTABLE order, compile error src, setfenv(0), and CONCAT GC",
		function()
			local Ouro = require("../")

			-- 1. LUAI_MAXCALLS (20000) + pcall(stackinfinite) + pcall(stackover) #res == 10000 + 1_000_000 active stack slot cap
			local stackFn = assert(Ouro.load(
				[[
				local function stackinfinite()
					return stackinfinite()
				end
				local okInf, errInf = pcall(stackinfinite)
				assert(not okInf and type(errInf) == "string")

				local function stackover()
					return pcall(stackover)
				end
				local res = { pcall(stackover) }
				assert(#res == 10000, "expected 10000, got " .. tostring(#res))

				local function recurse(n, ...)
					return n <= 1 and (1 + #{ ... }) or recurse(n - 1, table.unpack(table.create(4000, 1))) + 1
				end
				local okUnpack, msgUnpack = pcall(recurse, 19000)
				assert(not okUnpack and string.find(tostring(msgUnpack), "too many results to unpack") ~= nil, tostring(msgUnpack))
				return true
			]],
				{ name = "=stack_conformance" }
			))
			sert.eq(stackFn(), true)

			-- 2. debug.info validates target before options
			local diFn = assert(Ouro.load(
				[[
				local co = coroutine.create(function() coroutine.yield() end)
				coroutine.resume(co)
				local function qux(...)
					local ok, err = pcall(debug.info, ...)
					assert(not ok)
					return err
				end
				assert(string.find(qux(), "function or level expected") ~= nil)
				assert(string.find(qux(1), "string expected") ~= nil)
				assert(string.find(qux(-1), "level can't be negative") ~= nil)
				assert(string.find(qux(-1, 123), "level can't be negative") ~= nil)
				assert(string.find(qux(co), "function or level expected") ~= nil)
				assert(string.find(qux(co, 1), "string expected") ~= nil)
				return true
			]],
				{ name = "=di_order" }
			))
			sert.eq(diFn(), true)

			-- 3. DUPTABLE and NEWTABLE hash seed iteration order across O0/O1/O2
			local biomeOrder = runAtAllOptLevels([[
				local kSelectedBiomes = {
					["Mountains"] = true,
					["Canyons"] = true,
					["Dunes"] = true,
					["Arctic"] = true,
					["Lavaflow"] = true,
					["Hills"] = true,
					["Plains"] = true,
					["Marsh"] = true,
					["Water"] = true,
				}
				local result = ""
				for k in pairs(kSelectedBiomes) do
					result = result .. k
				end
				return result
			]])
			sert.eq(biomeOrder, "ArcticDunesCanyonsWaterMountainsHillsLavaflowPlainsMarsh")

			-- 4. Ouro.load compile errors include formatChunkSrc(name)
			local f1, e1 = Ouro.load("break label")
			sert.eq(f1, nil)
			expect(string.find(tostring(e1), '^%[string "break label"%]:1:') ~= nil, tostring(e1))
			local f2, e2 = Ouro.load("local x =", { name = "=mychunk" })
			sert.eq(f2, nil)
			expect(string.find(tostring(e2), "^mychunk:1:") ~= nil, tostring(e2))

			-- 5. setfenv(0, newEnv) thread-env inheritance when Ouro.load called with env == nil
			local fenvEnv: any
			fenvEnv = VM.createEnvironment({
				loadstring = function(s: string, chunkname: string?)
					return Ouro.load(s, { name = chunkname or s, env = fenvEnv.getfenv(0) })
				end,
			})
			local fenvInheritFn = assert(Ouro.load(
				[[
				local function foo(s)
					return loadstring(s)
				end
				assert(getfenv(foo("")) == getfenv())
				local a = { loadstring = loadstring }
				setfenv(foo, a)
				assert(getfenv(foo("")) == getfenv())
				setfenv(0, a)
				assert(getfenv(foo("")) == a)
				setfenv(0, getfenv())
				assert(getfenv(foo("")) == getfenv())
				return true
			]],
				{ name = "=setfenv0", env = fenvEnv }
			))
			sert.eq(fenvInheritFn(), true)
		end
	)

	test("covers guarded cross-context calls, fastcall fallbacks, and VM load validation", function()
		local Ouro = require("../")

		local sharedEnv = VM.createEnvironment({
			myGlobal = 10,
		})
		local guardedInner = assert(Ouro.load(
			[[
			local x, s = ...
			local a = math.abs(x) + math.floor(1.5) + math.ceil(1.2) + math.round(2.6)
			local b = math.clamp(x, -3, 3) + math.sign(x) + math.min(1, 2) + math.max(1, 2)
			local c = bit32.extract(0xFF, 2, 4) + bit32.extract(0xFF, 2) + bit32.replace(0, 7, 1)
			local d = bit32.band(12, 10) + bit32.bor(1, 2) + bit32.bxor(3, 5) + bit32.bnot(0) % 16
			local e = bit32.lshift(1, 3) + bit32.rshift(16, 2) + bit32.arshift(-8, 1) % 16
			local f = bit32.lrotate(1, 2) + bit32.rrotate(4, 1) + bit32.countlz(1) + bit32.countrz(8) + bit32.byteswap(1) % 256
			local sl = string.len(s)
			local sb1 = string.byte(s)
			local sb2 = string.byte(s, 2)
			local sc1 = string.char(65)
			local sc2 = string.char(65, 66)
			local sc3 = string.char(65, 66, 67)
			local ss2 = string.sub(s, 2)
			local ss3 = string.sub(s, 1, 2)
			local t = table.create(3, 4)
			table.insert(t, 9)
			local u1, u2, u3 = table.unpack(t, 1, 3)
			local v1, v2 = table.unpack({ 11, 22 })
			local re = rawequal(1, 1)
			local rg = rawget(_G, "myGlobal")
			local tp = type(s) .. ":" .. typeof(t)
			local mt = setmetatable({}, { __index = function() return 1 end })
			local isum = 0
			for i, v in ipairs(mt) do isum += i + v end
			-- Trigger fastcall fallback paths (-1, nil, nil)
			local ok1 = pcall(function() return math.abs("bad" :: any) end)
			local ok2 = pcall(function() return string.sub(123 :: any, 1) end)
			local ok3 = pcall(function() return bit32.extract(1, -1) end)
			local ok4 = pcall(function() return bit32.replace(1, 1, -1) end)
			local ok5 = pcall(function() return table.insert(table.freeze({}), 1) end)
			local ok6 = pcall(function() return table.clear(table.freeze({})) end)
			local ok7 = pcall(function() return string.byte(123 :: any) end)
			local ok8 = pcall(function() return string.char(999) end)
			local ok9 = pcall(function() return string.len(123 :: any) end)
			local ok10 = pcall(function() return table.create(-5) end)
			local lerpVal = if math.lerp then math.lerp(0, 10, 0.5) else 5
			if rawget(_G, "tempMut") == nil then
				rawset(_G, "tempMut", 77)
			end
			return a + b + c + d + e + f + sl + sb1 + sb2 + #sc1 + #sc2 + #sc3 + #ss2 + #ss3 + u1 + u2 + u3 + v1 + v2 + (if re then 1 else 0) + rg + #tp + isum + lerpVal + (if ok1 or ok2 or ok3 or ok4 or ok5 or ok6 or ok7 or ok8 or ok9 or ok10 then 0 else 1)
		]],
			{
				name = "=guarded_inner",
				env = sharedEnv,
				instructionLimit = 500000,
				timeout = 5,
				resourceLimits = {
					maxStringLength = 100000,
					maxTableSize = 10000,
					maxBufferSize = 10000,
					maxPatternLength = 1000,
				},
				compile = { optimizationLevel = 2 },
			}
		))
		local unguardedCaller = assert(Ouro.load(
			[[
			local fn = ...
			local a = fn(-2, "abc")
			local ok, b = pcall(fn, -2, "abc")
			local ok2, c = xpcall(function() return fn(-2, "abc") end, function(e) return e end)
			return a, ok, b, ok2, c
		]],
			{ name = "=unguarded_outer", env = sharedEnv, compile = { optimizationLevel = 2 } }
		))
		local rA, rOk, rB, rOk2, rC = unguardedCaller(guardedInner)
		sert.eq(rOk, true)
		sert.eq(rOk2, true)
		sert.eq(rA, rB)
		sert.eq(rA, rC)

		-- Guarded caller calling guarded inner via pcall (cross-ctx returnFromPcallFrame)
		local guardedOuter = assert(Ouro.load(
			[[
			local fn = ...
			local ok, res = pcall(fn, -2, "abc")
			return ok, res
		]],
			{
				name = "=guarded_outer",
				env = sharedEnv,
				instructionLimit = 500000,
				compile = { optimizationLevel = 2 },
			}
		))
		local gOk, gRes = guardedOuter(guardedInner)
		sert.eq(gOk, true)
		sert.eq(gRes, rA)

		-- Cross-ctx clear + setmetatable on tracked env
		local mutEnv: { [string]: any } = {
			table = table,
			setmetatable = setmetatable,
		}
		mutEnv._G = mutEnv
		local mutFn = assert(Ouro.load(
			[[
			local t = { 1, 2 }
			table.clear(t)
			setmetatable(_G, { __index = {} })
			table.clear(_G)
			return #t
		]],
			{ name = "=mut_env", env = mutEnv, compile = { optimizationLevel = 2 } }
		))
		sert.eq(mutFn(), 0)

		-- VM.loadProto / VM.loadBytecode validation edges
		local goodBc = assert(Ouro.compile("return 1"))
		local goodMod = assert(Ouro.Bytecode.deserialize(goodBc))
		sert.throws(function()
			VM.loadProto(goodMod, { name = 123 :: any })
		end, "invalid chunk name")
		sert.throws(function()
			VM.loadProto(goodMod, "bad" :: any)
		end, "invalid load options")
		sert.eq(
			select(
				1,
				VM.loadProto({ version = 14, typesversion = 3, strings = {}, protos = goodMod.protos, mainid = 99 })
			),
			nil
		)
		sert.eq(
			select(
				1,
				VM.loadProto({ version = 100, typesversion = 3, strings = {}, protos = goodMod.protos, mainid = 0 })
			),
			nil
		)
		sert.throws(function()
			VM.loadBytecode(goodBc, "bad" :: any)
		end, "invalid load options")
		sert.eq(select(1, VM.loadBytecode(buffer.create(0))), nil)
		sert.throws(function()
			VM.loadBytecode(123 :: any)
		end, "string or buffer expected")

		-- Guarded (no resourceLimits) & unguarded dynamic fastcalls + cross-context pcall/xpcall + >16 stack slots
		local fcSrc = [[
			local a, b, c, s, t = ...
			local l0 = math.floor(a) + math.ceil(a) + math.sqrt(b)
			local l1 = string.len(s)
			local l2 = string.byte(s)
			local l3 = string.byte(s, 2)
			local l4 = string.sub(s, 2)
			local l5 = string.sub(s, 1, 2)
			local l6 = type(s)
			local l7 = typeof(t)
			local l8 = bit32.bnot(a)
			local l9 = rawequal(a, b)
			local l10 = if math.lerp then math.lerp(a, b, c) else 0
			local packed = { table.unpack(t, 1, 2) }
			local packedAll = { table.unpack(t) }
			local nsum = 0
			for k, v in next, { x = 1, y = 2 } do
				nsum += v + #k
			end
			local ok1 = pcall(function() return string.byte(123 :: any, 1) end)
			local ok2 = pcall(function() return string.sub(123 :: any, 1, 2) end)
			local ok3 = pcall(function() return typeof() end)
			local ok4 = pcall(function() return type() end)
			local ok5 = pcall(function() return rawequal(1 :: any) end)
			local ok6 = pcall(function() return table.unpack(123 :: any, 1, 2) end)
			local ok7 = pcall(function() return math.lerp(1 :: any, "x" :: any, 0.5) end)
			return l0 + l1 + l2 + l3 + #l4 + #l5 + #l6 + #l7 + (l8 % 16) + (if l9 then 1 else 0) + l10 + #packed + #packedAll + nsum + (if ok1 or ok2 or ok3 or ok4 or ok5 or ok6 or ok7 then 0 else 1)
		]]
		local fcFast = assert(Ouro.load(fcSrc, { name = "=fc_fast", compile = { optimizationLevel = 2 } }))
		local fcGuarded = assert(Ouro.load(fcSrc, {
			name = "=fc_guarded",
			instructionLimit = 500000,
			compile = { optimizationLevel = 2 },
		}))
		local fcResFast = fcFast(2, 4, 0.5, "xyz", { 10, 20, 30 })
		local fcResGuarded = fcGuarded(2, 4, 0.5, "xyz", { 10, 20, 30 })
		sert.eq(fcResFast, fcResGuarded)

		-- Unguarded caller invoking guarded callee via pcall (both fixed & multi-return)
		local pcaller = assert(Ouro.load(
			[[
			local g = ...
			local ok1, r1 = pcall(g, 2, 4, 0.5, "xyz", { 10, 20, 30 })
			local packed = { pcall(g, 2, 4, 0.5, "xyz", { 10, 20, 30 }) }
			return ok1, r1, packed[1], packed[2]
		]],
			{ name = "=pcaller", compile = { optimizationLevel = 2 } }
		))
		local po1, pr1, pp1, pp2 = pcaller(fcGuarded)
		sert.eq(po1, true)
		sert.eq(pp1, true)
		sert.eq(pr1, fcResFast)
		sert.eq(pp2, fcResFast)

		-- Guarded recursive function with >16 stack slots (both guarded and unguarded frame reuse)
		local bigFrameSrc = [[
			local function rec(n)
				local a1,a2,a3,a4,a5,a6,a7,a8,a9,a10,a11,a12,a13,a14,a15,a16,a17,a18 = 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18
				if n <= 0 then return a1 + a18 end
				return rec(n - 1)
			end
			return rec(3)
		]]
		local bigFrameFn = assert(
			Ouro.load(
				bigFrameSrc,
				{ name = "=bigframe", instructionLimit = 50000, compile = { optimizationLevel = 0 } }
			)
		)
		sert.eq(bigFrameFn(), 19)

		-- Unguarded: first call depth 2..4 with small frame, then call >16-slot rec to hit frame stack growth
		local reuseFrameFn = assert(Ouro.load(
			[[
			local function small(n)
				if n <= 0 then return 1 end
				return small(n - 1)
			end
			local function rec(n)
				local a1,a2,a3,a4,a5,a6,a7,a8,a9,a10,a11,a12,a13,a14,a15,a16,a17,a18 = 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18
				if n <= 0 then return a1 + a18 end
				return rec(n - 1)
			end
			return small(4) + rec(3), 20, 30, 40
		]],
			{ name = "=reuse_frame", compile = { optimizationLevel = 0 } }
		))
		local rf1, rf2, rf3, rf4 = reuseFrameFn()
		sert.eq(rf1, 20)
		sert.eq(rf2, 20)
		sert.eq(rf3, 30)
		sert.eq(rf4, 40)

		-- Multi-return 2 and 3 entry return counts + ipairs standalone inext + local pcall(guarded)
		local ret2Fn = assert(Ouro.load("return 10, 20", { name = "=ret2" }))
		local r2a, r2b = ret2Fn()
		sert.eq(r2a, 10)
		sert.eq(r2b, 20)
		local ret3Fn = assert(Ouro.load("return 10, 20, 30", { name = "=ret3" }))
		local r3a, r3b, r3c = ret3Fn()
		sert.eq(r3a, 10)
		sert.eq(r3b, 20)
		sert.eq(r3c, 30)
		local ret4Fn = assert(Ouro.load("return 10, 20, 30, 40", { name = "=ret4" }))
		local xOk2, xr2a, xr2b = xpcall(ret2Fn, function(e)
			return e
		end)
		sert.eq(xOk2, true)
		sert.eq(xr2a, 10)
		sert.eq(xr2b, 20)
		local xOk3, xr3a, xr3b, xr3c = xpcall(ret3Fn, function(e)
			return e
		end)
		sert.eq(xOk3, true)
		sert.eq(xr3a, 10)
		sert.eq(xr3b, 20)
		sert.eq(xr3c, 30)
		local xOk4, xr4a, xr4b, xr4c, xr4d = xpcall(ret4Fn, function(e)
			return e
		end)
		sert.eq(xOk4, true)
		sert.eq(xr4a, 10)
		sert.eq(xr4b, 20)
		sert.eq(xr4c, 30)
		sert.eq(xr4d, 40)

		-- In-VM xpcall calling multi-return closures (2, 3, 4 return values)
		local inVmXpFn = assert(Ouro.load(
			[[
			local f2, f3, f4 = ...
			local ok2, a2, b2 = xpcall(f2, function(e) return e end)
			local ok3, a3, b3, c3 = xpcall(f3, function(e) return e end)
			local ok4, a4, b4, c4, d4 = xpcall(f4, function(e) return e end)
			return ok2 and ok3 and ok4, a2 + b2 + a3 + b3 + c3 + a4 + b4 + c4 + d4
		]],
			{ name = "=invm_xp" }
		))
		local ivxOk, ivxSum = inVmXpFn(ret2Fn, ret3Fn, ret4Fn)
		sert.eq(ivxOk, true)
		sert.eq(ivxSum, 190)

		-- Unguarded dynamic math.floor/ceil/sqrt + pcall multi-return nil fill on error
		local mathFastFn = assert(Ouro.load(
			[[
			local x = ...
			local a = math.floor(x) + math.ceil(x) + math.sqrt(math.abs(x))
			local ok, err, ex1, ex2 = pcall(function() error("pboom") end)
			return a, ok, type(err), ex1, ex2
		]],
			{ name = "=math_fast", compile = { optimizationLevel = 2 } }
		))
		local mfA, mfOk, mfEt, mfEx1, mfEx2 = mathFastFn(4.25)
		sert.eq(mfA, 4 + 5 + math.sqrt(4.25))
		sert.eq(mfOk, false)
		sert.eq(mfEt, "string")
		sert.eq(mfEx1, nil)
		sert.eq(mfEx2, nil)

		-- Guarded _G GETTABLE/SETTABLE/GETTABLEKS/SETTABLEKS with host wrappers
		local gTblEnv = { debug = debug, coroutine = coroutine, table = table, type = type }
		gTblEnv._G = gTblEnv
		local gTblFn = assert(Ouro.load(
			[[
			local kd, kc = "debug", "coroutine"
			local d1 = _G[kd]
			local c1 = _G[kc]
			local d2 = _G.debug
			local c2 = _G.coroutine
			_G["savedD"] = d1
			_G.savedC = c1
			return type(d1), type(c1), d1 == d2, c1 == c2, _G.savedD == d1, _G.savedC == c1
		]],
			{
				name = "=gtbl_guarded",
				env = gTblEnv,
				instructionLimit = 50000,
				compile = { optimizationLevel = 0 },
			}
		))
		local gd1, gc1, gdEq, gcEq, gsD, gsC = gTblFn()
		sert.eq(gd1, "table")
		sert.eq(gc1, "table")
		sert.eq(gdEq, true)
		sert.eq(gcEq, true)
		sert.eq(gsD, true)
		sert.eq(gsC, true)

		local inextGuarded = assert(Ouro.load(
			[[
			local t = { 10, 20 }
			local it, st, idx = ipairs(t)
			local k1, v1 = it(st, idx)
			local k2, v2 = it(st, k1)
			local k3, v3 = it(st, k2)
			local p = pcall
			return k1, v1, k2, v2, k3, v3, p(function() return 1 end)
		]],
			{ name = "=inext_g", instructionLimit = 50000, compile = { optimizationLevel = 2 } }
		))
		local ik1, iv1, ik2, iv2, ik3, iv3, ipok, ipres = inextGuarded()
		sert.eq(ik1, 1)
		sert.eq(iv1, 10)
		sert.eq(ik2, 2)
		sert.eq(iv2, 20)
		sert.eq(ik3, nil)
		sert.eq(iv3, nil)
		sert.eq(ipok, true)
		sert.eq(ipres, 1)

		local localPcallCaller = assert(Ouro.load(
			[[
			local g = ...
			local p = pcall
			local ok, res = p(g, 2, 4, 0.5, "xyz", { 10, 20, 30 })
			return ok, res
		]],
			{ name = "=lpcall_caller", compile = { optimizationLevel = 2 } }
		))
		local lpOk, lpRes = localPcallCaller(fcGuarded)
		sert.eq(lpOk, true)
		sert.eq(lpRes, fcResFast)

		-- Frozen custom env metatable chain for lookupEnvChainStatic
		local frozenBase = table.freeze({
			math = math,
			x = 55,
		})
		local lockedMt = table.freeze({
			__metatable = "locked",
			__index = frozenBase,
		})
		local lockedEnv = setmetatable({}, lockedMt)
		local lockedFn = assert(Ouro.load("return math.abs(-x)", {
			name = "=locked_chain",
			env = lockedEnv,
			compile = { optimizationLevel = 2 },
		}))
		sert.eq(lockedFn(), 55)

		local frozenMt = table.freeze({
			__index = frozenBase,
		})
		local frozenChainEnv = table.freeze(setmetatable({}, frozenMt)) :: any
		local frozenChainFn = assert(Ouro.load("return math.abs(-x)", {
			name = "=frozen_chain",
			env = frozenChainEnv,
			compile = { optimizationLevel = 2 },
		}))
		sert.eq(frozenChainFn(), 55)

		local mts: { any } = {
			table.freeze({}),
			table.freeze({ __index = { math = math } }),
			table.freeze({
				__index = (function()
					return nil
				end) :: any,
			}),
		}
		for _, mt in mts do
			local e = table.freeze(setmetatable({ x = 1 }, mt)) :: any
			local fn = assert(Ouro.load("return x", { name = "=mt_var", env = e }))
			sert.eq(fn(), 1)
		end

		-- DUPCLOSURE non-reuse (changed upval + changed env) & execCall pcall(0) / needsHostWrappers / resourceLimits
		local dupUvFn = assert(Ouro.load(
			[[
			local fns = {}
			for i = 1, 2 do
				local v = i
				fns[i] = function() return v end
			end
			local p = pcall
			local ok0 = pcall(p)
			local okDi, resDi = p(debug.info, 1, "n")
			local okSetEnv = p(function()
				local function g() return 1 end
				setfenv(g, {})
				return g()
			end)
			return fns[1]() + fns[2](), ok0, okDi, type(resDi), okSetEnv
		]],
			{ name = "=dup_uv", compile = { optimizationLevel = 2 } }
		))
		local duSum, duOk0, duOkDi, duType, duSetEnv = dupUvFn()
		sert.eq(duSum, 3)
		sert.eq(duOk0, false)
		sert.eq(duOkDi, true)
		sert.eq(duType, "string")
		sert.eq(duSetEnv, true)

		local pRlFn = assert(Ouro.load(
			[[
			local p = pcall
			return p(string.rep, "a", 10)
		]],
			{
				name = "=p_rl",
				resourceLimits = { maxStringLength = 5 },
				compile = { optimizationLevel = 0 },
			}
		))
		sert.eq(pRlFn(), false)

		-- needsHostWrappers GETIMPORT for debug/coroutine/table + unpack overflow guard
		local wrapImpEnv: { [string]: any } = {
			debug = debug,
			coroutine = coroutine,
			table = table,
			pcall = pcall,
			type = type,
		}
		wrapImpEnv._G = wrapImpEnv
		local wrapImpFn = assert(Ouro.load(
			[[
			local a = type(debug.traceback)
			local b = type(coroutine.create)
			local c = type(table.insert)
			local ok = pcall(function() return (function(...) return ... end)(table.unpack(table.create(20000, 1))) end)
			return a, b, c, ok
		]],
			{ name = "=wrap_imp", env = wrapImpEnv, compile = { optimizationLevel = 2 } }
		))
		local wiA, wiB, wiC, wiOk = wrapImpFn()
		sert.eq(wiA, "function")
		sert.eq(wiB, "function")
		sert.eq(wiC, "function")
		sert.eq(wiOk, false)

		-- Hardened ResourceLimits coercion & constructor guards (env-backed & LoadOptions-backed)
		local hardLimits: Ouro.ResourceLimits = {
			maxStringLength = 10,
			maxTableSize = 4,
			maxBufferSize = 8,
			maxPatternLength = 5,
		}
		local hardEnv = VM.createEnvironment(nil, { resourceLimits = hardLimits })
		local hardCases = {
			{ "table_create_coerce", "return table.create('100', 1)" },
			{ "table_move_coerce", "local t = {1,2,3}; return table.move(t, '1', '3', '10')" },
			{ "table_concat_coerce", "local t = {'a','b','c'}; return table.concat(t, 'xxxx', '1', '3')" },
			{ "buffer_create_coerce", "return buffer.create('100')" },
			{ "buffer_fromstring_num", "return buffer.fromstring(123456789)" },
			{ "buffer_readstring_coerce", "local b = buffer.create(4); return buffer.readstring(b, '0', '99')" },
			{ "find_num_pattern", "return string.find('123456', 123456)" },
			{ "match_num_pattern", "return string.match('123456', 123456)" },
			{ "gsub_num_pattern", "return string.gsub('123456', 123456, 'x')" },
			{ "gsub_num_repl", "return string.gsub('a', 'a', 12345678901)" },
			{ "gmatch_num_pattern", "for m in string.gmatch('123456', 123456) do return m end; return nil" },
			{ "format_prec_overflow", "return string.format('%.50d', 1)" },
			{ "setlist_varargs", "local function mk(...) return {...} end; return mk(1,2,3,4,5)" },
			{ "string_split_fn", "return string.split('a,b,c,d,e', ',')" },
			{ "string_split_method", "local s = 'a,b,c,d,e'; return s:split(',')" },
			{ "os_date_overflow", "return os.date('%c%c')" },
		}
		for _, hc in hardCases do
			local fnEnv = assert(Ouro.load(hc[2], {
				name = "=rl_env_" .. hc[1],
				env = hardEnv,
				compile = { optimizationLevel = 0 },
			}))
			sert.eq(pcall(fnEnv :: any), false, "env resourceLimits should block " .. hc[1])
			local fnOpt = assert(Ouro.load(hc[2], {
				name = "=rl_opt_" .. hc[1],
				resourceLimits = hardLimits,
				compile = { optimizationLevel = 0 },
			}))
			sert.eq(pcall(fnOpt :: any), false, "LoadOptions resourceLimits should block " .. hc[1])
		end
		local validHardFn = assert(Ouro.load(
			[[
			local fmt = string.format("%.20s", "hi")
			local yr = os.date("%Y")
			local sp = string.split("a,b,c", ",")
			local okSetlist = (function(...) return #{...} end)(1, 2, 3, 4)
			return fmt, type(yr), #yr <= 10, #sp, okSetlist
		]],
			{ name = "=rl_valid", env = hardEnv, compile = { optimizationLevel = 2 } }
		))
		local vhFmt, vhYrType, vhYrOk, vhSp, vhSetlist = validHardFn()
		sert.eq(vhFmt, "hi")
		sert.eq(vhYrType, "string")
		sert.eq(vhYrOk, true)
		sert.eq(vhSp, 3)
		sert.eq(vhSetlist, 4)
	end)

	test(
		"enforces exact callLimit, activeThreads unwind, lazy timeout/resetBudget, non-catchable budgets, isolations, and unnamed text traces",
		function()
			local Ouro = require("../")

			-- 1. Exact callLimit boundary & dead coroutine unwinding in activeThreads
			local cl1Ok = assert(Ouro.load("return 42", { callLimit = 1 }))
			sert.eq(cl1Ok(), 42)
			local cl1Fail = assert(
				Ouro.load(
					"local function sub() return 1 end; return sub()",
					{ callLimit = 1, compile = { optimizationLevel = 0 } }
				)
			)
			sert.eq(pcall(cl1Fail :: any), false)
			local cl2Ok = assert(
				Ouro.load(
					"local function sub() return 7 end; return sub()",
					{ callLimit = 2, compile = { optimizationLevel = 0 } }
				)
			)
			sert.eq(cl2Ok(), 7)
			local clCoDead = assert(Ouro.load(
				[[
				local function inner() return 1 end
				local co = coroutine.create(function()
					error("boom")
				end)
				local ok = coroutine.resume(co)
				assert(not ok and coroutine.status(co) == "dead")
				return inner()
			]],
				{ callLimit = 2, compile = { optimizationLevel = 0 } }
			))
			sert.eq(clCoDead(), 1)

			-- 2. Lazy timeout clock & VM.resetBudget clearing startClock
			local lazyFn = assert(Ouro.load("local spin = ...; if spin then while true do end end; return 42", {
				name = "=lazy_timeout",
				timeout = 0.03,
				interruptInterval = 64,
			}))
			local w0 = os.clock()
			while os.clock() - w0 < 0.05 do
			end
			sert.eq(lazyFn(false), 42)
			local tOk, tErr = pcall(lazyFn :: any, true)
			sert.eq(tOk, false)
			expect(string.find(tostring(tErr), "timeout", 1, true) ~= nil, tostring(tErr))
			sert.eq(VM.resetBudget(lazyFn), true)
			local w1 = os.clock()
			while os.clock() - w1 < 0.05 do
			end
			sert.eq(lazyFn(false), 42)

			-- 3. Same-context pcall/xpcall cannot swallow instructionLimit, timeout, or interrupt aborts
			local budgetCases: { { name: string, opts: any } } = {
				{ name = "insn", opts = { instructionLimit = 200, interruptInterval = 32 } :: any },
				{ name = "timeout", opts = { timeout = 0.02, interruptInterval = 64 } :: any },
				{
					name = "interrupt",
					opts = {
						interruptInterval = 32,
						interrupt = function(): boolean?
							return false
						end,
					} :: any,
				},
			}
			for _, tc in budgetCases do
				local pFn = assert(
					Ouro.load("local ok = pcall(function() while true do end end); return ok, 'escaped'", tc.opts)
				)
				sert.eq(pcall(pFn :: any), false, tc.name .. " pcall must not catch")
				local xFn = assert(
					Ouro.load(
						"local ok = xpcall(function() while true do end end, function(e) return e end); return ok, 'escaped'",
						tc.opts
					)
				)
				sert.eq(pcall(xFn :: any), false, tc.name .. " xpcall must not catch")
			end

			-- 4. onCall does not double-fire after pcall recovery
			local callNames: { string } = {}
			local recFn = assert(Ouro.load(
				[[
				local function failInner() error("inner") end
				local function okInner() return 7 end
				local ok = pcall(failInner)
				return ok, okInner()
			]],
				{
					name = "=oncall_recover",
					compile = { debugLevel = 1, optimizationLevel = 0 },
					onCall = function(info)
						table.insert(callNames, info.name or "<main>")
					end,
				}
			))
			local recOk, recVal = recFn()
			sert.eq(recOk, false)
			sert.eq(recVal, 7)
			sert.eq(#callNames, 3)
			sert.eq(callNames[1], "<main>")
			sert.eq(callNames[2], "failInner")
			sert.eq(callNames[3], "okInner")

			-- 5. setfenv updates meta.env without stale local & xpcall error handler inspects snapshot frames
			local fenvSwap = assert(Ouro.load(
				[[
				local before = FLAG
				setfenv(1, { FLAG = 99 })
				return before, FLAG
			]],
				{ name = "=fenv_swap", env = VM.createEnvironment({ FLAG = 11 }) }
			))
			local fb, fa = fenvSwap()
			sert.eq(fb, 11)
			sert.eq(fa, 99)

			local xpSnap = assert(Ouro.load(
				[[
				local function outerC()
					setfenv(1, { MARK = 777, error = error })
					error("snap")
				end
				local function outerVm()
					setfenv(1, { MARK = 888 })
					local x = nil
					return x.k
				end
				local ok1, r1 = xpcall(outerC, function()
					return getfenv(3).MARK
				end)
				local ok2, r2 = xpcall(outerVm, function()
					return getfenv(2).MARK
				end)
				return ok1, r1, ok2, r2
			]],
				{ name = "=xp_snap", compile = { optimizationLevel = 0 } }
			))
			local xOk1, xMark1, xOk2, xMark2 = xpSnap()
			sert.eq(xOk1, false)
			sert.eq(xMark1, 777)
			sert.eq(xOk2, false)
			sert.eq(xMark2, 888)

			-- 6. debug.traceback rejects NaN level
			local nanTb = assert(Ouro.load("return pcall(debug.traceback, 'hi', 0/0)"))
			sert.eq(nanTb(), false)

			-- 7. cloneFunction honors loadOpts.name and throws on unknown LoadOptions keys
			local cloneBase = assert(Ouro.load("error('boom')", { name = "=orig_src" }))
			local clonedNamed = assert(VM.cloneFunction(cloneBase, nil, { name = "=renamed_src" }))
			local _, cloneErr = pcall(clonedNamed :: any)
			expect(string.find(tostring(cloneErr), "^renamed_src:1:") ~= nil, tostring(cloneErr))
			sert.throws(function()
				VM.cloneFunction(cloneBase, nil, { unknownKey = true } :: any)
			end, "unknown load option")

			-- 8. Omitted options.env inside running VM creates fresh isolated env (never inherits outer env)
			local outerEnv = VM.createEnvironment({
				SECRET = 123,
				nestedLoad = function(src: string)
					return Ouro.load(src)
				end,
			})
			local outerCaller = assert(Ouro.load("return assert(nestedLoad('return SECRET'))()", { env = outerEnv }))
			sert.eq(outerCaller(), nil)

			-- 9. Unnamed text chunk runtime errors format using source [string "..."]
			local unnamedRuntime = assert(Ouro.load("error('boom_rt')"))
			local urOk, urErr = pcall(unnamedRuntime :: any)
			sert.eq(urOk, false)
			expect(string.find(tostring(urErr), '^%[string "error%(%S+%)"%]:1:') ~= nil, tostring(urErr))

			-- 10. Mutable ProtoModule isolation & frozen module with non-table proto guard
			local roMod = assert(Ouro.Compiler.compileProto("return 'orig'", { optimizationLevel = 0 }))
			local mp = roMod.protos[roMod.mainid + 1]
			local mutMod: any = {
				version = roMod.version,
				typesversion = roMod.typesversion,
				strings = table.clone(roMod.strings),
				mainid = roMod.mainid,
				protos = {
					{
						id = mp.id,
						maxstacksize = mp.maxstacksize,
						numparams = mp.numparams,
						nups = mp.nups,
						isvararg = mp.isvararg,
						flags = mp.flags,
						code = table.clone(mp.code),
						kTypes = table.clone(mp.kTypes),
						kValues = table.clone(mp.kValues),
						p = table.clone(mp.p),
						linedefined = mp.linedefined,
					},
				},
			}
			local mutLoaded = assert(VM.loadProto(mutMod))
			mutMod.protos[1].kValues[1] = "tampered"
			mutMod.protos[1].code[1] = 0
			sert.eq(mutLoaded(), "orig")

			local badFrozenProtoMod = table.freeze({
				version = 14,
				typesversion = 3,
				strings = table.freeze({}),
				protos = table.freeze({ 123 :: any }),
				mainid = 0,
			})
			sert.eq(select(1, VM.loadProto(badFrozenProtoMod :: any)), nil)

			-- 11. Strict LoadOptions / EnvironmentOptions / ResourceLimits unknown keys and mode="text" on ProtoModule
			sert.throws(function()
				Ouro.load(mutMod, { mode = "text" })
			end, "ProtoModule")
			sert.throws(function()
				VM.createEnvironment(nil, { bogusEnv = true } :: any)
			end, "unknown environment option")
			sert.throws(function()
				VM.createEnvironment(nil, { resourceLimits = { bogusLimit = 1 } :: any })
			end, "unknown resourceLimit")
			sert.throws(function()
				Ouro.load("return 1", { bogusLoad = true } :: any)
			end, "unknown load option")

			-- 12. DUPTABLE seed tiers (20/40/80 keys), 0-arg pcall, guarded CONCAT/GETTABLE, and cross-context 0/2-arg + interrupt calls
			for _, count in { 20, 40, 80 } do
				local entries: { string } = {}
				for i = 1, count do
					entries[i] = `k{i} = {i}`
				end
				local dupFn = assert(Ouro.load(`local t = \{ {table.concat(entries, ", ")} \}; return t.k{count}`))
				sert.eq(dupFn(), count)
			end

			local zeroPcallFn = assert(Ouro.load("local ok = pcall(); return ok"))
			sert.throws(function()
				zeroPcallFn()
			end, "missing argument #1")

			local rlConcatFn = assert(
				Ouro.load(
					"local n = 123456; return n .. 'abcdef'",
					{ resourceLimits = { maxStringLength = 10 }, compile = { optimizationLevel = 0 } }
				)
			)
			sert.eq(pcall(rlConcatFn :: any), false)

			local rlGettableFn = assert(
				Ouro.load(
					"local t = { f = string.rep }; local k = 'f'; return t[k]('x', 20)",
					{ resourceLimits = { maxStringLength = 10 }, compile = { optimizationLevel = 0 } }
				)
			)
			sert.eq(pcall(rlGettableFn :: any), false)

			local sharedCrossEnv = VM.createEnvironment()
			local calleeFresh = assert(Ouro.load("local a, b = ...; return (a or 10) + (b or 20)", {
				env = sharedCrossEnv,
				callLimit = 4,
				compile = { optimizationLevel = 0 },
			}))
			sharedCrossEnv.calleeFresh = calleeFresh
			local callerCross = assert(Ouro.load("return calleeFresh(), calleeFresh(3, 4)", {
				env = sharedCrossEnv,
				callLimit = 4,
				compile = { optimizationLevel = 0 },
			}))
			local c0, c2 = callerCross()
			sert.eq(c0, 30)
			sert.eq(c2, 7)

			local intrCallee = assert(Ouro.load("local s = 0; for i = 1, 10 do s += i end; return s", {
				callLimit = 4,
				interruptInterval = 1,
				interrupt = function(): boolean?
					return false
				end,
			}))
			local intrCaller = assert(Ouro.load("return f()", {
				env = VM.createEnvironment({ f = intrCallee }),
				callLimit = 4,
			}))
			sert.eq(pcall(intrCaller :: any), false)

			-- 13. Guarded dispatch fastcalls, hooks, custom globals, resourceLimits, and predecode Verifier checks
			local guardCalls, guardLines, guardRets = 0, 0, 0
			local guardedSafeFn = assert(Ouro.load(
				[[
					local function vfn(a, b, dynStr, dynNum, dynTbl, ...)
						local sc = select("#", ...)
						local s2 = select(2, ...)
						local b1 = string.byte(dynStr)
						local l1 = string.len(dynStr)
						local sub2 = string.sub(dynStr, a + 1, a + 3)
						local sub1 = string.sub(dynStr, a + 2)
						local n1 = tonumber(dynNum) or 0
						local ts = tostring(dynNum)
						local ty = type(sub2)
						local tof = typeof(dynStr)
						local mLock = {}
						setmetatable(mLock, { __metatable = "locked" })
						local gm = getmetatable(mLock)
						local gmn = getmetatable(dynStr)
						local mUnlock = {}
						setmetatable(mUnlock, { a = 1 })
						setmetatable(mUnlock, nil)
						local arr = table.create(a + 3)
						local arr2 = table.create(a + 2, 1)
						local arr3 = table.create(a + 3)
						table.insert(arr, b1 + l1)
						local xB = bit32.bxor(a + 2, b + 3) + bit32.band(a + 2, b + 3) + bit32.bor(a + 2, b + 3)
							+ bit32.lshift(a + 2, 1) + bit32.rshift(b + 3, 1)
						local mc1 = math.clamp(a + 4, 1, 3)
						local _d = xB + #arr2 + #arr3 - mc1 + 3
						local req = rawequal(arr[1], arr[1])
						local mc = math.clamp(a + 4, 1, 3)
						local ms = math.sign(-(a + 3))
						local mr = math.round(a + 1.6)
						local tObj = { val = 10 }
						function tObj:get()
							return self.val + 3
						end
						function tObj:getN(k)
							return self.val + k
						end
						local tGetter = {
							fn = function()
								return 5
							end,
						}
						local s = 0
						for i = 1, 5 do
							s += i
						end
						for _, v in ipairs({ 2, 4 }) do
							s += v
						end
						for k, v in pairs({ a = 3 }) do
							if k == "a" then
								s += v
							end
						end
						for k, v in pairs({ [math.abs] = 1, fn = math.abs }) do
							if k == math.abs or v == math.abs then
								s += 0
							end
						end
						local pOk, pRes = pcall(function(z)
							return z * 2
						end, 9)
						local pk = table.pack(1, 2)
						return sc
							+ s2
							+ b1
							+ l1
							+ #sub2
							+ #sub1
							+ n1
							+ #ts
							+ #ty
							+ #tof
							+ (if gm == "locked" and gmn == "The metatable is locked" then 1 else 0)
							+ (if getmetatable(mUnlock) == nil then 1 else 0)
							+ arr[1]
							+ (if req then 1 else 0)
							+ mc
							+ ms
							+ mr
							+ tObj:get()
							+ tObj:getN(a) - (a + 10)
							+ tGetter.fn()
							+ s
							+ (if pOk then pRes else 0)
							+ pk.n
							+ (if dynTbl.ok then 0 else 0)
					end
					local function heavyStack(...)
						local a1, a2, a3, a4, a5, a6, a7, a8, a9, a10 = 1, 2, 3, 4, 5, 6, 7, 8, 9, 10
						local b1, b2, b3, b4, b5, b6, b7, b8, b9, b10 = 1, 2, 3, 4, 5, 6, 7, 8, 9, 10
						return a1 + a10 + b1 + b10
					end
					local function leaf(x)
						return x + 1
					end
					local hs = heavyStack() + leaf(4) - 5
					return vfn(1, 2, "AbCdEf", "42", { ok = true }, 30, 40) + hs
				]],
				{
					instructionLimit = 5000000,
					callLimit = 64,
					interruptInterval = 40,
					compile = {
						optimizationLevel = 2,
						flags = { LuauCompileTableBuiltinsCreateClear = true },
					},
					interrupt = function()
						return true
					end,
					onCall = function()
						guardCalls += 1
					end,
					onLine = function()
						guardLines += 1
					end,
					onReturn = function()
						guardRets += 1
					end,
				}
			))
			sert.eq(guardedSafeFn(), 339)
			expect(guardCalls > 0 and guardLines > 0 and guardRets > 0, "guarded hooks fired")

			local gTable: { [string]: any } = {
				extVal = 7,
				gFunc = function()
					return 5
				end,
			}
			local guardedHookFn = assert(Ouro.load(
				[[
					gSet = 11
					local x = _G.gFunc()
					local d1, d2 = 3, 5
					local y = bit32.bxor(d1, d2)
					return x + y + (extVal or 0)
				]],
				{
					instructionLimit = 5000000,
					resourceLimits = { maxStringLength = 10000, maxTableSize = 1000 },
					getGlobal = function(k: string, envTbl: { [any]: any })
						return if gTable[k] ~= nil then gTable[k] else envTbl[k]
					end,
					setGlobal = function(k: string, val: any, _envTbl: { [any]: any })
						gTable[k] = val
					end,
				}
			))
			sert.eq(guardedHookFn(), 18)
			sert.eq(gTable.gSet, 11)

			local rawMtEnv1: { [string]: any } = { bit32 = bit32, setmetatable = setmetatable }
			rawMtEnv1._G = rawMtEnv1
			local guardedEnvMtFn = assert(Ouro.load(
				[[
					local x, y = ...
					local b = bit32.bxor(x, y) + bit32.band(x, y) + bit32.bor(x, y)
					local mt = { a = 1 }
					setmetatable(_G, mt)
					setmetatable(_G, nil)
					return b
				]],
				{
					env = rawMtEnv1,
					safeEnv = true,
					instructionLimit = 5000000,
				}
			))
			sert.eq(guardedEnvMtFn(3, 5), 14)

			local rawMtEnv2: { [string]: any } = { setmetatable = setmetatable }
			rawMtEnv2._G = rawMtEnv2
			local guardedEnvMtExprFn = assert(Ouro.load(
				[[
					local mt = { a = 1 }
					local r = setmetatable(_G, mt)
					return r == _G
				]],
				{
					env = rawMtEnv2,
					safeEnv = true,
					instructionLimit = 5000000,
				}
			))
			sert.eq(guardedEnvMtExprFn(), true)

			local safeUnboundedExtra = assert(Ouro.load([[
				local mLock = {}
				setmetatable(mLock, { __metatable = "locked" })
				local mUnlock = {}
				setmetatable(mUnlock, { a = 1 })
				setmetatable(mUnlock, nil)
				local function small(n)
					return n + 1
				end
				local function bigRec(n)
					local a1, a2, a3, a4, a5, a6, a7, a8, a9, a10 = 1, 2, 3, 4, 5, 6, 7, 8, 9, 10
					local b1, b2, b3, b4, b5, b6, b7, b8, b9, b10 = 1, 2, 3, 4, 5, 6, 7, 8, 9, n
					if n <= 0 then
						return a1 + a10 + b1 + b10
					end
					return bigRec(n - 1) + (b9 - b9)
				end
				local function openPcall()
					local function ret2(x)
						return x, x + 1
					end
					return pcall(ret2, 4)
				end
				local s1 = small(1)
				local b1 = bigRec(2)
				local okO, ox, oy = openPcall()
				return s1 + b1 + (if okO then ox + oy else 0) + (if getmetatable(mLock) == "locked" and getmetatable(mUnlock) == nil then 1 else 0)
			]]))
			sert.eq(safeUnboundedExtra(), 24)

			local guardedTarget = assert(Ouro.load("return function(x) return x + 1 end", {
				instructionLimit = 5000000,
			}))()
			local unguardedCaller = assert(Ouro.load("return gCallee(9)", {
				env = VM.createEnvironment({ gCallee = guardedTarget }),
			}))
			sert.eq(unguardedCaller(), 10)

			local sameLimFn =
				assert(Ouro.load("local function r(n) return if n <= 0 then 1 else r(n - 1) end return r(5)", {
					callLimit = 3,
				}))
			sert.throws(function()
				sameLimFn()
			end, "call stack overflow")

			-- Fastcalls statement-form fallbacks, out-of-range select, and resourceLimit string.pack/gsub
			local fcFallback = assert(Ouro.load(
				[[
					local function run(s, n, ...)
						math.clamp(n, 1, 3)
						typeof(s)
						string.len(s)
						string.byte(s, n)
						string.sub(s, n)
						table.create(n)
						rawequal(n, n)
						local v = select(5, ...)
						return if v == nil then 1 else 0
					end
					return run("ABCD", 2, 10, 20)
				]],
				{
					compile = {
						optimizationLevel = 2,
						flags = { LuauCompileTableBuiltinsCreateClear = true },
					},
				}
			))
			sert.eq(fcFallback(), 1)

			local rlStringFn = assert(Ouro.load(
				[[
					local g1 = string.gsub("aaaa", "a", "b", 2)
					local g2 = string.gsub("aaaa", "a", "b", 0)
					local pk = string.pack("c10", "abcdefghij")
					return #g1 + #g2 + #pk
				]],
				{
					resourceLimits = { maxStringLength = 50 },
				}
			))
			sert.eq(rlStringFn(), 18)

			local pcallCrossFn = assert(Ouro.load("local ok, r = pcall(gCallee, 9); return if ok then r else 0", {
				env = VM.createEnvironment({ gCallee = guardedTarget }),
			}))
			sert.eq(pcallCrossFn(), 10)

			local unboundFallbackFn = assert(Ouro.load(
				[[
				local mLock = {}
				setmetatable(mLock, { __metatable = "locked" })
				local mUnlock = {}
				setmetatable(mUnlock, { a = 1 })
				setmetatable(mUnlock, nil)
				local function heavy(z)
					local x1, x2, x3, x4, x5, x6, x7, x8, x9, x10 = 1, 2, 3, 4, 5, 6, 7, 8, 9, 10
					local y1, y2, y3, y4, y5, y6, y7, y8, y9, y10 = 1, 2, 3, 4, 5, 6, 7, 8, 9, z
					return x1 + x10 + y1 + y10
				end
				local function mf(a, b, s1, s2, n1, ...)
					local c1, _c2 = math.clamp(n1, 1, 3)
					local t1, _t2 = typeof(a)
					local l1, _l2 = string.len(s1)
					local sb1, _sb2 = string.byte(s2, 2)
					local b1, b2 = string.byte(s1, 1, 2)
					local ss1, _ss2 = string.sub(s1, 2)
					local arrC, _arrC2 = table.create(n1 - 1)
					local _ins = (table.insert :: any)(arrC, 1)
					local sv1, _sv2 = select("#", ...)
					local okS, x, y = pcall(function(...)
						return select(1, ...)
					end, ...)
					local sub1 = string.sub(s1, 2)
					return c1 + #t1 + l1 + sb1 + b1 + b2 + #ss1 + #arrC + sv1 + (if okS then x + y else 0) + #sub1
				end
				local _gFn = _G.extCall()
				return mf(1, 2, "ABCD", "XYZ", 5, 10, 20) + heavy(5) + _gFn + (if getmetatable(mLock) == "locked" and getmetatable(mUnlock) == nil then 1 else 0)
			]],
				{
					compile = {
						optimizationLevel = 2,
						flags = { LuauCompileTableBuiltinsCreateClear = true },
					},
					getGlobal = function(k: string, envTbl: { [any]: any })
						if k == "extCall" then
							return function()
								return 9
							end
						end
						return envTbl[k]
					end,
				}
			))
			sert.eq(unboundFallbackFn(), 299)

			-- Guarded cross-context & same-context callLimit overflow + interrupt inside loops/branches
			local limCallee =
				assert(Ouro.load("local function r(n) if n <= 0 then return 1 end return r(n - 1) end return r(5)", {
					callLimit = 3,
				}))
			local limCaller = assert(Ouro.load("return callee()", {
				env = VM.createEnvironment({ callee = limCallee }),
				callLimit = 2,
			}))
			sert.eq(pcall(limCaller :: any), false)

			local intrLoopFn = assert(Ouro.load(
				[[
					local s = 0
					for i = 1, 200 do
						local flag = (i % 2 == 0)
						if flag then
							s += math.abs(-i)
						end
						if not flag then
							s += 0
						end
						if i % 3 ~= 0 then
							s += 1
						end
					end
					for i, v in ipairs({ 1, 2, 3, 4, 5 }) do
						s += i * v
					end
					for k, v in pairs({ a = 1, b = 2, c = 3 }) do
						if k ~= "" then s += v end
					end
					return s
				]],
				{
					instructionLimit = 5000000,
					interruptInterval = 3,
					interrupt = function()
						return true
					end,
				}
			))
			sert.eq(intrLoopFn(), 10295)

			local function abc(op: number, a: number, b: number, c: number): number
				return bit32.bor(op, bit32.lshift(a, 8), bit32.lshift(b, 16), bit32.lshift(c, 24))
			end
			local function ad(op: number, a: number, d: number): number
				return bit32.bor(op, bit32.lshift(a, 8), bit32.lshift(bit32.band(d, 0xffff), 16))
			end
			local ret1 = abc(Opcodes.LOP_RETURN, 0, 1, 0)
			local badPredecode: {
				{
					code: { number },
					kT: { number }?,
					kV: { any }?,
					ms: number,
					nups: number?,
					child: { nups: number }?,
					p: { number }?,
				}
			} =
				{
					{
						code = { abc(Opcodes.LOP_LOADKX, 5, 0, 0), 0, ret1 },
						kT = { Tags.LBC_CONSTANT_NUMBER },
						kV = { 1 },
						ms = 2,
					},
					{
						code = { abc(Opcodes.LOP_LOADKX, 0, 0, 0), 5, ret1 },
						kT = { Tags.LBC_CONSTANT_NUMBER },
						kV = { 1 },
						ms = 2,
					},
					{
						code = { abc(Opcodes.LOP_LOADKX, 0, 0, 0), 0, ret1 },
						kT = { Tags.LBC_CONSTANT_IMPORT },
						kV = { 1 },
						ms = 2,
					},
					{ code = { abc(Opcodes.LOP_GETUPVAL, 5, 0, 0), ret1 }, ms = 2, nups = 1 },
					{ code = { abc(Opcodes.LOP_GETUPVAL, 0, 5, 0), ret1 }, ms = 2, nups = 0 },
					{ code = { abc(Opcodes.LOP_ADD, 5, 0, 0), ret1 }, ms = 2 },
					{ code = { abc(Opcodes.LOP_CONCAT, 0, 2, 1), ret1 }, ms = 4 },
					{
						code = { abc(Opcodes.LOP_GETTABLEKS, 5, 0, 0), 0, ret1 },
						kT = { Tags.LBC_CONSTANT_STRING },
						kV = { "k" },
						ms = 2,
					},
					{
						code = { abc(Opcodes.LOP_GETTABLEKS, 0, 0, 0), 5, ret1 },
						kT = { Tags.LBC_CONSTANT_STRING },
						kV = { "k" },
						ms = 2,
					},
					{
						code = { abc(Opcodes.LOP_GETTABLEKS, 0, 0, 0), 0, ret1 },
						kT = { Tags.LBC_CONSTANT_NUMBER },
						kV = { 1 },
						ms = 2,
					},
					{
						code = { abc(Opcodes.LOP_SETTABLEKS, 5, 0, 0), 0, ret1 },
						kT = { Tags.LBC_CONSTANT_STRING },
						kV = { "k" },
						ms = 2,
					},
					{
						code = { abc(Opcodes.LOP_SETTABLEKS, 0, 0, 0), 5, ret1 },
						kT = { Tags.LBC_CONSTANT_STRING },
						kV = { "k" },
						ms = 2,
					},
					{
						code = { abc(Opcodes.LOP_SETTABLEKS, 0, 0, 0), 0, ret1 },
						kT = { Tags.LBC_CONSTANT_NUMBER },
						kV = { 1 },
						ms = 2,
					},
					{
						code = { abc(Opcodes.LOP_GETUDATAKS, 5, 0, 0), 0, ret1 },
						kT = { Tags.LBC_CONSTANT_STRING },
						kV = { "k" },
						ms = 2,
					},
					{
						code = { abc(Opcodes.LOP_GETUDATAKS, 0, 0, 0), 5, ret1 },
						kT = { Tags.LBC_CONSTANT_STRING },
						kV = { "k" },
						ms = 2,
					},
					{
						code = { abc(Opcodes.LOP_GETUDATAKS, 0, 0, 0), 0, ret1 },
						kT = { Tags.LBC_CONSTANT_NUMBER },
						kV = { 1 },
						ms = 2,
					},
					{
						code = { abc(Opcodes.LOP_SETUDATAKS, 5, 0, 0), 0, ret1 },
						kT = { Tags.LBC_CONSTANT_STRING },
						kV = { "k" },
						ms = 2,
					},
					{
						code = { abc(Opcodes.LOP_SETUDATAKS, 0, 0, 0), 5, ret1 },
						kT = { Tags.LBC_CONSTANT_STRING },
						kV = { "k" },
						ms = 2,
					},
					{
						code = { abc(Opcodes.LOP_SETUDATAKS, 0, 0, 0), 0, ret1 },
						kT = { Tags.LBC_CONSTANT_NUMBER },
						kV = { 1 },
						ms = 2,
					},
					{
						code = { abc(Opcodes.LOP_NAMECALL, 1, 0, 0), 0, ret1 },
						kT = { Tags.LBC_CONSTANT_STRING },
						kV = { "k" },
						ms = 2,
					},
					{
						code = { abc(Opcodes.LOP_NAMECALL, 0, 0, 0), 5, ret1 },
						kT = { Tags.LBC_CONSTANT_STRING },
						kV = { "k" },
						ms = 2,
					},
					{
						code = { abc(Opcodes.LOP_NAMECALL, 0, 0, 0), 0, ret1 },
						kT = { Tags.LBC_CONSTANT_NUMBER },
						kV = { 1 },
						ms = 2,
					},
					{
						code = { abc(Opcodes.LOP_NAMECALLUDATA, 1, 0, 0), 0, ret1 },
						kT = { Tags.LBC_CONSTANT_STRING },
						kV = { "k" },
						ms = 2,
					},
					{
						code = { abc(Opcodes.LOP_NAMECALLUDATA, 0, 0, 0), 5, ret1 },
						kT = { Tags.LBC_CONSTANT_STRING },
						kV = { "k" },
						ms = 2,
					},
					{
						code = { abc(Opcodes.LOP_NAMECALLUDATA, 0, 0, 0), 0, ret1 },
						kT = { Tags.LBC_CONSTANT_NUMBER },
						kV = { 1 },
						ms = 2,
					},
					{
						code = { abc(Opcodes.LOP_JUMPXEQKN, 5, 0, 0), 0, ret1 },
						kT = { Tags.LBC_CONSTANT_NUMBER },
						kV = { 1 },
						ms = 2,
					},
					{
						code = { abc(Opcodes.LOP_JUMPXEQKN, 0, 0, 0), 5, ret1 },
						kT = { Tags.LBC_CONSTANT_NUMBER },
						kV = { 1 },
						ms = 2,
					},
					{
						code = { abc(Opcodes.LOP_JUMPXEQKN, 0, 0, 0), 0, ret1 },
						kT = { Tags.LBC_CONSTANT_STRING },
						kV = { "x" },
						ms = 2,
					},
					{
						code = { abc(Opcodes.LOP_JUMPXEQKS, 5, 0, 0), 0, ret1 },
						kT = { Tags.LBC_CONSTANT_STRING },
						kV = { "x" },
						ms = 2,
					},
					{
						code = { abc(Opcodes.LOP_JUMPXEQKS, 0, 0, 0), 5, ret1 },
						kT = { Tags.LBC_CONSTANT_STRING },
						kV = { "x" },
						ms = 2,
					},
					{
						code = { abc(Opcodes.LOP_JUMPXEQKS, 0, 0, 0), 0, ret1 },
						kT = { Tags.LBC_CONSTANT_NUMBER },
						kV = { 1 },
						ms = 2,
					},
					{
						code = { ad(Opcodes.LOP_DUPCLOSURE, 5, 0), ret1 },
						kT = { Tags.LBC_CONSTANT_CLOSURE },
						kV = { 1 },
						ms = 2,
						child = { nups = 0 },
					},
					{
						code = { ad(Opcodes.LOP_DUPCLOSURE, 0, 5), ret1 },
						kT = { Tags.LBC_CONSTANT_CLOSURE },
						kV = { 1 },
						ms = 2,
						child = { nups = 0 },
					},
					{
						code = { ad(Opcodes.LOP_DUPCLOSURE, 0, 0), ret1 },
						kT = { Tags.LBC_CONSTANT_NUMBER },
						kV = { 1 },
						ms = 2,
					},
					{
						code = { ad(Opcodes.LOP_DUPCLOSURE, 0, 0), ret1 },
						kT = { Tags.LBC_CONSTANT_CLOSURE },
						kV = { 1 },
						ms = 2,
						child = { nups = 2 },
					},
					{
						code = { ad(Opcodes.LOP_DUPCLOSURE, 0, 0), ret1, ret1 },
						kT = { Tags.LBC_CONSTANT_CLOSURE },
						kV = { 1 },
						ms = 2,
						child = { nups = 1 },
					},
					{
						code = { ad(Opcodes.LOP_DUPCLOSURE, 0, 0), abc(Opcodes.LOP_CAPTURE, 1, 0, 0), ret1 },
						kT = { Tags.LBC_CONSTANT_CLOSURE },
						kV = { 1 },
						ms = 2,
						child = { nups = 1 },
					},
					{
						code = { ad(Opcodes.LOP_DUPCLOSURE, 0, 0), abc(Opcodes.LOP_CAPTURE, 0, 9, 0), ret1 },
						kT = { Tags.LBC_CONSTANT_CLOSURE },
						kV = { 1 },
						ms = 2,
						child = { nups = 1 },
					},
					{
						code = { ad(Opcodes.LOP_DUPCLOSURE, 0, 0), abc(Opcodes.LOP_CAPTURE, 2, 9, 0), ret1 },
						kT = { Tags.LBC_CONSTANT_CLOSURE },
						kV = { 1 },
						ms = 2,
						child = { nups = 1 },
					},
					{
						code = { ad(Opcodes.LOP_DUPCLOSURE, 0, 0), abc(Opcodes.LOP_CAPTURE, 7, 0, 0), ret1 },
						kT = { Tags.LBC_CONSTANT_CLOSURE },
						kV = { 1 },
						ms = 2,
						child = { nups = 1 },
					},
					{ code = { abc(Opcodes.LOP_RETURN, 5, 0, 0) }, ms = 2 },
					{ code = { abc(Opcodes.LOP_RETURN, 1, 3, 0) }, ms = 2 },
					{
						code = { ad(Opcodes.LOP_NEWCLOSURE, 0, 0), abc(Opcodes.LOP_CAPTURE, 2, 9, 0), ret1 },
						ms = 2,
						nups = 0,
						p = { 1 },
						child = { nups = 1 },
					},
					{
						code = { ad(Opcodes.LOP_NEWCLOSURE, 0, 0), abc(Opcodes.LOP_CAPTURE, 7, 0, 0), ret1 },
						ms = 2,
						nups = 0,
						p = { 1 },
						child = { nups = 1 },
					},
					{
						code = { abc(Opcodes.LOP_LOADKX, 0, 0, 0), 0, ret1 },
						kT = { Tags.LBC_CONSTANT_CLOSURE },
						kV = { 0 },
						ms = 2,
					},
					{ code = { ad(Opcodes.LOP_JUMP, 0, 1), abc(Opcodes.LOP_GETGLOBAL, 0, 0, 0), 0, ret1 }, ms = 2 },
					{ code = { abc(Opcodes.LOP_SETLIST, 0, 9, 0), 1, ret1 }, ms = 2 },
				}
			for idx, spec in badPredecode do
				local protos = {
					{
						id = 0,
						maxstacksize = spec.ms,
						numparams = 0,
						nups = spec.nups or 0,
						isvararg = false,
						flags = 0,
						code = spec.code,
						kTypes = spec.kT or {},
						kValues = spec.kV or {},
						p = spec.p or {},
						linedefined = 0,
					},
				}
				if spec.child then
					protos[2] = {
						id = 1,
						maxstacksize = 1,
						numparams = 0,
						nups = spec.child.nups,
						isvararg = false,
						flags = 0,
						code = { ret1 },
						kTypes = {},
						kValues = {},
						p = {},
						linedefined = 0,
					}
				end
				local badMod: any = {
					version = 14,
					typesversion = 3,
					strings = {},
					protos = protos :: any,
					mainid = 0,
				}
				local fnBad, errBad = VM.loadProto(badMod)
				sert.eq(fnBad, nil, `badPredecode #{idx}`)
				expect(errBad ~= nil, `badPredecode err #{idx}`)
				local badBin = BytecodeCodec.serialize(badMod)
				if badBin ~= nil then
					local fnBin, errBin = VM.loadBytecode(badBin)
					sert.eq(fnBin, nil, `badPredecode bin #{idx}`)
					expect(errBin ~= nil, `badPredecode bin err #{idx}`)
				end
			end
		end
	)
end)

if not sert._bundled then
	return sert.run(sert.parseCliArgs(...))
end
return nil
