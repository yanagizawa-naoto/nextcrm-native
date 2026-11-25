#ifndef NEXTCRM_NATIVE_MAIL_TRANSPORT_H
#define NEXTCRM_NATIVE_MAIL_TRANSPORT_H
#include <stddef.h>
#include <stdint.h>

typedef struct {
    const char *url;
    const char *username;
    const char *password;
    const char *command;       /* IMAP only; never user-supplied command text. */
    const char *sender;        /* SMTP envelope, without display name. */
    const char *recipients;    /* Validated addresses separated by LF. */
    const uint8_t *upload;
    size_t upload_length;
    size_t maximum_response;
    int tls_mode;             /* 0: explicit plaintext, 1: STARTTLS, 2: TLS, 3: SMTP automatic STARTTLS */
    int allow_self_signed;
    int (*cancelled)(void *context);
    void *context;
    int stream_to_fd;         /* IMAP response spool; descriptor remains caller-owned. */
    int output_fd;
    int smtp_verify_only;     /* Authenticate and close, without MAIL/RCPT/DATA. */
} NativeMailRequest;

typedef struct {
    int code;                 /* libcurl code; negative: local validation */
    long server_code;
    uint8_t *body;
    size_t body_length;
    uint8_t *headers;
    size_t headers_length;
    size_t uploaded_bytes;    /* Nonzero means an SMTP result may be unknown. */
    size_t response_bytes;
} NativeMailResult;

NativeMailResult native_mail_perform(const NativeMailRequest *request);
void native_mail_result_free(NativeMailResult *result);
int native_mail_address_is_public(const char *address);
#endif
