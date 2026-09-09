const express = require("express");
const cors = require("cors");
const helmet = require("helmet");
const morgan = require("morgan");
const path = require("path");
const rateLimit = require("express-rate-limit");

const productRoutes = require("./routes/productRoutes");
const validationRoutes = require("./routes/validationRoutes");
const regulationRoutes = require("./routes/regulationRoutes");
const authRoutes = require("./routes/authRoutes");
const scanRoutes = require("./routes/scanRoutes");
const dashboardRoutes = require("./routes/dashboardRoutes");
const reportRoutes = require("./routes/reportRoutes");
const { storageMode } = require("./services/storage");

const app = express();

// Middleware
// CSP allows Google Fonts (self-hosted look, CDN delivery). connectSrc stays
// open because the dashboard's Server field may point at another origin.
app.use(helmet({
  crossOriginResourcePolicy: false,
  contentSecurityPolicy: {
    directives: {
      defaultSrc: ["'self'"],
      styleSrc: ["'self'", "https://fonts.googleapis.com"],
      fontSrc: ["'self'", "https://fonts.gstatic.com"],
      imgSrc: ["'self'", "data:", "https:"],
      scriptSrc: ["'self'"],
      connectSrc: ["'self'", "http:", "https:"],
    },
  },
}));
app.use(cors());
app.use(express.json({ limit: "2mb" }));
app.use(express.urlencoded({ extended: true }));
app.use(morgan("tiny"));
app.use(
  rateLimit({ windowMs: 15 * 60 * 1000, max: 1000, standardHeaders: true })
);

// Static: uploaded label photos + enforcement dashboard (E) + homepage.
app.use("/uploads", express.static(path.join(__dirname, "..", "uploads")));
app.use(
  "/dashboard",
  express.static(path.join(__dirname, "..", "public", "dashboard"))
);
const landingDir = path.join(__dirname, "..", "public", "landing");
app.use("/landing", express.static(landingDir));

// Routes — D (core API)
app.use("/api/auth", authRoutes);
app.use("/api/scans", scanRoutes);
app.use("/api/dashboard", dashboardRoutes);
// reportRoutes carries its own /reports* paths (frozen contract).
app.use("/api", reportRoutes);

// Legacy prototype routes (kept, import-case bugs fixed).
app.use("/api/products", productRoutes);
app.use("/api/validations", validationRoutes);
app.use("/api/regulations", regulationRoutes);

// Root: browsers get the homepage, API clients/healthchecks keep the JSON
// contract (same URL, content negotiation — no redirect games).
app.get("/", (req, res) => {
  if (req.accepts("html")) {
    return res.sendFile(path.join(landingDir, "index.html"));
  }
  res.json({
    message: "Regulatory Product Validation API is running",
    storage: storageMode(),
    dashboard: "/dashboard",
    contract: [
      "POST /api/auth/login",
      "POST /api/scans (multipart)",
      "GET /api/scans",
      "GET /api/scans/:id",
      "GET /api/regulations",
      "GET /api/dashboard/summary",
      "GET /api/reports/:id.pdf",
      "GET /api/reports.csv",
    ],
  });
});

// Multer / upload errors -> 400 with the contract envelope.
app.use((err, req, res, next) => {
  if (err) {
    const status = err.status || 400;
    return res.status(status).json({
      success: false,
      message: err.message || "Request failed",
    });
  }
  next();
});

// 404
app.use((req, res) => {
  res.status(404).json({
    success: false,
    message: "Route not found",
  });
});

module.exports = app;
