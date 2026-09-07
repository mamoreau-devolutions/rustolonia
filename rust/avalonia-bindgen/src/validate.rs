use crate::error::GenerationError;
use crate::ir::{
    ProjectedAttachedProperty, ProjectedEvent, ProjectedMethod, ProjectedParameter, ProjectedType,
    ProjectionIr,
};

pub const MINIMUM_VERSION: i32 = 1;
pub const CURRENT_VERSION: i32 = 16;

const SUPPORTED_MARSHALLING_KINDS: &[&str] = &[
    "Void",
    "I32",
    "I64",
    "F32",
    "F64",
    "Bool",
    "NullableBool",
    "StringUtf16",
    "ComInterface",
    "ComCollection",
    "Thickness",
    "CornerRadius",
    "Size",
    "Point",
    "Rect",
    "Color",
    "Brush",
    "Vector",
    "CharUtf16",
    "Command",
    "Variant",
    "TimeSpanI64",
    "DateTimeI64",
    "PixelPointI32",
    "DataTemplate",
    "ItemFilter",
    "TextFilter",
    "Notification",
    "ItemSelector",
    "TextSelector",
    "PopupPlacement",
    "AsyncPopulator",
    "DialogCompletion",
];

const SUPPORTED_DIRECTIONS: &[&str] = &["In", "Out", "InOut"];
const SUPPORTED_TYPE_KINDS: &[&str] = &["Interface", "Class", "Struct", "Enum"];
const SUPPORTED_PAYLOAD_KINDS: &[&str] = &["None", "Fields", "Args"];

pub fn validate(ir: &ProjectionIr) -> Result<(), GenerationError> {
    if ir.version < MINIMUM_VERSION || ir.version > CURRENT_VERSION {
        return Err(GenerationError::invalid(format!(
            "Unsupported projection IR version {} (supported {MINIMUM_VERSION}..={CURRENT_VERSION}).",
            ir.version
        )));
    }

    let mut types_by_full_name = std::collections::HashMap::new();
    for ty in &ir.types {
        if ty.full_name.trim().is_empty() {
            return Err(GenerationError::invalid(
                "Projected type is missing fullName.",
            ));
        }
        if types_by_full_name
            .insert(ty.full_name.as_str(), ty)
            .is_some()
        {
            return Err(GenerationError::invalid(format!(
                "Duplicate projected type '{}'.",
                ty.full_name
            )));
        }
        validate_named(
            &ty.kind,
            SUPPORTED_TYPE_KINDS,
            &format!(
                "Unknown type kind '{}' at type '{}'.",
                ty.kind, ty.full_name
            ),
        )?;
        for method in &ty.methods {
            validate_method(ty, method)?;
        }
        for property in &ty.properties {
            let location = format!("type '{}' property '{}'", ty.full_name, property.name);
            validate_kind(&property.kind, &location)?;
            if let Some(element_kind) = &property.element_kind {
                validate_kind(element_kind, &format!("{location} element"))?;
            }
        }
        for event in &ty.events {
            validate_event(ty, event)?;
        }
    }

    for attached in &ir.attached_properties {
        validate_attached(attached)?;
    }

    for ty in &ir.types {
        validate_inheritance(ty, &types_by_full_name)?;
    }

    Ok(())
}

fn validate_method(ty: &ProjectedType, method: &ProjectedMethod) -> Result<(), GenerationError> {
    let location = format!("type '{}' method '{}'", ty.full_name, method.name);
    validate_kind(&method.return_kind, &location)?;
    for parameter in &method.parameters {
        validate_parameter(parameter, &location)?;
    }
    Ok(())
}

fn validate_event(ty: &ProjectedType, event: &ProjectedEvent) -> Result<(), GenerationError> {
    let location = format!("type '{}' event '{}'", ty.full_name, event.name);
    validate_named(
        &event.payload_kind,
        SUPPORTED_PAYLOAD_KINDS,
        &format!(
            "Unknown event payload kind '{}' at {location}.",
            event.payload_kind
        ),
    )?;
    for parameter in &event.parameters {
        validate_parameter(parameter, &location)?;
    }
    Ok(())
}

fn validate_attached(attached: &ProjectedAttachedProperty) -> Result<(), GenerationError> {
    validate_kind(
        &attached.kind,
        &format!(
            "attached property '{}.{}'",
            attached.owner_name, attached.name
        ),
    )
}

fn validate_parameter(
    parameter: &ProjectedParameter,
    owner_location: &str,
) -> Result<(), GenerationError> {
    let location = format!("{owner_location} parameter '{}'", parameter.name);
    validate_kind(&parameter.kind, &location)?;
    validate_named(
        &parameter.direction,
        SUPPORTED_DIRECTIONS,
        &format!(
            "Unknown parameter direction '{}' at {location}.",
            parameter.direction
        ),
    )
}

fn validate_kind(kind: &str, location: &str) -> Result<(), GenerationError> {
    validate_named(
        kind,
        SUPPORTED_MARSHALLING_KINDS,
        &format!("Unknown marshalling kind '{kind}' at {location}."),
    )
}

fn validate_named(value: &str, allowed: &[&str], message: &str) -> Result<(), GenerationError> {
    if allowed.contains(&value) {
        Ok(())
    } else {
        Err(GenerationError::invalid(message))
    }
}

fn validate_inheritance(
    ty: &ProjectedType,
    types_by_full_name: &std::collections::HashMap<&str, &ProjectedType>,
) -> Result<(), GenerationError> {
    let Some(base) = ty.base_full_name.as_deref().filter(|name| !name.is_empty()) else {
        return Ok(());
    };

    if base == ty.full_name {
        return Err(GenerationError::invalid(format!(
            "Type '{}' has a self base reference.",
            ty.full_name
        )));
    }

    let mut seen = vec![ty.full_name.as_str()];
    let mut current = ty;
    while let Some(base_name) = current
        .base_full_name
        .as_deref()
        .filter(|name| !name.is_empty())
    {
        let Some(base_type) = types_by_full_name.get(base_name) else {
            return Err(GenerationError::invalid(format!(
                "Type '{}' references missing base '{base_name}'.",
                ty.full_name
            )));
        };
        if seen.contains(&base_type.full_name.as_str()) {
            seen.push(base_type.full_name.as_str());
            return Err(GenerationError::invalid(format!(
                "Inheritance cycle: {}.",
                seen.join(" -> ")
            )));
        }
        seen.push(base_type.full_name.as_str());
        current = base_type;
    }

    Ok(())
}
