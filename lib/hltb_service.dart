import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

class HltbTime {
  final double classic;
  final double average;
  final double median;
  final double rushed;
  final double leisure;

  const HltbTime({
    this.classic = 0,
    this.average = 0,
    this.median = 0,
    this.rushed = 0,
    this.leisure = 0,
  });

  factory HltbTime.fromJson(Map<String, dynamic> json) => HltbTime(
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

class HltbStats {
  final String? id;
  final String? steamId;
  final String? name;
  final List<String> aliases;
  final HltbTime mainStory;
  final HltbTime extras;
  final HltbTime completionist;
  final HltbTime allPlayStyles;

  const HltbStats({
    this.id,
    this.steamId,
    this.name,
    this.aliases = const [],
    this.mainStory = const HltbTime(),
    this.extras = const HltbTime(),
    this.completionist = const HltbTime(),
    this.allPlayStyles = const HltbTime(),
  });

  factory HltbStats.fromJson(Map<String, dynamic> json) => HltbStats(
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

class _HltbCandidate {
  final String id;
  final int score;

  _HltbCandidate({required this.id, required this.score});
}

class HltbService {
  static const String _baseUrl = 'https://howlongtobeat.com';
  static String _currentEndpoint = '/api/bleed';
  static String? _authToken;
  static Map<String, String>? _authHeaders;

  static final HttpClient _client = HttpClient()
    ..userAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  static Future<HltbStats?> fetchGameStats(String? gameName, String? knownId, String? steamId, bool isRefetch) async {
    try {
      await _initializeAuth();

      final targetNorm = _normalizeName(gameName ?? '');

      // Si ya conocemos el ID, lo consultamos directamente
      if (knownId != null) {
        final stats = await _fetchGameDetails(knownId);
        if (stats != null) {
          if (!isRefetch) {
            // Si NO es un refetch (ej. importación o carga), asumimos que el ID es correcto y terminamos.
            return stats;
          } else {
            // Si ES un refetch, validamos rigurosamente para ver si este ID sigue siendo nuestro mejor candidato
            bool isExactNameMatch = _normalizeName(stats.name ?? '') == targetNorm || 
                                    stats.aliases.any((alias) => _normalizeName(alias) == targetNorm);
            
            bool isSteamMismatch = steamId != null && stats.steamId != null && stats.steamId != "0" && stats.steamId != steamId;
            
            // Si sigue siendo válido, lo devolvemos
            if (!(isSteamMismatch && !isExactNameMatch)) {
              return stats;
            }
            // Si resultó NO ser válido, dejamos que el código proceda al flujo normal de búsqueda más abajo.
          }
        } else {
          // Si el ID conocido devolvió null (por caída de red, etc.),
          // devolver null para conservar el ID y estadísticas previas.
          return null;
        }
      }

      // De lo contrario, buscamos los IDs candidatos ordenados por relevancia base
      final candidates = await _searchGameCandidates(targetNorm);
      if (candidates.isEmpty) return null;

      HltbStats? exactNameFallback;

      for (final candidate in candidates) {
        await Future.delayed(const Duration(milliseconds: 800));
        
        final stats = await _fetchGameDetails(candidate.id);
        if (stats == null) continue;

        bool isSteamMatch = steamId != null && stats.steamId == steamId;
        bool isExactNameMatch = _normalizeName(stats.name ?? '') == targetNorm || 
                                stats.aliases.any((alias) => _normalizeName(alias) == targetNorm);

        // 1. Prioridad absoluta: Coincidencia exacta de Steam ID
        if (isSteamMatch) {
          return stats;
        }

        // 2. Reserva por coincidencia exacta de nombre
        if (isExactNameMatch) {
          if (steamId == null) {
            // Si no estamos buscando por Steam ID, el primer nombre exacto es nuestra mejor opción.
            return stats;
          } else {
            // Si estamos buscando por Steam ID, reservamos esta coincidencia de nombre exacta por si
            // ninguno de los siguientes candidatos tiene el Steam ID buscado.
            exactNameFallback ??= stats;
          }
        }
        
        // 3. Si no hay coincidencia de Steam ID ni de nombre exacto, simplemente continuamos iterando.
      }

      // Retorna el fallback si hubo coincidencia exacta de nombre, o null si todo falló.
      return exactNameFallback;
    } catch (e) {
      debugPrint("HLTB Error: $e");
      return null;
    }
  }

  static Future<void> _initializeAuth() async {
    if (_authHeaders != null) return;

    final homeReq = await _client.getUrl(Uri.parse(_baseUrl));
    final homeRes = await homeReq.close();
    final homeHtml = await homeRes.transform(utf8.decoder).join();

    final scriptMatch = RegExp(r'src="([^"]+_app-[^"]+\.js)"').firstMatch(homeHtml);
    if (scriptMatch != null) {
      final scriptUrl = '$_baseUrl${scriptMatch.group(1)}';
      final scriptReq = await _client.getUrl(Uri.parse(scriptUrl));
      final scriptRes = await scriptReq.close();
      final scriptJs = await scriptRes.transform(utf8.decoder).join();

      final apiMatch = RegExp(
        r'''fetch\s*\(\s*["']/api/([a-zA-Z0-9_]+)[^"']*["']\s*,\s*\{[^}]*method:\s*["']POST["']''',
        caseSensitive: false,
      ).firstMatch(scriptJs);
      if (apiMatch != null) {
        _currentEndpoint = '/api/${apiMatch.group(1)}';
      }
    }

    final initUrl = '$_baseUrl$_currentEndpoint/init?t=${DateTime.now().millisecondsSinceEpoch}';
    final initReq = await _client.getUrl(Uri.parse(initUrl));
    initReq.headers.set('Referer', _baseUrl);
    initReq.headers.set('Origin', _baseUrl);
    initReq.headers.set('Accept', 'application/json, text/javascript, */*; q=0.01');
    final initRes = await initReq.close();

    if (initRes.statusCode == 200) {
      final json = jsonDecode(await initRes.transform(utf8.decoder).join());
      if (json['token'] != null && json['hpKey'] != null && json['hpVal'] != null) {
        _authToken = json['token'];
        _authHeaders = {
          'Token': _authToken!,
          'Hpkey': json['hpKey'],
          'Hpval': json['hpVal']
        };
      }
    }
  }

  static String _removeDiacritics(String text) {
    const withDia = 'ÀÁÂÃÄÅàáâãäåÒÓÔÕÖØòóôõöøÈÉÊËèéêëÇçÌÍÎÏìíîïÙÚÛÜùúûüÑñŌō';
    const withoutDia = 'AAAAAAaaaaaaOOOOOOooooooEEEEeeeeCcIIIIiiiiUUUUuuuuNnOo';
    String result = text;
    for (int i = 0; i < withDia.length; i++) {
      result = result.replaceAll(withDia[i], withoutDia[i]);
    }
    return result;
  }

  static String _normalizeName(String input) {
    return _removeDiacritics(input)
        .toLowerCase()
        .replaceAll(RegExp(r'-'), ' ')
        .replaceAll(RegExp(r'[^a-z0-9\s]'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  static Future<List<_HltbCandidate>> _searchGameCandidates(String gameName) async {
    final searchUrl = '$_baseUrl$_currentEndpoint';
    final payload = <String, dynamic>{
      "searchType": "games",
      "searchTerms": gameName.split(' '),
      "searchPage": 1,
      "size": 20,
      "searchOptions": {
        "games": {
          "userId": 0,
          "platform": "",
          "sortCategory": "popular",
          "rangeCategory": "main",
          "rangeTime": {"min": 0, "max": 0},
          "gameplay": {"perspective": "", "flow": "", "genre": "", "difficulty": ""},
          "rangeYear": {"min": "", "max": ""},
          "modifier": ""
        },
        "users": {"sortCategory": "postcount"},
        "lists": {"sortCategory": "follows"},
        "filter": "",
        "sort": 0,
        "randomizer": 0
      },
      "useCache": true
    };

    if (_authHeaders != null) {
      payload[_authHeaders!['Hpkey']!] = _authHeaders!['Hpval']!;
    }

    final req = await _client.postUrl(Uri.parse(searchUrl));
    req.headers.set('Content-Type', 'application/json');
    req.headers.set('Accept', 'application/json, text/javascript, */*; q=0.01');
    req.headers.set('Referer', _baseUrl);
    req.headers.set('Origin', _baseUrl);

    if (_authHeaders != null) {
      req.headers.set('x-auth-token', _authHeaders!['Token']!);
      req.headers.set('x-hp-key', _authHeaders!['Hpkey']!);
      req.headers.set('x-hp-val', _authHeaders!['Hpval']!);
    }

    req.write(jsonEncode(payload));
    final res = await req.close();

    if (res.statusCode == 200) {
      final jsonStr = await res.transform(utf8.decoder).join();
      if (jsonStr.trim().isEmpty) return [];

      final json = jsonDecode(jsonStr);
      final data = json['data'] as List?;
      if (data != null && data.isNotEmpty) {
        final targetNorm = _normalizeName(gameName);
        final List<_HltbCandidate> scoredCandidates = [];

        for (var item in data) {
          final id = item['game_id']?.toString();
          if (id == null) continue;

          final itemName = _normalizeName(item['game_name']?.toString() ?? '');
          
          int score = 0;
          if (itemName == targetNorm) {
            score = 100;
          } else if (targetNorm.contains(itemName) || itemName.contains(targetNorm)) {
            score = 50;
          } else {
            score = 10;
          }

          scoredCandidates.add(_HltbCandidate(id: id, score: score));
        }

        // Ordenar por similitud para priorizar la consulta de detalles en los más relevantes
        scoredCandidates.sort((a, b) => b.score.compareTo(a.score));
        return scoredCandidates;
      }
    }
    return [];
  }

  static Future<HltbStats?> _fetchGameDetails(String gameId) async {
    final req = await _client.getUrl(Uri.parse('$_baseUrl/game?id=$gameId'));
    final res = await req.close();
    final html = await res.transform(utf8.decoder).join();

    final nextDataMatch = RegExp(r'<script[ ]?id=\"__NEXT_DATA__\"[ ]?type=\"application\/json\">(.+?)<\/script>').firstMatch(html);
    if (nextDataMatch != null) {
      final json = jsonDecode(nextDataMatch.group(1)!);
      final gameData = json['props']?['pageProps']?['game']?['data']?['game']?[0];
      if (gameData != null) {
        double toHours(dynamic seconds) => seconds == null ? 0 : (seconds / 3600.0);

        final String aliasesStr = gameData['game_alias']?.toString() ?? '';
        final List<String> aliases = aliasesStr
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
    return null;
  }
}
