import 'package:fl_clash/common/sse_history.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

/// The application-owned store outlives this route. Never open or focus a window.
Future<void> runSseTest(BuildContext context, {String? name, int? profileId}) {
  final container = ProviderScope.containerOf(context, listen: false);
  return SseHistory.instance.run(
    container.read(coreHandlerProvider),
    container.read(profilesProvider).map((p) => p.id).toList(),
    name: name,
    profileId: profileId ?? container.read(currentProfileIdProvider),
  );
}
