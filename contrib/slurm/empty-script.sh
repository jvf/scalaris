#!/bin/bash -l




# -o: output log file: %j for the job ID, %N for the name of the first executing node
# Change the path of the output logfile

#SBATCH -J scalaris
#SBATCH -N 2
#SBATCH -p CSR
#SBATCH -A csr
#SBATCH --exclusive

source /usr/share/modules/init/bash
source $(pwd)/env.sh

#$BINDIR/scalarisctl checkinstallation

$(pwd)/scalaris-start.sh

#############################################
#                                           #
#     Place your commands between here      #
#                                           #
#############################################

echo "Nodelist: $SLURM_NODELIST"

#############################################
#                                           #
#     and here                              #
#                                           #
#############################################

echo "stopping servers"
$(pwd)/scalaris-stop.sh
echo "stopped servers"
