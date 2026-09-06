# avalonia-patches

Additive patches against the [Avalonia UI framework](https://github.com/AvaloniaUI/Avalonia)
that rustolonia's NativeAOT host and projected TableView surface depend on.
They are meant to be applied to the `avalonia-src` submodule checkout
(pinned to a release tag) by `apply-avalonia-patches.ps1`.

| Patch | Contents |
|---|---|
| `avalonia-controls.patch` | `IViewportRangeSource` (new viewport-range interface), `TableViewColumn.MinWidth/MaxWidth/IsVisible` + `ClampWidth`, `TableViewRowAutomationPeer` (new), TableView layout/row/column-header hooks, and their unit tests |

## Usage

```pwsh
# after cloning submodules (avalonia-src pinned to a release tag)
pwsh ./apply-avalonia-patches.ps1 -AvaloniaRoot ../avalonia-src

# CI / after bumping the submodule to a newer tag
pwsh ./apply-avalonia-patches.ps1 -AvaloniaRoot ../avalonia-src -Check

# CI / after bumping the submodule to a newer tag
pwsh ./apply-avalonia-patches.ps1 -AvaloniaRoot ../avalonia-src -Check
```

Applying is idempotent: an already-patched checkout is detected and skipped.

Validated producers: the patch applies cleanly to upstream tag `12.1.2`
(2026-09-02) and to `origin/main` as of 2026-09-05; the patched 12.1.2
checkout builds and its full `Avalonia.Controls.UnitTests` suite passes.

## Maintenance

- Bump the submodule to a new Avalonia tag, then run with `-Check` first.
- If a patch stops applying, regenerate it from the rustolonia branch
  (`git diff <merge-base> HEAD -- src/Avalonia.Controls tests/Avalonia.Controls.UnitTests`)
  and update the upstreaming tracker below.
- The goal is for this directory to shrink to nothing as the changes are
  merged upstream.

## Upstreaming tracker

| Change | Status |
|---|---|
| `IViewportRangeSource` + TableView `NotifyVisibleRange` | candidate PR — additive, framework-generic |
| `TableViewColumn.MinWidth/MaxWidth/IsVisible` + `ClampWidth` + layout/header integration | candidate PR — additive, standalone control feature |
| `TableViewRowAutomationPeer` | candidate PR — accessibility, follows existing peer patterns |
| Column/row unit tests | rides with the PRs above |
| `InternalsVisibleTo` for `Avalonia.Host` (+ tests) in `Avalonia.Controls.csproj` | rustolonia-specific; preferred fix is a public `CustomPopupPlacement` factory, after which this line disappears |
