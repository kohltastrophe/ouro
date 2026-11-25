--!strict
local Ast = require("../src/Ast")
local Diagnostics = require("../src/Diagnostics")
local Parser = require("../src/Parser")
local sert = require("@sert") :: any

local describe = sert.describe
local test = sert.test
local prop = sert.prop
local model = sert.model
local gen = sert.gen
local expect = sert

local function parseEntry(source: string, entry: string?, opts: Parser.ParseOptions?): Parser.ParseResult
	if entry == "expression" then
		return Parser.parseExpression(source, opts)
	elseif entry == "type" then
		return Parser.parseType(source, opts)
	else
		return Parser.parse(source, opts)
	end
end

local function valid(source: string, entry: string?, opts: Parser.ParseOptions?): Parser.ParseResult
	local result = parseEntry(source, entry, opts)
	expect(
		result.status == "ok",
		source .. "\n" .. (if result.diagnostics[1] then result.diagnostics[1].message else result.status)
	)
	return result
end

local function stat(result: any, i: number): any
	local id = result.arena:listAt(result.arena.nodes[result.root].body, i)
	return result.arena.nodes[id]
end

-- Stateful model specification for ParserContext lifecycle, scratch reuse, suspension, cancellation, and arena isolation.
local function contextModelSpec(): any
	return {
		init = function()
			return {
				retained = {} :: { any },
				suspended = false,
			}
		end,
		setup = function()
			local state = {
				mode = "ok",
				shouldYield = false,
			}
			local ctx: any
			ctx = Parser.newContext({
				lossless = true,
				recursionLimit = 32,
				errorLimit = 6,
				checkpointInterval = 32,
				checkpoint = function()
					if state.mode == "cancel" then
						return false
					elseif state.mode == "throw" then
						error("model checkpoint boom", 0)
					elseif state.shouldYield then
						state.shouldYield = false
						coroutine.yield("paused")
					end
					return true
				end,
			})
			return {
				ctx = ctx,
				peer = Parser.newContext({ lossless = true }),
				control = state,
				worker = (nil :: any) :: thread?,
				workerSource = "",
			}
		end,
		invariants = {
			matchesModel = function(state: any, sut: any)
				sert.eq((sut.ctx :: any).busy, state.suspended, "context busy flag matches model suspension state")
				for index, item in state.retained do
					local res = item.result
					sert.eq(res.status, item.status, `retained #{index} status`)
					sert.eq(res.source, item.source, `retained #{index} source`)
					sert.eq(res:reconstruct(), item.source, `retained #{index} lossless reconstruct`)
					sert.eq(#res.arena.nodes, item.nodeCount, `retained #{index} arena node count`)
					if item.symbolName ~= nil then
						sert.eq(
							res.arena.symbols[res.arena.bindings[1].name],
							item.symbolName,
							`retained #{index} binding symbol`
						)
					end
				end
			end,
		},
		commands = {
			{
				name = "parseSmall",
				pre = function(state: any)
					return not state.suspended
				end,
				gen = function(_state: any, g: any)
					return g:int(1, 50)
				end,
				run = function(sut: any, id: number)
					sut.control.mode = "ok"
					local sym = `var_{id}`
					local src = `local {sym} = {id}; return {sym}`
					return { result = sut.ctx:parse(src), source = src, sym = sym }
				end,
				post = function(_: any, _: any, _: any, out: any)
					sert.eq(out.result.status, "ok")
					sert.eq(out.result:reconstruct(), out.source)
				end,
				next = function(state: any, _: any, out: any)
					table.insert(state.retained, {
						result = out.result,
						source = out.source,
						status = "ok",
						nodeCount = #out.result.arena.nodes,
						symbolName = out.sym,
					})
				end,
			},
			{
				name = "parseFragments",
				pre = function(state: any)
					return not state.suspended
				end,
				run = function(sut: any)
					sut.control.mode = "ok"
					local expr = sut.ctx:parseExpression("a + b * c")
					local ty = sut.ctx:parseType("{ x: number, y: string }")
					return { expr = expr, ty = ty }
				end,
				post = function(_: any, _: any, _: any, out: any)
					sert.eq(out.expr.status, "ok")
					sert.eq(out.expr:kindName(out.expr.root), "AstExprBinary")
					sert.eq(out.ty.status, "ok")
					sert.eq(out.ty:kindName(out.ty.root), "AstTypeTable")
				end,
				next = function(state: any, _: any, out: any)
					table.insert(state.retained, {
						result = out.expr,
						source = "a + b * c",
						status = "ok",
						nodeCount = #out.expr.arena.nodes,
					})
					table.insert(state.retained, {
						result = out.ty,
						source = "{ x: number, y: string }",
						status = "ok",
						nodeCount = #out.ty.arena.nodes,
					})
				end,
			},
			{
				name = "parseSyntaxError",
				pre = function(state: any)
					return not state.suspended
				end,
				gen = function(_state: any, g: any)
					return g:pick({ "local x =", "if a then", "return f(1, " })
				end,
				run = function(sut: any, src: string)
					sut.control.mode = "ok"
					return { result = sut.ctx:parse(src), source = src }
				end,
				post = function(_: any, _: any, _: any, out: any)
					sert.eq(out.result.status, "syntaxError")
					sert.eq(out.result:reconstruct(), out.source)
					expect(#out.result.diagnostics > 0, "has syntax diagnostics")
				end,
				next = function(state: any, _: any, out: any)
					table.insert(state.retained, {
						result = out.result,
						source = out.source,
						status = "syntaxError",
						nodeCount = #out.result.arena.nodes,
					})
				end,
			},
			{
				name = "parseCancelled",
				pre = function(state: any)
					return not state.suspended
				end,
				run = function(sut: any)
					sut.control.mode = "cancel"
					local src = "local x = '" .. string.rep("z", 128) .. "'\nreturn x"
					local res = sut.ctx:parse(src)
					sut.control.mode = "ok"
					return { result = res, source = src }
				end,
				post = function(_: any, _: any, _: any, out: any)
					sert.eq(out.result.status, "cancelled")
					sert.eq(out.result.root, 0)
					sert.eq(out.result:reconstruct(), out.source)
				end,
				next = function(state: any, _: any, out: any)
					table.insert(state.retained, {
						result = out.result,
						source = out.source,
						status = "cancelled",
						nodeCount = #out.result.arena.nodes,
					})
				end,
			},
			{
				name = "parseLimit",
				pre = function(state: any)
					return not state.suspended
				end,
				run = function(sut: any)
					sut.control.mode = "ok"
					local src = string.rep("do ", 40) .. "return 1 " .. string.rep("end ", 40)
					return { result = sut.ctx:parse(src), source = src }
				end,
				post = function(_: any, _: any, _: any, out: any)
					sert.eq(out.result.status, "limit")
					sert.eq(out.result.root, 0)
					sert.eq(out.result:reconstruct(), out.source)
				end,
				next = function(state: any, _: any, out: any)
					table.insert(state.retained, {
						result = out.result,
						source = out.source,
						status = "limit",
						nodeCount = #out.result.arena.nodes,
					})
				end,
			},
			{
				name = "checkpointThrow",
				pre = function(state: any)
					return not state.suspended
				end,
				run = function(sut: any)
					sut.control.mode = "throw"
					local msg = sert.throws(function()
						sut.ctx:parse("local a = '" .. string.rep("q", 128) .. "'")
					end, "model checkpoint boom")
					sut.control.mode = "ok"
					return msg
				end,
				post = function(_: any, _: any, _: any, msg: string)
					sert.contains(msg, "model checkpoint boom")
				end,
			},
			{
				name = "suspendStart",
				pre = function(state: any)
					return not state.suspended
				end,
				run = function(sut: any)
					sut.control.mode = "ok"
					sut.control.shouldYield = true
					local src = "local paused = '" .. string.rep("p", 128) .. "'; return paused"
					sut.workerSource = src
					local co = coroutine.create(function()
						return sut.ctx:parse(src)
					end)
					sut.worker = co
					local ok, yielded = coroutine.resume(co)
					expect(ok, tostring(yielded))
					sert.eq(yielded, "paused")
					return coroutine.status(co)
				end,
				post = function(_: any, _: any, _: any, status: string)
					sert.eq(status, "suspended")
				end,
				next = function(state: any)
					state.suspended = true
				end,
			},
			{
				name = "whileSuspendedReenterAndPeer",
				pre = function(state: any)
					return state.suspended
				end,
				run = function(sut: any)
					sert.throws(function()
						sut.ctx:parse("return 0")
					end, "already in use")
					return sut.peer:parse("local peerVar = 9; return peerVar")
				end,
				post = function(_: any, _: any, _: any, peerResult: any)
					sert.eq(peerResult.status, "ok")
					sert.eq(peerResult.arena.symbols[peerResult.arena.bindings[1].name], "peerVar")
				end,
			},
			{
				name = "suspendResume",
				pre = function(state: any)
					return state.suspended
				end,
				run = function(sut: any)
					local co = sut.worker :: thread
					local ok, res = coroutine.resume(co)
					expect(ok, tostring(res))
					sut.worker = (nil :: any) :: thread?
					return { result = res, source = sut.workerSource }
				end,
				post = function(_: any, _: any, _: any, out: any)
					sert.eq(out.result.status, "ok")
					sert.eq(out.result:reconstruct(), out.source)
				end,
				next = function(state: any, _: any, out: any)
					state.suspended = false
					table.insert(state.retained, {
						result = out.result,
						source = out.source,
						status = "ok",
						nodeCount = #out.result.arena.nodes,
						symbolName = "paused",
					})
				end,
			},
		},
	}
end

describe("Lifecycle", function()
	test("traverses AST children and handles sentinel NodeId zero safely", function()
		local expression = valid("foo + 2 * 3", "expression")
		sert.eq(expression:kindName(expression.root), "AstExprBinary")
		sert.eq(type(expression:kind(expression.root)), "number")
		local a, b = expression:range(expression.root)
		sert.eq(a, 0)
		sert.eq(b, 11)
		sert.eq(expression:childCount(expression.root), 2)
		sert.eq(expression:kindName(expression:childAt(expression.root, 1)), "AstExprGlobal")
		sert.eq(expression:kindName(expression:childAt(expression.root, 2)), "AstExprBinary")
		sert.eq(expression:childAt(expression.root, 3), 0)
		sert.eq(expression:kind(0), 0)
		sert.eq(expression:kindName(0), "")
		local zStart, zFinish = expression:range(0)
		sert.eq(zStart, 0)
		sert.eq(zFinish, 0)
		sert.eq(expression:childCount(0), 0)
		sert.eq(expression:childAt(0, 1), 0)

		local localRefResult = valid("local x: number = 1; return x")
		local returnStat = localRefResult.arena:listAt(localRefResult.arena.nodes[localRefResult.root].body, 2)
		local returnRef = localRefResult:childAt(returnStat, 1)
		sert.eq(localRefResult:kindName(returnRef), "AstExprLocal")
		sert.eq(localRefResult:childCount(returnRef), 0)

		local methodCallResult = valid("t:f<<number, string>>(1)", "expression")
		sert.eq(methodCallResult:kindName(methodCallResult.root), "AstExprCall")
		sert.eq(methodCallResult:childCount(methodCallResult.root), 4)

		local tree = assert(Ast.toTables(expression))
		sert.eq(tree.type, "AstExprBinary")
		sert.eq(tree.op, "Add")
		sert.eq(tree.right.op, "Mul")
	end)

	test("traverses AST via zero-alloc visit(fn), visit({enter,leave}), depth, pruning, and forEachChild", function()
		local res = valid("local x: number = 1 + 2; if true then return x else return 0 end")
		assert((res :: any)._childCache == nil, "result must not allocate _childCache")

		-- visit(fn) receives (nodeId, kind, depth) in pre-order and allocates no _childCache
		local fnVisited: { { id: number, kind: number, depth: number } } = {}
		res:visit(function(id: number, kind: number, depth: number): boolean?
			table.insert(fnVisited, { id = id, kind = kind, depth = depth })
			return nil
		end)
		assert((res :: any)._childCache == nil, "visit(fn) must not allocate _childCache")
		sert.eq(fnVisited[1].id, res.root)
		sert.eq(fnVisited[1].kind, res:kind(res.root))
		sert.eq(fnVisited[1].depth, 0)
		expect(#fnVisited > 5, "visited full AST")

		-- visit({ enter, leave }) matches pre/post order and honors return false pruning
		local entered: { number } = {}
		local left: { number } = {}
		local prunedCount = 0
		res:visit({
			enter = function(id: number, _kind: number, depth: number): boolean?
				table.insert(entered, id)
				if res:kindName(id) == "AstStatIf" then
					prunedCount += 1
					expect(depth == 1, "AstStatIf is at depth 1")
					return false
				end
				return nil
			end,
			leave = function(id: number, _kind: number, _depth: number)
				table.insert(left, id)
			end,
		})
		sert.eq(prunedCount, 1)
		sert.eq(#entered, #left, "leave is called for every entered node including pruned nodes")
		expect(#entered < #fnVisited, "return false prunes subtree descendants")
		for _, id in entered do
			expect(res:kindName(id) ~= "AstStatReturn", "pruned if subtree returns were not visited")
		end

		-- leave-only visitor and root == 0 safety
		local leaveOnlyCount = 0
		res:visit({
			leave = function()
				leaveOnlyCount += 1
			end,
		})
		sert.eq(leaveOnlyCount, #fnVisited)

		local emptyRes: any = table.clone(res)
		emptyRes.root = 0
		local emptyCalls = 0
		emptyRes:visit(function()
			emptyCalls += 1
			return nil
		end)
		sert.eq(emptyCalls, 0)

		-- forEachChild honors early exit and handles >4 children without _childCache
		local bigTbl = valid("{1, 2, 3, 4, 5, 6, 7, 8}", "expression")
		sert.eq(bigTbl:childCount(bigTbl.root), 8)
		sert.eq(bigTbl:kindName(bigTbl:childAt(bigTbl.root, 7)), "AstExprConstantNumber")
		local seen = 0
		bigTbl:forEachChild(bigTbl.root, function(): boolean?
			seen += 1
			if seen == 3 then
				return false
			end
			return nil
		end)
		sert.eq(seen, 3, "forEachChild stops on return false")
		assert((bigTbl :: any)._childCache == nil, "childCount/childAt/forEachChild must not allocate _childCache")
	end)

	test("sets arena.hasTypeAnnotations and arena.hasClasses accurately across untyped and typed programs", function()
		local untyped = valid("local x = 1; local function f(y) return x + y end; return f(2)")
		sert.eq(untyped.arena.hasTypeAnnotations, false)
		sert.eq(untyped.arena.hasClasses, false)

		local typedCases = {
			{ src = "local x: number = 1", opts = nil },
			{ src = "local function f(x: number) return x end", opts = nil },
			{ src = "local function f(): number return 1 end", opts = nil },
			{ src = "type T = number", opts = nil },
			{ src = "type function f(t) return t end", opts = nil },
			{ src = "return f<<number>>()", opts = nil },
			{ src = "return o:m<<string>>()", opts = nil },
			{ src = "return x :: number", opts = nil },
			{ src = "declare x: number", opts = { allowDeclarationSyntax = true } },
			{ src = "declare function f(x: number): number", opts = { allowDeclarationSyntax = true } },
			{ src = "declare extern type Box with x: number end", opts = { allowDeclarationSyntax = true } },
		}
		for _, tc in typedCases do
			local r = valid(tc.src, nil, tc.opts :: any)
			sert.eq(r.arena.hasTypeAnnotations, true, "hasTypeAnnotations for: " .. tc.src)
			sert.eq(r.arena.hasClasses, false, "hasClasses false for: " .. tc.src)
		end

		local typeFrag = valid("number", "type")
		sert.eq(typeFrag.arena.hasTypeAnnotations, true)

		local clsEmpty = valid("class Box end", nil, { profile = "experimental" })
		sert.eq(clsEmpty.arena.hasClasses, true)
		sert.eq(clsEmpty.arena.hasTypeAnnotations, false)

		local clsTyped = valid("export open class Box public x: number end", nil, { profile = "experimental" })
		sert.eq(clsTyped.arena.hasClasses, true)
		sert.eq(clsTyped.arena.hasTypeAnnotations, true)
	end)

	test("enforces requireEOF on expression and type fragment entrypoints", function()
		for _, source in { "foo bar", "number string" } do
			local result =
				parseEntry(source, if source == "foo bar" then "expression" else "type", { requireEOF = true })
			sert.eq(result.status, "syntaxError")
		end
		sert.eq(Parser.parseExpression("foo bar").status, "ok")
		sert.eq(Parser.parseType("number string").status, "ok")
	end)

	test("converts byte offsets and line/column positions accurately, including past NUL", function()
		local nullTail = Parser.parse("x\0tail\nmore", { lossless = true })
		local nullLine, nullCol = nullTail:position(8)
		sert.eq(nullLine, 1)
		sert.eq(nullCol, 1)

		local bytes = "--!strict\r\nlocal x='é'\r\nreturn x\n"
		local document = valid(bytes, nil, { lossless = true })
		sert.eq(document:reconstruct(), bytes)
		for index = 1, #bytes + 1 do
			local offset = index - 1
			local line, column = document:position(offset)
			local expectedLine, expectedColumn = 0, offset
			for p = 1, offset do
				if string.byte(bytes, p) == 10 then
					expectedLine += 1
					expectedColumn = offset - p
				end
			end
			sert.eq(line, expectedLine)
			sert.eq(column, expectedColumn)
			sert.eq(document:offset(line, column), offset)
		end
		sert.eq(document.hotcomments[1].content, "strict")
		sert.eq(document.hotcomments[1].header, true)

		sert.throws(function()
			document:position(#bytes + 1)
		end, "offset outside source")
		sert.throws(function()
			document:position(0.5)
		end, "offset outside source")

		local boundary = Parser.parse("a()\nb()")
		sert.throws(function()
			boundary:offset(0, 4)
		end, "column outside line")
		sert.throws(function()
			boundary:offset(0.5, 0)
		end, "line must be an integer")
		sert.throws(function()
			boundary:offset(0, 0.5)
		end, "column must be an integer")
		sert.eq(boundary:offset(0, 3), 3)
		sert.eq(boundary:offset(1, 0), 4)

		sert.throws(function()
			document:childAt(document.root, 0)
		end, "child index must be positive")
		sert.throws(function()
			document:childAt(document.root, 1.5)
		end, "child index must be positive")
		sert.eq(Diagnostics.location({ 0, 5 }, 1, 8), "0,1 - 1,3")
	end)

	test("binds declaration initializers after evaluating RHS and restores nested scopes", function()
		local bindingResult =
			valid("local x=1; do local x=x; f(x) end; local f=function(x) return function() return x end end")
		local outer = bindingResult.arena:listAt(stat(bindingResult, 1).vars, 1)
		local block = stat(bindingResult, 2)
		local innerStat = bindingResult.arena.nodes[bindingResult.arena:listAt(block.body, 1)]
		local inner = bindingResult.arena:listAt(innerStat.vars, 1)
		local rhs = bindingResult.arena.nodes[bindingResult.arena:listAt(innerStat.values, 1)]
		sert.eq(rhs["local"], outer)
		sert.eq(bindingResult.arena.bindings[inner].shadow, outer)
		sert.eq(bindingResult.arena.bindings[outer].scopeDepth, 1)
		sert.eq(bindingResult.arena.bindings[inner].scopeDepth, 2)
		local fn = bindingResult.arena.nodes[bindingResult.arena:listAt(stat(bindingResult, 3).values, 1)]
		local parameter = bindingResult.arena:listAt(fn.args, 1)
		local fnBody = bindingResult.arena.nodes[fn.body]
		local returned = bindingResult.arena.nodes[bindingResult.arena:listAt(fnBody.body, 1)]
		local closure = bindingResult.arena.nodes[bindingResult.arena:listAt(returned.list, 1)]
		local closureBody = bindingResult.arena.nodes[closure.body]
		local closureReturn = bindingResult.arena.nodes[bindingResult.arena:listAt(closureBody.body, 1)]
		local captured = bindingResult.arena.nodes[bindingResult.arena:listAt(closureReturn.list, 1)]
		sert.eq(captured["local"], parameter)
		sert.eq(captured.upvalue, true)
	end)

	test("isolates retained arenas across 100 context parses and caps >256 KiB scratch retention", function()
		local context = Parser.newContext({ lossless = true })
		local retained = {}
		for i = 1, 100 do
			local source = `local name{i}={i}; return name{i}`
			retained[i] = { result = context:parse(source), source = source }
		end
		for i, item in retained do
			local result = item.result
			sert.eq(result.status, "ok")
			sert.eq(result:reconstruct(), item.source)
			sert.eq(result.arena.symbols[result.arena.bindings[1].name], `name{i}`)
			if i > 1 then
				sert.eq(result.arena == retained[i - 1].result.arena, false)
				sert.eq(result.arena.nodes == retained[i - 1].result.arena.nodes, false)
			end
		end

		local large = context:parse(string.rep("local x=1; f(x); ", 20000))
		sert.eq(large.status, "ok")
		local largeNodes = #large.arena.nodes
		expect(#large.source > 262144, "exceeds 256 KiB scratch threshold")

		local small = context:parse("return 1")
		sert.eq(small.status, "ok")
		sert.eq(#large.arena.nodes, largeNodes)
		expect(#small.arena.nodes < 10, "small parse arena stays small")

		local exprFrag = context:parseExpression("1+2")
		sert.eq(exprFrag:kindName(exprFrag.root), "AstExprBinary")
		local typeFrag = context:parseType("number")
		sert.eq(typeFrag:kindName(typeFrag.root), "AstTypeReference")
	end)

	test("rejects reentrant use of a suspended context while allowing independent contexts", function()
		local reentrantRejected = false
		local yieldingContext: any
		local callbacks = 0
		yieldingContext = Parser.newContext({
			lossless = true,
			checkpointInterval = 64,
			checkpoint = function()
				callbacks += 1
				if not reentrantRejected then
					sert.throws(function()
						yieldingContext:parse("return 0")
					end, "already in use")
					reentrantRejected = true
				end
				coroutine.yield()
				return true
			end,
		})
		local yieldedResult: any
		local worker = coroutine.create(function()
			yieldedResult = yieldingContext:parse(string.rep("local x=1; f(x); ", 100))
		end)
		while coroutine.status(worker) ~= "dead" do
			local ok, err = coroutine.resume(worker)
			expect(ok, tostring(err))
			local other = Parser.newContext():parse("local other=3; return other")
			sert.eq(other.status, "ok")
			sert.eq(other.arena.symbols[other.arena.bindings[1].name], "other")
		end
		sert.eq(yieldedResult.status, "ok")
		sert.eq((yieldingContext :: any).busy, false)
		expect(callbacks > 1, `checkpoint invoked {callbacks} times`)
	end)

	test("handles cancellation, checkpoint exceptions, unparsed tail positions, and option snapshotting", function()
		local cancel = true
		local cancellable = Parser.newContext({
			lossless = true,
			checkpointInterval = 32,
			checkpoint = function()
				return not cancel
			end,
		})
		local cancelledSource = "local x='" .. string.rep("a", 1000) .. "'\nreturn x\n--tail\n"
		local cancelled = cancellable:parse(cancelledSource)
		sert.eq(cancelled.status, "cancelled")
		sert.eq(cancelled.root, 0)
		sert.eq(cancelled:reconstruct(), cancelledSource)
		sert.eq((cancellable :: any).busy, false)
		cancel = false
		sert.eq(cancellable:parse("return 1").status, "ok")

		local brokenContext = Parser.newContext({
			checkpointInterval = 1,
			checkpoint = function()
				error("user checkpoint failure", 0)
			end,
		})
		sert.throws(function()
			brokenContext:parse("local x=1")
		end, "user checkpoint failure")
		sert.eq((brokenContext :: any).busy, false)

		local finalLine, finalColumn = cancelled:position(#cancelledSource)
		sert.eq(finalLine, 3)
		sert.eq(finalColumn, 0)

		local flags: Parser.GrammarFlags = { LuauExperimentalWhileLocalSyntax = true }
		local stable = Parser.newContext({ profile = flags })
		flags.LuauExperimentalWhileLocalSyntax = false
		local whileLocal = stable:parse("while local x = f() do end")
		sert.eq(whileLocal.status, "ok")
		local statId = whileLocal.arena:listAt(whileLocal.arena.nodes[whileLocal.root].body, 1)
		sert.eq(whileLocal:kindName(statId), "AstStatWhile")
		assert(whileLocal.arena.nodes[statId].conditionLocal ~= 0, "expected conditionLocal binding")
	end)

	test.each({
		{
			name = "expression recursionLimit",
			source = string.rep("(", 100) .. "1" .. string.rep(")", 100),
			entry = "expression",
			options = { recursionLimit = 16, lossless = true },
		},
		{
			name = "chunk recursionLimit",
			source = string.rep("do ", 100) .. "x() " .. string.rep("end ", 100),
			options = { recursionLimit = 16, lossless = true },
		},
		{
			name = "typeLengthLimit",
			source = "a | b | c | d | e",
			entry = "type",
			options = { typeLengthLimit = 2, lossless = true },
		},
		{
			name = "errorLimit",
			source = string.rep("local = ; ", 100),
			options = { errorLimit = 4, lossless = true },
		},
	})("fatal limit enforcement", function(case)
		local limited = parseEntry(case.source, case.entry, case.options)
		sert.eq(limited.status, "limit")
		sert.eq(limited.root, 0)
		sert.eq(limited:reconstruct(), case.source)
		expect(#limited.diagnostics > 0, "reports limit diagnostic")
	end)

	test("survives deeply nested and malformed inputs without stack overflow", function()
		for _, source in
			{
				"return '\\256'",
				"local x=",
				"--[[",
				"`{{bad}}`",
				"x\0tail\nmore",
				string.rep("(", 3000),
				string.rep("{", 3000),
			}
		do
			local result = Parser.parse(source, { lossless = true, recursionLimit = 64, errorLimit = 8 })
			sert.eq(result:reconstruct(), source)
		end

		for _, source in
			{
				string.rep("(", 1200) .. "1" .. string.rep(")", 1200),
				string.rep("not ", 1200) .. "true",
				"1" .. string.rep("^1", 1200),
			}
		do
			local result = Parser.parseExpression(source, { lossless = true })
			sert.eq(result.status, "limit")
			sert.eq(result:reconstruct(), source)
		end

		local deepType = string.rep("{x:", 1200) .. "number" .. string.rep("}", 1200)
		local result = Parser.parseType(deepType, { lossless = true })
		sert.eq(result.status, "limit")
		sert.eq(result:reconstruct(), deepType)
	end)

	prop("position and offset form a bijection across arbitrary line endings and NUL tails", function(g: any)
		local lines: { string } = g:draw(
			gen.list(gen.pick({ "local x = 1", "-- comment", "return 'é'", "a\rb", "x\0y", "", "  \t  " }), 1, 12)
		)
		local sep: string = g:draw(gen.pick({ "\n", "\r\n" }))
		local source = table.concat(lines, sep)
		local result = Parser.parse(source, { lossless = true })
		sert.eq(result:reconstruct(), source)
		for index = 1, #source + 1 do
			local offset = index - 1
			local line, col = result:position(offset)
			sert.eq(result:offset(line, col), offset, `bijection at byte offset {offset}`)
		end
	end, { runs = 100 })

	model("stateful ParserContext lifecycle preserves retained results across interleavings", contextModelSpec(), {
		runs = 60,
		length = 20,
		redraw = true,
	})

	test("replays pinned multi-step ParserContext suspension, cancellation, and error scenario", function()
		local state = model.replay(contextModelSpec(), {
			{ "parseSmall", 1 },
			{ "parseFragments" },
			{ "suspendStart" },
			{ "whileSuspendedReenterAndPeer" },
			{ "suspendResume" },
			{ "parseCancelled" },
			{ "checkpointThrow" },
			{ "parseLimit" },
			{ "parseSyntaxError", "local x =" },
			{ "parseSmall", 2 },
		})
		sert.eq(state.suspended, false)
		sert.eq(#state.retained, 8)
	end)

	test(
		"keeps arena.symbols free of reserved keywords, recycles full context scratch on reset(), and preserves embedded NUL lossless tapes",
		function()
			local fresh = valid(
				"if true and not false then local alpha = nil; for idx = 1, 2 do while false do repeat break until true end end return alpha end"
			)
			sert.eq(#fresh.arena.symbols, 2, "only user identifiers enter arena.symbols")
			sert.eq(fresh.arena.symbols[1], "alpha")
			sert.eq(fresh.arena.symbols[2], "idx")
			local freshMap = (fresh.arena :: any).symbolMap
			expect(type(freshMap) == "table", "fresh parse attaches arena.symbolMap")
			sert.eq(freshMap.alpha, 1)
			sert.eq(freshMap.idx, 2)
			sert.eq(freshMap["local"], nil)
			sert.eq(freshMap["function"], nil)

			local shouldYield = true
			local ctx: any = Parser.newContext({
				lossless = true,
				profile = "experimental",
				checkpointInterval = 16,
				checkpoint = function()
					if shouldYield then
						coroutine.yield("hold")
					end
					return true
				end,
			})
			local abandoned = coroutine.create(function()
				return ctx:parse("export local held = `" .. string.rep("x", 64) .. "{1}`; class Box end")
			end)
			local ok, yielded = coroutine.resume(abandoned)
			expect(ok, tostring(yielded))
			sert.eq(yielded, "hold")
			sert.eq(ctx.busy, true, "ctx.busy is true while coroutine is suspended")
			sert.throws(function()
				ctx:parse("return 1")
			end, "already in use")

			-- Explicitly reset without resuming the abandoned coroutine and verify zero scratch bleed.
			ctx:reset()
			sert.eq(ctx.busy, false, "ctx:reset() clears busy flag")
			shouldYield = false
			local afterReset =
				ctx:parse("export local held = `ok{1 + 2}`\nclass Box\n\tfunction __init(self)\n\tend\nend\n")
			sert.eq(afterReset.status, "ok")
			sert.eq((afterReset.arena :: any).symbolMap, nil, "context parse does not retain shared symbolMap on arena")
			sert.eq(afterReset:reconstruct(), afterReset.source)

			for _, nulSrc in
				{
					"local x = 1 -- trailing\0hidden\nlocal y = 2",
					"local s = [[unterminated\0]]\nreturn s",
					"local q = 'unterminated\0'\nreturn q",
					"--[=[block\0]=]\nreturn 1",
				}
			do
				local r1 = Parser.parse(nulSrc, { lossless = true })
				local r2 = ctx:parse(nulSrc)
				sert.eq(r1:reconstruct(), nulSrc)
				sert.eq(r2:reconstruct(), nulSrc)
				sert.eq(r1.status, r2.status)
				sert.eq(#r1.diagnostics, #r2.diagnostics)
			end
		end
	)

	test(
		"passes numeric offset to checkpoint, snapshots public ParserContext.options, and rejects invalid ParseOptions",
		function()
			local offsets: { number } = {}
			local src = "local x = 1\n" .. string.rep("x += 1\n", 150)
			local res = Parser.parse(src, {
				checkpointInterval = 64,
				checkpoint = function(offset: number)
					sert.eq(type(offset), "number")
					table.insert(offsets, offset)
					return true
				end,
			})
			sert.eq(res.status, "ok")
			expect(#offsets >= 1, "checkpoint invoked with numeric offset")

			local flagInput: Parser.GrammarFlags = { LuauExperimentalWhileLocalSyntax = true }
			local roundTripCtx = Parser.newContext({
				lossless = true,
				recursionLimit = 32,
				profile = flagInput,
			})
			flagInput.LuauExperimentalWhileLocalSyntax = false
			local pubOpts: any = roundTripCtx.options
			sert.eq(table.isfrozen(pubOpts), true)
			sert.eq(pubOpts.lossless, true)
			sert.eq(pubOpts.captureComments, true)
			sert.eq(pubOpts.allowDeclarationSyntax, false)
			sert.eq(pubOpts.recursionLimit, 32)
			sert.eq(pubOpts.flags, nil)
			sert.eq(pubOpts.skipComments, nil)
			sert.eq(pubOpts.profile.LuauExperimentalWhileLocalSyntax, true)

			for _, badOpts in
				{
					{ unknownKey = true },
					{ skipComments = true },
					{ flags = { LuauExperimentalWhileLocalSyntax = true } },
				} :: { any }
			do
				sert.throws(function()
					Parser.parse("return 1", badOpts)
				end, "Unknown parse option")
			end

			local badValues: { { opts: any, match: string } } = {
				{ opts = 123, match = "parse options must be a table" },
				{ opts = { lossless = "yes" }, match = "lossless must be a boolean" },
				{ opts = { recursionLimit = 0 }, match = "recursionLimit must be a finite positive integer" },
				{ opts = { recursionLimit = 1.5 }, match = "recursionLimit must be a finite positive integer" },
				{ opts = { typeLengthLimit = 0 / 0 }, match = "typeLengthLimit must be a finite positive integer" },
				{ opts = { checkpoint = "nope" }, match = "checkpoint must be a function" },
			}
			for _, tc in badValues do
				sert.throws(function()
					Parser.parse("return 1", tc.opts)
				end, tc.match)
			end

			sert.throws(function()
				Parser.parse(123 :: any)
			end, "string")
			sert.throws(function()
				Parser.parseExpression(123 :: any)
			end, "string")
			sert.throws(function()
				Parser.parseType(123 :: any)
			end, "string")

			local pr = Parser.parse("return 1")
			sert.throws(function()
				pr:forEachChild("bad" :: any, function()
					return true
				end)
			end)
			sert.throws(function()
				pr:forEachChild(pr.root, "bad" :: any)
			end)
			sert.throws(function()
				pr:visit(123 :: any)
			end)
			sert.throws(function()
				pr:visit({ unknownVisitor = function() end } :: any)
			end, "Unknown AstVisitor key")
			sert.throws(function()
				pr:visit({ enter = "nope" } :: any)
			end, "enter must be a function")
			sert.throws(function()
				pr:visit({ leave = "nope" } :: any)
			end, "leave must be a function")
			sert.throws(function()
				Ast.toTables(123 :: any)
			end)
			sert.throws(function()
				Ast.toTables({} :: any)
			end)

			local itemPr = Parser.parse(
				"local t = { a = 1, [2] = 3, 4 }; local x: number = 1; local function f(self, y: string) return y end"
			)
			local sawVisit = 0
			itemPr:visit(function(nid)
				sawVisit += 1
				itemPr:forEachChild(nid, function()
					return false
				end)
				return true
			end)
			expect(sawVisit > 5, "expected table items and bindings visited")
		end
	)
end)

if not sert._bundled then
	return sert.run(sert.parseCliArgs(...))
end
return nil
