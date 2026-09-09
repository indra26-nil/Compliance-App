const express = require("express");
const { requireAuth } = require("../middleware/auth");
const upload = require("../middleware/upload");
const { createScan, listScans, getScanById } = require("../controllers/scanController");

const router = express.Router();

router.post("/", requireAuth, upload.array("photos", 8), createScan);
router.get("/", requireAuth, listScans);
router.get("/:id", requireAuth, getScanById);

module.exports = router;
