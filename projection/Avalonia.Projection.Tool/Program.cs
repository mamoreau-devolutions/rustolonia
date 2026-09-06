using System;
using System.IO;
using System.Linq;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Projection.Generator;
using Avalonia.Projection.Ir;

if (args.Length is not (2 or 3))
{
    Console.Error.WriteLine(
        "Usage: Avalonia.Projection.Tool <ir-output> <csharp-output-directory> [native-header-output]");
    return 2;
}

var sourceTypes = typeof(AvaloniaObject).Assembly.GetExportedTypes()
    .Concat(typeof(Control).Assembly.GetExportedTypes());
var ir = ClrTypeExtractor.Extract(sourceTypes, AvaloniaProjectionProfiles.ObjectModelKernel);
var irPath = Path.GetFullPath(args[0]);
var csharpDirectory = Path.GetFullPath(args[1]);

Directory.CreateDirectory(Path.GetDirectoryName(irPath)!);
Directory.CreateDirectory(csharpDirectory);
File.WriteAllText(irPath, ir.ToJson() + Environment.NewLine);

foreach (var existing in Directory.EnumerateFiles(csharpDirectory, "*.g.cs"))
    File.Delete(existing);
foreach (var (name, source) in ComSourceEmitter.Emit(ir))
    File.WriteAllText(Path.Combine(csharpDirectory, name), source);

if (args.Length == 3)
{
    var headerPath = Path.GetFullPath(args[2]);
    Directory.CreateDirectory(Path.GetDirectoryName(headerPath)!);
    File.WriteAllText(headerPath, NativeHeaderEmitter.Emit(ir));
}

var reportPath = Path.ChangeExtension(irPath, ".gaps.txt");
File.WriteAllLines(
    reportPath,
    ir.Skipped.Select(s => $"{s.Owner}.{s.Member}: {s.Reason}"));

Console.WriteLine($"Generated {ir.Types.Count} projected types and {ir.Skipped.Count} gap entries.");
return 0;
