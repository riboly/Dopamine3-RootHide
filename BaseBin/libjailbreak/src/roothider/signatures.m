#include <choma/Fat.h>
#include <choma/MachO.h>
#include <choma/Host.h>
#include <mach-o/dyld.h>
#include "../trustcache.h"
#include "../roothider.h"
#include "../jbroot.h"

#include <sys/stat.h>
#include <sys/mount.h>
#include <os/log.h>
#import <Foundation/Foundation.h>

#define DEBUG_LOG(...) //JBLogDebug(__VA_ARGS__)

MachO* fat_find_preferred_slice(Fat *fat)
{
	cpu_type_t cputype;
	cpu_subtype_t cpusubtype;
	if (host_get_cpu_information(&cputype, &cpusubtype) != 0) { return NULL; }
	
	MachO *candidateSlice = NULL;

	if (cpusubtype == CPU_SUBTYPE_ARM64E) {
		// New arm64e ABI
		candidateSlice = fat_find_slice(fat, cputype, CPU_SUBTYPE_ARM64E | CPU_SUBTYPE_ARM64E_ABI_V2);
		if (!candidateSlice) {
			// Old arm64e ABI
			candidateSlice = fat_find_slice(fat, cputype, CPU_SUBTYPE_ARM64E);
			if (candidateSlice) {
				// If we found an old arm64e slice, make sure this is a library! If it's a binary, skip!!!
				// For binaries the system will fall back to the arm64 slice, which has the CDHash that we want to add
				if (macho_get_filetype(candidateSlice) == MH_EXECUTE) candidateSlice = NULL;
			}
		}
	}

	if (!candidateSlice) {
		// On iOS 15+ the kernels prefers ARM64_V8 to ARM64_ALL
		candidateSlice = fat_find_slice(fat, cputype, CPU_SUBTYPE_ARM64_V8);
		if (!candidateSlice) {
			candidateSlice = fat_find_slice(fat, cputype, CPU_SUBTYPE_ARM64_ALL);
		}
	}

	return candidateSlice;
}

extern bool csd_superblob_is_adhoc_signed(CS_DecodedSuperBlob *superblob);

NSString* resolveLoaderExecutablePaths(NSString *loadPath, NSString *loaderPath, NSString *mainExecutablePath)
{
	if ([loadPath hasPrefix:@"@loader_path/"] || [loadPath isEqualToString:@"@loader_path"]) {
		return [loadPath stringByReplacingCharactersInRange:NSMakeRange(0,sizeof("@loader_path")-1) withString:loaderPath.stringByDeletingLastPathComponent];
	}
	if ([loadPath hasPrefix:@"@executable_path/"] || [loadPath isEqualToString:@"@executable_path"]) {
		return [loadPath stringByReplacingCharactersInRange:NSMakeRange(0,sizeof("@executable_path")-1) withString:mainExecutablePath.stringByDeletingLastPathComponent];
	}
	return nil;
};

NSString* resolveRpaths(NSString *loadPath, NSString *mainExecutablePath, NSArray* rpathStack)
{
@autoreleasepool {

	DEBUG_LOG("Resolving rpaths for %s, mainExecutable: %s, rpathStack: %s", loadPath.fileSystemRepresentation, mainExecutablePath.fileSystemRepresentation, rpathStack.description.UTF8String);

	__block NSString *rpathResolvedPath = nil;

	for (NSString* loaderPath in rpathStack.reverseObjectEnumerator)
	{
		Fat *fat = fat_init_from_path(loaderPath.fileSystemRepresentation);
		if (fat) {
			MachO *macho = fat_find_preferred_slice(fat);
			if (macho) {
				macho_enumerate_rpaths(macho, ^(const char *rpathCStr, bool *stop) {
					NSString* possiblePath = [loadPath stringByReplacingCharactersInRange:NSMakeRange(0,sizeof("@rpath")-1) withString:@(rpathCStr)];
					possiblePath = resolveLoaderExecutablePaths(possiblePath, loaderPath, mainExecutablePath) ?: possiblePath;
					if(![possiblePath hasPrefix:@"/"]) { // dyld only supports relative path in rpath on macOS
						JBLogDebug("Skipping relative rpath: %s -> %s", loadPath.fileSystemRepresentation, possiblePath.fileSystemRepresentation);
						return;
					}
					if (_dyld_shared_cache_contains_path(possiblePath.fileSystemRepresentation)
					 || [[NSFileManager defaultManager] fileExistsAtPath:possiblePath]) {
						rpathResolvedPath = possiblePath;
						*stop = true;
					}
				});
			}
			fat_free(fat);
		}

		if(rpathResolvedPath)
			break;
	}
	
	return rpathResolvedPath;

} //autoreleasepool
}

NSString *resolveLoadPath(NSString *loadPath, NSString *loaderPath, NSString *mainExecutablePath, NSString* workingDir, NSArray* rpathStack)
{
	if (!loadPath) return nil;

	NSString *resolvedPath = nil;

	if ([loadPath hasPrefix:@"@rpath/"]) {
		resolvedPath = resolveRpaths(loadPath, mainExecutablePath, rpathStack);
	} else {
		resolvedPath = resolveLoaderExecutablePaths(loadPath, loaderPath, mainExecutablePath);
	}

	if(!resolvedPath) {
		resolvedPath = loadPath;
	}

	if([resolvedPath hasPrefix:@"@"]) { // dyld does not support this path
		JBLogDebug("Skipping unresolvable loadPath: %s", resolvedPath.fileSystemRepresentation);
		return nil;
	}

	if(![resolvedPath hasPrefix:@"/"]) {
		JBLogDebug("Resolving relative path: %s + %s", workingDir.fileSystemRepresentation, resolvedPath.fileSystemRepresentation);
		return workingDir ? [workingDir stringByAppendingPathComponent:resolvedPath] : nil;
	}
	
	return resolvedPath;
}

typedef struct {
	uint32_t Count;
	uint32_t* Types;
	uint32_t* Subtypes;
} preferredArchInfo;

static void recurse_handler(NSString *loadPath, NSString *loaderPath, NSString *mainExecutablePath, NSString *workingDir, NSMutableArray* fileCaches, NSMutableArray* rpathStack, preferredArchInfo* preferredArch, cdhash_t **cdhashesOut, uint32_t *cdhashCountOut)
{
@autoreleasepool {
	bool trace = [mainExecutablePath containsString:@"/.jbroot-"];

	DEBUG_LOG("Recursing into loadPath: %s\n\tloader: %s\n\tmainExecutable: %s\nworkingDir: %s\n", loadPath.fileSystemRepresentation, loaderPath.fileSystemRepresentation, mainExecutablePath.fileSystemRepresentation, workingDir.fileSystemRepresentation);

	bool (^cdhashesContains)(cdhash_t) = ^bool(cdhash_t cdhash) {
		for (int i = 0; i < (*cdhashCountOut); i++) {
			if (!memcmp((*cdhashesOut)[i], cdhash, sizeof(cdhash_t))) {
				return true;
			}
		}
		return false;
	};
	void (^cdhashesAdd)(cdhash_t) = ^(cdhash_t cdhash) {
		(*cdhashCountOut)++;
		(*cdhashesOut) = realloc((*cdhashesOut), (*cdhashCountOut) * sizeof(cdhash_t));
		memcpy((*cdhashesOut)[(*cdhashCountOut)-1], cdhash, sizeof(cdhash_t));
	};


	NSString *resolvedLoadPath = resolveLoadPath(loadPath, loaderPath, mainExecutablePath, workingDir, rpathStack);
	if(!resolvedLoadPath) {
		JBLogError("Failed to resolve dependency library for %s (loader: %s, mainExecutable: %s)", loadPath.fileSystemRepresentation, loaderPath.fileSystemRepresentation, mainExecutablePath.fileSystemRepresentation);
		return;
	}
	if (trace) {
		os_log_error(OS_LOG_DEFAULT, "[APTTRUST-7C31] resolve load=%{public}s resolved=%{public}s loader=%{public}s", loadPath.fileSystemRepresentation, resolvedLoadPath.fileSystemRepresentation, loaderPath.fileSystemRepresentation);
	}

	if(_dyld_shared_cache_contains_path(resolvedLoadPath.fileSystemRepresentation)) {
		DEBUG_LOG("Skipping dyld shared cached library: %s", resolvedLoadPath.fileSystemRepresentation);
		return;
	}

	char realfilepath[PATH_MAX] = {0};
	int fd = open(resolvedLoadPath.fileSystemRepresentation, O_RDONLY);
	if (fd < 0) {
		JBLogError("Failed to open binary at path: %s (loader: %s)", resolvedLoadPath.fileSystemRepresentation, loaderPath.fileSystemRepresentation);
		return;
	}
	if(fcntl(fd, F_GETPATH, realfilepath) != 0) {
		JBLogError("Failed to get file path for fd %d", fd);
		close(fd);
		return;
	}
	close(fd);

	if(string_has_prefix(realfilepath, "/private/preboot/Cryptexes/")) {
		JBLogDebug("Skipping Cryptexes file: %s", realfilepath);
		return;
	}
	
	if(isRemovableBundlePath(realfilepath) && !hasTrollstoreLiteMarker(realfilepath)) {
		// ignore adhoc signed apps(removable system apps or other stuffs) which is not installed via tslite
		JBLogDebug("ignoring addhoc signed app: %s\n", realfilepath);
		return;
	}
	
	const char *jbrootPath = JBROOT_PATH("/");
	bool isInsideJBRoot = jbrootPath && isSubPathOf(realfilepath, jbrootPath);
	struct statfs fs;
	int sfsret = statfs(realfilepath, &fs);
	if (trace) {
		os_log_error(OS_LOG_DEFAULT, "[APTTRUST-7C31] canonical path=%{public}s mount=%{public}s inside-jbroot=%d", realfilepath, sfsret == 0 ? fs.f_mntonname : "(statfs-failed)", isInsideJBRoot);
	}
	if(sfsret == 0) {
		if(!isInsideJBRoot && (strcmp(fs.f_mntonname, "/")==0 || strcmp(fs.f_mntonname, "/Developer")==0)) {
			return;
		}
	}

	NSString* realLoadPath = @(realfilepath);

	DEBUG_LOG("loadPath = %s, \n\tresolvedLoadPath = %s, \n\trealLoadPath = %s\n", loadPath.fileSystemRepresentation, resolvedLoadPath.fileSystemRepresentation, realLoadPath.fileSystemRepresentation);

	if([fileCaches containsObject:realLoadPath]) {
		DEBUG_LOG("Skipping already parsed file: %s", realLoadPath.fileSystemRepresentation);
		return; // Already parsed
	}
	//add realLoadPath to fileCaches
	[fileCaches addObject:realLoadPath];
	
	ensure_jbroot_symlink(realLoadPath.fileSystemRepresentation);

	Fat *fat = fat_init_from_path(realLoadPath.fileSystemRepresentation);
	if (!fat) {
		JBLogError("Failed to parse fat binary at path: %s", realLoadPath.fileSystemRepresentation);
		return;
	}

	MachO *macho = NULL;
	if ([loadPath isEqualToString:mainExecutablePath]) {
		if (preferredArch->Count > 0) {
			for (size_t i = 0; i < preferredArch->Count; i++) {
				if (preferredArch->Types[i] != 0 && preferredArch->Subtypes[i] != UINT32_MAX) {
					macho = fat_find_slice(fat, preferredArch->Types[i], preferredArch->Subtypes[i]);
					if (macho) break;
				}
			}
		}
	}
	if (!macho) {
		macho = fat_find_preferred_slice(fat);
		if (!macho) {
			JBLogError("Failed to find preferred slice for file: %s", realLoadPath.fileSystemRepresentation);
			fat_free(fat);
			return;
		}
	}

	// Calculate cdhash and add it to our array
	bool isAdhocSigned = false;
	CS_SuperBlob *superblob = macho_read_code_signature(macho);
	if (superblob) {
		CS_DecodedSuperBlob *decodedSuperblob = csd_superblob_decode(superblob);
		if (decodedSuperblob) {
			if (csd_superblob_is_adhoc_signed(decodedSuperblob)) {
				isAdhocSigned = true;
				cdhash_t cdhash = {0};
				if (csd_superblob_calculate_best_cdhash(decodedSuperblob, cdhash, NULL) == 0) {
					if (!cdhashesContains(cdhash)) {
						bool shouldAdd = is_cdhash_trustcached(cdhash);
						if (trace) {
							os_log_error(OS_LOG_DEFAULT, "[APTTRUST-7C31] cdhash path=%{public}s cached=%d", realLoadPath.fileSystemRepresentation, shouldAdd);
						}
						if (!shouldAdd) {
							int ret = ensure_randomized_cdhash_for_slice(realLoadPath.fileSystemRepresentation, macho->archDescriptor.offset, cdhash);
							if (trace) {
								os_log_error(OS_LOG_DEFAULT, "[APTTRUST-7C31] randomize result=%d path=%{public}s", ret, realLoadPath.fileSystemRepresentation);
							}
							if (ret == 0) {
								shouldAdd = true;
							} else {
								JBLogError("ensure_randomized_cdhash_for_slice(%llx) failed: %s -> (%d)", macho->archDescriptor.offset, realLoadPath.fileSystemRepresentation, ret);
							}
						}

						// Include hashes already reported as trusted in this request too. This
						// makes the dynamic upload self-contained when an older or malformed
						// trustcache produced a stale positive lookup.
						if (shouldAdd) {
							cdhashesAdd(cdhash);
							if (trace) {
								os_log_error(OS_LOG_DEFAULT, "[APTTRUST-7C31] collected path=%{public}s total=%u", realLoadPath.fileSystemRepresentation, *cdhashCountOut);
							}
						}
					}
				}
			}
			csd_superblob_free(decodedSuperblob);
		}
		free(superblob);
	}

	// A trustcached executable can still reference a dependency that was
	// installed or replaced after the executable was trusted. Always walk the
	// dependency graph for ad-hoc binaries; fileCaches prevents recursion loops.
	if (!isAdhocSigned) {
		if (trace) {
			os_log_error(OS_LOG_DEFAULT, "[APTTRUST-7C31] stop non-adhoc path=%{public}s", realLoadPath.fileSystemRepresentation);
		}
		fat_free(fat);
		return;
	}

	// Recurse this block on all dependencies
	macho_enumerate_dependencies(macho, ^(const char *pathCStr, uint32_t cmd, struct dylib* dylib, bool *stop) {

		NSMutableArray* nextChain = rpathStack.mutableCopy;
		[nextChain addObject:realLoadPath]; //Loading dependencies, add current macho itself to the rpath stack
		
		recurse_handler(@(pathCStr), realLoadPath, mainExecutablePath, workingDir, fileCaches, nextChain, preferredArch, cdhashesOut, cdhashCountOut);
	});

	fat_free(fat);
	
} //autoreleasepool
}

void recurse_collect_untrusted_cdhashes(const char *path, const char *callerImagePath, const char *callerExecutablePath, const char *workingDir, preferredArchInfo* preferredArch, cdhash_t **cdhashesOut, uint32_t *cdhashCountOut)
{
	if(!callerExecutablePath) {
		callerExecutablePath = path;
	}

	NSMutableArray* rpathStack = [NSMutableArray array];

	[rpathStack addObject:@(callerExecutablePath)]; //initial rpath stack
	
	if(callerImagePath && strcmp(callerImagePath, callerExecutablePath) != 0) {
		[rpathStack addObject:@(callerImagePath)];
	}

	if(!callerImagePath) {
		callerImagePath = path;
	}

	NSMutableArray* fileCaches = [NSMutableArray array];

	recurse_handler(@(path), @(callerImagePath), @(callerExecutablePath), workingDir ? @(workingDir) : nil, fileCaches, rpathStack, preferredArch, cdhashesOut, cdhashCountOut);

	DEBUG_LOG("fileCaches: %s", path, fileCaches.description.UTF8String);
	DEBUG_LOG("Finished collecting cdhashes for path: %s, found %u cdhashes, processed %d files", path, *cdhashCountOut, fileCaches.count);
}
