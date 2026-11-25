#ifndef NEXTCRM_RESTORE_HOST_BRIDGE_H
#define NEXTCRM_RESTORE_HOST_BRIDGE_H
#include <stdint.h>
#include <sys/types.h>
enum { NCH_OK=0,NCH_BUSY=1,NCH_INVALID=2,NCH_SYSTEM=3,NCH_IDENTITY=4,NCH_PROTOCOL=5 };
enum { NCH_EXITED=1,NCH_CANCELLED=2,NCH_PEER_CLOSED=3,NCH_TIMED_OUT=4 };
typedef struct NCHLease NCHLease;
typedef struct { uint64_t control_device,control_inode,lease_device,lease_inode;uint32_t uid; } NCHLeaseIdentity;
typedef struct { int32_t pid;uint32_t uid;uint64_t start_seconds,start_microseconds; } NCHProcessIdentity;
/* Existing private control only; no coordinator/journal/pointer operations. */
int nch_lease_open(const char *control,NCHLease **out,NCHLeaseIdentity *identity);
/* Consumes inherited_fd on every result. The caller must own that descriptor. */
int nch_lease_adopt(const char *control,int inherited_fd,NCHLeaseIdentity expected,NCHLease **out);
int nch_lease_validate(NCHLease *lease);
int nch_lease_duplicate(NCHLease *lease,int *out_fd);
void nch_lease_close(NCHLease *lease); /* close-only: never LOCK_UN */
int nch_process_identity(pid_t pid,NCHProcessIdentity *out);
int nch_watch_register(NCHProcessIdentity expected,int *out_kqueue);
/* cancel/peer endpoints use a single C byte; peer EOF is separately reported.
   timeout < 0 means no deadline. Cancellation has priority over a simultaneous exit. */
int nch_watch_wait(int kqueue_fd,NCHProcessIdentity process,int cancel_fd,int peer_fd,double timeout,int *out_event_status);
int nch_make_cancel_pipe(int *read_fd,int *write_fd);
int nch_duplicate_pipe_reader(int descriptor,int *out);
void nch_signal_cancel(int descriptor);
int nch_spawn(const char *executable,char *const argv[],const int *sources,const int *targets,int count,pid_t *out);
/* Sole reaper for an unreaped direct child; consumes no descriptors.
   Cancellation waits through TERM/grace/KILL and waitpid before returning. */
int nch_child_wait(pid_t pid,int cancel_fd,double grace,int *out_status,int *out_cancelled);
void nch_child_abandon(pid_t pid); /* only a direct unreaped child; bounded TERM/KILL */
#endif
