# WAU-Notify

An add-on for [Winget-AutoUpdate](https://github.com/Romanitho/Winget-AutoUpdate) (WAU) by Romanitho that adds update deadline enforcement with a user-facing prompt dialog. In managed enterprise environments, admins need users to be notified before updates install and given the option to defer -- but with a hard deadline to ensure compliance. WAU-Notify adds that capability while remaining fully backward-compatible with upstream WAU behavior when not configured.

![Update Prompt Dialog](https://github.com/user-attachments/assets/bd2262a8-4006-44ce-b12f-ea579635c4c1)

## How It Works

When `WAU_UpdateDeadlineDays` is set to a value greater than 0, WAU-Notify changes the update flow:

1. **Detection** -- WAU detects outdated apps as usual. Instead of silently installing, it records a deadline (first detection date + configured days) in the registry for each app.
2. **Prompt** -- A WPF dialog is presented to the logged-in user (via ServiceUI.exe) listing all pending updates with their deadlines and days remaining. The user can update now, select specific apps to update, or snooze.
3. **Reminder** -- If the user snoozes, the prompt reappears after the configured reminder interval.
4. **Final day** -- On the deadline date, apps are auto-selected and locked in the prompt. The user must update them -- the Remind button is hidden.
5. **Enforcement** -- Once an app's deadline has passed, it is updated silently in the background with no prompt. The user receives a toast notification.

Setting `WAU_UpdateDeadlineDays` to `0` (or leaving it unconfigured) preserves the default silent update behavior -- WAU-Notify has zero effect.

## Features

- **Deadline tracking** -- Per-app deadline clock starts on first detection and never resets on version bumps
- **WPF prompt dialog** -- Clean, non-resizable window listing all pending updates with deadlines
- **Per-app selective update** -- Checkboxes let users update specific apps now and defer the rest
- **Final-day enforcement** -- Apps due today are auto-checked, locked (cannot be unchecked), and highlighted in red; the Remind button is hidden so the user must update them
- **Color-coded urgency** -- Red rows for deadline today/overdue, amber for 1-3 days remaining, white for 4+ days
- **Configurable reminder interval** -- Days between reminder prompts after the user snoozes
- **Custom company branding** -- Company name in the prompt header (e.g. "Contoso requires...")
- **User context respected** -- If the admin configures WAU to run with user context, WAU-Notify will also run with user context enabled, detecting and tracking user-scoped app updates alongside machine-scoped ones
- **Whitelist/blacklist respected** -- Only apps matching WAU's existing inclusion/exclusion lists enter deadline tracking
- **Self-healing** -- Apps updated outside WAU (manually, auto-updater, Store) are automatically purged from tracking on the next run; failed updates preserve the deadline entry for retry
- **ADMX/Intune policy support** -- Dedicated ADMX/ADML files for Intune Administrative Templates or Group Policy deployment
- **X button blocked** -- Users cannot close the dialog without choosing an action
- **Auto-dismiss timer** -- Dialog auto-closes after the reminder interval minus 1 hour, ensuring the next WAU run re-prompts with fresh data

## Configuration

All settings are configurable via ADMX Group Policy, Intune Administrative Templates, or direct registry entries.

### Registry Locations

| Source | Path |
|--------|------|
| Group Policy / Intune | `HKLM:\SOFTWARE\Policies\Romanitho\Winget-AutoUpdate` |
| Direct registry | `HKLM:\SOFTWARE\Romanitho\Winget-AutoUpdate` |

GPO values take precedence over direct registry values (WAU's built-in behavior via `Get-WAUConfig`).

### Settings

| Setting | Type | Default | Description |
|---------|------|---------|-------------|
| `WAU_UpdateDeadlineDays` | REG_SZ | `0` (disabled) | Number of days from first detection until the update is forced. `0` or not set = standard silent update behavior. |
| `WAU_ReminderIntervalDays` | REG_SZ | `2` | Days between reminder prompts after the user clicks "Remind Me." Only active when `WAU_UpdateDeadlineDays > 0`. Actual frequency is bounded by WAU's run schedule. |
| `WAU_CompanyName` | REG_SZ | *(empty)* | Company name displayed in the prompt header. E.g. `Contoso` produces "Contoso requires the following updates to be installed." Defaults to "Your organization" if not set. |

### ADMX Policy Files

Dedicated policy definition files are included for deployment via Intune or Group Policy:

| File | Path |
|------|------|
| ADMX | `Sources/Policies/ADMX/WAU-Notifier.admx` |
| ADML | `Sources/Policies/ADMX/en-US/WAU-Notifier.adml` |

These use the namespace `WAUNotifier.Policies` (prefix `WAUN`) and coexist with Romanitho's upstream `WAU.admx` (`Romanitho.Policies.WAU`). Both write to the same registry key, so WAU picks up all values seamlessly.

## Prompt Dialog

### Visual Indicators

| Days Remaining | Row Color | Checkbox |
|----------------|-----------|----------|
| 4+ days | White (default) | Enabled, unchecked |
| 1-3 days | Amber (`#FFF3CD`) | Enabled, unchecked |
| Today (0 days) | Red (`#FFA5A5`) | Disabled, checked (locked) |
| Overdue | Red (`#FFA5A5`) | Disabled, checked (locked) |

### User Actions

| Scenario | Available Actions |
|----------|-------------------|
| No final-day apps, no checkboxes | **Update Now** (all apps) or **Remind Me in X Days** |
| No final-day apps, some checked | **Update Selected (N)** -- updates checked apps, reminds for the rest |
| Final-day apps present (mixed) | **Update Selected (N)** or **Update Now** -- Remind button hidden. Final-day apps are pre-checked and locked. User can additionally check future-deadline apps. |
| All apps are final-day | **Update Now** -- Remind button hidden. All checkboxes locked. |

### Dialog Controls

- **X button** -- Always blocked. Users must use the on-screen buttons.
- **Auto-dismiss** -- If the dialog sits open for (ReminderIntervalDays - 1 hour), it auto-closes without writing a snooze. The next WAU run re-prompts with fresh data.
- **Sort order** -- Apps sorted ascending by days remaining (most urgent at top).

## Architecture

### Scheduled Tasks

WAU-Notify registers two additional scheduled tasks under the `WAU` task path:

| Task | Run As | Purpose |
|------|--------|---------|
| `Winget-AutoUpdate-UpdatePrompt` | SYSTEM (via ServiceUI.exe) | Presents the WPF dialog in the logged-in user's desktop session |
| `Winget-AutoUpdate-UpdateNow` | SYSTEM | Installs updates when the user clicks Update Now |

Both tasks use `MultipleInstances = IgnoreNew` to prevent concurrent runs.

### Files

| File | Status | Purpose |
|------|--------|---------|
| `Winget-Upgrade.ps1` | Modified | Adds deadline if/else branch around the main update loop |
| `config/WAU-MSI_Actions.ps1` | Modified | Registers/unregisters the two new scheduled tasks |
| `WAU-UpdatePrompt.ps1` | New | WPF dialog, user interaction, partial update logic |
| `WAU-UpdateNow.ps1` | New | Processes updates from pending-updates.json |
| `functions/Get-UpdateDeadlines.ps1` | New | Reads/purges deadline registry entries |
| `functions/Set-UpdateDeadline.ps1` | New | Creates/updates deadline registry entries |
| `functions/Start-UpdatePromptTask.ps1` | New | Writes pending-updates.json, fires UpdatePrompt task |

### Registry Structure

**Deadline tracking** (per-app, managed by SYSTEM task):
```
HKLM:\SOFTWARE\Romanitho\Winget-AutoUpdate\UpdateDeadlines\
  <AppId>\
    FirstDetected    = "2026-02-27"
    Deadline         = "2026-03-06"
    AvailableVersion = "130.0.1"
```

**Snooze tracking** (machine-wide):
```
HKLM:\SOFTWARE\Romanitho\Winget-AutoUpdate\
  NextPromptTime = "2026-03-01T10:00:00.0000000-06:00"
```

### Data Flow

```
WAU SYSTEM Task (Winget-Upgrade.ps1)
  |
  |-- Detect outdated apps (Get-WingetOutdatedApps)
  |-- Filter through whitelist/blacklist
  |-- Sync deadline registry (Set-UpdateDeadline / Get-UpdateDeadlines)
  |-- Split: Overdue vs Pending
  |
  |-- Overdue --> Force update silently (Update-App) + toast
  |
  |-- Pending --> Check NextPromptTime snooze
  |     |-- Snoozed --> Skip, exit
  |     |-- Ready   --> Write pending-updates.json
  |                     Fire UpdatePrompt task --> Exit
  |
  UpdatePrompt Task (WAU-UpdatePrompt.ps1 via ServiceUI.exe)
    |-- Show WPF dialog to logged-in user
    |-- "Update Now" / "Update Selected"
    |     |-- Rewrite JSON (partial) or keep (full)
    |     |-- Fire UpdateNow task
    |-- "Remind Me"
    |     |-- Write NextPromptTime to registry
    |
  UpdateNow Task (WAU-UpdateNow.ps1)
    |-- Read pending-updates.json
    |-- Machine-scoped apps --> Update-App + Confirm-Installation
    |-- User-scoped apps --> Hand off to UserContext task
    |-- Purge deadline registry for confirmed updates
    |-- Delete pending-updates.json
```

## Installation

Download the latest MSI from the [Releases](https://github.com/rtylerdavis/WAU-Notify/releases) page.

```powershell
msiexec /i WAU-Notify.msi DISABLEWAUAUTOUPDATE=1 /qn
```

`DISABLEWAUAUTOUPDATE=1` prevents upstream WAU from auto-updating over this fork.

After install, set `WAU_UpdateDeadlineDays` via one of:

- **Intune** -- Upload `WAU-Notifier.admx`/`.adml`, create a configuration profile
- **Group Policy** -- Copy ADMX/ADML to PolicyDefinitions, configure via GPMC
- **Registry** -- Set directly:
  ```powershell
  Set-ItemProperty -Path "HKLM:\SOFTWARE\Romanitho\Winget-AutoUpdate" -Name "WAU_UpdateDeadlineDays" -Value "7"
  ```

If `WAU_UpdateDeadlineDays` is not set or is `0`, WAU-Notify has no effect and WAU behaves exactly as upstream.

## Known Limitations

- **Machine-wide snooze** -- `NextPromptTime` is stored in HKLM. On shared/RDS machines, one user's snooze affects all users.
- **User-context one-cycle delay** -- User-scoped apps are detected in the user-context run and picked up by the SYSTEM task on the next cycle.
- **ServiceUI on locked screens** -- If no user session is available, the prompt is skipped gracefully and retried on the next WAU run.
- **Black console flash** -- Brief black window flash from ServiceUI.exe/conhost.exe is cosmetic only.

## Upstream

This project is based on [Winget-AutoUpdate](https://github.com/Romanitho/Winget-AutoUpdate) by Romanitho. An upstream proposal has been submitted as [issue #1130](https://github.com/Romanitho/Winget-AutoUpdate/issues/1130). Romanitho is working on a C# rewrite of WAU using the WinGet COM API and may integrate this feature into the new version.
