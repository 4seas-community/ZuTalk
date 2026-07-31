//! Encrypted, Notebook-scoped Context Packs for explicit Soniox sessions.
//!
//! Context Pack content is encrypted before it reaches SQLite. Compilation is
//! deterministic and fail-closed: a missing key, an untrusted source, a deleted
//! bound pack, or a cross-Notebook private pack aborts the entire preview.

use std::collections::HashSet;
use std::path::Path;
use std::sync::{Arc, Mutex};

use rusqlite::{params, Connection, OptionalExtension, Row};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use thiserror::Error;
use vt_crypto::{decrypt_chunk, encrypt_chunk, KeyProvider, SessionKey};

pub const CONTEXT_TEXT_MAX_BYTES: usize = 256 * 1024;
pub const CONTEXT_CSV_MAX_ROWS: usize = 1_000;
pub const CONTEXT_CSV_MAX_CELL_SCALARS: usize = 256;
pub const SONIOX_CONTEXT_MAX_SCALARS: usize = 8_000;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ContextPackScope {
    Private,
    Library,
}

impl ContextPackScope {
    fn as_str(self) -> &'static str {
        match self {
            Self::Private => "private",
            Self::Library => "library",
        }
    }

    fn parse(value: &str) -> Result<Self, ContextPackStoreError> {
        match value {
            "private" => Ok(Self::Private),
            "library" => Ok(Self::Library),
            other => Err(ContextPackStoreError::CorruptData(format!(
                "unknown Context Pack scope '{other}'"
            ))),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ContextSourceFormat {
    Text,
    Markdown,
    TranslationCsv,
}

impl ContextSourceFormat {
    fn as_str(self) -> &'static str {
        match self {
            Self::Text => "text",
            Self::Markdown => "markdown",
            Self::TranslationCsv => "translation_csv",
        }
    }

    fn parse(value: &str) -> Result<Self, ContextPackStoreError> {
        match value {
            "text" => Ok(Self::Text),
            "markdown" => Ok(Self::Markdown),
            "translation_csv" => Ok(Self::TranslationCsv),
            other => Err(ContextPackStoreError::CorruptData(format!(
                "unknown Context source format '{other}'"
            ))),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ContextContentKind {
    TranslationTerms,
    Terms,
    General,
    Text,
}

impl ContextContentKind {
    fn as_str(self) -> &'static str {
        match self {
            Self::TranslationTerms => "translation_terms",
            Self::Terms => "terms",
            Self::General => "general",
            Self::Text => "text",
        }
    }

    fn parse(value: &str) -> Result<Self, ContextPackStoreError> {
        match value {
            "translation_terms" => Ok(Self::TranslationTerms),
            "terms" => Ok(Self::Terms),
            "general" => Ok(Self::General),
            "text" => Ok(Self::Text),
            other => Err(ContextPackStoreError::CorruptData(format!(
                "unknown Context content kind '{other}'"
            ))),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ContextPackRecord {
    pub id: String,
    pub scope: ContextPackScope,
    pub owner_notebook_id: Option<String>,
    pub title: String,
    pub key_ref: String,
    pub revision: u64,
    pub created_at: String,
    pub updated_at: String,
    pub deleted_at: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ContextPackSourceRecord {
    pub id: String,
    pub pack_id: String,
    pub title: String,
    pub format: ContextSourceFormat,
    pub content_kind: ContextContentKind,
    pub plaintext_sha256: String,
    pub plaintext_bytes: u64,
    pub metadata_json: String,
    pub trusted: bool,
    pub revision: u64,
    pub created_at: String,
    pub updated_at: String,
    pub deleted_at: Option<String>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct NewContextSource {
    pub title: String,
    pub format: ContextSourceFormat,
    pub content_kind: ContextContentKind,
    pub content: Vec<u8>,
    pub metadata: Value,
}

impl NewContextSource {
    pub fn pasted_text(title: impl Into<String>, text: impl Into<String>) -> Self {
        Self {
            title: title.into(),
            format: ContextSourceFormat::Text,
            content_kind: ContextContentKind::Text,
            content: text.into().into_bytes(),
            metadata: Value::Object(Default::default()),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SonioxGeneralContext {
    pub key: String,
    pub value: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SonioxTranslationTerm {
    pub source: String,
    pub target: String,
}

/// Exact value placed under the Soniox WebSocket configuration's `context`
/// key. Field order is intentional and follows the MVP truncation priority.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct SonioxContext {
    #[serde(skip_serializing_if = "Vec::is_empty", default)]
    pub translation_terms: Vec<SonioxTranslationTerm>,
    #[serde(skip_serializing_if = "Vec::is_empty", default)]
    pub terms: Vec<String>,
    #[serde(skip_serializing_if = "Vec::is_empty", default)]
    pub general: Vec<SonioxGeneralContext>,
    #[serde(skip_serializing_if = "String::is_empty", default)]
    pub text: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ContextReceiptSource {
    pub pack_id: String,
    pub pack_scope: ContextPackScope,
    pub source_id: String,
    pub source_title: String,
    pub source_revision: u64,
    pub plaintext_sha256: String,
    pub included_items: u64,
    pub included_scalars: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ContextOmissionReason {
    Duplicate,
    BudgetExceeded,
    Truncated,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ContextOmission {
    pub pack_id: String,
    pub source_id: String,
    pub section: ContextContentKind,
    pub reason: ContextOmissionReason,
    pub omitted_items: u64,
    pub omitted_scalars: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ContextReceipt {
    pub notebook_id: String,
    pub context_sha256: String,
    pub serialized_scalars: u64,
    pub sources: Vec<ContextReceiptSource>,
    pub omissions: Vec<ContextOmission>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ContextCompilation {
    pub context: SonioxContext,
    pub context_json: String,
    pub receipt: ContextReceipt,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BoundContextPack {
    pub position: u64,
    pub pack: ContextPackRecord,
}

/// Schema tag written into every exported Pack document. Import refuses
/// anything else rather than guessing at an unknown layout.
pub const CONTEXT_PACK_DOCUMENT_SCHEMA: &str = "zulangue.context-pack.v1";

/// Upper bound on a Pack document accepted for import. Generous enough for a
/// Pack of maximum-size sources, small enough to reject a mistaken file.
pub const CONTEXT_PACK_DOCUMENT_MAX_BYTES: usize = 8 * 1024 * 1024;

/// One source inside an exported Pack document. `content` is plaintext: a
/// Pack document has left the Pack's encryption boundary by definition.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ContextPackDocumentSource {
    pub title: String,
    pub format: ContextSourceFormat,
    pub content_kind: ContextContentKind,
    pub sha256: String,
    pub content: String,
}

/// A whole Context Pack as one shareable, human-readable file.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ContextPackDocument {
    pub schema: String,
    pub title: String,
    pub sources: Vec<ContextPackDocumentSource>,
}

#[derive(Debug, Error)]
pub enum ContextPackStoreError {
    #[error("SQLite error: {0}")]
    Sqlite(#[from] rusqlite::Error),
    #[error("crypto error: {0}")]
    Crypto(#[from] vt_crypto::CryptoError),
    #[error("JSON error: {0}")]
    Json(#[from] serde_json::Error),
    #[error("Context Pack record not found: {0}")]
    NotFound(String),
    #[error("Context Pack ownership violation: {0}")]
    Ownership(String),
    #[error("Context Pack input is invalid: {0}")]
    Validation(String),
    #[error("Context Pack trust check failed: {0}")]
    Trust(String),
    #[error("Context Pack key is unavailable: {0}")]
    MissingKey(String),
    #[error("Context Pack revision or snapshot conflict: {0}")]
    Conflict(String),
    #[error("Context Pack data is corrupt: {0}")]
    CorruptData(String),
}

#[derive(Clone)]
pub struct ContextPackStore {
    conn: Arc<Mutex<Connection>>,
    keys: Arc<dyn KeyProvider>,
}

impl ContextPackStore {
    pub fn new(db_path: &Path, keys: Arc<dyn KeyProvider>) -> Result<Self, ContextPackStoreError> {
        let conn = Connection::open(db_path)?;
        conn.pragma_update(None, "foreign_keys", "ON")?;
        crate::migration::run_migrations(&conn)?;
        let store = Self {
            conn: Arc::new(Mutex::new(conn)),
            keys,
        };
        store.ensure_private_packs_for_existing_notebooks()?;
        Ok(store)
    }

    pub fn ensure_private_pack(
        &self,
        notebook_id: &str,
        title: Option<&str>,
    ) -> Result<ContextPackRecord, ContextPackStoreError> {
        require_nonempty("notebook_id", notebook_id)?;
        if let Some(existing) = self.get_private_pack(notebook_id)? {
            return Ok(existing);
        }
        let exists = self.conn.lock().unwrap().query_row(
            "SELECT EXISTS(SELECT 1 FROM notebooks WHERE id = ?1 AND deleted_at IS NULL)",
            [notebook_id],
            |row| row.get::<_, bool>(0),
        )?;
        if !exists {
            return Err(ContextPackStoreError::NotFound(format!(
                "notebook {notebook_id}"
            )));
        }
        self.create_pack(
            ContextPackScope::Private,
            Some(notebook_id),
            title.unwrap_or("Private Context"),
        )
        .or_else(|error| {
            // A concurrent caller may have won the partial unique index race.
            if matches!(error, ContextPackStoreError::Sqlite(_)) {
                if let Some(existing) = self.get_private_pack(notebook_id)? {
                    return Ok(existing);
                }
            }
            Err(error)
        })
    }

    pub fn create_library_pack(
        &self,
        title: &str,
    ) -> Result<ContextPackRecord, ContextPackStoreError> {
        self.create_pack(ContextPackScope::Library, None, title)
    }

    pub fn get_pack(
        &self,
        pack_id: &str,
    ) -> Result<Option<ContextPackRecord>, ContextPackStoreError> {
        self.conn
            .lock()
            .unwrap()
            .query_row(
                "SELECT id, scope, owner_notebook_id, title, key_ref, revision,
                        created_at, updated_at, deleted_at
                 FROM context_packs WHERE id = ?1",
                [pack_id],
                context_pack_from_row,
            )
            .optional()
            .map_err(Into::into)
    }

    pub fn get_private_pack(
        &self,
        notebook_id: &str,
    ) -> Result<Option<ContextPackRecord>, ContextPackStoreError> {
        self.conn
            .lock()
            .unwrap()
            .query_row(
                "SELECT id, scope, owner_notebook_id, title, key_ref, revision,
                        created_at, updated_at, deleted_at
                 FROM context_packs
                 WHERE scope = 'private' AND owner_notebook_id = ?1 AND deleted_at IS NULL",
                [notebook_id],
                context_pack_from_row,
            )
            .optional()
            .map_err(Into::into)
    }

    pub fn list_library_packs(&self) -> Result<Vec<ContextPackRecord>, ContextPackStoreError> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare(
            "SELECT id, scope, owner_notebook_id, title, key_ref, revision,
                    created_at, updated_at, deleted_at
             FROM context_packs WHERE scope = 'library' AND deleted_at IS NULL
             ORDER BY created_at ASC, id ASC",
        )?;
        let rows = stmt.query_map([], context_pack_from_row)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
    }

    pub fn bind_library_pack(
        &self,
        notebook_id: &str,
        pack_id: &str,
        position: u64,
    ) -> Result<(), ContextPackStoreError> {
        let pack = self.require_active_pack(pack_id)?;
        if pack.scope != ContextPackScope::Library {
            return Err(ContextPackStoreError::Ownership(
                "private Context Packs cannot be bound, including to their owner".into(),
            ));
        }
        let exists = self.conn.lock().unwrap().query_row(
            "SELECT EXISTS(SELECT 1 FROM notebooks WHERE id = ?1 AND deleted_at IS NULL)",
            [notebook_id],
            |row| row.get::<_, bool>(0),
        )?;
        if !exists {
            return Err(ContextPackStoreError::NotFound(format!(
                "notebook {notebook_id}"
            )));
        }
        let now = chrono::Utc::now().to_rfc3339();
        self.conn.lock().unwrap().execute(
            "INSERT INTO notebook_context_pack_bindings
             (notebook_id, pack_id, position, created_at) VALUES (?1, ?2, ?3, ?4)
             ON CONFLICT(notebook_id, pack_id) DO UPDATE SET position = excluded.position",
            params![notebook_id, pack_id, u64_to_i64(position, "position")?, now],
        )?;
        Ok(())
    }

    pub fn unbind_library_pack(
        &self,
        notebook_id: &str,
        pack_id: &str,
    ) -> Result<bool, ContextPackStoreError> {
        Ok(self.conn.lock().unwrap().execute(
            "DELETE FROM notebook_context_pack_bindings WHERE notebook_id = ?1 AND pack_id = ?2",
            params![notebook_id, pack_id],
        )? > 0)
    }

    pub fn list_bound_library_packs(
        &self,
        notebook_id: &str,
    ) -> Result<Vec<BoundContextPack>, ContextPackStoreError> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare(
            "SELECT b.position, p.id, p.scope, p.owner_notebook_id, p.title, p.key_ref,
                    p.revision, p.created_at, p.updated_at, p.deleted_at
             FROM notebook_context_pack_bindings b
             JOIN context_packs p ON p.id = b.pack_id
             WHERE b.notebook_id = ?1
             ORDER BY b.position ASC, b.created_at ASC, b.pack_id ASC",
        )?;
        let rows = stmt.query_map([notebook_id], |row| {
            let position =
                i64_to_u64(row.get(0)?, "binding position").map_err(to_sql_conversion_error)?;
            let scope: String = row.get(2)?;
            Ok(BoundContextPack {
                position,
                pack: ContextPackRecord {
                    id: row.get(1)?,
                    scope: ContextPackScope::parse(&scope).map_err(to_sql_conversion_error)?,
                    owner_notebook_id: row.get(3)?,
                    title: row.get(4)?,
                    key_ref: row.get(5)?,
                    revision: i64_to_u64(row.get(6)?, "pack revision")
                        .map_err(to_sql_conversion_error)?,
                    created_at: row.get(7)?,
                    updated_at: row.get(8)?,
                    deleted_at: row.get(9)?,
                },
            })
        })?;
        rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
    }

    pub fn import_source(
        &self,
        pack_id: &str,
        input: &NewContextSource,
    ) -> Result<ContextPackSourceRecord, ContextPackStoreError> {
        let pack = self.require_active_pack(pack_id)?;
        let validated = validate_source(input)?;
        let key = self.load_pack_key(&pack)?;
        let ciphertext = encrypt_chunk(&input.content, &key)?;
        let source_id = uuid::Uuid::new_v4().to_string();
        let now = chrono::Utc::now().to_rfc3339();
        let metadata_json = serde_json::to_string(&validated.metadata)?;
        let digest = sha256_hex(&input.content);
        let mut conn = self.conn.lock().unwrap();
        let tx = conn.transaction()?;
        tx.execute(
            "INSERT INTO context_pack_sources
             (id, pack_id, title, format, content_kind, ciphertext, plaintext_sha256,
              plaintext_bytes, metadata_json, trust_state, revision, created_at, updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, 'local_trusted', 0, ?10, ?10)",
            params![
                source_id,
                pack_id,
                normalize_title(&input.title, "Untitled Context Source"),
                input.format.as_str(),
                input.content_kind.as_str(),
                ciphertext,
                digest,
                usize_to_i64(input.content.len(), "plaintext_bytes")?,
                metadata_json,
                now,
            ],
        )?;
        tx.execute(
            "UPDATE context_packs SET revision = revision + 1, updated_at = ?1 WHERE id = ?2",
            params![now, pack_id],
        )?;
        tx.commit()?;
        drop(conn);
        self.get_source(&source_id)?
            .ok_or_else(|| ContextPackStoreError::NotFound(format!("Context source {source_id}")))
    }

    pub fn replace_source(
        &self,
        source_id: &str,
        expected_revision: u64,
        input: &NewContextSource,
    ) -> Result<ContextPackSourceRecord, ContextPackStoreError> {
        let current = self.require_active_source(source_id)?;
        let pack = self.require_active_pack(&current.pack_id)?;
        let validated = validate_source(input)?;
        let key = self.load_pack_key(&pack)?;
        let ciphertext = encrypt_chunk(&input.content, &key)?;
        let digest = sha256_hex(&input.content);
        let metadata_json = serde_json::to_string(&validated.metadata)?;
        let now = chrono::Utc::now().to_rfc3339();
        let mut conn = self.conn.lock().unwrap();
        let tx = conn.transaction()?;
        let updated = tx.execute(
            "UPDATE context_pack_sources
             SET title = ?1, format = ?2, content_kind = ?3, ciphertext = ?4,
                 plaintext_sha256 = ?5, plaintext_bytes = ?6, metadata_json = ?7,
                 revision = revision + 1, updated_at = ?8
             WHERE id = ?9 AND deleted_at IS NULL AND revision = ?10",
            params![
                normalize_title(&input.title, "Untitled Context Source"),
                input.format.as_str(),
                input.content_kind.as_str(),
                ciphertext,
                digest,
                usize_to_i64(input.content.len(), "plaintext_bytes")?,
                metadata_json,
                now,
                source_id,
                u64_to_i64(expected_revision, "expected_revision")?,
            ],
        )?;
        if updated == 0 {
            return Err(ContextPackStoreError::Conflict(format!(
                "source {source_id} expected revision {expected_revision}"
            )));
        }
        tx.execute(
            "UPDATE context_packs SET revision = revision + 1, updated_at = ?1 WHERE id = ?2",
            params![now, current.pack_id],
        )?;
        tx.commit()?;
        drop(conn);
        self.get_source(source_id)?
            .ok_or_else(|| ContextPackStoreError::NotFound(format!("Context source {source_id}")))
    }

    pub fn get_source(
        &self,
        source_id: &str,
    ) -> Result<Option<ContextPackSourceRecord>, ContextPackStoreError> {
        self.conn
            .lock()
            .unwrap()
            .query_row(SOURCE_SELECT_ID, [source_id], context_source_from_row)
            .optional()
            .map_err(Into::into)
    }

    pub fn list_sources(
        &self,
        pack_id: &str,
    ) -> Result<Vec<ContextPackSourceRecord>, ContextPackStoreError> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare(
            "SELECT id, pack_id, title, format, content_kind, plaintext_sha256,
                    plaintext_bytes, metadata_json, trust_state, revision,
                    created_at, updated_at, deleted_at
             FROM context_pack_sources
             WHERE pack_id = ?1 AND deleted_at IS NULL ORDER BY created_at ASC, id ASC",
        )?;
        let rows = stmt.query_map([pack_id], context_source_from_row)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
    }

    pub fn delete_source(&self, source_id: &str) -> Result<bool, ContextPackStoreError> {
        let now = chrono::Utc::now().to_rfc3339();
        let mut conn = self.conn.lock().unwrap();
        let tx = conn.transaction()?;
        let pack_id = tx
            .query_row(
                "SELECT pack_id FROM context_pack_sources WHERE id = ?1 AND deleted_at IS NULL",
                [source_id],
                |row| row.get::<_, String>(0),
            )
            .optional()?;
        let Some(pack_id) = pack_id else {
            return Ok(false);
        };
        tx.execute(
            "UPDATE context_pack_sources SET deleted_at = ?1, updated_at = ?1,
                    ciphertext = X'', revision = revision + 1 WHERE id = ?2",
            params![now, source_id],
        )?;
        tx.execute(
            "UPDATE context_packs SET revision = revision + 1, updated_at = ?1 WHERE id = ?2",
            params![now, pack_id],
        )?;
        tx.commit()?;
        Ok(true)
    }

    /// Decrypts one source for egress outside the Pack's encryption boundary.
    /// Callers own what happens next: the returned plaintext is no longer
    /// protected by the Pack key, so this is only for explicit user-initiated
    /// export.
    pub fn export_source_plaintext(
        &self,
        source_id: &str,
    ) -> Result<Vec<u8>, ContextPackStoreError> {
        let source = self.require_active_source(source_id)?;
        let pack = self.require_active_pack(&source.pack_id)?;
        self.read_source_plaintext(&pack, &source)
    }

    /// Serializes a whole Pack into one shareable document. Every source is
    /// decrypted, so the result is plaintext and no longer protected by the
    /// Pack key — only call this for an export the user explicitly asked for.
    pub fn export_pack_document(
        &self,
        pack_id: &str,
    ) -> Result<ContextPackDocument, ContextPackStoreError> {
        let pack = self.require_active_pack(pack_id)?;
        let records = self.list_sources(pack_id)?;
        if records.is_empty() {
            return Err(ContextPackStoreError::Validation(format!(
                "Context Pack '{}' has no sources to export",
                pack.title
            )));
        }
        let mut sources = Vec::with_capacity(records.len());
        for record in records {
            let plaintext = self.read_source_plaintext(&pack, &record)?;
            let content = String::from_utf8(plaintext).map_err(|_| {
                ContextPackStoreError::CorruptData(format!("source {} is not UTF-8", record.id))
            })?;
            sources.push(ContextPackDocumentSource {
                title: record.title,
                format: record.format,
                content_kind: record.content_kind,
                sha256: record.plaintext_sha256,
                content,
            });
        }
        Ok(ContextPackDocument {
            schema: CONTEXT_PACK_DOCUMENT_SCHEMA.to_string(),
            title: pack.title,
            sources,
        })
    }

    /// Materializes a Pack document as a new Library Pack with a fresh ID and
    /// a fresh key. Fails closed: a bad schema, a digest mismatch, or a
    /// rejected source aborts the whole import and leaves nothing behind.
    pub fn import_pack_document(
        &self,
        document: &ContextPackDocument,
        title_override: Option<&str>,
    ) -> Result<ContextPackRecord, ContextPackStoreError> {
        if document.schema != CONTEXT_PACK_DOCUMENT_SCHEMA {
            return Err(ContextPackStoreError::Validation(format!(
                "unsupported Context Pack document schema '{}'",
                document.schema
            )));
        }
        if document.sources.is_empty() {
            return Err(ContextPackStoreError::Validation(
                "Context Pack document contains no sources".into(),
            ));
        }
        for source in &document.sources {
            let actual = sha256_hex(source.content.as_bytes());
            if actual != source.sha256 {
                return Err(ContextPackStoreError::CorruptData(format!(
                    "source '{}' digest mismatch: expected {}, got {actual}",
                    source.title, source.sha256
                )));
            }
        }

        let title = title_override.unwrap_or(&document.title);
        let destination = self.create_library_pack(title)?;
        let result = (|| {
            for source in &document.sources {
                self.import_source(
                    &destination.id,
                    &NewContextSource {
                        title: source.title.clone(),
                        format: source.format,
                        content_kind: source.content_kind,
                        content: source.content.clone().into_bytes(),
                        metadata: serde_json::json!({"origin": "pack_document"}),
                    },
                )?;
            }
            self.require_active_pack(&destination.id)
        })();
        if result.is_err() {
            let _ = self.hard_delete_pack(&destination.id);
            let _ = self.keys.delete_key(&destination.key_ref);
        }
        result
    }

    /// Copies decrypted content through a fresh encryption boundary. The new
    /// Library Pack receives a new Pack ID, new source IDs, and a new key.
    pub fn copy_pack_to_library(
        &self,
        source_pack_id: &str,
        title: &str,
    ) -> Result<ContextPackRecord, ContextPackStoreError> {
        let source_pack = self.require_active_pack(source_pack_id)?;
        let sources = self.list_sources(source_pack_id)?;
        let destination = self.create_library_pack(title)?;
        let copy_result = (|| {
            for source in sources {
                let content = self.read_source_plaintext(&source_pack, &source)?;
                self.import_source(
                    &destination.id,
                    &NewContextSource {
                        title: source.title,
                        format: source.format,
                        content_kind: source.content_kind,
                        content,
                        metadata: serde_json::from_str(&source.metadata_json)?,
                    },
                )?;
            }
            self.require_active_pack(&destination.id)
        })();
        if copy_result.is_err() {
            let _ = self.hard_delete_pack(&destination.id);
            let _ = self.keys.delete_key(&destination.key_ref);
        }
        copy_result
    }

    /// Soft-deletes a Library Pack and destroys its encryption key. Existing
    /// bindings are deliberately retained so compilation fails closed instead
    /// of silently dropping previously previewed context.
    pub fn delete_library_pack(
        &self,
        pack_id: &str,
        expected_revision: u64,
    ) -> Result<bool, ContextPackStoreError> {
        // Destroy the key before tombstoning the row. If local key deletion
        // fails, the Pack must remain active so the operation can be retried.
        // Holding the store connection lock closes the revision race between
        // validation, key destruction, and the tombstone update. A crash after
        // key destruction is also retryable because a missing key is treated as
        // an idempotent success on the next call.
        let conn = self.conn.lock().unwrap();
        let pack = conn
            .query_row(
                "SELECT id, scope, owner_notebook_id, title, key_ref, revision,
                        created_at, updated_at, deleted_at
                 FROM context_packs WHERE id = ?1 AND deleted_at IS NULL",
                [pack_id],
                context_pack_from_row,
            )
            .optional()?
            .ok_or_else(|| ContextPackStoreError::NotFound(pack_id.to_string()))?;
        if pack.scope != ContextPackScope::Library {
            return Err(ContextPackStoreError::Ownership(
                "a Notebook's private Context Pack cannot be deleted".into(),
            ));
        }
        if pack.revision != expected_revision {
            return Err(ContextPackStoreError::Conflict(format!(
                "pack {pack_id} expected revision {expected_revision}"
            )));
        }
        match self.keys.delete_key(&pack.key_ref) {
            Ok(()) | Err(vt_crypto::CryptoError::KeyNotFound { .. }) => {}
            Err(error) => return Err(error.into()),
        }
        let now = chrono::Utc::now().to_rfc3339();
        let updated = conn.execute(
            "UPDATE context_packs SET deleted_at = ?1, updated_at = ?1, revision = revision + 1
             WHERE id = ?2 AND revision = ?3 AND deleted_at IS NULL",
            params![
                now,
                pack_id,
                u64_to_i64(expected_revision, "expected_revision")?
            ],
        )?;
        if updated == 0 {
            return Err(ContextPackStoreError::Conflict(format!(
                "pack {pack_id} expected revision {expected_revision}"
            )));
        }
        Ok(true)
    }

    pub fn compile_notebook_context(
        &self,
        notebook_id: &str,
    ) -> Result<ContextCompilation, ContextPackStoreError> {
        self.compile_notebook_context_with_limit(notebook_id, SONIOX_CONTEXT_MAX_SCALARS)
    }

    /// Public for deterministic boundary tests and preview tooling. Production
    /// callers should use the fixed 8,000-scalar method above.
    pub fn compile_notebook_context_with_limit(
        &self,
        notebook_id: &str,
        max_serialized_scalars: usize,
    ) -> Result<ContextCompilation, ContextPackStoreError> {
        if max_serialized_scalars < 2 {
            return Err(ContextPackStoreError::Validation(
                "context scalar budget must fit at least an empty JSON object".into(),
            ));
        }
        let private = self.ensure_private_pack(notebook_id, None)?;
        if private.owner_notebook_id.as_deref() != Some(notebook_id) {
            return Err(ContextPackStoreError::Ownership(format!(
                "private pack {} does not belong to notebook {notebook_id}",
                private.id
            )));
        }

        let mut ordered_packs = vec![private];
        for binding in self.list_bound_library_packs(notebook_id)? {
            if binding.pack.scope != ContextPackScope::Library
                || binding.pack.owner_notebook_id.is_some()
            {
                return Err(ContextPackStoreError::Ownership(format!(
                    "binding {} is not a Library Context Pack",
                    binding.pack.id
                )));
            }
            if binding.pack.deleted_at.is_some() {
                return Err(ContextPackStoreError::Trust(format!(
                    "bound Context Pack {} has been deleted",
                    binding.pack.id
                )));
            }
            ordered_packs.push(binding.pack);
        }

        let mut translations = Vec::new();
        let mut terms = Vec::new();
        let mut general = Vec::new();
        let mut texts = Vec::new();
        let mut receipt_sources = Vec::new();
        for pack in &ordered_packs {
            if pack.deleted_at.is_some() {
                return Err(ContextPackStoreError::Trust(format!(
                    "Context Pack {} has been deleted",
                    pack.id
                )));
            }
            let key = self.load_pack_key(pack)?;
            let sources = self.list_encrypted_sources(&pack.id)?;
            for source in sources {
                if !source.record.trusted {
                    return Err(ContextPackStoreError::Trust(format!(
                        "source {} is not locally trusted",
                        source.record.id
                    )));
                }
                let plaintext = decrypt_chunk(&source.ciphertext, &key)?;
                if sha256_hex(&plaintext) != source.record.plaintext_sha256 {
                    return Err(ContextPackStoreError::CorruptData(format!(
                        "source {} plaintext digest mismatch",
                        source.record.id
                    )));
                }
                let text = std::str::from_utf8(&plaintext).map_err(|_| {
                    ContextPackStoreError::CorruptData(format!(
                        "source {} is not UTF-8",
                        source.record.id
                    ))
                })?;
                let origin = CandidateOrigin {
                    pack_id: pack.id.clone(),
                    source_id: source.record.id.clone(),
                };
                receipt_sources.push(ContextReceiptSource {
                    pack_id: pack.id.clone(),
                    pack_scope: pack.scope,
                    source_id: source.record.id.clone(),
                    source_title: source.record.title.clone(),
                    source_revision: source.record.revision,
                    plaintext_sha256: source.record.plaintext_sha256.clone(),
                    included_items: 0,
                    included_scalars: 0,
                });
                match source.record.content_kind {
                    ContextContentKind::TranslationTerms => {
                        let parsed = parse_translation_csv(text)?;
                        for pair in parsed.rows {
                            translations.push(Candidate {
                                origin: origin.clone(),
                                value: SonioxTranslationTerm {
                                    source: pair.0.clone(),
                                    target: pair.1.clone(),
                                },
                            });
                            translations.push(Candidate {
                                origin: origin.clone(),
                                value: SonioxTranslationTerm {
                                    source: pair.1,
                                    target: pair.0,
                                },
                            });
                        }
                    }
                    ContextContentKind::Terms => {
                        for term in parse_terms(text)? {
                            terms.push(Candidate {
                                origin: origin.clone(),
                                value: term,
                            });
                        }
                    }
                    ContextContentKind::General => {
                        for value in parse_general(text)? {
                            general.push(Candidate {
                                origin: origin.clone(),
                                value,
                            });
                        }
                    }
                    ContextContentKind::Text => texts.push(Candidate {
                        origin,
                        value: text.trim().to_string(),
                    }),
                }
            }
        }

        let mut context = SonioxContext::default();
        let mut omissions = Vec::new();

        let mut seen_translation = HashSet::new();
        for candidate in translations {
            let fingerprint = (
                candidate.value.source.clone(),
                candidate.value.target.clone(),
            );
            if !seen_translation.insert(fingerprint) {
                record_omission(
                    &mut omissions,
                    &candidate.origin,
                    ContextContentKind::TranslationTerms,
                    ContextOmissionReason::Duplicate,
                    1,
                    candidate.value.source.chars().count() + candidate.value.target.chars().count(),
                );
                continue;
            }
            context.translation_terms.push(candidate.value.clone());
            if serialized_scalar_count(&context)? > max_serialized_scalars {
                context.translation_terms.pop();
                record_omission(
                    &mut omissions,
                    &candidate.origin,
                    ContextContentKind::TranslationTerms,
                    ContextOmissionReason::BudgetExceeded,
                    1,
                    candidate.value.source.chars().count() + candidate.value.target.chars().count(),
                );
            } else {
                record_included(
                    &mut receipt_sources,
                    &candidate.origin,
                    1,
                    candidate.value.source.chars().count() + candidate.value.target.chars().count(),
                );
            }
        }

        let mut seen_terms = HashSet::new();
        for candidate in terms {
            if !seen_terms.insert(candidate.value.clone()) {
                record_omission(
                    &mut omissions,
                    &candidate.origin,
                    ContextContentKind::Terms,
                    ContextOmissionReason::Duplicate,
                    1,
                    candidate.value.chars().count(),
                );
                continue;
            }
            context.terms.push(candidate.value.clone());
            if serialized_scalar_count(&context)? > max_serialized_scalars {
                context.terms.pop();
                record_omission(
                    &mut omissions,
                    &candidate.origin,
                    ContextContentKind::Terms,
                    ContextOmissionReason::BudgetExceeded,
                    1,
                    candidate.value.chars().count(),
                );
            } else {
                record_included(
                    &mut receipt_sources,
                    &candidate.origin,
                    1,
                    candidate.value.chars().count(),
                );
            }
        }

        let mut seen_general = HashSet::new();
        for candidate in general {
            let fingerprint = (candidate.value.key.clone(), candidate.value.value.clone());
            if !seen_general.insert(fingerprint) {
                record_omission(
                    &mut omissions,
                    &candidate.origin,
                    ContextContentKind::General,
                    ContextOmissionReason::Duplicate,
                    1,
                    candidate.value.key.chars().count() + candidate.value.value.chars().count(),
                );
                continue;
            }
            context.general.push(candidate.value.clone());
            if serialized_scalar_count(&context)? > max_serialized_scalars {
                context.general.pop();
                record_omission(
                    &mut omissions,
                    &candidate.origin,
                    ContextContentKind::General,
                    ContextOmissionReason::BudgetExceeded,
                    1,
                    candidate.value.key.chars().count() + candidate.value.value.chars().count(),
                );
            } else {
                record_included(
                    &mut receipt_sources,
                    &candidate.origin,
                    1,
                    candidate.value.key.chars().count() + candidate.value.value.chars().count(),
                );
            }
        }

        let mut seen_text = HashSet::new();
        for candidate in texts {
            if candidate.value.is_empty() {
                continue;
            }
            if !seen_text.insert(candidate.value.clone()) {
                record_omission(
                    &mut omissions,
                    &candidate.origin,
                    ContextContentKind::Text,
                    ContextOmissionReason::Duplicate,
                    1,
                    candidate.value.chars().count(),
                );
                continue;
            }
            let before = context.text.clone();
            let separator = if before.is_empty() { "" } else { "\n\n" };
            context.text = format!("{before}{separator}{}", candidate.value);
            if serialized_scalar_count(&context)? <= max_serialized_scalars {
                record_included(
                    &mut receipt_sources,
                    &candidate.origin,
                    1,
                    candidate.value.chars().count(),
                );
                continue;
            }
            context.text = before.clone();
            let total_scalars = candidate.value.chars().count();
            let included = largest_text_prefix_that_fits(
                &mut context,
                separator,
                &candidate.value,
                max_serialized_scalars,
            )?;
            if included == 0 {
                record_omission(
                    &mut omissions,
                    &candidate.origin,
                    ContextContentKind::Text,
                    ContextOmissionReason::BudgetExceeded,
                    1,
                    total_scalars,
                );
            } else if included < total_scalars {
                record_included(&mut receipt_sources, &candidate.origin, 1, included);
                record_omission(
                    &mut omissions,
                    &candidate.origin,
                    ContextContentKind::Text,
                    ContextOmissionReason::Truncated,
                    1,
                    total_scalars - included,
                );
            } else {
                record_included(&mut receipt_sources, &candidate.origin, 1, included);
            }
        }

        let context_json = serde_json::to_string(&context)?;
        let serialized_scalars = context_json.chars().count();
        debug_assert!(serialized_scalars <= max_serialized_scalars);
        let receipt = ContextReceipt {
            notebook_id: notebook_id.to_string(),
            context_sha256: sha256_hex(context_json.as_bytes()),
            serialized_scalars: usize_to_u64(serialized_scalars, "serialized scalars")?,
            sources: receipt_sources,
            omissions,
        };
        Ok(ContextCompilation {
            context,
            context_json,
            receipt,
        })
    }

    /// Persists the exact preview selected at recording start. The encrypted
    /// snapshot is write-once; later Pack edits cannot mutate this run.
    pub fn persist_run_snapshot(
        &self,
        run_id: &str,
        compilation: &ContextCompilation,
    ) -> Result<(), ContextPackStoreError> {
        validate_compilation(compilation)?;
        let key_ref = format!("zulangue.context-snapshot.{run_id}");
        let key = SessionKey::generate();
        self.keys.store_key(&key_ref, &key)?;
        let ciphertext = encrypt_chunk(compilation.context_json.as_bytes(), &key)?;
        let receipt_json = serde_json::to_string(&compilation.receipt)?;
        let updated = self.conn.lock().unwrap().execute(
            "UPDATE notebook_capture_runs
             SET context_receipt_json = ?1, context_snapshot_ciphertext = ?2,
                 context_snapshot_key_ref = ?3, context_snapshot_sha256 = ?4,
                 updated_at = ?5
             WHERE id = ?6 AND notebook_id = ?7
               AND context_snapshot_ciphertext IS NULL
               AND context_snapshot_key_ref IS NULL
               AND context_snapshot_sha256 IS NULL",
            params![
                receipt_json,
                ciphertext,
                key_ref,
                compilation.receipt.context_sha256,
                chrono::Utc::now().to_rfc3339(),
                run_id,
                compilation.receipt.notebook_id,
            ],
        );
        match updated {
            Ok(1) => Ok(()),
            Ok(_) => {
                let _ = self.keys.delete_key(&key_ref);
                Err(ContextPackStoreError::Conflict(format!(
                    "run {run_id} already has a Context snapshot or belongs to another Notebook"
                )))
            }
            Err(error) => {
                let _ = self.keys.delete_key(&key_ref);
                Err(error.into())
            }
        }
    }

    pub fn load_run_snapshot(
        &self,
        run_id: &str,
    ) -> Result<Option<ContextCompilation>, ContextPackStoreError> {
        let row = self
            .conn
            .lock()
            .unwrap()
            .query_row(
                "SELECT context_receipt_json, context_snapshot_ciphertext,
                        context_snapshot_key_ref, context_snapshot_sha256
                 FROM notebook_capture_runs WHERE id = ?1",
                [run_id],
                |row| {
                    Ok((
                        row.get::<_, Option<String>>(0)?,
                        row.get::<_, Option<Vec<u8>>>(1)?,
                        row.get::<_, Option<String>>(2)?,
                        row.get::<_, Option<String>>(3)?,
                    ))
                },
            )
            .optional()?;
        let Some((receipt_json, ciphertext, key_ref, digest)) = row else {
            return Ok(None);
        };
        let all_absent =
            receipt_json.is_none() && ciphertext.is_none() && key_ref.is_none() && digest.is_none();
        if all_absent {
            return Ok(None);
        }
        let (receipt_json, ciphertext, key_ref, digest) =
            match (receipt_json, ciphertext, key_ref, digest) {
                (Some(receipt), Some(ciphertext), Some(key_ref), Some(digest)) => {
                    (receipt, ciphertext, key_ref, digest)
                }
                _ => {
                    return Err(ContextPackStoreError::CorruptData(format!(
                        "run {run_id} has a partial Context snapshot"
                    )))
                }
            };
        if !self.keys.key_exists(&key_ref) {
            return Err(ContextPackStoreError::MissingKey(key_ref));
        }
        let key = self.keys.load_key(&key_ref)?;
        let plaintext = decrypt_chunk(&ciphertext, &key)?;
        if sha256_hex(&plaintext) != digest {
            return Err(ContextPackStoreError::CorruptData(format!(
                "run {run_id} Context snapshot digest mismatch"
            )));
        }
        let context_json = String::from_utf8(plaintext).map_err(|_| {
            ContextPackStoreError::CorruptData(format!(
                "run {run_id} Context snapshot is not UTF-8"
            ))
        })?;
        let context: SonioxContext = serde_json::from_str(&context_json)?;
        let receipt: ContextReceipt = serde_json::from_str(&receipt_json)?;
        let compilation = ContextCompilation {
            context,
            context_json,
            receipt,
        };
        validate_compilation(&compilation)?;
        Ok(Some(compilation))
    }

    /// Marks a persisted snapshot as actually accepted by the remote stream.
    /// Persisting/previewing alone is never treated as "Context applied".
    pub fn mark_context_applied(
        &self,
        run_id: &str,
        expected_context_sha256: &str,
    ) -> Result<String, ContextPackStoreError> {
        require_nonempty("expected context digest", expected_context_sha256)?;
        let current = self
            .conn
            .lock()
            .unwrap()
            .query_row(
                "SELECT context_snapshot_sha256, context_receipt_json, context_applied_at,
                        remote_health
                 FROM notebook_capture_runs WHERE id = ?1",
                [run_id],
                |row| {
                    Ok((
                        row.get::<_, Option<String>>(0)?,
                        row.get::<_, Option<String>>(1)?,
                        row.get::<_, Option<String>>(2)?,
                        row.get::<_, String>(3)?,
                    ))
                },
            )
            .optional()?
            .ok_or_else(|| ContextPackStoreError::NotFound(format!("capture run {run_id}")))?;
        if current.0.as_deref() != Some(expected_context_sha256) || current.1.is_none() {
            return Err(ContextPackStoreError::Conflict(format!(
                "run {run_id} does not contain the expected immutable Context receipt"
            )));
        }
        if let Some(applied_at) = current.2 {
            return Ok(applied_at);
        }
        if current.3 != "live" {
            return Err(ContextPackStoreError::Conflict(format!(
                "run {run_id} cannot mark Context applied before the remote stream is live"
            )));
        }
        let now = chrono::Utc::now().to_rfc3339();
        let updated = self.conn.lock().unwrap().execute(
            "UPDATE notebook_capture_runs SET context_applied_at = ?1, updated_at = ?1
             WHERE id = ?2 AND context_snapshot_sha256 = ?3
               AND context_receipt_json IS NOT NULL AND context_applied_at IS NULL
               AND remote_health = 'live'",
            params![now, run_id, expected_context_sha256],
        )?;
        if updated != 1 {
            return Err(ContextPackStoreError::Conflict(format!(
                "run {run_id} Context applied state changed concurrently"
            )));
        }
        Ok(now)
    }

    fn create_pack(
        &self,
        scope: ContextPackScope,
        owner_notebook_id: Option<&str>,
        title: &str,
    ) -> Result<ContextPackRecord, ContextPackStoreError> {
        let title = normalize_title(title, "Untitled Context Pack");
        if (scope == ContextPackScope::Private) != owner_notebook_id.is_some() {
            return Err(ContextPackStoreError::Validation(
                "private Packs require one owner; Library Packs cannot have one".into(),
            ));
        }
        let id = uuid::Uuid::new_v4().to_string();
        let key_ref = format!("zulangue.context-pack.{id}");
        let key = SessionKey::generate();
        self.keys.store_key(&key_ref, &key)?;
        let now = chrono::Utc::now().to_rfc3339();
        let result = self.conn.lock().unwrap().execute(
            "INSERT INTO context_packs
             (id, scope, owner_notebook_id, title, key_ref, revision, created_at, updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5, 0, ?6, ?6)",
            params![id, scope.as_str(), owner_notebook_id, title, key_ref, now],
        );
        if let Err(error) = result {
            let _ = self.keys.delete_key(&key_ref);
            return Err(error.into());
        }
        self.get_pack(&id)?
            .ok_or_else(|| ContextPackStoreError::NotFound(format!("new Context Pack {id}")))
    }

    fn ensure_private_packs_for_existing_notebooks(&self) -> Result<(), ContextPackStoreError> {
        let notebook_ids = {
            let conn = self.conn.lock().unwrap();
            let mut stmt = conn.prepare(
                "SELECT id FROM notebooks WHERE deleted_at IS NULL ORDER BY created_at ASC, id ASC",
            )?;
            let rows = stmt.query_map([], |row| row.get::<_, String>(0))?;
            rows.collect::<Result<Vec<_>, _>>()?
        };
        for notebook_id in notebook_ids {
            self.ensure_private_pack(&notebook_id, None)?;
        }
        Ok(())
    }

    fn require_active_pack(
        &self,
        pack_id: &str,
    ) -> Result<ContextPackRecord, ContextPackStoreError> {
        let pack = self
            .get_pack(pack_id)?
            .ok_or_else(|| ContextPackStoreError::NotFound(format!("Context Pack {pack_id}")))?;
        if pack.deleted_at.is_some() {
            return Err(ContextPackStoreError::Trust(format!(
                "Context Pack {pack_id} is deleted"
            )));
        }
        Ok(pack)
    }

    fn require_active_source(
        &self,
        source_id: &str,
    ) -> Result<ContextPackSourceRecord, ContextPackStoreError> {
        let source = self.get_source(source_id)?.ok_or_else(|| {
            ContextPackStoreError::NotFound(format!("Context source {source_id}"))
        })?;
        if source.deleted_at.is_some() {
            return Err(ContextPackStoreError::Trust(format!(
                "Context source {source_id} is deleted"
            )));
        }
        Ok(source)
    }

    fn load_pack_key(&self, pack: &ContextPackRecord) -> Result<SessionKey, ContextPackStoreError> {
        if !self.keys.key_exists(&pack.key_ref) {
            return Err(ContextPackStoreError::MissingKey(pack.key_ref.clone()));
        }
        self.keys.load_key(&pack.key_ref).map_err(Into::into)
    }

    fn list_encrypted_sources(
        &self,
        pack_id: &str,
    ) -> Result<Vec<EncryptedSource>, ContextPackStoreError> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare(
            "SELECT id, pack_id, title, format, content_kind, plaintext_sha256,
                    plaintext_bytes, metadata_json, trust_state, revision,
                    created_at, updated_at, deleted_at, ciphertext
             FROM context_pack_sources
             WHERE pack_id = ?1 AND deleted_at IS NULL ORDER BY created_at ASC, id ASC",
        )?;
        let rows = stmt.query_map([pack_id], |row| {
            Ok(EncryptedSource {
                record: context_source_from_row(row)?,
                ciphertext: row.get(13)?,
            })
        })?;
        rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
    }

    fn read_source_plaintext(
        &self,
        pack: &ContextPackRecord,
        source: &ContextPackSourceRecord,
    ) -> Result<Vec<u8>, ContextPackStoreError> {
        if !source.trusted || source.deleted_at.is_some() {
            return Err(ContextPackStoreError::Trust(format!(
                "source {} is unavailable or untrusted",
                source.id
            )));
        }
        let encrypted = self
            .list_encrypted_sources(&pack.id)?
            .into_iter()
            .find(|value| value.record.id == source.id)
            .ok_or_else(|| {
                ContextPackStoreError::NotFound(format!("Context source {}", source.id))
            })?;
        let key = self.load_pack_key(pack)?;
        let plaintext = decrypt_chunk(&encrypted.ciphertext, &key)?;
        if sha256_hex(&plaintext) != source.plaintext_sha256 {
            return Err(ContextPackStoreError::CorruptData(format!(
                "source {} plaintext digest mismatch",
                source.id
            )));
        }
        Ok(plaintext)
    }

    fn hard_delete_pack(&self, pack_id: &str) -> Result<(), ContextPackStoreError> {
        self.conn
            .lock()
            .unwrap()
            .execute("DELETE FROM context_packs WHERE id = ?1", [pack_id])?;
        Ok(())
    }
}

const SOURCE_SELECT_ID: &str = "SELECT id, pack_id, title, format, content_kind, plaintext_sha256,
            plaintext_bytes, metadata_json, trust_state, revision,
            created_at, updated_at, deleted_at
     FROM context_pack_sources WHERE id = ?1";

#[derive(Debug)]
struct EncryptedSource {
    record: ContextPackSourceRecord,
    ciphertext: Vec<u8>,
}

#[derive(Debug, Clone)]
struct CandidateOrigin {
    pack_id: String,
    source_id: String,
}

#[derive(Debug, Clone)]
struct Candidate<T> {
    origin: CandidateOrigin,
    value: T,
}

struct ValidatedSource {
    metadata: Value,
}

#[derive(Debug, PartialEq, Eq)]
struct ParsedTranslationCsv {
    language_a: String,
    language_b: String,
    rows: Vec<(String, String)>,
}

fn context_pack_from_row(row: &Row<'_>) -> rusqlite::Result<ContextPackRecord> {
    let scope: String = row.get(1)?;
    Ok(ContextPackRecord {
        id: row.get(0)?,
        scope: ContextPackScope::parse(&scope).map_err(to_sql_conversion_error)?,
        owner_notebook_id: row.get(2)?,
        title: row.get(3)?,
        key_ref: row.get(4)?,
        revision: i64_to_u64(row.get(5)?, "pack revision").map_err(to_sql_conversion_error)?,
        created_at: row.get(6)?,
        updated_at: row.get(7)?,
        deleted_at: row.get(8)?,
    })
}

fn context_source_from_row(row: &Row<'_>) -> rusqlite::Result<ContextPackSourceRecord> {
    let format: String = row.get(3)?;
    let content_kind: String = row.get(4)?;
    let trust_state: String = row.get(8)?;
    let trusted = match trust_state.as_str() {
        "local_trusted" => true,
        "untrusted" => false,
        other => {
            return Err(to_sql_conversion_error(ContextPackStoreError::CorruptData(
                format!("unknown Context source trust state '{other}'"),
            )))
        }
    };
    Ok(ContextPackSourceRecord {
        id: row.get(0)?,
        pack_id: row.get(1)?,
        title: row.get(2)?,
        format: ContextSourceFormat::parse(&format).map_err(to_sql_conversion_error)?,
        content_kind: ContextContentKind::parse(&content_kind).map_err(to_sql_conversion_error)?,
        plaintext_sha256: row.get(5)?,
        plaintext_bytes: i64_to_u64(row.get(6)?, "plaintext bytes")
            .map_err(to_sql_conversion_error)?,
        metadata_json: row.get(7)?,
        trusted,
        revision: i64_to_u64(row.get(9)?, "source revision").map_err(to_sql_conversion_error)?,
        created_at: row.get(10)?,
        updated_at: row.get(11)?,
        deleted_at: row.get(12)?,
    })
}

fn validate_source(input: &NewContextSource) -> Result<ValidatedSource, ContextPackStoreError> {
    require_nonempty("source title", &input.title)?;
    if !input.metadata.is_object() {
        return Err(ContextPackStoreError::Validation(
            "source metadata must be a JSON object".into(),
        ));
    }
    let text = std::str::from_utf8(&input.content)
        .map_err(|_| ContextPackStoreError::Validation("source must be valid UTF-8".into()))?;
    if text.trim().is_empty() {
        return Err(ContextPackStoreError::Validation(
            "Context source cannot be empty".into(),
        ));
    }
    let mut metadata = input.metadata.clone();
    match (input.format, input.content_kind) {
        (ContextSourceFormat::TranslationCsv, ContextContentKind::TranslationTerms) => {
            if input.content.len() > 1024 * 1024 {
                return Err(ContextPackStoreError::Validation(
                    "translation CSV exceeds the 1 MiB safety limit".into(),
                ));
            }
            let parsed = parse_translation_csv(text)?;
            let object = metadata.as_object_mut().expect("validated object");
            object.insert("language_a".into(), Value::String(parsed.language_a));
            object.insert("language_b".into(), Value::String(parsed.language_b));
            object.insert("direction".into(), Value::String("two_way".into()));
            object.insert(
                "row_count".into(),
                Value::Number(serde_json::Number::from(parsed.rows.len() as u64)),
            );
        }
        (ContextSourceFormat::TranslationCsv, _) | (_, ContextContentKind::TranslationTerms) => {
            return Err(ContextPackStoreError::Validation(
                "translation_terms require the bilingual CSV format".into(),
            ));
        }
        (ContextSourceFormat::Text | ContextSourceFormat::Markdown, kind) => {
            if input.content.len() > CONTEXT_TEXT_MAX_BYTES {
                return Err(ContextPackStoreError::Validation(format!(
                    "text/Markdown source exceeds {CONTEXT_TEXT_MAX_BYTES} bytes"
                )));
            }
            match kind {
                ContextContentKind::Terms => {
                    parse_terms(text)?;
                }
                ContextContentKind::General => {
                    parse_general(text)?;
                }
                ContextContentKind::Text => {}
                ContextContentKind::TranslationTerms => unreachable!(),
            }
        }
    }
    Ok(ValidatedSource { metadata })
}

fn parse_terms(text: &str) -> Result<Vec<String>, ContextPackStoreError> {
    let terms = text
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .map(str::to_string)
        .collect::<Vec<_>>();
    if terms.is_empty() {
        return Err(ContextPackStoreError::Validation(
            "terms source contains no non-empty terms".into(),
        ));
    }
    if terms.len() > CONTEXT_CSV_MAX_ROWS {
        return Err(ContextPackStoreError::Validation(
            "terms source exceeds 1,000 entries".into(),
        ));
    }
    if let Some(term) = terms
        .iter()
        .find(|term| term.chars().count() > CONTEXT_CSV_MAX_CELL_SCALARS)
    {
        return Err(ContextPackStoreError::Validation(format!(
            "term exceeds {CONTEXT_CSV_MAX_CELL_SCALARS} Unicode scalars: {}",
            prefix_chars(term, 32)
        )));
    }
    Ok(terms)
}

fn parse_general(text: &str) -> Result<Vec<SonioxGeneralContext>, ContextPackStoreError> {
    if let Ok(Value::Object(object)) = serde_json::from_str::<Value>(text) {
        let mut pairs = Vec::with_capacity(object.len());
        for (key, value) in object {
            let Value::String(value) = value else {
                return Err(ContextPackStoreError::Validation(
                    "general Context JSON values must be strings".into(),
                ));
            };
            validate_general_pair(&key, &value)?;
            pairs.push(SonioxGeneralContext { key, value });
        }
        if pairs.is_empty() {
            return Err(ContextPackStoreError::Validation(
                "general Context object cannot be empty".into(),
            ));
        }
        return Ok(pairs);
    }

    let mut pairs = Vec::new();
    for line in text.lines().map(str::trim).filter(|line| !line.is_empty()) {
        let split = line
            .split_once('=')
            .or_else(|| line.split_once(':'))
            .ok_or_else(|| {
                ContextPackStoreError::Validation(
                    "general Context lines must use key=value or key:value".into(),
                )
            })?;
        let key = split.0.trim();
        let value = split.1.trim();
        validate_general_pair(key, value)?;
        pairs.push(SonioxGeneralContext {
            key: key.to_string(),
            value: value.to_string(),
        });
    }
    if pairs.is_empty() {
        return Err(ContextPackStoreError::Validation(
            "general Context source contains no entries".into(),
        ));
    }
    if pairs.len() > 100 {
        return Err(ContextPackStoreError::Validation(
            "general Context source exceeds 100 entries".into(),
        ));
    }
    Ok(pairs)
}

fn validate_general_pair(key: &str, value: &str) -> Result<(), ContextPackStoreError> {
    if key.trim().is_empty() || value.trim().is_empty() {
        return Err(ContextPackStoreError::Validation(
            "general Context keys and values cannot be empty".into(),
        ));
    }
    if key.chars().count() > 64 || value.chars().count() > 512 {
        return Err(ContextPackStoreError::Validation(
            "general Context key/value exceeds the 64/512 scalar limit".into(),
        ));
    }
    Ok(())
}

fn parse_translation_csv(text: &str) -> Result<ParsedTranslationCsv, ContextPackStoreError> {
    let records = parse_csv_records(text)?;
    let Some(header) = records.first() else {
        return Err(ContextPackStoreError::Validation(
            "translation CSV requires a header".into(),
        ));
    };
    if header.len() != 2 {
        return Err(ContextPackStoreError::Validation(
            "translation CSV must have exactly two language-code headers".into(),
        ));
    }
    let language_a = header[0].trim_start_matches('\u{feff}').trim().to_string();
    let language_b = header[1].trim().to_string();
    validate_language_code(&language_a)?;
    validate_language_code(&language_b)?;
    if language_a.eq_ignore_ascii_case(&language_b) {
        return Err(ContextPackStoreError::Validation(
            "translation CSV headers must name two different languages".into(),
        ));
    }
    let mut rows = Vec::new();
    for (index, record) in records.into_iter().skip(1).enumerate() {
        if record.iter().all(|cell| cell.trim().is_empty()) {
            continue;
        }
        if record.len() != 2 {
            return Err(ContextPackStoreError::Validation(format!(
                "translation CSV row {} must contain exactly two cells",
                index + 2
            )));
        }
        let left = record[0].trim().to_string();
        let right = record[1].trim().to_string();
        if left.is_empty() || right.is_empty() {
            return Err(ContextPackStoreError::Validation(format!(
                "translation CSV row {} contains an empty cell",
                index + 2
            )));
        }
        if left.chars().count() > CONTEXT_CSV_MAX_CELL_SCALARS
            || right.chars().count() > CONTEXT_CSV_MAX_CELL_SCALARS
        {
            return Err(ContextPackStoreError::Validation(format!(
                "translation CSV row {} exceeds {CONTEXT_CSV_MAX_CELL_SCALARS} scalars per cell",
                index + 2
            )));
        }
        rows.push((left, right));
        if rows.len() > CONTEXT_CSV_MAX_ROWS {
            return Err(ContextPackStoreError::Validation(format!(
                "translation CSV exceeds {CONTEXT_CSV_MAX_ROWS} rows"
            )));
        }
    }
    if rows.is_empty() {
        return Err(ContextPackStoreError::Validation(
            "translation CSV contains no term rows".into(),
        ));
    }
    Ok(ParsedTranslationCsv {
        language_a,
        language_b,
        rows,
    })
}

/// Minimal RFC 4180 reader supporting quoted commas, escaped quotes, and
/// embedded newlines without adding another parser to the runtime dependency
/// graph.
fn parse_csv_records(text: &str) -> Result<Vec<Vec<String>>, ContextPackStoreError> {
    let chars = text.chars().collect::<Vec<_>>();
    let mut records = Vec::new();
    let mut record = Vec::new();
    let mut field = String::new();
    let mut in_quotes = false;
    let mut quoted = false;
    let mut index = 0;
    while index < chars.len() {
        let current = chars[index];
        if in_quotes {
            if current == '"' {
                if chars.get(index + 1) == Some(&'"') {
                    field.push('"');
                    index += 2;
                    continue;
                }
                in_quotes = false;
            } else {
                field.push(current);
            }
            index += 1;
            continue;
        }
        match current {
            '"' if field.is_empty() && !quoted => {
                in_quotes = true;
                quoted = true;
            }
            '"' => {
                return Err(ContextPackStoreError::Validation(
                    "translation CSV contains a quote inside an unquoted field".into(),
                ));
            }
            ',' => {
                record.push(std::mem::take(&mut field));
                quoted = false;
            }
            '\n' => {
                record.push(std::mem::take(&mut field));
                records.push(std::mem::take(&mut record));
                quoted = false;
            }
            '\r' => {
                if chars.get(index + 1) == Some(&'\n') {
                    index += 1;
                }
                record.push(std::mem::take(&mut field));
                records.push(std::mem::take(&mut record));
                quoted = false;
            }
            other => field.push(other),
        }
        index += 1;
    }
    if in_quotes {
        return Err(ContextPackStoreError::Validation(
            "translation CSV contains an unterminated quoted field".into(),
        ));
    }
    if !field.is_empty()
        || !record.is_empty()
        || (!text.is_empty() && !text.ends_with(['\n', '\r']))
    {
        record.push(field);
        records.push(record);
    }
    Ok(records)
}

fn validate_language_code(value: &str) -> Result<(), ContextPackStoreError> {
    if value.is_empty() || value.len() > 32 || !value.is_ascii() {
        return Err(ContextPackStoreError::Validation(format!(
            "invalid language-code header '{value}'"
        )));
    }
    let mut parts = value.split('-');
    let primary = parts.next().unwrap_or_default();
    if !(2..=3).contains(&primary.len()) || !primary.bytes().all(|byte| byte.is_ascii_alphabetic())
    {
        return Err(ContextPackStoreError::Validation(format!(
            "invalid language-code header '{value}'"
        )));
    }
    if parts.any(|part| {
        !(2..=8).contains(&part.len()) || !part.bytes().all(|byte| byte.is_ascii_alphanumeric())
    }) {
        return Err(ContextPackStoreError::Validation(format!(
            "invalid language-code header '{value}'"
        )));
    }
    Ok(())
}

fn serialized_scalar_count(context: &SonioxContext) -> Result<usize, ContextPackStoreError> {
    Ok(serde_json::to_string(context)?.chars().count())
}

fn largest_text_prefix_that_fits(
    context: &mut SonioxContext,
    separator: &str,
    candidate: &str,
    max_scalars: usize,
) -> Result<usize, ContextPackStoreError> {
    let before = context.text.clone();
    let total = candidate.chars().count();
    let mut low = 0;
    let mut high = total;
    while low < high {
        let middle = (low + high).div_ceil(2);
        context.text = format!("{before}{separator}{}", prefix_chars(candidate, middle));
        if serialized_scalar_count(context)? <= max_scalars {
            low = middle;
        } else {
            high = middle - 1;
        }
    }
    if low == 0 {
        context.text = before;
    } else {
        context.text = format!("{before}{separator}{}", prefix_chars(candidate, low));
    }
    Ok(low)
}

fn record_included(
    sources: &mut [ContextReceiptSource],
    origin: &CandidateOrigin,
    items: usize,
    scalars: usize,
) {
    if let Some(source) = sources
        .iter_mut()
        .find(|value| value.pack_id == origin.pack_id && value.source_id == origin.source_id)
    {
        source.included_items = source.included_items.saturating_add(items as u64);
        source.included_scalars = source.included_scalars.saturating_add(scalars as u64);
    }
}

fn record_omission(
    omissions: &mut Vec<ContextOmission>,
    origin: &CandidateOrigin,
    section: ContextContentKind,
    reason: ContextOmissionReason,
    items: usize,
    scalars: usize,
) {
    if let Some(existing) = omissions.iter_mut().find(|value| {
        value.pack_id == origin.pack_id
            && value.source_id == origin.source_id
            && value.section == section
            && value.reason == reason
    }) {
        existing.omitted_items = existing.omitted_items.saturating_add(items as u64);
        existing.omitted_scalars = existing.omitted_scalars.saturating_add(scalars as u64);
        return;
    }
    omissions.push(ContextOmission {
        pack_id: origin.pack_id.clone(),
        source_id: origin.source_id.clone(),
        section,
        reason,
        omitted_items: items as u64,
        omitted_scalars: scalars as u64,
    });
}

fn validate_compilation(compilation: &ContextCompilation) -> Result<(), ContextPackStoreError> {
    let serialized = serde_json::to_string(&compilation.context)?;
    if serialized != compilation.context_json {
        return Err(ContextPackStoreError::Validation(
            "Context compilation JSON does not match its structured value".into(),
        ));
    }
    if serialized.chars().count() > SONIOX_CONTEXT_MAX_SCALARS {
        return Err(ContextPackStoreError::Validation(
            "Context compilation exceeds 8,000 Unicode scalars".into(),
        ));
    }
    if sha256_hex(serialized.as_bytes()) != compilation.receipt.context_sha256
        || compilation.receipt.serialized_scalars != serialized.chars().count() as u64
    {
        return Err(ContextPackStoreError::Validation(
            "Context compilation does not match its receipt".into(),
        ));
    }
    Ok(())
}

fn sha256_hex(data: &[u8]) -> String {
    format!("{:x}", Sha256::digest(data))
}

fn normalize_title<'a>(value: &'a str, fallback: &'a str) -> &'a str {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        fallback
    } else {
        trimmed
    }
}

fn prefix_chars(value: &str, count: usize) -> String {
    value.chars().take(count).collect()
}

fn require_nonempty(field: &str, value: &str) -> Result<(), ContextPackStoreError> {
    if value.trim().is_empty() {
        return Err(ContextPackStoreError::Validation(format!(
            "{field} cannot be empty"
        )));
    }
    Ok(())
}

fn usize_to_i64(value: usize, field: &str) -> Result<i64, ContextPackStoreError> {
    i64::try_from(value).map_err(|_| {
        ContextPackStoreError::Validation(format!("{field} exceeds SQLite integer range"))
    })
}

fn usize_to_u64(value: usize, field: &str) -> Result<u64, ContextPackStoreError> {
    u64::try_from(value)
        .map_err(|_| ContextPackStoreError::Validation(format!("{field} exceeds u64 range")))
}

fn u64_to_i64(value: u64, field: &str) -> Result<i64, ContextPackStoreError> {
    i64::try_from(value).map_err(|_| {
        ContextPackStoreError::Validation(format!("{field} exceeds SQLite integer range"))
    })
}

fn i64_to_u64(value: i64, field: &str) -> Result<u64, ContextPackStoreError> {
    u64::try_from(value)
        .map_err(|_| ContextPackStoreError::CorruptData(format!("{field} is negative in SQLite")))
}

fn to_sql_conversion_error(error: ContextPackStoreError) -> rusqlite::Error {
    rusqlite::Error::FromSqlConversionFailure(0, rusqlite::types::Type::Text, Box::new(error))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::sync::atomic::{AtomicBool, Ordering};
    use tempfile::TempDir;
    use vt_crypto::{CryptoError, MemoryKeyStore};

    struct FailingDeleteKeyStore {
        inner: MemoryKeyStore,
        fail_delete: AtomicBool,
    }

    impl FailingDeleteKeyStore {
        fn new() -> Self {
            Self {
                inner: MemoryKeyStore::new(),
                fail_delete: AtomicBool::new(true),
            }
        }
    }

    impl KeyProvider for FailingDeleteKeyStore {
        fn create_session_key(&self, session_id: &uuid::Uuid) -> Result<String, CryptoError> {
            self.inner.create_session_key(session_id)
        }

        fn load_key(&self, key_ref: &str) -> Result<SessionKey, CryptoError> {
            self.inner.load_key(key_ref)
        }

        fn delete_key(&self, key_ref: &str) -> Result<(), CryptoError> {
            if self.fail_delete.load(Ordering::SeqCst) {
                return Err(CryptoError::SecretStoreAccess {
                    message: "injected delete failure".to_string(),
                });
            }
            self.inner.delete_key(key_ref)
        }

        fn key_exists(&self, key_ref: &str) -> bool {
            self.inner.key_exists(key_ref)
        }

        fn store_key(&self, key_ref: &str, key: &SessionKey) -> Result<(), CryptoError> {
            self.inner.store_raw(key_ref, key.as_bytes())
        }
    }

    struct Fixture {
        _temp: TempDir,
        db: std::path::PathBuf,
        keys: Arc<MemoryKeyStore>,
        store: ContextPackStore,
        notebook_a: String,
        notebook_b: String,
    }

    fn fixture() -> Fixture {
        let temp = tempfile::tempdir().unwrap();
        let db = temp.path().join("context.db");
        let notebooks = crate::NotebookStore::new(&db).unwrap();
        let notebook_a = notebooks.create_notebook(Some("A")).unwrap().id;
        let notebook_b = notebooks.create_notebook(Some("B")).unwrap().id;
        let keys = Arc::new(MemoryKeyStore::new());
        let store = ContextPackStore::new(&db, keys.clone()).unwrap();
        Fixture {
            _temp: temp,
            db,
            keys,
            store,
            notebook_a,
            notebook_b,
        }
    }

    #[test]
    fn library_delete_keeps_pack_retryable_when_key_destruction_fails() {
        let temp = tempfile::tempdir().unwrap();
        let db = temp.path().join("context.db");
        let keys = Arc::new(FailingDeleteKeyStore::new());
        let store = ContextPackStore::new(&db, keys.clone()).unwrap();
        let pack = store.create_library_pack("Retryable delete").unwrap();

        assert!(matches!(
            store.delete_library_pack(&pack.id, pack.revision),
            Err(ContextPackStoreError::Crypto(
                CryptoError::SecretStoreAccess { .. }
            ))
        ));
        let still_active = store.get_pack(&pack.id).unwrap().unwrap();
        assert_eq!(still_active.deleted_at, None);
        assert_eq!(still_active.revision, pack.revision);
        assert!(keys.key_exists(&pack.key_ref));

        keys.fail_delete.store(false, Ordering::SeqCst);
        assert!(store.delete_library_pack(&pack.id, pack.revision).unwrap());
        assert!(store
            .get_pack(&pack.id)
            .unwrap()
            .unwrap()
            .deleted_at
            .is_some());
        assert!(!keys.key_exists(&pack.key_ref));
    }

    #[test]
    fn library_delete_treats_an_already_missing_key_as_idempotent() {
        let fixture = fixture();
        let pack = fixture.store.create_library_pack("Missing key").unwrap();
        fixture.keys.delete_key(&pack.key_ref).unwrap();

        assert!(fixture
            .store
            .delete_library_pack(&pack.id, pack.revision)
            .unwrap());
        assert!(fixture
            .store
            .get_pack(&pack.id)
            .unwrap()
            .unwrap()
            .deleted_at
            .is_some());
    }

    fn text_source(title: &str, kind: ContextContentKind, content: &str) -> NewContextSource {
        NewContextSource {
            title: title.into(),
            format: ContextSourceFormat::Text,
            content_kind: kind,
            content: content.as_bytes().to_vec(),
            metadata: json!({}),
        }
    }

    #[test]
    fn new_sources_are_encrypted_and_schema_has_no_plaintext_column() {
        let fixture = fixture();
        let pack = fixture
            .store
            .get_private_pack(&fixture.notebook_a)
            .unwrap()
            .unwrap();
        let source = fixture
            .store
            .import_source(
                &pack.id,
                &NewContextSource::pasted_text("Private", "ultra secret phrase"),
            )
            .unwrap();
        let conn = fixture.store.conn.lock().unwrap();
        let columns = conn
            .prepare("PRAGMA table_info(context_pack_sources)")
            .unwrap()
            .query_map([], |row| row.get::<_, String>(1))
            .unwrap()
            .collect::<Result<Vec<_>, _>>()
            .unwrap();
        assert!(!columns.iter().any(|column| column == "content_snapshot"));
        let ciphertext: Vec<u8> = conn
            .query_row(
                "SELECT ciphertext FROM context_pack_sources WHERE id = ?1",
                [&source.id],
                |row| row.get(0),
            )
            .unwrap();
        assert_ne!(ciphertext, b"ultra secret phrase");
        assert!(!String::from_utf8_lossy(&ciphertext).contains("ultra secret phrase"));
        drop(conn);

        let compiled = fixture
            .store
            .compile_notebook_context(&fixture.notebook_a)
            .unwrap();
        assert_eq!(compiled.context.text, "ultra secret phrase");
        assert_eq!(compiled.receipt.sources[0].included_items, 1);
    }

    #[test]
    fn notebook_private_packs_never_cross_and_cannot_be_bound() {
        let fixture = fixture();
        let pack_a = fixture
            .store
            .get_private_pack(&fixture.notebook_a)
            .unwrap()
            .unwrap();
        let pack_b = fixture
            .store
            .get_private_pack(&fixture.notebook_b)
            .unwrap()
            .unwrap();
        fixture
            .store
            .import_source(&pack_a.id, &NewContextSource::pasted_text("A", "only-a"))
            .unwrap();
        fixture
            .store
            .import_source(&pack_b.id, &NewContextSource::pasted_text("B", "only-b"))
            .unwrap();

        assert!(matches!(
            fixture
                .store
                .bind_library_pack(&fixture.notebook_b, &pack_a.id, 0),
            Err(ContextPackStoreError::Ownership(_))
        ));
        let a = fixture
            .store
            .compile_notebook_context(&fixture.notebook_a)
            .unwrap();
        let b = fixture
            .store
            .compile_notebook_context(&fixture.notebook_b)
            .unwrap();
        assert!(a.context.text.contains("only-a"));
        assert!(!a.context.text.contains("only-b"));
        assert!(b.context.text.contains("only-b"));
        assert!(!b.context.text.contains("only-a"));
    }

    #[test]
    fn library_binding_is_explicit_and_ordered() {
        let fixture = fixture();
        let first = fixture.store.create_library_pack("First").unwrap();
        let second = fixture.store.create_library_pack("Second").unwrap();
        fixture
            .store
            .import_source(
                &first.id,
                &NewContextSource::pasted_text("one", "library-one"),
            )
            .unwrap();
        fixture
            .store
            .import_source(
                &second.id,
                &NewContextSource::pasted_text("two", "library-two"),
            )
            .unwrap();
        fixture
            .store
            .bind_library_pack(&fixture.notebook_a, &second.id, 1)
            .unwrap();
        fixture
            .store
            .bind_library_pack(&fixture.notebook_a, &first.id, 0)
            .unwrap();
        let compiled = fixture
            .store
            .compile_notebook_context(&fixture.notebook_a)
            .unwrap();
        assert_eq!(compiled.context.text, "library-one\n\nlibrary-two");
        assert_eq!(
            fixture
                .store
                .compile_notebook_context(&fixture.notebook_b)
                .unwrap()
                .context
                .text,
            ""
        );
    }

    #[test]
    fn bilingual_csv_generates_both_translation_directions() {
        let fixture = fixture();
        let pack = fixture
            .store
            .get_private_pack(&fixture.notebook_a)
            .unwrap()
            .unwrap();
        let source = fixture
            .store
            .import_source(
                &pack.id,
                &NewContextSource {
                    title: "Terms".into(),
                    format: ContextSourceFormat::TranslationCsv,
                    content_kind: ContextContentKind::TranslationTerms,
                    content: b"en,zh\n\"Voice, Tool\",\"\xe5\xa3\xb0\xe9\x9f\xb3\xe5\xb7\xa5\xe5\x85\xb7\"\nMVP,\xe6\x9c\x80\xe5\xb0\x8f\xe5\x8f\xaf\xe8\xa1\x8c\xe4\xba\xa7\xe5\x93\x81\n".to_vec(),
                    metadata: json!({}),
                },
            )
            .unwrap();
        let metadata: Value = serde_json::from_str(&source.metadata_json).unwrap();
        assert_eq!(metadata["language_a"], "en");
        assert_eq!(metadata["language_b"], "zh");
        assert_eq!(metadata["row_count"], 2);

        let context = fixture
            .store
            .compile_notebook_context(&fixture.notebook_a)
            .unwrap()
            .context;
        assert!(context.translation_terms.contains(&SonioxTranslationTerm {
            source: "Voice, Tool".into(),
            target: "声音工具".into(),
        }));
        assert!(context.translation_terms.contains(&SonioxTranslationTerm {
            source: "声音工具".into(),
            target: "Voice, Tool".into(),
        }));
    }

    #[test]
    fn csv_and_utf8_limits_are_enforced() {
        let fixture = fixture();
        let pack = fixture
            .store
            .get_private_pack(&fixture.notebook_a)
            .unwrap()
            .unwrap();
        let invalid_header = NewContextSource {
            title: "Bad".into(),
            format: ContextSourceFormat::TranslationCsv,
            content_kind: ContextContentKind::TranslationTerms,
            content: b"English,Chinese\na,b\n".to_vec(),
            metadata: json!({}),
        };
        assert!(matches!(
            fixture.store.import_source(&pack.id, &invalid_header),
            Err(ContextPackStoreError::Validation(_))
        ));
        let oversized_cell = format!("en,zh\n{},x\n", "a".repeat(257));
        let oversized = NewContextSource {
            content: oversized_cell.into_bytes(),
            ..invalid_header.clone()
        };
        assert!(matches!(
            fixture.store.import_source(&pack.id, &oversized),
            Err(ContextPackStoreError::Validation(_))
        ));
        let invalid_utf8 = NewContextSource {
            title: "Bad UTF-8".into(),
            format: ContextSourceFormat::Text,
            content_kind: ContextContentKind::Text,
            content: vec![0xff, 0xfe],
            metadata: json!({}),
        };
        assert!(matches!(
            fixture.store.import_source(&pack.id, &invalid_utf8),
            Err(ContextPackStoreError::Validation(_))
        ));
        let too_large =
            NewContextSource::pasted_text("Large", "x".repeat(CONTEXT_TEXT_MAX_BYTES + 1));
        assert!(matches!(
            fixture.store.import_source(&pack.id, &too_large),
            Err(ContextPackStoreError::Validation(_))
        ));
    }

    #[test]
    fn compiler_fails_closed_for_missing_key_untrusted_and_deleted_binding() {
        let fixture = fixture();
        let private = fixture
            .store
            .get_private_pack(&fixture.notebook_a)
            .unwrap()
            .unwrap();
        let source = fixture
            .store
            .import_source(&private.id, &NewContextSource::pasted_text("A", "safe"))
            .unwrap();
        fixture
            .store
            .conn
            .lock()
            .unwrap()
            .execute(
                "UPDATE context_pack_sources SET trust_state = 'untrusted' WHERE id = ?1",
                [&source.id],
            )
            .unwrap();
        assert!(matches!(
            fixture.store.compile_notebook_context(&fixture.notebook_a),
            Err(ContextPackStoreError::Trust(_))
        ));
        fixture
            .store
            .conn
            .lock()
            .unwrap()
            .execute(
                "UPDATE context_pack_sources SET trust_state = 'local_trusted' WHERE id = ?1",
                [&source.id],
            )
            .unwrap();
        fixture.keys.delete_key(&private.key_ref).unwrap();
        assert!(matches!(
            fixture.store.compile_notebook_context(&fixture.notebook_a),
            Err(ContextPackStoreError::MissingKey(_))
        ));

        let library = fixture.store.create_library_pack("Delete").unwrap();
        fixture
            .store
            .bind_library_pack(&fixture.notebook_b, &library.id, 0)
            .unwrap();
        fixture
            .store
            .delete_library_pack(&library.id, library.revision)
            .unwrap();
        assert!(matches!(
            fixture.store.compile_notebook_context(&fixture.notebook_b),
            Err(ContextPackStoreError::Trust(_))
        ));
    }

    #[test]
    fn compiler_priority_dedup_and_truncation_are_deterministic() {
        let fixture = fixture();
        let private = fixture
            .store
            .get_private_pack(&fixture.notebook_a)
            .unwrap()
            .unwrap();
        fixture
            .store
            .import_source(
                &private.id,
                &NewContextSource {
                    title: "CSV".into(),
                    format: ContextSourceFormat::TranslationCsv,
                    content_kind: ContextContentKind::TranslationTerms,
                    content: b"en,zh\nZulangue,\xe5\xa3\xb0\xe9\x9f\xb3\xe5\xb7\xa5\xe5\x85\xb7\n"
                        .to_vec(),
                    metadata: json!({}),
                },
            )
            .unwrap();
        fixture
            .store
            .import_source(
                &private.id,
                &text_source(
                    "Terms",
                    ContextContentKind::Terms,
                    "Zulangue\nZulangue\nMVP",
                ),
            )
            .unwrap();
        fixture
            .store
            .import_source(
                &private.id,
                &text_source(
                    "General",
                    ContextContentKind::General,
                    "domain=Voice tooling",
                ),
            )
            .unwrap();
        fixture
            .store
            .import_source(
                &private.id,
                &NewContextSource::pasted_text("Long", "背景".repeat(1_000)),
            )
            .unwrap();

        let first = fixture
            .store
            .compile_notebook_context_with_limit(&fixture.notebook_a, 420)
            .unwrap();
        let second = fixture
            .store
            .compile_notebook_context_with_limit(&fixture.notebook_a, 420)
            .unwrap();
        assert_eq!(first, second);
        assert!(first.context_json.chars().count() <= 420);
        assert_eq!(first.context.translation_terms.len(), 2);
        assert_eq!(first.context.terms, vec!["Zulangue", "MVP"]);
        assert_eq!(first.context.general.len(), 1);
        assert!(first.receipt.omissions.iter().any(|value| {
            value.reason == ContextOmissionReason::Duplicate
                && value.section == ContextContentKind::Terms
        }));
        assert!(first.receipt.omissions.iter().any(|value| {
            value.reason == ContextOmissionReason::Truncated
                && value.section == ContextContentKind::Text
        }));
        let text_receipt = first
            .receipt
            .sources
            .iter()
            .find(|source| source.source_title == "Long")
            .unwrap();
        assert_eq!(text_receipt.included_items, 1);
        assert!(text_receipt.included_scalars > 0);
    }

    #[test]
    fn run_snapshot_is_immutable_and_applied_requires_matching_digest() {
        let fixture = fixture();
        let capture = crate::NotebookCaptureStore::new(&fixture.db).unwrap();
        capture.get_or_create_profile(&fixture.notebook_a).unwrap();
        let profile = capture
            .update_profile(
                &fixture.notebook_a,
                0,
                &crate::NotebookCaptureProfileUpdate {
                    remote_realtime_enabled: true,
                    capture_mode: crate::CaptureMode::TwoWay,
                    language_a: "en".into(),
                    language_b: "zh".into(),
                    left_language: "en".into(),
                    right_language: "zh".into(),
                    selected_languages: vec!["en".into(), "zh".into()],
                    common_caption_language: None,
                    privacy_level: "standard".into(),
                    send_context_to_soniox: true,
                },
            )
            .unwrap();
        capture
            .create_run(
                &crate::NewNotebookCaptureRun {
                    id: "run-context".into(),
                    notebook_id: fixture.notebook_a.clone(),
                    session_id: "session-context".into(),
                    remote_health: crate::RemoteHealth::Connecting,
                    audio_journal_path: "/tmp/context.journal".into(),
                    audio_key_ref: "audio-key".into(),
                    sample_rate: 16_000,
                    channels: 1,
                },
                &profile,
            )
            .unwrap();
        capture
            .claim_provider_provenance(
                "session-context",
                crate::notebook_capture_store::CaptureProviderRole::Realtime,
                crate::notebook_capture_store::SONIOX_PROVIDER_ID,
                crate::notebook_capture_store::SONIOX_STT_RT_V5_MODEL_ID,
            )
            .unwrap();
        let private = fixture
            .store
            .get_private_pack(&fixture.notebook_a)
            .unwrap()
            .unwrap();
        let source = fixture
            .store
            .import_source(
                &private.id,
                &NewContextSource::pasted_text("Text", "before"),
            )
            .unwrap();
        let before = fixture
            .store
            .compile_notebook_context(&fixture.notebook_a)
            .unwrap();
        fixture
            .store
            .persist_run_snapshot("run-context", &before)
            .unwrap();
        assert!(capture
            .get_run("run-context")
            .unwrap()
            .unwrap()
            .context_applied_at
            .is_none());
        assert!(matches!(
            fixture
                .store
                .mark_context_applied("run-context", "wrong-digest"),
            Err(ContextPackStoreError::Conflict(_))
        ));
        assert!(matches!(
            fixture
                .store
                .mark_context_applied("run-context", &before.receipt.context_sha256),
            Err(ContextPackStoreError::Conflict(_))
        ));
        capture
            .update_remote_health("run-context", crate::RemoteHealth::Live, None)
            .unwrap();
        fixture
            .store
            .mark_context_applied("run-context", &before.receipt.context_sha256)
            .unwrap();
        assert!(capture
            .get_run("run-context")
            .unwrap()
            .unwrap()
            .context_applied_at
            .is_some());

        fixture
            .store
            .replace_source(
                &source.id,
                source.revision,
                &NewContextSource::pasted_text("Text", "after"),
            )
            .unwrap();
        let after = fixture
            .store
            .compile_notebook_context(&fixture.notebook_a)
            .unwrap();
        assert_ne!(before.context_json, after.context_json);
        assert_eq!(
            fixture
                .store
                .load_run_snapshot("run-context")
                .unwrap()
                .unwrap(),
            before
        );
        assert!(matches!(
            fixture.store.persist_run_snapshot("run-context", &after),
            Err(ContextPackStoreError::Conflict(_))
        ));
    }

    #[test]
    fn saving_private_pack_copy_creates_new_ids_and_key() {
        let fixture = fixture();
        let private = fixture
            .store
            .get_private_pack(&fixture.notebook_a)
            .unwrap()
            .unwrap();
        let original_source = fixture
            .store
            .import_source(
                &private.id,
                &NewContextSource::pasted_text("Text", "copy me"),
            )
            .unwrap();
        let copy = fixture
            .store
            .copy_pack_to_library(&private.id, "Reusable")
            .unwrap();
        let copied_sources = fixture.store.list_sources(&copy.id).unwrap();
        assert_eq!(copy.scope, ContextPackScope::Library);
        assert_ne!(copy.id, private.id);
        assert_ne!(copy.key_ref, private.key_ref);
        assert_ne!(copied_sources[0].id, original_source.id);
        assert_eq!(
            copied_sources[0].plaintext_sha256,
            original_source.plaintext_sha256
        );
    }

    #[test]
    fn parser_supports_quoted_commas_quotes_and_newlines() {
        let parsed = parse_translation_csv(
            "en,zh\n\"Voice, Tool\",\"声音工具\"\n\"say \"\"hi\"\"\",\"说\n你好\"\n",
        )
        .unwrap();
        assert_eq!(parsed.language_a, "en");
        assert_eq!(parsed.rows[0], ("Voice, Tool".into(), "声音工具".into()));
        assert_eq!(parsed.rows[1], ("say \"hi\"".into(), "说\n你好".into()));
    }

    fn seeded_library_pack(fixture: &Fixture) -> ContextPackRecord {
        let pack = fixture.store.create_library_pack("Field Camp").unwrap();
        fixture
            .store
            .import_source(
                &pack.id,
                &NewContextSource {
                    title: "Background".into(),
                    format: ContextSourceFormat::Text,
                    content_kind: ContextContentKind::General,
                    content: b"domain=Social anthropology\ntopic=Zomia".to_vec(),
                    metadata: json!({}),
                },
            )
            .unwrap();
        fixture
            .store
            .import_source(
                &pack.id,
                &NewContextSource {
                    title: "Speakers".into(),
                    format: ContextSourceFormat::Text,
                    content_kind: ContextContentKind::Terms,
                    content: "阿嘎佐诗\n和文臻\nZuzalu".as_bytes().to_vec(),
                    metadata: json!({}),
                },
            )
            .unwrap();
        fixture.store.require_active_pack(&pack.id).unwrap()
    }

    #[test]
    fn pack_document_round_trip_preserves_every_source() {
        let fixture = fixture();
        let original = seeded_library_pack(&fixture);
        let document = fixture.store.export_pack_document(&original.id).unwrap();
        assert_eq!(document.schema, CONTEXT_PACK_DOCUMENT_SCHEMA);
        assert_eq!(document.title, "Field Camp");
        assert_eq!(document.sources.len(), 2);

        let imported = fixture.store.import_pack_document(&document, None).unwrap();
        assert_ne!(imported.id, original.id, "import must mint a fresh Pack ID");
        assert_ne!(
            imported.key_ref, original.key_ref,
            "import must mint a fresh Pack key"
        );
        assert_eq!(imported.title, "Field Camp");

        let before = fixture.store.list_sources(&original.id).unwrap();
        let after = fixture.store.list_sources(&imported.id).unwrap();
        assert_eq!(before.len(), after.len());
        for (before, after) in before.iter().zip(after.iter()) {
            assert_eq!(before.title, after.title);
            assert_eq!(before.content_kind, after.content_kind);
            assert_eq!(before.format, after.format);
            assert_eq!(before.plaintext_sha256, after.plaintext_sha256);
            assert_ne!(before.id, after.id);
        }
    }

    #[test]
    fn pack_document_import_honors_a_title_override() {
        let fixture = fixture();
        let pack = seeded_library_pack(&fixture);
        let document = fixture.store.export_pack_document(&pack.id).unwrap();
        let imported = fixture
            .store
            .import_pack_document(&document, Some("人类学论坛"))
            .unwrap();
        assert_eq!(imported.title, "人类学论坛");
    }

    #[test]
    fn pack_document_import_rejects_an_unknown_schema() {
        let fixture = fixture();
        let pack = seeded_library_pack(&fixture);
        let mut document = fixture.store.export_pack_document(&pack.id).unwrap();
        document.schema = "zulangue.context-pack.v99".into();
        let error = fixture
            .store
            .import_pack_document(&document, None)
            .unwrap_err();
        assert!(matches!(error, ContextPackStoreError::Validation(_)));
        assert_eq!(fixture.store.list_library_packs().unwrap().len(), 1);
    }

    #[test]
    fn pack_document_import_rejects_tampered_content_and_leaves_nothing_behind() {
        let fixture = fixture();
        let pack = seeded_library_pack(&fixture);
        let mut document = fixture.store.export_pack_document(&pack.id).unwrap();
        document.sources[1].content.push_str("\n混入的内容");

        let error = fixture
            .store
            .import_pack_document(&document, None)
            .unwrap_err();
        assert!(matches!(error, ContextPackStoreError::CorruptData(_)));
        assert_eq!(
            fixture.store.list_library_packs().unwrap().len(),
            1,
            "a rejected import must not leave a half-built Pack behind"
        );
    }

    #[test]
    fn pack_document_export_rejects_an_empty_pack() {
        let fixture = fixture();
        let pack = fixture.store.create_library_pack("Empty").unwrap();
        let error = fixture.store.export_pack_document(&pack.id).unwrap_err();
        assert!(matches!(error, ContextPackStoreError::Validation(_)));
    }

    #[test]
    fn exported_pack_document_survives_json_serialization() {
        let fixture = fixture();
        let pack = seeded_library_pack(&fixture);
        let document = fixture.store.export_pack_document(&pack.id).unwrap();
        let json = serde_json::to_string_pretty(&document).unwrap();
        assert!(json.contains("阿嘎佐诗"), "export must stay human-readable");
        let parsed: ContextPackDocument = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed, document);
        let imported = fixture.store.import_pack_document(&parsed, None).unwrap();
        assert_eq!(fixture.store.list_sources(&imported.id).unwrap().len(), 2);
    }
}
