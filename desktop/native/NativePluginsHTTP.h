#ifndef NEXTCRM_NATIVE_PLUGINS_HTTP_H
#define NEXTCRM_NATIVE_PLUGINS_HTTP_H
#include <stddef.h>
#include <stdint.h>
typedef struct {
    const char *url, *method, *headers;
    const uint8_t *body;
    size_t body_length, maximum_response;
    long timeout_ms;
    int allow_private;
    /* Optional resolver result for deterministic tests. Every address is still
       checked, and the selected IP is pinned while retaining TLS hostname/SNI. */
    const char *resolved_addresses;
    int (*cancelled)(void *);
    void *context;
} NativePluginHTTPRequest;
typedef struct {
    int code;
    long status;
    uint8_t *body,*headers;
    size_t body_length,headers_length;
} NativePluginHTTPResult;
NativePluginHTTPResult native_plugin_http_perform(const NativePluginHTTPRequest *request);
void native_plugin_http_result_free(NativePluginHTTPResult *result);
#endif
