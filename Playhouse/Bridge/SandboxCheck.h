// The daemon's view of a caller's macOS sandbox. `sandbox_check` is variadic, which Swift
// can't call, so this header, imported only into the daemon's build, wraps the one query
// it needs.
#include <sys/types.h>

extern int sandbox_check(pid_t pid, const char *operation, int type, ...);

/// 1 when process `pid` runs in a macOS sandbox, else 0.
static inline int playhouse_is_sandboxed(pid_t pid) {
    return sandbox_check(pid, NULL, 0);
}

/// 1 when process `pid`'s sandbox forbids it to create files in the existing directory at
/// `path`, 0 when it may. A path that doesn't exist always reads as forbidden, so the caller
/// passes one that does. 1 is SANDBOX_FILTER_PATH.
static inline int playhouse_sandbox_denies_file_create(pid_t pid, const char *path) {
    return sandbox_check(pid, "file-write-create", 1, path);
}
