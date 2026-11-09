// LoaderShim/VolyAgentLoader.m
//
// When Voly's macOS host sets
//   SIMCTL_CHILD_DYLD_INSERT_LIBRARIES=<path-to-VolyAgent.dylib>
// and runs `simctl launch`, dyld loads VolyAgent.dylib into the target app
// before main(). This constructor runs there.
//
// We must NOT touch UIKit from inside the constructor — UIApplication may not
// be initialized yet, and for non-UI processes (daemons, app extensions that
// happen to load the dylib) we want to silently bail.

#import "VolyAgentLoader.h"
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <stdlib.h>
#import <string.h>

static id gVolyDidFinishLaunchingObserver = nil;

__attribute__((constructor))
static void VolyAgentLoader_Install(void) {
    // Honor the escape hatch before touching NSNotificationCenter so injected
    // apps with VOLY_DISABLE=1 stay completely dormant.
    const char *disable = getenv("VOLY_DISABLE");
    if (disable != NULL && strcmp(disable, "1") == 0) {
        return;
    }

    // The app opted into the agent it links itself (VolyAgent.start/wrap).
    // Two agents in one process would fight over overlays and ports, so the
    // injected copy stays dormant and the SDK one serves this process.
    const char *sdk = getenv("VOLY_AGENT_ENABLED");
    if (sdk != NULL && strcmp(sdk, "1") == 0) {
        NSLog(@"[VolyAgent] VOLY_AGENT_ENABLED=1 — injected agent standing down for the SDK agent");
        return;
    }

    NSLog(@"[VolyAgent] loader installed in pid %d", getpid());

    gVolyDidFinishLaunchingObserver = [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidFinishLaunchingNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification * _Nonnull note) {
        NSLog(@"[VolyAgent] UIApplicationDidFinishLaunchingNotification — calling voly_agent_injected_bootstrap()");
        voly_agent_injected_bootstrap();
        // Observer lives for process lifetime; nothing to remove.
    }];
}
