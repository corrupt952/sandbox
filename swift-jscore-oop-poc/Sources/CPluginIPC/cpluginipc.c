#include "include/cpluginipc.h"

#include <errno.h>
#include <libproc.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <mach/vm_statistics.h>
#include <string.h>
#include <sys/proc_info.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/uio.h>
#include <unistd.h>

ssize_t ipc_send(int sock, const void *buf, size_t len, int fd_to_send) {
  struct iovec iov;
  iov.iov_base = (void *)buf;
  iov.iov_len = len;

  struct msghdr msg;
  memset(&msg, 0, sizeof(msg));
  msg.msg_iov = &iov;
  msg.msg_iovlen = 1;

  union {
    struct cmsghdr align;
    char bytes[CMSG_SPACE(sizeof(int))];
  } control;

  if (fd_to_send >= 0) {
    memset(&control, 0, sizeof(control));
    msg.msg_control = control.bytes;
    msg.msg_controllen = sizeof(control.bytes);
    struct cmsghdr *cmsg = CMSG_FIRSTHDR(&msg);
    cmsg->cmsg_level = SOL_SOCKET;
    cmsg->cmsg_type = SCM_RIGHTS;
    cmsg->cmsg_len = CMSG_LEN(sizeof(int));
    memcpy(CMSG_DATA(cmsg), &fd_to_send, sizeof(int));
  }

  return sendmsg(sock, &msg, 0);
}

ssize_t ipc_recv(int sock, void *buf, size_t len, int *out_fd) {
  if (out_fd) {
    *out_fd = -1;
  }

  struct iovec iov;
  iov.iov_base = buf;
  iov.iov_len = len;

  struct msghdr msg;
  memset(&msg, 0, sizeof(msg));
  msg.msg_iov = &iov;
  msg.msg_iovlen = 1;

  union {
    struct cmsghdr align;
    char bytes[CMSG_SPACE(sizeof(int) * 4)];
  } control;
  memset(&control, 0, sizeof(control));
  msg.msg_control = control.bytes;
  msg.msg_controllen = sizeof(control.bytes);

  ssize_t n = recvmsg(sock, &msg, 0);
  if (n < 0) {
    return n;
  }

  for (struct cmsghdr *cmsg = CMSG_FIRSTHDR(&msg); cmsg != NULL;
       cmsg = CMSG_NXTHDR(&msg, cmsg)) {
    if (cmsg->cmsg_level != SOL_SOCKET || cmsg->cmsg_type != SCM_RIGHTS) {
      continue;
    }
    size_t payload = cmsg->cmsg_len - CMSG_LEN(0);
    size_t count = payload / sizeof(int);
    for (size_t i = 0; i < count; i++) {
      int fd;
      memcpy(&fd, CMSG_DATA(cmsg) + i * sizeof(int), sizeof(int));
      if (out_fd && *out_fd < 0) {
        *out_fd = fd;
      } else {
        close(fd);
      }
    }
  }

  return n;
}

int ipc_phys_footprint(pid_t pid, uint64_t *out_footprint) {
  struct rusage_info_v4 info;
  memset(&info, 0, sizeof(info));
  int rc = proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&info);
  if (rc != 0) {
    return rc;
  }
  if (out_footprint) {
    *out_footprint = info.ri_phys_footprint;
  }
  return 0;
}

int ipc_child_count(pid_t pid, int *out_errno) {
  errno = 0;
  int rc = proc_listchildpids(pid, NULL, 0);
  if (out_errno) {
    *out_errno = errno;
  }
  return rc;
}

int ipc_jit_region_bytes(uint64_t *out_jit_allocator, uint64_t *out_jit_register_file,
                         uint64_t *out_jscore_heap) {
  uint64_t allocator = 0;
  uint64_t register_file = 0;
  uint64_t heap = 0;

  mach_vm_address_t address = 0;
  natural_t depth = 0;

  while (1) {
    mach_vm_size_t size = 0;
    vm_region_submap_info_data_64_t info;
    mach_msg_type_number_t count = VM_REGION_SUBMAP_INFO_COUNT_64;

    kern_return_t kr = mach_vm_region_recurse(mach_task_self(), &address, &size, &depth,
                                              (vm_region_recurse_info_t)&info, &count);
    if (kr != KERN_SUCCESS) {
      break;
    }

    if (info.is_submap) {
      // Descend into the submap without advancing, so its entries are visited.
      depth++;
      continue;
    }

    switch (info.user_tag) {
      case VM_MEMORY_JAVASCRIPT_JIT_EXECUTABLE_ALLOCATOR:
        allocator += size;
        break;
      case VM_MEMORY_JAVASCRIPT_JIT_REGISTER_FILE:
        register_file += size;
        break;
      case VM_MEMORY_JAVASCRIPT_CORE:
        heap += size;
        break;
      default:
        break;
    }

    address += size;
  }

  if (out_jit_allocator) *out_jit_allocator = allocator;
  if (out_jit_register_file) *out_jit_register_file = register_file;
  if (out_jscore_heap) *out_jscore_heap = heap;
  return 0;
}

int ipc_thread_count(pid_t pid) {
  struct proc_taskinfo info;
  memset(&info, 0, sizeof(info));
  int rc = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, sizeof(info));
  if (rc != (int)sizeof(info)) {
    return -1;
  }
  return (int)info.pti_threadnum;
}
