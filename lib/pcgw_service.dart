import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:html/dom.dart';
import 'package:html/parser.dart' show parse;

import 'hltb_service.dart';
import 'model.dart';

/// Lo que PCGamingWiki aporta sobre un juego y Steam no publica.
class PcgwData({
  required final String page,
  final List<WebLink> translations = const [],
  final List<WebLink> vrMods = const [],
  final List<WebLink> audioFixes = const [],
  final List<WebLink> patches = const [],
  final Support? motion,
  /// Algún runtime de VR de PC (SteamVR, OpenXR, Oculus) figura como nativo.
  final bool vrNative = false,
});

/// Desenlace de una consulta. Como en HLTB, "no tiene artículo" es definitivo y "no se
/// pudo preguntar" merece reintento.
sealed class PcgwLookup {
  const PcgwLookup();
}

final class PcgwFound extends PcgwLookup {
  final PcgwData data;
  const PcgwFound(this.data);
}

final class PcgwNotFound extends PcgwLookup {
  const PcgwNotFound();
}

final class PcgwUnavailable extends PcgwLookup {
  const PcgwUnavailable();
}

/// Lee los artículos de PCGamingWiki por la API de MediaWiki: `action=parse` devuelve
/// el HTML ya renderizado y las tablas de cada plantilla llevan clases estables por
/// las que filtrar.
class PcgwService {
  /// Cloudflare rechaza al cliente HTTP de la app, así que ninguna cola la consulta.
  /// El parseo sigue valiendo para artículos descargados por otra vía.
  static const bool enabled = false;

  static const String _host = 'www.pcgamingwiki.com';

  static final HttpClient _client = .new()
    ..userAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  /// Filas de la tabla de idiomas que cuentan como español.
  static const _spanishRows = {'Spanish', 'Latin American Spanish'};

  /// Runtimes con los que funcionan Quest, Index y compañía. Las filas de 3D (Native 3D,
  /// 3D Vision) son para monitores con gafas y quedan fuera.
  static const _vrRuntimes = {'SteamVR', 'OpenXR', 'Oculus VR (LibOVR)', 'Oculus VR', 'Windows Mixed Reality'};

  static final _audioFixPattern = RegExp(r'DSOAL|OpenAL|HRTF|ALchemy|IndirectSound|3D audio|A3D', caseSensitive: false);
  static final _vrPattern = RegExp(r'\bVR\b|virtual reality|UEVR|vorpX', caseSensitive: false);
  /// Secciones de "Essential improvements" que no son un parche: saltar vídeos y launchers.
  static final _skipSection = RegExp(r'^skip\b', caseSensitive: false);
  static final _wikiPath = RegExp(r'/wiki/([^?#]+)');

  static String pageUrl(String page) => Uri.https(_host, '/wiki/${page.replaceAll(' ', '_')}').toString();

  static Future<Map<String, dynamic>?> _api(Map<String, String> params) async {
    final uri = Uri.https(_host, '/w/api.php', {...params, 'format': 'json'});
    try {
      final response = await (await _client.getUrl(uri)).close();
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode != 200) {
        debugPrint('PCGW respondió ${response.statusCode} [${params['action']}]');
      } else if (jsonDecode(body) case final Map<String, dynamic> json) {
        return json;
      }
    } catch (e) {
      debugPrint('PCGW error de red [${params['action']}]: $e');
    }
    return null;
  }

  /// Título del artículo del juego. `appid.php` redirige al artículo asociado al appid
  /// (las consultas Cargo exigen sesión); sin appid, o sin artículo asociado, se busca
  /// por título y solo se acepta la coincidencia exacta del nombre normalizado.
  /// `null` si no hay artículo, `''` si no se pudo preguntar.
  static Future<String?> _findPage(int? appId, String? name) async {
    if (appId != null) {
      try {
        final request = await _client.getUrl(Uri.https(_host, '/api/appid.php', {'appid': '$appId'}))
          ..followRedirects = false;
        final response = await request.close();
        await response.drain();
        if (_wikiPath.firstMatch(response.headers.value('location') ?? '') case final match?) {
          return Uri.decodeComponent(match[1]!).replaceAll('_', ' ');
        }
        if (response.statusCode != 200) return '';
      } catch (e) {
        debugPrint('PCGW error de red [appid]: $e');
        return '';
      }
    }
    if (name == null) return null;

    final json = await _api({
      'action': 'query',
      'list': 'search',
      'srwhat': 'title',
      'srlimit': '20',
      'srsearch': '"${HltbService.removeDiacritics(name).replaceAll('"', '')}"',
    });
    if (json == null) return '';
    final wanted = HltbService.nameKey(name);
    if (json case {'query': {'search': final List hits}}) {
      for (final hit in hits.whereType<Map>()) {
        if (hit['title']?.toString() case final title? when HltbService.nameKey(title) == wanted) return title;
      }
    }
    return null;
  }

  static Future<PcgwLookup> fetch(int? appId, String? name) async {
    final page = await _findPage(appId, name);
    if (page == null) return const PcgwNotFound();
    if (page.isEmpty) return const PcgwUnavailable();

    final json = await _api({'action': 'parse', 'page': page, 'prop': 'text', 'redirects': '1'});
    if (json == null) return const PcgwUnavailable();
    if (json case {'parse': {'title': final String title, 'text': {'*': final String html}}}) {
      return PcgwFound(parseArticle(title, html));
    }
    // El título existía en la búsqueda, pero el artículo no: borrado o renombrado.
    return const PcgwNotFound();
  }

  // ─── PARSEO DEL HTML ───

  static String _text(Node node) => (node.text ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();

  static Support _rating(Element row, [String suffix = 'rating']) =>
      Support.parse(row.querySelector('[class\$="-$suffix"] [title]')?.attributes['title']);

  static String _parameter(Element row) => _text(row.querySelector('[class\$="-parameter"]')!);

  static String? _externalHref(Element node) => node.querySelector('a.external')?.attributes['href'];

  /// Enlaces de una celda de notas, con la URL absoluta y el texto completo de la nota.
  /// Las anclas de la propia página (`#Input`) se descartan. Sin ningún enlace, la nota
  /// se conserva apuntando a [fallback] para que no se pierda lo que dice.
  static List<WebLink> _links(Element notes, {required String fallback, String? prefix}) {
    final text = _text(notes);
    final note = prefix == null ? text : '$prefix · $text';
    final links = [
      for (final a in notes.querySelectorAll('a[href]'))
        if (a.attributes['href']! case final href when !href.startsWith('#'))
          if (_text(a).replaceAll(RegExp(r'\.$'), '') case final label when label.isNotEmpty)
            WebLink(name: label, url: Uri.https(_host).resolve(href).toString(), note: note),
    ];
    if (links.isNotEmpty) return links;
    return text.isEmpty ? const [] : [WebLink(name: text, url: fallback, note: prefix)];
  }

  /// Público para poder contrastarlo con artículos guardados sin pasar por la red.
  static PcgwData parseArticle(String page, String html) {
    final body = parse(html).body!;
    final url = pageUrl(page); // ancla de respaldo para las notas sin enlace
    // Las citas `[1]` y los "[edit]" solo ensucian los textos, y los saltos de línea
    // pegarían dos frases al extraer el texto plano.
    for (final clutter in body.querySelectorAll('sup.reference, .mw-editsection')) {
      clutter.remove();
    }
    for (final br in body.querySelectorAll('br')) {
      br.replaceWith(Text(' '));
    }

    final translations = <WebLink>[];
    final vrMods = <WebLink>[];
    final audioFixes = <WebLink>[];
    final patches = <WebLink>[];
    Support? motion;
    var vrNative = false;

    // Idiomas: cada fila trae tres estados (interfaz, audio, subtítulos) y las notas con
    // los enlaces a las traducciones no oficiales, que pueden ser varias. Una fila con
    // español de serie no es una traducción, diga lo que diga la nota.
    for (final row in body.querySelectorAll('#table-l10n tr.table-l10n-body-row')) {
      final language = _parameter(row);
      if (!_spanishRows.contains(language)) continue;
      final states = [for (final part in ['ui', 'audio', 'sub']) _rating(row, 'rating-$part')];
      if (!states.any((s) => s == Support.hackable || s == Support.limited)) continue;
      if (row.querySelector('.table-l10n-body-notes') case final notes?) {
        translations.addAll(_links(
          notes,
          fallback: '$url#Localizations',
          prefix: language == 'Spanish' ? 'Español' : 'Español de Hispanoamérica',
        ));
      }
    }

    // VR: con un runtime nativo basta Steam; lo que interesa es el mod o aplicación de
    // las filas "hackable" y vorpX, que mete en el visor juegos sin soporte propio.
    for (final row in body.querySelectorAll('.container-pcgwikitable-settings-vr tr.table-settings-vr-body-row')) {
      final parameter = _parameter(row);
      final state = _rating(row);
      final notes = row.querySelector('.table-settings-vr-body-notes');
      if (parameter == 'Tracked motion controllers') {
        motion = state.best(motion);
      } else if (_vrRuntimes.contains(parameter)) {
        if (state == Support.native) vrNative = true;
        if ((state == Support.hackable || state == Support.limited) && notes != null) {
          vrMods.addAll(_links(notes, fallback: '$url#VR_support', prefix: parameter));
        }
      } else if (parameter == 'vorpX' && state.works) {
        vrMods.add(WebLink(
          name: 'vorpX',
          url: (notes == null ? null : _externalHref(notes)) ?? 'https://www.vorpx.com/supported-games/',
          note: notes == null ? null : _text(notes),
        ));
      }
    }

    // Entrada: el giroscopio aparece en las subtablas de cada familia de mando
    // (PlayStation, Steam Input...); se queda el mejor estado de todas. "Unknown" es
    // que nadie lo ha comprobado, así que no se guarda.
    for (final row in body.querySelectorAll('[id^="table-settings-input"] tr')) {
      if (row.querySelector('[class\$="-parameter"]') == null) continue;
      final state = _rating(row);
      if (state == Support.unknown) continue;
      if (_parameter(row) case 'Motion sensors support' || 'Tracked motion controllers') {
        motion = state.best(motion);
      }
    }

    // Audio: las notas de sonido envolvente y EAX son donde la wiki manda a DSOAL,
    // OpenAL Soft o un HRTF para recuperar el audio posicional. Solo cuenta si hace
    // falta arreglarlo: un juego con Dolby Atmos de serie también nombra el HRTF.
    for (final row in body.querySelectorAll('#table-settings-audio tr.table-settings-audio-body-row')) {
      final notes = row.querySelector('.table-settings-audio-body-notes');
      if (notes == null || !_audioFixPattern.hasMatch(_text(notes))) continue;
      if (_parameter(row) case 'Surround sound' || 'EAX support' when _rating(row) != Support.native) {
        audioFixes.addAll(_links(notes, fallback: '$url#Audio'));
      }
    }

    // Mejoras imprescindibles: una entrada por subsección, con el enlace del propio
    // título si lo lleva (SilentPatch, More Options Mod) o el primero externo del cuerpo,
    // y como nota el primer párrafo. Sin enlace externo no hay nada que descargar: son
    // consejos. Las que hablan de VR son mods de VR, no parches.
    final heading = body.querySelector('h2 > #Essential_improvements')?.parent;
    String? section;
    final sections = <String, ({String? url, String? note})>{};
    for (var node = heading?.nextElementSibling; node != null && node.localName != 'h2'; node = node.nextElementSibling) {
      if (node.localName == 'h3') {
        section = _text(node);
        sections[section] = (url: _externalHref(node), note: null);
        continue;
      }
      if (section == null || _skipSection.hasMatch(section)) continue;
      final (:url, :note) = sections[section]!;
      final text = _text(node);
      sections[section] = (url: url ?? _externalHref(node), note: note ?? (text.isEmpty ? null : text));
    }
    for (final MapEntry(key: title, value: (url: href, :note)) in sections.entries) {
      if (href == null || title.isEmpty || _skipSection.hasMatch(title)) continue;
      final isVr = _vrPattern.hasMatch(title) || (note != null && _vrPattern.hasMatch(note));
      (isVr ? vrMods : patches).add(WebLink(name: title, url: href, note: note));
    }

    return PcgwData(
      page: page,
      translations: translations,
      vrMods: vrMods,
      audioFixes: audioFixes,
      patches: patches,
      motion: motion == Support.unknown ? null : motion,
      vrNative: vrNative,
    );
  }
}
