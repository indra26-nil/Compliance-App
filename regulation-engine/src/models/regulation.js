const mongoose = require("mongoose");

const ruleSchema = new mongoose.Schema(
    {
        code: {
            type: String,
            required: true
        },

        name: {
            type: String,
            required: true
        },

        description: {
            type: String,
            required: true
        },

        severity: {
            type: String,
            enum: ["ERROR", "WARNING"],
            default: "ERROR"
        }
    },
    {
        _id: false
    }
);

const regulationSchema = new mongoose.Schema(
    {
        category: {
            type: String,
            required: true,
            unique: true,
            lowercase: true
        },

        requiredFields: {
            type: [String],
            required: true
        },

        rules: {
            type: [ruleSchema],
            default: []
        }
    },

    {
        timestamps: true
    }
);

module.exports = mongoose.model("Regulation", regulationSchema);    