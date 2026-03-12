import 'dart:io';
import 'http_client_adapter.dart';

class IOHttpClientAdapter implements HttpClientAdapter {
  final HttpClient _httpClient;
  final InternetAddress? sourceAddress;

  IOHttpClientAdapter({HttpClient? httpClient, this.sourceAddress})
      : _httpClient = httpClient ?? HttpClient() {
    if (sourceAddress != null) {
      // Set up IOOverrides to bind to specific source address
      _configureSourceAddress();
    }
  }

  void _configureSourceAddress() {
    // Override socket connection to use sourceAddress
    IOOverrides.global = _SourceAddressIOOverrides(sourceAddress!);
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

final class _SourceAddressIOOverrides extends IOOverrides {
  final InternetAddress sourceAddress;

  _SourceAddressIOOverrides(this.sourceAddress);

  @override
  Future<Socket> socketConnect(host, int port,
      {sourceAddress, int sourcePort = 0, Duration? timeout}) {
    return Socket.connect(
      host,
      port,
      sourceAddress: this.sourceAddress,
      sourcePort: sourcePort,
      timeout: timeout,
    );
  }
}

HttpClientAdapter makePlatformHttpClientAdapter({dynamic sourceAddress}) {
  return IOHttpClientAdapter(
      sourceAddress: sourceAddress as InternetAddress?);
}
