#ifndef DSH_GUEST_BACKEND_H
#define DSH_GUEST_BACKEND_H
#include <stddef.h>
#include <stdint.h>

// Trusted embedding API, not an authorization boundary. The caller must only
// supply approved workspace/temp roots and its complete protected-path set.
// All returned errors are positive host errno values. Apple is unverified.
enum dsh_guest_state { DSH_GUEST_COLD, DSH_GUEST_READY,
                       DSH_GUEST_RUNNING, DSH_GUEST_QUARANTINED };
struct dsh_guest_options {
  const char *root; // installed fakefs container: contains data/ and meta.db
  const char *const *protected_paths;
  size_t protected_count;
};
struct dsh_guest_request {
  const char *const *argv;
  size_t argc;
  const char *const *env; // KEY=value; no host environment inheritance
  size_t envc;
  const char *cwd; // normalized guest path under /workspace
  const char *workspace;
  const char *temporary;
  int workspace_readonly; // 0 or 1; temporary remains controlled and writable
};
struct dsh_guest_result {
  int exit_code; // decoded Linux wait status; 128 + signal for signalled task
  int abandoned; // outputs intentionally discarded, never a successful ACK
  int resources_settled;
};
// Output borrowed only for callback duration. At most one in-flight chunk per
// stream. Callback implements backpressure and returns ECANCELED on abandonment.
// It must wake on Env disposal; it must never call JS off the Node loop thread.
typedef int (*dsh_guest_output)(void *, int stream, uint64_t end_offset,
                              const void *, size_t);
// All strings are consumed/copied synchronously. start failure guarantees no
// callback can subsequently borrow context; after success wait governs release.
int dsh_guest_initialize(const struct dsh_guest_options *);
int dsh_guest_begin_install_change(void);
void dsh_guest_end_install_change(void);
int dsh_guest_start(const struct dsh_guest_request *, dsh_guest_output, void *,
                    uint64_t *job_id);
int dsh_guest_stdin_write(uint64_t, const void *, size_t, size_t *written);
int dsh_guest_stdin_close(uint64_t);
int dsh_guest_ack(uint64_t, int stream, uint64_t end_offset);
// Sends TERM now, escalates to KILL after 200 ms; stale ids cannot hit a new job.
int dsh_guest_cancel(uint64_t);
int dsh_guest_kill(uint64_t);
// Caller first wakes its blocked output callbacks to return ECANCELED. Marks
// dropped output separately from ACK, closes stdin and requests cancellation.
int dsh_guest_abandon(uint64_t);
// Only one native coordinator calls wait. Normal tasks have no total time limit.
// timeout_ms starts at cancel/abandon, bounds cleanup, and must be >= 200 ms.
// Never run on the JS loop/cleanup thread. Timeout quarantines this kernel.
// On success no callback uses context again. On failure caller retains context:
// it may still be borrowed by quarantined native threads, independent of Env.
int dsh_guest_wait(uint64_t, unsigned timeout_ms, struct dsh_guest_result *);
enum dsh_guest_state dsh_guest_status(void);
// One process-wide kernel, sequential reuse. EBUSY rejects concurrent start.
// There is no kernel destroy/reinitialize API; quarantine requires App restart.
#endif
