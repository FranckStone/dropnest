//! Parallel metadata walk for the library index. Matches the FileManager
//! enumerator it replaces: skips hidden entries, never follows symlinks, does
//! not enter packages or `node_modules`, and stops at an entry limit.

use rayon::prelude::*;
use std::ffi::OsStr;
use std::fs::{self, Metadata};
use std::os::macos::fs::MetadataExt as MacMetadataExt;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};

const UF_HIDDEN: u32 = 0x8000;

pub(crate) const KIND_FOLDER: u8 = 0;
pub(crate) const KIND_FILE: u8 = 1;
pub(crate) const KIND_PACKAGE: u8 = 2;

pub(crate) struct Entry {
    pub kind: u8,
    pub size: u64,
    pub seconds: i64,
    pub nanoseconds: i64,
    /// Path relative to the root, as raw filesystem bytes.
    pub relative: Vec<u8>,
}

pub(crate) struct ScanResult {
    pub entries: Vec<Entry>,
    pub incomplete: bool,
}

struct Walk<'a> {
    root_length: usize,
    max_entries: usize,
    max_depth: usize,
    count: AtomicUsize,
    incomplete: AtomicBool,
    stopped: AtomicBool,
    is_package: &'a (dyn Fn(&Path) -> bool + Sync),
}

impl Walk<'_> {
    fn flag_incomplete(&self) {
        self.incomplete.store(true, Ordering::Relaxed);
    }

    fn entry(&self, kind: u8, path: &Path, metadata: &Metadata, size: u64) -> Entry {
        Entry {
            kind,
            size,
            seconds: metadata.mtime(),
            nanoseconds: metadata.mtime_nsec(),
            relative: path.as_os_str().as_bytes()[self.root_length + 1..].to_vec(),
        }
    }

    fn directory(&self, directory: &Path, depth: usize) -> Vec<Entry> {
        let listing = match fs::read_dir(directory) {
            Ok(listing) => listing,
            Err(_) => {
                self.flag_incomplete();
                return Vec::new();
            }
        };
        let mut entries = Vec::new();
        let mut children: Vec<PathBuf> = Vec::new();
        for item in listing {
            if self.stopped.load(Ordering::Relaxed) {
                break;
            }
            let Ok(item) = item else {
                self.flag_incomplete();
                continue;
            };
            let name = item.file_name();
            if name.as_bytes().first() == Some(&b'.') {
                continue;
            }
            let path = item.path();
            let metadata = fs::symlink_metadata(&path);
            if let Ok(metadata) = &metadata {
                if metadata.st_flags() & UF_HIDDEN != 0 {
                    continue;
                }
            }
            if self.count.fetch_add(1, Ordering::Relaxed) + 1 > self.max_entries {
                self.flag_incomplete();
                self.stopped.store(true, Ordering::Relaxed);
                break;
            }
            let Ok(metadata) = metadata else {
                self.flag_incomplete();
                continue;
            };
            let kind = metadata.file_type();
            if kind.is_symlink() {
                continue;
            }
            if kind.is_dir() {
                if name == OsStr::new("node_modules") {
                    self.flag_incomplete();
                    continue;
                }
                // Only names with an extension can be bundles, so the
                // LaunchServices lookup in Swift stays rare.
                if name.as_bytes().contains(&b'.') && (self.is_package)(&path) {
                    entries.push(self.entry(KIND_PACKAGE, &path, &metadata, 0));
                    continue;
                }
                if depth + 1 > self.max_depth {
                    self.flag_incomplete();
                    continue;
                }
                entries.push(self.entry(KIND_FOLDER, &path, &metadata, 0));
                children.push(path);
            } else if kind.is_file() {
                entries.push(self.entry(KIND_FILE, &path, &metadata, metadata.len()));
            }
        }
        let nested: Vec<Vec<Entry>> = children
            .par_iter()
            .map(|child| self.directory(child, depth + 1))
            .collect();
        entries.extend(nested.into_iter().flatten());
        entries
    }
}

/// `root` must already be resolved (no symlinks) and must be a directory.
pub(crate) fn scan(
    root: &Path,
    max_entries: usize,
    max_depth: usize,
    is_package: &(dyn Fn(&Path) -> bool + Sync),
) -> ScanResult {
    let walk = Walk {
        root_length: root.as_os_str().len(),
        max_entries,
        max_depth,
        count: AtomicUsize::new(0),
        incomplete: AtomicBool::new(false),
        stopped: AtomicBool::new(false),
        is_package,
    };
    let entries = walk.directory(root, 0);
    ScanResult { entries, incomplete: walk.incomplete.load(Ordering::Relaxed) }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::process::Command;

    fn relative(result: &ScanResult, kind: u8) -> Vec<String> {
        let mut paths: Vec<String> = result
            .entries
            .iter()
            .filter(|entry| entry.kind == kind)
            .map(|entry| String::from_utf8(entry.relative.clone()).unwrap())
            .collect();
        paths.sort();
        paths
    }

    #[test]
    fn mirrors_enumerator_filters() {
        let root = std::env::temp_dir().join(format!("dropnest-scan-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(root.join("客户/星河/深层")).unwrap();
        fs::create_dir_all(root.join(".hidden")).unwrap();
        fs::create_dir_all(root.join("node_modules/pkg")).unwrap();
        fs::create_dir_all(root.join("Tool.app/Contents")).unwrap();
        fs::create_dir_all(root.join("flagged")).unwrap();
        fs::write(root.join("客户/星河/合同.pdf"), b"12345").unwrap();
        fs::write(root.join("客户/.DS_Store"), b"x").unwrap();
        fs::write(root.join("Tool.app/Contents/Info.plist"), b"x").unwrap();
        fs::write(root.join("node_modules/pkg/index.js"), b"x").unwrap();
        std::os::unix::fs::symlink(root.join("客户"), root.join("link")).unwrap();
        assert!(Command::new("chflags").arg("hidden").arg(root.join("flagged")).status().unwrap().success());
        let root = root.canonicalize().unwrap();

        let result = scan(&root, 100, 24, &|path: &Path| path.extension() == Some(OsStr::new("app")));
        assert_eq!(relative(&result, KIND_FOLDER), ["客户", "客户/星河", "客户/星河/深层"]);
        assert_eq!(relative(&result, KIND_FILE), ["客户/星河/合同.pdf"]);
        assert_eq!(relative(&result, KIND_PACKAGE), ["Tool.app"]);
        assert!(result.incomplete, "node_modules is reported as skipped");
        let file = result.entries.iter().find(|entry| entry.kind == KIND_FILE).unwrap();
        assert_eq!(file.size, 5);

        let shallow = scan(&root, 100, 2, &|path: &Path| path.extension() == Some(OsStr::new("app")));
        assert_eq!(relative(&shallow, KIND_FOLDER), ["客户", "客户/星河"]);
        let limited = scan(&root, 2, 24, &|_: &Path| false);
        assert!(limited.incomplete);
        assert!(limited.entries.len() <= 2);
        fs::remove_dir_all(root).unwrap();
    }
}
