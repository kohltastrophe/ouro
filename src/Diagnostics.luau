--!strict
local rshift = bit32.rshift
local Diagnostics = {}
local function findLine(lineStarts: { number }, lo: number, hi: number, offset: number): number
	while lo <= hi do
		local mid = rshift(lo + hi, 1)
		if lineStarts[mid] <= offset then
			lo = mid + 1
		else
			hi = mid - 1
		end
	end
	return if hi > 1 then hi else 1
end

function Diagnostics.position(lineStarts: { number }, offset: number): (number, number)
	local index = findLine(lineStarts, 1, #lineStarts, offset)
	return index - 1, offset - lineStarts[index]
end
function Diagnostics.location(lineStarts: { number }, start: number, finish: number): string
	local text = Diagnostics.locationCursor(lineStarts, start, finish, 1)
	return text
end
function Diagnostics.locationCursor(
	lineStarts: { number },
	start: number,
	finish: number,
	cursorIdx: number
): (string, number)
	local n = #lineStarts
	local idx = if cursorIdx >= 1 and cursorIdx <= n then cursorIdx else 1
	local lineStart = lineStarts[idx]
	if start >= lineStart then
		if idx < n and start >= lineStarts[idx + 1] then
			if idx + 1 == n or start < lineStarts[idx + 2] then
				idx += 1
				lineStart = lineStarts[idx]
			else
				idx = findLine(lineStarts, idx + 2, n, start)
				lineStart = lineStarts[idx]
			end
		end
	elseif idx > 1 and start >= lineStarts[idx - 1] then
		idx -= 1
		lineStart = lineStarts[idx]
	else
		idx = findLine(lineStarts, 1, idx - 1, start)
		lineStart = lineStarts[idx]
	end
	local sl = idx - 1
	local sc = start - lineStart
	if idx == n or finish < lineStarts[idx + 1] then
		return sl .. "," .. sc .. " - " .. sl .. "," .. (finish - lineStart), idx
	end
	local idx2 = findLine(lineStarts, idx + 1, n, finish)
	return sl .. "," .. sc .. " - " .. (idx2 - 1) .. "," .. (finish - lineStarts[idx2]), idx2
end
return table.freeze(Diagnostics)
