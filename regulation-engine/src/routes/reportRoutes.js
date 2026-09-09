const express = require("express");
const { requireAuth } = require("../middleware/auth");
const { reportPdf, reportsCsv } = require("../controllers/reportController");

const router = express.Router();

// Mounted at /api in app.js so the paths match the frozen contract:
//   GET /api/reports.csv   +   GET /api/reports/:id.pdf
router.get("/reports.csv", requireAuth, reportsCsv);
router.get("/reports/:id.pdf", requireAuth, reportPdf);

module.exports = router;
