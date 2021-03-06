#include <stdio.h>
#include <assert.h>

#include "cuda_runtime.h"
#include "device_launch_parameters.h"

#include <cufft.h>
#include <cufftXt.h>

#include <thrust/device_vector.h>

#include "Utilities.cuh"
#include "TimingGPU.cuh"

#define DISPLAY

/*******************************/
/* THRUST FUNCTOR IFFT SCALING */
/*******************************/
class Scale_by_constant
{
    private:
        float c_;

    public:
        Scale_by_constant(float c) { c_ = c; };

        __host__ __device__ float2 operator()(float2 &a) const
        {
            float2 output;

            output.x = a.x / c_;
            output.y = a.y / c_;

            return output;
        }

};

/**********************************/
/* IFFT SCALING CALLBACK FUNCTION */
/**********************************/
__device__ void IFFT_Scaling(void *dataOut, size_t offset, cufftComplex element, void *callerInfo, void *sharedPtr) {

	float *scaling_factor = (float*)callerInfo;

    float2 output;
    output.x = cuCrealf(element);
    output.y = cuCimagf(element);

    output.x = output.x / scaling_factor[0];
    output.y = output.y / scaling_factor[0];

    ((float2*)dataOut)[offset] = output;
}

__device__ cufftCallbackStoreC d_storeCallbackPtr = IFFT_Scaling;

/********/
/* MAIN */
/********/
int main() {

    const int N = 16;

    cufftHandle plan;		    cufftSafeCall(cufftPlan1d(&plan, N, CUFFT_C2C, 1));

    TimingGPU timerGPU;

    float2 *h_input             = (float2*)malloc(N*sizeof(float2));
    float2 *h_output1           = (float2*)malloc(N*sizeof(float2));
    float2 *h_output2           = (float2*)malloc(N*sizeof(float2));

    float2 *d_input;            gpuErrchk(cudaMalloc((void**)&d_input, N*sizeof(float2)));
    float2 *d_output1;          gpuErrchk(cudaMalloc((void**)&d_output1, N*sizeof(float2)));
    float2 *d_output2;          gpuErrchk(cudaMalloc((void**)&d_output2, N*sizeof(float2)));

    // --- Callback function parameters
    float *h_scaling_factor     = (float*)malloc(sizeof(float));
    h_scaling_factor[0] = 16.0f;
    float *d_scaling_factor;    gpuErrchk(cudaMalloc((void**)&d_scaling_factor, sizeof(float)));
    gpuErrchk(cudaMemcpy(d_scaling_factor, h_scaling_factor, sizeof(float), cudaMemcpyHostToDevice));

    // --- Initializing the input on the host and moving it to the device
    for (int i = 0; i < N; i++) {
        h_input[i].x = 1.0f;
        h_input[i].y = 0.f;
    }
    gpuErrchk(cudaMemcpy(d_input, h_input, N * sizeof(float2), cudaMemcpyHostToDevice));

    // --- Execute direct FFT on the device and move the results to the host
    cufftSafeCall(cufftExecC2C(plan, d_input, d_output1, CUFFT_FORWARD));
#ifdef DISPLAY
    gpuErrchk(cudaMemcpy(h_output1, d_output1, N * sizeof(float2), cudaMemcpyDeviceToHost));
    for (int i=0; i<N; i++) printf("Direct transform - %d - (%f, %f)\n", i, h_output1[i].x, h_output1[i].y);
#endif

    // --- Execute inverse FFT with subsequent scaling on the device and move the results to the host
    timerGPU.StartCounter();
    cufftSafeCall(cufftExecC2C(plan, d_output1, d_output2, CUFFT_INVERSE));
    thrust::transform(thrust::device_pointer_cast(d_output2), thrust::device_pointer_cast(d_output2) + N, thrust::device_pointer_cast(d_output2), Scale_by_constant((float)(N)));
#ifdef DISPLAY
    gpuErrchk(cudaMemcpy(h_output2, d_output2, N * sizeof(float2), cudaMemcpyDeviceToHost));
    for (int i=0; i<N; i++) printf("Inverse transform - %d - (%f, %f)\n", i, h_output2[i].x, h_output2[i].y);
#endif
    printf("Timing NO callback %f\n", timerGPU.GetCounter());

    // --- Setup store callback
//    timerGPU.StartCounter();
    cufftCallbackStoreC h_storeCallbackPtr;
    gpuErrchk(cudaMemcpyFromSymbol(&h_storeCallbackPtr, d_storeCallbackPtr, sizeof(h_storeCallbackPtr)));
    cufftSafeCall(cufftXtSetCallback(plan, (void **)&h_storeCallbackPtr, CUFFT_CB_ST_COMPLEX, (void **)&d_scaling_factor));

    // --- Execute inverse callback FFT on the device and move the results to the host
    timerGPU.StartCounter();
    cufftSafeCall(cufftExecC2C(plan, d_output1, d_output2, CUFFT_INVERSE));
#ifdef DISPLAY
    gpuErrchk(cudaMemcpy(h_output2, d_output2, N * sizeof(float2), cudaMemcpyDeviceToHost));
    for (int i=0; i<N; i++) printf("Inverse transform - %d - (%f, %f)\n", i, h_output2[i].x, h_output2[i].y);
#endif
    printf("Timing callback %f\n", timerGPU.GetCounter());

    cufftSafeCall(cufftDestroy(plan));

    gpuErrchk(cudaFree(d_input));
    gpuErrchk(cudaFree(d_output1));
    gpuErrchk(cudaFree(d_output2));

    return 0;
}
