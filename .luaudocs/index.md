---
layout: home

hero:
  name: "Ouro"
  text: "Parse. Compile. Execute."
  tagline: "Self-hosted Luau 0.748 lexer, lossless parser, bytecode compiler, and sandboxed register VM in pure Luau."
  image:
    src: /logo.svg
    alt: Ouro
  actions:
    - theme: brand
      text: Get Started
      link: /guide/introduction/getting-started
    - theme: alt
      text: API Reference
      link: /api/
    - theme: alt
      text: GitHub
      link: https://github.com/kohltastrophe/ouro
---

## Parse <span>without loss</span>

```luau
local Ouro = require("./ouro")

local source = "-- keep comments\nlocal x: number = 20 + 22\nreturn x"
local parsed = Ouro.parse(source, { profile = "studio", lossless = true })

if parsed.status == "ok" then
	print(parsed:kindName(parsed.root)) -- "AstStatBlock"
	assert(parsed:reconstruct() == source)
end
```

[`Ouro.parse`](/api/Ouro#parse) lowers Luau syntax, type annotations, and `.d.luau` declarations into flat numeric arenas with zero-based byte offsets. Enable `lossless = true` to preserve comments and whitespace for `reconstruct()`, or materialize nested node tables with [`Ouro.Ast.toTables`](/api/Ast#totables). See the [Parsing & AST](/guide/pipeline/parsing) guide for profiles and `ParserContext` reuse.

## Compile <span>to Luau bytecode</span>

```luau
local bytecode = assert(Ouro.compile("local a, b = ...\nreturn a * b + 2", {
	optimizationLevel = 2,
}))

print(Ouro.Bytecode.disassemble(bytecode))
```

[`Ouro.compile`](/api/Ouro#compile) emits binary Luau bytecode (`v14` default, `v100` for classes) across optimization levels `0`, `1`, and `2`, matching upstream constant folding, builtin fastcalls, inlining, and loop specialization. [`Ouro.Bytecode`](/api/Bytecode) includes `serialize`, `deserialize`, `verify` (`v3`–`v14`), and `disassemble`. See [Compiling & Bytecode](/guide/pipeline/compiling).

## Execute <span>in a sandbox</span>

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

[`Ouro.load`](/api/Ouro#load) runs source strings, binary bytecode, or decoded `ProtoModule` tables inside an isolated register VM (`inheritHost = false` by default). Enforce instruction, call, timeout, string, and table allocation caps, intercept global reads and writes with `getGlobal` / `setGlobal`, and attach debugger callbacks through [`Ouro.VM`](/api/VM). See [Sandboxed VM](/guide/pipeline/vm).

## Typed API <span>linked everywhere</span>

<Frame label="Generated API reference" link="/api/Ouro">

<!--@include: @/api/Ouro.md#parse-->

<!--@include: @/api/Ouro.md#compile-->

<!--@include: @/api/Ouro.md#load-->

</Frame>

Every public entry in [`Ouro`](/api/Ouro) and its submodules exposes `--!strict` Luau annotations verified against both solver generations. Root `require` loads types and a lazy facade, deferring `Ast`, `Profiles`, `Tokens`, `Kinds`, `Compiler`, `Bytecode`, and `VM` until accessed.

## Run fast <span>in pure Luau</span>

<a href="/guide/benchmarks"><img src="https://raw.githubusercontent.com/kohltastrophe/ouro/assets/chart-small.svg" width="100%" alt="Ouro vs Fiu vs LuauCeption comparison benchmark"></a>

Dual `@native` fast and guarded dispatch loops keep unguarded execution at full speed while enforcing instruction and resource caps only when configured, paired with lazy submodule loading to minimize startup cost. Read [Benchmarks](/guide/benchmarks) for `--codegen -O2` and `-O2` breakdowns against Fiu and LuauCeption.

## Batteries Included

- **Arena parser & lossless reconstruction:** Parse scripts, expressions, type packs, and `.d.luau` files, reuse `ParserContext` scratch buffers across parses, filter tokens and comments, and traverse ASTs via [`Ouro.parse`](/api/Ouro#parse) and [`Ouro.Ast`](/api/Ast).
- **Grammar profiles & strict flags:** Switch between `upstream`, `studio`, and `experimental` presets or toggle individual syntax flags via [`Ouro.Profiles`](/api/Profiles).
- **Full O0–O2 bytecode compiler:** Inline functions, fold builtins and constants, emit vector, native, and usercall fastcalls, and serialize or verify bytecode (`v3`–`v14`, `v100` classes) through [`Ouro.Compiler`](/api/Compiler) and [`Ouro.Bytecode`](/api/Bytecode).
- **Isolated sandboxed VM:** Execute compiled closures in isolated environments with per-environment `PCG32` `math.random` state, instruction/call/time/allocation caps, coverage tracking, and stack/upvalue debuggers via [`Ouro.VM`](/api/VM).

## Quick Start

<Tabs>
<TabItem value="wally" label="wally.toml" default>

```toml
[dependencies]
Ouro = "kohltastrophe/ouro@0.1.0"
```

</TabItem>
<TabItem value="pesde" label="pesde">

```sh
pesde add kohltastrophe/ouro
```

</TabItem>
<TabItem value="releases" label="Releases">

Download `Ouro.rbxm` or `Ouro-0.1.0-package.zip` (with `SHA256SUMS`) from [GitHub Releases](https://github.com/kohltastrophe/ouro/releases) and place the module in `ReplicatedStorage`.

</TabItem>
<TabItem value="rojo" label="Rojo / Standalone">

Build `default.project.json` with Rojo (`rojo build default.project.json --output build/Ouro.rbxm`), require the repository root directly in standalone Luau (`require("./ouro")`), or pull the runtime-only [`dist` branch](https://github.com/kohltastrophe/ouro/tree/dist):

```sh
git subtree add --prefix=Packages/Ouro https://github.com/kohltastrophe/ouro.git dist --squash
```

</TabItem>
</Tabs>

Read **[Getting Started](/guide/introduction/getting-started)** to configure your project, or explore the **[API Reference](/api/)**.

## Sponsors

Ouro is free and [MIT-licensed](https://github.com/kohltastrophe/ouro/blob/main/LICENSE.md). If Ouro is useful to you or your team, you can support its development through [GitHub Sponsors](https://github.com/sponsors/kohltastrophe) or [Ko-fi](https://ko-fi.com/kohltastrophe).

<p class="sponsors">
  <a href="https://github.com/sponsors/kohltastrophe"><img src="https://raw.githubusercontent.com/kohltastrophe/kohltastrophe/badges/sponsor-github.svg" alt="GitHub Sponsors" /></a>&nbsp;&nbsp;<a href="https://ko-fi.com/kohltastrophe"><img src="https://raw.githubusercontent.com/kohltastrophe/kohltastrophe/badges/sponsor-kofi.svg" alt="Ko-fi" /></a>
  <a href="https://github.com/sponsors/kohltastrophe"><img src="https://raw.githubusercontent.com/kohltastrophe/kohltastrophe/badges/sponsors.svg" alt="Sponsors" /></a>
</p>
