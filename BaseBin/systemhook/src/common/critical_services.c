#include "critical_services.h"

#include <errno.h>
#include <fcntl.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/param.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include <libjailbreak/jbroot.h>

#define ROOTHIDE_CRITICAL_SERVICE_CACHE_NS (2ULL * 1000ULL * 1000ULL * 1000ULL)
#define ROOTHIDE_CRITICAL_SERVICE_FILE_MAX 4096
#define ROOTHIDE_CRITICAL_SERVICE_DIRECTORY "/var/mobile/Library/RootHide"
#define ROOTHIDE_CRITICAL_SERVICE_FILE ROOTHIDE_CRITICAL_SERVICE_DIRECTORY "/watchdog-noinject-v1.txt"
#define ROOTHIDE_CRITICAL_SERVICE_LOCK ROOTHIDE_CRITICAL_SERVICE_DIRECTORY "/.watchdog-noinject.lock"

typedef struct {
	const char *serviceName;
	const char *executablePath;
} roothide_critical_service;

static const char *gIOS18FixedNoInjectPaths[] = {
	"/System/Library/PrivateFrameworks/NanoTimeKit.framework/nanotimekitcompaniond",
	"/System/Library/Frameworks/Metal.framework/XPCServices/MTLCompilerService.xpc/MTLCompilerService",
	"/System/Library/Frameworks/AudioToolbox.framework/XPCServices/AudioConverterService.xpc/AudioConverterService",
	"/usr/libexec/neagent",
	"/usr/libexec/thermalmonitord",
};

// Only dedicated Apple executables that do not host third-party extensions
// are eligible. SpringBoard, extensionkitservice and watchdogd are excluded.
static const roothide_critical_service gWatchdogQuarantineServices[] = {
	{ "thermalmonitord", "/usr/libexec/thermalmonitord" },
	{ "powerd", "/System/Library/CoreServices/powerd.bundle/powerd" },
	{ "wifid", "/usr/sbin/wifid" },
	{ "configd", "/usr/libexec/configd" },
	{ "CommCenter", "/System/Library/Frameworks/CoreTelephony.framework/Support/CommCenter" },
	{ "logd", "/usr/libexec/logd" },
	{ "runningboardd", "/usr/libexec/runningboardd" },
	{ "audiomxd", "/usr/libexec/audiomxd" },
	{ "backboardd", "/usr/libexec/backboardd" },
};

static _Atomic uint64_t gQuarantineMask = 0;
static _Atomic uint64_t gQuarantineCacheTimestampNs = 0;
static atomic_flag gQuarantineRefreshLock = ATOMIC_FLAG_INIT;

static int copy_quarantine_path(const char *relativePath, char pathOut[PATH_MAX])
{
	const char *convertedPath = JBROOT_PATH(relativePath);
	if (!convertedPath) return ENOENT;
	if (strlcpy(pathOut, convertedPath, PATH_MAX) >= PATH_MAX) return ENAMETOOLONG;
	return 0;
}

static uint64_t monotonic_time_ns(void)
{
	struct timespec now = {};
	if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) return 0;
	return ((uint64_t)now.tv_sec * 1000ULL * 1000ULL * 1000ULL) + (uint64_t)now.tv_nsec;
}

static int read_quarantine_file(char *buffer, size_t bufferSize)
{
	if (!buffer || bufferSize < 2) return EINVAL;
	buffer[0] = '\0';

	char filePath[PATH_MAX];
	int pathResult = copy_quarantine_path(ROOTHIDE_CRITICAL_SERVICE_FILE, filePath);
	if (pathResult != 0) return pathResult;
	int fd = open(filePath, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
	if (fd < 0) return errno == ENOENT ? 0 : errno;

	struct stat st = {};
	if (fstat(fd, &st) != 0) {
		int savedErrno = errno;
		close(fd);
		return savedErrno;
	}
	if (!S_ISREG(st.st_mode) || st.st_size < 0 || (uint64_t)st.st_size >= bufferSize) {
		close(fd);
		return EINVAL;
	}

	size_t total = 0;
	while (total < (size_t)st.st_size) {
		ssize_t amount = read(fd, buffer + total, (size_t)st.st_size - total);
		if (amount < 0) {
			if (errno == EINTR) continue;
			int savedErrno = errno;
			close(fd);
			return savedErrno;
		}
		if (amount == 0) break;
		total += (size_t)amount;
	}
	close(fd);
	buffer[total] = '\0';
	return 0;
}

static uint64_t quarantine_mask_from_text(char *text)
{
	uint64_t mask = 0;
	char *save = NULL;
	for (char *line = strtok_r(text, "\r\n", &save); line; line = strtok_r(NULL, "\r\n", &save)) {
		for (size_t index = 0; index < sizeof(gWatchdogQuarantineServices) / sizeof(gWatchdogQuarantineServices[0]); index++) {
			if (!strcmp(line, gWatchdogQuarantineServices[index].executablePath)) {
				mask |= (1ULL << index);
				break;
			}
		}
	}
	return mask;
}

static uint64_t cached_quarantine_mask(void)
{
	uint64_t now = monotonic_time_ns();
	uint64_t cachedAt = atomic_load_explicit(&gQuarantineCacheTimestampNs, memory_order_acquire);
	if (now != 0 && cachedAt != 0 && now >= cachedAt && now - cachedAt < ROOTHIDE_CRITICAL_SERVICE_CACHE_NS) {
		return atomic_load_explicit(&gQuarantineMask, memory_order_relaxed);
	}

	if (atomic_flag_test_and_set_explicit(&gQuarantineRefreshLock, memory_order_acquire)) {
		return atomic_load_explicit(&gQuarantineMask, memory_order_relaxed);
	}

	char fileContents[ROOTHIDE_CRITICAL_SERVICE_FILE_MAX] = {};
	uint64_t refreshedMask = 0;
	if (read_quarantine_file(fileContents, sizeof(fileContents)) == 0) {
		refreshedMask = quarantine_mask_from_text(fileContents);
	}
	atomic_store_explicit(&gQuarantineMask, refreshedMask, memory_order_relaxed);
	atomic_store_explicit(&gQuarantineCacheTimestampNs, now ? now : 1, memory_order_release);
	atomic_flag_clear_explicit(&gQuarantineRefreshLock, memory_order_release);
	return refreshedMask;
}

bool roothide_critical_service_should_skip_injection(const char *path)
{
	if (!path) return false;

	if (__builtin_available(iOS 18.0, *)) {
		for (size_t index = 0; index < sizeof(gIOS18FixedNoInjectPaths) / sizeof(gIOS18FixedNoInjectPaths[0]); index++) {
			if (!strcmp(path, gIOS18FixedNoInjectPaths[index])) return true;
		}

		uint64_t mask = cached_quarantine_mask();
		for (size_t index = 0; index < sizeof(gWatchdogQuarantineServices) / sizeof(gWatchdogQuarantineServices[0]); index++) {
			if ((mask & (1ULL << index)) && !strcmp(path, gWatchdogQuarantineServices[index].executablePath)) {
				return true;
			}
		}
	}
	return false;
}

static int ensure_quarantine_directory(void)
{
	char directory[PATH_MAX];
	int pathResult = copy_quarantine_path(ROOTHIDE_CRITICAL_SERVICE_DIRECTORY, directory);
	if (pathResult != 0) return pathResult;
	bool created = false;
	if (mkdir(directory, 0755) == 0) {
		created = true;
	}
	else if (errno != EEXIST) {
		return errno;
	}
	if (created) {
		char parentDirectory[PATH_MAX];
		pathResult = copy_quarantine_path("/var/mobile/Library", parentDirectory);
		if (pathResult != 0) return pathResult;
		struct stat parentStat = {};
		if (lstat(parentDirectory, &parentStat) != 0) return errno;
		if (chown(directory, parentStat.st_uid, parentStat.st_gid) != 0) return errno;
	}
	struct stat st = {};
	if (lstat(directory, &st) != 0) return errno;
	return S_ISDIR(st.st_mode) && !S_ISLNK(st.st_mode) ? 0 : EINVAL;
}

static int lock_quarantine(int *lockFdOut)
{
	if (!lockFdOut) return EINVAL;
	*lockFdOut = -1;
	int directoryResult = ensure_quarantine_directory();
	if (directoryResult != 0) return directoryResult;

	char lockPath[PATH_MAX];
	int pathResult = copy_quarantine_path(ROOTHIDE_CRITICAL_SERVICE_LOCK, lockPath);
	if (pathResult != 0) return pathResult;
	int lockFd = open(lockPath, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0600);
	if (lockFd < 0) return errno;
	struct stat lockStat = {};
	if (fstat(lockFd, &lockStat) != 0) {
		int savedErrno = errno;
		close(lockFd);
		return savedErrno;
	}
	if (!S_ISREG(lockStat.st_mode) || lockStat.st_nlink != 1) {
		close(lockFd);
		return EINVAL;
	}
	if (fchmod(lockFd, 0600) != 0) {
		int savedErrno = errno;
		close(lockFd);
		return savedErrno;
	}
	while (flock(lockFd, LOCK_EX) != 0) {
		if (errno == EINTR) continue;
		int savedErrno = errno;
		close(lockFd);
		return savedErrno;
	}
	*lockFdOut = lockFd;
	return 0;
}

static void unlock_quarantine(int lockFd)
{
	if (lockFd < 0) return;
	(void)flock(lockFd, LOCK_UN);
	close(lockFd);
}

static int write_quarantine_mask_unlocked(uint64_t mask)
{
	int directoryResult = ensure_quarantine_directory();
	if (directoryResult != 0) return directoryResult;

	char contents[ROOTHIDE_CRITICAL_SERVICE_FILE_MAX] = {};
	size_t used = 0;
	for (size_t index = 0; index < sizeof(gWatchdogQuarantineServices) / sizeof(gWatchdogQuarantineServices[0]); index++) {
		if (!(mask & (1ULL << index))) continue;
		int written = snprintf(contents + used, sizeof(contents) - used, "%s\n",
			gWatchdogQuarantineServices[index].executablePath);
		if (written < 0 || (size_t)written >= sizeof(contents) - used) return ENOSPC;
		used += (size_t)written;
	}

	char filePath[PATH_MAX];
	int pathResult = copy_quarantine_path(ROOTHIDE_CRITICAL_SERVICE_FILE, filePath);
	if (pathResult != 0) return pathResult;
	char temporaryPath[PATH_MAX] = {};
	if (strlcpy(temporaryPath, filePath, sizeof(temporaryPath)) >= sizeof(temporaryPath) ||
		strlcat(temporaryPath, ".tmp.XXXXXX", sizeof(temporaryPath)) >= sizeof(temporaryPath)) {
		return ENAMETOOLONG;
	}

	int fd = mkstemp(temporaryPath);
	if (fd < 0) return errno;
	(void)fcntl(fd, F_SETFD, FD_CLOEXEC);
	if (fchmod(fd, 0644) != 0) {
		int savedErrno = errno;
		close(fd);
		unlink(temporaryPath);
		return savedErrno;
	}

	size_t total = 0;
	while (total < used) {
		ssize_t amount = write(fd, contents + total, used - total);
		if (amount < 0) {
			if (errno == EINTR) continue;
			int savedErrno = errno;
			close(fd);
			unlink(temporaryPath);
			return savedErrno;
		}
		if (amount == 0) {
			close(fd);
			unlink(temporaryPath);
			return EIO;
		}
		total += (size_t)amount;
	}
	if (fsync(fd) != 0) {
		int savedErrno = errno;
		close(fd);
		unlink(temporaryPath);
		return savedErrno;
	}
	if (close(fd) != 0) {
		int savedErrno = errno;
		unlink(temporaryPath);
		return savedErrno;
	}
	if (rename(temporaryPath, filePath) != 0) {
		int savedErrno = errno;
		unlink(temporaryPath);
		return savedErrno;
	}

	atomic_store_explicit(&gQuarantineMask, mask, memory_order_relaxed);
	atomic_store_explicit(&gQuarantineCacheTimestampNs, monotonic_time_ns(), memory_order_release);
	return 0;
}

static const roothide_critical_service *service_from_watchdog_message(const char *panicMessage, size_t *indexOut)
{
	if (!panicMessage || !strstr(panicMessage, "induced crashes")) return NULL;

	const char *prefixes[] = {
		"no successful checkins from ",
		"checkin with service: ",
	};
	for (size_t prefixIndex = 0; prefixIndex < sizeof(prefixes) / sizeof(prefixes[0]); prefixIndex++) {
		const char *serviceStart = strstr(panicMessage, prefixes[prefixIndex]);
		if (!serviceStart) continue;
		serviceStart += strlen(prefixes[prefixIndex]);
		for (size_t index = 0; index < sizeof(gWatchdogQuarantineServices) / sizeof(gWatchdogQuarantineServices[0]); index++) {
			size_t nameLength = strlen(gWatchdogQuarantineServices[index].serviceName);
			char next = serviceStart[nameLength];
			if (!strncmp(serviceStart, gWatchdogQuarantineServices[index].serviceName, nameLength) &&
				(next == ' ' || next == '(' || next == '\n' || next == '\r' || next == '\0')) {
				if (indexOut) *indexOut = index;
				return &gWatchdogQuarantineServices[index];
			}
		}
	}
	return NULL;
}

int roothide_critical_service_quarantine_from_watchdog(const char *panicMessage,
	char *pathOut, size_t pathOutSize)
{
	if (!__builtin_available(iOS 18.0, *)) return ENOTSUP;
	size_t serviceIndex = 0;
	const roothide_critical_service *service = service_from_watchdog_message(panicMessage, &serviceIndex);
	if (!service) return ENOENT;

	char fileContents[ROOTHIDE_CRITICAL_SERVICE_FILE_MAX] = {};
	int lockFd = -1;
	int lockResult = lock_quarantine(&lockFd);
	if (lockResult != 0) return lockResult;
	int readResult = read_quarantine_file(fileContents, sizeof(fileContents));
	if (readResult != 0) {
		unlock_quarantine(lockFd);
		return readResult;
	}
	uint64_t mask = quarantine_mask_from_text(fileContents) | (1ULL << serviceIndex);

	int writeResult = write_quarantine_mask_unlocked(mask);
	unlock_quarantine(lockFd);
	if (writeResult != 0) return writeResult;
	if (pathOut && pathOutSize > 0) strlcpy(pathOut, service->executablePath, pathOutSize);
	return 0;
}

int roothide_critical_service_quarantine_clear(void)
{
	int lockFd = -1;
	int lockResult = lock_quarantine(&lockFd);
	if (lockResult != 0) return lockResult;
	char filePath[PATH_MAX];
	int pathResult = copy_quarantine_path(ROOTHIDE_CRITICAL_SERVICE_FILE, filePath);
	if (pathResult != 0) {
		unlock_quarantine(lockFd);
		return pathResult;
	}
	if (unlink(filePath) != 0 && errno != ENOENT) {
		int savedErrno = errno;
		unlock_quarantine(lockFd);
		return savedErrno;
	}
	atomic_store_explicit(&gQuarantineMask, 0, memory_order_relaxed);
	atomic_store_explicit(&gQuarantineCacheTimestampNs, monotonic_time_ns(), memory_order_release);
	unlock_quarantine(lockFd);
	return 0;
}

int roothide_critical_service_quarantine_copy(char *buffer, size_t bufferSize)
{
	return read_quarantine_file(buffer, bufferSize);
}
