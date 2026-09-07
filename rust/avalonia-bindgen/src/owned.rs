use crate::error::GenerationError;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};

pub const BINDGEN_GENERATOR_ID: &str = "avalonia-bindgen";

#[derive(Debug, Default)]
pub struct CheckReport {
    pub mismatches: Vec<String>,
}

impl CheckReport {
    pub fn success(&self) -> bool {
        self.mismatches.is_empty()
    }
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Manifest {
    generator: String,
    files: Vec<ManifestFile>,
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ManifestFile {
    path: String,
    sha256: String,
}

pub fn manifest_file_name(generator_id: &str) -> String {
    format!(".{generator_id}.owned.json")
}

pub fn hash_content(content: &str) -> String {
    hex_encode(&Sha256::digest(content.as_bytes()))
}

pub fn is_safe_relative_path(path: &str) -> bool {
    if path.trim().is_empty() {
        return false;
    }
    let normalized = path.replace('\\', "/");
    if Path::new(&normalized).is_absolute()
        || normalized.starts_with('/')
        || normalized.contains(':')
    {
        return false;
    }
    let parts: Vec<_> = normalized.split('/').collect();
    !parts.is_empty()
        && parts
            .iter()
            .all(|part| !part.is_empty() && *part != "." && *part != "..")
}

pub fn check_outputs(
    generator_id: &str,
    files: &[(PathBuf, String)],
) -> Result<CheckReport, GenerationError> {
    let map = destination_map(generator_id, files)?;
    let mut report = CheckReport::default();
    for (path, expected) in &map {
        if !path.exists() {
            report
                .mismatches
                .push(format!("MISSING: {}", path.display()));
            continue;
        }
        let actual = fs::read_to_string(path)?.replace("\r\n", "\n");
        if actual != *expected {
            report
                .mismatches
                .push(format!("DIFFERENT: {}", path.display()));
        }
    }

    for directory in group_directories(&map).into_keys() {
        if !directory.is_dir() {
            continue;
        }
        let Some(manifest) = read_manifest(&directory, generator_id)? else {
            continue;
        };
        let expected = expected_names(&directory, &map);
        for owned in manifest.files {
            validate_manifest_entry(&directory, &owned.path)?;
            if expected.contains(&owned.path) {
                continue;
            }
            let full = directory.join(&owned.path);
            if !full.exists() {
                report
                    .mismatches
                    .push(format!("OBSOLETE: {}", full.display()));
                continue;
            }
            let on_disk = hex_encode(&Sha256::digest(fs::read(&full)?));
            report.mismatches.push(if on_disk == owned.sha256 {
                format!("OBSOLETE: {}", full.display())
            } else {
                format!("OBSOLETE-MODIFIED: {}", full.display())
            });
        }
    }
    Ok(report)
}

pub fn write_outputs(
    generator_id: &str,
    files: &[(PathBuf, String)],
) -> Result<(), GenerationError> {
    let map = destination_map(generator_id, files)?;
    let groups = group_directories(&map);
    let mut obsolete = Vec::new();
    for directory in groups.keys() {
        let expected = expected_names(directory, &map);
        let Some(manifest) = read_manifest(directory, generator_id)? else {
            continue;
        };
        for owned in manifest.files {
            validate_manifest_entry(directory, &owned.path)?;
            if expected.contains(&owned.path) {
                continue;
            }
            let full = directory.join(&owned.path);
            if !full.exists() {
                continue;
            }
            let on_disk = hex_encode(&Sha256::digest(fs::read(&full)?));
            if on_disk != owned.sha256 {
                return Err(GenerationError::invalid(format!(
                    "Refusing to delete '{}' owned by {generator_id}: file was modified outside the generator.",
                    owned.path
                )));
            }
            obsolete.push(full);
        }
    }

    let mut staged = Vec::new();
    let stage_result: Result<(), GenerationError> = (|| {
        for (path, content) in &map {
            let parent = path.parent().unwrap_or_else(|| Path::new("."));
            fs::create_dir_all(parent)?;
            let unique = parent.join(format!(
                ".avalonia-owned-tmp-{}-{}",
                std::process::id(),
                staged.len()
            ));
            fs::write(&unique, content.as_bytes())?;
            staged.push((path.clone(), unique));
        }
        Ok(())
    })();
    if let Err(error) = stage_result {
        delete_temps(&staged);
        return Err(error);
    }

    let mut committed = Vec::new();
    for (destination, temp) in &staged {
        if let Err(error) = fs::rename(temp, destination).or_else(|_| {
            fs::copy(temp, destination).map(|_| {
                let _ = fs::remove_file(temp);
            })
        }) {
            delete_temps(&staged);
            return Err(GenerationError::invalid(format!(
                "Partial write failure after updating {} file(s): {error}",
                committed.len()
            )));
        }
        committed.push(destination.clone());
    }

    for path in obsolete {
        fs::remove_file(path)?;
    }

    for (directory, directory_files) in groups {
        fs::create_dir_all(&directory)?;
        let mut files: Vec<_> = directory_files
            .into_iter()
            .map(|(path, content)| ManifestFile {
                path: path
                    .file_name()
                    .and_then(|name| name.to_str())
                    .unwrap_or_default()
                    .to_string(),
                sha256: hash_content(&content),
            })
            .collect();
        files.sort_by(|left, right| {
            left.path
                .to_ascii_lowercase()
                .cmp(&right.path.to_ascii_lowercase())
        });
        let manifest = Manifest {
            generator: generator_id.to_string(),
            files,
        };
        let mut json = serde_json::to_string_pretty(&manifest)?;
        json.push('\n');
        fs::write(
            directory.join(manifest_file_name(generator_id)),
            json.replace("\r\n", "\n"),
        )?;
    }
    Ok(())
}

fn destination_map(
    generator_id: &str,
    files: &[(PathBuf, String)],
) -> Result<BTreeMap<PathBuf, String>, GenerationError> {
    if generator_id.trim().is_empty() {
        return Err(GenerationError::invalid("Generator id must not be empty."));
    }
    if files.is_empty() {
        return Err(GenerationError::invalid("Generation produced no outputs."));
    }
    let mut map = BTreeMap::new();
    for (path, content) in files {
        let full = if path.is_absolute() {
            path.clone()
        } else {
            std::env::current_dir()?.join(path)
        };
        let name = full
            .file_name()
            .and_then(|name| name.to_str())
            .ok_or_else(|| GenerationError::invalid("Generated output path must not be empty."))?;
        if !is_safe_relative_path(name) {
            return Err(GenerationError::invalid(format!(
                "Generated output '{}' is not a safe file name.",
                full.display()
            )));
        }
        if name.eq_ignore_ascii_case(&manifest_file_name(generator_id)) {
            return Err(GenerationError::invalid(format!(
                "Generator '{generator_id}' cannot emit its ownership manifest as content."
            )));
        }
        if map.insert(full.clone(), content.clone()).is_some() {
            return Err(GenerationError::invalid(format!(
                "Duplicate generated output '{}'.",
                full.display()
            )));
        }
    }
    Ok(map)
}

fn group_directories(
    files: &BTreeMap<PathBuf, String>,
) -> HashMap<PathBuf, Vec<(PathBuf, String)>> {
    let mut groups = HashMap::new();
    for (path, content) in files {
        let directory = path
            .parent()
            .unwrap_or_else(|| Path::new("."))
            .to_path_buf();
        groups
            .entry(directory)
            .or_insert_with(Vec::new)
            .push((path.clone(), content.clone()));
    }
    groups
}

fn expected_names(directory: &Path, files: &BTreeMap<PathBuf, String>) -> HashSet<String> {
    files
        .keys()
        .filter(|path| path.parent() == Some(directory))
        .filter_map(|path| path.file_name()?.to_str().map(str::to_string))
        .collect()
}

fn read_manifest(
    directory: &Path,
    generator_id: &str,
) -> Result<Option<Manifest>, GenerationError> {
    let path = directory.join(manifest_file_name(generator_id));
    if !path.exists() {
        return Ok(None);
    }
    let parsed: Manifest = serde_json::from_str(&fs::read_to_string(path)?)?;
    if parsed.generator != generator_id {
        return Err(GenerationError::invalid(format!(
            "Ownership manifest belongs to '{}', not '{generator_id}'.",
            parsed.generator
        )));
    }
    for owned in &parsed.files {
        validate_manifest_entry(directory, &owned.path)?;
    }
    Ok(Some(parsed))
}

fn validate_manifest_entry(directory: &Path, relative: &str) -> Result<(), GenerationError> {
    if !is_safe_relative_path(relative) {
        return Err(GenerationError::invalid(format!(
            "Ownership manifest in '{}' contains an unsafe path '{relative}'.",
            directory.display()
        )));
    }
    let combined = directory.join(relative);
    let canonical_parent = directory;
    if combined.parent() != Some(canonical_parent) && combined.parent() != Some(directory) {
        let escaped = combined
            .components()
            .any(|component| matches!(component, std::path::Component::ParentDir));
        if escaped {
            return Err(GenerationError::invalid(format!(
                "Ownership manifest in '{}' contains a path that escapes the output root: '{relative}'.",
                directory.display()
            )));
        }
    }
    Ok(())
}

fn delete_temps(staged: &[(PathBuf, PathBuf)]) {
    for (_, temp) in staged {
        let _ = fs::remove_file(temp);
    }
}

fn hex_encode(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn scratch() -> PathBuf {
        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let path = std::env::temp_dir().join(format!("rustolonia-bindgen-owned-{stamp}"));
        fs::create_dir_all(&path).unwrap();
        path
    }

    fn cleanup(path: &Path) {
        let _ = fs::remove_dir_all(path);
    }

    #[test]
    fn check_mode_does_not_create_missing_directories() {
        let root = scratch();
        let missing_root = root.join("absent");
        let path = missing_root.join("generated.rs");
        let report = check_outputs(
            BINDGEN_GENERATOR_ID,
            &[(path.clone(), "pub struct A;\n".into())],
        )
        .unwrap();
        assert!(!report.success());
        assert!(report
            .mismatches
            .iter()
            .any(|item| item.contains("MISSING:")));
        assert!(!missing_root.exists());
        cleanup(&root);
    }

    #[test]
    fn write_renders_all_outputs_before_replacing_and_keeps_unrelated_files() {
        let root = scratch();
        let sys = root.join("sys").join("generated.rs");
        let safe = root.join("safe").join("generated.rs");
        let unrelated = root.join("sys").join("hand.rs");
        fs::create_dir_all(sys.parent().unwrap()).unwrap();
        fs::write(&unrelated, "leave me\n").unwrap();
        write_outputs(
            BINDGEN_GENERATOR_ID,
            &[
                (sys.clone(), "sys-one\n".into()),
                (safe.clone(), "safe-one\n".into()),
            ],
        )
        .unwrap();
        write_outputs(
            BINDGEN_GENERATOR_ID,
            &[
                (sys.clone(), "sys-two\n".into()),
                (safe.clone(), "safe-two\n".into()),
            ],
        )
        .unwrap();
        assert_eq!(fs::read_to_string(&sys).unwrap(), "sys-two\n");
        assert_eq!(fs::read_to_string(&safe).unwrap(), "safe-two\n");
        assert_eq!(fs::read_to_string(&unrelated).unwrap(), "leave me\n");
        cleanup(&root);
    }

    #[test]
    fn write_prunes_only_owned_obsolete_files() {
        let root = scratch();
        let kept = root.join("generated.rs");
        let stale = root.join("old.rs");
        write_outputs(
            BINDGEN_GENERATOR_ID,
            &[
                (kept.clone(), "keep\n".into()),
                (stale.clone(), "stale\n".into()),
            ],
        )
        .unwrap();
        write_outputs(
            BINDGEN_GENERATOR_ID,
            &[(kept.clone(), "keep-updated\n".into())],
        )
        .unwrap();
        assert_eq!(fs::read_to_string(&kept).unwrap(), "keep-updated\n");
        assert!(!stale.exists());
        cleanup(&root);
    }

    #[test]
    fn write_refuses_modified_obsolete_file_and_leaves_bytes() {
        let root = scratch();
        let kept = root.join("generated.rs");
        let stale = root.join("old.rs");
        write_outputs(
            BINDGEN_GENERATOR_ID,
            &[
                (kept.clone(), "keep\n".into()),
                (stale.clone(), "stale\n".into()),
            ],
        )
        .unwrap();
        fs::write(&stale, "edited\n").unwrap();
        let kept_before = fs::read(&kept).unwrap();
        let stale_before = fs::read(&stale).unwrap();
        let error = write_outputs(
            BINDGEN_GENERATOR_ID,
            &[(kept.clone(), "keep-updated\n".into())],
        )
        .unwrap_err()
        .to_string();
        assert!(error.contains("modified outside the generator"));
        assert_eq!(fs::read(&kept).unwrap(), kept_before);
        assert_eq!(fs::read(&stale).unwrap(), stale_before);
        cleanup(&root);
    }

    #[test]
    fn malformed_ownership_paths_are_rejected() {
        let root = scratch();
        let owned = root.join("generated.rs");
        fs::write(&owned, "original\n").unwrap();
        fs::write(
            root.join(manifest_file_name(BINDGEN_GENERATOR_ID)),
            r#"{
  "generator": "avalonia-bindgen",
  "files": [{ "path": "../escape.rs", "sha256": "00" }]
}
"#,
        )
        .unwrap();
        let before = fs::read(&owned).unwrap();
        let error = write_outputs(BINDGEN_GENERATOR_ID, &[(owned.clone(), "updated\n".into())])
            .unwrap_err()
            .to_string();
        assert!(error.contains("unsafe path"));
        assert_eq!(fs::read(&owned).unwrap(), before);
        cleanup(&root);
    }

    #[test]
    fn check_reports_changed_missing_and_obsolete() {
        let root = scratch();
        let changed = root.join("changed.rs");
        let missing = root.join("missing.rs");
        let obsolete = root.join("obsolete.rs");
        write_outputs(
            BINDGEN_GENERATOR_ID,
            &[
                (changed.clone(), "old\n".into()),
                (obsolete.clone(), "stale\n".into()),
            ],
        )
        .unwrap();
        let report = check_outputs(
            BINDGEN_GENERATOR_ID,
            &[
                (changed.clone(), "new\n".into()),
                (missing.clone(), "fresh\n".into()),
            ],
        )
        .unwrap();
        assert!(report
            .mismatches
            .iter()
            .any(|item| item.starts_with("DIFFERENT:")));
        assert!(report
            .mismatches
            .iter()
            .any(|item| item.starts_with("MISSING:")));
        assert!(report
            .mismatches
            .iter()
            .any(|item| item.starts_with("OBSOLETE:")));
        assert!(!missing.exists());
        cleanup(&root);
    }
}
