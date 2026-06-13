use strict;
use warnings;
$| = 1;

# execute, i.e., launch, a pipeline
# called by the CLI
# configures the environment and launches pipeline worker script(s)

# trap SIGINT to remove any locks when user aborts
$SIG{INT} = sub {
    system("rm -f $ENV{RUDI_DIR}/frameworks/*.lock; ".
           "rm -f $ENV{RUDI_DIR}/suites/*.lock");
    print "\n";
    exit 1;
};

# container status
our $isContainer = $ENV{RUDI_IS_CONTAINER} ? 1 : 0;
our %pipelineContainerCommands = map { $_ => 1 } qw(
    template
    shell
); 

# various framework paths
our %Forks = (definitive => "definitive", developer => "developer-forks");
our $rudiDir = $ENV{RUDI_DIR}; # the installation from which the pipeline was launched
our $definitiveSuitesDir = "$rudiDir/suites/$Forks{definitive}"; # for external suite path resolution
our $developerSuitesDir  = "$rudiDir/suites/$Forks{developer}";
our $launcherDir    = "$ENV{FRAMEWORK_DIR}/pipeline/launcher";
our $workFlowDir    = "$ENV{FRAMEWORK_DIR}/pipeline/workflow";
our $workflowScript = "$workFlowDir/workflow.sh";

# collect the requested pipeline, action, data.yml, and option arguments
our ($pipelineName, $target, @args) = @ARGV;

# handle special case for building suite-level containers
if($pipelineName eq "buildSuite"){
    map { $_ =~ m/launcher\.pl$/ or require $_ } glob("$launcherDir/*.pl");
    buildSuite($target);
    exit;
}

# handle special case in Pipeline Runner where pipelineName is extracted from data.yml
if($pipelineName eq "valuesYaml"){
    require "$launcherDir/yaml.pl";
    my $yml = loadYamlFile($args[0], undef, undef, undef, 1); # suppress null entries
    $pipelineName = $$yml{pipeline}[0];
    $pipelineName =~ s/:.*$//; # strip trailing :version in data.yml pipeline declarations
}

# pipelineName could be a pipeline name only, or be directed to a specific repository as suite/pipeline (but not :version)
# target could be a single pipeline action, or a config file with target actions listed in the 'execute' key
my @pipelineName = reverse(split('/', $pipelineName, 2)); # thus [name, maybe a suite]
my $pipeline;

# discover the pipeline source and whether to use a developer or the definitive fork
# if not directed to a specific repository, use the first matching pipeline name
# developer-forks take precedence in developer mode, ignored otherwise
our @pipelineDirs = split(/\s/, $ENV{PIPELINE_DIRS});
sub getPipeline {
    my ($fork) = @_;
    foreach my $pipelineDir(@pipelineDirs){
        # RUDI_DIR/suites/definitive/rudi-pipelines-suite-template/pipelines/_template/
        $pipelineDir =~ m|/$| and chop $pipelineDir;
        my ($pipelineName, $pipelinesLabel, $suiteRepo, $pipelineFork) = reverse( split('/', $pipelineDir) );
        $suiteRepo or next;
        $pipelineName[0] eq $pipelineName or next;
        $pipelineName[1] and ($pipelineName[1] eq $suiteRepo or next);
        $fork eq $pipelineFork or next;
        return { directory => $pipelineDir, fork => $pipelineFork, suite => $suiteRepo, name => $pipelineName };
    }
}
$ENV{DEVELOPER_MODE} and $pipeline = getPipeline($Forks{developer});
!$pipeline and $pipeline = getPipeline($Forks{definitive});
!$pipeline and die "\nerror: not a known command, pipeline, or job config: $pipelineName\n\n"; 
$pipelineName = $$pipeline{name};
our $pipelineSuite = $$pipeline{suite};
our $pipelineSuiteDir = "$rudiDir/suites/$$pipeline{fork}/$$pipeline{suite}"; 

# working variables
our (%conda, %longOptions, %shortOptions, %optionArrays, %optionValues);

# various pipeline-dependent paths; these are used by the framework to find code
# they are not the values used by running pipelines, which are modified to account for code copying
our $pipelineDir = $$pipeline{directory};
our $sharedDir = "$pipelineSuiteDir/shared";
our $environmentsDir = "$sharedDir/environments";
our $optionsDir      = "$sharedDir/options";
our $modulesDir      = "$sharedDir/modules";
our $suiteBinDir     = "$rudiDir/bin/$pipelineSuite";

# load launcher scripts
map { $_ =~ m/launcher\.pl$/ or require $_ } glob("$launcherDir/*.pl");
use vars qw($jobConfigYml);

# handle special case of delayed execution via job scheduler submit
if($ENV{IS_DELAYED_EXECUTION}){
    executeJobTask($pipelineName, $target, @args);
    exit;
}

# lock the suite repository - only one process can use it at a time since branches may change
# hereafter, use throwError() or releaseMdiGitLock() to end this launcher process (not exit or die)
setMdiGitLock();

# do a first read of requested options to set the pipeline's suite version, as needed
# external suite dependencies are set during the subsequent call to loadPipelineConfig
setPipelineSuiteVersion();

# load the composite pipeline configuration from files
# NB: this is not the user's data configuration, it defines the pipeline itself
our $config = loadPipelineConfig();
$ENV{PIPELINE_NAME} = $$config{pipeline}{name}[0] or throwError("pipeline config error: missing pipeline name\n");

# establish lists of the universal options
our @universalOptionFamilies = sort {
    $$config{optionFamilies}{$a}{order}[0] <=> $$config{optionFamilies}{$b}{order}[0]
} map {
    $$config{optionFamilies}{$_}{universal}[0] ? $_ : ()
} keys %{$$config{optionFamilies}};
our @universalTemplateFamilies = sort {
    $$config{optionFamilies}{$a}{order}[0] <=> $$config{optionFamilies}{$b}{order}[0]
} map {
    $$config{optionFamilies}{$_}{template}[0] ? $_ : ()
} keys %{$$config{optionFamilies}};

# show top-level help for all pipeline actions; never returns
(!$target or $target eq '-h' or $target eq '--help') and showActionsHelp(undef, 1);

# act on and typically terminate execution if target is a restricted command
doRestrictedCommand($target);

# act on one or more actions taken from a requested pipeline chunk in a data config file
our $isSingleAction;
our $showProgress = $ENV{SHOW_LAUNCHER_PROGRESS};
if ($target =~ m/\.yml$/){ 
    extractPipelineJobConfigYml($target, 1);
    my $yaml = loadYamlFile(\$jobConfigYml, undef, undef, undef, 1);
    my %requestedActions = map { $_ => 1 } $$yaml{execute} ? @{$$yaml{execute}} : ();
    my $cmds = $$config{actions}; # execute all requested actions in their proper order
    my @orderedActions = sort { $$cmds{$a}{order}[0] <=> $$cmds{$b}{order}[0] } keys %$cmds;
    unshift @args, $target; # mimic format '<pipeline> <action> <data.yml> <options>' for each action
    my @argsCache = @args;
    my $actionSequenceStarted; # for honoring submit from-action/to-action requests
    foreach my $actionCommand(@orderedActions){
        $actionSequenceStarted = (!$ENV{SUBMIT_FROM_ACTION} or $actionSequenceStarted or $actionCommand eq $ENV{SUBMIT_FROM_ACTION});
        $actionSequenceStarted or next;                # allow user override of pipeline actions in data.yml
        $$cmds{$actionCommand}{universal}[0] and next; # only execute pipeline actions
        $requestedActions{$actionCommand} or next;     # only execute actions requested in data.yml chunk
        executeAction($actionCommand);
        @args = @argsCache; # reset args for next action
        $ENV{SUBMIT_TO_ACTION} and $actionCommand eq $ENV{SUBMIT_TO_ACTION} and last;
    }
    
# a single action specified on the command line    
} else {
    $isSingleAction = 1;
    my $actionCommand = $target;
    executeAction($actionCommand); # never returns
}
$showProgress and print STDERR "\n";

# release our lock on the suite repository
# any functions that terminate execution before this point must also release the lock
releaseMdiGitLock(0);

1;
