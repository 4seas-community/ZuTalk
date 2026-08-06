//! Zulangue SQLite v31 schema.
//!
//! Fresh databases are installed directly at v31. The eight immediately
//! preceding Notebook schemas (v23 through v30) are migrated in place so
//! existing capture data remains available; older retired product schemas are
//! still rejected.
//!
//! Every constant below is named for what its version introduced, not for
//! where it sits in the chain — positional names go stale on the next bump.
//! `OLDEST_SUPPORTED_VERSION` is the floor rather than a feature, and
//! `CURRENT_VERSION` is correct by definition.

use rusqlite::{Connection, OptionalExtension, Result as SqlResult};

const OLDEST_SUPPORTED_VERSION: i32 = 23;
const SPEAKER_VERSION: i32 = 24;
const SELECTED_LANGUAGES_VERSION: i32 = 25;
const MULTILINGUAL_VERSION: i32 = 26;
const REALTIME_LORO_VERSION: i32 = 27;
const TRANSLATION_INBOX_VERSION: i32 = 28;
const TRANSCRIPT_GAPS_VERSION: i32 = 29;
const REMOTE_ARTIFACTS_VERSION: i32 = 30;
const CURRENT_VERSION: i32 = 31;

const V23_TABLES: &[&str] = &[
    "audio_retention_chunks",
    "context_pack_sources",
    "context_packs",
    "notebook_capture_profiles",
    "notebook_capture_runs",
    "notebook_context_pack_bindings",
    "notebook_projection_mutations",
    "notebook_session_projections",
    "notebook_sessions",
    "notebook_tabs",
    "notebooks",
    "realtime_utterances",
    "search_index",
    "search_index_config",
    "search_index_content",
    "search_index_data",
    "search_index_docsize",
    "search_index_idx",
    "session_meta",
    "session_purge_jobs",
    "session_records",
];

const V23_INDEXES: &[&str] = &[
    "idx_audio_retention_chunks_due",
    "idx_audio_retention_chunks_session",
    "idx_context_pack_sources_pack_order",
    "idx_context_packs_library",
    "idx_context_packs_private_owner",
    "idx_notebook_capture_runs_notebook_created",
    "idx_notebook_capture_runs_single_active",
    "idx_notebook_context_bindings_order",
    "idx_notebook_projection_mutations_session",
    "idx_notebook_session_projections_notebook_session",
    "idx_notebook_session_projections_tab",
    "idx_notebook_sessions_session_unique",
    "idx_notebook_tabs_builtin_unique",
    "idx_notebook_tabs_notebook_position",
    "idx_notebooks_updated",
    "idx_realtime_utterances_session_sequence",
    "idx_session_purge_jobs_updated",
    "idx_session_records_active_created",
];

const V23_TRIGGERS: &[&str] = &[
    "context_binding_library_only_insert",
    "context_binding_library_only_update",
    "notebook_capture_runs_async_authorization_immutable",
    "notebook_capture_runs_async_identity_immutable",
    "notebook_capture_runs_async_projection_transition",
    "notebook_capture_runs_async_receipt_insert",
    "notebook_capture_runs_async_receipt_update",
    "notebook_capture_runs_async_state_transition",
    "notebook_capture_runs_post_stop_provenance_immutable",
    "notebook_capture_runs_provider_receipt_immutable",
    "notebook_capture_runs_realtime_provenance_immutable",
    "realtime_utterances_require_realtime_provenance",
    "session_meta_provider_tokens_immutable",
];

const V24_TABLES: &[&str] = &[
    "audio_retention_chunks",
    "context_pack_sources",
    "context_packs",
    "notebook_capture_profiles",
    "notebook_capture_runs",
    "notebook_context_pack_bindings",
    "notebook_projection_mutations",
    "notebook_session_projections",
    "notebook_sessions",
    "notebook_tabs",
    "notebooks",
    "participants",
    "realtime_utterances",
    "search_index",
    "search_index_config",
    "search_index_content",
    "search_index_data",
    "search_index_docsize",
    "search_index_idx",
    "session_meta",
    "session_purge_jobs",
    "session_records",
    "session_speakers",
];

const V24_INDEXES: &[&str] = &[
    "idx_audio_retention_chunks_due",
    "idx_audio_retention_chunks_session",
    "idx_context_pack_sources_pack_order",
    "idx_context_packs_library",
    "idx_context_packs_private_owner",
    "idx_notebook_capture_runs_notebook_created",
    "idx_notebook_capture_runs_single_active",
    "idx_notebook_context_bindings_order",
    "idx_notebook_projection_mutations_session",
    "idx_notebook_session_projections_notebook_session",
    "idx_notebook_session_projections_tab",
    "idx_notebook_sessions_session_unique",
    "idx_notebook_tabs_builtin_unique",
    "idx_notebook_tabs_notebook_position",
    "idx_notebooks_updated",
    "idx_participants_display_name",
    "idx_realtime_utterances_session_sequence",
    "idx_realtime_utterances_session_speaker",
    "idx_session_purge_jobs_updated",
    "idx_session_records_active_created",
    "idx_session_speakers_participant",
    "idx_session_speakers_session_epoch",
];

const V24_TRIGGERS: &[&str] = V23_TRIGGERS;
const V25_TABLES: &[&str] = V24_TABLES;
const V25_INDEXES: &[&str] = V24_INDEXES;
const V25_TRIGGERS: &[&str] = V24_TRIGGERS;
const V26_TABLES: &[&str] = &[
    "audio_retention_chunks",
    "context_pack_sources",
    "context_packs",
    "notebook_capture_profiles",
    "notebook_capture_runs",
    "notebook_context_pack_bindings",
    "notebook_projection_mutations",
    "notebook_session_projections",
    "notebook_sessions",
    "notebook_tabs",
    "notebooks",
    "participants",
    "realtime_utterance_variants",
    "realtime_utterances",
    "search_index",
    "search_index_config",
    "search_index_content",
    "search_index_data",
    "search_index_docsize",
    "search_index_idx",
    "session_meta",
    "session_purge_jobs",
    "session_records",
    "session_speakers",
];
const V26_INDEXES: &[&str] = &[
    "idx_audio_retention_chunks_due",
    "idx_audio_retention_chunks_session",
    "idx_context_pack_sources_pack_order",
    "idx_context_packs_library",
    "idx_context_packs_private_owner",
    "idx_notebook_capture_runs_notebook_created",
    "idx_notebook_capture_runs_single_active",
    "idx_notebook_context_bindings_order",
    "idx_notebook_projection_mutations_session",
    "idx_notebook_session_projections_notebook_session",
    "idx_notebook_session_projections_tab",
    "idx_notebook_sessions_session_unique",
    "idx_notebook_tabs_builtin_unique",
    "idx_notebook_tabs_notebook_position",
    "idx_notebooks_updated",
    "idx_participants_display_name",
    "idx_realtime_utterance_variants_language",
    "idx_realtime_utterance_variants_one_source",
    "idx_realtime_utterances_session_sequence",
    "idx_realtime_utterances_session_speaker",
    "idx_session_purge_jobs_updated",
    "idx_session_records_active_created",
    "idx_session_speakers_participant",
    "idx_session_speakers_session_epoch",
];
const V26_TRIGGERS: &[&str] = V25_TRIGGERS;
const V27_TABLES: &[&str] = &[
    "audio_retention_chunks",
    "context_pack_sources",
    "context_packs",
    "notebook_capture_profiles",
    "notebook_capture_runs",
    "notebook_context_pack_bindings",
    "notebook_projection_mutations",
    "notebook_session_projections",
    "notebook_sessions",
    "notebook_tabs",
    "notebooks",
    "participants",
    "realtime_utterance_overrides",
    "realtime_utterance_variants",
    "realtime_utterances",
    "search_index",
    "search_index_config",
    "search_index_content",
    "search_index_data",
    "search_index_docsize",
    "search_index_idx",
    "session_meta",
    "session_purge_jobs",
    "session_records",
    "session_speakers",
];
const V27_INDEXES: &[&str] = &[
    "idx_audio_retention_chunks_due",
    "idx_audio_retention_chunks_session",
    "idx_context_pack_sources_pack_order",
    "idx_context_packs_library",
    "idx_context_packs_private_owner",
    "idx_notebook_capture_runs_notebook_created",
    "idx_notebook_capture_runs_single_active",
    "idx_notebook_context_bindings_order",
    "idx_notebook_projection_mutations_session",
    "idx_notebook_projection_mutations_utterance_language",
    "idx_notebook_session_projections_notebook_session",
    "idx_notebook_session_projections_tab",
    "idx_notebook_sessions_session_unique",
    "idx_notebook_tabs_builtin_unique",
    "idx_notebook_tabs_notebook_position",
    "idx_notebooks_updated",
    "idx_participants_display_name",
    "idx_realtime_utterance_variants_language",
    "idx_realtime_utterance_variants_one_source",
    "idx_realtime_utterances_session_sequence",
    "idx_realtime_utterances_session_speaker",
    "idx_session_purge_jobs_updated",
    "idx_session_records_active_created",
    "idx_session_speakers_participant",
    "idx_session_speakers_session_epoch",
];
const V27_TRIGGERS: &[&str] = V26_TRIGGERS;
const V28_TABLES: &[&str] = &[
    "audio_retention_chunks",
    "context_pack_sources",
    "context_packs",
    "notebook_capture_profiles",
    "notebook_capture_runs",
    "notebook_context_pack_bindings",
    "notebook_projection_mutations",
    "notebook_session_projections",
    "notebook_sessions",
    "notebook_tabs",
    "notebooks",
    "participants",
    "realtime_translation_inbox",
    "realtime_utterance_overrides",
    "realtime_utterance_variants",
    "realtime_utterances",
    "search_index",
    "search_index_config",
    "search_index_content",
    "search_index_data",
    "search_index_docsize",
    "search_index_idx",
    "session_meta",
    "session_purge_jobs",
    "session_records",
    "session_speakers",
];
const V28_INDEXES: &[&str] = &[
    "idx_audio_retention_chunks_due",
    "idx_audio_retention_chunks_session",
    "idx_context_pack_sources_pack_order",
    "idx_context_packs_library",
    "idx_context_packs_private_owner",
    "idx_notebook_capture_runs_notebook_created",
    "idx_notebook_capture_runs_single_active",
    "idx_notebook_context_bindings_order",
    "idx_notebook_projection_mutations_session",
    "idx_notebook_projection_mutations_utterance_language",
    "idx_notebook_session_projections_notebook_session",
    "idx_notebook_session_projections_tab",
    "idx_notebook_sessions_session_unique",
    "idx_notebook_tabs_builtin_unique",
    "idx_notebook_tabs_notebook_position",
    "idx_notebooks_updated",
    "idx_participants_display_name",
    "idx_realtime_translation_inbox_bound_lane",
    "idx_realtime_translation_inbox_unbound",
    "idx_realtime_utterance_variants_language",
    "idx_realtime_utterance_variants_one_source",
    "idx_realtime_utterances_id_sequence",
    "idx_realtime_utterances_session_sequence",
    "idx_realtime_utterances_session_speaker",
    "idx_session_purge_jobs_updated",
    "idx_session_records_active_created",
    "idx_session_speakers_participant",
    "idx_session_speakers_session_epoch",
];
const V28_TRIGGERS: &[&str] = V27_TRIGGERS;
const V29_TABLES: &[&str] = &[
    "audio_retention_chunks",
    "context_pack_sources",
    "context_packs",
    "notebook_capture_profiles",
    "notebook_capture_runs",
    "notebook_context_pack_bindings",
    "notebook_projection_mutations",
    "notebook_session_projections",
    "notebook_sessions",
    "notebook_tabs",
    "notebooks",
    "participants",
    "realtime_transcript_gaps",
    "realtime_translation_inbox",
    "realtime_utterance_overrides",
    "realtime_utterance_variants",
    "realtime_utterances",
    "search_index",
    "search_index_config",
    "search_index_content",
    "search_index_data",
    "search_index_docsize",
    "search_index_idx",
    "session_meta",
    "session_purge_jobs",
    "session_records",
    "session_speakers",
];
const V30_TABLES: &[&str] = &[
    "audio_retention_chunks",
    "context_pack_sources",
    "context_packs",
    "notebook_capture_profiles",
    "notebook_capture_runs",
    "notebook_context_pack_bindings",
    "notebook_projection_mutations",
    "notebook_session_projections",
    "notebook_sessions",
    "notebook_tabs",
    "notebooks",
    "participants",
    "provider_remote_artifacts",
    "realtime_transcript_gaps",
    "realtime_translation_inbox",
    "realtime_utterance_overrides",
    "realtime_utterance_variants",
    "realtime_utterances",
    "search_index",
    "search_index_config",
    "search_index_content",
    "search_index_data",
    "search_index_docsize",
    "search_index_idx",
    "session_meta",
    "session_purge_jobs",
    "session_records",
    "session_speakers",
];
const V29_INDEXES: &[&str] = &[
    "idx_audio_retention_chunks_due",
    "idx_audio_retention_chunks_session",
    "idx_context_pack_sources_pack_order",
    "idx_context_packs_library",
    "idx_context_packs_private_owner",
    "idx_notebook_capture_runs_notebook_created",
    "idx_notebook_capture_runs_single_active",
    "idx_notebook_context_bindings_order",
    "idx_notebook_projection_mutations_session",
    "idx_notebook_projection_mutations_utterance_language",
    "idx_notebook_session_projections_notebook_session",
    "idx_notebook_session_projections_tab",
    "idx_notebook_sessions_session_unique",
    "idx_notebook_tabs_builtin_unique",
    "idx_notebook_tabs_notebook_position",
    "idx_notebooks_updated",
    "idx_participants_display_name",
    "idx_realtime_transcript_gaps_pending",
    "idx_realtime_translation_inbox_bound_lane",
    "idx_realtime_translation_inbox_unbound",
    "idx_realtime_utterance_variants_language",
    "idx_realtime_utterance_variants_one_source",
    "idx_realtime_utterances_id_sequence",
    "idx_realtime_utterances_session_sequence",
    "idx_realtime_utterances_session_speaker",
    "idx_session_purge_jobs_updated",
    "idx_session_records_active_created",
    "idx_session_speakers_participant",
    "idx_session_speakers_session_epoch",
];
const V29_TRIGGERS: &[&str] = V28_TRIGGERS;

/// Install, migrate, or validate the supported main-database schema.
pub fn run_migrations(conn: &Connection) -> SqlResult<()> {
    conn.pragma_update(None, "foreign_keys", "ON")?;
    let current = conn.pragma_query_value(None, "user_version", |row| row.get::<_, i32>(0))?;

    match current {
        0 if database_has_user_objects(conn)? => Err(schema_reset_required(0)),
        0 => install_current_baseline(conn),
        OLDEST_SUPPORTED_VERSION => {
            validate_v23_baseline(conn)?;
            migrate_v23_to_v24(conn)?;
            validate_v24_baseline(conn)?;
            migrate_v24_to_v25(conn)?;
            validate_v25_baseline(conn)?;
            migrate_v25_to_v26(conn)?;
            validate_v26_baseline(conn)?;
            migrate_v26_to_v27(conn)?;
            validate_v27_baseline(conn)?;
            migrate_v27_to_v28(conn)?;
            validate_v28_baseline(conn)?;
            migrate_v28_to_v29(conn)?;
            validate_v29_baseline(conn)?;
            migrate_v29_to_v30(conn)?;
            validate_v30_baseline(conn)?;
            migrate_v30_to_v31(conn)?;
            validate_v31_baseline(conn)
        }
        SPEAKER_VERSION => {
            validate_v24_baseline(conn)?;
            migrate_v24_to_v25(conn)?;
            validate_v25_baseline(conn)?;
            migrate_v25_to_v26(conn)?;
            validate_v26_baseline(conn)?;
            migrate_v26_to_v27(conn)?;
            validate_v27_baseline(conn)?;
            migrate_v27_to_v28(conn)?;
            validate_v28_baseline(conn)?;
            migrate_v28_to_v29(conn)?;
            validate_v29_baseline(conn)?;
            migrate_v29_to_v30(conn)?;
            validate_v30_baseline(conn)?;
            migrate_v30_to_v31(conn)?;
            validate_v31_baseline(conn)
        }
        SELECTED_LANGUAGES_VERSION => {
            validate_v25_baseline(conn)?;
            migrate_v25_to_v26(conn)?;
            validate_v26_baseline(conn)?;
            migrate_v26_to_v27(conn)?;
            validate_v27_baseline(conn)?;
            migrate_v27_to_v28(conn)?;
            validate_v28_baseline(conn)?;
            migrate_v28_to_v29(conn)?;
            validate_v29_baseline(conn)?;
            migrate_v29_to_v30(conn)?;
            validate_v30_baseline(conn)?;
            migrate_v30_to_v31(conn)?;
            validate_v31_baseline(conn)
        }
        MULTILINGUAL_VERSION => {
            validate_v26_baseline(conn)?;
            migrate_v26_to_v27(conn)?;
            validate_v27_baseline(conn)?;
            migrate_v27_to_v28(conn)?;
            validate_v28_baseline(conn)?;
            migrate_v28_to_v29(conn)?;
            validate_v29_baseline(conn)?;
            migrate_v29_to_v30(conn)?;
            validate_v30_baseline(conn)?;
            migrate_v30_to_v31(conn)?;
            validate_v31_baseline(conn)
        }
        REALTIME_LORO_VERSION => {
            validate_v27_baseline(conn)?;
            migrate_v27_to_v28(conn)?;
            validate_v28_baseline(conn)?;
            migrate_v28_to_v29(conn)?;
            validate_v29_baseline(conn)?;
            migrate_v29_to_v30(conn)?;
            validate_v30_baseline(conn)?;
            migrate_v30_to_v31(conn)?;
            validate_v31_baseline(conn)
        }
        TRANSLATION_INBOX_VERSION => {
            validate_v28_baseline(conn)?;
            migrate_v28_to_v29(conn)?;
            validate_v29_baseline(conn)?;
            migrate_v29_to_v30(conn)?;
            validate_v30_baseline(conn)?;
            migrate_v30_to_v31(conn)?;
            validate_v31_baseline(conn)
        }
        TRANSCRIPT_GAPS_VERSION => {
            validate_v29_baseline(conn)?;
            migrate_v29_to_v30(conn)?;
            validate_v30_baseline(conn)?;
            migrate_v30_to_v31(conn)?;
            validate_v31_baseline(conn)
        }
        CURRENT_VERSION => validate_v31_baseline(conn),
        unsupported => Err(schema_reset_required(unsupported)),
    }?;

    retire_legacy_common_caption_profile_state(conn)
}

/// Retire the former privileged caption-language setting without touching
/// immutable run snapshots or transcript history.
///
/// This repair also runs for databases that already claim the current schema:
/// early v26 builds preserved the v25 value even though new captures reject it.
/// Keeping the repair idempotent lets those installs recover on the next launch
/// without asking the user to recreate a Notebook or reselect languages.
fn retire_legacy_common_caption_profile_state(conn: &Connection) -> SqlResult<()> {
    let retired = conn.execute(
        "UPDATE notebook_capture_profiles
         SET common_caption_language = NULL
         WHERE common_caption_language IS NOT NULL",
        [],
    )?;
    if retired > 0 {
        tracing::info!(
            retired,
            "retired legacy common-caption profile state; selected languages are equal lanes"
        );
    }
    Ok(())
}

fn schema_reset_required(version: i32) -> rusqlite::Error {
    rusqlite::Error::SqliteFailure(
        rusqlite::ffi::Error::new(rusqlite::ffi::SQLITE_SCHEMA),
        Some(format!(
            "unsupported schema {version}; reset required (Zulangue accepts only an empty database, schema {OLDEST_SUPPORTED_VERSION}, schema {SPEAKER_VERSION}, schema {SELECTED_LANGUAGES_VERSION}, schema {MULTILINGUAL_VERSION}, schema {REALTIME_LORO_VERSION}, schema {TRANSLATION_INBOX_VERSION}, schema {TRANSCRIPT_GAPS_VERSION}, schema {REMOTE_ARTIFACTS_VERSION}, or schema {CURRENT_VERSION})"
        )),
    )
}

fn database_has_user_objects(conn: &Connection) -> SqlResult<bool> {
    Ok(conn
        .query_row(
            "SELECT 1 FROM sqlite_schema
             WHERE name NOT LIKE 'sqlite_%'
               AND type IN ('table', 'index', 'trigger', 'view')
             LIMIT 1",
            [],
            |_| Ok(()),
        )
        .optional()?
        .is_some())
}

fn validate_v23_baseline(conn: &Connection) -> SqlResult<()> {
    validate_exact_object_names(conn, OLDEST_SUPPORTED_VERSION, "table", V23_TABLES)?;
    validate_exact_object_names(conn, OLDEST_SUPPORTED_VERSION, "index", V23_INDEXES)?;
    validate_exact_object_names(conn, OLDEST_SUPPORTED_VERSION, "trigger", V23_TRIGGERS)?;

    const PROBES: &[&str] = &[
        "SELECT id, title, session_type, status, duration_ms, created_at, deleted_at
         FROM session_records LIMIT 0",
        "SELECT session_id, encrypted_path, key_id, tokens_json,
                privacy_level, sample_rate, channels
         FROM session_meta LIMIT 0",
        "SELECT id, title, created_at, updated_at, deleted_at FROM notebooks LIMIT 0",
        "SELECT id, notebook_id, builtin_kind, title, doc_id, position,
                created_at, updated_at, deleted_at FROM notebook_tabs LIMIT 0",
        "SELECT notebook_id, remote_realtime_enabled, capture_mode, language_a,
                language_b, left_language, right_language,
                privacy_level, send_context_to_soniox, revision,
                created_at, updated_at FROM notebook_capture_profiles LIMIT 0",
        "SELECT id, notebook_id, session_id, profile_revision, profile_snapshot_json,
                realtime_provider_id, realtime_model_id,
                post_stop_provider_id, post_stop_model_id,
                context_receipt_json, context_snapshot_ciphertext,
                context_snapshot_key_ref, context_snapshot_sha256, capture_state,
                remote_health, projection_state, async_task_state,
                async_authorized_at_ms, async_language_hint, async_task_id,
                async_task_payload_sha256, async_projection_state,
                provider_error_type, provider_request_id,
                audio_journal_path, audio_path, audio_key_ref, sample_rate, channels,
                captured_frames, created_at, updated_at, completed_at
         FROM notebook_capture_runs LIMIT 0",
        "SELECT id, session_id, sequence, source_language, source_text,
                source_start_ms, source_end_ms, translated_language, translated_text,
                revision, completion, alignment, created_at, updated_at
         FROM realtime_utterances LIMIT 0",
        "SELECT id, scope, owner_notebook_id, title, key_ref, revision,
                created_at, updated_at, deleted_at FROM context_packs LIMIT 0",
        "SELECT id, pack_id, title, format, content_kind, ciphertext,
                plaintext_sha256, plaintext_bytes, metadata_json, trust_state,
                revision, created_at, updated_at, deleted_at
         FROM context_pack_sources LIMIT 0",
        "SELECT id, session_id, utterance_id, lane, expected_revision, target_text,
                state, created_at, updated_at FROM notebook_projection_mutations LIMIT 0",
        "SELECT session_id, plan_json, phase, last_error, created_at, updated_at
         FROM session_purge_jobs LIMIT 0",
    ];

    for probe in PROBES {
        if conn.prepare(probe).is_err() {
            return Err(schema_reset_required(OLDEST_SUPPORTED_VERSION));
        }
    }
    let active_index_sql =
        schema_object_sql(conn, "index", "idx_notebook_capture_runs_single_active")?
            .to_ascii_lowercase();
    if !active_index_sql.contains("create unique index")
        || !active_index_sql.contains("capture_state in ('recording', 'paused', 'draining')")
    {
        return Err(schema_reset_required(OLDEST_SUPPORTED_VERSION));
    }
    for trigger in V23_TRIGGERS {
        let sql = schema_object_sql(conn, "trigger", trigger)?;
        if !sql.to_ascii_lowercase().contains("raise(abort") {
            return Err(schema_reset_required(OLDEST_SUPPORTED_VERSION));
        }
    }
    Ok(())
}

fn validate_v24_baseline(conn: &Connection) -> SqlResult<()> {
    validate_v24_or_later_baseline(conn, SPEAKER_VERSION)
}

fn validate_v25_baseline(conn: &Connection) -> SqlResult<()> {
    validate_v24_or_later_baseline(conn, SELECTED_LANGUAGES_VERSION)
}

fn validate_v26_baseline(conn: &Connection) -> SqlResult<()> {
    validate_v24_or_later_baseline(conn, MULTILINGUAL_VERSION)
}

fn validate_v27_baseline(conn: &Connection) -> SqlResult<()> {
    validate_v24_or_later_baseline(conn, REALTIME_LORO_VERSION)
}

fn validate_v28_baseline(conn: &Connection) -> SqlResult<()> {
    validate_v24_or_later_baseline(conn, TRANSLATION_INBOX_VERSION)
}

fn validate_v29_baseline(conn: &Connection) -> SqlResult<()> {
    validate_v24_or_later_baseline(conn, TRANSCRIPT_GAPS_VERSION)
}

fn validate_v30_baseline(conn: &Connection) -> SqlResult<()> {
    validate_v30_baseline_objects(conn, REMOTE_ARTIFACTS_VERSION)
}

fn validate_v31_baseline(conn: &Connection) -> SqlResult<()> {
    validate_v30_baseline_objects(conn, CURRENT_VERSION)?;
    // v31 的实质变化只在索引唯一性里:一条 canonical 语言车道可以持有多个
    // 辅助分段,所以绑定索引不再是 UNIQUE。
    let index_sql = schema_object_sql(conn, "index", "idx_realtime_translation_inbox_bound_lane")?
        .to_ascii_lowercase();
    if index_sql.contains("unique") {
        return Err(schema_reset_required(CURRENT_VERSION));
    }
    Ok(())
}

fn validate_v30_baseline_objects(conn: &Connection, claimed_version: i32) -> SqlResult<()> {
    validate_v24_or_later_baseline(conn, claimed_version)?;
    let table_sql = schema_object_sql(conn, "table", "notebook_capture_runs")?.to_ascii_lowercase();
    if !table_sql.contains("'stt-async-v5'") {
        return Err(schema_reset_required(claimed_version));
    }
    Ok(())
}

/// v24 及之后每一版的对象集合都是严格累加的，所以版本号本身就足以选出
/// 该版应有的表/索引/触发器；不要再退回按特性标志逐个传参。
fn validate_v24_or_later_baseline(conn: &Connection, claimed_version: i32) -> SqlResult<()> {
    let has_multilingual_profile = claimed_version >= SELECTED_LANGUAGES_VERSION;
    let has_utterance_variants = claimed_version >= MULTILINGUAL_VERSION;
    let has_realtime_loro_projection = claimed_version >= REALTIME_LORO_VERSION;
    let has_translation_inbox = claimed_version >= TRANSLATION_INBOX_VERSION;
    let has_transcript_gaps = claimed_version >= TRANSCRIPT_GAPS_VERSION;
    let has_remote_artifact_journal = claimed_version >= REMOTE_ARTIFACTS_VERSION;
    let (tables, indexes, triggers) = match claimed_version {
        // v31 changed one index's uniqueness, not the object set.
        CURRENT_VERSION | REMOTE_ARTIFACTS_VERSION => (V30_TABLES, V29_INDEXES, V29_TRIGGERS),
        TRANSCRIPT_GAPS_VERSION => (V29_TABLES, V29_INDEXES, V29_TRIGGERS),
        TRANSLATION_INBOX_VERSION => (V28_TABLES, V28_INDEXES, V28_TRIGGERS),
        REALTIME_LORO_VERSION => (V27_TABLES, V27_INDEXES, V27_TRIGGERS),
        MULTILINGUAL_VERSION => (V26_TABLES, V26_INDEXES, V26_TRIGGERS),
        SELECTED_LANGUAGES_VERSION => (V25_TABLES, V25_INDEXES, V25_TRIGGERS),
        _ => (V24_TABLES, V24_INDEXES, V24_TRIGGERS),
    };
    validate_exact_object_names(conn, claimed_version, "table", tables)?;
    validate_exact_object_names(conn, claimed_version, "index", indexes)?;
    validate_exact_object_names(conn, claimed_version, "trigger", triggers)?;

    const PROBES: &[&str] = &[
        "SELECT id, title, session_type, status, duration_ms, created_at, deleted_at
         FROM session_records LIMIT 0",
        "SELECT session_id, encrypted_path, key_id, tokens_json,
                privacy_level, sample_rate, channels
         FROM session_meta LIMIT 0",
        "SELECT id, title, created_at, updated_at, deleted_at FROM notebooks LIMIT 0",
        "SELECT id, notebook_id, builtin_kind, title, doc_id, position,
                created_at, updated_at, deleted_at FROM notebook_tabs LIMIT 0",
        "SELECT id, notebook_id, session_id, profile_revision, profile_snapshot_json,
                realtime_provider_id, realtime_model_id,
                post_stop_provider_id, post_stop_model_id,
                context_receipt_json, context_snapshot_ciphertext,
                context_snapshot_key_ref, context_snapshot_sha256, capture_state,
                remote_health, projection_state, async_task_state,
                async_authorized_at_ms, async_language_hint, async_task_id,
                async_task_payload_sha256, async_projection_state,
                provider_error_type, provider_request_id,
                audio_journal_path, audio_path, audio_key_ref, sample_rate, channels,
                captured_frames, created_at, updated_at, completed_at
         FROM notebook_capture_runs LIMIT 0",
        "SELECT id, display_name, created_at, updated_at FROM participants LIMIT 0",
        "SELECT id, session_id, provider_session_epoch, provider, provider_label,
                local_display_name, participant_id, participant_linked_at,
                created_at, updated_at
         FROM session_speakers LIMIT 0",
        "SELECT id, session_id, sequence, session_speaker_id, source_language, source_text,
                source_start_ms, source_end_ms, translated_language, translated_text,
                revision, completion, alignment, created_at, updated_at
         FROM realtime_utterances LIMIT 0",
        "SELECT id, scope, owner_notebook_id, title, key_ref, revision,
                created_at, updated_at, deleted_at FROM context_packs LIMIT 0",
        "SELECT id, pack_id, title, format, content_kind, ciphertext,
                plaintext_sha256, plaintext_bytes, metadata_json, trust_state,
                revision, created_at, updated_at, deleted_at
         FROM context_pack_sources LIMIT 0",
        "SELECT session_id, plan_json, phase, last_error, created_at, updated_at
         FROM session_purge_jobs LIMIT 0",
    ];

    let profile_probe = if has_multilingual_profile {
        "SELECT notebook_id, remote_realtime_enabled, capture_mode, language_a,
                language_b, left_language, right_language, selected_languages_json,
                common_caption_language, privacy_level, send_context_to_soniox, revision,
                created_at, updated_at FROM notebook_capture_profiles LIMIT 0"
    } else {
        "SELECT notebook_id, remote_realtime_enabled, capture_mode, language_a,
                language_b, left_language, right_language,
                privacy_level, send_context_to_soniox, revision,
                created_at, updated_at FROM notebook_capture_profiles LIMIT 0"
    };
    if conn.prepare(profile_probe).is_err() {
        return Err(schema_reset_required(claimed_version));
    }
    let mutation_probe = if has_utterance_variants {
        "SELECT id, session_id, utterance_id, lane, lane_language, expected_revision,
                target_text, state, created_at, updated_at
         FROM notebook_projection_mutations LIMIT 0"
    } else {
        "SELECT id, session_id, utterance_id, lane, expected_revision, target_text,
                state, created_at, updated_at
         FROM notebook_projection_mutations LIMIT 0"
    };
    if conn.prepare(mutation_probe).is_err() {
        return Err(schema_reset_required(claimed_version));
    }
    if has_utterance_variants
        && conn
            .prepare(
                "SELECT utterance_id, language, role, text, state, completion,
                        revision, created_at, updated_at
                 FROM realtime_utterance_variants LIMIT 0",
            )
            .is_err()
    {
        return Err(schema_reset_required(claimed_version));
    }
    if has_realtime_loro_projection
        && (conn
            .prepare(
                "SELECT realtime_loro_desired_revision, realtime_loro_applied_revision
                 FROM notebook_capture_runs LIMIT 0",
            )
            .is_err()
            || conn
                .prepare(
                    "SELECT utterance_id, lane, lane_language, text,
                            machine_utterance_revision, machine_variant_revision,
                            edit_revision,
                            created_at, updated_at
                     FROM realtime_utterance_overrides LIMIT 0",
                )
                .is_err()
            || conn
                .prepare(
                    "SELECT expected_variant_revision
                     FROM notebook_projection_mutations LIMIT 0",
                )
                .is_err()
            || conn
                .prepare(
                    "SELECT source_projection_revision
                     FROM realtime_utterances LIMIT 0",
                )
                .is_err()
            || conn
                .prepare(
                    "SELECT projection_revision
                     FROM realtime_utterance_variants LIMIT 0",
                )
                .is_err())
    {
        return Err(schema_reset_required(claimed_version));
    }
    if has_translation_inbox
        && conn
            .prepare(
                "SELECT session_id, lane_index, group_epoch, provider_sequence,
                        target_language, source_language, source_text,
                        source_start_ms, source_end_ms, translated_text,
                        completion, state, revision, bound_utterance_id,
                        bound_sequence, created_at, updated_at
                 FROM realtime_translation_inbox LIMIT 0",
            )
            .is_err()
    {
        return Err(schema_reset_required(claimed_version));
    }
    if has_transcript_gaps
        && conn
            .prepare(
                "SELECT id, session_id, start_frame, end_frame, reason, repair_state,
                        created_at, updated_at
                 FROM realtime_transcript_gaps LIMIT 0",
            )
            .is_err()
    {
        return Err(schema_reset_required(claimed_version));
    }
    if has_remote_artifact_journal
        && conn
            .prepare(
                "SELECT task_id, session_id, provider_id, client_reference_id,
                        remote_file_id, remote_transcription_id, created_at, updated_at
                 FROM provider_remote_artifacts LIMIT 0",
            )
            .is_err()
    {
        return Err(schema_reset_required(claimed_version));
    }
    for probe in PROBES {
        if conn.prepare(probe).is_err() {
            return Err(schema_reset_required(claimed_version));
        }
    }
    let active_index_sql =
        schema_object_sql(conn, "index", "idx_notebook_capture_runs_single_active")?
            .to_ascii_lowercase();
    if !active_index_sql.contains("create unique index")
        || !active_index_sql.contains("capture_state in ('recording', 'paused', 'draining')")
    {
        return Err(schema_reset_required(claimed_version));
    }
    for trigger in triggers {
        let sql = schema_object_sql(conn, "trigger", trigger)?;
        if !sql.to_ascii_lowercase().contains("raise(abort") {
            return Err(schema_reset_required(claimed_version));
        }
    }
    Ok(())
}

fn validate_exact_object_names(
    conn: &Connection,
    claimed_version: i32,
    object_type: &str,
    expected: &[&str],
) -> SqlResult<()> {
    let mut stmt = conn.prepare(
        "SELECT name FROM sqlite_schema
         WHERE type = ?1 AND name NOT LIKE 'sqlite_%'
         ORDER BY name",
    )?;
    let actual = stmt
        .query_map([object_type], |row| row.get::<_, String>(0))?
        .collect::<SqlResult<Vec<_>>>()?;
    let expected = expected
        .iter()
        .map(|name| (*name).to_string())
        .collect::<Vec<_>>();
    if actual != expected {
        return Err(schema_reset_required(claimed_version));
    }
    Ok(())
}

fn schema_object_sql(conn: &Connection, object_type: &str, name: &str) -> SqlResult<String> {
    conn.query_row(
        "SELECT sql FROM sqlite_schema WHERE type = ?1 AND name = ?2",
        [object_type, name],
        |row| row.get(0),
    )
}

fn migrate_v23_to_v24(conn: &Connection) -> SqlResult<()> {
    let tx = conn.unchecked_transaction()?;
    tx.execute_batch(
        r#"
        CREATE TABLE participants (
            id            TEXT PRIMARY KEY,
            display_name  TEXT NOT NULL CHECK(length(trim(display_name)) > 0),
            created_at    TEXT NOT NULL,
            updated_at    TEXT NOT NULL
        );
        CREATE INDEX idx_participants_display_name
            ON participants(display_name COLLATE NOCASE, id);

        CREATE TABLE session_speakers (
            id                      TEXT PRIMARY KEY,
            session_id              TEXT NOT NULL
                                             REFERENCES notebook_capture_runs(session_id)
                                             ON DELETE CASCADE,
            provider_session_epoch  INTEGER NOT NULL CHECK(provider_session_epoch >= 0),
            provider                TEXT NOT NULL CHECK(length(trim(provider)) > 0),
            provider_label          TEXT NOT NULL CHECK(length(trim(provider_label)) > 0),
            local_display_name      TEXT
                                      CHECK(local_display_name IS NULL
                                            OR length(trim(local_display_name)) > 0),
            participant_id          TEXT REFERENCES participants(id) ON DELETE SET NULL,
            participant_linked_at   TEXT,
            created_at              TEXT NOT NULL,
            updated_at              TEXT NOT NULL,
            UNIQUE(session_id, provider_session_epoch, provider, provider_label)
        );
        CREATE INDEX idx_session_speakers_session_epoch
            ON session_speakers(session_id, provider_session_epoch, provider, provider_label);
        CREATE INDEX idx_session_speakers_participant
            ON session_speakers(participant_id, session_id, id);

        ALTER TABLE realtime_utterances
            ADD COLUMN session_speaker_id TEXT
                REFERENCES session_speakers(id) ON DELETE SET NULL;
        CREATE INDEX idx_realtime_utterances_session_speaker
            ON realtime_utterances(session_speaker_id, session_id, sequence);
        "#,
    )?;
    tx.pragma_update(None, "user_version", SPEAKER_VERSION)?;
    tx.commit()?;
    tracing::info!("migrated Zulangue schema v{OLDEST_SUPPORTED_VERSION} to v{SPEAKER_VERSION}");
    Ok(())
}

fn migrate_v24_to_v25(conn: &Connection) -> SqlResult<()> {
    let tx = conn.unchecked_transaction()?;
    tx.execute_batch(
        r#"
        ALTER TABLE notebook_capture_profiles RENAME TO notebook_capture_profiles_v24;

        CREATE TABLE notebook_capture_profiles (
            notebook_id                    TEXT PRIMARY KEY
                                                   REFERENCES notebooks(id) ON DELETE CASCADE,
            remote_realtime_enabled        INTEGER NOT NULL DEFAULT 0
                                                   CHECK(remote_realtime_enabled IN (0, 1)),
            capture_mode                   TEXT NOT NULL DEFAULT 'transcription_only'
                                                   CHECK(capture_mode IN (
                                                       'transcription_only',
                                                       'two_way',
                                                       'multilingual_one_way'
                                                   )),
            language_a                     TEXT NOT NULL DEFAULT 'en',
            language_b                     TEXT NOT NULL DEFAULT 'zh',
            left_language                  TEXT NOT NULL DEFAULT 'en',
            right_language                 TEXT NOT NULL DEFAULT 'zh',
            selected_languages_json        TEXT NOT NULL DEFAULT '["en","zh"]'
                                                   CHECK(
                                                       json_valid(selected_languages_json)
                                                       AND json_type(selected_languages_json) = 'array'
                                                   ),
            common_caption_language        TEXT,
            privacy_level                  TEXT NOT NULL DEFAULT 'standard'
                                                   CHECK(privacy_level IN (
                                                       'standard', 'high', 'maximum'
                                                   )),
            send_context_to_soniox         INTEGER NOT NULL DEFAULT 0
                                                   CHECK(send_context_to_soniox IN (0, 1)),
            revision                       INTEGER NOT NULL DEFAULT 0 CHECK(revision >= 0),
            created_at                     TEXT NOT NULL,
            updated_at                     TEXT NOT NULL,
            CHECK(language_a <> language_b),
            CHECK(left_language IN (language_a, language_b)),
            CHECK(right_language IN (language_a, language_b)),
            CHECK(left_language <> right_language),
            CHECK(capture_mode = 'transcription_only' OR remote_realtime_enabled = 1),
            CHECK(send_context_to_soniox = 0 OR remote_realtime_enabled = 1)
        );

        INSERT INTO notebook_capture_profiles (
            notebook_id, remote_realtime_enabled, capture_mode,
            language_a, language_b, left_language, right_language,
            selected_languages_json, common_caption_language,
            privacy_level, send_context_to_soniox, revision, created_at, updated_at
        )
        SELECT notebook_id, remote_realtime_enabled, capture_mode,
               language_a, language_b, left_language, right_language,
               json_array(language_a, language_b), NULL,
               privacy_level, send_context_to_soniox, revision, created_at, updated_at
        FROM notebook_capture_profiles_v24;

        DROP TABLE notebook_capture_profiles_v24;
        "#,
    )?;
    tx.pragma_update(None, "user_version", SELECTED_LANGUAGES_VERSION)?;
    tx.commit()?;
    tracing::info!("migrated Zulangue schema v{SPEAKER_VERSION} to v{SELECTED_LANGUAGES_VERSION}");
    Ok(())
}

fn migrate_v25_to_v26(conn: &Connection) -> SqlResult<()> {
    let tx = conn.unchecked_transaction()?;
    tx.execute_batch(
        r#"
        CREATE TABLE realtime_utterance_variants (
            utterance_id  TEXT NOT NULL
                               REFERENCES realtime_utterances(id) ON DELETE CASCADE,
            language      TEXT NOT NULL CHECK(length(trim(language)) > 0),
            role          TEXT NOT NULL CHECK(role IN ('source', 'translation')),
            text          TEXT,
            state         TEXT NOT NULL
                               CHECK(state IN ('waiting', 'ready', 'failed', 'unavailable')),
            completion    TEXT CHECK(completion IS NULL
                                     OR completion IN ('partial', 'complete')),
            revision      INTEGER NOT NULL DEFAULT 0 CHECK(revision >= 0),
            created_at    TEXT NOT NULL,
            updated_at    TEXT NOT NULL,
            PRIMARY KEY(utterance_id, language),
            CHECK(
                (state = 'ready' AND text IS NOT NULL AND completion IS NOT NULL)
                OR
                (state <> 'ready' AND text IS NULL AND completion IS NULL)
            )
        );
        CREATE UNIQUE INDEX idx_realtime_utterance_variants_language
            ON realtime_utterance_variants(utterance_id, lower(trim(language)));
        CREATE UNIQUE INDEX idx_realtime_utterance_variants_one_source
            ON realtime_utterance_variants(utterance_id)
            WHERE role = 'source';

        INSERT INTO realtime_utterance_variants (
            utterance_id, language, role, text, state, completion,
            revision, created_at, updated_at
        )
        SELECT id, source_language, 'source', source_text, 'ready', completion,
               revision, created_at, updated_at
        FROM realtime_utterances;

        INSERT INTO realtime_utterance_variants (
            utterance_id, language, role, text, state, completion,
            revision, created_at, updated_at
        )
        SELECT id, translated_language, 'translation', translated_text, 'ready', completion,
               revision, created_at, updated_at
        FROM realtime_utterances
        WHERE translated_language IS NOT NULL AND translated_text IS NOT NULL;

        ALTER TABLE notebook_projection_mutations
            RENAME TO notebook_projection_mutations_v25;

        CREATE TABLE notebook_projection_mutations (
            id                 TEXT PRIMARY KEY,
            session_id         TEXT NOT NULL,
            utterance_id       TEXT NOT NULL
                                      REFERENCES realtime_utterances(id) ON DELETE CASCADE,
            lane               TEXT NOT NULL CHECK(lane IN ('source', 'translated')),
            lane_language      TEXT NOT NULL CHECK(length(trim(lane_language)) > 0),
            expected_revision  INTEGER NOT NULL CHECK(expected_revision >= 0),
            target_text        TEXT NOT NULL,
            state              TEXT NOT NULL DEFAULT 'pending' CHECK(state = 'pending'),
            created_at         TEXT NOT NULL,
            updated_at         TEXT NOT NULL,
            UNIQUE(utterance_id)
        );

        INSERT INTO notebook_projection_mutations (
            id, session_id, utterance_id, lane, lane_language,
            expected_revision, target_text, state, created_at, updated_at
        )
        SELECT m.id, m.session_id, m.utterance_id, m.lane,
               CASE m.lane
                   WHEN 'source' THEN u.source_language
                   WHEN 'translated' THEN u.translated_language
               END,
               m.expected_revision, m.target_text, m.state, m.created_at, m.updated_at
        FROM notebook_projection_mutations_v25 m
        JOIN realtime_utterances u ON u.id = m.utterance_id;

        DROP TABLE notebook_projection_mutations_v25;
        CREATE INDEX idx_notebook_projection_mutations_session
            ON notebook_projection_mutations(session_id, created_at, id);
        "#,
    )?;
    tx.pragma_update(None, "user_version", MULTILINGUAL_VERSION)?;
    tx.commit()?;
    tracing::info!(
        "migrated Zulangue schema v{SELECTED_LANGUAGES_VERSION} to v{MULTILINGUAL_VERSION}"
    );
    Ok(())
}

fn migrate_v26_to_v27(conn: &Connection) -> SqlResult<()> {
    let tx = conn.unchecked_transaction()?;
    // This migration owns SQLite only. Existing Loro rich-text marks may
    // still contain region/script tags such as `EN-US` or `zh-Hans`; the
    // projector must match those selectors by the same canonical primary
    // language. Rewriting Loro here would cross the SQLite transaction
    // boundary and recreate the dual-write failure this outbox removes.
    let has_primary_language_collision = tx
        .query_row(
            "SELECT 1
             FROM realtime_utterance_variants
             GROUP BY
                 utterance_id,
                 lower(
                     CASE
                         WHEN instr(trim(language), '-') > 0
                             THEN substr(
                                 trim(language),
                                 1,
                                 instr(trim(language), '-') - 1
                             )
                         ELSE trim(language)
                     END
                 )
             HAVING COUNT(*) > 1
             LIMIT 1",
            [],
            |_| Ok(()),
        )
        .optional()?
        .is_some();
    let has_base_language_collision = tx
        .query_row(
            "SELECT 1
             FROM realtime_utterances
             WHERE translated_language IS NOT NULL
               AND lower(
                       CASE
                           WHEN instr(trim(source_language), '-') > 0
                               THEN substr(
                                   trim(source_language),
                                   1,
                                   instr(trim(source_language), '-') - 1
                               )
                           ELSE trim(source_language)
                       END
                   )
                   =
                   lower(
                       CASE
                           WHEN instr(trim(translated_language), '-') > 0
                               THEN substr(
                                   trim(translated_language),
                                   1,
                                   instr(trim(translated_language), '-') - 1
                               )
                           ELSE trim(translated_language)
                       END
                   )
             LIMIT 1",
            [],
            |_| Ok(()),
        )
        .optional()?
        .is_some();
    if has_primary_language_collision || has_base_language_collision {
        return Err(schema_reset_required(MULTILINGUAL_VERSION));
    }
    tx.execute_batch(
        r#"
        ALTER TABLE notebook_capture_runs
            ADD COLUMN realtime_loro_desired_revision
                INTEGER NOT NULL DEFAULT 0 CHECK(realtime_loro_desired_revision >= 0);
        ALTER TABLE notebook_capture_runs
            ADD COLUMN realtime_loro_applied_revision
                INTEGER NOT NULL DEFAULT 0
                CHECK(
                    realtime_loro_applied_revision >= 0
                    AND realtime_loro_applied_revision <= realtime_loro_desired_revision
                );
        ALTER TABLE realtime_utterances
            ADD COLUMN source_projection_revision
                INTEGER NOT NULL DEFAULT 0 CHECK(source_projection_revision >= 0);
        ALTER TABLE realtime_utterance_variants
            ADD COLUMN projection_revision
                INTEGER NOT NULL DEFAULT 0 CHECK(projection_revision >= 0);

        UPDATE realtime_utterances
        SET source_language = lower(
                CASE
                    WHEN instr(trim(source_language), '-') > 0
                        THEN substr(
                            trim(source_language),
                            1,
                            instr(trim(source_language), '-') - 1
                        )
                    ELSE trim(source_language)
                END
            ),
            translated_language = CASE
                WHEN translated_language IS NULL THEN NULL
                ELSE lower(
                    CASE
                        WHEN instr(trim(translated_language), '-') > 0
                            THEN substr(
                                trim(translated_language),
                                1,
                                instr(trim(translated_language), '-') - 1
                            )
                        ELSE trim(translated_language)
                    END
                )
            END;
        UPDATE realtime_utterance_variants
        SET language = lower(
                CASE
                    WHEN instr(trim(language), '-') > 0
                        THEN substr(
                            trim(language),
                            1,
                            instr(trim(language), '-') - 1
                        )
                    ELSE trim(language)
                END
            );
        UPDATE notebook_projection_mutations
        SET lane_language = lower(
                CASE
                    WHEN instr(trim(lane_language), '-') > 0
                        THEN substr(
                            trim(lane_language),
                            1,
                            instr(trim(lane_language), '-') - 1
                        )
                    ELSE trim(lane_language)
                END
            );

        UPDATE notebook_capture_runs AS run
        SET realtime_loro_desired_revision = 1
        WHERE EXISTS (
                  SELECT 1
                  FROM realtime_utterances utterance
                  WHERE utterance.session_id = run.session_id
                    AND utterance.completion = 'complete'
              )
           OR EXISTS (
                  SELECT 1
                  FROM realtime_utterances utterance
                  JOIN realtime_utterance_variants variant
                    ON variant.utterance_id = utterance.id
                  WHERE utterance.session_id = run.session_id
                    AND variant.role = 'translation'
                    AND variant.state = 'ready'
                    AND variant.completion = 'complete'
              );
        UPDATE realtime_utterances
        SET source_projection_revision = 1
        WHERE completion = 'complete';
        UPDATE realtime_utterance_variants
        SET projection_revision = 1
        WHERE state = 'ready' AND completion = 'complete';

        DROP INDEX idx_notebook_projection_mutations_session;
        ALTER TABLE notebook_projection_mutations
            RENAME TO notebook_projection_mutations_v26;
        CREATE TABLE notebook_projection_mutations (
            id                        TEXT PRIMARY KEY,
            session_id                TEXT NOT NULL,
            utterance_id              TEXT NOT NULL
                                             REFERENCES realtime_utterances(id)
                                             ON DELETE CASCADE,
            lane                      TEXT NOT NULL
                                             CHECK(lane IN ('source', 'translated')),
            lane_language             TEXT NOT NULL
                                             CHECK(length(trim(lane_language)) > 0),
            expected_revision         INTEGER NOT NULL
                                             CHECK(expected_revision >= 0),
            expected_variant_revision INTEGER NOT NULL
                                             CHECK(expected_variant_revision >= 0),
            target_text               TEXT NOT NULL,
            state                     TEXT NOT NULL DEFAULT 'pending'
                                             CHECK(state = 'pending'),
            created_at                TEXT NOT NULL,
            updated_at                TEXT NOT NULL
        );
        INSERT INTO notebook_projection_mutations (
            id, session_id, utterance_id, lane, lane_language,
            expected_revision, expected_variant_revision, target_text,
            state, created_at, updated_at
        )
        SELECT
            mutation.id,
            mutation.session_id,
            mutation.utterance_id,
            mutation.lane,
            mutation.lane_language,
            -- v26 used the aggregate machine utterance revision here. v27
            -- defines this value as the lane-local visible edit revision;
            -- there were no override rows before v27, so every migrated lane
            -- starts at zero.
            0,
            COALESCE((
                SELECT variant.revision
                FROM realtime_utterance_variants variant
                WHERE variant.utterance_id = mutation.utterance_id
                  AND lower(trim(variant.language))
                      = lower(trim(mutation.lane_language))
            ), 0),
            mutation.target_text,
            mutation.state,
            mutation.created_at,
            mutation.updated_at
        FROM notebook_projection_mutations_v26 mutation;
        DROP TABLE notebook_projection_mutations_v26;
        CREATE INDEX idx_notebook_projection_mutations_session
            ON notebook_projection_mutations(session_id, created_at, id);
        CREATE UNIQUE INDEX idx_notebook_projection_mutations_utterance_language
            ON notebook_projection_mutations(
                utterance_id,
                lower(trim(lane_language))
            );

        CREATE TABLE realtime_utterance_overrides (
            utterance_id               TEXT NOT NULL
                                              REFERENCES realtime_utterances(id)
                                              ON DELETE CASCADE,
            lane                       TEXT NOT NULL
                                              CHECK(lane IN ('source', 'translated')),
            lane_language              TEXT NOT NULL
                                              CHECK(length(trim(lane_language)) > 0),
            text                       TEXT NOT NULL,
            machine_utterance_revision INTEGER NOT NULL
                                              CHECK(machine_utterance_revision >= 0),
            machine_variant_revision   INTEGER NOT NULL
                                              CHECK(machine_variant_revision >= 0),
            edit_revision              INTEGER NOT NULL
                                              CHECK(edit_revision > 0),
            created_at                 TEXT NOT NULL,
            updated_at                 TEXT NOT NULL,
            PRIMARY KEY(utterance_id, lane_language)
        );
        "#,
    )?;
    tx.pragma_update(None, "user_version", REALTIME_LORO_VERSION)?;
    tx.commit()?;
    tracing::info!("migrated Zulangue schema v{MULTILINGUAL_VERSION} to v{REALTIME_LORO_VERSION}");
    Ok(())
}

fn migrate_v27_to_v28(conn: &Connection) -> SqlResult<()> {
    let tx = conn.unchecked_transaction()?;
    tx.execute_batch(
        r#"
        CREATE UNIQUE INDEX idx_realtime_utterances_id_sequence
            ON realtime_utterances(id, sequence);
        CREATE TABLE realtime_translation_inbox (
            session_id          TEXT NOT NULL
                                     REFERENCES notebook_capture_runs(session_id)
                                     ON DELETE CASCADE,
            lane_index          INTEGER NOT NULL CHECK(lane_index >= 0),
            group_epoch         INTEGER NOT NULL CHECK(group_epoch >= 0),
            provider_sequence   INTEGER NOT NULL CHECK(provider_sequence >= 0),
            target_language     TEXT NOT NULL CHECK(length(trim(target_language)) > 0),
            source_language     TEXT NOT NULL CHECK(length(trim(source_language)) > 0),
            source_text         TEXT NOT NULL,
            source_start_ms     INTEGER CHECK(source_start_ms IS NULL OR source_start_ms >= 0),
            source_end_ms       INTEGER CHECK(source_end_ms IS NULL OR source_end_ms >= 0),
            translated_text     TEXT,
            completion          TEXT CHECK(completion IS NULL
                                            OR completion IN ('partial', 'complete')),
            state               TEXT NOT NULL CHECK(state IN ('present', 'withdrawn')),
            revision            INTEGER NOT NULL DEFAULT 0 CHECK(revision >= 0),
            bound_utterance_id  TEXT,
            bound_sequence      INTEGER CHECK(bound_sequence IS NULL OR bound_sequence >= 0),
            created_at          TEXT NOT NULL,
            updated_at          TEXT NOT NULL,
            PRIMARY KEY(
                session_id, group_epoch, provider_sequence, target_language
            ),
            CHECK(source_end_ms IS NULL OR source_start_ms IS NULL
                  OR source_end_ms >= source_start_ms),
            CHECK(
                (state = 'present'
                    AND translated_text IS NOT NULL
                    AND completion IS NOT NULL)
                OR
                (state = 'withdrawn'
                    AND translated_text IS NULL
                    AND completion IS NULL)
            ),
            CHECK((bound_utterance_id IS NULL) = (bound_sequence IS NULL)),
            FOREIGN KEY(bound_utterance_id, bound_sequence)
                REFERENCES realtime_utterances(id, sequence)
                ON DELETE SET NULL
        );
        CREATE UNIQUE INDEX idx_realtime_translation_inbox_bound_lane
            ON realtime_translation_inbox(bound_utterance_id, target_language)
            WHERE bound_utterance_id IS NOT NULL;
        CREATE INDEX idx_realtime_translation_inbox_unbound
            ON realtime_translation_inbox(
                session_id, group_epoch, provider_sequence, target_language
            )
            WHERE bound_utterance_id IS NULL;
        "#,
    )?;
    tx.pragma_update(None, "user_version", TRANSLATION_INBOX_VERSION)?;
    tx.commit()?;
    tracing::info!(
        "migrated Zulangue schema v{REALTIME_LORO_VERSION} to v{TRANSLATION_INBOX_VERSION}"
    );
    Ok(())
}

fn migrate_v28_to_v29(conn: &Connection) -> SqlResult<()> {
    let tx = conn.unchecked_transaction()?;
    tx.execute_batch(realtime_transcript_gaps_schema())?;
    tx.pragma_update(None, "user_version", TRANSCRIPT_GAPS_VERSION)?;
    tx.commit()?;
    tracing::info!(
        "migrated Zulangue schema v{TRANSLATION_INBOX_VERSION} to v{TRANSCRIPT_GAPS_VERSION}"
    );
    Ok(())
}

fn realtime_transcript_gaps_schema() -> &'static str {
    r#"
        CREATE TABLE realtime_transcript_gaps (
            id            TEXT PRIMARY KEY,
            session_id    TEXT NOT NULL
                               REFERENCES notebook_capture_runs(session_id) ON DELETE CASCADE,
            start_frame   INTEGER NOT NULL CHECK(start_frame >= 0),
            end_frame     INTEGER NOT NULL CHECK(end_frame > start_frame),
            reason        TEXT NOT NULL CHECK(reason = 'network_discontinuity'),
            repair_state  TEXT NOT NULL
                               CHECK(repair_state IN (
                                   'preserved', 'enqueued', 'provider_accepted',
                                   'result_durable', 'projected', 'repaired', 'failed'
                               )),
            created_at    TEXT NOT NULL,
            updated_at    TEXT NOT NULL,
            UNIQUE(session_id, start_frame, end_frame, reason)
        );
        CREATE INDEX idx_realtime_transcript_gaps_pending
            ON realtime_transcript_gaps(session_id, repair_state, start_frame)
            WHERE repair_state <> 'repaired';
    "#
}

fn install_current_baseline(conn: &Connection) -> SqlResult<()> {
    let tx = conn.unchecked_transaction()?;
    tx.execute_batch(
        r#"
        -- Current local session catalogue and encrypted audio metadata. These
        -- are supporting records for Notebook capture/import, not the removed
        -- v1 `sessions` or `task_queue` models.
        CREATE TABLE session_records (
            id             TEXT PRIMARY KEY,
            title          TEXT NOT NULL DEFAULT '',
            session_type   TEXT NOT NULL DEFAULT 'recording'
                                      CHECK(session_type IN ('recording', 'import')),
            status         TEXT NOT NULL DEFAULT 'recording'
                                      CHECK(status IN (
                                          'recording', 'completed', 'imported',
                                          'interrupted', 'failed'
                                      )),
            duration_ms    INTEGER NOT NULL DEFAULT 0 CHECK(duration_ms >= 0),
            created_at     TEXT NOT NULL DEFAULT (datetime('now')),
            deleted_at     TEXT
        );
        CREATE INDEX idx_session_records_active_created
            ON session_records(deleted_at, created_at DESC, id);

        CREATE TABLE session_meta (
            session_id            TEXT PRIMARY KEY,
            encrypted_path        TEXT,
            key_id                TEXT,
            tokens_json           TEXT,
            privacy_level         TEXT,
            sample_rate           INTEGER CHECK(sample_rate IS NULL OR sample_rate > 0),
            channels              INTEGER CHECK(channels IS NULL OR channels > 0),
            CHECK((encrypted_path IS NULL) = (key_id IS NULL))
        );

        CREATE TABLE audio_retention_chunks (
            session_id            TEXT NOT NULL,
            chunk_id              TEXT NOT NULL,
            start_ms              INTEGER NOT NULL CHECK(start_ms >= 0),
            end_ms                INTEGER NOT NULL CHECK(end_ms >= start_ms),
            local_path            TEXT NOT NULL,
            encrypted             INTEGER NOT NULL CHECK(encrypted IN (0, 1)),
            deleted               INTEGER NOT NULL DEFAULT 0 CHECK(deleted IN (0, 1)),
            retention_deadline_ms INTEGER NOT NULL,
            delete_error          TEXT,
            deleted_at_ms         INTEGER,
            PRIMARY KEY(session_id, chunk_id)
        );
        CREATE INDEX idx_audio_retention_chunks_session
            ON audio_retention_chunks(session_id, start_ms, chunk_id);
        CREATE INDEX idx_audio_retention_chunks_due
            ON audio_retention_chunks(deleted, retention_deadline_ms, session_id);

        CREATE VIRTUAL TABLE search_index USING fts5(
            session_id UNINDEXED,
            content,
            tokenize = 'unicode61'
        );

        -- Notebook is the sole product container. Recording Settings is a UI
        -- page over notebook_capture_profiles, never a fourth document row.
        CREATE TABLE notebooks (
            id          TEXT PRIMARY KEY,
            title       TEXT NOT NULL,
            created_at  TEXT NOT NULL,
            updated_at  TEXT NOT NULL,
            deleted_at  TEXT
        );
        CREATE INDEX idx_notebooks_updated
            ON notebooks(updated_at DESC, id);

        CREATE TABLE notebook_tabs (
            id            TEXT PRIMARY KEY,
            notebook_id   TEXT NOT NULL REFERENCES notebooks(id) ON DELETE CASCADE,
            builtin_kind  TEXT NOT NULL CHECK(builtin_kind IN (
                              'realtime_transcript',
                              'async_transcript',
                              'manual_note'
                          )),
            title         TEXT NOT NULL,
            doc_id        TEXT NOT NULL UNIQUE,
            position      INTEGER NOT NULL CHECK(position >= 0),
            created_at    TEXT NOT NULL,
            updated_at    TEXT NOT NULL,
            deleted_at    TEXT
        );
        CREATE UNIQUE INDEX idx_notebook_tabs_builtin_unique
            ON notebook_tabs(notebook_id, builtin_kind)
            WHERE deleted_at IS NULL;
        CREATE INDEX idx_notebook_tabs_notebook_position
            ON notebook_tabs(notebook_id, position, created_at, id);

        CREATE TABLE notebook_sessions (
            notebook_id  TEXT NOT NULL REFERENCES notebooks(id) ON DELETE CASCADE,
            session_id   TEXT NOT NULL,
            created_at   TEXT NOT NULL,
            PRIMARY KEY(notebook_id, session_id)
        );
        CREATE UNIQUE INDEX idx_notebook_sessions_session_unique
            ON notebook_sessions(session_id);

        CREATE TABLE notebook_session_projections (
            id             TEXT PRIMARY KEY,
            notebook_id    TEXT NOT NULL REFERENCES notebooks(id) ON DELETE CASCADE,
            tab_id         TEXT NOT NULL REFERENCES notebook_tabs(id) ON DELETE CASCADE,
            session_id     TEXT NOT NULL,
            section_title  TEXT,
            created_at     TEXT NOT NULL,
            updated_at     TEXT NOT NULL,
            deleted_at     TEXT,
            UNIQUE(tab_id, session_id)
        );
        CREATE INDEX idx_notebook_session_projections_tab
            ON notebook_session_projections(tab_id, created_at, id);
        CREATE INDEX idx_notebook_session_projections_notebook_session
            ON notebook_session_projections(notebook_id, session_id);

        -- Mutable next-run settings. Every remote-egress switch defaults off.
        CREATE TABLE notebook_capture_profiles (
            notebook_id                    TEXT PRIMARY KEY
                                                   REFERENCES notebooks(id) ON DELETE CASCADE,
            remote_realtime_enabled        INTEGER NOT NULL DEFAULT 0
                                                   CHECK(remote_realtime_enabled IN (0, 1)),
            capture_mode                   TEXT NOT NULL DEFAULT 'transcription_only'
                                                   CHECK(capture_mode IN (
                                                       'transcription_only',
                                                       'two_way',
                                                       'multilingual_one_way'
                                                   )),
            language_a                     TEXT NOT NULL DEFAULT 'en',
            language_b                     TEXT NOT NULL DEFAULT 'zh',
            left_language                  TEXT NOT NULL DEFAULT 'en',
            right_language                 TEXT NOT NULL DEFAULT 'zh',
            selected_languages_json        TEXT NOT NULL DEFAULT '["en","zh"]'
                                                   CHECK(
                                                       json_valid(selected_languages_json)
                                                       AND json_type(selected_languages_json) = 'array'
                                                   ),
            common_caption_language        TEXT,
            privacy_level                 TEXT NOT NULL DEFAULT 'standard'
                                                   CHECK(privacy_level IN (
                                                       'standard', 'high', 'maximum'
                                                   )),
            send_context_to_soniox         INTEGER NOT NULL DEFAULT 0
                                                   CHECK(send_context_to_soniox IN (0, 1)),
            revision                       INTEGER NOT NULL DEFAULT 0 CHECK(revision >= 0),
            created_at                     TEXT NOT NULL,
            updated_at                     TEXT NOT NULL,
            CHECK(language_a <> language_b),
            CHECK(left_language IN (language_a, language_b)),
            CHECK(right_language IN (language_a, language_b)),
            CHECK(left_language <> right_language),
            CHECK(capture_mode = 'transcription_only' OR remote_realtime_enabled = 1),
            CHECK(send_context_to_soniox = 0 OR remote_realtime_enabled = 1)
        );

        -- Human-assigned participant metadata. These records contain names
        -- only: no audio, embeddings, prototypes, or other voiceprints.
        CREATE TABLE participants (
            id            TEXT PRIMARY KEY,
            display_name  TEXT NOT NULL CHECK(length(trim(display_name)) > 0),
            created_at    TEXT NOT NULL,
            updated_at    TEXT NOT NULL
        );
        CREATE INDEX idx_participants_display_name
            ON participants(display_name COLLATE NOCASE, id);

        -- A provider label is anonymous and stable only inside one provider
        -- connection epoch. Cross-session identity exists solely when a user
        -- manually links this row to a participant.
        CREATE TABLE session_speakers (
            id                      TEXT PRIMARY KEY,
            session_id              TEXT NOT NULL
                                             REFERENCES notebook_capture_runs(session_id)
                                             ON DELETE CASCADE,
            provider_session_epoch  INTEGER NOT NULL CHECK(provider_session_epoch >= 0),
            provider                TEXT NOT NULL CHECK(length(trim(provider)) > 0),
            provider_label          TEXT NOT NULL CHECK(length(trim(provider_label)) > 0),
            local_display_name      TEXT
                                      CHECK(local_display_name IS NULL
                                            OR length(trim(local_display_name)) > 0),
            participant_id          TEXT REFERENCES participants(id) ON DELETE SET NULL,
            participant_linked_at   TEXT,
            created_at              TEXT NOT NULL,
            updated_at              TEXT NOT NULL,
            UNIQUE(session_id, provider_session_epoch, provider, provider_label)
        );
        CREATE INDEX idx_session_speakers_session_epoch
            ON session_speakers(session_id, provider_session_epoch, provider, provider_label);
        CREATE INDEX idx_session_speakers_participant
            ON session_speakers(participant_id, session_id, id);

        CREATE TABLE realtime_utterances (
            id                   TEXT PRIMARY KEY,
            session_id           TEXT NOT NULL
                                         REFERENCES notebook_capture_runs(session_id) ON DELETE CASCADE,
            sequence             INTEGER NOT NULL CHECK(sequence >= 0),
            session_speaker_id   TEXT
                                         REFERENCES session_speakers(id) ON DELETE SET NULL,
            source_language      TEXT NOT NULL,
            source_text          TEXT NOT NULL,
            source_start_ms      INTEGER CHECK(source_start_ms IS NULL OR source_start_ms >= 0),
            source_end_ms        INTEGER CHECK(source_end_ms IS NULL OR source_end_ms >= 0),
            translated_language  TEXT,
            translated_text      TEXT,
            revision             INTEGER NOT NULL DEFAULT 0 CHECK(revision >= 0),
            completion           TEXT NOT NULL CHECK(completion IN ('partial', 'complete')),
            alignment            TEXT NOT NULL CHECK(alignment IN (
                                     'paired', 'source_only', 'translation_pending',
                                     'outside_language_pair'
                                 )),
            created_at           TEXT NOT NULL,
            updated_at           TEXT NOT NULL,
            source_projection_revision INTEGER NOT NULL DEFAULT 0
                                               CHECK(source_projection_revision >= 0),
            UNIQUE(session_id, sequence),
            CHECK(source_end_ms IS NULL OR source_start_ms IS NULL
                  OR source_end_ms >= source_start_ms),
            CHECK((translated_language IS NULL) = (translated_text IS NULL))
        );
        CREATE INDEX idx_realtime_utterances_session_sequence
            ON realtime_utterances(session_id, sequence);
        CREATE INDEX idx_realtime_utterances_session_speaker
            ON realtime_utterances(session_speaker_id, session_id, sequence);
        CREATE UNIQUE INDEX idx_realtime_utterances_id_sequence
            ON realtime_utterances(id, sequence);

        CREATE TRIGGER realtime_utterances_require_realtime_provenance
        BEFORE INSERT ON realtime_utterances
        WHEN NOT EXISTS (
            SELECT 1 FROM notebook_capture_runs
            WHERE session_id = NEW.session_id
              AND realtime_provider_id = 'soniox'
              AND realtime_model_id = 'stt-rt-v5'
        )
        BEGIN
            SELECT RAISE(ABORT, 'realtime utterance requires provider provenance');
        END;

        CREATE TABLE realtime_utterance_variants (
            utterance_id  TEXT NOT NULL
                               REFERENCES realtime_utterances(id) ON DELETE CASCADE,
            language      TEXT NOT NULL CHECK(length(trim(language)) > 0),
            role          TEXT NOT NULL CHECK(role IN ('source', 'translation')),
            text          TEXT,
            state         TEXT NOT NULL
                               CHECK(state IN ('waiting', 'ready', 'failed', 'unavailable')),
            completion    TEXT CHECK(completion IS NULL
                                     OR completion IN ('partial', 'complete')),
            revision      INTEGER NOT NULL DEFAULT 0 CHECK(revision >= 0),
            created_at    TEXT NOT NULL,
            updated_at    TEXT NOT NULL,
            projection_revision INTEGER NOT NULL DEFAULT 0
                                        CHECK(projection_revision >= 0),
            PRIMARY KEY(utterance_id, language),
            CHECK(
                (state = 'ready' AND text IS NOT NULL AND completion IS NOT NULL)
                OR
                (state <> 'ready' AND text IS NULL AND completion IS NULL)
            )
        );
        CREATE UNIQUE INDEX idx_realtime_utterance_variants_language
            ON realtime_utterance_variants(utterance_id, lower(trim(language)));
        CREATE UNIQUE INDEX idx_realtime_utterance_variants_one_source
            ON realtime_utterance_variants(utterance_id)
            WHERE role = 'source';

        -- Provider output remains immutable machine evidence. User edits are
        -- overlaid for the UI and never rewritten into provider-owned rows.
        CREATE TABLE realtime_utterance_overrides (
            utterance_id               TEXT NOT NULL
                                              REFERENCES realtime_utterances(id)
                                              ON DELETE CASCADE,
            lane                       TEXT NOT NULL
                                              CHECK(lane IN ('source', 'translated')),
            lane_language              TEXT NOT NULL
                                              CHECK(length(trim(lane_language)) > 0),
            text                       TEXT NOT NULL,
            machine_utterance_revision INTEGER NOT NULL
                                              CHECK(machine_utterance_revision >= 0),
            machine_variant_revision   INTEGER NOT NULL
                                              CHECK(machine_variant_revision >= 0),
            edit_revision              INTEGER NOT NULL
                                              CHECK(edit_revision > 0),
            created_at                 TEXT NOT NULL,
            updated_at                 TEXT NOT NULL,
            PRIMARY KEY(utterance_id, lane_language)
        );

        -- One-way target streams are physically independent from the
        -- canonical timeline. Persist every auxiliary Partial/Final before
        -- correlation so process loss cannot erase an unbound provider fact.
        -- A withdrawn row is a durable tombstone; a binding is unique per
        -- canonical utterance/language lane.
        CREATE TABLE realtime_translation_inbox (
            session_id          TEXT NOT NULL
                                     REFERENCES notebook_capture_runs(session_id)
                                     ON DELETE CASCADE,
            lane_index          INTEGER NOT NULL CHECK(lane_index >= 0),
            group_epoch         INTEGER NOT NULL CHECK(group_epoch >= 0),
            provider_sequence   INTEGER NOT NULL CHECK(provider_sequence >= 0),
            target_language     TEXT NOT NULL CHECK(length(trim(target_language)) > 0),
            source_language     TEXT NOT NULL CHECK(length(trim(source_language)) > 0),
            source_text         TEXT NOT NULL,
            source_start_ms     INTEGER CHECK(source_start_ms IS NULL OR source_start_ms >= 0),
            source_end_ms       INTEGER CHECK(source_end_ms IS NULL OR source_end_ms >= 0),
            translated_text     TEXT,
            completion          TEXT CHECK(completion IS NULL
                                            OR completion IN ('partial', 'complete')),
            state               TEXT NOT NULL CHECK(state IN ('present', 'withdrawn')),
            revision            INTEGER NOT NULL DEFAULT 0 CHECK(revision >= 0),
            bound_utterance_id  TEXT,
            bound_sequence      INTEGER CHECK(bound_sequence IS NULL OR bound_sequence >= 0),
            created_at          TEXT NOT NULL,
            updated_at          TEXT NOT NULL,
            PRIMARY KEY(
                session_id, group_epoch, provider_sequence, target_language
            ),
            CHECK(source_end_ms IS NULL OR source_start_ms IS NULL
                  OR source_end_ms >= source_start_ms),
            CHECK(
                (state = 'present'
                    AND translated_text IS NOT NULL
                    AND completion IS NOT NULL)
                OR
                (state = 'withdrawn'
                    AND translated_text IS NULL
                    AND completion IS NULL)
            ),
            CHECK((bound_utterance_id IS NULL) = (bound_sequence IS NULL)),
            FOREIGN KEY(bound_utterance_id, bound_sequence)
                REFERENCES realtime_utterances(id, sequence)
                ON DELETE SET NULL
        );
        -- Deliberately not UNIQUE: one canonical language lane holds every
        -- auxiliary segment whose words belong to that row, concatenated in
        -- provider order. See migrate_v30_to_v31.
        CREATE INDEX idx_realtime_translation_inbox_bound_lane
            ON realtime_translation_inbox(bound_utterance_id, target_language)
            WHERE bound_utterance_id IS NOT NULL;
        CREATE INDEX idx_realtime_translation_inbox_unbound
            ON realtime_translation_inbox(
                session_id, group_epoch, provider_sequence, target_language
            )
            WHERE bound_utterance_id IS NULL;

        -- Encrypted Context Pack records. No plaintext Knowledge snapshot is
        -- represented by this schema.
        CREATE TABLE context_packs (
            id                 TEXT PRIMARY KEY,
            scope              TEXT NOT NULL CHECK(scope IN ('private', 'library')),
            owner_notebook_id  TEXT REFERENCES notebooks(id) ON DELETE CASCADE,
            title              TEXT NOT NULL,
            key_ref            TEXT NOT NULL UNIQUE,
            revision           INTEGER NOT NULL DEFAULT 0 CHECK(revision >= 0),
            created_at         TEXT NOT NULL,
            updated_at         TEXT NOT NULL,
            deleted_at         TEXT,
            CHECK((scope = 'private' AND owner_notebook_id IS NOT NULL)
                  OR (scope = 'library' AND owner_notebook_id IS NULL))
        );
        CREATE UNIQUE INDEX idx_context_packs_private_owner
            ON context_packs(owner_notebook_id)
            WHERE scope = 'private' AND deleted_at IS NULL;
        CREATE INDEX idx_context_packs_library
            ON context_packs(scope, created_at, id)
            WHERE deleted_at IS NULL;

        CREATE TABLE context_pack_sources (
            id                TEXT PRIMARY KEY,
            pack_id           TEXT NOT NULL REFERENCES context_packs(id) ON DELETE CASCADE,
            title             TEXT NOT NULL,
            format            TEXT NOT NULL CHECK(format IN (
                                  'text', 'markdown', 'translation_csv'
                              )),
            content_kind      TEXT NOT NULL CHECK(content_kind IN (
                                  'translation_terms', 'terms', 'general', 'text'
                              )),
            ciphertext        BLOB NOT NULL,
            plaintext_sha256  TEXT NOT NULL,
            plaintext_bytes   INTEGER NOT NULL CHECK(plaintext_bytes >= 0),
            metadata_json     TEXT NOT NULL DEFAULT '{}',
            trust_state       TEXT NOT NULL DEFAULT 'local_trusted'
                                      CHECK(trust_state IN ('local_trusted', 'untrusted')),
            revision          INTEGER NOT NULL DEFAULT 0 CHECK(revision >= 0),
            created_at        TEXT NOT NULL,
            updated_at        TEXT NOT NULL,
            deleted_at        TEXT,
            CHECK((format = 'translation_csv' AND content_kind = 'translation_terms')
                  OR (format <> 'translation_csv' AND content_kind <> 'translation_terms'))
        );
        CREATE INDEX idx_context_pack_sources_pack_order
            ON context_pack_sources(pack_id, created_at, id);

        CREATE TABLE notebook_context_pack_bindings (
            notebook_id  TEXT NOT NULL REFERENCES notebooks(id) ON DELETE CASCADE,
            pack_id      TEXT NOT NULL REFERENCES context_packs(id) ON DELETE CASCADE,
            position     INTEGER NOT NULL CHECK(position >= 0),
            created_at   TEXT NOT NULL,
            PRIMARY KEY(notebook_id, pack_id),
            UNIQUE(notebook_id, position)
        );
        CREATE INDEX idx_notebook_context_bindings_order
            ON notebook_context_pack_bindings(notebook_id, position, created_at, pack_id);

        CREATE TRIGGER context_binding_library_only_insert
        BEFORE INSERT ON notebook_context_pack_bindings
        BEGIN
            SELECT CASE WHEN NOT EXISTS (
                SELECT 1 FROM context_packs
                WHERE id = NEW.pack_id AND scope = 'library' AND deleted_at IS NULL
            ) THEN RAISE(ABORT, 'only active library Context Packs may be bound') END;
        END;

        CREATE TRIGGER context_binding_library_only_update
        BEFORE UPDATE OF pack_id ON notebook_context_pack_bindings
        BEGIN
            SELECT CASE WHEN NOT EXISTS (
                SELECT 1 FROM context_packs
                WHERE id = NEW.pack_id AND scope = 'library' AND deleted_at IS NULL
            ) THEN RAISE(ABORT, 'only active library Context Packs may be bound') END;
        END;

        -- A post-projection edit is a short-lived durable mutation receipt;
        -- the Loro document remains the editable source after commit.
        CREATE TABLE notebook_projection_mutations (
            id                        TEXT PRIMARY KEY,
            session_id                TEXT NOT NULL,
            utterance_id              TEXT NOT NULL
                                             REFERENCES realtime_utterances(id)
                                             ON DELETE CASCADE,
            lane                      TEXT NOT NULL
                                             CHECK(lane IN ('source', 'translated')),
            lane_language             TEXT NOT NULL
                                             CHECK(length(trim(lane_language)) > 0),
            expected_revision         INTEGER NOT NULL
                                             CHECK(expected_revision >= 0),
            expected_variant_revision INTEGER NOT NULL
                                             CHECK(expected_variant_revision >= 0),
            target_text               TEXT NOT NULL,
            state                     TEXT NOT NULL DEFAULT 'pending'
                                             CHECK(state = 'pending'),
            created_at                TEXT NOT NULL,
            updated_at                TEXT NOT NULL
        );
        CREATE INDEX idx_notebook_projection_mutations_session
            ON notebook_projection_mutations(session_id, created_at, id);
        CREATE UNIQUE INDEX idx_notebook_projection_mutations_utterance_language
            ON notebook_projection_mutations(
                utterance_id,
                lower(trim(lane_language))
            );

        -- The tombstone intentionally has no FK: it must survive deletion of
        -- all session-owned rows until file, key, task, and Loro cleanup ends.
        CREATE TABLE session_purge_jobs (
            session_id  TEXT PRIMARY KEY,
            plan_json   TEXT NOT NULL,
            phase       TEXT NOT NULL,
            last_error  TEXT,
            created_at  TEXT NOT NULL,
            updated_at  TEXT NOT NULL
        );
        CREATE INDEX idx_session_purge_jobs_updated
            ON session_purge_jobs(updated_at, session_id);

        CREATE TRIGGER session_meta_provider_tokens_immutable
        BEFORE UPDATE OF tokens_json ON session_meta
        WHEN NEW.tokens_json IS NOT OLD.tokens_json
             AND EXISTS (
                 SELECT 1 FROM notebook_capture_runs r
                 WHERE r.session_id = OLD.session_id
                   AND r.async_provider_output_sha256 IS NOT NULL
             )
        BEGIN
            SELECT RAISE(ABORT, 'capture provider authoritative tokens are immutable');
        END;

        "#,
    )?;
    tx.execute_batch(notebook_capture_runs_schema())?;
    tx.execute_batch(realtime_transcript_gaps_schema())?;
    tx.execute_batch(provider_remote_artifacts_schema())?;
    tx.pragma_update(None, "user_version", CURRENT_VERSION)?;
    tx.commit()?;
    tracing::info!("installed clean Zulangue schema v{CURRENT_VERSION}");
    Ok(())
}

/// 远端 provider 工件日志:post-stop 任务在调用 Soniox 异步文件 API 前落一行
/// claim,拿到远端 id 后回填,确认远端删除后整行移除。启动扫尾据此删掉
/// 崩溃遗留的远端文件/转录任务。像 session_purge_jobs 一样刻意不挂外键:
/// 行必须活过会话删除,直到远端收敛。
fn provider_remote_artifacts_schema() -> &'static str {
    r#"
        CREATE TABLE provider_remote_artifacts (
            task_id                 TEXT PRIMARY KEY,
            session_id              TEXT NOT NULL CHECK(length(trim(session_id)) > 0),
            provider_id             TEXT NOT NULL CHECK(provider_id = 'soniox'),
            client_reference_id     TEXT NOT NULL UNIQUE
                                         CHECK(length(trim(client_reference_id)) > 0),
            remote_file_id          TEXT,
            remote_transcription_id TEXT,
            created_at              TEXT NOT NULL,
            updated_at              TEXT NOT NULL
        );
    "#
}

/// `notebook_capture_runs` 的完整 schema(表 + 索引 + 自身触发器)。
///
/// v30 起 post-stop 允许 `stt-async-v5`(异步文件 API),同时保留
/// `stt-rt-v5` 让升级前落库的 restream 收据保持合法。全新安装与
/// v29→v30 重建迁移共用这一份定义。
fn notebook_capture_runs_schema() -> &'static str {
    r#"
        CREATE TABLE notebook_capture_runs (
            id                          TEXT PRIMARY KEY,
            notebook_id                 TEXT NOT NULL REFERENCES notebooks(id) ON DELETE CASCADE,
            session_id                  TEXT NOT NULL UNIQUE,
            profile_revision            INTEGER NOT NULL CHECK(profile_revision >= 0),
            profile_snapshot_json       TEXT NOT NULL,
            realtime_provider_id        TEXT,
            realtime_model_id           TEXT,
            post_stop_provider_id       TEXT,
            post_stop_model_id          TEXT,
            context_receipt_json        TEXT,
            context_applied_at          TEXT,
            context_snapshot_ciphertext BLOB,
            context_snapshot_key_ref    TEXT,
            context_snapshot_sha256     TEXT,
            capture_state               TEXT NOT NULL CHECK(capture_state IN (
                                            'recording', 'paused', 'draining', 'completed',
                                            'interrupted', 'failed'
                                        )),
            remote_health               TEXT NOT NULL DEFAULT 'off' CHECK(remote_health IN (
                                            'off', 'connecting', 'live', 'degraded', 'unavailable'
                                        )),
            projection_state            TEXT NOT NULL DEFAULT 'pending' CHECK(projection_state IN (
                                            'pending', 'projecting', 'ready', 'failed'
                                        )),
            async_task_state            TEXT NOT NULL DEFAULT 'none' CHECK(async_task_state IN (
                                            'none', 'pending', 'reserved', 'enqueued',
                                            'completed', 'failed'
                                        )),
            async_authorized_at_ms      INTEGER CHECK(
                                            async_authorized_at_ms IS NULL
                                            OR async_authorized_at_ms > 0
                                        ),
            async_language_hint         TEXT CHECK(
                                            async_language_hint IS NULL
                                            OR length(trim(async_language_hint)) > 0
                                        ),
            async_task_id               TEXT,
            async_task_payload_sha256   TEXT,
            async_projection_state      TEXT NOT NULL DEFAULT 'none' CHECK(
                                            async_projection_state IN (
                                                'none', 'pending', 'projecting', 'ready', 'failed'
                                            )
                                        ),
            async_provider_output_sha256 TEXT,
            async_provider_result_json   TEXT,
            async_provider_completed_at  TEXT,
            async_search_projection_state TEXT NOT NULL DEFAULT 'none' CHECK(
                                            async_search_projection_state IN (
                                                'none', 'pending', 'ready', 'failed'
                                            )
                                        ),
            provider_error_type         TEXT,
            provider_request_id         TEXT,
            audio_journal_path          TEXT,
            audio_path                  TEXT,
            audio_key_ref               TEXT,
            sample_rate                 INTEGER CHECK(sample_rate IS NULL OR sample_rate > 0),
            channels                    INTEGER CHECK(channels IS NULL OR channels > 0),
            captured_frames             INTEGER NOT NULL DEFAULT 0 CHECK(captured_frames >= 0),
            created_at                  TEXT NOT NULL,
            updated_at                  TEXT NOT NULL,
            completed_at                TEXT,
            realtime_loro_desired_revision INTEGER NOT NULL DEFAULT 0
                                                 CHECK(realtime_loro_desired_revision >= 0),
            realtime_loro_applied_revision INTEGER NOT NULL DEFAULT 0
                                                 CHECK(
                                                     realtime_loro_applied_revision >= 0
                                                     AND realtime_loro_applied_revision
                                                         <= realtime_loro_desired_revision
                                                 ),
            CHECK(
                (context_snapshot_ciphertext IS NULL
                    AND context_snapshot_key_ref IS NULL
                    AND context_snapshot_sha256 IS NULL)
                OR
                (context_snapshot_ciphertext IS NOT NULL
                    AND context_snapshot_key_ref IS NOT NULL
                    AND context_snapshot_sha256 IS NOT NULL)
            ),
            CHECK(
                (realtime_provider_id IS NULL AND realtime_model_id IS NULL)
                OR
                (realtime_provider_id IS NOT NULL AND realtime_model_id IS NOT NULL
                    AND realtime_provider_id = 'soniox'
                    AND realtime_model_id = 'stt-rt-v5')
            ),
            CHECK(
                (post_stop_provider_id IS NULL AND post_stop_model_id IS NULL)
                OR
                (post_stop_provider_id IS NOT NULL AND post_stop_model_id IS NOT NULL
                    AND post_stop_provider_id = 'soniox'
                    AND post_stop_model_id IN ('stt-rt-v5', 'stt-async-v5'))
            ),
            CHECK(
                context_applied_at IS NULL
                OR
                (realtime_provider_id IS NOT NULL
                    AND realtime_model_id IS NOT NULL
                    AND realtime_provider_id = 'soniox'
                    AND realtime_model_id = 'stt-rt-v5')
            ),
            CHECK(
                (async_task_state = 'none'
                    AND async_authorized_at_ms IS NULL
                    AND async_language_hint IS NULL
                    AND async_task_id IS NULL
                    AND async_task_payload_sha256 IS NULL)
                OR
                (async_task_state = 'pending'
                    AND async_authorized_at_ms IS NOT NULL
                    AND async_task_id IS NULL
                    AND async_task_payload_sha256 IS NULL)
                OR
                (async_task_state IN ('reserved', 'enqueued', 'completed', 'failed')
                    AND async_authorized_at_ms IS NOT NULL
                    AND async_task_id IS NOT NULL
                    AND length(trim(async_task_id)) > 0
                    AND async_task_payload_sha256 IS NOT NULL
                    AND length(async_task_payload_sha256) = 64
                    AND async_task_payload_sha256 NOT GLOB '*[^0-9a-f]*')
            ),
            CHECK(async_projection_state = 'none' OR async_task_state = 'completed'),
            CHECK(
                (async_provider_output_sha256 IS NULL
                    AND async_provider_result_json IS NULL
                    AND async_provider_completed_at IS NULL
                    AND async_search_projection_state = 'none')
                OR
                (async_provider_output_sha256 IS NOT NULL
                    AND length(async_provider_output_sha256) = 64
                    AND async_provider_output_sha256 NOT GLOB '*[^0-9a-f]*'
                    AND async_provider_result_json IS NOT NULL
                    AND async_provider_completed_at IS NOT NULL
                    AND async_search_projection_state IN ('pending', 'ready', 'failed'))
            ),
            CHECK(async_provider_output_sha256 IS NULL OR post_stop_provider_id IS NOT NULL)
        );
        CREATE INDEX idx_notebook_capture_runs_notebook_created
            ON notebook_capture_runs(notebook_id, created_at DESC, id);
        CREATE UNIQUE INDEX idx_notebook_capture_runs_single_active
            ON notebook_capture_runs((1))
            WHERE capture_state IN ('recording', 'paused', 'draining');

        CREATE TRIGGER notebook_capture_runs_async_receipt_insert
        BEFORE INSERT ON notebook_capture_runs
        WHEN NOT (
            (NEW.async_task_state = 'none'
                AND NEW.async_authorized_at_ms IS NULL
                AND NEW.async_language_hint IS NULL
                AND NEW.async_task_id IS NULL
                AND NEW.async_task_payload_sha256 IS NULL)
            OR
            (NEW.async_task_state = 'pending'
                AND NEW.async_authorized_at_ms IS NOT NULL
                AND NEW.async_task_id IS NULL
                AND NEW.async_task_payload_sha256 IS NULL)
            OR
            (NEW.async_task_state IN ('reserved', 'enqueued', 'completed', 'failed')
                AND NEW.async_authorized_at_ms IS NOT NULL
                AND NEW.async_task_id IS NOT NULL
                AND length(trim(NEW.async_task_id)) > 0
                AND NEW.async_task_payload_sha256 IS NOT NULL
                AND length(NEW.async_task_payload_sha256) = 64
                AND NEW.async_task_payload_sha256 NOT GLOB '*[^0-9a-f]*')
        )
        BEGIN
            SELECT RAISE(ABORT, 'invalid async task receipt');
        END;

        CREATE TRIGGER notebook_capture_runs_async_receipt_update
        BEFORE UPDATE OF async_task_state, async_authorized_at_ms, async_language_hint,
                         async_task_id, async_task_payload_sha256
        ON notebook_capture_runs
        WHEN NOT (
            (NEW.async_task_state = 'none'
                AND NEW.async_authorized_at_ms IS NULL
                AND NEW.async_language_hint IS NULL
                AND NEW.async_task_id IS NULL
                AND NEW.async_task_payload_sha256 IS NULL)
            OR
            (NEW.async_task_state = 'pending'
                AND NEW.async_authorized_at_ms IS NOT NULL
                AND NEW.async_task_id IS NULL
                AND NEW.async_task_payload_sha256 IS NULL)
            OR
            (NEW.async_task_state IN ('reserved', 'enqueued', 'completed', 'failed')
                AND NEW.async_authorized_at_ms IS NOT NULL
                AND NEW.async_task_id IS NOT NULL
                AND length(trim(NEW.async_task_id)) > 0
                AND NEW.async_task_payload_sha256 IS NOT NULL
                AND length(NEW.async_task_payload_sha256) = 64
                AND NEW.async_task_payload_sha256 NOT GLOB '*[^0-9a-f]*')
        )
        BEGIN
            SELECT RAISE(ABORT, 'invalid async task receipt');
        END;

        CREATE TRIGGER notebook_capture_runs_async_state_transition
        BEFORE UPDATE OF async_task_state ON notebook_capture_runs
        WHEN NOT (
            NEW.async_task_state = OLD.async_task_state
            OR (OLD.async_task_state = 'none'
                AND NEW.async_task_state = 'pending'
                AND NEW.async_authorized_at_ms IS NOT NULL)
            OR (OLD.async_task_state = 'pending' AND NEW.async_task_state = 'reserved')
            OR (OLD.async_task_state = 'reserved' AND NEW.async_task_state = 'enqueued')
            OR (OLD.async_task_state = 'enqueued'
                AND NEW.async_task_state IN ('completed', 'failed'))
        )
        BEGIN
            SELECT RAISE(ABORT, 'invalid async task state transition');
        END;

        CREATE TRIGGER notebook_capture_runs_async_authorization_immutable
        BEFORE UPDATE OF async_authorized_at_ms, async_language_hint
        ON notebook_capture_runs
        WHEN OLD.async_authorized_at_ms IS NOT NULL
             AND (
                 NEW.async_authorized_at_ms IS NOT OLD.async_authorized_at_ms
                 OR NEW.async_language_hint IS NOT OLD.async_language_hint
             )
        BEGIN
            SELECT RAISE(ABORT, 'async transcription authorization is immutable');
        END;

        CREATE TRIGGER notebook_capture_runs_async_projection_transition
        BEFORE UPDATE OF async_projection_state ON notebook_capture_runs
        WHEN NOT (
            NEW.async_projection_state = OLD.async_projection_state
            OR (OLD.async_projection_state = 'none'
                AND NEW.async_projection_state = 'pending'
                AND NEW.async_task_state = 'completed')
            OR (OLD.async_projection_state = 'pending'
                AND NEW.async_projection_state = 'projecting')
            OR (OLD.async_projection_state = 'projecting'
                AND NEW.async_projection_state IN ('ready', 'failed'))
            OR (OLD.async_projection_state = 'failed'
                AND NEW.async_projection_state = 'pending')
        )
        BEGIN
            SELECT RAISE(ABORT, 'invalid async projection state transition');
        END;

        CREATE TRIGGER notebook_capture_runs_async_identity_immutable
        BEFORE UPDATE OF async_task_id, async_task_payload_sha256 ON notebook_capture_runs
        WHEN OLD.async_task_state IN ('reserved', 'enqueued', 'completed', 'failed')
             AND (
                 NEW.async_task_id IS NOT OLD.async_task_id
                 OR NEW.async_task_payload_sha256 IS NOT OLD.async_task_payload_sha256
             )
        BEGIN
            SELECT RAISE(ABORT, 'async task receipt identity is immutable');
        END;

        CREATE TRIGGER notebook_capture_runs_provider_receipt_immutable
        BEFORE UPDATE OF async_provider_output_sha256, async_provider_result_json,
                         async_provider_completed_at
        ON notebook_capture_runs
        WHEN OLD.async_provider_output_sha256 IS NOT NULL
             AND (
                 NEW.async_provider_output_sha256 IS NOT OLD.async_provider_output_sha256
                 OR NEW.async_provider_result_json IS NOT OLD.async_provider_result_json
                 OR NEW.async_provider_completed_at IS NOT OLD.async_provider_completed_at
             )
        BEGIN
            SELECT RAISE(ABORT, 'capture provider success receipt is immutable');
        END;

        CREATE TRIGGER notebook_capture_runs_realtime_provenance_immutable
        BEFORE UPDATE OF realtime_provider_id, realtime_model_id
        ON notebook_capture_runs
        WHEN (OLD.realtime_provider_id IS NOT NULL OR OLD.realtime_model_id IS NOT NULL)
             AND (
                 NEW.realtime_provider_id IS NOT OLD.realtime_provider_id
                 OR NEW.realtime_model_id IS NOT OLD.realtime_model_id
             )
        BEGIN
            SELECT RAISE(ABORT, 'realtime provider provenance is immutable');
        END;

        CREATE TRIGGER notebook_capture_runs_post_stop_provenance_immutable
        BEFORE UPDATE OF post_stop_provider_id, post_stop_model_id
        ON notebook_capture_runs
        WHEN (OLD.post_stop_provider_id IS NOT NULL OR OLD.post_stop_model_id IS NOT NULL)
             AND (
                 NEW.post_stop_provider_id IS NOT OLD.post_stop_provider_id
                 OR NEW.post_stop_model_id IS NOT OLD.post_stop_model_id
             )
        BEGIN
            SELECT RAISE(ABORT, 'post-stop provider provenance is immutable');
        END;
    "#
}

/// v29 → v30:重建 `notebook_capture_runs`,把 post-stop 模型 CHECK 从
/// 仅 `stt-rt-v5` 放宽为 `stt-rt-v5` / `stt-async-v5`(SQLite 无法原地修改
/// CHECK,只能按官方 12 步流程重建)。
///
/// 同时清空"已认领 post-stop provenance 但没有 provider 成功收据"的未完成
/// 认领:这些任务升级后会用异步模型重新认领;不清空的话,不可变触发器会把
/// 它们永远卡死在旧 restream 模型上。已有收据的行保持原样,收据保持诚实。
fn migrate_v29_to_v30(conn: &Connection) -> SqlResult<()> {
    conn.pragma_update(None, "foreign_keys", "OFF")?;
    conn.pragma_update(None, "legacy_alter_table", "ON")?;
    let result = (|| {
        let tx = conn.unchecked_transaction()?;
        tx.execute_batch(
            "DROP TRIGGER notebook_capture_runs_async_receipt_insert;
             DROP TRIGGER notebook_capture_runs_async_receipt_update;
             DROP TRIGGER notebook_capture_runs_async_state_transition;
             DROP TRIGGER notebook_capture_runs_async_authorization_immutable;
             DROP TRIGGER notebook_capture_runs_async_projection_transition;
             DROP TRIGGER notebook_capture_runs_async_identity_immutable;
             DROP TRIGGER notebook_capture_runs_provider_receipt_immutable;
             DROP TRIGGER notebook_capture_runs_realtime_provenance_immutable;
             DROP TRIGGER notebook_capture_runs_post_stop_provenance_immutable;
             DROP INDEX idx_notebook_capture_runs_notebook_created;
             DROP INDEX idx_notebook_capture_runs_single_active;
             ALTER TABLE notebook_capture_runs RENAME TO notebook_capture_runs_v29_legacy;",
        )?;
        tx.execute_batch(notebook_capture_runs_schema())?;
        tx.execute(
            "INSERT INTO notebook_capture_runs (
                 id, notebook_id, session_id, profile_revision, profile_snapshot_json,
                 realtime_provider_id, realtime_model_id,
                 post_stop_provider_id, post_stop_model_id,
                 context_receipt_json, context_applied_at,
                 context_snapshot_ciphertext, context_snapshot_key_ref,
                 context_snapshot_sha256, capture_state, remote_health,
                 projection_state, async_task_state, async_authorized_at_ms,
                 async_language_hint, async_task_id, async_task_payload_sha256,
                 async_projection_state, async_provider_output_sha256,
                 async_provider_result_json, async_provider_completed_at,
                 async_search_projection_state, provider_error_type,
                 provider_request_id, audio_journal_path, audio_path, audio_key_ref,
                 sample_rate, channels, captured_frames, created_at, updated_at,
                 completed_at, realtime_loro_desired_revision,
                 realtime_loro_applied_revision
             )
             SELECT
                 id, notebook_id, session_id, profile_revision, profile_snapshot_json,
                 realtime_provider_id, realtime_model_id,
                 CASE WHEN async_provider_output_sha256 IS NULL THEN NULL
                      ELSE post_stop_provider_id END,
                 CASE WHEN async_provider_output_sha256 IS NULL THEN NULL
                      ELSE post_stop_model_id END,
                 context_receipt_json, context_applied_at,
                 context_snapshot_ciphertext, context_snapshot_key_ref,
                 context_snapshot_sha256, capture_state, remote_health,
                 projection_state, async_task_state, async_authorized_at_ms,
                 async_language_hint, async_task_id, async_task_payload_sha256,
                 async_projection_state, async_provider_output_sha256,
                 async_provider_result_json, async_provider_completed_at,
                 async_search_projection_state, provider_error_type,
                 provider_request_id, audio_journal_path, audio_path, audio_key_ref,
                 sample_rate, channels, captured_frames, created_at, updated_at,
                 completed_at, realtime_loro_desired_revision,
                 realtime_loro_applied_revision
             FROM notebook_capture_runs_v29_legacy",
            [],
        )?;
        tx.execute_batch("DROP TABLE notebook_capture_runs_v29_legacy;")?;
        tx.execute_batch(provider_remote_artifacts_schema())?;
        let violations: i64 =
            tx.query_row("SELECT count(*) FROM pragma_foreign_key_check", [], |row| {
                row.get(0)
            })?;
        if violations > 0 {
            return Err(rusqlite::Error::SqliteFailure(
                rusqlite::ffi::Error::new(rusqlite::ffi::SQLITE_CONSTRAINT),
                Some(format!(
                    "notebook_capture_runs rebuild left {violations} foreign key violations"
                )),
            ));
        }
        tx.pragma_update(None, "user_version", CURRENT_VERSION)?;
        tx.commit()?;
        tracing::info!("migrated Zulangue schema v{TRANSCRIPT_GAPS_VERSION} to v{CURRENT_VERSION}");
        Ok(())
    })();
    conn.pragma_update(None, "legacy_alter_table", "OFF")?;
    conn.pragma_update(None, "foreign_keys", "ON")?;
    result
}

/// v30 -> v31: one canonical language lane may hold several auxiliary segments.
///
/// The auxiliary translating connection ends a segment wherever it hears a
/// pause, which is routinely mid-row for the canonical connection. The unique
/// binding index made the first segment to arrive the only one that could ever
/// reach that row, so every later segment stayed durably unbound — measured at
/// roughly a third of the translated text in a long run. Dropping uniqueness
/// lets the store concatenate them in provider order instead.
///
/// Nothing is lost by relaxing this: the previously rejected segments are still
/// in the inbox with their text, and the repair pass binds them on next launch.
fn migrate_v30_to_v31(conn: &Connection) -> SqlResult<()> {
    let tx = conn.unchecked_transaction()?;
    tx.execute_batch(
        r#"
        DROP INDEX IF EXISTS idx_realtime_translation_inbox_bound_lane;
        CREATE INDEX idx_realtime_translation_inbox_bound_lane
            ON realtime_translation_inbox(bound_utterance_id, target_language)
            WHERE bound_utterance_id IS NOT NULL;
        "#,
    )?;
    tx.pragma_update(None, "user_version", CURRENT_VERSION)?;
    tx.commit()?;
    tracing::info!("migrated Zulangue schema v{REMOTE_ARTIFACTS_VERSION} to v{CURRENT_VERSION}");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{BuiltinNotebookTab, NotebookStore};
    use tempfile::TempDir;

    fn names(conn: &Connection, object_type: &str) -> Vec<String> {
        let mut stmt = conn
            .prepare(
                "SELECT name FROM sqlite_master
                 WHERE type = ?1 AND name NOT LIKE 'sqlite_%'
                 ORDER BY name",
            )
            .unwrap();
        stmt.query_map([object_type], |row| row.get::<_, String>(0))
            .unwrap()
            .collect::<Result<Vec<_>, _>>()
            .unwrap()
    }

    fn insert_notebook(conn: &Connection, id: &str) {
        conn.execute(
            "INSERT INTO notebooks (id, title, created_at, updated_at)
             VALUES (?1, 'Notebook', 't', 't')",
            [id],
        )
        .unwrap();
    }

    fn insert_run(conn: &Connection, id: &str, notebook_id: &str, state: &str) {
        conn.execute(
            "INSERT INTO notebook_capture_runs
             (id, notebook_id, session_id, profile_revision, profile_snapshot_json,
              capture_state, created_at, updated_at)
             VALUES (?1, ?2, ?3, 0, '{}', ?4, 't', 't')",
            rusqlite::params![id, notebook_id, format!("session-{id}"), state],
        )
        .unwrap();
    }

    fn downgrade_v27_to_v26(conn: &Connection) {
        conn.execute_batch(
            r#"
            DROP TABLE provider_remote_artifacts;
            DROP INDEX idx_realtime_transcript_gaps_pending;
            DROP TABLE realtime_transcript_gaps;
            DROP INDEX idx_realtime_translation_inbox_unbound;
            DROP INDEX idx_realtime_translation_inbox_bound_lane;
            DROP TABLE realtime_translation_inbox;
            DROP INDEX idx_realtime_utterances_id_sequence;

            DROP INDEX idx_notebook_projection_mutations_utterance_language;
            DROP INDEX idx_notebook_projection_mutations_session;
            ALTER TABLE notebook_projection_mutations
                RENAME TO notebook_projection_mutations_v27;
            CREATE TABLE notebook_projection_mutations (
                id                 TEXT PRIMARY KEY,
                session_id         TEXT NOT NULL,
                utterance_id       TEXT NOT NULL
                                          REFERENCES realtime_utterances(id) ON DELETE CASCADE,
                lane               TEXT NOT NULL CHECK(lane IN ('source', 'translated')),
                lane_language      TEXT NOT NULL CHECK(length(trim(lane_language)) > 0),
                expected_revision  INTEGER NOT NULL CHECK(expected_revision >= 0),
                target_text        TEXT NOT NULL,
                state              TEXT NOT NULL DEFAULT 'pending' CHECK(state = 'pending'),
                created_at         TEXT NOT NULL,
                updated_at         TEXT NOT NULL,
                UNIQUE(utterance_id)
            );
            INSERT INTO notebook_projection_mutations (
                id, session_id, utterance_id, lane, lane_language,
                expected_revision, target_text, state, created_at, updated_at
            )
            SELECT id, session_id, utterance_id, lane, lane_language,
                   expected_revision, target_text, state, created_at, updated_at
            FROM notebook_projection_mutations_v27;
            DROP TABLE notebook_projection_mutations_v27;
            CREATE INDEX idx_notebook_projection_mutations_session
                ON notebook_projection_mutations(session_id, created_at, id);

            DROP TABLE realtime_utterance_overrides;
            ALTER TABLE realtime_utterance_variants
                DROP COLUMN projection_revision;
            ALTER TABLE realtime_utterances
                DROP COLUMN source_projection_revision;
            ALTER TABLE notebook_capture_runs
                DROP COLUMN realtime_loro_applied_revision;
            ALTER TABLE notebook_capture_runs
                DROP COLUMN realtime_loro_desired_revision;
            PRAGMA user_version = 26;
            "#,
        )
        .unwrap();
        validate_v26_baseline(conn).unwrap();
    }

    #[test]
    fn migration_fresh_database_has_exact_v30_objects() {
        let conn = Connection::open_in_memory().unwrap();
        run_migrations(&conn).unwrap();

        assert_eq!(
            names(&conn, "table"),
            vec![
                "audio_retention_chunks",
                "context_pack_sources",
                "context_packs",
                "notebook_capture_profiles",
                "notebook_capture_runs",
                "notebook_context_pack_bindings",
                "notebook_projection_mutations",
                "notebook_session_projections",
                "notebook_sessions",
                "notebook_tabs",
                "notebooks",
                "participants",
                "provider_remote_artifacts",
                "realtime_transcript_gaps",
                "realtime_translation_inbox",
                "realtime_utterance_overrides",
                "realtime_utterance_variants",
                "realtime_utterances",
                "search_index",
                "search_index_config",
                "search_index_content",
                "search_index_data",
                "search_index_docsize",
                "search_index_idx",
                "session_meta",
                "session_purge_jobs",
                "session_records",
                "session_speakers",
            ]
        );
        assert_eq!(
            names(&conn, "index"),
            vec![
                "idx_audio_retention_chunks_due",
                "idx_audio_retention_chunks_session",
                "idx_context_pack_sources_pack_order",
                "idx_context_packs_library",
                "idx_context_packs_private_owner",
                "idx_notebook_capture_runs_notebook_created",
                "idx_notebook_capture_runs_single_active",
                "idx_notebook_context_bindings_order",
                "idx_notebook_projection_mutations_session",
                "idx_notebook_projection_mutations_utterance_language",
                "idx_notebook_session_projections_notebook_session",
                "idx_notebook_session_projections_tab",
                "idx_notebook_sessions_session_unique",
                "idx_notebook_tabs_builtin_unique",
                "idx_notebook_tabs_notebook_position",
                "idx_notebooks_updated",
                "idx_participants_display_name",
                "idx_realtime_transcript_gaps_pending",
                "idx_realtime_translation_inbox_bound_lane",
                "idx_realtime_translation_inbox_unbound",
                "idx_realtime_utterance_variants_language",
                "idx_realtime_utterance_variants_one_source",
                "idx_realtime_utterances_id_sequence",
                "idx_realtime_utterances_session_sequence",
                "idx_realtime_utterances_session_speaker",
                "idx_session_purge_jobs_updated",
                "idx_session_records_active_created",
                "idx_session_speakers_participant",
                "idx_session_speakers_session_epoch",
            ]
        );
        assert_eq!(
            names(&conn, "trigger"),
            vec![
                "context_binding_library_only_insert",
                "context_binding_library_only_update",
                "notebook_capture_runs_async_authorization_immutable",
                "notebook_capture_runs_async_identity_immutable",
                "notebook_capture_runs_async_projection_transition",
                "notebook_capture_runs_async_receipt_insert",
                "notebook_capture_runs_async_receipt_update",
                "notebook_capture_runs_async_state_transition",
                "notebook_capture_runs_post_stop_provenance_immutable",
                "notebook_capture_runs_provider_receipt_immutable",
                "notebook_capture_runs_realtime_provenance_immutable",
                "realtime_utterances_require_realtime_provenance",
                "session_meta_provider_tokens_immutable",
            ]
        );
        assert_eq!(
            conn.pragma_query_value(None, "user_version", |row| row.get::<_, i32>(0))
                .unwrap(),
            CURRENT_VERSION
        );
        let capture_profile_columns = conn
            .prepare("PRAGMA table_info(notebook_capture_profiles)")
            .unwrap()
            .query_map([], |row| row.get::<_, String>(1))
            .unwrap()
            .collect::<Result<Vec<_>, _>>()
            .unwrap();
        assert_eq!(
            capture_profile_columns,
            vec![
                "notebook_id",
                "remote_realtime_enabled",
                "capture_mode",
                "language_a",
                "language_b",
                "left_language",
                "right_language",
                "selected_languages_json",
                "common_caption_language",
                "privacy_level",
                "send_context_to_soniox",
                "revision",
                "created_at",
                "updated_at",
            ]
        );
        let capture_run_columns = conn
            .prepare("PRAGMA table_info(notebook_capture_runs)")
            .unwrap()
            .query_map([], |row| row.get::<_, String>(1))
            .unwrap()
            .collect::<Result<Vec<_>, _>>()
            .unwrap();
        assert_eq!(
            capture_run_columns,
            vec![
                "id",
                "notebook_id",
                "session_id",
                "profile_revision",
                "profile_snapshot_json",
                "realtime_provider_id",
                "realtime_model_id",
                "post_stop_provider_id",
                "post_stop_model_id",
                "context_receipt_json",
                "context_applied_at",
                "context_snapshot_ciphertext",
                "context_snapshot_key_ref",
                "context_snapshot_sha256",
                "capture_state",
                "remote_health",
                "projection_state",
                "async_task_state",
                "async_authorized_at_ms",
                "async_language_hint",
                "async_task_id",
                "async_task_payload_sha256",
                "async_projection_state",
                "async_provider_output_sha256",
                "async_provider_result_json",
                "async_provider_completed_at",
                "async_search_projection_state",
                "provider_error_type",
                "provider_request_id",
                "audio_journal_path",
                "audio_path",
                "audio_key_ref",
                "sample_rate",
                "channels",
                "captured_frames",
                "created_at",
                "updated_at",
                "completed_at",
                "realtime_loro_desired_revision",
                "realtime_loro_applied_revision",
            ]
        );

        let participant_columns = conn
            .prepare("PRAGMA table_info(participants)")
            .unwrap()
            .query_map([], |row| row.get::<_, String>(1))
            .unwrap()
            .collect::<Result<Vec<_>, _>>()
            .unwrap();
        assert_eq!(
            participant_columns,
            vec!["id", "display_name", "created_at", "updated_at"]
        );
        let session_speaker_columns = conn
            .prepare("PRAGMA table_info(session_speakers)")
            .unwrap()
            .query_map([], |row| row.get::<_, String>(1))
            .unwrap()
            .collect::<Result<Vec<_>, _>>()
            .unwrap();
        assert_eq!(
            session_speaker_columns,
            vec![
                "id",
                "session_id",
                "provider_session_epoch",
                "provider",
                "provider_label",
                "local_display_name",
                "participant_id",
                "participant_linked_at",
                "created_at",
                "updated_at",
            ]
        );
        let realtime_utterance_columns = conn
            .prepare("PRAGMA table_info(realtime_utterances)")
            .unwrap()
            .query_map([], |row| row.get::<_, String>(1))
            .unwrap()
            .collect::<Result<Vec<_>, _>>()
            .unwrap();
        assert!(realtime_utterance_columns
            .iter()
            .any(|column| column == "session_speaker_id"));
        assert!(realtime_utterance_columns
            .iter()
            .any(|column| column == "source_projection_revision"));
        let realtime_variant_columns = conn
            .prepare("PRAGMA table_info(realtime_utterance_variants)")
            .unwrap()
            .query_map([], |row| row.get::<_, String>(1))
            .unwrap()
            .collect::<Result<Vec<_>, _>>()
            .unwrap();
        assert_eq!(
            realtime_variant_columns,
            vec![
                "utterance_id",
                "language",
                "role",
                "text",
                "state",
                "completion",
                "revision",
                "created_at",
                "updated_at",
                "projection_revision",
            ]
        );
        let projection_mutation_columns = conn
            .prepare("PRAGMA table_info(notebook_projection_mutations)")
            .unwrap()
            .query_map([], |row| row.get::<_, String>(1))
            .unwrap()
            .collect::<Result<Vec<_>, _>>()
            .unwrap();
        assert!(projection_mutation_columns
            .iter()
            .any(|column| column == "lane_language"));
        assert!(projection_mutation_columns
            .iter()
            .any(|column| column == "expected_variant_revision"));
        let override_columns = conn
            .prepare("PRAGMA table_info(realtime_utterance_overrides)")
            .unwrap()
            .query_map([], |row| row.get::<_, String>(1))
            .unwrap()
            .collect::<Result<Vec<_>, _>>()
            .unwrap();
        assert_eq!(
            override_columns,
            vec![
                "utterance_id",
                "lane",
                "lane_language",
                "text",
                "machine_utterance_revision",
                "machine_variant_revision",
                "edit_revision",
                "created_at",
                "updated_at",
            ]
        );

        for column in participant_columns
            .iter()
            .chain(session_speaker_columns.iter())
        {
            let normalized = column.to_ascii_lowercase();
            assert!(
                !["voiceprint", "embedding", "prototype", "audio", "sample"]
                    .iter()
                    .any(|forbidden| normalized.contains(forbidden)),
                "speaker directory must not contain biometric field {column}"
            );
        }
    }

    #[test]
    fn migration_provider_provenance_pairs_are_fixed_immutable_and_guard_facts() {
        let conn = Connection::open_in_memory().unwrap();
        run_migrations(&conn).unwrap();
        insert_notebook(&conn, "provenance-notebook");
        insert_run(&conn, "provenance-run", "provenance-notebook", "recording");

        assert!(conn
            .execute(
                "UPDATE notebook_capture_runs SET realtime_provider_id = 'soniox'
                 WHERE id = 'provenance-run'",
                [],
            )
            .is_err());
        assert!(conn
            .execute(
                "UPDATE notebook_capture_runs
                 SET realtime_provider_id = 'soniox', realtime_model_id = 'stt-rt-v4'
                 WHERE id = 'provenance-run'",
                [],
            )
            .is_err());
        assert!(conn
            .execute(
                "INSERT INTO realtime_utterances
                 (id, session_id, sequence, source_language, source_text,
                  completion, alignment, created_at, updated_at)
                 VALUES ('utterance-before-claim', 'session-provenance-run', 0,
                         'en', 'blocked', 'complete', 'source_only', 't', 't')",
                [],
            )
            .is_err());
        assert!(conn
            .execute(
                "UPDATE notebook_capture_runs SET context_applied_at = 't'
                 WHERE id = 'provenance-run'",
                [],
            )
            .is_err());

        conn.execute(
            "UPDATE notebook_capture_runs
             SET realtime_provider_id = 'soniox', realtime_model_id = 'stt-rt-v5'
             WHERE id = 'provenance-run'",
            [],
        )
        .unwrap();
        conn.execute(
            "UPDATE notebook_capture_runs SET context_applied_at = 't'
             WHERE id = 'provenance-run'",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO realtime_utterances
             (id, session_id, sequence, source_language, source_text,
              completion, alignment, created_at, updated_at)
             VALUES ('utterance-after-claim', 'session-provenance-run', 0,
                     'en', 'accepted', 'complete', 'source_only', 't', 't')",
            [],
        )
        .unwrap();
        assert!(conn
            .execute(
                "UPDATE notebook_capture_runs SET realtime_model_id = 'stt-rt-v4'
                 WHERE id = 'provenance-run'",
                [],
            )
            .is_err());
        assert!(conn
            .execute(
                "UPDATE notebook_capture_runs
                 SET realtime_provider_id = NULL, realtime_model_id = NULL
                 WHERE id = 'provenance-run'",
                [],
            )
            .is_err());

        conn.execute(
            "UPDATE notebook_capture_runs
             SET post_stop_provider_id = 'soniox', post_stop_model_id = 'stt-rt-v5'
             WHERE id = 'provenance-run'",
            [],
        )
        .unwrap();
        assert!(conn
            .execute(
                "UPDATE notebook_capture_runs SET post_stop_provider_id = 'other'
                 WHERE id = 'provenance-run'",
                [],
            )
            .is_err());

        conn.execute(
            "INSERT INTO notebook_capture_runs
             (id, notebook_id, session_id, profile_revision, profile_snapshot_json,
              capture_state, async_task_state, async_authorized_at_ms,
              async_language_hint, created_at, updated_at)
             VALUES ('receipt-guard-run', 'provenance-notebook', 'receipt-guard-session',
                     0, '{}', 'completed', 'pending', 1, 'en', 't', 't')",
            [],
        )
        .unwrap();
        conn.execute(
            "UPDATE notebook_capture_runs
             SET async_task_state = 'reserved', async_task_id = 'stable-task',
                 async_task_payload_sha256 = ?1
             WHERE id = 'receipt-guard-run'",
            ["a".repeat(64)],
        )
        .unwrap();
        conn.execute(
            "UPDATE notebook_capture_runs SET async_task_state = 'enqueued'
             WHERE id = 'receipt-guard-run'",
            [],
        )
        .unwrap();
        assert!(conn
            .execute(
                "UPDATE notebook_capture_runs
                 SET async_provider_output_sha256 = ?1,
                     async_provider_result_json = '{}',
                     async_provider_completed_at = 't',
                     async_search_projection_state = 'pending'
                 WHERE id = 'receipt-guard-run'",
                ["b".repeat(64)],
            )
            .is_err());
        conn.execute(
            "UPDATE notebook_capture_runs
             SET post_stop_provider_id = 'soniox', post_stop_model_id = 'stt-rt-v5'
             WHERE id = 'receipt-guard-run'",
            [],
        )
        .unwrap();
        conn.execute(
            "UPDATE notebook_capture_runs
             SET async_provider_output_sha256 = ?1,
                 async_provider_result_json = '{}',
                 async_provider_completed_at = 't',
                 async_search_projection_state = 'pending'
             WHERE id = 'receipt-guard-run'",
            ["b".repeat(64)],
        )
        .unwrap();
    }

    #[test]
    fn migration_rejects_every_historical_or_future_nonzero_version() {
        for version in [1, 7, 21, 22, 30] {
            let conn = Connection::open_in_memory().unwrap();
            conn.pragma_update(None, "user_version", version).unwrap();
            let error = run_migrations(&conn).unwrap_err();
            assert!(error
                .to_string()
                .contains(&format!("unsupported schema {version}; reset required")));
            assert!(names(&conn, "table").is_empty());
        }
    }

    #[test]
    fn migration_rejects_unversioned_existing_objects_without_mutation() {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(
            "CREATE TABLE old_agent_events (id TEXT PRIMARY KEY);
             INSERT INTO old_agent_events (id) VALUES ('preserve-until-reset');",
        )
        .unwrap();

        let error = run_migrations(&conn).unwrap_err();
        assert!(error
            .to_string()
            .contains("unsupported schema 0; reset required"));
        let count: i64 = conn
            .query_row("SELECT COUNT(*) FROM old_agent_events", [], |row| {
                row.get(0)
            })
            .unwrap();
        assert_eq!(count, 1);
        assert_eq!(
            conn.pragma_query_value(None, "user_version", |row| row.get::<_, i32>(0))
                .unwrap(),
            0
        );
    }

    #[test]
    fn migration_v29_to_v30_relaxes_post_stop_model_and_clears_unfinished_claims() {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(
            "CREATE TABLE notebooks (
                 id TEXT PRIMARY KEY, title TEXT NOT NULL,
                 created_at TEXT NOT NULL, updated_at TEXT NOT NULL, deleted_at TEXT
             );",
        )
        .unwrap();
        // v29 的表只在 post-stop CHECK 文本上不同:从共享 schema 反推出旧约束。
        let v29_schema = notebook_capture_runs_schema()
            .replace("IN ('stt-rt-v5', 'stt-async-v5')", "= 'stt-rt-v5'");
        assert_ne!(v29_schema, notebook_capture_runs_schema());
        conn.execute_batch(&v29_schema).unwrap();
        insert_notebook(&conn, "v30-notebook");

        let receipt_sha = "a".repeat(64);
        let payload_sha = "b".repeat(64);
        conn.execute(
            "INSERT INTO notebook_capture_runs
             (id, notebook_id, session_id, profile_revision, profile_snapshot_json,
              post_stop_provider_id, post_stop_model_id, capture_state,
              async_task_state, async_authorized_at_ms, async_task_id,
              async_task_payload_sha256, async_provider_output_sha256,
              async_provider_result_json, async_provider_completed_at,
              async_search_projection_state, created_at, updated_at)
             VALUES ('run-legacy-receipt', 'v30-notebook', 'session-legacy-receipt',
                     0, '{}', 'soniox', 'stt-rt-v5', 'completed',
                     'completed', 1, 'task-legacy', ?1, ?2, '{}', 't', 'ready',
                     't', 't')",
            rusqlite::params![payload_sha, receipt_sha],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO notebook_capture_runs
             (id, notebook_id, session_id, profile_revision, profile_snapshot_json,
              post_stop_provider_id, post_stop_model_id, capture_state,
              async_task_state, async_authorized_at_ms, async_task_id,
              async_task_payload_sha256, created_at, updated_at)
             VALUES ('run-unfinished-claim', 'v30-notebook', 'session-unfinished',
                     0, '{}', 'soniox', 'stt-rt-v5', 'completed',
                     'failed', 1, 'task-unfinished', ?1, 't', 't')",
            rusqlite::params![payload_sha],
        )
        .unwrap();
        conn.pragma_update(None, "user_version", TRANSCRIPT_GAPS_VERSION)
            .unwrap();

        migrate_v29_to_v30(&conn).unwrap();

        assert_eq!(
            conn.pragma_query_value(None, "user_version", |row| row.get::<_, i32>(0))
                .unwrap(),
            CURRENT_VERSION
        );
        // 已有 provider 成功收据的行保持旧 restream provenance,收据保持诚实。
        let (legacy_model, legacy_sha): (Option<String>, Option<String>) = conn
            .query_row(
                "SELECT post_stop_model_id, async_provider_output_sha256
                 FROM notebook_capture_runs WHERE id = 'run-legacy-receipt'",
                [],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap();
        assert_eq!(legacy_model.as_deref(), Some("stt-rt-v5"));
        assert_eq!(legacy_sha.as_deref(), Some(receipt_sha.as_str()));
        // 未完成的认领被清空,升级后可以用异步模型重新认领。
        let unfinished_model: Option<String> = conn
            .query_row(
                "SELECT post_stop_model_id FROM notebook_capture_runs
                 WHERE id = 'run-unfinished-claim'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(unfinished_model, None);
        conn.execute(
            "UPDATE notebook_capture_runs
             SET post_stop_provider_id = 'soniox', post_stop_model_id = 'stt-async-v5'
             WHERE id = 'run-unfinished-claim'",
            [],
        )
        .unwrap();
        assert!(conn
            .execute(
                "UPDATE notebook_capture_runs
                 SET post_stop_provider_id = 'soniox', post_stop_model_id = 'stt-async-v4'
                 WHERE id = 'run-unfinished-claim'",
                [],
            )
            .is_err());
    }

    #[test]
    fn migration_rejects_incomplete_database_claiming_the_current_schema() {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute("CREATE TABLE notebooks (id TEXT PRIMARY KEY)", [])
            .unwrap();
        conn.pragma_update(None, "user_version", CURRENT_VERSION)
            .unwrap();

        let error = run_migrations(&conn).unwrap_err();
        assert!(
            error
                .to_string()
                .contains(&format!("unsupported schema {CURRENT_VERSION}; reset required")),
            "a database stamped v{CURRENT_VERSION} must be reported as v{CURRENT_VERSION}, got: {error}"
        );
    }

    /// v31 的实质变化只在一条索引的唯一性上,所以对象名清单认不出它。一个盖着
    /// v31 戳、索引却还是 UNIQUE 的库(v30 迁移中途断电就会留下这个形状)必须被
    /// 拒绝,而不是当成合法的当前库放行。
    #[test]
    fn migration_rejects_current_schema_whose_inbox_index_is_still_unique() {
        let conn = Connection::open_in_memory().unwrap();
        run_migrations(&conn).unwrap();

        conn.execute_batch(
            r#"
            DROP INDEX idx_realtime_translation_inbox_bound_lane;
            CREATE UNIQUE INDEX idx_realtime_translation_inbox_bound_lane
                ON realtime_translation_inbox(bound_utterance_id, target_language)
                WHERE bound_utterance_id IS NOT NULL;
            "#,
        )
        .unwrap();

        let error = run_migrations(&conn).unwrap_err();
        assert!(
            error.to_string().contains(&format!(
                "unsupported schema {CURRENT_VERSION}; reset required"
            )),
            "a v{CURRENT_VERSION} database must not keep the v30 UNIQUE inbox index, got: {error}"
        );
    }

    #[test]
    fn migration_v29_is_idempotent() {
        let conn = Connection::open_in_memory().unwrap();
        run_migrations(&conn).unwrap();
        let tables = names(&conn, "table");
        let triggers = names(&conn, "trigger");
        run_migrations(&conn).unwrap();
        assert_eq!(names(&conn, "table"), tables);
        assert_eq!(names(&conn, "trigger"), triggers);
    }

    #[test]
    fn migration_v26_to_v27_preserves_machine_facts_and_lane_cas() {
        let conn = Connection::open_in_memory().unwrap();
        run_migrations(&conn).unwrap();
        downgrade_v27_to_v26(&conn);

        insert_notebook(&conn, "v26-notebook");
        insert_run(&conn, "v26-run", "v26-notebook", "recording");
        conn.execute(
            "UPDATE notebook_capture_runs
             SET realtime_provider_id = 'soniox', realtime_model_id = 'stt-rt-v5'
             WHERE id = 'v26-run'",
            [],
        )
        .unwrap();
        conn.execute_batch(
            "INSERT INTO realtime_utterances (
                 id, session_id, sequence, source_language, source_text,
                 translated_language, translated_text, revision,
                 completion, alignment, created_at, updated_at
             ) VALUES (
                 'v26-utterance', 'session-v26-run', 0, 'en', 'hello',
                 'ZH-Hant', '你好', 4, 'complete', 'paired', 'created', 'updated'
             );
             INSERT INTO realtime_utterance_variants (
                 utterance_id, language, role, text, state, completion,
                 revision, created_at, updated_at
             ) VALUES
                 ('v26-utterance', 'en', 'source', 'hello', 'ready',
                  'complete', 4, 'created', 'updated'),
                 ('v26-utterance', 'ZH-Hant', 'translation', '你好', 'ready',
                  'complete', 7, 'created', 'updated');
             INSERT INTO notebook_projection_mutations (
                 id, session_id, utterance_id, lane, lane_language,
                 expected_revision, target_text, state, created_at, updated_at
             ) VALUES (
                 'v26-mutation', 'session-v26-run', 'v26-utterance',
                 'translated', ' ZH-Hant ', 4, '您好', 'pending', 'created', 'updated'
             );",
        )
        .unwrap();
        for (run_id, session_id) in [
            ("v26-translation-only-run", "session-v26-translation-only"),
            ("v26-partial-only-run", "session-v26-partial-only"),
        ] {
            insert_run(&conn, run_id, "v26-notebook", "completed");
            conn.execute(
                "UPDATE notebook_capture_runs
                 SET session_id = ?1,
                     realtime_provider_id = 'soniox',
                     realtime_model_id = 'stt-rt-v5'
                 WHERE id = ?2",
                rusqlite::params![session_id, run_id],
            )
            .unwrap();
        }
        conn.execute_batch(
            "INSERT INTO realtime_utterances (
                 id, session_id, sequence, source_language, source_text,
                 revision, completion, alignment, created_at, updated_at
             ) VALUES
                 ('v26-translation-only-utterance',
                  'session-v26-translation-only', 0, 'en', 'partial',
                  0, 'partial', 'translation_pending', 'created', 'updated'),
                 ('v26-partial-only-utterance',
                  'session-v26-partial-only', 0, 'en', 'partial',
                  0, 'partial', 'source_only', 'created', 'updated');
             INSERT INTO realtime_utterance_variants (
                 utterance_id, language, role, text, state, completion,
                 revision, created_at, updated_at
             ) VALUES
                 ('v26-translation-only-utterance', 'en', 'source',
                  'partial', 'ready', 'partial', 0, 'created', 'updated'),
                 ('v26-translation-only-utterance', 'zh', 'translation',
                  '最终译文', 'ready', 'complete', 0, 'created', 'updated'),
                 ('v26-partial-only-utterance', 'en', 'source',
                  'partial', 'ready', 'partial', 0, 'created', 'updated');",
        )
        .unwrap();

        run_migrations(&conn).unwrap();

        assert_eq!(
            conn.query_row(
                "SELECT source_language, translated_language,
                        source_text, translated_text,
                        source_projection_revision
                 FROM realtime_utterances WHERE id = 'v26-utterance'",
                [],
                |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, Option<String>>(1)?,
                        row.get::<_, String>(2)?,
                        row.get::<_, Option<String>>(3)?,
                        row.get::<_, i64>(4)?,
                    ))
                },
            )
            .unwrap(),
            (
                "en".to_string(),
                Some("zh".to_string()),
                "hello".to_string(),
                Some("你好".to_string()),
                1,
            )
        );
        assert_eq!(
            conn.query_row(
                "SELECT language, projection_revision
                 FROM realtime_utterance_variants
                 WHERE utterance_id = 'v26-utterance' AND role = 'translation'",
                [],
                |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?)),
            )
            .unwrap(),
            ("zh".to_string(), 1)
        );
        assert_eq!(
            conn.query_row(
                "SELECT realtime_loro_desired_revision,
                        realtime_loro_applied_revision
                 FROM notebook_capture_runs WHERE id = 'v26-run'",
                [],
                |row| Ok((row.get::<_, i64>(0)?, row.get::<_, i64>(1)?)),
            )
            .unwrap(),
            (1, 0),
            "pre-v27 Finals must be conservatively scheduled for one recovery projection"
        );
        assert_eq!(
            conn.query_row(
                "SELECT realtime_loro_desired_revision,
                        realtime_loro_applied_revision
                 FROM notebook_capture_runs
                 WHERE id = 'v26-translation-only-run'",
                [],
                |row| Ok((row.get::<_, i64>(0)?, row.get::<_, i64>(1)?)),
            )
            .unwrap(),
            (1, 0),
            "a translation Final must schedule recovery even while source is partial"
        );
        assert_eq!(
            conn.query_row(
                "SELECT realtime_loro_desired_revision,
                        realtime_loro_applied_revision
                 FROM notebook_capture_runs
                 WHERE id = 'v26-partial-only-run'",
                [],
                |row| Ok((row.get::<_, i64>(0)?, row.get::<_, i64>(1)?)),
            )
            .unwrap(),
            (0, 0),
            "partial-only history must remain SQLite-only"
        );
        assert_eq!(
            conn.query_row(
                "SELECT lane_language, expected_revision,
                        expected_variant_revision
                 FROM notebook_projection_mutations WHERE id = 'v26-mutation'",
                [],
                |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, i64>(1)?,
                        row.get::<_, i64>(2)?,
                    ))
                },
            )
            .unwrap(),
            ("zh".to_string(), 0, 7),
            "v26 aggregate expected revision must migrate to the v27 lane edit baseline"
        );
        assert_eq!(
            conn.query_row(
                "SELECT COUNT(*) FROM realtime_utterance_overrides",
                [],
                |row| row.get::<_, i64>(0),
            )
            .unwrap(),
            0
        );
        validate_v30_baseline(&conn).unwrap();
    }

    #[test]
    fn migration_v26_to_v27_rejects_primary_language_collisions_without_mutation() {
        let conn = Connection::open_in_memory().unwrap();
        run_migrations(&conn).unwrap();
        downgrade_v27_to_v26(&conn);

        insert_notebook(&conn, "primary-collision-notebook");
        insert_run(
            &conn,
            "primary-collision-run",
            "primary-collision-notebook",
            "recording",
        );
        conn.execute(
            "UPDATE notebook_capture_runs
             SET realtime_provider_id = 'soniox',
                 realtime_model_id = 'stt-rt-v5'
             WHERE id = 'primary-collision-run'",
            [],
        )
        .unwrap();
        conn.execute_batch(
            "INSERT INTO realtime_utterances (
                 id, session_id, sequence, source_language, source_text,
                 revision, completion, alignment, created_at, updated_at
             ) VALUES (
                 'primary-collision-utterance',
                 'session-primary-collision-run',
                 0, 'th', 'ข้อความ', 0, 'partial', 'translation_pending',
                 'created', 'updated'
             );
             INSERT INTO realtime_utterance_variants (
                 utterance_id, language, role, text, state, completion,
                 revision, created_at, updated_at
             ) VALUES
                 ('primary-collision-utterance', 'en-US', 'translation',
                  'color', 'ready', 'partial', 0, 'created', 'updated'),
                 ('primary-collision-utterance', 'en-GB', 'translation',
                  'colour', 'ready', 'partial', 0, 'created', 'updated');",
        )
        .unwrap();

        let error = run_migrations(&conn).unwrap_err();
        assert!(error
            .to_string()
            .contains("unsupported schema 26; reset required"));
        assert_eq!(
            conn.pragma_query_value(None, "user_version", |row| row.get::<_, i32>(0))
                .unwrap(),
            MULTILINGUAL_VERSION
        );
        assert_eq!(
            conn.query_row(
                "SELECT COUNT(*) FROM pragma_table_info('notebook_capture_runs')
                 WHERE name = 'realtime_loro_desired_revision'",
                [],
                |row| row.get::<_, i64>(0),
            )
            .unwrap(),
            0
        );
        assert_eq!(
            conn.query_row(
                "SELECT COUNT(*) FROM pragma_table_info('realtime_utterance_variants')
                 WHERE name = 'projection_revision'",
                [],
                |row| row.get::<_, i64>(0),
            )
            .unwrap(),
            0
        );
        assert_eq!(
            conn.query_row(
                "SELECT COUNT(*) FROM realtime_utterance_variants
                 WHERE utterance_id = 'primary-collision-utterance'",
                [],
                |row| row.get::<_, i64>(0),
            )
            .unwrap(),
            2
        );
        validate_v26_baseline(&conn).unwrap();
    }

    #[test]
    fn migration_v23_to_v27_preserves_existing_utterances() {
        let conn = Connection::open_in_memory().unwrap();
        run_migrations(&conn).unwrap();
        downgrade_v27_to_v26(&conn);

        // Reconstruct the supported v23 shape from the fresh v27
        // baseline, then seed data that must survive the in-place migration.
        conn.execute_batch(
            "ALTER TABLE notebook_projection_mutations DROP COLUMN lane_language;
             DROP TABLE realtime_utterance_variants;
             ALTER TABLE notebook_capture_profiles DROP COLUMN common_caption_language;
             ALTER TABLE notebook_capture_profiles DROP COLUMN selected_languages_json;
             DROP INDEX idx_realtime_utterances_session_speaker;
             ALTER TABLE realtime_utterances DROP COLUMN session_speaker_id;
             DROP TABLE session_speakers;
             DROP TABLE participants;
             PRAGMA user_version = 23;",
        )
        .unwrap();
        validate_v23_baseline(&conn).unwrap();

        insert_notebook(&conn, "migration-notebook");
        insert_run(&conn, "migration-run", "migration-notebook", "recording");
        conn.execute(
            "UPDATE notebook_capture_runs
             SET realtime_provider_id = 'soniox', realtime_model_id = 'stt-rt-v5'
             WHERE id = 'migration-run'",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO realtime_utterances
             (id, session_id, sequence, source_language, source_text,
              translated_language, translated_text,
              completion, alignment, created_at, updated_at)
             VALUES ('migration-utterance', 'session-migration-run', 0, 'th',
                     'สวัสดี', 'zh', '你好', 'complete', 'paired', 't', 't')",
            [],
        )
        .unwrap();

        run_migrations(&conn).unwrap();

        assert_eq!(
            conn.pragma_query_value(None, "user_version", |row| row.get::<_, i32>(0))
                .unwrap(),
            CURRENT_VERSION
        );
        let (text, speaker): (String, Option<String>) = conn
            .query_row(
                "SELECT source_text, session_speaker_id
                 FROM realtime_utterances WHERE id = 'migration-utterance'",
                [],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap();
        assert_eq!(text, "สวัสดี");
        assert_eq!(speaker, None);
        let variants = conn
            .prepare(
                "SELECT language, role, text, state, completion
                 FROM realtime_utterance_variants
                 WHERE utterance_id = 'migration-utterance'
                 ORDER BY role, language",
            )
            .unwrap()
            .query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, Option<String>>(2)?,
                    row.get::<_, String>(3)?,
                    row.get::<_, Option<String>>(4)?,
                ))
            })
            .unwrap()
            .collect::<Result<Vec<_>, _>>()
            .unwrap();
        assert_eq!(
            variants,
            vec![
                (
                    "th".to_string(),
                    "source".to_string(),
                    Some("สวัสดี".to_string()),
                    "ready".to_string(),
                    Some("complete".to_string()),
                ),
                (
                    "zh".to_string(),
                    "translation".to_string(),
                    Some("你好".to_string()),
                    "ready".to_string(),
                    Some("complete".to_string()),
                ),
            ]
        );
        validate_v30_baseline(&conn).unwrap();
    }

    #[test]
    fn migration_v24_to_v27_derives_selected_languages_from_legacy_pair() {
        let conn = Connection::open_in_memory().unwrap();
        run_migrations(&conn).unwrap();
        downgrade_v27_to_v26(&conn);
        conn.execute_batch(
            "ALTER TABLE notebook_projection_mutations DROP COLUMN lane_language;
             DROP TABLE realtime_utterance_variants;
             ALTER TABLE notebook_capture_profiles DROP COLUMN common_caption_language;
             ALTER TABLE notebook_capture_profiles DROP COLUMN selected_languages_json;
             PRAGMA user_version = 24;",
        )
        .unwrap();
        validate_v24_baseline(&conn).unwrap();

        insert_notebook(&conn, "profile-migration-notebook");
        conn.execute(
            "INSERT INTO notebook_capture_profiles (
                notebook_id, remote_realtime_enabled, capture_mode,
                language_a, language_b, left_language, right_language,
                privacy_level, send_context_to_soniox, revision, created_at, updated_at
             ) VALUES (?1, 1, 'two_way', 'th', 'ja', 'th', 'ja',
                       'standard', 0, 7, 'created', 'updated')",
            ["profile-migration-notebook"],
        )
        .unwrap();

        run_migrations(&conn).unwrap();

        let (selected, common, revision): (String, Option<String>, i64) = conn
            .query_row(
                "SELECT selected_languages_json, common_caption_language, revision
                 FROM notebook_capture_profiles WHERE notebook_id = ?1",
                ["profile-migration-notebook"],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .unwrap();
        assert_eq!(selected, r#"["th","ja"]"#);
        assert_eq!(common, None);
        assert_eq!(revision, 7);
        validate_v30_baseline(&conn).unwrap();
    }

    #[test]
    fn migration_v25_to_v27_backfills_variants_and_preserves_private_capture_data() {
        let conn = Connection::open_in_memory().unwrap();
        run_migrations(&conn).unwrap();
        downgrade_v27_to_v26(&conn);
        conn.execute_batch(
            "ALTER TABLE notebook_projection_mutations DROP COLUMN lane_language;
             DROP TABLE realtime_utterance_variants;
             PRAGMA user_version = 25;",
        )
        .unwrap();
        validate_v25_baseline(&conn).unwrap();

        insert_notebook(&conn, "v25-notebook");
        conn.execute(
            "INSERT INTO notebook_capture_profiles (
                notebook_id, remote_realtime_enabled, capture_mode,
                language_a, language_b, left_language, right_language,
                selected_languages_json, common_caption_language,
                privacy_level, send_context_to_soniox, revision, created_at, updated_at
             ) VALUES (?1, 1, 'multilingual_one_way',
                       'zh', 'th', 'zh', 'th', '[\"zh\",\"th\",\"en\"]', 'zh',
                       'standard', 0, 9, 'profile-created', 'profile-updated')",
            ["v25-notebook"],
        )
        .unwrap();
        insert_run(&conn, "v25-run", "v25-notebook", "recording");
        let snapshot = r#"{"selected_languages":["zh","th","en"],"opaque":"keep"}"#;
        conn.execute(
            "UPDATE notebook_capture_runs
             SET profile_snapshot_json = ?1,
                 realtime_provider_id = 'soniox', realtime_model_id = 'stt-rt-v5'
             WHERE id = 'v25-run'",
            [snapshot],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO realtime_utterances (
                id, session_id, sequence, source_language, source_text,
                translated_language, translated_text, revision, completion, alignment,
                created_at, updated_at
             ) VALUES ('v25-utterance', 'session-v25-run', 3, 'zh', '原文',
                       'th', 'คำแปล', 4, 'complete', 'paired',
                       'utterance-created', 'utterance-updated')",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO notebook_projection_mutations (
                id, session_id, utterance_id, lane, expected_revision,
                target_text, state, created_at, updated_at
             ) VALUES ('v25-mutation', 'session-v25-run', 'v25-utterance',
                       'translated', 4, 'แก้ไข', 'pending',
                       'mutation-created', 'mutation-updated')",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO session_meta (
                session_id, encrypted_path, key_id, tokens_json, privacy_level,
                sample_rate, channels
             ) VALUES ('session-v25-run', '/private/audio.enc', 'key-v25',
                       '[{\"text\":\"原文\"}]', 'maximum', 16000, 1)",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO audio_retention_chunks (
                session_id, chunk_id, start_ms, end_ms, local_path,
                encrypted, deleted, retention_deadline_ms
             ) VALUES ('session-v25-run', 'chunk-1', 0, 1000,
                       '/private/chunk.enc', 1, 0, 999999)",
            [],
        )
        .unwrap();

        run_migrations(&conn).unwrap();

        assert_eq!(
            conn.pragma_query_value(None, "user_version", |row| row.get::<_, i32>(0))
                .unwrap(),
            CURRENT_VERSION
        );
        assert_eq!(
            conn.query_row(
                "SELECT profile_snapshot_json FROM notebook_capture_runs
                 WHERE id = 'v25-run'",
                [],
                |row| row.get::<_, String>(0),
            )
            .unwrap(),
            snapshot
        );
        assert_eq!(
            conn.query_row(
                "SELECT common_caption_language FROM notebook_capture_profiles
                 WHERE notebook_id = 'v25-notebook'",
                [],
                |row| row.get::<_, Option<String>>(0),
            )
            .unwrap(),
            None
        );
        assert_eq!(
            conn.query_row(
                "SELECT encrypted_path, key_id, tokens_json FROM session_meta
                 WHERE session_id = 'session-v25-run'",
                [],
                |row| {
                    Ok((
                        row.get::<_, Option<String>>(0)?,
                        row.get::<_, Option<String>>(1)?,
                        row.get::<_, Option<String>>(2)?,
                    ))
                },
            )
            .unwrap(),
            (
                Some("/private/audio.enc".to_string()),
                Some("key-v25".to_string()),
                Some("[{\"text\":\"原文\"}]".to_string()),
            )
        );
        assert_eq!(
            conn.query_row(
                "SELECT local_path FROM audio_retention_chunks
                 WHERE session_id = 'session-v25-run' AND chunk_id = 'chunk-1'",
                [],
                |row| row.get::<_, String>(0),
            )
            .unwrap(),
            "/private/chunk.enc"
        );
        assert_eq!(
            conn.query_row(
                "SELECT lane_language FROM notebook_projection_mutations
                 WHERE id = 'v25-mutation'",
                [],
                |row| row.get::<_, String>(0),
            )
            .unwrap(),
            "th"
        );
        assert_eq!(
            conn.query_row(
                "SELECT COUNT(*) FROM realtime_utterance_variants
                 WHERE utterance_id = 'v25-utterance' AND state = 'ready'",
                [],
                |row| row.get::<_, i64>(0),
            )
            .unwrap(),
            2
        );
        assert!(conn
            .prepare("SELECT session_id FROM realtime_translation_inbox LIMIT 0")
            .is_ok());
        validate_v30_baseline(&conn).unwrap();
    }

    #[test]
    fn current_schema_retires_legacy_common_caption_profile_state_idempotently() {
        let conn = Connection::open_in_memory().unwrap();
        run_migrations(&conn).unwrap();
        insert_notebook(&conn, "equal-lanes-notebook");
        conn.execute(
            "INSERT INTO notebook_capture_profiles (
                notebook_id, remote_realtime_enabled, capture_mode,
                language_a, language_b, left_language, right_language,
                selected_languages_json, common_caption_language,
                privacy_level, send_context_to_soniox, revision, created_at, updated_at
             ) VALUES (?1, 1, 'multilingual_one_way',
                       'zh', 'th', 'zh', 'th', '[\"zh\",\"th\",\"en\"]', 'zh',
                       'standard', 0, 4, 'profile-created', 'profile-updated')",
            ["equal-lanes-notebook"],
        )
        .unwrap();

        run_migrations(&conn).unwrap();
        run_migrations(&conn).unwrap();

        assert_eq!(
            conn.query_row(
                "SELECT common_caption_language FROM notebook_capture_profiles
                 WHERE notebook_id = 'equal-lanes-notebook'",
                [],
                |row| row.get::<_, Option<String>>(0),
            )
            .unwrap(),
            None
        );
        assert_eq!(
            conn.query_row(
                "SELECT revision FROM notebook_capture_profiles
                 WHERE notebook_id = 'equal-lanes-notebook'",
                [],
                |row| row.get::<_, i64>(0),
            )
            .unwrap(),
            4
        );
        validate_v30_baseline(&conn).unwrap();
    }

    #[test]
    fn migration_v25_to_v27_rolls_back_on_case_insensitive_language_collision() {
        let conn = Connection::open_in_memory().unwrap();
        run_migrations(&conn).unwrap();
        downgrade_v27_to_v26(&conn);
        conn.execute_batch(
            "ALTER TABLE notebook_projection_mutations DROP COLUMN lane_language;
             DROP TABLE realtime_utterance_variants;
             PRAGMA user_version = 25;",
        )
        .unwrap();
        insert_notebook(&conn, "collision-notebook");
        insert_run(&conn, "collision-run", "collision-notebook", "recording");
        conn.execute(
            "UPDATE notebook_capture_runs
             SET realtime_provider_id = 'soniox', realtime_model_id = 'stt-rt-v5'
             WHERE id = 'collision-run'",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO realtime_utterances (
                id, session_id, sequence, source_language, source_text,
                translated_language, translated_text, completion, alignment,
                created_at, updated_at
             ) VALUES ('collision-utterance', 'session-collision-run', 0,
                       'zh', '原文', 'ZH', 'translation',
                       'complete', 'paired', 't', 't')",
            [],
        )
        .unwrap();

        assert!(run_migrations(&conn).is_err());
        assert_eq!(
            conn.pragma_query_value(None, "user_version", |row| row.get::<_, i32>(0))
                .unwrap(),
            SELECTED_LANGUAGES_VERSION
        );
        assert_eq!(
            conn.query_row(
                "SELECT COUNT(*) FROM sqlite_schema
                 WHERE type = 'table' AND name = 'realtime_utterance_variants'",
                [],
                |row| row.get::<_, i64>(0),
            )
            .unwrap(),
            0
        );
        assert_eq!(
            conn.query_row(
                "SELECT source_text, translated_text FROM realtime_utterances
                 WHERE id = 'collision-utterance'",
                [],
                |row| Ok((row.get::<_, String>(0)?, row.get::<_, Option<String>>(1)?)),
            )
            .unwrap(),
            ("原文".to_string(), Some("translation".to_string()))
        );
        validate_v25_baseline(&conn).unwrap();
    }

    #[test]
    fn migration_notebook_tabs_are_exactly_the_three_builtin_kinds() {
        let temp = TempDir::new().unwrap();
        let db_path = temp.path().join("tabs.db");
        let store = NotebookStore::new(&db_path).unwrap();
        let notebook = store.create_notebook(Some("Field Notes")).unwrap();
        let tabs = store.list_tabs(&notebook.id).unwrap();
        assert_eq!(
            tabs.into_iter()
                .map(|tab| tab.builtin_kind)
                .collect::<Vec<_>>(),
            vec![
                BuiltinNotebookTab::RealtimeTranscript,
                BuiltinNotebookTab::AsyncTranscript,
                BuiltinNotebookTab::ManualNote,
            ]
        );

        let conn = Connection::open(db_path).unwrap();
        let columns = conn
            .prepare("PRAGMA table_info(notebook_tabs)")
            .unwrap()
            .query_map([], |row| row.get::<_, String>(1))
            .unwrap()
            .collect::<Result<Vec<_>, _>>()
            .unwrap();
        assert_eq!(
            columns,
            vec![
                "id",
                "notebook_id",
                "builtin_kind",
                "title",
                "doc_id",
                "position",
                "created_at",
                "updated_at",
                "deleted_at",
            ]
        );
        assert!(conn
            .execute(
                "INSERT INTO notebook_tabs
                 (id, notebook_id, builtin_kind, title, doc_id, position, created_at, updated_at)
                 VALUES ('invalid', ?1, 'custom', 'Invalid', 'invalid-doc', 3, 't', 't')",
                [&notebook.id],
            )
            .is_err());
    }

    #[test]
    fn migration_capture_privacy_defaults_are_local_only() {
        let conn = Connection::open_in_memory().unwrap();
        run_migrations(&conn).unwrap();
        insert_notebook(&conn, "privacy-notebook");
        conn.execute(
            "INSERT INTO notebook_capture_profiles (notebook_id, created_at, updated_at)
             VALUES ('privacy-notebook', 't', 't')",
            [],
        )
        .unwrap();

        let defaults = conn
            .query_row(
                "SELECT remote_realtime_enabled, capture_mode,
                        privacy_level, send_context_to_soniox
                 FROM notebook_capture_profiles WHERE notebook_id = 'privacy-notebook'",
                [],
                |row| {
                    Ok((
                        row.get::<_, bool>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, String>(2)?,
                        row.get::<_, bool>(3)?,
                    ))
                },
            )
            .unwrap();
        assert_eq!(
            defaults,
            (false, "transcription_only".into(), "standard".into(), false)
        );
        assert!(conn
            .execute(
                "UPDATE notebook_capture_profiles
                 SET privacy_level = 'unknown'
                 WHERE notebook_id = 'privacy-notebook'",
                [],
            )
            .is_err());
        assert!(conn
            .execute(
                "UPDATE notebook_capture_profiles
                 SET capture_mode = 'two_way', remote_realtime_enabled = 0
                 WHERE notebook_id = 'privacy-notebook'",
                [],
            )
            .is_err());
        assert!(conn
            .execute(
                "UPDATE notebook_capture_profiles
                 SET send_context_to_soniox = 1, remote_realtime_enabled = 0
                 WHERE notebook_id = 'privacy-notebook'",
                [],
            )
            .is_err());
    }

    #[test]
    fn migration_session_catalog_rejects_retired_types_and_states() {
        let conn = Connection::open_in_memory().unwrap();
        run_migrations(&conn).unwrap();
        assert!(conn
            .execute(
                "INSERT INTO session_records (id, session_type, status)
                 VALUES ('event-session', 'event', 'recording')",
                [],
            )
            .is_err());
        assert!(conn
            .execute(
                "INSERT INTO session_records (id, session_type, status)
                 VALUES ('overlay-session', 'overlay', 'running')",
                [],
            )
            .is_err());
    }

    #[test]
    fn migration_async_receipt_triggers_enforce_the_state_machine() {
        let conn = Connection::open_in_memory().unwrap();
        run_migrations(&conn).unwrap();
        insert_notebook(&conn, "async-notebook");
        insert_run(&conn, "pending", "async-notebook", "completed");

        assert!(conn
            .execute(
                "UPDATE notebook_capture_runs
                 SET async_task_state = 'pending'
                 WHERE id = 'pending'",
                [],
            )
            .is_err());
        conn.execute(
            "UPDATE notebook_capture_runs
             SET async_task_state = 'pending', async_authorized_at_ms = 123,
                 async_language_hint = 'en'
             WHERE id = 'pending'",
            [],
        )
        .unwrap();
        assert!(conn
            .execute(
                "UPDATE notebook_capture_runs SET async_authorized_at_ms = 124
                 WHERE id = 'pending'",
                [],
            )
            .is_err());
        assert!(conn
            .execute(
                "UPDATE notebook_capture_runs SET async_language_hint = 'zh'
                 WHERE id = 'pending'",
                [],
            )
            .is_err());
        assert!(conn
            .execute(
                "UPDATE notebook_capture_runs SET async_task_state = 'none'
                 WHERE id = 'pending'",
                [],
            )
            .is_err());

        assert!(conn
            .execute(
                "INSERT INTO notebook_capture_runs
                 (id, notebook_id, session_id, profile_revision, profile_snapshot_json,
                  capture_state, async_task_state, created_at, updated_at)
                 VALUES ('pending-without-authorization', 'async-notebook',
                         'session-pending-without-authorization', 0, '{}',
                         'completed', 'pending', 't', 't')",
                [],
            )
            .is_err());

        let digest = "a".repeat(64);
        conn.execute(
            "UPDATE notebook_capture_runs
             SET async_task_state = 'reserved', async_task_id = 'task-1',
                 async_task_payload_sha256 = ?1
             WHERE id = 'pending'",
            [&digest],
        )
        .unwrap();
        assert!(conn
            .execute(
                "UPDATE notebook_capture_runs SET async_task_id = 'task-2' WHERE id = 'pending'",
                [],
            )
            .is_err());
        conn.execute(
            "UPDATE notebook_capture_runs SET async_task_state = 'enqueued' WHERE id = 'pending'",
            [],
        )
        .unwrap();
        conn.execute(
            "UPDATE notebook_capture_runs SET async_task_state = 'completed' WHERE id = 'pending'",
            [],
        )
        .unwrap();
        assert!(conn
            .execute(
                "UPDATE notebook_capture_runs SET async_task_state = 'failed' WHERE id = 'pending'",
                [],
            )
            .is_err());

        insert_run(&conn, "failed", "async-notebook", "completed");
        conn.execute(
            "UPDATE notebook_capture_runs
             SET async_task_state = 'pending', async_authorized_at_ms = 456
             WHERE id = 'failed'",
            [],
        )
        .unwrap();
        conn.execute(
            "UPDATE notebook_capture_runs
             SET async_task_state = 'reserved', async_task_id = 'task-failed',
                 async_task_payload_sha256 = ?1
             WHERE id = 'failed'",
            [&digest],
        )
        .unwrap();
        conn.execute(
            "UPDATE notebook_capture_runs SET async_task_state = 'enqueued'
             WHERE id = 'failed'",
            [],
        )
        .unwrap();
        conn.execute(
            "UPDATE notebook_capture_runs SET async_task_state = 'failed'
             WHERE id = 'failed'",
            [],
        )
        .unwrap();
        assert!(conn
            .execute(
                "UPDATE notebook_capture_runs SET async_task_state = 'pending'
                 WHERE id = 'failed'",
                [],
            )
            .is_err());

        assert!(conn
            .execute(
                "INSERT INTO notebook_capture_runs
                 (id, notebook_id, session_id, profile_revision, profile_snapshot_json,
                  capture_state, async_task_state, created_at, updated_at)
                 VALUES ('bad-receipt', 'async-notebook', 'bad-session', 0, '{}',
                         'completed', 'enqueued', 't', 't')",
                [],
            )
            .is_err());
    }

    #[test]
    fn migration_only_allows_one_active_capture() {
        let conn = Connection::open_in_memory().unwrap();
        run_migrations(&conn).unwrap();
        insert_notebook(&conn, "active-notebook");
        insert_run(&conn, "active-a", "active-notebook", "recording");
        assert!(conn
            .execute(
                "INSERT INTO notebook_capture_runs
                 (id, notebook_id, session_id, profile_revision, profile_snapshot_json,
                  capture_state, created_at, updated_at)
                 VALUES ('active-b', 'active-notebook', 'session-active-b', 0, '{}',
                         'paused', 't', 't')",
                [],
            )
            .is_err());
    }

    #[test]
    fn migration_context_binding_trigger_accepts_only_active_library_packs() {
        let conn = Connection::open_in_memory().unwrap();
        run_migrations(&conn).unwrap();
        insert_notebook(&conn, "context-notebook");
        conn.execute(
            "INSERT INTO context_packs
             (id, scope, owner_notebook_id, title, key_ref, created_at, updated_at)
             VALUES ('private-pack', 'private', 'context-notebook', 'Private',
                     'private-key', 't', 't')",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO context_packs
             (id, scope, title, key_ref, created_at, updated_at)
             VALUES ('library-pack', 'library', 'Library', 'library-key', 't', 't')",
            [],
        )
        .unwrap();

        assert!(conn
            .execute(
                "INSERT INTO notebook_context_pack_bindings
                 (notebook_id, pack_id, position, created_at)
                 VALUES ('context-notebook', 'private-pack', 0, 't')",
                [],
            )
            .is_err());
        conn.execute(
            "INSERT INTO notebook_context_pack_bindings
             (notebook_id, pack_id, position, created_at)
             VALUES ('context-notebook', 'library-pack', 0, 't')",
            [],
        )
        .unwrap();
        assert!(conn
            .execute(
                "UPDATE notebook_context_pack_bindings
                 SET pack_id = 'private-pack'
                 WHERE notebook_id = 'context-notebook' AND pack_id = 'library-pack'",
                [],
            )
            .is_err());
    }
}
