--!strict
-- Optional lossless AST table materialization. Parsing and arena traversal allocate no table trees.
local Schema = require("./Schema")
local Arena = require("./Arena")
local Types = require("./Types")
local K = Arena.Kinds
local kindNames = Arena.kindNames

export type AstTable = Types.AstTable

local ACCESS_NAMES: { [number]: string } = {
	[1] = "read",
	[2] = "write",
	[3] = "readwrite",
}

local visitNode: (ctx: any, id: number) -> any

local function materializeBinding(ctx: any, id: number): AstTable?
	if id == 0 then
		return nil
	end
	local cached = ctx.bindings[id]
	if cached then
		return cached
	end
	local node = ctx.arenaBindings[id]
	local out: AstTable = {
		type = "AstLocal",
		name = ctx.symbols[node.name],
		start = node.start,
		finish = node.finish,
		isConst = node.isConst == true,
		isExported = node.isExported == true,
		functionDepth = node.functionDepth,
		loopDepth = node.loopDepth,
		scopeDepth = node.scopeDepth,
	}
	ctx.bindings[id] = out
	if node.annotation ~= 0 then
		out.luauType = visitNode(ctx, node.annotation)
	end
	return out
end

local function bindingList(ctx: any, id: number?): { AstTable? }
	if not id or id == 0 then
		return {} :: { AstTable? }
	end
	local count = ctx.listCounts[id]
	local first = ctx.listFirsts[id]
	local listValues = ctx.listValues
	local list: { AstTable? } = table.create(count) :: { AstTable? }
	for i = 1, count do
		list[i] = materializeBinding(ctx, listValues[first + i - 1])
	end
	return list
end

local function nodeList(ctx: any, id: number): { any }
	if id == 0 then
		return {}
	end
	local count = ctx.listCounts[id]
	local first = ctx.listFirsts[id]
	local listValues = ctx.listValues
	local out = table.create(count)
	for i = 1, count do
		local value = listValues[first + i - 1]
		out[i] = if value == 0 then false else visitNode(ctx, value)
	end
	return out
end

local function typeList(ctx: any, id: number, tail: number?): AstTable
	local out: AstTable = { type = "AstTypeList", types = nodeList(ctx, id) }
	if tail and tail ~= 0 then
		out.tailType = visitNode(ctx, tail)
	end
	return out
end

local function materializeItems(ctx: any, id: number): { AstTable }
	if id == 0 then
		return {} :: { AstTable }
	end
	local count = ctx.listCounts[id]
	local first = ctx.listFirsts[id]
	local listValues = ctx.listValues
	local list: { AstTable } = table.create(count) :: { AstTable }
	for i = 1, count do
		local item = listValues[first + i - 1]
		local rawKind = item.kind
		local itemKind = if rawKind == "List"
			then "item"
			elseif rawKind == "Record" then "record"
			elseif rawKind == "General" then "general"
			else string.lower(rawKind)
		local data: AstTable = { type = "AstExprTableItem", kind = itemKind, value = visitNode(ctx, item.value) }
		if item.key and item.key ~= 0 then
			data.key = visitNode(ctx, item.key)
		end
		list[i] = data
	end
	return list
end

local function finalizeNode(node: any, kindId: number, out: AstTable)
	if kindId == K.AstStatIf then
		out.hasThen = node.hasThen == true
	elseif kindId == K.AstExprLocal then
		out.upvalue = node.upvalue == true
	elseif kindId == K.AstExprConstantNumber then
		out.parseResult = node.parseResult or "Ok"
	elseif kindId == K.AstExprIndexName then
		if node.indexStart ~= nil then
			out.indexStart = node.indexStart
			out.indexFinish = node.indexFinish
		end
		out.privateAccess = node.privateAccess == true
	elseif kindId == K.AstExprCall and node.argStart ~= nil then
		out.argStart = node.argStart
		out.argFinish = node.argFinish
	elseif kindId == K.AstStatLocal then
		out.isConst = node.isConst == true
		out.isExported = node.isExported == true
	elseif kindId == K.AstStatLocalFunction then
		out.isConst = node.isConst == true
		if node.constKeywordBegin ~= nil then
			out.constKeywordBegin = node.constKeywordBegin
		end
	elseif kindId == K.AstTableProp or kindId == K.AstTableIndexer then
		out.access = ACCESS_NAMES[node.access] or "readwrite"
		if node.accessStart ~= nil then
			out.accessStart = node.accessStart
		end
	elseif kindId == K.AstTypeReference then
		out.nameStart = node.nameStart
		out.nameFinish = node.nameFinish
		out.hasParameterList = node.hasParameterList == true
		if node.prefix and node.prefix ~= 0 then
			out.prefixStart = node.prefixStart
			out.prefixFinish = node.prefixFinish
		end
	elseif
		kindId == K.AstStatDeclareFunction
		or kindId == K.AstStatDeclareGlobal
		or kindId == K.AstStatTypeFunction
		or kindId == K.AstStatTypeAlias
	then
		out.nameStart = node.nameStart
		out.nameFinish = node.nameFinish
	elseif kindId == K.AstDeclaredExternTypeProperty then
		out.nameStart = node.nameStart
		out.nameFinish = node.nameFinish
		out.isMethod = node.isMethod == true
		out.access = ACCESS_NAMES[node.access] or "readwrite"
	elseif kindId == K.AstClassProperty or kindId == K.AstClassMethod then
		out.nameStart = node.nameStart
		out.nameFinish = node.nameFinish
		if node.qualifierStart ~= nil then
			out.qualifierStart = node.qualifierStart
			out.qualifierFinish = node.qualifierFinish
		end
		if kindId == K.AstClassProperty and node.typeColonStart ~= nil then
			out.typeColonStart = node.typeColonStart
			out.typeColonFinish = node.typeColonFinish
		elseif kindId == K.AstClassMethod and node.functionKeywordStart ~= nil then
			out.functionKeywordStart = node.functionKeywordStart
			out.functionKeywordFinish = node.functionKeywordFinish
		end
	elseif kindId == K.AstAttr and node.type ~= nil then
		out.attrType = node.type
	end
end

function visitNode(ctx: any, id: number): any
	if id == 0 then
		return nil
	end
	local cached = ctx.memo[id]
	if cached then
		return cached
	end
	local node = ctx.nodes[id]
	local kindId = node.kind
	local symbols = ctx.symbols
	local arena = ctx.arena
	local out: AstTable = {
		type = kindNames[kindId],
		start = node.start,
		finish = node.finish,
	}
	ctx.memo[id] = out
	local descriptors: { any }? = Schema[kindId]
	if descriptors then
		for _, descriptor in descriptors do
			local key, category, output = descriptor[1], descriptor[2], descriptor[3] or descriptor[1]
			local value = node[key]
			if category == "n" then
				if value and value ~= 0 then
					out[output] = visitNode(ctx, value)
				end
			elseif category == "b" or category == "local" then
				if value and value ~= 0 then
					out[output] = materializeBinding(ctx, value)
				end
			elseif category == "s" then
				if value and value ~= 0 then
					out[output] = symbols[value]
				elseif kindId == K.AstExprFunction and key == "debugname" then
					out[output] = ""
				end
			elseif category == "l" then
				out[output] = nodeList(ctx, value or 0)
			elseif category == "B" then
				out[output] = bindingList(ctx, value)
			elseif category == "r" then
				out[output] = arena:listItems(value or 0)
			elseif category == "p" then
				if value then
					out[output] = { start = value.start, finish = value.finish }
				end
			elseif category == "typelist" then
				local tailKey = descriptor[4]
				out[output] = typeList(ctx, value or 0, if tailKey then node[tailKey] else nil)
			elseif category == "items" then
				out[output] = materializeItems(ctx, value or 0)
			elseif value ~= nil then
				out[output] = value
			end
		end
	end
	finalizeNode(node, kindId, out)
	return out
end

--- Optional lossless AST table serialization for arena-backed `ParseResult` values.
local Ast = {}

--- Materializes an arena-backed `ParseResult` into lossless AST tables with numeric byte spans.
function Ast.toTables(result: Types.ParseResult): AstTable?
	if type(result) ~= "table" or type((result :: any).arena) ~= "table" or type((result :: any).root) ~= "number" then
		error("Ast.toTables expected a ParseResult", 2)
	end
	if result.root == 0 then
		return nil
	end
	local arena = result.arena
	local nodes = arena.nodes
	local arenaBindings = arena.bindings
	local ctx = {
		arena = arena,
		nodes = nodes,
		listFirsts = arena.listFirsts,
		listCounts = arena.listCounts,
		listValues = arena.listValues,
		symbols = arena.symbols,
		arenaBindings = arenaBindings,
		memo = table.create(#nodes),
		bindings = table.create(#arenaBindings),
	}
	return visitNode(ctx, result.root)
end

return table.freeze(Ast)
