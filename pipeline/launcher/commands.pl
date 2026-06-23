use strict;
use warnings;
use File::Basename;

# subs for handling universal pipeline commands
# most terminate execution or never return

# working variables
use vars qw($pipeline $pipelineName $pipelineSuiteDir $launcherDir $rudiDir
            @args $config %longOptions $workflowScript %workingSuiteVersions
            $isContainer %pipelineContainerCommands);

# switch for acting on restricted commands
sub doRestrictedCommand {
    my ($target) = @_;
    my %restricted = (

        # commands advertised to users
        template => \&runTemplate,
        conda    => \&runConda,
        build    => \&runBuild,
        shell    => \&runShell,
        status   => \&runStatus,
        rollback => \&runRollback,
        rust     => \&runRust,

        # commands for developers or framework-internal use
        options         => \&runOptions, 
        optionsTable    => \&runOptionsTable,
        valuesYaml      => \&runValuesYaml,
        checkContainer  => \&checkContainer,
        buildSuite      => \&buildSuite
    );
    if($restricted{$target}){
        if($isContainer and !$pipelineContainerCommands{$target}){
            throwError("command '$target' cannot be executed from a pipeline container");
        }
        &{$restricted{$target}}();
    }
}

#------------------------------------------------------------------------------
# return a template for data-file.yml for the user to modify
#------------------------------------------------------------------------------
sub runTemplate {
    
    # special handling of command line option flags
    my %options;
    my $help = "help";
    my $allOptions  = "all-options";
    my $addComments = "add-comments";
    foreach my $arg(@args){
        ($arg eq '-h' or $arg eq "--$help") and $options{$help}  = 1;        
        ($arg eq '-a' or $arg eq "--$allOptions")  and $options{$allOptions}  = 1;        
        ($arg eq '-c' or $arg eq "--$addComments") and $options{$addComments} = 1;
    }
    
    # if requested, show custom action help
    if($options{$help}){
        my $desc = getTemplateValue($$config{actions}{template}{description});
        my $pname = $$config{pipeline}{name}[0];
        print "\n$pname template: $desc\n";
        print  "\nusage: rudi $pname template [-a/--$allOptions] [-c/--$addComments] [-h/--help]\n";
        print  "\n    -a/--$allOptions    include all possible options [only include options needing values]";
        print  "\n    -c/--$addComments   add instructional comments for new users [comments omitted]";
        print "\n\n";
        releaseRudiGitLock(0);
    }
    
    # print the template to STDOUT
    writeDataFileTemplate($options{$allOptions}, $options{$addComments});
    releaseRudiGitLock(0);
}

#------------------------------------------------------------------------------
# create or list the runtime environment(s) required by a pipeline
#------------------------------------------------------------------------------
sub runConda {
    
    # see if user provided server.yml
    my $defaultServerYml = Cwd::abs_path("$rudiDir/config/pipelines.yml");
    my @newArgs = ($args[0] and $args[$#args] =~ m/\.yml$/) ? (pop @args) : ();
    
    # special handling of command line option flags
    # NOTE: as always, --version was already handled by launcher.pl: setPipelineSuiteVersion()
    my %options;
    my $help    = "help";
    my $version = "version";
    my $list    = "list";
    my $create  = "create";
    my $force   = "force";
    foreach my $arg(@args){
        ($arg eq '-h' or $arg eq "--$help")    and $options{$help}    = 1;
        ($arg eq '-l' or $arg eq "--$list")    and $options{$list}    = 1;
        ($arg eq '-c' or $arg eq "--$create")  and $options{$create}  = 1;
        ($arg eq '-f' or $arg eq "--$force")   and $options{$force}   = 1;
    }
    (!$options{$list} and !$options{$create}) and $options{$help}  = 1;     
    my $error = ($options{$list} and $options{$create}) ?
                "\noptions '--$list' and '--$create' are mutually exclusive\n" : "";
                
    # if requested, show custom action help
    my $pname = $$config{pipeline}{name}[0];
    if($options{$help} or $error){
        my $usage;
        my $desc = getTemplateValue($$config{actions}{conda}{description});
        $usage .= "\n$pname conda: $desc\n";
        $usage .=  "\nusage: rudi $pname conda [options]\n";
        $usage .=  "\n    -v/--$version   the suite version to query, as a git release tag or branch [latest]";
        $usage .=  "\n    -l/--$list      show the yml config file for each pipeline action";
        $usage .=  "\n    -c/--$create    if needed, create/update the required environments";
        $usage .=  "\n    -f/--$force     do not prompt for permission to create/update environments";    
        $error and throwError($error.$usage);
        print "$usage\n\n";
        releaseRudiGitLock(0);
    }
    
    # list or create runtime environments in action order
    @args = @newArgs;
    showCreateEnvironments($options{$create}, $options{$force});
    releaseRudiGitLock(0);
}

#------------------------------------------------------------------------------
# build a Singularity image and post to a registry (for suite developers)
#------------------------------------------------------------------------------
sub runBuild { 

    # command has limited options, collect them now
    # NOTE: as always, --version was already handled by launcher.pl: setPipelineSuiteVersion()
    my $help    = "help";
    my $version = "version";
    my $force   = "force";
    my $sandbox = "sandbox";
    my %options;   
    $args[0] or $args[0] = ""; 
    ($args[0] eq '-h' or $args[0] eq "--$help")    and $options{$help}    = 1;
    ($args[0] eq '-f' or $args[0] eq "--$force")   and $options{$force}   = 1;
    ($args[0] eq '-s' or $args[0] eq "--$sandbox") and $options{$sandbox} = 1;        
                
    # if requested, show custom action help
    my $pname = $$config{pipeline}{name}[0];
    if($options{$help}){
        my $usage;
        my $desc = getTemplateValue($$config{actions}{build}{description});
        $usage .= "\n$pname build: $desc\n";
        $usage .=  "\nusage: rudi $pname build [options]\n";  
        $usage .=  "\n    -h/--$help     show this help";    
        $usage .=  "\n    -v/--$version  the suite version to build from, as a git release tag or branch [latest]";
        $usage .=  "\n    -f/--$force    overwrite existing container images";  
        $usage .=  "\n    -s/--$sandbox  run singularity with the --sandbox option set"; 
        print "$usage\n\n";
        releaseRudiGitLock(0);
    }
    
    # call Singularity build action
    buildSingularity($options{$sandbox} ? "--sandbox" : "", $options{$force} ? "--force" : "");
    releaseRudiGitLock(0);
}

#------------------------------------------------------------------------------
# open a command shell, or run a command, in a pipeline's runtime environment
#------------------------------------------------------------------------------
sub runShell {

    # command has limited options, collect --help first
    my $help    = "help";
    my $action  = "action";
    my $runtime = "runtime";
    my %options;
    $args[0] or $args[0] = ""; 
    ($args[0] eq '-h' or $args[0] eq "--$help") and $options{$help} = 1;

    # if requested, show custom action help
    sub showShellHelp {
        my $usage;
        my $pname = $$config{pipeline}{name}[0];   
        my $desc = getTemplateValue($$config{actions}{shell}{description});
        $usage .= "\n$pname shell: $desc\n";
        $usage .=  "\nusage: rudi $pname shell [options]\n";  
        $usage .=  "\n    -h/--help     show this help"; 
        $usage .=  "\n    -a/--action   the pipeline action whose environment will be activated in the shell [do]";
        $usage .=  "\n    -m/--runtime  execution environment: one of direct, container, or auto (container if supported) [auto]";
        print "$usage\n\n";
        releaseRudiGitLock(0);
    }
    $options{$help} and showShellHelp();

    # collect and set the runtime options
    while($args[0] and $args[0] =~ m/^-/){
        if($args[0] eq '-a' or $args[0] eq "--$action"){
            $options{$action} = $args[1];
        } elsif($args[0] eq '-m' or $args[0] eq "--$runtime"){
            $options{$runtime} = $args[1];
        } else {
            print "\nunknown option: $args[0]\n";
            showShellHelp();
        }
        shift @args; 
        shift @args;
    }
    setRuntimeEnvVars($options{$runtime});

    # collect and set the pipeline action options
    my $defaultAction = $$config{actions}{do} ? "do" : "";
    $action = $options{$action} || $defaultAction;
    $action or throwError("option '--action' is required to launch a shell");
    my $cmd = getCmdHash($action);
    !$cmd and showActionsHelp("unknown action for pipeline $pipelineName: $action", 1);        
    my $configYml = assembleCompositeConfig($cmd, $action);
    parseAllDependencies($action);
    my $cnd = getEnvironmentPaths($configYml, $action);

    # set the shell command based on runtime mode
    my $shellCommand;
    my $commandArgs = join(" ", @args); # remaining arguments passed as a command to shell
    if($ENV{IS_CONTAINER}){             # or open an interactive shell if no command
        my $isSuite = $ENV{CONTAINER_LEVEL} eq 'suite';
        my $uris = getContainerUris($ENV{CONTAINER_MAJOR_MINOR}, $isSuite, "pipelines");
        my $singularity = "$ENV{SINGULARITY_LOAD_COMMAND}; singularity";
        pullPipelineContainer($uris, $singularity, $isSuite, "pipelines");
        $commandArgs =~ m/\S/ or $commandArgs = "bash";
        my $script = join("; ",
            "eval \"\$(\${MICROMAMBA} shell hook --shell bash)\"",
            "micromamba activate \${ENVIRONMENTS_DIR}/$$cnd{name}", # the micromamba function in the hook, not the binary
            "exec $commandArgs"
        ).";";
        $shellCommand = "$singularity exec $$uris{imageFile} bash -c '$script'"; # implicitly binds $PWD
    } else {
        -d $$cnd{dir} or throwError(
            "missing environment for action '$action'\n".
            "create it using 'rudi $pipelineName conda --create' before opening a direct shell"
        );  
        my $scriptFile = glob("~/.rudi.shellFile");
        my $script = join("\n",
            "rm -f $scriptFile", # the script file deletes itself
            $$cnd{shell_hook},
            "micromamba deactivate"
        )."\n";
        if($commandArgs =~ m/\S/){ # run a single command
            $script .= "$$cnd{micromamba} run --prefix $$cnd{dir} $commandArgs\n";
            $shellCommand = "bash $scriptFile";
        } else { # open an interactive shell in the activated environment
            $script .= "micromamba activate $$cnd{dir}\n";
            $shellCommand = "bash --rcfile $scriptFile"; # --rcfile configures environment before passing interactive shell to user
        }
	    open my $outH, ">", $scriptFile or throwError("could not write to $scriptFile: $!");
	    print $outH $script; 
	    close $outH;
    }

    # launch the shell, either interactively or to run one command
    releaseRudiGitLock();
    exec $shellCommand;
}

#------------------------------------------------------------------------------
# report on the current job completion status of the pipeline for a specific data directory
#------------------------------------------------------------------------------
sub runStatus {
    
    # check for a proper request
    my ($subjectAction, $error);
    ($subjectAction, @args) = @args;
    $subjectAction or $error .= "missing action\n";
    my $cmd = getCmdHash($subjectAction); 
    if(!$cmd){
        $subjectAction and $error .= "unkown action: $subjectAction\n";
        throwError(
            $error.
            "usage: rudi $$config{pipeline}{name}[0] status <action> [data.yml] [OPTIONS]"
        )
    }
    
    # get and check options
    parseAllOptions('status', $subjectAction);
    checkRestrictedTask($subjectAction);
    
    # do the work
    print "\n";
    releaseRudiGitLock();
    exec "bash -c 'source $workflowScript; showWorkflowStatus'";  
}

#------------------------------------------------------------------------------
# clear the job status for a specific data directory to force jobs to start anew
#------------------------------------------------------------------------------
sub runRollback {
    
    # check for a proper request
    my ($subjectAction, $statusLevel, $error);
    ($subjectAction, $statusLevel, @args) = @args;
    $subjectAction or $error .= "missing action\n";
    my $cmd = getCmdHash($subjectAction); 
    if(!$cmd or !defined $statusLevel){
        !$cmd and $subjectAction and $error .= "unkown action: $subjectAction\n";
        defined $statusLevel or $error .= "missing status level\n";
        throwError(
            $error.
            "usage: rudi $$config{pipeline}{name}[0] rollback <action> <last_successful_step> [data.yml] [OPTIONS]"
        )   
    }
    
    # get and check options
    parseAllOptions('rollback', $subjectAction);
    checkRestrictedTask($subjectAction);
    
    # do it
    doRollback($subjectAction, $statusLevel, 1);
}
sub doRollback {
    my ($subjectAction, $statusLevel, $exit) = @_;
    
    # request permission
    getPermission("Pipeline status will be permanently reset.") or releaseRudiGitLock(1);
    $ENV{PIPELINE_ACTION} = $subjectAction;
    $ENV{LAST_SUCCESSFUL_STEP} = $statusLevel;
    
    # do the work
    system("bash -c 'source $workflowScript; resetWorkflowStatus'");
    $exit and releaseRudiGitLock(0);
}

#------------------------------------------------------------------------------
# load a Rust environment or compile pipeline Rust executables (for developers)
#------------------------------------------------------------------------------
sub runRust {

    # special handling of command line option flags
    # NOTE: as always, --version was already handled by launcher.pl: setPipelineSuiteVersion()
    my %options;
    my $help    = "help";
    my $version = "version";
    my $gcc     = "gcc";
    my $noConda = "no-conda";
    my $create  = "create";
    my $exec    = "exec";
    my $compile = "compile";
    my $vscode  = "vscode";
    my $rustVersion;
    my $gccLoadCommand;
    while (@args > 0) {
        my $arg = shift @args;
        if($arg eq '-h' or $arg eq "--$help"){
            $options{$help} = 1;    
            last;
        }
        if($arg eq '-g' or $arg eq "--$gcc"){
            while (@args > 0 and $args[0] !~ m/^-/) {
                my $bit = shift @args;
                $gccLoadCommand .= $bit . " ";
            }
        }
        if($arg eq '-n' or $arg eq "--$noConda"){
            $options{$noConda} = 1;
        }
        if($arg eq '-c' or $arg eq "--$create"){
            $options{$create} = 1;
            $rustVersion = shift @args;
        }
        if($arg eq '-e' or $arg eq "--$exec"){
            $options{$exec} = 1;
            $rustVersion = shift @args;
        }
        if($arg eq '-p' or $arg eq "--$compile"){
            $options{$compile} = 1;
            $rustVersion = shift @args;
        }
        if($arg eq '-d' or $arg eq "--$vscode"){
            $options{$vscode} = 1;
            $rustVersion = shift @args;
        }
        $rustVersion and last;
    }
    $rustVersion or $rustVersion= "XXXXX";
    my $isError = !($options{$help} or $rustVersion =~ m/\d+\.\d+/);

    # if requested, show custom action help
    my $pname = $$config{pipeline}{name}[0];
    my $suiteName = basename($pipelineSuiteDir);
    if($options{$help} or $isError){
        my $error = $isError ? "\ninvalid or missing Rust version, expected \\d+\.\\d+, e.g., 19.2\n" : "";
        my $usage;
        my $desc = getTemplateValue($$config{actions}{rust}{description});
        $usage .= "\n$pname rust: $desc\n";
        $usage .=  "\nusage: rudi $pname rust [options] <rust_version>\n";
        $usage .=  "\n    -v/--$version   the suite version to query, as a git release tag or branch [latest]";
        $usage .=  "\n    -g/--$gcc       load a GCC environment for Rust C compilation; must come before --compile or --vscode";
        $usage .=  "\n    -n/--$noConda   do not use a conda environment to compile Rust code; must come before --compile";
        $usage .=  "\n    -c/--$create    create a versioned Rust development environment";
        $usage .=  "\n    -e/--$exec      execute a command in a Rust development environment";
        $usage .=  "\n    -p/--$compile   compile Rust crates listed in $suiteName/rust.txt";
        $usage  .= "\n    -d/--$vscode    generate rust-analyzer startup script for VSCode integration";
        $isError and throwError("$error$usage");
        print "$usage\n\n";
        releaseRudiGitLock(0);
    }
    
    # # compile any executable programs
    if ($options{$create}){
        createRustEnvironment($rustVersion);
    } elsif ($options{$exec}){
        execRustEnvironment($rustVersion, @args);
    } elsif ($options{$compile}){
        compileRustExecutables($rustVersion, $gccLoadCommand, $options{$noConda});
    } else {
        generateRustAnalyzerScript($rustVersion, $gccLoadCommand);
    }
    releaseRudiGitLock(0);
}

#------------------------------------------------------------------------------
# print a more concise list of an action's options (mostly for developers)
#------------------------------------------------------------------------------
sub runOptions {
    
    # check for a proper request
    my ($targetAction, $required, $error) = @args;
    $targetAction or $error .= "missing action\n";
    my $cmd = getCmdHash($targetAction); 
    if(!$cmd){
        $targetAction and $error .= "unkown action: $targetAction\n";
        throwError(
            $error.
            "usage: rudi $$config{pipeline}{name}[0] options <action> [required]"
        );
    }
    
    # report a terse format of all options (or just required options)
    loadActionOptions($cmd); # need options but no values    
    my @optionsOut = sort { lc($$a{short}[0]) cmp lc($$b{short}[0]) or
                               $$b{short}[0]  cmp    $$a{short}[0] or
                               $$a{long}[0]   cmp    $$b{long}[0] } values %longOptions;
    my (%shortOptions, %longOptions);
    foreach my $option(@optionsOut){
        if(!$required or $$option{required}[0]){
            my $required = $$option{required}[0] ? "*REQUIRED*" : "";
            my $shortOut = $$option{short}[0];
            $shortOut = (!$shortOut or $shortOut eq 'null') ? "" : "-$$option{short}[0]";
            my $line = join("\t", $shortOut, "--$$option{long}[0]", $required)."\n";
            print $line;
            $shortOut and push @{$shortOptions{$shortOut}}, $line;
            push @{$longOptions{$$option{long}[0]}}, $line;
        }   
    }

    # report any conflicts in short options flag usage
    my ($isConflicts, @conflictedOptions);
    foreach my $shortOption(sort { $a cmp $b } keys %shortOptions){
        @{$shortOptions{$shortOption}} > 1 and push @conflictedOptions, @{$shortOptions{$shortOption}};
    }
    if(@conflictedOptions){
        print "\n!!!!!!!! The following options have conflicting single-letter codes !!!!!!!!\n";
        print join("", @conflictedOptions), "\n";
        $isConflicts++;
    } 
    @conflictedOptions = ();
    foreach my $longOption(sort { $a cmp $b } keys %longOptions){
        @{$longOptions{$longOption}} > 1 and push @conflictedOptions, @{$longOptions{$longOption}};
    }
    if(@conflictedOptions){
        print "\n!!!!!!!! The following options have conflicting names !!!!!!!!\n";
        print join("", @conflictedOptions), "\n";
        $isConflicts++;
    }   
    !$isConflicts and print "\nNo option name conflicts were found.\n\n"; 
    releaseRudiGitLock(0);
}

#------------------------------------------------------------------------------
# print a tab-delimited table of all pipeline actions and options (mostly for Pipeline Runner)
#------------------------------------------------------------------------------
sub runOptionsTable { # takes no arguments
    my $launcher = loadYamlFile("$launcherDir/commands.yml", 0, 1, undef, 1);
    my %suppressedFamilies = map { $_ => 1 } ("workflow", "help"); # "job-manager", 
    print join("\t", qw(pipelineName action optionFamily optionName 
                        type required universal familyOrder order 
                        default description)), "\n";  
    foreach my $action(keys %{$$config{actions}}){
        $$launcher{actions}{$action} and next;
        my $cmd = getCmdHash($action); 
        loadActionOptions($cmd); # need options but no values, resets on each call
        my @optionsOut = sort { $$a{family}   cmp    $$b{family} } values %longOptions;
        foreach my $option(@optionsOut){
            my $family = $$option{family};
            $suppressedFamilies{$family} and next;
            my $universal = $$config{optionFamilies}{$family}{universal}[0] ? "UNIVERSAL" : "";            
            my $familyOrder = $$config{optionFamilies}{$family}{order} ? $$config{optionFamilies}{$family}{order}[0] : 9999;
            my $order = ($$option{order} and defined $$option{order}[0]) ? $$option{order}[0] : 9999;
            my $default = (!$$option{default} or $$option{default}[0] eq 'null') ? "" : $$option{default}[0];
            $default eq "NA" and $default = "_NA_";
            my $required = ($$option{required} and $$option{required}[0]) ? "TRUE" : "FALSE";
            print join("\t", $pipelineName, $action, $$option{family}, $$option{long}[0], 
                             $$option{type}[0], $required, $universal, $familyOrder, $order,
                             $default, $$option{description}[0]), "\n";
        }    
    }
    releaseRudiGitLock(0);
}

#------------------------------------------------------------------------------
# print a yaml-formatted string of parsed option values for <data>.yml (mostly for Pipeline Runner)
#------------------------------------------------------------------------------
sub runValuesYaml { # takes no arguments
    my $yaml = loadYamlFile($args[0], undef, undef, undef, 1); # suppress null entries

    # parse actions lists
    my %requestedActions = map { $_ => 1} ($$yaml{execute} ? @{$$yaml{execute}} : ());
    my $allActions = $$config{actions};
    foreach my $action (keys %$allActions){
        defined $$allActions{$action}{order} or $$allActions{$action}{order} = [999];
    }
    my @allActions = sort { 
        $$allActions{$a}{order}[0] <=> $$allActions{$b}{order}[0]
    } keys %$allActions;

    # initiate yaml
    my $yml = "---\n"; # will include values for _all_ actions
    $yml .= "pipeline: $pipelineName\n";
    my $actionsYml = "execute:\n"; # will include only the requested actions in <data>.yml
    my $indent = "    ";

    # parse options for all pipeline-specific actions
    foreach my $action(@allActions){
        $$allActions{$action}{universal}[0] and next;
        $requestedActions{$action} and $actionsYml .= "$indent- $action\n";        
        $yml .= "$action".":\n";
        my $cmd = getCmdHash($action);         
        parseAllOptions($action, undef, 1);
        parseAllDependencies($action);
        assembleActionYaml($action, $cmd, $indent, \my @taskOptions, \$yml, 1); # retains suite//option name format
    }

    # print the final yaml results
    print $yml.$actionsYml;
    releaseRudiGitLock(0);
}

#------------------------------------------------------------------------------
# pre-pull a pipeline container for asynchronous, queued jobs to use (used by jobManager and Pipeline Runner)
#------------------------------------------------------------------------------
sub checkContainer {
    # command has no options: rudi pipeline checkContainer <data.yml>
    # is silent unless needs to prompt for download
    pullPipelineContainer(undef, undef, $args[1] eq "suite", "pipelines", $args[2]);
    releaseRudiGitLock(0);
}

#------------------------------------------------------------------------------
# build one container with all of a tool suite's pipelines and apps (cascades from jobManager)
#------------------------------------------------------------------------------
sub buildSuite {  
    my ($suite) = @_;
    my $usage = "usage: rudi buildSuite <GIT_OWNER/SUITE_NAME> <CONTAINER_TYPE> [--version v0.0.0] [--sandbox]";
    my %options;
    my $sandbox = "sandbox"; # @args from jobManager is always (pipelines|apps --version xxxx [--sandbox])
    $args[3] and ($args[3] eq '-s' or $args[3] eq "--$sandbox") and $options{$sandbox} = 1;
    my $containerType = $args[0] or die "\nmissing container type\n$usage\n\n";
    $suite or die "\nmissing suite\n$usage\n\n";
    buildSuiteContainer($suite, $containerType, $options{$sandbox} ? "--sandbox" : "");
    exit;
}

1;
