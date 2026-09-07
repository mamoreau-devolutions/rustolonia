namespace Avalonia.Projection.Ir;

public sealed partial class ProjectionIr
{
    public void Validate()
    {
        if (Version < MinimumVersion || Version > CurrentVersion)
        {
            throw new InvalidOperationException(
                $"Unsupported projection IR version {Version} (supported {MinimumVersion}..={CurrentVersion}).");
        }

        var typesByFullName = new Dictionary<string, ProjectedType>(StringComparer.Ordinal);
        foreach (var type in Types)
        {
            if (string.IsNullOrWhiteSpace(type.FullName))
                throw new InvalidOperationException("Projected type is missing fullName.");
            if (!typesByFullName.TryAdd(type.FullName, type))
                throw new InvalidOperationException($"Duplicate projected type '{type.FullName}'.");
            if (!Enum.IsDefined(type.Kind))
                throw new InvalidOperationException($"Unknown type kind '{type.Kind}' at type '{type.FullName}'.");

            foreach (var method in type.Methods)
            {
                var methodLocation = $"type '{type.FullName}' method '{method.Name}'";
                ValidateKind(method.ReturnKind, methodLocation);
                foreach (var parameter in method.Parameters)
                    ValidateParameter(parameter, methodLocation);
            }

            foreach (var property in type.Properties)
            {
                var propertyLocation = $"type '{type.FullName}' property '{property.Name}'";
                ValidateKind(property.Kind, propertyLocation);
                if (property.ElementKind is { } elementKind)
                    ValidateKind(elementKind, propertyLocation + " element");
            }

            foreach (var @event in type.Events)
            {
                var eventLocation = $"type '{type.FullName}' event '{@event.Name}'";
                if (!Enum.IsDefined(@event.PayloadKind))
                {
                    throw new InvalidOperationException(
                        $"Unknown event payload kind '{@event.PayloadKind}' at {eventLocation}.");
                }

                foreach (var parameter in @event.Parameters)
                    ValidateParameter(parameter, eventLocation);
            }
        }

        foreach (var attached in AttachedProperties)
        {
            ValidateKind(
                attached.Kind,
                $"attached property '{attached.OwnerName}.{attached.Name}'");
        }

        foreach (var type in Types)
            ValidateInheritance(type, typesByFullName);
    }

    private static void ValidateParameter(ProjectedParameter parameter, string ownerLocation)
    {
        var location = $"{ownerLocation} parameter '{parameter.Name}'";
        ValidateKind(parameter.Kind, location);
        if (!Enum.IsDefined(parameter.Direction))
        {
            throw new InvalidOperationException(
                $"Unknown parameter direction '{parameter.Direction}' at {location}.");
        }
    }

    private static void ValidateKind(MarshallingKind kind, string location)
    {
        if (!Enum.IsDefined(kind) || kind == MarshallingKind.Unsupported)
        {
            throw new InvalidOperationException(
                $"Unknown marshalling kind '{kind}' at {location}.");
        }
    }

    private static void ValidateInheritance(
        ProjectedType type,
        IReadOnlyDictionary<string, ProjectedType> typesByFullName)
    {
        if (string.IsNullOrEmpty(type.BaseFullName))
            return;

        if (string.Equals(type.BaseFullName, type.FullName, StringComparison.Ordinal))
            throw new InvalidOperationException($"Type '{type.FullName}' has a self base reference.");

        var seen = new List<string> { type.FullName };
        var current = type;
        while (!string.IsNullOrEmpty(current.BaseFullName))
        {
            if (!typesByFullName.TryGetValue(current.BaseFullName, out var baseType))
            {
                throw new InvalidOperationException(
                    $"Type '{type.FullName}' references missing base '{current.BaseFullName}'.");
            }

            if (seen.Contains(baseType.FullName, StringComparer.Ordinal))
            {
                seen.Add(baseType.FullName);
                throw new InvalidOperationException($"Inheritance cycle: {string.Join(" -> ", seen)}.");
            }

            seen.Add(baseType.FullName);
            current = baseType;
        }
    }
}
