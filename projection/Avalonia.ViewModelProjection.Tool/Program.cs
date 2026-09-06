using System;
using System.IO;
using Avalonia.Projection.Generator;
using Avalonia.Projection.Ir;

// `--normalize <view-model-ir>` rewrites the schema file in its canonical
// serialized form. The checked-in schema is asserted to round-trip byte for
// byte, so this is how a hand-edited schema is brought back to canonical order
// after new members are added.
if (args.Length == 2 && args[0] == "--normalize")
{
    var file = Path.GetFullPath(args[1]);
    var normalized = ViewModelIr.FromJson(File.ReadAllText(file));
    File.WriteAllText(file, normalized.ToJson() + Environment.NewLine);
    Console.WriteLine($"Normalized {file}.");
    return 0;
}

var externalRust = args.Length == 6 && args[5] == "--external-rust";
if (args.Length != 5 && !externalRust)
{
    Console.Error.WriteLine(
        "Usage: Avalonia.ViewModelProjection.Tool <view-model-ir> <adapter-output-directory> <registry-output-directory> <rust-output> <contract-output> [--external-rust]");
    Console.Error.WriteLine(
        "       Avalonia.ViewModelProjection.Tool --normalize <view-model-ir>");
    return 2;
}

var ir = ViewModelIr.FromJson(File.ReadAllText(Path.GetFullPath(args[0])));
var adapterDirectory = Path.GetFullPath(args[1]);
var registryDirectory = Path.GetFullPath(args[2]);
var rustPath = Path.GetFullPath(args[3]);
var contractPath = Path.GetFullPath(args[4]);
Directory.CreateDirectory(adapterDirectory);
Directory.CreateDirectory(registryDirectory);
Directory.CreateDirectory(Path.GetDirectoryName(rustPath)!);
Directory.CreateDirectory(Path.GetDirectoryName(contractPath)!);

foreach (var existing in Directory.EnumerateFiles(adapterDirectory, "*.g.cs"))
    File.Delete(existing);
foreach (var existing in Directory.EnumerateFiles(registryDirectory, "RustViewRegistry.g.cs"))
    File.Delete(existing);
foreach (var (name, source) in ViewModelSourceEmitter.EmitCSharp(ir))
{
    var directory = name == "RustViewRegistry.g.cs"
        ? registryDirectory
        : adapterDirectory;
    File.WriteAllText(Path.Combine(directory, name), source);
}
File.WriteAllText(rustPath, ViewModelSourceEmitter.EmitRust(ir, externalRust));
File.WriteAllText(contractPath, ViewModelSourceEmitter.EmitContract(ir));

Console.WriteLine(
    $"Generated {ir.Models.Count} view model(s) and {ir.Views.Count} view(s).");
return 0;
