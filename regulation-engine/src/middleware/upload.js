const multer = require("multer");

// Memory storage — src/services/storage.js decides local vs Cloudinary vs S3.
const upload = multer({
  storage: multer.memoryStorage(),
  limits: { fileSize: 12 * 1024 * 1024, files: 8 }, // 12 MB/file, ≤8 photos
  fileFilter: (req, file, cb) => {
    if (/^image\//.test(file.mimetype)) return cb(null, true);
    cb(new Error("Only image files are allowed (photos[])"));
  },
});

module.exports = upload;
