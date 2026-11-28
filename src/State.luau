--!strict
-- Fresh Luau translation of parser bookkeeping. Luau upstream MIT LICENSE.md.
local Arena = require("./Arena")
local Diagnostics = require("./Diagnostics")
local Lexer = require("./Lexer")
local Profiles = require("./Profiles")
local Token = require("./Token")
local arenaList = Arena.list
local arenaList1 = Arena.list1
local arenaListFromRange = Arena.listFromRange
local lexerScanInto = Lexer._scanInto
local lexerLookahead = Lexer.lookahead
local ConfusablesMod: { [number]: string }? = nil
local punctuation: { [number]: string } = {
	[Token.Equal] = "'=='",
	[Token.LessEqual] = "'<='",
	[Token.GreaterEqual] = "'>='",
	[Token.NotEqual] = "'~='",
	[Token.Dot2] = "'..'",
	[Token.Dot3] = "'...'",
	[Token.SkinnyArrow] = "'->'",
	[Token.DoubleColon] = "'::'",
	[Token.FloorDiv] = "'//'",
	[Token.AddAssign] = "'+='",
	[Token.SubAssign] = "'-='",
	[Token.MulAssign] = "'*='",
	[Token.DivAssign] = "'/='",
	[Token.FloorDivAssign] = "'//='",
	[Token.ModAssign] = "'%='",
	[Token.PowAssign] = "'^='",
	[Token.ConcatAssign] = "'..='",
	[Token.AttributeOpen] = "'@['",
	[Token.BrokenString] = "malformed string",
	[Token.BrokenComment] = "unfinished comment",
	[Token.BrokenInterpDoubleBrace] = "'{{', which is invalid (did you mean '\\{'?)",
}
local State: any = {}
State.__index = State
function State.new(lexer: any, arena: any, options: any, scratch: any?): any
	local checkpoint = options.checkpoint
	local profile = options.flags or Profiles.resolve(options.profile)
	local self: any = setmetatable({
		lexer = lexer,
		arena = arena,
		nodes = arena.nodes,
		kinds = arena.kinds,
		starts = arena.starts,
		finishes = arena.finishes,
		bindings = arena.bindings,
		source = lexer.source,
		options = options,
		checkpoint = checkpoint,
		hasCheckpoint = checkpoint ~= nil,
		recursionLimit = options.recursionLimit or 1000,
		profile = profile,
		hasClasses = profile.DebugLuauUserDefinedClasses == true,
		hasExportValue = profile.LuauExportValueSyntax == true,
		diagnostics = {},
		locals = if scratch and scratch.locals then scratch.locals else {},
		localStack = if scratch and scratch.localStack then scratch.localStack else {},
		localTop = 0,
		listScratch = if scratch and scratch.listScratch then scratch.listScratch else {},
		listTop = 0,
		auxScratch = if scratch and scratch.auxScratch then scratch.auxScratch else {},
		auxTop = 0,
		functionDepth = 0,
		loopDepth = 0,
		blockDepth = 0,
		vararg = true,
		depth = 0,
		kind = 0,
		start = 0,
		finish = 0,
		previousStart = 0,
		previousFinish = 0,
		recoveryStops = if scratch and scratch.recoveryStops then scratch.recoveryStops else {},
		exportBindings = if scratch and scratch.exportBindings then scratch.exportBindings else {},
		typeFunctionDepth = 0,
		inClassMethodBody = false,
		work = 0,
	}, State)
	return self
end
@native
function State.advance(self: any)
	self.previousStart = self.start
	self.previousFinish = self.finish
	lexerScanInto(self.lexer, self)
	if self.hasCheckpoint then
		local work: number = self.work + 1
		self.work = work
		if bit32.band(work, 255) == 0 then
			local checkpoint: ((number) -> boolean?)? = self.checkpoint
			if checkpoint and checkpoint(self.start) == false then
				error({ parserSignal = "cancelled" }, 0)
			end
		end
	end
end
@native
function State.peek(self: any): (number, any)
	return lexerLookahead(self.lexer)
end
@native
function State.isName(self: any, name: string): boolean
	return self.kind == Token.Name and self.value == name
end
@native
function State.consume(self: any, kind: number): boolean
	if self.kind ~= kind then
		return false
	end
	State.advance(self)
	return true
end
@native
function State.sameLine(self: any, a: number, b: number): boolean
	-- Byte ranges make this cheap for adjacent tokens: only their intervening gap matters.
	if a >= b then
		return true
	end
	local lexer = self.lexer
	if a >= lexer.lineStarts[lexer.lineCount] then
		return true
	end
	local nl = string.find(self.source, "\n", a + 1, true)
	return nl == nil or nl > b
end
function State.tokenName(self: any, kind: number?): string
	local token = kind or self.kind
	local current = kind == nil
	if token == 0 then
		return "<eof>"
	end
	if token < 256 then
		return "'" .. string.char(token) .. "'"
	end
	if punctuation[token] then
		return punctuation[token]
	end
	if token == Token.Name then
		return if current then "'" .. tostring(self.value) .. "'" else "identifier"
	end
	if token == Token.Attribute then
		return if current then "'" .. tostring(self.value) .. "'" else "attribute"
	end
	if token == Token.Comment then
		return "comment"
	end
	if token >= Token.Reserved_BEGIN and token < Token.Reserved_END then
		return "'" .. string.lower(string.sub(Token.names[token], 9)) .. "'"
	end
	if not current then
		if token == Token.QuotedString or token == Token.RawString then
			return "string"
		elseif token == Token.Number then
			return "number"
		elseif token == Token.InterpStringBegin then
			return "the beginning of an interpolated string"
		elseif token == Token.InterpStringMid then
			return "the middle of an interpolated string"
		elseif token == Token.InterpStringEnd then
			return "the end of an interpolated string"
		elseif token == Token.InterpStringSimple then
			return "interpolated string"
		elseif token == Token.BrokenUnicode then
			return "invalid UTF-8 sequence"
		end
		return "<unknown>"
	end
	local lexer = self.lexer
	lexer.kind, lexer.start, lexer.finish, lexer.value = self.kind, self.start, self.finish, self.value
	local raw = lexer:rawText()
	if type(raw) ~= "string" then
		raw = tostring(raw)
	end
	local zero = string.find(raw, "\0", 1, true)
	if zero then
		raw = string.sub(raw, 1, zero - 1)
	end
	if token == Token.QuotedString or token == Token.RawString then
		return '"' .. raw .. '"'
	end
	if token == Token.Number then
		return "'" .. raw .. "'"
	end
	if token == Token.InterpStringBegin then
		return string.format("`%s{", raw)
	end
	if token == Token.InterpStringMid then
		return string.format("}%s{", raw)
	end
	if token == Token.InterpStringEnd then
		return string.format("}%s`", raw)
	end
	if token == Token.InterpStringSimple then
		return string.format("`%s`", raw)
	end
	if token == Token.BrokenUnicode then
		local code = self.lexer.codepoint
		if not code or code == 0 then
			return "invalid UTF-8 sequence"
		end
		local confusables = ConfusablesMod or require("./Confusables")
		ConfusablesMod = confusables
		local confusable = confusables[code]
		return string.format("Unicode character U+%x", code)
			.. (if confusable then " (did you mean '" .. confusable .. "'?)" else "")
	end
	return Token.names[token] or tostring(token)
end
function State.report(self: any, start: number, finish: number, message: string, code: string?): number
	local diagnostics = self.diagnostics
	local n = #diagnostics
	local last = diagnostics[n]
	if last and last.start == start and last.finish == finish then
		return n - 1
	end
	local limit = self.options.errorLimit or 100
	if not self.options.noErrorLimit and limit == 1 then
		error({ parserSignal = "limit", start = start, finish = finish, message = message }, 0)
	end
	n += 1
	diagnostics[n] = { start = start, finish = finish, message = message, code = code or "syntax" }
	if not self.options.noErrorLimit and n >= limit then
		error({
			parserSignal = "limit",
			start = start,
			finish = finish,
			message = "Reached error limit (" .. limit .. ")",
		}, 0)
	end
	return n - 1
end
@native
function State.expect(self: any, kind: number, context: string?): boolean
	if self.kind == kind then
		State.advance(self)
		return true
	end
	self:report(
		self.start,
		self.finish,
		"Expected "
			.. self:tokenName(kind)
			.. (if context then " when parsing " .. context else "")
			.. ", got "
			.. self:tokenName()
	)
	if self:peek() == kind then
		State.advance(self)
		State.advance(self)
	end
	return false
end
function State.recoveryPush(self: any, token: number)
	self.recoveryStops[token] = (self.recoveryStops[token] or 0) + 1
end
function State.recoveryPop(self: any, token: number)
	local count = self.recoveryStops[token] - 1
	self.recoveryStops[token] = if count > 0 then count else nil
end
function State.symbolFor(self: any, text: string): number
	return self.lexer:_intern(text)
end
@native
function State.expectName(self: any, context: string?): (number, number, number)
	local start: number = self.start
	local finish: number = self.finish
	if self.kind == Token.Name then
		local symbol: number = self.symbol
		State.advance(self)
		return symbol, start, finish
	end
	self:report(
		start,
		finish,
		"Expected identifier" .. (if context then " when parsing " .. context else "") .. ", got " .. self:tokenName()
	)
	return self:symbolFor("%error-id%"), start, start
end
@native
function State.node(self: any, node: any): number
	local arena = self.arena
	local id: number = arena.nodeCount + 1
	arena.nodeCount = id
	self.nodes[id] = node
	self.kinds[id] = node.kind
	self.starts[id] = node.start
	self.finishes[id] = node.finish
	return id
end
function State.list(self: any, items: { any }): number
	return arenaList(self.arena, items)
end
function State.list1(self: any, item: any): number
	return arenaList1(self.arena, item)
end
function State.beginList(self: any): number
	return self.listTop
end
function State.pushList(self: any, value: any)
	local top: number = self.listTop + 1
	self.listTop = top
	self.listScratch[top] = value
end
@native
function State.commitList(self: any, base: number): number
	local count: number = self.listTop - base
	self.listTop = base
	if count <= 0 then
		return 0
	end
	return arenaListFromRange(self.arena, self.listScratch, base + 1, count)
end
function State.beginAux(self: any): number
	return self.auxTop
end
function State.pushAux(self: any, value: any)
	local top: number = self.auxTop + 1
	self.auxTop = top
	self.auxScratch[top] = value
end
@native
function State.commitAux(self: any, base: number): number
	local count: number = self.auxTop - base
	self.auxTop = base
	if count <= 0 then
		return 0
	end
	return arenaListFromRange(self.arena, self.auxScratch, base + 1, count)
end
function State.mark(self: any): number
	return self.localTop
end
@native
function State.restore(self: any, mark: number)
	local stack = self.localStack
	local bindings = self.bindings
	local locals = self.locals
	for index = self.localTop, mark + 1, -1 do
		local binding = bindings[stack[index]]
		locals[binding.name] = binding.shadow
		stack[index] = nil
	end
	self.localTop = mark
end
@native
function State.bind(
	self: any,
	symbol: number,
	start: number,
	finish: number,
	annotation: number?,
	isConst: boolean?
): number
	local arena = self.arena
	local id: number = arena.bindingCount + 1
	arena.bindingCount = id
	local locals = self.locals
	self.bindings[id] = {
		name = symbol,
		start = start,
		finish = finish,
		annotation = annotation or 0,
		shadow = locals[symbol] or 0,
		functionDepth = self.functionDepth,
		loopDepth = self.loopDepth,
		scopeDepth = self.blockDepth,
		isConst = isConst or false,
		isExported = false,
	}
	locals[symbol] = id
	local top: number = self.localTop + 1
	self.localTop = top
	self.localStack[top] = id
	return id
end
function State.lookup(self: any, symbol: number): number
	return self.locals[symbol] or 0
end
function State.raiseRecursion(self: any, context: string?)
	error({
		parserSignal = "limit",
		start = self.start,
		finish = self.finish,
		message = "Exceeded allowed recursion depth; simplify your "
			.. (context or "syntax")
			.. " to make the code compile",
	}, 0)
end
function State.enter(self: any, context: string?)
	local depth = self.depth + 1
	self.depth = depth
	if depth > self.recursionLimit then
		self:raiseRecursion(context)
	end
end
@native
function State.expectClose(
	self: any,
	expected: number,
	opener: number,
	begin: number,
	search: boolean?,
	endMatch: boolean?
): boolean
	if self.kind == expected then
		if endMatch then
			local lexer = self.lexer
			local lineStarts = lexer.lineStarts
			local lineCount = lexer.lineCount
			local lastLineStart = lineStarts[lineCount]
			if begin < lastLineStart or self.start < lastLineStart then
				local line, column = Diagnostics.position(lineStarts, begin)
				local currentLine: number, currentColumn: number
				if self.start >= lastLineStart then
					currentLine, currentColumn = lineCount - 1, self.start - lastLineStart
				else
					currentLine, currentColumn = Diagnostics.position(lineStarts, self.start)
				end
				if currentLine ~= line and currentColumn ~= column then
					if not self.endMismatchLine or self.endMismatchLine < line then
						self.endMismatchKind = opener
						self.endMismatchLine = line
					end
				end
			end
		end
		State.advance(self)
		return true
	end
	local lineStarts = self.lexer.lineStarts
	local line, column = Diagnostics.position(lineStarts, begin)
	local currentLine = Diagnostics.position(lineStarts, self.start)
	local where = if currentLine == line then "column " .. tostring(column + 1) else "line " .. tostring(line + 1)
	local extra = ""
	local suspectLine = self.endMismatchLine
	if endMatch and suspectLine and suspectLine > line then
		extra = "; did you forget to close "
			.. self:tokenName(self.endMismatchKind)
			.. " at line "
			.. tostring(suspectLine + 1)
			.. "?"
	end
	self:report(
		self.start,
		self.finish,
		"Expected "
			.. self:tokenName(expected)
			.. " (to close "
			.. self:tokenName(opener)
			.. " at "
			.. where
			.. "), got "
			.. self:tokenName()
			.. extra
	)
	if search then
		local previousLine = Diagnostics.position(lineStarts, self.previousFinish)
		while self.kind ~= 0 and self.kind ~= expected and not self.recoveryStops[self.kind] do
			local current = Diagnostics.position(lineStarts, self.start)
			if current ~= previousLine then
				break
			end
			State.advance(self)
		end
		if self.kind == expected then
			State.advance(self)
			return true
		end
	elseif self:peek() == expected then
		State.advance(self)
		State.advance(self)
		return true
	end
	return false
end
return State
