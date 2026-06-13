//! This is a template for constructing a tool worker submodule using RuDI framework components.
//! 
//! A tool worker is claimed as a dependency by a workflow tool and performs a specific
//! data processing task as part of the tool's overall workflow.
//! 
//! Replace this comment block with a description of the workers's purpose, actions
//! performed, expected inputs, and the generated outputs.

// dependencies
use rudi::pub_key_constants;
use rudi::workflow::Workflow;
use super::Tool;

// constants
pub_key_constants!{
    // from environment variables
    WORKER_OPTION 
    WORKER_FLAG
    // derived configuration values
    WORKER_DERIVED_OPTION
    // counter keys
    N_EVENTS
    N_BY_WORKER_KEY
    N_BY_WORKER_VALUE
}
const WORKER_CONSTANT: u8 = 1; // additional fixed values not exposed as options

/// MySubModule does something useful.
pub struct MySubModule {
    my_value: bool,
}
impl MySubModule {
    /* ---------------------------------------------------------------------------
    initialize
    ---------------------------------------------------------------------------- */
    /// Initialize a new MySubModule.
    pub fn new(w: &mut Workflow) -> MySubModule {
        w.cfg.set_bool_env(&[WORKER_FLAG]);
        w.cfg.set_u8_env(&[WORKER_OPTION]);
        w.cfg.set_bool(WORKER_DERIVED_OPTION, *w.cfg.get_u8(WORKER_OPTION) == WORKER_CONSTANT);
        w.ctrs.add_counters(&[
            (N_EVENTS, "number of events processed"),
        ]);
        w.ctrs.add_keyed_counters(&[
            (N_BY_WORKER_KEY, "count of unique keys"),
        ]);
        w.ctrs.add_indexed_counters(&[
            (N_BY_WORKER_VALUE, "distribution of integer values"),
        ]);
        MySubModule{
            my_value: *w.cfg.get_bool(WORKER_FLAG),
        }
    }

    /* ---------------------------------------------------------------------------
    functions that do something useful
    ---------------------------------------------------------------------------- */
    /// Do something useful.
    pub fn do_something_useful(
        &self, 
        w: &mut Workflow, 
        tool: &mut Tool,
        record: &mut MyRecord,
    ) {

    }

}
