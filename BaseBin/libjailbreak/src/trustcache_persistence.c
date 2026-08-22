#include "trustcache_persistence.h"

#include <errno.h>
#include <fcntl.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/param.h>
#include <sys/stat.h>
#include <unistd.h>

#include "jbroot.h"

#define TRUSTCACHE_REGISTRY_DIRECTORY "/var/mobile/Library/RootHide"
#define TRUSTCACHE_REGISTRY_PATH TRUSTCACHE_REGISTRY_DIRECTORY "/dynamic-trustcache-v1.bin"
#define TRUSTCACHE_REGISTRY_LOCK_PATH TRUSTCACHE_REGISTRY_DIRECTORY "/.dynamic-trustcache.lock"
#define TRUSTCACHE_REGISTRY_VERSION 1U

static const uint8_t kTrustCacheRegistryMagic[8] = {'R', 'H', 'T', 'C', 'R', 'E', 'G', '1'};

typedef struct trustcache_registry_header {
	uint8_t magic[sizeof(kTrustCacheRegistryMagic)];
	uint32_t version;
	uint32_t header_size;
	uint32_t entry_size;
	uint32_t entry_count;
	uint32_t payload_crc32;
	uint32_t header_crc32;
} __attribute__((__packed__)) trustcache_registry_header;

_Static_assert(sizeof(trustcache_registry_header) == 32, "unexpected trustcache registry header size");

static uint32_t crc32_update(uint32_t crc, const void *data, size_t size)
{
	const uint8_t *bytes = data;
	crc = ~crc;
	for (size_t i = 0; i < size; i++) {
		crc ^= bytes[i];
		for (uint32_t bit = 0; bit < 8; bit++) {
			crc = (crc >> 1) ^ (0xEDB88320U & (uint32_t)-(int32_t)(crc & 1U));
		}
	}
	return ~crc;
}

static int copy_registry_path(const char *relativePath, char pathOut[PATH_MAX])
{
	const char *convertedPath = JBROOT_PATH(relativePath);
	if (!convertedPath) return ENOENT;
	if (strlcpy(pathOut, convertedPath, PATH_MAX) >= PATH_MAX) return ENAMETOOLONG;
	return 0;
}

static int ensure_registry_directory(struct stat *directoryStatOut)
{
	char directoryPath[PATH_MAX];
	int result = copy_registry_path(TRUSTCACHE_REGISTRY_DIRECTORY, directoryPath);
	if (result != 0) return result;

	struct stat directoryStat = {0};
	if (lstat(directoryPath, &directoryStat) == 0) {
		if (!S_ISDIR(directoryStat.st_mode)) return ENOTDIR;
		if (directoryStatOut) *directoryStatOut = directoryStat;
		return 0;
	}
	if (errno != ENOENT) return errno;
	if (mkdir(directoryPath, 0755) != 0 && errno != EEXIST) return errno;
	char parentPath[PATH_MAX];
	result = copy_registry_path("/var/mobile/Library", parentPath);
	if (result != 0) return result;
	struct stat parentStat = {0};
	if (lstat(parentPath, &parentStat) != 0) return errno;
	if (chown(directoryPath, parentStat.st_uid, parentStat.st_gid) != 0) return errno;
	if (lstat(directoryPath, &directoryStat) != 0) return errno;
	if (!S_ISDIR(directoryStat.st_mode)) return ENOTDIR;
	if (directoryStatOut) *directoryStatOut = directoryStat;
	return 0;
}

static int lock_registry(int *lockFdOut)
{
	if (!lockFdOut) return EINVAL;
	*lockFdOut = -1;

	struct stat directoryStat = {0};
	int result = ensure_registry_directory(&directoryStat);
	if (result != 0) return result;

	char lockPath[PATH_MAX];
	result = copy_registry_path(TRUSTCACHE_REGISTRY_LOCK_PATH, lockPath);
	if (result != 0) return result;

	int lockFd = open(lockPath, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0600);
	if (lockFd < 0) return errno;
	struct stat lockStat = {0};
	if (fstat(lockFd, &lockStat) != 0) {
		result = errno;
		close(lockFd);
		return result;
	}
	if (!S_ISREG(lockStat.st_mode) || lockStat.st_nlink != 1) {
		result = EINVAL;
		close(lockFd);
		return result;
	}
	if ((lockStat.st_uid != directoryStat.st_uid || lockStat.st_gid != directoryStat.st_gid) &&
		fchown(lockFd, directoryStat.st_uid, directoryStat.st_gid) != 0) {
		result = errno;
		close(lockFd);
		return result;
	}
	if (fchmod(lockFd, 0600) != 0) {
		result = errno;
		close(lockFd);
		return result;
	}
	while (flock(lockFd, LOCK_EX) != 0) {
		if (errno == EINTR) continue;
		result = errno;
		close(lockFd);
		return result;
	}

	*lockFdOut = lockFd;
	return 0;
}

static void unlock_registry(int lockFd)
{
	if (lockFd < 0) return;
	(void)flock(lockFd, LOCK_UN);
	close(lockFd);
}

static int read_all(int fd, void *buffer, size_t size)
{
	uint8_t *cursor = buffer;
	while (size > 0) {
		ssize_t amount = read(fd, cursor, size);
		if (amount > 0) {
			cursor += amount;
			size -= (size_t)amount;
			continue;
		}
		if (amount < 0 && errno == EINTR) continue;
		return amount == 0 ? EIO : errno;
	}
	return 0;
}

static int write_all(int fd, const void *buffer, size_t size)
{
	const uint8_t *cursor = buffer;
	while (size > 0) {
		ssize_t amount = write(fd, cursor, size);
		if (amount > 0) {
			cursor += amount;
			size -= (size_t)amount;
			continue;
		}
		if (amount < 0 && errno == EINTR) continue;
		return amount == 0 ? EIO : errno;
	}
	return 0;
}

static int trustcache_entry_comparator(const void *leftValue, const void *rightValue)
{
	const trustcache_entry_v1 *left = leftValue;
	const trustcache_entry_v1 *right = rightValue;
	int hashResult = memcmp(left->hash, right->hash, sizeof(left->hash));
	if (hashResult != 0) return hashResult;
	if (left->hash_type != right->hash_type) return left->hash_type < right->hash_type ? -1 : 1;
	if (left->flags != right->flags) return left->flags < right->flags ? -1 : 1;
	return 0;
}

static int read_registry_unlocked(trustcache_entry_v1 **entriesOut, uint32_t *entryCountOut)
{
	if (!entriesOut || !entryCountOut) return EINVAL;
	*entriesOut = NULL;
	*entryCountOut = 0;

	char registryPath[PATH_MAX];
	int result = copy_registry_path(TRUSTCACHE_REGISTRY_PATH, registryPath);
	if (result != 0) return result;

	int fd = open(registryPath, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
	if (fd < 0) return errno == ENOENT ? 0 : errno;

	struct stat fileStat = {0};
	if (fstat(fd, &fileStat) != 0) {
		result = errno;
		goto out;
	}
	struct stat directoryStat = {0};
	result = ensure_registry_directory(&directoryStat);
	if (result != 0) goto out;
	if (!S_ISREG(fileStat.st_mode) || fileStat.st_nlink != 1 ||
		fileStat.st_uid != directoryStat.st_uid || fileStat.st_gid != directoryStat.st_gid ||
		(fileStat.st_mode & 0777) != 0600 ||
		fileStat.st_size < (off_t)sizeof(trustcache_registry_header)) {
		result = EINVAL;
		goto out;
	}

	trustcache_registry_header header = {0};
	result = read_all(fd, &header, sizeof(header));
	if (result != 0) goto out;

	if (memcmp(header.magic, kTrustCacheRegistryMagic, sizeof(header.magic)) != 0 ||
		header.version != TRUSTCACHE_REGISTRY_VERSION ||
		header.header_size != sizeof(header) ||
		header.entry_size != sizeof(trustcache_entry_v1) ||
		header.entry_count > JB_TRUSTCACHE_PERSISTENT_MAX_ENTRIES) {
		result = EINVAL;
		goto out;
	}
	uint32_t expectedHeaderCrc = crc32_update(0, &header, offsetof(trustcache_registry_header, header_crc32));
	if (expectedHeaderCrc != header.header_crc32) {
		result = EINVAL;
		goto out;
	}

	uint64_t payloadSize = (uint64_t)header.entry_count * sizeof(trustcache_entry_v1);
	uint64_t expectedSize = sizeof(header) + payloadSize;
	if ((uint64_t)fileStat.st_size != expectedSize) {
		result = EINVAL;
		goto out;
	}

	trustcache_entry_v1 *entries = NULL;
	if (header.entry_count > 0) {
		entries = calloc(header.entry_count, sizeof(*entries));
		if (!entries) {
			result = ENOMEM;
			goto out;
		}
		result = read_all(fd, entries, (size_t)payloadSize);
		if (result != 0) {
			free(entries);
			goto out;
		}
	}

	if (crc32_update(0, entries, (size_t)payloadSize) != header.payload_crc32) {
		free(entries);
		result = EINVAL;
		goto out;
	}
	for (uint32_t i = 1; i < header.entry_count; i++) {
		if (memcmp(entries[i - 1].hash, entries[i].hash, sizeof(entries[i].hash)) >= 0) {
			free(entries);
			result = EINVAL;
			goto out;
		}
	}

	*entriesOut = entries;
	*entryCountOut = header.entry_count;
	result = 0;

out:
	close(fd);
	return result;
}

static int sync_fd(int fd)
{
	if (fcntl(fd, F_FULLFSYNC) == 0) return 0;
	if (fsync(fd) == 0) return 0;
	return errno;
}

static int sync_directory_fd(int fd)
{
	int result = sync_fd(fd);
	return result == EINVAL || result == ENOTSUP ? 0 : result;
}

static int write_registry_unlocked(const trustcache_entry_v1 *entries, uint32_t entryCount)
{
	if (entryCount > JB_TRUSTCACHE_PERSISTENT_MAX_ENTRIES) return ENOSPC;
	if (entryCount > 0 && !entries) return EINVAL;

	char registryPath[PATH_MAX];
	int result = copy_registry_path(TRUSTCACHE_REGISTRY_PATH, registryPath);
	if (result != 0) return result;
	struct stat directoryStat = {0};
	result = ensure_registry_directory(&directoryStat);
	if (result != 0) return result;

	char temporaryPath[PATH_MAX];
	if (strlcpy(temporaryPath, registryPath, sizeof(temporaryPath)) >= sizeof(temporaryPath) ||
		strlcat(temporaryPath, ".tmp.XXXXXX", sizeof(temporaryPath)) >= sizeof(temporaryPath)) {
		return ENAMETOOLONG;
	}

	int fd = mkstemp(temporaryPath);
	if (fd < 0) return errno;
	(void)fcntl(fd, F_SETFD, FD_CLOEXEC);
	struct stat temporaryStat = {0};
	if (fstat(fd, &temporaryStat) != 0) {
		result = errno;
		goto out;
	}
	if ((temporaryStat.st_uid != directoryStat.st_uid || temporaryStat.st_gid != directoryStat.st_gid) &&
		fchown(fd, directoryStat.st_uid, directoryStat.st_gid) != 0) {
		result = errno;
		goto out;
	}
	if (fchmod(fd, 0600) != 0) {
		result = errno;
		goto out;
	}

	size_t payloadSize = (size_t)entryCount * sizeof(trustcache_entry_v1);
	trustcache_registry_header header = {0};
	memcpy(header.magic, kTrustCacheRegistryMagic, sizeof(header.magic));
	header.version = TRUSTCACHE_REGISTRY_VERSION;
	header.header_size = sizeof(header);
	header.entry_size = sizeof(trustcache_entry_v1);
	header.entry_count = entryCount;
	header.payload_crc32 = crc32_update(0, entries, payloadSize);
	header.header_crc32 = crc32_update(0, &header, offsetof(trustcache_registry_header, header_crc32));

	result = write_all(fd, &header, sizeof(header));
	if (result == 0 && payloadSize > 0) result = write_all(fd, entries, payloadSize);
	if (result == 0) result = sync_fd(fd);
	if (close(fd) != 0 && result == 0) result = errno;
	fd = -1;
	if (result != 0) goto out;

	if (rename(temporaryPath, registryPath) != 0) {
		result = errno;
		goto out;
	}
	temporaryPath[0] = '\0';

	char directoryPath[PATH_MAX];
	result = copy_registry_path(TRUSTCACHE_REGISTRY_DIRECTORY, directoryPath);
	if (result != 0) return result;
	int directoryFd = open(directoryPath, O_RDONLY | O_CLOEXEC | O_DIRECTORY);
	if (directoryFd < 0) return errno;
	result = sync_directory_fd(directoryFd);
	close(directoryFd);
	return result;

out:
	if (fd >= 0) close(fd);
	if (temporaryPath[0]) unlink(temporaryPath);
	return result;
}

int jb_trustcache_persistent_load(trustcache_entry_v1 **entriesOut, uint32_t *entryCountOut)
{
	int lockFd = -1;
	int result = lock_registry(&lockFd);
	if (result != 0) return result;
	result = read_registry_unlocked(entriesOut, entryCountOut);
	unlock_registry(lockFd);
	return result;
}

int jb_trustcache_persistent_merge(const trustcache_entry_v1 *entries, uint32_t entryCount)
{
	if (entryCount == 0) return 0;
	if (!entries || entryCount > JB_TRUSTCACHE_PERSISTENT_MAX_ENTRIES) return EINVAL;

	int lockFd = -1;
	int result = lock_registry(&lockFd);
	if (result != 0) return result;

	trustcache_entry_v1 *existingEntries = NULL;
	uint32_t existingEntryCount = 0;
	result = read_registry_unlocked(&existingEntries, &existingEntryCount);
	if (result != 0) goto out;

	trustcache_entry_v1 *requestedEntries = malloc((size_t)entryCount * sizeof(*requestedEntries));
	if (!requestedEntries) {
		result = ENOMEM;
		goto out;
	}
	memcpy(requestedEntries, entries, (size_t)entryCount * sizeof(*requestedEntries));
	qsort(requestedEntries, entryCount, sizeof(*requestedEntries), trustcache_entry_comparator);

	uint32_t requestedEntryCount = 0;
	for (uint32_t i = 0; i < entryCount; i++) {
		if (requestedEntryCount > 0 &&
			memcmp(requestedEntries[requestedEntryCount - 1].hash, requestedEntries[i].hash,
				sizeof(requestedEntries[i].hash)) == 0) {
			if (memcmp(&requestedEntries[requestedEntryCount - 1], &requestedEntries[i],
					sizeof(requestedEntries[i])) != 0) {
				result = EINVAL;
				free(requestedEntries);
				goto out;
			}
			continue;
		}
		requestedEntries[requestedEntryCount++] = requestedEntries[i];
	}

	uint64_t combinedEntryCount = (uint64_t)existingEntryCount + requestedEntryCount;
	if (combinedEntryCount > (uint64_t)JB_TRUSTCACHE_PERSISTENT_MAX_ENTRIES * 2U) {
		result = ENOSPC;
		free(requestedEntries);
		goto out;
	}
	trustcache_entry_v1 *combinedEntries = calloc((size_t)combinedEntryCount, sizeof(*combinedEntries));
	if (!combinedEntries) {
		result = ENOMEM;
		free(requestedEntries);
		goto out;
	}

	uint32_t uniqueEntryCount = 0;
	uint32_t existingIndex = 0;
	uint32_t requestedIndex = 0;
	while (existingIndex < existingEntryCount || requestedIndex < requestedEntryCount) {
		if (uniqueEntryCount >= JB_TRUSTCACHE_PERSISTENT_MAX_ENTRIES) {
			result = ENOSPC;
			free(requestedEntries);
			free(combinedEntries);
			goto out;
		}
		if (existingIndex >= existingEntryCount) {
			combinedEntries[uniqueEntryCount++] = requestedEntries[requestedIndex++];
			continue;
		}
		if (requestedIndex >= requestedEntryCount) {
			combinedEntries[uniqueEntryCount++] = existingEntries[existingIndex++];
			continue;
		}
		int hashResult = memcmp(existingEntries[existingIndex].hash, requestedEntries[requestedIndex].hash,
			sizeof(existingEntries[existingIndex].hash));
		if (hashResult < 0) {
			combinedEntries[uniqueEntryCount++] = existingEntries[existingIndex++];
		}
		else {
			combinedEntries[uniqueEntryCount++] = requestedEntries[requestedIndex++];
			if (hashResult == 0) existingIndex++;
		}
	}
	free(requestedEntries);

	// A repeated trust request can contain only CDHashes that are already in
	// the registry. Avoid rewriting and fully syncing the complete file in
	// launchd when the durable state is unchanged.
	if (uniqueEntryCount == existingEntryCount &&
		(uniqueEntryCount == 0 || memcmp(combinedEntries, existingEntries,
			(size_t)uniqueEntryCount * sizeof(*combinedEntries)) == 0)) {
		result = 0;
	}
	else {
		result = write_registry_unlocked(combinedEntries, uniqueEntryCount);
	}
	free(combinedEntries);

out:
	free(existingEntries);
	unlock_registry(lockFd);
	return result;
}

int jb_trustcache_persistent_clear(void)
{
	int lockFd = -1;
	int result = lock_registry(&lockFd);
	if (result != 0) return result;
	result = write_registry_unlocked(NULL, 0);
	unlock_registry(lockFd);
	return result;
}
