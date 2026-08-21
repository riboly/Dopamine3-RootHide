//
//  EnvironmentManager.m
//  Dopamine
//
//  Created by Lars Fröder on 10.01.24.
//

#import "DOEnvironmentManager.h"
#import "UIImage+JPEG2000.h"

#import <sys/sysctl.h>
#import <sys/mount.h>
#import <sys/utsname.h>
#import <sys/stat.h>
#import <sys/wait.h>
#import <errno.h>
#import <unistd.h>
#import <mach-o/dyld.h>
#import <libgrabkernel2/libgrabkernel2.h>
#import <libjailbreak/info.h>
#import <libjailbreak/codesign.h>
#import <libjailbreak/util.h>
#import <libjailbreak/display.h>
#import <libjailbreak/machine_info.h>
#import <libjailbreak/carboncopy.h>

#import <IOKit/IOKitLib.h>
#import "DOUIManager.h"
#import "DOExploitManager.h"
#import "DOPreferenceManager.h"
#import "NSData+Hex.h"
#import <LocalAuthentication/LocalAuthentication.h>

int reboot3(uint64_t flags, ...);
CFPropertyListRef MGCopyAnswer(CFStringRef);
extern char **environ;

@implementation DOEnvironmentManager

@synthesize bootManifestHash = _bootManifestHash;

+ (instancetype)sharedManager
{
    static DOEnvironmentManager *shared;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[DOEnvironmentManager alloc] init];
    });
    return shared;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _bootstrapNeedsMigration = NO;
        _bootstrapper = [[DOBootstrapper alloc] init];
        if ([self isJailbroken]) {
            gSystemInfo.jailbreakInfo.rootPath = strdup(jbclient_get_jbroot() ?: "");
        }
        else if ([self isInstalledThroughTrollStore]) {
            [self locateJailbreakRoot];
        }
    }
    return self;
}

- (NSString *)nightlyHash
{
#ifdef NIGHTLY
    return [NSString stringWithUTF8String:COMMIT_HASH];
#else
    return nil;
#endif
}

- (NSString *)appVersion
{
    return [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
}

- (NSString *)appVersionDisplayString
{
    NSString *nightlyHash = [self nightlyHash];
    if (nightlyHash) {
        return [NSString stringWithFormat:@"%@~%@", self.appVersion, [nightlyHash substringToIndex:6]];
    }
    else {
        return [self appVersion];
    }
}

- (NSData *)bootManifestHash
{
    if (!_bootManifestHash) {
        io_registry_entry_t registryEntry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/chosen");
        if (registryEntry) {
            _bootManifestHash = (__bridge NSData *)IORegistryEntryCreateCFProperty(registryEntry, CFSTR("boot-manifest-hash"), NULL, 0);
        }
    }
    return _bootManifestHash;
}

- (NSString *)privatePrebootPath
{
    return @"/private/preboot";
}

- (NSString *)activePrebootPath
{
    return [[self privatePrebootPath] stringByAppendingPathComponent:[self bootManifestHash].hexString];
}

/*
- (void)locateJailbreakRoot
{
    if (!gSystemInfo.jailbreakInfo.rootPath) {
        NSString *activePrebootPath = [self activePrebootPath];
        
        NSString *randomizedJailbreakPath;
        
        // First attempt at finding jailbreak root, look for Dopamine 2.x path
        for (NSString *subItem in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:activePrebootPath error:nil]) {
            if (subItem.length == 15 && [subItem hasPrefix:@"dopamine-"]) {
                randomizedJailbreakPath = [activePrebootPath stringByAppendingPathComponent:subItem];
                break;
            }
        }
        
        if (!randomizedJailbreakPath) {
            // Second attempt at finding jailbreak root, look for Dopamine 1.x path, but as other jailbreaks use it too, make sure it is Dopamine
            // Some other jailbreaks also commit the sin of creating .installed_dopamine, for these we try to filter them out by checking for their installed_ file
            // If we find this and are sure it's from Dopamine 1.x, rename it so all Dopamine 2.x users will have the same path
            for (NSString *subItem in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:activePrebootPath error:nil]) {
                if (subItem.length == 9 && [subItem hasPrefix:@"jb-"]) {
                    NSString *candidateLegacyPath = [activePrebootPath stringByAppendingPathComponent:subItem];
                    
                    BOOL installedDopamine = [[NSFileManager defaultManager] fileExistsAtPath:[candidateLegacyPath stringByAppendingPathComponent:@"procursus/.installed_dopamine"]];
                    
                    if (installedDopamine) {
                        // Hopefully all other jailbreaks that use jb-<UUID>?
                        // These checks exist because of dumb users (and jailbreak developers) creating .installed_dopamine on jailbreaks that are NOT dopamine...
                        BOOL installedNekoJB = [[NSFileManager defaultManager] fileExistsAtPath:[candidateLegacyPath stringByAppendingPathComponent:@"procursus/.installed_nekojb"]];
                        BOOL installedDefinitelyNotAGoodName = [[NSFileManager defaultManager] fileExistsAtPath:[candidateLegacyPath stringByAppendingPathComponent:@"procursus/.xia0o0o0o_jb_installed"]];
                        BOOL installedPalera1n = [[NSFileManager defaultManager] fileExistsAtPath:[candidateLegacyPath stringByAppendingPathComponent:@"procursus/.palecursus_strapped"]];
                        if (installedNekoJB || installedPalera1n || installedDefinitelyNotAGoodName) {
                            continue;
                        }
                        
                        randomizedJailbreakPath = candidateLegacyPath;
                        _bootstrapNeedsMigration = YES;
                        break;
                    }
                }
            }
        }
        
        if (randomizedJailbreakPath) {
            NSString *jailbreakRootPath = [randomizedJailbreakPath stringByAppendingPathComponent:@"procursus"];
            if ([[NSFileManager defaultManager] fileExistsAtPath:jailbreakRootPath]) {
                // This attribute serves as the primary source of what the root path is
                // Anything else in the jailbreak will get it from here
                gSystemInfo.jailbreakInfo.rootPath = strdup(jailbreakRootPath.fileSystemRepresentation);
            }
        }
    }
}

- (NSError *)ensureJailbreakRootExists
{
    NSError *error = nil;

    [self locateJailbreakRoot];
    
    if (!gSystemInfo.jailbreakInfo.rootPath || _bootstrapNeedsMigration) {
        [_bootstrapper ensurePrivatePrebootIsWritable];

        NSString *activePrebootPath = [self activePrebootPath];

        NSString *characterSet = @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
        NSUInteger stringLen = 6;
        NSMutableString *randomString = [NSMutableString stringWithCapacity:stringLen];
        for (NSUInteger i = 0; i < stringLen; i++) {
            NSUInteger randomIndex = arc4random_uniform((uint32_t)[characterSet length]);
            unichar randomCharacter = [characterSet characterAtIndex:randomIndex];
            [randomString appendFormat:@"%C", randomCharacter];
        }
        
        NSString *randomJailbreakFolderName = [NSString stringWithFormat:@"dopamine-%@", randomString];
        NSString *randomizedJailbreakPath = [activePrebootPath stringByAppendingPathComponent:randomJailbreakFolderName];
        NSString *jailbreakRootPath = [randomizedJailbreakPath stringByAppendingPathComponent:@"procursus"];
        
        if (_bootstrapNeedsMigration) {
            NSString *oldRandomizedJailbreakPath = [[NSString stringWithUTF8String:gSystemInfo.jailbreakInfo.rootPath] stringByDeletingLastPathComponent];
            [[NSFileManager defaultManager] moveItemAtPath:oldRandomizedJailbreakPath toPath:randomizedJailbreakPath error:&error];
        }
        else {
            if (![[NSFileManager defaultManager] fileExistsAtPath:jailbreakRootPath]) {
                [[NSFileManager defaultManager] createDirectoryAtPath:jailbreakRootPath withIntermediateDirectories:YES attributes:nil error:&error];
            }
        }
        
        if (!error) {
            gSystemInfo.jailbreakInfo.rootPath = strdup(jailbreakRootPath.UTF8String);
        }
    }
    
    return error;
}
*/

- (BOOL)isArm64e
{
    cpu_subtype_t cpusubtype = 0;
    size_t len = sizeof(cpusubtype);
    if (sysctlbyname("hw.cpusubtype", &cpusubtype, &len, NULL, 0) == -1) { return NO; }
    return (cpusubtype & ~CPU_SUBTYPE_MASK) == CPU_SUBTYPE_ARM64E;
}

- (BOOL)isSPTM
{
    if (@available(iOS 17.0, *)) {
        io_registry_entry_t memoryMap = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/chosen/memory-map");
        if (memoryMap == IO_OBJECT_NULL) return NO;

        CFArrayRef keys = (CFArrayRef)IORegistryEntryCreateCFProperty(memoryMap, CFSTR(kIORegistryEntryPropertyKeysKey), kCFAllocatorDefault, 0);
        IOObjectRelease(memoryMap);
        if (!keys) return NO;

        CFRange range = CFRangeMake(0, CFArrayGetCount(keys));
        BOOL isSPTM = CFArrayContainsValue(keys, range, CFSTR("SPTM")) && CFArrayContainsValue(keys, range, CFSTR("TXM"));
        CFRelease(keys);
        return isSPTM;
    }
    return NO;
}

- (NSString *)versionSupportString
{
    cpu_subtype_t cpuFamily = 0;
    size_t cpuFamilySize = sizeof(cpuFamily);
    sysctlbyname("hw.cpufamily", &cpuFamily, &cpuFamilySize, NULL, 0);

    if ([self isArm64e]) {
        if (cpuFamily == CPUFAMILY_ARM_VORTEX_TEMPEST || cpuFamily == CPUFAMILY_ARM_LIGHTNING_THUNDER) {
            return @"iOS 15.0 - 18.7.1, 26.0 - 26.0.1 (A12/A13, PPL)";
        }
        if (![self isSPTM]) {
            return @"iOS 15.0 - 17.3.1 (PPL)";
        }
        return @"iOS 17.0 - 17.3.1 (SPTM)";
    }
    return @"iOS 15.0 - 18.7.1 (arm64)";
}

- (BOOL)isInstalledThroughTrollStore
{
    static BOOL trollstoreInstallation = NO;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString* trollStoreMarkerPath = [[[NSBundle mainBundle].bundlePath stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"_TrollStore"];
        trollstoreInstallation = [[NSFileManager defaultManager] fileExistsAtPath:trollStoreMarkerPath];
    });
    return trollstoreInstallation;
}

- (BOOL)isJailbroken
{
/************** roothide specific ***********/
    if (_isJailbroken)
        return YES;

    if(!jbclient_roothide_jailbroken())
        return NO;
/************** roothide specific ********/

    uint32_t csFlags = 0;
    csops(getpid(), CS_OPS_STATUS, &csFlags, sizeof(csFlags));
    _isJailbroken = (csFlags & CS_PLATFORM_BINARY) != 0;
    return _isJailbroken;
}

- (void)setJailbroken:(BOOL)jailbroken
{
    _isJailbroken = jailbroken;
}

- (BOOL)isJailbrokenWithOtherJailbreak
{
    if (![self isJailbroken]) {
        uint32_t csFlags = 0;
        csops(getpid(), CS_OPS_STATUS, &csFlags, sizeof(csFlags));

        // Palera1n or another platformized environment.
        if (csFlags & CS_PLATFORM_BINARY) return YES;

        // Dopamine 2 and older do not expose the Dopamine 3 client state.
        if (!access("/usr/lib/systemhook.dylib", F_OK)) return YES;
    }
    return NO;
}

- (NSString *)jailbrokenVersion
{
    if (!self.isJailbroken) return nil;

    __block NSString *version;
    [self runAsRoot:^{
        [self runUnsandboxed:^{
            version = [NSString stringWithContentsOfFile:JBROOT_PATH(@"/basebin/.version") encoding:NSUTF8StringEncoding error:nil];
        }];
    }];
    return [version stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

- (NSString *)systemVersion
{
    return (__bridge NSString *)MGCopyAnswer(CFSTR("ProductVersion"));
}

- (BOOL)isBootstrapped
{
    return (BOOL)jbinfo(rootPath);
}

- (void)runUnsandboxed:(void (^)(void))unsandboxBlock
{
    if ([self isInstalledThroughTrollStore]) {
        unsandboxBlock();
    }
    else if([self isJailbroken]) {
        uint64_t labelBackup = 0;
        jbclient_root_set_mac_label(1, -1, &labelBackup);
        unsandboxBlock();
        jbclient_root_set_mac_label(1, labelBackup, NULL);
    }
    else {
        // Hope that we are already unsandboxed
        unsandboxBlock();
    }
}

- (void)runAsRoot:(void (^)(void))rootBlock
{
    uint32_t orgUser = geteuid();
    uint32_t orgGroup = getegid();
    if (orgUser == 0 && orgGroup == 0) {
        rootBlock();
        return;
    }

    if (self.isJailbroken && jbclient_dopamine_get_root() == 0) {
        rootBlock();
        jbclient_dopamine_drop_root();
    }
}

- (int)spawnJbctlAsRootWithArgs:(NSArray<NSString *> *)args
{
    return [self spawnJbctlAsRootWithArgs:args outputHandler:nil];
}

- (int)spawnJbctlAsRootWithArgs:(NSArray<NSString *> *)args outputHandler:(void (^ _Nullable)(NSString *line))outputHandler
{
    if (args.count == 0) return EINVAL;

    BOOL needsLegacySolution = NO;
    NSString *jailbrokenVersion = self.jailbrokenVersion;
    if (jailbrokenVersion.length) {
        needsLegacySolution = [jailbrokenVersion compare:@"3.0.5" options:NSNumericSearch] == NSOrderedAscending;
    }

    char **argBuf = calloc(args.count + 4, sizeof(char *));
    argBuf[0] = strdup(JBROOT_PATH("/basebin/jbctl"));
    int i = 1;
    for (NSString *arg in args) {
        argBuf[i++] = strdup(arg.UTF8String);
    }
    if (!needsLegacySolution) {
        argBuf[i++] = strdup("--waitfor");
        argBuf[i++] = strdup("3");
    }

    posix_spawn_file_actions_t actions = NULL;
    posix_spawn_file_actions_init(&actions);
    posix_spawnattr_t attributes = NULL;
    posix_spawnattr_init(&attributes);

    int waitPipe[2] = {-1, -1};
    if (!needsLegacySolution) {
        if (pipe(waitPipe) != 0) {
            int pipeError = errno;
            posix_spawnattr_destroy(&attributes);
            posix_spawn_file_actions_destroy(&actions);
            for (int y = 0; y < i; y++) free(argBuf[y]);
            free(argBuf);
            return pipeError;
        }
        posix_spawn_file_actions_adddup2(&actions, waitPipe[0], 3);
        if (waitPipe[0] != 3) posix_spawn_file_actions_addclose(&actions, waitPipe[0]);
        posix_spawn_file_actions_addclose(&actions, waitPipe[1]);
    }
    else {
        posix_spawnattr_setflags(&attributes, POSIX_SPAWN_START_SUSPENDED);
    }

    int outputPipe[2] = {-1, -1};
    if (outputHandler) {
        if (pipe(outputPipe) != 0) {
            int pipeError = errno;
            if (waitPipe[0] >= 0) close(waitPipe[0]);
            if (waitPipe[1] >= 0) close(waitPipe[1]);
            posix_spawnattr_destroy(&attributes);
            posix_spawn_file_actions_destroy(&actions);
            for (int y = 0; y < i; y++) free(argBuf[y]);
            free(argBuf);
            return pipeError;
        }
        posix_spawn_file_actions_adddup2(&actions, outputPipe[1], STDOUT_FILENO);
        posix_spawn_file_actions_adddup2(&actions, outputPipe[1], STDERR_FILENO);
        posix_spawn_file_actions_addclose(&actions, outputPipe[0]);
        if (outputPipe[1] != STDOUT_FILENO && outputPipe[1] != STDERR_FILENO) {
            posix_spawn_file_actions_addclose(&actions, outputPipe[1]);
        }
    }

    __block pid_t pid = 0;
    __block int spawnResult = -1;
    [self runAsRoot:^{
        [self runUnsandboxed:^{
            spawnResult = posix_spawn(&pid, argBuf[0], &actions, &attributes, argBuf, environ);
            if (spawnResult == 0 && needsLegacySolution) {
                // Installed basebins older than 3.0.5 do not understand --waitfor.
                kill(pid, SIGCONT);
            }
        }];
        // On iOS 17+, restore credentials and the sandbox before jbctl acts.
    }];

    posix_spawnattr_destroy(&attributes);
    posix_spawn_file_actions_destroy(&actions);
    for (int y = 0; y < i; y++) free(argBuf[y]);
    free(argBuf);

    if (outputPipe[1] >= 0) close(outputPipe[1]);

    if (!needsLegacySolution) {
        if (spawnResult == 0) {
            char resumeByte = 'w';
            write(waitPipe[1], &resumeByte, sizeof(resumeByte));
        }
        close(waitPipe[0]);
        close(waitPipe[1]);
    }

    if (spawnResult != 0) {
        if (outputPipe[0] >= 0) close(outputPipe[0]);
        return spawnResult;
    }

    if (outputPipe[0] >= 0) {
        NSMutableString *pending = [NSMutableString string];
        char buffer[2048];
        ssize_t bytesRead = 0;
        while ((bytesRead = read(outputPipe[0], buffer, sizeof(buffer))) > 0) {
            NSString *chunk = [[NSString alloc] initWithBytes:buffer length:(NSUInteger)bytesRead encoding:NSUTF8StringEncoding];
            if (!chunk) chunk = [[NSString alloc] initWithBytes:buffer length:(NSUInteger)bytesRead encoding:NSASCIIStringEncoding];
            if (!chunk) continue;
            [pending appendString:chunk];
            while (YES) {
                NSRange newline = [pending rangeOfString:@"\n"];
                if (newline.location == NSNotFound) break;
                outputHandler([pending substringToIndex:newline.location]);
                [pending deleteCharactersInRange:NSMakeRange(0, newline.location + 1)];
            }
        }
        close(outputPipe[0]);
        if (pending.length) outputHandler(pending);
    }

    int waitStatus = 0;
    if (waitpid(pid, &waitStatus, 0) < 0) return errno;
    if (WIFEXITED(waitStatus)) return WEXITSTATUS(waitStatus);
    if (WIFSIGNALED(waitStatus)) return 128 + WTERMSIG(waitStatus);
    return ECHILD;
}

- (int)runTrollStoreAction:(NSString *)action
{
    if (![self isInstalledThroughTrollStore]) return -1;
    
    uint32_t selfPathSize = PATH_MAX;
    char selfPath[selfPathSize];
    _NSGetExecutablePath(selfPath, &selfPathSize);
    return exec_cmd_root(selfPath, "trollstore", action.UTF8String, NULL);
}

- (void)respring
{
    [self spawnJbctlAsRootWithArgs:@[@"respring"]];
}

- (void)rebootUserspace
{
    [self spawnJbctlAsRootWithArgs:@[@"reboot_userspace"]];
}

- (void)refreshJailbreakApps
{
    [self runAsRoot:^{
        [self runUnsandboxed:^{
            exec_cmd(JBROOT_PATH("/usr/bin/uicache"), "-a", NULL);
        }];
    }];
}

- (void)unregisterJailbreakApps
{
    [self runAsRoot:^{
        [self runUnsandboxed:^{
            NSArray *jailbreakApps = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:JBROOT_PATH(@"/Applications") error:nil];
            if (jailbreakApps.count) {
                for (NSString *jailbreakApp in jailbreakApps) {
                    NSString *jailbreakAppPath = [JBROOT_PATH(@"/Applications") stringByAppendingPathComponent:jailbreakApp];
                    exec_cmd(JBROOT_PATH("/usr/bin/uicache"), "-u", jailbreakAppPath.fileSystemRepresentation, NULL);
                }
            }
        }];
    }];
}

- (void)reboot
{
    [self runAsRoot:^{
        [self runUnsandboxed:^{
            reboot3(0x8000000000000000, 0);
        }];
    }];
}


- (void)changeMobilePassword:(NSString *)newPassword
{
    [self runAsRoot:^{
        [self runUnsandboxed:^{
            NSString *dashCommand = [NSString stringWithFormat:@"printf \"%%s\\n\" \"%@\" | %@ usermod 501 -h 0", newPassword, JBROOT_PATH(@"/usr/sbin/pw")];
            exec_cmd(JBROOT_PATH("/usr/bin/dash"), "-c", dashCommand.UTF8String, NULL);
        }];
    }];
}

- (NSError*)updateEnvironment
{
    NSString *newBasebinTarPath = [[NSBundle mainBundle].bundlePath stringByAppendingPathComponent:@"basebin.tar"];
    int result = jbclient_platform_stage_jailbreak_update(newBasebinTarPath.fileSystemRepresentation);
    if (result == 0) {
        [self rebootUserspace];
        return nil;
    }
    return [NSError errorWithDomain:@"Dopamine" code:result userInfo:nil];
}

- (void)updateJailbreakFromTIPA:(NSString *)tipaPath
{
    [self spawnJbctlAsRootWithArgs:@[@"update", @"tipa", tipaPath]];
}

- (BOOL)isTweakInjectionEnabled
{
    return ![[NSFileManager defaultManager] fileExistsAtPath:JBROOT_PATH(@"/basebin/.safe_mode")];
}

- (void)setTweakInjectionEnabled:(BOOL)enabled
{
    NSString *safeModePath = JBROOT_PATH(@"/basebin/.safe_mode");
    if ([self isJailbroken]) {
        [self runAsRoot:^{
            [self runUnsandboxed:^{
                if (enabled) {
                    [[NSFileManager defaultManager] removeItemAtPath:safeModePath error:nil];
                }
                else {
                    [[NSData data] writeToFile:safeModePath atomically:YES];
                }
            }];
        }];
    }
}

- (BOOL)isIDownloadEnabled
{
    __block BOOL isEnabled = NO;
    [self runAsRoot:^{
        [self runUnsandboxed:^{
            NSDictionary *disabledDict = [NSDictionary dictionaryWithContentsOfFile:@"/var/db/com.apple.xpc.launchd/disabled.plist"];
            NSNumber *idownloaddDisabledNum = disabledDict[@"com.opa334.Dopamine.idownloadd"];
            if (idownloaddDisabledNum) {
                isEnabled = ![idownloaddDisabledNum boolValue];
            }
            else {
                isEnabled = NO;
            }
        }];
    }];
    return isEnabled;
}

- (void)setIDownloadEnabled:(BOOL)enabled needsUnsandbox:(BOOL)needsUnsandbox
{
    void (^updateBlock)(void) = ^{
        if (enabled) {
            exec_cmd_trusted(JBROOT_PATH("/usr/bin/launchctl"), "enable", "system/com.opa334.Dopamine.idownloadd", NULL);
        }
        else {
            exec_cmd_trusted(JBROOT_PATH("/usr/bin/launchctl"), "disable", "system/com.opa334.Dopamine.idownloadd", NULL);
        }
    };

    if (needsUnsandbox) {
        [self runAsRoot:^{
            [self runUnsandboxed:updateBlock];
        }];
    }
    else {
        updateBlock();
    }
}

- (void)setIDownloadLoaded:(BOOL)loaded needsUnsandbox:(BOOL)needsUnsandbox
{
    if (loaded) {
        [self setIDownloadEnabled:loaded needsUnsandbox:needsUnsandbox];
    }
    
    void (^updateBlock)(void) = ^{
        if (loaded) {
            exec_cmd(JBROOT_PATH("/usr/bin/launchctl"), "load", JBROOT_PATH("/basebin/LaunchDaemons/com.opa334.Dopamine.idownloadd.plist"), NULL);
        }
        else {
            exec_cmd(JBROOT_PATH("/usr/bin/launchctl"), "unload", JBROOT_PATH("/basebin/LaunchDaemons/com.opa334.Dopamine.idownloadd.plist"), NULL);
        }
    };
    
    if (needsUnsandbox) {
        [self runAsRoot:^{
            [self runUnsandboxed:updateBlock];
        }];
    }
    else {
        updateBlock();
    }
    
    if (!loaded) {
        [self setIDownloadEnabled:loaded needsUnsandbox:needsUnsandbox];
    }
}

/*
- (BOOL)isFakelibMounted
{
    struct statfs fsb;
    if (statfs("/usr/lib", &fsb) != 0) return NO;
    return strcmp(fsb.f_mntonname, "/usr/lib") == 0;
}

- (int)setFakelibMounted:(BOOL)mounted
{
    int r = 0;
    if (mounted != [self isFakelibMounted]) {
        const char *arg = mounted ? "mount" : "unmount";
        r = exec_cmd(JBROOT_PATH("/basebin/jbctl"), "internal", "fakelib", arg, NULL);
    }
    return r;
}

- (int)setPrivatePrebootProtected:(BOOL)protected
{
    const char *arg = protected ? "activate" : "deactivate";
    return exec_cmd(JBROOT_PATH("/basebin/jbctl"), "internal", "protection", arg, NULL);
}

- (BOOL)isJailbreakHidden
{
    return ![[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb"];
}

- (void)setJailbreakHidden:(BOOL)hidden
{
    if (hidden && ![self isJailbroken] && geteuid() != 0) {
        [self runTrollStoreAction:@"hide-jailbreak"];
        return;
    }
    
    void (^actionBlock)(void) = ^{
        BOOL alreadyHidden = [self isJailbreakHidden];
        if (hidden != alreadyHidden) {
            if (hidden) {
                if ([self isJailbroken]) {
                    [self unregisterJailbreakApps];
                    [self setPrivatePrebootProtected:NO];
                    [self setFakelibMounted:NO];
                    jbclient_platform_set_systemwide_domain_enabled(false);
                }
                [[NSFileManager defaultManager] removeItemAtPath:@"/var/jb" error:nil];
            }
            else {
                [[NSFileManager defaultManager] createSymbolicLinkAtPath:@"/var/jb" withDestinationPath:JBROOT_PATH(@"/") error:nil];
                if ([self isJailbroken]) {
                    jbclient_platform_set_systemwide_domain_enabled(true);
                    [self setFakelibMounted:YES];
                    [self setPrivatePrebootProtected:YES];
                    [self refreshJailbreakApps];
                }
            }
        }
    };
    
    if ([self isJailbroken]) {
        [self runAsRoot:^{
            [self runUnsandboxed:actionBlock];
        }];
    }
    else {
        actionBlock();
    }
}
*/

- (NSString *)accessibleKernelPath
{
    if ([self isInstalledThroughTrollStore] || getuid() == 0) {
        NSString *kernelcachePath = [[self activePrebootPath] stringByAppendingPathComponent:@"System/Library/Caches/com.apple.kernelcaches/kernelcache"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:kernelcachePath]) {
            return kernelcachePath;
        }
        return @"/System/Library/Caches/com.apple.kernelcaches/kernelcache";
    }
    else {
        NSString *kernelInApp = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"kernelcache"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:kernelInApp]) {
            return kernelInApp;
        }
        
        [[DOUIManager sharedInstance] sendLog:@"Downloading Kernel" debug:NO];
        NSString *kernelcachePath = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/kernelcache"];
        if (![[NSFileManager defaultManager] fileExistsAtPath:kernelcachePath]) {
            if (grab_kernelcache(kernelcachePath) == false) return nil;
        }
        return kernelcachePath;
    }
}

- (NSString *)accessibleSPTMPath
{
    NSArray<NSString *> *localNames = @[@"sptm.img4", @"sptm.im4p"];
    for (NSString *name in localNames) {
        NSString *appPath = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:name];
        if ([[NSFileManager defaultManager] fileExistsAtPath:appPath]) return appPath;

        NSString *documentsPath = [NSHomeDirectory() stringByAppendingPathComponent:[@"Documents" stringByAppendingPathComponent:name]];
        if ([[NSFileManager defaultManager] fileExistsAtPath:documentsPath]) return documentsPath;
    }

    if ([self isInstalledThroughTrollStore] || getuid() == 0) {
        NSString *path = [[self activePrebootPath] stringByAppendingPathComponent:@"usr/standalone/firmware/FUD/Ap,SecurePageTableMonitor.img4"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:path]) return path;
    }
    return nil;
}

- (NSString *)accessibleTXMPath
{
    NSArray<NSString *> *localNames = @[@"txm.img4", @"txm.im4p"];
    for (NSString *name in localNames) {
        NSString *appPath = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:name];
        if ([[NSFileManager defaultManager] fileExistsAtPath:appPath]) return appPath;

        NSString *documentsPath = [NSHomeDirectory() stringByAppendingPathComponent:[@"Documents" stringByAppendingPathComponent:name]];
        if ([[NSFileManager defaultManager] fileExistsAtPath:documentsPath]) return documentsPath;
    }

    if ([self isInstalledThroughTrollStore] || getuid() == 0) {
        NSString *path = [[self activePrebootPath] stringByAppendingPathComponent:@"usr/standalone/firmware/FUD/Ap,TrustedExecutionMonitor.img4"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:path]) return path;
    }
    return nil;
}

- (BOOL)isPACBypassRequired
{
    if (![self isArm64e]) return NO;
    
    if (@available(iOS 15.2, *)) {
        return NO;
    }
    return YES;
}

- (BOOL)isPPLBypassRequired
{
    return [self isArm64e];
}

- (BOOL)isSupported
{
    //cpu_subtype_t cpuFamily = 0;
    //size_t cpuFamilySize = sizeof(cpuFamily);
    //sysctlbyname("hw.cpufamily", &cpuFamily, &cpuFamilySize, NULL, 0);
    //if (cpuFamily == CPUFAMILY_ARM_TYPHOON) return false; // A8X is unsupported for now (due to 4k page size)
    
    DOExploitManager *exploitManager = [DOExploitManager sharedManager];
    if ([exploitManager availableExploitsForType:EXPLOIT_TYPE_KERNEL].count) {
        if (![self isPACBypassRequired] || [exploitManager availableExploitsForType:EXPLOIT_TYPE_PAC].count) {
            if (![self isPPLBypassRequired] || [exploitManager availableExploitsForType:EXPLOIT_TYPE_PPL].count) {
                return true;
            }
        }
    }
    
    return false;
}

- (BOOL)deviceSupportsFaceID
{
    if (![LAContext class]) return NO;

    LAContext *myContext = [[LAContext alloc] init];
    NSError *authError = nil;
    if (![myContext canEvaluatePolicy:LAPolicyDeviceOwnerAuthenticationWithBiometrics error:&authError]) {
        NSLog(@"%@", [authError localizedDescription]);
        return NO;
    }

    return myContext.biometryType == LABiometryTypeFaceID;
}

- (BOOL)deviceSupportsLandscapeBootLogo
{
    struct utsname u;
    uname(&u);
    const char *ipadString = "iPad";

    bool isPad = strncmp(u.machine, ipadString, strlen(ipadString)) == 0;
    return isPad && [self deviceSupportsFaceID];
}

- (NSError *)prepareBootstrap
{
    __block NSError *errOut;
    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    [_bootstrapper prepareBootstrapWithCompletion:^(NSError *error) {
        errOut = error;
        dispatch_semaphore_signal(sema);
    }];
    dispatch_semaphore_wait(sema, DISPATCH_TIME_FOREVER);
    return errOut;
}

- (NSError *)finalizeBootstrap
{
    return [_bootstrapper finalizeBootstrap];
}

- (NSError *)deleteBootstrap
{
    if (![self isJailbroken] && getuid() != 0) {
        int r = [self runTrollStoreAction:@"delete-bootstrap"];
        if (r != 0) {
            return [NSError errorWithDomain:bootstrapErrorDomain
                                       code:BootstrapErrorCodeFailedFinalising
                                   userInfo:@{NSLocalizedDescriptionKey :
                                       [NSString stringWithFormat:@"删除月余环境失败，辅助进程退出码：%d", r]}];
        }
        return nil;
    }
    else if ([self isJailbroken]) {
        __block NSError *error;
        [self runAsRoot:^{
            [self runUnsandboxed:^{
                error = [self->_bootstrapper deleteBootstrap];
            }];
        }];
        return error;
    }
    else {
        // Let's hope for the best
        return [_bootstrapper deleteBootstrap];
    }
}

- (NSArray<NSDictionary<NSString *,NSString *> *> *)trollStoreInstalledApplicationsWithError:(NSError **)error
{
    NSMutableArray *applications = [NSMutableArray array];
    int result = [self spawnJbctlAsRootWithArgs:@[@"trollstore_apps", @"list"] outputHandler:^(NSString *line) {
        NSArray<NSString *> *parts = [line componentsSeparatedByString:@"\t"];
        if (parts.count != 4 || ![parts[0] isEqualToString:@"APP"]) return;
        [applications addObject:@{
            @"bundleIdentifier" : parts[1],
            @"name" : parts[2],
            @"marker" : parts[3],
        }];
    }];
    if (result != 0 && error) {
        *error = [NSError errorWithDomain:bootstrapErrorDomain
                                     code:result
                                 userInfo:@{NSLocalizedDescriptionKey :
                                     [NSString stringWithFormat:@"检测巨魔安装记录失败，辅助进程退出码：%d", result]}];
    }
    return result == 0 ? applications : nil;
}

- (NSError *)uninstallTrollStoreApplications:(NSArray<NSString *> *)bundleIdentifiers
{
    if (bundleIdentifiers.count == 0) return nil;
    NSMutableArray *arguments = [NSMutableArray arrayWithObjects:@"trollstore_apps", @"uninstall", nil];
    [arguments addObjectsFromArray:bundleIdentifiers];
    int result = [self spawnJbctlAsRootWithArgs:arguments];
    if (result == 0) return nil;
    return [NSError errorWithDomain:bootstrapErrorDomain
                               code:result
                           userInfo:@{NSLocalizedDescriptionKey :
                               [NSString stringWithFormat:@"移除巨魔安装记录失败，辅助进程退出码：%d。未完成的应用不会被直接删除。", result]}];
}

- (NSError *)reinstallPackageManagers
{
    __block NSError *error;
    [self runAsRoot:^{
        [self runUnsandboxed:^{
            error = [self->_bootstrapper installPackageManagers];
        }];
    }];
    return error;
}

- (NSError *)updateBootLogo
{
    const char *bootLogoPath = JBROOT_PATH("/basebin/bootlogo.jp2");
    if ([[DOPreferenceManager sharedManager] boolPreferenceValueForKey:@"bootlogoEnabled" fallback:YES]) {
        UIImage *bootLogoImage;

        if ([[DOPreferenceManager sharedManager] boolPreferenceValueForKey:@"customBootlogoEnabled" fallback:NO]) {
            bootLogoImage = [UIImage imageWithContentsOfFile:[DOUIManager sharedInstance].bootlogoPath];
        }

        if (!bootLogoImage) {
            bootLogoImage = [[DOUIManager sharedInstance] renderBootLogo];
        }

        [self runAsRoot:^{
            [self runUnsandboxed:^{
                unlink(bootLogoPath);
                [[bootLogoImage jp2DataWithCompressionQuality:0.9] writeToFile:[NSString stringWithUTF8String:bootLogoPath] atomically:NO];
            }];
        }];

        return nil;
    }
    else {
        [self runAsRoot:^{
            [self runUnsandboxed:^{
                unlink(bootLogoPath);
            }];
        }];
        return nil;
    }
}

- (NSString *)fakeMountConfigurationPath
{
    return JBROOT_PATH(@"/mnt/newFakePath.plist");
}

- (NSArray<NSString *> *)fakeMountPaths
{
    __block NSArray<NSString *> *paths = @[];
    [self runAsRoot:^{
        [self runUnsandboxed:^{
            NSDictionary *configuration = [NSDictionary dictionaryWithContentsOfFile:self.fakeMountConfigurationPath];
            if ([configuration[@"path"] isKindOfClass:[NSArray class]]) paths = configuration[@"path"];
        }];
    }];
    return paths;
}

- (BOOL)saveFakeMountPaths:(NSArray<NSString *> *)paths
{
    __block BOOL success = NO;
    [self runAsRoot:^{
        [self runUnsandboxed:^{
            NSString *configurationPath = self.fakeMountConfigurationPath;
            [[NSFileManager defaultManager] createDirectoryAtPath:[configurationPath stringByDeletingLastPathComponent]
                                      withIntermediateDirectories:YES attributes:nil error:nil];
            success = [@{@"path" : paths ?: @[]} writeToFile:configurationPath atomically:YES];
        }];
    }];
    return success;
}

- (int)setFakeMountPath:(NSString *)path mounted:(BOOL)mounted deleteMirror:(BOOL)deleteMirror
{
    NSString *standardPath = path.stringByStandardizingPath;
    if (![path isEqualToString:standardPath] || ![path hasPrefix:@"/"] || [path isEqualToString:@"/"]) return EINVAL;

    __block int result = EPERM;
    [self runAsRoot:^{
        [self runUnsandboxed:^{
            result = exec_cmd(JBROOT_PATH("/basebin/jbctl"), "internal", mounted ? "mount" : "unmount",
                              standardPath.fileSystemRepresentation, NULL);
            if (!mounted && deleteMirror && result == 0) {
                NSString *mirrorPath = [JBROOT_PATH(@"/mnt") stringByAppendingString:standardPath];
                [[NSFileManager defaultManager] removeItemAtPath:mirrorPath error:nil];
            }
        }];
    }];
    return result;
}

- (void)restoreFakeMounts
{
    for (NSString *path in self.fakeMountPaths) {
        int result = [self setFakeMountPath:path mounted:YES deleteMirror:NO];
        if (result != 0) NSLog(@"Failed restoring fake mount %@: %d", path, result);
    }
}

@end
