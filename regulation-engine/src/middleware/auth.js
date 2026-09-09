const jwt = require("jsonwebtoken");

function signToken(user) {
  const secret = process.env.JWT_SECRET || "dev-only-secret-change-me";
  return jwt.sign(
    { sub: user._id.toString(), role: user.role, email: user.email },
    secret,
    { expiresIn: process.env.JWT_EXPIRES || "12h" }
  );
}

// All routes below require `Authorization: Bearer <jwt>`.
function requireAuth(req, res, next) {
  const header = req.headers.authorization || "";
  const token = header.startsWith("Bearer ") ? header.slice(7) : null;
  if (!token) {
    return res
      .status(401)
      .json({ success: false, message: "Missing bearer token" });
  }
  try {
    const secret = process.env.JWT_SECRET || "dev-only-secret-change-me";
    req.auth = jwt.verify(token, secret);
    next();
  } catch (e) {
    return res
      .status(401)
      .json({ success: false, message: "Invalid or expired token" });
  }
}

function requireRole(...roles) {
  return (req, res, next) => {
    if (!req.auth || !roles.includes(req.auth.role)) {
      return res
        .status(403)
        .json({ success: false, message: "Forbidden for role " + (req.auth && req.auth.role) });
    }
    next();
  };
}

module.exports = { signToken, requireAuth, requireRole };
