---
title: Security & Sandbox
description: Sandbox trust boundaries, resource caps, bytecode verification, and vulnerability reporting.
outline: deep
sidebar_position: 4
---

# Security & Sandbox

## Supported Versions

Ouro tracks pinned official Luau releases (`0.748` for `v0.1.0`). Security fixes apply to the latest `0.1.x` release on `main` and the `dist` runtime branch.

## Sandbox Scope & Boundaries

[`Ouro.load`](/api/Ouro#load) executes guest Luau bytecode (`v3`–`v14`) in an isolated register VM rather than host `loadstring`. See [Sandboxed VM](/guide/pipeline/vm) for full environment and budget options. The following boundaries apply:

- **Environments**: `Ouro.load` creates a fresh pure-stdlib environment by default (`inheritHost = false`) and never implicitly inherits an outer VM environment unless the caller passes `options.env` explicitly.
- **String Metatable**: `getmetatable("")` returns `"The metatable is locked"` inside VM environments on both hosts. Because host Luau shares one string metatable across all strings, method syntax such as `("abc"):upper()` resolves against host `string` methods even when `"string"` is omitted from `libraries`.
- **Budgets & DoS Controls**: Enable `instructionLimit`, `timeout`, `callLimit`, and `resourceLimits` (`maxStringLength`, `maxTableSize`, `maxBufferSize`, `maxPatternLength`) together when running untrusted code. Host C library calls run atomically outside per-instruction limits, and incremental table growth (`t[i] = i`) and compile-time `O2` constant folding run outside `resourceLimits`.
- **Bytecode Verification**: Untrusted binary bytecode (`v3`–`v14`) and `ProtoModule` tables pass static bounds, constant, jump, and capture checks before instantiation. Experimental class bytecode (`v100`) is rejected by the VM loader and verifier.

## Reporting a Vulnerability

Please open a private [GitHub Security Advisory](https://github.com/kohltastrophe/ouro/security/advisories/new) with a minimal reproducer, expected behavior, and observed impact instead of filing a public issue.
