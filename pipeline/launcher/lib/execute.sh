#!/bin/sh

# this script is called to execute a pipeline action

# activate the runtime environment
eval "$(${MICROMAMBA} shell hook --shell posix)"
micromamba deactivate # the micromamba function in the hook, not the binary
micromamba activate ${ENVIRONMENTS_DIR}/${CONDA_NAME}

# load singularity in the running job if instructed by the pipeline via env-vars
# i.e., if the pipeline actions require running a singularity container
if [ "$LOAD_SINGULARITY" != "" ] && [ "$SINGULARITY_LOAD_COMMAND" != "" ]; then
    echo "loading singularity"
    SINGULARITY_LOAD_COMMAND=$(echo "$SINGULARITY_LOAD_COMMAND" | sed 's/>.*//')
    $SINGULARITY_LOAD_COMMAND
fi

# prepare the task workflow for execution
. ${WORKFLOW_SH}
if [ "${LAST_SUCCESSFUL_STEP}" != "" ]; then
    echo "rolling back to pipeline step ${LAST_SUCCESSFUL_STEP}"
    echo ""
    resetWorkflowStatus
fi
showWorkflowStatus

# execute the task, i.e., apply the pipeline action to the current data set
. ${ACTION_SCRIPT}

# as needed, create an app data package from this task's output
perl ${WORKFLOW_DIR}/package.pl
