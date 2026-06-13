// modules
pub mod streamer; // record streamer built on Rayon
pub mod fanner;   // record streamer built on Crossbeam parallel channels

// dependencies
use serde::de::{Deserializer, Visitor, SeqAccess};
use std::fmt;

/* ------------------------------------------------------------------
deserialization support methods
------------------------------------------------------------------ */
/// Deserialize all trailing fields of a record into a Vec<String>.
/// Add `#[serde(deserialize_with = "rudi::record::trailing_to_vec_string")]`
/// before the last field definition in your record struct, which should be of
/// type `Vec<String>`. Set `rs.flexible(true)` when initializing the RecordStreamer
/// if the number of trailing fields may vary between records.
pub fn trailing_to_vec_string<'de, D>(
    deserializer: D
) -> Result<Vec<String>, D::Error>
where
    D: Deserializer<'de>,
{
    struct TrailingVisitor;
    impl<'de> Visitor<'de> for TrailingVisitor {
        type Value = Vec<String>;
        fn expecting(&self, formatter: &mut fmt::Formatter) -> fmt::Result {
            formatter.write_str("a sequence of column values as strings")
        }
        fn visit_seq<A>(self, mut seq: A) -> Result<Self::Value, A::Error>
        where
            A: SeqAccess<'de>,
        {
            let mut value = Vec::new();
            while let Some(col) = seq.next_element::<String>()? {
                value.push(col);
            }
            Ok(value)
        }
    }
    deserializer.deserialize_seq(TrailingVisitor)
}
