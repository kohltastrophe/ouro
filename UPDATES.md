# Release tracking and generation

This repository tracks **official stable Luau releases**.
Ouro remains pure Luau and runs inside Roblox and standalone Luau. The native C++ implementation
is used only during development and conformance checks.

## What is generated

`tools/generate.py` reads the pinned official C++ source and deterministically emits:

- `src/Grammar.luau`: parser flag defaults and upstream revision.
- `src/Token.luau`: native token IDs and names, plus lossless tape sentinels.
- `src/Confusables.luau`: upstream confusable replacements.
- `src/BytecodeDefs.luau`: upstream bytecode opcodes, operand lengths, builtin IDs, constant/type tags, capture kinds, proto flags, and compiler flags.
- `UPSTREAM.json`: release, immutable commit, license, and source checksums across `Ast`, `Common`, `Bytecode`, and `Compiler`.

Upstream differential fixtures (`differential-all-literals.json`) are extracted on demand by `tools/check.py --upstream` or `tools/extract_fixtures.py` and gitignored locally.

Unsupported source formats fail generation. CI regenerates and compares all outputs,
builds a checksum-guarded native oracle, and verifies extracted strings against actual
C++ literal compilation. Explicit regeneration for the current pin:

```sh
python3 tools/fetch_upstream.py --output /tmp/luau-source
python3 tools/generate.py --source /tmp/luau-source --check
python3 tools/generate.py --source /tmp/luau-source
python3 tools/check.py --upstream /tmp/luau-source --report-dir /tmp/ouro-reports
```

Python 3.12+, CMake 3.20+, Ninja, and a C++17 compiler are required alongside the
tools pinned in `rokit.toml`. CI and scheduled checks install the pinned `luau@0.748`
CLI and toolchain via `kohltastrophe/sert/actions/setup` instead of downloading an
unpinned binary.

## Daily workflow

`.github/workflows/upstream.yml` runs daily at 13:17 UTC and can be started manually.
It reads GitHub's latest stable official release, resolves its tag to an immutable
commit, and downloads that source using the pinned `luau@0.748` runtime.

When a new release exists, the workflow copies this repository into a candidate and
regenerates the tracked data above. It then builds and tests the candidate against that release's
native `Ast`, `Compiler`, `Bytecode`, and `VM` oracle. The original library and pin remain intact. Artifacts include the
candidate, changed-file hashes, reports, and build/test log.

Statuses:

| Status | Meaning |
|---|---|
| `up-to-date` | Official release already matches the pin, and source checksums are verified. |
| `candidate-passed` | Generated data and the existing implementation passed the corpus, and upstream changes were limited to data, tests, or licenses. Review before adoption. |
| `needs-port` | `Ast`, `Common`, `Bytecode`, or `Compiler` implementation/header/build/encoder changes, an unsupported generator format, a native build failure, or any lexer/parser/compiler/VM conformance mismatch requires port work. Job fails visibly. |
| `failed` | Release discovery/download or baseline validation failed. Job fails visibly. |

The workflow has read-only repository permissions and never pushes, merges, or
publishes. It becomes scheduled only after you publish it on a GitHub repository's
default branch with Actions enabled. GitHub schedules can be delayed and inactive
public repositories may have schedules disabled.

Reproduce without network access using a source checkout and release JSON with
`version` and `commit`:

```sh
python3 tools/daily.py --source /path/to/official/source \
  --release /path/to/release.json --output /tmp/new-release-report
```

The output directory must be new and outside this repository.

## Limits of automatic porting

The handwritten recursive-descent lexer and parser, arena storage, binding tracking,
error recovery, AST schema, bytecode builder, compiler, register VM, public types,
and native encoder adaptations are maintained by hand. The EBNF grammar and header tables
are insufficient to reproduce these behaviors. Arbitrary C++ changes cannot be translated
automatically into this Luau implementation, and the generators implement a deliberately small
supported source format.

Corpus conformance is evidence, not a proof of language equivalence. The fixture
extractor excludes composed C++ inputs and does not reproduce every test's full
setup. Upstream implementation changes in `Ast`, `Common`, `Bytecode`, or `Compiler`
are always marked `needs-port`, including changes whose new syntax or bytecode
behavior is absent from extracted fixtures.

The `studio` profile retains the separately verified Studio grammar switches.
Official standalone releases do not establish which syntax Roblox Studio ships, so
Studio profile changes need their own native engine probes.

## Adopting a candidate

Review the changed upstream files and conformance evidence. Port implementation,
schema, public type, or oracle changes where needed, and update `README.md` provenance and
the separately maintained Studio profile as applicable. Run the full check runner
again and inspect the resulting diff before adopting the candidate. The release
workflow itself does not change your repository.
