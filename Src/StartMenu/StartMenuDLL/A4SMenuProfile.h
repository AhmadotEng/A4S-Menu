#pragma once

#include "SkinManager.h"

// Fixed, source-controlled profile for this machine's popup Start menu.
// This module is compiled into StartMenuDLL.dll and is the only supported
// customization surface for the environment fork.
namespace A4SMenuProfile
{
	const wchar_t *GetBuildId( void );
	bool IsEnabled( void );
	int Scale( int value, int dpi );

	// Captured StartAllBack geometry. These absolute-edge helpers are the
	// source of truth for the environment fork; the general Open-Shell
	// font/skin sizing heuristics must not resize the product around content.
	int MenuWidth( int dpi );
	int MenuHeight( int dpi );
	int SplitX( int dpi );
	void GetSearchRect( RECT &rect, int dpi );
	void GetProgramsButtonRect( RECT &rect, int dpi );
	void GetProgramsTreeRect( RECT &rect, int dpi );
	void GetMoreResultsRect( RECT &rect, int dpi );
	void GetShutdownRect( RECT &rect, int dpi );

	COLORREF BackdropTint( void );
	BYTE BackdropAlpha( void );

	// Called while the settings manager is write-locked. Values are forced in
	// memory so stale Open-Shell registry settings cannot change this product.
	void ApplyLockedSettings( void );

	// Called from MenuSkin::LoadSkin before its calculated metrics are finalized.
	// MenuSkin remains an internal render record; this is not a selectable skin.
	void ApplyPresentation( MenuSkin &profile, MenuSkin::TSkinType skinType, int dpi );

	// Reassert exact row metrics after the legacy loader has measured fonts and
	// icons. Without this pass it silently replaces the captured 22/40/28/26 px
	// rhythm with content-derived values.
	void FinalizeMetrics( MenuSkin &profile, MenuSkin::TSkinType skinType, int dpi );
}
