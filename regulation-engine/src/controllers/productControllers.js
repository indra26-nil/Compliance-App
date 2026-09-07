const Product = require("../models/product");

const createProduct = async (req, res) => {

    try {

        const product = await Product.create(req.body);

        res.status(201).json({
            success: true,
            message: "Product created successfully",
            product
        });

    } catch (error) {

        res.status(400).json({
            success: false,
            message: "Failed to create product",
            error: error.message
        });
    }
};

const getProducts = async (req, res) => {

    try {

        const products = await Product.find()
            .sort({ createdAt: -1 });

        res.json({
            success: true,
            count: products.length,
            products
        });

    } catch (error) {

        res.status(500).json({
            success: false,
            message: "Failed to fetch products",
            error: error.message
        });
    }
};

const getProductById = async (req, res) => {

    try {

        const product = await Product.findById(req.params.id);

        if (!product) {

            return res.status(404).json({
                success: false,
                message: "Product not found"
            });
        }

        res.json({
            success: true,
            product
        });

    } catch (error) {

        res.status(500).json({
            success: false,
            message: error.message
        });
    }
};

module.exports = {
    createProduct,
    getProducts,
    getProductById
};