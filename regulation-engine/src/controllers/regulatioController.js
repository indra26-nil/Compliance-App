const Regulation = require("../models/regulation");

const createRegulation = async (req, res) => {

    try {

        const regulation =
            await Regulation.create(req.body);

        res.status(201).json({

            success: true,

            message: "Regulation created successfully",

            regulation
        });

    } catch (error) {

        res.status(400).json({

            success: false,

            message: "Failed to create regulation",

            error: error.message
        });
    }
};


const getRegulations = async (req, res) => {

    try {

        const regulations =
            await Regulation.find();

        res.json({

            success: true,

            count: regulations.length,

            regulations
        });

    } catch (error) {

        res.status(500).json({

            success: false,

            message: error.message
        });
    }
};


module.exports = {
    createRegulation,
    getRegulations
};