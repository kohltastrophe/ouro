--!strict
local Lexer = require("./Lexer")
local Arena = require("./Arena")
local State = require("./State")
local Runtime = require("./RuntimeParser")
local TypeParser = require("./TypeParser")
local Profiles = require("./Profiles")
local Diagnostics = require("./Diagnostics")
local Types = require("./Types")

local DeclarationsMod: any = nil
local function getDeclarations(): any
	local mod = DeclarationsMod
	if mod == nil then
		mod = require("./Declarations")
		DeclarationsMod = mod
	end
	return mod
end

local OP_NODE = 1
local OP_LIST = 2
local OP_TYPELIST = 3
local OP_ITEMS = 4
local OP_BINDING = 5
local OP_BINDING_LIST = 6

local ChildOpsMod: { [number]: { any } }? = nil
local function getChildOps(): { [number]: { any } }
	local cached = ChildOpsMod
	if cached ~= nil then
		return cached
	end
	local schema = require("./Schema")
	local ops: { [number]: { any } } = {}
	for kindId, fields in schema :: { [any]: any } do
		if type(kindId) == "number" then
			local list: { any } = {}
			local n = 0
			for _, field in fields do
				local key, category = field[1], field[2]
				if category == "n" then
					n += 1
					list[n] = { OP_NODE, key }
				elseif category == "l" then
					n += 1
					list[n] = { OP_LIST, key }
				elseif category == "typelist" then
					n += 1
					list[n] = { OP_TYPELIST, key, field[4] }
				elseif category == "items" then
					n += 1
					list[n] = { OP_ITEMS, key }
				elseif category == "b" then
					n += 1
					list[n] = { OP_BINDING, key }
				elseif category == "B" then
					n += 1
					list[n] = { OP_BINDING_LIST, key }
				end
			end
			if n > 0 then
				ops[kindId] = list
			end
		end
	end
	ChildOpsMod = ops
	return ops
end
export type ParseOptions = Types.ParseOptions
export type ParseResult = Types.ParseResult
export type ParserContext = Types.ParserContext
export type GrammarFlags = Types.GrammarFlags
for key, fn in
	{
		["parseType"] = TypeParser.parseType,
		["parseTypePack"] = TypeParser.parseTypePack,
		["parseGenerics"] = TypeParser.parseGenerics,
		["parseTypeStatement"] = TypeParser.parseTypeStatement,
		["parseTypeParams"] = TypeParser.parseTypeParams,
		["parseDeclaration"] = function(...: any)
			return getDeclarations().declareStat(...)
		end,
		["parseClass"] = function(...: any)
			return getDeclarations().classDef(...)
		end,
		["parseExpression"] = Runtime.expression,
		["parseFunction"] = Runtime.functionBody,
		["parseAttributes"] = Runtime.attributes,
	} :: { [string]: any }
do
	State[key] = fn
end

local BOOLEAN_KEYS = table.freeze({
	"lossless",
	"captureComments",
	"allowDeclarationSyntax",
	"requireEOF",
	"noErrorLimit",
})
local defaultPublicOptions: ParseOptions = {
	profile = "upstream" :: "upstream",
	allowDeclarationSyntax = false,
	captureComments = false,
}
local DEFAULT_PUBLIC_OPTIONS: ParseOptions = (table.freeze(defaultPublicOptions) :: unknown) :: ParseOptions
local DEFAULT_OPTIONS = table.freeze({
	flags = Profiles.resolve(nil),
	allowDeclarationSyntax = false,
	captureComments = false,
})
local LIMIT_KEYS = table.freeze({ "recursionLimit", "typeLengthLimit", "errorLimit", "checkpointInterval" })
local VALID_OPTION_KEYS: { [string]: boolean } = table.freeze({
	profile = true,
	lossless = true,
	captureComments = true,
	allowDeclarationSyntax = true,
	requireEOF = true,
	noErrorLimit = true,
	recursionLimit = true,
	typeLengthLimit = true,
	errorLimit = true,
	checkpointInterval = true,
	checkpoint = true,
} :: { [string]: boolean })

local Parser: any = {}
local function completeLines(self: any)
	if self.lineStartsComplete then
		return
	end
	local lineStarts = self.lineStarts
	local lineCount = #lineStarts
	local source = self.source
	local cursor = lineStarts[lineCount] + 1
	while true do
		local at = string.find(source, "\n", cursor, true)
		if not at then
			break
		end
		lineCount += 1
		lineStarts[lineCount] = at
		cursor = at + 1
	end
	self.lineStartsComplete = true
end
local function listChild(
	listValues: { any },
	listFirst: number,
	listCount: number,
	fieldName: string,
	count: number,
	wanted: number
): (number, number)
	if fieldName == "argNames" then
		for i = 0, listCount - 1 do
			local nextId = listValues[listFirst + i]
			if nextId ~= 0 then
				count += 1
				if count == wanted then
					return nextId, count
				end
			end
		end
		return 0, count
	elseif wanted > count and wanted <= count + listCount then
		return listValues[listFirst + wanted - count - 1], wanted
	end
	return 0, count + listCount
end
local function itemsChild(
	listValues: { any },
	listFirst: number,
	listCount: number,
	count: number,
	wanted: number
): (number, number)
	for i = 0, listCount - 1 do
		local item = listValues[listFirst + i]
		if item.key and item.key ~= 0 then
			count += 1
			if count == wanted then
				return item.key, count
			end
		end
		count += 1
		if count == wanted then
			return item.value, count
		end
	end
	return 0, count
end
local function child(self: any, id: number, wanted: number): (number, number)
	if id == 0 then
		return 0, 0
	end
	local arena = self.arena
	local node = arena.nodes[id]
	if not node then
		return 0, 0
	end
	local ops = getChildOps()[node.kind]
	if not ops then
		return 0, 0
	end
	local listFirsts, listCounts, listValues, bindings =
		arena.listFirsts, arena.listCounts, arena.listValues, arena.bindings
	local count = 0
	for i = 1, #ops do
		local op = ops[i]
		local category = op[1]
		local value = node[op[2]]
		if category == OP_NODE then
			if value and value ~= 0 then
				count += 1
				if count == wanted then
					return value, count
				end
			end
		elseif category == OP_LIST then
			if value and value ~= 0 then
				local found: number
				found, count = listChild(listValues, listFirsts[value], listCounts[value], op[2], count, wanted)
				if found ~= 0 then
					return found, count
				end
			end
		elseif category == OP_TYPELIST then
			if value and value ~= 0 then
				local found: number
				found, count = listChild(listValues, listFirsts[value], listCounts[value], op[2], count, wanted)
				if found ~= 0 then
					return found, count
				end
			end
			local tailKey = op[3]
			local tail = if tailKey then node[tailKey] else nil
			if tail and tail ~= 0 then
				count += 1
				if count == wanted then
					return tail, count
				end
			end
		elseif category == OP_ITEMS and value and value ~= 0 then
			local found: number
			found, count = itemsChild(listValues, listFirsts[value], listCounts[value], count, wanted)
			if found ~= 0 then
				return found, count
			end
		elseif category == OP_BINDING and value and value ~= 0 then
			local annotation = bindings[value].annotation
			if annotation ~= 0 then
				count += 1
				if count == wanted then
					return annotation, count
				end
			end
		elseif category == OP_BINDING_LIST and value and value ~= 0 then
			local listFirst, listCount = listFirsts[value], listCounts[value]
			for j = 0, listCount - 1 do
				local annotation = bindings[listValues[listFirst + j]].annotation
				if annotation ~= 0 then
					count += 1
					if count == wanted then
						return annotation, count
					end
				end
			end
		end
	end
	return 0, count
end
local Result: any = {
	kind = function(self: any, id: number): number
		if id == 0 then
			return 0
		end
		return self.arena.kinds[id] or 0
	end,
	kindName = function(self: any, id: number): string
		return self.arena:kindName(id)
	end,
	range = function(self: any, id: number): (number, number)
		if id == 0 then
			return 0, 0
		end
		local arena = self.arena
		local s = arena.starts[id]
		if s == nil then
			return 0, 0
		end
		return s, arena.finishes[id]
	end,
	position = function(self: any, offset: number): (number, number)
		assert(
			type(offset) == "number" and offset == math.floor(offset) and offset >= 0 and offset <= #self.source,
			"offset outside source"
		)
		completeLines(self)
		return Diagnostics.position(self.lineStarts, offset)
	end,
	offset = function(self: any, line: number, column: number): number
		assert(type(line) == "number" and line == math.floor(line), "line must be an integer")
		assert(type(column) == "number" and column == math.floor(column), "column must be an integer")
		completeLines(self)
		local start = self.lineStarts[line + 1]
		assert(start and column >= 0, "invalid source position")
		local finish = if self.lineStarts[line + 2] then self.lineStarts[line + 2] - 1 else #self.source
		assert(start + column <= finish, "column outside line")
		return start + column
	end,
	childCount = function(self: any, id: number): number
		local _, count = child(self, id, 0)
		return count
	end,
	childAt = function(self: any, id: number, index: number): number
		assert(type(index) == "number" and index == math.floor(index) and index >= 1, "child index must be positive")
		local value = child(self, id, index)
		return value
	end,
	forEachChild = function(self: any, id: number, fn: (number) -> boolean?)
		if type(id) ~= "number" or id ~= math.floor(id) or id < 0 then
			error("forEachChild nodeId must be a non-negative integer", 2)
		end
		if type(fn) ~= "function" then
			error("forEachChild callback must be a function", 2)
		end
		if id == 0 then
			return
		end
		local arena = self.arena
		local node = arena.nodes[id]
		if not node then
			return
		end
		local ops = getChildOps()[node.kind]
		if not ops then
			return
		end
		local listFirsts, listCounts, listValues, bindings =
			arena.listFirsts, arena.listCounts, arena.listValues, arena.bindings
		for i = 1, #ops do
			local op = ops[i]
			local category = op[1]
			local value = node[op[2]]
			if category == OP_NODE then
				if value and value ~= 0 and fn(value) == false then
					return
				end
			elseif category == OP_LIST then
				if value and value ~= 0 then
					local first = listFirsts[value]
					local count = listCounts[value]
					for j = first, first + count - 1 do
						local cid = listValues[j]
						if cid ~= 0 and fn(cid) == false then
							return
						end
					end
				end
			elseif category == OP_TYPELIST then
				if value and value ~= 0 then
					local first = listFirsts[value]
					local count = listCounts[value]
					for j = first, first + count - 1 do
						local cid = listValues[j]
						if cid ~= 0 and fn(cid) == false then
							return
						end
					end
				end
				local tailKey = op[3]
				local tail = if tailKey then node[tailKey] else nil
				if tail and tail ~= 0 and fn(tail) == false then
					return
				end
			elseif category == OP_ITEMS then
				if value and value ~= 0 then
					local first = listFirsts[value]
					local count = listCounts[value]
					for j = first, first + count - 1 do
						local item = listValues[j]
						local k = item.key
						if k and k ~= 0 and fn(k) == false then
							return
						end
						local v = item.value
						if v and v ~= 0 and fn(v) == false then
							return
						end
					end
				end
			elseif category == OP_BINDING then
				if value and value ~= 0 then
					local annotation = bindings[value].annotation
					if annotation ~= 0 and fn(annotation) == false then
						return
					end
				end
			elseif category == OP_BINDING_LIST then
				if value and value ~= 0 then
					local first = listFirsts[value]
					local count = listCounts[value]
					for j = first, first + count - 1 do
						local annotation = bindings[listValues[j]].annotation
						if annotation ~= 0 and fn(annotation) == false then
							return
						end
					end
				end
			end
		end
	end,
	visit = function(self: any, visitor: any)
		local enterFn: ((number, number, number) -> boolean?)? = nil
		local leaveFn: ((number, number, number) -> ())? = nil
		local vType = type(visitor)
		if vType == "function" then
			enterFn = visitor :: (number, number, number) -> boolean?
		elseif vType == "table" then
			for k in visitor do
				if k ~= "enter" and k ~= "leave" then
					error("Unknown AstVisitor key: " .. tostring(k), 2)
				end
			end
			local vTbl = visitor :: Types.AstVisitor
			if vTbl.enter ~= nil and type(vTbl.enter) ~= "function" then
				error("AstVisitor.enter must be a function", 2)
			end
			if vTbl.leave ~= nil and type(vTbl.leave) ~= "function" then
				error("AstVisitor.leave must be a function", 2)
			end
			enterFn = vTbl.enter
			leaveFn = vTbl.leave
		else
			error("visit expects a function or AstVisitor table", 2)
		end
		local rootId = self.root
		if rootId == 0 then
			return
		end
		if enterFn == nil and leaveFn == nil then
			return
		end
		local onEnter: ((number, number, number) -> boolean?)? = if enterFn ~= nil then enterFn :: any else nil
		local onLeave: ((number, number, number) -> ())? = if leaveFn ~= nil then leaveFn :: any else nil
		local arena = self.arena
		local nodes = arena.nodes
		local kinds = arena.kinds
		local listFirsts = arena.listFirsts
		local listCounts = arena.listCounts
		local listValues = arena.listValues
		local bindings = arena.bindings
		local childOps = getChildOps()
		local function walk(nodeId: number, depth: number)
			local nodeKind = kinds[nodeId] or 0
			local descend = true
			if onEnter ~= nil then
				if onEnter(nodeId, nodeKind, depth) == false then
					descend = false
				end
			end
			if descend then
				local ops = childOps[nodeKind]
				if ops then
					local node = nodes[nodeId]
					local nextDepth = depth + 1
					for i = 1, #ops do
						local op = ops[i]
						local category = op[1]
						local value = node[op[2]]
						if category == OP_NODE then
							if value and value ~= 0 then
								walk(value, nextDepth)
							end
						elseif category == OP_LIST then
							if value and value ~= 0 then
								local first = listFirsts[value]
								local count = listCounts[value]
								for j = first, first + count - 1 do
									local cid = listValues[j]
									if cid ~= 0 then
										walk(cid, nextDepth)
									end
								end
							end
						elseif category == OP_TYPELIST then
							if value and value ~= 0 then
								local first = listFirsts[value]
								local count = listCounts[value]
								for j = first, first + count - 1 do
									local cid = listValues[j]
									if cid ~= 0 then
										walk(cid, nextDepth)
									end
								end
							end
							local tailKey = op[3]
							local tail = if tailKey then node[tailKey] else nil
							if tail and tail ~= 0 then
								walk(tail, nextDepth)
							end
						elseif category == OP_ITEMS then
							if value and value ~= 0 then
								local first = listFirsts[value]
								local count = listCounts[value]
								for j = first, first + count - 1 do
									local item = listValues[j]
									local k = item.key
									if k and k ~= 0 then
										walk(k, nextDepth)
									end
									local v = item.value
									if v and v ~= 0 then
										walk(v, nextDepth)
									end
								end
							end
						elseif category == OP_BINDING then
							if value and value ~= 0 then
								local annotation = bindings[value].annotation
								if annotation ~= 0 then
									walk(annotation, nextDepth)
								end
							end
						elseif category == OP_BINDING_LIST then
							if value and value ~= 0 then
								local first = listFirsts[value]
								local count = listCounts[value]
								for j = first, first + count - 1 do
									local annotation = bindings[listValues[j]].annotation
									if annotation ~= 0 then
										walk(annotation, nextDepth)
									end
								end
							end
						end
					end
				end
			end
			if onLeave ~= nil then
				onLeave(nodeId, nodeKind, depth)
			end
		end
		walk(rootId, 0)
	end,
	reconstruct = function(self: any): string
		if not self.tape then
			return self.source
		end
		local parts = table.create(self.tape.count)
		local cursor = 0
		for i = 1, self.tape.count do
			assert(self.tape.starts[i] == cursor, "lossless tape has a gap or overlap")
			cursor = self.tape.finishes[i]
			parts[i] = string.sub(self.source, self.tape.starts[i] + 1, cursor)
		end
		assert(cursor == #self.source, "lossless tape does not cover source")
		return table.concat(parts)
	end,
}
Result.__index = Result
local function parseEntry(state: any, entry: string): number
	state:advance()
	local root: number
	if entry == "expression" then
		root = Runtime.expression(state)
	elseif entry == "type" then
		root = TypeParser.parseType(state)
	else
		root = Runtime.parseChunk(state)
	end
	if state.kind ~= 0 and (entry == "chunk" or state.options.requireEOF) then
		state:report(state.start, state.finish, "Expected <eof>, got " .. state:tokenName())
	end
	return root
end
local function run(source: string, options: any, entry: string, scratch: any?): any
	local lexer = Lexer.new(source, options, scratch)
	local arena = Arena.new(lexer.symbols, #source, lexer.ownSymbolMap)
	local state = State.new(lexer, arena, options, scratch)
	local ok, resultOrSignal: any = pcall(parseEntry, state, entry)
	local diagnostics = state.diagnostics
	local status = if #diagnostics == 0 then "ok" else "syntaxError"
	local root = if ok then resultOrSignal else 0
	if not ok then
		if type(resultOrSignal) ~= "table" or not resultOrSignal.parserSignal then
			error(resultOrSignal, 0)
		end
		status = resultOrSignal.parserSignal
		if status == "limit" then
			diagnostics[#diagnostics + 1] = {
				start = resultOrSignal.start or lexer.start,
				finish = resultOrSignal.finish or lexer.finish,
				message = resultOrSignal.message or "Parser limit exceeded",
				code = "limit",
			}
		end
	end
	lexer:retainTail()
	local result = setmetatable({
		status = status,
		root = root,
		arena = arena,
		source = source,
		diagnostics = diagnostics,
		lineStarts = lexer.lineStarts,
		comments = lexer.comments,
		hotcomments = lexer.hotcomments,
		tape = lexer.tape,
		profile = if type(options.profile) == "table" then "custom" else options.profile or "upstream",
		flags = options.flags,
		lineStartsComplete = ok and lexer.kind == 0 and lexer.i > lexer.length,
	}, Result)
	if ok then
		completeLines(result)
	end
	return result
end
local function options(value: any): (any, ParseOptions)
	if value == nil then
		return DEFAULT_OPTIONS, DEFAULT_PUBLIC_OPTIONS
	end
	assert(type(value) == "table", "parse options must be a table")
	for key in value :: { [any]: any } do
		assert(type(key) == "string" and VALID_OPTION_KEYS[key], "Unknown parse option: " .. tostring(key))
	end
	local out = table.clone(value)
	local flags = Profiles.resolve(out.profile)
	local publicRaw = table.clone(value)
	for _, key in BOOLEAN_KEYS do
		local v = out[key]
		assert(v == nil or type(v) == "boolean", key .. " must be a boolean")
	end
	assert(out.checkpoint == nil or type(out.checkpoint) == "function", "checkpoint must be a function")
	if out.allowDeclarationSyntax == nil then
		out.allowDeclarationSyntax = false
		publicRaw.allowDeclarationSyntax = false
	end
	if out.captureComments == nil then
		local cap = out.lossless == true
		out.captureComments = cap
		publicRaw.captureComments = cap
	end
	out.flags = flags
	for _, key in LIMIT_KEYS do
		local number = out[key]
		assert(
			number == nil
				or (type(number) == "number" and number >= 1 and number == math.floor(number) and number < math.huge),
			key .. " must be a finite positive integer"
		)
	end
	if publicRaw.profile == nil then
		publicRaw.profile = "upstream"
	elseif type(publicRaw.profile) == "table" then
		publicRaw.profile = table.freeze(table.clone(publicRaw.profile))
	end
	local publicOut: ParseOptions = (table.freeze(publicRaw) :: any) :: ParseOptions
	return table.freeze(out), publicOut
end
--- Parses a Luau source chunk into an arena-backed ParseResult.
function Parser.parse(source: string, opts: ParseOptions?): ParseResult
	if type(source) ~= "string" then
		error("Parser.parse expected source string, got " .. type(source), 2)
	end
	local settings = options(opts)
	return run(source, settings, "chunk")
end
--- Parses a standalone Luau expression into an arena-backed ParseResult.
function Parser.parseExpression(source: string, opts: ParseOptions?): ParseResult
	if type(source) ~= "string" then
		error("Parser.parseExpression expected source string, got " .. type(source), 2)
	end
	local settings = options(opts)
	return run(source, settings, "expression")
end
--- Parses a standalone Luau type annotation into an arena-backed ParseResult.
function Parser.parseType(source: string, opts: ParseOptions?): ParseResult
	if type(source) ~= "string" then
		error("Parser.parseType expected source string, got " .. type(source), 2)
	end
	local settings = options(opts)
	return run(source, settings, "type")
end
local function newScratch()
	return {
		locals = {},
		localStack = {},
		recoveryStops = {},
		symbolMap = {},
		shortSymMap = {},
		braces = {},
		listScratch = {},
		auxScratch = {},
		exportBindings = {},
		buf = nil :: buffer?,
	}
end
--- Creates a reusable parser context that recycles internal scratch tables across parses.
function Parser.newContext(opts: ParseOptions?): ParserContext
	local settings, publicOpts = options(opts)
	local scratch = newScratch()
	local activeThread: thread? = nil
	local generation = 0
	local context: any
	local function reset(self: any)
		assert(self == context, "invalid parser context receiver")
		generation += 1
		scratch = newScratch()
		activeThread = nil
		self.busy = false
	end
	local function execute(self: any, source: string, entry: string): any
		assert(self == context, "invalid parser context receiver")
		if type(source) ~= "string" then
			error("ParserContext expected source string, got " .. type(source), 2)
		end
		if activeThread ~= nil then
			if coroutine.status(activeThread) ~= "dead" then
				error("Parser context is already in use", 2)
			end
			context:reset()
		end
		generation += 1
		local myGen = generation
		local runScratch = scratch
		activeThread = coroutine.running()
		self.busy = true
		local ok, result = pcall(run, source, settings, entry, runScratch)
		if generation == myGen then
			if #source > 262144 then
				scratch = newScratch()
			else
				for _, t in runScratch :: any do
					if type(t) == "table" then
						table.clear(t)
					end
				end
			end
			activeThread = nil
			self.busy = false
		end
		if not ok then
			error(result, 0)
		end
		return result
	end
	local function bindEntry(entry: string)
		return function(self: any, source: string): any
			return execute(self, source, entry)
		end
	end
	context = {
		busy = false,
		options = publicOpts,
		reset = reset,
		parse = bindEntry("chunk"),
		parseExpression = bindEntry("expression"),
		parseType = bindEntry("type"),
	}
	return context
end
return table.freeze(Parser) :: {
	parse: (string, ParseOptions?) -> ParseResult,
	parseExpression: (string, ParseOptions?) -> ParseResult,
	parseType: (string, ParseOptions?) -> ParseResult,
	newContext: (ParseOptions?) -> ParserContext,
}
