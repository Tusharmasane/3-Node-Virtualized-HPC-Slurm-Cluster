#!/bin/bash
#SBATCH --job-name=mpi_verify
#SBATCH --nodes=2
#SBATCH --ntasks=8
#SBATCH --output=/hpc_share/mpi_output_%j.log

mpirun /hpc_share/mpi_test
