use std::process::Command;
#[test]
fn headless_json_and_argument_validation() {
    let binary = env!("CARGO_BIN_EXE_openagentdeck");
    let dir = tempfile::tempdir().unwrap();
    std::fs::write(
        dir.path().join("one.jsonl"),
        concat!(
            "{\"type\":\"session_meta\",\"payload\":{\"id\":\"test\",\"cwd\":\"/project\"}}\n",
            "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\"}}\n"
        ),
    )
    .unwrap();
    let result = Command::new(binary)
        .env_remove("DISPLAY")
        .env_remove("WAYLAND_DISPLAY")
        .args(["--json", "--sessions-dir"])
        .arg(dir.path())
        .output()
        .unwrap();
    assert!(result.status.success());
    let data: serde_json::Value = serde_json::from_slice(&result.stdout).unwrap();
    assert_eq!(data["sessions"][0]["state"], "working");
    for args in [
        ["--limit", "0"],
        ["--interval", "nan"],
        ["--stale-after", "-1"],
        ["--size", "1920x480+0+0"],
        ["--size", "700x300"],
        ["--smoke-test", "/tmp/unreachable-preview"],
    ] {
        let result = Command::new(binary).args(args).output().unwrap();
        assert_eq!(result.status.code(), Some(2), "{args:?}");
    }
}
