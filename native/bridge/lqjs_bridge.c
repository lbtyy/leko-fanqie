/* See lqjs_bridge.h for the ABI contract.  The bridge owns every QuickJS
 * value and exposes only a JSON host-call boundary to LuaJIT.  No filesystem,
 * process, Android or WebView primitive is linked into the QuickJS context. */
#include "lqjs_bridge.h"
#include "quickjs.h"

#include <stdlib.h>
#include <string.h>
#ifdef LQJS_DEBUG_INPUT
#include <stdio.h>
#endif

#if defined(_WIN32)
#include <windows.h>
static uint64_t lqjs_now_ms(void) { return (uint64_t)GetTickCount64(); }
#else
#include <time.h>
static uint64_t lqjs_now_ms(void) {
    struct timespec value;
    if (clock_gettime(CLOCK_MONOTONIC, &value) != 0) return 0;
    return (uint64_t)value.tv_sec * 1000u + (uint64_t)value.tv_nsec / 1000000u;
}
#endif

#define LQJS_ERROR_CAPACITY 2048u

struct lqjs_runtime {
    JSRuntime *quickjs;
    uint64_t deadline_ms;
    size_t peak_memory_bytes;
};

struct lqjs_context {
    lqjs_runtime *owner;
    JSContext *quickjs;
    char message[LQJS_ERROR_CAPACITY];
    char stack[LQJS_ERROR_CAPACITY];
    lqjs_host_call_fn host_callback;
    void *host_opaque;
};

/* Runtime construction has no context to own an error string. KOReader calls
 * this from one source-operation thread, so this fallback is intentionally
 * process-local and documented as borrowed until the next constructor call. */
static char lqjs_constructor_error[LQJS_ERROR_CAPACITY];

static void lqjs_clear_error(lqjs_error *error_out) {
    if (!error_out) return;
    memset(error_out, 0, sizeof(*error_out));
    error_out->abi_version = LQJS_ABI_VERSION;
    error_out->status = LQJS_STATUS_OK;
}

static void lqjs_copy_text(char *target, size_t target_size, const char *source, size_t source_len) {
    size_t count = source_len;
    if (!target || target_size == 0) return;
    if (!source) { target[0] = '\0'; return; }
    if (count >= target_size) count = target_size - 1;
    if (count > 0) memcpy(target, source, count);
    target[count] = '\0';
}

static void lqjs_set_constructor_error(lqjs_error *error_out, uint32_t status, const char *message) {
    size_t length = message ? strlen(message) : 0;
    lqjs_copy_text(lqjs_constructor_error, sizeof(lqjs_constructor_error), message, length);
    lqjs_clear_error(error_out);
    if (!error_out) return;
    error_out->status = status;
    error_out->message = lqjs_constructor_error;
    error_out->message_len = strlen(lqjs_constructor_error);
}

static void lqjs_set_context_error(lqjs_context *context, lqjs_error *error_out,
                                   uint32_t status, const char *message,
                                   const char *stack) {
    lqjs_clear_error(error_out);
    if (!context) {
        lqjs_set_constructor_error(error_out, status, message);
        return;
    }
    lqjs_copy_text(context->message, sizeof(context->message), message,
                   message ? strlen(message) : 0);
    lqjs_copy_text(context->stack, sizeof(context->stack), stack, stack ? strlen(stack) : 0);
    if (!error_out) return;
    error_out->status = status;
    error_out->message = context->message;
    error_out->message_len = strlen(context->message);
    error_out->stack = context->stack;
    error_out->stack_len = strlen(context->stack);
}

static int lqjs_interrupt(JSRuntime *runtime, void *opaque) {
    lqjs_runtime *bridge = (lqjs_runtime *)opaque;
    (void)runtime;
    return bridge && bridge->deadline_ms != 0 && lqjs_now_ms() >= bridge->deadline_ms;
}

static uint32_t lqjs_exception_status(lqjs_context *context, const char *message) {
    if (context && context->owner && context->owner->deadline_ms != 0
            && lqjs_now_ms() >= context->owner->deadline_ms) return LQJS_STATUS_TIMEOUT;
    if (message && (strstr(message, "out of memory") || strstr(message, "Out of memory"))) {
        return LQJS_STATUS_MEMORY_LIMIT;
    }
    if (message && (strstr(message, "host-denied:") || strstr(message, "host-unsupported:"))) {
        return LQJS_STATUS_HOST_DENIED;
    }
    return LQJS_STATUS_EXCEPTION;
}

static void lqjs_capture_exception(lqjs_context *context, lqjs_error *error_out) {
    JSValue exception = JS_GetException(context->quickjs);
    JSValue stack_value = JS_UNDEFINED;
    const char *message = JS_ToCString(context->quickjs, exception);
    const char *stack = NULL;
    uint32_t status = lqjs_exception_status(context, message);
    if (!JS_IsNull(exception) && !JS_IsUndefined(exception)) {
        stack_value = JS_GetPropertyStr(context->quickjs, exception, "stack");
        if (!JS_IsException(stack_value) && !JS_IsUndefined(stack_value) && !JS_IsNull(stack_value)) {
            stack = JS_ToCString(context->quickjs, stack_value);
        }
    }
    lqjs_set_context_error(context, error_out, status,
                           message ? message : "QuickJS exception", stack);
    if (stack) JS_FreeCString(context->quickjs, stack);
    JS_FreeValue(context->quickjs, stack_value);
    if (message) JS_FreeCString(context->quickjs, message);
    JS_FreeValue(context->quickjs, exception);
}

static int lqjs_copy_result(lqjs_context *context, JSValue value,
                            size_t max_result_bytes, uint8_t **result_json,
                            size_t *result_len, lqjs_error *error_out) {
    static const char undefined_result[] = "{\"kind\":\"undefined\"}";
    static const char prefix[] = "{\"kind\":\"json\",\"value\":";
    static const char suffix[] = "}";
    JSValue json = JS_UNDEFINED;
    const char *text = NULL;
    size_t text_len = 0, total = 0;
    uint8_t *output;

    if (JS_IsUndefined(value)) {
        total = sizeof(undefined_result) - 1;
        if (max_result_bytes && total > max_result_bytes) {
            lqjs_set_context_error(context, error_out, LQJS_STATUS_MEMORY_LIMIT, "JSON result exceeds configured limit", NULL);
            return LQJS_STATUS_MEMORY_LIMIT;
        }
        output = (uint8_t *)malloc(total);
        if (!output) {
            lqjs_set_context_error(context, error_out, LQJS_STATUS_MEMORY_LIMIT, "native result allocation failed", NULL);
            return LQJS_STATUS_MEMORY_LIMIT;
        }
        memcpy(output, undefined_result, total);
        *result_json = output;
        *result_len = total;
        return LQJS_STATUS_OK;
    }

    json = JS_JSONStringify(context->quickjs, value, JS_UNDEFINED, JS_UNDEFINED);
    if (JS_IsException(json)) {
        lqjs_capture_exception(context, error_out);
        return (int)error_out->status;
    }
    if (JS_IsUndefined(json)) {
        JS_FreeValue(context->quickjs, json);
        return lqjs_copy_result(context, JS_UNDEFINED, max_result_bytes, result_json, result_len, error_out);
    }
    text = JS_ToCStringLen(context->quickjs, &text_len, json);
    if (!text) {
        JS_FreeValue(context->quickjs, json);
        lqjs_set_context_error(context, error_out, LQJS_STATUS_MEMORY_LIMIT, "cannot encode JSON result", NULL);
        return LQJS_STATUS_MEMORY_LIMIT;
    }
    total = (sizeof(prefix) - 1) + text_len + (sizeof(suffix) - 1);
    if (max_result_bytes && total > max_result_bytes) {
        JS_FreeCString(context->quickjs, text);
        JS_FreeValue(context->quickjs, json);
        lqjs_set_context_error(context, error_out, LQJS_STATUS_MEMORY_LIMIT, "JSON result exceeds configured limit", NULL);
        return LQJS_STATUS_MEMORY_LIMIT;
    }
    output = (uint8_t *)malloc(total);
    if (!output) {
        JS_FreeCString(context->quickjs, text);
        JS_FreeValue(context->quickjs, json);
        lqjs_set_context_error(context, error_out, LQJS_STATUS_MEMORY_LIMIT, "native result allocation failed", NULL);
        return LQJS_STATUS_MEMORY_LIMIT;
    }
    memcpy(output, prefix, sizeof(prefix) - 1);
    memcpy(output + sizeof(prefix) - 1, text, text_len);
    memcpy(output + sizeof(prefix) - 1 + text_len, suffix, sizeof(suffix) - 1);
    JS_FreeCString(context->quickjs, text);
    JS_FreeValue(context->quickjs, json);
    *result_json = output;
    *result_len = total;
    return LQJS_STATUS_OK;
}

uint32_t lqjs_abi_version(void) { return LQJS_ABI_VERSION; }

const char *lqjs_engine_version(void) { return LQJS_ENGINE_VERSION; }

const char *lqjs_bridge_version(void) { return LQJS_BRIDGE_VERSION; }

lqjs_runtime *lqjs_runtime_new(const lqjs_runtime_options *options, lqjs_error *error_out) {
    lqjs_runtime *bridge;
    lqjs_clear_error(error_out);
    if (!options || options->abi_version != LQJS_ABI_VERSION) {
        lqjs_set_constructor_error(error_out, LQJS_STATUS_INVALID_ARGUMENT, "lqjs runtime ABI mismatch");
        return NULL;
    }
    bridge = (lqjs_runtime *)calloc(1, sizeof(*bridge));
    if (!bridge) {
        lqjs_set_constructor_error(error_out, LQJS_STATUS_MEMORY_LIMIT, "cannot allocate lqjs runtime wrapper");
        return NULL;
    }
    bridge->quickjs = JS_NewRuntime();
    if (!bridge->quickjs) {
        free(bridge);
        lqjs_set_constructor_error(error_out, LQJS_STATUS_MEMORY_LIMIT, "QuickJS runtime allocation failed");
        return NULL;
    }
    if (options->memory_limit_bytes) JS_SetMemoryLimit(bridge->quickjs, options->memory_limit_bytes);
    if (options->max_stack_bytes) JS_SetMaxStackSize(bridge->quickjs, options->max_stack_bytes);
    JS_SetInterruptHandler(bridge->quickjs, lqjs_interrupt, bridge);
    return bridge;
}

void lqjs_runtime_free(lqjs_runtime *runtime) {
    if (!runtime) return;
    if (runtime->quickjs) JS_FreeRuntime(runtime->quickjs);
    free(runtime);
}

int lqjs_runtime_set_memory_limit(lqjs_runtime *runtime, size_t bytes) {
    if (!runtime || !runtime->quickjs) return LQJS_STATUS_INVALID_ARGUMENT;
    JS_SetMemoryLimit(runtime->quickjs, bytes);
    return LQJS_STATUS_OK;
}

int lqjs_runtime_set_stack_limit(lqjs_runtime *runtime, size_t bytes) {
    if (!runtime || !runtime->quickjs) return LQJS_STATUS_INVALID_ARGUMENT;
    JS_SetMaxStackSize(runtime->quickjs, bytes);
    return LQJS_STATUS_OK;
}

int lqjs_runtime_set_timeout_ms(lqjs_runtime *runtime, uint64_t timeout_ms) {
    if (!runtime || !runtime->quickjs) return LQJS_STATUS_INVALID_ARGUMENT;
    runtime->deadline_ms = timeout_ms ? lqjs_now_ms() + timeout_ms : 0;
    return LQJS_STATUS_OK;
}

void lqjs_runtime_collect_garbage(lqjs_runtime *runtime) {
    if (runtime && runtime->quickjs) {
        JS_RunGC(runtime->quickjs);
        lqjs_runtime_memory_usage(runtime, NULL, NULL);
    }
}

void lqjs_runtime_memory_usage(lqjs_runtime *runtime, size_t *current, size_t *peak) {
    JSMemoryUsage usage;
    size_t used = 0;
    if (runtime && runtime->quickjs) {
        memset(&usage, 0, sizeof(usage));
        JS_ComputeMemoryUsage(runtime->quickjs, &usage);
        if (usage.memory_used_size > 0) used = (size_t)usage.memory_used_size;
        if (used > runtime->peak_memory_bytes) runtime->peak_memory_bytes = used;
    }
    if (current) *current = used;
    if (peak) *peak = runtime ? runtime->peak_memory_bytes : 0;
}

lqjs_context *lqjs_context_new(lqjs_runtime *runtime, lqjs_error *error_out) {
    lqjs_context *bridge;
    lqjs_clear_error(error_out);
    if (!runtime || !runtime->quickjs) {
        lqjs_set_constructor_error(error_out, LQJS_STATUS_INVALID_ARGUMENT, "runtime is required");
        return NULL;
    }
    bridge = (lqjs_context *)calloc(1, sizeof(*bridge));
    if (!bridge) {
        lqjs_set_constructor_error(error_out, LQJS_STATUS_MEMORY_LIMIT, "cannot allocate lqjs context wrapper");
        return NULL;
    }
    bridge->owner = runtime;
    bridge->quickjs = JS_NewContext(runtime->quickjs);
    if (!bridge->quickjs) {
        free(bridge);
        lqjs_set_constructor_error(error_out, LQJS_STATUS_MEMORY_LIMIT, "QuickJS context allocation failed");
        return NULL;
    }
    JS_SetContextOpaque(bridge->quickjs, bridge);
    return bridge;
}

void lqjs_context_free(lqjs_context *context) {
    if (!context) return;
    if (context->quickjs) JS_FreeContext(context->quickjs);
    free(context);
}

int lqjs_context_install_host_policy_json(lqjs_context *context,
                                           const uint8_t *policy_json,
                                           size_t policy_len,
                                           lqjs_error *error_out) {
    /* Policy parsing remains on the Lua side.  This function is retained as
     * an explicit capability gate so callers can verify that the context is
     * alive before installing a host callback.  The native bridge never
     * interprets policy JSON as a filesystem or process capability. */
    (void)policy_json;
    (void)policy_len;
    if (!context || !context->quickjs) {
        lqjs_set_context_error(context, error_out, LQJS_STATUS_INVALID_ARGUMENT, "context is required", NULL);
        return LQJS_STATUS_INVALID_ARGUMENT;
    }
    lqjs_clear_error(error_out);
    return LQJS_STATUS_OK;
}

static JSValue lqjs_host_call(JSContext *ctx, JSValueConst this_val,
                              int argc, JSValueConst *argv) {
    lqjs_context *context = (lqjs_context *)JS_GetContextOpaque(ctx);
    JSValue request = JS_UNDEFINED;
    JSValue args = JS_UNDEFINED;
    JSValue response_value = JS_UNDEFINED;
    JSValue ok_value = JS_UNDEFINED;
    JSValue error_value = JS_UNDEFINED;
    const char *request_text = NULL;
    const char *error_text = NULL;
    const uint8_t *response = NULL;
    size_t request_len = 0, response_len = 0;
    int status = 0;
    (void)this_val;

    if (!context || !context->host_callback) {
        return JS_ThrowInternalError(ctx, "host-denied: no host callback installed");
    }
    if (argc < 1) {
        return JS_ThrowTypeError(ctx, "host-unsupported: method name is required");
    }

    request = JS_NewObject(ctx);
    if (JS_IsException(request)) return request;
    if (JS_SetPropertyStr(ctx, request, "method", JS_DupValue(ctx, argv[0])) < 0) {
        JS_FreeValue(ctx, request);
        return JS_EXCEPTION;
    }
    args = JS_NewArray(ctx);
    if (JS_IsException(args)) {
        JS_FreeValue(ctx, request);
        return args;
    }
    for (int index = 1; index < argc; index++) {
        if (JS_SetPropertyUint32(ctx, args, (uint32_t)(index - 1),
                                 JS_DupValue(ctx, argv[index])) < 0) {
            JS_FreeValue(ctx, args);
            JS_FreeValue(ctx, request);
            return JS_EXCEPTION;
        }
    }
    if (JS_SetPropertyStr(ctx, request, "args", args) < 0) {
        JS_FreeValue(ctx, args);
        JS_FreeValue(ctx, request);
        return JS_EXCEPTION;
    }

    {
        JSValue request_json = JS_JSONStringify(ctx, request, JS_UNDEFINED, JS_UNDEFINED);
        JS_FreeValue(ctx, request);
        if (JS_IsException(request_json)) return request_json;
        if (JS_IsUndefined(request_json)) {
            JS_FreeValue(ctx, request_json);
            return JS_ThrowTypeError(ctx, "host-unsupported: host request is not JSON serializable");
        }
        request_text = JS_ToCStringLen(ctx, &request_len, request_json);
        JS_FreeValue(ctx, request_json);
        if (!request_text) return JS_EXCEPTION;
    }
    status = context->host_callback(context->host_opaque,
                                    (const uint8_t *)request_text, request_len,
                                    &response, &response_len);
    if (status != 0 || !response) {
        JS_FreeCString(ctx, request_text);
        return JS_ThrowInternalError(ctx, "host-denied: host callback failed");
    }
    response_value = JS_ParseJSON(ctx, (const char *)response, response_len,
                                  "<leko-host-response>");
    JS_FreeCString(ctx, request_text);
    if (JS_IsException(response_value)) return response_value;

    if (JS_IsObject(response_value)) {
        ok_value = JS_GetPropertyStr(ctx, response_value, "ok");
        if (!JS_IsException(ok_value) && !JS_IsUndefined(ok_value)
                && JS_ToBool(ctx, ok_value) == 0) {
            error_value = JS_GetPropertyStr(ctx, response_value, "error");
            error_text = JS_ToCString(ctx, error_value);
            JS_FreeValue(ctx, error_value);
            JS_FreeValue(ctx, ok_value);
            JS_FreeValue(ctx, response_value);
            if (error_text) {
                JSValue thrown = JS_ThrowInternalError(ctx, "host-denied: %s", error_text);
                JS_FreeCString(ctx, error_text);
                return thrown;
            }
            return JS_ThrowInternalError(ctx, "host-denied: host rejected call");
        }
        JS_FreeValue(ctx, ok_value);
        ok_value = JS_UNDEFINED;
        {
            JSValue value = JS_GetPropertyStr(ctx, response_value, "value");
            if (!JS_IsException(value) && !JS_IsUndefined(value)) {
                JS_FreeValue(ctx, response_value);
                return value;
            }
            JS_FreeValue(ctx, value);
        }
    }
    return response_value;
}

int lqjs_context_install_host_callback(lqjs_context *context,
                                       lqjs_host_call_fn callback,
                                       void *opaque,
                                       lqjs_error *error_out) {
    JSValue global;
    JSValue function;
    if (!context || !context->quickjs || !callback) {
        lqjs_set_context_error(context, error_out, LQJS_STATUS_INVALID_ARGUMENT,
                               "context and host callback are required", NULL);
        return LQJS_STATUS_INVALID_ARGUMENT;
    }
    context->host_callback = callback;
    context->host_opaque = opaque;
    global = JS_GetGlobalObject(context->quickjs);
    function = JS_NewCFunction(context->quickjs, lqjs_host_call,
                               "__lekoHostCall", 1);
    if (JS_IsException(function)
            || JS_SetPropertyStr(context->quickjs, global, "__lekoHostCall", function) < 0) {
        JS_FreeValue(context->quickjs, global);
        lqjs_set_context_error(context, error_out, LQJS_STATUS_NATIVE_FAILURE,
                               "cannot install QuickJS host entrypoint", NULL);
        return LQJS_STATUS_NATIVE_FAILURE;
    }
    JS_FreeValue(context->quickjs, global);
    lqjs_clear_error(error_out);
    return LQJS_STATUS_OK;
}

int lqjs_eval_json(lqjs_context *context,
                   const uint8_t *script, size_t script_len,
                   const uint8_t *input_json, size_t input_len,
                   const lqjs_eval_options *options,
                   uint8_t **result_json, size_t *result_len,
                   lqjs_error *error_out) {
    JSValue input = JS_UNDEFINED, global = JS_UNDEFINED, value = JS_UNDEFINED;
    int status = LQJS_STATUS_OK;
    lqjs_clear_error(error_out);
    if (result_json) *result_json = NULL;
    if (result_len) *result_len = 0;
    if (!context || !context->quickjs || !context->owner || !script || !options
            || !result_json || !result_len || options->abi_version != LQJS_ABI_VERSION) {
        lqjs_set_context_error(context, error_out, LQJS_STATUS_INVALID_ARGUMENT, "invalid lqjs eval arguments", NULL);
        return LQJS_STATUS_INVALID_ARGUMENT;
    }
    if (input_len && !input_json) {
        lqjs_set_context_error(context, error_out, LQJS_STATUS_INVALID_ARGUMENT, "input_json pointer is null", NULL);
        return LQJS_STATUS_INVALID_ARGUMENT;
    }
    if (input_len) {
#ifdef LQJS_DEBUG_INPUT
        fprintf(stderr, "lqjs input_len=%zu tail=%02x %02x %02x\n", input_len,
                input_json[input_len - 3], input_json[input_len - 2], input_json[input_len - 1]);
#endif
        input = JS_ParseJSON(context->quickjs, (const char *)input_json, input_len, "<leko-input>");
    }
    else input = JS_NULL;
    if (JS_IsException(input)) {
        lqjs_capture_exception(context, error_out);
        return (int)error_out->status;
    }
    global = JS_GetGlobalObject(context->quickjs);
    if (JS_SetPropertyStr(context->quickjs, global, "__lekoInput", input) < 0) {
        JS_FreeValue(context->quickjs, global);
        lqjs_capture_exception(context, error_out);
        return (int)error_out->status;
    }
    /* JS_SetPropertyStr consumes input. */
    input = JS_UNDEFINED;
    JS_FreeValue(context->quickjs, global);
    global = JS_UNDEFINED;
    lqjs_runtime_set_timeout_ms(context->owner, options->timeout_ms);
    value = JS_Eval(context->quickjs, (const char *)script, script_len, "<leko-rule>", JS_EVAL_TYPE_GLOBAL);
    {
        int timed_out = context->owner->deadline_ms != 0
            && lqjs_now_ms() >= context->owner->deadline_ms;
        context->owner->deadline_ms = 0;
        if (JS_IsException(value)) {
            lqjs_capture_exception(context, error_out);
            if (timed_out && error_out) error_out->status = LQJS_STATUS_TIMEOUT;
            return (int)error_out->status;
        }
    }
    status = lqjs_copy_result(context, value, options->max_result_bytes, result_json, result_len, error_out);
    JS_FreeValue(context->quickjs, value);
    lqjs_runtime_memory_usage(context->owner, NULL, NULL);
    return status;
}

void lqjs_buffer_free(void *buffer) { free(buffer); }
