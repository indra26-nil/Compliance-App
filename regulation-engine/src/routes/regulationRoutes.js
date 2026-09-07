const express = require("express");

const {
    createRegulation,
    getRegulations
} = require("../controllers/regulationController");

const router = express.Router();

router.post("/", createRegulation);

router.get("/", getRegulations);

module.exports = router;