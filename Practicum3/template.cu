//
//  template.cu
//
//  Created by Zia Ul-Huda on 01/12/2017.
//

#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <string.h>
#include <time.h>
#include <sys/time.h>
#include "timing.h"

#define BLOCK_SIZE  16
#define HEADER_SIZE 122

typedef unsigned char BYTE;

//#define CUDA_ERROR_CHECK

#define CudaSafeCall( err ) __cudaSafeCall( err, __FILE__, __LINE__ )
#define CudaCheckError()    __cudaCheckError( __FILE__, __LINE__ )

void showGPUMem();

inline void __cudaSafeCall( cudaError err, const char *file, const int line )
{
#ifdef CUDA_ERROR_CHECK
    if ( cudaSuccess != err )
    {
        fprintf( stderr, "cudaSafeCall() failed at %s:%i : %s\n",
                file, line, cudaGetErrorString( err ) );
        exit( -1 );
    }
#endif

    return;
}

inline void __cudaCheckError( const char *file, const int line )
{
#ifdef CUDA_ERROR_CHECK
    cudaError err = cudaGetLastError();
    if ( cudaSuccess != err )
    {
        fprintf( stderr, "cudaCheckError() failed at %s:%i : %s\n",
                file, line, cudaGetErrorString( err ) );
	showGPUMem();
        exit( -1 );
    }

    // More careful checking. However, this will affect performance.
    // Comment away if needed.
    /*   err = cudaDeviceSynchronize();
     if( cudaSuccess != err )
     {
     fprintf( stderr, "cudaCheckError() with sync failed at %s:%i : %s\n",
     file, line, cudaGetErrorString( err ) );
     exit( -1 );
     }*/
#endif

    return;
}

void showGPUMem(){
    // show memory usage of GPU

    size_t free_byte ;

    size_t total_byte ;

    cudaError_t cuda_status = cudaMemGetInfo( &free_byte, &total_byte ) ;

    if ( cudaSuccess != cuda_status ){

        printf("Error: cudaMemGetInfo fails, %s \n", cudaGetErrorString(cuda_status) );

        exit(1);

    }



    double free_db = (double)free_byte ;

    double total_db = (double)total_byte ;

    double used_db = total_db - free_db ;

    printf("GPU memory usage: used = %f MB, free = %f MB, total = %f MB\n", used_db/1024.0/1024.0, free_db/1024.0/1024.0, total_db/1024.0/1024.0);
}


/********* BMP Image functions **************/
typedef struct
{
    int   width;
    int   height;
    float *data;
} BMPImage;

BYTE bmp_info[HEADER_SIZE]; // Reference header


/**
 * Reads a BMP 24bpp file and returns a BMPImage structure.
 * Thanks to https://stackoverflow.com/a/9296467
 */
BMPImage readBMP(char *filename)
{
    BMPImage bitmap = { 0 };
    int      size   = 0;
    BYTE     *data  = NULL;
    FILE     *file  = fopen(filename, "rb");

    // Read the header (expected BGR - 24bpp)
    fread(bmp_info, sizeof(BYTE), HEADER_SIZE, file);

    // Get the image width / height from the header
    bitmap.width  = *((int *)&bmp_info[18]);
    bitmap.height = *((int *)&bmp_info[22]);
    size          = *((int *)&bmp_info[34]);

    // Read the image data
    data = (BYTE *)malloc(sizeof(BYTE) * size);
    fread(data, sizeof(BYTE), size, file);

    // Convert the pixel values to float
    bitmap.data = (float *)malloc(sizeof(float) * size);

    for (int i = 0; i < size; i++)
    {
        bitmap.data[i] = (float)data[i];
    }

    fclose(file);
    free(data);

    return bitmap;
}



/**
 * Writes a BMP file in grayscale given its image data and a filename.
 */
void writeBMPGrayscale(int width, int height, float *image, char *filename)
{
    FILE *file = NULL;

    file = fopen(filename, "wb");

    // Write the reference header
    fwrite(bmp_info, sizeof(BYTE), HEADER_SIZE, file);

    // Unwrap the 8-bit grayscale into a 24bpp (for simplicity)
    for (int h = 0; h < height; h++)
    {
        int row = h * width;

        for (int w = 0; w < width; w++)
        {
            BYTE pixel = (BYTE)((image[row + w] > 255.0f) ? 255.0f :
                                (image[row + w] < 0.0f)   ? 0.0f   :
                                image[row + w]);

            // Repeat the same pixel value for BGR
            fputc(pixel, file);
            fputc(pixel, file);
            fputc(pixel, file);
        }
    }

    fclose(file);
}

/**
* Releases a given BMPImage.
*/
void freeBMP(BMPImage bitmap)
{
    free(bitmap.data);
}


/*********** Gray Scale Filter  *********/

/**
 * Converts a given 24bpp image into 8bpp grayscale using the CPU.
 */
void grayscale(int width, int height, float *image, float *image_out)
{
    for (int h = 0; h < height; h++)
    {
        int offset_out = h * width;      // 1 color per pixel
        int offset     = offset_out * 3; // 3 colors per pixel

        for (int w = 0; w < width; w++)
        {
            float *pixel = &image[offset + w * 3];

            // Convert to grayscale following the "luminance" model
            image_out[offset_out + w] = pixel[0] * 0.0722f + // B
            pixel[1] * 0.7152f + // G
            pixel[2] * 0.2126f;  // R
        }
    }
}

/**
 * Converts a given 24bpp image into 8bpp grayscale using the GPU.
 */
__global__
void cuda_grayscale(int width, int height, float *image, float *image_out)
{
    //TODO (9 pt): implement grayscale filter kernel
    // Calculate offset based on block position
    int offset_x = BLOCK_SIZE * blockIdx.x;
    int offset_y = BLOCK_SIZE * blockIdx.y;

    // Calculate rendering limitation
    int till_x = offset_x + BLOCK_SIZE;
    int till_y = offset_y + BLOCK_SIZE;

    for (int h = offset_y; h < till_y; h++)
    {
        // Break loop if image is smaller
        // Can occur if image height is not a multiple of BLOCK_SIZE -> Block is 'half-empty'
        if (h >= height)
            break;

        int offset_out = h * width;      // 1 color per pixel
        int offset     = offset_out * 3; // 3 colors per pixel

        for (int w = offset_x; w < till_x; w++)
        {
            // Break loop if image is smaller
            // Can occur if image width is not a multiple of BLOCK_SIZE -> Block is 'half-empty'
            if (w >= width)
                break;

            float *pixel = &image[offset + w * 3];

            // Convert to grayscale following the "luminance" model
            image_out[offset_out + w] = pixel[0] * 0.0722f + // B
                                        pixel[1] * 0.7152f + // G
                                        pixel[2] * 0.2126f;  // R
        }
    }
}

/****************Convolution Filters*****/


/**
 * Applies a 3x3 convolution matrix to a pixel using the CPU.
 */
float applyFilter(float *image, int stride, float *matrix, int filter_dim)
{
    float pixel = 0.0f;

    for (int h = 0; h < filter_dim; h++)
    {
        int offset        = h * stride;
        int offset_kernel = h * filter_dim;

        for (int w = 0; w < filter_dim; w++)
        {
            pixel += image[offset + w] * matrix[offset_kernel + w];
        }
    }

    return pixel;
}

/**
 * Applies a 3x3 convolution matrix to a pixel using the GPU.
 */
__device__
float cuda_applyFilter(float *image, int stride, float *matrix, int filter_dim)
{
    //TODO (4 pt): implement convolution filter function for the device
    float pixel = 0.0f;

    for (int h = 0; h < filter_dim; h++)
    {
        int offset        = h * stride;
        int offset_kernel = h * filter_dim;

        for (int w = 0; w < filter_dim; w++)
        {
            pixel += image[offset + w] * matrix[offset_kernel + w];
        }
    }

    return pixel;
}

/**
 * Applies a Gaussian 3x3 filter to a given image using the CPU.
 */
void gaussian(int width, int height, float *image, float *image_out)
{
    float gaussian[9] = { 1.0f / 16.0f, 2.0f / 16.0f, 1.0f / 16.0f,
        2.0f / 16.0f, 4.0f / 16.0f, 2.0f / 16.0f,
        1.0f / 16.0f, 2.0f / 16.0f, 1.0f / 16.0f };

    for (int h = 0; h < (height - 2); h++)
    {
        int offset_t = h * width;
        int offset   = (h + 1) * width;

        for (int w = 0; w < (width - 2); w++)
        {
            image_out[offset + (w + 1)] = applyFilter(&image[offset_t + w], width, gaussian, 3);
        }
    }
}

/**
 * Applies a Gaussian 3x3 filter to a given image using the GPU.
 */
__global__
void cuda_gaussian(int width, int height, float *image, float *image_out)
{
    //TODO (9 pt): implement gaussian filter kernel
    // Calculate offset based on block position
    int offset_x = BLOCK_SIZE * blockIdx.x;
    int offset_y = BLOCK_SIZE * blockIdx.y;

    // Use either image border or block border as rendering limitation
    // -> if image border is used, there must be a border of 1px
    int till_x = min(width - 2, offset_x + BLOCK_SIZE);
    int till_y = min(height - 2, offset_y + BLOCK_SIZE);

    float gaussian[9] = { 1.0f / 16.0f, 2.0f / 16.0f, 1.0f / 16.0f,
                          2.0f / 16.0f, 4.0f / 16.0f, 2.0f / 16.0f,
                          1.0f / 16.0f, 2.0f / 16.0f, 1.0f / 16.0f };

    for (int h = offset_y; h < till_y; h++)
    {
        // Break loop if image is smaller
        // Can occur if image height is not a multiple of BLOCK_SIZE -> Block is 'half-empty'
        if (h >= height)
            break;

        int offset_t = h * width;
        int offset   = (h + 1) * width;

        for (int w = offset_x; w < till_x; w++)
        {
            // Break loop if image is smaller
            // Can occur if image width is not a multiple of BLOCK_SIZE -> Block is 'half-empty'
            if (w >= width)
                break;

            image_out[offset + (w + 1)] = cuda_applyFilter(&image[offset_t + w], width, gaussian, 3);
        }
    }
}

/**
 * Calculates the gradient of an image using a Sobel filter on the CPU.
 */
void sobel(int width, int height, float *image, float *image_out)
{
    float sobel_x[9] = { 1.0f,  0.0f, -1.0f,
        2.0f,  0.0f, -2.0f,
        1.0f,  0.0f, -1.0f };
    float sobel_y[9] = { 1.0f,  2.0f,  1.0f,
        0.0f,  0.0f,  0.0f,
        -1.0f, -2.0f, -1.0f };

    for (int h = 0; h < (height - 2); h++)
    {
        int offset_t = h * width;
        int offset   = (h + 1) * width;

        for (int w = 0; w < (width - 2); w++)
        {
            float gx = applyFilter(&image[offset_t + w], width, sobel_x, 3);
            float gy = applyFilter(&image[offset_t + w], width, sobel_y, 3);

            image_out[offset + (w + 1)] = sqrtf(gx * gx + gy * gy);
        }
    }
}

/**
 * Calculates the gradient of an image using a Sobel filter on the GPU.
 */
__global__
void cuda_sobel(int width, int height, float *image, float *image_out)
{
    //TODO (9 pt): implement sobel filter kernel
    // Calculate offset based on block position
    int offset_x = BLOCK_SIZE * blockIdx.x;
    int offset_y = BLOCK_SIZE * blockIdx.y;

    // Use either image border or block border as rendering limitation
    // -> if image border is used, there must be a border of 1px
    int till_x = min(width - 2, offset_x + BLOCK_SIZE);
    int till_y = min(height - 2, offset_y + BLOCK_SIZE);

    float sobel_x[9] = { 1.0f,  0.0f, -1.0f,
                         2.0f,  0.0f, -2.0f,
                         1.0f,  0.0f, -1.0f };
    float sobel_y[9] = { 1.0f,  2.0f,  1.0f,
                         0.0f,  0.0f,  0.0f,
                         -1.0f, -2.0f, -1.0f };

    for (int h = offset_y; h < till_y; h++)
    {
        // Break loop if image is smaller
        // Can occur if image height is not a multiple of BLOCK_SIZE -> Block is 'half-empty'
        if (h >= height)
            break;

        int offset_t = h * width;
        int offset   = (h + 1) * width;

        for (int w = offset_x; w < till_x; w++)
        {
            // Break loop if image is smaller
            // Can occur if image width is not a multiple of BLOCK_SIZE -> Block is 'half-empty'
            if (w >= width)
                break;

            float gx = cuda_applyFilter(&image[offset_t + w], width, sobel_x, 3);
            float gy = cuda_applyFilter(&image[offset_t + w], width, sobel_y, 3);

            image_out[offset + (w + 1)] = sqrtf(gx * gx + gy * gy);
        }
    }
}


int main(int argc, char *argv[])
{
    //check for arguments
    if(argc != 2){
        puts("Usage: sol input_file\n");
        exit(0);
    }

    BMPImage bitmap          = { 0 };
    float    *d_bitmap       = { 0 };
    float    *image_out[2]   = { 0 };
    float    *d_image_out[2] = { 0 };
    int      image_size      = 0;
    double   t[2]            = { 0 };
    dim3     grid(1);
    dim3     block(BLOCK_SIZE, BLOCK_SIZE);
    char     path[255];

    init_clock_time();

    // Read the input image and update the grid dimension
    bitmap     = readBMP(argv[1]);
    image_size = bitmap.width * bitmap.height;
    float image_filesize = image_size*sizeof(float);


    //TODO (2 pt): Compute grid size
    // Ceil / float construct is needed for images whose image size is not a multiple of BLOCK_SIZE
    // -> 'half-empty' blocks will be created that calculate the remaining border pixels
    dim3 image_grid(ceil((float) bitmap.width / BLOCK_SIZE), ceil((float) bitmap.height / BLOCK_SIZE));

    printf("grid_x=%d, grid_y=%d, block_x_y=%d\n", image_grid.x, image_grid.y, BLOCK_SIZE);

    printf("Image read (width=%d height=%d).\n", bitmap.width, bitmap.height);

    // Allocate the intermediate image buffers for each step
    for (int i = 0; i < 2; i++)
    {
        image_out[i] = (float *)calloc(image_size, sizeof(float));

        //TODO (2 pt): allocate memory on the device
        cudaMalloc((void**) &d_image_out[i], image_filesize);

        //TODO (2 pt): intialize allocated memory on device to zero
        cudaMemset(d_image_out[i], 0, image_filesize);
    }

    //copy input image to device
    //TODO (2 pt): Allocate memory on device for input image
    cudaMalloc((void**) &d_bitmap, image_filesize * 3);

    //TODO (2 pt): Copy input image into the device memory
    cudaMemcpy(d_bitmap, bitmap.data, image_filesize * 3, cudaMemcpyHostToDevice);

    t[0] = get_clock_time();

    // Covert input image to grayscale
    //grayscale(bitmap.width, bitmap.height, bitmap.data, image_out[0]); //serial version

    //TODO (2 pt): Launch cuda_grayscale()
    cuda_grayscale<<<image_grid,block>>>(bitmap.width, bitmap.height, d_bitmap, d_image_out[0]);

    t[1] = get_clock_time();

    //TODO (2 pt): transfer image from device to the main memory for saving onto the disk
    cudaMemcpy(image_out[0], d_image_out[0], image_size*sizeof(float), cudaMemcpyDeviceToHost);

    sprintf(path, "images/grayscale.bmp");
    writeBMPGrayscale(bitmap.width, bitmap.height, image_out[0], path); //write output file
    printf("Time taken for grayscaling: %8.5f ms\n",t[1] - t[0]);

    // Apply a 3x3 Gaussian filter
    t[0] = get_clock_time();
    // Launch the CPU version
    //gaussian(bitmap.width, bitmap.height, image_out[0], image_out[1]);

    // Launch the GPU version
    //TODO (2 pt): Launch cuda_gaussian();
    cuda_gaussian<<<image_grid,block>>>(bitmap.width, bitmap.height, d_image_out[0], d_image_out[1]);

    t[1] = get_clock_time();
    //TODO (2 pt): transfer image from device to the main memory for saving onto the disk
    cudaMemcpy(image_out[1], d_image_out[1], image_size*sizeof(float), cudaMemcpyDeviceToHost);


    // Store the result image with the Gaussian filter applied
    sprintf(path, "images/gaussian.bmp");
    writeBMPGrayscale(bitmap.width, bitmap.height, image_out[1], path); //write output file
    printf("Time taken for Gaussian filtering: %8.5f ms\n",t[1] - t[0]);


    // Apply a Sobel filter
    t[0] = get_clock_time();
    // Launch the CPU version
    //sobel(bitmap.width, bitmap.height, image_out[1], image_out[0]);


    // Launch the GPU version
    //TODO (2 pt): Launch cuda_sobel();
    cuda_sobel<<<image_grid,block>>>(bitmap.width, bitmap.height, d_image_out[1], d_image_out[0]);

    t[1] = get_clock_time();
    //TODO (2 pt): transfer image from device to the main memory for saving onto the disk
    cudaMemcpy(image_out[0], d_image_out[0], image_size*sizeof(float), cudaMemcpyDeviceToHost);


    // Store the final result image with the Sobel filter applied
    sprintf(path, "images/sobel.bmp");
    writeBMPGrayscale(bitmap.width, bitmap.height, image_out[0], path); //write output file
    printf("Time taken for Sobel filtering: %8.5f ms\n",t[1] - t[0]);



    // Release the allocated memory
    for (int i = 0; i < 2; i++)
    {
        free(image_out[i]);

    }

    freeBMP(bitmap);
    //TODO (2 pt): Free device allocated memory
    for (int i = 0; i < 2; i++)
        cudaFree(image_out[i]);

    return 0;
}
