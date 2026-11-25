--!strict
local storage = game:GetService("ReplicatedStorage")
local loadModule = require
local Ouro = loadModule(storage:WaitForChild("Ouro")) :: typeof(require(storage.Ouro))
local sert = loadModule(storage:WaitForChild("sert")) :: any

local describe = sert.describe
local test = sert.test.roblox

local function loadChecked(code: string | buffer, name: string, env: any): (...any) -> ...any
	local fn, loadErr = Ouro.VM.loadBytecode(code, { name = name, env = env })
	sert.ok(fn ~= nil, name .. " failed: " .. tostring(loadErr))
	return fn :: any
end

describe("Roblox", function()
	test("parses studio profile, reuses ParserContext, and recovers syntax errors", function()
		local cases = {
			"local x = 1; return x",
			"local function f<T>(x: T, ...: string): (T, ...string) return x, ... end",
			"export type Map<K,V> = {[K]: V}; local t: Map<string,number> = {}",
			"local x = 1; repeat local y = x; x += 1 until y > 4",
			"for k,v in pairs({a=1}) do if v then continue end end",
			"return " .. string.char(96) .. "hello {1+2}" .. string.char(96),
			"local function f() return function() return f end end",
			"type function Identity(x) return x end; type A = Identity<number>",
			"const value = 42; return value",
		}
		for _, source in cases do
			local result = Ouro.parse(source, { profile = "studio", lossless = true })
			sert.eq(
				result.status,
				"ok",
				source .. ": " .. tostring(result.diagnostics[1] and result.diagnostics[1].message)
			)
			sert.eq(result:reconstruct(), source)
			sert.ok(result.root ~= 0, "Studio parse has no root")
		end

		local context = Ouro.newContext({ lossless = true })
		local a = context:parse("local a=1\nreturn a")
		local b = context:parse("return 2")
		sert.eq(a:reconstruct(), "local a=1\nreturn a")
		sert.eq(b.status, "ok")

		local incomplete = Ouro.parse("local x = (", { lossless = true })
		sert.eq(incomplete.status, "syntaxError")
		sert.eq(incomplete:reconstruct(), "local x = (")
	end)

	test("compiles and executes raw and binary chunks", function()
		local rawFn, rawErr = Ouro.load("return ... + 1", { name = "=studio" })
		sert.ok(rawFn ~= nil, rawErr)
		sert.eq((rawFn :: (...any) -> ...any)(41), 42)

		local bc = assert(
			Ouro.compile("local s = 0; for i = 1, ... do s += math.abs(-i) end; return s", { optimizationLevel = 2 })
		)
		local vmFn, vmErr = Ouro.load(bc, { name = "=smoke", env = getfenv(), mode = "binary" })
		sert.ok(vmFn ~= nil, vmErr)
		sert.eq((vmFn :: (...any) -> ...any)(10), 55)
	end)

	test("yields cleanly after destroying a cloned root package", function()
		local pkgClone = storage:WaitForChild("Ouro"):Clone()
		pkgClone.Name = "OuroStandaloneVM"
		pkgClone.Parent = storage
		local StandaloneVM = ((loadModule(pkgClone) :: any) :: typeof(Ouro)).VM
		pkgClone:Destroy()

		local yieldBc = assert(Ouro.compile(
			[[
				task.wait()
				local env = getfenv()
				return env.workspace == workspace and workspace ~= nil
			]],
			{ optimizationLevel = 2 }
		))
		local yieldFn, loadErr = StandaloneVM.loadBytecode(yieldBc, { name = "YieldAfterDestroy", env = getfenv() })
		sert.ok(yieldFn ~= nil, tostring(loadErr))
		sert.eq((yieldFn :: (...any) -> ...any)(), true)
	end)

	test("resolves shadowed Instance NAMECALL methods and Roblox datatypes", function()
		local shadowFolder = Instance.new("Folder")
		shadowFolder.Name = "OuroShadowFolder"
		local shadowChild = Instance.new("Folder")
		shadowChild.Name = "FindFirstChild"
		shadowChild.Parent = shadowFolder
		local shadowEnv = setmetatable({
			targetFolder = shadowFolder,
			expectedChild = shadowChild,
		}, { __index = getfenv() })
		local shadowFn = loadChecked(
			assert(Ouro.compile("return targetFolder:FindFirstChild('FindFirstChild') == expectedChild", {
				optimizationLevel = 2,
			})),
			"ShadowNamecall",
			shadowEnv
		)
		local shadowOk, shadowResult = pcall(shadowFn)
		shadowFolder:Destroy()
		sert.ok(shadowOk and shadowResult == true, "Shadowed Instance NAMECALL failed")

		local dtypeFn = loadChecked(
			assert(Ouro.compile(
				[[
					local x, y, z = ...
					local v = Vector3.new(x, y, z)
					local cf = CFrame.new(x, y, z)
					local c = Color3.fromRGB(10, 20, 30)
					local u = UDim2.fromOffset(10, 20)
					local vc = vector.create(x, y, z)
					return typeof(v) == "Vector3"
						and typeof(cf) == "CFrame"
						and typeof(c) == "Color3"
						and typeof(u) == "UDim2"
						and typeof(vc) == "Vector3"
						and v == vc
				]],
				{ optimizationLevel = 2 }
			)),
			"RobloxDatatypes",
			getfenv()
		)
		sert.eq(dtypeFn(1, 2, 3), true)
	end)

	test("reads and mutates workspace, shared, _G, and script through GETIMPORT", function()
		local rootHolder = Instance.new("Folder")
		local innerScript = Instance.new("Folder")
		innerScript.Name = "FakeScript"
		innerScript.Parent = rootHolder
		local newParent = Instance.new("Folder")
		local origGravity = workspace.Gravity
		local mutEnv = setmetatable({
			script = innerScript,
			altParent = newParent,
			origGravity = origGravity,
		}, { __index = getfenv() })
		local mutFn = loadChecked(
			assert(Ouro.compile(
				[[
					local g1 = workspace.Gravity
					workspace.Gravity = g1 + 10
					local g2 = workspace.Gravity
					shared._ouroTest = "s1"
					_G._ouroTest = "g1"
					local sp1 = script.Parent
					script.Parent = altParent
					local sp2 = script.Parent
					workspace.Gravity = origGravity
					local okShared = shared._ouroTest == "s1"
					local okG = _G._ouroTest == "g1"
					shared._ouroTest = "s2"
					_G._ouroTest = "g2"
					return g2 == g1 + 10
						and okShared
						and okG
						and shared._ouroTest == "s2"
						and _G._ouroTest == "g2"
						and sp1 ~= sp2
						and sp2 == altParent
				]],
				{ optimizationLevel = 2 }
			)),
			"MutableImports",
			mutEnv
		)
		local mutOk, mutRes = pcall(mutFn)
		workspace.Gravity = origGravity
		shared._ouroTest = nil
		_G._ouroTest = nil
		rootHolder:Destroy()
		newParent:Destroy()
		sert.ok(mutOk and mutRes == true, "Mutable GETIMPORT check failed: " .. tostring(mutRes))
	end)

	test("yields across task.wait inside pcall/xpcall and round-trips attributes and errors", function()
		local pcallWaitFn = loadChecked(
			assert(Ouro.compile(
				[[
					local ok1, r1 = pcall(function()
						task.wait()
						return 41
					end)
					local ok2, r2 = xpcall(function()
						task.wait()
						return 42
					end, function(e)
						return e
					end)
					return ok1 and r1 == 41 and ok2 and r2 == 42
				]],
				{ optimizationLevel = 2 }
			)),
			"PcallXpcallWait",
			getfenv()
		)
		sert.eq(pcallWaitFn(), true)

		local attrHost = Instance.new("Folder")
		local attrBc = assert(Ouro.compile("local s = 'hi\\0\\255'; return 6 * 7, #s", { optimizationLevel = 2 }))
		attrHost:SetAttribute("Code", attrBc)
		local gotStr = attrHost:GetAttribute("Code")
		attrHost:Destroy()
		sert.ok(type(gotStr) == "string" and gotStr == attrBc, "Attribute binary string round-trip differs")
		local strFn = loadChecked(gotStr :: string, "AttrStr", getfenv())
		local bufFn = loadChecked(buffer.fromstring(gotStr :: string), "AttrBuf", getfenv())
		local s1, s2 = strFn()
		local b1, b2 = bufFn()
		sert.eq(s1, 42)
		sert.eq(s2, 4)
		sert.eq(b1, 42)
		sert.eq(b2, 4)

		local errDebugFn = loadChecked(
			assert(Ouro.compile(
				[[
					local function outer(...)
						error("boom", 2)
					end
					local ok0, e0 = pcall(function()
						error("boom", 0)
					end)
					local ok2c, e2c = pcall(outer); local ok2, e2 = pcall(function() outer() end)
					local function inspect(...)
						local s, l, n = debug.info(1, "sln")
						local tb = debug.traceback("hdr", 1)
						return s, l, n, tb
					end
					local s, l, n, tb = inspect()
					local sf, lf, nf = debug.info(inspect, "sln")
					assert(not ok0 and e0 == "boom", "error(0) mismatch: " .. tostring(ok0) .. " / " .. tostring(e0))
					assert(not ok2c and e2c == "boom", "error(2) C-frame mismatch: " .. tostring(ok2c) .. " / " .. tostring(e2c))
					assert(
						not ok2 and string.find(tostring(e2), "ErrorDebugInfo\"]:7: boom", 1, true) ~= nil,
						"error(2) mismatch: " .. tostring(e2)
					)
					assert(
						s == '[string "ErrorDebugInfo"]' and l == 9 and n == "inspect",
						"debug.info(1) mismatch: " .. tostring(s) .. "," .. tostring(l) .. "," .. tostring(n)
					)
					assert(
						sf == '[string "ErrorDebugInfo"]' and lf == 8 and nf == "inspect",
						"debug.info(fn) mismatch: " .. tostring(sf) .. "," .. tostring(lf) .. "," .. tostring(nf)
					)
					assert(
						type(tb) == "string"
							and string.find(tb, "ErrorDebugInfo\"]:10", 1, true) ~= nil
							and string.find(tb, "Dispatch", 1, true) == nil
							and string.find(tb, "RuntimeEnv", 1, true) == nil,
						"traceback mismatch: " .. tostring(tb)
					)
					return true
				]],
				{ optimizationLevel = 2 }
			)),
			"ErrorDebugInfo",
			getfenv()
		)
		sert.eq(errDebugFn(), true)
	end)

	test("enforces sandbox isolation, inheritHost, and global hooks across yields", function()
		local defaultEnv = Ouro.VM.createEnvironment()
		local isoFn = loadChecked(
			assert(
				Ouro.compile(
					"local n = ...; return game == nil and workspace == nil and Instance == nil and require == nil and math.abs(n) == 7",
					{ optimizationLevel = 2 }
				)
			),
			"DefaultIsolatedEnv",
			defaultEnv
		)
		sert.eq(isoFn(-7), true)

		local hostEnv = Ouro.VM.createEnvironment(nil, { inheritHost = true })
		local hostFn = loadChecked(
			assert(
				Ouro.compile(
					"return game ~= nil and workspace ~= nil and Vector3 ~= nil and script == nil",
					{ optimizationLevel = 2 }
				)
			),
			"InheritHostEnv",
			hostEnv
		)
		sert.eq(hostFn(), true)

		local frozenBase = Ouro.VM.createEnvironment({ sharedVal = 21 }, { readOnly = true })
		local sb1 = Ouro.VM.sandbox(frozenBase)
		local sb2 = Ouro.VM.sandbox(frozenBase)
		local sbSetFn = loadChecked(
			assert(Ouro.compile("local x, y = ...; leaked = 99; return sharedVal + math.abs(x) + bit32.bxor(y, 3)", {
				optimizationLevel = 2,
			})),
			"SandboxA",
			sb1
		)
		local sbReadFn = loadChecked(
			assert(Ouro.compile("return leaked == nil and sharedVal == 21", { optimizationLevel = 2 })),
			"SandboxB",
			sb2
		)
		sert.eq(sbSetFn(-10, 6), 36)
		sert.eq(sbReadFn(), true)
		sert.eq(frozenBase.leaked, nil)

		local hookStore: { [string]: any } = { seed = 10, task = task }
		local hookSetLog: { [string]: any } = {}
		local hookEnv: { [any]: any } = Ouro.VM.createEnvironment()
		local hookFn, hookErr = Ouro.VM.loadBytecode(
			assert(Ouro.compile(
				[[
					local x = ...
					task.wait()
					out = seed + math.abs(x)
					return out
				]],
				{ optimizationLevel = 2 }
			)),
			{
				name = "HookYield",
				env = hookEnv,
				safeEnv = true,
				getGlobal = function(name, _env)
					if hookSetLog[name] ~= nil then
						return hookSetLog[name]
					end
					return hookStore[name]
				end,
				setGlobal = function(name, val, _env)
					hookSetLog[name] = val
				end,
			}
		)
		sert.ok(hookFn ~= nil, "HookYield failed to load: " .. tostring(hookErr))
		sert.eq((hookFn :: any)(-5), 15)
		sert.eq(hookSetLog.out, 15)
		sert.eq(hookEnv.out, nil)
	end)

	test("handles workspace namecalls, userdata __namecall, collectgarbage, and isolated math.random", function()
		local wsShadowChild = Instance.new("Folder")
		wsShadowChild.Name = "FindFirstChild"
		wsShadowChild.Parent = workspace
		local wsEnv = setmetatable({ expectedChild = wsShadowChild }, { __index = getfenv() })
		local wsFn = loadChecked(
			assert(Ouro.compile("return workspace:FindFirstChild('FindFirstChild') == expectedChild", {
				optimizationLevel = 2,
			})),
			"WorkspaceShadowNamecall",
			wsEnv
		)
		local wsOk, wsRes = pcall(wsFn)
		pcall(function()
			wsShadowChild:Destroy()
		end)
		sert.ok(wsOk and wsRes == true, "Workspace shadowed Instance NAMECALL failed: " .. tostring(wsRes))

		local udProxy = newproxy(true)
		local udMt = getmetatable(udProxy) :: any
		udMt.__index = function(_self: any, _key: any): any
			return function(_recv: any, x: number): number
				return x + 100
			end
		end
		udMt.__namecall = function(_self: any, x: number): number
			return x * 2
		end
		local udEnv = setmetatable({ p = udProxy }, { __index = getfenv() })
		local udFn = loadChecked(
			assert(Ouro.compile("return p:ping(7)", { optimizationLevel = 2 })),
			"ProxyNamecallVsIndex",
			udEnv
		)
		sert.eq(udFn(), 14)

		local gcEnv = Ouro.VM.createEnvironment()
		local gcFn = loadChecked(
			assert(
				Ouro.compile(
					"local badOk = pcall(collectgarbage, 'bogus'); return collectgarbage('count'), select('#', collectgarbage('collect')), badOk",
					{ optimizationLevel = 2 }
				)
			),
			"CollectGarbage",
			gcEnv
		)
		local gcKb, gcCount, badOk = gcFn()
		sert.eq(type(gcKb), "number")
		sert.ok(gcKb >= 0)
		sert.eq(gcCount, 0)
		sert.eq(badOk, false)

		local hostRandBase = Ouro.VM.createEnvironment(nil, { readOnly = true })
		local rEnv1 = Ouro.VM.sandbox(hostRandBase)
		local rEnv2 = Ouro.VM.sandbox(hostRandBase)
		local randSrc = "math.randomseed(12345); return math.random(1, 100000), math.random(1, 100000)"
		local randBc = assert(Ouro.compile(randSrc, { optimizationLevel = 2 }))
		math.randomseed(98765)
		local hostBefore1 = math.random(1, 100000)
		math.randomseed(98765)
		local r1a, r1b = loadChecked(randBc, "RandA", rEnv1)()
		local hostAfter = math.random(1, 100000)
		local r2a, r2b = loadChecked(randBc, "RandB", rEnv2)()
		sert.eq(r1a, r2a)
		sert.eq(r1b, r2b)
		sert.eq(hostAfter, hostBefore1)
	end)

	test("supports custom codecs, AST traversal, verify/serialize, ResourceLimits, and strict options", function()
		local encodeOp: (number) -> number = function(op: number): number
			return bit32.bxor(op, 0x5A)
		end
		local decodeOp: (number) -> number = function(op: number): number
			return bit32.bxor(op, 0x5A)
		end
		local encSrc = "local a, b = ...; return a * b + 1"
		local plainBc = assert(Ouro.compile(encSrc, { optimizationLevel = 2 }))
		local xorBc = assert(Ouro.compile(encSrc, { optimizationLevel = 2, encoder = encodeOp }))
		sert.ok(xorBc ~= plainBc, "XOR encoder did not transform bytecode")
		local xorFn, xorErr = Ouro.VM.loadBytecode(xorBc, { name = "=xor_studio", decoder = decodeOp })
		sert.ok(xorFn ~= nil, "XOR decoder failed: " .. tostring(xorErr))
		local xorProtoMod = assert(Ouro.Bytecode.deserialize(xorBc, decodeOp))
		local plainProtoMod = assert(Ouro.Bytecode.deserialize(plainBc))
		sert.eq((xorFn :: any)(6, 7), 43)
		sert.eq(xorProtoMod.version, plainProtoMod.version)
		sert.eq(#xorProtoMod.protos[xorProtoMod.mainid + 1].code, #plainProtoMod.protos[plainProtoMod.mainid + 1].code)

		local visitParse = Ouro.parse("local a = 1; return a + 2", { profile = "studio" })
		local seenNodes = 0
		visitParse:visit(function()
			seenNodes += 1
			return true
		end)
		local rootChildren = 0
		visitParse:forEachChild(visitParse.root, function()
			rootChildren += 1
			return true
		end)
		sert.ok(seenNodes >= 4 and rootChildren == 2, "Studio visit/forEachChild check failed")

		local vOk, vErr = Ouro.Bytecode.verify(plainBc)
		local serBc, serErr = Ouro.Bytecode.serialize(plainProtoMod)
		sert.eq(vOk, true)
		sert.eq(vErr, nil)
		sert.ok(serBc ~= nil and serErr == nil, "Studio Bytecode.verify/serialize failed")

		local rlFn = assert(Ouro.load("return string.rep('x', 64)", {
			name = "=studio_rl",
			resourceLimits = { maxStringLength = 16 },
		}))
		sert.throws(function()
			(rlFn :: any)()
		end)

		local mtFn: any = assert(Ouro.load("return getmetatable('')", { name = "=studio_str_mt" }))
		sert.eq(mtFn(), "The metatable is locked")

		local unnamedFn = assert(Ouro.load("error('studio_boom')"))
		local unnamedOk, unnamedErr = pcall(unnamedFn :: any)
		sert.eq(unnamedOk, false)
		sert.ok(
			string.find(tostring(unnamedErr), '^%[string "error%(%S+%)"%]:1:') ~= nil,
			"Studio unnamed chunk error trace check failed: " .. tostring(unnamedErr)
		)

		sert.throws(function()
			Ouro.load("return 1", { bogusKey = true } :: any)
		end)
	end)
end)
