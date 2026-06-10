import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'http_client_adapter.dart';

class IOHttpClientAdapter implements HttpClientAdapter {
  static final HttpClient _sharedHttpClient = HttpClient()
    ..maxConnectionsPerHost = 1000000;

  /// Cache of source-bound HttpClients keyed by IP address string.
  /// All adapters with the same sourceAddress share one HttpClient.
  static final Map<String, HttpClient> _sourceBoundClients = {};

  final HttpClient _httpClient;
  final InternetAddress? sourceAddress;

  IOHttpClientAdapter({HttpClient? httpClient, this.sourceAddress})
      : _httpClient = httpClient ??
            (sourceAddress != null
                ? _getOrCreateSourceBoundHttpClient(sourceAddress)
                : _sharedHttpClient);

  static HttpClient _getOrCreateSourceBoundHttpClient(
      InternetAddress sourceAddr) {
    final key = sourceAddr.address;
    return _sourceBoundClients.putIfAbsent(key, () {
      print('[IOHttpClientAdapter] Creating source-bound HttpClient for $key');
      return HttpClient()
        ..maxConnectionsPerHost = 1000000
        ..connectionFactory = (Uri uri, String? proxyHost, int? proxyPort) {
          final host = proxyHost ?? uri.host;
          final port = proxyPort ?? uri.port;
          return Socket.startConnect(
            host,
            port,
            sourceAddress: sourceAddr,
          );
        };
    });
  }

  @override
  Future<WebSocket> connect(String uri, {Map<String, dynamic>? headers}) {
    final parsed = Uri.parse(uri);
    final isSecure = parsed.isScheme('wss') || parsed.isScheme('https');
    // HttpClient.connectionFactory cannot return a TLS-secured socket: when a
    // custom factory is set, HttpClient uses the returned socket as-is and
    // does NOT upgrade it to TLS, and ConnectionTask (the required return
    // type) is a final class we cannot construct around a SecureSocket. So a
    // source-bound wss:// connection through the factory hands the server a
    // plain TCP socket on :443 and the TLS handshake never completes
    // (connectError). Plain ws:// is unaffected and keeps the factory path.
    //
    // For source-bound wss:// we therefore connect a source-bound TCP socket,
    // upgrade it to TLS ourselves, do the WebSocket opening handshake, and
    // hand the secured socket to WebSocket.fromUpgradedSocket.
    if (sourceAddress != null && isSecure) {
      return _connectSecureSourceBound(parsed, headers);
    }
    return WebSocket.connect(
      uri,
      headers: headers,
      customClient: _httpClient,
    );
  }

  Future<WebSocket> _connectSecureSourceBound(
      Uri uri, Map<String, dynamic>? headers) async {
    final host = uri.host;
    final port = uri.hasPort ? uri.port : 443;

    // 1. Source-bound plain TCP connect.
    final task = await Socket.startConnect(host, port,
        sourceAddress: sourceAddress);
    final Socket rawSocket = await task.socket;

    // 2. TLS upgrade (SNI/cert host = uri.host).
    final SecureSocket secure;
    try {
      secure = await SecureSocket.secure(rawSocket, host: host);
    } catch (e) {
      rawSocket.destroy();
      rethrow;
    }

    // 3. WebSocket opening handshake (RFC 6455).
    final nonceBytes = Uint8List(16);
    final rnd = Random.secure();
    for (var i = 0; i < 16; i++) {
      nonceBytes[i] = rnd.nextInt(256);
    }
    final nonce = base64.encode(nonceBytes);

    final path =
        '${uri.path.isEmpty ? '/' : uri.path}${uri.hasQuery ? '?${uri.query}' : ''}';
    final hostHeader = (port == 443) ? host : '$host:$port';
    final req = StringBuffer()
      ..write('GET $path HTTP/1.1\r\n')
      ..write('Host: $hostHeader\r\n')
      ..write('Upgrade: websocket\r\n')
      ..write('Connection: Upgrade\r\n')
      ..write('Sec-WebSocket-Key: $nonce\r\n')
      ..write('Sec-WebSocket-Version: 13\r\n')
      ..write('Cache-Control: no-cache\r\n');
    headers?.forEach((k, v) => req.write('$k: $v\r\n'));
    req.write('\r\n');
    secure.add(utf8.encode(req.toString()));

    // 4. Read the response headers without consuming WebSocket frame bytes.
    // engine.io v4 sends its OPEN packet as the first frame immediately after
    // the 101, so any bytes after the header terminator are buffered and
    // forwarded to the WebSocket via [dataController].
    // ignore: close_sinks
    final dataController = StreamController<Uint8List>();
    final headerBuf = BytesBuilder(copy: false);
    final handshake = Completer<void>();
    var headersDone = false;
    late StreamSubscription<Uint8List> sub;

    void fail(Object error, [StackTrace? st]) {
      if (!handshake.isCompleted) handshake.completeError(error, st);
    }

    sub = secure.listen(
      (chunk) {
        if (headersDone) {
          dataController.add(chunk);
          return;
        }
        headerBuf.add(chunk);
        final bytes = headerBuf.toBytes();
        final end = _indexOfHeaderEnd(bytes);
        if (end < 0) return;
        headersDone = true;
        final headerText =
            String.fromCharCodes(bytes.sublist(0, end));
        final err = _validateHandshake(headerText, nonce);
        if (err != null) {
          fail(WebSocketException(err));
          sub.cancel();
          secure.destroy();
          unawaited(dataController.close());
          return;
        }
        final leftover = bytes.sublist(end + 4);
        if (leftover.isNotEmpty) {
          dataController.add(Uint8List.fromList(leftover));
        }
        handshake.complete();
      },
      onError: (Object e, StackTrace st) {
        fail(e, st);
        if (!dataController.isClosed) dataController.addError(e, st);
      },
      onDone: () {
        if (!headersDone) {
          fail(const WebSocketException(
              'Connection closed during WebSocket handshake'));
        }
        if (!dataController.isClosed) dataController.close();
      },
    );

    try {
      await handshake.future
          .timeout(const Duration(seconds: 15));
    } catch (e) {
      await sub.cancel();
      secure.destroy();
      rethrow;
    }

    // 5. Wrap so the WebSocket reads buffered+subsequent bytes while writes go
    // to the secure socket.
    final upgraded = _UpgradedSocket(secure, dataController.stream);
    return WebSocket.fromUpgradedSocket(upgraded, serverSide: false);
  }
}

/// Index of the "\r\n\r\n" header terminator, or -1 if not present yet.
int _indexOfHeaderEnd(Uint8List b) {
  for (var i = 0; i + 3 < b.length; i++) {
    if (b[i] == 13 && b[i + 1] == 10 && b[i + 2] == 13 && b[i + 3] == 10) {
      return i;
    }
  }
  return -1;
}

/// Validates the HTTP upgrade response. Returns an error message or null.
String? _validateHandshake(String headerText, String nonce) {
  final lines = headerText.split('\r\n');
  if (lines.isEmpty) return 'Empty handshake response';
  final statusParts = lines.first.split(' ');
  if (statusParts.length < 2 || statusParts[1] != '101') {
    return "Connection was not upgraded to websocket (status '${lines.first}')";
  }
  String? headerValue(String name) {
    final lower = name.toLowerCase();
    for (var i = 1; i < lines.length; i++) {
      final idx = lines[i].indexOf(':');
      if (idx <= 0) continue;
      if (lines[i].substring(0, idx).trim().toLowerCase() == lower) {
        return lines[i].substring(idx + 1).trim();
      }
    }
    return null;
  }

  final upgrade = headerValue('upgrade');
  if (upgrade == null || upgrade.toLowerCase() != 'websocket') {
    return "Missing or invalid 'Upgrade' header";
  }
  final connection = headerValue('connection');
  if (connection == null || !connection.toLowerCase().contains('upgrade')) {
    return "Missing or invalid 'Connection' header";
  }
  final accept = headerValue('sec-websocket-accept');
  if (accept == null) {
    return "Response did not contain a 'Sec-WebSocket-Accept' header";
  }
  const guid = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';
  final expected = base64.encode(_sha1('$nonce$guid'.codeUnits));
  if (accept != expected) {
    return "Bad 'Sec-WebSocket-Accept' header";
  }
  return null;
}

/// Socket wrapper used for WebSocket.fromUpgradedSocket: the [Stream] side
/// replays buffered handshake-leftover bytes then the rest of the secure
/// socket, while all sink/socket operations delegate to the secure socket.
/// Extending StreamView provides the full Stream<Uint8List> surface.
class _UpgradedSocket extends StreamView<Uint8List> implements Socket {
  final Socket _inner;

  _UpgradedSocket(this._inner, Stream<Uint8List> data) : super(data);

  @override
  Encoding get encoding => _inner.encoding;
  @override
  set encoding(Encoding value) => _inner.encoding = value;

  @override
  void add(List<int> data) => _inner.add(data);
  @override
  void write(Object? object) => _inner.write(object);
  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) =>
      _inner.writeAll(objects, separator);
  @override
  void writeln([Object? object = '']) => _inner.writeln(object);
  @override
  void writeCharCode(int charCode) => _inner.writeCharCode(charCode);
  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _inner.addError(error, stackTrace);
  @override
  Future<dynamic> addStream(Stream<List<int>> stream) =>
      _inner.addStream(stream);
  @override
  Future<dynamic> flush() => _inner.flush();
  @override
  Future<dynamic> close() => _inner.close();
  @override
  Future<dynamic> get done => _inner.done;

  @override
  void destroy() => _inner.destroy();
  @override
  bool setOption(SocketOption option, bool enabled) =>
      _inner.setOption(option, enabled);
  @override
  Uint8List getRawOption(RawSocketOption option) =>
      _inner.getRawOption(option);
  @override
  void setRawOption(RawSocketOption option) => _inner.setRawOption(option);

  @override
  int get port => _inner.port;
  @override
  int get remotePort => _inner.remotePort;
  @override
  InternetAddress get address => _inner.address;
  @override
  InternetAddress get remoteAddress => _inner.remoteAddress;
}

/// Minimal SHA-1 (RFC 3174) for the Sec-WebSocket-Accept check, so the fork
/// needs no extra dependency.
List<int> _sha1(List<int> msg) {
  var h0 = 0x67452301,
      h1 = 0xEFCDAB89,
      h2 = 0x98BADCFE,
      h3 = 0x10325476,
      h4 = 0xC3D2E1F0;
  final ml = msg.length * 8;
  final bytes = List<int>.from(msg)..add(0x80);
  while (bytes.length % 64 != 56) {
    bytes.add(0);
  }
  for (var i = 7; i >= 0; i--) {
    bytes.add((ml >> (i * 8)) & 0xff);
  }
  int rol(int v, int n) =>
      ((v << n) | ((v & 0xffffffff) >> (32 - n))) & 0xffffffff;
  for (var chunk = 0; chunk < bytes.length; chunk += 64) {
    final w = List<int>.filled(80, 0);
    for (var i = 0; i < 16; i++) {
      w[i] = (bytes[chunk + i * 4] << 24) |
          (bytes[chunk + i * 4 + 1] << 16) |
          (bytes[chunk + i * 4 + 2] << 8) |
          bytes[chunk + i * 4 + 3];
    }
    for (var i = 16; i < 80; i++) {
      w[i] = rol(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1);
    }
    var a = h0, b = h1, c = h2, d = h3, e = h4;
    for (var i = 0; i < 80; i++) {
      int f, k;
      if (i < 20) {
        f = (b & c) | (~b & d);
        k = 0x5A827999;
      } else if (i < 40) {
        f = b ^ c ^ d;
        k = 0x6ED9EBA1;
      } else if (i < 60) {
        f = (b & c) | (b & d) | (c & d);
        k = 0x8F1BBCDC;
      } else {
        f = b ^ c ^ d;
        k = 0xCA62C1D6;
      }
      final tmp = (rol(a, 5) + f + e + k + w[i]) & 0xffffffff;
      e = d;
      d = c;
      c = rol(b, 30);
      b = a;
      a = tmp;
    }
    h0 = (h0 + a) & 0xffffffff;
    h1 = (h1 + b) & 0xffffffff;
    h2 = (h2 + c) & 0xffffffff;
    h3 = (h3 + d) & 0xffffffff;
    h4 = (h4 + e) & 0xffffffff;
  }
  final out = <int>[];
  for (final h in [h0, h1, h2, h3, h4]) {
    out.addAll([(h >> 24) & 0xff, (h >> 16) & 0xff, (h >> 8) & 0xff, h & 0xff]);
  }
  return out;
}

HttpClientAdapter makePlatformHttpClientAdapter({dynamic sourceAddress}) {
  return IOHttpClientAdapter(sourceAddress: sourceAddress as InternetAddress?);
}
