// The opendir guard (pocket/translation/libSystem.B/ContainerPaths.c) on the host. A folder
// above HOME whose listing is refused (mode 0111, as the sandbox refuses /var/mobile on the
// device) must open as HOME; one that is not above HOME, or does not exist, must fail as
// before. Run as a normal user (root reads every folder).
#include "ContainerPaths.h"
#include <assert.h>
#include <dirent.h>
#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

void AKLogC(const char *fmt, ...) { (void)fmt; }

int main(void) {
    // The ancestor rule, /private ignored on either side.
    const char *home = "/var/mobile/Containers/Data/Application/ABC";
    assert(cp_is_ancestor("/", home));
    assert(cp_is_ancestor("/var", home) && cp_is_ancestor("/var/", home) && cp_is_ancestor("/private/var", home));
    assert(cp_is_ancestor("/var/mobile/Containers/Data/Application", home));
    assert(cp_is_ancestor("/private/var/mobile", "/private/var/mobile/Containers/Data/Application/ABC"));
    assert(!cp_is_ancestor(home, home));                                   // home itself opens normally
    assert(!cp_is_ancestor("/var/mobile/Containers/Data/Application/AB", home));   // a sibling's prefix
    assert(!cp_is_ancestor("/var/mobile/Library", home));
    assert(!cp_is_ancestor("relative", home) && !cp_is_ancestor("/var", NULL) && !cp_is_ancestor(NULL, home));

    if (geteuid() == 0) { puts("paths: ok (folder permissions not checked as root)"); return 0; }
    char root[] = "/tmp/pocket-paths-XXXXXX";
    assert(mkdtemp(root));
    char locked[256], container[256], other[256];
    snprintf(locked, sizeof locked, "%s/locked", root);
    snprintf(container, sizeof container, "%s/locked/home", root);
    snprintf(other, sizeof other, "%s/other", root);
    assert(!mkdir(locked, 0755) && !mkdir(container, 0755) && !mkdir(other, 0755));
    assert(!chmod(locked, 0111) && !chmod(other, 0111));
    setenv("HOME", container, 1);

    DIR *d = opendir(locked);   // refused by the system, above HOME: HOME instead
    assert(d);
    closedir(d);
    errno = 0;
    assert(!opendir(other) && errno == EACCES);   // refused and not above HOME: refused
    char missing[256];
    snprintf(missing, sizeof missing, "%s/missing", root);
    errno = 0;
    assert(!opendir(missing) && errno == ENOENT);  // not there: as before
    d = opendir(container);
    assert(d);
    closedir(d);

    chmod(locked, 0755); chmod(other, 0755);
    rmdir(container); rmdir(locked); rmdir(other); rmdir(root);
    puts("paths: ok");
    return 0;
}
