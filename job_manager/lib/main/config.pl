use strict;
use warnings;
use vars qw($jobManagerName);
my $jmName = $ENV{JOB_MANAGER_NAME} ? $ENV{JOB_MANAGER_NAME} : $jobManagerName;

#========================================================================
# configure job manager commands and options
#------------------------------------------------------------------------
# commands
#------------------------------------------------------------------------
our %commands = (  # [executionSub, commandHelp, isAppCommand]
#------------------------------------------------------------------------------------------------------------
# commands that manage pipeline execution and depend on data.yml(s)
    inspect     =>  [\&qInspect,     "print the parsed values of all job options to STDOUT in YAML format"], # inspect, mkdir, submit, and extend must parse data.yml
    mkdir       =>  [\&qMkdir,       "create the output directory(s) needed by a job configuration file"], # mkdir, submit, and extend create files on the system 
    submit      =>  [\&qSubmit,      "queue all required data analysis jobs on the HPC server"],
    extend      =>  [\&qExtend,      "queue only new or deleted/unsatisfied jobs"],
    #--------------------------------------------------------------------------------------------------------
    status      =>  [\&qStatus,      "show the updated status of all previously queued jobs"], # non-destructive job-file actions
    start       =>  [\&qStart,       "show the estimated start time of all pending jobs queued by a job file"],
    #--------------------------------------------------------------------------------------------------------
    report      =>  [\&qReport,      "show the log file of a previously queued job"], # non-destructive job-specific actions
    script      =>  [\&qScript,      "show the parsed target script for a previously queued job"],
    ssh         =>  [\&qSsh,         "open a shell, or execute a command, on the host running a job"],  
    top         =>  [\&qTop,         "run the 'top' system monitor on the host running a job"],  
    ls          =>  [\&qLs,          "list the contents of the output directory of a specific job"],  
    #--------------------------------------------------------------------------------------------------------
    delete      =>  [\&qDelete,      "kill job(s) that have not yet finished running"], # destructive job-specific actions
    #--------------------------------------------------------------------------------------------------------
    rollback    =>  [\&qRollback,    "revert the job history to a previously archived status file"], # destructive job-file actions
    purge       =>  [\&qPurge,       "clear all status, script and log files associated with the job set"],
#------------------------------------------------------------------------------------------------------------
# commands that manage the installation, run the app server, etc.
    initialize  =>  [undef,           "refresh the '$jmName' script to establish its program targets", 1], # CLI handles this call
    install     =>  [\&rudiInstall,   "re-run the installation process to update suites, etc.", 1],
    alias       =>  [\&rudiAlias,     "create an alias, i.e., named shortcut, to this RuDI program target", 1],
    add         =>  [\&rudiAdd,       "add one tool suite repository to config/suites.yml and re-install", 1],
    list        =>  [\&rudiList,      "list all pipelines and apps available in this RuDI installation", 1],
    clean       =>  [\&rudiClean,     "delete all unused conda environments from old pipeline verions", 1],
    unlock      =>  [\&rudiUnlock,    "remove all framework and suite repository locks, to reset after error", 1],    
    build       =>  [\&rudiBuild,     "build one container with all of a suite's pipelines and apps", 1],
    serve       =>  [\&rudiServe,     "launch the web server to use interactive apps",  1],
); 
#------------------------------------------------------------------------
# options
#------------------------------------------------------------------------
our %optionInfo = (# [shortOption, valueString, optionGroup, groupOrder, optionHelp]          
    'help'=>        ["h", undef,   "main",    1, "show program help"],   
#------------------------------------------------------------------------------------------------------------
    'dry-run'=>     ["d", undef,   "submit",  0, "check syntax and report actions to be taken; nothing will be queued or deleted"], 
    'delete'=>      ["x", undef,   "submit",  2, "kill matching pending/running jobs when repeat job submissions are encountered"],    
    'execute'=>     ["e", undef,   "submit",  3, "run target jobs immediately in the shell instead of scheduling them"],   
    'force'=>       ["f", undef,   "submit",  4, "suppress warnings that duplicate jobs will be queued, files deleted, etc."],
    'from-action'=> ["t", "<str>", "submit",  5, "queue jobs starting from this named action"],
    'to-action'=>   ["T", "<str>", "submit",  6, "stop queuing jobs after this named action"],
#------------------------------------------------------------------------------------------------------------   
    'job'=>         ["j", "<str>", "job",     0, "restrict command to specific jobID(s) (and sometimes its successors)\n". 
                        "                          allowed formats for <str>:\n".
                        "                            <int>         one specific jobID\n".
                        "                            <int>[<int>]  one specific task of an array job, e.g. 6789[2]\n".
                        "                            <int>*        all jobIDs starting with <int>\n".
                        "                            <int>-<int>   a range of jobsIDs\n".
                        "                            <int>+        all jobIDS greater than or equal to <int>\n".
                        "                            <int>, ...    comma-delimited list of jobIDs\n".                      
                        "                            all           all jobIDs (the default for safe commands)"],
#------------------------------------------------------------------------------------------------------------  
    'count'=>       ["N", "<int>", "rollback",0, "number of sequential rollbacks to perform [1]"],
#------------------------------------------------------------------------------------------------------------
    '_suppress-echo_'=>["NA", undef,   "NA", "NA", 0, "internalOption"], 
    '_extending_'=>    ["NA", undef,   "NA", "NA", 0, "internalOption"], 
    '_q_remote_'=>     ["NA", undef,   "NA", "NA", 0, "internalOption"], 
    '_server_mode_'=>  ["NA", undef,   "NA", "NA", 0, "internalOption"], 
#------------------------------------------------------------------------------------------------------------
    'forks'=>              ["F", undef,   "install", 2, "also install your developer forks of relevant GitHub repositories"],
    'suite'=>              ["s", "<str>", "install", 4, "a single suite to install or build, in form GIT_OWNER/SUITE_NAME"],
    'alias'=>              ["a", "<str>", "alias",   0, "the name of the alias, i.e., the command you will type [rudi]"],
    'profile'=>            ["l", "<str>", "alias",   1, "full path to the bash profile file where the alias will be written [~/.bashrc]"],
    'get'=>                ["g", undef,   "alias",   2, "only show the alias command; --profile is ignored and nothing is written"],
    'container-type'=>     ["y", "<str>", "build",   0, "the type of container to build (pipelines or apps) [pipelines]"],
    'version'=>            ["V", "<str>", "build",   1, "the version of the suite to act on, e.g. v0.0.0 [latest]"],
    'sandbox'=>            ["S", undef,   "build",   2, "pass option '--sandbox' to singularity build"],
    'tool-suite'=>         ["U", "<str>", "serve",   0, "the tool suite to serve, as <git_owner>/<suite_name> [installed single-suite]"],
    'data-dir'=>           ["D", "<str>", "serve",   1, "path to the desired data directory [RUDI_DIR/data]"],
    'port' =>              ["P", "<int>", "serve",   2, "the port that the server will listen on [3839]"],
    'dioxus-container' =>  ["X", "<str>", "serve",   3, "for developers only, the Dioxus container image to use [rust-1.92.0-dx-0.7.9]"],
    # 'runtime'=>            ["m", "<str>", "serve",   5, "execution environment: direct, conda, container, singularity, or auto [auto]"],
);
our %longOptions = map { ${$optionInfo{$_}}[0] => $_ } keys %optionInfo; # for converting short options to long; long options are used internally
#------------------------------------------------------------------------
# associate commands with allowed and required options
#------------------------------------------------------------------------
our %commandOptions =  ( # 0=allowed, 1=required
    inspect    =>  {},
    mkdir      =>  {'dry-run'=>0,'force'=>0},
    submit     =>  {'dry-run'=>0,'delete'=>0,'execute'=>0,'force'=>0,
                    'from-action'=>0,'to-action'=>0,
                    '_suppress-echo_'=>0,'_extending_'=>0},
    extend     =>  {'dry-run'=>0,'delete'=>0,'execute'=>0,'force'=>0,
                    'from-action'=>0,'to-action'=>0}, 
#------------------------------------------------------------------------------------------------------------             
    status     =>  {},
    start      =>  {},
    report     =>  {'job'=>0},
    script     =>  {'job'=>0},
    ssh        =>  {'job'=>0},
    top        =>  {'job'=>0},
    ls         =>  {'job'=>0},
#------------------------------------------------------------------------------------------------------------
    delete     =>  {'dry-run'=>0,'job'=>0,'force'=>0}, 
#------------------------------------------------------------------------------------------------------------
    rollback   =>  {'dry-run'=>0,'force'=>0,'count'=>0}, 
    purge      =>  {'dry-run'=>0,'force'=>0},
    #move       =>  {'move-to'=>1,'force'=>0},
#------------------------------------------------------------------------------------------------------------
    initialize =>  {},
    install    =>  {'forks'=>0},
    alias      =>  {'alias'=>0, 'profile'=>0, 'get'=>0},
    add        =>  {'suite'=>1},
    list       =>  {},
    clean      =>  {},
    unlock     =>  {},
    build      =>  {'suite'=>1, 'container-type'=>0, 'version'=>0, 'sandbox' => 0},
    serve      =>  {'tool-suite'=>0,'data-dir'=>0,'port'=>0,'dioxus-container'=>0}, # ,'runtime'=>0, 'container-version'=>0
); 
#------------------------------------------------------------------------
# suppress the extra demarcating lines used in command execution outputs
#------------------------------------------------------------------------
our %suppressLinesCommands = map { $_ => 1 } qw(
    inspect
    mkdir
    ssh
    top
    ls    
    alias 
);
#------------------------------------------------------------------------
# identify commands that execute once for each pipeline block of data.yml
#------------------------------------------------------------------------
our %pipelineLevelCommands = map { $_ => 1 } qw(
    inspect
    submit    
    extend 
); # mkdir handled differently...
#========================================================================

1;
