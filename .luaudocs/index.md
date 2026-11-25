---
layout: home

hero:
  name: "Ouro"
  text: "Self-hosted Luau 0.748 in pure Luau."
  tagline: Parse. Compile. Execute.
  actions:
    - theme: brand
      text: Overview
      link: /guide/introduction/
    - theme: alt
      text: Getting Started
      link: /guide/introduction/getting-started
    - theme: alt
      text: API Reference
      link: /api/
    - theme: alt
      text: Benchmarks
      link: /guide/benchmarks
    - theme: alt
      text: GitHub
      link: https://github.com/kohltastrophe/ouro
---

<div align="center">

<h1>Parse <span style="opacity: 0.28">without loss</span></h1>

<div align="left">

`Ouro.parse` lowers Luau syntax, type annotations, and `.d.luau` declarations into flat numeric arenas with zero-based byte offsets. Enable `lossless = true` to preserve exact whitespace and comments for `reconstruct()`, or materialize node tables with `Ouro.Ast.toTables`.

```luau
local Ouro = require("./ouro")

local source = "-- keep comments\nlocal x: number = 20 + 22\nreturn x"
local parsed = Ouro.parse(source, { profile = "studio", lossless = true })

if parsed.status == "ok" then
	print(parsed:kindName(parsed.root)) -- "AstStatBlock"
	assert(parsed:reconstruct() == source)
end
```

</div>

---

<h1>Compile <span style="opacity: 0.28">to Luau bytecode</span></h1>

<div align="left">

```luau
local bytecode = assert(Ouro.compile("local a, b = ...\nreturn a * b + 2", {
	optimizationLevel = 2,
}))

print(Ouro.Bytecode.disassemble(bytecode))
```

The compiler emits Luau bytecode (`v14` default, `v100` for classes) across optimization levels `0`, `1`, and `2`, matching upstream constant folding, builtin fastcalls, inlining, and loop specialization.

</div>

---

<h1>Execute <span style="opacity: 0.28">in a sandbox</span></h1>

<div align="left">

```luau
local base = Ouro.VM.createEnvironment({ answer = 40 }, { readOnly = true })
local env = Ouro.VM.sandbox(base)
local chunk = assert(Ouro.load("return answer + 2", {
	name = "=example",
	env = env,
	instructionLimit = 100_000,
	timeout = 1,
}))

print(chunk()) -- 42
```

`Ouro.load` runs raw source, binary bytecode, or a decoded `ProtoModule` inside an isolated register VM (`inheritHost = false` by default) with instruction, call, wall-clock timeout, allocation caps, global hooks, and debugger callbacks.

</div>

---

<h1>Run fast <span style="opacity: 0.28">in pure Luau</span></h1>

<a href="/guide/benchmarks"><img src="/benchmark-small.svg" width="100%" alt="Ouro vs Fiu vs LuauCeption comparison benchmark"></a>

<div align="left">

Dual `@native` dispatch loops keep Ouro fast on both native-codegen and interpreter hosts while cutting startup cost through lazy submodule loading. Explore the full per-workload numbers in [Benchmarks](/guide/benchmarks).

</div>

</div>
