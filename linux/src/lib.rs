pub mod model;
pub mod monitor;
pub mod preferences;
#[cfg(feature = "desktop")]
pub mod ui;

pub fn now() -> f64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs_f64()
}
