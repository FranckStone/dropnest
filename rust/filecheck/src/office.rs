//! Text from XLSX shared strings / worksheet values and PPTX slide runs,
//! read in-process instead of spawning `unzip` once per XML entry.

use quick_xml::events::Event;
use quick_xml::Reader;
use std::fs::File;
use std::io::{self, Read};
use std::path::Path;
use zip::ZipArchive;

const MAX_ENTRIES: usize = 100;

fn wanted(name: &str, pptx: bool) -> bool {
    if pptx {
        name.starts_with("ppt/slides/slide") && name.ends_with(".xml")
    } else {
        name == "xl/sharedStrings.xml"
            || (name.starts_with("xl/worksheets/sheet") && name.ends_with(".xml"))
    }
}

/// Mirrors the previous XMLParser delegate: capture character data inside
/// `t`, `a:t` and `v`, and separate each captured element with a space.
pub(crate) fn xml_text(data: &[u8]) -> String {
    fn captured(name: &[u8]) -> bool {
        matches!(name, b"t" | b"a:t" | b"v")
    }
    // XML 1.0 §2.11 end-of-line handling, which XMLParser applies and
    // quick-xml leaves to the caller: CRLF and lone CR become LF. Character
    // references such as &#13; are untouched because they are still escaped.
    let mut normalized = Vec::with_capacity(data.len());
    let mut bytes = data.iter().peekable();
    while let Some(&byte) = bytes.next() {
        if byte == b'\r' {
            if bytes.peek() == Some(&&b'\n') {
                bytes.next();
            }
            normalized.push(b'\n');
        } else {
            normalized.push(byte);
        }
    }
    let mut reader = Reader::from_reader(normalized.as_slice());
    let mut buffer = Vec::new();
    let mut text = String::new();
    let mut capture = false;
    loop {
        match reader.read_event_into(&mut buffer) {
            Ok(Event::Start(element)) => capture = captured(element.name().as_ref()),
            Ok(Event::Empty(element)) => {
                if captured(element.name().as_ref()) {
                    text.push(' ');
                }
                capture = false;
            }
            Ok(Event::End(_)) => {
                if capture {
                    text.push(' ');
                }
                capture = false;
            }
            Ok(Event::Text(content)) if capture => {
                if let Ok(value) = content.unescape() {
                    text.push_str(&value);
                }
            }
            Ok(Event::CData(content)) if capture => {
                text.push_str(&String::from_utf8_lossy(&content));
            }
            // Like XMLParser, keep what was read before malformed or truncated XML.
            Ok(Event::Eof) | Err(_) => break,
            _ => {}
        }
        buffer.clear();
    }
    text
}

/// Returns the extracted text and whether it was cut short. Each XML entry is
/// read up to `limit * 6` bytes, bounding work on oversized or hostile files.
pub(crate) fn office_text(path: &Path, pptx: bool, limit: usize) -> io::Result<(String, bool)> {
    let mut archive = ZipArchive::new(File::open(path)?).map_err(io::Error::other)?;
    let mut names: Vec<String> = archive
        .file_names()
        .filter(|name| wanted(name, pptx))
        .map(String::from)
        .collect();
    names.sort();
    names.truncate(MAX_ENTRIES);
    let cap = limit.saturating_mul(6);
    let mut raw = String::new();
    let mut characters = 0usize;
    for name in names {
        let mut data = Vec::new();
        if let Ok(entry) = archive.by_name(&name) {
            if entry.take(cap as u64 + 1).read_to_end(&mut data).is_err() {
                data.clear();
            }
        }
        let entry_truncated = data.len() > cap;
        data.truncate(cap);
        let text = xml_text(&data);
        characters += text.chars().count() + 1;
        raw.push_str(&text);
        raw.push('\n');
        if entry_truncated || characters >= limit {
            return Ok((raw, true));
        }
    }
    Ok((raw, false))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use zip::write::SimpleFileOptions;

    fn archive(path: &Path, entries: &[(&str, &str)]) {
        let mut writer = zip::ZipWriter::new(File::create(path).unwrap());
        for (name, body) in entries {
            writer.start_file(*name, SimpleFileOptions::default()).unwrap();
            writer.write_all(body.as_bytes()).unwrap();
        }
        writer.finish().unwrap();
    }

    #[test]
    fn captures_text_runs_entities_and_empty_elements() {
        let xml = r#"<sst><si><t>Q3 &amp; 预算</t></si><si><r><t xml:space="preserve"> 合同 </t></r></si><si><t/></si><x>skip</x></sst>"#;
        assert_eq!(xml_text(xml.as_bytes()), "Q3 & 预算  合同   ");
        assert_eq!(xml_text(b"<p><a:t>Slide</a:t><a:t>"), "Slide ");
        assert_eq!(xml_text(b"<t>a\r\nb\rc&#13;d</t>"), "a\nb\nc\rd ");
    }

    #[test]
    fn reads_only_relevant_entries_in_sorted_order() {
        let folder = std::env::temp_dir().join(format!("dropnest-office-{}", std::process::id()));
        fs_reset(&folder);
        let xlsx = folder.join("a.xlsx");
        archive(&xlsx, &[
            ("xl/worksheets/sheet2.xml", "<w><c><v>42</v></c></w>"),
            ("xl/sharedStrings.xml", "<sst><si><t>客户名称</t></si></sst>"),
            ("xl/styles.xml", "<s><t>ignored</t></s>"),
            ("xl/worksheets/sheet1.xml", "<w><c><v>7</v></c></w>"),
        ]);
        let (text, truncated) = office_text(&xlsx, false, 1000).unwrap();
        assert_eq!(text, "客户名称 \n7 \n42 \n");
        assert!(!truncated);

        let pptx = folder.join("a.pptx");
        archive(&pptx, &[
            ("ppt/slides/slide1.xml", "<p:sld><a:t>年度汇报</a:t></p:sld>"),
            ("ppt/notesSlides/notesSlide1.xml", "<a:t>notes</a:t>"),
        ]);
        assert_eq!(office_text(&pptx, true, 1000).unwrap().0, "年度汇报 \n");

        let long = format!("<sst><si><t>{}</t></si></sst>", "字".repeat(500));
        archive(&xlsx, &[("xl/sharedStrings.xml", long.as_str())]);
        let (bounded, truncated) = office_text(&xlsx, false, 10).unwrap();
        assert!(truncated);
        assert!(bounded.len() <= 60 + 1);

        std::fs::write(&xlsx, b"not a zip").unwrap();
        assert!(office_text(&xlsx, false, 1000).is_err());
        std::fs::remove_dir_all(folder).unwrap();
    }

    fn fs_reset(folder: &Path) {
        let _ = std::fs::remove_dir_all(folder);
        std::fs::create_dir_all(folder).unwrap();
    }
}
