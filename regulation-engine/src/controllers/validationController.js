const Product = require("../models/product");
const Regulation = require("../models/regulation");
const ValidationResult = require("../models/ValidationResult");

const validateProductController = async (req, res) => {

    try {

        /*
        Get product from request
        */

        const productData = req.body;

        /*
        Find regulation according to category
        */

        const regulation = await Regulation.findOne({
            category: productData.category.toLowerCase()
        });

        if (!regulation) {

            return res.status(404).json({
                success: false,
                message:
                    `No regulation found for category: ${productData.category}`
            });
        }

        /*
        Create product
        */

        const product = await Product.create(productData);

        /*
        Run validation
        */

        const validateProduct =
            require("../services/validationEngine");

        const validation =
            validateProduct(product.toObject(), regulation);

        /*
        Save validation result
        */

        const validationResult =
            await ValidationResult.create({

                productId: product._id,

                status: validation.status,

                score: validation.score,

                errors: validation.errors,

                warnings: validation.warnings
            });

        /*
        Return response
        */

        res.status(201).json({

            success: true,

            message: "Product validation completed",

            result: {

                productId: product._id,

                status: validation.status,

                score: validation.score,

                errors: validation.errors,

                warnings: validation.warnings
            }
        });

    } catch (error) {

        res.status(500).json({

            success: false,

            message: "Validation failed",

            error: error.message
        });
    }
};


/*
-----------------------------------------
GET VALIDATION HISTORY
-----------------------------------------
*/

const getValidationHistory = async (req, res) => {

    try {

        const results =
            await ValidationResult.find()
                .populate("productId")
                .sort({ createdAt: -1 });

        res.json({

            success: true,

            count: results.length,

            results
        });

    } catch (error) {

        res.status(500).json({

            success: false,

            message: error.message
        });
    }
};


/*
-----------------------------------------
GET VALIDATION BY PRODUCT
-----------------------------------------
*/

const getValidationByProduct = async (req, res) => {

    try {

        const results =
            await ValidationResult.find({
                productId: req.params.productId
            })
            .sort({ createdAt: -1 });

        res.json({

            success: true,

            results
        });

    } catch (error) {

        res.status(500).json({

            success: false,

            message: error.message
        });
    }
};

module.exports = {
    validateProductController,
    getValidationHistory,
    getValidationByProduct
};