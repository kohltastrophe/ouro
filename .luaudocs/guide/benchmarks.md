---
title: Benchmarks
description: Comparing Ouro against Fiu and LuauCeption across VM execution, O2 compilation, cold startup, and code size.
outline: deep
sidebar_position: 3
---

# Benchmarks

Measured sequentially on an AMD Ryzen 7 5800X under headless `luau 0.748` (`--codegen -O2` matching Roblox native codegen, and `-O2` interpreter). Every VM workload verifies exact output parity against host Luau `loadstring` before timing.

[![Ouro vs Fiu vs LuauCeption full benchmark breakdown](/benchmark.svg)](/benchmark.svg)

## Summary

| Metric | Ouro (`0.1.0`) | Ouro (guarded) | Fiu (`fast`) | LuauCeption (`0.654`) |
| :--- | ---: | ---: | ---: | ---: |
| **VM execution (`--codegen -O2`, 13 workloads)** | **1.01×** | 1.19× | 2.76× | 43.69× *(12 + 1 DNF)* |
| **VM execution (`-O2`, 13 workloads)** | **1.00×** | 1.16× | 3.68× | 16.92× *(12 + 1 DNF)* |
| **O2 compilation (`--codegen -O2`, 5 corpora)** | **1.00×** | — | *VM-only* | 14.12× |
| **O2 compilation (`-O2`, 5 corpora)** | **1.00×** | — | *VM-only* | 8.45× |
| **Cold load + run (`--codegen -O2`, 1k loop)** | **0.057 ms** | — | 0.121 ms | 6.23 ms |
| **Cold load + run (`-O2`, 1k loop)** | **0.144 ms** | — | 0.653 ms | 5.36 ms |
| **Cold root `require` (`--codegen -O2` / `-O2`)** | **0.86 / 0.68 ms** | — | 10.63 / 2.41 ms | 731.46 / 363.13 ms |
| **Source footprint** | 1.23 MiB (35 files) | — | 44 KiB (1 file) | 5.41 MiB (`Full.luau`) |

Ouro's root `require` loads only types and a lazy facade, deferring `VM` (`45.22 ms` codegen / `20.88 ms` interp), `Parser` (`30.79 / 9.66 ms`), and `Compiler` (`60.16 / 19.62 ms`) until accessed (`137.01 / 50.83 ms` if every submodule loads eagerly).

## Capabilities

| Capability | Ouro (`0.1.0`) | Fiu | LuauCeption (`0.654`) |
| :--- | :--- | :--- | :--- |
| **Lexer & lossless AST** | Yes (`reconstruct()` exact bytes) | No | C++/WASM only |
| **Luau `0.748` bytecode compiler (`O0`–`O2`)** | Yes (pure Luau) | No | Luau `0.654` via WASM |
| **Bytecode disassembler & verifier** | Yes (`v3`–`v14` verified) | Deserializes only | C++/WASM only |
| **Sandboxed register VM** | Dual `@native` fast / guarded | Interpreter loop | WASM C VM (`lua_State`) |
| **Instruction, call, time & memory limits** | Yes (`LoadOptions` + `ResourceLimits`) | Custom hooks only | Custom C setup |
| **Per-environment RNG & `getGlobal`/`setGlobal`** | Built-in (`PCG32`) | Manual metatable env | Manual metatable env |
| **Runtime architecture** | Pure `--!strict` Luau | Pure Luau | Emscripten WASM in Luau |

## Native Codegen (`luau --codegen -O2`)

### Warm VM Execution (`p50` ms)

| Workload | Description | Host | Ouro | Ouro guarded | Fiu (`default`) | Fiu (`fast`) | LuauCeption |
| :--- | :--- | ---: | ---: | ---: | ---: | ---: | ---: |
| `vm-suite` | Mixed loop, fib, meta, co | 0.554 | **6.965** | 8.346 | 18.361 | 16.485 | 261.637 |
| `arith-100k` | 100k arithmetic loop | 1.540 | **7.601** | 8.772 | 21.808 | 20.230 | 565.080 |
| `fib-24` | Recursive `fib(24)` | 2.613 | **34.782** | 43.218 | 284.626 | 268.780 | 1267.670 |
| `closures-20k` | 20k upvalue closures | 0.839 | **12.001** | 12.966 | 15.326 | 16.379 | 360.232 |
| `tables-meta-5k` | 5k metatable & method ops | 0.601 | **9.923** | 11.195 | 22.695 | 21.381 | 380.823 |
| `imports-20k` | 20k `math` builtins & imports | 0.937 | **20.420** | 17.665 | 33.953 | 36.667 | 288.239 |
| `globals-20k` | 20k global reads & writes | 0.206 | **1.654** | 2.073 | 3.524 | 3.501 | 107.291 |
| `pcall-2k` | 2k `pcall` frames (25% throw) | 1.300 | **2.476** | 4.234 | 6.820 | 6.644 | *DNF (error)* |
| `forin-gen-20k` | 20k `ipairs` table scans | 0.105 | **2.055** | 2.403 | 6.797 | 5.443 | 85.465 |
| `quicksort-2k` | Quicksort 2,000 numbers | 0.786 | **4.898** | 5.607 | 11.331 | 17.510 | 333.233 |
| `string-ops-10k` | 10k concat & string calls | 1.379 | **5.672** | 5.806 | 21.776 | 18.754 | 467.504 |
| `varargs-10k` | 10k `select` vararg loops | 0.814 | **15.197** | 18.782 | 52.228 | 47.957 | 411.608 |
| `table-dict-20k` | 20k dictionary field ops | 1.605 | **9.524** | 11.497 | 20.752 | 30.839 | 587.711 |

### O2 Compilation & Bytecode Loading (`p50` ms)

| Corpus | Size | Bytecode | Lex | Parse | Compile O2 | Full O2 (`Ouro`) | Full O2 (`LC`) | Speedup |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `tiny-120B` | 56 B | 86 B | 0.004 | 0.014 | 0.032 | **0.056** | 0.679 | 12.18× |
| `runtime-10KiB` | 10 KiB | 10,628 B | 0.587 | 1.948 | 3.822 | **5.330** | 89.672 | 16.82× |
| `runtime-50KiB` | 50 KiB | 54,019 B | 2.828 | 9.401 | 21.271 | **33.984** | 408.663 | 12.03× |
| `runtime-250KiB` | 250 KiB | 271,252 B | 13.753 | 48.308 | 133.034 | **197.567** | 2248.890 | 11.38× |
| `types-50KiB` | 50 KiB | 41 B | 3.711 | 9.469 | 0.771 | **12.224** | 244.866 | 20.03× |

`Ouro.Bytecode.deserialize` decodes the `10 KiB / 50 KiB / 250 KiB` runtime bytecode in `0.110 / 0.479 / 3.738 ms`, and `Ouro.VM.loadBytecode` prepares callable closures in `0.312 / 1.192 / 5.925 ms`.

## Interpreter (`luau -O2`)

### Warm VM Execution (`p50` ms)

| Workload | Host | Ouro | Ouro guarded | Fiu (`default`) | Fiu (`fast`) | LuauCeption |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: |
| `vm-suite` | 0.577 | **16.564** | 20.170 | 61.549 | 60.962 | 249.109 |
| `arith-100k` | 0.943 | **27.537** | 30.871 | 151.394 | 151.973 | 515.975 |
| `fib-24` | 2.520 | **91.686** | 106.796 | 430.404 | 372.962 | 1149.780 |
| `closures-20k` | 0.691 | **21.717** | 24.796 | 46.183 | 47.072 | 347.767 |
| `tables-meta-5k` | 0.645 | **16.980** | 19.526 | 52.073 | 51.465 | 318.251 |
| `imports-20k` | 0.581 | **15.918** | 17.540 | 106.392 | 104.942 | 256.775 |
| `globals-20k` | 0.204 | **6.310** | 7.115 | 16.206 | 16.657 | 97.796 |
| `pcall-2k` | 0.924 | **3.348** | 5.319 | 11.359 | 9.633 | *DNF (error)* |
| `forin-gen-20k` | 0.103 | **4.842** | 5.366 | 21.069 | 20.309 | 75.952 |
| `quicksort-2k` | 0.741 | **16.503** | 18.999 | 44.998 | 46.890 | 269.529 |
| `string-ops-10k` | 1.242 | **15.073** | 15.316 | 62.572 | 60.570 | 438.220 |
| `varargs-10k` | 0.544 | **29.330** | 33.748 | 150.914 | 149.920 | 382.082 |
| `table-dict-20k` | 1.439 | **26.183** | 29.045 | 95.559 | 88.691 | 561.358 |

### O2 Compilation & Bytecode Loading (`p50` ms)

| Corpus | Lex | Parse | Compile O2 | Full O2 (`Ouro`) | Full O2 (`LC`) | Speedup |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: |
| `tiny-120B` | 0.008 | 0.022 | 0.047 | **0.078** | 0.673 | 8.68× |
| `runtime-10KiB` | 1.158 | 3.368 | 8.584 | **10.688** | 83.291 | 7.79× |
| `runtime-50KiB` | 5.816 | 17.855 | 42.368 | **61.230** | 424.391 | 6.93× |
| `runtime-250KiB` | 28.514 | 88.671 | 213.784 | **301.014** | 2172.060 | 7.22× |
| `types-50KiB` | 7.155 | 18.732 | 1.135 | **19.308** | 246.285 | 12.76× |

`Ouro.Bytecode.deserialize` takes `0.181 / 0.974 / 4.114 ms` across `10 KiB / 50 KiB / 250 KiB`, and `Ouro.VM.loadBytecode` takes `0.578 / 2.963 / 13.147 ms`.

## Methodology

- **Sampling:** Warmed median (`p50`) over `7` runs (`5` for `fib-24` and `runtime-250KiB`; `9` for `cold-load-run`). Expect roughly `±10%` run-to-run variance on microbenchmarks.
- **Fair sandbox configuration:** Ouro executes in its default isolated environment (`VM.createEnvironment()`), with `Ouro (guarded)` enforcing `instructionLimit = 50_000_000`. `Fiu (fast)` configures `errorHandling = false`, `reuseClosures = true`, `vectorCtor = vector.create`, and static `useImportConstants = true` on all non-global workloads. `LuauCeption` runs inside `luaL_sandbox(L)` on all non-global workloads.
- **Handling `pcall-2k`:** LuauCeption throws `Infinity` in WASM C++ exception handling when guest errors unwind inside `pcall` (`pcall-2k`). Its bar renders as `DNF (error)` on the full breakdown chart, and its VM geometric mean (`43.69×` codegen / `16.92×` interp) is computed over the `12` workloads it completes without adding an arbitrary timeout penalty.

## Reproducing

Run Ouro standalone without third-party dependencies:

```sh
luau --codegen -O2 docs/benchmarks/run.luau
```

Or run the sequential 3-way runner against local Fiu and LuauCeption copies to update [`results.json`](https://github.com/kohltastrophe/ouro/blob/main/docs/benchmarks/results.json) and regenerate both SVGs:

```sh
python3 docs/benchmarks/bench.py --fiu /path/to/Fiu/Source.luau --luauception /path/to/luauception
python3 docs/benchmarks/chart.py
```
