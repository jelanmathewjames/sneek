// Small C shims for Linux libc facilities Swift's Glibc overlay does not expose.
// prctl(2) is variadic, and variadic C functions are not callable from Swift;
// `struct ucred` / `SO_PEERCRED` sit behind feature-test macros the overlay does
// not set, so they are not in scope from Swift either.
#ifndef CPRCTL_H
#define CPRCTL_H

/// Returns the raw prctl(2) result: 0 on success, -1 on failure (errno set).
int sneek_prctl_set_dumpable(int value);

/// Credentials of the process at the other end of the connected unix socket `fd`,
/// read with SO_PEERCRED. Returns 0 on success (uid, gid and pid filled in),
/// -1 on failure (errno set).
int sneek_peer_cred(int fd, unsigned int *uid, unsigned int *gid, int *pid);

#endif
