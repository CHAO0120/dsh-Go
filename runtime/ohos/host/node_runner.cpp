#include <node.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>

#include "publication_binding.h"

namespace {
int RejectStartup(const char* code) {
  // Never echo NODE_OPTIONS, paths, DSH arguments or other environment values.
  std::fprintf(stderr, "%s: invalid dedicated OHOS Node startup contract\n", code);
  return 64;
}

bool IsUnifiedPreload(const char* value) {
  constexpr const char* suffix = "/runtime/ohos/preload.mjs";
  if (value == nullptr || value[0] != '/') return false;
  const size_t length = std::strlen(value);
  const size_t suffix_length = std::strlen(suffix);
  return length >= suffix_length &&
      std::strcmp(value + length - suffix_length, suffix) == 0;
}
}  // namespace

// A dedicated OHOS host entry, not a general Node CLI option parser.
// The Ark-side host owns the one-start-per-application guard and keeps this
// library resident. All validation precedes registration and node::Start.
extern "C" __attribute__((visibility("default")))
int dsh_node_start(int argc, char** argv) {
  const char* node_options = std::getenv("NODE_OPTIONS");
  if (node_options != nullptr && node_options[0] != '\0') {
    return RejectStartup("ERR_OHOS_HOST_NODE_OPTIONS");
  }
  if (argc < 4 || argv == nullptr || argv[0] == nullptr || argv[1] == nullptr ||
      argv[2] == nullptr || std::strcmp(argv[1], "--jitless") != 0) {
    return RejectStartup("ERR_OHOS_HOST_ARGV");
  }
  const char* preload = nullptr;
  int main_index;
  if (std::strcmp(argv[2], "--import") == 0) {
    if (argc < 5) return RejectStartup("ERR_OHOS_HOST_ARGV");
    preload = argv[3];
    main_index = 4;
  } else if (std::strncmp(argv[2], "--import=", 9) == 0) {
    preload = argv[2] + 9;
    main_index = 3;
  } else {
    return RejectStartup("ERR_OHOS_HOST_ARGV");
  }
  if (!IsUnifiedPreload(preload) || argv[main_index] == nullptr ||
      argv[main_index][0] != '/') {
    return RejectStartup("ERR_OHOS_HOST_ARGV");
  }
  // Arguments after the absolute DSH entry belong to DSH, not to Node.
  RegisterPublicationBinding();
  return node::Start(argc, argv);
}
