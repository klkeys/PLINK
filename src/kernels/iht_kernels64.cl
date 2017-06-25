#if __OPENCL_VERSION__ == CL_VERSION_1_1
    #pragma OPENCL EXTENSION cl_khr_fp64 : enable
#endif
#define NVIDIA_WARP_SIZE 32
#define MAPPING  __local double mapping[4]; mapping[0]=0.0; mapping[1]=9.0; mapping[2]=1.0; mapping[3]=2.0;

__kernel void reset_x(
	__global double * x,
	const int n,
	const double val
) {
	int i = get_global_id(0);
	if (i < n){
		x[i] = val;
	}
	return;
}



__kernel void compute_xt_times_vector(
	const int observations,
	const int snps,
	const int subject_chunks,
	const int packedstride_snpmajor,
	const int max_work_group_size,
	__global const char * packedgeno_snpmajor,
	__global double * Xt_vec_chunks,
	__global const double * vec,
	__global const double * means,
	__global const double * precisions,
	__global const long * mask_n,
	__local  double * local_floatgeno
){
    // initialize lookup table
    MAPPING

    // extract thread information
    int subject_chunk = get_group_id(0);
    int snp           = get_group_id(1);
    int threadindex   = get_local_id(0);

    // pull current snp mean, prec from input
    double mean      = means[snp];
    double precision = precisions[snp];

    // initialize values of floating point and compressed genotype arrays
    local_floatgeno[threadindex] = 0.0;

    // synchronize threads in local workgroup
    // barrier(CLK_LOCAL_MEM_FENCE);

    // index of current subject?
    int subject_index = subject_chunk * max_work_group_size + threadindex;

    // now query current value of vector y
    // also save the bitmask value
    //double y = vec[subject_index];
    //int mask = mask_n[subject_index];

    // ensure that subject is in set of observations
    // this is a standard bounds check with OpenCL kernels
    if (subject_index < observations){

        // decompress genotypes into local floating point arrays
        // decompressed genotypes are in local_floatgeno
        int row = subject_chunk * max_work_group_size + threadindex;
        int k = 2*(row & 3);
        char genotype_block = packedgeno_snpmajor[snp * packedstride_snpmajor + (row >> 2)];
        int val  = (((int)genotype_block)>>k) & 3;
        local_floatgeno[threadindex] = mapping[val];
        //double geno = mapping[val];

        // synchronize threads in local workgroup
        // barrier(CLK_LOCAL_MEM_FENCE);

        // now translate and standardize the decompressed genotype to the correct floating point genotype
        // if missing then set to 0.0, otherwise standardize on fly using mean and precision
        // in this process, will multiply against value at correct index of vector
        // in essence, this is the X'*y part
        local_floatgeno[threadindex] = (local_floatgeno[threadindex] == 9.0 || mask_n[subject_index] == 0) ? 0.0 : (local_floatgeno[threadindex] - mean) * precision * vec[subject_index];
        // try storing this as a local variable too
        //local_floatgeno[threadindex] = (geno == 9.0 || mask == 0) ? 0.0 : (geno - mean) * precision * y;

        // synchronize threads in local workgroup
        barrier(CLK_LOCAL_MEM_FENCE);

        // reduce across local workgroup
        // GPUs that are compliant with OpenCL 2.0 can replace this loop with work_group_reduce(local_floatgeno)
        for(int s = max_work_group_size / 2; s > 0; s >>= 1) {
            if (threadindex < s) {
                local_floatgeno[threadindex] += local_floatgeno[threadindex + s];
            }

            // synchronize threads in local workgroup
            barrier(CLK_LOCAL_MEM_FENCE);
        }

        if(threadindex == 0){
            Xt_vec_chunks[snp * subject_chunks + subject_chunk] += local_floatgeno[0];
        }
    }
    return;
}

__kernel void reduce_xt_vec_chunks(
    const int observations,
    const int subject_chunks,
    const int chunk_clusters,
    const int max_work_group_size,
    __global double * Xt_vec_chunks,
    __global double * Xt_vec,
    __local  double * local_xt
){
    // get SNP and thread indices
    int snp = get_group_id(1);
    int threadindex = get_local_id(0);

    // initialize local memory array with components equal to 0.0
    local_xt[threadindex] = 0.0;

    // synchronize threads in local workgroup
    //barrier(CLK_LOCAL_MEM_FENCE);

    // spawn computations for each chunk
    for (int chunk_cluster = 0; chunk_cluster < chunk_clusters; ++chunk_cluster){

        int subject_chunk = chunk_cluster * max_work_group_size + threadindex;

        if (subject_chunk < subject_chunks){

            // this accumuates chunks of X' times vector
            local_xt[threadindex] += Xt_vec_chunks[snp * subject_chunks + subject_chunk];
        }

        // synchronize threads in local workgroup
        barrier(CLK_LOCAL_MEM_FENCE);
    }

    // now reduce across the workgroup
    // in OpenCL 2.0, can use work_group_reduce(local_xt)
    for (int s = max_work_group_size / 2; s > 0; s >>= 1) {
        if (threadindex < s) {
            local_xt[threadindex] += local_xt[threadindex + s];
        }

        // synchronize threads in local workgroup
        barrier(CLK_LOCAL_MEM_FENCE);
    }

    // topmost thread assigns reduction across workgroup to correct entry in output vector
    if ( threadindex == 0){
        Xt_vec[snp] = local_xt[0];
    }
    return;
}
