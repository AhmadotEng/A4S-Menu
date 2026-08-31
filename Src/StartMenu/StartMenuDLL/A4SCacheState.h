// Pure cache-publication decisions shared by the injected product and its
// native fault-injection test. Keep this header independent of Win32/ATL so the
// state machine can be compiled and exercised without loading Explorer.
#pragma once

#include <stdint.h>

namespace A4SCacheState
{
	enum FolderWatchBit
	{
		WATCH_START_MENU       =1U<<0, // required: per-user Programs/pins
		WATCH_COMMON_START_MENU=1U<<1, // required unless policy hides common groups
		WATCH_DESKTOP          =1U<<2, // optional metadata preload only
		WATCH_PUBLIC_DESKTOP   =1U<<3, // optional metadata preload only
		WATCH_TASKBAR_PINNED   =1U<<4, // optional metadata preload only
		WATCH_CLASSIC_PINNED   =1U<<5, // required only for classic-pinned root mode
		WATCH_METRO_APPS       =1U<<6, // required only while an Apps surface is exposed
	};

	inline uint32_t RequiredFolderWatchMask( bool noCommonFolders,
		bool classicPinnedRoot, bool metroAppsSurface )
	{
		uint32_t mask=WATCH_START_MENU;
		if (!noCommonFolders)
			mask|=WATCH_COMMON_START_MENU;
		if (classicPinnedRoot)
			mask|=WATCH_CLASSIC_PINNED;
		if (metroAppsSurface)
			mask|=WATCH_METRO_APPS;
		return mask;
	}

	inline bool RequiredFolderWatchesReady( uint32_t requiredMask,
		uint32_t armedMask, bool waitApiHealthy, bool rearmApiHealthy,
		bool pendingSignals )
	{
		return waitApiHealthy && rearmApiHealthy && !pendingSignals &&
			(armedMask&requiredMask)==requiredMask;
	}

	inline uint64_t NextNonzeroEpoch( uint64_t value )
	{
		return value==UINT64_MAX?1:value+1;
	}

	struct EnvironmentDiscoveryState
	{
		bool powerCapabilitiesRequired;
		bool powerCapabilitiesSucceeded;
		bool hardwareProfileRequired;
		bool hardwareProfileSucceeded;
		bool switchUserPolicyRequired;
		bool switchUserPolicySucceeded;
		bool rootPathsSucceeded;
		bool rootPathClonesSucceeded;
	};

	inline bool EnvironmentDiscoveryComplete(
		const EnvironmentDiscoveryState &state )
	{
		return (!state.powerCapabilitiesRequired ||
				state.powerCapabilitiesSucceeded) &&
			(!state.hardwareProfileRequired ||
				state.hardwareProfileSucceeded) &&
			(!state.switchUserPolicyRequired ||
				state.switchUserPolicySucceeded) &&
			state.rootPathsSucceeded && state.rootPathClonesSucceeded;
	}

	enum EnvironmentPublicationDecision
	{
		KEEP_PREVIOUS_ENVIRONMENT,
		PUBLISH_DISCOVERED_ENVIRONMENT,
	};

	inline EnvironmentPublicationDecision DecideEnvironmentPublication(
		const EnvironmentDiscoveryState &state )
	{
		return EnvironmentDiscoveryComplete(state)?
			PUBLISH_DISCOVERED_ENVIRONMENT:KEEP_PREVIOUS_ENVIRONMENT;
	}
}
