#include "dsh_phone_self_runner.h"
#include <assert.h>
#include <stddef.h>

static void event(const char *run_id, int32_t kind, const char *payload) {
  (void)run_id;
  (void)kind;
  (void)payload;
  assert(!"invalid input must not start a callback thread");
}

int main(void) {
  assert(dsh_phone_xctest_start(NULL, event) == 0);
  assert(dsh_phone_xctest_start("{}", event) == 0);
  assert(dsh_phone_xctest_start("not-json", event) == 0);
  assert(dsh_phone_xctest_start("{}", NULL) == 0);
  dsh_phone_xctest_stop(0);
  dsh_phone_xctest_stop(UINT64_MAX);
  return 0;
}
