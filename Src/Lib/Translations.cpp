// Classic Shell (c) 2009-2017, Ivo Beltchev
// Open-Shell (c) 2017-2018, The Open-Shell Team
// Confidential information of Ivo Beltchev. Not for disclosure or distribution without prior written consent from the author

#include <stdafx.h>
#include "SettingsParser.h"

#ifdef A4S_PRODUCT

// A4S Menu is one fixed English environment. Only its embedded L10N resource
// participates in lookup; external translation files, language filtering and
// locale-dependent RTL selection are outside the product boundary.
static CSettingsParser g_A4STranslations;

void ParseTranslations( const wchar_t *fname, const wchar_t *forceLang )
{
	UNREFERENCED_PARAMETER(fname);
	UNREFERENCED_PARAMETER(forceLang);
	g_A4STranslations.Reset();
}

void LoadTranslationOverrides( HMODULE hModule )
{
	HRSRC resource=FindResource(hModule,MAKEINTRESOURCE(1),L"L10N");
	if (resource)
	{
		g_A4STranslations.LoadText(hModule,resource);
		g_A4STranslations.ParseText();
	}
}

const wchar_t *FindTranslation( const wchar_t *name, const wchar_t *def )
{
	return g_A4STranslations.FindSetting(name,def);
}

bool IsLanguageRTL( void )
{
	return false;
}

#else

static CSettingsParser g_Translations;
static CSettingsParser g_TranslationOverrides;
static bool g_bRTL;

// Parses the settings from an ini file. Supports UTF16, UTF8 or ANSI files
// Use forceLang for force a specific language
void ParseTranslations( const wchar_t *fname, const wchar_t *forceLang )
{
	g_Translations.Reset();

	if (fname)
	{
		if (!g_Translations.LoadText(fname)) return;
		g_Translations.ParseText();
	}

	wchar_t languages[100]={0};
	if (forceLang && *forceLang)
	{
		int len=(int)wcslen(forceLang);
		if (len>50) len=50;
		memcpy(languages,forceLang,len*2);
		memcpy(languages+len+1,L"default\0en-US\0",30);
	}
	else
	{
		ULONG size=0;
		ULONG len=_countof(languages);
		GetUserPreferredUILanguages(MUI_LANGUAGE_NAME,&size,languages,&len);
		if (len>50) len=50;
		if (len<1) len=1;
		memcpy(languages+len-1,L"default\0en-US\0",30);
	}

	g_Translations.FilterLanguages(languages);

	// Checks for right-to-left languages
	g_bRTL=false;
	LOCALESIGNATURE localesig;
	LANGID language=GetUserDefaultUILanguage();
	if (forceLang && *forceLang)
	{
		if (GetLocaleInfoEx(forceLang,LOCALE_FONTSIGNATURE,(LPWSTR)&localesig,(sizeof(localesig)/sizeof(wchar_t))) && (localesig.lsUsb[3]&0x08000000))
			g_bRTL=true;
	}
	else
	{
		if (GetLocaleInfoW(language,LOCALE_FONTSIGNATURE,(LPWSTR)&localesig,(sizeof(localesig)/sizeof(wchar_t))) && (localesig.lsUsb[3]&0x08000000))
			g_bRTL=true;
	}
}

// Loads text overrides from the given module. They must be in a "L10N" resource with ID=1
void LoadTranslationOverrides( HMODULE hModule )
{
	HRSRC hResInfo=FindResource(hModule,MAKEINTRESOURCE(1),L"L10N");
	if (hResInfo)
	{
		g_TranslationOverrides.LoadText(hModule,hResInfo);
		g_TranslationOverrides.ParseText();
	}
}

// Returns a setting with the given name. If no setting is found, returns def
const wchar_t *FindTranslation( const wchar_t *name, const wchar_t *def )
{
	const wchar_t *str=g_TranslationOverrides.FindSetting(name);
	if (str) return str;
	return g_Translations.FindSetting(name,def);
}

// Checks for right-to-left languages
bool IsLanguageRTL( void )
{
	return g_bRTL;
}

#endif
