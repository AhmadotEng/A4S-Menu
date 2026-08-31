#pragma once

#include <Windows.h>

#ifdef A4S_PRODUCT

enum A4SPerformanceEvent : UINT32
{
	A4S_PERF_ACTIVATION_REQUESTED = 1,
	A4S_PERF_OPEN_PATH = 2,
	A4S_PERF_PINNED_ENUMERATION = 3,
	A4S_PERF_ICON_LOAD = 4,
	A4S_PERF_BACKDROP_PREPARE = 5,
	A4S_PERF_WINDOW_VISIBLE = 6,
	A4S_PERF_FIRST_PAINT = 7,
	A4S_PERF_PROGRAMS_ENUMERATION = 8,
	A4S_PERF_SEARCH_INITIALIZATION = 9,
	A4S_PERF_CLOSE_PATH = 10,
	A4S_PERF_WINDOW_HIDDEN = 11,
	A4S_PERF_PRELOAD = 12,
	A4S_PERF_PAINT_RECT = 13,
};

enum A4SPerformanceStage : UINT32
{
	A4S_PERF_INSTANT = 0,
	A4S_PERF_BEGIN = 1,
	A4S_PERF_END = 2,
};

enum A4SActivationSource : UINT32
{
	A4S_ACTIVATION_UNKNOWN = 0,
	A4S_ACTIVATION_HOST = 1,
	A4S_ACTIVATION_WINDOWS_KEY = 2,
	A4S_ACTIVATION_START_BUTTON = 3,
};

// The provider is registered after Explorer-side initialization has left
// loader lock. Event writes are skipped before registration and when no ETW
// session has enabled the provider.
void InitializeA4SPerformance( void );
void CloseA4SPerformance( void );

UINT64 BeginA4SPerformanceOperation( A4SPerformanceEvent event,
	UINT32 value=0, A4SActivationSource source=A4S_ACTIVATION_UNKNOWN );
void EndA4SPerformanceOperation( A4SPerformanceEvent event, UINT64 operation,
	UINT32 value=0, BOOL cacheHit=FALSE );
void MarkA4SPerformanceEvent( A4SPerformanceEvent event, UINT32 value=0,
	A4SActivationSource source=A4S_ACTIVATION_UNKNOWN );

void SetA4SActivationSource( A4SActivationSource source );
UINT64 BeginA4SOpenPath( void );
void AssociateA4SOpenWindow( HWND window );
UINT64 BeginA4SClosePath( HWND window );
UINT64 CurrentA4SOpenOperation( void );
void MarkA4SFirstPaint( HWND window );
void MarkA4SPaintRect( HWND window, const RECT &paintRect );
void MarkA4SWindowVisible( HWND window );
void MarkA4SWindowHidden( HWND window );

class A4SPerformanceScope
{
public:
	explicit A4SPerformanceScope(A4SPerformanceEvent event, UINT32 beginValue=0) noexcept
		: m_event(event), m_operation(BeginA4SPerformanceOperation(event,beginValue)) {}
	A4SPerformanceScope(A4SPerformanceEvent event, bool enabled, UINT32 beginValue=0) noexcept
		: m_event(event), m_operation(enabled?BeginA4SPerformanceOperation(event,beginValue):0) {}
	~A4SPerformanceScope()
	{
		if (m_operation)
			EndA4SPerformanceOperation(m_event,m_operation,m_endValue,m_cacheHit);
	}
	A4SPerformanceScope(const A4SPerformanceScope &)=delete;
	A4SPerformanceScope &operator=(const A4SPerformanceScope &)=delete;
	void SetResult(UINT32 value, BOOL cacheHit=FALSE) noexcept
	{
		m_endValue=value;
		m_cacheHit=cacheHit;
	}

private:
	A4SPerformanceEvent m_event;
	UINT64 m_operation;
	UINT32 m_endValue=0;
	BOOL m_cacheHit=FALSE;
};

#else

enum A4SActivationSource : UINT32
{
	A4S_ACTIVATION_UNKNOWN = 0,
	A4S_ACTIVATION_HOST = 1,
	A4S_ACTIVATION_WINDOWS_KEY = 2,
	A4S_ACTIVATION_START_BUTTON = 3,
};

inline void InitializeA4SPerformance( void ) {}
inline void CloseA4SPerformance( void ) {}
inline void SetA4SActivationSource( A4SActivationSource ) {}
inline UINT64 BeginA4SOpenPath( void ) { return 0; }
inline void AssociateA4SOpenWindow( HWND ) {}
inline UINT64 BeginA4SClosePath( HWND ) { return 0; }
inline UINT64 CurrentA4SOpenOperation( void ) { return 0; }
inline void MarkA4SFirstPaint( HWND ) {}
inline void MarkA4SPaintRect( HWND, const RECT & ) {}
inline void MarkA4SWindowVisible( HWND ) {}
inline void MarkA4SWindowHidden( HWND ) {}

#endif
