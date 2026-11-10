# BUILD LOG

Append-only record of what was built, when, and what it left behind. One entry
per increment, newest last. **Nothing here is planned work - it is what the tree
actually contains.** The plan of record stays `MASTER_PROGRESS_REPORT.md`.

---

## 2026-11-07 - Unattended build pass (F4.1 finish, F4.2, F5.1, F5.2, F5.3 part)

**Session rule followed**: frontend only, additive edits, no new pub dependency,
no invented data in `lib/`, honest "not connected" states, full suite green before
each commit.

### Step 0 - documentation scaffolding
- Created `FEATURE_SPEC/INDEX.md` (every plan ID -> spec file -> real state) and
  this BUILD LOG.
- Localization consistency pass for the screens touched in this pass: every new
  or edited string now comes from `lib/core/localization/en.json` + `sw.json`
  (176 -> 261 keys in both, verified identical key sets). **Deferred and
  recorded**: the tracker screen's own status labels and `security_settings`
  strings were left as they are (verified screens, no churn) - see "Deferred".

### Step 1 - F4.1 status timeline
- `ApiEndpoints.tradeHistory`, `TradeEvent` model, shared `parseTradeStatus()`
  (the trade parser now uses it too), `TradeRepository.fetchTimeline`,
  `tradeTimelineProvider`, `TradeTimelineCard` wired into the tracker.
- Tests: `test/trade_timeline_test.dart`.

### Step 2 - F4.1 CSV export
- `ApiEndpoints.tradesExport`, `ExportTicket`, `TradeRepository.requestExport`,
  `tradeExportProvider`, history AppBar download action -> bottom sheet with the
  server link + Copy link (built-in `Clipboard`, no `share_plus`).
- Tests: `test/trade_export_test.dart`.

### Step 3 - F4.1 spending analytics
- `ApiEndpoints.tradesAnalytics`, `TradeAnalytics` / `CorridorSpend`,
  `TradeRepository.fetchAnalytics`, `analyticsProvider`, `AnalyticsScreen`
  (`/analytics`) + Account hub tile + history AppBar action.
- Tests: `test/analytics_screen_test.dart`.

### Step 4 - F4.2 market depth
- `ApiEndpoints.marketDepth`, `CorridorDepth`, `RatesRepository.fetchDepth`,
  `marketDepthProvider`, `MarketDepthScreen`; **the Rates shell tab is now this
  screen** (`_PlaceholderTab` deleted).
- Spec: `FEATURE_SPEC/F4/F4.2.md`. Tests: `test/market_depth_screen_test.dart`.
- `test/main_shell_screen_test.dart` updated for the two real tabs.

### Step 5 - F5.1 profile & limit bar
- `ProfileScreen` (`/profile`) using the existing `profileProvider` /
  `/me` model, with the daily limit bar; Account hub tile.
- Spec: `FEATURE_SPEC/F5/F5.1.md`. Tests: `test/profile_screen_test.dart`.

### Step 6 - F5.2 saved recipients CRUD
- `ApiEndpoints.beneficiary(id)`, `BeneficiaryRepository.add/update/remove`,
  `beneficiariesProvider.add/update/remove` (+ `saving`), `BeneficiariesScreen`
  (`/recipients`) with add/edit dialog and delete confirmation; hub tile.
- Spec: `FEATURE_SPEC/F5/F5.2.md`. Tests: `test/beneficiaries_screen_test.dart`.

### Step 7 - F5.3 remaining codable parts
- Language persistence: `lib/core/storage/language_store.dart`,
  `LocaleCodeNotifier(initial:)` + write-through on change, `main()` reads the
  stored code before the first frame.
- **Not built, by decision** (recorded in `FEATURE_SPEC/F5/F5.3.md`):
  biometrics (needs a `local_auth` dependency), stay-signed-in refresh
  (needs `POST /auth/refresh` on the server).
- Tests: `test/language_preference_test.dart`.

### Step 8 - preview + verification
- `preview/preview_overrides.dart` extended so the demo app shows history,
  timeline, export link, analytics, market depth and recipients; recipients really
  add/edit/delete for the session.
- `dart analyze lib/ preview/ test/` -> **No issues found**.
- `flutter test` -> **200/200 passing**.
- Preview web build + serve check recorded in `MASTER_PROGRESS_REPORT.md`.

### Blocked / not touched
- PART 2 (backend) - not in the repo; every endpoint above is documented in
  `docs/api_contract.md` and each screen shows "not connected" until it exists.
- `lib/core/network/environment_config.dart` - still backlog (real-money release).

### Deferred (deliberate, no churn on verified screens)
- Tracker screen status labels (`_statusLabel`, `_statusIcon`, `_statusColor`) and
  the security-settings / language-selector wording still use plain English
  literals; the new screens and the history screen use the dictionaries.
- Nothing else was deferred silently.

---

## Report End - No fluff. Just facts.

---

## 2026-11-10 - Theme repair (F1.2) and full dark-mode sweep

**Session rule followed**: no invented data in `lib/`, no new dependency, the
server stays the source of truth, nothing pushed.

### Step 1 - restore the build and persist the choice
- `ThemeStore` / `SecureThemeStore` moved to `lib/core/storage/theme_store.dart`;
  `main()` reads the saved language and theme mode before `runApp`, and falls
  back to the defaults when secure storage is unavailable.
- `AppThemeMode` (`light` / `dark` / `system`) maps to Flutter's `ThemeMode` in
  `app.dart`; `themeModeProvider` persists every change write-through.
- `/settings` is now a real hub (language, appearance, security). The Account
  tab tile opens it; every new string exists in both `en.json` and `sw.json`.

### Step 2 - one palette source
- `AppTheme` defines both palettes; screens read
  `Theme.of(context).colorScheme`. Dark scaffold `#12121C`, surface `#1E1E2E`,
  highest surface `#252538`, primary `#9FA8DA`, body text `#F1F2F6`, outline
  variant `#3A3D52`, error `#FF8A80`.
- Light `onSecondary` is black so emerald buttons meet the 4.5:1 text contrast.
- `test/app_theme_test.dart` checks WCAG AA contrast for surface/primary/
  secondary/error pairs in both palettes and that dark no longer paints light
  surfaces.

### Step 3 - sweep the screens
- 34 UI files (screens/widgets) replaced hardcoded `AppColors.navy/textPrimary/
  textSecondary/border/surface/background` and `Colors.white` surfaces with
  scheme colours.
- Only the brand/status palette (emerald, warning, danger, success) and the QR
  module paint stay fixed, by design.
- Removed 15 empty `TextStyle()` artifacts left behind by the earlier colour
  stripping; fixed a Settings subtitle that claimed fingerprint/Face ID before
  biometrics are wired.

### Step 4 - tests that do not race the clock
- `test/payment_provider_test.dart` now polls provider state through `_waitFor`
  instead of assuming a fixed 80-150 ms window; the assertions are unchanged.
- Theme coverage: `test/theme_provider_test.dart` (persistence + choices),
  `test/settings_screen_test.dart` (hub choices), `test/app_theme_test.dart`
  (contrast + dark surfaces).

### Verification
- `dart analyze lib test preview` -> **No issues found** (final tree).
- `flutter test -j 4` -> **210/210 passing**.
- Targeted rerun on the final tree (9 affected files) -> **45/45 passing**.
- `flutter build web --release -t preview/main.dart` -> **Built build/web**
  (578.2 s).

### Still open (not silently claimed as done)
- Biometrics: `local_auth` and `BiometricManager` are in the tree but are not
  wired into the app-lock gate; Android/iOS permission entries are still
  missing. The security screen correctly says "Not available yet".
- Stay signed in: needs `POST /auth/refresh` plus a validation call at boot.
- No push was made; the branch stays local until the product owner confirms.

---

## Report End - No fluff. Just facts.