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