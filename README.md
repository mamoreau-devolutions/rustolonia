# rustolonia

First-class Rust bindings for [Avalonia](https://avaloniaui.net/), projected
over a nano-COM ABI served by a NativeAOT host. This repository contains the
complete bindings effort; the Avalonia framework itself is consumed from the
pinned `avalonia-src` producer submodule at commit
`9654332a79f637473da96054f75b2a16deaa557e`.

## Layout

| Directory | Contents |
|---|---|
| `avalonia-src/` | Avalonia producer pinned to `9654332a79f637473da96054f75b2a16deaa557e`, currently cloned from the `mamoreau-devolutions/Avalonia` fork |
| `avalonia-patches/` | Additive framework patches applied onto the pinned checkout (see its README + UPSTREAM.md) |
| `rust/` | The Rust workspace: `avalonia` (safe bindings), `avalonia-sys` (ABI bindings), `avalonia-bindgen` (IR to Rust generator), templates, build scripts, and the checked-in IR |
| `host/` | `Avalonia.Host` - the C# NativeAOT host that serves the ABI, plus its generated object model |
| `projection/` | The projection pipeline: IR extraction, C#/header emitters, and the generator tools |
| `interop/` | `Avalonia.Rust` and `Avalonia.Rust.Interop` - the managed-side view-model interop layer |
| `tests/` | Host, IR, and generator test suites |
| `samples/` | `RustViewModelSample.Managed` - the sample presentation project the host consumes |
| `build/` | Vendored MSBuild configuration (versioning, signing, analyzers, xunit) |

## Getting started

```pwsh
git clone --recurse-submodules https://github.com/mamoreau-devolutions/rustolonia
cd rustolonia
pwsh ./avalonia-patches/apply-avalonia-patches.ps1 -AvaloniaRoot ./avalonia-src
pwsh ./rust/regenerate-and-build.ps1 -Configuration Release
```

The regeneration pipeline (IR, generated C#, native header, Rust bindings) is
deterministic; CI fails if regenerating changes the checkout.

## Creating a new app

```pwsh
pwsh ./rust/new-app.ps1 -Name my_app -Destination ../my_app -ProducerRoot ./avalonia-src -RustoloniaRoot .
```

The generated app keeps the producer root and Rustolonia root separate, allows
paths with spaces, and validates the declared roots before writing any files.

## CI

`.github/workflows/avalonia-rust.yml` keeps the native release and cross-build
gates running automatically on pull requests and pushes to `main`. Native
execution covers Windows/Linux x64 and macOS x64/arm64; Windows/Linux arm64
have cross-build packaging coverage, not native execution coverage. The
original flagship samples remain part of the release gate.

The quick helper/scaffold suite does not build or launch an application:

```pwsh
pwsh ./rust/tests/test-build-app.ps1
```

Native jobs additionally build and launch a fresh external consumer:

```pwsh
pwsh ./rust/tests/test-build-app.ps1 -RunNativeSmoke
```

Linux native smoke execution needs a display, for example
`xvfb-run -a pwsh ./rust/tests/test-build-app.ps1 -RunNativeSmoke`.
