// The Node embedded in the iOS app. V8 and Node's per-process state last as long as
// the process; every engine run gets its own Environment, so stopping the engine
// doesn't need the relaunch iOS can't do on its own.
#include <node.h>
#include <pthread.h>
#include <signal.h>

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include "publication_binding.h"
#include "phone_binding.h"

namespace {
// Secondary threads get 512 KiB by default here, less than V8's stack limit assumes.
constexpr size_t kEngineStackBytes = 16 * 1024 * 1024;

// runtime/ohos gates everything on process.platform and on WebAssembly being absent:
// it is the same in-process, no-child-process runtime, and this is what selects it.
// Workers inherit it with the rest of execArgv. Decodes to:
//   import{syncBuiltinESMExports as s}from'node:module';
//   Object.defineProperty(process,'platform',{value:'openharmony'});
//   Reflect.deleteProperty(globalThis,'WebAssembly');s();
constexpr const char* kPlatformImport =
    "--import=data:text/javascript;base64,"
    "aW1wb3J0e3N5bmNCdWlsdGluRVNNRXhwb3J0cyBhcyBzfWZyb20nbm9kZTptb2R1bGUnO09iamVjdC5kZWZpbmVQcm9wZXJ0eShwcm9jZXNz"
    "LCdwbGF0Zm9ybScse3ZhbHVlOidvcGVuaGFybW9ueSd9KTtSZWZsZWN0LmRlbGV0ZVByb3BlcnR5KGdsb2JhbFRoaXMsJ1dlYkFzc2VtYmx5"
    "Jyk7cygpOw==";

std::mutex environment_mutex;
node::Environment* active_environment = nullptr;
bool active = false;
bool stop_requested = false;

std::shared_ptr<node::InitializationResult> initialization;
std::unique_ptr<node::MultiIsolatePlatform> platform;

int RejectStartup(const char* code) {
  // Never echo paths, DSH arguments or environment values.
  std::fprintf(stderr, "%s: invalid embedded Node startup contract\n", code);
  return 64;
}

bool IsUnifiedPreload(const char* value) {
  constexpr const char* suffix = "/runtime/ohos/preload.mjs";
  if (value == nullptr || value[0] != '/') return false;
  const size_t length = std::strlen(value);
  const size_t suffix_length = std::strlen(suffix);
  return length >= suffix_length && std::strcmp(value + length - suffix_length, suffix) == 0;
}

int RunEnvironment(const std::vector<std::string>& args, const std::vector<std::string>& exec_args) {
  std::vector<std::string> errors;
  const auto flags = static_cast<node::EnvironmentFlags::Flags>(
      node::EnvironmentFlags::kTrackUnmanagedFds |
      node::EnvironmentFlags::kNoGlobalSearchPaths |
      node::EnvironmentFlags::kNoCreateInspector |
      node::EnvironmentFlags::kNoStartDebugSignalHandler);
  auto setup = node::CommonEnvironmentSetup::Create(platform.get(), &errors, args, exec_args, flags);
  if (!setup) {
    for (const auto& error : errors) std::fprintf(stderr, "%s\n", error.c_str());
    return RejectStartup("ERR_IOS_HOST_ENVIRONMENT");
  }
  auto* isolate = setup->isolate();
  auto* env = setup->env();
  int explicit_exit = 0;
  bool has_explicit_exit = false;
  int result = 1;
  {
    v8::Locker locker(isolate);
    v8::Isolate::Scope isolate_scope(isolate);
    v8::HandleScope handle_scope(isolate);
    v8::Context::Scope context_scope(setup->context());
    node::SetProcessExitHandler(env, [&](node::Environment* exiting, int code) {
      explicit_exit = code;
      has_explicit_exit = true;
      node::Stop(exiting);
    });
    {
      std::lock_guard<std::mutex> lock(environment_mutex);
      active_environment = env;
      if (stop_requested) node::Stop(env);
    }
    // An empty callback selects Node's normal CLI entry and its --import chain.
    if (!node::LoadEnvironment(env, node::StartExecutionCallback{}).IsEmpty()) {
      result = node::SpinEventLoop(env).FromMaybe(1);
    }
    {
      std::lock_guard<std::mutex> lock(environment_mutex);
      active_environment = nullptr;
      if (stop_requested && !has_explicit_exit) result = 0;
    }
    node::Stop(env);
  }
  return has_explicit_exit ? explicit_exit : result;
}

struct Run {
  std::vector<std::string> arguments;
  int result = 1;
};

void* RunOnEngineThread(void* raw) {
  auto* run = static_cast<Run*>(raw);
  if (!initialization) {
    RegisterPhoneBinding();
    // Options parsed here hold for every later Environment. The host's argv is fixed
    // for this installation, so what later runs would parse is the same.
    RegisterPublicationBinding();
    initialization = node::InitializeOncePerProcess(run->arguments, {
        node::ProcessInitializationFlags::kNoStdioInitialization,
        node::ProcessInitializationFlags::kNoDefaultSignalHandling,
        node::ProcessInitializationFlags::kNoInitializeV8,
        node::ProcessInitializationFlags::kNoInitializeNodeV8Platform,
        node::ProcessInitializationFlags::kDisableNodeOptionsEnv,
        node::ProcessInitializationFlags::kNoParseGlobalDebugVariables,
        node::ProcessInitializationFlags::kNoAdjustResourceLimits,
        node::ProcessInitializationFlags::kNoUseLargePages,
    });
    for (const auto& error : initialization->errors()) std::fprintf(stderr, "%s\n", error.c_str());
    if (initialization->early_return()) {
      run->result = initialization->exit_code();
      return nullptr;
    }
    platform = node::MultiIsolatePlatform::Create(4);
    v8::V8::InitializePlatform(platform.get());
    v8::V8::Initialize();
  } else if (initialization->early_return()) {
    run->result = initialization->exit_code();
    return nullptr;
  }
  run->result = RunEnvironment(initialization->args(), initialization->exec_args());
  return nullptr;
}
}  // namespace

extern "C" __attribute__((visibility("default"))) int dsh_node_start(int argc, char** argv) {
  const char* node_options = std::getenv("NODE_OPTIONS");
  if (node_options != nullptr && node_options[0] != '\0') return RejectStartup("ERR_IOS_HOST_NODE_OPTIONS");
  if (argc < 5 || argv == nullptr || argv[0] == nullptr || argv[1] == nullptr || argv[2] == nullptr ||
      std::strcmp(argv[1], "--jitless") != 0 || std::strcmp(argv[2], "--import") != 0 ||
      !IsUnifiedPreload(argv[3]) || argv[4] == nullptr || argv[4][0] != '/') {
    return RejectStartup("ERR_IOS_HOST_ARGV");
  }
  {
    std::lock_guard<std::mutex> lock(environment_mutex);
    if (active) return RejectStartup("ERR_IOS_HOST_ALREADY_STARTED");
    active = true;
    stop_requested = false;
  }
  // A dying write to a closed socket would otherwise take the whole app: Node's own
  // signal setup is off, since the process isn't Node's.
  signal(SIGPIPE, SIG_IGN);

  Run run;
  // Node's defaults assume a server's memory: left alone, the heap grows until iOS ends
  // the app. These held a five-tool round with a large JSON worker; not yet set on a device.
  run.arguments = {argv[0], argv[1], "--max-old-space-size=256", "--max-semi-space-size=4",
                   // NodeMobile warns on every plain open and close ("File descriptor N
                   // opened in unmanaged mode twice"), thousands at startup and into tool
                   // output. The stacks are ordinary readFileSync calls.
                   "--disable-warning=Warning", kPlatformImport, argv[2], argv[3]};
  run.arguments.insert(run.arguments.end(), argv + 4, argv + argc);
#ifdef DSH_IOS_ENGINE_SMOKE
  // Test builds only: the smoke test's fake model has to reach the fixed command line,
  // next to the host's own --patch because the CLI takes it nowhere later.
  if (const char* patch = std::getenv("DSH_IOS_SMOKE_PATCH")) {
    const auto own = std::find(run.arguments.begin(), run.arguments.end(), "--patch");
    run.arguments.insert(own + 2, {"--patch", patch});
  }
#endif

  pthread_attr_t attributes;
  pthread_t thread;
  pthread_attr_init(&attributes);
  pthread_attr_setstacksize(&attributes, kEngineStackBytes);
  const int created = pthread_create(&thread, &attributes, RunOnEngineThread, &run);
  pthread_attr_destroy(&attributes);
  if (created == 0) pthread_join(thread, nullptr);
  else run.result = RejectStartup("ERR_IOS_HOST_THREAD");
  {
    std::lock_guard<std::mutex> lock(environment_mutex);
    active = false;
  }
  return run.result;
}

// node::Stop is the public embedder cancellation API, not a process signal. The lock
// keeps the Environment from being destroyed during this call.
extern "C" __attribute__((visibility("default"))) int dsh_node_stop() {
  std::lock_guard<std::mutex> lock(environment_mutex);
  if (!active) return 0;
  stop_requested = true;
  if (active_environment) node::Stop(active_environment);
  return 1;
}
