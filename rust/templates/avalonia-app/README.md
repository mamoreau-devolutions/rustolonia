# Avalonia Rust external consumer

This is a real external consumer. Keep a pinned producer checkout or submodule
at `producer/` (or let `new-app` write its path), then run:

```powershell
pwsh ./producer/rust/build-app.ps1 -ProducerRoot ./producer -Manifest ./avalonia-app.json
```

`build-app` regenerates the managed adapters, NativeAOT registry, and Rust
view-model API from `view-model.ir.json`, compiles this AXAML project and Rust
binary, and writes the adjacent runnable bundle declared by the manifest.

Generated external bindings use a crate-root compatibility bridge. Keep the
`view_model` exports in `src/main.rs`, including `DynamicViewModel`,
`ViewModelSink`, `ViewModelBatch`, and `BatchCompletion`.

The scaffold's schema declares a stage 31 `Main` menu with a copy command
(`Ctrl+C`), a recent-file submenu and `Exit` (`Ctrl+Q`). `MainWindow.axaml.cs`
attaches it through the generated `MainViewModelMenus.AttachMain`, which sets
the top-level's `NativeMenu` and installs the declared gestures as key
bindings; the `NativeMenuBar` in `MainWindow.axaml` renders that same menu
in-window on platforms without a native menu bar. Recent files are Rust-owned
storage URIs published through the generated `publish_recent_files`. See
`MENUS.md` in the producer checkout.
