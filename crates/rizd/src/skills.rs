use anyhow::{Context, Result, bail};
use regex::Regex;
use serde_json::{Value, json};
use std::{
    fs,
    path::{Path, PathBuf},
    process::Command,
};
use walkdir::WalkDir;

pub fn global_dir() -> PathBuf {
    dirs::home_dir()
        .expect("home")
        .join(".gemini/config/skills")
}
pub fn project_dir(project: &Path) -> PathBuf {
    project.join(".agents/skills")
}

pub fn list(project: Option<&Path>) -> Result<Value> {
    let mut out = Vec::new();
    scan_scope("global", &global_dir(), &mut out)?;
    if let Some(p) = project {
        scan_scope("project", &project_dir(p), &mut out)?;
    }
    Ok(json!({"skills":out}))
}

fn scan_scope(scope: &str, dir: &Path, out: &mut Vec<Value>) -> Result<()> {
    if !dir.exists() {
        return Ok(());
    }
    for e in fs::read_dir(dir)? {
        let e = e?;
        let path = e.path();
        if e.file_name() == ".riz-disabled" {
            scan_disabled(scope, &path, out)?;
            continue;
        }
        let skill = path.join("SKILL.md");
        if !skill.is_file() {
            continue;
        }
        let raw = fs::read_to_string(&skill).unwrap_or_default();
        let (name, description) = frontmatter(&raw)
            .unwrap_or_else(|_| (e.file_name().to_string_lossy().into_owned(), String::new()));
        let source = read_source(&path);
        out.push(json!({"name":name,"description":description,"scope":scope,"path":path,"enabled":true,"source":source}));
    }
    Ok(())
}

fn scan_disabled(scope: &str, dir: &Path, out: &mut Vec<Value>) -> Result<()> {
    if !dir.exists() {
        return Ok(());
    }
    for e in fs::read_dir(dir)? {
        let path = e?.path();
        let content = fs::read_to_string(path.join("SKILL.md")).unwrap_or_default();
        if let Ok((name, description)) = frontmatter(&content) {
            let source = read_source(&path);
            out.push(json!({"name":name,"description":description,"scope":scope,"path":path,"enabled":false,"source":source}));
        }
    }
    Ok(())
}

pub fn read(path: &Path) -> Result<Value> {
    let skill = path.join("SKILL.md");
    let content = fs::read_to_string(&skill)?;
    let (name, description) = frontmatter(&content)?;
    Ok(json!({"path":path,"name":name,"description":description,"content":content}))
}
pub fn write(path: &Path, content: &str) -> Result<Value> {
    let (name, description) = frontmatter(content)?;
    fs::create_dir_all(path)?;
    crate::files::write(&path.join("SKILL.md"), content, None)?;
    Ok(json!({"path":path,"name":name,"description":description,"enabled":true}))
}
pub fn delete(path: &Path) -> Result<()> {
    if !path.join("SKILL.md").is_file() {
        bail!("not a skill directory")
    }
    fs::remove_dir_all(path)?;
    Ok(())
}

pub fn toggle(path: &Path, enabled: bool) -> Result<Value> {
    let parent = path.parent().context("skill has no parent")?;
    let target = if enabled {
        if parent.file_name().and_then(|v| v.to_str()) == Some(".riz-disabled") {
            parent
                .parent()
                .context("invalid disabled path")?
                .join(path.file_name().unwrap())
        } else {
            path.to_owned()
        }
    } else {
        let disabled_root = parent.join(".riz-disabled");
        fs::create_dir_all(&disabled_root)?;
        disabled_root.join(path.file_name().context("skill name")?)
    };
    if target != path {
        fs::rename(path, &target)?
    }
    Ok(json!({"path":target,"enabled":enabled}))
}

pub fn install_git(target_root: &Path, url: &str, reference: Option<&str>) -> Result<Value> {
    let temp = tempfile::tempdir()?;
    let mut cmd = Command::new("git");
    cmd.args(["clone", "--depth", "1"]);
    if let Some(r) = reference {
        cmd.args(["--branch", r]);
    }
    cmd.arg("--").arg(url).arg(temp.path());
    let out = cmd.output()?;
    if !out.status.success() {
        bail!("git clone failed: {}", String::from_utf8_lossy(&out.stderr))
    }
    let candidates = WalkDir::new(temp.path())
        .max_depth(5)
        .into_iter()
        .filter_map(Result::ok)
        .filter(|e| e.file_name() == "SKILL.md")
        .map(|e| e.path().parent().unwrap().to_owned())
        .collect::<Vec<_>>();
    if candidates.is_empty() {
        bail!("repository contains no SKILL.md")
    }
    fs::create_dir_all(target_root)?;
    let mut installed = Vec::new();
    for source in candidates {
        let content = fs::read_to_string(source.join("SKILL.md"))?;
        let (name, _) = frontmatter(&content)?;
        let target = target_root.join(&name);
        if target.exists() {
            bail!("skill already exists: {name}")
        }
        copy_tree(&source, &target)?;
        fs::write(
            target.join(".riz-source.json"),
            serde_json::to_vec_pretty(
                &json!({"url":url,"reference":reference,"commit":commit_of(temp.path())}),
            )?,
        )?;
        installed.push(json!({"name":name,"path":target}));
    }
    let commit = commit_of(temp.path());
    Ok(json!({"installed":installed,"url":url,"reference":reference,"commit":commit}))
}

pub fn update_git(path: &Path) -> Result<Value> {
    let source = read_source(path).context("skill was not installed from Git")?;
    let url = source["url"].as_str().context("source URL is missing")?;
    let reference = source["reference"].as_str();
    let temp_root = tempfile::tempdir()?;
    let mut cmd = Command::new("git");
    cmd.args(["clone", "--depth", "1"]);
    if let Some(r) = reference {
        cmd.args(["--branch", r]);
    }
    cmd.arg("--").arg(url).arg(temp_root.path());
    let out = cmd.output()?;
    if !out.status.success() {
        bail!("git clone failed: {}", String::from_utf8_lossy(&out.stderr));
    }
    let name = path
        .file_name()
        .and_then(|value| value.to_str())
        .context("skill name")?;
    let candidate = WalkDir::new(temp_root.path())
        .max_depth(5)
        .into_iter()
        .filter_map(Result::ok)
        .find_map(|entry| {
            if entry.file_name() != "SKILL.md" {
                return None;
            }
            let parent = entry.path().parent()?;
            let content = fs::read_to_string(entry.path()).ok()?;
            let (candidate_name, _) = frontmatter(&content).ok()?;
            (candidate_name == name).then(|| parent.to_owned())
        })
        .context("updated repository no longer contains this skill")?;
    let content = fs::read_to_string(candidate.join("SKILL.md"))?;
    frontmatter(&content)?;
    let staged = path.with_extension("riz-update");
    let backup = path.with_extension("riz-backup");
    if staged.exists() {
        fs::remove_dir_all(&staged)?;
    }
    if backup.exists() {
        fs::remove_dir_all(&backup)?;
    }
    copy_tree(&candidate, &staged)?;
    let commit = commit_of(temp_root.path());
    fs::write(
        staged.join(".riz-source.json"),
        serde_json::to_vec_pretty(&json!({"url":url,"reference":reference,"commit":commit}))?,
    )?;
    fs::rename(path, &backup)?;
    if let Err(e) = fs::rename(&staged, path) {
        let _ = fs::rename(&backup, path);
        return Err(e.into());
    }
    fs::remove_dir_all(backup)?;
    Ok(json!({"path":path,"url":url,"reference":reference,"commit":commit}))
}

pub fn read_source(path: &Path) -> Option<Value> {
    serde_json::from_slice(&fs::read(path.join(".riz-source.json")).ok()?).ok()
}

fn commit_of(repo: &Path) -> Option<String> {
    Command::new("git")
        .args(["rev-parse", "HEAD"])
        .current_dir(repo)
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_owned())
}

fn copy_tree(from: &Path, to: &Path) -> Result<()> {
    for e in WalkDir::new(from)
        .into_iter()
        .filter_entry(|entry| entry.file_name() != ".git")
    {
        let e = e?;
        let rel = e.path().strip_prefix(from)?;
        let dest = to.join(rel);
        if e.file_type().is_dir() {
            fs::create_dir_all(dest)?
        } else {
            fs::copy(e.path(), dest)?;
        }
    }
    Ok(())
}
fn frontmatter(content: &str) -> Result<(String, String)> {
    let re = Regex::new(r"(?s)^---\s*\n(.*?)\n---")?;
    let caps = re
        .captures(content)
        .context("SKILL.md requires YAML frontmatter")?;
    let body = &caps[1];
    let name = field(body, "name").context("frontmatter requires name")?;
    if name.len() > 64
        || !name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_'))
    {
        bail!("invalid skill name")
    };
    let description = field(body, "description").unwrap_or_default();
    if description.len() > 1024 {
        bail!("description is too long")
    };
    Ok((name, description))
}
fn field(body: &str, key: &str) -> Option<String> {
    body.lines().find_map(|l| {
        let (k, v) = l.split_once(':')?;
        (k.trim() == key).then(|| v.trim().trim_matches(['\"', '\'']).to_owned())
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validates_frontmatter() {
        assert!(frontmatter("---\nname: useful-skill\ndescription: Test\n---\nBody").is_ok());
        assert!(frontmatter("Body").is_err());
    }

    #[test]
    fn updates_a_skill_stored_at_the_repository_root() -> Result<()> {
        let source = tempfile::tempdir()?;
        let target = tempfile::tempdir()?;
        Command::new("git")
            .arg("init")
            .current_dir(source.path())
            .output()?;
        fs::write(
            source.path().join("SKILL.md"),
            "---\nname: root-skill\ndescription: Initial\n---\nInitial\n",
        )?;
        commit_all(source.path(), "initial")?;

        install_git(target.path(), source.path().to_str().unwrap(), None)?;
        let installed = target.path().join("root-skill");
        assert!(!installed.join(".git").exists());

        fs::write(
            source.path().join("SKILL.md"),
            "---\nname: root-skill\ndescription: Updated\n---\nUpdated\n",
        )?;
        commit_all(source.path(), "updated")?;
        update_git(&installed)?;

        let content = fs::read_to_string(installed.join("SKILL.md"))?;
        assert!(content.contains("description: Updated"));
        assert!(!installed.join(".git").exists());
        Ok(())
    }

    fn commit_all(repo: &Path, message: &str) -> Result<()> {
        let status = Command::new("git")
            .args(["add", "SKILL.md"])
            .current_dir(repo)
            .status()?;
        assert!(status.success());
        let status = Command::new("git")
            .args([
                "-c",
                "user.name=Riz Test",
                "-c",
                "user.email=riz@test.invalid",
                "commit",
                "-m",
                message,
            ])
            .current_dir(repo)
            .status()?;
        assert!(status.success());
        Ok(())
    }
}
