// LaunchBridge/VolyLaunchBridge.m
//
// Simulator-only. Loaded into exactly one process: the iOS Simulator's
// runningboardd, when Voly's macOS host runs (inside the simulator's launchd)
//
//   launchctl debug user/foreground/com.apple.runningboardd \
//       --environment DYLD_INSERT_LIBRARIES=<this dylib> VOLY_BRIDGE_CONFIG=<plist>
//   launchctl kickstart -k user/foreground/com.apple.runningboardd
//
// `launchctl debug` is one-shot, so nothing persists past this runningboardd
// instance: a simulator reboot (or a second kickstart) removes the bridge.
//
// The bridge does one thing. Every app launch in the simulator — SpringBoard
// taps, `simctl launch`, Xcode's Run — funnels through
//   -[RBLaunchdJobManager createAndLaunchWithIdentity:context:error:]
// and we append VolyAgent.dylib to the launch context's
// DYLD_INSERT_LIBRARIES there, keeping whatever the requester (e.g. Xcode's
// libBacktraceRecording / libMainThreadChecker) already put in it. The app
// is never terminated or relaunched, so the debugger session is untouched.
//
// Everything here is on the app-launch path of a system daemon, so:
//   - no networking, no directory scans; one stat() + one access() per launch
//   - any failure falls through to the original implementation untouched
//   - if the private seam is missing on this runtime we don't hook at all and
//     say so in the status file

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <os/lock.h>
#import <os/log.h>
#import <stdlib.h>
#import <string.h>
#import <sys/stat.h>
#import <unistd.h>

static NSString *const kVolyBridgeVersion = @"1";
static NSString *const kVolyInsertLibrariesKey = @"DYLD_INSERT_LIBRARIES";
static NSString *const kVolyAgentLeafName = @"VolyAgent.dylib";
static NSString *const kVolyDisableKey = @"VOLY_DISABLE";
static NSString *const kVolyInjectedMarkerKey = @"VOLY_BRIDGE_INJECTED";
static NSString *const kVolyStatusFileName = @"bridge-status.plist";

static os_log_t VolyBridgeLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        log = os_log_create("com.latifatci.Voly", "LaunchBridge");
    });
    return log;
}

#pragma mark - Config

/// Immutable snapshot of the plist Voly writes. Replaced wholesale on reload.
@interface VolyBridgeConfig : NSObject
@property (nonatomic, readonly) BOOL enabled;
@property (nonatomic, readonly, copy) NSString *simulatorUDID;
@property (nonatomic, readonly, copy) NSString *agentPath;
@property (nonatomic, readonly) BOOL includeSystemApps;
@property (nonatomic, readonly, copy) NSSet<NSString *> *allowedBundleIDs;
@property (nonatomic, readonly, copy) NSSet<NSString *> *excludedBundleIDs;
- (nullable instancetype)initWithDictionary:(NSDictionary *)dict;
@end

static NSSet<NSString *> *VolyBridgeStringSet(id value) {
    if (![value isKindOfClass:[NSArray class]]) return [NSSet set];
    NSMutableSet<NSString *> *set = [NSMutableSet set];
    for (id item in (NSArray *)value) {
        if ([item isKindOfClass:[NSString class]]) [set addObject:item];
    }
    return set;
}

@implementation VolyBridgeConfig
- (nullable instancetype)initWithDictionary:(NSDictionary *)dict {
    if (!(self = [super init])) return nil;
    id udid = dict[@"simulatorUDID"];
    id agent = dict[@"agentPath"];
    if (![udid isKindOfClass:[NSString class]] || ![agent isKindOfClass:[NSString class]]) return nil;
    _simulatorUDID = [udid copy];
    _agentPath = [agent copy];
    _enabled = [dict[@"enabled"] respondsToSelector:@selector(boolValue)] && [dict[@"enabled"] boolValue];
    _includeSystemApps = [dict[@"includeSystemApps"] respondsToSelector:@selector(boolValue)]
        && [dict[@"includeSystemApps"] boolValue];
    _allowedBundleIDs = VolyBridgeStringSet(dict[@"allowedBundleIDs"]);
    _excludedBundleIDs = VolyBridgeStringSet(dict[@"excludedBundleIDs"]);
    return self;
}
@end

static NSString *gConfigPath;
static NSString *gSimulatorUDID;
static os_unfair_lock gConfigLock = OS_UNFAIR_LOCK_INIT;
static VolyBridgeConfig *gConfig;          // guarded by gConfigLock
static struct timespec gConfigMTime;       // guarded by gConfigLock
static off_t gConfigSize;                  // guarded by gConfigLock
static ino_t gConfigInode;                 // guarded by gConfigLock

/// Current config, re-read only when the file changed on disk. Voly rewrites
/// it atomically when the user edits exclusions or disables integration, so
/// those take effect on the next launch without restarting runningboardd.
/// Returns nil when the file is missing/unreadable — treated as "disabled".
static VolyBridgeConfig *VolyBridgeCurrentConfig(void) {
    struct stat st;
    if (gConfigPath == nil || stat(gConfigPath.fileSystemRepresentation, &st) != 0) {
        os_unfair_lock_lock(&gConfigLock);
        gConfig = nil;
        gConfigInode = 0;
        os_unfair_lock_unlock(&gConfigLock);
        return nil;
    }
    os_unfair_lock_lock(&gConfigLock);
    BOOL unchanged = gConfigInode == st.st_ino
        && gConfigSize == st.st_size
        && gConfigMTime.tv_sec == st.st_mtimespec.tv_sec
        && gConfigMTime.tv_nsec == st.st_mtimespec.tv_nsec;
    if (!unchanged) {
        NSDictionary *dict = [NSDictionary dictionaryWithContentsOfURL:[NSURL fileURLWithPath:gConfigPath]
                                                                 error:NULL];
        gConfig = [dict isKindOfClass:[NSDictionary class]]
            ? [[VolyBridgeConfig alloc] initWithDictionary:dict]
            : nil;
        gConfigInode = st.st_ino;
        gConfigSize = st.st_size;
        gConfigMTime = st.st_mtimespec;
    }
    VolyBridgeConfig *config = gConfig;
    os_unfair_lock_unlock(&gConfigLock);
    return config;
}

#pragma mark - Launch decision

/// The DYLD_INSERT_LIBRARIES value to launch with, or nil when the agent is
/// already in `existing` (e.g. a manual `simctl launch` relaunch from Voly, or
/// an app that re-execs itself) — never insert it twice.
static NSString *VolyBridgeMergedInsertLibraries(NSString *existing, NSString *agentPath) {
    if (existing.length == 0) return agentPath;
    for (NSString *entry in [existing componentsSeparatedByString:@":"]) {
        if (entry.length == 0) continue;
        if ([entry isEqualToString:agentPath]) return nil;
        if ([entry.lastPathComponent isEqualToString:kVolyAgentLeafName]) return nil;
    }
    return [NSString stringWithFormat:@"%@:%@", existing, agentPath];
}

/// Why a launch is left alone; nil means "inject".
static NSString *VolyBridgeSkipReason(VolyBridgeConfig *config, NSString *bundleID, NSDictionary *environment) {
    if (config == nil) return @"no config";
    if (!config.enabled) return @"integration disabled";
    if (![config.simulatorUDID isEqualToString:gSimulatorUDID]) return @"config is for another simulator";
    if (bundleID.length == 0) return @"no bundle identifier";
    if ([config.excludedBundleIDs containsObject:bundleID]) return @"excluded by user";
    if (config.allowedBundleIDs.count > 0) {
        if (![config.allowedBundleIDs containsObject:bundleID]) return @"not in allow list";
    } else if (!config.includeSystemApps && [bundleID hasPrefix:@"com.apple."]) {
        return @"system app";
    }
    id disable = environment[kVolyDisableKey];
    if ([disable isKindOfClass:[NSString class]] && [disable isEqualToString:@"1"]) return @"VOLY_DISABLE=1";
    // The app runs the agent it links itself; don't load a second copy.
    id sdk = environment[@"VOLY_AGENT_ENABLED"];
    if ([sdk isKindOfClass:[NSString class]] && [sdk isEqualToString:@"1"]) return @"app uses the linked SDK agent";
    if ([config.agentPath rangeOfString:@":"].location != NSNotFound) return @"agent path contains ':'";
    // A missing insert library makes dyld abort the launch, so never hand out
    // a path we can't read right now (Voly.app moved, staging dir cleaned…).
    if (access(config.agentPath.fileSystemRepresentation, R_OK) != 0) return @"agent dylib unreadable";
    return nil;
}

static void VolyBridgePrepareLaunch(id identity, id context) {
    SEL isEmbeddedSel = NSSelectorFromString(@"isEmbeddedApplication");
    if (![identity respondsToSelector:isEmbeddedSel]) return;
    // Daemons, XPC services and app extensions also come through here; only
    // ordinary apps are eligible.
    if (![[identity valueForKey:@"isEmbeddedApplication"] boolValue]) return;

    SEL envSel = NSSelectorFromString(@"environment");
    SEL setEnvSel = NSSelectorFromString(@"setEnvironment:");
    if (![context respondsToSelector:envSel] || ![context respondsToSelector:setEnvSel]) return;

    NSString *bundleID = nil;
    if ([identity respondsToSelector:NSSelectorFromString(@"embeddedApplicationIdentifier")]) {
        id value = [identity valueForKey:@"embeddedApplicationIdentifier"];
        if ([value isKindOfClass:[NSString class]]) bundleID = value;
    }

    id rawEnvironment = [context valueForKey:@"environment"];
    NSDictionary *environment = [rawEnvironment isKindOfClass:[NSDictionary class]] ? rawEnvironment : @{};

    VolyBridgeConfig *config = VolyBridgeCurrentConfig();
    NSString *skip = VolyBridgeSkipReason(config, bundleID, environment);
    if (skip != nil) {
        os_log_info(VolyBridgeLog(), "launch %{public}@: not injecting (%{public}@)", bundleID ?: @"?", skip);
        return;
    }

    id existing = environment[kVolyInsertLibrariesKey];
    NSString *merged = VolyBridgeMergedInsertLibraries(
        [existing isKindOfClass:[NSString class]] ? existing : nil, config.agentPath);
    if (merged == nil) {
        os_log_info(VolyBridgeLog(), "launch %{public}@: agent already in DYLD_INSERT_LIBRARIES", bundleID);
        return;
    }

    NSMutableDictionary *updated = [environment mutableCopy];
    updated[kVolyInsertLibrariesKey] = merged;
    updated[kVolyInjectedMarkerKey] = @"1";
    [context setValue:updated forKey:@"environment"];
    os_log(VolyBridgeLog(), "launch %{public}@: agent appended (existing insert libraries kept: %lu)",
           bundleID,
           (unsigned long)([existing isKindOfClass:[NSString class]]
                           ? [[(NSString *)existing componentsSeparatedByString:@":"] count] : 0));
}

#pragma mark - Hook

typedef id (*VolyCreateAndLaunchIMP)(id, SEL, id, id, NSError *__autoreleasing *);
static VolyCreateAndLaunchIMP gOriginalCreateAndLaunch;

static id VolyBridge_createAndLaunch(id self, SEL _cmd, id identity, id context, NSError *__autoreleasing *outError) {
    @try {
        VolyBridgePrepareLaunch(identity, context);
    } @catch (NSException *exception) {
        // Never let a KVC surprise on a future runtime break app launching.
        os_log_error(VolyBridgeLog(), "prepare threw %{public}@ — launching unmodified", exception.name);
    }
    return gOriginalCreateAndLaunch(self, _cmd, identity, context, outError);
}

/// Returns nil on success, otherwise why this runtime can't be hooked.
static NSString *VolyBridgeInstallHook(void) {
    if (gOriginalCreateAndLaunch != NULL) return nil;   // idempotent
    Class manager = objc_getClass("RBLaunchdJobManager");
    if (manager == Nil) return @"RBLaunchdJobManager class not found";
    Class contextClass = objc_getClass("RBSLaunchContext");
    if (contextClass == Nil) return @"RBSLaunchContext class not found";
    if (![contextClass instancesRespondToSelector:NSSelectorFromString(@"environment")]
        || ![contextClass instancesRespondToSelector:NSSelectorFromString(@"setEnvironment:")]) {
        return @"RBSLaunchContext has no environment accessors";
    }
    SEL selector = NSSelectorFromString(@"createAndLaunchWithIdentity:context:error:");
    Method method = class_getInstanceMethod(manager, selector);
    if (method == NULL) return @"createAndLaunchWithIdentity:context:error: not found";
    // self, _cmd, identity, context, error — and an object return. Anything
    // else means the signature moved; don't guess.
    char returnType[8] = {0};
    method_getReturnType(method, returnType, sizeof(returnType));
    if (method_getNumberOfArguments(method) != 5 || returnType[0] != '@') {
        return [NSString stringWithFormat:@"unexpected launch signature %s",
                method_getTypeEncoding(method) ?: "?"];
    }
    gOriginalCreateAndLaunch = (VolyCreateAndLaunchIMP)method_setImplementation(
        method, (IMP)VolyBridge_createAndLaunch);
    return nil;
}

#pragma mark - Status

static void VolyBridgeWriteStatus(BOOL hookInstalled, NSString *failureReason) {
    if (gConfigPath == nil) return;
    NSString *statusPath = [[gConfigPath stringByDeletingLastPathComponent]
        stringByAppendingPathComponent:kVolyStatusFileName];
    NSMutableDictionary *status = [@{
        @"bridgeVersion": kVolyBridgeVersion,
        @"pid": @(getpid()),
        @"hookInstalled": @(hookInstalled),
        @"simulatorUDID": gSimulatorUDID ?: @"",
        @"loadedAt": [NSDate date],
    } mutableCopy];
    const char *runtimeVersion = getenv("SIMULATOR_RUNTIME_VERSION");
    const char *runtimeBuild = getenv("SIMULATOR_RUNTIME_BUILD_VERSION");
    if (runtimeVersion) status[@"runtimeVersion"] = @(runtimeVersion);
    if (runtimeBuild) status[@"runtimeBuild"] = @(runtimeBuild);
    if (failureReason) status[@"failureReason"] = failureReason;
    NSError *error = nil;
    if (![status writeToURL:[NSURL fileURLWithPath:statusPath] error:&error]) {
        os_log_error(VolyBridgeLog(), "could not write status file: %{public}@", error.localizedDescription);
    }
}

/// Drop this dylib from our own DYLD_INSERT_LIBRARIES so nothing that
/// inherits runningboardd's environment ever loads the bridge.
static void VolyBridgeScrubOwnEnvironment(void) {
    const char *raw = getenv("DYLD_INSERT_LIBRARIES");
    if (raw == NULL) return;
    NSMutableArray<NSString *> *kept = [NSMutableArray array];
    for (NSString *entry in [@(raw) componentsSeparatedByString:@":"]) {
        if (entry.length == 0) continue;
        if ([entry.lastPathComponent isEqualToString:@"VolyLaunchBridge.dylib"]) continue;
        [kept addObject:entry];
    }
    if (kept.count == 0) {
        unsetenv("DYLD_INSERT_LIBRARIES");
    } else {
        setenv("DYLD_INSERT_LIBRARIES", [kept componentsJoinedByString:@":"].UTF8String, 1);
    }
}

static void VolyBridgeInstallWithRetry(int attemptsLeft) {
    NSString *failure = VolyBridgeInstallHook();
    if (failure == nil) {
        os_log(VolyBridgeLog(), "bridge active in runningboardd pid %d (simulator %{public}@)",
               getpid(), gSimulatorUDID);
        VolyBridgeWriteStatus(YES, nil);
        return;
    }
    if (attemptsLeft > 0) {
        // RunningBoard's classes are normally registered before our
        // constructor runs; give a late-loading runtime a moment anyway.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            VolyBridgeInstallWithRetry(attemptsLeft - 1);
        });
        return;
    }
    os_log_error(VolyBridgeLog(), "bridge NOT active: %{public}@", failure);
    VolyBridgeWriteStatus(NO, failure);
}

__attribute__((constructor))
static void VolyLaunchBridge_Install(void) {
    // Inert anywhere but a simulator's runningboardd that Voly configured.
    const char *progname = getprogname();
    if (progname == NULL || strcmp(progname, "runningboardd") != 0) return;
    const char *udid = getenv("SIMULATOR_UDID");
    const char *configPath = getenv("VOLY_BRIDGE_CONFIG");
    if (udid == NULL || configPath == NULL) return;

    gSimulatorUDID = @(udid);
    gConfigPath = @(configPath);
    VolyBridgeScrubOwnEnvironment();

    VolyBridgeConfig *config = VolyBridgeCurrentConfig();
    if (config != nil && ![config.simulatorUDID isEqualToString:gSimulatorUDID]) {
        os_log_error(VolyBridgeLog(), "config is for simulator %{public}@, not %{public}@ — staying inert",
                     config.simulatorUDID, gSimulatorUDID);
        VolyBridgeWriteStatus(NO, @"config belongs to a different simulator");
        return;
    }
    VolyBridgeInstallWithRetry(4);
}
