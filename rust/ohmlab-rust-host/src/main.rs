use std::{
    env,
    io::{self, Read},
    process::ExitCode,
};

fn main() -> ExitCode {
    let command = env::args().nth(1).unwrap_or_else(|| "run".into());
    if command == "manifest" {
        println!("{}", ohmlab_rust_host::manifest_json());
        return ExitCode::SUCCESS;
    }
    if command == "qualify" {
        let qualification = ohmlab_rust_host::qualification_json();
        println!("{}", qualification.json);
        return if qualification.succeeded {
            ExitCode::SUCCESS
        } else {
            ExitCode::from(1)
        };
    }
    if command != "run" {
        eprintln!("usage: ohmlab-rust-host [run|manifest|qualify]");
        return ExitCode::from(2);
    }
    let mut input = Vec::new();
    if let Err(error) = io::stdin().read_to_end(&mut input) {
        eprintln!("failed to read stdin: {error}");
        return ExitCode::from(2);
    }
    let response = ohmlab_rust_host::execute(&input);
    println!("{}", response.json);
    if response.succeeded {
        ExitCode::SUCCESS
    } else {
        ExitCode::from(1)
    }
}
