//! A simple app to show the use of rudi::RecordStreamer::stream_in_place_serial().
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
    RecordStreamer::new()
        .stream_in_place_serial(record_parser);
}

// record parsing function
// records are updated by reference, returning Ok(bool) to enact filtering
fn record_parser(input_record: &mut MyRecord) -> Result<bool, Box<dyn Error>> {

    // filter against some records by returning None
    if input_record.group > 5 && input_record.group < 10 {
        Ok(false)

    // update the remaining records to show we did something
    } else {
        input_record.random *= 100;
        input_record.name = format!("{}-{}", input_record.name, "stream_in_place_serial");

        // return Ok(true) to output this record
        // do not need to return the record since it is updated in place
        Ok(true)
    }
}
