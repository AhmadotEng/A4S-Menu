#pragma once

// Runtime names are split at compile time so the product build can coexist
// with an installed Open-Shell build without sharing registry state, caches,
// window classes, registered messages, clipboard formats, or AppUserModel IDs.
#ifdef A4S_PRODUCT
#include "..\\..\\A4SMenu\\Shared\\A4SProductIdentity.h"
#define A4S_MENU_REG_ROOT             L"Software\\A4SMenu\\Menu"
#define A4S_MENU_REG_SETTINGS         L"Software\\A4SMenu\\Menu\\Settings"
#define A4S_MENU_REG_ORDER            L"Software\\A4SMenu\\Menu\\Order"
#define A4S_MENU_REG_MRU              L"Software\\A4SMenu\\Menu\\MRU"
#define A4S_SHARED_MACHINE_REG        L"Software\\A4SMenu\\Shared"
#define A4S_MENU_DATA_DIR             L"%LOCALAPPDATA%\\A4SMenu"
#define A4S_MENU_CACHE_DB             L"%LOCALAPPDATA%\\A4SMenu\\DataCache.db"
#define A4S_MENU_CACHE_LOG            L"%LOCALAPPDATA%\\A4SMenu\\DataCache.txt"
#define A4S_MENU_STARTUP_LOG          L"Software\\A4SMenu\\Menu\\Settings|LogStartup|%LOCALAPPDATA%\\A4SMenu\\StartupLog.txt"
#define A4S_MENU_PINNED_DIR           L"%APPDATA%\\A4SMenu\\Pinned"
#define A4S_MENU_USER_WINDOW_CLASS    L"A4SMenu.CUserWindow"
#define A4S_MENU_CONTAINER_CLASS      L"A4SMenu.CMenuContainer"
#define A4S_MENU_FADER_CLASS          L"A4SMenu.CMenuFader"
#define A4S_MENU_START_BUTTON_CLASS   L"A4SMenu.CStartButton"
#define A4S_MENU_OWNER_WINDOW_CLASS   L"A4SMenu.COwnerWindow"
#define A4S_MENU_START_MESSAGE        A4S_MENU_COMMAND_MESSAGE_W
#define A4S_MENU_METRO_CLIPBOARD      L"A4SMenu.MetroLink.v1"
#define A4S_MENU_SETTINGS_APP_ID      L"A4SMenu.Settings"
bool IsA4SRuntimeReady( void );
#else
#define A4S_MENU_REG_ROOT             L"Software\\OpenShell\\StartMenu"
#define A4S_MENU_REG_SETTINGS         L"Software\\OpenShell\\StartMenu\\Settings"
#define A4S_MENU_REG_ORDER            L"Software\\OpenShell\\StartMenu\\Order"
#define A4S_MENU_REG_MRU              L"Software\\OpenShell\\StartMenu\\MRU"
#define A4S_SHARED_MACHINE_REG        L"Software\\OpenShell\\OpenShell"
#define A4S_MENU_DATA_DIR             L"%LOCALAPPDATA%\\OpenShell"
#define A4S_MENU_CACHE_DB             L"%LOCALAPPDATA%\\OpenShell\\DataCache.db"
#define A4S_MENU_CACHE_LOG            L"%LOCALAPPDATA%\\OpenShell\\DataCache.txt"
#define A4S_MENU_STARTUP_LOG          L"Software\\OpenShell\\StartMenu\\Settings|LogStartup|%LOCALAPPDATA%\\OpenShell\\StartupLog.txt"
#define A4S_MENU_PINNED_DIR           L"%APPDATA%\\OpenShell\\Pinned"
#define A4S_MENU_USER_WINDOW_CLASS    L"OpenShell.CUserWindow"
#define A4S_MENU_CONTAINER_CLASS      L"OpenShell.CMenuContainer"
#define A4S_MENU_FADER_CLASS          L"OpenShell.CMenuFader"
#define A4S_MENU_START_BUTTON_CLASS   L"OpenShell.CStartButton"
#define A4S_MENU_OWNER_WINDOW_CLASS   L"OpenShell.COwnerWindow"
#define A4S_MENU_START_MESSAGE        L"OpenShellMenu.StartMenuMsg"
#define A4S_MENU_METRO_CLIPBOARD      L"OpenShell.MetroLink"
#define A4S_MENU_SETTINGS_APP_ID      L"OpenShell.StartMenu.Settings"
#endif
