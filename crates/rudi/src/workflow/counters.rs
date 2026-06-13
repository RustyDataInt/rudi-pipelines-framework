//! The Counters structure stores count values that can be passed to  
//! data processing functions as a single variable.
//! 
// dependencies
use std::collections::HashMap;
use num_format::{Locale, ToFormattedString};

// define a constant to print a separator line when printing counters
pub const COUNTER_SEPARATOR: &str = "------------------------------------------------------------";

/// The Counters struct stores keyed usize count values in a HashMap.
/// 
/// By convention, Counters objects are named `ctrs`.
pub struct Counters {
    tool:                  String,
    // regular counter fields, for things like record tallies
    keys:                  Vec<String>,
    descriptions:          HashMap<String, String>,
    counts:                HashMap<String, usize>,
    // keyed counter fields, for things like per-category tallies
    pub keyed_keys:            Vec<String>,
    keyed_descriptions:    HashMap<String, String>,
    pub keyed_counts:          HashMap<String, HashMap<String, usize>>,
    // indexed counter fields, for things like length distributions
    pub indexed_keys:          Vec<String>,
    indexed_column_labels: HashMap<String, String>,
    indexed_max_printed:   HashMap<String, usize>,
    indexed_descriptions:  HashMap<String, String>,
    pub indexed_counts:        HashMap<String, Vec<usize>>,
}
impl Counters {
    /// Create a new Counters instance with specified "regular" counters keys 
    /// initialized to zero.
    /// 
    /// Pass requested counters as a slice of tuples of form `&[(&str, &str)]`,
    /// where the first element of each tuple is the counter key and the second
    /// element is the counter description.
    /// 
    /// Pass (COUNTER_SEPARATOR, "".to_string()) to insert a separator line
    /// between groups of related counters.
    /// 
    /// By convention, Counters objects are named `ctrs`.
    pub fn new(tool: &str, counters: &[(&str, &str)]) -> Self {
        let mut keys: Vec<String> = Vec::new();
        let mut descriptions: HashMap<String, String> = HashMap::new();
        let mut counts: HashMap<String, usize> = HashMap::new();
        let mut n_separators = 0_usize;
        for (key, description) in counters {
            let mut final_key = key.to_string();
            if *key == COUNTER_SEPARATOR {
                final_key = format!("{}{}", COUNTER_SEPARATOR.to_string(), n_separators);
                descriptions.insert(final_key.clone(), COUNTER_SEPARATOR.to_string());
                n_separators += 1;
            } else {
                descriptions.insert(final_key.clone(), (*description).to_string());
                counts.insert(final_key.clone(), 0);
            }
            keys.push(final_key);
        }
        Counters {
            tool: tool.to_string(),
            keys,
            descriptions,
            counts,
            keyed_keys:     Vec::new(),
            keyed_descriptions: HashMap::new(),
            keyed_counts:   HashMap::new(),
            indexed_keys:   Vec::new(),
            indexed_column_labels: HashMap::new(),
            indexed_max_printed: HashMap::new(),
            indexed_descriptions: HashMap::new(),
            indexed_counts: HashMap::new(),
        }
    }
    /// Add one or more regular counters to the Counters instance.
    pub fn add_counters(&mut self, counters: &[(&str, &str)]) -> &mut Self {
        for (key, description) in counters {
            self.keys.push(key.to_string());
            self.descriptions.insert(key.to_string(), (*description).to_string());
            self.counts.insert(key.to_string(), 0);
        }
        self
    }
    /// Add one or more keyed counters to the Counters instance. 
    /// 
    /// Specify each counter as a tuple of (key, description).
    pub fn add_keyed_counters(&mut self, counters: &[(&str, &str)]) -> &mut Self {
        for (key, description) in counters {
            self.keyed_keys.push(key.to_string());
            self.keyed_descriptions.insert(key.to_string(), (*description).to_string());
            self.keyed_counts.insert(key.to_string(), HashMap::new());
        }
        self
    }
    /// Add one or more indexed counters to the Counters instance.
    /// 
    /// Specify each counter as a tuple of (key, column_label, max_printed, description).
    pub fn add_indexed_counters(&mut self, counters: &[(&str, &str, usize, &str)]) -> &mut Self {
        for (key, column_label, max_printed, description) in counters {
            self.indexed_keys.push(key.to_string());
            self.indexed_column_labels.insert(key.to_string(), (*column_label).to_string());
            self.indexed_max_printed.insert(key.to_string(), *max_printed);
            self.indexed_descriptions.insert(key.to_string(), (*description).to_string());
            self.indexed_counts.insert(key.to_string(), Vec::new());
        }
        self
    }
    /* ------------------------------------------------------------------
    regular counter methods
    ------------------------------------------------------------------ */
    /// Increment the count for the specified counter key by one.
    /// 
    /// Panic if the key is not found.
    pub fn increment(&mut self, key: &str) {
        let counter = self.counts.get_mut(key).unwrap_or_else(|| 
            panic!("Counters::increment error: key '{}' not found", key)
        );
        *counter += 1;
    }
    /// Increment the count for the specified counter key an arbitrary amount.
    /// 
    /// Panic if the key is not found.
    pub fn add_to(&mut self, key: &str, value: usize) {
        let counter = self.counts.get_mut(key).unwrap_or_else(|| 
            panic!("Counters::add_to error: key '{}' not found", key)
        );
        *counter += value;
    }
    /* ------------------------------------------------------------------
    keyed counter methods, with outer and inner keys, stored in HashMap
    ------------------------------------------------------------------ */
    /// Increment the count for the specified keyed counter key by one.
    /// 
    /// Panic if the outer key is not found.
    pub fn increment_keyed(&mut self, outer_key: &str, inner_key: &str) {
        let keyed_counter = self.keyed_counts.get_mut(outer_key).unwrap_or_else(|| 
            panic!("Counters::increment_keyed error: outer key '{}' not found", outer_key)
        );
        keyed_counter.entry(inner_key.to_string()).and_modify(|c| *c += 1).or_insert(1);
    }
    /// Increment the count for the specified keyed counter key an arbitrary amount.
    /// 
    /// Panic if the outer key is not found.
    pub fn add_to_keyed(&mut self, outer_key: &str, inner_key: &str, value: usize) {
        let keyed_counter = self.keyed_counts.get_mut(outer_key).unwrap_or_else(|| 
            panic!("Counters::add_to_keyed error: outer key '{}' not found", outer_key)
        );
        keyed_counter.entry(inner_key.to_string()).and_modify(|c| *c += value).or_insert(value);
    }
    /* ------------------------------------------------------------------
    indexed counter methods, with outer key and inner index, stored in Vec
    ------------------------------------------------------------------ */
    /// Increment the count for the specified indexed counter key by one.
    /// 
    /// Panic if the outer key is not found.
    pub fn increment_indexed(&mut self, key: &str, index: usize) {
        let indexed_counter = self.indexed_counts.get_mut(key).unwrap_or_else(|| 
            panic!("Counters::increment_indexed error: key '{}' not found", key)
        );
        indexed_counter.resize((index + 1).max(indexed_counter.len()), 0);
        indexed_counter[index] += 1;
    }
    /// Increment the count for the specified indexed counter key by one.
    /// 
    /// Panic if the outer key is not found.
    pub fn add_to_indexed(&mut self, key: &str, index: usize, value: usize) {
        let indexed_counter = self.indexed_counts.get_mut(key).unwrap_or_else(|| 
            panic!("Counters::add_to_indexed error: key '{}' not found", key)
        );
        indexed_counter.resize((index + 1).max(indexed_counter.len()), 0);
        indexed_counter[index] += value;
    }
    /* ------------------------------------------------------------------
    count reporting
    ------------------------------------------------------------------ */
    /// Print the value of all regular counters with their descriptions 
    /// to STDERR in the order they were initialized.
    pub fn print_all(&self) {
        for key in &self.keys {
            let description = self.descriptions.get(key).unwrap();
            if key.starts_with(COUNTER_SEPARATOR) {
                eprintln!("{}", description);
            } else {
                let count = self.counts.get(key).unwrap();
                eprintln!("{}\t{}\t{}\t{}", 
                    self.tool, 
                    count.to_formatted_string(&Locale::en), 
                    key, 
                    description
                );
            }
        }
    }
    /// Print the requested counters in groups of prefixes with
    /// group separator lines.
    pub fn print_grouped(&mut self, key_groups: &[&[&str]]) {
        let max_regular_count = Self::get_max_count_width(
            &self.counts.values().cloned().collect::<Vec<usize>>()
        );
        for key_group in key_groups {
            eprintln!("{}", COUNTER_SEPARATOR);
            for key in *key_group {
                let key = key.to_string();
                if self.keys.contains(&key){
                    eprintln!("{}\t{}\t{}\t{}", 
                        self.tool, 
                        Self::format_printed_count(self.counts.get(&key).unwrap(), &max_regular_count),
                        key, 
                        self.descriptions.get(&key).unwrap()
                    );
                } else if self.keyed_keys.contains(&key) {
                    let keyed_counter = self.keyed_counts.get(&key).unwrap();
                    let description = self.keyed_descriptions.get(&key).unwrap();
                    eprintln!("{}\t{}\t{}", self.tool, key, description);
                    if keyed_counter.is_empty() {
                        eprintln!("{}\t{} {}", self.tool, "no counts recorded for keyed counter", key);
                    } else {
                        let max_count = Self::get_max_count_width(
                            &keyed_counter.values().cloned().collect::<Vec<usize>>()
                        );
                        for inner_key in keyed_counter.keys() {
                            eprintln!("{}\t{}\t{}", 
                                self.tool, 
                                Self::format_printed_count(keyed_counter.get(inner_key).unwrap(), &max_count), 
                                inner_key
                            );
                        }
                    }
                } else if self.indexed_keys.contains(&key) {
                    let indexed_counter = self.indexed_counts.get_mut(&key).unwrap();
                    let column_label = self.indexed_column_labels.get(&key).unwrap();
                    let max_printed = self.indexed_max_printed.get(&key).unwrap();
                    let description = self.indexed_descriptions.get(&key).unwrap();
                    eprintln!("{}\t{}\t{}", self.tool, key, description);
                    eprintln!("{}\t{}\t{}", self.tool, "count", column_label);
                    if indexed_counter.is_empty() {
                        eprintln!("{}\t{} {}", self.tool, "no counts recorded for indexed counter", key);
                    } else {
                        let max_index = indexed_counter.len() - 1;
                        if max_index > *max_printed {
                            let above_max_printed: usize = indexed_counter[*max_printed + 1..].iter().sum();
                            indexed_counter[*max_printed] += above_max_printed;
                        };
                        let working_len = indexed_counter.len().min(*max_printed + 1);
                        let max_count = Self::get_max_count_width(
                            &indexed_counter[..working_len].to_vec()
                        );
                        for i in 0..working_len {
                            eprintln!("{}\t{}\t{}", 
                                self.tool, 
                                Self::format_printed_count(indexed_counter.get(i).unwrap_or(&0), &max_count), 
                                i,
                            );
                        }
                    }
                } else {
                    eprintln!("\t{}{}\t{}", self.tool, key, "no counts recorded for key");
                }
            }
        }
    }
    // adjust the padding of the printed counts based on the maximum count value
    fn get_max_count_width(counts: &[usize]) -> usize {
        let mut max_width = 1_usize;
        for count in counts {
            let width = count.to_formatted_string(&Locale::en).len();
            if width > max_width { max_width = width; }
        }
        max_width
    }
    fn format_printed_count(count: &usize, max_width: &usize) -> String {
        let count_str = count.to_formatted_string(&Locale::en);
        let padding = " ".repeat(max_width - count_str.len());
        format!("{}{}", padding, count_str)
    }
}
