// LoaderShim/VolyAgentLoader.h
#ifndef VOLY_AGENT_LOADER_H
#define VOLY_AGENT_LOADER_H

#ifdef __cplusplus
extern "C" {
#endif

/// Defined in Swift via @_cdecl. Must be called on the main thread after
/// UIApplicationDidFinishLaunchingNotification.
extern void voly_agent_injected_bootstrap(void);

#ifdef __cplusplus
}
#endif

#endif
