use strict;
use warnings;

#========================================================================
# define variables
#------------------------------------------------------------------------
my $silently = "> /dev/null 2>&1";
#========================================================================

#========================================================================
# discover Singularity on the system, if available
#------------------------------------------------------------------------
sub getSingularityLoadCommand {

    # first, see if singularity or apptainer command is already present and ready
    # NB: apptainer installations provide alias `singularity` to `apptainer`
    #     but commands report logs info as `apptainer`
    my $command = "echo $silently";
    checkForSingularity($command) and return $command; 
    
    # if not, attempt to use load-command from singularity.yml
    my $ymlFile = "$ENV{RUDI_DIR}/config/singularity.yml";
    if(-e $ymlFile){
        my $yamls = loadYamlFromString( slurpFile($ymlFile) );
        $command = $$yamls{parsed}[0]{'load-command'};
        if($command and $$command[0]){
            $command = "$$command[0] $silently";
            checkForSingularity($command) and return $command;
        }
    }

    # if not, attempt to use "module load singularity" as the default singularity load command
    $command = "module load singularity";
    checkForSingularity($command) and return $command;

    # no success
    undef;
}
sub checkForSingularity { # return TRUE if a proper singularity exists in system PATH after executing $command
    my ($command) = @_;
    system("$command; singularity --version $silently") and return; # command did not exist, system threw an error
    my $version = qx|$command; singularity --version|;
    $version =~ m/^(singularity|apptainer).+version.+/; # may fail if not a true singularity target (e.g., on greatlakes)
}
#========================================================================

1;
