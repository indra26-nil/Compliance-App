const mongoose = require("mongoose");

const ruleSchema = new mongoose.Schema(
  {
    code: { type: String, required: true }, // frozen LM-R6-* codes
    name: { type: String, required: true },
    description: { type: String, required: true },
    clause: { type: String, default: "" }, // e.g. "PCR Rule 6(1)(a)"
    severity: {
      type: String,
      enum: ["ERROR", "WARNING", "REVIEW", "INFO"],
      default: "ERROR",
    },
  },
  { _id: false }
);

const regulationSchema = new mongoose.Schema(
  {
    category: {
      type: String,
      required: true,
      unique: true,
      lowercase: true,
    },
    // Bump when the gazette changes; mobile displays it on the report card.
    version: { type: String, default: "2026.09" },
    effectiveFrom: { type: Date },
    requiredFields: { type: [String], required: true },
    // R7 principal-display-panel schedule (mm).
    fontTable: {
      type: Map,
      of: Number,
      default: {
        "upto_100_cm2": 1,
        "100_to_500_cm2": 2,
        "500_to_2500_cm2": 4,
        "above_2500_cm2": 6,
      },
    },
    rules: { type: [ruleSchema], default: [] },
  },
  { timestamps: true }
);

module.exports = mongoose.model("Regulation", regulationSchema);
