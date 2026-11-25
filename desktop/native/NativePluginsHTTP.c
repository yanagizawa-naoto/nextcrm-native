#include "NativePluginsHTTP.h"
#include "NativeMailTransport.h"
#include <curl/curl.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <pthread.h>
#include <time.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <errno.h>

static pthread_once_t once=PTHREAD_ONCE_INIT;
static CURLcode initialized;
static void initialize(void){initialized=curl_global_init(CURL_GLOBAL_DEFAULT);}
static double monotonic(void){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec+t.tv_nsec/1e9;}
static int cancelled(const NativePluginHTTPRequest *q){return q->cancelled&&q->cancelled(q->context);}
static int line(const char *s,size_t maximum,int empty){if(!s||(!empty&&!*s)||strnlen(s,maximum+1)>maximum)return 0;for(const unsigned char*p=(const unsigned char*)s;*p;p++)if(*p<32||*p==127)return 0;return 1;}
typedef struct {char host[256],port[6];pthread_mutex_t mutex;pthread_cond_t condition;int done,abandoned,code;struct addrinfo *addresses;} Resolve;
static void resolve_free(Resolve*r){if(r->addresses)freeaddrinfo(r->addresses);pthread_cond_destroy(&r->condition);pthread_mutex_destroy(&r->mutex);free(r);}
static void *resolve_work(void *context){
    Resolve*r=context;struct addrinfo hints={0},*addresses=NULL;hints.ai_family=AF_UNSPEC;hints.ai_socktype=SOCK_STREAM;
    int code=getaddrinfo(r->host,r->port,&hints,&addresses);
    pthread_mutex_lock(&r->mutex);r->addresses=addresses;r->code=code;r->done=1;int abandoned=r->abandoned;pthread_cond_signal(&r->condition);pthread_mutex_unlock(&r->mutex);
    if(abandoned)resolve_free(r);return NULL;
}
static int resolve(const char*host,const char*port,const NativePluginHTTPRequest*q,double deadline,char first[INET6_ADDRSTRLEN]){
    struct in_addr v4;struct in6_addr v6;
    if(inet_pton(AF_INET,host,&v4)==1||inet_pton(AF_INET6,host,&v6)==1){if(!q->allow_private&&!native_mail_address_is_public(host))return -2;strcpy(first,host);return 0;}
    Resolve*r=calloc(1,sizeof(*r));if(!r)return -1;strcpy(r->host,host);strcpy(r->port,port);pthread_mutex_init(&r->mutex,NULL);pthread_cond_init(&r->condition,NULL);
    pthread_t thread;if(pthread_create(&thread,NULL,resolve_work,r)!=0){resolve_free(r);return -3;}
    pthread_mutex_lock(&r->mutex);
    while(!r->done){
        int stop=cancelled(q)?-5:monotonic()>=deadline?CURLE_OPERATION_TIMEDOUT:0;
        if(stop){r->abandoned=1;pthread_mutex_unlock(&r->mutex);pthread_detach(thread);return stop;}
        struct timespec until;clock_gettime(CLOCK_REALTIME,&until);until.tv_nsec+=50000000;if(until.tv_nsec>=1000000000){until.tv_sec++;until.tv_nsec-=1000000000;}pthread_cond_timedwait(&r->condition,&r->mutex,&until);
    }
    pthread_mutex_unlock(&r->mutex);pthread_join(thread,NULL);int code=r->code?-3:0;
    if(!code)for(struct addrinfo*a=r->addresses;a;a=a->ai_next){
        char ip[INET6_ADDRSTRLEN];void*bytes=a->ai_family==AF_INET?(void*)&((struct sockaddr_in*)a->ai_addr)->sin_addr:a->ai_family==AF_INET6?(void*)&((struct sockaddr_in6*)a->ai_addr)->sin6_addr:NULL;
        if(!bytes)continue;if(!inet_ntop(a->ai_family,bytes,ip,sizeof(ip))||(!q->allow_private&&!native_mail_address_is_public(ip))){code=-2;break;}if(!*first)strcpy(first,ip);
    }
    if(!code&&!*first)code=-3;resolve_free(r);return code;
}
typedef struct {const NativePluginHTTPRequest*q;NativePluginHTTPResult*r;int limited;} Transfer;
static size_t append(uint8_t**buffer,size_t*length,size_t max,const void*bytes,size_t count,Transfer*t){
    if(cancelled(t->q))return 0;if(*length>max||count>max-*length){t->limited=1;return 0;}if(!count)return 0;uint8_t*next=realloc(*buffer,*length+count);if(!next)return 0;memcpy(next+*length,bytes,count);*buffer=next;*length+=count;return count;
}
static size_t body(char*p,size_t size,size_t count,void*context){Transfer*t=context;if(size&&count>SIZE_MAX/size)return 0;return append(&t->r->body,&t->r->body_length,t->q->maximum_response,p,size*count,t);}
static size_t headers(char*p,size_t size,size_t count,void*context){Transfer*t=context;if(size&&count>SIZE_MAX/size)return 0;return append(&t->r->headers,&t->r->headers_length,262144,p,size*count,t);}
static int progress(void*context,curl_off_t dt,curl_off_t dn,curl_off_t ut,curl_off_t un){(void)dt;(void)dn;(void)ut;(void)un;return cancelled(((Transfer*)context)->q);}
void native_plugin_http_result_free(NativePluginHTTPResult*r){if(!r)return;free(r->body);free(r->headers);r->body=r->headers=NULL;r->body_length=r->headers_length=0;}
NativePluginHTTPResult native_plugin_http_perform(const NativePluginHTTPRequest*q){
    NativePluginHTTPResult r={.code=-1};
    if(!q||!line(q->url,32768,0)||!line(q->method,32,0)||q->body_length>67108864||q->maximum_response==0||q->maximum_response>67108864||q->timeout_ms<=0||q->timeout_ms>3600000||(q->body_length&&!q->body))return r;
    if(cancelled(q)){r.code=-5;return r;}pthread_once(&once,initialize);if(initialized){r.code=initialized;return r;}
    double deadline=monotonic()+q->timeout_ms/1000.0;CURLU*url=curl_url();CURL*curl=NULL;struct curl_slist*resolve_list=NULL,*header_list=NULL;char *scheme=NULL,*host=NULL,*port=NULL,*part=NULL,*copy=NULL;
    if(!url||curl_url_set(url,CURLUPART_URL,q->url,0)||curl_url_get(url,CURLUPART_SCHEME,&scheme,0)||curl_url_get(url,CURLUPART_HOST,&host,0))goto done;
    if(strcmp(scheme,"https")&&strcmp(scheme,"http"))goto done;
    if(!curl_url_get(url,CURLUPART_USER,&part,0)){curl_free(part);part=NULL;goto done;}if(!curl_url_get(url,CURLUPART_PASSWORD,&part,0)){curl_free(part);part=NULL;goto done;}
    if(curl_url_get(url,CURLUPART_PORT,&port,CURLU_DEFAULT_PORT))goto done;
    char hostname[256];size_t hostlen=strlen(host);if(hostlen>=sizeof(hostname))goto done;
    if(hostlen>2&&host[0]=='['&&host[hostlen-1]==']'){memcpy(hostname,host+1,hostlen-2);hostname[hostlen-2]=0;}else strcpy(hostname,host);
    char first[INET6_ADDRSTRLEN]={0};
    if(q->resolved_addresses){
        if(strnlen(q->resolved_addresses,65537)>65536)goto done;copy=strdup(q->resolved_addresses);if(!copy)goto done;char*save=NULL;
        for(char*ip=strtok_r(copy,"\n",&save);ip;ip=strtok_r(NULL,"\n",&save)){struct in_addr v4;struct in6_addr v6;if((inet_pton(AF_INET,ip,&v4)!=1&&inet_pton(AF_INET6,ip,&v6)!=1)||(!q->allow_private&&!native_mail_address_is_public(ip))){r.code=-2;goto done;}if(!*first)strcpy(first,ip);}free(copy);copy=NULL;if(!*first){r.code=-3;goto done;}
    }else{r.code=resolve(hostname,port,q,deadline,first);if(r.code)goto done;}
    r.code=-1;
    char pinned[600];snprintf(pinned,sizeof(pinned),"%s:%s:%s%s%s",host,port,strchr(first,':')?"[":"",first,strchr(first,':')?"]":"");resolve_list=curl_slist_append(NULL,pinned);if(!resolve_list)goto done;
    if(q->headers){if(strnlen(q->headers,262145)>262144)goto done;copy=strdup(q->headers);if(!copy)goto done;char*save=NULL;
        for(char*h=strtok_r(copy,"\n",&save);h;h=strtok_r(NULL,"\n",&save)){if(!line(h,65536,0)||!strchr(h,':'))goto done;struct curl_slist*next=curl_slist_append(header_list,h);if(!next)goto done;header_list=next;}free(copy);copy=NULL;
    }
    curl=curl_easy_init();if(!curl)goto done;Transfer transfer={.q=q,.r=&r};long remaining=(long)((deadline-monotonic())*1000);if(remaining<1){r.code=CURLE_OPERATION_TIMEDOUT;goto done;}
#define SET(option,value) do{CURLcode c=curl_easy_setopt(curl,option,value);if(c){r.code=c;goto done;}}while(0)
    SET(CURLOPT_URL,q->url);SET(CURLOPT_CUSTOMREQUEST,q->method);SET(CURLOPT_HTTPHEADER,header_list);SET(CURLOPT_PROTOCOLS_STR,"http,https");SET(CURLOPT_REDIR_PROTOCOLS_STR,"http,https");
    SET(CURLOPT_PROXY,"");SET(CURLOPT_NOPROXY,"*");SET(CURLOPT_RESOLVE,resolve_list);SET(CURLOPT_FOLLOWLOCATION,0L);SET(CURLOPT_NOSIGNAL,1L);SET(CURLOPT_TIMEOUT_MS,remaining);SET(CURLOPT_CONNECTTIMEOUT_MS,remaining);
    SET(CURLOPT_SSL_VERIFYPEER,1L);SET(CURLOPT_SSL_VERIFYHOST,2L);SET(CURLOPT_ACCEPT_ENCODING,"");
    SET(CURLOPT_WRITEFUNCTION,body);SET(CURLOPT_WRITEDATA,&transfer);SET(CURLOPT_HEADERFUNCTION,headers);SET(CURLOPT_HEADERDATA,&transfer);SET(CURLOPT_XFERINFOFUNCTION,progress);SET(CURLOPT_XFERINFODATA,&transfer);SET(CURLOPT_NOPROGRESS,0L);
    if(!strcmp(q->method,"HEAD"))SET(CURLOPT_NOBODY,1L);
    if(q->body){SET(CURLOPT_POSTFIELDS,q->body);SET(CURLOPT_POSTFIELDSIZE_LARGE,(curl_off_t)q->body_length);}
    r.code=curl_easy_perform(curl);curl_easy_getinfo(curl,CURLINFO_RESPONSE_CODE,&r.status);
    if(transfer.limited)r.code=-4;if(cancelled(q))r.code=-5;
done:
    if(curl)curl_easy_cleanup(curl);if(url)curl_url_cleanup(url);curl_slist_free_all(resolve_list);curl_slist_free_all(header_list);curl_free(scheme);curl_free(host);curl_free(port);curl_free(part);free(copy);return r;
}
