use strict;
use warnings;

#========================================================================
# 'ssh.pl' executes an ssh command on the host/node running a live job
# if no command is provided, a shell is opened
#========================================================================

#========================================================================
# define variables
#------------------------------------------------------------------------
use vars qw(%options %allJobs %jobStates %targetJobIDs $taskID $pipelineOptions);
#========================================================================

#========================================================================
# main execution block
#------------------------------------------------------------------------
sub qSsh { 
    my ($command) = @_;

    # read required information from job log file
    $command or $command = "ssh";
    my $logFileYamls = getJobLogFileContents($command, 1);
    my %jmData;
    foreach my $yaml(@$logFileYamls){
        my $jm = $$yaml{'job-manager'} or next;
        foreach my $key(keys %$jm){
            $jmData{$key} = $$jm{$key}[0]
        }
    }
    $jmData{exit_status} and throwError("job has already finished or failed", $command); 

    # pass the call to system ssh
    my $host = $jmData{host};
    $host or throwError("error processing job log file: missing host", $command); 
    my $pseudoTerminal = $ENV{IS_PIPELINE_RUNNER} ? "" : "-t"; # use -t (terminal) to support interactive commands like [h]top
    exec join(" ", "ssh $pseudoTerminal $host", $pipelineOptions);
}
#========================================================================

#========================================================================
# get the contents of the log file for a specific job and task, from option --job
#------------------------------------------------------------------------
sub getJobLogFileContents {
    my ($command, $runningOnly) = @_;
    my $running = $runningOnly ? "running " : "";

    # initialize
    my $error = "command '$command' requires a single $running"."job or task ID";
    my $tooManyJobs = "too many matching job targets\n$error";    
    $options{'no-chain'} = 1; 

    # get a single target job, or a single task of an array job
    if($runningOnly and !$ENV{IS_PIPELINE_RUNNER}){
        updateStatusQuietly();
        my %runningJobs;
        foreach my $jobId(keys %allJobs){
            $jobStates{$jobId} and $jobStates{$jobId} eq 'R' and $runningJobs{$jobId} = $allJobs{$jobId};
        }
        if(!scalar(keys %runningJobs)){
            print "\nno running jobs, nothing to do\n\n";
            exit;
        }
        parseJobOption(\%runningJobs, 1); 
    } else {
        getJobStatusInfo();
        parseJobOption(\%allJobs, 1); 
    }
    my @jobIDs = keys %targetJobIDs; 
    @jobIDs == 1 or throwError($tooManyJobs, $command); 
    my $jobID = $jobIDs[0];

    # get and check the job/task log file
    my ($qType, $array, $inScript, $command_, $instrsFile, $scriptFile, $jobName) = @{$targetJobIDs{$jobID}};
    !$taskID and $array and $array =~ m/,/ and $taskID = promptForTaskSelection($jobID, $array);
    my $logFiles;
    if($taskID){
        $logFiles = [ getArrayTaskLogFile($qType, $jobID, $taskID, $jobName) ];
    } else {
        $logFiles = getLogFiles($qType, $jobName, $jobID, $array);
    }
    @$logFiles == 1 or throwError($tooManyJobs, $command_); 
    my $logFile = @$logFiles[0];  
    -e $logFile or throwError("job log file not found\n$error", $command_);   

    # extract the job manager status reports from the job/task log file
    my $yamls = loadYamlFromString( slurpFile($logFile) );
    $$yamls{parsed}; # a reference to an array of YAML chunks in the job's log file
}
#========================================================================

1;
