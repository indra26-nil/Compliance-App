package org.example.service;

import org.opencv.core.Core;
import org.opencv.core.CvType;
import org.opencv.core.Mat;
import org.opencv.core.MatOfPoint;
import org.opencv.core.MatOfPoint2f;
import org.opencv.core.Point;
import org.opencv.core.RotatedRect;
import org.opencv.imgproc.Imgproc;
import org.opencv.photo.Photo;
import org.springframework.stereotype.Service;

@Service
public class ImagePreprocessor {


    public Mat preprocess(Mat original) {
        Mat gray = toGrayscale(original);
        Mat denoised = denoise(gray);
        Mat sharpened = sharpen(denoised);
        Mat thresholded = threshold(sharpened);
        return deskew(thresholded);
    }

    public Mat toGrayscale(Mat src) {
        if (src.channels() == 1) {
            return src.clone();
        }
        Mat gray = new Mat();
        int code = (src.channels() == 4) ? Imgproc.COLOR_BGRA2GRAY : Imgproc.COLOR_BGR2GRAY;
        Imgproc.cvtColor(src, gray, code);
        return gray;
    }

    public Mat denoise(Mat src) {
        Mat denoised = new Mat();
        Photo.fastNlMeansDenoising(src, denoised, 10, 7, 21);
        return denoised;
    }

    public Mat sharpen(Mat src) {
        Mat sharpened = new Mat();
        Mat kernel = new Mat(3, 3, CvType.CV_32F);
        float[] kernelData = {
                0, -1, 0,
                -1, 5, -1,
                0, -1, 0
        };
        kernel.put(0, 0, kernelData);
        Imgproc.filter2D(src, sharpened, -1, kernel);
        return sharpened;
    }

    public Mat threshold(Mat src) {
        Mat thresholded = new Mat();
        Imgproc.threshold(src, thresholded, 0, 255, Imgproc.THRESH_BINARY + Imgproc.THRESH_OTSU);
        return thresholded;
    }

    public Mat deskew(Mat src) {
        Mat inverted = new Mat();
        Core.bitwise_not(src, inverted);

        MatOfPoint points = new MatOfPoint();
        Core.findNonZero(inverted, points);
        if (points.empty()) {
            return src;
        }

        MatOfPoint2f points2f = new MatOfPoint2f(points.toArray());
        RotatedRect rect = Imgproc.minAreaRect(points2f);

        double angle = rect.angle;
        if (angle < -45) {
            angle = 90 + angle;
        } else if (angle > 45) {
            angle = angle - 90;
        }

        Point center = new Point(src.cols() / 2.0, src.rows() / 2.0);
        Mat rotationMatrix = Imgproc.getRotationMatrix2D(center, angle, 1.0);
        Mat rotated = new Mat();
        Imgproc.warpAffine(
                src, rotated, rotationMatrix, src.size(),
                Imgproc.INTER_CUBIC, Core.BORDER_REPLICATE, new org.opencv.core.Scalar(0)
        );
        return rotated;
    }
}
