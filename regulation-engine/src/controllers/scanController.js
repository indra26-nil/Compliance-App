const Scan = require("../models/scan");
const { saveFiles, toPublicUrl } = require("../services/storage");

const VALID_VERDICTS = ["compliant", "nonCompliant", "needsReview"];
const VALID_CATEGORIES = ["general", "food"];

function parseReportJson(raw) {
  if (!raw) return {};
  if (typeof raw === "object") return raw;
  try {
    return JSON.parse(String(raw));
  } catch {
    return {};
  }
}

// POST /api/scans (multipart/form-data) — authoritative server record.
// Parts: photos[] (1..N), fields: productName, category, reportJson
// (stringified ComplianceReport.toJson), ocrText, capturedAt, gpsLat/gpsLng.
async function createScan(req, res) {
  try {
    const { productName, category, reportJson, ocrText, capturedAt, gpsLat, gpsLng } =
      req.body || {};
    if (!productName || !String(productName).trim()) {
      return res.status(400).json({ success: false, message: "productName is required" });
    }
    const cat = String(category || "general").toLowerCase();
    if (!VALID_CATEGORIES.includes(cat)) {
      return res.status(400).json({ success: false, message: "category must be general|food" });
    }
    const report = parseReportJson(reportJson);
    const verdict = VALID_VERDICTS.includes(report.verdict) ? report.verdict : "needsReview";
    const score = Number.isFinite(Number(report.score)) ? Number(report.score) : 0;

    const stored = await saveFiles(req.files || [], req);
    const imageUrls = stored.map((s) => toPublicUrl(s, req));
    const thumbnailUrl = imageUrls[0] || "";

    const scan = await Scan.create({
      productName: String(productName).trim(),
      category: cat,
      imageUrls,
      thumbnailUrl,
      ocrText: String(ocrText || ""),
      reportJson: report,
      verdict,
      score,
      photoCount: imageUrls.length || Number(report.photoCount) || 1,
      meanConfidence: Number(report.meanConfidence) || 0,
      regionCount: Number(report.regionCount) || 0,
      officerId: req.auth?.sub,
      officerName: req.auth?.email || "",
      gps:
        gpsLat !== undefined && gpsLng !== undefined
          ? { lat: Number(gpsLat), lng: Number(gpsLng) }
          : undefined,
      capturedAt: capturedAt ? new Date(capturedAt) : new Date(),
      serverValidated: false,
    });

    // Server MAY re-run extraction + rules later; v1 trusts the device
    // verdict (offline-first) and marks corrected=false.
    return res.status(201).json({
      success: true,
      id: scan._id.toString(),
      verdict: scan.verdict,
      score: scan.score,
      corrected: false,
    });
  } catch (e) {
    return res
      .status(500)
      .json({ success: false, message: "Failed to save scan", error: e.message });
  }
}

// GET /api/scans?q=&verdict=&category=&page=&limit=
async function listScans(req, res) {
  try {
    const page = Math.max(1, parseInt(req.query.page || "1", 10) || 1);
    const limit = Math.min(100, Math.max(1, parseInt(req.query.limit || "20", 10) || 20));
    const filter = {};
    if (req.query.verdict && VALID_VERDICTS.includes(req.query.verdict)) {
      filter.verdict = req.query.verdict;
    }
    if (req.query.category && VALID_CATEGORIES.includes(String(req.query.category).toLowerCase())) {
      filter.category = String(req.query.category).toLowerCase();
    }
    if (req.query.q && String(req.query.q).trim()) {
      filter.$text = { $search: String(req.query.q).trim() };
    }
    // Officers see everything in v1 (supervisor/admin scoping can be added).
    const [total, docs] = await Promise.all([
      Scan.countDocuments(filter),
      Scan.find(filter)
        .sort({ createdAt: -1 })
        .skip((page - 1) * limit)
        .limit(limit),
    ]);
    const baseUrl = process.env.BASE_URL || `${req.protocol}://${req.get("host")}`;
    return res.json({
      success: true,
      page,
      total,
      scans: docs.map((d) => d.toListJson(baseUrl)),
    });
  } catch (e) {
    return res
      .status(500)
      .json({ success: false, message: "Failed to list scans", error: e.message });
  }
}

// GET /api/scans/:id — full detail (report JSON + image URLs).
async function getScanById(req, res) {
  try {
    const scan = await Scan.findById(req.params.id).populate("officerId", "name email role");
    if (!scan) return res.status(404).json({ success: false, message: "Scan not found" });
    const baseUrl = process.env.BASE_URL || `${req.protocol}://${req.get("host")}`;
    return res.json({
      success: true,
      scan: {
        id: scan._id.toString(),
        productName: scan.productName,
        category: scan.category,
        verdict: scan.verdict,
        score: scan.score,
        photoCount: scan.photoCount,
        imageUrls: scan.imageUrls.map((u) =>
          /^https?:\/\//i.test(u) ? u : baseUrl.replace(/\/$/, "") + (u.startsWith("/") ? u : "/" + u)
        ),
        thumbnailUrl: scan.toListJson(baseUrl).thumbnailUrl,
        ocrText: scan.ocrText,
        reportJson: scan.reportJson,
        meanConfidence: scan.meanConfidence,
        regionCount: scan.regionCount,
        officer: scan.officerId,
        officerName: scan.officerName,
        gps: scan.gps,
        capturedAt: scan.capturedAt,
        createdAt: scan.createdAt,
      },
    });
  } catch (e) {
    return res
      .status(500)
      .json({ success: false, message: "Failed to fetch scan", error: e.message });
  }
}

module.exports = { createScan, listScans, getScanById };
