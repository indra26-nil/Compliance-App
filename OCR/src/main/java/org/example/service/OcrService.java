package org.example.service;

import net.sourceforge.tess4j.Tesseract;
import net.sourceforge.tess4j.TesseractException;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Service;

import java.awt.image.BufferedImage;

@Service
public class OcrService {

    private final Tesseract tesseract;

    public OcrService(
            @Value("${ocr.tessdata.path:./tessdata}") String tessdataPath,
            @Value("${ocr.tessdata.language:eng}") String language
    ) {
        this.tesseract = new Tesseract();
        this.tesseract.setDatapath(tessdataPath);
        this.tesseract.setLanguage(language);
        this.tesseract.setPageSegMode(3);
        this.tesseract.setOcrEngineMode(1);
    }

    public String extractText(BufferedImage image) throws TesseractException {
        return tesseract.doOCR(image);
    }
}
