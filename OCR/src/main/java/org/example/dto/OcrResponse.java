package org.example.dto;

public class OcrResponse {

    private boolean success;
    private String text;
    private long processingTimeMs;
    private String error;

    public static OcrResponse success(String text, long processingTimeMs) {
        OcrResponse r = new OcrResponse();
        r.success = true;
        r.text = text;
        r.processingTimeMs = processingTimeMs;
        return r;
    }

    public static OcrResponse failure(String error) {
        OcrResponse r = new OcrResponse();
        r.success = false;
        r.error = error;
        return r;
    }

    public boolean isSuccess() {
        return success;
    }

    public String getText() {
        return text;
    }

    public long getProcessingTimeMs() {
        return processingTimeMs;
    }

    public String getError() {
        return error;
    }
}
