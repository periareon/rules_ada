use flate2::read::GzDecoder;
use runfiles::{rlocation, Runfiles};
use serde::Deserialize;
use std::collections::HashMap;
use std::env;
use std::fs;
use std::io::{BufRead, BufReader, BufWriter, Write};
use std::path::{Path, PathBuf};
use std::process::{self, Command};
use walkdir::WalkDir;

#[derive(Deserialize)]
struct GcovData {
    #[serde(default)]
    files: Vec<GcovFile>,
}

#[derive(Deserialize)]
struct GcovFile {
    file: String,
    #[serde(default)]
    functions: Vec<GcovFunction>,
    #[serde(default)]
    lines: Vec<GcovLine>,
}

#[derive(Deserialize)]
struct GcovFunction {
    start_line: u64,
    demangled_name: String,
    execution_count: u64,
}

#[derive(Deserialize)]
struct GcovLine {
    line_number: u64,
    count: u64,
}

fn main() {
    if let Err(msg) = run() {
        eprintln!("collect_ada_coverage: error: {msg}");
        process::exit(1);
    }
}

fn env_nonempty(name: &str) -> Option<String> {
    env::var(name).ok().filter(|s| !s.is_empty())
}

fn run() -> Result<(), String> {
    let coverage_dir =
        PathBuf::from(env_nonempty("COVERAGE_DIR").ok_or("COVERAGE_DIR is not set or empty")?);
    let coverage_manifest =
        env_nonempty("COVERAGE_MANIFEST").ok_or("COVERAGE_MANIFEST is not set or empty")?;
    let workspace = env_nonempty("TEST_WORKSPACE").unwrap_or_else(|| "_main".to_string());

    let gcov_tool = resolve_gcov(&workspace)?;

    let root = env::var("ROOT").unwrap_or_default();
    let output_path = env_nonempty("COVERAGE_OUTPUT_FILE")
        .map(PathBuf::from)
        .unwrap_or_else(|| coverage_dir.join("_ada_coverage.dat"));

    let manifest = fs::File::open(&coverage_manifest)
        .map_err(|e| format!("cannot read COVERAGE_MANIFEST {coverage_manifest}: {e}"))?;

    let output = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&output_path)
        .map_err(|e| format!("cannot open output file {}: {e}", output_path.display()))?;
    let mut output = BufWriter::new(output);

    let gcda_files = collect_gcda_files(&coverage_dir);

    for line in BufReader::new(manifest).lines() {
        let line =
            line.map_err(|e| format!("cannot read COVERAGE_MANIFEST {coverage_manifest}: {e}"))?;
        if !line.ends_with(".gcno") {
            continue;
        }

        let gcno_entry = normalize_separators(&line);
        let stem = match Path::new(&gcno_entry).file_stem().and_then(|s| s.to_str()) {
            Some(s) if !s.is_empty() => s.to_owned(),
            _ => continue,
        };

        let gcda_file = match find_gcda(&gcda_files, &gcno_entry, &stem) {
            Some(f) => f,
            None => continue,
        };
        let gcda_dir = match gcda_file.parent() {
            Some(d) => d.to_path_buf(),
            None => continue,
        };

        let gcno_source = Path::new(&root).join(&line);
        if !gcno_source.is_file() {
            eprintln!(
                "collect_ada_coverage: warning: gcno file {} not found; skipping",
                gcno_source.display()
            );
            continue;
        }
        let gcno_dest = gcda_dir.join(format!("{stem}.gcno"));
        if let Err(e) = fs::copy(&gcno_source, &gcno_dest) {
            eprintln!(
                "collect_ada_coverage: warning: cannot copy {} to {}: {e}; skipping",
                gcno_source.display(),
                gcno_dest.display()
            );
            continue;
        }

        let status = Command::new(&gcov_tool)
            .args(["-i", "-b", "-o"])
            .arg(&gcda_dir)
            .arg(gcda_file)
            .current_dir(&coverage_dir)
            .status();
        match status {
            Ok(s) if s.success() => {}
            Ok(s) => eprintln!(
                "collect_ada_coverage: warning: {} failed on {} ({s}); skipping",
                gcov_tool.display(),
                gcda_file.display()
            ),
            Err(e) => eprintln!(
                "collect_ada_coverage: warning: cannot run {} on {}: {e}; skipping",
                gcov_tool.display(),
                gcda_file.display()
            ),
        }

        process_gcov_outputs(&coverage_dir, &workspace, &mut output);
    }

    output
        .flush()
        .map_err(|e| format!("cannot write output file {}: {e}", output_path.display()))
}

/// Convert every `*.gcov.json.gz` that gcov left in `coverage_dir` to LCOV,
/// then delete gcov's intermediate files.
fn process_gcov_outputs(coverage_dir: &Path, workspace: &str, output: &mut impl Write) {
    let entries = match fs::read_dir(coverage_dir) {
        Ok(entries) => entries,
        Err(e) => {
            eprintln!(
                "collect_ada_coverage: warning: cannot read {}: {e}",
                coverage_dir.display()
            );
            return;
        }
    };
    for entry in entries.flatten() {
        let path = entry.path();
        let name = match path.file_name().and_then(|n| n.to_str()) {
            Some(n) => n.to_owned(),
            None => continue,
        };
        if name.ends_with(".gcov.json.gz") {
            if let Err(e) = gcov_to_lcov(&path, workspace, output) {
                eprintln!(
                    "collect_ada_coverage: warning: cannot convert {}: {e}",
                    path.display()
                );
            }
        } else if !name.ends_with(".gcov") {
            continue;
        }
        if let Err(e) = fs::remove_file(&path) {
            eprintln!(
                "collect_ada_coverage: warning: cannot remove {}: {e}",
                path.display()
            );
        }
    }
}

/// Locate the toolchain's gcov through the runfiles of the test. ADA_GCOV_PATH
/// is a short path (possibly `..`-bearing for external repos), which is turned
/// into an rlocation key first.
fn resolve_gcov(workspace: &str) -> Result<PathBuf, String> {
    let gcov = env_nonempty("ADA_GCOV_PATH")
        .ok_or("ADA_GCOV_PATH is not set; the Ada toolchain provides no gcov")?;
    let key = normalize_runfiles_key(workspace, &gcov);
    let runfiles = Runfiles::create()
        .map_err(|e| format!("cannot locate runfiles to resolve gcov ({gcov}): {e}"))?;
    rlocation!(runfiles, &key)
        .filter(|p| is_executable(p))
        .ok_or_else(|| {
            format!("gcov executable not found in runfiles (ADA_GCOV_PATH={gcov}, key={key})")
        })
}

/// Build the runfiles key for `short_path` relative to `workspace`, collapsing
/// `..` segments (e.g. `_main/../+repo/bin/gcov` -> `+repo/bin/gcov`).
fn normalize_runfiles_key(workspace: &str, short_path: &str) -> String {
    let joined = format!("{workspace}/{}", normalize_separators(short_path));
    let mut parts: Vec<&str> = Vec::new();
    for part in joined.split('/') {
        match part {
            "" | "." => {}
            ".." => {
                parts.pop();
            }
            other => parts.push(other),
        }
    }
    parts.join("/")
}

#[cfg(unix)]
fn is_executable(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    fs::metadata(path)
        .map(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
        .unwrap_or(false)
}

#[cfg(not(unix))]
fn is_executable(path: &Path) -> bool {
    path.is_file()
}

/// gcda files under `dir`, keyed by basename.
type GcdaIndex = HashMap<String, Vec<PathBuf>>;

fn collect_gcda_files(dir: &Path) -> GcdaIndex {
    index_gcda_files(
        WalkDir::new(dir)
            .into_iter()
            .filter_map(|e| e.ok())
            .filter(|e| e.file_type().is_file())
            .map(|e| e.into_path()),
    )
}

fn index_gcda_files(paths: impl IntoIterator<Item = PathBuf>) -> GcdaIndex {
    let mut index = GcdaIndex::new();
    for path in paths {
        if let Some(name) = path.file_name().and_then(|n| n.to_str()) {
            if name.ends_with(".gcda") {
                index.entry(name.to_owned()).or_default().push(path);
            }
        }
    }
    index
}

fn normalize_separators(path: &str) -> String {
    path.replace('\\', "/")
}

/// True when the trailing components of `path` equal the `/`-separated
/// `suffix`, component by component.
fn path_has_suffix(path: &Path, suffix: &str) -> bool {
    let mut components = path.components().rev();
    suffix
        .rsplit('/')
        .all(|part| components.next().is_some_and(|c| c.as_os_str() == part))
}

/// Pick the gcda matching a gcno manifest entry. With GCOV_PREFIX_STRIP=0 the
/// gcda tree mirrors the object path under a sandbox prefix, and gcno/gcda for
/// rule-produced files always share the `_objs/<name>/body/` directory, so the
/// gcda must end with `<gcno dir>/<stem>.gcda`. Anything else is a miss.
fn find_gcda<'a>(gcda_files: &'a GcdaIndex, gcno_entry: &str, stem: &str) -> Option<&'a Path> {
    let gcda_name = format!("{stem}.gcda");
    let suffix = match gcno_entry.rsplit_once('/') {
        Some((dir, _)) => format!("{dir}/{gcda_name}"),
        None => gcda_name.clone(),
    };
    let candidates = gcda_files.get(&gcda_name).map_or(&[][..], Vec::as_slice);
    let found = candidates
        .iter()
        .map(PathBuf::as_path)
        .find(|p| path_has_suffix(p, &suffix));
    if found.is_none() {
        eprintln!(
            "collect_ada_coverage: note: no gcda ending with {suffix} for {gcno_entry} ({} named {gcda_name}); skipping",
            candidates.len()
        );
    }
    found
}

fn is_absolute_path(path: &str) -> bool {
    let b = path.as_bytes();
    path.starts_with('/')
        || (b.len() >= 3 && b[0].is_ascii_alphabetic() && b[1] == b':' && b[2] == b'/')
}

/// Turn a gcov-reported source path into a workspace-relative `/`-separated
/// path, or None if it should be omitted (external repos, unknown files).
fn sanitize_path(path: &str, workspace: &str) -> Option<String> {
    if path == "<unknown>" || path.is_empty() {
        return None;
    }
    let path = normalize_separators(path);
    let rel = if is_absolute_path(&path) {
        [workspace, "_main"].into_iter().find_map(|ws| {
            let needle = format!("/execroot/{ws}/");
            path.find(&needle).map(|idx| &path[idx + needle.len()..])
        })?
    } else {
        path.as_str()
    };
    if rel.starts_with("external/") {
        None
    } else {
        Some(rel.to_string())
    }
}

fn gcov_to_lcov(gz_path: &Path, workspace: &str, output: &mut impl Write) -> Result<(), String> {
    let file = fs::File::open(gz_path).map_err(|e| format!("open: {e}"))?;
    let decoder = GzDecoder::new(file);
    let data: GcovData =
        serde_json::from_reader(decoder).map_err(|e| format!("invalid gcov JSON: {e}"))?;
    write_lcov(&data, workspace, output).map_err(|e| format!("write LCOV output: {e}"))
}

fn write_lcov(data: &GcovData, workspace: &str, output: &mut impl Write) -> std::io::Result<()> {
    for file_data in &data.files {
        let sf = match sanitize_path(&file_data.file, workspace) {
            Some(p) => p,
            None => continue,
        };
        writeln!(output, "SF:{sf}")?;
        for func in &file_data.functions {
            writeln!(output, "FN:{},{}", func.start_line, func.demangled_name)?;
        }
        for func in &file_data.functions {
            writeln!(
                output,
                "FNDA:{},{}",
                func.execution_count, func.demangled_name
            )?;
        }
        writeln!(output, "FNF:{}", file_data.functions.len())?;
        let fnh = file_data
            .functions
            .iter()
            .filter(|f| f.execution_count > 0)
            .count();
        writeln!(output, "FNH:{fnh}")?;
        for line in &file_data.lines {
            writeln!(output, "DA:{},{}", line.line_number, line.count)?;
        }
        writeln!(output, "LF:{}", file_data.lines.len())?;
        let lh = file_data.lines.iter().filter(|l| l.count > 0).count();
        writeln!(output, "LH:{lh}")?;
        writeln!(output, "end_of_record")?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sanitize_relative_and_external() {
        assert_eq!(
            sanitize_path("tests/foo/bar.adb", "_main"),
            Some("tests/foo/bar.adb".to_string())
        );
        assert_eq!(sanitize_path("external/+gnat/x.ads", "_main"), None);
        assert_eq!(sanitize_path("<unknown>", "_main"), None);
        assert_eq!(sanitize_path("", "_main"), None);
    }

    #[test]
    fn sanitize_absolute_uses_workspace_name() {
        assert_eq!(
            sanitize_path("/cache/execroot/my_ws/pkg/a.adb", "my_ws"),
            Some("pkg/a.adb".to_string())
        );
        assert_eq!(
            sanitize_path("/cache/execroot/_main/pkg/a.adb", "my_ws"),
            Some("pkg/a.adb".to_string())
        );
        assert_eq!(
            sanitize_path("/cache/execroot/_main/external/r/a.adb", "_main"),
            None
        );
        assert_eq!(sanitize_path("/usr/include/foo.h", "_main"), None);
    }

    #[test]
    fn sanitize_windows_paths() {
        assert_eq!(
            sanitize_path("C:\\b\\execroot\\_main\\pkg\\a.adb", "_main"),
            Some("pkg/a.adb".to_string())
        );
        assert_eq!(sanitize_path("D:\\other\\a.adb", "_main"), None);
        assert_eq!(
            sanitize_path("pkg\\sub\\a.adb", "_main"),
            Some("pkg/sub/a.adb".to_string())
        );
    }

    #[test]
    fn runfiles_key_collapses_parent_segments() {
        assert_eq!(
            normalize_runfiles_key("_main", "../+ada+gnat/bin/gcov"),
            "+ada+gnat/bin/gcov"
        );
        assert_eq!(
            normalize_runfiles_key("_main", "external/+gnat/bin/gcov"),
            "_main/external/+gnat/bin/gcov"
        );
    }

    fn gcda_index(paths: &[&str]) -> GcdaIndex {
        index_gcda_files(paths.iter().map(PathBuf::from))
    }

    #[test]
    fn gcda_index_keys_by_basename_and_ignores_other_files() {
        let index = gcda_index(&[
            "/cov/a/u.gcda",
            "/cov/b/u.gcda",
            "/cov/a/v.gcda",
            "/cov/a/u.gcno",
        ]);
        assert_eq!(index.len(), 2);
        assert_eq!(index["u.gcda"].len(), 2);
        assert_eq!(index["v.gcda"], vec![PathBuf::from("/cov/a/v.gcda")]);
    }

    #[test]
    fn find_gcda_matches_directory_suffix() {
        let a = "/cov/sb/1/execroot/_main/bazel-out/bin/a/_objs/t/body/u.gcda";
        let b = "/cov/sb/1/execroot/_main/bazel-out/bin/b/_objs/t/body/u.gcda";
        let index = gcda_index(&[a, b]);
        let got = find_gcda(&index, "bazel-out/bin/b/_objs/t/body/u.gcno", "u").unwrap();
        assert_eq!(got, Path::new(b));
        let got = find_gcda(&index, "bazel-out/bin/a/_objs/t/body/u.gcno", "u").unwrap();
        assert_eq!(got, Path::new(a));
        // The suffix must align on a component boundary.
        assert!(find_gcda(&index, "out/bin/a/_objs/t/body/u.gcno", "u").is_none());
    }

    #[test]
    fn find_gcda_without_suffix_match_is_a_miss() {
        let index = gcda_index(&["/cov/x/u.gcda", "/cov/x/v.gcda"]);
        // A unique basename is not enough: the directory must match too.
        assert!(find_gcda(&index, "bazel-out/bin/z/u.gcno", "u").is_none());
        assert!(find_gcda(&index, "bazel-out/bin/z/w.gcno", "w").is_none());
        let got = find_gcda(&index, "x/u.gcno", "u").unwrap();
        assert_eq!(got, Path::new("/cov/x/u.gcda"));
    }
}
