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
	// Inject WaitForMultipleObjects and FindNextChangeNotification failures
	// independently. Either failure must make publication impossible.
	if ((result=Require(!RequiredFolderWatchesReady(full,full,false,true,false),30)))
		return result;
	if ((result=Require(!RequiredFolderWatchesReady(full,full,true,false,false),31)))
		return result;
	if ((result=Require(!RequiredFolderWatchesReady(full,full,true,true,true),32)))
		return result;
	if ((result=Require(RequiredFolderWatchesReady(base,
		base|WATCH_DESKTOP,true,true,false),33)))
		return result;
	if ((result=Require(NextNonzeroEpoch(41)==42,34)))
		return result;
	if ((result=Require(NextNonzeroEpoch(UINT64_MAX)==1,35)))
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
		PUBLISH_DISCOVERED_ENVIRONMENT,40)))
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
			41+static_cast<int>(i))))
			return result;
		*requiredResults[i]=true;
	}

	// A probe explicitly marked unnecessary is not a hidden publication
	// dependency; this is how disabled sleep/hibernate policy remains cacheable.
	environment.powerCapabilitiesRequired=false;
	environment.powerCapabilitiesSucceeded=false;
	if ((result=Require(DecideEnvironmentPublication(environment)==
		PUBLISH_DISCOVERED_ENVIRONMENT,50)))
		return result;

	puts("A4S native cache-state fault-injection gates passed.");
	return 0;
}
