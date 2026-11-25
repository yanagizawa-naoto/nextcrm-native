#define _DARWIN_C_SOURCE
#include "NativeRestoreHostBridge.h"
#include <sys/stat.h>
#include <sys/file.h>
#include <sys/event.h>
#include <sys/wait.h>
#include <sys/socket.h>
#include <libproc.h>
#include <spawn.h>
#include <fcntl.h>
#include <unistd.h>
#include <signal.h>
#include <errno.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <time.h>
extern char **environ;
struct NCHLease {int directory,descriptor;char path[PATH_MAX];struct stat control,entry;};
static int above_stdio(int fd){if(fd<0||fd>=3)return fd;int copy=fcntl(fd,F_DUPFD_CLOEXEC,3);close(fd);return copy;}
static int same(const struct stat *a,const struct stat *b){return a->st_dev==b->st_dev&&a->st_ino==b->st_ino;}
static int control_shape(const struct stat *s){return S_ISDIR(s->st_mode)&&s->st_uid==geteuid()&&(s->st_mode&0777)==0700;}
static int entry_shape(const struct stat *s){return S_ISREG(s->st_mode)&&s->st_uid==geteuid()&&(s->st_mode&0777)==0600&&s->st_nlink==1;}
static int directory(const char *path){
    if(!path||path[0]!='/'||strlen(path)>=PATH_MAX){errno=EINVAL;return -1;}
    int fd=above_stdio(open("/",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC));if(fd<0)return -1;
    char copy[PATH_MAX];strcpy(copy,path);char *save=NULL;
    for(char *part=strtok_r(copy,"/",&save);part;part=strtok_r(NULL,"/",&save)){
        if(!strcmp(part,".")||!strcmp(part,"..")){close(fd);return -1;}
        int next=above_stdio(openat(fd,part,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC));close(fd);if(next<0)return -1;fd=next;
    }return fd;
}
void nch_lease_close(NCHLease *lease){if(!lease)return;if(lease->descriptor>=0)close(lease->descriptor);if(lease->directory>=0)close(lease->directory);free(lease);}
int nch_lease_validate(NCHLease *lease){
    if(!lease)return NCH_INVALID;int fresh=directory(lease->path);struct stat a,b,c;int ok=fresh>=0&&fstat(fresh,&a)==0&&same(&a,&lease->control)&&control_shape(&a);
    if(fresh>=0)close(fresh);
    ok=ok&&fstat(lease->directory,&a)==0&&same(&a,&lease->control)&&control_shape(&a)&&fstat(lease->descriptor,&b)==0&&same(&b,&lease->entry)&&entry_shape(&b)&&
        fstatat(lease->directory,".instance.lease",&c,AT_SYMLINK_NOFOLLOW)==0&&same(&b,&c)&&entry_shape(&c);
    return ok?NCH_OK:NCH_INVALID;
}
static int lease_prepare(const char *control,int inherited,int create,NCHLease **out){
    *out=NULL;NCHLease *l=calloc(1,sizeof(*l));if(!l){if(inherited>=0)close(inherited);return NCH_SYSTEM;}l->directory=-1;l->descriptor=inherited;
    if(!control||strlen(control)>=sizeof(l->path))goto invalid;strcpy(l->path,control);
    l->directory=directory(control);if(l->directory<0||fstat(l->directory,&l->control)<0||!control_shape(&l->control))goto invalid;
    if(inherited<0)l->descriptor=above_stdio(openat(l->directory,".instance.lease",O_RDWR|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK|(create?O_CREAT:0),0600));
    else if(fcntl(inherited,F_SETFD,FD_CLOEXEC)<0)goto invalid;
    if(l->descriptor<0||fstat(l->descriptor,&l->entry)<0||!entry_shape(&l->entry)||nch_lease_validate(l)!=NCH_OK)goto invalid;
    *out=l;return NCH_OK;
invalid:nch_lease_close(l);return NCH_INVALID;
}
static NCHLeaseIdentity lease_identity(NCHLease *l){return(NCHLeaseIdentity){(uint64_t)l->control.st_dev,l->control.st_ino,(uint64_t)l->entry.st_dev,l->entry.st_ino,l->entry.st_uid};}
static int identity_equal(NCHLeaseIdentity a,NCHLeaseIdentity b){return a.control_device==b.control_device&&a.control_inode==b.control_inode&&a.lease_device==b.lease_device&&a.lease_inode==b.lease_inode&&a.uid==b.uid;}
static int lease_lock(NCHLease *l){if(flock(l->descriptor,LOCK_EX|LOCK_NB)<0)return errno==EWOULDBLOCK||errno==EAGAIN?NCH_BUSY:NCH_SYSTEM;return nch_lease_validate(l);}
int nch_lease_open(const char *control,NCHLease **out,NCHLeaseIdentity *identity){
    int code=lease_prepare(control,-1,1,out);if(code)return code;code=lease_lock(*out);
    if(!code&&(fsync((*out)->descriptor)<0||fsync((*out)->directory)<0))code=NCH_SYSTEM;
    if(code){nch_lease_close(*out);*out=NULL;return code;}*identity=lease_identity(*out);return NCH_OK;
}
int nch_lease_adopt(const char *control,int inherited,NCHLeaseIdentity expected,NCHLease **out){
    if(inherited<3){if(inherited>=0)close(inherited);*out=NULL;return NCH_INVALID;}
    int code=lease_prepare(control,inherited,0,out);if(code)return code;
    if(!identity_equal(expected,lease_identity(*out)))code=NCH_IDENTITY;else code=lease_lock(*out);
    if(code){nch_lease_close(*out);*out=NULL;}return code;
}
int nch_lease_duplicate(NCHLease *lease,int *out){*out=-1;int code=nch_lease_validate(lease);if(code)return code;int fd=fcntl(lease->descriptor,F_DUPFD_CLOEXEC,3);if(fd<0)return NCH_SYSTEM;*out=fd;return NCH_OK;}
int nch_process_identity(pid_t pid,NCHProcessIdentity *out){
    struct proc_bsdinfo b;int n=proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&b,sizeof(b));if(n!=(int)sizeof(b)||b.pbi_uid!=geteuid())return NCH_IDENTITY;
    *out=(NCHProcessIdentity){pid,b.pbi_uid,b.pbi_start_tvsec,b.pbi_start_tvusec};return NCH_OK;
}
static int process_equal(NCHProcessIdentity a,NCHProcessIdentity b){return a.pid==b.pid&&a.uid==b.uid&&a.start_seconds==b.start_seconds&&a.start_microseconds==b.start_microseconds;}
int nch_watch_register(NCHProcessIdentity expected,int *out){
    *out=-1;NCHProcessIdentity a,b;if(expected.pid<=0||nch_process_identity(expected.pid,&a)||!process_equal(a,expected))return NCH_IDENTITY;
    int q=above_stdio(kqueue());if(q<0)return NCH_SYSTEM;if(fcntl(q,F_SETFD,FD_CLOEXEC)<0){close(q);return NCH_SYSTEM;}
    struct kevent c,r;EV_SET(&c,(uintptr_t)expected.pid,EVFILT_PROC,EV_ADD|EV_ENABLE|EV_ONESHOT|EV_RECEIPT,NOTE_EXIT|NOTE_EXITSTATUS,0,NULL);
    int n=kevent(q,&c,1,&r,1,NULL);
    if(n!=1||!(r.flags&EV_ERROR)||r.data!=0||nch_process_identity(expected.pid,&b)||!process_equal(expected,b)){close(q);return NCH_IDENTITY;}
    *out=q;return NCH_OK;
}
int nch_make_cancel_pipe(int *read_fd,int *write_fd){
    int p[2];if(pipe(p)<0)return NCH_SYSTEM;
    p[0]=above_stdio(p[0]);p[1]=above_stdio(p[1]);if(p[0]<0||p[1]<0){if(p[0]>=0)close(p[0]);if(p[1]>=0)close(p[1]);return NCH_SYSTEM;}
    if(fcntl(p[0],F_SETFD,FD_CLOEXEC)<0||fcntl(p[1],F_SETFD,FD_CLOEXEC)<0||fcntl(p[0],F_SETFL,O_NONBLOCK)<0||fcntl(p[1],F_SETFL,O_NONBLOCK)<0||fcntl(p[1],F_SETNOSIGPIPE,1)<0){close(p[0]);close(p[1]);return NCH_SYSTEM;}
    *read_fd=p[0];*write_fd=p[1];return NCH_OK;
}
int nch_duplicate_pipe_reader(int descriptor,int *out){
    *out=-1;struct stat s;if(fstat(descriptor,&s)<0||!S_ISFIFO(s.st_mode))return NCH_INVALID;
    int flags=fcntl(descriptor,F_GETFL);if(flags<0||(flags&O_ACCMODE)==O_WRONLY||!(flags&O_NONBLOCK))return NCH_INVALID;
    int fd=fcntl(descriptor,F_DUPFD_CLOEXEC,3);if(fd<0)return NCH_SYSTEM;*out=fd;return NCH_OK;
}
void nch_signal_cancel(int fd){if(fd<0)return;char c='C';ssize_t result;do{result=write(fd,&c,1);}while(result<0&&errno==EINTR);}
static double monotonic(void){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec+t.tv_nsec/1e9;}
static int add_reader(int q,int fd){if(fd<0)return 0;struct kevent c,r;EV_SET(&c,(uintptr_t)fd,EVFILT_READ,EV_ADD|EV_ENABLE|EV_RECEIPT,0,0,NULL);return kevent(q,&c,1,&r,1,NULL)==1&&(r.flags&EV_ERROR)&&r.data==0?0:-1;}
int nch_watch_wait(int q,NCHProcessIdentity process,int cancel,int peer,double timeout,int *status){
    if(!isfinite(timeout)||timeout < -1||add_reader(q,cancel)||add_reader(q,peer))return -NCH_SYSTEM;
    double deadline=timeout<0?-1:monotonic()+timeout;
    while(1){
        struct timespec t,*tp=NULL;if(deadline>=0){double remaining=fmax(0,deadline-monotonic());t.tv_sec=(time_t)remaining;t.tv_nsec=(long)((remaining-t.tv_sec)*1e9);tp=&t;}
        struct kevent events[3];int n=kevent(q,NULL,0,events,3,tp);if(n<0){if(errno==EINTR)continue;return -NCH_SYSTEM;}if(n==0)return NCH_TIMED_OUT;
        int exit_event=0;for(int i=0;i<n;i++){
            struct kevent e=events[i];if(e.flags&EV_ERROR)return -NCH_SYSTEM;
            if(e.filter==EVFILT_READ&&e.ident==(uintptr_t)cancel)return NCH_CANCELLED;
            if(e.filter==EVFILT_READ&&e.ident==(uintptr_t)peer){
                if((e.flags&EV_EOF)&&e.data==0)return NCH_PEER_CLOSED;
                char c;ssize_t count=read(peer,&c,1);if(count==0)return NCH_PEER_CLOSED;if(count==1)return c=='C'?NCH_CANCELLED:-NCH_PROTOCOL;
                if(errno!=EAGAIN&&errno!=EINTR)return -NCH_SYSTEM;
            }
            if(e.filter==EVFILT_PROC&&e.ident==(uintptr_t)process.pid&&(e.fflags&NOTE_EXIT)){exit_event=1;*status=(int)e.data;}
        }
        if(exit_event)return NCH_EXITED;
    }
}
int nch_spawn(const char *path,char *const argv[],const int *sources,const int *targets,int count,pid_t *out){
    if(!path||path[0]!='/'||count<0||count>32)return NCH_INVALID;
    for(int i=0;i<count;i++){if(sources[i]<0||targets[i]<3||targets[i]>1024||fcntl(sources[i],F_GETFD)<0)return NCH_INVALID;for(int j=0;j<i;j++)if(targets[i]==targets[j])return NCH_INVALID;}
    posix_spawnattr_t attr;posix_spawn_file_actions_t actions;int initialized=0;
    if(posix_spawnattr_init(&attr))return NCH_SYSTEM;
    /* A Swift executor thread can have a different signal mask from the main
       thread. Child cancellation must not inherit an accidentally blocked TERM. */
    sigset_t mask,defaults;sigemptyset(&mask);sigemptyset(&defaults);sigaddset(&defaults,SIGTERM);sigaddset(&defaults,SIGINT);sigaddset(&defaults,SIGHUP);
    int code=posix_spawnattr_setsigmask(&attr,&mask);
    if(!code)code=posix_spawnattr_setsigdefault(&attr,&defaults);
    if(!code)code=posix_spawnattr_setflags(&attr,POSIX_SPAWN_CLOEXEC_DEFAULT|POSIX_SPAWN_SETSIGMASK|POSIX_SPAWN_SETSIGDEF);
    if(!code){code=posix_spawn_file_actions_init(&actions);if(!code)initialized=1;}
    /* Copy all sources above the target range, so cross-mappings cannot clobber
       a later source during sequential dup2 file actions. */
    int duplicates[32],minimum=3;for(int i=0;i<count;i++)if(targets[i]>=minimum)minimum=targets[i]+1;for(int i=0;i<32;i++)duplicates[i]=-1;
    for(int i=0;!code&&i<count;i++){duplicates[i]=fcntl(sources[i],F_DUPFD_CLOEXEC,minimum);if(duplicates[i]<0)code=errno;else code=posix_spawn_file_actions_adddup2(&actions,duplicates[i],targets[i]);}
    if(!code)code=posix_spawn(out,path,&actions,&attr,argv,environ);
    for(int i=0;i<count;i++)if(duplicates[i]>=0)close(duplicates[i]);
    if(initialized)posix_spawn_file_actions_destroy(&actions);posix_spawnattr_destroy(&attr);return code?NCH_SYSTEM:NCH_OK;
}
static int child_signal(pid_t pid,int sig,int *status,int *reaped){
    pid_t n;do{n=waitpid(pid,status,WNOHANG);}while(n<0&&errno==EINTR);
    if(n==pid){*reaped=1;return 0;}if(n!=0)return -1;
    return kill(pid,sig)==0||errno==ESRCH?0:-1;
}
static void force_reap(pid_t pid,int *status){
    int reaped=0;if(child_signal(pid,SIGTERM,status,&reaped)<0||reaped)return;
    double end=monotonic()+0.2;pid_t n;
    do{do{n=waitpid(pid,status,WNOHANG);}while(n<0&&errno==EINTR);if(n!=0)return;usleep(10000);}while(monotonic()<end);
    if(child_signal(pid,SIGKILL,status,&reaped)<0||reaped)return;
    do{n=waitpid(pid,status,0);}while(n<0&&errno==EINTR);
}
int nch_child_wait(pid_t pid,int cancel,double grace,int *status,int *cancelled){
    *cancelled=0;if(pid<=0||!isfinite(grace)||grace<0||grace>10)return NCH_INVALID;
    pid_t n;do{n=waitpid(pid,status,WNOHANG);}while(n<0&&errno==EINTR);if(n==pid)return NCH_OK;if(n<0)return NCH_IDENTITY;
    /* An unreaped direct child's PID cannot be recycled. Unlike a non-child
       parent watcher, it need not pass a racy proc_pidinfo lookup during exit. */
    NCHProcessIdentity id={pid,geteuid(),0,0};int q=above_stdio(kqueue());
    if(q<0){force_reap(pid,status);return NCH_SYSTEM;}
    if(fcntl(q,F_SETFD,FD_CLOEXEC)<0){close(q);force_reap(pid,status);return NCH_SYSTEM;}
    struct kevent c,r;EV_SET(&c,(uintptr_t)pid,EVFILT_PROC,EV_ADD|EV_ENABLE|EV_ONESHOT|EV_RECEIPT,NOTE_EXIT|NOTE_EXITSTATUS,0,NULL);
    int registered=kevent(q,&c,1,&r,1,NULL);
    if(registered!=1||!(r.flags&EV_ERROR)||r.data!=0){
        close(q);
        if(registered==1&&(r.flags&EV_ERROR)&&r.data==ESRCH){do{n=waitpid(pid,status,0);}while(n<0&&errno==EINTR);return n==pid?NCH_OK:NCH_IDENTITY;}
        force_reap(pid,status);return NCH_SYSTEM;
    }
    int event_status=0,outcome=nch_watch_wait(q,id,cancel,-1,-1,&event_status);
    if(outcome==NCH_CANCELLED){
        *cancelled=1;int reaped=0;if(child_signal(pid,SIGTERM,status,&reaped)<0){close(q);return NCH_SYSTEM;}if(reaped){close(q);return NCH_OK;}
        /* The level-triggered cancellation reader must not wake this grace wait. */
        struct kevent del;EV_SET(&del,(uintptr_t)cancel,EVFILT_READ,EV_DELETE,0,0,NULL);(void)kevent(q,&del,1,NULL,0,NULL);
        outcome=nch_watch_wait(q,id,-1,-1,grace,&event_status);
        if(outcome!=NCH_EXITED){if(child_signal(pid,SIGKILL,status,&reaped)<0){close(q);return NCH_SYSTEM;}if(reaped){close(q);return NCH_OK;}}
    }
    close(q);
    if(outcome!=NCH_EXITED&&!*cancelled){force_reap(pid,status);return NCH_SYSTEM;}
    do{n=waitpid(pid,status,0);}while(n<0&&errno==EINTR);return n==pid?NCH_OK:NCH_IDENTITY;
}
void nch_child_abandon(pid_t pid){
    int r=-1,w=-1,status=0,cancelled=0;if(nch_make_cancel_pipe(&r,&w)!=NCH_OK){force_reap(pid,&status);return;}nch_signal_cancel(w);
    (void)nch_child_wait(pid,r,0.2,&status,&cancelled);close(w);close(r);
}
