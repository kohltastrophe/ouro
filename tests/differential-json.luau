--!nocheck
-- Test-only JSON writer; binary strings are escaped bytewise.
local function quote(value)
	local pieces = { '"' }
	for index = 1, #value do
		local byte = string.byte(value, index)
		if byte == 34 then
			pieces[#pieces + 1] = '\\"'
		elseif byte == 92 then
			pieces[#pieces + 1] = "\\\\"
		elseif byte < 32 then
			pieces[#pieces + 1] = string.format("\\u%04x", byte)
		else
			pieces[#pieces + 1] = string.char(byte)
		end
	end
	pieces[#pieces + 1] = '"'
	return table.concat(pieces)
end
local function encode(value)
	local kind = type(value)
	if kind == "table" and value.__parserNull then
		return "null"
	end
	if kind == "nil" then
		return "null"
	elseif kind == "string" then
		return quote(value)
	elseif kind == "boolean" then
		return tostring(value)
	elseif kind == "number" then
		if value ~= value then
			return "NaN"
		elseif value == math.huge then
			return "Infinity"
		elseif value == -math.huge then
			return "-Infinity"
		end
		return string.format("%.17g", value)
	end
	assert(kind == "table", "cannot JSON encode " .. kind)
	local pieces = {}
	local array = true
	for key in value do
		if type(key) ~= "number" then
			array = false
			break
		end
	end
	if array then
		for i = 1, #value do
			pieces[i] = encode(value[i])
		end
		return "[" .. table.concat(pieces, ",") .. "]"
	end
	for key, child in value do
		pieces[#pieces + 1] = quote(tostring(key)) .. ":" .. encode(child)
	end
	table.sort(pieces)
	return "{" .. table.concat(pieces, ",") .. "}"
end
return encode
