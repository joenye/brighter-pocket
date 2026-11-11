// The folders above the app's container, as the client's directory walk expects them.
//
// The client makes its save folder (Application Support/Fen Research/...) with a walk of
// its own from the root: for each ancestor it calls opendir, and only where that fails,
// mkdir; a failed mkdir ends the walk. On a Mac every ancestor opens. On iOS the
// sandbox may refuse to open the folders above the app's container (/var/mobile,
// .../Containers/Data/Application), and then mkdir answers EEXIST, the walk stops, and
// the client's settings store is never created. So for an ancestor of the app's home
// folder that the system refused to open, this opendir opens the home folder instead:
// the walk only checks that the call succeeds, and closes it at once. Everything else
// is the system's opendir, unchanged.
#include "ContainerPaths.h"
#include <dirent.h>
#include <dlfcn.h>
#include <errno.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>

void AKLogC(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
#define SYSTEM_LIBRARY "/usr/lib/libSystem.B.dylib"

static void *real(const char *name, void *wrapper) {
    void *function = dlsym(RTLD_NEXT, name);
    if (!function || function == wrapper) {
        void *handle = dlopen(SYSTEM_LIBRARY, RTLD_LAZY | RTLD_NOLOAD);
        function = handle ? dlsym(handle, name) : NULL;
        if (handle) dlclose(handle);
    }
    return function == wrapper ? NULL : function;
}

// /private/var and /var name the same folder on iOS; compare without the prefix.
static const char *without_private(const char *path) {
    return strncmp(path, "/private/", 9) ? path : path + 8;
}

bool cp_is_ancestor(const char *path, const char *home) {
    if (!path || !home || path[0] != '/' || home[0] != '/') return false;
    path = without_private(path);
    home = without_private(home);
    size_t length = strlen(path);
    while (length > 1 && path[length - 1] == '/') length--;
    if (length == 1) return true;   // the root
    return !strncmp(path, home, length) && home[length] == '/';
}

DIR *opendir(const char *path) {
    static DIR *(*system_opendir)(const char *);
    if (!system_opendir) system_opendir = (DIR *(*)(const char *))real("opendir", (void *)opendir);
    if (!system_opendir) { errno = ENOSYS; return NULL; }
    DIR *directory = system_opendir(path);
    if (directory || (errno != EPERM && errno != EACCES)) return directory;
    int refused = errno;
    const char *home = getenv("HOME");
    if (!cp_is_ancestor(path, home)) { errno = refused; return NULL; }
    directory = system_opendir(home);
    if (directory) AKLogC("[paths] opendir(%s) refused by the sandbox: answered with the app's home folder\n", path);
    else errno = refused;
    return directory;
}
