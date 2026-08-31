// Classic Shell (c) 2009-2017, Ivo Beltchev
// Open-Shell (c) 2017-2018, The Open-Shell Team
// Confidential information of Ivo Beltchev. Not for disclosure or distribution without prior written consent from the author

// dllmain.cpp : Defines the entry point for the DLL application.

#include "stdafx.h"
#include "StartMenuDLL.h"
#include "Settings.h"
#include "Translations.h"
#include "ResourceHelper.h"
#include "StringSet.h"
#include "resource.h"
#include "..\Lib\resource.h"
#include "SettingsUI.h"
#include "SkinManager.h"
#include "uxtheme.h"
#include "FNVHash.h"
#include "MenuContainer.h"
#include "SearchManager.h"
#include "LogManager.h"
#include <dwmapi.h>

#pragma comment(linker, \
	"\"/manifestdependency:type='Win32' "\
	"name='Microsoft.Windows.Common-Controls' "\
	"version='6.0.0.0' "\
	"processorArchitecture='*' "\
	"publicKeyToken='6595b64144ccf1df' "\
	"language='*'\"")

static int g_LoadDialogs[]=
{
	IDD_SETTINGS,0x04000000,
	IDD_SETTINGSTREE,0x04000000,
	IDD_BROWSEFORICON,0x04000000,
	IDD_LANGUAGE,0x04000000,
	IDD_SKINSETTINGS,0x04000000,
	IDD_CUSTOMTREE,0x04000000,
	IDD_CUSTOMMENU,0x04000000,
	IDD_CUSTOMMENU7,0x04000000,
	IDD_STYLESETTINGS,0x04000000,
	IDD_CUSTOMLIST,0x04000000,
	IDD_PROGRESS,0x04000004,
	0
};

#ifndef A4S_PRODUCT
static HANDLE g_DllInitThread;

static DWORD CALLBACK DllInitThread( void* )
{
	CoInitialize(NULL);
	InitSettings();

	// This environment fork is a fixed English, two-binary product. All menu
	// text overrides are embedded as resource 1/L10N in the menu DLL.
	ParseTranslations(NULL,L"en-US");
	LoadTranslationResources(g_Instance,g_LoadDialogs);

	CoUninitialize();
	return 0;
}
#else
// Product initialization is intentionally not started from DllMain.  The DLL is
// loaded into A4SMenuHost once so the host can inspect its ABI, and a second time
// into Explorer by the taskbar-thread hook.  Running COM, settings, translations,
// logging, or worker creation under either process' loader lock makes both paths
// fragile.  A4SMenu_HookInject performs the explicit initialization instead.
static INIT_ONCE g_A4SRuntimeInitOnce=INIT_ONCE_STATIC_INIT;

static BOOL CALLBACK InitA4SRuntimeOnce( PINIT_ONCE, PVOID, PVOID * )
{
	HRESULT hr=CoInitializeEx(NULL,COINIT_APARTMENTTHREADED);
	if (FAILED(hr) && hr!=RPC_E_CHANGED_MODE)
	{
		SetLastError(HRESULT_CODE(hr));
		return FALSE; // InitOnce permits a later HookInject call to retry.
	}

	InitSettings();
	ParseTranslations(NULL,L"en-US");
	// Product text overrides are embedded in A4SMenu.dll. Settings and skin
	// dialogs are not product surfaces, so do not preload their templates.
	LoadTranslationResources(g_Instance,NULL);

	// If this call created the taskbar thread's STA, retain that apartment for
	// the pinned product lifetime because later menu shell work runs on the same
	// thread. Balance only S_FALSE, which added a reference to an existing STA.
	if (hr==S_FALSE)
		CoUninitialize();
	return TRUE;
}

bool EnsureA4SRuntimeInitialized( void )
{
	return InitOnceExecuteOnce(&g_A4SRuntimeInitOnce,InitA4SRuntimeOnce,NULL,NULL)!=FALSE;
}
#endif

STARTMENUAPI void WaitDllInitThread( void )
{
#ifdef A4S_PRODUCT
	// Kept for source compatibility with shared code. Product initialization is
	// driven only by A4SMenu_HookInject, outside loader lock.
	ATLASSERT(FALSE);
#else
	ATLASSERT(g_DllInitThread);
	WaitForSingleObject(g_DllInitThread,INFINITE);
#endif
}

extern "C" BOOL WINAPI DllMain( HINSTANCE hInstance, DWORD dwReason, LPVOID lpReserved )
{
#ifdef A4S_PRODUCT
	if (dwReason==DLL_PROCESS_ATTACH)
	{
		g_Instance=hInstance;
	}
#else
	if (dwReason==DLL_PROCESS_ATTACH)
	{
		LogToFile(STARTUP_LOG,L"StartMenu DLL: DLL_PROCESS_ATTACH");
		g_Instance=hInstance;
		g_DllInitThread=CreateThread(NULL,0,DllInitThread,NULL,0,NULL);
	}
	if (dwReason==DLL_PROCESS_DETACH)
	{
		LogToFile(STARTUP_LOG,L"StartMenu DLL: DLL_PROCESS_DETACH");
	}
#endif

	return TRUE;
}
