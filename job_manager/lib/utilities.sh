#--------------------------------------------------------------------
# these functions are automatically called by every target script
#--------------------------------------------------------------------
checkPredecessors() {  # check whether predecessors timed out
    if [ "$SCHEDULER_TYPE" = "SGE" ]; then  # predecessor time-out checking only required for SGE
        if [ "$JOB_PREDECESSORS" != "" ]; then 
            sleep 2  # give the prior job's log file a moment to finish being written    
            # Split the colon-separated list into individual job IDs
            _job_ids="$JOB_PREDECESSORS"
            while [ -n "$_job_ids" ]; do
                case "$_job_ids" in
                    *:*)
                        JOB_ID="${_job_ids%%:*}"
                        _job_ids="${_job_ids#*:}"
                        ;;
                    *)
                        JOB_ID="$_job_ids"
                        _job_ids=""
                        ;;
                esac
                
                FAILED="$(grep -L 'q: exit_status:' "$SCHEDULER_LOG_DIR"/*.o"$JOB_ID"* 2>/dev/null)"
                if [ -n "$FAILED" ]; then 
                    echo "predecessor job $JOB_ID failed to report an exit status (it probably timed out)"
                    exit 100
                fi
            done
        fi
    fi
}

getTaskID() {  # $TASK_ID is not set if this is not an array job
    if [ -z "$PBS_ARRAYID" ] && [ -z "$SGE_TASK_ID" ] && [ -z "$SLURM_ARRAY_TASK_ID" ]; then
        TASK_NUMBER=1
        TASK_ID=""     
    elif [ -n "${PBS_ARRAYID+x}" ]; then
        TASK_NUMBER="$PBS_ARRAYID"
        TASK_ID="--task-id $PBS_ARRAYID"
    elif [ -n "${SGE_TASK_ID+x}" ]; then
        TASK_NUMBER="$SGE_TASK_ID"
        TASK_ID="--task-id $SGE_TASK_ID"
    elif [ -n "${SLURM_ARRAY_TASK_ID+x}" ]; then
        TASK_NUMBER="$SLURM_ARRAY_TASK_ID"
        TASK_ID="--task-id $SLURM_ARRAY_TASK_ID"
    fi
}
#--------------------------------------------------------------------
