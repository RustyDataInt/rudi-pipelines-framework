use strict;
use warnings;
use Cwd(qw(getcwd abs_path));

#========================================================================
# 'submit.pl' is the data.yml interpreter (with help from launcher) and job submitter
#------------------------------------------------------------------------
# obeys a simpler threading model than q, with parallel named threads
#   thread with different names run in parallel(async)
#   jobs in the same named thread run in series in the order encountered (sync)
#   branched threading is not supported (i.e. threads never depend on other threads)
#   threads can contain task arrays submitted as a single job where tasks run in parallel
#========================================================================

#========================================================================
# define variables
#------------------------------------------------------------------------
use vars qw($rootDir $libDir $jobManagerName $pipelineName $pipelineOptions
            $qType $schedulerDir $submitTarget
            %options %optionInfo
            $dataYmlFile $statusFile
            $scriptDir $logDir
            $timePath $memoryCorrection);
my (@statusInfo, @jobInfos, @jobIds, $jobsAdded, %threads, 
    $dependJobId, $lastJobId);
my $currentThreadN = -1;
my $nJobsExpected = 0;
my $ymlError = "!" x 20;
my %nonSpecificFamilies = map { $_ => 1 } qw (resources help workflow job-manager);
#========================================================================

#========================================================================
# main execution block
#------------------------------------------------------------------------
sub qSubmit {
    (@statusInfo, @jobInfos, @jobIds, $jobsAdded, %threads) = ();
    my ($qInUse) = checkScheduler();
    checkDeleteExtend(); # includes quiet status update
    my $yamls = getConfigFromLauncher();
    parseAndSubmitJobs($qInUse, $yamls);
    $dependJobId = $lastJobId; # propagate to next YAML chunk in data.yml
    provideFeedback($qInUse);  
}
#------------------------------------------------------------------------
sub checkScheduler {  # make sure there will be a way to run requested jobs
    my $qInUse = $options{execute} ? 'local' : $qType;
    $qInUse or throwError("job submission requires a server scheduler or option --execute", 'submit');
    $qInUse;
}
sub getConfigFromLauncher {
    $ENV{SHOW_LAUNCHER_PROGRESS} = 1;
    $ENV{IS_JOB_MANAGER} = 1;
    $ENV{SAVE_DELAYED_EXECUTION} = !$options{'dry-run'};
    $ENV{SUBMIT_FROM_ACTION} = $options{'from-action'};
    $ENV{SUBMIT_TO_ACTION}   = $options{'to-action'};
    my $jobManagerCommand = getJobManagerCommand(); # returns full config, all commands
    my $parsedYaml = qx|$jobManagerCommand --dry-run|;
    if ($parsedYaml =~ m/$ymlError/) {
        print $parsedYaml;
        exit 1;
    }
    loadYamlFromString($parsedYaml); # potentially a series of configs for multiple jobs
}
sub getJobManagerCommand {
    my ($pipelineAction, $excludePipelineOptions) = @_;
    $pipelineAction or $pipelineAction = '';
    my $developerFlag = $ENV{DEVELOPER_MODE} ? "-d" : "";
    my $pOptions = $excludePipelineOptions ? "" : $pipelineOptions;
    "$rootDir/$jobManagerName $developerFlag $pipelineName $pipelineAction $dataYmlFile $pOptions";
}
sub provideFeedback {  # exit feedback
    my ($qInUse) = @_;
    if ($options{'dry-run'}){
        print "no errors detected\n";
    } elsif($jobsAdded) {  
        generateStatusFile($qInUse); # generate disk copy of queued jobs
        print "\nall jobs queued\n";  
    } else {
        print "\nno jobs to queue\n";  
    } 
}
#========================================================================

#========================================================================
# discover and submit jobs from the parsed yml config, as returned by launcher --dry-run
#------------------------------------------------------------------------
sub parseAndSubmitJobs {
    my ($qInUse, $yamls) = @_;
    $nJobsExpected = 0;
    foreach my $i(0..$#{$$yamls{parsed}}){
        my $parsed = $$yamls{parsed}[$i];
        $$parsed{execute} and $nJobsExpected++;
    }
    unless($nJobsExpected){ # don't die, to support multi-pipeline job files
        print STDERR "$pipelineName: no actions requested\n";
        return;
    }
    my $jobI = 0;
    foreach my $i(0..$#{$$yamls{parsed}}){
        my $parsed = $$yamls{parsed}[$i];
        $$parsed{execute} or next; # the jobs configs we need to act on, in series (jobs may be arrays) 
        my $config = assembleJobConfig($parsed);
        checkExtendability($config) or next; # jobs is already satisfied
        checkSingularityContainer($parsed);
        my $job = $jobI + 1;     
        my ($jobName, $nTasks, $thread, $targetScriptContents) = assembleTargetScript($qInUse, $parsed, $jobI);
        my $targetScriptFile = getTargetScriptFile($qInUse, $jobName);         
        writeTargetScript($targetScriptFile, $targetScriptContents);
        addJob($qInUse, $targetScriptFile, $jobName, $job, $nTasks, $thread, $config);
        $jobI++;
    }
}
# create a compact version of the config to use as a job identification key
sub assembleJobConfig {
    my ($parsed) = @_;
    my $pipelineAction = $$parsed{execute}[0];
    my $config = "$pipelineName $pipelineAction";    
    my $optionFamilies = $$parsed{$pipelineAction};
    $optionFamilies or throwError("missing key '$pipelineAction' in parsed config");
    foreach my $optionFamily(sort keys %$optionFamilies){
        $nonSpecificFamilies{$optionFamily} and next;
        my $options = $$optionFamilies{$optionFamily};
        $options or next;
        $config .= " $optionFamily";
        foreach my $optionLong(sort keys %$options){
            $config .= " $optionLong ".join(" ", @{$$options{$optionLong}});
        }  
    }
    $config;
}
# check for the presence of a required singularity container
sub checkSingularityContainer {
    my ($parsed) = @_;
    my $pipelineAction = $$parsed{execute}[0];
    my $cfg = $$parsed{$pipelineAction};
    $$cfg{singularity} or return; # pipeline does not support containers
    my $runtime = $$cfg{resources}{runtime}[0];
    $runtime eq "auto" or $runtime eq "container" or $runtime eq "singularity" or return; # user enforcing direct execution, regardless of container support
    my $level =    $$cfg{singularity}{level}[0]; # suite or pipeline
    my $uri   = lc($$cfg{singularity}{image}[0]); # oras://ghcr.io/owner/suite/pipeline:v0.0, always with lowercase owner, suite and pipeline names
    my ($imageFile, $version) = ("", "");
    if($level eq "suite"){
        $uri =~ m|.+/(.+):(v\d+\.\d+)$|; 
        my ($lcSuite, $uriVersion) = ($1, $2);
        ($imageFile, $version) = ("$rootDir/containers/$lcSuite/$lcSuite-$uriVersion.sif", $uriVersion);
    } else { # pipeline-level container
        $uri =~ m|.+/(.+)/(.+):(v\d+\.\d+)$|; 
        my ($lcSuite, $lcPipeline, $uriVersion) = ($1, $2, $3);
        ($imageFile, $version) = ("$rootDir/containers/$lcSuite/$lcPipeline/$lcPipeline-$uriVersion.sif", $uriVersion);
    }
    -f $imageFile and return;
    my $developerFlag = $ENV{DEVELOPER_MODE} ? "-d" : "";
    my $pullCommand = "$rootDir/$jobManagerName $developerFlag $pipelineName checkContainer $dataYmlFile $level $version";
    if(system($pullCommand)){
        print 
            "\nYou must pull the container or set '--runtime' to 'direct' or 'conda'\n".
            "to use the '$pipelineName' pipeline.\n\n";
        exit 1;
    }
}
# construct the complete script that is submitted for execution, with all helpers
sub assembleTargetScript {
    my ($qInUse, $parsed, $jobI) = @_; # jobI, not taskI

    # get required values based on config
    my $pipelineAction = $$parsed{execute}[0];
    my $outputOptions = $$parsed{$pipelineAction}{output};
    my $outputDirs = join(" ", @{$$outputOptions{'output-dir'}});
    my $dataNames  = join(" ", @{$$outputOptions{'data-name'}});
    my $nTasks = $$parsed{nTasks}[0];
    my $options = $$parsed{$pipelineAction};
    my $dataName = $nTasks == 1 ? "_$$options{output}{'data-name'}[0]" : "";
    my $nCpu = $$options{resources}{'n-cpu'}[0]; # thus, resources options really cannot be arrayed
    my $nGpu = $$options{resources}{'n-gpu'}[0];
    my $ramPerCpu = $$options{resources}{'ram-per-cpu'}[0]; # does this need to be made lower case, etc?
    my $thread = $$parsed{thread}[0] || "default";    

    # Slurm (Great Lakes) usage parameters
    my $email = $$options{'job-manager'}{email}[0];
    my $account = $$options{'job-manager'}{account}[0]; 
    my $timeLimit = $$options{'job-manager'}{'time-limit'}[0];
    my $partition = $$options{'job-manager'}{partition}[0];
    my $exclusive =  $$options{'job-manager'}{exclusive}[0];

    # set derivative job values
    my ($sgeArrayConfig, $pbsArrayConfig, $slurmArrayConfig) = ('','','');
    $ENV{IS_ARRAY_JOB} = $nTasks > 1 ? "TRUE" : "";
    if ($ENV{IS_ARRAY_JOB}) {
        $sgeArrayConfig = "\n#\$ -t 1-".$nTasks;
        $pbsArrayConfig = "\n#PBS -t 1-".$nTasks;
        $slurmArrayConfig = "\n#SBATCH --array=1-".$nTasks;
    }
    my $pipelineShort = $pipelineName;
    $pipelineShort =~ m|.\S+/(\S+)| and $pipelineShort = $1; # strip suite name prefix in jobName
    my $jobName = "$pipelineShort\_$pipelineAction$dataName";
    $jobName =~ s/\s+/_/g;
    $qInUse eq 'PBS' and $jobName = substr($jobName, 0, 15);
    my $logDir = getLogDir($qInUse);
    $ENV{JOB_LOG_DIR} = $logDir;
    my $slurmLogFile = $ENV{IS_ARRAY_JOB} ? "$logDir/%x.o%A-%a" : "$logDir/%x.o%j";
    my $gpuRequest = "";
    my $slurmExclusive = "";
    if($exclusive){
        $slurmExclusive =  "\n#SBATCH --exclusive";
        $ramPerCpu = 0;
    }

    # set job manager command
    my $jobManagerCommand = getJobManagerCommand($pipelineAction, 1);
    $jobManagerCommand =~ s/\s+$//;
    $jobManagerCommand =~ s/ / \\\n/g;
    
    # set job dependency
    my ($sgeDepend, $pbsDepend, $slurmDepend) = ('','','');    
    if ($threads{$thread}) { # previous job exists on this job's thread
        my $threadJobIds = $threads{$thread}{jobIds};
        my $predJobId = $$threadJobIds[$#$threadJobIds];  
        addJobDependency($predJobId, \$sgeDepend, \$pbsDepend, \$slurmDepend);
    } else {
        $currentThreadN++;
        $threads{$thread}{order} = $currentThreadN; # first job on thread may have dependency from prior chunk of data.yml
        $dependJobId and addJobDependency($dependJobId, \$sgeDepend, \$pbsDepend, \$slurmDepend);
    }
    push @{$threads{$thread}{jobIs}}, $jobI;    

    # set environment variables (when directives are not available)
    $ENV{SLURM_SUBMIT_DIR} = $scriptDir;

    # assemble and return the bash script
    ($jobName, $nTasks, $thread,
"#!/bin/bash

# Sun Grid Engine directives
#\$ -N  $jobName
#\$ -wd $logDir
#\$ -pe smp $nCpu
#\$ -l  vf=$ramPerCpu
#\$ -j  y
#\$ -o  $logDir
#\$ -V $sgeArrayConfig $sgeDepend

# Torque PBS directives
#PBS -N  $jobName
#PBS -d  $logDir
#PBS -l  mem=4gb 
#PBS -j  oe
#PBS -o  $logDir
#PBS -V $pbsArrayConfig $pbsDepend

# Slurm directives
#SBATCH --job-name=$jobName
#SBATCH --cpus-per-task=$nCpu
#SBATCH --gpus-per-task=$nGpu
#SBATCH --mem-per-cpu=$ramPerCpu 
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --time=$timeLimit
#SBATCH --partition=$partition
#SBATCH --output=$slurmLogFile
#SBATCH --account=$account
#SBATCH --mail-user=$email
#SBATCH --mail-type=NONE
#SBATCH --export=ALL $slurmExclusive $slurmArrayConfig $slurmDepend

# initialize job and task
source $libDir/utilities.sh
checkPredecessors # only continue if dependencies did not time out
getTaskID # determine if this is a specific task of an array job

# set a flag and data needed for delayed execution via job submitted to scheduler
export IS_DELAYED_EXECUTION=1
export JOB_OUTPUT_DIRS=\"$outputDirs\"
export JOB_DATA_NAMES=\"$dataNames\"

# pre-execution feedback
echo
echo \"---\"
echo \"job-manager:\"
echo \"    host: \$HOSTNAME\"
echo \"    started: \"`date +'%a %D %R'`

# cascade call to pipeline launcher
TIME_FORMAT=\"---\njob-manager:\n    exit_status: %x\n    walltime: %E\n    seconds: %e\n    maxvmem: %MK\n    swaps: %W\"
$timePath -f \"\n\$TIME_FORMAT\" \\
$jobManagerCommand \$TASK_NUMBER
EXIT_STATUS=\$?

# post-execution feedback
echo \"---\"
echo \"job-manager:\"
echo \"    ended: \"`date +'%a %D %R'`
echo \"...\"

[ \"\$EXIT_STATUS\" -gt 0 ] && EXIT_STATUS=100
exit \$EXIT_STATUS
")
}
sub addJobDependency {
    my ($predJobId, $sgeDepend, $pbsDepend, $slurmDepend) = @_;
    $ENV{JOB_PREDECESSORS} = $predJobId;
    $$sgeDepend   = "\n#\$ -hold_jid $predJobId";
    $$pbsDepend   = "\n#PBS -W depend=afterok:$predJobId";
    $$slurmDepend = "\n#SBATCH --dependency=afterok:$predJobId";
}
sub getTargetScriptFile {
    my ($qInUse, $jobName) = @_;
    my $scriptDir = getScriptDir($qInUse);
    my $scriptBase = "$scriptDir/$jobName".".sh";       
    my $targetScriptFile = $scriptBase;    
    my $i = 0;    
    while (-e $targetScriptFile){
        $i++;
        $targetScriptFile = "$scriptBase.$i";
    }
    $targetScriptFile;
}

sub writeTargetScript { # put it all together and commit the script for this job
    my ($targetScriptFile, $targetScriptContents) = @_;
    $options{'dry-run'} and return;
    open my $outH, ">", $targetScriptFile or
        throwError("could not open:\n    $targetScriptFile\n$!\n", 'submit');  
    print $outH $targetScriptContents;
    close $outH;   
}
#========================================================================

#========================================================================
# process target scripts for queuing
#------------------------------------------------------------------------
sub addJob { # act on the assembled job
    my ($qInUse, $targetScript, $jobName, $job, $nTasks, $thread, $config) = @_;
    my $jobID = submitJob($qInUse, $targetScript, $jobName, $job);
    push @jobIds, $jobID;
    push @{$threads{$thread}{jobIds}}, $jobID;    
    push @statusInfo, [$jobName, $job, $targetScript, $nTasks, $config, $thread];
    unless($options{'_suppress-echo_'} or $qInUse eq 'local'){
        my @jids = @{$threads{$thread}{jobIds}};
        my $pred = @jids == 1 ? "" : $jids[$#jids-1];
        my $jobID = $options{'dry-run'} ? 0 : $jobID; 
        padSubmitEchoColumns($jobName, $nTasks > 1 ? '@' : ' ', $jobID, $job, $pred);   
    }
    return $jobID;
}
sub padSubmitEchoColumns {  # ensure pretty parsing of echoed status table
    my(@in) = @_;
    my @columnWidths = (40, 1, 9, 5, 20);
    foreach my $i(0..4){
        my $value = $in[$i];
        my $outWidth = $columnWidths[$i];    
        $value =~ s/\s+$//;
        $value = substr($value, 0, $outWidth);        
        my $padChar = " ";
        $i == 0 and $value .= " " and $padChar = "-"; 
        my $inWidth = length($value);
        $inWidth < $outWidth and $value .= ($padChar x ($outWidth - $inWidth ));
        print "$value"."  ";
    }
    print "\n";
}
#========================================================================

#========================================================================
# submit job to queue
#------------------------------------------------------------------------
sub submitJob{ # disperse the job as indicated by $qInUse
    my ($qInUse, $targetScript, $jobName, $job) = @_;
    $options{'dry-run'} or qx/chmod u+x $targetScript/;
    if ($qInUse eq 'local'){   
        submitLocal($targetScript, $jobName, $job);
    } else {
        submitQueue($qInUse, $targetScript, $job);
    }
}
sub submitLocal { # run the script in shell if queue is suppressed
    my ($targetScript, $jobName, $job) = @_;
    my $separatorLength = $options{'dry-run'} ? 0 : 80;
    $options{'dry-run'} or print "=" x $separatorLength, "\n";
    $options{'_suppress-echo_'} or print "$jobName\n"; 
    $options{'dry-run'} or print "~" x $separatorLength, "\n";
    my $jobID = 0;
    my $jobI = $job - 1;
    unless($options{'dry-run'}){
        my $logContents = qx/$targetScript 2>&1/;
        print $logContents;
        $jobID = getLocalJobID();
        my $jName = $jobName;
        $jName =~ s/\s+$//;
        my $logFile = getLogDir('local')."/$jName.o$jobID";        
        open my $logFileH, ">", $logFile or die "could not open $logFile for writing: $!\n"; 
        print $logFileH "$logContents\n";
        close $logFileH;
        $jobInfos[$jobI] = {};
        parseLogFile($jobInfos[$jobI], $logContents, 1);        
        (defined $jobInfos[$jobI]{exit_status} and $jobInfos[$jobI]{exit_status} == 0) 
            or die "=" x $separatorLength."\n\njob error: no more jobs will be queued\n";    
        $jobsAdded = 1;          
    }
    $options{'dry-run'} or print "=" x $separatorLength, "\n";
    return $jobID; 
}
sub getLocalJobID {
    my $localDir = getLogDir('local');
    my @logFiles = <$localDir/*.o*>;
    my $maxJobID = 0;
    foreach my $logFile(@logFiles){
        $logFile =~ m|$localDir/.+\.o(\d+)| or next;
        $maxJobID >= $1 or $maxJobID = $1;
    }
    return $maxJobID + 1;
}
sub submitQueue { # submit to cluster scheduler
    my ($qInUse, $targetScript, $job) = @_;
    $options{'dry-run'} and return $job; # dry-run just returns our internal job number
    my $arguments = $qInUse eq 'SGE' ? "-terse" : ''; # causes SGE to return only the job ID as output
    $qInUse eq 'slurm' and $arguments .= "--ignore-pbs";
    my $jobId = qx/$submitTarget $arguments $targetScript/;
    chomp $jobId;
    $jobId or throwError("job submission failed");
    if ($qInUse eq 'slurm') {
        $jobId =~ m/(\d+)/;
        $jobId = $1;
    } else {
        $jobId =~ m/^(\d+).*/;
        $jobId = $1;
    }
    $jobId or throwError("error recovering submitted jobID");
    $jobsAdded = 1; # a boolean flag
    $lastJobId = $jobId;
    return $jobId;
}
#========================================================================

#========================================================================
# generate status file
#------------------------------------------------------------------------
sub generateStatusFile { # create the file that is used by subsequent commands such as delete, etc.
    my ($qInUse) = @_;
    my $time = getTime();
    my $createdArchive = archiveStatusFiles();  # attempt to create an archive copy of a pre-existing status file 
    open my $statusFileH, ">>", $statusFile or throwError("could not open:\n    $statusFile\n$!");
    my $user = $ENV{USER};
    print $statusFileH 
        "qType\t$qInUse\n",
        "submitted\t$time\t$user\n",
        join("\t", qw(  jobName
                        jobID
                        array
                        jobNo
                        predecessors
                        successors
                        start_time
                        exit_status
                        walltime
                        maxvmem   
                        targetScript
                        command
                        instrsFile
                        scriptFile
                        user
                        qType ))."\n";
    foreach my $jobInfo(@statusInfo){
        my ($jobName, $job, $targetScript, $nTasks, $config, $thread) = @$jobInfo;
        my ($startTime, $exitStatus, $wallTime, $maxVmem) = ('', '', '', '');
        my $jobI = $job - 1;
        if($jobInfos[$jobI]){ # job executed locally; already have status information
            $startTime  = $jobInfos[$jobI]{start_time};
            $exitStatus = $jobInfos[$jobI]{exit_status};
            $wallTime   = $jobInfos[$jobI]{walltime};
            $maxVmem    = $jobInfos[$jobI]{maxvmem};   
        }
        $nTasks or $nTasks = 0;
        my $array = $nTasks > 1 ?  join(",", 1..$nTasks) : '';
        my @threadJobs = map { $_ + 1 } @{$threads{$thread}{jobIs}};
        my $pred = join(",", map { $_ < $job } @threadJobs);
        my $succ = join(",", map { $_ > $job } @threadJobs);
        my $jobID = $jobIds[$jobI];
        print $statusFileH 
            join("\t",  $jobName,
                        $jobID,
                        $array,
                        $job,
                        $pred,
                        $succ,
                        $startTime, 
                        $exitStatus, 
                        $wallTime, 
                        $maxVmem,
                        $targetScript,
                        $config,
                        '',
                        '',
                        $user,
                        $qInUse )."\n";
    }
    close $statusFileH;
    $createdArchive or archiveStatusFiles();  # for 1st write of status file, create an immediate archive of it
}
#========================================================================

1;

