use std::borrow::Cow;
use std::env;
use std::fs;
use std::path::Path;
use std::process::{self, Command, ExitStatus};

const XCODE_PLACEHOLDERS: [&str; 2] = ["__BAZEL_XCODE_SDKROOT__", "__BAZEL_XCODE_DEVELOPER_DIR__"];

#[derive(Debug)]
struct RenameOp {
    src: String,
    dst: String,
    if_exists: bool,
}

fn main() {
    let raw_args: Vec<String> = env::args().skip(1).collect();
    let args = match expand_param_file(raw_args) {
        Ok(args) => args,
        Err(err) => {
            eprintln!("error: {err}");
            process::exit(1);
        }
    };

    let mut renames: Vec<RenameOp> = Vec::new();
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

    let debug = env::var_os("RULES_ADA_DEBUG").is_some();
    let needs_xcode = commands
        .iter()
        .any(|c| c.iter().any(|a| has_xcode_placeholder(a)));
    let xcode = if needs_xcode {
        resolve_xcode_placeholders()
    } else {
        XcodeEnv::default()
    };
    let xcode_subs = xcode.substitutions();

    for cmd_args in &commands {
        // Only pay for substitution when some argument actually carries a
        // placeholder; otherwise the original argv is passed through as-is.
        let argv: Cow<[String]> = if cmd_args.iter().any(|a| has_xcode_placeholder(a)) {
            let resolved: Vec<String> = cmd_args
                .iter()
                .map(|a| apply_xcode_placeholders(a, &xcode_subs))
                .collect();
            if let Some(arg) = resolved.iter().find(|a| has_xcode_placeholder(a)) {
                eprintln!(
                    "error: unresolved Xcode placeholder in argument: {arg}\n\
                     SDKROOT / DEVELOPER_DIR were not provided to this action and could not be \
                     derived (xcode-select / xcrun unavailable). This usually means no CC toolchain \
                     or apple_support environment was forwarded to the Ada action."
                );
                process::exit(1);
            }
            Cow::Owned(resolved)
        } else {
            Cow::Borrowed(cmd_args)
        };
        let program = &argv[0];
        let mut cmd = Command::new(program);
        cmd.args(&argv[1..]);
        if let Some(v) = &xcode.sdkroot {
            cmd.env("SDKROOT", v);
        }
        if let Some(v) = &xcode.developer_dir {
            cmd.env("DEVELOPER_DIR", v);
        }
        if debug {
            eprintln!("{cmd:#?}");
        }

        match cmd.status() {
            Ok(s) if s.success() => {}
            Ok(s) => process::exit(exit_code_for(program, s)),
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

/// Map a failed child status to the wrapper's exit code. A child killed by a
/// signal is reported and mapped to the conventional 128+signal.
#[cfg(unix)]
fn exit_code_for(program: &str, status: ExitStatus) -> i32 {
    use std::os::unix::process::ExitStatusExt;
    if let Some(sig) = status.signal() {
        eprintln!("error: {program} terminated by signal {sig}");
        return 128 + sig;
    }
    status.code().unwrap_or(1)
}

#[cfg(not(unix))]
fn exit_code_for(_program: &str, status: ExitStatus) -> i32 {
    status.code().unwrap_or(1)
}

/// Expand a Bazel param file. `Args.use_param_file` replaces the whole
/// argument list with a single `@<path>` argument, so expansion happens only
/// when that is the entire argv; `@`-prefixed arguments in any other position
/// are left alone. The file uses the "multiline" format: one argument per
/// line, no quoting.
fn expand_param_file(args: Vec<String>) -> Result<Vec<String>, String> {
    let path = match args.as_slice() {
        [only] => only.strip_prefix('@').map(str::to_owned),
        _ => None,
    };
    let Some(path) = path else {
        return Ok(args);
    };
    let bytes = fs::read(&path).map_err(|e| format!("cannot read param file {path}: {e}"))?;
    let content = String::from_utf8_lossy(&bytes);
    Ok(content.lines().map(str::to_owned).collect())
}

/// Strip the `--  BEGIN Object file/option list` comment block from a
/// gnatbind-generated .adb file. This block embeds absolute paths to the
/// toolchain repo which break remote cache determinism.
fn do_scrub_binder(path: &str) -> Result<(), String> {
    let content = fs::read(path).map_err(|e| format!("read: {e}"))?;
    let mut out = Vec::with_capacity(content.len());
    let mut inside_block = false;

    // Each line keeps its own newline (or lack of one), so the file is
    // otherwise copied byte-for-byte.
    for line in content.split_inclusive(|&b| b == b'\n') {
        let trimmed = line.trim_ascii();
        if trimmed == b"--  BEGIN Object file/option list" {
            inside_block = true;
            continue;
        }
        if trimmed == b"--  END Object file/option list" {
            inside_block = false;
            continue;
        }
        if inside_block {
            continue;
        }
        out.extend_from_slice(line);
    }

    fs::write(path, out).map_err(|e| format!("write: {e}"))
}

/// Normalize timestamps in ALI `D` lines to a fixed value. GNAT embeds
/// source file mtimes which vary across machines and after git operations.
fn do_scrub_ali(path: &str) -> Result<(), String> {
    let content = fs::read(path).map_err(|e| format!("read: {e}"))?;
    let mut out = Vec::with_capacity(content.len());

    for line in content.split_inclusive(|&b| b == b'\n') {
        if line.starts_with(b"D ") {
            out.extend_from_slice(&scrub_d_line_bytes(line));
        } else {
            out.extend_from_slice(line);
        }
    }

    fs::write(path, out).map_err(|e| format!("write: {e}"))
}

/// Replace the 14-digit timestamp in an ALI D line with zeros.
/// Format: `D <filename>\t\t<14-digit-timestamp> <checksum> <unit>`
/// The filename may contain spaces, so the timestamp is located as the first
/// whitespace-delimited token after the `D ` prefix that is exactly 14 digits.
/// A trailing line terminator, if present, is preserved.
fn scrub_d_line_bytes(line: &[u8]) -> Vec<u8> {
    let is_sep = |b: u8| matches!(b, b'\t' | b' ' | b'\r' | b'\n');
    let mut i = 2; // skip "D "
    while i < line.len() {
        // Skip whitespace between tokens.
        while i < line.len() && is_sep(line[i]) {
            i += 1;
        }
        let start = i;
        while i < line.len() && !is_sep(line[i]) {
            i += 1;
        }
        let token = &line[start..i];
        if token.len() == 14 && token.iter().all(u8::is_ascii_digit) {
            let mut result = Vec::with_capacity(line.len());
            result.extend_from_slice(&line[..start]);
            result.extend_from_slice(b"00000000000000");
            result.extend_from_slice(&line[i..]);
            return result;
        }
    }
    line.to_vec()
}

#[derive(Default)]
struct XcodeEnv {
    sdkroot: Option<String>,
    developer_dir: Option<String>,
}

impl XcodeEnv {
    /// `(placeholder, value)` pairs, in `XCODE_PLACEHOLDERS` order, for the
    /// values that could be resolved.
    fn substitutions(&self) -> Vec<(&'static str, &str)> {
        XCODE_PLACEHOLDERS
            .into_iter()
            .zip([self.sdkroot.as_deref(), self.developer_dir.as_deref()])
            .filter_map(|(placeholder, value)| Some((placeholder, value?)))
            .collect()
    }
}

fn has_xcode_placeholder(arg: &str) -> bool {
    XCODE_PLACEHOLDERS.iter().any(|p| arg.contains(p))
}

fn run_for_stdout(program: &str, args: &[&str]) -> Option<String> {
    let out = Command::new(program).args(args).output().ok()?;
    if !out.status.success() {
        return None;
    }
    let s = String::from_utf8_lossy(&out.stdout).trim().to_string();
    (!s.is_empty()).then_some(s)
}

fn resolve_xcode_placeholders() -> XcodeEnv {
    let platform = env::var("APPLE_SDK_PLATFORM")
        .ok()
        .filter(|s| !s.is_empty());

    let developer_dir = env::var("DEVELOPER_DIR")
        .ok()
        .filter(|s| !s.is_empty())
        .or_else(|| run_for_stdout("xcode-select", &["-p"]));

    let sdkroot = env::var("SDKROOT")
        .ok()
        .filter(|s| !s.is_empty())
        .or_else(|| {
            let sdk = platform.as_deref().unwrap_or("MacOSX").to_lowercase();
            run_for_stdout("xcrun", &["--sdk", &sdk, "--show-sdk-path"])
        })
        .or_else(|| {
            let platform = platform.as_deref()?;
            let version = env::var("APPLE_SDK_VERSION_OVERRIDE").ok()?;
            let dev_dir = developer_dir.as_deref()?;
            Some(format!(
                "{dev_dir}/Platforms/{platform}.platform/Developer/SDKs/{platform}{version}.sdk"
            ))
        });

    XcodeEnv {
        sdkroot,
        developer_dir,
    }
}

fn apply_xcode_placeholders(arg: &str, subs: &[(&str, &str)]) -> String {
    let mut result = arg.to_string();
    for (placeholder, value) in subs {
        result = result.replace(placeholder, value);
    }
    result
}

/// Split the command tail on `++` separators, dropping empty commands.
fn split_commands(args: &[String]) -> Vec<&[String]> {
    args.split(|a| a == "++")
        .filter(|c| !c.is_empty())
        .collect()
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

    fn strings(items: &[&str]) -> Vec<String> {
        items.iter().map(|s| s.to_string()).collect()
    }

    fn scrub_d_line(line: &str) -> String {
        String::from_utf8_lossy(&scrub_d_line_bytes(line.as_bytes())).into_owned()
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
    fn scrub_d_line_handles_filename_with_spaces() {
        let input = "D my file.ads\t\t20250419085653 70765b54 my_file%s";
        let result = scrub_d_line(input);
        assert_eq!(result, "D my file.ads\t\t00000000000000 70765b54 my_file%s");
    }

    #[test]
    fn scrub_d_line_preserves_non_d_lines() {
        assert_eq!(scrub_d_line("D "), "D ");
        assert_eq!(scrub_d_line("D x"), "D x");
    }

    #[test]
    fn scrub_d_line_keeps_line_terminator() {
        assert_eq!(
            scrub_d_line("D foo.adb\t\t20260515130356 6b54befe foo%b\n"),
            "D foo.adb\t\t00000000000000 6b54befe foo%b\n"
        );
        assert_eq!(
            scrub_d_line("D foo.adb\t\t20260515130356\r\n"),
            "D foo.adb\t\t00000000000000\r\n"
        );
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
    fn scrub_binder_preserves_missing_final_newline() {
        let content = "\
package body ada_main is
--  BEGIN Object file/option list
   --   -lgnat
--  END Object file/option list
end ada_main;";
        let path = tmp_file("scrub_binder_no_final_newline.adb", content);
        do_scrub_binder(&path).unwrap();
        assert_eq!(
            fs::read_to_string(&path).unwrap(),
            "package body ada_main is\nend ada_main;"
        );
    }

    #[test]
    fn scrub_binder_tolerates_non_utf8() {
        let dir = std::path::PathBuf::from(env::var("TEST_TMPDIR").unwrap());
        let path = dir.join("scrub_binder_non_utf8.adb");
        let content = b"-- caf\xe9\npackage body ada_main is\nend ada_main;\n";
        fs::write(&path, content).unwrap();
        do_scrub_binder(path.to_str().unwrap()).unwrap();
        assert_eq!(fs::read(&path).unwrap(), content);
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

    #[test]
    fn scrub_ali_preserves_missing_final_newline() {
        let content = "V \"GNAT Lib v15\"\nD foo.ads\t\t20260515143844 bc4e36d2 foo%s";
        let path = tmp_file("scrub_ali_no_final_newline.ali", content);
        do_scrub_ali(&path).unwrap();
        assert_eq!(
            fs::read_to_string(&path).unwrap(),
            "V \"GNAT Lib v15\"\nD foo.ads\t\t00000000000000 bc4e36d2 foo%s"
        );
    }

    #[test]
    fn param_file_expands_wrapper_flags_and_command() {
        let params = tmp_file(
            "wrapper.params",
            "--rename\nfoo.ali\nout/foo.ali\n--scrub-ali\nout/foo.ali\n--\ngcc\n-c\nfoo.adb\n++\nar\nrcs\n",
        );
        let args = strings(&[&format!("@{params}")]);
        let expanded = expand_param_file(args).unwrap();
        assert_eq!(
            expanded,
            strings(&[
                "--rename",
                "foo.ali",
                "out/foo.ali",
                "--scrub-ali",
                "out/foo.ali",
                "--",
                "gcc",
                "-c",
                "foo.adb",
                "++",
                "ar",
                "rcs",
            ])
        );
    }

    #[test]
    fn param_file_only_expanded_as_sole_argument() {
        let params = tmp_file("partial.params", "-I include dir\n-O2\n");
        // `@file` mixed with other arguments is not a Bazel param file.
        let args = strings(&["--", "gcc", &format!("@{params}"), "@"]);
        assert_eq!(expand_param_file(args.clone()).unwrap(), args);
        // Nor is a multi-argument argv consisting only of `@` entries.
        let args = strings(&[&format!("@{params}"), &format!("@{params}")]);
        assert_eq!(expand_param_file(args.clone()).unwrap(), args);
    }

    #[test]
    fn param_file_unreadable_is_an_error() {
        let err = expand_param_file(strings(&["@/nonexistent/x.params"])).unwrap_err();
        assert!(err.contains("/nonexistent/x.params"), "{err}");
        assert!(expand_param_file(strings(&["@"])).is_err());
    }

    #[test]
    fn param_file_empty_and_crlf() {
        let empty = tmp_file("empty.params", "");
        assert_eq!(
            expand_param_file(strings(&[&format!("@{empty}")])).unwrap(),
            Vec::<String>::new()
        );
        let crlf = tmp_file("crlf.params", "a\r\nb\r\n");
        assert_eq!(
            expand_param_file(strings(&[&format!("@{crlf}")])).unwrap(),
            strings(&["a", "b"])
        );
    }

    #[test]
    fn xcode_substitution_and_detection() {
        let xcode = XcodeEnv {
            sdkroot: Some("/sdk".to_string()),
            developer_dir: None,
        };
        let subs = xcode.substitutions();
        assert_eq!(subs, vec![("__BAZEL_XCODE_SDKROOT__", "/sdk")]);
        assert_eq!(
            apply_xcode_placeholders("--sysroot=__BAZEL_XCODE_SDKROOT__", &subs),
            "--sysroot=/sdk"
        );
        let leftover = apply_xcode_placeholders("__BAZEL_XCODE_DEVELOPER_DIR__/x", &subs);
        assert!(has_xcode_placeholder(&leftover));
        assert!(!has_xcode_placeholder("--sysroot=/sdk"));
    }

    #[test]
    fn split_commands_on_separator() {
        let args = strings(&["++", "gcc", "-c", "++", "++", "ar", "rcs", "++"]);
        let commands = split_commands(&args);
        assert_eq!(commands, vec![&args[1..3], &args[5..7]]);
    }
}
