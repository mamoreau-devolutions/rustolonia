# avalonia-sys

Raw nano-COM bindings for the Avalonia NativeAOT host (`Avalonia.Host`).

This crate is handwritten plus IR-generated vtables/GUIDs (see
`../projection.ir.json` and `avalonia-bindgen`), and is consumed almost
exclusively through the safe `avalonia` crate. It is source-only: `publish =
false` because it is pinned to a matching `Avalonia.Host` build produced from
the same checkout, not to a versioned ABI contract suitable for crates.io.

See [`../PRODUCTIZATION.md`](../PRODUCTIZATION.md) and
[`../README.md`](../README.md) for the full workflow, and
[`../OWNERSHIP.md`](../OWNERSHIP.md) for the ownership contract this crate
implements.

## Host lifetime

`Host::load` resolves every required export before publishing the process-wide
UTF-16 allocation callbacks. Successful host libraries intentionally remain
loaded for the process lifetime because returned ABI strings can outlive a
`Host` value. A later load whose `avn_free` or `avn_alloc_utf16` exports differ
is rejected, preserving the single allocator-host invariant.
