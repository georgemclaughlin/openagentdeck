use clap::Parser;
use openagentdeck::{
    monitor::{Monitor, ScanOptions, default_root},
    preferences::default_path,
};
use std::path::PathBuf;

#[derive(Parser, Clone, Debug)]
#[command(
    version,
    about = "Native read-only monitor for existing local Codex sessions"
)]
pub struct Args {
    /// Use synthetic sessions; never read or write personal preferences
    #[arg(long)]
    demo: bool,
    /// Print one JSON snapshot instead of opening a window
    #[arg(long, conflicts_with_all = ["demo", "list_monitors", "smoke_test"])]
    json: bool,
    #[arg(long, default_value_os_t = default_root())]
    sessions_dir: PathBuf,
    #[arg(long, default_value_os_t = default_path())]
    preferences_file: PathBuf,
    #[arg(long, default_value = "2", value_parser = positive)]
    interval: f64,
    #[arg(long, default_value = "120", value_parser = positive)]
    stale_after: f64,
    #[arg(long, default_value = "48", value_parser = clap::value_parser!(u32).range(1..=10000))]
    limit: u32,
    #[arg(long)]
    include_subagents: bool,
    /// Initial window size; Wayland does not support application-chosen coordinates
    #[arg(long, alias = "geometry", default_value = "1920x480", value_parser = size)]
    size: (i32, i32),
    #[arg(long)]
    fullscreen: bool,
    /// Connector to use for fullscreen (for example DP-3); must already be enabled
    #[arg(long)]
    monitor: Option<String>,
    /// List enabled displays without changing their configuration
    #[arg(long)]
    list_monitors: bool,
    /// Exercise the native UI with synthetic data, save previews, then exit
    #[arg(long, hide = true, requires = "demo", conflicts_with = "fullscreen")]
    smoke_test: Option<PathBuf>,
}
fn positive(s: &str) -> Result<f64, String> {
    s.parse::<f64>()
        .ok()
        .filter(|n| n.is_finite() && *n > 0. && *n <= 86400.)
        .ok_or_else(|| "must be a finite positive number no greater than 86400".into())
}
fn size(s: &str) -> Result<(i32, i32), String> {
    let parse = || {
        let (w, h) = s.split_once('x')?;
        Some((w.parse::<i32>().ok()?, h.parse::<i32>().ok()?))
    };
    parse()
        .filter(|(w, h)| (720..=16384).contains(w) && (400..=16384).contains(h))
        .ok_or_else(|| {
            "use WIDTHxHEIGHT (at least 720x400); select a fullscreen output with --monitor".into()
        })
}
fn main() -> std::process::ExitCode {
    let args = Args::parse();
    let options = ScanOptions {
        limit: args.limit as usize,
        stale_after: args.stale_after,
        include_subagents: args.include_subagents,
        ..Default::default()
    };
    if args.json {
        let snapshot = Monitor::new(args.sessions_dir).snapshot(&options, openagentdeck::now());
        let result = serde_json::to_writer_pretty(std::io::stdout().lock(), &snapshot);
        return if result.is_ok() {
            std::process::ExitCode::SUCCESS
        } else {
            std::process::ExitCode::FAILURE
        };
    }
    #[cfg(feature = "desktop")]
    {
        let code = openagentdeck::ui::run(openagentdeck::ui::Config {
            demo: args.demo,
            root: args.sessions_dir,
            preferences: args.preferences_file,
            interval: args.interval,
            options,
            size: args.size,
            fullscreen: args.fullscreen,
            monitor: args.monitor,
            list_monitors: args.list_monitors,
            smoke_test: args.smoke_test,
        });
        std::process::ExitCode::from(code)
    }
    #[cfg(not(feature = "desktop"))]
    {
        eprintln!("This build has no desktop feature. Use --json or build with default features.");
        std::process::ExitCode::FAILURE
    }
}
