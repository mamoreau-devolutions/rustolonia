# rustolonia

First-class Rust bindings for [Avalonia](https://avaloniaui.net/), projected
over a nano-COM ABI served by a NativeAOT host. This repository contains the
complete bindings effort; the Avalonia framework itself is consumed from the
pinned `avalonia-src` producer submodule.

## Layout

| Directory | Contents |
|---|---|
| `avalonia-src/` | Git submodule: AvaloniaUI/Avalonia pinned to release tag `12.1.2` |
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
pwsh ./rust/new-app.ps1 -Name my_app -Destination ../my_app -ProducerRoot ./avalonia-src
```

## CI

`.github/workflows/avalonia-rust.yml` builds and tests the full matrix
(win/linux/osx, x64/arm64): applies the producer patches after checkout, runs
the managed suites, publishes the NativeAOT host, runs the cargo workspace
tests, builds and packages the flagship samples, and smoke-tests the packaged
artifacts.
