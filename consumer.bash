#!/bin/bash

# Author: Nam Tran
# Email: namtt.7@gmail.com
# Copyright 2016

# This is the consumer script. There will be multiple
#   of them being spawned from the multiexec.bash script
#   in order to deploy code to multiple destination hosts at once.

# Parsing the script arguments. There are 2 arguments:
# - OUTDIR - the directory where command output is written to
#     the command output for hostA will be stored accordingly
#     at $OUTDIR/hostA
# - SCP_FILE - the local that need to be SCPed to all destination
#     hosts. This is optional.
OUTDIR=$1
shift
if [[ $1 == "--file" ]]; then
    shift
    SCP_FILE=$1
    shift
fi

# The consume function will move one hostname at once
#   from REDIS q1 (queue) to q2(processing). It then
#   ssh into the hostname and execute the required command
#   and scp local file (if required). After the destination host
#   is processed successfully, the hostname will be removed from
#   the q2 (processing). This pattern helps to improve robustness to
#   the whole program.
consume() {
    # Define the REDIS cli command
    REDIS_CLI="redis-cli -h 127.0.0.1"
    q1="queue"
    q2="processing"
    # redis nil reply
    nil=$(echo -n -e '\r\n')

    # Loop until the REDIS queues are empty
    while true; do
        # move message from q1 (queue) to q2 (processing)
        MSG=$(echo "RPOPLPUSH $q1 $q2" | $REDIS_CLI)
        # Exit when queue is empty (value is Null)
        if [[ -z "$MSG" ]]; then
            break
        else
            #Create the output file (store command output)
            OUTFILE="${OUTDIR}/${MSG}"
            > $OUTFILE
        fi
        # SCP local file to destination host if required
        if [[ ! -z $SCP_FILE ]]; then
            /bin/scp -q -o StrictHostKeyChecking=no -o LogLevel=QUIET $SCP_FILE "${MSG}":/var/tmp/  
        fi
        # Execute the command on destination host
        /bin/ssh -o StrictHostKeyChecking=no "${MSG}" $@ >> $OUTFILE

        # remove message from processing queue
        echo "LREM $q2 1 \"$MSG\"" | $REDIS_CLI >/dev/null
    done
}

# Trigger the consume function and parse all script arguments to consume()
cmds=$@
consume $cmds 
