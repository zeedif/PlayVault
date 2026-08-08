import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

class HltbTime {
  final int classic;
  final int average;
  final int median;
  final int rushed;
  final int leisure;

  const new({
    this.classic = 0,
    this.average = 0,
    this.median = 0,
    this.rushed = 0,
    this.leisure = 0,
  });

  factory fromJson(Map<String, dynamic> json) => HltbTime(
    classic: (json['classic'] as num?)?.toInt() ?? 0,
    average: (json['average'] as num?)?.toInt() ?? 0,
    median: (json['median'] as num?)?.toInt() ?? 0,
    rushed: (json['rushed'] as num?)?.toInt() ?? 0,
    leisure: (json['leisure'] as num?)?.toInt() ?? 0,
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
  final String? altSteamId,
  final String? name,
  final List<String> aliases = const [],
  final HltbTime mainStory = const HltbTime(),
  final HltbTime extras = const HltbTime(),
  final HltbTime completionist = const HltbTime(),
  final HltbTime allPlayStyles = const HltbTime(),
}) {
  /// Indica si la ficha declara algún appid de Steam. HLTB rellena los huecos con `'0'`,
  /// que no identifica a ningún juego.
  bool get hasSteamId =>
      (steamId != null && steamId != '0') || (altSteamId != null && altSteamId != '0');

  /// Compara [appId] con los appids de la ficha, incluido el alternativo que HLTB usa
  /// para reediciones y remasterizaciones que conservan una sola entrada.
  bool matchesSteamId(String? appId) =>
      appId != null && appId != '0' && (steamId == appId || altSteamId == appId);

  factory fromJson(Map<String, dynamic> json) => HltbStats(
    id: json['id'] as String?,
    steamId: json['steamId'] as String?,
    altSteamId: json['altSteamId'] as String?,
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
    if (altSteamId != null) 'altSteamId': altSteamId,
    'name': name,
    'aliases': aliases,
    'mainStory': mainStory.toJson(),
    'extras': extras.toJson(),
    'completionist': completionist.toJson(),
    'allPlayStyles': allPlayStyles.toJson(),
  };
}

/// Resultado de búsqueda con los metadatos que HLTB devuelve junto al id: bastan para
/// ordenar y descartar sin abrir la ficha de cada uno.
typedef _HltbSearchHit = ({
  String id,
  String name,
  List<String> aliases,
  String type,
  int year,
  int popularity,
});

class _HltbCandidate({required final String id, required final int score});

class HltbService {
  static const String _baseUrl = 'https://howlongtobeat.com';
  static String _currentEndpoint = '/api/bleed';
  static Map<String, String>? _authHeaders;
  static bool _endpointResolved = false;
  static DateTime _authExpiry = DateTime.fromMillisecondsSinceEpoch(0);

  /// El token de `init` caduca en el servidor; se renueva antes de que expire en vez de
  /// esperar a que las búsquedas empiecen a devolver vacío.
  static const Duration _authTtl = Duration(minutes: 30);

  /// Ritmo sostenido de peticiones. Por debajo de esto HLTB responde con normalidad;
  /// la ráfaga cubre el arranque (endpoint + token + primera búsqueda) sin espera.
  static const double _tokensPerSecond = 2;
  static const double _burstCapacity = 3;

  /// Fichas de detalle que se abren como máximo por juego. Acota el gasto cuando el
  /// nombre no coincide con nada: sin tope, un solo título recorría los 20 resultados.
  static const int _maxDetailProbes = 10;

  static double _tokens = _burstCapacity;
  static DateTime _lastRefill = DateTime.now();
  static DateTime _cooldownUntil = DateTime.fromMillisecondsSinceEpoch(0);
  static Future<void> _pacingChain = Future.value();

  // Resultados de búsqueda por consulta normalizada. Solo alimentan el orden de visita
  // (los tiempos siempre salen de la ficha recién descargada), así que no caducan:
  // varios juegos de la misma franquicia colapsan en una única petición.
  static final Map<String, List<_HltbSearchHit>> _searchCache = {};

  static final HttpClient _client = .new()
    ..userAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  // Las comillas y guiones tipográficos se pliegan a su equivalente ASCII junto a los
  // diacríticos: son la forma no ASCII más habitual en los nombres de la tienda.
  static final _diacriticMap = Map.fromIterables(
    'ÀÁÂÃÄÅàáâãäåÒÓÔÕÖØòóôõöøÈÉÊËèéêëÇçÌÍÎÏìíîïÙÚÛÜùúûüÑñŌō’‘“”–—'.runes,
    'AAAAAAaaaaaaOOOOOOooooooEEEEeeeeCcIIIIiiiiUUUUuuuuNnOo\'\'""--'.runes,
  );

  static final _nonAscii = RegExp(r'[^\x20-\x7E]');

  static final _nonAlnum = RegExp(r'[^a-z0-9]+');

  static final _letterDigitBoundary = RegExp(r'(?<=[a-z])(?=[0-9])|(?<=[0-9])(?=[a-z])');

  static final _whitespaceRun = RegExp(r'\s+');

  static final _yearTag = RegExp(r'[\(\[]((?:19|20)\d{2})[\)\]]');

  static final _alternateTitle = RegExp(r'\s*/\s*[^:/]*(?=:)');

  static final _leadingTitle = RegExp(r'^[^/]*/\s*');

  static final _edgePunctuation = RegExp(r'(?<=^|\s)[^\w\s]+|[^\w\s]+(?=\s|$)');

  /// Tipos de ficha que nunca corresponden a una entrada de la biblioteca: el appid
  /// apunta al juego, no a su contenido descargable ni a un mod.
  static const Set<String> _secondaryTypes = {'dlc', 'mod'};

  // Público para que HomeCubit lo reutilice sin duplicar el mapa en memoria.
  static String removeDiacritics(String text) =>
      String.fromCharCodes(text.runes.map((r) => _diacriticMap[r] ?? r)).toLowerCase();

  /// Deja la consulta en ASCII conservando la puntuación: un solo carácter fuera de
  /// ASCII deja la búsqueda en cero, y los símbolos de marca que Steam añade al título
  /// ("Dead Space™ 3") son el caso frecuente. Lo que NO se toca son los signos internos,
  /// porque son los que acotan el resultado: "f.e.a.r." devuelve 9 fichas y "fear" 140.
  static String _searchQuery(String input) => removeDiacritics(input)
      .replaceAll(_nonAscii, '')
      .replaceAll(_whitespaceRun, ' ')
      .trim();

  /// Clave compacta para comparar nombres: todo lo que no sea alfanumérico fuera, de
  /// modo que dos variantes que solo difieren en espacios, signos o un número pegado
  /// colapsan a la misma clave (p. ej. "Re;Birth3 V" ≡ "Re;Birth 3: V").
  static String nameKey(String? input) =>
      removeDiacritics(input ?? '').replaceAll(_nonAlnum, '');

  /// Claves con las que se acepta una ficha como coincidencia exacta del nombre:
  /// el título sin el año que añade Steam y, en los lanzamientos con doble título,
  /// cada mitad por separado, porque HLTB registra una como nombre y la otra como alias
  /// ("FATAL FRAME / PROJECT ZERO: Mask of the Lunar Eclipse" está catalogado como
  /// "Fatal Frame: Mask of the Lunar Eclipse" con "Project Zero: …" de alias).
  static Set<String> _targetKeys(String rawName) {
    final base = rawName.replaceAll(_yearTag, ' ');
    final keys = {nameKey(base)};
    if (_alternateTitle.hasMatch(base)) {
      keys..add(nameKey(base.replaceAll(_alternateTitle, '')))
        ..add(nameKey(base.replaceFirst(_leadingTitle, '')));
    }
    return keys..remove('');
  }

  /// Genera consultas para HLTB, de la más literal a la más laxa y sin duplicados.
  /// Cada paso RETIRA algo del título, nunca lo trocea: el buscador de HLTB casa por
  /// término, así que partir los signos multiplica los resultados y hunde la ficha
  /// buscada fuera de las 20 que devuelve la página.
  static List<String> _buildSearchVariants(String rawName) {
    final variants = <String>[];
    void add(String candidate) {
      final query = _searchQuery(candidate);
      if (query.isNotEmpty && !variants.contains(query)) variants.add(query);
    }

    // 1. El título tal cual. Lo habitual es que HLTB lo resuelva con la puntuación
    //    puesta: "STEINS;GATE", "s.p.l.i.t" o "9-nine-:Episode 1" aciertan de una.
    add(rawName);

    // 2. Con el número despegado de la letra, lo único que fallaba en la forma literal:
    //    "Re;Birth2: Sisters Generation" no devuelve nada y "Re;Birth 2: …" sí.
    final spacedDigits = rawName.replaceAllMapped(_letterDigitBoundary, (_) => ' ');
    add(spacedDigits);

    // 3. Sin tags entre paréntesis/corchetes: "Alone in the Dark (2008)" no devuelve
    //    nada hasta quitarle el año.
    final noTags = spacedDigits.replaceAll(RegExp(r'[\(\[][^\)\]]*[\)\]]'), ' ');
    add(noTags);

    // 4. Sin el título alternativo que precede al subtítulo, la convención de los
    //    lanzamientos japoneses con doble nombre: HLTB solo cataloga uno de los dos.
    //    "FATAL FRAME / PROJECT ZERO: Mask of the Lunar Eclipse" → "FATAL FRAME: Mask…".
    add(noTags.replaceAll(_alternateTitle, ''));

    // 5. Sin la puntuación decorativa, la que toca un espacio o un extremo. Solo cae el
    //    adorno de la tienda ("Syberia - Remastered", "-HD … ReMIX-"); la puntuación
    //    interna de "f.e.a.r." o "STEINS;GATE" queda intacta y sigue acotando igual.
    add(noTags.replaceAll(_edgePunctuation, ' '));

    // Descartados por imprecisos, no por inútiles: ambos amplían tanto el resultado que
    // la ficha correcta se cae de la primera página.
    //   Tokenizar los signos: "s.p.l.i.t" pasa de 1 ficha a 8030, "S.T.A.L.K.E.R." de
    //   10 a 4682 encabezadas por Resident Evil 2.
    // add(noTags.replaceAll(RegExp(r'[^a-z0-9\s]+'), ' '));
    //   Recortar en el primer ':' o ' - ' para quedarse con el título base: las sagas
    //   largas comparten base y un título con dos guiones se recorta por donde no toca.
    // add(noTags.split(RegExp(r':|\s-\s')).first);

    return variants;
  }

  static Future<HltbStats?> fetchGameStats(String? gameName, String? knownId, String? steamId, bool isRefetch) async {
    try {
      await _initializeAuth();
      final rawName = gameName ?? '';
      // El año que Steam añade entre paréntesis no forma parte del nombre en HLTB, así que
      // se saca de la clave y pasa a ordenar candidatos: sin esto "Resident Evil 4 (2005)"
      // no coincidía exactamente con ninguna ficha.
      final wantedYear = int.tryParse(_yearTag.firstMatch(rawName)?.group(1) ?? '') ?? 0;
      final targetKeys = _targetKeys(rawName);

      bool isExactNameMatch(HltbStats s) =>
          targetKeys.contains(nameKey(s.name)) || s.aliases.any((a) => targetKeys.contains(nameKey(a)));

      // Si ya conocemos el ID, lo consultamos directamente
      if (knownId != null) {
        final stats = await _fetchGameDetails(knownId);
        // Si el ID conocido devolvió null (por caída de red, etc.),
        // devolver null para conservar el ID y estadísticas previas.
        if (stats == null) return null;
        // Si NO es un refetch (ej. importación o carga), asumimos que el ID es correcto y terminamos.
        if (!isRefetch) return stats;

        // Si ES un refetch, validamos rigurosamente para ver si este ID sigue siendo nuestro mejor candidato
        final isSteamMismatch = steamId != null && stats.hasSteamId && !stats.matchesSteamId(steamId);
        if (!isSteamMismatch || isExactNameMatch(stats)) return stats;
        // Si resultó NO ser válido, dejamos que el código proceda al flujo normal de búsqueda más abajo.
      }

      // De lo contrario, buscamos los IDs candidatos ordenados por relevancia.
      // Se prueban variantes de título progresivamente más laxas hasta que una devuelva
      // candidatos: así un tag entre paréntesis o un subtítulo no dejan la búsqueda en cero.
      List<_HltbCandidate> candidates = const [];
      for (final variant in _buildSearchVariants(rawName)) {
        candidates = _rankHits(await _searchHits(variant), nameKey(variant), targetKeys, wantedYear);
        if (candidates.isNotEmpty) break;
      }
      if (candidates.isEmpty) return null;

      HltbStats? exactNameFallback;

      for (final candidate in candidates.take(_maxDetailProbes)) {
        final stats = await _fetchGameDetails(candidate.id);
        if (stats == null) continue;

        // 1. Prioridad absoluta: Coincidencia exacta de Steam ID.
        if (stats.matchesSteamId(steamId)) return stats;

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

  /// Espera el turno de una petición: cumple el enfriamiento que pidió un 429 y consume
  /// un token del cubo. Todo acceso a HLTB pasa por aquí, así que el ritmo se mantiene
  /// aunque la cola encole cientos de juegos de golpe.
  static Future<void> _throttle() {
    final turn = _pacingChain.then((_) async {
      if (_cooldownUntil.difference(DateTime.now()) case final pending when pending > Duration.zero) {
        await Future.delayed(pending);
      }

      final now = DateTime.now();
      _tokens = (_tokens + now.difference(_lastRefill).inMilliseconds / 1000 * _tokensPerSecond)
          .clamp(0, _burstCapacity);
      _lastRefill = now;

      if (_tokens < 1) {
        await Future.delayed(Duration(milliseconds: ((1 - _tokens) / _tokensPerSecond * 1000).ceil()));
        _tokens = 1;
      }
      _tokens -= 1;
    });
    // La cadena solo serializa el turno: un fallo aguas arriba no debe romper el pacing.
    _pacingChain = turn.catchError((_) {});
    return turn;
  }

  /// Clasifica la respuesta y devuelve el cuerpo, o null si no es aprovechable:
  /// un 429/503 aparca las siguientes peticiones el tiempo que indique `Retry-After`
  /// y un 401/403 invalida el token para que la siguiente llamada lo renueve.
  static Future<String?> _read(HttpClientResponse res) async {
    switch (res.statusCode) {
      case 200:
        final body = await res.transform(utf8.decoder).join();
        return body.trim().isEmpty ? null : body;
      case 429 || 503:
        final retryAfter = int.tryParse(res.headers.value('retry-after') ?? '');
        _cooldownUntil = DateTime.now().add(Duration(seconds: retryAfter?.clamp(1, 300) ?? 30));
        debugPrint('HLTB limitó el ritmo (${res.statusCode}): en pausa hasta $_cooldownUntil');
      case 401 || 403:
        _authHeaders = null;
    }
    await res.drain();
    return null;
  }

  static Future<String?> _get(Uri uri, [Map<String, String> headers = const {}]) async {
    await _throttle();
    final req = await _client.getUrl(uri);
    headers.forEach(req.headers.set);
    return _read(await req.close());
  }

  static Future<String?> _post(Uri uri, String payload, Map<String, String> headers) async {
    await _throttle();
    final req = await _client.postUrl(uri);
    headers.forEach(req.headers.set);
    // `write` codifica en Latin-1 y revienta con cualquier carácter fuera de ese rango.
    req.add(utf8.encode(payload));
    return _read(await req.close());
  }

  static Future<void> _initializeAuth() async {
    if (_authHeaders != null && DateTime.now().isBefore(_authExpiry)) return;
    // El endpoint solo se busca una vez por ejecución: renovar el token no lo cambia.
    if (!_endpointResolved) await _resolveEndpoint();

    final initUrl = '$_baseUrl$_currentEndpoint/init?t=${DateTime.now().millisecondsSinceEpoch}';
    final body = await _get(Uri.parse(initUrl), {
      'Referer': _baseUrl,
      'Origin': _baseUrl,
      'Accept': 'application/json, text/javascript, */*; q=0.01',
    });
    if (body == null) return;

    if (jsonDecode(body) case {
      'token': final String token,
      'hpKey': final String hpKey,
      'hpVal': final String hpVal,
    }) {
      _authHeaders = {'Token': token, 'Hpkey': hpKey, 'Hpval': hpVal};
      _authExpiry = DateTime.now().add(_authTtl);
    }
  }

  /// Extrae el endpoint de la API desde el JS del bundle de Next.js. Si la home responde
  /// pero el patrón no aparece, se queda con el valor por defecto y no vuelve a intentarlo.
  static Future<void> _resolveEndpoint() async {
    final homeHtml = await _get(Uri.parse(_baseUrl));
    if (homeHtml == null) return;
    _endpointResolved = true;

    if (RegExp(r'src="([^"]+_app-[^"]+\.js)"').firstMatch(homeHtml) case final scriptMatch?) {
      final scriptJs = await _get(Uri.parse('$_baseUrl${scriptMatch.group(1)}'));
      if (scriptJs == null) return;

      final apiMatch = RegExp(
        r'''fetch\s*\(\s*["']/api/([a-zA-Z0-9_]+)[^"']*["']\s*,\s*\{[^}]*method:\s*["']POST["']''',
        caseSensitive: false,
      ).firstMatch(scriptJs);
      if (apiMatch != null) _currentEndpoint = '/api/${apiMatch.group(1)}';
    }
  }

  /// [query] debe venir ya pasado por [_searchQuery]
  static Future<List<_HltbSearchHit>> _searchHits(String query) async {
    if (_searchCache[query] case final cached?) return cached;

    var body = await _postSearch(query);
    // Un token caducado se manifiesta como 401/403 (que ya lo invalidó) o como cuerpo
    // vacío: se renueva y se reintenta una vez. En enfriamiento no se reintenta, para
    // no gastar el turno siguiente en la misma petición que acaba de ser rechazada.
    if (body == null && DateTime.now().isAfter(_cooldownUntil)) {
      _authHeaders = null;
      await _initializeAuth();
      body = await _postSearch(query);
    }
    if (body == null) return const [];

    final data = jsonDecode(body)['data'] as List?;
    if (data == null) return const [];

    final hits = <_HltbSearchHit>[
      for (final item in data.whereType<Map>())
        if (item['game_id']?.toString() case final id? when id.isNotEmpty)
          (
            id: id,
            name: item['game_name']?.toString() ?? '',
            aliases: _splitAliases(item['game_alias']),
            type: item['game_type']?.toString().toLowerCase() ?? '',
            year: (item['release_world'] as num?)?.toInt() ?? 0,
            popularity: (item['count_comp'] as num?)?.toInt() ?? 0,
          ),
    ];
    _searchCache[query] = hits;
    return hits;
  }

  static Future<String?> _postSearch(String query) {
    final payload = <String, dynamic>{
      'searchType': 'games',
      'searchTerms': query.split(' ').where((t) => t.isNotEmpty).toList(),
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

    final headers = {
      'Content-Type': 'application/json; charset=utf-8',
      'Accept': 'application/json, text/javascript, */*; q=0.01',
      'Referer': _baseUrl,
      'Origin': _baseUrl,
    };

    if (_authHeaders case final auth?) {
      payload[auth['Hpkey']!] = auth['Hpval']!;
      headers.addAll({
        'x-auth-token': auth['Token']!,
        'x-hp-key': auth['Hpkey']!,
        'x-hp-val': auth['Hpval']!,
      });
    }

    return _post(Uri.parse('$_baseUrl$_currentEndpoint'), jsonEncode(payload), headers);
  }

  /// Ordena los resultados por probabilidad de ser la ficha buscada y aparta los DLC
  /// cuando hay alguna entrada principal. Solo decide el ORDEN y el recorte: la
  /// aceptación final la resuelve [fetchGameStats] contra la ficha ya descargada,
  /// así que priorizar mal cuesta peticiones, nunca precisión.
  static List<_HltbCandidate> _rankHits(
    List<_HltbSearchHit> hits,
    String queryKey,
    Set<String> targetKeys,
    int wantedYear,
  ) {
    // Recopilatorios y entradas multijuego SÍ son fichas válidas de biblioteca
    // (".hack//G.U. Last Recode" o "Kingdom Hearts HD 1.5+2.5 ReMIX" son `compil`),
    // así que solo se aparta lo secundario, y únicamente si queda algo con lo que buscar.
    final primary = hits.where((h) => !_secondaryTypes.contains(h.type));
    final pool = primary.isEmpty ? hits : primary;

    return [
      for (final hit in pool)
        _HltbCandidate(id: hit.id, score: _scoreHit(hit, queryKey, targetKeys, wantedYear)),
    ]..sort((a, b) => b.score.compareTo(a.score));
  }

  static int _scoreHit(_HltbSearchHit hit, String queryKey, Set<String> targetKeys, int wantedYear) {
    final hitKey = nameKey(hit.name);
    var score = switch (hit) {
      _ when targetKeys.contains(hitKey) ||
          hit.aliases.any((a) => targetKeys.contains(nameKey(a))) => 400,
      _ when queryKey.isEmpty || hitKey.isEmpty => 0,
      _ when hitKey == queryKey => 300,
      _ when queryKey.contains(hitKey) || hitKey.contains(queryKey) => 100,
      _ => 0,
    };
    // El año entre paréntesis del título es lo único que separa una reedición de su
    // original ("Resident Evil 4 (2005)" frente al remake de 2023).
    if (wantedYear != 0 && hit.year == wantedYear) score += 200;
    // A igualdad, primero la ficha con más partidas registradas: es la canónica.
    return score * 1000 + hit.popularity.clamp(0, 999);
  }

  static List<String> _splitAliases(dynamic raw) => (raw?.toString() ?? '')
      .split(',')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();

  static Future<HltbStats?> _fetchGameDetails(String gameId) async {
    final html = await _get(Uri.parse('$_baseUrl/game?id=$gameId'));
    if (html == null) return null;

    final scriptMatch = RegExp(r'<script[ ]?id="__NEXT_DATA__"[ ]?type="application/json">(.+?)<\/script>').firstMatch(html);
    if (scriptMatch == null) return null;
    final gameData = (jsonDecode(scriptMatch.group(1)!)?['props']?['pageProps']?['game']?['data']?['game'] as List?)?.firstOrNull as Map<String, dynamic>?;
    if (gameData == null) return null;

    int toMin(dynamic seconds) => seconds == null ? 0 : (seconds as num).toInt() ~/ 60;

    return HltbStats(
      id: gameId,
      steamId: gameData['profile_steam']?.toString(),
      altSteamId: gameData['profile_steam_alt']?.toString(),
      name: gameData['game_name']?.toString() ?? '',
      aliases: _splitAliases(gameData['game_alias']),
      mainStory: HltbTime(
        classic: toMin(gameData['comp_main']),
        average: toMin(gameData['comp_main_avg']),
        median: toMin(gameData['comp_main_med']),
        rushed: toMin(gameData['comp_main_l']),
        leisure: toMin(gameData['comp_main_h']),
      ),
      extras: HltbTime(
        classic: toMin(gameData['comp_plus']),
        average: toMin(gameData['comp_plus_avg']),
        median: toMin(gameData['comp_plus_med']),
        rushed: toMin(gameData['comp_plus_l']),
        leisure: toMin(gameData['comp_plus_h']),
      ),
      completionist: HltbTime(
        classic: toMin(gameData['comp_100']),
        average: toMin(gameData['comp_100_avg']),
        median: toMin(gameData['comp_100_med']),
        rushed: toMin(gameData['comp_100_l']),
        leisure: toMin(gameData['comp_100_h']),
      ),
      allPlayStyles: HltbTime(
        classic: toMin(gameData['comp_all']),
        average: toMin(gameData['comp_all_avg']),
        median: toMin(gameData['comp_all_med']),
        rushed: toMin(gameData['comp_all_l']),
        leisure: toMin(gameData['comp_all_h']),
      ),
    );
  }
}
