const express = require("express");
const cors = require("cors");

const productRoutes =
    require("./routes/productRoutes");

const validationRoutes =
    require("./routes/validationRoutes");

const regulationRoutes =
    require("./routes/regulationRoutes");

const app = express();


// Middleware

app.use(cors());

app.use(express.json());


// Routes

app.use(
    "/api/products",
    productRoutes
);

app.use(
    "/api/validations",
    validationRoutes
);

app.use(
    "/api/regulations",
    regulationRoutes
);


// Health check

app.get("/", (req, res) => {

    res.json({
        message:
            "Regulatory Product Validation API is running"
    });

});


// 404

app.use((req, res) => {

    res.status(404).json({

        success: false,

        message: "Route not found"

    });

});


module.exports = app;