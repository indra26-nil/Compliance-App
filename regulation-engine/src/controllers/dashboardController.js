const Scan = require("../models/scan");

// GET /api/dashboard/summary — KPIs, top violations, recent.
async function summary(req, res) {
  try {
    const [totalScans, byVerdictAgg, recent, allReports] = await Promise.all([
      Scan.countDocuments(),
      Scan.aggregate([{ $group: { _id: "$verdict", count: { $sum: 1 } } }]),
      Scan.find().sort({ createdAt: -1 }).limit(10),
      Scan.find({}, { reportJson: 1 }).limit(2000),
    ]);
    const byVerdict = { compliant: 0, nonCompliant: 0, needsReview: 0 };
    for (const row of byVerdictAgg) {
      if (row._id in byVerdict) byVerdict[row._id] = row.count;
    }
    const passRate = totalScans ? byVerdict.compliant / totalScans : 0;

    // Top violated rule codes across recent reports (fail-only).
    const counts = {};
    for (const s of allReports) {
      const results = s.reportJson?.results || [];
      for (const r of results) {
        if (r.status === "fail" && r.code) counts[r.code] = (counts[r.code] || 0) + 1;
      }
    }
    const topViolations = Object.entries(counts)
      .map(([code, count]) => ({ code, count }))
      .sort((a, b) => b.count - a.count)
      .slice(0, 8);

    const baseUrl = process.env.BASE_URL || `${req.protocol}://${req.get("host")}`;
    return res.json({
      success: true,
      totalScans,
      passRate,
      byVerdict,
      topViolations,
      recent: recent.map((d) => ({
        id: d._id.toString(),
        productName: d.productName,
        verdict: d.verdict,
        score: d.score,
      })),
      _baseUrl: baseUrl,
    });
  } catch (e) {
    return res.status(500).json({
      success: false,
      message: "Failed to build dashboard summary",
      error: e.message,
    });
  }
}

module.exports = { summary };
