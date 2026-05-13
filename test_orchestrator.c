/*
 * Nested-compositor test mode for somewm-client: spawns a sandboxed
 * somewm under the user's existing Wayland or X11 session and routes
 * the regular IPC commands at it.
 *
 * Inspired by AWMTT (https://github.com/serialoverflow/awmtt).
 */

#define _GNU_SOURCE

#include "test_orchestrator.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define STATE_DIR_NAME        "somewm-test"
#define DEFAULT_NAME          "test"
#define WAIT_FOR_SOCKET_MS    30000
#define STOP_GRACE_MS         5000
#define KILL_GRACE_MS         2000
#define POLL_INTERVAL_MS      50
#define IPC_BUFFER_SIZE       65536

enum host_mode { HOST_WAYLAND, HOST_X11, HOST_HEADLESS };
enum keybinds_mode { KB_AUTO, KB_INHIBIT, KB_REMAP, KB_NONE };

struct start_opts {
	const char *name;
	const char *config_path;
	enum host_mode host;
	enum keybinds_mode keybinds;
	int no_marker;
	int force;
};

/* Names land in $XDG_RUNTIME_DIR/somewm-test/<name>/; allowing '/'
 * or '..' lets a caller escape that directory or create nested dirs
 * that test stop won't reach. */
static int
validate_name(const char *name)
{
	if (!name || !*name) {
		fprintf(stderr, "Error: --name must not be empty\n");
		return -1;
	}
	if (strlen(name) > 64) {
		fprintf(stderr, "Error: --name must be 64 characters or fewer\n");
		return -1;
	}
	if (name[0] == '.') {
		fprintf(stderr, "Error: --name must not start with '.'\n");
		return -1;
	}
	for (const char *p = name; *p; p++) {
		int ok = (*p >= 'a' && *p <= 'z')
		      || (*p >= 'A' && *p <= 'Z')
		      || (*p >= '0' && *p <= '9')
		      || *p == '-' || *p == '_' || *p == '.';
		if (!ok) {
			fprintf(stderr,
			        "Error: --name '%s' contains invalid character '%c' "
			        "(allowed: A-Za-z0-9 . _ -)\n", name, *p);
			return -1;
		}
	}
	return 0;
}


static int
runtime_dir(char *out, size_t cap)
{
	const char *rd = getenv("XDG_RUNTIME_DIR");
	if (!rd || !*rd) {
		fprintf(stderr, "Error: XDG_RUNTIME_DIR not set\n");
		return -1;
	}
	if ((size_t)snprintf(out, cap, "%s", rd) >= cap)
		return -1;
	return 0;
}

static int
state_dir_for(const char *name, char *out, size_t cap)
{
	char rd[PATH_MAX];
	if (runtime_dir(rd, sizeof(rd)) < 0)
		return -1;
	if ((size_t)snprintf(out, cap, "%s/%s/%s", rd, STATE_DIR_NAME, name) >= cap)
		return -1;
	return 0;
}

static int
mkdir_p(const char *path, mode_t mode)
{
	char buf[PATH_MAX];
	size_t len = strnlen(path, sizeof(buf));
	if (len >= sizeof(buf))
		return -1;
	memcpy(buf, path, len + 1);
	for (char *p = buf + 1; *p; p++) {
		if (*p == '/') {
			*p = '\0';
			if (mkdir(buf, mode) < 0 && errno != EEXIST)
				return -1;
			*p = '/';
		}
	}
	if (mkdir(buf, mode) < 0 && errno != EEXIST)
		return -1;
	return 0;
}

static int
rmtree(const char *path)
{
	DIR *d = opendir(path);
	if (!d)
		return (errno == ENOENT) ? 0 : -1;
	struct dirent *e;
	while ((e = readdir(d))) {
		if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, ".."))
			continue;
		char child[PATH_MAX];
		if ((size_t)snprintf(child, sizeof(child), "%s/%s", path, e->d_name)
		    >= sizeof(child)) {
			closedir(d);
			return -1;
		}
		struct stat st;
		if (lstat(child, &st) < 0) {
			closedir(d);
			return -1;
		}
		if (S_ISDIR(st.st_mode)) {
			if (rmtree(child) < 0) {
				closedir(d);
				return -1;
			}
		} else {
			if (unlink(child) < 0 && errno != ENOENT) {
				closedir(d);
				return -1;
			}
		}
	}
	closedir(d);
	if (rmdir(path) < 0 && errno != ENOENT)
		return -1;
	return 0;
}


static int
info_write(const char *state_dir, const struct start_opts *opts, pid_t pid,
           const char *wl_socket_name, const char *resolved_config,
           const char *keybinds_status)
{
	char path[PATH_MAX + 16];
	if ((size_t)snprintf(path, sizeof(path), "%s/info", state_dir)
	    >= sizeof(path))
		return -1;
	FILE *f = fopen(path, "w");
	if (!f)
		return -1;
	const char *host_str =
		(opts->host == HOST_X11)       ? "x11"
		: (opts->host == HOST_HEADLESS) ? "headless"
		: "wayland";
	const char *host_display =
		(opts->host == HOST_X11)       ? getenv("DISPLAY")
		: (opts->host == HOST_HEADLESS) ? ""
		: getenv("WAYLAND_DISPLAY");
	const char *kb_mode =
		(opts->keybinds == KB_INHIBIT) ? "inhibit"
		: (opts->keybinds == KB_REMAP) ? "remap"
		: (opts->keybinds == KB_NONE)  ? "none"
		: "auto";
	fprintf(f, "name=%s\n", opts->name);
	fprintf(f, "pid=%ld\n", (long)pid);
	fprintf(f, "host=%s\n", host_str);
	fprintf(f, "host_display=%s\n", host_display ? host_display : "");
	fprintf(f, "config_path=%s\n", resolved_config ? resolved_config : "");
	fprintf(f, "started_at=%lld\n", (long long)time(NULL));
	fprintf(f, "keybinds_mode=%s\n", kb_mode);
	fprintf(f, "keybinds_status=%s\n", keybinds_status ? keybinds_status : "not-applicable");
	fprintf(f, "wl_socket_name=%s\n", wl_socket_name ? wl_socket_name : "");
	fprintf(f, "no_marker=%d\n", opts->no_marker ? 1 : 0);
	fclose(f);
	return 0;
}

static int
info_read_field(const char *state_dir, const char *key, char *out, size_t cap)
{
	char path[PATH_MAX];
	if ((size_t)snprintf(path, sizeof(path), "%s/info", state_dir)
	    >= sizeof(path))
		return -1;
	FILE *f = fopen(path, "r");
	if (!f)
		return -1;
	size_t klen = strlen(key);
	char line[2048];
	int found = -1;
	while (fgets(line, sizeof(line), f)) {
		if (strncmp(line, key, klen) == 0 && line[klen] == '=') {
			size_t len = strlen(line);
			if (len && line[len - 1] == '\n')
				line[len - 1] = '\0';
			snprintf(out, cap, "%s", line + klen + 1);
			found = 0;
			break;
		}
	}
	fclose(f);
	return found;
}


static int
write_pidfile_excl(const char *state_dir, pid_t pid)
{
	char path[PATH_MAX];
	if ((size_t)snprintf(path, sizeof(path), "%s/pid", state_dir)
	    >= sizeof(path))
		return -1;
	int fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0644);
	if (fd < 0)
		return -1;
	char buf[32];
	int n = snprintf(buf, sizeof(buf), "%ld\n", (long)pid);
	if (write(fd, buf, n) != n) {
		close(fd);
		return -1;
	}
	close(fd);
	return 0;
}

static pid_t
read_pidfile(const char *state_dir)
{
	char path[PATH_MAX];
	if ((size_t)snprintf(path, sizeof(path), "%s/pid", state_dir)
	    >= sizeof(path))
		return -1;
	FILE *f = fopen(path, "r");
	if (!f)
		return -1;
	long pid = -1;
	if (fscanf(f, "%ld", &pid) != 1)
		pid = -1;
	fclose(f);
	return (pid_t)pid;
}

static int
socket_path_for(const char *state_dir, char *out, size_t cap)
{
	if ((size_t)snprintf(out, cap, "%s/ipc.sock", state_dir) >= cap)
		return -1;
	return 0;
}

static int
try_connect_socket(const char *sock_path)
{
	int s = socket(AF_UNIX, SOCK_STREAM, 0);
	if (s < 0)
		return -1;
	struct sockaddr_un addr = {0};
	addr.sun_family = AF_UNIX;
	snprintf(addr.sun_path, sizeof(addr.sun_path), "%s", sock_path);
	if (connect(s, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
		close(s);
		return -1;
	}
	return s;
}

/* somewm prints a C-level FATAL line when it can't load any rc.lua, then
 * limps along with the IPC socket up but no working config. Catch that
 * after the socket comes up so the user sees a real failure instead of
 * a misleading status block. Returns 1 if a FATAL line was found and
 * copies it to `out` (up to cap-1 bytes, NUL terminated). */
static int
log_has_fatal(const char *log_path, char *out, size_t cap)
{
	FILE *f = fopen(log_path, "r");
	if (!f)
		return 0;
	char line[1024];
	int found = 0;
	while (fgets(line, sizeof(line), f)) {
		if (strstr(line, "somewm: FATAL:") || strstr(line, "FATAL:")) {
			size_t len = strlen(line);
			if (len && line[len - 1] == '\n')
				line[len - 1] = '\0';
			snprintf(out, cap, "%s", line);
			found = 1;
			break;
		}
	}
	fclose(f);
	return found;
}

/* Wait until the nested compositor's IPC server answers ping (not just
 * until the socket is connectable - the compositor accepts connections
 * only once its event loop runs). */
static int
wait_for_socket(const char *sock_path, int timeout_ms, pid_t child_pid)
{
	int elapsed = 0;
	while (elapsed < timeout_ms) {
		int s = try_connect_socket(sock_path);
		if (s >= 0) {
			const char *probe = "ping\n";
			ssize_t w = write(s, probe, 5);
			if (w == 5) {
				char buf[256];
				ssize_t n = read(s, buf, sizeof(buf) - 1);
				if (n > 0) {
					close(s);
					return 0;
				}
			}
			close(s);
		}
		int status;
		pid_t r = waitpid(child_pid, &status, WNOHANG);
		if (r == child_pid) {
			fprintf(stderr,
			        "Error: nested compositor exited before IPC was ready\n");
			return -1;
		}
		struct timespec ts = { 0, POLL_INTERVAL_MS * 1000000L };
		nanosleep(&ts, NULL);
		elapsed += POLL_INTERVAL_MS;
	}
	fprintf(stderr,
	        "Error: timed out waiting for nested compositor socket at %s\n",
	        sock_path);
	return -1;
}

static int
pid_alive(pid_t pid)
{
	if (pid <= 1)
		return 0;
	return (kill(pid, 0) == 0 || errno == EPERM) ? 1 : 0;
}

static int
kill_and_wait(pid_t pid, const char *sock_path)
{
	if (!pid_alive(pid))
		return 0;
	if (kill(pid, SIGTERM) < 0 && errno != ESRCH)
		return -1;
	int elapsed = 0;
	while (elapsed < STOP_GRACE_MS) {
		if (!pid_alive(pid))
			return 0;
		if (sock_path && access(sock_path, F_OK) != 0)
			break;
		struct timespec ts = { 0, POLL_INTERVAL_MS * 1000000L };
		nanosleep(&ts, NULL);
		elapsed += POLL_INTERVAL_MS;
	}
	if (!pid_alive(pid))
		return 0;
	kill(pid, SIGKILL);
	elapsed = 0;
	while (elapsed < KILL_GRACE_MS) {
		if (!pid_alive(pid))
			return 0;
		struct timespec ts = { 0, POLL_INTERVAL_MS * 1000000L };
		nanosleep(&ts, NULL);
		elapsed += POLL_INTERVAL_MS;
	}
	return pid_alive(pid) ? -1 : 0;
}


extern int read_response(int sock);

static int
ipc_call(const char *sock_path, const char *command)
{
	int s = try_connect_socket(sock_path);
	if (s < 0) {
		fprintf(stderr, "Error: cannot connect to %s\n", sock_path);
		return 4;
	}
	size_t cmd_len = strlen(command);
	if ((size_t)write(s, command, cmd_len) != cmd_len) {
		perror("write");
		close(s);
		return 4;
	}
	int rc = read_response(s);
	close(s);
	return rc < 0 ? 4 : rc;
}


static int
parse_start_opts(int argc, char *argv[], struct start_opts *opts)
{
	opts->name = DEFAULT_NAME;
	opts->config_path = NULL;
	opts->host = HOST_WAYLAND;
	opts->keybinds = KB_AUTO;
	opts->no_marker = 0;
	opts->force = 0;
	for (int i = 0; i < argc; i++) {
		const char *a = argv[i];
		if (!strcmp(a, "--name") || !strcmp(a, "-n")) {
			if (i + 1 >= argc) {
				fprintf(stderr, "Error: %s requires a value\n", a);
				return -1;
			}
			opts->name = argv[++i];
			if (validate_name(opts->name) < 0)
				return -1;
		} else if (!strcmp(a, "--config") || !strcmp(a, "-c")) {
			if (i + 1 >= argc) {
				fprintf(stderr, "Error: %s requires a value\n", a);
				return -1;
			}
			opts->config_path = argv[++i];
		} else if (!strcmp(a, "--host")) {
			if (i + 1 >= argc) {
				fprintf(stderr, "Error: --host requires a value\n");
				return -1;
			}
			const char *v = argv[++i];
			if (!strcmp(v, "wayland"))
				opts->host = HOST_WAYLAND;
			else if (!strcmp(v, "x11"))
				opts->host = HOST_X11;
			else if (!strcmp(v, "headless"))
				opts->host = HOST_HEADLESS;
			else {
				fprintf(stderr,
				        "Error: --host must be 'wayland', 'x11', or 'headless' (got '%s')\n",
				        v);
				return -1;
			}
		} else if (!strcmp(a, "--keybinds")) {
			if (i + 1 >= argc) {
				fprintf(stderr, "Error: --keybinds requires a value\n");
				return -1;
			}
			const char *v = argv[++i];
			if (!strcmp(v, "auto"))         opts->keybinds = KB_AUTO;
			else if (!strcmp(v, "inhibit")) opts->keybinds = KB_INHIBIT;
			else if (!strcmp(v, "remap"))   opts->keybinds = KB_REMAP;
			else if (!strcmp(v, "none"))    opts->keybinds = KB_NONE;
			else {
				fprintf(stderr,
				        "Error: --keybinds must be auto|inhibit|remap|none (got '%s')\n",
				        v);
				return -1;
			}
		} else if (!strcmp(a, "--no-marker")) {
			opts->no_marker = 1;
		} else if (!strcmp(a, "--force") || !strcmp(a, "-f")) {
			opts->force = 1;
		} else {
			fprintf(stderr, "Error: unknown option for `test start`: %s\n", a);
			return -1;
		}
	}
	return 0;
}


static int
test_stop_named(const char *name)
{
	char state_dir[PATH_MAX];
	if (state_dir_for(name, state_dir, sizeof(state_dir)) < 0)
		return 6;
	struct stat st;
	if (stat(state_dir, &st) < 0) {
		if (errno == ENOENT) {
			fprintf(stderr, "No test instance named '%s'\n", name);
			return 3;
		}
		perror("stat");
		return 6;
	}
	pid_t pid = read_pidfile(state_dir);
	char sock_path[PATH_MAX];
	socket_path_for(state_dir, sock_path, sizeof(sock_path));
	if (pid > 0 && pid_alive(pid)) {
		if (kill_and_wait(pid, sock_path) < 0) {
			fprintf(stderr, "Warning: nested compositor (pid %ld) did not exit cleanly\n",
			        (long)pid);
		}
	}
	if (rmtree(state_dir) < 0) {
		perror("rmtree");
		return 6;
	}
	printf("stopped test instance '%s'\n", name);
	return 0;
}


static int
exec_child(const struct start_opts *opts, const char *state_dir,
           const char *runtime_subdir, const char *sock_path,
           const char *log_path, const char *config_path)
{
	int log_fd = open(log_path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
	if (log_fd < 0) {
		perror("open log");
		_exit(127);
	}
	setsid();
	dup2(log_fd, STDOUT_FILENO);
	dup2(log_fd, STDERR_FILENO);
	close(log_fd);

	/* libwayland resolves a relative WAYLAND_DISPLAY against the
	 * child's XDG_RUNTIME_DIR. We're about to sandbox that, so anchor
	 * WAYLAND_DISPLAY to the parent's runtime dir as an absolute path
	 * before the override. */
	if (opts->host == HOST_WAYLAND) {
		const char *wd = getenv("WAYLAND_DISPLAY");
		const char *xdr = getenv("XDG_RUNTIME_DIR");
		if (wd && *wd && wd[0] != '/' && xdr && *xdr) {
			char abs_wd[PATH_MAX];
			snprintf(abs_wd, sizeof(abs_wd), "%s/%s", xdr, wd);
			setenv("WAYLAND_DISPLAY", abs_wd, 1);
		}
	}

	setenv("XDG_RUNTIME_DIR", runtime_subdir, 1);
	setenv("SOMEWM_SOCKET", sock_path, 1);
	setenv("SOMEWM_TEST_NAME", opts->name, 1);
	setenv("SOMEWM_TEST_STATE_DIR", state_dir, 1);
	const char *mode_str =
		(opts->keybinds == KB_INHIBIT) ? "inhibit"
		: (opts->keybinds == KB_REMAP) ? "remap"
		: (opts->keybinds == KB_NONE)  ? "none"
		: "auto";
	setenv("SOMEWM_TEST_KEYBINDS_MODE", mode_str, 1);
	if (opts->no_marker)
		setenv("SOMEWM_TEST_NO_MARKER", "1", 1);
	if (opts->host == HOST_X11) {
		setenv("WLR_BACKENDS", "x11", 1);
		if (!getenv("WLR_X11_OUTPUTS"))
			setenv("WLR_X11_OUTPUTS", "1", 1);
	} else if (opts->host == HOST_HEADLESS) {
		setenv("WLR_BACKENDS", "headless", 1);
		setenv("WLR_RENDERER", "pixman", 1);
		if (!getenv("WLR_WL_OUTPUTS"))
			setenv("WLR_WL_OUTPUTS", "1", 1);
	} else {
		setenv("WLR_BACKENDS", "wayland", 1);
		if (!getenv("WLR_WL_OUTPUTS"))
			setenv("WLR_WL_OUTPUTS", "1", 1);
	}

	const char *binary = getenv("SOMEWM_BINARY");
	if (!binary || !*binary)
		binary = "somewm";

	if (config_path) {
		execlp(binary, binary, "-c", config_path, (char *)NULL);
	} else {
		execlp(binary, binary, (char *)NULL);
	}
	fprintf(stderr, "exec %s: %s\n", binary, strerror(errno));
	_exit(127);
}

static const char *
detect_wl_socket_name(const char *runtime_subdir)
{
	DIR *d = opendir(runtime_subdir);
	if (!d)
		return NULL;
	static char name[256];
	name[0] = '\0';
	struct dirent *e;
	while ((e = readdir(d))) {
		if (strncmp(e->d_name, "wayland-", 8) == 0
		    && strstr(e->d_name, ".lock") == NULL) {
			snprintf(name, sizeof(name), "%s", e->d_name);
			break;
		}
	}
	closedir(d);
	return name[0] ? name : NULL;
}

/* Read the one-line keybinds_status file the nested compositor writes
 * during startup. Returns "not-applicable" if absent or unreadable. */
static void
read_keybinds_status(const char *state_dir, char *out, size_t cap)
{
	char path[PATH_MAX + 32];
	snprintf(path, sizeof(path), "%s/keybinds_status", state_dir);
	FILE *f = fopen(path, "r");
	if (!f) {
		snprintf(out, cap, "not-applicable");
		return;
	}
	if (!fgets(out, (int)cap, f)) {
		snprintf(out, cap, "not-applicable");
	} else {
		size_t len = strlen(out);
		if (len && out[len - 1] == '\n')
			out[len - 1] = '\0';
	}
	fclose(f);
}

static void
print_status_block(const struct start_opts *opts, pid_t pid,
                   const char *wl_sock, const char *config_resolved,
                   const char *log_path, const char *ipc_sock_path,
                   const char *keybinds_status)
{
	const char *host =
		(opts->host == HOST_X11)       ? "x11"
		: (opts->host == HOST_HEADLESS) ? "headless"
		: "wayland";
	const char *display = wl_sock ? wl_sock : "(unknown)";
	printf("test '%s': pid %ld on %s (host: %s), config %s\n",
	       opts->name, (long)pid, display, host,
	       config_resolved ? config_resolved : "(default)");
	if (!strcmp(keybinds_status, "active")) {
		printf("  keybinds: shortcut inhibitor ACTIVE on outer compositor, Mod4 passes through\n");
	} else if (!strcmp(keybinds_status, "unavailable")) {
		printf("  keybinds: ! outer compositor did not advertise shortcut inhibitor\n");
		printf("            ! Mod4 combos will be intercepted by the host\n");
	} else {
		printf("  keybinds: host=%s, no shortcut-inhibitor negotiation needed\n", host);
	}
	printf("  log:      %s\n", log_path);
	printf("  socket:   %s\n", ipc_sock_path);
	printf("  next:     somewm-client test run  --name %s -- alacritty\n",
	       opts->name);
	printf("            somewm-client test eval --name %s 'return mouse.coords()'\n",
	       opts->name);
	printf("            somewm-client test stop --name %s\n", opts->name);
}

static int
test_start(int argc, char *argv[])
{
	struct start_opts opts;
	if (parse_start_opts(argc, argv, &opts) < 0)
		return 1;

	char state_dir[PATH_MAX];
	if (state_dir_for(opts.name, state_dir, sizeof(state_dir)) < 0)
		return 6;

	struct stat st;
	if (stat(state_dir, &st) == 0) {
		pid_t prev = read_pidfile(state_dir);
		if (prev > 0 && pid_alive(prev)) {
			if (!opts.force) {
				fprintf(stderr,
				        "Error: test instance '%s' already running (pid %ld).\n",
				        opts.name, (long)prev);
				fprintf(stderr,
				        "       Use --force to replace it, or pick a different --name.\n");
				return 2;
			}
			fprintf(stderr, "Replacing existing '%s' (pid %ld)...\n",
			        opts.name, (long)prev);
			char prev_sock[PATH_MAX + 16];
			socket_path_for(state_dir, prev_sock, sizeof(prev_sock));
			kill_and_wait(prev, prev_sock);
		}
		if (rmtree(state_dir) < 0) {
			perror("rmtree existing");
			return 6;
		}
	}

	char runtime_subdir[PATH_MAX + 16];
	char log_path[PATH_MAX + 16];
	char sock_path[PATH_MAX + 16];
	snprintf(runtime_subdir, sizeof(runtime_subdir), "%s/runtime", state_dir);
	snprintf(log_path, sizeof(log_path), "%s/log", state_dir);
	socket_path_for(state_dir, sock_path, sizeof(sock_path));

	if (mkdir_p(state_dir, 0755) < 0 || mkdir_p(runtime_subdir, 0700) < 0) {
		perror("mkdir state dir");
		return 6;
	}

	char config_resolved[PATH_MAX] = {0};
	if (opts.config_path) {
		if (!realpath(opts.config_path, config_resolved)) {
			fprintf(stderr, "Error: config not found: %s\n", opts.config_path);
			rmtree(state_dir);
			return 6;
		}
	}

	if (opts.host == HOST_WAYLAND && !getenv("WAYLAND_DISPLAY")) {
		fprintf(stderr,
		        "Error: WAYLAND_DISPLAY not set; cannot use --host wayland.\n"
		        "       Use --host x11 if you are on an X11 session,\n"
		        "       or --host headless for a non-graphical test instance.\n");
		rmtree(state_dir);
		return 6;
	}
	if (opts.host == HOST_X11 && !getenv("DISPLAY")) {
		fprintf(stderr,
		        "Error: DISPLAY not set; cannot use --host x11.\n");
		rmtree(state_dir);
		return 6;
	}

	pid_t pid = fork();
	if (pid < 0) {
		perror("fork");
		rmtree(state_dir);
		return 5;
	}
	if (pid == 0) {
		exec_child(&opts, state_dir, runtime_subdir, sock_path, log_path,
		           opts.config_path ? config_resolved : NULL);
		_exit(127);
	}

	if (write_pidfile_excl(state_dir, pid) < 0) {
		fprintf(stderr, "Error: could not write pidfile\n");
		kill(pid, SIGTERM);
		rmtree(state_dir);
		return 6;
	}

	if (wait_for_socket(sock_path, WAIT_FOR_SOCKET_MS, pid) < 0) {
		fprintf(stderr,
		        "       Inspect %s for details.\n", log_path);
		kill_and_wait(pid, sock_path);
		if (!getenv("SOMEWM_TEST_KEEP_FAILED"))
			rmtree(state_dir);
		return 5;
	}

	char fatal_line[1024];
	if (log_has_fatal(log_path, fatal_line, sizeof(fatal_line))) {
		fprintf(stderr, "Error: nested compositor reported %s\n", fatal_line);
		fprintf(stderr, "       Inspect %s for the full log.\n", log_path);
		kill_and_wait(pid, sock_path);
		if (!getenv("SOMEWM_TEST_KEEP_FAILED"))
			rmtree(state_dir);
		return 5;
	}

	const char *wl_sock = detect_wl_socket_name(runtime_subdir);
	char keybinds_status[64];
	read_keybinds_status(state_dir, keybinds_status, sizeof(keybinds_status));
	info_write(state_dir, &opts, pid, wl_sock,
	           opts.config_path ? config_resolved : NULL,
	           keybinds_status);
	print_status_block(&opts, pid, wl_sock,
	                   opts.config_path ? config_resolved : NULL,
	                   log_path, sock_path, keybinds_status);
	return 0;
}


struct instance_summary {
	char name[256];
	char host[16];
	char pid[32];
	char display[64];
	char config[PATH_MAX];
	int alive;
};

static int
load_instance_summary(const char *name, struct instance_summary *out)
{
	char state_dir[PATH_MAX];
	if (state_dir_for(name, state_dir, sizeof(state_dir)) < 0)
		return -1;
	snprintf(out->name, sizeof(out->name), "%s", name);
	if (info_read_field(state_dir, "host", out->host, sizeof(out->host)) < 0)
		snprintf(out->host, sizeof(out->host), "?");
	if (info_read_field(state_dir, "pid", out->pid, sizeof(out->pid)) < 0)
		snprintf(out->pid, sizeof(out->pid), "?");
	if (info_read_field(state_dir, "wl_socket_name", out->display,
	                    sizeof(out->display)) < 0)
		out->display[0] = '\0';
	if (info_read_field(state_dir, "config_path", out->config,
	                    sizeof(out->config)) < 0)
		out->config[0] = '\0';
	char sock_path[PATH_MAX];
	socket_path_for(state_dir, sock_path, sizeof(sock_path));
	int s = try_connect_socket(sock_path);
	out->alive = (s >= 0);
	if (s >= 0)
		close(s);
	return 0;
}

static int
test_list(int json_mode)
{
	char rd[PATH_MAX];
	if (runtime_dir(rd, sizeof(rd)) < 0)
		return 6;
	char root[PATH_MAX];
	if ((size_t)snprintf(root, sizeof(root), "%s/%s", rd, STATE_DIR_NAME)
	    >= sizeof(root))
		return 6;

	DIR *d = opendir(root);
	if (!d) {
		if (json_mode)
			printf("[]\n");
		else
			printf("(no test instances)\n");
		return 0;
	}

	int first = 1;
	int rows = 0;
	if (json_mode)
		printf("[");

	struct dirent *e;
	while ((e = readdir(d))) {
		if (e->d_name[0] == '.')
			continue;
		struct instance_summary s;
		if (load_instance_summary(e->d_name, &s) < 0)
			continue;
		if (json_mode) {
			printf("%s{\"name\":\"%s\",\"host\":\"%s\",\"pid\":%s,"
			       "\"display\":\"%s\",\"config\":\"%s\",\"alive\":%s}",
			       first ? "" : ",", s.name, s.host,
			       s.pid[0] ? s.pid : "null",
			       s.display, s.config, s.alive ? "true" : "false");
		} else {
			if (rows == 0)
				printf("%-16s %-7s %-10s %-12s %s\n",
				       "NAME", "HOST", "PID", "DISPLAY", "CONFIG");
			printf("%-16s %-7s %-10s %-12s %s%s\n", s.name, s.host, s.pid,
			       s.display[0] ? s.display : "-",
			       s.config[0] ? s.config : "-",
			       s.alive ? "" : "  (stale)");
		}
		first = 0;
		rows++;
	}
	closedir(d);
	if (json_mode)
		printf("]\n");
	else if (rows == 0)
		printf("(no test instances)\n");
	return 0;
}


static int
resolve_named_socket(const char *name, char *out, size_t cap)
{
	char state_dir[PATH_MAX];
	if (state_dir_for(name, state_dir, sizeof(state_dir)) < 0)
		return -1;
	if (socket_path_for(state_dir, out, cap) < 0)
		return -1;
	if (access(out, F_OK) < 0) {
		fprintf(stderr, "Error: no test instance named '%s'\n", name);
		return -1;
	}
	return 0;
}

static const char *
extract_name(int *argc, char **argv[])
{
	int n = *argc;
	char **a = *argv;
	const char *name = DEFAULT_NAME;
	int i = 0;
	while (i < n) {
		if (!strcmp(a[i], "--name") || !strcmp(a[i], "-n")) {
			if (i + 1 >= n)
				return NULL;
			name = a[i + 1];
			for (int j = i; j + 2 < n; j++)
				a[j] = a[j + 2];
			n -= 2;
		} else if (!strcmp(a[i], "--")) {
			for (int j = i; j + 1 < n; j++)
				a[j] = a[j + 1];
			n -= 1;
			break;
		} else {
			i++;
		}
	}
	*argc = n;
	*argv = a;
	if (validate_name(name) < 0)
		return NULL;
	return name;
}

static int
ipc_send_join(const char *sock_path, const char *verb, int argc, char *argv[])
{
	char cmd[IPC_BUFFER_SIZE];
	int off = snprintf(cmd, sizeof(cmd), "%s", verb);
	for (int i = 0; i < argc; i++) {
		if (off + 1 >= (int)sizeof(cmd))
			return 4;
		off += snprintf(cmd + off, sizeof(cmd) - off, " %s", argv[i]);
	}
	if (off + 1 >= (int)sizeof(cmd))
		return 4;
	cmd[off++] = '\n';
	cmd[off] = '\0';
	return ipc_call(sock_path, cmd);
}

static int
test_run(int argc, char *argv[])
{
	const char *name = extract_name(&argc, &argv);
	if (!name)
		return 1;
	if (argc < 1) {
		fprintf(stderr, "Usage: somewm-client test run [--name N] -- <command> [args...]\n");
		return 1;
	}
	char sock_path[PATH_MAX];
	if (resolve_named_socket(name, sock_path, sizeof(sock_path)) < 0)
		return 3;
	return ipc_send_join(sock_path, "exec", argc, argv);
}

static int
test_eval(int argc, char *argv[])
{
	const char *name = extract_name(&argc, &argv);
	if (!name)
		return 1;
	if (argc < 1) {
		fprintf(stderr, "Usage: somewm-client test eval [--name N] <lua-code>\n");
		return 1;
	}
	char sock_path[PATH_MAX];
	if (resolve_named_socket(name, sock_path, sizeof(sock_path)) < 0)
		return 3;
	return ipc_send_join(sock_path, "eval", argc, argv);
}

static int
test_reload(int argc, char *argv[])
{
	const char *name = extract_name(&argc, &argv);
	if (!name)
		return 1;
	char sock_path[PATH_MAX];
	if (resolve_named_socket(name, sock_path, sizeof(sock_path)) < 0)
		return 3;
	return ipc_call(sock_path, "reload\n");
}


static int
test_logs(int argc, char *argv[])
{
	const char *name = DEFAULT_NAME;
	int follow = 0;
	for (int i = 0; i < argc; i++) {
		if (!strcmp(argv[i], "--name") || !strcmp(argv[i], "-n")) {
			if (i + 1 >= argc)
				return 1;
			name = argv[++i];
		} else if (!strcmp(argv[i], "-f") || !strcmp(argv[i], "--follow")) {
			follow = 1;
		}
	}
	if (validate_name(name) < 0)
		return 1;
	char state_dir[PATH_MAX];
	if (state_dir_for(name, state_dir, sizeof(state_dir)) < 0)
		return 6;
	char log_path[PATH_MAX + 16];
	snprintf(log_path, sizeof(log_path), "%s/log", state_dir);
	if (access(log_path, F_OK) < 0) {
		fprintf(stderr, "Error: no test instance named '%s' (no log at %s)\n",
		        name, log_path);
		return 3;
	}
	if (follow)
		execlp("tail", "tail", "-n", "+1", "-F", log_path, (char *)NULL);
	else
		execlp("cat", "cat", log_path, (char *)NULL);
	perror("exec");
	return 6;
}


static int
test_stop_cmd(int argc, char *argv[])
{
	const char *name = DEFAULT_NAME;
	for (int i = 0; i < argc; i++) {
		if (!strcmp(argv[i], "--name") || !strcmp(argv[i], "-n")) {
			if (i + 1 >= argc) {
				fprintf(stderr, "Error: --name requires a value\n");
				return 1;
			}
			name = argv[++i];
		}
	}
	if (validate_name(name) < 0)
		return 1;
	return test_stop_named(name);
}


void
test_orchestrator_print_usage(const char *progname)
{
	fprintf(stderr, "TEST MODE (inspired by AWMTT - https://github.com/serialoverflow/awmtt):\n");
	fprintf(stderr, "  %s test start  [--config FILE] [--name NAME] [--host wayland|x11]\n", progname);
	fprintf(stderr, "                       [--keybinds auto|inhibit|remap|none] [--no-marker] [--force]\n");
	fprintf(stderr, "  %s test stop   [--name NAME]\n", progname);
	fprintf(stderr, "  %s test list   [--json]\n", progname);
	fprintf(stderr, "  %s test run    [--name NAME] -- <command> [args...]\n", progname);
	fprintf(stderr, "  %s test eval   [--name NAME] <lua-code>\n", progname);
	fprintf(stderr, "  %s test reload [--name NAME]\n", progname);
	fprintf(stderr, "  %s test logs   [--name NAME] [-f]\n\n", progname);
	fprintf(stderr, "  Default --name is 'test'. State lives at $XDG_RUNTIME_DIR/somewm-test/<name>/.\n");
}

int
test_orchestrator_run(int argc, char *argv[], int json_mode)
{
	if (argc < 1) {
		test_orchestrator_print_usage("somewm-client");
		return 1;
	}
	const char *verb = argv[0];
	int rest_argc = argc - 1;
	char **rest = argv + 1;
	if (!strcmp(verb, "start"))  return test_start(rest_argc, rest);
	if (!strcmp(verb, "stop"))   return test_stop_cmd(rest_argc, rest);
	if (!strcmp(verb, "list"))   return test_list(json_mode);
	if (!strcmp(verb, "run"))    return test_run(rest_argc, rest);
	if (!strcmp(verb, "eval"))   return test_eval(rest_argc, rest);
	if (!strcmp(verb, "reload")) return test_reload(rest_argc, rest);
	if (!strcmp(verb, "logs"))   return test_logs(rest_argc, rest);
	if (!strcmp(verb, "--help") || !strcmp(verb, "-h")) {
		test_orchestrator_print_usage("somewm-client");
		return 0;
	}
	fprintf(stderr, "Error: unknown `test` verb: %s\n", verb);
	test_orchestrator_print_usage("somewm-client");
	return 1;
}
