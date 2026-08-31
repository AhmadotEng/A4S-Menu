// ## MenuContainer.h
// Classic Shell (c) 2009-2017, Ivo Beltchev
// Open-Shell (c) 2017-2018, The Open-Shell Team
// Confidential information of Ivo Beltchev. Not for disclosure or distribution without prior written consent from the author

// MenuPaint.cpp - handles the painting functionality of CMenuContainer

#include "stdafx.h"
#include "ItemManager.h"
#include "MenuContainer.h"
#include "StartMenuDLL.h"
#include "Settings.h"
#include "Translations.h"
#include "ResourceHelper.h"
#include "LogManager.h"
#include "ProgramsTree.h"
#include "SettingsUI.h"
#include "A4SMenuProfile.h"
#include <vsstyle.h>
#include <dwmapi.h>
#include <algorithm>
#include <math.h>
#include <chrono>

static BLENDFUNCTION g_AlphaFunc={AC_SRC_OVER,0,255,AC_SRC_ALPHA};
static void FillSolidGlassRect( HDC hdc, LPCRECT pRect, COLORREF color );

// Draw a small, resolution-independent power symbol without relying on a
// vendor bitmap or a particular icon font. Supersampling keeps the 16px form
// crisp while preserving proper premultiplied alpha on glass backgrounds.
static void DrawPowerGlyph( HDC hdc, int x, int y, int size, COLORREF color )
{
	if (size<=0)
		return;

	BITMAPINFO bi={0};
	bi.bmiHeader.biSize=sizeof(BITMAPINFOHEADER);
	bi.bmiHeader.biWidth=size;
	bi.bmiHeader.biHeight=-size;
	bi.bmiHeader.biPlanes=1;
	bi.bmiHeader.biBitCount=32;

	HDC hdcGlyph=CreateCompatibleDC(hdc);
	unsigned int *bits=NULL;
	HBITMAP bmp=CreateDIBSection(hdcGlyph,&bi,DIB_RGB_COLORS,(void**)&bits,NULL,0);
	if (!bmp || !bits)
	{
		if (bmp) DeleteObject(bmp);
		DeleteDC(hdcGlyph);
		return;
	}
	HGDIOBJ bmp0=SelectObject(hdcGlyph,bmp);

	const int samples=4;
	const double cx=size*0.5-0.5;
	const double cy=size*0.5;
	const double radius=size*0.40;
	const double stroke=(std::max)(1.0,size*0.10);
	const double halfStroke=stroke*0.5;
	const double lineTop=0;
	const double lineBottom=cy+radius*0.06;
	const int red=GetRValue(color);
	const int green=GetGValue(color);
	const int blue=GetBValue(color);

	for (int py=0;py<size;py++)
	{
		for (int px=0;px<size;px++)
		{
			int covered=0;
			for (int sy=0;sy<samples;sy++)
			{
				for (int sx=0;sx<samples;sx++)
				{
					const double fx=px+(sx+0.5)/samples;
					const double fy=py+(sy+0.5)/samples;
					const double dx=fx-cx;
					const double dy=fy-cy;
					const double distance=sqrt(dx*dx+dy*dy);
					const bool inTopGap=dy<-radius*0.28 && fabs(dx)<radius*0.43;
					const bool onRing=!inTopGap && fabs(distance-radius)<=halfStroke;

					double lineDy=0;
					if (fy<lineTop) lineDy=lineTop-fy;
					else if (fy>lineBottom) lineDy=fy-lineBottom;
					const bool onStem=sqrt(dx*dx+lineDy*lineDy)<=halfStroke;
					if (onRing || onStem)
						covered++;
				}
			}
			const int alpha=(covered*255)/(samples*samples);
			bits[py*size+px]=(alpha<<24)|((red*alpha/255)<<16)|((green*alpha/255)<<8)|(blue*alpha/255);
		}
	}

	AlphaBlend(hdc,x,y,size,size,hdcGlyph,0,0,size,size,g_AlphaFunc);
	SelectObject(hdcGlyph,bmp0);
	DeleteObject(bmp);
	DeleteDC(hdcGlyph);
}

static bool A4SInsideRoundedBox( double x, double y, double left, double top, double right, double bottom, double radius )
{
	if (x<left || x>=right || y<top || y>=bottom)
		return false;
	double cx=x;
	double cy=y;
	if (cx<left+radius) cx=left+radius;
	else if (cx>right-radius) cx=right-radius;
	if (cy<top+radius) cy=top+radius;
	else if (cy>bottom-radius) cy=bottom-radius;
	const double dx=x-cx;
	const double dy=y-cy;
	return dx*dx+dy*dy<=radius*radius;
}

// The search box is only an outline inside the shared acrylic footer.  Keep
// the interior at alpha zero so the wallpaper-reactive material remains
// continuous through the native edit control.
static void DrawA4SSearchSurface( HDC hdc, const RECT &rect, int dpi )
{
	const int width=rect.right-rect.left;
	const int height=rect.bottom-rect.top;
	if (width<=0 || height<=0)
		return;

	BITMAPINFO bi={0};
	bi.bmiHeader.biSize=sizeof(BITMAPINFOHEADER);
	bi.bmiHeader.biWidth=width;
	bi.bmiHeader.biHeight=-height;
	bi.bmiHeader.biPlanes=1;
	bi.bmiHeader.biBitCount=32;
	bi.bmiHeader.biCompression=BI_RGB;
	HDC source=CreateCompatibleDC(hdc);
	if (!source)
		return;
	unsigned int *bits=NULL;
	HBITMAP bitmap=CreateDIBSection(source,&bi,DIB_RGB_COLORS,(void **)&bits,NULL,0);
	if (!bitmap || !bits)
	{
		if (bitmap) DeleteObject(bitmap);
		DeleteDC(source);
		return;
	}
	HGDIOBJ bitmap0=SelectObject(source,bitmap);

	const int samples=4;
	const int sampleCount=samples*samples;
	const double radius=(std::max)(3.0,A4SMenuProfile::Scale(4,dpi)*1.0);
	const COLORREF border=RGB(81,81,81);
	for (int py=0;py<height;py++)
	{
		for (int px=0;px<width;px++)
		{
			int covered=0, red=0, green=0, blue=0;
			for (int sy=0;sy<samples;sy++)
			{
				for (int sx=0;sx<samples;sx++)
				{
					const double fx=px+(sx+0.5)/samples;
					const double fy=py+(sy+0.5)/samples;
					const bool insideOuter=A4SInsideRoundedBox(fx,fy,0,0,width,height,radius);
					const bool insideInner=A4SInsideRoundedBox(fx,fy,1,1,width-1,height-1,(std::max)(1.0,radius-1));
					if (!insideOuter || insideInner)
						continue;
					covered++;
					red+=GetRValue(border);
					green+=GetGValue(border);
					blue+=GetBValue(border);
				}
			}
			const unsigned int alpha=(covered*255+sampleCount/2)/sampleCount;
			bits[py*width+px]=(alpha<<24)|((red/sampleCount)<<16)|((green/sampleCount)<<8)|(blue/sampleCount);
		}
	}

	AlphaBlend(hdc,rect.left,rect.top,width,height,source,0,0,width,height,g_AlphaFunc);
	SelectObject(source,bitmap0);
	DeleteObject(bitmap);
	DeleteDC(source);
}

static void FillA4SOpaqueRect( HDC hdc, const RECT &rect, COLORREF color )
{
	if (rect.right<=rect.left || rect.bottom<=rect.top)
		return;
	BITMAPINFO bi={0};
	bi.bmiHeader.biSize=sizeof(BITMAPINFOHEADER);
	bi.bmiHeader.biWidth=1;
	bi.bmiHeader.biHeight=-1;
	bi.bmiHeader.biPlanes=1;
	bi.bmiHeader.biBitCount=32;
	bi.bmiHeader.biCompression=BI_RGB;
	HDC source=CreateCompatibleDC(hdc);
	unsigned int *pixel=NULL;
	HBITMAP bitmap=CreateDIBSection(source,&bi,DIB_RGB_COLORS,(void **)&pixel,NULL,0);
	if (!source || !bitmap || !pixel)
	{
		if (bitmap) DeleteObject(bitmap);
		if (source) DeleteDC(source);
		return;
	}
	HGDIOBJ bitmap0=SelectObject(source,bitmap);
	*pixel=0xFF000000|(GetRValue(color)<<16)|(GetGValue(color)<<8)|GetBValue(color);
	AlphaBlend(hdc,rect.left,rect.top,rect.right-rect.left,rect.bottom-rect.top,source,0,0,1,1,g_AlphaFunc);
	SelectObject(source,bitmap0);
	DeleteObject(bitmap);
	DeleteDC(source);
}

static void DrawA4SSelectionRect( HDC hdc, const RECT &rect, int dpi )
{
	// Keep hit targets and row rhythm untouched while pulling the visible hover
	// fill one physical pixel away from every button edge.
	RECT paintRect=rect;
	InflateRect(&paintRect,-1,-1);
	const int width=paintRect.right-paintRect.left;
	const int height=paintRect.bottom-paintRect.top;
	if (width<=0 || height<=0)
		return;
	BITMAPINFO bi={0};
	bi.bmiHeader.biSize=sizeof(BITMAPINFOHEADER);
	bi.bmiHeader.biWidth=width;
	bi.bmiHeader.biHeight=-height;
	bi.bmiHeader.biPlanes=1;
	bi.bmiHeader.biBitCount=32;
	bi.bmiHeader.biCompression=BI_RGB;
	HDC source=CreateCompatibleDC(hdc);
	unsigned int *bits=NULL;
	HBITMAP bitmap=CreateDIBSection(source,&bi,DIB_RGB_COLORS,(void **)&bits,NULL,0);
	if (!source || !bitmap || !bits)
	{
		if (bitmap) DeleteObject(bitmap);
		if (source) DeleteDC(source);
		return;
	}
	HGDIOBJ bitmap0=SelectObject(source,bitmap);
	const int samples=4;
	const int sampleCount=samples*samples;
	const int overlayAlpha=37;
	const int radiusDip=width>A4SMenuProfile::Scale(300,dpi)?4:3;
	const double radius=(std::max)(2.0,A4SMenuProfile::Scale(radiusDip,dpi)*1.0);
	for (int py=0;py<height;py++)
	{
		for (int px=0;px<width;px++)
		{
			int covered=0;
			for (int sy=0;sy<samples;sy++)
				for (int sx=0;sx<samples;sx++)
					if (A4SInsideRoundedBox(px+(sx+0.5)/samples,py+(sy+0.5)/samples,0,0,width,height,radius))
						covered++;
			const unsigned int alpha=(covered*overlayAlpha+sampleCount/2)/sampleCount;
			bits[py*width+px]=(alpha<<24)|(alpha<<16)|(alpha<<8)|alpha;
		}
	}
	AlphaBlend(hdc,paintRect.left,paintRect.top,width,height,source,0,0,width,height,g_AlphaFunc);
	SelectObject(source,bitmap0);
	DeleteObject(bitmap);
	DeleteDC(source);
}

enum A4SRightGlyph
{
	A4S_RIGHT_GLYPH_NONE,
	A4S_RIGHT_GLYPH_USER,
	A4S_RIGHT_GLYPH_DOCUMENT,
	A4S_RIGHT_GLYPH_DOWNLOAD,
	A4S_RIGHT_GLYPH_PC,
	A4S_RIGHT_GLYPH_CONTROL_PANEL,
	A4S_RIGHT_GLYPH_SETTINGS,
	A4S_RIGHT_GLYPH_COMMAND,
	A4S_RIGHT_GLYPH_RUN,
};

static double A4SDistanceToSegmentSquared( double x, double y, double x1, double y1, double x2, double y2 )
{
	const double dx=x2-x1;
	const double dy=y2-y1;
	const double lengthSquared=dx*dx+dy*dy;
	double t=0;
	if (lengthSquared>0)
	{
		t=((x-x1)*dx+(y-y1)*dy)/lengthSquared;
		if (t<0) t=0;
		else if (t>1) t=1;
	}
	const double px=x1+t*dx;
	const double py=y1+t*dy;
	const double qx=x-px;
	const double qy=y-py;
	return qx*qx+qy*qy;
}

static bool A4SHitLine( double x, double y, double x1, double y1, double x2, double y2, double halfWidth=0.50 )
{
	return A4SDistanceToSegmentSquared(x,y,x1,y1,x2,y2)<=halfWidth*halfWidth;
}

static bool A4SHitCircle( double x, double y, double cx, double cy, double radius, double halfWidth=0.50 )
{
	const double dx=x-cx;
	const double dy=y-cy;
	return fabs(sqrt(dx*dx+dy*dy)-radius)<=halfWidth;
}

static bool A4SHitDisc( double x, double y, double cx, double cy, double radius )
{
	const double dx=x-cx;
	const double dy=y-cy;
	return dx*dx+dy*dy<=radius*radius;
}

static bool A4SHitRect( double x, double y, double left, double top, double right, double bottom, double halfWidth=0.50 )
{
	return A4SHitLine(x,y,left,top,right,top,halfWidth) ||
		A4SHitLine(x,y,right,top,right,bottom,halfWidth) ||
		A4SHitLine(x,y,right,bottom,left,bottom,halfWidth) ||
		A4SHitLine(x,y,left,bottom,left,top,halfWidth);
}

static bool A4SHitRightGlyph( A4SRightGlyph glyph, double x, double y )
{
	switch (glyph)
	{
		case A4S_RIGHT_GLYPH_USER:
		{
			const bool folder=
				A4SHitLine(x,y,2.0,4.0,5.8,4.0) ||
				A4SHitLine(x,y,5.8,4.0,7.0,5.2) ||
				A4SHitLine(x,y,7.0,5.2,13.5,5.2) ||
				A4SHitLine(x,y,13.5,5.2,13.5,13.2) ||
				A4SHitLine(x,y,13.5,13.2,2.0,13.2) ||
				A4SHitLine(x,y,2.0,13.2,2.0,4.0);
			const bool head=A4SHitDisc(x,y,10.5,8.2,1.05);
			const double ex=(x-10.5)/2.65;
			const double ey=(y-13.4)/2.35;
			const double ellipseRadius=sqrt(ex*ex+ey*ey);
			const bool shoulders=y>=10.8 && y<=13.3 && fabs(ellipseRadius-1.0)<=0.22;
			return folder || head || shoulders;
		}

		case A4S_RIGHT_GLYPH_DOCUMENT:
			return A4SHitLine(x,y,4.0,2.0,9.0,2.0) ||
				A4SHitLine(x,y,9.0,2.0,12.0,5.0) ||
				A4SHitLine(x,y,12.0,5.0,12.0,14.0) ||
				A4SHitLine(x,y,12.0,14.0,4.0,14.0) ||
				A4SHitLine(x,y,4.0,14.0,4.0,2.0) ||
				A4SHitLine(x,y,9.0,2.0,9.0,5.0) ||
				A4SHitLine(x,y,9.0,5.0,12.0,5.0) ||
				A4SHitLine(x,y,6.0,8.2,10.0,8.2,0.40) ||
				A4SHitLine(x,y,6.0,10.6,10.0,10.6,0.40);

		case A4S_RIGHT_GLYPH_DOWNLOAD:
			return A4SHitLine(x,y,8.0,2.3,8.0,10.3) ||
				A4SHitLine(x,y,4.8,7.2,8.0,10.4) ||
				A4SHitLine(x,y,11.2,7.2,8.0,10.4) ||
				A4SHitLine(x,y,3.5,13.5,12.5,13.5);

		case A4S_RIGHT_GLYPH_PC:
			return A4SHitRect(x,y,2.3,3.0,13.7,11.0) ||
				A4SHitLine(x,y,8.0,11.0,8.0,13.3) ||
				A4SHitLine(x,y,5.2,14.0,10.8,14.0);

		case A4S_RIGHT_GLYPH_CONTROL_PANEL:
			return A4SHitRect(x,y,2.2,3.2,13.8,12.8) ||
				A4SHitLine(x,y,4.1,6.0,11.9,6.0,0.38) ||
				A4SHitLine(x,y,4.1,8.0,11.9,8.0,0.38) ||
				A4SHitLine(x,y,4.1,10.0,11.9,10.0,0.38) ||
				A4SHitDisc(x,y,6.0,6.0,0.64) ||
				A4SHitDisc(x,y,10.0,8.0,0.64) ||
				A4SHitDisc(x,y,7.0,10.0,0.64);

		case A4S_RIGHT_GLYPH_SETTINGS:
		{
			bool hit=A4SHitCircle(x,y,8.0,8.0,4.25) || A4SHitCircle(x,y,8.0,8.0,1.55,0.46);
			const double pi=3.14159265358979323846;
			for (int i=0;i<8 && !hit;i++)
			{
				const double angle=pi*i/4.0;
				hit=A4SHitLine(x,y,8.0+cos(angle)*4.45,8.0+sin(angle)*4.45,
					8.0+cos(angle)*6.15,8.0+sin(angle)*6.15,0.50);
			}
			return hit;
		}

		case A4S_RIGHT_GLYPH_COMMAND:
			return A4SHitRect(x,y,2.0,3.0,14.0,13.0) ||
				A4SHitLine(x,y,4.2,6.0,6.5,8.0) ||
				A4SHitLine(x,y,6.5,8.0,4.2,10.0) ||
				A4SHitLine(x,y,8.0,10.0,11.7,10.0);

		case A4S_RIGHT_GLYPH_RUN:
			return A4SHitRect(x,y,2.1,3.1,11.6,11.7) ||
				A4SHitLine(x,y,2.1,5.3,11.6,5.3,0.40) ||
				A4SHitCircle(x,y,11.2,11.2,2.55) ||
				A4SHitLine(x,y,10.4,9.8,12.1,11.2,0.44) ||
				A4SHitLine(x,y,12.1,11.2,10.4,12.6,0.44);

		default:
			return false;
	}
}

// The fixed right pane uses source-owned outline glyphs. Rendering from a
// supersampled premultiplied DIB keeps the forms crisp on the glass surface
// without depending on a shell icon cache, resource DLL, or icon font.
static wchar_t GetA4SFluentGlyph( A4SRightGlyph glyph )
{
	switch (glyph)
	{
		case A4S_RIGHT_GLYPH_USER:          return 0xE7EE; // OtherUser
		case A4S_RIGHT_GLYPH_DOCUMENT:      return 0xF000; // KnowledgeArticle
		case A4S_RIGHT_GLYPH_DOWNLOAD:      return 0xE896; // Download
		case A4S_RIGHT_GLYPH_CONTROL_PANEL: return 0xF8A6; // framed control panel
		case A4S_RIGHT_GLYPH_SETTINGS:      return 0xE713; // Settings
		case A4S_RIGHT_GLYPH_RUN:           return 0xE7EF; // framed user badge
		default:                            return 0;
	}
}

// StartAllBack uses Windows 11's monoline Fluent forms for six right-pane
// roles. Rasterize the installed system font into grayscale coverage and then
// convert it to premultiplied alpha so the glyph remains sharp on acrylic.
static bool DrawA4SFluentRightGlyph( HDC hdc, int x, int y, int canvasSize, int dpi, COLORREF color, A4SRightGlyph glyph )
{
	const wchar_t codepoint=GetA4SFluentGlyph(glyph);
	if (!codepoint || canvasSize<=0)
		return false;

	BITMAPINFO bi={0};
	bi.bmiHeader.biSize=sizeof(BITMAPINFOHEADER);
	bi.bmiHeader.biWidth=canvasSize;
	bi.bmiHeader.biHeight=-canvasSize;
	bi.bmiHeader.biPlanes=1;
	bi.bmiHeader.biBitCount=32;
	bi.bmiHeader.biCompression=BI_RGB;
	HDC source=CreateCompatibleDC(hdc);
	if (!source)
		return false;
	unsigned int *bits=NULL;
	HBITMAP bitmap=CreateDIBSection(source,&bi,DIB_RGB_COLORS,(void **)&bits,NULL,0);
	if (!bitmap || !bits)
	{
		if (bitmap) DeleteObject(bitmap);
		DeleteDC(source);
		return false;
	}
	HGDIOBJ bitmap0=SelectObject(source,bitmap);
	memset(bits,0,canvasSize*canvasSize*sizeof(*bits));

	const int fontSize=(std::max)(1,A4SMenuProfile::Scale(16,dpi));
	HFONT font=CreateFont(-fontSize,0,0,0,FW_NORMAL,FALSE,FALSE,FALSE,
		DEFAULT_CHARSET,OUT_TT_PRECIS,CLIP_DEFAULT_PRECIS,ANTIALIASED_QUALITY,
		DEFAULT_PITCH|FF_DONTCARE,L"Segoe Fluent Icons");
	HGDIOBJ font0=font?SelectObject(source,font):NULL;
	wchar_t face[64]={0};
	const bool hasFluent=font0 && GetTextFace(source,_countof(face),face)>0 && _wcsicmp(face,L"Segoe Fluent Icons")==0;
	if (hasFluent)
	{
		SetBkMode(source,OPAQUE);
		SetBkColor(source,RGB(0,0,0));
		SetTextColor(source,RGB(255,255,255));
		RECT rc={0,0,canvasSize,canvasSize};
		wchar_t text[2]={codepoint,0};
		DrawText(source,text,1,&rc,DT_CENTER|DT_VCENTER|DT_SINGLELINE|DT_NOPREFIX);

		const unsigned int red=GetRValue(color), green=GetGValue(color), blue=GetBValue(color);
		for (int i=0;i<canvasSize*canvasSize;i++)
		{
			const unsigned int pixel=bits[i];
			const unsigned int coverage=(((pixel>>16)&255)+((pixel>>8)&255)+(pixel&255)+1)/3;
			bits[i]=(coverage<<24)|((red*coverage/255)<<16)|((green*coverage/255)<<8)|(blue*coverage/255);
		}
		AlphaBlend(hdc,x,y,canvasSize,canvasSize,source,0,0,canvasSize,canvasSize,g_AlphaFunc);
	}

	if (font0) SelectObject(source,font0);
	if (font) DeleteObject(font);
	SelectObject(source,bitmap0);
	DeleteObject(bitmap);
	DeleteDC(source);
	return hasFluent;
}

static void DrawA4SRightGlyph( HDC hdc, int x, int y, int size, int dpi, COLORREF color, A4SRightGlyph glyph )
{
	if (size<=0 || glyph==A4S_RIGHT_GLYPH_NONE)
		return;
	if (DrawA4SFluentRightGlyph(hdc,x,y,size,dpi,color,glyph))
		return;

	BITMAPINFO bi={0};
	bi.bmiHeader.biSize=sizeof(BITMAPINFOHEADER);
	bi.bmiHeader.biWidth=size;
	bi.bmiHeader.biHeight=-size;
	bi.bmiHeader.biPlanes=1;
	bi.bmiHeader.biBitCount=32;
	bi.bmiHeader.biCompression=BI_RGB;

	HDC hdcGlyph=CreateCompatibleDC(hdc);
	if (!hdcGlyph)
		return;
	unsigned int *bits=NULL;
	HBITMAP bmp=CreateDIBSection(hdcGlyph,&bi,DIB_RGB_COLORS,(void **)&bits,NULL,0);
	if (!bmp || !bits)
	{
		if (bmp) DeleteObject(bmp);
		DeleteDC(hdcGlyph);
		return;
	}
	HGDIOBJ bmp0=SelectObject(hdcGlyph,bmp);

	const int samples=8;
	const int sampleCount=samples*samples;
	const double unitScale=16.0/size;
	const int red=GetRValue(color);
	const int green=GetGValue(color);
	const int blue=GetBValue(color);
	for (int py=0;py<size;py++)
	{
		for (int px=0;px<size;px++)
		{
			int covered=0;
			for (int sy=0;sy<samples;sy++)
			{
				for (int sx=0;sx<samples;sx++)
				{
					const double fx=(px+(sx+0.5)/samples)*unitScale;
					const double fy=(py+(sy+0.5)/samples)*unitScale;
					if (A4SHitRightGlyph(glyph,fx,fy))
						covered++;
				}
			}
			const unsigned int alpha=(covered*255+sampleCount/2)/sampleCount;
			const unsigned int r=red*alpha/255;
			const unsigned int g=green*alpha/255;
			const unsigned int b=blue*alpha/255;
			bits[py*size+px]=(alpha<<24)|(r<<16)|(g<<8)|b;
		}
	}

	AlphaBlend(hdc,x,y,size,size,hdcGlyph,0,0,size,size,g_AlphaFunc);
	SelectObject(hdcGlyph,bmp0);
	DeleteObject(bmp);
	DeleteDC(hdcGlyph);
}

// StartAllBack's footer/navigation chevrons have a 6x10-pixel strong-ink
// footprint at 96 DPI. Keep the three coverage bands from the capture instead
// of stretching Open-Shell's legacy 4x7 filled triangle.
static void DrawA4SChevron( HDC hdc, int x, int y, int dpi, COLORREF color, bool left )
{
	const int width=(std::max)(1,A4SMenuProfile::Scale(8,dpi));
	const int height=(std::max)(1,A4SMenuProfile::Scale(10,dpi));
	BITMAPINFO bi={0};
	bi.bmiHeader.biSize=sizeof(BITMAPINFOHEADER);
	bi.bmiHeader.biWidth=width;
	bi.bmiHeader.biHeight=-height;
	bi.bmiHeader.biPlanes=1;
	bi.bmiHeader.biBitCount=32;
	bi.bmiHeader.biCompression=BI_RGB;
	HDC source=CreateCompatibleDC(hdc);
	if (!source)
		return;
	unsigned int *bits=NULL;
	HBITMAP bitmap=CreateDIBSection(source,&bi,DIB_RGB_COLORS,(void **)&bits,NULL,0);
	if (!bitmap || !bits)
	{
		if (bitmap) DeleteObject(bitmap);
		DeleteDC(source);
		return;
	}
	HGDIOBJ bitmap0=SelectObject(source,bitmap);
	static const BYTE centersRight[10]={2,3,4,5,6,6,5,4,3,2};
	static const BYTE centersLeft[10]={5,4,3,2,1,1,2,3,4,5};
	const BYTE *centers=left?centersLeft:centersRight;
	const int red=GetRValue(color), green=GetGValue(color), blue=GetBValue(color);
	for (int py=0;py<height;py++)
	{
		const int logicalY=(std::min)(9,py*10/height);
		for (int px=0;px<width;px++)
		{
			const int logicalX=(std::min)(7,px*8/width);
			const int center=centers[logicalY];
			int alpha=0;
			if (logicalX==center)
				alpha=223;
			else if (logicalX==center+(left?1:-1))
				alpha=178;
			else if (logicalX==center+(left?-1:1))
				alpha=20;
			bits[py*width+px]=(alpha<<24)|((red*alpha/255)<<16)|((green*alpha/255)<<8)|(blue*alpha/255);
		}
	}
	AlphaBlend(hdc,x,y,width,height,source,0,0,width,height,g_AlphaFunc);
	SelectObject(source,bitmap0);
	DeleteObject(bitmap);
	DeleteDC(source);
}

static void DrawA4SSearchMagnifier( HDC hdc, int x, int y, int dpi )
{
	const int size=(std::max)(1,A4SMenuProfile::Scale(15,dpi));
	BITMAPINFO bi={0};
	bi.bmiHeader.biSize=sizeof(BITMAPINFOHEADER);
	bi.bmiHeader.biWidth=size;
	bi.bmiHeader.biHeight=-size;
	bi.bmiHeader.biPlanes=1;
	bi.bmiHeader.biBitCount=32;
	bi.bmiHeader.biCompression=BI_RGB;
	HDC source=CreateCompatibleDC(hdc);
	if (!source)
		return;
	unsigned int *bits=NULL;
	HBITMAP bitmap=CreateDIBSection(source,&bi,DIB_RGB_COLORS,(void **)&bits,NULL,0);
	if (!bitmap || !bits)
	{
		if (bitmap) DeleteObject(bitmap);
		DeleteDC(source);
		return;
	}
	HGDIOBJ bitmap0=SelectObject(source,bitmap);
	const int samples=4;
	const int sampleCount=samples*samples;
	const double unitScale=15.0/size;
	const int gray=144;
	for (int py=0;py<size;py++)
	{
		for (int px=0;px<size;px++)
		{
			int covered=0;
			for (int sy=0;sy<samples;sy++)
			{
				for (int sx=0;sx<samples;sx++)
				{
					const double fx=(px+(sx+0.5)/samples)*unitScale;
					const double fy=(py+(sy+0.5)/samples)*unitScale;
					if (A4SHitCircle(fx,fy,6.0,6.0,5.375,0.50) ||
						A4SHitLine(fx,fy,10.5,10.5,14.25,14.25,0.575))
						covered++;
				}
			}
			const unsigned int alpha=(covered*255+sampleCount/2)/sampleCount;
			const unsigned int value=gray*alpha/255;
			bits[py*size+px]=(alpha<<24)|(value<<16)|(value<<8)|value;
		}
	}
	AlphaBlend(hdc,x,y,size,size,source,0,0,size,size,g_AlphaFunc);
	SelectObject(source,bitmap0);
	DeleteObject(bitmap);
	DeleteDC(source);
}

static void DrawA4SSearchClear( HDC hdc, int x, int y, int dpi )
{
	const int size=(std::max)(1,A4SMenuProfile::Scale(12,dpi));
	BITMAPINFO bi={0};
	bi.bmiHeader.biSize=sizeof(BITMAPINFOHEADER);
	bi.bmiHeader.biWidth=size;
	bi.bmiHeader.biHeight=-size;
	bi.bmiHeader.biPlanes=1;
	bi.bmiHeader.biBitCount=32;
	bi.bmiHeader.biCompression=BI_RGB;
	HDC source=CreateCompatibleDC(hdc);
	if (!source)
		return;
	unsigned int *bits=NULL;
	HBITMAP bitmap=CreateDIBSection(source,&bi,DIB_RGB_COLORS,(void **)&bits,NULL,0);
	if (!bitmap || !bits)
	{
		if (bitmap) DeleteObject(bitmap);
		DeleteDC(source);
		return;
	}
	HGDIOBJ bitmap0=SelectObject(source,bitmap);
	const int samples=4;
	const int sampleCount=samples*samples;
	const double unitScale=12.0/size;
	const COLORREF blue=RGB(4,129,220);
	for (int py=0;py<size;py++)
	{
		for (int px=0;px<size;px++)
		{
			int covered=0;
			for (int sy=0;sy<samples;sy++)
			{
				for (int sx=0;sx<samples;sx++)
				{
					const double fx=(px+(sx+0.5)/samples)*unitScale;
					const double fy=(py+(sy+0.5)/samples)*unitScale;
					if (A4SHitLine(fx,fy,0.75,0.75,11.25,11.25,0.50) ||
						A4SHitLine(fx,fy,11.25,0.75,0.75,11.25,0.50))
						covered++;
				}
			}
			const unsigned int alpha=(covered*255+sampleCount/2)/sampleCount;
			bits[py*size+px]=(alpha<<24)|((GetRValue(blue)*alpha/255)<<16)|
				((GetGValue(blue)*alpha/255)<<8)|(GetBValue(blue)*alpha/255);
		}
	}
	AlphaBlend(hdc,x,y,size,size,source,0,0,size,size,g_AlphaFunc);
	SelectObject(source,bitmap0);
	DeleteObject(bitmap);
	DeleteDC(source);
}

MIDL_INTERFACE("4BEDE6E0-A125-46A7-A3BF-4187165E09A5")
IUserTileStore8 : public IUnknown
{
	virtual HRESULT STDMETHODCALLTYPE SaveUserTileToStream( IStream*, int ) = 0;
	virtual HRESULT STDMETHODCALLTYPE SetUserTileFromStream( int, IStream* ) = 0;
	virtual HRESULT STDMETHODCALLTYPE GetLargePath( const wchar_t *userSid, wchar_t **pPath ) = 0;
	virtual HRESULT STDMETHODCALLTYPE GetSmallPath( const wchar_t *userSid, wchar_t **pPath ) = 0;
	virtual HRESULT STDMETHODCALLTYPE GetDynamicPath( const wchar_t *userSid, wchar_t **pPath ) = 0;
	virtual HRESULT STDMETHODCALLTYPE GetSmallPicture( const wchar_t *userSid, HBITMAP *pBitmap ) = 0;
	virtual HRESULT STDMETHODCALLTYPE GetLargePicture( const wchar_t *userSid, HBITMAP *pBitmap ) = 0;
	virtual HRESULT STDMETHODCALLTYPE GetUserTilePathBySize( const wchar_t *userSid, unsigned int size, wchar_t **pPath ) = 0;
	virtual HRESULT STDMETHODCALLTYPE GetDynamicPathBySize( const wchar_t *userSid, unsigned int size, wchar_t **pPath ) = 0;
};

MIDL_INTERFACE("A1BA55E7-0F4E-454D-89A4-2376347D504A")
IUserTileStore81 : public IUnknown
{
	virtual HRESULT STDMETHODCALLTYPE SaveUserTileToStream( IStream*, int ) = 0;
	virtual HRESULT STDMETHODCALLTYPE SetUserTileFromStream( int, IStream* ) = 0;
	virtual HRESULT STDMETHODCALLTYPE GetLargePath( const wchar_t *userSid, wchar_t **pPath ) = 0;
	virtual HRESULT STDMETHODCALLTYPE GetSmallPath( const wchar_t *userSid, wchar_t **pPath ) = 0;
	virtual HRESULT STDMETHODCALLTYPE GetDynamicPath( const wchar_t *userSid, wchar_t **pPath ) = 0;
	virtual HRESULT STDMETHODCALLTYPE GetSmallPicture( const wchar_t *userSid, HBITMAP *pBitmap ) = 0;
	virtual HRESULT STDMETHODCALLTYPE GetLargePicture( const wchar_t *userSid, HBITMAP *pBitmap ) = 0;
	virtual HRESULT STDMETHODCALLTYPE GetUserTilePathBySize( const wchar_t *userSid, unsigned int size, wchar_t **pPath ) = 0;
	virtual HRESULT STDMETHODCALLTYPE GetDynamicPathBySize( const wchar_t *userSid, unsigned int size, wchar_t **pPath ) = 0;
};

MIDL_INTERFACE("A76E31A3-DED8-4119-ADD8-BF818F05965C")
IUserTileStore10 : public IUnknown
{
	virtual HRESULT STDMETHODCALLTYPE SaveUserTileToStream( IStream*, int ) = 0;
	virtual HRESULT STDMETHODCALLTYPE SetUserTileFromStream( int, IStream* ) = 0;
	virtual HRESULT STDMETHODCALLTYPE GetLargePath( const wchar_t *userSid, wchar_t **pPath ) = 0;
	virtual HRESULT STDMETHODCALLTYPE GetSmallPath( const wchar_t *userSid, wchar_t **pPath ) = 0;
	virtual HRESULT STDMETHODCALLTYPE GetExtraSmallPath( const wchar_t *userSid, wchar_t **pPath ) = 0;
	virtual HRESULT STDMETHODCALLTYPE GetDynamicPath( const wchar_t *userSid, wchar_t **pPath ) = 0;
	virtual HRESULT STDMETHODCALLTYPE GetSmallPicture( const wchar_t *userSid, HBITMAP *pBitmap ) = 0;
	virtual HRESULT STDMETHODCALLTYPE GetLargePicture( const wchar_t *userSid, HBITMAP *pBitmap ) = 0;
	virtual HRESULT STDMETHODCALLTYPE GetUserTilePathBySize( const wchar_t *userSid, unsigned int size, wchar_t **pPath ) = 0;
	virtual HRESULT STDMETHODCALLTYPE GetDynamicPathBySize( const wchar_t *userSid, unsigned int size, wchar_t **pPath ) = 0;
};

static CLSID CLSID_UserTileStore={0x09c5dd34, 0x009d, 0x40fa, {0xbc, 0xb9, 0x01, 0x65, 0xad, 0x0c, 0x15, 0xd4}};

static void StretchBlt2( HDC hdcDest, int xDest, int yDest, int wDest, int hDest, HDC hdcSrc, int xSrc, int ySrc, int wSrc, int hSrc, bool bAlpha )
{
	if (wDest>0 && hDest>0 && wSrc>0 && hSrc>0)
	{
		if (bAlpha)
			AlphaBlend(hdcDest,xDest,yDest,wDest,hDest,hdcSrc,xSrc,ySrc,wSrc,hSrc,g_AlphaFunc);
		else if (wDest==wSrc && hDest==hSrc)
		{
			// HACK: when blitting RTL image with no stretching, StretchBlt adds 1 pixel offset. use BitBlt instead
			BitBlt(hdcDest,xDest,yDest,wDest,hDest,hdcSrc,xSrc,ySrc,SRCCOPY);
		}
		else
			StretchBlt(hdcDest,xDest,yDest,wDest,hDest,hdcSrc,xSrc,ySrc,wSrc,hSrc,SRCCOPY);
	}
}

HBITMAP CMenuContainer::LoadUserImage( int size, HBITMAP hMask )
{
	wchar_t path[_MAX_PATH];
	path[0]=0;
	CString str=GetSettingString(L"UserPicturePath");
	if (str.IsEmpty())
	{
		if (GetWinVersion()==WIN_VER_WIN8)
		{
			CComPtr<IUserTileStore8> pStore;
			pStore.CoCreateInstance(CLSID_UserTileStore);
			if (pStore)
			{
				CComString pPath;
				if (SUCCEEDED(pStore->GetDynamicPathBySize(NULL,size,&pPath)) || SUCCEEDED(pStore->GetUserTilePathBySize(NULL,size,&pPath)))
					Strcpy(path,_countof(path),pPath);
			}
		}
		else if (GetWinVersion()==WIN_VER_WIN81)
		{
			CComPtr<IUserTileStore81> pStore;
			pStore.CoCreateInstance(CLSID_UserTileStore);
			if (pStore)
			{
				CComString pPath;
				if (SUCCEEDED(pStore->GetDynamicPathBySize(NULL,size,&pPath)) || SUCCEEDED(pStore->GetUserTilePathBySize(NULL,size,&pPath)))
					Strcpy(path,_countof(path),pPath);
			}
		}
		else if (GetWinVersion()>=WIN_VER_WIN10)
		{
			CComPtr<IUserTileStore10> pStore;
			pStore.CoCreateInstance(CLSID_UserTileStore);
			if (pStore)
			{
				CComString pPath;
				if (SUCCEEDED(pStore->GetDynamicPathBySize(NULL,size,&pPath)) || SUCCEEDED(pStore->GetUserTilePathBySize(NULL,size,&pPath)))
					Strcpy(path,_countof(path),pPath);
			}
		}
		if (!path[0])
		{
			HMODULE hShell32=GetModuleHandle(L"shell32.dll");
			typedef HRESULT (__stdcall*tSHGetUserPicturePath)(LPCWSTR, UINT, LPWSTR, ULONG);
			tSHGetUserPicturePath SHGetUserPicturePath=(tSHGetUserPicturePath)GetProcAddress(hShell32,MAKEINTRESOURCEA(261));
			if (SHGetUserPicturePath)
				SHGetUserPicturePath(NULL,0x80000000,path,_countof(path));
		}
	}
	else
	{
		Strcpy(path,_countof(path),str);
		DoEnvironmentSubst(path,_countof(path));
	}
	HBITMAP hBitmap=NULL;
	if (path[0])
	{
		LOG_MENU(LOG_OPEN,L"Loading user image: '%s'",path);
		SIZE s={size,size};
		if (str.IsEmpty())
			hBitmap=LoadImageFile(path,&s,false,false,NULL);
		else
			hBitmap=LoadImageFile(path,&s,true,true,NULL);
	}
	if (hBitmap && hMask)
	{
		BITMAP info1, info2;
		GetObject(hBitmap,sizeof(info1),&info1);
		GetObject(hMask,sizeof(info2),&info2);
		if (info1.bmBits && info2.bmBits && info1.bmWidth==info2.bmWidth && info1.bmHeight==info2.bmHeight && info1.bmBitsPixel==32 && info2.bmBitsPixel==32)
		{
			unsigned char *pixels1=(unsigned char*)info1.bmBits;
			const unsigned char *pixels2=(const unsigned char*)info2.bmBits;
			int n=info1.bmWidth*info1.bmHeight;
			bool bHasAlpha=false;
			pixels1+=3;
			for (int i=0;i<n;i++, pixels1+=4)
				if (*pixels1)
				{
					bHasAlpha=true;
					break;
				}

			pixels1=(unsigned char*)info1.bmBits;
			for (int i=0;i<n;i++, pixels1+=4, pixels2+=4)
			{
				int r=pixels1[0];
				int g=pixels1[1];
				int b=pixels1[2];
				int a=pixels1[3];
				int mask=pixels2[3];
				pixels1[0]=(unsigned char)(r*mask/255);
				pixels1[1]=(unsigned char)(g*mask/255);
				pixels1[2]=(unsigned char)(b*mask/255);
				pixels1[3]=(unsigned char)(bHasAlpha?(a*mask/255):mask);
			}
		}
	}
	return hBitmap;
}

void MarginsBlit( HDC hSrc, HDC hDst, const RECT &rSrc, const RECT &rDst, const RECT &rMargins, bool bAlpha )
{
	int x0a=rDst.left;
	int x1a=rDst.left+rMargins.left;
	if (x1a>rDst.right) x1a=rDst.right;
	int x2a=rDst.right-rMargins.right;
	if (x2a<rDst.left) x2a=rDst.left;
	if (x1a>x2a) x1a=x2a=(x1a+x2a)/2;
	int x3a=rDst.right;
	int x0b=rSrc.left;
	int x1b=rSrc.left+rMargins.left;
	int x2b=rSrc.right-rMargins.right;
	int x3b=rSrc.right;

	int y0a=rDst.top;
	int y1a=rDst.top+rMargins.top;
	if (y1a>rDst.bottom) y1a=rDst.bottom;
	int y2a=rDst.bottom-rMargins.bottom;
	if (y2a<rDst.top) y2a=rDst.top;
	if (y1a>y2a) y1a=y2a=(y1a+y2a)/2;
	int y3a=rDst.bottom;
	int y0b=rSrc.top;
	int y1b=rSrc.top+rMargins.top;
	int y2b=rSrc.bottom-rMargins.bottom;
	int y3b=rSrc.bottom;

	SetStretchBltMode(hDst,COLORONCOLOR);
	StretchBlt2(hDst,x0a,y0a,x1a-x0a,y1a-y0a,hSrc,x0b,y0b,x1b-x0b,y1b-y0b,bAlpha);
	StretchBlt2(hDst,x1a,y0a,x2a-x1a,y1a-y0a,hSrc,x1b,y0b,x2b-x1b,y1b-y0b,bAlpha);
	StretchBlt2(hDst,x2a,y0a,x3a-x2a,y1a-y0a,hSrc,x2b,y0b,x3b-x2b,y1b-y0b,bAlpha);

	StretchBlt2(hDst,x0a,y1a,x1a-x0a,y2a-y1a,hSrc,x0b,y1b,x1b-x0b,y2b-y1b,bAlpha);
	StretchBlt2(hDst,x1a,y1a,x2a-x1a,y2a-y1a,hSrc,x1b,y1b,x2b-x1b,y2b-y1b,bAlpha);
	StretchBlt2(hDst,x2a,y1a,x3a-x2a,y2a-y1a,hSrc,x2b,y1b,x3b-x2b,y2b-y1b,bAlpha);

	StretchBlt2(hDst,x0a,y2a,x1a-x0a,y3a-y2a,hSrc,x0b,y2b,x1b-x0b,y3b-y2b,bAlpha);
	StretchBlt2(hDst,x1a,y2a,x2a-x1a,y3a-y2a,hSrc,x1b,y2b,x2b-x1b,y3b-y2b,bAlpha);
	StretchBlt2(hDst,x2a,y2a,x3a-x2a,y3a-y2a,hSrc,x2b,y2b,x3b-x2b,y3b-y2b,bAlpha);
}

struct PatternInfo
{
	int index;
	SIZE size;
	int offsetX;
	int maskShift;
	unsigned int otherMask;
	const std::vector<unsigned int> *bits;
	const unsigned int *bitsY;
	int stride;
};

static HBITMAP CreateMaskedEmblem( HBITMAP bmpEmblem, RECT &rcEmblem, const unsigned int *EMaskBits, int maskWidth, int maskHeight, int channel )
{
	if (channel<3) channel=2-channel;
	int minx=rcEmblem.left<0?0:rcEmblem.left;
	int maxx=rcEmblem.right>maskWidth?maskWidth:rcEmblem.right;
	int miny=rcEmblem.top<0?0:rcEmblem.top;
	int maxy=rcEmblem.bottom>maskHeight?maskHeight:rcEmblem.bottom;
	Assert(minx<maxx && miny<maxy);

	BITMAPINFO dib={sizeof(dib)};
	dib.bmiHeader.biWidth=maxx-minx;
	dib.bmiHeader.biHeight=miny-maxy;
	dib.bmiHeader.biPlanes=1;
	dib.bmiHeader.biBitCount=32;
	dib.bmiHeader.biCompression=BI_RGB;

	HDC hdc=CreateCompatibleDC(NULL);
	unsigned int *dstBits;
	HBITMAP maskedEmblem=CreateDIBSection(hdc,&dib,DIB_RGB_COLORS,(void**)&dstBits,NULL,0);
	DeleteDC(hdc);

	BITMAP info;
	GetObject(bmpEmblem,sizeof(info),&info);

	const unsigned char *srcMask=(unsigned char*)(EMaskBits+miny*maskWidth+minx)+channel;
	const unsigned char *srcBits=(unsigned char*)info.bmBits+(info.bmHeight-rcEmblem.top+miny-1)*info.bmWidthBytes+(minx-rcEmblem.left)*(info.bmBitsPixel/8);
	for (int y=miny;y<maxy;y++, srcMask+=maskWidth*4, srcBits-=info.bmWidthBytes)
	{
		const unsigned char *srcMask2=srcMask;
		const unsigned char *srcBits2=srcBits;
		if (info.bmBitsPixel==32)
		{
			ptrdiff_t start=(char*)srcBits2-(char*)info.bmBits;
			Assert(start>=0 && start+(maxx-minx)*4<=info.bmHeight*info.bmWidthBytes);
			for (int x=minx;x<maxx;x++,srcMask2+=4,srcBits2+=4,dstBits++)
			{
				int mask=*srcMask2;
				int r=(srcBits2[2]*mask)/255;
				int g=(srcBits2[1]*mask)/255;
				int b=(srcBits2[0]*mask)/255;
				int a=(srcBits2[3]*mask)/255;
				*dstBits=(a<<24)|(r<<16)|(g<<8)|b;
			}
		}
		else if (info.bmBitsPixel==24)
		{
			ptrdiff_t start=(char*)srcBits2-(char*)info.bmBits;
			Assert(start>=0 && start+(maxx-minx)*3<=info.bmHeight*info.bmWidthBytes);
			for (int x=minx;x<maxx;x++,srcMask2+=4,srcBits2+=3,dstBits++)
			{
				int mask=*srcMask2;
				int r=(srcBits2[2]*mask)/255;
				int g=(srcBits2[1]*mask)/255;
				int b=(srcBits2[0]*mask)/255;
				*dstBits=(mask<<24)|(r<<16)|(g<<8)|b;
			}
		}
	}

	rcEmblem.left=minx;
	rcEmblem.right=maxx;
	rcEmblem.top=miny;
	rcEmblem.bottom=maxy;

	return maskedEmblem;
}

void CMenuContainer::BlendPatterns( unsigned int *bits, int width, int height )
{
	s_Skin.PretilePatterns(width);
	LARGE_INTEGER time0;
	QueryPerformanceCounter(&time0);
	LARGE_INTEGER freq;
	QueryPerformanceFrequency(&freq);

	PatternInfo patterns[4];
	int patCount=0;
	unsigned int patMask=0;
	const int maskShift[4]={16,8,0,24};
	for (int i=0;i<4;i++)
	{
		if (s_Skin.Patterns[i].GetBitmap())
		{
			PatternInfo &pattern=patterns[patCount++];
			pattern.size=s_Skin.Pattern_sizes[i];
			pattern.index=i;
			pattern.maskShift=maskShift[i];
			pattern.otherMask=~(255<<pattern.maskShift);
			patMask|=255<<pattern.maskShift;
			pattern.bits=&s_Skin.PatternBits[i];
			pattern.stride=(int)pattern.bits->size()/pattern.size.cy;
		}
	}

	for (int y=0;y<height;y++)
	{
		for (int i=0;i<patCount;i++)
		{
			PatternInfo &pattern=patterns[i];
			pattern.bitsY=&(*pattern.bits)[(y%pattern.size.cy)*pattern.stride];
			pattern.offsetX=0;
		}

		for (int x=0;x<width;x++,bits++)
		{
			unsigned int &pixel=*bits;
			if ((pixel&patMask)==0)
			{
				pixel=0;
				continue;
			}
			int a=0, r=0, g=0, b=0;
			for (int i=0;i<patCount;i++)
			{
				const PatternInfo &pattern=patterns[i];
				int mask=(pixel>>pattern.maskShift)&255;
				if (mask==0) continue;

				unsigned int pat=pattern.bitsY[x];
				if ((pixel&pattern.otherMask)==0)
				{
					// fast path if only one channel is set
					int pa=pat>>24;
					if (pa)
					{
						if (mask==255)
						{
							// even faster path for straight copy
							pixel=pat;
						}
						else
						{
							mask++; // a cheat to make the mask from 1 to 256, so we can use >>8 instead of /255
							a=(pa*mask)>>8;
							if (a==0)
							{
								pixel=0;
							}
							else
							{
								r=(((pat>>16)&255)*mask)>>8;
								g=(((pat>>8)&255)*mask)>>8;
								b=((pat&255)*mask)>>8;
								pixel=(a<<24)|(r<<16)|(g<<8)|b;
							}
						}
					}
					else
						pixel=0;
					goto end;
				}
				int pa=pat>>24;
				if (pa)
				{
					a+=pa*mask;
					r+=((pat>>16)&255)*mask;
					g+=((pat>>8)&255)*mask;
					b+=(pat&255)*mask;
				}
			}
			a/=255;
			if (a==0)
			{
				pixel=0;
			}
			else
			{
				if (a>255) a=255;
				r/=255; if (r>255) r=255;
				g/=255; if (g>255) g=255;
				b/=255; if (b>255) b=255;
				pixel=(a<<24)|(r<<16)|(g<<8)|b;
			}
end:;
		}
	}

	LARGE_INTEGER time;
	QueryPerformanceCounter(&time);
	LONGLONG dt=(time.QuadPart-time0.QuadPart)*1000000/freq.QuadPart;
//	Trace("BlendPatterns: %.3f ms",(int)dt/1000.f);
}

// Creates the bitmap for the background
void CMenuContainer::CreateBackground( int width1, int width2, int height1, int height2, int &totalWidth, int &totalHeight, bool bCreateRegion )
{
	// get the text from the ini file or from the registry
	wchar_t caption[256];
	Strcpy(caption,_countof(caption),GetSettingString(L"MenuCaption"));
	DoEnvironmentSubst(caption,_countof(caption));

	MenuBitmap bmpSkin;
	MenuBitmap bmpSkinPattern;
	MenuBitmap bmpSkinEmblem;
	const int *slicesX, *slicesY;
	if (s_MenuMode==MODE_SEARCH)
	{
		bmpSkin=s_Skin.Main_bitmap_search;
		slicesX=s_Skin.Main_bitmap_search_slices_X;
		slicesY=s_Skin.Main_bitmap_search_slices_Y;
		bmpSkinPattern=s_Skin.Main_pattern_search_mask;
		bmpSkinEmblem=s_Skin.Main_emblem_search_mask;
	}
	else if (s_MenuMode==MODE_JUMPLIST)
	{
		bmpSkin=s_Skin.Main_bitmap_jump;
		slicesX=s_Skin.Main_bitmap_jump_slices_X;
		slicesY=s_Skin.Main_bitmap_jump_slices_Y;
		bmpSkinPattern=s_Skin.Main_pattern_jump_mask;
		bmpSkinEmblem=s_Skin.Main_emblem_jump_mask;
	}
	else
	{
		bmpSkin=s_Skin.Main_bitmap;
		slicesX=s_Skin.Main_bitmap_slices_X;
		slicesY=s_Skin.Main_bitmap_slices_Y;
		bmpSkinPattern=s_Skin.Main_pattern_mask;
		bmpSkinEmblem=s_Skin.Main_emblem_mask;
	}
	bool bCaption=(slicesX[1]>0);
	MenuSkin::TOpacity opacity=s_Skin.Main_opacity;

	HDC hdcTemp=CreateCompatibleDC(NULL);

	HFONT font0=NULL;
	if (bCaption)
		font0=(HFONT)SelectObject(hdcTemp,s_Skin.Caption_font);

	RECT rc={0,0,0,0};
	DTTOPTS opts={sizeof(opts),DTT_COMPOSITED|DTT_CALCRECT};
	if (bCaption)
	{
		if (s_Theme)
			DrawThemeTextEx(s_Theme,hdcTemp,0,0,caption,-1,DT_NOPREFIX|DT_SINGLELINE|DT_CALCRECT,&rc,&opts);
		else
			DrawText(hdcTemp,caption,-1,&rc,DT_NOPREFIX|DT_SINGLELINE|DT_CALCRECT);
	}
	int textWidth=rc.right+s_Skin.Caption_padding.top+s_Skin.Caption_padding.bottom;
	int textHeight=rc.bottom+s_Skin.Caption_padding.left+s_Skin.Caption_padding.right;

	int total=slicesX[0]+slicesX[2];
	if (textHeight<total) textHeight=total;

	RECT menuPadding[2];
	if (s_MenuMode==MODE_SEARCH)
	{
		menuPadding[0]=s_Skin.Main_search_padding;
		memset(&menuPadding[1],0,sizeof(menuPadding[1]));
	}
	else if (s_MenuMode==MODE_JUMPLIST)
	{
		menuPadding[0]=s_Skin.Main_padding;
		menuPadding[1]=s_Skin.Main_jump_padding;
	}
	else
	{
		menuPadding[0]=s_Skin.Main_padding;
		menuPadding[1]=s_Skin.Main2_padding;
	}

	int totalWidth1=textHeight+width1;
	totalWidth1+=menuPadding[0].left+menuPadding[0].right;
	if (totalWidth1<total) totalWidth1=total;
	int totalWidth2=0;
	if (m_bTwoColumns)
		totalWidth2=width2+menuPadding[1].left+menuPadding[1].right;
	totalWidth=totalWidth1+totalWidth2;

	totalHeight=height1+menuPadding[0].top+menuPadding[0].bottom;
	if (m_bTwoColumns)
	{
		int totalHeight2=height2+menuPadding[1].top+menuPadding[1].bottom;
		if (totalHeight<totalHeight2) totalHeight=totalHeight2;
	}

	total=slicesY[0]+slicesY[2];
	if (m_SearchIndex>=0 && s_bWin7Style)
		total+=slicesY[3]+slicesY[5];
	if (totalHeight<total) totalHeight=total;
	if (textWidth>totalHeight) textWidth=totalHeight;

	m_rContent.left=menuPadding[0].left+textHeight;
	m_rContent.right=totalWidth1-menuPadding[0].right;
	m_rContent.top=menuPadding[0].top;
	m_rContent.bottom=m_rContent.top+height1;
	if (totalWidth2>0)
	{
		m_rContent2.left=m_rContent.right+menuPadding[0].right+menuPadding[1].left;
		m_rContent2.right=totalWidth-menuPadding[1].right;
		m_rContent2.top=menuPadding[1].top;
		m_rContent2.bottom=m_rContent2.top+height2;
	}

	MenuBitmap bmpSearch;
	MenuBitmap bmpSearchPattern;
	MenuBitmap bmpSearchEmblem;
	int *searchSlicesX, *searchSlicesY;
	RECT searchPadding;
	int searchX[4], searchY[4];
	if (m_SearchIndex>=0 && s_bWin7Style)
	{
		if (s_MenuMode==MODE_SEARCH)
		{
			bmpSearch=s_Skin.Search_background_search;
			bmpSearchPattern=s_Skin.Search_pattern_search_mask;
			bmpSearchEmblem=s_Skin.Search_emblem_search_mask;
			searchSlicesX=s_Skin.Search_background_search_slices_X;
			searchSlicesY=s_Skin.Search_background_search_slices_Y;
			searchPadding=s_Skin.Search_background_search_padding;
		}
		else if (s_MenuMode==MODE_JUMPLIST)
		{
			bmpSearch=s_Skin.Search_background_jump;
			bmpSearchPattern=s_Skin.Search_pattern_jump_mask;
			bmpSearchEmblem=s_Skin.Search_emblem_jump_mask;
			searchSlicesX=s_Skin.Search_background_jump_slices_X;
			searchSlicesY=s_Skin.Search_background_jump_slices_Y;
			searchPadding=s_Skin.Search_background_jump_padding;
		}
		else
		{
			bmpSearch=s_Skin.Search_background;
			bmpSearchPattern=s_Skin.Search_pattern_mask;
			bmpSearchEmblem=s_Skin.Search_emblem_mask;
			searchSlicesX=s_Skin.Search_background_slices_X;
			searchSlicesY=s_Skin.Search_background_slices_Y;
			searchPadding=s_Skin.Search_background_padding;
		}

		const MenuSkin::ItemDrawSettings &settings=s_Skin.ItemSettings[MenuSkin::COLUMN1_ITEM];
		int searchH=settings.textMetrics.tmHeight*12/8+s_Skin.Search_padding.top+s_Skin.Search_padding.bottom; // 12 DLUs
		int searchW=settings.textMetrics.tmAveCharWidth*25;

		RECT searchRect;
		if (A4SMenuProfile::IsEnabled())
			A4SMenuProfile::GetSearchRect(searchRect,s_Skin.Dpi);
		else
		{
			searchRect.left=m_rContent.left+s_Skin.Search_padding.left;
			searchRect.top=m_rContent.bottom-searchH+s_Skin.Search_padding.top;
			searchRect.bottom=m_rContent.bottom-s_Skin.Search_padding.bottom;
			searchRect.right=m_rContent.right-s_Skin.Search_padding.right;
		}

		RECT editRect;
		if (m_SearchBox.m_hWnd)
		{
			m_SearchBox.GetWindowRect(&editRect);
			::MapWindowPoints(NULL,m_hWnd,(POINT*)&editRect,2);
			OffsetRect(&editRect,-m_BitmapOffset,0);
			if (!A4SMenuProfile::IsEnabled())
			{
				searchRect.right=editRect.right;
				if (!s_Skin.Search_frame)
					searchRect.right++;
			}
		}
		else
		{
			GetSearchEditRect(searchRect,editRect);
		}

		searchX[0]=m_rContent.left-searchPadding.left;
		searchX[1]=editRect.left;
		searchX[2]=searchRect.right+s_Skin.Search_padding.right;
		searchX[3]=((s_MenuMode==MODE_JUMPLIST)?m_rContent2.right:m_rContent.right)+searchPadding.right;
		searchY[0]=searchRect.top-s_Skin.Search_padding.top-searchPadding.top;
		searchY[1]=editRect.top-2;
		searchY[2]=editRect.bottom+2;
		searchY[3]=m_rContent.bottom+searchPadding.bottom;
		if (A4SMenuProfile::IsEnabled())
		{
			searchX[0]=searchRect.left;
			searchX[3]=searchRect.right;
			searchY[0]=searchRect.top;
			searchY[3]=searchRect.bottom;
		}
	}

	BITMAPINFO dib={sizeof(dib)};
	dib.bmiHeader.biWidth=totalWidth;
	dib.bmiHeader.biHeight=-totalHeight;
	dib.bmiHeader.biPlanes=1;
	dib.bmiHeader.biBitCount=32;
	dib.bmiHeader.biCompression=BI_RGB;

	HDC hdc=CreateCompatibleDC(NULL);
	unsigned int *bits;
	m_Bitmap=CreateDIBSection(hdc,&dib,DIB_RGB_COLORS,(void**)&bits,NULL,0);
	HGDIOBJ bmp0=SelectObject(hdc,m_Bitmap);
	memset(bits,0,totalWidth*totalHeight*sizeof(*bits));

	if (opacity==MenuSkin::OPACITY_SOLID)
	{
		RECT rc={0,0,totalWidth,totalHeight};
		SetDCBrushColor(hdc,s_Skin.Main_background);
		FillRect(hdc,&rc,(HBRUSH)GetStockObject(DC_BRUSH));
	}

	bool bHasPattern=false;
	if (s_Skin.Patterns[0].GetBitmap() || s_Skin.Patterns[1].GetBitmap() || s_Skin.Patterns[2].GetBitmap() || s_Skin.Patterns[3].GetBitmap())
	{
		bHasPattern=(bmpSkinPattern.GetBitmap() || bmpSkinPattern.GetColor() || bmpSearchPattern.GetBitmap() || bmpSearchPattern.GetColor());
	}

	bool bHasEmblemMask=false;
	if (s_Skin.Main_emblems[0].GetBitmap() || s_Skin.Main_emblems[1].GetBitmap() || s_Skin.Main_emblems[2].GetBitmap() || s_Skin.Main_emblems[3].GetBitmap())
	{
		bHasEmblemMask=(bmpSkinEmblem.GetBitmap() || bmpSkinEmblem.GetColor() || bmpSearchEmblem.GetBitmap() || bmpSearchEmblem.GetColor());
	}

	HBITMAP PMaskBmp=NULL, EMaskBmp=NULL;
	unsigned int *PMaskBits=NULL, *EMaskBits=NULL;
	HGDIOBJ bmp02=GetCurrentObject(hdcTemp,OBJ_BITMAP);

	HDC hdcPMask=NULL, hdcEMask=NULL;
	HDC hdcPMaskTemp=NULL, hdcEMaskTemp=NULL;
	HGDIOBJ PMaskBmp0=NULL, PMaskBmp02=NULL, EMaskBmp0=NULL, EMaskBmp02=NULL;
	if (bHasPattern)
	{
		hdcPMask=CreateCompatibleDC(NULL);
		PMaskBmp=CreateDIBSection(hdcPMask,&dib,DIB_RGB_COLORS,(void**)&PMaskBits,NULL,0);
		PMaskBmp0=SelectObject(hdcPMask,PMaskBmp);
		hdcPMaskTemp=CreateCompatibleDC(NULL);
		PMaskBmp02=GetCurrentObject(hdcPMaskTemp,OBJ_BITMAP);
	}
	if (bHasEmblemMask)
	{
		hdcEMask=CreateCompatibleDC(NULL);
		EMaskBmp=CreateDIBSection(hdcEMask,&dib,DIB_RGB_COLORS,(void**)&EMaskBits,NULL,0);
		EMaskBmp0=SelectObject(hdcEMask,EMaskBmp);
		hdcEMaskTemp=CreateCompatibleDC(NULL);
		EMaskBmp02=GetCurrentObject(hdcEMaskTemp,OBJ_BITMAP);
	}

	if (bmpSkin.GetBitmap())
	{
		// draw the skinned background
		SelectObject(hdcTemp,bmpSkin.GetBitmap());

		if (bHasPattern)
		{
			if (bmpSkinPattern.GetBitmap())
			{
				SelectObject(hdcPMaskTemp,bmpSkinPattern.GetBitmap());
			}
			else
			{
				RECT rc={0,0,totalWidth,totalHeight};
				SetDCBrushColor(hdcPMask,bmpSkinPattern.GetColor());
				FillRect(hdcPMask,&rc,(HBRUSH)GetStockObject(DC_BRUSH));
			}
		}

		if (bHasEmblemMask)
		{
			if (bmpSkinEmblem.GetBitmap())
			{
				SelectObject(hdcEMaskTemp,bmpSkinEmblem.GetBitmap());
			}
			else
			{
				RECT rc={0,0,totalWidth,totalHeight};
				SetDCBrushColor(hdcEMask,bmpSkinEmblem.GetColor());
				FillRect(hdcEMask,&rc,(HBRUSH)GetStockObject(DC_BRUSH));
			}
		}

		int searchHeight=0;
		if (m_SearchIndex>=0 && s_bWin7Style && slicesY[3]+slicesY[4]+slicesY[5]>0)
			searchHeight=m_Items[m_SearchIndex].itemRect.top-s_Skin.Search_padding.top-searchPadding.top;

		RECT rSrc={0,0,slicesX[0]+slicesX[1]+slicesX[2],slicesY[0]+slicesY[1]+slicesY[2]};
		RECT rDst={0,0,textHeight,searchHeight?searchHeight:totalHeight};
		RECT rMargins={slicesX[0],slicesY[0],slicesX[2],slicesY[2]};
		MarginsBlit(hdcTemp,hdc,rSrc,rDst,rMargins,(opacity==MenuSkin::OPACITY_SOLID && bmpSkin.bIs32));
		if (bmpSkinPattern.GetBitmap())
			MarginsBlit(hdcPMaskTemp,hdcPMask,rSrc,rDst,rMargins,false);
		if (bmpSkinEmblem.GetBitmap())
			MarginsBlit(hdcEMaskTemp,hdcEMask,rSrc,rDst,rMargins,false);

		rSrc.left=rSrc.right;
		rSrc.right+=slicesX[3]+slicesX[4]+slicesX[5];
		rDst.left=rDst.right;
		rDst.right=totalWidth1;
		rMargins.left=slicesX[3];
		rMargins.right=slicesX[5];
		MarginsBlit(hdcTemp,hdc,rSrc,rDst,rMargins,(opacity==MenuSkin::OPACITY_SOLID && bmpSkin.bIs32));
		if (bmpSkinPattern.GetBitmap())
			MarginsBlit(hdcPMaskTemp,hdcPMask,rSrc,rDst,rMargins,false);
		if (bmpSkinEmblem.GetBitmap())
			MarginsBlit(hdcEMaskTemp,hdcEMask,rSrc,rDst,rMargins,false);

		if (searchHeight>0)
		{
			RECT rSrc2=rSrc, rDst2=rDst, rMargins2=rMargins;
			rSrc2.top=rSrc.bottom;
			rSrc2.bottom+=slicesY[3]+slicesY[4]+slicesY[5];
			rDst2.top=rDst.bottom;
			rDst2.bottom=totalHeight;
			rMargins2.top=slicesY[3];
			rMargins2.bottom=slicesY[5];
			MarginsBlit(hdcTemp,hdc,rSrc2,rDst2,rMargins2,(opacity==MenuSkin::OPACITY_SOLID && bmpSkin.bIs32));
			if (bmpSkinPattern.GetBitmap())
				MarginsBlit(hdcPMaskTemp,hdcPMask,rSrc2,rDst2,rMargins2,false);
			if (bmpSkinEmblem.GetBitmap())
				MarginsBlit(hdcEMaskTemp,hdcEMask,rSrc2,rDst2,rMargins2,false);
		}

		if (totalWidth2>0)
		{
			rSrc.left=rSrc.right;
			rSrc.right+=slicesX[6]+slicesX[7]+slicesX[8];
			rDst.left=rDst.right;
			rDst.right+=totalWidth2;
			rMargins.left=slicesX[6];
			rMargins.right=slicesX[8];
			MarginsBlit(hdcTemp,hdc,rSrc,rDst,rMargins,(opacity==MenuSkin::OPACITY_SOLID && bmpSkin.bIs32));
			if (bmpSkinPattern.GetBitmap())
				MarginsBlit(hdcPMaskTemp,hdcPMask,rSrc,rDst,rMargins,false);
			if (bmpSkinEmblem.GetBitmap())
				MarginsBlit(hdcEMaskTemp,hdcEMask,rSrc,rDst,rMargins,false);

			if (searchHeight>0)
			{
				RECT rSrc2=rSrc, rDst2=rDst, rMargins2=rMargins;
				rSrc2.top=rSrc.bottom;
				rSrc2.bottom+=slicesY[3]+slicesY[4]+slicesY[5];
				rDst2.top=rDst.bottom;
				rDst2.bottom=totalHeight;
				rMargins2.top=slicesY[3];
				rMargins2.bottom=slicesY[5];
				MarginsBlit(hdcTemp,hdc,rSrc2,rDst2,rMargins2,(opacity==MenuSkin::OPACITY_SOLID && bmpSkin.bIs32));
				if (bmpSkinPattern.GetBitmap())
					MarginsBlit(hdcPMaskTemp,hdcPMask,rSrc2,rDst2,rMargins2,false);
				if (bmpSkinEmblem.GetBitmap())
					MarginsBlit(hdcEMaskTemp,hdcEMask,rSrc2,rDst2,rMargins2,false);
			}
		}
	}
	else
	{
		RECT rc={0,0,totalWidth,totalHeight};
		if (!A4SMenuProfile::IsEnabled())
		{
			SetDCBrushColor(hdc,s_Skin.Main_background);
			FillRect(hdc,&rc,(HBRUSH)GetStockObject(DC_BRUSH));
		}

		if (bHasPattern)
		{
			SetDCBrushColor(hdcPMask,bmpSkinPattern.GetColor());
			FillRect(hdcPMask,&rc,(HBRUSH)GetStockObject(DC_BRUSH));
		}
		if (bHasEmblemMask)
		{
			SetDCBrushColor(hdcEMask,bmpSkinEmblem.GetColor());
			FillRect(hdcEMask,&rc,(HBRUSH)GetStockObject(DC_BRUSH));
		}
	}

	if (m_SearchIndex>=0 && s_bWin7Style)
	{
		// draw the search background
		if (bmpSearch.GetBitmap())
		{
			if (bHasPattern)
			{
				if (bmpSearchPattern.GetBitmap())
				{
					SelectObject(hdcPMaskTemp,bmpSearchPattern.GetBitmap());
				}
				else if (!bmpSearchPattern.bIsBitmap)
				{
					RECT rc={searchX[0],searchY[0],searchX[3],searchY[3]};
					SetDCBrushColor(hdcPMask,bmpSearchPattern.GetColor());
					FillRect(hdcPMask,&rc,(HBRUSH)GetStockObject(DC_BRUSH));
				}
			}
			if (bHasEmblemMask)
			{
				if (bmpSearchEmblem.GetBitmap())
				{
					SelectObject(hdcEMaskTemp,bmpSearchEmblem.GetBitmap());
				}
				else if (!bmpSearchEmblem.bIsBitmap)
				{
					RECT rc={searchX[0],searchY[0],searchX[3],searchY[3]};
					SetDCBrushColor(hdcEMask,bmpSearchEmblem.GetColor());
					FillRect(hdcEMask,&rc,(HBRUSH)GetStockObject(DC_BRUSH));
				}
			}

			int u[4], v[4];
			u[0]=0;
			u[1]=searchSlicesX[0]+searchSlicesX[1]+searchSlicesX[2];
			u[2]=u[1]+searchSlicesX[3]+searchSlicesX[4]+searchSlicesX[5];
			u[3]=u[2]+searchSlicesX[6]+searchSlicesX[7]+searchSlicesX[8];
			v[0]=0;
			v[1]=searchSlicesY[0]+searchSlicesY[1]+searchSlicesY[2];
			v[2]=v[1]+searchSlicesY[3]+searchSlicesY[4]+searchSlicesY[5];
			v[3]=v[2]+searchSlicesY[6]+searchSlicesY[7]+searchSlicesY[8];
			SelectObject(hdcTemp,bmpSearch.GetBitmap());
			for (int y=0;y<3;y++)
			{
				for (int x=0;x<3;x++)
				{
					RECT rDst={searchX[x],searchY[y],searchX[x+1],searchY[y+1]};
					RECT rSrc={u[x],v[y],u[x+1],v[y+1]};
					RECT rMargins={searchSlicesX[x*3],searchSlicesY[y*3],searchSlicesX[x*3+2],searchSlicesY[y*3+2]};
					MarginsBlit(hdcTemp,hdc,rSrc,rDst,rMargins,bmpSearch.bIs32);
					if (bmpSearchPattern.GetBitmap())
						MarginsBlit(hdcPMaskTemp,hdcPMask,rSrc,rDst,rMargins,bmpSearchPattern.bIs32);
					if (bmpSearchEmblem.GetBitmap())
						MarginsBlit(hdcEMaskTemp,hdcEMask,rSrc,rDst,rMargins,bmpSearchPattern.bIs32);
				}
			}
		}
		else if (!bmpSearch.bIsBitmap)
		{
			RECT rDst={searchX[0],searchY[0],searchX[3],searchY[3]};
			if (A4SMenuProfile::IsEnabled())
				DrawA4SSearchSurface(hdc,rDst,s_Skin.Dpi);
			else
			{
				SetDCBrushColor(hdc,bmpSearch.GetColor());
				FillRect(hdc,&rDst,(HBRUSH)GetStockObject(DC_BRUSH));
			}
			if (bHasPattern && !bmpSearchPattern.bIsBitmap)
			{
				SetDCBrushColor(hdcPMask,bmpSkinPattern.GetColor());
				FillRect(hdcPMask,&rc,(HBRUSH)GetStockObject(DC_BRUSH));
			}
			if (bHasEmblemMask && !bmpSearchEmblem.bIsBitmap)
			{
				SetDCBrushColor(hdcEMask,bmpSkinEmblem.GetColor());
				FillRect(hdcEMask,&rc,(HBRUSH)GetStockObject(DC_BRUSH));
			}
		}
	}

	if (bHasPattern)
	{
		if (PMaskBmp02)
			SelectObject(hdcPMaskTemp,PMaskBmp02);
		if (PMaskBmp0)
			SelectObject(hdcPMask,PMaskBmp0);
		if (hdcPMask)
			DeleteDC(hdcPMask);
		if (hdcPMaskTemp)
			DeleteDC(hdcPMaskTemp);

		// apply pattern
		BlendPatterns(PMaskBits,totalWidth,totalHeight);
		SelectObject(hdcTemp,PMaskBmp);
		AlphaBlend(hdc,0,0,totalWidth,totalHeight,hdcTemp,0,0,totalWidth,totalHeight,g_AlphaFunc);
		SelectObject(hdcTemp,bmp02);
		DeleteObject(PMaskBmp);
	}

	// draw vertical separator
	if (width2 && !A4SMenuProfile::IsEnabled())
	{
		if (s_Skin.Main_separatorV.GetBitmap())
		{
			SelectObject(hdcTemp,s_Skin.Main_separatorV.GetBitmap());
			RECT rSrc2={0,0,s_Skin.Main_separatorWidth,s_Skin.Main_separator_slices_Y[0]+s_Skin.Main_separator_slices_Y[1]+s_Skin.Main_separator_slices_Y[2]};
			RECT rDst2={totalWidth1,menuPadding[0].top,totalWidth1+s_Skin.Main_separatorWidth,totalHeight-menuPadding[0].bottom};
			if (s_bRTL)
			{
				rDst2.left=totalWidth-rDst2.right;
				rDst2.right=totalWidth-totalWidth1;
			}
			RECT rMargins2={0,s_Skin.Main_separator_slices_Y[0],0,s_Skin.Main_separator_slices_Y[2]};
			MarginsBlit(hdcTemp,hdc,rSrc2,rDst2,rMargins2,s_Skin.Main_separatorV.bIs32);
		}
		else if (!bmpSkin.GetBitmap()) // only when there is no main bitmap (it may have a built-in separator)
		{
			rc.left=rc.right=s_bRTL?(totalWidth-totalWidth1-2):totalWidth1;
			rc.top=menuPadding[0].top;
			rc.bottom=totalHeight-menuPadding[0].bottom;
			DrawEdge(hdc,&rc,EDGE_ETCHED,BF_LEFT);
		}
	}

	SelectObject(hdcTemp,bmp02);

	for (int i=0;i<_countof(s_Skin.Main_emblems);i++)
	{
		if (s_Skin.Main_emblems[i].GetBitmap())
		{
			const SIZE &emblemSize=s_Skin.Main_emblem_sizes[i];
			const RECT &emblemPadding=s_Skin.Main_emblem_paddings[i];
			MenuSkin::THAlign alignH=s_Skin.Main_emblem_alignH1[i];
			if (width2==0 && (alignH==MenuSkin::HALIGN_LEFT2 || alignH==MenuSkin::HALIGN_RIGHT2 || alignH==MenuSkin::HALIGN_CENTER2))
				alignH=s_Skin.Main_emblem_alignH2[i];
			if (alignH==MenuSkin::HALIGN_CORNER)
				alignH=(m_Options&CONTAINER_LEFT)?MenuSkin::HALIGN_LEFT:MenuSkin::HALIGN_RIGHT;
			MenuSkin::TVAlign alignV=s_Skin.Main_emblem_alignV[i];
			if (alignV==MenuSkin::VALIGN_CORNER)
				alignV=(m_Options&CONTAINER_TOP)?MenuSkin::VALIGN_TOP:MenuSkin::VALIGN_BOTTOM;
			if (alignH==MenuSkin::HALIGN_NONE || alignV==MenuSkin::VALIGN_NONE)
				continue;

			int w=emblemSize.cx+emblemPadding.left+emblemPadding.right;
			int h=emblemSize.cy+emblemPadding.top+emblemPadding.bottom;
			int x0=0, x1=totalWidth;
			int y0=0, y1=totalHeight;

			if (alignH==MenuSkin::HALIGN_CENTER1 || alignH==MenuSkin::HALIGN_LEFT1 || alignH==MenuSkin::HALIGN_RIGHT1)
				x1=totalWidth1;
			else if (alignH==MenuSkin::HALIGN_CENTER2 || alignH==MenuSkin::HALIGN_LEFT2 || alignH==MenuSkin::HALIGN_RIGHT2)
				x0=totalWidth1;
			if (alignH==MenuSkin::HALIGN_LEFT || alignH==MenuSkin::HALIGN_LEFT1 || alignH==MenuSkin::HALIGN_LEFT2)
				x1=x0+w;
			else if (alignH==MenuSkin::HALIGN_RIGHT || alignH==MenuSkin::HALIGN_RIGHT1 || alignH==MenuSkin::HALIGN_RIGHT2)
				x0=x1-w;
			else if (alignH==MenuSkin::HALIGN_CENTER || alignH==MenuSkin::HALIGN_CENTER1 || alignH==MenuSkin::HALIGN_CENTER2)
				x0=(x0+x1-w)/2, x1=x0+w;

			if (alignV==MenuSkin::VALIGN_TOP)
				y1=y0+h;
			else if (alignV==MenuSkin::VALIGN_BOTTOM)
				y0=y1-h;
			else if (alignV==MenuSkin::VALIGN_CENTER)
				y0=(y0+y1-h)/2, y1=y0+h;

			x0+=emblemPadding.left;
			y0+=emblemPadding.top;

			RECT rcEmblem={x0,y0,x0+emblemSize.cx,y0+emblemSize.cy};
			if (rcEmblem.left>=totalWidth || rcEmblem.right<0 || rcEmblem.top>=totalHeight || rcEmblem.bottom<0)
				continue;

			HBITMAP maskedEmblem=NULL;
			if (bHasEmblemMask && i<4)
				maskedEmblem=CreateMaskedEmblem(s_Skin.Main_emblems[i].GetBitmap(),rcEmblem,EMaskBits,totalWidth,totalHeight,i);

			if (maskedEmblem)
				SelectObject(hdcTemp,maskedEmblem);
			else
				SelectObject(hdcTemp,s_Skin.Main_emblems[i].GetBitmap());
			BLENDFUNCTION func={AC_SRC_OVER,0,255,AC_SRC_ALPHA};
			w=rcEmblem.right-rcEmblem.left;
			h=rcEmblem.bottom-rcEmblem.top;
			AlphaBlend(hdc,rcEmblem.left,rcEmblem.top,w,h,hdcTemp,0,0,w,h,func);
			SelectObject(hdcTemp,bmp02);
			if (maskedEmblem)
				DeleteObject(maskedEmblem);
		}
	}

	if (bHasEmblemMask)
	{
		if (EMaskBmp02)
			SelectObject(hdcEMaskTemp,EMaskBmp02);
		if (EMaskBmp0)
			SelectObject(hdcEMask,EMaskBmp0);
		if (hdcEMask)
			DeleteDC(hdcEMask);
		if (hdcEMaskTemp)
			DeleteDC(hdcEMaskTemp);
		DeleteObject(EMaskBmp);
	}

	if (s_bRTL)
	{
		SelectObject(hdc,bmp0); // deselect m_Bitmap so all the GDI operations get flushed
		// mirror the background image for RTL windows
		for (int y=0;y<totalHeight;y++)
		{
			int yw=y*totalWidth;
			std::reverse(bits+yw,bits+yw+totalWidth);
		}
		SelectObject(hdc,m_Bitmap);
	}

	if (bCaption)
	{
		// draw the title
		BITMAPINFO dib={sizeof(dib)};
		dib.bmiHeader.biWidth=textWidth;
		dib.bmiHeader.biHeight=-textHeight;
		dib.bmiHeader.biPlanes=1;
		dib.bmiHeader.biBitCount=32;
		dib.bmiHeader.biCompression=BI_RGB;

		unsigned int *bits2;
		HBITMAP bmpText=CreateDIBSection(hdcTemp,&dib,DIB_RGB_COLORS,(void**)&bits2,NULL,0);
		SelectObject(hdcTemp,bmpText);
		{
			RECT rc={0,0,textWidth,textHeight};
			FillRect(hdcTemp,&rc,(HBRUSH)GetStockObject(BLACK_BRUSH));
		}

		RECT rc={s_Skin.Caption_padding.bottom,s_bRTL?s_Skin.Caption_padding.right:s_Skin.Caption_padding.left,textWidth-s_Skin.Caption_padding.top,textHeight-(s_bRTL?s_Skin.Caption_padding.left:s_Skin.Caption_padding.right)};
		if (s_Theme && s_Skin.Caption_glow_size>0)
		{
			// draw the glow
			opts.dwFlags=DTT_COMPOSITED|DTT_TEXTCOLOR|DTT_GLOWSIZE;
			opts.crText=0xFFFFFF;
			opts.iGlowSize=s_Skin.Caption_glow_size;
			DrawThemeTextEx(s_Theme,hdcTemp,0,0,caption,-1,DT_VCENTER|DT_NOPREFIX|DT_SINGLELINE,&rc,&opts);
			SelectObject(hdcTemp,bmp02); // deselect bmpText so all the GDI operations get flushed

			// change the glow color
			int gr=(s_Skin.Caption_glow_color)&255;
			int gg=(s_Skin.Caption_glow_color>>8)&255;
			int gb=(s_Skin.Caption_glow_color>>16)&255;
			for (int y=0;y<textHeight;y++)
				for (int x=0;x<textWidth;x++)
				{
					unsigned int &pixel=bits2[y*textWidth+x];
					int a1=(pixel>>24);
					int r1=(pixel>>16)&255;
					int g1=(pixel>>8)&255;
					int b1=(pixel)&255;
					r1=(r1*gr)/255;
					g1=(g1*gg)/255;
					b1=(b1*gb)/255;
					pixel=(a1<<24)|(r1<<16)|(g1<<8)|b1;
				}

			SelectObject(hdcTemp,bmpText);
		}

		// draw the text
		int offset=0;
		if (s_bRTL)
			offset=totalWidth-textHeight;

		if (s_Theme)
		{
			opts.dwFlags=DTT_COMPOSITED|DTT_TEXTCOLOR;
			opts.crText=s_Skin.Caption_text_color;
			DrawThemeTextEx(s_Theme,hdcTemp,0,0,caption,-1,DT_VCENTER|DT_NOPREFIX|DT_SINGLELINE,&rc,&opts);
			SelectObject(hdcTemp,bmp02);

			// rotate and copy the text onto the final bitmap. Combine the alpha channels
			for (int y=0;y<textHeight;y++)
				for (int x=0;x<textWidth;x++)
				{
					unsigned int src=bits2[y*textWidth+x];
					int a1=(src>>24);
					int r1=(src>>16)&255;
					int g1=(src>>8)&255;
					int b1=(src)&255;

					unsigned int &dst=bits[(totalHeight-1-x)*totalWidth+y+offset];

					int a2=(dst>>24);
					int r2=(dst>>16)&255;
					int g2=(dst>>8)&255;
					int b2=(dst)&255;

					r2=(r2*(255-a1))/255+r1;
					g2=(g2*(255-a1))/255+g1;
					b2=(b2*(255-a1))/255+b1;
					a2=a1+a2-(a1*a2)/255;

					dst=(a2<<24)|(r2<<16)|(g2<<8)|b2;
				}
		}
		else
		{
			// draw white text on black background
			SetTextColor(hdcTemp,0xFFFFFF);
			SetBkMode(hdcTemp,TRANSPARENT);
			DrawText(hdcTemp,caption,-1,&rc,DT_VCENTER|DT_NOPREFIX|DT_SINGLELINE);
			SelectObject(hdcTemp,bmp02);

			// rotate and copy the text onto the final bitmap
			// change the text color
			int tr=(s_Skin.Caption_text_color>>16)&255;
			int tg=(s_Skin.Caption_text_color>>8)&255;
			int tb=(s_Skin.Caption_text_color)&255;
			for (int y=0;y<textHeight;y++)
				for (int x=0;x<textWidth;x++)
				{
					unsigned int src=bits2[y*textWidth+x];
					int a1=(src)&255;

					unsigned int &dst=bits[(totalHeight-1-x)*totalWidth+y+offset];

					int a2=(dst>>24);
					int r2=(dst>>16)&255;
					int g2=(dst>>8)&255;
					int b2=(dst)&255;

					r2=(r2*(255-a1)+tr*a1)/255;
					g2=(g2*(255-a1)+tg*a1)/255;
					b2=(b2*(255-a1)+tb*a1)/255;
					a2=a1+a2-(a1*a2)/255;

					dst=(a2<<24)|(r2<<16)|(g2<<8)|b2;
				}
		}

		DeleteObject(bmpText);
		SelectObject(hdcTemp,font0);
	}

	if (s_Skin.User_image_size && !s_bWin7Style)
	{
		// draw user image
		HBITMAP userPicture;
		bool bMask=(s_Skin.User_mask.bIsBitmap && s_Skin.User_mask.bIs32 && s_Skin.User_maskSize.cx==s_Skin.User_image_size && s_Skin.User_maskSize.cy==s_Skin.User_image_size);
		if (bMask)
			userPicture=LoadUserImage(s_Skin.User_image_size,s_Skin.User_mask.GetBitmap());
		else
			userPicture=LoadUserImage(s_Skin.User_image_size,NULL);
		if (userPicture)
		{
			// draw user picture
			SIZE frameSize;
			if (s_Skin.User_bitmap.GetBitmap())
			{
				BITMAP info;
				GetObject(s_Skin.User_bitmap.GetBitmap(),sizeof(info),&info);
				frameSize.cx=info.bmWidth;
				frameSize.cy=info.bmHeight;
			}
			else
			{
				frameSize.cx=s_Skin.User_image_size+s_Skin.User_image_offset.x*2;
				frameSize.cy=s_Skin.User_image_size+s_Skin.User_image_offset.y*2;
			}
			POINT pos=s_Skin.User_frame_position;
			if (pos.x==MenuSkin::USER_CENTER)
				pos.x=(totalWidth-frameSize.cx)/2;
			else if (pos.x==MenuSkin::USER_CENTER1)
				pos.x=(totalWidth1+textHeight-frameSize.cx)/2;
			else if (pos.x==MenuSkin::USER_CENTER2)
			{
				if (totalWidth2>0)
					pos.x=totalWidth1+(totalWidth2-frameSize.cx)/2;
				else
					pos.x=(totalWidth-frameSize.cx)/2;
			}

			if (pos.x<0) pos.x+=totalWidth-frameSize.cx;
			if (pos.y<0) pos.y+=totalHeight-frameSize.cy;

			if (s_bRTL)
				pos.x=totalWidth-frameSize.cx-pos.x;
			pos.x+=s_Skin.User_image_offset.x;
			pos.y+=s_Skin.User_image_offset.y;
			HGDIOBJ bmp02=SelectObject(hdcTemp,userPicture);
			unsigned int alpha=s_Skin.User_image_alpha;
			if (alpha==255 && !bMask)
			{
				BitBlt(hdc,pos.x,pos.y,s_Skin.User_image_size,s_Skin.User_image_size,hdcTemp,0,0,SRCCOPY);
			}
			else
			{
				BLENDFUNCTION func={AC_SRC_OVER,0U,bMask?255U:(BYTE)alpha,bMask?AC_SRC_ALPHA:0U};
				AlphaBlend(hdc,pos.x,pos.y,s_Skin.User_image_size,s_Skin.User_image_size,hdcTemp,0,0,s_Skin.User_image_size,s_Skin.User_image_size,func);
			}

			if (s_bRTL)
				m_rUser1.left=totalWidth-pos.x-s_Skin.User_image_size;
			else
				m_rUser1.left=pos.x;
			m_rUser1.right=m_rUser1.left+s_Skin.User_image_size;
			m_rUser1.top=pos.y;
			m_rUser1.bottom=pos.y+s_Skin.User_image_size;

			if (opacity!=MenuSkin::OPACITY_SOLID && !bMask)
			{
				// set to opaque
				SelectObject(hdc,bmp0); // deselect m_Bitmap so all the GDI operations get flushed
				unsigned int *bits2=bits+pos.y*totalWidth+pos.x;
				alpha<<=24;
				for (int y=0;y<s_Skin.User_image_size;y++,bits2+=totalWidth)
					for (int x=0;x<s_Skin.User_image_size;x++)
						bits2[x]=alpha|(bits2[x]&0xFFFFFF);
				SelectObject(hdc,m_Bitmap);
			}

			// draw frame
			pos.x-=s_Skin.User_image_offset.x;
			pos.y-=s_Skin.User_image_offset.y;
			if (s_Skin.User_bitmap.GetBitmap())
			{
				SelectObject(hdcTemp,s_Skin.User_bitmap.GetBitmap());
				BLENDFUNCTION func={AC_SRC_OVER,0,255,AC_SRC_ALPHA};
				AlphaBlend(hdc,pos.x,pos.y,frameSize.cx,frameSize.cy,hdcTemp,0,0,frameSize.cx,frameSize.cy,func);
			}
			else if (!s_Skin.User_mask.GetBitmap())
			{
				RECT rc={pos.x,pos.y,pos.x+frameSize.cx,pos.y+frameSize.cy};
				DrawEdge(hdc,&rc,EDGE_BUMP,BF_RECT);
			}
			SelectObject(hdcTemp,bmp02);
			DeleteObject(userPicture);
		}
	}

	if (s_Skin.User_name_position.left!=s_Skin.User_name_position.right)
	{
		RECT rc0;
		int x0=0, x1=totalWidth;
		if (s_Skin.User_name_align==MenuSkin::HALIGN_CENTER1 || s_Skin.User_name_align==MenuSkin::HALIGN_LEFT1 || s_Skin.User_name_align==MenuSkin::HALIGN_RIGHT1)
			x1=totalWidth1;
		else if (s_Skin.User_name_align==MenuSkin::HALIGN_CENTER2 || s_Skin.User_name_align==MenuSkin::HALIGN_LEFT2 || s_Skin.User_name_align==MenuSkin::HALIGN_RIGHT2)
			x0=totalWidth1;

		if (s_Skin.User_name_position.left<0)
			rc0.left=x1+s_Skin.User_name_position.left;
		else
			rc0.left=x0+s_Skin.User_name_position.left;

		if (s_Skin.User_name_position.right<0)
			rc0.right=x1+s_Skin.User_name_position.right;
		else
			rc0.right=x0+s_Skin.User_name_position.right;

		rc0.top=s_Skin.User_name_position.top;
		if (rc0.top<0) rc0.top+=totalHeight;
		rc0.bottom=s_Skin.User_name_position.bottom;
		if (rc0.bottom<0) rc0.bottom+=totalHeight;

		m_rUser2=rc0;

		wchar_t name[256];
		Strcpy(name,_countof(name),GetSettingString(L"MenuUsername"));
		DoEnvironmentSubst(name,_countof(name));

		if (Strlen(name)>0)
		{
			int nameWidth=rc0.right-rc0.left;
			int nameHeight=rc0.bottom-rc0.top;
			RECT rc={0,0,nameWidth,nameHeight};

			// draw the title
			BITMAPINFO dib={sizeof(dib)};
			dib.bmiHeader.biWidth=nameWidth;
			dib.bmiHeader.biHeight=-nameHeight;
			dib.bmiHeader.biPlanes=1;
			dib.bmiHeader.biBitCount=32;
			dib.bmiHeader.biCompression=BI_RGB;

			font0=(HFONT)SelectObject(hdcTemp,s_Skin.User_font);

			unsigned int *bits2;
			HBITMAP bmpText=CreateDIBSection(hdcTemp,&dib,DIB_RGB_COLORS,(void**)&bits2,NULL,0);
			HGDIOBJ bmp02=SelectObject(hdcTemp,bmpText);
			FillRect(hdcTemp,&rc,(HBRUSH)GetStockObject(BLACK_BRUSH));

			DWORD align=DT_CENTER;
			if (s_Skin.User_name_align==MenuSkin::HALIGN_LEFT || s_Skin.User_name_align==MenuSkin::HALIGN_LEFT1 || s_Skin.User_name_align==MenuSkin::HALIGN_LEFT2)
				align=s_bRTL?DT_RIGHT:DT_LEFT;
			else if (s_Skin.User_name_align==MenuSkin::HALIGN_RIGHT || s_Skin.User_name_align==MenuSkin::HALIGN_RIGHT1 || s_Skin.User_name_align==MenuSkin::HALIGN_RIGHT2)
				align=s_bRTL?DT_LEFT:DT_RIGHT;
			if (s_Theme && s_Skin.User_glow_size>0)
			{
				InflateRect(&rc,-s_Skin.User_glow_size,-s_Skin.User_glow_size);
				// draw the glow
				opts.dwFlags=DTT_COMPOSITED|DTT_TEXTCOLOR|DTT_GLOWSIZE;
				opts.crText=0xFFFFFF;
				opts.iGlowSize=s_Skin.User_glow_size;
				DrawThemeTextEx(s_Theme,hdcTemp,0,0,name,-1,align|DT_VCENTER|DT_NOPREFIX|DT_SINGLELINE|DT_END_ELLIPSIS|DT_NOCLIP,&rc,&opts);
				SelectObject(hdcTemp,bmp02); // deselect bmpText so all the GDI operations get flushed

				// change the glow color
				int gr=(s_Skin.User_glow_color)&255;
				int gg=(s_Skin.User_glow_color>>8)&255;
				int gb=(s_Skin.User_glow_color>>16)&255;
				for (int y=0;y<nameHeight;y++)
					for (int x=0;x<nameWidth;x++)
					{
						unsigned int &pixel=bits2[y*nameWidth+x];
						int a1=(pixel>>24);
						int r1=(pixel>>16)&255;
						int g1=(pixel>>8)&255;
						int b1=(pixel)&255;
						r1=(r1*gr)/255;
						g1=(g1*gg)/255;
						b1=(b1*gb)/255;
						pixel=(a1<<24)|(r1<<16)|(g1<<8)|b1;
					}

					SelectObject(hdcTemp,bmpText);
			}

			// draw the text
			int offset=rc0.top*totalWidth+rc0.left;
			if (s_bRTL)
				offset=rc0.top*totalWidth+totalWidth-rc0.right;

			if (s_Theme)
			{
				opts.dwFlags=DTT_COMPOSITED|DTT_TEXTCOLOR;
				opts.crText=s_Skin.User_text_color;
				DrawThemeTextEx(s_Theme,hdcTemp,0,0,name,-1,align|DT_VCENTER|DT_NOPREFIX|DT_SINGLELINE|DT_END_ELLIPSIS|DT_NOCLIP,&rc,&opts);
				SelectObject(hdcTemp,bmp02);

				// copy the text onto the final bitmap. Combine the alpha channels
				for (int y=0;y<nameHeight;y++)
					for (int x=0;x<nameWidth;x++)
					{
						unsigned int src=bits2[y*nameWidth+x];
						int a1=(src>>24);
						int r1=(src>>16)&255;
						int g1=(src>>8)&255;
						int b1=(src)&255;

						unsigned int &dst=bits[y*totalWidth+x+offset];

						int a2=(dst>>24);
						int r2=(dst>>16)&255;
						int g2=(dst>>8)&255;
						int b2=(dst)&255;

						r2=(r2*(255-a1))/255+r1;
						g2=(g2*(255-a1))/255+g1;
						b2=(b2*(255-a1))/255+b1;
						a2=a1+a2-(a1*a2)/255;

						dst=(a2<<24)|(r2<<16)|(g2<<8)|b2;
					}
			}
			else
			{
				// draw white text on black background
				SetTextColor(hdcTemp,0xFFFFFF);
				SetBkMode(hdcTemp,TRANSPARENT);
				DrawText(hdcTemp,name,-1,&rc,align|DT_VCENTER|DT_NOPREFIX|DT_SINGLELINE|DT_END_ELLIPSIS|DT_NOCLIP);
				SelectObject(hdcTemp,bmp02);

				// copy the text onto the final bitmap
				// change the text color
				int tr=(s_Skin.User_text_color>>16)&255;
				int tg=(s_Skin.User_text_color>>8)&255;
				int tb=(s_Skin.User_text_color)&255;
				for (int y=0;y<nameHeight;y++)
					for (int x=0;x<nameWidth;x++)
					{
						unsigned int src=bits2[y*nameWidth+x];
						int a1=(src)&255;

						unsigned int &dst=bits[y*totalWidth+x+offset];

						int a2=(dst>>24);
						int r2=(dst>>16)&255;
						int g2=(dst>>8)&255;
						int b2=(dst)&255;

						r2=(r2*(255-a1)+tr*a1)/255;
						g2=(g2*(255-a1)+tg*a1)/255;
						b2=(b2*(255-a1)+tb*a1)/255;
						a2=a1+a2-(a1*a2)/255;

						dst=(a2<<24)|(r2<<16)|(g2<<8)|b2;
					}
			}

			DeleteObject(bmpText);
			SelectObject(hdcTemp,font0);
		}
	}

	DeleteDC(hdcTemp);

	SelectObject(hdc,bmp0);
	DeleteDC(hdc);

	// calculate the window region
	if (bCreateRegion)
	{
		if (m_Region) DeleteObject(m_Region);
		m_Region=NULL;
		if (A4SMenuProfile::IsEnabled())
		{
			// DWM owns the 8-DIP rounded clip in the environment build.
		}
		else if (opacity==MenuSkin::OPACITY_REGION || opacity==MenuSkin::OPACITY_GLASS || opacity==MenuSkin::OPACITY_FULLGLASS)
		{
			for (int y=0;y<totalHeight;y++)
			{
				int minx=-1, maxx=-1;
				int yw=y*totalWidth;
				for (int x=0;x<totalWidth;x++)
				{
					if (bits[yw+x]&0xFF000000)
					{
						if (minx==-1) minx=x; // first non-transparent pixel
						if (maxx<x) maxx=x; // last non-transparent pixel
					}
				}
				if (minx>=0)
				{
					maxx++;
					HRGN r=CreateRectRgn(minx,y,maxx,y+1);
					AddTrackedObject(r);
					if (!m_Region)
						m_Region=r;
					else
					{
						CombineRgn(m_Region,m_Region,r,RGN_OR);
						DeleteObject(r);
					}
				}
			}
		}
		else if (opacity==MenuSkin::OPACITY_ALPHA || opacity==MenuSkin::OPACITY_FULLALPHA)
			m_Region=CreateRectRgn(0,0,totalWidth,totalHeight);
	}
}

void CMenuContainer::CreateContentRects( int width1, int width2, int height1, int height2, int &totalWidth, int &totalHeight )
{
	const int *slicesY;
	RECT menuPadding[2];
	if (s_MenuMode==MODE_SEARCH)
	{
		slicesY=s_Skin.Main_bitmap_search_slices_Y;
		menuPadding[0]=s_Skin.Main_search_padding;
		memset(&menuPadding[1],0,sizeof(menuPadding[1]));
	}
	else if (s_MenuMode==MODE_JUMPLIST)
	{
		slicesY=s_Skin.Main_bitmap_jump_slices_Y;
		menuPadding[0]=s_Skin.Main_padding;
		menuPadding[1]=s_Skin.Main_jump_padding;
	}
	else
	{
		slicesY=s_Skin.Main_bitmap_slices_Y;
		menuPadding[0]=s_Skin.Main_padding;
		menuPadding[1]=s_Skin.Main2_padding;
	}

	int totalWidth1=width1+menuPadding[0].left+menuPadding[0].right;
	int totalWidth2=width2+menuPadding[1].left+menuPadding[1].right;
	totalWidth=totalWidth1+totalWidth2;

	totalHeight=height1+menuPadding[0].top+menuPadding[0].bottom;
	int totalHeight2=height2+menuPadding[1].top+menuPadding[1].bottom;
	if (totalHeight<totalHeight2) totalHeight=totalHeight2;
	if (totalHeight<slicesY[0]+slicesY[2]) totalHeight=slicesY[0]+slicesY[2];

	m_rContent.left=menuPadding[0].left;
	m_rContent.right=totalWidth1-menuPadding[0].right;
	m_rContent.top=menuPadding[0].top;
	m_rContent.bottom=m_rContent.top+height1;
	if (totalWidth2>0)
	{
		m_rContent2.left=m_rContent.right+menuPadding[0].right+menuPadding[1].left;
		m_rContent2.right=totalWidth-menuPadding[1].right;
		m_rContent2.top=menuPadding[1].top;
		m_rContent2.bottom=m_rContent2.top+height2;
	}
}

void CMenuContainer::CreateSubmenuRegion( int width, int height )
{
	int totalWidth=s_Skin.Submenu_padding.left+s_Skin.Submenu_padding.right+width;
	int totalHeight=s_Skin.Submenu_padding.top+s_Skin.Submenu_padding.bottom+height;
	if (m_Region) DeleteObject(m_Region);
	m_Region=NULL;
	if (A4SMenuProfile::IsEnabled())
		return;
	if (s_Skin.Submenu_opacity==MenuSkin::OPACITY_SOLID)
		return;
	if (!s_Skin.Submenu_bitmap.GetBitmap() || !s_Skin.Submenu_bitmap.bIs32)
		return;
	if (s_Skin.Submenu_opacity==MenuSkin::OPACITY_ALPHA || s_Skin.Submenu_opacity==MenuSkin::OPACITY_FULLALPHA)
	{
		m_Region=CreateRectRgn(0,0,totalWidth,totalHeight-m_ExtraTop-m_ExtraBottom);
		return;
	}
	BITMAP info;
	GetObject(s_Skin.Submenu_bitmap.GetBitmap(),sizeof(info),&info);
	const int *slicesX=s_Skin.Submenu_bitmap_slices_X+3;
	const int *slicesY=s_Skin.Submenu_bitmap_slices_Y;
	int slicesX0=slicesX[s_bRTL?2:0];
	int slicesX2=slicesX[s_bRTL?0:2];
	int bmpWidth=slicesX0+slicesX[1]+slicesX2;
	int bmpHeight=slicesY[0]+slicesY[1]+slicesY[2];
	unsigned int *bits=(unsigned int*)info.bmBits;
	{
		for (int y=m_ExtraTop;y<totalHeight-m_ExtraBottom;y++)
		{
			int yy;
			if (y<=slicesY[0])
				yy=y;
			else if (y>=totalHeight-slicesY[2])
				yy=bmpHeight-totalHeight+y;
			else
				yy=slicesY[0]+((y-slicesY[0])*slicesY[1])/(totalHeight-slicesY[0]-slicesY[2]);
			if (info.bmHeight>0)
				yy=info.bmHeight-yy-1;
			int yw=yy*info.bmWidth;
			int minx=-1, maxx=-1;
			for (int x=0;x<bmpWidth;x++)
			{
				if (bits[yw+x]&0xFF000000)
				{
					if (minx==-1) minx=x; // first non-transparent pixel
					if (maxx<x) maxx=x; // last non-transparent pixel
				}
			}

			if (minx>=0)
			{
				if (minx>=bmpWidth-slicesX2)
					minx+=totalWidth-bmpWidth;
				else if (minx>slicesX0)
					minx=slicesX0+((minx-slicesX0)*(totalWidth-slicesX0-slicesX2))/slicesX[1];

				if (maxx>=bmpWidth-slicesX2)
					maxx+=totalWidth-bmpWidth;
				else if (minx>slicesX0)
					maxx=slicesX0+((maxx-slicesX0)*(totalWidth-slicesX0-slicesX2))/slicesX[1];

				maxx++;
				HRGN r=CreateRectRgn(minx,y-m_ExtraTop,maxx,y-m_ExtraTop+1);
				AddTrackedObject(r);
				if (!m_Region)
					m_Region=r;
				else
				{
					CombineRgn(m_Region,m_Region,r,RGN_OR);
					DeleteObject(r);
				}
			}
		}
	}
}

void CMenuContainer::DrawA4SSearchEdit( HDC hdc )
{
	if (!m_SearchBox.m_hWnd || m_SearchIndex<0)
		return;

	RECT itemRect;
	if (!GetItemRect(m_SearchIndex,itemRect))
		return;

	CString text;
	m_SearchBox.GetWindowText(text);
	const bool hint=text.IsEmpty() &&
		(((GetSettingInt(L"SearchBox")==SEARCHBOX_NORMAL) && GetSettingBool(L"SearchSelect")) || GetFocus()!=m_SearchBox.m_hWnd);
	if (hint)
	{
		if (GetSettingBool(L"SearchHint"))
			text=GetSettingString(L"SearchHintText");
		else
			text=m_Items[m_SearchIndex].name;
	}

	// The exact captured text cell is 17 DIP high at y=408 and remains inside
	// the native edit's live client rectangle for mouse/input hit testing.
	RECT childRect;
	::GetClientRect(m_SearchBox.m_hWnd,&childRect);
	::MapWindowPoints(m_SearchBox.m_hWnd,m_hWnd,(POINT*)&childRect,2);
	RECT clipRect={itemRect.left+A4SMenuProfile::Scale(27,s_Skin.Dpi),
		itemRect.top+A4SMenuProfile::Scale(4,s_Skin.Dpi),
		itemRect.right-A4SMenuProfile::Scale(1,s_Skin.Dpi),
		itemRect.top+A4SMenuProfile::Scale(21,s_Skin.Dpi)};
	if (!IntersectRect(&clipRect,&clipRect,&childRect))
		return;

	HGDIOBJ oldFont=SelectObject(hdc,s_Skin.Search_hint_font);
	TEXTMETRIC metrics={0};
	GetTextMetrics(hdc,&metrics);
	const int cellTop=itemRect.top+A4SMenuProfile::Scale(4,s_Skin.Dpi);
	const int cellBottom=(std::min)(clipRect.bottom,cellTop+metrics.tmHeight);

	int textX=itemRect.left+A4SMenuProfile::Scale(hint?38:31,s_Skin.Dpi);
	if (!hint && !text.IsEmpty())
	{
		// For a single-line EDIT this is the first visible character. Recover the
		// full-string origin from its native, scroll-aware position so long queries
		// keep the same caret and horizontal-scroll behavior as the input model.
		int first=(int)m_SearchBox.SendMessage(EM_GETFIRSTVISIBLELINE);
		if (first<0) first=0;
		if (first>text.GetLength()) first=text.GetLength();
		LRESULT pos=m_SearchBox.SendMessage(EM_POSFROMCHAR,first);
		if (pos!=-1)
		{
			SIZE prefix={0,0};
			if (first>0)
				GetTextExtentPoint32(hdc,text,first,&prefix);
			textX=childRect.left+(short)LOWORD(pos)-prefix.cx;
		}
	}

	SIZE textSize={0,0};
	if (!text.IsEmpty())
		GetTextExtentPoint32(hdc,text,text.GetLength(),&textSize);
	RECT textRect={textX,cellTop,textX+(std::max)(textSize.cx,clipRect.right-clipRect.left)+A4SMenuProfile::Scale(2,s_Skin.Dpi),cellBottom};

	DWORD selectionStart=0, selectionEnd=0;
	if (!hint)
		m_SearchBox.SendMessage(EM_GETSEL,(WPARAM)&selectionStart,(LPARAM)&selectionEnd);
	selectionStart=(std::min)(selectionStart,(DWORD)text.GetLength());
	selectionEnd=(std::min)(selectionEnd,(DWORD)text.GetLength());
	if (selectionEnd<selectionStart)
		std::swap(selectionStart,selectionEnd);

	auto CharacterX=[&](DWORD index)->int
	{
		SIZE prefix={0,0};
		if (index>0)
			GetTextExtentPoint32(hdc,text,(int)index,&prefix);
		return textX+prefix.cx;
	};

	RECT selectionRect={0,0,0,0};
	const bool hasFocus=GetFocus()==m_SearchBox.m_hWnd;
	const bool hasSelection=hasFocus && !hint && selectionStart!=selectionEnd;
	if (hasSelection)
	{
		selectionRect.left=CharacterX(selectionStart);
		selectionRect.right=CharacterX(selectionEnd);
		selectionRect.top=cellTop;
		selectionRect.bottom=cellBottom;
		RECT visibleSelection;
		if (IntersectRect(&visibleSelection,&selectionRect,&clipRect))
			FillA4SOpaqueRect(hdc,visibleSelection,GetSysColor(COLOR_HIGHLIGHT));
	}

	int saved=SaveDC(hdc);
	IntersectClipRect(hdc,clipRect.left,clipRect.top,clipRect.right,clipRect.bottom);
	if (!text.IsEmpty())
	{
		const DWORD flags=DT_SINGLELINE|DT_NOPREFIX|DT_NOCLIP;
		if (s_Theme)
		{
			DTTOPTS options={sizeof(options),DTT_TEXTCOLOR|DTT_COMPOSITED};
			options.crText=hint?s_Skin.Search_text_colors[1]:s_Skin.Search_text_colors[0];
			COLORREF selectedText=GetSysColor(COLOR_HIGHLIGHTTEXT);
			if (hasSelection && selectedText!=options.crText)
			{
				int normal=SaveDC(hdc);
				ExcludeClipRect(hdc,selectionRect.left,selectionRect.top,selectionRect.right,selectionRect.bottom);
				DrawThemeTextEx(s_Theme,hdc,0,0,text,text.GetLength(),flags,&textRect,&options);
				RestoreDC(hdc,normal);
				int selected=SaveDC(hdc);
				IntersectClipRect(hdc,selectionRect.left,selectionRect.top,selectionRect.right,selectionRect.bottom);
				options.crText=selectedText;
				DrawThemeTextEx(s_Theme,hdc,0,0,text,text.GetLength(),flags,&textRect,&options);
				RestoreDC(hdc,selected);
			}
			else
				DrawThemeTextEx(s_Theme,hdc,0,0,text,text.GetLength(),flags,&textRect,&options);
		}
		else
		{
			SetBkMode(hdc,TRANSPARENT);
			COLORREF normalText=hint?s_Skin.Search_text_colors[1]:s_Skin.Search_text_colors[0];
			COLORREF selectedText=GetSysColor(COLOR_HIGHLIGHTTEXT);
			if (hasSelection && selectedText!=normalText)
			{
				int normal=SaveDC(hdc);
				ExcludeClipRect(hdc,selectionRect.left,selectionRect.top,selectionRect.right,selectionRect.bottom);
				SetTextColor(hdc,normalText);
				DrawText(hdc,text,text.GetLength(),&textRect,flags);
				RestoreDC(hdc,normal);
				int selected=SaveDC(hdc);
				IntersectClipRect(hdc,selectionRect.left,selectionRect.top,selectionRect.right,selectionRect.bottom);
				SetTextColor(hdc,selectedText);
				DrawText(hdc,text,text.GetLength(),&textRect,flags);
				RestoreDC(hdc,selected);
			}
			else
			{
				SetTextColor(hdc,normalText);
				DrawText(hdc,text,text.GetLength(),&textRect,flags);
			}
		}
	}

	if (hasFocus && !hasSelection && m_bA4SSearchCaretVisible)
	{
		POINT caret={!hint && !text.IsEmpty()?CharacterX(selectionEnd):itemRect.left+A4SMenuProfile::Scale(31,s_Skin.Dpi),cellTop};
		POINT nativeCaret;
		if (::GetCaretPos(&nativeCaret))
		{
			::MapWindowPoints(m_SearchBox.m_hWnd,m_hWnd,&nativeCaret,1);
			caret.x=nativeCaret.x;
		}
		RECT caretRect={caret.x,cellTop,caret.x+1,cellBottom};
		RECT visibleCaret;
		if (IntersectRect(&visibleCaret,&caretRect,&clipRect))
			FillA4SOpaqueRect(hdc,visibleCaret,RGB(230,230,230));
	}
	RestoreDC(hdc,saved);
	SelectObject(hdc,oldFont);
}

void CMenuContainer::DrawBackground( HDC hdc, const RECT &drawRect )
{
	HDC hdc2=CreateCompatibleDC(hdc);

	// draw the background (bitmap or solid color)
	HBITMAP bmpMain=NULL;
	RECT rMarginsMain, rSrcMain;
	bool bAlphaMain;
	if (m_Bitmap)
	{
		HGDIOBJ bmp0=SelectObject(hdc2,m_Bitmap);
		BitBlt(hdc,m_BitmapOffset,0,m_rMenu.right,m_rMenu.bottom,hdc2,0,0,SRCCOPY);
		SelectObject(hdc2,bmp0);
		bmpMain=m_Bitmap;
		{ RECT rc={m_rMenu.right-m_rMenu.left,m_rMenu.bottom,0,0}; rMarginsMain=rc; }
		{ RECT rc={0,0,m_rMenu.right-m_rMenu.left,m_rMenu.bottom}; rSrcMain=rc; }
		bAlphaMain=false;
	}
	else if (m_bSubMenu && s_Skin.Submenu_bitmap.GetBitmap())
	{
		bAlphaMain=(s_Skin.Submenu_opacity==MenuSkin::OPACITY_SOLID && s_Skin.Submenu_bitmap.bIs32);
		if (bAlphaMain)
		{
			SetDCBrushColor(hdc,s_Skin.Submenu_background);
			FillRect(hdc,&drawRect,(HBRUSH)GetStockObject(DC_BRUSH));
		}
		HGDIOBJ bmp0=SelectObject(hdc2,s_Skin.Submenu_bitmap.GetBitmap());
		const int *slicesX=s_Skin.Submenu_bitmap_slices_X;
		const int *slicesY=s_Skin.Submenu_bitmap_slices_Y;
		RECT rSrc={0,0,slicesX[3]+slicesX[4]+slicesX[5],slicesY[0]+slicesY[1]+slicesY[2]};
		RECT rMargins={slicesX[3],slicesY[0],slicesX[5],slicesY[2]};
		RECT rDst=m_rMenu;
		rDst.top-=m_ExtraTop;
		rDst.bottom+=m_ExtraBottom;
		MarginsBlit(hdc2,hdc,rSrc,rDst,rMargins,bAlphaMain);
		SelectObject(hdc2,bmp0);
		bmpMain=s_Skin.Submenu_bitmap.GetBitmap();
		rMarginsMain=rMargins;
		rSrcMain=rSrc;
	}
	else if (!A4SMenuProfile::IsEnabled())
	{
		SetDCBrushColor(hdc,m_bSubMenu?s_Skin.Submenu_background:s_Skin.Main_background);
		FillRect(hdc,&m_rMenu,(HBRUSH)GetStockObject(DC_BRUSH));
	}
	// A4S submenus have no backing bitmap by design. Their cleared alpha buffer
	// is the surface consumed by the same WCA acrylic policy as the main popup.

	MenuBitmap bmpSeparatorV;
	int sepWidth=0;
	const int *sepSlicesY=NULL;
	MenuBitmap bmpPager;
	const int *pagSlicesX=NULL;
	const int *pagSlicesY=NULL;
	MenuBitmap bmpPagerArrows;
	SIZE pagArrowSize;
	MenuSkin::TOpacity opacity=m_bSubMenu?s_Skin.Submenu_opacity:s_Skin.Main_opacity;
	int glow=s_Skin.ItemSettings[m_bSubMenu?MenuSkin::SUBMENU_ITEM:MenuSkin::COLUMN1_ITEM].glowSize;
	if (!s_Theme) glow=0;
	TRecentKeys recentType=(TRecentKeys)GetSettingInt(L"RecentProgKeys");

	if (m_bSubMenu)
	{
		bmpSeparatorV=s_Skin.Submenu_separatorV;
		sepWidth=s_Skin.Submenu_separatorWidth;
		sepSlicesY=s_Skin.Submenu_separator_slices_Y;

		bmpPager=s_Skin.Submenu_pager;
		pagSlicesX=s_Skin.Submenu_pager_slices_X;
		pagSlicesY=s_Skin.Submenu_pager_slices_Y;
		bmpPagerArrows=s_Skin.Submenu_pager_arrows;
		pagArrowSize=s_Skin.Submenu_pager_arrow_Size;
	}
	else
	{
		bmpSeparatorV=s_Skin.Main_separatorV;
		sepWidth=s_Skin.Main_separatorWidth;
		sepSlicesY=s_Skin.Main_separator_slices_Y;

		bmpPager=s_Skin.Main_pager;
		pagSlicesX=s_Skin.Main_pager_slices_X;
		pagSlicesY=s_Skin.Main_pager_slices_Y;
		bmpPagerArrows=s_Skin.Main_pager_arrows;
		pagArrowSize=s_Skin.Main_pager_arrow_Size;
	}

	HGDIOBJ font0=GetCurrentObject(hdc,OBJ_FONT);
	SetBkMode(hdc,TRANSPARENT);
	if (A4SMenuProfile::IsEnabled() && !m_bSubMenu)
	{
		RECT divider={0,A4SMenuProfile::Scale(391,s_Skin.Dpi),A4SMenuProfile::MenuWidth(s_Skin.Dpi),A4SMenuProfile::Scale(392,s_Skin.Dpi)};
		FillA4SOpaqueRect(hdc,divider,RGB(56,56,56));
		if (s_MenuMode==MODE_NORMAL || s_MenuMode==MODE_PROGRAMS)
		{
			RECT programsDivider={A4SMenuProfile::Scale(15,s_Skin.Dpi),A4SMenuProfile::Scale(361,s_Skin.Dpi),
				A4SMenuProfile::Scale(268,s_Skin.Dpi),A4SMenuProfile::Scale(362,s_Skin.Dpi)};
			FillA4SOpaqueRect(hdc,programsDivider,RGB(56,56,56));
		}
	}

	// set clip rectangle for the scrollable items
	int clipTop=m_rContent.top;
	int clipBottom=m_rContent.bottom;
	if (m_bScrollUp)
		clipTop=m_rContent.top+m_ScrollButtonSize;
	if (m_bScrollDown)
		clipBottom=m_rContent.top+m_ScrollHeight-m_ScrollButtonSize;
	if (m_ScrollHeight>0)
		IntersectClipRect(hdc,0,clipTop,m_rMenu.right,clipBottom);

	// draw items
	for (int index=0;;index++)
	{
		if (!m_bSubMenu)
		{
			if (index==m_ProgramTreeIndex) continue;
			if (s_MenuMode==MODE_PROGRAMS)
			{
				if (index<m_ScrollCount) continue;
			}
		}
		if (m_ScrollHeight>0 && index==m_ScrollCount)
		{
			// clean up after the scrollable items
			SelectClipRgn(hdc,NULL);
			if (m_bScrollUp)
			{
				if (glow || opacity==MenuSkin::OPACITY_FULLALPHA || opacity==MenuSkin::OPACITY_FULLGLASS)
				{
					// fix background behind the up button (DrawThemeTextEx may spill onto the tablecloth)
					RECT rc={m_rContent.left,0,m_rContent.right,clipTop};
					if (bAlphaMain || !bmpMain)
					{
						SetDCBrushColor(hdc,m_bSubMenu?s_Skin.Submenu_background:s_Skin.Main_background);
						FillRect(hdc,&rc,(HBRUSH)GetStockObject(DC_BRUSH));
					}
					if (bmpMain)
					{
						HGDIOBJ bmp0=SelectObject(hdc2,bmpMain);
						IntersectClipRect(hdc,m_rContent.left,0,m_rContent.right,clipTop);
						MarginsBlit(hdc2,hdc,rSrcMain,m_rMenu,rMarginsMain,bAlphaMain);
						SelectObject(hdc2,bmp0);
						SelectClipRgn(hdc,NULL);
					}
				}

				// draw up button
				RECT rc=m_rContent;
				rc.bottom=clipTop;
				if (bmpPager.GetBitmap() && bmpPagerArrows.GetBitmap())
				{
					// background
					HGDIOBJ bmp0=SelectObject(hdc2,bmpPager.GetBitmap());
					RECT rSrc={0,0,pagSlicesX[0]+pagSlicesX[1]+pagSlicesX[2],pagSlicesY[0]+pagSlicesY[1]+pagSlicesY[2]};
					if (m_bScrollUpHot)
						OffsetRect(&rSrc,0,rSrc.bottom);
					RECT rMargins={pagSlicesX[0],pagSlicesY[0],pagSlicesX[2],pagSlicesY[2]};
					MarginsBlit(hdc2,hdc,rSrc,rc,rMargins,bmpPager.bIs32);

					// arrow
					SelectObject(hdc2,bmpPagerArrows.GetBitmap());
					int x=(rc.left+rc.right-pagArrowSize.cx)/2;
					int y=(rc.top+rc.bottom-pagArrowSize.cy)/2;
					if (bmpPagerArrows.bIs32)
					{
						BLENDFUNCTION func={AC_SRC_OVER,0,255,AC_SRC_ALPHA};
						AlphaBlend(hdc,x,y,pagArrowSize.cx,pagArrowSize.cy,hdc2,m_bScrollUpHot?pagArrowSize.cx:0,0,pagArrowSize.cx,pagArrowSize.cy,func);
					}
					else
						BitBlt(hdc,x,y,pagArrowSize.cx,pagArrowSize.cy,hdc2,m_bScrollUpHot?pagArrowSize.cx:0,0,SRCCOPY);
					SelectObject(hdc2,bmp0);
				}
				else
				{
					if (s_PagerTheme)
						DrawThemeBackground(s_PagerTheme,hdc,SBP_ARROWBTN,(m_bScrollUpHot?ABS_UPHOT:ABS_UPHOVER),&rc,NULL);
					else
						DrawFrameControl(hdc,&rc,DFC_SCROLL,DFCS_SCROLLUP|DFCS_FLAT|(m_bScrollUpHot?DFCS_PUSHED:0));
				}
			}
			if (m_bScrollDown)
			{
				int bottom=clipBottom+s_Skin.ItemSettings[m_bSubMenu?MenuSkin::SUBMENU_ITEM:MenuSkin::COLUMN1_ITEM].itemHeight;
				if (bottom>=m_rMenu.bottom) bottom=m_rMenu.bottom;
				if (bottom>clipBottom && (glow || opacity==MenuSkin::OPACITY_FULLALPHA || opacity==MenuSkin::OPACITY_FULLGLASS))
				{
					// fix background behind the up button (DrawThemeTextEx may spill onto the tablecloth)
					RECT rc={m_rContent.left,clipBottom,m_rContent.right,bottom};
					if (bAlphaMain || !bmpMain)
					{
						SetDCBrushColor(hdc,m_bSubMenu?s_Skin.Submenu_background:s_Skin.Main_background);
						FillRect(hdc,&rc,(HBRUSH)GetStockObject(DC_BRUSH));
					}
					if (bmpMain)
					{
						HGDIOBJ bmp0=SelectObject(hdc2,bmpMain);
						IntersectClipRect(hdc,m_rContent.left,clipBottom,m_rContent.right,bottom);
						MarginsBlit(hdc2,hdc,rSrcMain,m_rMenu,rMarginsMain,bAlphaMain);
						SelectObject(hdc2,bmp0);
						SelectClipRgn(hdc,NULL);
					}
				}

				// draw down button
				RECT rc=m_rContent;
				rc.bottom=m_rContent.top+m_ScrollHeight;
				rc.top=clipBottom;
				if (bmpPager.GetBitmap() && bmpPagerArrows.GetBitmap())
				{
					// background
					HGDIOBJ bmp0=SelectObject(hdc2,bmpPager.GetBitmap());
					RECT rSrc={0,0,pagSlicesX[0]+pagSlicesX[1]+pagSlicesX[2],pagSlicesY[0]+pagSlicesY[1]+pagSlicesY[2]};
					if (m_bScrollDownHot)
						OffsetRect(&rSrc,0,rSrc.bottom);
					RECT rMargins={pagSlicesX[0],pagSlicesY[0],pagSlicesX[2],pagSlicesY[2]};
					MarginsBlit(hdc2,hdc,rSrc,rc,rMargins,bmpPager.bIs32);

					// arrow
					SelectObject(hdc2,bmpPagerArrows.GetBitmap());
					int x=(rc.left+rc.right-pagArrowSize.cx)/2;
					int y=(rc.top+rc.bottom-pagArrowSize.cy)/2;
					if (bmpPagerArrows.bIs32)
					{
						BLENDFUNCTION func={AC_SRC_OVER,0,255,AC_SRC_ALPHA};
						AlphaBlend(hdc,x,y,pagArrowSize.cx,pagArrowSize.cy,hdc2,m_bScrollDownHot?pagArrowSize.cx:0,pagArrowSize.cy,pagArrowSize.cx,pagArrowSize.cy,func);
					}
					else
						BitBlt(hdc,x,y,pagArrowSize.cx,pagArrowSize.cy,hdc2,m_bScrollDownHot?pagArrowSize.cx:0,pagArrowSize.cy,SRCCOPY);
					SelectObject(hdc2,bmp0);
				}
				else
				{
					if (s_PagerTheme)
						DrawThemeBackground(s_PagerTheme,hdc,SBP_ARROWBTN,(m_bScrollDownHot?ABS_DOWNHOT:ABS_DOWNHOVER),&rc,NULL);
					else
						DrawFrameControl(hdc,&rc,DFC_SCROLL,DFCS_SCROLLDOWN|DFCS_FLAT|(m_bScrollDownHot?DFCS_PUSHED:0));
				}
			}
		}

		if (index>=(int)m_Items.size()) break;
		const MenuItem &item=m_Items[index];

		RECT itemRect=item.itemRect;
		// ignore offscreen items
		if (m_ScrollHeight>0 && index<m_ScrollCount)
		{
			OffsetRect(&itemRect,0,-m_ScrollOffset);
			if (itemRect.bottom<=clipTop) continue;
			if (itemRect.top>=clipBottom) continue;
		}
		else if (m_SearchScrollCount>m_SearchScrollHeight && index>=m_OriginalCount)
		{
			if (index-m_OriginalCount<m_SearchScrollPos || index-m_OriginalCount>=m_SearchScrollPos+m_SearchScrollHeight)
				continue;
			OffsetRect(&itemRect,0,-m_SearchScrollPos*(itemRect.bottom-itemRect.top));
		}
		{
			RECT q;
			if (!IntersectRect(&q,&drawRect,&itemRect))
				continue;
		}

		bool bHot=(index==m_HotItem || index==m_SubJumpItem || (m_HotItem==-1 && (index==m_Submenu || index==m_ContextItem)));
		const bool bA4SContextFlyout=IsA4SContextFlyout();
		const bool bA4SContextItemEnabled=IsA4SContextItemEnabled(item);
		if (!bA4SContextItemEnabled)
			bHot=false;
		bool bSplit=false;
		int stateLeft=0, stateRight=0;
		bool bNew=!bHot && item.bNew && !(s_bWin7Style && item.id==MENU_PROGRAMS && s_MenuMode==MODE_PROGRAMS);
		MenuSkin::TItemDrawType drawType=item.drawType;
		if (!bNew)
		{
			if (drawType==MenuSkin::COLUMN1_NEW)
				drawType=MenuSkin::COLUMN1_ITEM;
			else if (drawType==MenuSkin::COLUMN2_NEW)
				drawType=MenuSkin::COLUMN2_ITEM;
			else if (drawType==MenuSkin::PROGRAMS_BUTTON_NEW)
				drawType=MenuSkin::PROGRAMS_BUTTON;
			else if (drawType==MenuSkin::PROGRAMS_CASCADING_NEW)
				drawType=MenuSkin::PROGRAMS_CASCADING;
			else if (drawType==MenuSkin::SUBMENU_NEW)
				drawType=MenuSkin::SUBMENU_ITEM;

			if (!bHot && index==m_DropTargetIndex)
			{
				if (drawType==MenuSkin::COLUMN1_SPLIT)
					drawType=MenuSkin::COLUMN1_ITEM;
				if (drawType==MenuSkin::COLUMN2_SPLIT)
					drawType=MenuSkin::COLUMN2_ITEM;
			}
		}

		if (item.id==MENU_SEARCH_BOX)
		{
			RECT glyphRect;
			GetSearchGlyphRect(itemRect,glyphRect);
			itemRect=glyphRect;
			bHot=(index==m_HotItem && m_SearchState>=SEARCH_TEXT);
		}
		if (item.id==MENU_PROGRAMS_TREE)
			bHot=false;
		// An open power flyout keeps m_Submenu pointed at the root Shut down
		// item. For the A4S profile that ownership must not latch its visual hot
		// state after the pointer has left the footer control.
		if (A4SMenuProfile::IsEnabled() && item.id==MENU_SHUTDOWN_BUTTON)
			bHot=index==m_HotItem;
		int splitX=itemRect.right;
		const MenuSkin::ItemDrawSettings &settings=s_Skin.ItemSettings[drawType];
		int glowSize=s_Theme?settings.glowSize:0;

		if (bHot || bNew || item.id==MENU_SHUTDOWN_BUTTON || index==m_DropTargetIndex)
		{
			if (bHot || item.id==MENU_SHUTDOWN_BUTTON)
			{
				bSplit=(item.bSplit && (item.bFolder || item.jumpIndex>=0 || item.id==MENU_SEARCH_CATEGORY || item.id==MENU_SHUTDOWN_BUTTON));
				if (item.id==MENU_SHUTDOWN_BUTTON)
				{
					if (A4SMenuProfile::IsEnabled())
					{
						// Keep the two click targets, but derive the connected visual
						// state only from the pointer/capture—not from the open flyout.
						if (index==m_HotItem)
						{
							if (GetCapture()==m_hWnd && index==m_ClickIndex)
							{
								if (m_bClickArrow && m_bHotArrow)
									stateRight=2;
								else if (!m_bClickArrow && !m_bHotArrow)
									stateLeft=2;
								else
									stateLeft=stateRight=1;
							}
							else
								stateLeft=stateRight=1;
						}
					}
					else
					{
						if (GetCapture()==m_hWnd)
						{
							if (index==m_ClickIndex && !m_bClickArrow && index==m_HotItem && !m_bHotArrow)
								stateLeft=2;
							else if (index==m_ClickIndex || index==m_Submenu || index==m_SubJumpItem)
								stateLeft=1;
						}
						else if (index==m_HotItem || index==m_Submenu || index==m_SubJumpItem)
							stateLeft=1;

						if (index==m_Submenu || index==m_SubJumpItem)
							stateRight=2;
						else if (GetCapture()==m_hWnd)
						{
							if (index==m_ClickIndex && m_bClickArrow && index==m_HotItem && m_bHotArrow)
								stateRight=2;
						}
						else if (index==m_HotItem)
							stateRight=1;
					}
				}
				else
				{
					if ((index==m_HotItem && !m_bHotArrow) || index==m_ContextItem)
						stateLeft=1;
					if ((index==m_HotItem && m_bHotArrow) || index==m_Submenu || index==m_SubJumpItem || index==m_ContextItem)
						stateRight=1;
				}
				splitX=itemRect.right-settings.arrPadding.cx-settings.arrPadding.cy-1;
				if (item.jumpIndex>=0)
					splitX-=s_Skin.Pin_bitmap_Size.cx;
				else if (item.id==MENU_SEARCH_CATEGORY)
					splitX-=s_Skin.More_bitmap_Size.cx;
				else
					splitX-=settings.arrSize.cx;
			}
			// draw selection background
			if (bSplit && settings.bmpSelection.GetBitmap())
			{
				int srcHeight=settings.selSlicesY[0]+settings.selSlicesY[1]+settings.selSlicesY[2];
				HGDIOBJ bmp0=SelectObject(hdc2,settings.bmpSelection.GetBitmap());
				{
					// draw left half
					RECT rSrc={0,0,settings.selSlicesX[0]+settings.selSlicesX[1]+settings.selSlicesX[2],srcHeight};
					OffsetRect(&rSrc,0,srcHeight*stateLeft);
					RECT rMargins={settings.selSlicesX[0],settings.selSlicesY[0],settings.selSlicesX[2],settings.selSlicesY[2]};
					RECT itemRect2=itemRect;
					itemRect2.right=splitX;
					int w=itemRect2.right-itemRect2.left;
					int h=itemRect2.bottom-itemRect2.top;
					if (rMargins.left>w) rMargins.left=w;
					if (rMargins.right>w) rMargins.right=w;
					if (rMargins.top>h) rMargins.top=h;
					if (rMargins.bottom>h) rMargins.bottom=h;
					MarginsBlit(hdc2,hdc,rSrc,itemRect2,rMargins,settings.bmpSelection.bIs32);
				}
				{
					// draw right half
					RECT rSrc={settings.selSlicesX[0]+settings.selSlicesX[1]+settings.selSlicesX[2],0,0,srcHeight};
					OffsetRect(&rSrc,0,srcHeight*stateRight);
					rSrc.right=rSrc.left+settings.selSlicesX[3]+settings.selSlicesX[4]+settings.selSlicesX[5];
					RECT rMargins={settings.selSlicesX[3],settings.selSlicesY[0],settings.selSlicesX[5],settings.selSlicesY[2]};
					RECT itemRect2=itemRect;
					itemRect2.left=splitX;
					int w=itemRect2.right-itemRect2.left;
					int h=itemRect2.bottom-itemRect2.top;
					if (rMargins.left>w) rMargins.left=w;
					if (rMargins.right>w) rMargins.right=w;
					if (rMargins.top>h) rMargins.top=h;
					if (rMargins.bottom>h) rMargins.bottom=h;
					MarginsBlit(hdc2,hdc,rSrc,itemRect2,rMargins,settings.bmpSelection.bIs32);
				}
				SelectObject(hdc2,bmp0);
			}
			else if (settings.bmpSelection.GetBitmap())
			{
				HGDIOBJ bmp0=SelectObject(hdc2,settings.bmpSelection.GetBitmap());
				RECT rSrc={0,0,settings.selSlicesX[0]+settings.selSlicesX[1]+settings.selSlicesX[2],settings.selSlicesY[0]+settings.selSlicesY[1]+settings.selSlicesY[2]};
				{
					RECT rMargins={settings.selSlicesX[0],settings.selSlicesY[0],settings.selSlicesX[2],settings.selSlicesY[2]};
					RECT itemRect2=itemRect;
					if (bSplit) itemRect2.right=splitX;
					int w=itemRect2.right-itemRect2.left;
					int h=itemRect2.bottom-itemRect2.top;
					if (rMargins.left>w) rMargins.left=w;
					if (rMargins.right>w) rMargins.right=w;
					if (rMargins.top>h) rMargins.top=h;
					if (rMargins.bottom>h) rMargins.bottom=h;
					MarginsBlit(hdc2,hdc,rSrc,itemRect2,rMargins,settings.bmpSelection.bIs32);
				}
				if (bSplit)
				{
					RECT rMargins={settings.selSlicesX[0],settings.selSlicesY[0],settings.selSlicesX[2],settings.selSlicesY[2]};
					RECT itemRect2=itemRect;
					itemRect2.left=splitX;
					int w=itemRect2.right-itemRect2.left;
					int h=itemRect2.bottom-itemRect2.top;
					if (rMargins.left>w) rMargins.left=w;
					if (rMargins.right>w) rMargins.right=w;
					if (rMargins.top>h) rMargins.top=h;
					if (rMargins.bottom>h) rMargins.bottom=h;
					MarginsBlit(hdc2,hdc,rSrc,itemRect2,rMargins,settings.bmpSelection.bIs32);
				}
				SelectObject(hdc2,bmp0);
			}
			else if (item.id==MENU_SHUTDOWN_BUTTON)
			{
				RECT itemRect2=itemRect;
				itemRect2.right=splitX;
				if (A4SMenuProfile::IsEnabled())
				{
					// The command and chevron remain separate hit targets, but their
					// visual selection is one continuous rounded surface.
					if (stateLeft>0 || stateRight>0)
						DrawA4SSelectionRect(hdc,itemRect,s_Skin.Dpi);
				}
				else
					DrawEdge(hdc,&itemRect2,stateLeft==2?BDR_SUNKENOUTER:BDR_RAISEDINNER,BF_RECT|BF_MIDDLE);
				if (bHot && m_Submenu==-1 && s_bKeyboardCues)
				{
					RECT focus=itemRect2;
					if (s_Skin.Dpi>=144)
						InflateRect(&focus,-3,-3);
					else
						InflateRect(&focus,-2,-2);
					SetBkColor(hdc,0);
					SetTextColor(hdc,0xFFFFFF);
					DrawFocusRect(hdc,&focus);
				}
				itemRect2.left=itemRect2.right;
				itemRect2.right=itemRect.right;
				if (!A4SMenuProfile::IsEnabled())
					DrawEdge(hdc,&itemRect2,stateRight==2?BDR_SUNKENOUTER:BDR_RAISEDINNER,BF_RECT|BF_MIDDLE);
			}
			else
			{
				SetDCBrushColor(hdc,settings.bmpSelection.GetColor());
				SetDCPenColor(hdc,settings.bmpSelection.GetColor());
				if (bSplit)
				{
					if (stateLeft>0)
					{
						RECT itemRect2=itemRect;
						itemRect2.right=splitX;
						if (A4SMenuProfile::IsEnabled())
							DrawA4SSelectionRect(hdc,itemRect2,s_Skin.Dpi);
						else
							FillRect(hdc,&itemRect2,(HBRUSH)GetStockObject(DC_BRUSH));
					}
					else if (!A4SMenuProfile::IsEnabled())
					{
						SelectObject(hdc,GetStockObject(DC_PEN));
						SelectObject(hdc,GetStockObject(NULL_BRUSH));
						Rectangle(hdc,itemRect.left,itemRect.top,splitX+1,itemRect.bottom);
					}
					if (stateRight>0)
					{
						RECT itemRect2=itemRect;
						itemRect2.left=splitX+1;
						if (A4SMenuProfile::IsEnabled())
							DrawA4SSelectionRect(hdc,itemRect2,s_Skin.Dpi);
						else
							FillRect(hdc,&itemRect2,(HBRUSH)GetStockObject(DC_BRUSH));
					}
					else if (!A4SMenuProfile::IsEnabled())
					{
						SelectObject(hdc,GetStockObject(DC_PEN));
						SelectObject(hdc,GetStockObject(NULL_BRUSH));
						Rectangle(hdc,splitX-1,itemRect.top,itemRect.right,itemRect.bottom);
					}
				}
				else
				{
					if (A4SMenuProfile::IsEnabled())
					{
						RECT selectionRect=itemRect;
						if (IsA4SShutdownFlyout())
						{
							// Trim only the visible first/last hover fills. Row geometry,
							// text baselines, keyboard focus, and hit targets stay intact.
							if (item.id==MENU_SWITCHUSER)
								selectionRect.top+=A4SMenuProfile::Scale(2,s_Skin.Dpi);
							else if (item.id==MENU_RESTART || item.id==MENU_RESTART_NOUPDATE)
								selectionRect.bottom-=A4SMenuProfile::Scale(2,s_Skin.Dpi);
						}
						DrawA4SSelectionRect(hdc,selectionRect,s_Skin.Dpi);
					}
					else
						FillRect(hdc,&itemRect,(HBRUSH)GetStockObject(DC_BRUSH));
				}
			}
		}

		if (item.id==MENU_SEPARATOR || item.id==MENU_SEARCH_CATEGORY)
		{
			if (A4SMenuProfile::IsEnabled() && item.id==MENU_SEPARATOR)
			{
				if (m_bSubMenu || item.column==1)
				{
					RECT line=itemRect;
					line.top=(line.top+line.bottom)/2;
					line.bottom=line.top+(std::max)(1,A4SMenuProfile::Scale(1,s_Skin.Dpi));
					FillA4SOpaqueRect(hdc,line,RGB(56,56,56));
				}
				continue;
			}
			if (A4SMenuProfile::IsEnabled() && item.id==MENU_SEARCH_CATEGORY)
			{
				// StartAllBack paints a plain, larger category caption. It has no
				// disclosure glyph, count, hover split, or trailing separator rule.
				SelectObject(hdc,settings.font);
				RECT rc={A4SMenuProfile::Scale(13,s_Skin.Dpi),itemRect.top-A4SMenuProfile::Scale(3,s_Skin.Dpi),
					A4SMenuProfile::Scale(452,s_Skin.Dpi),itemRect.bottom-A4SMenuProfile::Scale(3,s_Skin.Dpi)};
				const DWORD flags=DT_VCENTER|DT_SINGLELINE|DT_END_ELLIPSIS|DT_NOPREFIX;
				SetBkMode(hdc,TRANSPARENT);
				if (s_Theme)
				{
					DTTOPTS opts={sizeof(opts),DTT_TEXTCOLOR|DTT_COMPOSITED};
					opts.crText=RGB(224,224,224);
					DrawThemeTextEx(s_Theme,hdc,0,0,item.name,item.name.GetLength(),flags,&rc,&opts);
				}
				else
				{
					SetTextColor(hdc,RGB(224,224,224));
					DrawText(hdc,item.name,item.name.GetLength(),&rc,flags);
				}
				continue;
			}
			// draw separator
			if (!item.bBlankSeparator && itemRect.bottom>itemRect.top)
			{
				RECT itemRect2=itemRect;
				if (item.id==MENU_SEARCH_CATEGORY)
				{
					itemRect2.left+=settings.iconPadding.left;
					if (item.bSplit)
						itemRect2.right=splitX;
					if (s_Skin.Search_arrow.GetBitmap())
					{
						int x=itemRect2.left;
						int y=(itemRect2.top+itemRect2.bottom-s_Skin.Search_arrow_size.cy)/2;
						int v=(m_SearchCategoryHash==item.categoryHash?s_Skin.Search_arrow_size.cy:0);
						HGDIOBJ bmp0=SelectObject(hdc2,s_Skin.Search_arrow.GetBitmap());
						if (s_Skin.Search_arrow.bIs32)
						{
							BLENDFUNCTION func={AC_SRC_OVER,0,255,AC_SRC_ALPHA};
							AlphaBlend(hdc,x,y,s_Skin.Search_arrow_size.cx,s_Skin.Search_arrow_size.cy,hdc2,0,v,s_Skin.Search_arrow_size.cx,s_Skin.Search_arrow_size.cy,func);
						}
						else
							BitBlt(hdc,x,y,s_Skin.Search_arrow_size.cx,s_Skin.Search_arrow_size.cy,hdc2,0,v,SRCCOPY);
						SelectObject(hdc2,bmp0);
						itemRect2.left+=settings.iconPadding.right+s_Skin.Search_arrow_size.cx;
					}
					else
					{
						const POINT *sizes=s_Skin.GetArrowsBitmapSizes();
						int x=itemRect2.left;
						int y=(itemRect2.top+itemRect2.bottom-sizes[6].y)/2;
						HGDIOBJ bmp0=SelectObject(hdc2,GetArrowsBitmap(settings.arrColors[((bHot && (!bSplit || stateLeft>0))?1:0)]));
						BLENDFUNCTION func={AC_SRC_OVER,0,255,AC_SRC_ALPHA};
						if (m_SearchCategoryHash==item.categoryHash)
						{
							SIZE s={sizes[5].y-sizes[5].x,sizes[6].y};
							AlphaBlend(hdc,x,y,s.cx,s.cy,hdc2,s_bRTL?sizes[6].x-sizes[5].y:sizes[5].x,0,s.cx,s.cy,func);
						}
						else
						{
							SIZE s={sizes[3].y-sizes[3].x,sizes[6].y};
							int dx=(sizes[5].y-sizes[5].x-s.cx+1)/2;
							AlphaBlend(hdc,x+dx,y,s.cx,s.cy,hdc2,s_bRTL?sizes[6].x-sizes[4].y:sizes[3].x,0,s.cx,s.cy,func);
						}
						SelectObject(hdc2,bmp0);
						itemRect2.left+=settings.iconPadding.right+sizes[5].y-sizes[5].x+1;
					}
				}
				if (!item.name.IsEmpty())
				{
					if (item.id==MENU_SEARCH_CATEGORY && !item.bSplit && item.categoryHash>=CSearchManager::CATEGORY_FILE && index==m_HotItem && m_bHotArrow)
						SelectObject(hdc,s_Skin.Search_underline_font);
					else
						SelectObject(hdc,settings.font);

					COLORREF color=settings.textColors[(bHot && (!bSplit || stateLeft>0))?1:0];
					COLORREF shadowColor=settings.textShadowColors[(bHot && (!bSplit || stateLeft>0))?1:0];
					RECT rc={itemRect2.left+settings.textPadding.left,itemRect2.top+settings.textTopOffset+settings.textPadding.top-settings.textPadding.bottom,
						       itemRect2.right-settings.arrSize.cx-settings.arrPadding.cx-settings.arrPadding.cy-settings.textPadding.right,itemRect2.bottom-settings.textTopOffset};
					DWORD flags=DT_VCENTER|DT_SINGLELINE|DT_END_ELLIPSIS|DT_NOPREFIX;
					if (s_Theme)
					{
						DTTOPTS opts={sizeof(opts),DTT_TEXTCOLOR};
						if (glowSize || settings.opacity==MenuSkin::OPACITY_FULLALPHA || settings.opacity==MenuSkin::OPACITY_FULLGLASS)
							opts.dwFlags|=DTT_COMPOSITED;
						if (glowSize)
						{
							opts.dwFlags|=DTT_GLOWSIZE;
							opts.iGlowSize=glowSize;
						}
						if (shadowColor!=0xFFFFFFFF)
						{
							opts.crText=shadowColor;
							RECT rc2=rc;
							OffsetRect(&rc2,1,1);
							DrawThemeTextEx(s_Theme,hdc,0,0,item.name,item.name.GetLength(),flags,&rc2,&opts);
						}
						opts.crText=color;
						DrawThemeTextEx(s_Theme,hdc,0,0,item.name,item.name.GetLength(),flags,&rc,&opts);
					}
					else
					{
						if (shadowColor!=0xFFFFFFFF)
						{
							RECT rc2=rc;
							OffsetRect(&rc2,1,1);
							SetTextColor(hdc,shadowColor);
							DrawText(hdc,item.name,item.name.GetLength(),&rc,flags);
						}

						SetTextColor(hdc,color);
						DrawText(hdc,item.name,item.name.GetLength(),&rc,flags);
					}
					SIZE size;
					GetTextExtentPoint32(hdc,item.name,item.name.GetLength(),&size);
					itemRect2.left=rc.left+size.cx+settings.textPadding.right;
				}
				if (itemRect2.left<itemRect2.right)
				{
					if (settings.bmpSeparator.GetBitmap())
					{
						itemRect2.top=(itemRect2.top+itemRect2.bottom-settings.sepHeight)/2;
						itemRect2.bottom=itemRect2.top+settings.sepHeight;
						HGDIOBJ bmp0=SelectObject(hdc2,settings.bmpSeparator.GetBitmap());
						RECT rSrc={0,0,settings.sepSlicesX[0]+settings.sepSlicesX[1]+settings.sepSlicesX[2],settings.sepHeight};
						RECT rMargins={settings.sepSlicesX[0],settings.sepHeight,settings.sepSlicesX[2],0};
						MarginsBlit(hdc2,hdc,rSrc,itemRect2,rMargins,settings.bmpSeparator.bIs32);
						SelectObject(hdc2,bmp0);
					}
					else
					{
						if (s_Theme)
						{
							SIZE size;
							if (SUCCEEDED(GetThemePartSize(s_Theme,hdc,TP_SEPARATORVERT,TS_NORMAL,NULL,TS_MIN,&size)))
								OffsetRect(&itemRect2,0,(itemRect2.bottom-itemRect2.top-size.cy)/2);
							DrawThemeBackground(s_Theme,hdc,TP_SEPARATORVERT,TS_NORMAL,&itemRect2,NULL);
						}
						else
						{
							itemRect2.top=itemRect2.bottom=(itemRect2.top+itemRect2.bottom)/2-1;
							DrawEdge(hdc,&itemRect2,EDGE_ETCHED,BF_TOP);
						}
					}
				}
			}
			if (bHot && item.bSplit && item.id==MENU_SEARCH_CATEGORY)
			{
				int x=itemRect.right-settings.arrPadding.cy-s_Skin.More_bitmap_Size.cx;
				int y=(itemRect.top+itemRect.bottom-s_Skin.More_bitmap_Size.cy)/2;
				HGDIOBJ bmp0=SelectObject(hdc2,s_Skin.More_bitmap.GetBitmap());
				if (s_Skin.More_bitmap.bIs32)
				{
					BLENDFUNCTION func={AC_SRC_OVER,0,255,AC_SRC_ALPHA};
					AlphaBlend(hdc,x,y,s_Skin.More_bitmap_Size.cx,s_Skin.More_bitmap_Size.cy,hdc2,0,stateRight==0?s_Skin.More_bitmap_Size.cy:0,s_Skin.More_bitmap_Size.cx,s_Skin.More_bitmap_Size.cy,func);
				}
				else
				{
					BitBlt(hdc,x,y,s_Skin.More_bitmap_Size.cx,s_Skin.More_bitmap_Size.cy,hdc2,0,stateRight==0?s_Skin.More_bitmap_Size.cy:0,SRCCOPY);
				}
				SelectObject(hdc2,bmp0);
			}
			continue;
		}

		if (item.id==MENU_SEARCH_BOX)
		{
			if (A4SMenuProfile::IsEnabled())
			{
				if (m_SearchState<SEARCH_TEXT)
					DrawA4SSearchMagnifier(hdc,itemRect.left+A4SMenuProfile::Scale(5,s_Skin.Dpi),
						itemRect.top+A4SMenuProfile::Scale(5,s_Skin.Dpi),s_Skin.Dpi);
				else
					DrawA4SSearchClear(hdc,itemRect.left+A4SMenuProfile::Scale(6,s_Skin.Dpi),
						itemRect.top+A4SMenuProfile::Scale(6,s_Skin.Dpi),s_Skin.Dpi);
				DrawA4SSearchEdit(hdc);
				continue;
			}
			MenuBitmap searchIcons;
			if (s_Skin.Search_bitmap.GetBitmap())
				searchIcons=s_Skin.Search_bitmap;
			else
			{
				searchIcons.Init();
				searchIcons=m_SearchIcons;
				searchIcons.bIs32=true;
			}

			RECT rc;
			m_SearchBox.GetWindowRect(&rc);
			int iconSize=16, iconY=0;
			int icon;
			if (m_SearchState<SEARCH_TEXT)
				icon=s_bRTL?4:0;
			else
				icon=s_bRTL?3:1;
			if (rc.bottom-rc.top>=30)
			{
				iconSize=20;
				iconY=16;
				if (s_bRTL)
					icon--;
			}
			HGDIOBJ bmp0=SelectObject(hdc2,searchIcons.GetBitmap());
			RECT rSrc={0,0,iconSize,iconSize};
			RECT rDst=rSrc;
			OffsetRect(&rSrc,iconSize*icon,iconY);
			OffsetRect(&rDst,(itemRect.right+itemRect.left-iconSize)/2,(itemRect.bottom+itemRect.top-iconSize)/2);
			RECT rMargins={0,0,0,0};
			MarginsBlit(hdc2,hdc,rSrc,rDst,rMargins,searchIcons.bIs32);
			SelectObject(hdc2,bmp0);
			continue;
		}

		bool bNoIcon=!item.bInline && settings.iconSize==MenuSkin::ICON_SIZE_NONE;
		const bool bA4SSearchListIcon=A4SMenuProfile::IsEnabled() && !m_bSubMenu && s_MenuMode==MODE_SEARCH &&
			(item.id==MENU_MORE_RESULTS || (index>=m_OriginalCount &&
			(item.id==MENU_NO || item.id==MENU_SEARCH_EXECUTE || item.id==MENU_SEARCH_EMPTY)));
		SIZE iconSize;
		if (bA4SSearchListIcon)
			iconSize.cx=iconSize.cy=A4SMenuProfile::Scale(item.id==MENU_MORE_RESULTS?18:16,s_Skin.Dpi);
		else if (settings.iconSize==MenuSkin::ICON_SIZE_SMALL)
			iconSize.cx=iconSize.cy=g_ItemManager.SMALL_ICON_SIZE;
		else if (settings.iconSize==MenuSkin::ICON_SIZE_LARGE)
			iconSize.cx=iconSize.cy=g_ItemManager.LARGE_ICON_SIZE;
		else if (settings.iconSize==MenuSkin::ICON_SIZE_PROGRAMS)
		{
			if (s_Skin.Programs_icon.GetBitmap())
				iconSize=s_Skin.Programs_icon_size;
			else
			{
				iconSize.cx=s_Skin.ItemSettings[MenuSkin::COLUMN1_ITEM].iconSize==MenuSkin::ICON_SIZE_SMALL?g_ItemManager.SMALL_ICON_SIZE:g_ItemManager.LARGE_ICON_SIZE;
				iconSize.cy=7;
			}
		}
		else
			iconSize.cx=iconSize.cy=0;

		COLORREF color, shadowColor;
		{
			bool bHotColor = (bHot && !bSplit) || stateLeft > 0;
			if (item.id == MENU_EMPTY || item.id == MENU_EMPTY_TOP)
			{
				color = settings.textColors[bHotColor ? 3 : 2];
				shadowColor = settings.textShadowColors[bHotColor ? 3 : 2];
			}
			else
			{
				color = settings.textColors[bHotColor ? 1 : 0];
				shadowColor = settings.textShadowColors[bHotColor ? 1 : 0];
			}
		}
		if (bA4SContextFlyout && !bA4SContextItemEnabled)
		{
			color=RGB(128,128,128);
			shadowColor=0xFFFFFFFF;
		}

		A4SRightGlyph a4sRightGlyph=A4S_RIGHT_GLYPH_NONE;
		const bool bA4SRightPane=A4SMenuProfile::IsEnabled() && !m_bSubMenu &&
			drawType>=MenuSkin::COLUMN2_ITEM && drawType<=MenuSkin::COLUMN2_INLINE;
		if (bA4SRightPane)
		{
			// Keep a deterministic 20-DIP icon cell instead of inheriting the
			// process-global shell small-icon metric at higher DPI.
			iconSize.cx=iconSize.cy=A4SMenuProfile::Scale(20,s_Skin.Dpi);
			switch (item.id)
			{
				case MENU_USERFILES:
					a4sRightGlyph=A4S_RIGHT_GLYPH_USER;
					break;
				case MENU_USERDOCUMENTS:
					a4sRightGlyph=A4S_RIGHT_GLYPH_DOCUMENT;
					break;
				case MENU_COMPUTER:
					a4sRightGlyph=A4S_RIGHT_GLYPH_PC;
					break;
				case MENU_CONTROLPANEL:
					a4sRightGlyph=A4S_RIGHT_GLYPH_CONTROL_PANEL;
					break;
				case MENU_PCSETTINGS:
					a4sRightGlyph=A4S_RIGHT_GLYPH_SETTINGS;
					break;
				case MENU_RUN:
					a4sRightGlyph=A4S_RIGHT_GLYPH_RUN;
					break;
				case MENU_CUSTOM:
					if (item.pStdItem && item.pStdItem->folder1 && IsEqualGUID(*item.pStdItem->folder1,FOLDERID_Downloads))
						a4sRightGlyph=A4S_RIGHT_GLYPH_DOWNLOAD;
					else if (item.pStdItem && item.pStdItem->command && _wcsicmp(item.pStdItem->command,L"cmd.exe")==0)
						a4sRightGlyph=A4S_RIGHT_GLYPH_COMMAND;
					break;
			}
		}

		// draw icon
		if (drawType==MenuSkin::PROGRAMS_BUTTON || drawType==MenuSkin::PROGRAMS_BUTTON_NEW)
		{
			if (A4SMenuProfile::IsEnabled())
			{
				const bool left=s_MenuMode==MODE_PROGRAMS;
				const int x=itemRect.left+A4SMenuProfile::Scale(11,s_Skin.Dpi);
				const int y=(itemRect.top+itemRect.bottom-A4SMenuProfile::Scale(10,s_Skin.Dpi))/2;
				DrawA4SChevron(hdc,x,y,s_Skin.Dpi,settings.arrColors[bHot?1:0],left);
			}
			else if (s_Skin.Programs_icon.GetBitmap())
			{
				int iconX=itemRect.left+settings.iconPadding.left;
				int iconY=itemRect.top+settings.iconPadding.top+settings.iconTopOffset;
				const MenuBitmap &icon=bHot?s_Skin.Programs_icon_selected:s_Skin.Programs_icon;
				HGDIOBJ bmp0=SelectObject(hdc2,icon.GetBitmap());
				if (icon.bIs32)
				{
					BLENDFUNCTION func={AC_SRC_OVER,0,255,AC_SRC_ALPHA};
					AlphaBlend(hdc,iconX,iconY,s_Skin.Programs_icon_size.cx,s_Skin.Programs_icon_size.cy,hdc2,0,s_MenuMode==MODE_PROGRAMS?s_Skin.Programs_icon_size.cy:0,s_Skin.Programs_icon_size.cx,s_Skin.Programs_icon_size.cy,func);
				}
				else
					BitBlt(hdc,iconX,iconY,s_Skin.Programs_icon_size.cx,s_Skin.Programs_icon_size.cy,hdc2,0,s_MenuMode==MODE_PROGRAMS?s_Skin.Programs_icon_size.cy:0,SRCCOPY);
				SelectObject(hdc2,bmp0);
			}
			else
			{
				const POINT *sizes=s_Skin.GetArrowsBitmapSizes();
				SIZE s={sizes[4].y-sizes[4].x,sizes[6].y};
				int x=itemRect.left+settings.arrPadding.cx;
				int y=(itemRect.top+itemRect.bottom-s.cy)/2;
				HGDIOBJ bmp0=SelectObject(hdc2,GetArrowsBitmap(settings.arrColors[bHot?1:0]));
				BLENDFUNCTION func={AC_SRC_OVER,0,255,AC_SRC_ALPHA};
				if (s_MenuMode==MODE_PROGRAMS)
				{
					AlphaBlend(hdc,x,y,s.cx,s.cy,hdc2,s_bRTL?sizes[6].x-sizes[3].y:sizes[4].x,0,s.cx,s.cy,func);
				}
				else
				{
					AlphaBlend(hdc,x,y,s.cx,s.cy,hdc2,s_bRTL?sizes[6].x-sizes[4].y:sizes[3].x,0,s.cx,s.cy,func);
				}
				SelectObject(hdc2,bmp0);
			}
		}
		else if (bA4SContextFlyout)
		{
			if (item.id==MENU_A4S_CONTEXT_RUNAS)
			{
				SHSTOCKICONINFO shield={sizeof(shield)};
				if (SUCCEEDED(SHGetStockIconInfo(SIID_SHIELD,SHGSI_ICON|SHGSI_SMALLICON,&shield)) && shield.hIcon)
				{
					const int size=A4SMenuProfile::Scale(16,s_Skin.Dpi);
					const int x=A4SMenuProfile::Scale(11,s_Skin.Dpi);
					const int y=(itemRect.top+itemRect.bottom-size)/2;
					if (bA4SContextItemEnabled)
						DrawIconEx(hdc,x,y,shield.hIcon,size,size,0,NULL,DI_NORMAL);
					else
						DrawState(hdc,NULL,NULL,(LPARAM)shield.hIcon,0,x,y,size,size,DST_ICON|DSS_DISABLED);
					DestroyIcon(shield.hIcon);
				}
			}
		}
		else if (bA4SRightPane)
		{
			// Preserve the fixed icon gutter even if an unexpected right-pane item
			// has no procedural role; never leak a colored shell icon into it.
			if (!bNoIcon && a4sRightGlyph!=A4S_RIGHT_GLYPH_NONE)
			{
				const int iconX=itemRect.left+settings.iconPadding.left;
				const int iconY=itemRect.top+settings.iconPadding.top+settings.iconTopOffset;
				DrawA4SRightGlyph(hdc,iconX,iconY,iconSize.cx,s_Skin.Dpi,color,a4sRightGlyph);
			}
		}
		else if (item.pItemInfo && !bNoIcon)
		{
			int iconX=itemRect.left+settings.iconPadding.left;
			int iconY=itemRect.top+settings.iconPadding.top+settings.iconTopOffset;
			if (A4SMenuProfile::IsEnabled() && item.id==MENU_MORE_RESULTS)
				iconY-=A4SMenuProfile::Scale(1,s_Skin.Dpi);
			if (settings.bmpIconFrame.GetBitmap())
			{
				HGDIOBJ bmp0=SelectObject(hdc2,settings.bmpIconFrame.GetBitmap());
				RECT rSrc={0,0,settings.frameSlicesX[0]+settings.frameSlicesX[1]+settings.frameSlicesX[2],settings.frameSlicesY[0]+settings.frameSlicesY[1]+settings.frameSlicesY[2]};
				if (bHot)
					OffsetRect(&rSrc,rSrc.right,0);
				RECT rDst={iconX,iconY,iconX+iconSize.cx,iconY+iconSize.cy};
				InflateRect(&rDst,settings.iconFrameOffset.x,settings.iconFrameOffset.y);
				RECT rMargins={settings.frameSlicesX[0],settings.frameSlicesY[0],settings.frameSlicesX[2],settings.frameSlicesY[2]};
				MarginsBlit(hdc2,hdc,rSrc,rDst,rMargins,settings.bmpIconFrame.bIs32);
				SelectObject(hdc2,bmp0);
			}
			const CItemManager::IconInfo *pIcon=(settings.iconSize==MenuSkin::ICON_SIZE_LARGE)?item.pItemInfo->largeIcon:item.pItemInfo->smallIcon;
			if (pIcon && pIcon->bitmap)
			{
				HBITMAP temp = ColorizeMonochromeImage(pIcon->bitmap, color);
				HBITMAP bitmap = temp ? temp : pIcon->bitmap;

				BITMAP info;
				GetObject(bitmap,sizeof(info),&info);
				HGDIOBJ bmp0=SelectObject(hdc2,bitmap);
				if (bmp0)
				{
					BLENDFUNCTION func={AC_SRC_OVER,0,255,AC_SRC_ALPHA};
					AlphaBlend(hdc,iconX,iconY,iconSize.cx,iconSize.cy,hdc2,0,0,info.bmWidth,info.bmHeight,func);
					SelectObject(hdc2,bmp0);
				}

				if (temp)
					DeleteObject(temp);
			}
		}
		else if (item.id==MENU_SHUTDOWN_BUTTON && (s_Skin.Shutdown_power_glyph || (s_bHasUpdates && s_Skin.Shutdown_bitmap.GetBitmap())))
		{
			int iconX=itemRect.left+settings.iconPadding.left;
			int iconY=itemRect.top+settings.iconPadding.top+settings.iconTopOffset;
			if (stateLeft==2 && !settings.bmpSelection.GetBitmap())
				iconX++, iconY++;
			if (s_Skin.Shutdown_power_glyph)
			{
				DrawPowerGlyph(hdc,iconX,iconY,s_Skin.Shutdown_power_glyph_size,color);
			}
			else
			{
				HGDIOBJ bmp0=SelectObject(hdc2,s_Skin.Shutdown_bitmap.GetBitmap());
				if (s_Skin.Shutdown_bitmap.bIs32)
				{
					BLENDFUNCTION func={AC_SRC_OVER,0,255,AC_SRC_ALPHA};
					AlphaBlend(hdc,iconX,iconY,s_Skin.Shutdown_bitmap_Size.cx,s_Skin.Shutdown_bitmap_Size.cy,hdc2,0,0,s_Skin.Shutdown_bitmap_Size.cx,s_Skin.Shutdown_bitmap_Size.cy,func);
				}
				else
					BitBlt(hdc,iconX,iconY,s_Skin.Shutdown_bitmap_Size.cx,s_Skin.Shutdown_bitmap_Size.cy,hdc2,0,0,SRCCOPY);
				SelectObject(hdc2,bmp0);
			}
		}


		// draw text
		SelectObject(hdc,settings.font);
		RECT rc={itemRect.left+settings.iconPadding.left+settings.iconPadding.right+settings.textPadding.left,itemRect.top+settings.textPadding.top,
		         itemRect.right-settings.arrPadding.cx-settings.arrPadding.cy-settings.textPadding.right,itemRect.bottom-settings.textPadding.bottom};
		if (item.id==MENU_SHUTDOWN_BUTTON)
		{
			if (s_Skin.Shutdown_power_glyph)
				rc.left+=s_Skin.Shutdown_power_glyph_size-settings.iconPadding.left-settings.iconPadding.right;
			else if (s_bHasUpdates && s_Skin.Shutdown_bitmap.GetBitmap())
				rc.left+=s_Skin.Shutdown_bitmap_Size.cx-settings.iconPadding.left-settings.iconPadding.right;
			if (stateLeft==2 && !settings.bmpSelection.GetBitmap())
				OffsetRect(&rc,1,1);
		}
		if (s_MenuMode==MODE_SEARCH && !m_bSubMenu && item.id==MENU_NO && index>=m_OriginalCount)
			rc.right+=settings.arrPadding.cx+settings.arrPadding.cy;
		else
			rc.right-=(item.jumpIndex>=0)?s_Skin.Pin_bitmap_Size.cx:settings.arrSize.cx;
		if (!bNoIcon)
			rc.left+=iconSize.cx;
		if (A4SMenuProfile::IsEnabled() && !m_bSubMenu && s_MenuMode==MODE_SEARCH)
		{
			if (item.id==MENU_MORE_RESULTS)
			{
				rc.left-=A4SMenuProfile::Scale(2,s_Skin.Dpi);
				OffsetRect(&rc,0,-A4SMenuProfile::Scale(1,s_Skin.Dpi));
			}
			else if (index>=m_OriginalCount && item.id==MENU_NO)
				rc.left-=A4SMenuProfile::Scale(1,s_Skin.Dpi);
		}
		if (A4SMenuProfile::IsEnabled() && item.id==MENU_SHUTDOWN_BUTTON)
			rc.left-=A4SMenuProfile::Scale(2,s_Skin.Dpi);
		if (A4SMenuProfile::IsEnabled() && IsA4SShutdownFlyout() &&
			(item.id==MENU_RESTART || item.id==MENU_RESTART_NOUPDATE))
			OffsetRect(&rc,0,-A4SMenuProfile::Scale(1,s_Skin.Dpi));
		if (bA4SContextFlyout)
		{
			rc.left=A4SMenuProfile::Scale(35,s_Skin.Dpi);
			rc.top=itemRect.top;
			rc.right=A4SMenuProfile::Scale(208,s_Skin.Dpi);
			rc.bottom=itemRect.bottom;
		}

		DWORD flags=DT_END_ELLIPSIS;
		if (item.id==MENU_NO || (item.id==MENU_RECENT && recentType!=RECENT_KEYS_DIGITS))
			flags|=DT_NOPREFIX;
		else if (!s_bKeyboardCues)
			flags|=DT_HIDEPREFIX;

		CString name;
		if (drawType==MenuSkin::PROGRAMS_BUTTON || drawType==MenuSkin::PROGRAMS_BUTTON_NEW || drawType==MenuSkin::PROGRAMS_CASCADING || drawType==MenuSkin::PROGRAMS_CASCADING_NEW)
			name=s_MenuMode==MODE_PROGRAMS?FindTranslation(L"Menu.Back",L"Back"):FindTranslation(L"Menu.AllPrograms",L"All Programs");
		else
			name=item.name;

		if (settings.textMetrics.tmHeight*2<=rc.bottom-rc.top)
		{
			// if the height can fit two lines, see if we can make use of them
			RECT rc2={0,0,rc.right-rc.left,0};
			DrawText(hdc,name,name.GetLength(),&rc2,flags|DT_WORDBREAK|DT_CALCRECT);
			if (2*rc2.bottom>settings.textMetrics.tmHeight*3)
			{
				flags|=DT_EDITCONTROL|DT_WORDBREAK;
				int d=rc.bottom-rc.top-settings.textMetrics.tmHeight*2;
				rc.top+=d/2;
			}
		}
		if (!(flags&DT_WORDBREAK))
			flags|=DT_VCENTER|DT_SINGLELINE;

		if (s_Theme)
		{
			DTTOPTS opts={sizeof(opts),DTT_TEXTCOLOR};
			if (bA4SContextFlyout || glowSize || settings.opacity==MenuSkin::OPACITY_FULLALPHA || settings.opacity==MenuSkin::OPACITY_FULLGLASS)
				opts.dwFlags|=DTT_COMPOSITED;
			if (glowSize)
			{
				opts.dwFlags|=DTT_GLOWSIZE;
				opts.iGlowSize=glowSize;
			}
			if (shadowColor!=0xFFFFFFFF)
			{
				opts.crText=shadowColor;
				RECT rc2=rc;
				OffsetRect(&rc2,1,1);
				DrawThemeTextEx(s_Theme,hdc,0,0,name,name.GetLength(),flags,&rc2,&opts);
			}
			opts.crText=color;
			DrawThemeTextEx(s_Theme,hdc,0,0,name,name.GetLength(),flags,&rc,&opts);
		}
		else
		{
			if (shadowColor!=0xFFFFFFFF)
			{
				RECT rc2=rc;
				OffsetRect(&rc2,1,1);
				SetTextColor(hdc,shadowColor);
				DrawText(hdc,item.name,item.name.GetLength(),&rc,flags);
			}

			SetTextColor(hdc,color);
			DrawText(hdc,name,name.GetLength(),&rc,flags);
		}

		if (item.bFolder && drawType!=MenuSkin::PROGRAMS_BUTTON && drawType!=MenuSkin::PROGRAMS_BUTTON_NEW)
		{
			// draw the sub-menu arrows
			bool bHotArrow=(bHot && !bSplit) || stateRight>0;
			if (A4SMenuProfile::IsEnabled() && item.id==MENU_SHUTDOWN_BUTTON)
			{
				const int x=itemRect.right-A4SMenuProfile::Scale(14,s_Skin.Dpi);
				const int y=(itemRect.top+itemRect.bottom-A4SMenuProfile::Scale(10,s_Skin.Dpi))/2;
				DrawA4SChevron(hdc,x,y,s_Skin.Dpi,settings.arrColors[bHotArrow?1:0],false);
			}
			else if (settings.bmpArrow.GetBitmap())
			{
				int x=itemRect.right-settings.arrPadding.cy-settings.arrSize.cx;
				int y=(itemRect.top+itemRect.bottom-settings.arrSize.cy)/2;
				if (stateRight==2 && !settings.bmpSelection.GetBitmap())
					x++, y++;
				HGDIOBJ bmp0=SelectObject(hdc2,settings.bmpArrow.GetBitmap());
				if (settings.bmpArrow.bIs32)
				{
					BLENDFUNCTION func={AC_SRC_OVER,0,255,AC_SRC_ALPHA};
					AlphaBlend(hdc,x,y,settings.arrSize.cx,settings.arrSize.cy,hdc2,0,bHotArrow?settings.arrSize.cy:0,settings.arrSize.cx,settings.arrSize.cy,func);
				}
				else
				{
					BitBlt(hdc,x,y,settings.arrSize.cx,settings.arrSize.cy,hdc2,0,bHotArrow?settings.arrSize.cy:0,SRCCOPY);
				}
				SelectObject(hdc2,bmp0);
			}
			else
			{
				const POINT *sizes=s_Skin.GetArrowsBitmapSizes();
				SIZE s={sizes[3].y-sizes[3].x,sizes[6].y};
				int x=itemRect.right-settings.arrPadding.cy-s.cx;
				int y=(itemRect.top+itemRect.bottom-s.cy)/2;
				if (stateRight==2 && !settings.bmpSelection.GetBitmap())
					x++, y++;
				HGDIOBJ bmp0=SelectObject(hdc2,GetArrowsBitmap(settings.arrColors[bHotArrow?1:0]));
				BLENDFUNCTION func={AC_SRC_OVER,0,255,AC_SRC_ALPHA};
				AlphaBlend(hdc,x,y,s.cx,s.cy,hdc2,s_bRTL?sizes[6].x-sizes[4].y:sizes[3].x,0,s.cx,s.cy,func);
				SelectObject(hdc2,bmp0);
			}
		}
		else if (bHot && item.bSplit && item.jumpIndex>=0)
		{
			int x=itemRect.right-settings.arrPadding.cy-s_Skin.Pin_bitmap_Size.cx;
			int y=(itemRect.top+itemRect.bottom-s_Skin.Pin_bitmap_Size.cy)/2;
			HGDIOBJ bmp0=SelectObject(hdc2,s_Skin.Pin_bitmap.GetBitmap());
			bool bPinned=s_JumpList.groups[LOWORD(item.jumpIndex)].type==CJumpGroup::TYPE_PINNED;
			if (s_Skin.Pin_bitmap.bIs32)
			{
				BLENDFUNCTION func={AC_SRC_OVER,0,255,AC_SRC_ALPHA};
				AlphaBlend(hdc,x,y,s_Skin.Pin_bitmap_Size.cx,s_Skin.Pin_bitmap_Size.cy,hdc2,bPinned?s_Skin.Pin_bitmap_Size.cx:0,stateRight==0?s_Skin.Pin_bitmap_Size.cy:0,s_Skin.Pin_bitmap_Size.cx,s_Skin.Pin_bitmap_Size.cy,func);
			}
			else
			{
				BitBlt(hdc,x,y,s_Skin.Pin_bitmap_Size.cx,s_Skin.Pin_bitmap_Size.cy,hdc2,bPinned?s_Skin.Pin_bitmap_Size.cx:0,stateRight==0?s_Skin.Pin_bitmap_Size.cy:0,SRCCOPY);
			}
			SelectObject(hdc2,bmp0);
		}
	}

	// draw vertical separators
	if (m_bSubMenu && m_ColumnOffsets.size()>1)
	{
		if (bmpSeparatorV.GetBitmap())
		{
			HGDIOBJ bmp0=SelectObject(hdc2,bmpSeparatorV.GetBitmap());
			RECT rSrc={0,0,sepWidth,sepSlicesY[0]+sepSlicesY[1]+sepSlicesY[2]};
			RECT rMargins={0,sepSlicesY[0],0,sepSlicesY[2]};
			for (size_t i=1;i<m_ColumnOffsets.size();i++)
			{
				int x=m_rContent.left+m_ColumnOffsets[i];
				RECT rc={x-sepWidth,m_rContent.top,x,m_rContent.bottom};
				MarginsBlit(hdc2,hdc,rSrc,rc,rMargins,bmpSeparatorV.bIs32);
			}
			SelectObject(hdc2,bmp0);
		}
		else
		{
			int offset=0;
			if (s_Theme)
			{
				SIZE size;
				if (SUCCEEDED(GetThemePartSize(s_Theme,hdc,TP_SEPARATOR,TS_NORMAL,NULL,TS_MIN,&size)))
					offset=(sepWidth-size.cx)/2;
			}
			else
			{
				offset=(sepWidth-2)/2;
			}
			for (size_t i=1;i<m_ColumnOffsets.size();i++)
			{
				int x=m_rContent.left+m_ColumnOffsets[i]+offset;
				RECT rc={x-sepWidth,m_rContent.top,x,m_rContent.bottom};
				if (s_Theme)
					DrawThemeBackground(s_Theme,hdc,TP_SEPARATOR,TS_NORMAL,&rc,NULL);
				else
					DrawEdge(hdc,&rc,EDGE_ETCHED,BF_LEFT);
			}
		}
	}

	// draw insert mark
	{
		RECT rc;
		if (GetInsertRect(rc))
		{
			HGDIOBJ bmp0=SelectObject(hdc2,GetArrowsBitmap(s_Skin.ItemSettings[m_bSubMenu?MenuSkin::SUBMENU_ITEM:MenuSkin::COLUMN1_ITEM].arrColors[0])); // the insert mask can't be in the second column of the main menu
			const POINT *sizes=s_Skin.GetArrowsBitmapSizes();
			RECT rSrc={s_bRTL?sizes[6].x-sizes[2].y:sizes[0].x,0,s_bRTL?sizes[6].x-sizes[0].x:sizes[2].y,sizes[1].y};
			RECT rMargins={sizes[0].y-sizes[0].x,0,sizes[2].y-sizes[2].x,0};
			MarginsBlit(hdc2,hdc,rSrc,rc,rMargins,true);
			SelectObject(hdc2,bmp0);
		}
	}

	SelectObject(hdc,font0);

	DeleteDC(hdc2);
}

LRESULT CMenuContainer::OnPaint( UINT uMsg, WPARAM wParam, LPARAM lParam, BOOL& bHandled )
{
	// handles both WM_PAINT and WM_PRINTCLIENT
	MenuSkin::TOpacity opacity=(m_bSubMenu?s_Skin.Submenu_opacity:s_Skin.Main_opacity);
	MenuSkin::TOpacity opacity2=s_MenuMode==MODE_JUMPLIST?s_Skin.Jumplist_opacity:s_Skin.Main2_opacity;
	if ((!m_bSubMenu && m_Bitmap) || (m_bSubMenu && s_Skin.Submenu_bitmap.GetBitmap()))
	{
		if (!A4SMenuProfile::IsEnabled() && (opacity==MenuSkin::OPACITY_GLASS || opacity==MenuSkin::OPACITY_FULLGLASS))
		{
			DWM_BLURBEHIND blur={DWM_BB_ENABLE|DWM_BB_BLURREGION,TRUE,m_Region,FALSE};
			DwmEnableBlurBehindWindow(m_hWnd,&blur);
		}
		else if (opacity==MenuSkin::OPACITY_REGION)
		{
			DWM_BLURBEHIND blur={DWM_BB_ENABLE|((uMsg==WM_PRINTCLIENT)?DWM_BB_BLURREGION:0U),(uMsg==WM_PRINTCLIENT),m_Region,FALSE};
			DwmEnableBlurBehindWindow(m_hWnd,&blur);
		}
	}

	PAINTSTRUCT ps;
	HDC hdc;
	if (uMsg==WM_PRINTCLIENT)
	{
		hdc=(HDC)wParam;
		GetClientRect(&ps.rcPaint);
	}
	else
	{
		hdc=BeginPaint(&ps);
		OffsetViewportOrgEx(hdc,m_PaintOffset.x,m_PaintOffset.y,NULL);
		OffsetRect(&ps.rcPaint,-m_PaintOffset.x,-m_PaintOffset.y);
	}

	BP_PAINTPARAMS paintParams={sizeof(paintParams)};
	paintParams.dwFlags=BPPF_ERASE;

	HDC hdcPaint=NULL;
	HPAINTBUFFER hBufferedPaint=BeginBufferedPaint(hdc,&ps.rcPaint,BPBF_TOPDOWNDIB,&paintParams,&hdcPaint);
	if (hdcPaint)
	{
		if (s_OldMenuState.mode!=MODE_UNKNOWN)
		{
			HDC hSrc=CreateCompatibleDC(hdcPaint);
			HGDIOBJ bmp0=SelectObject(hSrc,m_Bitmap);
			BITMAP info;
			GetObject(m_Bitmap,sizeof(info),&info);
			RECT rc1={m_BitmapOffset,0,info.bmWidth+m_BitmapOffset,info.bmHeight};
			RECT rc2;
			IntersectRect(&rc2,&rc1,&ps.rcPaint);
			BitBlt(hdcPaint,rc2.left,rc2.top,rc2.right-rc2.left,rc2.bottom-rc2.top,hSrc,rc2.left-m_BitmapOffset,rc2.top,SRCCOPY);
			SelectObject(hSrc,bmp0);
			DeleteDC(hSrc);
		}
		else
		{
			DrawBackground(hdcPaint,ps.rcPaint);
		}
		if (m_bSubMenu?s_Skin.Submenu_FakeGlass:s_Skin.Main_FakeGlass)
		{
			static unsigned char remapAlpha[256];
			if (!remapAlpha[255])
			{
				for (int i=0;i<256;i++)
					remapAlpha[i]=(unsigned char)(255*pow(i/255.f,0.2f));
			}
			HBITMAP bmp0=CreateCompatibleBitmap(hdcPaint,1,1);
			HGDIOBJ bmp=SelectObject(hdcPaint,bmp0);
			BITMAP info;
			GetObject(bmp,sizeof(info),&info);
			if (info.bmBitsPixel==32)
			{
				int n=info.bmWidth*info.bmHeight;
				for (int i=0;i<n;i++)
				{
					unsigned int &pixel=((unsigned int*)info.bmBits)[i];
					int a=pixel>>24;
					a=remapAlpha[a];
					pixel=(a<<24)|(pixel&0xFFFFFF);
				}
			}
			SelectObject(hdcPaint,bmp);
			DeleteObject(bmp0);
		}
		if (!A4SMenuProfile::IsEnabled() && m_SearchBox.m_hWnd && ((uMsg==WM_PRINTCLIENT && (lParam&PRF_CHILDREN)) || (uMsg==WM_PAINT && !m_bSearchDrawn)))
		{
			RECT rc;
			GetWindowRect(&rc);
			m_SearchBox.GetWindowRect(&rc);
			::MapWindowPoints(NULL,m_hWnd,(POINT*)&rc,2);

			// print the editbox to a new bitmap, and then blit to hdcPaint. printing directly into hdcPaint doesn't quite work with RTL
			HDC hdcSearch=CreateCompatibleDC(hdcPaint);
			HBITMAP bmpSearch=CreateCompatibleBitmap(hdcPaint,rc.right-rc.left,rc.bottom-rc.top);
			HGDIOBJ bmp0=SelectObject(hdcSearch,bmpSearch);

			if (s_bRTL) SetLayout(hdcSearch,0);
			m_SearchBox.SendMessage(WM_PRINTCLIENT,(WPARAM)hdcSearch,PRF_CLIENT);
			if (s_bRTL) SetLayout(hdcSearch,LAYOUT_RTL);
			BitBlt(hdcPaint,rc.left,rc.top,rc.right-rc.left,rc.bottom-rc.top,hdcSearch,0,0,SRCCOPY);
			BufferedPaintSetAlpha(hBufferedPaint,&rc,255);
			SelectObject(hdcSearch,bmp0);
			DeleteDC(hdcSearch);
			DeleteObject(bmpSearch);
		}
		if (m_pProgramsTree && s_MenuMode==MODE_PROGRAMS)
		{
			bool bDrawTree=(uMsg==WM_PAINT && (m_PaintOffset.x!=0 || m_PaintOffset.y!=0)) || (uMsg==WM_PRINTCLIENT && (lParam&PRF_CHILDREN));
			if (bDrawTree)
			{
				RECT rc;
				m_pProgramsTree->GetWindowRect(&rc);
				::MapWindowPoints(NULL,m_hWnd,(POINT*)&rc,2);
				SetViewportOrgEx(hdcPaint,rc.left,rc.top,NULL);
				m_pProgramsTree->GetClientRect(&rc);
				m_pProgramsTree->DrawTree(hdcPaint,rc);
				m_pProgramsTree->Print(hdcPaint,PRF_NONCLIENT);
				SetViewportOrgEx(hdcPaint,0,0,NULL);
			}
		}
		if (opacity==MenuSkin::OPACITY_REGION && uMsg==WM_PRINTCLIENT && m_bSubMenu && s_Skin.Submenu_bitmap.bIsBitmap && !s_Skin.Submenu_bitmap.bIs32)
		{
			// if the bitmap is 24-bit, the alpha channel may be undefined
			BufferedPaintSetAlpha(hBufferedPaint,&ps.rcPaint,255);
		}
		else
		{
			if (s_OldMenuState.mode==MODE_UNKNOWN)
			{
				if (opacity==MenuSkin::OPACITY_GLASS || opacity==MenuSkin::OPACITY_ALPHA || (opacity==MenuSkin::OPACITY_REGION && uMsg==WM_PRINTCLIENT))
				{
					RECT rc;
					IntersectRect(&rc,&ps.rcPaint,&m_rContent);
					BufferedPaintSetAlpha(hBufferedPaint,&rc,255);
				}
				if (m_bTwoColumns && (opacity2==MenuSkin::OPACITY_GLASS || opacity2==MenuSkin::OPACITY_ALPHA || (opacity2==MenuSkin::OPACITY_REGION && uMsg==WM_PRINTCLIENT)))
				{
					RECT rc;
					IntersectRect(&rc,&ps.rcPaint,&m_rContent2);
					BufferedPaintSetAlpha(hBufferedPaint,&rc,255);
				}
			}
			if (!A4SMenuProfile::IsEnabled() && m_SearchIndex>=0 && s_bWin7Style && ((s_Skin.Search_background_jump.GetBitmap() && !s_Skin.Search_background_jump.bIs32) || !s_Skin.Search_background_jump.bIsBitmap))
			{
				RECT padding;
				if (s_MenuMode==MODE_SEARCH)
					padding=s_Skin.Search_background_search_padding;
				else if (s_MenuMode==MODE_JUMPLIST)
					padding=s_Skin.Search_background_jump_padding;
				else
					padding=s_Skin.Search_background_padding;
				RECT rcSearch;
				rcSearch.left=m_rContent.right-padding.left;
				rcSearch.right=m_rContent2.left+padding.right;
				rcSearch.top=m_Items[m_SearchIndex].itemRect.top-s_Skin.Search_padding.top-padding.top;
				rcSearch.bottom=m_rContent.bottom+padding.bottom;
				RECT rc;
				IntersectRect(&rc,&ps.rcPaint,&rcSearch);
				BufferedPaintSetAlpha(hBufferedPaint,&rc,255);
			}
		}
		EndBufferedPaint(hBufferedPaint,TRUE);
	}

	if (uMsg!=WM_PRINTCLIENT)
		EndPaint(&ps);

	return 0;
}

static void FillSolidGlassRect( HDC hdc, LPCRECT pRect, COLORREF color )
{
	BP_PAINTPARAMS paintParams={sizeof(paintParams)};
	paintParams.dwFlags=0;
	HDC hdcPaint=NULL;
	HPAINTBUFFER hBufferedPaint=BeginBufferedPaint(hdc,pRect,BPBF_TOPDOWNDIB,&paintParams,&hdcPaint);
	if (hdcPaint)
	{
		SetDCBrushColor(hdcPaint,color);
		FillRect(hdcPaint,pRect,(HBRUSH)GetStockObject(DC_BRUSH));
		BufferedPaintSetAlpha(hBufferedPaint,pRect,255);
		EndBufferedPaint(hBufferedPaint,TRUE);
	}
}

enum A4SScrollbarShape
{
	A4S_SCROLL_CAPSULE,
	A4S_SCROLL_ARROW_UP,
	A4S_SCROLL_ARROW_DOWN,
};

static void DrawA4SScrollbarShape( HDC hdc, const RECT &rect, COLORREF color, A4SScrollbarShape shape )
{
	const int width=rect.right-rect.left;
	const int height=rect.bottom-rect.top;
	if (width<=0 || height<=0)
		return;

	BITMAPINFO bi={0};
	bi.bmiHeader.biSize=sizeof(BITMAPINFOHEADER);
	bi.bmiHeader.biWidth=width;
	bi.bmiHeader.biHeight=-height;
	bi.bmiHeader.biPlanes=1;
	bi.bmiHeader.biBitCount=32;
	bi.bmiHeader.biCompression=BI_RGB;

	HDC hdcShape=CreateCompatibleDC(hdc);
	if (!hdcShape)
		return;
	unsigned int *bits=NULL;
	HBITMAP bitmap=CreateDIBSection(hdc,&bi,DIB_RGB_COLORS,(void **)&bits,NULL,0);
	if (!bitmap || !bits)
	{
		if (bitmap) DeleteObject(bitmap);
		DeleteDC(hdcShape);
		return;
	}
	HGDIOBJ bitmap0=SelectObject(hdcShape,bitmap);

	const int samples=4;
	const int sampleCount=samples*samples;
	const int red=GetRValue(color);
	const int green=GetGValue(color);
	const int blue=GetBValue(color);
	for (int y=0;y<height;y++)
	{
		for (int x=0;x<width;x++)
		{
			int covered=0;
			for (int sy=0;sy<samples;sy++)
			{
				for (int sx=0;sx<samples;sx++)
				{
					const double fx=x+(sx+0.5)/samples;
					const double fy=y+(sy+0.5)/samples;
					bool inside=false;
					if (shape==A4S_SCROLL_CAPSULE)
					{
						const double radius=width*0.5;
						double centerY=fy;
						if (centerY<radius) centerY=radius;
						else if (centerY>height-radius) centerY=height-radius;
						const double dx=fx-width*0.5;
						const double dy=fy-centerY;
						inside=dx*dx+dy*dy<=radius*radius;
					}
					else
					{
						const double progress=shape==A4S_SCROLL_ARROW_UP?fy/height:(height-fy)/height;
						inside=fabs(fx-width*0.5)<=progress*width*0.5;
					}
					if (inside) covered++;
				}
			}
			const unsigned int alpha=(covered*255+sampleCount/2)/sampleCount;
			const unsigned int r=red*alpha/255;
			const unsigned int g=green*alpha/255;
			const unsigned int b=blue*alpha/255;
			bits[y*width+x]=(alpha<<24)|(r<<16)|(g<<8)|b;
		}
	}

	AlphaBlend(hdc,rect.left,rect.top,width,height,hdcShape,0,0,width,height,g_AlphaFunc);
	SelectObject(hdcShape,bitmap0);
	DeleteObject(bitmap);
	DeleteDC(hdcShape);
}

static void RestoreA4SScrollbarBackground( HDC hdc, LPCRECT pRect )
{
	if (!pRect)
		return;

	if (g_CustomScrollbarBackground && IsWindow(g_CustomScrollbarWindow) && IsWindow(g_CustomScrollbarOwnerWindow))
	{
		RECT sourceRect=*pRect;
		MapWindowPoints(g_CustomScrollbarWindow,g_CustomScrollbarOwnerWindow,(POINT *)&sourceRect,2);
		HDC hdcSource=CreateCompatibleDC(hdc);
		if (hdcSource)
		{
			HGDIOBJ bitmap0=SelectObject(hdcSource,g_CustomScrollbarBackground);
			BOOL restored=BitBlt(hdc,pRect->left,pRect->top,pRect->right-pRect->left,pRect->bottom-pRect->top,
				hdcSource,sourceRect.left,sourceRect.top,SRCCOPY);
			SelectObject(hdcSource,bitmap0);
			DeleteDC(hdcSource);
			if (restored)
				return;
		}
	}

	// The context is normally supplied by the tree/control subclass. If its
	// backing bitmap is temporarily unavailable, ask the parent to paint through
	// instead of turning the zero "reuse parent" sentinel into opaque black.
	if (IsWindow(g_CustomScrollbarWindow))
		DrawThemeParentBackground(g_CustomScrollbarWindow,hdc,pRect);
}

static bool IsA4SScrollbarPaintActive( void )
{
	if (!IsWindow(g_CustomScrollbarWindow))
		return false;

	// The renderer context is copied from persistent CProgramsTree hover/pulse
	// state for every native paint. The property is retained as a diagnostic and
	// as a fallback for any unexpected theme callback outside the normal thunk.
	if (g_CustomScrollbarActive)
		return true;
	if (GetProp(g_CustomScrollbarWindow,L"A4SMenu.ScrollbarActive"))
		return true;

	// Keep a thumb drag active even if capture carries the pointer beyond the
	// scrollbar's bounds.
	if (GetCapture()==g_CustomScrollbarWindow && GetKeyState(VK_LBUTTON)<0)
		return true;

	POINT cursor;
	if (!GetCursorPos(&cursor))
		return false;

	// A standalone scrollbar control owns its whole window.
	wchar_t className[32];
	if (GetClassName(g_CustomScrollbarWindow,className,_countof(className)) && _wcsicmp(className,WC_SCROLLBAR)==0)
	{
		RECT windowRect;
		return GetWindowRect(g_CustomScrollbarWindow,&windowRect) && PtInRect(&windowRect,cursor);
	}

	// Query the accessibility scrollbar object rather than inferring the band
	// from GetClientRect. Windows 11 themed TreeViews may use an inset/overlay
	// scroller whose rectangle is inside the nominal client area.
	SCROLLBARINFO info={sizeof(info)};
	if (!GetScrollBarInfo(g_CustomScrollbarWindow,OBJID_VSCROLL,&info) ||
		(info.rgstate[0]&0x00008000))
		return false;
	return PtInRect(&info.rcScrollBar,cursor)!=FALSE;
}

void CProgramsTree::DrawTree( HDC hdc, const RECT &drawRect )
{
	RECT rcClient;
	GetClientRect(&rcClient);
	{
		RECT rc;
		TreeView_GetItemRect(m_hWnd,TreeView_GetRoot(m_hWnd),&rc,TRUE);
		m_MinX=rc.left-m_RootX; // detect when the tree auto-scrolls

		// find the widest of the visible elements
		m_MaxX=rcClient.right;
		int maxy=rcClient.bottom;
		for (HTREEITEM hItem=TreeView_GetFirstVisible(m_hWnd);hItem;hItem=TreeView_GetNextVisible(m_hWnd,hItem))
		{
			TreeView_GetItemRect(m_hWnd,hItem,&rc,TRUE);
			if (m_MaxX<rc.right) m_MaxX=rc.right;
			if (rc.bottom>=maxy)
				break;
		}
	}

	BP_PAINTPARAMS paintParams={sizeof(paintParams)};
	HDC hdcPaint=NULL;
	HPAINTBUFFER hBufferedPaint=BeginBufferedPaint(hdc,&drawRect,BPBF_TOPDOWNDIB,&paintParams,&hdcPaint);
	if (hdcPaint)
	{
		HDC hsrc=CreateCompatibleDC(hdcPaint);
		const MenuSkin &skin=CMenuContainer::s_Skin;
		int alpha;
		if (skin.Programs_background==0)
		{
			RECT bmpRect=drawRect;
			::MapWindowPoints(m_hWnd,m_pOwner->m_hWnd,(POINT*)&bmpRect,2);
			HGDIOBJ bmp0=SelectObject(hsrc,m_pOwner->m_Bitmap);
			BitBlt(hdcPaint,drawRect.left,drawRect.top,drawRect.right-drawRect.left,drawRect.bottom-drawRect.top,hsrc,bmpRect.left,bmpRect.top,SRCCOPY);
			SelectObject(hsrc,bmp0);
			alpha=(skin.Main_opacity==MenuSkin::OPACITY_ALPHA || skin.Main_opacity==MenuSkin::OPACITY_GLASS)?255:0;
		}
		else
		{
			SetDCBrushColor(hdcPaint,skin.Programs_background&0xFFFFFF);
			FillRect(hdcPaint,&drawRect,(HBRUSH)GetStockObject(DC_BRUSH));
			alpha=skin.Programs_background>>24;
			if (alpha<255)
			{
				if (skin.Main_FakeGlass)
					alpha=(unsigned char)(255*pow(alpha/255.f,0.2f));
				BufferedPaintSetAlpha(hBufferedPaint,&drawRect,alpha);
			}
		}

		SelectObject(hdcPaint,GetFont());
		HTREEITEM hSelection=TreeView_GetSelection(m_hWnd);
		HTREEITEM hHilight=TreeView_GetDropHilight(m_hWnd);
		HWND focus=GetFocus();
		for (HTREEITEM hItem=TreeView_GetFirstVisible(m_hWnd);hItem;hItem=TreeView_GetNextVisible(m_hWnd,hItem))
		{
			RECT itemRect;
			TreeView_GetItemRect(m_hWnd,hItem,&itemRect,TRUE);
			if (itemRect.top>=drawRect.bottom)
				break;
			bool bHot=((hItem==hSelection && m_DropLocation==DROP_NOWHERE) || hItem==hHilight) && (m_pOwner->m_HotItem==m_pOwner->m_ProgramTreeIndex || focus==m_hWnd);
			if (itemRect.bottom>drawRect.top)
				DrawTreeItem(hdcPaint,hsrc,hItem,itemRect,bHot);
		}
		RECT rc;
		if (GetInsertRect(rc))
		{
			const POINT *sizes=skin.GetArrowsBitmapSizes();
			HGDIOBJ bmp0=SelectObject(hsrc,CMenuContainer::GetArrowsBitmap(CMenuContainer::s_Skin.ItemSettings[MenuSkin::PROGRAMS_TREE_ITEM].textColors[0]));
			RECT rSrc={CMenuContainer::s_bRTL?sizes[6].x-sizes[2].y:sizes[0].x,0,CMenuContainer::s_bRTL?sizes[6].x-sizes[0].x:sizes[2].y,sizes[1].y};
			RECT rMargins={sizes[0].y-sizes[0].x,0,sizes[2].y-sizes[2].x,0};
			MarginsBlit(hsrc,hdcPaint,rSrc,rc,rMargins,true);
			SelectObject(hsrc,bmp0);
		}
		DeleteDC(hsrc);

		if (alpha==255)
			BufferedPaintSetAlpha(hBufferedPaint,&drawRect,alpha);
		EndBufferedPaint(hBufferedPaint,TRUE);
	}
}

void CProgramsTree::DrawTreeItem( HDC hdc, HDC hsrc, HTREEITEM hItem, const RECT &itemRect, bool bHot ) const
{
	TVITEM item={TVIF_PARAM|TVIF_STATE,hItem,0,TVIS_SELECTED};
	TreeView_GetItem(m_hWnd,&item);

	const MenuSkin &skin=CMenuContainer::s_Skin;
	const CTreeItem *pItem=(CTreeItem*)item.lParam;
	COLORREF textColor;
	COLORREF shadowColor;
	MenuBitmap bmp;
	const int *slicesX, *slicesY;
	RECT iconPadding;
	int iconTopOffset, textTopOffset;
	int glowSize;
	if (bHot)
	{
		// selected
		const MenuSkin::ItemDrawSettings &settings=skin.ItemSettings[MenuSkin::PROGRAMS_TREE_ITEM];
		bmp=settings.bmpSelection;
		slicesX=settings.selSlicesX;
		slicesY=settings.selSlicesY;
		iconPadding=settings.iconPadding;
		iconTopOffset=settings.iconTopOffset+settings.iconPadding.top;
		textTopOffset=settings.textTopOffset+settings.textPadding.top;
		textColor=settings.textColors[pItem->bEmpty?3:1];
		shadowColor=settings.textShadowColors[bHot?1:0];
		glowSize=settings.glowSize;
	}
	else if (pItem->bNew && !A4SMenuProfile::IsEnabled())
	{
		// highlighted
		const MenuSkin::ItemDrawSettings &settings=skin.ItemSettings[MenuSkin::PROGRAMS_TREE_NEW];
		bmp=settings.bmpSelection;
		slicesX=settings.selSlicesX;
		slicesY=settings.selSlicesY;
		iconPadding=settings.iconPadding;
		iconTopOffset=settings.iconTopOffset+settings.iconPadding.top;
		textTopOffset=settings.textTopOffset+settings.textPadding.top;
		textColor=settings.textColors[pItem->bEmpty?2:0];
		shadowColor=settings.textShadowColors[bHot?1:0];
		glowSize=settings.glowSize;
	}
	else
	{
		// not selected
		bmp=skin.Programs_background;
		const MenuSkin::ItemDrawSettings &settings=skin.ItemSettings[MenuSkin::PROGRAMS_TREE_ITEM];
		iconPadding=settings.iconPadding;
		iconTopOffset=settings.iconTopOffset+settings.iconPadding.top;
		textTopOffset=settings.textTopOffset+settings.textPadding.top;
		textColor=settings.textColors[pItem->bEmpty?2:0];
		shadowColor=settings.textShadowColors[bHot?1:0];
		glowSize=settings.glowSize;
	}

	RECT rc=itemRect;
	int left=rc.left;
	rc.left=m_MinX;
	rc.right=m_MaxX;

	if (bHot || (pItem->bNew && !A4SMenuProfile::IsEnabled()))
	{
		// draw background
		if (bmp.bIsBitmap)
		{
			HGDIOBJ bmp0=SelectObject(hsrc,bmp.GetBitmap());
			RECT rSrc={0,0,slicesX[0]+slicesX[1]+slicesX[2],slicesY[0]+slicesY[1]+slicesY[2]};
			RECT rMargins={slicesX[0],slicesY[0],slicesX[2],slicesY[2]};
			MarginsBlit(hsrc,hdc,rSrc,rc,rMargins,bmp.bIs32);
			SelectObject(hsrc,bmp0);
		}
		else
		{
			if (A4SMenuProfile::IsEnabled())
				DrawA4SSelectionRect(hdc,rc,skin.Dpi);
			else
			{
				SetDCBrushColor(hdc,bmp.GetColor());
				FillRect(hdc,&rc,(HBRUSH)GetStockObject(DC_BRUSH));
			}
		}
	}

	// draw icon
	rc.left=left;
	int iconSize=CItemManager::SMALL_ICON_SIZE;
	int x=rc.left-iconSize-3-iconPadding.right;
	int y=rc.top+iconTopOffset;

	if (pItem->pItemInfo1 && pItem->pItemInfo1->smallIcon)
	{
		HGDIOBJ bmp0=SelectObject(hsrc,pItem->pItemInfo1->smallIcon->bitmap);
		BLENDFUNCTION func={AC_SRC_OVER,0,255,AC_SRC_ALPHA};
		AlphaBlend(hdc,x,y,iconSize,iconSize,hsrc,0,0,iconSize,iconSize,func);
		SelectObject(hsrc,bmp0);
	}

	// draw text
	rc.top+=textTopOffset;

	if (m_TreeTheme)
	{
		DTTOPTS opts={sizeof(opts),DTT_TEXTCOLOR};
		if (glowSize || skin.ItemSettings[MenuSkin::PROGRAMS_TREE_ITEM].opacity==MenuSkin::OPACITY_FULLALPHA || skin.ItemSettings[MenuSkin::PROGRAMS_TREE_ITEM].opacity==MenuSkin::OPACITY_FULLGLASS)
			opts.dwFlags|=DTT_COMPOSITED;
		if (glowSize)
		{
			opts.dwFlags|=DTT_GLOWSIZE;
			opts.iGlowSize=glowSize;
		}
		if (shadowColor!=0xFFFFFFFF)
		{
			opts.crText=shadowColor;
			RECT rc2=rc;
			OffsetRect(&rc2,1,1);
			DrawThemeTextEx(m_TreeTheme,hdc,0,0,pItem->name,pItem->name.GetLength(),DT_SINGLELINE|DT_NOPREFIX,&rc2,&opts);
		}
		opts.crText=textColor;
		DrawThemeTextEx(m_TreeTheme,hdc,0,0,pItem->name,pItem->name.GetLength(),DT_SINGLELINE|DT_NOPREFIX,&rc,&opts);
	}
	else
	{
		SetBkMode(hdc,TRANSPARENT);
		if (shadowColor!=0xFFFFFFFF)
		{
			RECT rc2=rc;
			OffsetRect(&rc2,1,1);
			SetTextColor(hdc,shadowColor);
			DrawText(hdc,pItem->name,pItem->name.GetLength(),&rc,DT_SINGLELINE|DT_NOPREFIX);
		}

		SetTextColor(hdc,textColor);
		DrawText(hdc,pItem->name,pItem->name.GetLength(),&rc,DT_SINGLELINE|DT_NOPREFIX);
	}
}

void CProgramsTree::DrawScrollbarBackground( HDC hdc, int iPartId, int iStateId, LPCRECT pRect )
{
	const MenuSkin &skin=CMenuContainer::s_Skin;
	if (A4SMenuProfile::IsEnabled())
	{
		if (!pRect)
			return;

		// The themed scrollbar asks for its gripper after drawing the thumb and
		// supplies the full thumb rectangle for that callback. Restoring the
		// backing there erases the middle of our capsule and leaves only its caps.
		// We intentionally have no gripper, so preserve the thumb already drawn.
		if (iPartId==SBP_GRIPPERVERT)
			return;

		// StartAllBack's programs scroller is a quiet centered line: 2 px at
		// rest, 6 px while hovered/dragged, with no boxed track. Clear the native
		// part from the shared acrylic backing before drawing our replacement.
		RestoreA4SScrollbarBackground(hdc,pRect);
		const bool active=IsA4SScrollbarPaintActive();
		if (iPartId==SBP_ARROWBTN)
		{
			if (!active)
				return;
			const bool down=(iStateId>=ABS_DOWNNORMAL && iStateId<=ABS_DOWNDISABLED) || iStateId==ABS_DOWNHOVER;
			const int partWidth=(int)(pRect->right-pRect->left);
			const int partHeight=(int)(pRect->bottom-pRect->top);
			int arrowWidth=(std::max)(3,A4SMenuProfile::Scale(6,skin.Dpi));
			int arrowHeight=(std::max)(2,A4SMenuProfile::Scale(4,skin.Dpi));
			arrowWidth=(std::min)(arrowWidth,partWidth);
			arrowHeight=(std::min)(arrowHeight,partHeight);
			RECT arrowRect={
				(pRect->left+pRect->right-arrowWidth)/2,
				(pRect->top+pRect->bottom-arrowHeight)/2,
				0,0
			};
			arrowRect.right=arrowRect.left+arrowWidth;
			arrowRect.bottom=arrowRect.top+arrowHeight;
			DrawA4SScrollbarShape(hdc,arrowRect,RGB(206,206,206),down?A4S_SCROLL_ARROW_DOWN:A4S_SCROLL_ARROW_UP);
		}
		else if (iPartId==SBP_THUMBBTNVERT)
		{
			const int lineWidth=(std::max)(1,A4SMenuProfile::Scale(active?6:2,skin.Dpi));
			RECT thumb=*pRect;
			thumb.left=(pRect->left+pRect->right-lineWidth)/2;
			thumb.right=thumb.left+lineWidth;
			DrawA4SScrollbarShape(hdc,thumb,active?RGB(206,206,206):RGB(119,119,119),A4S_SCROLL_CAPSULE);
		}
		return;
	}

	HDC hSrc=CreateCompatibleDC(hdc);
	if (iPartId==SBP_ARROWBTN)
	{
		// draw arrows
		int state=0;
		if (iStateId==ABS_UPHOT || iStateId==ABS_DOWNHOT)
			state=1;
		else if (iStateId==ABS_UPPRESSED || iStateId==ABS_DOWNPRESSED)
			state=2;

		HGDIOBJ bmp0=GetCurrentObject(hSrc,OBJ_BITMAP);
		if (skin.Scrollbar_button.bIsBitmap)
		{
			SelectObject(hSrc,skin.Scrollbar_button.GetBitmap());
			int w=skin.Scrollbar_button_slices_X[0]+skin.Scrollbar_button_slices_X[1]+skin.Scrollbar_button_slices_X[2];
			int h=skin.Scrollbar_button_slices_Y[0]+skin.Scrollbar_button_slices_Y[1]+skin.Scrollbar_button_slices_Y[2];
			RECT rSrc={0,h*state,w,h*(state+1)};
			RECT rMargins={skin.Scrollbar_button_slices_X[0],skin.Scrollbar_button_slices_Y[0],skin.Scrollbar_button_slices_X[2],skin.Scrollbar_button_slices_Y[2]};
			MarginsBlit(hSrc,hdc,rSrc,*pRect,rMargins,false);
		}
		else
		{
			FillSolidGlassRect(hdc,pRect,skin.Scrollbar_button.GetColor());
		}

		int arrowOffset=0;
		if ((iStateId>=ABS_DOWNNORMAL && iStateId<=ABS_DOWNDISABLED) || iStateId==ABS_DOWNHOVER)
			arrowOffset=skin.Scrollbar_arrows_size.cx;

		SelectObject(hSrc,skin.Scrollbar_arrows.GetBitmap());
		int x=(pRect->right+pRect->left-skin.Scrollbar_arrows_size.cx)/2;
		int y=(pRect->bottom+pRect->top-skin.Scrollbar_arrows_size.cy)/2;
		StretchBlt2(hdc,x,y,skin.Scrollbar_arrows_size.cx,skin.Scrollbar_arrows_size.cy,hSrc,arrowOffset,skin.Scrollbar_arrows_size.cy*state,skin.Scrollbar_arrows_size.cx,skin.Scrollbar_arrows_size.cy,true);
		SelectObject(hSrc,bmp0);
	}
	else if (iPartId==SBP_LOWERTRACKVERT || iPartId==SBP_UPPERTRACKVERT)
	{
		// draw background
		if (skin.Scrollbar_background.bIsBitmap)
		{
			int state=0;
			if (iStateId==SCRBS_HOT)
				state=1;
			else if (iStateId==SCRBS_PRESSED)
				state=2;

			HGDIOBJ bmp0=SelectObject(hSrc,skin.Scrollbar_background.GetBitmap());
			int w=skin.Scrollbar_background_slices_X[0]+skin.Scrollbar_background_slices_X[1]+skin.Scrollbar_background_slices_X[2];
			int h=skin.Scrollbar_background_slices_Y[0]+skin.Scrollbar_background_slices_Y[1]+skin.Scrollbar_background_slices_Y[2];
			RECT rSrc={0,h*state,w,h*(state+1)};
			RECT rMargins={skin.Scrollbar_background_slices_X[0],skin.Scrollbar_background_slices_Y[0],skin.Scrollbar_background_slices_X[2],skin.Scrollbar_background_slices_Y[2]};
			MarginsBlit(hSrc,hdc,rSrc,*pRect,rMargins,false);
			SelectObject(hSrc,bmp0);
		}
		else
		{
			FillSolidGlassRect(hdc,pRect,skin.Scrollbar_background.GetColor());
		}
	}
	else if (iPartId==SBP_THUMBBTNVERT)
	{
		// draw thumb
		if (skin.Scrollbar_thumb.bIsBitmap)
		{
			int state=0;
			if (iStateId==SCRBS_HOT)
				state=1;
			else if (iStateId==SCRBS_PRESSED)
				state=2;

			HGDIOBJ bmp0=SelectObject(hSrc,skin.Scrollbar_thumb.GetBitmap());
			int w=skin.Scrollbar_thumb_slices_X[0]+skin.Scrollbar_thumb_slices_X[1]+skin.Scrollbar_thumb_slices_X[2];
			int h=skin.Scrollbar_thumb_slices_Y[0]+skin.Scrollbar_thumb_slices_Y[1]+skin.Scrollbar_thumb_slices_Y[2];
			RECT rSrc={0,h*state,w,h*(state+1)};
			RECT rMargins={skin.Scrollbar_thumb_slices_X[0],skin.Scrollbar_thumb_slices_Y[0],skin.Scrollbar_thumb_slices_X[2],skin.Scrollbar_thumb_slices_Y[2]};
			MarginsBlit(hSrc,hdc,rSrc,*pRect,rMargins,false);
		}
		else
		{
			FillSolidGlassRect(hdc,pRect,skin.Scrollbar_thumb.GetColor());
		}
	}
	else if (iPartId==SBP_GRIPPERVERT)
	{
		// draw gripper
		if (skin.Scrollbar_gripper.GetBitmap())
		{
			int state=0;
			if (iStateId==SCRBS_HOT)
				state=1;
			else if (iStateId==SCRBS_PRESSED)
				state=2;

			HGDIOBJ bmp0=SelectObject(hSrc,skin.Scrollbar_gripper.GetBitmap());
			int x=(pRect->right+pRect->left-skin.Scrollbar_gripper_size.cx)/2;
			int y=(pRect->bottom+pRect->top-skin.Scrollbar_gripper_size.cy)/2;
			StretchBlt2(hdc,x,y,skin.Scrollbar_gripper_size.cx,skin.Scrollbar_gripper_size.cy,hSrc,0,skin.Scrollbar_gripper_size.cy*state,skin.Scrollbar_gripper_size.cx,skin.Scrollbar_gripper_size.cy,true);
			SelectObject(hSrc,bmp0);
		}
	}
	DeleteDC(hSrc);
}

void CMenuContainer::AnimateMenu( int flags, int speed, const RECT &rect )
{
	using namespace std::chrono;

	RECT clipRect=m_bSubMenu?s_MenuLimits:s_MainMenuLimits;

	bool bUserPic=(!m_bSubMenu && s_bWin7Style && s_UserPicture.m_hWnd && s_UserPictureRect.top<s_UserPictureRect.bottom);
	int frames=0;

	if ((flags&AW_BLEND) && speed>0)
	{
		// fade in
		SetWindowLong(GWL_EXSTYLE,GetWindowLong(GWL_EXSTYLE)|WS_EX_LAYERED);
		SetWindowPos((flags&AW_TOPMOST)?HWND_TOPMOST:HWND_TOP,&rect,SWP_SHOWWINDOW|((flags&AW_ACTIVATE)?0:SWP_NOACTIVATE));
		if (!m_bSubMenu && s_TaskBar && s_bBehindTaskbar)
		{
			// position the start button on top
			if (s_StartButton)
				::SetWindowPos(s_StartButton,(flags&AW_TOPMOST)?HWND_TOPMOST:HWND_TOP,0,0,0,0,SWP_NOMOVE|SWP_NOSIZE|SWP_NOACTIVATE);
			// position the start menu behind the taskbar
			SetWindowPos(s_TaskBar,0,0,0,0,SWP_NOMOVE|SWP_NOSIZE|SWP_NOACTIVATE);
		}
		if (bUserPic)
		{
			s_UserPicture.Update(0);
			s_UserPicture.SetWindowPos(NULL,&s_UserPictureRect,SWP_NOZORDER|SWP_NOACTIVATE|SWP_SHOWWINDOW);
		}

		// animate
		auto time0=steady_clock::now();
		while (true)
		{
			auto dt=duration_cast<milliseconds>(steady_clock::now()-time0).count();
			if (dt>speed) break;
			float f=dt/(float)speed;
			int alpha=(int)(f*255);
			SetLayeredWindowAttributes(m_hWnd,0,(BYTE)alpha,LWA_ALPHA);
			RedrawWindow();
			if (bUserPic)
				s_UserPicture.Update(alpha);
			frames++;
		}

		SetWindowLong(GWL_EXSTYLE,GetWindowLong(GWL_EXSTYLE)&~WS_EX_LAYERED);
		RedrawWindow();
	}
	else if (!A4SMenuProfile::IsEnabled() && (flags&AW_SLIDE) && speed>0)
	{
		// slide in
		HRGN rgn=CreateRectRgn(0,0,0,0);
		if (!SetWindowRgn(rgn,FALSE)) // set empty region
			DeleteObject(rgn);
		SetWindowPos((flags&AW_TOPMOST)?HWND_TOPMOST:HWND_TOP,&rect,SWP_SHOWWINDOW|((flags&AW_ACTIVATE)?0:SWP_NOACTIVATE));
		if (!m_bSubMenu && s_TaskBar && s_bBehindTaskbar)
		{
			// position the start button on top
			if (s_StartButton)
				::SetWindowPos(s_StartButton,(flags&AW_TOPMOST)?HWND_TOPMOST:HWND_TOP,0,0,0,0,SWP_NOMOVE|SWP_NOSIZE|SWP_NOACTIVATE);
			// position the start menu behind the taskbar
			SetWindowPos(s_TaskBar,0,0,0,0,SWP_NOMOVE|SWP_NOSIZE|SWP_NOACTIVATE);
		}
		if (bUserPic)
		{
			s_UserPicture.Update(0);
			s_UserPicture.SetWindowPos(NULL,&s_UserPictureRect,SWP_NOZORDER|SWP_NOACTIVATE|SWP_SHOWWINDOW);
		}
		if (m_pProgramsTree && s_MenuMode==MODE_PROGRAMS)
			m_pProgramsTree->ShowWindow(SW_HIDE);
		HRGN rgn0=NULL;
		if (m_Region)
		{
			int rgnSize=GetRegionData(m_Region,0,NULL);
			std::vector<char> buf(rgnSize);
			GetRegionData(m_Region,rgnSize,(RGNDATA*)&buf[0]);
			XFORM xform={1,0,0,1};
			if (s_bRTL)
			{
				// mirror the region (again)
				xform.eM11=-1;
				xform.eDx=(float)(m_rMenu.right+m_rMenu.left-m_BitmapOffset);
			}
			rgn0=ExtCreateRegion(&xform,rgnSize,(RGNDATA*)&buf[0]);
		}

		// animate
		auto time0=steady_clock::now();
		int movex=0, movey=0;
		if (flags&AW_HOR_POSITIVE)
		{
			movex=rect.right-rect.left;
			clipRect.left=rect.left;
		}
		else if (flags&AW_HOR_NEGATIVE)
		{
			movex=rect.left-rect.right;
			clipRect.right=rect.right;
		}
		else if (flags&AW_VER_POSITIVE)
		{
			movey=rect.bottom-rect.top;
			clipRect.top=rect.top;
		}
		else
		{
			movey=rect.top-rect.bottom;
			clipRect.bottom=rect.bottom;
		}

		HRGN clipRgn=CreateRectRgn(clipRect.left-rect.left,clipRect.top-rect.top,clipRect.right-rect.left,clipRect.bottom-rect.top); // clip region in window space
		while (true)
		{
			auto dt=duration_cast<milliseconds>(steady_clock::now()-time0).count();
			if (dt>speed) break;
			float f=1-dt/(float)speed;
			f=powf(f,5);
			int dx=(int)(movex*f);
			int dy=(int)(movey*f);
			if (dx==0 && dy==0) break;
			m_PaintOffset.x=-dx;
			m_PaintOffset.y=-dy;

			// calculate region
			HRGN wndRgn=CreateRectRgn(0,0,rect.right-rect.left,rect.bottom-rect.top); // window region
			if (rgn0)
				CombineRgn(wndRgn,rgn0,NULL,RGN_COPY);
			OffsetRgn(wndRgn,-dx,-dy);
			HRGN rgn=CreateRectRgn(0,0,0,0);
			CombineRgn(rgn,clipRgn,wndRgn,RGN_AND); // clipped window region
			if (!SetWindowRgn(rgn,FALSE))
				DeleteObject(rgn);
			DeleteObject(wndRgn);
			RedrawWindow(NULL,NULL,RDW_INVALIDATE|RDW_FRAME|RDW_UPDATENOW);

			// move user pic
			if (bUserPic)
			{
				POINT pos={s_UserPictureRect.left-dx,s_UserPictureRect.top-dy};
				s_UserPicture.UpdatePartial(pos,&clipRect);
			}
			frames++;
		}
		DeleteObject(clipRgn);

		m_PaintOffset.x=m_PaintOffset.y=0;
		if (!SetWindowRgn(rgn0,FALSE) && rgn0)
			DeleteObject(rgn0);
		if (m_pProgramsTree && s_MenuMode==MODE_PROGRAMS)
			m_pProgramsTree->ShowWindow(SW_SHOW);
		RedrawWindow(NULL,NULL,RDW_INVALIDATE|RDW_FRAME|RDW_UPDATENOW);
	}
	else
	{
		// no animation
		SetWindowPos((flags&AW_TOPMOST)?HWND_TOPMOST:HWND_TOP,&rect,SWP_SHOWWINDOW|((flags&AW_ACTIVATE)?0:SWP_NOACTIVATE));
		RedrawWindow(NULL,NULL,RDW_INVALIDATE|RDW_FRAME|RDW_UPDATENOW);
		if (bUserPic)
		{
			s_UserPicture.Update(255);
			s_UserPicture.SetWindowPos(NULL,&s_UserPictureRect,SWP_NOZORDER|SWP_NOACTIVATE|SWP_SHOWWINDOW);
		}
	}

	if (m_SearchBox.m_hWnd)
		m_SearchBox.ShowWindow(SW_SHOW);

	if (bUserPic)
	{
		POINT pos={s_UserPictureRect.left,s_UserPictureRect.top};
		s_UserPicture.UpdatePartial(pos,NULL);
	}

	if (frames)
		LOG_MENU(LOG_OPEN,L"Menu animation %d frames in %dms (%.0f fps)",frames,speed,1000.0*frames/speed);
}
