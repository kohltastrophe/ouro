--!strict
-- Lexer regression and property tests derived from the MIT-licensed Luau 0.748 lexer.
local Lexer = require("../src/Lexer")
local T = require("../src/Token")
local sert = require("@sert") :: any

local describe = sert.describe
local test = sert.test
local prop = sert.prop
local gen = sert.gen
local expect = sert

local function sequence(source: string, expected: { { any } }, options: any?)
	local lex = Lexer.new(source, options)
	for index, token in expected do
		sert.eq(lex:next(), token[1], `token #{index} kind`)
		if token[2] ~= nil then
			sert.eq(lex.value, token[2], `token #{index} value`)
		end
	end
	sert.eq(lex:next(), T.Eof, "trailing EOF")
	return lex
end

local function tapeCheck(lex: any)
	local at = 0
	local pieces = table.create(lex.tape.count)
	for i = 1, lex.tape.count do
		sert.eq(lex.tape.starts[i], at, `tape start #{i}`)
		expect(lex.tape.finishes[i] > at, `tape finish #{i} > {at}`)
		at = lex.tape.finishes[i]
		pieces[i] = string.sub(lex.source, lex.tape.starts[i] + 1, at)
	end
	sert.eq(at, #lex.source, "tape covers full source length")
	sert.eq(table.concat(pieces), lex.source, "tape slices reconstruct source")
end

describe("Lexer", function()
	test("scans identifiers, keywords, comments, and attributes", function()
		sequence(
			"foo --[[ comment ]] bar : nil end",
			{ { T.Name, "foo" }, { T.Name, "bar" }, { 58 }, { T.ReservedNil, "nil" }, { T.ReservedEnd, "end" } }
		)
		sequence("[[", { { T.BrokenString } })
		sequence("--[[  ", { { T.BrokenComment } })
		sequence(
			"--[===[\n\n\n\n]===] end",
			{ { T.BlockComment, "\n\n\n\n" }, { T.ReservedEnd } },
			{ skipComments = false }
		)
		sequence("@native @[checked] @ _x continue type", {
			{ T.Attribute, "native" },
			{ T.AttributeOpen },
			{ T.Name, "checked" },
			{ 93 },
			{ T.Attribute, "" },
			{ T.Name, "_x" },
			{ T.Name, "continue" },
			{ T.Name, "type" },
		})
	end)

	test("scans all operators, compound assignments, and punctuation", function()
		sequence("+ += - -= -> * *= / /= // //= % %= ^ ^= = == ~= < <= > >= :: . .. ... ..=", {
			{ 43 },
			{ T.AddAssign },
			{ 45 },
			{ T.SubAssign },
			{ T.SkinnyArrow },
			{ 42 },
			{ T.MulAssign },
			{ 47 },
			{ T.DivAssign },
			{ T.FloorDiv },
			{ T.FloorDivAssign },
			{ 37 },
			{ T.ModAssign },
			{ 94 },
			{ T.PowAssign },
			{ 61 },
			{ T.Equal },
			{ T.NotEqual },
			{ 60 },
			{ T.LessEqual },
			{ 62 },
			{ T.GreaterEqual },
			{ T.DoubleColon },
			{ 46 },
			{ T.Dot2 },
			{ T.Dot3 },
			{ T.ConcatAssign },
		})
	end)

	test("scans numbers and classifies integer/precision status", function()
		sequence("0 123 .5 1e-3 1_000 0xFF 0b1010", {
			{ T.Number, 0 },
			{ T.Number, 123 },
			{ T.Number, 0.5 },
			{ T.Number, 0.001 },
			{ T.Number, 1000 },
			{ T.Number, 255 },
			{ T.Number, 10 },
		})
		for _, okLit in { "0", "123", ".5", "1e-3", "1_000", "0xFF", "0b1010" } do
			local okLex = Lexer.new(okLit)
			sert.eq(okLex:next(), T.Number)
			sert.eq(okLex.numberParseResult, "Ok", okLit)
			sert.eq(okLex:next(), T.Eof)
		end

		local malformedLex = Lexer.new("0x1p2 1..2 1e 0b")
		for idx = 1, 4 do
			sert.eq(malformedLex:next(), T.Number, `malformed token #{idx}`)
			sert.eq(malformedLex.value, nil)
			sert.eq(malformedLex.numberParseResult, "Malformed")
			sert.eq(malformedLex.error, "Malformed number")
		end
		sert.eq(malformedLex:next(), T.Eof)
	end)

	test.each({
		{ name = "exact 2^53", literal = "9007199254740992", expected = "Ok" },
		{ name = "imprecise 2^53 + 1", literal = "9007199254740993", expected = "Imprecise" },
		{ name = "float 2^53 + 1.0", literal = "9007199254740993.0", expected = "Ok" },
		{ name = "leading zero imprecise", literal = "09007199254740992", expected = "Imprecise" },
		{ name = "u64 max hex imprecise", literal = "0xffffffffffffffff", expected = "Imprecise" },
		{ name = "hex 2^53 exact", literal = "0x20000000000000", expected = "Ok" },
		{ name = "hex 2^53 + 1 imprecise", literal = "0x20000000000001", expected = "Imprecise" },
		{ name = "hex top 53 bits exact", literal = "0xfffffffffffff800", expected = "Ok" },
		{ name = "binary >2^53 imprecise", literal = "0b1" .. string.rep("0", 52) .. "1", expected = "Imprecise" },
		{ name = "binary exact 2^53", literal = "0b1" .. string.rep("0", 53), expected = "Ok" },
		{ name = "u64 hex overflow", literal = "0x10000000000000000", expected = "HexOverflow" },
		{ name = "u64 binary overflow", literal = "0b1" .. string.rep("0", 64), expected = "BinOverflow" },
		{ name = "malformed hex exponent", literal = "0x1p2", expected = "Malformed" },
	})("numberParseResult", function(case)
		local lex = Lexer.new(case.literal)
		sert.eq(lex:next(), T.Number)
		sert.eq(lex.numberParseResult, case.expected)
	end)

	test("decodes quoted strings, escapes, and raw long strings", function()
		sequence(
			[==['a\n\x41\065\u{1f600}\z 
 b\q' [[
hello
world]]]==],
			{ { T.QuotedString, "a\nAA😀bq" }, { T.RawString, "hello\nworld" } }
		)
		sequence("[=[\r\na\r\nb\rc]=]", { { T.RawString, "a\nb\rc" } })
		sequence("'a\\\r\nb'", { { T.QuotedString, "a\nb" } })
	end)

	test.each({ "'\\256'", "'\\xg0'", "'\\u{}'", "'\\u{110000}'", "'\\u{xyz}'" })(
		"malformed string escape",
		function(source)
			local lex = Lexer.new(source)
			sert.eq(lex:next(), T.QuotedString)
			sert.eq(lex.value, nil)
			sert.eq(lex.error, "Malformed string")
		end
	)

	test("scans simple, nested, and broken interpolated strings", function()
		sequence("`hello` `a{foo}b{bar}c`", {
			{ T.InterpStringSimple, "hello" },
			{ T.InterpStringBegin, "a" },
			{ T.Name, "foo" },
			{ T.InterpStringMid, "b" },
			{ T.Name, "bar" },
			{ T.InterpStringEnd, "c" },
		})
		sequence("`x{{a}}`", { { T.BrokenInterpDoubleBrace, "x" }, { T.Name, "a" }, { T.InterpStringEnd, "}" } })
		sequence("`a{ {a=`b{c}d`} }e`", {
			{ T.InterpStringBegin, "a" },
			{ 123 },
			{ T.Name, "a" },
			{ 61 },
			{ T.InterpStringBegin, "b" },
			{ T.Name, "c" },
			{ T.InterpStringEnd, "d" },
			{ 125 },
			{ T.InterpStringEnd, "e" },
		})
		sequence("`\\u{1f600}\\{`", { { T.InterpStringSimple, "😀{" } })

		local brokenBrace = Lexer.new("`foo{{x}}`")
		sert.eq(brokenBrace:next(), T.BrokenInterpDoubleBrace)
		sert.eq(brokenBrace.start, 0)
		sert.eq(brokenBrace.finish, 4)
	end)

	test("detects invalid UTF-8 sequences and non-ASCII codepoints", function()
		sequence("é", { { T.BrokenUnicode, 233 } })
		local badUtf8 = Lexer.new(string.char(255, 192, 65))
		sert.eq(badUtf8:next(), T.BrokenUnicode)
		sert.eq(badUtf8.value, nil)
		sert.eq(badUtf8.error, "Invalid UTF-8 byte")
		sert.eq(badUtf8:next(), T.BrokenUnicode)
		sert.eq(badUtf8.value, nil)
		sert.eq(badUtf8.error, "Invalid UTF-8 sequence")
		sert.eq(badUtf8:next(), T.Name)
		sert.eq(badUtf8.value, "A")
		sert.eq(badUtf8:next(), T.Eof)
	end)

	test("preserves lookahead state, hotcomments, lineStarts, and independent instances", function()
		local lex = Lexer.new("--!strict  \r\n foo --!after\nbar", { lossless = true })
		sert.eq(lex:next(), T.Name)
		sert.eq(lex.start, 14)
		sert.eq(lex.value, "foo")
		local currentStart = lex.start
		for _ = 1, 3 do
			local kind, value = lex:lookahead()
			sert.eq(kind, T.Name)
			sert.eq(value, "bar")
			sert.eq(lex.start, currentStart)
			sert.eq(lex.value, "foo")
		end
		sert.eq(lex:next(), T.Name)
		sert.eq(lex.value, "bar")
		sert.eq(lex:next(), T.Eof)
		sert.eq(#lex.comments, 2)
		sert.eq(#lex.hotcomments, 2)
		sert.eq(lex.hotcomments[1].header, true)
		sert.eq(lex.hotcomments[1].content, "strict")
		sert.eq(lex.hotcomments[2].header, false)
		sert.eq(lex.lineStarts[2], 13)
		sert.eq(lex.lineStarts[3], 27)
		tapeCheck(lex)

		local a = Lexer.new("first second")
		local b = Lexer.new("third fourth")
		sert.eq(a:next(), T.Name)
		sert.eq(b:next(), T.Name)
		sert.eq(a:lookahead(), T.Name)
		sert.eq(b:next(), T.Name)
		sert.eq(a:next(), T.Name)
		sert.eq(a.value, "second")
		sert.eq(b.value, "fourth")
	end)

	test.each({
		"`x{{a}}`",
		"--[[  ",
		"x\0tail\n",
		"'unterminated",
		"  ",
		"",
		"[=broken\r\n",
		"`a{ {a=`b{c}d`} }e`",
	})("lossless tape partition on malformed inputs", function(source)
		local lex = Lexer.new(source, { lossless = true })
		while lex:next() ~= T.Eof do
		end
		tapeCheck(lex)
	end)

	test("exhaustively scans every single byte 0..255 with lossless coverage", function()
		for c = 0, 255 do
			local lex = Lexer.new(string.char(c), { lossless = true })
			local count = 0
			while lex:next() ~= T.Eof do
				count += 1
				expect(count < 4, `byte {c} terminated in {count} tokens`)
			end
			tapeCheck(lex)
		end
	end)

	test("checkpoints and cancels inside long tokens while retaining unparsed tail", function()
		local cancel = Lexer.new("[[" .. string.rep("a", 100000) .. "]]", {
			lossless = true,
			checkpoint = function()
				return false
			end,
		})
		local ok, err = pcall(function()
			cancel:next()
		end)
		sert.eq(ok, false)
		sert.eq((err :: any).parserSignal, "cancelled")
		cancel:retainTail()
		tapeCheck(cancel)

		for _, source in
			{
				string.rep("a", 100000),
				"--" .. string.rep("a", 100000),
				"'" .. string.rep("a", 100000) .. "'",
				"'\\z" .. string.rep(" ", 100000) .. "'",
				"0b" .. string.rep("1", 100000),
				string.rep(" ", 100000),
			}
		do
			local calls = 0
			local lex = Lexer.new(source, {
				lossless = true,
				checkpointInterval = 1024,
				checkpoint = function(at: number)
					calls += 1
					expect(at < 13000, `checkpoint byte {at} < 13000`)
					return calls < 10
				end,
			})
			local success, signal = pcall(function()
				lex:next()
			end)
			sert.eq(success, false)
			sert.eq((signal :: any).parserSignal, "cancelled")
			sert.eq(calls, 10)
			lex:retainTail()
			tapeCheck(lex)
		end
	end)

	test("suspends and resumes inside long tokens via yielding checkpoints", function()
		local suspended = Lexer.new(string.rep("a", 10000), {
			checkpointInterval = 1000,
			checkpoint = function(at: number)
				coroutine.yield(at)
				return true
			end,
		})
		local runner = coroutine.create(function()
			suspended:next()
			return suspended.value
		end)
		local resumes = 0
		while coroutine.status(runner) ~= "dead" do
			local success, value = coroutine.resume(runner)
			expect(success, tostring(value))
			resumes += 1
			local other = Lexer.new("other")
			sert.eq(other:next(), T.Name)
			sert.eq(other.value, "other")
			if coroutine.status(runner) == "dead" then
				sert.eq(value, string.rep("a", 10000))
			end
		end
		expect(resumes > 2, `resumed {resumes} times`)
	end)

	prop("lossless tape partitions source and lookahead matches next token", function(g)
		local atoms = {
			"local",
			"function",
			"end",
			"return",
			"foo",
			"bar_1",
			"123",
			"0xff",
			"0b101",
			"1_000.5e-2",
			"99i",
			"'str\\n\\x41'",
			"[[raw\nstring]]",
			"[=[nested]=]",
			"`interp{foo}tail`",
			"`broken{{brace}}`",
			"-- comment\n",
			"--[[block]]",
			"--!strict\n",
			"+=",
			"//=",
			"..=",
			"::",
			"->",
			"...",
			"@native",
			"@[checked]",
			"\r\n",
			"\t ",
			"\0",
			"é",
		}
		local parts = g:list(function(step)
			return step:pick(atoms)
		end, 0, 25)
		local source = table.concat(parts, " ")
		g:note(function()
			return `source = {string.format("%q", source)}`
		end)

		local lex = Lexer.new(source, { lossless = true, profile = "experimental" })
		while true do
			local snapKind = lex.kind
			local snapStart = lex.start
			local snapFinish = lex.finish
			local snapValue = lex.value
			local snapSymbol = lex.symbol
			local snapError = lex.error
			local peekKind, peekValue = lex:lookahead()
			sert.eq(lex.kind, snapKind, "lookahead preserves kind")
			sert.eq(lex.start, snapStart, "lookahead preserves start")
			sert.eq(lex.finish, snapFinish, "lookahead preserves finish")
			sert.eq(lex.value, snapValue, "lookahead preserves value")
			sert.eq(lex.symbol, snapSymbol, "lookahead preserves symbol")
			sert.eq(lex.error, snapError, "lookahead preserves error")

			local nextKind = lex:next()
			sert.eq(nextKind, peekKind, "next() matches lookahead() kind")
			sert.eq(lex.value, peekValue, "next() matches lookahead() value")
			if nextKind == T.Name then
				expect(lex.symbol > 0, "identifier has positive symbol ID")
				sert.eq(lex.symbols[lex.symbol], lex.value, "symbol table round-trips identifier")
				sert.eq(lex.symbolMap[lex.value], lex.symbol, "symbolMap matches symbol ID")
			end
			if nextKind == T.Eof then
				break
			end
		end
		tapeCheck(lex)
	end, { runs = 200 })

	prop("symbol interning is idempotent across repeated identifiers", function(g)
		local names: { string } =
			g:draw(gen.list(gen.pick({ "alpha", "beta", "gamma", "delta", "_id", "type", "continue" }), 1, 30))
		local source = table.concat(names, " ")
		local lex = Lexer.new(source)
		local firstSeen: { [string]: number } = {}
		for _, expectedName in names do
			sert.eq(lex:next(), T.Name)
			sert.eq(lex.value, expectedName)
			local existing = firstSeen[expectedName]
			if existing ~= nil then
				sert.eq(lex.symbol, existing, "repeated identifier reuses symbol ID")
			else
				firstSeen[expectedName] = lex.symbol
			end
			sert.eq(lex.symbols[lex.symbol], expectedName)
		end
		sert.eq(lex:next(), T.Eof)
	end, { runs = 100 })

	prop(
		"scans boundaryInt, boundaryFloat, and malformedString literals without crashing and preserves lossless tape",
		function(g: any)
			local bInt: number = g:draw(gen.boundaryInt())
			local bFloat: number = g:draw(gen.boundaryFloat())
			local mStr: string = g:draw(gen.malformedString())
			local absInt = math.abs(math.floor(bInt)) % 0x7fffffff
			local hexLit = string.format("0x%x", absInt)
			local int64Lit = string.format("%di", absInt)
			local floatLit = if bFloat ~= bFloat
				then "0x1p2"
				elseif math.abs(bFloat) == math.huge then "1e500"
				else tostring(bFloat)
			local source = `{tostring(bInt)} {hexLit} {int64Lit} {floatLit} {mStr}`
			local lex = Lexer.new(source, { lossless = true, skipComments = false, profile = "experimental" })
			local count = 0
			while lex:next() ~= T.Eof do
				count += 1
				expect(count <= #source + 4, "lexer terminates on boundary numeric and malformed inputs")
			end
			tapeCheck(lex)
		end,
		{ runs = 150 }
	)

	test("covers UTF-8 escape widths, decode checkpoints, and fine-grained checkpointed tokens", function()
		-- 1-byte, 2-byte, 3-byte, and 4-byte \u{...} escapes, plus \\\n, \\\r\n, and malformed escapes
		sequence(
			[=['\u{41}\u{e9}\u{2603}\u{1f600}\
ok']=],
			{ { T.QuotedString, "Aé☃😀\nok" } }
		)
		local badEscapes: { { src: string, kind: number, err: string } } = {
			{ src = "'\\\0'", kind = T.BrokenString, err = "Unfinished string" },
			{ src = "'\\x1'", kind = T.QuotedString, err = "Malformed string" },
			{ src = "'\\u{1'", kind = T.QuotedString, err = "Malformed string" },
			{ src = "'\\u'", kind = T.QuotedString, err = "Malformed string" },
		}
		for _, tc in badEscapes do
			local lex = Lexer.new(tc.src)
			sert.eq(lex:next(), tc.kind)
			sert.eq(lex.error, tc.err)
			sert.eq(lex.value, nil)
		end

		-- Checkpoint active (returning true) across long strings, interpolated strings, backslash escapes, and hex numbers
		local cpTrue = function()
			return true
		end
		local complexSource = table.concat({
			"[=[\nline1\n]=]",
			"`interp\\u{41}\\n\\r\\n\\z  \n{1 + 2}end`",
			"`broken{{brace}}`",
			"0x123456789abcdef0",
			"0b1010101010101010i",
			"'escaped\\z   \\n\\r\\n\\x41'",
			"--[=[\nblock\n]=]\n",
		}, " ")
		local lexCp = Lexer.new(complexSource, {
			lossless = true,
			skipComments = false,
			checkpointInterval = 2,
			checkpoint = cpTrue,
		})
		while lexCp:next() ~= T.Eof do
		end
		tapeCheck(lexCp)

		-- Cancel during _decodeCheck (after initial scan succeeds, cancel on later checkpoint calls)
		for _, cancelSrc in { "'" .. string.rep("a", 40) .. "\\z   '", "0x" .. string.rep("f", 40) } do
			local seen = 0
			local lexDecodeCancel = Lexer.new(cancelSrc, {
				lossless = true,
				checkpointInterval = 16,
				checkpoint = function()
					seen += 1
					return seen <= 3
				end,
			})
			local ok, err = pcall(function()
				lexDecodeCancel:next()
			end)
			sert.eq(ok, false)
			sert.eq((err :: any).parserSignal, "cancelled")
			lexDecodeCancel:retainTail()
			tapeCheck(lexDecodeCancel)
		end
	end)

	test("skips interning reserved keywords while preserving attribute and scratch symbolMap semantics", function()
		local allKeywords =
			"and break do else elseif end false for function if in local nil not or repeat return then true until while"
		local kwLex = Lexer.new(allKeywords)
		local count = 0
		while kwLex:next() ~= T.Eof do
			count += 1
			sert.eq(kwLex.symbol, 0, `keyword #{count} does not allocate a symbol`)
		end
		sert.eq(count, 21)
		sert.eq(#kwLex.symbols, 0, "reserved keywords do not bloat symbols")
		sert.eq(next(kwLex.symbolMap), nil, "reserved keywords do not bloat symbolMap")
		sert.eq(kwLex.ownSymbolMap, kwLex.symbolMap, "fresh lexer exposes ownSymbolMap")

		local attrLex = Lexer.new("@native local foo = true")
		sert.eq(attrLex:next(), T.Attribute)
		sert.eq(attrLex.symbol, 1)
		sert.eq(attrLex:next(), T.ReservedLocal)
		sert.eq(attrLex.symbol, 0)
		sert.eq(attrLex:next(), T.Name)
		sert.eq(attrLex.symbol, 2)
		sert.eq(attrLex:next(), 61)
		sert.eq(attrLex:next(), T.ReservedTrue)
		sert.eq(attrLex.symbol, 0)
		sert.eq(attrLex:next(), T.Eof)
		sert.eq(#attrLex.symbols, 2)
		sert.eq(attrLex.symbols[1], "native")
		sert.eq(attrLex.symbols[2], "foo")

		local scratch: { symbolMap: { [string]: number }, braces: { boolean } } = { symbolMap = {}, braces = {} }
		local scratchLex = Lexer.new("alpha beta", nil, scratch)
		sert.eq(scratchLex.ownSymbolMap, nil, "scratch-backed lexer omits ownSymbolMap")
		sert.eq(scratchLex.symbolMap, scratch.symbolMap)
		sert.eq(scratchLex.braces, scratch.braces)
		sert.eq(scratchLex:next(), T.Name)
		sert.eq(scratch.symbolMap.alpha, 1)
	end)

	test(
		"handles embedded NUL bytes and bare CR across comments, long strings, and quoted/interpolated strings",
		function()
			local cases = {
				{ src = "-- a\0b\nx", kind = T.Comment, start = 0, finish = 4 },
				{ src = "[[a\0b]]", kind = T.BrokenString, start = 0, finish = 3 },
				{ src = "--[[a\0b]]x", kind = T.BrokenComment, start = 0, finish = 5 },
				{ src = '"a\0b"', kind = T.BrokenString, start = 0, finish = 2 },
				{ src = "`a\0b`", kind = T.BrokenString, start = 0, finish = 2 },
			}
			for _, c in cases do
				local lex = Lexer.new(c.src, { lossless = true, skipComments = false })
				sert.eq(lex:next(), c.kind, `first token kind for {string.format("%q", c.src)}`)
				sert.eq(lex.start, c.start)
				sert.eq(lex.finish, c.finish)
				sert.eq(lex:next(), T.Eof)
				sert.eq(lex.start, c.finish)
				sert.eq(lex.finish, c.finish)
				tapeCheck(lex)
			end

			local crLex = Lexer.new("-- foo\rbar\n", { lossless = true, skipComments = false })
			sert.eq(crLex:next(), T.Comment)
			sert.eq(crLex.start, 0)
			sert.eq(crLex.finish, 6)
			sert.eq(crLex.value, " foo")
			sert.eq(crLex:next(), T.Name)
			sert.eq(crLex.value, "bar")
			sert.eq(crLex.start, 7)
			sert.eq(crLex.finish, 10)
			sert.eq(crLex:next(), T.Eof)
			tapeCheck(crLex)

			local escapedNul = Lexer.new('"a\\0b" `c\\x00d`', { lossless = true })
			sert.eq(escapedNul:next(), T.QuotedString)
			sert.eq(escapedNul.value, "a\0b")
			sert.eq(escapedNul:next(), T.InterpStringSimple)
			sert.eq(escapedNul.value, "c\0d")
			sert.eq(escapedNul:next(), T.Eof)
			tapeCheck(escapedNul)
		end
	)

	test("lookahead preserves tokenFinish and defers retainTail on embedded NUL until Eof", function()
		local brokenInterpLex = Lexer.new("x `a{{b}`", { lossless = true })
		sert.eq(brokenInterpLex:next(), T.Name)
		local peekKind = brokenInterpLex:lookahead()
		sert.eq(peekKind, T.BrokenInterpDoubleBrace)
		sert.eq(brokenInterpLex:next(), T.BrokenInterpDoubleBrace)
		sert.eq(brokenInterpLex.start, 2)
		sert.eq(brokenInterpLex.finish, 4)

		local nulLex = Lexer.new("a\0bc", { lossless = true })
		sert.eq(nulLex:next(), T.Name)
		sert.eq(nulLex:lookahead(), T.Eof)
		sert.eq(nulLex.tailRecorded, false)
		sert.eq(nulLex:next(), T.Eof)
		sert.eq(nulLex.tailRecorded, true)
		tapeCheck(nulLex)
	end)
end)

if not sert._bundled then
	return sert.run(sert.parseCliArgs(...))
end
return nil
