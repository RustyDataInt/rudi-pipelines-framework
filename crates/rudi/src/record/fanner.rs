//! RecordFanner supports RuDI pipelines by providing a structure to manipulate 
//! data records in a data stream. 
//! 
//! In the simplest case, CSV records of known structures are read from STDIN 
//! and written to STDOUT to function in a Unix stream. More complex allow
//! passing a custom record reader and output record handler.
//! 
//! A `record_parser` closure passed to a RecordFanner does work on each record 
//! or group of records in parallel. This makes it easy to create executable 
//! crates that can be chained together, with each crate performing a specific 
//! task in a data processing pipeline with maximal utilization of available 
//! CPU cores.
//! 
//! # Usage Overview
//! 
//! Create a new RecordFanner instance with default settings using
//! `RecordFanner::new(n_cpu, capacity)`, where:
//! - `n_cpu` is the total number of cores dedicated to the RecordFanner, including two I/O threads
//! - `capacity` is the maximum number of records to buffer per data processing thread
//!
//! Input records can be handled either:
//! - one record at a time using the `stream()` method, or
//! - over multiple records in pre-sorted and keyed groups using the `stream_by()` method
//! 
//! Output records can be either:
//! - in-place modifications of owned input records
//! - entirely new records generated from input records
//! - input records repeated verbatim, or no records at all, if side effects are the only goal
//! 
//! Output records will be written in an arbitrary order relative to input records
//! unless `ordered()` is called on the RecordFanner, in which case output records
//! will be buffered and written in the same relative order as input records.
//! If unordered, each record in an output group will be printed together in the 
//! order received from the record parser, but the relative order of output groups 
//! may differ from the input stream.
//!
//! For CSV records, input and output records are assumed to be:
//! - without headers, unless `has_headers()` is called on the RecordFanner
//! - tab-delimited, unless `delimiter(b'<delimiter>')` is called on the RecordFanner
//! - of a fixed number of columns, unless `flexible()` is called on the RecordFanner
//! 
//! If `comment(Some(b'<char>'))` is called on the RecordFanner to set a comment 
//! character, initial comment lines at the beginning of the input stream will 
//! be passed directly to the output stream. 
//! 
//! Fields in input records will be trimmed of leading and trailing whitespace 
//! unless `no_trim()` is called on the RecordFanner.
//! 
//! Field quoting is disabled by default. To enable dynamic quoting, call 
//! `quote(b'<quote_char>')` on the RecordFanner.
//! 
//! # Record Parsing
//! 
//! Streaming is executed by calling one of the following methods on the RecordFanner:
//! - `stream()`
//! - `stream_by()`
//! - `fan()`
//! - `fan_by()`
//! where 
//! - `stream()` methods process CSV records and `fan()` methods process records from custom readers and writers
//! - the caller defines and provides:
//!     - data structures that describe the input and output data format (I for InputRecord, O for OutputRecord)
//!     - a `record_parser` function or closure that processes the data, returning:
//!         - Ok(Some(Vec<OutputRecord>)) carrying the output record(s) resulting from processing of the input record(s)
//!         - Ok(None), if no records are to be output for the given input record(s)
//!         - Err(...) if a fatal error occurred during record processing
//!
//! The work to be done on input records is arbitrary and defined by the caller.
//! Some examples of work that can be done include:
//! - filtering records based on a condition
//! - updating field(s) in a record
//! - transforming records into distinct output records, e.g., adding a new field
//! - splitting records into multiple output records
//! - reordering records within each group
//! - aggregating grouped records into a single output record
//! - generating side effects distinct from passing output records, for example:
//!     - writing aggregated summary information such as counts to a log 
//!     - creating a summary image or plot
//!     - updating a database
//! 
//! # Error Handling
//! 
//! RecordFanners are designed to work in an HPC data stream where the presumption is
//! that all records are valid and will be processed successfully, even if they are
//! filtered out and not written to the output stream. Accordingly, all RecordFanners
//! panic on any error encountered during processing and create detailed error messages 
//! that identify the specific line in the input data stream that caused a failure. This
//! facilitates debugging when errors are isolated to rare lines in input data. Accordingly, 
//! your record_parser should not panic but should return Err(...) with a descriptive error 
//! message, or simply propagate errors `?`. RecordFanners will append additional 
//! information including the input line number to your error message.
//! 
//! # Serial Record Streamers
//! 
//! A RecordFanner is explicitly designed for parallel processing of records. 
//! If parallel processing is not needed, an rudi::RecordStreamer is a better 
//! choice for flexible streaming CSV records in series.

// dependencies
use std::error::Error;
use std::io::{stdin, stdout, Stdin, Stdout, BufRead, BufReader, BufWriter, Read, Write, Cursor};
use std::collections::BTreeMap;
use crossbeam::channel::{Receiver, bounded};
use serde::{de::{DeserializeOwned}, Serialize};

// constants
const IO_CAPACITY: usize = 8 * 1024 * 1024; // 8 MB buffer for I/O streams
const READING_COMMENTS: &str = "reading comment lines";
const WRITING_COMMENTS: &str = "writing comment lines";
const DESERIALIZING:    &str = "deserializing input record";
const SENDING_INPUT:    &str = "sending input record(s) to worker";
const PROCESSING:       &str = "processing data row(s)";
const SENDING_OUTPUT:   &str = "sending output record(s) from worker";
const SERIALIZING:      &str = "writing serialized output";
const OUTPUTING:        &str = "handling output";
const SERIALIZING_KEY:  &str = "serializing input record for grouping key extraction";
const FLUSHING_OUTPUT:  &str = "flushing final output";

/// Initialize a record streamer.
pub struct RecordFanner {
    n_workers:   usize,
    capacity:    usize,
    ordered:     bool,
    has_headers: bool,
    comment:     Option<u8>,
    delimiter:   u8,
    quote:       Option<u8>,
    trim:        csv::Trim,
    flexible:    bool,
}
impl RecordFanner {

    /* ------------------------------------------------------------------
    public initialization methods, using a style similar to CSV Reader/Writer
    ------------------------------------------------------------------ */
    /// Create a new RecordFanner instance with default settings, where:
    /// - `n_cpu` is the total number of cores dedicated to the RecordFanner, including two I/O threads
    /// - `capacity` is the maximum number of records to buffer per data processing thread
    pub fn new(n_cpu: usize, capacity: usize) -> RecordFanner {
        RecordFanner {
            n_workers:   n_cpu.max(3) - 2, // reserve one core for deserializing, one for serializing
            capacity,
            ordered:     false, 
            has_headers: false,
            comment:     None,
            delimiter:   b'\t',
            quote:       None,
            trim:        csv::Trim::Fields,
            flexible:    false,
        }
    }

    /// Set the csv has_headers option to true for the input and output streams.
    pub fn ordered(&mut self) -> &mut Self {
        self.ordered = true;
        self
    }

    /// Set the csv has_headers option to true for the input and output streams.
    pub fn has_headers(&mut self) -> &mut Self {
        self.has_headers = true;
        self
    }

    /// Set the comment character for the input stream to pass initial comment lines directly to STDOUT.
    pub fn comment(&mut self, comment: u8) -> &mut Self {
        self.comment = Some(comment);
        self
    }

    /// Set the csv delimiter for the input and output streams if not tab-delimited.
    pub fn delimiter(&mut self, delimiter: u8) -> &mut Self {
        self.delimiter = delimiter;
        self
    }

    /// Set the quote character for the input and output streams.
    /// Setting a quote character is not generally needed for most HPC data formats.
    /// If a quote character is set, output fields will be dynamically quoted only as needed.
    pub fn quote(&mut self, quote_char: u8) -> &mut Self {
        self.quote = Some(quote_char);
        self
    }

    /// Set the csv trim option for the input stream if whitespace trimming is not needed.
    pub fn no_trim(&mut self) -> &mut Self {
        self.trim = csv::Trim::None;
        self
    }

    /// Set the csv flexible option for the input stream if a variable number of columns is expected.
    pub fn flexible(&mut self) -> &mut Self {
        self.flexible = true;
        self
    }

    /* ------------------------------------------------------------------
    public streaming methods
    ------------------------------------------------------------------ */
    /// Process input CSV records from STDIN to STDOUT one record at a time 
    /// using a caller-provided record parser to convert input records
    /// to output records or record groups.
    /// 
    /// Record types must support deserialization and serialization with Serde, 
    /// and the record parser must be thread-safe.
    pub fn stream <I, O, F>(
        &mut self, 
        record_parser: F, 
    )
    where
        I: DeserializeOwned + Send + Sync,
        O: Serialize + Send,
        F: Fn(I) -> Result<Option<Vec<O>>, Box<dyn Error + Send + Sync>> + Send + Sync,
    {
        const MODE: &str = "RecordFanner::stream()";

        // initialize streams and channels
        let (mut rdr, wtr) = self.init_csv_streams(MODE);
        let (tx_in, rx_in) 
            = bounded::<(usize, usize, I)>(self.capacity);
        let (tx_out,    rx_out) 
            = bounded::<(usize, usize, Result<Option<Vec<O>>, Box<dyn Error + Send + Sync>>)>(self.capacity);
        crossbeam::scope(|scope| {

            // spawn worker threads
            for _ in 0..self.n_workers {
                let rx_in= rx_in.clone();
                let tx_out = tx_out.clone();
                let record_parser = &record_parser;
                scope.spawn(move |_| {
                    for (record_i0, group_i0, input_record) in rx_in.iter() {
                        let result: Result<Option<Vec<O>>, Box<dyn Error + Send + Sync>> = record_parser(input_record);
                        tx_out.send((record_i0, group_i0, result)).unwrap_or_else(|e| {
                            line_error(MODE, SENDING_OUTPUT, Some(record_i0), &e)
                        });
                    }
                });
            }
            drop(tx_out);

            // spawn output serialization thread
            scope.spawn(move |_| {
                serialize_csv_output(MODE, self.ordered, rx_out, wtr);
            });

            // deserialize input records in main thread
            // groups comprise single records, so group_i0 is the same as record_i0
            for (record_i0, line) in rdr.deserialize().enumerate() {
                let input_record: I = line.unwrap_or_else(|e| 
                    line_error(MODE, DESERIALIZING, Some(record_i0), &e)
                );
                tx_in.send((record_i0, record_i0, input_record)).unwrap_or_else(|e| {
                    line_error(MODE, SENDING_INPUT, Some(record_i0), &e)
                });
            }
            drop(tx_in); // close input channel to signal workers to exit
        }).unwrap();
    }

    /// Process any type of records using a caller-provided iterator over
    /// owned input records, a record parser to convert input records to 
    /// output records or record groups, and an output handler.
    /// 
    /// The record parser must be thread-safe.
    pub fn fan <I, O, F>(
        &mut self, 
        input: impl IntoIterator<Item = I>,
        record_parser: F, 
        handler: impl FnMut(O) -> Result<(), Box<dyn Error + Send + Sync>> + Send + Sync,
    )
    where
        I: DeserializeOwned + Send + Sync,
        O: Serialize + Send,
        F: Fn(I) -> Result<Option<Vec<O>>, Box<dyn Error + Send + Sync>> + Send + Sync,
    {
        const MODE: &str = "RecordFanner::fan()";

        // initialize streams and channels
        let (tx_in, rx_in) 
            = bounded::<(usize, usize, I)>(self.capacity);
        let (tx_out,    rx_out) 
            = bounded::<(usize, usize, Result<Option<Vec<O>>, Box<dyn Error + Send + Sync>>)>(self.capacity);
        crossbeam::scope(|scope| {

            // spawn worker threads
            for _ in 0..self.n_workers {
                let rx_in= rx_in.clone();
                let tx_out = tx_out.clone();
                let record_parser = &record_parser;
                scope.spawn(move |_| {
                    for (record_i0, group_i0, input_record) in rx_in.iter() {
                        let result: Result<Option<Vec<O>>, Box<dyn Error + Send + Sync>> = record_parser(input_record);
                        tx_out.send((record_i0, group_i0, result)).unwrap_or_else(|e| {
                            line_error(MODE, SENDING_OUTPUT, Some(record_i0), &e)
                        });
                    }
                });
            }
            drop(tx_out);

            // spawn output serialization thread
            scope.spawn(move |_| {
                handle_output_records(MODE, self.ordered, rx_out, OUTPUTING, handler);
            });

            // deserialize input records in main thread
            // groups comprise single records, so group_i0 is the same as record_i0
            for (record_i0, input_record) in input.into_iter().enumerate() {
                tx_in.send((record_i0, record_i0, input_record)).unwrap_or_else(|e| {
                    line_error(MODE, SENDING_INPUT, Some(record_i0), &e)
                });
            }
            drop(tx_in); // close input channel to signal workers to exit
        }).unwrap();
    }

    /// Process input CSV records from STDIN to STDOUT in groups of records
    /// using a caller-provided record parser to convert input record groups 
    /// to output records or record groups.
    /// 
    /// Use `grouping_fields` to specify the field(s) to group by, and
    /// `group_capacity` to specify the number of records to pre-allocate
    /// per group based on expectations of the input data.
    /// 
    /// Record types must support deserialization and serialization with Serde, 
    /// and the record parser must be thread-safe.
    pub fn stream_by <I, O, F>(
        &mut self, 
        record_parser:   F, 
        grouping_fields: &[&str],
        group_capacity:  usize,
    )
    where
        I: DeserializeOwned + Serialize + Send + Sync, // Serialize is needed to extract grouping key(s)
        O: Serialize + Send,
        F: Fn(Vec<I>) -> Result<Option<Vec<O>>, Box<dyn Error + Send + Sync>> + Send + Sync,
    {
        const MODE: &str = "RecordFanner::stream_by()";

        // initialize streams and channels
        let (mut rdr, wtr) = self.init_csv_streams(MODE);
        let (tx_in, rx_in) 
            = bounded::<(usize, usize, Vec<I>)>(self.capacity);
        let (tx_out,    rx_out)    
            = bounded::<(usize, usize, Result<Option<Vec<O>>, Box<dyn Error + Send + Sync>>)>(self.capacity);
        crossbeam::scope(|scope| {

            // spawn worker threads
            for _ in 0..self.n_workers {
                let rx_in= rx_in.clone();
                let tx_out = tx_out.clone();
                let record_parser = &record_parser;
                scope.spawn(move |_| {
                    for (record_i0, group_i0, input_record_group) in rx_in.iter() {
                        let result = record_parser(input_record_group);
                        tx_out.send((record_i0, group_i0, result)).unwrap_or_else(|e| {
                            line_error(MODE, SENDING_OUTPUT, Some(record_i0), &e)
                        });
                    }
                });
            }
            drop(tx_out);

            // spawn output serialization thread
            scope.spawn(move |_| {
                serialize_csv_output(MODE, self.ordered, rx_out, wtr);
            });

            // deserialize and group input records in main thread
            // record_i0 is passed as the first record index in a group
            // group_i0 is a sequential group index
            let mut input_record_group: Vec<I> = Vec::with_capacity(group_capacity);
            let mut previous_key: Option<String> = None;
            let mut group_start_i0: usize = 0;
            let mut group_i0: usize = 0;
            for (record_i0, line) in rdr.deserialize().enumerate() {
                let input_record: I = line.unwrap_or_else(|e| 
                    line_error(MODE, DESERIALIZING, Some(record_i0), &e)
                );
                let this_key = get_composite_key(MODE, &input_record, grouping_fields, record_i0);
                if previous_key.as_ref().map_or(false, |k| k != &this_key) {
                    tx_in.send((group_start_i0, group_i0, input_record_group)).unwrap_or_else(|e| {
                        line_error(MODE, SENDING_INPUT, Some(group_start_i0), &e)
                    });
                    input_record_group = Vec::with_capacity(group_capacity);
                    group_start_i0 = record_i0;
                    group_i0 += 1;
                }
                previous_key = Some(this_key);
                input_record_group.push(input_record);
            }
            tx_in.send((group_start_i0, group_i0, input_record_group)).unwrap_or_else(|e| {
                line_error(MODE, SENDING_INPUT, Some(group_start_i0), &e)
            });
            drop(tx_in); // close input channel to signal workers to exit
        }).unwrap();
    }

    /// Process any type of records using a caller-provided iterator over
    /// owned input record groups, a record parser to convert input record 
    /// groups to output records or record groups, and an output handler.
    /// 
    /// The record parser must be thread-safe.
    pub fn fan_by <I, O, F>(
        &mut self, 
        input: impl IntoIterator<Item = Vec<I>>,
        record_parser: F, 
        handler: impl FnMut(O) -> Result<(), Box<dyn Error + Send + Sync>> + Send + Sync,
    )
    where
        I: DeserializeOwned + Serialize + Send + Sync, // Serialize is needed to extract grouping key(s)
        O: Serialize + Send,
        F: Fn(Vec<I>) -> Result<Option<Vec<O>>, Box<dyn Error + Send + Sync>> + Send + Sync,
    {
        const MODE: &str = "RecordFanner::fan_by()";

        // initialize streams and channels
        let (tx_in, rx_in) 
            = bounded::<(usize, usize, Vec<I>)>(self.capacity);
        let (tx_out,    rx_out)    
            = bounded::<(usize, usize, Result<Option<Vec<O>>, Box<dyn Error + Send + Sync>>)>(self.capacity);
        crossbeam::scope(|scope| {

            // spawn worker threads
            for _ in 0..self.n_workers {
                let rx_in= rx_in.clone();
                let tx_out = tx_out.clone();
                let record_parser = &record_parser;
                scope.spawn(move |_| {
                    for (record_i0, group_i0, input_record_group) in rx_in.iter() {
                        let result = record_parser(input_record_group);
                        tx_out.send((record_i0, group_i0, result)).unwrap_or_else(|e| {
                            line_error(MODE, SENDING_OUTPUT, Some(record_i0), &e)
                        });
                    }
                });
            }
            drop(tx_out);

            // spawn output serialization thread
            scope.spawn(move |_| {
                handle_output_records(MODE, self.ordered, rx_out, OUTPUTING, handler);
            });

            // deserialize and group input records in main thread
            // record_i0 is passed as the first record index in a group
            // group_i0 is a sequential group index
            for (group_i0, input_record_group) in input.into_iter().enumerate() {
                tx_in.send((group_i0, group_i0, input_record_group)).unwrap_or_else(|e| {
                    line_error(MODE, SENDING_INPUT, Some(group_i0), &e)
                });
            }
            drop(tx_in); // close input channel to signal workers to exit
        }).unwrap();
    }

    /*  ------------------------------------------------------------------
    private CSV-specific stream and record methods
    ------------------------------------------------------------------ */
    /// Return a paired stream reader and writer for STDIN and STDOUT.
    /// By design, headers and delimiters are handled the same for both input and output streams.
    fn init_csv_streams(
        &self, 
        mode: &'static str,
    ) -> (
        csv::Reader<Box<dyn BufRead>>, 
        csv::Writer<BufWriter<Stdout>>,
    ) {
        let (quote_char, quoting, quote_style) = match self.quote {
            Some(quote_char) => (quote_char, true, csv::QuoteStyle::Necessary),
            None => (b'\0', false, csv::QuoteStyle::Never),
        };
        let stdin = stdin();
        let mut stdout = BufWriter::with_capacity(IO_CAPACITY, stdout());
        let reader: Box<dyn BufRead> = if let Some(comment_char) = self.comment {
            pass_initial_comment_lines(mode, comment_char, &stdin, &mut stdout)
        } else {
            Box::new(BufReader::with_capacity(IO_CAPACITY, stdin.lock()))
        };
        let rdr = csv::ReaderBuilder::new()
            .has_headers(self.has_headers)
            .delimiter(self.delimiter)
            .quote(quote_char)
            .quoting(quoting)
            .flexible(self.flexible)
            .trim(self.trim)
            .from_reader(reader);
        let wtr = csv::WriterBuilder::new()
            .has_headers(self.has_headers)
            .delimiter(self.delimiter)
            .quote(quote_char)
            .quote_style(quote_style)
            .flexible(self.flexible)
            .from_writer(stdout);
        (rdr, wtr)
    }
}

/*  ------------------------------------------------------------------
additional CSV-specific stream and record methods
------------------------------------------------------------------ */
/// Pass initial CSV comment lines from STDIN to STDOUT.
fn pass_initial_comment_lines(
    mode:         &'static str,
    comment_char: u8,
    stdin:        &Stdin, 
    stdout:       &mut dyn Write,
) -> Box<dyn BufRead> {
    let mut buf_reader = BufReader::with_capacity(IO_CAPACITY, stdin.lock());
    let mut line = String::new();
    let mut non_comment_line: Option<String> = None;
    loop {
        line.clear();
        let bytes_read = buf_reader.read_line(&mut line).unwrap_or_else(|e| {
            line_error(mode, READING_COMMENTS, None, &e)
        });
        if bytes_read == 0 { break; } // EOF
        if line.as_bytes()[0] == comment_char {
            stdout.write_all(line.as_bytes()).unwrap_or_else(|e| {
                line_error(mode, WRITING_COMMENTS, None, &e)
            });
        } else {
            non_comment_line = Some(line.clone());
            break;
        }
    }
    if let Some(non_comment_line) = non_comment_line {
        let chained = Cursor::new(non_comment_line).chain(buf_reader);
        Box::new(BufReader::with_capacity(IO_CAPACITY, chained)) // prepend first non-comment line to stdin
    } else {
        Box::new(BufReader::with_capacity(IO_CAPACITY, buf_reader)) // only comments or empty input
    }
}

/// Handle output serialization of CSV records on a channel Receiver to STDOUT.
fn serialize_csv_output<O>(
    mode:    &'static str,
    ordered: bool,
    rx_out:  Receiver<(usize, usize, Result<Option<Vec<O>>, Box<dyn Error + Send + Sync>>)>,
    mut wtr: csv::Writer<BufWriter<Stdout>>,
) where
    O: Serialize + Send,
{
    handle_output_records(
        mode, 
        ordered, 
        rx_out, 
        SERIALIZING, 
        |output_record| {
            wtr.serialize(output_record).map_err(|e| Box::new(e) as Box<dyn Error + Send + Sync>)
        }
    );
    flush_stream(mode, wtr);
}

/// Finish CSV streaming by flushing the output stream.
fn flush_stream(
    mode:    &'static str, 
    mut wtr: csv::Writer<BufWriter<Stdout>>,
) {
    if let Err(e) = wtr.flush(){
        line_error(mode, FLUSHING_OUTPUT, None, &e);
    }
}

/*  ------------------------------------------------------------------
additional general stream and record methods
------------------------------------------------------------------ */
/// Format a handling error on a data line and panic.
fn line_error(
    mode:      &'static str, 
    doing:     &'static str, 
    record_i0: Option<usize>, 
    e:         &dyn Error
) -> ! {
    if let Some(record_i0) = record_i0 {
        panic!("{} failed while {} at input line {}: {}", mode, doing, record_i0 + 1, e);
    } else {
        panic!("{} failed while {}: {}", mode, doing, e);
    }
}

/// Generic handling of Vec<O> output records on a channel receiver,
/// supporting caller-defined handlers for ordered and unordered output.
fn handle_output_records<O>(
    mode:        &'static str,
    ordered:     bool,
    rx_out:      Receiver<(usize, usize, Result<Option<Vec<O>>, Box<dyn Error + Send + Sync>>)>,
    handling:    &'static str, // a "doing" string for error messages
    mut handler: impl FnMut(O) -> Result<(), Box<dyn Error + Send + Sync>>,
) where
    O: Serialize + Send,
{
    // ordered output: buffer results to write in same order as input
    if ordered {
        let mut output_buffer: BTreeMap<usize, Option<Vec<O>>> = BTreeMap::new();
        let mut next_group_i0: usize = 0;
        for (record_i0, group_i0, result) in rx_out.iter() {
            match result {
                Ok(opt) => {
                    output_buffer.insert(group_i0, opt);
                    // output record groups are written in the order their corresponding input record (groups) were read
                    while let Some(buffered_option) = output_buffer.remove(&next_group_i0) {
                        if let Some(output_records) = buffered_option {
                            // record_parser order is maintained within output record groups
                            for output_record in output_records {
                                handler(output_record).unwrap_or_else(|e| {
                                    line_error(mode, handling, Some(record_i0), e.as_ref())
                                });
                            }
                        }
                        next_group_i0 += 1;
                    }
                },
                Err(e) => {
                    line_error(mode, PROCESSING, Some(record_i0), e.as_ref());
                }
            }
        }

    // unordered output: write records as they arrive
    // group_i0 is ignored even when meaningfully set for a grouped input
    } else {
        for (record_i0, _group_i0, result) in rx_out.iter() {
            match result {
                Ok(Some(output_records)) => {
                    // record_parser order is maintained within output record groups
                    for output_record in output_records {
                        handler(output_record).unwrap_or_else(|e| {
                            line_error(mode, handling, Some(record_i0), e.as_ref())
                        });
                    }
                },
                Ok(None) => {}, // no output records, do nothing
                Err(e) => {
                    line_error(mode, PROCESSING, Some(record_i0), e.as_ref());
                }
            }
        }
    }
}

/*  ------------------------------------------------------------------
grouping methods for keyed batch processing
------------------------------------------------------------------ */
/// Define a composite key for grouping based on potentially multiple fields.
fn get_composite_key<T>(
    mode:            &'static str,
    record:          &T, 
    grouping_fields: &[&str],
    record_i0:       usize,
) -> String
where 
    T: Serialize,
{
    if grouping_fields.len() == 1 {
        get_field_as_string(mode, record, grouping_fields[0], record_i0)
    } else {
        grouping_fields
            .iter()
            .map(|&grouping_field| get_field_as_string(mode, record, grouping_field, record_i0))
            .collect::<Vec<String>>()
            .join("__")
    }
}

/// Get the value of the key field in a record.
/// Return an error if the named field is not found in the record structure.
fn get_field_as_string<T: Serialize>(
    mode:           &'static str,
    record:         &T, 
    grouping_field: &str,
    record_i0:      usize,
) -> String {
    let value = serde_json::to_value(record).unwrap_or_else(|e| {
        line_error(mode, SERIALIZING_KEY, Some(record_i0), &e)
    });
    match value.get(grouping_field) {
        Some(v) => v.to_string().trim_matches('"').to_string(),
        None => {
            let msg = format!("Field '{}' not found in record", grouping_field);
            let e = Box::<dyn Error>::from(msg);
            line_error(mode, SERIALIZING_KEY, Some(record_i0), e.as_ref())
        }
    }
}
