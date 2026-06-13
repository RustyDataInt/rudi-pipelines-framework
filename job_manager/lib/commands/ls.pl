use strict;
use warnings;

#========================================================================
# 'ls.pl' lists the contents of the output directory of a specific job
# arguments are taken to be the sub-directory to ls; otherwise ls $TASK_DIR
#========================================================================

#========================================================================
# define variables
#------------------------------------------------------------------------
use vars qw($pipelineOptions);
#========================================================================

#========================================================================
# main execution block
#------------------------------------------------------------------------
sub qLs { 

    # read required information from job log file
    my $command = "ls";
    my $logFileYamls = getJobLogFileContents($command);
    my ($taskId, $taskDir) = (1);
    foreach my $yaml(@$logFileYamls){
        my $task = $$yaml{'task'} or next;
        $taskId  = $$task{'task-id'}[0];
    }
    foreach my $yaml(@$logFileYamls){
        my $action = $$yaml{'execute'} or next;
        my $output = $$yaml{$$action[0]}{'output'};
        my $outputDir = $$output{'output-dir'}[$taskId - 1] || $$output{'output-dir'}[0];
        my $dataName  = $$output{'data-name'} [$taskId - 1] || $$output{'data-name'}[0];
        $taskDir = "$outputDir/$dataName";
    }

    # pass the call to system ls
    $taskDir or throwError("error processing job log file: could not extract the task directory", $command);
    my $lsDir = join("/", $taskDir, $pipelineOptions);
    exec "echo $lsDir; ls -lahrt $lsDir"; 
}
#========================================================================

1;
