// modules
mod config;
mod counters;
mod log;
pub mod file;

// exports
pub use config::Config;
pub use counters::{Counters, COUNTER_SEPARATOR};
pub use log::Log;

/// Declare one or more data keys as constants in form `const KEY: &str = "KEY";`.
/// Doing so improves code readability and helps avoid typos in string literals 
/// used to access environment variables or string-keyed data structures like HashMap,  
/// since calls can now take the form `w.cfg.u8.set_from_env(KEY); w.cfg.u8.get_str(KEY)`.
/// 
/// Key constants set in this way must have all uppercase names to follow Rust conventions.
/// 
/// Constants are declared with pub so that other modules can also use them.
/// 
/// Provide keys as either space-separated or comma-separated lists.
#[macro_export]
macro_rules! pub_key_constants {
    ($($key:ident)+) => { // support space-separated keys
        $(
            pub const $key: &str = stringify!($key);
        )+
    };
    ($($key:ident),+ $(,)?) => { // support comma-separated keys    
        $(
            pub const $key: &str = stringify!($key);
        )+
    };
}

/// The Workflow structure organizes the common components of a data processing workflow,
/// including configuration parameters, logging, and counters.
/// 
/// It is a convenience wrapper to facilitate passing these common components to functions
/// in a single variable. 
/// 
/// By convention, Workflow objects are named `w`, and elements are accessed as 
/// `w.cfg`, `w.log`, and `w.ctrs`.
pub struct Workflow {
    pub cfg:  Config,
    pub ctrs: Counters,
    pub log:  Log,
}
impl Workflow {
    /// Create a new Workflow instance with specified tool name, configuration,
    /// and counters.
    /// 
    /// By convention, Workflow objects are named `w`, and elements are accessed as 
    /// `w.cfg`, `w.log`, and `w.ctrs`.
    pub fn new(tool: &str, cfg: Config, ctrs: Counters) -> Self {
        Self {
            cfg,
            ctrs,
            log: Log::new(tool),
        }
    }
}
