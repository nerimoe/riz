use anyhow::{Context, Result, bail};
use base64::{Engine, engine::general_purpose::STANDARD};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    fs,
    io::Write,
    path::{Path, PathBuf},
    process::Command,
};
use tempfile::NamedTempFile;

pub const MAX_EDIT_BYTES: u64 = 2 * 1024 * 1024;

pub fn list(path: &Path, offset: usize, limit: usize) -> Result<Value> {
    let path = path.canonicalize()?;
    if !path.is_dir() {
        bail!("not a directory")
    }
    let mut entries=fs::read_dir(&path)?.filter_map(Result::ok).map(|e|{
        let p=e.path(); let m=e.metadata().ok(); json!({"name":e.file_name().to_string_lossy(),"path":p,"isDirectory":m.as_ref().is_some_and(|v|v.is_dir()),"isSymlink":e.file_type().ok().is_some_and(|v|v.is_symlink()),"size":m.as_ref().map(|v|v.len()),"modifiedAt":m.and_then(|v|v.modified().ok()).and_then(|v|v.duration_since(std::time::UNIX_EPOCH).ok()).map(|v|v.as_secs())})
    }).collect::<Vec<_>>();
    entries.sort_by(|a, b| {
        b["isDirectory"]
            .as_bool()
            .cmp(&a["isDirectory"].as_bool())
            .then_with(|| a["name"].as_str().cmp(&b["name"].as_str()))
    });
    let total = entries.len();
    let entries = entries
        .into_iter()
        .skip(offset)
        .take(limit.clamp(1, 500))
        .collect::<Vec<_>>();
    Ok(json!({"path":path,"entries":entries,"offset":offset,"total":total}))
}

pub fn read(path: &Path) -> Result<Value> {
    let canonical = path.canonicalize()?;
    let metadata = fs::metadata(&canonical)?;
    let bytes = fs::read(&canonical)?;
    let mime = mime_guess::from_path(&canonical)
        .first_or_octet_stream()
        .to_string();
    let revision = revision(&bytes);
    if metadata.len() > MAX_EDIT_BYTES || std::str::from_utf8(&bytes).is_err() {
        Ok(
            json!({"path":canonical,"mimeType":mime,"size":metadata.len(),"revision":revision,"readOnly":true,"base64":if mime.starts_with("image/"){Some(STANDARD.encode(bytes))}else{None}}),
        )
    } else {
        Ok(
            json!({"path":canonical,"mimeType":mime,"size":metadata.len(),"revision":revision,"readOnly":false,"text":String::from_utf8(bytes)?}),
        )
    }
}

pub fn write(path: &Path, text: &str, expected: Option<&str>) -> Result<Value> {
    if text.len() as u64 > MAX_EDIT_BYTES {
        bail!("text exceeds 2 MiB editor limit")
    }
    if path.exists() {
        let old = fs::read(path)?;
        if expected.is_some_and(|e| e != revision(&old)) {
            bail!("revision conflict")
        }
    }
    let parent = path.parent().context("path has no parent")?;
    fs::create_dir_all(parent)?;
    let mut temp = NamedTempFile::new_in(parent)?;
    temp.write_all(text.as_bytes())?;
    temp.flush()?;
    temp.persist(path).map_err(|e| e.error)?;
    Ok(json!({"path":path,"revision":revision(text.as_bytes()),"size":text.len()}))
}

pub fn mkdir(path: &Path) -> Result<()> {
    fs::create_dir_all(path)?;
    Ok(())
}
pub fn delete(path: &Path) -> Result<()> {
    let m = fs::symlink_metadata(path)?;
    if m.is_dir() {
        fs::remove_dir_all(path)?
    } else {
        fs::remove_file(path)?
    }
    Ok(())
}
pub fn rename(from: &Path, to: &Path) -> Result<()> {
    fs::rename(from, to)?;
    Ok(())
}

pub fn search(root: &Path, query: &str, limit: usize) -> Result<Value> {
    let out = Command::new("rg")
        .args([
            "--json",
            "--line-number",
            "--hidden",
            "--glob",
            "!.git",
            query,
        ])
        .current_dir(root)
        .output()?;
    let mut items = Vec::new();
    for line in String::from_utf8_lossy(&out.stdout).lines() {
        if items.len() >= limit.clamp(1, 500) {
            break;
        }
        let Ok(v) = serde_json::from_str::<Value>(line) else {
            continue;
        };
        if v["type"] == "match" {
            items.push(v["data"].clone())
        }
    }
    Ok(json!({"query":query,"items":items,"truncated":items.len()>=limit}))
}

pub fn git_diff(root: &Path, path: Option<&Path>) -> Result<Value> {
    let mut c = Command::new("git");
    c.args(["diff", "--no-ext-diff", "--"]);
    if let Some(p) = path {
        c.arg(p);
    }
    let out = c.current_dir(root).output()?;
    if !out.status.success() {
        bail!("git diff failed: {}", String::from_utf8_lossy(&out.stderr))
    }
    Ok(json!({"diff":String::from_utf8_lossy(&out.stdout)}))
}

pub fn upload(path: &Path, data: &[u8]) -> Result<Value> {
    let parent = path.parent().context("path has no parent")?;
    fs::create_dir_all(parent)?;
    let mut t = NamedTempFile::new_in(parent)?;
    t.write_all(data)?;
    t.persist(path).map_err(|e| e.error)?;
    Ok(json!({"path":path,"size":data.len(),"revision":revision(data)}))
}

pub fn download(path: &Path, max_bytes: usize) -> Result<(Value, Vec<u8>)> {
    let canonical = path.canonicalize()?;
    if !canonical.is_file() {
        bail!("not a file")
    }
    let bytes = fs::read(&canonical)?;
    if bytes.len() > max_bytes {
        bail!("file exceeds download limit")
    }
    let mime = mime_guess::from_path(&canonical)
        .first_or_octet_stream()
        .to_string();
    let metadata = json!({
        "path": canonical,
        "name": canonical.file_name().map(|v| v.to_string_lossy()),
        "mimeType": mime,
        "size": bytes.len(),
        "revision": revision(&bytes),
    });
    Ok((metadata, bytes))
}

pub fn revision(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}
pub fn path_from(value: &Value, key: &str) -> Result<PathBuf> {
    value
        .get(key)
        .and_then(Value::as_str)
        .map(PathBuf::from)
        .with_context(|| format!("missing {key}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn detects_write_conflict() {
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("a.txt");
        write(&p, "one", None).unwrap();
        assert!(write(&p, "two", Some("wrong")).is_err());
    }

    #[test]
    fn downloads_exact_file_bytes_and_metadata() {
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("sample.bin");
        let bytes = [0_u8, 1, 2, 255];
        upload(&p, &bytes).unwrap();
        let (metadata, downloaded) = download(&p, 16).unwrap();
        assert_eq!(downloaded, bytes);
        assert_eq!(metadata["name"], "sample.bin");
        assert_eq!(metadata["size"], 4);
        assert!(download(&p, 3).is_err());
    }
}
