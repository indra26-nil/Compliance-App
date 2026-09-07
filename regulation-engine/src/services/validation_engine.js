const validateProduct = (product, regulation) => {

    const errors = [];
    const warnings = [];

    /*
    -----------------------------------
    1. REQUIRED FIELD VALIDATION
    -----------------------------------
    */

    for (const field of regulation.requiredFields) {

        let value;

        if (field.includes(".")) {
            const parts = field.split(".");

            value = product;

            for (const part of parts) {
                value = value?.[part];
            }
        } else {
            value = product[field];
        }

        if (
            value === undefined ||
            value === null ||
            value === ""
        ) {
            errors.push({
                ruleCode: "REQUIRED_FIELD",
                field,
                message: `${field} is required`,
                severity: "ERROR"
            });
        }
    }

    /*
    -----------------------------------
    2. MRP VALIDATION
    -----------------------------------
    */

    if (product.mrp !== undefined) {

        if (typeof product.mrp !== "number") {

            errors.push({
                ruleCode: "PRICE_TYPE",
                field: "mrp",
                message: "MRP must be a number",
                severity: "ERROR"
            });

        } else if (product.mrp <= 0) {

            errors.push({
                ruleCode: "PRICE_002",
                field: "mrp",
                message: "MRP must be greater than zero",
                severity: "ERROR"
            });
        }
    }

    /*
    -----------------------------------
    3. SELLING PRICE VALIDATION
    -----------------------------------
    */

    if (
        product.mrp !== undefined &&
        product.sellingPrice !== undefined
    ) {

        if (product.sellingPrice > product.mrp) {

            errors.push({
                ruleCode: "PRICE_001",
                field: "sellingPrice",
                message: "Selling price cannot exceed MRP",
                severity: "ERROR"
            });
        }
    }

    /*
    -----------------------------------
    4. DATE VALIDATION
    -----------------------------------
    */

    if (
        product.manufacturingDate &&
        product.expiryDate
    ) {

        const manufacturingDate =
            new Date(product.manufacturingDate);

        const expiryDate =
            new Date(product.expiryDate);

        if (expiryDate <= manufacturingDate) {

            errors.push({
                ruleCode: "DATE_001",
                field: "expiryDate",
                message:
                    "Expiry date must be after manufacturing date",
                severity: "ERROR"
            });
        }
    }

    /*
    -----------------------------------
    5. EXPIRY VALIDATION
    -----------------------------------
    */

    if (product.expiryDate) {

        const expiryDate =
            new Date(product.expiryDate);

        const today = new Date();

        if (expiryDate < today) {

            errors.push({
                ruleCode: "DATE_002",
                field: "expiryDate",
                message: "Product has already expired",
                severity: "ERROR"
            });
        }
    }

    /*
    -----------------------------------
    6. MANUFACTURER VALIDATION
    -----------------------------------
    */

    if (product.manufacturer) {

        if (!product.manufacturer.name) {

            errors.push({
                ruleCode: "MANUFACTURER_001",
                field: "manufacturer.name",
                message: "Manufacturer name is required",
                severity: "ERROR"
            });
        }

        if (!product.manufacturer.address) {

            errors.push({
                ruleCode: "MANUFACTURER_002",
                field: "manufacturer.address",
                message: "Manufacturer address is required",
                severity: "ERROR"
            });
        }
    }

    /*
    -----------------------------------
    7. SCORE CALCULATION
    -----------------------------------
    */

    const totalErrors = errors.length;

    let score = 100;

    if (totalErrors > 0) {
        score = Math.max(0, 100 - totalErrors * 10);
    }

    /*
    -----------------------------------
    8. FINAL STATUS
    -----------------------------------
    */

    const status =
        errors.length === 0
            ? "PASS"
            : "FAIL";

    return {
        status,
        score,
        errors,
        warnings
    };
};

module.exports = validateProduct;