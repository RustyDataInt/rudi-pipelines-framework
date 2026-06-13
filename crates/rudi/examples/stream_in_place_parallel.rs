//! A simple app to show the use of rudi::RecordStreamer::stream_in_place_parallel().
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
const METHOD:      &str  = "stream_in_place_parallel";
const N_CPU:       usize = 4;
const BUFFER_SIZE: usize = 1000; // number of records to buffer before parallel processing

// main
fn main() {

    // demonstrate passing of immutable values to the record parser
    let proof: String = METHOD.to_string();
    let record_parser = |input_record: &mut MyRecord| -> Result<bool, Box<dyn Error + Send + Sync>> {
        parse_with_proof(input_record, &proof)
    };
    RecordStreamer::new()
        .stream_in_place_parallel(record_parser, N_CPU, BUFFER_SIZE);
}

// record parsing function
// records are updated by reference, returning Ok(bool) to enact filtering
fn parse_with_proof(input_record: &mut MyRecord, proof: &str) -> Result<bool, Box<dyn Error + Send + Sync>> {

    // filter against some records by returning Ok(false)
    if input_record.group > 5 && input_record.group < 10 {
        Ok(false)

    // update the remaining records to show we did something
    } else {
        input_record.random *= 100;
        input_record.name = format!("{}-{}", input_record.name, proof);

        // return Ok(true) to output this record
        // do not need to return the record since it is updated in place
        Ok(true)
    }
}
