use std::env;
use std::fs;
use std::process::ExitCode;

fn main() -> ExitCode {
    let args: Vec<_> = env::args_os().collect();
    if args.len() != 3 && args.len() != 4 {
        eprintln!("Usage: avalonia-bindgen <projection.ir.json> <sys-output> [safe-output]");
        return ExitCode::from(2);
    }

    let json = match fs::read_to_string(&args[1]) {
        Ok(value) => value,
        Err(error) => {
            eprintln!("Failed to read projection IR: {error}");
            return ExitCode::FAILURE;
        }
    };
    let source = match avalonia_bindgen::generate_from_json(&json) {
        Ok(value) => value,
        Err(error) => {
            eprintln!("Failed to parse projection IR: {error}");
            return ExitCode::FAILURE;
        }
    };
    if let Err(error) = fs::write(&args[2], source) {
        eprintln!("Failed to write generated Rust: {error}");
        return ExitCode::FAILURE;
    }
    if args.len() == 4 {
        let source = match avalonia_bindgen::generate_safe_from_json(&json) {
            Ok(value) => value,
            Err(error) => {
                eprintln!("Failed to parse projection IR for safe bindings: {error}");
                return ExitCode::FAILURE;
            }
        };
        if let Err(error) = fs::write(&args[3], source) {
            eprintln!("Failed to write generated safe Rust: {error}");
            return ExitCode::FAILURE;
        }
    }

    ExitCode::SUCCESS
}
