#ifndef DSH_WORKSPACE_GRANTS_ABI_H
#define DSH_WORKSPACE_GRANTS_ABI_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
// Trusted in-process consumers only; never expose acquire to guest/Dart as an
// unchecked method. Caller already consumed its engine task policy. write=0
// gives a read-only lease even when the OS grant permits writes.
#define DSH_WORKSPACE_API __attribute__((visibility("default")))
DSH_WORKSPACE_API void* dsh_workspace_acquire(const char* id,uint64_t generation,int write);
DSH_WORKSPACE_API void dsh_workspace_release(void* lease);
DSH_WORKSPACE_API const char* dsh_workspace_error(void);
DSH_WORKSPACE_API int64_t dsh_workspace_read(void* lease,const char* relative,uint64_t offset,void* buffer,size_t length);
DSH_WORKSPACE_API int64_t dsh_workspace_write(void* lease,const char* relative,uint64_t offset,const void* buffer,size_t length,int create,int truncate);
DSH_WORKSPACE_API int dsh_workspace_rename(void* lease,const char* source,const char* destination);
DSH_WORKSPACE_API int dsh_workspace_remove(void* lease,const char* relative,int directory);
DSH_WORKSPACE_API int dsh_workspace_mkdir(void* lease,const char* relative);
#ifdef __cplusplus
}
#endif
#endif

#ifndef DSH_WORKSPACE_GRANTS_ABI_913
#define DSH_WORKSPACE_GRANTS_ABI_913
#ifdef __cplusplus
extern "C" {
#endif
struct DshWorkspaceStat {uint64_t size;uint64_t ino;uint64_t dev;uint32_t mode;uint32_t type;double mtime_ms;};
typedef int (*DshWorkspaceEntry)(const char*,size_t,void*);
// Discovery only. No path/URI/FD is returned. Issue revalidates active generation.
 typedef int (*DshWorkspaceSnapshotEntry)(const char*,size_t,uint64_t,int,void*);
 DSH_WORKSPACE_API int dsh_workspace_snapshot(DshWorkspaceSnapshotEntry,void*);
DSH_WORKSPACE_API int dsh_workspace_errno(void);
DSH_WORKSPACE_API int dsh_workspace_stat(void*,const char*,struct DshWorkspaceStat*);
DSH_WORKSPACE_API int dsh_workspace_readdir(void*,const char*,DshWorkspaceEntry,void*);
DSH_WORKSPACE_API int64_t dsh_workspace_write_flags(void*,const char*,uint64_t,const void*,size_t,int);
// Ticket token: parent generates 32 random bytes encoded as exactly 64 hex chars.
// Issue/revoke are trusted owner-only. Worker sees only consume + ordinary IO.
DSH_WORKSPACE_API int dsh_workspace_ticket_issue(const char* token,const char* id,uint64_t generation,int write);
DSH_WORKSPACE_API void* dsh_workspace_ticket_consume(const char* token);
DSH_WORKSPACE_API int dsh_workspace_ticket_retire(const char* token);
#ifdef __cplusplus
}
#endif
#endif
