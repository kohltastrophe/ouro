--!strict
-- Luau 0.748 pure-Luau Register Virtual Machine public API and module cache.
-- Upstream Luau is MIT licensed. See ../../LICENSE.md and ../../UPSTREAM.json.
local BytecodeCodec = require("./BytecodeCodec")
local BytecodeDefs = require("./BytecodeDefs")
local Dispatch = require("@self/Dispatch")
local RuntimeEnv = require("@self/RuntimeEnv")
local Types = require("./Types")
local Verifier = require("@self/Verifier")

export type Proto = Types.Proto
export type ProtoModule = Types.ProtoModule
export type CompileOptions = Types.CompileOptions
export type BytecodeDecoder = Types.BytecodeDecoder
export type LoadMode = Types.LoadMode
export type LoadOptions = Types.LoadOptions
export type EnvironmentOptions = Types.EnvironmentOptions
export type ResourceLimits = Types.ResourceLimits
export type DebugFrameInfo = Types.DebugFrameInfo
export type CoverageEntry = Types.CoverageEntry
export type UpvalueInfo = Types.UpvalueInfo

type ProtoTemplate = RuntimeEnv.ProtoTemplate
type PredecodedProto = RuntimeEnv.PredecodedProto
type ModuleContext = RuntimeEnv.ModuleContext

local Tags = BytecodeDefs.Tags
local LBC_CONSTANT_VECTOR = Tags.LBC_CONSTANT_VECTOR
local LBC_CONSTANT_VECTORD = Tags.LBC_CONSTANT_VECTORD
local LBC_CONSTANT_TABLE = Tags.LBC_CONSTANT_TABLE
local LBC_CONSTANT_TABLE_WITH_CONSTANTS = Tags.LBC_CONSTANT_TABLE_WITH_CONSTANTS
local LBC_CONSTANT_CLASS_SHAPE = Tags.LBC_CONSTANT_CLASS_SHAPE

local protoModuleCache: { [ProtoModule]: { [number]: ProtoTemplate } } = setmetatable({}, { __mode = "k" }) :: any

local formatChunkSrc = RuntimeEnv.formatChunkSrc
local validateLoadOptions = RuntimeEnv.validateLoadOptions

local function isPlainFrozenTable(t: any): boolean
	return type(t) == "table" and getmetatable(t) == nil and table.isfrozen(t)
end

local function isDeepFrozenModule(mod: ProtoModule, protos: { Proto }): boolean
	if not (isPlainFrozenTable(mod) and isPlainFrozenTable(protos)) then
		return false
	end
	if mod.strings ~= nil and not isPlainFrozenTable(mod.strings) then
		return false
	end
	if mod.userdataTypes ~= nil and not isPlainFrozenTable(mod.userdataTypes) then
		return false
	end
	for i = 1, #protos do
		local p = protos[i]
		if not isPlainFrozenTable(p) then
			return false
		end
		local kTypes = p.kTypes
		local kValues = p.kValues
		if
			not (
				isPlainFrozenTable(p.code)
				and isPlainFrozenTable(kTypes)
				and isPlainFrozenTable(kValues)
				and isPlainFrozenTable(p.p)
				and (p.upvalues == nil or isPlainFrozenTable(p.upvalues))
			)
		then
			return false
		end
		for ki = 1, #kTypes do
			local kt = kTypes[ki]
			if kt == LBC_CONSTANT_VECTOR or kt == LBC_CONSTANT_VECTORD then
				if not isPlainFrozenTable(kValues[ki]) then
					return false
				end
			elseif kt == LBC_CONSTANT_TABLE then
				local kv = kValues[ki]
				if not (isPlainFrozenTable(kv) and isPlainFrozenTable(kv.keys)) then
					return false
				end
			elseif kt == LBC_CONSTANT_TABLE_WITH_CONSTANTS then
				local kv = kValues[ki]
				if
					not (isPlainFrozenTable(kv) and isPlainFrozenTable(kv.keys) and isPlainFrozenTable(kv.constants))
				then
					return false
				end
			elseif kt == LBC_CONSTANT_CLASS_SHAPE then
				local kv = kValues[ki]
				if
					not (
						isPlainFrozenTable(kv)
						and isPlainFrozenTable(kv.propertyNames)
						and isPlainFrozenTable(kv.methodNames)
					)
				then
					return false
				end
			end
		end
	end
	return true
end

local function snapshotProtoKValues(kTypes: { number }, kValues: { any }): { any }
	local out = table.clone(kValues)
	for ki = 1, #kTypes do
		local kt = kTypes[ki]
		local kv = out[ki]
		if type(kv) == "table" and not table.isfrozen(kv) then
			if kt == LBC_CONSTANT_VECTOR or kt == LBC_CONSTANT_VECTORD then
				out[ki] = table.clone(kv)
			elseif kt == LBC_CONSTANT_TABLE then
				local cloned = table.clone(kv)
				cloned.keys = table.clone(kv.keys)
				out[ki] = cloned
			elseif kt == LBC_CONSTANT_TABLE_WITH_CONSTANTS then
				local cloned = table.clone(kv)
				cloned.keys = table.clone(kv.keys)
				if type(kv.constants) == "table" then
					cloned.constants = table.clone(kv.constants)
				end
				out[ki] = cloned
			end
		end
	end
	return out
end

local function snapshotMutableProtos(protos: { Proto }): { Proto }
	local clonedProtos = table.create(#protos) :: { Proto }
	for i = 1, #protos do
		local p = protos[i]
		local cp: Proto = {
			id = p.id,
			maxstacksize = p.maxstacksize,
			numparams = p.numparams,
			nups = p.nups,
			isvararg = p.isvararg,
			flags = p.flags,
			code = table.clone(p.code),
			kTypes = table.clone(p.kTypes),
			kValues = snapshotProtoKValues(p.kTypes, p.kValues),
			p = table.clone(p.p),
			linedefined = p.linedefined,
			debugname = p.debugname,
			lineData = p.lineData,
			linegaplog2 = p.linegaplog2,
			locvars = if p.locvars ~= nil then table.clone(p.locvars) else nil,
			upvalues = if p.upvalues ~= nil then table.clone(p.upvalues) else nil,
			typeinfo = p.typeinfo,
		}
		clonedProtos[i] = cp
	end
	return clonedProtos
end

local function loadProtoInternal(
	protoModule: ProtoModule,
	chunkname: string?,
	customEnv: { [any]: any }?,
	loadOpts: LoadOptions?,
	trusted: boolean,
	ephemeral: boolean,
	fromBinary: boolean?
): (((...any) -> ...any)?, string?)
	if type(protoModule) ~= "table" or getmetatable(protoModule :: any) ~= nil then
		return nil, "invalid proto module"
	end
	if chunkname ~= nil and type(chunkname) ~= "string" then
		return nil, "invalid chunk name"
	end
	if loadOpts ~= nil and type(loadOpts) ~= "table" then
		return nil, "invalid load options"
	end
	if customEnv ~= nil and type(customEnv) ~= "table" then
		return nil, "invalid env table"
	end
	if protoModule.version == Tags.LBC_VERSION_CLASSES then
		return nil, "unsupported experimental class bytecode (v100)"
	end
	local protos = protoModule.protos
	local mainid = protoModule.mainid
	if type(protos) ~= "table" or getmetatable(protos :: any) ~= nil or #protos == 0 then
		return nil, "invalid protos table"
	end
	if type(mainid) ~= "number" or mainid ~= math.floor(mainid) then
		return nil, "invalid main proto id"
	end
	local mainProto = protos[mainid + 1]
	if not mainProto then
		return nil, "invalid main proto id"
	end
	local shortSrc: string = formatChunkSrc(chunkname or "=chunk")

	local cached = if not ephemeral then protoModuleCache[protoModule] else nil
	local templates: { [number]: ProtoTemplate }
	if cached ~= nil then
		templates = cached
	elseif not ephemeral and isDeepFrozenModule(protoModule, protos) then
		local verifyErr = Verifier.verifyModule(protoModule, trusted, fromBinary)
		if verifyErr then
			return nil, verifyErr
		end
		local freshTemplates: { [number]: ProtoTemplate } = {}
		protoModuleCache[protoModule] = freshTemplates
		templates = freshTemplates
	else
		local verifyErr = Verifier.verifyModule(protoModule, trusted, fromBinary)
		if verifyErr then
			return nil, verifyErr
		end
		if not trusted and not fromBinary then
			protos = snapshotMutableProtos(protos)
			mainProto = protos[mainid + 1]
		end
		templates = {}
		if not ephemeral then
			for i = 1, #protos do
				local p = protos[i]
				templates[p.id + 1] = Verifier.predecodeProtoTemplate(p)
			end
		end
	end

	local env: { [any]: any }
	local envNeedsWrapperCheck = false
	if customEnv ~= nil then
		env = customEnv
		envNeedsWrapperCheck = true
	else
		local envOpts: EnvironmentOptions? = if loadOpts ~= nil and loadOpts.resourceLimits ~= nil
			then { resourceLimits = loadOpts.resourceLimits }
			else nil
		env = RuntimeEnv.createEnvironment(nil, envOpts)
	end
	local safeRootsMask = RuntimeEnv.computeSafeRootsMask(env, loadOpts)
	local needsHostWrappers = (envNeedsWrapperCheck and RuntimeEnv.envNeedsHostWrappers(env))
		or (loadOpts ~= nil and loadOpts.getGlobal ~= nil)
	local ctx: ModuleContext = RuntimeEnv.createModuleContext(
		protos,
		mainProto,
		templates,
		shortSrc,
		env,
		safeRootsMask,
		needsHostWrappers,
		loadOpts
	)
	local mainIdx = mainProto.id + 1
	local mainTmpl = templates[mainIdx]
	if not mainTmpl then
		mainTmpl = Verifier.predecodeProtoTemplate(mainProto)
		templates[mainIdx] = mainTmpl
	end
	ctx.predecoded[mainIdx] = Verifier.instantiatePredecoded(mainTmpl, mainProto, env, ctx.safeRootsMask)

	return Dispatch.instantiateClosure(ctx, mainProto, Dispatch.EMPTY_UPVALS, env), nil
end

--- Loads a deserialized ProtoModule into a callable Luau closure.
local function loadProto(protoModule: ProtoModule, options: LoadOptions?): (((...any) -> ...any)?, string?)
	validateLoadOptions(options, 2)
	if type(protoModule) ~= "table" then
		RuntimeEnv.hostError(
			"bad argument #1 to 'loadProto' (ProtoModule table expected, got " .. type(protoModule) .. ")",
			2
		)
	end
	local chunkname = if options then options.name else nil
	local customEnv = if options then options.env else nil
	local ok, closureOrErr, loadErr =
		pcall(loadProtoInternal, protoModule, chunkname, customEnv, options, false, false, false)
	if not ok then
		return nil, tostring(closureOrErr)
	end
	return closureOrErr, loadErr
end

local function loadBytecodeInternal(
	bytecode: string | buffer,
	options: LoadOptions?,
	defaultName: string?
): (((...any) -> ...any)?, string?)
	local chunkType = type(bytecode)
	if chunkType == "buffer" then
		local buf = bytecode :: buffer
		local len = buffer.len(buf)
		if len == 0 then
			return nil, "empty bytecode"
		end
		if buffer.readu8(buf, 0) == 0 then
			return nil, buffer.readstring(buf, 1, len - 1)
		end
	elseif chunkType == "string" then
		local str = bytecode :: string
		if #str == 0 then
			return nil, "empty bytecode"
		end
		local firstByte = string.byte(str, 1)
		if firstByte == 0 then
			return nil, string.sub(str, 2)
		end
	end
	local decoder = if options then options.decoder else nil
	local protoMod, deserErr = BytecodeCodec.deserialize(bytecode, decoder)
	if not protoMod then
		return nil, deserErr or "invalid bytecode"
	end
	local chunkname = (if options then options.name else nil) or defaultName
	local env = if options then options.env else nil
	local okLoad, closureOrErr, loadErr =
		pcall(loadProtoInternal, protoMod, chunkname, env, options, false, true, decoder == nil)
	if not okLoad then
		return nil, tostring(closureOrErr)
	end
	return closureOrErr, loadErr
end

--- Deserializes binary Luau bytecode and loads it into a callable closure.
local function loadBytecode(bytecode: string | buffer, options: LoadOptions?): (((...any) -> ...any)?, string?)
	validateLoadOptions(options, 2)
	local chunkType = type(bytecode)
	if chunkType ~= "buffer" and chunkType ~= "string" then
		RuntimeEnv.hostError(
			"bad argument #1 to 'loadBytecode' (string or buffer expected, got " .. chunkType .. ")",
			2
		)
	end
	return loadBytecodeInternal(bytecode, options, nil)
end

local lazyCompiler: any = nil

local function getCompiler(): any?
	if lazyCompiler == nil then
		local requireFn: any = require
		local ok, mod = pcall(requireFn, "./Compiler")
		if ok and mod ~= nil then
			lazyCompiler = mod
		end
	end
	return lazyCompiler
end

local function formatCompileError(chunkname: string?, source: string, err: string?): string
	local msg = err or "compile error"
	local src = formatChunkSrc(chunkname or source)
	if string.sub(msg, 1, 1) == ":" then
		return src .. msg
	end
	return src .. ": " .. msg
end

--- Compiles or deserializes a Luau chunk and loads it into a callable closure.
local function load(chunk: string | buffer | ProtoModule, options: LoadOptions?): (((...any) -> ...any)?, string?)
	validateLoadOptions(options, 2)
	local chunkname = if options then options.name else nil
	local mode = if options then options.mode else nil
	local chunkType = type(chunk)
	if chunkType == "table" then
		if mode == "text" then
			RuntimeEnv.hostError("ProtoModule cannot be loaded in text mode", 2)
		end
		return loadProto(chunk :: ProtoModule, options)
	elseif chunkType == "buffer" then
		if mode == "text" then
			RuntimeEnv.hostError("buffer cannot be loaded in text mode", 2)
		end
		return loadBytecodeInternal(chunk :: buffer, options, nil)
	elseif chunkType ~= "string" then
		RuntimeEnv.hostError(
			"bad argument #1 to 'load' (expected source string, bytecode buffer, or ProtoModule, got "
				.. chunkType
				.. ")",
			2
		)
	end

	local str = chunk :: string
	if mode == "binary" then
		return loadBytecodeInternal(str, options, nil)
	elseif mode == "auto" and #str > 0 then
		local b = string.byte(str, 1)
		local b2 = string.byte(str, 2)
		if
			b == 0
			or b == 3
			or (
				((b >= 4 and b <= Tags.LBC_VERSION_MAX) or b == Tags.LBC_VERSION_CLASSES)
				and b2 ~= nil
				and b2 >= Tags.LBC_TYPE_VERSION_MIN
				and b2 <= Tags.LBC_TYPE_VERSION_MAX
			)
		then
			return loadBytecodeInternal(str, options, nil)
		end
	end

	local compiler = getCompiler()
	if not compiler then
		return nil, "Compiler module is not available in standalone VM mode; pass precompiled bytecode"
	end
	local compileOpts = if options then options.compile else nil
	if compileOpts ~= nil and compileOpts.encoder ~= nil then
		local compileFn: (string, CompileOptions?) -> (string?, string?) = compiler.compile
		local bc, err = compileFn(str, compileOpts)
		if not bc then
			return nil, formatCompileError(chunkname, str, err)
		end
		return loadBytecodeInternal(bc, options, chunkname or str)
	end
	local compileProtoFn: (string, CompileOptions?) -> (ProtoModule?, string?) = compiler.compileProto
	local pm, err = compileProtoFn(str, compileOpts)
	if not pm then
		return nil, formatCompileError(chunkname, str, err)
	end
	local env = if options then options.env else nil
	local okLoad, closureOrErr, loadErr =
		pcall(loadProtoInternal, pm, chunkname or str, env, options, true, true, false)
	if not okLoad then
		return nil, tostring(closureOrErr)
	end
	return closureOrErr, loadErr
end

return table.freeze({
	load = load,
	loadBytecode = loadBytecode,
	loadProto = loadProto,
	createEnvironment = RuntimeEnv.createEnvironment,
	sandbox = RuntimeEnv.sandbox,
	traceback = RuntimeEnv.vmTraceback,
	getCoverage = RuntimeEnv.vmGetCoverage,
	cloneFunction = Dispatch.cloneFunction,
	getUpvalues = RuntimeEnv.vmGetUpvalues,
	setUpvalue = RuntimeEnv.vmSetUpvalue,
	resetBudget = RuntimeEnv.vmResetBudget,
})
