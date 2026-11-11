//! The repository's paths and local settings, as tools/common.py has them: local.env at the
//! root (KEY=value, shell-quoted), overridden by the environment; downloaded clients under client/.
use std::collections::HashMap;
use std::path::{Path, PathBuf};

pub fn root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("..").canonicalize().expect("the repository root")
}

pub fn build_dir() -> PathBuf {
    root().join("build")
}

/// Where the client sits inside a downloaded depot, and its executable inside the app bundle.
pub const DEPOT_APP: &str = "x64arm64/Brighter Shores.app";
pub const BUNDLE_EXECUTABLE: &str = "Contents/MacOS/Brighter Shores";

pub fn settings() -> HashMap<String, String> {
    let mut values = HashMap::new();
    if let Ok(text) = std::fs::read_to_string(root().join("local.env")) {
        for line in text.lines() {
            let line = line.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let Some((key, value)) = line.split_once('=') else { continue };
            values.insert(key.trim().to_string(), unquote(value.trim()));
        }
    }
    values.extend(std::env::vars());
    values
}

/// A setting, if set and not empty.
pub fn setting(key: &str) -> Option<String> {
    settings().remove(key).filter(|value| !value.is_empty())
}

/// The first word of a shell-quoted value, as shlex.split()[0] reads it.
fn unquote(value: &str) -> String {
    let mut out = String::new();
    let mut chars = value.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            '\'' => out.extend(chars.by_ref().take_while(|&c| c != '\'')),
            '"' => {
                while let Some(c) = chars.next() {
                    match c {
                        '"' => break,
                        '\\' => out.extend(chars.next()),
                        c => out.push(c),
                    }
                }
            }
            '\\' => out.extend(chars.next()),
            c if c.is_whitespace() => break,
            c => out.push(c),
        }
    }
    out
}

/// The Brighter Shores.app of a download: the one named, else the newest finished one.
pub fn client_app(client: Option<&Path>) -> Result<PathBuf, String> {
    let client = match client {
        Some(path) => path.to_path_buf(),
        None => {
            let mut found: Vec<PathBuf> = std::fs::read_dir(root().join("client"))
                .map_err(|_| "no downloaded client: run tools/fetch_client.py first".to_string())?
                .filter_map(|entry| entry.ok().map(|e| e.path()))
                .filter(|path| path.is_dir() && path.join(".complete").is_file())
                .collect();
            found.sort();
            found.pop().ok_or("no downloaded client: run tools/fetch_client.py first")?
        }
    };
    let app = if client.join(DEPOT_APP).is_dir() { client.join(DEPOT_APP) } else { client };
    if !app.join(BUNDLE_EXECUTABLE).is_file() {
        return Err(format!("{} holds no {BUNDLE_EXECUTABLE}", app.display()));
    }
    Ok(app)
}

#[cfg(test)]
mod tests {
    use super::unquote;

    #[test]
    fn reads_values_as_the_shell_would() {
        assert_eq!(unquote("plain"), "plain");
        assert_eq!(unquote("\"a b\" c"), "a b");
        assert_eq!(unquote("'x\\y'"), "x\\y");
        assert_eq!(unquote("a\\ b"), "a b");
    }
}
