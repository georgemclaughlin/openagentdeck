use crate::model::Session;
use serde_json::{Map, Value};
use std::{
    collections::HashSet,
    fs::{self, File},
    io::{self, Read, Write},
    os::unix::fs::DirBuilderExt,
    path::PathBuf,
};

pub struct Preferences {
    path: Option<PathBuf>,
    pub pinned: HashSet<String>,
    pub hidden: HashSet<String>,
    pub warning: String,
    document: Map<String, Value>,
    readable: bool,
}
impl Preferences {
    pub fn load(path: Option<PathBuf>) -> Self {
        let mut p = Self {
            path,
            pinned: HashSet::new(),
            hidden: HashSet::new(),
            warning: String::new(),
            document: Map::new(),
            readable: true,
        };
        let Some(path) = &p.path else {
            return p;
        };
        let load = (|| -> Result<_, Box<dyn std::error::Error>> {
            let mut data = Vec::new();
            File::open(path)?
                .take(1024 * 1024 + 1)
                .read_to_end(&mut data)?;
            if data.len() > 1024 * 1024 {
                return Err("oversized preferences".into());
            }
            let doc: Map<String, Value> = serde_json::from_slice(&data)?;
            let parse = |key: &str| -> Result<HashSet<String>, Box<dyn std::error::Error>> {
                let Some(values) = doc.get(key) else {
                    return Ok(HashSet::new());
                };
                let values = values.as_array().ok_or("invalid preferences")?;
                values
                    .iter()
                    .map(|v| {
                        v.as_str()
                            .filter(|s| !s.is_empty() && s.chars().count() <= 512)
                            .map(String::from)
                            .ok_or_else(|| "invalid session ID".into())
                    })
                    .collect()
            };
            let pinned = parse("pinned")?;
            let hidden = parse("hidden")?;
            Ok((doc, pinned, hidden))
        })();
        match load {
            Ok((doc, pinned, hidden)) => {
                p.document = doc;
                p.pinned = pinned;
                p.hidden = hidden;
            }
            Err(e)
                if e.downcast_ref::<io::Error>()
                    .is_some_and(|e| e.kind() == io::ErrorKind::NotFound) => {}
            Err(_) => {
                p.readable = false;
                p.warning =
                    "Deck preferences could not be read; existing file left untouched.".into();
            }
        }
        p
    }
    pub fn toggle(&mut self, id: &str, field: &str) -> bool {
        if id.is_empty() || id.chars().count() > 512 {
            return false;
        }
        let mut pinned = self.pinned.clone();
        let mut hidden = self.hidden.clone();
        let values = match field {
            "pinned" => &mut pinned,
            "hidden" => &mut hidden,
            _ => return false,
        };
        if !values.remove(id) {
            values.insert(id.into());
        }
        self.save(pinned, hidden)
    }
    pub fn restore_all(&mut self) -> bool {
        self.save(self.pinned.clone(), HashSet::new())
    }
    fn save(&mut self, pinned: HashSet<String>, hidden: HashSet<String>) -> bool {
        if !self.readable {
            return false;
        }
        let mut document = self.document.clone();
        for (name, values) in [("pinned", &pinned), ("hidden", &hidden)] {
            let mut values: Vec<_> = values.iter().collect();
            values.sort();
            document.insert(name.into(), serde_json::json!(values));
        }
        let save = (|| -> Result<(), Box<dyn std::error::Error>> {
            if let Some(path) = &self.path {
                let parent = path
                    .parent()
                    .filter(|p| !p.as_os_str().is_empty())
                    .unwrap_or(std::path::Path::new("."));
                fs::DirBuilder::new()
                    .recursive(true)
                    .mode(0o700)
                    .create(parent)?;
                let mut file = tempfile::Builder::new()
                    .prefix(".preferences-")
                    .tempfile_in(parent)?;
                serde_json::to_writer_pretty(&mut file, &document)?;
                file.write_all(b"\n")?;
                file.as_file().sync_all()?;
                file.persist(path)?;
            }
            Ok(())
        })();
        if save.is_err() {
            self.warning = "Could not save deck preferences. The change was not applied.".into();
            return false;
        }
        self.pinned = pinned;
        self.hidden = hidden;
        self.document = document;
        self.warning.clear();
        true
    }
    pub fn visible<'a>(&self, sessions: &'a [Session], hidden: bool) -> Vec<&'a Session> {
        let mut rows: Vec<_> = sessions
            .iter()
            .filter(|s| self.hidden.contains(&s.id) == hidden)
            .collect();
        rows.sort_by(|a, b| {
            (!self.pinned.contains(&a.id), a.stale, a.state != "working")
                .cmp(&(!self.pinned.contains(&b.id), b.stale, b.state != "working"))
                .then(b.updated_at.total_cmp(&a.updated_at))
                .then(a.id.cmp(&b.id))
        });
        rows
    }
}
pub fn default_path() -> PathBuf {
    std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            PathBuf::from(std::env::var_os("HOME").unwrap_or_default()).join(".config")
        })
        .join("openagentdeck/preferences.json")
}
