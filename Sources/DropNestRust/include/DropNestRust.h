#include <stddef.h>
#include <stdint.h>

// Heap bytes owned by Rust; always release with dn_buffer_free.
typedef struct {
    uint8_t *data;
    size_t len;
} DnBuffer;

void dn_buffer_free(DnBuffer buffer);

// Returns 0 on success, -1 if unreadable, unsupported, or modified during reading.
int32_t dn_sha256_file(const char *path, uint8_t output[32]);
// Returns 1 for identical bytes, 0 for different bytes, -1 on a read/change error.
int32_t dn_files_equal(const char *left, const char *right);
// Hashes files in parallel. digests holds count * 32 bytes; results[i] is 0 or -1
// as for dn_sha256_file. Returns -1 only for invalid arguments.
int32_t dn_sha256_files(const char *const *paths, size_t count, uint8_t *digests, int32_t *results);
// kind: 0 = XLSX, 1 = PPTX. Fills output with UTF-8 text; -1 if not a readable archive.
int32_t dn_office_text(const char *path, int32_t kind, size_t limit, DnBuffer *output, int32_t *truncated);
// Parallel metadata walk of an already resolved root. Output records:
// u8 incomplete, then per entry u8 kind (0 folder, 1 file, 2 package), u64 size,
// i64 seconds, i64 nanoseconds, u32 length, path bytes relative to root (little-endian).
// is_package may be called from several threads.
int32_t dn_scan_library(const char *root, size_t max_entries, size_t max_depth,
                        int32_t (*is_package)(const char *path), DnBuffer *output);
