#include "trustcache.h"

#include <sys/types.h>
#include <sys/stat.h>
#include <unistd.h>
#include <errno.h>
#include <os/lock.h>
#include <os/log.h>
#include <pthread.h>
#include "kernel.h"
#include "info.h"
#include "primitives.h"
#include "trustcache_persistence.h"

static const char kTrustCacheStabilityMarker[] __attribute__((used)) = "TRUSTCACHE-KALLOC-18B2";
static const char kTrustCachePersistenceMarker[] __attribute__((used)) = "TRUSTCACHE-PERSIST-18C1";
static os_unfair_lock gJbTrustCacheLock = OS_UNFAIR_LOCK_INIT;
static pthread_mutex_t gJbTrustCacheOperationLock = PTHREAD_MUTEX_INITIALIZER;
static bool is_cdhash_trustcached_unlocked(cdhash_t CDHash);

void _trustcache_file_init(trustcache_file_v1 *file)
{
	memset(file, 0, sizeof(*file));
	file->version = 1;
	uuid_generate(file->uuid);
}

// iOS 16:
// ppl_trust_cache_rt has trustcache runtime
// **(ppl_trust_cache_rt+0x20) seems to have the loaded trustcache linked list
// trustcache struct changed, "next" is still at +0x0, but "this" is at +0x20

uint64_t _trustcache_list_get_start(void)
{
	if (ksymbol(pmap_image4_trust_caches)) { // iOS <=15
		return kread64(ksymbol(pmap_image4_trust_caches));
	}
	else if (ksymbol(ppl_trust_cache_rt)) {  // iOS >=16, PPL
		return kread64(kread64(ksymbol(ppl_trust_cache_rt) + 0x20));
	}
	else if (ksymbol_txm(txm_trustcache_root)) { // iOS >=17, SPTM/TXM
		return kread64(kread64(ksymbol_txm(txm_trustcache_root) + 0x20));
	}

	return 0;
}

int _trustcache_list_set_start(uint64_t newStart)
{
	if (ksymbol(pmap_image4_trust_caches)) { // iOS <=15
		return kwrite64(ksymbol(pmap_image4_trust_caches), newStart);
	}
	else if (ksymbol(ppl_trust_cache_rt)) {  // iOS >=16
		uint64_t listHead = kread64(ksymbol(ppl_trust_cache_rt) + 0x20);
		if (!listHead) return -1;
		return kwrite64(listHead, newStart);
	}
	else if (ksymbol_txm(txm_trustcache_root)) { // iOS >=17, SPTM/TXM
		uint64_t listHead = kread64(ksymbol_txm(txm_trustcache_root) + 0x20);
		if (!listHead) return -1;
		return kwrite64(listHead, newStart);
	}
	return -1;
}

void _trustcache_list_enumerate(void (^enumerateBlock)(uint64_t tcKaddr, bool *stop))
{
	uint64_t curTC = _trustcache_list_get_start();
	while(curTC != 0) {
		bool stop = false;
		enumerateBlock(curTC, &stop);
		if (stop) break;
		curTC = kread64(curTC + koffsetof(trustcache, nextptr));
	}
}

int trustcache_list_insert(uint64_t tcToInsert)
{
	if (!tcToInsert) return -1;

	if (ksymbol(SPTMArgs)) {
		// On SPTM/TXM devices, our allocations are read-only by TXM so it cannot write to the prevptr field 
		// Since TXM will only add trust caches to the start of the list, we simply add ours to the end
		// We avoid a panic when loading a new trustcache, since we guarantee the first trustcache in the list is always writable

		__block uint64_t lastTC = 0;
		_trustcache_list_enumerate(^(uint64_t tcKaddr, bool *stop) {
			lastTC = tcKaddr;
		});
		if (!lastTC) return -1;

		if (koffsetof(trustcache, prevptr)) {
			if (kwrite64(tcToInsert + koffsetof(trustcache, prevptr), lastTC) != 0) return -1;
		}
		if (kwrite64(lastTC + koffsetof(trustcache, nextptr), tcToInsert) != 0) return -1;
	}
	else {
		uint64_t previousStartTC = _trustcache_list_get_start();
		if (kwrite64(tcToInsert + koffsetof(trustcache, nextptr), previousStartTC) != 0) return -1;
		if (previousStartTC && koffsetof(trustcache, prevptr)) {
			if (kwrite64(previousStartTC + koffsetof(trustcache, prevptr), tcToInsert) != 0) return -1;
		}
		if (_trustcache_list_set_start(tcToInsert) != 0) {
			if (previousStartTC && koffsetof(trustcache, prevptr)) {
				(void)kwrite64(previousStartTC + koffsetof(trustcache, prevptr), 0);
			}
			return -1;
		}
	}

	return 0;
}

int trustcache_list_remove(uint64_t tcKaddr)
{
	if (!tcKaddr) return -1;

	uint64_t nextTc = kread64(tcKaddr + koffsetof(trustcache, nextptr));

	uint64_t curTc = _trustcache_list_get_start();
	if (curTc == 0) {
		return -1;
	}
	else if (curTc == tcKaddr) {
		if (_trustcache_list_set_start(nextTc) != 0) return -1;
		if (nextTc && koffsetof(trustcache, prevptr)) {
			if (kwrite64(nextTc + koffsetof(trustcache, prevptr), 0) != 0) return -1;
		}
	}
	else {
		uint64_t prevTc = 0;
		while (curTc != tcKaddr)
		{
			if (curTc == 0) {
				return -1;
			}
			prevTc = curTc;
			curTc = kread64(curTc);
		}
		if (kwrite64(prevTc + koffsetof(trustcache, nextptr), nextTc) != 0) return -1;
		if (nextTc && koffsetof(trustcache, prevptr)) {
			if (kwrite64(nextTc + koffsetof(trustcache, prevptr), prevTc) != 0) return -1;
		}
	}

	return 0;
}

int _trustcache_file_sort_entry_comparator_v1(const void * vp1, const void * vp2)
{
	trustcache_entry_v1* tc1 = (trustcache_entry_v1*)vp1;
	trustcache_entry_v1* tc2 = (trustcache_entry_v1*)vp2;
	return memcmp(tc1->hash, tc2->hash, sizeof(cdhash_t));
}

void _trustcache_file_sort(trustcache_file_v1 *file)
{
	qsort(file->entries, file->length, sizeof(trustcache_entry_v1), _trustcache_file_sort_entry_comparator_v1);
}

bool _is_jb_trustcache(uint64_t tcKaddr)
{
	uint64_t jbTcFile = tcKaddr + offsetof(jb_trustcache, file);
	uint64_t file = kread64(tcKaddr + koffsetof(trustcache, fileptr));
	if (file == jbTcFile) {
		// If there is exactly one 8-byte value between the kpage start and the trustcache file,
		// Check if that matches against the JB_MAGIC
		// This is a 100% accurate way of determining whether this entry is a jb_trustcache or not
		return (kread64(tcKaddr + offsetof(jb_trustcache, magic)) == JB_MAGIC);
	}
	return false;
}

void _jb_trustcache_enumerate(void (^enumerateBlock)(uint64_t jbTcKaddr, bool *stop))
{
	_trustcache_list_enumerate(^(uint64_t tcKaddr, bool *stop) {
		if (_is_jb_trustcache(tcKaddr)) {
			enumerateBlock(tcKaddr, stop);
		}
	});
}

int jb_trustcache_clear(void)
{
	int lockResult = pthread_mutex_lock(&gJbTrustCacheOperationLock);
	if (lockResult != 0) return lockResult;

	__block int result = 0;
	os_unfair_lock_lock(&gJbTrustCacheLock);
	_jb_trustcache_enumerate(^(uint64_t jbTcKaddr, bool *stop) {
		if (kwrite64(jbTcKaddr + offsetof(jb_trustcache, file.length), 0) != 0) {
			result = EIO;
			*stop = true;
		}
	});
	os_unfair_lock_unlock(&gJbTrustCacheLock);
	if (result == 0) {
		int persistenceResult = jb_trustcache_persistent_clear();
		if (persistenceResult != 0) {
			os_log_error(OS_LOG_DEFAULT, "[TRUSTCACHE-PERSIST-18C1] failed to clear registry: %{public}d", persistenceResult);
			result = persistenceResult;
		}
	}
	pthread_mutex_unlock(&gJbTrustCacheOperationLock);
	return result;
}

static int _jb_trustcache_grow(uint64_t *jbTcKernOut)
{
	if (!jbTcKernOut) return EINVAL;
	*jbTcKernOut = 0;
	jb_trustcache *jbTc = calloc(1, sizeof(*jbTc));
	if (!jbTc) return ENOMEM;
	_trustcache_file_init(&jbTc->file);
	jbTc->magic = JB_MAGIC;

	uint64_t jbTcKern = 0;
	if (kalloc(&jbTcKern, 0x4000) != 0) {
		free(jbTc);
		return ENOMEM;
	}

	*(uint64_t *)(jbTc->trustcache + koffsetof(trustcache, fileptr)) = (jbTcKern + offsetof(jb_trustcache, file));
	if (koffsetof(trustcache, size)) {
		*(uint64_t *)(jbTc->trustcache + koffsetof(trustcache, size)) = JB_TRUSTCACHE_SIZE;
	}
	if (koffsetof(trustcache, type)) {
		*(uint64_t *)(jbTc->trustcache + koffsetof(trustcache, type)) = 0x5;
	}
	if (kwritebuf(jbTcKern, jbTc, sizeof(*jbTc)) != 0) {
		free(jbTc);
		return EIO;
	}
	free(jbTc);
	if (trustcache_list_insert(jbTcKern) != 0) return EIO;
	*jbTcKernOut = jbTcKern;
	return 0;
}

static int jb_trustcache_add_entries_internal(struct trustcache_entry_v1 *entries, uint32_t entryCount,
	trustcache_entry_v1 **insertedEntriesOut, uint32_t *insertedEntryCountOut)
{
	if (insertedEntriesOut) *insertedEntriesOut = NULL;
	if (insertedEntryCountOut) *insertedEntryCountOut = 0;
	if (entryCount == 0) return 0;
	if (!entries) return EINVAL;

	trustcache_entry_v1 *pendingEntries = calloc(entryCount, sizeof(*pendingEntries));
	if (!pendingEntries) return ENOMEM;

	int result = 0;
	uint32_t pendingEntryCount = 0;
	os_unfair_lock_lock(&gJbTrustCacheLock);

	// Collection happens before this lock is acquired. Recheck the live cache
	// and remove duplicates from the request so repeated trust calls cannot
	// consume a new 16 KiB global allocation for an existing CDHash.
	for (uint32_t i = 0; i < entryCount; i++) {
		if (is_cdhash_trustcached_unlocked(entries[i].hash)) continue;
		bool duplicate = false;
		for (uint32_t j = 0; j < pendingEntryCount; j++) {
			if (memcmp(pendingEntries[j].hash, entries[i].hash, sizeof(cdhash_t)) == 0) {
				duplicate = true;
				break;
			}
		}
		if (!duplicate) pendingEntries[pendingEntryCount++] = entries[i];
	}

	uint32_t insertedEntryCount = 0;
	uint32_t remainingEntryCount = pendingEntryCount;
	while (remainingEntryCount > 0) {
		__block uint64_t freeJbTcKaddr = 0;
		__block uint32_t freeJbTcCurrentLength = 0;
		__block bool invalidLength = false;
		_jb_trustcache_enumerate(^(uint64_t jbTcKaddr, bool *stop) {
			uint32_t length = kread32(jbTcKaddr + offsetof(jb_trustcache, file.length));
			if (length > JB_TRUSTCACHE_ENTRY_COUNT) {
				invalidLength = true;
				*stop = true;
				return;
			}
			if (length < JB_TRUSTCACHE_ENTRY_COUNT) {
				freeJbTcKaddr = jbTcKaddr;
				freeJbTcCurrentLength = length;
				*stop = true;
			}
		});
		if (invalidLength) {
			result = EIO;
			break;
		}
		if (freeJbTcKaddr == 0) {
			result = _jb_trustcache_grow(&freeJbTcKaddr);
			freeJbTcCurrentLength = 0;
			if (result != 0) break;
		}

		uint32_t entryCountToInsert = JB_TRUSTCACHE_ENTRY_COUNT - freeJbTcCurrentLength;
		if (remainingEntryCount < entryCountToInsert) {
			entryCountToInsert = remainingEntryCount;
		}

		jb_trustcache *jbTc = malloc(JB_TRUSTCACHE_SIZE);
		if (!jbTc) {
			result = ENOMEM;
			break;
		}
		if (kreadbuf(freeJbTcKaddr, jbTc, JB_TRUSTCACHE_SIZE) != 0 ||
			jbTc->file.length != freeJbTcCurrentLength) {
			free(jbTc);
			result = EIO;
			break;
		}
		for (uint32_t i = 0; i < entryCountToInsert; i++) {
			jbTc->file.entries[freeJbTcCurrentLength+i] = pendingEntries[insertedEntryCount+i];
		}
		jbTc->file.length += entryCountToInsert;
		_trustcache_file_sort(&jbTc->file);
		if (kwritebuf(freeJbTcKaddr, jbTc, JB_TRUSTCACHE_SIZE) != 0) {
			free(jbTc);
			result = EIO;
			break;
		}
		free(jbTc);
		insertedEntryCount += entryCountToInsert;
		remainingEntryCount -= entryCountToInsert;
	}

	os_unfair_lock_unlock(&gJbTrustCacheLock);
	if (insertedEntriesOut) {
		*insertedEntriesOut = pendingEntries;
	}
	else {
		free(pendingEntries);
	}
	if (insertedEntryCountOut) *insertedEntryCountOut = insertedEntryCount;
	return result;
}

int jb_trustcache_add_entries(struct trustcache_entry_v1 *entries, uint32_t entryCount)
{
	int lockResult = pthread_mutex_lock(&gJbTrustCacheOperationLock);
	if (lockResult != 0) return lockResult;

	trustcache_entry_v1 *insertedEntries = NULL;
	uint32_t insertedEntryCount = 0;
	int result = jb_trustcache_add_entries_internal(entries, entryCount, &insertedEntries, &insertedEntryCount);
	int persistenceResult = 0;
	const trustcache_entry_v1 *entriesToPersist = result == 0 ? entries : insertedEntries;
	uint32_t entryCountToPersist = result == 0 ? entryCount : insertedEntryCount;
	if (entryCountToPersist > 0) {
		// Persist every explicitly requested entry after a successful kernel
		// update. This makes a retry repair an earlier disk-write failure even
		// when the live trust cache now reports every CDHash as a duplicate.
		persistenceResult = jb_trustcache_persistent_merge(entriesToPersist, entryCountToPersist);
		if (persistenceResult != 0) {
			os_log_error(OS_LOG_DEFAULT,
				"[TRUSTCACHE-PERSIST-18C1] failed to persist %{public}u requested entries: %{public}d",
				entryCountToPersist, persistenceResult);
		}
	}
	free(insertedEntries);
	pthread_mutex_unlock(&gJbTrustCacheOperationLock);

	return result != 0 ? result : persistenceResult;
}

int jb_trustcache_add_cdhashes(cdhash_t *hashes, uint32_t hashCount)
{
	if (hashCount == 0) return 0;
	if (!hashes) return EINVAL;
	struct trustcache_entry_v1 *entries = calloc(hashCount, sizeof(*entries));
	if (!entries) return ENOMEM;
	for (uint32_t i = 0; i < hashCount; i++) {
		memcpy(entries[i].hash, hashes[i], sizeof(cdhash_t));
		entries[i].hash_type = 1;
		entries[i].flags = 0;
	}
	int result = jb_trustcache_add_entries(entries, hashCount);
	free(entries);
	return result;
}

int jb_trustcache_add_entry(struct trustcache_entry_v1 entry)
{
	return jb_trustcache_add_entries(&entry, 1);
}

static int jb_trustcache_copy_live_entries(trustcache_entry_v1 **entriesOut, uint32_t *entryCountOut)
{
	if (!entriesOut || !entryCountOut) return EINVAL;
	*entriesOut = NULL;
	*entryCountOut = 0;

	__block int result = 0;
	__block uint32_t totalEntryCount = 0;
	os_unfair_lock_lock(&gJbTrustCacheLock);
	_jb_trustcache_enumerate(^(uint64_t jbTcKaddr, bool *stop) {
		uint32_t length = kread32(jbTcKaddr + offsetof(jb_trustcache, file.length));
		if (length > JB_TRUSTCACHE_ENTRY_COUNT ||
			length > JB_TRUSTCACHE_PERSISTENT_MAX_ENTRIES - totalEntryCount) {
			result = length > JB_TRUSTCACHE_ENTRY_COUNT ? EIO : ENOSPC;
			*stop = true;
			return;
		}
		totalEntryCount += length;
	});

	trustcache_entry_v1 *entries = NULL;
	if (result == 0 && totalEntryCount > 0) {
		entries = calloc(totalEntryCount, sizeof(*entries));
		if (!entries) result = ENOMEM;
	}
	if (result == 0 && totalEntryCount > 0) {
		__block uint32_t copiedEntryCount = 0;
		_jb_trustcache_enumerate(^(uint64_t jbTcKaddr, bool *stop) {
			uint32_t length = kread32(jbTcKaddr + offsetof(jb_trustcache, file.length));
			if (length > JB_TRUSTCACHE_ENTRY_COUNT || length > totalEntryCount - copiedEntryCount) {
				result = EIO;
				*stop = true;
				return;
			}
			if (length > 0 && kreadbuf(jbTcKaddr + offsetof(jb_trustcache, file.entries),
				&entries[copiedEntryCount], (size_t)length * sizeof(*entries)) != 0) {
				result = EIO;
				*stop = true;
				return;
			}
			copiedEntryCount += length;
		});
		if (result == 0 && copiedEntryCount != totalEntryCount) result = EIO;
	}
	os_unfair_lock_unlock(&gJbTrustCacheLock);

	if (result != 0) {
		free(entries);
		return result;
	}
	*entriesOut = entries;
	*entryCountOut = totalEntryCount;
	return 0;
}

int jb_trustcache_restore_persistent(void)
{
	int lockResult = pthread_mutex_lock(&gJbTrustCacheOperationLock);
	if (lockResult != 0) return lockResult;

	trustcache_entry_v1 *liveEntries = NULL;
	uint32_t liveEntryCount = 0;
	int result = jb_trustcache_copy_live_entries(&liveEntries, &liveEntryCount);

	trustcache_entry_v1 *persistentEntries = NULL;
	uint32_t persistentEntryCount = 0;
	if (result == 0) {
		result = jb_trustcache_persistent_load(&persistentEntries, &persistentEntryCount);
	}
	if (result == 0 && persistentEntryCount > 0) {
		result = jb_trustcache_add_entries_internal(persistentEntries, persistentEntryCount, NULL, NULL);
	}
	if (result == 0 && liveEntryCount > 0) {
		// Import entries left by an older Dopamine during an in-place upgrade.
		// Fixed basebin/dyld UUID caches are not jb_trustcache pages and are
		// intentionally excluded by jb_trustcache_copy_live_entries().
		result = jb_trustcache_persistent_merge(liveEntries, liveEntryCount);
	}
	if (result != 0) {
		os_log_error(OS_LOG_DEFAULT,
			"[TRUSTCACHE-PERSIST-18C1] restore failed registry=%{public}u live=%{public}u result=%{public}d",
			persistentEntryCount, liveEntryCount, result);
	}
	else {
		os_log(OS_LOG_DEFAULT,
			"[TRUSTCACHE-PERSIST-18C1] restored registry=%{public}u imported-live=%{public}u",
			persistentEntryCount, liveEntryCount);
	}
	free(persistentEntries);
	free(liveEntries);
	pthread_mutex_unlock(&gJbTrustCacheOperationLock);
	return result;
}


/*int jb_trustcache_add_file(const char *filePath)
{
	
}

int jb_trustcache_add_directory(const char *directoryPath)
{

}*/

xpc_object_t jb_trustcache_info(void)
{
	xpc_object_t arr = xpc_array_create_empty();
	os_unfair_lock_lock(&gJbTrustCacheLock);
	_jb_trustcache_enumerate(^(uint64_t jbTcKaddr, bool *stop) {
		uuid_t uuid;
		kreadbuf(jbTcKaddr + offsetof(jb_trustcache, file.uuid), (void *)uuid, sizeof(uuid));
		uint32_t length = kread32(jbTcKaddr + offsetof(jb_trustcache, file.length));
		if (length > JB_TRUSTCACHE_ENTRY_COUNT) {
			*stop = true;
			return;
		}

		xpc_object_t tcDict = xpc_dictionary_create_empty();
		xpc_dictionary_set_data(tcDict, "uuid", &uuid, sizeof(uuid));

		xpc_object_t hashesArr = xpc_array_create_empty();
		for (int i = 0; i < length; i++) {
			trustcache_entry_v1 entry;
			kreadbuf(jbTcKaddr + offsetof(jb_trustcache, file.entries[i]), &entry, sizeof(entry));
			xpc_array_set_data(hashesArr, XPC_ARRAY_APPEND, &entry.hash, sizeof(entry.hash));
		}
		xpc_dictionary_set_value(tcDict, "cdhashes", hashesArr);
		xpc_release(hashesArr);

		xpc_array_append_value(arr, tcDict);
		xpc_release(tcDict);
	});
	os_unfair_lock_unlock(&gJbTrustCacheLock);
	return arr;
}

void jb_trustcache_debug_print(FILE *f)
{
	__block int i = 0;
	os_unfair_lock_lock(&gJbTrustCacheLock);
	_jb_trustcache_enumerate(^(uint64_t jbTcKaddr, bool *stop) {
		uuid_t uuid;
		kreadbuf(jbTcKaddr + offsetof(jb_trustcache, file.uuid), (void *)uuid, sizeof(uuid));
		uint32_t length = kread32(jbTcKaddr + offsetof(jb_trustcache, file.length));
		if (length > JB_TRUSTCACHE_ENTRY_COUNT) {
			fprintf(f, "Invalid Jailbreak TrustCache length %u at 0x%llx\n", length, jbTcKaddr);
			*stop = true;
			return;
		}

		uint32_t *uuidData = (uint32_t *)uuid;
		fprintf(f, "Jailbreak TrustCache %d <%08x%08x%08x%08x> (length: %u) (kaddr: 0x%llx):\n", i++, htonl(uuidData[0]), htonl(uuidData[1]), htonl(uuidData[2]), htonl(uuidData[3]), length, jbTcKaddr);
		
		for (uint32_t j = 0; j < length; j++) {
			trustcache_entry_v1 entry;
			kreadbuf(jbTcKaddr + offsetof(jb_trustcache, file.entries[j]), &entry, sizeof(entry));
			fprintf(f, "| ");
			for (uint32_t k = 0; k < sizeof(cdhash_t); k++) {
				fprintf(f, "%02x", entry.hash[k]);
			}
			fprintf(f, "\n");
		}
	});


	/////////////////////////////////////////////////////////////////
	_trustcache_list_enumerate(^(uint64_t tcKaddr, bool *stop) {
		if (_is_jb_trustcache(tcKaddr)) return;

		uint64_t tcFileKaddr = kread64(tcKaddr + koffsetof(trustcache, fileptr));
		uint32_t length = kread32(tcFileKaddr + offsetof(trustcache_file_v1, length));
		if (length == 0) return;
	
		uuid_t uuid;
		kreadbuf(tcFileKaddr + offsetof(trustcache_file_v1, uuid), (void *)uuid, sizeof(uuid));

		uint32_t *uuidData = (uint32_t *)uuid;
		fprintf(f, "TrustCache File <%08x%08x%08x%08x> (length: %u) (kaddr: 0x%llx):\n", htonl(uuidData[0]), htonl(uuidData[1]), htonl(uuidData[2]), htonl(uuidData[3]), length, tcFileKaddr);
		
		for (uint32_t j = 0; j < length; j++) {
			trustcache_entry_v1 entry;
			kreadbuf(tcFileKaddr + offsetof(trustcache_file_v1, entries[j]), &entry, sizeof(entry));
			fprintf(f, "| ");
			for (uint32_t k = 0; k < sizeof(cdhash_t); k++) {
				fprintf(f, "%02x", entry.hash[k]);
			}
			fprintf(f, "\n");
		}
	});
	os_unfair_lock_unlock(&gJbTrustCacheLock);
}

static int trustcache_file_upload_unlocked(trustcache_file_v1 *tc)
{
	uint64_t tcSize = ksizeof(trustcache) + sizeof(trustcache_file_v1) + (tc->length * sizeof(trustcache_entry_v1));
	if (tcSize > 0x4000) return -1;

	// Check if there is already a TrustCache with the same UUID
	__block uint64_t existingTcKaddr = 0;
	_trustcache_list_enumerate(^(uint64_t tcKaddr, bool *stop) {
		uint64_t tcFileKaddr = kread64(tcKaddr + koffsetof(trustcache, fileptr));
		uuid_t tcFileUUID;
		kreadbuf(tcFileKaddr + offsetof(trustcache_file_v1, uuid), tcFileUUID, sizeof(tcFileUUID));
		if (memcmp(tcFileUUID, tc->uuid, sizeof(tcFileUUID)) == 0) {
			existingTcKaddr = tcKaddr;
			*stop = true;
		}
	});

	// If so, we want to either replace it or remove it
	if (existingTcKaddr != 0) {
		if (_is_jb_trustcache(existingTcKaddr)) {
			// There is something terribly wrong, abort
			return -1;
		}

		uint64_t prevTcFile = kread64(existingTcKaddr + koffsetof(trustcache, fileptr));
		uint32_t prevTcLength = kread32(prevTcFile + offsetof(trustcache_file_v1, length));
		uint64_t prevTcSize = ksizeof(trustcache) + sizeof(trustcache_file_v1) + (prevTcLength * sizeof(trustcache_entry_v1));
		if (prevTcSize == tcSize) {
			// If size is the same this is simple, just replace the file data
			return kwritebuf(prevTcFile, tc, tcSize - ksizeof(trustcache));
		}
		else {
			// If not, it gets more complicated and hacky...
			// We can't take a lock (at least not yet??) to ensure nothing accesses the original TrustCache after we freed it
			// So we do the next best thing, we remove it from the linked list and wait a bit before freeing it, hoping that any
			// outstanding reads on the memory would be done by then
			if (trustcache_list_remove(existingTcKaddr) != 0) {
				return -1; // really unlikely error, if this triggers the world is probably upside down
			}
			usleep(10000); // hope for current accesses to finish if there are any (new accesses won't come as we removed the list entry)
			// Do not free a detached page here.  Trust caches created by an older
			// activation may be IOSurface-backed, while current pages use
			// kalloc_data_external(); without allocator provenance, either free
			// primitive could corrupt the kernel.  Detached trust-cache pages are
			// intentionally retained until the next boot.
			// now just fall through and make this function add the new TrustCache
		}
	}

	uint64_t tcKaddr = 0;
	if (kalloc(&tcKaddr, tcSize) != 0) return -1;

	// kalloc is not guaranteed to be zeroed, make sure trustcache head is zeroed
	char nullBuf[ksizeof(trustcache)];
	memset(nullBuf, 0, sizeof(nullBuf));
	if (kwritebuf(tcKaddr, nullBuf, sizeof(nullBuf)) != 0) return -1;

	uint64_t tcFileKaddr = tcKaddr + ksizeof(trustcache);
	if (kwritebuf(tcFileKaddr, tc, tcSize - ksizeof(trustcache)) != 0) return -1;

	if (kwrite64(tcKaddr + koffsetof(trustcache, fileptr), tcFileKaddr) != 0) return -1;
	if (koffsetof(trustcache, size)) {
		if (kwrite64(tcKaddr + koffsetof(trustcache, size), tcSize) != 0) return -1;
	}
	if (koffsetof(trustcache, type)) {
		if (kwrite64(tcKaddr + koffsetof(trustcache, type), 0x5) != 0) return -1;
	}

	return trustcache_list_insert(tcKaddr);
}

int trustcache_file_upload(trustcache_file_v1 *tc)
{
	if (!tc) return -1;
	os_unfair_lock_lock(&gJbTrustCacheLock);
	int result = trustcache_file_upload_unlocked(tc);
	os_unfair_lock_unlock(&gJbTrustCacheLock);
	return result;
}

int trustcache_file_upload_with_uuid(trustcache_file_v1 *tc, uuid_t uuid)
{
	memcpy(tc->uuid, uuid, sizeof(uuid_t));
	return trustcache_file_upload(tc);
}

int trustcache_file_build_from_cdhashes(cdhash_t *CDHashes, uint32_t CDHashCount, trustcache_file_v1 **tcOut)
{
	if (!CDHashes || CDHashCount == 0 || !tcOut) return -1;

	size_t tcSize = sizeof(trustcache_file_v1) + (sizeof(trustcache_entry_v1) * CDHashCount);
	trustcache_file_v1 *file = malloc(tcSize);
	_trustcache_file_init(file);

	file->length = CDHashCount;
	for (uint32_t i = 0; i < CDHashCount; i++) {
		memcpy(file->entries[i].hash, CDHashes[i], sizeof(cdhash_t));
		file->entries[i].hash_type = 2;
		file->entries[i].flags = 0;
	}
	_trustcache_file_sort(file);

	*tcOut = file;
	return 0;
}

int trustcache_file_build_from_path(const char *filePath, trustcache_file_v1 **tcOut)
{
	int fd = open(filePath, O_RDONLY);
	struct stat s = { 0 };
	fstat(fd, &s);
	
	size_t tcSize = s.st_size;
	if (tcSize < (sizeof(trustcache_file_v1))) {
		// To small to be a TrustCache, file is probably malformed
		return -1;
	}

	trustcache_file_v1 *file = malloc(tcSize);
	read(fd, file, tcSize);
	close(fd);

	size_t actualTcSize = sizeof(trustcache_file_v1) + (sizeof(trustcache_entry_v1) * file->length);
	if (actualTcSize != tcSize) {
		// Size mismatch, file is malformed
		free(file);
		return -1;
	}

	*tcOut = file;
	return 0;
}

bool trustcache_contains_cdhash(uint64_t tcKaddr, cdhash_t CDHash)
{
	uint64_t tcFileKaddr = kread64(tcKaddr + koffsetof(trustcache, fileptr));
	uint32_t length = kread32(tcFileKaddr + offsetof(trustcache_file_v1, length));
	if (length == 0) return false;

	int32_t left = 0;
	int32_t right = length - 1;

	while (left <= right) {
		int32_t mid = (left + right) / 2;
		cdhash_t itCDHash;
		kreadbuf(tcFileKaddr + offsetof(trustcache_file_v1, entries[mid].hash), itCDHash, CS_CDHASH_LEN);
		int32_t cmp = memcmp(CDHash, itCDHash, CS_CDHASH_LEN);
		if (cmp == 0) {
			return true;
		}
		if (cmp < 0) {
			right = mid - 1;
		} else {
			left = mid + 1;
		}
	}
	return false;
}

static bool is_cdhash_trustcached_unlocked(cdhash_t CDHash)
{
	__block bool inTrustCache = false;
	_trustcache_list_enumerate(^(uint64_t tcKaddr, bool *stop) {
		bool inThisTrustCache = trustcache_contains_cdhash(tcKaddr, CDHash);
		if (inThisTrustCache) {
			inTrustCache = true;
			*stop = true;
		}
	});
	return inTrustCache;
}

bool is_cdhash_trustcached(cdhash_t CDHash)
{
	os_unfair_lock_lock(&gJbTrustCacheLock);
	bool inTrustCache = is_cdhash_trustcached_unlocked(CDHash);
	os_unfair_lock_unlock(&gJbTrustCacheLock);
	return inTrustCache;
}
