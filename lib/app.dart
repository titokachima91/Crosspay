import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crosspay_app/core/constants/app_constants.dart';
import 'package:crosspay_app/core/theme/app_theme.dart';
import 'package:crosspay_app/providers/localization_provider.dart';

class CrossPayApp extends StatelessWidget {
  const CrossPayApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: AppConstants.appName,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      home: const _LocalizationCheckScreen(),
    );
  }
}

// Temporary screen to confirm localization works. Replaced in F2.1 (Splash).
class _LocalizationCheckScreen extends ConsumerWidget {
  const _LocalizationCheckScreen();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final code = ref.watch(localeCodeProvider);

    return Scaffold(
      appBar: AppBar(title: const Text(AppConstants.appName)),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              ref.tr('splash.welcome',
                  params: {'appName': AppConstants.appName}),
              style: Theme.of(context).textTheme.headlineMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              ref.tr('app.tagline'),
              style: Theme.of(context).textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            Text(ref.tr('common.language'),
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            SegmentedButton<String>(
              segments: [
                ButtonSegment(
                    value: 'en', label: Text(ref.tr('common.english'))),
                ButtonSegment(
                    value: 'sw', label: Text(ref.tr('common.swahili'))),
              ],
              selected: {code},
              onSelectionChanged: (selection) => ref
                  .read(localeCodeProvider.notifier)
                  .setLanguage(selection.first),
            ),
            const SizedBox(height: 24),
            TextField(
              decoration: InputDecoration(labelText: ref.tr('phone.label')),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () {},
              child: Text(ref.tr('common.continue')),
            ),
          ],
        ),
      ),
    );
  }
}
