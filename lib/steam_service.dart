import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Motivo por el que una operación contra Steam no devolvió datos.
enum SteamFailure {
  badInput,
  notFound,
  network,
  badKey,
  needsKey,
  privateProfile,
  emptyLibrary,
  notLinked,
  busy,
}

/// Cuenta resuelta a partir de una URL de perfil, un nombre personalizado o un SteamID64.
class SteamAccount({required final String id64, final String? persona});

/// Entrada mínima de la biblioteca remota: el resto de metadatos los completa la cola de Steam.
typedef SteamOwnedGame = ({int appId, String? name});

/// Resultado sellado de cualquier consulta a Steam, para que el caller trate de forma
/// exhaustiva el éxito y el motivo exacto del fallo sin propagar `null`.
sealed class SteamResult<T> {
  const SteamResult();
}

final class SteamOk<T> extends SteamResult<T> {
  final T value;
  const SteamOk(this.value);
}

final class SteamFail<T> extends SteamResult<T> {
  final SteamFailure reason;
  const SteamFail(this.reason);
}

/// Acceso a la biblioteca vía Steam Web API. Todas las consultas exigen clave: con la de
/// la propia cuenta `GetOwnedGames` incluye ADEMÁS los juegos privados; contra un tercero
/// se limita a lo que ese perfil publique.
class SteamService {
  static const String _host = 'api.steampowered.com';

  static final HttpClient _client = .new()
    ..userAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  static final _id64Pattern = RegExp(r'^\d{17}$');

  static final _profileUrlPattern = RegExp(r'steamcommunity\.com/(profiles|id)/([^/?#\s]+)', caseSensitive: false);

  /// Clasifica la entrada libre del usuario en SteamID64 o nombre personalizado (vanity).
  static ({String? id64, String? vanity}) _parseProfileInput(String raw) {
    final input = raw.trim();
    if (input.isEmpty) return (id64: null, vanity: null);
    if (_id64Pattern.hasMatch(input)) return (id64: input, vanity: null);

    if (_profileUrlPattern.firstMatch(input) case final match?) {
      final segment = match.group(2)!;
      return match.group(1)!.toLowerCase() == 'profiles' && _id64Pattern.hasMatch(segment)
          ? (id64: segment, vanity: null)
          : (id64: null, vanity: segment);
    }
    // Una entrada suelta sin barras se trata como nombre personalizado del perfil.
    return input.contains('/') ? (id64: null, vanity: null) : (id64: null, vanity: input);
  }

  /// Llamada a la Web API que devuelve el objeto `response` ya decodificado. Centraliza
  /// la clasificación de fallos: los tres endpoints usados comparten esa envoltura.
  static Future<SteamResult<Map<String, dynamic>>> _call(String path, Map<String, String> params) async {
    final int status;
    final String body;
    try {
      final response = await (await _client.getUrl(Uri.https(_host, path, params))).close();
      status = response.statusCode;
      body = await response.transform(utf8.decoder).join();
    } catch (e) {
      debugPrint('Steam error de red [$path]: $e'); // sin query: contiene la API key
      return const SteamFail(SteamFailure.network);
    }

    if (status case 401 || 403) return const SteamFail(SteamFailure.badKey);
    if (status != 200) return const SteamFail(SteamFailure.network);
    try {
      if (jsonDecode(body) case {'response': final Map response}) {
        return SteamOk(Map<String, dynamic>.from(response));
      }
    } catch (_) {}
    return const SteamFail(SteamFailure.network);
  }

  /// Resuelve el perfil a su SteamID64 canónico y su nombre visible, validando de paso
  /// que la clave sirva antes de guardar nada.
  static Future<SteamResult<SteamAccount>> resolveAccount(String input, String? apiKey) async {
    final key = apiKey?.trim() ?? '';
    if (key.isEmpty) return const SteamFail(SteamFailure.needsKey);

    final (:id64, :vanity) = _parseProfileInput(input);
    if (id64 == null && vanity == null) return const SteamFail(SteamFailure.badInput);

    var resolvedId = id64;
    if (vanity != null) {
      switch (await _call('/ISteamUser/ResolveVanityURL/v1/', {'key': key, 'vanityurl': vanity})) {
        case SteamFail(:final reason):
          return SteamFail(reason);
        case SteamOk(:final value):
          // success == 42 cuando el nombre personalizado no corresponde a ningún perfil.
          if (value case {'success': 1, 'steamid': final String id}) {
            resolvedId = id;
          } else {
            return const SteamFail(SteamFailure.notFound);
          }
      }
    }

    switch (await _call('/ISteamUser/GetPlayerSummaries/v2/', {'key': key, 'steamids': resolvedId!})) {
      case SteamFail(:final reason):
        return SteamFail(reason);
      case SteamOk(:final value):
        if (value case {'players': [final Map player, ...]}) {
          return SteamOk(SteamAccount(id64: resolvedId, persona: player['personaname']?.toString()));
        }
        return const SteamFail(SteamFailure.notFound);
    }
  }

  /// Biblioteca de la cuenta. Una respuesta sin `games` significa que Steam aplicó la
  /// privacidad del perfil: la clave no pertenece a esa cuenta y sus juegos no son públicos.
  static Future<SteamResult<List<SteamOwnedGame>>> fetchOwnedGames(String id64, String? apiKey) async {
    final key = apiKey?.trim() ?? '';
    if (key.isEmpty) return const SteamFail(SteamFailure.needsKey);

    switch (await _call('/IPlayerService/GetOwnedGames/v1/', {
      'key': key,
      'steamid': id64,
      'include_appinfo': '1',
      'include_played_free_games': '1',
    })) {
      case SteamFail(:final reason):
        return SteamFail(reason);
      case SteamOk(:final value):
        if (value['games'] case final List rawGames) {
          final games = [
            for (final raw in rawGames.whereType<Map>())
              if (int.tryParse(raw['appid']?.toString() ?? '') case final appId?)
                // Algunos nombres llegan con espacios de sobra (" Wanba Warriors").
                (appId: appId, name: raw['name']?.toString().trim()),
          ];
          return games.isEmpty ? const SteamFail(SteamFailure.emptyLibrary) : SteamOk(games);
        }
        return const SteamFail(SteamFailure.privateProfile);
    }
  }
}
