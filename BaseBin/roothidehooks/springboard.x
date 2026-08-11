#import <Foundation/Foundation.h>
#include <roothide.h>
#include <libjailbreak/jbclient_xpc.h>
#import <fcntl.h>
#include <stdint.h>
#include "common.h"

static NSString *springboardJbrootPath(NSString *path)
{
	const char *rootPath = jbclient_get_jbroot();
	if (!rootPath || !path.fileSystemRepresentation) {
		return nil;
	}
	return [NSString stringWithFormat:@"%s%s", rootPath, path.fileSystemRepresentation];
}

%hookf(int, fcntl, int fildes, int cmd, ...) {
	if (cmd == F_SETPROTECTIONCLASS) {
		char filePath[PATH_MAX];
		if (fcntl(fildes, F_GETPATH, filePath) != -1) {
			// Skip setting protection class on jailbreak apps, this doesn't work and causes snapshots to not be saved correctly
			if (isSubPathOf(filePath, jbroot("/var/mobile/Library/SplashBoard/Snapshots/"))) {
				return 0;
			}
		}
	}

	// Preserve fcntl's ABI without walking beyond its single optional argument.
	// Passing a zero placeholder to no-argument commands is safe because the
	// original variadic wrapper and kernel ignore it for those commands.
	switch (cmd) {
		case F_GETOWN:
		case F_GETFD:
		case F_GETFL:
		case F_FULLFSYNC:
		case F_FREEZE_FS:
		case F_THAW_FS:
		case F_GETPROTECTIONCLASS:
		case F_GETNOSIGPIPE:
		case F_GETPROTECTIONLEVEL:
		case F_BARRIERFSYNC:
		case F_GETLEASE:
			return %orig(fildes, cmd, (uintptr_t)0);

		default: {
			va_list a;
			va_start(a, cmd);
			uintptr_t arg = va_arg(a, uintptr_t);
			va_end(a);
			return %orig(fildes, cmd, arg);
		}
	}
}

@interface XBSnapshotContainerIdentity : NSObject
@property NSString* bundleIdentifier;
@end

%hook XBSnapshotContainerIdentity

/*
-(id)_initWithBundleIdentifier:(id)arg1 bundlePath:(id)arg2 dataContainerPath:(id)arg3 bundleContainerPath:(id)arg4 
{
    NSLog(@"snapshot init, id=%@, bundlePath=%@, dataContainerPath=%@, bundleContainerPath=%@", arg1, arg2, arg3, arg4);

    return %orig;
}
*/

-(NSString *)snapshotContainerPath {
    NSString* path = %orig;

    if([path hasPrefix:@"/var/mobile/Library/SplashBoard/Snapshots/"] && (![self.bundleIdentifier hasPrefix:@"com.apple."] || is_apple_internal_identifier(self.bundleIdentifier.UTF8String))) {
        NSString *redirectedPath = springboardJbrootPath(path);
        BOOL isDirectory = NO;
        NSFileManager *fileManager = NSFileManager.defaultManager;
        BOOL exists = [fileManager fileExistsAtPath:redirectedPath isDirectory:&isDirectory];

		if ((!exists || !isDirectory)) {
			NSError *error = nil;
			BOOL created = [fileManager createDirectoryAtPath:redirectedPath
				withIntermediateDirectories:YES
				attributes:@{ NSFilePosixPermissions : @0755 }
				error:&error];
			if (!created) {
				NSLog(@"snapshotContainerPath fallback %@ : failed to create %@ (%@)", self.bundleIdentifier, redirectedPath, error);
				return path;
			}
		}

		NSLog(@"snapshotContainerPath redirect %@ : %@ -> %@", self.bundleIdentifier, path, redirectedPath);
		path = redirectedPath;
    }

    return path;
}

%end

static const void *kDenyQueryTagKey = &kDenyQueryTagKey;

%hook FBSApplicationLibrary
-(id)applicationInfoForBundleIdentifier:(NSString*)bundleIdentifier
{
	id result = %orig; //SBApplicationInfo
	NSURL* executableURL = [result performSelector:@selector(executableURL)];
	NSLog(@"FBSApplicationLibrary applicationInfoForBundleIdentifier %@ : %@, %@", bundleIdentifier, result, executableURL);

	NSNumber* tag = objc_getAssociatedObject(bundleIdentifier, kDenyQueryTagKey);

	if(tag && tag.boolValue) {

		if(is_sensitive_app_identifier(bundleIdentifier.UTF8String)) {
			NSLog(@"FBSApplicationLibrary deny query %@", bundleIdentifier);
			return nil;
		}

		if(result && executableURL && isJailbreakBundlePath(executableURL.path.fileSystemRepresentation)) {
			NSLog(@"FBSApplicationLibrary deny query %@", bundleIdentifier);
			return nil;
		}
	}

	return result;
}
%end

%hook FBSystemService
-(void*)openApplication:(NSString*)bundleIdentifier withOptions:(id)options originator:(id)originator requestID:(void*)requestID completion:(void*)completion
{
	NSLog(@"openApplication %@ withOptions:%@ originator:%@ requestID:%@ completion:%p", bundleIdentifier, options, originator, requestID, completion);

	id currentContext = [NSClassFromString(@"BSServiceConnection") performSelector:@selector(currentContext)];
	id remoteProcess = [currentContext performSelector:@selector(remoteProcess)]; //BSProcessHandle

	NSNumber* _pid = [remoteProcess valueForKey:@"_pid"];
	NSString* _bundleID = [remoteProcess valueForKey:@"_bundleID"]; //may be nil

	pid_t pid = _pid.intValue;

	NSLog(@"openApplication %@ from pid=%d bundleID=%@", bundleIdentifier, pid, _bundleID);

	BOOL taggedDenyQuery = jbclient_blacklist_check_pid(pid);
	if(taggedDenyQuery) {
		NSLog(@"openApplication deny request from %@", _bundleID);
		objc_setAssociatedObject(bundleIdentifier, kDenyQueryTagKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	}

	void *result = %orig;

	// The tag is call-scoped. Leaving it attached permanently makes unrelated
	// SplashBoard queries treat jailbreak apps as missing and deny snapshots.
	if(taggedDenyQuery) {
		objc_setAssociatedObject(bundleIdentifier, kDenyQueryTagKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	}

	return result;
}
%end

void sbInit(void)
{
	NSLog(@"sbInit...");
	%init();
}
