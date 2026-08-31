#include <Windows.h>
#include <RestartManager.h>
#include <bcrypt.h>
#include <shellapi.h>
#include <shlobj.h>
#include <tlhelp32.h>

#include <algorithm>
#include <array>
#include <cstdint>
#include <cwchar>
#include <limits>
#include <span>
#include <string>
#include <vector>

#include "resource.h"
#include "../Shared/A4SProductApi.h"
#include "../Shared/A4SProductIdentity.h"

namespace
{
    constexpr wchar_t kStateKey[] = L"Software\\A4SMenu";
    constexpr wchar_t kUninstallKey[] =
        L"Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\A4SMenu";
    constexpr wchar_t kRunKey[] = L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";
    constexpr wchar_t kRunOnceKey[] = L"Software\\Microsoft\\Windows\\CurrentVersion\\RunOnce";
    constexpr wchar_t kRunValue[] = L"A4SMenu";
    // The RunOnce '!' prefix asks Windows to remove the value after execution,
    // rather than before it. A failed cleanup therefore remains recoverable.
    constexpr wchar_t kCleanupRunOnceValue[] = L"!A4SMenuCleanup";
    constexpr wchar_t kSetupFilename[] = L"A4SMenuSetup.exe";
    constexpr wchar_t kVersionsDirectory[] = L"versions";
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

    PayloadSet LoadAndValidatePayloads(HINSTANCE instance)
    {
        PayloadSet payloads;
        payloads.host = LoadPayload(instance, IDR_A4S_HOST_PAYLOAD);
        payloads.menu = LoadPayload(instance, IDR_A4S_MENU_PAYLOAD);
        payloads.setup = ReadFileBytes(ModulePath());
        ValidatePe(std::span(payloads.host.data, payloads.host.size), false);
        ValidatePe(std::span(payloads.menu.data, payloads.menu.size), true);
        ValidatePe(payloads.setup, false);

        std::vector<std::uint8_t> identity;
        const auto hostHash = HashBytes(std::span(payloads.host.data, payloads.host.size));
        const auto menuHash = HashBytes(std::span(payloads.menu.data, payloads.menu.size));
        const auto setupHash = HashBytes(payloads.setup);
        identity.insert(identity.end(), hostHash.begin(), hostHash.end());
        identity.insert(identity.end(), menuHash.begin(), menuHash.end());
        identity.insert(identity.end(), setupHash.begin(), setupHash.end());
        payloads.slotName = A4S_PRODUCT_VERSION_STR_W;
        payloads.slotName += L"-" + Hex(HashBytes(identity)).substr(0, 20);
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

    bool RemoveKnownSlot(const std::wstring &slot)
    {
        RejectReparsePoint(slot, true);
        bool complete = true;
        for (const wchar_t *name : { A4S_PRODUCT_HOST_FILENAME_W, A4S_PRODUCT_DLL_FILENAME_W, kSetupFilename })
        {
            const std::wstring path = Join(slot, name);
            if (!DeleteFileW(path.c_str()) && GetLastError() != ERROR_FILE_NOT_FOUND &&
                GetLastError() != ERROR_PATH_NOT_FOUND)
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
            return true;
        }
        catch (const InstallerFailure &)
        {
            return false;
        }
    }

    std::wstring DeploySlot(const PayloadSet &payloads)
    {
        const std::wstring root = InstallRoot();
        EnsureDirectory(root);
        RejectReparsePoint(root, false);
        const std::wstring versions = Join(root, kVersionsDirectory);
        EnsureDirectory(versions);
        RejectReparsePoint(versions, false);
        const std::wstring finalSlot = Join(versions, payloads.slotName.c_str());

        if (GetFileAttributesW(finalSlot.c_str()) != INVALID_FILE_ATTRIBUTES)
        {
            RejectReparsePoint(finalSlot, false);
            if (!ExactFile(Join(finalSlot, A4S_PRODUCT_HOST_FILENAME_W),
                    std::span(payloads.host.data, payloads.host.size)) ||
                !ExactFile(Join(finalSlot, A4S_PRODUCT_DLL_FILENAME_W),
                    std::span(payloads.menu.data, payloads.menu.size)) ||
                !ExactFile(Join(finalSlot, kSetupFilename), payloads.setup))
                Fail(ERROR_FILE_CORRUPT, L"The existing version slot does not match this installer.");
            return finalSlot;
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

    void RegisterSlot(const std::wstring &active, const std::wstring &previous)
    {
        if (!ValidateSlotBasic(active))
            Fail(ERROR_FILE_CORRUPT, L"The selected A4S Menu version is incomplete.");
        const std::wstring host = Join(active, A4S_PRODUCT_HOST_FILENAME_W);
        const std::wstring setup = Join(active, kSetupFilename);

        auto run = OpenOrCreateKey(kRunKey);
        SetString(run.get(), kRunValue, Quote(host));

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
        // ActiveSlot is the commit marker and is deliberately written last.
        SetString(state.get(), L"ActiveSlot", active);
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

    void UnregisterProduct()
    {
        DeleteValueChecked(kRunKey, kRunValue);
        DeleteTreeChecked(kUninstallKey);
        DeleteTreeChecked(kStateKey);
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

    bool ExplorerHasA4SModule(DWORD processId)
    {
        if (!processId)
            return false;
        UniqueHandle snapshot(CreateToolhelp32Snapshot(TH32CS_SNAPMODULE | TH32CS_SNAPMODULE32, processId));
        if (!snapshot)
            return true; // Fail closed: an unknown live mapping requires a restart boundary.
        MODULEENTRY32W entry = {};
        entry.dwSize = sizeof(entry);
        if (!Module32FirstW(snapshot.get(), &entry))
            return true;
        do
        {
            const wchar_t *filename = wcsrchr(entry.szExePath, L'\\');
            filename = filename ? filename + 1 : entry.szExePath;
            if (_wcsicmp(filename, A4S_PRODUCT_DLL_FILENAME_W) == 0)
                return true;
        }
        while (Module32NextW(snapshot.get(), &entry));
        return false;
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
            if (shutdown == ERROR_SUCCESS)
                restart = RmRestart(session, 0, nullptr);
        }
        RmEndSession(session);
        if (registration != ERROR_SUCCESS || shutdown != ERROR_SUCCESS || restart != ERROR_SUCCESS)
            return false;
        WaitForSingleObject(explorer.get(), kRestartTimeoutMs);
        const ULONGLONG deadline = GetTickCount64() + kRestartTimeoutMs;
        while (GetTickCount64() < deadline)
        {
            const DWORD replacement = ExplorerProcessId();
            if (replacement && replacement != processId)
                return true;
            Sleep(50);
        }
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

    void RequestNativeSelfDelete()
    {
        // Windows 10's POSIX delete semantics can unlink the bounded cleanup
        // copy while its image section is still mapped. Failure is harmless:
        // there is only one deterministic helper path and a future uninstall
        // reuses or replaces that exact file.
        UniqueHandle file(CreateFileW(ModulePath().c_str(), DELETE | FILE_READ_ATTRIBUTES,
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
        try
        {
            RejectReparsePoint(root, true);
            RejectReparsePoint(versions, true);
        }
        catch (const InstallerFailure &)
        {
            return false;
        }
        WIN32_FIND_DATAW data = {};
        const std::wstring pattern = Join(versions, L"*");
        UniqueFindHandle find(FindFirstFileW(pattern.c_str(), &data));
        if (find)
        {
            do
            {
                if (wcscmp(data.cFileName, L".") == 0 || wcscmp(data.cFileName, L"..") == 0)
                    continue;
                if ((data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) == 0 ||
                    (data.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0)
                    continue;
                RemoveKnownSlot(Join(versions, data.cFileName));
            }
            while (FindNextFileW(find.get(), &data));
        }
        RemoveDirectoryW(versions.c_str());
        // These are product-owned runtime caches. They are deliberately left
        // untouched by install/update/repair and removed only by uninstall.
        for (const wchar_t *name : { L"DataCache.db", L"DataCache.tmp", L"DataCache.txt", L"StartupLog.txt" })
        {
            const std::wstring path = Join(root, name);
            if (!DeleteFileW(path.c_str()) && GetLastError() != ERROR_FILE_NOT_FOUND &&
                GetLastError() != ERROR_PATH_NOT_FOUND)
                return false;
        }
        if (RemoveDirectoryW(root.c_str()))
            return true;
        const DWORD error = GetLastError();
        return error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND;
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

    void ScheduleCleanup(const PayloadSet &payloads, DWORD explorerPid)
    {
        const std::wstring helper = CleanupHelperPath();
        if (!ExactFile(helper, payloads.setup))
        {
            if (!DeleteFileW(helper.c_str()) && GetLastError() != ERROR_FILE_NOT_FOUND)
                Fail(ERROR_SHARING_VIOLATION, L"A previous deferred-cleanup helper is still active.");
            WriteExactFile(helper, payloads.setup);
        }

        auto runOnce = OpenOrCreateKey(kRunOnceKey);
        const std::wstring retry = CleanupCommand(helper, 0, 0);
        SetString(runOnce.get(), kCleanupRunOnceValue, retry);

        std::wstring immediate = CleanupCommand(helper, GetCurrentProcessId(), explorerPid);
        STARTUPINFOW startup = {};
        startup.cb = sizeof(startup);
        PROCESS_INFORMATION process = {};
        if (!CreateProcessW(helper.c_str(), immediate.data(), nullptr, nullptr, FALSE,
                CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT, nullptr, nullptr, &startup, &process))
            FailLastError(L"Could not start deferred A4S Menu cleanup.");
        CloseHandle(process.hThread);
        CloseHandle(process.hProcess);
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

    void RestoreRegistrationBestEffort(const InstalledState &oldState)
    {
        try
        {
            if (ValidateSlotBasic(oldState.activeSlot))
                RegisterSlot(oldState.activeSlot, oldState.previousSlot);
            else
                UnregisterProduct();
        }
        catch (const InstallerFailure &) {}
    }

    int InstallOrRepair(HINSTANCE instance, const Options &options)
    {
        const PayloadSet payloads = LoadAndValidatePayloads(instance);
        const InstalledState oldState = ReadInstalledState();
        const ProductVersion incomingVersion = FileProductVersion(ModulePath());
        if (ValidateSlotBasic(oldState.activeSlot) &&
            FileProductVersion(Join(oldState.activeSlot, A4S_PRODUCT_HOST_FILENAME_W)) > incomingVersion)
            Fail(ERROR_PRODUCT_VERSION, L"This installer is older than the active A4S Menu version. Use --rollback to restore a recorded previous version.");
        const bool wasRunning = StopHost();
        const DWORD oldExplorer = ExplorerProcessId();
        const bool mappingRetained = ExplorerHasA4SModule(oldExplorer) || wasRunning;
        std::wstring newSlot;
        try
        {
            newSlot = DeploySlot(payloads);
            const std::wstring previous = oldState.activeSlot != newSlot &&
                ValidateSlotBasic(oldState.activeSlot) ? oldState.activeSlot : oldState.previousSlot;
            RegisterSlot(newSlot, previous);
        }
        catch (...)
        {
            RestoreRegistrationBestEffort(oldState);
            throw;
        }

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
        WriteParentConsole(L"A4SMenuSetup: installed " + newSlot);
        return ERROR_SUCCESS;
    }

    int Rollback(const Options &options)
    {
        const InstalledState state = ReadInstalledState();
        if (!ValidateSlotBasic(state.previousSlot))
            Fail(ERROR_NOT_FOUND, L"No valid previous A4S Menu version is available.");
        const bool wasRunning = StopHost();
        const DWORD oldExplorer = ExplorerProcessId();
        const bool mappingRetained = ExplorerHasA4SModule(oldExplorer) || wasRunning;
        try
        {
            RegisterSlot(state.previousSlot, state.activeSlot);
        }
        catch (...)
        {
            RestoreRegistrationBestEffort(state);
            throw;
        }
        bool restarted = false;
        if (mappingRetained && PromptRestart(options.silent, options.restartExplorer))
            restarted = RestartExplorerWithConsent(oldExplorer);
        if (!mappingRetained || restarted)
            StartHost(state.previousSlot);
        WriteParentConsole(L"A4SMenuSetup: restored previous version");
        return ERROR_SUCCESS;
    }

    int Uninstall(HINSTANCE instance, const Options &options)
    {
        const PayloadSet payloads = LoadAndValidatePayloads(instance);
        const InstalledState oldState = ReadInstalledState();
        StopHost();
        const DWORD explorer = ExplorerProcessId();
        const bool mappingRetained = ExplorerHasA4SModule(explorer);
        try
        {
            UnregisterProduct();
        }
        catch (...)
        {
            RestoreRegistrationBestEffort(oldState);
            throw;
        }
        bool restarted = false;
        if (mappingRetained && PromptRestart(options.silent, options.restartExplorer))
            restarted = RestartExplorerWithConsent(explorer);
        ScheduleCleanup(payloads, mappingRetained && !restarted ? explorer : 0);
        WriteParentConsole(L"A4SMenuSetup: uninstalled; locked files are queued for verified per-user cleanup");
        if (!options.silent)
            MessageBoxW(nullptr,
                restarted ? L"A4S Menu was uninstalled."
                          : L"A4S Menu was uninstalled. Any files still mapped by Explorer will be removed after Explorer exits or at the next sign-in.",
                L"A4S Menu Setup", MB_OK | MB_ICONINFORMATION);
        return ERROR_SUCCESS;
    }

    int Cleanup(const Options &options)
    {
        WaitForProcessId(options.waitProcessId);
        WaitForProcessId(options.waitExplorerId);
        // --cleanup is an internal post-uninstall continuation, not an
        // alternate uninstall entry point. Refuse it while either authoritative
        // product registration still says the runtime is installed.
        if (!ReadString(HKEY_CURRENT_USER, kStateKey, L"ActiveSlot").empty() ||
            !ReadString(HKEY_CURRENT_USER, kRunKey, kRunValue).empty())
            return ERROR_INSTALL_ALREADY_RUNNING;
        if (!CleanupKnownInstallTree())
            return ERROR_DIR_NOT_EMPTY;
        DeleteValueBestEffort(kRunOnceKey, kCleanupRunOnceValue);
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
            else if ((IsSwitch(argument, L"--repair") || IsSwitch(argument, L"--update")) &&
                SelectOperation(options, Operation::Repair)) {}
            else if (IsSwitch(argument, L"--uninstall") && SelectOperation(options, Operation::Uninstall)) {}
            else if (IsSwitch(argument, L"--rollback") && SelectOperation(options, Operation::Rollback)) {}
            else if (IsSwitch(argument, L"--verify") && SelectOperation(options, Operation::Verify)) {}
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
            options.operation != Operation::Rollback)
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
        if (options.operation == Operation::ExtractTest)
        {
            const PayloadSet payloads = LoadAndValidatePayloads(instance);
            ExtractTestLayout(payloads, options.extractPath);
            WriteParentConsole(L"A4SMenuSetup: extracted test layout without installation side effects");
            return ERROR_SUCCESS;
        }
        if (options.operation == Operation::Cleanup)
            return Cleanup(options);

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
