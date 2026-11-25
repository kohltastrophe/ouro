--!strict
-- Isolates getfenv/setfenv references from VM/init.luau so Luau O2 inlining and safeenv
-- remain active for VM and host callers until a host fallback is actually requested.
local hostGetfenv: ((any?) -> { [any]: any })? = getfenv
local hostSetfenv: ((any, { [any]: any }) -> any)? = setfenv
local cachedEnv: { [any]: any }? = nil

local function getHostEnv(): { [any]: any }
	if cachedEnv == nil then
		if hostGetfenv then
			local rawEnv = hostGetfenv(1)
			if rawget(rawEnv, "script") ~= nil then
				cachedEnv = setmetatable({}, {
					__index = function(_self: any, k: any): any
						if k == "script" then
							return nil
						end
						return rawEnv[k]
					end,
				}) :: any
			else
				cachedEnv = rawEnv
			end
		else
			cachedEnv = {}
		end
	end
	return cachedEnv :: { [any]: any }
end

return table.freeze({
	getfenv = hostGetfenv,
	setfenv = hostSetfenv,
	getHostEnv = getHostEnv,
})
