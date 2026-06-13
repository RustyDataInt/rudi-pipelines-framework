//! The Log structure helps print structured log messages to STDERR.

// dependencies
use chrono::Local;

/// The Log structure helps print structured log messages to STDERR.
/// 
/// By convention, Log objects are named `log`.
pub struct Log {
    tool: String,
}
impl Log {

    /// Create a new Log instance for a given tool.
    /// 
    /// By convention, Log objects are named `log`.
    pub fn new(tool: &str) -> Self {
        Self {
            tool: tool.to_string(),
        }
    }

    /// Print a time-stamped message to STDERR for logging purposes.
    pub fn print(&self, msg: &str) {
        eprintln!("{}: {} ({})", 
            self.tool, 
            msg, 
            Local::now().to_rfc3339()
        );
    }

    /// Print a time-stamped 'initializing' message to STDERR for logging purposes.
    /// Includes a preceding newline for spacing clarity.
    pub fn initializing(&self) {
        eprintln!("\n{}: {} ({})", 
            self.tool, 
            "initializing", 
            Local::now().to_rfc3339()
        );
    }
}
