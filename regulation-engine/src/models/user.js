const mongoose = require("mongoose");

// D — officer accounts. Roles: officer | supervisor | admin.
// Passwords are bcrypt hashes; JWT expiry 12h (see middleware/auth.js).
const userSchema = new mongoose.Schema(
  {
    name: { type: String, required: true, trim: true },
    email: {
      type: String,
      required: true,
      unique: true,
      lowercase: true,
      trim: true,
      index: true,
    },
    passwordHash: { type: String, required: true },
    role: {
      type: String,
      enum: ["officer", "supervisor", "admin"],
      default: "officer",
    },
  },
  { timestamps: true }
);

userSchema.methods.toSafeJson = function () {
  return {
    id: this._id.toString(),
    name: this.name,
    email: this.email,
    role: this.role,
  };
};

module.exports = mongoose.model("User", userSchema);
