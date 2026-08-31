#include "../Src/StartMenu/StartMenuDLL/A4SCacheState.h"
#include <stddef.h>
#include <stdio.h>

using namespace A4SCacheState;

static int Require( bool condition, int failure )
{
	return condition?0:failure;
}

int main()
{
	int result=0;
	const uint32_t base=RequiredFolderWatchMask(false,false,false);
	if ((result=Require(base==(WATCH_START_MENU|WATCH_COMMON_START_MENU),10)))
		return result;
	if ((result=Require(RequiredFolderWatchMask(true,false,false)==WATCH_START_MENU,11)))
		return result;
	const uint32_t full=RequiredFolderWatchMask(false,true,true);
	if ((result=Require(full==(WATCH_START_MENU|WATCH_COMMON_START_MENU|
		WATCH_CLASSIC_PINNED|WATCH_METRO_APPS),12)))
		return result;
	if ((result=Require((full&(WATCH_DESKTOP|WATCH_PUBLIC_DESKTOP|
		WATCH_TASKBAR_PINNED))==0,13)))
		return result;

	if ((result=Require(RequiredFolderWatchesReady(full,full,true,true,false),20)))
		return result;
	const uint32_t requiredBits[]={WATCH_START_MENU,WATCH_COMMON_START_MENU,
		WATCH_CLASSIC_PINNED,WATCH_METRO_APPS};
	for (size_t i=0;i<sizeof(requiredBits)/sizeof(requiredBits[0]);i++)
		if ((result=Require(!RequiredFolderWatchesReady(full,
			full&~requiredBits[i],true,true,false),21+static_cast<int>(i))))
			return result;
	// Inject wait and overlapped-rearm failures independently. Either failure
	// must make publication impossible.
	if ((result=Require(!RequiredFolderWatchesReady(full,full,false,true,false),30)))
		return result;
	if ((result=Require(!RequiredFolderWatchesReady(full,full,true,false,false),31)))
		return result;
	if ((result=Require(!RequiredFolderWatchesReady(full,full,true,true,true),32)))
		return result;
	if ((result=Require(RequiredFolderWatchesReady(base,
		base|WATCH_DESKTOP,true,true,false),33)))
		return result;
	if ((result=Require(RequiredFolderLoadsComplete(full,full),34)))
		return result;
	for (size_t i=0;i<sizeof(requiredBits)/sizeof(requiredBits[0]);i++)
		if ((result=Require(!RequiredFolderLoadsComplete(full,
			full&~requiredBits[i]),35+static_cast<int>(i))))
			return result;
	// Optional preload failures are explicit best effort and never satisfy or
	// block a required-load bit.
	if ((result=Require(RequiredFolderLoadsComplete(base,
		base|WATCH_DESKTOP|WATCH_TASKBAR_PINNED),39)))
		return result;
	const uint32_t requestedLoads=base|WATCH_DESKTOP|WATCH_TASKBAR_PINNED;
	if ((result=Require(RequestedFolderLoadsComplete(requestedLoads,
		requestedLoads),71)))
		return result;
	if ((result=Require(!RequestedFolderLoadsComplete(requestedLoads,
		requestedLoads&~WATCH_DESKTOP),72)))
		return result;

	const uint32_t notifyFilter=RequiredDirectoryNotifyFilter();
	const uint32_t expectedNotifyFilter=0x00000001U|0x00000002U|
		0x00000004U|0x00000008U|0x00000010U|0x00000040U|0x00000100U;
	if ((result=Require(notifyFilter==expectedNotifyFilter,40)))
		return result;

	const uint64_t pathA=FoldWatchPathIdentity(WATCH_PATH_HASH_OFFSET,
		WATCH_START_MENU,101,7,9001);
	const uint64_t pathB=FoldWatchPathIdentity(WATCH_PATH_HASH_OFFSET,
		WATCH_START_MENU,102,7,9001);
	WatchConfigurationIdentity identityA={base,pathA,5};
	WatchConfigurationIdentity identityACopy={base,pathA,5};
	WatchConfigurationIdentity differentPathSameMask={base,pathB,5};
	WatchConfigurationIdentity differentSourceSameMask={base,pathA,6};
	if ((result=Require(WatchConfigurationMatches(identityA,identityACopy),41)))
		return result;
	if ((result=Require(!WatchConfigurationMatches(identityA,
		differentPathSameMask),42)))
		return result;
	if ((result=Require(!WatchConfigurationMatches(identityA,
		differentSourceSameMask),43)))
		return result;
	WatchConfigurationIdentity unknownIdentity={base,0,5};
	if ((result=Require(!WatchConfigurationMatches(identityA,unknownIdentity),44)))
		return result;
	WatchConfigurationIdentity unknownSource={base,pathA,0};
	if ((result=Require(!WatchConfigurationMatches(identityA,unknownSource),58)))
		return result;

	WatchRootView roots[]={
		{WATCH_START_MENU,L"\\??\\C:\\USERS\\ADMIN\\START MENU",101,7,5,true},
		{WATCH_COMMON_START_MENU,L"\\??\\C:\\USERS\\ADMIN\\START MENU\\PROGRAMS",102,7,5,true},
	};
	if ((result=Require(IsCanonicalPathWithinRoot(
		L"\\??\\c:\\users\\admin\\start menu\\Programs\\Tool.lnk",
		roots[0].canonicalPath),73)))
		return result;
	if ((result=Require(!IsCanonicalPathWithinRoot(
		L"\\??\\C:\\USERS\\ADMIN\\START MENUEVIL\\Tool.lnk",
		roots[0].canonicalPath),74)))
		return result;
	if ((result=Require(SelectCanonicalWatchRoot(
		L"\\??\\C:\\USERS\\ADMIN\\START MENU\\PROGRAMS\\Tool.lnk",
		roots,sizeof(roots)/sizeof(roots[0]))==1,75)))
		return result;
	// A path validated under a redirected old root cannot bind to the new root.
	if ((result=Require(SelectCanonicalWatchRoot(
		L"\\??\\D:\\REDIRECTED\\START MENU\\Tool.lnk",roots,
		sizeof(roots)/sizeof(roots[0]))==-1,76)))
		return result;
	// Shell namespace entries have no filesystem source and must bypass this
	// cache unless a real canonical source is added explicitly.
	if ((result=Require(SelectCanonicalWatchRoot(
		L"shell:::{4234d49b-0245-4df3-b780-3893943456e1}",roots,
		sizeof(roots)/sizeof(roots[0]))==-1,77)))
		return result;

	WatchBindingIdentity binding={WATCH_START_MENU,101,7,5};
	WatchBindingIdentity sameBinding={WATCH_START_MENU,101,7,5};
	if ((result=Require(WatchBindingMatches(binding,sameBinding),78)))
		return result;
	WatchBindingIdentity changedBinding=binding;
	changedBinding.rootIdentity++;
	if ((result=Require(!WatchBindingMatches(binding,changedBinding),79)))
		return result;
	changedBinding=binding;
	changedBinding.identityGeneration++;
	if ((result=Require(!WatchBindingMatches(binding,changedBinding),80)))
		return result;
	changedBinding=binding;
	changedBinding.sourceGeneration++;
	if ((result=Require(!WatchBindingMatches(binding,changedBinding),81)))
		return result;

	RequiredMetroValueState metro={true,true,true,true,true};
	if ((result=Require(RequiredMetroValueReady(metro),82)))
		return result;
	bool *requiredMetroStages[]={&metro.callSucceeded,&metro.objectPresent,
		&metro.typeValid,&metro.valuePresent};
	for (size_t i=0;i<sizeof(requiredMetroStages)/sizeof(requiredMetroStages[0]);i++)
	{
		*requiredMetroStages[i]=false;
		if ((result=Require(!RequiredMetroValueReady(metro),
			83+static_cast<int>(i))))
			return result;
		*requiredMetroStages[i]=true;
	}
	metro.valueRequired=false;
	metro.valuePresent=false;
	if ((result=Require(RequiredMetroValueReady(metro),87)))
		return result;

	CachedMetadataAdmissionState metadata={};
	metadata.mainThread=true;
	metadata.pathPresent=true;
	metadata.forceValidation=false;
	metadata.watchBaselineReady=true;
	metadata.pathCoveredByWatchIdentity=true;
	metadata.entryStable=true;
	metadata.requestedFlagsComplete=true;
	metadata.validatedPathGeneration=9;
	metadata.currentPathGeneration=9;
	if ((result=Require(CanUseCachedFileMetadata(metadata),45)))
		return result;
	bool *metadataConditions[]={&metadata.mainThread,&metadata.pathPresent,
		&metadata.watchBaselineReady,&metadata.pathCoveredByWatchIdentity,
		&metadata.entryStable,&metadata.requestedFlagsComplete};
	for (size_t i=0;i<sizeof(metadataConditions)/sizeof(metadataConditions[0]);i++)
	{
		*metadataConditions[i]=false;
		if ((result=Require(!CanUseCachedFileMetadata(metadata),
			46+static_cast<int>(i))))
			return result;
		*metadataConditions[i]=true;
	}
	metadata.forceValidation=true;
	if ((result=Require(!CanUseCachedFileMetadata(metadata),52)))
		return result;
	metadata.forceValidation=false;
	metadata.validatedPathGeneration=8;
	if ((result=Require(!CanUseCachedFileMetadata(metadata),53)))
		return result;
	metadata.validatedPathGeneration=0;
	if ((result=Require(!CanUseCachedFileMetadata(metadata),54)))
		return result;
	if ((result=Require(NextNonzeroEpoch(41)==42,55)))
		return result;
	if ((result=Require(NextNonzeroEpoch(UINT64_MAX)==1,56)))
		return result;

	EnvironmentDiscoveryState environment={};
	environment.powerCapabilitiesRequired=true;
	environment.powerCapabilitiesSucceeded=true;
	environment.hardwareProfileRequired=true;
	environment.hardwareProfileSucceeded=true;
	environment.switchUserPolicyRequired=true;
	environment.switchUserPolicySucceeded=true;
	environment.rootPathsSucceeded=true;
	environment.rootPathClonesSucceeded=true;
	if ((result=Require(DecideEnvironmentPublication(environment)==
		PUBLISH_DISCOVERED_ENVIRONMENT,60)))
		return result;

	bool *requiredResults[]={&environment.powerCapabilitiesSucceeded,
		&environment.hardwareProfileSucceeded,&environment.switchUserPolicySucceeded,
		&environment.rootPathsSucceeded,&environment.rootPathClonesSucceeded};
	for (size_t i=0;i<sizeof(requiredResults)/sizeof(requiredResults[0]);i++)
	{
		int retainedEnvironment=7;
		*requiredResults[i]=false;
		const EnvironmentPublicationDecision decision=
			DecideEnvironmentPublication(environment);
		if (decision==PUBLISH_DISCOVERED_ENVIRONMENT)
			retainedEnvironment=11;
		if ((result=Require(decision==KEEP_PREVIOUS_ENVIRONMENT &&
			retainedEnvironment==7,
			61+static_cast<int>(i))))
			return result;
		*requiredResults[i]=true;
	}

	// A probe explicitly marked unnecessary is not a hidden publication
	// dependency; this is how disabled sleep/hibernate policy remains cacheable.
	environment.powerCapabilitiesRequired=false;
	environment.powerCapabilitiesSucceeded=false;
	if ((result=Require(DecideEnvironmentPublication(environment)==
		PUBLISH_DISCOVERED_ENVIRONMENT,70)))
		return result;

	puts("A4S native cache-state fault-injection gates passed.");
	return 0;
}
