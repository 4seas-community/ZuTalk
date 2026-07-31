//! Shared guard for the Context Pack example binaries.

use std::path::Path;

/// Refuses to touch the store while the app owns it. Two processes doing a
/// read-modify-write on `Secrets/content-keys.json` can drop keys, and losing
/// a key means losing everything it protects.
pub fn require_app_quit(data_dir: &Path) -> Result<(), String> {
    let Ok(pid) = std::fs::read_to_string(data_dir.join(".zulangue-core.lock")) else {
        return Ok(());
    };
    let pid = pid.trim();
    if pid.is_empty() || !process_is_alive(pid) {
        return Ok(());
    }
    Err(format!("Zulangue is running (pid {pid}); quit it first"))
}

fn process_is_alive(pid: &str) -> bool {
    std::process::Command::new("kill")
        .args(["-0", pid])
        .stderr(std::process::Stdio::null())
        .status()
        .map(|status| status.success())
        .unwrap_or(false)
}
