#ifndef DSH_PHONE_SELF_RUNNER_H
#define DSH_PHONE_SELF_RUNNER_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* All callback strings are borrowed and valid only until the callback returns.
 * Callbacks run on the native worker thread. Copy before dispatching elsewhere.
 * No callback contains a plaintext RPC credential or pairing record.
 * kind: 0 starting, 1 ready (base64 RSA ciphertext), 2 stopped, 3 failed,
 * 4 faulted (ERR_PHONE_STOP_UNCONFIRMED; poisoned until app restart).
 * 2/3 follow resource release and confirmed device exit (or no device launch).
 * 4 follows native resource release but does NOT confirm device process exit.
 * Callbacks may precede start's return.
 */
typedef void (*dsh_phone_xctest_callback)(const char *run_id, int32_t kind,
                                          const char *payload);

/* The JSON string is copied during this call. Returns zero for invalid input,
 * another live/stopping owner, or failure to create the native worker thread.
 * Accepted keys: runId, pairingFile, host, port, runnerBundleId,
 * targetBundleId, publicKeyBase64. Public key is 2048-bit RSA PKCS#1 DER.
 */
uint64_t dsh_phone_xctest_start(const char *config_json,
                               dsh_phone_xctest_callback callback);

/* Idempotent and nonblocking. A stale handle cannot stop a newer session.
 * A stopping session still owns the singleton slot until terminal delivery.
 * A faulted/unconfirmed session keeps the slot poisoned until app restart.
 */
void dsh_phone_xctest_stop(uint64_t handle);

#ifdef __cplusplus
}
#endif
#endif
