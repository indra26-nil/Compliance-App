import 'dart:convert';

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

/// One saved product-level scan (1..N photos of the SAME product).
///
/// This is the primary record type for the compliance workflow. The legacy
/// single-photo [OcrRecord] table is kept untouched for backward
/// compatibility; new scans go here.
///
/// [reportJson] holds the full `ComplianceReport.toJson()` map (verdict,
/// score, per-rule results, declarations, combined OCR text) so the report
/// card can be re-rendered offline without re-running OCR. Denormalised
/// [verdict]/[score] columns allow fast list sorting/filtering. See
/// `docs/backend_api_contract.md` — these field names match the future
/// `POST /api/scans` body.
class ProductScanRecord {
  const ProductScanRecord({
    this.id,
    required this.productName,
    required this.category,
    required this.imagePaths,
    required this.ocrText,
    required this.reportJson,
    required this.verdict,
    required this.score,
    required this.photoCount,
    required this.meanConfidence,
    required this.regionCount,
    required this.createdAt,
  });

  final int? id;
  final String productName;
  final String category;
  final List<String> imagePaths;
  final String ocrText;
  final Map<String, Object?> reportJson;
  final String verdict;
  final int score;
  final int photoCount;
  final double meanConfidence;
  final int regionCount;
  final DateTime createdAt;

  Map<String, Object?> toMap() => {
        'id': id,
        'productName': productName,
        'category': category,
        'imagePathsJson': jsonEncode(imagePaths),
        'ocrText': ocrText,
        'reportJson': jsonEncode(reportJson),
        'verdict': verdict,
        'score': score,
        'photoCount': photoCount,
        'meanConfidence': meanConfidence,
        'regionCount': regionCount,
        'createdAt': createdAt.millisecondsSinceEpoch,
      };

  factory ProductScanRecord.fromMap(Map<String, Object?> map) {
    List<String> paths = [];
    try {
      final decoded = jsonDecode(map['imagePathsJson'] as String? ?? '[]');
      if (decoded is List) paths = decoded.map((e) => e.toString()).toList();
    } catch (_) {}
    Map<String, Object?> report = {};
    try {
      final decoded = jsonDecode(map['reportJson'] as String? ?? '{}');
      if (decoded is Map) {
        report = Map<String, Object?>.from(decoded);
      }
    } catch (_) {}
    return ProductScanRecord(
      id: map['id'] as int?,
      productName: map['productName'] as String? ?? 'Unnamed product',
      category: map['category'] as String? ?? 'general',
      imagePaths: paths,
      ocrText: map['ocrText'] as String? ?? '',
      reportJson: report,
      verdict: map['verdict'] as String? ?? 'needsReview',
      score: (map['score'] as num?)?.toInt() ?? 0,
      photoCount: (map['photoCount'] as num?)?.toInt() ?? paths.length,
      meanConfidence: (map['meanConfidence'] as num?)?.toDouble() ?? 0,
      regionCount: (map['regionCount'] as num?)?.toInt() ?? 0,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
          (map['createdAt'] as int?) ?? 0),
    );
  }
}

/// Tiny SQLite store for OCR history.
///
/// Tables:
/// * `ocr_records` (v1, legacy single-photo OCR text) — kept as-is.
/// * `product_scans` (v2, product-level compliance scans) — the compliance
///   workflow reads/writes here.
class OcrStore {
  OcrStore._();
  static final OcrStore instance = OcrStore._();

  static const _dbName = 'ocr_history.db';
  static const _table = 'ocr_records';
  static const _productTable = 'product_scans';
  Database? _db;

  Future<Database> _open() async {
    if (_db != null) return _db!;
    final dir = await getDatabasesPath();
    _db = await openDatabase(
      p.join(dir, _dbName),
      version: 2,
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
        await _createProductTable(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        // v1 -> v2: add the product-level compliance table. Legacy rows stay.
        if (oldVersion < 2) {
          await _createProductTable(db);
        }
      },
    );
    return _db!;
  }

  static Future<void> _createProductTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $_productTable(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        productName TEXT NOT NULL DEFAULT 'Unnamed product',
        category TEXT NOT NULL DEFAULT 'general',
        imagePathsJson TEXT NOT NULL DEFAULT '[]',
        ocrText TEXT NOT NULL DEFAULT '',
        reportJson TEXT NOT NULL DEFAULT '{}',
        verdict TEXT NOT NULL DEFAULT 'needsReview',
        score INTEGER NOT NULL DEFAULT 0,
        photoCount INTEGER NOT NULL DEFAULT 1,
        meanConfidence REAL NOT NULL DEFAULT 0,
        regionCount INTEGER NOT NULL DEFAULT 0,
        createdAt INTEGER NOT NULL
      )
    ''');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_${_productTable}_createdAt ON $_productTable(createdAt DESC)');
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

  // ------------------------------------------------- product scans (v2) ---

  /// Insert one product-level compliance scan. Returns the new row id.
  Future<int> insertProductScan({
    required String productName,
    required String category,
    required List<String> imagePaths,
    required String ocrText,
    required Map<String, Object?> reportJson,
    required String verdict,
    required int score,
    required double meanConfidence,
    required int regionCount,
  }) async {
    final db = await _open();
    return db.insert(_productTable, {
      'productName': productName,
      'category': category,
      'imagePathsJson': jsonEncode(imagePaths),
      'ocrText': ocrText,
      'reportJson': jsonEncode(reportJson),
      'verdict': verdict,
      'score': score,
      'photoCount': imagePaths.length,
      'meanConfidence': meanConfidence,
      'regionCount': regionCount,
      'createdAt': DateTime.now().millisecondsSinceEpoch,
    });
  }

  Future<List<ProductScanRecord>> listProductScans({int limit = 200}) async {
    final db = await _open();
    final rows = await db.query(
      _productTable,
      orderBy: 'createdAt DESC',
      limit: limit,
    );
    return rows.map(ProductScanRecord.fromMap).toList();
  }

  Future<ProductScanRecord?> getProductScan(int id) async {
    final db = await _open();
    final rows =
        await db.query(_productTable, where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    return ProductScanRecord.fromMap(rows.first);
  }

  Future<int> updateProductScanName(int id, String productName) async {
    final db = await _open();
    return db.update(
      _productTable,
      {'productName': productName},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<int> deleteProductScan(int id) async {
    final db = await _open();
    return db.delete(_productTable, where: 'id = ?', whereArgs: [id]);
  }
}
