// F — CSV export. Header order is FROZEN: identical to the offline export
// (Flutter ExportService.headers, 31 columns). Guarantee: a server CSV and a
// device CSV for the same scans are diff-able modulo id/photo_paths
// (URLs vs local paths).
const HEADERS = [
  "id",
  "product_name",
  "category",
  "scanned_at",
  "verdict",
  "score",
  "photo_count",
  "mean_confidence",
  "region_count",
  "generic_name",
  "brand",
  "net_qty_raw",
  "net_qty_value",
  "net_qty_unit",
  "mrp_raw",
  "mrp_value",
  "mrp_tax_phrase",
  "mfg_raw",
  "exp_raw",
  "manufacturer_name",
  "manufacturer_address",
  "care_phone",
  "care_email",
  "country_of_origin",
  "batch_no",
  "fssai_lic",
  "fail_count",
  "warning_count",
  "review_count",
  "failed_rule_codes",
  "photo_paths",
  "unverified_rule_codes",
];

function obs(reportJson, field) {
  try {
    const fields = reportJson?.declarations?.fields || {};
    return fields[field] || {};
  } catch {
    return {};
  }
}
function val(reportJson, field) {
  return obs(reportJson, field).value || "";
}
function data(reportJson, field, key) {
  const d = obs(reportJson, field).data || {};
  const v = d[key];
  return v === undefined || v === null ? "" : String(v);
}
function codes(reportJson, pred) {
  try {
    return (reportJson?.results || []).filter(pred).map((r) => r.code).join(";");
  } catch {
    return "";
  }
}

function scanToRow(scan) {
  const r = scan.reportJson || {};
  const ocrText = scan.ocrText || "";
  const taxPhrase = /inclusive\s+of\s+all\s+taxes?/i.test(ocrText) ? "yes" : "no";
  const results = r.results || [];
  const failCount = results.filter((x) => x.status === "fail").length;
  const warningCount = results.filter((x) => x.status === "warning").length;
  const reviewCount = results.filter((x) => x.status === "manualReview").length;
  return [
    String(scan._id),
    scan.productName || "",
    scan.category || "",
    (scan.createdAt || new Date()).toISOString(),
    scan.verdict || "",
    String(scan.score ?? ""),
    String(scan.photoCount ?? ""),
    Number(scan.meanConfidence || 0).toFixed(2),
    String(scan.regionCount ?? ""),
    val(r, "genericName"),
    val(r, "brand"),
    val(r, "netQty"),
    data(r, "netQty", "value"),
    data(r, "netQty", "unit"),
    val(r, "mrp"),
    data(r, "mrp", "value"),
    taxPhrase,
    val(r, "mfg"),
    val(r, "exp"),
    val(r, "manufacturer"),
    data(r, "manufacturer", "address"),
    val(r, "carePhone"),
    val(r, "careEmail"),
    val(r, "origin"),
    val(r, "batch"),
    val(r, "fssai"),
    String(failCount),
    String(warningCount),
    String(reviewCount),
    codes(r, (x) => x.status === "fail"),
    (scan.imageUrls || []).join(";"),
    codes(r, (x) => x.status === "unverified"),
  ];
}

function cell(v) {
  const s = String(v ?? "");
  if (/[",\n\r]/.test(s)) return '"' + s.replace(/"/g, '""') + '"';
  return s;
}

function buildCsv(scans) {
  const lines = [HEADERS.map(cell).join(",")];
  for (const s of scans) lines.push(scanToRow(s).map(cell).join(","));
  return lines.join("\n") + "\n";
}

module.exports = { HEADERS, scanToRow, buildCsv };
