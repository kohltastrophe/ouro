--!strict
-- Seeded and property-based malformed-source and bytecode verifier safety checks. Every generated input is checked, never skipped.
local Ast = require("../src/Ast")
local BytecodeBuilder = require("../src/BytecodeBuilder")
local BytecodeCodec = require("../src/BytecodeCodec")
local BytecodeDefs = require("../src/BytecodeDefs")
local Compiler = require("../src/Compiler")
local Helpers = require("./Helpers")
local Lexer = require("../src/Lexer")
local Parser = require("../src/Parser")
local T = require("../src/Token")
local Types = require("../src/Types")
local VM = require("../src/VM")
local sert = require("@sert") :: any

local describe = sert.describe
local test = sert.test
local prop = sert.prop
local gen = sert.gen
local expect = sert
local Tags = BytecodeDefs.Tags

local vocabulary = {
	"local",
	"const",
	"function",
	"end",
	"if",
	"then",
	"else",
	"elseif",
	"while",
	"do",
	"repeat",
	"until",
	"for",
	"in",
	"return",
	"break",
	"continue",
	"type",
	"export",
	"declare",
	"class",
	"typeof",
	"read",
	"write",
	"x",
	"a",
	"number",
	"string",
	"T",
	"1",
	"0b",
	"0xgg",
	"(",
	")",
	"[",
	"]",
	"{",
	"}",
	",",
	";",
	":",
	"::",
	"=",
	"==",
	"...",
	"->",
	"+",
	"|",
	"&",
	"?",
	"<",
	">",
	"@",
	"@[native]",
	"`a{x}b`",
	"`{{",
	"'broken",
	"'\\256'",
	"--[[",
	"--!strict\n",
	"\0",
	"\xff",
	"\n",
}

local profiles = { "upstream", "studio", "experimental" }
local entrypoints: { { name: string, fn: (string, Parser.ParseOptions?) -> Parser.ParseResult } } = {
	{ name = "chunk", fn = Parser.parse },
	{ name = "expression", fn = Parser.parseExpression },
	{ name = "type", fn = Parser.parseType },
}

local function assertResultInvariants(result: Parser.ParseResult, source: string, verifyTreeWalk: boolean)
	expect(
		result.status == "ok" or result.status == "syntaxError" or result.status == "limit",
		`unexpected status {result.status}`
	)
	sert.eq(result:reconstruct(), source, "lossless reconstruction matches source")
	for _, diagnostic in result.diagnostics do
		expect(
			diagnostic.start >= 0 and diagnostic.finish >= diagnostic.start and diagnostic.finish <= #source,
			`diagnostic span [{diagnostic.start}, {diagnostic.finish}] within [0, {#source}]`
		)
	end
	if result.root ~= 0 then
		local tbl = assert(Ast.toTables(result))
		sert.eq(tbl.type, result:kindName(result.root), "Ast.toTables root type matches kindName")
		if verifyTreeWalk then
			local visited: { [number]: boolean } = {}
			local function walk(id: number)
				if id == 0 then
					return
				end
				expect(not visited[id], `AST node {id} visited once (strictly a tree)`)
				visited[id] = true
				expect(result:kind(id) > 0, `node {id} has positive numeric kind`)
				expect(result:kindName(id) ~= "", `node {id} has non-empty kindName`)
				local a, b = result:range(id)
				expect(a >= 0 and b >= a and b <= #source, `node {id} range [{a}, {b}] within [0, {#source}]`)
				local count = result:childCount(id)
				sert.eq(result:childAt(id, count + 1), 0, "childAt past childCount returns 0")
				for i = 1, count do
					local childId = result:childAt(id, i)
					expect(childId > 0, `child #{i} of node {id} is positive`)
					walk(childId)
				end
			end
			walk(result.root)
		end
	end
end

describe("Safety", function()
	test("3,000 seeded malformed-source fuzz cases terminate and preserve lossless invariants", function()
		local randomState = 742
		local function nextRandom(n: number): number
			randomState = (randomState * 48271) % 2147483647
			return randomState % n + 1
		end
		local samples = 1000
		for _ = 1, samples do
			local count = nextRandom(50)
			local parts = table.create(count)
			for i = 1, count do
				parts[i] = vocabulary[nextRandom(#vocabulary)]
			end
			local source = table.concat(parts, " ")
			local profile = profiles[nextRandom(#profiles)]
			for _, entry in entrypoints do
				local result = entry.fn(
					source,
					{ profile = profile :: any, lossless = true, recursionLimit = 64, errorLimit = 12 }
				)
				assertResultInvariants(result, source, false)
			end
		end
	end)

	prop("shrinkable malformed token soup preserves AST tree and lossless invariants", function(g)
		local parts = g:list(function(step)
			return step:pick(vocabulary)
		end, 1, 35)
		local sep = g:pick({ " ", "\n", "", "\t" })
		local profile = g:pick(profiles)
		local source = table.concat(parts, sep)
		g:note(function()
			return `profile={profile} source={string.format("%q", source)}`
		end)

		for _, entry in entrypoints do
			local result = entry.fn(source, {
				profile = profile :: any,
				allowDeclarationSyntax = profile == "experimental",
				lossless = true,
				recursionLimit = 64,
				errorLimit = 12,
			})
			assertResultInvariants(result, source, true)
		end
	end, { runs = 300 })

	prop("shrinkable raw byte, escape, comment, and interpolation soup never crashes", function(g)
		local fragments = {
			"`a{",
			"}b`",
			"`{{",
			"}}`",
			"[=[",
			"]=]",
			"--[==[",
			"]==]",
			"--!strict\r\n",
			"'\\z \r\n",
			"'\\u{1f600}",
			"'\\u{110000}'",
			"'\\x41\\256'",
			"0x1_000_ffff_ffff_ffffi",
			"0b1010_i",
			"\0",
			"\r",
			"\n",
			"\xff\xc0",
			"local x: (number, ...string) -> (boolean, ...number) = ",
			"declare extern type T extends Base with [string]: number function f(self): nil end",
			"class C extends B public x: number function m(self) return 1 end end",
		}
		local list = g:list(function(step)
			return step:pick(fragments)
		end, 1, 20)
		local source = table.concat(list, "")
		local profile = g:pick(profiles)
		g:note(function()
			return `profile={profile} source={string.format("%q", source)}`
		end)

		for _, entry in entrypoints do
			local result = entry.fn(source, {
				profile = profile :: any,
				allowDeclarationSyntax = profile == "experimental",
				lossless = true,
				recursionLimit = 48,
				errorLimit = 10,
			})
			assertResultInvariants(result, source, true)
		end
	end, { runs = 200 })

	prop(
		"adversarial malformedString, boundaryInt, and boundaryFloat inputs never crash lexer, parser, or compiler",
		function(g: any)
			local malformedParts: { string } = g:draw(gen.list(gen.malformedString(), 1, 6))
			local bInt: number = g:draw(gen.boundaryInt())
			local bFloat: number = g:draw(gen.boundaryFloat())
			local profile: string = g:draw(gen.pick(profiles))
			local numSnippet = `local a = {tostring(bInt)}; local b = {tostring(bFloat)};`
			local rawMalformed = table.concat(malformedParts, "\n")
			for _, source in { rawMalformed, numSnippet .. "\n" .. rawMalformed, `return "{rawMalformed}"` } do
				local lex = Lexer.new(source, { lossless = true, skipComments = false, profile = profile :: any })
				local steps = 0
				while lex:next() ~= T.Eof do
					steps += 1
					expect(steps <= #source + 4, "lexer always progresses toward EOF")
				end

				for _, entry in entrypoints do
					local result = entry.fn(source, {
						profile = profile :: any,
						allowDeclarationSyntax = profile == "experimental",
						lossless = true,
						recursionLimit = 32,
						errorLimit = 8,
					})
					assertResultInvariants(result, source, true)
				end

				local comp = Compiler.compileResult(source, {
					optimizationLevel = 2,
					parseOptions = {
						profile = profile :: any,
						allowDeclarationSyntax = profile == "experimental",
						recursionLimit = 32,
						errorLimit = 8,
					},
				})
				expect(
					comp.status == "ok" or comp.status == "parseError" or comp.status == "compileError",
					`unexpected compileResult status {comp.status}`
				)
				if comp.status ~= "ok" then
					sert.eq(string.byte(comp.bytecode, 1), 0)
					expect(type(comp.error) == "string" and #comp.error > 0, "structured error message present")
					expect(#comp.diagnostics > 0, "structured diagnostics present")
				end
			end
		end,
		{ runs = 150 }
	)

	prop(
		"bytecode deserializer and VM loader safely reject malformedString and truncated/corrupted bytecode buffers",
		function(g: any)
			local raw: string = g:draw(gen.malformedString())
			local headerByte: number = g:draw(gen.boundaryInt(0, 255))
			local secondByte: number = g:draw(gen.boundaryInt(0, 255))
			-- Direct malformed string into VM.loadBytecode and BytecodeCodec.deserialize
			local fnRaw, errRaw = VM.loadBytecode(raw, { name = "=fuzz", instructionLimit = 500 })
			if fnRaw == nil then
				expect(type(errRaw) == "string", "VM.loadBytecode returns error string on failure")
			else
				local okRun, errRun = pcall(fnRaw)
				if not okRun then
					expect(type(errRun) == "string", "fuzzed raw bytecode runtime error is string")
				end
			end

			-- Construct bounded header-corrupted buffer (keeping varint counts small so invalid headers/tags fail fast)
			local headerCorrupted = string.char(headerByte % 256, secondByte % 256, 1, 2, 65, 66, 1, 0, 0, 0, 0, 0)
			local deserMod, deserErr = BytecodeCodec.deserialize(headerCorrupted)
			if not deserMod then
				expect(
					type(deserErr) == "string" and #(deserErr :: string) > 0,
					"deserialize error is non-empty string"
				)
			end
			local fnHdr, errHdr = VM.loadBytecode(headerCorrupted, { name = "=hdr", instructionLimit = 500 })
			if fnHdr == nil then
				expect(type(errHdr) == "string" and #errHdr > 0, "VM.loadBytecode returns structured error string")
			else
				local okRun, errRun = pcall(fnHdr)
				if not okRun then
					expect(type(errRun) == "string", "fuzzed header bytecode runtime error is string")
				end
			end
		end,
		{ runs = 150 }
	)

	test("bytecode verifier/deserializer rejects every truncated prefix and corrupted constant tag cleanly", function()
		local validBc = assert(Compiler.compile(
			[[
			local function add(a: number, b: number): number
				local s = "hello"
				return a + b + #s
			end
			return add(10, 32)
		]],
			{ optimizationLevel = 2, debugLevel = 2, typeInfoLevel = 1 }
		))
		expect(string.byte(validBc, 1) ~= 0, "valid baseline bytecode")

		-- Empty bytecode
		local modEmpty, errEmpty = BytecodeCodec.deserialize("")
		sert.eq(modEmpty, nil)
		expect(string.find(tostring(errEmpty), "empty bytecode", 1, true) ~= nil, "empty bytecode error")
		local fnEmpty, vmErrEmpty = VM.loadBytecode("")
		sert.eq(fnEmpty, nil)
		sert.eq(vmErrEmpty, "empty bytecode")

		-- Error-status bytecode (first byte 0)
		local errBc = BytecodeCodec.encodeError(":1: syntax error")
		sert.eq(BytecodeCodec.decodeError(errBc), ":1: syntax error")
		local modErrBc, msgErrBc = BytecodeCodec.deserialize(errBc)
		sert.eq(modErrBc, nil)
		sert.eq(msgErrBc, ":1: syntax error")
		local fnErrBc, vmMsgErrBc = VM.loadBytecode(errBc)
		sert.eq(fnErrBc, nil)
		sert.eq(vmMsgErrBc, ":1: syntax error")

		-- Version and typeversion mismatches
		for _, badVer in { 1, 2, 15, 99, 255 } do
			local bad = string.char(badVer, Tags.LBC_TYPE_VERSION_TARGET) .. string.sub(validBc, 3)
			local modV, errV = BytecodeCodec.deserialize(bad)
			sert.eq(modV, nil)
			expect(string.find(tostring(errV), "bytecode version mismatch", 1, true) ~= nil, "version mismatch")
		end
		for _, badTypeVer in { 0, 4, 99, 255 } do
			local bad = string.char(Tags.LBC_VERSION_TARGET, badTypeVer) .. string.sub(validBc, 3)
			local modTV, errTV = BytecodeCodec.deserialize(bad)
			sert.eq(modTV, nil)
			expect(
				string.find(tostring(errTV), "bytecode type version mismatch", 1, true) ~= nil,
				"type version mismatch"
			)
		end

		-- Every truncated prefix from 1 to #validBc - 1 must fail cleanly without hanging
		for cut = 1, #validBc - 1 do
			local prefix = string.sub(validBc, 1, cut)
			local modPrefix, errPrefix = BytecodeCodec.deserialize(prefix)
			sert.eq(modPrefix, nil, `truncated prefix of length {cut}/{#validBc} must fail`)
			expect(type(errPrefix) == "string" and #(errPrefix :: string) > 0, "truncated prefix reports error message")
		end

		-- Invalid constant tag in proto constant table
		local craftedInvalidConst = buffer.fromstring(string.char(
			Tags.LBC_VERSION_MIN, -- version 3 (no typesversion, no protoSize)
			0, -- 0 strings
			1, -- 1 proto
			2, -- maxstacksize
			0, -- numparams
			0, -- nups
			0, -- is_vararg
			0, -- sizecode = 0
			1, -- sizek = 1
			250 -- invalid constant tag 250
		))
		local modConst, errConst = BytecodeCodec.deserialize(craftedInvalidConst)
		sert.eq(modConst, nil)
		expect(string.find(tostring(errConst), "Unexpected constant kind: 250", 1, true) ~= nil, "bad constant kind")

		-- Invalid mainid in ProtoModule
		local mod = table.clone(assert(BytecodeCodec.deserialize(validBc)))
		mod.mainid = 999
		local fnBadMain, errBadMain = VM.loadProto(mod, { name = "=badmain" })
		sert.eq(fnBadMain, nil)
		sert.eq(errBadMain, "invalid main proto id")
	end)

	test(
		"static proto verifier rejects out-of-bounds registers, constants, upvalues, child protos, and jumps",
		function()
			local Opcodes = BytecodeDefs.Opcodes
			local encodeABC = Helpers.encodeABC
			local encodeAD = Helpers.encodeAD
			local encodeE = Helpers.encodeE

			local function makeBaseModule(
				code: { number },
				kTypes: { number }?,
				kValues: { any }?,
				maxstack: number?,
				nups: number?,
				p: { number }?,
				extraProtos: { any }?
			): any
				local protos: { any } = {
					{
						id = 0,
						bytecodeid = 0,
						maxstacksize = maxstack or 2,
						numparams = 0,
						nups = nups or 0,
						isvararg = false,
						flags = 0,
						code = code,
						kTypes = kTypes or {},
						kValues = kValues or {},
						p = p or {},
					},
				}
				if extraProtos then
					for _, ep in extraProtos do
						table.insert(protos, ep)
					end
				end
				return {
					version = Tags.LBC_VERSION_TARGET,
					typesversion = Tags.LBC_TYPE_VERSION_TARGET,
					strings = { "x" },
					mainid = 0,
					protos = protos,
				}
			end

			local retInsn = encodeABC(Opcodes.LOP_RETURN, 0, 1, 0)
			local twoUpChild = {
				id = 2,
				bytecodeid = 2,
				maxstacksize = 2,
				numparams = 0,
				nups = 1,
				isvararg = false,
				flags = 0,
				code = { retInsn },
				kTypes = {},
				kValues = {},
				p = {},
			}
			local capOobMid = {
				id = 1,
				bytecodeid = 1,
				maxstacksize = 2,
				numparams = 0,
				nups = 1,
				isvararg = false,
				flags = 0,
				code = {
					encodeAD(Opcodes.LOP_NEWCLOSURE, 0, 0),
					encodeABC(Opcodes.LOP_CAPTURE, 2, 1, 0),
					retInsn,
				},
				kTypes = {},
				kValues = {},
				p = { 2 },
			}
			local badCases: { { name: string, mod: any, match: string } } = {
				-- Register out of bounds
				{
					name = "MOVE a OOB",
					mod = makeBaseModule({ encodeABC(Opcodes.LOP_MOVE, 2, 0, 0), retInsn }, nil, nil, 2),
					match = "register out of bounds",
				},
				{
					name = "MOVE b OOB",
					mod = makeBaseModule({ encodeABC(Opcodes.LOP_MOVE, 0, 5, 0), retInsn }, nil, nil, 2),
					match = "register out of bounds",
				},
				{
					name = "ADD c OOB",
					mod = makeBaseModule({ encodeABC(Opcodes.LOP_ADD, 0, 0, 3), retInsn }, nil, nil, 2),
					match = "register out of bounds",
				},
				{
					name = "CONCAT b > c",
					mod = makeBaseModule({ encodeABC(Opcodes.LOP_CONCAT, 0, 2, 1), retInsn }, nil, nil, 4),
					match = "register out of bounds",
				},
				{
					name = "CALL args OOB",
					mod = makeBaseModule({ encodeABC(Opcodes.LOP_CALL, 1, 3, 1), retInsn }, nil, nil, 2),
					match = "call register out of bounds",
				},
				{
					name = "CALL rets OOB",
					mod = makeBaseModule({ encodeABC(Opcodes.LOP_CALL, 1, 1, 3), retInsn }, nil, nil, 2),
					match = "call register out of bounds",
				},
				{
					name = "NAMECALL a+1 OOB",
					mod = makeBaseModule(
						{ encodeABC(Opcodes.LOP_NAMECALL, 1, 0, 0), 0, retInsn },
						{ Tags.LBC_CONSTANT_STRING },
						{ "m" },
						2
					),
					match = "register out of bounds",
				},
				{
					name = "JUMPIFEQ aux reg OOB",
					mod = makeBaseModule({ encodeAD(Opcodes.LOP_JUMPIFEQ, 0, 1), 9, retInsn }, nil, nil, 2),
					match = "register out of bounds",
				},
				{
					name = "FORNPREP a+2 OOB",
					mod = makeBaseModule({ encodeAD(Opcodes.LOP_FORNPREP, 1, 0), retInsn }, nil, nil, 3),
					match = "for-loop register out of bounds",
				},
				{
					name = "FORGLOOP regs OOB",
					mod = makeBaseModule({ encodeAD(Opcodes.LOP_FORGLOOP, 0, 1), 2, retInsn }, nil, nil, 4),
					match = "for-loop register out of bounds",
				},
				-- Constant index and constant kind checks
				{
					name = "LOADK OOB",
					mod = makeBaseModule({ encodeAD(Opcodes.LOP_LOADK, 0, 0), retInsn }, {}, {}, 2),
					match = "constant index out of bounds",
				},
				{
					name = "LOADKX OOB",
					mod = makeBaseModule({ encodeABC(Opcodes.LOP_LOADKX, 0, 0, 0), 3, retInsn }, {}, {}, 2),
					match = "constant index out of bounds",
				},
				{
					name = "GETTABLEKS k OOB",
					mod = makeBaseModule({ encodeABC(Opcodes.LOP_GETTABLEKS, 0, 0, 0), 1, retInsn }, {}, {}, 2),
					match = "constant index out of bounds",
				},
				{
					name = "DUPTABLE non-table k",
					mod = makeBaseModule(
						{ encodeAD(Opcodes.LOP_DUPTABLE, 0, 0), retInsn },
						{ Tags.LBC_CONSTANT_NUMBER },
						{ 1 },
						2
					),
					match = "invalid duptable constant",
				},
				{
					name = "ADDK non-number k",
					mod = makeBaseModule(
						{ encodeABC(Opcodes.LOP_ADDK, 0, 0, 0), retInsn },
						{ Tags.LBC_CONSTANT_STRING },
						{ "x" },
						2
					),
					match = "arithmetic K constant must be number",
				},
				{
					name = "JUMPXEQKN non-number k",
					mod = makeBaseModule(
						{ encodeAD(Opcodes.LOP_JUMPXEQKN, 0, 1), 0, retInsn },
						{ Tags.LBC_CONSTANT_STRING },
						{ "x" },
						2
					),
					match = "JUMPXEQKN constant must be number",
				},
				{
					name = "JUMPXEQKS non-string k",
					mod = makeBaseModule(
						{ encodeAD(Opcodes.LOP_JUMPXEQKS, 0, 1), 0, retInsn },
						{ Tags.LBC_CONSTANT_NUMBER },
						{ 1 },
						2
					),
					match = "JUMPXEQKS constant must be string",
				},
				-- Upvalue and capture checks
				{
					name = "GETUPVAL OOB",
					mod = makeBaseModule({ encodeABC(Opcodes.LOP_GETUPVAL, 0, 0, 0), retInsn }, nil, nil, 2, 0),
					match = "upvalue index out of bounds",
				},
				{
					name = "CAPTURE upval OOB",
					mod = makeBaseModule({
						encodeAD(Opcodes.LOP_NEWCLOSURE, 0, 0),
						encodeABC(Opcodes.LOP_CAPTURE, 0, 0, 0),
						retInsn,
					}, nil, nil, 2, 0, { 1 }, { capOobMid, twoUpChild }),
					match = "capture upvalue out of bounds",
				},
				{
					name = "CAPTURE reg OOB",
					mod = makeBaseModule(
						{
							encodeAD(Opcodes.LOP_NEWCLOSURE, 0, 0),
							encodeABC(Opcodes.LOP_CAPTURE, 1, 4, 0),
							retInsn,
						},
						nil,
						nil,
						2,
						0,
						{ 1 },
						{
							{
								id = 1,
								bytecodeid = 1,
								maxstacksize = 2,
								numparams = 0,
								nups = 1,
								isvararg = false,
								flags = 0,
								code = { retInsn },
								kTypes = {},
								kValues = {},
								p = {},
							},
						}
					),
					match = "capture register out of bounds",
				},
				{
					name = "CAPTURE invalid type",
					mod = makeBaseModule(
						{
							encodeAD(Opcodes.LOP_NEWCLOSURE, 0, 0),
							encodeABC(Opcodes.LOP_CAPTURE, 3, 0, 0),
							retInsn,
						},
						nil,
						nil,
						2,
						0,
						{ 1 },
						{
							{
								id = 1,
								bytecodeid = 1,
								maxstacksize = 2,
								numparams = 0,
								nups = 1,
								isvararg = false,
								flags = 0,
								code = { retInsn },
								kTypes = {},
								kValues = {},
								p = {},
							},
						}
					),
					match = "invalid capture type",
				},
				-- Child proto and closure checks
				{
					name = "NEWCLOSURE child OOB",
					mod = makeBaseModule({ encodeAD(Opcodes.LOP_NEWCLOSURE, 0, 0), retInsn }, nil, nil, 2, 0, {}),
					match = "child proto index out of bounds",
				},
				{
					name = "NEWCLOSURE missing CAPTURE",
					mod = makeBaseModule({ encodeAD(Opcodes.LOP_NEWCLOSURE, 0, 0), retInsn }, nil, nil, 2, 0, { 1 }, {
						{
							id = 1,
							bytecodeid = 1,
							maxstacksize = 2,
							numparams = 0,
							nups = 1,
							isvararg = false,
							flags = 0,
							code = { retInsn },
							kTypes = {},
							kValues = {},
							p = {},
						},
					}),
					match = "expected LOP_CAPTURE",
				},
				{
					name = "DUPCLOSURE bad k",
					mod = makeBaseModule(
						{ encodeAD(Opcodes.LOP_DUPCLOSURE, 0, 0), retInsn },
						{ Tags.LBC_CONSTANT_STRING },
						{ "nope" },
						2
					),
					match = "invalid closure constant",
				},
				-- Jump target and fastcall checks
				{
					name = "JUMP past end",
					mod = makeBaseModule({ encodeAD(Opcodes.LOP_JUMP, 0, 5), retInsn }, nil, nil, 2),
					match = "jump target out of bounds",
				},
				{
					name = "JUMPBACK before start",
					mod = makeBaseModule({ encodeAD(Opcodes.LOP_JUMPBACK, 0, -5), retInsn }, nil, nil, 2),
					match = "jump target out of bounds",
				},
				{
					name = "JUMPX past end",
					mod = makeBaseModule({ encodeE(Opcodes.LOP_JUMPX, 10), retInsn }, nil, nil, 2),
					match = "jump target out of bounds",
				},
				{
					name = "LOADB skip past end",
					mod = makeBaseModule({ encodeABC(Opcodes.LOP_LOADB, 0, 1, 5), retInsn }, nil, nil, 2),
					match = "jump target out of bounds",
				},
				{
					name = "LOADB misaligned skip",
					mod = makeBaseModule(
						{ encodeABC(Opcodes.LOP_LOADB, 0, 1, 1), encodeABC(Opcodes.LOP_LOADKX, 0, 0, 0), 0, retInsn },
						{ Tags.LBC_CONSTANT_NUMBER },
						{ 1 },
						2
					),
					match = "misaligned jump target",
				},
				{
					name = "FASTCALL1 target not CALL",
					mod = makeBaseModule({ encodeABC(Opcodes.LOP_FASTCALL1, 1, 0, 0), retInsn }, nil, nil, 2),
					match = "fastcall target is not CALL",
				},
				{
					name = "FASTCALL2 aux reg OOB",
					mod = makeBaseModule(
						{ encodeABC(Opcodes.LOP_FASTCALL2, 14, 0, 1), 9, encodeABC(Opcodes.LOP_CALL, 0, 3, 2), retInsn },
						nil,
						nil,
						4
					),
					match = "fastcall register out of bounds",
				},
				{
					name = "FASTCALL2K aux k OOB",
					mod = makeBaseModule({
						encodeABC(Opcodes.LOP_FASTCALL2K, 14, 0, 1),
						3,
						encodeABC(Opcodes.LOP_CALL, 0, 3, 2),
						retInsn,
					}, {}, {}, 4),
					match = "fastcall constant index out of bounds",
				},
				{
					name = "FASTCALL3 aux reg OOB",
					mod = makeBaseModule({
						encodeABC(Opcodes.LOP_FASTCALL3, 14, 0, 1),
						0x0500,
						encodeABC(Opcodes.LOP_CALL, 0, 4, 2),
						retInsn,
					}, nil, nil, 5),
					match = "fastcall register out of bounds",
				},
				{
					name = "Truncated two-word instruction",
					mod = makeBaseModule(
						{ encodeABC(Opcodes.LOP_LOADKX, 0, 0, 0) },
						{ Tags.LBC_CONSTANT_NUMBER },
						{ 1 },
						2
					),
					match = "truncated two-word instruction",
				},
			}

			for _, c in badCases do
				local fn, err = VM.loadProto(c.mod, { name = "=bad_proto" })
				sert.eq(fn, nil, `verifier must reject {c.name}`)
				expect(string.find(tostring(err), c.match, 1, true) ~= nil, `{c.name}: {err}`)
			end
		end
	)

	test("rejects hostile binary bytecode and malformed ProtoModule payloads cleanly", function()
		local Opcodes = BytecodeDefs.Opcodes
		local Tags = BytecodeDefs.Tags
		local function encodeABC(op: number, a: number, b: number, c: number): number
			return bit32.bor(
				bit32.band(op, 0xff),
				bit32.lshift(bit32.band(a, 0xff), 8),
				bit32.lshift(bit32.band(b, 0xff), 16),
				bit32.lshift(bit32.band(c, 0xff), 24)
			)
		end
		local function encodeAD(op: number, a: number, d: number): number
			local ud = if d < 0 then d + 0x10000 else d
			return bit32.bor(bit32.band(op, 0xff), bit32.lshift(bit32.band(a, 0xff), 8), bit32.lshift(ud, 16))
		end

		-- 1. Binary readVarInt >35 continuation bytes, giant stringCount/protoCount, v12 protoSize=0 rewind
		local hugeVarint = string.char(Tags.LBC_VERSION_TARGET, Tags.LBC_TYPE_VERSION_TARGET)
			.. string.rep("\128", 150)
			.. "\1"
		local modVi, errVi = BytecodeCodec.deserialize(hugeVarint)
		sert.eq(modVi, nil)
		expect(string.find(tostring(errVi), "invalid varint", 1, true) ~= nil, tostring(errVi))
		local fnVi, vmErrVi = VM.loadBytecode(hugeVarint, { name = "=vi" })
		sert.eq(fnVi, nil)
		expect(string.find(tostring(vmErrVi), "invalid varint", 1, true) ~= nil, tostring(vmErrVi))

		local giantStr =
			string.char(Tags.LBC_VERSION_TARGET, Tags.LBC_TYPE_VERSION_TARGET, 0xff, 0xff, 0xff, 0xff, 0x07)
		local fnGS, errGS = VM.loadBytecode(giantStr, { name = "=giant_str" })
		sert.eq(fnGS, nil)
		expect(type(errGS) == "string" and #errGS > 0, tostring(errGS))

		local protoSizeRewind = string.char(
			Tags.LBC_VERSION_TARGET,
			Tags.LBC_TYPE_VERSION_TARGET,
			0, -- 0 strings
			0, -- typesversion 3 userdata sentinel
			1, -- 1 proto
			0, -- protoSize = 0 (must fail invalid proto size)
			2,
			0,
			0,
			0,
			0,
			0,
			1,
			Opcodes.LOP_RETURN,
			0,
			1,
			0,
			0,
			0,
			0,
			0,
			0,
			0
		)
		local modRw, errRw = BytecodeCodec.deserialize(protoSizeRewind)
		sert.eq(modRw, nil)
		expect(string.find(tostring(errRw), "invalid proto size", 1, true) ~= nil, tostring(errRw))

		-- 2. Giant NEWTABLE aux preallocation is capped safely without OOM
		local bigTblMod = {
			version = Tags.LBC_VERSION_TARGET,
			typesversion = Tags.LBC_TYPE_VERSION_TARGET,
			strings = {},
			mainid = 0,
			protos = {
				{
					id = 0,
					maxstacksize = 2,
					numparams = 0,
					nups = 0,
					isvararg = false,
					flags = 0,
					code = {
						encodeABC(Opcodes.LOP_NEWTABLE, 0, 0, 0),
						0x7fffffff,
						encodeABC(Opcodes.LOP_RETURN, 0, 2, 0),
					},
					kTypes = {},
					kValues = {},
					p = {},
					linedefined = 1,
				},
			},
		}
		local bigTblFn = assert(VM.loadProto(bigTblMod :: any, { name = "=big_tbl" }))
		sert.eq(type(bigTblFn()), "table")

		-- 3. Hostile ProtoModule edge cases: mainProto.nups>0, empty code, NaN key, GETIMPORT aux=0, misaligned jumps, non-terminating end, bad id
		local retInsn = encodeABC(Opcodes.LOP_RETURN, 0, 1, 0)
		local validImpId = BytecodeBuilder.getImportId(1)
		local hostileMods: { { name: string, mod: any, match: string } } = {
			{
				name = "mainProto nups > 0",
				mod = {
					version = Tags.LBC_VERSION_TARGET,
					typesversion = Tags.LBC_TYPE_VERSION_TARGET,
					strings = {},
					mainid = 0,
					protos = {
						{
							id = 0,
							maxstacksize = 2,
							numparams = 0,
							nups = 1,
							isvararg = false,
							flags = 0,
							code = { retInsn },
							kTypes = {},
							kValues = {},
							p = {},
						},
					},
				},
				match = "main proto cannot have upvalues",
			},
			{
				name = "empty code",
				mod = {
					version = Tags.LBC_VERSION_TARGET,
					typesversion = Tags.LBC_TYPE_VERSION_TARGET,
					strings = {},
					mainid = 0,
					protos = {
						{
							id = 0,
							maxstacksize = 2,
							numparams = 0,
							nups = 0,
							isvararg = false,
							flags = 0,
							code = {},
							kTypes = {},
							kValues = {},
							p = {},
						},
					},
				},
				match = "empty proto code",
			},
			{
				name = "NaN table key",
				mod = {
					version = Tags.LBC_VERSION_TARGET,
					typesversion = Tags.LBC_TYPE_VERSION_TARGET,
					strings = {},
					mainid = 0,
					protos = {
						{
							id = 0,
							maxstacksize = 2,
							numparams = 0,
							nups = 0,
							isvararg = false,
							flags = 0,
							code = { encodeAD(Opcodes.LOP_DUPTABLE, 0, 0), retInsn },
							kTypes = { Tags.LBC_CONSTANT_TABLE, Tags.LBC_CONSTANT_NUMBER },
							kValues = {
								{ keys = { 1 }, length = 1 },
								0 / 0,
							},
							p = {},
						},
					},
				},
				match = "table constant key cannot be NaN",
			},
			{
				name = "GETIMPORT aux=0",
				mod = {
					version = Tags.LBC_VERSION_TARGET,
					typesversion = Tags.LBC_TYPE_VERSION_TARGET,
					strings = {},
					mainid = 0,
					protos = {
						{
							id = 0,
							maxstacksize = 2,
							numparams = 0,
							nups = 0,
							isvararg = false,
							flags = 0,
							code = { encodeAD(Opcodes.LOP_GETIMPORT, 0, 0), 0, retInsn },
							kTypes = { Tags.LBC_CONSTANT_IMPORT, Tags.LBC_CONSTANT_STRING },
							kValues = { validImpId, "math" },
							p = {},
						},
					},
				},
				match = "import aux constant index out of bounds",
			},
			{
				name = "misaligned jump into AUX word",
				mod = {
					version = Tags.LBC_VERSION_TARGET,
					typesversion = Tags.LBC_TYPE_VERSION_TARGET,
					strings = {},
					mainid = 0,
					protos = {
						{
							id = 0,
							maxstacksize = 2,
							numparams = 0,
							nups = 0,
							isvararg = false,
							flags = 0,
							code = {
								encodeABC(Opcodes.LOP_GETGLOBAL, 0, 0, 0),
								0, -- aux word at pc=2
								encodeAD(Opcodes.LOP_JUMP, 0, -2), -- target pc = 3 + 1 - 2 = 2
								retInsn,
							},
							kTypes = { Tags.LBC_CONSTANT_STRING },
							kValues = { "print" },
							p = {},
						},
					},
				},
				match = "misaligned jump target",
			},
			{
				name = "misaligned jump into CAPTURE slot",
				mod = {
					version = Tags.LBC_VERSION_TARGET,
					typesversion = Tags.LBC_TYPE_VERSION_TARGET,
					strings = {},
					mainid = 0,
					protos = {
						{
							id = 0,
							maxstacksize = 2,
							numparams = 0,
							nups = 0,
							isvararg = false,
							flags = 0,
							code = {
								encodeAD(Opcodes.LOP_NEWCLOSURE, 0, 0),
								encodeABC(Opcodes.LOP_CAPTURE, 0, 1, 0), -- capture slot at pc=2
								encodeAD(Opcodes.LOP_JUMP, 0, -2), -- target pc = 3 + 1 - 2 = 2
								retInsn,
							},
							kTypes = {},
							kValues = {},
							p = { 1 },
						},
						{
							id = 1,
							maxstacksize = 2,
							numparams = 0,
							nups = 1,
							isvararg = false,
							flags = 0,
							code = { retInsn },
							kTypes = {},
							kValues = {},
							p = {},
						},
					},
				},
				match = "misaligned jump target",
			},
			{
				name = "non-terminating final instruction",
				mod = {
					version = Tags.LBC_VERSION_TARGET,
					typesversion = Tags.LBC_TYPE_VERSION_TARGET,
					strings = {},
					mainid = 0,
					protos = {
						{
							id = 0,
							maxstacksize = 2,
							numparams = 0,
							nups = 0,
							isvararg = false,
							flags = 0,
							code = { encodeABC(Opcodes.LOP_NOP, 0, 0, 0) },
							kTypes = {},
							kValues = {},
							p = {},
						},
					},
				},
				match = "proto does not terminate cleanly",
			},
			{
				name = "bad proto.id",
				mod = {
					version = Tags.LBC_VERSION_TARGET,
					typesversion = Tags.LBC_TYPE_VERSION_TARGET,
					strings = {},
					mainid = 0,
					protos = {
						{
							id = 5,
							maxstacksize = 2,
							numparams = 0,
							nups = 0,
							isvararg = false,
							flags = 0,
							code = { retInsn },
							kTypes = {},
							kValues = {},
							p = {},
						},
					},
				},
				match = "malformed proto header",
			},
			{
				name = "import constant non-string piece",
				mod = {
					version = Tags.LBC_VERSION_TARGET,
					typesversion = Tags.LBC_TYPE_VERSION_TARGET,
					strings = {},
					mainid = 0,
					protos = {
						{
							id = 0,
							maxstacksize = 2,
							numparams = 0,
							nups = 0,
							isvararg = false,
							flags = 0,
							code = { retInsn },
							kTypes = { Tags.LBC_CONSTANT_IMPORT, Tags.LBC_CONSTANT_NUMBER },
							kValues = { validImpId, 1 },
							p = {},
						},
					},
				},
				match = "import constant piece must be string",
			},
			{
				name = "invalid vector constant",
				mod = {
					version = Tags.LBC_VERSION_TARGET,
					typesversion = Tags.LBC_TYPE_VERSION_TARGET,
					strings = {},
					mainid = 0,
					protos = {
						{
							id = 0,
							maxstacksize = 2,
							numparams = 0,
							nups = 0,
							isvararg = false,
							flags = 0,
							code = { retInsn },
							kTypes = { Tags.LBC_CONSTANT_VECTOR },
							kValues = { { 1, "bad", 3 } },
							p = {},
						},
					},
				},
				match = "invalid vector constant",
			},
			{
				name = "invalid string constant value",
				mod = {
					version = Tags.LBC_VERSION_TARGET,
					typesversion = Tags.LBC_TYPE_VERSION_TARGET,
					strings = {},
					mainid = 0,
					protos = {
						{
							id = 0,
							maxstacksize = 2,
							numparams = 0,
							nups = 0,
							isvararg = false,
							flags = 0,
							code = { retInsn },
							kTypes = { Tags.LBC_CONSTANT_STRING },
							kValues = { 0 / 0 },
							p = {},
						},
					},
				},
				match = "invalid string constant",
			},
			{
				name = "bad aux non-integer NEWTABLE",
				mod = {
					version = Tags.LBC_VERSION_TARGET,
					typesversion = Tags.LBC_TYPE_VERSION_TARGET,
					strings = {},
					mainid = 0,
					protos = {
						{
							id = 0,
							maxstacksize = 2,
							numparams = 0,
							nups = 0,
							isvararg = false,
							flags = 0,
							code = { encodeABC(Opcodes.LOP_NEWTABLE, 0, 0, 0), "bad", retInsn },
							kTypes = {},
							kValues = {},
							p = {},
						},
					},
				},
				match = "invalid instruction aux word",
			},
			{
				name = "bad aux float JUMPIFEQ",
				mod = {
					version = Tags.LBC_VERSION_TARGET,
					typesversion = Tags.LBC_TYPE_VERSION_TARGET,
					strings = {},
					mainid = 0,
					protos = {
						{
							id = 0,
							maxstacksize = 2,
							numparams = 0,
							nups = 0,
							isvararg = false,
							flags = 0,
							code = { encodeAD(Opcodes.LOP_JUMPIFEQ, 0, 1), 0.5, retInsn },
							kTypes = {},
							kValues = {},
							p = {},
						},
					},
				},
				match = "invalid instruction aux word",
			},
			{
				name = "stateful frozen metatable on constant table",
				mod = {
					version = Tags.LBC_VERSION_TARGET,
					typesversion = Tags.LBC_TYPE_VERSION_TARGET,
					strings = {},
					mainid = 0,
					protos = {
						{
							id = 0,
							maxstacksize = 2,
							numparams = 0,
							nups = 0,
							isvararg = false,
							flags = 0,
							code = { retInsn },
							kTypes = { Tags.LBC_CONSTANT_TABLE },
							kValues = {
								setmetatable(
									{},
									table.freeze({
										__index = function()
											return "string"
										end,
									})
								),
							},
							p = {},
						},
					},
				},
				match = "invalid table constant",
			},
		}

		for _, hCase in hostileMods do
			local hFn, hErr = VM.loadProto(hCase.mod, { name = "=hostile" })
			sert.eq(hFn, nil, `must reject {hCase.name}`)
			expect(string.find(tostring(hErr), hCase.match, 1, true) ~= nil, `{hCase.name}: {hErr}`)
		end
	end)

	test(
		"enforces coroutine escape, locked/frozen metatables, safeEnv absent-builtin blocking, and vmDebug allowlist",
		function()
			-- 1. coroutine.create(getfenv/setfenv/debug.*) escape attempts and direct host call
			local escapeFn = assert(VM.load(
				[[
				local coGet = coroutine.create(getfenv)
				local okG, errG = coroutine.resume(coGet, 0)
				local coSet = coroutine.create(setfenv)
				local okS, errS = coroutine.resume(coSet, 1, {})
				local coInfo0 = coroutine.create(debug.info)
				local okI0, errI0 = coroutine.resume(coInfo0, 0, "s")
				local coInfo1 = coroutine.create(debug.info)
				local okI1, errI1 = coroutine.resume(coInfo1, 1, "s")
				local coTb = coroutine.create(debug.traceback)
				local okT, errT = coroutine.resume(coTb, "probe")
				local dbgKeys = {}
				for k in debug do
					dbgKeys[k] = true
				end
				return okG, errG, okS, errS, okI0, errI0, okI1, errI1, okT, errT, dbgKeys,
					debug.sethook == nil, debug.getupvalue == nil, debug.getregistry == nil, getmetatable(_G)
			]],
				{ name = "=escape_checks" }
			))
			local okG, errG, okS, errS, okI0, errI0, okI1, errI1, okT, errT, dbgKeys, noHook, noUpv, noReg, guestMt =
				escapeFn()
			sert.eq(okG, false)
			expect(type(errG) == "string", tostring(errG))
			sert.eq(okS, false)
			expect(type(errS) == "string", tostring(errS))
			sert.eq(okI0, true)
			sert.eq(errI0, "[C]")
			sert.eq(okI1, true)
			sert.eq(errI1, nil)
			sert.eq(okT, true)
			expect(string.find(tostring(errT), "Dispatch", 1, true) == nil, tostring(errT))
			expect(string.find(tostring(errT), "Safety.spec", 1, true) == nil, tostring(errT))
			sert.eq(dbgKeys.traceback, true)
			sert.eq(dbgKeys.info, true)
			local keyCount = 0
			for _ in dbgKeys do
				keyCount += 1
			end
			sert.eq(keyCount, 2)
			sert.eq(noHook, true)
			sert.eq(noUpv, true)
			sert.eq(noReg, true)
			sert.eq(guestMt, "locked")

			-- Calling env.getfenv from host outside VM execution must also refuse
			local isoEnv = VM.createEnvironment()
			local okHostCall = pcall(isoEnv.getfenv, 0)
			sert.eq(okHostCall, false)

			-- 2. Locked metatables on writable envs/sandboxes; frozen table + metatable on readOnly = true
			local writableEnvs: { { [any]: any } } = {
				VM.createEnvironment(),
				VM.createEnvironment(nil, { inheritHost = true }),
				VM.createEnvironment(nil, { libraries = { "base", "math" } }),
				VM.createEnvironment(nil, { libraries = { "base", "math" }, inheritHost = true }),
				VM.sandbox(),
				VM.sandbox(VM.createEnvironment({ x = 1 }, { readOnly = true })),
			}
			for _, wEnv in writableEnvs do
				sert.eq(getmetatable(wEnv :: any), "locked")
				local gMtFn = assert(VM.load("return getmetatable(_G)", { name = "=mt_lock", env = wEnv }))
				sert.eq(gMtFn(), "locked")
			end

			local pureReadOnlyEnvs: { { env: { [any]: any }, expectedSeed: number } } = {
				{ env = VM.createEnvironment({ seed = 1 }, { readOnly = true }), expectedSeed = 1 },
				{
					env = VM.createEnvironment({ seed = 3 }, { libraries = { "base", "math" }, readOnly = true }),
					expectedSeed = 3,
				},
			}
			for _, case in pureReadOnlyEnvs do
				local roEnv = case.env
				sert.eq(table.isfrozen(roEnv), true)
				sert.eq(getmetatable(roEnv :: any), nil)
				local okWrite, errWrite = pcall(function()
					roEnv.tamper = 1
				end)
				sert.eq(okWrite, false)
				expect(string.find(string.lower(tostring(errWrite)), "readonly", 1, true) ~= nil, tostring(errWrite))
				local okReMt = pcall(setmetatable :: any, roEnv, {})
				sert.eq(okReMt, false)
				local sbOverRo = VM.sandbox(roEnv, { extra = 99 })
				local roFn = assert(VM.load("return seed, extra", { name = "=sb_ro", env = sbOverRo }))
				local sVal, eVal = roFn()
				sert.eq(sVal, case.expectedSeed)
				sert.eq(eVal, 99)
			end

			local inheritReadOnlyEnvs: { { env: { [any]: any }, expectedSeed: number } } = {
				{
					env = VM.createEnvironment({ seed = 2 }, { inheritHost = true, readOnly = true }),
					expectedSeed = 2,
				},
				{
					env = VM.createEnvironment(
						{ seed = 4 },
						{ libraries = { "base", "math" }, inheritHost = true, readOnly = true }
					),
					expectedSeed = 4,
				},
			}
			for _, case in inheritReadOnlyEnvs do
				local roEnv = case.env
				sert.eq(getmetatable(roEnv :: any), "locked")
				sert.eq(roEnv.math.abs, math.abs)
				expect(roEnv.math.random ~= math.random, "isolated math.random")
				sert.eq(table.isfrozen(roEnv.math), true)
				local okWrite, errWrite = pcall(function()
					roEnv.tamper = 1
				end)
				sert.eq(okWrite, false)
				expect(string.find(string.lower(tostring(errWrite)), "readonly", 1, true) ~= nil, tostring(errWrite))
				local okReMt = pcall(setmetatable :: any, roEnv, {})
				sert.eq(okReMt, false)
				local roGuestFn = assert(VM.load("return seed, type(math.abs)", { name = "=ro_inherit", env = roEnv }))
				local gSeed, gMathTy = roGuestFn()
				sert.eq(gSeed, case.expectedSeed)
				sert.eq(gMathTy, "function")
				local sbInheritRo = VM.sandbox(roEnv, { extra = 77 })
				local sbGuestFn = assert(VM.load("return seed, extra", { name = "=sb_ro_inherit", env = sbInheritRo }))
				local sbSeed, sbExtra = sbGuestFn()
				sert.eq(sbSeed, case.expectedSeed)
				sert.eq(sbExtra, 77)
			end

			-- Guest `_G = nil` clearing must not leak host or parent `_G`, while preserving parent immutability,
			-- blocking `rawget(_G, "getfenv")` escapes, and suppressing `loadstring` under `inheritHost = true`
			local gNilInheritEnv = VM.createEnvironment({ tag = 7 }, { inheritHost = true })
			local gNilInheritFn = assert(VM.load(
				[[
				local beforeG = _G
				_G = nil
				return beforeG ~= nil, beforeG.tag, _G
			]],
				{ name = "=gnil_inherit", env = gNilInheritEnv }
			))
			local sawBeforeG, beforeTag, afterClearG = gNilInheritFn()
			sert.eq(sawBeforeG, true)
			sert.eq(beforeTag, 7)
			sert.eq(afterClearG, nil)
			sert.eq(gNilInheritEnv._G, nil)
			sert.eq(gNilInheritEnv.tag, 7)

			local parentBase = VM.createEnvironment({ marker = "parent", nested = { v = 1 } }, { readOnly = true })
			local gNilSandbox = VM.sandbox(parentBase, { child = "ok" })
			local sbFn = assert(VM.load(
				[[
				local beforeG = _G
				local okRaw, errRaw = pcall(rawget(beforeG, "getfenv"), 2)
				_G = nil
				local sawG = _G == nil
				return sawG, okRaw, tostring(errRaw), marker, child
			]],
				{ name = "=sb_gnil", env = gNilSandbox }
			))
			local sawG, okRaw, _errRaw, pMarker, cTag = sbFn()
			sert.eq(sawG, true)
			sert.eq(okRaw, false)
			sert.eq(pMarker, "parent")
			sert.eq(cTag, "ok")
			sert.eq(gNilSandbox._G, nil)
			sert.eq(parentBase.marker, "parent")
			sert.eq(parentBase._G, parentBase)

			local inheritHostEnv = VM.createEnvironment(nil, { inheritHost = true })
			local bypassFn = assert(VM.load(
				[[
				local rawGetfenv = rawget(_G, "getfenv")
				local okLvl2, lvl2Env = pcall(_G.getfenv, 2)
				local okBypass = pcall(_G.getfenv, 3)
				local pairHasLoadstring = false
				for k, v in pairs(_G) do
					if k == "loadstring" and v ~= nil then
						pairHasLoadstring = true
					end
				end
				return okLvl2, lvl2Env == _G, okBypass, rawGetfenv == nil, _G.loadstring == nil, pairHasLoadstring
			]],
				{ name = "=host_bypass", env = inheritHostEnv }
			))
			local okLvl2, lvl2Same, okBypass, rawGfNil, noLoadstring, pairLoadstring = bypassFn()
			sert.eq(okLvl2, true)
			sert.eq(lvl2Same, true)
			sert.eq(okBypass, false)
			sert.eq(rawGfNil, true)
			sert.eq(noLoadstring, true)
			sert.eq(pairLoadstring, false)
			local directBypassFn =
				assert(VM.load("return _G.getfenv(2)", { name = "=host_bypass_direct", env = inheritHostEnv }))
			sert.eq(pcall(directBypassFn), false)

			local wrappedOverrideEnv = VM.createEnvironment({ hostGetfenv = getfenv, hostDebug = debug })
			local wrappedBypassFn = assert(VM.load(
				[[
				local rawGf = rawget(_G, "hostGetfenv")
				local okRawLvl2, rawLvl2Env = pcall(rawGf, 2)
				local okRawGf = pcall(rawGf, 3)
				local rawDbg = rawget(_G, "hostDebug")
				return okRawLvl2, rawLvl2Env == _G, okRawGf, rawDbg.getupvalue == nil, rawDbg.getregistry == nil, type(rawDbg.info)
			]],
				{ name = "=host_wrapper_rawget", env = wrappedOverrideEnv }
			))
			local okRawLvl2, rawLvl2Same, okRawGf, noDbgUpv, noDbgReg, dbgInfoTy = wrappedBypassFn()
			sert.eq(okRawLvl2, true)
			sert.eq(rawLvl2Same, true)
			sert.eq(okRawGf, false)
			sert.eq(noDbgUpv, true)
			sert.eq(noDbgReg, true)
			sert.eq(dbgInfoTy, "function")

			-- 3. safeEnv = true + getGlobal never leaks absent or blocked builtins
			local blockedGets: { string } = {}
			local baseOnlyEnv = VM.createEnvironment(nil, { libraries = { "base" } })
			local blockedFn = assert(VM.load("return math.abs(-1)", {
				name = "=blocked_safeenv",
				env = baseOnlyEnv,
				safeEnv = true,
				getGlobal = function(name: string, _env: { [any]: any }): any
					table.insert(blockedGets, name)
					return nil
				end,
			}))
			local okBlocked = pcall(blockedFn)
			sert.eq(okBlocked, false)
			sert.eq(table.find(blockedGets, "math") ~= nil, true)
		end
	)

	test(
		"enforces Ouro.load mode rules, verifier constant/header checks, template freezing, and buffer copy",
		function()
			local Ouro = require("../")
			local Opcodes = BytecodeDefs.Opcodes
			local encodeABC = Helpers.encodeABC
			local encodeAD = Helpers.encodeAD

			-- 1. Ouro.load mode defaults ("text" vs "binary" vs "auto")
			local validBc = assert(Ouro.compile("return 40 + 2", { optimizationLevel = 2 }))
			local textFailFn, textFailErr = Ouro.load(validBc)
			sert.eq(textFailFn, nil)
			expect(type(textFailErr) == "string" and #textFailErr > 0, "default mode rejects bytecode string")
			local binFn = assert(Ouro.load(validBc, { name = "=bin_mode", mode = "binary" }))
			sert.eq(binFn(), 42)
			local autoFn = assert(Ouro.load(validBc, { name = "=auto_mode", mode = "auto" }))
			sert.eq(autoFn(), 42)
			local badBinFn, badBinErr = Ouro.load("return 42", { mode = "binary" })
			sert.eq(badBinFn, nil)
			expect(type(badBinErr) == "string" and #badBinErr > 0, "binary mode rejects source text")

			-- 2. DUPTABLE freezes ProtoModule template tables and never shares runtime table mutations across calls
			local tplBc = assert(Ouro.compile("local t = { k = 10 }; t.k += 5; return t.k", { optimizationLevel = 2 }))
			local tplMod = assert(Ouro.Bytecode.deserialize(tplBc))
			local tplFn = assert(Ouro.load(tplMod, { name = "=tpl_iso" }))
			sert.eq(tplFn(), 15)
			sert.eq(tplFn(), 15)

			-- 3. Targeted verifier rejections: LOADK table constant, DUPCLOSURE+LCT_REF, nups=-1, NaN headers,
			--    non-string GETGLOBAL, LOP_NATIVECALL, standalone LOP_CAPTURE
			local retInsn = encodeABC(Opcodes.LOP_RETURN, 0, 1, 0)
			local targetedBad: { { name: string, mod: any, match: string } } = {
				{
					name = "LOADK table template",
					mod = {
						version = Tags.LBC_VERSION_TARGET,
						typesversion = Tags.LBC_TYPE_VERSION_TARGET,
						strings = { "x" },
						mainid = 0,
						protos = {
							{
								id = 0,
								maxstacksize = 2,
								numparams = 0,
								nups = 0,
								isvararg = false,
								flags = 0,
								code = { encodeAD(Opcodes.LOP_LOADK, 0, 1), retInsn },
								kTypes = { Tags.LBC_CONSTANT_STRING, Tags.LBC_CONSTANT_TABLE },
								kValues = { "x", { keys = { 0 }, length = 1 } },
								p = {},
							},
						},
					},
					match = "invalid constant type for LOADK",
				},
				{
					name = "DUPCLOSURE with LCT_REF",
					mod = {
						version = Tags.LBC_VERSION_TARGET,
						typesversion = Tags.LBC_TYPE_VERSION_TARGET,
						strings = {},
						mainid = 0,
						protos = {
							{
								id = 0,
								maxstacksize = 2,
								numparams = 0,
								nups = 0,
								isvararg = false,
								flags = 0,
								code = {
									encodeAD(Opcodes.LOP_DUPCLOSURE, 0, 0),
									encodeABC(Opcodes.LOP_CAPTURE, BytecodeDefs.Captures.LCT_REF, 1, 0),
									retInsn,
								},
								kTypes = { Tags.LBC_CONSTANT_CLOSURE },
								kValues = { 1 },
								p = {},
							},
							{
								id = 1,
								maxstacksize = 2,
								numparams = 0,
								nups = 1,
								isvararg = false,
								flags = 0,
								code = { retInsn },
								kTypes = {},
								kValues = {},
								p = {},
							},
						},
					},
					match = "DUPCLOSURE cannot capture by reference",
				},
				{
					name = "negative nups",
					mod = {
						version = Tags.LBC_VERSION_TARGET,
						typesversion = Tags.LBC_TYPE_VERSION_TARGET,
						strings = {},
						mainid = 0,
						protos = {
							{
								id = 0,
								maxstacksize = 2,
								numparams = 0,
								nups = -1,
								isvararg = false,
								flags = 0,
								code = { retInsn },
								kTypes = {},
								kValues = {},
								p = {},
							},
						},
					},
					match = "malformed proto header",
				},
				{
					name = "NaN maxstacksize header",
					mod = {
						version = Tags.LBC_VERSION_TARGET,
						typesversion = Tags.LBC_TYPE_VERSION_TARGET,
						strings = {},
						mainid = 0,
						protos = {
							{
								id = 0,
								maxstacksize = 0 / 0,
								numparams = 0,
								nups = 0,
								isvararg = false,
								flags = 0,
								code = { retInsn },
								kTypes = {},
								kValues = {},
								p = {},
							},
						},
					},
					match = "malformed proto header",
				},
				{
					name = "non-string GETGLOBAL constant",
					mod = {
						version = Tags.LBC_VERSION_TARGET,
						typesversion = Tags.LBC_TYPE_VERSION_TARGET,
						strings = {},
						mainid = 0,
						protos = {
							{
								id = 0,
								maxstacksize = 2,
								numparams = 0,
								nups = 0,
								isvararg = false,
								flags = 0,
								code = { encodeABC(Opcodes.LOP_GETGLOBAL, 0, 0, 0), 0, retInsn },
								kTypes = { Tags.LBC_CONSTANT_NUMBER },
								kValues = { 123 },
								p = {},
							},
						},
					},
					match = "global name constant must be string",
				},
				{
					name = "LOP_NATIVECALL rejected",
					mod = {
						version = Tags.LBC_VERSION_TARGET,
						typesversion = Tags.LBC_TYPE_VERSION_TARGET,
						strings = {},
						mainid = 0,
						protos = {
							{
								id = 0,
								maxstacksize = 2,
								numparams = 0,
								nups = 0,
								isvararg = false,
								flags = 0,
								code = { encodeABC(Opcodes.LOP_NATIVECALL, 0, 0, 0), retInsn },
								kTypes = {},
								kValues = {},
								p = {},
							},
						},
					},
					match = "unsupported opcode",
				},
				{
					name = "standalone LOP_CAPTURE rejected",
					mod = {
						version = Tags.LBC_VERSION_TARGET,
						typesversion = Tags.LBC_TYPE_VERSION_TARGET,
						strings = {},
						mainid = 0,
						protos = {
							{
								id = 0,
								maxstacksize = 2,
								numparams = 0,
								nups = 0,
								isvararg = false,
								flags = 0,
								code = { encodeABC(Opcodes.LOP_CAPTURE, BytecodeDefs.Captures.LCT_VAL, 0, 0), retInsn },
								kTypes = {},
								kValues = {},
								p = {},
							},
						},
					},
					match = "unexpected standalone LOP_CAPTURE",
				},
			}
			for _, tc in targetedBad do
				local fBad, eBad = VM.loadProto(tc.mod, { name = "=targeted" })
				sert.eq(fBad, nil, `must reject {tc.name}`)
				expect(string.find(tostring(eBad), tc.match, 1, true) ~= nil, `{tc.name}: {eBad}`)
			end

			-- TOCTOU: mutating child proto after VM.loadProto does not corrupt loaded closure,
			-- and re-loading detects the newly injected malicious opcode
			local mutChildBc =
				assert(Ouro.compile("local function child() return 42 end return child()", { optimizationLevel = 2 }))
			local srcMod = assert(Ouro.Bytecode.deserialize(mutChildBc))
			local clonedProtos: { any } = table.create(#srcMod.protos)
			for i, p in srcMod.protos do
				local cp = table.clone(p)
				cp.code = table.clone(p.code)
				cp.kTypes = table.clone(p.kTypes)
				cp.kValues = table.clone(p.kValues)
				cp.p = table.clone(p.p)
				clonedProtos[i] = cp
			end
			local mutMod = {
				version = srcMod.version,
				typesversion = srcMod.typesversion,
				strings = srcMod.strings,
				protos = clonedProtos,
				mainid = srcMod.mainid,
			}
			local fnToctou1 = assert(VM.loadProto(mutMod :: any, { name = "=toctou" }))
			sert.eq(fnToctou1(), 42)
			clonedProtos[1].code[1] = encodeABC(Opcodes.LOP_NATIVECALL, 0, 0, 0)
			sert.eq(fnToctou1(), 42)
			local fnToctou2, errToctou2 = VM.loadProto(mutMod :: any, { name = "=toctou2" })
			sert.eq(fnToctou2, nil)
			expect(string.find(tostring(errToctou2), "unsupported opcode", 1, true) ~= nil, tostring(errToctou2))

			-- 4. Partially frozen ProtoModule (outer table frozen, inner kValues mutable) is NOT cached across mutations
			local numBc = assert(Ouro.compile("return 123.5", { optimizationLevel = 2 }))
			local frozenSrcMod = assert(Ouro.Bytecode.deserialize(numBc))
			local partialProto = table.clone(frozenSrcMod.protos[1])
			partialProto.kTypes = table.clone(partialProto.kTypes)
			partialProto.kValues = table.clone(partialProto.kValues)
			local partialMod = table.freeze({
				version = frozenSrcMod.version,
				typesversion = frozenSrcMod.typesversion,
				strings = frozenSrcMod.strings,
				protos = { partialProto },
				mainid = 0,
			})
			local pFn1 = assert(VM.loadProto(partialMod :: any, { name = "=partial" }))
			sert.eq(pFn1(), 123.5)
			partialProto.kValues[1] = 456.5
			local pFn2 = assert(VM.loadProto(partialMod :: any, { name = "=partial" }))
			sert.eq(pFn2(), 456.5)

			-- 5. Caller buffer mutation after VM.loadBytecode(buf) must not corrupt execution or lazy line info
			local lineBc = assert(Ouro.compile("local a = 1\nlocal b = 2\nlocal c = 3\nerror('buf_boom')", {
				optimizationLevel = 2,
				debugLevel = 1,
			}))
			local callerBuf = buffer.fromstring(lineBc)
			local bufFn = assert(VM.loadBytecode(callerBuf, { name = "=buf_copy" }))
			buffer.fill(callerBuf, 0, 0xff)
			local okBufRun, errBufRun = pcall(bufFn)
			sert.eq(okBufRun, false)
			expect(string.find(tostring(errBufRun), "buf_copy:4: buf_boom", 1, true) ~= nil, tostring(errBufRun))
		end
	)

	prop("fuzzes mutated valid binary bytecode without unhandled crashes or hangs", function(g: any)
		local baseline = assert(Compiler.compile(
			[[
				local s = 0
				for i = 1, 3 do
					s += i
				end
				return s
			]],
			{ optimizationLevel = 2, debugLevel = 2, typeInfoLevel = 1 }
		))
		local len = #baseline
		local buf = buffer.fromstring(baseline)
		local flips: number = g:int(1, 5)
		for _ = 1, flips do
			local idx: number = g:int(0, len - 1)
			local val: number = g:int(0, 255)
			buffer.writeu8(buf, idx, val)
		end
		local mutated = buffer.tostring(buf)
		local modOrNil, deserErr = BytecodeCodec.deserialize(mutated)
		if modOrNil == nil then
			expect(type(deserErr) == "string" and #(deserErr :: string) > 0, "deserialize error string")
		else
			sert.eq(table.isfrozen(modOrNil :: any), true)
		end
		local fn, err = VM.loadBytecode(mutated, { name = "=mut_fuzz", instructionLimit = 500 })
		if fn == nil then
			expect(type(err) == "string" and #err > 0, "loadBytecode error string")
		else
			local okRun, errRun = pcall(fn)
			if not okRun then
				expect(type(errRun) == "string", "fuzzed mutated bytecode runtime error is string")
			end
		end
	end, { runs = 100 })

	test(
		"enforces instructionLimit on cold opcodes, interrupt on backward FORNPREP, xpcall callLimit, and timeout + resetBudget",
		function()
			local Opcodes = BytecodeDefs.Opcodes

			-- 1. Cold opcodes (NOP/BREAK/CLOSEUPVALS) charge instructionLimit
			local bcbCold = BytecodeBuilder.new()
			local fCold = bcbCold:beginFunction(0, false)
			local loopStart = bcbCold:emitLabel()
			bcbCold:emitABC(Opcodes.LOP_NOP, 0, 0, 0)
			bcbCold:emitABC(Opcodes.LOP_BREAK, 0, 0, 0)
			bcbCold:emitABC(Opcodes.LOP_CLOSEUPVALS, 0, 0, 0)
			local jumpLbl = bcbCold:emitLabel()
			bcbCold:emitAD(Opcodes.LOP_JUMPBACK, 0, 0)
			assert(bcbCold:patchJumpD(jumpLbl, loopStart))
			bcbCold:emitABC(Opcodes.LOP_RETURN, 0, 1, 0)
			bcbCold:endFunction(2, 0, 0)
			bcbCold:setMainFunction(fCold)
			bcbCold:finalize()

			local coldFn =
				assert(VM.loadBytecode(bcbCold:getBytecode(), { name = "=cold_limit", instructionLimit = 25 }))
			local okCold, errCold = pcall(coldFn)
			sert.eq(okCold, false)
			expect(string.find(tostring(errCold), "instruction limit exceeded", 1, true) ~= nil, tostring(errCold))

			-- 2. Backward FORNPREP loop triggers interrupt
			local bcbBackFor = BytecodeBuilder.new()
			local fBackFor = bcbBackFor:beginFunction(0, false)
			bcbBackFor:emitAD(Opcodes.LOP_LOADN, 0, 0) -- limit = 0 (idx=1 > limit skips/branches backward to bodyStart)
			bcbBackFor:emitAD(Opcodes.LOP_LOADN, 1, 1) -- step = 1
			bcbBackFor:emitAD(Opcodes.LOP_LOADN, 2, 1) -- idx = 1
			local bodyStart = bcbBackFor:emitLabel()
			bcbBackFor:emitABC(Opcodes.LOP_NOP, 0, 0, 0)
			local prepLbl = bcbBackFor:emitLabel()
			bcbBackFor:emitAD(Opcodes.LOP_FORNPREP, 0, 0)
			assert(bcbBackFor:patchJumpD(prepLbl, bodyStart))
			bcbBackFor:emitABC(Opcodes.LOP_RETURN, 0, 1, 0)
			bcbBackFor:endFunction(4, 0, 0)
			bcbBackFor:setMainFunction(fBackFor)
			bcbBackFor:finalize()

			local backTicks = 0
			local backForFn = assert(VM.loadBytecode(bcbBackFor:getBytecode(), {
				name = "=back_forn",
				interruptInterval = 8,
				interrupt = function(): boolean?
					backTicks += 1
					if backTicks >= 3 then
						return false
					end
					return true
				end,
			}))
			local okBackFor, errBackFor = pcall(backForFn)
			sert.eq(okBackFor, false)
			sert.eq(backTicks, 3)
			expect(string.find(tostring(errBackFor), "execution interrupted", 1, true) ~= nil, tostring(errBackFor))

			-- 3. Recursive xpcall under callLimit aborts cleanly
			local recXpFn = assert(VM.load(
				[[
				local function dive()
					local ok, res = xpcall(function()
						return dive()
					end, function(err)
						local okH, errH = pcall(dive)
						return if okH then errH else err
					end)
					if not ok then
						error(tostring(res), 0)
					end
					return res
				end
				return dive()
			]],
				{ name = "=rec_xpcall", callLimit = 8 }
			))
			local okRecXp, errRecXp = pcall(recXpFn)
			sert.eq(okRecXp, false)
			expect(string.find(tostring(errRecXp), "call stack overflow", 1, true) ~= nil, tostring(errRecXp))
			local afterFn = assert(VM.load("return 9", { name = "=after_xp" }))
			sert.eq(afterFn(), 9)

			-- 4. timeout + VM.resetBudget
			local timeoutFn = assert(VM.load("while true do end", { name = "=timeout_loop", timeout = 0.005 }))
			local okTo, errTo = pcall(timeoutFn)
			sert.eq(okTo, false)
			expect(string.find(tostring(errTo), "timeout", 1, true) ~= nil, tostring(errTo))

			local budgetedFn = assert(
				VM.load(
					"local s = 0; for i = 1, 60 do s += i end; return s",
					{ name = "=reset_budget", instructionLimit = 220, timeout = 5 }
				)
			)
			sert.eq(budgetedFn(), 1830)
			local okSecond = pcall(budgetedFn)
			sert.eq(okSecond, false)
			sert.eq(VM.resetBudget(budgetedFn), true)
			sert.eq(VM.resetBudget(print), false)
			sert.eq(budgetedFn(), 1830)
		end
	)

	test("Verifier.verify validates binary strings, buffers, custom decoders, and ProtoModules", function()
		local Verifier = require("../src/VM/Verifier")
		local validSrc = "local x = { a = 1, b = 2 }; return x.a + x.b"
		local validBc = assert(Compiler.compile(validSrc, { optimizationLevel = 2 }))
		local validMod = assert(BytecodeCodec.deserialize(validBc))

		local okStr, errStr = Verifier.verify(validBc)
		sert.eq(okStr, true)
		sert.eq(errStr, nil)

		local okBuf, errBuf = Verifier.verify(buffer.fromstring(validBc))
		sert.eq(okBuf, true)
		sert.eq(errBuf, nil)

		local okMod, errMod = Verifier.verify(validMod)
		sert.eq(okMod, true)
		sert.eq(errMod, nil)

		local xorBc = assert(Compiler.compile(validSrc, {
			optimizationLevel = 2,
			encoder = function(b)
				return bit32.bxor(b, 0x5a)
			end,
		}))
		local okDecFail = Verifier.verify(xorBc)
		sert.eq(okDecFail, false)
		local okDecPass, errDecPass = Verifier.verify(xorBc, function(b)
			return bit32.bxor(b, 0x5a)
		end)
		sert.eq(okDecPass, true)
		sert.eq(errDecPass, nil)

		local badInputs: { any } = {
			"",
			buffer.create(0),
			BytecodeCodec.encodeError(":1: parse error"),
			string.sub(validBc, 1, #validBc - 3),
			123,
			{
				version = Tags.LBC_VERSION_TARGET,
				typesversion = Tags.LBC_TYPE_VERSION_TARGET,
				strings = {},
				mainid = 0,
				protos = {
					{
						id = 0,
						maxstacksize = 2,
						numparams = 0,
						nups = 0,
						isvararg = false,
						flags = 0,
						code = { Helpers.encodeABC(BytecodeDefs.Opcodes.LOP_NATIVECALL, 0, 0, 0) },
						kTypes = {},
						kValues = {},
						p = {},
					},
				},
			},
		}
		for _, bad in badInputs do
			local okBad, errBad = Verifier.verify(bad)
			sert.eq(okBad, false)
			expect(type(errBad) == "string" and #(errBad :: string) > 0, "expected error message")
		end
	end)

	test("enforces opt-in ResourceLimits on createEnvironment, sandbox, LoadOptions, and cloneFunction", function()
		local Ouro = require("../")

		-- Default env (no resourceLimits) preserves frozen stdlib references
		local plainEnv = VM.createEnvironment()
		sert.eq(plainEnv.string, string)
		sert.eq(plainEnv.buffer, buffer)

		-- Invalid resourceLimits validation
		local okBadEnv = pcall(function()
			VM.createEnvironment(nil, { resourceLimits = { maxStringLength = -1 } })
		end)
		sert.eq(okBadEnv, false)
		sert.throws(function()
			Ouro.load("return 1", {
				name = "=bad_rl",
				resourceLimits = { maxBufferSize = 0 / 0 },
			})
		end, "invalid maxBufferSize")

		local limits: Types.ResourceLimits = {
			maxStringLength = 10,
			maxTableSize = 8,
			maxBufferSize = 12,
			maxPatternLength = 5,
		}

		local function checkAllGuards(runCode: (string) -> (boolean, any))
			-- maxStringLength
			local okRep, resRep = runCode("return string.rep('ab', 5)")
			sert.eq(okRep, true)
			sert.eq(resRep, "ababababab")
			local okRepFail, errRep = runCode("return string.rep('ab', 6)")
			sert.eq(okRepFail, false)
			expect(string.find(tostring(errRep), "string length limit", 1, true) ~= nil, tostring(errRep))

			local okMethRep = runCode("return ('a'):rep(11)")
			sert.eq(okMethRep, false)

			local okFmt, resFmt = runCode("return string.format('%s-%d', 'hi', 42)")
			sert.eq(okFmt, true)
			sert.eq(resFmt, "hi-42")
			local okFmtFail = runCode("return string.format('%20s', 'x')")
			sert.eq(okFmtFail, false)

			local okChar = runCode("return string.char(65, 66, 67)")
			sert.eq(okChar, true)
			local okCharFail = runCode("return string.char(65,66,67,68,69,70,71,72,73,74,75)")
			sert.eq(okCharFail, false)

			if (string :: any).pack ~= nil then
				local okPackFail = runCode("return string.pack('c15', 'a')")
				sert.eq(okPackFail, false)
			end

			local okGsubFail = runCode("return string.gsub('aaaaaa', 'a', 'bb')")
			sert.eq(okGsubFail, false)

			local okConcatOp = runCode("local t = { '1234', '5678', '901' }; return t[1] .. t[2] .. t[3]")
			sert.eq(okConcatOp, false)
			local okConcatNumFail = runCode("local a, b = '123456', 78901; return a .. b")
			sert.eq(okConcatNumFail, false)
			local okConcatTblFail = runCode(
				"local a = '12345'; local b = setmetatable({}, { __concat = function() return '12345678901' end }); return a .. b"
			)
			sert.eq(okConcatTblFail, false)
			local okConcatOk, resConcatOk = runCode("local t = { '12345', '67890' }; return t[1] .. t[2]")
			sert.eq(okConcatOk, true)
			sert.eq(resConcatOk, "1234567890")

			-- maxPatternLength
			local okFind, idxFind = runCode("return string.find('hello world', 'world')")
			sert.eq(okFind, true)
			sert.eq(idxFind, 7)
			local okFindFail, errFind = runCode("return string.find('hello world', 'abcdef')")
			sert.eq(okFindFail, false)
			expect(string.find(tostring(errFind), "pattern length limit", 1, true) ~= nil, tostring(errFind))
			local okMatchFail = runCode("return ('hello'):match('abcdef')")
			sert.eq(okMatchFail, false)
			local okGmatchFail = runCode("return string.gmatch('hello', 'abcdef')")
			sert.eq(okGmatchFail, false)
			local okGsubPatFail = runCode("return string.gsub('hello', 'abcdef', 'x')")
			sert.eq(okGsubPatFail, false)

			-- maxTableSize
			local okTblCreate = runCode("return #table.create(8, 1)")
			sert.eq(okTblCreate, true)
			local okTblCreateFail, errTbl = runCode("return table.create(9, 1)")
			sert.eq(okTblCreateFail, false)
			expect(string.find(tostring(errTbl), "table size limit", 1, true) ~= nil, tostring(errTbl))
			local okTblMoveFail = runCode("return table.move({1,2,3}, 1, 3, 7, {})")
			sert.eq(okTblMoveFail, false)
			local okTblConcatLenFail = runCode("return table.concat({1,2,3,4,5,6,7,8,9}, ',')")
			sert.eq(okTblConcatLenFail, false)
			local okTblConcatStrFail = runCode("return table.concat({'123456', '78901'})")
			sert.eq(okTblConcatStrFail, false)
			local okNewTableFail = runCode("local t = {1,2,3,4,5,6,7,8,9}; return #t")
			sert.eq(okNewTableFail, false)
			local okDupTableFail = runCode("local t = {a=1,b=2,c=3,d=4,e=5,f=6,g=7,h=8,i=9}; return t.a")
			sert.eq(okDupTableFail, false)
			local okPackFail = runCode("return table.pack(1,2,3,4,5,6,7,8,9).n")
			sert.eq(okPackFail, false)
			local okPackMultiFail = runCode("local a = {1,2,3,4,5}; return table.pack(6, 7, 8, 9, table.unpack(a)).n")
			sert.eq(okPackMultiFail, false)
			local okCloneFail = runCode("local t = {1,2,3,4,5,6,7,8}; t[9] = 9; return #table.clone(t)")
			sert.eq(okCloneFail, false)
			local okCloneOk, resCloneOk = runCode("local t = {1,2,3}; return #table.clone(t)")
			sert.eq(okCloneOk, true)
			sert.eq(resCloneOk, 3)

			-- utf8.char + buffer.readstring / buffer.tostring under maxStringLength
			local okUtf8Ok, resUtf8Ok = runCode("return utf8.char(65, 66)")
			sert.eq(okUtf8Ok, true)
			sert.eq(resUtf8Ok, "AB")
			local okUtf8MultiFail = runCode("return utf8.char(table.unpack(table.create(4, 8000)))")
			sert.eq(okUtf8MultiFail, false)

			-- maxBufferSize & maxStringLength buffer string conversions
			local okBufOk = runCode("return buffer.len(buffer.create(12))")
			sert.eq(okBufOk, true)
			local okBufReadStrOk, resBufReadStrOk =
				runCode("local b = buffer.fromstring('hello'); return buffer.readstring(b, 0, 5)")
			sert.eq(okBufReadStrOk, true)
			sert.eq(resBufReadStrOk, "hello")
			local okBufToStrOk, resBufToStrOk =
				runCode("local b = buffer.fromstring('hello'); return buffer.tostring(b)")
			sert.eq(okBufToStrOk, true)
			sert.eq(resBufToStrOk, "hello")
			local okBufReadStrFail = runCode("local b = buffer.create(12); return buffer.readstring(b, 0, 11)")
			sert.eq(okBufReadStrFail, false)
			local okBufToStrFail = runCode("local b = buffer.create(12); return buffer.tostring(b)")
			sert.eq(okBufToStrFail, false)
			local okBufCreateFail, errBuf = runCode("return buffer.create(13)")
			sert.eq(okBufCreateFail, false)
			expect(string.find(tostring(errBuf), "buffer size limit", 1, true) ~= nil, tostring(errBuf))
			local okBufFromStrFail = runCode("return buffer.fromstring('1234567890123')")
			sert.eq(okBufFromStrFail, false)
		end

		-- Mode 1: createEnvironment({ resourceLimits })
		local rlEnv = VM.createEnvironment(nil, { resourceLimits = limits })
		checkAllGuards(function(src)
			local fn = assert(Ouro.load(src, { name = "=rl_env", env = rlEnv }))
			return pcall(fn)
		end)

		-- Mode 2: sandbox(readOnly env with resourceLimits)
		local roRlEnv = VM.createEnvironment(nil, { readOnly = true, resourceLimits = limits })
		local sbRlEnv = VM.sandbox(roRlEnv)
		checkAllGuards(function(src)
			local fn = assert(Ouro.load(src, { name = "=rl_sb", env = sbRlEnv }))
			return pcall(fn)
		end)

		-- Mode 3: LoadOptions.resourceLimits on existing plain env + cloneFunction inheritance
		local sharedPlain = VM.createEnvironment(nil, { readOnly = true })
		checkAllGuards(function(src)
			local fn = assert(Ouro.load(src, { name = "=rl_opt", env = sharedPlain, resourceLimits = limits }))
			local cloned = assert(VM.cloneFunction(fn))
			return pcall(cloned)
		end)

		-- Mode 4: Ouro.load with resourceLimits and no env (exercises VM/init createEnvironment with envOpts)
		local fnNoEnv, errNoEnv = Ouro.load("return string.rep('a', 11)", {
			name = "=rl_noenv",
			resourceLimits = { maxStringLength = 5 },
		})
		assert(fnNoEnv ~= nil, tostring(errNoEnv))
		sert.eq(pcall(fnNoEnv), false)
	end)

	test("Verifier.verify rejects malformed constants, instruction operands, closures, and metadata", function()
		local Verifier = require("../src/VM/Verifier")
		local Opcodes = BytecodeDefs.Opcodes
		local function baseProto(overrides: { [string]: any }): Types.Proto
			local p: { [string]: any } = {
				id = 0,
				maxstacksize = 4,
				numparams = 0,
				nups = 0,
				isvararg = false,
				flags = 0,
				code = { Helpers.encodeABC(Opcodes.LOP_RETURN, 0, 1, 0) },
				kTypes = {},
				kValues = {},
				p = {},
				linedefined = 1,
			}
			for k, v in overrides do
				p[k] = v
			end
			return p :: any
		end
		local function wrapMod(protos: { Types.Proto }, mainid: number?): Types.ProtoModule
			return {
				version = Tags.LBC_VERSION_TARGET,
				typesversion = Tags.LBC_TYPE_VERSION_TARGET,
				strings = { "s" },
				mainid = mainid or 0,
				protos = protos,
			}
		end
		local badMods: { Types.ProtoModule } = {
			wrapMod({ baseProto({ kTypes = { Tags.LBC_CONSTANT_NIL }, kValues = { 1 } }) }),
			wrapMod({
				baseProto({
					kTypes = { Tags.LBC_CONSTANT_IMPORT },
					kValues = { bit32.bor(bit32.lshift(1, 30), bit32.lshift(9, 20)) },
				}),
			}),
			wrapMod({ baseProto({ kTypes = { Tags.LBC_CONSTANT_TABLE }, kValues = { { keys = { 9 }, length = 1 } } }) }),
			wrapMod({
				baseProto({
					kTypes = { Tags.LBC_CONSTANT_NIL, Tags.LBC_CONSTANT_TABLE },
					kValues = { nil, { keys = { 0 }, length = 1 } },
				}),
			}),
			wrapMod({ baseProto({ kTypes = { Tags.LBC_CONSTANT_TABLE }, kValues = { "not_table" } }) }),
			wrapMod({
				baseProto({
					kTypes = { Tags.LBC_CONSTANT_TABLE_WITH_CONSTANTS },
					kValues = { { keys = {}, constants = { 9 }, length = 1 } },
				}),
			}),
			wrapMod({ baseProto({ code = { 0xff, Helpers.encodeABC(Opcodes.LOP_RETURN, 0, 1, 0) } }) }),
			wrapMod({
				baseProto({
					code = {
						Helpers.encodeAD(Opcodes.LOP_GETIMPORT, 10, 0),
						0,
						Helpers.encodeABC(Opcodes.LOP_RETURN, 0, 1, 0),
					},
				}),
			}),
			wrapMod({
				baseProto({
					code = {
						Helpers.encodeAD(Opcodes.LOP_GETIMPORT, 0, 5),
						0,
						Helpers.encodeABC(Opcodes.LOP_RETURN, 0, 1, 0),
					},
				}),
			}),
			wrapMod({
				baseProto({
					kTypes = { Tags.LBC_CONSTANT_NUMBER },
					kValues = { 1 },
					code = {
						Helpers.encodeAD(Opcodes.LOP_GETIMPORT, 0, 0),
						0,
						Helpers.encodeABC(Opcodes.LOP_RETURN, 0, 1, 0),
					},
				}),
			}),
			wrapMod({
				baseProto({
					code = {
						Helpers.encodeAD(Opcodes.LOP_LOADKX, 10, 0),
						0,
						Helpers.encodeABC(Opcodes.LOP_RETURN, 0, 1, 0),
					},
				}),
			}),
			wrapMod({
				baseProto({
					code = {
						Helpers.encodeAD(Opcodes.LOP_LOADKX, 0, 0),
						5,
						Helpers.encodeABC(Opcodes.LOP_RETURN, 0, 1, 0),
					},
				}),
			}),
			wrapMod({
				baseProto({
					kTypes = { Tags.LBC_CONSTANT_TABLE },
					kValues = { { keys = {}, length = 0 } },
					code = {
						Helpers.encodeAD(Opcodes.LOP_LOADKX, 0, 0),
						0,
						Helpers.encodeABC(Opcodes.LOP_RETURN, 0, 1, 0),
					},
				}),
			}),
			wrapMod({
				baseProto({
					code = {
						Helpers.encodeABC(Opcodes.LOP_GETTABLEKS, 10, 0, 0),
						0,
						Helpers.encodeABC(Opcodes.LOP_RETURN, 0, 1, 0),
					},
				}),
			}),
			wrapMod({
				baseProto({
					kTypes = { Tags.LBC_CONSTANT_NUMBER },
					kValues = { 1 },
					code = {
						Helpers.encodeABC(Opcodes.LOP_GETTABLEKS, 0, 0, 0),
						0,
						Helpers.encodeABC(Opcodes.LOP_RETURN, 0, 1, 0),
					},
				}),
			}),
			wrapMod({
				baseProto({
					code = {
						Helpers.encodeABC(Opcodes.LOP_NAMECALL, 0, 0, 0),
						5,
						Helpers.encodeABC(Opcodes.LOP_RETURN, 0, 1, 0),
					},
				}),
			}),
			wrapMod({
				baseProto({
					kTypes = { Tags.LBC_CONSTANT_NUMBER },
					kValues = { 1 },
					code = {
						Helpers.encodeABC(Opcodes.LOP_NAMECALL, 0, 0, 0),
						0,
						Helpers.encodeABC(Opcodes.LOP_RETURN, 0, 1, 0),
					},
				}),
			}),
			wrapMod({
				baseProto({
					code = {
						Helpers.encodeAD(Opcodes.LOP_NEWCLOSURE, 10, 0),
						Helpers.encodeABC(Opcodes.LOP_RETURN, 0, 1, 0),
					},
				}),
			}),
			wrapMod({
				baseProto({
					code = {
						Helpers.encodeAD(Opcodes.LOP_NEWCLOSURE, 0, 5),
						Helpers.encodeABC(Opcodes.LOP_RETURN, 0, 1, 0),
					},
				}),
			}),
			wrapMod({
				baseProto({
					code = {
						Helpers.encodeAD(Opcodes.LOP_DUPCLOSURE, 0, 5),
						Helpers.encodeABC(Opcodes.LOP_RETURN, 0, 1, 0),
					},
				}),
			}),
			wrapMod({
				baseProto({
					kTypes = { Tags.LBC_CONSTANT_NUMBER },
					kValues = { 1 },
					code = {
						Helpers.encodeAD(Opcodes.LOP_DUPCLOSURE, 0, 0),
						Helpers.encodeABC(Opcodes.LOP_RETURN, 0, 1, 0),
					},
				}),
			}),
			wrapMod({
				baseProto({ id = 0, nups = 1 }),
				baseProto({
					id = 1,
					code = {
						Helpers.encodeAD(Opcodes.LOP_NEWCLOSURE, 0, 0),
						Helpers.encodeABC(Opcodes.LOP_RETURN, 0, 1, 0),
					},
				}),
			}, 1),
		}
		for idx, badMod in badMods do
			local ok, err = Verifier.verify(badMod)
			sert.eq(ok, false, `badMod #{idx} must fail`)
			expect(type(err) == "string" and #(err :: string) > 0, `badMod #{idx} error`)
		end
	end)

	test(
		"enforces string metatable lock, closed math RNG escape, wrapper/resourceLimits propagation, and verifier hardening",
		function()
			local Ouro = require("../")
			local Opcodes = BytecodeDefs.Opcodes
			local Verifier = require("../src/VM/Verifier")

			-- 1. getmetatable("") == "The metatable is locked" across O0/O1/O2 and missing-arg errors
			for _, opt in { 0, 1, 2 } do
				local fn = assert(Ouro.load(
					[[
					local mt = getmetatable("")
					local okGm, errGm = pcall(getmetatable)
					local okRg, errRg = pcall(rawget, {})
					local okNx, errNx = pcall(next)
					return mt, okGm, tostring(errGm), okRg, tostring(errRg), okNx, tostring(errNx)
				]],
					{ name = "=mt_lock_" .. tostring(opt), compile = { optimizationLevel = opt } }
				))
				local mt, okGm, errGm, okRg, errRg, okNx, errNx = fn()
				sert.eq(mt, "The metatable is locked")
				sert.eq(okGm, false)
				expect(string.find(errGm, "missing argument #1", 1, true) ~= nil, errGm)
				sert.eq(okRg, false)
				expect(string.find(errRg, "missing argument #2", 1, true) ~= nil, errRg)
				sert.eq(okNx, false)
				expect(string.find(errNx, "missing argument #1", 1, true) ~= nil, errNx)
			end

			-- 2. math = nil RNG escape closed across inheritHost = false/true and sandbox
			local envs = {
				VM.createEnvironment(),
				VM.createEnvironment(nil, { inheritHost = true }),
				VM.sandbox(VM.createEnvironment()),
			}
			for idx, env in envs do
				local fn = assert(Ouro.load(
					[[
					_G.math = nil
					return _G.math, math
				]],
					{ name = "=math_nil_" .. tostring(idx), env = env }
				))
				local gm, m = fn()
				sert.eq(gm, nil)
				sert.eq(m, nil)
			end

			-- 3. HOST_WRAPPERS and ResourceLimits propagate across rawget, next, for-in, coroutine, xpcall, namecall, and stepImportChain
			local rlEnv = VM.createEnvironment(nil, { resourceLimits = { maxStringLength = 10, maxTableSize = 4 } })
			local propCases = {
				{
					name = "rawget_coroutine",
					src = "return rawget(_G, 'coroutine').wrap(function() return string.rep('x', 20) end)()",
				},
				{
					name = "next_string_rep",
					src = "local _, f = next({ s = string.rep }); return f('x', 20)",
				},
				{
					name = "for_in_string_rep",
					src = "for _, f in { a = string.rep } do return f('x', 20) end; return nil",
				},
				{
					name = "coroutine_create",
					src = "local co = coroutine.create(function() return string.rep('x', 20) end); local ok, res = coroutine.resume(co); assert(ok, res); return res",
				},
				{
					name = "xpcall_body",
					src = "local ok, res = xpcall(function() return string.rep('x', 20) end, function(e) return e end); assert(ok, res); return res",
				},
				{
					name = "xpcall_handler",
					src = "local ok, res = xpcall(function() error('boom') end, function() return string.rep('y', 20) end); assert(ok, res); return res",
				},
				{
					name = "resolve_namecall",
					src = "local s = 'abc'; return s:rep(10)",
				},
				{
					name = "step_import_chain",
					src = "local f = string.rep; return f('z', 20)",
				},
			}
			for _, tc in propCases do
				local pFn = assert(Ouro.load(tc.src, {
					name = "=prop_" .. tc.name,
					env = rlEnv,
					compile = { optimizationLevel = 2 },
				}))
				sert.eq(pcall(pFn :: any), false, tc.name .. " must enforce resourceLimits")
			end

			-- 4. Pre-allocation guards: string.format summed width, string.gsub L^2 vs zero-match, string.split, table.clone hash keys, table.concat
			local fmtOver = assert(Ouro.load("return string.format('%6d%6d', 1, 2)", { env = rlEnv }))
			sert.eq(pcall(fmtOver :: any), false)
			local gsubOver = assert(Ouro.load("return string.gsub('aaaaaaa', 'a', '%0%0')", { env = rlEnv }))
			sert.eq(pcall(gsubOver :: any), false)
			local gsubZeroMatch = assert(Ouro.load("return string.gsub('abcdefg', 'zzzzz', '%0%0%0')", { env = rlEnv }))
			local gmStr, gmCount = gsubZeroMatch()
			sert.eq(gmStr, "abcdefg")
			sert.eq(gmCount, 0)
			local splitOver = assert(Ouro.load("return string.split('1,2,3,4,5,6', ',')", { env = rlEnv }))
			sert.eq(pcall(splitOver :: any), false)
			local cloneOver =
				assert(Ouro.load("return table.clone({ a = 1, b = 2, c = 3, d = 4, e = 5 })", { env = rlEnv }))
			sert.eq(pcall(cloneOver :: any), false)
			local concatOver = assert(Ouro.load("return table.concat({ 'aaaa', 'bbbb', 'cccc' })", { env = rlEnv }))
			sert.eq(pcall(concatOver :: any), false)

			-- 5. Verifier hardening: invalid p.upvalues, invalid LOP_FASTPCALL target, v100 ProtoModule/binary rejection, and bad decoder throw
			local function mkMod(protos: { any }): any
				return {
					version = 14,
					typesversion = 3,
					strings = {},
					protos = protos,
					mainid = 0,
				}
			end
			local function mkProto(over: { [string]: any }): any
				local p: any = {
					id = 0,
					maxstacksize = 4,
					numparams = 0,
					nups = 0,
					isvararg = false,
					flags = 0,
					code = { Helpers.encodeABC(Opcodes.LOP_RETURN, 0, 1, 0) },
					kTypes = {},
					kValues = {},
					p = {},
					linedefined = 1,
				}
				for k, v in over do
					p[k] = v
				end
				return p
			end
			local badUvMod = mkMod({
				mkProto({
					nups = 1,
					upvalues = { 123 :: any },
				}),
			})
			sert.eq(select(1, Verifier.verify(badUvMod)), false)

			local badFastPcallMod = mkMod({
				mkProto({
					maxstacksize = 2,
					code = {
						Helpers.encodeABC(Opcodes.LOP_FASTPCALL, 0, 0, 0),
						Helpers.encodeABC(Opcodes.LOP_LOADN, 0, 1, 0),
						Helpers.encodeABC(Opcodes.LOP_RETURN, 0, 1, 0),
					},
				}),
			})
			sert.eq(select(1, Verifier.verify(badFastPcallMod)), false)

			local clsMod = assert(Compiler.compileProto("class Foo public x: number end", {
				parseOptions = { profile = "experimental" },
			}))
			sert.eq(select(1, Ouro.Bytecode.verify(clsMod)), false)
			local clsBin = assert(Ouro.compile("class Foo public x: number end", {
				parseOptions = { profile = "experimental" },
			}))
			sert.eq(select(1, Ouro.Bytecode.verify(clsBin)), false)
			sert.eq(select(1, VM.loadBytecode(clsBin)), nil)

			local goodBc = assert(Ouro.compile("return 1"))
			sert.throws(function()
				Ouro.Bytecode.verify(goodBc, "bad_decoder" :: any)
			end, "invalid bytecode decoder")

			-- 6. LBF_RAWGET fastcall resourceLimits, 1-arg/empty next, inheritHost getmetatable("") fallback, VM.loadProto validation, and Verifier table constants
			local rawgetRlFn = assert(
				Ouro.load(
					"local t = { f = string.rep }; return rawget(t, 'f')('x', 20)",
					{ name = "=rawget_fc_rl", env = rlEnv, compile = { optimizationLevel = 2 } }
				)
			)
			sert.eq(pcall(rawgetRlFn :: any), false)

			local nextEdgeFn = assert(Ouro.load([[
				local k, v = next({ a = 1 })
				local ek, ev = next({})
				return k, v, ek, ev
			]]))
			local nk, nv, nek, nev = nextEdgeFn()
			sert.eq(nk, "a")
			sert.eq(nv, 1)
			sert.eq(nek, nil)
			sert.eq(nev, nil)

			local inhEnv = VM.createEnvironment(nil, { inheritHost = true })
			local inhGmFn = assert(Ouro.load("_G.getmetatable = nil; return getmetatable('')", { env = inhEnv }))
			sert.eq(inhGmFn(), "The metatable is locked")

			sert.throws(function()
				VM.loadProto(123 :: any)
			end, "ProtoModule table expected")
			local badFrozenStrMod = table.freeze({
				version = 14,
				typesversion = 3,
				strings = "bad" :: any,
				protos = table.freeze({}),
				mainid = 0,
			})
			sert.eq(select(1, VM.loadProto(badFrozenStrMod :: any)), nil)

			local nonScalarTblMod = mkMod({
				mkProto({
					kTypes = { Tags.LBC_CONSTANT_NUMBER, Tags.LBC_CONSTANT_TABLE },
					kValues = { 1, { keys = { 1 }, length = 1 } },
				}),
			})
			sert.eq(select(1, Verifier.verify(nonScalarTblMod)), false)

			local badTblWithConstMod = mkMod({
				mkProto({
					kTypes = { Tags.LBC_CONSTANT_TABLE_WITH_CONSTANTS },
					kValues = { "bad" :: any },
				}),
			})
			sert.eq(select(1, Verifier.verify(badTblWithConstMod)), false)

			local oobTblWithConstMod = mkMod({
				mkProto({
					kTypes = { Tags.LBC_CONSTANT_STRING, Tags.LBC_CONSTANT_TABLE_WITH_CONSTANTS },
					kValues = { "k", { keys = { 99 }, constants = { 0 }, length = 1 } },
				}),
			})
			sert.eq(select(1, Verifier.verify(oobTblWithConstMod)), false)

			local badHeaderMod = mkMod({ mkProto({ maxstacksize = -1 }) })
			sert.eq(select(1, Verifier.verify(badHeaderMod)), false)
			sert.eq(select(1, Verifier.verify(123 :: any)), false)
			sert.eq(
				select(
					1,
					Verifier.verify(
						{ version = 14, typesversion = 3, strings = {}, protos = 123 :: any, mainid = 0 } :: any
					)
				),
				false
			)
			sert.eq(
				select(
					1,
					Verifier.verify(
						{ version = 14, typesversion = 3, strings = {}, protos = { mkProto({}) }, mainid = 99 } :: any
					)
				),
				false
			)
		end
	)
end)

if not sert._bundled then
	return sert.run(sert.parseCliArgs(...))
end
return nil
