# CrossPay App Theme Fix

**Status (2026-11-10): DONE — build green, dark palette rewritten, per-screen
sweep completed.** The toggle is wired through Riverpod, the choice is
remembered, `/settings` is reachable from the Account hub, and every feature
screen reads its colours from the `ColorScheme` (only brand/status colours and
the QR module paint stay fixed by design). See `docs/BUILD_LOG.md`.
## Problem Statement
### 1. Theme Toggle Not Working
- Root Cause: CrossPayApp is StatelessWidget with themeMode passed from main() only. Never rebuilds when theme changes.
### 2. Dark Mode Colors Still White
- Root Cause: app_theme.dart uses hardcoded AppColors.* instead of ColorScheme values.
### 3. Theme Toggle Inside Language Screen
- Root Cause: Theme selector embedded in language_selector_screen.dart alongside language selection.

## Final Plan
### Step 1: Fix app_theme.dart
- Replace hardcoded AppColors.background with scheme.background
- Replace AppColors.surface with Theme.of(context).colorScheme.surface
- Set dark theme surface: const Color(0xFF1E1E2E) (not white)
### Step 2: Create theme_provider.dart
- Centralize theme mode state in Riverpod
- Move themeModeProvider from language_selector_screen
- Import SecureThemeStore from core/storage/
### Step 3: Update CrossPayApp in app.dart
- Convert from StatelessWidget to ConsumerStatefulWidget
- Remove themeMode constructor parameter
- Rebuild on theme changes via Riverpod watcher
### Step 4: Update main.dart
- Wire themeModeProvider from Riverpod
- Pass theme mode to CrossPayApp via provider override
### Step 5: Update Routes
- Change AppRoutes.language to AppRoutes.settings
- Point to new SettingsScreen
### Step 6: Create SettingsScreen
- Professional settings with Language, Appearance, Security sections
- Replace language_selector_screen with unified settings
### Step 7: Remove Theme Toggle from language_selector_screen
- Remove themeModeProvider and AppThemeModeNotifier
- Keep language selector focused only on language

## Git Commitment Pick-up Point
After implementing all changes, commit with:
```bash
git add lib/core/theme/app_theme.dart lib/providers/theme_provider.dart lib/app.dart lib/main.dart lib/features/account/screens/settings_screen.dart lib/features/account/screens/language_selector_screen.dart
git commit -m "feat: fix theme system and reorganize settings screen"
```

## Delivered 2026-11-09 (branch `fix/theme-system`)

- `lib/core/storage/theme_store.dart` — `ThemeStore` / `SecureThemeStore`
  (`theme_mode`), split out of the language store.
- `lib/providers/theme_provider.dart` — state-first writes, storage failures
  tolerated, optional `main()` seed; no flash on launch.
- `lib/main.dart` — reads language and theme before `runApp`.
- `lib/app.dart` — 1:1 `AppThemeMode` → `ThemeMode`; `/settings` route.
- `lib/features/account/screens/settings_screen.dart` — localized hub for
  language, appearance and security; Account tab tile points here.
- `lib/core/theme/app_theme.dart` — light and dark palettes both derive text,
  input and button colors from `ColorScheme`; dark uses `#12121C` scaffold,
  `#1E1E2E` surface and a light indigo primary. On-colors pass a 4.5:1 contrast
  test.
- Tests — `test/theme_provider_test.dart`, `test/settings_screen_test.dart`,
  `test/app_theme_test.dart`.
- Still open — biometrics are present but not wired. The per-screen colour
  sweep shipped on 2026-11-10; only brand/status colours and the QR paint stay
  fixed by design.

## Next Steps
1. Execute Step 1-7 from Final Plan
2. Add remaining settings sections
3. Test theme toggle functionality
4. Verify dark mode colors work correctly
