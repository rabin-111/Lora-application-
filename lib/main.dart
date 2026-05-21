import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'services/ble_service.dart';
import 'services/database_service.dart';
import 'dart:convert';
import 'dart:math';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await DatabaseService.init();
  runApp(const LoraNetApp());
}

class LoraNetApp extends StatelessWidget {
  const LoraNetApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LoRaChat',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: aconst Color(0xFF4FC3F7),
          brightness: Brightness.light,
          primary: const Color(0xFF4FC3F7),
          secondary: const Color(0xFF29B6F6),
        ),
        scaffoldBackgroundColor: const Color(0xFFF5F9FC),
        cardColor: Colors.white,
        appBarTheme: const AppBarTheme(
          elevation: 0,
          backgroundColor: Color(0xFF4FC3F7),
          foregroundColor: Colors.white,
        ),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final BleService _bleService = BleService();

  String _connectionStatus = 'Disconnected';
  final List<Map<String, dynamic>> _messages = [];
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _messageScrollController = ScrollController();

  int _selectedIndex = 0;
  String _userId = '';
  String _userName = 'User';
  String _receiverId = '';

  static const int _chunkSize = 200;

  @override
  void initState() {
    super.initState();
    _requestPermissions();
    _setupListeners();
    _loadUserProfile().then((_) => _loadSavedMessages());
  }

  Future<void> _loadUserProfile() async {
    final savedName = await DatabaseService.getUserName();
    if (savedName != null && savedName.isNotEmpty) {
      if (mounted) setState(() => _userName = savedName);
    }
    final savedId = await DatabaseService.getUserId();
    if (savedId != null && savedId.isNotEmpty) {
      if (mounted) setState(() => _userId = savedId);
    } else {
      final random = Random.secure();
      final int randomByte = random.nextInt(255) + 1;
      final String newId = randomByte.toRadixString(16).toUpperCase().padLeft(2, '0');
      await DatabaseService.saveUserId(newId);
      if (mounted) setState(() => _userId = newId);
    }
  }

  // ── FIX: read userId directly from DB so isSent is always correct ─────────
  Future<void> _loadSavedMessages() async {
    final savedId = await DatabaseService.getUserId();
    final myIdInt = savedId == null || savedId.isEmpty
        ? 0
        : int.tryParse(savedId, radix: 16) ?? 0;

    final saved = await DatabaseService.loadMessages();
    final processed = saved.map((row) {
      final senderId = row['senderId'] as int? ?? 0;
      return <String, dynamic>{
        ...row,
        'isSent': senderId == myIdInt,
      };
    }).toList();
    if (mounted) {
      setState(() {
        _messages.clear();
        _messages.addAll(processed);
      });
      _scrollToBottom(_messageScrollController);
    }
  }

  Future<void> _requestPermissions() async {
    await Permission.bluetoothScan.request();
    await Permission.bluetoothConnect.request();
    await Permission.location.request();
  }

  void _setupListeners() {
    _bleService.connectionStatus.listen((status) {
      if (mounted) setState(() => _connectionStatus = status);
      if (status == 'Connected') {
        Future.delayed(const Duration(milliseconds: 500), _retryFailedMessages);
      }
    });

    _bleService.messages.listen((BleMessage message) async {
      if (_userId.isNotEmpty) {
        final int myIdInt = int.tryParse(_userId, radix: 16) ?? 0;
        if (message.senderId == myIdInt) return;
      }

      final int messageId = message.messageId;
      final String text = message.text;
      final int senderId = message.senderId;
      final int receiverId = message.receiverId;
      final String type = message.type;

      if (type == '01') {
        if (mounted) {
          setState(() {
            final index = _messages.indexWhere(
                  (m) => m['messageId'] == messageId && m['isSent'] == true,
            );
            if (index != -1) {
              _messages[index]['status'] = 'delivered';
            }
          });
          final dbMsg = _messages.firstWhere(
                (m) => m['messageId'] == messageId && m['isSent'] == true,
            orElse: () => {},
          );
          if (dbMsg.isNotEmpty && dbMsg['id'] != null) {
            await DatabaseService.updateMessageStatus(
              dbMsg['id'] as int,
              'delivered',
            );
          }
        }
        return;
      }

      if (type == '00') {
        if (text == 'NULL') return;
        final alreadyExists = _messages.any(
              (m) => m['messageId'] == messageId && m['isSent'] == false,
        );
        if (alreadyExists) return;

        final int tempKey = DateTime.now().millisecondsSinceEpoch;
        if (mounted) {
          setState(() {
            _messages.add({
              'id': tempKey,
              'text': text,
              'time': DateTime.now(),
              'status': 'received',
              'isSent': false,
              'retryCount': 0,
              'messageId': messageId,
              'senderId': senderId,
              'receiverId': receiverId,
            });
          });
          _scrollToBottom(_messageScrollController);
        }

        final id = await DatabaseService.saveMessage(
          messageId: messageId,
          type: type,
          senderId: senderId,
          receiverId: receiverId,
          text: text,
          status: 'received',
        );

        if (mounted) {
          setState(() {
            final index = _messages.indexWhere((m) => m['id'] == tempKey);
            if (index != -1) _messages[index]['id'] = id;
          });
        }
      }
    });
  }

  List<String> _chunkMessage(String text) {
    if (text.length <= _chunkSize) return [text];
    final chunks = <String>[];
    for (int i = 0; i < text.length; i += _chunkSize) {
      final end = (i + _chunkSize < text.length) ? i + _chunkSize : text.length;
      chunks.add(text.substring(i, end));
    }
    return chunks;
  }

  Future<void> _sendChunked(String text) async {
    final chunks = _chunkMessage(text);
    if (chunks.length == 1) {
      await _bleService.sendMessage(chunks[0]);
    } else {
      await _bleService.sendMessage('CHUNK_START:${chunks.length}');
      for (int i = 0; i < chunks.length; i++) {
        await _bleService.sendMessage('CHUNK:${chunks[i]}');
        await Future.delayed(const Duration(milliseconds: 50));
      }
      await _bleService.sendMessage('CHUNK_END');
    }
  }

  Future<void> _retryFailedMessages() async {
    final failed = await DatabaseService.getFailedMessages();
    for (final msg in failed) {
      final id = msg['id'] as int;
      final payload = {
        "messageId": msg['messageId'],
        "type": "01",
        "senderId": msg['senderId'],
        "receiverId": msg['receiverId'],
        "text": msg['text'],
      };
      try {
        await _sendChunked(jsonEncode(payload));
        await DatabaseService.updateMessageStatus(id, 'sent');
        if (mounted) {
          setState(() {
            final index = _messages.indexWhere((m) => m['id'] == id);
            if (index != -1) _messages[index]['status'] = 'sent';
          });
        }
      } catch (e) {
        await DatabaseService.incrementRetry(id);
      }
    }
  }

  Future<void> _retrySingleMessage(Map<String, dynamic> msg) async {
    if (!_bleService.isConnected) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Not connected to ESP32. Please connect first.'),
            backgroundColor: Colors.red,
          ),
        );
      }
      return;
    }

    final id = msg['id'] as int;
    final text = msg['text'] as String;
    final int senderId = int.tryParse(_userId.isEmpty ? '01' : _userId, radix: 16) ?? 1;
    final int receiverId = msg['receiverId'] as int? ?? 1;

    if (mounted) {
      setState(() {
        final index = _messages.indexWhere((m) => m['id'] == id);
        if (index != -1) _messages[index]['status'] = 'pending';
      });
    }

    final payload = {
      "messageId": msg['messageId'] ?? 0,
      "type": "01",
      "senderId": senderId,
      "receiverId": receiverId,
      "text": text,
    };

    try {
      await _sendChunked(jsonEncode(payload));
      await DatabaseService.updateMessageStatus(id, 'sent');
      if (mounted) {
        setState(() {
          final index = _messages.indexWhere((m) => m['id'] == id);
          if (index != -1) _messages[index]['status'] = 'sent';
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Message sent!'), backgroundColor: Colors.green),
        );
      }
    } catch (e) {
      await DatabaseService.incrementRetry(id);
      if (mounted) {
        setState(() {
          final index = _messages.indexWhere((m) => m['id'] == id);
          if (index != -1) _messages[index]['status'] = 'failed';
        });
      }
    }
  }

  void _scrollToBottom(ScrollController controller) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (controller.hasClients) {
        controller.animateTo(
          controller.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _connectToBle() async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(
        child: Card(
          child: Padding(
            padding: EdgeInsets.all(20.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 16),
                Text('Scanning for devices...'),
              ],
            ),
          ),
        ),
      ),
    );

    final devices = await _bleService.scanDevices();
    if (mounted) Navigator.of(context).pop();

    if (devices.isEmpty) {
      if (mounted) {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('No Devices Found'),
            content: const Text('No Bluetooth devices found. Make sure your ESP32 is on.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      }
      return;
    }

    if (mounted) {
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Select Device'),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: devices.length,
              itemBuilder: (context, index) {
                final device = devices[index];
                return ListTile(
                  leading: const Icon(Icons.bluetooth, color: Color(0xFF4FC3F7)),
                  title: Text(
                    device.platformName.isEmpty ? 'Unknown Device' : device.platformName,
                    style: const TextStyle(fontWeight: FontWeight.w500),
                  ),
                  subtitle: Text(
                    device.remoteId.toString(),
                    style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                  ),
                  onTap: () async {
                    Navigator.of(context).pop();
                    await _bleService.connectToDevice(device);
                  },
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
          ],
        ),
      );
    }
  }

  void _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;

    if (_userId.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Please wait, profile is loading...'),
            backgroundColor: Colors.orange,
          ),
        );
      }
      return;
    }

    if (_receiverId.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Please set receiver ID first.'),
            backgroundColor: Colors.orange,
            action: SnackBarAction(
              label: 'Set',
              textColor: Colors.white,
              onPressed: _editReceiverId,
            ),
          ),
        );
      }
      return;
    }

    _messageController.clear();

    final int messageId = DateTime.now().millisecondsSinceEpoch % 256;
    final int senderId = int.tryParse(_userId, radix: 16) ?? 1;
    final int receiverId = int.tryParse(_receiverId, radix: 16) ?? 1;

    final payload = {
      "messageId": messageId,
      "type": "01",
      "senderId": senderId,
      "receiverId": receiverId,
      "text": text,
    };

    final jsonMessage = jsonEncode(payload);

    // STEP 1: show in UI immediately
    final int tempKey = DateTime.now().millisecondsSinceEpoch;
    if (mounted) {
      setState(() {
        _messages.add({
          'id': tempKey,
          'text': text,
          'isSent': true,       // ── always explicitly set
          'time': DateTime.now(),
          'status': 'pending',
          'retryCount': 0,
          'messageId': messageId,
          'receiverId': receiverId,
          'senderId': senderId, // ── store senderId so reload works correctly
        });
      });
      _scrollToBottom(_messageScrollController);
    }

    // STEP 2: not connected — save as failed
    if (!_bleService.isConnected) {
      final id = await DatabaseService.saveMessage(
        messageId: messageId,
        type: "01",
        senderId: senderId,
        receiverId: receiverId,
        text: text,
        status: 'failed',
      );
      if (mounted) {
        setState(() {
          final index = _messages.indexWhere(
                (m) => m['messageId'] == messageId && m['isSent'] == true,
          );
          if (index != -1) {
            _messages[index]['id'] = id;
            _messages[index]['status'] = 'failed';
          }
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Not connected. Long press message to retry.'),
            backgroundColor: Colors.orange,
            duration: Duration(seconds: 3),
          ),
        );
      }
      return;
    }

    // STEP 3: send via BLE
    try {
      await _sendChunked(jsonMessage);
      final id = await DatabaseService.saveMessage(
        messageId: messageId,
        type: "01",
        senderId: senderId,
        receiverId: receiverId,
        text: text,
        status: 'sent',
      );
      if (mounted) {
        setState(() {
          final index = _messages.indexWhere(
                (m) => m['messageId'] == messageId && m['isSent'] == true,
          );
          if (index != -1) {
            _messages[index]['id'] = id;
            _messages[index]['status'] = 'sent';
          }
        });
      }
    } catch (e) {
      final id = await DatabaseService.saveMessage(
        messageId: messageId,
        type: "01",
        senderId: senderId,
        receiverId: receiverId,
        text: text,
        status: 'failed',
      );
      if (mounted) {
        setState(() {
          final index = _messages.indexWhere(
                (m) => m['messageId'] == messageId && m['isSent'] == true,
          );
          if (index != -1) {
            _messages[index]['id'] = id;
            _messages[index]['status'] = 'failed';
          }
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Send failed: $e'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }
  }

  Future<void> _sendInitPacket(int receiverId) async {
    if (!_bleService.isConnected) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Receiver ID saved. Connect to ESP32 first to initialize.'),
            backgroundColor: Colors.orange,
            duration: Duration(seconds: 3),
          ),
        );
      }
      return;
    }

    final int senderId = int.tryParse(_userId.isEmpty ? '01' : _userId, radix: 16) ?? 1;
    final int messageId = DateTime.now().millisecondsSinceEpoch % 65536;
    final payload = {
      "messageId": messageId,
      "type": "00",
      "senderId": senderId,
      "receiverId": receiverId,
      "text": "NULL",
    };
    try {
      await _sendChunked(jsonEncode(payload));
      debugPrint('Init packet sent → sender:$senderId receiver:$receiverId');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
                'Initialized with receiver 0x${receiverId.toRadixString(16).toUpperCase().padLeft(2, '0')}'),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      debugPrint('Init packet failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Init failed: $e'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
  }

  void _editName() {
    final controller = TextEditingController(text: _userName);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit Name'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(hintText: 'Enter your name'),
          autofocus: true,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () {
              if (controller.text.isNotEmpty) {
                setState(() => _userName = controller.text);
                DatabaseService.saveUserName(controller.text);
              }
              Navigator.pop(context);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF4FC3F7),
              foregroundColor: Colors.white,
            ),
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  void _editUserId() {
    final controller = TextEditingController(text: _userId);
    String? errorText;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Set Your ID'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: controller,
                maxLength: 2,
                textCapitalization: TextCapitalization.characters,
                decoration: InputDecoration(
                  hintText: 'e.g. A3',
                  errorText: errorText,
                  helperText: 'Choose any hex value from 01 to FF',
                ),
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 4,
                ),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9a-fA-F]')),
                ],
                onChanged: (_) {
                  if (errorText != null) setDialogState(() => errorText = null);
                },
              ),
              const SizedBox(height: 8),
              Text(
                'This ID identifies you on the LoRa network.',
                style: TextStyle(fontSize: 12, color: Colors.grey[500], height: 1.5),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () {
                final input = controller.text.trim().toUpperCase();
                final value = int.tryParse(input, radix: 16);
                if (input.length != 2 || value == null || value < 1 || value > 255) {
                  setDialogState(() => errorText = 'Enter a hex value from 01 to FF');
                  return;
                }
                setState(() => _userId = input);
                DatabaseService.saveUserId(input);
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('ID set to 0x$input'),
                    backgroundColor: const Color(0xFF4FC3F7),
                    duration: const Duration(seconds: 2),
                  ),
                );
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF4FC3F7),
                foregroundColor: Colors.white,
              ),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  void _editReceiverId() {
    final controller = TextEditingController(text: _receiverId);
    String? errorText;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Set Receiver ID'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: controller,
                maxLength: 2,
                textCapitalization: TextCapitalization.characters,
                decoration: InputDecoration(
                  hintText: 'e.g. B2',
                  errorText: errorText,
                  helperText: 'Receiver hex ID from 01 to FF',
                ),
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 4,
                ),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9a-fA-F]')),
                ],
                onChanged: (_) {
                  if (errorText != null) setDialogState(() => errorText = null);
                },
              ),
              const SizedBox(height: 8),
              Text(
                'Ask the receiver for their ID shown in their Profile tab.',
                style: TextStyle(fontSize: 12, color: Colors.grey[500], height: 1.5),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () {
                final input = controller.text.trim().toUpperCase();
                final value = int.tryParse(input, radix: 16);
                if (input.length != 2 || value == null || value < 1 || value > 255) {
                  setDialogState(() => errorText = 'Enter a hex value from 01 to FF');
                  return;
                }
                setState(() => _receiverId = input);
                Navigator.pop(context);
                final int receiverIdInt = int.tryParse(input, radix: 16) ?? 1;
                _sendInitPacket(receiverIdInt);
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF4FC3F7),
                foregroundColor: Colors.white,
              ),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }
// show received status
  Widget _buildStatusIcon(String status) {
    switch (status) {
      case 'pending':
        return const Icon(Icons.access_time, size: 14, color: Colors.white70);
      case 'sent':
        return const Icon(Icons.done, size: 14, color: Colors.white70);
      case 'delivered':
        return const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.done, size: 14, color: Colors.white70),
            SizedBox(width: -6),
            Icon(Icons.done, size: 14, color: Colors.white70),
          ],
        );
      case 'failed':
        return const Icon(Icons.refresh, size: 14, color: Colors.redAccent);
      default:
        return const Icon(Icons.done, size: 14, color: Colors.white70);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(

      // ui of the top bar
      appBar: AppBar(
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.2),
                borderRadius: BorderRadius.circular(8),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.asset(
                  'assets/icon/app_icon.png',
                  width: 32,
                  height: 32,
                  fit: BoxFit.cover,
                ),
              ),
            ),
            const SizedBox(width: 12),
            const Text('LoRaChat',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 20)),
          ],
        ),
        actions: [
          IconButton(
            icon: Icon(
              _bleService.isConnected// green icon
                  ? Icons.bluetooth_connected
                  : Icons.bluetooth_searching,
              color: _bleService.isConnected ? Colors.greenAccent : Colors.white,
              size: 24,
            ),
            onPressed: _connectToBle,
            tooltip: _bleService.isConnected
                ? _bleService.deviceName
                : 'Connect to ESP32',
          ),
        ],
      ),
      body: SafeArea(
        child: _selectedIndex == 0 ? _buildMessagingTab() : _buildProfileTab(),
      ),
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.05),
              blurRadius: 10,
              offset: const Offset(0, -2),
            )
          ],
        ),
        child: SafeArea(
          child: BottomNavigationBar(
            currentIndex: _selectedIndex,
            selectedFontSize: 12,
            unselectedFontSize: 11,
            type: BottomNavigationBarType.fixed,
            elevation: 0,
            backgroundColor: Colors.transparent,
            selectedItemColor: const Color(0xFF4FC3F7),
            unselectedItemColor: Colors.grey[400],
            onTap: (index) => setState(() => _selectedIndex = index),
            items: const [
              BottomNavigationBarItem(
                icon: Padding(
                  padding: EdgeInsets.only(bottom: 4),
                  child: Icon(Icons.message_outlined, size: 24),
                ),
                activeIcon: Padding(
                  padding: EdgeInsets.only(bottom: 4),
                  child: Icon(Icons.message, size: 24),
                ),
                label: 'Messages',
              ),
              BottomNavigationBarItem(
                icon: Padding(
                  padding: EdgeInsets.only(bottom: 4),
                  child: Icon(Icons.person_outline, size: 24),
                ),
                activeIcon: Padding(
                  padding: EdgeInsets.only(bottom: 4),
                  child: Icon(Icons.person, size: 24),
                ),
                label: 'Profile',
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMessagingTab() {
    return Column(
      children: [
        // disconnected banner
        //if not connect to esp
        if (!_bleService.isConnected)
          GestureDetector(
            onTap: _connectToBle,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              color: Colors.orange.shade100,
              child: Row(
                children: [
                  const Icon(Icons.bluetooth_disabled, size: 18, color: Colors.orange),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      'Not connected to ESP32 — tap to connect',
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.orange,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  const Icon(Icons.chevron_right, size: 18, color: Colors.orange),
                ],
              ),
            ),
          ),

        // receiver ID bar
        // if empty then show grey text
        GestureDetector(
          onTap: _editReceiverId,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border(bottom: BorderSide(color: Colors.grey.shade200)),
            ),

            // input bar bottom
            child: Row(
              children: [
                const Icon(Icons.send, size: 15, color: Color(0xFF4FC3F7)),
                const SizedBox(width: 8),
                const Text('To: ', style: TextStyle(fontSize: 13, color: Colors.grey)),
                Text(
                  _receiverId.isEmpty ? 'Tap to set receiver ID' : '0x$_receiverId',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: _receiverId.isEmpty
                        ? Colors.grey[400]
                        : const Color(0xFF0288D1),
                    letterSpacing: _receiverId.isEmpty ? 0 : 1,
                  ),
                ),
                const Spacer(),
                const Icon(Icons.edit, size: 14, color: Color(0xFF4FC3F7)),
                const SizedBox(width: 4),
                const Text('change',
                    style: TextStyle(fontSize: 12, color: Color(0xFF4FC3F7))),
              ],
            ),
          ),
        ),

        // message list
        Expanded(
          child: Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xFFE3F2FD), Color(0xFFF5F9FC)],
              ),
            ),
            child: _messages.isEmpty
                ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.chat_bubble_outline,
                      size: 64, color: Colors.grey[300]),
                  const SizedBox(height: 16),
                  Text('No messages yet',
                      style:
                      TextStyle(color: Colors.grey[500], fontSize: 16)),
                  const SizedBox(height: 8),
                  Text('Send your first message!',
                      style:
                      TextStyle(color: Colors.grey[400], fontSize: 14)),
                ],
              ),
            )
                : ListView.builder(
              controller: _messageScrollController,
              padding: const EdgeInsets.all(16),
              itemCount: _messages.length,
              itemBuilder: (context, index) {
                final message = _messages[index];
                final isSent = message['isSent'] as bool? ?? false;
                final text = message['text'] as String? ?? '';
                final rawTime = message['time'];
                final time = rawTime is DateTime
                    ? rawTime
                    : DateTime.tryParse(rawTime.toString()) ??
                    DateTime.now();
                final status =
                    message['status'] as String? ?? 'pending';
                final retryCount =
                    message['retryCount'] as int? ?? 0;
                final Color bubbleColor =
                isSent ? const Color(0xFF4FC3F7) : Colors.white;
// long press -failed messages
                return GestureDetector(
                  onLongPress: (status == 'failed' && isSent)
                      ? () {
                    showModalBottomSheet(
                      context: context,
                      shape: const RoundedRectangleBorder(
                        borderRadius: BorderRadius.vertical(
                            top: Radius.circular(20)),
                      ),
                      builder: (context) => Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 40,
                              height: 4,
                              decoration: BoxDecoration(
                                color: Colors.grey[300],
                                borderRadius:
                                BorderRadius.circular(2),
                              ),
                            ),
                            const SizedBox(height: 20),
                            const Text('Message Failed',
                                style: TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w700)),
                            const SizedBox(height: 8),
                            Text(
                              'Tried $retryCount time(s). What do you want to do?',
                              style: TextStyle(
                                  color: Colors.grey[600]),
                            ),
                            const SizedBox(height: 24),
                            Row(
                              children: [
                                Expanded(
                                  child: OutlinedButton.icon(
                                    onPressed: () =>
                                        Navigator.pop(context),
                                    icon: const Icon(Icons.close,
                                        color: Colors.red),
                                    label: const Text('Dismiss',
                                        style: TextStyle(
                                            color: Colors.red)),
                                    style:
                                    OutlinedButton.styleFrom(
                                      side: const BorderSide(
                                          color: Colors.red),
                                      padding: const EdgeInsets
                                          .symmetric(vertical: 14),
                                      shape: RoundedRectangleBorder(
                                          borderRadius:
                                          BorderRadius.circular(
                                              12)),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: ElevatedButton.icon(
                                    onPressed: () {
                                      Navigator.pop(context);
                                      _retrySingleMessage(message);
                                    },
                                    icon: const Icon(Icons.refresh),
                                    label:
                                    const Text('Retry Now'),
                                    style:
                                    ElevatedButton.styleFrom(
                                      backgroundColor:
                                      const Color(0xFF4FC3F7),
                                      foregroundColor: Colors.white,
                                      padding: const EdgeInsets
                                          .symmetric(vertical: 14),
                                      shape: RoundedRectangleBorder(
                                          borderRadius:
                                          BorderRadius.circular(
                                              12)),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                          ],
                        ),
                      ),
                    );
                  }
                      : null,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Row(
                      mainAxisAlignment: isSent
                          ? MainAxisAlignment.end
                          : MainAxisAlignment.start,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        if (!isSent)
                          Container(
                            margin: const EdgeInsets.only(
                                right: 8, bottom: 2),
                            child: ClipOval(
                              child: Image.asset(
                                'assets/images/receiver.png',
                                width: 36,
                                height: 36,
                                fit: BoxFit.cover,
                              ),
                            ),
                          ),
                        Flexible(
                          child: Column(
                            crossAxisAlignment: isSent
                                ? CrossAxisAlignment.end
                                : CrossAxisAlignment.start,
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 16, vertical: 12),
                                constraints: BoxConstraints(
                                    maxWidth: MediaQuery.of(context)
                                        .size
                                        .width *
                                        0.72),
                                decoration: BoxDecoration(
                                  color: bubbleColor,
                                  borderRadius: BorderRadius.only(
                                    topLeft: Radius.circular(
                                        isSent ? 20 : 6),
                                    topRight: Radius.circular(
                                        isSent ? 6 : 20),
                                    bottomLeft:
                                    const Radius.circular(20),
                                    bottomRight:
                                    const Radius.circular(20),
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black
                                          .withOpacity(0.06),
                                      blurRadius: 8,
                                      offset: const Offset(0, 2),
                                    ),
                                  ],
                                ),
                                child: Column(
                                  crossAxisAlignment:
                                  CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      text,
                                      style: TextStyle(
                                        fontSize: 15,
                                        height: 1.4,
                                        color: isSent
                                            ? Colors.white
                                            : const Color(0xFF263238),
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}',
                                          style: TextStyle(
                                            fontSize: 11,
                                            color: isSent
                                                ? Colors.white
                                                .withOpacity(0.7)
                                                : Colors.grey[500],
                                          ),
                                        ),
                                        if (isSent) ...[
                                          const SizedBox(width: 4),
                                          status == 'failed'
                                              ? GestureDetector(
                                            onTap: () =>
                                                _retrySingleMessage(
                                                    message),
                                            child: const Icon(
                                                Icons.refresh,
                                                size: 14,
                                                color: Colors
                                                    .redAccent),
                                          )
                                              : _buildStatusIcon(status),
                                        ],
                                      ],
                                    ),
                                    if (status == 'failed' &&
                                        retryCount > 0)
                                      Padding(
                                        padding: const EdgeInsets.only(
                                            top: 4),
                                        child: Text(
                                          'Failed · $retryCount retries · Long press to retry',
                                          style: TextStyle(
                                            fontSize: 10,
                                            color: Colors.white
                                                .withOpacity(0.8),
                                            fontStyle: FontStyle.italic,
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (isSent)
                          Container(
                            margin: const EdgeInsets.only(
                                left: 8, bottom: 2),
                            child: ClipOval(
                              child: Image.asset(
                                'assets/images/sender.png',
                                width: 36,
                                height: 36,
                                fit: BoxFit.cover,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ),

        // input bar
        Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          decoration: BoxDecoration(
            color: Colors.white,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.05),
                blurRadius: 10,
                offset: const Offset(0, -2),
              )
            ],
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFFF5F9FC),
                    borderRadius: BorderRadius.circular(25),
                  ),
                  child: TextField(
                    controller: _messageController,
                    maxLines: null,
                    maxLength: 5000,
                    decoration: InputDecoration(
                      hintText: 'Type a message...',
                      hintStyle: TextStyle(color: Colors.grey[400]),
                      filled: false,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(25),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 20, vertical: 12),
                      counterText: '',
                    ),
                    style: const TextStyle(fontSize: 15),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Color(0xFF4FC3F7), Color(0xFF29B6F6)],
                  ),
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: Color(0x664FC3F7),
                      blurRadius: 8,
                      offset: Offset(0, 2),
                    ),
                  ],
                ),
                child: IconButton(
                  onPressed: _sendMessage,
                  icon: const Icon(Icons.send, color: Colors.white, size: 22),
                  padding: const EdgeInsets.all(12),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
//profile sections
  Widget _buildProfileTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          const SizedBox(height: 20),
          Container(
            width: 120,
            height: 120,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF4FC3F7).withOpacity(0.4),
                  blurRadius: 20,
                  offset: const Offset(0, 8),
                )
              ],
            ),
            child: ClipOval(
              child: Image.asset(
                'assets/images/sender.png',//profile
                width: 120,
                height: 120,
                fit: BoxFit.cover,
              ),
            ),
          ),
          const SizedBox(height: 24),
          Text(_userName,
              style: const TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF263238))),
          const SizedBox(height: 6),
          GestureDetector(
            onTap: _editName,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.edit, size: 14, color: Colors.grey[500]),
                const SizedBox(width: 4),
                Text('Edit name',
                    style: TextStyle(fontSize: 13, color: Colors.grey[500])),
              ],
            ),
          ),
          const SizedBox(height: 36),

          // ID card
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.06),
                  blurRadius: 16,
                  offset: const Offset(0, 4),
                )
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: const Color(0xFF4FC3F7).withOpacity(0.1),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(Icons.fingerprint,
                          color: Color(0xFF4FC3F7), size: 22),
                    ),
                    const SizedBox(width: 12),
                    const Text('Your Unique ID',
                        style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF263238))),
                  ],
                ),
                const SizedBox(height: 16),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 20, vertical: 16),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF5F9FC),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                        color: const Color(0xFF4FC3F7).withOpacity(0.3)),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        _userId.isEmpty
                            ? 'Loading...'
                            : '0x${_userId.toUpperCase()}',
                        style: const TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w800,
                            color: Color(0xFF0288D1),
                            letterSpacing: 2),
                      ),
                      Row(
                        children: [
                          GestureDetector(
                            onTap: _editUserId,
                            child: const Padding(
                              padding: EdgeInsets.only(right: 12),
                              child: Icon(Icons.edit,
                                  color: Color(0xFF4FC3F7), size: 22),
                            ),
                          ),
                          GestureDetector(
                            onTap: () {
                              if (_userId.isNotEmpty) {
                                Clipboard.setData(
                                    ClipboardData(text: _userId));
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('ID copied to clipboard!'),
                                    duration: Duration(seconds: 2),
                                    backgroundColor: Color(0xFF4FC3F7),
                                  ),
                                );
                              }
                            },
                            child: const Icon(Icons.copy,
                                color: Color(0xFF4FC3F7), size: 22),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Your hex ID (01 to FF). Share with others to receive messages.',
                  style: TextStyle(
                      fontSize: 13,
                      color: Colors.grey[500],
                      height: 1.5),
                ),
              ],
            ),
          ),

          const SizedBox(height: 20),

          // stats card
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.06),
                  blurRadius: 16,
                  offset: const Offset(0, 4),
                )
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: const Color(0xFF4FC3F7).withOpacity(0.1),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(Icons.bar_chart,
                          color: Color(0xFF4FC3F7), size: 22),
                    ),
                    const SizedBox(width: 12),
                    const Text('Message Stats',
                        style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF263238))),
                  ],
                ),
                const SizedBox(height: 20),
                // stats box
                Row(
                  children: [
                    Expanded(
                      child: _statBox(
                        'Sent',
                        '${_messages.where((m) => m['isSent'] == true).length}',
                        Icons.arrow_upward,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _statBox(
                        'Received',
                        '${_messages.where((m) => m['isSent'] == false).length}',
                        Icons.arrow_downward,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _statBox(
                        'Failed',
                        '${_messages.where((m) => m['status'] == 'failed').length}',
                        Icons.error_outline,
                        color: Colors.red,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          const SizedBox(height: 20),

          // connection status card
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.06),
                  blurRadius: 16,
                  offset: const Offset(0, 4),
                )
              ],
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: (_bleService.isConnected
                        ? Colors.green
                        : Colors.red)
                        .withOpacity(0.1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    _bleService.isConnected
                        ? Icons.bluetooth_connected
                        : Icons.bluetooth_disabled,
                    color:
                    _bleService.isConnected ? Colors.green : Colors.red,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 16),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('ESP32 Status',
                        style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF263238))),
                    const SizedBox(height: 4),
                    Text(
                      _bleService.isConnected
                          ? 'Connected to ${_bleService.deviceName}'
                          : 'Not connected',
                      style: TextStyle(fontSize: 13, color: Colors.grey[500]),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 30),
        ],
      ),
    );
  }

  Widget _statBox(String label, String value, IconData icon, {Color? color}) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFF5F9FC),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        children: [
          Icon(icon, color: color ?? const Color(0xFF4FC3F7), size: 20),
          const SizedBox(height: 8),
          Text(value,
              style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  color: color ?? const Color(0xFF263238))),
          const SizedBox(height: 4),
          Text(label,
              style: TextStyle(fontSize: 12, color: Colors.grey[500])),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _messageController.dispose();
    _messageScrollController.dispose();
    _bleService.dispose();
    super.dispose();
  }
}