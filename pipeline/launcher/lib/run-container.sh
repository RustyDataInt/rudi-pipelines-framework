#!/bin/sh

# this script distributes a singularity run call to a suite-level container
CONTAINER_ACTION=$1

# execute a pipeline action configured by the launcher
if [ "$CONTAINER_ACTION" = "run_pipeline" ]; then
    if [ "$HAS_PIPELINES" != "true" ]; then 
        echo "container does not have any pipelines installed"
        echo "is this an app container?"
        exit 1
    fi 
    exec sh ${LAUNCHER_DIR}/lib/execute.sh

# launch the apps server, passing container metadata
# bind-mount all code, data, and sessions files, to otherwise run like any app server
elif [ "$CONTAINER_ACTION" = "run_apps" ]; then
    if [ "$HAS_APPS" != "true" ]; then 
        echo "container does not have apps installed"
        echo "is this a pipeline container?"
        exit 1
    fi 

    # options as provided by job_manager/lib/commands/serve.pl::launchServerContainer()
    #     run_apps $serverCmd $dataDir $port
    RUN_COMMAND=$2
    DATA_DIR=$3
    SERVER_PORT=$4

    # launch the server
    # TODO: update this to Dioxus
    exec Rscript -e ".libPaths('$STATIC_R_LIBRARY'); mdi::$RUN_COMMAND('$STATIC_RUDI_DIR', dataDir = '$DATA_DIR', port = $SHINY_PORT)"

# otherwise pass all arguments to the container's static RuDI installation directly
else
    if [ "$HAS_PIPELINES" = "true" ]; then
        RUDI_DIR=${STATIC_RUDI_DIR}
        export RUDI_DIR
        exec ${STATIC_RUDI_DIR}/rudi "$@"

    # abort and report usage error
    else
        echo "usage error: please run this apps container using a RuDI command"
        exit 1
    fi
fi
