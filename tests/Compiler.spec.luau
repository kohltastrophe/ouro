--!strict
local BytecodeBuilder = require("../src/BytecodeBuilder")
local BytecodeCodec = require("../src/BytecodeCodec")
local BytecodeDefs = require("../src/BytecodeDefs")
local BytecodeDisassembler = require("../src/BytecodeDisassembler")
local Compiler = require("../src/Compiler")
local CompilerBuiltins = require("../src/CompilerBuiltins")
local Helpers = require("./Helpers")
local Parser = require("../")
local PublicTypes = require("../src/Types")
local VM = require("../src/VM")
local sert = require("@sert") :: any

local describe = sert.describe
local test = sert.test
local expect = sert
local gen = sert.gen
local laws = sert.laws

local Opcodes = BytecodeDefs.Opcodes
local Builtins = BytecodeDefs.Builtins
local ProtoFlags = BytecodeDefs.ProtoFlags
local BytecodeTypes = BytecodeDefs.Types

local function numEq(a: any, b: any): boolean
	if type(a) == "number" and type(b) == "number" then
		if a ~= a and b ~= b then
			return true
		end
		if a == 0 and b == 0 then
			return (1 / a) == (1 / b)
		end
		if a == b then
			return true
		end
		return math.abs(a - b) <= 1e-9 * math.max(1, math.abs(a), math.abs(b))
	end
	return a == b
end

local function disassemble(source: string, opts: Compiler.CompileOptions?): (string, Compiler.CompileResult)
	local options: Compiler.CompileOptions = if opts then table.clone(opts) else {}
	options.dumpFlags = bit32.bor(
		options.dumpFlags or 0,
		BytecodeBuilder.DumpFlags.Code,
		BytecodeBuilder.DumpFlags.Lines,
		BytecodeBuilder.DumpFlags.Locals,
		BytecodeBuilder.DumpFlags.Remarks,
		BytecodeBuilder.DumpFlags.Types
	)
	local res = Compiler.compileResult(source, options)
	assert(res.status == "ok", res.error or "compile failed")
	local builder = assert(res.builder, "missing builder")
	return builder:dumpEverything(), res
end

describe("Compiler", function()
	test("folds arithmetic, string, and table constants at O1 and builtin calls at O2", function()
		local dumpO1 = disassemble(
			[[
			local a = (10 + 20) * 3 - 6
			local s = "hello" .. " " .. "world"
			return a, #s
		]],
			{ optimizationLevel = 1 }
		)
		expect(string.find(dumpO1, "LOADN R0 84", 1, true) ~= nil, "folded (10+20)*3-6 -> 84")
		expect(string.find(dumpO1, "LOADN R1 11", 1, true) ~= nil, "folded #'hello world' -> 11")

		local dumpO2, resO2 = disassemble(
			[[
			local a = math.floor(3.9) + math.abs(-10)
			local b = bit32.band(0xff, 0x0f) + bit32.extract(0b101100, 2, 3)
			local c = string.byte("ABC", 2)
			local t = { x = 42, ["y"] = 8 }
			return a, b, c, t.x, t["y"]
		]],
			{ optimizationLevel = 2 }
		)
		expect(string.find(dumpO2, "LOADN R%d+ 13\n") ~= nil, "folded math.floor + math.abs at O2 -> 13")
		expect(string.find(dumpO2, "LOADN R%d+ 18\n") ~= nil, "folded bit32.band + bit32.extract at O2 -> 18")
		expect(string.find(dumpO2, "LOADN R%d+ 66\n") ~= nil, "folded string.byte at O2 -> 66")
		expect(string.find(dumpO2, "LOADN R%d+ 42\n") ~= nil, "folded constant table field t.x at O2 -> 42")
		expect(string.find(dumpO2, "LOADN R%d+ 8\n") ~= nil, "folded constant table string key t['y'] at O2 -> 8")
		expect(string.find(dumpO2, "FASTCALL", 1, true) == nil, "no FASTCALL on folded O2 chunk")
		expect(string.find(dumpO2, "CALL ", 1, true) == nil, "no CALL on folded O2 chunk")
		local fnO2 = assert(VM.loadBytecode(resO2.bytecode, { name = "=fold_o2" }))
		local f1, f2, f3, f4, f5 = fnO2()
		sert.eq(f1, 13)
		sert.eq(f2, 18)
		sert.eq(f3, 66)
		sert.eq(f4, 42)
		sert.eq(f5, 8)
	end)

	test("emits FASTCALL1, FASTCALL2, FASTCALL2K, FASTCALL3, and specialized BIT32_EXTRACTK / SELECT_VARARG", function()
		local dump = disassemble(
			[[
			local function f(x, y, z, ...)
				local a = math.abs(x)
				local b = math.min(x, y)
				local c = bit32.lshift(x, 4)
				local d = math.clamp(x, y, z)
				local e = bit32.extract(x, 4, 8)
				local n = select("#", ...)
				return a + b + c + d + e + n
			end
			return f
		]],
			{ optimizationLevel = 1 }
		)
		expect(string.find(dump, "FASTCALL1", 1, true) ~= nil, "emits FASTCALL1 for math.abs(x)")
		expect(string.find(dump, "FASTCALL2 ", 1, true) ~= nil, "emits FASTCALL2 for math.min(x, y)")
		expect(string.find(dump, "FASTCALL2K", 1, true) ~= nil, "emits FASTCALL2K for bit32.lshift(x, 4)")
		expect(string.find(dump, "FASTCALL3", 1, true) ~= nil, "emits FASTCALL3 for math.clamp(x, y, z)")
		expect(
			string.find(dump, "FASTCALL2K " .. tostring(Builtins.LBF_BIT32_EXTRACTK), 1, true) ~= nil,
			"emits LBF_BIT32_EXTRACTK for constant field/width"
		)
		expect(
			string.find(dump, "FASTCALL1 " .. tostring(Builtins.LBF_SELECT_VARARG), 1, true) ~= nil,
			"emits LBF_SELECT_VARARG for select('#', ...)"
		)
	end)

	test("respects mutableGlobals and disabledBuiltins options", function()
		local dumpMutable = disassemble(
			[[
			return math.abs(x)
		]],
			{
				optimizationLevel = 1,
				mutableGlobals = { "math" },
			}
		)
		expect(string.find(dumpMutable, "FASTCALL", 1, true) == nil, "mutableGlobals suppresses fastcall")
		expect(string.find(dumpMutable, "[math.abs]", 1, true) == nil, "mutableGlobals suppresses 2-level GETIMPORT")
		expect(string.find(dumpMutable, "GETTABLEKS", 1, true) ~= nil, "mutableGlobals emits dynamic GETTABLEKS")

		local dumpDisabled = disassemble(
			[[
			return math.abs(x)
		]],
			{
				optimizationLevel = 1,
				disabledBuiltins = { "math.abs" },
			}
		)
		expect(string.find(dumpDisabled, "FASTCALL", 1, true) == nil, "disabledBuiltins suppresses math.abs fastcall")
		expect(string.find(dumpDisabled, "GETIMPORT", 1, true) ~= nil, "still emits GETIMPORT for non-mutable math.abs")
	end)

	test("inlines small functions and unrolls constant-trip-count loops at O2", function()
		local dump = disassemble(
			[[
			local function square(v: number): number
				return v * v
			end

			local sum = 0
			for i = 1, 4 do
				sum += square(i)
			end
			return sum
		]],
			{ optimizationLevel = 2 }
		)
		expect(string.find(dump, "inlining succeeded", 1, true) ~= nil, "inlined square(i) at O2")
		expect(string.find(dump, "loop unroll succeeded", 1, true) ~= nil, "unrolled 1..4 loop at O2")
		expect(string.find(dump, "FORNLOOP", 1, true) == nil, "no FORNLOOP after unrolling")
	end)

	test("predicts table shapes from subsequent field and array assignments", function()
		local _, res = disassemble(
			[[
			local t = {}
			t.a = 1
			t.b = 2
			t[1] = 10
			t[2] = 20
			return t
		]],
			{ optimizationLevel = 1 }
		)
		local protoModule = assert(res.builder, "missing builder"):toProtoModule()
		local mainProto = protoModule.protos[protoModule.mainid + 1]
		local hasNewTableWithPrediction = false
		for idx, insn in mainProto.code do
			if BytecodeCodec.insnOp(insn) == Opcodes.LOP_NEWTABLE then
				local hashLog2 = BytecodeCodec.insnB(insn)
				local arraySize = mainProto.code[idx + 1]
				if hashLog2 > 0 and arraySize == 2 then
					hasNewTableWithPrediction = true
				end
			end
		end
		expect(hasNewTableWithPrediction, "predicted 2 hash keys and 2 array elements on NEWTABLE")
	end)

	test("emits type info, debug locals/upvalues, coverage, and native proto flags", function()
		local _, res = disassemble(
			[[
			--!native
			local up = 10
			@native
			local function compute(a: number, b: string?): number
				local c: boolean = a > 0
				if c and b then
					return a + up
				end
				return 0
			end
			up += 1
			return compute
		]],
			{
				optimizationLevel = 2,
				debugLevel = 2,
				typeInfoLevel = 1,
				coverageLevel = 2,
			}
		)
		local mod = assert(res.builder, "missing builder"):toProtoModule()
		local mainProto = mod.protos[mod.mainid + 1]
		expect(bit32.band(mainProto.flags, ProtoFlags.LPF_NATIVE_MODULE) ~= 0, "sets LPF_NATIVE_MODULE from --!native")

		local childProto = mod.protos[1]
		expect(bit32.band(childProto.flags, ProtoFlags.LPF_NATIVE_FUNCTION) ~= 0, "sets LPF_NATIVE_FUNCTION")
		expect(childProto.typeinfo ~= nil and #childProto.typeinfo > 0, "emits binary function typeinfo")
		expect(childProto.locvars ~= nil and #childProto.locvars >= 3, "emits debug local variables at debugLevel=2")
		expect(childProto.upvalues ~= nil and childProto.upvalues[1] == "up", "emits debug upvalue names")

		local hasCoverage = false
		for _, insn in childProto.code do
			if BytecodeCodec.insnOp(insn) == Opcodes.LOP_COVERAGE then
				hasCoverage = true
				break
			end
		end
		expect(hasCoverage, "emits LOP_COVERAGE instructions when coverageLevel >= 1")
	end)

	test("returns formatted error bytecode on syntax errors and semantic compile errors", function()
		local syntaxBc, syntaxTupleErr = Parser.compile("local x =")
		sert.eq(syntaxBc, nil)
		expect(string.find(assert(syntaxTupleErr), ":1:", 1, true) ~= nil, "syntax error includes line number")
		local wireErrBc = BytecodeCodec.encodeError(assert(syntaxTupleErr))
		sert.eq(string.byte(wireErrBc, 1), 0)
		expect(string.find(wireErrBc, ":1:", 1, true) ~= nil, "wire error includes line number")

		-- Jumping over a local declared in repeat..until condition scope via continue
		local contErrRes = Parser.compileResult([[
			repeat
				if true then
					continue
				end
				local x = 10
			until x == 10
		]])
		sert.eq(contErrRes.status, "compileError")
		sert.eq(string.byte(contErrRes.bytecode, 1), 0)
		expect(
			string.find(contErrRes.error or "", "Local x used in the repeat..until condition", 1, true) ~= nil,
			"reports continue-until local error"
		)

		sert.eq(CompilerBuiltins.getBuiltinFunctionId({ object = "math", method = "abs" }, {}), Builtins.LBF_MATH_ABS)
		sert.eq(
			CompilerBuiltins.getBuiltinFunctionId(
				{ object = "math", method = "not_a_builtin" },
				{ disabledBuiltins = { "abs" } }
			),
			Builtins.LBF_NONE
		)
		sert.eq(CompilerBuiltins.getBuiltinInfo(Builtins.LBF_MATH_ABS).params, 1)

		local repeatDump = disassemble(
			[[
			local a = 1
			local b = 2
			local function f()
				repeat
					local t = {}
					print(a)
				until (function()
					t.x = b
					return b == 2
				end)()
			end
			return f
		]],
			{ optimizationLevel = 2, debugLevel = 2 }
		)
		expect(
			string.find(repeatDump, "allocation: table hash 1", 1, true) ~= nil,
			"predicts table shape across repeat body and until condition"
		)
	end)

	sert.prop("compiles and executes generated arithmetic expressions at O0, O1, and O2", function(g)
		local terms: { number } = g:draw(gen.list(gen.int(-50, 50), 2, 8))
		local parts = table.create(#terms)
		local expectedSum = 0
		for i, n in terms do
			parts[i] = string.format("local v%d = %d", i, n)
			expectedSum += n
		end
		local sumExpr = table.create(#terms)
		for i = 1, #terms do
			sumExpr[i] = "v" .. tostring(i)
		end
		local src = table.concat(parts, "\n") .. "\nreturn " .. table.concat(sumExpr, " + ")
		for _, opt in { 0, 1, 2 } do
			local bc = assert(Parser.compile(src, { optimizationLevel = opt }))
			expect(string.byte(bc, 1) ~= 0, "compiled without error")
			local mod = assert(BytecodeCodec.deserialize(bc))
			expect(#mod.protos == 1, "single main proto")
			local fn = assert(VM.loadProto(mod, { name = "=arith" }))
			sert.eq(fn(), expectedSum)
		end
	end, { runs = 30 })

	laws.codec("compiler bytecode determinism and ProtoModule round-trip", {
		gen = function(g: any)
			local a = gen.boundaryInt(-10000, 10000)(g)
			local b = gen.boundaryInt(-10000, 10000)(g)
			local c = gen.boundaryInt(1, 500)(g)
			local opt: number = g:pick({ 0, 1, 2 })
			local opIdx: number = g:int(1, 5)
			local ops = { "+", "-", "*", "//", "%" }
			local op = ops[opIdx]
			local src =
				`local a, b, c = {a}, {b}, {c}; local function f(x) return (x {op} a) + b - c end; return f({a}), "{op}", {opt}, {a}, {b}, {c}`
			return { src = src, opt = opt, a = a }
		end,
		encode = function(spec)
			return assert(Parser.compile(spec.src, {
				optimizationLevel = spec.opt,
				debugLevel = 2,
				typeInfoLevel = 1,
			}))
		end,
		decode = function(bc: string)
			local mod = assert(BytecodeCodec.deserialize(bc))
			local fn = assert(Parser.load(mod, { name = "=codec" }))
			local fnRes, op, opt, aVal, bVal, cVal = fn()
			local lhs = if op == "+"
				then aVal + aVal
				elseif op == "-" then aVal - aVal
				elseif op == "*" then aVal * aVal
				elseif op == "//" then (if aVal == 0 then 0 / 0 else aVal // aVal)
				else (if aVal == 0 then 0 / 0 else aVal % aVal)
			local expected = lhs + bVal - cVal
			expect(numEq(fnRes, expected), `codec fn({aVal}) {op} result`)
			local src =
				`local a, b, c = {aVal}, {bVal}, {cVal}; local function f(x) return (x {op} a) + b - c end; return f({aVal}), "{op}", {opt}, {aVal}, {bVal}, {cVal}`
			return { src = src, opt = opt, a = aVal }
		end,
		eq = function(x, y)
			return x.src == y.src and x.opt == y.opt and x.a == y.a
		end,
	}, { runs = 60 })

	laws.differential("O2 constant folding vs O0 runtime evaluation on boundaryInt and boundaryFloat", {
		gen = function(g)
			local i1 = gen.boundaryInt(-10000, 10000)(g)
			local i2 = gen.boundaryInt(1, 1000)(g)
			local f1 = gen.boundaryFloat(-1000, 1000)(g)
			local shift = g:int(-4, 35)
			return { i1 = i1, i2 = i2, f1 = f1, shift = shift }
		end,
		sut = function(inp)
			local fLit = if inp.f1 ~= inp.f1
				then "(0/0)"
				elseif inp.f1 == math.huge then "math.huge"
				elseif inp.f1 == -math.huge then "(-math.huge)"
				elseif inp.f1 == 0 and 1 / inp.f1 < 0 then "(-0.0)"
				else string.format("%.17g", inp.f1)
			local src = string.format(
				[[
				local a = %d
				local b = %d
				local f = %s
				local r1 = (a + b) * (a - b) + (a // b) - (a %% b)
				local b1 = bit32.band(a, 0xffff)
				local b2 = bit32.lshift(b, %d)
				local r2 = bit32.bxor(b1, b2)
				local r3 = math.abs(f)
				local r4 = (a < b) and (a == a) or (a ~= b)
				return r1, r2, r3, r4
			]],
				inp.i1,
				inp.i2,
				fLit,
				inp.shift
			)
			local bcO2 = assert(Parser.compile(src, { optimizationLevel = 2 }))
			local fnO2 = assert(Parser.load(bcO2, { name = "=o2", mode = "binary" }))
			return table.pack(fnO2())
		end,
		oracle = function(inp: any)
			local a: number, b: number, f: number = inp.i1, inp.i2, inp.f1
			local r1 = (a + b) * (a - b) + (a // b) - (a % b)
			local r2 = bit32.bxor(bit32.band(a, 0xffff), bit32.lshift(b, inp.shift))
			local r3 = math.abs(f)
			local r4 = (a < b) and (a == a) or (a ~= b)
			return table.pack(r1, r2, r3, r4)
		end,
		eq = function(got, want)
			return got.n == want.n
				and numEq(got[1], want[1])
				and numEq(got[2], want[2])
				and numEq(got[3], want[3])
				and got[4] == want[4]
		end,
	}, { runs = 100 })

	test("folds comprehensive math, bit32, string, type, vector, and 0.748 builtins at O2", function()
		local function hasCallOrFastcall(mod: PublicTypes.ProtoModule): boolean
			for _, proto in mod.protos do
				for _, word in proto.code do
					local op = BytecodeCodec.insnOp(word)
					if
						op == Opcodes.LOP_CALL
						or op == Opcodes.LOP_FASTCALL
						or op == Opcodes.LOP_FASTCALL1
						or op == Opcodes.LOP_FASTCALL2
						or op == Opcodes.LOP_FASTCALL2K
						or op == Opcodes.LOP_FASTCALL3
					then
						return true
					end
				end
			end
			return false
		end

		local mathAndBitDump, mathAndBitRes = disassemble(
			[[
			local m1 = math.acos(1) + math.asin(0) + math.atan(0) + math.atan2(0, 1)
			local m2 = math.ceil(1.2) + math.cos(0) + math.cosh(0) + math.deg(0) + math.exp(0)
			local m3 = math.floor(2.8) + math.fmod(7, 3) + math.ldexp(1.5, 2) + math.ldexp(2, -1)
			local m4 = math.log(1) + math.log(8, 2) + math.log(100, 10) + math.log(9, 3) + math.log10(1000)
			local m5 = math.max(1, 5, 3) + math.min(4, 2, 8) + math.pow(2, 4) + math.rad(180)
			local m6 = math.sin(0) + math.sinh(0) + math.sqrt(16) + math.tan(0) + math.tanh(0) + math.round(2.6)
			local m7 = math.sign(10) + math.sign(-10) + math.sign(0) + math.clamp(5, 1, 3) + math.lerp(10, 20, 0.5) + math.lerp(10, 20, 1.0)
			local b1 = if math.isnan(0/0) and math.isinf(math.huge) and math.isfinite(42) then 1 else 0
			local kc = math.e + math.pi + math.tau + math.phi + math.sqrt2

			local x1 = bit32.band(0xff, 0x0f) + bit32.bor(0x10, 0x01) + bit32.bxor(0xff, 0x0f) + bit32.bnot(0)
			local x2 = (if bit32.btest(0xff, 0x01) then 1 else 0)
			local x3 = bit32.lshift(1, 4) + bit32.rshift(32, 2) + bit32.arshift(-16, 2) + bit32.lrotate(1, 3) + bit32.rrotate(8, 2)
			local x4 = bit32.extract(0xff, 2) + bit32.extract(0xff, 2, 4) + bit32.replace(0, 1, 3) + bit32.replace(0, 7, 2, 3)

			local s1 = string.byte("ABC") + string.byte("ABC", 2) + string.len("hello")
			local s2 = string.char(65, 66, 67) .. string.sub("abcdef", 2) .. string.sub("abcdef", -2)
			local s3 = string.sub("abcdef", 2, 4) .. string.sub("abcdef", -4, -2) .. string.sub("abcdef", 1, -10)
			local ty = type(1) .. typeof("a") .. type(true) .. type(nil) .. type(vector.create(1, 2, 3))
			return m1, m2, m3, m4, m5, m6, m7, b1, kc, x1, x2, x3, x4, s1, s2, s3, ty
		]],
			{ optimizationLevel = 2, librariesWithKnownMembers = { "math", "bit32", "string", "vector" } }
		)
		expect(string.find(mathAndBitDump, "RETURN", 1, true) ~= nil, "compiled folded math/bit32/string/type chunk")
		sert.eq(
			hasCallOrFastcall(assert(mathAndBitRes.builder):toProtoModule()),
			false,
			"all foldable math/bit32/string/vector/type expressions fold with zero CALL/FASTCALL"
		)
		local foldFn = assert(VM.loadBytecode(mathAndBitRes.bytecode, { name = "=fold_all" }))
		local rm1, rm2, rm3, rm4, rm5, rm6, rm7, rb1, rkc, rx1, rx2, rx3, rx4, rs1, rs2, rs3, rty = foldFn()
		local expKc = math.exp(1) + math.pi + (math.pi * 2) + ((1 + math.sqrt(5)) / 2) + math.sqrt(2)
		sert.eq(rm1, math.acos(1) + math.asin(0) + math.atan(0) + math.atan2(0, 1))
		sert.eq(rm2, math.ceil(1.2) + math.cos(0) + math.cosh(0) + math.deg(0) + math.exp(0))
		sert.eq(rm3, math.floor(2.8) + math.fmod(7, 3) + math.ldexp(1.5, 2) + math.ldexp(2, -1))
		sert.eq(rm4, math.log(1) + math.log(8, 2) + math.log(100, 10) + math.log(9, 3) + math.log10(1000))
		sert.eq(rm5, math.max(1, 5, 3) + math.min(4, 2, 8) + math.pow(2, 4) + math.rad(180))
		sert.eq(rm6, math.sin(0) + math.sinh(0) + math.sqrt(16) + math.tan(0) + math.tanh(0) + math.round(2.6))
		sert.eq(
			rm7,
			math.sign(10)
				+ math.sign(-10)
				+ math.sign(0)
				+ math.clamp(5, 1, 3)
				+ math.lerp(10, 20, 0.5)
				+ math.lerp(10, 20, 1.0)
		)
		sert.eq(rb1, 1)
		expect(numEq(rkc, expKc), `math constants folded to {rkc} vs {expKc}`)
		sert.eq(rx1, bit32.band(0xff, 0x0f) + bit32.bor(0x10, 0x01) + bit32.bxor(0xff, 0x0f) + bit32.bnot(0))
		sert.eq(rx2, if bit32.btest(0xff, 0x01) then 1 else 0)
		sert.eq(
			rx3,
			bit32.lshift(1, 4) + bit32.rshift(32, 2) + bit32.arshift(-16, 2) + bit32.lrotate(1, 3) + bit32.rrotate(8, 2)
		)
		sert.eq(
			rx4,
			bit32.extract(0xff, 2) + bit32.extract(0xff, 2, 4) + bit32.replace(0, 1, 3) + bit32.replace(0, 7, 2, 3)
		)
		sert.eq(rs1, string.byte("ABC") + string.byte("ABC", 2) + string.len("hello"))
		sert.eq(rs2, string.char(65, 66, 67) .. string.sub("abcdef", 2) .. string.sub("abcdef", -2))
		sert.eq(rs3, string.sub("abcdef", 2, 4) .. string.sub("abcdef", -4, -2) .. string.sub("abcdef", 1, -10))
		sert.eq(rty, "numberstringbooleannilvector")

		local runtimeBuiltinDump, runtimeBuiltinRes = disassemble(
			"return typeof(vector.create(1, 2, 3)), bit32.countlz(16) + bit32.countrz(16) + bit32.byteswap(0x01020304)",
			{ optimizationLevel = 2, librariesWithKnownMembers = { "math", "bit32", "vector" } }
		)
		expect(
			string.find(runtimeBuiltinDump, "FASTCALL1 44", 1, true) ~= nil,
			"typeof(vector.create) must stay runtime-resolved via FASTCALL1"
		)
		expect(string.find(runtimeBuiltinDump, "FASTCALL1 55", 1, true) ~= nil, "bit32.countlz emits FASTCALL1")
		expect(string.find(runtimeBuiltinDump, "FASTCALL1 56", 1, true) ~= nil, "bit32.countrz emits FASTCALL1")
		expect(string.find(runtimeBuiltinDump, "FASTCALL1 64", 1, true) ~= nil, "bit32.byteswap emits FASTCALL1")
		local runtimeBuiltinFn = assert(VM.loadBytecode(runtimeBuiltinRes.bytecode, { name = "=runtime_builtins" }))
		local rTypeof, rBit = runtimeBuiltinFn()
		sert.eq(rTypeof, "vector")
		sert.eq(rBit, bit32.countlz(16) + bit32.countrz(16) + bit32.byteswap(0x01020304))

		local mathImportDump = disassemble(
			"return math.halfpi, math.quarterpi, math.twopi, math.sqrt3",
			{ optimizationLevel = 2, librariesWithKnownMembers = { "math" } }
		)
		expect(string.find(mathImportDump, "GETIMPORT", 1, true) ~= nil, "non-folded math fields keep GETIMPORT")

		-- Vector folding at float32 (vectorPrecision = 0) and float64 (vectorPrecision = 1)
		for _, prec in { 0, 1 } do
			local _, vecRes = disassemble(
				[[
				local v1 = vector.create(1, 2, 3)
				local v2 = vector.create(4, 5, 6)
				local v3 = -v1 + v2 - v1
				local v4 = (v1 * v2) / v1
				local v5 = (v1 * 2) + (2 * v2) - (v2 / 2) + (12 / v1)
				local v6 = (v2 // v1) + (v2 // 2) + (12 // v1)
				local eq = (v1 == v2) or (v1 ~= v2)
				local comps = v1.x + v1.y + v1.z + v1.X + v1.Y + v1.Z
				return v3.x, v4.y, v5.z, v6.x, eq, comps
			]],
				{
					optimizationLevel = 2,
					vectorPrecision = prec,
				}
			)
			sert.eq(
				hasCallOrFastcall(assert(vecRes.builder):toProtoModule()),
				false,
				`zero CALL/FASTCALL for folded vector@prec{prec}`
			)
			local vecFn = assert(VM.loadBytecode(vecRes.bytecode, { name = "=vec_fold" }))
			local rv3x, rv4y, rv5z, rv6x, req, rcomps = vecFn()
			sert.eq(rv3x, 2)
			sert.eq(rv4y, 5)
			sert.eq(rv5z, 19)
			sert.eq(rv6x, 18)
			sert.eq(req, true)
			sert.eq(rcomps, 12)
		end

		-- 0.748 table.create/table.clear and buffer.read/writevectorf32x* fastcalls
		local _, builtinRes = disassemble(
			[[
			local function testNewBuiltins(buf)
				local t = table.create(4, 9)
				table.clear(t)
				local v2 = buffer.readvectorf32x2(buf, 0)
				local v3 = buffer.readvectorf32x3(buf, 0)
				local v4 = buffer.readvectorf32x4(buf, 0)
				buffer.writevectorf32x2(buf, 0, v2)
				buffer.writevectorf32x3(buf, 0, v3)
				buffer.writevectorf32x4(buf, 0, v4)
				return t, v2, v3, v4
			end
			return testNewBuiltins
		]],
			{
				optimizationLevel = 2,
				flags = {
					LuauCompileTableBuiltinsCreateClear = true,
					DebugLuauBufferVectorFastcalls = true,
				},
			}
		)
		local emittedFastcallIds: { [number]: boolean } = {}
		for _, word in assert(builtinRes.builder):toProtoModule().protos[1].code do
			local op = BytecodeCodec.insnOp(word)
			if
				op == Opcodes.LOP_FASTCALL
				or op == Opcodes.LOP_FASTCALL1
				or op == Opcodes.LOP_FASTCALL2
				or op == Opcodes.LOP_FASTCALL2K
				or op == Opcodes.LOP_FASTCALL3
			then
				emittedFastcallIds[BytecodeCodec.insnA(word)] = true
			end
		end
		for _, fcId in { 133, 134, 135, 136, 137, 138, 139, 140 } do
			expect(emittedFastcallIds[fcId] == true, "expected 0.748 fastcall id " .. tostring(fcId))
		end
	end)

	test("compiles classes, exports, if-local, assignment conflicts, type aliases, and compiler flags", function()
		-- Classes (including private properties/methods) + Exports with LuauOptimizeExportTable = false and true
		for _, optExport in { false, true } do
			local varExportDecls = if optExport
				then "local expVar = 10\nconst expConst = 20"
				else "export local expVar = 10\nexport const expConst = 20"
			local dumpClass, resClass = disassemble(varExportDecls .. "\n" .. [[
				export type MyNumber = number
				type VecAlias = vector
				type TblAlias = { x: number, y: string }

				export function expFn(v: MyNumber): MyNumber
					return v + expVar + expConst
				end

				class Base
					public baseProp: number
					private _sec: number
					public function __init(self, v: number)
						self.baseProp = v
						self._sec = v + 1
					end
					private function _getSec(self): number
						return self._sec
					end
					public function getBase(self): number
						return self.baseProp + self:_getSec()
					end
				end

				export open class Derived extends Base
					public extra: string
					public function getExtra(self): string
						return self.extra
					end
				end

				if local condVar = expFn(5) then
					expVar = condVar
				else
					expVar = 0
				end

				local exprIfLocal = if local tmp = expFn(1) then tmp + 1 else 0
				expVar = exprIfLocal
			]], {
				optimizationLevel = 2,
				debugLevel = 2,
				typeInfoLevel = 1,
				parseOptions = { profile = "experimental" },
				flags = {
					LuauOptimizeExportTable = optExport,
					LuauExportedTypesParticipateInScc = true,
				},
			})
			expect(string.find(dumpClass, "NEWCLASS", 1, true) ~= nil, "emits NEWCLASS")
			expect(string.find(dumpClass, "NEWCLASSMEMBER", 1, true) ~= nil, "emits NEWCLASSMEMBER")
			expect(string.find(dumpClass, "GETPRIVATEFIELD", 1, true) ~= nil, "emits GETPRIVATEFIELD")
			expect(string.find(dumpClass, "SETPRIVATEFIELD", 1, true) ~= nil, "emits SETPRIVATEFIELD")
			expect(string.find(dumpClass, "[private]", 1, true) ~= nil, "emits private class member flag")
			local deser = assert(BytecodeCodec.deserialize(resClass.bytecode))
			expect(#deser.protos >= 5, "deserializes class and export bytecode")
		end

		-- LuauExportedTypesParticipateInScc sets LPF_USES_EXPORT on top-level unless module returns
		local expTypeNoRet = assert(
			BytecodeCodec.deserialize(
				assert(
					Compiler.compile("export type T = number", { flags = { LuauExportedTypesParticipateInScc = true } })
				)
			)
		)
		local expTypeWithRet = assert(
			BytecodeCodec.deserialize(
				assert(
					Compiler.compile(
						"export type T = number\nreturn {}",
						{ flags = { LuauExportedTypesParticipateInScc = true } }
					)
				)
			)
		)
		expect(
			bit32.band(expTypeNoRet.protos[expTypeNoRet.mainid + 1].flags, BytecodeDefs.ProtoFlags.LPF_USES_EXPORT) ~= 0,
			"export type without return sets LPF_USES_EXPORT"
		)
		sert.eq(
			bit32.band(expTypeWithRet.protos[expTypeWithRet.mainid + 1].flags, BytecodeDefs.ProtoFlags.LPF_USES_EXPORT),
			0
		)

		-- Export + top-level return conflict diagnostic
		local conflictRes = Compiler.compileResult("export local x = 1\nreturn x", {
			parseOptions = { profile = "experimental" },
		})
		sert.eq(conflictRes.status, "parseError")
		expect(
			string.find(conflictRes.error or "", "export/return conflict", 1, true) ~= nil,
			"reports export/return conflict"
		)

		-- Multi-assignment conflict resolution, compound concat, while/break/continue, move elision, local reg reuse
		local dumpComplex, resComplex = disassemble(
			[[
			local a, b, c = 1, 2, 3
			local t = { 10, 20, 30, k = "v" }
			-- Register & table assignment conflicts
			a, b, c = b, c, a
			local idx = 1
			t[idx], idx = 99, idx + 1
			t.k, a = a, t.k

			-- Compound concat with chained ..
			local s = "start"
			s ..= "-" .. tostring(a) .. "-" .. tostring(b)

			-- JUMPXEQKNIL, JUMPXEQKB, JUMPXEQKN, JUMPXEQKS and unary not jump
			local flag = false
			if a == nil or b == true or c == 42 or s == " target " or not flag then
				flag = true
			end

			-- While loop with break and continue, plus 0-trip unroll candidate
			local i = 0
			while i < 10 do
				i += 1
				if i == 2 then
					continue
				elseif i == 5 then
					break
				end
			end
			for z = 10, 1, 1 do
				i += z
			end

			-- Move elision & parameter return
			local function retParam(p1: number, p2: number)
				local copy = p2
				return copy
			end

			-- Sequentially scoped locals to trigger register reuse with debug info
			do
				local scopedA: number = 11
				i += scopedA
			end
			do
				local scopedB: number = 22
				i += scopedB
			end

			-- Table call & method definition
			local function sink(tbl)
				return tbl[1]
			end
			local tc = sink { 123 }
			local obj = {}
			function obj:method(x: number)
				return x + 1
			end

			return a, b, c, s, flag, i, retParam(1, 2), tc, obj:method(5), CustomLib.CONST
		]],
			{
				optimizationLevel = 2,
				debugLevel = 2,
				typeInfoLevel = 1,
				librariesWithKnownMembers = { "CustomLib" },
				libraryMemberConstantCb = function(lib: string, member: string): PublicTypes.CompileConstant?
					if lib == "CustomLib" and member == "CONST" then
						return { type = "number", value = 777 }
					end
					return nil
				end,
				libraryMemberTypeCb = function(lib: string, member: string)
					if lib == "CustomLib" and member == "CONST" then
						return BytecodeTypes.LBC_TYPE_NUMBER
					end
					return BytecodeTypes.LBC_TYPE_ANY
				end,
			}
		)
		expect(string.find(dumpComplex, "CONCAT", 1, true) ~= nil, "emits CONCAT for compound ..=")
		expect(string.find(dumpComplex, "JUMPXEQK", 1, true) ~= nil, "emits JUMPXEQK*")
		expect(string.find(dumpComplex, "NAMECALL", 1, true) ~= nil, "emits NAMECALL")
		local complexFn = assert(VM.loadBytecode(resComplex.bytecode, { name = "=complex" }))
		local ca, cb, cc, cs, cflag, ci, crp, ctc, cmeth, cconst = complexFn()
		sert.eq(ca, "v")
		sert.eq(cb, 3)
		sert.eq(cc, 1)
		sert.eq(cs, "start-v-3")
		sert.eq(cflag, true)
		sert.eq(ci, 38)
		sert.eq(crp, 2)
		sert.eq(ctc, 123)
		sert.eq(cmeth, 6)
		sert.eq(cconst, 777)

		-- Exceeded userdata type limit error
		local tooManyUd: { string } = {}
		for i = 1, 40 do
			tooManyUd[i] = `UD_{i}`
		end
		local udRes = Compiler.compileResult("return 1", { userdataTypes = tooManyUd })
		sert.eq(udRes.status, "compileError")
		expect(string.find(udRes.error or "", "Exceeded userdata type limit", 1, true) ~= nil, "userdata limit error")
	end)

	test(
		"covers cost modeling, inlining arg bindings, repeat-until continue validation, coverage opcodes, and type alias resolution",
		function()
			-- 1. Repeat-until continue validation across all expression node kinds
			local contErrs = {
				[[
				local x = { y = 1, [1] = 2 }
				local function fn(a, b) return a end
				repeat
					if x.y == 1 then continue end
					local afterLocal = 10
				until (-(fn(x[1], x.y)) :: any)
					and (if x.y then `s={x.y}` else ({ [x.y] = 1, k = 2 }).k)
					and (function() return 1 end)()
					and afterLocal == 10
				]],
				[[
				repeat
					if unknownCond then continue end
					local capturedAfter = unknownFn()
				until (function() return capturedAfter end)() == 5
				]],
			}
			for _, src in contErrs do
				local r = Compiler.compileResult(src)
				sert.eq(r.status, "compileError")
				expect(
					string.find(r.error or "", "repeat..until", 1, true) ~= nil,
					"reports continue until local error"
				)
			end

			-- 2. Cost model, inlining argument bindings, move elision, coverageLevel = 2, and type aliases
			local dumpInl, resInl = disassemble(
				[[
					type NumAlias = number
					type GenericAlias<T> = T | nil
					type IntersectAlias = { x: number } & { y: string }
					type BoolLit = true
					type StrLit = "tag"
					type TblIdx = { [number]: string, prop: number }

					repeat
						type InnerAlias = NumAlias
						local tmpAlias: InnerAlias = 1
					until true

					local function multiProducer(): (number, number)
						return 3, 4
					end

					local function inlWritten(a: NumAlias, b: GenericAlias<number>, c: IntersectAlias?)
						a = a + 1
						local tbl = { k = a, [a] = b or 0 }
						local ifelse = if local cl = a then cl + 1 else 0
						local interp = `v={a},{ifelse}`
						if local sl = a then
							b = sl
						end
						if false then
							a = 0
						else
							a += 1
						end
						if true then
							a += 2
						end
						for i = 1, 3 do
							a += i
						end
						for i = 1, a, 2 do
							a += i
						end
						for k, v in next, tbl do
							if k == 99 then break end
							if k == 98 then continue end
							a += 1
						end
						while a > 100 do
							a -= 1
						end
						repeat
							a -= 1
						until a <= 50
						return a + (#interp)
					end

					local function inlWrittenRetParam(p1: number, p2: number)
						p1 += 1
						return p1
					end

					local function inlVarargCaller(...)
						return inlWrittenRetParam(...)
					end

					local function inlRetParam(p1: number, p2: number)
						return p1
					end

					local function inlRetParam2(p1: number, p2: number)
						return p2
					end

					local function nonConsecReturn(g)
						local r1 = g()
						local r2 = g()
						local r3 = g()
						local condA = if r1 then r1 else r2
						local condB = if r1 then r2 else r1
						local condC = if r1 then r1 else 42
						local condD = if r1 then 42 else r1
						return r1, r3, condA, condB, condC, condD
					end

					local function indexTyped(t: TblIdx, u: CustomUD, v: Vec3, b: BoolLit, s: StrLit)
						local constKey = "prop"
						return t[1], t.prop, t[constKey], u, v, b, s
					end

					local constTbl = {
						fn = function(v: number)
							return v + 10
						end,
					}

					local function nestedRecOuter(n: number)
						local function rec(k: number): number
							if k <= 0 then
								return 1
							end
							return rec(k - 1)
						end
						return rec(n)
					end

					-- Loop unroll remarks: too many iterations & too expensive body
					local unrollAcc = 0
					for i = 1, 25 do
						unrollAcc += i
					end
					for i = 1, 5 do
						unrollAcc += math.sin(i) + math.cos(i) + math.tan(i) + math.sqrt(i) + math.exp(i) + math.log(i)
						unrollAcc += math.asin(0) + math.acos(1) + math.atan(i) + math.sinh(i) + math.cosh(i) + math.tanh(i)
					end

					-- Constant folding comparisons (strings, booleans, nil, mismatched types, vectors)
					local cmpFold = ("a" < "b") and ("a" <= "b") and ("b" > "a") and ("b" >= "a")
						and (true == true) and (true ~= false) and (nil == nil) and (1 ~= "1")

					local x = inlWritten(10, 20)
					local y = inlWritten()
					local z = inlWritten(multiProducer())
					local w = inlWritten(1, 2, 3, x + y)
					local wr1 = inlWrittenRetParam(x, x)
					local wr2 = inlWrittenRetParam(x, y)
					local wr3 = inlWrittenRetParam()
					local wr4 = inlVarargCaller(x, y)
					local rp1 = inlRetParam(x, x + 1)
					local rp2 = inlRetParam(x + 1, x)
					local rp3 = inlRetParam()
					local rp4 = inlRetParam2(x, x + 1)
					local ctCall = constTbl.fn(5)
					local sinkTbl = inlRetParam { a = 1, b = x }
					return x, y, z, w, wr1, wr2, wr3, wr4, rp1, rp2, rp3, rp4, ctCall, nestedRecOuter(2), unrollAcc, cmpFold, sinkTbl, nonConsecReturn(multiProducer), indexTyped
				]],
				{
					optimizationLevel = 2,
					debugLevel = 2,
					typeInfoLevel = 1,
					coverageLevel = 2,
					userdataTypes = { "CustomUD" },
					vectorType = "Vec3",
					vectorCtor = "vec3",
					disabledBuiltins = { "assert", "math.abs", "bit32" },
					parseOptions = { profile = "experimental" },
				}
			)
			expect(string.find(dumpInl, "COVERAGE", 1, true) ~= nil, "emits COVERAGE instructions")
			expect(string.find(dumpInl, "inlining succeeded", 1, true) ~= nil, "inlines eligible helper calls")
			expect(string.find(dumpInl, "loop unroll", 1, true) ~= nil, "emits loop unroll remarks")
			local covCount = 0
			local hasTypedProto = false
			for _, proto in assert(resInl.builder):toProtoModule().protos do
				if proto.debugname == "indexTyped" and proto.typeinfo ~= nil and #proto.typeinfo > 0 then
					hasTypedProto = true
				end
				for _, word in proto.code do
					if BytecodeCodec.insnOp(word) == Opcodes.LOP_COVERAGE then
						covCount += 1
					end
				end
			end
			expect(covCount >= 1, "emits LOP_COVERAGE opcodes")
			expect(hasTypedProto, "indexTyped proto emits typeinfo")

			-- 3. Compiler limit errors (locals > 200, upvalues > 200, registers > 255, non-top-level export, getfenv/setfenv)
			local manyLocals = table.create(205)
			for i = 1, 202 do
				manyLocals[i] = `local l_{i} = {i}`
			end
			local locErr = Compiler.compileResult(table.concat(manyLocals, "\n"), { optimizationLevel = 0 })
			sert.eq(locErr.status, "compileError")
			expect(string.find(locErr.error or "", "Out of local registers", 1, true) ~= nil, "local limit error")

			local manyArgs = table.create(260)
			for i = 1, 256 do
				manyArgs[i] = tostring(i)
			end
			local regErr = Compiler.compileResult(`return f({table.concat(manyArgs, ", ")})`)
			sert.eq(regErr.status, "compileError")
			expect(string.find(regErr.error or "", "Out of registers", 1, true) ~= nil, "register limit error")

			local upDecls = { "local function outer1()" }
			for i = 1, 120 do
				upDecls[#upDecls + 1] = `local u_{i} = {i}`
			end
			upDecls[#upDecls + 1] = "local function outer2()"
			for i = 121, 205 do
				upDecls[#upDecls + 1] = `local u_{i} = {i}`
			end
			upDecls[#upDecls + 1] = "local function inner()"
			local upUses = {}
			for i = 1, 202 do
				upUses[i] = `u_{i}`
			end
			upDecls[#upDecls + 1] = `return {table.concat(upUses, " + ")}`
			upDecls[#upDecls + 1] = "end return inner end return outer2 end"
			local upErr = Compiler.compileResult(table.concat(upDecls, "\n"), { optimizationLevel = 0 })
			sert.eq(upErr.status, "compileError")
			expect(string.find(upErr.error or "", "Out of upvalue registers", 1, true) ~= nil, "upvalue limit error")

			local nonTopExport = Compiler.compileResult("do export local x = 1 end", {
				parseOptions = { profile = "experimental" },
			})
			sert.eq(nonTopExport.status, "parseError")
			expect(string.find(nonTopExport.error or "", "top-level", 1, true) ~= nil, "non-top-level export error")

			local fenvDump, fenvRes = disassemble(
				[[
				local function useFenv(buf)
					local e = getfenv(1)
					setfenv(1, e)
					buffer.writevectorf32x2(buf, 0, vector.create(1, 2, 0))
					return buffer.readvectorf32x2(buf, 0)
				end
				return useFenv
			]],
				{
					optimizationLevel = 2,
					flags = { DebugLuauBufferVectorFastcalls = true },
				}
			)
			expect(
				string.find(fenvDump, "GETIMPORT", 1, true) ~= nil and string.find(fenvDump, "CALL", 1, true) ~= nil,
				fenvDump
			)
			expect(string.find(fenvDump, "FASTCALL", 1, true) ~= nil, fenvDump)
			local useFenvFactory = assert(VM.loadBytecode(fenvRes.bytecode, {
				name = "=use_fenv",
				env = VM.createEnvironment({
					buffer = {
						writevectorf32x2 = function() end,
						readvectorf32x2 = function()
							return vector.create(1, 2, 0)
						end,
					},
				}),
			}))
			local useFenvFn = useFenvFactory()
			local fenvBuf = buffer.create(16)
			local fenvVec = useFenvFn(fenvBuf)
			sert.eq(fenvVec.X, 1)
			sert.eq(fenvVec.Y, 2)

			-- Non-terminating inlined call, xpcall fastpcall, class without __init, and vector/string constant equality folding
			local miscDump = disassemble(
				[[
				class PlainBox
					public val: number
				end
				local function sideEffectInl(a: number)
					local tmp = a + 1
					if tmp > 0 then
						tmp += 2
					else
						tmp += 3
					end
				end
				sideEffectInl(10)
				local ok, res = xpcall(sideEffectInl, function(e) return e end, 5)
				return ok, res
			]],
				{
					optimizationLevel = 2,
					parseOptions = { profile = "experimental" },
				}
			)
			expect(string.find(miscDump, "NEWCLASS", 1, true) ~= nil, "compiles PlainBox without explicit __init")
			expect(string.find(miscDump, "FASTPCALL", 1, true) ~= nil, "xpcall uses FASTPCALL in miscDump")

			local eqDump = disassemble(
				[[
				local v1 = vector.create(1, 2, 3)
				local v2 = vector.create(1, 2, 3)
				local eqVec = (v1 == v2) and (v1 ~= v2)
				local s1 = "abc"
				local s2 = "abc"
				local eqStr = (s1 == s2) and (s1 ~= s2)
				return eqVec, eqStr
			]],
				{ optimizationLevel = 2 }
			)
			expect(string.find(eqDump, "JUMPIF", 1, true) == nil, "vector/string constant equality folded away")

			-- Rich type annotations, vector.zero/one, and libraryMemberTypeCallback in CompilerTypes
			do
				local typeDump, typeRes = disassemble(
					[[
					type Rec = Rec
					type NumAlias = number
					local function typedFn(
						p1: Mod.Foo,
						p2: Rec,
						p3: { a: number, [number]: string },
						p4: () -> (),
						p5: number | nil,
						p6: number | string,
						p7: nil | nil,
						p8: number & string,
						p9: (number),
						p10: number?,
						p11: true,
						p12: "hi",
						p13: NumAlias
					)
						local v0 = vector.zero
						local v1 = vector.one
						local cb = CustomLib.b
						local cn = CustomLib.n
						local cs = CustomLib.s
						local cv = CustomLib.v
						for k, v in ipairs(p3) do
							local _ = k + #v
						end
						for k, v in pairs(p3) do
							local _ = k + #v
						end
						for k: number, v: string in p3 do
							local _ = k + #v
						end
						local ifLoc = if local c = p13 then c else 0
						local castVal = (p1 :: number)
						return p3.a, p3[1], v0.X + v1.Y, cb, cn, cs, cv, ifLoc, castVal
					end
					return typedFn
				]],
					{
						optimizationLevel = 2,
						typeInfoLevel = 1,
						parseOptions = { profile = "experimental" },
						librariesWithKnownMembers = { "CustomLib" },
						libraryMemberTypeCb = function(lib: string, member: string): number
							if lib == "CustomLib" then
								if member == "b" then
									return BytecodeDefs.Types.LBC_TYPE_BOOLEAN
								elseif member == "n" then
									return BytecodeDefs.Types.LBC_TYPE_NUMBER
								elseif member == "s" then
									return BytecodeDefs.Types.LBC_TYPE_STRING
								elseif member == "v" then
									return BytecodeDefs.Types.LBC_TYPE_VECTOR
								end
							end
							return BytecodeDefs.Types.LBC_TYPE_ANY
						end,
					}
				)
				expect(string.find(typeDump, "GETIMPORT", 1, true) ~= nil, "compiles typed function and CustomLib")
				local typeMod = assert(typeRes.builder):toProtoModule()
				expect(
					typeMod.protos[1].typeinfo ~= nil and #(typeMod.protos[1].typeinfo :: string) > 8,
					"typedFn emits binary typeinfo"
				)
			end
		end
	)

	test("accepts pre-parsed ParseResult in compile, compileResult, and compileProto", function()
		-- Verify CompilerBuiltins.getBuiltinFunctionId signature
		local bParse = Parser.parse("return math.abs(-5), notABuiltin(1)")
		assert(#bParse.diagnostics == 0, "clean parse")
		sert.eq(CompilerBuiltins.getBuiltinFunctionId({ object = "math", method = "abs" }, {}), Builtins.LBF_MATH_ABS)

		local src = [[
			local base = -0.0
			local function makeAdder(offset: number): (number) -> (number, string)
				local tag = "sum:"
				return function(x: number): (number, string)
					local acc = offset + base
					for i = 1, 4 do
						acc += math.abs(x - i)
					end
					local tbl = { kind = tag, total = acc, [1] = x }
					return tbl.total, tbl.kind .. tostring(tbl[1])
				end
			end
			local fn = makeAdder(10)
			return fn(3)
		]]

		local pr = Parser.parse(src)
		sert.eq(#pr.diagnostics, 0)

		-- Reuse the exact same ParseResult across O0, O1, and O2
		for _, optLevel in { 0, 1, 2 } do
			local opts: Compiler.CompileOptions = {
				optimizationLevel = optLevel,
				debugLevel = 2,
				typeInfoLevel = 1,
			}
			local bcFromStr = assert(Compiler.compile(src, opts))
			local bcFromPr = assert(Compiler.compile(pr, opts))
			sert.eq(bcFromPr, bcFromStr)

			local resFromPr = Compiler.compileResult(pr, opts)
			sert.eq(resFromPr.status, "ok")
			sert.eq(resFromPr.bytecode, bcFromStr)

			local deserialized = assert(BytecodeCodec.deserialize(bcFromStr))
			local retainedProto = assert(resFromPr.builder, "compileResult builder"):toProtoModule()
			Helpers.assertDeepEqual(
				retainedProto,
				deserialized,
				"compileResult.builder:toProtoModule()@O" .. tostring(optLevel)
			)

			local protoOnly, protoErr = Compiler.compileProto(pr, opts)
			sert.eq(protoErr, nil)
			local checkedProto = assert(protoOnly, "compileProto returned ProtoModule")
			Helpers.assertDeepEqual(checkedProto, deserialized, "compileProto@O" .. tostring(optLevel))

			local fnBc = assert(VM.loadBytecode(bcFromStr, { name = "=bc" }))
			local fnProto = assert(VM.loadProto(checkedProto, { name = "=proto" }))
			local n1, s1 = fnBc()
			local n2, s2 = fnProto()
			sert.eq(n1, 14)
			sert.eq(s1, "sum:3")
			sert.eq(n2, n1)
			sert.eq(s2, s1)
		end

		-- Parse error handling on pre-parsed ParseResult
		local badParse = Parser.parse("local broken =")
		expect(#badParse.diagnostics > 0, "has syntax error")
		local badParseRes = Compiler.compileResult(badParse)
		sert.eq(badParseRes.status, "parseError")
		sert.eq(badParseRes.bytecode, Parser.compileResult("local broken =").bytecode)
		local nilBc1, parseTupleErr = Compiler.compile(badParse)
		sert.eq(nilBc1, nil)
		sert.eq(parseTupleErr, badParseRes.error)
		local nilProto1, parseErrStr = Compiler.compileProto(badParse)
		sert.eq(nilProto1, nil)
		sert.eq(parseErrStr, badParseRes.error)

		-- Semantic compile error handling on pre-parsed ParseResult
		local semErrSrc = "repeat if cond then continue end local x = 10 until x == 10"
		local badSemantic = Parser.parse(semErrSrc)
		sert.eq(#badSemantic.diagnostics, 0)
		local badSemRes = Compiler.compileResult(badSemantic)
		sert.eq(badSemRes.status, "compileError")
		sert.eq(badSemRes.bytecode, Compiler.compileResult(semErrSrc).bytecode)
		local nilBc2, semTupleErr = Compiler.compile(badSemantic)
		sert.eq(nilBc2, nil)
		sert.eq(semTupleErr, badSemRes.error)
		local nilProto2, semErrStr = Compiler.compileProto(badSemantic)
		sert.eq(nilProto2, nil)
		sert.eq(semErrStr, badSemRes.error)
	end)

	test("upgrades O0 compilation for @native functions and analyzes builtins inside inlined helpers", function()
		local nativeO0Bc = assert(Compiler.compile(
			[[
			local function step(x: number)
				@native
				local function inner(y: number): number
					local s = math.abs(y)
					local t = { k = s }
					return t.k + 1
				end
				return inner(x)
			end
			return step(-9)
		]],
			{ optimizationLevel = 0 }
		))
		local nativeO0Mod = assert(BytecodeCodec.deserialize(nativeO0Bc))
		local innerProto = nativeO0Mod.protos[1]
		expect(
			bit32.band(innerProto.flags, ProtoFlags.LPF_NATIVE_FUNCTION) ~= 0,
			"@native upgrades inner proto flag even at O0"
		)
		local hasNativeFastcall = false
		for _, word in innerProto.code do
			if BytecodeCodec.insnOp(word) == Opcodes.LOP_FASTCALL1 then
				hasNativeFastcall = true
				break
			end
		end
		expect(hasNativeFastcall, "@native emits LOP_FASTCALL1 at O0")
		local nativeO0Fn = assert(VM.loadProto(nativeO0Mod, { name = "=native_o0" }))
		sert.eq(nativeO0Fn(), 10)

		local inlineSrc = [[
			local abs = math.abs
			local function ifApply(fn, a)
				if a < 0 then
					return fn(a)
				end
				return fn(-a)
			end
			local function forApply(fn, a)
				local s = 0
				for i = 1, 2 do
					s += fn(a - i)
				end
				return s
			end
			local function whileApply(fn, a)
				local i, s = 0, 0
				while i < 2 do
					i += 1
					s += fn(a)
				end
				return s
			end
			local function repeatApply(fn, a)
				local i, s = 2, 0
				repeat
					s += fn(a)
					i -= 1
				until i == 0
				return s
			end
			local function forInApply(fn, tbl)
				local s = 0
				for _, v in tbl do
					s += fn(v)
				end
				return s
			end
			local function exprApply(fn, a)
				local r = 0
				r = fn(a)
				r += fn(a)
				return (if r > 0 then fn(r) else 0) + ({ fn(a) })[1]
			end
			return ifApply(abs, -3)
				+ forApply(abs, -1)
				+ whileApply(abs, -2)
				+ repeatApply(abs, -2)
				+ forInApply(abs, { -1, -2 })
				+ exprApply(abs, -4)
		]]
		local dumpInline, inlineRes = disassemble(inlineSrc, { optimizationLevel = 2 })
		sert.eq(inlineRes.status, "ok")
		expect(string.find(dumpInline, "inlining succeeded", 1, true) ~= nil, "inlined helper with builtin parameter")
		local inlineFn = assert(VM.loadBytecode(inlineRes.bytecode, { name = "=inline_builtins" }))
		sert.eq(inlineFn(), 31)

		-- Exported variables compile cleanly when not conflicting with top-level return
		local exportRes = Compiler.compileResult(
			[[
			export local ex = 10
			export local ey = 20
			export local sum = ex + ey
		]],
			{
				optimizationLevel = 2,
				parseOptions = { profile = "experimental" },
				flags = { LuauOptimizeExportTable = true },
			}
		)
		sert.eq(exportRes.status, "ok")

		local expNoClassProfile = table.clone(Parser.Profiles.resolve("experimental"))
		expNoClassProfile.DebugLuauUserDefinedClasses = false

		-- Experimental table constructor call and while local/const compile & execute cleanly
		local expRes = Compiler.compileResult(
			[[
			local function take(t: { x: number }): number
				return t.x
			end
			local items = { 2, 3, 4 }
			local acc = 0
			while local v = table.remove(items) do
				acc += v
			end
			local items2 = { 1, 5 }
			while const c = table.remove(items2) do
				acc += c
			end
			return take { x = 7 } + acc
		]],
			{
				optimizationLevel = 2,
				parseOptions = { profile = expNoClassProfile },
				flags = {
					LuauCompileRequireNoInline = true,
					LuauCompileCapturedCallTarget = true,
					LuauCompileLoopUnrollNegativeZero = true,
				},
			}
		)
		sert.eq(expRes.status, "ok")
		local expFn = assert(VM.loadBytecode(expRes.bytecode, { name = "=while_local_exec" }))
		sert.eq(expFn(), 22)

		-- Verify LuauCompileRequireNoInline inhibits LPF_INLINABLE on functions calling require
		local reqRes = assert(BytecodeCodec.deserialize(assert(Compiler.compile(
			[[
			local function f()
				return require("./mod")
			end
			return f
		]],
			{ optimizationLevel = 2, flags = { LuauCompileRequireNoInline = true } }
		))))
		sert.eq(bit32.band(reqRes.protos[1].flags, BytecodeDefs.ProtoFlags.LPF_INLINABLE), 0)

		-- Verify BytecodeEncoder retention across compile and compileResult, and rejection in compileProto
		local encodedCount = 0
		local encoderFn = function(op: number): number
			encodedCount += 1
			return bit32.band(bit32.bxor(op, 0x15), 0xff)
		end
		local rawUnencoded = assert(Compiler.compile("return 40 + 2", { optimizationLevel = 2 }))
		local rawEncoded = assert(Compiler.compile("return 40 + 2", { optimizationLevel = 2, encoder = encoderFn }))
		expect(encodedCount > 0 and rawEncoded ~= rawUnencoded, "encoder transforms compiled bytecode")
		local resEncoded = Compiler.compileResult("return 40 + 2", { optimizationLevel = 2, encoder = encoderFn })
		sert.eq(resEncoded.bytecode, rawEncoded)
		local canonicalProto = assert(resEncoded.builder, "compileResult retains canonical builder"):toProtoModule()
		sert.eq(
			BytecodeCodec.insnOp(assert(BytecodeCodec.deserialize(rawEncoded)).protos[1].code[1]),
			bit32.bxor(BytecodeCodec.insnOp(canonicalProto.protos[1].code[1]), 0x15)
		)
		local okProtoEnc, errProtoEnc = pcall(
			Compiler.compileProto,
			"return 40 + 2",
			{ optimizationLevel = 2, encoder = encoderFn } :: Compiler.CompileOptions
		)
		sert.eq(okProtoEnc, false)
		expect(
			string.find(tostring(errProtoEnc), "Invalid CompileOptions.encoder", 1, true) ~= nil,
			tostring(errProtoEnc)
		)

		-- Standard tail multi-return and table call execute identically at O1 and O2
		local extraSrc = [[
			local function pair(): (number, number)
				return 3, 4
			end
			local function take(t: { x: number }): number
				return t.x
			end
			local function tailSum(): ...number
				return 1, pair()
			end
			local a, b, c = tailSum()
			return 30 + take { x = 7 } + a + b + c
		]]
		for _, opt in { 1, 2 } do
			local extraBc = assert(Compiler.compile(extraSrc, {
				optimizationLevel = opt,
			}))
			local extraFn = assert(VM.loadBytecode(extraBc, { name = "=extra_compiler_cov_o" .. tostring(opt) }))
			sert.eq(extraFn(), 45)
		end

		-- Inlined helper capturing an upvalue must keep nonLexicalUse = true across popStatLocals at O2
		local inlinedUpvalSrc = [[
			local helper = { tag = 10 }
			local function make(a, b)
				return { tag = helper.tag, a = a, b = b }
			end
			local function wrap(x)
				return make(x, x + 1)
			end
			return wrap(5).tag + wrap(5).b
		]]
		local inlinedUpvalRes = Compiler.compileResult(inlinedUpvalSrc, {
			optimizationLevel = 2,
		})
		sert.eq(inlinedUpvalRes.status, "ok")
		local inlinedUpvalFn = assert(VM.loadBytecode(inlinedUpvalRes.bytecode, { name = "=inlined_upval_o2" }))
		sert.eq(inlinedUpvalFn(), 16)

		-- Reassigning a while-local binding must initialize its tracked variable entry cleanly at O2
		local whileAssignRes = Compiler.compileResult(
			[[
			local seen = 0
			local n = 0
			local function nextItem(): number?
				n += 1
				if n <= 2 then
					return n
				end
				return nil
			end
			while local x = nextItem() do
				x += 10
				seen += x
			end
			return seen
		]],
			{
				optimizationLevel = 2,
				parseOptions = { profile = expNoClassProfile },
			}
		)
		sert.eq(whileAssignRes.status, "ok")
		local whileAssignFn = assert(VM.loadBytecode(whileAssignRes.bytecode, { name = "=while_local_assign_o2" }))
		sert.eq(whileAssignFn(), 23)

		-- Reject unknown flags and non-boolean flag values in CompileOptions.flags
		sert.throws(function()
			Compiler.compile("return 1", { flags = { UnknownCompilerFlag = true } })
		end, "Unknown")
		sert.throws(function()
			Compiler.compile("return 1", { flags = { LuauCompileTableFoldFix = "yes" :: any } })
		end, "Invalid compiler flag value")
	end)

	test(
		"enforces 0.748 table escape, builtin flags, math constants, _G mutability, folding, and clean arena",
		function()
			-- 1. BuiltinInfo flags and math constant conformance
			sert.eq(CompilerBuiltins.getBuiltinInfo(Builtins.LBF_GETMETATABLE).flags, 0)
			sert.eq(CompilerBuiltins.getBuiltinInfo(Builtins.LBF_RAWGET).flags, 0)
			sert.eq(CompilerBuiltins.getBuiltinInfo(Builtins.LBF_RAWEQUAL).flags, 0)
			sert.eq(CompilerBuiltins.getBuiltinInfo(Builtins.LBF_SETMETATABLE).flags, 0)
			sert.eq(CompilerBuiltins.getBuiltinInfo(Builtins.LBF_RAWSET).flags, 0)
			sert.eq(CompilerBuiltins.getBuiltinInfo(Builtins.LBF_VECTOR_MIN).params, -1)
			sert.eq(CompilerBuiltins.getBuiltinInfo(Builtins.LBF_VECTOR_MIN).flags, 0)
			sert.eq(CompilerBuiltins.getBuiltinInfo(Builtins.LBF_VECTOR_MAX).params, -1)
			sert.eq(CompilerBuiltins.getBuiltinInfo(Builtins.LBF_VECTOR_MAX).flags, 0)
			sert.eq(CompilerBuiltins.getBuiltinInfo(Builtins.LBF_TABLE_INSERT).results, 0)
			sert.eq(CompilerBuiltins.foldBuiltinMath("halfpi").type, CompilerBuiltins.ConstantType.Unknown)
			sert.eq(CompilerBuiltins.foldBuiltinMath("quarterpi").type, CompilerBuiltins.ConstantType.Unknown)
			sert.eq(CompilerBuiltins.foldBuiltinMath("sqrt3").type, CompilerBuiltins.ConstantType.Unknown)
			sert.eq(CompilerBuiltins.foldBuiltinMath("twopi").type, CompilerBuiltins.ConstantType.Unknown)

			-- 2. Table mutation tracking rules (self-call, subexpr, AstStatFunction)
			local mutSrc = [[
			local t1 = { x = 1, m = function(self) self.x = 2 end }
			t1:m()
			local t2 = { a = 1 }
			local function mut(tbl) tbl.a = 9; return tbl end
			mut(t2).b = 2
			local t3 = { f = function() return 1 end }
			function t3.f() return 3 end
			return t1.x, t2.a, t3.f()
		]]
			local mutFn = assert(
				VM.loadBytecode(assert(Compiler.compile(mutSrc, { optimizationLevel = 2 })), { name = "=tbl_mut" })
			)
			local r1, r2, r3 = mutFn()
			sert.eq(r1, 2)
			sert.eq(r2, 9)
			sert.eq(r3, 3)

			-- 3. Unconditional _G mutability across reads at O2
			local gEnv = VM.createEnvironment({})
			gEnv._G = gEnv
			gEnv.readG = function()
				return gEnv._G.foo
			end
			local gFn = assert(
				VM.loadBytecode(
					assert(
						Compiler.compile(
							"_G.foo = 10; local a = _G.foo; _G.foo = 20; return a, readG()",
							{ optimizationLevel = 2 }
						)
					),
					{ name = "=g_mut", env = gEnv }
				)
			)
			local g1, g2 = gFn()
			sert.eq(g1, 10)
			sert.eq(g2, 20)

			-- 4. None-unsafe and trailing multi-return fastcall checks
			local noneSrc = [[
			local function none() end
			local ok1 = pcall(getmetatable, none())
			local ok2 = pcall(rawget, {}, none())
			local function two() return vector.create(1, 2, 3), vector.create(0, 5, 0) end
			local vmin = vector.min(vector.create(4, 4, 4), two())
			return ok1, ok2, vmin.X, vmin.Y, vmin.Z
		]]
			local noneFn = assert(
				VM.loadBytecode(assert(Compiler.compile(noneSrc, { optimizationLevel = 2 })), { name = "=none_safe" })
			)
			local n1, n2, vx, vy, vz = noneFn()
			sert.eq(n1, false)
			sert.eq(n2, false)
			sert.eq(vx, 0)
			sert.eq(vy, 2)
			sert.eq(vz, 0)

			-- 5. Local math alias, disabledBuiltins by bfid, interp folding, short-circuit, multi-var local, bit32 wrap
			local aliasBc = assert(
				Compiler.compile(
					"local m = math; local a = math or {}; return function(x, y) return m.abs(x), a.floor(y) end",
					{ optimizationLevel = 2 }
				)
			)
			local aliasMod = assert(BytecodeCodec.deserialize(aliasBc))
			local sawAbsFastcall = false
			local sawFloorFastcall = false
			for _, proto in aliasMod.protos do
				for _, word in proto.code do
					local op = BytecodeCodec.insnOp(word)
					if op == Opcodes.LOP_FASTCALL1 then
						local bfid = BytecodeCodec.insnA(word)
						if bfid == Builtins.LBF_MATH_ABS then
							sawAbsFastcall = true
						elseif bfid == Builtins.LBF_MATH_FLOOR then
							sawFloorFastcall = true
						end
					end
				end
			end
			expect(sawAbsFastcall, "local library alias m.abs lowers to FASTCALL1 LBF_MATH_ABS")
			expect(sawFloorFastcall, "local library alias a.floor lowers to FASTCALL1 LBF_MATH_FLOOR")
			local aliasFactory = assert(VM.loadBytecode(aliasBc, { name = "=alias" }))
			local aliasFn = aliasFactory()
			local al1, al2 = aliasFn(-7, 3.9)
			sert.eq(al1, 7)
			sert.eq(al2, 3)

			local disMod = assert(
				BytecodeCodec.deserialize(
					assert(
						Compiler.compile(
							"local m = math; local abs = math.abs; return function(x, y) return m.abs(x), abs(y) end",
							{ optimizationLevel = 2, disabledBuiltins = { "math.abs" } }
						)
					)
				)
			)
			local disHasCall = false
			for _, proto in disMod.protos do
				for _, word in proto.code do
					local op = BytecodeCodec.insnOp(word)
					expect(
						op ~= Opcodes.LOP_FASTCALL and op ~= Opcodes.LOP_FASTCALL1,
						"disabledBuiltins blocks resolved alias bfid"
					)
					if op == Opcodes.LOP_CALL then
						disHasCall = true
					end
				end
			end
			expect(disHasCall, "disabledBuiltins emits LOP_CALL for runtime calls")

			local interpConstSrc = "return `hello {'world'}`"
			local interpMod =
				assert(BytecodeCodec.deserialize(assert(Compiler.compile(interpConstSrc, { optimizationLevel = 2 }))))
			sert.eq(interpMod.protos[1].kValues[1], "hello world")

			local foldMiscSrc = [[
			local calls = 0
			local function f() calls += 1; return 99 end
			local sc1 = false and f()
			local sc2 = true or f()
			local mv1, mv2 = math.abs(-5)
			local b = bit32.band(2^32 + 1, 1)
			local vadd = vector.create(1, 2, 3, 4) + vector.create(1, 1, 1, 1)
			local neg = 0
			if f() and false then neg = 10 else neg = 20 end
			return sc1, sc2, calls, mv1, mv2, b, neg, vadd.X
		]]
			local foldFn = assert(
				VM.loadBytecode(
					assert(Compiler.compile(foldMiscSrc, { optimizationLevel = 2 })),
					{ name = "=fold_misc" }
				)
			)
			local fc1, fc2, fcalls, fmv1, fmv2, fb, fneg, fvx = foldFn()
			sert.eq(fc1, false)
			sert.eq(fc2, true)
			sert.eq(fcalls, 1)
			sert.eq(fmv1, 5)
			sert.eq(fmv2, nil)
			sert.eq(fb, 1)
			sert.eq(fneg, 20)
			sert.eq(fvx, 2)

			-- 6. Experimental if-local false branch
			local ifNoClassProfile = table.clone(Parser.Profiles.resolve("experimental"))
			ifNoClassProfile.DebugLuauUserDefinedClasses = false
			local ifLocFalseBc = assert(Compiler.compile("if local x = false then return 1 else return 2 end", {
				optimizationLevel = 2,
				parseOptions = { profile = ifNoClassProfile },
			}))
			local ifLocFn = assert(VM.loadBytecode(ifLocFalseBc, { name = "=if_loc_false" }))
			sert.eq(ifLocFn(), 2)

			-- 7. Caller ParseResult.arena remains unmutated on both compile success and compile error
			local errPr = Parser.parse(
				"export const expVal = 1\nrepeat local a = 1; if a > 0 then continue end; local b = 2 until b == 2",
				{ profile = "experimental" }
			)
			local origNodes = #errPr.arena.nodes
			local origBindings = #errPr.arena.bindings
			local origSymbols = #errPr.arena.symbols
			local symMap = (errPr.arena :: any).symbolMap :: { [string]: number }?
			local hadExpSymBefore = if symMap then symMap["__EXP"] ~= nil else false
			local errRes = Compiler.compileResult(errPr)
			sert.eq(errRes.status, "compileError")
			sert.eq(#errPr.arena.nodes, origNodes)
			sert.eq(#errPr.arena.bindings, origBindings)
			sert.eq(#errPr.arena.symbols, origSymbols)
			if symMap and not hadExpSymBefore then
				sert.eq(symMap["__EXP"], nil)
			end

			local okPr =
				Parser.parse("export const okVal = 7\nexport local okVal2 = okVal + 1", { profile = "experimental" })
			local okNodes = #okPr.arena.nodes
			local okBindings = #okPr.arena.bindings
			local okSymbols = #okPr.arena.symbols
			local okRes = Compiler.compileResult(okPr)
			sert.eq(okRes.status, "ok")
			sert.eq(#okPr.arena.nodes, okNodes)
			sert.eq(#okPr.arena.bindings, okBindings)
			sert.eq(#okPr.arena.symbols, okSymbols)
			-- 8. Unrolled loop constant isolation across repeated loops
			local unrollSrc = [[
			local function calc(k: number): number
				local s = 0
				for i = 1, 3 do
					s += (i + k)
				end
				for i = 1, 2 do
					s += i * 10
				end
				return s
			end
			return calc(5), calc(-2)
		]]
			local unrollBc = assert(Compiler.compile(unrollSrc, { optimizationLevel = 2 }))
			local unrollFn = assert(VM.loadBytecode(unrollBc, { name = "=unroll_iso" }))
			local u1, u2 = unrollFn()
			sert.eq(u1, (6 + 7 + 8) + 30)
			sert.eq(u2, (-1 + 0 + 1) + 30)
		end
	)

	test(
		"covers cancelled/fragment ParseResult, O2 bugfix flags, sparse userdataTypes, wildcard disabledBuiltins, CompileConstant kinds, bit32.btest, numeric bounds, detectFastPcall, and class sibling capture isolation",
		function()
			-- 1. Cancelled & fragment ParseResult rejected cleanly
			local cancelRes = Parser.parse("return 1", {
				checkpointInterval = 1,
				checkpoint = function()
					return false
				end,
			})
			sert.eq(cancelRes.status, "cancelled")
			local cancelBc, cancelErr = Compiler.compile(cancelRes)
			sert.eq(cancelBc, nil)
			expect(string.find(assert(cancelErr), "cancelled", 1, true) ~= nil, tostring(cancelErr))
			sert.eq(Compiler.compileResult(cancelRes).status, "parseError")

			local fragRes = Parser.parseExpression("1 + 2")
			local fragBc, fragErr = Compiler.compile(fragRes)
			sert.eq(fragBc, nil)
			expect(string.find(assert(fragErr), "AstStatBlock", 1, true) ~= nil, tostring(fragErr))
			sert.eq(Compiler.compileResult(fragRes).status, "parseError")

			-- 2. Default compiler bugfix flags and O2 -0.0 loop unroll (explicit opt-in overrides)
			sert.eq(Compiler.CompilerFlags.LuauCompileCapturedCallTarget, false)
			sert.eq(Compiler.CompilerFlags.LuauCompileLoopUnrollNegativeZero, false)
			sert.eq(Compiler.CompilerFlags.LuauCompileTableFoldFix, false)

			local negZeroLoopSrc = [[
			local out = {}
			for i = -0.0, 0, 1 do
				out[#out + 1] = 1 / i
			end
			return #out, out[1] == -math.huge
		]]
			local nzFn = assert(
				VM.loadBytecode(
					assert(
						Compiler.compile(
							negZeroLoopSrc,
							{ optimizationLevel = 2, flags = { LuauCompileLoopUnrollNegativeZero = true } }
						)
					),
					{ name = "=nz_unroll" }
				)
			)
			local nzLen, nzNeg = nzFn()
			sert.eq(nzLen, 1)
			sert.eq(nzNeg, true)

			local capCallSrc = [[
			local f = function() return 1 end
			local function mut() f = function() return 2 end end
			mut()
			return f()
		]]
			local capCallFn = assert(
				VM.loadBytecode(
					assert(
						Compiler.compile(
							capCallSrc,
							{ optimizationLevel = 2, flags = { LuauCompileCapturedCallTarget = true } }
						)
					),
					{ name = "=cap_call" }
				)
			)
			sert.eq(capCallFn(), 2)

			local tblFoldSrc = "return ({ x = 1, x = 2 }).x"
			local tblFoldFn = assert(
				VM.loadBytecode(
					assert(
						Compiler.compile(
							tblFoldSrc,
							{ optimizationLevel = 2, flags = { LuauCompileTableFoldFix = true } }
						)
					),
					{ name = "=tbl_fold" }
				)
			)
			sert.eq(tblFoldFn(), 2)

			-- 3. Sparse userdataTypes (slot 1 unused, slot 2 used)
			local udMod = assert(Compiler.compileProto(
				[[
			local function f(u: UsedUD)
				return u
			end
			return f
		]],
				{
					optimizationLevel = 2,
					typeInfoLevel = 1,
					userdataTypes = { "UnusedUD", "UsedUD" },
				}
			))
			expect(udMod.userdataTypes ~= nil, "sparse userdataTypes retained")
			sert.eq((udMod.userdataTypes :: any)[1], "UsedUD")

			-- 4. disabledBuiltins wildcards ("*" and "math.*"), plus local math mutation
			for _, disPattern in { "*", "math.*" } do
				local wildBc = assert(
					Compiler.compile(
						"local abs = math.abs; return function(x, y) return math.abs(x), abs(y) end",
						{ optimizationLevel = 2, disabledBuiltins = { disPattern } }
					)
				)
				local wildMod = assert(BytecodeCodec.deserialize(wildBc))
				local wildCalls = 0
				for _, proto in wildMod.protos do
					for _, word in proto.code do
						local op = BytecodeCodec.insnOp(word)
						expect(
							op ~= Opcodes.LOP_FASTCALL and op ~= Opcodes.LOP_FASTCALL1,
							`wildcard {disPattern} disables fastcall`
						)
						if op == Opcodes.LOP_CALL or op == Opcodes.LOP_CALLFB then
							wildCalls += 1
						end
					end
				end
				sert.eq(wildCalls, 2)
			end

			local mutMathBc = assert(
				Compiler.compile(
					"math = { abs = function(x) return x end }; return (function(v) return math.abs(v) end)(-9)",
					{ optimizationLevel = 2 }
				)
			)
			local mutMathMod = assert(BytecodeCodec.deserialize(mutMathBc))
			local mutHasCall = false
			for _, proto in mutMathMod.protos do
				for _, word in proto.code do
					local op = BytecodeCodec.insnOp(word)
					expect(op ~= Opcodes.LOP_FASTCALL1, "mutated math global disables math builtin folding/fastcall")
					if op == Opcodes.LOP_CALL then
						mutHasCall = true
					end
				end
			end
			expect(mutHasCall, "mutated math global emits runtime LOP_CALL")
			local mutMathFn = assert(VM.loadProto(mutMathMod, { name = "=mut_math_runtime" }))
			sert.eq(mutMathFn(), -9)

			-- 5. All string-tagged CompileConstant variants with librariesWithKnownMembers
			local constBc = assert(
				Compiler.compile(
					"return CustomK.kNil == nil, CustomK.kBool, CustomK.kNum, CustomK.kStr, CustomK.kVecF.X, CustomK.kVecD.Y, CustomK.kTbl",
					{
						optimizationLevel = 2,
						librariesWithKnownMembers = { "CustomK" },
						libraryMemberConstantCb = function(_lib: string, member: string): PublicTypes.CompileConstant?
							if member == "kNil" then
								return { type = "nil" } :: PublicTypes.CompileConstant
							elseif member == "kBool" then
								return { type = "boolean", value = true } :: PublicTypes.CompileConstant
							elseif member == "kNum" then
								return { type = "number", value = 123 } :: PublicTypes.CompileConstant
							elseif member == "kStr" then
								return { type = "string", value = "hi" } :: PublicTypes.CompileConstant
							elseif member == "kVecF" then
								return { type = "vectorf", value = { 7, 8, 9 } } :: PublicTypes.CompileConstant
							elseif member == "kVecD" then
								return { type = "vectord", value = { 1, 2, 3 } } :: PublicTypes.CompileConstant
							elseif member == "kTbl" then
								return { type = "table", value = {} } :: PublicTypes.CompileConstant
							end
							return nil
						end,
					}
				)
			)
			local constFn = assert(VM.loadBytecode(constBc, {
				name = "=const_cb",
				env = VM.createEnvironment({ CustomK = { kTbl = "liveTbl" } }),
			}))
			local cNil, cBool, cNum, cStr, cVf, cVd, cTbl = constFn()
			sert.eq(cNil, true)
			sert.eq(cBool, true)
			sert.eq(cNum, 123)
			sert.eq(cStr, "hi")
			sert.eq(cVf, 7)
			sert.eq(cVd, 2)
			sert.eq(cTbl, "liveTbl")

			-- 6. bit32.btest number typeinfo, foldStringSub / bit32Rotate NaN & int32 bounds, detectFastPcall
			local btestMod = assert(Compiler.compileProto(
				[[
			local function testBit(x: number)
				local b = bit32.btest(x, 1)
				return b
			end
			return testBit
		]],
				{ optimizationLevel = 2, typeInfoLevel = 1 }
			))
			local testBitProto = btestMod.protos[1]
			local tinfo = assert(testBitProto.typeinfo, "bit32.btest proto must emit typeinfo")
			local function readVarInt(blob: string, p: number): (number, number)
				local v, shift = 0, 0
				repeat
					local bByte = string.byte(blob, p)
					p += 1
					v += bit32.lshift(bit32.band(bByte, 0x7f), shift)
					shift += 7
				until bByte < 0x80
				return v, p
			end
			local rawLen, tPos = readVarInt(tinfo, 1)
			local upvCnt: number
			upvCnt, tPos = readVarInt(tinfo, tPos)
			local locCnt: number
			locCnt, tPos = readVarInt(tinfo, tPos)
			tPos += rawLen + upvCnt
			sert.eq(locCnt, 1)
			sert.eq(string.byte(tinfo, tPos), BytecodeTypes.LBC_TYPE_NUMBER, "local b inferred as LBC_TYPE_NUMBER")
			expect(
				string.find(
					BytecodeDisassembler.disassemble(btestMod, BytecodeBuilder.DumpFlags.Types),
					"number",
					1,
					true
				) ~= nil,
				"disassembly prints number typeinfo"
			)

			local edgeSrc = [[
			local a = string.sub("abcdef", 0 / 0, 2)
			local b = string.sub("abcdef", 2, 1000000000000)
			local c = bit32.lrotate(1, 1000000000000)
			local d = bit32.rrotate(8, -1000000000000)
			return a, b, c, d
		]]
			local fnEdge0 = assert(
				VM.loadBytecode(assert(Compiler.compile(edgeSrc, { optimizationLevel = 0 })), { name = "=edge0" })
			)
			local fnEdge2 = assert(
				VM.loadBytecode(assert(Compiler.compile(edgeSrc, { optimizationLevel = 2 })), { name = "=edge2" })
			)
			local e0a, e0b, e0c, e0d = fnEdge0()
			local e2a, e2b, e2c, e2d = fnEdge2()
			sert.eq(e2a, e0a)
			sert.eq(e2b, e0b)
			sert.eq(e2c, e0c)
			sert.eq(e2d, e0d)

			local mutPcallMod = assert(
				Compiler.compileProto(
					"return pcall(function() return 1 end)",
					{ optimizationLevel = 2, mutableGlobals = { "pcall" } }
				)
			)
			local sawFastPcall = false
			for _, word in mutPcallMod.protos[mutPcallMod.mainid + 1].code do
				if BytecodeCodec.insnOp(word) == Opcodes.LOP_FASTPCALL then
					sawFastPcall = true
				end
			end
			expect(sawFastPcall, "mutableGlobals permits detectFastPcall matching upstream canImport")

			local writtenPcallMod = assert(
				Compiler.compileProto(
					"pcall = function(f) return true, f() end; return pcall(function() return 1 end)",
					{ optimizationLevel = 2 }
				)
			)
			for _, word in writtenPcallMod.protos[writtenPcallMod.mainid + 1].code do
				expect(BytecodeCodec.insnOp(word) ~= Opcodes.LOP_FASTPCALL, "written pcall blocks detectFastPcall")
			end

			-- 7. CompilerClass sibling method capture isolation + nested closure private capture
			local siblingMod = assert(Compiler.compileProto(
				[[
			class SibBox
				private _sec: number
				public pub: number
				private function _m1(self)
					return self._sec
				end
				public function m2(self)
					return self.pub
				end
				public function m3(self)
					return function()
						return self._sec
					end
				end
			end
		]],
				{
					optimizationLevel = 2,
					parseOptions = { profile = "experimental" },
				}
			))
			expect(#siblingMod.protos >= 4, "sibling class methods compile cleanly")
			local sawPrivateM1 = false
			local sawPublicM2 = false
			local sawInnerCapture = false
			local sawGetPrivate = false
			for _, proto in siblingMod.protos do
				if proto.debugname == "_m1" then
					sawPrivateM1 = true
					sert.eq(proto.nups, 1, "_m1 accessing self._sec captures enclosing class")
				elseif proto.debugname == "m2" then
					sawPublicM2 = true
					sert.eq(proto.nups, 0, "sibling method without private access does not capture upvalues")
				elseif proto.debugname == "m3" then
					sert.eq(proto.nups, 1, "m3 forwards class upvalue to nested closure")
				elseif proto.debugname == nil and proto.nups == 2 then
					sawInnerCapture = true
				end
				for _, word in proto.code do
					if BytecodeCodec.insnOp(word) == Opcodes.LOP_GETPRIVATEFIELD then
						sawGetPrivate = true
					end
				end
			end
			expect(sawPrivateM1, "compiled private _m1 proto")
			expect(sawPublicM2, "compiled sibling public m2 proto")
			expect(sawInnerCapture, "compiled nested closure capturing self")
			expect(sawGetPrivate, "sibling and nested private captures emit GETPRIVATEFIELD")
		end
	)

	test(
		"enforces 0.748 table equality folding, nested library constants, userdata type callbacks, hotcomments, global vectorCtor, and options validation",
		function()
			-- 1. Cfg.opts == Cfg.opts from libraryMemberConstantCb must NOT fold, while local t == t DOES fold
			local libEqMod = assert(Compiler.compileProto("return Cfg.opts == Cfg.opts", {
				optimizationLevel = 2,
				librariesWithKnownMembers = { "Cfg" },
				libraryMemberConstantCb = function(lib: string, member: string): PublicTypes.CompileConstant?
					if lib == "Cfg" and member == "opts" then
						return { type = "table", value = { a = { type = "number", value = 1 } } }
					end
					return nil
				end,
			}))
			local sawJumpEq = false
			for _, word in libEqMod.protos[1].code do
				local op = BytecodeCodec.insnOp(word)
				if op == Opcodes.LOP_JUMPIFEQ or op == Opcodes.LOP_JUMPIFNOTEQ then
					sawJumpEq = true
				end
			end
			expect(sawJumpEq, "libraryMemberConstantCb table comparison does not constant-fold")
			local liveCfgFn = assert(VM.loadProto(libEqMod, {
				name = "=cfg_eq",
				env = VM.createEnvironment({ Cfg = { opts = { a = 1 } } }),
			}))
			sert.eq(liveCfgFn(), true)

			local localTblEqDump, localTblEqRes = disassemble("local t = { a = 1 }; return t == t", {
				optimizationLevel = 2,
			})
			expect(string.find(localTblEqDump, "LOADB R%d+ 1\n") ~= nil, "local t == t folds to true")
			local localTblFn = assert(VM.loadBytecode(localTblEqRes.bytecode, { name = "=local_tbl_eq" }))
			sert.eq(localTblFn(), true)

			-- 2. tryIndexConstantTable with unknown key + nested vector coercion in libraryMemberConstantCb
			local unkIdxFn = assert(VM.load("local u; local t = { a = 1 }; return t[u]", { name = "=unk_idx" }))
			sert.eq(unkIdxFn(), nil)

			local function compileNestedVec(prec: number): number
				local bc = assert(Compiler.compile("return CustomV.bag.vec.X", {
					optimizationLevel = 2,
					vectorPrecision = prec,
					librariesWithKnownMembers = { "CustomV" },
					libraryMemberConstantCb = function(lib: string, member: string): PublicTypes.CompileConstant?
						if lib == "CustomV" and member == "bag" then
							return {
								type = "table",
								value = {
									vec = { type = "vectorf", value = { 0.1, 0.2, 0.3 } },
								},
							}
						end
						return nil
					end,
				}))
				local fn = assert(VM.loadBytecode(bc, { name = "=nested_vec_" .. tostring(prec) }))
				return fn()
			end
			local vf = compileNestedVec(0)
			local vd = compileNestedVec(1)
			expect(vf ~= 0.1 and math.abs(vf - 0.1) < 1e-6, "vectorPrecision = 0 rounds nested vectorf to f32")
			sert.eq(vd, 0.1, "vectorPrecision = 1 coerces nested vectorf to exact f64")

			-- 3. libraryMemberTypeCb tagged userdata marks userdataTypes used even without annotation in source
			local udCbMod = assert(
				Compiler.compileProto(
					"local UnusedUD, HandleUD = 1, 2; local v = Ext.handle; return v, UnusedUD, HandleUD",
					{
						optimizationLevel = 2,
						typeInfoLevel = 1,
						userdataTypes = { "UnusedUD", "HandleUD" },
						librariesWithKnownMembers = { "Ext" },
						libraryMemberTypeCb = function(lib: string, member: string): number
							if lib == "Ext" and member == "handle" then
								return BytecodeTypes.LBC_TYPE_TAGGED_USERDATA_BASE + 1
							end
							return BytecodeTypes.LBC_TYPE_ANY
						end,
					}
				)
			)
			expect(udCbMod.userdataTypes ~= nil, "libraryMemberTypeCb userdata retained")
			local udList = assert(udCbMod.userdataTypes) :: any
			sert.eq(udList[1], nil)
			sert.eq(udList[2], "HandleUD")

			-- 4. CompileOptions validation, explicit LuauCompileLoopUnrollNegativeZero = false, compileResult bad inputs,
			--    --!optimize 0/2 hotcomments, and global (no-lib) vectorCtor
			local badOptCases: { { name: string, opts: any, match: string } } = {
				{ name = "non-table options", opts = 123, match = "expected table" },
				{ name = "NaN optimizationLevel", opts = { optimizationLevel = 0 / 0 }, match = "optimizationLevel" },
				{ name = "negative optimizationLevel", opts = { optimizationLevel = -1 }, match = "optimizationLevel" },
				{ name = "OOB optimizationLevel", opts = { optimizationLevel = 3 }, match = "optimizationLevel" },
				{ name = "OOB debugLevel", opts = { debugLevel = 3 }, match = "debugLevel" },
				{ name = "OOB typeInfoLevel", opts = { typeInfoLevel = 2 }, match = "typeInfoLevel" },
				{ name = "OOB coverageLevel", opts = { coverageLevel = 3 }, match = "coverageLevel" },
				{ name = "OOB vectorPrecision", opts = { vectorPrecision = 2 }, match = "vectorPrecision" },
				{ name = "invalid encoder", opts = { encoder = "bad" }, match = "Invalid CompileOptions.encoder" },
				{ name = "non-table flags", opts = { flags = "bad" }, match = "Invalid CompileOptions.flags" },
			}
			for _, tc in badOptCases do
				sert.throws(function()
					Compiler.compile("return 1", tc.opts)
				end, tc.match)
			end

			local nzOffFn = assert(
				VM.loadBytecode(
					assert(Compiler.compile(
						[[
					local out = {}
					for i = -0.0, 0, 1 do
						out[#out + 1] = 1 / i
					end
					return #out, out[1] == math.huge
				]],
						{ optimizationLevel = 2, flags = { LuauCompileLoopUnrollNegativeZero = false } }
					)),
					{ name = "=nz_off" }
				)
			)
			local nzOffLen, nzOffSign = nzOffFn()
			sert.eq(nzOffLen, 1)
			sert.eq(nzOffSign, true)

			sert.throws(function()
				Compiler.compileResult(123 :: any)
			end, "Expected source string or ParseResult table")
			local exprRes = Compiler.compileResult(Parser.parseExpression("1 + 2"))
			sert.eq(exprRes.status, "parseError")
			expect(string.find(exprRes.error or "", "AstStatBlock", 1, true) ~= nil, tostring(exprRes.error))

			local hotO0 = disassemble("--!optimize 0\nreturn math.abs(-7)", { optimizationLevel = 2 })
			expect(
				string.find(hotO0, "GETGLOBAL", 1, true) ~= nil and string.find(hotO0, "LOADN R0 7", 1, true) == nil,
				"--!optimize 0 overrides optimizationLevel=2"
			)
			local hotO2 = disassemble("--!optimize 2\nreturn math.abs(-7)", { optimizationLevel = 0 })
			expect(string.find(hotO2, "LOADN R0 7", 1, true) ~= nil, "--!optimize 2 overrides optimizationLevel=0")

			local globalVecMod = assert(
				Compiler.compileProto(
					"local function f(x, y, z) return vec3(x, y, z) end\nreturn f",
					{ optimizationLevel = 2, vectorCtor = "vec3" }
				)
			)
			local sawGlobalVecFastcall = false
			for _, word in globalVecMod.protos[1].code do
				if
					BytecodeCodec.insnOp(word) == Opcodes.LOP_FASTCALL3
					and BytecodeCodec.insnA(word) == Builtins.LBF_VECTOR
				then
					sawGlobalVecFastcall = true
				end
			end
			expect(sawGlobalVecFastcall, "global vectorCtor without vectorLib emits LBF_VECTOR FASTCALL3")
		end
	)

	test(
		"accepts upstream O0/O2 parity flags, aliased/fallback inlined builtins, bit32 extra args, alias disabledBuiltins, and jump bounds",
		function()
			-- 1. Valid CompilerFlags accepted; removed/unknown flags rejected
			local flagRes = Compiler.compileResult("local x = true; return x", {
				flags = {
					LuauCompileCapturedCallTarget = true,
					LuauCompileTableFoldFix = true,
				},
			})
			sert.eq(flagRes.status, "ok")
			sert.throws(function()
				Compiler.compileResult("return 1", { flags = { LuauInlinerNamecallSelfFromMove = true } :: any })
			end, "Unknown compiler flag")
			sert.throws(function()
				Compiler.compileResult("return 1", { flags = { LuauBytecodeLoadbSkip = true } :: any })
			end, "Unknown compiler flag")

			-- 2. Aliased and fallback inlined builtins resolve at O2
			local aliasSrc = [[
local function apply(fn, v) return fn(v) end
return function(x)
	local m = math
	local f = m.abs
	local a = apply(f, x)
	local m2 = math or {}
	local b = apply(m2.abs, x - 3)
	return a, b
end
]]
			local aliasDisasm = disassemble(aliasSrc, { optimizationLevel = 2 })
			local hasFastcallAbs = string.find(aliasDisasm, "FASTCALL", 1, true) ~= nil
			expect(
				hasFastcallAbs,
				"aliased/fallback inlined math.abs should lower via fastcall at O2:\n" .. aliasDisasm
			)
			local aliasLoader = assert(
				VM.loadBytecode(assert(Compiler.compile(aliasSrc, { optimizationLevel = 2 })), { name = "=alias" })
			)
			local a, b = aliasLoader()(-9)
			sert.eq(a, 9)
			sert.eq(b, 12)

			-- 3. bit32.extract(>3 args) and bit32.replace(>4 args) fold extra constant args
			local bitFoldSrc = [[
local ex = bit32.extract(0xABCD, 4, 8, 999)
local rep = bit32.replace(0x1111, 0xA, 4, 4, 999)
return ex, rep
]]
			local bitDisasm = disassemble(bitFoldSrc, { optimizationLevel = 2 })
			expect(
				string.find(bitDisasm, "FASTCALL", 1, true) == nil,
				"extra-arg bit32 calls should fold away:\n" .. bitDisasm
			)
			local bitFn = assert(
				VM.loadBytecode(assert(Compiler.compile(bitFoldSrc, { optimizationLevel = 2 })), { name = "=bitfold" })
			)
			local ex, rep = bitFn()
			sert.eq(ex, 0xBC)
			sert.eq(rep, 0x11A1)

			-- 4. Alias-sharing disabledBuiltins ("unpack" -> table.unpack, "buffer.writei8" -> buffer.writeu8)
			local unpackDisasm = disassemble("local t = { 1, 2 }\nreturn table.unpack(t)", {
				optimizationLevel = 2,
				disabledBuiltins = { "unpack" },
			})
			expect(
				string.find(unpackDisasm, "FASTCALL", 1, true) == nil,
				"disabling unpack must disable table.unpack fastcall"
			)

			local bufDisasm = disassemble("local b = buffer.create(4)\nbuffer.writeu8(b, 0, 7)", {
				optimizationLevel = 2,
				disabledBuiltins = { "buffer.writei8" },
			})
			expect(
				string.find(bufDisasm, "LBF_BUFFER_WRITEU8", 1, true) == nil,
				"disabling buffer.writei8 must disable buffer.writeu8 fastcall"
			)

			-- 5. patchJumpD rejects out-of-range offsets >= 2^23
			local bcb = BytecodeBuilder.new()
			local _fid = bcb:beginFunction(0, false)
			bcb:emitAD(Opcodes.LOP_JUMP, 0, 0)
			local bcbRaw: any = bcb
			bcbRaw.insnCount = (2 ^ 23) + 2
			sert.eq(bcb:patchJumpD(0, (2 ^ 23) + 1), false)
			sert.eq(bcb:patchJumpD(0, 2 ^ 23), true)
			bcbRaw.insnCount = 1
			bcb:emitABC(Opcodes.LOP_RETURN, 0, 1, 0)
			bcb:endFunction(1, 0)
		end
	)

	test(
		"traverses full AST forms in inliner, @native builtin analysis, 64-bit Vectord folding, if-local folding, and interp folding",
		function()
			-- 1. Inliner AST local traversal (visitAstLocalStat / visitAstLocalNode) across control flow & expr forms
			local inlineAstSrc = [[
local function work(n: number, c: boolean, k: string, fn: (number) -> number): number
	local acc = (n :: number)
	if c then
		acc += -1
	else
		acc = acc + (if n > 0 then 2 else 3)
	end
	while acc < 0 do
		acc += 1
	end
	repeat
		acc += 1
	until acc > 0
	for i = 1, 2 do
		local x, y = acc, i
		acc, y = y + x, x
	end
	for _, v in { [k] = 1, 2 } do
		if type(v) == "number" then
			acc += v
		end
	end
	local function inner(z: number): number
		return z + acc
	end
	local s = `v:{acc}`
	return fn(inner(0)) + #s
end
local function id(v: number): number
	return v
end
return work(2, false, "k", id)
]]
			for _, opt in { 0, 1, 2 } do
				local opts: Compiler.CompileOptions = {
					optimizationLevel = opt,
					flags = { LuauCompileInlineThreshold = 1000 },
				}
				local fn = assert(VM.loadBytecode(assert(Compiler.compile(inlineAstSrc, opts)), { name = "=inl" }))
				sert.eq(fn(), 15)
			end

			-- 2. @native builtin analyzer AST traversal across O0 module statement/expression forms + class method
			local builtinAstSrc = [[
class B
	function ok(): number
		return 1
	end
end
class C extends B
	function calc(self, x: number, y: number, c: boolean, t: { [string]: any }): number
		local _u = t["a"]
		return math.abs(x) + bit32.bxor(y, 1)
	end
end
@native
local function walk(x: number, y: number, c: boolean, t: { [any]: any }): number
	local a = math.abs((x :: number))
	local b = t[a] or 0
	local e = if c then math.abs(x) else math.abs(y)
	local s = `{math.abs(x)}`
	local m = { [math.abs(x)] = bit32.bxor(x, y) }
	if c then
		a += 1
	elseif not c then
		a += 2
	else
		a += 3
	end
	while a < 0 do
		a += math.abs(-1)
	end
	repeat
		a += 1
	until a > 0
	for i = 1, 2, 1 do
		a += math.abs(i)
	end
	for _, v in { 1, 2 } do
		a += math.abs(v)
	end
	local p, q = 1, 2
	p, q = q, p
	local function helper(v: number): number
		return math.abs(v)
	end
	return a + b + e + #s + (m[math.abs(x)] or 0) + p + q + helper(-3)
end
function globalFn(): number
	return math.abs(-4)
end
return walk(-5, 3, true, { [5] = 2 }) + globalFn() + C.new():calc(-2, 4, true, { a = 1 })
]]
			local nativeRes = Compiler.compileResult(builtinAstSrc, {
				parseOptions = { profile = "experimental" },
				optimizationLevel = 0,
				typeInfoLevel = 1,
			})
			sert.eq(nativeRes.status, "ok")
			local nativeDump = BytecodeDisassembler.disassemble(assert(nativeRes.builder):toProtoModule())
			expect(string.find(nativeDump, "FASTCALL", 1, true) ~= nil, nativeDump)

			local o1BuiltinsRes = Compiler.compileResult(builtinAstSrc, {
				parseOptions = { profile = "experimental" },
				optimizationLevel = 1,
				typeInfoLevel = 1,
				disabledBuiltins = { "bit32.*" },
			})
			sert.eq(o1BuiltinsRes.status, "ok")
			sert.eq(
				CompilerBuiltins.getBuiltinFunctionId(
					{ object = "math", method = "abs" },
					{ disabledBuiltins = { "math.*" } },
					{}
				),
				Builtins.LBF_NONE
			)
			local disAllDump = disassemble("return math.abs(-3) + bit32.bxor(1, 2)", {
				optimizationLevel = 1,
				disabledBuiltins = { "*" },
			})
			expect(string.find(disAllDump, "FASTCALL", 1, true) == nil, "wildcard * disables all fastcalls")

			-- Multi-assign RHS closure traversal in visitAstLocalStat / visitAstLocalNode
			local assignInlineSrc = [[
local a, b = 1, 2
a, b = b, (function(n)
	local acc = n
	if acc > 0 then
		acc += 1
	else
		acc -= 1
	end
	while acc < 3 do
		acc += 1
	end
	repeat
		acc += 1
	until acc > 3
	for i = 1, 2 do
		acc += i
	end
	for _, v in { 1, 2 } do
		acc += v
	end
	local p, q = 1, 2
	p, q = q, p
	local function addOne(z)
		return z + (if p > 0 then 1 else 0)
	end
	local t = { k = `x:{acc}` }
	return addOne(acc) + (t.k and 1 or 0) + (q - p)
end)(a)
return a + b
]]
			for _, opt in { 0, 1, 2 } do
				local fn = assert(
					VM.loadBytecode(
						assert(Compiler.compile(assignInlineSrc, { optimizationLevel = opt })),
						{ name = "=ma" }
					)
				)
				sert.eq(fn(), 13)
			end

			-- Inliner and loop-unroll diagnostic remark branches
			local remDump = disassemble(
				[[
local function rec(n: number): number
	if n <= 0 then return 0 end
	return rec(n - 1)
end
local function leaf(x: number): number
	return x + 1
end
local function c1(x: number): number return leaf(x) + 1 end
local function c2(x: number): number return c1(x) + 1 end
local function pairRet(): (number, number) return 1, 2 end
local function caller(n: number)
	local s = 0
	for i = 1, 100 do s += i end
	for j = 1, n do s += j end
	for k = 1, 3 do k = k + 1; s += k end
	local a, b = rec(2), c2(3)
	return s + a + b, pairRet()
end
return caller
]],
				{
					optimizationLevel = 2,
					flags = { LuauCompileInlineDepth = 1 },
				}
			)
			expect(string.find(remDump, "inlining failed:", 1, true) ~= nil, remDump)
			expect(string.find(remDump, "loop unroll failed:", 1, true) ~= nil, remDump)

			-- 3. vectorPrecision = 1 (Vectord) negation & constant equality, floor-div vec folding, if-local folding, and constant string interpolation folding
			local vec32FoldFn = assert(VM.loadBytecode(
				assert(Compiler.compile(
					[[
local function idv(v) return v + vector.create(0, 0, 0) end
local a = vector.create(10, 20, 30) // vector.create(2, 4, 5)
local b = 20 // vector.create(2, 4, 5)
local c = vector.create(10, 20, 30) // 2
local d = idv(vector.create(1, 2, 3))
return a.x, a.y, a.z, b.x, b.y, b.z, c.x, c.y, c.z, d.x, d.y, d.z
]],
					{ optimizationLevel = 2, vectorLib = "vector", vectorCtor = "create" }
				)),
				{ name = "=v32fold" }
			))
			local v1, v2, v3, v4, v5, v6, v7, v8, v9, v10, v11, v12 = vec32FoldFn()
			sert.eq(v1 + v2 + v3, 16)
			sert.eq(v4 + v5 + v6, 19)
			sert.eq(v7 + v8 + v9, 30)
			sert.eq(v10 + v11 + v12, 6)

			local vec64Src = [[
local function keepv(v) return -v end
local a = -vector.create(1.5, -2.5, 3.5)
local b = keepv(vector.create(1.5, -2.5, 3.5))
local c = vector.create(10, 20, 30) // vector.create(2, 4, 5)
local d = 20 // vector.create(2, 4, 5)
local e = vector.create(10, 20, 30) // 2
local eq = a == b
return eq, a.x, a.y, a.z, c.x + d.y + e.z
]]
			local vecRes = Compiler.compileResult(vec64Src, {
				optimizationLevel = 2,
				vectorPrecision = 1,
				vectorLib = "vector",
				vectorCtor = "create",
			})
			sert.eq(vecRes.status, "ok")
			local vecFn = assert(VM.loadProto(assert(vecRes.builder):toProtoModule(), { name = "=vec64" }))
			local veq, vx, vy, vz, vsum = vecFn()
			sert.eq(veq, true)
			sert.eq(vx, -1.5)
			sert.eq(vy, 2.5)
			sert.eq(vz, -3.5)
			sert.eq(vsum, 25)

			local ifLocalSrc = [[
local function dyn(): any return nil end
local a = if local t = { v = 7 } then t.v else 0
local b = if local n = 2 + 3 then n + 1 else 0
local c = if local u = dyn() then u else 42
local sum = 0
for i = 1, 2 do
	if local k = i * 2 then
		sum += k
	end
end
local emptyInterp = ``
local fullInterp = `hello {"world"}{"!"}`
return a, b, c, sum, emptyInterp, fullInterp
]]
			local ifLocalDump, ifLocalRes = disassemble(ifLocalSrc, {
				optimizationLevel = 2,
				parseOptions = { profile = { LuauExperimentalIfLocalSyntax = true } },
			})
			expect(string.find(ifLocalDump, "hello world!", 1, true) ~= nil, "folds constant interp string")
			local ifLocalFn = assert(VM.loadBytecode(ifLocalRes.bytecode, { name = "=iflocal" }))
			local ia, ib, ic, isum, ie, ifull = ifLocalFn()
			sert.eq(ia, 7)
			sert.eq(ib, 6)
			sert.eq(ic, 42)
			sert.eq(isum, 6)
			sert.eq(ie, "")
			sert.eq(ifull, "hello world!")

			-- 4. O2 inlined builtin init argument traverses setupInlinedCallFrame -> analyzeBuiltins across all AST forms
			local inlBuiltinSrc = [[
local function apply(fn: (number) -> number, x: number, y: number, c: boolean, t: { [any]: any }): number
	local a = fn(x)
	local b = t[a] or 0
	local e = if c then fn(x) else fn(y)
	local s = `{fn(x)}`
	local m = { [fn(x)] = bit32.bxor(x, y) }
	if c then
		a += 1
	elseif not c then
		a += 2
	else
		a += 3
	end
	while a < 0 do
		a += fn(-1)
	end
	repeat
		a += 1
	until a > 0
	for i = 1, 2, 1 do
		a += fn(i)
	end
	for _, v in { 1, 2 } do
		a += fn(v)
	end
	local p, q = 1, 2
	p, q = q, p
	local function inner(z: number): number
		return fn(z)
	end
	local tbl = {}
	function tbl.f(z: number): number
		return fn(z)
	end
	return a + b + e + #s + (m[fn(x)] or 0) + p + q + inner(-2) + tbl.f(-3)
end
return apply(math.abs, -5, 3, true, { [5] = 2 })
]]
			local inlBRes = Compiler.compileResult(inlBuiltinSrc, {
				optimizationLevel = 2,
				flags = { LuauCompileInlineThreshold = 1000 },
			})
			sert.eq(inlBRes.status, "ok")
			local inlBFn = assert(VM.loadBytecode(inlBRes.bytecode, { name = "=inl_builtin" }))
			sert.eq(inlBFn(), 4294967317)

			-- 5. Experimental class forms (local class, const class extends, existing local class, table call), parseExpression error, multi-assign shortfall, declare stat, class depth & private error
			local clsCompileRes = Compiler.compileResult(
				[[
local class BaseClass
	public x: number
end
const class SubClass extends BaseClass
	public y: number
end
local Rebound = nil
class Rebound
	public z: number
end
local inst = BaseClass { x = 4 }
return inst
]],
				{ parseOptions = { profile = "experimental" }, optimizationLevel = 1 }
			)
			sert.eq(clsCompileRes.status, "ok")

			local undefPrivRes = Compiler.compileResult(
				[[
class P
	private _ok: number
	function bad(self)
		return self._missing
	end
end
]],
				{ parseOptions = { profile = "experimental" } }
			)
			sert.eq(undefPrivRes.status, "compileError")
			expect(string.find(undefPrivRes.error or "", "undefined private field", 1, true) ~= nil, undefPrivRes.error)

			local nestedClsParts: { string } = {}
			for i = 1, 257 do
				nestedClsParts[i] = `class N{i} function f{i}() `
			end
			local nestedClsSrc = table.concat(nestedClsParts) .. string.rep("end ", 514)
			local nestedClsRes = Compiler.compileResult(nestedClsSrc, {
				parseOptions = { profile = "experimental", recursionLimit = 2000 },
			})
			sert.eq(nestedClsRes.status, "compileError")
			expect(string.find(nestedClsRes.error or "", "Class nest exceeded", 1, true) ~= nil, nestedClsRes.error)

			local exprParseErr = Compiler.compileResult(Parser.parseExpression("1 + 2"))
			sert.eq(exprParseErr.status, "parseError")
			expect(string.find(exprParseErr.error or "", "AstStatBlock", 1, true) ~= nil, exprParseErr.error)

			local declCompileRes = Compiler.compileResult("declare foo: number\nreturn 7", {
				parseOptions = { allowDeclarationSyntax = true },
			})
			sert.eq(declCompileRes.status, "ok")

			local multiShortFn = assert(VM.loadBytecode(
				assert(Compiler.compile([[
local function one()
	return 10
end
local a, b, c = 1, 2, 3
a, b, c = one()
return a, b, c
]])),
				{ name = "=ma_short" }
			))
			local ma1, ma2, ma3 = multiShortFn()
			sert.eq(ma1, 10)
			sert.eq(ma2, nil)
			sert.eq(ma3, nil)

			-- 6. Vector floor-div float folding, double-vector branch merge, O2 clearLocalConstant & class builtins/inlining
			local vecFloatFoldFn = assert(VM.loadBytecode(
				assert(Compiler.compile(
					[[
local a = vector.create(9, 10, 11) // vector.create(2, 3, 4)
local b = 20 // vector.create(3, 4, 5)
return a.x, a.y, a.z, b.x, b.y, b.z
]],
					{ optimizationLevel = 2, vectorPrecision = 0 }
				)),
				{ name = "=vec_f_fdiv" }
			))
			local vf1, vf2, vf3, vf4, vf5, vf6 = vecFloatFoldFn()
			sert.eq(vf1, 4)
			sert.eq(vf2, 3)
			sert.eq(vf3, 2)
			sert.eq(vf4, 6)
			sert.eq(vf5, 5)
			sert.eq(vf6, 4)

			local vecDoubleBranchFn = assert(VM.loadBytecode(
				assert(Compiler.compile(
					[[
local cond = ...
local v = vector.create(1, 2, 3)
if cond then
	v = vector.create(1, 2, 3)
else
	v = vector.create(1, 2, 3)
end
return v.x, v.y, v.z
]],
					{ optimizationLevel = 2, vectorPrecision = 1 }
				)),
				{ name = "=vec_d_branch" }
			))
			local vd1, vd2, vd3 = vecDoubleBranchFn(true)
			sert.eq(vd1, 1)
			sert.eq(vd2, 2)
			sert.eq(vd3, 3)

			local clearLocRes = Compiler.compileResult(
				[[
local pre = 1 + 2
local function bump(flag, dyn)
	local x = 10
	if flag then
		x = dyn()
	end
	return x + pre
end
return bump(..., function() return 9 end)
]],
				{ optimizationLevel = 2, flags = { LuauCompileInlineThreshold = 1000 } }
			)
			sert.eq(clearLocRes.status, "ok")
			local clearLocFn = assert(VM.loadBytecode(clearLocRes.bytecode, { name = "=clear_loc_inl" }))
			sert.eq(clearLocFn(true), 12)
			sert.eq(clearLocFn(false), 13)

			local clsInlRes = Compiler.compileResult(
				[[
local function apply(fn, s)
	return fn(s)
end
local function makeClass(fn)
	local class HBase
		public v: number
	end
	local class HSub extends HBase
		function m(self, z)
			return fn(z)
		end
	end
	return HSub { v = 3 }
end
local o = makeClass(math.abs)
local v, _ = o:m(-5)
class CA
	private _p: number
	function h(self)
		local function helper(s)
			return s._p
		end
		class CB
			function run(s)
				return helper(s)
			end
		end
		return apply(helper, self), CB {}
	end
end
return v
]],
				{
					parseOptions = { profile = "experimental" },
					optimizationLevel = 2,
					dumpFlags = bit32.bor(BytecodeBuilder.DumpFlags.Code, BytecodeBuilder.DumpFlags.Remarks),
					flags = { LuauCompileInlineThreshold = 1000 },
				}
			)
			sert.eq(clsInlRes.status, "ok")
			local clsInlDump = assert(clsInlRes.builder):dumpEverything()
			expect(
				string.find(clsInlDump, "inlining failed: mismatched enclosing classes", 1, true) ~= nil,
				"expected mismatched enclosing classes remark"
			)

			local cls201Parts: { string } = {}
			cls201Parts[1] = "class M1 private _p: number function g1(s) "
			for i = 2, 201 do
				cls201Parts[i] = `class M{i} function g{i}(s) `
			end
			local cls201Src = table.concat(cls201Parts) .. "return s._p " .. string.rep("end ", 402)
			local clsMethodUvErr = Compiler.compileResult(cls201Src, {
				parseOptions = { profile = "experimental", recursionLimit = 2000 },
			})
			sert.eq(clsMethodUvErr.status, "compileError")
			expect(
				string.find(clsMethodUvErr.error or "", "Out of upvalue registers", 1, true) ~= nil,
				clsMethodUvErr.error
			)

			local uvDecls: { string } = {}
			local uvSum: { string } = {}
			for i = 1, 199 do
				uvDecls[i] = `local u{i} = ext({i})`
				uvSum[i] = `u{i}`
			end
			local uvBase = table.concat(uvDecls, "\n")
			local uvExpr = table.concat(uvSum, " + ")
			local clsExprUvErr = Compiler.compileResult(
				uvBase
					.. `\nclass BigUvExpr\n\tprivate _p: number\n\tfunction m(s)\n\t\treturn s._p + {uvExpr}\n\tend\nend`,
				{ parseOptions = { profile = "experimental" } }
			)
			sert.eq(clsExprUvErr.status, "compileError")
			expect(
				string.find(clsExprUvErr.error or "", "Out of upvalue registers", 1, true) ~= nil,
				clsExprUvErr.error
			)
		end
	)

	test("covers CompilerTypes large typeinfo scratch growth, instantiate exprs, and CompilerClass errors", function()
		-- 40+ typed parameters force typeScratchBuf expansion in CompilerTypes
		local paramNames: { string } = {}
		local paramUses: { string } = {}
		for i = 1, 45 do
			paramNames[i] = `p{i}: number`
			paramUses[i] = `p{i}`
		end
		local bigTypeFnSrc = `local function f({table.concat(paramNames, ", ")}): number\n\treturn {table.concat(
			paramUses,
			" + "
		)}\nend\nreturn f`
		local bigTypeRes = Compiler.compileResult(bigTypeFnSrc, {
			optimizationLevel = 1,
			typeInfoLevel = 1,
		})
		sert.eq(bigTypeRes.status, "ok")

		-- Explicit type instantiation + type functions + error recovery in CompilerTypes
		local instSrc = [[
local function id<T>(x: T): T
	return x
end
local y = id<<number>>(42)
type function tf()
	return types.any
end
return y
]]
		local instRes = Compiler.compileResult(instSrc, {
			optimizationLevel = 0,
			typeInfoLevel = 1,
		})
		sert.eq(instRes.status, "ok")

		local optTypeRes = Compiler.compileResult(
			[[
local function optFn(a: number?, b: string?): boolean?
	local x: number? = a
	return if x and b then true else nil
end
return optFn
]],
			{ optimizationLevel = 1, typeInfoLevel = 1, dumpFlags = 0xff }
		)
		sert.eq(optTypeRes.status, "ok")
		local optTypeDump = assert(optTypeRes.builder):dumpTypeInfo()
		expect(string.find(optTypeDump, "number?", 1, true) ~= nil, "optional type info dumped")

		-- export class without LuauExportValueSyntax error
		local expClsErr = Compiler.compileResult("export class E\nend", {
			parseOptions = { profile = { DebugLuauUserDefinedClasses = true, LuauExportValueSyntax = false } },
		})
		sert.eq(expClsErr.status, "compileError")
		expect(string.find(expClsErr.error or "", "LuauExportValueSyntax", 1, true) ~= nil, expClsErr.error)

		-- 32-bit and 64-bit vector constant folding (//, ==, arithmetic) and if-local table folding
		local vecFoldSrc = [[
local v1 = vector.create(1, 2, 3) + vector.create(4, 5, 6)
local v2 = vector.create(10, 20, 30) - vector.create(1, 2, 3)
local v3 = vector.create(2, 3, 4) * 2
local v4 = vector.create(8, 12, 16) // vector.create(2, 3, 4)
local v5 = 24 // vector.create(2, 3, 4)
local v6 = -vector.create(1, -2, 3)
local eq = vector.create(1, 2, 3) == vector.create(1, 2, 3)
return v1, v2, v3, v4, v5, v6, eq
]]
		local vecfRes = Compiler.compileResult(vecFoldSrc, {
			optimizationLevel = 2,
			vectorLib = "vector",
			vectorCtor = "create",
			vectorPrecision = 0,
		})
		sert.eq(vecfRes.status, "ok")
		local vecdRes = Compiler.compileResult(vecFoldSrc, {
			optimizationLevel = 2,
			vectorLib = "vector",
			vectorCtor = "create",
			vectorPrecision = 1,
		})
		sert.eq(vecdRes.status, "ok")

		local ifLocalTblSrc = [[
local function testIfLocal(x, cond)
	local k = 10
	if cond then
		k = 20
	end
	local t = { a = 1 }
	if local v = x then
		t.a = 2
		return v + t.a + k
	else
		t = { a = 3 }
		return t.a + k
	end
end
local function testIfLocalConstTbl()
	if local ct = { a = 7 } then
		return ct.a
	end
	return 0
end
return testIfLocal(5, true), testIfLocal(nil, false), testIfLocalConstTbl()
]]
		local ifLocalRes = Compiler.compileResult(ifLocalTblSrc, {
			optimizationLevel = 2,
			parseOptions = { profile = { LuauExperimentalIfLocalSyntax = true } },
		})
		sert.eq(ifLocalRes.status, "ok")

		-- >64 locals inside a function for high-bit varMasks + 260 typed params for typeScratchBuf growth + inline localChanges
		local manyLocals: { string } = {}
		local manyUses: { string } = {}
		for i = 1, 70 do
			manyLocals[i] = `\tlocal v{i}: number = {i}`
			manyUses[i] = `v{i}`
		end
		local manyLoopSrc = "local function sumMany(cond)\n"
			.. table.concat(manyLocals, "\n")
			.. "\n\tlocal s = 0\n\tfor i = 1, 2 do\n\t\tif cond then v65 += 1 end\n\t\ts += "
			.. table.concat(manyUses, " + ")
			.. "\n\tend\n\treturn s\nend\nreturn sumMany(true)"
		local manyRes = Compiler.compileResult(manyLoopSrc, { optimizationLevel = 2, typeInfoLevel = 1 })
		sert.eq(manyRes.status, "ok")

		local hugeParams: { string } = {}
		for i = 1, 100 do
			hugeParams[i] = `p{i}: number`
		end
		local hugeLocals: { string } = {}
		for i = 1, 90 do
			hugeLocals[i] = `\tlocal l{i}: number = p1`
		end
		local hugeTypeSrc = `local function hugeFn({table.concat(hugeParams, ", ")}): number\n{table.concat(
			hugeLocals,
			"\n"
		)}\n\treturn l90\nend\nreturn hugeFn`
		local hugeTypeRes = Compiler.compileResult(hugeTypeSrc, { optimizationLevel = 1, typeInfoLevel = 1 })
		sert.eq(hugeTypeRes.status, "ok")

		local inlineChangesSrc = [[
local function helper(c, b)
	local x = 1
	local y = "a"
	if c then
		x = 2
	else
		y = b
	end
	return x, #y
end
return helper(true, "zz"), helper(false, "zz")
]]
		local inlineChangesRes = Compiler.compileResult(inlineChangesSrc, { optimizationLevel = 2 })
		sert.eq(inlineChangesRes.status, "ok")

		-- Regression tests: const class DUPCLOSURE capture, nested unrolled for loops, and inlined unroll isolation
		local constClassDump = disassemble(
			[[
const class Point
	public x: number
	function origin()
		return Point { x = 0 }
	end
end
local function getPoint()
	return Point
end
return Point, getPoint
]],
			{
				optimizationLevel = 1,
				parseOptions = { profile = { DebugLuauUserDefinedClasses = true } },
			}
		)
		expect(string.find(constClassDump, "DUPCLOSURE", 1, true) ~= nil, constClassDump)
		expect(string.find(constClassDump, "CAPTURE VAL", 1, true) ~= nil, constClassDump)

		local nestedUnrollSrc = [[
local t = {}
for i = 0, 1 do
	for j = 0, i do
		t[i * 2 + (j + 1)] = i * 10 + j
	end
end
return t[1], t[2], t[3], t[4]
]]
		local nestedUnrollBc = assert(Compiler.compile(nestedUnrollSrc, { optimizationLevel = 2 }))
		local nestedUnrollFn = assert(VM.loadBytecode(nestedUnrollBc, { name = "=nested_unroll" }))
		local nu1, nu2, nu3, nu4 = nestedUnrollFn()
		sert.eq(nu1, 0)
		sert.eq(nu2, nil)
		sert.eq(nu3, 10)
		sert.eq(nu4, 11)

		local nestedBranchBc = assert(Compiler.compile(
			[[
for i = 1, 1 do
	for j = 1, 1 do
		if i == 1 then
			continue
		else
			break
		end
	end
end
return 42
]],
			{ optimizationLevel = 2 }
		))
		local nestedBranchFn = assert(VM.loadBytecode(nestedBranchBc, { name = "=nested_unroll_branch" }))
		sert.eq(nestedBranchFn(), 42)

		local inlineNestedUnrollSrc = [[
local function sumTri(n)
	local s = 0
	for i = 0, 1 do
		for j = 0, i do
			s += (i + j) * n
		end
	end
	return s
end
local function runNonConst(v)
	return sumTri(v)
end
return sumTri(2), runNonConst(5)
]]
		local inlineNestedBc = assert(Compiler.compile(inlineNestedUnrollSrc, { optimizationLevel = 2 }))
		local inlineNestedFn = assert(VM.loadBytecode(inlineNestedBc, { name = "=inline_nested_unroll" }))
		local inl1, inl2 = inlineNestedFn()
		sert.eq(inl1, 6)
		sert.eq(inl2, 15)

		-- Public Bytecode.verify error and custom decoder coverage
		local badVerifyOk, badVerifyErr = Parser.Bytecode.verify("\14\3\0\0")
		sert.eq(badVerifyOk, false)
		expect(badVerifyErr ~= nil, "verify rejects truncated bytecode")
		local xorBc = assert(Compiler.compile("return 1 + 2", {
			encoder = function(op)
				return bit32.bxor(op, 0x55)
			end,
		}))
		sert.eq(Parser.Bytecode.verify(xorBc), false)
		local xorOk, xorErr = Parser.Bytecode.verify(xorBc, function(op)
			return bit32.bxor(op, 0x55)
		end)
		sert.eq(xorOk, true)
		sert.eq(xorErr, nil)
	end)

	test(
		"validates strict CompileOptions, protects frozen ParseResult arenas, guards GlobalState.Default, and cleans scratch on errors",
		function()
			-- 1. compileUnrolledFor preserves outer change stacks
			local unrollNestSrc = [[
			local a = 5
			for i = 1, 2 do
				for j = 1, 2 do
					a = a + i + j
				end
			end
			return a
		]]
			local unrollNestFn =
				assert(VM.loadBytecode(assert(Compiler.compile(unrollNestSrc, { optimizationLevel = 2 })), {
					name = "=unroll_nest",
				}))
			sert.eq(unrollNestFn(), 17)

			-- 2. mutableGlobals preserves GlobalState.Default across CompilerFolding and CompilerTypes; out-of-range libraryMemberTypeCb ignored
			local mutMathDisasm = disassemble("return math.abs(-5)", {
				optimizationLevel = 2,
				mutableGlobals = { "math" },
			})
			expect(
				string.find(mutMathDisasm, "GETIMPORT", 1, true) ~= nil
					and string.find(mutMathDisasm, "FASTCALL", 1, true) == nil
					and string.find(mutMathDisasm, "LOADN R0 5", 1, true) == nil,
				"mutableGlobals math should block folding:\n" .. mutMathDisasm
			)
			for _, badTy in { -1, 256, 1.5, "string" :: any } do
				local cbRes = Compiler.compileResult("local x = customLib.member\nreturn x", {
					optimizationLevel = 2,
					typeInfoLevel = 1,
					librariesWithKnownMembers = { "customLib" },
					libraryMemberTypeCb = function()
						return badTy
					end,
				})
				sert.eq(cbRes.status, "ok")
				sert.eq(Parser.Bytecode.verify(cbRes.bytecode), true)
			end

			-- 3. Throwing libraryMemberConstantCb / libraryMemberTypeCb cleans scratch via pcall
			sert.throws(function()
				Compiler.compileResult("return customLib.val", {
					optimizationLevel = 2,
					librariesWithKnownMembers = { "customLib" },
					libraryMemberConstantCb = function()
						error("const cb failed")
					end,
				})
			end, "const cb failed")
			sert.throws(function()
				Compiler.compileResult("local x = customLib.val; return x", {
					optimizationLevel = 2,
					typeInfoLevel = 1,
					librariesWithKnownMembers = { "customLib" },
					libraryMemberTypeCb = function()
						error("type cb failed")
					end,
				})
			end, "type cb failed")
			local postCbRes =
				Compiler.compileResult("@native local function f(x: number): number return x + 1 end; return f(4)", {
					optimizationLevel = 2,
					typeInfoLevel = 1,
				})
			sert.eq(postCbRes.status, "ok")
			sert.eq(assert(VM.loadBytecode(postCbRes.bytecode))(), 5)

			-- 4. Deeply frozen ParseResult (including exports) compiles cleanly without arena mutation
			local frozenPr = Parser.parse("export const X = 10\nexport local Y = X + 5", { profile = "experimental" })
			sert.eq(frozenPr.status, "ok")
			table.freeze(frozenPr.arena.nodes)
			table.freeze(frozenPr.arena.kinds)
			table.freeze(frozenPr.arena.bindings)
			table.freeze(frozenPr.arena.symbols)
			table.freeze(frozenPr.arena.listFirsts)
			table.freeze(frozenPr.arena.listCounts)
			table.freeze(frozenPr.arena.listValues)
			table.freeze(frozenPr.arena)
			table.freeze(frozenPr.lineStarts)
			table.freeze(frozenPr.diagnostics)
			local frozenCompRes = Compiler.compileResult(frozenPr)
			sert.eq(frozenCompRes.status, "ok", frozenCompRes.error or "frozen compile failed")
			local frozenExpDecoded = assert(BytecodeCodec.deserialize(frozenCompRes.bytecode))
			sert.eq(frozenExpDecoded.version, 100)

			local frozenRunPr = Parser.parse("local function f(x: number): number return x * 2 end; return f(21)")
			table.freeze(frozenRunPr.arena.nodes)
			table.freeze(frozenRunPr.arena.kinds)
			table.freeze(frozenRunPr.arena.bindings)
			table.freeze(frozenRunPr.arena.symbols)
			table.freeze(frozenRunPr.arena.listFirsts)
			table.freeze(frozenRunPr.arena.listCounts)
			table.freeze(frozenRunPr.arena.listValues)
			table.freeze(frozenRunPr.arena)
			table.freeze(frozenRunPr.lineStarts)
			table.freeze(frozenRunPr.diagnostics)
			local frozenRunRes = Compiler.compileResult(frozenRunPr)
			sert.eq(frozenRunRes.status, "ok")
			sert.eq(assert(VM.loadBytecode(frozenRunRes.bytecode))(), 42)

			-- 5. Strict CompileOptions validation throws
			local badCompileCases: { any } = {
				"not_a_table",
				{ unknownOpt = true },
				{ optimizationLevel = 3 },
				{ debugLevel = -1 },
				{ typeInfoLevel = 2 },
				{ coverageLevel = 3 },
				{ vectorPrecision = 2 },
				{ mutableGlobals = "math" },
				{ mutableGlobals = { 123 } },
				{ userdataTypes = { 1 } },
				{ librariesWithKnownMembers = { true } },
				{ disabledBuiltins = { {} } },
				{ encoder = "bad_encoder" },
				{ dumpFlags = "bad_flags" },
			}
			for _, badOpts in badCompileCases do
				sert.throws(function()
					Compiler.compile("return 1", badOpts)
				end)
			end

			-- 6. O2 inlining of 10-parameter function exercising >32-bit cost model bitmasks
			local tenParamSrc = [[
			local function heavy10(
				a1: number,
				a2: number,
				a3: number,
				a4: number,
				a5: number,
				a6: number,
				a7: number,
				a8: number,
				a9: number,
				a10: number
			): number
				local t = { k = a10 }
				local acc = a1 + a2 + a3 + a4 + a5 + a6 + a7 + a8 + a9 + t.k
				if a9 > 0 then
					acc += a8
				else
					acc -= a7
				end
				for _i = 1, 2 do
					acc += 1
				end
				return acc
			end
			return heavy10(1, 2, 3, 4, 5, 6, 7, 8, 9, 10)
		]]
			local tenFn = assert(VM.loadBytecode(assert(Compiler.compile(tenParamSrc, { optimizationLevel = 2 }))))
			sert.eq(tenFn(), 65)

			-- 7. Constant vector floor division (Vectorf / Vectord / scalar-vector) and local constant overwrite undo
			local vecDivSrc = [[
			local dyn, flag = ...
			local a = vector.create(10, 21, 35, 4)
			local b = vector.create(3, 4, 5, 2)
			local c = a // b
			local d = a // 3
			local e = 100 // b
			local x = 10
			if flag then
				x = dyn
			end
			return c.x + c.y + c.z + d.x + d.y + d.z + e.x + e.y + e.z + x
			]]
			local vbcF = assert(
				Compiler.compile(
					vecDivSrc,
					{ optimizationLevel = 2, vectorPrecision = 0, vectorLib = "vector", vectorCtor = "create" }
				)
			)
			local vbcD = assert(
				Compiler.compile(
					vecDivSrc,
					{ optimizationLevel = 2, vectorPrecision = 1, vectorLib = "vector", vectorCtor = "create" }
				)
			)
			sert.eq(assert(VM.loadBytecode(vbcF))(7, true), 121)
			sert.eq(assert(VM.loadBytecode(vbcD))(7, false), 124)

			-- 8. >32-parameter cost model bitmask (resHi/sumHi) and speculative inline local constant undo
			local hiAndUndoSrc = [[
			local dyn, gflag = ...
			local function f35(
				p1, p2, p3, p4, p5, p6, p7, p8, p9, p10,
				p11, p12, p13, p14, p15, p16, p17, p18, p19, p20,
				p21, p22, p23, p24, p25, p26, p27, p28, p29, p30,
				p31, p32, p33, p34, p35
			)
				local acc = p1 + p35
				if p34 > 0 then
					acc += p33
				end
				for _i = 1, 2 do
					acc += p32
				end
				return acc
			end
			local function inlineUndo(cond, v)
				local x = 10
				if cond then
					x = v + (if gflag then 1 else 2)
				end
				return x
			end
			local tot = 0
			for i = 1, 2 do
				tot += inlineUndo(dyn > i, 5)
			end
			return f35(
				1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32,33,34,35
			) + tot
			]]
			local huBc = assert(Compiler.compile(hiAndUndoSrc, { optimizationLevel = 2 }))
			sert.eq(assert(VM.loadBytecode(huBc))(2, true), 149)
		end
	)
end)

if not sert._bundled then
	return sert.run(sert.parseCliArgs(...))
end
return nil
