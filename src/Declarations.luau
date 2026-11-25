--!strict
-- Fresh Luau 0.748 declaration/class parser translation. Upstream MIT LICENSE.md.
local T = require("./Token")
local Arena = require("./Arena")
local K = Arena.Kinds
local Declarations = {}
local Runtime = require("./RuntimeParser")
local TypeParser = require("./TypeParser")
local typeError = TypeParser.typeError
local explicitPack = TypeParser.explicitPack
local parseIndexer = TypeParser.parseIndexer
local ZERO_LOCATION = table.freeze({ start = 0, finish = 0 })
local function declarationArguments(s: any, method: boolean?): ({ number }, { number }, number, boolean, any)
	local opener, startToken = s.kind, s.start
	s:expect(40, if method then "function parameter list start" else "global function declaration")
	local params, names = {}, {}
	local tail = 0
	local vararg = false
	local varargLocation = ZERO_LOCATION
	if s.kind ~= 41 then
		repeat
			if s.kind == T.Dot3 then
				vararg = true
				varargLocation = { start = s.start, finish = s.finish }
				s:advance()
				if s:consume(58) then
					tail = TypeParser.parseTypePack(s, true)
				end
				break
			end
			local name, a, b = s:expectName("variable name")
			local annotation = 0
			if s:consume(58) then
				annotation = TypeParser.parseType(s)
			end
			params[#params + 1] = annotation
			names[#names + 1] = s:node({ kind = K.AstArgumentName, start = a, finish = b, name = name })
		until not s:consume(44)
	end
	s:expectClose(41, opener, startToken)
	return params, names, tail, vararg, varargLocation
end
local function declareFunction(s: any, start: number, attributes: number?): number
	s:advance()
	local name, a, b = s:expectName("global function name")
	local generics, packs = TypeParser.parseGenerics(s, false)
	local params, names, tail, vararg, varargLocation = declarationArguments(s)
	local returns = if s:consume(58) then TypeParser.parseTypePack(s) else explicitPack(s, s.start, s.finish, nil, 0)
	local finish = s.finish
	local missingAnnotation = vararg and tail == 0
	if not missingAnnotation then
		for _, annotation in params do
			if annotation == 0 then
				missingAnnotation = true
				break
			end
		end
	end
	if missingAnnotation then
		local ix = s:report(start, finish, "All declaration parameters must be annotated")
		return s:node({
			kind = K.AstStatError,
			start = start,
			finish = finish,
			expressions = 0,
			statements = 0,
			messageIndex = ix,
		})
	end
	return s:node({
		kind = K.AstStatDeclareFunction,
		start = start,
		finish = finish,
		attributes = attributes or 0,
		name = name,
		nameStart = a,
		nameFinish = b,
		generics = generics,
		genericPacks = packs,
		params = s:list(params),
		paramNames = s:list(names),
		paramTailType = tail,
		vararg = vararg,
		varargLocation = varargLocation,
		retTypes = returns,
	})
end
local function externMethod(s: any, props: { number }, attrs: number)
	local begin = s.start
	s:advance()
	local member, a, b = s:expectName("function name")
	local params, names, tail, isVararg = declarationArguments(s, true)
	local returns = if s:consume(58) then TypeParser.parseTypePack(s) else explicitPack(s, s.start, s.finish, nil, 0)
	local first = names[1] and s.nodes[names[1]]
	local finish = s.previousFinish
	if not first or s.arena.symbols[first.name] ~= "self" or params[1] ~= 0 then
		local ty = typeError(s, begin, finish, "'self' must be present as the unannotated first parameter")
		props[#props + 1] = s:node({
			kind = K.AstDeclaredExternTypeProperty,
			start = 0,
			finish = 0,
			name = member,
			nameStart = a,
			nameFinish = b,
			ty = ty,
			isMethod = true,
			access = 3,
		})
		return
	end
	table.remove(params, 1)
	table.remove(names, 1)
	for index, annotation in params do
		if annotation == 0 then
			params[index] =
				typeError(s, begin, finish, "All declaration parameters aside from 'self' must be annotated")
		end
	end
	if isVararg and tail == 0 then
		s:report(begin, begin + 8, "All declaration parameters aside from 'self' must be annotated")
	end
	local ty = s:node({
		kind = K.AstTypeFunction,
		start = begin,
		finish = finish,
		attributes = attrs,
		generics = 0,
		genericPacks = 0,
		argTypes = s:list(params),
		argTailType = tail,
		argNames = s:list(names),
		returnTypes = returns,
	})
	props[#props + 1] = s:node({
		kind = K.AstDeclaredExternTypeProperty,
		start = begin,
		finish = finish,
		name = member,
		nameStart = a,
		nameFinish = b,
		ty = ty,
		isMethod = true,
		access = 3,
	})
end
local function checkExternKeyword(s: any, fixUnicode: boolean, expected: string, messagePrefix: string): boolean
	if s:isName(expected) then
		s:advance()
		return true
	end
	local got = if fixUnicode and s.kind ~= T.Name then s:tokenName() else tostring(s.value)
	s:report(s.start, s.finish, messagePrefix .. got .. " instead")
	return false
end
local function externBracket(s: any, props: { number }, idx: number): number
	local begin = s.previousStart
	if (s.kind == T.QuotedString or s.kind == T.RawString) and s:peek() == 93 then
		local value, a, b = s.value, s.start, s.finish
		s:advance()
		s:expectClose(93, 91, begin)
		s:expect(58, "property type annotation")
		local ty = TypeParser.parseType(s)
		if type(value) == "string" and not string.find(value, "\0", 1, true) then
			props[#props + 1] = s:node({
				kind = K.AstDeclaredExternTypeProperty,
				start = begin,
				finish = s.previousFinish,
				name = s:symbolFor(value),
				nameStart = a,
				nameFinish = b,
				ty = ty,
				isMethod = false,
				access = 3,
			})
		else
			s:report(begin, begin + 1, "String literal contains malformed escape sequence or \\0")
		end
		return idx
	end
	local item = parseIndexer(s, begin, 3)
	if idx ~= 0 then
		s:report(begin, s.previousFinish, "Cannot have more than one indexer on an extern type")
		return idx
	end
	return item
end
local function externProperty(s: any, props: { number }): boolean
	local access = 3
	if s.kind == T.Name and (s.value == "read" or s.value == "write") and s:peek() ~= 58 then
		access = if s.value == "read" then 1 else 2
		s:advance()
	elseif s.kind == T.Name and s:peek() ~= 58 then
		s:report(s.start, s.finish, "Expected blank or 'read' or 'write' attribute, got '" .. tostring(s.value) .. "'")
		s:advance()
	end
	local member, a, b = s:expectName("property name")
	if a == b then
		return false
	end
	s:expect(58, "property type annotation")
	local ty = TypeParser.parseType(s)
	props[#props + 1] = s:node({
		kind = K.AstDeclaredExternTypeProperty,
		start = a,
		finish = s.previousFinish,
		name = member,
		nameStart = a,
		nameFinish = b,
		ty = ty,
		isMethod = false,
		access = access,
	})
	return true
end
local function declareExternType(s: any): number
	local fixUnicode = s.profile.LuauDeclarationFixCrashOnBadUnicode == true
	s:advance()
	if not checkExternKeyword(s, fixUnicode, "type", "Expected `type` keyword after `extern`, but got ") then
		return s:node({
			kind = K.AstStatError,
			start = s.start,
			finish = s.finish,
			expressions = 0,
			statements = 0,
			messageIndex = math.max(0, #s.diagnostics - 1),
		})
	end
	local classStart = s.start
	local name = s:expectName("type name")
	local super = 0
	if s:isName("extends") then
		s:advance()
		super = s:expectName("supertype name")
	end
	checkExternKeyword(
		s,
		fixUnicode,
		"with",
		"Expected `with` keyword before listing properties of the external type, but got "
	)
	local props = {}
	local idx = 0
	while s.kind ~= T.ReservedEnd and s.kind ~= T.Eof do
		local before = s.start
		local attrs = 0
		if s.kind == T.Attribute or s.kind == T.AttributeOpen then
			attrs = Runtime.attributes(s)
			if s.kind ~= T.ReservedFunction then
				local ix = s:report(
					s.start,
					s.finish,
					"Expected a method type declaration after attribute, but got " .. s:tokenName() .. " instead"
				)
				return s:node({
					kind = K.AstStatError,
					start = s.start,
					finish = s.finish,
					expressions = 0,
					statements = 0,
					messageIndex = ix,
				})
			end
		end
		if s.kind == T.ReservedFunction then
			externMethod(s, props, attrs)
		elseif s:consume(91) then
			idx = externBracket(s, props, idx)
		elseif not externProperty(s, props) then
			break
		end
		if before == s.start then
			s:advance()
		end
	end
	local finish = s.finish
	if s.kind ~= T.Eof then
		s:advance()
	end
	return s:node({
		kind = K.AstStatDeclareExternType,
		start = classStart,
		finish = finish,
		name = name,
		superName = super,
		props = s:list(props),
		indexer = idx,
	})
end
function Declarations.declareStat(s: any, start: number, attributes: number?): number
	s.arena.hasTypeAnnotations = true
	if s.kind == T.ReservedFunction then
		return declareFunction(s, start, attributes)
	elseif s:isName("extern") then
		return declareExternType(s)
	elseif s.kind == T.Name then
		local name, a, b = s:expectName("global variable name")
		s:expect(58, "global variable declaration")
		local ty = TypeParser.parseType(s, true)
		return s:node({
			kind = K.AstStatDeclareGlobal,
			start = start,
			finish = s.nodes[ty].finish,
			name = name,
			nameStart = a,
			nameFinish = b,
			type = ty,
		})
	else
		local declFinish = s.previousFinish
		s:expectName("global variable name")
		local ix =
			s:report(start, declFinish, "declare must be followed by an identifier, 'function', or 'extern type'")
		return s:node({
			kind = K.AstStatError,
			start = start,
			finish = declFinish,
			expressions = 0,
			statements = 0,
			messageIndex = ix,
		})
	end
end
local metamethods: { [string]: boolean } = {
	__init = true,
	__call = true,
	__concat = true,
	__unm = true,
	__add = true,
	__sub = true,
	__mul = true,
	__div = true,
	__mod = true,
	__pow = true,
	__tostring = true,
	__eq = true,
	__lt = true,
	__le = true,
	__iter = true,
	__len = true,
	__idiv = true,
}
local disallowed: { [string]: boolean } =
	{ __index = true, __newindex = true, __mode = true, __metatable = true, __type = true }
local K_MAX_CLASS_PRIVATE_PROPERTIES = 255
local function getClassFieldNameError(name: string, access: string): string?
	if access == "Private" then
		if string.byte(name, 1) == 95 and string.byte(name, 2) == 95 then
			return "Private class properties cannot start with '__'"
		elseif string.byte(name, 1) ~= 95 then
			return "Private class properties must begin with '_'"
		end
	elseif Runtime.isPrivateFieldName(name) then
		return "Public class properties cannot begin with '_'"
	end
	return nil
end
local function classProperty(
	s: any,
	members: { number },
	namespace: { [number]: boolean },
	access: string,
	qualifierStart: number,
	qualifierFinish: number
): boolean
	local missing = s.kind ~= T.Name
	local member, c, d = s:expectName("class property name")
	if missing then
		return false
	end
	local typeColonStart, typeColonFinish = nil, nil
	local ty = 0
	if s.kind == 58 then
		typeColonStart, typeColonFinish = s.start, s.finish
		s:advance()
		ty = TypeParser.parseType(s)
	end
	local text = s.arena.symbols[member]
	local nameErr = getClassFieldNameError(text, access)
	if nameErr then
		s:report(c, d, nameErr)
		return false
	elseif string.byte(text, 1) == 95 and string.byte(text, 2) == 95 then
		s:report(c, d, "Class properties cannot start with '__'")
		return false
	elseif namespace[member] then
		s:report(c, d, "Duplicate class member '" .. text .. "'")
		return false
	else
		namespace[member] = true
		members[#members + 1] = s:node({
			kind = K.AstClassProperty,
			start = c,
			finish = s.previousFinish,
			name = member,
			nameStart = c,
			nameFinish = d,
			ty = ty,
			access = access,
			qualifierStart = qualifierStart,
			qualifierFinish = qualifierFinish,
			typeColonStart = typeColonStart,
			typeColonFinish = typeColonFinish,
		})
		return true
	end
end
local function classMethod(
	s: any,
	members: { number },
	namespace: { [number]: boolean },
	access: string,
	qualifierStart: number?,
	qualifierFinish: number?
): boolean
	local begin, keywordFinish = s.start, s.finish
	s:advance()
	local member, c, d = s:expectName("method name")
	local oldInClassMethodBody = s.inClassMethodBody
	s.inClassMethodBody = true
	s:recoveryPush(T.ReservedEnd)
	local func = Runtime.functionBody(s, begin, false, 0, member)
	s:recoveryPop(T.ReservedEnd)
	s.inClassMethodBody = oldInClassMethodBody
	local argsList = s.nodes[func].args
	if s.arena:listCount(argsList) > 0 then
		local arg = s.bindings[s.arena:listAt(argsList, 1)]
		if s.arena.symbols[arg.name] == "self" and arg.annotation ~= 0 then
			local ty = s.nodes[arg.annotation]
			s:report(ty.start, ty.finish, "The 'self' parameter cannot have a type annotation")
		end
	end
	local duplicated = false
	local text = s.arena.symbols[member]
	local nameErr = getClassFieldNameError(text, access)
	if nameErr then
		s:report(c, d, nameErr)
	elseif disallowed[text] then
		s:report(c, d, "Classes cannot define '" .. text .. "' as a metamethod")
	elseif string.byte(text, 1) == 95 and string.byte(text, 2) == 95 and not metamethods[text] then
		s:report(c, d, "Cannot use '" .. text .. "' as a method name: names starting with '__' are reserved")
	end
	if namespace[member] then
		s:report(c, d, "Duplicate class member '" .. text .. "'")
		duplicated = true
	else
		namespace[member] = true
	end
	if duplicated then
		return false
	else
		members[#members + 1] = s:node({
			kind = K.AstClassMethod,
			start = begin,
			finish = s.nodes[func].finish,
			functionName = member,
			nameStart = c,
			nameFinish = d,
			["function"] = func,
			access = access,
			qualifierStart = qualifierStart,
			qualifierFinish = qualifierFinish,
			functionKeywordStart = begin,
			functionKeywordFinish = keywordFinish,
		})
		return true
	end
end
function Declarations.classDef(s: any, start: number, declModifier: string, open: boolean?): number
	local missingName = s.kind ~= T.Name
	local name, a, b = s:expectName("class name")
	if missingName then
		b = s.finish
	end
	local super = 0
	if s:isName("extends") then
		s:advance()
		super = Runtime.parseClassReference(s)
	end
	local nameLocal = 0
	local nameExpr = 0
	if declModifier == "None" then
		local existing = s:lookup(name)
		if existing ~= 0 then
			local bRec = s.bindings[existing]
			if s.typeFunctionDepth > 0 and bRec.functionDepth < s.typeFunctionDepth then
				local ix = s:report(
					s.start,
					s.finish,
					"Type function cannot assign to outer local '" .. s.arena.symbols[name] .. "'"
				)
				return s:node({
					kind = K.AstStatError,
					start = s.start,
					finish = s.finish,
					expressions = 0,
					statements = 0,
					messageIndex = ix,
				})
			end
			nameExpr = s:node({
				kind = K.AstExprLocal,
				start = a,
				finish = b,
				["local"] = existing,
				upvalue = bRec.functionDepth ~= s.functionDepth,
			})
		else
			nameExpr = s:node({ kind = K.AstExprGlobal, start = a, finish = b, name = name })
		end
		nameExpr = Runtime.lvalue(s, nameExpr, true)
	else
		local isConst = declModifier == "Const" or declModifier == "Export"
		nameLocal = s:bind(name, a, b, 0, isConst)
	end
	local members = {}
	local namespace: { [number]: boolean } = {}
	local privateFieldCount = 0
	local privateMethodCount = 0
	while s.kind ~= T.ReservedEnd and s.kind ~= T.Eof do
		local before = s.start
		local access: string? = nil
		local qualifierStart: number? = nil
		local qualifierFinish: number? = nil
		if s:isName("public") then
			access = "Public"
			qualifierStart, qualifierFinish = s.start, s.finish
			s:advance()
		elseif s:isName("private") then
			access = "Private"
			qualifierStart, qualifierFinish = s.start, s.finish
			s:advance()
		end
		if access ~= nil and s.kind ~= T.ReservedFunction then
			if
				classProperty(s, members, namespace, access, qualifierStart :: number, qualifierFinish :: number)
				and access == "Private"
			then
				privateFieldCount += 1
			end
		elseif s.kind == T.ReservedFunction then
			local methodAccess = access or "Public"
			if
				classMethod(s, members, namespace, methodAccess, qualifierStart, qualifierFinish)
				and methodAccess == "Private"
			then
				privateMethodCount += 1
			end
		else
			s:report(s.start, s.finish, "Only class properties and functions can be declared within a class")
			s:advance()
		end
		if before == s.start then
			s:advance()
		end
	end
	if privateFieldCount > K_MAX_CLASS_PRIVATE_PROPERTIES then
		s:report(
			a,
			b,
			string.format("Exceeded the maximum of %d private fields in a class", K_MAX_CLASS_PRIVATE_PROPERTIES)
		)
	end
	if privateMethodCount > K_MAX_CLASS_PRIVATE_PROPERTIES then
		s:report(
			a,
			b,
			string.format("Exceeded the maximum of %d private methods in a class", K_MAX_CLASS_PRIVATE_PROPERTIES)
		)
	end
	local finish = s.finish
	s:expect(T.ReservedEnd, "class")
	s.arena.hasClasses = true
	return s:node({
		kind = K.AstStatClass,
		start = start,
		finish = finish,
		declModifier = declModifier,
		exprName = nameExpr,
		localName = nameLocal,
		super = super,
		members = s:list(members),
		open = open or false,
	})
end
return Declarations
