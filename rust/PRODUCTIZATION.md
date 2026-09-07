# Productizing the Rust application workflow

This documents the reusable, scripted path from "empty directory" to a
packaged Rust Avalonia application: the copyable project template, the
one-command regeneration/build loop, native host discovery, the deterministic
per-runtime-identifier (RID) artifact layout with checksums and an optional
signing hook, source-only crate packaging readiness, and the EU CRA CycloneDX
SBOM scope decision for everything this workflow ships.

Nothing here changes the generated ABI, the ownership contract, or the
view-model transport; see [README.md](README.md), [OWNERSHIP.md](OWNERSHIP.md),
[ASYNC.md](ASYNC.md), [VIEW_MODELS.md](VIEW_MODELS.md),
[DESKTOP_FILES.md](DESKTOP_FILES.md), and [PLATFORMS.md](PLATFORMS.md) for
those. Release compatibility, RID artifact integrity, signing, and future SBOM
requirements are defined in [COMPATIBILITY.md](COMPATIBILITY.md).

## Application template

[`templates/avalonia-app`](templates/avalonia-app) is a minimal, copyable
Cargo project (a `Cargo.toml` with a path dependency on `avalonia`, plus a
`src/main.rs` that opens a window) meant to be copied outside this repository
to bootstrap a new application. `new-app.ps1` do the copy and
package rename:

```powershell
.\rust\new-app.ps1 -Name my_app -Destination .\my_app
```

```bash
pwsh ./rust/new-app.ps1 my_app ~/src/my_app
```

The template is excluded from the `rust` Cargo workspace (see the `exclude`
entry in `Cargo.toml`) and declares an empty workspace of its own. The template is an external consumer, including a managed AXAML project,
versioned view-model IR, and `avalonia-app.json`. It also carries copyable
Windows/Linux/macOS file type association metadata in `file-associations/`, and
a `main.rs` that already surfaces startup "open with" documents through
`AppScope::activation_items()` (see
[DESKTOP_FILES.md](DESKTOP_FILES.md#file-type-associations)). `new-app`
substitutes both the Cargo package name and the pinned producer-root
placeholder throughout, including those snippets. Commit the producer as a
submodule (or pin a checkout to an immutable commit); do not point a release
consumer at an unpinned branch.
Initialize the pinned producer recursively before generation or publishing:

```bash
git submodule update --init --recursive
```

This is required because the producer build consumes its XamlX and platform
submodules. The vendored template declares an empty `[workspace]`, so it does
not become an accidental member of an enclosing consumer Cargo workspace.
`regenerate-and-build.ps1 -ValidateTemplate` /
`pwsh ./regenerate-and-build.ps1 -ValidateTemplate` copies it through `new-app`
before running `cargo check`.

## External consumer build and package

`consumer-app-manifest.schema.json` defines manifest version 1. The required
fields name the consumer presentation `.csproj`, IR, generated adapter,
registry, Rust and contract outputs, Cargo manifest/package, RID,
configuration, and output directory; `binary` optionally selects a normal
Cargo binary and defaults to `packageName`.

```powershell
& .\rustolonia\rust\build-app.ps1 -ProducerRoot .\rustolonia\avalonia-src `
  -Manifest .\consumer\avalonia-app.json
```

The cross-platform `build-app.ps1` (PowerShell 7) validates the
manifest and paths before it runs Rustolonia's
`Avalonia.ViewModelProjection.Tool` against consumer outputs. It then runs
`cargo fmt`, builds consumer AXAML, builds the declared Cargo `--bin`, and
publishes `Avalonia.Host` with
`AvaloniaRustPresentationProjects` and `AvaloniaRustViewRegistryFile`.
The external ProjectReference and linked generated registry are therefore
compiled statically into NativeAOT; no application-specific ABI is introduced.
External Rust output uses a crate-root compatibility bridge. Consumers must
re-export `DynamicViewModel`, `ViewModelSink`, `ViewModelBatch`, and
`BatchCompletion` from `avalonia::view_model`; the shipped template already
does so.
Finally it writes the host, published native DLLs/shared libraries, consumer
executable, the producer's `licence.md`, Rustolonia's `LICENSE` and
`THIRD-PARTY-NOTICES.txt`, deterministic CycloneDX delivery inventory, and SHA-256
checksums to the manifest's adjacent output directory. A local
`AVALONIA_RUST_SIGN_COMMAND` wrapper may sign final binaries before SBOM and
checksums; it is never downloaded or shell-expanded.

Both packaging entrypoints share `package-shared.ps1`: target mappings, native
preparation, command construction, native-library copying, signing and checksums.
Consumer publication uses a unique temporary staging directory, and cleans only
that invocation's directory. A `.rustolonia-bundle-owner` marker identifies
disposable output bundles. A nonempty directory without the valid marker is
rejected rather than erased; choose a new output directory for existing bundles
created before this ownership mechanism.

Windows MSVC Rust binaries are built with `target-feature=+crt-static`, so the
adjacent bundle does not require a separately installed Visual C++ runtime.
The external template carries the same target-specific Cargo configuration;
`build-app` also enforces it for existing consumer workspaces.

## One-command developer workflow

`regenerate-and-build.ps1` replace the four
previously separate, manually copy-pasted commands from README.md's
"Regenerate bindings" section with one:

1. Regenerate the object-model projection IR, generated C# COM sources, and
   the native ABI header from the current `AvaloniaObject`/`Control`
   assemblies (`Avalonia.Projection.Tool`).
2. Regenerate the Rust `avalonia-sys`/`avalonia` bindings from that IR
   (`avalonia-bindgen`), then `cargo fmt --all`.
3. Regenerate the managed adapters, application view registry, Rust
   view-model API, and `view-model.contract.md` from the sample-owned
   `rust/avalonia-sample/view-model.ir.json` (`Avalonia.ViewModelProjection.Tool`
   with `--external-rust`).
4. Build the code-first host (no sample presentation), then the
   sample-composed host (`AvaloniaRustPresentationProjects` +
   `AvaloniaRustViewRegistryFile`), then the Rust workspace
   (`cargo build --workspace`).

```powershell
.\rust\regenerate-and-build.ps1
```

```bash
pwsh ./rust/regenerate-and-build.ps1
```

Both scripts are idempotent when the IR hasn't changed (running them against
an unmodified `projection.ir.json`/`view-model.ir.json` reproduces byte-identical
generated output) and fail fast: each step's exit code stops the script before
the next one runs.

## Tabular presentation

Schema version 3 table metadata is generated with the normal consumer
presentation sources. Consumers use built-in `TableView` columns and compiled
AXAML cell bindings; no DataGrid package, runtime binding reflection, or
application-specific host code is required. A stage-28 model snapshot still has
one managed row adapter per delivered row, while `TableView` virtualizes visual
rows. Stage 30's schema-v4 `window` metadata is the range-backed answer: the
projection reports the whole Rust dataset size while keeping live element
objects bounded by `pageSize * maxLivePages`, and both shapes ship in the
sample so the difference is measurable rather than asserted.

Useful switches/environment variables:

| PowerShell | Bash (env var) | Effect |
| --- | --- | --- |
| `-Configuration Debug` | `pwsh ./regenerate-and-build.ps1 Debug` | Build configuration for the .NET regeneration tools and managed build (default `Release`). |
| `-SkipManagedBuild` | `AVN_SKIP_MANAGED_BUILD=1` | Skip step 4's `dotnet build`, e.g. when only the Rust side changed. |
| `-Test` | `AVN_RUN_CARGO_TESTS=1` | Run `cargo test --workspace` instead of `cargo build --workspace`. Requires a host discoverable per [Host discovery](#host-discovery) below (`rust/build.ps1` publish one; set `AVN_HOST_NATIVE_LIB` otherwise). |
| `-ValidateTemplate` | `AVN_VALIDATE_TEMPLATE=1` | Additionally `cargo check` the application template in place. |
| `-PackageRid <rid>` | `AVN_PACKAGE_RID=<rid>` | Additionally run [`package.ps1`](#deterministic-per-rid-artifact-layout) for that RID. |

This script intentionally does not replace `rust/build.ps1`
(full RID publish plus `cargo test --workspace` against the exact published
host) or `package.ps1` (below): it is the fast inner
regenerate/compile loop, and delegates to those for anything that needs a
real NativeAOT publish.

## Host discovery

`avalonia::App::load_from_env()` (used by every example and the template)
resolves the native `Avalonia.Host` library through `avalonia::discover_host_path()`:

1. **`AVN_HOST_NATIVE_LIB`** (the `avalonia::HOST_NATIVE_LIB_ENV_VAR` constant) -- an explicit
   override. If set, its value is used as-is, even if nothing exists at that
   path yet, so `Host::load` can surface a precise loader error instead of
   this function silently falling back to the next mechanism. This remains
   how `rust/build.ps1` point the workspace test suite at a
   freshly published host, and how you point a running app at a different
   host during development.
2. **Adjacent to the executable** -- otherwise, the platform host file name
   (`Avalonia.Host.dll` on Windows, `Avalonia.Host.so` on Linux,
   `Avalonia.Host.dylib` on macOS) is looked up next to
   `std::env::current_exe()`. This is what lets a packaged application run
   with no environment variable at all: [`package.ps1`](#deterministic-per-rid-artifact-layout)
   copy the host and the application binary into the same directory.

If neither resolves, the error names both the environment variable and the
host file name it looked for next to the executable's directory. See
`rust/avalonia/src/runtime.rs` (`discover_host_path`, `HOST_NATIVE_LIB_ENV_VAR`)
for the implementation, `rust/avalonia/src/runtime.rs`'s
`host_discovery_tests` module for unit tests of the override/adjacent-lookup
precedence and error message, and `rust/avalonia/tests/host_discovery.rs` for
the same behavior exercised through the crate's public API.

## Deterministic per-RID artifact layout

`package.ps1` publish the NativeAOT host for
one RID, build a Rust binary next to it, and lay both out identically
regardless of platform, under `rust/artifacts/<rid>/`:

```powershell
.\rust\package.ps1 -Rid win-x64
```

```bash
pwsh ./rust/package.ps1 linux-x64
```

```bash
pwsh ./rust/package.ps1 osx-arm64
```

Both produce, for every supported RID:

- `Avalonia.Host.<dll|so|dylib>` -- the published NativeAOT host.
- Its native rendering dependencies that publish alongside it
  (`libSkiaSharp`/`libHarfBuzzSharp`, plus `libAvaloniaNative.dylib` on
  macOS), copied only if present. `package.ps1` copies every published `.so`,
  versioned `.so.*`, and `.dylib` dependency rather than maintaining a
  platform-specific allow-list.
- The requested Rust binary (`hello_world` by default; pass `-Example`/an
  extra argument to package a different example, or point `-OutputRoot`
  /`AVN_PACKAGE_OUTPUT` and build the copied application template the same
  way), placed **next to** the host so [host discovery](#host-discovery)
  finds it with no environment variable.
- `checksums.sha256` -- a `sha256sum -c`-compatible SHA-256 manifest of every
  other file in the directory, generated last so it never hashes itself.
- `licence.md`, `LICENSE`, `THIRD-PARTY-NOTICES.txt` -- producer and project
  licensing notices copied into every delivery bundle.
- `.rustolonia-bundle-owner` -- the marker authorizing replacement of a previously
  generated bundle; it is included in the delivery inventory and checksums.
- `sbom.cdx.json` -- a deterministic CycloneDX 1.5 delivery inventory,
  generated after optional signing and before checksums. It records SHA-256
  hashes for the host, Rust executable, bundled native libraries, and licence;
  it intentionally excludes itself and the checksum manifest to avoid a
  recursive hash. It also records the resolved third-party dependency graph:
  NuGet packages from the host's already-restored `project.assets.json` (no
  network access; `type: "project"` entries such as in-repo project
  references are excluded) and Cargo crates from `Cargo.lock` (workspace-local
  crates with no `[source]`, like `avalonia`, are excluded as not third-party).
  Each resolved dependency is a CycloneDX `library` component with a `purl`
  (`pkg:nuget/...`/`pkg:cargo/...`). `metadata.properties` records the producer
  git pin used for the build and, when a dependency source path could not be
  supplied, an explicit note that dependency data for that ecosystem is
  unavailable rather than silently omitting it. This is still a delivery
  inventory of resolved packages and their identities, not a NVD/OSV
  vulnerability scan or license-compatibility check.

The layout is deterministic: the same RID with the same configuration and
example always produces the same file set at the same relative paths, which
is what makes the adjacent-host discovery above reliable and what a release
pipeline can zip and publish unchanged.

Each supported RID has an explicit native Cargo target; package scripts reject
an absent target with the corresponding `rustup target add` command:

| RID | Cargo target |
| --- | --- |
| `win-x64` | `x86_64-pc-windows-msvc` |
| `win-arm64` | `aarch64-pc-windows-msvc` |
| `linux-x64` | `x86_64-unknown-linux-gnu` |
| `linux-arm64` | `aarch64-unknown-linux-gnu` |
| `osx-x64` | `x86_64-apple-darwin` |
| `osx-arm64` | `aarch64-apple-darwin` |

Packaging supports same-OS cross-architecture builds when the required native
and Rust toolchains are available. Executing a packaged application requires a
matching native runner. Cross-build artifacts are therefore not evidence of
native runtime coverage.

### Signing hook

Neither script downloads or bundles a signing tool -- that would be exactly
the kind of unverified-binary shortcut this workflow avoids. Instead, before
the SBOM and checksums are computed, both scripts check for
`AVALONIA_RUST_SIGN_COMMAND`. If set, it must be the path to a trusted local
wrapper executable (or executable script); the script invokes it once per
binary artifact with that artifact's path as a separate argument. The wrapper
owns all signer options and identity selection. No shell evaluation or command
template expansion is performed. If unset, signing is skipped with a message
explaining how to opt in; either way, the SBOM and checksums describe final
(optionally signed) bytes.

The entrypoints explicitly identify the application executable, including
extensionless Linux/macOS binaries. Licensing files and ownership markers are
not signing inputs. Missing explicitly requested signing inputs fail the build.

## Source-only crate packaging

`avalonia`, `avalonia-sys`, and `avalonia-bindgen` all set `publish = false`:
they are pinned to a matching `Avalonia.Host` build from the same checkout,
not to a versioned ABI contract suitable for crates.io. That is a deliberate
choice, not a gap -- but the crates are kept in a state where `cargo package`
would succeed if that ever changed: each has `description`, `license`,
`repository`, and (for the two application-facing crates) a `readme`
pointing at a real `README.md`. This is checked with:

```bash
cargo package --list -p avalonia-sys --allow-dirty
cargo package --list -p avalonia --allow-dirty
cargo package --list -p avalonia-bindgen --allow-dirty
```

## SBOM (EU CRA) scope

The repository's CycloneDX SBOM generation (`nukebuild/SbomGenerator.cs`,
`CreateSbom` target) walks published NuGet packages: for each one it resolves
the packed assemblies' NuGet dependency graph and, where a package bundles a
built webapp (Numerge-merged assemblies, npm-built browser bundles), that
bundled content too. It does not scan arbitrary files on disk, so it does not
need to be told about something that is never packed into a shipped NuGet
package.

Everything this stage adds stays outside a shipped NuGet package, by design,
and the checks below are what keep that true instead of assumed:

- **`Avalonia.Host`, `Avalonia.Rust`, `Avalonia.Rust.Interop`,
  `Avalonia.Projection.*`, `Avalonia.ViewModelProjection.Tool`** remain
  `IsPackable=false` (unchanged by this stage). None are referenced by
  `nukebuild/numerge.json`. A project only needs SBOM coverage once it is
  packed into a published `.nupkg`; do not flip `IsPackable` to `true` for
  any of these without also giving `nukebuild/SbomGenerator.cs` a way to
  attribute their dependencies (native libraries, bundled assemblies) to the
  resulting package first.
- **The `rust/*` crates** are source only (`publish = false`, see above) and
  are never vendored as compiled binaries into any NuGet package; they are
  consumed by `cargo`, entirely outside the NuGet/CycloneDX pipeline.
- **The `rust/package.ps1` output** (`Avalonia.Host` plus
  its native dependencies and a Rust binary, per RID) is not a NuGet package
  and is not produced by this repository's NuGet publish path -- it is a
  standalone build artifact distributed by whatever channel a consumer of
  this workflow chooses (for example a GitHub release). Its delivery scope is
  covered by `sbom.cdx.json`, which inventories exact per-RID files after
  signing, and by `checksums.sha256`, which covers that SBOM too. This does
  not change the NuGet SBOM generator because no new packable NuGet project
  or package delivery dependency is introduced.
- **Stage 29 desktop file integration** adds only source files to the existing
  non-packable `Avalonia.Host` and to the source-only `rust/*` crates, plus
  template metadata snippets that are never compiled or copied into a delivered
  bundle. No new shipped package, bundled third-party binary, npm/JS content,
  or Numerge merge group is introduced, so neither `nukebuild/SbomGenerator.cs`
  nor `rust/generate-sbom.ps1`'s delivery inventory changes.

## Tests

- `pwsh ./rust/tests/test-build-app.ps1` runs quick script-parser, helper,
  path/ownership, signing, manifest and scaffold regressions without a native
  build. All fixtures are created in an owned temporary directory.
- Add `-RunNativeSmoke` to build, package and launch a fresh external consumer
  for the current OS/architecture. On Linux, run under a display such as
  `xvfb-run -a pwsh ./rust/tests/test-build-app.ps1 -RunNativeSmoke`. Smoke builds
  do not invoke a user-configured signing service and clear the host override
  when launching so that the adjacent packaged host is exercised.
- `rust/avalonia/src/runtime.rs` (`host_discovery_tests` module) and
  `rust/avalonia/tests/host_discovery.rs` cover `discover_host_path`: the
  explicit override always winning (even to a nonexistent path), the
  adjacent-file lookup succeeding and failing, and the combined error naming
  both mechanisms -- all without requiring a published host.
- `regenerate-and-build.ps1 -ValidateTemplate` / `AVN_VALIDATE_TEMPLATE=1
  pwsh ./regenerate-and-build.ps1` and direct `cargo check --manifest-path
  rust/templates/avalonia-app/Cargo.toml` compile-check the application
  template as a standalone crate.
- `cargo package --list` (see [Source-only crate packaging](#source-only-crate-packaging))
  is the packaging-readiness check for all three workspace crates.
- `package.ps1` self-verify their own output shape (the
  publish step fails the script if the host file is missing, the cargo build
  step fails it if the binary is missing) and were run end to end for
  `win-x64` while developing this stage, confirming the host, its native
  dependencies, the Rust binary, and a matching `checksums.sha256` land
  together in one deterministic directory.
- Desktop file integration is covered end to end from the managed picker core
  through the raw nano-COM vtables to the safe Rust API; the full table is in
  [DESKTOP_FILES.md](DESKTOP_FILES.md#tests).
