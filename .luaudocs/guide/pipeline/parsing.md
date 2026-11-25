---
title: Parsing & AST
description: Parse Luau source into flat numeric arenas with lossless byte preservation and yielding checkpoints.
outline: deep
sidebar_position: 1
---

# Parsing & AST

[`Ouro.parse`](/api/Ouro#parse) turns Luau source code into a flat numeric AST arena with zero-based byte offsets. When a chunk contains syntax errors, it emits structured diagnostics alongside a recovered tree so tooling can still inspect spans.

```luau
--!strict
local Ouro = require("./ouro")

local parsed = Ouro.parse("local total: number = 20 + 22\nreturn total")

if parsed.status == "ok" then
	print(parsed:kindName(parsed.root)) -- "AstStatBlock"
else
	for _, diag in parsed.diagnostics do
		local line, col = parsed:position(diag.start)
		print(`{line + 1}:{col + 1} [{diag.code}] {diag.message}`)
	end
end
```

All parser entrypoints validate arguments strictly and throw on non-string sources or unknown option keys.

## Expressions, Types & Declarations

Use [`Ouro.parseExpression`](/api/Ouro#parseexpression) for standalone expressions, [`Ouro.parseType`](/api/Ouro#parsetype) for standalone type annotations, and `allowDeclarationSyntax = true` for `.d.luau` definition files:

```luau
-- Fragment entrypoints accept a prefix by default; pass requireEOF = true for full strings
local expr = Ouro.parseExpression("a + b * 2", { requireEOF = true })
local ty = Ouro.parseType("{ [string]: number }", { requireEOF = true })
local decl = Ouro.parse("declare function ping(host: string): boolean", {
	allowDeclarationSyntax = true,
})

assert(expr.status == "ok" and ty.status == "ok" and decl.status == "ok")
```

## Grammar Profiles {#profiles}

Built-in profile maps live in [`Ouro.Profiles`](/api/Profiles). Pass a preset name or a custom `GrammarFlags` override table in `ParseOptions.profile`:

```luau
local studioResult = Ouro.parse("local value = 1", {
	profile = "studio",
})

-- Custom flags validate every key against known flags and merge onto "upstream" defaults
local customResult = Ouro.parse("local value = 1", {
	profile = { LuauSolverV2 = true },
})
```

| Profile | Behavior |
| :--- | :--- |
| `upstream` | Pinned official C++ `0.748` parser boolean defaults from `UPSTREAM.json` (default). |
| `studio` | Enables shipping Studio flags (`LuauSolverV2`, `LuauSingleTypeOptionalPackReturnsAttributeParens`, and `LuauAllowGlobalDeclarationToBeCalledClass`) verified on Studio `0.748.0.7481526`. |
| `experimental` | Enables every ported boolean grammar flag in `src/Grammar.luau`. Does not imply Studio support. |

## Lossless Reconstruction

Enable `lossless = true` to record a compact parallel token and trivia tape (`kinds`, `starts`, `finishes`, `count`) alongside parsed `comments` and `--!` `hotcomments`. Calling `result:reconstruct()` verifies contiguous coverage with zero gaps or overlaps and returns the exact original bytes, even on malformed inputs:

```luau
local source = "--!strict\n-- leading comment\nlocal x = 1 + 2\n"
local parsed = Ouro.parse(source, { lossless = true })

assert(parsed:reconstruct() == source)
print(#parsed.hotcomments, #parsed.comments) --> 1  2
```

If a parse aborts early due to a limit or cancellation, the tape appends a [`Token.Unparsed`](/api/Token#unparsed) sentinel covering the remaining source tail, and `lineStarts` past the stop point computes on demand. Set `captureComments = true` when you only want comment spans without retaining the full lexical tape.

## Walking the Arena

`ParseResult` stores tagged nodes alongside parallel Structure-of-Arrays metadata (`kinds`, `starts`, `finishes`), bindings, symbols, and flat child lists (`listFirsts`, `listCounts`, `listValues`). You can traverse nodes in schema order without allocating tables, or materialize nested tables with [`Ouro.Ast.toTables`](/api/Ast#totables):

```luau
local source = "local function add(a: number, b: number)\n\treturn a + b\nend"
local parsed = Ouro.parse(source)

parsed:visit(function(nodeId, _kind, depth)
	local start, finish = parsed:range(nodeId)
	local line, col = parsed:position(start)
	print(`depth={depth} {parsed:kindName(nodeId)} at {line + 1}:{col + 1} ({finish - start} bytes)`)
	return true
end)

-- Or inspect direct children of the root block without table allocation
parsed:forEachChild(parsed.root, function(childId)
	print("top-level statement:", parsed:kindName(childId))
	return true
end)

-- Materialize conventional upstream-named Lua tables when needed
local rootTable = Ouro.Ast.toTables(parsed)
```

All spans and diagnostics use zero-based half-open `[start, finish)` byte offsets, matching C++ Luau. `result:position(offset)` returns zero-based `(line, column)` byte coordinates (only LF `\n` advances line numbers), and `result:offset(line, column)` converts back to a byte offset. Node, list, symbol, and binding IDs (`0` means absent) belong strictly to that `ParseResult`. Treat exposed `arena` tables as read-only.

`visit` accepts either a function `(nodeId, kind, depth) -> boolean?` or `{ enter?, leave? }`. Returning `false` from `enter` (or the callback) skips descending into children while still invoking `leave`. `Ast.toTables` returns `nil` when `result.root == 0` and uses `false` for absent unnamed `argNames` or `paramNames` slots.

## Reusing Contexts & Yielding

[`Ouro.newContext`](/api/Ouro#newcontext) creates a reusable `ParserContext` (`:parse`, `:parseExpression`, `:parseType`, `:reset()`, `busy`) that recycles private scope, symbol, and error-recovery scratch tables across calls. Each returned `ParseResult` still owns its own arena, while temporary scratch buffers larger than `256 KiB` (`262,144` bytes) release after completion so one huge script never pins memory:

```luau
local steps = 0
local ctx = Ouro.newContext({
	profile = "studio",
	checkpointInterval = 4096,
	checkpoint = function(_offset)
		steps += 1
		-- Yield in Roblox frame budgets (e.g. task.wait) or return false to cancel
		return steps < 10_000
	end,
})

local first = ctx:parse("local a = 1")
local second = ctx:parse("local b = 2")
ctx:reset()
```

Contexts reject reentrant or overlapping calls while `ctx.busy` is `true`, though independent contexts can interleave across yielding checkpoints. Checkpoints also fire inside long strings and block comments (the lexer checks every `checkpointInterval` bytes and the parser checks every `256` token advances). Errors thrown inside `checkpoint` propagate directly to the caller.

## Parse Options & Statuses

`ParseResult.status` reports one of four outcomes:

- `"ok"`: Zero diagnostics (`result.root` holds the full AST).
- `"syntaxError"`: Recoverable syntax errors produced diagnostics alongside a recovered AST (`result.root ~= 0`).
- `"limit"`: Aborted by `errorLimit`, `recursionLimit`, or `typeLengthLimit` (`result.root == 0`).
- `"cancelled"`: `checkpoint` returned `false` (`result.root == 0`).

| Option | Default / Behavior |
| :--- | :--- |
| `profile` | `"upstream"`, `"studio"`, `"experimental"`, or a custom `GrammarFlags` table. |
| `lossless` | `false`. Retains token/trivia tape for exact `reconstruct()` output and enables `captureComments`. |
| `captureComments` | `false` (enabled automatically by `lossless = true`). |
| `allowDeclarationSyntax` | `false`. Enables `.d.luau` `declare` syntax. |
| `requireEOF` | `false` on `parseExpression` and `parseType`; chunks always require EOF. |
| `recursionLimit` | `1,000` nested parser frames. |
| `typeLengthLimit` | `1,000` items in a type list or union/intersection chain. |
| `errorLimit` | `100` reported diagnostics before aborting with `"limit"`. |
| `noErrorLimit` | `false`. Disables `errorLimit` when `true`. |
| `checkpointInterval` | `4,096` scanned bytes between lexer `checkpoint` checks. |
| `checkpoint` | `(offset: number) -> boolean?`. Return `false` to cancel, or yield to pause. |
