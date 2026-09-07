package org.example.controller;

import org.example.dto.OcrResponse;
import org.example.service.ImagePreprocessor;
import org.example.service.OcrService;
import org.example.util.ImageUtils;
import org.opencv.core.Mat;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.multipart.MultipartFile;

import java.awt.image.BufferedImage;

@RestController
@RequestMapping("/api/ocr")
public class OcrController {

    private final ImagePreprocessor preprocessor;
    private final OcrService ocrService;

    public OcrController(ImagePreprocessor preprocessor, OcrService ocrService) {
        this.preprocessor = preprocessor;
        this.ocrService = ocrService;
    }

    @PostMapping(value = "/extract", consumes = MediaType.MULTIPART_FORM_DATA_VALUE)
    public ResponseEntity<OcrResponse> extractText(@RequestParam("image") MultipartFile image) {
        if (image == null || image.isEmpty()) {
            return ResponseEntity.badRequest().body(OcrResponse.failure("No image file provided."));
        }

        long start = System.currentTimeMillis();
        try {
            Mat original = ImageUtils.multipartFileToMat(image);
            Mat processed = preprocessor.preprocess(original);
            BufferedImage bufferedImage = ImageUtils.matToBufferedImage(processed);

            String text = ocrService.extractText(bufferedImage);
            long elapsed = System.currentTimeMillis() - start;

            return ResponseEntity.ok(OcrResponse.success(text.trim(), elapsed));
        } catch (Exception e) {
            return ResponseEntity.internalServerError()
                    .body(OcrResponse.failure("OCR failed: " + e.getMessage()));
        }
    }
}
