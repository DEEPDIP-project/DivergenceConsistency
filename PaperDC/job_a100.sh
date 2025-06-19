#!/bin/bash
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=18
#SBATCH --gpus=1
#SBATCH --partition=gpu_a100
#SBATCH --time=10:00:00
#SBATCH --mail-type=BEGIN,END
#SBATCH --array=1-8

# Note:
# - gpu_a100: 18 cores
# - gpu_h100: 16 cores
# https://servicedesk.surf.nl/wiki/display/WIKI/Snellius+partitions+and+accounting

module load 2023
module load juliaup/1.14.5-GCCcore-12.3.0

julia --project=PaperDC -e 'using Pkg; Pkg.instantiate()'

# julia --project prioranalysis.jl
julia --project -t auto postanalysis_snel.jl

# julia --project -t auto -e 'using Pkg; Pkg.update()'
