--!strict
-- Fresh translation of Luau 0.748 type/declaration grammar, modified for ID arenas.
-- Upstream Luau is MIT licensed; see ../LICENSE.md and ../UPSTREAM.json.
local T = require("./Token")
local Arena = require("./Arena")
local Lexer = require("./Lexer")
local State = require("./State")
local K = Arena.Kinds
local advance = State.advance
local peek = Lexer.lookahead
local nodeAdd = State.node
local expect = State.expect
local expectClose = State.expectClose
local expectName = State.expectName
local commitList = State.commitList
local commitAux = State.commitAux
local arenaList1 = Arena.list1
local arenaList = Arena.list
local TypeParser = {}
local parseType: any
local parseSimple: any
local parseTypePack: any
local parseGenerics: any
local function isTypePack(kindId: number): boolean
	return kindId == K.AstTypePackExplicit or kindId == K.AstTypePackVariadic or kindId == K.AstTypePackGeneric
end
@native
local function typeError(
	s: any,
	start: number,
	finish: number,
	message: string,
	types: { number }?,
	missing: boolean?
): number
	if not s.arena.hasTypeAnnotations then
		s.arena.hasTypeAnnotations = true
	end
	local index = s:report(start, finish, message)
	return nodeAdd(s, {
		kind = K.AstTypeError,
		start = start,
		finish = finish,
		types = if types then arenaList(s.arena, types) else 0,
		isMissing = missing or false,
		messageIndex = index,
	})
end
@native
local function ref(s: any, start: number, finish: number, name: number): number
	return nodeAdd(s, {
		kind = K.AstTypeReference,
		start = start,
		finish = finish,
		name = name,
		prefix = 0,
		prefixLocal = 0,
		nameStart = start,
		nameFinish = finish,
		parameters = 0,
		hasParameterList = false,
	})
end
@native
local function isPack(s: any): boolean
	return s.kind == T.Dot3 or (s.kind == T.Name and peek(s.lexer) == T.Dot3)
end
@native
local function genericPack(s: any): number
	local start: number = s.start
	if s.kind == T.Dot3 then
		advance(s)
		local inner = parseType(s)
		return nodeAdd(s, {
			kind = K.AstTypePackVariadic,
			start = start,
			finish = s.finishes[inner],
			variadicType = inner,
		})
	end
	local name = expectName(s, "generic name")
	local finish: number = s.finish
	expect(s, T.Dot3, "generic type pack annotation")
	return nodeAdd(s, { kind = K.AstTypePackGeneric, start = start, finish = finish, genericName = name })
end
local function explicitPackFromList(s: any, start: number, finish: number, headList: number, tail: number): number
	return nodeAdd(s, {
		kind = K.AstTypePackExplicit,
		start = start,
		finish = finish,
		types = headList,
		tailType = tail,
	})
end
local function explicitPack(s: any, start: number, finish: number, head: { number }?, tail: number): number
	return explicitPackFromList(s, start, finish, if head then arenaList(s.arena, head) else 0, tail)
end
@native
local function typeList(s: any): (boolean, number, number)
	local hasNames = false
	local tail = 0
	local n = 0
	local listScratch = s.listScratch
	local auxScratch = s.auxScratch
	while s.kind ~= 41 and s.kind ~= T.Eof do
		if isPack(s) then
			tail = genericPack(s)
			break
		end
		local nameRecord = 0
		if s.kind == T.Name and peek(s.lexer) == 58 then
			local name: number, nameStart: number, nameFinish: number = s.symbol, s.start, s.finish
			advance(s)
			nameRecord = nodeAdd(s, { kind = K.AstArgumentName, start = nameStart, finish = nameFinish, name = name })
			hasNames = true
			expect(s, 58)
		end
		n += 1
		local ty = parseType(s)
		local ltop: number = s.listTop + 1
		s.listTop = ltop
		listScratch[ltop] = ty
		local atop: number = s.auxTop + 1
		s.auxTop = atop
		auxScratch[atop] = nameRecord
		if s.kind ~= 44 then
			break
		end
		advance(s)
		if s.kind == 41 then
			s:report(s.start, s.finish, "Expected type after ',' but got ')' instead")
			break
		end
	end
	return hasNames, tail, n
end
@native
local function suffix(s: any, inner: number, start: number): number
	local kind: number = s.kind
	if inner ~= 0 and kind ~= 124 and kind ~= 38 and kind ~= 63 and kind ~= T.Dot3 then
		return inner
	end
	local oldDepth: number = s.depth
	local d: number = oldDepth + 1
	s.depth = d
	if d > s.recursionLimit then
		s:raiseRecursion("type annotation")
	end
	local base: number = s.listTop
	local listScratch = s.listScratch
	local count = 0
	local lastPart = 0
	if inner ~= 0 then
		local top: number = base + 1
		s.listTop = top
		listScratch[top] = inner
		count = 1
		lastPart = inner
	end
	local union, intersection = false, false
	local limit: number = s.options.typeLengthLimit or 1000
	local optionalCount = 0
	while true do
		kind = s.kind
		if kind == 124 or kind == 38 then
			if kind == 124 then
				union = true
			else
				intersection = true
			end
			advance(s)
			local iterDepth: number = s.depth
			lastPart = parseSimple(s, false, false)
			s.depth = iterDepth
			local top: number = s.listTop + 1
			s.listTop = top
			listScratch[top] = lastPart
			count += 1
		elseif kind == 63 then
			local a: number, b: number = s.start, s.finish
			advance(s)
			lastPart = nodeAdd(s, { kind = K.AstTypeOptional, start = a, finish = b })
			local top: number = s.listTop + 1
			s.listTop = top
			listScratch[top] = lastPart
			count += 1
			optionalCount += 1
			union = true
		elseif kind == T.Dot3 then
			s:report(s.start, s.finish, "Unexpected '...' after type annotation")
			advance(s)
		else
			break
		end
		if count > limit + optionalCount then
			s.listTop = base
			s.depth = oldDepth
			error({
				parserSignal = "limit",
				start = start,
				finish = s.previousFinish,
				message = "Exceeded allowed type length; simplify your type annotation to make the code compile",
			}, 0)
		end
	end
	if count == 1 and not union and not intersection then
		s.listTop = base
		s.depth = oldDepth
		return lastPart
	end
	local finish: number = if count > 0 then s.finishes[lastPart] else s.previousFinish
	local typesList = commitList(s, base)
	if union and intersection then
		local index = s:report(
			start,
			finish,
			"Mixing union and intersection types is not allowed; consider wrapping in parentheses."
		)
		s.depth = oldDepth
		return nodeAdd(s, {
			kind = K.AstTypeError,
			start = start,
			finish = finish,
			types = typesList,
			isMissing = false,
			messageIndex = index,
		})
	end
	s.depth = oldDepth
	return nodeAdd(s, {
		kind = if union then K.AstTypeUnion else K.AstTypeIntersection,
		start = start,
		finish = finish,
		types = typesList,
	})
end
@native
local function parseFunctionTypeTail(
	s: any,
	start: number,
	parenEnd: number,
	attributes: number,
	generics: number,
	packs: number,
	argTypesList: number,
	argNamesList: number,
	tail: number,
	headCount: number
): number
	local oldDepth: number = s.depth
	local d: number = oldDepth + 1
	s.depth = d
	if d > s.recursionLimit then
		s:raiseRecursion("type annotation")
	end
	if s.kind == 58 then
		advance(s)
		s:report(
			s.previousStart,
			s.previousFinish,
			"Return types in function type annotations are written after '->' instead of ':'"
		)
	elseif s.kind ~= T.SkinnyArrow and generics == 0 and packs == 0 and headCount == 0 then
		s:report(start, s.previousFinish, "Expected '->' after '()' when parsing function type; did you mean 'nil'?")
		s.depth = oldDepth
		return ref(s, start, parenEnd, s:symbolFor("nil"))
	else
		expect(s, T.SkinnyArrow, "function type")
	end
	local returns = parseTypePack(s)
	s.depth = oldDepth
	return nodeAdd(s, {
		kind = K.AstTypeFunction,
		start = start,
		finish = s.finishes[returns],
		attributes = attributes,
		generics = generics,
		genericPacks = packs,
		argTypes = argTypesList,
		argTailType = tail,
		argNames = argNamesList,
		returnTypes = returns,
	})
end
@native
local function functionType(s: any, allowPack: boolean, attributes: number?): number
	local oldDepth: number = s.depth
	local d: number = oldDepth + 1
	s.depth = d
	if d > s.recursionLimit then
		s:raiseRecursion("type annotation")
	end
	local start: number = s.start
	local forced = s.kind == 60
	local generics, packs = parseGenerics(s, false)
	local parenStart: number = s.start
	local parenKind: number = s.kind
	expect(s, 40, "function parameters")
	s:recoveryPush(T.SkinnyArrow)
	local listBase: number = s.listTop
	local auxBase: number = s.auxTop
	local hasNames, tail, headCount = false, 0, 0
	if s.kind ~= 41 then
		hasNames, tail, headCount = typeList(s)
	end
	local closeFinish: number = s.finish
	expectClose(s, 41, parenKind, parenStart, true)
	s:recoveryPop(T.SkinnyArrow)
	forced = forced or hasNames
	local returnIntro = s.kind == T.SkinnyArrow or s.kind == 58
	if headCount == 1 and tail == 0 and not forced and not returnIntro then
		local first = s.listScratch[listBase + 1]
		s.auxTop = auxBase
		if allowPack then
			local listId = commitList(s, listBase)
			s.depth = oldDepth
			return explicitPackFromList(s, start, start + 1, listId, 0)
		end
		s.listTop = listBase
		s.depth = oldDepth
		return nodeAdd(s, { kind = K.AstTypeGroup, start = parenStart, finish = closeFinish, type = first })
	end
	if not forced and not returnIntro and allowPack then
		local listId = commitList(s, listBase)
		s.auxTop = auxBase
		s.depth = oldDepth
		return explicitPackFromList(s, start, start + 1, listId, tail)
	end
	local argTypesList = commitList(s, listBase)
	local argNamesList = if hasNames then commitAux(s, auxBase) else 0
	if not hasNames then
		s.auxTop = auxBase
	end
	local fn = parseFunctionTypeTail(
		s,
		start,
		parenStart + 1,
		attributes or 0,
		generics,
		packs,
		argTypesList,
		argNamesList,
		tail,
		headCount
	)
	s.depth = oldDepth
	return fn
end
@native
local function parseIndexer(s: any, start: number, access: number, accessStart: number?): number
	local key = parseType(s)
	expectClose(s, 93, 91, start)
	expect(s, 58, "table field")
	local value = parseType(s)
	return nodeAdd(s, {
		kind = K.AstTableIndexer,
		start = start,
		finish = s.finishes[value],
		indexType = key,
		resultType = value,
		access = access,
		accessStart = accessStart,
	})
end
@native
local function tableType(s: any, declaration: boolean): number
	local oldDepth: number = s.depth
	local d: number = oldDepth + 1
	s.depth = d
	if d > s.recursionLimit then
		s:raiseRecursion("type annotation")
	end
	local start: number = s.start
	advance(s)
	local base: number = s.listTop
	local listScratch = s.listScratch
	local propCount = 0
	local idx = 0
	while s.kind ~= 125 and s.kind ~= T.Eof do
		local before: number = s.start
		local access, accessStart = 3, nil
		if s.kind == T.Name and (s.value == "read" or s.value == "write") and peek(s.lexer) ~= 58 then
			access = if s.value == "read" then 1 else 2
			accessStart = s.start
			advance(s)
		end
		if s.kind == 91 then
			advance(s)
			local bracketStart: number = s.previousStart
			if (s.kind == T.QuotedString or s.kind == T.RawString) and peek(s.lexer) == 93 then
				local value = s.value
				advance(s)
				expectClose(s, 93, 91, bracketStart)
				expect(s, 58, "table field")
				local ty = parseType(s)
				if type(value) ~= "string" or string.find(value, "\0", 1, true) then
					s:report(bracketStart, bracketStart + 1, "String literal contains malformed escape sequence or \\0")
				else
					local propId = nodeAdd(s, {
						kind = K.AstTableProp,
						start = bracketStart,
						finish = bracketStart + 1,
						name = s:symbolFor(value),
						type = ty,
						access = access,
						accessStart = accessStart,
					})
					local top: number = s.listTop + 1
					s.listTop = top
					listScratch[top] = propId
					propCount += 1
				end
			else
				local item = parseIndexer(s, bracketStart, access, accessStart)
				if idx ~= 0 then
					s:report(bracketStart, s.previousFinish, "Cannot have more than one table indexer")
				else
					idx = item
				end
			end
		elseif propCount == 0 and idx == 0 and not (s.kind == T.Name and peek(s.lexer) == 58) then
			local value = parseType(s)
			local key = ref(s, start, start, s:symbolFor("number"))
			idx = nodeAdd(s, {
				kind = K.AstTableIndexer,
				start = s.starts[value],
				finish = s.finishes[value],
				indexType = key,
				resultType = value,
				access = access,
				accessStart = accessStart,
			})
			break
		else
			local name: number, a: number, b: number
			if s.kind == T.Name then
				name, a, b = s.symbol, s.start, s.finish
				advance(s)
			else
				name, a, b = expectName(s, "table field")
				if b == a then
					break
				end
			end
			expect(s, 58, "table field")
			local value = parseType(s, declaration)
			local propId = nodeAdd(s, {
				kind = K.AstTableProp,
				start = a,
				finish = b,
				name = name,
				type = value,
				access = access,
				accessStart = accessStart,
			})
			local top: number = s.listTop + 1
			s.listTop = top
			listScratch[top] = propId
			propCount += 1
		end
		if s.kind == 44 or s.kind == 59 then
			advance(s)
		else
			break
		end
		if s.start == before then
			break
		end
	end
	local propsList = commitList(s, base)
	local finish: number = s.finish
	if not expectClose(s, 125, 123, start, true) then
		finish = s.previousFinish
	end
	s.depth = oldDepth
	return nodeAdd(s, {
		kind = K.AstTypeTable,
		start = start,
		finish = finish,
		props = propsList,
		indexer = idx,
	})
end
@native
function parseSimple(s: any, allowPack: boolean?, declaration: boolean?): number
	local oldDepth: number = s.depth
	local d: number = oldDepth + 1
	s.depth = d
	if d > s.recursionLimit then
		s:raiseRecursion("type annotation")
	end
	local start: number, finish: number, kind: number = s.start, s.finish, s.kind
	local id: number
	if kind == T.Name then
		local name: number, rawName, a: number, b: number = s.symbol, s.value, start, finish
		advance(s)
		local prefix, prefixStart, prefixFinish, prefixLocal = 0, 0, 0, 0
		if s.kind == 46 then
			local dot: number = s.start
			advance(s)
			prefix, prefixStart, prefixFinish, prefixLocal = name, a, b, s:lookup(name)
			name, a, b = expectName(s, "field name")
			if a == b and s.kind >= T.Reserved_BEGIN and s.kind < T.Reserved_END then
				if s:sameLine(dot, s.start) then
					name = s:symbolFor(string.lower(string.sub(T.names[s.kind], 9)))
					b = s.finish
					advance(s)
				end
			end
		elseif s.kind == T.Dot3 then
			s:report(s.start, s.finish, "Unexpected '...' after type name; type pack is not allowed in this context")
			advance(s)
		elseif rawName == "typeof" then
			local openKind: number, openStart: number = s.kind, s.start
			expect(s, 40, "typeof type")
			local expr = s.parseExpression(s)
			local ending: number = s.finish
			expectClose(s, 41, openKind, openStart)
			s.depth = oldDepth
			return nodeAdd(s, { kind = K.AstTypeTypeof, start = start, finish = ending, expr = expr })
		end
		local hasParams = s.kind == 60
		local parameters = if hasParams then TypeParser.parseTypeParams(s) else 0
		id = nodeAdd(s, {
			kind = K.AstTypeReference,
			start = start,
			finish = s.previousFinish,
			name = name,
			prefix = prefix,
			prefixLocal = prefixLocal,
			prefixStart = prefixStart,
			prefixFinish = prefixFinish,
			nameStart = a,
			nameFinish = b,
			parameters = parameters,
			hasParameterList = hasParams,
		})
	elseif kind == 123 then
		id = tableType(s, declaration or false)
	elseif kind == 40 or kind == 60 then
		id = functionType(s, allowPack or false)
	elseif kind == T.ReservedNil then
		advance(s)
		id = ref(s, start, finish, s:symbolFor("nil"))
	elseif kind == T.ReservedTrue or kind == T.ReservedFalse then
		advance(s)
		id = nodeAdd(
			s,
			{ kind = K.AstTypeSingletonBool, start = start, finish = finish, value = kind == T.ReservedTrue }
		)
	elseif kind == T.QuotedString or kind == T.RawString then
		local value = s.value
		advance(s)
		id = if value ~= nil
			then nodeAdd(s, { kind = K.AstTypeSingletonString, start = start, finish = finish, value = value })
			else typeError(s, start, finish, "String literal contains malformed escape sequence")
	elseif kind == T.Attribute or kind == T.AttributeOpen then
		if not declaration then
			s.depth = oldDepth
			return typeError(s, start, finish, "attributes are not allowed in declaration context")
		end
		local attributes = s.parseAttributes(s)
		id = functionType(s, allowPack or false, attributes)
	elseif kind == T.InterpStringBegin or kind == T.InterpStringSimple then
		s.parseExpression(s)
		id = typeError(s, start, finish, "Interpolated string literals cannot be used as types")
	elseif kind == T.BrokenString then
		advance(s)
		id = typeError(s, start, finish, "Malformed string; did you forget to finish it?")
	elseif kind == T.ReservedFunction then
		advance(s)
		id = typeError(
			s,
			start,
			finish,
			"Using 'function' as a type annotation is not supported, consider replacing with a function type annotation e.g. '(...any) -> ...any'"
		)
	else
		local a: number = s.previousFinish
		local index = s:report(a, finish, "Expected type, got " .. s:tokenName())
		id = nodeAdd(s, {
			kind = K.AstTypeError,
			start = a,
			finish = start,
			types = 0,
			isMissing = true,
			messageIndex = index,
		})
	end
	s.depth = oldDepth
	return id
end
@native
function parseType(s: any, declaration: boolean?): number
	if not s.arena.hasTypeAnnotations then
		s.arena.hasTypeAnnotations = true
	end
	local start: number = s.start
	local inner = 0
	if s.kind ~= 124 and s.kind ~= 38 then
		inner = parseSimple(s, false, declaration)
	end
	local nextKind: number = s.kind
	if inner ~= 0 and nextKind ~= 124 and nextKind ~= 38 and nextKind ~= 63 and nextKind ~= T.Dot3 then
		return inner
	end
	return suffix(s, inner, start)
end
@native
function parseTypePack(s: any, argument: boolean?): number
	if not s.arena.hasTypeAnnotations then
		s.arena.hasTypeAnnotations = true
	end
	local oldDepth: number = s.depth
	local d: number = oldDepth + 1
	s.depth = d
	if d > s.recursionLimit then
		s:raiseRecursion("type annotation")
	end
	local start: number = s.start
	local result: number
	if isPack(s) then
		result = genericPack(s)
	elseif argument then
		local ty = parseType(s)
		result = nodeAdd(s, { kind = K.AstTypePackVariadic, start = start, finish = s.finishes[ty], variadicType = ty })
	elseif s.kind == 40 then
		advance(s)
		s:recoveryPush(T.SkinnyArrow)
		local listBase: number = s.listTop
		local auxBase: number = s.auxTop
		local hasNames, tail, headCount = false, 0, 0
		if s.kind ~= 41 then
			hasNames, tail, headCount = typeList(s)
		end
		local finish: number = s.finish
		expectClose(s, 41, 40, start, true)
		s:recoveryPop(T.SkinnyArrow)
		if s.kind ~= T.SkinnyArrow and not hasNames then
			s.auxTop = auxBase
			if headCount == 1 then
				local inner = s.listScratch[listBase + 1]
				s.listTop = listBase
				local follow = s.kind == 124 or s.kind == 38 or s.kind == 63
				if tail == 0 and (not s.profile.LuauSingleTypeOptionalPackReturnsAttributeParens or follow) then
					inner = nodeAdd(s, { kind = K.AstTypeGroup, start = start, finish = finish, type = inner })
				end
				local suffixed = suffix(s, inner, start)
				result = explicitPackFromList(s, start, finish, arenaList1(s.arena, suffixed), tail)
			else
				result = explicitPackFromList(s, start, finish, commitList(s, listBase), tail)
			end
		else
			local argTypesList = commitList(s, listBase)
			local argNamesList = if hasNames then commitAux(s, auxBase) else 0
			if not hasNames then
				s.auxTop = auxBase
			end
			local fn = parseFunctionTypeTail(s, start, start + 1, 0, 0, 0, argTypesList, argNamesList, tail, headCount)
			result = explicitPackFromList(s, start, s.finishes[fn], arenaList1(s.arena, fn), 0)
		end
	else
		local ty = parseType(s)
		result = nodeAdd(s, {
			kind = K.AstTypePackExplicit,
			start = start,
			finish = s.finishes[ty],
			types = arenaList1(s.arena, ty),
			tailType = 0,
		})
	end
	s.depth = oldDepth
	return result
end
@native
function parseGenerics(s: any, defaults: boolean?): (number, number)
	if s.kind ~= 60 then
		return 0, 0
	end
	if not s.arena.hasTypeAnnotations then
		s.arena.hasTypeAnnotations = true
	end
	local openStart: number = s.start
	advance(s)
	local typesBase: number = s.listTop
	local packsBase: number = s.auxTop
	local listScratch = s.listScratch
	local auxScratch = s.auxScratch
	local seenPack, seenDefault = false, false
	while true do
		local before: number = s.start
		local name: number, start: number, finish: number
		if s.kind == T.Name then
			name, start, finish = s.symbol, s.start, s.finish
			advance(s)
		else
			start, finish = s.start, s.finish
			name = expectName(s)
		end
		local hasDots = s.kind == T.Dot3
		if hasDots then
			advance(s)
		end
		local pack = hasDots or seenPack
		if pack then
			if not hasDots then
				s:report(s.start, s.finish, "Generic types come before generic type packs")
			end
			seenPack = true
		end
		local value = 0
		if defaults and s.kind == 61 then
			advance(s)
			seenDefault = true
			if pack then
				if isPack(s) then
					value = genericPack(s)
				else
					local valStart: number = s.start
					local simpleVal = parseSimple(s, true, false)
					if isTypePack(s.kinds[simpleVal]) then
						value = simpleVal
					else
						local fullVal = suffix(s, simpleVal, valStart)
						s:report(s.starts[fullVal], s.finishes[fullVal], "Expected type pack after '=', got type")
						value = 0
					end
				end
			else
				value = parseType(s)
			end
		elseif seenDefault then
			s:report(
				s.start,
				s.finish,
				if pack
					then "Expected default type pack after type pack name"
					else "Expected default type after type name"
			)
		end
		local item = nodeAdd(s, {
			kind = if pack then K.AstGenericTypePack else K.AstGenericType,
			start = start,
			finish = finish,
			name = name,
			defaultValue = value,
		})
		if pack then
			local top: number = s.auxTop + 1
			s.auxTop = top
			auxScratch[top] = item
		else
			local top: number = s.listTop + 1
			s.listTop = top
			listScratch[top] = item
		end
		if s.kind ~= 44 then
			break
		end
		advance(s)
		if s.kind == 62 then
			s:report(s.start, s.finish, "Expected type after ',' but got '>' instead")
			break
		end
		if before == s.start then
			break
		end
	end
	expectClose(s, 62, 60, openStart)
	return commitList(s, typesBase), commitAux(s, packsBase)
end
@native
function TypeParser.parseTypeStatement(s: any, start: number?, exported: boolean?): number
	if not s.arena.hasTypeAnnotations then
		s.arena.hasTypeAnnotations = true
	end
	local begin = start or s.start
	if s:isName("type") then
		advance(s)
	end
	if s.kind == T.ReservedFunction then
		local functionStart = s.start
		advance(s)
		local missing = s.kind ~= T.Name
		local tokStart, tokFinish = s.start, s.finish
		local name, a, b = expectName(s, "type function name")
		if missing then
			a, b = tokStart, tokFinish
		end
		local before = #s.diagnostics
		s:recoveryPush(T.ReservedEnd)
		local oldDepth = s.typeFunctionDepth
		s.typeFunctionDepth = s.functionDepth + 1
		local oldInClass = s.inClassMethodBody
		if s.hasClasses then
			s.inClassMethodBody = false
		end
		local body = s.parseFunction(s, functionStart, false, nil, name)
		s.typeFunctionDepth = oldDepth
		if s.hasClasses then
			s.inClassMethodBody = oldInClass
		end
		s:recoveryPop(T.ReservedEnd)
		return nodeAdd(s, {
			kind = K.AstStatTypeFunction,
			start = begin,
			finish = s.finishes[body],
			name = name,
			nameStart = a,
			nameFinish = b,
			body = body,
			exported = exported or false,
			hasErrors = #s.diagnostics > before,
		})
	end
	local missing = s.kind ~= T.Name
	local tokStart, tokFinish = s.start, s.finish
	local name, a, b = expectName(s, "type name")
	if missing then
		a, b = tokStart, tokFinish
	end
	local generics, packs = parseGenerics(s, true)
	expect(s, 61, "type alias")
	local ty = parseType(s)
	return nodeAdd(s, {
		kind = K.AstStatTypeAlias,
		start = begin,
		finish = s.finishes[ty],
		name = name,
		nameStart = a,
		nameFinish = b,
		generics = generics,
		genericPacks = packs,
		type = ty,
		exported = exported or false,
	})
end
TypeParser.parseType = parseType
TypeParser.parseTypePack = parseTypePack
TypeParser.parseGenerics = parseGenerics
TypeParser.typeError = typeError
TypeParser.explicitPack = explicitPack
TypeParser.parseIndexer = parseIndexer
@native
function TypeParser.parseTypeParams(s: any): number
	if not s.arena.hasTypeAnnotations then
		s.arena.hasTypeAnnotations = true
	end
	local opener: number = s.start
	expect(s, 60)
	local base: number = s.listTop
	local listScratch = s.listScratch
	local empty = true
	while s.kind ~= T.Eof do
		local id: number
		if isPack(s) then
			id = genericPack(s)
		elseif s.kind == 40 then
			local groupStart: number = s.start
			id = parseSimple(s, true, false)
			local node = s.nodes[id]
			if
				node.kind == K.AstTypePackExplicit
				and node.tailType == 0
				and s.arena:listCount(node.types) == 1
				and (s.kind == 124 or s.kind == 38 or s.kind == 63)
			then
				local inner = s.arena:listAt(node.types, 1)
				local group = nodeAdd(
					s,
					{ kind = K.AstTypeGroup, start = s.starts[inner], finish = s.finishes[inner], type = inner }
				)
				id = suffix(s, group, groupStart)
			elseif not isTypePack(node.kind) then
				id = suffix(s, id, groupStart)
			end
		elseif s.kind == 62 and empty then
			break
		else
			id = parseType(s)
		end
		empty = false
		local top: number = s.listTop + 1
		s.listTop = top
		listScratch[top] = id
		if s.kind ~= 44 then
			break
		end
		advance(s)
	end
	local listId = commitList(s, base)
	expectClose(s, 62, 60, opener)
	return listId
end
return TypeParser
