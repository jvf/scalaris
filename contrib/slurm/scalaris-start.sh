#!/bin/bash

source $(pwd)/env.sh

function fix_known_hosts() {
    let NR_OF_NODES=$SLURM_JOB_NUM_NODES\*$VMS_PER_NODE
    if [ -e $ETCDIR/scalaris.local.cfg ]
    then
        mv $ETCDIR/scalaris.local.cfg .
    else
        touch scalaris.local.cfg
    fi
    NODEIDX=1
    echo "{known_hosts, [" >> $ETCDIR/scalaris.local.cfg
    for NODE in `scontrol show hostnames`; do
        PORT=14195
        for TASKSPERNODE in `seq 1 $VMS_PER_NODE`; do
            IP=`host $NODE | cut -d ' ' -f 4`
            echo -n "{{" >> $ETCDIR/scalaris.local.cfg
            echo -n $IP | sed s/\\./\,/g >> $ETCDIR/scalaris.local.cfg
            echo -n "},$PORT,service_per_vm}" >> $ETCDIR/scalaris.local.cfg
            if [ "$NODEIDX" -ne "$NR_OF_NODES" ]
            then
                echo "," >> $ETCDIR/scalaris.local.cfg
            fi
            let PORT+=1
            let NODEIDX+=1
        done
    done
    echo "]}." >> $ETCDIR/scalaris.local.cfg

    ## fix mgmt_server
    HEADNODE=`scontrol show hostnames | head -n1`
    echo -n "{mgmt_server, {{" >> $ETCDIR/scalaris.local.cfg
    IP=`host $HEADNODE | cut -d ' ' -f 4`
    echo -n $IP | sed s/\\./\,/g >> $ETCDIR/scalaris.local.cfg
    echo "}, 14195, mgmt_server}}." >> $ETCDIR/scalaris.local.cfg
}

function kill_old_nodes() {
    srun -N$SLURM_JOB_NUM_NODES bash -c "screen -ls | grep Detached | grep scalaris_ | cut -d. -f1 | awk '{print $1}' | xargs -r kill"
}

function start_servers() {
    HEADNODE=`scontrol show hostnames | head -n1`
    TAILNODES=`scontrol show hostnames | tail -n +2`

    let NR_OF_DHT_NODES=$SLURM_JOB_NUM_NODES\*$VMS_PER_NODE\*$DHT_NODES_PER_VM
    let NR_OF_VMS=$SLURM_JOB_NUM_NODES\*$VMS_PER_NODE

    KEYLIST=""
    if [ $SHUFFLE_NODE_IDS -eq 1 ]
    then
        KEYLIST=`erl -name bench_ -pa $BEAMDIR -noinput -eval "L = util:lists_split(util:shuffle(api_dht_raw:split_ring($NR_OF_DHT_NODES)), $NR_OF_VMS), io:format('~p', [L]), halt(0)."`
    else
        KEYLIST=`erl -name bench_ -pa $BEAMDIR -noinput -eval "L = util:lists_split(api_dht_raw:split_ring($NR_OF_DHT_NODES), $NR_OF_VMS), io:format('~p', [L]), halt(0)."`
    fi

    VM_IDX=1
    JOIN_KEYS=`erl -name bench_ -noinput -eval "L = lists:nth($VM_IDX, $KEYLIST), io:format('~p', [L]), halt(0)."`
    # start first node on head node
    $BINDIR/scalarisctl -j "$JOIN_KEYS" -n first -p 14195 -y 8000 --nodes-per-vm $DHT_NODES_PER_VM --screen -d -m -t first start
    let VM_IDX+=1

    ## @todo use auto-binding
    # start vms at all the tail nodes
    srun -k -r1 -N$((SLURM_NNODES-1)) --cpu_bind=none --ntasks-per-node=${VMS_PER_NODE} ./start-vm.sh --keylist "${KEYLIST}" --vm-idx $VMS_PER_NODE &

    # start remaining VMs on head node
    PORT=14196
    YAWSPORT=8001
    for TASKSPERNODE in `seq 2 $VMS_PER_NODE`; do
        JOIN_KEYS=`erl -name bench_ -noinput -eval "L = lists:nth($VM_IDX, $KEYLIST), io:format('~p', [L]), halt(0)."`
        $BINDIR/scalarisctl -j "$JOIN_KEYS" -n node$PORT -p $PORT -y $YAWSPORT --nodes-per-vm $DHT_NODES_PER_VM --screen -d -t joining start &
        let VM_IDX+=1
        let PORT+=1
        let YAWSPORT+=1
    done

    # wait for all sruns to return
    wait
}

function wait_for_servers_to_start {
    let NR_OF_NODES=$SLURM_JOB_NUM_NODES\*$VMS_PER_NODE\*$DHT_NODES_PER_VM
    for NODE in `scontrol show hostnames`; do
        RUNNING_NODES=`srun --nodelist=$NODE -N1 --ntasks-per-node=1 epmd -names | grep " at port " | wc -l`
        while [ $RUNNING_NODES -ne $VMS_PER_NODE ]
        do
            RUNNING_NODES=`srun --nodelist=$NODE -N1 --ntasks-per-node=1 epmd -names | grep " at port " | wc -l`
        done
    done

    # wait for the first VM to start
    NR_OF_FIRSTS=`epmd -names | grep 'name first at port' | wc -l`
    while [ $NR_OF_FIRSTS -ne 1 ]
    do
        NR_OF_FIRSTS=`epmd -names | grep 'name first at port' | wc -l`
    done
    # wait for the first VM to initialize
    erl -setcookie "chocolate chip cookie" -name bench_ -noinput -eval "A = rpc:call('first@`hostname -f`', api_vm, wait_for_scalaris_to_start, []), io:format('waited for scalaris: ~p~n', [A]), halt(0)."
    # wait for the ring to stabilize
    erl -setcookie "chocolate chip cookie" -name bench_ -noinput -eval "A = rpc:call('first@`hostname -f`', admin, wait_for_stable_ring, [$NR_OF_NODES]), io:format('waited for the ring: ~p~n', [A]), halt(0)."
}

function start_watchdog() {
    # start watchdog
    srun -N$SLURM_NNODES screen -S scalaris_watchdog_${SLURM_JOBID} -d -m ./watchdog.sh
}

module load erlang/$ERLANG_VERSION

fix_known_hosts
kill_old_nodes
d1=$(date '+%s')
start_servers
wait_for_servers_to_start
d2=$(date '+%s')
echo "starting $(($SLURM_JOB_NUM_NODES*$VMS_PER_NODE*$DHT_NODES_PER_VM))($SLURM_JOB_NUM_NODES*$VMS_PER_NODE*$DHT_NODES_PER_VM) nodes took $((d2-d1)) seconds"
start_watchdog
