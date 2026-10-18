use super::*;

/// clap owns the public command tree and help metadata. Discovery walks that
/// same tree so adding a command cannot silently omit it from capabilities.
pub(super) fn operations() -> Vec<String> {
    fn collect(command: &clap::Command, prefix: &str, out: &mut Vec<String>) {
        for child in command.get_subcommands().filter(|c| !c.is_hide_set()) {
            let name = if prefix.is_empty() {
                child.get_name().to_owned()
            } else {
                format!("{prefix}.{}", child.get_name())
            };
            if child.has_subcommands() {
                collect(child, &name, out);
            } else {
                out.push(name);
            }
        }
    }
    let mut operations = Vec::new();
    collect(&Cli::command(), "", &mut operations);
    operations
}
