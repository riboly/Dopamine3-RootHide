#ifndef TRUSTCACHE_PERSISTENCE_H
#define TRUSTCACHE_PERSISTENCE_H

#include <stdint.h>
#include "trustcache_structs.h"

#define JB_TRUSTCACHE_PERSISTENT_MAX_ENTRIES 32768U

int jb_trustcache_persistent_load(trustcache_entry_v1 **entriesOut, uint32_t *entryCountOut);
int jb_trustcache_persistent_merge(const trustcache_entry_v1 *entries, uint32_t entryCount);
int jb_trustcache_persistent_clear(void);

#endif
