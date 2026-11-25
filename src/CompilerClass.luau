--!strict
-- Luau 0.748 experimental class lowering and class-visitor pass.
-- Upstream Luau is MIT licensed; see ../LICENSE.md and ../UPSTREAM.json.
local Arena = require("./Arena")
local BytecodeBuilder = require("./BytecodeBuilder")
local BytecodeDefs = require("./BytecodeDefs")
local CompilerExpr = require("./CompilerExpr")

local K = Arena.Kinds
local Opcodes = BytecodeDefs.Opcodes

local kInvalidReg = 255
local kDefaultAllocPc = 0xffffffff
local kMaxClassNest = 256

type CompilerCtx = CompilerExpr.CompilerCtx

local raiseCompileError: (CompilerCtx, number, number, string) -> never
local checkConstantNode: (CompilerCtx, number, number) -> ()
local allocReg: (CompilerCtx, number, number) -> number
local pushLocal: (CompilerCtx, number, number, number) -> ()
local checkExportedLocal: (CompilerCtx, number, number, number) -> ()
local ensureExportTable: (CompilerCtx, number) -> ()
local getExprLocalReg: (CompilerCtx, number) -> number
local compileExpr: (CompilerCtx, number, number, boolean?) -> ()
local compileExprFunction: (CompilerCtx, number, number, number?) -> ()
local compileLValueUnboxed: (CompilerCtx, number) -> (number, number, number, string?, number, number, number)
local compileLValueUseUnboxed: (
	CompilerCtx,
	number,
	number,
	number,
	string?,
	number,
	number,
	number,
	number,
	boolean,
	number
) -> ()

local function bind(deps: {
	raiseCompileError: (CompilerCtx, number, number, string) -> never,
	checkConstantNode: (CompilerCtx, number, number) -> (),
	allocReg: (CompilerCtx, number, number) -> number,
	pushLocal: (CompilerCtx, number, number, number) -> (),
	checkExportedLocal: (CompilerCtx, number, number, number) -> (),
	ensureExportTable: (CompilerCtx, number) -> (),
	getExprLocalReg: (CompilerCtx, number) -> number,
	compileExpr: (CompilerCtx, number, number, boolean?) -> (),
	compileExprFunction: (CompilerCtx, number, number, number?) -> (),
	compileLValueUnboxed: (CompilerCtx, number) -> (number, number, number, string?, number, number, number),
	compileLValueUseUnboxed: (
		CompilerCtx,
		number,
		number,
		number,
		string?,
		number,
		number,
		number,
		number,
		boolean,
		number
	) -> (),
})
	raiseCompileError = deps.raiseCompileError
	checkConstantNode = deps.checkConstantNode
	allocReg = deps.allocReg
	pushLocal = deps.pushLocal
	checkExportedLocal = deps.checkExportedLocal
	ensureExportTable = deps.ensureExportTable
	getExprLocalReg = deps.getExprLocalReg
	compileExpr = deps.compileExpr
	compileExprFunction = deps.compileExprFunction
	compileLValueUnboxed = deps.compileLValueUnboxed
	compileLValueUseUnboxed = deps.compileLValueUseUnboxed
end

@native
local function getClassNodeName(ctx: CompilerCtx, decl: any): string
	if decl.declModifier ~= "None" then
		return ctx.symbols[ctx.bindings[decl.localName].name]
	end
	local k = ctx.kinds[decl.exprName]
	if k == K.AstExprLocal then
		return ctx.symbols[ctx.bindings[ctx.nodes[decl.exprName]["local"]].name]
	elseif k == K.AstExprGlobal then
		return ctx.symbols[ctx.nodes[decl.exprName].name]
	elseif k == K.AstExprError then
		return "*error*"
	end
	error("Unreachable class name")
end

@native
local function getClassNodeNameSpan(ctx: CompilerCtx, decl: any): (number, number)
	if decl.declModifier == "None" then
		return ctx.starts[decl.exprName], ctx.finishes[decl.exprName]
	end
	local b = ctx.bindings[decl.localName]
	return b.start, b.finish
end

@native
local function computePrivateFieldInfo(
	ctx: CompilerCtx,
	nameSym: number,
	start: number,
	finish: number
): (number, number, boolean)
	local currClasses = ctx.currClasses
	assert(currClasses and #currClasses > 0, "expected enclosing classes")
	local classPrivateFieldOffsets = ctx.classPrivateFieldOffsets
	for classIndex = #currClasses, 1, -1 do
		local currClassId = currClasses[classIndex]
		local offsets = classPrivateFieldOffsets[currClassId]
		if offsets then
			local entry = offsets[nameSym]
			if entry then
				return entry.offset, classIndex - 1, entry.isStatic
			end
		end
	end
	raiseCompileError(ctx, start, finish, "Attempt to access undefined private field")
	return 0, 0, false
end

@native
local function compilePrivateFieldAccess(
	ctx: CompilerCtx,
	expr: any,
	target: number,
	source: number,
	namecall: boolean?
)
	local offset, classNest, isStatic = computePrivateFieldInfo(ctx, expr.index, expr.start, expr.finish)
	ctx.bytecode:emitABC(Opcodes.LOP_GETPRIVATEFIELD, target, source, classNest)
	ctx.bytecode:emitAux(
		bit32.bor(if namecall then bit32.lshift(1, 9) else 0, if isStatic then bit32.lshift(1, 8) else 0, offset)
	)
end

@native
local function compileClassObject(ctx: CompilerCtx, declId: number, dest: number)
	assert(ctx.flagDebugClasses, "classes flag must be enabled")
	local decl = ctx.nodes[declId]
	local oldTop = ctx.regTop
	local instrCVal = if decl.open then 1 else 0

	if decl.super ~= 0 then
		local superReg = getExprLocalReg(ctx, decl.super)
		local superDest = allocReg(ctx, declId, if superReg < 0 then 1 else 0)
		if superReg >= 0 then
			ctx.bytecode:emitABC(Opcodes.LOP_NEWCLASS, dest, superReg, instrCVal)
		else
			compileExpr(ctx, decl.super, superDest)
			ctx.bytecode:emitABC(Opcodes.LOP_NEWCLASS, dest, superDest, instrCVal)
		end
	else
		ctx.bytecode:emitABC(Opcodes.LOP_NEWCLASS, dest, kInvalidReg, instrCVal)
	end

	local auxOffset = ctx.bytecode:emitLabel()
	ctx.bytecode:emitAux(0xDEADBEEF)

	local classNameCid = ctx.bytecode:addConstantString(getClassNodeName(ctx, decl))
	local nameStart, nameFinish = getClassNodeNameSpan(ctx, decl)
	if classNameCid < 0 then
		raiseCompileError(ctx, nameStart, nameFinish, "Exceeded constant limit; simplify the code to compile")
	end

	local numPrivateInstanceProps = 0
	local numPrivateStaticProps = 0
	local shape: BytecodeBuilder.ClassShape = {
		className = classNameCid,
		numPrivateInstanceProps = 0,
		numPrivateStaticProps = 0,
		propertyNames = {},
		methodNames = {},
	}

	local temp = allocReg(ctx, declId, 1)
	local hasExplicitConstructor = false

	if decl.members ~= 0 then
		local membersFirst = ctx.listFirsts[decl.members]
		local membersCount = ctx.listCounts[decl.members]
		local kinds = ctx.kinds
		for i = 0, membersCount - 1 do
			local memberId = ctx.listValues[membersFirst + i]
			local mk = kinds[memberId]
			local member = ctx.nodes[memberId]
			if mk == K.AstClassProperty then
				if member.access == "Private" then
					if numPrivateInstanceProps >= 256 then
						raiseCompileError(ctx, member.start, member.finish, "Exceeded private property limit")
					end
					numPrivateInstanceProps += 1
				else
					local propNameCid = ctx.bytecode:addConstantString(ctx.symbols[member.name])
					if propNameCid < 0 then
						raiseCompileError(
							ctx,
							member.nameStart,
							member.nameFinish,
							"Exceeded constant limit; simplify the code to compile"
						)
					end
					table.insert(shape.propertyNames, propNameCid)
				end
			elseif mk == K.AstClassMethod then
				compileExprFunction(ctx, member["function"], temp, dest)
				local mname = ctx.symbols[member.functionName]
				if member.access == "Private" then
					if numPrivateStaticProps >= 256 then
						raiseCompileError(ctx, member.start, member.finish, "Exceeded private method limit")
					end
					ctx.bytecode:emitABC(Opcodes.LOP_NEWCLASSMEMBER, dest, 1, temp)
					ctx.bytecode:emitAux(numPrivateStaticProps)
					numPrivateStaticProps += 1
				else
					local methodNameCid = ctx.bytecode:addConstantString(mname)
					checkConstantNode(ctx, methodNameCid, member["function"])
					table.insert(shape.methodNames, methodNameCid)
					ctx.bytecode:emitABC(Opcodes.LOP_NEWCLASSMEMBER, dest, 0, temp)
					ctx.bytecode:emitAux(methodNameCid)
				end
				if mname == "__init" then
					if member.access ~= "Public" then
						raiseCompileError(ctx, member.start, member.finish, "private constructor is unsupported")
					end
					hasExplicitConstructor = true
				end
			end
		end
	end

	shape.numPrivateInstanceProps = numPrivateInstanceProps
	shape.numPrivateStaticProps = numPrivateStaticProps

	if not hasExplicitConstructor then
		local initCid = ctx.bytecode:addConstantString("__init")
		checkConstantNode(ctx, initCid, declId)
		table.insert(shape.methodNames, initCid)
	end

	local classConst = ctx.bytecode:addClassShape(shape)
	checkConstantNode(ctx, classConst, declId)
	ctx.bytecode:patchAux(auxOffset, classConst)
	ctx.regTop = oldTop
end

@native
local function compileClassDeclaration(ctx: CompilerCtx, declId: number)
	assert(ctx.flagDebugClasses, "classes flag must be enabled")
	local decl = ctx.nodes[declId]
	local mod = decl.declModifier

	if mod == "None" then
		local reg = getExprLocalReg(ctx, decl.exprName)
		if reg >= 0 and (decl.super == 0 or reg ~= getExprLocalReg(ctx, decl.super)) then
			compileClassObject(ctx, declId, reg)
			return
		end
		local oldTop = ctx.regTop
		local tmp = allocReg(ctx, declId, 1)
		compileClassObject(ctx, declId, tmp)
		local lvKind, lvReg, lvAux, lvName, lvSymId, lvStart, lvFinish = compileLValueUnboxed(ctx, decl.exprName)
		compileLValueUseUnboxed(ctx, lvKind, lvReg, lvAux, lvName, lvSymId, lvStart, lvFinish, tmp, true, decl.exprName)
		ctx.regTop = oldTop
	elseif mod == "Export" then
		if not ctx.flags.LuauExportValueSyntax then
			raiseCompileError(ctx, decl.start, decl.finish, "export class requires LuauExportValueSyntax")
		end
		local reg = allocReg(ctx, declId, 1)
		pushLocal(ctx, decl.localName, reg, kDefaultAllocPc)
		checkExportedLocal(ctx, decl.localName, decl.start, decl.finish)
		ensureExportTable(ctx, declId)
		ctx.exports.exportedClasses[decl.localName] = reg
		compileClassObject(ctx, declId, reg)
	elseif mod == "Local" or mod == "Const" then
		local reg = allocReg(ctx, declId, 1)
		pushLocal(ctx, decl.localName, reg, kDefaultAllocPc)
		compileClassObject(ctx, declId, reg)
	else
		error("Unexpected class declaration modifier: " .. tostring(mod))
	end
end

@native
local function runClassVisitor(ctx: CompilerCtx, rootId: number)
	local nodes = ctx.nodes
	local kinds = ctx.kinds
	local listFirsts = ctx.listFirsts
	local listCounts = ctx.listCounts
	local listValues = ctx.listValues
	local enclosingClasses = ctx.enclosingClasses
	local classPrivateFieldOffsets = ctx.classPrivateFieldOffsets
	local classStack: { number } = {}
	local currFuncShouldCapture = false

	local visitNode: (number) -> ()

	@native
	local function visitList(listId: number)
		if listId ~= 0 then
			local first = listFirsts[listId]
			local count = listCounts[listId]
			for i = 0, count - 1 do
				visitNode(listValues[first + i])
			end
		end
	end

	@native
	function visitNode(nodeId: number)
		if nodeId == 0 then
			return
		end
		local k = kinds[nodeId]
		if k == nil then
			return
		end
		local n = nodes[nodeId]
		if k == K.AstStatClass then
			if n.super ~= 0 then
				visitNode(n.super)
			end
			classStack[#classStack + 1] = nodeId
			if #classStack > kMaxClassNest then
				raiseCompileError(
					ctx,
					n.start,
					n.finish,
					string.format("Class nest exceeded the maximum depth of %d", kMaxClassNest)
				)
			end
			local privateOffsets: { [number]: { offset: number, isStatic: boolean } } = {}
			local numPrivateInst = 0
			local numPrivateStat = 0
			local prevShouldCapture = currFuncShouldCapture
			local anyCaptured = false
			if n.members ~= 0 then
				local first = listFirsts[n.members]
				local count = listCounts[n.members]
				for i = 0, count - 1 do
					local memberId = listValues[first + i]
					local mk = kinds[memberId]
					local member = nodes[memberId]
					if mk == K.AstClassProperty then
						if member.access == "Private" then
							privateOffsets[member.name] = { offset = numPrivateInst, isStatic = false }
							numPrivateInst += 1
						end
					elseif mk == K.AstClassMethod then
						if member.access == "Private" then
							privateOffsets[member.functionName] = { offset = numPrivateStat, isStatic = true }
							numPrivateStat += 1
						end
						currFuncShouldCapture = false
						visitNode(member["function"])
						anyCaptured = anyCaptured or currFuncShouldCapture
					end
				end
			end
			if next(privateOffsets) ~= nil then
				classPrivateFieldOffsets[nodeId] = privateOffsets
			end
			classStack[#classStack] = nil
			currFuncShouldCapture = if #classStack == 0 then false else (prevShouldCapture or anyCaptured)
		elseif k == K.AstExprFunction then
			local prevShouldCapture = currFuncShouldCapture
			currFuncShouldCapture = false
			visitNode(n.body)
			local bodyCaptured = currFuncShouldCapture
			if bodyCaptured then
				assert(#classStack > 0, "expected enclosing classes")
				enclosingClasses[nodeId] = table.clone(classStack)
			end
			currFuncShouldCapture = prevShouldCapture or bodyCaptured
		elseif k == K.AstExprIndexName then
			if n.privateAccess then
				currFuncShouldCapture = true
			end
			visitNode(n.expr)
		elseif k == K.AstStatBlock then
			visitList(n.body)
		elseif k == K.AstStatIf then
			visitNode(n.condition)
			visitNode(n.thenbody)
			visitNode(n.elsebody)
		elseif k == K.AstStatWhile then
			visitNode(n.condition)
			visitNode(n.body)
		elseif k == K.AstStatRepeat then
			visitNode(n.body)
			visitNode(n.condition)
		elseif k == K.AstStatReturn then
			visitList(n.list)
		elseif k == K.AstStatExpr then
			visitNode(n.expr)
		elseif k == K.AstStatLocal then
			visitList(n.values)
		elseif k == K.AstStatFor then
			visitNode(n.from)
			visitNode(n.to)
			visitNode(n.step)
			visitNode(n.body)
		elseif k == K.AstStatForIn then
			visitList(n.values)
			visitNode(n.body)
		elseif k == K.AstStatAssign then
			visitList(n.vars)
			visitList(n.values)
		elseif k == K.AstStatCompoundAssign then
			visitNode(n.var)
			visitNode(n.value)
		elseif k == K.AstStatFunction then
			visitNode(n.name)
			visitNode(n.func)
		elseif k == K.AstStatLocalFunction then
			visitNode(n.func)
		elseif k == K.AstStatError then
			visitList(n.expressions)
			visitList(n.statements)
		elseif
			k == K.AstExprGroup
			or k == K.AstExprTypeAssertion
			or k == K.AstExprInstantiate
			or k == K.AstExprUnary
		then
			visitNode(n.expr)
		elseif k == K.AstExprBinary then
			visitNode(n.left)
			visitNode(n.right)
		elseif k == K.AstExprIndexExpr then
			visitNode(n.expr)
			visitNode(n.index)
		elseif k == K.AstExprCall then
			visitNode(n.func)
			visitList(n.args)
		elseif k == K.AstExprIfElse then
			visitNode(n.condition)
			visitNode(n.trueExpr)
			visitNode(n.falseExpr)
		elseif k == K.AstExprTable then
			if n.items ~= 0 then
				local first = listFirsts[n.items]
				local count = listCounts[n.items]
				for i = 0, count - 1 do
					local item = listValues[first + i]
					if item.key ~= 0 then
						visitNode(item.key)
					end
					visitNode(item.value)
				end
			end
		elseif k == K.AstExprInterpString or k == K.AstExprError then
			visitList(n.expressions)
		end
	end

	visitNode(rootId)
end

return table.freeze({
	bind = bind,
	getClassNodeName = getClassNodeName,
	computePrivateFieldInfo = computePrivateFieldInfo,
	compilePrivateFieldAccess = compilePrivateFieldAccess,
	compileClassDeclaration = compileClassDeclaration,
	runClassVisitor = runClassVisitor,
})
