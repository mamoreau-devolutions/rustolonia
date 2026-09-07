using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using Avalonia.Projection.Generator;
using Xunit;

namespace Avalonia.Projection.Generator.Tests;

public class OwnedOutputWriterTests
{
    [Fact]
    public void Check_mode_does_not_create_missing_directories_or_files()
    {
        using var scratch = new Scratch();
        var missingRoot = Path.Combine(scratch.Root, "absent");
        var path = Path.Combine(missingRoot, "owned.g.cs");

        var result = OwnedOutputs.Check(OwnedOutputs.ViewModelGeneratorId, new Dictionary<string, string>
        {
            [path] = "generated\n",
        });

        Assert.False(result.Success);
        Assert.Contains(result.Mismatches, item => item.StartsWith("MISSING:", StringComparison.Ordinal) && item.Contains(path, StringComparison.Ordinal));
        Assert.False(Directory.Exists(missingRoot));
        Assert.False(File.Exists(path));
        Assert.Empty(Directory.GetFileSystemEntries(scratch.Root));
    }

    [Fact]
    public void Check_reports_changed_missing_and_obsolete_outputs()
    {
        using var scratch = new Scratch();
        var changed = Path.Combine(scratch.Root, "changed.g.cs");
        var missing = Path.Combine(scratch.Root, "missing.g.cs");
        var obsolete = Path.Combine(scratch.Root, "obsolete.g.cs");
        File.WriteAllText(changed, "old\n");
        File.WriteAllText(obsolete, "stale\n");
        OwnedOutputs.Write(OwnedOutputs.ViewModelGeneratorId, new Dictionary<string, string>
        {
            [changed] = "old\n",
            [obsolete] = "stale\n",
        });

        var result = OwnedOutputs.Check(OwnedOutputs.ViewModelGeneratorId, new Dictionary<string, string>
        {
            [changed] = "new\n",
            [missing] = "fresh\n",
        });

        Assert.Contains(result.Mismatches, item => item.StartsWith("DIFFERENT:", StringComparison.Ordinal) && item.Contains(changed, StringComparison.Ordinal));
        Assert.Contains(result.Mismatches, item => item.StartsWith("MISSING:", StringComparison.Ordinal) && item.Contains(missing, StringComparison.Ordinal));
        Assert.Contains(result.Mismatches, item => item.StartsWith("OBSOLETE:", StringComparison.Ordinal) && item.Contains(obsolete, StringComparison.Ordinal));
        Assert.Equal("old\n", File.ReadAllText(changed).Replace("\r\n", "\n"));
        Assert.Equal("stale\n", File.ReadAllText(obsolete).Replace("\r\n", "\n"));
        Assert.False(File.Exists(missing));
    }

    [Fact]
    public void Write_prunes_only_manifest_owned_stale_files_and_keeps_unrelated_and_other_generator_outputs()
    {
        using var scratch = new Scratch();
        var kept = Path.Combine(scratch.Root, "kept.g.cs");
        var stale = Path.Combine(scratch.Root, "stale.g.cs");
        var unrelated = Path.Combine(scratch.Root, "notes.txt");
        var other = Path.Combine(scratch.Root, "other.g.cs");
        File.WriteAllText(unrelated, "leave me\n");
        OwnedOutputs.Write(OwnedOutputs.ProjectionGeneratorId, new Dictionary<string, string>
        {
            [other] = "projection-owned\n",
        });
        OwnedOutputs.Write(OwnedOutputs.ViewModelGeneratorId, new Dictionary<string, string>
        {
            [kept] = "keep\n",
            [stale] = "remove\n",
        });

        OwnedOutputs.Write(OwnedOutputs.ViewModelGeneratorId, new Dictionary<string, string>
        {
            [kept] = "keep-updated\n",
        });

        Assert.Equal("keep-updated\n", File.ReadAllText(kept).Replace("\r\n", "\n"));
        Assert.False(File.Exists(stale));
        Assert.Equal("leave me\n", File.ReadAllText(unrelated).Replace("\r\n", "\n"));
        Assert.Equal("projection-owned\n", File.ReadAllText(other).Replace("\r\n", "\n"));
        Assert.True(File.Exists(Path.Combine(scratch.Root, OwnedOutputs.ManifestFileName(OwnedOutputs.ProjectionGeneratorId))));
    }

    [Fact]
    public void Write_refuses_to_delete_obsolete_file_modified_outside_the_generator()
    {
        using var scratch = new Scratch();
        var kept = Path.Combine(scratch.Root, "kept.g.cs");
        var stale = Path.Combine(scratch.Root, "stale.g.cs");
        OwnedOutputs.Write(OwnedOutputs.ViewModelGeneratorId, new Dictionary<string, string>
        {
            [kept] = "keep\n",
            [stale] = "owned-stale\n",
        });
        File.WriteAllText(stale, "edited by hand\n");
        var beforeKept = File.ReadAllBytes(kept);
        var beforeStale = File.ReadAllBytes(stale);
        var manifestBefore = File.ReadAllBytes(Path.Combine(scratch.Root, OwnedOutputs.ManifestFileName(OwnedOutputs.ViewModelGeneratorId)));

        var error = Assert.Throws<InvalidOperationException>(() => OwnedOutputs.Write(
            OwnedOutputs.ViewModelGeneratorId,
            new Dictionary<string, string> { [kept] = "keep-updated\n" }));

        Assert.Contains("modified outside the generator", error.Message, StringComparison.Ordinal);
        Assert.Equal(beforeKept, File.ReadAllBytes(kept));
        Assert.Equal(beforeStale, File.ReadAllBytes(stale));
        Assert.Equal(manifestBefore, File.ReadAllBytes(Path.Combine(scratch.Root, OwnedOutputs.ManifestFileName(OwnedOutputs.ViewModelGeneratorId))));
    }

    [Fact]
    public void Malformed_ownership_paths_are_rejected_without_changing_existing_bytes()
    {
        using var scratch = new Scratch();
        var owned = Path.Combine(scratch.Root, "owned.g.cs");
        File.WriteAllText(owned, "original\n");
        var manifestPath = Path.Combine(scratch.Root, OwnedOutputs.ManifestFileName(OwnedOutputs.ViewModelGeneratorId));
        File.WriteAllText(manifestPath, """
            {
              "generator": "avalonia-viewmodel",
              "files": [
                { "path": "../escape.g.cs", "sha256": "00" }
              ]
            }
            """);
        var ownedBytes = File.ReadAllBytes(owned);
        var manifestBytes = File.ReadAllBytes(manifestPath);

        var error = Assert.Throws<InvalidOperationException>(() => OwnedOutputs.Write(
            OwnedOutputs.ViewModelGeneratorId,
            new Dictionary<string, string> { [owned] = "updated\n" }));

        Assert.Contains("unsafe path", error.Message, StringComparison.Ordinal);
        Assert.Equal(ownedBytes, File.ReadAllBytes(owned));
        Assert.Equal(manifestBytes, File.ReadAllBytes(manifestPath));
    }

    [Fact]
    public void Absolute_manifest_path_is_rejected()
    {
        using var scratch = new Scratch();
        var owned = Path.Combine(scratch.Root, "owned.g.cs");
        File.WriteAllText(owned, "original\n");
        var absolute = Path.Combine(scratch.Root, "other.g.cs");
        File.WriteAllText(Path.Combine(scratch.Root, OwnedOutputs.ManifestFileName(OwnedOutputs.ViewModelGeneratorId)), $$"""
            {
              "generator": "avalonia-viewmodel",
              "files": [
                { "path": {{ToJson(absolute)}}, "sha256": "00" }
              ]
            }
            """);

        var error = Assert.Throws<InvalidOperationException>(() => OwnedOutputs.Check(
            OwnedOutputs.ViewModelGeneratorId,
            new Dictionary<string, string> { [owned] = "original\n" }));
        Assert.Contains("unsafe path", error.Message, StringComparison.Ordinal);
        Assert.Equal("original\n", File.ReadAllText(owned).Replace("\r\n", "\n"));
    }

    [Fact]
    public void Check_with_normalize_is_rejected_by_flag_helper()
    {
        Assert.True(GeneratorCli.ContainsCheckAndNormalize(["--check", "--normalize", "view-model.ir.json"]));
        Assert.True(GeneratorCli.ContainsCheckAndNormalize(["--normalize", "--check", "view-model.ir.json"]));
        Assert.False(GeneratorCli.ContainsCheckAndNormalize(["--check", "a", "b", "c", "d", "e"]));
        Assert.Equal("Cannot combine --check with --normalize.", GeneratorCli.CheckWithNormalizeMessage);
    }

    [Fact]
    public void Bootstrap_does_not_claim_unrelated_gcs_files()
    {
        using var scratch = new Scratch();
        var generated = Path.Combine(scratch.Root, "SampleAdapter.g.cs");
        var leftover = Path.Combine(scratch.Root, "HandWritten.g.cs");
        File.WriteAllText(leftover, "not generated\n");

        OwnedOutputs.Write(OwnedOutputs.ViewModelGeneratorId, new Dictionary<string, string>
        {
            [generated] = "adapter\n",
        });

        Assert.True(File.Exists(leftover));
        var manifest = File.ReadAllText(Path.Combine(scratch.Root, OwnedOutputs.ManifestFileName(OwnedOutputs.ViewModelGeneratorId)));
        Assert.Contains("SampleAdapter.g.cs", manifest, StringComparison.Ordinal);
        Assert.DoesNotContain("HandWritten.g.cs", manifest, StringComparison.Ordinal);
    }

    private static string ToJson(string value)
    {
        var builder = new StringBuilder("\"");
        foreach (var character in value)
        {
            builder.Append(character switch
            {
                '\\' => "\\\\",
                '"' => "\\\"",
                _ => character.ToString(),
            });
        }

        builder.Append('"');
        return builder.ToString();
    }

    private sealed class Scratch : IDisposable
    {
        public string Root { get; } = Path.Combine(Path.GetTempPath(), "rustolonia-owned-" + Guid.NewGuid().ToString("N"));

        public Scratch() => Directory.CreateDirectory(Root);

        public void Dispose()
        {
            if (Directory.Exists(Root))
                Directory.Delete(Root, recursive: true);
        }
    }
}
