//! A simple app to show the use of rudi::RecordStreamer::group_by_in_place_parallel().
//! Compatible with output streamed from make_tsv.pl.

// dependencies
use std::error::Error;
use rudi::RecordStreamer;
use serde::{Deserialize, Serialize};

// structures, with support for record parsing using serde
#[derive(Serialize, Deserialize)]
struct MyRecord {
    group:  u32,
    record: u32,
    name:   String,
    random: u32,
}

// constants, for parallel processing
const METHOD:      &str  = "group_by_in_place_parallel";
const N_CPU:       usize = 4;
const BUFFER_SIZE: usize = 1000;

// main
fn main() {

    // demonstrate passing of immutable values to the record parser
    let proof: String = METHOD.to_string();
    let record_parser = |input_record: &mut [MyRecord]| -> Result<Vec<usize>, Box<dyn Error + Send + Sync>> {
        parse_with_proof(input_record, &proof)
    };

    // in this example, we group by a single field
    RecordStreamer::new()
        .group_by_in_place_parallel(record_parser, &["group"], N_CPU, BUFFER_SIZE);
}

// record parsing function
// records are updated by reference, returning None or Some(()) to enact filtering at the group level
fn parse_with_proof(input_record_group: &mut [MyRecord], proof: &str) -> Result<Vec<usize>, Box<dyn Error + Send + Sync>> {

    // filter against some record groups by returning an empty vector
    let group = input_record_group[0].group;
    if group > 5 && group < 10 {
        Ok(vec![])

    // update the remaining records to show we did something
    } else {
        for input_record in input_record_group.iter_mut() {
            input_record.random *= 100;
            input_record.name = format!("{}-{}-{}", input_record.name, proof, group);
        }

        // return Vec<usize> to enact filtering and sorting at the group level
        // do not need to return the record since it is updated in place
        Ok((0..input_record_group.len()).collect())
        // Ok(vec![0]) // return only the first record in each group
        // Ok((0..input_record_group.len()).rev().collect()) // reverse the group order, etc.
    }
}
