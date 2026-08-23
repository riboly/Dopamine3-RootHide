#import "LSApplicationProxy.h"
@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (NSArray<LSApplicationProxy *> *)allApplications;
- (BOOL)registerApplicationDictionary:(NSDictionary*)dict;
- (BOOL)unregisterApplication:(id)arg1;
- (BOOL)_LSPrivateRebuildApplicationDatabasesForSystemApps:(BOOL)arg1 internal:(BOOL)arg2 user:(BOOL)arg3;
- (BOOL)openApplicationWithBundleID:(NSString *)arg1 ;
- (void)enumerateApplicationsOfType:(NSUInteger)type block:(void (^)(LSApplicationProxy*))block;
- (BOOL)installApplication:(NSURL*)appPackageURL withOptions:(NSDictionary*)options error:(NSError**)error;
- (BOOL)uninstallApplication:(NSString*)appId withOptions:(NSDictionary*)options;
- (BOOL)uninstallApplication:(NSString *)bundleIdentifier withOptions:(NSDictionary *)options error:(NSError **)error usingBlock:(id)block;
- (void)addObserver:(id)arg1;
- (void)removeObserver:(id)arg1;
@end
