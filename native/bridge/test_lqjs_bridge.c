/* Native acceptance test. It is intentionally not run unless a local C
 * compiler has built liblekoqjs; see build-host.ps1. */
#include "lqjs_bridge.h"

#include <stdio.h>
#include <string.h>

static int failures = 0;

static int host_answer(void *opaque, const uint8_t *request, size_t request_len,
                       const uint8_t **response, size_t *response_len) {
    static const uint8_t accepted[] = "{\"ok\":true,\"value\":21}";
    static const uint8_t rejected[] = "{\"ok\":false,\"error\":\"unknown method\"}";
    (void)opaque;
    if (request && request_len >= 16 && strstr((const char *)request, "java.answer")) {
        *response = accepted;
        *response_len = sizeof(accepted) - 1;
    } else {
        *response = rejected;
        *response_len = sizeof(rejected) - 1;
    }
    return 0;
}

static void expect(int condition, const char *message) {
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message); failures++; }
}

static int eval(lqjs_context *context, const char *script, const char *input,
                uint64_t timeout_ms, size_t max_result_bytes,
                uint8_t **output, size_t *output_size, lqjs_error *error) {
    lqjs_eval_options options;
    memset(&options, 0, sizeof(options));
    options.abi_version = LQJS_ABI_VERSION;
    options.timeout_ms = timeout_ms;
    options.max_result_bytes = max_result_bytes;
    return lqjs_eval_json(context, (const uint8_t *)script, strlen(script),
                          (const uint8_t *)input, strlen(input), &options,
                          output, output_size, error);
}

int main(void) {
    lqjs_runtime_options runtime_options;
    lqjs_error error;
    lqjs_runtime *runtime;
    lqjs_context *context;
    uint8_t *output = NULL;
    size_t output_size = 0;
    int status;

    memset(&runtime_options, 0, sizeof(runtime_options));
    runtime_options.abi_version = LQJS_ABI_VERSION;
    runtime_options.memory_limit_bytes = 8u * 1024u * 1024u;
    runtime_options.max_stack_bytes = 512u * 1024u;
    runtime = lqjs_runtime_new(&runtime_options, &error);
    expect(runtime != NULL, "create runtime");
    if (!runtime) return 1;
    context = lqjs_context_new(runtime, &error);
    expect(context != NULL, "create context");
    if (!context) { lqjs_runtime_free(runtime); return 1; }
    expect(lqjs_abi_version() == LQJS_ABI_VERSION, "ABI version query");
    expect(strcmp(lqjs_engine_version(), LQJS_ENGINE_VERSION) == 0, "engine version query");
    expect(strcmp(lqjs_bridge_version(), LQJS_BRIDGE_VERSION) == 0, "bridge version query");
    status = lqjs_context_install_host_callback(context, host_answer, NULL, &error);
    expect(status == LQJS_STATUS_OK, "install host callback");

    status = eval(context, "__lekoHostCall('java.answer') * 2", "{}", 100, 1024, &output, &output_size, &error);
    expect(status == LQJS_STATUS_OK, "host callback evaluation succeeds");
    expect(output && strstr((const char *)output, "\"value\":42"), "host callback JSON result");
    lqjs_buffer_free(output); output = NULL;

    status = eval(context, "__lekoInput.answer * 2", "{\"answer\":21}", 100, 1024, &output, &output_size, &error);
    expect(status == LQJS_STATUS_OK, "real evaluation succeeds");
    expect(output && strstr((const char *)output, "\"value\":42"), "real evaluation JSON result");
    lqjs_buffer_free(output); output = NULL;

    status = eval(context, "__lekoInput.a", "{\"__lekoFunctions\":{},\"a\":2,\"book\":{\"__leko_kind\":\"undefined\"},\"chapter\":{\"__leko_kind\":\"undefined\"},\"context\":{\"__leko_kind\":\"undefined\"},\"currentResponse\":{\"__leko_kind\":\"undefined\"},\"result\":{\"__leko_kind\":\"undefined\"},\"source\":{\"__leko_kind\":\"undefined\"}}", 100, 1024, &output, &output_size, &error);
    expect(status == LQJS_STATUS_OK, "long JSON input succeeds");
    lqjs_buffer_free(output); output = NULL;

    status = eval(context, "throw new Error('bridge-boom')", "{}", 100, 1024, &output, &output_size, &error);
    expect(status == LQJS_STATUS_EXCEPTION, "exception classification");
    expect(error.message && strstr(error.message, "bridge-boom"), "exception message kept");

    status = eval(context, "while (true) {}", "{}", 20, 1024, &output, &output_size, &error);
    expect(status == LQJS_STATUS_TIMEOUT, "interrupt timeout classification");

    expect(lqjs_runtime_set_memory_limit(runtime, 256u * 1024u) == LQJS_STATUS_OK, "set memory limit");
    status = eval(context, "new Array(10000000).fill('x')", "{}", 100, 1024, &output, &output_size, &error);
    expect(status == LQJS_STATUS_MEMORY_LIMIT, "memory limit classification");

    lqjs_context_free(context);
    lqjs_runtime_free(runtime);
    if (failures) return 1;
    puts("lqjs bridge real-engine tests: OK");
    return 0;
}
