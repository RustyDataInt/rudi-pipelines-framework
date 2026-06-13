// modules
pub mod workflow; // support for RuDI-style workflows, environment variables, etc.
pub mod record;   // helpers for streaming data in Unix pipes

// re-exports
pub use workflow::file::{InputFile, OutputFile, InputCsv, OutputCsv};
pub use record::streamer::RecordStreamer;
pub use record::fanner::RecordFanner;
