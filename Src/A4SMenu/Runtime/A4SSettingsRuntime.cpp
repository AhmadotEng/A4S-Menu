// Minimal settings helpers retained by the fixed A4S presentation profile.
// The general Open-Shell settings UI implementation is not part of the
// product runtime library.

#include "stdafx.h"
#include <stdlib.h>

DWORD RgbToBgr( DWORD val )
{
	return ((val&0xFF)<<16)|(val&0xFF00)|((val>>16)&0xFF);
}

DWORD BgrToRgb( DWORD val )
{
	return RgbToBgr(val);
}

DWORD ParseColor( const wchar_t *str )
{
	wchar_t *end;
	return wcstoul(str,&end,16)&0xFFFFFF;
}
