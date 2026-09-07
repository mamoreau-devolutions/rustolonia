using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Avalonia.Projection.Generator;

public sealed class OwnedOutputCheckResult
{
    public IReadOnlyList<string> Mismatches { get; init; } = [];
    public bool Success => Mismatches.Count == 0;
}

public static class OwnedOutputs
{
    public const string ProjectionGeneratorId = "avalonia-projection";
    public const string ViewModelGeneratorId = "avalonia-viewmodel";
    public const string BindgenGeneratorId = "avalonia-bindgen";

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    public static string ManifestFileName(string generatorId) => $".{generatorId}.owned.json";

    public static string HashContent(string content)
    {
        var bytes = Encoding.UTF8.GetBytes(content);
        return Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();
    }

    public static bool IsSafeRelativePath(string path)
    {
        if (string.IsNullOrWhiteSpace(path))
            return false;
        if (Path.IsPathRooted(path))
            return false;

        var normalized = path.Replace('\\', '/');
        if (normalized.StartsWith('/') || normalized.Contains(':'))
            return false;

        var parts = normalized.Split('/', StringSplitOptions.None);
        return parts.Length > 0 && parts.All(part => part is not "" and not "." and not "..");
    }

    public static OwnedOutputCheckResult Check(
        string generatorId,
        IReadOnlyDictionary<string, string> files)
    {
        var mismatches = new List<string>();
        ValidateDestinations(generatorId, files);

        foreach (var (path, expected) in files.OrderBy(entry => entry.Key, StringComparer.OrdinalIgnoreCase))
        {
            if (!File.Exists(path))
            {
                mismatches.Add($"MISSING: {path}");
                continue;
            }

            var actual = File.ReadAllText(path).Replace("\r\n", "\n", StringComparison.Ordinal);
            if (!string.Equals(actual, expected, StringComparison.Ordinal))
                mismatches.Add($"DIFFERENT: {path}");
        }

        foreach (var directory in GroupByDirectory(files).Keys)
        {
            if (!Directory.Exists(directory))
                continue;

            var manifest = ReadManifest(directory, generatorId);
            if (manifest is null)
                continue;

            var expectedNames = ExpectedRelativeNames(directory, files);
            foreach (var owned in manifest.Files)
            {
                ValidateManifestEntry(directory, owned);
                if (expectedNames.Contains(owned.Path))
                    continue;

                var fullPath = Path.GetFullPath(Path.Combine(directory, owned.Path));
                if (!File.Exists(fullPath))
                {
                    mismatches.Add($"OBSOLETE: {fullPath}");
                    continue;
                }

                var onDisk = HashBytes(File.ReadAllBytes(fullPath));
                mismatches.Add(
                    onDisk == owned.Sha256
                        ? $"OBSOLETE: {fullPath}"
                        : $"OBSOLETE-MODIFIED: {fullPath}");
            }
        }

        return new OwnedOutputCheckResult { Mismatches = mismatches };
    }

    public static void Write(string generatorId, IReadOnlyDictionary<string, string> files)
    {
        ValidateDestinations(generatorId, files);
        var groups = GroupByDirectory(files);
        var obsolete = new List<(string Path, string Hash)>();

        foreach (var (directory, _) in groups)
        {
            var expectedNames = ExpectedRelativeNames(directory, files);
            var manifest = Directory.Exists(directory) ? ReadManifest(directory, generatorId) : null;
            if (manifest is null)
                continue;

            foreach (var owned in manifest.Files)
            {
                ValidateManifestEntry(directory, owned);
                if (expectedNames.Contains(owned.Path))
                    continue;

                var fullPath = Path.GetFullPath(Path.Combine(directory, owned.Path));
                if (!File.Exists(fullPath))
                    continue;

                var onDisk = HashBytes(File.ReadAllBytes(fullPath));
                if (onDisk != owned.Sha256)
                {
                    throw new InvalidOperationException(
                        $"Refusing to delete '{owned.Path}' owned by {generatorId}: file was modified outside the generator.");
                }

                obsolete.Add((fullPath, owned.Sha256));
            }
        }

        var staged = new List<(string Destination, string Temp)>();
        try
        {
            foreach (var (path, content) in files.OrderBy(entry => entry.Key, StringComparer.OrdinalIgnoreCase))
            {
                var directory = Path.GetDirectoryName(path)
                    ?? throw new InvalidOperationException($"Output path '{path}' has no directory.");
                Directory.CreateDirectory(directory);
                var temp = path + $".owned-tmp-{Guid.NewGuid():N}";
                File.WriteAllText(temp, content, new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
                staged.Add((path, temp));
            }
        }
        catch
        {
            DeleteTemps(staged);
            throw;
        }

        var committed = new List<string>();
        try
        {
            foreach (var (destination, temp) in staged)
            {
                File.Move(temp, destination, overwrite: true);
                committed.Add(destination);
            }
        }
        catch (Exception exception)
        {
            DeleteTemps(staged);
            throw new InvalidOperationException(
                $"Partial write failure after updating {committed.Count} file(s): {exception.Message}",
                exception);
        }

        foreach (var (path, _) in obsolete)
            File.Delete(path);

        foreach (var (directory, directoryFiles) in groups)
        {
            Directory.CreateDirectory(directory);
            var manifest = new OwnedOutputManifest
            {
                Generator = generatorId,
                Files = directoryFiles
                    .Select(entry => new OwnedOutputFile
                    {
                        Path = Path.GetFileName(entry.Key),
                        Sha256 = HashContent(entry.Value),
                    })
                    .OrderBy(file => file.Path, StringComparer.OrdinalIgnoreCase)
                    .ToList(),
            };
            var manifestPath = Path.Combine(directory, ManifestFileName(generatorId));
            var json = JsonSerializer.Serialize(manifest, JsonOptions).Replace("\r\n", "\n", StringComparison.Ordinal) + "\n";
            File.WriteAllText(manifestPath, json, new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
        }
    }

    private static void ValidateDestinations(string generatorId, IReadOnlyDictionary<string, string> files)
    {
        if (string.IsNullOrWhiteSpace(generatorId))
            throw new InvalidOperationException("Generator id must not be empty.");
        if (files.Count == 0)
            throw new InvalidOperationException("Generation produced no outputs.");

        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var path in files.Keys)
        {
            if (string.IsNullOrWhiteSpace(path))
                throw new InvalidOperationException("Generated output path must not be empty.");
            var full = Path.GetFullPath(path);
            if (!seen.Add(full))
                throw new InvalidOperationException($"Duplicate generated output '{full}'.");
            var relative = Path.GetFileName(full);
            if (!IsSafeRelativePath(relative))
                throw new InvalidOperationException($"Generated output '{path}' is not a safe file name.");
            if (string.Equals(relative, ManifestFileName(generatorId), StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException($"Generator '{generatorId}' cannot emit its ownership manifest as content.");
        }
    }

    private static Dictionary<string, List<KeyValuePair<string, string>>> GroupByDirectory(
        IReadOnlyDictionary<string, string> files)
    {
        var groups = new Dictionary<string, List<KeyValuePair<string, string>>>(StringComparer.OrdinalIgnoreCase);
        foreach (var entry in files)
        {
            var directory = Path.GetDirectoryName(Path.GetFullPath(entry.Key))
                ?? throw new InvalidOperationException($"Output path '{entry.Key}' has no directory.");
            if (!groups.TryGetValue(directory, out var list))
            {
                list = [];
                groups[directory] = list;
            }

            list.Add(entry);
        }

        return groups;
    }

    private static HashSet<string> ExpectedRelativeNames(
        string directory,
        IReadOnlyDictionary<string, string> files)
    {
        var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var path in files.Keys)
        {
            if (string.Equals(Path.GetDirectoryName(Path.GetFullPath(path)), directory, StringComparison.OrdinalIgnoreCase))
                names.Add(Path.GetFileName(path));
        }

        return names;
    }

    private static OwnedOutputManifest? ReadManifest(string directory, string generatorId)
    {
        var path = Path.Combine(directory, ManifestFileName(generatorId));
        if (!File.Exists(path))
            return null;

        var parsed = JsonSerializer.Deserialize<OwnedOutputManifest>(File.ReadAllText(path), JsonOptions)
            ?? throw new InvalidOperationException($"Ownership manifest '{path}' deserialized to null.");
        if (!string.Equals(parsed.Generator, generatorId, StringComparison.Ordinal))
        {
            throw new InvalidOperationException(
                $"Ownership manifest '{path}' belongs to '{parsed.Generator}', not '{generatorId}'.");
        }

        parsed.Files ??= [];
        foreach (var owned in parsed.Files)
            ValidateManifestEntry(directory, owned);
        return parsed;
    }

    private static void ValidateManifestEntry(string directory, OwnedOutputFile owned)
    {
        if (!IsSafeRelativePath(owned.Path))
        {
            throw new InvalidOperationException(
                $"Ownership manifest in '{directory}' contains an unsafe path '{owned.Path}'.");
        }

        var combined = Path.GetFullPath(Path.Combine(directory, owned.Path));
        var root = Path.GetFullPath(directory).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar)
                   + Path.DirectorySeparatorChar;
        if (!combined.StartsWith(root, StringComparison.OrdinalIgnoreCase)
            && !string.Equals(Path.GetDirectoryName(combined), Path.GetFullPath(directory), StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException(
                $"Ownership manifest in '{directory}' contains a path that escapes the output root: '{owned.Path}'.");
        }
    }

    private static string HashBytes(byte[] bytes) =>
        Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();

    private static void DeleteTemps(IEnumerable<(string Destination, string Temp)> staged)
    {
        foreach (var (_, temp) in staged)
        {
            if (File.Exists(temp))
                File.Delete(temp);
        }
    }

    private sealed class OwnedOutputManifest
    {
        public string Generator { get; set; } = "";
        public List<OwnedOutputFile> Files { get; set; } = [];
    }

    private sealed class OwnedOutputFile
    {
        public string Path { get; set; } = "";
        public string Sha256 { get; set; } = "";
    }
}
