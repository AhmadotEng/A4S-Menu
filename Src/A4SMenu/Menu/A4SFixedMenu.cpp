// Fixed product menu graph. The general Open-Shell custom-menu parser remains
// available to upstream builds, but it is not part of A4SMenu.dll.

#include "stdafx.h"
#include "CustomMenu.h"
#include "MenuContainer.h"

namespace
{
	StdMenuItem g_A4SPowerMenu[]=
	{
		{L"switch_user",MENU_SWITCHUSER,NULL,NULL,L"S&witch user",
			L"Switch users without closing programs.",L"none"},
		{L"logoff",MENU_LOGOFF,NULL,NULL,L"Sign out",
			L"Close programs and sign out.",L"none"},
		{NULL,MENU_SEPARATOR},
		{L"lock",MENU_LOCK,NULL,NULL,L"L&ock",L"Lock this computer.",L"none"},
		{L"sleep",MENU_SLEEP,NULL,NULL,L"&Sleep",
			L"Keeps your session in memory and puts the computer in a low-power state so that you can quickly resume working.",L"none"},
		{NULL,MENU_SEPARATOR},
		{L"restart",MENU_RESTART,NULL,NULL,L"&Restart",
			L"Closes all open programs, shuts down Windows, and then starts Windows again.",L"none"},
		{NULL,MENU_LAST},
	};

	StdMenuItem g_A4SRootMenu[]=
	{
		{NULL,MENU_COLUMN_PADDING},
		{NULL,MENU_PROGRAMS,&FOLDERID_Programs,&FOLDERID_CommonPrograms,
			L"&Programs",L"Opens a list of your programs.",L"none",NULL,
			StdMenuItem::MENU_ITEMS_FIRST},
		{L"search_box",MENU_SEARCH_BOX,NULL,NULL,L"Search programs and files",
			NULL,L"none",NULL,StdMenuItem::MENU_TRACK|StdMenuItem::MENU_OPENUP},
		{NULL,MENU_COLUMN_BREAK},
		{NULL,MENU_USERFILES,&FOLDERID_UsersFiles,NULL,NULL,
			L"Contains folders for Documents, Pictures, Music, and other files that belong to you.",
			NULL,NULL,StdMenuItem::MENU_NOEXPAND},
		{NULL,MENU_USERDOCUMENTS,&FOLDERID_Documents,NULL,NULL,
			L"Contains letters, reports, and other documents and files.",
			NULL,NULL,StdMenuItem::MENU_NOEXPAND},
		{NULL,MENU_CUSTOM,&FOLDERID_Downloads,NULL,NULL,
			L"Find Internet downloads and links to favorite websites.",
			NULL,NULL,StdMenuItem::MENU_NOEXPAND},
		{NULL,MENU_SEPARATOR},
		{NULL,MENU_COMPUTER,&FOLDERID_ComputerFolder,NULL,NULL,NULL,NULL,NULL,
			StdMenuItem::MENU_NOEXPAND},
		{NULL,MENU_SEPARATOR},
		{NULL,MENU_CONTROLPANEL,&FOLDERID_ControlPanelFolder,NULL,L"&Control Panel",
			L"Change settings and customize the functionality of your computer.",
			NULL,NULL,StdMenuItem::MENU_NOEXPAND},
		{L"pc_settings",MENU_PCSETTINGS,NULL,NULL,L"Settings",L"",
			NULL,L"shell:appsfolder\\windows.immersivecontrolpanel_cw5n1h2txyewy!microsoft.windows.immersivecontrolpanel",
			StdMenuItem::MENU_NOEXPAND},
		{L"cmd.exe",MENU_CUSTOM,NULL,NULL,L"Command Prompt",NULL,L"imageres.dll,11",
			NULL,0},
		{L"run",MENU_RUN,NULL,NULL,L"&Run...",
			L"Opens a program, folder, document, or web site.",L"imageres.dll,100",
			NULL,StdMenuItem::MENU_NOEXPAND},
		{NULL,MENU_COLUMN_PADDING},
		{NULL,MENU_SHUTDOWN_BUTTON,NULL,NULL,L"Sh&ut down",
			L"Closes all apps and turns off the PC.",L"none",NULL,
			StdMenuItem::MENU_SPLIT_BUTTON,g_A4SPowerMenu},
		{NULL,MENU_LAST},
	};
}

SpecialFolder g_SpecialFolders[]=
{
	{&FOLDERID_Games,SpecialFolder::FOLDER_NONEWFOLDER},
	{&FOLDERID_ComputerFolder,SpecialFolder::FOLDER_NONEWFOLDER},
	{&FOLDERID_RecycleBinFolder,SpecialFolder::FOLDER_NOSUBFOLDERS|SpecialFolder::FOLDER_NODROP},
	{&FOLDERID_NetworkFolder,SpecialFolder::FOLDER_NODROP},
	{&FOLDERID_ConnectionsFolder,SpecialFolder::FOLDER_NODROP|SpecialFolder::FOLDER_NOPATH},
	{&FOLDERID_Recent,SpecialFolder::FOLDER_NODROP},
	{&FOLDERID_ControlPanelFolder,SpecialFolder::FOLDER_NODROP},
	{&FOLDERID_PrintersFolder,SpecialFolder::FOLDER_NODROP},
	{&FOLDERID_HomeGroup,SpecialFolder::FOLDER_NODROP},
	{NULL}
};

void InitializeSpecialFolders( void )
{
	static bool initialized=false;
	if (initialized)
		return;
	initialized=true;
	for (int i=0;g_SpecialFolders[i].folder;i++)
	{
		CComPtr<IShellItem> item;
		if (SUCCEEDED(ShGetKnownFolderItem(*g_SpecialFolders[i].folder,&item)) && item)
		{
			CComString path;
			item->GetDisplayName(SIGDN_DESKTOPABSOLUTEPARSING,&path);
			path.MakeUpper();
			Strcpy(g_SpecialFolders[i].PATH,_countof(g_SpecialFolders[i].PATH),path);
		}
	}
}

const StdMenuItem *ParseCustomMenu( unsigned int &rootSettings )
{
	rootSettings=0;
	return g_A4SRootMenu;
}
