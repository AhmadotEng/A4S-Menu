#pragma once

#include <Windows.h>
#include <stdint.h>

#include "A4SProductIdentity.h"

// Increment the major word for an incompatible table or message change. A
// host intentionally requires an exact product version as well as this ABI.
#define A4S_MENU_ABI_VERSION       UINT32_C(0x00040000)
#define A4S_MENU_PRODUCT_VERSION   UINT32_C(0x00010000)

enum A4SMenuDllStatus : UINT32
{
	A4S_MENU_DLL_STATUS_READY = 1,
	A4S_MENU_DLL_STATUS_FAILED = 2,
	A4S_MENU_DLL_STATUS_DISARMED = 3,
};

// A4S_DLL_BOOTSTRAP_MESSAGE_W is posted to the validated taskbar HWND after
// the WH_GETMESSAGE hook is installed:
//   wParam = the host HWND that owns this attempt
//   lParam = the nonzero, per-attempt 64-bit cookie published on that HWND
// The Explorer callback captures this pair before initialization and never
// substitutes a later host's cookie while that attempt is in flight.

// A4S_DLL_STATUS_MESSAGE_W payload:
//   wParam low 32 bits = A4SMenuDllStatus
//   wParam high 32 bits = the notifying Explorer process ID
//   lParam = the nonzero, per-attempt 64-bit cookie published on the host HWND
// The host accepts only the cookie for its current validated Explorer attempt
// and only transitions that are legal from its current state. This rejects
// stale attempts and accidental registered-message traffic. Processes running
// as the same user/integrity remain inside the product's trust boundary.

enum A4SMenuCommand : UINT32
{
	A4S_MENU_COMMAND_TOGGLE = 1,
	A4S_MENU_COMMAND_EXIT = 2,
	// Close transient UI before the interactive desktop is suspended or locked.
	A4S_MENU_COMMAND_SUSPEND_INPUT = 3,
	// Re-establish the low-level Windows-key route after the interactive desktop
	// returns. Failure disarms the product so native Start remains available.
	A4S_MENU_COMMAND_REFRESH_INPUT = 4,
};

// A4S_MENU_COMMAND_MESSAGE_W payload:
//   wParam = A4SMenuCommand
//   lParam = 0

enum A4SMenuHostControl : UINT32
{
	A4S_MENU_HOST_CONTROL_TOGGLE = 1,
	A4S_MENU_HOST_CONTROL_EXIT = 2,
	A4S_MENU_HOST_CONTROL_REHOOK = 3,
	A4S_MENU_HOST_CONTROL_STATUS = 4,
	A4S_MENU_HOST_CONTROL_RESET_SAFETY = 5,
};

enum A4SMenuHostStatus : UINT32
{
	A4S_MENU_HOST_STATUS_STARTING = 1,
	A4S_MENU_HOST_STATUS_INJECTING = 2,
	A4S_MENU_HOST_STATUS_READY = 3,
	A4S_MENU_HOST_STATUS_FAILED = 4,
	A4S_MENU_HOST_STATUS_STOPPING = 5,
	A4S_MENU_HOST_STATUS_SAFETY_DISABLED = 6,
};

// This function is called in the host's mapping of A4SMenu.dll. It must only
// send the process-independent shutdown request to the supplied taskbar HWND;
// Explorer-owned cleanup occurs in Explorer's mapping of the DLL.
typedef BOOL (WINAPI *A4SMenuRequestShutdownFn)(HWND taskbarWindow);

struct A4SMenuApi
{
	UINT32 cbSize;
	UINT32 abiVersion;
	UINT32 productVersion;
	UINT32 reserved;
	A4SMenuRequestShutdownFn RequestShutdown;
};

typedef const A4SMenuApi *(WINAPI *A4SMenuGetApiFn)(UINT32 requestedAbi);
typedef LRESULT (CALLBACK *A4SMenuHookInjectFn)(int code, WPARAM wParam, LPARAM lParam);

#ifdef __cplusplus
extern "C"
{
#endif

#ifdef A4S_MENU_API_EXPORTS
#define A4S_MENU_API __declspec(dllexport)
#else
#define A4S_MENU_API __declspec(dllimport)
#endif

A4S_MENU_API const A4SMenuApi *WINAPI A4SMenu_GetApi(UINT32 requestedAbi);
A4S_MENU_API LRESULT CALLBACK A4SMenu_HookInject(int code, WPARAM wParam, LPARAM lParam);

#undef A4S_MENU_API

#ifdef __cplusplus
}
#endif
