// Storage abstraction — local `uploads/` first, Cloudinary/S3 env swap later.
//
// Why this choice (SIH-friendly):
//  - Local disk: zero cost, zero setup, works on first `npm run dev`.
//  - Cloudinary (recommended for hosting): free tier, URL-based images, no
//    bucket CORS/IAM pain. Set CLOUDINARY_CLOUD_NAME + API_KEY + API_SECRET
//    and uploads go there automatically.
//  - S3-compatible (alternative): set S3_BUCKET (+ S3_REGION, AWS creds) and
//    extend `uploadBuffer` — the Scan model already stores plain URLs so the
//    swap is invisible to the app/dashboard.
//
// The Flutter app and dashboard only ever see final URLs (`imageUrls[]`).
const path = require("path");
const fs = require("fs");

let cloudinary = null;
if (
  process.env.CLOUDINARY_CLOUD_NAME &&
  process.env.CLOUDINARY_API_KEY &&
  process.env.CLOUDINARY_API_SECRET
) {
  cloudinary = require("cloudinary").v2;
  cloudinary.config({
    cloud_name: process.env.CLOUDINARY_CLOUD_NAME,
    api_key: process.env.CLOUDINARY_API_KEY,
    api_secret: process.env.CLOUDINARY_API_SECRET,
  });
}

function storageMode() {
  if (cloudinary) return "cloudinary";
  if (process.env.S3_BUCKET) return "s3-stub";
  return "local";
}

// Multer storage: keep files in memory; we persist via saveFiles() so the
// Cloudinary/local decision lives in one place.
function saveFiles(files, req) {
  if (cloudinary) return saveToCloudinary(files);
  if (process.env.S3_BUCKET) return saveToS3Stub(files);
  return saveToLocal(files, req);
}

function saveToLocal(files, req) {
  const dir = path.join(__dirname, "..", "..", "uploads");
  fs.mkdirSync(dir, { recursive: true });
  const baseUrl =
    process.env.BASE_URL ||
    (req ? `${req.protocol}://${req.get("host")}` : "");
  return (files || []).map((f) => {
    const safe = `${Date.now()}-${Math.round(Math.random() * 1e6)}${path.extname(
      f.originalname || ".jpg"
    )}`;
    fs.writeFileSync(path.join(dir, safe), f.buffer);
    const rel = `/uploads/${safe}`;
    return {
      url: rel, // absolutized by callers via BASE_URL when needed
      absoluteUrl: baseUrl ? baseUrl.replace(/\/$/, "") + rel : rel,
      path: path.join(dir, safe),
    };
  });
}

function saveToCloudinary(files) {
  // Upload buffers to Cloudinary (folder: compliance-scans).
  return Promise.all(
    (files || []).map(
      (f) =>
        new Promise((resolve, reject) => {
          const stream = cloudinary.uploader.upload_stream(
            { folder: "compliance-scans", resource_type: "image" },
            (err, result) => {
              if (err) return reject(err);
              resolve({
                url: result.secure_url,
                absoluteUrl: result.secure_url,
                path: result.public_id,
              });
            }
          );
          stream.end(f.buffer);
        })
    )
  );
}

function saveToS3Stub(files) {
  // S3 env swap point: wire @aws-sdk/client-s3 PutObjectCommand here.
  // For now behave like local but flag the mode so operators notice.
  console.warn(
    "[storage] S3_BUCKET is set but the S3 uploader is not wired — " +
      "storing locally. See src/services/storage.js saveToS3Stub()."
  );
  return saveToLocal(files);
}

function toPublicUrl(stored, req) {
  if (!stored) return "";
  if (/^https?:\/\//i.test(stored.url || "")) return stored.url;
  const base =
    process.env.BASE_URL ||
    (req ? `${req.protocol}://${req.get("host")}` : "");
  const rel = stored.url || "";
  if (!base) return rel;
  return base.replace(/\/$/, "") + (rel.startsWith("/") ? rel : "/" + rel);
}

module.exports = { storageMode, saveFiles, toPublicUrl };
