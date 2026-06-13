use strict;
use warnings;
use File::Basename;
use File::Spec;

# subs for loading available options and their requested values

# working variables
use vars qw($rudiDir $pipeline $jobConfigYml
            $config $isSingleAction $target @args
            @universalOptionFamilies %allOptionFamilies
            %longOptions %shortOptions %optionArrays
            $helpAction $helpCmd
            %nTasks $errorSeparator);
our (%nTasks);

#------------------------------------------------------------------------------
# preliminary read of command line arguments to pull any pipeline-level version request
#------------------------------------------------------------------------------
sub getCommandLineVersionRequest {
    $target or return; # ensure that we also handle blind calls to a pipeline, i.e., rudi <pipeline> --version xxx
    my @ARGS = ($target, @args);
    foreach my $i(0..$#ARGS){
        $ARGS[$i] eq '-v' or $ARGS[$i] eq '--version' or next;
        my $version = $ARGS[$i + 1];
        $version or throwError("command line error: missing value for option --version");
        splice(@ARGS, $i, 2); # prevent --version from being read as an action option later on
        ($target, @args) = @ARGS;
        return $version;
    }
    undef;
}

#------------------------------------------------------------------------------
# top-level function that discovers and checks all expected and requested option values
#------------------------------------------------------------------------------
sub parseAllOptions {
    my ($actionCommand, $subjectAction, $skipValidation) = @_;
    $subjectAction or $subjectAction = $actionCommand;
    $ENV{PIPELINE_ACTION} = $subjectAction;    
    
    # set the known options list for a pipeline action
    my $cmd = getCmdHash($subjectAction);
    ($helpAction, $helpCmd) = ($subjectAction, $cmd);
    loadActionOptions($cmd);
    $isSingleAction and (!$args[0] or $args[0] eq '-h' or $args[0] eq '--help') and showOptionsHelp();

    # define and load a series of config scripts in increasing order of precedence
    my $configYml = assembleCompositeConfig($cmd, $subjectAction);
    setOptionsFromConfigComposite($configYml, $subjectAction);
    
    # add options values from the command line; takes precedence over any config file
    setOptionsFromCommandLine($subjectAction);
    
    # ensure that we have a complete and valid set of options
    validateOptionArrays($subjectAction);
    $cmd = getCmdHash($actionCommand);
    ($helpAction, $helpCmd) = ($actionCommand, $cmd);
    $skipValidation or validateOptionValues($cmd, $actionCommand);
    $configYml;
}
# extend parseAllOptions with a check that options specify a specific task
sub checkRestrictedTask {
    my ($subjectAction) = @_;
    my $taskId;
    if ($nTasks{$subjectAction} > 1) {
        $taskId = $optionArrays{'task-id'}[0];
        defined $taskId and $taskId ne 'null' and $taskId >= 1 or throwError(
            "option '--task-id' must be specified for arrayed option values"
        );
    } else {
        $taskId = 1;
    }
    my $i = @{$optionArrays{'output-dir'}} > 1 ? $taskId - 1 : 0;
    $ENV{OUTPUT_DIR} = $optionArrays{'output-dir'}[$i];
       $i = @{$optionArrays{'data-name'}}  > 1 ? $taskId - 1 : 0;
    $ENV{DATA_NAME}  = $optionArrays{'data-name'}[$i];
}

#------------------------------------------------------------------------------
# create option lookups for the active action based on the pipeline's defition
#------------------------------------------------------------------------------
sub loadActionOptions {
    my ($cmd) = @_;
    %longOptions = %shortOptions = %optionArrays = %nTasks = (); # reset is for multi-action mode
    my %familySeen;
    foreach my $family(getAllOptionFamilies($cmd)){
        $allOptionFamilies{$family}++;
        $familySeen{$family} and next;
        $familySeen{$family}++;
        my $options = getFamilyOptions($family);
        foreach my $optionName(keys %$options){
            my $option = $$options{$optionName};
            $$cmd{override} and defined $$cmd{override}{$optionName} and $$option{default} = $$cmd{override}{$optionName};
            #$$option{required}[0] or defined $$option{default}[0] or $$option{type}[0] eq 'boolean' or 
            #     throwError("pipeline configuration error\n".
            #                "option '$optionName' must be required or have a default value");
            $$option{long} = [$optionName];
            $$option{family} = $family;
            $longOptions{$optionName} = $option;
            $shortOptions{$$option{short}[0] || "null"} = $option; # variables can have long-names only
        }
    }    
}
sub getAllOptionFamilies {
    my ($cmd) = @_;
    my @actionOptionFamilies = ($cmd and $$cmd{optionFamilies}) ? @{$$cmd{optionFamilies}} : ();
    my $order = 1; # order the family presentation the same way as the calling config file
    foreach my $family(@actionOptionFamilies){
        my $x = $$config{optionFamilies}{$family};
        if(!$x){
            $family =~ m|//(.+)| and $family = $1;
            $x = $$config{optionFamilies}{$family};
        }
        $x or next;
        $$x{order} = [$order];
        $order++;
    }
    (@actionOptionFamilies, @universalOptionFamilies); # universal option ordering is preset
}
sub getFamilyOptions { # pipeline takes precedence over universal options, i.e can override if needed
    my ($family) = @_;
    my $options = $$config{optionFamilies}{$family};
    if(!$options){
        $family =~ m|//(.+)| and $family = $1;
        $options = $$config{optionFamilies}{$family};
    }
    $options or return {};     
    $$options{options} || {};
}

#------------------------------------------------------------------------------
# get option specifications from .yml config file(s)
#------------------------------------------------------------------------------
# define and load a series of option config file in increasing order of precedence
sub assembleCompositeConfig {
    my ($cmd, $subjectAction) = @_;
    
    # collect the user's provided config file, if any
    my ($dataYmlFile, $dataYmlDir);
    if ($args[0] and $args[0] =~ m/\.yml$/) {
        $dataYmlFile = $args[0];
        -e $dataYmlFile or throwError("file not found:\n    $dataYmlFile");
        $dataYmlDir = File::Spec->rel2abs( dirname($dataYmlFile) );
        shift @args;
    }
    extractPipelineJobConfigYml($dataYmlFile); # sets $jobConfigYml

    # initialize the composite config with developer-level recommended resources for the action
    my %resourcesYml;
    fillResourceRecommendations($subjectAction, $cmd, 'resources',   \%resourcesYml);
    fillResourceRecommendations($subjectAction, $cmd, 'job-manager', \%resourcesYml);

    # add further configs at increasing precedence
    my @configYmlFiles = (
        # installation/host level
        "$rudiDir/config/pipelines.yml", 
        
        # user level
        $dataYmlDir ? "$dataYmlDir/../../server.yml" : undef, # user's server environment around multiple pipelines
        $dataYmlDir ? "$dataYmlDir/../server.yml" : undef, 
        $dataYmlDir ? "$dataYmlDir/server.yml" : undef,
        $dataYmlDir ? "$dataYmlDir/../pipeline.yml"  : undef, # user's environment for multiple data sets for a pipeline
        $dataYmlDir ? "$dataYmlDir/../$$config{pipeline}{name}[0].yml"  : undef,
        $dataYmlDir ? "$dataYmlDir/pipeline.yml"  : undef, 
        $dataYmlDir ? "$dataYmlDir/$$config{pipeline}{name}[0].yml"  : undef,
        
        # data config level
        \$jobConfigYml
        
        # call level, from command line added last, later
    );
    my @configYmls = (\%resourcesYml);
    foreach my $i(0..$#configYmlFiles){
        $configYmls[$i + 1] = loadOptionsConfigFile($configYmlFiles[$i], $i + 1);   
    }

    # merge and override variables with special handling to ensure sequential behavior
    my $yml = mergeYAML(@configYmls);
    $$yml{variables} = mergeYamlVariables(@configYmlFiles);
    $yml;
}
sub fillResourceRecommendations {
    my ($subjectAction, $cmd, $family, $resourcesYml) = @_;
    if ($cmd and $$cmd{$family} and $$cmd{$family}{recommended}) {
        my $recs = $$cmd{$family}{recommended};
        my $i = 1;
        foreach my $option(keys %$recs){
            my $rec = [$$recs{$option}[0]];
            $$resourcesYml{$subjectAction}{$family}{$option} = $rec;
            push @{$$resourcesYml{parsed_}}, [
                'KEYED',
                join(":", $subjectAction, $family, $option),
                $rec,
                0,
                $i
            ];
            $i++;
        }
    }  
}

# read a job config from disk; could be from one of multiple levels (server, pipeline, data)
sub loadOptionsConfigFile { 
    my ($configFile, $priority) = @_;
    
    # load the config
    my $nullConfig = {parsed_ => []};
    $configFile or return $nullConfig; 
    if(ref($configFile)){
        $$configFile or return $nullConfig;
    } else {
        -e $configFile or return $nullConfig;
    }
    my $yaml = loadYamlFile($configFile, $priority, 1, undef, 1);

    # check that we are reading a file intended for us
    if (defined $$yaml{pipeline}) { # server level config files do not declare a single pipeline; others should
        my $yamlPipeline = ref($$yaml{pipeline}) eq 'HASH' ? $$yaml{pipeline}{name}[0] : $$yaml{pipeline}[0];
        $yamlPipeline or $yamlPipeline = '';
        if($yamlPipeline =~ m|/|){ # strip suite name prefix
            my @x = split('/', $yamlPipeline);
            $yamlPipeline = $x[$#x];
        }
        $yamlPipeline =~ m/(.+):/ and $yamlPipeline = $1; # strip :version suffix
        $yamlPipeline eq $$config{pipeline}{name}[0] or
            throwError("$configFile is not a configuration file for pipeline '$$config{pipeline}{name}[0]'");
    }
    
    # return the hash, still with variable names, not their values
    $yaml;
}
# execute an ordered filling of option values from assembled composite config for a single action
sub setOptionsFromConfigComposite {
    my ($yaml, $subjectAction) = @_;
    setConfigFileOptions($yaml, 'shared');
    setConfigFileOptions($yaml, $subjectAction);
}
sub setConfigFileOptions {
    my ($yaml, $yamlKey) = @_; # yamlKey is either 'shared' or a pipeline action
    my $cmd  = $$yaml{$yamlKey};
    my $vars = $$yaml{variables};
    ref($cmd) eq 'HASH' or return;
    ref($vars) eq 'HASH' or $vars = {};
 
    # process each option found in the config
    foreach my $family($cmd ? keys %$cmd : ()){
        ref($$cmd{$family}) eq 'HASH' or throwConfigError(undef, $yamlKey, $family);
        $allOptionFamilies{$family} or $yamlKey eq 'shared' or
            throwConfigError("'$family' is not a recognized optionFamily\n", $yamlKey, $family); 
        foreach my $longOption(keys %{$$cmd{$family}}){
            
            # validate the option and data type
            my $optionConfig = $longOptions{$longOption};    
            if (!defined $optionConfig) {
                $yamlKey eq 'shared' and next; # no error, shared option might not apply to this action
                throwConfigError("'$longOption' is not a valid option for action '$yamlKey'\n",
                                 $yamlKey, $family);
            }
            if ($$optionConfig{family} ne $family) {
                $yamlKey ne 'shared' and
                    throwConfigError("'$longOption' is not a member of family '$family' for action '$yamlKey'\n",
                                     $yamlKey, $family);
            }
            my $type = $$optionConfig{type} ? $$optionConfig{type}[0] : undef;
            $type or throwError("configuration error:\n    missing data type for option:\n        $family : $longOption");
            $type = substr($type, 0, 3);

            # collect one or more values per option (i.e. a scalar value or a list)
            my $values = $$cmd{$family}{$longOption};
            my @parsedValues;
            foreach my $value(@$values){
                $value = applyVariablesToYamlValue($value, $vars); 
                $type eq 'boo' or defined $value or showOptionsHelp("missing value for option '$longOption'");
                defined $value or $value = 0;
                push @parsedValues, $value;              
            }            

            # parse option values to arrays as needed
            # NB: do NOT support nested arrays
            if (@$values > 1) { # already an array, wrap space-containing strings in double quotes
                @parsedValues = map { $_ =~ m/ / ? '"'.$_.'"' : $_ } @parsedValues;
            } elsif(!$$optionConfig{literal}[0]) { # interpret space-delimited lists as option arrays, unless pipeline says not to via "literal" flag
                @parsedValues = split(" ", $parsedValues[0]);
            }
            $optionArrays{$longOption} = \@parsedValues;     
        }
    }    
}

# apply a special, non-canonical substitution of variable values into yaml values
# uses variables first, if not found then tries %ENV
sub mergeYamlVariables { # first, collect the values of variables, obeying config precedence order
    my %vars;
    foreach my $configFile(@_){
        $configFile or next;
        if(ref($configFile)){
            $$configFile or next;
        } else {
            -e $configFile or next;
        }
        open my $inH, "<", $configFile or throwError("could not open:\n    $configFile\n$!");
        my $inVariablesSection;
        while (my $line = <$inH>) {
            $line = trimYamlLine($line) or next; # ignore blank lines
            $line =~ s/^(\s*)//;
            my $indent = length $1;            
            if (!$indent) {
                $inVariablesSection = ($line =~ m/^variables\s*:/);
                next;
            }
            $inVariablesSection or next;            
            $line =~ s/\s+/ /g;
            my ($key, $value) = split(': ', $line, 2);
            (!defined $value or $value eq '') and throwConfigError("malformed variables section\n", $key);
            $vars{$key} = applyVariablesToYamlValue($value, \%vars); # thus, overwrite any prior declaration of VAR_NAME
            $ENV{$key} = $vars{$key};
        }
        close $inH;
    }
    \%vars;
}
sub applyVariablesToYamlValue {
    my ($value, $vars) = @_;
    defined $value or return $value;

    # discover any environment variables needing substitution
    my ($varName, $useType);
    if($value =~ m/\$(\w+)/){
        ($varName, $useType) = ($1, 'plain');
    } elsif($value =~ m/\$\{(\w+)\}/){
        ($varName, $useType) = ($1, 'braces');
    }
    #$varName or return applyBackticks($value); # TODO: allow use of commands in config file? (security risk)
    $varName or return unmaskInterploatedSymbols(removeInternalDoubleQuotes($value)); # nothing more to do; these are final values
    
    # discover the values to subsitute
    my $sub;
    if($vars and defined $$vars{$varName}){
        $sub = $$vars{$varName};
    } elsif(defined $ENV{$varName}){
        $sub = $ENV{$varName};
    }
    defined $sub or throwError("no value found for environment variable '$varName'");        

    # do the substitution as many times as needed
    my $target;
    if ($useType eq 'braces') {
        $value =~ s/\{/__OPEN_BRACE__/g; # avoids regex confusion
        $value =~ s/\}/__CLOSED_BRACE__/g;
        $target = "\\\$__OPEN_BRACE__$varName\__CLOSED_BRACE__";  
    } else {
        $target = "\\\$$varName";  
    }
    $value =~ s/$target/$sub/g;    
    $value =~ s/__OPEN_BRACE__/\{/g; # enable multiple different variables per line
    $value =~ s/__CLOSED_BRACE__/\}/g;

    # repeat until no more variables are found in the string
    return applyVariablesToYamlValue($value, $vars);
}
sub removeInternalDoubleQuotes { # in case pattern "$ABC""_123" was used to ensure proper variable parsing
    my ($value) = @_;
    $value or return $value;
    $value =~ s/\"\"//g;
    $value =~ s/^\"//g;
    $value =~ s/\"$//g;
    $value;
}
#sub applyBackticks { # convert system commands into option/variable values
#    my ($value) = @_;
#    $value =~ m/^\s*`(.+)`\s*$/ or return $value;
#    my $values = qx($1);
#    chomp $values;
#    $values =~ s/\n/ /g;
#    $values =~ s/\s+/ /g; # ensure that all system calls return single-space-delimited lists
#    $values;
#}

#------------------------------------------------------------------------------
# get command line option specifications; takes precedence over .yml values
#------------------------------------------------------------------------------
sub setOptionsFromCommandLine {
    my ($subjectAction) = @_;
    while (defined (my $optionList = shift @args)){
        defined $optionList or last; # no more options to process
        unless($optionList =~ m/^\-./){ # next item is a value, not an option
            unshift @args, $optionList;
            last;
        }
        if($optionList =~ m/^\-\-(.+)/){ # long option formatted request
            my $longOption = $1;
            checkAndSetOption(\%longOptions, $longOption, $subjectAction);
        } elsif ($optionList =~ m/^\-(.+)/){ # short option formatted request
            foreach my $shortOption(split('', $1)){
                checkAndSetOption(\%shortOptions, $shortOption, $subjectAction);
            }   
        } else {
            showOptionsHelp("malformed option list");
        }
    }     
}
sub checkAndSetOption {
    my ($options, $optionName, $subjectAction) = @_;
    if (defined $$options{$optionName}) { # set known options
        setOption($$options{$optionName});
    } elsif($isSingleAction){ # no option errors in multi-action mode, it may apply to another action
        showOptionsHelp("'--$optionName' is not a recognized option for action '$subjectAction'");
    }   
}
sub setOption { 
    my ($option) = @_;
    my $longOption = $$option{long}[0];
    my $type = substr($$option{type}[0], 0, 3);
    my $value = $type eq 'boo' ? 1 : shift @args;    
    (!defined $value or $value =~ m/^\-/) and showOptionsHelp("missing value for command line option '$longOption'");
    $optionArrays{$longOption} = [$value]; # command line options are always single, simple values    
}

#------------------------------------------------------------------------------
# add option value to environment
#------------------------------------------------------------------------------
sub setEnvVariable {
    my ($optionLong, $value) = @_;
    my $VAR_NAME = uc($optionLong); # reformat option names (xxx-yyy) to variable names (XXX_YYY)
    $VAR_NAME =~ s/-/_/g;
    $ENV{$VAR_NAME} = $value;
}

#------------------------------------------------------------------------------
# validate all requested option values for a given action
#------------------------------------------------------------------------------
# makes sure option lists are all of length 1 or a constant N
sub validateOptionArrays {
    my ($action) = @_;
    
    # get the lengths of all option lists
    my @nListValues = sort { $b <=> $a } map {
        my $nValues = scalar( @{$optionArrays{$_}} );
        $nValues > 1 ? $nValues : ();
    } keys %optionArrays;
    my %nListValues = map { $_ => 1 } @nListValues;
    
    # abort if list of different lengths (other than 1, which repeats over all tasks)
    if (scalar(keys %nListValues) > 1) {
        my @offendingOptions = map {
            my $nValues = scalar( @{$optionArrays{$_}} );
            $nValues > 1 ? "    $_: $nValues" : ();
        } keys %optionArrays; 
        throwError(
            "too many different lengths of option value lists for action '$action'\n".
            "all option lists must be of length 1 or a single constant value N\n".
            "got lengths: \n".join("\n", @offendingOptions)
        );
    }
    
    # if multiple tasks, either OUTPUT_DIR or DATA_NAME must be arrayed to yield unique output paths
    $nTasks{$action} = $nListValues[0] || 1; # largest length of options lists, i.e N
    if ($nTasks{$action} > 1) {
        my $nDir  = $optionArrays{'output-dir'} ? @{$optionArrays{'output-dir'}} : 0;
        my $nName = $optionArrays{'data-name'}  ? @{$optionArrays{'data-name'}}  : 0;
        $nDir > 1 or $nName > 1 or throwError(
            "task arrays must have multiple values for either '--output-dir' or '--data-name'"
        )
    }
    # OUTPUT_DIR cannot have spaces
    foreach my $value(@{$optionArrays{'output-dir'}}){
        $value =~ m/\s/ and throwError("--output-dir cannot have spaces:\n    $value");
    }
    
    # DATA_NAME cannot have spaces
    foreach my $value(@{$optionArrays{'data-name'}}){
        $value =~ m/\s/ and throwError("--data-name cannot have spaces:\n    $value");
        # $value =~ m/\./ and throwError("--data-name cannot have periods:\n    $value");
    }
}
# check for the existence and proper data types for all expected options
sub validateOptionValues {
    my ($cmd, $action) = @_;
    foreach my $family(getAllOptionFamilies($cmd)){
        my $options = getFamilyOptions($family);
        foreach my $longOption(keys %$options){
            my $option = $$options{$longOption};
            
            # check for required values or fill defaults if not required or present
            my $valueExists = defined ${$optionArrays{$longOption}}[0];       
            if($$option{required}[0]){
                $valueExists or showOptionsHelp("option '--$longOption' is required for action '$action'");
            } elsif(!$valueExists and defined $$option{default}[0]){ # options can carry 0 or zero-length strings
                $optionArrays{$longOption} = [ applyVariablesToYamlValue($$option{default}[0]) ];
            }
            
            # check data types of provided values
            my $type = substr($$option{type}[0], 0, 3);
            if ($type eq 'int') {
                foreach my $value(@{$optionArrays{$longOption}}){
                    $value ne 'null' and $value =~ m|\D| and showOptionsHelp("'--$longOption' must be an integer");
                }
            }

            # check for valid directories and existence of input files  
            if ($$option{directory} and $$option{directory}{'must-exist'}[0]) {
                unless($ENV{SUPPRESS_OUTPUT_DIR_CHECK} and $longOption eq 'output-dir'){ # allow mkdir to query output directories without failing
                    foreach my $glob(@{$optionArrays{$longOption}}){
                        foreach my $dir(glob($glob)){
                            -d $dir or showOptionsHelp("'--$longOption' does not exist or is not a directory\n    $dir");
                        }   
                    }
                }
            }
            if ($$option{file} and $$option{file}{'must-exist'}[0]) {
                foreach my $glob(@{$optionArrays{$longOption}}){
                    foreach my $file(glob($glob)){
                        -e $file or $file eq 'null' or showOptionsHelp("'--$longOption' file does not exist\n    $file");
                    }   
                }
            }  
        }
    } 
}

1;
