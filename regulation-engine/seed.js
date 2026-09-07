require("dotenv").config();

const mongoose = require("mongoose");

const Regulation =
    require("./src/models/regulation");


const regulations = [

    {
        category: "food",

        requiredFields: [

            "productName",
            "brand",
            "category",
            "mrp",
            "sellingPrice",
            "manufacturer.name",
            "manufacturer.address",
            "manufacturingDate",
            "expiryDate",
            "batchNumber",
            "netQuantity"

        ],

        rules: [

            {
                code: "PRICE_001",

                name: "MRP Validation",

                description:
                    "Selling price must not exceed MRP",

                severity: "ERROR"
            },

            {
                code: "DATE_001",

                name: "Manufacturing and Expiry Date",

                description:
                    "Expiry date must be after manufacturing date",

                severity: "ERROR"
            },

            {
                code: "DATE_002",

                name: "Expiry Validation",

                description:
                    "Product must not be expired",

                severity: "ERROR"
            },

            {
                code: "MANUFACTURER_001",

                name: "Manufacturer Information",

                description:
                    "Manufacturer name and address must be present",

                severity: "ERROR"
            }

        ]
    }

];


const seedDatabase = async () => {

    try {

        await mongoose.connect(
            process.env.MONGO_URI
        );

        console.log("MongoDB connected");

        await Regulation.deleteMany({});

        await Regulation.insertMany(
            regulations
        );

        console.log(
            "Regulations inserted successfully"
        );

        await mongoose.connection.close();

    } catch (error) {

        console.error(error);

        process.exit(1);
    }
};


seedDatabase();