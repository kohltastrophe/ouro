--!strict
-- Differential adapter preserving upstream C++ AstJsonEncoder output for oracle comparison.
local Schema = require("../src/Schema")
local Diagnostics = require("../src/Diagnostics")
local Arena = require("../src/Arena")
local K = Arena.Kinds
local kindNames = Arena.kindNames

export type AstNull = { __parserNull: boolean }
export type AstTable = { [string]: any }

local nullSentinel: AstNull = table.freeze({ __parserNull = true }) :: any
local visitNode: (ctx: any, id: number) -> any

local function loc(ctx: any, a: number?, b: number?): string
	local text, nextIdx = Diagnostics.locationCursor(ctx.lineStarts, a or 0, b or 0, ctx.lastLineIdx)
	ctx.lastLineIdx = nextIdx
	return text
end
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
		isConst = node.isConst or false,
		location = loc(ctx, node.start, node.finish),
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
		out[i] = if value == 0 then nullSentinel else visitNode(ctx, value)
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
local function finalizeNode(ctx: any, node: any, kindId: number, out: AstTable)
	if kindId == K.AstStatIf then
		out.hasThen = node.hasThen == true
	end
	if kindId == K.AstExprIndexName and node.indexStart ~= nil then
		out.indexLocation = loc(ctx, node.indexStart, node.indexFinish)
	elseif kindId == K.AstExprCall then
		out.typeArguments = nil
		if node.argStart ~= nil then
			out.argLocation = loc(ctx, node.argStart, node.argFinish)
		end
	elseif kindId == K.AstAttr then
		out.args = nil
	elseif kindId == K.AstStatDeclareExternType then
		out.type = "AstStatDeclareClass"
	elseif
		kindId == K.AstTypeReference
		or kindId == K.AstStatDeclareFunction
		or kindId == K.AstStatDeclareGlobal
		or kindId == K.AstStatTypeFunction
	then
		out.nameLocation = loc(ctx, node.nameStart, node.nameFinish)
		if kindId == K.AstTypeReference and node.prefix and node.prefix ~= 0 then
			out.prefixLocation = loc(ctx, node.prefixStart, node.prefixFinish)
		end
	elseif kindId == K.AstGenericType or kindId == K.AstGenericTypePack then
		out.location = nil
	elseif kindId == K.AstTableIndexer then
		out.type = nil
	elseif kindId == K.AstDeclaredExternTypeProperty then
		out.type = "AstDeclaredClassProp"
		out.nameLocation = loc(ctx, node.nameStart, node.nameFinish)
	elseif kindId == K.AstClassProperty or kindId == K.AstClassMethod then
		out.location = nil
		out.nameLocation = loc(ctx, node.nameStart, node.nameFinish)
		if node.qualifierStart then
			out.qualifierLocation = loc(ctx, node.qualifierStart, node.qualifierFinish)
		end
		if kindId == K.AstClassProperty and node.typeColonStart then
			out.typeColonLocation = loc(ctx, node.typeColonStart, node.typeColonFinish)
		elseif kindId == K.AstClassMethod then
			out.keywordLocation = loc(ctx, node.functionKeywordStart, node.functionKeywordFinish)
		end
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
	local location = loc(ctx, node.start, node.finish)
	local arena = ctx.arena
	local out: AstTable = { type = kindNames[kindId], location = location }
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
					out[output] = loc(ctx, value.start, value.finish)
				end
			elseif category == "typelist" then
				local tailKey = descriptor[4]
				out[output] = typeList(ctx, value or 0, if tailKey then node[tailKey] else nil)
			elseif category == "items" then
				out[output] = materializeItems(ctx, value or 0)
			elseif category ~= "c" and value ~= nil then
				out[output] = value
			end
		end
	end
	finalizeNode(ctx, node, kindId, out)
	return out
end

local UpstreamAstAdapter = {}
UpstreamAstAdapter.Null = nullSentinel

function UpstreamAstAdapter.toTables(result: any): AstTable?
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
		lineStarts = result.lineStarts,
		lastLineIdx = 1,
		memo = table.create(#nodes),
		bindings = table.create(#arenaBindings),
	}
	return visitNode(ctx, result.root)
end

return table.freeze(UpstreamAstAdapter)
