---
title: Parsing & AST
description: Parse Luau source into flat numeric arenas with lossless byte preservation and yielding checkpoints.
outline: deep
sidebar_position: 1
---

# Parsing & AST

`Ouro.parse(source, options?)` consumes a complete chunk and requires EOF. [`Ouro.parseExpression`](/api/Ouro#parseexpression) and [`Ouro.parseType`](/api/Ouro#parsetype) follow upstream Luau's fragment APIs and accept a leading prefix unless you pass `requireEOF = true`. All parser entrypoints validate arguments strictly and throw on non-string sources or unknown option keys.

[`Ouro.newContext`](/api/Ouro#newcontext) creates a stateful `ParserContext` (`:parse`, `:parseExpression`, `:parseType`, `:reset()`, `busy` boolean) that reuses private scope, symbol, and error-recovery scratch tables across calls. Published `ParseResult` arenas stay owned by their result and are never recycled, while scratch buffers above `256 KiB` (`262,144` bytes) release on completion so one large file does not pin heap memory. Contexts reject overlapping or reentrant calls while active, though independent contexts can interleave across yielding checkpoints.

## Parse Options & Profiles

`ParseOptions` configures grammar flags, parser limits, lossless capture, and cooperative yielding:

| Option | Default / behavior |
| :--- | :--- |
| `profile` | `"upstream"` (pinned C++ flag defaults), `"studio"`, `"experimental"`, or a custom `GrammarFlags` table. |
| `lossless` | `false`. When `true`, retains dense token and trivia span arrays for exact source reconstruction. |
| `captureComments` | Enabled automatically by `lossless = true`, otherwise `false` (explicit override supported). |
| `allowDeclarationSyntax` | `false`. Enables `.d.luau` `declare` syntax. |
| `requireEOF` | `false` for expression and type fragment entrypoints (chunks always require EOF). |
| `recursionLimit` | `1,000` nested parser frames. |
| `typeLengthLimit` | `1,000` items in a type list or union/intersection chain. |
| `errorLimit` | `100` reported diagnostics before aborting with `"limit"`. |
| `noErrorLimit` | `false`. Disables `errorLimit` when `true`. |
| `checkpointInterval` | `4,096` scanned bytes per lexer checkpoint (the parser also checks every `256` token advances). |
| `checkpoint` | Optional `(offset: number) -> boolean?` callback. Return `false` to cancel or yield to suspend. |

### Named Profiles

Built-in profile tables live in [`Ouro.Profiles`](/api/Profiles):

| Profile | Behavior |
| :--- | :--- |
| `upstream` | Pinned official C++ parser boolean defaults from `UPSTREAM.json`. |
| `studio` | Enables shipping Studio flags (`LuauSolverV2`, `LuauSingleTypeOptionalPackReturnsAttributeParens`, and `LuauAllowGlobalDeclarationToBeCalledClass`) verified on Studio `0.748.0.7481526`. |
| `experimental` | Enables every ported boolean grammar flag in `src/Grammar.luau`. Does not imply Studio support. |

Passing a custom `GrammarFlags` table validates every key against known flags at runtime, checks boolean types, merges onto `upstream` defaults, and freezes the resolved map.

### Lossless Tape & Checkpoints

When `lossless = true`, the lexer records a compact parallel tape (`kinds`, `starts`, `finishes`, `count`) referencing byte slices of `source` rather than allocating concrete syntax nodes. `result:reconstruct()` verifies contiguous coverage with no gaps or overlaps and returns the exact original bytes, including malformed inputs. When a parse stops on a limit or cancellation, the tape appends a `Token.Unparsed` sentinel covering the remaining tail, and `lineStarts` indexing past an early stop computes lazily on demand.

Checkpoint callbacks execute inside the active parse context, including long-string and block-comment scans, so Studio plugins can yield cleanly against frame budgets without blocking the main thread.

## Parse Results & Arena Storage

`ParseResult.status` reports `"ok"`, `"syntaxError"`, `"limit"`, or `"cancelled"`:

- `"ok"`: Parsing succeeded with zero diagnostics.
- `"syntaxError"`: Recoverable errors produced diagnostics; `result.root` holds an error-containing tree rather than validated code.
- `"limit"` or `"cancelled"`: Fatal abort (`result.root == 0`).

Invalid argument types and errors thrown inside `checkpoint` callbacks propagate directly to the caller. Node, list, symbol, and binding IDs are integer indices local to that `ParseResult` (`0` means absent), not cross-parse identities.

### Traversing the Arena

Arenas store tagged node records alongside parallel Structure-of-Arrays metadata (`kinds`, `starts`, `finishes`), module flags (`hasTypeAnnotations`, `hasClasses`), bindings, symbols, and flat child-list arrays (`listFirsts`, `listCounts`, `listValues`). Treat exposed arena tables as read-only:

- `result:kind(nodeId)` / `result:kindName(nodeId)`: Returns numeric tag (`Ouro.Kinds`) or upstream node name (`"AstStatBlock"`).
- `result:range(nodeId)`: Returns `(start, finish)` zero-based byte offsets.
- `result:childCount(nodeId)` / `result:childAt(nodeId, index)`: Accesses schema-ordered children without allocating tables.
- `result:forEachChild(nodeId, callback)`: Iterates direct children in schema order without allocating tables. Return `false` to stop early.
- `result:visit(visitor)`: Walks depth-first from `result.root`, accepting either `(nodeId, kind, depth) -> boolean?` or `{ enter?, leave? }`. Returning `false` skips descending into children while still invoking `leave`.

Calling [`Ouro.Ast.toTables(result)`](/api/Ast#totables) materializes conventional Lua node tables (`nil` when `result.root == 0`) with `type`, zero-based `start`/`finish` offsets, and preserved metadata (`false` for absent unnamed `argNames` or `paramNames`).

### Byte Offsets & Lines

All spans and diagnostics use zero-based half-open `[start, finish)` byte offsets, matching C++ Luau. `result:position(offset)` returns zero-based `(line, column)` byte coordinates, and `result:offset(line, column)` maps back to a byte offset. Only LF (`\n`) advances line numbers.
