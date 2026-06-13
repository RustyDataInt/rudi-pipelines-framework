//! RecordStreamer supports RuDI pipelines by providing
//! a structure to manipulate tabular records in data streams.
//! 
//! Data are read from STDIN and written to STDOUT to function in a Unix stream.
//! This makes it easy to create executable crates that can be chained together,
//! with each crate performing a specific task in a data processing pipeline.
//! 
//! A `record_parser` closure passed to a RecordStreamer does work on each record 
//! or group of records. This makes it easy to create executable crates that can 
//! be chained together, with each crate performing a specific task in a data 
//! processing pipeline.
//!
//! Functions are fast, without unnecessary copying and with efficient allocation 
//! of record vectors. Record parsing can often be done by reference to a record 
//! buffer, i.e., in place, unless records need to change structure.
//! 
//! # Usage Overview
//! 
//! Create a new RecordStreamer instance with default settings using
//! `RecordStreamer::new()`.
//!
//! Input records can be handled either:
//! - one record at a time using one of the `stream_xxx_xxx()` functions, or
//! - over multiple records in a sorted and keyed batch using one of the `group_by_xxx_xxx()` functions
//! 
//! Output records can be either:
//! - in-place modifications of input records using one of the `xxx_in_place_xxx()` functions, or
//! - entirely new records generated from input records using one of the `xxx_replace_xxx()` functions
//! In-place modification is faster but demands that the input and output record structures   
//! be the same. New record generation to replace input records allows the input and output 
//! record structures to differ and allows any number of output records to be generated from 
//! each input record.
//!  
//! Record/group parsing can be done either:
//! - serially using one of the xxx_xxx_serial() functions, or
//! - in parallel using one of the xxx_xxx_parallel() functions
//! Only benchmarking can determine which is faster for a given task, which will depend on 
//! the complexity of the parsing function. Notably, parallel processing if often
//! better handled using the rudi::RecordFanner, which uses Crossbeam channels for parallel
//! processing, in constrast to the RecordStreamer, which uses Rayon to iterate in parallel
//! over buffered vectors of input records.
//!
//! Input and output records are assumed to be:
//! - without headers, unless `has_headers()` is called on the RecordStreamer
//! - tab-delimited, unless `delimiter(b'<delimiter>')` is called on the RecordStreamer
//! - of a fixed number of columns, unless `flexible()` is called on the RecordStreamer
//! 
//! If `comment(Some(b'<char>'))` is called on the RecordStreamer to set a comment character, 
//! initial comment lines at the beginning of the input stream will be passed directly to 
//! the output stream. 
//! 
//! Fields in input records will be trimmed of leading and trailing whitespace 
//! unless `no_trim()` is called on the RecordStreamer.
//! 
//! Field quoting is disabled by default. To enable dynamic quoting, call 
//! `quote(b'<quote_char>')` on the RecordStreamer.
//!
//! # Record Parsing
//! 
//! Streaming is executed by calling one of the following methods on the RecordStreamer:
//! - `stream_in_place_serial()`
//! - `stream_in_place_parallel()`
//! - `stream_replace_serial()`
//! - `stream_replace_parallel()`
//! - `group_by_in_place_serial()`
//! - `group_by_in_place_parallel()`
//! - `group_by_replace_serial()`
//! - `group_by_replace_parallel()`
//! where the caller defines and provides:
//! - data structures that describe the input and output data format (I for InputRecord, O for OutputRecord)
//! - a `record_parser` function or closure that processes the data, returning:
//!   - Err(...) if an error occurred during record processing, or
//!   - for stream_in_place_xxx functions:
//!     - Ok(true) or Ok(false) indicating whether the (updated) record should be written to the output stream
//!   - for group_by_in_place_xxx functions:
//!     - Ok(Vec<usize>) carrying the 0-referenced indices of the (reordered) input records that should be written to the output stream, if any
//!   - for xxx_replace_xxx functions:
//!     - Ok(Vec<OutputRecord>) carrying the output record(s) resulting from processing of the input record(s), if any
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
//! # Mutable Captures
//! 
//! It is common for calling code to pass a closure to the RecordStreamer as
//! the record_parser argument, so that the closure can capture variables from
//! its environment. Only the `xxx__xxx_serial` RecordStreamer functions support
//! mutable captures, i.e., that allow the record_parser to modify captured variables,
//! as parallel functions cannot modify shared local variables safely due to concurrency
//! restrictions. Immutable local  captures are supported by all RecordStreamers.
//! 
//! # Error Handling
//! 
//! RecordStreamers are designed to work in an HPC data stream where the presumption is
//! that all records are valid and will be processed successfully, even if they are
//! filtered out and not written to the output stream. Accordingly, all RecordStreamers
//! panic on any error encountered during processing and create detailed error messages 
//! that identify the specific line in the input data stream that caused a failure. This
//! facilitates debugging when errors are isolated to rare lines in input data. Accordingly, 
//! your record_parser should not panic but should return Err(...) with a descriptive error 
//! message, or simply propagate errors `?`. RecordStreamers will append additional 
//! information including the input line number to your error message.

// dependencies
use std::error::Error;
use std::io::{stdin, stdout, Stdin, Stdout, BufRead, BufReader, Read, Write, Cursor};
use rayon::prelude::*;
use serde::{de::{DeserializeOwned}, Serialize};

/// Error types.
const DESERIALIZING:   &str = "deserializing data fields";
const PROCESSING:      &str = "processing data row(s)";
const WRITING:         &str = "writing output";
const SERIALIZING:     &str = "serializing record for grouping key extraction";

/// Initialize a record streamer.
pub struct RecordStreamer {
    has_headers: bool,
    comment:     Option<u8>,
    delimiter:   u8,
    quote:       Option<u8>,
    trim:        csv::Trim,
    flexible:    bool,
    mode:        String,
}
impl Default for RecordStreamer {
    fn default() -> RecordStreamer {
        RecordStreamer {
            has_headers: false,
            comment:     None,
            delimiter:   b'\t',
            quote:       None,
            trim:        csv::Trim::Fields,
            flexible:    false,
            mode:        String::new(),
        }
    }
}
impl RecordStreamer {

    /* ------------------------------------------------------------------
    public initialization methods, using a style similar to CSV Reader/Writer
    ------------------------------------------------------------------ */
    /// Create a new RecordStreamer instance with default settings.
    pub fn new() -> RecordStreamer {
        RecordStreamer::default()
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
    /// `stream_in_place_serial()` processes input records from STDIN to STDOUT:
    ///     - one at a time as they are encountered, without parallel processing
    ///     - in place, i.e., only filtering or updating the input record structure
    pub fn stream_in_place_serial <R, F>(
        &mut self, 
        mut record_parser: F
    )
    where
        R: DeserializeOwned + Serialize,
        F: FnMut(&mut R) -> Result<bool, Box<dyn Error>>,
    {
        self.mode = "RecordStreamer::stream_in_place_serial()".to_string();
        let (mut rdr, mut wtr) = self.init_io_streams(None);
        for (i0, line) in rdr.deserialize().enumerate() {
            let i1 = Some(i0 + 1);
            let mut input_record = line.unwrap_or_else(|e| 
                self.line_error(DESERIALIZING, i1, &e)
            );
            let keep = record_parser(&mut input_record).unwrap_or_else(|e| 
                self.line_error(PROCESSING, i1, e.as_ref())
            );
            if keep {
                wtr.serialize(input_record).unwrap_or_else(|e| 
                    self.line_error(WRITING, i1, &e)
                );
            }
        }
        self.flush_stream(wtr);
    }

    /// `stream_in_place_parallel()` processes input records from STDIN to STDOUT:
    ///     - one at a time as they are encountered, with parallel processing in batches
    ///     - in place, i.e., only filtering or updating the input record structure
    pub fn stream_in_place_parallel <R, F>(
        &mut self, 
        record_parser: F, 
        n_cpu: usize, 
        buffer_size: usize
    )
    where
        R: DeserializeOwned + Serialize + Send + Sync,
        F: Fn(&mut R) -> Result<bool, Box<dyn Error + Send + Sync>> + Send + Sync,
    {
        self.mode = "RecordStreamer::stream_in_place_parallel()".to_string();
        let (mut rdr, mut wtr) = self.init_io_streams(Some(n_cpu));
        let mut input_record_buffer: Vec<R> = Vec::with_capacity(buffer_size);
        for (i0, line) in rdr.deserialize().enumerate() {
            let input_record = line.unwrap_or_else(|e| 
                self.line_error(DESERIALIZING, Some(i0 + 1), &e)
            );
            input_record_buffer.push(input_record);
            if input_record_buffer.len() == buffer_size {
                self.do_stream_in_place_parallel(&mut wtr, &mut input_record_buffer, &record_parser, Some(i0));
                input_record_buffer.clear();
            }
        }
        self.do_stream_in_place_parallel(&mut wtr, &mut input_record_buffer, &record_parser, None);
        self.flush_stream(wtr);
    }

    /// `stream_replace_serial()` processes input records from STDIN to STDOUT:
    ///     - one at a time as they are encountered, without parallel processing
    ///     - where output records of arbitrary number and structure replace input records
    pub fn stream_replace_serial <I, O, F>(
        &mut self, 
        mut record_parser: F
    )
    where
        I: DeserializeOwned + Serialize,
        O: Serialize,
        F: FnMut(I) -> Result<Vec<O>, Box<dyn Error>>,
    {
        self.mode = "RecordStreamer::stream_replace_serial()".to_string();
        let (mut rdr, mut wtr) = self.init_io_streams(None);
        for (i0, line) in rdr.deserialize().enumerate() {
            let i1 = Some(i0 + 1);
            let input_record = line.unwrap_or_else(|e| 
                self.line_error(DESERIALIZING, i1, &e)
            );
            let output_records = record_parser(input_record).unwrap_or_else(|e| 
                self.line_error(PROCESSING, i1, e.as_ref())
            );
            for output_record in output_records {
                wtr.serialize(output_record).unwrap_or_else(|e| {
                    self.line_error(WRITING, i1, &e)
                });
            }
        }
        self.flush_stream(wtr);
    }

    /// `stream_replace_parallel()` processes input records from STDIN to STDOUT:
    ///     - one at a time as they are encountered, with parallel processing
    ///     - where output records of arbitrary number and structure replace input records
    /// 
    /// Notably, rudi::RecordFanner::stream() is often a better choice for parallel
    /// processing of single records with record replacement.
    pub fn stream_replace_parallel <I, O, F>(
        &mut self, 
        record_parser: F, 
        n_cpu: usize, 
        buffer_size: usize
    )
    where
        I: DeserializeOwned + Serialize + Send + Sync,
        O: Serialize + Send + Sync,
        F: Fn(&I) -> Result<Vec<O>, Box<dyn Error + Send + Sync>> + Send + Sync,
    {
        self.mode = "RecordStreamer::stream_replace_parallel()".to_string();
        let (mut rdr, mut wtr) = self.init_io_streams(Some(n_cpu));
        let mut input_record_buffer: Vec<I> = Vec::with_capacity(buffer_size);
        for (i0, line) in rdr.deserialize().enumerate() {
            let input_record = line.unwrap_or_else(|e| 
                self.line_error(DESERIALIZING, Some(i0 + 1), &e)
            );
            input_record_buffer.push(input_record);
            if input_record_buffer.len() == buffer_size {
                self.do_stream_replace_parallel(&mut wtr, &mut input_record_buffer, &record_parser, Some(i0));
                input_record_buffer.clear();
            }
        }
        self.do_stream_replace_parallel(&mut wtr, &mut input_record_buffer, &record_parser, None);
        self.flush_stream(wtr);
    }

    /// `group_by_in_place_serial()` processes input records from STDIN to STDOUT:
    ///     - in groups of records with the same sequential key, without parallel processing
    ///     - in place, i.e., only filtering, sorting or updating the input records
    pub fn group_by_in_place_serial <R, F>(
        &mut self, 
        mut record_parser: F, 
        grouping_fields: &[&str]
    )
    where
        R: DeserializeOwned + Serialize,
        F: FnMut(&mut [R]) -> Result<Vec<usize>, Box<dyn Error>>,
    {
        self.mode = "RecordStreamer::group_by_in_place_serial()".to_string();
        let (mut rdr, mut wtr) = self.init_io_streams(None);
        let mut input_record_group: Vec<R> = Vec::new();
        let mut previous_key: Option<String> = None;
        for (i0, line) in rdr.deserialize().enumerate() {
            let input_record = line.unwrap_or_else(|e| 
                self.line_error(DESERIALIZING, Some(i0 + 1), &e)
            );
            let this_key = self.get_composite_key(&input_record, grouping_fields, i0);
            if previous_key.as_ref().map_or(false, |k| k != &this_key) {
                self.do_group_by_in_place_serial(&mut wtr, &mut input_record_group, &mut record_parser, Some(i0));
                input_record_group.clear();
            }
            previous_key = Some(this_key);
            input_record_group.push(input_record);
        }
        self.do_group_by_in_place_serial(&mut wtr, &mut input_record_group, &mut record_parser, None);
        self.flush_stream(wtr);
    }

    /// `group_by_in_place_parallel()` processes input records from STDIN to STDOUT:
    ///     - in groups of records with the same sequential key, with parallel processing
    ///     - in place, i.e., only filtering, sorting or updating the input records
    pub fn group_by_in_place_parallel <R, F>(
        &mut self, 
        record_parser: F, 
        grouping_fields: &[&str],
        n_cpu: usize, 
        buffer_size: usize
    )
    where
        R: DeserializeOwned + Serialize + Send + Sync,
        F: Fn(&mut [R]) -> Result<Vec<usize>, Box<dyn Error + Send + Sync>> + Send + Sync,
    {
        self.mode = "RecordStreamer::group_by_in_place_parallel()".to_string();
        let (mut rdr, mut wtr) = self.init_io_streams(Some(n_cpu));
        let mut input_record_group_buffer: Vec<Vec<R>> = Vec::new();
        let mut input_record_group: Vec<R> = Vec::new();
        let mut previous_key: Option<String> = None;
        for (i0, line) in rdr.deserialize().enumerate() {
            let input_record = line.unwrap_or_else(|e| 
                self.line_error(DESERIALIZING, Some(i0 + 1), &e)
            );
            let this_key = self.get_composite_key(&input_record, grouping_fields, i0);
            if previous_key.as_ref().map_or(false, |k| k != &this_key) {
                input_record_group_buffer.push(input_record_group);
                input_record_group = Vec::new(); // prevents move error with input_record_group.clear(); must reallocate
                if input_record_group_buffer.len() == buffer_size {
                    self.do_group_by_in_place_parallel(&mut wtr, &mut input_record_group_buffer, &record_parser, Some(i0));
                    input_record_group_buffer.clear();
                }
            }
            previous_key = Some(this_key);
            input_record_group.push(input_record);
        }
        input_record_group_buffer.push(input_record_group);
        self.do_group_by_in_place_parallel(&mut wtr, &mut input_record_group_buffer, &record_parser, None);
        self.flush_stream(wtr);
    }

    /// `group_by_replace_serial()` processes input records from STDIN to STDOUT:
    ///     - in groups of records with the same sequential key, without parallel processing
    ///     - where output records of arbitrary number and structure replace input records
    pub fn group_by_replace_serial <I, O, F>(
        &mut self, 
        mut record_parser: F, 
        grouping_fields: &[&str]
    )
    where
        I: DeserializeOwned + Serialize,
        O: Serialize,
        F: FnMut(&[I]) -> Result<Vec<O>, Box<dyn Error>>,
    {
        self.mode = "RecordStreamer::group_by_replace_serial()".to_string();
        let (mut rdr, mut wtr) = self.init_io_streams(None);
        let mut input_record_group: Vec<I> = Vec::new();
        let mut previous_key: Option<String> = None;
        for (i0, line) in rdr.deserialize().enumerate() {
            let input_record = line.unwrap_or_else(|e| 
                self.line_error(DESERIALIZING, Some(i0 + 1), &e)
            );
            let this_key = self.get_composite_key(&input_record, grouping_fields, i0);
            if previous_key.as_ref().map_or(false, |k| k != &this_key) {
                self.do_group_by_replace_serial(&mut wtr, &input_record_group, &mut record_parser, Some(i0));
                input_record_group.clear();
            }
            previous_key = Some(this_key);
            input_record_group.push(input_record);
        }
        self.do_group_by_replace_serial(&mut wtr, &input_record_group, &mut record_parser, None);
        self.flush_stream(wtr);
    }

    /// `group_by_replace_parallel()` processes input records from STDIN to STDOUT:
    ///     - in groups of records with the same sequential key, with parallel processing
    ///     - where output records of arbitrary number and structure replace input records
    /// 
    /// Notably, rudi::RecordFanner::stream_by() is often a better choice for parallel
    /// processing of grouped records with record replacement.
    pub fn group_by_replace_parallel <I, O, F>(
        &mut self, 
        record_parser: F, 
        grouping_fields: &[&str],
        n_cpu: usize, 
        buffer_size: usize
    )
    where
        I: DeserializeOwned + Serialize + Send + Sync,
        O: Serialize + Send,
        F: Fn(&[I]) -> Result<Vec<O>, Box<dyn Error + Send + Sync>> + Send + Sync,
    {
        self.mode = "RecordStreamer::group_by_replace_parallel()".to_string();
        let (mut rdr, mut wtr) = self.init_io_streams(Some(n_cpu));
        let mut input_record_group_buffer: Vec<Vec<I>> = Vec::new();
        let mut input_record_group: Vec<I> = Vec::new();
        let mut previous_key: Option<String> = None;
        for (i0, line) in rdr.deserialize().enumerate() {
            let input_record = line.unwrap_or_else(|e| 
                self.line_error(DESERIALIZING, Some(i0 + 1), &e)
            );
            let this_key = self.get_composite_key(&input_record, grouping_fields, i0);
            if previous_key.as_ref().map_or(false, |k| k != &this_key) {
                input_record_group_buffer.push(input_record_group);
                input_record_group = Vec::new(); // prevents move error with input_record_group.clear(); must reallocate
                if input_record_group_buffer.len() == buffer_size {
                    self.do_group_by_replace_parallel(&mut wtr, &input_record_group_buffer, &record_parser, Some(i0));
                    input_record_group_buffer.clear();
                }
            }
            previous_key = Some(this_key);
            input_record_group.push(input_record);
        }
        input_record_group_buffer.push(input_record_group);
        self.do_group_by_replace_parallel(&mut wtr, &input_record_group_buffer, &record_parser, None);
        self.flush_stream(wtr);
    }

    /*  ------------------------------------------------------------------
    private stream and record methods
    ------------------------------------------------------------------ */

    // return a paired stream reader and writer for STDIN and STDOUT
    // by design, headers and delimiters are handled the same for both input and output streams
    fn init_io_streams(&self, n_cpu: Option<usize>) -> (
        csv::Reader<Box<dyn BufRead>>, 
        csv::Writer<Stdout>
    ) {
        let (quote_char, quoting, quote_style) = match self.quote {
            Some(quote_char) => (quote_char, true, csv::QuoteStyle::Necessary),
            None => (b'\0', false, csv::QuoteStyle::Never),
        };
        let stdin = stdin();
        let mut stdout = stdout();
        let reader: Box<dyn BufRead> = if let Some(comment_char) = self.comment {
            self.pass_initial_comment_lines(comment_char, &stdin, &mut stdout)
        } else {
            Box::new(BufReader::new(stdin.lock()))
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
        if let Some(n_cpu) = n_cpu {
            rayon::ThreadPoolBuilder::new().num_threads(n_cpu).build_global()
                .expect("RecordStreamer failed to initialize parallel processing");
        }
        (rdr, wtr)
    }

    // pass initial comment lines from STDIN to STDOUT
    fn pass_initial_comment_lines(
        &self, 
        comment_char: u8,
        stdin: &Stdin, 
        stdout: &mut Stdout
    ) -> Box<dyn BufRead> {
        let mut buf_reader = BufReader::new(stdin.lock());
        let mut line = String::new();
        let mut non_comment_line: Option<String> = None;
        loop {
            line.clear();
            let bytes_read = buf_reader.read_line(&mut line).unwrap_or_else(|e| {
                self.line_error("reading comment lines", None, &e)
            });
            if bytes_read == 0 { break; } // EOF
            if line.as_bytes()[0] == comment_char {
                stdout.write_all(line.as_bytes()).unwrap_or_else(|e| {
                    self.line_error("writing comment lines", None, &e)
                });
            } else {
                non_comment_line = Some(line.clone());
                break;
            }
        }
        if let Some(non_comment_line) = non_comment_line {
            let chained = Cursor::new(non_comment_line).chain(buf_reader);
            Box::new(BufReader::new(chained)) // prepend first non-comment line to stdin
        } else {
            Box::new(BufReader::new(buf_reader)) // only comments or empty input
        }
    }

    // format and return a handling error on a data line
    fn line_error(&self, doing: &str, i1: Option<usize>, e: &dyn Error) -> ! {
        if let Some(i1) = i1 {
            panic!("{} failed while {} at or near input line {}: {}", self.mode, doing, i1, e);
        } else {
            panic!("{} failed while {}: {}", self.mode, doing, e);
        }
    }

    // finish streaming by flushing the output stream
    fn flush_stream(&self, mut wtr: csv::Writer<Stdout>) {
        if let Err(e) = wtr.flush(){
            self.line_error("flushing final output", None, &e);
        }
    }

    /*  ------------------------------------------------------------------
    private methods for parallel processing (names match the corresponding calling methods above)
    ------------------------------------------------------------------ */
    fn do_stream_in_place_parallel<R, F>(
        &self,
        wtr: &mut csv::Writer<Stdout>, 
        input_record_buffer: &mut [R], 
        record_parser: F,
        i0: Option<usize>,
    )
    where
        R: DeserializeOwned + Serialize + Send + Sync,
        F: Fn(&mut R) -> Result<bool, Box<dyn Error + Send + Sync>> + Send + Sync,
    {
        let keep: Vec<_> = input_record_buffer
            .into_par_iter()
            .map(record_parser)
            .collect();
        let n = input_record_buffer.len(); // <= buffer_size
        for j in 0..n {
            match &keep[j] {
                Ok(true) => wtr.serialize(&input_record_buffer[j]).unwrap_or_else(|e| {
                    let i1 = if let Some(i0) = i0 { Some(i0 - n + j + 1) } else { None };
                    self.line_error(WRITING, i1, &e);
                }),
                Ok(false) => {}, // do not write the record
                Err(e) => {
                    let i1 = if let Some(i0) = i0 { Some(i0 - n + j + 1) } else { None };
                    self.line_error(PROCESSING, i1, e.as_ref());
                }
            }
        }
    }
    fn do_stream_replace_parallel<I, O, F>(
        &self,
        wtr: &mut csv::Writer<Stdout>, 
        input_record_buffer: &[I], 
        record_parser: F,
        i0: Option<usize>,
    )
    where
        I: DeserializeOwned + Serialize + Send + Sync,
        O: Serialize + Send + Sync,
        F: Fn(&I) -> Result<Vec<O>, Box<dyn Error + Send + Sync>> + Send + Sync,
    {
        let output: Vec<_> = input_record_buffer
            .into_par_iter()
            .map(record_parser)
            .collect();
        let n = input_record_buffer.len(); // <= buffer_size
        for j in 0..n {
            match &output[j] {
                Ok(output_records) => for output_record in output_records {
                    wtr.serialize(output_record).unwrap_or_else(|e| {
                        let i1 = if let Some(i0) = i0 { Some(i0 - n + j + 1) } else { None };
                        self.line_error(WRITING, i1, &e);
                    });
                },
                Err(e) => {
                    let i1 = if let Some(i0) = i0 { Some(i0 - n + j + 1) } else { None };
                    self.line_error(PROCESSING, i1, e.as_ref());
                }
            }
        }
    }
    fn do_group_by_in_place_serial<R, F>(
        &self,
        wtr: &mut csv::Writer<Stdout>, 
        input_record_group: &mut [R], 
        record_parser: &mut F,
        i0: Option<usize>,
    )
    where
        R: DeserializeOwned + Serialize,
        F: FnMut(&mut [R]) -> Result<Vec<usize>, Box<dyn Error>>,
    {
        let result = record_parser(input_record_group);
        let n_in  = input_record_group.len();
        match &result {
            Ok(indices) => { // indices should reflect the order of the input records after any sorting by the record_parser
                let n_out = indices.len();
                if n_out > n_in {
                    let err_msg = format!("Record parser returned {} indices, input record group only has {} records", n_out, n_in);
                    let i1 = if let Some(i0) = i0 { Some(i0 - n_in + 1) } else { None };
                    self.line_error(PROCESSING, i1, &*Box::<dyn Error>::from(err_msg));
                }
                for j in indices {
                    wtr.serialize(&input_record_group[*j]).unwrap_or_else(|e| {
                        let i1 = if let Some(i0) = i0 { Some(i0 - n_in + j + 1) } else { None };
                        self.line_error(WRITING, i1, &e);
                    });
                }
            },  
            Err(e) => {
                let i1 = if let Some(i0) = i0 { Some(i0 - n_in + 1) } else { None };
                self.line_error(PROCESSING, i1, e.as_ref());
            }
        }
    }
    fn do_group_by_in_place_parallel<R, F>(
        &self,
        wtr: &mut csv::Writer<Stdout>, 
        input_record_group_buffer: &mut [Vec<R>], 
        record_parser: F,
        i0: Option<usize>,
    )
    where
        R: DeserializeOwned + Serialize + Send + Sync,
        F: Fn(&mut [R]) -> Result<Vec<usize>, Box<dyn Error + Send + Sync>> + Send + Sync,
    {
        let results: Vec<_> = input_record_group_buffer
            .par_iter_mut()
            .map(|group | record_parser(group.as_mut_slice()))
            .collect();
        for j in 0..results.len() {
            let n_in = input_record_group_buffer[j].len();
            match &results[j] {
                Ok(indices) => {
                    let n_out = indices.len();
                    if n_out > n_in {
                        let err_msg = format!("Record parser returned {} indices, input record group only has {} records", n_out, n_in);
                        let i1 = if let Some(i0) = i0 { Some(i0 - n_in + 1) } else { None };
                        self.line_error(PROCESSING, i1, &*Box::<dyn Error>::from(err_msg));
                    }
                    for k in indices {
                        wtr.serialize(&input_record_group_buffer[j][*k]).unwrap_or_else(|e| {
                            let i1 = if let Some(i0) = i0 { Some(i0 - n_in + j + 1) } else { None }; // not especially accurate
                            self.line_error(WRITING, i1, &e);
                        });
                    }
                },  
                Err(e) => {
                    let i1 = if let Some(i0) = i0 { Some(i0 - n_in + 1) } else { None };
                    self.line_error(PROCESSING, i1, e.as_ref());
                }
            }
        }
    }
    fn do_group_by_replace_serial<I, O, F>(
        &self,
        wtr: &mut csv::Writer<Stdout>, 
        input_record_group: &[I], 
        record_parser: &mut F,
        i0: Option<usize>,
    )
    where
        I: DeserializeOwned + Serialize,
        O: Serialize,
        F: FnMut(&[I]) -> Result<Vec<O>, Box<dyn Error>>,
    {
        let result = record_parser(input_record_group);
        match &result {
            Ok(output_records) => for output_record in output_records {
                wtr.serialize(output_record).unwrap_or_else(|e| {
                    let i1 = if let Some(i0) = i0 { Some(i0 - input_record_group.len() + 1) } else { None };
                    self.line_error(WRITING, i1, &e);
                });
            },
            Err(e) => {
                let i1 = if let Some(i0) = i0 { Some(i0 - input_record_group.len() + 1) } else { None };
                self.line_error(PROCESSING, i1, e.as_ref());
            }
        }
    }
    fn do_group_by_replace_parallel<I, O, F>(
        &self,
        wtr: &mut csv::Writer<Stdout>, 
        input_record_group_buffer: &[Vec<I>], 
        record_parser: F,
        i0: Option<usize>,
    )
    where
        I: DeserializeOwned + Serialize + Send + Sync,
        O: Serialize + Send,
        F: Fn(&[I]) -> Result<Vec<O>, Box<dyn Error + Send + Sync>> + Send + Sync,
    {
        let results: Vec<_> = input_record_group_buffer
            .par_iter()
            .map(|group| record_parser(group.as_slice()))
            .collect();
        for j in 0..results.len() {
            match &results[j] {
                Ok(output_records) => for output_record in output_records {
                    wtr.serialize(output_record).unwrap_or_else(|e| {
                        let i1 = if let Some(i0) = i0 { Some(i0 - input_record_group_buffer[j].len() + 1) } else { None };
                        self.line_error(WRITING, i1, &e);
                    });
                },
                Err(e) => {
                    let i1 = if let Some(i0) = i0 { Some(i0 - input_record_group_buffer[j].len() + 1) } else { None };
                    self.line_error(PROCESSING, i1, e.as_ref());
                }
            }
        }
    }

    /*  ------------------------------------------------------------------
    grouping methods for keyed batch processing
    ------------------------------------------------------------------ */
    // define a composite key for grouping based on potentially multiple fields
    fn get_composite_key<T>(
        &self,
        record: &T, 
        grouping_fields: &[&str],
        i0: usize,
    ) -> String
    where 
        T: Serialize,
    {
        if grouping_fields.len() == 1 {
            self.get_field_as_string(record, grouping_fields[0], i0)
        } else {
            grouping_fields
                .iter()
                .map(|&grouping_field| self.get_field_as_string(record, grouping_field, i0))
                .collect::<Vec<String>>()
                .join("__")
        }
    }

    // get the value of the key field in a record
    // returns an error if the named field is not found in the record structure
    fn get_field_as_string<T: Serialize>(
        &self,
        record: &T, 
        grouping_field: &str,
        i0: usize,
    ) -> String {
        let value = serde_json::to_value(record).unwrap_or_else(|e| {
            self.line_error(SERIALIZING, Some(i0 + 1), &e)
        });
        match value.get(grouping_field) {
            Some(v) => v.to_string().trim_matches('"').to_string(),
            None => {
                let err_msg = format!("Field '{}' not found in record", grouping_field);
                self.line_error(SERIALIZING, Some(i0 + 1), &*Box::<dyn Error>::from(err_msg))
            }
        }
    }
}
