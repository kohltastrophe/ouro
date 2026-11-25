--!strict
-- Compile fixed test snippets in temporary scratch-place modules. They return
-- closures without running their bodies; this never evaluates user programs.
local storage = game:GetService("ReplicatedStorage")
local package = storage.Ouro:Clone()
package.Name = "OuroFinalProfile"
package.Parent = storage
local loadModule = require
local Parser = loadModule(package) :: typeof(require(storage.Ouro))
local folder = Instance.new("Folder")
folder.Name = "ParserGrammarProbe"
folder.Parent = storage
local cases = {
	{ "constant", "const x=1\nreturn function() return x end" },
	{ "generic", "return function<T>(x:T):T return x end" },
	{ "type-function", "type function Id(x) return x end\n type R=Id<number>\nreturn function() end" },
	{ "interpolation", "return function() return " .. string.char(96) .. "x {1}" .. string.char(96) .. " end" },
	{ "class", "class Cat public x: number end\nreturn function() end" },
	{ "if-local", "return function() if local x=1 then return x end end" },
	{ "while-local", "return function() while local x=nil do return x end end" },
	{ "integer", "return function() return 1i end" },
	{ "export-value", "export local x=1\nreturn function() end" },
	{ "exact-table", "type T={|x:number|}\nreturn function() end" },
	{ "declaration", "declare foo:number\nreturn function() end" },
}
local rows = {}
local mismatches = 0
local ok, err = pcall(function()
	for index, case in cases do
		local module = Instance.new("ModuleScript")
		module.Name = "Probe" .. tostring(index)
		module.Source = case[2]
		module.Parent = folder
		local modOk, value = pcall(require, module)
		local parsed = Parser.parse(case[2], { profile = "studio" })
		local accepted = parsed.status == "ok"
		if modOk ~= accepted then
			mismatches += 1
		end
		rows[index] = {
			name = case[1],
			nativeAccepted = modOk,
			parserAccepted = accepted,
			error = if modOk then nil else tostring(value),
		}
	end
end)
folder:Destroy()
package:Destroy()
if not ok then
	error(err)
end
assert(mismatches == 0, "Studio grammar profile mismatches: " .. tostring(mismatches))
return { passed = #cases, failed = mismatches, profileRevision = Parser.upstreamRevision, cases = rows }
