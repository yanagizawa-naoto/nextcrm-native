#include "NativeMailTransport.h"
#include <curl/curl.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

/* Use the system library: no resident Node process, shell, password arguments,
 * proxy environment, redirects, or unbounded response buffer. */
static pthread_once_t once = PTHREAD_ONCE_INIT;
static CURLcode initialized;
static void initialize(void) { initialized = curl_global_init(CURL_GLOBAL_DEFAULT); }

static int ipv4_public(const uint8_t *b) {
    if (b[0] == 0 || b[0] == 10 || b[0] == 127 || b[0] >= 224) return 0;
    if (b[0] == 100 && b[1] >= 64 && b[1] <= 127) return 0;
    if (b[0] == 169 && b[1] == 254) return 0;
    if (b[0] == 172 && b[1] >= 16 && b[1] <= 31) return 0;
    if (b[0] == 192 && (b[1] == 168 || (b[1] == 0 && (b[2] == 0 || b[2] == 2)) || (b[1] == 88 && b[2] == 99))) return 0;
    if (b[0] == 198 && (b[1] == 18 || b[1] == 19 || (b[1] == 51 && b[2] == 100))) return 0;
    if (b[0] == 203 && b[1] == 0 && b[2] == 113) return 0;
    return 1;
}
int native_mail_address_is_public(const char *address) {
    struct in_addr a4; struct in6_addr a6;
    if (!address) return 0;
    if (inet_pton(AF_INET,address,&a4) == 1) return ipv4_public((uint8_t *)&a4);
    if (inet_pton(AF_INET6,address,&a6) != 1) return 0;
    const uint8_t *b = a6.s6_addr;
    if (IN6_IS_ADDR_V4MAPPED(&a6)) return ipv4_public(b + 12);
    if ((b[0] & 0xe0) != 0x20) return 0;
    if (b[0] == 0x20 && b[1] == 0x02) return 0; /* 6to4 */
    if (b[0] == 0x20 && b[1] == 0x01 && ((b[2] == 0 && b[3] == 0) || (b[2] == 0x0d && b[3] == 0xb8))) return 0;
    return 1;
}
static int test_loopback(const char *address) {
#ifdef NATIVE_MAIL_TRANSPORT_TESTING
    return !strcmp(address,"127.0.0.1") || !strcmp(address,"::1");
#else
    (void)address; return 0;
#endif
}
static int line_valid(const char *s, size_t maximum, int empty) {
    if (!s || (!empty && !*s) || strnlen(s,maximum+1) > maximum) return 0;
    for (const unsigned char *p=(const unsigned char *)s;*p;p++) if (*p < 32 || *p == 127) return 0;
    return 1;
}
typedef struct {
    NativeMailResult *result;
    const NativeMailRequest *request;
    size_t offset;
    int limit_hit, cancelled, smtp_starttls, tls_refused;
    int needs_utf8, utf8_refused, ehlo, utf8_supported, tls_advertised, tls_started;
} Transfer;
static int cancel_check(Transfer *t) {
    if (t->request->cancelled && t->request->cancelled(t->request->context)) t->cancelled=1;
    return t->cancelled;
}
static size_t append(uint8_t **bytes,size_t *length,size_t limit,const void *data,size_t n,Transfer *t) {
    if (cancel_check(t)) return 0;
    if (*length > limit || n > limit-*length) { t->limit_hit=1; return 0; }
    if (!n) return 0;
    uint8_t *next=realloc(*bytes,*length+n);
    if (!next) return 0;
    memcpy(next+*length,data,n); *bytes=next; *length+=n; return n;
}
static size_t body_write(char *p,size_t size,size_t count,void *context) {
    Transfer *t=context; if (size && count > SIZE_MAX/size) return 0;
    return append(&t->result->body,&t->result->body_length,t->request->maximum_response,p,size*count,t);
}
static size_t header_write(char *p,size_t size,size_t count,void *context) {
    Transfer *t=context; if (size && count > SIZE_MAX/size) return 0;
    size_t length=size*count;
    // SMTP automatic mode permits servers without STARTTLS, but an advertised
    // upgrade must succeed. Stop before libcurl TRY could fall back to AUTH.
    if (t->smtp_starttls) {
        if (size*count < 4 || strncmp(p,"220",3)) { t->tls_refused=1; return 0; }
        if (p[3]==' ') t->smtp_starttls=0;
    }
    if (t->ehlo && length>=4) {
        if (length>=14 && !strncmp(p,"250",3) && !strncasecmp(p+4,"SMTPUTF8",8) && (p[12]=='\r' || p[12]==' ')) t->utf8_supported=1;
        if (length>=14 && !strncmp(p,"250",3) && !strncasecmp(p+4,"STARTTLS",8) && (p[12]=='\r' || p[12]==' ')) t->tls_advertised=1;
        if (p[3]==' ') {
            t->ehlo=0;
            int will_upgrade=(t->request->tls_mode==1 || t->request->tls_mode==3) && t->tls_advertised && !t->tls_started;
            // libcurl 8.7 can otherwise send UTF-8 without this capability.
            // Fail before AUTH/MAIL/DATA, and re-check after every TLS upgrade.
            if (t->needs_utf8 && !t->utf8_supported && !will_upgrade) { t->utf8_refused=1; return 0; }
        }
    }
    size_t limit=t->request->maximum_response < 262144 ? t->request->maximum_response : 262144;
    return append(&t->result->headers,&t->result->headers_length,limit,p,size*count,t);
}
static int smtp_debug(CURL *curl,curl_infotype kind,char *data,size_t length,void *context) {
    (void)curl; Transfer *t=context;
    if (kind==CURLINFO_HEADER_OUT) {
        // Keep only the current SMTP reply, rather than accumulating one reply
        // for every RCPT command. The per-reply byte limit still applies.
        t->result->headers_length=0;
        if (length>=5 && (!memcmp(data,"EHLO ",5) || !memcmp(data,"HELO ",5))) { t->ehlo=1; t->utf8_supported=0; t->tls_advertised=0; }
        if (length==10 && !memcmp(data,"STARTTLS\r\n",10)) { t->tls_started=1; if(t->request->tls_mode==3) t->smtp_starttls=1; }
    }
    // Suppress all debug output, including credentials and message contents.
    return 0;
}
static size_t body_read(char *p,size_t size,size_t count,void *context) {
    Transfer *t=context; if (cancel_check(t)) return CURL_READFUNC_ABORT;
    if (size && count > SIZE_MAX/size) return CURL_READFUNC_ABORT;
    size_t available=t->request->upload_length-t->offset, n=size*count;
    if (n > available) n=available;
    if (n) memcpy(p,t->request->upload+t->offset,n);
    t->offset+=n; t->result->uploaded_bytes=t->offset; return n;
}
static int progress(void *context,curl_off_t a,curl_off_t b,curl_off_t c,curl_off_t d) {
    (void)a;(void)b;(void)c;(void)d; return cancel_check(context);
}

/* CONNECT_ONLY completes libcurl's IMAP authentication/STARTTLS phase. We then
 * frame the read-only command ourselves: CUSTOMREQUEST's line parser cannot
 * distinguish an arbitrary mail literal from a tagged server response. */
typedef struct {
    CURL *curl;
    curl_socket_t socket;
    Transfer *transfer;
    unsigned char buffer[16384];
    size_t begin,end;
    double deadline;
} MailReader;
static double monotonic_now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t); return (double)t.tv_sec+(double)t.tv_nsec/1000000000.0; }
static int raw_wait(MailReader *reader,short events) {
    if (cancel_check(reader->transfer)) return -5;
    if (monotonic_now() >= reader->deadline) return CURLE_OPERATION_TIMEDOUT;
    struct pollfd fd={.fd=reader->socket,.events=events};
    int status=poll(&fd,1,100);
    if (status < 0 && errno != EINTR) return CURLE_RECV_ERROR;
    return 0;
}
static int raw_send(MailReader *reader,const char *data,size_t length) {
    size_t offset=0;
    while (offset < length) {
        if (cancel_check(reader->transfer)) return -5;
        if (monotonic_now() >= reader->deadline) return CURLE_OPERATION_TIMEDOUT;
        size_t count=0; CURLcode code=curl_easy_send(reader->curl,data+offset,length-offset,&count);
        if (code == CURLE_AGAIN) { int status=raw_wait(reader,POLLOUT); if(status) return status; continue; }
        if (code != CURLE_OK || !count) return code != CURLE_OK ? (int)code : CURLE_SEND_ERROR;
        offset+=count;
    }
    return 0;
}
static int raw_capture(Transfer *t,int selection,const unsigned char *bytes,size_t length) {
    if (!length) return 0;
    if (cancel_check(t)) return -5;
    if (selection) {
        if (append(&t->result->headers,&t->result->headers_length,262144,bytes,length,t) != length) return t->limit_hit ? -4 : CURLE_WRITE_ERROR;
        return 0;
    }
    if (length > t->request->maximum_response-t->result->response_bytes) { t->limit_hit=1; return -4; }
    if (t->request->stream_to_fd) {
        size_t offset=0;
        while(offset < length) {
            ssize_t written=write(t->request->output_fd,bytes+offset,length-offset);
            if (written < 0 && errno==EINTR) continue;
            if (written <= 0) return CURLE_WRITE_ERROR;
            offset+=(size_t)written;
        }
    } else if (append(&t->result->body,&t->result->body_length,t->request->maximum_response,bytes,length,t) != length) return t->limit_hit ? -4 : CURLE_WRITE_ERROR;
    t->result->response_bytes+=length; return 0;
}
static int response_allows_literal(const char *prefix) {
    if (!strncasecmp(prefix,"* LIST ",7) || !strncasecmp(prefix,"* STATUS ",9)) return 1;
    if (strncmp(prefix,"* ",2)) return 0;
    const char *p=prefix+2; if (*p<'0' || *p>'9') return 0;
    while (*p>='0' && *p<='9') p++;
    return !strncasecmp(p," FETCH ",7);
}
static int command_valid(const char *command) {
    if (!command) return 1;
    if (!strcmp(command,"NOOP") || !strncmp(command,"LIST ",5) || !strncmp(command,"STATUS ",7) || !strncmp(command,"UID SEARCH ",11)) return 1;
    return !strncmp(command,"UID FETCH ",10) && strstr(command,"BODY.PEEK[") && !strstr(command,"BODY[");
}
static int raw_response(MailReader *reader,const char *tag,int selection) {
    char prefix[129]={0}, tail[128]; size_t line_length=0,literal=0;
    int continuation=0; size_t tag_length=strlen(tag);
    for (;;) {
        if (cancel_check(reader->transfer)) return -5;
        if (monotonic_now() >= reader->deadline) return CURLE_OPERATION_TIMEDOUT;
        if (reader->begin==reader->end) {
            size_t count=0; CURLcode code=curl_easy_recv(reader->curl,reader->buffer,sizeof(reader->buffer),&count);
            if (code==CURLE_AGAIN) { int status=raw_wait(reader,POLLIN); if(status) return status; continue; }
            if (code!=CURLE_OK || !count) return code!=CURLE_OK ? (int)code : CURLE_RECV_ERROR;
            reader->begin=0; reader->end=count;
        }
        size_t start=reader->begin; int completed=0, result=0;
        while(reader->begin < reader->end) {
            if (literal) {
                size_t n=reader->end-reader->begin; if(n>literal) n=literal;
                reader->begin+=n; literal-=n;
                continue;
            }
            unsigned char byte=reader->buffer[reader->begin++];
            if (line_length < sizeof(prefix)-1) { prefix[line_length]=(char)byte; prefix[line_length+1]=0; }
            tail[line_length%sizeof(tail)]=(char)byte; line_length++;
            if (byte != '\n') continue;
            if (line_length<2 || tail[(line_length-2)%sizeof(tail)]!='\r') { completed=1; result=CURLE_WEIRD_SERVER_REPLY; break; }
            if (!continuation && !strncmp(prefix,tag,tag_length) && prefix[tag_length]==' ') {
                const char *status=prefix+tag_length+1;
                completed=1;
                result=(!strncasecmp(status,"OK",2) && (status[2]==' ' || status[2]=='\r')) ? 0 : CURLE_REMOTE_ACCESS_DENIED;
                break;
            }
            if (!continuation && !strncasecmp(prefix,"* BYE",5) && (prefix[5]==' ' || prefix[5]=='\r')) { completed=1; result=CURLE_RECV_ERROR; break; }
            if ((continuation || response_allows_literal(prefix)) && line_length>=5 && tail[(line_length-3)%sizeof(tail)]=='}') {
                size_t end=line_length-3, position=end;
                if (position && tail[(position-1)%sizeof(tail)]=='+') position--;
                size_t digit_end=position;
                while(position && digit_end-position<11) {
                    unsigned char c=(unsigned char)tail[(position-1)%sizeof(tail)];
                    if(c<'0' || c>'9') break;
                    position--;
                }
                if (!position || digit_end==position || digit_end-position>10 || tail[(position-1)%sizeof(tail)]!='{') { completed=1; result=CURLE_WEIRD_SERVER_REPLY; break; }
                size_t length=0;
                for(size_t j=position;j<digit_end;j++) { unsigned digit=(unsigned)(tail[j%sizeof(tail)]-'0'); if(length>(SIZE_MAX-digit)/10) { completed=1; result=-4; break; }; length=length*10+digit; }
                if(completed) break;
                if (length>reader->transfer->request->maximum_response) { completed=1; result=-4; break; }
                literal=length; continuation=1;
            } else continuation=0;
            line_length=0; prefix[0]=0;
        }
        int captured=raw_capture(reader->transfer,selection,reader->buffer+start,reader->begin-start);
        if(captured) return captured;
        if(completed) return result;
    }
}
static int raw_command(MailReader *reader,const char *tag,const char *command,int selection) {
    char *line=NULL;
    if(asprintf(&line,"%s %s\r\n",tag,command)<0) return CURLE_OUT_OF_MEMORY;
    int status=raw_send(reader,line,strlen(line)); free(line);
    return status ? status : raw_response(reader,tag,selection);
}
static int raw_imap(CURL *curl,CURLU *url,Transfer *transfer) {
    const char *command=transfer->request->command ? transfer->request->command : "LIST \"\" \"*\"";
    MailReader reader={.curl=curl,.transfer=transfer,.deadline=monotonic_now()+60.0};
    if(curl_easy_getinfo(curl,CURLINFO_ACTIVESOCKET,&reader.socket)!=CURLE_OK || reader.socket==CURL_SOCKET_BAD) return CURLE_COULDNT_CONNECT;
    char *path=NULL;
    if(curl_url_get(url,CURLUPART_PATH,&path,CURLU_URLDECODE)!=CURLUE_OK) return -1;
    int status=0;
    if(path[0]=='/' && path[1]) {
        const char *mailbox=path+1;
        if(!line_valid(mailbox,8192,0)) { curl_free(path); return -1; }
        char quoted[16400], *p=quoted; const char *start="EXAMINE \""; memcpy(p,start,strlen(start)); p+=strlen(start);
        for(const char *s=mailbox;*s;s++) { if(*s=='\\' || *s=='\"') *p++='\\'; *p++=*s; }
        *p++='\"'; *p=0;
        status=raw_command(&reader,"NCRM1",quoted,1);
    }
    curl_free(path);
    if(!status) status=raw_command(&reader,"NCRM2",command,0);
    // Connection teardown closes this read-only session. No IMAP STORE/CLOSE
    // command is issued, so fetching does not change read/deleted flags.
    return status;
}
void native_mail_result_free(NativeMailResult *r) {
    if (!r) return;
    free(r->body); free(r->headers); r->body=NULL; r->headers=NULL; r->body_length=r->headers_length=0;
}
NativeMailResult native_mail_perform(const NativeMailRequest *q) {
    NativeMailResult r={0}; r.code=-1;
    if (!q || !line_valid(q->url,8192,0) || !line_valid(q->username,1024,0) || (!q->oauth_bearer && !line_valid(q->password,16384,0)) ||
        (q->oauth_bearer && (!line_valid(q->oauth_bearer,16384,0) || (q->password && *q->password))) ||
        q->maximum_response == 0 || q->maximum_response > (q->stream_to_fd ? (size_t)INT64_MAX : 33554432) || q->upload_length > 33554432 || q->tls_mode < 0 || q->tls_mode > 3 ||
        (q->upload_length && !q->upload) || (q->command && !line_valid(q->command,4096,0))) return r;
    pthread_once(&once,initialize); if (initialized != CURLE_OK) { r.code=initialized; return r; }
    CURLU *url=curl_url(); CURL *curl=NULL; struct curl_slist *resolve=NULL,*recipients=NULL;
    char *scheme=NULL,*host=NULL,*port=NULL,*part=NULL,*recipient_copy=NULL; struct addrinfo *addresses=NULL;
    if (!url || curl_url_set(url,CURLUPART_URL,q->url,0) != CURLUE_OK ||
        curl_url_get(url,CURLUPART_SCHEME,&scheme,0) != CURLUE_OK || curl_url_get(url,CURLUPART_HOST,&host,0) != CURLUE_OK ||
        curl_url_get(url,CURLUPART_PORT,&port,0) != CURLUE_OK) goto done;
    const CURLUPart prohibited[]={CURLUPART_USER,CURLUPART_PASSWORD,CURLUPART_QUERY,CURLUPART_FRAGMENT};
    for (size_t i=0;i<sizeof(prohibited)/sizeof(prohibited[0]);i++) {
        if (curl_url_get(url,prohibited[i],&part,0) == CURLUE_OK) { curl_free(part); part=NULL; goto done; }
    }
    int smtp=!strcmp(scheme,"smtp") || !strcmp(scheme,"smtps"), imap=!strcmp(scheme,"imap") || !strcmp(scheme,"imaps");
    if (!smtp && !imap) goto done;
    if (imap && q->tls_mode==3) goto done;
    /* A bearer token must never follow configurable legacy server settings. */
    if (q->oauth_bearer && (q->tls_mode != 2 || q->allow_self_signed ||
        (imap ? strcmp(host,"imap.gmail.com") || strcmp(port,"993") : strcmp(host,"smtp.gmail.com") || strcmp(port,"465")))) goto done;
    if ((q->tls_mode == 2) != (!strcmp(scheme,"smtps") || !strcmp(scheme,"imaps"))) goto done;
    if (q->smtp_verify_only && (!smtp || q->command || q->sender || q->recipients || q->upload_length)) goto done;
    if (smtp && !q->smtp_verify_only && (q->command || !line_valid(q->sender,1024,0) || !q->recipients || !q->upload_length)) goto done;
    if (imap && (q->sender || q->recipients || q->upload_length)) goto done;
    if (imap && !command_valid(q->command)) goto done;
    if(q->stream_to_fd) {
        struct stat info; int flags=fcntl(q->output_fd,F_GETFL);
        if(!imap || flags<0 || (flags&O_ACCMODE)==O_RDONLY || fstat(q->output_fd,&info)!=0 || !S_ISREG(info.st_mode) || info.st_uid!=geteuid() || info.st_nlink!=1 || (info.st_mode&0077)) goto done;
        if(ftruncate(q->output_fd,0)!=0 || lseek(q->output_fd,0,SEEK_SET)<0) goto done;
    }
    char hostname[256]; size_t hostlen=strlen(host);
    if (hostlen >= sizeof(hostname)) goto done;
    if (hostlen > 2 && host[0]=='[' && host[hostlen-1]==']') { memcpy(hostname,host+1,hostlen-2); hostname[hostlen-2]=0; }
    else memcpy(hostname,host,hostlen+1);
    for (char *p=hostname;*p;p++) if (!( (*p>='a'&&*p<='z') || (*p>='A'&&*p<='Z') || (*p>='0'&&*p<='9') || *p=='.' || *p=='-' || *p==':')) goto done;
    long number=strtol(port,NULL,10);
    if (number<1 || number>65535) goto done;
    Transfer t={.result=&r,.request=q}; if (cancel_check(&t)) { r.code=-5; goto done; }
    struct addrinfo hints={0}; hints.ai_family=AF_UNSPEC; hints.ai_socktype=SOCK_STREAM;
    if (getaddrinfo(hostname,port,&hints,&addresses) != 0) { r.code=-3; goto done; }
    char first[INET6_ADDRSTRLEN]={0};
    for (struct addrinfo *a=addresses;a;a=a->ai_next) {
        char ip[INET6_ADDRSTRLEN]; void *bytes=NULL;
        if (a->ai_family==AF_INET) bytes=&((struct sockaddr_in *)a->ai_addr)->sin_addr;
        else if (a->ai_family==AF_INET6) bytes=&((struct sockaddr_in6 *)a->ai_addr)->sin6_addr;
        else continue;
        if (!inet_ntop(a->ai_family,bytes,ip,sizeof(ip)) || (!native_mail_address_is_public(ip) && !test_loopback(ip))) { r.code=-2; goto done; }
        if (!*first) memcpy(first,ip,strlen(ip)+1);
    }
    if (!*first) { r.code=-3; goto done; }
    struct in_addr literal4; struct in6_addr literal6;
    if (inet_pton(AF_INET,hostname,&literal4) != 1 && inet_pton(AF_INET6,hostname,&literal6) != 1) {
        char pinned[600]; snprintf(pinned,sizeof(pinned),"%s:%s:%s%s%s",hostname,port,strchr(first,':')?"[":"",first,strchr(first,':')?"]":"");
        resolve=curl_slist_append(NULL,pinned); if (!resolve) goto done;
    }
    if (smtp && !q->smtp_verify_only) {
        if (strnlen(q->recipients,1048577)>1048576) goto done;
        recipient_copy=strdup(q->recipients); if (!recipient_copy) goto done;
        char *cursor=NULL; struct curl_slist *tail=NULL;
        for (char *p=strtok_r(recipient_copy,"\n",&cursor);p;p=strtok_r(NULL,"\n",&cursor)) {
            if (!line_valid(p,1024,0)) goto done;
            // curl_slist_append walks the list. Appending a singleton through
            // our tail keeps constructing a large envelope linear in size.
            struct curl_slist *next=curl_slist_append(NULL,p); if (!next) goto done;
            if(tail) tail->next=next; else recipients=next; tail=next;
        }
        if (!recipients) goto done;
    }
    curl=curl_easy_init(); if (!curl) goto done;
#define SET(option,value) do { CURLcode c=curl_easy_setopt(curl,option,value); if(c!=CURLE_OK) { r.code=c; goto done; } } while(0)
    SET(CURLOPT_URL,q->url); SET(CURLOPT_USERNAME,q->username);
    if (q->oauth_bearer) { SET(CURLOPT_XOAUTH2_BEARER,q->oauth_bearer); SET(CURLOPT_LOGIN_OPTIONS,"AUTH=XOAUTH2"); }
    else { SET(CURLOPT_PASSWORD,q->password); }
    SET(CURLOPT_PROTOCOLS_STR,smtp?"smtp,smtps":"imap,imaps"); SET(CURLOPT_PROXY,""); SET(CURLOPT_NOPROXY,"*");
    SET(CURLOPT_RESOLVE,resolve); SET(CURLOPT_FOLLOWLOCATION,0L); SET(CURLOPT_NOSIGNAL,1L);
    SET(CURLOPT_CONNECTTIMEOUT,10L); SET(CURLOPT_TIMEOUT,60L); SET(CURLOPT_LOW_SPEED_LIMIT,1L); SET(CURLOPT_LOW_SPEED_TIME,15L);
    SET(CURLOPT_SSL_VERIFYPEER,q->allow_self_signed?0L:1L); SET(CURLOPT_SSL_VERIFYHOST,q->allow_self_signed?0L:2L);
    SET(CURLOPT_USE_SSL,(long)(q->tls_mode==1?CURLUSESSL_ALL:q->tls_mode==3?CURLUSESSL_TRY:CURLUSESSL_NONE));
    if (smtp && !q->smtp_verify_only) {
        for (const unsigned char *p=(const unsigned char *)q->sender;*p;p++) if(*p>=128) t.needs_utf8=1;
        for (const unsigned char *p=(const unsigned char *)q->recipients;*p;p++) if(*p>=128) t.needs_utf8=1;
    }
    if (smtp) { SET(CURLOPT_DEBUGFUNCTION,smtp_debug); SET(CURLOPT_DEBUGDATA,&t); SET(CURLOPT_VERBOSE,1L); }
    SET(CURLOPT_WRITEFUNCTION,body_write); SET(CURLOPT_WRITEDATA,&t); SET(CURLOPT_HEADERFUNCTION,header_write); SET(CURLOPT_HEADERDATA,&t);
    SET(CURLOPT_XFERINFOFUNCTION,progress); SET(CURLOPT_XFERINFODATA,&t); SET(CURLOPT_NOPROGRESS,0L);
    if (imap || q->smtp_verify_only) SET(CURLOPT_CONNECT_ONLY,1L);
    if (smtp && !q->smtp_verify_only) { SET(CURLOPT_MAIL_FROM,q->sender); SET(CURLOPT_MAIL_RCPT,recipients); SET(CURLOPT_UPLOAD,1L); SET(CURLOPT_READFUNCTION,body_read); SET(CURLOPT_READDATA,&t); SET(CURLOPT_INFILESIZE_LARGE,(curl_off_t)q->upload_length); }
    r.code=curl_easy_perform(curl); curl_easy_getinfo(curl,CURLINFO_RESPONSE_CODE,&r.server_code);
    if(r.code==CURLE_OK && imap) r.code=raw_imap(curl,url,&t);
    if (t.limit_hit) r.code=-4; if (t.cancelled) r.code=-5;
    if (t.tls_refused) r.code=CURLE_USE_SSL_FAILED;
    if (t.utf8_refused) r.code=-6;
done:
    if (curl) curl_easy_cleanup(curl);
    if (url) curl_url_cleanup(url);
    curl_slist_free_all(resolve); curl_slist_free_all(recipients);
    curl_free(scheme); curl_free(host); curl_free(port); free(recipient_copy); if(addresses) freeaddrinfo(addresses);
    return r;
#undef SET
}
