--!strict
local Parser = require("../src/Parser")

local Helpers = {}

function Helpers.encodeABC(op: number, a: number, b: number, c: number): number
	return bit32.bor(
		bit32.band(op, 0xff),
		bit32.lshift(bit32.band(a, 0xff), 8),
		bit32.lshift(bit32.band(b, 0xff), 16),
		bit32.lshift(bit32.band(c, 0xff), 24)
	)
end

function Helpers.encodeAD(op: number, a: number, d: number): number
	local ud = if d < 0 then d + 0x10000 else d
	return bit32.bor(
		bit32.band(op, 0xff),
		bit32.lshift(bit32.band(a, 0xff), 8),
		bit32.lshift(bit32.band(ud, 0xffff), 16)
	)
end

function Helpers.encodeE(op: number, e: number): number
	local ue = if e < 0 then e + 0x1000000 else e
	return bit32.bor(bit32.band(op, 0xff), bit32.lshift(bit32.band(ue, 0xffffff), 8))
end

function Helpers.sameValue(a: any, b: any): boolean
	local ta = typeof(a)
	if ta ~= typeof(b) then
		return false
	end
	if ta == "number" then
		local an: number = a
		local bn: number = b
		if an ~= an and bn ~= bn then
			return true
		end
		if an == 0 and bn == 0 then
			return (1 / an) == (1 / bn)
		end
		return an == bn
	elseif ta == "buffer" then
		return buffer.tostring(a) == buffer.tostring(b)
	end
	return a == b
end

function Helpers.assertDeepEqual(a: any, b: any, path: string?)
	local here = path or "root"
	if typeof(a) == "table" and typeof(b) == "table" then
		for k, v in a do
			Helpers.assertDeepEqual(v, b[k], here .. "." .. tostring(k))
		end
		for k, v in b do
			if a[k] == nil then
				Helpers.assertDeepEqual(a[k], v, here .. "." .. tostring(k))
			end
		end
	elseif not Helpers.sameValue(a, b) then
		error(string.format("%s: value mismatch (%s vs %s)", here, tostring(a), tostring(b)), 2)
	end
end

function Helpers.parseValid(source: string, options: Parser.ParseOptions?): Parser.ParseResult
	local result = Parser.parse(source, options)
	if #result.diagnostics > 0 then
		error(source .. "\n" .. result.diagnostics[1].message, 2)
	end
	return result
end

return table.freeze(Helpers)
