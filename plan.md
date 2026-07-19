# Implementation Plan for a Modern Windows 11 User Interface

## 0. Implementation status and adaptations (2026-07-19)

The plan below was implemented with the following deliberate adaptations,
driven by the verified runtime environment (Windows PowerShell 5.1 host via
`powershell.exe -STA`, .NET Framework WinForms):

1. **DPI (WP 1):** PerMonitorV2 requires an app-level configuration file that a
   portable app cannot provide for `powershell.exe`; API-only PerMonitorV2
   would leave WinForms unable to rescale on monitor changes. The implemented
   strategy is explicit **System-DPI awareness** (`SetProcessDpiAwareness(1)`
   with `SetProcessDPIAware` fallback) plus `AutoScaleMode.Dpi` and an explicit
   `PerformAutoScale()` after the layout is built — empirically required
   because WinForms under the PowerShell host does not run the implicit
   autoscale pass. Cross-DPI monitor moves fall back to DWM stretching.
2. **Responsive layout (WP 2):** Implemented with an outer `TableLayoutPanel`
   (auto-sized rows; the folder section takes the remaining space) and a
   nested table layout for the folder area. The window is resizable and
   maximizable; minimum and initial size are clamped to the active monitor's
   working area in the `Shown` handler (after DPI scaling). Whole-form
   Whole-form scrolling was replaced by a dedicated scrollable content host;
   the footer remains visible. At ordinary sizes the folder list receives all
   spare height and scrolls locally. If the complete minimum layout cannot fit
   at high scaling (for example 175%), the content host scrolls vertically
   instead of dropping entire rows. Destination, option, and footer commands
   use nested table or wrapping flow layouts so width clamping cannot overlap
   them.
3. **Folder/backup management (WP 3):** Implemented as planned. The large logo
   was removed from the workflow; History, Verify backup, and Delete backup
   form a labeled "Backup management" row below the list, with Delete last and
   spatially separated.
4. **Interaction targets (WP 4):** A shared button factory (`New-M24Button`)
   provides consistent styles; secondary commands are 32 logical pixels high,
   footer actions 40. Checkbox rows received padded hit areas.
5. **Options (WP 5):** Operation options sit in a labeled "Options" row;
   the reminder is presented as a separate labeled persistent setting row
   ("Remind me at Windows sign-in when a backup is due") instead of a separate
   settings dialog (kept deliberately small, as the plan allows). "Super fast"
   was renamed to "Fast mode (no preflight checks)"; the former term is
   mentioned in help and changelog.
6. **Themes and accessibility (WP 6):** Per the plan's risk mitigation, no
   dark mode ships: WinForms on .NET Framework renders drop-downs, scroll
   bars, and menus light, so a coherent, contrast-checked light theme plus
   High Contrast support (system colors and system-styled buttons) was
   implemented instead. High Contrast is evaluated once at startup; a scheme
   change while the app is running takes effect after a restart, the
   restart-based behavior the plan permits for theme changes. Colors moved to
   a central semantic palette. Accessibility metadata
   (`AccessibleName`/`AccessibleDescription`) was added to key controls and
   the summary box is keyboard-reachable; this is metadata coverage, not yet
   a verified Narrator/UI-Automation pass (see the remaining manual
   verification below).
7. **Splash (WP 7):** Instead of a startup measurement campaign, the splash is
   created lazily after a fixed 400 ms threshold, so fast starts show no
   splash at all. The potentially slow logical-drive query runs in a guarded
   background runspace while the UI thread pumps status updates, so the
   threshold is also honored while CIM is waiting. The splash is small, never
   `TopMost`, centered on the monitor with the cursor, and the artificial
   300 ms completion delay was removed.

Remaining manual verification (not automatable here): the full visual test
matrix of section 12 (multiple scale factors and monitors, Narrator
walkthrough, all High Contrast schemes, touch input).

## 1. Purpose and scope

This plan describes the staged modernization of the **Bibliothekssicherung** Windows Forms interface. It covers the seven prioritized areas identified during the GUI and splash-screen review:

1. Per-monitor DPI awareness and text scaling
2. Responsive layout using Windows Forms layout containers
3. Reorganization of the folder and backup-management area
4. Larger and more consistent interaction targets
5. Reorganization of backup options and persistent settings
6. Dark mode, high contrast, and accessibility
7. Optimization or removal of the splash screen

The application is implemented in PowerShell and Windows Forms. Migration to WinUI 3 or the Windows App SDK is outside the scope of this work. The objective is a robust, accessible, Windows 11-aligned experience within the existing technology stack. Mica, Acrylic, and custom emulation of WinUI controls are deliberately not priorities. Microsoft documents the supported Mica path for classic Win32 applications through the Windows App SDK, which would introduce additional runtime and deployment dependencies [S11].

Backup logic, restore behavior, backup format, and command-line interfaces must remain unchanged. UI modernization must not alter the reliability or semantics of backup and restore operations.

## 2. Design principles and source basis

Implementation should follow these principles:

- **Function before decoration:** DPI robustness, responsive behavior, keyboard support, and contrast take priority over rounded corners or material effects.
- **Use platform behavior:** Prefer standard Windows Forms controls, system colors, system fonts, and UI Automation wherever practical.
- **Fluid rather than pixel-fixed:** Microsoft recommends assigning explicit measurements only to selected key elements and using flexible sizing for the rest of the interface [S2].
- **Calm visual hierarchy:** Windows 11 emphasizes an uncluttered, focused experience supported by subtle layering and restrained emphasis [S1].
- **Four-pixel grid:** Use dimensions, margins, and padding in increments of four logical pixels where possible. Microsoft recommends 24 epx gutters for larger windows and 12 epx for narrow layouts [S2].
- **Accessibility as an acceptance criterion:** Contrast, keyboard operation, screen readers, high-contrast themes, text enlargement, and accessible names are core quality requirements [S6][S7].

## 3. Current implementation baseline

The relevant UI code is located primarily in `Bibliothekssicherung-GUI.ps1`:

- The main window has a fixed client size of 720 × 698 pixels, uses `FixedSingle`, cannot be maximized, and contains many absolutely positioned controls.
- `AutoScroll` handles insufficient screen height but does not provide responsive reflow.
- The application already prefers Segoe UI Variable and falls back to Segoe UI.
- `EnableVisualStyles()` is called, but no explicit PerMonitorV2 configuration or DPI-change handling is present in the repository.
- Many secondary buttons are only 27 pixels high.
- A 187 × 164 pixel logo occupies a significant portion of the folder-selection area.
- Five options are positioned at fixed X coordinates in a single 34-pixel-high row.
- Many colors are hard-coded light RGB values.
- The splash screen is borderless and `TopMost`, measures 390 × 285 pixels, displays a 300 × 205 pixel logo, and intentionally keeps the completed state visible for an additional 300 ms.

Before implementation begins, capture reference screenshots at 100% and 125% display scaling. These screenshots will serve as the visual-regression baseline.

## 4. Implementation order and dependencies

The work packages should be completed in this order:

1. Establish a reliable DPI foundation because all later sizing decisions depend on it.
2. Introduce responsive layout before finalizing individual spacing and target sizes.
3. Reorganize content after the layout foundation is stable.
4. Standardize interaction targets after their final groups and positions are known.
5. Reorganize options and persistent settings.
6. Complete themes and accessibility after the visual and semantic structure is stable.
7. Decide the splash-screen strategy using measured startup performance and reuse the DPI/theme infrastructure.

The application must remain executable and functionally complete after each work package. Changes should be split into small, focused commits.

---

## 5. Work package 1: PerMonitorV2 DPI awareness and text scaling

### Rationale

Windows Forms has provided improved support for high-DPI and dynamically changing DPI environments since .NET Framework 4.7. On .NET Framework this support is opt-in. Microsoft specifically documents PerMonitorV2 awareness, Windows compatibility declarations, and `EnableVisualStyles()` as parts of the configuration [S3][S4]. Without an explicit DPI strategy, controls can become blurry, scale incorrectly, overlap, or clip text when a window moves between monitors. The current interface is particularly vulnerable because almost every size and position is fixed.

### Target state

- The application is per-monitor DPI-aware wherever reliably supported by the actual PowerShell/Windows Forms host.
- Text, images, spacing, and controls remain sharp and complete when launched on or moved between displays with different scale factors.
- Windows text-size enlargement does not clip labels or commands.
- The application has one documented DPI initialization strategy without conflicting manifest, host, configuration, or API settings.

### Implementation steps

1. **Identify and document the runtime environment**
   - Determine whether the released application runs under Windows PowerShell 5.1/.NET Framework, PowerShell 7/.NET, or a generated executable host.
   - Inspect build, VBS, BAT, installer, and shortcut launch paths because the host process may establish DPI awareness before the GUI script runs.
   - Record the effective .NET version and process that creates the Windows Forms handles.

2. **Select the appropriate DPI activation mechanism**
   - For .NET Framework, prefer Microsoft’s documented PerMonitorV2 configuration [S3][S4].
   - If a foreign PowerShell host prevents app-level configuration, evaluate a safe DPI-awareness API before any Windows Forms handle is created.
   - Never change process DPI awareness after a form or control handle has been created.
   - Document Windows 10 compatibility and fallback behavior.

3. **Configure form autoscaling explicitly**
   - Set `AutoScaleMode` and, where necessary, `AutoScaleDimensions` deliberately instead of relying on implicit defaults.
   - Compare font-based and DPI-based autoscaling in a small prototype. Choose the option that behaves most reliably with Segoe UI Variable, Windows text-size settings, and monitor changes.

4. **Handle dynamic DPI changes**
   - Verify whether the deployed runtime reliably exposes the Windows Forms DPI events (`DpiChanged`, `DpiChangedBeforeParent`, and `DpiChangedAfterParent`) documented by Microsoft [S3].
   - Add manual scaling only for controls that remain defective after normal Windows Forms scaling. Avoid double scaling.
   - Re-evaluate bitmap and icon handling on DPI changes. The source resolution of `logo.jpg` is sufficient, but the application should avoid repeatedly allocating oversized bitmap copies.

5. **Introduce scale-safe layout constants**
   - Centralize recurring logical measurements such as outer margin, section gap, control height, and icon size.
   - Do not persist device-pixel measurements derived from a particular monitor.

### Verification

- Launch at 100%, 125%, 150%, 175%, and 200% display scaling.
- Move the open window in both directions between monitors using different scale factors.
- Test Windows text size at 100%, 125%, 150%, and 200%.
- Inspect the title area, mode selector, destination selector, checked list, options, status area, footer, custom dialogs, and splash screen.
- Confirm that there is no clipped text, overlap, blurry image, or double scaling.

### Acceptance criteria

- Every interactive control remains reachable at all listed scale factors.
- German and English text is either fully readable or intentionally wrapped/ellipsized with the full text made available through an accessible tooltip or description.
- Moving between monitors does not raise an exception or leave the layout corrupted.
- The DPI strategy is clearly documented in code and developer documentation.

### Risks and mitigations

- **The PowerShell host overrides DPI behavior:** Test the real release launch path and initialize DPI awareness at the earliest valid point.
- **Anchored controls scale twice:** Do not introduce parallel manual scaling while automatic scaling works.
- **Older systems or runtimes lack an API:** Use feature detection and safe fallbacks rather than assuming availability.

---

## 6. Work package 2: Responsive layout with Windows Forms layout containers

### Rationale

The current UI assigns fixed coordinates to nearly every element. Microsoft recommends flexible alignment and sizing, with explicit measurements applied only to key elements. Fixed dimensions can clip content when text is enlarged or window width changes [S2]. Responsive layout improves DPI behavior, localization, small-screen usability, and maintainability at the same time.

### Target state

- The main window can be resized meaningfully in both dimensions and can be maximized.
- Primary content grows with the window; the footer and primary action remain predictably placed.
- Narrow windows trigger reflow or local scrolling instead of uncontrolled whole-form scrolling.
- Spacing follows a consistent four-pixel grid.

### Implementation steps

1. **Create the top-level layout structure**
   - Use an outer `TableLayoutPanel` with rows for header, destination, folder/backup management, options, activity, and footer.
   - Use `AutoSize` for most rows and allow the folder or result region to consume remaining space.
   - Prefer 24 logical pixels for normal outer gutters and support 12 pixels in narrow layouts [S2].

2. **Encapsulate each section**
   - Move every functional section into its own layout container with defined internal spacing.
   - Remove the need for separate absolutely positioned decorative panels behind controls.
   - Eliminate Z-order repair code such as `SendToBack()` once the new structure is stable.

3. **Make the header responsive**
   - Place title and description in a vertical group on the left.
   - Place mode selection and Help in an automatically sized group on the right.
   - At narrow widths, allow the right group to move below the title instead of overlapping text.

4. **Rebuild the destination section**
   - Arrange label, ComboBox, and Refresh button in three columns.
   - Give the ComboBox the flexible remaining width.
   - Put destination metadata and warnings in a separate row that can wrap safely.

5. **Make the activity area flexible**
   - Align Status and Duration with a two-column layout.
   - Stretch the progress bar across available width.
   - Allow the summary field to grow in width and height instead of relying on a fixed 64-pixel height.

6. **Stabilize the footer**
   - Keep the primary action first in reading and tab order.
   - Put secondary commands in a `FlowLayoutPanel` that can wrap when necessary.
   - Keep Close clearly secondary without relying on hard-coded coordinates.

7. **Update window behavior**
   - Replace `FixedSingle` with an appropriate resizable border and enable maximization.
   - Determine minimum size from the smallest actually usable layout, not the previous outside dimensions.
   - Use whole-form `AutoScroll` only as a final fallback; prefer local scroll areas.
   - Ensure the initial bounds fit entirely within the active monitor’s working area.

### Verification

- Test below, at, and above the original window width.
- Test 1366 × 768, 1920 × 1080, and 4K displays at multiple scale factors.
- Compare German and English layouts.
- Use long drive names, custom folder paths, and status messages.
- Test ready, running, success, failure, restore, verification, and deletion states.

### Acceptance criteria

- Controls never overlap.
- The primary action and Cancel remain reachable without horizontal scrolling.
- The folder list and summary use additional space meaningfully.
- Focus indicators are fully visible.
- The interface remains fully operable at minimum size.

### Risks and mitigations

- **Large visual regression surface:** Migrate one section at a time and compare screenshots after each section.
- **Windows Forms AutoSize feedback loops:** Avoid contradictory combinations of AutoSize, percentage sizing, anchors, and docking; prototype the container hierarchy first.
- **Hidden controls affect row height:** Explicitly test backup/restore and start/cancel visibility transitions.

---

## 7. Work package 3: Reorganize folder selection and backup management

### Rationale

Folder selection, selection commands, history, verification, deletion, and a large logo currently compete within one section. Windows 11 design principles emphasize calm, focus, familiarity, and restrained use of hierarchy [S1]. Microsoft also recommends keeping branding small and outside the user’s workflow [S10].

### Target state

- Folder selection is the dominant content of the section.
- Commands appear next to the content they affect.
- Backup-management commands form a distinct group.
- The large logo no longer consumes productive workspace.
- Destructive commands are clear but do not dominate the screen continuously.

### Implementation steps

1. **Remove the large logo from the workflow**
   - Remove the large `PictureBox` beside the folder list.
   - Limit branding to the app icon, window title, About content, or a much smaller header mark.
   - Prefer no additional logo in the main workflow unless testing demonstrates a real need.

2. **Expand the folder list**
   - Let the list use the reclaimed width and available vertical space.
   - Handle long custom folder names with controlled ellipsis plus tooltip, or another fully readable presentation.
   - Display selection count within the same functional group.

3. **Group direct list actions**
   - Place All, None, Add, and Remove in a single command area directly above, below, or beside the list.
   - All/None may use a compact text-command presentation if focus visibility and target size remain sufficient.
   - Enable Remove only for a selected removable custom folder; built-in libraries remain protected.

4. **Create a separate backup-management group**
   - Move History, Verify backup, and Delete backup into a clearly labeled “Backup management” section.
   - Show or enable the group only when a relevant backup destination is selected.
   - Put Delete backup last and away from frequently used selection commands.

5. **Standardize command hierarchy**
   - Use the accent style only for the central Start action.
   - Keep secondary commands neutral.
   - Express destructive meaning through text, placement, and optionally an icon as well as color; color must not be the only cue [S6].

6. **Review command wording**
   - Consider renaming History to “Recent operations” if that better matches the actual dialog.
   - Keep Verify backup and Delete backup if the currently selected target is unambiguous.
   - Continue to state destination, scope, and consequences in deletion confirmation text.

### Verification

- Test with zero, one, nine, and many custom folders.
- Compare selection of built-in and custom folders.
- Test no backup, valid backup, incomplete backup, and unavailable destination.
- Navigate both command groups entirely by keyboard.
- Test large text and long English labels.

### Acceptance criteria

- Users can distinguish folder commands from commands affecting an existing backup without documentation.
- Branding no longer reduces useful folder-list width.
- Delete backup is not adjacent to high-frequency selection commands.
- Tab order matches visual and functional order.

### Risks and mitigations

- **Existing users rely on current locations:** Use clear group labels and preserve discoverability.
- **Too many secondary commands remain visible:** Reduce or collapse unavailable management content only if it remains easy to find.

---

## 8. Work package 4: Larger and consistent interaction targets

### Rationale

Microsoft recommends an approximately 7.5 mm or 40 × 40 ePixel target for broadly accessible Windows interaction. Frequently used controls and controls with serious consequences may need more space [S5]. Many current buttons are 27 pixels high, while the footer buttons already use an appropriate 40-pixel height. Larger targets improve touch, high-resolution mouse use, motor accessibility, and remote-session usability.

### Target state

- Primary and frequently used buttons are at least 40 logical pixels high.
- Compact secondary actions use a comfortable height of at least 32–36 pixels; use 40 pixels where touch is a design target.
- Checkbox and radio-button rows have a generous clickable area, not merely a small glyph target.
- Spacing reduces accidental activation, especially near Delete backup.

### Implementation steps

1. **Define control density**
   - Establish a common size system: for example, 40 pixels for regular commands and 32/36 only for clearly secondary compact actions.
   - Use horizontal padding sufficient for both German and English labels.

2. **Standardize buttons**
   - Use `MinimumSize` rather than a fixed width where content should determine width.
   - Create reusable style/factory functions for primary, secondary, and destructive buttons.
   - Define consistent Normal, Hover, Pressed, Disabled, and Focus states.

3. **Enlarge checkbox and radio-button hit areas**
   - Use padding or row containers so the full option row is easy to click.
   - Leave adequate space between adjacent options.
   - Present Back up/Restore as a related but comfortably sized choice group.

4. **Verify focus rendering**
   - FlatStyle customization must not suppress the standard keyboard focus indicator.
   - Any custom painting must preserve a clearly visible focus state in all themes and high contrast.

5. **Protect destructive actions**
   - Increase separation between Delete backup and routine commands.
   - Keep the confirmation dialog and typed confirmation where currently required.
   - Never assign default focus to destructive confirmation.

### Verification

- Test mouse, touch or touch simulation, keyboard, and on-screen keyboard.
- Test with Magnifier and through Remote Desktop.
- Navigate using only Tab, Shift+Tab, Space, Enter, and Escape.
- Inspect Normal, Hover, Pressed, Disabled, Focus, and High Contrast states.

### Acceptance criteria

- Primary actions meet or exceed 40 × 40 ePixels.
- No frequent action is available only through a small text or glyph target.
- Every focusable command has an unmistakable visible focus indicator.
- Destructive and normal actions are spatially and semantically distinct.

### Risks and mitigations

- **Larger controls increase window height:** Use the responsive reflow introduced in work package 2.
- **FlatStyle weakens platform states:** Minimize custom painting and prefer standard controls.

---

## 9. Work package 5: Reorganize operation options and persistent settings

### Rationale

The current option row mixes settings for the next backup with a persistent application preference. “Super fast” also hides major safety implications in a long tooltip. Microsoft recommends concise, helpful language, leading with the important information and using active wording [S9]. Persistent preferences belong in a recognizable settings area [S8].

### Target state

- Options for the next operation are separated from persistent application preferences.
- Safety implications are visible without relying solely on tooltips.
- Options can wrap and remain usable with enlarged text.
- Dependencies and conflicts between options are explained clearly.

### Implementation steps

1. **Classify every option**
   - Operation-specific: Simulation, Eject after success, Checksums, and the fast mode.
   - Persistent preference: Reminder.
   - Verify which values are persisted today and whether persistence matches the visible meaning.

2. **Create a named operation-options section**
   - Use a heading such as “Backup options” or “Options.”
   - Replace fixed X coordinates with a flexible, wrapping container.
   - Explain disabled states and dependencies beside the relevant option when needed.

3. **Rename and explain fast mode**
   - Replace “Super fast” with a factual name such as “Fast mode — skip preflight checks.”
   - Provide concise visible supporting text or an accessible information button.
   - Keep detailed help available, but do not hide critical consequences exclusively in a tooltip.
   - Consider a first-use or pre-operation confirmation appropriate to the risk without interrupting every normal start.

4. **Move Reminder to Settings**
   - Add a small settings dialog or clearly identified persistent-preferences area.
   - Label the option “Remind me to back up” and explain its interval and behavior.
   - Preserve the transparency statement that no background service is installed where useful.

5. **Expose dependencies**
   - When an option is unavailable because of mode or another choice, provide a short reason through visible text, tooltip, or AccessibleDescription as appropriate.
   - Preserve consistent state when switching between Backup and Restore.

6. **Standardize microcopy**
   - Ensure German and English strings communicate the same meaning in concise active language.
   - Define specialized terms such as checksum, simulation, and preflight check in Help.

### Verification

- Test every meaningful combination of operation options.
- Switch between Backup and Restore with options selected.
- Restart the application and verify persistent versus operation-specific state.
- Test without a mouse and with Narrator.
- Test at 200% text size.

### Acceptance criteria

- Reminder is clearly presented as a persistent application preference.
- The consequences of fast mode are understandable before activation or, at the latest, before the operation starts.
- Options are never clipped at narrow widths or enlarged text sizes.
- Tooltips supplement rather than exclusively contain safety-critical information.

### Risks and mitigations

- **A settings dialog adds complexity:** Initially keep it small and limited to genuinely persistent preferences.
- **Renaming confuses existing users:** Mention the former term temporarily in Help or the changelog.

---

## 10. Work package 6: Dark mode, high contrast, and accessibility

### Rationale

The current interface uses many fixed light colors. Windows does not assume that classic Win32 applications support dark mode; even the standard dark title bar can require explicit activation [S12]. Microsoft’s accessibility guidance requires accessible names, keyboard support, a minimum 4.5:1 contrast ratio, high-contrast testing, and verification with UI Automation and screen-reader tools [S6][S7].

### Target state

- The interface follows the Windows light/dark app mode where practical and applies changes at least after a controlled restart; live theme changes are desirable.
- High Contrast uses system colors and remains completely operable.
- Interactive and meaningful controls expose correct accessible names, roles, states, and descriptions.
- Color is never the sole carrier of information.
- Keyboard order and screen-reader output follow the visible workflow.

### Implementation steps

1. **Introduce a semantic theme abstraction**
   - Replace scattered RGB literals with a central theme palette.
   - Define semantic roles such as WindowBackground, Surface, Border, PrimaryText, SecondaryText, Accent, Warning, Error, Disabled, and Focus.
   - Continue using the system accent where contrast and state behavior are reliable.

2. **Implement light and dark themes**
   - Read the Windows app mode from an appropriate documented system source.
   - Align the standard title bar with client content. Microsoft documents `DWMWA_USE_IMMERSIVE_DARK_MODE` for classic Win32 applications [S12].
   - Test ComboBox, CheckedListBox, TextBox, context menus, tooltips, and dialogs. A dark title bar above an otherwise hard-coded light UI is not sufficient.
   - Either react to live theme changes or document that changes apply on the next application start.

3. **Handle High Contrast separately**
   - Use `SystemColors` when High Contrast is active.
   - Decorative surfaces and custom borders must not override system contrast colors.
   - Progress, focus, warnings, and errors must remain understandable without custom colors.

4. **Measure contrast**
   - Verify all normal text colors against their actual backgrounds; regular visible text must reach at least 4.5:1 [S6][S7].
   - Disabled text must still communicate state even where normal-text contrast rules differ.
   - Supplement warning and error colors with text and/or symbols.

5. **Add UI Automation metadata**
   - Set `AccessibleName`, `AccessibleDescription`, and, where needed, `AccessibleRole` for controls whose visible text is insufficient.
   - Associate labels logically with form inputs wherever Windows Forms permits.
   - Mark decorative images appropriately; give meaningful images useful descriptions.
   - Evaluate status updates and completion messages for useful screen-reader announcements without excessive repetition.

6. **Review keyboard and focus behavior**
   - Rebuild tab order to follow visual reading order.
   - Consider localized mnemonics/access keys for important commands without conflicts.
   - Preserve and document Escape behavior, F1 Help, F5 Refresh, and existing shortcuts.
   - Reconsider whether the read-only result field’s `TabStop = false` unnecessarily prevents keyboard or assistive-technology access.

7. **Include custom dialogs**
   - Apply DPI, theme, focus, and UI Automation testing to deletion confirmation and all custom Forms.
   - Configure default focus, CancelButton, and AcceptButton safely.

8. **Perform systematic accessibility testing**
   - Use Windows Narrator and UI Automation Inspect.
   - Run Accessibility Insights for Windows or an equivalent diagnostic tool.
   - Perform keyboard-only, High Contrast, color-vision, and Magnifier checks.

### Verification

- Windows Light, Dark, and multiple High Contrast themes.
- Theme changes with the application open and closed.
- Narrator reading order and announcements for state changes.
- UI Automation inspection of every control and dialog.
- Contrast measurement for the semantic palette.
- Complete a backup simulation using only the keyboard.

### Acceptance criteria

- Regular text meets the minimum 4.5:1 contrast ratio [S6][S7].
- Every interactive control is keyboard accessible and has visible focus.
- Narrator communicates purpose, state, and relevant descriptions clearly.
- High Contrast contains no unreadable fixed-white or fixed-color islands.
- Health and error states are expressed with text or symbols in addition to color.
- Light and dark title bars match the selected application mode.

### Risks and mitigations

- **Windows Forms dark-mode support is inconsistent:** Prefer system behavior and standard controls. If necessary, ship a coherent accessible light theme rather than an incomplete dark theme.
- **Custom painting reduces UI Automation quality:** Prioritize semantics and native controls.
- **System accent contrast is insufficient:** Measure it and use an accessible semantic fallback when necessary.

---

## 11. Work package 7: Measure, reduce, or remove the splash screen

### Rationale

Microsoft advises against splash screens used primarily for branding. They should provide feedback only when startup is unusually long, because users may otherwise associate them with poor performance [S10]. The current splash does show real status, but its large logo dominates, it is `TopMost`, and it intentionally delays transition by 300 ms. A brief flashing splash can make the program feel slower than showing the main window directly.

### Target state

- A splash appears only when measured startup duration demonstrates a real benefit.
- Fast starts complete without splash flicker or artificial delay.
- Long starts provide calm, informative, accessible feedback.
- Splash and main window use the same DPI and theme strategy.
- Startup remains robust; a splash failure must never prevent the application from opening.

### Implementation steps

1. **Instrument startup performance**
   - Measure process start, shared-script loading, settings loading, drive discovery, metadata inspection, and main-window display.
   - Record scenarios with no external drive, a fast SSD destination, a slow USB drive, and an unavailable or heavily loaded drive.
   - Document median, 90th-percentile, and 95th-percentile startup times.

2. **Define a decision rule**
   - If the main window can normally become responsive almost immediately, remove the splash and show loading state in the main window.
   - If startup duration varies, delay splash creation by approximately 300–500 ms so fast starts remain splash-free.
   - Prefer showing the main window early with destination controls temporarily disabled if drive discovery can continue safely after display.

3. **Reduce the splash visually if retained**
   - Make the logo substantially smaller and prioritize status text and a calm progress indicator.
   - Avoid large duplicate branding in splash and main window.
   - Use the same logical spacing and sizing system as the main UI.
   - Apply Light, Dark, and High Contrast palettes.

4. **Correct window behavior**
   - Remove `TopMost` unless a proven technical requirement exists.
   - Center on the monitor where launch originated or on the active/cursor monitor.
   - Test taskbar and activation behavior through VBS, BAT, installer shortcut, and direct PowerShell launch.
   - Avoid stealing focus from another application during automated startup paths.

5. **Remove artificial completion delay**
   - Remove `Start-Sleep -Milliseconds 300` unless a concrete UX requirement justifies it.
   - Do not show a standalone “Ready” state immediately before the main window replaces it.
   - Use determinate progress only when percentages represent real work; otherwise keep an indeterminate progress indicator.

6. **Make event handling more robust**
   - Review `Application.DoEvents()` calls for reentrancy risks.
   - Where feasible, move startup work into controlled worker-, timer-, or asynchronous steps without altering backup behavior.
   - Prevent startup interactions from triggering the same initialization work more than once.

7. **Add accessibility support**
   - Give the status label a meaningful accessible name.
   - Expose determinate or indeterminate progress correctly.
   - Avoid rapid status changes that cause continuous Narrator announcements.
   - Ensure the login reminder or noninteractive startup paths never show the GUI splash unnecessarily.

### Verification

- Measure at least 20 launches for each representative drive scenario.
- Fast startup: no splash flicker.
- Slow startup: timely feedback, accurate status, and no apparent frozen period.
- Multiple monitors with different DPI values.
- Light, Dark, and High Contrast themes.
- Launch using VBS, BAT, installer shortcut, and direct PowerShell execution.
- Failures while loading the logo, querying drives, and initializing the main UI.

### Acceptance criteria

- The retain/remove decision is backed by recorded measurements.
- Startup is never artificially extended by 300 ms.
- Typical fast starts do not show a short-lived splash.
- Long starts provide visible feedback within a reasonable interval.
- Splash failures do not prevent application startup.
- No unnecessary `TopMost` window obscures other applications.

### Risks and mitigations

- **An early main window appears unfinished:** Show a clear loading state and disable only controls that depend on unfinished drive discovery.
- **Asynchronous work changes initialization order:** Isolate startup UI state, preserve dependencies, and add startup-state tests.
- **A delayed splash races with completion:** Coordinate display and cancellation through one cancellable timer/state machine.

---

## 12. Cross-cutting quality assurance

### Functional regression coverage

Every work package must preserve these workflows:

- Refresh and select destination drives
- Select, clear, add, and remove folders
- Start a simulation
- Start and cancel a normal backup
- Use Restore mode and preflight review
- Open history and log
- Verify a backup
- Delete a backup with its safety confirmation
- Open the backup folder
- Enable and disable reminders
- Handle success, warning, and error states

Run the existing tests in `tests/` after each relevant change. Extract UI-related helper functions where practical so size, theme, and state decisions can be tested without manual interaction.

### Visual test matrix

| Dimension | Minimum coverage |
|---|---|
| Language | German, English |
| Display scaling | 100%, 125%, 150%, 175%, 200% |
| Text size | 100%, 125%, 150%, 200% |
| Theme | Light, Dark, High Contrast |
| Display | 1366 × 768, 1920 × 1080, 4K |
| Input | Mouse, keyboard, touch where available |
| State | Ready, loading, running, success, warning, error, restore |

Not every combination must be tested manually after every commit. Before final acceptance, however, all dimensions and the highest-risk combinations—especially 200% display scaling with enlarged text and High Contrast—must be covered.

### Performance goals

- Layout and theme changes must not materially slow startup.
- Resizing and DPI transitions must not produce long visible stalls.
- Images are loaded once, disposed correctly, and retained only at the necessary resolution.
- Drive discovery must not make the visible window appear frozen.

## 13. Recommended delivery stages

### Delivery A: Technical robustness

- Work package 1: DPI
- Work package 2: responsive layout
- Baseline and regression testing

**Outcome:** A scalable, resizable main window without major content reorganization.

### Delivery B: Information architecture and interaction

- Work package 3: folder and backup management
- Work package 4: interaction targets
- Work package 5: options and settings

**Outcome:** A calmer, better grouped interface with consistent interaction behavior.

### Delivery C: System integration and startup quality

- Work package 6: themes and accessibility
- Work package 7: splash screen
- Full visual and functional test matrix

**Outcome:** A Windows 11-aligned, accessible interface with a startup experience supported by measurements.

## 14. Definition of Done

The modernization is complete when:

1. the application renders correctly at 100–200% display scaling and through cross-monitor DPI changes;
2. the main window is responsively resizable and remains fully operable at minimum size;
3. folder commands and backup management are clearly separated, and no large logo displaces workspace;
4. primary actions meet the 40 × 40 ePixel target and every control has visible keyboard focus;
5. operation-specific options and persistent preferences are separated;
6. Light, Dark, High Contrast, UI Automation, and Narrator satisfy the defined criteria;
7. the splash screen has been removed or implemented as a delayed, reduced experience based on startup measurements;
8. all automated tests pass and core workflows have been manually regression tested;
9. German and English content is not uncontrolledly clipped with enlarged text;
10. the README, changelog, and developer notes document the new window, theme, DPI, and settings behavior.

## 15. Sources

- **[S1] Microsoft Learn — Windows 11 design principles.** “Effortless,” “Calm,” “Personal,” and “Familiar,” plus guidance on color, layering, geometry, and typography.  
  <https://learn.microsoft.com/en-us/windows/apps/design/design-principles>

- **[S2] Microsoft Learn — Alignment, margin, and padding.** Fluid layout, fixed measurements only for key elements, the four-ePixel grid, and recommended 12/24 ePixel gutters.  
  <https://learn.microsoft.com/en-us/windows/apps/design/layout/alignment-margin-padding>

- **[S3] Microsoft Learn — High DPI support in Windows Forms.** PerMonitorV2, Windows compatibility, `EnableVisualStyles`, dynamic DPI events, and scaling helpers for .NET Framework.  
  <https://learn.microsoft.com/en-us/dotnet/desktop/winforms/high-dpi-support-in-windows-forms>

- **[S4] Microsoft Learn — Windows Forms Add Configuration Element.** DPI awareness as an opt-in feature and the `PerMonitorV2` setting.  
  <https://learn.microsoft.com/en-us/dotnet/framework/configure-apps/file-schema/winforms/windows-forms-add-configuration-element>

- **[S5] Microsoft Learn — Guidelines for touch targets.** Approximately 7.5 mm or 40 × 40 pixels at 1.0 scaling and additional spacing for consequential actions.  
  <https://learn.microsoft.com/en-us/windows/apps/develop/input/guidelines-for-targeting>

- **[S6] Microsoft Learn — Accessibility checklist.** Accessible names and descriptions, keyboard support, High Contrast, contrast checks, UI Automation, and screen-reader testing.  
  <https://learn.microsoft.com/en-us/windows/apps/design/accessibility/accessibility-checklist>

- **[S7] Microsoft Learn — Accessible text requirements.** Readability, text scaling, and a minimum 4.5:1 contrast ratio for visible text.  
  <https://learn.microsoft.com/en-us/windows/apps/design/accessibility/accessible-text-requirements>

- **[S8] Microsoft Learn — Guidelines for app settings.** Persistent user preferences should be placed in a recognizable settings experience.  
  <https://learn.microsoft.com/en-us/windows/apps/design/app-settings/guidelines-for-app-settings>

- **[S9] Microsoft Learn — Writing style.** Clear, concise, helpful wording, leading with important information, and active voice.  
  <https://learn.microsoft.com/en-us/windows/apps/design/style/writing-style>

- **[S10] Microsoft Learn — Software Branding.** Keep logos small and outside the workflow; avoid branding splash screens and use a splash only for unusually long startup.  
  <https://learn.microsoft.com/en-us/windows/win32/uxguide/exper-branding>

- **[S11] Microsoft Learn — Apply Mica in Win32 desktop apps for Windows 11.** Supported technical path and Windows App SDK dependency for Mica in classic Win32 applications.  
  <https://learn.microsoft.com/en-us/windows/apps/desktop/modernize/ui/apply-mica-win32>

- **[S12] Microsoft Learn — Support Dark and Light themes in Win32 apps.** Dark title bars for classic Win32 applications using `DwmSetWindowAttribute` and `DWMWA_USE_IMMERSIVE_DARK_MODE`.  
  <https://learn.microsoft.com/en-us/windows/apps/desktop/modernize/ui/apply-windows-themes>

- **[S13] Microsoft Learn — Windows app title bar.** Title-bar behavior, typography, light/dark adaptation, and High Contrast guidance.  
  <https://learn.microsoft.com/en-us/windows/apps/design/basics/titlebar-design>

- **[S14] Microsoft Learn — Design guidelines.** Current overview of color, commanding, layout, materials, typography, usability, and accessibility.  
  <https://learn.microsoft.com/en-us/windows/apps/design/guidelines-overview>
