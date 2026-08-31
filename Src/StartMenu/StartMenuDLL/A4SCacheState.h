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

	inline bool RequiredFolderLoadsComplete( uint32_t requestedRequiredMask,
		uint32_t completedMask )
	{
		return (completedMask&requestedRequiredMask)==requestedRequiredMask;
	}

	// Win32 FILE_NOTIFY_CHANGE_* values. Keeping the reviewed product filter in
	// this pure header lets the native gate prove every metadata dimension used
	// by ItemInfo participates in the exact mask passed to the watcher API.
	constexpr uint32_t RequiredDirectoryNotifyFilter( void )
	{
		return 0x00000001U | // FILE_NOTIFY_CHANGE_FILE_NAME
			0x00000002U |     // FILE_NOTIFY_CHANGE_DIR_NAME
			0x00000004U |     // FILE_NOTIFY_CHANGE_ATTRIBUTES
			0x00000008U |     // FILE_NOTIFY_CHANGE_SIZE
			0x00000010U |     // FILE_NOTIFY_CHANGE_LAST_WRITE
			0x00000040U |     // FILE_NOTIFY_CHANGE_CREATION
			0x00000100U;      // FILE_NOTIFY_CHANGE_SECURITY
	}

	const uint64_t WATCH_PATH_HASH_OFFSET=14695981039346656037ULL;
	const uint64_t WATCH_PATH_HASH_PRIME=1099511628211ULL;

	inline uint64_t MixWatchIdentityWord( uint64_t hash, uint64_t value )
	{
		for (unsigned int i=0;i<8;i++)
		{
			hash^=static_cast<uint8_t>(value>>(i*8));
			hash*=WATCH_PATH_HASH_PRIME;
		}
		return hash;
	}

	inline uint64_t FoldWatchPathIdentity( uint64_t aggregate,
		uint32_t watchBit, uint64_t normalizedPathHash,
		uint64_t volumeIdentity, uint64_t fileIdentity )
	{
		aggregate=MixWatchIdentityWord(aggregate,watchBit);
		aggregate=MixWatchIdentityWord(aggregate,normalizedPathHash);
		aggregate=MixWatchIdentityWord(aggregate,volumeIdentity);
		return MixWatchIdentityWord(aggregate,fileIdentity);
	}

	struct WatchConfigurationIdentity
	{
		uint32_t requiredMask;
		uint64_t normalizedPathIdentity;
		uint64_t sourceGeneration;
	};

	inline bool WatchConfigurationMatches(
		const WatchConfigurationIdentity &left,
		const WatchConfigurationIdentity &right )
	{
		return left.requiredMask==right.requiredMask &&
			left.normalizedPathIdentity!=0 &&
			left.normalizedPathIdentity==right.normalizedPathIdentity &&
			left.sourceGeneration!=0 &&
			left.sourceGeneration==right.sourceGeneration;
	}

	struct CachedMetadataAdmissionState
	{
		bool mainThread;
		bool pathPresent;
		bool forceValidation;
		bool watchBaselineReady;
		bool pathCoveredByWatchIdentity;
		bool entryStable;
		bool requestedFlagsComplete;
		uint64_t validatedPathGeneration;
		uint64_t currentPathGeneration;
	};

	inline bool CanUseCachedFileMetadata(
		const CachedMetadataAdmissionState &state )
	{
		return state.mainThread && state.pathPresent &&
			!state.forceValidation && state.watchBaselineReady &&
			state.pathCoveredByWatchIdentity && state.entryStable &&
			state.requestedFlagsComplete &&
			state.validatedPathGeneration!=0 &&
			state.validatedPathGeneration==state.currentPathGeneration;
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
