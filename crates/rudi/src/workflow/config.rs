//! The Config structure stores configuration values that can be passed to  
//! data processing functions as a single variable.

// dependencies
use std::collections::HashMap;
use std::env;
use std::str::FromStr;
use paste::paste;

/// The Config struct gathers configuration values from environment variables
/// and those set in code as derived configuration values.
/// 
/// Values retrieved from environment variables are set using the `set_*_env`
/// methods, which panic if the environment variable was not set or if a recovered 
/// value cannot be parsed as the specified data type. 
/// 
/// Derived configuration values are set using the `set_*` or `set_*_list` methods.
/// 
/// Values are accessed using the `get_*` methods, which panic if the requested key 
/// was never set to a value.
/// 
/// Supported data types include bool, u8, usize, i32, f64, and String.
/// 
/// By convention, Config objects are named `cfg`.
pub struct Config {
    // String keys used for named environment variables
    pub bool:   HashMap<String, bool>, 
    pub u8:     HashMap<String, u8>,
    pub u32:    HashMap<String, u32>,
    pub usize:  HashMap<String, usize>,
    pub i32:    HashMap<String, i32>,
    pub f64:    HashMap<String, f64>,
    pub string: HashMap<String, String>,
}
impl Config {
    /// Create a new empty Config instance.
    /// 
    /// By convention, Config objects are named `cfg`.
    pub fn new() -> Self {
        Config {
            // String keys used for named environment variables
            bool:   HashMap::new(),
            u8:     HashMap::new(),
            u32:    HashMap::new(),
            usize:  HashMap::new(),
            i32:    HashMap::new(),
            f64:    HashMap::new(),
            string: HashMap::new(),
        }
    }
    /* ------------------------------------------------------------------
    special handling of bool setting from environment variables
    ------------------------------------------------------------------ */
    /// Set bool configuration values from environment variables.
    /// 
    /// Values are set to `true` unless the environment variable string value is
    /// one of "", "\s+", "0", "false", "FALSE", "na", "NA", "null", or "NULL".
    pub fn set_bool_env(&mut self, keys: &[&str]) {
        for &key in keys {
            let value_str = Self::get_env_string(key);
            self.bool.insert(key.to_string(), 
                value_str != "" && 
                !value_str.chars().all(char::is_whitespace) &&
                value_str != "0" && 
                value_str.to_lowercase() != "false" && 
                value_str.to_lowercase() != "na" && 
                value_str.to_lowercase() != "null"
            );
        }
    }
    /* ------------------------------------------------------------------
    special handling of String getting to use &str as argument
    ------------------------------------------------------------------ */
    /// Get a reference to a String configuration value by key.
    /// 
    /// Panic if the key is not found.
    pub fn get_string(&self, key: &str) -> &str {
        self.string.get(key).unwrap_or_else(|| Self::key_not_found(key, "String"))
    }
    /// Check if a String configuration value in a keyed HashMap equals the specified value. 
    /// 
    /// Panic if the key is not found.
    pub fn equals_string(&self, key: &str, value: &str) -> bool {
        self.get_string(key) == value
    }
    /* ------------------------------------------------------------------
    implementation helpers
    ------------------------------------------------------------------ */
    // get the initial string representation of an environment variable
    fn get_env_string(key: &str) -> String {
        match env::var_os(key) {
            Some(value) => value.to_string_lossy().to_string(),
            None => panic!("Environment variable {key} is not set."),
        }
    }
    // parse an environment variable string into the desired data type
    fn parse_env_string<T: FromStr>(key: &str, value: &str, data_type: &str) -> T {
        match value.parse::<T>() {
            Ok(parsed_value) => parsed_value,
            Err(_) => panic!("Environment variable {key} string value '{value}' could not be parsed as {data_type}."),
        }
    }
    fn key_not_found(key: &str, data_type: &str) -> ! {
        panic!("Config key {key} not found in {data_type} config HashMap; please call set_{data_type}[_env] first.")
    }
}

// macro to fill implementation methods for different data types
macro_rules! fill_set_env_methods {
    () => {};
    ($type_ident:ident, $type_ty:ty, $($tail:tt)* ) => {
        paste! {
            impl Config {
                /// Set typed configuration values from environment variables.
                /// 
                /// Panic if an environment variable was not set of if a retrieved  
                /// value cannot be parsed as the data type.
                pub fn [<set_ $type_ident _env>](&mut self, keys: &[&str]) {
                    for key in keys {
                        let value_str = Self::get_env_string(key);
                        self.[<$type_ident>].insert(key.to_string(), Self::parse_env_string(key, &value_str, stringify!($type_ty)));
                    }
                }
            }
        }
        fill_set_env_methods!($($tail)*);
    };
}
macro_rules! fill_set_methods {
    () => {};
    ($type_ident:ident, $type_ty:ty, $($tail:tt)* ) => {
        paste! {
            impl Config {
                /// Set a derived and typed configuration value from a key and value.
                /// 
                /// Any existing value is overridden.
                pub fn [<set_ $type_ident>](&mut self, key: &str, value: $type_ty) {
                    self.[<$type_ident>].insert(key.to_string(), value);
                }
                /// Set derived and typed configuration values from key/value pairs.
                /// 
                /// Any existing values are overridden.
                pub fn [<set_ $type_ident _list>](&mut self, key_value_pairs: &[(&str, $type_ty)]) {
                    for key_value_pair in key_value_pairs {
                        self.[<$type_ident>].insert(key_value_pair.0.to_string(), key_value_pair.1.clone());
                    }
                }
            }
        }
        fill_set_methods!($($tail)*);
    };
}
macro_rules! fill_get_methods {
    () => {};
    ($type_ident:ident, $type_ty:ty, $($tail:tt)* ) => {
        paste! {
            impl Config {
                /// Get a reference to a typed configuration value by key.
                /// 
                /// Panic if the key is not found.
                pub fn [<get_ $type_ident>](&self, key: &str) -> &$type_ty {
                    self.[<$type_ident>].get(key).unwrap_or_else(|| Self::key_not_found(key, stringify!($type_ty)))
                }
                /// Check if a typed configuration value in a keyed HashMap equals the specified value. 
                /// 
                /// Panic if the key is not found.
                pub fn [<equals_ $type_ident>](&self, key: &str, value: $type_ty) -> bool {
                    self.[<get_ $type_ident>](key) == &value
                }
            }
        }
        fill_get_methods!($($tail)*);
    };
}
fill_set_env_methods!(
    u8,     u8, // everything except bool, which is handled differently
    u32,    u32,
    usize,  usize, 
    i32,    i32, 
    f64,    f64, 
    string, String,
);
fill_set_methods!(
    bool,   bool,
    u8,     u8,
    u32,    u32,
    usize,  usize, 
    i32,    i32, 
    f64,    f64, 
    string, String, 
);
fill_get_methods!(
    bool,   bool, // everything except String, which is handled differently
    u8,     u8,
    u32,    u32,
    usize,  usize, 
    i32,    i32, 
    f64,    f64, 
);
