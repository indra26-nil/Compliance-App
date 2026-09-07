const mongoose = require("mongoose");

const validationErrorSchema = new mongoose.Schema(
    {
        ruleCode: String,
        field: String,
        message: String,
        severity: {
            type: String,
            enum: ["ERROR", "WARNING"]
        }
    },
    {
        _id: false
    }
);

const validationResultSchema = new mongoose.Schema(
    {
        productId: {
            type: mongoose.Schema.Types.ObjectId,
            ref: "Product",
            required: true
        },

        status: {
            type: String,
            enum: ["PASS", "FAIL"],
            required: true
        },

        score: {
            type: Number,
            min: 0,
            max: 100,
            required: true
        },

        errors: {
            type: [validationErrorSchema],
            default: []
        },

        warnings: {
            type: [validationErrorSchema],
            default: []
        }
    },

    {
        timestamps: true
    }
);

module.exports = mongoose.model(
    "ValidationResult",
    validationResultSchema
);