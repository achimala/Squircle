use serde_json::Value;
use std::process::{Command, Output};

fn command() -> Command {
    let mut command = Command::new(env!("CARGO_BIN_EXE_squircle"));
    // Discovery and ordinary API requests must not depend on an installed agent
    // executable, shell startup file, or agent credentials.
    command.env("PATH", "");
    command.env_remove("SQUIRCLE_SERVER");
    command.env_remove("SQUIRCLE_DATA_DIR");
    command
}

fn json_result(output: &Output) -> Value {
    let result: Value = serde_json::from_slice(&output.stdout).unwrap_or_else(|error| {
        panic!(
            "invalid JSON result: {error}; stdout={:?}",
            String::from_utf8_lossy(&output.stdout)
        )
    });
    assert_eq!(result["schema_version"], 1);
    result
}

#[test]
fn non_utf8_arguments_report_an_error_instead_of_panicking() {
    use std::os::unix::ffi::OsStringExt;
    let output = command()
        .arg("--json")
        .arg(std::ffi::OsString::from_vec(vec![0xff]))
        .output()
        .unwrap();
    assert_eq!(output.status.code(), Some(2));
    assert_eq!(json_result(&output)["error"]["code"], "invalid_arguments");
}
