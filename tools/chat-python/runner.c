// F28-CAPI-1: one invocation, one WASI preview1 guest, no host code execution.
#define _DARWIN_C_SOURCE
#include <wasmtime.h>
#include <wasi.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

enum { SETUP = 2, GUEST = 3, RESOURCE = 4, TIMED_OUT = 5, CANCELLED = 6 };
enum { MAX_MODULE = 64 * 1024 * 1024, MAX_OUTPUT = 1024 * 1024 };
static const uint64_t DEFAULT_FUEL = UINT64_C(5000000000);
static const uint64_t DEFAULT_TIMEOUT = 30000;
static const uint64_t DEFAULT_MEMORY = 256;

typedef struct {
  const wasm_engine_t *engine;
  atomic_size_t output_bytes;
  atomic_bool overflow;
  atomic_bool io_error;
  atomic_bool timed_out;
  atomic_bool done;
  struct timespec deadline;
} Supervisor;

static volatile sig_atomic_t signal_seen;

static void on_signal(int signo) {
  (void)signo;
  signal_seen = 1;
}

static int compare_time(struct timespec a, struct timespec b) {
  if (a.tv_sec != b.tv_sec) return a.tv_sec < b.tv_sec ? -1 : 1;
  return (a.tv_nsec > b.tv_nsec) - (a.tv_nsec < b.tv_nsec);
}

static void *watchdog(void *arg) {
  Supervisor *s = arg;
  const struct timespec pause = { .tv_sec = 0, .tv_nsec = 5000000 };
  while (!atomic_load(&s->done)) {
    if (signal_seen) {
      wasmtime_engine_increment_epoch(s->engine);
      return NULL;
    }
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0 ||
        compare_time(now, s->deadline) >= 0) {
      atomic_store(&s->timed_out, true);
      wasmtime_engine_increment_epoch(s->engine);
      return NULL;
    }
    nanosleep(&pause, NULL);
  }
  return NULL;
}

typedef struct {
  Supervisor *supervisor;
  int fd;
  int original_flags;
  bool flags_changed;
} Output;

static bool prepare_output(Output *o) {
  struct stat st;
  o->original_flags = fcntl(o->fd, F_GETFL);
  if (o->original_flags < 0 || fstat(o->fd, &st)) return false;
  // Regular files retain their normal behavior; other outputs must not block
  // inside a host callback while the watchdog requests interruption.
  if (!S_ISREG(st.st_mode) && !(o->original_flags & O_NONBLOCK)) {
    if (fcntl(o->fd, F_SETFL, o->original_flags | O_NONBLOCK)) return false;
    o->flags_changed = true;
  }
  return true;
}

static void restore_output(Output *o) {
  if (o->flags_changed) fcntl(o->fd, F_SETFL, o->original_flags);
}

static bool output_stopped(Supervisor *s) {
  return signal_seen || atomic_load(&s->timed_out) ||
         atomic_load(&s->overflow);
}

static ptrdiff_t guest_write(void *arg, const unsigned char *data, size_t len) {
  Output *o = arg;
  Supervisor *s = o->supervisor;
  if (output_stopped(s)) return -ECANCELED;
  size_t old = atomic_load(&s->output_bytes);
  if (old > MAX_OUTPUT || len > MAX_OUTPUT - old) {
    atomic_store(&s->overflow, true);
    wasmtime_engine_increment_epoch(s->engine);
    return -EFBIG;
  }
  // Callbacks execute on the guest thread; no Store operation is made here.
  size_t written = 0;
  while (written < len) {
    if (output_stopped(s)) return -ECANCELED;
    ssize_t n = write(o->fd, data + written, len - written);
    if (n > 0) {
      written += (size_t)n;
      atomic_fetch_add(&s->output_bytes, (size_t)n);
      continue;
    }
    if (n < 0 && errno == EINTR) continue;
    if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
      struct pollfd pfd = { .fd = o->fd, .events = POLLOUT };
      int ready = poll(&pfd, 1, 5);
      if (ready >= 0 || errno == EINTR) continue;
    }
    if (n <= 0) {
      atomic_store(&s->io_error, true);
      wasmtime_engine_increment_epoch(s->engine);
      return -EIO;
    }
  }
  return (ptrdiff_t)written;
}

static void report_status(int status) {
  static const char *messages[] = { "", "", "runner setup error\n",
    "guest failed\n", "guest resource limit\n", "guest timed out\n",
    "guest cancelled\n" };
  if (status == 0) return;
  int flags = fcntl(STDERR_FILENO, F_GETFL);
  struct stat st;
  if (flags < 0 || fstat(STDERR_FILENO, &st)) return;
  bool changed = false;
  if (!S_ISREG(st.st_mode) && !(flags & O_NONBLOCK)) {
    if (fcntl(STDERR_FILENO, F_SETFL, flags | O_NONBLOCK)) return;
    changed = true;
  }
  const char *message = messages[status];
  (void)write(STDERR_FILENO, message, strlen(message));
  if (changed) fcntl(STDERR_FILENO, F_SETFL, flags);
}

static bool positive_bounded(const char *str, uint64_t min, uint64_t max,
                             uint64_t *out) {
  if (!str || !*str || *str == '-' || *str == '+') return false;
  errno = 0;
  char *end = NULL;
  unsigned long long n = strtoull(str, &end, 10);
  if (errno || !end || *end || n < min || n > max) return false;
  *out = (uint64_t)n;
  return true;
}

static bool leaf_files_only(const char *path) {
  DIR *dir = opendir(path);
  if (!dir) return false;
  bool okay = true;
  struct dirent *item;
  errno = 0;
  while ((item = readdir(dir))) {
    if (!strcmp(item->d_name, ".") || !strcmp(item->d_name, "..")) continue;
    size_t size = strlen(path) + strlen(item->d_name) + 2;
    char *name = malloc(size);
    if (!name) { okay = false; break; }
    snprintf(name, size, "%s/%s", path, item->d_name);
    struct stat st;
    if (lstat(name, &st) || !S_ISREG(st.st_mode)) okay = false;
    free(name);
    if (!okay) break;
    errno = 0;
  }
  if (errno && !item) okay = false;
  closedir(dir);
  return okay;
}

static bool directory(const char *path, char resolved[PATH_MAX]) {
  if (!path || path[0] != '/' || !realpath(path, resolved)) return false;
  struct stat st;
  return !stat(resolved, &st) && S_ISDIR(st.st_mode);
}

static int read_module(const char *runtime, uint8_t **bytes, size_t *size) {
  size_t len = strlen(runtime);
  const char suffix[] = "/python.wasm";
  if (len > PATH_MAX - sizeof(suffix)) return -1;
  char path[PATH_MAX];
  memcpy(path, runtime, len);
  memcpy(path + len, suffix, sizeof(suffix));
  struct stat st;
  if (lstat(path, &st) || !S_ISREG(st.st_mode) || st.st_size <= 0 ||
      st.st_size > MAX_MODULE) return -1;
  int fd = open(path, O_RDONLY | O_NOFOLLOW);
  if (fd < 0) return -1;
  uint8_t *buf = malloc((size_t)st.st_size);
  if (!buf) { close(fd); return -1; }
  size_t done = 0;
  while (done < (size_t)st.st_size) {
    ssize_t n = read(fd, buf + done, (size_t)st.st_size - done);
    if (n < 0 && errno == EINTR) continue;
    if (n <= 0) break;
    done += (size_t)n;
  }
  close(fd);
  if (done != (size_t)st.st_size) { free(buf); return -1; }
  *bytes = buf;
  *size = done;
  return 0;
}

int main(int argc, char **argv) {
  // This helper owns its process. Convert broken stdout/stderr pipes into
  // EPIPE so guest_write can finish cleanup and status reporting cannot
  // replace an earlier error with SIGPIPE.
  struct sigaction ignore_pipe = {0};
  ignore_pipe.sa_handler = SIG_IGN;
  sigemptyset(&ignore_pipe.sa_mask);
  if (sigaction(SIGPIPE, &ignore_pipe, NULL)) return SETUP;
  const char *runtime = NULL, *inputs = NULL;
  uint64_t fuel = DEFAULT_FUEL, timeout = DEFAULT_TIMEOUT, memory = DEFAULT_MEMORY;
  unsigned seen = 0;
  int status = SETUP;
  for (int i = 1; i < argc; i += 2) {
    if (i + 1 >= argc) goto finish;
    unsigned bit;
    if (!strcmp(argv[i], "--runtime")) { bit = 1; runtime = argv[i + 1]; }
    else if (!strcmp(argv[i], "--inputs")) { bit = 2; inputs = argv[i + 1]; }
    else if (!strcmp(argv[i], "--fuel")) {
      bit = 4;
      if (!positive_bounded(argv[i + 1], 1, DEFAULT_FUEL, &fuel)) goto finish;
    } else if (!strcmp(argv[i], "--timeout-ms")) {
      bit = 8;
      if (!positive_bounded(argv[i + 1], 1, DEFAULT_TIMEOUT, &timeout)) goto finish;
    } else if (!strcmp(argv[i], "--memory-mib")) {
      bit = 16;
      if (!positive_bounded(argv[i + 1], 16, DEFAULT_MEMORY, &memory)) goto finish;
    } else goto finish;
    if (seen & bit) goto finish;
    seen |= bit;
  }
  if ((seen & 3) != 3) goto finish;
  char runtime_path[PATH_MAX], inputs_path[PATH_MAX];
  if (!directory(runtime, runtime_path) || !directory(inputs, inputs_path) ||
      !strcmp(runtime_path, inputs_path) || !leaf_files_only(inputs_path)) goto finish;
  uint8_t *bytes = NULL;
  size_t bytes_len = 0;
  if (read_module(runtime_path, &bytes, &bytes_len)) goto finish;

  wasm_config_t *config = wasm_config_new();
  wasm_engine_t *engine = NULL;
  wasmtime_module_t *module = NULL;
  wasmtime_store_t *store = NULL;
  wasmtime_linker_t *linker = NULL;
  wasi_config_t *wasi = NULL;
  wasmtime_error_t *error = NULL;
  wasm_trap_t *trap = NULL;
  pthread_t thread;
  bool thread_started = false;
  struct sigaction previous_int, previous_term;
  bool handlers = false;
  Supervisor supervisor = {0};
  Output out = { .supervisor = &supervisor, .fd = STDOUT_FILENO };
  Output err = { .supervisor = &supervisor, .fd = STDERR_FILENO };
  if (!config) goto cleanup;
  error = wasmtime_config_target_set(config, "pulley64");
  if (error) goto cleanup;
  wasmtime_config_consume_fuel_set(config, true);
  wasmtime_config_epoch_interruption_set(config, true);
  wasmtime_config_max_wasm_stack_set(config, 16 * 1024 * 1024);
  // Wasmtime validates this relation even for a synchronous Store.
  wasmtime_config_async_stack_size_set(config, 24 * 1024 * 1024);
  engine = wasm_engine_new_with_config(config);
  config = NULL;
  if (!engine || !wasmtime_engine_is_pulley(engine)) goto cleanup;
  supervisor.engine = engine;
  error = wasmtime_module_new(engine, bytes, bytes_len, &module);
  if (error) goto cleanup;
  store = wasmtime_store_new(engine, NULL, NULL);
  if (!store) goto cleanup;
  // Limits are per Store. These do not claim a process RSS bound.
  wasmtime_store_limiter(store, (int64_t)(memory * 1024 * 1024),
                         100000, 8, 8, 8);
  wasmtime_context_t *context = wasmtime_store_context(store);
  error = wasmtime_context_set_fuel(context, fuel);
  if (error) goto cleanup;
  wasi = wasi_config_new();
  if (!wasi) goto cleanup;
  const char *args[] = { "/runtime/python.wasm", "-S", "-B", "/inputs/program.py" };
  const char *names[] = { "PYTHONHOME", "PYTHONDONTWRITEBYTECODE" };
  const char *values[] = { "/runtime", "1" };
  if (!wasi_config_set_argv(wasi, 4, args) ||
      !wasi_config_set_env(wasi, 2, names, values) ||
      !wasi_config_preopen_dir(wasi, runtime_path, "/runtime", false) ||
      !wasi_config_preopen_dir(wasi, inputs_path, "/inputs", false)) goto cleanup;
  wasm_byte_vec_t empty_stdin;
  wasm_byte_vec_new_empty(&empty_stdin);
  wasi_config_set_stdin_bytes(wasi, &empty_stdin);
  wasi_config_set_stdout_custom(wasi, guest_write, &out, NULL);
  wasi_config_set_stderr_custom(wasi, guest_write, &err, NULL);
  error = wasmtime_context_set_wasi(context, wasi);
  wasi = NULL; // consumed even on error
  if (error) goto cleanup;
  linker = wasmtime_linker_new(engine);
  if (!linker) goto cleanup;
  error = wasmtime_linker_define_wasi(linker);
  if (error) goto cleanup;
  if (!prepare_output(&out) || !prepare_output(&err)) goto cleanup;
  wasmtime_context_set_epoch_deadline(context, 1);
  if (clock_gettime(CLOCK_MONOTONIC, &supervisor.deadline)) goto cleanup;
  supervisor.deadline.tv_sec += (time_t)(timeout / 1000);
  supervisor.deadline.tv_nsec += (long)(timeout % 1000) * 1000000L;
  if (supervisor.deadline.tv_nsec >= 1000000000L) {
    supervisor.deadline.tv_sec++;
    supervisor.deadline.tv_nsec -= 1000000000L;
  }
  struct sigaction action = {0};
  action.sa_handler = on_signal;
  sigemptyset(&action.sa_mask);
  if (sigaction(SIGINT, &action, &previous_int)) goto cleanup;
  if (sigaction(SIGTERM, &action, &previous_term)) {
    sigaction(SIGINT, &previous_int, NULL);
    goto cleanup;
  }
  handlers = true;
  if (signal_seen) goto cleanup;
  if (pthread_create(&thread, NULL, watchdog, &supervisor)) goto cleanup;
  thread_started = true;
  if (signal_seen) goto cleanup;
  wasmtime_instance_t instance;
  error = wasmtime_linker_instantiate(linker, context, module, &instance, &trap);
  if (error || trap) { status = GUEST; goto cleanup; }
  if (signal_seen) goto cleanup;
  wasmtime_extern_t start;
  if (!wasmtime_instance_export_get(context, &instance, "_start", 6, &start) ||
      start.kind != WASMTIME_EXTERN_FUNC) { status = SETUP; goto cleanup; }
  if (signal_seen) goto cleanup;
  error = wasmtime_func_call(context, &start.of.func, NULL, 0, NULL, 0, &trap);
  status = error || trap ? GUEST : 0;
  if (error) {
    int guest_exit;
    if (wasmtime_error_exit_status(error, &guest_exit))
      status = guest_exit == 0 ? 0 : GUEST;
  }
cleanup:
  atomic_store(&supervisor.done, true);
  if (thread_started) pthread_join(thread, NULL);
  if (atomic_load(&supervisor.io_error)) status = SETUP;
  if (atomic_load(&supervisor.overflow)) status = RESOURCE;
  if (atomic_load(&supervisor.timed_out)) status = TIMED_OUT;
  if (signal_seen) status = CANCELLED;
  restore_output(&err);
  restore_output(&out);
  if (trap) {
    wasmtime_trap_code_t code;
    if (status == GUEST && wasmtime_trap_code(trap, &code) &&
        (code == WASMTIME_TRAP_CODE_OUT_OF_FUEL ||
         code == WASMTIME_TRAP_CODE_MEMORY_OUT_OF_BOUNDS ||
         code == WASMTIME_TRAP_CODE_STACK_OVERFLOW)) status = RESOURCE;
    wasm_trap_delete(trap);
  }
  if (error) wasmtime_error_delete(error);
  if (linker) wasmtime_linker_delete(linker);
  if (store) wasmtime_store_delete(store);
  if (module) wasmtime_module_delete(module);
  if (engine) wasm_engine_delete(engine);
  if (config) wasm_config_delete(config);
  if (wasi) wasi_config_delete(wasi);
  free(bytes);
  if (signal_seen) status = CANCELLED;
  if (handlers) {
    sigaction(SIGTERM, &previous_term, NULL);
    sigaction(SIGINT, &previous_int, NULL);
  }
finish:
  report_status(status);
  return status;
}
