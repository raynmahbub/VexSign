#ifndef VEX_ZSTD_H
#define VEX_ZSTD_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Decodes a zstd frame — or a concatenation of frames and skippable frames — into a
/// malloc'd buffer the caller releases with `vex_zstd_free`.
///
/// `max_out` is a hard ceiling: the frame's declared content size is refused before
/// allocation, and growth stops at the ceiling, so a decompression bomb returns an error
/// instead of expanding. Pass 0 for no ceiling (never with untrusted input).
///
/// When the frame carries an XXH64 content checksum, it is verified.
///
/// - Returns: 0 on success, -1 on malformed or truncated input, -2 when `max_out` would
///   be exceeded. `vex_zstd_last_error()` describes the failure for a log line.
int vex_zstd_decode(const uint8_t *in, size_t len, size_t max_out,
                    uint8_t **out, size_t *out_len);

/// Releases a buffer produced by `vex_zstd_decode`.
void vex_zstd_free(void *p);

/// The last failure on this thread, or an empty string.
const char *vex_zstd_last_error(void);

#ifdef __cplusplus
}
#endif

#endif /* VEX_ZSTD_H */
