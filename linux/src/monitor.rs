use crate::model::Session;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{
    collections::{HashMap, HashSet},
    fs::{self, File, Metadata},
    io::{self, BufRead, BufReader, Read, Seek, SeekFrom},
    os::unix::fs::MetadataExt,
    path::{Path, PathBuf},
};

const HEADER: usize = 1024 * 1024;
const TAIL: usize = 512 * 1024;
type Stamp = (u64, u64, u64, i64, i64, i64, i64);
fn stamp(m: &Metadata) -> Stamp {
    (
        m.dev(),
        m.ino(),
        m.len(),
        m.mtime(),
        m.mtime_nsec(),
        m.ctime(),
        m.ctime_nsec(),
    )
}
fn modified(m: &Metadata) -> f64 {
    m.mtime() as f64 + m.mtime_nsec() as f64 / 1e9
}

/// Read a bounded tail, dropping an initial partial record and an unfinished append.
fn tail(file: &mut File, size: u64, floor: u64, bound: usize) -> io::Result<Vec<u8>> {
    let start = floor.max(size.saturating_sub(bound as u64));
    file.seek(SeekFrom::Start(start))?;
    let mut bytes = Vec::with_capacity(bound);
    file.take(bound as u64).read_to_end(&mut bytes)?;
    if start > floor {
        let skip = bytes
            .iter()
            .position(|b| *b == b'\n')
            .map_or(bytes.len(), |p| p + 1);
        bytes.drain(..skip);
    }
    Ok(bytes)
}
fn records(bytes: &[u8]) -> impl Iterator<Item = Value> + '_ {
    bytes
        .split_inclusive(|b| *b == b'\n')
        .filter(|b| b.ends_with(b"\n"))
        .filter_map(|b| serde_json::from_slice::<Value>(b).ok())
        .filter(Value::is_object)
}
pub fn read_session(path: &Path) -> io::Result<Session> {
    let mut file = File::open(path)?;
    let meta = file.metadata()?;
    let mut session = Session {
        updated_at: modified(&meta),
        ..Default::default()
    };
    let mut first = Vec::new();
    BufReader::new((&mut file).take((HEADER + 1) as u64)).read_until(b'\n', &mut first)?;
    if first.len() > HEADER || !first.ends_with(b"\n") {
        return Ok(session);
    }
    if let Ok(row) = serde_json::from_slice(&first) {
        session.reduce(&row);
    }
    for row in records(&tail(&mut file, meta.len(), first.len() as u64, TAIL)?) {
        session.reduce(&row);
    }
    Ok(session)
}

#[derive(Clone, Debug)]
pub struct ScanOptions {
    pub limit: usize,
    pub stale_after: f64,
    pub include_subagents: bool,
    pub preferred_ids: HashSet<String>,
}
impl Default for ScanOptions {
    fn default() -> Self {
        Self {
            limit: 48,
            stale_after: 120.,
            include_subagents: false,
            preferred_ids: HashSet::new(),
        }
    }
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Snapshot {
    pub source: String,
    pub observed_at: f64,
    pub warnings: Vec<String>,
    pub sessions: Vec<Session>,
}
pub struct Monitor {
    root: PathBuf,
    cache: HashMap<PathBuf, (Stamp, Session)>,
    title_stamp: Option<Stamp>,
    titles: HashMap<String, String>,
}
impl Monitor {
    pub fn new(root: PathBuf) -> Self {
        Self {
            root,
            cache: HashMap::new(),
            title_stamp: None,
            titles: HashMap::new(),
        }
    }
    fn titles(&mut self) -> io::Result<()> {
        let path = self
            .root
            .parent()
            .unwrap_or(Path::new("."))
            .join("session_index.jsonl");
        let result = (|| {
            let mut file = File::open(path)?;
            let meta = file.metadata()?;
            let key = stamp(&meta);
            if self.title_stamp == Some(key) {
                return Ok(());
            }
            let mut titles = HashMap::new();
            for row in records(&tail(&mut file, meta.len(), 0, HEADER)?) {
                let id = crate::model::clean(row["id"].as_str().unwrap_or_default(), 512, false);
                if !id.is_empty() {
                    titles.insert(
                        id,
                        crate::model::clean(
                            row["thread_name"].as_str().unwrap_or_default(),
                            512,
                            false,
                        ),
                    );
                }
            }
            self.titles = titles;
            self.title_stamp = Some(key);
            Ok(())
        })();
        if result.is_err() {
            self.titles.clear();
            self.title_stamp = None;
        }
        result
    }
    pub fn snapshot(&mut self, options: &ScanOptions, now: f64) -> Snapshot {
        let mut warnings = Vec::new();
        if let Err(e) = self.titles()
            && e.kind() != io::ErrorKind::NotFound
        {
            warnings.push("Session titles could not be read.".into());
        }
        if !self.root.is_dir() {
            warnings.push("Session directory is missing or inaccessible.".into());
        }
        let mut files = Vec::new();
        for entry in walkdir::WalkDir::new(&self.root).follow_links(false) {
            let Ok(entry) = entry else {
                warnings.push("Some session directories could not be read.".into());
                continue;
            };
            if !entry.file_type().is_file() || entry.path().extension().is_none_or(|s| s != "jsonl")
            {
                continue;
            }
            match fs::symlink_metadata(entry.path()) {
                Ok(meta) if meta.is_file() => files.push((entry.into_path(), meta)),
                Ok(_) => (),
                Err(_) => warnings.push("A session file disappeared or could not be read.".into()),
            }
        }
        files.sort_by(|a, b| {
            b.1.mtime()
                .cmp(&a.1.mtime())
                .then(b.1.mtime_nsec().cmp(&a.1.mtime_nsec()))
                .then(b.0.cmp(&a.0))
        });
        let preferred = |p: &Path| {
            p.file_stem().and_then(|s| s.to_str()).is_some_and(|stem| {
                options
                    .preferred_ids
                    .iter()
                    .any(|id| stem.ends_with(&format!("-{id}")))
            })
        };
        let candidates = files.iter().filter(|(p, _)| preferred(p)).chain(
            files
                .iter()
                .take(100.max(options.limit.saturating_mul(10)))
                .filter(|(p, _)| !preferred(p)),
        );
        let mut retained = HashMap::new();
        let mut seen = HashSet::new();
        let mut sessions = Vec::new();
        for (path, meta) in candidates {
            let key = stamp(meta);
            let cached = self
                .cache
                .get(path)
                .filter(|(k, _)| *k == key)
                .map(|(_, s)| s.clone());
            let session = match cached.map(Ok).unwrap_or_else(|| read_session(path)) {
                Ok(s) => s,
                Err(_) => {
                    warnings.push("A session file disappeared or could not be read.".into());
                    continue;
                }
            };
            retained.insert(path.clone(), (key, session.clone()));
            if session.id.is_empty()
                || (session.subagent && !options.include_subagents)
                || !seen.insert(session.id.clone())
            {
                continue;
            }
            let mut session = session;
            session.stale = now - session.updated_at > options.stale_after;
            if let Some(title) = self.titles.get(&session.id) {
                session.title = title.clone();
            }
            sessions.push(session);
            if sessions.len() >= options.limit {
                break;
            }
        }
        self.cache = retained;
        warnings.sort();
        warnings.dedup();
        Snapshot {
            source: "codex-rollout".into(),
            observed_at: now,
            warnings,
            sessions,
        }
    }
}

pub fn default_root() -> PathBuf {
    std::env::var_os("CODEX_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            PathBuf::from(std::env::var_os("HOME").unwrap_or_default()).join(".codex")
        })
        .join("sessions")
}
