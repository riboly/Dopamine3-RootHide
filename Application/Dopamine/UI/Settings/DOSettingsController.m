//
//  DOSettingsController.m
//  Dopamine
//
//  Created by tomt000 on 08/01/2024.
//

#import "DOSettingsController.h"
#import <objc/runtime.h>
#import <Photos/Photos.h>
#import <libjailbreak/util.h>
#import <errno.h>
#import <string.h>
#import <sys/stat.h>
#import <sys/wait.h>
#import <spawn.h>
#import <unistd.h>
#import <fcntl.h>
#import "DOUIManager.h"
#import "DOPkgManagerPickerViewController.h"
#import "DOHeaderCell.h"
#import "DOEnvironmentManager.h"
#import "DOExploitManager.h"
#import "DOPSListItemsController.h"
#import "DOPSExploitListItemsController.h"
#import "DOThemeManager.h"
#import "DOSceneDelegate.h"
#import "DOPSJetsamListItemsController.h"
#import "DOButtonCell.h"
#import "DOLogCrashViewController.h"

extern char **environ;

@interface DOSettingsController ()

@end

static NSString *RHDiagnosticPath(NSString *root, NSString *relativePath)
{
    return [root stringByAppendingPathComponent:relativePath];
}

static void RHAppendDiagnosticStat(NSMutableString *output, NSString *root, NSString *relativePath)
{
    NSString *path = RHDiagnosticPath(root, relativePath);
    struct stat st = {0};
    if (lstat(path.fileSystemRepresentation, &st) != 0) {
        [output appendFormat:@"PATH %@\n  missing errno=%d (%s)\n", relativePath, errno, strerror(errno)];
        return;
    }

    [output appendFormat:@"PATH %@\n  mode=%o uid=%d gid=%d size=%lld\n",
        relativePath, st.st_mode & 07777, st.st_uid, st.st_gid, (long long)st.st_size];

    if (S_ISLNK(st.st_mode)) {
        char link[PATH_MAX + 1] = {0};
        ssize_t length = readlink(path.fileSystemRepresentation, link, PATH_MAX);
        if (length > 0) {
            link[length] = '\0';
            [output appendFormat:@"  symlink=%s\n", link];
        }
    }

    if (!S_ISDIR(st.st_mode)) return;

    NSArray<NSString *> *children = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:path error:nil];
    children = [children sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *child in children) {
        struct stat childStat = {0};
        NSString *childPath = [path stringByAppendingPathComponent:child];
        if (lstat(childPath.fileSystemRepresentation, &childStat) == 0) {
            [output appendFormat:@"  %@ mode=%o uid=%d gid=%d size=%lld%@\n",
                child, childStat.st_mode & 07777, childStat.st_uid, childStat.st_gid,
                (long long)childStat.st_size, S_ISDIR(childStat.st_mode) ? @"/" : @""];
        } else {
            [output appendFormat:@"  %@ stat_errno=%d (%s)\n", child, errno, strerror(errno)];
        }
    }
}

static void RHAppendDiagnosticText(NSMutableString *output, NSString *root, NSString *relativePath, NSUInteger maxLength)
{
    NSString *path = RHDiagnosticPath(root, relativePath);
    NSError *error = nil;
    NSString *contents = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&error];
    if (!contents) {
        [output appendFormat:@"TEXT %@\n  unavailable=%@\n", relativePath, error.localizedDescription ?: @"unknown error"];
        return;
    }
    if (contents.length > maxLength) {
        contents = [contents substringToIndex:maxLength];
        [output appendFormat:@"TEXT %@ (truncated)\n%@\n", relativePath, contents];
    } else {
        [output appendFormat:@"TEXT %@\n%@\n", relativePath, contents];
    }
}

static NSString *RHBuildPackageDiagnostic(void)
{
    NSMutableString *output = [NSMutableString stringWithString:@"Dopamine RootHide package diagnostic\n"];
    [output appendFormat:@"generated=%@\nuid=%d euid=%d gid=%d\n",
        [NSDate date], getuid(), geteuid(), getgid()];

    NSString *root = gSystemInfo.jailbreakInfo.rootPath ?
        [NSString stringWithUTF8String:gSystemInfo.jailbreakInfo.rootPath] : nil;
    [output appendFormat:@"jbroot=%@\n\n", root ?: @"<nil>"];
    if (!root.length) return output;

    NSArray<NSString *> *pathSnapshots = @[
        @"/var/jb",
        @"/etc/apt/sources.list.d",
        @"/etc/apt/sileo.list.d",
        @"/var/lib/apt",
        @"/var/lib/apt/lists",
        @"/var/lib/apt/sileolists",
        @"/var/lib/dpkg/status",
        @"/usr/sbin/sshd",
        @"/usr/sbin/frida-server",
        @"/Library/LaunchDaemons/re.frida.server.plist",
        @"/var/mobile/Library/Logs/Sileo.log",
        @"/var/mobile/Library/Logs/SileoStore.log",
    ];
    for (NSString *relativePath in pathSnapshots) {
        RHAppendDiagnosticStat(output, root, relativePath);
    }

    NSArray<NSString *> *textSnapshots = @[
        @"/etc/apt/sources.list.d/default.sources",
        @"/etc/apt/sources.list.d/procursus.sources",
        @"/etc/apt/sources.list.d/sileo.sources",
        @"/var/mobile/Library/Application Support/xyz.willy.Zebra/sources.list",
    ];
    for (NSString *relativePath in textSnapshots) {
        RHAppendDiagnosticText(output, root, relativePath, 128 * 1024);
    }

    NSString *statusPath = RHDiagnosticPath(root, @"/var/lib/dpkg/status");
    NSString *status = [NSString stringWithContentsOfFile:statusPath encoding:NSUTF8StringEncoding error:nil];
    if (status.length) {
        [output appendString:@"PACKAGES (selected status records)\n"];
        for (NSString *record in [status componentsSeparatedByString:@"\n\n"]) {
            if ([record containsString:@"Package: org.coolstar.sileo"] ||
                [record containsString:@"Package: apt"] ||
                [record containsString:@"Package: dpkg"] ||
                [record containsString:@"Package: libroot"] ||
                [record containsString:@"Package: roothide"] ||
                [record containsString:@"Package: openssh-server"] ||
                [record containsString:@"Package: re.frida.server"]) {
                [output appendFormat:@"%@\n\n", record];
            }
        }
    }
    return output;
}

static void RHSendInstallLog(NSString *line)
{
    NSString *trimmed = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmed.length) {
        [[DOUIManager sharedInstance] sendLog:trimmed debug:NO];
    }
}

static int RHRunInstallCommand(NSArray<NSString *> *arguments)
{
    if (arguments.count == 0) return EINVAL;

    int outputPipe[2] = {-1, -1};
    if (pipe(outputPipe) != 0) return errno;

    char **argv = calloc(arguments.count + 1, sizeof(char *));
    for (NSUInteger i = 0; i < arguments.count; i++) {
        argv[i] = strdup(arguments[i].fileSystemRepresentation);
    }

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, outputPipe[1], STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, outputPipe[1], STDERR_FILENO);
    posix_spawn_file_actions_addclose(&actions, outputPipe[0]);

    pid_t pid = 0;
    int spawnResult = posix_spawn(&pid, argv[0], &actions, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&actions);
    close(outputPipe[1]);
    for (NSUInteger i = 0; i < arguments.count; i++) free(argv[i]);
    free(argv);

    if (spawnResult != 0) {
        close(outputPipe[0]);
        return spawnResult;
    }

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
            NSString *line = [pending substringToIndex:newline.location];
            [pending deleteCharactersInRange:NSMakeRange(0, newline.location + 1)];
            RHSendInstallLog(line);
        }
    }
    close(outputPipe[0]);
    if (pending.length) RHSendInstallLog(pending);

    int waitStatus = 0;
    if (waitpid(pid, &waitStatus, 0) < 0) return errno;
    if (WIFEXITED(waitStatus)) return WEXITSTATUS(waitStatus);
    if (WIFSIGNALED(waitStatus)) return 128 + WTERMSIG(waitStatus);
    return ECHILD;
}

static BOOL RHStatusContainsInstalledPackage(NSString *packageName, NSString *architecture)
{
    NSString *statusPath = JBROOT_PATH(@"/var/lib/dpkg/status");
    NSString *status = [NSString stringWithContentsOfFile:statusPath encoding:NSUTF8StringEncoding error:nil];
    if (!status.length) return NO;
    for (NSString *record in [status componentsSeparatedByString:@"\n\n"]) {
        if ([record containsString:[NSString stringWithFormat:@"Package: %@", packageName]] &&
            [record containsString:@"Status: install ok installed"] &&
            (!architecture.length || [record containsString:[NSString stringWithFormat:@"Architecture: %@", architecture]])) {
            return YES;
        }
    }
    return NO;
}

static void RHInstallOpenSSH(void)
{
    NSString *apt = JBROOT_PATH(@"/usr/bin/apt-get");
    if (!apt.length || ![[NSFileManager defaultManager] isExecutableFileAtPath:apt]) {
        RHSendInstallLog(@"RESULT: FAILED (RootHide apt-get 不存在)");
        return;
    }

    RHSendInstallLog(@"使用 RootHide arm64e Procursus 源更新软件包索引");
    int result = RHRunInstallCommand(@[apt, @"update"]);
    if (result != 0) {
        RHSendInstallLog([NSString stringWithFormat:@"apt-get update 失败，退出码 %d", result]);
        RHSendInstallLog(@"RESULT: FAILED");
        return;
    }

    RHSendInstallLog(@"安装 openssh-server (RootHide/iphoneos-arm64e)");
    result = RHRunInstallCommand(@[apt, @"install", @"-y", @"openssh-server"]);
    BOOL packageInstalled = RHStatusContainsInstalledPackage(@"openssh-server", @"iphoneos-arm64e");
    BOOL daemonPresent = [[NSFileManager defaultManager] fileExistsAtPath:JBROOT_PATH(@"/usr/sbin/sshd")] ||
        [[NSFileManager defaultManager] fileExistsAtPath:JBROOT_PATH(@"/usr/bin/sshd")];
    if (result == 0 && packageInstalled && daemonPresent) {
        RHSendInstallLog(@"检测通过：openssh-server 与 sshd 均已安装");
        RHSendInstallLog(@"RESULT: SUCCESS");
    } else {
        RHSendInstallLog([NSString stringWithFormat:@"检测失败：exit=%d package=%d sshd=%d", result, packageInstalled, daemonPresent]);
        RHSendInstallLog(@"RESULT: FAILED");
    }
}

static void RHInstallFridaFromURL(NSURL *url)
{
    RHSendInstallLog([NSString stringWithFormat:@"下载 RootHide Frida arm64e 包：%@", url.absoluteString]);
    NSURLSessionDownloadTask *task = [[NSURLSession sharedSession] downloadTaskWithURL:url completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
        if (error || !location) {
            RHSendInstallLog([NSString stringWithFormat:@"Frida 下载失败：%@", error.localizedDescription ?: @"未知错误"]);
            RHSendInstallLog(@"RESULT: FAILED");
            return;
        }
        if ([response isKindOfClass:[NSHTTPURLResponse class]] && [(NSHTTPURLResponse *)response statusCode] >= 400) {
            RHSendInstallLog([NSString stringWithFormat:@"Frida 下载返回 HTTP %ld", (long)[(NSHTTPURLResponse *)response statusCode]]);
            RHSendInstallLog(@"RESULT: FAILED");
            return;
        }

        DOEnvironmentManager *environmentManager = [DOEnvironmentManager sharedManager];
        __block int installResult = EIO;
        __block BOOL copied = NO;
        NSString *destination = JBROOT_PATH([NSString stringWithFormat:@"/tmp/frida-roothide-%@.deb", NSUUID.UUID.UUIDString]);
        [environmentManager runAsRoot:^{
            [environmentManager runUnsandboxed:^{
                NSString *tmpDirectory = JBROOT_PATH(@"/tmp");
                [[NSFileManager defaultManager] createDirectoryAtPath:tmpDirectory withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @0755} error:nil];
                NSError *copyError = nil;
                copied = [[NSFileManager defaultManager] copyItemAtPath:location.path toPath:destination error:&copyError];
                if (!copied) {
                    RHSendInstallLog([NSString stringWithFormat:@"复制 Frida 包失败：%@", copyError.localizedDescription ?: @"未知错误"]);
                } else {
                    NSDictionary *fileAttributes = [[NSFileManager defaultManager] attributesOfItemAtPath:destination error:nil];
                    unsigned long long fileSize = [[fileAttributes objectForKey:NSFileSize] unsignedLongLongValue];
                    RHSendInstallLog([NSString stringWithFormat:@"已下载 %.1f MB，开始 dpkg 安装", (double)fileSize / (1024.0 * 1024.0)]);
                    installResult = RHRunInstallCommand(@[JBROOT_PATH(@"/usr/bin/dpkg"), @"-i", destination]);
                }
                [[NSFileManager defaultManager] removeItemAtPath:destination error:nil];
            }];
        }];

        __block BOOL packageInstalled = NO;
        __block BOOL serverPresent = NO;
        __block BOOL launchDaemonPresent = NO;
        [environmentManager runAsRoot:^{
            [environmentManager runUnsandboxed:^{
                packageInstalled = RHStatusContainsInstalledPackage(@"re.frida.server", @"iphoneos-arm64e");
                serverPresent = [[NSFileManager defaultManager] fileExistsAtPath:JBROOT_PATH(@"/usr/sbin/frida-server")];
                launchDaemonPresent = [[NSFileManager defaultManager] fileExistsAtPath:JBROOT_PATH(@"/Library/LaunchDaemons/re.frida.server.plist")];
            }];
        }];
        if (copied && installResult == 0 && packageInstalled && serverPresent && launchDaemonPresent) {
            RHSendInstallLog(@"检测通过：re.frida.server、frida-server 与 LaunchDaemon 均已安装");
            RHSendInstallLog(@"RESULT: SUCCESS");
        } else {
            RHSendInstallLog([NSString stringWithFormat:@"检测失败：copied=%d exit=%d package=%d server=%d daemon=%d", copied, installResult, packageInstalled, serverPresent, launchDaemonPresent]);
            RHSendInstallLog(@"RESULT: FAILED");
        }
    }];
    [task resume];
}

@implementation DOSettingsController

- (void)viewDidLoad
{
    _lastKnownTheme = [[DOThemeManager sharedInstance] enabledTheme].key;
    [super viewDidLoad];
}

- (void)viewWillAppear:(BOOL)arg1
{
    [super viewWillAppear:arg1];
    if (_lastKnownTheme != [[DOThemeManager sharedInstance] enabledTheme].key)
    {
        [DOSceneDelegate relaunch];
        NSString *icon = [[DOThemeManager sharedInstance] enabledTheme].icon;
        [[UIApplication sharedApplication] setAlternateIconName:icon completionHandler:^(NSError * _Nullable error) {
            if (error)
                NSLog(@"Error changing app icon: %@", error);
        }];

        if ([DOEnvironmentManager sharedManager].isJailbroken) {
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                [[DOEnvironmentManager sharedManager] updateBootLogo];
            });
        }
    }
}

- (NSArray *)availableKernelExploitIdentifiers
{
    NSMutableArray *identifiers = [NSMutableArray new];
    for (DOExploit *exploit in _availableKernelExploits) {
        [identifiers addObject:exploit.identifier];
    }
    return identifiers;
}

- (NSArray *)availableKernelExploitNames
{
    NSMutableArray *names = [NSMutableArray new];
    for (DOExploit *exploit in _availableKernelExploits) {
        [names addObject:exploit.name];
    }
    return names;
}

- (NSArray *)availablePACBypassIdentifiers
{
    NSMutableArray *identifiers = [NSMutableArray new];
    if (![DOEnvironmentManager sharedManager].isPACBypassRequired) {
        [identifiers addObject:@"none"];
    }
    for (DOExploit *exploit in _availablePACBypasses) {
        [identifiers addObject:exploit.identifier];
    }
    return identifiers;
}

- (NSArray *)availablePACBypassNames
{
    NSMutableArray *names = [NSMutableArray new];
    if (![DOEnvironmentManager sharedManager].isPACBypassRequired) {
        [names addObject:DOLocalizedString(@"None")];
    }
    for (DOExploit *exploit in _availablePACBypasses) {
        [names addObject:exploit.name];
    }
    return names;
}

- (NSArray *)availablePPLBypassIdentifiers
{
    NSMutableArray *identifiers = [NSMutableArray new];
    for (DOExploit *exploit in _availablePPLBypasses) {
        [identifiers addObject:exploit.identifier];
    }
    return identifiers;
}

- (NSArray *)availablePPLBypassNames
{
    NSMutableArray *names = [NSMutableArray new];
    for (DOExploit *exploit in _availablePPLBypasses) {
        [names addObject:exploit.name];
    }
    return names;
}

- (NSArray *)themeIdentifiers
{
    return [[DOThemeManager sharedInstance] getAvailableThemeKeys];
}

- (NSArray *)themeNames
{
    return [[DOThemeManager sharedInstance] getAvailableThemeNames];
}

- (NSArray *)jetsamOptionNumbers
{
    return @[
    @2,
    @3,
    @4,
    @5,
    @6,
    @7,
    @8,
    ];
}

- (NSArray *)jetsamOptionTitles
{
    return @[
        @"1x",
        @"1.5x",
        @"2x",
        @"2.5x",
        [NSString stringWithFormat:@"3x (%@)", DOLocalizedString(@"Recommended")],
        @"3.5x",
        @"4x",
    ];
}

- (id)specifiers
{
    if(_specifiers == nil) {
        NSMutableArray *specifiers = [NSMutableArray new];
        DOEnvironmentManager *envManager = [DOEnvironmentManager sharedManager];
        DOExploitManager *exploitManager = [DOExploitManager sharedManager];

        NSNumber *buttonHeight = @(44);
        
        SEL defGetter = @selector(readPreferenceValue:);
        SEL defSetter = @selector(setPreferenceValue:specifier:);
        
        NSSortDescriptor *prioritySortDescriptor = [NSSortDescriptor sortDescriptorWithKey:@"priority" ascending:NO];
        
        _availableKernelExploits = [[exploitManager availableExploitsForType:EXPLOIT_TYPE_KERNEL] sortedArrayUsingDescriptors:@[prioritySortDescriptor]];
        if (envManager.isArm64e) {
            _availablePACBypasses = [[exploitManager availableExploitsForType:EXPLOIT_TYPE_PAC] sortedArrayUsingDescriptors:@[prioritySortDescriptor]];
            _availablePPLBypasses = [[exploitManager availableExploitsForType:EXPLOIT_TYPE_PPL] sortedArrayUsingDescriptors:@[prioritySortDescriptor]];
        }
        
        PSSpecifier *headerSpecifier = [PSSpecifier emptyGroupSpecifier];
        [headerSpecifier setProperty:@"DOHeaderCell" forKey:@"headerCellClass"];
        [headerSpecifier setProperty:[NSString stringWithFormat:@"Settings"] forKey:@"title"];
        [specifiers addObject:headerSpecifier];
        
        if (envManager.isSupported) {
            if (!envManager.isJailbroken) {
                PSSpecifier *exploitGroupSpecifier = [PSSpecifier emptyGroupSpecifier];
                exploitGroupSpecifier.name = DOLocalizedString(@"Section_Exploits");
                [specifiers addObject:exploitGroupSpecifier];
                
                PSSpecifier *kernelExploitSpecifier = [PSSpecifier preferenceSpecifierNamed:DOLocalizedString(@"Kernel Exploit") target:self set:defSetter get:defGetter detail:nil cell:PSLinkListCell edit:nil];
                [kernelExploitSpecifier setProperty:@YES forKey:@"enabled"];
                [kernelExploitSpecifier setProperty:exploitManager.preferredKernelExploit.identifier forKey:@"default"];
                kernelExploitSpecifier.detailControllerClass = [DOPSExploitListItemsController class];
                [kernelExploitSpecifier setProperty:@"availableKernelExploitIdentifiers" forKey:@"valuesDataSource"];
                [kernelExploitSpecifier setProperty:@"availableKernelExploitNames" forKey:@"titlesDataSource"];
                [kernelExploitSpecifier setProperty:@"selectedKernelExploit" forKey:@"key"];
                [kernelExploitSpecifier setProperty:(_availableKernelExploits.firstObject.identifier ?: @"none") forKey:@"recommendedExploitIdentifier"];
                [specifiers addObject:kernelExploitSpecifier];
                
                if (envManager.isArm64e) {
                    PSSpecifier *pacBypassSpecifier = [PSSpecifier preferenceSpecifierNamed:DOLocalizedString(@"PAC Bypass") target:self set:defSetter get:defGetter detail:nil cell:PSLinkListCell edit:nil];
                    [pacBypassSpecifier setProperty:@YES forKey:@"enabled"];
                    DOExploit *preferredPACBypass = exploitManager.preferredPACBypass;
                    if (!preferredPACBypass) {
                        [pacBypassSpecifier setProperty:@"none" forKey:@"default"];
                    }
                    else {
                        [pacBypassSpecifier setProperty:preferredPACBypass.identifier forKey:@"default"];
                    }
                    pacBypassSpecifier.detailControllerClass = [DOPSExploitListItemsController class];
                    [pacBypassSpecifier setProperty:@"availablePACBypassIdentifiers" forKey:@"valuesDataSource"];
                    [pacBypassSpecifier setProperty:@"availablePACBypassNames" forKey:@"titlesDataSource"];
                    [pacBypassSpecifier setProperty:@"selectedPACBypass" forKey:@"key"];
                    [pacBypassSpecifier setProperty:([envManager isPACBypassRequired] ? _availablePACBypasses.firstObject.identifier : @"none") forKey:@"recommendedExploitIdentifier"];
                    [specifiers addObject:pacBypassSpecifier];
                    
                    PSSpecifier *pplBypassSpecifier = [PSSpecifier preferenceSpecifierNamed:DOLocalizedString(@"PPL Bypass") target:self set:defSetter get:defGetter detail:nil cell:PSLinkListCell edit:nil];
                    [pplBypassSpecifier setProperty:@YES forKey:@"enabled"];
                    [pplBypassSpecifier setProperty:exploitManager.preferredPPLBypass.identifier forKey:@"default"];
                    pplBypassSpecifier.detailControllerClass = [DOPSExploitListItemsController class];
                    [pplBypassSpecifier setProperty:@"availablePPLBypassIdentifiers" forKey:@"valuesDataSource"];
                    [pplBypassSpecifier setProperty:@"availablePPLBypassNames" forKey:@"titlesDataSource"];
                    [pplBypassSpecifier setProperty:@"selectedPPLBypass" forKey:@"key"];
                    [pplBypassSpecifier setProperty:(_availablePPLBypasses.firstObject.identifier ?: @"none") forKey:@"recommendedExploitIdentifier"];
                    [specifiers addObject:pplBypassSpecifier];
                }
            }
            
            PSSpecifier *settingsGroupSpecifier = [PSSpecifier emptyGroupSpecifier];
            settingsGroupSpecifier.name = DOLocalizedString(@"Section_Jailbreak_Settings");
            [specifiers addObject:settingsGroupSpecifier];
            
            PSSpecifier *tweakInjectionSpecifier = [PSSpecifier preferenceSpecifierNamed:DOLocalizedString(@"Settings_Tweak_Injection") target:self set:@selector(setTweakInjectionEnabled:specifier:) get:@selector(readTweakInjectionEnabled:) detail:nil cell:PSSwitchCell edit:nil];
            [tweakInjectionSpecifier setProperty:@YES forKey:@"enabled"];
            [tweakInjectionSpecifier setProperty:@"tweakInjectionEnabled" forKey:@"key"];
            [tweakInjectionSpecifier setProperty:@YES forKey:@"default"];
            [specifiers addObject:tweakInjectionSpecifier];
            
            if (!envManager.isJailbroken) {
                PSSpecifier *verboseLogSpecifier = [PSSpecifier preferenceSpecifierNamed:DOLocalizedString(@"Settings_Verbose_Logs") target:self set:defSetter get:defGetter detail:nil cell:PSSwitchCell edit:nil];
                [verboseLogSpecifier setProperty:@YES forKey:@"enabled"];
                [verboseLogSpecifier setProperty:@"verboseLogsEnabled" forKey:@"key"];
                [verboseLogSpecifier setProperty:@NO forKey:@"default"];
                [specifiers addObject:verboseLogSpecifier];
            }
            
            PSSpecifier *idownloadSpecifier = [PSSpecifier preferenceSpecifierNamed:DOLocalizedString(@"Settings_iDownload") target:self set:@selector(setIDownloadEnabled:specifier:) get:@selector(readIDownloadEnabled:) detail:nil cell:PSSwitchCell edit:nil];
            [idownloadSpecifier setProperty:@YES forKey:@"enabled"];
            [idownloadSpecifier setProperty:@"idownloadEnabled" forKey:@"key"];
            [idownloadSpecifier setProperty:@NO forKey:@"default"];
            [specifiers addObject:idownloadSpecifier];
            
            PSSpecifier *appJitSpecifier = [PSSpecifier preferenceSpecifierNamed:DOLocalizedString(@"Settings_Apps_JIT") target:self set:@selector(setAppJITEnabled:specifier:) get:@selector(readAppJITEnabled:) detail:nil cell:PSSwitchCell edit:nil];
            [appJitSpecifier setProperty:@YES forKey:@"enabled"];
            [appJitSpecifier setProperty:@"appJITEnabled" forKey:@"key"];
            [appJitSpecifier setProperty:@YES forKey:@"default"];
            [specifiers addObject:appJitSpecifier];
            
            
            /**************************** roothide specfic *********************************/
            NSString* namedesc = DOLocalizedString(@"Enable dyld patch");
            if(envManager.isArm64e && NSProcessInfo.processInfo.operatingSystemVersion.majorVersion==15) {
                namedesc = DOLocalizedString(@"Dyld Patch(Spinlock Fix)");
            }
            PSSpecifier *dyldPatchSpecifier = [PSSpecifier preferenceSpecifierNamed:namedesc target:self set:@selector(setDyldPatchEnabled:specifier:) get:@selector(readDyldPatchEnabled:) detail:nil cell:PSSwitchCell edit:nil];
            [dyldPatchSpecifier setProperty:@YES forKey:@"enabled"];
            [dyldPatchSpecifier setProperty:@"dyldPatchEnabled" forKey:@"key"];
            [dyldPatchSpecifier setProperty:@NO forKey:@"default"];
            [specifiers addObject:dyldPatchSpecifier];
            /**************************** roothide specfic *********************************/
            
            
            PSSpecifier *jetsamSpecifier = [PSSpecifier preferenceSpecifierNamed:DOLocalizedString(@"Settings_Jetsam_Multiplier") target:self set:@selector(setJetsamMultiplier:specifier:) get:@selector(readJetsamMultiplier:) detail:nil cell:PSLinkListCell edit:nil];
            [jetsamSpecifier setProperty:@YES forKey:@"enabled"];
            [jetsamSpecifier setProperty:@"jetsamMultiplier" forKey:@"key"];
            [jetsamSpecifier setProperty:@6 forKey:@"default"];
            jetsamSpecifier.detailControllerClass = [DOPSJetsamListItemsController class];
            [jetsamSpecifier setProperty:@"jetsamOptionNumbers" forKey:@"valuesDataSource"];
            [jetsamSpecifier setProperty:@"jetsamOptionTitles" forKey:@"titlesDataSource"];
            [specifiers addObject:jetsamSpecifier];
            
            if (!envManager.isJailbroken && !envManager.isInstalledThroughTrollStore) {
                PSSpecifier *removeJailbreakSwitchSpecifier = [PSSpecifier preferenceSpecifierNamed:DOLocalizedString(@"Button_Remove_Jailbreak") target:self set:@selector(setRemoveJailbreakEnabled:specifier:) get:defGetter detail:nil cell:PSSwitchCell edit:nil];
                [removeJailbreakSwitchSpecifier setProperty:@YES forKey:@"enabled"];
                [removeJailbreakSwitchSpecifier setProperty:@"removeJailbreakEnabled" forKey:@"key"];
                [specifiers addObject:removeJailbreakSwitchSpecifier];
            }
            
            if (envManager.isJailbroken || (envManager.isInstalledThroughTrollStore && envManager.isBootstrapped)) {
                PSSpecifier *actionsGroupSpecifier = [PSSpecifier emptyGroupSpecifier];
                actionsGroupSpecifier.name = DOLocalizedString(@"Section_Actions");
                [specifiers addObject:actionsGroupSpecifier];
                
                if (envManager.isJailbroken) {
                    PSSpecifier *refreshAppsSpecifier = [PSSpecifier preferenceSpecifierNamed:@"" target:self set:defSetter get:defGetter detail:nil cell:PSStaticTextCell edit:nil];
                    [refreshAppsSpecifier setProperty:@"Button_Refresh_Jailbreak_Apps" forKey:@"title"];
                    [refreshAppsSpecifier setProperty:[DOButtonCell class] forKey:@"cellClass"];
                    [refreshAppsSpecifier setProperty:buttonHeight forKey:@"height"];
                    [refreshAppsSpecifier setProperty:@"arrow.triangle.2.circlepath" forKey:@"image"];
                    [refreshAppsSpecifier setProperty:@"refreshJailbreakAppsPressed" forKey:@"action"];
                    [specifiers addObject:refreshAppsSpecifier];
                    
                    PSSpecifier *changeMobilePasswordSpecifier = [PSSpecifier preferenceSpecifierNamed:@"" target:self set:defSetter get:defGetter detail:nil cell:PSStaticTextCell edit:nil];
                    [changeMobilePasswordSpecifier setProperty:@"Button_Change_Mobile_Password" forKey:@"title"];
                    [changeMobilePasswordSpecifier setProperty:[DOButtonCell class] forKey:@"cellClass"];
                    [changeMobilePasswordSpecifier setProperty:buttonHeight forKey:@"height"];
                    [changeMobilePasswordSpecifier setProperty:@"key" forKey:@"image"];
                    [changeMobilePasswordSpecifier setProperty:@"changeMobilePasswordWithAuthenticationPressed" forKey:@"action"];
                    [specifiers addObject:changeMobilePasswordSpecifier];
                    
                    PSSpecifier *reinstallPackageManagersSpecifier = [PSSpecifier preferenceSpecifierNamed:@"" target:self set:defSetter get:defGetter detail:nil cell:PSStaticTextCell edit:nil];
                    [reinstallPackageManagersSpecifier setProperty:@"Button_Reinstall_Package_Managers" forKey:@"title"];
                    [reinstallPackageManagersSpecifier setProperty:[DOButtonCell class] forKey:@"cellClass"];
                    [reinstallPackageManagersSpecifier setProperty:buttonHeight forKey:@"height"];
                    if (@available(iOS 16.0, *))
                        [reinstallPackageManagersSpecifier setProperty:@"shippingbox.and.arrow.backward" forKey:@"image"];
                    else
                        [reinstallPackageManagersSpecifier setProperty:@"shippingbox" forKey:@"image"];
                    [reinstallPackageManagersSpecifier setProperty:@"reinstallPackageManagersPressed" forKey:@"action"];
                    [specifiers addObject:reinstallPackageManagersSpecifier];

                    PSSpecifier *diagnosticSpecifier = [PSSpecifier preferenceSpecifierNamed:@"" target:self set:defSetter get:defGetter detail:nil cell:PSStaticTextCell edit:nil];
                    [diagnosticSpecifier setProperty:@"Button_Export_RootHide_Diagnostics" forKey:@"title"];
                    [diagnosticSpecifier setProperty:[DOButtonCell class] forKey:@"cellClass"];
                    [diagnosticSpecifier setProperty:buttonHeight forKey:@"height"];
                    [diagnosticSpecifier setProperty:@"doc.text.magnifyingglass" forKey:@"image"];
                    [diagnosticSpecifier setProperty:@"exportRootHidePackageDiagnosticsPressed" forKey:@"action"];
                    [specifiers addObject:diagnosticSpecifier];

                    PSSpecifier *fridaSpecifier = [PSSpecifier preferenceSpecifierNamed:@"" target:self set:defSetter get:defGetter detail:nil cell:PSStaticTextCell edit:nil];
                    [fridaSpecifier setProperty:@"Button_Install_Frida" forKey:@"title"];
                    [fridaSpecifier setProperty:[DOButtonCell class] forKey:@"cellClass"];
                    [fridaSpecifier setProperty:buttonHeight forKey:@"height"];
                    [fridaSpecifier setProperty:@"bolt.horizontal.circle" forKey:@"image"];
                    [fridaSpecifier setProperty:@"installFridaPressed" forKey:@"action"];
                    [specifiers addObject:fridaSpecifier];

                    PSSpecifier *openSSHSpecifier = [PSSpecifier preferenceSpecifierNamed:@"" target:self set:defSetter get:defGetter detail:nil cell:PSStaticTextCell edit:nil];
                    [openSSHSpecifier setProperty:@"Button_Install_OpenSSH" forKey:@"title"];
                    [openSSHSpecifier setProperty:[DOButtonCell class] forKey:@"cellClass"];
                    [openSSHSpecifier setProperty:buttonHeight forKey:@"height"];
                    [openSSHSpecifier setProperty:@"lock.shield" forKey:@"image"];
                    [openSSHSpecifier setProperty:@"installOpenSSHPressed" forKey:@"action"];
                    [specifiers addObject:openSSHSpecifier];

                    PSSpecifier *addMountSpecifier = [PSSpecifier preferenceSpecifierNamed:@"" target:self set:defSetter get:defGetter detail:nil cell:PSStaticTextCell edit:nil];
                    [addMountSpecifier setProperty:@"Mount_Add_Title" forKey:@"title"];
                    [addMountSpecifier setProperty:[DOButtonCell class] forKey:@"cellClass"];
                    [addMountSpecifier setProperty:buttonHeight forKey:@"height"];
                    [addMountSpecifier setProperty:@"externaldrive.badge.plus" forKey:@"image"];
                    [addMountSpecifier setProperty:@"addMountPressed" forKey:@"action"];
                    [specifiers addObject:addMountSpecifier];

                    PSSpecifier *manageMountsSpecifier = [PSSpecifier preferenceSpecifierNamed:@"" target:self set:defSetter get:defGetter detail:nil cell:PSStaticTextCell edit:nil];
                    [manageMountsSpecifier setProperty:@"Mount_Manage_Title" forKey:@"title"];
                    [manageMountsSpecifier setProperty:[DOButtonCell class] forKey:@"cellClass"];
                    [manageMountsSpecifier setProperty:buttonHeight forKey:@"height"];
                    [manageMountsSpecifier setProperty:@"externaldrive" forKey:@"image"];
                    [manageMountsSpecifier setProperty:@"manageMountsPressed" forKey:@"action"];
                    [specifiers addObject:manageMountsSpecifier];
                }
                if ((envManager.isJailbroken || envManager.isInstalledThroughTrollStore) && envManager.isBootstrapped) {
/*
                    PSSpecifier *hideUnhideJailbreakSpecifier = [PSSpecifier preferenceSpecifierNamed:@"" target:self set:defSetter get:defGetter detail:nil cell:PSStaticTextCell edit:nil];
                    [hideUnhideJailbreakSpecifier setProperty:[DOButtonCell class] forKey:@"cellClass"];
                    [hideUnhideJailbreakSpecifier setProperty:buttonHeight forKey:@"height"];
                    if (envManager.isJailbreakHidden) {
                        [hideUnhideJailbreakSpecifier setProperty:@"Button_Unhide_Jailbreak" forKey:@"title"];
                        [hideUnhideJailbreakSpecifier setProperty:@"eye" forKey:@"image"];
                    }
                    else {
                        [hideUnhideJailbreakSpecifier setProperty:@"Button_Hide_Jailbreak" forKey:@"title"];
                        [hideUnhideJailbreakSpecifier setProperty:@"eye.slash" forKey:@"image"];
                    }
                    [hideUnhideJailbreakSpecifier setProperty:@"hideUnhideJailbreakPressed" forKey:@"action"];
                    BOOL hideJailbreakButtonShown = (envManager.isJailbroken || (envManager.isInstalledThroughTrollStore && envManager.isBootstrapped && !envManager.isJailbreakHidden));
                    if (hideJailbreakButtonShown) {
                        [specifiers addObject:hideUnhideJailbreakSpecifier];
                    }
*/
                    
                    PSSpecifier *removeJailbreakSpecifier = [PSSpecifier preferenceSpecifierNamed:@"" target:self set:defSetter get:defGetter detail:nil cell:PSStaticTextCell edit:nil];
                    [removeJailbreakSpecifier setProperty:@"Button_Remove_Jailbreak" forKey:@"title"];
                    [removeJailbreakSpecifier setProperty:[DOButtonCell class] forKey:@"cellClass"];
                    [removeJailbreakSpecifier setProperty:buttonHeight forKey:@"height"];
                    [removeJailbreakSpecifier setProperty:@"trash" forKey:@"image"];
                    [removeJailbreakSpecifier setProperty:@"removeJailbreakPressed" forKey:@"action"];
/*
                    if (hideJailbreakButtonShown) {
                        if (envManager.isJailbroken) {
                            [removeJailbreakSpecifier setProperty:DOLocalizedString(@"Hint_Hide_Jailbreak_Jailbroken") forKey:@"footerText"];
                        }
                        else {
                            [removeJailbreakSpecifier setProperty:DOLocalizedString(@"Hint_Hide_Jailbreak") forKey:@"footerText"];
                        }
                    }
*/
                    [specifiers addObject:removeJailbreakSpecifier];
                }
            }
        }
        
        PSSpecifier *themingGroupSpecifier = [PSSpecifier emptyGroupSpecifier];
        themingGroupSpecifier.name = DOLocalizedString(@"Section_Customization");
        [specifiers addObject:themingGroupSpecifier];
        
        PSSpecifier *themeSpecifier = [PSSpecifier preferenceSpecifierNamed:DOLocalizedString(@"Theme") target:self set:defSetter get:defGetter detail:nil cell:PSLinkListCell edit:nil];
        themeSpecifier.detailControllerClass = [DOPSListItemsController class];
        [themeSpecifier setProperty:@YES forKey:@"enabled"];
        [themeSpecifier setProperty:@"theme" forKey:@"key"];
        [themeSpecifier setProperty:[[self themeIdentifiers] firstObject] forKey:@"default"];
        [themeSpecifier setProperty:@"themeIdentifiers" forKey:@"valuesDataSource"];
        [themeSpecifier setProperty:@"themeNames" forKey:@"titlesDataSource"];
        [specifiers addObject:themeSpecifier];

        PSSpecifier *bootlogoGropSpecifier = [PSSpecifier emptyGroupSpecifier];
        bootlogoGropSpecifier.name = DOLocalizedString(@"Section_Boot_Logo");
        [specifiers addObject:bootlogoGropSpecifier];

        PSSpecifier *bootlogoEnabledSpecifier = [PSSpecifier preferenceSpecifierNamed:DOLocalizedString(@"Enabled") target:self set:@selector(setBootlogoEnabled:specifier:) get:defGetter detail:nil cell:PSSwitchCell edit:nil];
        [bootlogoEnabledSpecifier setProperty:@YES forKey:@"enabled"];
        [bootlogoEnabledSpecifier setProperty:@"bootlogoEnabled" forKey:@"key"];
        [bootlogoEnabledSpecifier setProperty:@YES forKey:@"default"];
        bootlogoEnabledSpecifier.identifier = @"bootlogoEnabled";
        [specifiers addObject:bootlogoEnabledSpecifier];

        _customBootlogoEnabledSpecifier = [PSSpecifier preferenceSpecifierNamed:DOLocalizedString(@"Custom_Boot_Logo") target:self set:@selector(setCustomBootlogoEnabled:specifier:) get:defGetter detail:nil cell:PSSwitchCell edit:nil];
        [_customBootlogoEnabledSpecifier setProperty:@YES forKey:@"enabled"];
        [_customBootlogoEnabledSpecifier setProperty:@"customBootlogoEnabled" forKey:@"key"];
        [_customBootlogoEnabledSpecifier setProperty:@NO forKey:@"default"];
        _customBootlogoEnabledSpecifier.identifier = @"customBootlogoEnabled";

        _customBootlogoSpecifier = [PSSpecifier preferenceSpecifierNamed:DOLocalizedString(@"Select_Image") target:self set:defSetter get:defGetter detail:nil cell:PSButtonCell edit:nil];
        _customBootlogoSpecifier.buttonAction = @selector(selectCustomBootlogoPressed);
        [_customBootlogoSpecifier setProperty:@YES forKey:@"enabled"];
        [_customBootlogoSpecifier setProperty:@"customBootlogo" forKey:@"key"];
        _customBootlogoSpecifier.identifier = @"customBootlogo";

        if ([[DOPreferenceManager sharedManager] boolPreferenceValueForKey:@"bootlogoEnabled" fallback:YES]) {
            [specifiers addObject:_customBootlogoEnabledSpecifier];

            if ([[DOPreferenceManager sharedManager] boolPreferenceValueForKey:@"customBootlogoEnabled" fallback:NO]) {
                [specifiers addObject:_customBootlogoSpecifier];
            }
        }

        _specifiers = specifiers;
    }
    return _specifiers;
}

#pragma mark - Getters & Setters

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier
{
    NSString *key = [specifier propertyForKey:@"key"];
    [[DOPreferenceManager sharedManager] setPreferenceValue:value forKey:key];
}

- (id)readPreferenceValue:(PSSpecifier*)specifier
{
    NSString *key = [specifier propertyForKey:@"key"];
    id value = [[DOPreferenceManager sharedManager] preferenceValueForKey:key];
    if (!value) {
        return [specifier propertyForKey:@"default"];
    }
    return value;
}

- (id)readIDownloadEnabled:(PSSpecifier *)specifier
{
    DOEnvironmentManager *envManager = [DOEnvironmentManager sharedManager];
    if (envManager.isJailbroken) {
        return @([DOEnvironmentManager sharedManager].isIDownloadEnabled);
    }
    return [self readPreferenceValue:specifier];
}

- (void)setIDownloadEnabled:(id)value specifier:(PSSpecifier *)specifier
{
    [self setPreferenceValue:value specifier:specifier];
    DOEnvironmentManager *envManager = [DOEnvironmentManager sharedManager];
    if (envManager.isJailbroken) {
        [[DOEnvironmentManager sharedManager] setIDownloadLoaded:((NSNumber *)value).boolValue needsUnsandbox:YES];
    }
}

- (id)readTweakInjectionEnabled:(PSSpecifier *)specifier
{
    DOEnvironmentManager *envManager = [DOEnvironmentManager sharedManager];
    if (envManager.isJailbroken) {
        return @([DOEnvironmentManager sharedManager].isTweakInjectionEnabled);
    }
    return [self readPreferenceValue:specifier];
}

- (void)setTweakInjectionEnabled:(id)value specifier:(PSSpecifier *)specifier
{
    [self setPreferenceValue:value specifier:specifier];
    DOEnvironmentManager *envManager = [DOEnvironmentManager sharedManager];
    if (envManager.isJailbroken) {
        [[DOEnvironmentManager sharedManager] setTweakInjectionEnabled:((NSNumber *)value).boolValue];
        UIAlertController *userspaceRebootAlertController = [UIAlertController alertControllerWithTitle:DOLocalizedString(@"Alert_Tweak_Injection_Toggled_Title") message:DOLocalizedString(@"Alert_Tweak_Injection_Toggled_Body") preferredStyle:UIAlertControllerStyleAlert];
        UIAlertAction *rebootNowAction = [UIAlertAction actionWithTitle:DOLocalizedString(@"Alert_Tweak_Injection_Toggled_Reboot_Now") style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            [[DOEnvironmentManager sharedManager] rebootUserspace];
        }];
        UIAlertAction *rebootLaterAction = [UIAlertAction actionWithTitle:DOLocalizedString(@"Alert_Tweak_Injection_Toggled_Reboot_Later") style:UIAlertActionStyleCancel handler:nil];
        
        [userspaceRebootAlertController addAction:rebootNowAction];
        [userspaceRebootAlertController addAction:rebootLaterAction];
        [self presentViewController:userspaceRebootAlertController animated:YES completion:nil];
    }
}

- (id)readAppJITEnabled:(PSSpecifier *)specifier
{
    DOEnvironmentManager *envManager = [DOEnvironmentManager sharedManager];
    if (envManager.isJailbroken) {
        bool v = jbclient_jbsettings_get_bool("markAppsAsDebugged");
        return @(v);
    }
    return [self readPreferenceValue:specifier];
}

- (void)setAppJITEnabled:(id)value specifier:(PSSpecifier *)specifier
{
    [self setPreferenceValue:value specifier:specifier];
    DOEnvironmentManager *envManager = [DOEnvironmentManager sharedManager];
    if (envManager.isJailbroken) {
        jbclient_platform_jbsettings_set_bool("markAppsAsDebugged", ((NSNumber *)value).boolValue);
    }
}

- (id)readJetsamMultiplier:(PSSpecifier *)specifier
{
    DOEnvironmentManager *envManager = [DOEnvironmentManager sharedManager];
    if (envManager.isJailbroken) {
        double v = jbclient_jbsettings_get_double("jetsamMultiplier");
        return @((v < 1 || isnan(v)) ? 6 : ceil(v * 2));
    }
    return [self readPreferenceValue:specifier];
}

- (void)setJetsamMultiplier:(id)value specifier:(PSSpecifier *)specifier
{
    [self setPreferenceValue:value specifier:specifier];
    DOEnvironmentManager *envManager = [DOEnvironmentManager sharedManager];
    if (envManager.isJailbroken) {
        jbclient_platform_jbsettings_set_double("jetsamMultiplier", ((NSNumber *)value).doubleValue / 2);
    }
}

- (void)setRemoveJailbreakEnabled:(id)value specifier:(PSSpecifier *)specifier
{
    [self setPreferenceValue:value specifier:specifier];
    if (((NSNumber *)value).boolValue) {
        UIAlertController *confirmationAlertController = [UIAlertController alertControllerWithTitle:DOLocalizedString(@"Alert_Remove_Jailbreak_Title") message:DOLocalizedString(@"Alert_Remove_Jailbreak_Enabled_Body") preferredStyle:UIAlertControllerStyleAlert];
        UIAlertAction *uninstallAction = [UIAlertAction actionWithTitle:DOLocalizedString(@"Button_Continue") style:UIAlertActionStyleDestructive handler:nil];
        UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:DOLocalizedString(@"Button_Cancel") style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            [self setPreferenceValue:@NO specifier:specifier];
            [self reloadSpecifiers];
        }];
        [confirmationAlertController addAction:uninstallAction];
        [confirmationAlertController addAction:cancelAction];
        [self presentViewController:confirmationAlertController animated:YES completion:nil];
    }
}

- (void)setBootlogoEnabled:(id)value specifier:(PSSpecifier *)specifier
{
    bool prevValueBool = ((NSNumber *)[self readPreferenceValue:specifier]).boolValue;
    [self setPreferenceValue:value specifier:specifier];
    bool valueBool = ((NSNumber *)value).boolValue;

    if (prevValueBool != valueBool) {
        NSMutableArray *affectedSpecifiers = [NSMutableArray new];
        [affectedSpecifiers addObject:_customBootlogoEnabledSpecifier];

        if (valueBool == ![self containsSpecifier:_customBootlogoSpecifier]) {
            [affectedSpecifiers addObject:_customBootlogoSpecifier];
        }

        if (valueBool) {
            [self insertContiguousSpecifiers:affectedSpecifiers afterSpecifier:specifier animated:YES];
        }
        else {
            [self removeContiguousSpecifiers:affectedSpecifiers animated:YES];
        }
    }

    if ([DOEnvironmentManager sharedManager].isJailbroken) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [[DOEnvironmentManager sharedManager] updateBootLogo];
        });
    }
}

- (void)setCustomBootlogoEnabled:(id)value specifier:(PSSpecifier *)specifier
{
    bool prevValueBool = ((NSNumber *)[self readPreferenceValue:specifier]).boolValue;
    [self setPreferenceValue:value specifier:specifier];
    bool valueBool = ((NSNumber *)value).boolValue;

    if (prevValueBool != valueBool) {
        if (valueBool) {
            [self insertSpecifier:_customBootlogoSpecifier afterSpecifier:specifier animated:YES];
        }
        else {
            [self removeSpecifier:_customBootlogoSpecifier animated:YES];
        }
    }

    if ([DOEnvironmentManager sharedManager].isJailbroken) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [[DOEnvironmentManager sharedManager] updateBootLogo];
        });
    }
}

- (void)selectCustomBootlogoPressed
{
    PHAuthorizationStatus status = [PHPhotoLibrary authorizationStatus];
    if (status == PHAuthorizationStatusDenied || status == PHAuthorizationStatusRestricted) {
        return;
    } else if (status == PHAuthorizationStatusNotDetermined) {
        [PHPhotoLibrary requestAuthorization:^(PHAuthorizationStatus status) {
            if (status == PHAuthorizationStatusAuthorized) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self selectCustomBootlogoPressed];
                });
            }
        }];
        return;
    }

    UIImagePickerController *picker = [[UIImagePickerController alloc] init];
    picker.delegate = self;
    picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
    [self presentViewController:picker animated:YES completion:nil];
}

#pragma mark - Boot Logo Picker

- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary<NSString *,id> *)info {
    UIImage *chosenImage = info[UIImagePickerControllerEditedImage];
    if (!chosenImage) {
        chosenImage = info[UIImagePickerControllerOriginalImage];
    }

    // Force correct the orientation
    // For some reason without rerendering the image, the stored file will have a wrong orientation for photos taken with the camera‚
    UIGraphicsBeginImageContextWithOptions(chosenImage.size, NO, 1.0);
    [chosenImage drawInRect:CGRectMake(0,0, chosenImage.size.width, chosenImage.size.height)];
    chosenImage = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();

    [UIImagePNGRepresentation(chosenImage) writeToFile:[DOUIManager sharedInstance].bootlogoPath atomically:YES];

    if ([DOEnvironmentManager sharedManager].isJailbroken) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [[DOEnvironmentManager sharedManager] updateBootLogo];
        });
    }

    [picker dismissViewControllerAnimated:YES completion:nil];
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    [picker dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - Button Actions

- (void)refreshJailbreakAppsPressed
{
    [[DOEnvironmentManager sharedManager] refreshJailbreakApps];
}

- (void)reinstallPackageManagersPressed
{
    [self.navigationController pushViewController:[[DOPkgManagerPickerViewController alloc] init] animated:YES];
}

- (void)exportRootHidePackageDiagnosticsPressed
{
    // Resolve the app container before entering the root/unsandboxed context.
    // NSHomeDirectory() may refer to root's home after credentials are changed.
    NSString *documentsPath = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    __block NSString *diagnostic = nil;
    DOEnvironmentManager *environmentManager = [DOEnvironmentManager sharedManager];
    [environmentManager runAsRoot:^{
        [environmentManager runUnsandboxed:^{
            diagnostic = RHBuildPackageDiagnostic();
        }];
    }];

    if (!diagnostic.length) {
        diagnostic = @"Dopamine RootHide package diagnostic\nNo jailbreak root was available.\n";
    }

    NSString *path = [documentsPath stringByAppendingPathComponent:@"RootHide-package-diagnostic.txt"];
    NSError *error = nil;
    if (![diagnostic writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&error]) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:DOLocalizedString(@"Log_Error") message:error.localizedDescription preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:DOLocalizedString(@"Button_OK") style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    UIActivityViewController *activity = [[UIActivityViewController alloc] initWithActivityItems:@[[NSURL fileURLWithPath:path]] applicationActivities:nil];
    activity.popoverPresentationController.sourceView = self.view;
    activity.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1, 1);
    [self presentViewController:activity animated:YES completion:nil];
}

- (void)pushRootHideInstallLogWithTitle:(NSString *)title operation:(void (^)(void))operation
{
    DOLogCrashViewController *logController = [[DOLogCrashViewController alloc] initWithTitle:title exitOnDisappear:NO];
    [self.navigationController pushViewController:logController animated:YES];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), operation);
}

- (void)installOpenSSHPressed
{
    [self pushRootHideInstallLogWithTitle:DOLocalizedString(@"Button_Install_OpenSSH") operation:^{
        RHSendInstallLog(@"开始安装 OpenSSH Server（RootHide 隔离环境）");
        DOEnvironmentManager *environmentManager = [DOEnvironmentManager sharedManager];
        [environmentManager runAsRoot:^{
            [environmentManager runUnsandboxed:^{
                RHInstallOpenSSH();
            }];
        }];
    }];
}

- (void)installFridaPressed
{
    [self pushRootHideInstallLogWithTitle:DOLocalizedString(@"Button_Install_Frida") operation:^{
        RHSendInstallLog(@"开始安装 Frida Server（RootHide arm64e 专用包）");
        NSURL *url = [NSURL URLWithString:@"https://github.com/sl-ars/frida-ios-stealth/releases/download/v17.17.0/frida_17.17.0_iphoneos-arm64e-roothide.deb"];
        if (!url) {
            RHSendInstallLog(@"Frida 下载地址无效");
            RHSendInstallLog(@"RESULT: FAILED");
            return;
        }
        RHInstallFridaFromURL(url);
    }];
}

- (void)changeMobilePasswordWithAuthenticationPressed
{
	LAContext *context = [[LAContext alloc] init];
	NSError *authError = nil;
	NSString *reason = DOLocalizedString(@"Password_Auth_Required");
	
	if ([context canEvaluatePolicy:LAPolicyDeviceOwnerAuthentication error:&authError]) {
		[context evaluatePolicy:LAPolicyDeviceOwnerAuthentication
			localizedReason:reason
			reply:^(BOOL success, NSError * _Nullable error) {
			dispatch_async(dispatch_get_main_queue(), ^{
				if (success) {
					[self changeMobilePassword];
				}
			});
		}];
	}
	else {
		[self changeMobilePassword];
	}
}

- (void)changeMobilePassword
{
    UIAlertController *changeMobilePasswordAlert = [UIAlertController alertControllerWithTitle:DOLocalizedString(@"Button_Change_Mobile_Password") message:DOLocalizedString(@"Alert_Change_Mobile_Password_Body") preferredStyle:UIAlertControllerStyleAlert];
    
    [changeMobilePasswordAlert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
        textField.placeholder = DOLocalizedString(@"Password_Placeholder");
        textField.secureTextEntry = YES;
    }];
    
    [changeMobilePasswordAlert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
        textField.placeholder = DOLocalizedString(@"Repeat_Password_Placeholder");
        textField.secureTextEntry = YES;
    }];
    
    UIAlertAction *changeButton = [UIAlertAction actionWithTitle:DOLocalizedString(@"Button_Change") style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action){
        NSString *password = changeMobilePasswordAlert.textFields[0].text;
        NSString *repeatPassword = changeMobilePasswordAlert.textFields[1].text;
        if (![password isEqualToString:repeatPassword]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self changeMobilePassword];
            });
        }
        else {
            [[DOEnvironmentManager sharedManager] changeMobilePassword:password];
        }
    }];
    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:DOLocalizedString(@"Button_Cancel") style:UIAlertActionStyleCancel handler:nil];
    [changeMobilePasswordAlert addAction:changeButton];
    [changeMobilePasswordAlert addAction:cancelAction];
    [self presentViewController:changeMobilePasswordAlert animated:YES completion:nil];
}

/*
- (void)hideUnhideJailbreakPressed
{
    DOEnvironmentManager *envManager = [DOEnvironmentManager sharedManager];
    [envManager setJailbreakHidden:!envManager.isJailbreakHidden];
    [self reloadSpecifiers];
}
*/

- (void)removeJailbreakPressed
{
    UIAlertController *confirmationAlertController = [UIAlertController alertControllerWithTitle:DOLocalizedString(@"Alert_Remove_Jailbreak_Title") message:DOLocalizedString(@"Alert_Remove_Jailbreak_Pressed_Body") preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction *uninstallAction = [UIAlertAction actionWithTitle:DOLocalizedString(@"Button_Continue") style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        [[DOEnvironmentManager sharedManager] deleteBootstrap];
        if ([DOEnvironmentManager sharedManager].isJailbroken) {
            [[DOEnvironmentManager sharedManager] reboot];
        }
        else {
            if (gSystemInfo.jailbreakInfo.rootPath) {
                free(gSystemInfo.jailbreakInfo.rootPath);
                gSystemInfo.jailbreakInfo.rootPath = NULL;
                [[DOEnvironmentManager sharedManager] locateJailbreakRoot];
            }
            [self reloadSpecifiers];
        }
    }];
    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:DOLocalizedString(@"Button_Cancel") style:UIAlertActionStyleDefault handler:nil];
    [confirmationAlertController addAction:uninstallAction];
    [confirmationAlertController addAction:cancelAction];
    [self presentViewController:confirmationAlertController animated:YES completion:nil];
}

- (void)showMountMessage:(NSString *)message
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:DOLocalizedString(@"Mount_Title")
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:DOLocalizedString(@"Button_OK") style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (NSString *)normalizedMountPath:(NSString *)path
{
    NSString *trimmedPath = [path stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (![trimmedPath hasPrefix:@"/"]) trimmedPath = [@"/" stringByAppendingString:trimmedPath];
    return trimmedPath.stringByStandardizingPath;
}

- (void)performMountPath:(NSString *)path mounted:(BOOL)mounted deleteMirror:(BOOL)deleteMirror
{
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        DOEnvironmentManager *environmentManager = [DOEnvironmentManager sharedManager];
        int result = [environmentManager setFakeMountPath:path mounted:mounted deleteMirror:deleteMirror];
        if (result == 0) {
            NSMutableArray<NSString *> *paths = [environmentManager.fakeMountPaths mutableCopy];
            if (mounted && ![paths containsObject:path]) [paths addObject:path];
            if (!mounted) [paths removeObject:path];
            if (![environmentManager saveFakeMountPaths:paths]) result = EIO;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *message = result == 0 ? DOLocalizedString(@"Mount_Operation_Succeeded") :
                [NSString stringWithFormat:DOLocalizedString(@"Mount_Operation_Failed"), result];
            [self showMountMessage:message];
        });
    });
}

- (void)addMountPressed
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:DOLocalizedString(@"Mount_Add_Title")
                                                                   message:DOLocalizedString(@"Mount_Path_Prompt")
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = @"/System/Library/...";
        textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:DOLocalizedString(@"Button_Cancel") style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:DOLocalizedString(@"Button_Mount") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        NSString *path = [self normalizedMountPath:alert.textFields.firstObject.text ?: @""];
        BOOL isDirectory = NO;
        if ([path isEqualToString:@"/"] || ![[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDirectory] || !isDirectory) {
            [self showMountMessage:DOLocalizedString(@"Mount_Path_Invalid")];
            return;
        }
        [self performMountPath:path mounted:YES deleteMirror:NO];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)manageMountsPressed
{
    NSArray<NSString *> *paths = [DOEnvironmentManager sharedManager].fakeMountPaths;
    if (paths.count == 0) {
        [self showMountMessage:DOLocalizedString(@"Mount_No_Paths")];
        return;
    }

    UIAlertController *list = [UIAlertController alertControllerWithTitle:DOLocalizedString(@"Mount_Manage_Title")
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleAlert];
    for (NSString *path in paths) {
        [list addAction:[UIAlertAction actionWithTitle:path style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            UIAlertController *options = [UIAlertController alertControllerWithTitle:path message:nil preferredStyle:UIAlertControllerStyleAlert];
            [options addAction:[UIAlertAction actionWithTitle:DOLocalizedString(@"Mount_Unmount_Keep_Copy") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *innerAction) {
                [self performMountPath:path mounted:NO deleteMirror:NO];
            }]];
            [options addAction:[UIAlertAction actionWithTitle:DOLocalizedString(@"Mount_Unmount_Delete_Copy") style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *innerAction) {
                [self performMountPath:path mounted:NO deleteMirror:YES];
            }]];
            [options addAction:[UIAlertAction actionWithTitle:DOLocalizedString(@"Button_Cancel") style:UIAlertActionStyleCancel handler:nil]];
            [self presentViewController:options animated:YES completion:nil];
        }]];
    }
    [list addAction:[UIAlertAction actionWithTitle:DOLocalizedString(@"Button_Cancel") style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:list animated:YES completion:nil];
}

- (void)resetSettingsPressed
{
    [[DOUIManager sharedInstance] resetSettings];
    [self.navigationController popToRootViewControllerAnimated:YES];
    [self reloadSpecifiers];
}


- (id)readDyldPatchEnabled:(PSSpecifier *)specifier
{
    DOEnvironmentManager *envManager = [DOEnvironmentManager sharedManager];
    if (envManager.isJailbroken) {
        return @(jbclient_dyld_patch_enabled());
    }
    return [self readPreferenceValue:specifier];
}

- (void)setDyldPatchEnabled:(id)value specifier:(PSSpecifier *)specifier
{
    DOEnvironmentManager *envManager = [DOEnvironmentManager sharedManager];
    
    bool enable = ((NSNumber *)value).boolValue;
    
    void (^confirmAction)(void) = ^{
        
        if (!envManager.isJailbroken) {
            
            [self setPreferenceValue:value specifier:specifier];
            return;
        }
    
        UIAlertController *userspaceRebootAlertController = [UIAlertController alertControllerWithTitle:DOLocalizedString(@"Alert_Tweak_Injection_Toggled_Title") message:DOLocalizedString(@"Alert_Tweak_Injection_Toggled_Body") preferredStyle:UIAlertControllerStyleAlert];
        UIAlertAction *rebootNowAction = [UIAlertAction actionWithTitle:DOLocalizedString(@"Menu_Reboot_Userspace_Title") style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            if(jbclient_set_dyld_patch(enable) == 0) {
                [self setPreferenceValue:value specifier:specifier];
                [[DOEnvironmentManager sharedManager] rebootUserspace];
            } else {
                [self reloadSpecifiers];
            }
        }];
        UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:DOLocalizedString(@"Button_Cancel") style:UIAlertActionStyleCancel handler:^(UIAlertAction * _Nonnull action) {
            [self reloadSpecifiers];
        }];
        
        [userspaceRebootAlertController addAction:cancelAction];
        [userspaceRebootAlertController addAction:rebootNowAction];
        [self presentViewController:userspaceRebootAlertController animated:YES completion:nil];
    };
    
    
    if(enable && envManager.isArm64e && NSProcessInfo.processInfo.operatingSystemVersion.majorVersion==15) {
        UIAlertController* alert = [UIAlertController alertControllerWithTitle:DOLocalizedString(@"Warning") message:DOLocalizedString(@"When spinlock fix is ​​enabled, app extensions of blacklisted apps will be disabled and may also cause spinlock panics when the blacklisted app is in foreground/background.\n\nYou can first try disabling tweak injection for the app in Choicy (spinlock fix still works), and only blacklist the app if that doesn't work.") preferredStyle:UIAlertControllerStyleAlert];
        UIAlertAction *continueAction = [UIAlertAction actionWithTitle:DOLocalizedString(@"Button_Continue") style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            confirmAction();
        }];
        UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:DOLocalizedString(@"Button_Cancel") style:UIAlertActionStyleCancel handler:^(UIAlertAction * _Nonnull action) {
            [self reloadSpecifiers];
        }];
        
        [alert addAction:cancelAction];
        [alert addAction:continueAction];
        [self presentViewController:alert animated:YES completion:nil];
    } else {
        confirmAction();
    }
}

@end
