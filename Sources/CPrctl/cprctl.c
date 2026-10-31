#define _GNU_SOURCE
#include "include/cprctl.h"
#include <sys/prctl.h>
#include <sys/socket.h>
#include <sys/types.h>

int sneek_prctl_set_dumpable(int value) {
    return prctl(PR_SET_DUMPABLE, value, 0, 0, 0);
}

int sneek_peer_cred(int fd, unsigned int *uid, unsigned int *gid, int *pid) {
    struct ucred cred;
    socklen_t len = sizeof(cred);
    if (getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &cred, &len) != 0) return -1;
    // A short read would leave part of `cred` uninitialised; report failure rather
    // than hand Swift a plausible-looking pid that is really stack garbage.
    if (len != sizeof(cred)) return -1;
    if (uid) *uid = (unsigned int)cred.uid;
    if (gid) *gid = (unsigned int)cred.gid;
    if (pid) *pid = (int)cred.pid;
    return 0;
}
