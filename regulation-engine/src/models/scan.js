const mongoose = require("mongoose");

// D — authoritative server record for one product scan (1..N photos).
// Mirrors the Flutter offline row (ProductScanRecord) + ComplianceReport.toJson().
// Contract: docs/backend_api_contract.md §1 (POST /api/scans).
const scanSchema = new mongoose.Schema(
  {
    productName: { type: String, required: true, trim: true, index: true },
    category: {
      type: String,
      enum: ["general", "food"],
      default: "general",
      lowercase: true,
      index: true,
    },
    imageUrls: { type: [String], default: [] },
    thumbnailUrl: { type: String, default: "" },
    ocrText: { type: String, default: "" },
    // Verbatim ComplianceReport.toJson() from the device (audit + re-render).
    reportJson: { type: mongoose.Schema.Types.Mixed, default: {} },
    verdict: {
      type: String,
      enum: ["compliant", "nonCompliant", "needsReview"],
      default: "needsReview",
      index: true,
    },
    score: { type: Number, min: 0, max: 100, default: 0 },
    photoCount: { type: Number, default: 1 },
    meanConfidence: { type: Number, default: 0 },
    regionCount: { type: Number, default: 0 },
    officerId: {
      type: mongoose.Schema.Types.ObjectId,
      ref: "User",
      index: true,
    },
    officerName: { type: String, default: "" },
    gps: {
      lat: { type: Number },
      lng: { type: Number },
    },
    capturedAt: { type: Date },
    serverValidated: { type: Boolean, default: false },
  },
  { timestamps: true }
);

scanSchema.index({ createdAt: -1 });
scanSchema.index({ productName: "text", ocrText: "text" });

// List-view projection for GET /api/scans (shared repository / search).
scanSchema.methods.toListJson = function (baseUrl) {
  return {
    id: this._id.toString(),
    productName: this.productName,
    category: this.category,
    verdict: this.verdict,
    score: this.score,
    photoCount: this.photoCount,
    createdAt: this.createdAt,
    thumbnailUrl: absolutize(baseUrl, this.thumbnailUrl || this.imageUrls[0] || ""),
  };
};

function absolutize(baseUrl, url) {
  if (!url) return "";
  if (/^https?:\/\//i.test(url)) return url;
  if (!baseUrl) return url;
  return baseUrl.replace(/\/$/, "") + (url.startsWith("/") ? url : "/" + url);
}

module.exports = mongoose.model("Scan", scanSchema);
