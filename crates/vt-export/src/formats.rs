//! md/txt/srt/vtt 导出格式
//! 权威：D5 §13

/// 导出数据
pub struct ExportData {
    pub title: String,
    pub transcript: ExportTranscript,
    pub summary: Option<String>,
}

/// Transcript fact source selected by the Rust core.
///
/// Post-recording transcription owns timestamped provider tokens. Realtime
/// Notebook capture owns ordered utterances plus the immutable language order
/// copied into the capture run. Keeping the distinction here prevents an
/// untimestamped translation lane from being turned into synthetic subtitles.
pub enum ExportTranscript {
    AsyncTokens(Vec<ExportToken>),
    /// Legacy one- or two-language export shape. Keeping this variant intact
    /// preserves the existing bilingual column behavior for callers that
    /// construct exports directly.
    NotebookCapture {
        left_language: String,
        right_language: Option<String>,
        utterances: Vec<ExportUtterance>,
    },
    /// Ordered language columns frozen into a 3+ language capture run.
    ///
    /// Empty cells mean that no text exists for that language; they are not
    /// synthesized translations. `common_caption_language` is retained only
    /// so older callers and stored profiles remain readable. It has no display
    /// or routing semantics.
    NotebookCaptureLanguageColumns {
        language_columns: Vec<String>,
        common_caption_language: Option<String>,
        utterances: Vec<ExportUtterance>,
    },
}

/// 导出 token
pub struct ExportToken {
    pub text: String,
    pub start_ms: u64,
    pub end_ms: u64,
}

/// One persisted realtime utterance. Translation timestamps intentionally do
/// not exist: Soniox v5 does not provide a 1:1 timed translation alignment.
pub struct ExportUtterance {
    pub source_language: String,
    pub source_text: String,
    pub source_start_ms: Option<u64>,
    pub source_end_ms: Option<u64>,
    pub translated_language: Option<String>,
    pub translated_text: Option<String>,
    /// Ready translations beyond the legacy single translated lane.
    pub language_variants: Vec<ExportLanguageVariant>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ExportLanguageVariant {
    pub language: String,
    pub text: String,
}

/// Human-readable transcript facts prepared for clipboard formatting.
///
/// `language_columns` is the immutable language order selected for the run.
/// It controls line order only; the formatter never creates text for an empty
/// language lane.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ClipboardTranscript {
    pub title: Option<String>,
    pub language_columns: Vec<String>,
    pub utterances: Vec<ClipboardUtterance>,
}

/// One clipboard paragraph with an optional timestamp and speaker label.
///
/// Source and translation remain separate facts here so the formatter can
/// preserve both without presenting either one as more authoritative.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ClipboardUtterance {
    pub start_ms: Option<u64>,
    pub speaker_name: Option<String>,
    pub source_language: String,
    pub source_text: String,
    pub translated_language: Option<String>,
    pub translated_text: Option<String>,
    pub language_variants: Vec<ExportLanguageVariant>,
}

#[derive(Debug, thiserror::Error)]
pub enum ExportError {
    #[error("export failed: {0}")]
    Failed(String),
}

fn format_time_srt(ms: u64) -> String {
    let hours = ms / 3_600_000;
    let minutes = (ms % 3_600_000) / 60_000;
    let seconds = (ms % 60_000) / 1_000;
    let millis = ms % 1_000;
    format!("{hours:02}:{minutes:02}:{seconds:02},{millis:03}")
}

fn format_time_vtt(ms: u64) -> String {
    let hours = ms / 3_600_000;
    let minutes = (ms % 3_600_000) / 60_000;
    let seconds = (ms % 60_000) / 1_000;
    let millis = ms % 1_000;
    format!("{hours:02}:{minutes:02}:{seconds:02}.{millis:03}")
}

/// Format transcript facts for pasting into notes, chat, or a document.
///
/// Within each paragraph, selected languages follow `language_columns`.
/// Real facts in unselected or unknown languages follow afterward in their
/// original source/translation order. Empty facts and empty lanes are omitted.
pub fn export_clipboard_text(data: &ClipboardTranscript) -> String {
    let mut paragraphs = Vec::new();

    if let Some(title) = data
        .title
        .as_deref()
        .map(str::trim)
        .filter(|title| !title.is_empty())
    {
        paragraphs.push(txt_cell(title));
    }

    for utterance in &data.utterances {
        let language_lines = clipboard_language_lines(utterance, &data.language_columns);
        if language_lines.is_empty() {
            continue;
        }

        let mut paragraph = Vec::new();
        let timestamp = utterance
            .start_ms
            .map(format_time_vtt)
            .map(|timestamp| format!("[{timestamp}]"));
        let speaker = utterance
            .speaker_name
            .as_deref()
            .map(str::trim)
            .filter(|speaker| !speaker.is_empty())
            .map(txt_cell);
        match (timestamp, speaker) {
            (Some(timestamp), Some(speaker)) => paragraph.push(format!("{timestamp} {speaker}")),
            (Some(timestamp), None) => paragraph.push(timestamp),
            (None, Some(speaker)) => paragraph.push(speaker),
            (None, None) => {}
        }
        paragraph.extend(language_lines);
        paragraphs.push(paragraph.join("\n"));
    }

    paragraphs.join("\n\n")
}

fn clipboard_language_lines(
    utterance: &ClipboardUtterance,
    language_columns: &[String],
) -> Vec<String> {
    let export_utterance = ExportUtterance {
        source_language: utterance.source_language.clone(),
        source_text: utterance.source_text.clone(),
        source_start_ms: utterance.start_ms,
        source_end_ms: None,
        translated_language: utterance.translated_language.clone(),
        translated_text: utterance.translated_text.clone(),
        language_variants: utterance.language_variants.clone(),
    };
    let mut facts = utterance_facts(&export_utterance)
        .into_iter()
        .map(|fact| (fact.language, fact.text, false))
        .collect::<Vec<_>>();

    let mut lines = Vec::with_capacity(facts.len());
    for column in language_columns
        .iter()
        .map(String::as_str)
        .filter(|column| !column.trim().is_empty())
    {
        for (language, text, emitted) in &mut facts {
            if !*emitted && same_language(language, column) {
                lines.push(format!(
                    "{}: {}",
                    txt_cell(display_language(column)),
                    txt_cell(text)
                ));
                *emitted = true;
            }
        }
    }
    for (language, text, emitted) in facts {
        if !emitted {
            lines.push(format!(
                "{}: {}",
                txt_cell(display_language(&language)),
                txt_cell(&text)
            ));
        }
    }
    lines
}

/// Markdown 导出
pub fn export_markdown(data: &ExportData) -> Result<String, ExportError> {
    let mut out = String::new();

    out.push_str(&format!("# {}\n\n", data.title));

    out.push_str("## 转录\n\n");

    match &data.transcript {
        ExportTranscript::AsyncTokens(tokens) => {
            for token in tokens {
                let time = format_time_vtt(token.start_ms);
                out.push_str(&format!("[{time}] {}\n\n", token.text));
            }
        }
        ExportTranscript::NotebookCapture {
            left_language,
            right_language: Some(right_language),
            utterances,
        } => {
            out.push_str(&format!(
                "| {} | {} |\n| --- | --- |\n",
                markdown_cell(left_language),
                markdown_cell(right_language)
            ));
            let mut outside_pair = Vec::new();
            for utterance in utterances {
                match fixed_language_row(utterance, left_language, right_language) {
                    Some((left, right)) => out.push_str(&format!(
                        "| {} | {} |\n",
                        markdown_cell(&left),
                        markdown_cell(&right)
                    )),
                    None => outside_pair.push(utterance),
                }
            }
            out.push('\n');
            if !outside_pair.is_empty() {
                out.push_str("### 其他语言\n\n");
                for utterance in outside_pair {
                    out.push_str(&format!(
                        "- **{}**: {}\n",
                        markdown_cell(&utterance.source_language),
                        markdown_cell(&utterance.source_text)
                    ));
                }
                out.push('\n');
            }
        }
        ExportTranscript::NotebookCapture {
            left_language,
            right_language: None,
            utterances,
        } => {
            for utterance in utterances {
                let time = utterance
                    .source_start_ms
                    .map(format_time_vtt)
                    .map(|value| format!("[{value}] "))
                    .unwrap_or_default();
                out.push_str(&format!(
                    "{time}**{}**: {}\n\n",
                    markdown_cell(if utterance.source_language.is_empty() {
                        left_language
                    } else {
                        &utterance.source_language
                    }),
                    markdown_cell(&utterance.source_text)
                ));
            }
        }
        ExportTranscript::NotebookCaptureLanguageColumns {
            language_columns,
            common_caption_language: _,
            utterances,
        } => {
            if !language_columns.is_empty() {
                let headers = language_columns
                    .iter()
                    .map(|language| markdown_cell(language))
                    .collect::<Vec<_>>()
                    .join(" | ");
                let separators = std::iter::repeat_n("---", language_columns.len())
                    .collect::<Vec<_>>()
                    .join(" | ");
                out.push_str(&format!("| {headers} |\n| {separators} |\n"));
                for utterance in utterances {
                    if let Some(cells) = ordered_language_row(utterance, language_columns) {
                        let cells = cells
                            .iter()
                            .map(|cell| markdown_cell(cell))
                            .collect::<Vec<_>>()
                            .join(" | ");
                        out.push_str(&format!("| {cells} |\n"));
                    }
                }
                out.push('\n');
            }

            if utterances
                .iter()
                .any(|utterance| has_unrepresented_fact(utterance, language_columns))
            {
                out.push_str("### 其他语言内容\n\n");
                for utterance in utterances {
                    append_unrepresented_markdown(&mut out, utterance, language_columns);
                }
                out.push('\n');
            }
        }
    }

    if let Some(summary) = &data.summary {
        out.push_str("## 总结\n\n");
        out.push_str(summary);
        out.push('\n');
    }

    Ok(out)
}

/// 纯文本导出
pub fn export_txt(data: &ExportData) -> Result<String, ExportError> {
    let mut out = String::new();

    out.push_str(&data.title);
    out.push_str("\n\n");

    match &data.transcript {
        ExportTranscript::AsyncTokens(tokens) => {
            for token in tokens {
                out.push_str(&format!("{}\n", token.text));
            }
        }
        ExportTranscript::NotebookCapture {
            left_language,
            right_language: Some(right_language),
            utterances,
        } => {
            out.push_str(&format!("{left_language}\t{right_language}\n"));
            for utterance in utterances {
                if let Some((left, right)) =
                    fixed_language_row(utterance, left_language, right_language)
                {
                    out.push_str(&format!("{}\t{}\n", txt_cell(&left), txt_cell(&right)));
                } else {
                    out.push_str(&format!(
                        "[{}] {}\n",
                        utterance.source_language,
                        txt_cell(&utterance.source_text)
                    ));
                }
            }
        }
        ExportTranscript::NotebookCapture {
            left_language,
            right_language: None,
            utterances,
        } => {
            for utterance in utterances {
                let language = if utterance.source_language.is_empty() {
                    left_language
                } else {
                    &utterance.source_language
                };
                out.push_str(&format!(
                    "[{language}] {}\n",
                    txt_cell(&utterance.source_text)
                ));
            }
        }
        ExportTranscript::NotebookCaptureLanguageColumns {
            language_columns,
            common_caption_language: _,
            utterances,
        } => {
            if !language_columns.is_empty() {
                out.push_str(
                    &language_columns
                        .iter()
                        .map(|language| txt_cell(language))
                        .collect::<Vec<_>>()
                        .join("\t"),
                );
                out.push('\n');
                for utterance in utterances {
                    if let Some(cells) = ordered_language_row(utterance, language_columns) {
                        out.push_str(
                            &cells
                                .iter()
                                .map(|cell| txt_cell(cell))
                                .collect::<Vec<_>>()
                                .join("\t"),
                        );
                        out.push('\n');
                    }
                }
            }
            for utterance in utterances {
                append_unrepresented_txt(&mut out, utterance, language_columns);
            }
        }
    }

    if let Some(summary) = &data.summary {
        out.push_str("\n---\n\n");
        out.push_str(summary);
        out.push('\n');
    }

    Ok(out)
}

/// SRT 字幕导出
pub fn export_srt(data: &ExportData) -> Result<String, ExportError> {
    let mut out = String::new();

    for (i, token) in subtitle_tokens(data).into_iter().enumerate() {
        let idx = i + 1;
        let start = format_time_srt(token.start_ms);
        let end = format_time_srt(token.end_ms);
        out.push_str(&format!("{idx}\n{start} --> {end}\n{}\n\n", token.text));
    }

    Ok(out)
}

/// WebVTT 字幕导出
pub fn export_vtt(data: &ExportData) -> Result<String, ExportError> {
    let mut out = String::from("WEBVTT\n\n");

    for token in subtitle_tokens(data) {
        let start = format_time_vtt(token.start_ms);
        let end = format_time_vtt(token.end_ms);
        out.push_str(&format!("{start} --> {end}\n{}\n\n", token.text));
    }

    Ok(out)
}

fn subtitle_tokens(data: &ExportData) -> Vec<ExportToken> {
    match &data.transcript {
        ExportTranscript::AsyncTokens(tokens) => tokens
            .iter()
            .map(|token| ExportToken {
                text: token.text.clone(),
                start_ms: token.start_ms,
                end_ms: token.end_ms,
            })
            .collect(),
        ExportTranscript::NotebookCapture { utterances, .. }
        | ExportTranscript::NotebookCaptureLanguageColumns { utterances, .. } => utterances
            .iter()
            .filter_map(|utterance| {
                let (Some(start_ms), Some(end_ms)) =
                    (utterance.source_start_ms, utterance.source_end_ms)
                else {
                    return None;
                };
                (end_ms > start_ms).then(|| ExportToken {
                    text: utterance.source_text.clone(),
                    start_ms,
                    end_ms,
                })
            })
            .collect(),
    }
}

fn ordered_language_row(
    utterance: &ExportUtterance,
    language_columns: &[String],
) -> Option<Vec<String>> {
    let mut cells = vec![String::new(); language_columns.len()];
    let mut represented = false;
    for fact in utterance_facts(utterance) {
        if let Some(index) = language_index(language_columns, &fact.language) {
            cells[index] = fact.text;
            represented = true;
        }
    }
    represented.then_some(cells)
}

fn has_unrepresented_fact(utterance: &ExportUtterance, language_columns: &[String]) -> bool {
    utterance_facts(utterance)
        .iter()
        .any(|fact| language_index(language_columns, &fact.language).is_none())
}

fn append_unrepresented_markdown(
    out: &mut String,
    utterance: &ExportUtterance,
    language_columns: &[String],
) {
    for fact in utterance_facts(utterance)
        .into_iter()
        .filter(|fact| language_index(language_columns, &fact.language).is_none())
    {
        let label = if fact.is_source {
            markdown_cell(display_language(&fact.language))
        } else {
            format!(
                "{} (翻译自 {})",
                markdown_cell(display_language(&fact.language)),
                markdown_cell(display_language(&utterance.source_language))
            )
        };
        out.push_str(&format!("- **{label}**: {}\n", markdown_cell(&fact.text)));
    }
}

fn append_unrepresented_txt(
    out: &mut String,
    utterance: &ExportUtterance,
    language_columns: &[String],
) {
    for fact in utterance_facts(utterance)
        .into_iter()
        .filter(|fact| language_index(language_columns, &fact.language).is_none())
    {
        let label = if fact.is_source {
            txt_cell(display_language(&fact.language))
        } else {
            format!(
                "{} 翻译自 {}",
                txt_cell(display_language(&fact.language)),
                txt_cell(display_language(&utterance.source_language))
            )
        };
        out.push_str(&format!("[{label}] {}\n", txt_cell(&fact.text)));
    }
}

struct UtteranceFact {
    language: String,
    text: String,
    is_source: bool,
}

fn utterance_facts(utterance: &ExportUtterance) -> Vec<UtteranceFact> {
    let mut facts = Vec::new();
    push_or_replace_fact(
        &mut facts,
        &utterance.source_language,
        &utterance.source_text,
        true,
    );
    if let Some(text) = utterance.translated_text.as_deref() {
        push_or_replace_fact(
            &mut facts,
            utterance.translated_language.as_deref().unwrap_or("und"),
            text,
            false,
        );
    }
    for variant in &utterance.language_variants {
        push_or_replace_fact(&mut facts, &variant.language, &variant.text, false);
    }
    facts
}

fn push_or_replace_fact(
    facts: &mut Vec<UtteranceFact>,
    language: &str,
    text: &str,
    is_source: bool,
) {
    let text = text.trim();
    if text.is_empty() {
        return;
    }
    if let Some(existing) = facts.iter_mut().find(|fact| {
        !is_unknown_language(&fact.language)
            && !is_unknown_language(language)
            && same_language(&fact.language, language)
    }) {
        if !existing.is_source {
            existing.language = language.to_string();
            existing.text = text.to_string();
            existing.is_source = is_source;
        }
        return;
    }
    facts.push(UtteranceFact {
        language: language.to_string(),
        text: text.to_string(),
        is_source,
    });
}

fn is_unknown_language(language: &str) -> bool {
    language.trim().is_empty() || language.eq_ignore_ascii_case("und")
}

fn language_index(language_columns: &[String], language: &str) -> Option<usize> {
    language_columns
        .iter()
        .position(|column| same_language(column, language))
}

fn display_language(language: &str) -> &str {
    if language.trim().is_empty() {
        "und"
    } else {
        language
    }
}

fn fixed_language_row(
    utterance: &ExportUtterance,
    left_language: &str,
    right_language: &str,
) -> Option<(String, String)> {
    let translated_language = utterance.translated_language.as_deref().unwrap_or_default();
    let translated_text = utterance.translated_text.clone().unwrap_or_default();
    if same_language(&utterance.source_language, left_language) {
        let right = if same_language(translated_language, right_language) {
            translated_text
        } else {
            String::new()
        };
        Some((utterance.source_text.clone(), right))
    } else if same_language(&utterance.source_language, right_language) {
        let left = if same_language(translated_language, left_language) {
            translated_text
        } else {
            String::new()
        };
        Some((left, utterance.source_text.clone()))
    } else {
        None
    }
}

fn same_language(a: &str, b: &str) -> bool {
    fn base(value: &str) -> &str {
        value.trim().split(['-', '_']).next().unwrap_or_default()
    }
    base(a).eq_ignore_ascii_case(base(b))
}

fn markdown_cell(value: &str) -> String {
    value
        .replace('\\', "\\\\")
        .replace('|', "\\|")
        .replace(['\r', '\n'], "<br>")
}

fn txt_cell(value: &str) -> String {
    value.replace(['\r', '\n', '\t'], " ")
}

#[cfg(test)]
mod tests {
    use super::*;
    fn test_transcript() -> ExportData {
        ExportData {
            title: "产品讨论会".into(),
            transcript: ExportTranscript::AsyncTokens(vec![
                ExportToken {
                    text: "今天讨论路线图。".into(),
                    start_ms: 0,
                    end_ms: 2000,
                },
                ExportToken {
                    text: "我建议先做 MVP。".into(),
                    start_ms: 2500,
                    end_ms: 4500,
                },
                ExportToken {
                    text: "同意，下周出原型。".into(),
                    start_ms: 5000,
                    end_ms: 7000,
                },
            ]),
            summary: Some("讨论了产品路线图，决定先做 MVP。".into()),
        }
    }

    #[test]
    fn test_export_markdown() {
        let data = test_transcript();
        let output = export_markdown(&data).unwrap();
        assert!(output.contains("[00:00:00.000] 今天讨论路线图。"));
    }

    #[test]
    fn test_export_txt() {
        let data = test_transcript();
        let output = export_txt(&data).unwrap();
        assert!(output.contains("我建议先做 MVP。"));
    }

    #[test]
    fn test_export_srt() {
        let data = test_transcript();
        let output = export_srt(&data).unwrap();
        assert!(output.contains("00:00:00,000 --> 00:00:02,000"));
        assert!(output.contains("1\n"));
    }

    #[test]
    fn test_export_vtt() {
        let data = test_transcript();
        let output = export_vtt(&data).unwrap();
        assert!(output.starts_with("WEBVTT"));
        assert!(output.contains("00:00:00.000 --> 00:00:02.000"));
    }

    #[test]
    fn test_export_empty_transcript() {
        let data = ExportData {
            title: "空会话".into(),
            transcript: ExportTranscript::AsyncTokens(vec![]),
            summary: None,
        };
        let md = export_markdown(&data).unwrap();
        assert!(md.contains("空会话"));
    }

    #[test]
    fn clipboard_text_formats_bilingual_facts_with_title_time_and_speaker() {
        let transcript = ClipboardTranscript {
            title: Some("Product meeting".into()),
            language_columns: vec!["en".into(), "zh".into()],
            utterances: vec![ClipboardUtterance {
                start_ms: Some(1_234),
                speaker_name: Some("Speaker A".into()),
                source_language: "zh-CN".into(),
                source_text: "你好".into(),
                translated_language: Some("en-US".into()),
                translated_text: Some("Hello".into()),
                language_variants: Vec::new(),
            }],
        };

        assert_eq!(
            export_clipboard_text(&transcript),
            "Product meeting\n\n[00:00:01.234] Speaker A\nen: Hello\nzh: 你好"
        );
    }

    #[test]
    fn clipboard_text_formats_only_real_trilingual_lines_in_column_order() {
        let transcript = ClipboardTranscript {
            title: None,
            language_columns: vec!["en".into(), "zh".into(), "th".into()],
            utterances: vec![
                ClipboardUtterance {
                    start_ms: Some(0),
                    speaker_name: Some("Speaker 1".into()),
                    source_language: "th".into(),
                    source_text: "สวัสดี".into(),
                    translated_language: Some("en".into()),
                    translated_text: Some("Hello".into()),
                    language_variants: vec![ExportLanguageVariant {
                        language: "zh".into(),
                        text: "你好".into(),
                    }],
                },
                ClipboardUtterance {
                    start_ms: Some(2_000),
                    speaker_name: Some("Speaker 2".into()),
                    source_language: "zh".into(),
                    source_text: "欢迎".into(),
                    translated_language: Some("en".into()),
                    translated_text: Some("Welcome".into()),
                    language_variants: vec![ExportLanguageVariant {
                        language: "th".into(),
                        text: "ยินดีต้อนรับ".into(),
                    }],
                },
            ],
        };

        let text = export_clipboard_text(&transcript);
        assert_eq!(
            text,
            "[00:00:00.000] Speaker 1\nen: Hello\nzh: 你好\nth: สวัสดี\n\n\
             [00:00:02.000] Speaker 2\nen: Welcome\nzh: 欢迎\nth: ยินดีต้อนรับ"
        );
        assert!(!text.contains("th: \n"));
        assert!(!text.contains("---"));
        assert!(!text.contains("等待"));
    }

    #[test]
    fn clipboard_text_retains_unselected_language_facts() {
        let transcript = ClipboardTranscript {
            title: None,
            language_columns: vec!["en".into(), "zh".into(), "th".into()],
            utterances: vec![
                ClipboardUtterance {
                    start_ms: None,
                    speaker_name: Some("Guest".into()),
                    source_language: "fr".into(),
                    source_text: "Bonjour".into(),
                    translated_language: Some("en".into()),
                    translated_text: Some("Hello".into()),
                    language_variants: Vec::new(),
                },
                ClipboardUtterance {
                    start_ms: None,
                    speaker_name: None,
                    source_language: "zh".into(),
                    source_text: "你好".into(),
                    translated_language: Some("es".into()),
                    translated_text: Some("Hola".into()),
                    language_variants: Vec::new(),
                },
            ],
        };

        assert_eq!(
            export_clipboard_text(&transcript),
            "Guest\nen: Hello\nfr: Bonjour\n\nzh: 你好\nes: Hola"
        );
    }

    #[test]
    fn clipboard_text_omits_missing_time_and_speaker_without_placeholders() {
        let transcript = ClipboardTranscript {
            title: None,
            language_columns: vec!["en".into()],
            utterances: vec![ClipboardUtterance {
                start_ms: None,
                speaker_name: None,
                source_language: "en".into(),
                source_text: "No metadata".into(),
                translated_language: None,
                translated_text: None,
                language_variants: Vec::new(),
            }],
        };

        assert_eq!(export_clipboard_text(&transcript), "en: No metadata");
    }

    #[test]
    fn clipboard_text_omits_empty_facts_and_empty_paragraphs() {
        let transcript = ClipboardTranscript {
            title: Some("   ".into()),
            language_columns: vec!["en".into(), "zh".into()],
            utterances: vec![
                ClipboardUtterance {
                    start_ms: Some(1_000),
                    speaker_name: Some("Nobody".into()),
                    source_language: "en".into(),
                    source_text: " \n ".into(),
                    translated_language: Some("zh".into()),
                    translated_text: Some("\t".into()),
                    language_variants: Vec::new(),
                },
                ClipboardUtterance {
                    start_ms: None,
                    speaker_name: None,
                    source_language: "".into(),
                    source_text: "Known text".into(),
                    translated_language: None,
                    translated_text: Some("Actual translation".into()),
                    language_variants: Vec::new(),
                },
            ],
        };

        assert_eq!(
            export_clipboard_text(&transcript),
            "und: Known text\nund: Actual translation"
        );
        assert_eq!(
            export_clipboard_text(&ClipboardTranscript {
                title: None,
                language_columns: Vec::new(),
                utterances: Vec::new(),
            }),
            ""
        );
    }

    #[test]
    fn bilingual_text_uses_fixed_language_columns_in_both_speaking_directions() {
        let data = ExportData {
            title: "Bilingual".into(),
            transcript: ExportTranscript::NotebookCapture {
                left_language: "en".into(),
                right_language: Some("zh".into()),
                utterances: vec![
                    ExportUtterance {
                        source_language: "en-US".into(),
                        source_text: "Hello".into(),
                        source_start_ms: Some(10),
                        source_end_ms: Some(500),
                        translated_language: Some("zh-CN".into()),
                        translated_text: Some("你好".into()),
                        language_variants: Vec::new(),
                    },
                    ExportUtterance {
                        source_language: "zh".into(),
                        source_text: "再见".into(),
                        source_start_ms: Some(600),
                        source_end_ms: Some(900),
                        translated_language: Some("en".into()),
                        translated_text: Some("Goodbye".into()),
                        language_variants: Vec::new(),
                    },
                ],
            },
            summary: None,
        };

        let markdown = export_markdown(&data).unwrap();
        assert!(markdown.contains("| en | zh |"));
        assert!(markdown.contains("| Hello | 你好 |"));
        assert!(markdown.contains("| Goodbye | 再见 |"));
        let text = export_txt(&data).unwrap();
        assert!(text.contains("en\tzh"));
        assert!(text.contains("Hello\t你好"));
        assert!(text.contains("Goodbye\t再见"));
    }

    #[test]
    fn multilingual_text_uses_equal_ordered_columns_with_all_ready_translations() {
        let data = ExportData {
            title: "Multilingual".into(),
            transcript: ExportTranscript::NotebookCaptureLanguageColumns {
                language_columns: vec!["en".into(), "zh".into(), "th".into()],
                common_caption_language: Some("en".into()),
                utterances: vec![
                    ExportUtterance {
                        source_language: "th-TH".into(),
                        source_text: "สวัสดี".into(),
                        source_start_ms: Some(10),
                        source_end_ms: Some(500),
                        translated_language: Some("en-US".into()),
                        translated_text: Some("Hello".into()),
                        language_variants: vec![ExportLanguageVariant {
                            language: "zh".into(),
                            text: "你好".into(),
                        }],
                    },
                    ExportUtterance {
                        source_language: "zh".into(),
                        source_text: "欢迎".into(),
                        source_start_ms: Some(600),
                        source_end_ms: Some(900),
                        translated_language: Some("en".into()),
                        translated_text: Some("Welcome".into()),
                        language_variants: vec![ExportLanguageVariant {
                            language: "th".into(),
                            text: "ยินดีต้อนรับ".into(),
                        }],
                    },
                ],
            },
            summary: None,
        };

        let markdown = export_markdown(&data).unwrap();
        assert!(!markdown.contains("公共字幕"));
        assert!(markdown.contains("| en | zh | th |"));
        assert!(markdown.contains("| Hello | 你好 | สวัสดี |"));
        assert!(markdown.contains("| Welcome | 欢迎 | ยินดีต้อนรับ |"));

        let text = export_txt(&data).unwrap();
        assert!(!text.contains("公共字幕"));
        assert!(text.contains("en\tzh\tth"));
        assert!(text.contains("Hello\t你好\tสวัสดี"));
        assert!(text.contains("Welcome\t欢迎\tยินดีต้อนรับ"));
    }

    #[test]
    fn multilingual_text_exports_actual_facts_outside_selected_columns() {
        let data = ExportData {
            title: "Multilingual".into(),
            transcript: ExportTranscript::NotebookCaptureLanguageColumns {
                language_columns: vec!["en".into(), "zh".into(), "th".into()],
                common_caption_language: Some("en".into()),
                utterances: vec![
                    ExportUtterance {
                        source_language: "fr".into(),
                        source_text: "Bonjour".into(),
                        source_start_ms: Some(10),
                        source_end_ms: Some(500),
                        translated_language: Some("en".into()),
                        translated_text: Some("Hello".into()),
                        language_variants: Vec::new(),
                    },
                    ExportUtterance {
                        source_language: "zh".into(),
                        source_text: "你好".into(),
                        source_start_ms: Some(600),
                        source_end_ms: Some(900),
                        translated_language: Some("es".into()),
                        translated_text: Some("Hola".into()),
                        language_variants: Vec::new(),
                    },
                ],
            },
            summary: None,
        };

        let markdown = export_markdown(&data).unwrap();
        assert!(markdown.contains("- **fr**: Bonjour"));
        assert!(markdown.contains("| Hello |  |  |"));
        assert!(!markdown.contains("- **en (翻译自 fr)**: Hello"));
        assert!(markdown.contains("|  | 你好 |  |"));
        assert!(markdown.contains("- **es (翻译自 zh)**: Hola"));

        let text = export_txt(&data).unwrap();
        assert!(text.contains("[fr] Bonjour"));
        assert!(text.contains("Hello\t\t"));
        assert!(!text.contains("[en 翻译自 fr] Hello"));
        assert!(text.contains("[es 翻译自 zh] Hola"));
    }

    #[test]
    fn subtitles_include_only_timestamped_source_lane() {
        let data = ExportData {
            title: "Bilingual".into(),
            transcript: ExportTranscript::NotebookCapture {
                left_language: "en".into(),
                right_language: Some("zh".into()),
                utterances: vec![
                    ExportUtterance {
                        source_language: "en".into(),
                        source_text: "source with time".into(),
                        source_start_ms: Some(100),
                        source_end_ms: Some(900),
                        translated_language: Some("zh".into()),
                        translated_text: Some("不能出现在字幕".into()),
                        language_variants: Vec::new(),
                    },
                    ExportUtterance {
                        source_language: "zh".into(),
                        source_text: "source without time".into(),
                        source_start_ms: None,
                        source_end_ms: None,
                        translated_language: Some("en".into()),
                        translated_text: Some("also untimed".into()),
                        language_variants: Vec::new(),
                    },
                ],
            },
            summary: None,
        };

        let srt = export_srt(&data).unwrap();
        assert!(srt.contains("source with time"));
        assert!(!srt.contains("不能出现在字幕"));
        assert!(!srt.contains("source without time"));
        let vtt = export_vtt(&data).unwrap();
        assert!(vtt.contains("source with time"));
        assert!(!vtt.contains("also untimed"));
    }
}
