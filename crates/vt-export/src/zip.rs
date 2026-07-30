//! ZIP 打包导出
//! 权威：D5 §13

use crate::{ExportData, ExportError};

/// ZIP 导出选项
pub struct ExportOptions {
    pub include_audio: bool,
    pub include_markdown: bool,
    pub include_srt: bool,
    pub include_vtt: bool,
    pub include_txt: bool,
}

impl Default for ExportOptions {
    fn default() -> Self {
        Self {
            include_audio: true,
            include_markdown: true,
            include_srt: true,
            include_vtt: false,
            include_txt: false,
        }
    }
}

/// 导出为 ZIP（返回 ZIP 字节）
pub fn export_zip(
    data: &ExportData,
    options: &ExportOptions,
    audio_data: Option<&[u8]>,
) -> Result<Vec<u8>, ExportError> {
    use std::io::Write;

    let buf = std::io::Cursor::new(Vec::new());
    let mut zip = zip::ZipWriter::new(buf);

    let zip_options = zip::write::SimpleFileOptions::default()
        .compression_method(zip::CompressionMethod::Deflated);

    // Markdown
    if options.include_markdown {
        let md = crate::export_markdown(data)?;
        zip.start_file("transcript.md", zip_options)
            .map_err(|e| ExportError::Failed(e.to_string()))?;
        zip.write_all(md.as_bytes())
            .map_err(|e| ExportError::Failed(e.to_string()))?;
    }

    // SRT
    if options.include_srt {
        let srt = crate::export_srt(data)?;
        zip.start_file("transcript.srt", zip_options)
            .map_err(|e| ExportError::Failed(e.to_string()))?;
        zip.write_all(srt.as_bytes())
            .map_err(|e| ExportError::Failed(e.to_string()))?;
    }

    // VTT
    if options.include_vtt {
        let vtt = crate::export_vtt(data)?;
        zip.start_file("transcript.vtt", zip_options)
            .map_err(|e| ExportError::Failed(e.to_string()))?;
        zip.write_all(vtt.as_bytes())
            .map_err(|e| ExportError::Failed(e.to_string()))?;
    }

    // TXT
    if options.include_txt {
        let txt = crate::export_txt(data)?;
        zip.start_file("transcript.txt", zip_options)
            .map_err(|e| ExportError::Failed(e.to_string()))?;
        zip.write_all(txt.as_bytes())
            .map_err(|e| ExportError::Failed(e.to_string()))?;
    }

    // Audio
    if options.include_audio {
        let audio = audio_data.ok_or_else(|| {
            ExportError::Failed("audio was requested but no complete audio was supplied".into())
        })?;
        zip.start_file("audio.wav", zip_options)
            .map_err(|e| ExportError::Failed(e.to_string()))?;
        zip.write_all(audio)
            .map_err(|e| ExportError::Failed(e.to_string()))?;
    }

    let cursor = zip
        .finish()
        .map_err(|e| ExportError::Failed(e.to_string()))?;
    Ok(cursor.into_inner())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{ExportToken, ExportTranscript};

    fn test_data() -> ExportData {
        ExportData {
            title: "Test".into(),
            transcript: ExportTranscript::AsyncTokens(vec![ExportToken {
                text: "Hello.".into(),
                start_ms: 0,
                end_ms: 1000,
            }]),
            summary: Some("Summary".into()),
        }
    }

    #[test]
    fn test_export_zip_with_audio() {
        let data = test_data();
        let audio = vec![0u8; 1000];
        let zip_bytes = export_zip(&data, &ExportOptions::default(), Some(&audio)).unwrap();
        assert!(!zip_bytes.is_empty());

        // Verify ZIP contains expected files
        let reader = std::io::Cursor::new(&zip_bytes);
        let archive = zip::ZipArchive::new(reader).unwrap();
        let names: Vec<_> = archive.file_names().collect();
        assert!(names.contains(&"transcript.md"));
        assert!(names.contains(&"transcript.srt"));
        assert!(names.contains(&"audio.wav"));
    }

    #[test]
    fn test_export_zip_without_audio() {
        let data = test_data();
        let opts = ExportOptions {
            include_audio: false,
            ..Default::default()
        };
        let zip_bytes = export_zip(&data, &opts, None).unwrap();

        let reader = std::io::Cursor::new(&zip_bytes);
        let archive = zip::ZipArchive::new(reader).unwrap();
        let names: Vec<_> = archive.file_names().collect();
        assert!(!names.contains(&"audio.wav"));
        assert!(names.contains(&"transcript.md"));
    }

    #[test]
    fn test_export_zip_rejects_missing_requested_audio() {
        let error = export_zip(&test_data(), &ExportOptions::default(), None).unwrap_err();
        assert!(error.to_string().contains("audio was requested"));
    }

    #[test]
    fn test_export_zip_all_formats() {
        let data = test_data();
        let opts = ExportOptions {
            include_audio: false,
            include_markdown: true,
            include_srt: true,
            include_vtt: true,
            include_txt: true,
        };
        let zip_bytes = export_zip(&data, &opts, None).unwrap();

        let reader = std::io::Cursor::new(&zip_bytes);
        let archive = zip::ZipArchive::new(reader).unwrap();
        assert_eq!(archive.len(), 4); // md + srt + vtt + txt
    }
}
