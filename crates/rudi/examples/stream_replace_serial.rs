//! A simple app to show the use of rudi::RecordStreamer::stream_replace_serial().
//! Compatible with output streamed from make_tsv.pl.

// dependencies
use std::error::Error;
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
    group:  u32,
    record: u32,
    name:   String,
    random: u32,
    proof:  String, // to illustrate adding a field to the output record
}

// implement transformation (cast) from input to output records
// this is the slowest step as it requires copying the input data to a new output record
impl From<&InputRecord> for OutputRecord {
    fn from(input_record: &InputRecord) -> Self {
        OutputRecord {
            group:  input_record.group,        // integers implement Copy so no clone is required
            record: input_record.record,
            name:   input_record.name.clone(), // clone is required since name is a String
            random: input_record.random,
            proof:  "".to_string(),            // initialise proof to empty string
        }
    }
}

// main
fn main() {
    RecordStreamer::new()
        .stream_replace_serial(record_parser);
}

// record parsing function
// input records are immutable and must be transformed to output records
fn record_parser(input_record: InputRecord) -> Result<Vec<OutputRecord>, Box<dyn Error>> {

    // filter against some records by returning and empty Vec<OutputRecord>
    if input_record.group > 5 && input_record.group < 10 {
        Ok(vec![])
    } else {

        // create a new output record
        let mut output_record = OutputRecord::from(&input_record);
        // let mut output_record: OutputRecord = input_record.into(); // alternative syntax

        // update the proof fields
        output_record.random *= 100;
        output_record.proof = format!("{}-{}", output_record.name, "stream_replace_serial");

        // return the new output record(s) as Ok(Vec<OutputRecord>)
        // returning a vector of records transfers metadata ownership to RecordStreamer
        // without a deep copy of the allocated record data on the heap
        Ok(vec![output_record])
    }
}
