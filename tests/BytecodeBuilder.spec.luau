--!strict
local BytecodeBuilder = require("../src/BytecodeBuilder")
local BytecodeCodec = require("../src/BytecodeCodec")
local BytecodeDefs = require("../src/BytecodeDefs")
local BytecodeDisassembler = require("../src/BytecodeDisassembler")
local Helpers = require("./Helpers")
local VM = require("../src/VM")
local sert = require("@sert") :: any

local describe = sert.describe
local test = sert.test
local expect = sert
local gen = sert.gen
local laws = sert.laws

local Opcodes = BytecodeDefs.Opcodes
local ProtoFlags = BytecodeDefs.ProtoFlags
local Captures = BytecodeDefs.Captures

describe("BytecodeBuilder", function()
	test("deduplicates constants including signed zero and NaN", function()
		local bcb = BytecodeBuilder.new()
		local fid = bcb:beginFunction(0, false)
		sert.eq(fid, 0)

		local kNil1 = bcb:addConstantNil()
		local kNil2 = bcb:addConstantNil()
		sert.eq(kNil1, kNil2)

		local kTrue1 = bcb:addConstantBoolean(true)
		local kTrue2 = bcb:addConstantBoolean(true)
		local kFalse = bcb:addConstantBoolean(false)
		sert.eq(kTrue1, kTrue2)
		expect(kTrue1 ~= kFalse, "true vs false constants are distinct")

		local kPosZero = bcb:addConstantNumber(0.0)
		local kNegZero = bcb:addConstantNumber(-0.0)
		expect(kPosZero ~= kNegZero, "+0.0 and -0.0 have distinct constant slots")
		sert.eq(bcb:addConstantNumber(-0.0), kNegZero)

		local nan = 0 / 0
		local kNan1 = bcb:addConstantNumber(nan)
		local kNan2 = bcb:addConstantNumber(nan)
		sert.eq(kNan1, kNan2)

		local kStr1 = bcb:addConstantString("hello")
		local kStr2 = bcb:addConstantString("hello")
		local kStr3 = bcb:addConstantString("world")
		sert.eq(kStr1, kStr2)
		expect(kStr1 ~= kStr3, "distinct strings get distinct constants")

		local kVec1 = bcb:addConstantVectorf(1, 2, 3, 0)
		local kVec2 = bcb:addConstantVectorf(1, 2, 3, 0)
		sert.eq(kVec1, kVec2)

		bcb:emitABC(Opcodes.LOP_RETURN, 0, 1, 0)
		bcb:endFunction(2, 0, 0)
		bcb:setMainFunction(fid)
		bcb:finalize()

		local mod = assert(BytecodeCodec.deserialize(bcb:getBytecode()))
		sert.eq(mod.mainid, 0)
		sert.eq(#mod.protos, 1)
		local proto = mod.protos[1]
		sert.eq(proto.kValues[kPosZero + 1], 0)
		expect(1 / proto.kValues[kNegZero + 1] < 0, "deserialized -0.0 preserves sign bit")
		expect(proto.kValues[kNan1 + 1] ~= proto.kValues[kNan1 + 1], "deserialized NaN is NaN")
		sert.eq(proto.kValues[kStr1 + 1], "hello")
		sert.eq(proto.kValues[kStr3 + 1], "world")
	end)

	test("computes Luau string hash and import IDs", function()
		local h1 = BytecodeBuilder.getStringHash("math")
		local h2 = BytecodeBuilder.getStringHash("abs")
		sert.eq(h1, 8031340)
		sert.eq(h2, 218612)
		expect(h1 >= 0 and h1 < 0x100000000 and math.floor(h1) == h1, "string hash is uint32")
		expect(h1 ~= h2, "distinct identifiers hash differently")

		local iid1 = BytecodeBuilder.getImportId(5)
		local c1, a0, a1, a2 = BytecodeCodec.decomposeImportId(iid1)
		sert.eq(c1, 1)
		sert.eq(a0, 5)
		sert.eq(a1, -1)
		sert.eq(a2, -1)

		local iid2 = BytecodeBuilder.getImportId(5, 12)
		local c2, b0, b1, b2 = BytecodeCodec.decomposeImportId(iid2)
		sert.eq(c2, 2)
		sert.eq(b0, 5)
		sert.eq(b1, 12)
		sert.eq(b2, -1)

		local iid3 = BytecodeBuilder.getImportId(5, 12, 99)
		local c3, d0, d1, d2 = BytecodeCodec.decomposeImportId(iid3)
		sert.eq(c3, 3)
		sert.eq(d0, 5)
		sert.eq(d1, 12)
		sert.eq(d2, 99)
	end)

	test("folds chained jumps and expands long jumps via trampolines", function()
		local bcb = BytecodeBuilder.new()
		local fid = bcb:beginFunction(0, false)

		local j1 = bcb:emitLabel()
		bcb:emitAD(Opcodes.LOP_JUMPIF, 0, 0)
		bcb:emitABC(Opcodes.LOP_LOADN, 0, 1, 0)
		local j2 = bcb:emitLabel()
		bcb:emitAD(Opcodes.LOP_JUMP, 0, 0)
		bcb:emitABC(Opcodes.LOP_LOADN, 0, 2, 0)
		local finalLabel = bcb:emitLabel()
		bcb:emitABC(Opcodes.LOP_RETURN, 0, 2, 0)

		expect(bcb:patchJumpD(j1, j2), "patched j1 -> j2")
		expect(bcb:patchJumpD(j2, finalLabel), "patched j2 -> finalLabel")
		bcb:foldJumps()
		expect(not bcb:expandJumps(), "expandJumps succeeds")
		bcb:endFunction(2, 0, 0)
		bcb:setMainFunction(fid)
		bcb:finalize()

		local mod = assert(BytecodeCodec.deserialize(bcb:getBytecode()))
		local insn1 = mod.protos[1].code[1]
		-- j1 was at 0, finalLabel at 4 -> offset = 4 - 0 - 1 = 3
		sert.eq(BytecodeCodec.insnD(insn1), 3)
	end)

	test("expands jumps exceeding 16-bit signed offset into JUMPX trampolines", function()
		local bcb = BytecodeBuilder.new()
		local fid = bcb:beginFunction(0, false)

		local condJump = bcb:emitLabel()
		bcb:emitAD(Opcodes.LOP_JUMPIFNOT, 0, 0)
		for _ = 1, 33000 do
			bcb:emitABC(Opcodes.LOP_NOP, 0, 0, 0)
		end
		local targetLabel = bcb:emitLabel()
		bcb:emitABC(Opcodes.LOP_RETURN, 0, 1, 0)

		-- Direct patchJumpD records the jump and marks hasLongJumps when out of 16-bit range, leaving D=0 for expandJumps
		expect(bcb:patchJumpD(condJump, targetLabel), "patchJumpD records jump for expandJumps")
		expect(bcb.hasLongJumps, "offset > 32767 sets hasLongJumps")
		expect(not bcb:expandJumps(), "expandJumps trampolines conditional jump")
		bcb:endFunction(2, 0, 0)
		bcb:setMainFunction(fid)
		bcb:finalize()

		local mod = assert(BytecodeCodec.deserialize(bcb:getBytecode()))
		local code = mod.protos[1].code
		-- C++ 0.748 trampoline layout: JUMP +1, JUMPX <far>, JUMPIFNOT -2
		sert.eq(BytecodeCodec.insnOp(code[1]), Opcodes.LOP_JUMP)
		sert.eq(BytecodeCodec.insnD(code[1]), 1)
		sert.eq(BytecodeCodec.insnOp(code[2]), Opcodes.LOP_JUMPX)
		sert.eq(BytecodeCodec.insnE(code[2]), 33001)
		sert.eq(BytecodeCodec.insnOp(code[3]), Opcodes.LOP_JUMPIFNOT)
		sert.eq(BytecodeCodec.insnD(code[3]), -2)
	end)

	test("expands nested out-of-order >32767-instruction long jumps accurately", function()
		local bcb = BytecodeBuilder.new()
		local fid = bcb:beginFunction(2, false) -- R0 = outerFlag, R1 = innerFlag, R2 = acc
		local kFive = bcb:addConstantNumber(5)
		local kOne = bcb:addConstantNumber(1)

		bcb:emitAD(Opcodes.LOP_LOADN, 2, 0)
		local outerJump = bcb:emitLabel()
		bcb:emitAD(Opcodes.LOP_JUMPIFNOT, 0, 0)

		bcb:emitAD(Opcodes.LOP_LOADN, 2, 10)
		local innerShortJump = bcb:emitLabel()
		bcb:emitAD(Opcodes.LOP_JUMPIFNOT, 1, 0)
		bcb:emitAD(Opcodes.LOP_LOADN, 2, 20)
		local innerShortEnd = bcb:emitLabel()
		-- Patched BEFORE outerJump (source > outerJump)
		expect(bcb:patchJumpD(innerShortJump, innerShortEnd), "patched inner short jump")

		local innerLongJump = bcb:emitLabel()
		bcb:emitAD(Opcodes.LOP_JUMPIFNOT, 1, 0)
		for _ = 1, 33100 do
			bcb:emitABC(Opcodes.LOP_NOP, 0, 0, 0)
		end
		bcb:emitAD(Opcodes.LOP_LOADN, 2, 30)
		local innerLongEnd = bcb:emitLabel()
		-- Patched BEFORE outerJump (source > outerJump, >32767 insns)
		expect(bcb:patchJumpD(innerLongJump, innerLongEnd), "patched inner long jump")

		bcb:emitABC(Opcodes.LOP_ADDK, 2, 2, kFive)
		local outerEnd = bcb:emitLabel()
		-- Patched AFTER inner jumps despite earlier source index, spanning >33100 insns
		expect(bcb:patchJumpD(outerJump, outerEnd), "patched outer long jump")

		bcb:emitABC(Opcodes.LOP_ADDK, 2, 2, kOne)
		bcb:emitABC(Opcodes.LOP_RETURN, 2, 2, 0)

		expect(bcb.hasLongJumps, "long jumps flagged")
		expect(not bcb:expandJumps(), "expandJumps succeeds for out-of-order nested jumps")
		bcb:endFunction(3, 0, 0)
		bcb:setMainFunction(fid)
		bcb:finalize()

		local fn = assert(VM.loadBytecode(bcb:getBytecode(), { name = "=nested_long_jumps" }))
		sert.eq(fn(false, false), 1)
		sert.eq(fn(false, true), 1)
		sert.eq(fn(true, false), 16)
		sert.eq(fn(true, true), 36)
	end)

	test("disassembles functions, constants, locals, types, and remarks", function()
		local bcb = BytecodeBuilder.new()
		bcb:setDumpFlags(
			bit32.bor(
				BytecodeBuilder.DumpFlags.Code,
				BytecodeBuilder.DumpFlags.Lines,
				BytecodeBuilder.DumpFlags.Locals,
				BytecodeBuilder.DumpFlags.Remarks,
				BytecodeBuilder.DumpFlags.Types,
				BytecodeBuilder.DumpFlags.Constants
			)
		)
		local fid = bcb:beginFunction(1, false)
		bcb:setDebugFunctionName("addOne")
		bcb:setDebugFunctionLineDefined(1)
		bcb:setDebugLine(2)
		bcb:addDebugRemark("custom remark")
		local kOne = bcb:addConstantNumber(1)
		bcb:emitABC(Opcodes.LOP_ADDK, 0, 0, kOne)
		bcb:emitABC(Opcodes.LOP_RETURN, 0, 2, 0)
		bcb:pushDebugLocal("x", 0, 0, 2)
		bcb:endFunction(2, 0, 0)
		bcb:setMainFunction(fid)
		bcb:finalize()

		local dump = bcb:dumpFunction(fid)
		expect(string.find(dump, "Function 0 (addOne)", 1, true) ~= nil, "includes function header")
		expect(string.find(dump, "remark: custom remark", 1, true) ~= nil, "includes remark")
		expect(string.find(dump, "ADDK R0 R0 K0 [1]", 1, true) ~= nil, "includes ADDK disassembly")
		expect(string.find(dump, "local x: R0", 1, true) ~= nil, "includes local debug info")
		sert.eq(bcb:dumpEverything(), dump)
	end)

	sert.prop("round-trips arbitrary number and string constant pools through binary serialization", function(g)
		local nums: { number } = g:draw(gen.list(gen.int(-100000, 100000), 1, 16))
		local bcb = BytecodeBuilder.new()
		local fid = bcb:beginFunction(0, false)
		local cids: { number } = table.create(#nums) :: any
		for i, n in nums do
			bcb:setDebugLine(i)
			cids[i] = bcb:addConstantNumber(n)
			bcb:emitAD(Opcodes.LOP_LOADK, 0, cids[i])
		end
		bcb:emitABC(Opcodes.LOP_RETURN, 0, 2, 0)
		bcb:endFunction(2, 0, 0)
		bcb:setMainFunction(fid)
		bcb:finalize()

		local mod = assert(BytecodeCodec.deserialize(bcb:getBytecode()))
		local memMod = bcb:toProtoModule()
		sert.eq(#mod.protos[1].code, #nums + 1)
		sert.eq(#memMod.protos[1].code, #nums + 1)
		for i, n in nums do
			local cid = cids[i]
			sert.eq(mod.protos[1].kValues[cid + 1], n)
			sert.eq(memMod.protos[1].kValues[cid + 1], n)
		end
	end, { runs = 40 })

	laws.codec("ImportId 1/2/3-part pack and unpack", {
		gen = function(g)
			local count = g:int(1, 3)
			local id0 = g:int(0, 1023)
			local id1 = if count >= 2 then g:int(0, 1023) else -1
			local id2 = if count >= 3 then g:int(0, 1023) else -1
			return { count = count, id0 = id0, id1 = id1, id2 = id2 }
		end,
		encode = function(v)
			if v.count == 1 then
				return BytecodeBuilder.getImportId(v.id0)
			elseif v.count == 2 then
				return BytecodeBuilder.getImportId(v.id0, v.id1)
			else
				return BytecodeBuilder.getImportId(v.id0, v.id1, v.id2)
			end
		end,
		decode = function(iid: number)
			local c, a0, a1, a2 = BytecodeCodec.decomposeImportId(iid)
			return { count = c, id0 = a0, id1 = a1, id2 = a2 }
		end,
		eq = function(a, b)
			return a.count == b.count and a.id0 == b.id0 and a.id1 == b.id1 and a.id2 == b.id2
		end,
	}, { runs = 100 })

	laws.codec("BytecodeBuilder constant pool and instruction serialization", {
		gen = function(g)
			return {
				vecX = gen.boundaryInt(-1000000, 1000000)(g),
				bFloat = gen.boundaryFloat(-1e5, 1e5)(g),
				str = gen.malformedString()(g),
				flag = g:bool(),
			}
		end,
		encode = function(item)
			local bcb = BytecodeBuilder.new()
			local fid = bcb:beginFunction(1, true)
			bcb:addConstantNil()
			bcb:addConstantBoolean(item.flag)
			bcb:addConstantNumber(item.bFloat)
			bcb:addConstantString(item.str)
			bcb:addConstantVectord(item.vecX, 1.5, -2.5, 0)
			bcb:emitABC(Opcodes.LOP_RETURN, 0, 1, 0)
			bcb:endFunction(2, 0, ProtoFlags.LPF_INLINABLE, 10, 0)
			bcb:setMainFunction(fid)
			bcb:finalize()
			return bcb:getBytecode()
		end,
		decode = function(bc: string)
			local mod = assert(BytecodeCodec.deserialize(bc))
			local kValues = mod.protos[1].kValues
			return {
				vecX = kValues[5][1],
				bFloat = kValues[3],
				str = kValues[4],
				flag = kValues[2],
			}
		end,
		eq = function(a: any, b: any)
			local af: number = a.bFloat
			local bf: number = b.bFloat
			local floatEq = if af ~= af then bf ~= bf elseif af == 0 and bf == 0 then (1 / af == 1 / bf) else af == bf
			return a.vecX == b.vecX and floatEq and a.str == b.str and a.flag == b.flag
		end,
	}, { runs = 80 })

	test("serializes, disassembles, and deserializes classes, vectors, userdata types, and feedback slots", function()
		-- Verify function and table encoders (function form encodes opcode only and preserves 2-word aux words)
		local encodedOps: { number } = {}
		local bFnEnc = BytecodeBuilder.new(function(op: number): number
			table.insert(encodedOps, op)
			return bit32.band(op * 7 + 3, 0xff)
		end)
		bFnEnc:setDumpFlags(bit32.bor(BytecodeBuilder.DumpFlags.Code, BytecodeBuilder.DumpFlags.Source))
		bFnEnc:setDumpSource("local g = foo")
		local fFnEnc = bFnEnc:beginFunction(0, false)
		local kGlob = bFnEnc:addConstantString("foo")
		bFnEnc:setDebugLine(1)
		bFnEnc:emitABC(Opcodes.LOP_GETGLOBAL, 0, 0, 0)
		bFnEnc:emitAux(kGlob)
		bFnEnc:emitABC(Opcodes.LOP_RETURN, 0, 2, 0)
		bFnEnc:endFunction(2, 0, 0)
		bFnEnc:setMainFunction(fFnEnc)
		bFnEnc:finalize()
		sert.eq(#encodedOps, 2)
		sert.eq(encodedOps[1], Opcodes.LOP_GETGLOBAL)
		sert.eq(encodedOps[2], Opcodes.LOP_RETURN)
		local encodedMod = assert(BytecodeCodec.deserialize(bFnEnc:getBytecode()))
		sert.eq(bit32.band(encodedMod.protos[1].code[1], 0xff), bit32.band(Opcodes.LOP_GETGLOBAL * 7 + 3, 0xff))
		sert.eq(encodedMod.protos[1].code[2], kGlob)
		sert.eq(bit32.band(encodedMod.protos[1].code[3], 0xff), bit32.band(Opcodes.LOP_RETURN * 7 + 3, 0xff))
		expect(string.find(bFnEnc:dumpEverything(), "GETGLOBAL", 1, true) ~= nil, "dump stays unencoded")
		expect(
			string.find(bFnEnc:dumpEverything(), "local g = foo", 1, true) ~= nil,
			"DumpFlags.Source prints source line"
		)

		local bTblEnc = BytecodeBuilder.new({
			encode = function(_self: any, insns: { number })
				for i = 1, #insns do
					insns[i] = bit32.bxor(insns[i], 0x5a)
				end
			end,
		}, nil, { retainProto = true })
		local fTblEnc = bTblEnc:beginFunction(0, false)
		bTblEnc:emitABC(Opcodes.LOP_RETURN, 0, 1, 0)
		bTblEnc:endFunction(2, 0, 0)
		bTblEnc:setMainFunction(fTblEnc)
		bTblEnc:finalize()
		expect(#bTblEnc:getBytecode() > 0, "encoded bytecode non-empty")
		sert.eq(bit32.band(bTblEnc:toProtoModule().protos[1].code[1], 0xff), Opcodes.LOP_RETURN)
		sert.eq(
			bit32.band(assert(BytecodeCodec.deserialize(bTblEnc:getBytecode())).protos[1].code[1], 0xff),
			bit32.bxor(Opcodes.LOP_RETURN, 0x5a)
		)
		sert.throws(function()
			local badBcb = BytecodeBuilder.new({} :: any)
			local fBad = badBcb:beginFunction(0, false)
			badBcb:emitABC(Opcodes.LOP_RETURN, 0, 1, 0)
			badBcb:endFunction(2, 0, 0)
			badBcb:setMainFunction(fBad)
			badBcb:finalize()
		end, "Invalid BytecodeEncoder")

		local bcb = BytecodeBuilder.new(nil, {
			DebugLuauUserDefinedClasses = true,
		})
		bcb:setDumpFlags(
			bit32.bor(
				BytecodeBuilder.DumpFlags.Code,
				BytecodeBuilder.DumpFlags.Lines,
				BytecodeBuilder.DumpFlags.Source,
				BytecodeBuilder.DumpFlags.Locals,
				BytecodeBuilder.DumpFlags.Remarks,
				BytecodeBuilder.DumpFlags.Types,
				BytecodeBuilder.DumpFlags.Constants
			)
		)

		local udUsed = bcb:addUserdataType("UsedUD")
		local udUnused = bcb:addUserdataType("UnusedUD")
		sert.eq(udUsed, 0)
		sert.eq(udUnused, 1)
		bcb:useUserdataType(udUsed)

		local childFid = bcb:beginFunction(1, false)
		bcb:setDebugFunctionName("childFn")
		bcb:setDebugLine(1)
		bcb:emitABC(Opcodes.LOP_RETURN, 0, 1, 0)
		bcb:endFunction(2, 1, ProtoFlags.LPF_INLINABLE, 5, 0)

		local fid = bcb:beginFunction(1, true)
		bcb:setDebugFunctionName("mainFn")
		bcb:setDebugFunctionLineDefined(1)
		bcb:setDebugLine(2)
		bcb:addDebugRemark("testing remark %d", 1)

		local kNil = bcb:addConstantNil()
		local kFalse1 = bcb:addConstantBoolean(false)
		local kFalse2 = bcb:addConstantBoolean(false)
		sert.eq(kFalse1, kFalse2)
		local kNegNum = bcb:addConstantNumber(-42)
		local kPosNum = bcb:addConstantNumber(42)
		local kVecd = bcb:addConstantVectord(1.25, -2.5, 3.75, 0.5)
		local kStrA = bcb:addConstantString("propA")
		local kStrM = bcb:addConstantString("methodM")
		local kStrC = bcb:addConstantString("MyClass")

		local shape = BytecodeBuilder.newTableShape()
		shape.keys[1] = kStrA
		shape.constants[1] = kPosNum
		shape.length = 1
		shape.hasConstants = true
		local kTblConst = bcb:addConstantTable(shape)
		local kClosure = bcb:addConstantClosure(childFid)
		local pid1 = bcb:addChildFunction(childFid)
		local pid2 = bcb:addChildFunction(childFid)
		sert.eq(pid1, pid2)

		local kClass = bcb:addClassShape({
			className = kStrC,
			numPrivateInstanceProps = 1,
			numPrivateStaticProps = 1,
			propertyNames = { kStrA },
			methodNames = { kStrM },
		})

		bcb:addCallTargetSlot(0)
		bcb:addConstructSlot(kTblConst)

		bcb:emitAD(Opcodes.LOP_LOADK, 0, kNil)
		bcb:emitAD(Opcodes.LOP_LOADK, 0, kNegNum)
		bcb:emitAD(Opcodes.LOP_LOADK, 0, kVecd)
		bcb:emitAD(Opcodes.LOP_DUPTABLE, 0, kTblConst)
		bcb:emitAD(Opcodes.LOP_DUPCLOSURE, 0, kClosure)
		bcb:emitABC(Opcodes.LOP_CAPTURE, Captures.LCT_VAL, 0, 0)
		bcb:emitABC(Opcodes.LOP_CAPTURE, Captures.LCT_REF, 0, 0)
		bcb:emitABC(Opcodes.LOP_CAPTURE, Captures.LCT_UPVAL, 0, 0)
		bcb:emitAD(Opcodes.LOP_NEWCLOSURE, 0, pid1)
		bcb:emitABC(Opcodes.LOP_NEWCLASS, 0, 255, 1)
		local auxLbl = bcb:emitLabel()
		bcb:emitAux(0xDEADBEEF)
		bcb:patchAux(auxLbl, kClass)
		bcb:emitABC(Opcodes.LOP_NEWCLASSMEMBER, 0, 0, 1)
		bcb:emitAux(kStrM)
		bcb:emitABC(Opcodes.LOP_GETPRIVATEFIELD, 2, 0, 0)
		bcb:emitAux(0x0300)
		bcb:emitABC(Opcodes.LOP_SETPRIVATEFIELD, 2, 0, 0)
		bcb:emitAux(0)
		bcb:emitABC(Opcodes.LOP_SUBRK, 0, kPosNum, 0)
		bcb:emitAD(Opcodes.LOP_JUMPXEQKN, 0, 0)
		bcb:emitAux(kPosNum)
		bcb:emitE(Opcodes.LOP_JUMPX, 0)

		-- Test undoEmit adjusting debugLocals and typedLocals endpc
		local beforeUndo = bcb:getInstructionCount()
		bcb:emitABC(Opcodes.LOP_NOP, 0, 0, 0)
		bcb:pushDebugLocal("tempVar", 0, 0, beforeUndo + 1)
		bcb:pushLocalTypeInfo(BytecodeDefs.Types.LBC_TYPE_NUMBER, 0, 0, beforeUndo + 1)
		bcb:pushDebugUpval("upVar")
		bcb:pushUpvalTypeInfo(BytecodeDefs.Types.LBC_TYPE_ANY)
		bcb:setFunctionTypeInfo(string.char(BytecodeDefs.Types.LBC_TYPE_FUNCTION, 0, 0))
		bcb:undoEmit(Opcodes.LOP_NOP)

		bcb:emitABC(Opcodes.LOP_RETURN, 0, 1, 0)
		bcb:endFunction(4, 1, ProtoFlags.LPF_INLINABLE, 12, 0)
		bcb:setMainFunction(fid)
		bcb:finalize()

		local dumpAll = bcb:dumpEverything()
		expect(string.find(dumpAll, "MyClass", 1, true) ~= nil, "dump includes class shape")
		expect(string.find(dumpAll, "GETPRIVATEFIELD", 1, true) ~= nil, "dump includes GETPRIVATEFIELD")
		expect(string.find(dumpAll, "SETPRIVATEFIELD", 1, true) ~= nil, "dump includes SETPRIVATEFIELD")
		expect(string.find(dumpAll, "UPVAL", 1, true) ~= nil, "dump includes UPVAL capture")
		expect(string.find(bcb:dumpSourceRemarks(), "testing remark 1", 1, true) ~= nil, "dumpSourceRemarks")
		expect(string.find(bcb:dumpTypeInfo(), "UsedUD", 1, true) ~= nil, "dumpTypeInfo includes userdata")

		local rawBytes = bcb:getBytecode()
		local modFromStr = assert(BytecodeCodec.deserialize(rawBytes))
		local modFromBuf = assert(BytecodeCodec.deserialize(buffer.fromstring(rawBytes)))
		local memMod = bcb:toProtoModule()
		sert.eq(modFromStr.version, BytecodeDefs.Tags.LBC_VERSION_CLASSES)
		sert.eq(#modFromStr.protos, 2)
		sert.eq(#modFromBuf.protos, 2)
		sert.eq(#memMod.protos, 2)
		local clsShape = modFromStr.protos[2].kValues[kClass + 1]
		sert.eq(clsShape.numPrivateInstanceProps, 1)
		sert.eq(clsShape.numPrivateStaticProps, 1)
		sert.eq(#assert(clsShape.propertyNames), 1)
		sert.eq(#assert(clsShape.methodNames), 1)
		local udTypes = assert(modFromStr.userdataTypes, "userdataTypes table")
		sert.eq(udTypes[1], "UsedUD")
		local locvars = assert(modFromStr.protos[2].locvars, "deserialized locvars")
		local upvalues = assert(modFromStr.protos[2].upvalues, "deserialized upvalues")
		sert.eq(#locvars, 1)
		sert.eq(#upvalues, 1)

		-- Test expandJumps (long jump expansion for LOP_JUMP and conditional jump trampolines) and applyJumpRemap
		local bcbLong = BytecodeBuilder.new()
		bcbLong:setDumpFlags(0xFF)
		local fidLong = bcbLong:beginFunction(0, false)
		local kZero = bcbLong:addConstantNumber(0)
		local kClsStr = bcbLong:addConstantString("LongCls")
		local kCls = bcbLong:addClassShape({ className = kClsStr, propertyNames = {}, methodNames = {} })
		bcbLong:addCallTargetSlot(0)
		local j1 = bcbLong:emitLabel()
		bcbLong:emitAD(Opcodes.LOP_JUMP, 0, 0)
		local j2 = bcbLong:emitLabel()
		bcbLong:emitAD(Opcodes.LOP_JUMPIF, 0, 0)
		local j3 = bcbLong:emitLabel()
		bcbLong:emitAD(Opcodes.LOP_JUMPXEQKN, 0, 0)
		bcbLong:emitAux(kZero)
		for _ = 1, 32770 do
			bcbLong:emitABC(Opcodes.LOP_NOP, 0, 0, 0)
		end
		local endLbl = bcbLong:emitLabel()
		bcbLong:emitABC(Opcodes.LOP_CONSTRUCT, 0, 1, 1)
		bcbLong:emitAux(kCls)
		bcbLong:emitABC(Opcodes.LOP_NEWCLASS, 0, 1, 0)
		bcbLong:emitAux(kCls)
		bcbLong:emitABC(Opcodes.LOP_RETURN, 0, 1, 0)
		bcbLong:pushDebugLocal("longVar", 0, 1, 10)
		bcbLong:pushLocalTypeInfo(BytecodeDefs.Types.LBC_TYPE_NUMBER, 0, 1, 10)
		sert.eq(bcbLong:patchJumpD(j1, endLbl), true, "marks hasLongJumps for LOP_JUMP")
		sert.eq(bcbLong:patchJumpD(j2, endLbl), true, "marks hasLongJumps for LOP_JUMPIF")
		sert.eq(bcbLong:patchJumpD(j3, endLbl), true, "marks hasLongJumps for LOP_JUMPXEQKN")
		bcbLong:foldJumps()
		sert.eq(bcbLong:expandJumps(), false, "expandJumps succeeds")
		bcbLong:endFunction(2, 0, 0, 0, 0)
		bcbLong:setMainFunction(fidLong)
		bcbLong:finalize()
		local longDump = bcbLong:dumpEverything()
		expect(string.find(longDump, "CONSTRUCT", 1, true) ~= nil, "dump includes CONSTRUCT")
	end)

	test("constructs direct retainProto ProtoModule structurally identical to BytecodeBuilder.deserialize", function()
		local builderFlags = {
			DebugLuauUserDefinedClasses = true,
		}

		local function populateModule(bcb: any)
			local ud0 = bcb:addUserdataType("VecUD")
			local _ud1 = bcb:addUserdataType("SkippedUD")
			local ud2 = bcb:addUserdataType("MatrixUD")
			bcb:useUserdataType(ud0)
			bcb:useUserdataType(ud2)

			-- Function 0: leaf function without debug lines or types
			local leafFid = bcb:beginFunction(2, false)
			bcb:emitABC(Opcodes.LOP_ADD, 0, 0, 1)
			bcb:emitABC(Opcodes.LOP_RETURN, 0, 2, 0)
			bcb:endFunction(2, 0, ProtoFlags.LPF_NATIVE_FUNCTION)

			-- Function 1: mid function with upvals, debug locals, sparse userdata type, and multi-interval lineinfo
			local midFid = bcb:beginFunction(1, true)
			bcb:setDebugFunctionName("midHelper")
			bcb:setDebugFunctionLineDefined(10)
			for i = 1, 300 do
				bcb:setDebugLine(if i % 37 == 0 then 10 + i * 20 else 10 + i)
				bcb:emitABC(Opcodes.LOP_NOP, 0, 0, 0)
			end
			bcb:setDebugLine(6500)
			bcb:emitABC(Opcodes.LOP_RETURN, 0, 1, 0)
			bcb:pushDebugLocal("arg0", 0, 0, 301)
			bcb:pushDebugLocal("tmp1", 1, 5, 250)
			bcb:pushDebugUpval("capturedUp")
			bcb:pushLocalTypeInfo(BytecodeDefs.Types.LBC_TYPE_TAGGED_USERDATA_BASE + ud2, 0, 0, 301)
			bcb:pushUpvalTypeInfo(BytecodeDefs.Types.LBC_TYPE_STRING)
			bcb:setFunctionTypeInfo(
				string.char(
					BytecodeDefs.Types.LBC_TYPE_FUNCTION,
					1,
					BytecodeDefs.Types.LBC_TYPE_TAGGED_USERDATA_BASE + ud0,
					0
				)
			)
			bcb:endFunction(3, 1, ProtoFlags.LPF_INLINABLE)

			-- Function 2: main function exercising every constant kind
			local mainFid = bcb:beginFunction(0, true)
			bcb:setDebugFunctionName("mainEntry")
			bcb:setDebugFunctionLineDefined(1)
			bcb:setDebugLine(2)

			local _kNil = bcb:addConstantNil()
			local _kTrue = bcb:addConstantBoolean(true)
			local _kFalse = bcb:addConstantBoolean(false)
			local _kZero = bcb:addConstantNumber(0.0)
			local _kNegZero = bcb:addConstantNumber(-0.0)
			local _kNan = bcb:addConstantNumber(0 / 0)
			local kPi = bcb:addConstantNumber(3.141592653589793)
			local _kVecf = bcb:addConstantVectorf(0.1, -0.2, 0.3, 0.0) -- non-dyadic float32 rounding check
			local _kVecd = bcb:addConstantVectord(0.1, -0.2, 0.3, 0.4)
			local kStrAlpha = bcb:addConstantString("alpha")
			local kStrBeta = bcb:addConstantString("beta")
			local kStrCls = bcb:addConstantString("ShapeCls")
			local _kImp1 = bcb:addImport(BytecodeBuilder.getImportId(kStrAlpha))
			local _kImp2 = bcb:addImport(BytecodeBuilder.getImportId(kStrAlpha, kStrBeta))
			local _kImp3 = bcb:addImport(BytecodeBuilder.getImportId(kStrAlpha, kStrBeta, kStrCls))

			local plainShape = BytecodeBuilder.newTableShape()
			plainShape.keys[1] = kStrAlpha
			plainShape.keys[2] = kStrBeta
			plainShape.length = 2
			local _kTblPlain = bcb:addConstantTable(plainShape)

			local constShape = BytecodeBuilder.newTableShape()
			constShape.keys[1] = kStrAlpha
			constShape.constants[1] = kPi
			constShape.length = 1
			constShape.hasConstants = true
			local _kTblConst = bcb:addConstantTable(constShape)

			local _kClosLeaf = bcb:addConstantClosure(leafFid)
			local childMidIdx = bcb:addChildFunction(midFid)
			local _childLeafIdx = bcb:addChildFunction(leafFid)

			local _kClass = bcb:addClassShape({
				className = kStrCls,
				numPrivateInstanceProps = 1,
				numPrivateStaticProps = 2,
				propertyNames = { kStrAlpha },
				methodNames = { kStrBeta },
			})

			bcb:emitAD(Opcodes.LOP_NEWCLOSURE, 0, childMidIdx)
			bcb:emitABC(Opcodes.LOP_CAPTURE, Captures.LCT_VAL, 0, 0)
			bcb:setDebugLine(3)
			bcb:emitABC(Opcodes.LOP_RETURN, 0, 2, 0)
			bcb:pushDebugLocal("fnOut", 0, 0, 3)
			bcb:endFunction(4, 0, 0)
			bcb:setMainFunction(mainFid)
			bcb:finalize()
		end

		local bcbBoth = BytecodeBuilder.new(nil, builderFlags, { serializeBytes = true, retainProto = true })
		populateModule(bcbBoth)

		local bcbProtoOnly = BytecodeBuilder.new(nil, builderFlags, { serializeBytes = false, retainProto = true })
		populateModule(bcbProtoOnly)
		sert.eq(bcbProtoOnly.bytecode, "")
		local fwProtoOnly = bcbProtoOnly.funcWriter
		sert.eq(if fwProtoOnly then fwProtoOnly.offset else 0, 0)
		local okGet = pcall(bcbProtoOnly.getBytecode, bcbProtoOnly)
		sert.eq(okGet, false)

		local expectedMod = assert(BytecodeCodec.deserialize(bcbBoth:getBytecode()))
		local directModBoth = bcbBoth:toProtoModule()
		local directModOnly = bcbProtoOnly:toProtoModule()

		Helpers.assertDeepEqual(directModBoth, expectedMod, "retainProto(serializeBytes=true)")
		Helpers.assertDeepEqual(directModOnly, expectedMod, "retainProto(serializeBytes=false)")
	end)

	test("verifies 0.748 hasLines, deferred useUserdataType string order, undoEmit, and >32k applyJumpRemap", function()
		-- 1. hasLines requires ALL instructions to have line > 0
		local partialLines = BytecodeBuilder.new()
		local fPartial = partialLines:beginFunction(0, false)
		partialLines:setDebugLine(10)
		partialLines:emitABC(Opcodes.LOP_NOP, 0, 0, 0)
		partialLines:setDebugLine(0)
		partialLines:emitABC(Opcodes.LOP_RETURN, 0, 1, 0)
		partialLines:endFunction(1, 0, 0)
		partialLines:setMainFunction(fPartial)
		partialLines:finalize()
		local partialMod = assert(BytecodeCodec.deserialize(partialLines:getBytecode()))
		sert.eq(partialMod.protos[1].lineData, nil)
		local nilLinfo, nilAbsinfo = BytecodeCodec.decodeLineInfo(partialMod.protos[1])
		sert.eq(nilLinfo, nil)
		sert.eq(nilAbsinfo, nil)

		-- 2. Deferring useUserdataType string interning to finalize preserves pre-existing string table order
		local udFirst = BytecodeBuilder.new()
		local udSlot = udFirst:addUserdataType("TailUD")
		udFirst:useUserdataType(udSlot)
		local fUd = udFirst:beginFunction(1, false)
		local kAlpha = udFirst:addConstantString("alpha")
		sert.eq(kAlpha, 0)
		udFirst:pushLocalTypeInfo(BytecodeDefs.Types.LBC_TYPE_TAGGED_USERDATA_BASE + udSlot, 0, 0, 1)
		udFirst:emitABC(Opcodes.LOP_RETURN, 0, 1, 0)
		udFirst:endFunction(1, 0, 0)
		udFirst:setMainFunction(fUd)
		udFirst:finalize()
		local udBytes = udFirst:getBytecode()
		local udMod = assert(BytecodeCodec.deserialize(udBytes))
		local alphaPos = string.find(udBytes, "alpha", 1, true)
		local tailUdPos = string.find(udBytes, "TailUD", 1, true)
		expect(
			alphaPos ~= nil and tailUdPos ~= nil and (alphaPos :: number) < (tailUdPos :: number),
			"alpha precedes deferred TailUD in string table"
		)
		local udTypes2 = assert(udMod.userdataTypes, "userdataTypes")
		sert.eq(udTypes2[1], "TailUD")
		expect(string.find(udFirst:dumpTypeInfo(), "TailUD", 1, true) ~= nil, "tagged userdata in type dump")

		-- 3. undoEmit erases startpc == oldSize and decrements all endpc == oldSize without early break
		local bcbUndo = BytecodeBuilder.new()
		local fUndo = bcbUndo:beginFunction(0, false)
		bcbUndo:emitABC(Opcodes.LOP_NOP, 0, 0, 0) -- pc 0
		bcbUndo:emitABC(Opcodes.LOP_NOP, 0, 0, 0) -- pc 1
		bcbUndo:pushDebugLocal("earlierEnded", 0, 0, 1)
		bcbUndo:pushDebugLocal("atOldSize", 1, 0, 3)
		bcbUndo:pushLocalTypeInfo(BytecodeDefs.Types.LBC_TYPE_NUMBER, 1, 0, 3)
		bcbUndo:emitABC(Opcodes.LOP_NOP, 0, 0, 0) -- pc 2 (will be undone; oldSize = 3)
		bcbUndo:pushDebugLocal("droppedLocal", 2, 3, 4)
		bcbUndo:pushLocalTypeInfo(BytecodeDefs.Types.LBC_TYPE_STRING, 2, 3, 4)
		bcbUndo:pushDebugLocal("atOldSize2", 3, 1, 3)
		bcbUndo:undoEmit(Opcodes.LOP_NOP)
		bcbUndo:emitABC(Opcodes.LOP_RETURN, 0, 1, 0)
		bcbUndo:endFunction(4, 0, 0)
		bcbUndo:setMainFunction(fUndo)
		bcbUndo:finalize()
		local undoMod = assert(BytecodeCodec.deserialize(bcbUndo:getBytecode()))
		local undoVars = assert(undoMod.protos[1].locvars, "locvars after undo")
		sert.eq(#undoVars, 3)
		sert.eq(undoVars[1].varname, "earlierEnded")
		sert.eq(undoVars[1].endpc, 1)
		sert.eq(undoVars[2].varname, "atOldSize")
		sert.eq(undoVars[2].endpc, 2)
		sert.eq(undoVars[3].varname, "atOldSize2")
		sert.eq(undoVars[3].endpc, 2)

		-- 4. applyJumpRemap preserves exclusive endpc (+1) on >32k expansion
		local bcbRemap = BytecodeBuilder.new()
		local fRemap = bcbRemap:beginFunction(0, false)
		bcbRemap:emitABC(Opcodes.LOP_NOP, 0, 0, 0) -- pc 0
		local jmpLbl = bcbRemap:emitLabel()
		bcbRemap:emitAD(Opcodes.LOP_JUMP, 0, 0) -- pc 1 (expands to JUMP +1; JUMPX; JUMP -2 -> remap[2] = 3)
		for _ = 1, 32775 do
			bcbRemap:emitABC(Opcodes.LOP_NOP, 0, 0, 0)
		end
		local tgtLbl = bcbRemap:emitLabel()
		bcbRemap:emitABC(Opcodes.LOP_RETURN, 0, 1, 0)
		bcbRemap:pushDebugLocal("endingAtJump", 0, 0, 1)
		bcbRemap:pushDebugLocal("liveAcross", 1, 0, 3)
		bcbRemap:pushDebugLocal("emptyRange", 2, 1, 1)
		sert.eq(bcbRemap:patchJumpD(jmpLbl, tgtLbl), true, "marks long jump")
		sert.eq(bcbRemap:expandJumps(), false, "expandJumps succeeds")
		bcbRemap:endFunction(3, 0, 0)
		bcbRemap:setMainFunction(fRemap)
		bcbRemap:finalize()
		local remapMod = assert(BytecodeCodec.deserialize(bcbRemap:getBytecode()))
		local rvars = assert(remapMod.protos[1].locvars, "remapped locvars")
		sert.eq(rvars[1].startpc, 0)
		sert.eq(rvars[1].endpc, 1)
		sert.eq(rvars[2].startpc, 0)
		sert.eq(rvars[2].endpc, 5)
		sert.eq(rvars[3].startpc, 3)
		sert.eq(rvars[3].endpc, 3)
	end)

	test(
		"supports standalone Bytecode.disassemble, DumpFlags.Lines label ordering, guarded dumpCurrentFunction, and strict binary codec validation",
		function()
			local Ouro = require("../")
			local BytecodeCodec = require("../src/BytecodeCodec")
			local Compiler = require("../src/Compiler")
			local Tags = BytecodeDefs.Tags

			-- 1. Standalone Ouro.Bytecode.disassemble on bytecode string, buffer, and ProtoModule (plus GET/SETUDATAKS/NAMECALLUDATA)
			local bc = assert(Compiler.compile("local a = 1 + 2\nreturn a", { optimizationLevel = 2, debugLevel = 2 }))
			local mod = assert(BytecodeCodec.deserialize(bc))
			local flagsAll = bit32.bor(
				BytecodeBuilder.DumpFlags.Code,
				BytecodeBuilder.DumpFlags.Lines,
				BytecodeBuilder.DumpFlags.Locals,
				BytecodeBuilder.DumpFlags.Constants
			)
			local dStr = Ouro.Bytecode.disassemble(bc, flagsAll)
			local dBuf = Ouro.Bytecode.disassemble(buffer.fromstring(bc), flagsAll)
			local dMod = Ouro.Bytecode.disassemble(mod, flagsAll)
			expect(
				#dStr > 0 and dStr == dBuf and dStr == dMod,
				"disassemble agrees across string, buffer, and ProtoModule"
			)

			local udataBcb = BytecodeBuilder.new()
			udataBcb:setDumpFlags(flagsAll)
			sert.eq(udataBcb:dumpCurrentFunction(), "")
			local uFid = udataBcb:beginFunction(1, false)
			local kProp = udataBcb:addConstantString("prop")
			local kMeth = udataBcb:addConstantString("meth")
			udataBcb:setDebugLine(3)
			udataBcb:emitABC(Opcodes.LOP_GETUDATAKS, 1, 0, 0)
			udataBcb:emitAux(kProp)
			udataBcb:emitABC(Opcodes.LOP_SETUDATAKS, 1, 0, 0)
			udataBcb:emitAux(kProp)
			udataBcb:emitABC(Opcodes.LOP_NAMECALLUDATA, 1, 0, 0)
			udataBcb:emitAux(kMeth)
			udataBcb:emitABC(Opcodes.LOP_RETURN, 1, 1, 0)
			udataBcb:endFunction(4, 0, 0)
			sert.eq(udataBcb:dumpCurrentFunction(), "")
			udataBcb:setMainFunction(uFid)
			udataBcb:finalize()
			local uDump = Ouro.Bytecode.disassemble(udataBcb:getBytecode(), flagsAll)
			expect(string.find(uDump, "GETUDATAKS", 1, true) ~= nil, "disassembles GETUDATAKS")
			expect(string.find(uDump, "SETUDATAKS", 1, true) ~= nil, "disassembles SETUDATAKS")
			expect(string.find(uDump, "NAMECALLUDATA", 1, true) ~= nil, "disassembles NAMECALLUDATA")
			expect(string.find(uDump, "    3: ", 1, true) ~= nil, "Dump_Lines formats line prefix cleanly")

			-- 2. Malformed binary input validation in BytecodeCodec.deserialize
			local function writeVarInt(buf: { string }, n: number)
				repeat
					local b = bit32.band(n, 0x7f)
					n = bit32.rshift(n, 7)
					if n > 0 then
						b = bit32.bor(b, 0x80)
					end
					buf[#buf + 1] = string.char(b)
				until n == 0
			end
			type ProtoBodyOpts = {
				maxstack: number?,
				numparams: number?,
				kRaw: string?,
				kCount: number?,
				pRaw: string?,
				pCount: number?,
			}
			local function encodeProtoBody(opts: ProtoBodyOpts): string
				local protoBody = {
					string.char(opts.maxstack or 2, opts.numparams or 0, 0, 0, 0),
					string.char(0), -- typeinfo size
					string.char(1), -- sizecode = 1
					string.char(Opcodes.LOP_RETURN, 0, 1, 0),
				}
				local kCountParts: { string } = {}
				writeVarInt(kCountParts, opts.kCount or 0)
				protoBody[#protoBody + 1] = table.concat(kCountParts)
				if opts.kRaw then
					protoBody[#protoBody + 1] = opts.kRaw
				end
				local pCountParts: { string } = {}
				writeVarInt(pCountParts, opts.pCount or 0)
				protoBody[#protoBody + 1] = table.concat(pCountParts)
				if opts.pRaw then
					protoBody[#protoBody + 1] = opts.pRaw
				end
				protoBody[#protoBody + 1] = string.char(1, 0, 0, 0, 0) -- linedefined=1, debugname=0, hasLines=0, hasDebug=0, feedbackvecsize=0
				local bodyStr = table.concat(protoBody)
				local sizeParts: { string } = {}
				writeVarInt(sizeParts, #bodyStr)
				return table.concat(sizeParts) .. bodyStr
			end
			local function buildMinV14(opts: {
				maxstack: number?,
				numparams: number?,
				userdataRaw: string?,
				kRaw: string?,
				kCount: number?,
				pRaw: string?,
				pCount: number?,
				trailing: string?,
			}): string
				local parts = {
					string.char(Tags.LBC_VERSION_TARGET, Tags.LBC_TYPE_VERSION_TARGET),
					string.char(1, 1, string.byte("x")), -- 1 string: "x"
					opts.userdataRaw or string.char(0), -- userdata sentinel
					string.char(1), -- protoCount = 1
					encodeProtoBody(opts),
					string.char(0), -- mainid = 0
					opts.trailing or "",
				}
				return table.concat(parts)
			end
			local function buildTwoProtoV14(opts: ProtoBodyOpts): string
				local parts = {
					string.char(Tags.LBC_VERSION_TARGET, Tags.LBC_TYPE_VERSION_TARGET),
					string.char(1, 1, string.byte("x")), -- 1 string: "x"
					string.char(0), -- userdata sentinel
					string.char(2), -- protoCount = 2
					encodeProtoBody({}), -- proto 0
					encodeProtoBody(opts), -- proto 1
					string.char(1), -- mainid = 1
				}
				return table.concat(parts)
			end

			local codecCases: { { name: string, data: any, match: string } } = {
				{
					name = "closure fid OOB",
					data = buildMinV14({ kCount = 1, kRaw = string.char(Tags.LBC_CONSTANT_CLOSURE, 5) }),
					match = "closure",
				},
				{
					name = "closure self-cycle fid == protoId",
					data = buildMinV14({ kCount = 1, kRaw = string.char(Tags.LBC_CONSTANT_CLOSURE, 0) }),
					match = "closure",
				},
				{
					name = "child proto OOB",
					data = buildMinV14({ pCount = 1, pRaw = string.char(5) }),
					match = "child proto",
				},
				{
					name = "child proto forward/self pid == protoId",
					data = buildMinV14({ pCount = 1, pRaw = string.char(0) }),
					match = "child proto",
				},
				{
					name = "numparams > maxstacksize",
					data = buildMinV14({ maxstack = 1, numparams = 2 }),
					match = "numparams",
				},
				{
					name = "table constant key OOB",
					data = buildMinV14({
						kCount = 1,
						kRaw = string.char(Tags.LBC_CONSTANT_TABLE, 1, 5),
					}),
					match = "table",
				},
				{
					name = "table_with_constants nil key",
					data = buildMinV14({
						kCount = 2,
						kRaw = string.char(Tags.LBC_CONSTANT_NIL)
							.. string.char(Tags.LBC_CONSTANT_TABLE_WITH_CONSTANTS, 1, 0, 0, 0, 0, 0),
					}),
					match = "table",
				},
				{
					name = "table_with_constants NaN key",
					data = buildMinV14({
						kCount = 2,
						kRaw = string.char(Tags.LBC_CONSTANT_NUMBER, 0, 0, 0, 0, 0, 0, 0xf8, 0x7f)
							.. string.char(Tags.LBC_CONSTANT_TABLE_WITH_CONSTANTS, 1, 0, 0, 0, 0, 0),
					}),
					match = "table",
				},
				{
					name = "table_with_constants forward cyclic constant",
					data = buildMinV14({
						kCount = 2,
						kRaw = string.char(Tags.LBC_CONSTANT_TABLE_WITH_CONSTANTS, 1, 1, 1, 1)
							.. string.char(Tags.LBC_CONSTANT_STRING, 1),
					}),
					match = "table",
				},
				{
					name = "table_with_constants closure value",
					data = buildTwoProtoV14({
						kCount = 3,
						kRaw = string.char(Tags.LBC_CONSTANT_STRING, 1)
							.. string.char(Tags.LBC_CONSTANT_CLOSURE, 0)
							.. string.char(Tags.LBC_CONSTANT_TABLE_WITH_CONSTANTS, 1, 0, 1, 0, 0, 0),
					}),
					match = "table constant value type",
				},
				{
					name = "table_with_constants import value",
					data = buildMinV14({
						kCount = 3,
						kRaw = string.char(Tags.LBC_CONSTANT_STRING, 1)
							.. string.char(Tags.LBC_CONSTANT_IMPORT, 0, 0, 0, 0x40)
							.. string.char(Tags.LBC_CONSTANT_TABLE_WITH_CONSTANTS, 1, 0, 1, 0, 0, 0),
					}),
					match = "table constant value type",
				},
				{
					name = "userdata index OOB",
					data = buildMinV14({ userdataRaw = string.char(99, 1, 0) }),
					match = "userdata",
				},
				{
					name = "userdata zero nameId",
					data = buildMinV14({ userdataRaw = string.char(1, 0, 0) }),
					match = "userdata",
				},
				{
					name = "trailing bytes after mainid",
					data = buildMinV14({ trailing = "\1\2" }),
					match = "trailing",
				},
				{
					name = "non-string/buffer input",
					data = 123,
					match = "expected bytecode string or buffer",
				},
			}
			for _, tc in codecCases do
				local modC, errC = BytecodeCodec.deserialize(tc.data)
				sert.eq(modC, nil, `must reject {tc.name}`)
				expect(string.find(string.lower(tostring(errC)), tc.match, 1, true) ~= nil, `{tc.name}: {errC}`)
			end
			sert.throws(function()
				BytecodeCodec.decodeLineInfo({ code = { 0 }, lineData = "12345678", linegaplog2 = 32 } :: any)
			end, "invalid lineinfo bounds")
			sert.throws(function()
				BytecodeCodec.decodeLineInfo({ code = { 0 }, lineData = "bad", linegaplog2 = 0 } :: any)
			end, "invalid lineinfo bounds")

			-- 3. Disassembly of >260 lines, decodeLineInfo(proto), typesversion == 1, and unknown type byte
			local longLines: { string } = { "local acc = 0" }
			for i = 1, 270 do
				longLines[#longLines + 1] = `acc += {i}`
			end
			longLines[#longLines + 1] = "return acc"
			local longBc =
				assert(Compiler.compile(table.concat(longLines, "\n"), { optimizationLevel = 1, debugLevel = 1 }))
			local fastMod = assert(BytecodeCodec.deserialize(longBc))
			local decodedLinfo, decodedAbsinfo = BytecodeCodec.decodeLineInfo(fastMod.protos[1])
			expect(
				decodedLinfo ~= nil
					and decodedAbsinfo ~= nil
					and #(decodedLinfo :: { number }) == #fastMod.protos[1].code,
				"decodeLineInfo returns arrays"
			)
			local fastDump = Ouro.Bytecode.disassemble(
				fastMod,
				bit32.bor(BytecodeBuilder.DumpFlags.Code, BytecodeBuilder.DumpFlags.Lines)
			)
			expect(string.find(fastDump, "  272: RETURN", 1, true) ~= nil, fastDump)

			local bcbUnknownTy = BytecodeBuilder.new()
			local fUnk = bcbUnknownTy:beginFunction(1, false)
			bcbUnknownTy:setFunctionTypeInfo(string.char(127))
			bcbUnknownTy:emitABC(Opcodes.LOP_RETURN, 0, 1, 0)
			bcbUnknownTy:endFunction(2, 1, 0)
			bcbUnknownTy:setMainFunction(fUnk)
			bcbUnknownTy:finalize()
			local unkMod = assert(BytecodeCodec.deserialize(bcbUnknownTy:getBytecode()))
			local unkModV1 = table.clone(unkMod :: any)
			unkModV1.typesversion = 1
			local unkDump = Ouro.Bytecode.disassemble(unkModV1, BytecodeBuilder.DumpFlags.Types)
			expect(string.find(unkDump, "unknown(127)", 1, true) ~= nil, unkDump)
		end
	)

	test("disassembler fixes FASTCALL labels, LOADB skips, PC-order numbering, formatting, and typeinfo", function()
		local Ouro = require("../")
		-- 1. FASTCALL* label lands AFTER the following CALL; PC labels increase sequentially
		local fastSrc =
			"local function f(x) return math.abs(x) end\nlocal function g(a, b) if a then return true end return false end\nreturn f, g"
		local resFast =
			Ouro.compileResult(fastSrc, { optimizationLevel = 2, dumpFlags = BytecodeBuilder.DumpFlags.Code })
		sert.eq(resFast.status, "ok")
		local dumpFast = (resFast.builder :: any):dumpEverything()
		local fcTarget = string.match(dumpFast, "FASTCALL1%s+%d+%s+R%d+%s+L(%d+)")
		expect(fcTarget ~= nil, "expected FASTCALL1 label in:\n" .. dumpFast)
		expect(
			string.find(dumpFast, "CALL%s+R%d+%s+%d+%s+%d+%s*\nL" .. fcTarget :: string .. ":") ~= nil,
			"FASTCALL target label must land immediately after CALL:\n" .. dumpFast
		)

		-- 2. LOADB with skip > 0 emits jump target label in disassembly
		local bcb = BytecodeBuilder.new()
		local fid = bcb:beginFunction(0, false)
		bcb:emitABC(Opcodes.LOP_LOADB, 0, 1, 1)
		bcb:emitABC(Opcodes.LOP_LOADB, 0, 0, 0)
		bcb:emitABC(Opcodes.LOP_RETURN, 0, 2, 0)
		bcb:endFunction(1, 0)
		bcb:setMainFunction(fid)
		bcb:finalize()
		local loadbDump = Ouro.Bytecode.disassemble(bcb:toProtoModule(), BytecodeBuilder.DumpFlags.Code)
		expect(string.find(loadbDump, "LOADB R0 1 L0", 1, true) ~= nil, loadbDump)
		expect(string.find(loadbDump, "L0:\nRETURN R0 1", 1, true) ~= nil, loadbDump)

		-- 3. Labels are numbered in ascending PC order even when an earlier jump points forward past a backward loop
		local pcOrderBcb = BytecodeBuilder.new()
		local pcFid = pcOrderBcb:beginFunction(0, false)
		pcOrderBcb:emitAD(Opcodes.LOP_JUMP, 0, 3) -- jumps forward to pc 4
		pcOrderBcb:emitABC(Opcodes.LOP_LOADN, 0, 1, 0) -- pc 1
		pcOrderBcb:emitAD(Opcodes.LOP_JUMPBACK, 0, -2) -- pc 2 -> pc 1 (earlier target -> L0)
		pcOrderBcb:emitABC(Opcodes.LOP_LOADNIL, 0, 0, 0) -- pc 3
		pcOrderBcb:emitABC(Opcodes.LOP_RETURN, 0, 1, 0) -- pc 4 (later target -> L1)
		pcOrderBcb:endFunction(1, 0)
		pcOrderBcb:setMainFunction(pcFid)
		pcOrderBcb:finalize()
		local pcDump = Ouro.Bytecode.disassemble(pcOrderBcb:toProtoModule(), BytecodeBuilder.DumpFlags.Code)
		expect(string.find(pcDump, "JUMP L1", 1, true) ~= nil, pcDump)
		expect(string.find(pcDump, "JUMPBACK L0", 1, true) ~= nil, pcDump)

		-- 4. Structural instruction syntax parity + readable dumpTypeInfo + 4-arg decoder
		local fmtBcb = BytecodeBuilder.new()
		fmtBcb:setDumpFlags(bit32.bor(BytecodeBuilder.DumpFlags.Code, BytecodeBuilder.DumpFlags.Types))
		local ffid = fmtBcb:beginFunction(2, false)
		fmtBcb:setDebugFunctionName("typed")
		local kNum = fmtBcb:addConstantNumber(5)
		local kStr = fmtBcb:addConstantString("Base")
		fmtBcb:emitABC(Opcodes.LOP_CALLFB, 0, 2, 1) -- pc 0,1
		fmtBcb:emitAux(0)
		local jxLbl = fmtBcb:emitLabel()
		fmtBcb:emitAD(Opcodes.LOP_JUMPXEQKN, 0, 0) -- pc 2,3
		fmtBcb:emitAux(0x80000000 + kNum)
		local cpLbl = fmtBcb:emitLabel()
		fmtBcb:emitAD(Opcodes.LOP_CMPPROTO, 0, 0) -- pc 4,5
		fmtBcb:emitAux(0)
		fmtBcb:emitABC(Opcodes.LOP_FASTPCALL, 0, 0, 5) -- pc 6 -> target 6 + 2 + 5 = 13 (RETURN)
		fmtBcb:emitABC(Opcodes.LOP_NEWCLASS, 1, 0xff, 0) -- pc 7,8
		fmtBcb:emitAux(kStr)
		fmtBcb:emitABC(Opcodes.LOP_CONSTRUCT, 2, 1, 0) -- pc 9,10
		fmtBcb:emitAux(4)
		fmtBcb:emitABC(Opcodes.LOP_NOP, 0, 0, 0) -- pc 11
		fmtBcb:emitABC(Opcodes.LOP_NOP, 0, 0, 0) -- pc 12
		local retLbl = fmtBcb:emitLabel() -- pc 13
		fmtBcb:emitABC(Opcodes.LOP_RETURN, 0, 1, 0)
		assert(fmtBcb:patchJumpD(jxLbl, retLbl))
		assert(fmtBcb:patchJumpD(cpLbl, retLbl))
		fmtBcb:setFunctionTypeInfo(
			string.char(
				BytecodeDefs.Types.LBC_TYPE_FUNCTION,
				2,
				BytecodeDefs.Types.LBC_TYPE_NUMBER,
				bit32.bor(BytecodeDefs.Types.LBC_TYPE_STRING, 0x80)
			)
		)
		fmtBcb:endFunction(4, 0)
		fmtBcb:setMainFunction(ffid)
		fmtBcb:finalize()
		local fmtMod = fmtBcb:toProtoModule()
		local fullDump = Ouro.Bytecode.disassemble(
			fmtMod,
			bit32.bor(BytecodeBuilder.DumpFlags.Code, BytecodeBuilder.DumpFlags.Types)
		)
		expect(string.find(fullDump, "CALLFB R0 1 0 [0]", 1, true) ~= nil, fullDump)
		expect(string.find(fullDump, "JUMPXEQKN R0 K0 L0 NOT [5]", 1, true) ~= nil, fullDump)
		expect(string.find(fullDump, "CMPPROTO R0 #0 L0", 1, true) ~= nil, fullDump)
		expect(string.find(fullDump, "FASTPCALL pcall L0", 1, true) ~= nil, fullDump)
		expect(string.find(fullDump, "NEWCLASS R1 no_base 0 K1 ['Base']", 1, true) ~= nil, fullDump)
		expect(string.find(fullDump, "CONSTRUCT R2 R1 slot 4", 1, true) ~= nil, fullDump)
		expect(string.find(fullDump, "(number, string?)", 1, true) ~= nil, fullDump)
		local typeDump = fmtBcb:dumpTypeInfo()
		expect(string.find(typeDump, "0: function(number, string?)", 1, true) ~= nil, typeDump)

		-- 5. Malformed / cyclic ProtoModule does not crash disassemble
		local cyclicConst: any = { shape = { 1 }, keys = { 1 } }
		cyclicConst.keys = { cyclicConst }
		local malformedMod: any = {
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
					code = { Opcodes.LOP_JUMPXEQKN, 0x80000000, Opcodes.LOP_RETURN },
					kTypes = {
						BytecodeDefs.Tags.LBC_CONSTANT_NUMBER,
						BytecodeDefs.Tags.LBC_CONSTANT_VECTOR,
						BytecodeDefs.Tags.LBC_CONSTANT_TABLE_WITH_CONSTANTS,
					},
					kValues = {
						"bad" :: any,
						"bad" :: any,
						cyclicConst,
					},
					p = {},
					locvars = {},
					upvalues = {},
				},
			},
		}
		local safeOut = Ouro.Bytecode.disassemble(malformedMod, BytecodeBuilder.DumpFlags.Code)
		expect(string.find(safeOut, "RETURN", 1, true) ~= nil, safeOut)

		-- 6. 4-arg disassemble with decoder matches canonical bytecode disassembly
		local canonBc = assert(Ouro.compile("local a = 1 + 2; return math.abs(-a)", { optimizationLevel = 2 }))
		local encBc = assert(Ouro.compile("local a = 1 + 2; return math.abs(-a)", {
			optimizationLevel = 2,
			encoder = function(op: number): number
				return (op * 227) % 256
			end,
		}))
		local expectedDisasm = Ouro.Bytecode.disassemble(canonBc, BytecodeBuilder.DumpFlags.Code)
		local decodedDisasm = Ouro.Bytecode.disassemble(
			encBc,
			BytecodeBuilder.DumpFlags.Code,
			nil,
			function(op: number): number
				return (op * 203) % 256
			end
		)
		sert.eq(decodedDisasm, expectedDisasm)
	end)

	test("rejects unknown v12+ feedbackvec slot type during deserialization", function()
		-- Build minimal valid v14 bytecode carrying an invalid feedbackvec slot type (99)
		local badFeedbackBc = string.char(
			14, -- version 14
			3, -- typesversion 3
			0, -- stringCount = 0
			0, -- userdataTypes terminator = 0 (typesversion == 3)
			1, -- protoCount = 1
			20, -- protoSize = 20
			0, -- maxstacksize
			0, -- numparams
			0, -- nups
			0, -- isvararg
			0, -- flags
			0, -- typesize
			1, -- sizecode = 1
			Opcodes.LOP_RETURN,
			0,
			1,
			0, -- RETURN
			0, -- sizek
			0, -- sizep
			0, -- linedefined
			0, -- debugname
			0, -- hasLineInfo
			0, -- hasDebugInfo
			1, -- sizefeedback = 1 (unknown slot type 99)
			99,
			0,
			0 -- mainid = 0
		)
		local modFb, errFb = BytecodeCodec.deserialize(badFeedbackBc)
		sert.eq(modFb, nil)
		expect(string.find(tostring(errFb), "invalid feedback slot type", 1, true) ~= nil, tostring(errFb))
	end)

	test(
		"disassembles CRLF source remarks, in-memory ProtoModules with class/table_with_constants/closures, and v1/v3 typeinfo",
		function()
			local Ouro = require("../")
			local Compiler = require("../src/Compiler")

			-- 1. CRLF source with compiler remarks via builder:dumpSourceRemarks and Ouro.Bytecode.disassemble
			local crlfSrc = table.concat({
				"local function add1(n: number): number",
				"\treturn n + 1",
				"end",
				"local s = 0",
				"for i = 1, 3 do",
				"\ts += add1(i)",
				"end",
				"return s",
			}, "\r\n") .. "\r\n"

			local flagsRemarks = bit32.bor(
				BytecodeBuilder.DumpFlags.Code,
				BytecodeBuilder.DumpFlags.Lines,
				BytecodeBuilder.DumpFlags.Source,
				BytecodeBuilder.DumpFlags.Locals,
				BytecodeBuilder.DumpFlags.Remarks,
				BytecodeBuilder.DumpFlags.Types,
				BytecodeBuilder.DumpFlags.Constants
			)
			local crlfRes = Compiler.compileResult(crlfSrc, {
				optimizationLevel = 2,
				debugLevel = 2,
				typeInfoLevel = 1,
				dumpFlags = flagsRemarks,
			})
			sert.eq(crlfRes.status, "ok")
			local crlfBcb = assert(crlfRes.builder)
			local remOut = crlfBcb:dumpSourceRemarks()
			expect(string.find(remOut, "-- remark:", 1, true) ~= nil, "builder interleaves -- remark lines")
			expect(string.find(remOut, "\r", 1, true) == nil, "splitDumpSourceLines strips CR")
			local fullDump = crlfBcb:dumpEverything()
			expect(string.find(fullDump, "remark:", 1, true) ~= nil, "dumpEverything includes remarks")

			-- 2. Direct ProtoModule disassembly with table, table_with_constants, closure constants, control strings, and v3 typed upvals/locals
			local richModSrc = [[
local ext = 10
local function outer(x: number, ...: string)
	local ctrl = "\1\2\n\t12345678901234567890123456789012"
	local emptyT = {}
	local folded = { a = 10, b = "hi" }
	local function inner(y: number): number
		return ext + x + y
	end
	return inner(folded.a), emptyT, ctrl
end
return outer
]]
			local richMod, richErr = Compiler.compileProto(richModSrc, {
				optimizationLevel = 2,
				debugLevel = 2,
				typeInfoLevel = 1,
				flags = { LuauCompileTableFoldFix = true },
			})
			assert(richMod ~= nil, richErr)
			local modDump = Ouro.Bytecode.disassemble(richMod, flagsRemarks, crlfSrc)
			expect(
				string.find(modDump, "table_with_constants", 1, true) ~= nil
					or string.find(modDump, "K", 1, true) ~= nil,
				modDump
			)
			expect(string.find(modDump, "Function ", 1, true) ~= nil, modDump)
			expect(
				string.find(modDump, "locvars", 1, true) ~= nil or string.find(modDump, "local ", 1, true) ~= nil,
				modDump
			)
			expect(string.find(modDump, "\\x01\\x02", 1, true) ~= nil, modDump)

			-- 3. In-memory v100 class ProtoModule disassembly via compileResult.builder:toProtoModule()
			local clsRes = Compiler.compileResult(
				[[
class Box
	public val: number
	function initVal(self, v: number)
		self.val = v
	end
end
return Box
]],
				{
					parseOptions = { profile = "experimental" },
					optimizationLevel = 1,
					debugLevel = 2,
					typeInfoLevel = 1,
				}
			)
			sert.eq(clsRes.status, "ok")
			local clsModDump = Ouro.Bytecode.disassemble(assert(clsRes.builder):toProtoModule(), flagsRemarks)
			expect(string.find(clsModDump, "NEWCLASS", 1, true) ~= nil, clsModDump)
			expect(string.find(clsModDump, "Box", 1, true) ~= nil, clsModDump)

			-- 4. Raw v14 + typesversion == 1 ProtoModule disassembly exercises v1 typeinfo path
			local v1Mod: any = {
				version = 14,
				typesversion = 1,
				mainid = 0,
				strings = { "arg" },
				userdataTypes = {},
				protos = {
					{
						id = 0,
						maxstacksize = 1,
						numparams = 1,
						nups = 0,
						isvararg = false,
						flags = 0,
						linedefined = 1,
						debugname = "v1fn",
						code = { Opcodes.LOP_RETURN + 0x00010000 },
						kTypes = {},
						kValues = {},
						p = {},
						typeinfo = string.char(
							BytecodeDefs.Types.LBC_TYPE_FUNCTION,
							1,
							BytecodeDefs.Types.LBC_TYPE_NUMBER
						),
						locvars = { { varname = "arg", reg = 0, startpc = 0, endpc = 1 } },
						upvalues = {},
					},
				},
			}
			local v1Dump = Ouro.Bytecode.disassemble(v1Mod, flagsRemarks)
			expect(string.find(v1Dump, "(number)", 1, true) ~= nil, v1Dump)

			-- 5. Unsorted >24 jump sources exercise heapsort in sortJumps alongside long-jump expansion and writer buffer growth
			local bcbHeap = BytecodeBuilder.new()
			local fHeap = bcbHeap:beginFunction(0, false)
			local jumpLabels: { number } = {}
			for i = 1, 30 do
				jumpLabels[i] = bcbHeap:emitLabel()
				bcbHeap:emitAD(Opcodes.LOP_JUMP, 0, 0)
			end
			for _ = 1, 32775 do
				bcbHeap:emitABC(Opcodes.LOP_NOP, 0, 0, 0)
			end
			local endHeap = bcbHeap:emitLabel()
			bcbHeap:emitABC(Opcodes.LOP_RETURN, 0, 1, 0)
			-- Patch in reverse order so sortJumps receives unsorted sources (>24) and triggers siftDown heapsort
			for i = 30, 1, -1 do
				sert.eq(bcbHeap:patchJumpD(jumpLabels[i], endHeap), true)
			end
			sert.eq(bcbHeap:expandJumps(), false)
			-- Also grow writer buffer via >120 constant tables/shapes
			for i = 1, 120 do
				local ks = bcbHeap:addConstantString("k_" .. tostring(i))
				local sh = BytecodeBuilder.newTableShape()
				sh.keys[1] = ks
				sh.length = 1
				bcbHeap:addConstantTable(sh)
			end
			bcbHeap:endFunction(2, 0, 0)
			bcbHeap:setMainFunction(fHeap)
			bcbHeap:finalize()
			local heapMod = assert(BytecodeCodec.deserialize(bcbHeap:getBytecode()))
			expect(#heapMod.protos[1].code > 32800, "expanded long jumps")

			-- 6. Disassemble raw ProtoModule exercising nil, boolean, vector, vectord, plain table, and 3-part import constants
			local iid3 = BytecodeBuilder.getImportId(0, 1, 2)
			local Tags = BytecodeDefs.Tags
			local richConstMod: any = {
				version = 14,
				typesversion = 3,
				mainid = 0,
				strings = { "a", "b", "c" },
				userdataTypes = {},
				protos = {
					{
						id = 0,
						maxstacksize = 4,
						numparams = 0,
						nups = 0,
						isvararg = false,
						flags = 0,
						linedefined = 1,
						code = { Opcodes.LOP_RETURN + 0x00010000 },
						kTypes = {
							Tags.LBC_CONSTANT_STRING,
							Tags.LBC_CONSTANT_STRING,
							Tags.LBC_CONSTANT_STRING,
							Tags.LBC_CONSTANT_NIL,
							Tags.LBC_CONSTANT_BOOLEAN,
							Tags.LBC_CONSTANT_VECTOR,
							Tags.LBC_CONSTANT_VECTORD,
							Tags.LBC_CONSTANT_TABLE,
							Tags.LBC_CONSTANT_IMPORT,
						},
						kValues = {
							"a",
							"b",
							"c",
							nil,
							true,
							{ 1, 2, 3, 0 },
							{ 4, 5, 6, 7 },
							{ keys = { 0, 1 }, length = 2 },
							iid3,
						},
						p = {},
					},
				},
			}
			local constModDump = Ouro.Bytecode.disassemble(
				richConstMod,
				bit32.bor(
					BytecodeBuilder.DumpFlags.Code,
					BytecodeBuilder.DumpFlags.Constants,
					BytecodeBuilder.DumpFlags.Types
				)
			)
			expect(string.find(constModDump, "a.b.c", 1, true) ~= nil, constModDump)
			expect(string.find(constModDump, "1, 2, 3", 1, true) ~= nil, constModDump)
			expect(string.find(constModDump, "4, 5, 6, 7", 1, true) ~= nil, constModDump)
		end
	)

	test(
		"BytecodeCodec.serialize round-trips compiled and synthetic ProtoModules across versions and encoders",
		function()
			local Compiler = require("../src/Compiler")
			local Tags = BytecodeDefs.Tags

			local function protoEq(a: any, b: any)
				sert.eq(a.version, b.version)
				sert.eq(a.typesversion, b.typesversion)
				sert.eq(a.mainid, b.mainid)
				sert.eq(#a.strings, #b.strings)
				for i = 1, #a.strings do
					sert.eq(a.strings[i], b.strings[i])
				end
				sert.eq(a.userdataTypes ~= nil, b.userdataTypes ~= nil)
				if a.userdataTypes and b.userdataTypes then
					for k, v in a.userdataTypes do
						sert.eq(b.userdataTypes[k], v)
					end
					for k, v in b.userdataTypes do
						sert.eq(a.userdataTypes[k], v)
					end
				end
				sert.eq(#a.protos, #b.protos)
				for i = 1, #a.protos do
					local pa, pb = a.protos[i], b.protos[i]
					sert.eq(pa.id, pb.id)
					sert.eq(pa.maxstacksize, pb.maxstacksize)
					sert.eq(pa.numparams, pb.numparams)
					sert.eq(pa.nups, pb.nups)
					sert.eq(pa.isvararg, pb.isvararg)
					sert.eq(pa.flags, pb.flags)
					sert.eq(pa.linedefined, pb.linedefined)
					sert.eq(pa.debugname, pb.debugname)
					sert.eq(pa.lineData, pb.lineData)
					sert.eq(pa.linegaplog2, pb.linegaplog2)
					sert.eq(pa.typeinfo, pb.typeinfo)
					sert.eq(#pa.code, #pb.code)
					for j = 1, #pa.code do
						sert.eq(pa.code[j], pb.code[j])
					end
					sert.eq(#pa.p, #pb.p)
					for j = 1, #pa.p do
						sert.eq(pa.p[j], pb.p[j])
					end
					sert.eq(#pa.kTypes, #pb.kTypes)
					for j = 1, #pa.kTypes do
						sert.eq(pa.kTypes[j], pb.kTypes[j])
						local va, vb = pa.kValues[j], pb.kValues[j]
						if type(va) == "number" then
							if va ~= va then
								expect(vb ~= vb, "NaN preserved")
							elseif va == 0 then
								sert.eq(vb, 0)
								expect((1 / va) == (1 / vb), "signed zero preserved")
							else
								sert.eq(va, vb)
							end
						elseif type(va) == "table" then
							expect(type(vb) == "table", "table constant preserved")
						else
							sert.eq(va, vb)
						end
					end
					sert.eq(pa.locvars ~= nil, pb.locvars ~= nil)
					if pa.locvars and pb.locvars then
						sert.eq(#pa.locvars, #pb.locvars)
						for j = 1, #pa.locvars do
							sert.eq(pa.locvars[j].varname, pb.locvars[j].varname)
							sert.eq(pa.locvars[j].startpc, pb.locvars[j].startpc)
							sert.eq(pa.locvars[j].endpc, pb.locvars[j].endpc)
							sert.eq(pa.locvars[j].reg, pb.locvars[j].reg)
						end
					end
					sert.eq(pa.upvalues ~= nil, pb.upvalues ~= nil)
					if pa.upvalues and pb.upvalues then
						sert.eq(#pa.upvalues, #pb.upvalues)
						for j = 1, #pa.upvalues do
							sert.eq(pa.upvalues[j], pb.upvalues[j])
						end
					end
				end
			end

			-- 1. Compile rich source, round-trip compile -> deserialize -> serialize -> deserialize -> VM run
			local src = [[
			local negZero = -0.0
			local nanVal = 0 / 0
			local t = { a = 1, b = "hi" }
			local v = vector.create(1, 2, 3)
			local function makeAdder(base: number): (number) -> number
				return function(x: number): number
					return base + x
				end
			end
			local add10 = makeAdder(10)
			return add10(5) + t.a + v.x, negZero, nanVal, t.b
		]]
			for _, opt in { 0, 1, 2 } do
				local bc = assert(Compiler.compile(src, { optimizationLevel = opt, debugLevel = 2, typeInfoLevel = 1 }))
				local pm1 = assert(BytecodeCodec.deserialize(bc))
				local bc2, serErr = BytecodeCodec.serialize(pm1)
				assert(bc2 ~= nil, serErr)
				local pm2 = assert(BytecodeCodec.deserialize(bc2))
				protoEq(pm1, pm2)
				local fn = assert(VM.loadBytecode(bc2, { name = "=ser_roundtrip" }))
				local r1, r2, r3, r4 = fn()
				sert.eq(r1, 17)
				expect(r2 == 0 and 1 / r2 < 0, "-0.0 preserved through serialize")
				expect(r3 ~= r3, "NaN preserved through serialize")
				sert.eq(r4, "hi")
			end

			-- 2. Function and table BytecodeEncoder support without mutating input ProtoModule
			local rawBc = assert(Compiler.compile("local a = math.abs(-5); return a + 1", { optimizationLevel = 2 }))
			local canonMod = assert(BytecodeCodec.deserialize(rawBc))
			local firstInsnBefore = canonMod.protos[canonMod.mainid + 1].code[1]
			local encBcFn = assert(BytecodeCodec.serialize(canonMod, function(op: number): number
				return (op * 227) % 256
			end))
			local decModFn = assert(BytecodeCodec.deserialize(encBcFn, function(op: number): number
				return (op * 203) % 256
			end))
			protoEq(canonMod, decModFn)

			local encBcTbl = assert(BytecodeCodec.serialize(canonMod, {
				encode = function(_self: any, code: { number })
					for i = 1, #code do
						code[i] = bit32.bxor(code[i], 0x5a)
					end
				end,
			}))
			sert.eq(canonMod.protos[canonMod.mainid + 1].code[1], firstInsnBefore)
			local decModTbl = assert(BytecodeCodec.deserialize(encBcTbl, {
				decode = function(_self: any, code: { number })
					for i = 1, #code do
						code[i] = bit32.bxor(code[i], 0x5a)
					end
				end,
			}))
			protoEq(canonMod, decModTbl)

			-- 3. Synthetic v3, v11, and v100 (classes + sparse userdataTypes + vectord) round-trips
			local v3Mod: any = {
				version = 3,
				typesversion = 0,
				strings = { "main" },
				mainid = 0,
				protos = {
					{
						id = 0,
						maxstacksize = 2,
						numparams = 0,
						nups = 0,
						isvararg = false,
						flags = 0,
						code = { Opcodes.LOP_LOADN + 0x00010000 * 7, Opcodes.LOP_RETURN + 0x00020000 },
						kTypes = {},
						kValues = {},
						p = {},
						linedefined = 1,
						debugname = "main",
					},
				},
			}
			local v3Bc = assert(BytecodeCodec.serialize(v3Mod))
			local v3Dec = assert(BytecodeCodec.deserialize(v3Bc))
			sert.eq(v3Dec.version, 3)
			sert.eq(v3Dec.typesversion, 0)
			sert.eq(v3Dec.protos[1].debugname, "main")

			local v11Mod: any = {
				version = 11,
				typesversion = 2,
				strings = { "x" },
				mainid = 0,
				protos = {
					{
						id = 0,
						maxstacksize = 1,
						numparams = 0,
						nups = 0,
						isvararg = false,
						flags = 0,
						code = { Opcodes.LOP_RETURN + 0x00010000 },
						kTypes = { Tags.LBC_CONSTANT_STRING },
						kValues = { "extra_not_in_strings" },
						p = {},
						linedefined = 1,
					},
				},
			}
			local v11Bc = assert(BytecodeCodec.serialize(v11Mod))
			local v11Dec = assert(BytecodeCodec.deserialize(v11Bc))
			sert.eq(v11Dec.version, 11)
			sert.eq(v11Dec.protos[1].kValues[1], "extra_not_in_strings")

			local clsBc = assert(Compiler.compile(
				[[
class Point
	public x: number
	private _secret: number
	function getSecret(self, a: UsedA, b: UsedB): number
		return self._secret
	end
end
return Point
]],
				{
					parseOptions = { profile = "experimental" },
					optimizationLevel = 1,
					userdataTypes = { "UsedA", "UsedB" },
					typeInfoLevel = 1,
				}
			))
			local clsPm1 = assert(BytecodeCodec.deserialize(clsBc))
			local clsBc2 = assert(BytecodeCodec.serialize(clsPm1))
			local clsPm2 = assert(BytecodeCodec.deserialize(clsBc2))
			protoEq(clsPm1, clsPm2)

			-- 4. Validation errors return (nil, err)
			local badCases: { { name: string, mod: any, enc: any?, match: string } } = {
				{ name = "non-table", mod = "bad", match = "ProtoModule" },
				{
					name = "bad version",
					mod = { version = 99, typesversion = 3, strings = {}, protos = { {} }, mainid = 0 },
					match = "version",
				},
				{
					name = "bad typesversion",
					mod = { version = 14, typesversion = 9, strings = {}, protos = { {} }, mainid = 0 },
					match = "type version",
				},
				{
					name = "empty protos",
					mod = { version = 14, typesversion = 3, strings = {}, protos = {}, mainid = 0 },
					match = "protos",
				},
				{
					name = "mainid OOB",
					mod = {
						version = 14,
						typesversion = 3,
						strings = {},
						protos = {
							{
								maxstacksize = 1,
								numparams = 0,
								nups = 0,
								isvararg = false,
								flags = 0,
								code = {},
								kTypes = {},
								kValues = {},
								p = {},
								linedefined = 0,
							},
						},
						mainid = 1,
					},
					match = "main proto",
				},
				{
					name = "numparams > maxstacksize",
					mod = {
						version = 14,
						typesversion = 3,
						strings = {},
						mainid = 0,
						protos = {
							{
								maxstacksize = 1,
								numparams = 2,
								nups = 0,
								isvararg = false,
								flags = 0,
								code = {},
								kTypes = {},
								kValues = {},
								p = {},
								linedefined = 0,
							},
						},
					},
					match = "numparams",
				},
				{
					name = "NaN table key",
					mod = {
						version = 14,
						typesversion = 3,
						strings = {},
						mainid = 0,
						protos = {
							{
								maxstacksize = 1,
								numparams = 0,
								nups = 0,
								isvararg = false,
								flags = 0,
								code = {},
								kTypes = { Tags.LBC_CONSTANT_NUMBER, Tags.LBC_CONSTANT_TABLE },
								kValues = { 0 / 0, { keys = { 0 }, length = 1 } },
								p = {},
								linedefined = 0,
							},
						},
					},
					match = "NaN",
				},
				{
					name = "upvalue count mismatch",
					mod = {
						version = 14,
						typesversion = 3,
						strings = {},
						mainid = 0,
						protos = {
							{
								maxstacksize = 1,
								numparams = 0,
								nups = 1,
								isvararg = false,
								flags = 0,
								code = {},
								kTypes = {},
								kValues = {},
								p = {},
								linedefined = 0,
								upvalues = {},
							},
						},
					},
					match = "upvalue",
				},
			}
			for _, tc in badCases do
				local out, err = BytecodeCodec.serialize(tc.mod, tc.enc)
				sert.eq(out, nil, `must reject {tc.name}`)
				expect(
					string.find(string.lower(tostring(err)), string.lower(tc.match), 1, true) ~= nil,
					`{tc.name}: {err}`
				)
			end
			sert.throws(function()
				BytecodeCodec.serialize(canonMod, {} :: any)
			end, "invalid bytecode encoder")

			-- 5. Extended serialize validation, multi-byte varints, buffer growth, and disassembler edge cases
			local manyStrings: { string } = { string.rep("A", 16385) }
			local bigCode: { number } = {}
			local bigKTypes: { number } = {
				Tags.LBC_CONSTANT_NIL,
				Tags.LBC_CONSTANT_BOOLEAN,
				Tags.LBC_CONSTANT_NUMBER,
				Tags.LBC_CONSTANT_VECTOR,
				Tags.LBC_CONSTANT_VECTORD,
				Tags.LBC_CONSTANT_STRING,
				Tags.LBC_CONSTANT_IMPORT,
				Tags.LBC_CONSTANT_TABLE,
				Tags.LBC_CONSTANT_CLASS_SHAPE,
			}
			local bigKValues: { any } = {
				nil,
				true,
				123.5,
				{ 1, 2, 3, 4 },
				{ 1.25, 2.5, 3.75 },
				string.rep("long_constant_", 4),
				bit32.bor(bit32.lshift(1, 30), bit32.lshift(5, 20)),
				{ keys = {}, length = 0 },
				{ className = 5, propertyNames = {}, methodNames = {} },
			}
			for i = 1, 50 do
				bigKTypes[#bigKTypes + 1] = Tags.LBC_CONSTANT_VECTORD
				bigKValues[#bigKValues + 1] = { i, i + 1, i + 2 }
			end
			local tblKeys20: { number } = {}
			local tblConsts20: { number } = {}
			for i = 1, 25 do
				tblKeys20[i] = 5
				tblConsts20[i] = 2
			end
			bigKTypes[#bigKTypes + 1] = Tags.LBC_CONSTANT_TABLE
			bigKValues[#bigKValues + 1] = { keys = tblKeys20, length = #tblKeys20 }
			bigKTypes[#bigKTypes + 1] = Tags.LBC_CONSTANT_TABLE_WITH_CONSTANTS
			bigKValues[#bigKValues + 1] = { keys = tblKeys20, constants = tblConsts20, length = #tblKeys20 }
			local props10: { number } = {}
			for i = 1, 10 do
				props10[i] = 5
			end
			bigKTypes[#bigKTypes + 1] = Tags.LBC_CONSTANT_CLASS_SHAPE
			bigKValues[#bigKValues + 1] = { className = 5, propertyNames = props10, methodNames = props10 }
			bigKTypes[#bigKTypes + 1] = Tags.LBC_CONSTANT_VECTOR
			bigKValues[#bigKValues + 1] = { 1, 2, 3 }
			bigKTypes[#bigKTypes + 1] = Tags.LBC_CONSTANT_TABLE_WITH_CONSTANTS
			bigKValues[#bigKValues + 1] = { keys = {}, constants = {}, length = 0 }
			bigKTypes[#bigKTypes + 1] = Tags.LBC_CONSTANT_VECTOR
			local idxVec3 = #bigKTypes - 1
			bigKValues[#bigKTypes] = { 1, 2, 3 }
			bigKTypes[#bigKTypes + 1] = Tags.LBC_CONSTANT_VECTOR
			local idxVec0 = #bigKTypes - 1
			bigKValues[#bigKTypes] = { 0, 0, 0 }
			bigKTypes[#bigKTypes + 1] = Tags.LBC_CONSTANT_VECTORD
			local idxVecd0 = #bigKTypes - 1
			bigKValues[#bigKTypes] = { 0, 0, 0 }
			bigKTypes[#bigKTypes + 1] = Tags.LBC_CONSTANT_TABLE_WITH_CONSTANTS
			local idxTwc0 = #bigKTypes - 1
			bigKValues[#bigKTypes] = { keys = {}, constants = {}, length = 0 }
			for i = 2, 280 do
				manyStrings[i] = string.rep("s", 8) .. tostring(i)
			end
			bigCode[1] = Helpers.encodeAD(Opcodes.LOP_LOADK, 0, idxVec3)
			bigCode[2] = Helpers.encodeAD(Opcodes.LOP_LOADK, 0, idxVec0)
			bigCode[3] = Helpers.encodeAD(Opcodes.LOP_LOADK, 0, idxVecd0)
			bigCode[4] = Helpers.encodeAD(Opcodes.LOP_LOADK, 0, idxTwc0)
			bigCode[5] = Helpers.encodeAD(Opcodes.LOP_LOADK, 0, 5)
			bigCode[6] = Helpers.encodeAD(Opcodes.LOP_LOADK, 0, 7)
			bigCode[7] = Helpers.encodeAD(Opcodes.LOP_LOADK, 0, 8)
			for i = 8, 280 do
				bigCode[i] = Opcodes.LOP_NOP
			end
			bigCode[281] = Opcodes.LOP_RETURN + 0x00010000
			local bigMod: any = {
				version = Tags.LBC_VERSION_TARGET,
				typesversion = Tags.LBC_TYPE_VERSION_TARGET,
				strings = manyStrings,
				mainid = 0,
				protos = {
					{
						id = 0,
						maxstacksize = 2,
						numparams = 0,
						nups = 0,
						isvararg = false,
						flags = 0,
						typeinfo = "",
						code = bigCode,
						kTypes = bigKTypes,
						kValues = bigKValues,
						p = {},
						linedefined = 0x200000,
						debugname = "",
					},
				},
			}
			local bigBc = assert(BytecodeCodec.serialize(bigMod))
			local bigDec = assert(BytecodeCodec.deserialize(bigBc))
			sert.eq(#bigDec.strings, 281)
			sert.eq(bigDec.protos[1].linedefined, 0x200000)

			local bigDisasm = BytecodeDisassembler.disassemble(bigDec, 0xff)
			expect(string.find(bigDisasm, "long_constant_", 1, true) ~= nil, "long string constant truncated")
			expect(string.find(bigDisasm, "class", 1, true) ~= nil, "empty class shape disassembled")

			-- Table-based encoder + serialize rejection matrix for constants/proto fields
			local tableEncMod = assert(BytecodeCodec.deserialize(assert(Compiler.compile("return 1 + 2"))))
			local encTableCalls = 0
			local encTable = {
				encode = function(_self: any, code: { number })
					encTableCalls += 1
					for i = 1, #code do
						code[i] = code[i]
					end
				end,
			}
			sert.eq(type(assert(BytecodeCodec.serialize(tableEncMod, encTable))), "string")
			expect(encTableCalls >= 1, "table encoder called")

			local extraBad: { { mod: any, enc: any? } } = {
				{ mod = { version = 3, typesversion = 1, strings = {}, protos = { {} }, mainid = 0 } },
				{ mod = { version = 14, typesversion = 3, strings = { 123 }, protos = { {} }, mainid = 0 } },
				{ mod = { version = 14, typesversion = 3, strings = {}, protos = { "bad" }, mainid = 0 } },
				{
					mod = {
						version = 14,
						typesversion = 3,
						strings = {},
						userdataTypes = "bad",
						protos = { {} },
						mainid = 0,
					},
				},
				{
					mod = {
						version = 14,
						typesversion = 2,
						strings = {},
						userdataTypes = { "A" },
						protos = { {} },
						mainid = 0,
					},
				},
				{
					mod = {
						version = 14,
						typesversion = 3,
						strings = {},
						userdataTypes = { [0] = "A" },
						protos = { {} },
						mainid = 0,
					},
				},
				{
					mod = {
						version = 14,
						typesversion = 3,
						strings = {},
						userdataTypes = { [1] = "" },
						protos = { {} },
						mainid = 0,
					},
				},
				{
					mod = {
						version = 14,
						typesversion = 3,
						strings = {},
						mainid = 0,
						protos = {
							{
								maxstacksize = 1,
								numparams = 0,
								nups = 0,
								isvararg = "no",
								code = {},
								kTypes = {},
								kValues = {},
								p = {},
								linedefined = 0,
							},
						},
					},
				},
				{
					mod = {
						version = 14,
						typesversion = 3,
						strings = {},
						mainid = 0,
						protos = {
							{
								id = 1,
								maxstacksize = 1,
								numparams = 0,
								nups = 0,
								isvararg = false,
								code = {},
								kTypes = {},
								kValues = {},
								p = {},
								linedefined = 0,
							},
						},
					},
				},
				{
					mod = {
						version = 14,
						typesversion = 3,
						strings = {},
						mainid = 0,
						protos = {
							{
								maxstacksize = 1,
								numparams = 0,
								nups = 0,
								isvararg = false,
								typeinfo = 123,
								code = {},
								kTypes = {},
								kValues = {},
								p = {},
								linedefined = 0,
							},
						},
					},
				},
				{
					mod = {
						version = 14,
						typesversion = 3,
						strings = {},
						mainid = 0,
						protos = {
							{
								maxstacksize = 1,
								numparams = 0,
								nups = 0,
								isvararg = false,
								code = { 0xff },
								kTypes = {},
								kValues = {},
								p = {},
								linedefined = 0,
							},
						},
					},
					enc = function(op: number)
						return op
					end,
				},
				{
					mod = {
						version = 14,
						typesversion = 3,
						strings = {},
						mainid = 0,
						protos = {
							{
								maxstacksize = 1,
								numparams = 0,
								nups = 0,
								isvararg = false,
								code = { Opcodes.LOP_RETURN + 0x00010000 },
								kTypes = {},
								kValues = {},
								p = {},
								linedefined = 0,
							},
						},
					},
					enc = function(_op: number)
						return 1.5
					end,
				},
				{
					mod = {
						version = 14,
						typesversion = 3,
						strings = {},
						mainid = 0,
						protos = {
							{
								maxstacksize = 1,
								numparams = 0,
								nups = 0,
								isvararg = false,
								code = { Opcodes.LOP_LOADKX },
								kTypes = {},
								kValues = {},
								p = {},
								linedefined = 0,
							},
						},
					},
					enc = function(op: number)
						return op
					end,
				},
				{
					mod = {
						version = 14,
						typesversion = 3,
						strings = {},
						mainid = 0,
						protos = {
							{
								maxstacksize = 1,
								numparams = 0,
								nups = 0,
								isvararg = false,
								code = {},
								kTypes = { Tags.LBC_CONSTANT_BOOLEAN },
								kValues = { 1 },
								p = {},
								linedefined = 0,
							},
						},
					},
				},
				{
					mod = {
						version = 14,
						typesversion = 3,
						strings = {},
						mainid = 0,
						protos = {
							{
								maxstacksize = 1,
								numparams = 0,
								nups = 0,
								isvararg = false,
								code = {},
								kTypes = { Tags.LBC_CONSTANT_NUMBER },
								kValues = { "x" },
								p = {},
								linedefined = 0,
							},
						},
					},
				},
				{
					mod = {
						version = 14,
						typesversion = 3,
						strings = {},
						mainid = 0,
						protos = {
							{
								maxstacksize = 1,
								numparams = 0,
								nups = 0,
								isvararg = false,
								code = {},
								kTypes = { Tags.LBC_CONSTANT_VECTOR },
								kValues = { { "x", 0, 0 } },
								p = {},
								linedefined = 0,
							},
						},
					},
				},
				{
					mod = {
						version = 14,
						typesversion = 3,
						strings = {},
						mainid = 0,
						protos = {
							{
								maxstacksize = 1,
								numparams = 0,
								nups = 0,
								isvararg = false,
								code = {},
								kTypes = { Tags.LBC_CONSTANT_VECTORD },
								kValues = { "bad" },
								p = {},
								linedefined = 0,
							},
						},
					},
				},
				{
					mod = {
						version = 14,
						typesversion = 3,
						strings = {},
						mainid = 0,
						protos = {
							{
								maxstacksize = 1,
								numparams = 0,
								nups = 0,
								isvararg = false,
								code = {},
								kTypes = { Tags.LBC_CONSTANT_STRING },
								kValues = { 123 },
								p = {},
								linedefined = 0,
							},
						},
					},
				},
				{
					mod = {
						version = 14,
						typesversion = 3,
						strings = {},
						mainid = 0,
						protos = {
							{
								maxstacksize = 1,
								numparams = 0,
								nups = 0,
								isvararg = false,
								code = {},
								kTypes = { Tags.LBC_CONSTANT_IMPORT },
								kValues = { 0 },
								p = {},
								linedefined = 0,
							},
						},
					},
				},
				{
					mod = {
						version = 14,
						typesversion = 3,
						strings = {},
						mainid = 0,
						protos = {
							{
								maxstacksize = 1,
								numparams = 0,
								nups = 0,
								isvararg = false,
								code = {},
								kTypes = { Tags.LBC_CONSTANT_TABLE_WITH_CONSTANTS },
								kValues = { { keys = { 9 }, constants = { 9 } } },
								p = {},
								linedefined = 0,
							},
						},
					},
				},
				{
					mod = {
						version = 14,
						typesversion = 3,
						strings = {},
						mainid = 0,
						protos = {
							{
								maxstacksize = 1,
								numparams = 0,
								nups = 0,
								isvararg = false,
								code = {},
								kTypes = { Tags.LBC_CONSTANT_CLASS_SHAPE },
								kValues = { "bad" },
								p = {},
								linedefined = 0,
							},
						},
					},
				},
				{
					mod = {
						version = 14,
						typesversion = 3,
						strings = {},
						mainid = 0,
						protos = {
							{
								maxstacksize = 1,
								numparams = 0,
								nups = 0,
								isvararg = false,
								code = {},
								kTypes = { 250 },
								kValues = { nil },
								p = {},
								linedefined = 0,
							},
						},
					},
				},
				{
					mod = {
						version = 14,
						typesversion = 3,
						strings = {},
						mainid = 0,
						protos = {
							{
								maxstacksize = 1,
								numparams = 0,
								nups = 0,
								isvararg = false,
								code = {},
								kTypes = {},
								kValues = {},
								p = {},
								linedefined = 0,
								lineData = "bad",
								linegaplog2 = 2,
							},
						},
					},
				},
				{
					mod = {
						version = 14,
						typesversion = 3,
						strings = {},
						mainid = 0,
						protos = {
							{
								maxstacksize = 1,
								numparams = 0,
								nups = 0,
								isvararg = false,
								code = {},
								kTypes = {},
								kValues = {},
								p = {},
								linedefined = 0,
								linegaplog2 = 2,
							},
						},
					},
				},
			}
			for idx, tc in extraBad do
				local out = BytecodeCodec.serialize(tc.mod, tc.enc)
				sert.eq(out, nil, `extraBad #{idx}`)
			end
			sert.eq(BytecodeCodec.decodeError(buffer.fromstring(bigBc)), nil)
			sert.eq(pcall(BytecodeCodec.decodeError :: any, 123), false)

			-- Deserialize malformed binary payloads (bad varints, decoder errors, lineinfo gap, import count)
			local simpleBc = assert(Compiler.compile("return 1"))
			sert.throws(function()
				BytecodeCodec.deserialize(simpleBc, {} :: any)
			end, "invalid bytecode decoder")
			sert.eq(
				select(
					1,
					BytecodeCodec.deserialize(simpleBc, function()
						return 1.5
					end)
				),
				nil
			)
			sert.eq(select(1, BytecodeCodec.deserialize("\14\3\128\128\128\128\32")), nil)
			sert.eq(select(1, BytecodeCodec.deserialize("\14\3\0\1\0\0\0\0\0\1\1\1\5\0\0\0\0\0\1\32")), nil)
			for _, ktag in
				{
					Tags.LBC_CONSTANT_BOOLEAN,
					Tags.LBC_CONSTANT_NUMBER,
					Tags.LBC_CONSTANT_VECTOR,
					Tags.LBC_CONSTANT_VECTORD,
					Tags.LBC_CONSTANT_STRING,
					Tags.LBC_CONSTANT_IMPORT,
					Tags.LBC_CONSTANT_TABLE,
					Tags.LBC_CONSTANT_TABLE_WITH_CONSTANTS,
					Tags.LBC_CONSTANT_CLASS_SHAPE,
				}
			do
				sert.eq(select(1, BytecodeCodec.deserialize("\14\3\0\0\1\9\5\0\0\0\0\0\0\1" .. string.char(ktag))), nil)
			end
			local emptyDisasm = BytecodeDisassembler.disassemble({
				version = 14,
				typesversion = 3,
				strings = {},
				mainid = 0,
				protos = {
					{
						id = 0,
						maxstacksize = 1,
						numparams = 0,
						nups = 0,
						isvararg = false,
						flags = 0,
						code = {
							Helpers.encodeAD(Opcodes.LOP_LOADK, 0, 0),
							Helpers.encodeAD(Opcodes.LOP_LOADK, 0, 1),
							Helpers.encodeAD(Opcodes.LOP_LOADK, 0, 2),
							Helpers.encodeAD(Opcodes.LOP_LOADK, 0, 3),
							Opcodes.LOP_RETURN + 0x00010000,
						},
						kTypes = {
							Tags.LBC_CONSTANT_VECTOR,
							Tags.LBC_CONSTANT_VECTORD,
							Tags.LBC_CONSTANT_TABLE,
							Tags.LBC_CONSTANT_CLASS_SHAPE,
						},
						kValues = {
							{},
							{},
							{ keys = {} },
							{ propertyNames = {}, methodNames = {} },
						},
						p = {},
						linedefined = 0,
					},
				},
			}, 0xff)
			expect(string.find(emptyDisasm, "0, 0, 0", 1, true) ~= nil, "empty vector disassembled")
			expect(string.find(emptyDisasm, "{}", 1, true) ~= nil, "empty table disassembled")

			-- 6. Strict argument validation on encodeError, decodeLineInfo, disassemble, and deserialize decoder
			local bcbValid = BytecodeBuilder.new()
			bcbValid:beginFunction(0, false)
			bcbValid:emitABC(Opcodes.LOP_RETURN, 0, 1, 0)
			bcbValid:endFunction(1, 0)
			bcbValid:setMainFunction(0)
			bcbValid:finalize()
			local validBcStr = bcbValid:getBytecode()

			sert.throws(function()
				BytecodeCodec.encodeError(123 :: any)
			end)
			sert.throws(function()
				BytecodeCodec.decodeLineInfo("bad" :: any)
			end)
			sert.throws(function()
				BytecodeCodec.deserialize(validBcStr, "bad_decoder" :: any)
			end)
			sert.throws(function()
				BytecodeDisassembler.disassemble(123 :: any)
			end)
			sert.throws(function()
				BytecodeDisassembler.disassemble("corrupt_bytecode")
			end)
			sert.throws(function()
				BytecodeDisassembler.disassemble(validBcStr, "bad_flags" :: any)
			end)
			sert.throws(function()
				BytecodeDisassembler.disassemble(validBcStr, 1, 123 :: any)
			end)
			sert.throws(function()
				BytecodeDisassembler.disassemble(validBcStr, 1, nil, "bad_decoder" :: any)
			end)

			local serializeBadCases: { any } = {
				{
					version = 14,
					typesversion = 3,
					strings = {},
					mainid = 0,
					protos = {
						{
							id = 0,
							maxstacksize = 1,
							numparams = 0,
							nups = 0,
							isvararg = false,
							flags = 0,
							code = {},
							kTypes = { BytecodeDefs.Tags.LBC_CONSTANT_VECTOR },
							kValues = { 123 },
							p = {},
							linedefined = 0,
						},
					},
				},
				{
					version = 14,
					typesversion = 3,
					strings = {},
					mainid = 0,
					protos = {
						{
							id = 0,
							maxstacksize = 1,
							numparams = 0,
							nups = 0,
							isvararg = false,
							flags = 0,
							code = {},
							kTypes = { BytecodeDefs.Tags.LBC_CONSTANT_VECTORD },
							kValues = { { 1, 2, "bad" } },
							p = {},
							linedefined = 0,
						},
					},
				},
				{
					version = 14,
					typesversion = 3,
					strings = {},
					mainid = 0,
					protos = {
						{
							id = 0,
							maxstacksize = 1,
							numparams = 0,
							nups = 0,
							isvararg = false,
							flags = 0,
							code = {},
							kTypes = { BytecodeDefs.Tags.LBC_CONSTANT_STRING, BytecodeDefs.Tags.LBC_CONSTANT_IMPORT },
							kValues = {
								"math",
								BytecodeCodec.decomposeImportId and BytecodeBuilder.getImportId(0, 0, 99) or 0,
							},
							p = {},
							linedefined = 0,
						},
					},
				},
				{
					version = 14,
					typesversion = 3,
					strings = {},
					mainid = 0,
					protos = {
						{
							id = 0,
							maxstacksize = 1,
							numparams = 0,
							nups = 0,
							isvararg = false,
							flags = 0,
							code = {},
							kTypes = { BytecodeDefs.Tags.LBC_CONSTANT_TABLE },
							kValues = { { bad = true } },
							p = {},
							linedefined = 0,
						},
					},
				},
			}
			for _, badSerMod in serializeBadCases do
				local serRes = BytecodeCodec.serialize(badSerMod)
				sert.eq(serRes, nil)
			end
		end
	)
end)

if not sert._bundled then
	return sert.run(sert.parseCliArgs(...))
end
return nil
