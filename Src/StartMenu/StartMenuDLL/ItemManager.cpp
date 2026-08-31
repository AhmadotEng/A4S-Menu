// Classic Shell (c) 2009-2017, Ivo Beltchev
// Open-Shell (c) 2017-2018, The Open-Shell Team
// Confidential information of Ivo Beltchev. Not for disclosure or distribution without prior written consent from the author

#include "stdafx.h"
#include "ItemManager.h"
#include "MetroLinkManager.h"
#include "FNVHash.h"
#include "Settings.h"
#include "SettingsUI.h"
#include "Translations.h"
#include "ResourceHelper.h"
#include "MenuContainer.h"
#include "LogManager.h"
#include "StartMenuDLL.h"
#include "A4SPerformance.h"
#include "A4SCacheState.h"
#include "resource.h"
#include <propkey.h>
#include <CommonControls.h>
#include <wincodec.h>
#include <algorithm>

//#define DISABLE_CACHE
//#define FORCE_ALL_NEW

#ifdef BUILD_SETUP
#undef DISABLE_CACHE
#undef FORCE_ALL_NEW
#endif

#ifdef _DEBUG
_declspec(thread) int CItemManager::RWLock::g_LockState[CItemManager::RWLOCK_COUNT]; // 0 - none, 1 - read, 2 - write
#endif

static bool g_bInvertMetroIcons;

const int MAX_FOLDER_LEVELS=10; // don't go more than 10 levels deep
const int REFRESH_DELAY=5000;
const int CACHE_FILE_VERSION=2;

PROPERTYKEY PKEY_MetroIcon={{0x86D40B4D, 0x9069, 0x443C, {0x81, 0x9A, 0x2A, 0x54, 0x09, 0x0D, 0xCC, 0xEC}}, 2};

// app ID resolver interface as described here: http://www.binrand.com/post/1510934-out-using-system-using-system-collections-generic-using-system.html
interface IApplicationResolver: public IUnknown
{
	STDMETHOD(GetAppIDForShortcut)( IShellItem *psi, LPWSTR *ppszAppID );
	// .... we don't care about the rest of the methods ....
};

GUID CLSID_ApplicationResolver={0x660b90c8,0x73a9,0x4b58,{0x8c,0xae,0x35,0x5b,0x7f,0x55,0x34,0x1b}};
// different IIDs for Win8 and Win8: http://a-whiter.livejournal.com/1266.html
GUID IID_IApplicationResolver7={0x46a6eeff,0x908e,0x4dc6,{0x92,0xa6,0x64,0xbe,0x91,0x77,0xb4,0x1c}};
GUID IID_IApplicationResolver8={0xde25675a,0x72de,0x44b4,{0x93,0x73,0x05,0x17,0x04,0x50,0xc1,0x40}};

///////////////////////////////////////////////////////////////////////////////

interface IResourceContext;

MIDL_INTERFACE("6e21e72b-b9b0-42ae-a686-983cf784edcd")
IResourceMap : public IUnknown
{
	virtual HRESULT STDMETHODCALLTYPE GetUri(const wchar_t **pUri ) = 0;
	virtual HRESULT STDMETHODCALLTYPE GetSubtree(const wchar_t *propName, IResourceMap **pSubTree ) = 0;
	virtual HRESULT STDMETHODCALLTYPE GetString( const wchar_t *propName, wchar_t *pString ) = 0;
	virtual HRESULT STDMETHODCALLTYPE GetStringForContext( IResourceContext *pContext, const wchar_t *propName, wchar_t *pString ) = 0;
	virtual HRESULT STDMETHODCALLTYPE GetFilePath( const wchar_t *propName, wchar_t **pPath ) = 0;
	virtual HRESULT STDMETHODCALLTYPE GetFilePathForContext( IResourceContext *pContext, const wchar_t *propName, wchar_t **pPath ) = 0;
};

///////////////////////////////////////////////////////////////////////////////

enum RESOURCE_SCALE
{
	RES_SCALE_100=0,
	RES_SCALE_140=1,
	RES_SCALE_180=2,
	RES_SCALE_80 =3,
};

MIDL_INTERFACE("e3c22b30-8502-4b2f-9133-559674587e51")
IResourceContext : public IUnknown
{
	virtual HRESULT STDMETHODCALLTYPE GetLanguage( void ) = 0;
	virtual HRESULT STDMETHODCALLTYPE GetHomeRegion( wchar_t *pRegion ) = 0;
	virtual HRESULT STDMETHODCALLTYPE GetLayoutDirection( enum RESOURCE_LAYOUT_DIRECTION *pDirection ) = 0;
	virtual HRESULT STDMETHODCALLTYPE GetTargetSize( WORD *pSize ) = 0;
	virtual HRESULT STDMETHODCALLTYPE GetScale( RESOURCE_SCALE *pScale ) = 0;
	virtual HRESULT STDMETHODCALLTYPE GetContrast( enum RESOURCE_CONTRAST *pContrast ) = 0;
	virtual HRESULT STDMETHODCALLTYPE GetAlternateForm( wchar_t *pForm ) = 0;
	virtual HRESULT STDMETHODCALLTYPE GetQualifierValue( const wchar_t *name, wchar_t *pValue ) = 0;
	virtual HRESULT STDMETHODCALLTYPE SetLanguage( const wchar_t *language ) = 0;
	virtual HRESULT STDMETHODCALLTYPE SetHomeRegion( const wchar_t *region ) = 0;
	virtual HRESULT STDMETHODCALLTYPE SetLayoutDirection( enum RESOURCE_LAYOUT_DIRECTION direction ) = 0;
	virtual HRESULT STDMETHODCALLTYPE SetTargetSize( WORD size ) = 0;
	virtual HRESULT STDMETHODCALLTYPE SetScale( RESOURCE_SCALE scale ) = 0;
	virtual HRESULT STDMETHODCALLTYPE SetContrast( void ) = 0;
	virtual HRESULT STDMETHODCALLTYPE SetAlternateForm( const wchar_t *form ) = 0;
};

///////////////////////////////////////////////////////////////////////////////

const CLSID CLSID_ResourceManager={0xdbce7e40, 0x7345, 0x439d, {0xb1, 0x2c, 0x11, 0x4a, 0x11, 0x81, 0x9a, 0x09}};
MIDL_INTERFACE("130a2f65-2be7-4309-9a58-a9052ff2b61c")
IResourceManager : public IUnknown
{
public:
	virtual HRESULT STDMETHODCALLTYPE Initialize( void ) = 0;
	virtual HRESULT STDMETHODCALLTYPE InitializeForCurrentApplication( void ) = 0;
	virtual HRESULT STDMETHODCALLTYPE InitializeForPackage( const wchar_t *name ) = 0;
	virtual HRESULT STDMETHODCALLTYPE InitializeForFile( const wchar_t *fname ) = 0;
	virtual HRESULT STDMETHODCALLTYPE GetMainResourceMap( REFIID riid, void **ppvObject ) = 0;
	virtual HRESULT STDMETHODCALLTYPE GetResourceMap( void ) = 0;
	virtual HRESULT STDMETHODCALLTYPE GetDefaultContext( REFIID riid, void **ppvObject ) = 0;
	virtual HRESULT STDMETHODCALLTYPE GetReference( void ) = 0;
};

///////////////////////////////////////////////////////////////////////////////

extern PROPERTYKEY PKEY_MetroPackagePath;
extern PROPERTYKEY PKEY_MetroPackageName;

static CComPtr<IApplicationResolver> g_pAppResolver;

// Creates the app id resolver object
static void CreateAppResolver( void )
{
	if (GetWinVersion()>=WIN_VER_WIN7)
	{
		CComPtr<IUnknown> pUnknown;
		pUnknown.CoCreateInstance(CLSID_ApplicationResolver);
		if (GetWinVersion()==WIN_VER_WIN7)
			g_pAppResolver=CComQIPtr<IApplicationResolver,&IID_IApplicationResolver7>(pUnknown);
		else
			g_pAppResolver=CComQIPtr<IApplicationResolver,&IID_IApplicationResolver8>(pUnknown);
	}
}

static bool DetectGrayscaleImage( const unsigned int *bits, int stride, int width, int height )
{
	if (width==0 || height==0)
		return false;
	int transparent=0;
	for (int y=0;y<height;y++,bits+=stride)
	{
		for (int x=0;x<width;x++)
		{
			unsigned int pixel=bits[x];
			int a=(pixel>>24)&255;
			int r=(pixel>>16)&255;
			int g=(pixel>>8)&255;
			int b=(pixel)&255;
			if (abs(a-r)>2 || abs(r-g)>2 || abs(r-b)>2 || abs(g-b)>2)
				return false; // found colored pixel
			if (!(pixel&0xFF000000))
				transparent++;
		}
	}
	if ((transparent*100)/(width*height)<5)
		return false; // less than 5% transparent pixels
	return true;
}

static void CreateMonochromeImage( unsigned int *bits, int stride, int width, int height, DWORD metroColor )
{
	int r0=(metroColor)&255;
	int g0=(metroColor>>8)&255;
	int b0=(metroColor>>16)&255;
	for (int y=0;y<height;y++,bits+=stride)
	{
		for (int x=0;x<width;x++)
		{
			unsigned int &pixel=bits[x];
			int a=pixel>>24;
			int r=(r0*a)/255;
			int g=(g0*a)/255;
			int b=(b0*a)/255;
			pixel=(a<<24)|(r<<16)|(g<<8)|b;
		}
	}
}

HBITMAP ColorizeMonochromeImage(HBITMAP bitmap, DWORD color)
{
	{
		BITMAP info{};
		GetObject(bitmap, sizeof(info), &info);
		if (!DetectGrayscaleImage((const unsigned int*)info.bmBits, info.bmWidth, info.bmWidth, info.bmHeight))
			return nullptr;
	}

	HBITMAP bmp = (HBITMAP)CopyImage(bitmap, IMAGE_BITMAP, 0, 0, LR_CREATEDIBSECTION);
	if (bmp)
	{
		BITMAP info{};
		GetObject(bmp, sizeof(info), &info);

		CreateMonochromeImage((unsigned int*)info.bmBits, info.bmWidth, info.bmWidth, info.bmHeight, color);
	}

	return bmp;
}

static HBITMAP BitmapFromMetroIcon( HICON hIcon, int bitmapSize, int iconSize, DWORD metroColor, bool bDestroyIcon=true )
{
	ICONINFO info;
	BITMAP bmpInfo;
	GetIconInfo(hIcon,&info);
	AddTrackedObject(info.hbmColor);
	AddTrackedObject(info.hbmMask);
	if (info.hbmColor)
	{
		GetObject(info.hbmColor,sizeof(bmpInfo),&bmpInfo);
		iconSize=bmpInfo.bmWidth;
		if (iconSize>bitmapSize)
			iconSize=bitmapSize;
	}
	if (info.hbmColor) DeleteObject(info.hbmColor);
	if (info.hbmMask) DeleteObject(info.hbmMask);

	BITMAPINFO bi={0};
	bi.bmiHeader.biSize=sizeof(BITMAPINFOHEADER);
	bi.bmiHeader.biWidth=bi.bmiHeader.biHeight=bitmapSize;
	bi.bmiHeader.biPlanes=1;
	bi.bmiHeader.biBitCount=32;
	RECT rc={0,0,bitmapSize,bitmapSize};

	HDC hdc=CreateCompatibleDC(NULL);
	unsigned int *bits;
	HBITMAP bmp=CreateDIBSection(hdc,&bi,DIB_RGB_COLORS,(void**)&bits,NULL,0);
	HGDIOBJ bmp0=SelectObject(hdc,bmp);
	int offset=(bitmapSize-iconSize)/2;
	bool bInvert=g_bInvertMetroIcons;
	if (g_bInvertMetroIcons)
	{
		FillRect(hdc,&rc,(HBRUSH)GetStockObject(BLACK_BRUSH));
		DrawIconEx(hdc,offset,offset,hIcon,iconSize,iconSize,0,NULL,DI_NORMAL);
		SelectObject(hdc,bmp0);
		unsigned int *bits2=bits+offset*(bitmapSize+1);
		if (DetectGrayscaleImage(bits2,bitmapSize,iconSize,iconSize))
		{
			CreateMonochromeImage(bits2,bitmapSize,iconSize,iconSize,metroColor);
		}
		else
		{
			SelectObject(hdc,bmp);
			bInvert=false;
		}
	}

	if (!bInvert)
	{
		SetDCBrushColor(hdc,metroColor&0xFFFFFF);
		FillRect(hdc,&rc,(HBRUSH)GetStockObject(DC_BRUSH));
		DrawIconEx(hdc,offset,offset,hIcon,iconSize,iconSize,0,NULL,DI_NORMAL);
		SelectObject(hdc,bmp0);
		int n=bitmapSize*bitmapSize;
		for (int i=0;i<n;i++)
			bits[i]|=0xFF000000;
	}
	DeleteDC(hdc);

	if (bDestroyIcon) DestroyIcon(hIcon);
	return bmp;
}

static HBITMAP BitmapFromMetroBitmap( HBITMAP hBitmap, int bitmapSize, DWORD metroColor, bool bDestroyBitmap=true )
{
	BITMAP info;
	GetObject(hBitmap,sizeof(info),&info);
	bool bGrayscale=DetectGrayscaleImage((const unsigned int*)info.bmBits,info.bmWidth,info.bmWidth,info.bmHeight);

	BITMAPINFO bi={0};
	bi.bmiHeader.biSize=sizeof(BITMAPINFOHEADER);
	bi.bmiHeader.biWidth=bi.bmiHeader.biHeight=bitmapSize;
	bi.bmiHeader.biPlanes=1;
	bi.bmiHeader.biBitCount=32;
	RECT rc={0,0,bitmapSize,bitmapSize};

	HDC hdc=CreateCompatibleDC(NULL);
	HDC hsrc=CreateCompatibleDC(NULL);
	unsigned int *bits;
	HBITMAP bmp=CreateDIBSection(hdc,&bi,DIB_RGB_COLORS,(void**)&bits,NULL,0);
	HGDIOBJ bmp0=SelectObject(hdc,bmp);
	HGDIOBJ bmp02=SelectObject(hsrc,hBitmap);
	int offset=(bitmapSize-info.bmWidth)/2;
	if (g_bInvertMetroIcons && bGrayscale)
	{
		FillRect(hdc,&rc,(HBRUSH)GetStockObject(BLACK_BRUSH));
		BitBlt(hdc,offset,offset,info.bmWidth,info.bmHeight,hsrc,0,0,SRCCOPY);
		SelectObject(hdc,bmp0);
		unsigned int *bits2=bits+offset*(bitmapSize+1);
		CreateMonochromeImage(bits2,bitmapSize,info.bmWidth,info.bmHeight,metroColor);
	}
	else
	{
		if (metroColor!=0xFFFFFFFF && bGrayscale)
		{
			SetDCBrushColor(hdc,metroColor&0xFFFFFF);
			FillRect(hdc,&rc,(HBRUSH)GetStockObject(DC_BRUSH));
			BLENDFUNCTION func={AC_SRC_OVER,0,255,AC_SRC_ALPHA};
			AlphaBlend(hdc,offset,offset,info.bmWidth,info.bmHeight,hsrc,0,0,info.bmWidth,info.bmHeight,func);
			SelectObject(hdc,bmp0);

			int n=bitmapSize*bitmapSize;
			for (int i=0;i<n;i++)
				bits[i]|=0xFF000000;
		}
		else
		{
			int n=bitmapSize*bitmapSize;
			for (int i=0;i<n;i++)
				bits[i]=0;
			BitBlt(hdc,offset,offset,info.bmWidth,info.bmHeight,hsrc,0,0,SRCCOPY);
		}
	}
	SelectObject(hsrc,bmp02);
	DeleteDC(hdc);
	DeleteDC(hsrc);

	if (bDestroyBitmap) DeleteObject(hBitmap);
	return bmp;
}

///////////////////////////////////////////////////////////////////////////////

static HBITMAP LoadMetroBitmap0(const wchar_t *path, int bitmapSize, DWORD metroColor = 0xFFFFFFFF)
{
	SIZE size={-bitmapSize,bitmapSize};
	HBITMAP hBitmap=LoadImageFile(path,&size,true,true,NULL);
	if (hBitmap)
	{
		if (metroColor==0xFFFFFFFF)
			return hBitmap;
		return BitmapFromMetroBitmap(hBitmap,bitmapSize,metroColor);
	}
	return NULL;
}

///////////////////////////////////////////////////////////////////////////////

static bool ParseMetroBitmapLocation( wchar_t *location )
{
	CharUpper(location);
	while (1)
	{
		wchar_t *scale=wcswcs(location,L"SCALE-");
		if (!scale) return false;
		if (scale==location || scale[-1]=='\\' || scale[-1]=='.')
		{
			scale+=6;
			if (scale[0]>='0' && scale[0]<='9' && scale[1]>='0' && scale[1]<='9')
			{
				int digits=2;
				while (scale[digits]>='0' && scale[digits]<='9')
					digits++;
				scale[0]='%';
				scale[1]='d';
				if (digits>2)
					memmove(scale+2,scale+digits,Strlen(scale+digits)*2+2);
				return true;
			}
		}
		else
			scale+=6;
		location=scale;
	}
}

static int g_MetroIconScales[]={80,100,140,180}; // 24, 30, 42, 54 pixels

static HBITMAP LoadMetroBitmap( const wchar_t *location, int bitmapSize, DWORD metroColor )
{
	// pick the best sized icon
	int start;
	if (bitmapSize<=26)
		start=0;
	else if (bitmapSize<=32)
		start=1;
	else if (bitmapSize<=44)
		start=2;
	else
		start=3;
	wchar_t path[_MAX_PATH];
	bool bFound=false;
	for (int i=start;i<_countof(g_MetroIconScales);i++) // correct size or bigger (will scale down)
	{
		Sprintf(path,_countof(path),location,g_MetroIconScales[i]);
		if (GetFileAttributes(path)!=INVALID_FILE_ATTRIBUTES)
		{
			bFound=true;
			break;
		}
	}
	if (!bFound)
	{
		for (int i=start-1;i>=0;i--) // smaller (will scale up)
		{
			Sprintf(path,_countof(path),location,g_MetroIconScales[i]);
			if (GetFileAttributes(path)!=INVALID_FILE_ATTRIBUTES)
			{
				bFound=true;
				break;
			}
		}
	}
	if (bFound)
	{
		SIZE size={2-bitmapSize,bitmapSize-2};
		HBITMAP hBitmap=LoadImageFile(path,&size,true,true,NULL);
		if (hBitmap)
			return BitmapFromMetroBitmap(hBitmap,bitmapSize,metroColor);
	}
	return NULL;
}

///////////////////////////////////////////////////////////////////////////////

static bool ParseMetroBitmapLocation2( wchar_t *location )
{
	CharUpper(location);
	wchar_t *png=wcswcs(location,L".PNG-");
	if (!png) return false;
	Strcpy(png,100,L".TARGETSIZE-%d.PNG");
	return true;
}

static int g_MetroIconSizes2[]={16,20,24,32,40,48,64};

static HBITMAP LoadMetroBitmap2( const wchar_t *location, int bitmapSize, DWORD metroColor )
{
	// pick the best sized icon
	int start=-1;
	for (int i=0;i<_countof(g_MetroIconSizes2);i++)
	{
		if (g_MetroIconSizes2[i]>=bitmapSize)
			break;
		start++;
	}
	if (start<0) start=0;
	wchar_t path[_MAX_PATH];
	int iconSize=0;
	for (int i=start;i<_countof(g_MetroIconSizes2);i++) // correct size or bigger (will scale down)
	{
		Sprintf(path,_countof(path),location,g_MetroIconSizes2[i]);
		if (GetFileAttributes(path)!=INVALID_FILE_ATTRIBUTES)
		{
			iconSize=g_MetroIconSizes2[i];
			break;
		}
	}
	if (!iconSize)
	{
		for (int i=start-1;i>=0;i--) // smaller (will scale up)
		{
			Sprintf(path,_countof(path),location,g_MetroIconSizes2[i]);
			if (GetFileAttributes(path)!=INVALID_FILE_ATTRIBUTES)
			{
				iconSize=g_MetroIconSizes2[i];
				break;
			}
		}
	}
	if (iconSize)
	{
		if (iconSize>bitmapSize)
			iconSize=bitmapSize;
		SIZE size={iconSize,iconSize};
		HBITMAP hBitmap=LoadImageFile(path,&size,true,true,NULL);
		if (hBitmap)
			return BitmapFromMetroBitmap(hBitmap,bitmapSize,metroColor);
	}
	return NULL;
}

///////////////////////////////////////////////////////////////////////////////

void CItemManager::LoadIconData::Init( void )
{
	m_IconSizes[0]=SMALL_ICON_SIZE;
	m_IconSizes[1]=LARGE_ICON_SIZE;
	m_IconSizes[2]=EXTRA_LARGE_ICON_SIZE;
	m_IconSizes[3]=SMALL_ICON_SIZE-2;
	m_IconSizes[4]=LARGE_ICON_SIZE-2;
	m_IconSizes[5]=EXTRA_LARGE_ICON_SIZE-2;

	for (int i=0;i<_countof(m_TempLists);i++)
	{
		m_TempLists[i]=ImageList_Create(m_IconSizes[i],m_IconSizes[i],ILC_COLOR32,0,1);
		if (m_TempLists[i])
		{
			ImageList_SetImageCount(m_TempLists[i],1);
			HIMAGELIST_QueryInterface(m_TempLists[i],IID_IImageList2,(void**)&m_pTempLists[i]);
		}
	}
	if (FAILED(m_pFactory.CoCreateInstance(CLSID_WICImagingFactory)))
		m_pFactory.CoCreateInstance(CLSID_WICImagingFactory1);
}

void CItemManager::LoadIconData::Close( void )
{
	for (int i=0;i<_countof(m_TempLists);i++)
	{
		m_pTempLists[i]=NULL;
		if (m_TempLists[i])
			ImageList_Destroy(m_TempLists[i]);
	}
	m_pFactory=NULL;
}

int CItemManager::SMALL_ICON_SIZE;
int CItemManager::LARGE_ICON_SIZE;
int CItemManager::EXTRA_LARGE_ICON_SIZE=64;
int CItemManager::s_DPI;
int CItemManager::s_DPIOverride;

CItemManager g_ItemManager;

CItemManager::CItemManager( void )
{
	m_bInitialized=false;

	memset(m_CriticalSections,0,sizeof(m_CriticalSections));
	memset(m_CriticalSectionOwners,0,sizeof(m_CriticalSectionOwners));
	m_StartEvent=m_WorkEvent=m_ExitEvent=m_DoneEvent=m_PreloadItemsThread=m_RefreshInfoThread=m_SaveCacheThread=NULL;
	m_MainThreadId=m_PreloadItemsThreadId=m_RefreshInfoThreadId=0;
	m_DefaultSmallIcon=m_DefaultLargeIcon=m_DefaultExtraLargeIcon=NULL;
	m_bHasNewPrograms[0]=m_bHasNewPrograms[1]=m_bHasNewApps[0]=m_bHasNewApps[1]=m_bPreloadIcons=m_bPreloadFavorites=false;
	m_LoadingStage=LOAD_STOPPED;
#ifdef A4S_PRODUCT
	m_PendingPidlRefresh=0;
	m_FolderContentGeneration=1;
	m_IconCacheEpoch=1;
	m_A4SPathIdentityGeneration=1;
	m_A4SWatchConfigurationGeneration=1;
	m_A4SPublishedWatchConfigurationGeneration=0;
	m_A4SPublishedWatchIdentityHash=0;
	m_A4SFolderWatchReady=0;
	m_A4SRequiredWatchMask=A4SCacheState::RequiredFolderWatchMask(false,false,false);
	m_A4SArmedWatchMask=0;
	InitializeSRWLock(&m_A4SWatchRootLock);
	m_A4SWatchRootTable.count=0;
	m_A4SItemReadyEvent=NULL;
	m_A4SFolderWatchReadyEvent=NULL;
	m_A4SWatchRebuildEvent=NULL;
#endif
	m_LastCacheSave=0;
	m_TransientHash=1;
}

CItemManager::~CItemManager( void )
{
	Close();
}

bool CItemManager::Init( void )
{
	m_MainThreadId=GetCurrentThreadId();

	{
		// get the DPI setting
		HDC hdc=GetDC(NULL);
		s_DPI=GetDeviceCaps(hdc,LOGPIXELSY);
		ReleaseDC(NULL,hdc);
		s_DPIOverride=GetSettingInt(L"OverrideDPI");
		if (s_DPIOverride!=0)
		{
			if (s_DPIOverride<96) s_DPIOverride=96;
			if (s_DPIOverride>480) s_DPIOverride=480;
		}
	}

	SMALL_ICON_SIZE=GetSettingInt(L"SmallIconSize");
	LARGE_ICON_SIZE=GetSettingInt(L"LargeIconSize");
	m_OldSysAccentColor=GetSystemAccentColor();
	g_bInvertMetroIcons=GetSettingBool(L"InvertMetroIcons");
	m_bOldInvertIcons=g_bInvertMetroIcons;
	m_LoadIconData[0].Init();

	bool bRTL=IsLanguageRTL();

	CComString pPath;
	if (SUCCEEDED(ShGetKnownFolderPath(FOLDERID_StartMenu,&pPath)))
	{
		m_RootStartMenu1=pPath;
		m_RootStartMenu1+=L"\\";
		StringUpper(m_RootStartMenu1);
	}
	pPath.Clear();
	if (SUCCEEDED(ShGetKnownFolderPath(FOLDERID_CommonStartMenu,&pPath)))
	{
		m_RootStartMenu2=pPath;
		m_RootStartMenu2+=L"\\";
		StringUpper(m_RootStartMenu2);
	}
	pPath.Clear();
	if (SUCCEEDED(ShGetKnownFolderPath(FOLDERID_CommonPrograms,&pPath)))
	{
		m_RootCommonPrograms=pPath;
		m_RootCommonPrograms+=L"\\";
		StringUpper(m_RootCommonPrograms);
	}
	pPath.Clear();
	if (SUCCEEDED(ShGetKnownFolderPath(FOLDERID_Desktop,&pPath)))
	{
		m_RootDesktop=pPath;
		m_RootDesktop+=L"\\";
		StringUpper(m_RootDesktop);
	}
	pPath.Clear();

	m_RootGames=L"::{ED228FDF-9EA8-4870-83B1-96B02CFE0D52}\\";
	wchar_t text[_MAX_PATH];
	Sprintf(text,_countof(text),L"%s\\",GetSettingString(L"PinnedItemsPath"));
	DoEnvironmentSubst(text,_countof(text));
	m_RootStartMenu3=text;
	StringUpper(m_RootStartMenu3);
	Strcpy(text,_countof(text),TASKBAR_PINNED_ROOT L"\\");
	DoEnvironmentSubst(text,_countof(text));
	m_RootTaskbar=text;
	StringUpper(m_RootTaskbar);
	Strcpy(text,_countof(text),METRO_APP_ROOT L"\\");
	DoEnvironmentSubst(text,_countof(text));
	m_RootMetro=text;
	StringUpper(m_RootMetro);

	for (int i=0;i<=SHIL_LAST;i++)
	{
		CComPtr<IImageList> pList;
		if (SUCCEEDED(SHGetImageList(i,IID_IImageList,(void**)&pList)))
		{
			int width, height;
			pList->GetIconSize(&width,&height);
			m_ListSizes.emplace_back(width,i);
		}
	}
	std::sort(m_ListSizes.begin(),m_ListSizes.end());

	CreateDefaultIcons();
	LoadCacheFile();

	ItemInfo &item=m_ItemInfos.emplace(0,ItemInfo())->second;
	item.bIconOnly=true;
	item.smallIcon=m_DefaultSmallIcon;
	item.largeIcon=m_DefaultLargeIcon;
	item.extraLargeIcon=m_DefaultExtraLargeIcon;

	for (int i=0;i<RWLOCK_COUNT;i++)
		InitializeSRWLock(&m_RWLocks[i]);
	for (int i=0;i<LOCK_COUNT;i++)
		InitializeCriticalSection(&m_CriticalSections[i]);
	m_bInitialized=true;
	m_bPreloadIcons=GetSettingBool(L"PreCacheIcons");
	m_bPreloadFavorites=(GetSettingInt(L"Favorites")==2);

	m_LoadingStage=LOAD_LOADING;
	m_StartEvent=CreateEvent(NULL,TRUE,FALSE,NULL);
	m_WorkEvent=CreateEvent(NULL,FALSE,FALSE,NULL);
	m_ExitEvent=CreateEvent(NULL,TRUE,FALSE,NULL);
	m_DoneEvent=CreateEvent(NULL,TRUE,FALSE,NULL);
#ifdef A4S_PRODUCT
	InterlockedExchange(&m_A4SFolderWatchReady,0);
	InterlockedExchange(&m_A4SArmedWatchMask,0);
	InterlockedExchange64(&m_A4SPublishedWatchConfigurationGeneration,0);
	InterlockedExchange64(&m_A4SPublishedWatchIdentityHash,0);
	ClearA4SWatchRootTable();
	m_A4SItemReadyEvent=CreateEvent(NULL,FALSE,FALSE,NULL);
	m_A4SFolderWatchReadyEvent=CreateEvent(NULL,TRUE,FALSE,NULL);
	m_A4SWatchRebuildEvent=CreateEvent(NULL,FALSE,FALSE,NULL);
#endif

#ifdef A4S_PRODUCT
	if (!m_StartEvent || !m_WorkEvent || !m_ExitEvent || !m_DoneEvent ||
		!m_A4SItemReadyEvent || !m_A4SFolderWatchReadyEvent ||
		!m_A4SWatchRebuildEvent)
	{
		Close();
		return false;
	}
#endif

	m_PreloadItemsThread=CreateThread(NULL,0,StaticPreloadItemsThread,this,0,&m_PreloadItemsThreadId);
	m_RefreshInfoThread=CreateThread(NULL,0,StaticRefreshInfoThread,this,0,&m_RefreshInfoThreadId);

#ifdef A4S_PRODUCT
	if (!m_PreloadItemsThread || !m_RefreshInfoThread)
	{
		Close();
		return false;
	}
#endif

	LoadOldItems();

	return true;
}

bool CItemManager::Close( void )
{
	if (!m_bInitialized) return true;

	m_LoadingStage=LOAD_STOPPING;
	if (m_ExitEvent)
		SetEvent(m_ExitEvent);
#ifdef A4S_PRODUCT
	if (m_A4SItemReadyEvent)
		SetEvent(m_A4SItemReadyEvent);
#endif
#ifdef A4S_PRODUCT
	const DWORD closeBudget=1500;
	const DWORD closeStart=GetTickCount();
	HANDLE threads[]={m_PreloadItemsThread,m_RefreshInfoThread,m_SaveCacheThread};
	for (int i=0;i<_countof(threads);i++)
	{
		if (!threads[i])
			continue;
		const DWORD elapsed=GetTickCount()-closeStart;
		const DWORD remaining=elapsed<closeBudget?closeBudget-elapsed:0;
		if (WaitForSingleObject(threads[i],remaining)!=WAIT_OBJECT_0)
			return false;
	}
#endif
	if (m_PreloadItemsThread)
	{
#ifndef A4S_PRODUCT
		WaitForSingleObject(m_PreloadItemsThread,INFINITE);
#endif
		CloseHandle(m_PreloadItemsThread);
		m_PreloadItemsThread=NULL;
	}
	if (m_RefreshInfoThread)
	{
#ifndef A4S_PRODUCT
		WaitForSingleObject(m_RefreshInfoThread,INFINITE);
#endif
		CloseHandle(m_RefreshInfoThread);
		m_RefreshInfoThread=NULL;
	}
	if (m_SaveCacheThread)
	{
#ifndef A4S_PRODUCT
		WaitForSingleObject(m_SaveCacheThread,INFINITE);
#endif
		CloseHandle(m_SaveCacheThread);
		m_SaveCacheThread=NULL;
	}
	m_LoadingStage=LOAD_STOPPED;

	for (std::multimap<unsigned int,IconInfo>::const_iterator it=m_IconInfos.begin();it!=m_IconInfos.end();++it)
	{
		if (it->second.bitmap)
			DeleteObject(it->second.bitmap);
	}

	for (int i=0;i<LOCK_COUNT;i++)
		DeleteCriticalSection(&m_CriticalSections[i]);
	g_pAppResolver=NULL;
	if (m_StartEvent) CloseHandle(m_StartEvent);
	if (m_WorkEvent) CloseHandle(m_WorkEvent);
	if (m_ExitEvent) CloseHandle(m_ExitEvent);
	if (m_DoneEvent) CloseHandle(m_DoneEvent);
	m_StartEvent=m_WorkEvent=m_ExitEvent=m_DoneEvent=NULL;
#ifdef A4S_PRODUCT
	if (m_A4SItemReadyEvent) CloseHandle(m_A4SItemReadyEvent);
	if (m_A4SFolderWatchReadyEvent) CloseHandle(m_A4SFolderWatchReadyEvent);
	if (m_A4SWatchRebuildEvent) CloseHandle(m_A4SWatchRebuildEvent);
	m_A4SItemReadyEvent=NULL;
	m_A4SFolderWatchReadyEvent=NULL;
	m_A4SWatchRebuildEvent=NULL;
#endif
	m_LoadIconData[0].Close();
	m_bInitialized=false;
	return true;
}

void CItemManager::CreateDefaultIcons( void )
{
	SHFILEINFO info;
	int index;
	if (SHGetFileInfo(L"file",FILE_ATTRIBUTE_NORMAL,&info,sizeof(info),SHGFI_USEFILEATTRIBUTES|SHGFI_SYSICONINDEX))
		index=info.iIcon;
	else
		index=-1;
	IconInfo icon;
	icon.bTemp=false;
	icon.bMetro=false;
	icon.timestamp.dwLowDateTime=icon.timestamp.dwHighDateTime=0;
	icon.sizeType=ICON_SIZE_TYPE_SMALL;
	if (index>=0)
		icon.bitmap=BitmapFromIcon(LoadShellIcon(index,SMALL_ICON_SIZE),SMALL_ICON_SIZE);
	else
		icon.bitmap=NULL;
	m_DefaultSmallIcon=&m_IconInfos.emplace(0,icon)->second;

	icon.sizeType=ICON_SIZE_TYPE_LARGE;
	if (index>=0)
		icon.bitmap=BitmapFromIcon(LoadShellIcon(index,LARGE_ICON_SIZE),LARGE_ICON_SIZE);
	else
		icon.bitmap=NULL;
	m_DefaultLargeIcon=&m_IconInfos.emplace(0,icon)->second;

	icon.sizeType=ICON_SIZE_TYPE_EXTRA_LARGE;
	if (index>=0)
		icon.bitmap=BitmapFromIcon(LoadShellIcon(index,EXTRA_LARGE_ICON_SIZE),EXTRA_LARGE_ICON_SIZE);
	else
		icon.bitmap=NULL;
	m_DefaultExtraLargeIcon=&m_IconInfos.emplace(0,icon)->second;
}

CItemManager::LoadIconData &CItemManager::GetLoadIconData( void )
{
	DWORD thread=GetCurrentThreadId();
	if (thread==m_RefreshInfoThreadId)
		return m_LoadIconData[2];
	if (thread==m_PreloadItemsThreadId)
		return m_LoadIconData[1];
	Assert(thread==m_MainThreadId);
	return m_LoadIconData[0];
}

void CItemManager::ResetTempIcons( void )
{
	Assert(GetCurrentThreadId()==m_MainThreadId);
	Lock cleanupLock(this,LOCK_CLEANUP);
	RWLock itemLock(this,true,RWLOCK_ITEMS);
	RWLock iconLock(this,true,RWLOCK_ICONS);
	bool bCacheInvalidated=false;

	COLORREF sysColor=GetSystemAccentColor();
	bool bResetMetro=m_OldSysAccentColor!=sysColor;
	m_OldSysAccentColor=sysColor;

	g_bInvertMetroIcons=GetSettingBool(L"InvertMetroIcons");
	if (m_bOldInvertIcons!=g_bInvertMetroIcons)
		bResetMetro=true;
	m_bOldInvertIcons=g_bInvertMetroIcons;

	if (bResetMetro)
	{
		for (std::map<unsigned int,const ItemInfo*>::iterator it=m_MetroItemInfos10.begin();it!=m_MetroItemInfos10.end();)
		{
			std::map<unsigned int,const ItemInfo*>::iterator next=it; ++next;
			if (it->second && !it->second->packagePath.IsEmpty())
			{
				ItemInfo *pInfo=const_cast<ItemInfo*>(it->second);
				pInfo->validFlags&=~(INFO_ICON|INFO_METRO);
#ifdef A4S_PRODUCT
				pInfo->a4sResolvedIconFlags&=~INFO_ICON;
#endif
				m_MetroItemInfos10.erase(it);
				bCacheInvalidated=true;
			}
			it=next;
		}
	}
	{
		// remove temp items from the queue
		std::list<ItemInfo*>::iterator it=m_ItemQueue.begin();
		while (it!=m_ItemQueue.end())
		{
			std::list<ItemInfo*>::iterator next=it; ++next;
			if ((*it)->bTemp)
			{
				Assert(!(*it)->largeIcon && !(*it)->extraLargeIcon && ((*it)->smallIcon==m_DefaultSmallIcon || (*it)->smallIcon->bTemp));
				m_ItemQueue.erase(it);
				bCacheInvalidated=true;
			}
			it=next;
		}
	}

	int metroFlags=bResetMetro?INFO_METRO:0;
	{
		// remove temp items from the cache
		std::multimap<unsigned int,ItemInfo>::iterator it=m_ItemInfos.begin();
		while (it!=m_ItemInfos.end())
		{
			std::multimap<unsigned int,ItemInfo>::iterator next=it; ++next;
			if (it->second.bTemp)
			{
				Assert(it->second.largeIcon==m_DefaultLargeIcon && it->second.extraLargeIcon==m_DefaultExtraLargeIcon && (it->second.smallIcon==m_DefaultSmallIcon || it->second.smallIcon->bTemp));
				m_ItemInfos.erase(it);
				bCacheInvalidated=true;
			}
			else
			{
				if (it->second.smallIcon && (it->second.smallIcon->bTemp || (it->second.smallIcon->bMetro && bResetMetro)))
				{
					it->second.smallIcon=m_DefaultSmallIcon;
					it->second.validFlags&=~(INFO_SMALL_ICON|metroFlags);
#ifdef A4S_PRODUCT
					it->second.a4sResolvedIconFlags&=~INFO_SMALL_ICON;
#endif
					bCacheInvalidated=true;
				}
				if (it->second.largeIcon && (it->second.largeIcon->bTemp || (it->second.largeIcon->bMetro && bResetMetro)))
				{
					it->second.largeIcon=m_DefaultLargeIcon;
					it->second.validFlags&=~(INFO_LARGE_ICON|metroFlags);
#ifdef A4S_PRODUCT
					it->second.a4sResolvedIconFlags&=~INFO_LARGE_ICON;
#endif
					bCacheInvalidated=true;
				}
				if (it->second.extraLargeIcon && (it->second.extraLargeIcon->bTemp || (it->second.extraLargeIcon->bMetro && bResetMetro)))
				{
					it->second.extraLargeIcon=m_DefaultExtraLargeIcon;
					it->second.validFlags&=~(INFO_EXTRA_LARGE_ICON|metroFlags);
#ifdef A4S_PRODUCT
					it->second.a4sResolvedIconFlags&=~INFO_EXTRA_LARGE_ICON;
#endif
					bCacheInvalidated=true;
				}
#ifdef A4S_PRODUCT
				// A terminal fallback has no Metro IconInfo to match. Accent or
				// inversion changes must still make that Metro result resolvable again.
				if (bResetMetro && (it->second.bMetroLink || it->second.bMetroApp ||
					!it->second.packagePath.IsEmpty()) && it->second.a4sResolvedIconFlags)
				{
					it->second.a4sResolvedIconFlags&=~INFO_ICON;
					bCacheInvalidated=true;
				}
#endif
			}
			it=next;
		}
	}

	{
		// remove temp icons
		std::multimap<unsigned int,IconInfo>::iterator it=m_IconInfos.begin();
		while (it!=m_IconInfos.end())
		{
			std::multimap<unsigned int,IconInfo>::iterator next=it; ++next;
			if (it->second.bTemp || (it->second.bMetro && bResetMetro))
			{
				if (it->second.bitmap)
					DeleteObject(it->second.bitmap);
				m_IconInfos.erase(it);
				bCacheInvalidated=true;
			}
			it=next;
		}
	}

	{
		// delete old bitmaps
		for (std::vector<HBITMAP>::iterator it=m_OldBitmaps.begin();it!=m_OldBitmaps.end();++it)
			DeleteObject(*it);
		m_OldBitmaps.clear();
	}
	if (m_TransientHash!=1)
		bCacheInvalidated=true;
	m_TransientHash=1;
#ifdef A4S_PRODUCT
	// ResetTempIcons runs on every toggle. Preserve warm cache identity unless
	// this pass actually removed or invalidated icon/Metro/temp state.
	if (bCacheInvalidated)
		AdvanceIconCacheEpoch();
#endif
}

static bool ComparePidls( PIDLIST_ABSOLUTE pidl1, PIDLIST_ABSOLUTE pidl2 )
{
	if (!pidl1 && !pidl2) return true;
	if (!pidl1 || !pidl2) return false;
	int size1=ILGetSize(pidl1);
	int size2=ILGetSize(pidl2);
	if (size1!=size2) return false;
	return memcmp(pidl1,pidl2,size1)==0;
}

#ifdef A4S_PRODUCT
bool CItemManager::TryGetCachedFileMetadata( unsigned int hash, const CString &PATH, int refreshFlags, FILETIME &writeTime, FILETIME &createTime )
{
	const ULONGLONG pathGeneration=GetA4SPathIdentityGeneration();
	A4SCacheState::CachedMetadataAdmissionState admission={};
	admission.mainThread=GetCurrentThreadId()==m_MainThreadId;
	admission.pathPresent=!PATH.IsEmpty();
	admission.forceValidation=
		(refreshFlags&(INFO_VALIDATE_FILE|INFO_REFRESH_NOW))!=0;
	admission.watchBaselineReady=IsFolderWatchBaselineReady();
	admission.currentPathGeneration=pathGeneration;
	if (!admission.mainThread || !admission.pathPresent ||
		admission.forceValidation || !admission.watchBaselineReady)
		return false;

	const int requiredFlags=refreshFlags&(INFO_DATA|INFO_ICON);
	RWLock lock(this,false,RWLOCK_ITEMS);
	std::multimap<unsigned int,ItemInfo>::const_iterator it=m_ItemInfos.find(hash);
	for (;it!=m_ItemInfos.end() && it->first==hash;++it)
	{
		const ItemInfo &info=it->second;
		if (wcscmp(PATH,info.PATH)!=0)
			continue;

		admission.entryStable=!info.bTemp && !info.refreshFlags && !info.newPidl;
		A4SWatchRootBinding currentBinding={};
		const bool bMapped=!info.a4sCanonicalPath.IsEmpty() &&
			ResolveA4SItemWatchBinding(info.a4sCanonicalPath,currentBinding);
		A4SCacheState::WatchBindingIdentity validated={
			info.a4sWatchRootBit,info.a4sWatchRootIdentity,
			info.a4sPathIdentityGeneration,info.a4sWatchSourceGeneration};
		A4SCacheState::WatchBindingIdentity current={
			currentBinding.watchBit,currentBinding.rootIdentity,
			currentBinding.identityGeneration,currentBinding.sourceGeneration};
		admission.pathCoveredByWatchIdentity=bMapped &&
			info.packagePath.IsEmpty() &&
			A4SCacheState::WatchBindingMatches(validated,current);
		admission.requestedFlagsComplete=
			(info.validFlags&requiredFlags)==requiredFlags;
		admission.validatedPathGeneration=info.a4sPathIdentityGeneration;
		if (!A4SCacheState::CanUseCachedFileMetadata(admission))
			return false;

		writeTime=info.writestamp;
		createTime=info.createstamp;
		// Recheck both moving admission barriers after copying the timestamps.
		// Reconfiguration revokes readiness and advances the identity generation,
		// so a race always falls back to real filesystem validation.
		return IsFolderWatchBaselineReady() &&
			GetA4SPathIdentityGeneration()==pathGeneration;
	}
	return false;
}
#endif

const CItemManager::ItemInfo *CItemManager::GetItemInfo( IShellItem *pItem, PIDLIST_ABSOLUTE pidl, int refreshFlags, TLocation location )
{
	Assert(!RWLock::ThreadHasReadLock(RWLOCK_ITEMS));
#ifdef A4S_PRODUCT
	const UINT32 requestedIconFlags=static_cast<UINT32>(refreshFlags&INFO_ICON);
#endif
	if ((refreshFlags&INFO_METRO) && GetWinVersion()<WIN_VER_WIN8)
		refreshFlags&=~INFO_METRO;
	CComString pName;
	if (refreshFlags&INFO_NO_PATH)
		refreshFlags&=~INFO_NO_PATH;
	else
		pItem->GetDisplayName(SIGDN_DESKTOPABSOLUTEPARSING,&pName);

	CString path, PATH;
	unsigned int hash;
	if (pName)
	{
		path=pName;
		PATH=path;
		StringUpper(PATH);
		hash=CalcFNVHash(PATH);
	}
	else
	{
		hash=CalcFNVHash(pidl,ILGetSize(pidl));
	}

	FILETIME writeTime={0}, createTime={0};
#ifdef A4S_PRODUCT
	bool bA4SFileMetadataValidated=false;
	CString a4sCanonicalPath;
	A4SWatchRootBinding a4sValidatedBinding={};
	const bool bUseCachedFileMetadata=TryGetCachedFileMetadata(hash,PATH,refreshFlags,writeTime,createTime);
#endif
	if (!path.IsEmpty())
	{
#ifdef A4S_PRODUCT
		if (!bUseCachedFileMetadata &&
			!GetA4SFileMetadataAndBinding(path,writeTime,createTime,
				a4sCanonicalPath,a4sValidatedBinding))
#else
		if (!MenuGetFileTimestamp(path,&writeTime,&createTime))
#endif
		{
			if (refreshFlags&INFO_VALIDATE_FILE)
				return NULL;
			path.Empty();
		}
#ifdef A4S_PRODUCT
		else if (!bUseCachedFileMetadata)
			bA4SFileMetadataValidated=true;
#endif
	}

	bool bDelay=GetSettingBool(L"DelayIcons");
	ItemInfo *pInfo=NULL;
	{
		RWLock lock(this,true,RWLOCK_ITEMS);
		std::multimap<unsigned int,ItemInfo>::iterator it=m_ItemInfos.find(hash);
		for (;it!=m_ItemInfos.end() && it->first==hash;++it)
		{
			if ((!PATH.IsEmpty() && wcscmp(PATH,it->second.PATH)==0) || (PATH.IsEmpty() && ILIsEqual(pidl,it->second.GetPidl())))
			{
				pInfo=&it->second;
				break;
			}
		}
		if (!pInfo)
		{
			pInfo=&m_ItemInfos.emplace(hash,ItemInfo())->second;
			pInfo->pidl.Clone(pidl);
			pInfo->path=path;
			pInfo->PATH=PATH;
			pInfo->createstamp=createTime;
			pInfo->writestamp=writeTime;
			pInfo->smallIcon=m_DefaultSmallIcon;
			pInfo->largeIcon=m_DefaultLargeIcon;
			pInfo->extraLargeIcon=m_DefaultExtraLargeIcon;
			pInfo->validFlags=0;
#ifdef A4S_PRODUCT
			const bool bBindingCurrent=bA4SFileMetadataValidated &&
				a4sValidatedBinding.watchBit &&
				IsA4SItemWatchBindingCurrent(a4sCanonicalPath,
					a4sValidatedBinding);
			pInfo->a4sPathIdentityGeneration=bBindingCurrent?
				a4sValidatedBinding.identityGeneration:0;
			pInfo->a4sWatchRootBit=bBindingCurrent?
				a4sValidatedBinding.watchBit:0;
			pInfo->a4sWatchRootIdentity=bBindingCurrent?
				a4sValidatedBinding.rootIdentity:0;
			pInfo->a4sWatchSourceGeneration=bBindingCurrent?
				a4sValidatedBinding.sourceGeneration:0;
			pInfo->a4sCanonicalPath=bBindingCurrent?a4sCanonicalPath:CString();
#endif
		}
		else
		{
#ifdef A4S_PRODUCT
			if (!bUseCachedFileMetadata && !pInfo->packagePath.IsEmpty())
#else
			if (!pInfo->packagePath.IsEmpty())
#endif
			{
				if (!MenuGetFileTimestamp(pInfo->packagePath,&writeTime,&createTime))
				{
#ifdef A4S_PRODUCT
					bA4SFileMetadataValidated=false;
#endif
				}
			}
			if (CompareFileTime(&pInfo->writestamp,&writeTime)!=0)
			{
				if (!PATH.IsEmpty() && !ComparePidls(pInfo->pidl,pidl) && !ComparePidls(pInfo->newPidl,pidl))
				{
					pInfo->newPidl.Clone(pidl);
#ifdef A4S_PRODUCT
					InterlockedExchange(&m_PendingPidlRefresh,1);
#endif
				}
				pInfo->writestamp=writeTime;
				pInfo->validFlags=0;
			}
#ifdef A4S_PRODUCT
			if (!bUseCachedFileMetadata)
			{
				const bool bBindingCurrent=bA4SFileMetadataValidated &&
					pInfo->packagePath.IsEmpty() &&
					a4sValidatedBinding.watchBit &&
					IsA4SItemWatchBindingCurrent(a4sCanonicalPath,
						a4sValidatedBinding);
				pInfo->a4sPathIdentityGeneration=bBindingCurrent?
					a4sValidatedBinding.identityGeneration:0;
				pInfo->a4sWatchRootBit=bBindingCurrent?
					a4sValidatedBinding.watchBit:0;
				pInfo->a4sWatchRootIdentity=bBindingCurrent?
					a4sValidatedBinding.rootIdentity:0;
				pInfo->a4sWatchSourceGeneration=bBindingCurrent?
					a4sValidatedBinding.sourceGeneration:0;
				pInfo->a4sCanonicalPath=bBindingCurrent?a4sCanonicalPath:CString();
			}
#endif
		}
		if (pInfo->location==LOCATION_UNKNOWN && !pInfo->PATH.IsEmpty())
		{
			if (location!=LOCATION_UNKNOWN)
				pInfo->location=location;
			else
				pInfo->location=DetermineLocation(pInfo->PATH);
		}
		refreshFlags&=~pInfo->validFlags;
	}
#ifdef A4S_PRODUCT
	if (requestedIconFlags && !(refreshFlags&INFO_ICON))
	{
		A4SPerformanceScope iconCacheScope(A4S_PERF_ICON_LOAD,requestedIconFlags);
		iconCacheScope.SetResult(requestedIconFlags,TRUE);
	}
#endif

	if (refreshFlags)
	{
		int refreshMask=bDelay?INFO_DATA:(INFO_DATA|INFO_ICON);
		if (refreshFlags&refreshMask)
			RefreshItemInfo(pInfo,refreshFlags&refreshMask,pItem,false);
		refreshFlags&=~refreshMask;
		if (refreshFlags)
		{
			RWLock lock(this,true,RWLOCK_ITEMS);
			QueueItemInfo(pInfo,refreshFlags);
		}
	}

	return pInfo;
}

const CItemManager::ItemInfo *CItemManager::GetItemInfo( CString path, int refreshFlags, TLocation location )
{
	Assert(!RWLock::ThreadHasReadLock(RWLOCK_ITEMS));
	Assert(!path.IsEmpty());
#ifdef A4S_PRODUCT
	const UINT32 requestedIconFlags=static_cast<UINT32>(refreshFlags&INFO_ICON);
#endif
	if ((refreshFlags&INFO_METRO) && GetWinVersion()<WIN_VER_WIN8)
		refreshFlags&=~INFO_METRO;
	CString PATH=path;
	StringUpper(PATH);
	unsigned int hash=CalcFNVHash(PATH);

	FILETIME writeTime={0}, createTime={0};
#ifdef A4S_PRODUCT
	bool bA4SFileMetadataValidated=false;
	CString a4sCanonicalPath;
	A4SWatchRootBinding a4sValidatedBinding={};
	const bool bUseCachedFileMetadata=TryGetCachedFileMetadata(hash,PATH,refreshFlags,writeTime,createTime);
	if (!bUseCachedFileMetadata &&
		!GetA4SFileMetadataAndBinding(path,writeTime,createTime,
			a4sCanonicalPath,a4sValidatedBinding))
#else
	if (!MenuGetFileTimestamp(path,&writeTime,&createTime))
#endif
	{
		if (refreshFlags&INFO_VALIDATE_FILE)
			return NULL;
		path.Empty();
	}
#ifdef A4S_PRODUCT
	else if (!bUseCachedFileMetadata)
		bA4SFileMetadataValidated=true;
#endif

	bool bDelay=GetSettingBool(L"DelayIcons");
	ItemInfo *pInfo=NULL;
	{
		RWLock lock(this,true,RWLOCK_ITEMS);
		std::multimap<unsigned int,ItemInfo>::iterator it=m_ItemInfos.find(hash);
		for (;it!=m_ItemInfos.end() && it->first==hash;++it)
		{
			if (wcscmp(PATH,it->second.PATH)==0)
			{
				pInfo=&it->second;
				break;
			}
		}
		if (!pInfo)
		{
			pInfo=&m_ItemInfos.emplace(hash,ItemInfo())->second;
			if (!PATH.IsEmpty())
				MenuParseDisplayName(path,&pInfo->pidl,NULL,NULL);
			if (pInfo->pidl)
				pInfo->path=path;
			pInfo->PATH=PATH;
			pInfo->createstamp=createTime;
			pInfo->writestamp=writeTime;
			pInfo->smallIcon=m_DefaultSmallIcon;
			pInfo->largeIcon=m_DefaultLargeIcon;
			pInfo->extraLargeIcon=m_DefaultExtraLargeIcon;
			pInfo->validFlags=0;
#ifdef A4S_PRODUCT
			const bool bBindingCurrent=bA4SFileMetadataValidated &&
				a4sValidatedBinding.watchBit &&
				IsA4SItemWatchBindingCurrent(a4sCanonicalPath,
					a4sValidatedBinding);
			pInfo->a4sPathIdentityGeneration=bBindingCurrent?
				a4sValidatedBinding.identityGeneration:0;
			pInfo->a4sWatchRootBit=bBindingCurrent?
				a4sValidatedBinding.watchBit:0;
			pInfo->a4sWatchRootIdentity=bBindingCurrent?
				a4sValidatedBinding.rootIdentity:0;
			pInfo->a4sWatchSourceGeneration=bBindingCurrent?
				a4sValidatedBinding.sourceGeneration:0;
			pInfo->a4sCanonicalPath=bBindingCurrent?a4sCanonicalPath:CString();
#endif
		}
		else
		{
#ifdef A4S_PRODUCT
			if (!bUseCachedFileMetadata && !pInfo->packagePath.IsEmpty())
#else
			if (!pInfo->packagePath.IsEmpty())
#endif
			{
				if (!MenuGetFileTimestamp(pInfo->packagePath,&writeTime,&createTime))
				{
#ifdef A4S_PRODUCT
					bA4SFileMetadataValidated=false;
#endif
				}
			}
			if (CompareFileTime(&pInfo->writestamp,&writeTime)!=0)
			{
				CAbsolutePidl pidl;
				if (!PATH.IsEmpty())
					MenuParseDisplayName(PATH,&pidl,NULL,NULL);
				if (!ComparePidls(pInfo->pidl,pidl) && !ComparePidls(pInfo->newPidl,pidl))
				{
					pInfo->newPidl.Swap(pidl);
#ifdef A4S_PRODUCT
					InterlockedExchange(&m_PendingPidlRefresh,1);
#endif
				}
				pInfo->writestamp=writeTime;
				pInfo->validFlags=0;
			}
#ifdef A4S_PRODUCT
			if (!bUseCachedFileMetadata)
			{
				const bool bBindingCurrent=bA4SFileMetadataValidated &&
					pInfo->packagePath.IsEmpty() &&
					a4sValidatedBinding.watchBit &&
					IsA4SItemWatchBindingCurrent(a4sCanonicalPath,
						a4sValidatedBinding);
				pInfo->a4sPathIdentityGeneration=bBindingCurrent?
					a4sValidatedBinding.identityGeneration:0;
				pInfo->a4sWatchRootBit=bBindingCurrent?
					a4sValidatedBinding.watchBit:0;
				pInfo->a4sWatchRootIdentity=bBindingCurrent?
					a4sValidatedBinding.rootIdentity:0;
				pInfo->a4sWatchSourceGeneration=bBindingCurrent?
					a4sValidatedBinding.sourceGeneration:0;
				pInfo->a4sCanonicalPath=bBindingCurrent?a4sCanonicalPath:CString();
			}
#endif
		}
		if (pInfo->location==LOCATION_UNKNOWN && !pInfo->PATH.IsEmpty())
		{
			if (location!=LOCATION_UNKNOWN)
				pInfo->location=location;
			else
				pInfo->location=DetermineLocation(pInfo->PATH);
		}
		refreshFlags&=~pInfo->validFlags;
	}
#ifdef A4S_PRODUCT
	if (requestedIconFlags && !(refreshFlags&INFO_ICON))
	{
		A4SPerformanceScope iconCacheScope(A4S_PERF_ICON_LOAD,requestedIconFlags);
		iconCacheScope.SetResult(requestedIconFlags,TRUE);
	}
#endif

	if (refreshFlags)
	{
		int refreshMask=bDelay?INFO_DATA:(INFO_DATA|INFO_ICON);
		if (refreshFlags&refreshMask)
			RefreshItemInfo(pInfo,refreshFlags&refreshMask,NULL,false);
		refreshFlags&=~refreshMask;
		if (refreshFlags)
		{
			RWLock lock(this,true,RWLOCK_ITEMS);
			QueueItemInfo(pInfo,refreshFlags);
		}
	}

	return pInfo;
}

void CItemManager::UpdateItemInfo( const ItemInfo *pInfo, int refreshFlags, bool bHasWriteLock )
{
	if (bHasWriteLock)
	{
		Assert(RWLock::ThreadHasWriteLock(RWLOCK_ITEMS));
	}
	else
	{
		Assert(!RWLock::ThreadHasReadLock(RWLOCK_ITEMS));
	}
	refreshFlags&=~pInfo->validFlags; // potentially out of lock, assuming validFlags is atomic
	if (refreshFlags)
	{
		RWLock lock(this,true,bHasWriteLock?RWLOCK_COUNT:RWLOCK_ITEMS);
		if ((refreshFlags&INFO_ICON) && !(refreshFlags&INFO_REFRESH_NOW) && GetSettingBool(L"DelayIcons"))
		{
			QueueItemInfo(const_cast<ItemInfo*>(pInfo),refreshFlags&INFO_ICON);
			refreshFlags&=~INFO_ICON;
		}
		if (refreshFlags)
			RefreshItemInfo(const_cast<ItemInfo*>(pInfo),refreshFlags,NULL,true);
	}
}

const CItemManager::ItemInfo *CItemManager::GetCustomIcon( const wchar_t *location, int index, TIconSizeType iconSizeType, bool bTemp )
{
	return GetCustomIconInternal(location,index,iconSizeType,bTemp,false);
}

const CItemManager::ItemInfo *CItemManager::GetCustomIconInternal( const wchar_t *location,
	int index, TIconSizeType iconSizeType, bool bTemp, bool bForceAsync )
{
	Assert(!RWLock::ThreadHasReadLock(RWLOCK_ITEMS));
	unsigned int hash=CalcFNVHash(location,CalcFNVHash(&index,4));
	ItemInfo *pInfo=NULL;
	bool bDelay=bForceAsync || GetSettingBool(L"DelayIcons");
	int refreshFlags=0;
	{
		RWLock lock(this,true,RWLOCK_ITEMS);
		std::multimap<unsigned int,ItemInfo>::iterator it=m_ItemInfos.find(hash);
		for (;it!=m_ItemInfos.end() && it->first==hash;++it)
		{
			if (it->second.bIconOnly && it->second.bTemp==bTemp)
			{
				pInfo=&it->second;
				break;
			}
		}
		if (!pInfo)
		{
			pInfo=&m_ItemInfos.emplace(hash,ItemInfo())->second;
			pInfo->bIconOnly=true;
			pInfo->bTemp=bTemp;
			pInfo->iconPath=location;
			pInfo->iconIndex=index;
			pInfo->smallIcon=m_DefaultSmallIcon;
			pInfo->largeIcon=m_DefaultLargeIcon;
			pInfo->extraLargeIcon=m_DefaultExtraLargeIcon;
		}

		if (iconSizeType==ICON_SIZE_TYPE_SMALL) refreshFlags|=INFO_SMALL_ICON;
		if (iconSizeType==ICON_SIZE_TYPE_LARGE) refreshFlags|=INFO_LARGE_ICON;
		if (iconSizeType==ICON_SIZE_TYPE_EXTRA_LARGE) refreshFlags|=INFO_EXTRA_LARGE_ICON;
		refreshFlags&=~pInfo->validFlags;

		if (refreshFlags && bDelay)
		{
			QueueItemInfo(pInfo,refreshFlags);
			refreshFlags=0;
		}
	}
	if (!bDelay && refreshFlags)
	{
		RefreshItemInfo(pInfo,refreshFlags,NULL,false);
	}
	return pInfo;
}

const CItemManager::ItemInfo *CItemManager::GetCustomIcon( const wchar_t *path, TIconSizeType iconSizeType )
{
	Assert(!RWLock::ThreadHasReadLock(RWLOCK_ITEMS));
	if (!path)
	{
		RWLock lock(this,false,RWLOCK_ITEMS);
		return &m_ItemInfos.find(0)->second;
	}
	wchar_t text[1024];
	Strcpy(text,_countof(text),path);
	DoEnvironmentSubst(text,_countof(text));
	wchar_t *c=wcsrchr(text,',');
	int index=0;
	if (c)
	{
		*c=0;
		index=-_wtol(c+1);
	}
	// special handling for Apps icon
	if (!text[0] && index==-IDI_APPSICON)
	{
		if (IsWin11())
			index=-IDI_APPSICON11;
		else if (GetWinVersion()==WIN_VER_WIN10)
			index=-IDI_APPSICON10;
	}
	return GetCustomIcon(text,index,iconSizeType,false);
}

#ifdef A4S_PRODUCT
const CItemManager::ItemInfo *CItemManager::GetA4SCustomIcon( const wchar_t *path,
	TIconSizeType iconSizeType )
{
	Assert(!RWLock::ThreadHasReadLock(RWLOCK_ITEMS));
	wchar_t text[1024];
	Strcpy(text,_countof(text),path);
	DoEnvironmentSubst(text,_countof(text));
	wchar_t *c=wcsrchr(text,',');
	int index=0;
	if (c)
	{
		*c=0;
		index=-_wtol(c+1);
	}
	if (!text[0] && index==-IDI_APPSICON)
	{
		if (IsWin11())
			index=-IDI_APPSICON11;
		else if (GetWinVersion()==WIN_VER_WIN10)
			index=-IDI_APPSICON10;
	}
	return GetCustomIconInternal(text,index,iconSizeType,false,true);
}
#endif

const CItemManager::ItemInfo* CItemManager::GetLinkIcon(IShellLink* link, TIconSizeType iconSizeType)
{
	wchar_t location[_MAX_PATH];
	int index;

	if (link->GetIconLocation(location, _countof(location), &index) == S_OK && location[0])
		return GetCustomIcon(location, index, iconSizeType, (index == 0)); // assuming that if index!=0 the icon comes from a permanent location like a dll or exe

	CComQIPtr<IPropertyStore> store(link);
	if (store)
	{
		//  Name:     System.AppUserModel.DestListLogoUri -- PKEY_AppUserModel_DestListLogoUri
		//  Type:     String -- VT_LPWSTR
		//  FormatID: {9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3}, 29
		static const PROPERTYKEY PKEY_AppUserModel_DestListLogoUri = { {0x9F4C2855, 0x9F79, 0x4B39, {0xA8, 0xD0, 0xE1, 0xD4, 0x2D, 0xE1, 0xD5, 0xF3}}, 29 };

		auto logoUri = GetPropertyStoreString(store, PKEY_AppUserModel_DestListLogoUri);
		if (!logoUri.IsEmpty())
		{
			auto appId = GetPropertyStoreString(store, PKEY_AppUserModel_ID);
			if (!appId.IsEmpty())
			{
				CComPtr<IResourceManager> resManager;
				if (SUCCEEDED(resManager.CoCreateInstance(CLSID_ResourceManager)))
				{
					if (SUCCEEDED(resManager->InitializeForPackage(GetPackageFullName(appId))))
					{
						CComPtr<IResourceMap> resMap;
						if (SUCCEEDED(resManager->GetMainResourceMap(IID_PPV_ARGS(&resMap))))
						{
							CComPtr<IResourceContext> resContext;
							if (SUCCEEDED(resManager->GetDefaultContext(IID_PPV_ARGS(&resContext))))
								resContext->SetTargetSize(GetIconSize(iconSizeType));

							CComString location;
							if (SUCCEEDED(resMap->GetFilePath(logoUri, &location)))
								return GetCustomIcon(location, -65536, iconSizeType, true);
						}
					}
				}
			}
		}
	}

	return nullptr;
}

const CItemManager::ItemInfo *CItemManager::GetMetroAppInfo10( const wchar_t *appid )
{
	wchar_t APPID[256];
	Strcpy(APPID,_countof(APPID),appid);
	CharUpper(APPID);
	if (APPID[0]=='\\' || APPID[0]=='{' || APPID[1]==':' || wcsstr(APPID,L".AUTOGENERATED."))
		return NULL; // attempt to recognize appids that are for sure not Metro
	unsigned int hash=CalcFNVHash(APPID);
	const ItemInfo *pInfo=NULL;
	{
		RWLock lock(this,false,RWLOCK_ITEMS);
		// the key is a hash of the uppercase appid
		std::map<unsigned int,const ItemInfo*>::const_iterator it=m_MetroItemInfos10.find(hash);
		if (it!=m_MetroItemInfos10.end())
			pInfo=it->second;
		else if (m_BlackListInfos10.find(hash)!=m_BlackListInfos10.end())
			return NULL;
	}
	if (pInfo)
	{
		UpdateItemInfo(pInfo,INFO_LINK|INFO_METRO);
		return pInfo;
	}

	CComPtr<IShellItem> pItem;
	if (SUCCEEDED(SHCreateItemInKnownFolder(FOLDERID_AppsFolder2,0,appid,IID_IShellItem,(void**)&pItem)))
	{
		CAbsolutePidl pidl;
		if (SUCCEEDED(SHGetIDListFromObject(pItem,&pidl)))
			pInfo=GetItemInfo(pItem,pidl,INFO_LINK|INFO_METRO,LOCATION_METRO);
	}

	{
		RWLock lock(this,true,RWLOCK_ITEMS);
		std::map<unsigned int,const ItemInfo*>::const_iterator it=m_MetroItemInfos10.find(hash);
		if (it!=m_MetroItemInfos10.end() && it->second)
			return it->second;
		else
		{
			if (!pInfo)
				m_BlackListInfos10.insert(hash);
			if (pInfo && !pInfo->IsMetroApp())
				pInfo=NULL;
			m_MetroItemInfos10[hash]=pInfo;
			return pInfo;
		}
	}
}

// requires LOCK_ITEMS to be held
void CItemManager::QueueItemInfo( ItemInfo *pInfo, int refreshFlags )
{
	Assert(RWLock::ThreadHasWriteLock(RWLOCK_ITEMS));
	DWORD thread=GetCurrentThreadId();
	Assert(thread!=m_RefreshInfoThreadId);
	pInfo->refreshFlags|=refreshFlags&~pInfo->validFlags&(INFO_DATA|INFO_ICON);
	if (pInfo->refreshFlags)
	{
		std::list<ItemInfo*> &queue=(thread==m_PreloadItemsThreadId)?m_ItemQueueLow:m_ItemQueue;
		for (std::list<ItemInfo*>::const_iterator it=queue.begin();it!=queue.end();++it)
		{
			if (*it==pInfo)
				return;
		}
		queue.push_back(pInfo);
		SetEvent(m_WorkEvent);
		if (thread!=m_PreloadItemsThreadId)
			SetEvent(m_StartEvent);
	}
}

#ifdef A4S_PRODUCT
bool CItemManager::QueueA4SItemInfo( const ItemInfo *pInfo0, int refreshFlags )
{
	refreshFlags&=INFO_ICON;
	if (!pInfo0 || !refreshFlags || !m_bInitialized ||
		m_LoadingStage!=LOAD_LOADING || !m_WorkEvent || !m_StartEvent)
		return !refreshFlags;

	ItemInfo *pInfo=const_cast<ItemInfo*>(pInfo0);
	RWLock lock(this,true,RWLOCK_ITEMS);
	const int missingFlags=refreshFlags&~pInfo->validFlags;
	if (!missingFlags)
		return true;

	// A previous terminal fallback applies only to the request that produced it.
	// Explicitly queueing an invalidated icon starts a fresh resolution attempt.
	pInfo->a4sResolvedIconFlags&=~missingFlags;

	// Promote an idle preload request to the high-priority decoder queue. The
	// decoder may already have popped the item; a harmless second queue entry is
	// preferable to waiting behind unrelated preload work.
	for (std::list<ItemInfo*>::iterator it=m_ItemQueueLow.begin();
		it!=m_ItemQueueLow.end();)
	{
		if (*it==pInfo)
			it=m_ItemQueueLow.erase(it);
		else
			++it;
	}
	QueueItemInfo(pInfo,missingFlags);
	return true;
}

bool CItemManager::AreA4SItemInfosReady(
	const std::vector<const ItemInfo*> &items, int refreshFlags )
{
	refreshFlags&=INFO_ICON;
	if (!refreshFlags)
		return true;
	RWLock lock(this,false,RWLOCK_ITEMS);
	for (std::vector<const ItemInfo*>::const_iterator it=items.begin();
		it!=items.end();++it)
	{
		const ItemInfo *pInfo=*it;
		if (pInfo && ((pInfo->validFlags|pInfo->a4sResolvedIconFlags)&refreshFlags)
			!=refreshFlags)
			return false;
	}
	return true;
}

bool CItemManager::WaitForA4SItemInfo( DWORD timeout )
{
	if (!m_A4SItemReadyEvent || !m_ExitEvent)
		return false;
	HANDLE handles[2]={m_A4SItemReadyEvent,m_ExitEvent};
	const DWORD result=WaitForMultipleObjects(_countof(handles),handles,FALSE,timeout);
	return result==WAIT_OBJECT_0 || result==WAIT_TIMEOUT;
}
#endif

void CItemManager::WaitForShortcuts( const POINT &balloonPos )
{
	if (m_PreloadItemsThreadId)
	{
		if (WaitForSingleObject(m_DoneEvent,1000)!=WAIT_TIMEOUT)
			return;
		CWindow tooltip=CreateWindowEx(WS_EX_TOPMOST|WS_EX_TOOLWINDOW|(IsLanguageRTL()?WS_EX_LAYOUTRTL:0),TOOLTIPS_CLASS,NULL,WS_POPUP|TTS_BALLOON|TTS_NOPREFIX,0,0,0,0,NULL,NULL,g_Instance,NULL);
		tooltip.SendMessage(TTM_SETMAXTIPWIDTH,0,500);
		TOOLINFO tool={sizeof(tool),TTF_TRANSPARENT|TTF_TRACK|(IsLanguageRTL()?TTF_RTLREADING:0U)};
		tool.uId=1;
		CString message=LoadStringEx(IDS_MENU_BUSY);
		tool.lpszText=(LPWSTR)(const wchar_t*)message;
		tooltip.SendMessage(TTM_ADDTOOL,0,(LPARAM)&tool);
		tooltip.SendMessage(TTM_SETTITLE,TTI_INFO,(LPARAM)(const wchar_t*)LoadStringEx(IDS_APP_TITLE));
		tooltip.SendMessage(TTM_TRACKPOSITION,0,MAKELONG(balloonPos.x,balloonPos.y));
		tooltip.SendMessage(TTM_TRACKACTIVATE,TRUE,(LPARAM)&tool);
		tooltip.SendMessage(TTM_UPDATE);
		WaitForSingleObject(m_DoneEvent,INFINITE);
		tooltip.DestroyWindow();
	}
}

bool CItemManager::IsTaskbarPinned( const wchar_t *appid )
{
	Assert(GetCurrentThreadId()==m_MainThreadId);
	RWLock lock(this,true,RWLOCK_ITEMS);
	const ItemInfo *pInfo=NULL;
	for (std::multimap<unsigned int,ItemInfo>::const_iterator it=m_ItemInfos.begin();it!=m_ItemInfos.end();++it)
	{
		if (it->second.bLink && it->second.location==LOCATION_TASKBAR)
		{
			UpdateItemInfo(&it->second,INFO_LINK_APPID,true);
			if (wcscmp(it->second.appid,appid)==0)
			{
				if (GetFileAttributes(it->second.path)!=INVALID_FILE_ATTRIBUTES)
					return true;
			}
		}
	}
	return false;
}

void EncodeRot13( wchar_t *text )
{
	for (;*text;text++)
	{
		if (*text>='a' && *text<='z')
			*text=(*text-'a'+13)%26+'a';
		else if (*text>='A' && *text<='Z')
			*text=(*text-'A'+13)%26+'A';
	}
}

static KNOWNFOLDERID g_KnownPrefixes[]=
{
	FOLDERID_SystemX86,
	FOLDERID_System,
	FOLDERID_Windows,
	FOLDERID_ProgramFilesX86,
	FOLDERID_ProgramFilesX64,
	FOLDERID_Programs,
	FOLDERID_CommonPrograms,
	FOLDERID_StartMenu,
	FOLDERID_CommonStartMenu,
};

void EncodeUserAssistPath( wchar_t *path )
{
	for (int i=0;i<_countof(g_KnownPrefixes);i++)
	{
		CComString knownPath;
		if (FAILED(SHGetKnownFolderPath(g_KnownPrefixes[i],0,NULL,&knownPath)))
			continue;
		int len=Strlen(knownPath);
		if (_wcsnicmp(path,knownPath,len)==0)
		{
			CComString guid;
			StringFromCLSID(g_KnownPrefixes[i],&guid);
			wchar_t name[_MAX_PATH];
			Sprintf(name,_countof(name),L"%s%s",(const wchar_t*)guid,path+len);
			Strcpy(path,_MAX_PATH,name);
			return;
		}
	}
}

bool CItemManager::IsPathUsed( CRegKey &regKey, const wchar_t *path, const FILETIME &createstamp, const KnownPathGuid *knownPaths, int knownPathsCount, bool bMetroApp )
{
	{
		unsigned int hash=CalcFNVHash(path);
		OldItemInfo key={hash};
		std::vector<OldItemInfo>::const_iterator it=std::lower_bound(m_OldItemInfos.begin(),m_OldItemInfos.end(),key);
		if (it!=m_OldItemInfos.end() && it->hash==hash)
		{
			if (CompareFileTime(&createstamp,&it->timestamp)<0)
				return true;
		}
	}

	wchar_t name[_MAX_PATH];
	if (knownPaths)
	{
		for (int i=0;i<knownPathsCount;i++)
		{
			if (i==knownPathsCount-1)
				Strcpy(name,_countof(name),path);
			else if (wcsncmp(path,knownPaths[i].path,knownPaths[i].pathLen)==0)
			{
				Sprintf(name,_countof(name),L"%s%s", (const wchar_t*)knownPaths[i].guid,path+knownPaths[i].pathLen);
				break;
			}
		}
	}
	else
	{
		Strcpy(name,_countof(name),path);
	}
	EncodeRot13(name);
	UserAssistData data;
	DWORD size=sizeof(data);
	if (regKey.QueryBinaryValue(name,&data,&size)==ERROR_SUCCESS)
	{
		if (bMetroApp)
		{
			// count is unreliable, the timestamp can be 0
			return ((data.timestamp.dwLowDateTime|data.timestamp.dwHighDateTime)==0 || CompareFileTime(&createstamp,&data.timestamp)<0);
		}
		else
		{
			return (data.count>0 && CompareFileTime(&createstamp,&data.timestamp)<0);
		}
	}
	return false;
}

void CItemManager::UpdateNewPrograms( const POINT &balloonPos )
{
	Assert(GetCurrentThreadId()==m_MainThreadId);
	m_NewPrograms.clear();
	m_NewProgramRoots.clear();
	m_bHasNewPrograms[0]=m_bHasNewPrograms[1]=m_bHasNewApps[0]=m_bHasNewApps[1]=false;
#ifdef FORCE_ALL_NEW
	m_bHasNewPrograms[0]=m_bHasNewPrograms[1]=m_bHasNewApps[0]=m_bHasNewApps[1]=true;
#endif
	if (!GetSettingBool(L"HighlightNew"))
		return;
	bool bNewApps=GetSettingBool(L"HighlightNewApps");
/*	{
		// the new programs need the MFU system to be enabled
		CRegKey regKey;
		if (regKey.Open(HKEY_CURRENT_USER,L"Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",KEY_READ)!=ERROR_SUCCESS)
			return;
		DWORD val;
		if (regKey.QueryDWORDValue(L"Start_TrackProgs",val)==ERROR_SUCCESS && !val)
			return;
	}
*/
	LONGLONG installTime=0;
	{
		CRegKey regKey;
		if (regKey.Open(HKEY_LOCAL_MACHINE,L"SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion",KEY_READ)==ERROR_SUCCESS)
		{
			DWORD time=0;
			if (regKey.QueryDWORDValue(L"InstallDate",time)==ERROR_SUCCESS)
			{
				installTime=Int32x32To64(time,10000000)+116444736000000000;
			}
		}
		FILETIME ft={(DWORD)installTime,(DWORD)(installTime>>32)};
		SYSTEMTIME st;
		GetSystemTime(&st);
		LOG_MENU(LOG_NEW,L"Current time: %02d.%02d.%04d:%02d:%02d",st.wDay,st.wMonth,st.wYear,st.wHour,st.wMinute);
		FileTimeToSystemTime(&ft,&st);
		LOG_MENU(LOG_NEW,L"Install time: %02d.%02d.%04d:%02d:%02d",st.wDay,st.wMonth,st.wYear,st.wHour,st.wMinute);
	}

	CRegKey regKeyExe;
	regKeyExe.Open(HKEY_CURRENT_USER,USERASSIST_APPIDS_KEY,KEY_READ);
	CRegKey regKeyLink;
	regKeyLink.Open(HKEY_CURRENT_USER,USERASSIST_LINKS_KEY,KEY_READ);

	KnownPathGuid knownPaths[_countof(g_KnownPrefixes)+1];

	int OLD_PROGRAMS_AGE=GetSettingInt(L"OldProgramsAge");
	if (OLD_PROGRAMS_AGE<0) OLD_PROGRAMS_AGE=0;
	if (OLD_PROGRAMS_AGE>48) OLD_PROGRAMS_AGE=48;
	const int INSTALL_GRACE_PERIOD=12; // ignore programs installed within 12 hours of system install
	int knownPathsCount=0;
	for (int i=0;i<_countof(g_KnownPrefixes);i++)
	{
		if (SUCCEEDED(SHGetKnownFolderPath(g_KnownPrefixes[i],0,NULL,&knownPaths[knownPathsCount].path)))
		{
			StringFromCLSID(g_KnownPrefixes[i],&knownPaths[knownPathsCount].guid);
			knownPaths[knownPathsCount].path.MakeUpper();
			knownPaths[knownPathsCount].pathLen=Strlen(knownPaths[knownPathsCount].path);
			knownPathsCount++;
		}
	}
	knownPaths[knownPathsCount++].pathLen=0;

	LONGLONG curTime;
	GetSystemTimeAsFileTime((FILETIME*)&curTime);
	WaitForShortcuts(balloonPos);
	LARGE_INTEGER newestProgram={0}, newestApp={0};
	{
		RWLock lock(this,true,RWLOCK_ITEMS);
		for (std::multimap<unsigned int,ItemInfo>::const_iterator it=m_ItemInfos.begin();it!=m_ItemInfos.end();++it)
		{
			if (it->second.location!=LOCATION_START_MENU && it->second.location!=LOCATION_METRO)
				continue;
			if ((it->second.bMetroLink || it->second.bMetroApp) && !bNewApps)
				continue;
			if (!it->second.bLink && !it->second.bMetroApp)
			{
				LOG_MENU(LOG_NEW,L"Ignoring new: %s not a link",it->second.path);
				continue;
			}
			if (it->second.bNoNew)
			{
				LOG_MENU(LOG_NEW,L"Ignoring new: %s suppressed",it->second.path);
				continue;
			}
#ifdef FORCE_ALL_NEW
			m_NewPrograms.push_back(&it->second);
			continue;
#endif
			LONGLONG timestamp=it->second.createstamp.dwLowDateTime|(((LONGLONG)it->second.createstamp.dwHighDateTime)<<32);
			int hours1=(int)((curTime-timestamp)/36000000000);
			if (hours1<0)
			{
				LOG_MENU(LOG_NEW,L"Ignoring new: %s creation time too new - %d hours",it->second.path,hours1);
				continue;
			}
			if (hours1>OLD_PROGRAMS_AGE)
			{
				LOG_MENU(LOG_NEW,L"Ignoring new: %s creation time too old - %d hours",it->second.path,hours1);
				continue;
			}
			if (wcswcs(PathFindFileName(it->second.PATH),L"UNINSTALL"))
			{
				LOG_MENU(LOG_NEW,L"Ignoring new: %s contains UNINSTALL",it->second.path);
				continue;
			}
			if (it->second.location==LOCATION_START_MENU)
			{
				if (wcscmp(PathFindExtension(it->second.targetPATH),L".EXE")!=0)
				{
					LOG_MENU(LOG_NEW,L"Ignoring new: %s target not exe",it->second.path);
					continue;
				}
			}

			if (it->second.bLink && GetFileAttributes(it->second.path)==INVALID_FILE_ATTRIBUTES)
			{
				LOG_MENU(LOG_NEW,L"Ignoring new: %s missing file",it->second.path);
				continue;
			}
			// existing link to exe that is newer than 48 hours
			int hours2=0, hours3=0;
			if (it->second.location==LOCATION_START_MENU)
			{
				HANDLE h=CreateFile(it->second.targetPATH,FILE_READ_ATTRIBUTES,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,NULL,OPEN_EXISTING,0,NULL);
				if (h==INVALID_HANDLE_VALUE)
				{
					LOG_MENU(LOG_NEW,L"Ignoring new: %s failed to read attributes",it->second.path);
					continue;
				}

				FILE_BASIC_INFO info;
				hours2=0;
				if (GetFileInformationByHandleEx(h,FileBasicInfo,&info,sizeof(info)))
					hours2=(int)((curTime-info.ChangeTime.QuadPart)/36000000000);
				CloseHandle(h);
				if (hours2<0)
				{
					LOG_MENU(LOG_NEW,L"Ignoring new: %s target change time too new - %d hours",it->second.path,hours2);
					continue; // the exe is too old
				}
				if (hours2>OLD_PROGRAMS_AGE)
				{
					LOG_MENU(LOG_NEW,L"Ignoring new: %s target change time too old - %d hours",it->second.path,hours2);
					continue; // the exe is too old
				}
				hours3=(int)((info.ChangeTime.QuadPart-installTime)/36000000000);
				if (hours3<INSTALL_GRACE_PERIOD)
				{
					LOG_MENU(LOG_NEW,L"Ignoring new: %s too soon after install - %d hours",it->second.path,hours3);
					continue; // too soon after install
				}

				if (regKeyLink.m_hKey && IsPathUsed(regKeyLink,it->second.PATH,it->second.createstamp,knownPaths,knownPathsCount,it->second.bMetroApp))
				{
					LOG_MENU(LOG_NEW,L"Ignoring new: %s shortcut used after it was created",it->second.path);
					continue;  // the shortcut was used after it was created
				}
				if (regKeyExe.m_hKey)
				{
					UpdateItemInfo(&it->second,INFO_LINK_APPID,true);
					CString appid=it->second.appid;
					appid.MakeUpper();
					if (IsPathUsed(regKeyExe,appid,it->second.createstamp,NULL,0,it->second.bMetroApp))
					{
						LOG_MENU(LOG_NEW,L"Ignoring new: %s exe used after the shortcut was created",it->second.path);
						continue; // the exe was used after the shortcut was created
					}
				}
				if (newestProgram.QuadPart<info.ChangeTime.QuadPart)
					newestProgram.QuadPart=info.ChangeTime.QuadPart;
			}

			if (it->second.location==LOCATION_METRO)
			{
				hours3=(int)((timestamp-installTime)/36000000000);
				if (hours3<INSTALL_GRACE_PERIOD)
				{
					LOG_MENU(LOG_NEW,L"Ignoring new: %s too soon after install - %d hours",it->second.path,hours3);
					continue; // too soon after install
				}
				CString appid=it->second.appid;
				appid.MakeUpper();
				if (regKeyExe.m_hKey && IsPathUsed(regKeyExe,appid,it->second.createstamp,NULL,0,it->second.bMetroApp))
				{
					LOG_MENU(LOG_NEW,L"Ignoring new: %s app id used after app was created",it->second.path);
					continue; // the exe was used after the shortcut was created
				}
				if (it->second.bLink && regKeyLink.m_hKey && IsPathUsed(regKeyLink,it->second.PATH,it->second.createstamp,knownPaths,knownPathsCount,it->second.bMetroApp))
				{
					LOG_MENU(LOG_NEW,L"Ignoring new: %s shortcut used after it was created",it->second.path);
					continue;  // the shortcut was used after it was created
				}
				if (newestApp.QuadPart<timestamp)
					newestApp.QuadPart=timestamp;
			}

			m_NewPrograms.push_back(&it->second);
			LOG_MENU(LOG_NEW,L"Accepting new: highlighting %s, created %d hours, target changed %d hours, since install %d hours, %I64X",it->second.path,hours1,hours2,hours3,timestamp);
		}
	}

	if (newestProgram.QuadPart || newestApp.QuadPart)
	{
		CRegKey regKey;
		ULONGLONG val1, val2;
		if (regKey.Open(HKEY_CURRENT_USER,A4S_MENU_REG_ROOT,KEY_READ)==ERROR_SUCCESS)
		{
			if (regKey.QueryQWORDValue(L"LastProgramsTime",val1)!=ERROR_SUCCESS)
				val1=0;
			if (regKey.QueryQWORDValue(L"LastAppsTime",val2)!=ERROR_SUCCESS)
				val2=0;
		}
		if (newestProgram.QuadPart)
		{
			LOG_MENU(LOG_NEW,L"LastProgramsTime: %I64X",val1);
			m_bHasNewPrograms[0]=true;
			m_bHasNewPrograms[1]=(val1<(ULONGLONG)newestProgram.QuadPart);
		}
		if (newestApp.QuadPart)
		{
			LOG_MENU(LOG_NEW,L"LastAppsTime: %I64X",val2);
			m_bHasNewApps[0]=true;
			m_bHasNewApps[1]=(val2<(ULONGLONG)newestApp.QuadPart);
		}
	}

	static const KNOWNFOLDERID *newProgramRoots[]={
		&FOLDERID_StartMenu,
		&FOLDERID_CommonStartMenu,
		&FOLDERID_Programs,
		&FOLDERID_CommonPrograms,
	};
	for (int i=0;i<_countof(newProgramRoots);i++)
	{
		CComPtr<IShellItem> pFolder;
		if (SUCCEEDED(ShGetKnownFolderItem(*newProgramRoots[i],&pFolder)))
		{
			CAbsolutePidl pidl;
			if (SUCCEEDED(SHGetIDListFromObject(pFolder,&pidl)))
				m_NewProgramRoots.push_back(GetItemInfo(pFolder,pidl,0));
		}
	}
	if (GetWinVersion()>=WIN_VER_WIN8)
	{
		wchar_t path[_MAX_PATH]=METRO_APP_ROOT;
		DoEnvironmentSubst(path,_countof(path));
		CAbsolutePidl pidl;
		pidl.Attach(ILCreateFromPath(path));
		CComPtr<IShellItem> pFolder;
		if (SUCCEEDED(SHCreateItemFromIDList(pidl,IID_IShellItem,(void**)&pFolder)))
			m_NewProgramRoots.push_back(GetItemInfo(pFolder,pidl,0));
	}
}

bool CItemManager::IsNewProgram( PIDLIST_ABSOLUTE pidl, bool bFolder, bool bMetroApp )
{
	Assert(GetCurrentThreadId()==m_MainThreadId);
	if (m_NewPrograms.empty()) return false;
	if (!bMetroApp)
	{
		// check if the item is under the approved roots
		bool bValid=false;
		for (std::vector<const ItemInfo*>::const_iterator it=m_NewProgramRoots.begin();it!=m_NewProgramRoots.end();++it)
		{
			if (ILIsParent((*it)->GetPidl(),pidl,FALSE))
			{
				bValid=true;
				break;
			}
		}
		if (!bValid) return false;
	}
	for (std::vector<const ItemInfo*>::const_iterator it=m_NewPrograms.begin();it!=m_NewPrograms.end();++it)
	{
		if (bFolder && ILIsParent(pidl,(*it)->GetPidl(),FALSE))
			return true;
		if (!bFolder && ILIsEqual(pidl,(*it)->GetPidl()))
			return true;
	}
	return false;
}

void CItemManager::LoadOldItems( void )
{
	m_OldItemInfos.clear();
	CRegKey regItems;
	if (regItems.Open(HKEY_CURRENT_USER,A4S_MENU_REG_ROOT,KEY_READ)==ERROR_SUCCESS)
	{
		ULONG size=0;
		regItems.QueryBinaryValue(L"OldItems",NULL,&size);
		if (size>0 && (size%sizeof(OldItemInfo))==0)
		{
			m_OldItemInfos.resize(size/sizeof(OldItemInfo));
			regItems.QueryBinaryValue(L"OldItems",&m_OldItemInfos[0],&size);
		}
	}

	std::sort(m_OldItemInfos.begin(),m_OldItemInfos.end());
}

void CItemManager::RemoveNewItem( PIDLIST_ABSOLUTE pItem1, PIDLIST_ABSOLUTE pItem2, bool bFolder )
{
	std::vector<unsigned> hashes;
	{
		RWLock lock(this,false,RWLOCK_ITEMS);
		for (size_t i=0;i<m_NewPrograms.size();i++)
		{
			const ItemInfo *pInfo=m_NewPrograms[i];
			bool bFound=false;
			if (bFolder && (ILIsParent(pItem1,pInfo->GetPidl(),FALSE) || (pItem2 && ILIsParent(pItem2,pInfo->GetPidl(),FALSE))))
				bFound=true;
			if (!bFound && !bFolder && ILIsEqual(pItem1,pInfo->GetPidl()))
				bFound=true;
			if (bFound)
			{
				unsigned hash;
				if (pInfo->bMetroApp)
				{
					CString appid=pInfo->appid;
					appid.MakeUpper();
					hash=CalcFNVHash(appid);
				}
				else if (pInfo->bLink)
				{
					hash=CalcFNVHash(pInfo->PATH);
				}
				else continue;
				m_NewPrograms.erase(m_NewPrograms.begin()+i);
				hashes.push_back(hash);
				i--;
			}
		}
	}
	AddOldItems(hashes);
}

void CItemManager::RemoveNewItems( bool bPrograms, bool bMetro )
{
	std::vector<unsigned> hashes;
	{
		RWLock lock(this,false,RWLOCK_ITEMS);
		for (size_t i=0;i<m_NewPrograms.size();i++)
		{
			const ItemInfo *pInfo=m_NewPrograms[i];
			if (pInfo->location==LOCATION_METRO && !bMetro)
				continue;
			if (pInfo->location!=LOCATION_METRO && !bPrograms)
				continue;
			unsigned hash;
			if (pInfo->bMetroApp)
			{
				CString appid=pInfo->appid;
				appid.MakeUpper();
				hash=CalcFNVHash(appid);
			}
			else if (pInfo->bLink)
			{
				hash=CalcFNVHash(pInfo->PATH);
			}
			else continue;
			m_NewPrograms.erase(m_NewPrograms.begin()+i);
			hashes.push_back(hash);
			i--;
		}
	}
	AddOldItems(hashes);
	if (bMetro)
		m_bHasNewApps[0]=m_bHasNewApps[1]=false;
	if (bPrograms)
		m_bHasNewPrograms[0]=m_bHasNewPrograms[1]=false;
}

void CItemManager::AddOldItems( const std::vector<unsigned> &hashes )
{
	// purge items older than 48 hours
	LONGLONG timestamp;
	GetSystemTimeAsFileTime((FILETIME*)&timestamp);
	timestamp-=36000000000ll*48;
	for (size_t i=0;i<m_OldItemInfos.size();i++)
	{
		if (CompareFileTime((FILETIME*)&timestamp,&m_OldItemInfos[i].timestamp)>0)
		{
			m_OldItemInfos.erase(m_OldItemInfos.begin()+i);
			i--;
		}
	}

	for (std::vector<unsigned>::const_iterator it=hashes.begin();it!=hashes.end();++it)
	{
		OldItemInfo key={*it};
		GetSystemTimeAsFileTime(&key.timestamp);
		std::vector<OldItemInfo>::iterator it2=std::lower_bound(m_OldItemInfos.begin(),m_OldItemInfos.end(),key);
		if (it2!=m_OldItemInfos.end() && it2->hash==*it)
			it2->timestamp=key.timestamp;
		else
			m_OldItemInfos.insert(it2,key);
	}

	CRegKey regItems;
	if (regItems.Open(HKEY_CURRENT_USER,A4S_MENU_REG_ROOT)!=ERROR_SUCCESS)
		regItems.Create(HKEY_CURRENT_USER,A4S_MENU_REG_ROOT);

	if (m_OldItemInfos.empty())
		regItems.SetBinaryValue(L"OldItems",NULL,0);
	else
		regItems.SetBinaryValue(L"OldItems",&m_OldItemInfos[0],ULONG((size_t)m_OldItemInfos.size()*sizeof(OldItemInfo)));
}

CString GetPropertyStoreString( IPropertyStore *pStore, REFPROPERTYKEY key )
{
	PROPVARIANT val;
	PropVariantInit(&val);
	CString res;
	if (SUCCEEDED(pStore->GetValue(key,&val)))
	{
		if (val.vt==VT_LPWSTR || val.vt==VT_BSTR)
			res=val.pwszVal;
		else if (val.vt==VT_LPSTR)
			res=val.pszVal;
	}
	PropVariantClear(&val);
	return res;
}

// doesn't require the lock to be held
void CItemManager::RefreshItemInfo( ItemInfo *pInfo, int refreshFlags, IShellItem *pItem0, bool bHasWriteLock )
{
#ifdef A4S_PRODUCT
	const UINT32 requestedIconFlags=static_cast<UINT32>(refreshFlags&INFO_ICON);
	ItemInfo *const pA4SInfo=pInfo;
	A4SPerformanceScope iconScope(A4S_PERF_ICON_LOAD,requestedIconFlags!=0,
		requestedIconFlags);
#endif
	ItemInfo newInfo;

	{
		// get info from pInfo
		RWLock lock(this,false,bHasWriteLock?RWLOCK_COUNT:RWLOCK_ITEMS);
		newInfo=*pInfo;
	}

	CComPtr<IShellItem> pItem;
	CComPtr<IShellItem> pAppItem;
	bool bStartScreen=
#ifndef STARTSCREEN_WIN7
		GetWinVersion()>=WIN_VER_WIN8 &&
#endif
		(_wcsicmp(PathFindFileName(newInfo.PATH),STARTSCREEN_COMMAND)==0);
	bool bValidateIcons=!bStartScreen; // hack - don't mark the icon as valid, so we have to load it next time
	{
		// do the real work

		int pInfo=0; // shadow the pInfo parameter while in this block
		if ((refreshFlags&INFO_DATA) || !(newInfo.bIconOnly || newInfo.bMetroLink))
		{
			if (pItem0)
				pItem=pItem0;
			else
			{
				const CAbsolutePidl &pidl=newInfo.newPidl?newInfo.newPidl:newInfo.pidl;
				if (pidl)
				{
					if (FAILED(SHCreateItemFromIDList(pidl,IID_IShellItem,(void**)&pItem)))
					{
#ifdef A4S_PRODUCT
						{
							RWLock lock(this,true,bHasWriteLock?RWLOCK_COUNT:RWLOCK_ITEMS);
							if (requestedIconFlags)
								pA4SInfo->a4sResolvedIconFlags|=requestedIconFlags;
							pA4SInfo->refreshFlags&=~refreshFlags;
						}
						if (requestedIconFlags && m_A4SItemReadyEvent)
							SetEvent(m_A4SItemReadyEvent);
						iconScope.SetResult(requestedIconFlags,FALSE);
#endif
						return;
					}
				}
			}
		}

		if (refreshFlags&INFO_DATA)
		{
			Assert(!newInfo.bIconOnly);

			// these two are always updated even if INFO_LINK is not requested
			newInfo.bLink=false;
			newInfo.bNoPin=false;
			newInfo.bNoNew=false;
			newInfo.bExplicitAppId=false;
			newInfo.targetPATH.Empty();
			newInfo.targetPidl.Clear();
			if (refreshFlags&INFO_LINK_APPID)
			{
				newInfo.appid.Empty();
			}

			if (refreshFlags&INFO_METRO)
			{
				newInfo.bMetroLink=false;
				newInfo.bMetroApp=false;
				newInfo.bProtectedLink=false;
				newInfo.metroName.Empty();
				newInfo.iconPath.Empty();
				newInfo.iconColor=0;
			}

			// refresh link and metro
			SFGAOF flags=0;
			if (pItem && SUCCEEDED(pItem->GetAttributes(SFGAO_LINK|SFGAO_FILESYSTEM,&flags)))
			{
				CComQIPtr<IPropertyStore> pStore;
				if (flags&SFGAO_LINK)
				{
					// get link properties
					CComPtr<IShellLink> pLink;
					if (SUCCEEDED(pItem->BindToHandler(NULL,BHID_SFUIObject,IID_IShellLink,(void**)&pLink)))
					{
						newInfo.bLink=true;
						pStore=pLink;
#ifdef _DEBUG
						LOG_MENU(LOG_OPEN, L"Link: %s", newInfo.path);
						LOG_MENU(LOG_OPEN, L"Link property store:");
						LogPropertyStore(LOG_OPEN, pStore);
#endif
						if (SUCCEEDED(pLink->GetIDList(&newInfo.targetPidl)))
						{
							wchar_t path[_MAX_PATH];
							if (SUCCEEDED(SHGetPathFromIDList(newInfo.targetPidl,path)))
							{
								CharUpper(path);
								newInfo.targetPATH=path;
							}

							CComPtr<IShellItem> target;
							if (SUCCEEDED(SHCreateItemFromIDList(newInfo.targetPidl, IID_PPV_ARGS(&target))))
							{
								CComPtr<IPropertyStore> store;
								if (SUCCEEDED(target->BindToHandler(nullptr, BHID_PropertyStore, IID_PPV_ARGS(&store))))
								{
#ifdef _DEBUG
									LOG_MENU(LOG_OPEN, L"Target property store:");
									LogPropertyStore(LOG_OPEN, store);
#endif
									PROPVARIANT val;
									PropVariantInit(&val);
									if (SUCCEEDED(store->GetValue(PKEY_MetroAppLauncher, &val)) && (val.vt == VT_I4 || val.vt == VT_UI4) && val.intVal)
									{
										newInfo.bLink = false;
										pItem = std::move(target);
										pStore = store;
									}
									PropVariantClear(&val);
								}
							}
						}
					}
				}
				else if (!(flags&SFGAO_FILESYSTEM))
				{
					newInfo.bLink=false;
					pItem->BindToHandler(NULL,BHID_PropertyStore,IID_IPropertyStore,(void**)&pStore);
				}
				if (pStore)
				{
					if (GetWinVersion()>=WIN_VER_WIN7)
					{
						newInfo.appid=GetPropertyStoreString(pStore,PKEY_AppUserModel_ID);
						newInfo.bExplicitAppId=!newInfo.appid.IsEmpty();
					}
					if (!newInfo.appid.IsEmpty() && (refreshFlags&INFO_METRO) && (GetWinVersion()<=WIN_VER_WIN8 || _wcsicmp(newInfo.appid,SEARCH_APP_ID)!=0))
					{
						PROPVARIANT val;
						PropVariantInit(&val);
						if (SUCCEEDED(pStore->GetValue(PKEY_MetroAppLauncher,&val)) && (val.vt==VT_I4 || val.vt==VT_UI4) && val.intVal)
						{
							// get Metro properties
							PropVariantClear(&val);
							newInfo.bMetroLink=newInfo.bLink;
							newInfo.bMetroApp=!newInfo.bLink;
							newInfo.bProtectedLink=false;
							if (newInfo.bMetroApp)
							{
								pAppItem=pItem;
								newInfo.packagePath=GetPropertyStoreString(pStore,PKEY_MetroPackagePath);
								if (!newInfo.packagePath.IsEmpty())
								{
									FILETIME writeTime={0}, createTime={0};
									if (MenuGetFileTimestamp(newInfo.packagePath,&writeTime,&createTime))
									{
										newInfo.writestamp=writeTime;
										newInfo.createstamp=createTime;
									}
								}
							}
							if (newInfo.bMetroLink && wcsncmp(newInfo.PATH,m_RootCommonPrograms,m_RootCommonPrograms.GetLength())==0)
							{
								const wchar_t *str=newInfo.PATH;
								newInfo.bProtectedLink=m_RootCommonPrograms.GetLength()==(PathFindFileName(str)-str);
							}
							if (SUCCEEDED(pStore->GetValue(PKEY_MetroIconColor,&val)) && (val.vt==VT_I4 || val.vt==VT_UI4))
								newInfo.iconColor=val.intVal;
							if (pAppItem || SUCCEEDED(SHCreateItemInKnownFolder(FOLDERID_AppsFolder2,0,newInfo.appid,IID_IShellItem,(void**)&pAppItem)))
							{
								CComString pName;
								if (SUCCEEDED(pAppItem->GetDisplayName(SIGDN_NORMALDISPLAY,&pName)))
								{
									newInfo.metroName=pName;
								}
							}
						}
						PropVariantClear(&val);
					}
					if (!newInfo.bMetroLink && !newInfo.bMetroApp)
					{
						PROPVARIANT val;
						PropVariantInit(&val);
						if (SUCCEEDED(pStore->GetValue(PKEY_AppUserModel_PreventPinning,&val)) && val.vt==VT_BOOL && val.boolVal)
							newInfo.bNoPin=true;
						PropVariantClear(&val);
						if (SUCCEEDED(pStore->GetValue(PKEY_AppUserModel_ExcludeFromShowInNewInstall,&val)) && val.vt==VT_BOOL && val.boolVal)
							newInfo.bNoNew=true;
						PropVariantClear(&val);
					}
				}

				if (newInfo.bLink && newInfo.appid.IsEmpty() && (refreshFlags&INFO_LINK_APPID))
				{
					Assert(GetCurrentThreadId()==m_MainThreadId);
					if (!g_pAppResolver)
						CreateAppResolver();
					if (g_pAppResolver)
					{
						CComString pAppId;
						if (SUCCEEDED(g_pAppResolver->GetAppIDForShortcut(pItem,&pAppId)))
							newInfo.appid=pAppId;
					}
				}
			}
		}
		if (!newInfo.bIconOnly)
		{
			if (!newInfo.bLink)
			{
				newInfo.targetPidl.Clear();
				newInfo.targetPATH.Empty();
				newInfo.iconPath.Empty();
				newInfo.bNoPin=newInfo.bNoNew=false;
				if (!newInfo.bMetroApp)
				{
					newInfo.bExplicitAppId=false;
					newInfo.appid.Empty();
					newInfo.packagePath.Empty();
				}
			}
			else if (newInfo.bMetroLink)
			{
				newInfo.targetPidl.Clear();
				newInfo.targetPATH.Empty();
			}
		}

		if (refreshFlags&INFO_ICON)
		{
			// load icons
			if (newInfo.bIconOnly)
			{
				LoadCustomIcon(newInfo.iconPath,newInfo.iconIndex,refreshFlags&INFO_ICON,newInfo.smallIcon,newInfo.largeIcon,newInfo.extraLargeIcon,newInfo.bTemp);
			}
			else if (newInfo.bMetroLink || newInfo.bMetroApp)
			{
				if (pAppItem || SUCCEEDED(SHCreateItemInKnownFolder(FOLDERID_AppsFolder2,0,newInfo.appid,IID_IShellItem,(void**)&pAppItem)))
				{
					int iconFlags=refreshFlags&INFO_ICON;
					LoadMetroIcon(pAppItem,iconFlags,newInfo.smallIcon,newInfo.largeIcon,newInfo.extraLargeIcon,&newInfo.iconColor);
					if (iconFlags)
						LoadShellIcon(pItem?pItem:pAppItem,iconFlags,newInfo.smallIcon,newInfo.largeIcon,newInfo.extraLargeIcon,&newInfo.iconColor);
				}
			}
			else if (_wcsicmp(PathFindExtension(newInfo.path),L".settingcontent-ms")==0)
			{
				wchar_t iconPath[_MAX_PATH]=L"%windir%\\ImmersiveControlPanel\\systemsettings.exe";
				DoEnvironmentSubst(iconPath,_countof(iconPath));
				newInfo.iconPath=iconPath;
				newInfo.iconIndex=-10;
				LoadCustomIcon(newInfo.iconPath,newInfo.iconIndex,refreshFlags&INFO_ICON,newInfo.smallIcon,newInfo.largeIcon,newInfo.extraLargeIcon,false);
			}
			else
			{
				LoadShellIcon(pItem,(refreshFlags&INFO_ICON)|(bStartScreen?INFO_STARTSCREEN_ICON:0),newInfo.smallIcon,newInfo.largeIcon,newInfo.extraLargeIcon,NULL);
			}
		}
	}

	{
		// store info in pInfo
		RWLock lock(this,true,bHasWriteLock?RWLOCK_COUNT:RWLOCK_ITEMS);

		if (refreshFlags&INFO_DATA)
		{
			pInfo->bLink=newInfo.bLink;
			pInfo->bMetroLink=newInfo.bMetroLink;
			pInfo->bMetroApp=newInfo.bMetroApp;
			pInfo->bProtectedLink=newInfo.bProtectedLink;
			pInfo->bNoPin=newInfo.bNoPin;
			pInfo->bNoNew=newInfo.bNoNew;
			pInfo->bExplicitAppId=newInfo.bExplicitAppId;
			pInfo->targetPidl.Swap(newInfo.targetPidl);
			pInfo->targetPATH=newInfo.targetPATH;
			pInfo->packagePath=newInfo.packagePath;
			if ((refreshFlags&INFO_LINK_APPID) || !newInfo.appid.IsEmpty())
				pInfo->appid=newInfo.appid;
			if (!pInfo->appid.IsEmpty())
				refreshFlags|=INFO_LINK_APPID; // appid is valid, no need to resolve
			pInfo->metroName=newInfo.metroName;
			pInfo->iconPath=newInfo.iconPath;
			pInfo->iconColor=newInfo.iconColor;
			if (pInfo->bMetroApp)
			{
				pInfo->writestamp=newInfo.writestamp;
				pInfo->createstamp=newInfo.createstamp;
			}
		}

		if (refreshFlags&INFO_SMALL_ICON)
			pInfo->smallIcon=newInfo.smallIcon;
		if (refreshFlags&INFO_LARGE_ICON)
			pInfo->largeIcon=newInfo.largeIcon;
		if (refreshFlags&INFO_EXTRA_LARGE_ICON)
			pInfo->extraLargeIcon=newInfo.extraLargeIcon;
		if (bValidateIcons)
			pInfo->validFlags|=refreshFlags&(INFO_DATA|INFO_ICON);
		else
			pInfo->validFlags|=refreshFlags&INFO_DATA;
#ifdef A4S_PRODUCT
		pInfo->a4sResolvedIconFlags|=requestedIconFlags;
#endif
		pInfo->refreshFlags&=~refreshFlags;
	}
#ifdef A4S_PRODUCT
	if (requestedIconFlags && m_A4SItemReadyEvent)
		SetEvent(m_A4SItemReadyEvent);
	iconScope.SetResult(requestedIconFlags,FALSE);
#endif
}

void CItemManager::RefreshInfos( void )
{
	Assert(GetCurrentThreadId()==m_MainThreadId);
#ifdef A4S_PRODUCT
	// Most toggles have no PIDL replacement pending. Avoid an exclusive scan of
	// the complete metadata cache unless a watcher actually published one.
	if (InterlockedCompareExchange(&m_PendingPidlRefresh,0,0)==0)
		return;
#endif
	RWLock lock(this,true,RWLOCK_ITEMS);
	for (std::multimap<unsigned int,ItemInfo>::iterator it=m_ItemInfos.begin();it!=m_ItemInfos.end();++it)
	{
		if (it->second.newPidl)
		{
			it->second.pidl.Swap(it->second.newPidl);
			it->second.newPidl.Clear();
			it->second.validFlags=0;
		}
	}
#ifdef A4S_PRODUCT
	InterlockedExchange(&m_PendingPidlRefresh,0);
#endif
}

#ifdef A4S_PRODUCT
ULONGLONG CItemManager::GetFolderContentGeneration( void ) const
{
	return static_cast<ULONGLONG>(InterlockedCompareExchange64(
		const_cast<volatile LONGLONG*>(&m_FolderContentGeneration),0,0));
}

ULONGLONG CItemManager::GetIconCacheEpoch( void ) const
{
	return static_cast<ULONGLONG>(InterlockedCompareExchange64(
		const_cast<volatile LONGLONG*>(&m_IconCacheEpoch),0,0));
}

ULONGLONG CItemManager::GetA4SPathIdentityGeneration( void ) const
{
	return static_cast<ULONGLONG>(InterlockedCompareExchange64(
		const_cast<volatile LONGLONG*>(&m_A4SPathIdentityGeneration),0,0));
}

void CItemManager::ConfigureA4SFolderWatches( bool bNoCommonFolders,
	bool bClassicPinnedRoot, bool bMetroAppsSurface )
{
	const LONG requiredMask=static_cast<LONG>(
		A4SCacheState::RequiredFolderWatchMask(bNoCommonFolders,
			bClassicPinnedRoot,bMetroAppsSurface));
	const LONG previous=InterlockedExchange(&m_A4SRequiredWatchMask,requiredMask);
	if (previous!=requiredMask)
	{
		LONGLONG generation=InterlockedCompareExchange64(
			&m_A4SWatchConfigurationGeneration,0,0);
		while (1)
		{
			const LONGLONG next=static_cast<LONGLONG>(
				A4SCacheState::NextNonzeroEpoch(
					static_cast<ULONGLONG>(generation)));
			const LONGLONG observed=InterlockedCompareExchange64(
				&m_A4SWatchConfigurationGeneration,next,generation);
			if (observed==generation)
				break;
			generation=observed;
		}
		RevokeA4SFolderWatchBaseline();
		if (m_A4SWatchRebuildEvent)
			SetEvent(m_A4SWatchRebuildEvent);
	}
}

void CItemManager::ForceA4SFolderWatchReconfigure( void )
{
	LONGLONG generation=InterlockedCompareExchange64(
		&m_A4SWatchConfigurationGeneration,0,0);
	while (1)
	{
		const LONGLONG next=static_cast<LONGLONG>(
			A4SCacheState::NextNonzeroEpoch(
				static_cast<ULONGLONG>(generation)));
		const LONGLONG observed=InterlockedCompareExchange64(
			&m_A4SWatchConfigurationGeneration,next,generation);
		if (observed==generation)
			break;
		generation=observed;
	}
	RevokeA4SFolderWatchBaseline();
	if (m_A4SWatchRebuildEvent)
		SetEvent(m_A4SWatchRebuildEvent);
}

bool CItemManager::IsFolderWatchBaselineReady( void ) const
{
	if (InterlockedCompareExchange(
		const_cast<volatile LONG*>(&m_A4SFolderWatchReady),0,0)==0)
		return false;
	const DWORD requiredMask=static_cast<DWORD>(InterlockedCompareExchange(
		const_cast<volatile LONG*>(&m_A4SRequiredWatchMask),0,0));
	const DWORD armedMask=static_cast<DWORD>(InterlockedCompareExchange(
		const_cast<volatile LONG*>(&m_A4SArmedWatchMask),0,0));
	const ULONGLONG configurationGeneration=static_cast<ULONGLONG>(
		InterlockedCompareExchange64(const_cast<volatile LONGLONG*>(
			&m_A4SWatchConfigurationGeneration),0,0));
	const ULONGLONG publishedGeneration=static_cast<ULONGLONG>(
		InterlockedCompareExchange64(const_cast<volatile LONGLONG*>(
			&m_A4SPublishedWatchConfigurationGeneration),0,0));
	const ULONGLONG publishedIdentity=static_cast<ULONGLONG>(
		InterlockedCompareExchange64(const_cast<volatile LONGLONG*>(
			&m_A4SPublishedWatchIdentityHash),0,0));
	return A4SCacheState::RequiredFolderWatchesReady(requiredMask,armedMask,
		true,true,false) && publishedIdentity!=0 &&
		publishedGeneration==configurationGeneration &&
		InterlockedCompareExchange64(const_cast<volatile LONGLONG*>(
			&m_A4SWatchConfigurationGeneration),0,0)==
			static_cast<LONGLONG>(configurationGeneration) &&
		InterlockedCompareExchange(
			const_cast<volatile LONG*>(&m_A4SFolderWatchReady),0,0)!=0;
}

bool CItemManager::WaitForFolderWatchBaseline( DWORD timeout ) const
{
	if (IsFolderWatchBaselineReady())
		return true;
	if (!m_A4SFolderWatchReadyEvent || !m_ExitEvent)
		return false;
	HANDLE handles[2]={m_A4SFolderWatchReadyEvent,m_ExitEvent};
	const DWORD wait=WaitForMultipleObjects(_countof(handles),handles,FALSE,timeout);
	return wait==WAIT_OBJECT_0 && IsFolderWatchBaselineReady();
}

void CItemManager::AdvanceFolderContentGeneration( void )
{
	LONGLONG current=InterlockedCompareExchange64(&m_FolderContentGeneration,0,0);
	while (1)
	{
		// Zero is reserved for an uninitialized snapshot. Advance monotonically
		// for the practical lifetime of Explorer and skip zero on counter wrap.
		const ULONGLONG value=static_cast<ULONGLONG>(current);
		const LONGLONG next=static_cast<LONGLONG>(
			A4SCacheState::NextNonzeroEpoch(value));
		const LONGLONG observed=InterlockedCompareExchange64(&m_FolderContentGeneration,next,current);
		if (observed==current)
			return;
		current=observed;
	}
}

void CItemManager::AdvanceIconCacheEpoch( void )
{
	LONGLONG current=InterlockedCompareExchange64(&m_IconCacheEpoch,0,0);
	while (1)
	{
		const ULONGLONG value=static_cast<ULONGLONG>(current);
		const LONGLONG next=static_cast<LONGLONG>(
			A4SCacheState::NextNonzeroEpoch(value));
		const LONGLONG observed=InterlockedCompareExchange64(&m_IconCacheEpoch,next,current);
		if (observed==current)
			return;
		current=observed;
	}
}

void CItemManager::AdvanceA4SPathIdentityGeneration( void )
{
	LONGLONG current=InterlockedCompareExchange64(
		&m_A4SPathIdentityGeneration,0,0);
	while (1)
	{
		const LONGLONG next=static_cast<LONGLONG>(
			A4SCacheState::NextNonzeroEpoch(
				static_cast<ULONGLONG>(current)));
		const LONGLONG observed=InterlockedCompareExchange64(
			&m_A4SPathIdentityGeneration,next,current);
		if (observed==current)
			return;
		current=observed;
	}
}

void CItemManager::RevokeA4SFolderWatchBaseline( void )
{
	InterlockedExchange(&m_A4SFolderWatchReady,0);
	InterlockedExchange(&m_A4SArmedWatchMask,0);
	if (m_A4SFolderWatchReadyEvent)
		ResetEvent(m_A4SFolderWatchReadyEvent);
	ClearA4SWatchRootTable();
	// Generation changes before callers can observe readiness again. Any cache
	// that raced the old ready state therefore fails its final epoch check.
	AdvanceFolderContentGeneration();
	AdvanceA4SPathIdentityGeneration();
}
#endif

HBITMAP CItemManager::BitmapFromIcon( HICON hIcon, int iconSize, bool bDestroyIcon )
{
	if (!hIcon) return NULL;
	LoadIconData &data=GetLoadIconData();
	if (!data.m_pFactory)
	{
		if (bDestroyIcon)
			DestroyIcon(hIcon);
		return NULL;
	}

	CComPtr<IWICBitmap> pBitmap;
	HRESULT hr=data.m_pFactory->CreateBitmapFromHICON(hIcon,&pBitmap);
	if (bDestroyIcon)
		DestroyIcon(hIcon);
	if (FAILED(hr))
		return NULL;

	CComPtr<IWICFormatConverter> pConverter;
	if (FAILED(data.m_pFactory->CreateFormatConverter(&pConverter)))
		return NULL;

	UINT width=0, height=0;
	if (SUCCEEDED(pBitmap->GetSize(&width,&height)) && width==iconSize && height==iconSize)
	{
		pConverter->Initialize(pBitmap,GUID_WICPixelFormat32bppPBGRA,WICBitmapDitherTypeNone,NULL,0,WICBitmapPaletteTypeMedianCut);
	}
	else
	{
		CComPtr<IWICBitmapScaler> pScaler;
		if (FAILED(data.m_pFactory->CreateBitmapScaler(&pScaler)))
			return NULL;
		pScaler->Initialize(pBitmap,iconSize,iconSize,WICBitmapInterpolationModeFant);
		pConverter->Initialize(pScaler,GUID_WICPixelFormat32bppPBGRA,WICBitmapDitherTypeNone,NULL,0,WICBitmapPaletteTypeMedianCut);
	}

	BITMAPINFO bi={0};
	bi.bmiHeader.biSize=sizeof(BITMAPINFOHEADER);
	bi.bmiHeader.biWidth=iconSize;
	bi.bmiHeader.biHeight=-iconSize;
	bi.bmiHeader.biPlanes=1;
	bi.bmiHeader.biBitCount=32;
	HDC hdc=CreateCompatibleDC(NULL);
	BYTE *bits;
	HBITMAP bmp=CreateDIBSection(hdc,&bi,DIB_RGB_COLORS,(void**)&bits,NULL,0);
	DeleteDC(hdc);
	if (!bmp) return NULL;
	hr=pConverter->CopyPixels(NULL,iconSize*4,iconSize*iconSize*4,bits);
	if (FAILED(hr))
	{
		DeleteObject(bmp);
		return NULL;
	}
	return bmp;
}

HICON CItemManager::LoadShellIcon( int index, int iconSize )
{
	LoadIconData &data=GetLoadIconData();
	int sizeIndex=-1;
	for (int i=0;i<_countof(data.m_IconSizes);i++)
	{
		if (data.m_IconSizes[i]==iconSize)
		{
			sizeIndex=i;
			break;
		}
	}
	if (sizeIndex==-1) return NULL;
	int listType=0;
	for (std::vector<std::pair<int,int>>::const_iterator it=m_ListSizes.begin();it!=m_ListSizes.end();++it)
	{
		listType=it->second;
		if (it->first>=iconSize)
			break;
	}
	CComPtr<IImageList> pImageList;
	if (FAILED(SHGetImageList(listType,IID_IImageList,(void**)&pImageList)))
		return NULL;
	HICON hIcon;

	if (data.m_pTempLists[sizeIndex])
	{
		if (SUCCEEDED(data.m_pTempLists[sizeIndex]->ReplaceFromImageList(0,pImageList,index,NULL,0)) && SUCCEEDED(data.m_pTempLists[sizeIndex]->GetIcon(0,ILD_TRANSPARENT,&hIcon)))
		{
			AddTrackedIcon(hIcon);
			return hIcon;
		}
	}
	if (FAILED(pImageList->GetIcon(index,ILD_TRANSPARENT,&hIcon)))
		return NULL;
	AddTrackedIcon(hIcon);
	return hIcon;
}

HICON CItemManager::LoadShellIcon( int iconSize, IExtractIcon *pExtractW, const wchar_t *location, IExtractIconA *pExtractA, const char *locationA, int index )
{
	HICON hIcon=NULL, hIcon2=NULL;
	HRESULT hr;
	if (iconSize<=GetSystemMetrics(SM_CXSMICON))
	{
		// small icon is closer
		if (pExtractW)
			hr=pExtractW->Extract(location,index,&hIcon2,&hIcon,MAKELONG(iconSize,iconSize));
		else
			hr=pExtractA->Extract(locationA,index,&hIcon2,&hIcon,MAKELONG(iconSize,iconSize));
	}
	else
	{
		// large icon is closer
		if (pExtractW)
			hr=pExtractW->Extract(location,index,&hIcon,&hIcon2,MAKELONG(iconSize,iconSize));
		else
			hr=pExtractA->Extract(locationA,index,&hIcon,&hIcon2,MAKELONG(iconSize,iconSize));
	}
	if (FAILED(hr)) return NULL;

	if (hIcon2) DestroyIcon(hIcon2);
	return hIcon;
}

void CItemManager::LoadShellIcon( IShellItem *pItem, int refreshFlags, const IconInfo *&smallIcon, const IconInfo *&largeIcon, const IconInfo *&extraLargeIcon, const DWORD *pMetroColor )
{
	if (!pItem)
		return;

	wchar_t location[_MAX_PATH];
	int index=0;
	if (refreshFlags&INFO_STARTSCREEN_ICON)
	{
		CComPtr<IShellLink> pLink;
		if (SUCCEEDED(pItem->BindToHandler(NULL,BHID_SFUIObject,IID_IShellLink,(void**)&pLink)))
		{
			if (SUCCEEDED(pLink->GetIconLocation(location,_countof(location),&index)) && (!location[0] || _wcsicmp(PathFindFileName(location),L"StartScreen.exe")==0))
			{
				unsigned int hash=CalcFNVHash(STARTSCREEN_COMMAND);
				HBITMAP hSmallBitmap=NULL, hLargeBitmap=NULL, hExtraLargeBitmap=NULL;
				if (refreshFlags&INFO_SMALL_ICON)
				{
					hSmallBitmap=GetStartScreenIcon(SMALL_ICON_SIZE);
				}

				if (refreshFlags&INFO_LARGE_ICON)
				{
					hLargeBitmap=GetStartScreenIcon(LARGE_ICON_SIZE);
				}

				if (refreshFlags&INFO_EXTRA_LARGE_ICON)
				{
					hExtraLargeBitmap=GetStartScreenIcon(EXTRA_LARGE_ICON_SIZE);
				}

				StoreInCache(hash,NULL,hSmallBitmap,hLargeBitmap,hExtraLargeBitmap,refreshFlags,smallIcon,largeIcon,extraLargeIcon,false,false);
				return;
			}
		}
	}

	// get the IExtractIcon object
	CComPtr<IExtractIcon> pExtractW;
	CComPtr<IExtractIconA> pExtractA;

	bool bNotFileName;
	bool bTransient=false;
	char locationA[_MAX_PATH];

	// get the icon location
	if (SUCCEEDED(pItem->BindToHandler(NULL,BHID_SFUIObject,IID_IExtractIconW,(void**)&pExtractW)))
	{
		UINT iconFlags=0;
		if (pExtractW->GetIconLocation(0,location,_countof(location),&index,&iconFlags)!=S_OK)
			return;

		bNotFileName=(iconFlags&GIL_NOTFILENAME)!=0;
		bTransient=(iconFlags&GIL_DONTCACHE)!=0;
	}
	else if (SUCCEEDED(pItem->BindToHandler(NULL,BHID_SFUIObject,IID_IExtractIconA,(void**)&pExtractA)))
	{
		UINT iconFlags=0;
		if (pExtractA->GetIconLocation(0,locationA,_countof(locationA),&index,&iconFlags)!=S_OK)
			return;

		MbsToWcs(location,_countof(location),locationA);
		bNotFileName=(iconFlags&GIL_NOTFILENAME)!=0;
		bTransient=(iconFlags&GIL_DONTCACHE)!=0;
	}
	else
		return;

	unsigned int hash;
	if (bTransient)
		hash=m_TransientHash++;
	else if (location[0])
		hash=CalcFNVHash(location,CalcFNVHash(&index,4));
	else
	{
		// if the location is blank, use the parsing name for the hash
		CComString pName;
		pItem->GetDisplayName(SIGDN_DESKTOPABSOLUTEPARSING,&pName);
		hash=CalcFNVHash(pName,CalcFNVHash(&index,4));
	}

	if (pMetroColor)
		hash=CalcFNVHash(pMetroColor,4,hash);

	if (!bTransient)
		FindInCache(hash,refreshFlags,smallIcon,largeIcon,extraLargeIcon);
	if (!refreshFlags) return;

	// extract icon
	HBITMAP hSmallBitmap=NULL, hLargeBitmap=NULL, hExtraLargeBitmap=NULL;

	wchar_t metroLocation[_MAX_PATH];
	Strcpy(metroLocation,_countof(metroLocation),location);
	if (pMetroColor && ParseMetroBitmapLocation(metroLocation))
	{
		if (refreshFlags&INFO_SMALL_ICON)
		{
			hSmallBitmap=LoadMetroBitmap(metroLocation,SMALL_ICON_SIZE,*pMetroColor);
		}
		if (refreshFlags&INFO_LARGE_ICON)
		{
			hLargeBitmap=LoadMetroBitmap(metroLocation,LARGE_ICON_SIZE,*pMetroColor);
		}
		if (refreshFlags&INFO_EXTRA_LARGE_ICON)
		{
			hExtraLargeBitmap=LoadMetroBitmap(metroLocation,EXTRA_LARGE_ICON_SIZE,*pMetroColor);
		}
		if (hSmallBitmap || hLargeBitmap || hExtraLargeBitmap)
		{
			metroLocation[1]='#';
			StoreInCache(hash,metroLocation,hSmallBitmap,hLargeBitmap,hExtraLargeBitmap,refreshFlags,smallIcon,largeIcon,extraLargeIcon,bTransient,true);
			return;
		}
	}
	
	Strcpy(metroLocation,_countof(metroLocation),location);
	if (pMetroColor && GetWinVersion()>=WIN_VER_WIN10 && ParseMetroBitmapLocation2(metroLocation))
	{
		if (refreshFlags&INFO_SMALL_ICON)
		{
			hSmallBitmap=LoadMetroBitmap2(metroLocation,SMALL_ICON_SIZE,*pMetroColor);
		}
		if (refreshFlags&INFO_LARGE_ICON)
		{
			hLargeBitmap=LoadMetroBitmap2(metroLocation,LARGE_ICON_SIZE,*pMetroColor);
		}
		if (refreshFlags&INFO_EXTRA_LARGE_ICON)
		{
			hExtraLargeBitmap=LoadMetroBitmap2(metroLocation,EXTRA_LARGE_ICON_SIZE,*pMetroColor);
		}
		if (hSmallBitmap || hLargeBitmap || hExtraLargeBitmap)
		{
			metroLocation[1]='#';
			StoreInCache(hash,metroLocation,hSmallBitmap,hLargeBitmap,hExtraLargeBitmap,refreshFlags,smallIcon,largeIcon,extraLargeIcon,bTransient,true);
			return;
		}
	}

	if (GetWinVersion()>=WIN_VER_WIN10)
		pMetroColor=NULL;

	int smallIconSize=SMALL_ICON_SIZE;
	int largeIconSize=LARGE_ICON_SIZE;
	int extraLargeIconSize=EXTRA_LARGE_ICON_SIZE;
	HICON hSmallIcon=NULL, hLargeIcon=NULL, hExtraLargeIcon=NULL;
	if (bNotFileName)
	{
		CAbsolutePidl pidl;
		SHFILEINFO info;
		if (SUCCEEDED(SHGetIDListFromObject(pItem,&pidl)) && SHGetFileInfo((const wchar_t*)(PIDLIST_ABSOLUTE)pidl,0,&info,sizeof(info),SHGFI_PIDL|SHGFI_SYSICONINDEX))
		{
			if (refreshFlags&INFO_SMALL_ICON)
				hSmallIcon=LoadShellIcon(info.iIcon,smallIconSize);
			if (refreshFlags&INFO_LARGE_ICON)
				hLargeIcon=LoadShellIcon(info.iIcon,largeIconSize);
			if (refreshFlags&INFO_EXTRA_LARGE_ICON)
				hExtraLargeIcon=LoadShellIcon(info.iIcon,extraLargeIconSize);
		}
		else
		{
			// fall back to the extractor
			if (refreshFlags&INFO_SMALL_ICON)
				hSmallIcon=LoadShellIcon(smallIconSize,pExtractW,location,pExtractA,locationA,index);
			if (refreshFlags&INFO_LARGE_ICON)
				hLargeIcon=LoadShellIcon(largeIconSize,pExtractW,location,pExtractA,locationA,index);
			if (refreshFlags&INFO_EXTRA_LARGE_ICON)
				hExtraLargeIcon=LoadShellIcon(extraLargeIconSize,pExtractW,location,pExtractA,locationA,index);
		}
	}
	else
	{
		DoEnvironmentSubst(location,_countof(location));
		if (refreshFlags&INFO_SMALL_ICON)
			hSmallIcon=ShExtractIcon(location,index==-1?0:index,smallIconSize);
		if (refreshFlags&INFO_LARGE_ICON)
			hLargeIcon=ShExtractIcon(location,index==-1?0:index,largeIconSize);
		if (refreshFlags&INFO_EXTRA_LARGE_ICON)
			hExtraLargeIcon=ShExtractIcon(location,index==-1?0:index,extraLargeIconSize);
	}
	if (hSmallIcon)
	{
		if (pMetroColor)
			hSmallBitmap=BitmapFromMetroIcon(hSmallIcon,SMALL_ICON_SIZE,smallIconSize,*pMetroColor);
		else
			hSmallBitmap=BitmapFromIcon(hSmallIcon,smallIconSize);
	}
	if (hLargeIcon)
	{
		if (pMetroColor)
			hLargeBitmap=BitmapFromMetroIcon(hLargeIcon,LARGE_ICON_SIZE,largeIconSize,*pMetroColor);
		else
			hLargeBitmap=BitmapFromIcon(hLargeIcon,largeIconSize);
	}
	if (hExtraLargeIcon)
	{
		if (pMetroColor)
			hExtraLargeBitmap=BitmapFromMetroIcon(hExtraLargeIcon,EXTRA_LARGE_ICON_SIZE,extraLargeIconSize,*pMetroColor);
		else
			hExtraLargeBitmap=BitmapFromIcon(hExtraLargeIcon,extraLargeIconSize);
	}
	if (pMetroColor)
		location[1]='#';
	StoreInCache(hash,bNotFileName?NULL:location,hSmallBitmap,hLargeBitmap,hExtraLargeBitmap,refreshFlags,smallIcon,largeIcon,extraLargeIcon,bTransient,false);
}

static bool SetResContextTargetSize( IResourceContext *pResContext, int size )
{
	if (GetWinVersion()>=WIN_VER_WIN10)
	{
		if (SUCCEEDED(pResContext->SetTargetSize(size)))
			return true;
	}
	RESOURCE_SCALE scale;
	if (size<=24)
		scale=RES_SCALE_80;
	else if (size<=30)
		scale=RES_SCALE_100;
	else if (size<=42)
		scale=RES_SCALE_140;
	else
		scale=RES_SCALE_180;
	return SUCCEEDED(pResContext->SetScale(scale));
}

void CItemManager::LoadMetroIcon( IShellItem *pItem, int &refreshFlags, const IconInfo *&smallIcon, const IconInfo *&largeIcon, const IconInfo *&extraLargeIcon, const DWORD *pMetroColor )
{
	unsigned int hash;
	{
		CComString pName;
		pItem->GetDisplayName(SIGDN_DESKTOPABSOLUTEPARSING,&pName);
		hash=CalcFNVHash(pName);
	}

	hash=CalcFNVHash(pMetroColor,4,hash);

	FindInCache(hash,refreshFlags,smallIcon,largeIcon,extraLargeIcon);
	if (!refreshFlags) return;

	// extract icon
	HBITMAP hSmallBitmap=NULL, hLargeBitmap=NULL, hExtraLargeBitmap=NULL;

	CComPtr<IPropertyStore> pStore;
	pItem->BindToHandler(NULL,BHID_PropertyStore,IID_IPropertyStore,(void**)&pStore);
	if (!pStore) return;

	CString packageName=GetPropertyStoreString(pStore,PKEY_MetroPackageName);
	if (packageName.IsEmpty()) return;
	CString iconName=GetPropertyStoreString(pStore,PKEY_MetroIcon);
	if (iconName.IsEmpty()) return;

	CComPtr<IResourceManager> pResManager;
	if (FAILED(pResManager.CoCreateInstance(CLSID_ResourceManager)))
		return;
	if (FAILED(pResManager->InitializeForPackage(packageName)))
		return;
	CComPtr<IResourceMap> pResMap;
	if (FAILED(pResManager->GetMainResourceMap(IID_PPV_ARGS(&pResMap))))
		return;
	CComPtr<IResourceContext> pResContext;
	if (FAILED(pResManager->GetDefaultContext(IID_PPV_ARGS(&pResContext))))
		return;
	int iconFlags=0;
	if ((refreshFlags&INFO_SMALL_ICON) && SetResContextTargetSize(pResContext,SMALL_ICON_SIZE))
	{
		CComString pLocation;
		if (SUCCEEDED(pResMap->GetFilePath(iconName,&pLocation)))
		{
			hSmallBitmap=LoadMetroBitmap0(pLocation,SMALL_ICON_SIZE,*pMetroColor);
			refreshFlags&=~INFO_SMALL_ICON;
			StoreInCache(hash,L"",hSmallBitmap,NULL,NULL,INFO_SMALL_ICON,smallIcon,largeIcon,extraLargeIcon,false,true);
		}
	}
	if ((refreshFlags&INFO_LARGE_ICON) && SetResContextTargetSize(pResContext,LARGE_ICON_SIZE))
	{
		CComString pLocation;
		if (SUCCEEDED(pResMap->GetFilePath(iconName,&pLocation)))
		{
			hLargeBitmap=LoadMetroBitmap0(pLocation,LARGE_ICON_SIZE,*pMetroColor);
			refreshFlags&=~INFO_LARGE_ICON;
			StoreInCache(hash,L"",NULL,hLargeBitmap,NULL,INFO_LARGE_ICON,smallIcon,largeIcon,extraLargeIcon,false,true);
		}
	}
	if ((refreshFlags&INFO_EXTRA_LARGE_ICON) && SetResContextTargetSize(pResContext,EXTRA_LARGE_ICON_SIZE))
	{
		CComString pLocation;
		if (SUCCEEDED(pResMap->GetFilePath(iconName,&pLocation)))
		{
			hExtraLargeBitmap=LoadMetroBitmap0(pLocation,EXTRA_LARGE_ICON_SIZE,*pMetroColor);
			refreshFlags&=~INFO_EXTRA_LARGE_ICON;
			StoreInCache(hash,L"",NULL,NULL,hExtraLargeBitmap,INFO_EXTRA_LARGE_ICON,smallIcon,largeIcon,extraLargeIcon,false,true);
		}
	}
}

void CItemManager::FindInCache( unsigned int hash, int &refreshFlags, const IconInfo *&smallIcon, const IconInfo *&largeIcon, const IconInfo *&extraLargeIcon )
{
	// look in the cache
	RWLock lock(this,false,RWLOCK_ICONS);
	std::multimap<unsigned int,IconInfo>::iterator it=m_IconInfos.find(hash);
	for (;it!=m_IconInfos.end() && it->first==hash;++it)
	{
		if ((refreshFlags&INFO_SMALL_ICON) && it->second.sizeType==ICON_SIZE_TYPE_SMALL)
		{
			smallIcon=&it->second;
			refreshFlags&=~INFO_SMALL_ICON;
		}
		if ((refreshFlags&INFO_LARGE_ICON) && it->second.sizeType==ICON_SIZE_TYPE_LARGE)
		{
			largeIcon=&it->second;
			refreshFlags&=~INFO_LARGE_ICON;
		}
		if ((refreshFlags&INFO_EXTRA_LARGE_ICON) && it->second.sizeType==ICON_SIZE_TYPE_EXTRA_LARGE)
		{
			extraLargeIcon=&it->second;
			refreshFlags&=~INFO_EXTRA_LARGE_ICON;
		}
	}
}

void CItemManager::StoreInCache( unsigned int hash, const wchar_t *path, HBITMAP hSmallBitmap, HBITMAP hLargeBitmap, HBITMAP hExtraLargeBitmap, int refreshFlags, const IconInfo *&smallIcon, const IconInfo *&largeIcon, const IconInfo *&extraLargeIcon, bool bTemp, bool bMetro )
{
	RWLock lock(this,true,RWLOCK_ICONS);
	std::multimap<unsigned int,IconInfo>::iterator it=m_IconInfos.find(hash);
	for (;it!=m_IconInfos.end() && it->first==hash;++it)
	{
		if ((refreshFlags&INFO_SMALL_ICON) && it->second.sizeType==ICON_SIZE_TYPE_SMALL)
		{
			if (hSmallBitmap)
			{
				HBITMAP old=it->second.bitmap;
				it->second.bitmap=hSmallBitmap;
				if (old) m_OldBitmaps.push_back(old);
				hSmallBitmap=NULL;
			}
			smallIcon=&it->second;
			refreshFlags&=~INFO_SMALL_ICON;
		}
		if ((refreshFlags&INFO_LARGE_ICON) && it->second.sizeType==ICON_SIZE_TYPE_LARGE)
		{
			if (hLargeBitmap)
			{
				HBITMAP old=it->second.bitmap;
				it->second.bitmap=hLargeBitmap;
				if (old) m_OldBitmaps.push_back(old);
				hLargeBitmap=NULL;
			}
			largeIcon=&it->second;
			refreshFlags&=~INFO_LARGE_ICON;
		}
		if ((refreshFlags&INFO_EXTRA_LARGE_ICON) && it->second.sizeType==ICON_SIZE_TYPE_EXTRA_LARGE)
		{
			if (hExtraLargeBitmap)
			{
				HBITMAP old=it->second.bitmap;
				it->second.bitmap=hExtraLargeBitmap;
				if (old) m_OldBitmaps.push_back(old);
				hExtraLargeBitmap=NULL;
			}
			extraLargeIcon=&it->second;
			refreshFlags&=~INFO_EXTRA_LARGE_ICON;
		}
	}

	if ((refreshFlags&INFO_SMALL_ICON) && hSmallBitmap)
	{
		IconInfo *pInfo=&m_IconInfos.emplace(hash,IconInfo())->second;
		pInfo->sizeType=ICON_SIZE_TYPE_SMALL;
		pInfo->bTemp=bTemp;
		pInfo->bMetro=bMetro;
		pInfo->SetPath(path);
		pInfo->bitmap=hSmallBitmap;
		smallIcon=pInfo;
	}
	if ((refreshFlags&INFO_LARGE_ICON) && hLargeBitmap)
	{
		IconInfo *pInfo=&m_IconInfos.emplace(hash,IconInfo())->second;
		pInfo->sizeType=ICON_SIZE_TYPE_LARGE;
		pInfo->bTemp=bTemp;
		pInfo->bMetro=bMetro;
		pInfo->SetPath(path);
		pInfo->bitmap=hLargeBitmap;
		largeIcon=pInfo;
	}
	if ((refreshFlags&INFO_EXTRA_LARGE_ICON) && hExtraLargeBitmap)
	{
		IconInfo *pInfo=&m_IconInfos.emplace(hash,IconInfo())->second;
		pInfo->sizeType=ICON_SIZE_TYPE_EXTRA_LARGE;
		pInfo->bTemp=bTemp;
		pInfo->bMetro=bMetro;
		pInfo->SetPath(path);
		pInfo->bitmap=hExtraLargeBitmap;
		extraLargeIcon=pInfo;
	}
}

void CItemManager::IconInfo::SetPath( const wchar_t *path )
{
	Assert(RWLock::ThreadHasWriteLock(RWLOCK_ICONS));
	if (path && (_wcsicmp(path,L"shell32.dll")==0 || _wcsicmp(path,L"imageres.dll")==0))
	{
		PATH=path;
		StringUpper(PATH);
		timestamp.dwHighDateTime=timestamp.dwLowDateTime=0;
		return;
	}
	if (path && path[0] && path[1]=='#')
	{
		PATH=path;
		StringUpper(PATH);
		timestamp.dwHighDateTime=timestamp.dwLowDateTime=0;
		return;
	}
	if (path && path[0] && path[1]==':' && !PathIsNetworkPath(path))
	{
		WIN32_FILE_ATTRIBUTE_DATA attributes={0};
		if (GetFileAttributesEx(path,GetFileExInfoStandard,&attributes))
		{
			PATH=path;
			StringUpper(PATH);
			timestamp=attributes.ftLastWriteTime;
			return;
		}
	}
	PATH.Empty();
	timestamp.dwHighDateTime=timestamp.dwLowDateTime=0;
}

void CItemManager::LoadCustomIcon(const wchar_t *iconPath, int iconIndex, int refreshFlags, const IconInfo *&smallIcon, const IconInfo *&largeIcon, const IconInfo *&extraLargeIcon, bool bTemp)
{
	unsigned int hash = CalcFNVHash(iconPath, CalcFNVHash(&iconIndex, 4));

	FindInCache(hash, refreshFlags, smallIcon, largeIcon, extraLargeIcon);
	if (!refreshFlags)
		return;

	auto ExtractIconAsBitmap = [&](int iconSize) -> HBITMAP {

		if (iconIndex == -65536)
			return LoadMetroBitmap0(iconPath, iconSize);

		HICON hIcon;

		if (!*iconPath)
			hIcon = (HICON)LoadImage(g_Instance, MAKEINTRESOURCE(-iconIndex), IMAGE_ICON, iconSize, iconSize, LR_DEFAULTCOLOR);
		else
			hIcon = ShExtractIcon(iconPath, iconIndex == -1 ? 0 : iconIndex, iconSize);

		if (hIcon)
			return BitmapFromIcon(hIcon, iconSize);

		return nullptr;
	};

	// extract icon
	HBITMAP hSmallBitmap = nullptr, hLargeBitmap = nullptr, hExtraLargeBitmap = nullptr;

	if (refreshFlags & INFO_SMALL_ICON)
		hSmallBitmap = ExtractIconAsBitmap(SMALL_ICON_SIZE);

	if (refreshFlags & INFO_LARGE_ICON)
		hLargeBitmap = ExtractIconAsBitmap(LARGE_ICON_SIZE);

	if (refreshFlags & INFO_EXTRA_LARGE_ICON)
		hExtraLargeBitmap = ExtractIconAsBitmap(EXTRA_LARGE_ICON_SIZE);

	StoreInCache(hash, bTemp ? nullptr : iconPath, hSmallBitmap, hLargeBitmap, hExtraLargeBitmap, refreshFlags, smallIcon, largeIcon, extraLargeIcon, bTemp, false);
}

// Recursive function to preload the items for a folder
#ifdef A4S_PRODUCT
HRESULT CItemManager::LoadFolderItems( IShellItem *pFolder, int refreshFlags, int levels, TLocation location )
{
	if (m_LoadingStage!=LOAD_LOADING)
		return HRESULT_FROM_WIN32(ERROR_CANCELLED);
	CShellItemEnumerator enumerator(pFolder);
	if (!enumerator.IsValid())
		return enumerator.GetResult()==S_FALSE?S_OK:enumerator.GetResult();

	int queueFlags=refreshFlags&INFO_ICON;
	refreshFlags&=~INFO_ICON;
	CComPtr<IShellItem> pChild;
	CAbsolutePidl childPidl;
	while (enumerator.GetNext(pChild,childPidl))
	{
		if (location==CItemManager::LOCATION_DESKTOP)
		{
			// collect only links from the desktop. this is an attempt to skip the SkyDrive item, which is causing problems.
			SFGAOF attr=0;
			const HRESULT attributesResult=
				pChild->GetAttributes(SFGAO_LINK,&attr);
			if (FAILED(attributesResult))
				return attributesResult;
			if (!(attr&SFGAO_LINK))
				continue;
		}
		if (m_LoadingStage!=LOAD_LOADING)
			return HRESULT_FROM_WIN32(ERROR_CANCELLED);

		ItemInfo *pItemInfo=const_cast<ItemInfo*>(GetItemInfo(pChild,childPidl,refreshFlags,location));
		if (!pItemInfo)
			return E_FAIL;
		if (queueFlags)
		{
			RWLock lock(this,true,RWLOCK_ITEMS);
			QueueItemInfo(pItemInfo,queueFlags);
		}

		if (levels>1)
		{
			SFGAOF flags=0;
			const HRESULT attributesResult=pChild->GetAttributes(
				SFGAO_FOLDER|SFGAO_STREAM|SFGAO_LINK,&flags);
			if (FAILED(attributesResult))
				return attributesResult;
			if ((flags&(SFGAO_FOLDER|SFGAO_STREAM|SFGAO_LINK))==SFGAO_FOLDER)
			{
				// go into subfolders but not archives or links to folders
				const HRESULT recursiveResult=LoadFolderItems(pChild,
					refreshFlags|queueFlags,levels-1,location);
				if (FAILED(recursiveResult))
					return recursiveResult;
			}
		}
	}
	const HRESULT terminal=enumerator.GetResult();
	if (m_LoadingStage!=LOAD_LOADING)
		return HRESULT_FROM_WIN32(ERROR_CANCELLED);
	return terminal==S_FALSE?S_OK:(FAILED(terminal)?terminal:E_UNEXPECTED);
}
#else
void CItemManager::LoadFolderItems( IShellItem *pFolder, int refreshFlags, int levels, TLocation location )
{
	CShellItemEnumerator enumerator(pFolder);
	if (!enumerator.IsValid()) return;

	int queueFlags=refreshFlags&INFO_ICON;
	refreshFlags&=~INFO_ICON;
	CComPtr<IShellItem> pChild;
	CAbsolutePidl childPidl;
	while (enumerator.GetNext(pChild,childPidl))
	{
		if (location==CItemManager::LOCATION_DESKTOP)
		{
			// collect only links from the desktop. this is an attempt to skip the SkyDrive item, which is causing problems.
			SFGAOF attr=0;
			if (FAILED(pChild->GetAttributes(SFGAO_LINK,&attr)) || !(attr&SFGAO_LINK))
				continue;
		}
		if (m_LoadingStage!=LOAD_LOADING) break;

		ItemInfo *pItemInfo=const_cast<ItemInfo*>(GetItemInfo(pChild,childPidl,refreshFlags,location));
		if (queueFlags)
		{
			RWLock lock(this,true,RWLOCK_ITEMS);
			QueueItemInfo(pItemInfo,queueFlags);
		}

		if (levels>1)
		{
			SFGAOF flags=0;
			if (SUCCEEDED(pChild->GetAttributes(SFGAO_FOLDER|SFGAO_STREAM|SFGAO_LINK,&flags)) && (flags&(SFGAO_FOLDER|SFGAO_STREAM|SFGAO_LINK))==SFGAO_FOLDER)
			{
				// go into subfolders but not archives or links to folders
				LoadFolderItems(pChild,refreshFlags|queueFlags,levels-1,location);
			}
		}
	}
}
#endif

CItemManager::TLocation CItemManager::DetermineLocation( const wchar_t *PATH )
{
	if (wcsncmp(PATH,m_RootStartMenu1,m_RootStartMenu1.GetLength())==0)
		return LOCATION_START_MENU;
	if (wcsncmp(PATH,m_RootStartMenu2,m_RootStartMenu2.GetLength())==0)
		return LOCATION_START_MENU;
	if (wcsncmp(PATH,m_RootStartMenu3,m_RootStartMenu3.GetLength())==0)
		return LOCATION_START_MENU;
	if (wcsncmp(PATH,m_RootGames,m_RootGames.GetLength())==0)
		return LOCATION_GAMES;
	if (wcsncmp(PATH,m_RootDesktop,m_RootDesktop.GetLength())==0)
		return LOCATION_DESKTOP;
	if (wcsncmp(PATH,m_RootTaskbar,m_RootTaskbar.GetLength())==0)
		return LOCATION_TASKBAR;
	if (wcsncmp(PATH,m_RootMetro,m_RootMetro.GetLength())==0)
		return LOCATION_METRO;
	return LOCATION_UNKNOWN;
}

// Recursive function to preload the metro apps
#ifdef A4S_PRODUCT
HRESULT CItemManager::LoadMetroItems( int refreshFlags )
{
	if (m_LoadingStage!=LOAD_LOADING)
		return HRESULT_FROM_WIN32(ERROR_CANCELLED);
	std::vector<MetroLink> links;
	std::vector<CString> nonApps10;
	const HRESULT linksResult=GetMetroLinks(links,false,&nonApps10);
	if (FAILED(linksResult))
		return linksResult;
	int queueFlags=refreshFlags&INFO_ICON;
	refreshFlags&=~queueFlags;
	for (std::vector<MetroLink>::const_iterator it=links.begin();it!=links.end();++it)
	{
		if (m_LoadingStage!=LOAD_LOADING)
			return HRESULT_FROM_WIN32(ERROR_CANCELLED);
		ItemInfo *pItemInfo=const_cast<ItemInfo*>(GetItemInfo(it->pItem,it->pidl,refreshFlags,LOCATION_METRO));
		if (!pItemInfo)
			return E_FAIL;
		if (queueFlags)
		{
			RWLock lock(this,true,RWLOCK_ITEMS);
			QueueItemInfo(pItemInfo,queueFlags);
		}
	}
	if (GetWinVersion()>=WIN_VER_WIN10)
	{
		wchar_t APPID[256];
		for (std::vector<MetroLink>::const_iterator it=links.begin();it!=links.end();++it)
		{
			if (m_LoadingStage!=LOAD_LOADING)
				return HRESULT_FROM_WIN32(ERROR_CANCELLED);
			const ItemInfo *pInfo=GetItemInfo(it->pItem,it->pidl,INFO_LINK|INFO_LINK_APPID|INFO_METRO);
			if (!pInfo)
				return E_FAIL;
			Strcpy(APPID,_countof(APPID),it->appid);
			CharUpper(APPID);
			unsigned int hash=CalcFNVHash(APPID);
			{
				RWLock lock(this,true,RWLOCK_ITEMS);
				std::map<unsigned int,const ItemInfo*>::const_iterator it2=m_MetroItemInfos10.find(hash);
				if (it2==m_MetroItemInfos10.end())
					m_MetroItemInfos10[hash]=pInfo;
				std::set<unsigned int>::iterator it3=m_BlackListInfos10.find(hash);
				if (it3!=m_BlackListInfos10.end())
					m_BlackListInfos10.erase(it3);
			}
		}

		{
			RWLock lock(this,true,RWLOCK_ITEMS);
			for (std::vector<CString>::const_iterator it=nonApps10.begin();it!=nonApps10.end();++it)
			{
				Strcpy(APPID,_countof(APPID),*it);
				CharUpper(APPID);
				unsigned int hash=CalcFNVHash(APPID);
				std::map<unsigned int,const ItemInfo*>::const_iterator it2=m_MetroItemInfos10.find(hash);
				if (it2==m_MetroItemInfos10.end())
					m_MetroItemInfos10[hash]=NULL;
				std::set<unsigned int>::iterator it3=m_BlackListInfos10.find(hash);
				if (it3!=m_BlackListInfos10.end())
					m_BlackListInfos10.erase(it3);
			}
		}
	}
	if (m_LoadingStage!=LOAD_LOADING)
		return HRESULT_FROM_WIN32(ERROR_CANCELLED);
	return S_OK;
}
#else
void CItemManager::LoadMetroItems( int refreshFlags )
{
	std::vector<MetroLink> links;
	std::vector<CString> nonApps10;
	GetMetroLinks(links,false,&nonApps10);
	int queueFlags=refreshFlags&INFO_ICON;
	refreshFlags&=~queueFlags;
	for (std::vector<MetroLink>::const_iterator it=links.begin();it!=links.end();++it)
	{
		ItemInfo *pItemInfo=const_cast<ItemInfo*>(GetItemInfo(it->pItem,it->pidl,refreshFlags,LOCATION_METRO));
		if (queueFlags)
		{
			RWLock lock(this,true,RWLOCK_ITEMS);
			QueueItemInfo(pItemInfo,queueFlags);
		}
		if (m_LoadingStage!=LOAD_LOADING) break;
	}
	if (GetWinVersion()>=WIN_VER_WIN10)
	{
		wchar_t APPID[256];
		for (std::vector<MetroLink>::const_iterator it=links.begin();it!=links.end();++it)
		{
			const ItemInfo *pInfo=GetItemInfo(it->pItem,it->pidl,INFO_LINK|INFO_LINK_APPID|INFO_METRO);
			Strcpy(APPID,_countof(APPID),it->appid);
			CharUpper(APPID);
			unsigned int hash=CalcFNVHash(APPID);
			{
				RWLock lock(this,true,RWLOCK_ITEMS);
				std::map<unsigned int,const ItemInfo*>::const_iterator it2=m_MetroItemInfos10.find(hash);
				if (it2==m_MetroItemInfos10.end())
					m_MetroItemInfos10[hash]=pInfo;
				std::set<unsigned int>::iterator it3=m_BlackListInfos10.find(hash);
				if (it3!=m_BlackListInfos10.end())
					m_BlackListInfos10.erase(it3);
			}
		}

		{
			RWLock lock(this,true,RWLOCK_ITEMS);
			for (std::vector<CString>::const_iterator it=nonApps10.begin();it!=nonApps10.end();++it)
			{
				Strcpy(APPID,_countof(APPID),*it);
				CharUpper(APPID);
				unsigned int hash=CalcFNVHash(APPID);
				std::map<unsigned int,const ItemInfo*>::const_iterator it2=m_MetroItemInfos10.find(hash);
				if (it2==m_MetroItemInfos10.end())
					m_MetroItemInfos10[hash]=NULL;
				std::set<unsigned int>::iterator it3=m_BlackListInfos10.find(hash);
				if (it3!=m_BlackListInfos10.end())
					m_BlackListInfos10.erase(it3);
			}
		}
	}
}
#endif

static KNOWNFOLDERID FOLDERID_TaskbarPinned={'TASK', 'BA', 'R', {'P', 'I', 'N', 'N', 'E', 'D'}};
static KNOWNFOLDERID FOLDERID_ClassicPinned={'CLAS', 'SI', 'C', {'P', 'I', 'N', 'N', 'E', 'D'}};
static KNOWNFOLDERID FOLDERID_MetroApps={'MET', 'R', 'O', {'A', 'P', 'P', 'S'}};

static struct
{
	KNOWNFOLDERID folder;
	int refreshFlags;
	int levels;
	CItemManager::TLocation location;
} g_CacheFolders[]=
{
	{FOLDERID_StartMenu,CItemManager::INFO_LINK|CItemManager::INFO_METRO|CItemManager::INFO_SMALL_ICON,MAX_FOLDER_LEVELS,CItemManager::LOCATION_START_MENU},
	{FOLDERID_CommonStartMenu,CItemManager::INFO_LINK|CItemManager::INFO_METRO|CItemManager::INFO_SMALL_ICON,MAX_FOLDER_LEVELS,CItemManager::LOCATION_START_MENU},
	{FOLDERID_Desktop,CItemManager::INFO_LINK,1,CItemManager::LOCATION_DESKTOP},
	{FOLDERID_PublicDesktop,CItemManager::INFO_LINK,1,CItemManager::LOCATION_DESKTOP},
	{FOLDERID_TaskbarPinned,CItemManager::INFO_LINK,1,CItemManager::LOCATION_TASKBAR},
	{FOLDERID_ClassicPinned,CItemManager::INFO_LINK|CItemManager::INFO_METRO|CItemManager::INFO_SMALL_ICON,1,CItemManager::LOCATION_START_MENU},
	{FOLDERID_MetroApps,CItemManager::INFO_LINK|CItemManager::INFO_METRO,1,CItemManager::LOCATION_METRO},
	{FOLDERID_ControlPanelFolder,CItemManager::INFO_SMALL_ICON,1,CItemManager::LOCATION_UNKNOWN},
	{FOLDERID_Favorites,CItemManager::INFO_SMALL_ICON,MAX_FOLDER_LEVELS,CItemManager::LOCATION_UNKNOWN},
};

const int NUM_WATCHED_DIRS=7;

#ifdef A4S_PRODUCT
struct A4SDirectoryIdentity
{
	CString canonicalPath;
	ULONGLONG normalizedPathHash;
	ULONGLONG volumeIdentity;
	ULONGLONG fileIdentity;
	ULONGLONG rootIdentity;

	bool operator==( const A4SDirectoryIdentity &other ) const
	{
		return canonicalPath==other.canonicalPath &&
			normalizedPathHash==other.normalizedPathHash &&
			volumeIdentity==other.volumeIdentity &&
			fileIdentity==other.fileIdentity &&
			rootIdentity==other.rootIdentity;
	}
};

struct A4SDirectoryWatch
{
	A4SDirectoryWatch( void )
	{
		directory=INVALID_HANDLE_VALUE;
		eventHandle=NULL;
		watchBit=0;
		memset(&overlapped,0,sizeof(overlapped));
		memset(buffer,0,sizeof(buffer));
	}

	HANDLE directory;
	HANDLE eventHandle;
	OVERLAPPED overlapped;
	DWORD buffer[2048]; // ReadDirectoryChangesW requires DWORD alignment.
	DWORD watchBit;
	A4SDirectoryIdentity identity;
};

static HRESULT ResolveA4SCacheFolder( int index, CAbsolutePidl &pidl,
	CComPtr<IShellItem> &pFolder, CString &filesystemPath )
{
	pidl.Clear();
	pFolder=NULL;
	filesystemPath.Empty();
	if (index<0 || index>=_countof(g_CacheFolders))
		return E_INVALIDARG;

	HRESULT result=S_OK;
	if (g_CacheFolders[index].folder==FOLDERID_TaskbarPinned)
	{
		wchar_t path[_MAX_PATH]=TASKBAR_PINNED_ROOT;
		DoEnvironmentSubst(path,_countof(path));
		result=SHParseDisplayName(path,NULL,&pidl,0,NULL);
		if (FAILED(result) || !pidl)
			return FAILED(result)?result:E_UNEXPECTED;
		result=SHCreateItemFromIDList(pidl,IID_IShellItem,(void**)&pFolder);
	}
	else if (g_CacheFolders[index].folder==FOLDERID_ClassicPinned)
	{
		if (GetSettingInt(L"PinnedPrograms")!=PINNED_PROGRAMS_PINNED)
			return HRESULT_FROM_WIN32(ERROR_NOT_READY);
		wchar_t path[_MAX_PATH];
		Strcpy(path,_countof(path),GetSettingString(L"PinnedItemsPath"));
		DoEnvironmentSubst(path,_countof(path));
		if (!path[0])
			return E_INVALIDARG;
		result=SHParseDisplayName(path,NULL,&pidl,0,NULL);
		if (FAILED(result) || !pidl)
			return FAILED(result)?result:E_UNEXPECTED;
		result=SHCreateItemFromIDList(pidl,IID_IShellItem,(void**)&pFolder);
	}
	else if (g_CacheFolders[index].folder==FOLDERID_MetroApps)
	{
		if (GetWinVersion()<WIN_VER_WIN8)
			return HRESULT_FROM_WIN32(ERROR_NOT_SUPPORTED);
		wchar_t path[_MAX_PATH]=METRO_APP_ROOT;
		DoEnvironmentSubst(path,_countof(path));
		pidl.Attach(ILCreateFromPath(path));
		if (!pidl)
			return E_FAIL;
	}
	else
	{
		result=ShGetKnownFolderIDList(g_CacheFolders[index].folder,&pidl);
		if (FAILED(result) || !pidl)
			return FAILED(result)?result:E_UNEXPECTED;
		result=SHCreateItemFromIDList(pidl,IID_IShellItem,(void**)&pFolder);
	}
	if (FAILED(result) ||
		(g_CacheFolders[index].folder!=FOLDERID_MetroApps && !pFolder))
		return FAILED(result)?result:E_UNEXPECTED;

	if (index<NUM_WATCHED_DIRS)
	{
		wchar_t path[32768]={};
		if (!SHGetPathFromIDList(pidl,path) || !path[0])
			return E_FAIL;
		filesystemPath=path;
	}
	return S_OK;
}

static HRESULT QueryA4SHandleIdentity( HANDLE handle, DWORD watchBit,
	A4SDirectoryIdentity &identity )
{
	identity.canonicalPath.Empty();
	identity.normalizedPathHash=identity.volumeIdentity=
		identity.fileIdentity=identity.rootIdentity=0;
	if (!handle || handle==INVALID_HANDLE_VALUE)
		return E_INVALIDARG;

	BY_HANDLE_FILE_INFORMATION information={};
	if (!GetFileInformationByHandle(handle,&information))
		return HRESULT_FROM_WIN32(GetLastError());
	std::vector<wchar_t> finalPath(512);
	DWORD length=GetFinalPathNameByHandle(handle,&finalPath[0],
		static_cast<DWORD>(finalPath.size()),
		FILE_NAME_NORMALIZED|VOLUME_NAME_NT);
	if (length>=finalPath.size())
	{
		finalPath.resize(static_cast<size_t>(length)+1);
		length=GetFinalPathNameByHandle(handle,&finalPath[0],
			static_cast<DWORD>(finalPath.size()),
			FILE_NAME_NORMALIZED|VOLUME_NAME_NT);
	}
	if (!length || length>=finalPath.size())
	{
		const DWORD error=GetLastError();
		return HRESULT_FROM_WIN32(error?error:ERROR_INVALID_DATA);
	}

	CharUpperBuff(&finalPath[0],length);
	identity.canonicalPath.SetString(&finalPath[0],length);
	ULONGLONG pathHash=A4SCacheState::WATCH_PATH_HASH_OFFSET;
	for (DWORD i=0;i<length;i++)
	{
		const ULONGLONG pathUnit=static_cast<unsigned short>(
			finalPath[i]=='/'?L'\\':finalPath[i]);
		pathHash=A4SCacheState::MixWatchIdentityWord(pathHash,pathUnit);
	}
	identity.normalizedPathHash=A4SCacheState::MixWatchIdentityWord(
		pathHash,length);
	identity.volumeIdentity=information.dwVolumeSerialNumber;
	identity.fileIdentity=(static_cast<ULONGLONG>(information.nFileIndexHigh)<<32)|
		information.nFileIndexLow;
	identity.rootIdentity=A4SCacheState::FoldWatchPathIdentity(
		A4SCacheState::WATCH_PATH_HASH_OFFSET,watchBit,
		identity.normalizedPathHash,identity.volumeIdentity,
		identity.fileIdentity);
	if (!identity.rootIdentity)
		identity.rootIdentity=1;
	return S_OK;
}

static HANDLE OpenA4SDirectoryHandle( const wchar_t *path, bool bOverlapped )
{
	if (!path || !path[0])
		return INVALID_HANDLE_VALUE;
	// Deliberately follow directory reparse points. The canonical target identity
	// is captured from this same handle and configuration/path redirection forces
	// a full rebuild. OPEN_REPARSE_POINT is therefore intentionally omitted.
	DWORD flags=FILE_FLAG_BACKUP_SEMANTICS;
	if (bOverlapped)
		flags|=FILE_FLAG_OVERLAPPED;
	return CreateFile(path,FILE_LIST_DIRECTORY|FILE_READ_ATTRIBUTES,
		FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,NULL,OPEN_EXISTING,
		flags,NULL);
}

static void CloseA4SDirectoryWatch( A4SDirectoryWatch &watch )
{
	if (watch.directory!=INVALID_HANDLE_VALUE)
	{
		CancelIoEx(watch.directory,&watch.overlapped);
		// OVERLAPPED and its output buffer must remain alive until cancellation
		// completes. This thread is the sole issuer/consumer for the handle.
		DWORD ignored=0;
		GetOverlappedResult(watch.directory,&watch.overlapped,&ignored,TRUE);
		CloseHandle(watch.directory);
		watch.directory=INVALID_HANDLE_VALUE;
	}
	if (watch.eventHandle)
	{
		CloseHandle(watch.eventHandle);
		watch.eventHandle=NULL;
	}
	watch.watchBit=0;
	watch.identity=A4SDirectoryIdentity();
}

static bool ArmA4SDirectoryWatch( A4SDirectoryWatch &watch )
{
	if (watch.directory==INVALID_HANDLE_VALUE || !watch.eventHandle)
		return false;
	ResetEvent(watch.eventHandle);
	memset(&watch.overlapped,0,sizeof(watch.overlapped));
	watch.overlapped.hEvent=watch.eventHandle;
	return ReadDirectoryChangesW(watch.directory,watch.buffer,
		static_cast<DWORD>(sizeof(watch.buffer)),TRUE,
		static_cast<DWORD>(A4SCacheState::RequiredDirectoryNotifyFilter()),
		NULL,&watch.overlapped,NULL)!=FALSE;
}

static bool OpenA4SDirectoryWatch( const wchar_t *path, DWORD watchBit,
	A4SDirectoryWatch &watch )
{
	CloseA4SDirectoryWatch(watch);
	watch.directory=OpenA4SDirectoryHandle(path,true);
	if (watch.directory==INVALID_HANDLE_VALUE)
		return false;
	watch.watchBit=watchBit;
	if (FAILED(QueryA4SHandleIdentity(watch.directory,watchBit,
		watch.identity)))
	{
		CloseA4SDirectoryWatch(watch);
		return false;
	}
	watch.eventHandle=CreateEvent(NULL,TRUE,FALSE,NULL);
	if (!watch.eventHandle || !ArmA4SDirectoryWatch(watch))
	{
		CloseA4SDirectoryWatch(watch);
		return false;
	}
	// Query the exact monitored handle again after ReadDirectoryChangesW is armed.
	A4SDirectoryIdentity armedIdentity;
	if (FAILED(QueryA4SHandleIdentity(watch.directory,watchBit,
		armedIdentity)) || !(armedIdentity==watch.identity))
	{
		CloseA4SDirectoryWatch(watch);
		return false;
	}
	return true;
}

static bool ConsumeAndRearmA4SDirectoryWatch( A4SDirectoryWatch &watch )
{
	DWORD bytes=0;
	if (!GetOverlappedResult(watch.directory,&watch.overlapped,&bytes,FALSE))
		return false;
	return ArmA4SDirectoryWatch(watch);
}

static bool QueryA4SConfiguredDirectoryIdentity( int index, DWORD watchBit,
	A4SDirectoryIdentity &identity )
{
	CAbsolutePidl pidl;
	CComPtr<IShellItem> pFolder;
	CString path;
	if (FAILED(ResolveA4SCacheFolder(index,pidl,pFolder,path)))
		return false;
	HANDLE directory=OpenA4SDirectoryHandle(path,false);
	if (directory==INVALID_HANDLE_VALUE)
		return false;
	const HRESULT result=QueryA4SHandleIdentity(directory,watchBit,identity);
	CloseHandle(directory);
	return SUCCEEDED(result);
}

static int FindA4SDirectoryWatch( const A4SDirectoryWatch *watches,
	int watchCount, DWORD watchBit )
{
	for (int i=0;i<watchCount;i++)
		if (watches[i].watchBit==watchBit)
			return i;
	return -1;
}

static bool VerifyA4SRequiredWatchConfiguration( DWORD requiredMask,
	const A4SDirectoryWatch *watches, int watchCount,
	A4SDirectoryIdentity *verifiedByIndex, ULONGLONG &aggregateIdentity )
{
	aggregateIdentity=A4SCacheState::MixWatchIdentityWord(
		A4SCacheState::WATCH_PATH_HASH_OFFSET,requiredMask);
	for (int index=0;index<NUM_WATCHED_DIRS;index++)
	{
		const DWORD watchBit=1U<<index;
		if (!(requiredMask&watchBit))
			continue;
		const int watchIndex=FindA4SDirectoryWatch(watches,watchCount,watchBit);
		if (watchIndex<0)
			return false;
		A4SDirectoryIdentity sameHandleIdentity;
		if (FAILED(QueryA4SHandleIdentity(watches[watchIndex].directory,
			watchBit,sameHandleIdentity)) ||
			!(sameHandleIdentity==watches[watchIndex].identity))
			return false;
		A4SDirectoryIdentity configuredIdentity;
		if (!QueryA4SConfiguredDirectoryIdentity(index,watchBit,
			configuredIdentity) || !(configuredIdentity==sameHandleIdentity))
			return false;
		if (verifiedByIndex)
			verifiedByIndex[index]=sameHandleIdentity;
		aggregateIdentity=A4SCacheState::MixWatchIdentityWord(
			aggregateIdentity,sameHandleIdentity.rootIdentity);
	}
	if (!aggregateIdentity)
		aggregateIdentity=1;
	return true;
}

static_assert(A4SCacheState::RequiredDirectoryNotifyFilter()==
	(FILE_NOTIFY_CHANGE_FILE_NAME|FILE_NOTIFY_CHANGE_DIR_NAME|
	FILE_NOTIFY_CHANGE_ATTRIBUTES|FILE_NOTIFY_CHANGE_SIZE|
	FILE_NOTIFY_CHANGE_LAST_WRITE|FILE_NOTIFY_CHANGE_CREATION|
	FILE_NOTIFY_CHANGE_SECURITY),"A4S watcher metadata filter drift");

void CItemManager::ClearA4SWatchRootTable( void )
{
	AcquireSRWLockExclusive(&m_A4SWatchRootLock);
	for (int i=0;i<m_A4SWatchRootTable.count;i++)
		m_A4SWatchRootTable.roots[i]=A4SWatchRootBinding();
	m_A4SWatchRootTable.count=0;
	ReleaseSRWLockExclusive(&m_A4SWatchRootLock);
}

void CItemManager::PublishA4SWatchRootTable(
	const A4SWatchRootBinding *roots, int count )
{
	AcquireSRWLockExclusive(&m_A4SWatchRootLock);
	for (int i=0;i<m_A4SWatchRootTable.count;i++)
		m_A4SWatchRootTable.roots[i]=A4SWatchRootBinding();
	m_A4SWatchRootTable.count=0;
	if (roots && count>0 && count<=A4S_MAX_REQUIRED_WATCH_ROOTS)
	{
		for (int i=0;i<count;i++)
			m_A4SWatchRootTable.roots[i]=roots[i];
		m_A4SWatchRootTable.count=count;
	}
	ReleaseSRWLockExclusive(&m_A4SWatchRootLock);
}

bool CItemManager::ResolveA4SItemWatchBinding( const wchar_t *canonicalPath,
	A4SWatchRootBinding &binding ) const
{
	binding=A4SWatchRootBinding();
	AcquireSRWLockShared(&m_A4SWatchRootLock);
	A4SCacheState::WatchRootView views[A4S_MAX_REQUIRED_WATCH_ROOTS]={};
	for (int i=0;i<m_A4SWatchRootTable.count;i++)
	{
		const A4SWatchRootBinding &root=m_A4SWatchRootTable.roots[i];
		views[i].watchBit=root.watchBit;
		views[i].canonicalPath=root.canonicalPath;
		views[i].rootIdentity=root.rootIdentity;
		views[i].identityGeneration=root.identityGeneration;
		views[i].sourceGeneration=root.sourceGeneration;
		views[i].filesystemBacked=true;
	}
	const int selected=A4SCacheState::SelectCanonicalWatchRoot(canonicalPath,
		views,static_cast<size_t>(m_A4SWatchRootTable.count));
	if (selected>=0)
		binding=m_A4SWatchRootTable.roots[selected];
	ReleaseSRWLockShared(&m_A4SWatchRootLock);
	return selected>=0;
}

bool CItemManager::IsA4SItemWatchBindingCurrent(
	const wchar_t *canonicalPath, const A4SWatchRootBinding &binding ) const
{
	A4SWatchRootBinding current;
	if (!ResolveA4SItemWatchBinding(canonicalPath,current))
		return false;
	A4SCacheState::WatchBindingIdentity validated={binding.watchBit,
		binding.rootIdentity,binding.identityGeneration,
		binding.sourceGeneration};
	A4SCacheState::WatchBindingIdentity observed={current.watchBit,
		current.rootIdentity,current.identityGeneration,
		current.sourceGeneration};
	return A4SCacheState::WatchBindingMatches(validated,observed);
}

bool CItemManager::GetA4SFileMetadataAndBinding( const wchar_t *path,
	FILETIME &writeTime, FILETIME &createTime, CString &canonicalPath,
	A4SWatchRootBinding &binding ) const
{
	canonicalPath.Empty();
	binding=A4SWatchRootBinding();
	HANDLE file=CreateFile(path,FILE_READ_ATTRIBUTES,
		FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,NULL,OPEN_EXISTING,
		FILE_FLAG_BACKUP_SEMANTICS,NULL);
	if (file==INVALID_HANDLE_VALUE)
		return MenuGetFileTimestamp(path,&writeTime,&createTime);
	const bool bTimestamp=GetFileTime(file,&createTime,NULL,&writeTime)!=FALSE;
	A4SDirectoryIdentity identity;
	const bool bCanonical=SUCCEEDED(QueryA4SHandleIdentity(file,0,identity));
	CloseHandle(file);
	if (!bTimestamp)
		return false;
	if (bCanonical)
	{
		canonicalPath=identity.canonicalPath;
		ResolveA4SItemWatchBinding(canonicalPath,binding);
	}
	return true;
}
#endif

void CItemManager::PreloadItemsThread( void )
{
#ifdef A4S_PRODUCT
	// Injection must become ready before background shell enumeration begins.
	// A waitable delay keeps this dormant and immediately cancellable during
	// unload; it also keeps cold Explorer startup I/O out of the hook path.
	const DWORD initialWait=WaitForSingleObject(m_ExitEvent,2000);
	if (initialWait==WAIT_OBJECT_0 || initialWait==WAIT_FAILED)
	{
		SetEvent(m_DoneEvent);
		if (initialWait==WAIT_FAILED)
			RevokeA4SFolderWatchBaseline();
		return;
	}

	const DWORD WATCH_RETRY_MIN_MS=250;
	const DWORD WATCH_RETRY_MAX_MS=30000;
	const DWORD WATCH_IDENTITY_RECHECK_MS=30000;
	const int WATCH_DRAIN_LIMIT=64;
	A4SDirectoryWatch watches[NUM_WATCHED_DIRS];
	int watchCount=0;
	DWORD armedMask=0;
	DWORD setupRequiredMask=0;
	ULONGLONG setupConfigurationGeneration=0;
	ULONGLONG setupIdentityHash=0;
	DWORD baselineRequestedLoadMask=0;
	DWORD baselineCompletedLoadMask=0;
	DWORD dirMask=0xFFFFFFFF;
	DWORD retryDelay=WATCH_RETRY_MIN_MS;
	bool bBuildWatches=true;
	bool bEstablishingBaseline=true;
	bool bInitialPreload=true;
	UINT64 preloadOperation=BeginA4SPerformanceOperation(A4S_PERF_PRELOAD);
	UINT32 preloadedFolders=0;

	auto CloseWatches=[&]()
	{
		for (int i=0;i<watchCount;i++)
			CloseA4SDirectoryWatch(watches[i]);
		watchCount=0;
		armedMask=0;
	};

	auto WaitForWatchRetry=[&](DWORD timeout)->bool
	{
		HANDLE retryHandles[2]={m_ExitEvent,m_A4SWatchRebuildEvent};
		DWORD wait=WaitForMultipleObjects(_countof(retryHandles),retryHandles,
			FALSE,timeout);
		return wait==WAIT_TIMEOUT || wait==WAIT_OBJECT_0+1;
	};

	while (1)
	{
		if (m_LoadingStage!=LOAD_LOADING)
			break;
		if (bBuildWatches)
		{
			CloseWatches();
			baselineRequestedLoadMask=0;
			baselineCompletedLoadMask=0;
			ResetEvent(m_A4SWatchRebuildEvent);
			setupRequiredMask=static_cast<DWORD>(InterlockedCompareExchange(
				&m_A4SRequiredWatchMask,0,0));
			setupConfigurationGeneration=static_cast<ULONGLONG>(
				InterlockedCompareExchange64(
					&m_A4SWatchConfigurationGeneration,0,0));
			setupIdentityHash=0;
			for (int i=0;i<NUM_WATCHED_DIRS;i++)
			{
				const DWORD watchBit=1U<<i;
				CAbsolutePidl pidl;
				CComPtr<IShellItem> pFolder;
				CString path;
				if (FAILED(ResolveA4SCacheFolder(i,pidl,pFolder,path)))
					continue;
				if (!OpenA4SDirectoryWatch(path,watchBit,watches[watchCount]))
					continue;
				armedMask|=watchBit;
				watchCount++;
			}
		}

		DWORD requestedLoadMask=0;
		DWORD completedLoadMask=0;
		for (int i=0;i<_countof(g_CacheFolders);i++)
		{
			if (m_LoadingStage!=LOAD_LOADING) break;
			const DWORD loadBit=1U<<i;
			if (!(dirMask&loadBit)) continue;
			if (!bInitialPreload && bBuildWatches && i>=NUM_WATCHED_DIRS)
				continue;
			if (g_CacheFolders[i].folder==FOLDERID_Favorites &&
				!m_bPreloadFavorites) continue;
			const bool bShouldLoad=bInitialPreload || !bBuildWatches ||
				((setupRequiredMask&loadBit)!=0);
			if (!bShouldLoad)
				continue;
			int refreshFlags=g_CacheFolders[i].refreshFlags;
			if (!m_bPreloadIcons)
				refreshFlags&=CItemManager::INFO_DATA;
			if (!refreshFlags)
				continue;
			if (g_CacheFolders[i].location==CItemManager::LOCATION_DESKTOP &&
				(GetSettingInt(L"CompatibilityFixes")&COMPATIBILITY_SKIP_DESKTOP))
			{
				// Policy deliberately excludes this optional preload root.
				continue;
			}

			// Selection makes this root part of the disk-cache transaction. Resolve,
			// enumeration, recursion, and Metro property failures must all complete
			// before this pass is allowed to replace the last good cache file.
			requestedLoadMask|=loadBit;

			CAbsolutePidl pidl;
			CComPtr<IShellItem> pFolder;
			CString filesystemPath;
			if (FAILED(ResolveA4SCacheFolder(i,pidl,pFolder,filesystemPath)))
				continue;
			const HRESULT loadResult=g_CacheFolders[i].folder!=FOLDERID_MetroApps?
				LoadFolderItems(pFolder,refreshFlags,g_CacheFolders[i].levels,
					g_CacheFolders[i].location):
				LoadMetroItems(refreshFlags);
			if (SUCCEEDED(loadResult))
			{
				completedLoadMask|=loadBit;
				preloadedFolders++;
			}
		}
		if (bEstablishingBaseline)
		{
			baselineRequestedLoadMask|=requestedLoadMask;
			baselineCompletedLoadMask=
				(baselineCompletedLoadMask&~requestedLoadMask)|completedLoadMask;
		}
		const DWORD transactionRequestedLoadMask=bEstablishingBaseline?
			baselineRequestedLoadMask:requestedLoadMask;
		const DWORD transactionCompletedLoadMask=bEstablishingBaseline?
			baselineCompletedLoadMask:completedLoadMask;
		const bool bRequiredLoadsComplete=
			A4SCacheState::RequiredFolderLoadsComplete(
				setupRequiredMask,transactionCompletedLoadMask);
		const bool bRequestedLoadsComplete=
			A4SCacheState::RequestedFolderLoadsComplete(
				transactionRequestedLoadMask,transactionCompletedLoadMask);

		if (bInitialPreload)
		{
			SetEvent(m_DoneEvent);
			if (preloadOperation)
			{
				EndA4SPerformanceOperation(A4S_PERF_PRELOAD,preloadOperation,preloadedFolders);
				preloadOperation=0;
			}
			bInitialPreload=false;
		}
		const bool bSaveCacheThisPass=transactionRequestedLoadMask &&
			bRequestedLoadsComplete;

		if (bEstablishingBaseline)
		{
			const DWORD currentRequiredMask=static_cast<DWORD>(
				InterlockedCompareExchange(&m_A4SRequiredWatchMask,0,0));
			const ULONGLONG currentConfigurationGeneration=
				static_cast<ULONGLONG>(InterlockedCompareExchange64(
					&m_A4SWatchConfigurationGeneration,0,0));
			bool bRequirementsStable=
				currentRequiredMask==setupRequiredMask &&
				currentConfigurationGeneration==setupConfigurationGeneration;
			bool bWaitApiHealthy=watchCount>0;
			bool bRearmApiHealthy=true;
			bool bDrainComplete=true;
			DWORD pendingMask=0;
			int drainCount=0;
			HANDLE drainHandles[NUM_WATCHED_DIRS];
			for (int i=0;i<watchCount;i++)
				drainHandles[i]=watches[i].eventHandle;
			while (bRequirementsStable && bWaitApiHealthy &&
				bRearmApiHealthy && drainCount<WATCH_DRAIN_LIMIT)
			{
				DWORD wait=WaitForMultipleObjects(watchCount,drainHandles,FALSE,0);
				if (wait==WAIT_TIMEOUT)
					break;
				if (wait==WAIT_FAILED || wait<WAIT_OBJECT_0 ||
					wait>=WAIT_OBJECT_0+static_cast<DWORD>(watchCount))
				{
					bWaitApiHealthy=false;
					break;
				}
				const int watch=static_cast<int>(wait-WAIT_OBJECT_0);
				pendingMask|=watches[watch].watchBit;
				drainCount++;
				if (!ConsumeAndRearmA4SDirectoryWatch(watches[watch]))
					bRearmApiHealthy=false;
			}
			if (bRequirementsStable && bWaitApiHealthy &&
				bRearmApiHealthy && drainCount==WATCH_DRAIN_LIMIT)
			{
				DWORD wait=WaitForMultipleObjects(watchCount,drainHandles,FALSE,0);
				if (wait==WAIT_FAILED)
					bWaitApiHealthy=false;
				else if (wait!=WAIT_TIMEOUT)
					bDrainComplete=false;
			}

			A4SDirectoryIdentity verifiedByIndex[NUM_WATCHED_DIRS];
			ULONGLONG confirmedIdentityHash=0;
			bool bCanonicalIdentityStable=bRequirementsStable &&
				VerifyA4SRequiredWatchConfiguration(currentRequiredMask,watches,
					watchCount,verifiedByIndex,confirmedIdentityHash);
			const DWORD finalRequiredMask=static_cast<DWORD>(
				InterlockedCompareExchange(&m_A4SRequiredWatchMask,0,0));
			const ULONGLONG finalConfigurationGeneration=
				static_cast<ULONGLONG>(InterlockedCompareExchange64(
					&m_A4SWatchConfigurationGeneration,0,0));
			bRequirementsStable=bRequirementsStable &&
				finalRequiredMask==currentRequiredMask &&
				finalConfigurationGeneration==currentConfigurationGeneration;
			if (bRequirementsStable && bCanonicalIdentityStable &&
				bWaitApiHealthy && bRearmApiHealthy && bDrainComplete)
			{
				// Close the identity-query window with one final nonblocking event
				// observation. Any signal prevents publication this iteration.
				const DWORD finalWait=WaitForMultipleObjects(watchCount,
					drainHandles,FALSE,0);
				if (finalWait==WAIT_FAILED)
					bWaitApiHealthy=false;
				else if (finalWait!=WAIT_TIMEOUT)
				{
					if (finalWait<WAIT_OBJECT_0 || finalWait>=
						WAIT_OBJECT_0+static_cast<DWORD>(watchCount))
						bWaitApiHealthy=false;
					else
					{
						const int watch=static_cast<int>(finalWait-WAIT_OBJECT_0);
						pendingMask|=watches[watch].watchBit;
						if (!ConsumeAndRearmA4SDirectoryWatch(watches[watch]))
							bRearmApiHealthy=false;
					}
				}
			}
			const bool bWatcherHealthy=bRequirementsStable && bDrainComplete &&
				A4SCacheState::RequiredFolderWatchesReady(currentRequiredMask,
					armedMask,bWaitApiHealthy,bRearmApiHealthy,pendingMask!=0);

			if (!bRequirementsStable || !bCanonicalIdentityStable ||
				!bRequiredLoadsComplete ||
				!bWaitApiHealthy ||
				!bRearmApiHealthy || !bDrainComplete ||
				!A4SCacheState::RequiredFolderWatchesReady(currentRequiredMask,
					armedMask,true,true,false))
			{
				// Missing required paths/handles, incomplete enumeration/recursion,
				// configuration drift, wait failure, or rearm failure makes every
				// cache fail closed until a complete quiet baseline exists.
				RevokeA4SFolderWatchBaseline();
				CloseWatches();
				bBuildWatches=true;
				bEstablishingBaseline=true;
				dirMask=0xFFFFFFFF;
				if (!WaitForWatchRetry(retryDelay))
					break;
				retryDelay=retryDelay>WATCH_RETRY_MAX_MS/2?
					WATCH_RETRY_MAX_MS:retryDelay*2;
				continue;
			}
			if (pendingMask)
			{
				// A required signal can represent a reparse or redirected path, not
				// only content. Re-resolve canonical identities and rebuild every
				// required handle under bounded backoff. Optional metadata signals do
				// not gate readiness and can be reloaded in place.
				if (pendingMask&currentRequiredMask)
				{
					RevokeA4SFolderWatchBaseline();
					CloseWatches();
					bBuildWatches=true;
					bEstablishingBaseline=true;
					dirMask=0xFFFFFFFF;
					if (!WaitForWatchRetry(retryDelay))
						break;
					retryDelay=retryDelay>WATCH_RETRY_MAX_MS/2?
						WATCH_RETRY_MAX_MS:retryDelay*2;
					continue;
				}
				dirMask=pendingMask;
				bBuildWatches=false;
				continue;
			}
			if (!bWatcherHealthy)
			{
				// The only remaining non-ready state would be an unprocessed signal;
				// keep the explicit guard adjacent to the publication point.
				RevokeA4SFolderWatchBaseline();
				dirMask=0xFFFFFFFF;
				bBuildWatches=true;
				continue;
			}

			setupIdentityHash=confirmedIdentityHash;
			AdvanceFolderContentGeneration();
			A4SWatchRootBinding publishedRoots[A4S_MAX_REQUIRED_WATCH_ROOTS]={};
			int publishedRootCount=0;
			const ULONGLONG identityGeneration=GetA4SPathIdentityGeneration();
			for (int i=0;i<NUM_WATCHED_DIRS;i++)
			{
				const DWORD watchBit=1U<<i;
				if (!(setupRequiredMask&watchBit))
					continue;
				A4SWatchRootBinding &root=publishedRoots[publishedRootCount++];
				root.watchBit=watchBit;
				root.canonicalPath=verifiedByIndex[i].canonicalPath;
				root.volumeIdentity=verifiedByIndex[i].volumeIdentity;
				root.fileIdentity=verifiedByIndex[i].fileIdentity;
				root.rootIdentity=verifiedByIndex[i].rootIdentity;
				root.identityGeneration=identityGeneration;
				root.sourceGeneration=setupConfigurationGeneration;
			}
			PublishA4SWatchRootTable(publishedRoots,publishedRootCount);
			InterlockedExchange64(&m_A4SPublishedWatchIdentityHash,
				static_cast<LONGLONG>(setupIdentityHash));
			InterlockedExchange64(&m_A4SPublishedWatchConfigurationGeneration,
				static_cast<LONGLONG>(setupConfigurationGeneration));
			InterlockedExchange(&m_A4SArmedWatchMask,
				static_cast<LONG>(armedMask));
			InterlockedExchange(&m_A4SFolderWatchReady,1);
			SetEvent(m_A4SFolderWatchReadyEvent);
			bEstablishingBaseline=false;
			bBuildWatches=false;
			retryDelay=WATCH_RETRY_MIN_MS;
		}

		if (bSaveCacheThisPass)
		{
			// Every selected root, including optional metadata roots, participates in
			// the transaction. Partial runtime data may remain useful, but it must not
			// overwrite the previous complete disk cache. Establishing passes reach
			// this point only after a quiet, identity-verified watcher publication.
			SaveCacheFile();
		}

		HANDLE waitHandles[NUM_WATCHED_DIRS+2];
		for (int i=0;i<watchCount;i++)
			waitHandles[i]=watches[i].eventHandle;
		waitHandles[watchCount]=m_A4SWatchRebuildEvent;
		waitHandles[watchCount+1]=m_ExitEvent;
		DWORD wait=WaitForMultipleObjects(watchCount+2,waitHandles,FALSE,
			WATCH_IDENTITY_RECHECK_MS);
		if (wait==WAIT_OBJECT_0+watchCount+1)
			break;
		if (wait==WAIT_TIMEOUT)
		{
			const DWORD currentRequiredMask=static_cast<DWORD>(
				InterlockedCompareExchange(&m_A4SRequiredWatchMask,0,0));
			const ULONGLONG currentConfigurationGeneration=
				static_cast<ULONGLONG>(InterlockedCompareExchange64(
					&m_A4SWatchConfigurationGeneration,0,0));
			ULONGLONG currentIdentityHash=0;
			const bool bIdentityCertain=VerifyA4SRequiredWatchConfiguration(
				currentRequiredMask,watches,watchCount,NULL,currentIdentityHash);
			A4SCacheState::WatchConfigurationIdentity published={
				setupRequiredMask,setupIdentityHash,
				setupConfigurationGeneration};
			A4SCacheState::WatchConfigurationIdentity observed={
				currentRequiredMask,currentIdentityHash,
				currentConfigurationGeneration};
			if (!bIdentityCertain ||
				!A4SCacheState::WatchConfigurationMatches(published,observed))
			{
				// A redirected/reparsed path, same-mask source update, or identity
				// query failure is uncertainty. Fail closed and rebuild all handles.
				RevokeA4SFolderWatchBaseline();
				CloseWatches();
				bBuildWatches=true;
				bEstablishingBaseline=true;
				dirMask=0xFFFFFFFF;
				if (!WaitForWatchRetry(retryDelay))
					break;
				retryDelay=retryDelay>WATCH_RETRY_MAX_MS/2?
					WATCH_RETRY_MAX_MS:retryDelay*2;
			}
			continue;
		}
		if (wait==WAIT_OBJECT_0+watchCount)
		{
			if (IsFolderWatchBaselineReady())
				RevokeA4SFolderWatchBaseline();
			CloseWatches();
			bBuildWatches=true;
			bEstablishingBaseline=true;
			dirMask=0xFFFFFFFF;
			continue;
		}
		if (wait==WAIT_FAILED || wait<WAIT_OBJECT_0 ||
			wait>=WAIT_OBJECT_0+static_cast<DWORD>(watchCount))
		{
			RevokeA4SFolderWatchBaseline();
			CloseWatches();
			bBuildWatches=true;
			bEstablishingBaseline=true;
			dirMask=0xFFFFFFFF;
			if (!WaitForWatchRetry(retryDelay))
				break;
			retryDelay=retryDelay>WATCH_RETRY_MAX_MS/2?
				WATCH_RETRY_MAX_MS:retryDelay*2;
			continue;
		}

		const int watch=static_cast<int>(wait-WAIT_OBJECT_0);
		dirMask=watches[watch].watchBit;
		DWORD requiredMask=static_cast<DWORD>(InterlockedCompareExchange(
			&m_A4SRequiredWatchMask,0,0));
		bool bRequiredChange=(dirMask&requiredMask)!=0;
		if (bRequiredChange)
			RevokeA4SFolderWatchBaseline();
		bool bWatchFailure=!ConsumeAndRearmA4SDirectoryWatch(watches[watch]);
		bool bRebuildRequested=false;
		bool bExitRequested=false;

		// Debounce while still servicing every watched handle. In particular, a
		// required change that arrives behind an optional metadata notification
		// revokes readiness immediately instead of remaining hidden by a sleep.
		const ULONGLONG debounceDeadline=GetTickCount64()+1000;
		while (!bWatchFailure && !bRebuildRequested && !bExitRequested)
		{
			const ULONGLONG now=GetTickCount64();
			if (now>=debounceDeadline)
				break;
			const DWORD remaining=static_cast<DWORD>(debounceDeadline-now);
			HANDLE debounceHandles[NUM_WATCHED_DIRS+2];
			for (int i=0;i<watchCount;i++)
				debounceHandles[i]=watches[i].eventHandle;
			debounceHandles[watchCount]=m_A4SWatchRebuildEvent;
			debounceHandles[watchCount+1]=m_ExitEvent;
			DWORD debounce=WaitForMultipleObjects(watchCount+2,
				debounceHandles,FALSE,remaining);
			if (debounce==WAIT_TIMEOUT)
				break;
			if (debounce==WAIT_OBJECT_0+watchCount+1)
			{
				bExitRequested=true;
				break;
			}
			if (debounce==WAIT_OBJECT_0+watchCount)
			{
				bRebuildRequested=true;
				break;
			}
			if (debounce==WAIT_FAILED || debounce<WAIT_OBJECT_0 ||
				debounce>=WAIT_OBJECT_0+static_cast<DWORD>(watchCount))
			{
				bWatchFailure=true;
				break;
			}

			const int changedWatch=static_cast<int>(debounce-WAIT_OBJECT_0);
			dirMask|=watches[changedWatch].watchBit;
			requiredMask=static_cast<DWORD>(InterlockedCompareExchange(
				&m_A4SRequiredWatchMask,0,0));
			if (!bRequiredChange && (dirMask&requiredMask)!=0)
			{
				bRequiredChange=true;
				RevokeA4SFolderWatchBaseline();
			}
			if (!ConsumeAndRearmA4SDirectoryWatch(watches[changedWatch]))
				bWatchFailure=true;
		}

		if (bExitRequested)
			break;
		if (bRebuildRequested)
		{
			// ConfigureA4SFolderWatches revoked readiness before signaling us.
			CloseWatches();
			bBuildWatches=true;
			bEstablishingBaseline=true;
			dirMask=0xFFFFFFFF;
			continue;
		}
		if (bWatchFailure)
		{
			// Either WaitForMultipleObjects or overlapped consumption/rearm failed.
			// Revoke even for an optional handle because the watch set is no longer
			// known to be complete, then rebuild using capped event-driven backoff.
			RevokeA4SFolderWatchBaseline();
			CloseWatches();
			bBuildWatches=true;
			bEstablishingBaseline=true;
			dirMask=0xFFFFFFFF;
			if (!WaitForWatchRetry(retryDelay))
				break;
			retryDelay=retryDelay>WATCH_RETRY_MAX_MS/2?
				WATCH_RETRY_MAX_MS:retryDelay*2;
			continue;
		}
		if (bRequiredChange)
		{
			CloseWatches();
			bBuildWatches=true;
			bEstablishingBaseline=true;
			dirMask=0xFFFFFFFF;
		}
		else
		{
			bBuildWatches=false;
			bEstablishingBaseline=false;
		}
	}
	RevokeA4SFolderWatchBaseline();
	CloseWatches();
	if (preloadOperation)
		EndA4SPerformanceOperation(A4S_PERF_PRELOAD,preloadOperation,preloadedFolders);
#else
	int dirCount=0;
	HANDLE handles[NUM_WATCHED_DIRS+1];
	DWORD dirMasks[NUM_WATCHED_DIRS]={0};
	DWORD dirMask=0xFFFFFFFF;
	while (1)
	{
		for (int i=0;i<_countof(g_CacheFolders);i++)
		{
			if (m_LoadingStage!=LOAD_LOADING) break;
			if (i==NUM_WATCHED_DIRS && dirMask==0xFFFFFFFF)
				SetEvent(m_DoneEvent);
			if (!(dirMask&(1<<i))) continue;
			if (g_CacheFolders[i].folder==FOLDERID_Favorites && !m_bPreloadFavorites) continue;
			CAbsolutePidl pidl;
			CComPtr<IShellItem> pFolder;
			if (g_CacheFolders[i].folder==FOLDERID_TaskbarPinned)
			{
				wchar_t path[_MAX_PATH]=TASKBAR_PINNED_ROOT;
				DoEnvironmentSubst(path,_countof(path));
				if (FAILED(SHParseDisplayName(path,NULL,&pidl,0,NULL)) || !pidl) continue;
				if (FAILED(SHCreateItemFromIDList(pidl,IID_IShellItem,(void**)&pFolder)) || !pFolder) continue;
			}
			else if (g_CacheFolders[i].folder==FOLDERID_ClassicPinned)
			{
				if (GetSettingInt(L"PinnedPrograms")!=PINNED_PROGRAMS_PINNED) continue;
				wchar_t path[_MAX_PATH];
				Strcpy(path,_countof(path),GetSettingString(L"PinnedItemsPath"));
				DoEnvironmentSubst(path,_countof(path));
				if (FAILED(SHParseDisplayName(path,NULL,&pidl,0,NULL)) || !pidl) continue;
				if (FAILED(SHCreateItemFromIDList(pidl,IID_IShellItem,(void**)&pFolder)) || !pFolder) continue;
			}
			else if (g_CacheFolders[i].folder==FOLDERID_MetroApps)
			{
				if (GetWinVersion()<WIN_VER_WIN8) continue;
				wchar_t path[_MAX_PATH]=METRO_APP_ROOT;
				DoEnvironmentSubst(path,_countof(path));
				pidl.Attach(ILCreateFromPath(path));
			}
			else
			{
				if (FAILED(ShGetKnownFolderIDList(g_CacheFolders[i].folder,&pidl)) || !pidl) continue;
				if (FAILED(SHCreateItemFromIDList(pidl,IID_IShellItem,(void**)&pFolder)) || !pFolder) continue;
			}

			wchar_t path[_MAX_PATH];
			if (i<NUM_WATCHED_DIRS && dirMask==0xFFFFFFFF &&
				SUCCEEDED(SHGetPathFromIDList(pidl,path)))
			{
				handles[dirCount]=FindFirstChangeNotification(path,TRUE,
					FILE_NOTIFY_CHANGE_FILE_NAME|FILE_NOTIFY_CHANGE_DIR_NAME|FILE_NOTIFY_CHANGE_LAST_WRITE);
				if (handles[dirCount]!=INVALID_HANDLE_VALUE)
				{
					dirMasks[dirCount]=1<<i;
					dirCount++;
				}
			}
			int refreshFlags=g_CacheFolders[i].refreshFlags;
			if (!m_bPreloadIcons)
				refreshFlags&=CItemManager::INFO_DATA;
			if (refreshFlags)
			{
				if (g_CacheFolders[i].folder!=FOLDERID_MetroApps)
				{
					if (g_CacheFolders[i].location==CItemManager::LOCATION_DESKTOP)
					{
						int compat=GetSettingInt(L"CompatibilityFixes");
						if (compat&COMPATIBILITY_SKIP_DESKTOP)
							continue;
					}
					LoadFolderItems(pFolder,refreshFlags,g_CacheFolders[i].levels,g_CacheFolders[i].location);
				}
				else
					LoadMetroItems(refreshFlags);
			}
		}
		if (dirMask==0xFFFFFFFF)
			SetEvent(m_DoneEvent);
		if (dirCount==0)
			break;
		handles[dirCount]=m_ExitEvent;
		DWORD wait=WaitForMultipleObjects(dirCount+1,handles,FALSE,INFINITE);
		if (wait<WAIT_OBJECT_0 || wait>WAIT_OBJECT_0+dirCount-1)
			break;

		int dir=wait-WAIT_OBJECT_0;
		dirMask=dirMasks[dir];
		if (!FindNextChangeNotification(handles[dir]))
			ResetEvent(handles[dir]);
		Sleep(1000);
	}
	for (int i=0;i<dirCount;i++)
		FindCloseChangeNotification(handles[i]);
#endif
}

DWORD CALLBACK CItemManager::StaticPreloadItemsThread( void *param )
{
	CItemManager *pThis=(CItemManager*)param;
	SetThreadPriority(GetCurrentThread(),THREAD_PRIORITY_IDLE);
	CoInitialize(NULL);
	pThis->m_LoadIconData[1].Init();
	wchar_t path[_MAX_PATH];
	GetModuleFileName(g_Instance,path,_countof(path));
	LoadLibrary(path); // stop the DLL from unloading
	pThis->PreloadItemsThread();
	pThis->m_LoadIconData[1].Close();
	CoUninitialize();
	FreeLibraryAndExitThread(g_Instance,0); // release the DLL
	return 0;
}

void CItemManager::RefreshInfoThread( void )
{
	WaitForSingleObject(m_StartEvent,REFRESH_DELAY);
	bool bRefresh=false;
	while (1)
	{
		HANDLE handles[2]={m_WorkEvent,m_ExitEvent};
		WaitForMultipleObjects(2,handles,FALSE,INFINITE);
		bRefresh=false;
		int t0=GetTickCount();
		while (1)
		{
			if (m_LoadingStage!=LOAD_LOADING)
				return;

			ItemInfo *pItemInfo=NULL;
			int refreshFlags=0;
			{
				Lock cleanupLock(this,LOCK_CLEANUP);
				{
					RWLock lock(this,true,RWLOCK_ITEMS);
					if (!m_ItemQueue.empty())
					{
						pItemInfo=*m_ItemQueue.begin();
						m_ItemQueue.pop_front();
					}
					else if (!m_ItemQueueLow.empty())
					{
						pItemInfo=*m_ItemQueueLow.begin();
						m_ItemQueueLow.pop_front();
					}
					else
						break;
					refreshFlags=pItemInfo->refreshFlags;
				}
				if (refreshFlags && pItemInfo->bTemp)
				{
					// temp items must be refreshed inside LOCK_CLEANUP because the cleanup process will delete all such items
					RefreshItemInfo(pItemInfo,refreshFlags,NULL,false);
					refreshFlags=0;
				}
			}
			if (refreshFlags)
			{
				// non-temp items should be refreshed outside LOCK_CLEANUP
				RefreshItemInfo(pItemInfo,refreshFlags,NULL,false);
			}

			bRefresh=true;
			int t=GetTickCount();
			if (t-t0>100)
			{
				CMenuContainer::RefreshIcons();
				t0=t;
				bRefresh=false;
			}
		}
		if (bRefresh)
			CMenuContainer::RefreshIcons();
	}
}

DWORD CALLBACK CItemManager::StaticRefreshInfoThread( void *param )
{
	CItemManager *pThis=(CItemManager*)param;
	volatile DWORD MAIN_THREAD=pThis->m_MainThreadId;
	SetThreadPriority(GetCurrentThread(),THREAD_PRIORITY_IDLE);
	CoInitialize(NULL);
	pThis->m_LoadIconData[2].Init();
	pThis->RefreshInfoThread();
	pThis->m_LoadIconData[2].Close();
	CoUninitialize();
	return MAIN_THREAD-MAIN_THREAD;
}

namespace
{
	struct IconData
	{
		unsigned int key;
		CItemManager::TIconSizeType sizeType;
		int PATHLen;
		FILETIME timestamp;
		int bitmapW, bitmapH;
	};

	struct ItemData
	{
		unsigned int key;
		FILETIME writestamp;
		FILETIME createstamp;
		bool bIconOnly;
		bool bLink;
		bool bMetroLink;
		bool bProtectedLink;
		bool bNoPin;
		bool bNoNew;
		bool bExplicitAppId;
		int pidlSize;
		int pathLen;
		int PATHLen;
		int smallIcon;
		int largeIcon;
		int extraLargeIcon;
		int validFlags;
		int targetPidlSize;
		int targetPATHLen;
		int appidLen;
		int metroNameLen;
		int iconPathLen;
		DWORD iconColor;
		int iconIndex;
	};
}

static DWORD ReadCacheFile( HANDLE file )
{
	DWORD data;
	DWORD q;
	if (!ReadFile(file,&data,4,&q,NULL) || q!=4)
		return 0;
	return data;
}

static bool ReadCacheFile( HANDLE file, IconData &data )
{
	DWORD q;
	return ReadFile(file,&data,sizeof(data),&q,NULL)!=0 && q==sizeof(data);
}

static bool ReadCacheFile( HANDLE file, ItemData &data )
{
	DWORD q;
	return ReadFile(file,&data,sizeof(data),&q,NULL)!=0 && q==sizeof(data);
}

static bool ReadCacheFile( HANDLE file, CAbsolutePidl &data, int size )
{
	if (size>0)
	{
		PIDLIST_ABSOLUTE pidl=(PIDLIST_ABSOLUTE)CoTaskMemAlloc(size);
		if (!pidl) return false;
		DWORD q;
		if (!ReadFile(file,pidl,size,&q,NULL) || q!=size)
		{
			ILFree(pidl);
			return false;
		}
		data.Attach(pidl);
	}
	return true;
}

static bool ReadCacheFile( HANDLE file, CString &data, int len )
{
	if (len>0)
	{
		DWORD q;
		if (!ReadFile(file,data.GetBuffer(len),len*2,&q,NULL) || q!=len*2)
		{
			data.Empty();
			return false;
		}
		data.ReleaseBuffer(len);
	}
	return true;
}

static bool ReadCacheFile( HANDLE file, HDC hdc, HBITMAP &data, int width, int height )
{
	std::vector<DWORD> bits(width*height);
	if (bits.empty()) return false;
	BITMAPINFO bi={0};
	bi.bmiHeader.biSize=sizeof(BITMAPINFOHEADER);
	bi.bmiHeader.biWidth=width;
	bi.bmiHeader.biHeight=height;
	bi.bmiHeader.biPlanes=1;
	bi.bmiHeader.biBitCount=32;
	DWORD q;
	int size=width*height*4;
	if (!ReadFile(file,&bits[0],size,&q,NULL) || q!=size)
		return false;
	unsigned int *pBits;
	data=CreateDIBSection(hdc,&bi,DIB_RGB_COLORS,(void**)&pBits,NULL,0);
	if (!data)
		return false;
	memcpy(pBits,&bits[0],size);
	return true;
}

static void WriteCacheFile( HANDLE file, DWORD data )
{
	DWORD q;
	WriteFile(file,&data,sizeof(data),&q,NULL);
}

static void WriteCacheFile( HANDLE file, const IconData &data )
{
	DWORD q;
	WriteFile(file,&data,sizeof(data),&q,NULL);
}

static void WriteCacheFile( HANDLE file, const ItemData &data )
{
	DWORD q;
	WriteFile(file,&data,sizeof(data),&q,NULL);
}

static void WriteCacheFile( HANDLE file, PIDLIST_ABSOLUTE data, int size )
{
	if (size>0)
	{
		DWORD q;
		WriteFile(file,data,size,&q,NULL);
	}
}

static void WriteCacheFile( HANDLE file, const CString &data )
{
	if (!data.IsEmpty())
	{
		DWORD q;
		WriteFile(file,(const wchar_t*)data,data.GetLength()*2,&q,NULL);
	}
}

static void WriteCacheFile( HANDLE file, HDC hdc, HBITMAP data, int width, int height )
{
	std::vector<DWORD> bits(width*height);
	if (bits.empty()) return;
	BITMAPINFO bi={0};
	bi.bmiHeader.biSize=sizeof(BITMAPINFOHEADER);
	bi.bmiHeader.biWidth=width;
	bi.bmiHeader.biHeight=height;
	bi.bmiHeader.biPlanes=1;
	bi.bmiHeader.biBitCount=32;
	GetDIBits(hdc,data,0,height,&bits[0],&bi,DIB_RGB_COLORS);
	DWORD q;
	WriteFile(file,&bits[0],width*height*4,&q,NULL);
}

bool CItemManager::CompareModuleTimeStamp( const CString &PATH, const FILETIME &timestamp, std::vector<ModuleInfo> &modules )
{
	for (std::vector<ModuleInfo>::const_iterator it=modules.begin();it!=modules.end();++it)
	{
		if (it->PATH==PATH)
			return (CompareFileTime(&timestamp,&it->timestamp)==0);
	}
	WIN32_FILE_ATTRIBUTE_DATA attributes={0};
	if (GetFileAttributesEx(PATH,GetFileExInfoStandard,&attributes))
	{
		ModuleInfo info={PATH,attributes.ftLastWriteTime};
		modules.push_back(info);
		return (CompareFileTime(&timestamp,&info.timestamp)==0);
	}
	else
	{
		ModuleInfo info={PATH};
		modules.push_back(info);
		return false;
	}
}

void CItemManager::LoadCacheFile( void )
{
#ifdef DISABLE_CACHE
		return;
#endif
	// load cached icons and info
	wchar_t path[_MAX_PATH]=A4S_MENU_CACHE_DB;
	DoEnvironmentSubst(path,_MAX_PATH);

	HANDLE file=CreateFile(path,GENERIC_READ,0,NULL,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,NULL);
	if (file==INVALID_HANDLE_VALUE) return;

	bool bError=true;
	DWORD tag=ReadCacheFile(file);
	std::vector<ModuleInfo> modules;
	ModuleInfo stdInfo={L"SHELL32.DLL"};
	modules.push_back(stdInfo);
	stdInfo.PATH=L"IMAGERES.DLL";
	modules.push_back(stdInfo);
	m_BlackListInfos10.clear();
	if (tag=='CLSH')
	{
		tag=ReadCacheFile(file);
		std::vector<const IconInfo*> remapIcons(1);
		remapIcons[0]=NULL;
		DWORD build;
		if (tag==GetVersionEx(g_Instance,&build) && ReadCacheFile(file)==CACHE_FILE_VERSION)
		{
			int size1=ReadCacheFile(file);
			int size2=ReadCacheFile(file);
			int size3=ReadCacheFile(file);
			int langHash=ReadCacheFile(file);
			bError=false;
			tag=ReadCacheFile(file);
			HDC hdc=CreateCompatibleDC(NULL);
			while (tag=='ICON')
			{
				IconData data;
				if (!ReadCacheFile(file,data))
				{
					bError=true;
					break;
				}
				IconInfo info;
				info.sizeType=data.sizeType;
				info.timestamp=data.timestamp;
				info.bTemp=false;
				info.bMetro=false;
				if (!ReadCacheFile(file,info.PATH,data.PATHLen))
				{
					bError=true;
					break;
				}
				if (size1==SMALL_ICON_SIZE && size2==LARGE_ICON_SIZE && size3==EXTRA_LARGE_ICON_SIZE && CompareModuleTimeStamp(info.PATH,info.timestamp,modules))
				{
					if (!ReadCacheFile(file,hdc,info.bitmap,data.bitmapW,data.bitmapH))
					{
						bError=true;
						break;
					}
					remapIcons.push_back(&m_IconInfos.emplace(data.key,info)->second);
				}
				else
				{
					int size=data.bitmapW*data.bitmapH*4;
					SetFilePointer(file,size,NULL,FILE_CURRENT);
					remapIcons.push_back(NULL);
				}
				tag=ReadCacheFile(file);
			}
			DeleteDC(hdc);
			if (tag!='ITEM')
			{
				bError=true;
			}
			else
			{
				wchar_t languages[100];
				DWORD size=0;
				DWORD len=_countof(languages);
				GetUserPreferredUILanguages(MUI_LANGUAGE_ID,&size,languages,&len);
				bError=(CalcFNVHash(languages,len*2,FNV_HASH0)!=langHash);
			}
			while (!bError && tag=='ITEM')
			{
				ItemData data;
				if (!ReadCacheFile(file,data))
				{
					bError=true;
					break;
				}
				ItemInfo &info=m_ItemInfos.emplace(data.key,ItemInfo())->second;

				info.writestamp=data.writestamp;
				info.createstamp=data.createstamp;
				info.bIconOnly=data.bIconOnly;
				info.bTemp=false;
				info.bLink=data.bLink;
				info.bMetroLink=data.bMetroLink;
				info.bProtectedLink=data.bProtectedLink;
				info.bNoPin=data.bNoPin;
				info.bNoNew=data.bNoNew;
				info.bExplicitAppId=data.bExplicitAppId;
				info.validFlags=data.validFlags;
				info.refreshFlags=0;
				info.iconColor=data.iconColor;
				info.iconIndex=data.iconIndex;

				info.smallIcon=data.smallIcon<(int)remapIcons.size()?remapIcons[data.smallIcon]:NULL;
				if (!info.smallIcon)
				{
					info.validFlags&=~INFO_SMALL_ICON;
					info.smallIcon=m_DefaultSmallIcon;
				}
				info.largeIcon=data.largeIcon<(int)remapIcons.size()?remapIcons[data.largeIcon]:NULL;
				if (!info.largeIcon)
				{
					info.validFlags&=~INFO_LARGE_ICON;
					info.largeIcon=m_DefaultLargeIcon;
				}
				info.extraLargeIcon=data.extraLargeIcon<(int)remapIcons.size()?remapIcons[data.extraLargeIcon]:NULL;
				if (!info.extraLargeIcon)
				{
					info.validFlags&=~INFO_EXTRA_LARGE_ICON;
					info.extraLargeIcon=m_DefaultExtraLargeIcon;
				}

				bError=bError || !ReadCacheFile(file,info.pidl,data.pidlSize);
				bError=bError || !ReadCacheFile(file,info.path,data.pathLen);
				bError=bError || !ReadCacheFile(file,info.PATH,data.PATHLen);
				bError=bError || !ReadCacheFile(file,info.targetPidl,data.targetPidlSize);
				bError=bError || !ReadCacheFile(file,info.targetPATH,data.targetPATHLen);
				bError=bError || !ReadCacheFile(file,info.appid,data.appidLen);
				bError=bError || !ReadCacheFile(file,info.metroName,data.metroNameLen);
				bError=bError || !ReadCacheFile(file,info.iconPath,data.iconPathLen);

				tag=ReadCacheFile(file);
			}
			if (tag=='BLAK')
			{
				int count=ReadCacheFile(file);
				for (int i=0;i<count;i++)
				{
					unsigned int hash=ReadCacheFile(file);
					m_BlackListInfos10.insert(hash);
				}
			}
		}
	}

	CloseHandle(file);
	if (bError)
	{
		m_ItemInfos.clear();
		for (std::multimap<unsigned int,IconInfo>::const_iterator it=m_IconInfos.begin();it!=m_IconInfos.end();++it)
		{
			if (it->second.bitmap)
				DeleteObject(it->second.bitmap);
		}
		m_IconInfos.clear();
		CreateDefaultIcons();
	}
}

DWORD CALLBACK CItemManager::SaveCacheFileThread( void *param )
{
	CItemManager *pThis=(CItemManager*)param;
	wchar_t path[_MAX_PATH]=A4S_MENU_DATA_DIR;
	DoEnvironmentSubst(path,_MAX_PATH);
	SHCreateDirectory(NULL,path);
	Strcat(path,_countof(path),L"\\DataCache.tmp");
	HANDLE file=CreateFile(path,GENERIC_WRITE,0,NULL,CREATE_ALWAYS,FILE_ATTRIBUTE_NORMAL,NULL);
	if (file==INVALID_HANDLE_VALUE) return 0;

	WriteCacheFile(file,'CLSH');
	WriteCacheFile(file,GetVersionEx(g_Instance));
	WriteCacheFile(file,CACHE_FILE_VERSION);
	WriteCacheFile(file,SMALL_ICON_SIZE);
	WriteCacheFile(file,LARGE_ICON_SIZE);
	WriteCacheFile(file,EXTRA_LARGE_ICON_SIZE);
	{
		wchar_t languages[100];
		DWORD size=0;
		DWORD len=_countof(languages);
		GetUserPreferredUILanguages(MUI_LANGUAGE_ID,&size,languages,&len);
		WriteCacheFile(file,CalcFNVHash(languages,len*2,FNV_HASH0));
	}

	std::vector<const std::pair<const unsigned int,IconInfo>*> iconInfos;
	{
		RWLock lock(pThis,false,RWLOCK_ICONS);
		for (std::multimap<unsigned int,IconInfo>::const_iterator it=pThis->m_IconInfos.begin();it!=pThis->m_IconInfos.end();++it)
		{
			if (!it->second.PATH.IsEmpty() && it->second.PATH[1]!='#' && it->first!=0)
				iconInfos.push_back(&*it);
		}
	}

	std::vector<const std::pair<const unsigned int,ItemInfo>*> itemInfos;
	std::vector<unsigned int> blackList;
	{
		RWLock lock(pThis,false,RWLOCK_ITEMS);
		for (std::multimap<unsigned int,ItemInfo>::const_iterator it=pThis->m_ItemInfos.begin();it!=pThis->m_ItemInfos.end();++it)
		{
			if (it->first!=0)
				itemInfos.push_back(&*it);
		}
		for (std::set<unsigned int>::const_iterator it=pThis->m_BlackListInfos10.begin();it!=pThis->m_BlackListInfos10.end();++it)
			blackList.push_back(*it);
	}

	HDC hdc=CreateCompatibleDC(NULL);
	std::map<const IconInfo*,int> remapIcons;
	int iconIndex=1;
	// save cached icons and info
	for (std::vector<const std::pair<const unsigned int,IconInfo>*>::const_iterator it=iconInfos.begin();it!=iconInfos.end();++it)
	{
		RWLock lock(pThis,false,RWLOCK_ICONS);
		if ((*it)->second.bTemp || (*it)->second.bMetro) continue;
		remapIcons[&(*it)->second]=iconIndex++;
		IconData data;
		data.key=(*it)->first;
		data.sizeType=(*it)->second.sizeType;
		data.timestamp=(*it)->second.timestamp;
		data.PATHLen=(*it)->second.PATH.GetLength();
		BITMAP bmp;
		GetObject((*it)->second.bitmap,sizeof(bmp),&bmp);
		data.bitmapW=bmp.bmWidth;
		data.bitmapH=bmp.bmHeight;

		WriteCacheFile(file,'ICON');
		WriteCacheFile(file,data);
		WriteCacheFile(file,(*it)->second.PATH);
		WriteCacheFile(file,hdc,(*it)->second.bitmap,data.bitmapW,data.bitmapH);
	}
	DeleteDC(hdc);

	FILE *log=NULL;
	if (g_LogCategories&LOG_CACHE)
	{
		wchar_t path3[_MAX_PATH]=A4S_MENU_CACHE_LOG;
		DoEnvironmentSubst(path3,_countof(path3));
		if (_wfopen_s(&log,path3,L"wb")==0)
		{
			wchar_t bom=0xFEFF;
			fwrite(&bom,2,1,log);
		}
	}
	for (std::vector<const std::pair<const unsigned int,ItemInfo>*>::const_iterator it=itemInfos.begin();it!=itemInfos.end();++it)
	{
		RWLock lock(pThis,false,RWLOCK_ITEMS);
		if ((*it)->second.bTemp || (*it)->second.path.IsEmpty()) continue;

		ItemData data;
		data.key=(*it)->first;
		data.writestamp=(*it)->second.writestamp;
		data.createstamp=(*it)->second.createstamp;
		data.bIconOnly=(*it)->second.bIconOnly;
		data.bLink=(*it)->second.bLink;
		data.bMetroLink=(*it)->second.bMetroLink;
		data.bProtectedLink=(*it)->second.bProtectedLink;
		data.bNoPin=(*it)->second.bNoPin;
		data.bNoNew=(*it)->second.bNoNew;
		data.bExplicitAppId=(*it)->second.bExplicitAppId;
		data.pidlSize=(*it)->second.GetLatestPidl()?ILGetSize((*it)->second.GetLatestPidl()):0;
		data.pathLen=(*it)->second.path.GetLength();
		data.PATHLen=(*it)->second.PATH.GetLength();

		std::map<const IconInfo*,int>::const_iterator remapIt=remapIcons.find((*it)->second.smallIcon);
		data.smallIcon=(remapIt==remapIcons.end()?0:remapIt->second);
		remapIt=remapIcons.find((*it)->second.largeIcon);
		data.largeIcon=(remapIt==remapIcons.end()?0:remapIt->second);
		remapIt=remapIcons.find((*it)->second.extraLargeIcon);
		data.extraLargeIcon=(remapIt==remapIcons.end()?0:remapIt->second);

		data.validFlags=(*it)->second.validFlags;
		data.targetPidlSize=(*it)->second.targetPidl?ILGetSize((*it)->second.targetPidl):0;
		data.targetPATHLen=(*it)->second.targetPATH.GetLength();
		data.appidLen=(*it)->second.appid.GetLength();
		data.metroNameLen=(*it)->second.metroName.GetLength();
		data.iconPathLen=(*it)->second.iconPath.GetLength();
		data.iconColor=(*it)->second.iconColor;
		data.iconIndex=(*it)->second.iconIndex;

		WriteCacheFile(file,'ITEM');
		WriteCacheFile(file,data);
		WriteCacheFile(file,(*it)->second.GetLatestPidl(),data.pidlSize);
		WriteCacheFile(file,(*it)->second.path);
		WriteCacheFile(file,(*it)->second.PATH);
		WriteCacheFile(file,(*it)->second.targetPidl,data.targetPidlSize);
		WriteCacheFile(file,(*it)->second.targetPATH);
		WriteCacheFile(file,(*it)->second.appid);
		WriteCacheFile(file,(*it)->second.metroName);
		WriteCacheFile(file,(*it)->second.iconPath);
		if (log) fwprintf(log,L"0x%08X - %s\r\n",(*it)->first,(const wchar_t*)(*it)->second.PATH);
	}
	{
		WriteCacheFile(file,'BLAK');
		WriteCacheFile(file,(DWORD)blackList.size());
		for (std::vector<unsigned int>::const_iterator it=blackList.begin();it!=blackList.end();++it)
			WriteCacheFile(file,*it);
	}
	if (log) fclose(log);

	CloseHandle(file);
	wchar_t path2[_MAX_PATH]=A4S_MENU_CACHE_DB;
	DoEnvironmentSubst(path2,_MAX_PATH);
	MoveFileEx(path,path2,MOVEFILE_REPLACE_EXISTING);
	return 0;
}

void CItemManager::SaveCacheFile( void )
{
#ifdef DISABLE_CACHE
		return;
#endif
	if (g_LogCategories&LOG_CACHE)
	{
		SaveCacheFileThread(this);
		return;
	}
	int time=GetTickCount();
	if (m_LastCacheSave && (time-m_LastCacheSave)<300000) // at least 5 minutes since the last save
		return;
	m_LastCacheSave=time;
	if (m_SaveCacheThread)
	{
		if (WaitForSingleObject(m_SaveCacheThread,0)==WAIT_TIMEOUT)
			return;
		CloseHandle(m_SaveCacheThread);
		m_SaveCacheThread=NULL;
	}
	m_SaveCacheThread=CreateThread(NULL,0,SaveCacheFileThread,this,0,NULL);
}

void CItemManager::ClearCache( void )
{
	Lock cleanupLock(this,LOCK_CLEANUP);
	RWLock itemLock(this,true,RWLOCK_ITEMS);
	RWLock iconLock(this,true,RWLOCK_ICONS);

	wchar_t path[_MAX_PATH]=A4S_MENU_CACHE_DB;
	DoEnvironmentSubst(path,_MAX_PATH);
	DeleteFile(path);

	m_BlackListInfos10.clear();
	m_ItemInfos.clear();
	for (std::multimap<unsigned int,IconInfo>::const_iterator it=m_IconInfos.begin();it!=m_IconInfos.end();++it)
	{
		if (it->second.bitmap)
			DeleteObject(it->second.bitmap);
	}
	m_IconInfos.clear();
	m_MetroItemInfos10.clear();
	CreateDefaultIcons();
	ItemInfo &item=m_ItemInfos.emplace(0,ItemInfo())->second;
	item.bIconOnly=true;
	item.smallIcon=m_DefaultSmallIcon;
	item.largeIcon=m_DefaultLargeIcon;
	item.extraLargeIcon=m_DefaultExtraLargeIcon;
}

int CItemManager::GetIconSize(TIconSizeType iconSizeType) const
{
	switch (iconSizeType)
	{
	case ICON_SIZE_TYPE_SMALL:
	case ICON_SIZE_TYPE_SMALL_METRO:
		return SMALL_ICON_SIZE;

	case ICON_SIZE_TYPE_LARGE:
	case ICON_SIZE_TYPE_LARGE_METRO:
		return LARGE_ICON_SIZE;

	case ICON_SIZE_TYPE_EXTRA_LARGE:
	case ICON_SIZE_TYPE_EXTRA_LARGE_METRO:
		return EXTRA_LARGE_ICON_SIZE;
	}

	return 0;
}

// retrieves the pidl and the SFGAO_FOLDER, SFGAO_STREAM, SFGAO_LINK flags for the path
// for paths starting with \\ tries to guess if it is a folder or a link based on the extension
HRESULT MenuParseDisplayName( const wchar_t *path, PIDLIST_ABSOLUTE *pPidl, SFGAOF *pFlags, TNetworkType *pNetworkType )
{
	if (pFlags)
		*pFlags=0;
	*pPidl=NULL;
	if (pNetworkType)
		*pNetworkType=NETWORK_NONE;
	if (PathIsNetworkPath(path))
	{
		*pPidl=SHSimpleIDListFromPath(path);
		if (!*pPidl)
			return E_FAIL;
		if (pFlags || pNetworkType)
		{
			const wchar_t *ext=PathFindExtension(path);
			if (!*ext)
			{
				if (pFlags)
					*pFlags=SFGAO_FOLDER;
				if (pNetworkType)
				{
					if (path[1]==':')
					{
						// drive:
						if (path[2]=='\\' && path[3]) // drive:\folder
							*pNetworkType=NETWORK_FOLDER;
						else
							*pNetworkType=NETWORK_DRIVE;
					}
					else if (path[0]=='\\' && path[1]=='\\')
					{
						// \\server
						const wchar_t *c=wcschr(path+2,'\\');
						if (c)
						{
							// \\server\share[\folder]
							*pNetworkType=wcschr(c+2,'\\')?NETWORK_FOLDER:NETWORK_SHARE;
						}
						else
							*pNetworkType=NETWORK_SERVER;
					}
					else
					{
						// something else
						*pNetworkType=NETWORK_FOLDER;
					}
				}
			}
			else if (_wcsicmp(ext,L".lnk")==0)
			{
				if (pFlags)
					*pFlags=SFGAO_LINK;
				if (pNetworkType)
					*pNetworkType=NETWORK_FILE;
			}
			else
			{
				if (pFlags)
					*pFlags=0;
				if (pNetworkType)
					*pNetworkType=NETWORK_FILE;
			}
		}
		return S_OK;
	}
	else
	{
		return ShParseDisplayName(path,pPidl,SFGAO_FOLDER|SFGAO_STREAM|SFGAO_LINK,pFlags);
	}
}

const wchar_t *GetDefaultNetworkIcon( TNetworkType networkType )
{
	switch (networkType)
	{
		case NETWORK_SERVER:
			return L"imageres.dll,109";
		case NETWORK_SHARE:
			return L"imageres.dll,143";
		case NETWORK_DRIVE:
			return L"imageres.dll,33";
		case NETWORK_FOLDER:
			return L"imageres.dll,3";
		default:
			return L"imageres.dll,2";
	}
}

bool MenuGetFileTimestamp( const wchar_t *path, FILETIME *pWriteTime, FILETIME *pCreateTime )
{
	if (PathIsNetworkPath(path))
	{
		memset(pWriteTime,0,sizeof(FILETIME));
		memset(pCreateTime,0,sizeof(FILETIME));
		return true;
	}
	else
	{
		WIN32_FILE_ATTRIBUTE_DATA attributes={0};
		if (!GetFileAttributesEx(path,GetFileExInfoStandard,&attributes))
		{
			memset(pWriteTime,0,sizeof(FILETIME));
			memset(pCreateTime,0,sizeof(FILETIME));
			return false;
		}
		else
		{
			*pWriteTime=attributes.ftLastWriteTime;
			*pCreateTime=attributes.ftCreationTime;
			return true;
		}
	}
}

static CString GetKnownFolderSetting( REFKNOWNFOLDERID rfid )
{
	if (rfid==FOLDERID_CommonAdminTools)
		return L"shell:::{D20EA4E1-3957-11d2-A40B-0C5020524153}";

	wchar_t path[_MAX_PATH];
	path[0]=0;
	if (rfid==FOLDERID_StartMenu)
		Strcpy(path,_countof(path),GetSettingString(L"FolderStartMenu"));

	if (rfid==FOLDERID_CommonStartMenu)
	{
		Strcpy(path,_countof(path),GetSettingString(L"FolderCommonStartMenu"));
	}
	else if (rfid==FOLDERID_Programs)
	{
		CString str=GetSettingString(L"FolderPrograms");
		if (!str.IsEmpty())
			Strcpy(path,_countof(path),str);
		else
		{
			str=GetSettingString(L"FolderStartMenu");
			if (!str.IsEmpty())
				Sprintf(path,_countof(path),L"%s\\Programs",str);
		}
	}
	else if (rfid==FOLDERID_CommonPrograms)
	{
		CString str=GetSettingString(L"FolderCommonPrograms");
		if (!str.IsEmpty())
			Strcpy(path,_countof(path),str);
		else
		{
			str=GetSettingString(L"FolderCommonStartMenu");
			if (!str.IsEmpty())
				Sprintf(path,_countof(path),L"%s\\Programs",str);
		}
	}
	else if (rfid==FOLDERID_Favorites)
	{
		if (IsEdgeDefaultBrowser())
			Strcpy(path,_countof(path),L"%LOCALAPPDATA%\\Packages\\Microsoft.MicrosoftEdge_8wekyb3d8bbwe\\AC\\MicrosoftEdge\\User\\Default\\Favorites");
	}
	if (!path[0])
		return CString();
	DoEnvironmentSubst(path,_countof(path));
	return path;
}

STDAPI ShGetKnownFolderPath( REFKNOWNFOLDERID rfid, PWSTR *pPath )
{
	CString path=GetKnownFolderSetting(rfid);
	if (!path.IsEmpty())
	{
		int size=path.GetLength()+1;
		*pPath=(PWSTR)CoTaskMemAlloc(size*2);
		if (!*pPath)
			return E_FAIL;
		Strcpy(*pPath,size,path);
		return S_OK;
	}
	return SHGetKnownFolderPath(rfid,0,NULL,pPath);
}

STDAPI ShGetKnownFolderIDList(REFKNOWNFOLDERID rfid, PIDLIST_ABSOLUTE *pPidl )
{
	CString path=GetKnownFolderSetting(rfid);
	if (!path.IsEmpty())
	{
		return ShParseDisplayName(path,pPidl,0,NULL);
	}
	return SHGetKnownFolderIDList(rfid,0,NULL,pPidl);
}

STDAPI ShGetKnownFolderItem(REFKNOWNFOLDERID rfid, IShellItem **ppItem )
{
#ifndef BUILD_SETUP
	if (rfid==FOLDERID_Games && (GetTickCount()&16))
		return E_FAIL;
#endif
	// Skip getting the Games menu on RS4
	if(IsWin10RS4() && rfid==FOLDERID_Games)
	{
		return E_FAIL;
	}
	CString path=GetKnownFolderSetting(rfid);
	if (!path.IsEmpty())
	{
		return SHCreateItemFromParsingName(path,NULL,IID_IShellItem,(void**)ppItem);
	}
	return SHGetKnownFolderItem(rfid,KF_FLAG_DEFAULT,NULL,IID_IShellItem,(void**)ppItem);
}

///////////////////////////////////////////////////////////////////////////////

#ifdef A4S_PRODUCT
CShellItemEnumerator::CShellItemEnumerator( IShellItem *pFolder )
	: m_Result(E_FAIL)
{
	if (!pFolder)
	{
		m_Result=E_INVALIDARG;
		return;
	}
	int compat=GetSettingInt(L"CompatibilityFixes");
	if (!(compat&COMPATIBILITY_ENUM_SHELLITEM))
	{
		CComPtr<IShellFolder> pFolder0;
		HRESULT hr=pFolder->BindToHandler(NULL,BHID_SFObject,IID_IShellFolder,(void**)&pFolder0);
		if (FAILED(hr) || !pFolder0)
		{
			if (SUCCEEDED(hr))
				hr=E_UNEXPECTED;
			CComQIPtr<IShellItem2> pFolder2=pFolder;
			if (pFolder2)
			{
				// The operation may fail if pFolder has a simple pidl (like from a network path). Update the shell item and try again
				pFolder2->Update(NULL);
				hr=pFolder->BindToHandler(NULL,BHID_SFObject,IID_IShellFolder,(void**)&pFolder0);
				if (FAILED(hr) || !pFolder0)
				{
					m_Result=FAILED(hr)?hr:E_UNEXPECTED;
					return;
				}
			}
			else
			{
				m_Result=hr;
				return;
			}
		}
		hr=SHGetIDListFromObject(pFolder,&m_Root);
		if (FAILED(hr) || !m_Root)
		{
			m_Result=FAILED(hr)?hr:E_UNEXPECTED;
			return;
		}
		hr=pFolder0->EnumObjects(NULL,SHCONTF_FOLDERS|SHCONTF_NONFOLDERS,(IEnumIDList**)&m_pEnumPidls);
		m_Result=(hr==S_OK && !m_pEnumPidls)?E_UNEXPECTED:hr;
	}
	else
	{
		HRESULT hr=pFolder->BindToHandler(NULL,BHID_EnumItems,IID_IEnumShellItems,(void**)&m_pEnumItems);
		if (FAILED(hr))
		{
			m_pEnumItems=NULL;
			// The operation may fail if pFolder has a simple pidl (like from a network path). Update the shell item and try again
			CComQIPtr<IShellItem2> pFolder2=pFolder;
			if (pFolder2)
			{
				pFolder2->Update(NULL);
				hr=pFolder->BindToHandler(NULL,BHID_EnumItems,IID_IEnumShellItems,(void**)&m_pEnumItems);
				if (FAILED(hr))
				{
					m_pEnumItems=NULL;
					m_Result=hr;
					return;
				}
			}
			else
			{
				m_Result=hr;
				return;
			}
		}
		if (compat&COMPATIBILITY_ENUM_FIX_PIDLS)
			SHGetIDListFromObject(pFolder,&m_Root);
		m_Result=m_pEnumItems?S_OK:(FAILED(hr)?hr:E_UNEXPECTED);
	}
}

bool CShellItemEnumerator::IsValid( void ) const
{
	return m_pEnumPidls || m_pEnumItems;
}

bool CShellItemEnumerator::GetNext( CComPtr<IShellItem> &pChild, CAbsolutePidl &childPidl )
{
	pChild=NULL;
	childPidl.Clear();
	if (m_Result!=S_OK)
		return false;
	if (m_pEnumPidls)
	{
		CAbsolutePidl child;
		const HRESULT nextResult=m_pEnumPidls->Next(1,(PITEMID_CHILD*)&child,NULL);
		if (nextResult!=S_OK || !child)
		{
			m_Result=nextResult==S_OK?E_UNEXPECTED:nextResult;
			return false;
		}

		CAbsolutePidl pidl;
		pidl.Attach(ILCombine(m_Root,child));
		if (!pidl)
		{
			m_Result=E_OUTOFMEMORY;
			return false;
		}
		const HRESULT createResult=SHCreateItemFromIDList(pidl,IID_IShellItem,
			(void**)&pChild);
		if (FAILED(createResult) || !pChild)
		{
			m_Result=FAILED(createResult)?createResult:E_UNEXPECTED;
			return false;
		}
		childPidl.Swap(pidl);
		return true;
	}
	else if (m_pEnumItems)
	{
		CComPtr<IShellItem> pChild0;
		const HRESULT nextResult=m_pEnumItems->Next(1,&pChild0,NULL);
		if (nextResult!=S_OK || !pChild0)
		{
			m_Result=nextResult==S_OK?E_UNEXPECTED:nextResult;
			return false;
		}

		CAbsolutePidl pidl0;
		const HRESULT pidlResult=SHGetIDListFromObject(pChild0,&pidl0);
		if (FAILED(pidlResult) || !pidl0)
		{
			m_Result=FAILED(pidlResult)?pidlResult:E_UNEXPECTED;
			return false;
		}

		if (m_Root)
		{
			CAbsolutePidl pidl;
			pidl.Attach(ILCombine(m_Root,ILFindLastID(pidl0)));
			if (SUCCEEDED(SHCreateItemFromIDList(pidl,IID_IShellItem,(void**)&pChild)))
			{
				childPidl.Swap(pidl);
				return true;
			}
		}

		childPidl.Swap(pidl0);
		pChild=pChild0;
		return true;
	}
	m_Result=E_UNEXPECTED;
	return false;
}
#else
CShellItemEnumerator::CShellItemEnumerator( IShellItem *pFolder )
{
	int compat=GetSettingInt(L"CompatibilityFixes");
	if (!(compat&COMPATIBILITY_ENUM_SHELLITEM))
	{
		CComPtr<IShellFolder> pFolder0;
		HRESULT hr=pFolder->BindToHandler(NULL,BHID_SFObject,IID_IShellFolder,(void**)&pFolder0);
		if (FAILED(hr))
		{
			CComQIPtr<IShellItem2> pFolder2=pFolder;
			if (pFolder2)
			{
				// The operation may fail if pFolder has a simple pidl (like from a network path). Update the shell item and try again
				pFolder2->Update(NULL);
				hr=pFolder->BindToHandler(NULL,BHID_SFObject,IID_IShellFolder,(void**)&pFolder0);
				if (FAILED(hr))
					return;
			}
		}
		if (FAILED(SHGetIDListFromObject(pFolder,&m_Root)))
			return;
		hr=pFolder0->EnumObjects(NULL,SHCONTF_FOLDERS|SHCONTF_NONFOLDERS,(IEnumIDList**)&m_pEnumPidls);
	}
	else
	{
		HRESULT hr=pFolder->BindToHandler(NULL,BHID_EnumItems,IID_IEnumShellItems,(void**)&m_pEnumItems);
		if (FAILED(hr))
		{
			m_pEnumItems=NULL;
			// The operation may fail if pFolder has a simple pidl (like from a network path). Update the shell item and try again
			CComQIPtr<IShellItem2> pFolder2=pFolder;
			if (pFolder2)
			{
				pFolder2->Update(NULL);
				hr=pFolder->BindToHandler(NULL,BHID_EnumItems,IID_IEnumShellItems,(void**)&m_pEnumItems);
				if (FAILED(hr))
				{
					m_pEnumItems=NULL;
					return;
				}
			}
		}
		if (compat&COMPATIBILITY_ENUM_FIX_PIDLS)
			SHGetIDListFromObject(pFolder,&m_Root);
	}
}

bool CShellItemEnumerator::IsValid( void ) const
{
	return m_pEnumPidls || m_pEnumItems;
}

bool CShellItemEnumerator::GetNext( CComPtr<IShellItem> &pChild, CAbsolutePidl &childPidl )
{
	pChild=NULL;
	childPidl.Clear();
	if (m_pEnumPidls)
	{
		CAbsolutePidl child;
		if (m_pEnumPidls->Next(1,(PITEMID_CHILD*)&child,NULL)!=S_OK)
			return false;

		CAbsolutePidl pidl;
		pidl.Attach(ILCombine(m_Root,child));
		if (FAILED(SHCreateItemFromIDList(pidl,IID_IShellItem,(void**)&pChild)))
			return false;
		childPidl.Swap(pidl);
		return true;
	}
	else
	{
		CComPtr<IShellItem> pChild0;
		if (m_pEnumItems->Next(1,&pChild0,NULL)!=S_OK)
			return false;

		CAbsolutePidl pidl0;
		if (FAILED(SHGetIDListFromObject(pChild0,&pidl0)))
			return false;

		if (m_Root)
		{
			CAbsolutePidl pidl;
			pidl.Attach(ILCombine(m_Root,ILFindLastID(pidl0)));
			if (SUCCEEDED(SHCreateItemFromIDList(pidl,IID_IShellItem,(void**)&pChild)))
			{
				childPidl.Swap(pidl);
				return true;
			}
		}

		childPidl.Swap(pidl0);
		pChild=pChild0;
		return true;
	}
}
#endif
