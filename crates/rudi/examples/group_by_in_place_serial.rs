//! A simple app to show the use of rudi::RecordStreamer::group_by_in_place_serial().
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

// main
fn main() {
    // in this example, we group by a single field
    RecordStreamer::new()
        .group_by_in_place_serial(record_parser, &["group"]);
}

// record parsing function
// records are updated by reference, returning Vec<usize> to enact filtering and sorting at the group level
fn record_parser(input_record_group: &mut [MyRecord]) -> Result<Vec<usize>, Box<dyn Error>> {

    // filter against some record groups by returning an empty vector
    let group = input_record_group[0].group;
    if group > 5 && group < 10 {
        Ok(vec![])

    // update the remaining records to show we did something
    } else {
        for input_record in input_record_group.iter_mut() {
            input_record.random *= 100;
            input_record.name = format!("{}-{}-{}", input_record.name, "group_by_in_place_serial", group);
        }

        // return Vec<usize> to enact filtering and sorting at the group level
        // do not need to return the record since it is updated in place
        Ok((0..input_record_group.len()).collect())
        // Ok(vec![0]) // return only the first record in each group
        // Ok((0..input_record_group.len()).rev().collect()) // reverse the group order, etc.
    }
}
