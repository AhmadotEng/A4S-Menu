#include <Windows.h>
#include <shellapi.h>

#include <algorithm>
#include <cstdint>
#include <cwchar>
#include <string>
#include <vector>

#include "../Shared/A4SProductApi.h"

namespace
{
	constexpr UINT_PTR kRetryTimer = 1;
	constexpr UINT_PTR kInjectionTimer = 2;
	constexpr UINT_PTR kStopTimer = 3;
	constexpr UINT_PTR kBootstrapUnhookTimer = 4;
	constexpr DWORD kInjectionTimeoutMs = 5000;
	constexpr DWORD kStopTimeoutMs = 5500;
	constexpr DWORD kBootstrapUnhookRetryMs = 250;
	constexpr size_t kBootstrapReplayLimit = 3;
	constexpr DWORD kRetryDelayMs[] = { 100, 250, 500, 1000, 2000, 4000, 4000 };

	class UniqueHandle
	{
	public:
		UniqueHandle() noexcept = default;
		explicit UniqueHandle(HANDLE value) noexcept : m_value(value) {}
		~UniqueHandle() { reset(); }
		UniqueHandle(const UniqueHandle &) = delete;
		UniqueHandle &operator=(const UniqueHandle &) = delete;
		UniqueHandle(UniqueHandle &&other) noexcept : m_value(other.release()) {}
		UniqueHandle &operator=(UniqueHandle &&other) noexcept
		{
			if (this != &other)
				reset(other.release());
			return *this;
		}
		HANDLE get() const noexcept { return m_value; }
		explicit operator bool() const noexcept { return m_value && m_value != INVALID_HANDLE_VALUE; }
		HANDLE release() noexcept
		{
			HANDLE value = m_value;
			m_value = nullptr;
			return value;
		}
		void reset(HANDLE value = nullptr) noexcept
		{
			if (m_value && m_value != INVALID_HANDLE_VALUE)
				CloseHandle(m_value);
			m_value = value;
		}

	private:
		HANDLE m_value = nullptr;
	};

	struct ExplorerTarget
	{
		HWND taskbar = nullptr;
		DWORD processId = 0;
		DWORD threadId = 0;
		UniqueHandle process;

		void clear()
		{
			taskbar = nullptr;
			processId = 0;
			threadId = 0;
			process.reset();
		}
	};

	struct HostRuntime
	{
		HINSTANCE instance = nullptr;
		HWND window = nullptr;
		UINT hostControlMessage = 0;
		UINT dllBootstrapMessage = 0;
		UINT dllStatusMessage = 0;
		UINT menuCommandMessage = 0;
		UINT taskbarCreatedMessage = 0;
		A4SMenuHostStatus status = A4S_MENU_HOST_STATUS_STARTING;
		HHOOK bootstrapHook = nullptr;
		HMODULE menuDll = nullptr;
		const A4SMenuApi *api = nullptr;
		A4SMenuHookInjectFn hookInject = nullptr;
		ExplorerTarget explorer;
		size_t retryIndex = 0;
		size_t bootstrapReplayCount = 0;
		bool pendingToggle = false;
		bool exitPending = false;
		bool activationCommitted = false;
		bool initializationPending = false;
		bool replacementPending = false;
		bool targetInvalidated = false;
		UINT_PTR attemptCookie = 0;
	};

	HostRuntime g_runtime;

	void DebugLog(const wchar_t *text)
	{
		std::wstring line = L"A4SMenuHost: ";
		line += text;
		line += L"\r\n";
		OutputDebugStringW(line.c_str());
	}

	bool GenerateAttemptCookie(UINT_PTR &cookie)
	{
		using RtlGenRandomFn = BOOLEAN (WINAPI *)(PVOID, ULONG);
		auto random = reinterpret_cast<RtlGenRandomFn>(
			GetProcAddress(GetModuleHandleW(L"advapi32.dll"), "SystemFunction036"));
		cookie = 0;
		return random && random(&cookie, sizeof(cookie)) && cookie != 0;
	}

	void ClearAttemptCookie()
	{
		if (g_runtime.window)
			RemovePropW(g_runtime.window, A4S_HOST_ATTEMPT_COOKIE_PROPERTY_W);
		g_runtime.attemptCookie = 0;
	}

	bool PublishAttemptCookie()
	{
		ClearAttemptCookie();
		UINT_PTR cookie = 0;
		if (!GenerateAttemptCookie(cookie) ||
			!SetPropW(g_runtime.window, A4S_HOST_ATTEMPT_COOKIE_PROPERTY_W,
				reinterpret_cast<HANDLE>(cookie)))
			return false;
		g_runtime.attemptCookie = cookie;
		return true;
	}

	void WriteParentConsole(const std::wstring &text)
	{
		bool attached = false;
		if (!GetConsoleWindow())
			attached = AttachConsole(ATTACH_PARENT_PROCESS) != FALSE;
		HANDLE output = GetStdHandle(STD_OUTPUT_HANDLE);
		if (output && output != INVALID_HANDLE_VALUE)
		{
			DWORD written = 0;
			std::wstring line = text + L"\r\n";
			if (GetFileType(output) == FILE_TYPE_CHAR)
				WriteConsoleW(output, line.data(), static_cast<DWORD>(line.size()), &written, nullptr);
			else
			{
				const int bytes = WideCharToMultiByte(CP_UTF8, 0, line.c_str(),
					static_cast<int>(line.size()), nullptr, 0, nullptr, nullptr);
				if (bytes > 0)
				{
					std::string utf8(static_cast<size_t>(bytes), '\0');
					WideCharToMultiByte(CP_UTF8, 0, line.c_str(), static_cast<int>(line.size()),
						utf8.data(), bytes, nullptr, nullptr);
					WriteFile(output, utf8.data(), static_cast<DWORD>(utf8.size()), &written, nullptr);
				}
			}
		}
		if (attached)
			FreeConsole();
	}

	std::wstring GetModulePath()
	{
		std::vector<wchar_t> buffer(512);
		for (;;)
		{
			SetLastError(ERROR_SUCCESS);
			const DWORD length = GetModuleFileNameW(nullptr, buffer.data(),
				static_cast<DWORD>(buffer.size()));
			if (!length)
				return {};
			if (length < buffer.size() - 1)
				return std::wstring(buffer.data(), length);
			if (buffer.size() >= 32768)
				return {};
			buffer.resize(std::min<size_t>(buffer.size() * 2, 32768));
		}
	}

	std::wstring StripExtendedPrefix(std::wstring path)
	{
		if (path.rfind(L"\\\\?\\UNC\\", 0) == 0)
			return L"\\\\" + path.substr(8);
		if (path.rfind(L"\\\\?\\", 0) == 0)
			return path.substr(4);
		return path;
	}

	bool CanonicalizeExistingFile(const std::wstring &path, std::wstring &canonical)
	{
		UniqueHandle file(CreateFileW(path.c_str(), FILE_READ_ATTRIBUTES,
			FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING,
			FILE_ATTRIBUTE_NORMAL, nullptr));
		if (!file)
			return false;

		const DWORD needed = GetFinalPathNameByHandleW(file.get(), nullptr, 0,
			FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
		if (!needed)
			return false;
		std::vector<wchar_t> buffer(static_cast<size_t>(needed) + 1);
		const DWORD length = GetFinalPathNameByHandleW(file.get(), buffer.data(),
			static_cast<DWORD>(buffer.size()), FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
		if (!length || length >= buffer.size())
			return false;
		canonical = StripExtendedPrefix(std::wstring(buffer.data(), length));
		return true;
	}

	std::wstring DirectoryOf(const std::wstring &path)
	{
		const size_t slash = path.find_last_of(L"\\/");
		return slash == std::wstring::npos ? std::wstring() : path.substr(0, slash);
	}

	bool EqualPath(const std::wstring &left, const std::wstring &right)
	{
		return CompareStringOrdinal(left.c_str(), -1, right.c_str(), -1, TRUE) == CSTR_EQUAL;
	}

	bool ResolveSiblingDll(std::wstring &dllPath)
	{
		std::wstring canonicalHost;
		if (!CanonicalizeExistingFile(GetModulePath(), canonicalHost))
			return false;
		const std::wstring hostDirectory = DirectoryOf(canonicalHost);
		if (hostDirectory.empty())
			return false;

		const std::wstring candidate = hostDirectory + L"\\" + A4S_PRODUCT_DLL_FILENAME_W;
		std::wstring canonicalDll;
		if (!CanonicalizeExistingFile(candidate, canonicalDll))
			return false;
		// Reject a sibling-name reparse point that resolves outside the product directory.
		if (!EqualPath(DirectoryOf(canonicalDll), hostDirectory))
			return false;
		const size_t slash = canonicalDll.find_last_of(L"\\/");
		if (slash == std::wstring::npos ||
			_wcsicmp(canonicalDll.c_str() + slash + 1, A4S_PRODUCT_DLL_FILENAME_W) != 0)
			return false;
		dllPath = canonicalDll;
		return true;
	}

	bool QueryTokenUser(HANDLE process, std::vector<BYTE> &storage, PSID &sid)
	{
		UniqueHandle token;
		HANDLE rawToken = nullptr;
		if (!OpenProcessToken(process, TOKEN_QUERY, &rawToken))
			return false;
		token.reset(rawToken);
		DWORD bytes = 0;
		GetTokenInformation(token.get(), TokenUser, nullptr, 0, &bytes);
		if (!bytes || GetLastError() != ERROR_INSUFFICIENT_BUFFER)
			return false;
		storage.resize(bytes);
		if (!GetTokenInformation(token.get(), TokenUser, storage.data(), bytes, &bytes))
			return false;
		sid = reinterpret_cast<TOKEN_USER *>(storage.data())->User.Sid;
		return IsValidSid(sid) != FALSE;
	}

	bool IsSameUser(HANDLE targetProcess)
	{
		std::vector<BYTE> currentStorage;
		std::vector<BYTE> targetStorage;
		PSID currentSid = nullptr;
		PSID targetSid = nullptr;
		return QueryTokenUser(GetCurrentProcess(), currentStorage, currentSid) &&
			QueryTokenUser(targetProcess, targetStorage, targetSid) &&
			EqualSid(currentSid, targetSid) != FALSE;
	}

	bool IsSameArchitecture(HANDLE targetProcess)
	{
		using IsWow64Process2Fn = BOOL (WINAPI *)(HANDLE, USHORT *, USHORT *);
		auto isWow64Process2 = reinterpret_cast<IsWow64Process2Fn>(
			GetProcAddress(GetModuleHandleW(L"kernel32.dll"), "IsWow64Process2"));
		if (isWow64Process2)
		{
			USHORT currentProcessMachine = 0;
			USHORT currentNativeMachine = 0;
			USHORT targetProcessMachine = 0;
			USHORT targetNativeMachine = 0;
			if (!isWow64Process2(GetCurrentProcess(), &currentProcessMachine, &currentNativeMachine) ||
				!isWow64Process2(targetProcess, &targetProcessMachine, &targetNativeMachine))
				return false;
			const USHORT currentEffective = currentProcessMachine ? currentProcessMachine : currentNativeMachine;
			const USHORT targetEffective = targetProcessMachine ? targetProcessMachine : targetNativeMachine;
			return currentEffective == targetEffective;
		}

		BOOL currentWow64 = FALSE;
		BOOL targetWow64 = FALSE;
		return IsWow64Process(GetCurrentProcess(), &currentWow64) &&
			IsWow64Process(targetProcess, &targetWow64) && currentWow64 == targetWow64;
	}

	bool QueryProcessImagePath(HANDLE process, std::wstring &path)
	{
		std::vector<wchar_t> buffer(32768);
		DWORD count = static_cast<DWORD>(buffer.size());
		if (!QueryFullProcessImageNameW(process, 0, buffer.data(), &count))
			return false;
		path.assign(buffer.data(), count);
		return true;
	}

	bool IsWindowsExplorer(HANDLE process)
	{
		std::wstring processPath;
		if (!QueryProcessImagePath(process, processPath))
			return false;
		std::wstring canonicalProcess;
		if (!CanonicalizeExistingFile(processPath, canonicalProcess))
			return false;

		std::vector<wchar_t> windowsDirectory(32768);
		const UINT length = GetWindowsDirectoryW(windowsDirectory.data(),
			static_cast<UINT>(windowsDirectory.size()));
		if (!length || length >= windowsDirectory.size())
			return false;
		std::wstring expected(windowsDirectory.data(), length);
		expected += L"\\explorer.exe";
		std::wstring canonicalExpected;
		return CanonicalizeExistingFile(expected, canonicalExpected) &&
			EqualPath(canonicalProcess, canonicalExpected);
	}

	bool FindValidatedExplorer(ExplorerTarget &result)
	{
		HWND taskbar = FindWindowW(L"Shell_TrayWnd", nullptr);
		if (!taskbar)
			return false;
		DWORD processId = 0;
		const DWORD threadId = GetWindowThreadProcessId(taskbar, &processId);
		if (!threadId || !processId)
			return false;

		DWORD currentSession = 0;
		DWORD explorerSession = 0;
		if (!ProcessIdToSessionId(GetCurrentProcessId(), &currentSession) ||
			!ProcessIdToSessionId(processId, &explorerSession) || currentSession != explorerSession)
			return false;

		UniqueHandle process(OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE,
			FALSE, processId));
		if (!process || !IsSameUser(process.get()) || !IsWindowsExplorer(process.get()) ||
			!IsSameArchitecture(process.get()))
			return false;

		result.clear();
		result.taskbar = taskbar;
		result.processId = processId;
		result.threadId = threadId;
		result.process = std::move(process);
		return true;
	}

	bool LoadProductDll()
	{
		if (g_runtime.menuDll)
			return true;
		std::wstring dllPath;
		if (!ResolveSiblingDll(dllPath))
		{
			DebugLog(L"the canonical sibling A4SMenu.dll was not found");
			return false;
		}
		SetDefaultDllDirectories(LOAD_LIBRARY_SEARCH_SYSTEM32 | LOAD_LIBRARY_SEARCH_USER_DIRS);
		g_runtime.menuDll = LoadLibraryExW(dllPath.c_str(), nullptr,
			LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32);
		if (!g_runtime.menuDll)
		{
			DebugLog(L"LoadLibraryExW rejected A4SMenu.dll");
			return false;
		}

		auto getApi = reinterpret_cast<A4SMenuGetApiFn>(
			GetProcAddress(g_runtime.menuDll, A4S_DLL_GET_API_EXPORT_A));
		g_runtime.hookInject = reinterpret_cast<A4SMenuHookInjectFn>(
			GetProcAddress(g_runtime.menuDll, A4S_DLL_HOOK_INJECT_EXPORT_A));
		g_runtime.api = getApi ? getApi(A4S_MENU_ABI_VERSION) : nullptr;
		if (!g_runtime.api || !g_runtime.hookInject ||
			g_runtime.api->cbSize < sizeof(A4SMenuApi) ||
			g_runtime.api->abiVersion != A4S_MENU_ABI_VERSION ||
			g_runtime.api->productVersion != A4S_MENU_PRODUCT_VERSION ||
			!g_runtime.api->RequestShutdown)
		{
			DebugLog(L"A4SMenu.dll has an incompatible or incomplete product ABI");
			FreeLibrary(g_runtime.menuDll);
			g_runtime.menuDll = nullptr;
			g_runtime.api = nullptr;
			g_runtime.hookInject = nullptr;
			return false;
		}
		return true;
	}

	bool UnhookBootstrap()
	{
		if (!g_runtime.bootstrapHook)
		{
			if (g_runtime.window)
				KillTimer(g_runtime.window, kBootstrapUnhookTimer);
			return true;
		}
		if (UnhookWindowsHookEx(g_runtime.bootstrapHook))
		{
			g_runtime.bootstrapHook = nullptr;
			if (g_runtime.window)
				KillTimer(g_runtime.window, kBootstrapUnhookTimer);
			return true;
		}

		// Windows removes a thread hook when its target thread/process exits. In
		// that one case the stale local HHOOK can be forgotten safely. While the
		// validated Explorer remains alive, retain the handle so it can be retried
		// and so no second bootstrap hook can be installed beside it.
		if (g_runtime.explorer.process &&
			WaitForSingleObject(g_runtime.explorer.process.get(), 0) != WAIT_TIMEOUT)
		{
			g_runtime.bootstrapHook = nullptr;
			if (g_runtime.window)
				KillTimer(g_runtime.window, kBootstrapUnhookTimer);
			return true;
		}
		DebugLog(L"UnhookWindowsHookEx failed; retaining the bootstrap hook handle");
		if (g_runtime.window)
			SetTimer(g_runtime.window, kBootstrapUnhookTimer,
				kBootstrapUnhookRetryMs, nullptr);
		return false;
	}

	void CancelConnectionTimers(bool preserveReplacementIntent = false)
	{
		if (!g_runtime.window)
			return;
		KillTimer(g_runtime.window, kRetryTimer);
		KillTimer(g_runtime.window, kInjectionTimer);
		if (!preserveReplacementIntent)
			g_runtime.replacementPending = false;
	}

	bool ResetConnection()
	{
		CancelConnectionTimers();
		if (!UnhookBootstrap())
			return false;
		g_runtime.explorer.clear();
		ClearAttemptCookie();
		return true;
	}

	void ScheduleRetry()
	{
		if (!ResetConnection())
		{
			g_runtime.status = A4S_MENU_HOST_STATUS_FAILED;
			return;
		}
		g_runtime.initializationPending = false;
		if (g_runtime.retryIndex >= _countof(kRetryDelayMs))
		{
			g_runtime.status = A4S_MENU_HOST_STATUS_FAILED;
			DebugLog(L"bounded Explorer connection retries exhausted; native Start remains enabled");
			return;
		}
		g_runtime.status = A4S_MENU_HOST_STATUS_STARTING;
		const DWORD delay = kRetryDelayMs[g_runtime.retryIndex++];
		if (!SetTimer(g_runtime.window, kRetryTimer, delay, nullptr))
			g_runtime.status = A4S_MENU_HOST_STATUS_FAILED;
	}

	bool TargetStillMatches();

	bool PostBootstrapMessage()
	{
		return g_runtime.attemptCookie && TargetStillMatches() &&
			PostMessageW(g_runtime.explorer.taskbar,g_runtime.dllBootstrapMessage,
				reinterpret_cast<WPARAM>(g_runtime.window),
				static_cast<LPARAM>(g_runtime.attemptCookie))!=FALSE;
	}

	bool TryInject()
	{
		if (!LoadProductDll())
		{
			g_runtime.status = A4S_MENU_HOST_STATUS_FAILED;
			return false;
		}
		ExplorerTarget target;
		if (!FindValidatedExplorer(target))
			return false;
		g_runtime.explorer = std::move(target);
		// Revalidate immediately before installation. Thread IDs can be reused
		// after process termination, so the original discovery is not sufficient.
		if (!TargetStillMatches())
		{
			g_runtime.explorer.clear();
			return false;
		}
		if (!PublishAttemptCookie())
		{
			DebugLog(L"could not publish a cryptographically random attempt cookie");
			g_runtime.explorer.clear();
			return false;
		}
		g_runtime.bootstrapHook = SetWindowsHookExW(WH_GETMESSAGE, g_runtime.hookInject,
			g_runtime.menuDll, g_runtime.explorer.threadId);
		if (!g_runtime.bootstrapHook)
		{
			DebugLog(L"SetWindowsHookExW failed for the validated Explorer taskbar thread");
			g_runtime.explorer.clear();
			return false;
		}
		g_runtime.initializationPending = true;
		g_runtime.bootstrapReplayCount = 0;
		g_runtime.status = A4S_MENU_HOST_STATUS_INJECTING;
		if (!TargetStillMatches())
			DebugLog(L"Explorer changed immediately after hook installation; retaining the committed attempt");
		if (!PostBootstrapMessage())
		{
			// The product hook initializes only for this authenticated bootstrap
			// message. If it was not queued, no unrelated message can commit the DLL.
			g_runtime.initializationPending = false;
			UnhookBootstrap();
			DebugLog(L"the authenticated bootstrap message could not be queued");
			return false;
		}
		// The timer may re-post this same authenticated attempt, but it never
		// installs another hook or treats elapsed time as proof of rollback.
		SetTimer(g_runtime.window, kInjectionTimer, kInjectionTimeoutMs, nullptr);
		return true;
	}

	void BeginConnection(bool immediate)
	{
		g_runtime.exitPending = false;
		g_runtime.activationCommitted = false;
		g_runtime.replacementPending = false;
		g_runtime.targetInvalidated = false;
		g_runtime.retryIndex = 0;
		g_runtime.bootstrapReplayCount = 0;
		if (!ResetConnection())
		{
			g_runtime.status = A4S_MENU_HOST_STATUS_FAILED;
			return;
		}
		g_runtime.initializationPending = false;
		g_runtime.status = A4S_MENU_HOST_STATUS_STARTING;
		if (immediate && TryInject())
			return;
		ScheduleRetry();
	}

	bool TargetStillMatches()
	{
		if (!g_runtime.explorer.taskbar || !IsWindow(g_runtime.explorer.taskbar))
			return false;
		DWORD processId = 0;
		const DWORD threadId = GetWindowThreadProcessId(g_runtime.explorer.taskbar, &processId);
		return processId == g_runtime.explorer.processId && threadId == g_runtime.explorer.threadId &&
			WaitForSingleObject(g_runtime.explorer.process.get(), 0) == WAIT_TIMEOUT;
	}

	bool ExplorerProcessStillAlive()
	{
		return g_runtime.explorer.process &&
			WaitForSingleObject(g_runtime.explorer.process.get(), 0) == WAIT_TIMEOUT;
	}

	bool SendMenuCommand(A4SMenuCommand command)
	{
		if (!TargetStillMatches())
			return false;
		if (command == A4S_MENU_COMMAND_TOGGLE &&
			!AllowSetForegroundWindow(g_runtime.explorer.processId))
			DebugLog(L"foreground authorization could not be delegated to Explorer");
		return PostMessageW(g_runtime.explorer.taskbar, g_runtime.menuCommandMessage,
			static_cast<WPARAM>(command), 0) != FALSE;
	}

	void IssueShutdownRequest(bool preserveReplacementIntent = false)
	{
		g_runtime.status = A4S_MENU_HOST_STATUS_STOPPING;
		CancelConnectionTimers(preserveReplacementIntent);
		UnhookBootstrap();

		const bool targetValid = TargetStillMatches();
		bool requested = false;
		if (targetValid && g_runtime.api && g_runtime.api->RequestShutdown)
			requested = g_runtime.api->RequestShutdown(g_runtime.explorer.taskbar) != FALSE;
		if (!requested && targetValid)
			requested = SendMenuCommand(A4S_MENU_COMMAND_EXIT);

		if (!requested)
		{
			if (!targetValid && !ExplorerProcessStillAlive())
			{
				g_runtime.activationCommitted = false;
				DestroyWindow(g_runtime.window);
			}
			else
			{
				// A still-live Explorer may own committed activation hooks even when its
				// original taskbar HWND was recreated. Never reinject it or abandon its
				// process-exit watch when there is no verified shutdown path.
				g_runtime.replacementPending = preserveReplacementIntent;
				g_runtime.status = A4S_MENU_HOST_STATUS_FAILED;
				DebugLog(L"shutdown target unavailable; waiting for the live Explorer process to exit");
			}
			return;
		}
		SetTimer(g_runtime.window, kStopTimer, kStopTimeoutMs, nullptr);
	}

	void RequestStop()
	{
		g_runtime.exitPending = true;
		if (g_runtime.replacementPending)
		{
			// An initializing old mapping must first report whether activation was
			// committed. A ready mapping can be disarmed through its stored taskbar
			// while the replacement intent remains latched.
			if (g_runtime.initializationPending)
			{
				g_runtime.status = A4S_MENU_HOST_STATUS_STOPPING;
				return;
			}
			if (g_runtime.activationCommitted)
			{
				IssueShutdownRequest(true);
				return;
			}
			// FAILED or DISARMED already proved this mapping inert. There is no
			// callback left to protect, so an explicit stop can complete immediately.
			CancelConnectionTimers();
			UnhookBootstrap();
			DestroyWindow(g_runtime.window);
			return;
		}

		if (g_runtime.initializationPending)
		{
			// Initialization may still be committing Explorer callbacks. Preserve the
			// bootstrap hook and queue the intent until READY or FAILED is reported.
			g_runtime.status = A4S_MENU_HOST_STATUS_STOPPING;
			return;
		}

		if (g_runtime.activationCommitted || g_runtime.status == A4S_MENU_HOST_STATUS_READY)
		{
			IssueShutdownRequest();
			return;
		}

		CancelConnectionTimers();
		UnhookBootstrap();
		DestroyWindow(g_runtime.window);
	}

	void HandleReadyStatus()
	{
		// The bootstrap hook is needed only to map and initialize the DLL. Remove it
		// before accepting any runtime toggle or shutdown command.
		g_runtime.initializationPending = false;
		UnhookBootstrap();
		KillTimer(g_runtime.window, kInjectionTimer);
		KillTimer(g_runtime.window, kRetryTimer);
		g_runtime.activationCommitted = true;
		if (g_runtime.targetInvalidated)
		{
			// Same-process taskbar recreation is a terminal first-half condition.
			// A late READY cannot reactivate the obsolete target or consume a toggle.
			g_runtime.status = A4S_MENU_HOST_STATUS_FAILED;
			if (g_runtime.exitPending)
				IssueShutdownRequest(false);
			return;
		}
		if (g_runtime.replacementPending)
		{
			// READY belongs to the old Explorer. Preserve the replacement watch and
			// any queued toggle; only the replacement process may become interactive.
			if (g_runtime.exitPending)
				IssueShutdownRequest(true);
			else
				g_runtime.status = A4S_MENU_HOST_STATUS_STARTING;
			return;
		}
		g_runtime.status = A4S_MENU_HOST_STATUS_READY;
		if (g_runtime.exitPending)
		{
			IssueShutdownRequest();
			return;
		}
		if (g_runtime.pendingToggle)
		{
			if (SendMenuCommand(A4S_MENU_COMMAND_TOGGLE))
				g_runtime.pendingToggle = false;
			else if (!ExplorerProcessStillAlive())
			{
				g_runtime.activationCommitted = false;
				BeginConnection(false);
			}
			else
			{
				g_runtime.targetInvalidated = true;
				g_runtime.status = A4S_MENU_HOST_STATUS_FAILED;
				DebugLog(L"queued menu toggle could not be delivered to the live Explorer target");
			}
		}
	}

	void HandleDllStatus(A4SMenuDllStatus status, DWORD explorerProcessId,
		UINT_PTR attemptCookie)
	{
		if (!g_runtime.explorer.processId ||
			explorerProcessId != g_runtime.explorer.processId || !attemptCookie ||
			attemptCookie != g_runtime.attemptCookie)
			return;
		switch (status)
		{
		case A4S_MENU_DLL_STATUS_READY:
			if (!g_runtime.initializationPending &&
				g_runtime.status != A4S_MENU_HOST_STATUS_READY)
				return;
			HandleReadyStatus();
			break;
		case A4S_MENU_DLL_STATUS_FAILED:
			if (!g_runtime.initializationPending || g_runtime.activationCommitted)
				return;
			// Do not leave the bootstrap callback installed after a failed init. The
			// product DLL promises it has not committed activation hooks in this state.
			{
			const bool exitPending = g_runtime.exitPending;
			const bool reconnectReplacement = g_runtime.replacementPending;
			const bool preserveReplacement = reconnectReplacement && !exitPending;
			g_runtime.initializationPending = false;
			CancelConnectionTimers(preserveReplacement);
			UnhookBootstrap();
			g_runtime.activationCommitted = false;
			g_runtime.status = preserveReplacement ? A4S_MENU_HOST_STATUS_STARTING :
				A4S_MENU_HOST_STATUS_FAILED;
			if (exitPending)
				DestroyWindow(g_runtime.window);
			}
			break;
		case A4S_MENU_DLL_STATUS_DISARMED:
			if (g_runtime.initializationPending && !g_runtime.activationCommitted)
			{
				// A new host can encounter a product mapping that an earlier host
				// already disarmed. That mapping is intentionally non-restartable in
				// the first half, so finish this attempt instead of waiting forever.
				const bool exitPending = g_runtime.exitPending;
				const bool reconnectReplacement = g_runtime.replacementPending;
				const bool preserveReplacement = reconnectReplacement && !exitPending;
				g_runtime.initializationPending = false;
				CancelConnectionTimers(preserveReplacement);
				UnhookBootstrap();
				g_runtime.status = preserveReplacement ? A4S_MENU_HOST_STATUS_STARTING :
					A4S_MENU_HOST_STATUS_FAILED;
				if (exitPending)
					DestroyWindow(g_runtime.window);
				break;
			}
			if (!g_runtime.activationCommitted)
				return;
			{
			const bool reconnectReplacement = g_runtime.replacementPending;
			const bool exitPending = g_runtime.exitPending;
			const bool preserveReplacement = reconnectReplacement && !exitPending;
			g_runtime.initializationPending = false;
			KillTimer(g_runtime.window, kStopTimer);
			CancelConnectionTimers(preserveReplacement);
			UnhookBootstrap();
			g_runtime.activationCommitted = false;
			if (exitPending)
				DestroyWindow(g_runtime.window);
			else if (preserveReplacement)
				g_runtime.status = A4S_MENU_HOST_STATUS_STARTING;
			else
				g_runtime.status = A4S_MENU_HOST_STATUS_FAILED;
			}
			break;
		default:
			break;
		}
	}

	const wchar_t *StatusText(A4SMenuHostStatus status)
	{
		switch (status)
		{
		case A4S_MENU_HOST_STATUS_STARTING: return L"starting";
		case A4S_MENU_HOST_STATUS_INJECTING: return L"injecting";
		case A4S_MENU_HOST_STATUS_READY: return L"ready";
		case A4S_MENU_HOST_STATUS_FAILED: return L"failed (native Start available)";
		case A4S_MENU_HOST_STATUS_STOPPING: return L"stopping";
		default: return L"unknown";
		}
	}

	void HandleExplorerProcessExit()
	{
		if (!g_runtime.explorer.process ||
			WaitForSingleObject(g_runtime.explorer.process.get(), 0) != WAIT_OBJECT_0)
			return;

		DebugLog(L"validated Explorer process exited");
		g_runtime.initializationPending = false;
		g_runtime.activationCommitted = false;
		g_runtime.replacementPending = false;
		g_runtime.targetInvalidated = false;
		if (g_runtime.exitPending)
		{
			ResetConnection();
			if (g_runtime.window && IsWindow(g_runtime.window))
				DestroyWindow(g_runtime.window);
		}
		else
			BeginConnection(true);
	}

	LRESULT CALLBACK HostWindowProc(HWND window, UINT message, WPARAM wParam, LPARAM lParam)
	{
		if (message == g_runtime.hostControlMessage)
		{
			switch (static_cast<A4SMenuHostControl>(wParam))
			{
			case A4S_MENU_HOST_CONTROL_TOGGLE:
				if (g_runtime.status == A4S_MENU_HOST_STATUS_READY)
				{
					if (SendMenuCommand(A4S_MENU_COMMAND_TOGGLE))
						return TRUE;
					if (ExplorerProcessStillAlive())
					{
						// The committed hooks may still exist even when their taskbar HWND
						// no longer accepts messages. Never duplicate them in this process.
						g_runtime.status = A4S_MENU_HOST_STATUS_FAILED;
						DebugLog(L"menu command failed; waiting for a new Explorer process");
						return FALSE;
					}
					g_runtime.activationCommitted = false;
					g_runtime.pendingToggle = true;
					BeginConnection(false);
					return TRUE;
				}
				if (g_runtime.status == A4S_MENU_HOST_STATUS_STARTING ||
					g_runtime.status == A4S_MENU_HOST_STATUS_INJECTING)
				{
					g_runtime.pendingToggle = true;
					return TRUE;
				}
				return FALSE;
			case A4S_MENU_HOST_CONTROL_EXIT:
				RequestStop();
				return TRUE;
			case A4S_MENU_HOST_CONTROL_REHOOK:
				if (g_runtime.exitPending || TargetStillMatches() || ExplorerProcessStillAlive())
				{
					DebugLog(L"same-process rehook is intentionally unsupported in the first-half host");
					return FALSE;
				}
				BeginConnection(true);
				return TRUE;
			case A4S_MENU_HOST_CONTROL_STATUS:
				return static_cast<LRESULT>(g_runtime.status);
			default:
				return FALSE;
			}
		}
		if (message == g_runtime.dllStatusMessage)
		{
			const UINT64 payload=static_cast<UINT64>(wParam);
			HandleDllStatus(static_cast<A4SMenuDllStatus>(static_cast<UINT32>(payload)),
				static_cast<DWORD>(payload>>32),static_cast<UINT_PTR>(lParam));
			return 0;
		}
		if (message == g_runtime.taskbarCreatedMessage)
		{
			if (g_runtime.exitPending)
			{
				// TaskbarCreated is an unauthenticated broadcast and can be replayed.
				// While the validated Explorer is alive, only an authoritative FAILED
				// or DISARMED status may finish an in-flight stop transaction.
				if (!ExplorerProcessStillAlive())
					DestroyWindow(window);
				else
				{
					DWORD currentProcessId = 0;
					HWND currentTaskbar = FindWindowW(L"Shell_TrayWnd", nullptr);
					if (currentTaskbar)
						GetWindowThreadProcessId(currentTaskbar, &currentProcessId);
					if (currentProcessId && currentProcessId != g_runtime.explorer.processId)
					{
						g_runtime.replacementPending = true;
						g_runtime.status = A4S_MENU_HOST_STATUS_STOPPING;
					}
				}
				return 0;
			}
			else
			{
				DWORD currentProcessId = 0;
				HWND currentTaskbar = FindWindowW(L"Shell_TrayWnd", nullptr);
				if (currentTaskbar)
					GetWindowThreadProcessId(currentTaskbar, &currentProcessId);
				const bool explorerStillAlive = ExplorerProcessStillAlive();

				// Read the authoritative current Shell_TrayWnd before accepting the
				// stored target. During Explorer replacement the old HWND/process can
				// remain valid after the new shell has already broadcast TaskbarCreated.
				if (explorerStillAlive && currentProcessId && currentProcessId != g_runtime.explorer.processId)
				{
					// Do not attach twice; wait for the old Explorer process handle to
					// signal, then connect to the validated replacement taskbar.
					g_runtime.replacementPending = true;
					g_runtime.status = A4S_MENU_HOST_STATUS_STARTING;
					DebugLog(L"replacement taskbar observed; waiting for the old Explorer process to exit");
				}
				else if (explorerStillAlive && currentProcessId==g_runtime.explorer.processId &&
					currentTaskbar!=g_runtime.explorer.taskbar)
				{
					// A new taskbar HWND in the same Explorer cannot safely reuse the
					// retained managers or activation hooks. Latch the invalidation so a
					// late READY cannot make the obsolete target interactive again.
					g_runtime.targetInvalidated = true;
					g_runtime.status = A4S_MENU_HOST_STATUS_FAILED;
					DebugLog(L"same-process replacement taskbar requires an Explorer restart");
				}
				else if (TargetStillMatches())
				{
					// TaskbarCreated is a broadcast and can be replayed. The authoritative
					// taskbar still belongs to the connected Explorer.
					return 0;
				}
				else if (explorerStillAlive)
				{
					// A same-process taskbar recreation cannot safely restart retained
					// managers. It remains inert until a real process replacement.
					g_runtime.targetInvalidated = true;
					g_runtime.status = A4S_MENU_HOST_STATUS_FAILED;
					DebugLog(L"same-process taskbar recreation requires an Explorer restart");
				}
				else
				{
					g_runtime.activationCommitted = false;
					BeginConnection(false);
				}
			}
			return 0;
		}

		switch (message)
		{
		case WM_TIMER:
			if (wParam == kRetryTimer)
			{
				KillTimer(window, kRetryTimer);
				if (!TryInject())
					ScheduleRetry();
				return 0;
			}
			if (wParam == kInjectionTimer)
			{
				KillTimer(window, kInjectionTimer);
				if (!ExplorerProcessStillAlive())
				{
					g_runtime.initializationPending = false;
					g_runtime.activationCommitted = false;
					if (g_runtime.exitPending)
						DestroyWindow(window);
					else
						BeginConnection(false);
					return 0;
				}
				// A bootstrap can be consumed while an earlier host's synchronous
				// initialization is re-entrant. Re-advertise the same authenticated
				// attempt a bounded number of times so the eventual stable state replies
				// to this host without ever installing a second hook.
				if (g_runtime.bootstrapReplayCount<kBootstrapReplayLimit &&
					PostBootstrapMessage())
				{
					g_runtime.bootstrapReplayCount++;
					SetTimer(window,kInjectionTimer,kInjectionTimeoutMs,nullptr);
					DebugLog(L"Explorer initialization is pending; authenticated bootstrap re-posted");
				}
				else
				{
					if (!TargetStillMatches())
					{
						g_runtime.targetInvalidated = true;
						g_runtime.status = A4S_MENU_HOST_STATUS_FAILED;
					}
					DebugLog(L"Explorer initialization is still pending after the bounded bootstrap replay budget");
				}
				return 0;
			}
			if (wParam == kStopTimer)
			{
				KillTimer(window, kStopTimer);
				// Never reinject when cleanup was not acknowledged; that could duplicate
				// Explorer hooks. A new Explorer process is the only restart boundary.
				g_runtime.status = A4S_MENU_HOST_STATUS_FAILED;
				DebugLog(L"DLL disarm acknowledgment is still pending; watchdog retained");
				return 0;
			}
			if (wParam == kBootstrapUnhookTimer)
			{
				// This retry only removes the already-installed bootstrap hook. It
				// never creates a hook or starts a new Explorer injection attempt.
				UnhookBootstrap();
				return 0;
			}
			break;
		case WM_CLOSE:
			if (!g_runtime.exitPending)
				RequestStop();
			return 0;
		case WM_QUERYENDSESSION:
			return TRUE;
		case WM_ENDSESSION:
			if (wParam)
				DestroyWindow(window);
			return 0;
		case WM_DESTROY:
			PostQuitMessage(0);
			return 0;
		default:
			break;
		}
		return DefWindowProcW(window, message, wParam, lParam);
	}

	uint64_t HashBytes(uint64_t hash, const void *data, size_t size)
	{
		const BYTE *bytes = static_cast<const BYTE *>(data);
		for (size_t index = 0; index < size; ++index)
		{
			hash ^= bytes[index];
			hash *= UINT64_C(1099511628211);
		}
		return hash;
	}

	bool BuildInstanceMutexName(std::wstring &name)
	{
		std::vector<BYTE> tokenStorage;
		PSID sid = nullptr;
		if (!QueryTokenUser(GetCurrentProcess(), tokenStorage, sid))
			return false;
		DWORD desktopBytes = 0;
		HDESK desktop = GetThreadDesktop(GetCurrentThreadId());
		GetUserObjectInformationW(desktop, UOI_NAME, nullptr, 0, &desktopBytes);
		if (!desktopBytes)
			return false;
		std::vector<wchar_t> desktopName((desktopBytes / sizeof(wchar_t)) + 1);
		if (!GetUserObjectInformationW(desktop, UOI_NAME, desktopName.data(), desktopBytes,
			&desktopBytes))
			return false;
		DWORD sessionId = 0;
		if (!ProcessIdToSessionId(GetCurrentProcessId(), &sessionId))
			return false;

		uint64_t hash = UINT64_C(14695981039346656037);
		hash = HashBytes(hash, sid, GetLengthSid(sid));
		hash = HashBytes(hash, desktopName.data(), desktopBytes);
		wchar_t suffix[64] = {};
		swprintf_s(suffix, L".%lu.%016llX", sessionId, static_cast<unsigned long long>(hash));
		name = A4S_HOST_MUTEX_PREFIX_W;
		name += suffix;
		return true;
	}

	std::wstring QuoteCommandLineArgument(const wchar_t *argument)
	{
		const std::wstring value = argument ? argument : L"";
		if (!value.empty() && value.find_first_of(L" \t\n\v\"") == std::wstring::npos)
			return value;
		std::wstring quoted(1, L'"');
		size_t backslashes = 0;
		for (wchar_t ch : value)
		{
			if (ch == L'\\')
			{
				++backslashes;
				continue;
			}
			if (ch == L'"')
			{
				quoted.append(backslashes * 2 + 1, L'\\');
				quoted.push_back(L'"');
				backslashes = 0;
				continue;
			}
			quoted.append(backslashes, L'\\');
			backslashes = 0;
			quoted.push_back(ch);
		}
		quoted.append(backslashes * 2, L'\\');
		quoted.push_back(L'"');
		return quoted;
	}

	int RunElevated(int argc, wchar_t **argv)
	{
		if (argc < 3 || !argv[2][0])
			return ERROR_INVALID_PARAMETER;
		std::wstring parameters;
		for (int index = 3; index < argc; ++index)
		{
			if (!parameters.empty())
				parameters.push_back(L' ');
			parameters += QuoteCommandLineArgument(argv[index]);
		}
		SHELLEXECUTEINFOW execute = {};
		execute.cbSize = sizeof(execute);
		execute.fMask = SEE_MASK_NOASYNC | SEE_MASK_FLAG_LOG_USAGE | SEE_MASK_DOENVSUBST;
		execute.lpVerb = L"runas";
		execute.lpFile = argv[2];
		execute.lpParameters = parameters.empty() ? nullptr : parameters.c_str();
		execute.nShow = SW_SHOWNORMAL;
		if (!ShellExecuteExW(&execute))
			return static_cast<int>(GetLastError());
		return 0;
	}

	enum class LaunchCommand
	{
		Host,
		Toggle,
		Exit,
		Rehook,
		Status,
		Version,
		RunAs,
		Invalid,
	};

	LaunchCommand ParseCommand(int argc, wchar_t **argv)
	{
		if (argc == 1)
			return LaunchCommand::Host;
		if (_wcsicmp(argv[1], L"--runas") == 0 || _wcsicmp(argv[1], L"-runas") == 0)
			return LaunchCommand::RunAs;
		if (argc != 2)
			return LaunchCommand::Invalid;
		if (_wcsicmp(argv[1], L"--toggle") == 0) return LaunchCommand::Toggle;
		if (_wcsicmp(argv[1], L"--exit") == 0) return LaunchCommand::Exit;
		if (_wcsicmp(argv[1], L"--rehook") == 0) return LaunchCommand::Rehook;
		if (_wcsicmp(argv[1], L"--status") == 0) return LaunchCommand::Status;
		if (_wcsicmp(argv[1], L"--version") == 0) return LaunchCommand::Version;
		return LaunchCommand::Invalid;
	}

	A4SMenuHostControl ToHostControl(LaunchCommand command)
	{
		switch (command)
		{
		case LaunchCommand::Toggle: return A4S_MENU_HOST_CONTROL_TOGGLE;
		case LaunchCommand::Exit: return A4S_MENU_HOST_CONTROL_EXIT;
		case LaunchCommand::Rehook: return A4S_MENU_HOST_CONTROL_REHOOK;
		case LaunchCommand::Status: return A4S_MENU_HOST_CONTROL_STATUS;
		default: return static_cast<A4SMenuHostControl>(0);
		}
	}

	HWND FindExistingHostWindow()
	{
		for (unsigned attempt = 0; attempt < 80; ++attempt)
		{
			HWND window = FindWindowW(A4S_HOST_WINDOW_CLASS_W, A4S_HOST_WINDOW_TITLE_W);
			if (window)
				return window;
			Sleep(25);
		}
		return nullptr;
	}

	int ForwardToExistingHost(LaunchCommand command, UINT controlMessage)
	{
		HWND window = FindExistingHostWindow();
		if (!window)
			return ERROR_SERVICE_NOT_ACTIVE;
		if (command == LaunchCommand::Toggle)
		{
			DWORD hostProcessId = 0;
			GetWindowThreadProcessId(window, &hostProcessId);
			if (hostProcessId && !AllowSetForegroundWindow(hostProcessId))
				DebugLog(L"foreground authorization could not be delegated to the resident host");
		}
		DWORD_PTR result = 0;
		if (!SendMessageTimeoutW(window, controlMessage, static_cast<WPARAM>(ToHostControl(command)),
			0, SMTO_ABORTIFHUNG | SMTO_BLOCK, 2500, &result))
			return static_cast<int>(GetLastError());
		if (command == LaunchCommand::Status)
		{
			const auto status = static_cast<A4SMenuHostStatus>(result);
			WriteParentConsole(std::wstring(L"A4SMenuHost: ") + StatusText(status));
			return status == A4S_MENU_HOST_STATUS_READY ? 0 : static_cast<int>(status);
		}
		return result ? 0 : ERROR_GEN_FAILURE;
	}

	bool RegisterHostWindow(HINSTANCE instance)
	{
		WNDCLASSEXW windowClass = {};
		windowClass.cbSize = sizeof(windowClass);
		windowClass.lpfnWndProc = HostWindowProc;
		windowClass.hInstance = instance;
		windowClass.lpszClassName = A4S_HOST_WINDOW_CLASS_W;
		if (!RegisterClassExW(&windowClass) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS)
			return false;
		g_runtime.window = CreateWindowExW(WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
			A4S_HOST_WINDOW_CLASS_W, A4S_HOST_WINDOW_TITLE_W, WS_POPUP,
			0, 0, 0, 0, nullptr, nullptr, instance, nullptr);
		if (!g_runtime.window)
			return false;
		return true;
	}
}

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE, PWSTR, int)
{
#ifndef _WIN64
#error A4SMenuHost currently supports only the x64 Explorer product target.
#endif
	int argc = 0;
	wchar_t **argv = CommandLineToArgvW(GetCommandLineW(), &argc);
	if (!argv)
		return static_cast<int>(GetLastError());
	const LaunchCommand command = ParseCommand(argc, argv);
	if (command == LaunchCommand::RunAs)
	{
		const int result = RunElevated(argc, argv);
		LocalFree(argv);
		return result;
	}
	LocalFree(argv);
	if (command == LaunchCommand::Version)
	{
		WriteParentConsole(L"A4SMenuHost " A4S_PRODUCT_VERSION_STR_W);
		return 0;
	}
	if (command == LaunchCommand::Invalid)
		return ERROR_BAD_ARGUMENTS;

	g_runtime.instance = instance;
	g_runtime.hostControlMessage = RegisterWindowMessageW(A4S_HOST_CONTROL_MESSAGE_W);
	g_runtime.dllBootstrapMessage = RegisterWindowMessageW(A4S_DLL_BOOTSTRAP_MESSAGE_W);
	g_runtime.dllStatusMessage = RegisterWindowMessageW(A4S_DLL_STATUS_MESSAGE_W);
	g_runtime.menuCommandMessage = RegisterWindowMessageW(A4S_MENU_COMMAND_MESSAGE_W);
	g_runtime.taskbarCreatedMessage = RegisterWindowMessageW(A4S_TASKBAR_CREATED_MESSAGE_W);
	if (!g_runtime.hostControlMessage || !g_runtime.dllBootstrapMessage || !g_runtime.dllStatusMessage ||
		!g_runtime.menuCommandMessage || !g_runtime.taskbarCreatedMessage)
		return static_cast<int>(GetLastError());

	std::wstring mutexName;
	if (!BuildInstanceMutexName(mutexName))
		return static_cast<int>(GetLastError());
	SetLastError(ERROR_SUCCESS);
	UniqueHandle instanceMutex(CreateMutexW(nullptr, TRUE, mutexName.c_str()));
	const DWORD mutexError = GetLastError();
	if (!instanceMutex && mutexError != ERROR_ACCESS_DENIED)
		return static_cast<int>(mutexError);
	if (mutexError == ERROR_ALREADY_EXISTS || mutexError == ERROR_ACCESS_DENIED)
	{
		if (command == LaunchCommand::Host)
			return 0;
		return ForwardToExistingHost(command, g_runtime.hostControlMessage);
	}
	if (command == LaunchCommand::Status)
	{
		WriteParentConsole(L"A4SMenuHost: stopped");
		ReleaseMutex(instanceMutex.get());
		return ERROR_SERVICE_NOT_ACTIVE;
	}
	if (command == LaunchCommand::Exit)
	{
		ReleaseMutex(instanceMutex.get());
		return 0;
	}

	if (!RegisterHostWindow(instance))
	{
		ReleaseMutex(instanceMutex.get());
		return static_cast<int>(GetLastError());
	}
	if (command == LaunchCommand::Toggle)
		g_runtime.pendingToggle = true;
	BeginConnection(true);

	MSG message = {};
	int result = 0;
	bool running = true;
	while (running)
	{
		HANDLE handles[1] = { g_runtime.explorer.process.get() };
		const DWORD handleCount = handles[0] ? 1u : 0u;
		const DWORD waitResult = MsgWaitForMultipleObjectsEx(handleCount,
			handleCount ? handles : nullptr, INFINITE, QS_ALLINPUT, MWMO_INPUTAVAILABLE);
		if (waitResult == WAIT_FAILED)
		{
			result = static_cast<int>(GetLastError());
			break;
		}
		if (handleCount && waitResult == WAIT_OBJECT_0)
		{
			HandleExplorerProcessExit();
			continue;
		}
		if (waitResult != WAIT_OBJECT_0 + handleCount)
		{
			result = ERROR_GEN_FAILURE;
			break;
		}

		while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE))
		{
			if (message.message == WM_QUIT)
			{
				running = false;
				break;
			}
			TranslateMessage(&message);
			DispatchMessageW(&message);
		}
	}

	CancelConnectionTimers();
	if (g_runtime.window)
		KillTimer(g_runtime.window, kStopTimer);
	UnhookBootstrap();
	g_runtime.explorer.clear();
	if (g_runtime.menuDll)
		FreeLibrary(g_runtime.menuDll);
	if (g_runtime.window && IsWindow(g_runtime.window))
		DestroyWindow(g_runtime.window);
	ReleaseMutex(instanceMutex.get());
	return result;
}
