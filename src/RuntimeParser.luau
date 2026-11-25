--!strict
-- Derived from Luau 0.748 Parser.cpp, Copyright (c) 2019-2026 Roblox Corporation.
-- MIT license. See ../LICENSE.md. Modified: native Luau arena and byte ranges.
local T = require("./Token")
local Arena = require("./Arena")
local State = require("./State")
local K = Arena.Kinds
local advance = State.advance
local nodeAdd = State.node
local expect = State.expect
local expectClose = State.expectClose
local expectName = State.expectName
local commitList = State.commitList
local bindLocal = State.bind
local restoreScope = State.restore
local sameLine = State.sameLine
local recoveryPush = State.recoveryPush
local recoveryPop = State.recoveryPop
local arenaList1 = Arena.list1
local arenaList = Arena.list
local readu8 = buffer.readu8
local RESERVED_ELSE = T.ReservedElse
local RESERVED_ELSEIF = T.ReservedElseif
local RESERVED_END = T.ReservedEnd
local RESERVED_UNTIL = T.ReservedUntil
local Runtime = {}
local expression: any
local block: any
local statement: any
local primary: any
local simple: any
local functionBody: any
local attributes: any
local ifExpression: any
local ifStatement: any
local exportValue: any

local binaryOp: { [number]: string } = {
	[43] = "Add",
	[45] = "Sub",
	[42] = "Mul",
	[47] = "Div",
	[T.FloorDiv] = "FloorDiv",
	[37] = "Mod",
	[94] = "Pow",
	[T.Dot2] = "Concat",
	[T.NotEqual] = "CompareNe",
	[T.Equal] = "CompareEq",
	[60] = "CompareLt",
	[T.LessEqual] = "CompareLe",
	[62] = "CompareGt",
	[T.GreaterEqual] = "CompareGe",
	[T.ReservedAnd] = "And",
	[T.ReservedOr] = "Or",
}
local BINARY_LEFT = buffer.create(320)
local BINARY_RIGHT = buffer.create(320)
local PRIMARY_SUFFIX = buffer.create(320)
for _, tok in { 46, 58, 91, 40, 123, T.QuotedString, T.RawString, 60 } do
	buffer.writeu8(PRIMARY_SUFFIX, tok, 1)
end
for tok, precs in
	{
		[43] = { 6, 6 },
		[45] = { 6, 6 },
		[42] = { 7, 7 },
		[47] = { 7, 7 },
		[T.FloorDiv] = { 7, 7 },
		[37] = { 7, 7 },
		[94] = { 10, 9 },
		[T.Dot2] = { 5, 4 },
		[T.NotEqual] = { 3, 3 },
		[T.Equal] = { 3, 3 },
		[60] = { 3, 3 },
		[T.LessEqual] = { 3, 3 },
		[62] = { 3, 3 },
		[T.GreaterEqual] = { 3, 3 },
		[T.ReservedAnd] = { 2, 2 },
		[T.ReservedOr] = { 1, 1 },
	}
do
	buffer.writeu8(BINARY_LEFT, tok, precs[1])
	buffer.writeu8(BINARY_RIGHT, tok, precs[2])
end
table.freeze(binaryOp)
local compound = table.freeze({
	[T.AddAssign] = "Add",
	[T.SubAssign] = "Sub",
	[T.MulAssign] = "Mul",
	[T.DivAssign] = "Div",
	[T.FloorDivAssign] = "FloorDiv",
	[T.ModAssign] = "Mod",
	[T.PowAssign] = "Pow",
	[T.ConcatAssign] = "Concat",
})
local ZERO_LOCATION = table.freeze({ start = 0, finish = 0 })
local function currentLocation(s: any): any
	return { start = s.start, finish = s.finish }
end
local function exprError(s: any, start: number, finish: number, message: string, children: { number }?): number
	s:report(start, finish, message)
	return nodeAdd(s, {
		kind = K.AstExprError,
		start = start,
		finish = finish,
		expressions = if children then arenaList(s.arena, children) else 0,
		messageIndex = math.max(0, #s.diagnostics - 1),
	})
end
local function statError(
	s: any,
	start: number,
	finish: number,
	message: string,
	exprs: { number }?,
	stats: { number }?
): number
	s:report(start, finish, message)
	return nodeAdd(s, {
		kind = K.AstStatError,
		start = start,
		finish = finish,
		expressions = if exprs then arenaList(s.arena, exprs) else 0,
		statements = if stats then arenaList(s.arena, stats) else 0,
		messageIndex = math.max(0, #s.diagnostics - 1),
	})
end
@native
local function exprList(s: any): (number, number, number)
	local first = expression(s)
	if s.kind ~= 44 then
		return arenaList1(s.arena, first), 1, first
	end
	local base: number = s.listTop
	local listScratch = s.listScratch
	local top: number = base + 1
	listScratch[top] = first
	s.listTop = top
	local last = first
	local count = 1
	while s.kind == 44 do
		advance(s)
		if s.kind == 41 then
			s:report(s.start, s.finish, "Expected expression after ',' but got ')' instead")
			break
		end
		last = expression(s)
		top += 1
		listScratch[top] = last
		s.listTop = top
		count += 1
	end
	return commitList(s, base), count, last
end
@native
local function binding(s: any, isConst: boolean?): (number, number, number, number, boolean)
	local tokenFinish: number = s.finish
	local missing = s.kind ~= T.Name
	local name: number, start: number, finish: number = expectName(s, "variable name")
	if missing then
		finish = tokenFinish
	end
	local annotation = 0
	if s.kind == 58 then
		advance(s)
		annotation = s.parseType(s)
	end
	return name, start, finish, annotation, isConst == true
end
@native
local function nameExpr(s: any, context: string?): number
	local start: number, finish: number = s.start, s.finish
	if s.kind ~= T.Name then
		return exprError(
			s,
			start,
			finish,
			"Expected identifier when parsing " .. (context or "expression") .. ", got " .. s:tokenName()
		)
	end
	local symbol: number = s.symbol
	advance(s)
	local localId: number? = s.locals[symbol]
	if localId and localId ~= 0 then
		local localRecord = s.bindings[localId]
		if s.typeFunctionDepth > 0 and localRecord.functionDepth < s.typeFunctionDepth then
			return exprError(
				s,
				start,
				finish,
				"Type function cannot reference outer local '" .. s.arena.symbols[symbol] .. "'"
			)
		end
		return nodeAdd(s, {
			kind = K.AstExprLocal,
			start = start,
			finish = finish,
			["local"] = localId,
			upvalue = localRecord.functionDepth ~= s.functionDepth,
		})
	end
	return nodeAdd(s, { kind = K.AstExprGlobal, start = start, finish = finish, name = symbol })
end
local function indexName(s: any, context: string?, opPosition: number): (number, number, number)
	if s.kind == T.Name then
		return expectName(s, context)
	end
	local start, finish, value, token = s.start, s.finish, s.value, s.kind
	s:report(
		start,
		finish,
		"Expected identifier" .. (if context then " when parsing " .. context else "") .. ", got " .. s:tokenName()
	)
	if token >= T.Reserved_BEGIN and token < T.Reserved_END then
		-- Recover reserved words on the same line as the indexing operator.
		if s:sameLine(opPosition, start) then
			advance(s)
			return s:symbolFor(value), start, finish
		end
	end
	return s:symbolFor("%error-id%"), start, start
end
@native
local function lvalue(s: any, id: number, forceConstMsg: boolean?): number
	local n = s.nodes[id]
	local k: number = n.kind
	if k == K.AstExprLocal and s.bindings[n["local"]].isConst then
		if not forceConstMsg and not s.hasExportValue then
			return exprError(s, n.start, n.finish, "Assigned expression must be a variable or a field", { id })
		end
		return exprError(
			s,
			n.start,
			n.finish,
			"Variable '" .. s.arena.symbols[s.bindings[n["local"]].name] .. "' is constant and may not be reassigned",
			{ id }
		)
	end
	if k == K.AstExprLocal or k == K.AstExprGlobal or k == K.AstExprIndexName or k == K.AstExprIndexExpr then
		return id
	end
	return exprError(s, n.start, n.finish, "Assigned expression must be a variable or a field", { id })
end
local function isPrivateFieldName(name: string?): boolean
	if not name then
		return false
	end
	local b1, b2 = string.byte(name, 1, 2)
	return b1 == 95 and b2 ~= 95
end
local function stringExpr(s: any): number
	local start: number, finish: number, value = s.start, s.finish, s.value
	advance(s)
	if value == nil then
		return exprError(s, start, finish, "String literal contains malformed escape sequence")
	end
	return nodeAdd(s, {
		kind = K.AstExprConstantString,
		start = start,
		finish = finish,
		value = value,
	})
end
@native
local function call(s: any, func: number, selfCall: boolean, typeArguments: number?): number
	local start: number = s.starts[func]
	local fnFinish: number = s.finishes[func]
	local argsList = 0
	local argStart: number, argFinish: number = s.start, s.finish
	local callOpen: number = s.start
	local tableCall = false
	if s.kind == 40 then
		if not sameLine(s, fnFinish, s.start) then
			s:report(
				s.start,
				s.finish,
				"Ambiguous syntax: this looks like an argument list for a function call, but could also be a start of new statement; use ';' to separate statements"
			)
		end
		argStart = s.finish
		advance(s)
		if s.kind ~= 41 then
			argsList = exprList(s)
		end
		argFinish = s.finish
		expectClose(s, 41, 40, callOpen)
	elseif s.kind == 123 then
		tableCall = true
		argStart = s.finish
		local arg = simple(s)
		argsList = arenaList1(s.arena, arg)
		argFinish = s.finishes[arg]
	elseif s.kind == T.QuotedString or s.kind == T.RawString then
		argsList = arenaList1(s.arena, stringExpr(s))
	else
		if selfCall and not sameLine(s, fnFinish, s.start) then
			return exprError(s, start, fnFinish, "Expected function call arguments after '('", { func })
		end
		return exprError(
			s,
			start,
			s.start,
			"Expected '(', '{' or <string> when parsing function call, got " .. s:tokenName(),
			{ func }
		)
	end
	return nodeAdd(s, {
		kind = K.AstExprCall,
		start = start,
		finish = argFinish,
		func = func,
		args = argsList,
		self = selfCall,
		tableCall = tableCall,
		typeArguments = typeArguments or 0,
		argStart = argStart,
		argFinish = argFinish,
	})
end
local function instantiation(s: any): number
	local start: number = s.start
	expect(s, 60, "type instantiation")
	local types = s.parseTypeParams(s)
	expectClose(s, 62, 60, start)
	return types
end
@native
function primary(s: any, asStatement: boolean?): number
	local start: number = s.start
	local result: number
	if s.kind == 40 then
		advance(s)
		local inner = expression(s)
		local finish: number = s.finish
		local hint = s.kind == 61
		local errorStart: number = s.start
		if not expectClose(s, 41, 40, start) then
			finish = s.previousFinish
		end
		if hint then
			local diagnostic = s.diagnostics[#s.diagnostics]
			if diagnostic and diagnostic.start == errorStart then
				diagnostic.message ..= "; did you mean to use '{' when defining a table?"
			end
		end
		result = nodeAdd(s, { kind = K.AstExprGroup, start = start, finish = finish, expr = inner })
	else
		result = nameExpr(s)
	end
	local k0: number = s.kind
	if k0 < 320 and readu8(PRIMARY_SUFFIX, k0) == 0 then
		return result
	end
	local chainDepth = 0
	while true do
		local k: number = s.kind
		if k == 46 or k == 58 then
			local op: number = k
			local opPosition: number = s.start
			advance(s)
			local index, indexStart, indexFinish = indexName(s, if op == 58 then "method name" else nil, opPosition)
			local isPrivate = s.inClassMethodBody == true and isPrivateFieldName(s.arena.symbols[index])
			result = nodeAdd(s, {
				kind = K.AstExprIndexName,
				start = start,
				finish = indexFinish,
				expr = result,
				index = index,
				indexStart = indexStart,
				indexFinish = indexFinish,
				op = if op == 58 then ":" else ".",
				privateAccess = isPrivate,
			})
			if op == 58 then
				local types = 0
				if s.kind == 60 and s:peek() == 60 then
					types = instantiation(s)
				end
				result = call(s, result, true, types)
			end
		elseif k == 91 then
			local bracketStart: number = s.start
			advance(s)
			local index = expression(s)
			local finish: number = s.finish
			expectClose(s, 93, 91, bracketStart)
			result =
				nodeAdd(s, { kind = K.AstExprIndexExpr, start = start, finish = finish, expr = result, index = index })
		elseif k == 40 or k == 123 or k == T.QuotedString or k == T.RawString then
			if k == 40 and not asStatement and not sameLine(s, s.finishes[result], s.start) then
				s:report(
					s.start,
					s.finish,
					"Ambiguous syntax: this looks like an argument list for a function call, but could also be a start of new statement; use ';' to separate statements"
				)
				break
			end
			result = call(s, result, false)
		elseif k == 60 and s:peek() == 60 then
			local types = instantiation(s)
			result = nodeAdd(s, {
				kind = K.AstExprInstantiate,
				start = start,
				finish = s.previousFinish,
				expr = result,
				typeArguments = types,
			})
		else
			break
		end
		chainDepth += 1
		local depth: number = s.depth + 1
		s.depth = depth
		if depth > s.recursionLimit then
			s:raiseRecursion("expression")
		end
	end
	s.depth -= chainDepth
	return result
end
@native
local function tableConstructor(s: any): number
	local start: number = s.start
	advance(s)
	local base: number = s.listTop
	local listScratch = s.listScratch
	while s.kind ~= 125 and s.kind ~= T.Eof do
		local before: number = s.start
		local key: number, value: number, itemKind: string
		if s.kind == 91 then
			local bracketStart: number = s.start
			advance(s)
			key = expression(s)
			expectClose(s, 93, 91, bracketStart)
			expect(s, 61, "table field")
			value = expression(s)
			itemKind = "General"
		elseif s.kind == T.Name and s:peek() == 61 then
			local symbol, keyName, nameStart, nameFinish = s.symbol, s.value, s.start, s.finish
			advance(s)
			advance(s)
			key = nodeAdd(s, {
				kind = K.AstExprConstantString,
				start = nameStart,
				finish = nameFinish,
				value = keyName,
			})
			value = expression(s)
			itemKind = "Record"
			local valNode = s.nodes[value]
			if valNode.kind == K.AstExprFunction then
				valNode.debugname = symbol
			end
		else
			key = 0
			value = expression(s)
			itemKind = "List"
		end
		local top: number = s.listTop + 1
		s.listTop = top
		listScratch[top] = { kind = itemKind, key = key, value = value }
		if s.kind == 44 or s.kind == 59 then
			advance(s)
		elseif s.kind == T.Name or s.kind == 91 then
			s:report(s.start, s.finish, "Expected ',' after table constructor element")
		else
			break
		end
		if s.start == before then
			break
		end
	end
	local itemsList = commitList(s, base)
	local finish: number = s.finish
	if not expectClose(s, 125, 123, start) then
		finish = s.previousFinish
	end
	return nodeAdd(s, { kind = K.AstExprTable, start = start, finish = finish, items = itemsList })
end
local function interpString(s: any): number
	local start = s.start
	local strBase = s:beginAux()
	local exprBase = s:beginList()
	local segmentStart, finish = s.start, s.finish
	while true do
		local token = s.kind
		segmentStart, finish = s.start, s.finish
		if s.value == nil then
			s:advance()
			s.auxTop = strBase
			s.listTop = exprBase
			return exprError(s, start, finish, "Interpolated string literal contains malformed escape sequence")
		end
		s:pushAux(s.value)
		s:advance()
		if token == T.InterpStringEnd or token == T.InterpStringSimple then
			break
		end
		if s.kind == T.InterpStringMid or s.kind == T.InterpStringEnd then
			s:advance()
			s:pushList(
				exprError(s, segmentStart, finish, "Malformed interpolated string, expected expression inside '{}'")
			)
			break
		elseif s.kind == T.BrokenString then
			s:advance()
			s:pushList(
				exprError(s, segmentStart, finish, "Malformed interpolated string; did you forget to add a '`'?")
			)
			break
		else
			s:pushList(expression(s))
		end
		if s.kind == T.BrokenInterpDoubleBrace then
			s:advance()
			s.auxTop = strBase
			s.listTop = exprBase
			return exprError(
				s,
				segmentStart,
				finish,
				"Double braces are not permitted within interpolated strings; did you mean '\\{'?"
			)
		elseif s.kind == T.BrokenString or s.kind == T.Eof then
			if s.kind == T.BrokenString then
				s:advance()
			end
			finish = s.previousFinish
			local brace = s.lexer.braces[#s.lexer.braces]
			if brace ~= false then
				s:report(
					s.previousStart,
					s.previousFinish,
					if brace == true
						then "Malformed interpolated string; did you forget to add a '}'?"
						else "Malformed interpolated string; did you forget to add a '`'?"
				)
			end
			break
		elseif s.kind ~= T.InterpStringBegin and s.kind ~= T.InterpStringMid and s.kind ~= T.InterpStringEnd then
			s.auxTop = strBase
			s.listTop = exprBase
			return exprError(s, segmentStart, finish, "Malformed interpolated string, got " .. s:tokenName())
		end
	end
	local stringsList = s:commitAux(strBase)
	local exprsList = s:commitList(exprBase)
	return s:node({
		kind = K.AstExprInterpString,
		start = start,
		finish = finish,
		strings = stringsList,
		expressions = exprsList,
	})
end
@native
local function numberExpr(s: any): number
	local start: number, finish: number, value = s.start, s.finish, s.value
	local parseResult = if s.lexer.hasExtra then s.lexer.numberParseResult else "Ok"
	advance(s)
	if value == nil then
		return exprError(s, start, finish, "Malformed number")
	end
	if parseResult == "Ok" or parseResult == nil then
		return nodeAdd(s, {
			kind = K.AstExprConstantNumber,
			start = start,
			finish = finish,
			value = value,
		})
	end
	return nodeAdd(s, {
		kind = K.AstExprConstantNumber,
		start = start,
		finish = finish,
		value = value,
		parseResult = parseResult,
	})
end
local function conditionBinding(s: any): (boolean, number, number, number, number, boolean)
	if
		s.profile.LuauExperimentalIfLocalSyntax
		and (s.kind == T.ReservedLocal or (s:isName("const") and s:peek() == T.Name))
	then
		local isConst = s:isName("const")
		advance(s)
		local bName, bStart, bFinish, bAnn, bConst = binding(s, isConst)
		if s.kind == 44 then
			s:report(
				s.start,
				s.finish,
				"Expected '=' after variable name in 'if local', got ','; only a single binding is allowed"
			)
		end
		expect(s, 61, "if local declaration")
		return true, bName, bStart, bFinish, bAnn, bConst
	end
	return false, 0, 0, 0, 0, false
end
function ifExpression(s: any): number
	local start = s.start
	advance(s)
	local hasBinding, bName, bStart, bFinish, bAnn, bConst = conditionBinding(s)
	local condition = expression(s)
	local hasThen = expect(s, T.ReservedThen, "if then else expression")
	local mark = s.localTop
	local conditionLocal = if hasBinding then bindLocal(s, bName, bStart, bFinish, bAnn, bConst) else 0
	local trueExpr = expression(s)
	if s.localTop > mark then
		restoreScope(s, mark)
	end
	local hasElse = s.kind == T.ReservedElse or s.kind == T.ReservedElseif
	local falseExpr
	if s.kind == T.ReservedElseif then
		local depth = s.depth + 1
		s.depth = depth
		if depth > s.recursionLimit then
			s:raiseRecursion("expression")
		end
		falseExpr = ifExpression(s)
		s.depth -= 1
	else
		expect(s, T.ReservedElse, "if then else expression")
		falseExpr = expression(s)
	end
	return nodeAdd(s, {
		kind = K.AstExprIfElse,
		start = start,
		finish = s.finishes[falseExpr],
		condition = condition,
		trueExpr = trueExpr,
		falseExpr = falseExpr,
		hasThen = hasThen,
		hasElse = hasElse,
		conditionLocal = conditionLocal,
		conditionIsConst = hasBinding and bConst,
	})
end
@native
function simple(s: any): number
	local k: number, start: number, finish: number = s.kind, s.start, s.finish
	if k == T.Name or k == 40 then
		return primary(s, false)
	elseif k == T.Number then
		return numberExpr(s)
	elseif k == T.QuotedString or k == T.RawString or k == T.InterpStringSimple then
		return stringExpr(s)
	elseif k == 123 then
		return tableConstructor(s)
	elseif k == T.ReservedTrue or k == T.ReservedFalse then
		advance(s)
		return nodeAdd(s, { kind = K.AstExprConstantBool, start = start, finish = finish, value = k == T.ReservedTrue })
	elseif k == T.ReservedNil then
		advance(s)
		return nodeAdd(s, { kind = K.AstExprConstantNil, start = start, finish = finish })
	elseif k == T.ReservedFunction then
		advance(s)
		return (functionBody(s, start, false))
	elseif k == T.ReservedIf then
		return ifExpression(s)
	elseif k == T.InterpStringBegin then
		return interpString(s)
	elseif k == T.Dot3 then
		advance(s)
		if not s.vararg then
			return exprError(s, start, finish, "Cannot use '...' outside of a vararg function")
		end
		return nodeAdd(s, { kind = K.AstExprVarargs, start = start, finish = finish })
	elseif k == T.Attribute or k == T.AttributeOpen then
		local attrs = attributes(s)
		if s.kind ~= T.ReservedFunction then
			return exprError(
				s,
				start,
				finish,
				"Expected 'function' declaration after attribute, but got " .. s:tokenName() .. " instead"
			)
		end
		advance(s)
		return (functionBody(s, start, false, attrs))
	elseif k == T.BrokenString then
		advance(s)
		return exprError(s, start, finish, "Malformed string; did you forget to finish it?")
	elseif k == T.BrokenInterpDoubleBrace then
		advance(s)
		return exprError(
			s,
			start,
			finish,
			"Double braces are not permitted within interpolated strings; did you mean '\\{'?"
		)
	else
		return primary(s, false)
	end
end
local function checkBinaryConfusable(s: any, tok: number, minPrec: number): (number, number, string?)
	if tok ~= 38 and tok ~= 124 and tok ~= 33 then
		return 0, 0, nil
	end
	local nk = s:peek()
	local lexer = s.lexer
	if s.finish ~= lexer.cacheStart then
		return 0, 0, nil
	end
	if tok == 38 and nk == 38 and 2 > minPrec then
		local spanStart = s.start
		s:advance()
		s:report(spanStart, s.finish, "Unexpected '&&'; did you mean 'and'?")
		return 2, 2, "And"
	elseif tok == 124 and nk == 124 and 1 > minPrec then
		local spanStart = s.start
		s:advance()
		s:report(spanStart, s.finish, "Unexpected '||'; did you mean 'or'?")
		return 1, 1, "Or"
	elseif tok == 33 and nk == 61 and 3 > minPrec then
		local spanStart = s.start
		s:advance()
		s:report(spanStart, s.finish, "Unexpected '!='; did you mean '~='?")
		return 3, 3, "CompareNe"
	end
	return 0, 0, nil
end
@native
function expression(s: any, limit: number?): number
	local depth: number = s.depth + 1
	s.depth = depth
	if depth > s.recursionLimit then
		s:raiseRecursion("expression")
	end
	local start: number = s.start
	local result: number
	local tok0: number = s.kind
	if tok0 == 45 or tok0 == 35 or tok0 == T.ReservedNot or tok0 == 33 then
		local unary: string
		if tok0 == 45 then
			unary = "Minus"
		elseif tok0 == 35 then
			unary = "Len"
		elseif tok0 == T.ReservedNot then
			unary = "Not"
		else
			s:report(start, s.finish, "Unexpected '!'; did you mean 'not'?")
			unary = "Not"
		end
		advance(s)
		local inner = expression(s, 8)
		result =
			nodeAdd(s, { kind = K.AstExprUnary, start = start, finish = s.finishes[inner], op = unary, expr = inner })
	else
		result = simple(s)
		if s.kind == T.DoubleColon then
			advance(s)
			local annotation = s.parseType(s)
			result = nodeAdd(s, {
				kind = K.AstExprTypeAssertion,
				start = start,
				finish = s.finishes[annotation],
				expr = result,
				annotation = annotation,
			})
		end
	end
	local minPrec: number = limit or 0
	local chainDepth = 0
	while true do
		local tok: number = s.kind
		local leftPrec: number = if tok < 320 then readu8(BINARY_LEFT, tok) else 0
		local rightPrec: number
		local binOpName: string
		if leftPrec > minPrec then
			rightPrec = readu8(BINARY_RIGHT, tok)
			binOpName = binaryOp[tok]
		elseif tok == 38 or tok == 124 or tok == 33 then
			local cl, cr, cOp = checkBinaryConfusable(s, tok, minPrec)
			if not cOp or cl <= minPrec then
				break
			end
			rightPrec, binOpName = cr, cOp
		else
			break
		end
		advance(s)
		local right = expression(s, rightPrec)
		result = nodeAdd(s, {
			kind = K.AstExprBinary,
			start = start,
			finish = s.finishes[right],
			op = binOpName,
			left = result,
			right = right,
		})
		chainDepth += 1
		local chainD: number = s.depth + 1
		s.depth = chainD
		if chainD > s.recursionLimit then
			s:raiseRecursion("expression")
		end
	end
	s.depth -= chainDepth + 1
	return result
end
@native
local function functionSignature(s: any): (number, number, boolean, number, any, number)
	local argStart: number, argKind: number = s.start, s.kind
	expect(s, 40, "function")
	recoveryPush(s, 41)
	local bindBase: number = s.listTop
	local listScratch = s.listScratch
	local vararg = false
	local varargAnnotation = 0
	local varargLocation = ZERO_LOCATION
	if s.kind ~= 41 then
		while true do
			if s.kind == T.Dot3 then
				vararg = true
				varargLocation = currentLocation(s)
				advance(s)
				if s.kind == 58 then
					advance(s)
					varargAnnotation = s.parseTypePack(s, true)
				end
				break
			end
			local bName, bStart, bFinish, bAnn = binding(s)
			local top: number = s.listTop
			listScratch[top + 1] = bName
			listScratch[top + 2] = bStart
			listScratch[top + 3] = bFinish
			listScratch[top + 4] = bAnn
			s.listTop = top + 4
			if s.kind ~= 44 then
				break
			end
			advance(s)
		end
	end
	local bindTop: number = s.listTop
	expectClose(s, 41, argKind, argStart, true)
	recoveryPop(s, 41)
	local returnAnnotation = 0
	if s.kind == 58 or s.kind == T.SkinnyArrow then
		if s.kind == T.SkinnyArrow then
			s:report(s.start, s.finish, "Function return type annotations are written after ':' instead of '->'")
		end
		advance(s)
		returnAnnotation = s.parseTypePack(s)
		if s.kind == 44 then
			s:report(
				s.start,
				s.finish,
				"Expected a statement, got ','; did you forget to wrap the list of return types in parentheses?"
			)
			advance(s)
		end
	end
	return bindBase, bindTop, vararg, varargAnnotation, varargLocation, returnAnnotation
end
@native
local function commitBindings(s: any, base: number, top: number, isConst: boolean): number
	if top <= base then
		return 0
	end
	local scratch = s.listScratch
	local outIdx: number = base
	for idx = base + 1, top, 4 do
		outIdx += 1
		scratch[outIdx] = bindLocal(s, scratch[idx], scratch[idx + 1], scratch[idx + 2], scratch[idx + 3], isConst)
	end
	s.listTop = outIdx
	return commitList(s, base)
end
local function atClassKeyword(s: any): boolean
	if s.kind ~= T.Name then
		return false
	end
	if s.value == "class" then
		return s:peek() == T.Name
	end
	if s.value == "open" then
		local pk, pv = s:peek()
		return pk == T.Name and pv == "class"
	end
	return false
end
@native
function functionBody(
	s: any,
	start: number,
	isMethod: boolean?,
	attrs: number?,
	debugname: number?,
	keywordFinish: number?,
	localNameSym: number?,
	localStart: number?,
	localFinish: number?,
	localIsConst: boolean?
): (number, number)
	local keywordStart: number = start
	if attrs and attrs ~= 0 then
		start = s.starts[s.arena:listAt(attrs, 1)]
	end
	local generics, genericPacks = 0, 0
	if s.kind == 60 then
		generics, genericPacks = s.parseGenerics(s, false)
	end
	local bindBase, bindTop, vararg, varargAnnotation, varargLocation, returnAnnotation = functionSignature(s)
	local functionLocal = if localNameSym
		then bindLocal(s, localNameSym, localStart :: number, localFinish :: number, 0, localIsConst)
		else 0
	local mark: number = s.localTop
	local oldDepth: number, oldLoop: number, oldVararg = s.functionDepth, s.loopDepth, s.vararg
	s.functionDepth = oldDepth + 1
	s.loopDepth = 0
	s.vararg = vararg
	local selfBinding = 0
	if isMethod then
		selfBinding = bindLocal(s, s:symbolFor("self"), start, keywordFinish or start, 0)
	end
	local argsList = commitBindings(s, bindBase, bindTop, false)
	local body = block(s, true)
	if s.localTop > mark then
		restoreScope(s, mark)
	end
	s.functionDepth = oldDepth
	s.loopDepth = oldLoop
	s.vararg = oldVararg
	local finish: number = s.finish
	local hasEnd = expectClose(s, T.ReservedEnd, T.ReservedFunction, keywordStart, false, true)
	s.nodes[body].hasEnd = hasEnd
	return nodeAdd(s, {
		kind = K.AstExprFunction,
		start = start,
		finish = finish,
		attributes = attrs or 0,
		generics = generics,
		genericPacks = genericPacks,
		self = selfBinding,
		args = argsList,
		vararg = vararg,
		varargLocation = varargLocation,
		varargAnnotation = varargAnnotation,
		body = body,
		functionDepth = oldDepth + 1,
		debugname = debugname or 0,
		returnAnnotation = returnAnnotation,
	}),
		functionLocal
end
local function functionStatement(s: any, start: number?, attrs: number?): number
	local actualStart = start or s.start
	local functionStart, functionFinish = s.start, s.finish
	advance(s)
	local name = nameExpr(s, "function name")
	local nameNode = s.nodes[name]
	local debugname = nameNode.name or (if nameNode["local"] then s.bindings[nameNode["local"]].name else 0)
	local method = false
	local oldDepth = s.depth
	while s.kind == 46 do
		local opPosition = s.start
		advance(s)
		local index, a, b = expectName(s, "field name")
		debugname = index
		name = nodeAdd(s, {
			kind = K.AstExprIndexName,
			start = s.starts[name],
			finish = b,
			expr = name,
			index = index,
			indexStart = a,
			indexFinish = b,
			op = ".",
			opPosition = opPosition,
		})
		local d = s.depth + 1
		s.depth = d
		if d > s.recursionLimit then
			s:raiseRecursion("function name")
		end
	end
	s.depth = oldDepth
	if s.kind == 58 then
		local opPosition = s.start
		advance(s)
		local index, a, b = expectName(s, "method name")
		debugname = index
		name = nodeAdd(s, {
			kind = K.AstExprIndexName,
			start = s.starts[name],
			finish = b,
			expr = name,
			index = index,
			indexStart = a,
			indexFinish = b,
			op = ":",
			opPosition = opPosition,
		})
		method = true
	end
	name = lvalue(s, name)
	s:recoveryPush(T.ReservedEnd)
	local func = functionBody(
		s,
		functionStart,
		method,
		attrs,
		debugname,
		if attrs and attrs ~= 0 then s.finishes[s.arena:listAt(attrs, 1)] else functionFinish
	)
	s:recoveryPop(T.ReservedEnd)
	return nodeAdd(s, {
		kind = K.AstStatFunction,
		start = actualStart,
		finish = s.finishes[func],
		name = name,
		func = func,
	})
end
@native
local function localStatement(s: any, start: number?, attrs: number?, isConst: boolean?, kwStart: number?): number
	local actualStart: number = start or s.start
	if not isConst and s.kind == T.ReservedLocal then
		advance(s)
	end
	local hasClasses: boolean = s.hasClasses
	local parseClassFn: ((...any) -> number)? = s.parseClass
	if hasClasses and parseClassFn and atClassKeyword(s) then
		local isOpen = s:isName("open")
		if isOpen then
			advance(s)
		end
		advance(s)
		if attrs and attrs ~= 0 then
			local firstAttr = s.nodes[s.arena:listAt(attrs, 1)]
			s:report(firstAttr.start, firstAttr.finish, "Attributes are not supported on class declarations")
		end
		return parseClassFn(s, actualStart, if isConst then "Const" else "Local", isOpen)
	end
	if s.kind == T.ReservedFunction then
		local functionStart: number = s.start
		advance(s)
		if s:sameLine(actualStart, functionStart) then
			functionStart = actualStart
		end
		local name, a, b = expectName(s, "variable name")
		-- Parameters are not yet in scope; self-recursive binding is in the outer scope.
		s:recoveryPush(T.ReservedEnd)
		local func, localId = functionBody(s, functionStart, false, attrs, name, nil, name, a, b, isConst == true)
		s:recoveryPop(T.ReservedEnd)
		return nodeAdd(s, {
			kind = K.AstStatLocalFunction,
			start = actualStart,
			finish = s.finishes[func],
			name = localId,
			func = func,
			isConst = isConst == true,
			constKeywordBegin = if isConst then kwStart else nil,
		})
	end
	if attrs and attrs ~= 0 then
		return statError(
			s,
			s.start,
			s.finish,
			"Expected 'function' after local declaration with attribute, but got " .. s:tokenName() .. " instead"
		)
	end
	local constFlag = isConst == true
	recoveryPush(s, 61)
	local name1, start1, finish1, ann1 = binding(s, constFlag)
	local varsList: number
	local varCount = 1
	local valuesList, valuesCount, lastValue = 0, 0, 0
	if s.kind ~= 44 then
		recoveryPop(s, 61)
		if s.kind == 61 then
			advance(s)
			valuesList, valuesCount, lastValue = exprList(s)
		end
		varsList = arenaList1(s.arena, bindLocal(s, name1, start1, finish1, ann1, constFlag))
	else
		local bindBase: number = s.listTop
		local listScratch = s.listScratch
		listScratch[bindBase + 1] = name1
		listScratch[bindBase + 2] = start1
		listScratch[bindBase + 3] = finish1
		listScratch[bindBase + 4] = ann1
		local top: number = bindBase + 4
		s.listTop = top
		while s.kind == 44 do
			advance(s)
			local bName, bStart, bFinish, bAnn = binding(s, constFlag)
			listScratch[top + 1] = bName
			listScratch[top + 2] = bStart
			listScratch[top + 3] = bFinish
			listScratch[top + 4] = bAnn
			top += 4
			s.listTop = top
			varCount += 1
		end
		local bindTop: number = top
		recoveryPop(s, 61)
		if s.kind == 61 then
			advance(s)
			valuesList, valuesCount, lastValue = exprList(s)
		end
		varsList = commitBindings(s, bindBase, bindTop, constFlag)
	end
	local finish: number = if valuesCount > 0 then s.finishes[lastValue] else s.previousFinish
	if constFlag then
		local lastKind = if lastValue ~= 0 then s.kinds[lastValue] else 0
		if valuesCount ~= varCount and not (lastKind == K.AstExprCall or lastKind == K.AstExprVarargs) then
			s:report(actualStart, finish, "Missing initializer in const declaration")
		end
	end
	return nodeAdd(s, {
		kind = K.AstStatLocal,
		start = actualStart,
		finish = finish,
		vars = varsList,
		values = valuesList,
		isConst = constFlag,
		isExported = false,
	})
end
local function classStatement(
	s: any,
	start: number,
	declModifier: string,
	isOpen: boolean,
	errStart: number?,
	errFinish: number?,
	errExprId: number?
): number
	if isOpen then
		if not s:isName("class") then
			return statError(
				s,
				errStart or start,
				errFinish or s.finish,
				"Incomplete statement: expected a class definition after 'open'",
				if errExprId then { errExprId } else nil
			)
		end
		s:advance()
	end
	return s.parseClass(s, start, declModifier, isOpen)
end
local function markExportBinding(s: any, bindingId: number)
	local b = s.bindings[bindingId]
	local exportBindings = s.exportBindings
	b.isExported = true
	if exportBindings[b.name] then
		s:report(b.start, b.finish, "Duplicate exported identifier '" .. s.arena.symbols[b.name] .. "'")
	else
		exportBindings[b.name] = true
	end
end
function exportValue(s: any, start: number, attrs: number?): number
	local errFinish = if attrs and attrs ~= 0 then s.finishes[s.arena:listAt(attrs, 1)] else start + 6
	if s.functionDepth ~= 0 or s.blockDepth ~= 1 then
		s:report(start, errFinish, "'export' may only be applied to top-level statements")
	end
	if s.moduleReturn then
		s:report(start, errFinish, "Exporting values is not compatible with top-level return (export/return conflict)")
	end
	local hasClasses = s.profile.DebugLuauUserDefinedClasses == true
	local parseClassFn: ((...any) -> number)? = s.parseClass
	local result: number
	if attrs and attrs ~= 0 and s.kind ~= T.ReservedFunction then
		s:report(
			s.start,
			s.finish,
			"Expected 'function' after export declaration with attribute, but got " .. s:tokenName() .. " instead"
		)
	end
	if s.kind == T.ReservedFunction then
		result = localStatement(s, start, attrs, true)
	elseif s.kind == T.ReservedLocal then
		local lookKind, lookVal = s:peek()
		if lookKind == T.ReservedFunction then
			s:report(
				start,
				errFinish,
				if hasClasses
					then "'export' must be followed by an identifier, 'function', or a class declaration; try removing 'local'"
					else "'export' must be followed by an identifier or 'function'; try removing 'local'"
			)
			s:advance()
			return localStatement(s, start, nil, true)
		elseif hasClasses and lookKind == T.Name and (lookVal == "class" or lookVal == "open") then
			s:report(
				start,
				errFinish,
				"'export' must be followed by an identifier, 'function', or a class declaration; try removing 'local'"
			)
			s:advance()
			return localStatement(s, start, nil, true)
		else
			result = localStatement(s, start, nil, false)
		end
	elseif s:isName("const") then
		s:advance()
		if hasClasses and atClassKeyword(s) then
			s:report(
				start,
				errFinish,
				"'export' must be followed by an identifier, 'function', or a class declaration; try removing 'const'"
			)
			return localStatement(s, start, nil, true)
		elseif s.kind == T.ReservedFunction then
			s:report(
				start,
				errFinish,
				if hasClasses
					then "'export' must be followed by an identifier, 'function', or a class declaration; try removing 'const'"
					else "'export' must be followed by an identifier or 'function'"
			)
			return localStatement(s, start, nil, true)
		else
			result = localStatement(s, start, nil, true)
		end
	elseif hasClasses and parseClassFn and atClassKeyword(s) then
		local isOpen = s:isName("open")
		s:advance()
		if isOpen then
			if not s:isName("class") then
				return statError(s, start, errFinish, "Incomplete statement: expected a class definition after 'open'")
			end
			s:advance()
		end
		local cls = parseClassFn(s, start, "Export", isOpen)
		local clsNode = s.nodes[cls]
		if clsNode.kind == K.AstStatClass then
			markExportBinding(s, clsNode.localName)
		end
		return cls
	else
		return statError(
			s,
			start,
			s.finish,
			if hasClasses
				then "'export' must be followed by an identifier, 'function', or a class declaration"
				else "'export' must be followed by an identifier or 'function'"
		)
	end
	local r = s.nodes[result]
	local rk = r.kind
	if rk == K.AstStatLocal then
		r.isExported = true
		local varsList = r.vars
		for i = 1, s.arena:listCount(varsList) do
			markExportBinding(s, s.arena:listAt(varsList, i))
		end
	elseif rk == K.AstStatLocalFunction then
		markExportBinding(s, r.name)
	end
	return result
end
local function loopControl(s: any, isContinue: boolean, start: number, finish: number): number
	local control =
		s:node({ kind = if isContinue then K.AstStatContinue else K.AstStatBreak, start = start, finish = finish })
	if s.loopDepth == 0 then
		return statError(
			s,
			start,
			finish,
			(if isContinue then "continue" else "break") .. " statement must be inside a loop",
			nil,
			{ control }
		)
	end
	return control
end
@native
function ifStatement(s: any): number
	local start: number = s.start
	advance(s)
	local hasBinding, bName, bStart, bFinish, bAnn, bConst = conditionBinding(s)
	local condition = expression(s)
	local thenStart: number, thenKind: number = s.start, s.kind
	local hasThen = expect(s, T.ReservedThen, "if statement")
	local closerKind: number, closerStart: number = thenKind, thenStart
	local mark: number = s.localTop
	local conditionLocal = if hasBinding then bindLocal(s, bName, bStart, bFinish, bAnn, bConst) else 0
	local thenbody = block(s, true)
	if s.localTop > mark then
		restoreScope(s, mark)
	end
	local elsebody = 0
	local finish: number = s.finish
	if s.kind == T.ReservedElseif then
		s.nodes[thenbody].hasEnd = true
		local depth: number = s.depth + 1
		s.depth = depth
		if depth > s.recursionLimit then
			s:raiseRecursion("elseif")
		end
		elsebody = ifStatement(s)
		s.depth -= 1
		finish = s.finishes[elsebody]
	else
		if s.kind == T.ReservedElse then
			s.nodes[thenbody].hasEnd = true
			closerKind, closerStart = T.ReservedElse, s.start
			advance(s)
			elsebody = block(s, true)
		end
		finish = s.finish
		local hasEnd = expectClose(s, T.ReservedEnd, closerKind, closerStart, false, true)
		s.nodes[if elsebody ~= 0 then elsebody else thenbody].hasEnd = hasEnd
	end
	return nodeAdd(s, {
		kind = K.AstStatIf,
		start = start,
		finish = finish,
		condition = condition,
		thenbody = thenbody,
		elsebody = elsebody,
		hasThen = hasThen,
		conditionLocal = conditionLocal,
		conditionIsConst = hasBinding and bConst,
	})
end
local function whileLocalCondition(s: any, start: number): number
	local condIsConst = s:isName("const")
	s:advance() -- consume 'local' or 'const'
	local bName, bStart, bFinish, bAnn, bConst = binding(s, condIsConst)
	if s.kind == 44 then
		s:report(
			s.start,
			s.finish,
			"Expected '=' after variable name in 'while local', got ','; only a single binding is allowed"
		)
	end
	s:expect(61, "while local declaration")
	local condition = expression(s)
	local doStart, doKind = s.start, s.kind
	local hasDo = s:expect(T.ReservedDo, "while loop")
	local mark = s:mark()
	local conditionLocal = s:bind(bName, bStart, bFinish, bAnn, bConst)
	s.loopDepth += 1
	local body = block(s, true)
	s.loopDepth -= 1
	s:restore(mark)
	local finish = s.finish
	s.nodes[body].hasEnd = expectClose(s, T.ReservedEnd, doKind, doStart, false, true)
	return nodeAdd(s, {
		kind = K.AstStatWhile,
		start = start,
		finish = finish,
		condition = condition,
		body = body,
		hasDo = hasDo,
		conditionLocal = conditionLocal,
		conditionIsConst = condIsConst,
	})
end
local function whileStatement(s: any): number
	local start = s.start
	s:advance()
	if
		s.profile.LuauExperimentalWhileLocalSyntax
		and (s.kind == T.ReservedLocal or (s:isName("const") and s:peek() == T.Name))
	then
		return whileLocalCondition(s, start)
	end
	local condition = expression(s)
	local doStart, doKind = s.start, s.kind
	local hasDo = s:expect(T.ReservedDo, "while loop")
	s.loopDepth += 1
	local body = block(s, true)
	s.loopDepth -= 1
	local finish = s.finish
	s.nodes[body].hasEnd = expectClose(s, T.ReservedEnd, doKind, doStart, false, true)
	return nodeAdd(s, {
		kind = K.AstStatWhile,
		start = start,
		finish = finish,
		condition = condition,
		body = body,
		hasDo = hasDo,
	})
end
local function repeatStatement(s: any): number
	local start = s.start
	s:advance()
	local mark = s:mark()
	s.loopDepth += 1
	local body = block(s, false)
	s.loopDepth -= 1
	local hasUntil = s:expectClose(T.ReservedUntil, T.ReservedRepeat, start, false, true)
	s.nodes[body].hasEnd = hasUntil
	local condition = expression(s)
	if s.localTop > mark then
		restoreScope(s, mark)
	end
	return nodeAdd(s, {
		kind = K.AstStatRepeat,
		start = start,
		finish = s.finishes[condition],
		condition = condition,
		body = body,
	})
end
local function forStatement(s: any): number
	local start = s.start
	s:advance()
	local name1, start1, finish1, ann1, const1 = binding(s)
	if s:consume(61) then
		local from = expression(s)
		s:expect(44, "index range")
		local to = expression(s)
		local step = if s:consume(44) then expression(s) else 0
		local doStart, doKind = s.start, s.kind
		local hasDo = s:expect(T.ReservedDo, "for loop")
		local mark = s:mark()
		s.loopDepth += 1
		local variable = s:bind(name1, start1, finish1, ann1, const1)
		local body = block(s, true)
		s.loopDepth -= 1
		s:restore(mark)
		local finish = s.finish
		s.nodes[body].hasEnd = expectClose(s, T.ReservedEnd, doKind, doStart, false, true)
		return nodeAdd(s, {
			kind = K.AstStatFor,
			start = start,
			finish = finish,
			var = variable,
			from = from,
			to = to,
			step = step,
			body = body,
			hasDo = hasDo,
		})
	end
	local varsList: number
	local valuesList: number
	local hasIn: boolean
	local doStart: number
	local doKind: number
	local hasDo: boolean
	local mark: number
	if not s:consume(44) then
		hasIn = s:expect(T.ReservedIn, "for loop")
		valuesList = exprList(s)
		doStart, doKind = s.start, s.kind
		hasDo = s:expect(T.ReservedDo, "for loop")
		mark = s:mark()
		s.loopDepth += 1
		varsList = s:list1(s:bind(name1, start1, finish1, ann1, false))
	else
		local bindBase = s:beginList()
		s:pushList(name1)
		s:pushList(start1)
		s:pushList(finish1)
		s:pushList(ann1)
		repeat
			local bName, bStart, bFinish, bAnn = binding(s)
			s:pushList(bName)
			s:pushList(bStart)
			s:pushList(bFinish)
			s:pushList(bAnn)
		until not s:consume(44)
		local bindTop = s.listTop
		hasIn = s:expect(T.ReservedIn, "for loop")
		valuesList = exprList(s)
		doStart, doKind = s.start, s.kind
		hasDo = s:expect(T.ReservedDo, "for loop")
		mark = s:mark()
		s.loopDepth += 1
		varsList = commitBindings(s, bindBase, bindTop, false)
	end
	local body = block(s, true)
	s.loopDepth -= 1
	s:restore(mark)
	local finish = s.finish
	s.nodes[body].hasEnd = expectClose(s, T.ReservedEnd, doKind, doStart, false, true)
	return nodeAdd(s, {
		kind = K.AstStatForIn,
		start = start,
		finish = finish,
		vars = varsList,
		values = valuesList,
		body = body,
		hasIn = hasIn,
		hasDo = hasDo,
	})
end
local attributeTypes: any = table.freeze({ checked = "Checked", native = "Native", deprecated = "Deprecated" })
local function constant(s: any, id: number): boolean
	local n = s.nodes[id]
	local k = n.kind
	if k == K.AstExprTable then
		local itemsList = n.items
		for i = 1, s.arena:listCount(itemsList) do
			local item = s.arena:listAt(itemsList, i)
			if item.kind == "General" then
				return false
			end
			if item.key ~= 0 and not constant(s, item.key) then
				return false
			end
			if not constant(s, item.value) then
				return false
			end
		end
		return true
	end
	return k == K.AstExprConstantNil
		or k == K.AstExprConstantBool
		or k == K.AstExprConstantNumber
		or k == K.AstExprConstantString
end
local function checkDeprecatedArgs(
	s: any,
	start: number,
	finish: number,
	nameFinish: number?,
	argsList: number,
	argCount: number
)
	local firstArg = s.nodes[s.arena:listAt(argsList, 1)]
	if argCount > 1 then
		s:report(start, nameFinish or finish, "@deprecated can be parametrized only by 1 argument")
	elseif firstArg.kind ~= K.AstExprTable then
		s:report(firstArg.start, firstArg.finish, "Unknown argument type for @deprecated")
	else
		local itemsList = firstArg.items
		for i = 1, s.arena:listCount(itemsList) do
			local item = s.arena:listAt(itemsList, i)
			local itemVal = s.nodes[item.value]
			local itemKey = if item.key ~= 0 then s.nodes[item.key] else nil
			if item.kind ~= "Record" or not itemKey then
				s:report(
					itemVal.start,
					itemVal.finish,
					"Only constants keys 'use' and 'reason' are allowed for @deprecated attribute"
				)
			elseif itemKey.value ~= "use" and itemKey.value ~= "reason" then
				s:report(
					itemKey.start,
					itemKey.finish,
					"Unknown argument '"
						.. itemKey.value
						.. "' for @deprecated. Only string constants for 'use' and 'reason' are allowed"
				)
			elseif itemVal.kind ~= K.AstExprConstantString then
				s:report(
					itemVal.start,
					itemVal.finish,
					"Only constant string allowed as value for '" .. itemKey.value .. "'"
				)
			end
		end
	end
end
local function recordAttribute(
	s: any,
	entries: { number },
	seen: { [string]: boolean },
	start: number,
	finish: number,
	symbol: number,
	hasArgs: boolean?,
	argsList: number?,
	nameFinish: number?,
	argStart: number?
)
	local name = s.arena.symbols[symbol] or ""
	local attrType = attributeTypes[name]
	if name == "debugnoinline" and s.profile.DebugLuauNoInline then
		attrType = "DebugNoinline"
	end
	local resolvedArgs = argsList or 0
	local argCount = if hasArgs and resolvedArgs ~= 0 then s.arena:listCount(resolvedArgs) else 0
	if argCount > 0 then
		for i = 1, argCount do
			local arg = s.arena:listAt(resolvedArgs, i)
			if not constant(s, arg) then
				s:report(argStart or s.starts[arg], finish, "Only literals can be passed as arguments for attributes")
			end
		end
	end
	if not attrType then
		s:report(
			start,
			nameFinish or finish,
			if name == "" then "Attribute name is missing" else "Invalid attribute '@" .. name .. "'"
		)
	elseif seen[attrType] then
		s:report(start, nameFinish or finish, "Cannot duplicate attribute '@" .. name .. "'")
	end
	if attrType then
		seen[attrType] = true
		if attrType == "Deprecated" and argCount > 0 then
			checkDeprecatedArgs(s, start, finish, nameFinish, resolvedArgs, argCount)
		end
	end
	entries[#entries + 1] = s:node({
		kind = K.AstAttr,
		start = start,
		finish = finish,
		type = attrType or "Unknown",
		name = symbol,
		args = resolvedArgs,
	})
end
local function bracketAttributes(s: any, entries: { number }, seen: { [string]: boolean })
	local start = s.start
	s:advance()
	if s.kind == 93 then
		s:report(start, s.finish, "Attribute list cannot be empty")
		entries[#entries + 1] = s:node({
			kind = K.AstAttr,
			start = start,
			finish = s.finish,
			type = "Unknown",
			name = s:symbolFor("%error-id%"),
			args = 0,
		})
	else
		repeat
			local symbol, a, b = s:expectName("attribute name")
			local nameFinish = b
			local argStart = s.start
			local hasArgs = false
			local argsList = 0
			if s.kind == 40 then
				local parenStart = s.start
				argStart = s.finish
				s:advance()
				if s.kind ~= 41 then
					hasArgs = true
					argsList = exprList(s)
				end
				b = s.finish
				s:expectClose(41, 40, parenStart)
			elseif s.kind == 123 then
				hasArgs = true
				argStart = s.finish
				local tbl = tableConstructor(s)
				argsList = s:list1(tbl)
				b = s.finishes[tbl]
			elseif s.kind == T.RawString or s.kind == T.QuotedString then
				hasArgs = true
				local str = stringExpr(s)
				argsList = s:list1(str)
				b = s.finishes[str]
			end
			recordAttribute(s, entries, seen, a, b, symbol, hasArgs, argsList, nameFinish, argStart)
		until not s:consume(44)
	end
	s:expectClose(93, T.AttributeOpen, start)
end
function attributes(s: any): number
	if s.kind ~= T.Attribute and s.kind ~= T.AttributeOpen then
		return 0
	end
	local entries, seen = {}, {}
	while s.kind == T.Attribute or s.kind == T.AttributeOpen do
		if s.kind == T.Attribute then
			local start, finish, symbol = s.start, s.finish, s.symbol
			s:advance()
			recordAttribute(s, entries, seen, start, finish, symbol)
		else
			bracketAttributes(s, entries, seen)
		end
	end
	return s:list(entries)
end
@native
local function returnStatement(s: any, start: number): number
	local finish: number = s.finish
	advance(s)
	local listId = 0
	local fk: number = s.kind
	if
		fk ~= 0
		and fk ~= 59
		and fk ~= RESERVED_ELSE
		and fk ~= RESERVED_ELSEIF
		and fk ~= RESERVED_END
		and fk ~= RESERVED_UNTIL
	then
		local exprsList, _, lastExpr = exprList(s)
		listId = exprsList
		finish = s.finishes[lastExpr]
	end
	if s.hasExportValue and s.functionDepth == 0 then
		if s.exportBindings and next(s.exportBindings) ~= nil then
			s:report(start, finish, "Exporting values is not compatible with top-level return (export/return conflict)")
		end
		s.moduleReturn = true
	end
	return nodeAdd(s, {
		kind = K.AstStatReturn,
		start = start,
		finish = finish,
		list = listId,
	})
end
local function attributedStatement(s: any, start: number): number
	local attrs = attributes(s)
	if attrs ~= 0 then
		start = s.starts[s.arena:listAt(attrs, 1)]
	end
	if s.kind == T.ReservedFunction then
		return functionStatement(s, start, attrs)
	elseif s.kind == T.ReservedLocal then
		return localStatement(s, start, attrs, false)
	elseif s:isName("const") then
		local kwStart = s.start
		s:advance()
		return localStatement(s, start, attrs, true, kwStart)
	elseif s:isName("export") and s.profile.LuauExportValueSyntax then
		s:advance()
		return exportValue(s, start, attrs)
	elseif s.options.allowDeclarationSyntax and s:isName("declare") then
		local declareStart = s.start
		s:advance()
		if s.kind ~= T.ReservedFunction then
			return statError(
				s,
				s.start,
				s.finish,
				"Expected a function type declaration after attribute, but got " .. s:tokenName() .. " instead"
			)
		end
		return s.parseDeclaration(s, declareStart, attrs)
	end
	return statError(
		s,
		s.start,
		s.finish,
		"Expected 'function', 'local function', 'const function', 'declare function' or a function type declaration after attribute, but got "
			.. s:tokenName()
			.. " instead"
	)
end
local function identStatement(s: any, start: number, ident: string, resNode: any, resId: number): number?
	if ident == "type" then
		return s.parseTypeStatement(s, start, false)
	elseif ident == "export" then
		if
			s.profile.LuauExportValueSyntax
			and (
				s.kind == T.ReservedLocal
				or s:isName("const")
				or s.kind == T.ReservedFunction
				or (s.profile.DebugLuauUserDefinedClasses and (s:isName("class") or s:isName("open")))
			)
		then
			return exportValue(s, start)
		elseif s:isName("type") then
			s:advance()
			return s.parseTypeStatement(s, start, true)
		elseif s.profile.DebugLuauUserDefinedClasses and s.parseClass and (s:isName("class") or s:isName("open")) then
			if s.functionDepth ~= 0 or s.blockDepth ~= 1 then
				s:report(start, start + 6, "'export' may only be applied to top-level statements")
			end
			if s.moduleReturn then
				s:report(
					start,
					start + 6,
					"Exporting values is not compatible with top-level return (export/return conflict)"
				)
			end
			local isOpen = s:isName("open")
			s:advance()
			local cls = classStatement(s, start, "Export", isOpen, resNode.start, resNode.finish, resId)
			local clsNode = s.nodes[cls]
			if clsNode.kind == K.AstStatClass then
				markExportBinding(s, clsNode.localName)
			end
			return cls
		end
	elseif ident == "continue" then
		return loopControl(s, true, start, resNode.finish)
	elseif ident == "const" then
		return localStatement(s, start, nil, true, start)
	elseif ident == "declare" and s.options.allowDeclarationSyntax then
		return s.parseDeclaration(s, start, 0)
	elseif (ident == "class" or ident == "open") and s.profile.DebugLuauUserDefinedClasses and s.parseClass then
		return classStatement(s, start, "None", ident == "open", resNode.start, resNode.finish, resId)
	end
	return nil
end
@native
function statement(s: any): number
	local k: number, start: number = s.kind, s.start
	if k ~= T.Name then
		if k == T.ReservedLocal then
			return localStatement(s)
		elseif k == T.ReservedIf then
			return ifStatement(s)
		elseif k == T.ReservedReturn then
			return returnStatement(s, start)
		elseif k == T.ReservedFor then
			return forStatement(s)
		elseif k == T.ReservedWhile then
			return whileStatement(s)
		elseif k == T.ReservedFunction then
			return functionStatement(s)
		elseif k == T.ReservedDo then
			advance(s)
			local body = block(s, true)
			local bodyNode = s.nodes[body]
			bodyNode.start = start
			s.starts[body] = start
			bodyNode.hasEnd = expectClose(s, T.ReservedEnd, T.ReservedDo, start, false, true)
			if bodyNode.hasEnd then
				local prevFinish: number = s.previousFinish
				bodyNode.finish = prevFinish
				s.finishes[body] = prevFinish
			end
			return body
		elseif k == T.ReservedRepeat then
			return repeatStatement(s)
		elseif k == T.ReservedBreak then
			local finish: number = s.finish
			advance(s)
			return loopControl(s, false, start, finish)
		elseif k == T.Attribute or k == T.AttributeOpen then
			return attributedStatement(s, start)
		end
	end
	local result = primary(s, true)
	local resNode = s.nodes[result]
	local resultKind: number = resNode.kind
	if resultKind == K.AstExprCall then
		return nodeAdd(s, { kind = K.AstStatExpr, start = start, finish = resNode.finish, expr = result })
	end
	if s.kind == 44 or s.kind == 61 then
		local varsBase: number = s.listTop
		local listScratch = s.listScratch
		local top: number = varsBase + 1
		listScratch[top] = lvalue(s, result)
		s.listTop = top
		while s.kind == 44 do
			advance(s)
			local lv = lvalue(s, primary(s, true))
			top += 1
			listScratch[top] = lv
			s.listTop = top
		end
		local varsList = commitList(s, varsBase)
		expect(s, 61, "assignment")
		local valuesList, _, lastValue = exprList(s)
		return nodeAdd(s, {
			kind = K.AstStatAssign,
			start = start,
			finish = s.finishes[lastValue],
			vars = varsList,
			values = valuesList,
		})
	elseif s.kind >= T.AddAssign and s.kind <= T.ConcatAssign then
		local op = compound[s.kind]
		if op then
			advance(s)
			local variable = lvalue(s, result)
			local value = expression(s)
			return nodeAdd(s, {
				kind = K.AstStatCompoundAssign,
				start = start,
				finish = s.finishes[value],
				op = op,
				var = variable,
				value = value,
			})
		end
	end
	-- Context-sensitive keywords only apply to an unadorned name, even if locally bound.
	local ident = nil
	if resultKind == K.AstExprGlobal then
		ident = s.arena.symbols[resNode.name]
	elseif resultKind == K.AstExprLocal then
		ident = s.arena.symbols[s.bindings[resNode["local"]].name]
	end
	if ident then
		local stat = identStatement(s, start, ident, resNode, result)
		if stat then
			return stat
		end
	end
	if s.start == start then
		advance(s)
	end
	return statError(
		s,
		start,
		resNode.finish,
		"Incomplete statement: expected assignment or a function call",
		{ result }
	)
end
@native
function block(s: any, scoped: boolean?): number
	local scopeDepth: number = s.blockDepth + 1
	s.blockDepth = scopeDepth
	local mark: number = s.localTop
	local start: number = s.previousFinish
	local base: number = s.listTop
	local oldDepth: number = s.depth
	local listScratch = s.listScratch
	while true do
		local stopKind: number = s.kind
		if
			stopKind == 0
			or stopKind == RESERVED_ELSE
			or stopKind == RESERVED_ELSEIF
			or stopKind == RESERVED_END
			or stopKind == RESERVED_UNTIL
		then
			break
		end
		local before: number = s.start
		local d: number = oldDepth + 1
		s.depth = d
		if d > s.recursionLimit then
			s:raiseRecursion("block")
		end
		local stat = statement(s)
		s.depth = oldDepth
		local statNode = s.nodes[stat]
		if s.kind == 59 then
			advance(s)
			local prevFinish: number = s.previousFinish
			statNode.finish = prevFinish
			s.finishes[stat] = prevFinish
		end
		local top: number = s.listTop + 1
		s.listTop = top
		listScratch[top] = stat
		local k: number = statNode.kind
		if k == K.AstStatReturn or k == K.AstStatBreak or k == K.AstStatContinue then
			break
		end
		if s.start == before then
			if s.kind == T.Eof then
				break
			end
			advance(s)
		end
	end
	local bodyList = commitList(s, base)
	if scoped ~= false and s.localTop > mark then
		restoreScope(s, mark)
	end
	local finish: number = s.start
	s.blockDepth -= 1
	return nodeAdd(s, {
		kind = K.AstStatBlock,
		start = start,
		finish = finish,
		body = bodyList,
		hasEnd = true,
		scopeDepth = scopeDepth,
	})
end
function Runtime.parseClassReference(s: any): number
	local start = s.start
	local result = nameExpr(s, "class reference expression")
	if s.kind == 46 then
		local opPosition = s.start
		s:advance()
		local index, a, b = indexName(s, "class reference expression", opPosition)
		local isPrivate = s.inClassMethodBody == true and isPrivateFieldName(s.arena.symbols[index])
		return s:node({
			kind = K.AstExprIndexName,
			start = start,
			finish = b,
			expr = result,
			index = index,
			indexStart = a,
			indexFinish = b,
			op = ".",
			privateAccess = isPrivate,
		})
	elseif s.kind == 91 then
		s:advance()
		local index = expression(s)
		s:expect(93, "class reference expression")
		return s:node({
			kind = K.AstExprIndexExpr,
			start = start,
			finish = s.previousFinish,
			expr = result,
			index = index,
		})
	end
	return result
end
Runtime.expression = expression
Runtime.functionBody = functionBody
Runtime.attributes = attributes
Runtime.lvalue = lvalue
Runtime.isPrivateFieldName = isPrivateFieldName
Runtime.parseChunk = function(s: any): number
	return block(s, false)
end
return table.freeze(Runtime)
