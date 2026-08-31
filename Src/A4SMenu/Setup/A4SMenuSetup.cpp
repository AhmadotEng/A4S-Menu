#include <Windows.h>
#include <RestartManager.h>
#include <bcrypt.h>
#include <shellapi.h>
#include <shlobj.h>
#include <tlhelp32.h>

#include <algorithm>
#include <array>
#include <cstdint>
#include <cstring>
#include <cwchar>
#include <exception>
#include <iterator>
#include <limits>
#include <span>
#include <string>
#include <string_view>
#include <vector>

#include "resource.h"
#include "../Shared/A4SProductApi.h"
#include "../Shared/A4SProductIdentity.h"

namespace
{
    constexpr wchar_t kStateKey[] = L"Software\\A4SMenu";
    constexpr wchar_t kServicingKey[] = L"Software\\A4SMenu\\Servicing";
    constexpr wchar_t kUninstallKey[] =
        L"Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\A4SMenu";
    constexpr wchar_t kRunKey[] = L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";
    constexpr wchar_t kRunOnceKey[] = L"Software\\Microsoft\\Windows\\CurrentVersion\\RunOnce";
    constexpr wchar_t kRunValue[] = L"A4SMenu";
    // The RunOnce '!' prefix asks Windows to remove the value after execution,
    // rather than before it. A failed cleanup therefore remains recoverable.
    constexpr wchar_t kCleanupRunOnceValue[] = L"!A4SMenuCleanup";
    constexpr wchar_t kRecoveryRunOnceValue[] = L"!A4SMenuServicingRecovery";
    constexpr wchar_t kSetupFilename[] = L"A4SMenuSetup.exe";
    constexpr wchar_t kVersionsDirectory[] = L"versions";
    // Global namespace serializes the same SID across simultaneous desktop/RDP
    // sessions; the SID-derived suffix still keeps different users independent.
    constexpr wchar_t kSetupMutexPrefix[] = L"Global\\A4SMenu.Setup.v1.";
    constexpr DWORD kStopTimeoutMs = 20000;
    constexpr DWORD kRestartTimeoutMs = 20000;
    constexpr size_t kMaximumPayloadBytes = 64U * 1024U * 1024U;

    class InstallerFailure
    {
    public:
        InstallerFailure(DWORD code, std::wstring message) : code(code), message(std::move(message)) {}
        DWORD code;
        std::wstring message;
    };

    [[noreturn]] void Fail(DWORD code, const wchar_t *message)
    {
        throw InstallerFailure(code ? code : ERROR_GEN_FAILURE, message ? message : L"A4S Menu setup failed.");
    }

    [[noreturn]] void FailLastError(const wchar_t *message)
    {
        Fail(GetLastError(), message);
    }

    class UniqueHandle
    {
    public:
        UniqueHandle() = default;
        explicit UniqueHandle(HANDLE handle) : handle_(handle) {}
        ~UniqueHandle() { reset(); }
        UniqueHandle(const UniqueHandle &) = delete;
        UniqueHandle &operator=(const UniqueHandle &) = delete;
        UniqueHandle(UniqueHandle &&other) noexcept : handle_(other.release()) {}
        UniqueHandle &operator=(UniqueHandle &&other) noexcept
        {
            if (this != &other)
                reset(other.release());
            return *this;
        }
        HANDLE get() const { return handle_; }
        explicit operator bool() const { return handle_ && handle_ != INVALID_HANDLE_VALUE; }
        HANDLE release()
        {
            HANDLE value = handle_;
            handle_ = nullptr;
            return value;
        }
        void reset(HANDLE value = nullptr)
        {
            if (handle_ && handle_ != INVALID_HANDLE_VALUE)
                CloseHandle(handle_);
            handle_ = value;
        }
    private:
        HANDLE handle_ = nullptr;
    };

    class UniqueRegKey
    {
    public:
        UniqueRegKey() = default;
        ~UniqueRegKey() { reset(); }
        UniqueRegKey(const UniqueRegKey &) = delete;
        UniqueRegKey &operator=(const UniqueRegKey &) = delete;
        UniqueRegKey(UniqueRegKey &&other) noexcept : key_(other.key_) { other.key_ = nullptr; }
        UniqueRegKey &operator=(UniqueRegKey &&other) noexcept
        {
            if (this != &other)
            {
                reset();
                key_ = other.key_;
                other.key_ = nullptr;
            }
            return *this;
        }
        HKEY *put()
        {
            reset();
            return &key_;
        }
        HKEY get() const { return key_; }
        void reset()
        {
            if (key_)
                RegCloseKey(key_);
            key_ = nullptr;
        }
    private:
        HKEY key_ = nullptr;
    };

    class OwnedMutex
    {
    public:
        OwnedMutex() = default;
        explicit OwnedMutex(HANDLE value) : value_(value) {}
        ~OwnedMutex()
        {
            if (value_)
            {
                ReleaseMutex(value_);
                CloseHandle(value_);
            }
        }
        OwnedMutex(const OwnedMutex &) = delete;
        OwnedMutex &operator=(const OwnedMutex &) = delete;
        OwnedMutex(OwnedMutex &&other) noexcept : value_(other.value_) { other.value_ = nullptr; }
        OwnedMutex &operator=(OwnedMutex &&) = delete;
    private:
        HANDLE value_ = nullptr;
    };

    class UniqueFindHandle
    {
    public:
        explicit UniqueFindHandle(HANDLE handle) : handle_(handle) {}
        ~UniqueFindHandle()
        {
            if (handle_ != INVALID_HANDLE_VALUE)
                FindClose(handle_);
        }
        UniqueFindHandle(const UniqueFindHandle &) = delete;
        UniqueFindHandle &operator=(const UniqueFindHandle &) = delete;
        HANDLE get() const { return handle_; }
        explicit operator bool() const { return handle_ != INVALID_HANDLE_VALUE; }
    private:
        HANDLE handle_ = INVALID_HANDLE_VALUE;
    };

    struct ResourceView
    {
        const std::uint8_t *data = nullptr;
        size_t size = 0;
    };

    struct PayloadSet
    {
        ResourceView host;
        ResourceView menu;
        std::vector<std::uint8_t> setup;
        std::wstring slotName;
    };

    enum class Operation
    {
        Automatic,
        Install,
        Repair,
        Uninstall,
        Rollback,
        Verify,
        SelfTest,
        Reconcile,
        ExtractTest,
        Cleanup,
        Version,
        Invalid,
    };

    struct Options
    {
        Operation operation = Operation::Automatic;
        bool silent = false;
        bool restartExplorer = false;
        // Only an explicit --repair is allowed to clear HostSafety. --update,
        // automatic install/repair, rollback, and install preserve user state.
        bool resetSafety = false;
        std::wstring extractPath;
        DWORD waitProcessId = 0;
        DWORD waitExplorerId = 0;
    };

    struct InstalledState
    {
        std::wstring activeSlot;
        std::wstring previousSlot;
    };

    using ProductVersion = std::uint64_t;

    enum class JournalTarget : DWORD
    {
        Installed = 1,
        Uninstalled = 2,
    };

    enum class RecoveryDisposition
    {
        DiscardIncomplete,
        RestorePrevious,
        KeepCommitted,
    };

    constexpr RecoveryDisposition ChooseRecoveryDisposition(bool snapshotComplete,
        bool readyToCommit, bool targetMatches)
    {
        if (!snapshotComplete)
            return RecoveryDisposition::DiscardIncomplete;
        return readyToCommit && targetMatches ? RecoveryDisposition::KeepCommitted
                                               : RecoveryDisposition::RestorePrevious;
    }

    static_assert(ChooseRecoveryDisposition(false, false, false) ==
        RecoveryDisposition::DiscardIncomplete);
    static_assert(ChooseRecoveryDisposition(true, false, true) ==
        RecoveryDisposition::RestorePrevious);
    static_assert(ChooseRecoveryDisposition(true, true, false) ==
        RecoveryDisposition::RestorePrevious);
    static_assert(ChooseRecoveryDisposition(true, true, true) ==
        RecoveryDisposition::KeepCommitted);

    struct RegistryValueSpec
    {
        const wchar_t *keyPath;
        const wchar_t *valueName;
    };

    constexpr RegistryValueSpec kRegistrationValues[] = {
        { kRunKey, kRunValue },
        { kRunOnceKey, kCleanupRunOnceValue },
        { kRunOnceKey, kRecoveryRunOnceValue },
        { kUninstallKey, L"DisplayName" },
        { kUninstallKey, L"DisplayVersion" },
        { kUninstallKey, L"Publisher" },
        { kUninstallKey, L"InstallLocation" },
        { kUninstallKey, L"DisplayIcon" },
        { kUninstallKey, L"UninstallString" },
        { kUninstallKey, L"QuietUninstallString" },
        { kUninstallKey, L"ModifyPath" },
        { kUninstallKey, L"NoModify" },
        { kUninstallKey, L"NoRepair" },
        { kUninstallKey, L"EstimatedSize" },
        { kStateKey, L"PreviousSlot" },
        { kStateKey, L"InstallVersion" },
        { kStateKey, L"ActiveSlot" },
    };

    struct RegistryValueSnapshot
    {
        bool present = false;
        DWORD type = REG_NONE;
        std::vector<std::uint8_t> data;
    };

    using RegistrationSnapshot =
        std::array<RegistryValueSnapshot, std::size(kRegistrationValues)>;

    struct ServicingJournal
    {
        RegistrationSnapshot previous;
        JournalTarget target = JournalTarget::Installed;
        std::wstring targetActive;
        std::wstring targetPrevious;
        std::wstring targetCleanupCommand;
        std::wstring targetRecoveryCommand;
        bool resetSafety = false;
    };

    std::wstring Quote(const std::wstring &value)
    {
        std::wstring result(1, L'"');
        size_t slashes = 0;
        for (wchar_t ch : value)
        {
            if (ch == L'\\')
            {
                ++slashes;
                continue;
            }
            if (ch == L'"')
            {
                result.append(slashes * 2U + 1U, L'\\');
                result.push_back(ch);
                slashes = 0;
                continue;
            }
            result.append(slashes, L'\\');
            slashes = 0;
            result.push_back(ch);
        }
        result.append(slashes * 2U, L'\\');
        result.push_back(L'"');
        return result;
    }

    void WriteParentConsole(const std::wstring &line)
    {
        if (!AttachConsole(ATTACH_PARENT_PROCESS) && GetLastError() != ERROR_ACCESS_DENIED)
            return;
        HANDLE output = GetStdHandle(STD_OUTPUT_HANDLE);
        if (!output || output == INVALID_HANDLE_VALUE)
            return;
        DWORD written = 0;
        const std::wstring text = line + L"\r\n";
        WriteConsoleW(output, text.data(), static_cast<DWORD>(text.size()), &written, nullptr);
    }

    std::wstring ModulePath()
    {
        std::vector<wchar_t> buffer(512);
        for (;;)
        {
            const DWORD length = GetModuleFileNameW(nullptr, buffer.data(), static_cast<DWORD>(buffer.size()));
            if (!length)
                FailLastError(L"Could not identify the setup executable.");
            if (length < buffer.size() - 1U)
                return std::wstring(buffer.data(), length);
            if (buffer.size() >= 32768U)
                Fail(ERROR_BUFFER_OVERFLOW, L"The setup path is too long.");
            buffer.resize(buffer.size() * 2U);
        }
    }

    std::wstring InstallRoot()
    {
        PWSTR localAppData = nullptr;
        const HRESULT result = SHGetKnownFolderPath(FOLDERID_LocalAppData, KF_FLAG_DEFAULT, nullptr, &localAppData);
        if (FAILED(result) || !localAppData)
            Fail(HRESULT_CODE(result), L"Could not locate LocalAppData.");
        std::wstring path(localAppData);
        CoTaskMemFree(localAppData);
        path += L"\\A4SMenu";
        return path;
    }

    std::wstring Join(const std::wstring &left, const wchar_t *right)
    {
        if (left.empty())
            return right ? right : L"";
        std::wstring result = left;
        if (result.back() != L'\\')
            result.push_back(L'\\');
        result += right ? right : L"";
        return result;
    }

    std::wstring FullPath(const std::wstring &path)
    {
        const DWORD required = GetFullPathNameW(path.c_str(), 0, nullptr, nullptr);
        if (!required || required > 32768U)
            FailLastError(L"Could not canonicalize an installation path.");
        std::vector<wchar_t> buffer(static_cast<size_t>(required) + 1U, L'\0');
        const DWORD length = GetFullPathNameW(path.c_str(), static_cast<DWORD>(buffer.size()),
            buffer.data(), nullptr);
        if (!length || length >= buffer.size())
            FailLastError(L"Could not canonicalize an installation path.");
        return std::wstring(buffer.data(), length);
    }

    void RejectReparsePoint(const std::wstring &path, bool allowMissing)
    {
        const DWORD attributes = GetFileAttributesW(path.c_str());
        if (attributes == INVALID_FILE_ATTRIBUTES)
        {
            if (allowMissing && GetLastError() == ERROR_FILE_NOT_FOUND)
                return;
            if (allowMissing && GetLastError() == ERROR_PATH_NOT_FOUND)
                return;
            FailLastError(L"Could not inspect an installation path.");
        }
        if ((attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0)
            Fail(ERROR_REPARSE_TAG_INVALID, L"A4S Menu refuses to install through a reparse point.");
    }

    void EnsureDirectory(const std::wstring &path)
    {
        if (CreateDirectoryW(path.c_str(), nullptr))
            return;
        if (GetLastError() != ERROR_ALREADY_EXISTS)
            FailLastError(L"Could not create an installation directory.");
        const DWORD attributes = GetFileAttributesW(path.c_str());
        if (attributes == INVALID_FILE_ATTRIBUTES || (attributes & FILE_ATTRIBUTE_DIRECTORY) == 0)
            Fail(ERROR_DIRECTORY, L"An installation path is not a directory.");
        RejectReparsePoint(path, false);
    }

    ResourceView LoadPayload(HINSTANCE instance, WORD identifier)
    {
        HRSRC resource = FindResourceW(instance, MAKEINTRESOURCEW(identifier), RT_RCDATA);
        if (!resource)
            FailLastError(L"An embedded A4S Menu payload is missing.");
        const DWORD size = SizeofResource(instance, resource);
        HGLOBAL loaded = LoadResource(instance, resource);
        const void *data = loaded ? LockResource(loaded) : nullptr;
        if (!size || !data || size > kMaximumPayloadBytes)
            Fail(ERROR_BAD_FORMAT, L"An embedded A4S Menu payload is invalid.");
        return { static_cast<const std::uint8_t *>(data), static_cast<size_t>(size) };
    }

    std::vector<std::uint8_t> ReadFileBytes(const std::wstring &path)
    {
        UniqueHandle file(CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_DELETE,
            nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL | FILE_FLAG_SEQUENTIAL_SCAN, nullptr));
        if (!file)
            FailLastError(L"Could not read a product file.");
        LARGE_INTEGER length = {};
        if (!GetFileSizeEx(file.get(), &length))
            FailLastError(L"Could not measure a product file.");
        if (length.QuadPart <= 0 || static_cast<ULONGLONG>(length.QuadPart) > kMaximumPayloadBytes)
            Fail(ERROR_FILE_TOO_LARGE, L"A product file has an invalid size.");
        std::vector<std::uint8_t> bytes(static_cast<size_t>(length.QuadPart));
        size_t offset = 0;
        while (offset < bytes.size())
        {
            const DWORD request = static_cast<DWORD>(std::min<size_t>(bytes.size() - offset,
                static_cast<size_t>(std::numeric_limits<DWORD>::max())));
            DWORD read = 0;
            if (!ReadFile(file.get(), bytes.data() + offset, request, &read, nullptr))
                FailLastError(L"Could not read a product file.");
            if (!read)
                Fail(ERROR_HANDLE_EOF, L"A product file ended unexpectedly.");
            offset += read;
        }
        return bytes;
    }

    ProductVersion FileProductVersion(const std::wstring &path)
    {
        DWORD ignored = 0;
        const DWORD bytes = GetFileVersionInfoSizeW(path.c_str(), &ignored);
        if (!bytes)
            FailLastError(L"A product file has no version information.");
        std::vector<std::uint8_t> version(bytes);
        if (!GetFileVersionInfoW(path.c_str(), 0, bytes, version.data()))
            FailLastError(L"Could not read product version information.");
        VS_FIXEDFILEINFO *fixed = nullptr;
        UINT fixedBytes = 0;
        if (!VerQueryValueW(version.data(), L"\\", reinterpret_cast<void **>(&fixed), &fixedBytes) ||
            !fixed || fixedBytes < sizeof(*fixed) || fixed->dwSignature != VS_FFI_SIGNATURE)
            Fail(ERROR_BAD_FORMAT, L"A product file has invalid version information.");
        return (static_cast<ProductVersion>(fixed->dwProductVersionMS) << 32U) |
            fixed->dwProductVersionLS;
    }

    std::wstring VersionText(ProductVersion version)
    {
        const DWORD high = static_cast<DWORD>(version >> 32U);
        const DWORD low = static_cast<DWORD>(version);
        return std::to_wstring(HIWORD(high)) + L"." + std::to_wstring(LOWORD(high)) + L"." +
            std::to_wstring(HIWORD(low)) + L"." + std::to_wstring(LOWORD(low));
    }

    void ValidatePe(std::span<const std::uint8_t> bytes, bool expectDll)
    {
        if (bytes.size() < sizeof(IMAGE_DOS_HEADER))
            Fail(ERROR_BAD_EXE_FORMAT, L"An embedded payload is not a PE image.");
        const auto *dos = reinterpret_cast<const IMAGE_DOS_HEADER *>(bytes.data());
        if (dos->e_magic != IMAGE_DOS_SIGNATURE || dos->e_lfanew <= 0)
            Fail(ERROR_BAD_EXE_FORMAT, L"An embedded payload has an invalid DOS header.");
        const size_t ntOffset = static_cast<size_t>(dos->e_lfanew);
        if (ntOffset > bytes.size() || bytes.size() - ntOffset < sizeof(IMAGE_NT_HEADERS64))
            Fail(ERROR_BAD_EXE_FORMAT, L"An embedded payload has an invalid PE offset.");
        const auto *nt = reinterpret_cast<const IMAGE_NT_HEADERS64 *>(bytes.data() + ntOffset);
        if (nt->Signature != IMAGE_NT_SIGNATURE || nt->FileHeader.Machine != IMAGE_FILE_MACHINE_AMD64 ||
            nt->OptionalHeader.Magic != IMAGE_NT_OPTIONAL_HDR64_MAGIC)
            Fail(ERROR_BAD_EXE_FORMAT, L"An embedded payload is not an x64 PE image.");
        const bool isDll = (nt->FileHeader.Characteristics & IMAGE_FILE_DLL) != 0;
        if (isDll != expectDll)
            Fail(ERROR_BAD_EXE_FORMAT, L"An embedded payload has the wrong PE type.");
    }

    std::array<std::uint8_t, 32> HashBytes(std::span<const std::uint8_t> bytes)
    {
        BCRYPT_ALG_HANDLE algorithm = nullptr;
        NTSTATUS status = BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM, nullptr, 0);
        if (status < 0)
            Fail(ERROR_CRC, L"Could not initialize SHA-256 validation.");
        std::array<std::uint8_t, 32> result = {};
        status = BCryptHash(algorithm, nullptr, 0,
            const_cast<PUCHAR>(bytes.data()), static_cast<ULONG>(bytes.size()),
            result.data(), static_cast<ULONG>(result.size()));
        BCryptCloseAlgorithmProvider(algorithm, 0);
        if (status < 0)
            Fail(ERROR_CRC, L"Could not hash an A4S Menu payload.");
        return result;
    }

    std::wstring Hex(const std::array<std::uint8_t, 32> &hash)
    {
        constexpr wchar_t digits[] = L"0123456789ABCDEF";
        std::wstring text;
        text.reserve(hash.size() * 2U);
        for (std::uint8_t value : hash)
        {
            text.push_back(digits[value >> 4U]);
            text.push_back(digits[value & 0x0FU]);
        }
        return text;
    }

    std::wstring PayloadSlotBase(std::wstring_view version,
        std::span<const std::uint8_t> host, std::span<const std::uint8_t> menu,
        std::span<const std::uint8_t> setup)
    {
        std::vector<std::uint8_t> identity;
        const auto hostHash = HashBytes(host);
        const auto menuHash = HashBytes(menu);
        const auto setupHash = HashBytes(setup);
        identity.reserve(hostHash.size() + menuHash.size() + setupHash.size());
        identity.insert(identity.end(), hostHash.begin(), hostHash.end());
        identity.insert(identity.end(), menuHash.begin(), menuHash.end());
        identity.insert(identity.end(), setupHash.begin(), setupHash.end());
        return std::wstring(version) + L"-" + Hex(HashBytes(identity));
    }

    constexpr bool IsUpperHex(std::wstring_view value)
    {
        return std::all_of(value.begin(), value.end(), [](wchar_t ch) {
            return (ch >= L'0' && ch <= L'9') || (ch >= L'A' && ch <= L'F');
        });
    }

    constexpr bool SlotNameMatchesPayload(std::wstring_view name, std::wstring_view payloadBase)
    {
        if (name == payloadBase)
            return true;

        // Version 1.0 setup used the first 80 bits of the same SHA-256 payload
        // identity. This prefix is intentionally frozen: future release-version
        // bumps must not extend truncated-identity acceptance beyond v1.0.
        constexpr std::wstring_view legacyV1Prefix = L"1.0.0.0-";
        const size_t dash = payloadBase.find(L'-');
        if (payloadBase.size() >= legacyV1Prefix.size() + 20U &&
            payloadBase.substr(0, legacyV1Prefix.size()) == legacyV1Prefix &&
            dash == legacyV1Prefix.size() - 1U)
        {
            const std::wstring_view legacy = payloadBase.substr(0, dash + 1U + 20U);
            if (name == legacy)
                return true;
        }

        constexpr std::wstring_view repairMarker = L".repair-";
        if (name.size() != payloadBase.size() + repairMarker.size() + 32U ||
            name.substr(0, payloadBase.size()) != payloadBase ||
            name.substr(payloadBase.size(), repairMarker.size()) != repairMarker)
            return false;
        return IsUpperHex(name.substr(payloadBase.size() + repairMarker.size()));
    }

    static_assert(SlotNameMatchesPayload(L"1.0.0.0-0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF",
        L"1.0.0.0-0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF"));
    static_assert(SlotNameMatchesPayload(L"1.0.0.0-0123456789ABCDEF0123",
        L"1.0.0.0-0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF"));
    static_assert(!SlotNameMatchesPayload(L"1.1.0.0-0123456789ABCDEF0123",
        L"1.1.0.0-0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF"));
    static_assert(!SlotNameMatchesPayload(L"1.0.0.0-not-a-payload",
        L"1.0.0.0-0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF"));
    static_assert(SlotNameMatchesPayload(
        L"1.0.0.0-0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF.repair-0123456789ABCDEF0123456789ABCDEF",
        L"1.0.0.0-0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF"));

    OwnedMutex AcquireSetupMutex()
    {
        UniqueHandle token;
        HANDLE rawToken = nullptr;
        if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &rawToken))
            FailLastError(L"Could not identify the current user for setup serialization.");
        token.reset(rawToken);

        DWORD bytes = 0;
        GetTokenInformation(token.get(), TokenUser, nullptr, 0, &bytes);
        if (!bytes || GetLastError() != ERROR_INSUFFICIENT_BUFFER)
            FailLastError(L"Could not measure the current-user identity.");
        std::vector<std::uint8_t> user(bytes);
        if (!GetTokenInformation(token.get(), TokenUser, user.data(), bytes, &bytes))
            FailLastError(L"Could not read the current-user identity.");
        const auto *tokenUser = reinterpret_cast<const TOKEN_USER *>(user.data());
        if (!IsValidSid(tokenUser->User.Sid))
            Fail(ERROR_INVALID_SID, L"The current-user identity is invalid.");
        const DWORD sidBytes = GetLengthSid(tokenUser->User.Sid);
        const auto identity = HashBytes(std::span(
            static_cast<const std::uint8_t *>(tokenUser->User.Sid), sidBytes));
        const std::wstring name = std::wstring(kSetupMutexPrefix) + Hex(identity).substr(0, 32);

        HANDLE mutex = CreateMutexW(nullptr, FALSE, name.c_str());
        if (!mutex)
            FailLastError(L"Could not create the A4S Menu servicing lock.");
        const DWORD wait = WaitForSingleObject(mutex, 0);
        if (wait == WAIT_TIMEOUT)
        {
            CloseHandle(mutex);
            Fail(ERROR_INSTALL_ALREADY_RUNNING, L"Another A4S Menu setup operation is already running for this user.");
        }
        if (wait != WAIT_OBJECT_0 && wait != WAIT_ABANDONED)
        {
            const DWORD error = GetLastError();
            CloseHandle(mutex);
            SetLastError(error);
            FailLastError(L"Could not acquire the A4S Menu servicing lock.");
        }
        return OwnedMutex(mutex);
    }

    PayloadSet LoadAndValidatePayloads(HINSTANCE instance)
    {
        PayloadSet payloads;
        payloads.host = LoadPayload(instance, IDR_A4S_HOST_PAYLOAD);
        payloads.menu = LoadPayload(instance, IDR_A4S_MENU_PAYLOAD);
        payloads.setup = ReadFileBytes(ModulePath());
        ValidatePe(std::span(payloads.host.data, payloads.host.size), false);
        ValidatePe(std::span(payloads.menu.data, payloads.menu.size), true);
        ValidatePe(payloads.setup, false);

        payloads.slotName = PayloadSlotBase(A4S_PRODUCT_VERSION_STR_W,
            std::span(payloads.host.data, payloads.host.size),
            std::span(payloads.menu.data, payloads.menu.size), payloads.setup);
        return payloads;
    }

    void WriteExactFile(const std::wstring &path, std::span<const std::uint8_t> bytes)
    {
        UniqueHandle file(CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_NEW,
            FILE_ATTRIBUTE_NORMAL | FILE_FLAG_WRITE_THROUGH, nullptr));
        if (!file)
            FailLastError(L"Could not create an installed product file.");
        size_t offset = 0;
        while (offset < bytes.size())
        {
            const DWORD request = static_cast<DWORD>(std::min<size_t>(bytes.size() - offset,
                static_cast<size_t>(std::numeric_limits<DWORD>::max())));
            DWORD written = 0;
            if (!WriteFile(file.get(), bytes.data() + offset, request, &written, nullptr) || !written)
                FailLastError(L"Could not write an installed product file.");
            offset += written;
        }
        if (!FlushFileBuffers(file.get()))
            FailLastError(L"Could not commit an installed product file.");
    }

    bool ExactFile(const std::wstring &path, std::span<const std::uint8_t> expected)
    {
        try
        {
            const auto actual = ReadFileBytes(path);
            return actual.size() == expected.size() &&
                std::equal(actual.begin(), actual.end(), expected.begin(), expected.end());
        }
        catch (const InstallerFailure &)
        {
            return false;
        }
    }

    std::wstring NewGuidName(const wchar_t *prefix)
    {
        GUID value = {};
        if (FAILED(CoCreateGuid(&value)))
            Fail(ERROR_GEN_FAILURE, L"Could not create an installation transaction identifier.");
        wchar_t buffer[64] = {};
        swprintf_s(buffer, L"%s%08lX%04hX%04hX%02hhX%02hhX%02hhX%02hhX%02hhX%02hhX%02hhX%02hhX",
            prefix, value.Data1, value.Data2, value.Data3, value.Data4[0], value.Data4[1], value.Data4[2],
            value.Data4[3], value.Data4[4], value.Data4[5], value.Data4[6], value.Data4[7]);
        return buffer;
    }

    // The checked wrapper is implemented after Explorer-module inspection.
    // No caller may bypass that inspection before removing a slot.
    bool RemoveKnownSlot(const std::wstring &slot);

    bool RemoveKnownSlotFilesUnchecked(const std::wstring &slot)
    {
        RejectReparsePoint(slot, true);
        bool complete = true;
        for (const wchar_t *name : { A4S_PRODUCT_HOST_FILENAME_W, A4S_PRODUCT_DLL_FILENAME_W, kSetupFilename })
        {
            const std::wstring path = Join(slot, name);
            const DWORD attributes = GetFileAttributesW(path.c_str());
            if (attributes == INVALID_FILE_ATTRIBUTES)
            {
                const DWORD error = GetLastError();
                if (error != ERROR_FILE_NOT_FOUND && error != ERROR_PATH_NOT_FOUND)
                    complete = false;
                continue;
            }
            // A directory or reparse point using a product filename is unknown
            // content. Preserve it and never follow it during bounded cleanup.
            if ((attributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) != 0)
                continue;
            if (!DeleteFileW(path.c_str()))
                complete = false;
        }
        if (!RemoveDirectoryW(slot.c_str()) && GetLastError() != ERROR_FILE_NOT_FOUND &&
            GetLastError() != ERROR_PATH_NOT_FOUND)
            complete = false;
        return complete;
    }

    void RemoveStagingBestEffort(const std::wstring &path)
    {
        try { RemoveKnownSlot(path); }
        catch (const InstallerFailure &) {}
    }

    bool ValidateSlotBasic(const std::wstring &slot)
    {
        if (slot.empty())
            return false;
        try
        {
            const std::wstring canonicalSlot = FullPath(slot);
            const std::wstring root = FullPath(InstallRoot());
            const std::wstring versions = FullPath(Join(root, kVersionsDirectory));
            const size_t slash = canonicalSlot.find_last_of(L"\\/");
            if (slash == std::wstring::npos || _wcsicmp(canonicalSlot.substr(0, slash).c_str(), versions.c_str()) != 0)
                return false;
            RejectReparsePoint(root, false);
            RejectReparsePoint(versions, false);
            RejectReparsePoint(canonicalSlot, false);
            const auto host = ReadFileBytes(Join(canonicalSlot, A4S_PRODUCT_HOST_FILENAME_W));
            const auto menu = ReadFileBytes(Join(canonicalSlot, A4S_PRODUCT_DLL_FILENAME_W));
            const auto setup = ReadFileBytes(Join(canonicalSlot, kSetupFilename));
            ValidatePe(host, false);
            ValidatePe(menu, true);
            ValidatePe(setup, false);
            const ProductVersion hostVersion = FileProductVersion(Join(canonicalSlot, A4S_PRODUCT_HOST_FILENAME_W));
            if (!hostVersion || hostVersion != FileProductVersion(Join(canonicalSlot, A4S_PRODUCT_DLL_FILENAME_W)) ||
                hostVersion != FileProductVersion(Join(canonicalSlot, kSetupFilename)))
                return false;
            const std::wstring expectedName = PayloadSlotBase(VersionText(hostVersion), host, menu, setup);
            const std::wstring_view actualName(canonicalSlot.c_str() + slash + 1U);
            return SlotNameMatchesPayload(actualName, expectedName);
        }
        catch (const InstallerFailure &)
        {
            return false;
        }
    }

    bool SlotMatchesPayload(const std::wstring &slot, const PayloadSet &payloads)
    {
        if (!ValidateSlotBasic(slot))
            return false;
        return ExactFile(Join(slot, A4S_PRODUCT_HOST_FILENAME_W),
                   std::span(payloads.host.data, payloads.host.size)) &&
            ExactFile(Join(slot, A4S_PRODUCT_DLL_FILENAME_W),
                std::span(payloads.menu.data, payloads.menu.size)) &&
            ExactFile(Join(slot, kSetupFilename), payloads.setup);
    }

    std::wstring DeploySlot(const PayloadSet &payloads, const std::wstring &preferredSlot)
    {
        const std::wstring root = InstallRoot();
        EnsureDirectory(root);
        RejectReparsePoint(root, false);
        const std::wstring versions = Join(root, kVersionsDirectory);
        EnsureDirectory(versions);
        RejectReparsePoint(versions, false);
        if (SlotMatchesPayload(preferredSlot, payloads))
            return FullPath(preferredSlot);

        std::wstring finalSlot = Join(versions, payloads.slotName.c_str());

        if (GetFileAttributesW(finalSlot.c_str()) != INVALID_FILE_ATTRIBUTES)
        {
            if (SlotMatchesPayload(finalSlot, payloads))
                return finalSlot;

            // An immutable slot may be incomplete or corrupt after storage
            // damage or an interrupted older installer. Never overwrite or
            // traverse it. A repair commits the same verified payload into a
            // fresh immutable recovery slot instead.
            finalSlot = Join(versions,
                (payloads.slotName + NewGuidName(L".repair-")).c_str());
        }

        const std::wstring staging = Join(versions, NewGuidName(L".stage-").c_str());
        EnsureDirectory(staging);
        try
        {
            WriteExactFile(Join(staging, A4S_PRODUCT_HOST_FILENAME_W),
                std::span(payloads.host.data, payloads.host.size));
            WriteExactFile(Join(staging, A4S_PRODUCT_DLL_FILENAME_W),
                std::span(payloads.menu.data, payloads.menu.size));
            WriteExactFile(Join(staging, kSetupFilename), payloads.setup);
            if (!ExactFile(Join(staging, A4S_PRODUCT_HOST_FILENAME_W),
                    std::span(payloads.host.data, payloads.host.size)) ||
                !ExactFile(Join(staging, A4S_PRODUCT_DLL_FILENAME_W),
                    std::span(payloads.menu.data, payloads.menu.size)) ||
                !ExactFile(Join(staging, kSetupFilename), payloads.setup))
                Fail(ERROR_CRC, L"The staged product failed byte-for-byte validation.");
            if (!MoveFileExW(staging.c_str(), finalSlot.c_str(), MOVEFILE_WRITE_THROUGH))
                FailLastError(L"Could not atomically commit the new A4S Menu version.");
        }
        catch (...)
        {
            RemoveStagingBestEffort(staging);
            throw;
        }
        return finalSlot;
    }

    UniqueRegKey OpenOrCreateKey(const wchar_t *path, REGSAM access = KEY_READ | KEY_WRITE)
    {
        UniqueRegKey key;
        DWORD disposition = 0;
        const LSTATUS status = RegCreateKeyExW(HKEY_CURRENT_USER, path, 0, nullptr,
            REG_OPTION_NON_VOLATILE, access, nullptr, key.put(), &disposition);
        if (status != ERROR_SUCCESS)
            Fail(static_cast<DWORD>(status), L"Could not open the A4S Menu user configuration.");
        return key;
    }

    std::wstring ReadString(HKEY root, const wchar_t *keyPath, const wchar_t *valueName)
    {
        UniqueRegKey key;
        if (RegOpenKeyExW(root, keyPath, 0, KEY_QUERY_VALUE, key.put()) != ERROR_SUCCESS)
            return {};
        DWORD type = 0;
        DWORD bytes = 0;
        if (RegQueryValueExW(key.get(), valueName, nullptr, &type, nullptr, &bytes) != ERROR_SUCCESS ||
            (type != REG_SZ && type != REG_EXPAND_SZ) || bytes < sizeof(wchar_t) ||
            bytes > 32768U * sizeof(wchar_t))
            return {};
        std::vector<wchar_t> value(bytes / sizeof(wchar_t) + 1U, L'\0');
        if (RegQueryValueExW(key.get(), valueName, nullptr, &type,
                reinterpret_cast<BYTE *>(value.data()), &bytes) != ERROR_SUCCESS)
            return {};
        value.back() = L'\0';
        return value.data();
    }

    void SetString(HKEY key, const wchar_t *name, const std::wstring &value)
    {
        const DWORD bytes = static_cast<DWORD>((value.size() + 1U) * sizeof(wchar_t));
        const LSTATUS status = RegSetValueExW(key, name, 0, REG_SZ,
            reinterpret_cast<const BYTE *>(value.c_str()), bytes);
        if (status != ERROR_SUCCESS)
            Fail(static_cast<DWORD>(status), L"Could not write the A4S Menu user configuration.");
    }

    void SetDword(HKEY key, const wchar_t *name, DWORD value)
    {
        const LSTATUS status = RegSetValueExW(key, name, 0, REG_DWORD,
            reinterpret_cast<const BYTE *>(&value), sizeof(value));
        if (status != ERROR_SUCCESS)
            Fail(static_cast<DWORD>(status), L"Could not write the A4S Menu user configuration.");
    }

    void DeleteValueChecked(const wchar_t *keyPath, const wchar_t *name);

    RegistryValueSnapshot ReadRawValue(const RegistryValueSpec &spec)
    {
        RegistryValueSnapshot snapshot;
        UniqueRegKey key;
        LSTATUS status = RegOpenKeyExW(HKEY_CURRENT_USER, spec.keyPath, 0,
            KEY_QUERY_VALUE, key.put());
        if (status == ERROR_FILE_NOT_FOUND || status == ERROR_PATH_NOT_FOUND)
            return snapshot;
        if (status != ERROR_SUCCESS)
            Fail(static_cast<DWORD>(status), L"Could not read A4S Menu registration for servicing.");

        DWORD bytes = 0;
        status = RegQueryValueExW(key.get(), spec.valueName, nullptr, &snapshot.type, nullptr, &bytes);
        if (status == ERROR_FILE_NOT_FOUND)
            return snapshot;
        if (status != ERROR_SUCCESS || bytes > 1024U * 1024U)
            Fail(status == ERROR_SUCCESS ? ERROR_FILE_TOO_LARGE : static_cast<DWORD>(status),
                L"Could not snapshot A4S Menu registration.");
        snapshot.data.resize(bytes);
        status = RegQueryValueExW(key.get(), spec.valueName, nullptr, &snapshot.type,
            snapshot.data.empty() ? nullptr : snapshot.data.data(), &bytes);
        if (status != ERROR_SUCCESS)
            Fail(static_cast<DWORD>(status), L"Could not snapshot A4S Menu registration.");
        snapshot.data.resize(bytes);
        snapshot.present = true;
        return snapshot;
    }

    RegistrationSnapshot CaptureRegistration()
    {
        RegistrationSnapshot snapshot;
        for (size_t index = 0; index < snapshot.size(); ++index)
            snapshot[index] = ReadRawValue(kRegistrationValues[index]);
        return snapshot;
    }

    void RestoreRawValue(const RegistryValueSpec &spec, const RegistryValueSnapshot &snapshot)
    {
        if (!snapshot.present)
        {
            DeleteValueChecked(spec.keyPath, spec.valueName);
            return;
        }
        auto key = OpenOrCreateKey(spec.keyPath);
        const LSTATUS status = RegSetValueExW(key.get(), spec.valueName, 0, snapshot.type,
            snapshot.data.empty() ? nullptr : snapshot.data.data(),
            static_cast<DWORD>(snapshot.data.size()));
        if (status != ERROR_SUCCESS)
            Fail(static_cast<DWORD>(status), L"Could not restore A4S Menu registration after a failed operation.");
    }

    void FlushKeyChecked(const wchar_t *keyPath, bool allowMissing = false)
    {
        UniqueRegKey key;
        const LSTATUS open = RegOpenKeyExW(HKEY_CURRENT_USER, keyPath, 0,
            KEY_QUERY_VALUE, key.put());
        if (allowMissing && (open == ERROR_FILE_NOT_FOUND || open == ERROR_PATH_NOT_FOUND))
            return;
        if (open != ERROR_SUCCESS)
            Fail(static_cast<DWORD>(open), L"Could not open A4S Menu registration for a durable commit.");
        const LSTATUS flush = RegFlushKey(key.get());
        if (flush != ERROR_SUCCESS)
            Fail(static_cast<DWORD>(flush), L"Could not durably commit A4S Menu registration.");
    }

    void RestoreRegistration(const RegistrationSnapshot &snapshot)
    {
        for (size_t index = 0; index < snapshot.size(); ++index)
            RestoreRawValue(kRegistrationValues[index], snapshot[index]);
        FlushKeyChecked(kRunKey, true);
        FlushKeyChecked(kRunOnceKey, true);
        FlushKeyChecked(kUninstallKey, true);
        FlushKeyChecked(kStateKey, true);
    }

    InstalledState ReadInstalledState()
    {
        InstalledState state;
        state.activeSlot = ReadString(HKEY_CURRENT_USER, kStateKey, L"ActiveSlot");
        state.previousSlot = ReadString(HKEY_CURRENT_USER, kStateKey, L"PreviousSlot");
        return state;
    }

    DWORD EstimateKilobytes(const std::wstring &slot)
    {
        ULONGLONG total = 0;
        for (const wchar_t *name : { A4S_PRODUCT_HOST_FILENAME_W, A4S_PRODUCT_DLL_FILENAME_W, kSetupFilename })
        {
            WIN32_FILE_ATTRIBUTE_DATA data = {};
            if (GetFileAttributesExW(Join(slot, name).c_str(), GetFileExInfoStandard, &data))
            {
                ULARGE_INTEGER size = {};
                size.HighPart = data.nFileSizeHigh;
                size.LowPart = data.nFileSizeLow;
                total += size.QuadPart;
            }
        }
        return static_cast<DWORD>(std::min<ULONGLONG>((total + 1023U) / 1024U,
            std::numeric_limits<DWORD>::max()));
    }

    void PrepareSlotRegistration(const std::wstring &active, const std::wstring &previous)
    {
        if (!ValidateSlotBasic(active))
            Fail(ERROR_FILE_CORRUPT, L"The selected A4S Menu version is incomplete.");
        const std::wstring host = Join(active, A4S_PRODUCT_HOST_FILENAME_W);
        const std::wstring setup = Join(active, kSetupFilename);
        const std::wstring startupCommand = Quote(host);
        if (startupCommand.size() >= 260U)
            Fail(ERROR_FILENAME_EXCED_RANGE, L"The per-user startup command exceeds the Windows Run-key limit.");

        auto uninstall = OpenOrCreateKey(kUninstallKey);
        SetString(uninstall.get(), L"DisplayName", L"A4S Menu");
        const ProductVersion version = FileProductVersion(host);
        SetString(uninstall.get(), L"DisplayVersion", VersionText(version));
        SetString(uninstall.get(), L"Publisher", L"A4SMenu Project");
        SetString(uninstall.get(), L"InstallLocation", InstallRoot());
        SetString(uninstall.get(), L"DisplayIcon", Quote(setup));
        SetString(uninstall.get(), L"UninstallString", Quote(setup) + L" --uninstall");
        SetString(uninstall.get(), L"QuietUninstallString", Quote(setup) + L" --uninstall --silent");
        SetString(uninstall.get(), L"ModifyPath", Quote(setup) + L" --repair");
        SetDword(uninstall.get(), L"NoModify", 0);
        SetDword(uninstall.get(), L"NoRepair", 0);
        SetDword(uninstall.get(), L"EstimatedSize", EstimateKilobytes(active));

        auto state = OpenOrCreateKey(kStateKey);
        SetString(state.get(), L"PreviousSlot", previous);
        SetString(state.get(), L"InstallVersion", VersionText(version));
        SetString(state.get(), L"ActiveSlot", active);

        // A committed install supersedes any deferred cleanup from an older,
        // interrupted uninstall. The journal restores that value if this
        // transaction does not reach the startup commit marker.
        DeleteValueChecked(kRunOnceKey, kCleanupRunOnceValue);
        FlushKeyChecked(kUninstallKey);
        FlushKeyChecked(kStateKey);
        FlushKeyChecked(kRunOnceKey, true);
    }

    void CommitSlotStartup(const std::wstring &active)
    {
        const std::wstring host = Join(active, A4S_PRODUCT_HOST_FILENAME_W);
        const std::wstring startupCommand = Quote(host);
        if (startupCommand.size() >= 260U)
            Fail(ERROR_FILENAME_EXCED_RANGE, L"The per-user startup command exceeds the Windows Run-key limit.");
        auto run = OpenOrCreateKey(kRunKey);
        SetString(run.get(), kRunValue, startupCommand);
        if (RegFlushKey(run.get()) != ERROR_SUCCESS)
            Fail(ERROR_WRITE_FAULT, L"Could not durably commit A4S Menu startup.");
    }

    void DeleteValueBestEffort(const wchar_t *keyPath, const wchar_t *name)
    {
        UniqueRegKey key;
        if (RegOpenKeyExW(HKEY_CURRENT_USER, keyPath, 0, KEY_SET_VALUE, key.put()) == ERROR_SUCCESS)
            RegDeleteValueW(key.get(), name);
    }

    void DeleteValueChecked(const wchar_t *keyPath, const wchar_t *name)
    {
        UniqueRegKey key;
        LSTATUS status = RegOpenKeyExW(HKEY_CURRENT_USER, keyPath, 0, KEY_SET_VALUE, key.put());
        if (status == ERROR_FILE_NOT_FOUND)
            return;
        if (status != ERROR_SUCCESS)
            Fail(static_cast<DWORD>(status), L"Could not open A4S Menu registration for removal.");
        status = RegDeleteValueW(key.get(), name);
        if (status != ERROR_SUCCESS && status != ERROR_FILE_NOT_FOUND)
            Fail(static_cast<DWORD>(status), L"Could not remove A4S Menu registration.");
    }

    void DeleteTreeChecked(const wchar_t *keyPath)
    {
        const LSTATUS status = RegDeleteTreeW(HKEY_CURRENT_USER, keyPath);
        if (status != ERROR_SUCCESS && status != ERROR_FILE_NOT_FOUND)
            Fail(static_cast<DWORD>(status), L"Could not remove A4S Menu registration.");
    }

    void PrepareUnregisterProduct()
    {
        for (const auto &spec : kRegistrationValues)
        {
            if (_wcsicmp(spec.keyPath, kRunKey) == 0 ||
                (_wcsicmp(spec.keyPath, kRunOnceKey) == 0 &&
                    _wcsicmp(spec.valueName, kCleanupRunOnceValue) == 0))
                continue;
            DeleteValueChecked(spec.keyPath, spec.valueName);
        }
        FlushKeyChecked(kUninstallKey, true);
        FlushKeyChecked(kStateKey, true);
        FlushKeyChecked(kRunOnceKey, true);
    }

    void CommitUnregisteredStartup()
    {
        DeleteValueChecked(kRunKey, kRunValue);
        FlushKeyChecked(kRunKey, true);
    }

    bool RawValueEquals(const RegistryValueSpec &spec, DWORD type,
        const void *data, size_t bytes)
    {
        const RegistryValueSnapshot value = ReadRawValue(spec);
        return value.present && value.type == type && value.data.size() == bytes &&
            (bytes == 0 || std::memcmp(value.data.data(), data, bytes) == 0);
    }

    bool StringValueEquals(const wchar_t *keyPath, const wchar_t *name,
        const std::wstring &expected)
    {
        const RegistryValueSpec spec = { keyPath, name };
        return RawValueEquals(spec, REG_SZ, expected.c_str(),
            (expected.size() + 1U) * sizeof(wchar_t));
    }

    bool DwordValueEquals(const wchar_t *keyPath, const wchar_t *name, DWORD expected)
    {
        const RegistryValueSpec spec = { keyPath, name };
        return RawValueEquals(spec, REG_DWORD, &expected, sizeof(expected));
    }

    bool RegistrationMatchesInstalledCore(const std::wstring &active,
        const std::wstring &previous)
    {
        if (!ValidateSlotBasic(active))
            return false;
        const std::wstring host = Join(active, A4S_PRODUCT_HOST_FILENAME_W);
        const std::wstring setup = Join(active, kSetupFilename);
        const ProductVersion version = FileProductVersion(host);
        return StringValueEquals(kRunKey, kRunValue, Quote(host)) &&
            StringValueEquals(kUninstallKey, L"DisplayName", L"A4S Menu") &&
            StringValueEquals(kUninstallKey, L"DisplayVersion", VersionText(version)) &&
            StringValueEquals(kUninstallKey, L"Publisher", L"A4SMenu Project") &&
            StringValueEquals(kUninstallKey, L"InstallLocation", InstallRoot()) &&
            StringValueEquals(kUninstallKey, L"DisplayIcon", Quote(setup)) &&
            StringValueEquals(kUninstallKey, L"UninstallString", Quote(setup) + L" --uninstall") &&
            StringValueEquals(kUninstallKey, L"QuietUninstallString",
                Quote(setup) + L" --uninstall --silent") &&
            StringValueEquals(kUninstallKey, L"ModifyPath", Quote(setup) + L" --repair") &&
            DwordValueEquals(kUninstallKey, L"NoModify", 0) &&
            DwordValueEquals(kUninstallKey, L"NoRepair", 0) &&
            DwordValueEquals(kUninstallKey, L"EstimatedSize", EstimateKilobytes(active)) &&
            StringValueEquals(kStateKey, L"PreviousSlot", previous) &&
            StringValueEquals(kStateKey, L"InstallVersion", VersionText(version)) &&
            StringValueEquals(kStateKey, L"ActiveSlot", active);
    }

    bool RegistrationMatchesSlot(const std::wstring &active, const std::wstring &previous,
        const std::wstring &recoveryCommand)
    {
        const RegistryValueSpec cleanup = { kRunOnceKey, kCleanupRunOnceValue };
        return !ReadRawValue(cleanup).present &&
            StringValueEquals(kRunOnceKey, kRecoveryRunOnceValue, recoveryCommand) &&
            RegistrationMatchesInstalledCore(active, previous);
    }

    bool RegistrationMatchesCommittedSlot(const std::wstring &active,
        const std::wstring &previous)
    {
        const RegistryValueSpec cleanup = { kRunOnceKey, kCleanupRunOnceValue };
        const RegistryValueSpec recovery = { kRunOnceKey, kRecoveryRunOnceValue };
        return !ReadRawValue(cleanup).present && !ReadRawValue(recovery).present &&
            RegistrationMatchesInstalledCore(active, previous);
    }

    bool RegistrationMatchesUninstalled(const std::wstring &cleanupCommand)
    {
        for (const auto &spec : kRegistrationValues)
        {
            if (_wcsicmp(spec.keyPath, kRunOnceKey) == 0 &&
                _wcsicmp(spec.valueName, kCleanupRunOnceValue) == 0)
                continue;
            if (ReadRawValue(spec).present)
                return false;
        }
        return StringValueEquals(kRunOnceKey, kCleanupRunOnceValue, cleanupCommand);
    }

    void SetBinary(HKEY key, const wchar_t *name, std::span<const std::uint8_t> value)
    {
        const LSTATUS status = RegSetValueExW(key, name, 0, REG_BINARY,
            value.empty() ? nullptr : value.data(), static_cast<DWORD>(value.size()));
        if (status != ERROR_SUCCESS)
            Fail(static_cast<DWORD>(status), L"Could not persist the A4S Menu servicing journal.");
    }

    std::wstring SnapshotValueName(size_t index)
    {
        wchar_t name[32] = {};
        swprintf_s(name, L"Snapshot%02zu", index);
        return name;
    }

    std::vector<std::uint8_t> SerializeSnapshot(const RegistryValueSnapshot &snapshot)
    {
        constexpr DWORD magic = 0x53345341; // A4SS
        const DWORD present = snapshot.present ? 1U : 0U;
        const DWORD size = static_cast<DWORD>(snapshot.data.size());
        std::vector<std::uint8_t> blob(sizeof(DWORD) * 4U + snapshot.data.size());
        DWORD header[] = { magic, present, snapshot.type, size };
        std::memcpy(blob.data(), header, sizeof(header));
        if (!snapshot.data.empty())
            std::memcpy(blob.data() + sizeof(header), snapshot.data.data(), snapshot.data.size());
        return blob;
    }

    RegistryValueSnapshot DeserializeSnapshot(std::span<const std::uint8_t> blob)
    {
        constexpr DWORD magic = 0x53345341;
        if (blob.size() < sizeof(DWORD) * 4U)
            Fail(ERROR_FILE_CORRUPT, L"The A4S Menu servicing journal is truncated.");
        DWORD header[4] = {};
        std::memcpy(header, blob.data(), sizeof(header));
        if (header[0] != magic || header[1] > 1U ||
            header[3] != blob.size() - sizeof(header) || header[3] > 1024U * 1024U)
            Fail(ERROR_FILE_CORRUPT, L"The A4S Menu servicing journal is invalid.");
        RegistryValueSnapshot snapshot;
        snapshot.present = header[1] != 0;
        snapshot.type = header[2];
        snapshot.data.assign(blob.begin() + sizeof(header), blob.end());
        if (!snapshot.present && (!snapshot.data.empty() || snapshot.type != REG_NONE))
            Fail(ERROR_FILE_CORRUPT, L"The A4S Menu servicing journal has an invalid absent value.");
        return snapshot;
    }

    bool ReadJournalDword(const wchar_t *name, DWORD &value)
    {
        const RegistryValueSpec spec = { kServicingKey, name };
        const RegistryValueSnapshot raw = ReadRawValue(spec);
        if (!raw.present || raw.type != REG_DWORD || raw.data.size() != sizeof(value))
            return false;
        std::memcpy(&value, raw.data.data(), sizeof(value));
        return true;
    }

    bool JournalExists()
    {
        UniqueRegKey key;
        const LSTATUS status = RegOpenKeyExW(HKEY_CURRENT_USER, kServicingKey, 0,
            KEY_QUERY_VALUE, key.put());
        if (status == ERROR_FILE_NOT_FOUND || status == ERROR_PATH_NOT_FOUND)
            return false;
        if (status != ERROR_SUCCESS)
            Fail(static_cast<DWORD>(status), L"Could not inspect the A4S Menu servicing journal.");
        return true;
    }

    ServicingJournal LoadJournal()
    {
        ServicingJournal journal;
        DWORD target = 0;
        DWORD resetSafety = 0;
        if (!ReadJournalDword(L"Target", target) ||
            (target != static_cast<DWORD>(JournalTarget::Installed) &&
                target != static_cast<DWORD>(JournalTarget::Uninstalled)) ||
            !ReadJournalDword(L"ResetSafety", resetSafety) || resetSafety > 1U)
            Fail(ERROR_FILE_CORRUPT, L"The A4S Menu servicing journal metadata is invalid.");
        journal.target = static_cast<JournalTarget>(target);
        journal.resetSafety = resetSafety != 0;
        journal.targetActive = ReadString(HKEY_CURRENT_USER, kServicingKey, L"TargetActive");
        journal.targetPrevious = ReadString(HKEY_CURRENT_USER, kServicingKey, L"TargetPrevious");
        journal.targetCleanupCommand = ReadString(HKEY_CURRENT_USER, kServicingKey, L"TargetCleanup");
        journal.targetRecoveryCommand = ReadString(HKEY_CURRENT_USER, kServicingKey, L"TargetRecovery");
        for (size_t index = 0; index < journal.previous.size(); ++index)
        {
            const std::wstring name = SnapshotValueName(index);
            const RegistryValueSpec spec = { kServicingKey, name.c_str() };
            const RegistryValueSnapshot raw = ReadRawValue(spec);
            if (!raw.present || raw.type != REG_BINARY)
                Fail(ERROR_FILE_CORRUPT, L"The A4S Menu servicing journal snapshot is incomplete.");
            journal.previous[index] = DeserializeSnapshot(raw.data);
        }
        return journal;
    }

    ServicingJournal BeginJournal(JournalTarget target, const std::wstring &active,
        const std::wstring &previous, const std::wstring &cleanupCommand,
        const std::wstring &recoveryCommand, bool resetSafety)
    {
        DeleteTreeChecked(kServicingKey);
        ServicingJournal journal;
        journal.previous = CaptureRegistration();
        journal.target = target;
        journal.targetActive = active;
        journal.targetPrevious = previous;
        journal.targetCleanupCommand = cleanupCommand;
        journal.targetRecoveryCommand = recoveryCommand;
        journal.resetSafety = resetSafety;

        auto key = OpenOrCreateKey(kServicingKey);
        SetDword(key.get(), L"SnapshotComplete", 0);
        SetDword(key.get(), L"ReadyToCommit", 0);
        SetDword(key.get(), L"Target", static_cast<DWORD>(target));
        SetDword(key.get(), L"ResetSafety", resetSafety ? 1U : 0U);
        SetString(key.get(), L"TargetActive", active);
        SetString(key.get(), L"TargetPrevious", previous);
        SetString(key.get(), L"TargetCleanup", cleanupCommand);
        SetString(key.get(), L"TargetRecovery", recoveryCommand);
        for (size_t index = 0; index < journal.previous.size(); ++index)
        {
            const std::wstring name = SnapshotValueName(index);
            const auto blob = SerializeSnapshot(journal.previous[index]);
            SetBinary(key.get(), name.c_str(), blob);
        }
        SetDword(key.get(), L"SnapshotComplete", 1);
        if (RegFlushKey(key.get()) != ERROR_SUCCESS)
            Fail(ERROR_WRITE_FAULT, L"Could not durably commit the A4S Menu servicing journal.");
        return journal;
    }

    void MarkJournalReady()
    {
        auto key = OpenOrCreateKey(kServicingKey);
        SetDword(key.get(), L"ReadyToCommit", 1);
        if (RegFlushKey(key.get()) != ERROR_SUCCESS)
            Fail(ERROR_WRITE_FAULT, L"Could not durably commit the A4S Menu registration marker.");
    }

    void ClearSafetyStateChecked()
    {
        DeleteTreeChecked(A4S_HOST_SAFETY_REGISTRY_W);
    }

    void DeleteJournalDurably()
    {
        DeleteTreeChecked(kServicingKey);
        // kServicingKey is a child of kStateKey. Flushing the surviving parent
        // makes removal of the recovery record durable across power loss.
        FlushKeyChecked(kStateKey, true);
    }

    void RollBackJournal(const ServicingJournal &journal)
    {
        RestoreRegistration(journal.previous);
        DeleteJournalDurably();
    }

    void CompleteJournal(const ServicingJournal &journal)
    {
        if (journal.resetSafety)
            ClearSafetyStateChecked();
        DeleteJournalDurably();
        if (!journal.targetRecoveryCommand.empty())
        {
            DeleteValueChecked(kRunOnceKey, kRecoveryRunOnceValue);
            FlushKeyChecked(kRunOnceKey, true);
        }
    }

    void ReconcilePendingJournal()
    {
        if (!JournalExists())
            return;
        DWORD snapshotComplete = 0;
        DWORD readyToCommit = 0;
        const bool hasSnapshot = ReadJournalDword(L"SnapshotComplete", snapshotComplete) &&
            snapshotComplete == 1U;
        const bool ready = ReadJournalDword(L"ReadyToCommit", readyToCommit) &&
            readyToCommit == 1U;
        if (!hasSnapshot)
        {
            DeleteJournalDurably();
            return;
        }

        const ServicingJournal journal = LoadJournal();
        const bool targetMatches = journal.target == JournalTarget::Installed ?
            RegistrationMatchesSlot(journal.targetActive, journal.targetPrevious,
                journal.targetRecoveryCommand) :
            RegistrationMatchesUninstalled(journal.targetCleanupCommand);
        switch (ChooseRecoveryDisposition(true, ready, targetMatches))
        {
        case RecoveryDisposition::KeepCommitted:
            CompleteJournal(journal);
            break;
        case RecoveryDisposition::RestorePrevious:
            RollBackJournal(journal);
            break;
        case RecoveryDisposition::DiscardIncomplete:
            DeleteJournalDurably();
            break;
        }
    }

    void RunInternalSelfTest(HINSTANCE instance)
    {
        const PayloadSet payloads = LoadAndValidatePayloads(instance);
        const size_t fullIdentityLength = wcslen(A4S_PRODUCT_VERSION_STR_W) + 1U + 64U;
        const std::wstring legacyName = payloads.slotName.substr(0,
            wcslen(A4S_PRODUCT_VERSION_STR_W) + 1U + 20U);
        const bool legacyExpected = payloads.slotName.starts_with(L"1.0.0.0-");
        if (payloads.slotName.size() != fullIdentityLength ||
            !SlotNameMatchesPayload(payloads.slotName, payloads.slotName) ||
            SlotNameMatchesPayload(legacyName, payloads.slotName) != legacyExpected ||
            SlotNameMatchesPayload(payloads.slotName + L".arbitrary", payloads.slotName) ||
            !SlotNameMatchesPayload(payloads.slotName +
                L".repair-0123456789ABCDEF0123456789ABCDEF", payloads.slotName) ||
            SlotNameMatchesPayload(payloads.slotName +
                L".repair-0123456789abcdef0123456789abcdef", payloads.slotName))
            Fail(ERROR_INVALID_DATA, L"The immutable-slot identity self-test failed.");

        RegistryValueSnapshot value;
        value.present = true;
        value.type = REG_BINARY;
        value.data = { 0, 1, 2, 3, 0xFE, 0xFF };
        const RegistryValueSnapshot restored = DeserializeSnapshot(SerializeSnapshot(value));
        const RegistryValueSnapshot absent;
        const RegistryValueSnapshot restoredAbsent = DeserializeSnapshot(SerializeSnapshot(absent));
        bool rejectedTruncatedSnapshot = false;
        try
        {
            const std::array<std::uint8_t, 3> truncated = { 1, 2, 3 };
            (void)DeserializeSnapshot(truncated);
        }
        catch (const InstallerFailure &)
        {
            rejectedTruncatedSnapshot = true;
        }
        if (!restored.present || restored.type != value.type || restored.data != value.data ||
            restoredAbsent.present || restoredAbsent.type != REG_NONE || !restoredAbsent.data.empty() ||
            !rejectedTruncatedSnapshot ||
            ChooseRecoveryDisposition(false, false, false) != RecoveryDisposition::DiscardIncomplete ||
            ChooseRecoveryDisposition(false, false, true) != RecoveryDisposition::DiscardIncomplete ||
            ChooseRecoveryDisposition(false, true, false) != RecoveryDisposition::DiscardIncomplete ||
            ChooseRecoveryDisposition(false, true, true) != RecoveryDisposition::DiscardIncomplete ||
            ChooseRecoveryDisposition(true, false, false) != RecoveryDisposition::RestorePrevious ||
            ChooseRecoveryDisposition(true, false, true) != RecoveryDisposition::RestorePrevious ||
            ChooseRecoveryDisposition(true, true, false) != RecoveryDisposition::RestorePrevious ||
            ChooseRecoveryDisposition(true, true, true) != RecoveryDisposition::KeepCommitted)
            Fail(ERROR_INVALID_DATA, L"The servicing-recovery self-test failed.");
    }

    bool StopHost()
    {
        HWND host = FindWindowW(A4S_HOST_WINDOW_CLASS_W, A4S_HOST_WINDOW_TITLE_W);
        if (!host)
            return false;
        const UINT control = RegisterWindowMessageW(A4S_HOST_CONTROL_MESSAGE_W);
        if (!control)
            FailLastError(L"Could not register the A4S Menu stop command.");
        DWORD_PTR accepted = 0;
        if (!SendMessageTimeoutW(host, control, A4S_MENU_HOST_CONTROL_EXIT, 0,
                SMTO_ABORTIFHUNG | SMTO_BLOCK, 5000, &accepted) || !accepted)
            Fail(ERROR_BUSY, L"The running A4S Menu host did not accept a clean stop request.");
        const ULONGLONG deadline = GetTickCount64() + kStopTimeoutMs;
        while (IsWindow(host) && GetTickCount64() < deadline)
            Sleep(25);
        if (IsWindow(host))
            Fail(ERROR_TIMEOUT, L"A4S Menu did not finish its clean logical unhook in time.");
        return true;
    }

    DWORD ExplorerProcessId()
    {
        HWND taskbar = FindWindowW(L"Shell_TrayWnd", nullptr);
        DWORD processId = 0;
        if (taskbar)
            GetWindowThreadProcessId(taskbar, &processId);
        return processId;
    }

    struct ExplorerModuleInspection
    {
        bool complete = false;
        bool unknownA4SModule = false;
        std::vector<std::wstring> modulePaths;
        std::vector<std::wstring> validatedSlots;

        bool RequiresRestartBoundary() const
        {
            return !complete || unknownA4SModule || !modulePaths.empty();
        }

        bool ProtectsSlot(const std::wstring &slot) const
        {
            return std::any_of(validatedSlots.begin(), validatedSlots.end(),
                [&](const std::wstring &candidate) {
                    return _wcsicmp(candidate.c_str(), slot.c_str()) == 0;
                });
        }
    };

    constexpr bool CanPruneKnownSlot(bool enumerationComplete,
        bool unknownA4SModule, bool slotMapped)
    {
        return enumerationComplete && !unknownA4SModule && !slotMapped;
    }

    static_assert(CanPruneKnownSlot(true, false, false));
    static_assert(!CanPruneKnownSlot(false, false, false));
    static_assert(!CanPruneKnownSlot(true, true, false));
    static_assert(!CanPruneKnownSlot(true, false, true));

    void AddUniquePath(std::vector<std::wstring> &paths, const std::wstring &path)
    {
        if (std::none_of(paths.begin(), paths.end(), [&](const std::wstring &candidate) {
                return _wcsicmp(candidate.c_str(), path.c_str()) == 0;
            }))
            paths.push_back(path);
    }

    ExplorerModuleInspection InspectExplorerA4SModules(DWORD processId)
    {
        ExplorerModuleInspection result;
        if (!processId)
            return result;
        UniqueHandle snapshot(CreateToolhelp32Snapshot(TH32CS_SNAPMODULE | TH32CS_SNAPMODULE32, processId));
        if (!snapshot)
            return result;
        MODULEENTRY32W entry = {};
        entry.dwSize = sizeof(entry);
        if (!Module32FirstW(snapshot.get(), &entry))
        {
            result.complete = GetLastError() == ERROR_NO_MORE_FILES;
            return result;
        }
        do
        {
            const wchar_t *filename = wcsrchr(entry.szExePath, L'\\');
            filename = filename ? filename + 1 : entry.szExePath;
            if (_wcsicmp(filename, A4S_PRODUCT_DLL_FILENAME_W) == 0 ||
                _wcsicmp(entry.szModule, A4S_PRODUCT_DLL_FILENAME_W) == 0)
            {
                // Preserve every matching observation. A path that cannot be
                // canonicalized or tied to a validated immutable slot is an
                // explicit unknown mapping and protects every slot from
                // pruning rather than being mistaken for "not mapped".
                if (!entry.szExePath[0])
                {
                    result.unknownA4SModule = true;
                    continue;
                }
                AddUniquePath(result.modulePaths, entry.szExePath);
                try
                {
                    const std::wstring modulePath = FullPath(entry.szExePath);
                    AddUniquePath(result.modulePaths, modulePath);
                    const size_t slash = modulePath.find_last_of(L"\\/");
                    const std::wstring slot = slash == std::wstring::npos ? L"" :
                        modulePath.substr(0, slash);
                    if (!slot.empty() && ValidateSlotBasic(slot))
                        AddUniquePath(result.validatedSlots, slot);
                    else
                        result.unknownA4SModule = true;
                }
                catch (const InstallerFailure &)
                {
                    result.unknownA4SModule = true;
                }
            }
        }
        while (Module32NextW(snapshot.get(), &entry));
        result.complete = GetLastError() == ERROR_NO_MORE_FILES;
        return result;
    }

    bool ExplorerHasA4SModule(DWORD processId)
    {
        return InspectExplorerA4SModules(processId).RequiresRestartBoundary();
    }

    bool RemoveKnownSlot(const std::wstring &slot)
    {
        const std::wstring canonicalSlot = FullPath(slot);
        const ExplorerModuleInspection inspection =
            InspectExplorerA4SModules(ExplorerProcessId());
        if (!CanPruneKnownSlot(inspection.complete,
                inspection.unknownA4SModule, inspection.ProtectsSlot(canonicalSlot)))
            return false;
        return RemoveKnownSlotFilesUnchecked(canonicalSlot);
    }

    bool StartHost(const std::wstring &slot)
    {
        const std::wstring executable = Join(slot, A4S_PRODUCT_HOST_FILENAME_W);
        std::wstring command = Quote(executable);
        STARTUPINFOW startup = {};
        startup.cb = sizeof(startup);
        PROCESS_INFORMATION process = {};
        if (!CreateProcessW(executable.c_str(), command.data(), nullptr, nullptr, FALSE,
                CREATE_UNICODE_ENVIRONMENT, nullptr, slot.c_str(), &startup, &process))
            return false;
        CloseHandle(process.hThread);
        CloseHandle(process.hProcess);
        return true;
    }

    bool RestartExplorerWithConsent(DWORD processId)
    {
        if (!processId)
            return false;
        UniqueHandle explorer(OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE, FALSE, processId));
        if (!explorer)
            return false;
        FILETIME creation = {}, exit = {}, kernel = {}, user = {};
        if (!GetProcessTimes(explorer.get(), &creation, &exit, &kernel, &user))
            return false;
        RM_UNIQUE_PROCESS process = {};
        process.dwProcessId = processId;
        process.ProcessStartTime = creation;
        DWORD session = 0;
        WCHAR key[CCH_RM_SESSION_KEY + 1] = {};
        if (RmStartSession(&session, 0, key) != ERROR_SUCCESS)
            return false;
        const DWORD registration = RmRegisterResources(session, 0, nullptr, 1, &process, 0, nullptr);
        DWORD shutdown = registration;
        DWORD restart = registration;
        if (registration == ERROR_SUCCESS)
        {
            shutdown = RmShutdown(session, RmForceShutdown, nullptr);
            // Restart Manager requires RmRestart even when RmShutdown reports
            // that not every registered application stopped. Explorer may also
            // restart itself, so the PID transition below is authoritative.
            restart = RmRestart(session, 0, nullptr);
        }
        RmEndSession(session);
        if (registration != ERROR_SUCCESS)
            return false;
        const DWORD oldExit = WaitForSingleObject(explorer.get(), kRestartTimeoutMs);
        if (oldExit != WAIT_OBJECT_0)
            return false;
        const ULONGLONG deadline = GetTickCount64() + kRestartTimeoutMs;
        while (GetTickCount64() < deadline)
        {
            const DWORD replacement = ExplorerProcessId();
            if (replacement && replacement != processId)
                return true;
            Sleep(50);
        }
        // A Restart Manager participant is restartable only if it registered
        // for application restart. Explorer normally recreates its shell on
        // exit, but explicitly launch it after the consented shutdown if that
        // did not happen. No launch occurs unless the old PID really exited.
        std::vector<wchar_t> windowsDirectory(512);
        UINT windowsLength = GetWindowsDirectoryW(windowsDirectory.data(),
            static_cast<UINT>(windowsDirectory.size()));
        if (!windowsLength || windowsLength >= windowsDirectory.size())
            return false;
        const std::wstring explorerPath = Join(
            std::wstring(windowsDirectory.data(), windowsLength), L"explorer.exe");
        SHELLEXECUTEINFOW execute = {};
        execute.cbSize = sizeof(execute);
        execute.fMask = SEE_MASK_NOASYNC;
        execute.lpFile = explorerPath.c_str();
        execute.nShow = SW_SHOWNORMAL;
        if (!ShellExecuteExW(&execute))
            return false;
        const ULONGLONG fallbackDeadline = GetTickCount64() + kRestartTimeoutMs;
        while (GetTickCount64() < fallbackDeadline)
        {
            const DWORD replacement = ExplorerProcessId();
            if (replacement && replacement != processId)
                return true;
            Sleep(50);
        }
        (void)shutdown;
        (void)restart;
        return false;
    }

    bool PromptRestart(bool silent, bool explicitRestart)
    {
        if (explicitRestart)
            return true;
        if (silent)
            return false;
        return MessageBoxW(nullptr,
            L"A4S Menu has been safely disarmed. Activating the new files requires restarting Windows Explorer.\n\n"
            L"Restart Explorer now? Open File Explorer windows will close.",
            L"A4S Menu Setup", MB_YESNO | MB_ICONWARNING | MB_DEFBUTTON2) == IDYES;
    }

    void WaitForProcessId(DWORD processId)
    {
        if (!processId || processId == GetCurrentProcessId())
            return;
        UniqueHandle process(OpenProcess(SYNCHRONIZE, FALSE, processId));
        if (process)
            WaitForSingleObject(process.get(), INFINITE);
    }

    bool InstalledRegistrationPresent()
    {
        for (const auto &spec : kRegistrationValues)
        {
            if (_wcsicmp(spec.keyPath, kRunOnceKey) == 0 &&
                _wcsicmp(spec.valueName, kCleanupRunOnceValue) == 0)
                continue;
            if (ReadRawValue(spec).present)
                return true;
        }
        return false;
    }

    constexpr bool CleanupMayReconcile(bool recoveryPresent,
        bool exactValidRecoveryState)
    {
        return !recoveryPresent || exactValidRecoveryState;
    }

    static_assert(CleanupMayReconcile(false, false));
    static_assert(CleanupMayReconcile(false, true));
    static_assert(!CleanupMayReconcile(true, false));
    static_assert(CleanupMayReconcile(true, true));

    bool ServicingRecoveryStateAllowsReconcile()
    {
        const RegistryValueSpec recovery = { kRunOnceKey, kRecoveryRunOnceValue };
        const RegistryValueSnapshot rawRecovery = ReadRawValue(recovery);
        if (!rawRecovery.present)
            return CleanupMayReconcile(false, false);
        bool exact = false;
        try
        {
            DWORD snapshotComplete = 0;
            if (JournalExists() &&
                ReadJournalDword(L"SnapshotComplete", snapshotComplete) &&
                snapshotComplete == 1U)
            {
                const ServicingJournal journal = LoadJournal();
                exact = journal.target == JournalTarget::Installed &&
                    !journal.targetRecoveryCommand.empty() &&
                    ValidateSlotBasic(journal.targetActive) &&
                    (journal.targetPrevious.empty() ||
                        ValidateSlotBasic(journal.targetPrevious)) &&
                    StringValueEquals(kRunOnceKey, kRecoveryRunOnceValue,
                        journal.targetRecoveryCommand);
            }
        }
        catch (const InstallerFailure &)
        {
            exact = false;
        }
        return CleanupMayReconcile(true, exact);
    }

    enum class CleanupWaitResult
    {
        BlockerExited,
        InstalledStateObserved,
    };

    CleanupWaitResult WaitForProcessOrInstalledState(DWORD processId)
    {
        if (!processId || processId == GetCurrentProcessId())
            return CleanupWaitResult::BlockerExited;
        UniqueHandle process(OpenProcess(SYNCHRONIZE, FALSE, processId));
        if (!process)
            return CleanupWaitResult::BlockerExited;
        while (true)
        {
            const DWORD wait = WaitForSingleObject(process.get(), 100);
            if (wait == WAIT_OBJECT_0)
                return CleanupWaitResult::BlockerExited;
            if (wait != WAIT_TIMEOUT)
                return CleanupWaitResult::BlockerExited;
            // A reinstall can commit while this old helper waits for Explorer's
            // image mapping. Wake promptly; the setup mutex and a second check
            // below distinguish a committed install from a transient write.
            if (InstalledRegistrationPresent())
                return CleanupWaitResult::InstalledStateObserved;
        }
    }

    void RequestNativeSelfDelete()
    {
        // Windows 10's POSIX delete semantics can unlink the bounded cleanup
        // copy while its image section is still mapped. Failure is harmless:
        // there is only one deterministic helper path and a future uninstall
        // reuses or replaces that exact file.
        UniqueHandle file(CreateFileW(ModulePath().c_str(), DELETE | FILE_READ_ATTRIBUTES | FILE_WRITE_ATTRIBUTES,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING,
            FILE_ATTRIBUTE_NORMAL, nullptr));
        if (!file)
            return;
        FILE_DISPOSITION_INFO_EX disposition = {};
        disposition.Flags = FILE_DISPOSITION_FLAG_DELETE | FILE_DISPOSITION_FLAG_POSIX_SEMANTICS |
            FILE_DISPOSITION_FLAG_IGNORE_READONLY_ATTRIBUTE;
        SetFileInformationByHandle(file.get(), FileDispositionInfoEx, &disposition, sizeof(disposition));
    }

    bool CleanupKnownInstallTree()
    {
        const std::wstring root = InstallRoot();
        const std::wstring versions = Join(root, kVersionsDirectory);
        const ExplorerModuleInspection inspection =
            InspectExplorerA4SModules(ExplorerProcessId());
        if (!CanPruneKnownSlot(inspection.complete,
                inspection.unknownA4SModule, !inspection.modulePaths.empty()))
            return false;
        try
        {
            RejectReparsePoint(root, true);
            RejectReparsePoint(versions, true);
        }
        catch (const InstallerFailure &)
        {
            return false;
        }
        bool knownFilesRemoved = true;
        WIN32_FIND_DATAW data = {};
        const std::wstring pattern = Join(versions, L"*");
        UniqueFindHandle find(FindFirstFileW(pattern.c_str(), &data));
        if (!find)
        {
            const DWORD error = GetLastError();
            if (error != ERROR_FILE_NOT_FOUND && error != ERROR_PATH_NOT_FOUND)
                knownFilesRemoved = false;
        }
        else
        {
            do
            {
                if (wcscmp(data.cFileName, L".") == 0 || wcscmp(data.cFileName, L"..") == 0)
                    continue;
                if ((data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) == 0 ||
                    (data.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0)
                    continue;
                const std::wstring slot = Join(versions, data.cFileName);
                if (!RemoveKnownSlot(slot))
                    return false;
                for (const wchar_t *name :
                    { A4S_PRODUCT_HOST_FILENAME_W, A4S_PRODUCT_DLL_FILENAME_W, kSetupFilename })
                {
                    const DWORD attributes = GetFileAttributesW(Join(slot, name).c_str());
                    if (attributes != INVALID_FILE_ATTRIBUTES &&
                        (attributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) == 0)
                        knownFilesRemoved = false;
                    else if (GetLastError() != ERROR_FILE_NOT_FOUND &&
                        GetLastError() != ERROR_PATH_NOT_FOUND)
                        knownFilesRemoved = false;
                }
            }
            while (FindNextFileW(find.get(), &data));
            const DWORD enumerationError = GetLastError();
            if (enumerationError != ERROR_NO_MORE_FILES)
                knownFilesRemoved = false;
        }
        RemoveDirectoryW(versions.c_str());
        // These are product-owned runtime caches. They are deliberately left
        // untouched by install/update/repair and removed only by uninstall.
        for (const wchar_t *name : { L"DataCache.db", L"DataCache.tmp", L"DataCache.txt", L"StartupLog.txt" })
        {
            const std::wstring path = Join(root, name);
            const DWORD attributes = GetFileAttributesW(path.c_str());
            if (attributes == INVALID_FILE_ATTRIBUTES)
            {
                const DWORD error = GetLastError();
                if (error != ERROR_FILE_NOT_FOUND && error != ERROR_PATH_NOT_FOUND)
                    knownFilesRemoved = false;
                continue;
            }
            if ((attributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) != 0)
                continue;
            if (!DeleteFileW(path.c_str()))
                knownFilesRemoved = false;
        }
        // Unknown user-created root/slot content is deliberately preserved.
        // Its presence may keep the now data-only directories from being
        // removed, but must not cause a successful known-file cleanup to retry
        // at every logon forever.
        RemoveDirectoryW(root.c_str());
        return knownFilesRemoved;
    }

    void PruneObsoleteSlotsBestEffort(const std::vector<std::wstring> &retained)
    {
        try
        {
            const ExplorerModuleInspection inspection =
                InspectExplorerA4SModules(ExplorerProcessId());
            if (!inspection.complete || inspection.unknownA4SModule)
                return;
            std::vector<std::wstring> protectedSlots = retained;
            for (const std::wstring &mappedSlot : inspection.validatedSlots)
                AddUniquePath(protectedSlots, mappedSlot);
            const std::wstring versions = Join(InstallRoot(), kVersionsDirectory);
            RejectReparsePoint(versions, true);
            WIN32_FIND_DATAW data = {};
            UniqueFindHandle find(FindFirstFileW(Join(versions, L"*").c_str(), &data));
            if (!find)
                return;
            do
            {
                if (wcscmp(data.cFileName, L".") == 0 || wcscmp(data.cFileName, L"..") == 0 ||
                    (data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) == 0 ||
                    (data.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0)
                    continue;
                const std::wstring slot = FullPath(Join(versions, data.cFileName));
                const bool keep = std::any_of(protectedSlots.begin(), protectedSlots.end(),
                    [&](const std::wstring &candidate) {
                        return !candidate.empty() && _wcsicmp(slot.c_str(), FullPath(candidate).c_str()) == 0;
                    });
                if (!keep && !RemoveKnownSlot(slot))
                    return;
            }
            while (FindNextFileW(find.get(), &data));
        }
        catch (const InstallerFailure &)
        {
            // Pruning is bounded housekeeping after a committed registration.
            // A failure cannot invalidate the active or previous slot.
        }
    }

    std::wstring CleanupHelperPath()
    {
        wchar_t temp[MAX_PATH + 1] = {};
        const DWORD length = GetTempPathW(MAX_PATH, temp);
        if (!length || length > MAX_PATH)
            FailLastError(L"Could not locate the temporary directory for deferred cleanup.");
        return Join(temp, L"A4SMenuCleanup.exe");
    }

    std::wstring CleanupCommand(const std::wstring &helper, DWORD waitPid, DWORD explorerPid)
    {
        std::wstring command = Quote(helper) + L" --cleanup --silent";
        if (waitPid)
            command += L" --wait-pid " + std::to_wstring(waitPid);
        if (explorerPid)
            command += L" --wait-explorer " + std::to_wstring(explorerPid);
        return command;
    }

    void RemoveCanonicalCleanupStateForHelper()
    {
        const std::wstring expected = CleanupCommand(CleanupHelperPath(), 0, 0);
        if (!StringValueEquals(kRunOnceKey, kCleanupRunOnceValue, expected))
            return;
        DeleteValueChecked(kRunOnceKey, kCleanupRunOnceValue);
        FlushKeyChecked(kRunOnceKey, true);
    }

    std::wstring RecoveryCommand(const std::wstring &setup)
    {
        const std::wstring command = Quote(setup) + L" --reconcile --silent";
        if (command.size() >= 260U)
            Fail(ERROR_FILENAME_EXCED_RANGE, L"The servicing-recovery command exceeds the Windows RunOnce limit.");
        return command;
    }

    void QueueJournalRecovery(const std::wstring &command)
    {
        auto runOnce = OpenOrCreateKey(kRunOnceKey);
        SetString(runOnce.get(), kRecoveryRunOnceValue, command);
        if (RegFlushKey(runOnce.get()) != ERROR_SUCCESS)
            Fail(ERROR_WRITE_FAULT, L"Could not durably queue A4S Menu servicing recovery.");
    }

    struct PreparedCleanup
    {
        std::wstring helper;
        std::wstring retryCommand;
    };

    PreparedCleanup PrepareCleanup(const PayloadSet &payloads)
    {
        PreparedCleanup cleanup;
        cleanup.helper = CleanupHelperPath();
        cleanup.retryCommand = CleanupCommand(cleanup.helper, 0, 0);
        if (cleanup.retryCommand.size() >= 260U)
            Fail(ERROR_FILENAME_EXCED_RANGE, L"The deferred-cleanup command exceeds the Windows RunOnce limit.");

        if (!ExactFile(cleanup.helper, payloads.setup))
        {
            if (!DeleteFileW(cleanup.helper.c_str()) && GetLastError() != ERROR_FILE_NOT_FOUND)
                Fail(ERROR_SHARING_VIOLATION, L"A previous deferred-cleanup helper is still active.");
            WriteExactFile(cleanup.helper, payloads.setup);
        }

        auto runOnce = OpenOrCreateKey(kRunOnceKey);
        SetString(runOnce.get(), kCleanupRunOnceValue, cleanup.retryCommand);
        if (RegFlushKey(runOnce.get()) != ERROR_SUCCESS)
            Fail(ERROR_WRITE_FAULT, L"Could not durably queue deferred A4S Menu cleanup.");
        return cleanup;
    }

    bool StartPreparedCleanup(const PreparedCleanup &cleanup, DWORD explorerPid)
    {
        std::wstring immediate = CleanupCommand(cleanup.helper, GetCurrentProcessId(), explorerPid);
        STARTUPINFOW startup = {};
        startup.cb = sizeof(startup);
        PROCESS_INFORMATION process = {};
        if (!CreateProcessW(cleanup.helper.c_str(), immediate.data(), nullptr, nullptr, FALSE,
                CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT, nullptr, nullptr, &startup, &process))
            return false;
        CloseHandle(process.hThread);
        CloseHandle(process.hProcess);
        return true;
    }

    void ExtractTestLayout(const PayloadSet &payloads, const std::wstring &target)
    {
        if (target.empty())
            Fail(ERROR_BAD_ARGUMENTS, L"--extract-test requires an empty target directory.");
        if (!CreateDirectoryW(target.c_str(), nullptr))
            FailLastError(L"The extract-test target must not already exist.");
        RejectReparsePoint(target, false);
        try
        {
            WriteExactFile(Join(target, A4S_PRODUCT_HOST_FILENAME_W),
                std::span(payloads.host.data, payloads.host.size));
            WriteExactFile(Join(target, A4S_PRODUCT_DLL_FILENAME_W),
                std::span(payloads.menu.data, payloads.menu.size));
            WriteExactFile(Join(target, kSetupFilename), payloads.setup);
        }
        catch (...)
        {
            RemoveKnownSlot(target);
            throw;
        }
    }

    [[noreturn]] void RestoreFailedOperation(const ServicingJournal &journal,
        const InstalledState &oldState, bool restartPreviousHost)
    {
        const std::exception_ptr failure = std::current_exception();
        RollBackJournal(journal);
        if (restartPreviousHost && ValidateSlotBasic(oldState.activeSlot))
            StartHost(oldState.activeSlot);
        std::rethrow_exception(failure);
    }

    int InstallOrRepair(HINSTANCE instance, const Options &options)
    {
        const PayloadSet payloads = LoadAndValidatePayloads(instance);
        const InstalledState oldState = ReadInstalledState();
        const ProductVersion incomingVersion = FileProductVersion(ModulePath());
        if (ValidateSlotBasic(oldState.activeSlot) &&
            FileProductVersion(Join(oldState.activeSlot, A4S_PRODUCT_HOST_FILENAME_W)) > incomingVersion)
            Fail(ERROR_PRODUCT_VERSION, L"This installer is older than the active A4S Menu version. Use --rollback to restore a recorded previous version.");
        // Deploying a new immutable slot does not touch or overwrite the active
        // runtime, so complete that fallible work before disarming the host.
        const std::wstring newSlot = DeploySlot(payloads, oldState.activeSlot);
        if (!ValidateSlotBasic(newSlot))
            Fail(ERROR_FILE_CORRUPT, L"The deployed A4S Menu slot failed its final identity validation.");
        std::wstring previous = oldState.activeSlot != newSlot &&
            ValidateSlotBasic(oldState.activeSlot) ? oldState.activeSlot :
            (ValidateSlotBasic(oldState.previousSlot) ? oldState.previousSlot : L"");
        if (previous.empty())
        {
            // A reinstall can race a deferred uninstall helper while Explorer
            // still maps the old DLL. The helper must cancel promptly, so keep
            // that exact validated slot as the registered rollback slot rather
            // than pruning it into an unregistered, partially locked orphan.
            const ExplorerModuleInspection mapped =
                InspectExplorerA4SModules(ExplorerProcessId());
            if (mapped.complete && !mapped.unknownA4SModule &&
                mapped.validatedSlots.size() == 1U &&
                _wcsicmp(mapped.validatedSlots.front().c_str(), newSlot.c_str()) != 0)
                previous = mapped.validatedSlots.front();
        }
        const bool resetSafety = options.resetSafety;
        const std::wstring recoveryCommand = RecoveryCommand(Join(newSlot, kSetupFilename));
        const ServicingJournal journal = BeginJournal(JournalTarget::Installed,
            newSlot, previous, L"", recoveryCommand, resetSafety);
        const bool hostWasPresent = FindWindowW(A4S_HOST_WINDOW_CLASS_W,
            A4S_HOST_WINDOW_TITLE_W) != nullptr;
        bool wasRunning = false;
        DWORD oldExplorer = 0;
        bool mappingRetained = false;
        try
        {
            QueueJournalRecovery(recoveryCommand);
            wasRunning = StopHost();
            oldExplorer = ExplorerProcessId();
            mappingRetained = ExplorerHasA4SModule(oldExplorer);
            PrepareSlotRegistration(newSlot, previous);
            MarkJournalReady();
            CommitSlotStartup(newSlot);
        }
        catch (...)
        {
            RestoreFailedOperation(journal, oldState, hostWasPresent || wasRunning);
        }
        // The safety latch is cleared only after the complete target
        // registration is durable. A crash here leaves a ready journal that
        // retries the reset during the next setup reconciliation.
        CompleteJournal(journal);

        bool restarted = false;
        if (mappingRetained && PromptRestart(options.silent, options.restartExplorer))
            restarted = RestartExplorerWithConsent(oldExplorer);
        if (!mappingRetained || restarted)
        {
            if (!StartHost(newSlot) && !options.silent)
                MessageBoxW(nullptr, L"A4S Menu was installed, but its host could not be started. It will retry at the next sign-in.",
                    L"A4S Menu Setup", MB_OK | MB_ICONWARNING);
        }
        else if (!options.silent)
        {
            MessageBoxW(nullptr, L"A4S Menu is installed. The new version will activate after Windows Explorer restarts or at the next sign-in.",
                L"A4S Menu Setup", MB_OK | MB_ICONINFORMATION);
        }
        PruneObsoleteSlotsBestEffort({ newSlot, previous,
            mappingRetained && !restarted ? oldState.activeSlot : L"" });
        WriteParentConsole(L"A4SMenuSetup: installed " + newSlot);
        return ERROR_SUCCESS;
    }

    int Rollback(const Options &options)
    {
        const InstalledState state = ReadInstalledState();
        if (!ValidateSlotBasic(state.previousSlot))
            Fail(ERROR_NOT_FOUND, L"No valid previous A4S Menu version is available.");
        const std::wstring nextPrevious = ValidateSlotBasic(state.activeSlot) ?
            state.activeSlot : L"";
        const std::wstring recoveryCommand = RecoveryCommand(
            Join(state.previousSlot, kSetupFilename));
        const ServicingJournal journal = BeginJournal(JournalTarget::Installed,
            state.previousSlot, nextPrevious, L"", recoveryCommand, false);
        const bool hostWasPresent = FindWindowW(A4S_HOST_WINDOW_CLASS_W,
            A4S_HOST_WINDOW_TITLE_W) != nullptr;
        bool wasRunning = false;
        DWORD oldExplorer = 0;
        bool mappingRetained = false;
        try
        {
            QueueJournalRecovery(recoveryCommand);
            wasRunning = StopHost();
            oldExplorer = ExplorerProcessId();
            mappingRetained = ExplorerHasA4SModule(oldExplorer);
            PrepareSlotRegistration(state.previousSlot, nextPrevious);
            MarkJournalReady();
            CommitSlotStartup(state.previousSlot);
        }
        catch (...)
        {
            RestoreFailedOperation(journal, state, hostWasPresent || wasRunning);
        }
        CompleteJournal(journal);
        bool restarted = false;
        if (mappingRetained && PromptRestart(options.silent, options.restartExplorer))
            restarted = RestartExplorerWithConsent(oldExplorer);
        if (!mappingRetained || restarted)
            StartHost(state.previousSlot);
        PruneObsoleteSlotsBestEffort({ state.previousSlot, nextPrevious,
            mappingRetained && !restarted ? state.activeSlot : L"" });
        WriteParentConsole(L"A4SMenuSetup: restored previous version");
        return ERROR_SUCCESS;
    }

    int Uninstall(HINSTANCE instance, const Options &options)
    {
        const PayloadSet payloads = LoadAndValidatePayloads(instance);
        const InstalledState oldState = ReadInstalledState();
        const std::wstring cleanupHelper = CleanupHelperPath();
        const std::wstring cleanupRetry = CleanupCommand(cleanupHelper, 0, 0);
        const ServicingJournal journal = BeginJournal(JournalTarget::Uninstalled,
            L"", L"", cleanupRetry, L"", false);
        const bool hostWasPresent = FindWindowW(A4S_HOST_WINDOW_CLASS_W,
            A4S_HOST_WINDOW_TITLE_W) != nullptr;
        PreparedCleanup cleanup;
        bool wasRunning = false;
        DWORD explorer = 0;
        bool mappingRetained = false;
        try
        {
            // Queue a durable RunOnce continuation before registration is
            // removed. A process crash can therefore never strand an
            // unregistered product without a cleanup/recovery path.
            cleanup = PrepareCleanup(payloads);
            wasRunning = StopHost();
            explorer = ExplorerProcessId();
            mappingRetained = ExplorerHasA4SModule(explorer);
            PrepareUnregisterProduct();
            MarkJournalReady();
            CommitUnregisteredStartup();
        }
        catch (...)
        {
            RestoreFailedOperation(journal, oldState, hostWasPresent || wasRunning);
        }
        CompleteJournal(journal);
        bool restarted = false;
        if (mappingRetained && PromptRestart(options.silent, options.restartExplorer))
            restarted = RestartExplorerWithConsent(explorer);
        const bool cleanupStarted = StartPreparedCleanup(cleanup,
            mappingRetained && !restarted ? explorer : 0);
        WriteParentConsole(L"A4SMenuSetup: uninstalled; locked files are queued for verified per-user cleanup");
        if (!options.silent)
            MessageBoxW(nullptr,
                restarted && cleanupStarted ? L"A4S Menu was uninstalled."
                          : L"A4S Menu was uninstalled. Any files still mapped by Explorer will be removed after Explorer exits or at the next sign-in.",
                L"A4S Menu Setup", MB_OK | MB_ICONINFORMATION);
        return ERROR_SUCCESS;
    }

    int Cleanup(const Options &options)
    {
        if (_wcsicmp(FullPath(ModulePath()).c_str(),
                FullPath(CleanupHelperPath()).c_str()) != 0)
            Fail(ERROR_INVALID_NAME, L"Deferred cleanup may run only from the canonical per-user helper path.");
        WaitForProcessId(options.waitProcessId);
        const CleanupWaitResult blocker = WaitForProcessOrInstalledState(options.waitExplorerId);
        const OwnedMutex setupMutex = AcquireSetupMutex();
        // The wake-up registration may have been only a partially committed
        // transaction when the setup process crashed. Reconcile it under the
        // same servicing mutex before deciding whether reinstall really won.
        // A recovery RunOnce entry is authoritative servicing state: it must
        // either be absent or exactly match one complete installed-target
        // journal. Stale/malformed recovery state blocks reconciliation and all
        // deletion rather than being silently ignored by the cleanup helper.
        if (!ServicingRecoveryStateAllowsReconcile())
            return ERROR_INVALID_STATE;
        ReconcilePendingJournal();
        const RegistryValueSpec recovery = { kRunOnceKey, kRecoveryRunOnceValue };
        if (ReadRawValue(recovery).present)
            return ERROR_INVALID_STATE;
        if (blocker == CleanupWaitResult::InstalledStateObserved || InstalledRegistrationPresent())
        {
            const InstalledState installed = ReadInstalledState();
            if (RegistrationMatchesCommittedSlot(installed.activeSlot, installed.previousSlot))
            {
                // Reinstall won the race. Never delete product state or files:
                // remove only this helper's exact retry value, unlink this
                // canonical helper image, and leave the committed install.
                RemoveCanonicalCleanupStateForHelper();
                RequestNativeSelfDelete();
                return ERROR_SUCCESS;
            }
            if (InstalledRegistrationPresent())
                return ERROR_INVALID_STATE;
        }
        // --cleanup is an internal post-uninstall continuation, not an
        // alternate uninstall entry point. Refuse it while either authoritative
        // product registration still says the runtime is installed.
        if (InstalledRegistrationPresent())
            return ERROR_INVALID_STATE;
        const std::wstring expectedCleanup = CleanupCommand(CleanupHelperPath(), 0, 0);
        if (!StringValueEquals(kRunOnceKey, kCleanupRunOnceValue, expectedCleanup))
        {
            // This process no longer owns cleanup registration. Preserve unknown
            // state and files, but remove this deterministic helper image.
            RequestNativeSelfDelete();
            return ERROR_INVALID_STATE;
        }
        if (!CleanupKnownInstallTree())
            return ERROR_DIR_NOT_EMPTY;
        DeleteTreeChecked(kUninstallKey);
        DeleteTreeChecked(kStateKey);
        RemoveCanonicalCleanupStateForHelper();
        RequestNativeSelfDelete();
        return ERROR_SUCCESS;
    }

    bool IsSwitch(const wchar_t *value, const wchar_t *expected)
    {
        return value && expected && _wcsicmp(value, expected) == 0;
    }

    bool ParseDword(const wchar_t *value, DWORD &result)
    {
        if (!value || !*value)
            return false;
        wchar_t *end = nullptr;
        const unsigned long parsed = wcstoul(value, &end, 10);
        if (!end || *end || parsed > std::numeric_limits<DWORD>::max())
            return false;
        result = static_cast<DWORD>(parsed);
        return true;
    }

    bool SelectOperation(Options &options, Operation operation)
    {
        if (options.operation != Operation::Automatic)
            return false;
        options.operation = operation;
        return true;
    }

    Options ParseOptions(int argc, wchar_t **argv)
    {
        Options options;
        for (int index = 1; index < argc; ++index)
        {
            const wchar_t *argument = argv[index];
            if (IsSwitch(argument, L"--silent") || IsSwitch(argument, L"/quiet") || IsSwitch(argument, L"/s"))
                options.silent = true;
            else if (IsSwitch(argument, L"--restart-explorer"))
                options.restartExplorer = true;
            else if (IsSwitch(argument, L"--install") && SelectOperation(options, Operation::Install)) {}
            else if (IsSwitch(argument, L"--repair") && SelectOperation(options, Operation::Repair))
                options.resetSafety = true;
            else if (IsSwitch(argument, L"--update") && SelectOperation(options, Operation::Repair)) {}
            else if (IsSwitch(argument, L"--uninstall") && SelectOperation(options, Operation::Uninstall)) {}
            else if (IsSwitch(argument, L"--rollback") && SelectOperation(options, Operation::Rollback)) {}
            else if (IsSwitch(argument, L"--verify") && SelectOperation(options, Operation::Verify)) {}
            else if (IsSwitch(argument, L"--self-test") && SelectOperation(options, Operation::SelfTest)) {}
            else if (IsSwitch(argument, L"--reconcile") && SelectOperation(options, Operation::Reconcile)) {}
            else if (IsSwitch(argument, L"--version") && SelectOperation(options, Operation::Version)) {}
            else if (IsSwitch(argument, L"--cleanup") && SelectOperation(options, Operation::Cleanup)) {}
            else if (IsSwitch(argument, L"--extract-test") && index + 1 < argc &&
                SelectOperation(options, Operation::ExtractTest))
                options.extractPath = argv[++index];
            else if (IsSwitch(argument, L"--wait-pid") && index + 1 < argc &&
                ParseDword(argv[index + 1], options.waitProcessId))
                ++index;
            else if (IsSwitch(argument, L"--wait-explorer") && index + 1 < argc &&
                ParseDword(argv[index + 1], options.waitExplorerId))
                ++index;
            else
                options.operation = Operation::Invalid;
        }
        if (options.operation != Operation::Cleanup && (options.waitProcessId || options.waitExplorerId))
            options.operation = Operation::Invalid;
        if (options.restartExplorer && options.operation != Operation::Install &&
            options.operation != Operation::Repair && options.operation != Operation::Uninstall &&
            options.operation != Operation::Rollback && options.operation != Operation::Automatic)
            options.operation = Operation::Invalid;
        return options;
    }

    bool Confirm(const wchar_t *text, const Options &options)
    {
        if (options.silent)
            return true;
        return MessageBoxW(nullptr, text, L"A4S Menu Setup",
            MB_YESNO | MB_ICONQUESTION | MB_DEFBUTTON2) == IDYES;
    }

    void ShowFailure(const InstallerFailure &failure, bool silent)
    {
        std::wstring text = failure.message + L"\n\nError " + std::to_wstring(failure.code) + L".";
        WriteParentConsole(L"A4SMenuSetup: " + text);
        if (!silent)
            MessageBoxW(nullptr, text.c_str(), L"A4S Menu Setup", MB_OK | MB_ICONERROR);
    }
}

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE, PWSTR, int)
{
#ifndef _WIN64
#error A4SMenuSetup supports only the x64 A4S product.
#endif
    int argc = 0;
    wchar_t **argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    if (!argv)
        return static_cast<int>(GetLastError());
    Options options = ParseOptions(argc, argv);
    LocalFree(argv);

    try
    {
        if (options.operation == Operation::Invalid)
            Fail(ERROR_BAD_ARGUMENTS, L"Invalid A4SMenuSetup command line.");
        if (options.operation == Operation::Version)
        {
            WriteParentConsole(L"A4SMenuSetup " A4S_PRODUCT_VERSION_STR_W);
            return ERROR_SUCCESS;
        }
        if (options.operation == Operation::Verify)
        {
            const PayloadSet payloads = LoadAndValidatePayloads(instance);
            WriteParentConsole(L"A4SMenuSetup: verified embedded slot " + payloads.slotName);
            return ERROR_SUCCESS;
        }
        if (options.operation == Operation::SelfTest)
        {
            const OwnedMutex setupMutex = AcquireSetupMutex();
            RunInternalSelfTest(instance);
            WriteParentConsole(L"A4SMenuSetup: servicing self-test passed");
            return ERROR_SUCCESS;
        }
        if (options.operation == Operation::ExtractTest)
        {
            const PayloadSet payloads = LoadAndValidatePayloads(instance);
            ExtractTestLayout(payloads, options.extractPath);
            WriteParentConsole(L"A4SMenuSetup: extracted test layout without installation side effects");
            return ERROR_SUCCESS;
        }
        if (options.operation == Operation::Cleanup)
            return Cleanup(options);
        if (options.operation == Operation::Reconcile)
        {
            const OwnedMutex setupMutex = AcquireSetupMutex();
            ReconcilePendingJournal();
            return ERROR_SUCCESS;
        }

        const OwnedMutex setupMutex = AcquireSetupMutex();
        ReconcilePendingJournal();
        const InstalledState state = ReadInstalledState();
        if (options.operation == Operation::Automatic)
            options.operation = state.activeSlot.empty() ? Operation::Install : Operation::Repair;

        switch (options.operation)
        {
        case Operation::Install:
            if (!Confirm(L"Install A4S Menu for the current user?", options))
                return ERROR_CANCELLED;
            return InstallOrRepair(instance, options);
        case Operation::Repair:
            if (!Confirm(L"Repair or update A4S Menu for the current user?", options))
                return ERROR_CANCELLED;
            return InstallOrRepair(instance, options);
        case Operation::Uninstall:
            if (!Confirm(L"Uninstall A4S Menu for the current user?", options))
                return ERROR_CANCELLED;
            return Uninstall(instance, options);
        case Operation::Rollback:
            if (!Confirm(L"Restore the previous A4S Menu version?", options))
                return ERROR_CANCELLED;
            return Rollback(options);
        default:
            Fail(ERROR_BAD_ARGUMENTS, L"Invalid A4SMenuSetup operation.");
        }
    }
    catch (const InstallerFailure &failure)
    {
        ShowFailure(failure, options.silent);
        return static_cast<int>(failure.code);
    }
    catch (...)
    {
        const InstallerFailure failure(ERROR_UNHANDLED_EXCEPTION, L"A4S Menu setup encountered an unexpected failure.");
        ShowFailure(failure, options.silent);
        return static_cast<int>(failure.code);
    }
}
