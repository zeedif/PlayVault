import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:playvault/model.dart';
import 'package:playvault/pcgw_service.dart';

/// Carpeta con respuestas de `action=parse` guardadas (`PCGamingWikiMetadata.Tests/data`
/// del repositorio Jeshibu/PlayniteExtensions); sin ella la prueba se omite.
final fixtures = Platform.environment['PCGW_FIXTURES'];

void main() {
  test('parsea los artículos guardados', skip: fixtures == null ? 'Define PCGW_FIXTURES' : false, () {
    final results = <String, PcgwData>{};
    for (final file in Directory(fixtures!).listSync().whereType<File>()) {
      if (!file.path.endsWith('.json')) continue;
      final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      final parse = json['parse'] as Map<String, dynamic>;
      final data = PcgwService.parseArticle(parse['title'] as String, parse['text']['*'] as String);
      results[file.uri.pathSegments.last] = data;
      final buffer = StringBuffer('== ${data.page}  vrNative=${data.vrNative} motion=${data.motion}\n');
      void dump(String label, List<WebLink> links) {
        for (final l in links) {
          buffer.writeln('  $label: ${l.name} | ${l.url} | ${l.note?.substring(0, l.note!.length.clamp(0, 120))}');
        }
      }
      dump('TRAD', data.translations);
      dump('VR', data.vrMods);
      dump('AUDIO', data.audioFixes);
      dump('PATCH', data.patches);
      // ignore: avoid_print
      print(buffer);
    }

    final yakuza = results['yakuza4.json']!;
    expect(yakuza.translations.single.url, 'https://steamcommunity.com/sharedfiles/filedetails/?id=3385318071');
    expect(yakuza.patches.first.name, 'SilentPatch');
    expect(yakuza.patches.first.url, 'https://cookieplmonster.github.io/mods/yakuza-4/');
    final batman = results['batman.json']!;
    expect(batman.vrMods.map((l) => l.name), contains('vorpX'));
    expect(batman.patches.map((l) => l.name), ['Arkham Quixote']);
    final skyrim = results['skyrim-vr.json']!;
    expect(skyrim.vrNative, isTrue);
    expect(skyrim.motion, Support.native);
    expect(skyrim.audioFixes.single.name, 'X3DAudio HRTF');
    final deathloop = results['deathloop.json']!;
    expect(deathloop.motion, Support.native);
    expect(deathloop.audioFixes, isEmpty);
    expect(deathloop.patches.map((l) => l.name), ['More Options Mod']);
    expect(results['cod-mw.json']!.audioFixes, isEmpty);
    expect(results['cities-skylines.json']!.motion, isNull);
  });
}
