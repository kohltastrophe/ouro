--!strict
local sert = require("@sert") :: any

local options = sert.parseCliArgs(...)
assert(type(options) == "table", "expected parsed CLI options")

sert._bundled = true

require("./Lexer.spec")
require("./Runtime.spec")
require("./Types.spec")
require("./Lifecycle.spec")
require("./Safety.spec")
require("./Package.spec")
require("./BytecodeBuilder.spec")
require("./Compiler.spec")
require("./VM.spec")

return sert.run(options)
