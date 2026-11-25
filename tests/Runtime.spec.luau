--!strict
-- Runtime grammar regression and property tests derived from Luau 0.748 MIT-licensed parser behavior.
local Ast = require("../src/Ast")
local Parser = require("../src/Parser")
local sert = require("@sert") :: any

local describe = sert.describe
local test = sert.test
local prop = sert.prop
local expect = sert

local function parse(source: string, options: Parser.ParseOptions?): Parser.ParseResult
	return Parser.parse(source, options)
end

local function valid(source: string, options: Parser.ParseOptions?): Parser.ParseResult
	local result = parse(source, options)
	expect(
		#result.diagnostics == 0,
		source .. "\n" .. (if result.diagnostics[1] then result.diagnostics[1].message else "")
	)
	return result
end

local function body(s: Parser.ParseResult, id: number?): any
	return s.arena:listItems(s.arena.nodes[id or s.root].body)
end

local function n(s: Parser.ParseResult, id: number): any
	return s.arena.nodes[id]
end

local function k(s: Parser.ParseResult, id: number): string
	return s.arena:kindName(id)
end

describe("Runtime", function()
	test.each({
		"",
		"local x",
		"local x,y=1,2",
		"local a,b:f<number> = f(), ...",
		"a.b[c],x=1,2",
		"a+=1",
		"a..='x'",
		"a//=2",
		"f()",
		"f{1,foo=2,[x]=3}",
		"f'foo'",
		"a:b(1)",
		"local x={1; 2, foo=function() end, [f()]=3}",
		"do local x=1; f(x) end",
		"while f() do if x then break end continue end",
		"repeat local x=f() until x>0",
		"for i=1,10,2 do f(i) end",
		"for k,v in pairs(t) do print(k,v) end",
		"if x then f() elseif y then g() else h() end",
		"function a.b:c(x:number,...:string):(number,string) return x,... end",
		"local function f(n) if n==0 then return 1 end return f(n-1) end",
		"local f=function<T,U...>(x:T,...:U...):(T,U...) return x,... end",
		"local x=if a then b elseif c then d else e",
		"return -2^3^4, a..b..c, a or b and c, #a*2",
		"return (f())",
		"return f()::number",
		"return `a{foo}b{bar}c`",
		"return `a{ {x=`b{c}d`} }e`",
		"@native function f() end",
		"@[native,deprecated({reason='x',use='f'})] local function f() end",
		"local f=@native function() return 1 end",
		"type T={x:number,y:string}; local v:T={x=1,y='a'}",
		"type function f(t) return t end",
		"const x=1",
		"const function f() return f end",
		"local continue=0; continue+=1; continue()",
		"local type=1; type=2; type()",
	})("valid runtime grammar", function(source)
		local result = valid(source, { lossless = true })
		sert.eq(result:reconstruct(), source)
	end)

	test.each({
		"export function f() return f end",
		"export local x=1; export const y=2",
		"@checked declare function extFn(x: number): number",
		'class SubA extends Pkg.Base end\nclass SubB extends Pkg["Base"] end',
	})("valid experimental declarations and attributes", function(source)
		local res = valid(source, { profile = "experimental", allowDeclarationSyntax = true, lossless = true })
		sert.eq(res:reconstruct(), source)
	end)

	test.each({
		{ src = "@[] local function f() end", match = "Attribute list cannot be empty" },
		{
			src = '@[attr1(1, 2), attr2 { k = 1 }, attr3 "str", attr4()] local function g() end',
			match = "Invalid attribute '@attr1'",
		},
		{ src = "@checked declare badVar: number", match = "Expected a function type declaration after attribute" },
		{ src = "@checked x = 1", match = "Expected 'function'" },
	})("malformed attributes preserve lossless recovery", function(tc)
		local res = parse(tc.src, { profile = "experimental", allowDeclarationSyntax = true, lossless = true })
		sert.eq(res.status, "syntaxError")
		sert.eq(res:reconstruct(), tc.src)
		expect(string.find(res.diagnostics[1].message, tc.match, 1, true) ~= nil, res.diagnostics[1].message)
	end)

	test("resolves repeat-until, numeric for, local function, and method self bindings", function()
		local s = valid("local x=1; repeat local x=x until x; for x=x,x do f(x) end; f(x)")
		local stats = body(s)
		local outer = s.arena:listAt(n(s, stats[1]).vars, 1)
		local repeatStat = n(s, stats[2])
		local repeatInner = s.arena:listAt(n(s, body(s, repeatStat.body)[1]).vars, 1)
		sert.eq(n(s, repeatStat.condition)["local"], repeatInner)
		local forStat = n(s, stats[3])
		sert.eq(n(s, forStat.from)["local"], outer)
		sert.eq(n(s, forStat.to)["local"], outer)
		local forCall = n(s, n(s, body(s, forStat.body)[1]).expr)
		sert.eq(n(s, s.arena:listAt(forCall.args, 1))["local"], forStat.var)
		local lastCall = n(s, n(s, stats[4]).expr)
		sert.eq(n(s, s.arena:listAt(lastCall.args, 1))["local"], outer)

		s = valid("local function f() return f end; function obj:method(self) return self end")
		stats = body(s)
		local lf = n(s, stats[1])
		local ref = s.arena:listAt(n(s, body(s, n(s, lf.func).body)[1]).list, 1)
		sert.eq(n(s, ref)["local"], lf.name)
		sert.eq(n(s, ref).upvalue, true)
		local mf = n(s, n(s, stats[2]).func)
		local explicitSelf = s.arena:listAt(mf.args, 1)
		sert.eq(s.arena.bindings[explicitSelf].shadow, mf.self)
		sert.eq(s.arena.symbols[s.arena.bindings[mf.self].name], "self")

		s = valid("local f=1; local function f(x:typeof(f)) return f end")
		stats = body(s)
		local prior = s.arena:listAt(n(s, stats[1]).vars, 1)
		local second = n(s, stats[2])
		local arg = s.arena:listAt(n(s, second.func).args, 1)
		local annotation = n(s, s.arena.bindings[arg].annotation)
		sert.eq(n(s, annotation.expr)["local"], prior)
	end)

	test("enforces operator precedence, right associativity, and string interpolation lists", function()
		local s = valid("return -2^3^4,a..b..c,a or b and c")
		local list = n(s, body(s)[1]).list
		local first = n(s, s.arena:listAt(list, 1))
		sert.eq(first.op, "Minus")
		local power = n(s, first.expr)
		sert.eq(power.op, "Pow")
		sert.eq(n(s, power.right).op, "Pow")
		local concat = n(s, s.arena:listAt(list, 2))
		sert.eq(concat.op, "Concat")
		sert.eq(n(s, concat.right).op, "Concat")
		local logical = n(s, s.arena:listAt(list, 3))
		sert.eq(logical.op, "Or")
		sert.eq(n(s, logical.right).op, "And")

		s = valid("return `x{foo}y{bar}z`")
		local interp = n(s, s.arena:listAt(n(s, body(s)[1]).list, 1))
		sert.eq(s.arena:listCount(interp.strings), 3)
		sert.eq(s.arena:listCount(interp.expressions), 2)
		sert.eq(s.arena:listAt(interp.strings, 2), "y")
	end)

	test("supports experimental if-local and exported value bindings", function()
		local s = valid("if local x=f() then f(x) else f(x) end", { profile = "experimental" })
		local ifStat = n(s, body(s)[1])
		local thenCall = n(s, n(s, body(s, ifStat.thenbody)[1]).expr)
		sert.eq(n(s, s.arena:listAt(thenCall.args, 1))["local"], ifStat.conditionLocal)
		local elseCall = n(s, n(s, body(s, ifStat.elsebody)[1]).expr)
		sert.eq(k(s, s.arena:listAt(elseCall.args, 1)), "AstExprGlobal")

		s = valid("export function f() return f end; export local x=1; export const y=2", { profile = "experimental" })
		local stats = body(s)
		sert.eq(k(s, stats[1]), "AstStatLocalFunction")
		local exportedFunc = n(s, stats[1])
		sert.eq(s.arena.bindings[exportedFunc.name].isConst, true)
		sert.eq(s.arena.bindings[exportedFunc.name].isExported, true)
		sert.eq(n(s, stats[2]).isExported, true)
		sert.eq(n(s, stats[3]).isExported, true)
		valid("@native export function f() end", { profile = "experimental" })
	end)

	test.each({
		"do export local x=1 end",
		"export local x=1; export local x=2",
		"export const x=1; return x",
		"export local function f() end",
		"export const function f() end",
	})("invalid exported value statements", function(source)
		local invalid = parse(source, { profile = "experimental" })
		sert.eq(invalid.status, "syntaxError", source)
		expect(#invalid.diagnostics > 0 and #invalid.diagnostics[1].message > 0, source)
	end)

	test.each({
		"break",
		"continue",
		"function f() return ... end",
		"while x do function f() break end end",
		"(x)=1",
		"const x=1; x=2",
		"const x",
		"@native @native function f() end",
		"@bad function f() end",
		"@[deprecated(1)] function f() end",
		"@[native(f())] function f() end",
		"local x=",
		"return `foo{}`",
		"return 'unfinished",
		"return f(1",
		"local x={1 2}",
		"return 1; f()",
		"for x=1,2 f() end",
		"if x f() end",
		"local f=function( end",
	})("invalid runtime syntax diagnostics", function(source)
		local invalid = parse(source)
		sert.eq(invalid.status, "syntaxError", source)
		expect(#invalid.diagnostics > 0 and #invalid.diagnostics[1].message > 0, source)
	end)

	test("parses generic calls, declarations, while-local, and classes", function()
		local s = valid("while local x = next() do end\nwhile const y = next() do end", {
			profile = "experimental",
		})
		local stats = body(s)
		sert.eq(k(s, stats[1]), "AstStatWhile")
		expect(n(s, stats[1]).conditionLocal ~= 0, "while local binds conditionLocal")
		expect(not s.arena.bindings[n(s, stats[1]).conditionLocal].isConst, "while local is mutable")
		expect(s.arena.bindings[n(s, stats[2]).conditionLocal].isConst, "while const is const")

		valid("return f<<number,T...>>()")
		valid("return o:m<<number,(string,number)>>()")
		valid("declare extern type Foo with function bar(self,x:number):string end", { allowDeclarationSyntax = true })
		valid(
			"declare extern type Sub extends Foo with ['literal']:number read r:number write w:string [number]:boolean @native function m(self,x:number,...:string):boolean end",
			{ allowDeclarationSyntax = true }
		)
		local constConst = valid("const const = 1")
		sert.eq(n(constConst, body(constConst)[1]).isConst, true)
		local expConstConst = valid("export const const = 1", { profile = "experimental" })
		sert.eq(n(expConstConst, body(expConstConst)[1]).isExported, true)
		valid("declare function f(x:number,...:string):number", { allowDeclarationSyntax = true })
		valid(
			"export open class A public x:number private _secret:number public function __init(self) return self.x end private function _calc(self) return self._secret end end;class B extends A public y end",
			{ profile = "experimental" }
		)
		valid("local m={};class A extends m['Base'] end", { profile = "experimental" })

		s = valid("local class A end;local class B extends A end;f(B)", { profile = "experimental" })
		stats = body(s)
		sert.eq(k(s, stats[1]), "AstStatClass")
		sert.eq(n(s, stats[1]).declModifier, "Local")
		local classB = n(s, stats[2]).localName
		local after = n(s, n(s, stats[3]).expr)
		sert.eq(n(s, s.arena:listAt(after.args, 1))["local"], classB)
	end)

	test.each({
		"while local x do end",
		"while const x do end",
		"class A function f(self:number) end end",
		"class A public __x end",
		"class A public x function x() end end",
		"class A function __index(self) end end",
		"class A function __custom(self) end end",
		"class A function f(self) end function f(self) end end",
		"class A x:number end",
		"do export class A end end",
	})("invalid experimental while-local and class forms", function(source)
		local invalid = parse(source, { profile = "experimental" })
		sert.eq(invalid.status, "syntaxError", source)
		expect(#invalid.diagnostics > 0 and #invalid.diagnostics[1].message > 0, source)
	end)

	test.each({
		"declare function f(x)",
		"declare function f(...)",
		"declare extern type X with function f(x:number):string end",
		"declare extern type X with function f(self:number):string end",
		"declare extern type X with function f(self,x):string end",
		"declare extern type X with function f(self,...):string end",
		"declare extern type X with @native x:number end",
		"declare extern type X with ['\\0']:number end",
		"declare extern type X with [number]:string [string]:number end",
		"declare extern type X with bad x:number end",
		"declare extern Foo with x:number end",
		"declare extern type Foo x:number end",
		"declare function f(x:number,)",
		"declare extern type X with a:number, b:string end",
		"declare extern type X with a:number; b:string end",
		"declare 123",
	})("invalid declaration forms", function(source)
		local invalid = parse(source, { allowDeclarationSyntax = true })
		sert.eq(invalid.status, "syntaxError", source)
		expect(#invalid.diagnostics > 0 and #invalid.diagnostics[1].message > 0, source)
	end)

	test("enforces 0.748 diagnostics, confusables, recovery stops, and limits", function()
		local attrGen = parse("@[native({ [1] = 2 })] function f() end")
		expect(
			#attrGen.diagnostics > 0 and string.find(attrGen.diagnostics[1].message, "Only literals", 1, true) ~= nil,
			"attribute table forbids General computed key items"
		)

		local expLocalFn = parse("export local function f() end", { profile = "experimental" })
		expect(
			string.find(expLocalFn.diagnostics[1].message, "try removing 'local'", 1, true) ~= nil,
			expLocalFn.diagnostics[1].message
		)
		local expConstFn = parse("export const function f() end", { profile = "experimental" })
		expect(
			string.find(expConstFn.diagnostics[1].message, "try removing 'const'", 1, true) ~= nil,
			expConstFn.diagnostics[1].message
		)
		local dupExp = parse("export local x=1; export local x=2", { profile = "experimental" })
		expect(
			string.find(dupExp.diagnostics[1].message, "Duplicate exported identifier 'x'", 1, true) ~= nil,
			dupExp.diagnostics[1].message
		)

		local unaryBang = parse("return !a")
		sert.eq(unaryBang.diagnostics[1].message, "Unexpected '!'; did you mean 'not'?")
		local binConf = parse("return a && b || c != d")
		sert.eq(#binConf.diagnostics, 3)
		sert.eq(binConf.diagnostics[1].message, "Unexpected '&&'; did you mean 'and'?")
		sert.eq(binConf.diagnostics[2].message, "Unexpected '||'; did you mean 'or'?")
		sert.eq(binConf.diagnostics[3].message, "Unexpected '!='; did you mean '~='?")

		-- Whitespace between ! and = is not combined as !=
		local spacedBangEq = parse("return a ! = b")
		sert.eq(spacedBangEq.status, "syntaxError")
		expect(
			string.find(spacedBangEq.diagnostics[1].message, "Expected", 1, true) ~= nil,
			spacedBangEq.diagnostics[1].message
		)

		local ifLocalComma = parse("if local x, y = 1 then end", { profile = "experimental" })
		expect(
			string.find(ifLocalComma.diagnostics[1].message, "only a single binding is allowed", 1, true) ~= nil,
			"if local rejects multi-binding"
		)

		local fnReserved = parse("function a.end() end")
		sert.eq(fnReserved.diagnostics[1].message, "Expected identifier when parsing field name, got 'end'")

		local recLocal = parse("local x: { a: number = 1")
		sert.eq(#recLocal.diagnostics, 1)
		local stId = body(recLocal)[1]
		local st = n(recLocal, stId)
		sert.eq(k(recLocal, stId), "AstStatLocal")
		sert.eq(recLocal.arena:listCount(st.values), 1)

		local deepDot = parse("function a" .. string.rep(".b", 12) .. "() end", { recursionLimit = 8 })
		sert.eq(deepDot.status, "limit")

		local errOne = parse("local = ; local = ;", { errorLimit = 1 })
		sert.eq(errOne.status, "limit")
		sert.eq(#errOne.diagnostics, 1)
		expect(string.find(errOne.diagnostics[1].message, "Expected identifier", 1, true) ~= nil)

		local declBad = parse("declare 123", { allowDeclarationSyntax = true })
		sert.eq(k(declBad, body(declBad)[1]), "AstStatError")
		sert.eq(
			declBad.diagnostics[2].message,
			"declare must be followed by an identifier, 'function', or 'extern type'"
		)
	end)

	test.each({
		"a " .. string.rep("? ", 200),
		string.rep("( ", 20),
		"local x={" .. string.rep("[ ", 20),
		"local x = if a then 1" .. string.rep(" elseif b then 2", 120) .. " else 3",
	})("bounded recursion and recovery on repeated malformed forms", function(source)
		local result = parse(source, { errorLimit = 1000, recursionLimit = 100 })
		expect(result.status == "syntaxError" or result.status == "limit", result.status)
	end)

	prop("generated valid runtime programs round-trip and build valid AST tables", function(g)
		local exprPool = {
			"1",
			"true",
			"nil",
			"'str'",
			"x",
			"f(x)",
			"t.field",
			"t[1]",
			"t:m(x)",
			"-x",
			"not x",
			"#t",
			"x + 1",
			"x * 2 ^ 3",
			"a .. b",
			"a and b or c",
			"if x then 1 else 2",
			"`val={x}`",
			"{ 1, a = x, [2] = true }",
			"(x :: number)",
		}
		local function genStatement(step: any): string
			local choice = step:int(1, 8)
			if choice == 1 then
				return `local x = {step:pick(exprPool)}`
			elseif choice == 2 then
				return `const c = {step:pick(exprPool)}`
			elseif choice == 3 then
				return `x += {step:pick(exprPool)}`
			elseif choice == 4 then
				return `if {step:pick(exprPool)} then f(x) else g(x) end`
			elseif choice == 5 then
				return `for i = 1, 3 do f(i) end`
			elseif choice == 6 then
				return `for k, v in pairs(t) do f(k, v) end`
			elseif choice == 7 then
				return `local function fn(a: number): number return a end`
			else
				return `do local y = {step:pick(exprPool)}; f(y) end`
			end
		end
		local statements = g:list(genStatement, 1, 10)
		local source = table.concat(statements, "; ") .. "; return x"
		g:note(function()
			return `source = {source}`
		end)

		local result = Parser.parse(source, { lossless = true })
		sert.eq(result.status, "ok")
		sert.eq(#result.diagnostics, 0)
		sert.eq(result:reconstruct(), source)
		local ast = assert(Ast.toTables(result))
		sert.eq(ast.type, "AstStatBlock")
		sert.eq(#ast.body, #statements + 1)
	end, { runs = 150 })

	test(
		"covers lossless Ast.toTables metadata, root == 0 nil return, export local forms, and Ouro.Tokens alignment",
		function()
			local Ouro = require("../")

			-- root == 0 returns nil
			local emptyRootRes: any = table.clone(Parser.parse("return 1"))
			emptyRootRes.root = 0
			sert.eq(Ast.toTables(emptyRootRes), nil)

			-- Lossless Ast.toTables metadata: access, args, isConst, isExported, typeArguments, constKeywordBegin
			local richRes = valid(
				[[
			export local exportedVar: number = 1
			export function pubFn<T>(a: T) return a end
			export open class PubBox
				private _hidden: number
			end
			@checked local function attrFn()
				return pubFn<<number>>(1)
			end
			const function constFn()
				return 1
			end
		]],
				{ profile = "experimental", lossless = true }
			)
			local richTbl = assert(Ast.toTables(richRes))
			sert.eq(richTbl.body[1].vars[1].isExported, true)
			sert.eq(richTbl.body[1].vars[1].isConst, false)
			sert.eq(richTbl.body[2].name.isExported, true)
			sert.eq(n(richRes, body(richRes)[2]).constKeywordBegin, nil)
			sert.eq(richTbl.body[3].declModifier, "Export")
			sert.eq(richTbl.body[3].localName.isExported, true)
			sert.eq(richTbl.body[3].open, true)
			sert.eq(richTbl.body[3].members[1].access, "Private")
			sert.eq(type(richTbl.body[4].func.attributes[1].args), "table")
			sert.eq(#richTbl.body[4].func.body.body[1].list[1].func.typeArguments, 1)
			sert.eq(n(richRes, body(richRes)[5]).constKeywordBegin ~= nil, true)
			sert.eq(richRes.arena.bindings[n(richRes, body(richRes)[5]).name].isConst, true)

			-- Ouro.Tokens matches Comment.kind and TokenTape.kinds
			local tokRes = Parser.parse("-- hi\nlocal x = 1", { lossless = true, captureComments = true })
			sert.eq(tokRes.comments[1].kind, Ouro.Tokens.Comment)
			local tape = assert(tokRes.tape)
			sert.eq(tape.kinds[1], Ouro.Tokens.Comment)
		end
	)

	test("reports attributed function missing end on the function keyword line", function()
		for _, src in { "@native\nlocal function broken()\n\tlocal x = 1", "@native\nfunction broken()\n\tlocal x = 1" } do
			local res = parse(src)
			sert.eq(res.status, "syntaxError")
			local found = false
			for _, diag in res.diagnostics do
				if string.find(diag.message, "line 2", 1, true) ~= nil then
					found = true
					break
				end
			end
			expect(found, "missing end error must cite line 2 (function) rather than line 1 (@native)")
		end
	end)

	test("checks parameterized attribute literal arguments before unknown/duplicate names", function()
		local src1 = "@[not_known(x)] local function a() end"
		local res1 = parse(src1, { profile = "experimental" })
		sert.eq(res1.status, "syntaxError")
		sert.eq(res1.diagnostics[1].message, "Only literals can be passed as arguments for attributes")

		local src2 = "@[native] @[native] local function b() end"
		local res2 = parse(src2, { profile = "experimental" })
		sert.eq(res2.status, "syntaxError")
		local dupDiag = nil
		for _, diag in res2.diagnostics do
			if string.find(string.lower(diag.message), "duplicate attribute", 1, true) ~= nil then
				dupDiag = diag
				break
			end
		end
		expect(dupDiag ~= nil, "expected duplicate attribute diagnostic")
		if dupDiag then
			sert.eq(string.sub(src2, dupDiag.start + 1, dupDiag.finish), "native")
		end

		local src3 = "@[checked(1)] @[checked(2)] local function c() end"
		local res3 = parse(src3, { profile = "experimental" })
		sert.eq(res3.status, "syntaxError")
		local pDupDiag = nil
		for _, diag in res3.diagnostics do
			if string.find(string.lower(diag.message), "duplicate attribute", 1, true) ~= nil then
				pDupDiag = diag
				break
			end
		end
		expect(pDupDiag ~= nil, "expected parameterized duplicate attribute diagnostic")
		if pDupDiag then
			sert.eq(string.sub(src3, pDupDiag.start + 1, pDupDiag.finish), "checked")
		end
	end)

	test("formats malformed interpolated string diagnostic with trailing question mark", function()
		local res = parse("local s = `hi {1}")
		sert.eq(res.status, "syntaxError")
		local found = false
		for _, diag in res.diagnostics do
			if diag.message == "Malformed interpolated string; did you forget to add a '`'?" then
				found = true
				break
			end
		end
		expect(found, "expected exact trailing '?' diagnostic")
	end)

	test("validates @deprecated tables, attribute targets, export class rules, and class private limits", function()
		local dep1 = parse("@[deprecated{1}] function f() end")
		sert.eq(dep1.status, "syntaxError")
		expect(
			string.find(dep1.diagnostics[1].message, "Only constants keys 'use' and 'reason'", 1, true) ~= nil,
			dep1.diagnostics[1].message
		)

		local dep2 = parse('@[deprecated{bad = "x"}] function f() end')
		sert.eq(dep2.status, "syntaxError")
		expect(
			string.find(dep2.diagnostics[1].message, "Unknown argument 'bad' for @deprecated", 1, true) ~= nil,
			dep2.diagnostics[1].message
		)

		local dep3 = parse("@[deprecated{use = 123}] function f() end")
		sert.eq(dep3.status, "syntaxError")
		expect(
			string.find(dep3.diagnostics[1].message, "Only constant string allowed as value for 'use'", 1, true) ~= nil,
			dep3.diagnostics[1].message
		)

		local declAttrErr = parse("@native declare x: number", { allowDeclarationSyntax = true })
		sert.eq(declAttrErr.status, "syntaxError")
		expect(
			string.find(
				declAttrErr.diagnostics[1].message,
				"Expected a function type declaration after attribute",
				1,
				true
			) ~= nil,
			declAttrErr.diagnostics[1].message
		)

		local localAttrErr = parse("@native local x = 1")
		sert.eq(localAttrErr.status, "syntaxError")
		expect(
			string.find(
				localAttrErr.diagnostics[1].message,
				"Expected 'function' after local declaration with attribute",
				1,
				true
			) ~= nil,
			localAttrErr.diagnostics[1].message
		)

		local statAttrErr = parse("@native return 1")
		sert.eq(statAttrErr.status, "syntaxError")
		expect(
			string.find(
				statAttrErr.diagnostics[1].message,
				"Expected 'function', 'local function', 'const function'",
				1,
				true
			) ~= nil,
			statAttrErr.diagnostics[1].message
		)

		local classNoExportVal: any = {
			profile = { DebugLuauUserDefinedClasses = true, LuauExportValueSyntax = false },
		}
		local okExpCls = valid("export open class C public x: number end", classNoExportVal)
		local clsAst = assert(Ast.toTables(okExpCls))
		sert.eq(clsAst.body[1].type, "AstStatClass")
		sert.eq(clsAst.body[1].localName.isExported, true)

		local nestedExpCls = parse("do export class C end end", classNoExportVal)
		sert.eq(nestedExpCls.status, "syntaxError")
		expect(
			string.find(nestedExpCls.diagnostics[1].message, "top-level statements", 1, true) ~= nil,
			nestedExpCls.diagnostics[1].message
		)

		local conflictExp = parse("if true then return 1 end\nexport local x = 1", { profile = "experimental" })
		sert.eq(conflictExp.status, "syntaxError")
		expect(
			string.find(conflictExp.diagnostics[1].message, "export/return conflict", 1, true) ~= nil,
			conflictExp.diagnostics[1].message
		)

		local existingLocalCls = valid("local Foo = {}\nclass Foo public x: number end", { profile = "experimental" })
		sert.eq(k(existingLocalCls, body(existingLocalCls)[2]), "AstStatClass")

		local outerLocalTypeFn = parse("local Foo = 1\ntype function T()\n\tclass Foo public x: number end\nend", {
			profile = "experimental",
		})
		sert.eq(outerLocalTypeFn.status, "syntaxError")
		expect(
			string.find(outerLocalTypeFn.diagnostics[1].message, "Type function cannot assign to outer local", 1, true)
				~= nil,
			outerLocalTypeFn.diagnostics[1].message
		)

		local fieldLines = table.create(256)
		local methodLines = table.create(256)
		for i = 1, 256 do
			fieldLines[i] = `private _f{i}: number`
			methodLines[i] = `private function _m{i}(self) end`
		end
		local tooManyFields =
			parse("class BigFields\n" .. table.concat(fieldLines, "\n") .. "\nend", { profile = "experimental" })
		sert.eq(tooManyFields.status, "syntaxError")
		sert.eq(#tooManyFields.diagnostics, 1)
		expect(
			string.find(tooManyFields.diagnostics[1].message, "maximum of 255 private fields", 1, true) ~= nil,
			tooManyFields.diagnostics[1].message
		)

		local tooManyMethods =
			parse("class BigMethods\n" .. table.concat(methodLines, "\n") .. "\nend", { profile = "experimental" })
		sert.eq(tooManyMethods.status, "syntaxError")
		sert.eq(#tooManyMethods.diagnostics, 1)
		expect(
			string.find(tooManyMethods.diagnostics[1].message, "maximum of 255 private methods", 1, true) ~= nil,
			tooManyMethods.diagnostics[1].message
		)

		local extraParserDiagCases: { { src: string, opts: Parser.ParseOptions?, substr: string } } = {
			{
				src = "local x = 1\ntype function T()\n\treturn x\nend",
				opts = { profile = "experimental" },
				substr = "Type function cannot reference outer local 'x'",
			},
			{
				src = "const x = 1\nx = 2",
				opts = { profile = { LuauExportValueSyntax = true } },
				substr = "is constant and may not be reassigned",
			},
			{ src = "f\n(1)", substr = "Ambiguous syntax" },
			{ src = "local a = f\n(1)", substr = "Ambiguous syntax" },
			{ src = "local s = `a\\xZZb`", substr = "malformed escape sequence" },
			{ src = "local s = `a {1} {{`", substr = "Double braces are not permitted" },
			{
				src = "export open foo = 1",
				opts = { profile = "experimental" },
				substr = "class definition after 'open'",
			},
			{
				src = "@native export local x = 1",
				opts = { profile = "experimental" },
				substr = "Expected 'function' after export declaration with attribute",
			},
			{
				src = "export local class C end",
				opts = { profile = "experimental" },
				substr = "try removing 'local'",
			},
			{
				src = "export const class C end",
				opts = { profile = "experimental" },
				substr = "try removing 'const'",
			},
			{
				src = "local function f(): number, string return 1 end",
				substr = "wrap the list of return types in parentheses",
			},
		}
		for _, tc in extraParserDiagCases do
			local res = parse(tc.src, tc.opts)
			sert.eq(res.status, "syntaxError", tc.src)
			local matched = false
			for _, diag in res.diagnostics do
				if string.find(diag.message, tc.substr, 1, true) ~= nil then
					matched = true
					break
				end
			end
			expect(matched, tc.src .. " -> expected '" .. tc.substr .. "'")
		end
		local tpGroupRes = parse("local x: Foo<(number) | string> = nil")
		sert.eq(tpGroupRes.status, "ok")
	end)
end)

if not sert._bundled then
	return sert.run(sert.parseCliArgs(...))
end
return nil
