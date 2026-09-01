// Fixed settings catalog for A4SMenu.dll. This is a runtime compatibility
// layer for the shared menu renderer, not a user-editable settings surface.

#include "stdafx.h"
#include "SettingsUI.h"
#include "A4SMenuProfile.h"
#include "A4SProductRuntime.h"
#include "Settings.h"

#define A4S_WIDEN_IMPL(value) L##value
#define A4S_WIDEN(value) A4S_WIDEN_IMPL(value)
#define A4S_FIXED_FLAGS (CSetting::FLAG_HIDDEN|CSetting::FLAG_NOSAVE|CSetting::FLAG_FORCED_DEFAULT|CSetting::FLAG_LOCKED_GP)
#define A4S_BOOL(name,value) {A4S_WIDEN(#name),CSetting::TYPE_BOOL,0,0,value,A4S_FIXED_FLAGS}
#define A4S_INT(name,value) {A4S_WIDEN(#name),CSetting::TYPE_INT,0,0,value,A4S_FIXED_FLAGS}
#define A4S_HOTKEY(name,value) {A4S_WIDEN(#name),CSetting::TYPE_HOTKEY,0,0,value,A4S_FIXED_FLAGS}
#define A4S_COLOR(name,value) {A4S_WIDEN(#name),CSetting::TYPE_COLOR,0,0,value,A4S_FIXED_FLAGS}
#define A4S_STRING(name,value) {A4S_WIDEN(#name),CSetting::TYPE_STRING,0,0,value,A4S_FIXED_FLAGS}
#define A4S_MULTI(name,value) {A4S_WIDEN(#name),CSetting::TYPE_MULTISTRING,0,0,value,A4S_FIXED_FLAGS}

namespace
{
	CSetting g_A4SSettings[]=
	{
		A4S_INT(MenuStyle,MENU_WIN7),
		A4S_BOOL(AutoStart,1),
		A4S_BOOL(EnableSettings,0),
		A4S_INT(CrashDump,0),
		A4S_INT(OldProgramsAge,48),
		A4S_INT(CompatibilityFixes,0),
		A4S_STRING(FolderStartMenu,L""),
		A4S_STRING(FolderCommonStartMenu,L""),
		A4S_STRING(FolderPrograms,L""),
		A4S_STRING(FolderCommonPrograms,L""),

		A4S_INT(MouseClick,1),
		A4S_STRING(MouseClickCommand,L""),
		A4S_INT(ShiftClick,1),
		A4S_STRING(ShiftClickCommand,L""),
		A4S_INT(WinKey,1),
		A4S_STRING(WinKeyCommand,L""),
		A4S_INT(ShiftWin,1),
		A4S_STRING(ShiftWinCommand,L""),
		A4S_INT(MiddleClick,0),
		A4S_STRING(MiddleClickCommand,L""),
		A4S_INT(Hover,0),
		A4S_STRING(HoverCommand,L""),
		A4S_INT(StartHoverDelay,1000),
		A4S_BOOL(ShiftRight,0),
		A4S_HOTKEY(CSMHotkey,0),
		A4S_HOTKEY(WSMHotkey,0),

		A4S_INT(Computer,1),
		A4S_INT(Favorites,0),
		A4S_INT(Documents,2),
		A4S_INT(MaxRecentDocuments,15),
		A4S_INT(SortRecentDocuments,0),
		A4S_INT(UserFiles,1),
		A4S_INT(UserDocuments,1),
		A4S_INT(UserPictures,1),
		A4S_INT(ControlPanel,2),
		A4S_BOOL(ControlPanelCategories,0),
		A4S_INT(Network,1),
		A4S_INT(Printers,1),
		A4S_INT(Shutdown,2),
		A4S_BOOL(LogOff,1),
		A4S_BOOL(ConfirmLogOff,0),
		A4S_BOOL(ConfirmLogOff2,0),
		A4S_BOOL(Undock,1),
		A4S_BOOL(Search,1),
		A4S_BOOL(ShowAppsMenu,0),
		A4S_BOOL(Help,1),
		A4S_BOOL(Run,1),

		A4S_INT(ProgramsStyle,PROGRAMS_INLINE),
		A4S_BOOL(AllProgramsMetro,1),
		A4S_BOOL(FoldersFirst,0),
		A4S_BOOL(OpenPrograms,0),
		A4S_INT(ProgramsMenuDelay,200),
		A4S_BOOL(HideProgramsMetro,1),
		A4S_INT(PinnedPrograms,PINNED_PROGRAMS_FAST),
		A4S_STRING(PinnedItemsPath,A4S_MENU_PINNED_DIR),
		A4S_INT(RecentPrograms,RECENT_PROGRAMS_NONE),
		A4S_BOOL(RecentMetroApps,0),
		A4S_INT(MaxRecentPrograms,0),
		A4S_BOOL(RecentProgsTop,1),
		A4S_BOOL(RecentSortName,0),
		A4S_INT(RecentProgKeys,RECENT_KEYS_DIGITS),
		A4S_BOOL(EnableJumplists,0),
		A4S_INT(MaxJumplists,10),
		A4S_INT(JumplistKeys,0),
		A4S_INT(ShutdownCommand,SHUTDOWN_TYPE_SHUTDOWN),
		A4S_STRING(ShutdownW7,L"switch_user logoff lock restart sleep"),
		A4S_BOOL(RemoteShutdown,0),
		A4S_BOOL(HybridShutdown,0),
		A4S_BOOL(SelectLastShutdown,0),
		A4S_INT(ProgramsWidth,37),
		A4S_INT(JumplistWidth,0),
		A4S_INT(MinMainHeight,0),
		A4S_BOOL(MainSortZA,0),
		A4S_BOOL(MainSortOnce,0),
		A4S_MULTI(MenuItems7,L""),

		A4S_BOOL(HighlightNew,0),
		A4S_BOOL(HighlightNewApps,0),
		A4S_INT(MenuDelay,400),
		A4S_INT(SplitMenuDelay,200),
		A4S_STRING(InfotipDelay,L"0,0"),
		A4S_STRING(FolderInfotipDelay,L"0,0"),
		A4S_BOOL(EnableDragDrop,0),
		A4S_INT(DragHideDelay,4000),
		A4S_INT(ScrollType,1),
		A4S_BOOL(SameSizeColumns,1),
		A4S_STRING(UserPicturePath,L""),
		A4S_STRING(UserPictureCommand,L""),
		A4S_STRING(UserNameCommand,L""),
		A4S_STRING(SearchFilesCommand,L"search-ms:"),
		A4S_BOOL(ExpandFolderLinks,1),
		A4S_BOOL(SingleClickFolders,0),
		A4S_BOOL(OpenTruePath,1),
		A4S_BOOL(EnableTouch,0),
		A4S_BOOL(EnableAccessibility,1),
		A4S_BOOL(ShowNextToTaskbar,1),
		A4S_BOOL(PreCacheIcons,1),
		A4S_BOOL(DelayIcons,1),
		A4S_BOOL(ReportSkinErrors,0),
		A4S_BOOL(EnableAccelerators,1),
		A4S_BOOL(AltAccelerators,0),

		A4S_INT(SearchBox,SEARCHBOX_NORMAL),
		A4S_BOOL(SearchSelect,0),
		A4S_BOOL(SearchHint,1),
		A4S_STRING(SearchHintText,L"Search programs and files"),
		A4S_BOOL(SearchTrack,0),
		A4S_INT(SearchResults,5),
		A4S_INT(SearchResultsMax,20),
		A4S_BOOL(SearchAutoComplete,1),
		A4S_BOOL(SearchPrograms,1),
		A4S_BOOL(SearchPath,1),
		A4S_BOOL(SearchMetroApps,1),
		A4S_BOOL(SearchMetroSettings,0),
		A4S_BOOL(SearchKeywords,1),
		A4S_BOOL(SearchSubWord,1),
		A4S_BOOL(SearchFiles,1),
		A4S_BOOL(SearchContents,1),
		A4S_BOOL(SearchCategories,1),
		A4S_BOOL(SearchInternet,0),
		A4S_BOOL(MoreResults,1),

		A4S_INT(SmallIconSize,20),
		A4S_INT(LargeIconSize,32),
		A4S_BOOL(InvertMetroIcons,0),
		A4S_INT(MaxMainMenuWidth,60),
		A4S_INT(MaxMenuWidth,60),
		A4S_BOOL(AlignToWorkArea,0),
		A4S_INT(HorizontalMenuOffset,0),
		A4S_INT(VerticalMenuOffset,0),
		A4S_INT(OverrideDPI,0),
		A4S_BOOL(MainMenuAnimate,0),
		A4S_INT(MainMenuAnimation,0),
		A4S_INT(MainMenuAnimationSpeed,200),
		A4S_INT(SubMenuAnimation,0),
		A4S_INT(SubMenuAnimationSpeed,200),
		A4S_BOOL(SubMenuAnimationAlways,0),
		A4S_INT(MainMenuScrollSpeed,3),
		A4S_INT(SubMenuScrollSpeed,3),
		A4S_INT(MenuFadeSpeed,400),
		A4S_STRING(MenuCaption,L""),
		A4S_STRING(MenuUsername,L""),
		A4S_BOOL(NumericSort,1),
		A4S_INT(FontSmoothing,0),
		A4S_BOOL(MenuShadow,1),
		A4S_BOOL(AeroGlass,0),
		A4S_BOOL(EnableGlass,1),
		A4S_BOOL(GlassOverride,1),
		A4S_COLOR(GlassColor,RGB(32,32,32)),
		A4S_INT(GlassIntensity,0),
		A4S_INT(GlassBlending,0),
		A4S_INT(GlassOpacity,50),

		// Compatibility keys read by shared taskbar/start-button code are locked
		// off. No product UI or resource exposes these features.
		A4S_BOOL(EnableStartButton,0),
		A4S_BOOL(AllTaskbars,0),
		A4S_STRING(StartButtonTip,L""),
		A4S_INT(StartButtonType,0),
		A4S_STRING(StartButtonPath,L""),
		A4S_INT(StartButtonSize,0),
		A4S_INT(StartButtonOffset,0),
		A4S_BOOL(StartButtonAlign,0),
		A4S_STRING(StartButtonIcon,L"none"),
		A4S_INT(StartButtonIconSize,0),
		A4S_STRING(StartButtonText,L""),
		A4S_BOOL(CustomTaskbar,0),
		A4S_INT(TaskbarLook,1),
		A4S_INT(TaskbarOpacity,85),
		A4S_COLOR(TaskbarColor,0),
		A4S_COLOR(TaskbarTextColor,0xFFFFFF),
		A4S_STRING(TaskbarTexture,L""),
		A4S_INT(TaskbarTileH,1),
		A4S_STRING(TaskbarBordersH,L"0,0"),
		A4S_INT(TaskbarTileV,1),
		A4S_STRING(TaskbarBordersV,L"0,0"),

		A4S_BOOL(SkipMetro,0),
		A4S_INT(SkipMetroCount,10),
		A4S_INT(DisableHotCorner,0),
		A4S_BOOL(OpenMouseMonitor,0),
		A4S_BOOL(CascadeAll,0),
		A4S_INT(AllProgramsDelay,400),
		A4S_INT(InitiallySelect,0),
		A4S_BOOL(HideUserPic,0),
		A4S_BOOL(EnableContextMenu,0),
		A4S_BOOL(CascadingMenu,0),
		A4S_BOOL(ShowNewFolder,0),
		A4S_BOOL(EnableExit,0),
		A4S_BOOL(EnableExplorer,0),
		A4S_STRING(ExplorerPath,L""),
		A4S_BOOL(StartScreenShortcut,0),

		A4S_STRING(SoundMain,L"MenuPopup"),
		A4S_STRING(SoundPopup,L"MenuPopup"),
		A4S_STRING(SoundCommand,L"MenuCommand"),
		A4S_STRING(SoundDrop,L"MoveMenuItem"),
		A4S_STRING(SoundButtonHover,L""),

		{NULL}
	};
	CComVariant g_A4SSourceDefaults[_countof(g_A4SSettings)-1];
	unsigned int g_A4SSourceFlags[_countof(g_A4SSettings)-1];
	bool g_A4SSourceDefaultsCaptured;

	void CaptureFixedCatalog( void )
	{
		ATLASSERT(!g_A4SSourceDefaultsCaptured);
		for (int index=0;g_A4SSettings[index].name;index++)
		{
			g_A4SSourceDefaults[index]=g_A4SSettings[index].defValue;
			g_A4SSourceFlags[index]=g_A4SSettings[index].flags;
		}
		g_A4SSourceDefaultsCaptured=true;
	}

	void RestoreFixedCatalog( void )
	{
		ATLASSERT(g_A4SSourceDefaultsCaptured);
		for (int index=0;g_A4SSettings[index].name;index++)
		{
			CSetting &setting=g_A4SSettings[index];
			setting.defValue=g_A4SSourceDefaults[index];
			setting.value=g_A4SSourceDefaults[index];
			setting.flags=g_A4SSourceFlags[index]|CSetting::FLAG_DEFAULT;
		}
	}

	void SetFixedDefault( const wchar_t *name, const CComVariant &value )
	{
		for (CSetting *setting=g_A4SSettings;setting->name;setting++)
			if (wcscmp(setting->name,name)==0)
			{
				setting->defValue=value;
				setting->value=value;
				return;
			}
		ATLASSERT(FALSE);
	}

	void LockFixedCatalog( void )
	{
		// Reassert every source-owned default and lock after the immutable reset,
		// dynamic system timing, and profile overrides have all been applied.
		for (CSetting *setting=g_A4SSettings;setting->name;setting++)
		{
			setting->value=setting->defValue;
			setting->flags|=CSetting::FLAG_DEFAULT|CSetting::FLAG_FORCED_DEFAULT|
				CSetting::FLAG_LOCKED_GP|CSetting::FLAG_HIDDEN|CSetting::FLAG_NOSAVE;
			setting->flags&=~CSetting::FLAG_WARNING;
		}
	}
}

void UpgradeSettings( bool bShared )
{
	UNREFERENCED_PARAMETER(bShared);
}

void UpdateSettings( void )
{
	// Generic loading can change both value and defValue through HKLM/HKCU
	// policy/default records. Start again from the immutable source snapshot.
	RestoreFixedCatalog();

	DWORD delay=400;
	if (SystemParametersInfo(SPI_GETMENUSHOWDELAY,0,&delay,0))
		SetFixedDefault(L"MenuDelay",CComVariant(static_cast<int>(delay)));
	if (SystemParametersInfo(SPI_GETMOUSEHOVERTIME,0,&delay,0))
		SetFixedDefault(L"AllProgramsDelay",CComVariant(static_cast<int>(delay)));

	A4SMenuProfile::ApplyLockedSettings();
	LockFixedCatalog();
	SetSettingsStyle(CSetting::FLAG_MENU_WIN7,CSetting::FLAG_MENU_MASK);
}

void InitSettings( void )
{
	CaptureFixedCatalog();
	SetSettingsRegPathOverride(COMPONENT_MENU,L"Software\\A4SMenu\\Menu",L"Software\\Policies\\A4SMenu\\Menu");
	SetSettingsRegPathOverride(COMPONENT_SHARED,L"Software\\A4SMenu\\Shared",L"Software\\Policies\\A4SMenu\\Shared");
	::InitSettings(g_A4SSettings,COMPONENT_MENU,NULL);
}

void ClosingSettings( HWND hWnd, int flags, int command )
{
	UNREFERENCED_PARAMETER(hWnd);
	UNREFERENCED_PARAMETER(flags);
	UNREFERENCED_PARAMETER(command);
}

void SettingChangedCallback( const CSetting *pSetting )
{
	UNREFERENCED_PARAMETER(pSetting);
}

void EditSettings( bool bModal, int tab )
{
	UNREFERENCED_PARAMETER(bModal);
	UNREFERENCED_PARAMETER(tab);
}

bool DllImportSettingsXml( const wchar_t *fname )
{
	UNREFERENCED_PARAMETER(fname);
	return false;
}

bool DllExportSettingsXml( const wchar_t *fname )
{
	UNREFERENCED_PARAMETER(fname);
	return false;
}

#undef A4S_MULTI
#undef A4S_STRING
#undef A4S_COLOR
#undef A4S_HOTKEY
#undef A4S_INT
#undef A4S_BOOL
#undef A4S_FIXED_FLAGS
#undef A4S_WIDEN
#undef A4S_WIDEN_IMPL
