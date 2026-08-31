// A4SMenu deliberately excludes Open-Shell features that are locked off by
// the product profile.  Keep the narrow linker surface expected by the shared
// menu code without initializing shell drag/drop, touch, or jump-list systems.

#include "stdafx.h"
#include "MenuContainer.h"
#include "DragDrop.h"
#include "JumpLists.h"
#include "TouchHelper.h"

bool HasJumplist( const wchar_t *appid )
{
	UNREFERENCED_PARAMETER(appid);
	return false;
}

bool GetJumplist( const wchar_t *appid, CJumpList &list, int maxCount, int maxHeight, int sepHeight, int itemHeight )
{
	UNREFERENCED_PARAMETER(appid);
	UNREFERENCED_PARAMETER(maxCount);
	UNREFERENCED_PARAMETER(maxHeight);
	UNREFERENCED_PARAMETER(sepHeight);
	UNREFERENCED_PARAMETER(itemHeight);
	list.Clear();
	return false;
}

bool ExecuteJumpItem( const CItemManager::ItemInfo *pAppInfo, const CJumpItem &item, HWND hwnd )
{
	UNREFERENCED_PARAMETER(pAppInfo);
	UNREFERENCED_PARAMETER(item);
	UNREFERENCED_PARAMETER(hwnd);
	return false;
}

void RemoveJumpItem( const CItemManager::ItemInfo *pAppInfo, CJumpList &list, int groupIdx, int itemIdx )
{
	UNREFERENCED_PARAMETER(pAppInfo);
	UNREFERENCED_PARAMETER(list);
	UNREFERENCED_PARAMETER(groupIdx);
	UNREFERENCED_PARAMETER(itemIdx);
}

void PinJumpItem( const CItemManager::ItemInfo *pAppInfo, const CJumpList &list, int groupIdx, int itemIdx, bool bPin, int pinIndex )
{
	UNREFERENCED_PARAMETER(pAppInfo);
	UNREFERENCED_PARAMETER(list);
	UNREFERENCED_PARAMETER(groupIdx);
	UNREFERENCED_PARAMETER(itemIdx);
	UNREFERENCED_PARAMETER(bPin);
	UNREFERENCED_PARAMETER(pinIndex);
}

CComPtr<IDataObject> CMenuContainer::CreateMetroDataObject( const CItemManager::ItemInfo *pInfo )
{
	UNREFERENCED_PARAMETER(pInfo);
	return CComPtr<IDataObject>();
}

bool CMenuContainer::DragOutApps( const CItemManager::ItemInfo *pInfo )
{
	UNREFERENCED_PARAMETER(pInfo);
	return false;
}

bool CMenuContainer::DragOut( int index, bool bApp )
{
	UNREFERENCED_PARAMETER(index);
	UNREFERENCED_PARAMETER(bApp);
	return false;
}

void CMenuContainer::SetDropTip( IDataObject *pDataObj, bool bPin )
{
	UNREFERENCED_PARAMETER(pDataObj);
	UNREFERENCED_PARAMETER(bPin);
}

void CMenuContainer::GetDragEffect( DWORD &grfKeyState, DWORD *pdwEffect )
{
	UNREFERENCED_PARAMETER(grfKeyState);
	if (pdwEffect)
		*pdwEffect=DROPEFFECT_NONE;
}

HRESULT STDMETHODCALLTYPE CMenuContainer::DragEnter( IDataObject *pDataObj, DWORD grfKeyState, POINTL pt, DWORD *pdwEffect )
{
	UNREFERENCED_PARAMETER(pDataObj);
	UNREFERENCED_PARAMETER(grfKeyState);
	UNREFERENCED_PARAMETER(pt);
	if (pdwEffect)
		*pdwEffect=DROPEFFECT_NONE;
	return S_OK;
}

HRESULT STDMETHODCALLTYPE CMenuContainer::DragOver( DWORD grfKeyState, POINTL pt, DWORD *pdwEffect )
{
	UNREFERENCED_PARAMETER(grfKeyState);
	UNREFERENCED_PARAMETER(pt);
	if (pdwEffect)
		*pdwEffect=DROPEFFECT_NONE;
	return S_OK;
}

HRESULT STDMETHODCALLTYPE CMenuContainer::DragLeave( void )
{
	return S_OK;
}

HRESULT STDMETHODCALLTYPE CMenuContainer::Drop( IDataObject *pDataObj, DWORD grfKeyState, POINTL pt, DWORD *pdwEffect )
{
	UNREFERENCED_PARAMETER(pDataObj);
	UNREFERENCED_PARAMETER(grfKeyState);
	UNREFERENCED_PARAMETER(pt);
	if (pdwEffect)
		*pdwEffect=DROPEFFECT_NONE;
	return S_OK;
}

HRESULT STDMETHODCALLTYPE CDropTargetProxy::DragEnter( IDataObject *pDataObj, DWORD grfKeyState, POINTL pt, DWORD *pdwEffect )
{
	UNREFERENCED_PARAMETER(pDataObj);
	UNREFERENCED_PARAMETER(grfKeyState);
	UNREFERENCED_PARAMETER(pt);
	if (pdwEffect)
		*pdwEffect=DROPEFFECT_NONE;
	return S_OK;
}

HRESULT STDMETHODCALLTYPE CDropTargetProxy::DragOver( DWORD grfKeyState, POINTL pt, DWORD *pdwEffect )
{
	UNREFERENCED_PARAMETER(grfKeyState);
	UNREFERENCED_PARAMETER(pt);
	if (pdwEffect)
		*pdwEffect=DROPEFFECT_NONE;
	return S_OK;
}

HRESULT STDMETHODCALLTYPE CDropTargetProxy::DragLeave( void )
{
	return S_OK;
}

HRESULT STDMETHODCALLTYPE CDropTargetProxy::Drop( IDataObject *pDataObj, DWORD grfKeyState, POINTL pt, DWORD *pdwEffect )
{
	UNREFERENCED_PARAMETER(pDataObj);
	UNREFERENCED_PARAMETER(grfKeyState);
	UNREFERENCED_PARAMETER(pt);
	if (pdwEffect)
		*pdwEffect=DROPEFFECT_NONE;
	return S_OK;
}

void InitTouchHelper( void )
{
}

BOOL GetPointerType2( UINT32 pointerId, POINTER_INPUT_TYPE *pointerType )
{
	UNREFERENCED_PARAMETER(pointerId);
	if (pointerType)
		*pointerType=PT_POINTER;
	return FALSE;
}

BOOL GetPointerCursorId2( UINT32 pointerId, UINT32 *cursorId )
{
	UNREFERENCED_PARAMETER(pointerId);
	if (cursorId)
		*cursorId=0;
	return FALSE;
}

BOOL GetPointerInfo2( UINT32 pointerId, POINTER_INFO *pointerInfo )
{
	UNREFERENCED_PARAMETER(pointerId);
	if (pointerInfo)
		ZeroMemory(pointerInfo,sizeof(*pointerInfo));
	return FALSE;
}

BOOL GetCurrentInputMessageSource2( INPUT_MESSAGE_SOURCE *inputMessageSource )
{
	if (inputMessageSource)
		ZeroMemory(inputMessageSource,sizeof(*inputMessageSource));
	return FALSE;
}

BOOL GetCIMSSM2( INPUT_MESSAGE_SOURCE *inputMessageSource )
{
	if (inputMessageSource)
		ZeroMemory(inputMessageSource,sizeof(*inputMessageSource));
	return FALSE;
}
