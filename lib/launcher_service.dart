import 'dart:io';

import 'package:android_intent_plus/android_intent.dart';
import 'package:android_intent_plus/flag.dart';

/// Apps externas desde las que se puede lanzar un juego de Steam ya indexado.
enum GameLauncher {
  gameNative('GameNative', ['app.gamenative', 'app.gamenative.gold']),
  droidDeck('DroidDeck', ['com.droiddeck.launcher']);

  final String label;
  final List<String> packages;
  const GameLauncher(this.label, this.packages);

  AndroidIntent _intent(String package, int appId) => switch (this) {
    // GameNative exige app_id como Int; sin game_source asume STEAM.
    gameNative => AndroidIntent(
      action: 'app.gamenative.LAUNCH_GAME',
      package: package,
      componentName: 'app.gamenative.MainActivity',
      arguments: {'app_id': appId, 'game_source': 'STEAM'},
      flags: [Flag.FLAG_ACTIVITY_NEW_TASK],
    ),
    droidDeck => AndroidIntent(
      action: 'com.droiddeck.launcher.LAUNCH_GAME',
      package: package,
      arguments: {'app_id': appId},
      flags: [Flag.FLAG_ACTIVITY_NEW_TASK],
    ),
  };

  /// Package instalado que atiende el intent, o null si la app no está.
  Future<String?> installedPackage() async {
    if (!Platform.isAndroid) return null;
    for (final package in packages) {
      if (await _intent(package, 1).canResolveActivity() ?? false) return package;
    }
    return null;
  }

  Future<void> launch(String package, int appId) => _intent(package, appId).launch();
}

/// Launchers instalados, con el package que debe usarse para cada uno.
Future<Map<GameLauncher, String>> detectInstalledLaunchers() async {
  final installed = <GameLauncher, String>{};
  for (final launcher in GameLauncher.values) {
    if (await launcher.installedPackage() case final package?) installed[launcher] = package;
  }
  return installed;
}
