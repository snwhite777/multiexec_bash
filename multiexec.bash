#!/bin/bash
# Author: Nam Tran
# Email: namtt.7@gmail.com
# Copyright 2016

###################################################
# This script is used to deploy command to a large 
#   list of destination hosts simultaneously
#   using multiprocessing, inspired by 
#   https://blog.garage-coding.com/2016/02/05/bash-fifo-jobqueue.html 
#   (Redis & Bash version)
#
# This script follows the pattern proposed by the blogpost, where a producer 
#   read destination hostnames from a file, and push these hostnames into
#   Redis messaging queue, ready to be processed by multiple child processes
#   called consumers. These consumers' job is to ssh into each of the host
#   and execute the command specified by the user. Redis queue is a reliable
#   mechanism for multiple parrallel consumer processes to share memory, making
#   it possible to deploy comomand to multiple hosts simulatneously.
#
# In current implementation, producer is stored in producer.bash script, and 
#   consumer is stored in consumer.bash script. Rest of the stuffs this multiexec.bash
#   code contains are housekeeping tasks, such as parsing arguments, firing producer, spawning
#   multiple consumer, keep track of the consumers status, and output result to 
#   defined output directory.
#   
# This script works under 2 assumptions:
# 1.  Redis server is installed in the server where the script is hosted
#     (follow instruction at http://redis.io/topics/quickstart)
#     Remember to always make sure that Redis server is running before executing
#     the bash script otherwise it won't work.
#     To start the Redis server: redis-server start &
# 2.  The host where this script run can log in passwordlessly to all the 
#     hosts in the list (via SSH key)
#
#   Please execute command "bash multiexec.bash --help" to display the usage of this script
#
###################################################
###############USAGE OF THE SCRIPT#################
function usage {
    echo 'multiexec.bash : Execute command simultaneously to large number of hosts'
    echo
    echo USAGE:
    echo 'bash ./multiexec.bash -l hostlist -c command [-t timeout] [-m max_number_of_child] [-o outdir] [-h]'
    echo 
    echo 'WHERE:'
    echo '-l|--hostlist <hostlist>: File contain list of servers where the command is deployed to'
    echo '-c|--command <command>  : Command to be executed in list of hosts'
    echo '-t|--timeout <s>        : Number of seconds before a child process is killed'
    echo '-o|--out_dir <directory : Directory where the output of command is dumped to'
    echo '-m|--max_child          : Maximum number of child processes being forked at once'
    echo '-h|--help               : Print this usage message'
}

##################################################
# Checking status(ACTIVE/INACTIVE of a processID #
# If the pid exists in ps -p command, then it's  #
# active, otherwise the process is inactive      #
##################################################
function process_active() {
    PROCESS=$1
    ps -p ${PROCESS} > /dev/null
    RESULT=$?

    if [ $RESULT == 0 ]; then
            echo "ACTIVE"
    else
            echo "INACTIVE"
    fi
}

##################################################
# Monitor the status of the child processes and  #
# display number of child processes currently    #
# running, finished or expired (according to     #
# defined timeout value specified by the script  #
##################################################
function monitor_processes() {
    # Define arguments values, MAX_CHILD is the maximum number
    # of consumers being spawned by the script. Child processes
    # must finish within TIME_OUT seconds otherwise they will be 
    # terminated
    i=0
    MAX_CHILD=$1
    TIME_OUT=$2

    # Count the number of processes currently being running(acitve and 
    # not yet expired), inactive (already terminated / returned) and
    # expired (has run for more than TIME_OUT seconds)
    while true; do
        i=0
        running=0
        finished=0
        expired=0
        # loop i through all child processes
        while [[ $i -lt $MAX_CHILD ]]; do
            # prodid is the array defined below in main command,
            # it contains the pid of all child processes (cosunmers)
            cur_proc_active=$(process_active "${procid[$i]}")
            cur_time=`date +%s`
            # determine how many seconds that the child process run &
            # store it in $exec_time
            exec_time=$((cur_time - proc_start[$i]))
            # process status change when it completed / terminated / expired
            if [[ "${proc_status[$i]}" == "RUNNING" ]]; then
                if [[ "${cur_proc_active}" == "INACTIVE" ]]; then
                    proc_status[$i]="FINISHED"
                elif [[ "${exec_time}" -gt $TIME_OUT ]]; then
                    proc_status[$i]="EXPIRED"
                    /bin/kill -KILL "${procid[$i]}"
                fi
            fi
            #increase the counter of running, finished or inactive process accordingly
            if [[ "${proc_status[$i]}" == "RUNNING" ]]; then
                running=$((running+1))
            elif [[ "${proc_status[$i]}" == "FINISHED" ]]; then
                finished=$((finished+1))
            else
                expired=$((expired+1))
            fi
            i=$((i+1))
        done
        #output the current status
        echo -ne "RUNNING:" "${running}" "FINISHED:" "${finished}" "EXPIRED:" "${expired}" '\r'
        if [[ $running == 0 ]]; then
            echo  "RUNNING:" "${running}" "FINISHED:" "${finished}" "EXPIRED:" "${expired}"
            sleep 2
            break
            :
        fi
    done
}
#################################################
# Main part of the script where the arguments   #
# are read, processed and parameters assigned   #
# values                                        #
#################################################
MAX_CHILD=5
TIME_OUT=100
OUT_DIR="/tmp/OUT.$$"

# Parsing the named argument of the script
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        -l|--hostlist)
            shift
            if [[ $# == 0 ]]; then
               echo "No host list specified"
               exit 1
            else
                HOSTS_FROM=$1
            fi
            shift
            ;;
        -c|--command)
            shift
            if [[ $# == 0 ]]; then
               echo "No command specified"
               exit 1
            else
                CMD="$1"
            fi
            shift
            ;;
        -m|--max_child)
            shift
            if [[ $# -gt 0 ]]; then 
                MAX_CHILD=$1
            else
                echo "No number of max child specified, using default value"
            fi
            shift
            ;;
        -o|--out_dir)
            shift
            if [[ $# == 0 ]]; then
                echo "No output directory specified, using ${OUT_DIR}"
            else
                OUT_DIR=$1
            fi
            shift
            ;;
        -t|--timeout)
            shift
            if [[ $# == 0 ]]; then
                TIME_OUT=100
            else
                TIME_OUT=$1
            fi
            shift
            ;;
        -f|--filename)
            shift
            if [[ $# == 0 || ! -f $1 ]]; then
                echo "No filename specified or wrong filename used. Exitting.."
                usage
                exit 1
            else
                FILE_SCP=$1
            fi
            shift
            ;;
        *)
            echo "Wrong parameter specified. Exitting.."
            usage
            exit 1
            ;;   
    esac
done

# Quit if required arguments are not specified
if [[ -z $HOSTS_FROM || -z $CMD ]]; then
    echo "Host list and command to execute must be specified. Exitting.."
    usage
    exit 1
else
    #Creating output directory if it does not exist yet
    #output the the command execution on destination hosts
    # are stored there under $OUT_DIR/hostname
    if [[ ! -p $OUT_DIR ]]; then
        mkdir -p $OUT_DIR
    fi

    num_hosts=`wc -l $HOSTS_FROM | awk '{print $1}'`
    if [[ $num_hosts -lt $MAX_CHILD ]]; then
        MAX_CHILD=$num_hosts
    fi
fi
    echo "Writing output to directory ${OUT_DIR}"

# Check redis-server status and start it if it's not running
# Execute the producer.bash script to populate the Redis messaging queue        
redis-cli ping > /dev/null 2>&1
if [[ $? -eq 1  ]]; then
    redis-server --daemonize yes
fi
bash ./producer.bash "${HOSTS_FROM}"
i=0
while [[ $i -lt $MAX_CHILD ]]; do
    # SCP a local file to all destination hosts if required by user
    if [[ ! -z $FILE_SCP ]]; then
        bash ./consumer.bash "${OUT_DIR}" --file $FILE_SCP "${CMD}" &
    else
        bash ./consumer.bash "${OUT_DIR}" "${CMD}" &
    fi
    # store the pid of child processes and start time of executing the child process
    # for monitoring purpose
    procid[i]=$!
    proc_start[i]=`date +%s`
    proc_status[i]="RUNNING"
    i=$((i+1))
done
#Spawned multiple processes of the consumer.bash script
monitor_processes $MAX_CHILD $TIME_OUT

#Shutdown redis-server
redis-cli shutdown