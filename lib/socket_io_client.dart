///
/// socket_io_client.dart
///
/// Purpose:
///
/// Description:
///
/// History:
///   26/04/2017, Created by jumperchen
///
/// Copyright (C) 2017 Potix Corporation. All Rights Reserved.
///

library socket_io_client;

import 'package:logging/logging.dart';
import 'package:socket_io_client/src/socket.dart';
import 'package:socket_io_common/src/engine/parser/parser.dart' as parser;
import 'package:socket_io_client/src/engine/parseqs.dart';
import 'package:socket_io_client/src/manager.dart';

export 'package:socket_io_client/src/socket.dart';
export 'package:socket_io_client/src/darty.dart';
export 'package:socket_io_client/src/engine/transport/http_client_adapter.dart';

// Protocol version
final protocol = parser.protocol;

final Map<String, dynamic> cache = {};

final Logger _logger = Logger('socket_io_client');

///
/// Looks up an existing `Manager` for multiplexing.
/// If the user summons:
///
///   `io('http://localhost/a');`
///   `io('http://localhost/b');`
///
/// We reuse the existing instance based on same scheme/port/host,
/// and we initialize sockets for each namespace.
///
/// @api public
///
Socket io(uri, [opts]) => _lookup(uri, opts);

Socket _lookup(uri, opts) {
  opts = opts ?? <dynamic, dynamic>{};

  var parsed = Uri.parse(uri);
  // Build cache key with sourceAddress so each source IP gets its own Manager
  var sourceAddr = opts['sourceAddress']?.address ?? '';
  var baseId = '${parsed.scheme}://${parsed.host}:${parsed.port}';
  if (sourceAddr.isNotEmpty) {
    baseId = '$baseId#$sourceAddr';
  }
  var path = parsed.path;

  var forceNew = opts['forceNew'] == true ||
      opts['force new connection'] == true ||
      false == opts['multiplex'];

  late Manager io;

  if (forceNew) {
    _logger.fine('ignoring socket cache for $uri');
    io = Manager(uri: uri, options: opts);
  } else {
    // When sameNamespace is hit, find or create a new Manager slot
    // instead of creating an uncached throwaway Manager.
    // This ensures namespace multiplexing works for all clients.
    var id = baseId;
    var suffix = 0;
    while (cache.containsKey(id) && cache[id].nsps.containsKey(path)) {
      suffix++;
      id = '$baseId~$suffix';
    }
    io = cache[id] ??= Manager(uri: uri, options: opts);
  }
  if (parsed.query.isNotEmpty && opts['query'] == null) {
    opts['query'] = parsed.query;
  } else if (opts != null && opts['query'] is Map) {
    opts['query'] = encode(opts['query']);
  }
  return io.socket(parsed.path.isEmpty ? '/' : parsed.path, opts);
}
