import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// One saved OCR scan.
class OcrRecord {
  const OcrRecord({
    this.id,
    required this.imagePath,
    required this.extractedText,
    required this.createdAt,
  });

  final int? id;
  final String imagePath;
  final String extractedText;
  final DateTime createdAt;

  Map<String, Object?> toMap() => {
        'id': id,
        'imagePath': imagePath,
        'extractedText': extractedText,
        'createdAt': createdAt.millisecondsSinceEpoch,
      };

  factory OcrRecord.fromMap(Map<String, Object?> map) => OcrRecord(
        id: map['id'] as int?,
        imagePath: map['imagePath'] as String,
        extractedText: map['extractedText'] as String? ?? '',
        createdAt: DateTime.fromMillisecondsSinceEpoch(
            (map['createdAt'] as int?) ?? 0),
      );
}

/// Tiny SQLite store for OCR history.
///
/// Table: `ocr_records(id INTEGER PK, imagePath TEXT, extractedText TEXT,
/// createdAt INTEGER)`.
class OcrStore {
  OcrStore._();
  static final OcrStore instance = OcrStore._();

  static const _dbName = 'ocr_history.db';
  static const _table = 'ocr_records';
  Database? _db;

  Future<Database> _open() async {
    if (_db != null) return _db!;
    final dir = await getDatabasesPath();
    _db = await openDatabase(
      p.join(dir, _dbName),
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE $_table(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            imagePath TEXT NOT NULL,
            extractedText TEXT NOT NULL DEFAULT '',
            createdAt INTEGER NOT NULL
          )
        ''');
        await db.execute(
            'CREATE INDEX idx_${_table}_createdAt ON $_table(createdAt DESC)');
      },
    );
    return _db!;
  }

  Future<int> insert({
    required String imagePath,
    required String extractedText,
  }) async {
    final db = await _open();
    return db.insert(_table, {
      'imagePath': imagePath,
      'extractedText': extractedText,
      'createdAt': DateTime.now().millisecondsSinceEpoch,
    });
  }

  Future<List<OcrRecord>> listRecent({int limit = 100}) async {
    final db = await _open();
    final rows = await db.query(
      _table,
      orderBy: 'createdAt DESC',
      limit: limit,
    );
    return rows.map(OcrRecord.fromMap).toList();
  }

  Future<OcrRecord?> getById(int id) async {
    final db = await _open();
    final rows = await db.query(_table, where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    return OcrRecord.fromMap(rows.first);
  }

  Future<int> updateText(int id, String newText) async {
    final db = await _open();
    return db.update(
      _table,
      {'extractedText': newText},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<int> delete(int id) async {
    final db = await _open();
    return db.delete(_table, where: 'id = ?', whereArgs: [id]);
  }
}
