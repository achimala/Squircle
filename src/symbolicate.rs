//! Best-effort Apple-text crash symbolication using the selected Xcode tool.
//! A zero exit status does not prove that any application frame was resolved.

use std::{
    ffi::OsString,
    path::{Path, PathBuf},
    time::Duration,
};

use anyhow::{Context, Result, ensure};
use tokio::{io::AsyncReadExt, process::Command, time::Instant};

const MAX_BYTES: usize = 2 * 1024 * 1024;
const TIMEOUT: Duration = Duration::from_secs(60);

/// Return the tool's stdout followed by any stderr warnings, without claiming
/// that symbolication succeeded. symbolicatecrash itself matches binary UUIDs;
/// merely supplying a dSYM does not establish that it matches this report.
pub async fn run(report: &Path, dsym: &Path) -> Result<String> {
    let report = report
        .canonicalize()
        .context("crash report does not exist")?;
    let dsym = dsym.canonicalize().context("dSYM bundle does not exist")?;
    ensure!(report.is_file(), "crash report must be a regular file");
    ensure!(
        dsym.is_dir() && dsym.extension().is_some_and(|value| value == "dSYM"),
        "dSYM must be a .dSYM bundle directory"
    );
    let dwarf_dir = dsym.join("Contents/Resources/DWARF");
    let mut entries = tokio::fs::read_dir(&dwarf_dir)
        .await
        .context("dSYM bundle has no DWARF directory")?;
    let mut has_symbols = false;
    while let Some(entry) = entries.next_entry().await? {
        let metadata = entry.metadata().await?;
        if metadata.is_file() && metadata.len() > 0 {
            has_symbols = true;
            break;
        }
    }
    ensure!(has_symbols, "dSYM bundle has no nonempty DWARF file");
    let mut bytes = Vec::new();
    tokio::fs::File::open(&report)
        .await?
        .take((MAX_BYTES + 1) as u64)
        .read_to_end(&mut bytes)
        .await?;
    ensure!(
        bytes.len() <= MAX_BYTES,
        "crash report exceeds the 2 MiB limit"
    );
    validate_apple_text(&bytes)?;

    let deadline = Instant::now() + TIMEOUT;
    let mut select = Command::new("/usr/bin/xcode-select");
    select.arg("-p");
    let selected = capture(select, "xcode-select", deadline, 8192).await?;
    ensure!(
        selected.status.success(),
        "xcode-select could not locate the active Xcode"
    );
    let developer = PathBuf::from(
        std::str::from_utf8(&selected.stdout)
            .context("xcode-select returned a non-UTF-8 path")?
            .trim(),
    );
    let tool = tool_candidates(&developer)?
        .into_iter()
        .find(|path| path.is_file())
        .context("selected Xcode does not contain symbolicatecrash")?;
    let mut command = Command::new(&tool);
    command
        .args(tool_args(&report, &dsym))
        .env("DEVELOPER_DIR", &developer);
    let output = capture(command, "symbolicatecrash", deadline, MAX_BYTES).await?;
    ensure!(
        output.status.success(),
        "symbolicatecrash failed ({}); verify the Apple-text report and selected Xcode",
        output.status
    );
    ensure!(
        !output.stdout.is_empty(),
        "symbolicatecrash returned no report"
    );
    // Preserve warnings for the caller's review; they can explain unresolved
    // symbols even when the tool exits successfully. This is not an event log.
    let mut text = String::from_utf8(output.stdout)
        .context("symbolicatecrash returned non-UTF-8 report output")?;
    if !output.stderr.is_empty() {
        if !text.ends_with('\n') {
            text.push('\n');
        }
        text.push_str(
            &String::from_utf8(output.stderr)
                .context("symbolicatecrash returned non-UTF-8 warning output")?,
        );
    }
    ensure!(
        text.len() <= MAX_BYTES,
        "symbolication output exceeded the 2 MiB limit"
    );
    Ok(text)
}

fn validate_apple_text(bytes: &[u8]) -> Result<()> {
    let text = std::str::from_utf8(bytes).context("crash report must be UTF-8 Apple text")?;
    ensure!(!text.trim().is_empty(), "crash report is empty");
    ensure!(
        ["Process:", "Exception Type:", "Binary Images:"]
            .iter()
            .all(|prefix| text
                .lines()
                .any(|line| line.trim_start().starts_with(prefix))),
        "expected an Apple-text crash report with Process, Exception Type, and Binary Images sections; JSON .ips reports are not supported"
    );
    Ok(())
}

fn tool_candidates(developer: &Path) -> Result<[PathBuf; 2]> {
    ensure!(
        developer.is_absolute(),
        "xcode-select returned an invalid developer path"
    );
    let contents = developer
        .parent()
        .context("selected Xcode has no Contents directory")?;
    ensure!(
        developer
            .file_name()
            .is_some_and(|value| value == "Developer")
            && contents
                .file_name()
                .is_some_and(|value| value == "Contents"),
        "symbolication requires full Xcode; select its Contents/Developer directory instead of standalone Command Line Tools"
    );
    let framework = contents.join("SharedFrameworks/DVTFoundation.framework");
    Ok([
        framework.join("Versions/A/Resources/symbolicatecrash"),
        framework.join("Resources/symbolicatecrash"),
    ])
}

fn tool_args(report: &Path, dsym: &Path) -> [OsString; 3] {
    [
        "-d".into(),
        dsym.as_os_str().into(),
        report.as_os_str().into(),
    ]
}

async fn capture(
    command: Command,
    label: &str,
    deadline: Instant,
    limit: usize,
) -> Result<crate::process::Finished> {
    // The group is killed on timeout or when the containing server task is
    // dropped: symbolicatecrash can launch its own dwarfdump/atos subprocesses.
    let output = crate::process::run_bounded(
        command,
        crate::process::Sink::Capture(limit),
        crate::process::Sink::Capture(limit),
        deadline,
        None,
    )
    .await
    .map_err(|error| match error {
        crate::process::RunError::TimedOut | crate::process::RunError::Cancelled => {
            anyhow::anyhow!("{label}: symbolication exceeded its 60-second timeout")
        }
        crate::process::RunError::Failed(error) => {
            error.context(format!("{label} did not complete"))
        }
    })?;
    ensure!(
        output.stdout.len() + output.stderr.len() <= limit,
        "{label}: symbolication tool output exceeded its size limit"
    );
    Ok(output)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_empty_json_and_incomplete_reports() {
        assert!(validate_apple_text(b" \n").is_err());
        assert!(validate_apple_text(br#"{"incident":"example"}"#).is_err());
        assert!(validate_apple_text(b"Process: App\nException Type: EXC_BAD_ACCESS\n").is_err());
        assert!(
            validate_apple_text(
                b"Process: App [1]\nException Type: EXC_BAD_ACCESS\nBinary Images:\n"
            )
            .is_ok()
        );
    }
}
