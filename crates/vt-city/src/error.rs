//! What can go wrong when talking to a city, in words the caller can log.
//!
//! Nothing here ever carries key material: a refusal names the signatures the
//! city would not keep (public by construction), and a malformed input is
//! described by what was wrong with its shape, never by its content.

/// A failure to read from, sign for, or deliver to a city.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum CityError {
    /// Input that the city's own software would not accept, caught before it
    /// was signed or sent. The text says which rule, not what the value was.
    #[error("malformed input: {0}")]
    Malformed(String),

    /// A signature, checksum or sealed box that did not verify.
    #[error("a signature or sealed message did not verify")]
    Crypto,

    /// The city listed one of our records as not kept. Which ones is in the
    /// `PostOutcome` the caller already holds; this is the verdict alone.
    #[error("the city did not keep a record this device signed")]
    Refused,

    /// The city answered, but not with success.
    #[error("the city answered HTTP {status}")]
    Http { status: u16 },

    /// The city's server could not be reached, or did not answer in time: no
    /// route, no name, no TLS, a connection that stalled. It says nothing
    /// about whether this machine is online — the path to one server fails
    /// often enough on its own — so callers must not word it that way.
    /// Retrying later is the only remedy.
    #[error("the city could not be reached")]
    Offline,

    /// The city would not store a file: none of the records it holds claims
    /// these bytes for someone it stores audio for. Either the record that
    /// names the file has not reached it, or its author may not add audio to
    /// that event. Sending the same bytes again changes nothing.
    #[error("the city would not store the file: nobody it serves has claimed it")]
    Unclaimed,

    /// The file is larger than the city stores.
    #[error("the file is larger than the city stores")]
    FileTooBig,

    /// The city has taken as much from this person as it takes in a day.
    /// `retry_after_secs` is how long it asked us to wait, when it said.
    #[error("the city has taken as much from this person as it takes in a day")]
    DailyCap { retry_after_secs: Option<u64> },

    /// The city's server is short of disk and takes no more files for now.
    #[error("the city's server has no room for the file")]
    ServerFull,

    /// The bytes that arrived were not the bytes the file's name promised:
    /// cut short, or changed on the way.
    #[error("the city did not receive the bytes the file's name promised")]
    BadFile,

    /// The other side called the exchange off.
    #[error("cancelled")]
    Cancelled,

    /// The city answered with something this client does not understand.
    #[error("the city's answer was not understood: {0}")]
    Protocol(String),
}

pub type Result<T> = std::result::Result<T, CityError>;

impl CityError {
    pub(crate) fn malformed(why: &'static str) -> Self {
        CityError::Malformed(why.to_string())
    }

    pub(crate) fn protocol(why: &'static str) -> Self {
        CityError::Protocol(why.to_string())
    }
}
