#!/bin/bash
#
# Copyright (c) 2016, Nimbix, Inc.
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#
# 1. Redistributions of source code must retain the above copyright notice,
#    this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright notice,
#    this list of conditions and the following disclaimer in the documentation
#    and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
# AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
# LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
# CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
# SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
# INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
# CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
# ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
# POSSIBILITY OF SUCH DAMAGE.
#
# The views and conclusions contained in the software and documentation are
# those of the authors and should not be interpreted as representing official
# policies, either expressed or implied, of Nimbix, Inc.
#
# Author: Stephen Fox (stephen.fox@nimbix.net)

################################################################################
# canu-pipeline.sh
#
# Setup:
#  1. Install CANU from binary archives: https://github.com/marbl/canu/releases, along with JAVA 1.8.
#     * https://github.com/marbl/canu/releases/download/v1.2/canu-1.2.Linux-amd64.tar.bz2
#     * http://download.oracle.com/otn-pub/java/jdk/8u91-b14/jre-8u91-linux-x64.rpm
#  2. Install Torque 6.0.1 RPMs. These can be built from the source archive.
#  3. Run jarvice.apps/torque/install.sh
#  4. Call setup_torque.sh to start the torque server and clients
#
# This script should be called if you want to submit a job to torque via
# qsub or qrun in the current job environment.
################################################################################

sudo service sshd start 2>/dev/null
echo "$0 $@"

SPEC_FILE=
GENOME_MAGNITUDE=

while [ ! -z "$1" ]; do
    case "$1" in
        -version)
            shift
            VERSION="$1"
            ;;
        -ApplicationParams)
            shift
            PARAMS="$1"
            ;;
        -action)
            shift
            if [ "$1" != "all" ]; then
                ACTION="$1"
            else
                ACTION=
            fi
            ;;
        -genomeSize)
            shift
            GENOME_SIZE="$1"
            ;;
        -genomeMagnitude)
            shift
            if [ "$1" != "None" ]; then
                GENOME_MAGNITUDE="$1"
            else
                GENOME_MAGNITUDE=""
            fi
            ;;
        -errorRate)
            shift
            ERROR_RATE="$1"
            ;;
        -inputType)
            shift
            INPUT_TYPE="$1"
            ;;
        -inputFile)
            shift
            INPUT_FILE="$1"
            ;;
        -resumeFromJob)
            shift
            RESUME_FROM_JOB="$1"
            ;;
        -s)
            shift
            SPEC_FILE="-s $1"
            ;;
        *)
            ;;
    esac
    shift
done

sleep 5

#. `dirname $0`/../torque/install.sh

echo "Starting torque"
/usr/local/scripts/torque/launch.sh

sleep 15

TIMEOUT=100
ELAPSED=0

while [ 1 ]; do
    NODE_COUNT=$(qnodes -a |grep -i down | wc -l)
    if [ $NODE_COUNT -gt 0 ]; then
        sleep 10
        ELAPSED=$(($ELAPSED+10))
        if [ $ELAPSED -gt $TIMEOUT ]; then
            echo "Failure to start torque!" 1>&2
            echo `qnodes -a` 1>&2
            exit 1
        fi
    else
        break
    fi
done


CANU_PATH=/usr/local/canu-$VERSION/Linux-amd64/bin
export PATH=${PATH}:${CANU_PATH}

. /etc/JARVICE/jobinfo.sh

if [ ! -z $RESUME_FROM_JOB ] && [ ! -d /data/$RESUME_FROM_JOB ]; then
    echo "FATAL: Cannot resume job: $RESUME_FROM_JOB. Try with a different job name, or leave this blank to start over." 1>&1
fi


OUTPUT_DIR=/data/${JOB_NAME}

# Create output directory
if [ ! -z $RESUME_FROM_JOB ]; then
    ln -s /data/$RESUME_FROM_JOB $OUTPUT_DIR
    # Get the job prefix, from the -p prefix part of canu.01.sh, since that's how the job run is uniquely identified
    JOB_PREFIX=$(tail -n1 /data/$RESUME_FROM_JOB/canu-scripts/canu.01.sh | awk 'BEGIN { FS="[ ]+" } { print $5 }' | awk 'BEGIN { FS="\"" } { print $2 }')
else
    JOB_PREFIX=$JOB_NAME
    mkdir -p $OUTPUT_DIR
fi
cd $OUTPUT_DIR

echo "Output will be saved to /data/${JOB_NAME}"

# canu \
#     -d <working-directory> \
#     -p <file-prefix> \
#     [-s specifications] \
#     [-correct | -trim | -assemble] \
#     errorRate=<fraction-error> \
#     genomeSize=<genome-size>\
#     [parameters] \
#     [-pacbio-raw         <read-file>]
#     [-pacbio-corrected   <read-file>]
#     [-nanopore-raw       <read-file>]
#     [-nanopore-corrected <read-file>]
echo '###########################################################################'
echo `qnodes -a`
echo '###########################################################################'
echo `qstat -a`


set -e
# Canu is PBS aware and submits the job to PBS automagically using the name canu_${JOB_NAME}
if [ ! -z $RESUME_FROM_JOB ]; then
    # If resuming from a previous job...just call the command with no input file
    canu -d ${OUTPUT_DIR} -p ${JOB_PREFIX} ${SPEC_FILE} ${ACTION} errorRate=${ERROR_RATE} \
         genomeSize=${GENOME_SIZE}${GENOME_MAGNITUDE} gridOptionsJobName=canu ${PARAMS}
else
    # Otherwise...call the full command
    canu -d ${OUTPUT_DIR} -p ${JOB_PREFIX} ${SPEC_FILE} ${ACTION} errorRate=${ERROR_RATE} \
         genomeSize=${GENOME_SIZE}${GENOME_MAGNITUDE} gridOptionsJobName=canu ${PARAMS} ${INPUT_TYPE} ${INPUT_FILE}
fi
set +e

# Query the Torque Job Id so we can schedule the system to shutdown once it ends
torque_job_id="$(qstat -f |grep "Job Id"| awk 'BEGIN { FS=": " } { print $2 }')"

QUEUE_LENGTH=1
LAST_LATEST_OUTPUT=""

if [ ! -z $torque_job_id ]; then
    while [ $QUEUE_LENGTH -gt 0 ]; do
        sleep 10
        QUEUE_LENGTH=$(qstat -f | grep "job_state" |grep -v "job_state = C" |wc -l)
        LATEST_OUTPUT=$(ls $OUTPUT_DIR/canu-scripts |grep out$ | sort |tail -n 1)
        if [ "$LATEST_OUTPUT" != "$LAST_LATEST_OUTPUT" ]; then
            echo "Current log file is: $LATEST_OUTPUT"
            # cat the contents of the last output. if there's a new output file, then the
            # contents is complete.
            if [ ! -z $OUTPUT_DIR/canu-scripts/${LAST_LATEST_OUTPUT} ] && \
                   [ -f $OUTPUT_DIR/canu-scripts/${LAST_LATEST_OUTPUT} ]; then
                cat $OUTPUT_DIR/canu-scripts/${LAST_LATEST_OUTPUT}
            fi
            LAST_LATEST_OUTPUT=$LATEST_OUTPUT
        fi
    done
    LAST_OUTPUT=$(ls $OUTPUT_DIR/canu-scripts | grep out$ | sort | tail -n 1)
    cat $OUTPUT_DIR/canu-scripts/${LAST_OUTPUT}
    FAILED=$(cat $OUTPUT_DIR/canu-scripts/${LAST_OUTPUT} |grep -i "canu failed")
    if [ ! -z "$FAILED" ]; then
        echo "$FAILED" 1>&2
        ERROR_CODE=1
    else
        ERROR_CODE=0
    fi
else
    echo "FATAL: Error launching canu job!" 1>&2
    ERROR_CODE=1
fi

NNODES=$(cat /etc/JARVICE/nodes | wc -l)
let NSLAVES=$NNODES-1

for i in `cat /etc/JARIVCE/nodes |tail -n $NSLAVES`; do
    echo "Shutting down $i"
    ssh $i sudo halt
done

exit $ERROR_CODE
