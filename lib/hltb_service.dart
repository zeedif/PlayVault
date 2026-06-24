import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

class HltbTime {
  final double classic;
  final double average;
  final double median;
  final double rushed;
  final double leisure;

  const new({
    this.classic = 0,
    this.average = 0,
    this.median = 0,
    this.rushed = 0,
    this.leisure = 0,
  });

  factory fromJson(Map<String, dynamic> json) => HltbTime(
    classic: (json['classic'] as num?)?.toDouble() ?? 0,
    average: (json['average'] as num?)?.toDouble() ?? 0,
    median: (json['median'] as num?)?.toDouble() ?? 0,
    rushed: (json['rushed'] as num?)?.toDouble() ?? 0,
    leisure: (json['leisure'] as num?)?.toDouble() ?? 0,
  );

  Map<String, dynamic> toJson() => {
    'classic': classic,
    'average': average,
    'median': median,
    'rushed': rushed,
    'leisure': leisure,
  };

  bool get isEmpty =>
      classic == 0 &&
      average == 0 &&
      median == 0 &&
      rushed == 0 &&
      leisure == 0;
}

class HltbStats({
  final String? id,
  final String? steamId,
  final String? name,
  final List<String> aliases = const [],
  final HltbTime mainStory = const HltbTime(),
  final HltbTime extras = const HltbTime(),
  final HltbTime completionist = const HltbTime(),
  final HltbTime allPlayStyles = const HltbTime(),
}) {
  factory fromJson(Map<String, dynamic> json) => HltbStats(
    id: json['id'] as String?,
    steamId: json['steamId'] as String?,
    name: json['name'] as String?,
    aliases: (json['aliases'] as List<dynamic>?)?.map((e) => e as String).toList() ?? [],
    mainStory: HltbTime.fromJson(json['mainStory'] ?? {}),
    extras: HltbTime.fromJson(json['extras'] ?? {}),
    completionist: HltbTime.fromJson(json['completionist'] ?? {}),
    allPlayStyles: HltbTime.fromJson(json['allPlayStyles'] ?? {}),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'steamId': steamId,
    'name': name,
    'aliases': aliases,
    'mainStory': mainStory.toJson(),
    'extras': extras.toJson(),
    'completionist': completionist.toJson(),
    'allPlayStyles': allPlayStyles.toJson(),
  };
}

class _HltbCandidate({required final String id, required final int score});

class HltbService {
  static const String _baseUrl = 'https://howlongtobeat.com';
  static String _currentEndpoint = '/api/bleed';
  static Map<String, String>? _authHeaders;

  static final HttpClient _client = .new()
    ..userAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  static final _diacriticMap = Map.fromIterables(
    'ÀÁÂÃÄÅàáâãäåÒÓÔÕÖØòóôõöøÈÉÊËèéêëÇçÌÍÎÏìíîïÙÚÛÜùúûüÑñŌō'.runes,
    'AAAAAAaaaaaaOOOOOOooooooEEEEeeeeCcIIIIiiiiUUUUuuuuNnOo'.runes,
  );

  static String _removeDiacritics(String text) =>
      String.fromCharCodes(text.runes.map((r) => _diacriticMap[r] ?? r));

  static String _normalizeName(String input) => _removeDiacritics(input)
      .toLowerCase()
      .replaceAll('-', ' ')
      .replaceAll(RegExp(r'[^a-z0-9\s]'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  static Future<HltbStats?> fetchGameStats(String? gameName, String? knownId, String? steamId, bool isRefetch) async {
    try {
      await _initializeAuth();
      final targetNorm = _normalizeName(gameName ?? '');

      bool isExactNameMatch(HltbStats s) =>
          _normalizeName(s.name ?? '') == targetNorm ||
          s.aliases.any((a) => _normalizeName(a) == targetNorm);

      // Si ya conocemos el ID, lo consultamos directamente
      if (knownId != null) {
        final stats = await _fetchGameDetails(knownId);
        // Si el ID conocido devolvió null (por caída de red, etc.),
        // devolver null para conservar el ID y estadísticas previas.
        if (stats == null) return null;
        // Si NO es un refetch (ej. importación o carga), asumimos que el ID es correcto y terminamos.
        if (!isRefetch) return stats;

        // Si ES un refetch, validamos rigurosamente para ver si este ID sigue siendo nuestro mejor candidato
        final isSteamMismatch = steamId != null && stats.steamId != null && stats.steamId != '0' && stats.steamId != steamId;
        if (!isSteamMismatch || isExactNameMatch(stats)) return stats;
        // Si resultó NO ser válido, dejamos que el código proceda al flujo normal de búsqueda más abajo.
      }

      // De lo contrario, buscamos los IDs candidatos ordenados por relevancia base
      final candidates = await _searchGameCandidates(targetNorm);
      if (candidates.isEmpty) return null;

      HltbStats? exactNameFallback;

      for (final candidate in candidates) {
        await Future.delayed(const Duration(milliseconds: 800));
        final stats = await _fetchGameDetails(candidate.id);
        if (stats == null) continue;

        // 1. Prioridad absoluta: Coincidencia exacta de Steam ID.
        if (steamId != null && stats.steamId == steamId) return stats;

        // 2. Coincidencia exacta de nombre.
        if (isExactNameMatch(stats)) {
          // Si no tenemos un Steam ID, el primer nombre exacto es nuestra mejor opción.
          if (steamId == null) return stats;

          // Si tenemos un Steam ID, reservamos esta coincidencia de nombre exacta por si
          // ninguno de los siguientes candidatos tiene el Steam ID buscado.
          exactNameFallback ??= stats;
        }
        // 3. Si no hay coincidencia de Steam ID ni de nombre exacto, simplemente continuamos iterando.
      }

      // Retorna el fallback si hubo coincidencia exacta de nombre, o null si todo falló.
      return exactNameFallback;
    } catch (e) {
      debugPrint('HLTB Error: $e');
      return null;
    }
  }

  static Future<void> _initializeAuth() async {
    if (_authHeaders != null) return;

    final homeHtml = await _client.getUrl(Uri.parse(_baseUrl))
        .then((r) => r.close())
        .then((r) => r.transform(utf8.decoder).join());

    // Extrae el endpoint de la API desde el JS del bundle de Next.js.
    final scriptMatch = RegExp(r'src="([^"]+_app-[^"]+\.js)"').firstMatch(homeHtml);
    if (scriptMatch != null) {
      final scriptUrl = '$_baseUrl${scriptMatch.group(1)}';
      final scriptJs = await _client.getUrl(Uri.parse(scriptUrl))
          .then((r) => r.close())
          .then((r) => r.transform(utf8.decoder).join());

      final apiMatch = RegExp(
        r'''fetch\s*\(\s*["']/api/([a-zA-Z0-9_]+)[^"']*["']\s*,\s*\{[^}]*method:\s*["']POST["']''',
        caseSensitive: false,
      ).firstMatch(scriptJs);
      if (apiMatch != null) _currentEndpoint = '/api/${apiMatch.group(1)}';
    }

    final initUrl = '$_baseUrl$_currentEndpoint/init?t=${DateTime.now().millisecondsSinceEpoch}';
    final initReq = await _client.getUrl(Uri.parse(initUrl));
    initReq.headers..set('Referer', _baseUrl)
      ..set('Origin', _baseUrl)
      ..set('Accept', 'application/json, text/javascript, */*; q=0.01');
    final initRes = await initReq.close();

    if (initRes.statusCode == 200) {
      final decoded = jsonDecode(await initRes.transform(utf8.decoder).join());
      if (decoded case {
        'token': final String token,
        'hpKey': final String hpKey,
        'hpVal': final String hpVal,
      }) {
        _authHeaders = {
          'Token': token,
          'Hpkey': hpKey,
          'Hpval': hpVal
        };
      }
    }
  }

  static Future<List<_HltbCandidate>> _searchGameCandidates(String gameName) async {
    final payload = <String, dynamic>{
      'searchType': 'games',
      'searchTerms': gameName.split(' '),
      'searchPage': 1,
      'size': 20,
      'searchOptions': {
        'games': {
          'userId': 0,
          'platform': '',
          'sortCategory': 'popular',
          'rangeCategory': 'main',
          'rangeTime': {'min': 0, 'max': 0},
          'gameplay': {'perspective': '', 'flow': '', 'genre': '', 'difficulty': ''},
          'rangeYear': {'min': '', 'max': ''},
          'modifier': '',
        },
        'users': {'sortCategory': 'postcount'},
        'lists': {'sortCategory': 'follows'},
        'filter': '',
        'sort': 0,
        'randomizer': 0,
      },
      'useCache': true,
    };

    if (_authHeaders != null) payload[_authHeaders!['Hpkey']!] = _authHeaders!['Hpval']!;

    final req = await _client.postUrl(Uri.parse('$_baseUrl$_currentEndpoint'));
    req.headers..set('Content-Type', 'application/json')
      ..set('Accept', 'application/json, text/javascript, */*; q=0.01')
      ..set('Referer', _baseUrl)
      ..set('Origin', _baseUrl);
    if (_authHeaders != null) {
      req.headers..set('x-auth-token', _authHeaders!['Token']!)
        ..set('x-hp-key', _authHeaders!['Hpkey']!)
        ..set('x-hp-val', _authHeaders!['Hpval']!);
    }

    req.write(jsonEncode(payload));
    final res = await req.close();

    if (res.statusCode != 200) return [];
    final jsonStr = await res.transform(utf8.decoder).join();
    if (jsonStr.trim().isEmpty) return [];

    final data = jsonDecode(jsonStr)['data'] as List?;
    if (data == null || data.isEmpty) return [];

    final targetNorm = _normalizeName(gameName);
    final candidates = <_HltbCandidate>[];

    for (final item in data) {
      final id = item['game_id']?.toString();
      if (id == null) continue;

      final itemName = _normalizeName(item['game_name']?.toString() ?? '');
      final score = switch (itemName) {
        _ when itemName == targetNorm => 100,
        _ when targetNorm.contains(itemName) || itemName.contains(targetNorm) => 50,
        _ => 10,
      };
      candidates.add(_HltbCandidate(id: id, score: score));
    }
    // Ordenar por similitud para priorizar la consulta de detalles en los más relevantes
    candidates.sort((a, b) => b.score.compareTo(a.score));
    return candidates;
  }

  static Future<HltbStats?> _fetchGameDetails(String gameId) async {
    final res = await (await _client.getUrl(Uri.parse('$_baseUrl/game?id=$gameId'))).close();
    final html = await res.transform(utf8.decoder).join();

    final scriptMatch = RegExp(r'<script[ ]?id="__NEXT_DATA__"[ ]?type="application/json">(.+?)<\/script>').firstMatch(html);
    if (scriptMatch == null) return null;
    final gameData = (jsonDecode(scriptMatch.group(1)!)?['props']?['pageProps']?['game']?['data']?['game'] as List?)?.firstOrNull as Map<String, dynamic>?;
    if (gameData == null) return null;

    double toHours(dynamic seconds) => seconds == null ? 0 : (seconds as num) / 3600.0;

    final aliases = (gameData['game_alias']?.toString() ?? '')
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();

    return HltbStats(
      id: gameId,
      steamId: gameData['profile_steam']?.toString(),
      name: gameData['game_name']?.toString() ?? '',
      aliases: aliases,
      mainStory: HltbTime(
        classic: toHours(gameData['comp_main']),
        average: toHours(gameData['comp_main_avg']),
        median: toHours(gameData['comp_main_med']),
        rushed: toHours(gameData['comp_main_l']),
        leisure: toHours(gameData['comp_main_h']),
      ),
      extras: HltbTime(
        classic: toHours(gameData['comp_plus']),
        average: toHours(gameData['comp_plus_avg']),
        median: toHours(gameData['comp_plus_med']),
        rushed: toHours(gameData['comp_plus_l']),
        leisure: toHours(gameData['comp_plus_h']),
      ),
      completionist: HltbTime(
        classic: toHours(gameData['comp_100']),
        average: toHours(gameData['comp_100_avg']),
        median: toHours(gameData['comp_100_med']),
        rushed: toHours(gameData['comp_100_l']),
        leisure: toHours(gameData['comp_100_h']),
      ),
      allPlayStyles: HltbTime(
        classic: toHours(gameData['comp_all']),
        average: toHours(gameData['comp_all_avg']),
        median: toHours(gameData['comp_all_med']),
        rushed: toHours(gameData['comp_all_l']),
        leisure: toHours(gameData['comp_all_h']),
      ),
    );
  }
}
