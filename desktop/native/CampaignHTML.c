#include "CampaignHTML.h"
#include <libxml/HTMLparser.h>
#include <libxml/parser.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>
#include "CampaignHTMLEntities.inc"

const char *nextcrm_html_entity(const uint8_t *name,size_t count) {
    size_t low=0,high=sizeof(entities)/sizeof(entities[0]);
    while(low<high){size_t mid=low+(high-low)/2,n=strlen(entities[mid].name);int c=memcmp(name,entities[mid].name,count<n?count:n);
        if(!c)c=count<n?-1:count>n?1:0;
        if(c<0)high=mid;else if(c>0)low=mid+1;else return entities[mid].numeric;
    }
    return NULL;
}

struct NextCRMHTMLParser { htmlParserCtxtPtr parser; void *context; NextCRMHTMLEvent callback; int stopped; };
static void emit(NextCRMHTMLParser *p, int kind, const xmlChar *bytes, size_t count) {
    if (!p->stopped && !p->callback(p->context,kind,(const char *)bytes,count)) {
        p->stopped=1; if (p->parser) xmlStopParser(p->parser);
    }
}
static void start(void *ctx,const xmlChar *name,const xmlChar **attrs) {
    NextCRMHTMLParser *p=ctx; emit(p,1,name,xmlStrlen(name));
    if (attrs) for (size_t i=0; attrs[i] && attrs[i+1] && !p->stopped; i+=2) {
        emit(p,2,attrs[i],xmlStrlen(attrs[i])); emit(p,3,attrs[i+1],xmlStrlen(attrs[i+1]));
    }
    emit(p,4,NULL,0);
}
static void end(void *ctx,const xmlChar *name) { emit(ctx,6,name,xmlStrlen(name)); }
static void text(void *ctx,const xmlChar *bytes,int count) { if(count>0) emit(ctx,5,bytes,(size_t)count); }
static xmlParserInputPtr no_entity(void *ctx,const xmlChar *publicID,const xmlChar *systemID) { (void)ctx;(void)publicID;(void)systemID;return NULL; }
NextCRMHTMLParser *nextcrm_html_create(void *context,NextCRMHTMLEvent callback) {
    NextCRMHTMLParser *p=calloc(1,sizeof(*p)); if(!p)return NULL;
    p->context=context;p->callback=callback;
    htmlSAXHandler sax;memset(&sax,0,sizeof(sax));sax.startElement=start;sax.endElement=end;sax.characters=text;sax.cdataBlock=text;sax.resolveEntity=no_entity;
    // A SAX HTML parser never builds a DOM. Explicit UTF-8 also preserves
    // Japanese/emoji without expanding each scalar to a numeric entity.
    p->parser=htmlCreatePushParserCtxt(&sax,p,NULL,0,NULL,XML_CHAR_ENCODING_UTF8);
    if(!p->parser){free(p);return NULL;}
    htmlCtxtUseOptions(p->parser,HTML_PARSE_RECOVER|HTML_PARSE_NONET|HTML_PARSE_NOERROR|HTML_PARSE_NOWARNING|HTML_PARSE_COMPACT|HTML_PARSE_NODEFDTD|HTML_PARSE_IGNORE_ENC);
    return p;
}
int nextcrm_html_feed(NextCRMHTMLParser *p,const uint8_t *bytes,size_t count,int final) {
    if(!p || p->stopped || count>INT_MAX)return -1;
    int code=htmlParseChunk(p->parser,(const char *)bytes,(int)count,final);
    if(p->stopped)return -1;
    // HTML recovery reports unknown/misnested tags without making output
    // unsafe: every emitted tag, attribute and text fragment is filtered.
    // Allocation/encoding/depth failures must never publish a partial mail.
    if(code==XML_ERR_NO_MEMORY || code==XML_ERR_INTERNAL_ERROR || code==XML_ERR_INVALID_ENCODING || code==XML_ERR_UNSUPPORTED_ENCODING)return -1;
    return 0;
}
void nextcrm_html_destroy(NextCRMHTMLParser *p) { if(p){htmlFreeParserCtxt(p->parser);free(p);} }
