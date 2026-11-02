// Linux integration driver: generate the production Host profile and argv.
// The callback does not start Node; run argv.json with the actual pinned engine.
#include "host_core.h"

#include <fstream>
#include <iostream>
#include <string>

namespace {
std::string output;
std::string Json(const std::string& value) {
  std::string result = "\"";
  const char hex[] = "0123456789abcdef";
  for (unsigned char c : value) {
    if (c == '"' || c == '\\') { result += '\\'; result += c; }
    else if (c < 0x20) { result += "\\u00"; result += hex[c >> 4]; result += hex[c & 15]; }
    else result += c;
  }
  return result + '"';
}
int CaptureArguments(int argc, char** argv) {
  std::ofstream file(output);
  file << '[';
  for (int i = 0; i < argc; ++i) { if (i) file << ','; file << Json(argv[i]); }
  file << "]\n";
  return file ? 0 : 97;
}
int NoEngineToStop() { return 0; }
}  // namespace

int main(int argc, char** argv) {
  if (argc != 7) {
    std::cerr << "Usage: host-profile RUNTIME_ROOT DSH_HOME WORKSPACE CACHE_DIR NATIVE_LIBRARY_DIR ARGV_JSON\n";
    return 2;
  }
  output = argv[6];
  dsh::Host host;
  try {
    dsh::HostOptions options;
    options.runtime_root = argv[1]; options.dsh_home = argv[2];
    options.workspace_roots = {argv[3]}; options.cache_dir = argv[4];
    options.native_library_dir = argv[5];
    host.Start(std::move(options), CaptureArguments, NoEngineToStop);
    host.Wait();
    const auto state = host.State();
    if (state.phase != "exited" || state.exit_code != 0) {
      std::cerr << state.phase << ' ' << state.error_code << '\n'; return 1;
    }
    std::cout << "Generated production Host profile and argv; Node was not started by this driver.\n";
    return 0;
  } catch (const dsh::HostError& error) {
    std::cerr << error.code << '\n'; return 1;
  }
}
