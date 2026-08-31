# A4S Menu first-half build record

This record captures the verified first-half build that established the
two-binary product boundary and passed the explicit live Explorer lifecycle
gate on 2026-08-31 at 20:53 (+04:00).

## Source provenance

- Baseline commit: `edc8bf0fc31f1dc302701716717a5284f13dadff`
- Branch: `a4s-product-first-half`
- Accepted source profile: `A4SMenu/phase4-source-profile/23`
- Product configuration: `A4SProduct|x64`
- Product stage: `build/stage/A4SProduct`

## Observed build environment

- Visual Studio 2022 Build Tools
- MSVC toolset: `14.44.35207`
- Windows SDK: `10.0.26100.0`
- Target architecture: x64

## Gate results

- A4S product x64 build: **PASS**
- Retained upstream development x64 build: **PASS**
- Exact two-file atomic stage: **PASS**
- `tools/Test-A4SProduct.ps1` static gate: **PASS**
- `tools/Test-A4SProductLifecycle.ps1` fresh-Explorer gate: **PASS**

The exact staged product was exercised with:

```powershell
.\tools\Test-A4SProductLifecycle.ps1 -AllowExplorerInjection
```

The pre-test Explorer PID was `1660`, with no running A4S host and no prior
`A4SMenu.dll` mapping. The staged host PID was `15780`. The gate verified
`READY`, the exact staged DLL mapping, toggle-open, toggle-close, logical
`--exit`, host/menu closure, and the expected pinned-but-inert DLL mapping.
StartAllBack's disabled registry value was `1`; its loader/runtime DLLs remained
mapped, so "fresh Explorer" here specifically means no prior A4S mapping. The
lifecycle script itself never restarts Explorer or uses same-process `--rehook`.

## Staged artifact record

The stage contained exactly these two top-level files and no directories:

| File | Size | SHA-256 |
| --- | ---: | --- |
| `A4SMenuHost.exe` | 201216 bytes | `C422731706DDB801457C5A4367CB57BC05DCE7A1987334B5775DD2835B27996B` |
| `A4SMenu.dll` | 1532416 bytes | `CC4F0914BD7B0CC1836D4FB8EA5585D766A1365714AD0C81254551A14F0FB80B` |

Both images passed the x64 PE check. The host has no static import of
`A4SMenu.dll` or `StartMenuDLL.dll`; it resolves its canonical absolute sibling
DLL dynamically. The menu DLL exported exactly `A4SMenu_GetApi` and
`A4SMenu_HookInject`, and the isolated probe negotiated ABI `0x00030000` with
product API version `0x00010000`.

## Exact dependency allowlists

`tools/Test-A4SProduct.ps1` requires every dependency to exist in Windows
System32 (apart from Windows API-set forwarders) and requires the following
exact direct-import sets.

### `A4SMenuHost.exe`

- `ADVAPI32.dll`
- `KERNEL32.dll`
- `SHELL32.dll`
- `USER32.dll`

### `A4SMenu.dll`

- `ADVAPI32.dll`
- `COMCTL32.dll`
- `dwmapi.dll`
- `GDI32.dll`
- `KERNEL32.dll`
- `MSIMG32.dll`
- `NETAPI32.dll`
- `OLE32.dll`
- `OLEACC.dll`
- `OLEAUT32.dll`
- `POWRPROF.dll`
- `PROPSYS.dll`
- `Secur32.dll`
- `SHELL32.dll`
- `SHLWAPI.dll`
- `USER32.dll`
- `UxTheme.dll`
- `WINMM.dll`
- `WTSAPI32.dll`

The gate separately rejects Visual C++ redistributable/debug runtimes and
retained updater, network-download, or HTML Help imports.

## Reproducibility boundary

The repository contains a clean-clone reproducible workflow: package restore,
isolated x64 product build, atomic exact-file staging, and static verification
are scripted. It is not a bit-for-bit deterministic build contract.

The projects select the `v143` platform toolset and the installed Windows 10
SDK family rather than pinning the exact compiler/linker binaries and SDK
contents. A later machine with a newer compatible v143 servicing release or
Windows SDK can produce different bytes while passing the same product gates.
The toolchain versions and hashes above therefore identify this observed build;
they are not promised outputs for every future clean clone.
