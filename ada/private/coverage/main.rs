use flate2::read::GzDecoder;
use serde::Deserialize;
use std::env;
use std::fs;
use std::io::{BufRead, BufReader, BufWriter, Write};
use std::path::{Path, PathBuf};
use std::process::Command;
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
    let coverage_dir = match env::var("COVERAGE_DIR") {
        Ok(v) if !v.is_empty() => PathBuf::from(v),
        _ => return,
    };
    let coverage_manifest = match env::var("COVERAGE_MANIFEST") {
        Ok(v) if !v.is_empty() => v,
        _ => return,
    };

    let gcov_tool = match resolve_gcov() {
        Some(tool) => tool,
        None => return,
    };

    let root = env::var("ROOT").unwrap_or_default();
    let output_path = env::var("COVERAGE_OUTPUT_FILE")
        .ok()
        .filter(|s| !s.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| coverage_dir.join("_ada_coverage.dat"));

    let manifest = match fs::File::open(&coverage_manifest) {
        Ok(f) => f,
        Err(_) => return,
    };

    let output = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&output_path)
        .unwrap_or_else(|e| {
            eprintln!(
                "error: cannot open output file {}: {e}",
                output_path.display()
            );
            std::process::exit(1);
        });
    let mut output = BufWriter::new(output);

    for line in BufReader::new(manifest).lines() {
        let line = match line {
            Ok(l) => l,
            Err(_) => continue,
        };

        if !line.ends_with(".gcno") {
            continue;
        }

        let stem = match Path::new(&line).file_stem().and_then(|s| s.to_str()) {
            Some(s) if !s.is_empty() => s.to_owned(),
            _ => continue,
        };

        let gcda_name = format!("{stem}.gcda");
        let gcda_file = match find_file(&coverage_dir, &gcda_name) {
            Some(f) => f,
            None => continue,
        };

        let gcda_dir = match gcda_file.parent() {
            Some(d) => d.to_path_buf(),
            None => continue,
        };

        let gcno_source = Path::new(&root).join(&line);
        if !gcno_source.is_file() {
            continue;
        }

        if let Some(name) = gcno_source.file_name() {
            let _ = fs::copy(&gcno_source, gcda_dir.join(name));
        }

        let _ = Command::new(&gcov_tool)
            .args(["-i", "-b", "-o"])
            .arg(&gcda_dir)
            .arg(&gcda_file)
            .current_dir(&coverage_dir)
            .stderr(std::process::Stdio::null())
            .status();

        if let Ok(entries) = fs::read_dir(&coverage_dir) {
            for entry in entries.flatten() {
                let path = entry.path();
                let name = match path.file_name().and_then(|n| n.to_str()) {
                    Some(n) => n.to_owned(),
                    None => continue,
                };
                if name.ends_with(".gcov.json.gz") {
                    let _ = gcov_to_lcov(&path, &mut output);
                    let _ = fs::remove_file(&path);
                } else if name.ends_with(".gcov") {
                    let _ = fs::remove_file(&path);
                }
            }
        }
    }
}

fn resolve_gcov() -> Option<String> {
    let ada_gcov_path = env::var("ADA_GCOV_PATH").ok().filter(|s| !s.is_empty())?;

    let root = env::var("ROOT").ok().filter(|s| !s.is_empty());
    let test_srcdir = env::var("TEST_SRCDIR").ok().filter(|s| !s.is_empty());
    let test_workspace = env::var("TEST_WORKSPACE").ok().filter(|s| !s.is_empty());

    let mut candidates = vec![ada_gcov_path.clone()];

    if let Some(ref root) = root {
        candidates.push(format!("{root}/{ada_gcov_path}"));
    }

    if let Some(ref srcdir) = test_srcdir {
        let workspace = test_workspace.as_deref().unwrap_or("_main");
        candidates.push(format!("{srcdir}/{workspace}/{ada_gcov_path}"));
    }

    candidates.into_iter().find(|c| is_executable(c))
}

#[cfg(unix)]
fn is_executable(path: &str) -> bool {
    use std::os::unix::fs::PermissionsExt;
    fs::metadata(path)
        .map(|m| m.permissions().mode() & 0o111 != 0)
        .unwrap_or(false)
}

#[cfg(not(unix))]
fn is_executable(path: &str) -> bool {
    Path::new(path).is_file()
}

fn find_file(dir: &Path, name: &str) -> Option<PathBuf> {
    WalkDir::new(dir)
        .into_iter()
        .filter_map(|e| e.ok())
        .find(|e| e.file_type().is_file() && e.file_name().to_str() == Some(name))
        .map(|e| e.into_path())
}

fn sanitize_path(path: &str) -> Option<&str> {
    if path == "<unknown>" || path.is_empty() {
        return None;
    }
    if !path.starts_with('/') {
        if path.starts_with("external/") {
            return None;
        }
        return Some(path);
    }
    if let Some(idx) = path.find("/execroot/_main/") {
        let rel = &path[idx + "/execroot/_main/".len()..];
        if rel.starts_with("external/") {
            return None;
        }
        return Some(rel);
    }
    None
}

fn gcov_to_lcov(gz_path: &Path, output: &mut impl Write) -> std::io::Result<()> {
    let file = fs::File::open(gz_path)?;
    let decoder = GzDecoder::new(file);
    let data: GcovData = serde_json::from_reader(decoder)
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;

    for file_data in &data.files {
        let sf = match sanitize_path(&file_data.file) {
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
