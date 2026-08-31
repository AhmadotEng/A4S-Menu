// Classic Shell (c) 2009-2017, Ivo Beltchev
// Open-Shell (c) 2017-2018, The Open-Shell Team
// Confidential information of Ivo Beltchev. Not for disclosure or distribution without prior written consent from the author

#pragma once

#include "ItemManager.h"
#include "DragDrop.h"

class CMenuContainer;

class CProgramsTree: public IDropTarget, public CWindowImpl<CProgramsTree>
{
public:
	enum {
		TVM_REFRESH=WM_APP+1,
#ifdef A4S_PRODUCT
		TVM_A4S_SNAPSHOT_READY=WM_APP+2,
#endif
		TIMER_HOVER=1,
		TIMER_A4S_SCROLLBAR_IDLE=2,
	};

	struct CTreeItem
	{
		CString name;
		unsigned int nameHashProg; // hash if the item is directly in the Programs folder
		unsigned int nameHash; // hash if the item is not directly in the Programs folder
		const CItemManager::ItemInfo *pItemInfo1;
		const CItemManager::ItemInfo *pItemInfo2;
		bool bFolder;
		bool bEmpty;
		bool bApps; // the Apps folder item
		bool bApp; // App inside the Apps folder
		bool bAutoSort;
		bool bPrograms; // this item is directly in the Programs folder
		bool bNew;
		int order;
		unsigned int folderHash; // only if bFolder

		CTreeItem( void ) { nameHash=nameHashProg=0; pItemInfo1=pItemInfo2=NULL; bFolder=bEmpty=bApps=bApp=bAutoSort=bPrograms=bNew=false; order=0; folderHash=0; }
		void SetName( const wchar_t *_name, bool bNoExtensions )
		{
			if (bNoExtensions)
			{
				const wchar_t *end=wcsrchr(_name,'.');
				if (end)
				{
					name=CString(_name,(int)(end-_name));
					return;
				}
			}
			name=_name;
		}

		bool operator==( const CTreeItem &item ) const { return pItemInfo1==item.pItemInfo1 && pItemInfo2==item.pItemInfo2 && name==item.name && bFolder==item.bFolder && (bFolder || bNew==item.bNew); }
		unsigned int GetNameHash( void ) const { return bPrograms?nameHashProg:nameHash; }
	};

	BEGIN_MSG_MAP( CProgramsTree )
		MESSAGE_HANDLER( WM_DESTROY, OnDestroy )
		MESSAGE_HANDLER( WM_KEYDOWN, OnKeyDown )
		MESSAGE_HANDLER( WM_SYSKEYDOWN, OnSysKeyDown )
		MESSAGE_HANDLER( WM_CHAR, OnChar )
		MESSAGE_HANDLER( WM_SETFOCUS, OnSetFocus )
		MESSAGE_HANDLER( WM_MOUSEMOVE, OnMouseMove )
		MESSAGE_HANDLER( WM_MOUSELEAVE, OnMouseLeave )
		MESSAGE_HANDLER( WM_NCMOUSEMOVE, OnNcMouseMove )
		MESSAGE_HANDLER( WM_NCMOUSELEAVE, OnNcMouseLeave )
		MESSAGE_HANDLER( WM_MOUSEACTIVATE, OnMouseActivate )
		MESSAGE_HANDLER( WM_NCLBUTTONDOWN, OnNcLButtonDown)
		MESSAGE_HANDLER( WM_TIMER, OnTimer )
		MESSAGE_HANDLER( WM_ERASEBKGND, OnEraseBkgnd )
		MESSAGE_HANDLER( WM_PAINT, OnPaint )
		MESSAGE_HANDLER( WM_CONTEXTMENU, OnContextMenu )
		MESSAGE_HANDLER( WM_HSCROLL, OnScroll )
		MESSAGE_HANDLER( WM_VSCROLL, OnScroll )
		MESSAGE_HANDLER( WM_MOUSEWHEEL, OnScroll )
		MESSAGE_HANDLER( TVM_SETINSERTMARK, OnSetInsertMark )
		MESSAGE_HANDLER( TVM_REFRESH, OnRefresh )
#ifdef A4S_PRODUCT
		MESSAGE_HANDLER( TVM_A4S_SNAPSHOT_READY, OnA4SSnapshotReady )
#endif
		REFLECTED_NOTIFY_CODE_HANDLER( TVN_DELETEITEM, OnDeleteItem )
		REFLECTED_NOTIFY_CODE_HANDLER( TVN_ITEMEXPANDING, OnItemExpanding )
		REFLECTED_NOTIFY_CODE_HANDLER( TVN_SINGLEEXPAND, OnSingleExpand )
		REFLECTED_NOTIFY_CODE_HANDLER( TVN_BEGINDRAG, OnBeginDrag )
		REFLECTED_NOTIFY_CODE_HANDLER( TVN_BEGINRDRAG, OnBeginDrag )
		REFLECTED_NOTIFY_CODE_HANDLER( TVN_BEGINLABELEDIT, OnBeginLabelEdit )
		REFLECTED_NOTIFY_CODE_HANDLER( TVN_ENDLABELEDIT, OnEndLabelEdit )
		REFLECTED_NOTIFY_CODE_HANDLER( TVN_GETINFOTIP, OnGetInfoTip )
		REFLECTED_NOTIFY_CODE_HANDLER( NM_CLICK, OnClick )
		REFLECTED_NOTIFY_CODE_HANDLER( NM_RCLICK, OnRClick )
	END_MSG_MAP()

	CProgramsTree( void );

	~CProgramsTree( void )
	{
		Assert(m_RefCount==0);
	}
	void Create( CMenuContainer *pOwner );
#ifdef A4S_PRODUCT
	// Starts the process-wide Programs root snapshot while the normal menu is
	// becoming visible. The worker never publishes apartment-bound objects.
	static void PreloadA4SItems( bool bNoCommonFolders );
	// Cancels enumeration and proves no worker can still reference ItemManager
	// before the Explorer-side manager shutdown transaction continues.
	static bool ShutdownA4SItems( DWORD timeout );
#endif

	virtual WNDPROC GetWindowProc( void ) { return CustomWindowProc; }
	static LRESULT CALLBACK CustomWindowProc(HWND hWnd, UINT uMsg, WPARAM wParam, LPARAM lParam);

	void DeleteAllItems( void );
	// A4S returns false until a complete current-generation root snapshot has
	// been merged. Upstream construction is synchronous and always returns true.
	bool CreateItems( void );
	void SelectItem( int y );
	void SelectFirst( void );
	void SelectLast( void );
	void ClearAllNew( void );

	// reorders the tree elements and saves the order in registry
	void OrderElements( HTREEITEM hChild, HTREEITEM hParent, const std::vector<unsigned int> &order, bool bAutoSort, bool bResort );
	// saves the item order by replacing the item with the new info
	void SaveRenamedOrder( HTREEITEM hItem, const CItemManager::ItemInfo *pNewInfo );

	// IUnknown
	virtual STDMETHODIMP QueryInterface( REFIID riid, void **ppvObject )
	{
		Assert(0);
		*ppvObject=NULL;
		return E_FAIL;
	}

	virtual ULONG STDMETHODCALLTYPE AddRef( void ) 
	{ 
		return InterlockedIncrement(&m_RefCount);
	}

	virtual ULONG STDMETHODCALLTYPE Release( void )
	{
		long nTemp=InterlockedDecrement(&m_RefCount);
		if (!nTemp) delete this;
		return nTemp;
	}

	// IDropTarget
	virtual HRESULT STDMETHODCALLTYPE DragEnter( IDataObject *pDataObj, DWORD grfKeyState, POINTL pt, DWORD *pdwEffect );
	virtual HRESULT STDMETHODCALLTYPE DragOver( DWORD grfKeyState, POINTL pt, DWORD *pdwEffect );
	virtual HRESULT STDMETHODCALLTYPE DragLeave( void );
	virtual HRESULT STDMETHODCALLTYPE Drop( IDataObject *pDataObj, DWORD grfKeyState, POINTL pt, DWORD *pdwEffect );

	static void DrawScrollbarBackground( HDC hdc, int iPartId, int iStateId, LPCRECT pRect );

	void DrawTree( HDC hdc, const RECT &drawRect );

protected:
	LRESULT OnDestroy( UINT uMsg, WPARAM wParam, LPARAM lParam, BOOL& bHandled );
	LRESULT OnKeyDown( UINT uMsg, WPARAM wParam, LPARAM lParam, BOOL& bHandled );
	LRESULT OnSysKeyDown( UINT uMsg, WPARAM wParam, LPARAM lParam, BOOL& bHandled );
	LRESULT OnChar( UINT uMsg, WPARAM wParam, LPARAM lParam, BOOL& bHandled );
	LRESULT OnSetFocus( UINT uMsg, WPARAM wParam, LPARAM lParam, BOOL& bHandled );
	LRESULT OnMouseMove( UINT uMsg, WPARAM wParam, LPARAM lParam, BOOL& bHandled );
	LRESULT OnMouseLeave( UINT uMsg, WPARAM wParam, LPARAM lParam, BOOL& bHandled );
	LRESULT OnNcMouseMove( UINT uMsg, WPARAM wParam, LPARAM lParam, BOOL& bHandled );
	LRESULT OnNcMouseLeave( UINT uMsg, WPARAM wParam, LPARAM lParam, BOOL& bHandled );
	LRESULT OnMouseActivate( UINT uMsg, WPARAM wParam, LPARAM lParam, BOOL& bHandled );
	LRESULT OnNcLButtonDown( UINT uMsg, WPARAM wParam, LPARAM lParam, BOOL& bHandled );
	LRESULT OnTimer( UINT uMsg, WPARAM wParam, LPARAM lParam, BOOL& bHandled );
	LRESULT OnPaint( UINT uMsg, WPARAM wParam, LPARAM lParam, BOOL& bHandled );
	LRESULT OnEraseBkgnd( UINT uMsg, WPARAM wParam, LPARAM lParam, BOOL& bHandled ) { return 1; }
	LRESULT OnContextMenu( UINT uMsg, WPARAM wParam, LPARAM lParam, BOOL& bHandled );
	LRESULT OnScroll( UINT uMsg, WPARAM wParam, LPARAM lParam, BOOL& bHandled );
	LRESULT OnSetInsertMark( UINT uMsg, WPARAM wParam, LPARAM lParam, BOOL& bHandled );
	LRESULT OnRefresh( UINT uMsg, WPARAM wParam, LPARAM lParam, BOOL& bHandled );
	LRESULT OnDeleteItem( int idCtrl, LPNMHDR pnmh, BOOL& bHandled );
	LRESULT OnItemExpanding( int idCtrl, LPNMHDR pnmh, BOOL& bHandled );
	LRESULT OnSingleExpand( int idCtrl, LPNMHDR pnmh, BOOL& bHandled );
	LRESULT OnBeginDrag( int idCtrl, LPNMHDR pnmh, BOOL& bHandled );
	LRESULT OnBeginLabelEdit( int idCtrl, LPNMHDR pnmh, BOOL& bHandled );
	LRESULT OnEndLabelEdit( int idCtrl, LPNMHDR pnmh, BOOL& bHandled );
	LRESULT OnGetInfoTip( int idCtrl, LPNMHDR pnmh, BOOL& bHandled );
	LRESULT OnClick( int idCtrl, LPNMHDR pnmh, BOOL& bHandled );
	LRESULT OnRClick( int idCtrl, LPNMHDR pnmh, BOOL& bHandled );
	virtual void OnFinalMessage( HWND ) { Release(); }

private:
	DWORD m_RefCount;
	CMenuContainer *m_pOwner;
	HIMAGELIST m_ImageList;
	bool m_bHoverTimer;
	bool m_bTrackMouse;
	bool m_bRefreshPosted;
	bool m_bAutoSort;
	bool m_bDragApps;
	bool m_bInsertAfter;
	bool m_bA4SScrollbarHover;
	bool m_bA4SScrollbarPulse;
	DWORD m_A4SScrollbarInputCount;
#ifdef A4S_PRODUCT
	const CItemManager::ItemInfo *m_pA4SPendingSelectItem;
	LONG m_A4SInstanceCookie;
#endif
	POINT m_LastMousePos;
	int m_RootX;
	int m_MinX;
	int m_MaxX;
	HTREEITEM m_InsertMark;
	HTHEME m_TreeTheme;
	HTHEME m_ScrollTheme;

	enum TDropLocation
	{
		DROP_NOWHERE,
		DROP_INSIDE,
		DROP_BEFORE,
		DROP_AFTER,
		DROP_LAST,
	};

	TDropLocation m_DropLocation;
	HTREEITEM m_DragItem;
	HTREEITEM m_DropTarget;
	HTREEITEM m_HoverItem;
	CComPtr<CDropTargetProxy> m_pDropTargetProxy;

	const CTreeItem *GetSelectedItem( HTREEITEM &hItem );
	void AddFirstFolder( std::vector<CTreeItem*> &items, IShellItem *pParent, bool bPrograms );
	void AddSecondFolder( std::vector<CTreeItem*> &items, IShellItem *pParent, bool bPrograms );
	void AddMetroApps( std::vector<CTreeItem*> &items );
	void GetFolderItems( std::vector<CTreeItem*> &items, HTREEITEM hParent );
	void CreateFolderItems( IShellItem *pParent1, IShellItem *pParent2, HTREEITEM hParent );
	void CreateFolderItems( HTREEITEM hParent );
	void PostRefreshMessage( const CItemManager::ItemInfo *pSelectItem=NULL );
	void RefreshTree( HTREEITEM hParent, const CItemManager::ItemInfo *pSelectItem );
	void GetDragEffect( DWORD &grfKeyState, DWORD *pdwEffect );
	void DrawTreeItem( HDC hdc, HDC hsrc, HTREEITEM hItem, const RECT &itemRect, bool bHot ) const;
	bool GetInsertRect( RECT &rc ) const;
	void ClearAllNewRec( HTREEITEM hParent );
	bool IsA4SScrollbarActive( void ) const { return m_bA4SScrollbarHover || m_bA4SScrollbarPulse; }
	void SyncA4SScrollbarProperties( void );

#ifdef A4S_PRODUCT
	enum A4SAsyncResult
	{
		A4S_ASYNC_SUCCESS,
		A4S_ASYNC_CANCELLED,
		A4S_ASYNC_FAILURE,
	};

	struct A4SAsyncConfiguration
	{
		int pinnedPrograms;
		bool bNoCommonFolders;
		bool bAllProgramsMetro;
		bool bHideProgramsMetro;
		bool bFoldersFirst;
		ULONGLONG folderContentGeneration;
		ULONGLONG iconCacheEpoch;
		CString appsName;

		bool operator==( const A4SAsyncConfiguration &other ) const
		{
			return pinnedPrograms==other.pinnedPrograms &&
				bNoCommonFolders==other.bNoCommonFolders &&
				bAllProgramsMetro==other.bAllProgramsMetro &&
				bHideProgramsMetro==other.bHideProgramsMetro &&
				bFoldersFirst==other.bFoldersFirst &&
				folderContentGeneration==other.folderContentGeneration &&
				iconCacheEpoch==other.iconCacheEpoch &&
				appsName==other.appsName;
		}
	};

	static SRWLOCK s_A4SAsyncLock;
	static A4SAsyncConfiguration s_A4SAsyncConfiguration;
	static A4SAsyncConfiguration s_A4SSnapshotConfiguration;
	static std::vector<CTreeItem> s_A4SAsyncItems;
	static volatile LONG s_A4SAsyncGeneration;
	static LONG s_A4SAsyncReadyGeneration;
	static LONG s_A4SAsyncFailedGeneration;
	static volatile LONG s_A4SNextInstanceCookie;
	static bool s_bA4SAsyncHasSnapshot;
	static bool s_bA4SAsyncAutoSort;
	static bool s_bA4SAsyncWorkerRunning;
	static bool s_bA4SAsyncStopping;
	static HANDLE s_A4SAsyncWorker;
	static HWND s_A4SAsyncNotifyWindow;
	static LONG s_A4SAsyncNotifyCookie;

	static A4SAsyncConfiguration CaptureA4SConfiguration( bool bNoCommonFolders );
	static bool IsA4SConfigurationLive( const A4SAsyncConfiguration &configuration );
	static bool SupersedeA4SConfigurationIfStale(
		const A4SAsyncConfiguration &configuration, LONG generation );
	static bool StartA4SAsyncWorkerLocked( void );
	static DWORD CALLBACK A4SAsyncWorkerProc( void *param );
	static A4SAsyncResult BuildA4SRootSnapshot( const A4SAsyncConfiguration &configuration,
		LONG generation, std::vector<CTreeItem> &items, bool &bAutoSort );
	static A4SAsyncResult WaitForA4SIcons( std::vector<CTreeItem> &items,
		LONG generation );
	static bool IsA4SGenerationCurrent( LONG generation );
	static A4SAsyncResult AddA4SFirstFolder( std::vector<CTreeItem> &items,
		IShellItem *pParent,
		bool bPrograms, bool bHideProgramsMetro, LONG generation );
	static A4SAsyncResult AddA4SSecondFolder( std::vector<CTreeItem> &items,
		IShellItem *pParent,
		bool bPrograms, bool bHideProgramsMetro, LONG generation );
	static void RequestA4SItems( CProgramsTree *pOwner, HWND notifyWindow,
		bool bNoCommonFolders, bool bInvalidate );
	static void UnsubscribeA4SItems( HWND notifyWindow, LONG instanceCookie );
	bool ApplyA4SSnapshot( LONG expectedGeneration=0 );
	void ApplyA4SRootItems( std::vector<CTreeItem*> &items,
		const CItemManager::ItemInfo *pSelectItem );
	void InvalidateA4SItems( const CItemManager::ItemInfo *pSelectItem );
	LRESULT OnA4SSnapshotReady( UINT uMsg, WPARAM wParam, LPARAM lParam, BOOL& bHandled );
#endif

	static bool s_bFoldersFirst;
	static bool CmpTreeItems( const CTreeItem *item1, const CTreeItem *item2 );
	static int CALLBACK CmpTreeItemsCB( LPARAM lParam1, LPARAM lParam2, LPARAM lParamSort );
};
