//! A simple app to show the use of rudi::RecordStreamer::group_by_replace_parallel().
//! Compatible with output streamed from make_tsv.pl.

// dependencies
use std::error::Error;
use std::cmp::min;
use rudi::RecordStreamer;
use serde::{Deserialize, Serialize};

// structures, with support for record parsing using serde
#[derive(Serialize, Deserialize)]
struct InputRecord {
    group:  u32,
    record: u32,
    name:   String,
    random: u32,
}
#[derive(Serialize, Deserialize)]
struct OutputRecord {
    group:      u32,    // grouping field
    name:       String,
    n_records:  usize,  // new aggregate fields
    min_random: u32,
    proof:      String,
}

// constants, for parallel processing
const METHOD:      &str  = "group_by_replace_parallel";
const N_CPU:       usize = 4;
const BUFFER_SIZE: usize = 1000;

// main
fn main() {

    // demonstrate passing of immutable values to the record parser
    let proof: String = METHOD.to_string();
    let record_parser = |input_record_group: &[InputRecord]| -> Result<Vec<OutputRecord>, Box<dyn Error + Send + Sync>> {
        parse_with_proof(input_record_group, &proof)
    };

    // in this example, we group and aggregate by a two fields
    RecordStreamer::new()
        .group_by_replace_parallel(record_parser, &["group","name"], N_CPU, BUFFER_SIZE);
}

// record parsing function
// input records are immutable and must be transformed to output records
fn parse_with_proof(input_record_group: &[InputRecord], proof: &str) -> Result<Vec<OutputRecord>, Box<dyn Error + Send + Sync>> {

    // filter against some record groups by returning an empty vector
    let group0 = &input_record_group[0];
    let group = group0.group; // probably wouldn't do this, but to demonstrate some things
    if group > 5 && group < 10 {
        Ok(vec![])
    } else {

        // initialize a new aggregated output record from the first input record
        let mut output_record = OutputRecord {
            group, // Rust encourages shortcut naming of struct fields when possible
            name:       group0.name.clone(), // clone() is needed since String is not Copy
            n_records:  input_record_group.len(), // set aggregate fields
            min_random: group0.random,
            proof:      format!("{}-{}", group0.name, proof),
        };

        // apply aggregation functions using the remaining records
        if input_record_group.len() > 1 {
            for input_record in input_record_group.iter().skip(1) {
                output_record.min_random = min(output_record.min_random, input_record.random);
            }
        }

        // return the new output record(s)
        // returning a vector of records transfers metadata ownership to RecordStreamer
        // without a deep copy of the allocated record data on the heap
        Ok(vec![output_record])
    }
}
