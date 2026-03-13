import 'dart:io';
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

  static HttpClient _getOrCreateSourceBoundHttpClient(InternetAddress sourceAddr) {
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
    return WebSocket.connect(
      uri,
      headers: headers,
      customClient: _httpClient,
    );
  }
}

HttpClientAdapter makePlatformHttpClientAdapter({dynamic sourceAddress}) {
  return IOHttpClientAdapter(
      sourceAddress: sourceAddress as InternetAddress?);
}
