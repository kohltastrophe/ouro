--!strict
-- Numeric result-local IDs, fixed-shape records, flat child-list storage.
local Types = require("./Types")
local Arena = {}
Arena.__index = Arena
local Kinds = table.freeze({
	AstAttr = 1,
	AstExprGroup = 2,
	AstExprConstantNil = 3,
	AstExprConstantBool = 4,
	AstExprConstantNumber = 5,
	AstExprConstantString = 6,
	AstExprLocal = 7,
	AstExprGlobal = 8,
	AstExprVarargs = 9,
	AstExprCall = 10,
	AstExprIndexName = 11,
	AstExprIndexExpr = 12,
	AstExprFunction = 13,
	AstExprTable = 14,
	AstExprUnary = 15,
	AstExprBinary = 16,
	AstExprTypeAssertion = 17,
	AstExprIfElse = 18,
	AstExprInterpString = 19,
	AstExprError = 20,
	AstExprInstantiate = 21,
	AstStatBlock = 22,
	AstStatIf = 23,
	AstStatWhile = 24,
	AstStatRepeat = 25,
	AstStatBreak = 26,
	AstStatContinue = 27,
	AstStatReturn = 28,
	AstStatExpr = 29,
	AstStatLocal = 30,
	AstStatFor = 31,
	AstStatForIn = 32,
	AstStatAssign = 33,
	AstStatCompoundAssign = 34,
	AstStatFunction = 35,
	AstStatLocalFunction = 36,
	AstStatTypeAlias = 37,
	AstStatTypeFunction = 38,
	AstStatDeclareGlobal = 39,
	AstStatDeclareFunction = 40,
	AstStatDeclareExternType = 41,
	AstStatClass = 42,
	AstStatError = 43,
	AstGenericType = 44,
	AstGenericTypePack = 45,
	AstTypeReference = 46,
	AstTypeTable = 47,
	AstTypeFunction = 48,
	AstTypeTypeof = 49,
	AstTypeOptional = 50,
	AstTypeUnion = 51,
	AstTypeIntersection = 52,
	AstTypeError = 53,
	AstTypeSingletonBool = 54,
	AstTypeSingletonString = 55,
	AstTypeGroup = 56,
	AstTypePackExplicit = 57,
	AstTypePackVariadic = 58,
	AstTypePackGeneric = 59,
	AstTableProp = 60,
	AstTableIndexer = 61,
	AstArgumentName = 62,
	AstDeclaredExternTypeProperty = 63,
	AstClassProperty = 64,
	AstClassMethod = 65,
})
export type ArenaImpl = Types.Arena & {
	nodeCount: number,
	numLists: number,
	listValueCount: number,
	bindingCount: number,
	symbolMap: { [string]: number }?,
	add: (self: ArenaImpl, node: any) -> number,
	list: (self: ArenaImpl, items: { any }) -> number,
	list1: (self: ArenaImpl, item: any) -> number,
	listFromRange: (self: ArenaImpl, scratch: { any }, startIdx: number, count: number) -> number,
	listHasProp: (self: ArenaImpl, id: number, prop: string, expected: any) -> boolean,
}
local kindNames: { string } = {}
for name, index in Kinds :: { [string]: number } do
	kindNames[index] = name
end
table.freeze(kindNames)
Arena.Kinds = Kinds
Arena.kindNames = kindNames
Arena.kindIds = Kinds
function Arena.new(symbols: { string }?, sourceBytes: number?, symbolMap: { [string]: number }?): ArenaImpl
	local estNodes = if sourceBytes and sourceBytes > 256 then math.min(65536, math.ceil(sourceBytes * 0.3)) else 32
	local estLists = math.max(16, bit32.rshift(estNodes, 1))
	local self: any = setmetatable({
		nodes = table.create(estNodes),
		kinds = table.create(estNodes),
		starts = table.create(estNodes),
		finishes = table.create(estNodes),
		hasTypeAnnotations = false,
		hasClasses = false,
		nodeCount = 0,
		listFirsts = table.create(estLists),
		listCounts = table.create(estLists),
		numLists = 0,
		listValues = table.create(estNodes),
		listValueCount = 0,
		bindings = table.create(math.max(16, bit32.rshift(estNodes, 2))),
		bindingCount = 0,
		symbols = symbols or {},
		symbolMap = symbolMap,
	}, Arena)
	return self
end
@native
function Arena.add(self: ArenaImpl, node: any): number
	local id = self.nodeCount + 1
	self.nodeCount = id
	self.nodes[id] = node
	self.kinds[id] = node.kind
	self.starts[id] = node.start or 0
	self.finishes[id] = node.finish or 0
	return id
end
function Arena.kind(self: Types.Arena, id: number): number
	if id == 0 then
		return 0
	end
	return self.kinds[id] or 0
end
function Arena.kindName(self: Types.Arena, id: number): string
	if id == 0 then
		return ""
	end
	local k = self.kinds[id]
	return if k then kindNames[k] or "" else ""
end
@native
function Arena.list1(self: ArenaImpl, item: any): number
	local first = self.listValueCount + 1
	self.listValueCount = first
	self.listValues[first] = item
	local id = self.numLists + 1
	self.numLists = id
	self.listFirsts[id] = first
	self.listCounts[id] = 1
	return id
end
@native
function Arena.listFromRange(self: ArenaImpl, scratch: { any }, startIdx: number, count: number): number
	if count <= 0 then
		return 0
	end
	local values = self.listValues
	local first = self.listValueCount + 1
	self.listValueCount = first + count - 1
	if count == 1 then
		values[first] = scratch[startIdx]
	elseif count == 2 then
		values[first] = scratch[startIdx]
		values[first + 1] = scratch[startIdx + 1]
	elseif count == 3 then
		values[first] = scratch[startIdx]
		values[first + 1] = scratch[startIdx + 1]
		values[first + 2] = scratch[startIdx + 2]
	else
		table.move(scratch, startIdx, startIdx + count - 1, first, values)
	end
	local id = self.numLists + 1
	self.numLists = id
	self.listFirsts[id] = first
	self.listCounts[id] = count
	return id
end
@native
function Arena.list(self: ArenaImpl, items: { any }): number
	local count = #items
	if count == 0 then
		return 0
	elseif count == 1 then
		return Arena.list1(self, items[1])
	end
	return Arena.listFromRange(self, items, 1, count)
end
function Arena.listCount(self: Types.Arena, id: number): number
	if type(id) ~= "number" or id <= 0 then
		return 0
	end
	return self.listCounts[id] or 0
end
function Arena.listAt(self: Types.Arena, id: number, index: number): any
	if type(id) ~= "number" or id <= 0 then
		return nil
	end
	local count = self.listCounts[id]
	if count == nil or index < 1 or index > count then
		return nil
	end
	return self.listValues[self.listFirsts[id] + index - 1]
end
function Arena.listItems(self: Types.Arena, id: number): { any }
	if type(id) ~= "number" or id <= 0 then
		return {}
	end
	local count = self.listCounts[id]
	if count == nil or count == 0 then
		return {}
	end
	local first = self.listFirsts[id]
	local result = table.create(count)
	table.move(self.listValues, first, first + count - 1, 1, result)
	return result
end
function Arena.listHasProp(self: ArenaImpl, id: number, prop: string, expected: any): boolean
	if id <= 0 then
		return false
	end
	local first = self.listFirsts[id]
	local count = self.listCounts[id]
	local values = self.listValues
	local nodes = self.nodes
	for i = 0, count - 1 do
		local item = nodes[values[first + i]]
		if item and item[prop] == expected then
			return true
		end
	end
	return false
end
return table.freeze(Arena)
