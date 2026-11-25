--!strict
local Ouro = require("../../../")

local badOptions: Ouro.ParseOptions = { lossless = "yes" } -- expect-error

local badCompile: Ouro.CompileOptions = { optimizationLevel = "high" } -- expect-error

local badConstant: Ouro.CompileConstant = { type = "number", value = "bad" } -- expect-error
local badLoadMode: Ouro.LoadMode = "bytecode" -- expect-error

local badEnvOpts: Ouro.EnvironmentOptions = { libraries = { 123 } } -- expect-error

local badLoadOpts: Ouro.LoadOptions = { timeout = "fast" } -- expect-error

local badCompileCall = Ouro.compile(123) -- expect-error
local badLoadCall = Ouro.load(123) -- expect-error
local badVmLoad: string = Ouro.VM.loadBytecode("x") -- expect-error
local badDeserialize: number = Ouro.Bytecode.deserialize("x") -- expect-error
local badVerify = Ouro.Bytecode.verify(123) -- expect-error
local badSerialize = Ouro.Bytecode.serialize(123) -- expect-error
local badVisitor: Ouro.AstVisitor = { enter = "bad" } -- expect-error
local badLimits: Ouro.ResourceLimits = { maxStringLength = "10" } -- expect-error

local result: Ouro.ParseResult = Ouro.parse("return 1")
local badStatus: "unknownStatus" = result.status -- expect-error
local badRange: string = result:kind(result.root) -- expect-error

return {
	badOptions = badOptions,
	badCompile = badCompile,
	badConstant = badConstant,
	badLoadMode = badLoadMode,
	badEnvOpts = badEnvOpts,
	badLoadOpts = badLoadOpts,
	badCompileCall = badCompileCall,
	badLoadCall = badLoadCall,
	badVmLoad = badVmLoad,
	badDeserialize = badDeserialize,
	badVerify = badVerify,
	badSerialize = badSerialize,
	badVisitor = badVisitor,
	badLimits = badLimits,
	badStatus = badStatus,
	badRange = badRange,
}
