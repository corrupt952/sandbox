#ifndef CPLUGINIPC_H
#define CPLUGINIPC_H

#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

// The CMSG_* macros are C macros, so descriptor passing cannot be expressed in
// Swift without re-deriving Darwin's cmsg alignment by hand. This shim keeps the
// real macros on the C side and hands Swift a flat interface.

/// When `fd_to_send` is >= 0 the descriptor is attached as SCM_RIGHTS ancillary data.
ssize_t ipc_send(int sock, const void *buf, size_t len, int fd_to_send);

/// Extra descriptors beyond the first are closed, so a misbehaving peer cannot
/// exhaust the receiver's descriptor table.
ssize_t ipc_recv(int sock, void *buf, size_t len, int *out_fd);

/// `ri_phys_footprint` from proc_pid_rusage(RUSAGE_INFO_V4). Returns 0 on success.
int ipc_phys_footprint(pid_t pid, uint64_t *out_footprint);

/// `*out_errno` receives errno either way — under App Sandbox the errno is itself
/// the observation.
int ipc_child_count(pid_t pid, int *out_errno);

int ipc_thread_count(pid_t pid);

/// The JIT executable allocator region only exists once JSC actually compiled
/// something, so this answers "is the JIT running here" directly rather than
/// inferring it from a timing benchmark. Returns 0 on success.
int ipc_jit_region_bytes(uint64_t *out_jit_allocator, uint64_t *out_jit_register_file,
                         uint64_t *out_jscore_heap);

#endif
