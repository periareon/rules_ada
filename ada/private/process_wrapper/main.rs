use std::env;
use std::fs;
use std::path::Path;
use std::process::{self, Command};

#[derive(Debug)]
struct RenameOp {
    src: String,
    dst: String,
    if_exists: bool,
}

fn main() {
    let args: Vec<String> = env::args().skip(1).collect();

    let mut renames: Vec<RenameOp> = Vec::new();
    let mut env_vars: Vec<(String, String)> = Vec::new();
    let mut scrub_binder: Vec<String> = Vec::new();
    let mut scrub_ali: Vec<String> = Vec::new();
    let mut idx = 0;

    while idx < args.len() {
        match args[idx].as_str() {
            "--rename" => {
                if idx + 2 >= args.len() {
                    eprintln!("error: --rename requires SRC and DST arguments");
                    process::exit(1);
                }
                renames.push(RenameOp {
                    src: args[idx + 1].clone(),
                    dst: args[idx + 2].clone(),
                    if_exists: false,
                });
                idx += 3;
            }
            "--rename-if-exists" => {
                if idx + 2 >= args.len() {
                    eprintln!("error: --rename-if-exists requires SRC and DST arguments");
                    process::exit(1);
                }
                renames.push(RenameOp {
                    src: args[idx + 1].clone(),
                    dst: args[idx + 2].clone(),
                    if_exists: true,
                });
                idx += 3;
            }
            "--env" => {
                if idx + 1 >= args.len() {
                    eprintln!("error: --env requires KEY=VALUE argument");
                    process::exit(1);
                }
                let kv = &args[idx + 1];
                if let Some(eq_pos) = kv.find('=') {
                    env_vars.push((kv[..eq_pos].to_string(), kv[eq_pos + 1..].to_string()));
                } else {
                    eprintln!("error: --env value must contain '=': {kv}");
                    process::exit(1);
                }
                idx += 2;
            }
            "--scrub-binder" => {
                if idx + 1 >= args.len() {
                    eprintln!("error: --scrub-binder requires a file path");
                    process::exit(1);
                }
                scrub_binder.push(args[idx + 1].clone());
                idx += 2;
            }
            "--scrub-ali" => {
                if idx + 1 >= args.len() {
                    eprintln!("error: --scrub-ali requires a file path");
                    process::exit(1);
                }
                scrub_ali.push(args[idx + 1].clone());
                idx += 2;
            }
            "--" => {
                idx += 1;
                break;
            }
            other => {
                eprintln!("error: unexpected flag before '--': {other}");
                process::exit(1);
            }
        }
    }

    if idx >= args.len() {
        eprintln!("error: no command specified after '--'");
        process::exit(1);
    }

    let commands = split_commands(&args[idx..]);
    if commands.is_empty() {
        eprintln!("error: no command specified after '--'");
        process::exit(1);
    }

    let xcode_subs = resolve_xcode_placeholders();

    for cmd_args in &commands {
        let resolved: Vec<String> = cmd_args
            .iter()
            .map(|a| apply_xcode_placeholders(a, &xcode_subs))
            .collect();
        let program = &resolved[0];
        let status = Command::new(program)
            .args(&resolved[1..])
            .envs(env_vars.iter().map(|(k, v)| (k.as_str(), v.as_str())))
            .status();

        match status {
            Ok(s) if s.success() => {}
            Ok(s) => process::exit(s.code().unwrap_or(1)),
            Err(err) => {
                eprintln!("error: failed to execute {program}: {err}");
                process::exit(1);
            }
        }
    }

    for op in &renames {
        let src = Path::new(&op.src);
        if op.if_exists && !src.exists() {
            continue;
        }
        if !src.exists() {
            eprintln!("error: --rename source does not exist: {}", op.src);
            process::exit(1);
        }
        if let Some(parent) = Path::new(&op.dst).parent() {
            if !parent.exists() {
                if let Err(err) = fs::create_dir_all(parent) {
                    eprintln!(
                        "error: failed to create directory {}: {err}",
                        parent.display()
                    );
                    process::exit(1);
                }
            }
        }
        if let Err(err) = fs::rename(&op.src, &op.dst) {
            eprintln!("error: rename {} -> {}: {err}", op.src, op.dst);
            process::exit(1);
        }
    }

    for path in &scrub_binder {
        if let Err(err) = do_scrub_binder(path) {
            eprintln!("error: --scrub-binder {path}: {err}");
            process::exit(1);
        }
    }

    for path in &scrub_ali {
        if let Err(err) = do_scrub_ali(path) {
            eprintln!("error: --scrub-ali {path}: {err}");
            process::exit(1);
        }
    }
}

/// Strip the `--  BEGIN Object file/option list` comment block from a
/// gnatbind-generated .adb file. This block embeds absolute paths to the
/// toolchain repo which break remote cache determinism.
fn do_scrub_binder(path: &str) -> Result<(), String> {
    let content = fs::read_to_string(path).map_err(|e| format!("read: {e}"))?;
    let mut out = String::with_capacity(content.len());
    let mut inside_block = false;

    for line in content.lines() {
        let trimmed = line.trim();
        if trimmed == "--  BEGIN Object file/option list" {
            inside_block = true;
            continue;
        }
        if trimmed == "--  END Object file/option list" {
            inside_block = false;
            continue;
        }
        if inside_block {
            continue;
        }
        out.push_str(line);
        out.push('\n');
    }

    fs::write(path, out).map_err(|e| format!("write: {e}"))
}

/// Normalize timestamps in ALI `D` lines to a fixed value. GNAT embeds
/// source file mtimes which vary across machines and after git operations.
fn do_scrub_ali(path: &str) -> Result<(), String> {
    let content = fs::read_to_string(path).map_err(|e| format!("read: {e}"))?;
    let mut out = String::with_capacity(content.len());

    for line in content.lines() {
        if line.starts_with("D ") {
            out.push_str(&scrub_d_line(line));
        } else {
            out.push_str(line);
        }
        out.push('\n');
    }

    fs::write(path, out).map_err(|e| format!("write: {e}"))
}

/// Replace the 14-digit timestamp in an ALI D line with zeros.
/// Format: `D <filename>\t\t<14-digit-timestamp> <checksum> <unit>`
fn scrub_d_line(line: &str) -> String {
    let bytes = line.as_bytes();
    let mut i = 2; // skip "D "

    // Skip the filename (non-whitespace)
    while i < bytes.len() && bytes[i] != b'\t' && bytes[i] != b' ' {
        i += 1;
    }
    // Skip whitespace between filename and timestamp
    while i < bytes.len() && (bytes[i] == b'\t' || bytes[i] == b' ') {
        i += 1;
    }
    // i now points to the start of the timestamp
    let ts_start = i;
    // Check if next 14 chars are digits
    let mut ts_end = ts_start;
    while ts_end < bytes.len() && bytes[ts_end].is_ascii_digit() {
        ts_end += 1;
    }

    if ts_end - ts_start == 14 {
        let mut result = String::with_capacity(line.len());
        result.push_str(&line[..ts_start]);
        result.push_str("00000000000000");
        result.push_str(&line[ts_end..]);
        result
    } else {
        line.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp_file(name: &str, content: &str) -> String {
        let dir = std::path::PathBuf::from(env::var("TEST_TMPDIR").unwrap());
        let path = dir.join(name);
        fs::write(&path, content).unwrap();
        path.to_str().unwrap().to_string()
    }

    #[test]
    fn scrub_d_line_replaces_timestamp() {
        let input = "D foo.adb\t\t20260515130356 6b54befe foo%b";
        let result = scrub_d_line(input);
        assert_eq!(result, "D foo.adb\t\t00000000000000 6b54befe foo%b");
    }

    #[test]
    fn scrub_d_line_handles_single_tab() {
        let input = "D system.ads\t20250419085653 70765b54 system%s";
        let result = scrub_d_line(input);
        assert_eq!(result, "D system.ads\t00000000000000 70765b54 system%s");
    }

    #[test]
    fn scrub_d_line_preserves_non_d_lines() {
        assert_eq!(scrub_d_line("D "), "D ");
        assert_eq!(scrub_d_line("D x"), "D x");
    }

    #[test]
    fn scrub_d_line_preserves_checksum() {
        let input = "D a-textio.ads\t\t20250419085653 34ef47de ada.text_io%s";
        let result = scrub_d_line(input);
        assert!(result.contains("34ef47de"));
        assert!(result.contains("00000000000000"));
        assert!(!result.contains("20250419085653"));
    }

    #[test]
    fn scrub_binder_strips_object_list() {
        let content = "\
package body ada_main is
end ada_main;
--  BEGIN Object file/option list
   --   -L/absolute/path/to/toolchain/adalib/
   --   -Lbazel-out/config/bin/pkg/_objs/foo/body/
   --   -static
   --   -lgnat
--  END Object file/option list
";
        let path = tmp_file("scrub_binder_strips.adb", content);
        do_scrub_binder(&path).unwrap();
        let result = fs::read_to_string(&path).unwrap();

        assert!(result.contains("package body ada_main is"));
        assert!(result.contains("end ada_main;"));
        assert!(!result.contains("BEGIN Object file"));
        assert!(!result.contains("END Object file"));
        assert!(!result.contains("/absolute/path"));
        assert!(!result.contains("-lgnat"));
    }

    #[test]
    fn scrub_binder_preserves_file_without_block() {
        let content = "package body ada_main is\nend ada_main;\n";
        let path = tmp_file("scrub_binder_preserves.adb", content);
        do_scrub_binder(&path).unwrap();
        let result = fs::read_to_string(&path).unwrap();

        assert_eq!(result, content);
    }

    #[test]
    fn scrub_ali_normalizes_all_d_lines() {
        let content = "\
V \"GNAT Lib v15\"
P ZX

U foo%b\t\tfoo.adb\t\t12345678 NE OO PK

D foo.ads\t\t20260515143844 bc4e36d2 foo%s
D foo.adb\t\t20260515143844 0f84a327 foo%b
D system.ads\t\t20250419085653 70765b54 system%s
G a e
";
        let path = tmp_file("scrub_ali_test.ali", content);
        do_scrub_ali(&path).unwrap();
        let result = fs::read_to_string(&path).unwrap();

        for line in result.lines() {
            if line.starts_with("D ") {
                assert!(
                    line.contains("00000000000000"),
                    "D line should have zeroed timestamp: {line}"
                );
                assert!(
                    !line.contains("20260515"),
                    "D line should not have original timestamp: {line}"
                );
            }
        }
        assert!(result.contains("V \"GNAT Lib v15\""));
        assert!(result.contains("U foo%b"));
        assert!(result.contains("G a e"));
        assert!(result.contains("bc4e36d2"));
        assert!(result.contains("0f84a327"));
    }
}

fn resolve_xcode_placeholders() -> Vec<(&'static str, String)> {
    let mut subs = Vec::new();
    if let Ok(v) = env::var("SDKROOT") {
        subs.push(("__BAZEL_XCODE_SDKROOT__", v));
    }
    if let Ok(v) = env::var("DEVELOPER_DIR") {
        subs.push(("__BAZEL_XCODE_DEVELOPER_DIR__", v));
    }
    subs
}

fn apply_xcode_placeholders(arg: &str, subs: &[(&str, String)]) -> String {
    let mut result = arg.to_string();
    for (placeholder, value) in subs {
        result = result.replace(placeholder, value);
    }
    result
}

fn split_commands(args: &[String]) -> Vec<Vec<&String>> {
    let mut commands: Vec<Vec<&String>> = Vec::new();
    let mut current: Vec<&String> = Vec::new();

    for arg in args {
        if arg == "++" {
            if !current.is_empty() {
                commands.push(current);
                current = Vec::new();
            }
        } else {
            current.push(arg);
        }
    }
    if !current.is_empty() {
        commands.push(current);
    }
    commands
}
