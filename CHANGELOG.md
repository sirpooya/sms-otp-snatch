# Changelog

All notable changes to OTP Snatcher. The release workflow reads the section
matching the tagged version and turns it into the GitHub Release notes, so keep
the `## [x.y.z]` heading format.

## [0.1.0]

### Added
- Watches the Messages database for forwarded SMS and copies the one-time code
  to the clipboard automatically.
- Persian-aware extraction: Arabic-Indic and Persian digits, bidi marks and ZWNJ
  normalized before matching, Arabic yeh and kaf folded to their Persian forms.
- Four extraction strategies in confidence order: a per-sender regex override,
  the standardized domain-bound autofill line, keyword anchoring, and a guarded
  fallback. Rejects transaction amounts, validity clocks, USSD strings, support
  line numbers, discount codes and digits inside URLs.
- Clipboard entries are marked with the concealed pasteboard type, so clipboard
  managers do not persist the code, and are cleared after a configurable delay
  only if the clipboard still holds exactly what was written.
- Full Disk Access onboarding with a deep link to the correct settings pane.
- Fallback polling that turns itself on if filesystem events are being missed.
- `OTPSnatcher --check`, a headless diagnostic for permission and decode state.

### Notes
- No network code of any kind. "Check for Updates" opens the releases page in a
  browser rather than fetching anything in process.
- Not notarized (no paid Apple Developer account), so first launch needs
  right-click then Open.

<!-- Template
## [x.y.z]

### Added
### Changed
### Fixed
-->
