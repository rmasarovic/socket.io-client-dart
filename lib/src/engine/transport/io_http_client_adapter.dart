import 'dart:io';
import 'http_client_adapter.dart';

class IOHttpClientAdapter implements HttpClientAdapter {
  static final HttpClient _sharedHttpClient = HttpClient()
    ..maxConnectionsPerHost = 1000000;

  final HttpClient _httpClient;
  final InternetAddress? sourceAddress;

  IOHttpClientAdapter({HttpClient? httpClient, this.sourceAddress})
      : _httpClient = httpClient ??
            (sourceAddress != null
                ? _createSourceBoundHttpClient(sourceAddress)
                : _sharedHttpClient) {
    print('[IOHttpClientAdapter] created with sourceAddress: ${sourceAddress?.address ?? "DEFAULT/shared"}');
  }

  static HttpClient _createSourceBoundHttpClient(InternetAddress sourceAddr) {
    print('[IOHttpClientAdapter] Creating source-bound HttpClient for ${sourceAddr.address}');
    return HttpClient()
      ..maxConnectionsPerHost = 1000000
      ..connectionFactory = (Uri uri, String? proxyHost, int? proxyPort) {
        final host = proxyHost ?? uri.host;
        final port = proxyPort ?? uri.port;
        print('[IOHttpClientAdapter] connectionFactory: connecting to $host:$port from ${sourceAddr.address}');
        return Socket.startConnect(
          host,
          port,
          sourceAddress: sourceAddr,
        );
      };
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
