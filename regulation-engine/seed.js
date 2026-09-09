require("dotenv").config();

const mongoose = require("mongoose");
const bcrypt = require("bcryptjs");

const Regulation = require("./src/models/regulation");
const User = require("./src/models/user");

// Frozen LM-R6-* catalog — mirrors Flutter lib/services/rule_engine.dart.
// Codes + CSV order must never be renamed (see docs/backend_api_contract.md).
const LM_RULES = [
  { code: "LM-R6-NAME", name: "Manufacturer / Packer / Importer", description: "Name + complete address of manufacturer/packer/importer", clause: "PCR Rule 6(1)(a)", severity: "ERROR" },
  { code: "LM-R6-COMMON", name: "Common / generic name", description: "Common or generic name of the commodity", clause: "PCR Rule 6(1)(b)", severity: "ERROR" },
  { code: "LM-R6-NETQ", name: "Net quantity", description: "Net quantity with standard unit (g/kg/ml/L/pcs)", clause: "PCR Rule 6(1)(c) + Rule 8", severity: "ERROR" },
  { code: "LM-R6-DATE-MFG", name: "Month + year (mfg/pack/import)", description: "Month and year of manufacture/packing/import", clause: "PCR Rule 6(1)(d)", severity: "ERROR" },
  { code: "LM-R6-DATE-EXP", name: "Expiry / use-by / best-before", description: "Expiry / best-before visible (food + perishables)", clause: "FSSAI + best practice", severity: "WARNING" },
  { code: "LM-R6-MRP", name: "Maximum Retail Price", description: "MRP present and greater than zero", clause: "PCR Rule 6(1)(e) + Rule 9", severity: "ERROR" },
  { code: "LM-R6-MRP-TAX", name: "MRP includes-taxes phrase", description: "'Inclusive of all taxes' wording next to MRP", clause: "PCR Rule 9", severity: "WARNING" },
  { code: "LM-R9-SINGLE-MRP", name: "Single MRP declaration", description: "Only one MRP declared (dual MRP flagged for review)", clause: "PCR Rule 9 (dual MRP prohibited)", severity: "REVIEW" },
  { code: "LM-R6-CARE", name: "Consumer-care details", description: "Consumer-care phone + email", clause: "PCR Rule 6(1)(f)", severity: "ERROR" },
  { code: "LM-R6-ORIGIN", name: "Country of origin (import)", description: "Country of origin when import is mentioned", clause: "Import proviso to Rule 6", severity: "ERROR" },
  { code: "LM-R6-BATCH", name: "Batch / lot / code", description: "Batch/lot/code for traceability", clause: "Traceability (with Rule 6(1)(d))", severity: "WARNING" },
  { code: "LM-FOOD-FSSAI", name: "FSSAI licence number", description: "14-digit FSSAI Lic. No. (food only)", clause: "FSS Act (food labels)", severity: "ERROR" },
  { code: "LM-READ-QUALITY", name: "Capture quality (OCR confidence)", description: "Legibility proxy via OCR confidence", clause: "Legibility requirement (proxy)", severity: "WARNING" },
  { code: "LM-R7-FONT", name: "Declaration font size (R7 table)", description: "Manual-review gate against the R7 schedule", clause: "PCR Rule 7 schedule", severity: "REVIEW" },
];

const regulations = [
  {
    category: "general",
    version: "2026.09",
    effectiveFrom: new Date("2026-09-01"),
    requiredFields: ["productName", "category", "mrp", "manufacturer", "netQty"],
    fontTable: {
      "upto_100_cm2": 1,
      "100_to_500_cm2": 2,
      "500_to_2500_cm2": 4,
      "above_2500_cm2": 6,
    },
    rules: LM_RULES.filter((r) => r.code !== "LM-FOOD-FSSAI"),
  },
  {
    category: "food",
    version: "2026.09",
    effectiveFrom: new Date("2026-09-01"),
    requiredFields: ["productName", "category", "mrp", "manufacturer", "netQty", "fssai"],
    fontTable: {
      "upto_100_cm2": 1,
      "100_to_500_cm2": 2,
      "500_to_2500_cm2": 4,
      "above_2500_cm2": 6,
    },
    rules: LM_RULES,
  },
];

const seedDatabase = async () => {
  try {
    if (!process.env.MONGO_URI) {
      console.error("MONGO_URI is not set — copy .env.example to .env first.");
      process.exit(1);
    }
    await mongoose.connect(process.env.MONGO_URI);
    console.log("MongoDB connected");

    await Regulation.deleteMany({});
    await Regulation.insertMany(regulations);
    console.log("Regulations inserted (general + food, LM-R6-* catalog)");

    // Demo accounts (passwords from env or defaults — change after first login).
    const officerPass = process.env.SEED_OFFICER_PASSWORD || "officer123";
    const adminPass = process.env.SEED_ADMIN_PASSWORD || "admin123";
    await User.deleteMany({ email: { $in: ["officer@gov.in", "admin@gov.in"] } });
    await User.create([
      {
        name: "Field Officer",
        email: "officer@gov.in",
        passwordHash: await bcrypt.hash(officerPass, 10),
        role: "officer",
      },
      {
        name: "Administrator",
        email: "admin@gov.in",
        passwordHash: await bcrypt.hash(adminPass, 10),
        role: "admin",
      },
    ]);
    console.log("Demo users: officer@gov.in / admin@gov.in");

    await mongoose.connection.close();
    console.log("Seed complete.");
  } catch (error) {
    console.error(error);
    process.exit(1);
  }
};

seedDatabase();
