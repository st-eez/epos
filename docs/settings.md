# Settings

The menu shows readiness, three permission tiles, the configured locale,
preferences, and action buttons. Preferences persist through UserDefaults.
Most changes are saved immediately; correction drafts use Save Changes in their
own window.

## Preferences

| Control | Initial value | Effect |
| --- | --- | --- |
| Launch at login | Off | Registers the main app with SMAppService |
| Save audio samples | Off | Enables local WAV capture for new recordings |
| Learn corrections | Off | Enables transcript and observed edit evidence for new recordings |
| Ignore speaker audio | Off | Enables microphone voice processing at the next fn press |
| Stream into field | On | Attempts inline marked text through the companion on the next recording |
| Edge glow | On | Selects the screen edge capture cue; changes apply to a current hold |
| Glow intensity | 0.85 | Brightness multiplier, constrained to 0.4 through 1.6 |
| Glow thickness | 1.0 | Width multiplier, constrained to 0.6 through 1.6 |
| Ember aura | Off | Selects the fixed ember palette |
| Glow color | Teal | Standard theme base color, from swatches or a custom color panel |
| Locale | `en-US` | Displayed from saved configuration; no menu switcher |

Launch at login reads the system service status, including changes made in
System Settings. If registration or unregistration fails, the switch returns to
the actual system state. Defaults describe a fresh preferences store; saved
preferences and system service status determine an existing installation.

See [dictation](dictation.md#ignore-speaker-audio),
[insertion](insertion.md#stream-into-field),
[corrections](corrections.md#learning-and-suggestions), and
[recording feedback](recording-feedback.md#edge-glow) for behavior and limits.

## Menu actions

Corrections opens the dictionary editor and activates its window. Privacy opens
System Settings. Quit terminates Epos; the button also carries the Q keyboard
shortcut in the menu. The banner reports Starting up, Not ready, Needs
permission, Ready to dictate, Recording, Finishing speech, or Updating text from
the coordinator and current grants.

## Evidence

Source is [Settings](../Sources/Epos/App/Settings.swift),
[AppCoordinatorSettings](../Sources/Epos/App/AppCoordinatorSettings.swift), and
[MenuBarView](../Sources/Epos/UI/MenuBarView.swift).
[SettingsTests](../Tests/EposTests/SettingsTests.swift) and
[SmokeTests](../Tests/EposTests/SmokeTests.swift) cover persistence, defaults,
and glow range validation. System login registration and native color panel
interaction require installed app verification.
