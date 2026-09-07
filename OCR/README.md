# OCR API (Java + OpenCV + Tesseract)

A small Spring Boot service that accepts an image, cleans it up with OpenCV,
runs it through Tesseract, and returns the extracted text as JSON. It's meant
to be called from another part of a larger project (over HTTP), or used
directly as Spring beans if it lives in the same JVM.

## Pipeline

```
upload -> grayscale -> denoise -> sharpen -> threshold (Otsu) -> deskew -> Tesseract -> text
```

Each step is its own method in `ImagePreprocessor`, so you can reorder, skip,
or tune any step independently.

## Project layout

```
src/main/java/org/example/
  Main.java                     Spring Boot entry point (loads OpenCV native lib)
  controller/OcrController.java REST endpoint: POST /api/ocr/extract
  service/ImagePreprocessor.java  Grayscale / denoise / sharpen / threshold / deskew
  service/OcrService.java       Wraps Tess4J's Tesseract engine
  util/ImageUtils.java          MultipartFile <-> Mat <-> BufferedImage conversions
  dto/OcrResponse.java          API response shape
src/main/resources/application.properties
```

## Prerequisites

1. **Java 17** and **Maven**.
2. **Tesseract trained data** — you do NOT need to install the Tesseract
   binary itself (Tess4J bundles native libraries for common platforms), but
   you do need the language data file:
   - Download `eng.traineddata` from
     https://github.com/tesseract-ocr/tessdata (or `tessdata_fast` for a
     smaller/faster model).
   - Put it in a `tessdata/` folder at the project root (or wherever you set
     `ocr.tessdata.path` in `application.properties`).
   ```
   ocr-project/
     tessdata/
       eng.traineddata
   ```
3. OpenCV needs no manual install — the `org.openpnp:opencv` dependency
   bundles native libraries for Windows/macOS/Linux and loads them at
   startup via `OpenCV.loadLocally()` in `Main.java`.

> Note: dependency versions in `pom.xml` (Spring Boot 3.3.2, openpnp opencv
> 4.9.0-0, tess4j 5.11.0) were current at the time of writing — check for
> newer releases on Maven Central before building for production.

## Run it

```bash
mvn spring-boot:run
```

The API will be available at `http://localhost:8080/api/ocr/extract`.

## Call it

```bash
curl -X POST http://localhost:8080/api/ocr/extract \
  -F "image=@/path/to/your/image.jpg"
```

Response:

```json
{
  "success": true,
  "text": "Extracted text goes here...",
  "processingTimeMs": 842,
  "error": null
}
```

## Using it from the rest of your project

- **Different service / different JVM:** call the REST endpoint above with
  any HTTP client (`RestTemplate`, `WebClient`, `HttpClient`, fetch/axios
  from a frontend, etc.).
- **Same Spring Boot app / same JVM:** just inject `ImagePreprocessor` and
  `OcrService` directly wherever you need OCR, no HTTP hop required:

  ```java
  @Service
  public class SomeOtherService {
      private final ImagePreprocessor preprocessor;
      private final OcrService ocrService;

      public SomeOtherService(ImagePreprocessor preprocessor, OcrService ocrService) {
          this.preprocessor = preprocessor;
          this.ocrService = ocrService;
      }

      public String readImage(Mat image) throws Exception {
          Mat processed = preprocessor.preprocess(image);
          BufferedImage buffered = ImageUtils.matToBufferedImage(processed);
          return ocrService.extractText(buffered);
      }
  }
  ```

## Tuning tips

- **Low-quality/handwritten scans:** increase the denoise strength (`h`
  parameter in `ImagePreprocessor.denoise`) or try `THRESH_BINARY` with a
  fixed value instead of Otsu if lighting is very uneven (consider
  `Imgproc.adaptiveThreshold` for uneven lighting across the page).
- **Wrong PSM (page segmentation) results:** `OcrService` sets
  `PageSegMode = 3` (fully automatic). For a single line/word of text, try
  `7` or `8`.
- **Non-English text:** change `ocr.tessdata.language` and download the
  matching `.traineddata` file (e.g. `hin.traineddata` for Hindi).
