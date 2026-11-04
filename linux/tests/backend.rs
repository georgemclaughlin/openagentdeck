use openagentdeck::{
    model::{Session, clean},
    monitor::{Monitor, ScanOptions, read_session},
    preferences::Preferences,
};
use serde_json::{Value, json};
use std::{
    collections::HashSet,
    fs::{self, File, FileTimes},
    io::Write,
    os::unix::fs::{PermissionsExt, symlink},
    path::Path,
    time::{Duration, UNIX_EPOCH},
};
fn record(kind: &str, payload: Value) -> String {
    format!("{}\n", json!({"type":kind,"payload":payload}))
}
fn event(kind: &str) -> String {
    record("event_msg", json!({"type":kind}))
}
fn header(id: &str) -> String {
    record(
        "session_meta",
        json!({"id":id,"cwd":"/projects/deck","git":{"branch":"feature/native"}}),
    )
}
fn write(path: &Path, content: &str, time: u64) {
    fs::write(path, content).unwrap();
    File::open(path)
        .unwrap()
        .set_times(FileTimes::new().set_modified(UNIX_EPOCH + Duration::from_secs(time)))
        .unwrap();
}
fn reduce(payload: Value) -> Session {
    let mut s = Session::default();
    s.reduce(&payload);
    s
}

#[test]
fn partial_append_cache_replacement_and_deletion() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("one.jsonl");
    let complete = event("task_complete");
    let start = header("one") + &event("task_started");
    write(
        &path,
        &(start.clone() + &complete[..complete.len() - 1]),
        1000,
    );
    let mut monitor = Monitor::new(dir.path().into());
    let options = ScanOptions::default();
    assert_eq!(
        monitor.snapshot(&options, 1010.).sessions[0].state,
        "working"
    );
    assert!(!monitor.snapshot(&options, 1010.).sessions[0].stale);
    assert!(monitor.snapshot(&options, 1200.).sessions[0].stale);
    File::options()
        .append(true)
        .open(&path)
        .unwrap()
        .write_all(b"\n")
        .unwrap();
    assert_eq!(
        monitor.snapshot(&options, 1200.).sessions[0].state,
        "completed"
    );
    let new = dir.path().join("replacement");
    write(&new, &header("new"), 1000);
    fs::rename(new, &path).unwrap();
    assert_eq!(monitor.snapshot(&options, 1200.).sessions[0].id, "new");
    fs::write(&path, "").unwrap();
    assert!(monitor.snapshot(&options, 1200.).sessions.is_empty());
    fs::remove_file(&path).unwrap();
    assert!(monitor.snapshot(&options, 1200.).sessions.is_empty());
}
#[test]
fn bounded_tail_header_and_malformed_data() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("one.jsonl");
    let large = record(
        "response_item",
        json!({"type":"reasoning","content":"x".repeat(600_000)}),
    );
    fs::write(&path, header("one") + &event("task_started") + &large).unwrap();
    assert_eq!(read_session(&path).unwrap().state, "unknown");
    File::options()
        .append(true)
        .open(&path)
        .unwrap()
        .write_all(event("task_complete").as_bytes())
        .unwrap();
    assert_eq!(read_session(&path).unwrap().state, "completed");
    fs::write(
        &path,
        header("one") + "broken\n[]\nnull\n{\"type\":\"event_msg\",\"payload\":[]}\n",
    )
    .unwrap();
    assert_eq!(read_session(&path).unwrap().state, "unknown");
    fs::write(
        &path,
        record(
            "session_meta",
            json!({"id":"one","cwd":"x".repeat(1024*1024)}),
        ),
    )
    .unwrap();
    assert!(read_session(&path).unwrap().id.is_empty());
    fs::write(&path, header("one").trim_end()).unwrap();
    assert!(read_session(&path).unwrap().id.is_empty());
}
#[test]
fn discovery_deduplicates_filters_symlinks_subagents_and_retains_old_pin() {
    let dir = tempfile::tempdir().unwrap();
    let mut monitor = Monitor::new(dir.path().into());
    for i in 0..105 {
        write(
            &dir.path().join(format!("rollout-session-{i}.jsonl")),
            &header(&format!("session-{i}")),
            1000 + i,
        );
    }
    let mut options = ScanOptions {
        limit: 1,
        ..Default::default()
    };
    assert_eq!(
        monitor.snapshot(&options, 1200.).sessions[0].id,
        "session-104"
    );
    options.preferred_ids.insert("session-0".into());
    assert_eq!(
        monitor.snapshot(&options, 1200.).sessions[0].id,
        "session-0"
    );
    write(
        &dir.path().join("new.jsonl"),
        &(header("session-0") + &event("task_complete")),
        1300,
    );
    options.preferred_ids.clear();
    assert_eq!(
        monitor.snapshot(&options, 1400.).sessions[0].state,
        "completed"
    );
    options.limit = 200;
    assert_eq!(monitor.snapshot(&options, 1400.).sessions.len(), 105);
    write(
        &dir.path().join("child.jsonl"),
        &record(
            "session_meta",
            json!({"id":"child","source":{"subagent":{"parent":"one"}}}),
        ),
        1500,
    );
    assert_eq!(monitor.snapshot(&options, 1600.).sessions.len(), 105);
    options.include_subagents = true;
    assert_eq!(monitor.snapshot(&options, 1600.).sessions.len(), 106);
    let outside = dir.path().join("not-a-rollout.txt");
    fs::write(&outside, header("symlink")).unwrap();
    symlink(&outside, dir.path().join("symlink.jsonl")).unwrap();
    assert_eq!(monitor.snapshot(&options, 1600.).sessions.len(), 106);
    assert!(
        !Monitor::new(dir.path().join("missing"))
            .snapshot(&options, 1600.)
            .warnings
            .is_empty()
    );
}
#[test]
fn titles_update_independently_and_partial_titles_wait() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("sessions");
    fs::create_dir(&root).unwrap();
    fs::write(root.join("one.jsonl"), header("one")).unwrap();
    let index = dir.path().join("session_index.jsonl");
    let mut monitor = Monitor::new(root);
    let o = ScanOptions::default();
    fs::write(&index, "{\"id\":\"one\",\"thread_name\":\"First\"}\n").unwrap();
    assert_eq!(monitor.snapshot(&o, 0.).sessions[0].title, "First");
    File::options()
        .append(true)
        .open(&index)
        .unwrap()
        .write_all(b"{\"id\":\"one\",\"thread_name\":\"Second\"}")
        .unwrap();
    assert_eq!(monitor.snapshot(&o, 0.).sessions[0].title, "First");
    File::options()
        .append(true)
        .open(&index)
        .unwrap()
        .write_all(b"\n")
        .unwrap();
    assert_eq!(monitor.snapshot(&o, 0.).sessions[0].title, "Second");
    fs::remove_file(index).unwrap();
    assert!(monitor.snapshot(&o, 0.).sessions[0].title.is_empty());
}
#[test]
fn privacy_filter_human_messages_tools_and_history_bounds() {
    let mut s = Session::default();
    for payload in [
        json!({"type":"message","role":"developer","content":"SECRET"}),
        json!({"type":"message","role":"assistant","phase":"analysis","content":"SECRET"}),
        json!({"type":"reasoning","content":"SECRET"}),
        json!({"type":"function_call_output","output":"SECRET"}),
        json!({"type":"message","role":"user","content":"<environment_context>SECRET</environment_context>"}),
        json!({"type":"message","role":"user","content":format!("<environment_context>{}","x".repeat(3000))}),
        json!({"type":"message","role":"user","content":[{"type":"input_text","text":"Build native UI"}]}),
        json!({"type":"function_call","name":"test","arguments":"SECRET"}),
        json!({"type":"message","role":"assistant","phase":"final_answer","content":[{"type":"output_text","text":"Ready."},{"type":"reasoning","text":"SECRET"}]}),
    ] {
        s.reduce(&json!({"type":"response_item","payload":payload}));
    }
    assert_eq!(s.last_prompt, "Build native UI");
    assert_eq!(s.last_activity, "Ready.");
    assert_eq!(s.recent.len(), 3);
    assert!(!serde_json::to_string(&s).unwrap().contains("SECRET"));
    for i in 0..30 {
        s.reduce(&json!({"type":"event_msg","payload":{"type":"agent_message","message":format!("Update {i}")}}));
    }
    s.reduce(&json!({"type":"event_msg","payload":{"type":"agent_message","message":"Update 29"}}));
    assert_eq!(s.recent.len(), 12);
    assert_eq!(s.recent[0].text, "Update 18");
    assert!(s.history().starts_with("ASSISTANT"));
    assert!(s.history().contains("LATEST PROMPT"));
}
#[test]
fn lifecycle_item_errors_and_invalid_usage() {
    let mut s = Session::default();
    for payload in [
        json!({"type":"item_completed","item":{"type":"UserMessage","content":[{"type":"Text","text":"Check API"}]}}),
        json!({"type":"item_completed","item":{"type":"CommandExecution","status":"failed","exit_code":2,"aggregated_output":"SECRET"}}),
        json!({"type":"task_complete","error":{"message":"Network unavailable"},"last_agent_message":"Try later"}),
    ] {
        s.reduce(&json!({"type":"event_msg","payload":payload}));
    }
    assert_eq!(s.state, "error");
    assert_eq!(s.error, "Network unavailable");
    assert_eq!(s.last_prompt, "Check API");
    assert!(
        s.recent
            .iter()
            .any(|a| a.text == "Command: failed (exit 2)")
    );
    assert!(!serde_json::to_string(&s).unwrap().contains("SECRET"));
    s.reduce(&json!({"type":"event_msg","payload":{"type":"task_started"}}));
    assert!(s.error.is_empty());
    s.reduce(&json!({"type":"event_msg","payload":{"type":"turn_aborted"}}));
    assert_eq!(s.state, "interrupted");
    for n in [json!(true), json!(-1), json!("123"), json!({}), Value::Null] {
        let s = reduce(
            json!({"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":n}},"rate_limits":{"primary":{"used_percent":n}}}}),
        );
        assert!(s.total_tokens.is_none());
        assert!(s.limit_used_percent.is_none());
    }
    let s = reduce(
        json!({"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":1234}},"rate_limits":{"primary":{"used_percent":42}}}}),
    );
    assert_eq!(s.total_tokens, Some(1234));
    assert_eq!(s.limit_used_percent, Some(42.));
    assert_eq!(
        clean("hello\u{1b}\u{202e}\nworld", 512, false),
        "hello   world"
    );
    assert_eq!(clean("Hi\nthere", 2000, true), "Hi\nthere");
}
#[test]
fn preferences_compatible_private_and_atomic() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("preferences.json");
    fs::write(
        &path,
        r#"{"future":{"keep":true},"pinned":["old"],"hidden":[]}"#,
    )
    .unwrap();
    let mut p = Preferences::load(Some(path.clone()));
    assert!(p.toggle("new", "pinned"));
    assert!(p.toggle("hidden", "hidden"));
    let doc: Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
    assert_eq!(doc["future"]["keep"], true);
    assert_eq!(
        fs::metadata(&path).unwrap().permissions().mode() & 0o777,
        0o600
    );
    let mut reloaded = Preferences::load(Some(path.clone()));
    assert!(reloaded.pinned.contains("new"));
    assert!(reloaded.restore_all());
    let before = fs::read(&path).unwrap();
    fs::remove_file(&path).unwrap();
    fs::create_dir(&path).unwrap();
    assert!(!reloaded.toggle("failed", "pinned"));
    assert!(!reloaded.pinned.contains("failed"));
    assert_eq!(fs::read_dir(dir.path()).unwrap().count(), 1);
    fs::remove_dir(&path).unwrap();
    fs::write(&path, b"broken").unwrap();
    let mut p = Preferences::load(Some(path.clone()));
    assert!(!p.toggle("x", "hidden"));
    assert_eq!(fs::read(&path).unwrap(), b"broken");
    fs::write(&path, r#"{"pinned":["x"],"hidden":[5]}"#).unwrap();
    let p = Preferences::load(Some(path));
    assert!(p.pinned.is_empty());
    assert!(!p.warning.is_empty());
    assert!(!before.is_empty());
}
#[test]
fn sorting_pinning_hiding_and_demo() {
    let mut p = Preferences::load(None);
    let mut sessions = vec![];
    for (id, stale, state, time) in [
        ("pin", true, "unknown", 0.),
        ("working", false, "working", 10.),
        ("done", false, "completed", 20.),
    ] {
        sessions.push(Session {
            id: id.into(),
            stale,
            state: state.into(),
            updated_at: time,
            ..Default::default()
        });
    }
    p.toggle("pin", "pinned");
    assert_eq!(
        p.visible(&sessions, false)
            .iter()
            .map(|s| s.id.as_str())
            .collect::<Vec<_>>(),
        ["pin", "working", "done"]
    );
    p.toggle("working", "hidden");
    assert_eq!(p.visible(&sessions, true)[0].id, "working");
    p.toggle("outside-scan", "hidden");
    p.restore_all();
    assert_eq!(p.hidden, HashSet::new());
}
