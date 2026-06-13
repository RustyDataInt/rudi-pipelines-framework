#!/bin/sh
# utility functions for managing a shell-based workflow script

#--------------------------------------------------------------------
# detect shell capabilities for pipe error checking
#--------------------------------------------------------------------
if [ -n "$BASH_VERSION" ]; then
    SHELL_TYPE="bash"
elif ( set -o pipefail ) 2>/dev/null; then
    set -o pipefail
    SHELL_TYPE="pipefail"
else
    SHELL_TYPE="basic"
    echo "WARNING: Advanced pipe error checking not available in this shell"
    echo "Pipe errors may only be detected for the last command in a pipeline"
fi

#--------------------------------------------------------------------
# place some internal utilities into PATH
#--------------------------------------------------------------------
export PATH=$MODULES_DIR/utilities:$PATH

#--------------------------------------------------------------------
# get and set the last successfully completed step in a multi-step serial workflow
#--------------------------------------------------------------------
setStatusFile() { # construct a rule-based status file name
    if [ "$OUTPUT_DIR" = "" ]; then
        echo "missing variable: OUTPUT_DIR"
        exit 1
    fi
    if [ ! -d "$OUTPUT_DIR" ]; then # OUTPUT_DIR must exist, it will not be created
        echo "directory does not exist: $OUTPUT_DIR"
        exit 1
    fi
    if [ "$PIPELINE_NAME" = "" ]; then
        echo "missing variable: PIPELINE_NAME"
        exit 1
    fi
    if [ "$PIPELINE_ACTION" = "" ]; then
        echo "missing variable: PIPELINE_ACTION"
        exit 1
    fi 
    if [ "$DATA_NAME" = "" ]; then
        echo "missing variable: DATA_NAME"
        exit 1
    fi
    if [ "$TASK_PIPELINE_DIR" = "" ]; then
        echo "missing variable: TASK_PIPELINE_DIR"
        exit 1
    fi
    if [ "$TASK_ACTION_DIR" = "" ]; then
        echo "missing variable: TASK_ACTION_DIR"
        exit 1
    fi
    if [ ! -d "$TASK_ACTION_DIR" ]; then mkdir -p "$TASK_ACTION_DIR"; fi # a direct child of TASK_PIPELINE_DIR, under OUTPUT_DIR
    STATUS_FILE=$TASK_PIPELINE_DIR/$DATA_NAME.$PIPELINE_NAME.status # a pipeline level file, includes all steps for all actions
    if [ ! -e "$STATUS_FILE" ]; then touch "$STATUS_FILE"; fi  
}

getWorkflowStatus() {
    setStatusFile
    LAST_SUCCESSFUL_STEP=$(awk '$1=="'"$PIPELINE_ACTION"'"' "$STATUS_FILE" | tail -n1 | cut -f2)
    if [ "$LAST_SUCCESSFUL_STEP" = "" ]; then LAST_SUCCESSFUL_STEP=0; fi
}

setWorkflowStatus() {
    setStatusFile
    STEP_NUMBER=$1
    STEP_NAME=$2
    STEP_SCRIPT=$3
    DATE=$(date)
    printf "%s\t%s\t%s\t%s\n" "$PIPELINE_ACTION" "$STEP_NUMBER" "$STEP_NAME" "$DATE" >> "$STATUS_FILE"
}

resetWorkflowStatus() { # override any prior job outcomes and force a new status
    setStatusFile
    if [ "$LAST_SUCCESSFUL_STEP" != "" ]; then
        awk '$1!="'"$PIPELINE_ACTION"'"||$2<='"$LAST_SUCCESSFUL_STEP" "$STATUS_FILE" >> "$STATUS_FILE.tmp"
        mv -f "$STATUS_FILE.tmp" "$STATUS_FILE"
    fi
}

showWorkflowStatus() {
    setStatusFile
    STATUS_LINE_LENGTH=$(wc -l < "$STATUS_FILE")
    if [ "$STATUS_LINE_LENGTH" -gt "0" ] && [ "$QUIET" = "0" ]; then
        printf "ACTION\tSTEP#\tSTEP\tDATE\n"
        cat "$STATUS_FILE"
        echo
    fi
}
#--------------------------------------------------------------------

#--------------------------------------------------------------------
# execute a pipeline step by sourcing its script, if not already successfully completed
#--------------------------------------------------------------------
runWorkflowStep() {   
    STEP_NUMBER=$1
    STEP_NAME=$2
    STEP_SCRIPT=$3
    getWorkflowStatus    
    STEP_SUMMARY="$PIPELINE_NAME $PIPELINE_ACTION, step $STEP_NUMBER = $STEP_NAME"
    if [ "$LAST_SUCCESSFUL_STEP" -lt "$STEP_NUMBER" ]; then
        case "$STEP_SCRIPT" in
            /*) TARGET_SCRIPT=$STEP_SCRIPT ;; # an absolute script path was provided
            *)  TARGET_SCRIPT=$ACTION_DIR/$STEP_SCRIPT ;; # path interpreted relative to current action step
        esac
        echo
        echo "executing: $STEP_SUMMARY ($(date '+%Y-%m-%d %H:%M:%S'))"
        . "$TARGET_SCRIPT" # NB: script is responsible for calling checkPipe to validate execution success
        setWorkflowStatus "$STEP_NUMBER" "$STEP_NAME" "$STEP_SCRIPT"
    else
        echo    
        echo "already succeeded: $STEP_SUMMARY"
    fi    
}
#--------------------------------------------------------------------
# alternatively let the caller handle the execution, just communicate step state
# e.g., to have another flow controller, like snakemake, handle a step's execution
#--------------------------------------------------------------------
checkWorkflowStep() {
    STEP_NUMBER=$1
    STEP_NAME=$2
    STEP_SCRIPT=$3
    getWorkflowStatus    
    STEP_SUMMARY="$PIPELINE_NAME $PIPELINE_ACTION, step $STEP_NUMBER = $STEP_NAME"
    if [ "$LAST_SUCCESSFUL_STEP" -lt "$STEP_NUMBER" ]; then
        STEP_SATISFIED=""    
    else
        echo    
        echo "already succeeded: $STEP_SUMMARY"
        STEP_SATISFIED="TRUE"        
    fi    
}

finishWorkflowStep() {
    setWorkflowStatus "$STEP_NUMBER" "$STEP_NAME" "$STEP_SCRIPT"    
}
#--------------------------------------------------------------------

#--------------------------------------------------------------------
# ensure that all commands in a pipe had exit_status=0
# use after a shell command or piped stream to force pipeline to fail if command fails
#--------------------------------------------------------------------
checkPipe() {  
    if [ "$SHELL_TYPE" = "bash" ]; then
        # Use bash's PIPESTATUS array for full pipe checking
        PSS="${PIPESTATUS[*]}"
        for PS in $PSS; do
            if [ "$PS" -gt 0 ]; then
                echo "pipe error: [$PSS]"
                exit 99
            fi
        done
    elif [ "$SHELL_TYPE" = "pipefail" ]; then
        # With pipefail set, $? reflects any failure in the pipe
        EXIT_CODE=$?
        if [ "$EXIT_CODE" -ne 0 ]; then
            echo "pipe error: exit code $EXIT_CODE"
            exit 99
        fi
    else
        # Basic shells can only check the last command
        EXIT_CODE=$?
        if [ "$EXIT_CODE" -ne 0 ]; then
            echo "pipe error: exit code $EXIT_CODE (last command only)"
            exit 99
        fi
    fi
}
#--------------------------------------------------------------------

#--------------------------------------------------------------------
# ensure a job will have data to work on
#--------------------------------------------------------------------
checkForData() { # ensure that a data stream will have at least one line of data
    COMMAND="$1"
    if [ "$COMMAND" = "" ]; then
        echo "checkForData error: system command not provided"
        exit 100
    fi
    LINE_1=$(eval "$COMMAND" | head -n1)
    if [ "$LINE_1" = "" ]; then
        echo "no data; exiting quietly"
        exit 0
    fi
}

waitForFile() {  # wait for a file to appear on the file system; default timeout=60 seconds
    FILE="$1"
    TIME_OUT="$2"
    if [ "$FILE" = "" ]; then
        echo "waitForFile error: file not provided"
        exit 100
    fi
    if [ "$TIME_OUT" = "" ]; then
        TIME_OUT=60
    fi
    ELAPSED=0
    while [ ! -s "$FILE" ]
    do
        sleep 2
        ELAPSED=$((ELAPSED + 2))
        if [ "$ELAPSED" -gt "$TIME_OUT" ]; then
            echo "waitForFile error: $FILE not found after $TIME_OUT seconds"
            exit 100
        fi
    done
}

checkFileExists() {  # verify non-empty file, or first of glob if called as checkFileExists $GLOB
    FILE="$1"
    if [ "$FILE" = "" ]; then
        echo "checkFileExists error: file not provided"
        exit 100
    fi
    if [ ! -s "$FILE" ]; then
        echo "file empty or not found on node $(hostname)"
        echo "$FILE"
        exit 100
    fi
}
#--------------------------------------------------------------------

#--------------------------------------------------------------------
# download a binary from GitHub as needed and return its path in bin directory
#--------------------------------------------------------------------
getVersionedBinary() {
    GITHUB_REPO=$1 # e.g., wilsontelab/hf3_tools
    BINARY_NAME=$2

    # get a usable SUITE_BIN_DIR, mainly if working in a container
    SUITE_BIN_DIR_WRK=${SUITE_BIN_DIR}
    if [ ! -d "${SUITE_BIN_DIR_WRK}" ] || [ ! -w "${SUITE_BIN_DIR_WRK}" ]; then
        SUITE_BIN_DIR_WRK=${TMP_DIR}/${SUITE_NAME}
    fi

    # developer mode expects that the developer has compiled their working binary
    # or otherwise obtained it so they are in full control of the binary in use
    if [ "$DEVELOPER_MODE" != "" ]; then
        VERSION_DIR=${SUITE_BIN_DIR_WRK}/dev
        mkdir -p "${VERSION_DIR}"
        VERSIONED_BINARY_PATH=${VERSION_DIR}/${BINARY_NAME}
        export VERSIONED_BINARY_PATH
        if [ ! -f "${VERSIONED_BINARY_PATH}" ]; then
            echo "missing developer ${BINARY_NAME} binary"
            echo "expected file: ${VERSIONED_BINARY_PATH}"
            echo "developers must compile the binary using CLI commands, or manually download it"
            exit 1
        fi

    # otherwise use the working suite version to download the binary from GitHub as needed
    else 
        VERSION_TAG=${SUITE_VERSION}

        # for containers, always match the version of a binary to the version of the scripts in /srv/active/rudi
        if [ "${RUDI_IS_CONTAINER}" != "" ]; then
            VERSION_TAG=${ACTIVE_SUITE_VERSION}

        # for non-containers, get the latest stable version if user did not request otherwise
        elif [ "${VERSION_TAG}" = "latest" ] || [ "${VERSION_TAG}" = "main" ] || [ "${VERSION_TAG}" = "HEAD" ]; then
            VERSION_TAG=$(curl -s https://api.github.com/repos/${GITHUB_REPO}/releases/latest | jq -r .tag_name)
        fi

        VERSION_DIR=${SUITE_BIN_DIR_WRK}/${VERSION_TAG}
        mkdir -p "${VERSION_DIR}"
        VERSIONED_BINARY_PATH=${VERSION_DIR}/${BINARY_NAME}
        export VERSIONED_BINARY_PATH
        if [ ! -f "${VERSIONED_BINARY_PATH}" ]; then
            ASSET="${VERSION_TAG}/${BINARY_NAME}-x86_64-unknown-linux-gnu.tar.gz" # as created by taiki-e/upload-rust-binary-action
            URL="https://github.com/${GITHUB_REPO}/releases/download/${ASSET}"
            curl -sLf "${URL}" | tar -xz -C "${VERSION_DIR}"
            if [ ! -f "${VERSIONED_BINARY_PATH}" ]; then
                echo "failed to download ${BINARY_NAME} binary from GitHub"
                echo "expected URL: ${URL}"
                exit 1
            fi
            chmod +x "${VERSIONED_BINARY_PATH}"
        fi
    fi
}
#--------------------------------------------------------------------
