const Scan = require("../models/scan");
const User = require("../models/user");
const { buildCsv } = require("../services/report_csv");
const { buildReportPdf } = require("../services/report_pdf");

// GET /api/reports/:id.pdf — signed archival copy.
async function reportPdf(req, res) {
  try {
    const scan = await Scan.findById(req.params.id);
    if (!scan) return res.status(404).json({ success: false, message: "Scan not found" });
    const officer = scan.officerId ? await User.findById(scan.officerId) : null;
    const pdf = await buildReportPdf(scan, officer);
    res.setHeader("Content-Type", "application/pdf");
    res.setHeader(
      "Content-Disposition",
      `attachment; filename="compliance-${scan._id}.pdf"`
    );
    return res.send(pdf);
  } catch (e) {
    return res.status(500).json({
      success: false,
      message: "Failed to render PDF",
      error: e.message,
    });
  }
}

// GET /api/reports.csv — same column order as the offline export.
async function reportsCsv(req, res) {
  try {
    const filter = {};
    if (req.query.verdict) filter.verdict = req.query.verdict;
    if (req.query.category) filter.category = String(req.query.category).toLowerCase();
    const scans = await Scan.find(filter).sort({ createdAt: -1 }).limit(10000);
    const csv = buildCsv(scans);
    res.setHeader("Content-Type", "text/csv");
    res.setHeader("Content-Disposition", 'attachment; filename="reports.csv"');
    return res.send(csv);
  } catch (e) {
    return res.status(500).json({
      success: false,
      message: "Failed to render CSV",
      error: e.message,
    });
  }
}

module.exports = { reportPdf, reportsCsv };
