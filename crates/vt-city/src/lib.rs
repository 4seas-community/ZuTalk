//! A client for the "city": the community software a ZuTalk listener's
//! neighbours run to keep their events, residents and archive.
//!
//! A city stores nothing but signed records. People are the fingerprint of
//! the record that opened their account; an event, a channel, a recording and
//! every sentence of its transcript are records that link to one another.
//! There are no sessions and no auth headers: a server keeps a record because
//! its signature verifies and its author is someone the city knows.
//!
//! What this crate does with that:
//!
//! - [`link`] signs a resident in on this device by the city's own "link a
//!   new device" exchange, and [`identity`] holds the result;
//! - [`hub`] reads and posts records over HTTP, and [`calendar`] and
//!   [`channels`] reduce what was read to the events and channels a recorder
//!   chooses between;
//! - [`publish`] turns a finished recording's transcript and translations
//!   into the records the city's archive page reads.
//!
//! Everything a reader would refuse is refused here first, before signing:
//! a city's log is public and append-only, and a record that should not have
//! been written cannot be taken back.

mod didlog;
mod ed;
mod facts;
mod text;

pub mod calendar;
pub mod channels;
pub mod error;
pub mod hub;
pub mod identity;
pub mod jcs;
pub mod link;
pub mod publish;
pub mod record;

pub use error::{CityError, Result};
