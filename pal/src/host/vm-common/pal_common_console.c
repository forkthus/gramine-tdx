/* SPDX-License-Identifier: LGPL-3.0-or-later */
/* Copyright (C) 2023 Intel Corporation */

/*
 * Operations to handle the console device. In VM PALs, the console is emulated via virtio console
 * device. Note that both host process's stderr/stdout streams and Gramine's internal messages
 * (like logs) are multiplexed onto a single virtio console output.
 *
 * Note that some operations (like stat and truncate) are resolved in LibOS and don't have a
 * counterpart in PAL.
 */

#include "api.h"
#include "pal.h"
#include "pal_common.h"
#include "pal_error.h"
#include "pal_internal.h"
#include "perm.h"
#include "spinlock.h"

#include "kernel_sched.h"
#include "kernel_virtio.h"

#define CONSOLE_OUT_CHUNK_SIZE 1024UL

/*
* In the TDX PAL, the console is tunneled over virtio-vsock to the parent VM
* using a fixed base port:
*   - 33222 for stdout/stderr (PAL_ACCESS_WRONLY)
*   - 33223 for stdin        (PAL_ACCESS_RDONLY)
*/
#define GRAMINE_CONSOLE_VSOCK_FIXED_BASE_PORT 33222

static int g_console_reader_futex;

static int get_console_vsock_base_port(void) {
    if (strcmp(XSTRINGIFY(HOST_TYPE), "TDX") == 0)
        return GRAMINE_CONSOLE_VSOCK_FIXED_BASE_PORT;
    return -1;
}

static int console_vsock_connect(uint32_t port) {
    int fd = virtio_vsock_socket(AF_VSOCK, VIRTIO_VSOCK_TYPE_STREAM, /*protocol=*/0);
    if (fd < 0)
        return fd;

    struct sockaddr_vm addr_vm = { .svm_port = port, .svm_cid = g_vsock->host_cid };
    int ret = virtio_vsock_connect(fd, &addr_vm, sizeof(addr_vm), VSOCK_CONNECT_TIMEOUT_US);
    if (ret < 0) {
        int close_ret = virtio_vsock_close(fd, VSOCK_CLOSE_TIMEOUT_US);
        if (close_ret < 0)
            log_error("closing console vsock fd %d failed: %s", fd, pal_strerror(close_ret));
        return ret;
    }

    return fd;
}

void thread_wakeup_console(void) {
    sched_thread_wakeup(&g_console_reader_futex);
}

int pal_common_console_open(struct pal_handle** handle, const char* type, const char* uri,
                            enum pal_access access, pal_share_flags_t share,
                            enum pal_create_mode create, pal_stream_options_t options) {
    __UNUSED(uri);
    __UNUSED(share);
    __UNUSED(create);
    __UNUSED(options);

    if (strcmp(type, URI_TYPE_CONSOLE))
        return -PAL_ERROR_INVAL;

    if (access != PAL_ACCESS_RDONLY && access != PAL_ACCESS_WRONLY)
        return -PAL_ERROR_INVAL;

    struct pal_handle* hdl = calloc(1, sizeof(*hdl));
    if (!hdl)
        return -PAL_ERROR_NOMEM;

    hdl->hdr.type = PAL_TYPE_CONSOLE;
    spinlock_init(&hdl->console.lock);

    hdl->flags = access == PAL_ACCESS_RDONLY ? PAL_HANDLE_FD_READABLE : PAL_HANDLE_FD_WRITABLE;

    int base_port = get_console_vsock_base_port();
    if (base_port > 0) {
        uint32_t port = access == PAL_ACCESS_RDONLY ? (uint32_t)base_port + 1 : (uint32_t)base_port;
        int fd = console_vsock_connect(port);
        if (fd < 0) {
            free(hdl);
            return fd;
        }
        hdl->console.fd = fd;
    } else {
        hdl->console.fd = access == PAL_ACCESS_RDONLY ? /*host stdin*/0 : /*host stdout*/1;
    }

    *handle = hdl;
    return 0;
}

int64_t pal_common_console_read(struct pal_handle* handle, uint64_t offset, uint64_t size,
                                void* buffer) {
    assert(handle->hdr.type == PAL_TYPE_CONSOLE);

    if (offset)
        return -PAL_ERROR_INVAL;

    if (!(handle->flags & PAL_HANDLE_FD_READABLE))
        return -PAL_ERROR_DENIED;

    spinlock_lock(&handle->console.lock);

    int base_port = get_console_vsock_base_port();

    int64_t bytes;
    while (true) {
        if (base_port > 0) {
            bytes = virtio_vsock_read(handle->console.fd, buffer, size);
            if (bytes < 0) {
                if (bytes == -PAL_ERROR_TRYAGAIN) {
                    sched_thread_wait(&g_streams_waiting_events_futex, &handle->console.lock);
                    continue;
                }
            }
        } else {
            bytes = virtio_console_read(buffer, size);
            if (bytes < 0) {
                if (bytes == -PAL_ERROR_TRYAGAIN) {
                    sched_thread_wait(&g_console_reader_futex, &handle->console.lock);
                    continue;
                }
            }
        }
        break;
    }

    spinlock_unlock(&handle->console.lock);
    return bytes;
}

int64_t pal_common_console_write(struct pal_handle* handle, uint64_t offset, uint64_t size,
                                 const void* buffer) {
    assert(handle->hdr.type == PAL_TYPE_CONSOLE);

    if (offset)
        return -PAL_ERROR_INVAL;

    if (!(handle->flags & PAL_HANDLE_FD_WRITABLE))
        return -PAL_ERROR_DENIED;

    int base_port = get_console_vsock_base_port();

    if (base_port > 0) {
        spinlock_lock(&handle->console.lock);

        size_t written = 0;
        while (written < size) {
            int64_t bytes = virtio_vsock_write(handle->console.fd, (const char*)buffer + written,
                                               size - written);
            if (bytes < 0) {
                if (bytes == -PAL_ERROR_TRYAGAIN) {
                    sched_thread_wait(&g_streams_waiting_events_futex, &handle->console.lock);
                    continue;
                }
                spinlock_unlock(&handle->console.lock);
                return bytes;
            }
            written += (size_t)bytes;
        }

        spinlock_unlock(&handle->console.lock);
        return (int64_t)size;
    }

    uint64_t written = 0;
    while (written < size) {
        uint64_t to_write = MIN(size - written, CONSOLE_OUT_CHUNK_SIZE);
        int ret = virtio_console_nprint(buffer + written, to_write);
        if (ret < 0) {
            if (ret == -PAL_ERROR_TRYAGAIN)
                continue;
            if (ret == -PAL_ERROR_NOMEM) {
                /* this error means that we exceed the total capacity of virtio console buffer;
                 * if this happens then our CONSOLE_OUT_CHUNK_SIZE is too big */
                BUG();
            }
            return ret;
        }
        written += to_write;
    }

    return (int64_t)size; /* virtio-console always prints the whole buffer */
}

void pal_common_console_destroy(struct pal_handle* handle) {
    assert(handle->hdr.type == PAL_TYPE_CONSOLE);

    int base_port = get_console_vsock_base_port();
    if (base_port > 0) {
        spinlock_lock(&handle->console.lock);
        int ret = virtio_vsock_close(handle->console.fd, VSOCK_CLOSE_TIMEOUT_US);
        spinlock_unlock(&handle->console.lock);

        if (ret < 0)
            log_error("closing console vsock fd %d failed: %s", 
                       handle->console.fd, pal_strerror(ret));
    }

    free(handle);
}

int pal_common_console_flush(struct pal_handle* handle) {
    assert(handle->hdr.type == PAL_TYPE_CONSOLE);

    if (!(handle->flags & PAL_HANDLE_FD_WRITABLE))
        return -PAL_ERROR_DENIED;

    return 0; /* no-op */
}
