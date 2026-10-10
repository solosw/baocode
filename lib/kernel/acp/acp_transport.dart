import 'dart:async';

import '../agent_kernel.dart';

/// The client side of an ACP agent connection.
///
/// ACP transports carry JSON-RPC messages. Implementations may use stdio,
/// a remote process, or an in-process test transport.
abstract interface class AcpTransport {
  Stream<Map<String, Object?>> get messages;

  void write(Map<String, Object?> message);

  void close();
}

/// Queues messages until a listener is attached, then forwards live ones.
///
/// ACP agents can emit `session/update` as soon as `session/new` is handled,
/// before the JSON-RPC response. A broadcast stream drops those if the
/// client is still awaiting the response.
class QueuedAcpTransport implements AcpTransport {
  QueuedAcpTransport(this._inner) {
    _inner.messages.listen(
      (message) {
        final controller = _out;
        if (controller == null || !controller.hasListener) {
          _queued.add(message);
        } else {
          controller.add(message);
        }
      },
      onError: (Object error, StackTrace stack) {
        final controller = _out;
        if (controller == null || !controller.hasListener) {
          _queuedErrors.add((error, stack));
        } else {
          controller.addError(error, stack);
        }
      },
      onDone: () {
        _done = true;
        _out?.close();
      },
    );
  }

  final AcpTransport _inner;
  final List<Map<String, Object?>> _queued = [];
  final List<(Object, StackTrace)> _queuedErrors = [];
  StreamController<Map<String, Object?>>? _out;
  bool _done = false;

  /// Messages received while no listener is attached, in arrival order.
  List<Map<String, Object?>> takeQueued() {
    final queued = [..._queued];
    _queued.clear();
    return queued;
  }

  @override
  Stream<Map<String, Object?>> get messages {
    final existing = _out;
    if (existing != null) return existing.stream;
    late final StreamController<Map<String, Object?>> controller;
    controller = StreamController<Map<String, Object?>>.broadcast(
      sync: true,
      onListen: () {
        if (_done) controller.close();
      },
    );
    _out = controller;
    return controller.stream;
  }

  @override
  void write(Map<String, Object?> message) => _inner.write(message);

  @override
  void close() {
    _inner.close();
    _out?.close();
  }
}

typedef AcpTransportFactory = Future<AcpTransport> Function(
  KernelContext context,
);
