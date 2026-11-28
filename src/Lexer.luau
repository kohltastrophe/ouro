--!strict
-- Fresh Luau translation of Luau 0.748 Ast/src/Lexer.cpp.
-- Copyright (c) 2019-2026 Roblox Corporation. MIT License. See ../LICENSE.md.
local Token = require("./Token")
local byte, sub, char, find, gsub = string.byte, string.sub, string.char, string.find, string.gsub
local readu8, readu16, readu32 = buffer.readu8, buffer.readu16, buffer.readu32
local writeu8 = buffer.writeu8
local band, lshift, rshift, countlz = bit32.band, bit32.lshift, bit32.rshift, bit32.countlz
local Lexer: any = {}
Lexer.__index = Lexer
-- 1 = space, 2 = digit, 4 = identifier start (alpha or '_')
local CHAR_MASK = buffer.create(256)
local HEX_VAL = buffer.create(256)
-- Dispatch classes for scan():
-- 0 = pure single-char punctuation, 1 = ident start, 2 = digit, 3 = EOF/NUL, 4 = quote,
-- 5 = '-', 6 = '.', 7 = '[', 8 = '`', 9 = '{'/' }', 10 = '/', 11 = ':', 12 = '@', 13 = unicode (>= 128),
-- 14 = EQ_PAIR chars (+, *, %, ^, =, <, >, ~)
local SCAN_CLASS = buffer.create(256)
-- Packed paired '=' tokens stored as (tokenId - 256) so they fit in u8
local EQ_PAIR = buffer.create(256)
buffer.fill(HEX_VAL, 0, 255, 256)
for c = 65, 90 do
	writeu8(CHAR_MASK, c, 4)
	writeu8(SCAN_CLASS, c, 1)
end
for c = 97, 122 do
	writeu8(CHAR_MASK, c, 4)
	writeu8(SCAN_CLASS, c, 1)
end
writeu8(CHAR_MASK, 95, 4)
writeu8(SCAN_CLASS, 95, 1)
for c = 48, 57 do
	writeu8(CHAR_MASK, c, 2)
	writeu8(HEX_VAL, c, c - 48)
	writeu8(SCAN_CLASS, c, 2)
end
for c = 65, 70 do
	writeu8(HEX_VAL, c, c - 55)
	writeu8(HEX_VAL, c + 32, c - 55)
end
for _, c in { 9, 10, 11, 12, 13, 32 } do
	writeu8(CHAR_MASK, c, 1)
end
writeu8(SCAN_CLASS, 0, 3)
writeu8(SCAN_CLASS, 34, 4)
writeu8(SCAN_CLASS, 39, 4)
writeu8(SCAN_CLASS, 45, 5)
writeu8(SCAN_CLASS, 46, 6)
writeu8(SCAN_CLASS, 91, 7)
writeu8(SCAN_CLASS, 96, 8)
writeu8(SCAN_CLASS, 123, 9)
writeu8(SCAN_CLASS, 125, 9)
writeu8(SCAN_CLASS, 47, 10)
writeu8(SCAN_CLASS, 58, 11)
writeu8(SCAN_CLASS, 64, 12)
for c = 128, 255 do
	writeu8(SCAN_CLASS, c, 13)
end
for c, tok in
	{
		[43] = Token.AddAssign,
		[42] = Token.MulAssign,
		[37] = Token.ModAssign,
		[94] = Token.PowAssign,
		[61] = Token.Equal,
		[60] = Token.LessEqual,
		[62] = Token.GreaterEqual,
		[126] = Token.NotEqual,
	}
do
	writeu8(EQ_PAIR, c, tok - 256)
	writeu8(SCAN_CLASS, c, 14)
end
local escapes: { [number]: string } =
	{ [97] = "\a", [98] = "\b", [102] = "\f", [110] = "\n", [114] = "\r", [116] = "\t", [118] = "\v" }
local function utf8code(code: number): string?
	if code < 128 then
		return char(code)
	elseif code < 2048 then
		return char(192 + rshift(code, 6), 128 + band(code, 63))
	elseif code < 65536 then
		return char(224 + rshift(code, 12), 128 + band(rshift(code, 6), 63), 128 + band(code, 63))
	elseif code < 1114112 then
		return char(
			240 + rshift(code, 18),
			128 + band(rshift(code, 12), 63),
			128 + band(rshift(code, 6), 63),
			128 + band(code, 63)
		)
	end
	return nil
end
function Lexer.new(source: string, options: any?, scratch: any?): any
	options = options or {}
	local length = #source
	local needed = length + 1
	local buf: buffer
	if scratch and scratch.buf and buffer.len(scratch.buf) >= needed then
		buf = scratch.buf
	else
		buf = buffer.create(needed)
		if scratch then
			scratch.buf = buf
		end
	end
	if length > 0 then
		buffer.writestring(buf, 0, source)
	end
	buffer.writeu8(buf, length, 0)
	local symbolMap = if scratch and scratch.symbolMap then scratch.symbolMap else {}
	local shortSymMap = if scratch and scratch.shortSymMap then scratch.shortSymMap else {}
	local shortSymMapLong = if scratch and scratch.shortSymMapLong then scratch.shortSymMapLong else {}
	local braces = if scratch and scratch.braces then scratch.braces else {}
	local interval = math.max(1, options.checkpointInterval or 4096)
	local checkpoint = options.checkpoint
	local hasCheckpoint = checkpoint ~= nil
	local nextCp = if hasCheckpoint then interval else math.huge
	local estTape = if options.lossless then math.min(65536, math.max(16, math.floor(length / 4))) else 0
	return setmetatable({
		source = source,
		buf = buf,
		length = length,
		i = 1,
		kind = 0,
		start = 0,
		finish = 0,
		value = nil,
		symbol = 0,
		error = nil,
		raw = nil,
		codepoint = nil,
		numberParseResult = nil,
		tokenFinish = nil,
		hasExtra = false,
		hasCheckpoint = hasCheckpoint,
		symbols = {},
		symbolCount = 0,
		symbolMap = symbolMap,
		shortSymMap = shortSymMap,
		shortSymMapLong = shortSymMapLong,
		ownSymbolMap = if scratch then nil else symbolMap,
		lineStarts = { 0 },
		lineCount = 1,
		comments = {},
		hotcomments = {},
		tape = if options.lossless
			then {
				kinds = table.create(estTape),
				starts = table.create(estTape),
				finishes = table.create(estTape),
				count = 0,
			}
			else nil,
		braces = braces,
		header = true,
		skipComments = options.skipComments ~= false,
		captureComments = options.captureComments ~= false,
		checkpoint = checkpoint,
		checkpointInterval = interval,
		nextCheckpoint = nextCp,
		cached = false,
		cacheKind = 0,
		cacheStart = 0,
		cacheFinish = 0,
		cacheValue = nil,
		cacheSymbol = 0,
		cacheError = nil,
		cacheRaw = nil,
		cacheCodepoint = nil,
		cacheNumberParseResult = nil,
		cacheTokenFinish = nil,
		cacheHasExtra = false,
		inLookahead = false,
		tailRecorded = false,
	}, Lexer)
end
local function check(self: any)
	if self.i >= self.nextCheckpoint then
		self.nextCheckpoint = self.i + self.checkpointInterval
		local cp: ((number) -> boolean?)? = self.checkpoint
		if cp and cp(self.i - 1) == false then
			error({ parserSignal = "cancelled" }, 0)
		end
	end
end
local function consume(self: any)
	local i = self.i
	if readu8(self.buf, i - 1) == 10 then
		local lc = self.lineCount + 1
		self.lineCount = lc
		self.lineStarts[lc] = i
	end
	i += 1
	self.i = i
	if i >= self.nextCheckpoint then
		check(self)
	end
end
local function tapeRecord(self: any, kind: number, first: number, last: number)
	local tape = self.tape
	if tape and last > first then
		local n = tape.count + 1
		tape.kinds[n], tape.starts[n], tape.finishes[n], tape.count = kind, first, last, n
	end
end
function Lexer.retainTail(self: any)
	-- Used by the parser on cancellation/limits. A token in progress has not entered the tape.
	local tape = self.tape
	if tape then
		local first = if tape.count > 0 then tape.finishes[tape.count] else 0
		tapeRecord(self, Token.Unparsed, first, self.length)
	end
	self.tailRecorded = true
end
@native
local function intern(self: any, name: string): number
	local symbolMap = self.symbolMap
	local id = symbolMap[name]
	if not id then
		id = self.symbolCount + 1
		self.symbolCount = id
		self.symbols[id] = name
		symbolMap[name] = id
	end
	return id
end
Lexer._intern = intern
local function separator(self: any): number
	local buf = self.buf
	local i = self.i
	local delimiter = readu8(buf, i - 1)
	i += 1
	if i >= self.nextCheckpoint then
		self.i = i
		check(self)
	end
	local count = 0
	while readu8(buf, i - 1) == 61 do
		i += 1
		count += 1
		if i >= self.nextCheckpoint then
			self.i = i
			check(self)
		end
	end
	self.i = i
	return if readu8(buf, i - 1) == delimiter then count else -count - 1
end
local function decodeCheck(self: any, i: number)
	local cp: ((number) -> boolean?)? = self.checkpoint
	if cp and i >= self.decodeCheckpoint then
		self.decodeCheckpoint = i + self.checkpointInterval
		if cp(i - 1) == false then
			error({ parserSignal = "cancelled" }, 0)
		end
	end
end
local function decode(self: any, first: number, last: number): string?
	local source, buf = self.source, self.buf
	local hasCheckpoint = self.checkpoint ~= nil
	local pieces = {}
	local i, run = first, first
	while i < last do
		if hasCheckpoint and i >= self.decodeCheckpoint then
			decodeCheck(self, i)
		end
		local c = readu8(buf, i - 1)
		if c ~= 92 then
			i += 1
			continue
		end
		pieces[#pieces + 1] = sub(source, run, i - 1)
		i += 1
		if i >= last then
			return nil
		end
		c = readu8(buf, i - 1)
		i += 1
		local value: string? = nil
		if c == 0 then
			return nil
		elseif c == 10 then
			value = "\n"
		elseif c == 13 then
			value = "\n"
			if i < last and readu8(buf, i - 1) == 10 then
				i += 1
			end
		elseif c == 122 then
			while i < last and readu8(CHAR_MASK, readu8(buf, i - 1)) == 1 do
				if hasCheckpoint and i >= self.decodeCheckpoint then
					decodeCheck(self, i)
				end
				i += 1
			end
			value = ""
		elseif c == 120 then
			if i + 1 >= last then
				return nil
			end
			local a, b = readu8(HEX_VAL, readu8(buf, i - 1)), readu8(HEX_VAL, readu8(buf, i))
			if a > 15 or b > 15 then
				return nil
			end
			value = char(lshift(a, 4) + b)
			i += 2
		elseif c == 117 then
			if i + 2 >= last or readu8(buf, i - 1) ~= 123 then
				return nil
			end
			i += 1
			local code, count = 0, 0
			while i < last and readu8(buf, i - 1) ~= 125 and count < 16 do
				local h = readu8(HEX_VAL, readu8(buf, i - 1))
				if h > 15 then
					return nil
				end
				-- C++ uses uint32 and wraps; preserve this even for excessive zero digits.
				code = (code * 16 + h) % 4294967296
				count += 1
				i += 1
			end
			if count == 0 or i >= last or readu8(buf, i - 1) ~= 125 then
				return nil
			end
			i += 1
			value = utf8code(code)
			if not value then
				return nil
			end
		elseif c >= 48 and c <= 57 then
			local code = c - 48
			for _ = 1, 2 do
				if i >= last then
					break
				end
				local dc = readu8(buf, i - 1)
				if dc < 48 or dc > 57 then
					break
				end
				code = code * 10 + dc - 48
				i += 1
			end
			if code > 255 then
				return nil
			end
			value = char(code)
		else
			value = escapes[c] or char(c)
		end
		pieces[#pieces + 1] = value :: string
		run = i
	end
	pieces[#pieces + 1] = sub(source, run, last - 1)
	return table.concat(pieces)
end
local function stringValue(self: any, first: number, last: number, escaped: boolean?)
	if escaped then
		self.decodeCheckpoint = first + self.checkpointInterval
		local val = decode(self, first, last)
		self.value = val
		if val == nil then
			self.error = "Malformed string"
			self.raw = sub(self.source, first, last - 1)
			self.hasExtra = true
		end
	else
		self.value = sub(self.source, first, last - 1)
	end
end
local function backslash(self: any)
	local buf = self.buf
	local lineStarts = self.lineStarts
	local i = self.i + 1
	if i >= self.nextCheckpoint then
		self.i = i
		check(self)
	end
	local c = readu8(buf, i - 1)
	if c == 13 then
		i += 1
		if i >= self.nextCheckpoint then
			self.i = i
			check(self)
		end
		if readu8(buf, i - 1) == 10 then
			local lc = self.lineCount + 1
			self.lineCount = lc
			lineStarts[lc] = i
			i += 1
			if i >= self.nextCheckpoint then
				self.i = i
				check(self)
			end
		end
	elseif c == 122 then
		i += 1
		if i >= self.nextCheckpoint then
			self.i = i
			check(self)
		end
		while true do
			local sc = readu8(buf, i - 1)
			if readu8(CHAR_MASK, sc) ~= 1 then
				break
			end
			if sc == 10 then
				local lc = self.lineCount + 1
				self.lineCount = lc
				lineStarts[lc] = i
			end
			i += 1
			if i >= self.nextCheckpoint then
				self.i = i
				check(self)
			end
		end
	elseif c ~= 0 then
		if c == 10 then
			local lc = self.lineCount + 1
			self.lineCount = lc
			lineStarts[lc] = i
		end
		i += 1
		if i >= self.nextCheckpoint then
			self.i = i
			check(self)
		end
	end
	self.i = i
end
local function quoted(self: any): number
	local buf: buffer = self.buf
	local start: number = self.i
	local delimiter: number = readu8(buf, start - 1)
	local first: number = start + 1
	local i: number = first
	local escaped = false
	if not self.hasCheckpoint then
		while true do
			local c = readu8(buf, i - 1)
			if c == delimiter then
				self.i = i + 1
				stringValue(self, first, i, escaped)
				return Token.QuotedString
			elseif c == 92 then
				escaped = true
				self.i = i
				backslash(self)
				i = self.i
			elseif c == 0 or c == 10 or c == 13 then
				self.i = i
				self.error = "Unfinished string"
				self.hasExtra = true
				return Token.BrokenString
			else
				i += 1
			end
		end
	else
		local nextCp: number = self.nextCheckpoint
		self.i = first
		if first >= nextCp then
			check(self)
			nextCp = self.nextCheckpoint
		end
		while true do
			local c = readu8(buf, i - 1)
			if c == delimiter then
				break
			elseif c == 0 or c == 10 or c == 13 then
				self.i = i
				self.error = "Unfinished string"
				self.hasExtra = true
				return Token.BrokenString
			elseif c == 92 then
				escaped = true
				self.i = i
				backslash(self)
				i = self.i
				nextCp = self.nextCheckpoint
			else
				i += 1
				if i >= nextCp then
					self.i = i
					check(self)
					nextCp = self.nextCheckpoint
				end
			end
		end
		self.i = i
		local last = i
		consume(self)
		stringValue(self, first, last, escaped)
		return Token.QuotedString
	end
end
local function interpolation(self: any, formatKind: number, endKind: number): number
	local first: number = self.i
	local buf: buffer = self.buf
	local i: number = first
	local escaped = false
	if not self.hasCheckpoint then
		while true do
			local c = readu8(buf, i - 1)
			if c == 96 then
				self.i = i + 1
				stringValue(self, first, i, escaped)
				return endKind
			elseif c == 92 then
				escaped = true
				if readu8(buf, i) == 117 and readu8(buf, i + 1) == 123 then
					i += 3
				else
					self.i = i
					backslash(self)
					i = self.i
				end
			elseif c == 123 then
				self.braces[#self.braces + 1] = true
				if readu8(buf, i) == 123 then
					self.i = i + 2
					stringValue(self, first, i, escaped)
					self.tokenFinish = i - 1
					self.error = "Double braces are not permitted within interpolated strings"
					self.hasExtra = true
					return Token.BrokenInterpDoubleBrace
				end
				self.i = i + 1
				stringValue(self, first, i, escaped)
				return formatKind
			elseif c == 0 or c == 10 or c == 13 then
				self.i = i
				self.error = "Unfinished string"
				self.hasExtra = true
				return Token.BrokenString
			else
				i += 1
			end
		end
	end
	local nextCp: number = self.nextCheckpoint
	while true do
		local c = readu8(buf, i - 1)
		if c == 96 then
			break
		elseif c == 0 or c == 10 or c == 13 then
			self.i = i
			self.error = "Unfinished string"
			self.hasExtra = true
			return Token.BrokenString
		elseif c == 92 then
			escaped = true
			if readu8(buf, i) == 117 and readu8(buf, i + 1) == 123 then
				i += 3
				if i >= nextCp then
					self.i = i
					check(self)
					nextCp = self.nextCheckpoint
				end
			else
				self.i = i
				backslash(self)
				i = self.i
				nextCp = self.nextCheckpoint
			end
		elseif c == 123 then
			self.braces[#self.braces + 1] = true
			local last = i
			if readu8(buf, i) == 123 then
				self.i = i + 2
				if self.i >= nextCp then
					check(self)
				end
				stringValue(self, first, last, escaped)
				self.tokenFinish = last - 1
				self.error = "Double braces are not permitted within interpolated strings"
				self.hasExtra = true
				return Token.BrokenInterpDoubleBrace
			end
			self.i = i + 1
			if self.i >= nextCp then
				check(self)
			end
			stringValue(self, first, last, escaped)
			return formatKind
		else
			i += 1
			if i >= nextCp then
				self.i = i
				check(self)
				nextCp = self.nextCheckpoint
			end
		end
	end
	local last = i
	self.i = i + 1
	if self.i >= nextCp then
		check(self)
	end
	stringValue(self, first, last, escaped)
	return endKind
end
local function finishLong(self: any, first: number, last: number, ok: number): number
	if ok ~= Token.RawString then
		if not self.skipComments then
			self.value = sub(self.source, first, last - 1)
		end
		return ok
	end
	local source, buf = self.source, self.buf
	local slice: string
	local b0 = readu8(buf, first - 1)
	if b0 == 10 then
		slice = sub(source, first + 1, last - 1)
	elseif b0 == 13 and readu8(buf, first) == 10 then
		slice = sub(source, first + 2, last - 1)
	else
		slice = sub(source, first, last - 1)
	end
	self.value = if find(slice, "\r\n", 1, true) then (gsub(slice, "\r\n", "\n")) else slice
	return ok
end
local function long(self: any, sep: number, ok: number, broken: number): number
	consume(self)
	local first: number = self.i
	local source = self.source
	local buf: buffer = self.buf
	local i: number = first
	local lineStarts = self.lineStarts
	local nextCp: number = self.nextCheckpoint
	if not self.hasCheckpoint then
		local closePattern = if sep == 0 then "]]" elseif sep == 1 then "]=]" else "]" .. string.rep("=", sep) .. "]"
		local closePos, closeEnd = find(source, closePattern, i, true)
		if closePos and closeEnd then
			local j = i
			local nulFound = false
			local lc = self.lineCount
			while j < closePos do
				local b = readu8(buf, j - 1)
				if b == 0 then
					nulFound = true
					break
				elseif b == 10 then
					lc += 1
					lineStarts[lc] = j
				end
				j += 1
			end
			if not nulFound then
				self.lineCount = lc
				self.i = closeEnd + 1
				return finishLong(self, first, closePos, ok)
			end
		end
	end
	while true do
		local c = readu8(buf, i - 1)
		if c == 0 then
			break
		end
		if c == 93 then
			local last = i
			self.i = i
			if separator(self) == sep then
				consume(self)
				return finishLong(self, first, last, ok)
			end
			i = self.i
			nextCp = self.nextCheckpoint
		else
			if c == 10 then
				local lc = self.lineCount + 1
				self.lineCount = lc
				lineStarts[lc] = i
			end
			i += 1
			if i >= nextCp then
				self.i = i
				check(self)
				nextCp = self.nextCheckpoint
			end
		end
	end
	self.i = i
	self.error = if broken == Token.BrokenComment then "Unfinished long comment" else "Unfinished long string"
	self.hasExtra = true
	return broken
end
@native
local function number(self: any, first: number): number
	local i: number = self.i
	local buf: buffer = self.buf
	local source = self.source
	local hasCp: boolean = self.hasCheckpoint
	local nextCp: number = self.nextCheckpoint
	if not hasCp then
		local b0: number = readu8(buf, first - 1)
		if b0 >= 48 and b0 <= 57 then
			local val = b0 - 48
			local j: number = first + 1
			local c: number = readu8(buf, j - 1)
			while c >= 48 and c <= 57 do
				val = val * 10 + (c - 48)
				j += 1
				c = readu8(buf, j - 1)
			end
			if j - first <= 15 and c ~= 46 and c ~= 95 and c ~= 101 and c ~= 69 and readu8(CHAR_MASK, c) < 2 then
				self.i = j
				self.value = val
				self.numberParseResult = "Ok"
				return Token.Number
			end
		end
	end
	while true do
		i += 1
		if hasCp and i >= nextCp then
			self.i = i
			check(self)
			nextCp = self.nextCheckpoint
		end
		local c: number = readu8(buf, i - 1)
		if not ((c >= 48 and c <= 57) or c == 46 or c == 95) then
			break
		end
	end
	local c: number = readu8(buf, i - 1)
	if c == 101 or c == 69 then
		i += 1
		c = readu8(buf, i - 1)
		if c == 43 or c == 45 then
			i += 1
		end
	end
	while readu8(CHAR_MASK, readu8(buf, i - 1)) >= 2 do
		i += 1
		if hasCp and i >= nextCp then
			self.i = i
			check(self)
			nextCp = self.nextCheckpoint
		end
	end
	self.i = i
	local raw = sub(source, first, i - 1)
	local text = raw
	if find(text, "_", 1, true) then
		text = (gsub(text, "_", ""))
	end
	local second = byte(text, 2)
	if byte(text, 1) == 48 and (second == 98 or second == 66 or second == 120 or second == 88) then
		local base = if second == 98 or second == 66 then 2 else 16
		local high, low, valid, overflow = 0, 0, #text > 2, false
		if hasCp then
			self.decodeCheckpoint = first + self.checkpointInterval
		end
		for p = 3, #text do
			if hasCp and first + p - 1 >= self.decodeCheckpoint then
				decodeCheck(self, first + p - 1)
			end
			local ch: number = byte(text, p)
			local h = readu8(HEX_VAL, ch)
			if h > 15 or h >= base then
				valid = false
				break
			end
			local product = low * base + h
			high = high * base + math.floor(product / 4294967296)
			low = product % 4294967296
			if high >= 4294967296 then
				overflow = true
				high = 4294967295
				low = 4294967295
			end
		end
		self.value = if valid then high * 4294967296 + low else nil
		if overflow then
			self.numberParseResult = if base == 2 then "BinOverflow" else "HexOverflow"
			self.hasExtra = true
		elseif valid and high >= 0x200000 then
			local bits = 64 - countlz(high)
			if band(low, lshift(1, bits - 53) - 1) ~= 0 then
				self.numberParseResult = "Imprecise"
				self.hasExtra = true
			else
				self.numberParseResult = "Ok"
			end
		else
			self.numberParseResult = "Ok"
		end
	else
		local num = tonumber(text)
		self.value = num
		self.numberParseResult = "Ok"
		if num and num >= 9007199254740992 then
			if hasCp then
				self.decodeCheckpoint = first + self.checkpointInterval
			end
			local decimal = true
			for p = 1, #text do
				if hasCp and first + p - 1 >= self.decodeCheckpoint then
					decodeCheck(self, first + p - 1)
				end
				local dc: number = byte(text, p)
				if dc < 48 or dc > 57 then
					decimal = false
					break
				end
			end
			if decimal and string.format("%.0f", num) ~= text then
				self.numberParseResult = "Imprecise"
				self.hasExtra = true
			end
		end
	end
	if self.value == nil then
		self.raw = raw
		self.error = "Malformed number"
		self.numberParseResult = "Malformed"
		self.hasExtra = true
	end
	return Token.Number
end
@native
local function scanName(self: any, attribute: boolean): (number, any, number)
	local first: number = self.i
	local i: number = first
	local buf: buffer = self.buf
	if not self.hasCheckpoint then
		repeat
			i += 1
		until readu8(CHAR_MASK, readu8(buf, i - 1)) < 2
	else
		local nextCp: number = self.nextCheckpoint
		repeat
			i += 1
			if i >= nextCp then
				self.i = i
				check(self)
				nextCp = self.nextCheckpoint
			end
		until readu8(CHAR_MASK, readu8(buf, i - 1)) < 2
	end
	self.i = i
	local len: number = i - first
	local p: number = first - 1
	local packed: number = 0
	local d1: number, d2: number = 0, 0
	if len == 1 then
		packed = readu8(buf, p)
	elseif len == 2 then
		local w: number = readu16(buf, p)
		if not attribute then
			if w == 0x6F64 then
				return Token.ReservedDo, "do", 0
			elseif w == 0x6669 then
				return Token.ReservedIf, "if", 0
			elseif w == 0x6E69 then
				return Token.ReservedIn, "in", 0
			elseif w == 0x726F then
				return Token.ReservedOr, "or", 0
			end
		end
		packed = w
	elseif len == 3 then
		local w: number = readu16(buf, p)
		local b2: number = readu8(buf, p + 2)
		if not attribute then
			if w == 0x6E65 and b2 == 100 then
				return Token.ReservedEnd, "end", 0
			elseif w == 0x6E61 and b2 == 100 then
				return Token.ReservedAnd, "and", 0
			elseif w == 0x6F66 and b2 == 114 then
				return Token.ReservedFor, "for", 0
			elseif w == 0x696E and b2 == 108 then
				return Token.ReservedNil, "nil", 0
			elseif w == 0x6F6E and b2 == 116 then
				return Token.ReservedNot, "not", 0
			end
		end
		packed = w + b2 * 65536
	elseif len == 4 then
		local d: number = readu32(buf, p)
		if not attribute then
			if d == 0x6E656874 then
				return Token.ReservedThen, "then", 0
			elseif d == 0x65757274 then
				return Token.ReservedTrue, "true", 0
			elseif d == 0x65736C65 then
				return Token.ReservedElse, "else", 0
			end
		end
		packed = d
	elseif len == 5 then
		local d: number = readu32(buf, p)
		local b4: number = readu8(buf, p + 4)
		if not attribute then
			if d == 0x61636F6C and b4 == 108 then
				return Token.ReservedLocal, "local", 0
			elseif d == 0x736C6166 and b4 == 101 then
				return Token.ReservedFalse, "false", 0
			elseif d == 0x6C696877 and b4 == 101 then
				return Token.ReservedWhile, "while", 0
			elseif d == 0x61657262 and b4 == 107 then
				return Token.ReservedBreak, "break", 0
			elseif d == 0x69746E75 and b4 == 108 then
				return Token.ReservedUntil, "until", 0
			end
		end
		packed = d + b4 * 4294967296
	elseif len == 6 then
		local d: number = readu32(buf, p)
		local w2: number = readu16(buf, p + 4)
		if not attribute then
			if d == 0x75746572 and w2 == 0x6E72 then
				return Token.ReservedReturn, "return", 0
			elseif d == 0x65706572 and w2 == 0x7461 then
				return Token.ReservedRepeat, "repeat", 0
			elseif d == 0x65736C65 and w2 == 0x6669 then
				return Token.ReservedElseif, "elseif", 0
			end
		end
		packed = d + w2 * 4294967296
	elseif len == 7 then
		d1 = readu32(buf, p)
		d2 = readu16(buf, p + 4) + readu8(buf, p + 6) * 65536
	elseif len == 8 then
		d1 = readu32(buf, p)
		d2 = readu32(buf, p + 4)
		if not attribute and d1 == 0x636E7566 and d2 == 0x6E6F6974 then
			return Token.ReservedFunction, "function", 0
		end
	end
	if packed ~= 0 then
		local shortSymMap = self.shortSymMap
		local id = shortSymMap[packed]
		if id then
			return (if attribute then Token.Attribute else Token.Name), self.symbols[id], id
		end
		local name = sub(self.source, first, i - 1)
		id = intern(self, name)
		shortSymMap[packed] = id
		return (if attribute then Token.Attribute else Token.Name), name, id
	elseif d1 ~= 0 then
		local longMap = self.shortSymMapLong
		local subMap = longMap[d1]
		local id = if subMap then subMap[d2] else nil
		if id then
			return (if attribute then Token.Attribute else Token.Name), self.symbols[id], id
		end
		local name = sub(self.source, first, i - 1)
		id = intern(self, name)
		if not subMap then
			longMap[d1] = { [d2] = id }
		else
			subMap[d2] = id
		end
		return (if attribute then Token.Attribute else Token.Name), name, id
	end
	local name = sub(self.source, first, i - 1)
	local id = intern(self, name)
	return (if attribute then Token.Attribute else Token.Name), name, id
end
local function unicode(self: any): number
	local buf = self.buf
	local i = self.i
	local c = readu8(buf, i - 1)
	local size, code = 0, 0
	if c >= 192 and c < 224 then
		size = 2
		code = band(c, 31)
	elseif c >= 224 and c < 240 then
		size = 3
		code = band(c, 15)
	elseif c >= 240 and c < 248 then
		size = 4
		code = band(c, 7)
	else
		self.i = i + 1
		if self.i >= self.nextCheckpoint then
			check(self)
		end
		self.error = "Invalid UTF-8 byte"
		self.hasExtra = true
		return Token.BrokenUnicode
	end
	i += 1
	if i >= self.nextCheckpoint then
		self.i = i
		check(self)
	end
	for _ = 2, size do
		c = readu8(buf, i - 1)
		if c < 128 or c >= 192 then
			self.i = i
			self.error = "Invalid UTF-8 sequence"
			self.hasExtra = true
			return Token.BrokenUnicode
		end
		code = lshift(code, 6) + band(c, 63)
		i += 1
		if i >= self.nextCheckpoint then
			self.i = i
			check(self)
		end
	end
	self.i = i
	self.codepoint = code
	self.value = code
	self.error = "Unexpected Unicode character"
	self.hasExtra = true
	return Token.BrokenUnicode
end
@native
local function minus(self: any, i: number): number
	local buf = self.buf
	local nextByte = readu8(buf, i)
	if nextByte == 45 then
		local source = self.source
		i += 2
		self.i = i
		local hasCp: boolean = self.hasCheckpoint
		local nextCp: number = self.nextCheckpoint
		if hasCp and i >= nextCp then
			check(self)
			nextCp = self.nextCheckpoint
		end
		local first = i
		if readu8(buf, i - 1) == 91 then
			local sep = separator(self)
			if sep >= 0 then
				return long(self, sep, Token.BlockComment, Token.BrokenComment)
			end
			i = self.i
			nextCp = self.nextCheckpoint
		end
		if not hasCp then
			while true do
				local ch = readu8(buf, i - 1)
				if ch == 0 or ch == 10 or ch == 13 then
					break
				end
				i += 1
			end
		else
			while true do
				local ch = readu8(buf, i - 1)
				if ch == 0 or ch == 10 or ch == 13 then
					break
				end
				i += 1
				if i >= nextCp then
					self.i = i
					check(self)
					nextCp = self.nextCheckpoint
				end
			end
		end
		self.i = i
		if not (self.skipComments and readu8(buf, first - 1) ~= 33) then
			self.value = sub(source, first, i - 1)
		end
		return Token.Comment
	elseif nextByte == 62 then
		self.i = i + 2
		if self.i >= self.nextCheckpoint then
			check(self)
		end
		return Token.SkinnyArrow
	elseif nextByte == 61 then
		self.i = i + 2
		if self.i >= self.nextCheckpoint then
			check(self)
		end
		return Token.SubAssign
	end
	self.i = i + 1
	if self.i >= self.nextCheckpoint then
		check(self)
	end
	return 45
end
@native
local function dot(self: any, i: number): number
	local buf = self.buf
	local nextByte = readu8(buf, i)
	if nextByte == 46 then
		local third = readu8(buf, i + 1)
		if third == 46 then
			self.i = i + 3
			if self.i >= self.nextCheckpoint then
				check(self)
			end
			return Token.Dot3
		elseif third == 61 then
			self.i = i + 3
			if self.i >= self.nextCheckpoint then
				check(self)
			end
			return Token.ConcatAssign
		end
		self.i = i + 2
		if self.i >= self.nextCheckpoint then
			check(self)
		end
		return Token.Dot2
	elseif nextByte >= 48 and nextByte <= 57 then
		self.i = i + 1
		if self.i >= self.nextCheckpoint then
			check(self)
		end
		return number(self, i)
	end
	self.i = i + 1
	if self.i >= self.nextCheckpoint then
		check(self)
	end
	return 46
end
@native
local function brace(self: any, c: number, i: number): number
	self.i = i + 1
	if self.i >= self.nextCheckpoint then
		check(self)
	end
	local braces = self.braces
	if c == 123 then
		if #braces > 0 then
			braces[#braces + 1] = false
		end
		return 123
	end
	local n = #braces
	if n > 0 then
		local interpolated = braces[n]
		braces[n] = nil
		if interpolated then
			return interpolation(self, Token.InterpStringMid, Token.InterpStringEnd)
		end
	end
	return 125
end
local function attribute(self: any, i: number): number
	local buf = self.buf
	i += 1
	self.i = i
	if i >= self.nextCheckpoint then
		check(self)
	end
	local nextByte = readu8(buf, i - 1)
	if nextByte == 91 then
		self.i = i + 1
		if self.i >= self.nextCheckpoint then
			check(self)
		end
		return Token.AttributeOpen
	elseif readu8(CHAR_MASK, nextByte) == 4 then
		local k, val, sym = scanName(self, true)
		self.value = val
		self.symbol = sym
		return k
	end
	self.value = ""
	self.symbol = intern(self, "")
	return Token.Attribute
end
@native
local function scan(self: any): number
	local buf: buffer = self.buf
	local i: number = self.i
	local c: number = readu8(buf, i - 1)
	local cls: number = readu8(SCAN_CLASS, c)
	if cls == 3 then
		if i <= self.length and not self.tailRecorded and not self.inLookahead then
			Lexer.retainTail(self)
		end
		return Token.Eof
	elseif cls == 4 then
		return quoted(self)
	elseif cls == 5 then
		return minus(self, i)
	elseif cls == 6 then
		return dot(self, i)
	elseif cls == 7 then
		local nextByte = readu8(buf, i)
		if nextByte ~= 91 and nextByte ~= 61 then
			self.i = i + 1
			if self.i >= self.nextCheckpoint then
				check(self)
			end
			return 91
		end
		local sep = separator(self)
		if sep >= 0 then
			return long(self, sep, Token.RawString, Token.BrokenString)
		else
			self.error = "Invalid long string delimiter"
			self.hasExtra = true
			return Token.BrokenString
		end
	elseif cls == 8 then
		self.i = i + 1
		if self.i >= self.nextCheckpoint then
			check(self)
		end
		return interpolation(self, Token.InterpStringBegin, Token.InterpStringSimple)
	elseif cls == 9 then
		return brace(self, c, i)
	elseif cls == 10 then
		local nextByte = readu8(buf, i)
		if nextByte == 47 then
			if readu8(buf, i + 1) == 61 then
				self.i = i + 3
				if self.i >= self.nextCheckpoint then
					check(self)
				end
				return Token.FloorDivAssign
			end
			self.i = i + 2
			if self.i >= self.nextCheckpoint then
				check(self)
			end
			return Token.FloorDiv
		elseif nextByte == 61 then
			self.i = i + 2
			if self.i >= self.nextCheckpoint then
				check(self)
			end
			return Token.DivAssign
		end
		self.i = i + 1
		if self.i >= self.nextCheckpoint then
			check(self)
		end
		return 47
	elseif cls == 12 then
		return attribute(self, i)
	else
		return unicode(self)
	end
end
function Lexer.rawText(self: any): string
	if self.raw ~= nil then
		return self.raw
	end
	local kind = self.kind
	if kind == Token.Number then
		return sub(self.source, self.start + 1, self.finish)
	elseif
		kind == Token.QuotedString
		or kind == Token.InterpStringBegin
		or kind == Token.InterpStringMid
		or kind == Token.InterpStringEnd
		or kind == Token.InterpStringSimple
	then
		return sub(self.source, self.start + 2, self.finish - 1)
	elseif kind == Token.RawString then
		local sepEnd = find(self.source, "[", self.start + 2, true)
		if sepEnd then
			return sub(self.source, sepEnd + 1, self.finish - (sepEnd - self.start))
		end
	end
	local val = self.value
	return if type(val) == "string" then val elseif val ~= nil then tostring(val) else ""
end
@native
function Lexer._scanInto(self: any, dst: any)
	if self.cached then
		self.cached = false
		local kind: number = self.cacheKind
		local start: number = self.cacheStart
		local finish: number = self.cacheFinish
		local value = self.cacheValue
		local symbol: number = self.cacheSymbol
		dst.kind, dst.start, dst.finish, dst.value, dst.symbol = kind, start, finish, value, symbol
		if self.cacheHasExtra or self.hasExtra then
			local cacheHasExtra = self.cacheHasExtra
			self.hasExtra = cacheHasExtra
			if cacheHasExtra then
				self.error, self.raw, self.codepoint, self.numberParseResult, self.tokenFinish =
					self.cacheError,
					self.cacheRaw,
					self.cacheCodepoint,
					self.cacheNumberParseResult,
					self.cacheTokenFinish
			else
				self.error, self.raw, self.codepoint, self.numberParseResult, self.tokenFinish = nil, nil, nil, nil, nil
			end
		end
		if kind == Token.Eof and self.i <= self.length and not self.tailRecorded then
			Lexer.retainTail(self)
		end
		return
	end
	local buf: buffer = self.buf
	local lineStarts = self.lineStarts
	local tape = self.tape
	local hasCp: boolean = self.hasCheckpoint
	local skipComments = self.skipComments
	while true do
		local i: number = self.i
		local first: number = i - 1
		local c: number
		if not hasCp then
			local lc: number = self.lineCount
			while true do
				c = readu8(buf, i - 1)
				if c == 32 then
					i += 1
				elseif c > 32 then
					break
				elseif c == 10 then
					lc += 1
					lineStarts[lc] = i
					i += 1
				elseif c == 9 or (c >= 11 and c <= 13) then
					i += 1
				else
					break
				end
			end
			self.lineCount = lc
		else
			local nextCp: number = self.nextCheckpoint
			while true do
				c = readu8(buf, i - 1)
				if readu8(CHAR_MASK, c) ~= 1 then
					break
				end
				if c == 10 then
					local lc: number = self.lineCount + 1
					self.lineCount = lc
					lineStarts[lc] = i
				end
				i += 1
				if i >= nextCp then
					self.i = i
					check(self)
					nextCp = self.nextCheckpoint
				end
			end
		end
		self.i = i
		local start: number = i - 1
		if tape and start > first then
			local n: number = tape.count + 1
			tape.kinds[n], tape.starts[n], tape.finishes[n], tape.count = Token.Whitespace, first, start, n
		end
		if self.hasExtra then
			self.hasExtra = false
			self.error, self.raw, self.codepoint, self.numberParseResult, self.tokenFinish = nil, nil, nil, nil, nil
		end
		local cls: number = readu8(SCAN_CLASS, c)
		if cls == 1 then
			local kind: number, val: any, sym: number = scanName(self, false)
			local rawEnd: number = self.i - 1
			dst.kind, dst.start, dst.finish, dst.value, dst.symbol = kind, start, rawEnd, val, sym
			if tape and rawEnd > start then
				local n: number = tape.count + 1
				tape.kinds[n], tape.starts[n], tape.finishes[n], tape.count = kind, start, rawEnd, n
			end
			if self.header then
				self.header = false
			end
			return
		elseif cls == 0 then
			local ni: number = i + 1
			self.i = ni
			if hasCp and ni >= self.nextCheckpoint then
				check(self)
			end
			dst.kind, dst.start, dst.finish, dst.value, dst.symbol = c, start, i, nil, 0
			if tape then
				local n: number = tape.count + 1
				tape.kinds[n], tape.starts[n], tape.finishes[n], tape.count = c, start, i, n
			end
			if self.header then
				self.header = false
			end
			return
		elseif cls == 14 then
			local ni: number = i + 1
			local kind: number
			if readu8(buf, i) == 61 then
				ni = i + 2
				kind = 256 + readu8(EQ_PAIR, c)
			else
				kind = c
			end
			self.i = ni
			if hasCp and ni >= self.nextCheckpoint then
				check(self)
			end
			local rawEnd: number = ni - 1
			dst.kind, dst.start, dst.finish, dst.value, dst.symbol = kind, start, rawEnd, nil, 0
			if tape then
				local n: number = tape.count + 1
				tape.kinds[n], tape.starts[n], tape.finishes[n], tape.count = kind, start, rawEnd, n
			end
			if self.header then
				self.header = false
			end
			return
		elseif cls == 2 then
			self.value, self.symbol = nil, 0
			local kind: number = number(self, i)
			local rawEnd: number = self.i - 1
			dst.kind, dst.start, dst.finish, dst.value, dst.symbol = kind, start, rawEnd, self.value, 0
			if tape and rawEnd > start then
				local n: number = tape.count + 1
				tape.kinds[n], tape.starts[n], tape.finishes[n], tape.count = kind, start, rawEnd, n
			end
			if self.header then
				self.header = false
			end
			return
		elseif cls == 9 and #self.braces == 0 then
			local ni: number = i + 1
			self.i = ni
			if hasCp and ni >= self.nextCheckpoint then
				check(self)
			end
			dst.kind, dst.start, dst.finish, dst.value, dst.symbol = c, start, i, nil, 0
			if tape then
				local n: number = tape.count + 1
				tape.kinds[n], tape.starts[n], tape.finishes[n], tape.count = c, start, i, n
			end
			if self.header then
				self.header = false
			end
			return
		elseif cls == 11 then
			local ni: number = i + 1
			local kind: number = 58
			if readu8(buf, i) == 58 then
				ni = i + 2
				kind = Token.DoubleColon
			end
			self.i = ni
			if hasCp and ni >= self.nextCheckpoint then
				check(self)
			end
			local rawEnd: number = ni - 1
			dst.kind, dst.start, dst.finish, dst.value, dst.symbol = kind, start, rawEnd, nil, 0
			if tape then
				local n: number = tape.count + 1
				tape.kinds[n], tape.starts[n], tape.finishes[n], tape.count = kind, start, rawEnd, n
			end
			if self.header then
				self.header = false
			end
			return
		end
		self.start = start
		self.value, self.symbol = nil, 0
		local kind: number = scan(self)
		local rawEnd: number = self.i - 1
		local finish: number = if self.hasExtra and self.tokenFinish then self.tokenFinish else rawEnd
		dst.kind, dst.start, dst.finish, dst.value, dst.symbol = kind, start, finish, self.value, self.symbol
		if tape and rawEnd > start then
			local n: number = tape.count + 1
			tape.kinds[n], tape.starts[n], tape.finishes[n], tape.count = kind, start, rawEnd, n
		end
		if kind == Token.Comment or kind == Token.BlockComment or kind == Token.BrokenComment then
			if self.captureComments then
				self.comments[#self.comments + 1] = { kind = kind, start = start, finish = finish }
			end
			if kind == Token.Comment and self.value and byte(self.value, 1) == 33 then
				local val = self.value
				local last = #val
				while last > 0 and readu8(CHAR_MASK, (byte(val, last))) == 1 do
					last -= 1
				end
				self.hotcomments[#self.hotcomments + 1] = {
					header = self.header,
					content = sub(val, 2, last),
					start = start,
					finish = finish,
				}
			end
			if skipComments and kind ~= Token.BrokenComment then
				continue
			end
		elseif kind ~= Token.Eof and self.header then
			self.header = false
		end
		return
	end
end
function Lexer.next(self: any): number
	Lexer._scanInto(self, self)
	return self.kind
end
@native
function Lexer.lookahead(self: any): (number, any)
	if not self.cached then
		local buf: buffer = self.buf
		local lineStarts = self.lineStarts
		local tape = self.tape
		local hasCp: boolean = self.hasCheckpoint
		local i: number = self.i
		local first: number = i - 1
		local c: number
		if not hasCp then
			local lc: number = self.lineCount
			while true do
				c = readu8(buf, i - 1)
				if c == 32 then
					i += 1
				elseif c > 32 then
					break
				elseif c == 10 then
					lc += 1
					lineStarts[lc] = i
					i += 1
				elseif c == 9 or (c >= 11 and c <= 13) then
					i += 1
				else
					break
				end
			end
			self.lineCount = lc
		else
			local nextCp: number = self.nextCheckpoint
			while true do
				c = readu8(buf, i - 1)
				if readu8(CHAR_MASK, c) ~= 1 then
					break
				end
				if c == 10 then
					local lc: number = self.lineCount + 1
					self.lineCount = lc
					lineStarts[lc] = i
				end
				i += 1
				if i >= nextCp then
					self.i = i
					check(self)
					nextCp = self.nextCheckpoint
				end
			end
		end
		self.i = i
		local start: number = i - 1
		if tape and start > first then
			local n: number = tape.count + 1
			tape.kinds[n], tape.starts[n], tape.finishes[n], tape.count = Token.Whitespace, first, start, n
		end
		local cls: number = readu8(SCAN_CLASS, c)
		if cls == 1 then
			local kind: number, val: any, sym: number = scanName(self, false)
			local rawEnd: number = self.i - 1
			self.cacheKind, self.cacheStart, self.cacheFinish, self.cacheValue, self.cacheSymbol, self.cacheHasExtra =
				kind, start, rawEnd, val, sym, false
			self.cached = true
			if tape and rawEnd > start then
				local n: number = tape.count + 1
				tape.kinds[n], tape.starts[n], tape.finishes[n], tape.count = kind, start, rawEnd, n
			end
			if self.header then
				self.header = false
			end
			return kind, val
		elseif cls == 0 then
			local ni: number = i + 1
			self.i = ni
			if hasCp and ni >= self.nextCheckpoint then
				check(self)
			end
			self.cacheKind, self.cacheStart, self.cacheFinish, self.cacheValue, self.cacheSymbol, self.cacheHasExtra =
				c, start, i, nil, 0, false
			self.cached = true
			if tape then
				local n: number = tape.count + 1
				tape.kinds[n], tape.starts[n], tape.finishes[n], tape.count = c, start, i, n
			end
			if self.header then
				self.header = false
			end
			return c, nil
		elseif cls == 14 then
			local ni: number = i + 1
			local kind: number
			if readu8(buf, i) == 61 then
				ni = i + 2
				kind = 256 + readu8(EQ_PAIR, c)
			else
				kind = c
			end
			self.i = ni
			if hasCp and ni >= self.nextCheckpoint then
				check(self)
			end
			local rawEnd: number = ni - 1
			self.cacheKind, self.cacheStart, self.cacheFinish, self.cacheValue, self.cacheSymbol, self.cacheHasExtra =
				kind, start, rawEnd, nil, 0, false
			self.cached = true
			if tape then
				local n: number = tape.count + 1
				tape.kinds[n], tape.starts[n], tape.finishes[n], tape.count = kind, start, rawEnd, n
			end
			if self.header then
				self.header = false
			end
			return kind, nil
		elseif cls == 11 then
			local ni: number = i + 1
			local kind: number = 58
			if readu8(buf, i) == 58 then
				ni = i + 2
				kind = Token.DoubleColon
			end
			self.i = ni
			if hasCp and ni >= self.nextCheckpoint then
				check(self)
			end
			local rawEnd: number = ni - 1
			self.cacheKind, self.cacheStart, self.cacheFinish, self.cacheValue, self.cacheSymbol, self.cacheHasExtra =
				kind, start, rawEnd, nil, 0, false
			self.cached = true
			if tape then
				local n: number = tape.count + 1
				tape.kinds[n], tape.starts[n], tape.finishes[n], tape.count = kind, start, rawEnd, n
			end
			if self.header then
				self.header = false
			end
			return kind, nil
		elseif cls == 9 and #self.braces == 0 then
			local ni: number = i + 1
			self.i = ni
			if hasCp and ni >= self.nextCheckpoint then
				check(self)
			end
			self.cacheKind, self.cacheStart, self.cacheFinish, self.cacheValue, self.cacheSymbol, self.cacheHasExtra =
				c, start, i, nil, 0, false
			self.cached = true
			if tape then
				local n: number = tape.count + 1
				tape.kinds[n], tape.starts[n], tape.finishes[n], tape.count = c, start, i, n
			end
			if self.header then
				self.header = false
			end
			return c, nil
		elseif cls == 6 then
			local nextByte: number = readu8(buf, i)
			if nextByte < 48 or nextByte > 57 then
				local ni: number = i + 1
				local kind: number = 46
				if nextByte == 46 then
					local third: number = readu8(buf, i + 1)
					if third == 46 then
						ni = i + 3
						kind = Token.Dot3
					elseif third == 61 then
						ni = i + 3
						kind = Token.ConcatAssign
					else
						ni = i + 2
						kind = Token.Dot2
					end
				end
				self.i = ni
				if hasCp and ni >= self.nextCheckpoint then
					check(self)
				end
				local rawEnd: number = ni - 1
				self.cacheKind, self.cacheStart, self.cacheFinish, self.cacheValue, self.cacheSymbol, self.cacheHasExtra =
					kind, start, rawEnd, nil, 0, false
				self.cached = true
				if tape then
					local n: number = tape.count + 1
					tape.kinds[n], tape.starts[n], tape.finishes[n], tape.count = kind, start, rawEnd, n
				end
				if self.header then
					self.header = false
				end
				return kind, nil
			end
		end
		local kind, firstTok, last, value, symbol, hasExtra =
			self.kind, self.start, self.finish, self.value, self.symbol, self.hasExtra
		local err, raw, codepoint, tokenFinish
		local numberParseResult = self.numberParseResult
		if hasExtra then
			err, raw, codepoint, tokenFinish = self.error, self.raw, self.codepoint, self.tokenFinish
		end
		self.inLookahead = true
		Lexer._scanInto(self, self)
		self.inLookahead = false
		local scannedHasExtra = self.hasExtra
		self.cacheKind, self.cacheStart, self.cacheFinish, self.cacheValue, self.cacheSymbol, self.cacheHasExtra =
			self.kind, self.start, self.finish, self.value, self.symbol, scannedHasExtra
		self.kind, self.start, self.finish, self.value, self.symbol = kind, firstTok, last, value, symbol
		if scannedHasExtra then
			self.cacheError, self.cacheRaw, self.cacheCodepoint, self.cacheNumberParseResult, self.cacheTokenFinish =
				self.error, self.raw, self.codepoint, self.numberParseResult, self.tokenFinish
		end
		self.numberParseResult = numberParseResult
		if hasExtra or scannedHasExtra then
			self.hasExtra = hasExtra
			if hasExtra then
				self.error, self.raw, self.codepoint, self.tokenFinish = err, raw, codepoint, tokenFinish
			else
				self.error, self.raw, self.codepoint, self.tokenFinish = nil, nil, nil, nil
			end
		end
		self.cached = true
	end
	return self.cacheKind, self.cacheValue
end
return Lexer
