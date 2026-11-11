// The container-ancestor rule of ContainerPaths.c, for its tests.
#pragma once
#include <stdbool.h>

// Whether path is the root or a folder above home (a /private prefix on either ignored).
bool cp_is_ancestor(const char *path, const char *home);
