#ifndef IPC_H
#define IPC_H

#include <wayland-server-core.h>

/**
 * Initialize IPC socket and integrate with Wayland event loop
 * Creates a Unix domain socket at $XDG_RUNTIME_DIR/somewm-socket
 * and registers it with the event loop for non-blocking I/O.
 *
 * @param event_loop The Wayland event loop to integrate with
 * @return 0 on success, -1 on error
 */
int ipc_init(struct wl_event_loop *event_loop);

/**
 * Cleanup IPC resources
 * Closes all client connections and the listening socket.
 * Removes the socket file from the filesystem.
 */
void ipc_cleanup(void);

/**
 * Get the IPC socket path
 * Useful for error messages and debugging
 *
 * @return Path to the IPC socket file
 */
const char *ipc_get_socket_path(void);

#endif /* IPC_H */
