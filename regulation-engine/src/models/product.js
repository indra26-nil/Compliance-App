const mongoose = require("mongoose");

const productSchema = new mongoose.Schema(
    {
        productName: {
            type: String,
            required: true,
            trim: true
        },

        brand: {
            type: String,
            required: true,
            trim: true
        },

        category: {
            type: String,
            required: true,
            lowercase: true,
            trim: true
        },

        mrp: {
            type: Number,
            required: true,
            min: 0
        },

        sellingPrice: {
            type: Number,
            required: true,
            min: 0
        },

        manufacturer: {
            name: {
                type: String,
                required: true,
                trim: true
            },

            address: {
                type: String,
                required: true,
                trim: true
            }
        },

        manufacturingDate: {
            type: Date,
            required: true
        },

        expiryDate: {
            type: Date,
            required: true
        },

        batchNumber: {
            type: String,
            required: true,
            trim: true
        },

        netQuantity: {
            type: String,
            required: true,
            trim: true
        }
    },

    {
        timestamps: true
    }
);

module.exports = mongoose.model("Product", productSchema);