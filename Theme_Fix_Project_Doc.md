# CrossPay App Theme Fix
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

## Next Steps
1. Execute Step 1-7 from Final Plan
2. Add remaining settings sections
3. Test theme toggle functionality
4. Verify dark mode colors work correctly
