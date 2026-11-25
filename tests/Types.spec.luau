--!strict
local Ast = require("../src/Ast")
local Parser = require("../src/Parser")
local sert = require("@sert") :: any

local describe = sert.describe
local test = sert.test
local prop = sert.prop
local expect = sert

local function parseEntry(source: string, entry: string?, options: Parser.ParseOptions?): Parser.ParseResult
	if entry == "type" then
		return Parser.parseType(source, options)
	else
		return Parser.parse(source, options)
	end
end

local function valid(source: string, entry: string?, options: Parser.ParseOptions?): Parser.ParseResult
	local result = parseEntry(source, entry, options)
	expect(
		result.status == "ok",
		source .. "\n" .. (if result.diagnostics[1] then result.diagnostics[1].message else result.status)
	)
	return result
end

describe("Types", function()
	test.each({
		"number",
		"nil",
		"true",
		"false",
		"'literal'",
		"[[long]]",
		"number?",
		"number | string | nil",
		"number & string",
		"(number | string) & T",
		"| number | string",
		"& number & string",
		"{number}",
		"{x:number,y:string}",
		"{[string]:number}",
		"{['x']:number}",
		"{read x:number,write y:string,read [number]:boolean}",
		"typeof(f())",
		"Module.Type<string,number>",
		"Box<>",
		"(number,string)->boolean",
		"(x:number,y:string)->(boolean,string)",
		"<T,U...>(T,U...)->(T,U...)",
		"(...number)->...string",
		"(number,...string)->(boolean,...number)",
		"Box<(number,string),...boolean,U...>",
		"((number)->string)?",
		"(number)",
	})("valid type expression", function(source)
		local result = valid(source, "type", { lossless = true })
		sert.eq(result:reconstruct(), source)
		local a, b = result:range(result.root)
		expect(a >= 0 and b >= a and b <= #source, `valid byte range [{a}, {b}]`)
		expect(Ast.toTables(result) ~= nil, "Ast.toTables succeeds")
	end)

	test.each({
		"type Pair<T,U> = {first:T,second:U}",
		"export type Identity<T=number> = T",
		"type F<T,U...> = (T,U...)->(T,U...)",
		"type A<T=number,U...=(string,boolean)> = F<T,U...>",
		"local x:number=1; local y:typeof(x)=x",
		"local f=function<T,U...>(x:T,...:U...):(T,U...) return x,... end",
		"type function identity(t) return t end",
	})("valid type statement and function annotation", function(source)
		local result = valid(source, nil, { lossless = true })
		sert.eq(result:reconstruct(), source)
	end)

	test("constructs optional unions, binding annotations, and generic defaults", function()
		local grouped = valid("number?", "type")
		local groupTree = assert(Ast.toTables(grouped))
		sert.eq(groupTree.type, "AstTypeUnion")
		sert.eq(#groupTree.types, 2)

		local annotation = valid("local x:number=1")
		local variableStat =
			annotation.arena.nodes[annotation.arena:listAt(annotation.arena.nodes[annotation.root].body, 1)]
		local variableId = annotation.arena:listAt(variableStat.vars, 1)
		local typeId = annotation.arena.bindings[variableId].annotation
		sert.eq(annotation:kindName(typeId), "AstTypeReference")
		sert.eq(annotation:childCount(annotation.arena:listAt(annotation.arena.nodes[annotation.root].body, 1)), 2)

		local generic = valid("type F<T=number,U...=(string,...boolean)> = (x:T,U...)->(T,U...)")
		local alias = generic.arena.nodes[generic.arena:listAt(generic.arena.nodes[generic.root].body, 1)]
		sert.eq(generic.arena:listCount(alias.generics), 1)
		sert.eq(generic.arena:listCount(alias.genericPacks), 1)
		local genericTree = assert(Ast.toTables(generic))
		sert.eq(genericTree.body[1].value.type, "AstTypeFunction")
		sert.eq(genericTree.body[1].value.argNames[1].name, "x")
	end)

	test.each({
		"number & string | boolean",
		"number | string & boolean",
		"()",
		"(number,string)",
		"function",
		"`literal`",
		"{[number]:a,[string]:b}",
		"{['\\0']:number}",
		"'\\256'",
		"Box<number,>",
		"type Foo<> = number",
		"local function f(): (x: number) end",
		"local x: @invalid () -> ()",
		"local x: typeof...",
		"<T... ,U>(T)->T",
		"type A<T=number,U> = T",
		"local f:function=function()end",
	})("invalid type syntax", function(source)
		local entry = if string.sub(source, 1, 4) == "type" or string.sub(source, 1, 5) == "local"
			then "chunk"
			else "type"
		local result = parseEntry(source, entry, { lossless = true })
		sert.eq(result.status, "syntaxError")
		sert.eq(result:reconstruct(), source)
		expect(#result.diagnostics > 0, "reports syntax diagnostic")
	end)

	test("aligns 0.748 type diagnostics, recovery stops, and AstTypeReference flags", function()
		local nonDeclAttr = Parser.parse("local x: @invalid () -> ()")
		expect(#nonDeclAttr.diagnostics >= 1)
		sert.eq(nonDeclAttr.diagnostics[1].message, "attributes are not allowed in declaration context")
		local nonDeclVar = nonDeclAttr.arena.bindings[nonDeclAttr.arena:listAt(
			nonDeclAttr.arena.nodes[nonDeclAttr.arena:listAt(nonDeclAttr.arena.nodes[nonDeclAttr.root].body, 1)].vars,
			1
		)]
		sert.eq(nonDeclAttr:kindName(nonDeclVar.annotation), "AstTypeError")

		local typeofDots = Parser.parse("local x: typeof...")
		sert.eq(#typeofDots.diagnostics, 1)
		sert.eq(
			typeofDots.diagnostics[1].message,
			"Unexpected '...' after type name; type pack is not allowed in this context"
		)

		local emptyGen = Parser.parse("type Foo<> = number")
		sert.eq(#emptyGen.diagnostics, 1)
		sert.eq(emptyGen.diagnostics[1].message, "Expected identifier, got '>'")

		local trailingComma = Parser.parseType("Box<number,>")
		sert.eq(trailingComma.diagnostics[1].message, "Expected type, got '>'")
		local boxRef = trailingComma.arena.nodes[trailingComma.root]
		sert.eq(trailingComma.arena:listCount(boxRef.parameters), 2)
		sert.eq(trailingComma:kindName(trailingComma.arena:listAt(boxRef.parameters, 2)), "AstTypeError")
		sert.eq(boxRef.hasParameterList, true)

		local recFn = Parser.parseType("(a: number -> string")
		sert.eq(#recFn.diagnostics, 1)
		sert.eq(recFn:kindName(recFn.root), "AstTypeFunction")
	end)

	test("rejects unknown profile names, unknown flags, and non-boolean flag values", function()
		sert.throws(function()
			Parser.parseType("number", { profile = "missing" } :: any)
		end, "Unknown parser profile")
		sert.throws(function()
			Parser.parseType("number", { profile = { MissingFlag = true } } :: any)
		end, "Unknown grammar flag")
		sert.throws(function()
			Parser.parseType("number", { profile = { LuauExperimentalWhileLocalSyntax = 1 } } :: any)
		end, "must be boolean")
	end)

	test("gates experimental while-local and declaration syntax by profile", function()
		local whileLocal = valid("while local x = f() do end", nil, { profile = "experimental" })
		local statId = whileLocal.arena:listAt(whileLocal.arena.nodes[whileLocal.root].body, 1)
		sert.eq(whileLocal:kindName(statId), "AstStatWhile")
		expect(whileLocal.arena.nodes[statId].conditionLocal ~= 0, "expected conditionLocal binding")
		sert.eq(Parser.parse("while local x = f() do end").status, "syntaxError")

		for _, source in
			{
				"declare x:number",
				"declare function f(x:number,...:string):(boolean,...number)",
				"declare extern type Foo with x:number end",
			}
		do
			local declaration = valid(source, nil, { allowDeclarationSyntax = true })
			expect(Ast.toTables(declaration) ~= nil, "declaration Ast.toTables")
			sert.eq(Parser.parse(source).status, "syntaxError")
		end
	end)

	test("includes hidden type-pack tails in childCount and childAt traversal", function()
		local tails = valid("(number,...string)->(boolean,...number)", "type")
		local functionNode = tails.arena.nodes[tails.root]
		sert.eq(tails:childCount(tails.root), 3)
		sert.eq(tails:kindName(tails:childAt(tails.root, 2)), "AstTypePackVariadic")
		local returnPack = functionNode.returnTypes
		sert.eq(tails:childCount(returnPack), 2)
		sert.eq(tails:kindName(tails:childAt(returnPack, 2)), "AstTypePackVariadic")
	end)

	prop("composable type expressions round-trip and traverse cleanly", function(g)
		local atoms = { "number", "string", "boolean", "nil", "true", "false", "'tag'", "T", "Module.Item" }
		local function genType(depth: number): string
			if depth <= 0 then
				return g:pick(atoms)
			end
			local kind = g:int(1, 8)
			if kind == 1 then
				return g:pick(atoms)
			elseif kind == 2 then
				return `({genType(depth - 1)}?)`
			elseif kind == 3 then
				return `({genType(depth - 1)} | {genType(depth - 1)})`
			elseif kind == 4 then
				return `({genType(depth - 1)} & {genType(depth - 1)})`
			elseif kind == 5 then
				return `\{ {genType(depth - 1)} \}`
			elseif kind == 6 then
				local access = g:pick({ "", "read ", "write " })
				return `\{ {access}x: {genType(depth - 1)}, [string]: {genType(depth - 1)} \}`
			elseif kind == 7 then
				return `({genType(depth - 1)}, {genType(depth - 1)}) -> ({genType(depth - 1)}, ...string)`
			else
				return `Box<{genType(depth - 1)}, ({genType(depth - 1)})>`
			end
		end

		local source = genType(3)
		g:note(function()
			return `type = {source}`
		end)

		local result = Parser.parseType(source, { lossless = true, requireEOF = true })
		sert.eq(result.status, "ok")
		sert.eq(#result.diagnostics, 0)
		sert.eq(result:reconstruct(), source)
		expect(result.root ~= 0, "root present")
		local tbl = assert(Ast.toTables(result))
		sert.eq(tbl.type, result:kindName(result.root))
	end, { runs = 150 })

	test("enforces typeLengthLimit on union types and parses attributed declaration function types", function()
		local limited = Parser.parseType("number | string | boolean | nil", { typeLengthLimit = 3 })
		sert.eq(limited.status, "limit")
		expect(#limited.diagnostics >= 1, "typeLengthLimit reports limit diagnostic")

		local optAllowed = Parser.parseType("number?????", { typeLengthLimit = 3 })
		sert.eq(optAllowed.status, "ok")

		local declAttr = Parser.parse("declare x: @native (number) -> number", { allowDeclarationSyntax = true })
		sert.eq(declAttr.status, "ok")
		local tbl = assert(Ast.toTables(declAttr))
		sert.eq(tbl.body[1].type, "AstStatDeclareGlobal")
		sert.eq(tbl.body[1].luauType.type, "AstTypeFunction")
		sert.eq(tbl.body[1].luauType.attributes[1].name, "native")

		-- AstStatTypeAlias preserves identifier nameStart/nameFinish spans
		local aliasRes = valid("export type MyAlias<T> = { x: T }")
		local aliasId = aliasRes.arena:listAt(aliasRes.arena.nodes[aliasRes.root].body, 1)
		local aliasNode = aliasRes.arena.nodes[aliasId]
		sert.eq(aliasNode.nameStart, 12)
		sert.eq(aliasNode.nameFinish, 19)
		local aliasTbl = assert(Ast.toTables(aliasRes))
		sert.eq(aliasTbl.body[1].nameStart, 12)
		sert.eq(aliasTbl.body[1].nameFinish, 19)

		-- Generic parameter lists match upstream and do not trigger typeLengthLimit
		local genericAllowed = Parser.parse("type Box<A, B, C, D> = A", { typeLengthLimit = 2 })
		sert.eq(genericAllowed.status, "ok")
		sert.eq(#genericAllowed.diagnostics, 0)
	end)

	test("allows 600 optional types in a union within default typeLengthLimit", function()
		local parts = table.create(600, "number?")
		local res = valid("type BigUnion = " .. table.concat(parts, " | "))
		sert.eq(res.status, "ok")
	end)

	test("sets attributed AstTypeFunction.start after attributes", function()
		local src = "declare f: @[checked] (x: number) -> number"
		local res = valid(src, nil, { profile = "experimental", allowDeclarationSyntax = true })
		local statId = res.arena:listAt(res.arena.nodes[res.root].body, 1)
		local typeId = res.arena.nodes[statId].type
		local fnType = res.arena.nodes[typeId]
		sert.eq(res.arena:kindName(typeId), "AstTypeFunction")
		sert.eq(string.sub(src, fnType.start + 1, fnType.start + 1), "(")
	end)
end)

if not sert._bundled then
	return sert.run(sert.parseCliArgs(...))
end
return nil
