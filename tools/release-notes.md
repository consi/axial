## Changes in v0.2.5

- Adds hardware zero calibration (#11): **Motion → Calibrate…** or `axialctl calibrate` rezeroes controllers that support it, as 3DxWare does, while the LED blinks for about four seconds.
- Keeps web pages that do not answer `self:update`, such as driftlock.online, navigating instead of closing the session after two seconds (#12).
- Honours `rowMajorOrder` in the web API and detects row-major `view.affine` matrices from clients that do not declare it.

## Installation

Universal macOS installer for Apple Silicon and Intel Macs, targeting macOS 13 or later.

Install through Homebrew after the release workflow's Homebrew job completes:

```sh
brew tap consi/homebrew https://github.com/consi/homebrew
brew install --cask consi/homebrew/axial
open /Applications/Axial.app
```

Uninstall the 3Dconnexion driver first. Quit Axial and CAD applications before upgrading. Installation requires administrator access. Grant Axial Accessibility permission for keyboard shortcuts.

Binaries are ad-hoc signed; the installer is not Developer ID signed or notarized. macOS may require approval in Privacy & Security. No system-wide Gatekeeper bypass is required or recommended.

CI builds on macOS 15 and 26 (ARM and Intel), and macOS 27 (ARM preview). The canonical package is also tested on macOS 14 ARM. macOS 13 and native Intel macOS 14/27 are not runtime-tested. Hardware HID and CAD application testing remains manual.

Verify the downloaded installer with `shasum -a 256 -c SHA256SUMS`.
