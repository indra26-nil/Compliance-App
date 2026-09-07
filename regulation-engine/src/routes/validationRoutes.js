const express = require("express");

const {
    validateProductController,
    getValidationHistory,
    getValidationByProduct
} = require("../controllers/validationController");

const router = express.Router();

router.post(
    "/",
    validateProductController
);

router.get(
    "/",
    getValidationHistory
);

router.get(
    "/product/:productId",
    getValidationByProduct
);

module.exports = router;