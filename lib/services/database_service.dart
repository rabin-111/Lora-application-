import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

class DatabaseService {
  static Database? _db;

  static Future<void> init() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'loranet.db');

    _db = await openDatabase(
      path,
      version: 3,
      onCreate: (db, version) async {
        await _createAllTables(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        // Drop and recreate everything on upgrade
        await db.execute("DROP TABLE IF EXISTS messages");
        await db.execute("DROP TABLE IF EXISTS settings");
        await db.execute("DROP TABLE IF EXISTS contacts");
        await db.execute("DROP TABLE IF EXISTS friend_requests");
        await _createAllTables(db);
      },
    );
  }
// message table
  static Future<void> _createAllTables(Database db) async {
    await db.execute('''
      CREATE TABLE messages (
        id            INTEGER PRIMARY KEY AUTOINCREMENT,
        message_id    INTEGER NOT NULL,
        type          TEXT    NOT NULL,
        sender_id     INTEGER NOT NULL,
        receiver_id   INTEGER NOT NULL,
        text          TEXT    NOT NULL,
        status        TEXT    NOT NULL DEFAULT 'pending',
        retry_count   INTEGER NOT NULL DEFAULT 0,
        timestamp     INTEGER NOT NULL
      )
    ''');
// settings table
    await db.execute('''
      CREATE TABLE settings (
        key   TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');

    // contacts = accepted friends( which is not used now)
    await db.execute('''
      CREATE TABLE contacts (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        hex_id      TEXT    NOT NULL UNIQUE,
        nickname    TEXT    NOT NULL DEFAULT '',
        added_at    INTEGER NOT NULL
      )
    ''');

    // friend_requests — both incoming and outgoing( which is not used now)
    await db.execute('''
      CREATE TABLE friend_requests (
        id            INTEGER PRIMARY KEY AUTOINCREMENT,
        hex_id        TEXT    NOT NULL,
        direction     TEXT    NOT NULL,
        status        TEXT    NOT NULL DEFAULT 'pending',
        message_text  TEXT    NOT NULL DEFAULT '',
        timestamp     INTEGER NOT NULL
      )
    ''');
  }

  // ── MESSAGES ─────────────────────────────────────────────────────────────
//message is saved in db before transmission
  static Future<int> saveMessage({
    required int messageId,
    required String type,
    required int senderId,
    required int receiverId,
    required String text,
    String status = 'pending',// initially status is set to pending paxi update hunxa
  }) async {
    return await _db!.insert('messages', {
      'message_id': messageId % 256,
      'type': type,
      'sender_id': senderId % 256,
      'receiver_id': receiverId % 256,
      'text': text,
      'status': status,
      'retry_count': 0,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });
  }
// update the status as per the condition
  static Future<void> updateMessageStatus(int id, String status) async {
    await _db!.update(
      'messages',
      {'status': status},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  static Future<void> incrementRetry(int id) async {
    await _db!.rawUpdate(
      'UPDATE messages SET retry_count = retry_count + 1, status = ? WHERE id = ?',
      ['failed', id],
    );
  }
//compare sender id and user id and if match
  //isSent =true right blue bubble dekhinxa and if not match white bubble dekhinxa

  static Future<List<Map<String, dynamic>>> loadMessages() async {
    final rows = await _db!.query('messages', orderBy: 'timestamp ASC');
    final savedId = await _loadSetting('user_id');
    final myId = int.tryParse(savedId ?? '0', radix: 16) ?? 0;

    return rows.map((row) {
      final senderId = row['sender_id'] as int;
      return {
        'id': row['id'],
        'messageId': row['message_id'],
        'type': row['type'],
        'senderId': senderId,
        'receiverId': row['receiver_id'],
        'text': row['text'],
        'status': row['status'],
        'retryCount': row['retry_count'],
        'isSent': senderId == myId,
        'time': DateTime.fromMillisecondsSinceEpoch(row['timestamp'] as int),
      };
    }).toList();
  }

  static Future<List<Map<String, dynamic>>> getFailedMessages() async {
    final rows = await _db!.query(
      'messages',
      where: "status IN ('pending', 'failed')",
      orderBy: 'timestamp ASC',
    );
    return rows.map((row) => {
      'id': row['id'],
      'messageId': row['message_id'],
      'type': row['type'],
      'senderId': row['sender_id'],
      'receiverId': row['receiver_id'],
      'text': row['text'],
      'retryCount': row['retry_count'],
    }).toList();
  }

  // ── CONTACTS ──────────────────────────────────────────────────────────────

  static Future<void> addContact(String hexId, {String nickname = ''}) async {
    await _db!.insert(
      'contacts',
      {
        'hex_id': hexId.toUpperCase(),
        'nickname': nickname,
        'added_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  static Future<void> updateContactNickname(String hexId, String nickname) async {
    await _db!.update(
      'contacts',
      {'nickname': nickname},
      where: 'hex_id = ?',
      whereArgs: [hexId.toUpperCase()],
    );
  }

  static Future<void> removeContact(String hexId) async {
    await _db!.delete(
      'contacts',
      where: 'hex_id = ?',
      whereArgs: [hexId.toUpperCase()],
    );
  }

  static Future<List<Map<String, dynamic>>> getContacts() async {
    final rows = await _db!.query('contacts', orderBy: 'added_at ASC');
    return rows.map((row) => {
      'id': row['id'],
      'hexId': row['hex_id'],
      'nickname': row['nickname'],
      'addedAt': DateTime.fromMillisecondsSinceEpoch(row['added_at'] as int),
    }).toList();
  }

  static Future<bool> isContact(String hexId) async {
    final rows = await _db!.query(
      'contacts',
      where: 'hex_id = ?',
      whereArgs: [hexId.toUpperCase()],
    );
    return rows.isNotEmpty;
  }

  // ── FRIEND REQUESTS ───────────────────────────────────────────────────────

  /// direction: 'outgoing' | 'incoming'
  /// status: 'pending' | 'accepted' | 'rejected'
  static Future<int> saveFriendRequest({
    required String hexId,
    required String direction,
    String status = 'pending',
    String messageText = '',
  }) async {
    // Check if one already exists for this hexId + direction
    final existing = await _db!.query(
      'friend_requests',
      where: 'hex_id = ? AND direction = ?',
      whereArgs: [hexId.toUpperCase(), direction],
    );
    if (existing.isNotEmpty) {
      return existing.first['id'] as int;
    }
    return await _db!.insert('friend_requests', {
      'hex_id': hexId.toUpperCase(),
      'direction': direction,
      'status': status,
      'message_text': messageText,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });
  }

  static Future<void> updateFriendRequestStatus(String hexId, String direction, String status) async {
    await _db!.update(
      'friend_requests',
      {'status': status},
      where: 'hex_id = ? AND direction = ?',
      whereArgs: [hexId.toUpperCase(), direction],
    );
  }

  static Future<List<Map<String, dynamic>>> getPendingIncomingRequests() async {
    final rows = await _db!.query(
      'friend_requests',
      where: "direction = 'incoming' AND status = 'pending'",
      orderBy: 'timestamp DESC',
    );
    return rows.map((row) => {
      'id': row['id'],
      'hexId': row['hex_id'],
      'direction': row['direction'],
      'status': row['status'],
      'messageText': row['message_text'],
      'timestamp': DateTime.fromMillisecondsSinceEpoch(row['timestamp'] as int),
    }).toList();
  }

  static Future<List<Map<String, dynamic>>> getAllFriendRequests() async {
    final rows = await _db!.query('friend_requests', orderBy: 'timestamp DESC');
    return rows.map((row) => {
      'id': row['id'],
      'hexId': row['hex_id'],
      'direction': row['direction'],
      'status': row['status'],
      'messageText': row['message_text'],
      'timestamp': DateTime.fromMillisecondsSinceEpoch(row['timestamp'] as int),
    }).toList();
  }

  static Future<String?> getFriendRequestStatus(String hexId, String direction) async {
    final rows = await _db!.query(
      'friend_requests',
      where: 'hex_id = ? AND direction = ?',
      whereArgs: [hexId.toUpperCase(), direction],
    );
    if (rows.isEmpty) return null;
    return rows.first['status'] as String;
  }

  // ── SETTINGS ──────────────────────────────────────────────────────────────

  static Future<void> _saveSetting(String key, String value) async {
    await _db!.insert(
      'settings',
      {'key': key, 'value': value},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  static Future<String?> _loadSetting(String key) async {
    final rows = await _db!.query('settings', where: 'key = ?', whereArgs: [key]);
    if (rows.isEmpty) return null;
    return rows.first['value'] as String;
  }

  static Future<void> saveUserId(String id) async => _saveSetting('user_id', id);
  static Future<String?> getUserId() async => _loadSetting('user_id');

  static Future<void> saveUserName(String name) async => _saveSetting('user_name', name);
  static Future<String?> getUserName() async => _loadSetting('user_name');
}