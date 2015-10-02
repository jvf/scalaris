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

sleep 3

KEYS=512
ITERS=8
echo "$(date) running bench:increment($KEYS, $ITERS)..."
METRICS="{value, {mean_troughput_overall, Mean}} = lists:keysearch(mean_troughput_overall, 1, Res), {value, {avg_latency_overall, Latency}} = lists:keysearch(avg_latency_overall, 1, Res)"
LOGSTRING_INC="io:format('result data inc:~p:~p~n', [Mean, Latency])"
erl -setcookie "chocolate chip cookie" -name bench_ -noinput -eval "{ok, Res} = rpc:call('first@`hostname -f`', bench, increment, [$KEYS, $ITERS]), $METRICS, $LOGSTRING_INC, halt(0)."

sleep 3

#############################################
#                                           #
#     and here                              #
#                                           #
#############################################

echo "stopping servers"
$(pwd)/scalaris-stop.sh
echo "stopped servers"
