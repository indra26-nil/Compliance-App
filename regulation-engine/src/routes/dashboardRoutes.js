const express = require("express");
const { requireAuth } = require("../middleware/auth");
const { summary } = require("../controllers/dashboardController");

const router = express.Router();

router.get("/summary", requireAuth, summary);

module.exports = router;
