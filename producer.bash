#!/bin/bash
# Author: Nam Tran
# Email: namtt.7@gmail.com
# Copyright 2016

# This is the simple producer script.
# Which read the file that contains host lists
# and push all of them to the queue, ready to be processed 
# by the consumers. Refer to the multiexec.bash for more details

# Define the command to connect to REDIS server
# And define the two queues where the destination hostnames
#   are pushed to
REDIS_CLI="redis-cli -h 127.0.0.1"
q1="queue"
q2="processing"

# Initialize the two queues
clean () {
    echo "DEL $q1" | $REDIS_CLI > /dev/null
    echo "DEL $q2" | $REDIS_CLI > /dev/null
}

# Read the hostlist file and push all hostnames to q1
# The hostnames stay in this queue and only moved to q2
#   (processing queue) once they are ready to be 
#   processed by the consumer (consumer.bash script)
produce () {
    FILE="${1}"
    while read MSG; do
        echo "LPUSH $q1 \"$MSG\"" | $REDIS_CLI > /dev/null
    done < $FILE
}

clean
produce $1
