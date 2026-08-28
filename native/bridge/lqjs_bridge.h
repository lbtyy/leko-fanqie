/*
 * Stable, deliberately narrow QuickJS bridge ABI for the Leko experiment.
 *
 * This header is MIT-compatible glue intended to be compiled together with a
 * pinned QuickJS source release. It does not expose QuickJS JSValue or any
 * QuickJS struct to LuaJIT FFI. All input/output bytes are length-delimited
 * UTF-8 JSON. The ABI is single-threaded: the KOReader task that creates a
 * runtime must also use and destroy it.
 */
#ifndef LEKO_QJS_BRIDGE_H
#define LEKO_QJS_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#if defined(_WIN32)
#define LQJS_EXPORT __declspec(dllexport)
#else
#define LQJS_EXPORT __attribute__((visibility("default")))
#endif

#define LQJS_ABI_VERSION 2u
#define LQJS_ENGINE_VERSION "2026-06-04"
#define LQJS_BRIDGE_VERSION "2.0.0"

enum lqjs_status {
    LQJS_STATUS_OK = 0,
    LQJS_STATUS_EXCEPTION = 1,
    LQJS_STATUS_MEMORY_LIMIT = 2,
    LQJS_STATUS_TIMEOUT = 3,
    LQJS_STATUS_INVALID_ARGUMENT = 4,
    LQJS_STATUS_NATIVE_FAILURE = 5,
    LQJS_STATUS_HOST_DENIED = 6,
    LQJS_STATUS_UNSUPPORTED = 7,
};

typedef struct lqjs_runtime lqjs_runtime;
typedef struct lqjs_context lqjs_context;

typedef struct {
    uint32_t abi_version;
    uint32_t flags;
    size_t memory_limit_bytes;
    size_t max_stack_bytes;
} lqjs_runtime_options;

typedef struct {
    uint32_t abi_version;
    uint32_t flags;
    /* Relative wall-clock budget set immediately before JS_Eval. */
    uint64_t timeout_ms;
    size_t max_result_bytes;
} lqjs_eval_options;

typedef struct {
    uint32_t abi_version;
    uint32_t status;
    int64_t engine_code;
    /* Borrowed until the next bridge call on this context/runtime. */
    const char *message;
    size_t message_len;
    const char *stack;
    size_t stack_len;
} lqjs_error;

/*
 * Host calls are synchronous and length-delimited.  The callback owns neither
 * the request bytes nor the returned bytes; the bridge consumes the returned
 * buffer before the callback returns.  This keeps the LuaJIT FFI boundary
 * independent from QuickJS's JSValue representation and avoids passing a Lua
 * allocator into the native engine.
 */
typedef int (*lqjs_host_call_fn)(void *opaque,
                                const uint8_t *request, size_t request_len,
                                const uint8_t **response, size_t *response_len);

LQJS_EXPORT uint32_t lqjs_abi_version(void);
LQJS_EXPORT const char *lqjs_engine_version(void);
LQJS_EXPORT const char *lqjs_bridge_version(void);
LQJS_EXPORT lqjs_runtime *lqjs_runtime_new(const lqjs_runtime_options *options,
                                           lqjs_error *error_out);
LQJS_EXPORT void lqjs_runtime_free(lqjs_runtime *runtime);
LQJS_EXPORT int lqjs_runtime_set_memory_limit(lqjs_runtime *runtime, size_t bytes);
LQJS_EXPORT int lqjs_runtime_set_stack_limit(lqjs_runtime *runtime, size_t bytes);
LQJS_EXPORT int lqjs_runtime_set_timeout_ms(lqjs_runtime *runtime, uint64_t timeout_ms);
LQJS_EXPORT void lqjs_runtime_collect_garbage(lqjs_runtime *runtime);
/* Values are QuickJS-managed bytes. `peak` is the highest sampled usage at
 * runtime API/evaluation boundaries since runtime creation. */
LQJS_EXPORT void lqjs_runtime_memory_usage(lqjs_runtime *runtime,
                                           size_t *current,
                                           size_t *peak);

LQJS_EXPORT lqjs_context *lqjs_context_new(lqjs_runtime *runtime,
                                           lqjs_error *error_out);
LQJS_EXPORT void lqjs_context_free(lqjs_context *context);

/*
 * The policy is deliberately opaque to QuickJS. Lua owns the allow-list and
 * the callback below is the only host capability exposed to the engine.
 */
LQJS_EXPORT int lqjs_context_install_host_policy_json(lqjs_context *context,
                                                       const uint8_t *policy_json,
                                                       size_t policy_len,
                                                       lqjs_error *error_out);

LQJS_EXPORT int lqjs_context_install_host_callback(lqjs_context *context,
                                                    lqjs_host_call_fn callback,
                                                    void *opaque,
                                                    lqjs_error *error_out);

/*
 * Evaluates source as a global script. input_json is exposed as __lekoInput.
 * On success result_json is heap allocated and must be returned with
 * lqjs_buffer_free(). It is a JSON envelope: {"kind":"json","value":...}
 * or {"kind":"undefined"}; this preserves JS undefined without leaking
 * internal JSValue representation over FFI.
 */
LQJS_EXPORT int lqjs_eval_json(lqjs_context *context,
                               const uint8_t *script, size_t script_len,
                               const uint8_t *input_json, size_t input_len,
                               const lqjs_eval_options *options,
                               uint8_t **result_json, size_t *result_len,
                               lqjs_error *error_out);
LQJS_EXPORT void lqjs_buffer_free(void *buffer);

#endif
