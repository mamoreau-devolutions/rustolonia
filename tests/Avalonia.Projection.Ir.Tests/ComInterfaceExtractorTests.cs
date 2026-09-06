using System;
using System.Linq;
using Avalonia.Host.Com;
using Avalonia.Projection.Ir;
using Xunit;

namespace Avalonia.Projection.Ir.Tests;

public class ComInterfaceExtractorTests
{
    [Fact]
    public void Extracts_fixture_com_interfaces_from_host()
    {
        var ir = ComInterfaceExtractor.Extract(typeof(IAvnEcho).Assembly, new ProjectionPolicy
        {
            IncludeNamespaces = ["Avalonia.Host.Com"],
        });

        Assert.Equal("Avalonia.Host", ir.SourceAssembly);
        Assert.Contains(ir.Types, t => t.Name == "IAvnEcho");
        Assert.Contains(ir.Types, t => t.Name == "IAvnActivationFactory");

        var echo = ir.Types.Single(t => t.Name == "IAvnEcho");
        Assert.Equal("6B2E8F10-4C91-4E3A-9A77-1F0C2B3A4D11", echo.Iid);
        Assert.Equal(3, echo.Methods.Count);

        var ping = echo.Methods.Single(m => m.Name == "Ping");
        Assert.True(ping.PreserveSig);
        Assert.Equal(MarshallingKind.I32, ping.ReturnKind);
        Assert.Equal(MarshallingKind.I32, ping.Parameters[0].Kind);
        Assert.Equal(ParameterDirection.In, ping.Parameters[0].Direction);
        Assert.Equal(ParameterDirection.Out, ping.Parameters[1].Direction);

        var echoString = echo.Methods.Single(m => m.Name == "EchoString");
        Assert.Equal(MarshallingKind.StringUtf16, echoString.Parameters[0].Kind);
        Assert.Equal(MarshallingKind.StringUtf16, echoString.Parameters[1].Kind);
        Assert.Equal(ParameterDirection.Out, echoString.Parameters[1].Direction);

        var factory = ir.Types.Single(t => t.Name == "IAvnActivationFactory");
        var create = factory.Methods.Single(m => m.Name == "CreateEcho");
        Assert.Equal(MarshallingKind.ComInterface, create.Parameters[0].Kind);
        Assert.Equal(typeof(IAvnEcho).FullName, create.Parameters[0].InterfaceName);
        Assert.Equal(ParameterDirection.Out, create.Parameters[0].Direction);
    }

    [Fact]
    public void Json_roundtrips_fixture_ir()
    {
        var ir = ComInterfaceExtractor.Extract(typeof(IAvnEcho).Assembly, new ProjectionPolicy
        {
            IncludeNamespaces = ["Avalonia.Host.Com"],
        });
        var json = ir.ToJson();
        var again = ProjectionIr.FromJson(json);
        Assert.Equal(ir.Types.Count, again.Types.Count);
        Assert.Equal(ir.Types.Select(t => t.FullName), again.Types.Select(t => t.FullName));
        Assert.Contains("\"iid\":", json, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("IAvnEcho", json);
    }

    [Fact]
    public void Policy_excludes_types()
    {
        var ir = ComInterfaceExtractor.Extract(typeof(IAvnEcho).Assembly, new ProjectionPolicy
        {
            IncludeNamespaces = ["Avalonia.Host.Com"],
            ExcludeTypeNames = [typeof(IAvnActivationFactory).FullName!],
        });
        Assert.DoesNotContain(ir.Types, t => t.Name == "IAvnActivationFactory");
        Assert.Contains(ir.Types, t => t.Name == "IAvnEcho");
    }
}
