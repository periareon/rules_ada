#include "registry.h"

__attribute__((constructor)) static void plugin_init(void) {
    register_plugin();
}
