const bcrypt = require("bcryptjs");
const User = require("../models/user");
const { signToken } = require("../middleware/auth");

// POST /api/auth/login — { email, password } -> { token, user }
async function login(req, res) {
  try {
    const { email, password } = req.body || {};
    if (!email || !password) {
      return res
        .status(400)
        .json({ success: false, message: "email and password are required" });
    }
    const user = await User.findOne({ email: String(email).toLowerCase() });
    if (!user) {
      return res
        .status(401)
        .json({ success: false, message: "Invalid credentials" });
    }
    const ok = await bcrypt.compare(String(password), user.passwordHash);
    if (!ok) {
      return res
        .status(401)
        .json({ success: false, message: "Invalid credentials" });
    }
    return res.json({ success: true, token: signToken(user), user: user.toSafeJson() });
  } catch (e) {
    return res
      .status(500)
      .json({ success: false, message: "Login failed", error: e.message });
  }
}

// POST /api/auth/register — bootstrap: open only when zero users exist,
// afterwards admin-only. Body: { name, email, password, role? }
async function register(req, res) {
  try {
    const count = await User.countDocuments();
    const { name, email, password, role } = req.body || {};
    if (!name || !email || !password) {
      return res.status(400).json({
        success: false,
        message: "name, email and password are required",
      });
    }
    if (count > 0) {
      // Admin-only after bootstrap.
      if (!req.auth || req.auth.role !== "admin") {
        return res.status(403).json({
          success: false,
          message: "Only admins can create users (bootstrap already done)",
        });
      }
    }
    const exists = await User.findOne({ email: String(email).toLowerCase() });
    if (exists) {
      return res
        .status(409)
        .json({ success: false, message: "Email already registered" });
    }
    const passwordHash = await bcrypt.hash(String(password), 10);
    const user = await User.create({
      name,
      email: String(email).toLowerCase(),
      passwordHash,
      role: count === 0 ? "admin" : role || "officer",
    });
    return res
      .status(201)
      .json({ success: true, token: signToken(user), user: user.toSafeJson() });
  } catch (e) {
    return res
      .status(500)
      .json({ success: false, message: "Registration failed", error: e.message });
  }
}

async function me(req, res) {
  const user = await User.findById(req.auth.sub);
  if (!user) return res.status(404).json({ success: false, message: "User not found" });
  return res.json({ success: true, user: user.toSafeJson() });
}

module.exports = { login, register, me };
