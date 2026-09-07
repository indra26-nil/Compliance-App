package org.example.util;

import org.opencv.core.Mat;
import org.opencv.core.MatOfByte;
import org.opencv.imgcodecs.Imgcodecs;
import org.springframework.web.multipart.MultipartFile;

import javax.imageio.ImageIO;
import java.awt.image.BufferedImage;
import java.io.ByteArrayInputStream;
import java.io.IOException;

public final class ImageUtils {

    private ImageUtils() {
    }

    public static Mat multipartFileToMat(MultipartFile file) throws IOException {
        byte[] bytes = file.getBytes();
        Mat encoded = new MatOfByte(bytes);
        Mat decoded = Imgcodecs.imdecode(encoded, Imgcodecs.IMREAD_COLOR);
        if (decoded.empty()) {
            throw new IOException("Could not decode image. Unsupported or corrupt file.");
        }
        return decoded;
    }

    public static BufferedImage matToBufferedImage(Mat mat) throws IOException {
        MatOfByte buffer = new MatOfByte();
        Imgcodecs.imencode(".png", mat, buffer);
        return ImageIO.read(new ByteArrayInputStream(buffer.toArray()));
    }
}
