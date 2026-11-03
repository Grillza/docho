// The embedded JVM bridge (PLAN-2, part G5): starts Eclipse OpenJ9, linked into the app, with the
// extension host jar, and passes JSON-RPC calls and extension HTTP between Swift and the host's
// EmbeddedBridge. The API matches what the runtime's smoke test (jvm-ios/smoke/host_smoke.c)
// calls, so `jvm-ios/smoke-openj9-ios.sh host` can check this shim without the app.
//
// Threads: every JNI call runs on one thread the bridge owns (with a large stack, which the
// interpreter needs). Callbacks arrive on the host's threads; they must not block for long.
#ifndef DOCHO_JVM_H
#define DOCHO_JVM_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    void *context;
    /// The JSON-RPC response to call `id`.
    void (*complete)(void *context, int64_t id, const uint8_t *bytes, size_t length);
    /// A host event (`ext.progress`, `host.toast`, `net.challengeRequired`, `webview.command`, …).
    void (*emit)(void *context, const uint8_t *bytes, size_t length);
    /// Extension HTTP request `id`: `net.fetch` metadata (JSON, no body) and the raw body, which the
    /// callee owns and frees (NULL when there is none). Answer with `oc_jvm_fetch_result`.
    void (*fetch)(void *context, int64_t id, const uint8_t *meta, size_t meta_length, uint8_t *body, size_t body_length);
    /// The answer to fetch `id` is no longer wanted. May be NULL.
    void (*fetch_cancel)(void *context, int64_t id);
} oc_jvm_callbacks;

/// Whether a JVM is linked into this app (`JNI_CreateJavaVM` can be found).
int oc_jvm_available(void);

/// Starts the JVM with `options` (`-D…`, `-X…`; one JVM per process), registers the callbacks on
/// `bridge_class` (`oneechan/host/embedded/EmbeddedBridge`) and calls its `start(config)`. Returns
/// 0, or -1 with a message in `error`. Blocks until the host has started. `reserved` is unused.
int oc_jvm_start(const void *reserved, const char *const *options, int option_count, const char *bridge_class,
                 const uint8_t *config, size_t config_length, oc_jvm_callbacks callbacks, char *error, size_t error_size);

/// Queues JSON-RPC request `bytes` as call `id`; the answer comes to `complete`.
int oc_jvm_call(int64_t id, const uint8_t *bytes, size_t length);

/// Queues the answer to fetch `id`: `net.fetchResult` metadata without the body (JSON), and the raw
/// body, which this takes ownership of and frees (NULL when there is none). Returns 0 when queued.
int oc_jvm_fetch_result(int64_t id, const uint8_t *meta, size_t meta_length, uint8_t *body, size_t body_length);

#ifdef __cplusplus
}
#endif

#endif
