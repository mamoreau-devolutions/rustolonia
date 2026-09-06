using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Avalonia.Controls;
using Avalonia.Host.Com;
using Avalonia.UnitTests;
using Xunit;

namespace Avalonia.Host.Tests;

public class WaveU36AsyncPopulatorComTests
{
    [Fact]
    public async Task Async_populator_round_trips_through_the_ccw()
    {
        using var app = UnitTestApplication.Start(TestServices.StyledWindow);
        var factory = new AvnControlFactory();
        Assert.Equal(0, factory.CreateAutoCompleteBox(out var projected));
        Assert.NotNull(projected);

        var wrapper = Assert.IsType<AvnAutoCompleteBox>(projected);

        // A foreign CCW converts into the managed delegate: BeginPopulate launches
        // and the completion resolves the task with the variant list.
        var foreign = new ForeignPopulator();
        Assert.Equal(0, wrapper.SetAsyncPopulator(foreign));
        Assert.Equal(0, wrapper.GetAsyncPopulator(out var read));
        Assert.IsType<AvnAsyncPopulator>(read);

        var value = Assert.IsType<AutoCompleteBox>(
            typeof(AvnAutoCompleteBox)
                .GetProperty("_value", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic)!
                .GetValue(wrapper));
        var managed = value.AsyncPopulator;
        Assert.NotNull(managed);

        var items = await managed!("query", CancellationToken.None);
        var list = items.ToList();
        Assert.Single(list);
        Assert.Equal("query-result", list[0]);

        // Null clears the populator.
        Assert.Equal(0, wrapper.SetAsyncPopulator(null));
        Assert.Equal(0, wrapper.GetAsyncPopulator(out var cleared));
        Assert.Null(cleared);
    }

    private sealed class ForeignPopulator : IAvnAsyncPopulator
    {
        public int BeginPopulate(long requestId, IAvnAsyncPopulatorCompletion? completion, string? searchText)
        {
            if (completion is null)
                return -2147467261;
            var items = AvnObjectList.FromManaged(new List<object?> { $"{searchText}-result" });
            return completion.Complete(requestId, 0, items);
        }
    }
}
