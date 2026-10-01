#include "registry.h"

static int count = 0;

void register_plugin(void) { count++; }

int registered_plugins(void) { return count; }
