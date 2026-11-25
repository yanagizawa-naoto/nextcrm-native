#ifndef NEXTCRM_CAMPAIGN_HTML_H
#define NEXTCRM_CAMPAIGN_HTML_H
#include <stddef.h>
#include <stdint.h>
// 1 start-name, 2 attribute-name, 3 attribute-value, 4 end-start,
// 5 text, 6 end-name. Returning 0 aborts parsing. Buffers are borrowed.
typedef int (*NextCRMHTMLEvent)(void *, int, const char *, size_t);
typedef struct NextCRMHTMLParser NextCRMHTMLParser;
NextCRMHTMLParser *nextcrm_html_create(void *context, NextCRMHTMLEvent callback);
int nextcrm_html_feed(NextCRMHTMLParser *, const uint8_t *, size_t, int final);
void nextcrm_html_destroy(NextCRMHTMLParser *);
const char *nextcrm_html_entity(const uint8_t *name, size_t count);
#endif
