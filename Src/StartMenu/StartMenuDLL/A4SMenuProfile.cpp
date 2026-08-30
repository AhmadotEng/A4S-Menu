#include "stdafx.h"
#include "A4SMenuProfile.h"
#include "Settings.h"
#include "SettingsUI.h"

namespace
{
	const wchar_t kBuildId[]=L"A4SMenu/phase4-source-profile/10";

	const wchar_t kRightColumnModel[]=
		L"Item1.Command=user_files\n"
		L"Item1.Settings=NOEXPAND\n"
		L"Item2.Command=user_documents\n"
		L"Item2.Settings=NOEXPAND\n"
		L"Item3.Command=downloads\n"
		L"Item3.Settings=NOEXPAND\n"
		L"Item4.Command=separator\n"
		L"Item5.Command=computer\n"
		L"Item5.Settings=NOEXPAND\n"
		L"Item6.Command=separator\n"
		L"Item7.Command=control_panel\n"
		L"Item7.Settings=NOEXPAND\n"
		L"Item8.Command=pc_settings\n"
		L"Item8.Label=Settings\n"
		L"Item9.Command=cmd.exe\n"
		L"Item9.Label=Command Prompt\n"
		L"Item9.Icon=imageres.dll,11\n"
		L"Item10.Command=run\n";

	void ForceSetting( const wchar_t *name, const CComVariant &value )
	{
		CSetting *setting=FindSetting(name);
		if (!setting)
			return;
		if (setting->pLinkTo)
			setting=setting->pLinkTo;

		setting->defValue=value;
		setting->value=value;
		setting->flags|=CSetting::FLAG_DEFAULT|CSetting::FLAG_FORCED_DEFAULT|
			CSetting::FLAG_LOCKED_GP|CSetting::FLAG_HIDDEN|CSetting::FLAG_NOSAVE;
		setting->flags&=~CSetting::FLAG_WARNING;
	}

	void ForceBool( const wchar_t *name, bool value )
	{
		ForceSetting(name,CComVariant(value?1:0));
	}

	void ForceInt( const wchar_t *name, int value )
	{
		ForceSetting(name,CComVariant(value));
	}

	void ForceString( const wchar_t *name, const wchar_t *value )
	{
		ForceSetting(name,CComVariant(value));
	}

	void SetSolidBitmap( MenuBitmap &bitmap, COLORREF color )
	{
		bitmap.Reset();
		bitmap=color;
	}

	void SetItemColors( MenuSkin::ItemDrawSettings &item, COLORREF normal, COLORREF selected, COLORREF disabled )
	{
		item.textColors[0]=normal;
		item.textColors[1]=selected;
		item.textColors[2]=disabled;
		item.textColors[3]=disabled;
		for (int i=0;i<4;i++)
			item.textShadowColors[i]=0xFFFFFFFF;
	}

	void SetSelection( MenuSkin::ItemDrawSettings &item, COLORREF color )
	{
		item.bmpSelection.Reset();
		item.bmpSelection=color;
		memset(item.selSlicesX,0,sizeof(item.selSlicesX));
		memset(item.selSlicesY,0,sizeof(item.selSlicesY));
	}

	void SetPadding( RECT &padding, int left, int top, int right, int bottom, int dpi )
	{
		padding.left=A4SMenuProfile::Scale(left,dpi);
		padding.top=A4SMenuProfile::Scale(top,dpi);
		padding.right=A4SMenuProfile::Scale(right,dpi);
		padding.bottom=A4SMenuProfile::Scale(bottom,dpi);
	}

	void InstallMenuTypography( MenuSkin &profile, int dpi )
	{
		// The captured StartAllBack raster uses Windows 11's variable text face at
		// 13 px. DTT_COMPOSITED converts its natural ClearType geometry to grayscale
		// premultiplied coverage, retaining clean acrylic edges without color fringe.
		HFONT font=CreateFont(-A4SMenuProfile::Scale(13,dpi),0,0,0,FW_NORMAL,FALSE,FALSE,FALSE,
			DEFAULT_CHARSET,OUT_TT_PRECIS,CLIP_DEFAULT_PRECIS,CLEARTYPE_NATURAL_QUALITY,
			DEFAULT_PITCH|FF_DONTCARE,L"Segoe UI Variable Text");
		if (!font)
			return;

		std::vector<HFONT> oldFonts;
		for (int i=0;i<MenuSkin::ITEM_TYPE_COUNT;i++)
		{
			MenuSkin::ItemDrawSettings &item=profile.ItemSettings[i];
			if (item.font && item.bOwnFont && std::find(oldFonts.begin(),oldFonts.end(),item.font)==oldFonts.end())
				oldFonts.push_back(item.font);
		}
		if (profile.Search_hint_font && profile.BOwnHintFont &&
			std::find(oldFonts.begin(),oldFonts.end(),profile.Search_hint_font)==oldFonts.end())
			oldFonts.push_back(profile.Search_hint_font);
		for (std::vector<HFONT>::const_iterator it=oldFonts.begin();it!=oldFonts.end();++it)
			DeleteObject(*it);

		for (int i=0;i<MenuSkin::ITEM_TYPE_COUNT;i++)
		{
			profile.ItemSettings[i].font=font;
			profile.ItemSettings[i].bOwnFont=(i==MenuSkin::COLUMN1_ITEM);
		}
		// The native transparent EDIT does not pass through DTT_COMPOSITED. Give it
		// the same Variable Text outlines with grayscale coverage so query/hint text
		// cannot acquire colored subpixel fringes over the acrylic child surface.
		HFONT searchEdit=CreateFont(-A4SMenuProfile::Scale(13,dpi),0,0,0,FW_NORMAL,FALSE,FALSE,FALSE,
			DEFAULT_CHARSET,OUT_TT_PRECIS,CLIP_DEFAULT_PRECIS,ANTIALIASED_QUALITY,
			DEFAULT_PITCH|FF_DONTCARE,L"Segoe UI Variable Text");
		profile.Search_hint_font=searchEdit?searchEdit:font;
		profile.BOwnHintFont=searchEdit!=NULL;

		HFONT searchHeader=CreateFont(-A4SMenuProfile::Scale(16,dpi),0,0,0,FW_NORMAL,FALSE,FALSE,FALSE,
			DEFAULT_CHARSET,OUT_TT_PRECIS,CLIP_DEFAULT_PRECIS,CLEARTYPE_NATURAL_QUALITY,
			DEFAULT_PITCH|FF_DONTCARE,L"Segoe UI Variable Text");
		if (searchHeader)
		{
			profile.ItemSettings[MenuSkin::LIST_SEPARATOR].font=searchHeader;
			profile.ItemSettings[MenuSkin::LIST_SEPARATOR].bOwnFont=true;
			profile.ItemSettings[MenuSkin::LIST_SEPARATOR_SPLIT].font=searchHeader;
			profile.ItemSettings[MenuSkin::LIST_SEPARATOR_SPLIT].bOwnFont=false;
		}
	}
}

namespace A4SMenuProfile
{
	const wchar_t *GetBuildId( void )
	{
		return kBuildId;
	}

	bool IsEnabled( void )
	{
		return true;
	}

	int Scale( int value, int dpi )
	{
		return MulDiv(value,dpi,96);
	}

	int MenuWidth( int dpi )
	{
		return Scale(463,dpi);
	}

	int MenuHeight( int dpi )
	{
		return Scale(443,dpi);
	}

	int SplitX( int dpi )
	{
		return Scale(276,dpi);
	}

	void GetSearchRect( RECT &rect, int dpi )
	{
		rect.left=Scale(13,dpi);
		rect.top=Scale(404,dpi);
		rect.right=Scale(270,dpi);
		rect.bottom=Scale(430,dpi);
	}

	void GetProgramsButtonRect( RECT &rect, int dpi )
	{
		rect.left=Scale(8,dpi);
		rect.top=Scale(362,dpi);
		rect.right=Scale(261,dpi);
		rect.bottom=Scale(390,dpi);
	}

	void GetProgramsTreeRect( RECT &rect, int dpi )
	{
		rect.left=Scale(7,dpi);
		rect.top=Scale(7,dpi);
		rect.right=Scale(276,dpi);
		rect.bottom=Scale(362,dpi);
	}

	void GetMoreResultsRect( RECT &rect, int dpi )
	{
		rect.left=Scale(8,dpi);
		rect.top=Scale(362,dpi);
		rect.right=Scale(455,dpi);
		rect.bottom=Scale(391,dpi);
	}

	void GetShutdownRect( RECT &rect, int dpi )
	{
		rect.left=Scale(285,dpi);
		rect.top=Scale(404,dpi);
		rect.right=Scale(400,dpi);
		rect.bottom=Scale(430,dpi);
	}

	COLORREF BackdropTint( void )
	{
		return RGB(32,32,32);
	}

	BYTE BackdropAlpha( void )
	{
		return 128;
	}

	void ApplyLockedSettings( void )
	{
		// Product identity and activation. The native taskbar and native Start
		// button remain visually untouched.
		ForceInt(L"MenuStyle",MENU_WIN7);
		ForceBool(L"AutoStart",true);
		ForceBool(L"EnableSettings",false);
		ForceBool(L"EnableStartButton",false);
		ForceBool(L"AllTaskbars",false);
		ForceBool(L"CustomTaskbar",false);
		ForceInt(L"MouseClick",1); // OPEN_CLASSIC
		ForceInt(L"WinKey",1);     // OPEN_CLASSIC
		ForceInt(L"ShiftClick",1);
		ForceInt(L"ShiftWin",1);

		// Fixed StartAllBack-compatible model: empty normal left pane, inline
		// All Programs, fixed right links, and no jump-list/pinning subsystem.
		ForceInt(L"ProgramsStyle",PROGRAMS_INLINE);
		ForceBool(L"OpenPrograms",false);
		ForceBool(L"AllProgramsMetro",true);
		ForceBool(L"FoldersFirst",false);
		ForceInt(L"PinnedPrograms",PINNED_PROGRAMS_FAST);
		ForceInt(L"RecentPrograms",RECENT_PROGRAMS_NONE);
		ForceInt(L"MaxRecentPrograms",0);
		ForceBool(L"EnableJumplists",false);
		ForceBool(L"HighlightNew",false);
		ForceBool(L"HighlightNewApps",false);
		ForceString(L"MenuItems7",kRightColumnModel);

		// Search is part of the accepted menu, but unrelated providers and
		// tracking are removed.
		ForceInt(L"SearchBox",SEARCHBOX_NORMAL);
		ForceBool(L"SearchSelect",false);
		ForceBool(L"SearchHint",true);
		ForceString(L"SearchHintText",L"Search programs and files");
		ForceBool(L"SearchTrack",false);
		ForceBool(L"SearchPrograms",true);
		ForceBool(L"SearchPath",true);
		ForceBool(L"SearchMetroApps",true);
		ForceBool(L"SearchMetroSettings",false);
		ForceBool(L"SearchFiles",true);
		ForceBool(L"SearchInternet",false);
		ForceBool(L"MoreResults",true);

		// Match the captured power button and flyout contents. ShutdownW7 is a
		// filter; the upstream fixed model supplies the captured ordering.
		ForceInt(L"ShutdownCommand",SHUTDOWN_TYPE_SHUTDOWN);
		ForceString(L"ShutdownW7",L"switch_user logoff lock restart sleep");
		ForceBool(L"HybridShutdown",false);
		ForceBool(L"ConfirmLogOff",false);
		ForceBool(L"ConfirmLogOff2",false);
		ForceBool(L"SelectLastShutdown",false);

		// Rendering and fixed 96-DPI reference geometry. Presentation code
		// scales these values for the actual monitor DPI.
		// Retained only for compatibility with code paths that still read these
		// settings. The product HWND and pane widths are clamped directly from
		// this DLL's captured geometry below.
		ForceInt(L"ProgramsWidth",37);
		ForceInt(L"JumplistWidth",0);
		ForceInt(L"MinMainHeight",0);
		ForceInt(L"SmallIconSize",20);
		ForceInt(L"LargeIconSize",40);
		ForceBool(L"MenuShadow",true);
		ForceBool(L"EnableGlass",true);
		ForceBool(L"GlassOverride",true);
		ForceInt(L"GlassOpacity",50);
		ForceInt(L"GlassColor",RGB(32,32,32));
		ForceBool(L"MainMenuAnimate",false);
		ForceInt(L"MainMenuAnimation",0);
		ForceInt(L"SubMenuAnimation",0);

		// Strip feature surfaces that are not part of the popup menu contract.
		ForceBool(L"CheckWinUpdates",false);
		ForceBool(L"EnableDragDrop",false);
		ForceBool(L"EnableContextMenu",false);
		ForceBool(L"EnableExplorer",false);
		ForceBool(L"EnableExit",false);
		ForceBool(L"EnableTouch",false);
		ForceBool(L"StartScreenShortcut",false);
		ForceBool(L"SkipMetro",false);
		ForceInt(L"DisableHotCorner",0);
		ForceBool(L"ReportSkinErrors",false);
	}

	void ApplyPresentation( MenuSkin &profile, MenuSkin::TSkinType skinType, int dpi )
	{
		if (skinType!=MenuSkin::SKIN_TYPE_WIN7)
			return;
		InstallMenuTypography(profile,dpi);

		// StartAllBack's captured foreground has true white cores. Keep the
		// antialiasing in the text renderer; do not pre-dim the source color.
		const COLORREF text=RGB(255,255,255);
		const COLORREF disabled=RGB(128,128,128);
		const COLORREF selection=RGB(64,64,64);
		const COLORREF surface=RGB(31,31,31);

		profile.About=L"A4S Menu source profile";
		profile.ForceRTL=false;
		profile.TwoColumns=true;
		profile.ForceTouch=false;
		profile.Main_icon_size=MenuSkin::ICON_SIZE_SMALL;
		profile.Main2_icon_size=MenuSkin::ICON_SIZE_SMALL;
		profile.User_image_size=0;
		profile.User_bitmapSize.cx=profile.User_bitmapSize.cy=0;
		profile.User_maskSize.cx=profile.User_maskSize.cy=0;

		// The DWM composition path supplies the adaptive, wallpaper-influenced
		// material. The DIB supplies the dark tint and readable foreground.
		profile.Main_opacity=MenuSkin::OPACITY_FULLGLASS;
		profile.Main2_opacity=MenuSkin::OPACITY_FULLGLASS;
		profile.Search_opacity=MenuSkin::OPACITY_FULLGLASS;
		profile.Jumplist_opacity=MenuSkin::OPACITY_FULLGLASS;
		profile.Submenu_opacity=MenuSkin::OPACITY_FULLGLASS;
		profile.Main_shadow=MenuSkin::SHADOW_ON;
		profile.Submenu_shadow=MenuSkin::SHADOW_ON;
		profile.Main_background=surface;
		profile.Main_background2=surface;
		profile.Submenu_background=surface;
		// Zero is the legacy renderer's "reuse the parent bitmap" sentinel.
		// The Programs tree is a child HWND; giving it its own translucent fill
		// bypasses the parent's acrylic tint and makes the entire list look hot.
		profile.Programs_background=0;
		profile.BHasScrollbar=true;

		SetSolidBitmap(profile.Main_bitmap,surface);
		SetSolidBitmap(profile.Main_bitmap_search,surface);
		SetSolidBitmap(profile.Main_bitmap_jump,surface);
		// Zero is transparent in the A4S renderer.  The search box contributes
		// only its hairline; the popup acrylic remains visible through it.
		SetSolidBitmap(profile.Search_background,0);
		SetSolidBitmap(profile.Search_background_search,0);
		SetSolidBitmap(profile.Search_background_jump,0);

		SetPadding(profile.Main_padding0,7,7,7,13,dpi);
		SetPadding(profile.Main2_padding0,10,15,8,13,dpi);
		SetPadding(profile.Main_search_padding0,7,7,7,13,dpi);
		SetPadding(profile.Main_jump_padding0,7,7,7,13,dpi);
		profile.Main_padding=profile.Main_padding0;
		profile.Main2_padding=profile.Main2_padding0;
		profile.Main_search_padding=profile.Main_search_padding0;
		profile.Main_jump_padding=profile.Main_jump_padding0;
		profile.Main_search_indent=Scale(13,dpi);
		SetPadding(profile.Submenu_padding0,4,0,4,0,dpi);
		profile.Submenu_padding=profile.Submenu_padding0;

		SetPadding(profile.Search_padding,3,2,3,2,dpi);
		profile.Search_frame=false;
		profile.Search_icon_left=true;
		profile.Search_text_colors[0]=text;
		profile.Search_text_colors[1]=RGB(153,153,153);
		profile.Search_text_background=0;
		profile.Shutdown_power_glyph=true;
		profile.Shutdown_power_glyph_size=Scale(17,dpi);
		SetPadding(profile.Shutdown_padding,0,0,0,0,dpi);

		for (int i=0;i<MenuSkin::ITEM_TYPE_COUNT;i++)
		{
			MenuSkin::ItemDrawSettings &item=profile.ItemSettings[i];
			SetItemColors(item,text,text,disabled);
			SetSelection(item,selection);
			item.arrColors[0]=text;
			item.arrColors[1]=text;
			item.glowSize=0;
		}

		// Captured row rhythm at 96 DPI: 22 px left/program rows, 40 px
		// right links, and a compact 26 px footer action.
		for (int i=MenuSkin::COLUMN1_ITEM;i<=MenuSkin::COLUMN1_SEPARATOR;i++)
		{
			MenuSkin::ItemDrawSettings &item=profile.ItemSettings[i];
			SetPadding(item.textPadding,5,3,8,4,dpi);
			SetPadding(item.iconPadding,4,1,4,1,dpi);
			item.itemHeight=Scale(22,dpi);
		}
		for (int i=MenuSkin::COLUMN2_ITEM;i<=MenuSkin::COLUMN2_INLINE;i++)
		{
			MenuSkin::ItemDrawSettings &item=profile.ItemSettings[i];
			SetPadding(item.textPadding,5,12,8,11,dpi);
			SetPadding(item.iconPadding,4,9,2,15,dpi);
			item.itemHeight=Scale(40,dpi);
		}
		for (int i=MenuSkin::PROGRAMS_TREE_ITEM;i<=MenuSkin::PROGRAMS_TREE_NEW;i++)
		{
			MenuSkin::ItemDrawSettings &item=profile.ItemSettings[i];
			SetPadding(item.textPadding,5,3,0,4,dpi);
			SetPadding(item.iconPadding,4,1,4,1,dpi);
			item.itemHeight=Scale(22,dpi);
		}
		for (int i=MenuSkin::LIST_ITEM;i<=MenuSkin::LIST_SPLIT;i++)
		{
			MenuSkin::ItemDrawSettings &item=profile.ItemSettings[i];
			SetPadding(item.textPadding,4,1,8,0,dpi);
			SetPadding(item.iconPadding,4,5,0,6,dpi);
			item.itemHeight=Scale(27,dpi);
		}
		SetItemColors(profile.ItemSettings[MenuSkin::LIST_SEPARATOR],RGB(224,224,224),RGB(224,224,224),disabled);
		SetItemColors(profile.ItemSettings[MenuSkin::LIST_SEPARATOR_SPLIT],RGB(224,224,224),RGB(224,224,224),disabled);
		for (int i=MenuSkin::SUBMENU_ITEM;i<=MenuSkin::SUBMENU_SEPARATOR_SPLIT;i++)
		{
			MenuSkin::ItemDrawSettings &item=profile.ItemSettings[i];
			SetPadding(item.textPadding,5,0,4,0,dpi);
			SetPadding(item.iconPadding,0,0,0,0,dpi);
		}
		for (int i=MenuSkin::PROGRAMS_BUTTON;i<=MenuSkin::PROGRAMS_CASCADING_NEW;i++)
		{
			MenuSkin::ItemDrawSettings &item=profile.ItemSettings[i];
			SetPadding(item.textPadding,3,3,8,2,dpi);
			SetPadding(item.iconPadding,12,6,7,6,dpi);
			item.arrPadding.cx=Scale(12,dpi);
			item.itemHeight=Scale(28,dpi);
		}
		for (int i=MenuSkin::SHUTDOWN_BUTTON;i<=MenuSkin::SHUTDOWN_BUTTON_JUMP;i++)
		{
			MenuSkin::ItemDrawSettings &item=profile.ItemSettings[i];
			SetPadding(item.textPadding,10,4,6,5,dpi);
			SetPadding(item.iconPadding,5,5,5,5,dpi);
			item.itemHeight=Scale(26,dpi);
		}
	}

	void FinalizeMetrics( MenuSkin &profile, MenuSkin::TSkinType skinType, int dpi )
	{
		if (skinType!=MenuSkin::SKIN_TYPE_WIN7)
			return;

		for (int i=MenuSkin::COLUMN1_ITEM;i<=MenuSkin::COLUMN1_SEPARATOR;i++)
			profile.ItemSettings[i].itemHeight=Scale(22,dpi);
		for (int i=MenuSkin::COLUMN2_ITEM;i<=MenuSkin::COLUMN2_INLINE;i++)
			profile.ItemSettings[i].itemHeight=Scale(40,dpi);
		for (int i=MenuSkin::PROGRAMS_TREE_ITEM;i<=MenuSkin::PROGRAMS_TREE_NEW;i++)
			profile.ItemSettings[i].itemHeight=Scale(22,dpi);
		profile.ItemSettings[MenuSkin::LIST_ITEM].itemHeight=Scale(27,dpi);
		profile.ItemSettings[MenuSkin::LIST_SPLIT].itemHeight=Scale(27,dpi);
		for (int i=MenuSkin::PROGRAMS_BUTTON;i<=MenuSkin::PROGRAMS_CASCADING_NEW;i++)
			profile.ItemSettings[i].itemHeight=Scale(28,dpi);
		for (int i=MenuSkin::SHUTDOWN_BUTTON;i<=MenuSkin::SHUTDOWN_BUTTON_JUMP;i++)
			profile.ItemSettings[i].itemHeight=Scale(26,dpi);
		profile.ItemSettings[MenuSkin::SUBMENU_ITEM].itemHeight=Scale(24,dpi);
		profile.ItemSettings[MenuSkin::SUBMENU_SPLIT].itemHeight=Scale(24,dpi);
		profile.ItemSettings[MenuSkin::SUBMENU_NEW].itemHeight=Scale(24,dpi);
		profile.ItemSettings[MenuSkin::SUBMENU_SEPARATOR].itemHeight=Scale(5,dpi);
		profile.ItemSettings[MenuSkin::SUBMENU_SEPARATOR_SPLIT].itemHeight=Scale(5,dpi);
	}
}
