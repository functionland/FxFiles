# FxFiles Windows Installer Return Codes

FxFiles for Windows is distributed as an MSIX package. The following documents standard Windows Installer return codes applicable to the FxFiles installation process.

## Standard Return Codes

| Code | Scenario | Description |
|------|----------|-------------|
| `0` | Installation successful | The installation completed successfully. |
| `112` | Disk space is full | There is not enough space on the disk to complete the installation. Free up space and retry. |
| `1231` | Network failure | A network connectivity issue prevented the installation from completing. Check your internet connection and retry. |
| `1602` | Installation cancelled by user | The user cancelled the installation before it completed. |
| `1618` | Installation already in progress | Another installation is already in progress. Wait for the current installation to finish before retrying. |
| `1625` | Package rejected by security policy | Installation was blocked by a system security policy (e.g., Group Policy, AppLocker, or Windows Defender Application Control). Contact your system administrator. |
| `1638` | Application already exists | Another version of FxFiles is already installed. Uninstall the existing version or use the update mechanism. |
| `3010` | Reboot required | The installation completed but a system restart is required for changes to take effect. |

## MSIX-Specific Notes

FxFiles uses the MSIX packaging format, which provides the following installation behaviors:

- **Silent installation**: MSIX packages install silently by default without requiring additional switches.
- **Clean uninstall**: All app files and registry entries are fully removed on uninstall.
- **Auto-update**: When distributed via the Microsoft Store, updates are handled automatically.
- **Side-by-side**: MSIX apps run in a lightweight container and do not conflict with other applications.

## Miscellaneous Return Codes

| Code | Description |
|------|-------------|
| `1` | General failure — an unspecified error occurred during installation. |
| `2` | File not found — a required installation file could not be located. |
| `5` | Access denied — the installer does not have sufficient permissions. Run as administrator if installing outside the Microsoft Store. |
| `87` | Invalid parameter — the installation was invoked with incorrect arguments. |
| `1603` | Fatal error during installation — an unexpected error halted the installation. Check Windows Event Viewer for details. |
| `1612` | Installation source unavailable — the installation source (download URL or local file) is not accessible. |
| `1633` | Platform not supported — this version of FxFiles requires Windows 10 (version 1809) or later on x64 architecture. |
| `15612` | MSIX package validation failed — the package signature could not be verified. Ensure you are installing from an official source. |
| `15613` | MSIX dependency missing — a required framework dependency (e.g., VCLibs, .NET Desktop Runtime) is not installed. Install Windows updates and retry. |

## System Requirements

- **OS**: Windows 10 version 1809 (build 17763) or later
- **Architecture**: x64 (64-bit)
- **Disk space**: ~200 MB
- **Network**: Required for cloud sync and IPFS features; not required for local file management

## Troubleshooting

If you encounter an unlisted error code:

1. Open **Event Viewer** (`eventvwr.msc`) and check **Windows Logs > Application** for detailed error messages.
2. Run `Get-AppxLog -ActivityID <id>` in PowerShell for MSIX-specific diagnostics.
3. Ensure your Windows installation is up to date via **Settings > Windows Update**.
4. For sideloaded installations, verify that **Developer Mode** or **Sideloading** is enabled in **Settings > For Developers**.

## Contact

For installation issues, please open an issue at the FxFiles repository or contact Functionland support.
