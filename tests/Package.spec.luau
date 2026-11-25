--!strict
local Arena = require("../src/Arena")
local Grammar = require("../src/Grammar")
local Ouro = require("../")
local Types = require("../src/Types")
local sert = require("@sert") :: any

local describe = sert.describe
local test = sert.test
local expect = sert

describe("Package", function()
	test("exports root parse, kinds, Ast adapter, and upstream revision", function()
		local result: Ouro.ParseResult = Ouro.parse("local x=1;return x")
		sert.eq(result.status, "ok")
		sert.eq(result:kind(result.root), Ouro.Kinds.AstStatBlock)
		local rootTable: Ouro.AstTable = assert(Ouro.Ast.toTables(result))
		sert.eq(rootTable.type, "AstStatBlock")
		sert.eq(Ouro.upstreamRevision, Grammar.revision)
		sert.eq(Ouro.luauVersion, Grammar.version)
		sert.eq((Ouro.Profiles :: any).upstreamRevision, nil)
		sert.eq((Ouro.Profiles :: any).luauVersion, nil)
		sert.eq(Ouro.Tokens.Eof, 0)
		sert.eq(Ouro.Tokens.Name > 255, true)
		sert.eq(Ouro.Tokens.Comment > 255, true)
		expect(string.match(Ouro.version, "^%d+%.%d+%.%d+") ~= nil, Ouro.version)
		sert.eq(table.isfrozen(getmetatable(Ouro :: any)), true)

		-- Internal loader keys must not leak on the public package metatable
		local rawPkg: any = Ouro
		sert.eq(rawPkg.Parser, nil)
		sert.eq(rawPkg.BytecodeBuilder, nil)
		sert.eq(rawPkg.BytecodeDefs, nil)
		sert.eq(rawPkg.BytecodeCodec, nil)
		sert.eq(rawPkg.DocumentAdapter, nil)

		-- Bytecode error helpers and instruction unpackers live on Ouro.Bytecode, not VM
		local errPayload = Ouro.Bytecode.encodeError(":1: boom")
		sert.eq(Ouro.Bytecode.decodeError(errPayload), ":1: boom")
		sert.eq(Ouro.Bytecode.decodeError(buffer.fromstring(errPayload)), ":1: boom")
		local bc, bcErr = Ouro.compile("local x = 20 + 22; return x")
		sert.eq(bcErr, nil)
		local bcBytes = assert(bc)
		expect(#bcBytes > 0 and string.byte(bcBytes, 1) ~= 0, "compiled bytecode")
		sert.eq(Ouro.Bytecode.decodeError(bcBytes), nil)
		sert.eq(Ouro.Bytecode.decodeError(""), nil)
		sert.eq(type(Ouro.Bytecode.disassemble), "function")
		local pkgDump = Ouro.Bytecode.disassemble(bcBytes)
		expect(string.find(pkgDump, "RETURN", 1, true) ~= nil, pkgDump)
		sert.eq(Ouro.Bytecode.insnOp(0x01020304), 4)
		sert.eq(Ouro.Bytecode.insnA(0x01020304), 3)
		sert.eq(Ouro.Bytecode.insnB(0x01020304), 2)
		sert.eq(Ouro.Bytecode.insnC(0x01020304), 1)

		local rawVM: any = Ouro.VM
		sert.eq(rawVM.deserialize, nil)
		sert.eq(rawVM.insnOp, nil)
		sert.eq(rawVM.decomposeImportId, nil)
		sert.eq(type(Ouro.VM.sandbox), "function")
		sert.eq(type(Ouro.VM.getCoverage), "function")
		sert.eq(type(Ouro.VM.cloneFunction), "function")
		sert.eq(type(Ouro.VM.getUpvalues), "function")
		sert.eq(type(Ouro.VM.setUpvalue), "function")
		sert.eq(type(Ouro.VM.resetBudget), "function")

		local envOpts: Ouro.EnvironmentOptions = {
			inheritHost = false,
			libraries = { "base", "math" },
			readOnly = false,
		}
		local loadMode: Ouro.LoadMode = "binary"
		local loadOpts: Ouro.LoadOptions = {
			mode = loadMode,
			safeEnv = true,
			timeout = 5,
			getGlobal = function(name: string, env: { [any]: any })
				return env[name]
			end,
			setGlobal = function(name: string, value: any, env: { [any]: any })
				env[name] = value
			end,
			onCall = function(_info: Ouro.DebugFrameInfo) end,
			onReturn = function(_info: Ouro.DebugFrameInfo) end,
			onLine = function(_line: number, _info: Ouro.DebugFrameInfo) end,
			onBreak = function(_line: number, _info: Ouro.DebugFrameInfo) end,
		}
		local _covCheck: Ouro.CoverageEntry = {
			name = "fn",
			lineDefined = 1,
			hits = { [1] = 1 },
			totalHits = 1,
		}
		local _uvCheck: Ouro.UpvalueInfo = {
			index = 1,
			name = "x",
			value = 42,
		}
		expect(envOpts.inheritHost == false and loadOpts.safeEnv == true, "new root types compile strictly")
		local okCall = pcall(function()
			return rawVM("return 1")
		end)
		sert.eq(okCall, false)

		local fn = assert(Ouro.load(bcBytes, { name = "=pkg", mode = "binary" }))
		sert.eq(fn(), 42)
		sert.eq(Ouro.VM.resetBudget(fn), true)
		local srcFn = assert(Ouro.load("return ... + 1", { name = "=src" }))
		sert.eq(srcFn(41), 42)
	end)

	test("supports context and fragment entrypoints", function()
		local context: Ouro.ParserContext = Ouro.newContext()
		sert.eq(context:parse("return 1").status, "ok")
		sert.eq(context:parseExpression("1 2").status, "ok")
		sert.eq(Ouro.parseExpression("1 2", { requireEOF = true }).status, "syntaxError")
	end)

	test("captures hotcomments, optional comments, and lossless tape independently", function()
		local normal = Ouro.parse("-- hi\n--!strict\nreturn 1")
		sert.eq(#normal.comments, 0)
		sert.eq(normal.hotcomments[1].content, "strict")

		local captured = Ouro.parse("-- hi\nreturn 1", { captureComments = true })
		sert.eq(#captured.comments, 1)

		local lossless = Ouro.parse("-- hi\nreturn 1", { lossless = true, captureComments = false })
		sert.eq(#lossless.comments, 0)
		sert.eq(lossless:reconstruct(), "-- hi\nreturn 1")
	end)

	test("validates AST arena API and custom GrammarFlags tables", function()
		local arena: Arena.ArenaImpl = Arena.new({ "x" })
		local nodeId: Types.NodeId = arena:add({ kind = Arena.Kinds.AstExprConstantNil, start = 0, finish = 3 })
		sert.eq(arena:kind(nodeId), Arena.Kinds.AstExprConstantNil)
		sert.eq(arena:kind(0), 0)
		sert.eq(arena:kindName(nodeId), "AstExprConstantNil")
		sert.eq(arena:kindName(0), "")
		local listId: Types.ListId = arena:list({ nodeId })
		sert.eq(arena:listCount(listId), 1)
		sert.eq(arena:listAt(listId, 1), nodeId)
		sert.eq(arena:listAt(0, 1), nil)
		sert.eq(arena:listAt(listId, 9), nil)
		sert.eq(arena:listItems(listId)[1], nodeId)
		sert.eq(#arena:listItems(0), 0)
		sert.eq(arena:list({}), 0)

		local curried = Ouro.parse("type F = () -> (a: number, string) -> boolean")
		sert.eq(curried.status, "ok")
		local aliasId = curried.arena:listAt(curried.arena.nodes[curried.root].body, 1)
		local fnTypeId = curried.arena.nodes[aliasId].type
		sert.eq(curried:childCount(fnTypeId), 1)
		local retPackId = curried:childAt(fnTypeId, 1)
		local retFnId = curried:childAt(retPackId, 1)
		sert.eq(curried:childCount(retFnId), 4)
		sert.eq(curried:kindName(curried:childAt(retFnId, 3)), "AstArgumentName")

		local confusable = Ouro.parse("local x = \226\128\156")
		sert.eq(confusable.status, "syntaxError")
		expect(
			string.find(confusable.diagnostics[1].message, "U+201c", 1, true) ~= nil,
			confusable.diagnostics[1].message
		)
		local mismatch = Ouro.parse("function f()\n\tif true then\nend\n")
		sert.eq(mismatch.status, "syntaxError")
		expect(
			string.find(mismatch.diagnostics[1].message, "to close 'then'", 1, true) ~= nil,
			mismatch.diagnostics[1].message
		)

		local flags: Ouro.GrammarFlags = { LuauExperimentalIfLocalSyntax = true }
		local condition = Ouro.parse("if local x:number=1 then end", { profile = flags })
		sert.eq(condition.status, "ok")
		local out = assert(Ouro.Ast.toTables(condition))
		sert.eq(out.body[1].conditionLocal.name, "x")
		local conditional = condition.arena.nodes[condition.arena:listAt(condition.arena.nodes[condition.root].body, 1)]
		expect(condition.arena.bindings[conditional.conditionLocal].annotation ~= 0, "binding annotation retained")
		sert.eq(condition:childCount(condition.arena:listAt(condition.arena.nodes[condition.root].body, 1)), 3)
	end)

	test("walks large arena child collections with caching and exercises Diagnostics.locationCursor", function()
		local Diagnostics = require("../src/Diagnostics")
		local UpstreamAstAdapter = require("./UpstreamAstAdapter")

		local richSrc = [[
@native
local function outer(p: number): number
	for i: number = 1, 2 do
		local f = function(q: number): number
			return q + p
		end
		if i > 0 then
			return f(i)
		end
	end
	return p
end

type ManyArgs = (a: number, b: string, c: boolean, d: any, e: number, ...string) -> (number, ...boolean)

local tbl = { [1] = 10, a = 20, b = 30, c = 40, d = 50 }

local v1: number, v2: string, v3: boolean, v4: number, v5: string = 1, "a", true, 2, "b"

return outer(tbl.a + v1)
]]
		local parsed = Ouro.parse(richSrc)
		sert.eq(parsed.status, "ok")

		local root = parsed.root
		local fnTypeId = parsed.arena.nodes[parsed:childAt(root, 2)].type
		local localTblId = parsed:childAt(root, 3)
		local tblId = parsed.arena.nodes[localTblId].values
			and parsed.arena:listAt(parsed.arena.nodes[localTblId].values, 1)
		local multiLocalId = parsed:childAt(root, 4)

		-- Trigger collectChildren + _childCache across >4 argNames (+ tail), >4 table items, and >4 typed locals
		local fnChildren = parsed:childCount(fnTypeId)
		sert.eq(fnChildren, 12)
		sert.eq(parsed:childAt(fnTypeId, 1) ~= 0, true)
		sert.eq(parsed:childAt(fnTypeId, fnChildren) ~= 0, true)
		sert.eq(parsed:childCount(fnTypeId), fnChildren)
		sert.eq(parsed:childAt(fnTypeId, fnChildren + 1), 0)

		local tblChildren = parsed:childCount(tblId)
		sert.eq(tblChildren, 10)
		sert.eq(parsed:childAt(tblId, 1) ~= 0, true)
		sert.eq(parsed:childAt(tblId, tblChildren) ~= 0, true)
		sert.eq(parsed:childCount(tblId), tblChildren)

		local multiChildren = parsed:childCount(multiLocalId)
		expect(multiChildren >= 10, "5 typed locals + 5 values")
		sert.eq(parsed:childAt(multiLocalId, 1) ~= 0, true)
		sert.eq(parsed:childAt(multiLocalId, multiChildren) ~= 0, true)
		sert.eq(parsed:childCount(multiLocalId), multiChildren)

		local astTable = assert(Ouro.Ast.toTables(parsed))
		sert.eq(#astTable.body, 5)
		local upstreamTbl = assert(UpstreamAstAdapter.toTables(parsed))
		sert.eq(#upstreamTbl.body, 5)

		-- Exercise Diagnostics.locationCursor forward (+1, +2+ binary search), backward (-1, -2+), and single-line spans
		local lineStarts = { 0, 10, 20, 30, 40, 50 }
		local loc1, idx1 = Diagnostics.locationCursor(lineStarts, 12, 15, 1)
		sert.eq(loc1, "1,2 - 1,5")
		sert.eq(idx1, 2)
		local loc2, idx2 = Diagnostics.locationCursor(lineStarts, 42, 48, 2)
		sert.eq(loc2, "4,2 - 4,8")
		sert.eq(idx2, 5)
		local loc3, idx3 = Diagnostics.locationCursor(lineStarts, 31, 35, 5)
		sert.eq(loc3, "3,1 - 3,5")
		sert.eq(idx3, 4)
		local loc4, idx4 = Diagnostics.locationCursor(lineStarts, 2, 14, 5)
		sert.eq(loc4, "0,2 - 1,4")
		sert.eq(idx4, 2)
	end)

	test("covers ParseResult visit, forEachChild, Ouro.Bytecode.verify/serialize, and Ouro.load validation", function()
		local richAstSrc = [[
if local condVal: number = 1 then
	local a: number, b: string = 10, "hi"
	local t = { [1 + 1] = a, key = b, 42 }
	type Fn = (p: number, ...string) -> (boolean, ...number)
	local f: Fn = function(p: number, ...: string)
		return p > 0, 1
	end
	return f(t.key == "hi" and 1 or 0)
end
return nil
]]
		local parsed = Ouro.parse(richAstSrc, { profile = "experimental" })
		sert.eq(parsed.status, "ok")

		-- forEachChild boundary cases and early return=false pruning across all child categories
		local zeroVisits = 0
		parsed:forEachChild(0, function()
			zeroVisits += 1
			return true
		end)
		parsed:forEachChild(999999, function()
			zeroVisits += 1
			return true
		end)
		sert.eq(zeroVisits, 0)
		sert.eq(parsed:childCount(999999), 0)
		local r0, r1 = parsed:range(999999)
		sert.eq(r0, 0)
		sert.eq(r1, 0)

		-- Leaf node (AstExprConstantNil) has no child ops
		local rootChildren: { number } = {}
		parsed:forEachChild(parsed.root, function(cid)
			rootChildren[#rootChildren + 1] = cid
			return true
		end)
		local lastRet = rootChildren[#rootChildren]
		local nilLeaf = parsed:childAt(lastRet, 1)
		local leafChildVisits = 0
		parsed:forEachChild(nilLeaf, function()
			leafChildVisits += 1
			return true
		end)
		sert.eq(leafChildVisits, 0)

		-- Stop early on OP_LIST (root block statements)
		local listEarly = 0
		parsed:forEachChild(parsed.root, function()
			listEarly += 1
			return false
		end)
		sert.eq(listEarly, 1)

		-- Stop early on OP_NODE (AstStatIf -> condition, thenbody, conditionLocal)
		local ifId = rootChildren[1]
		local ifBodyId = parsed:childAt(ifId, 2)
		sert.eq(parsed:childCount(ifId), 3)
		local bindingEarly = 0
		parsed:forEachChild(ifId, function()
			bindingEarly += 1
			return false
		end)
		sert.eq(bindingEarly, 1)

		-- Stop early on OP_BINDING_LIST, OP_ITEMS (key & value), and OP_TYPELIST (elem & tail)
		local ifStmts: { number } = {}
		parsed:forEachChild(ifBodyId, function(cid)
			ifStmts[#ifStmts + 1] = cid
			return true
		end)
		local localMultiId = ifStmts[1]
		local blCount = 0
		parsed:forEachChild(localMultiId, function()
			blCount += 1
			return false
		end)
		sert.eq(blCount, 1)

		local tblLocalId = ifStmts[2]
		local tblExprId = parsed:childAt(tblLocalId, 1)
		local itemKeyStop = 0
		parsed:forEachChild(tblExprId, function()
			itemKeyStop += 1
			return false
		end)
		sert.eq(itemKeyStop, 1)
		local itemValStop = 0
		parsed:forEachChild(tblExprId, function()
			itemValStop += 1
			return itemValStop < 2
		end)
		sert.eq(itemValStop, 2)

		local typeAliasId = ifStmts[3]
		local fnTypeId = parsed.arena.nodes[typeAliasId].type
		local tlElemStop = 0
		parsed:forEachChild(fnTypeId, function()
			tlElemStop += 1
			return false
		end)
		sert.eq(tlElemStop, 1)
		local tlTailStop = 0
		parsed:forEachChild(fnTypeId, function()
			tlTailStop += 1
			return tlTailStop < 2
		end)
		sert.eq(tlTailStop, 2)

		-- AstStatReturn -> OP_LIST inside forEachChild
		local retStatId = ifStmts[5]
		local retStop = 0
		parsed:forEachChild(retStatId, function()
			retStop += 1
			return false
		end)
		sert.eq(retStop, 1)
		-- OP_NODE stop early via AstStatLocalFunction / AstTypeAlias -> type
		local aliasStop = 0
		parsed:forEachChild(typeAliasId, function()
			aliasStop += 1
			return false
		end)
		sert.eq(aliasStop, 1)

		-- visit with empty visitor, root == 0, full enter/leave, and enter returning false
		parsed:visit({})
		local emptyRoot: any = { root = 0 }
		parsed.visit(emptyRoot, function(): boolean?
			return nil
		end)

		local enterCount, leaveCount = 0, 0
		parsed:visit({
			enter = function(nid, _kind, depth)
				enterCount += 1
				if nid == tblExprId then
					expect(depth > 0, "positive depth inside block")
					return false
				end
				return true
			end,
			leave = function()
				leaveCount += 1
			end,
		})
		expect(enterCount > 10 and enterCount == leaveCount, "balanced enter and leave with pruning")

		-- Ouro.Bytecode.verify & Ouro.Bytecode.serialize public entrypoints
		local bc = assert(Ouro.compile("local t = { a = 1 }; return t.a"))
		local okV, errV = Ouro.Bytecode.verify(bc)
		sert.eq(okV, true)
		sert.eq(errV, nil)
		local mod = assert(Ouro.Bytecode.deserialize(bc))
		local reBc, serErr = Ouro.Bytecode.serialize(mod)
		sert.eq(serErr, nil)
		sert.eq(Ouro.Bytecode.verify(assert(reBc)), true)

		-- Ouro.load validation paths
		sert.throws(function()
			Ouro.load("return 1", "bad" :: any)
		end, "invalid load options")
		sert.throws(function()
			Ouro.load("return 1", { name = 123 :: any })
		end, "invalid chunk name")
		sert.throws(function()
			Ouro.load("return 1", { mode = "invalid" :: any })
		end, "invalid load mode")
		sert.throws(function()
			Ouro.load(123 :: any)
		end, "expected source string")
		sert.throws(function()
			Ouro.load(buffer.fromstring(bc), { mode = "text" })
		end, "buffer cannot be loaded in text mode")
		local badComp, badCompErr = Ouro.load("local =", {
			compile = {
				encoder = function(op)
					return op
				end,
			},
		})
		sert.eq(badComp, nil)
		expect(string.find(tostring(badCompErr), "^%[string") ~= nil, tostring(badCompErr))

		sert.throws(function()
			Ouro.load(mod, { mode = "text" })
		end, "ProtoModule")
		sert.throws(function()
			Ouro.load("return 1", { unknownOption = true } :: any)
		end, "unknown load option")
		sert.throws(function()
			Ouro.Bytecode.verify(bc, 123 :: any)
		end, "invalid bytecode decoder")
	end)
end)

if not sert._bundled then
	return sert.run(sert.parseCliArgs(...))
end
return nil
