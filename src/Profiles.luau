--!strict
--- Named parser grammar flag profiles (`upstream`, `studio`, `experimental`) pinned to Luau 0.748.
local Grammar = require("./Grammar")
local Types = require("./Types")
local defaults = table.clone(Grammar.defaults) :: { [string]: boolean }
local upstream = table.freeze(table.clone(defaults)) :: Types.ResolvedFlags
local studio = table.clone(defaults)
-- In 0.748, LuauSingleTypeOptionalPackReturnsAttributeParens affects parser output;
-- LuauSolverV2, LuauAllowGlobalDeclarationToBeCalledClass, and DebugLuauReportReturnTypeVariadicWithTypeSuffix mirror enabled upstream Studio flags (no-ops in Parser.cpp).
studio.LuauSolverV2 = true
studio.LuauSingleTypeOptionalPackReturnsAttributeParens = true
studio.LuauAllowGlobalDeclarationToBeCalledClass = true
table.freeze(studio)
local experimental = table.clone(defaults)
for name in experimental do
	experimental[name] = true
end
table.freeze(experimental)
local profiles: { [string]: Types.ResolvedFlags } = table.freeze({
	upstream = upstream,
	studio = studio :: Types.ResolvedFlags,
	experimental = experimental :: Types.ResolvedFlags,
} :: { [string]: Types.ResolvedFlags })
--- Named parser grammar flag profiles (`upstream`, `studio`, `experimental`) pinned to Luau 0.748.
local Profiles = {
	--- Frozen map of built-in parser profiles keyed by name (`"upstream"`, `"studio"`, `"experimental"`).
	named = profiles,
}

--- Resolves a built-in profile name or validates a custom `GrammarFlags` table against upstream defaults.
function Profiles.resolve(value: (string | Types.GrammarFlags)?): Types.ResolvedFlags
	if value == nil then
		return upstream
	end
	if type(value) == "string" then
		assert(profiles[value], "Unknown parser profile: " .. value)
		return profiles[value]
	end
	assert(type(value) == "table", "profile must be a name or flag table")
	local result = table.clone(defaults)
	for key, flag in value :: { [string]: any } do
		assert(defaults[key] ~= nil, "Unknown grammar flag: " .. tostring(key))
		assert(type(flag) == "boolean", "Grammar flags must be boolean")
		result[key] = flag
	end
	return table.freeze(result) :: Types.ResolvedFlags
end
return table.freeze(Profiles)
