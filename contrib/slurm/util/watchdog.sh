#!/bin/bash

function cleanup_node(){
    screen -ls | grep Detached | grep scalaris_ | grep "SLURM_JOBID_${SLURM_JOB_ID}" | cut -d. -f1 | awk '{print $1}' | xargs -r kill

    return 0
}

IS_RUNNING=("RUNNING")
SACCT_RES=$(sacct -j $SLURM_JOB_ID -b)
if [[ $? -eq 0 ]]; then
    echo "$(date +%y-%m-%d-%H:%M:%S): $(hostname -s): with sacct error" >> /scratch/bzcfisch/slog/watchdog_${SLURM_JOB_ID}
    IS_RUNNING=($(echo "$SACCT_RES" | grep $SLURM_JOB_ID | awk '{print $2}'))
fi
while [[ ${IS_RUNNING[0]} == "RUNNING" ]]; do
    sleep $WATCHDOG_INTERVAL
    SACCT_RES=$(sacct -j $SLURM_JOB_ID -b)
    if [[ $? -eq 0 ]]; then
        echo "$(date +%y-%m-%d-%H:%M:%S): $(hostname -s): with sacct error" >> /scratch/bzcfisch/slog/watchdog_${SLURM_JOB_ID}
        IS_RUNNING=($(echo "$SACCT_RES" | grep $SLURM_JOB_ID | awk '{print $2}'))
    fi
done

cat <<EOF >> /scratch/bzcfisch/slog/watchdog_${SLURM_JOB_ID}
$(date +%y-%m-%d-%H:%M:%S): $(hostname -s):
SACCT_RES:
$SACCT_RES
IS_RUNNING: ${IS_RUNNING[@]}
screen ls:
$(screen -ls)

EOF

cleanup_node

