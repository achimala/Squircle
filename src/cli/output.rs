use super::*;

pub(super) fn print_result(value: &Value, machine: bool) {
    if machine {
        println!("{}", value);
    } else {
        println!("{}", serde_json::to_string_pretty(value).unwrap());
    }
}
