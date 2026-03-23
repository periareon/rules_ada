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

    for cmd_args in &commands {
        let program = &cmd_args[0];
        let status = Command::new(program)
            .args(&cmd_args[1..])
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
