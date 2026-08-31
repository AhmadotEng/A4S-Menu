#pragma once

// Product-facing names live here so the host and Explorer DLL cannot silently
// drift back to an Open-Shell identity. Keep these strings versioned whenever
// their message payload or window contract changes.
#define A4S_PRODUCT_NAME_W                    L"A4SMenu"
#define A4S_PRODUCT_NAME_A                    "A4SMenu"
#define A4S_PRODUCT_HOST_FILENAME_W           L"A4SMenuHost.exe"
#define A4S_PRODUCT_DLL_FILENAME_W            L"A4SMenu.dll"

#define A4S_HOST_WINDOW_CLASS_W               L"A4SMenu.Host.Window.v1"
#define A4S_HOST_WINDOW_TITLE_W               L"A4SMenuHost"
#define A4S_HOST_MUTEX_PREFIX_W               L"Local\\A4SMenu.Host.Instance.v1"
#define A4S_HOST_ATTEMPT_COOKIE_PROPERTY_W    L"A4SMenu.Host.AttemptCookie.v1"

#define A4S_HOST_CONTROL_MESSAGE_W            L"A4SMenu.Host.Control.v1"
#define A4S_DLL_BOOTSTRAP_MESSAGE_W            L"A4SMenu.Dll.Bootstrap.v1"
#define A4S_DLL_STATUS_MESSAGE_W              L"A4SMenu.Dll.Status.v2"
#define A4S_MENU_COMMAND_MESSAGE_W            L"A4SMenu.Menu.Command.v1"
#define A4S_TASKBAR_CREATED_MESSAGE_W         L"TaskbarCreated"

#define A4S_DLL_GET_API_EXPORT_A              "A4SMenu_GetApi"
#define A4S_DLL_HOOK_INJECT_EXPORT_A          "A4SMenu_HookInject"

#define A4S_PRODUCT_VERSION_MAJOR             1
#define A4S_PRODUCT_VERSION_MINOR             0
#define A4S_PRODUCT_VERSION_PATCH             0
#define A4S_PRODUCT_VERSION_BUILD             0
#define A4S_PRODUCT_VERSION_STR_A             "1.0.0.0"
#define A4S_PRODUCT_VERSION_STR_W             L"1.0.0.0"
