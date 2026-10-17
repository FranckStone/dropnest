#include <stdint.h>

// Returns 0 on success, -1 if unreadable, unsupported, or modified during reading.
int32_t dn_sha256_file(const char *path, uint8_t output[32]);
// Returns 1 for identical bytes, 0 for different bytes, -1 on a read/change error.
int32_t dn_files_equal(const char *left, const char *right);
