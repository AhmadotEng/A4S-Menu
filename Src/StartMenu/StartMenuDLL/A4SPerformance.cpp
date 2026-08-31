#include "stdafx.h"
#include "A4SPerformance.h"

#ifdef A4S_PRODUCT

#include <TraceLoggingProvider.h>

TRACELOGGING_DEFINE_PROVIDER(
	g_A4SPerformanceProvider,
	"A4SMenu.Runtime",
	(0x74a9f986,0xc7ab,0x429a,0x95,0x71,0xdf,0x0f,0xb7,0xf4,0xa3,0x3c));

namespace
{
	constexpr UCHAR kTraceLevelVerbose=5;
	volatile LONG g_registered;
	volatile LONG64 g_nextOperation;
	volatile LONG64 g_openOperation;
	volatile LONG64 g_closeOperation;
	PVOID volatile g_openWindow;
	PVOID volatile g_closeWindow;
	volatile LONG g_pendingActivationSource;
	volatile LONG g_firstPaintMarked;
	volatile LONG g_openPathEnded;

	bool ProviderEnabled( void )
	{
		return InterlockedCompareExchange(&g_registered,0,0)==1 &&
			TraceLoggingProviderEnabled(g_A4SPerformanceProvider,kTraceLevelVerbose,0);
	}

	UINT64 NextOperation( void )
	{
		return static_cast<UINT64>(InterlockedIncrement64(&g_nextOperation));
	}

	void WriteEvent(A4SPerformanceEvent event, A4SPerformanceStage stage,
		UINT64 operation, UINT32 value, BOOL cacheHit, A4SActivationSource source,
		HWND window)
	{
		if (!ProviderEnabled())
			return;
		TraceLoggingWrite(g_A4SPerformanceProvider,"RuntimeEvent",
			TraceLoggingLevel(kTraceLevelVerbose),
			TraceLoggingUInt32(static_cast<UINT32>(event),"Event"),
			TraceLoggingUInt32(static_cast<UINT32>(stage),"Stage"),
			TraceLoggingUInt64(operation,"Operation"),
			TraceLoggingUInt32(value,"Value"),
			TraceLoggingBool(cacheHit!=FALSE,"CacheHit"),
			TraceLoggingUInt32(static_cast<UINT32>(source),"ActivationSource"),
			TraceLoggingPointer(window,"Window"),
			TraceLoggingUInt32(GetCurrentProcessId(),"ProcessId"),
			TraceLoggingUInt32(GetCurrentThreadId(),"ThreadId"));
	}
}

void InitializeA4SPerformance( void )
{
	// -1 is a private registration-in-progress state. Never publish the provider
	// as usable until TraceLoggingRegister has completed successfully.
	if (InterlockedCompareExchange(&g_registered,-1,0)==0)
	{
		const ULONG result=TraceLoggingRegister(g_A4SPerformanceProvider);
		InterlockedExchange(&g_registered,result==ERROR_SUCCESS?1:0);
	}
}

void CloseA4SPerformance( void )
{
	if (InterlockedExchange(&g_registered,0)!=0)
		TraceLoggingUnregister(g_A4SPerformanceProvider);
	InterlockedExchange64(&g_openOperation,0);
	InterlockedExchange64(&g_closeOperation,0);
	InterlockedExchangePointer(&g_openWindow,NULL);
	InterlockedExchangePointer(&g_closeWindow,NULL);
	InterlockedExchange(&g_firstPaintMarked,0);
	InterlockedExchange(&g_openPathEnded,0);
	InterlockedExchange(&g_pendingActivationSource,A4S_ACTIVATION_UNKNOWN);
}

UINT64 BeginA4SPerformanceOperation(A4SPerformanceEvent event, UINT32 value,
	A4SActivationSource source)
{
	if (!ProviderEnabled())
		return 0;
	const UINT64 operation=NextOperation();
	WriteEvent(event,A4S_PERF_BEGIN,operation,value,FALSE,source,NULL);
	return operation;
}

void EndA4SPerformanceOperation(A4SPerformanceEvent event, UINT64 operation,
	UINT32 value, BOOL cacheHit)
{
	WriteEvent(event,A4S_PERF_END,operation,value,cacheHit,A4S_ACTIVATION_UNKNOWN,NULL);
}

void MarkA4SPerformanceEvent(A4SPerformanceEvent event, UINT32 value,
	A4SActivationSource source)
{
	WriteEvent(event,A4S_PERF_INSTANT,CurrentA4SOpenOperation(),value,FALSE,source,NULL);
}

void SetA4SActivationSource(A4SActivationSource source)
{
	InterlockedExchange(&g_pendingActivationSource,static_cast<LONG>(source));
	MarkA4SPerformanceEvent(A4S_PERF_ACTIVATION_REQUESTED,0,source);
}

UINT64 BeginA4SOpenPath( void )
{
	const A4SActivationSource source=static_cast<A4SActivationSource>(
		InterlockedExchange(&g_pendingActivationSource,A4S_ACTIVATION_UNKNOWN));
	if (!ProviderEnabled())
		return 0;
	const UINT64 operation=NextOperation();
	InterlockedExchange64(&g_openOperation,static_cast<LONG64>(operation));
	InterlockedExchangePointer(&g_openWindow,NULL);
	InterlockedExchange(&g_firstPaintMarked,0);
	InterlockedExchange(&g_openPathEnded,0);
	WriteEvent(A4S_PERF_OPEN_PATH,A4S_PERF_BEGIN,operation,0,FALSE,source,NULL);
	return operation;
}

void AssociateA4SOpenWindow(HWND window)
{
	if (window && CurrentA4SOpenOperation())
		InterlockedExchangePointer(&g_openWindow,window);
}

UINT64 CurrentA4SOpenOperation( void )
{
	return static_cast<UINT64>(InterlockedCompareExchange64(&g_openOperation,0,0));
}

UINT64 BeginA4SClosePath(HWND window)
{
	if (!ProviderEnabled())
		return 0;
	const UINT64 existing=static_cast<UINT64>(
		InterlockedCompareExchange64(&g_closeOperation,0,0));
	if (existing)
		return existing;
	const UINT64 operation=NextOperation();
	if (InterlockedCompareExchange64(&g_closeOperation,
		static_cast<LONG64>(operation),0)!=0)
		return static_cast<UINT64>(
			InterlockedCompareExchange64(&g_closeOperation,0,0));
	InterlockedExchangePointer(&g_closeWindow,window);
	WriteEvent(A4S_PERF_CLOSE_PATH,A4S_PERF_BEGIN,operation,0,FALSE,
		A4S_ACTIVATION_UNKNOWN,NULL);
	return operation;
}

void MarkA4SFirstPaint(HWND window)
{
	const HWND associated=static_cast<HWND>(
		InterlockedCompareExchangePointer(&g_openWindow,NULL,NULL));
	if (!CurrentA4SOpenOperation() || !associated || associated!=window)
		return;
	if (InterlockedCompareExchange(&g_firstPaintMarked,1,0)==0)
		WriteEvent(A4S_PERF_FIRST_PAINT,A4S_PERF_INSTANT,CurrentA4SOpenOperation(),
			0,FALSE,A4S_ACTIVATION_UNKNOWN,window);
}

void MarkA4SWindowVisible(HWND window)
{
	const UINT64 operation=CurrentA4SOpenOperation();
	if (!operation)
		return;
	const HWND associated=static_cast<HWND>(
		InterlockedCompareExchangePointer(&g_openWindow,NULL,NULL));
	if (associated && associated!=window)
		return;
	InterlockedExchangePointer(&g_openWindow,window);
	WriteEvent(A4S_PERF_WINDOW_VISIBLE,A4S_PERF_INSTANT,operation,
		0,FALSE,A4S_ACTIVATION_UNKNOWN,window);
	if (InterlockedCompareExchange(&g_openPathEnded,1,0)==0)
		EndA4SPerformanceOperation(A4S_PERF_OPEN_PATH,operation);
}

void MarkA4SWindowHidden(HWND window)
{
	const UINT64 operation=CurrentA4SOpenOperation();
	const HWND associated=static_cast<HWND>(
		InterlockedCompareExchangePointer(&g_openWindow,NULL,NULL));
	const bool matchesOpen=!window || associated==window;
	if (operation && matchesOpen)
	{
		WriteEvent(A4S_PERF_WINDOW_HIDDEN,A4S_PERF_INSTANT,operation,0,FALSE,
			A4S_ACTIVATION_UNKNOWN,window);
		if (InterlockedCompareExchange64(&g_openOperation,0,
			static_cast<LONG64>(operation))==static_cast<LONG64>(operation))
		{
			InterlockedCompareExchangePointer(&g_openWindow,NULL,associated);
			InterlockedExchange(&g_openPathEnded,0);
			InterlockedExchange(&g_firstPaintMarked,0);
		}
	}

	const HWND closeWindow=static_cast<HWND>(
		InterlockedCompareExchangePointer(&g_closeWindow,NULL,NULL));
	if (!window || closeWindow==window)
	{
		const UINT64 closeOperation=static_cast<UINT64>(
			InterlockedExchange64(&g_closeOperation,0));
		if (closeOperation)
		{
			InterlockedExchangePointer(&g_closeWindow,NULL);
			EndA4SPerformanceOperation(A4S_PERF_CLOSE_PATH,closeOperation);
		}
	}
}

#endif
