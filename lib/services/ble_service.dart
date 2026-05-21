import 'dart:async';
import 'dart:convert';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

/// Typed message coming off the LoRa network via BLE.
class BleMessage {
  final String type;       // '00' = incoming msg, '01' = ack
  final int messageId;
  final int senderId;
  final int receiverId;
  final String text;
  final String status;     // '00' = received, '01' = delivered, '02' = error

  const BleMessage({
    required this.type,
    required this.messageId,
    required this.senderId,
    required this.receiverId,
    required this.text,
    this.status = '00',
  });
}

class BleService {
  static final BleService _instance = BleService._internal();
  factory BleService() => _instance;
  BleService._internal();

  BluetoothDevice? _connectedDevice;
  BluetoothCharacteristic? _rxCharacteristic;
  BluetoothCharacteristic? _txCharacteristic;

  final StreamController<String> _connectionStatusController =
  StreamController<String>.broadcast();
  final StreamController<BleMessage> _messageController =
  StreamController<BleMessage>.broadcast();

  Stream<String> get connectionStatus => _connectionStatusController.stream;
  Stream<BleMessage> get messages => _messageController.stream;

  bool get isConnected =>
      _connectedDevice != null && _rxCharacteristic != null;
  String get deviceName => _connectedDevice?.platformName ?? 'No Device';
//Nordic UART Service (NUS) UUID if this matched ble connected hunxa.

  final String serviceUUID = "6e400001-b5a3-f393-e0a9-e50e24dcca9e";
  final String rxCharacteristicUUID = "6e400002-b5a3-f393-e0a9-e50e24dcca9e";
  final String txCharacteristicUUID = "6e400003-b5a3-f393-e0a9-e50e24dcca9e";

  final List<String> _chunkBuffer = [];
  bool _isReceivingChunk = false;

  // ── SCAN ──────────────────────────────────────────────────────────────────
//connect garna ko lagi
  Future<List<BluetoothDevice>> scanDevices() async {
    _connectionStatusController.add('Scanning...');
    final List<BluetoothDevice> foundDevices = [];

    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 10));

    final sub = FlutterBluePlus.scanResults.listen((results) {
      for (final r in results) {
        if (r.device.platformName.isNotEmpty &&
            !foundDevices.contains(r.device)) {
          foundDevices.add(r.device);
        }
      }
    });

    await Future.delayed(const Duration(seconds: 10));
    await FlutterBluePlus.stopScan();
    await sub.cancel();

    _connectionStatusController.add('Scan complete');
    return foundDevices;
  }

  // ── CONNECT ───────────────────────────────────────────────────────────────

  Future<void> connectToDevice(BluetoothDevice device) async {
    try {
      _connectionStatusController.add('Connecting...');
      await device.connect();
      _connectedDevice = device;
// if connected discoverservices() is called which is ble handshake
      //uuid is matched and find TX and RX charactertics and esp32 sents data then app lai notify
      final services = await device.discoverServices();

      for (final service in services) {
        if (service.uuid.toString().toLowerCase() ==
            serviceUUID.toLowerCase()) {
          for (final c in service.characteristics) {
            if (c.uuid.toString().toLowerCase() ==
                rxCharacteristicUUID.toLowerCase()) {
              _rxCharacteristic = c;
            }
            if (c.uuid.toString().toLowerCase() ==
                txCharacteristicUUID.toLowerCase()) {
              _txCharacteristic = c;
              await c.setNotifyValue(true);
              c.onValueReceived.listen((value) {
                if (value.isEmpty) return;
                _handleIncoming(String.fromCharCodes(value));
              });
            }
          }
        }
      }

      _connectionStatusController.add('Connected');

      device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          _connectedDevice = null;
          _rxCharacteristic = null;
          _txCharacteristic = null;
          _chunkBuffer.clear();
          _isReceivingChunk = false;
          _connectionStatusController.add('Disconnected');
        }
      });
    } catch (e) {
      _connectionStatusController.add('Error: $e');
    }
  }

  // ── INCOMING ──────────────────────────────────────────────────────────────
//esp to app if chunks collect it
  //
  void _handleIncoming(String raw) {
    if (raw.startsWith('CHUNK_START:')) {
      _chunkBuffer.clear();
      _isReceivingChunk = true;
    } else if (raw.startsWith('CHUNK:') && _isReceivingChunk) {
      _chunkBuffer.add(raw.substring(6));//collect chunk
    } else if (raw == 'CHUNK_END' && _isReceivingChunk) {
      final full = _chunkBuffer.join();//join chunk
      _chunkBuffer.clear();
      _isReceivingChunk = false;
      _parseAndEmit(full);
    } else if (!_isReceivingChunk) {
      _parseAndEmit(raw);//single message
    }
  }
// convert json string to ble message object
  // listen by main.dart and shown in UI
  void _parseAndEmit(String raw) {
    try {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      _messageController.add(BleMessage(
        type: data['type'] as String? ?? '00',
        messageId: data['messageId'] as int? ?? 0,
        senderId: data['senderId'] as int? ?? 0,
        receiverId: data['receiverId'] as int? ?? 0,
        text: data['text'] as String? ?? '',
        status: data['status'] as String? ?? '00',
      ));
    } catch (_) {
      // Plain text fallback
      _messageController.add(BleMessage(
        type: '00',
        messageId: 0,
        senderId: 0,
        receiverId: 0,
        text: raw,
        status: '00',
      ));
    }
  }

  // ── SEND ──────────────────────────────────────────────────────────────────
// send from app to esp
  Future<void> sendMessage(String message) async {
    if (_rxCharacteristic == null || !isConnected) {
      throw Exception('Not connected or characteristic not ready');
    }

    // message sending
    await _rxCharacteristic!.write(
      message.codeUnits,// convert message to ascii values
      withoutResponse: true,// fast sending data
    );
  }

  // ── DISCONNECT ────────────────────────────────────────────────────────────

  Future<void> disconnect() async {
    await _connectedDevice?.disconnect();
    _connectedDevice = null;
    _rxCharacteristic = null;
    _txCharacteristic = null;
    _connectionStatusController.add('Disconnected');
  }

  void dispose() {
    _connectionStatusController.close();
    _messageController.close();
  }
}