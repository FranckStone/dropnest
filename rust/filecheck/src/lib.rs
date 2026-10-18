mod office;
mod scan;

use rayon::prelude::*;
use sha2::{Digest, Sha256};
use std::ffi::{c_char, CStr};
use std::fs::{self, File, Metadata};
use std::io::{self, Read};
use std::os::unix::{ffi::OsStrExt, fs::MetadataExt};
use std::path::{Path, PathBuf};

const CHUNK: usize = 64 * 1024;

fn stamp(metadata: &Metadata) -> (u64, u64, u64, i64, i64, i64, i64) {
    (
        metadata.dev(),
        metadata.ino(),
        metadata.len(),
        metadata.mtime(),
        metadata.mtime_nsec(),
        metadata.ctime(),
        metadata.ctime_nsec(),
    )
}

fn open_regular(path: &Path) -> io::Result<(File, Metadata)> {
    let before = fs::symlink_metadata(path)?;
    if !before.is_file() {
        return Err(io::Error::other("not a regular file"));
    }
    let file = File::open(path)?;
    if stamp(&before) != stamp(&file.metadata()?) {
        return Err(io::Error::other("file changed before reading"));
    }
    Ok((file, before))
}

fn ensure_unchanged(path: &Path, file: &File, before: &Metadata) -> io::Result<()> {
    if stamp(before) != stamp(&file.metadata()?)
        || stamp(before) != stamp(&fs::symlink_metadata(path)?)
    {
        return Err(io::Error::other("file changed while reading"));
    }
    Ok(())
}

fn fingerprint(path: &Path) -> io::Result<[u8; 32]> {
    let (mut file, before) = open_regular(path)?;
    let mut hasher = Sha256::new();
    let mut buffer = [0u8; CHUNK];
    loop {
        let count = file.read(&mut buffer)?;
        if count == 0 {
            break;
        }
        hasher.update(&buffer[..count]);
    }
    ensure_unchanged(path, &file, &before)?;
    Ok(hasher.finalize().into())
}

fn files_equal(left: &Path, right: &Path) -> io::Result<bool> {
    let (mut a, before_a) = open_regular(left)?;
    let (mut b, before_b) = open_regular(right)?;
    if before_a.len() != before_b.len() {
        return Ok(false);
    }
    let mut remaining = before_a.len();
    let mut buffer_a = [0u8; CHUNK];
    let mut buffer_b = [0u8; CHUNK];
    while remaining > 0 {
        let count = remaining.min(CHUNK as u64) as usize;
        a.read_exact(&mut buffer_a[..count])?;
        b.read_exact(&mut buffer_b[..count])?;
        if buffer_a[..count] != buffer_b[..count] {
            return Ok(false);
        }
        remaining -= count as u64;
    }
    ensure_unchanged(left, &a, &before_a)?;
    ensure_unchanged(right, &b, &before_b)?;
    Ok(true)
}

// The caller supplies valid NUL-terminated filesystem paths and a 32-byte output buffer.
#[no_mangle]
pub unsafe extern "C" fn dn_sha256_file(path: *const c_char, output: *mut u8) -> i32 {
    if path.is_null() || output.is_null() {
        return -1;
    }
    std::panic::catch_unwind(|| {
        let path = Path::new(std::ffi::OsStr::from_bytes(CStr::from_ptr(path).to_bytes()));
        match fingerprint(path) {
            Ok(digest) => {
                std::ptr::copy_nonoverlapping(digest.as_ptr(), output, 32);
                0
            }
            Err(_) => -1,
        }
    })
    .unwrap_or(-1)
}

#[no_mangle]
pub unsafe extern "C" fn dn_files_equal(left: *const c_char, right: *const c_char) -> i32 {
    if left.is_null() || right.is_null() {
        return -1;
    }
    std::panic::catch_unwind(|| {
        let left = Path::new(std::ffi::OsStr::from_bytes(CStr::from_ptr(left).to_bytes()));
        let right = Path::new(std::ffi::OsStr::from_bytes(
            CStr::from_ptr(right).to_bytes(),
        ));
        match files_equal(left, right) {
            Ok(true) => 1,
            Ok(false) => 0,
            Err(_) => -1,
        }
    })
    .unwrap_or(-1)
}


unsafe fn path_from<'a>(path: *const c_char) -> &'a Path {
    Path::new(std::ffi::OsStr::from_bytes(CStr::from_ptr(path).to_bytes()))
}

/// Heap bytes handed to Swift; release with `dn_buffer_free`.
#[repr(C)]
pub struct DnBuffer {
    data: *mut u8,
    len: usize,
}

impl DnBuffer {
    const EMPTY: DnBuffer = DnBuffer { data: std::ptr::null_mut(), len: 0 };

    fn from_vec(bytes: Vec<u8>) -> DnBuffer {
        let boxed = bytes.into_boxed_slice();
        let len = boxed.len();
        DnBuffer { data: Box::into_raw(boxed) as *mut u8, len }
    }
}

#[no_mangle]
pub unsafe extern "C" fn dn_buffer_free(buffer: DnBuffer) {
    if !buffer.data.is_null() {
        drop(Box::from_raw(std::ptr::slice_from_raw_parts_mut(buffer.data, buffer.len)));
    }
}

/// Hashes `count` files in parallel. `digests` holds `count * 32` bytes and
/// `results[i]` receives 0 or -1 exactly as `dn_sha256_file` would.
#[no_mangle]
pub unsafe extern "C" fn dn_sha256_files(
    paths: *const *const c_char,
    count: usize,
    digests: *mut u8,
    results: *mut i32,
) -> i32 {
    if count == 0 {
        return 0;
    }
    if paths.is_null() || digests.is_null() || results.is_null() {
        return -1;
    }
    let owned: Vec<Option<PathBuf>> = (0..count)
        .map(|index| {
            let path = *paths.add(index);
            (!path.is_null()).then(|| path_from(path).to_path_buf())
        })
        .collect();
    let hashed = std::panic::catch_unwind(|| {
        owned
            .par_iter()
            .map(|path| path.as_deref().and_then(|path| fingerprint(path).ok()))
            .collect::<Vec<_>>()
    });
    let Ok(hashed) = hashed else { return -1 };
    for (index, digest) in hashed.into_iter().enumerate() {
        match digest {
            Some(digest) => {
                std::ptr::copy_nonoverlapping(digest.as_ptr(), digests.add(index * 32), 32);
                *results.add(index) = 0;
            }
            None => *results.add(index) = -1,
        }
    }
    0
}

/// `kind`: 0 = XLSX, 1 = PPTX. Returns 0 and fills `output` with UTF-8 text,
/// or -1 when the file is not a readable archive.
#[no_mangle]
pub unsafe extern "C" fn dn_office_text(
    path: *const c_char,
    kind: i32,
    limit: usize,
    output: *mut DnBuffer,
    truncated: *mut i32,
) -> i32 {
    if path.is_null() || output.is_null() || truncated.is_null() {
        return -1;
    }
    *output = DnBuffer::EMPTY;
    let path = path_from(path);
    match std::panic::catch_unwind(|| office::office_text(path, kind == 1, limit)) {
        Ok(Ok((text, cut))) => {
            *output = DnBuffer::from_vec(text.into_bytes());
            *truncated = cut as i32;
            0
        }
        _ => -1,
    }
}

/// Walks `root` (already resolved) and fills `output` with records:
/// header `u8 incomplete`, then per entry `u8 kind, u64 size, i64 seconds,
/// i64 nanoseconds, u32 length, path bytes`, all little-endian.
/// `is_package` is called, possibly from several threads, for directories
/// whose name contains a dot.
#[no_mangle]
pub unsafe extern "C" fn dn_scan_library(
    root: *const c_char,
    max_entries: usize,
    max_depth: usize,
    is_package: Option<extern "C" fn(*const c_char) -> i32>,
    output: *mut DnBuffer,
) -> i32 {
    if root.is_null() || output.is_null() {
        return -1;
    }
    *output = DnBuffer::EMPTY;
    let root = path_from(root);
    let check = |path: &Path| -> bool {
        let Some(callback) = is_package else { return false };
        let Ok(bytes) = std::ffi::CString::new(path.as_os_str().as_bytes()) else { return false };
        callback(bytes.as_ptr()) == 1
    };
    let Ok(result) = std::panic::catch_unwind(|| scan::scan(root, max_entries, max_depth, &check)) else {
        return -1;
    };
    let mut bytes = Vec::with_capacity(1 + result.entries.len() * 64);
    bytes.push(result.incomplete as u8);
    for entry in &result.entries {
        bytes.push(entry.kind);
        bytes.extend_from_slice(&entry.size.to_le_bytes());
        bytes.extend_from_slice(&entry.seconds.to_le_bytes());
        bytes.extend_from_slice(&entry.nanoseconds.to_le_bytes());
        bytes.extend_from_slice(&(entry.relative.len() as u32).to_le_bytes());
        bytes.extend_from_slice(&entry.relative);
    }
    *output = DnBuffer::from_vec(bytes);
    0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn streaming_comparison_and_sha256() {
        let folder = std::env::temp_dir().join(format!("dropnest-rust-{}", std::process::id()));
        fs::create_dir_all(&folder).unwrap();
        let a = folder.join("a");
        let b = folder.join("b");
        fs::write(&a, b"abc").unwrap();
        assert_eq!(
            format!("{:x}", Sha256::digest(b"abc")),
            fingerprint(&a)
                .unwrap()
                .iter()
                .map(|b| format!("{b:02x}"))
                .collect::<String>()
        );
        let data = vec![42u8; CHUNK * 3 + 7];
        fs::write(&a, &data).unwrap();
        fs::write(&b, &data).unwrap();
        assert!(files_equal(&a, &b).unwrap());
        let mut changed = data;
        *changed.last_mut().unwrap() = 43;
        fs::write(&b, changed).unwrap();
        assert!(!files_equal(&a, &b).unwrap());
        assert_ne!(fingerprint(&a).unwrap(), fingerprint(&b).unwrap());
        fs::write(&a, []).unwrap();
        fs::write(&b, []).unwrap();
        assert!(files_equal(&a, &b).unwrap());
        let link = folder.join("link");
        std::os::unix::fs::symlink(&a, &link).unwrap();
        assert!(fingerprint(&link).is_err());
        assert!(fingerprint(&folder).is_err());
        fs::remove_dir_all(folder).unwrap();
    }
}
