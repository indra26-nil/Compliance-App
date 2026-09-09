const express = require("express");
const { login, register, me } = require("../controllers/authController");
const { requireAuth } = require("../middleware/auth");

const router = express.Router();

router.post("/login", login);
// Bootstrap-open when zero users exist, admin-only afterwards.
router.post("/register", (req, res, next) => {
  if (req.headers.authorization) return requireAuth(req, res, () => register(req, res));
  return register(req, res);
});
router.get("/me", requireAuth, me);

module.exports = router;
