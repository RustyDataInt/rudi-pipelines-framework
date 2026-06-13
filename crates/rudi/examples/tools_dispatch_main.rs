//! This file provides a template for an RuDI-style tool dispatcher
//! that allows one compiled binary to pass requests to different tools.
//! Copy this file as `main.rs` of you tools crate and modify as needed.

//! Command-line tools for processing XXXXX data.

// dependencies
use std::env;
use std::error::Error;

// modules
// mod XXXXX;  // uncomment and add modules as needed to expose tools

// constants
const TOOLS_NAME: &str = "my_tools";

// load and process data
fn main() -> Result<(), Box<dyn Error>> {

    // read command line arguments
    let mut args: Vec<String> = env::args().collect();
    args = args[1..].to_vec(); // drop executable name 
    if args.len() == 0 { // check for something to do, i.e., a tool to run
        eprintln!("{}: missing tool or command", TOOLS_NAME);
        Err(format!("usage: {} <tool> [additional arguments]", TOOLS_NAME))?
    }
    let tool = args[0].clone(); // drop tool name
    args = args[1..].to_vec();

    // dispatch to tool or command
    match tool.as_str() {

        /*--------------------------------------------------------------
        tool group, e.g., for one pipeline or action
        ------------------------------------------------------------- */
        // tool summary
        // "xxxxx" => tools::xxxxx::stream(),

        // tool summary
        // "xxxxx" => tools::xxxxx::stream(args), // if your tool needs additional arguments

        /*--------------------------------------------------------------
        unrecognized tool
        ------------------------------------------------------------- */
        _ => Err(format!("{}: unknown tool or command: {}", TOOLS_NAME, tool))?
    }
}
