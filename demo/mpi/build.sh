#!/usr/bin/env bash
set -euo pipefail

module load mpich/4.1.2

mpicc -O2 -o hello_mpi hello_mpi.c
echo "Built ./hello_mpi"