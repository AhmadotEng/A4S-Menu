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
	volatile LONG g_pendingActivationSource;
	volatile LONG g_firstPaintMarked;

	bool ProviderEnabled( void )
	{
		return InterlockedCompareExchange(&g_registered,0,0)!=0 &&
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
	if (InterlockedCompareExchange(&g_registered,1,0)==0)
	{
		const ULONG result=TraceLoggingRegister(g_A4SPerformanceProvider);
		if (result!=ERROR_SUCCESS)
			InterlockedExchange(&g_registered,0);
	}
}

void CloseA4SPerformance( void )
{
	if (InterlockedExchange(&g_registered,0)!=0)
		TraceLoggingUnregister(g_A4SPerformanceProvider);
	InterlockedExchange64(&g_openOperation,0);
	InterlockedExchange64(&g_closeOperation,0);
	InterlockedExchange(&g_firstPaintMarked,0);
	InterlockedExchange(&g_pendingActivationSource,A4S_ACTIVATION_UNKNOWN);
}

UINT64 BeginA4SPerformanceOperation(A4SPerformanceEvent event, UINT32 value,
	A4SActivationSource source)
{
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
	const UINT64 operation=NextOperation();
	InterlockedExchange64(&g_openOperation,static_cast<LONG64>(operation));
	InterlockedExchange(&g_firstPaintMarked,0);
	WriteEvent(A4S_PERF_OPEN_PATH,A4S_PERF_BEGIN,operation,0,FALSE,source,NULL);
	return operation;
}

UINT64 CurrentA4SOpenOperation( void )
{
	return static_cast<UINT64>(InterlockedCompareExchange64(&g_openOperation,0,0));
}

UINT64 BeginA4SClosePath( void )
{
	const UINT64 operation=NextOperation();
	InterlockedExchange64(&g_closeOperation,static_cast<LONG64>(operation));
	WriteEvent(A4S_PERF_CLOSE_PATH,A4S_PERF_BEGIN,operation,0,FALSE,
		A4S_ACTIVATION_UNKNOWN,NULL);
	return operation;
}

void MarkA4SFirstPaint(HWND window)
{
	if (InterlockedCompareExchange(&g_firstPaintMarked,1,0)==0)
		WriteEvent(A4S_PERF_FIRST_PAINT,A4S_PERF_INSTANT,CurrentA4SOpenOperation(),
			0,FALSE,A4S_ACTIVATION_UNKNOWN,window);
}

void MarkA4SWindowVisible(HWND window)
{
	WriteEvent(A4S_PERF_WINDOW_VISIBLE,A4S_PERF_INSTANT,CurrentA4SOpenOperation(),
		0,FALSE,A4S_ACTIVATION_UNKNOWN,window);
	EndA4SPerformanceOperation(A4S_PERF_OPEN_PATH,CurrentA4SOpenOperation());
}

void MarkA4SWindowHidden(HWND window)
{
	const UINT64 operation=CurrentA4SOpenOperation();
	WriteEvent(A4S_PERF_WINDOW_HIDDEN,A4S_PERF_INSTANT,operation,0,FALSE,
		A4S_ACTIVATION_UNKNOWN,window);
	InterlockedCompareExchange64(&g_openOperation,0,static_cast<LONG64>(operation));
	const UINT64 closeOperation=static_cast<UINT64>(
		InterlockedExchange64(&g_closeOperation,0));
	if (closeOperation)
		EndA4SPerformanceOperation(A4S_PERF_CLOSE_PATH,closeOperation);
}

#endif
