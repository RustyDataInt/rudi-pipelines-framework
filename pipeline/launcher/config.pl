use strict;
use warnings;

# subs for handle configuration .yml files

# working variables
our $jobConfigYml;
use vars qw($launcherDir $pipelineDir $optionsDir
            $configFile $config
            %optionArrays %nTasks %conda
            $pipelineSuite $pipelineSuiteDir $pipelineName 
            $pipelineSuiteVersions %workingSuiteVersions);

#------------------------------------------------------------------------------
# load a composite, i.e., assembled version of a pipeline's configuration
#------------------------------------------------------------------------------
sub loadPipelineConfig {
    
    # load the pipeline-specific and universal configs
    my $launcher = loadYamlFile("$launcherDir/commands.yml", 0, 1);
    my $pipeline = loadYamlFile("$pipelineDir/pipeline.yml"); # quick read to obtain suite version declarations and merge _global
    $pipelineSuiteVersions = $$pipeline{suiteVersions};  
    mergeGlobalFamilies($$pipeline{actions}); # control order of re-assembled yaml to ensure that suiteVersion precedes actions on full load
    printYAML($pipeline, \my $pipelineYml, undef, undef, qw(
        pipeline
        suiteVersions
        actions
        optionFamilies
        condaFamilies
        compilationTargets
        package
        container
    ));
    $pipeline = loadYamlFile(\$pipelineYml, 2, 1, 1); # full read to support modules, etc.
    my @optionFamilies = (loadYamlFile("$launcherDir/options.yml", 1, 1)); # an expanded, multi-family, shared options file
    my %loaded = (universal => 1);

    # cascade to add shared option families invoked by a pipeline action
    foreach my $action(keys %{$$pipeline{actions}}){ 
        my $optionFamilies = $$pipeline{actions}{$action}{optionFamilies} or next;
        ref($optionFamilies) eq 'ARRAY' or next;
        foreach my $optionFamily(@$optionFamilies){
            $loaded{$optionFamily} and next;
            $loaded{$optionFamily} = 1;
            my $ymlFile = getSharedFile($optionsDir, "$optionFamily.yml", 'option'); # not required since private options added later
            $ymlFile or next;
            my $yml = loadYamlFile("$ymlFile", 1, 1); # support both simple (single-family) and expanded (multi-family) shared option files
            # !$$yml{optionFamilies} and 
            prependYamlKeys($yml, "optionFamilies", $optionFamily);
            push @optionFamilies, $yml;
        }
    }
    
    # merge information into a single, final config file hash
    my $config = mergeYAML($launcher, $pipeline, @optionFamilies); # only uses parsed_ values

    # override simple keys, like "description" and option defaults, in action modules to support pipeline customization
    overrideActionModuleKeys($$config{actions});
    $config
}
sub mergeGlobalFamilies { # support option and conda family sharing between actions
    my ($actions) = @_;
    my $global = "_global";
    $$actions{$global} or return; # no global families, nothing to do
    if(ref($$actions{$global}) eq "HASH"){ # check for something to do
        foreach my $key(qw(environment condaFamilies optionFamilies compilationTargets)){ # control what is supported in _global, ignore all other keys
            my $globalRef = $$actions{$global}{$key};
            (ref($globalRef) eq "ARRAY" and @$globalRef and $$globalRef[0] ne 'null') or next; # make sure key is defined
            foreach my $action(keys %$actions){ # append _global to every action ...
                $action eq $global and next; # ... except _global itself ...
                $$actions{$action}{module} and next; # ... and never append _global to actions defined by action modules
                my $actionRef = $$actions{$action}{$key};
                if(!$actionRef or ref($actionRef) ne "ARRAY" or $$actionRef[0] eq 'null'){ # initialize key for each action if not present in pipeline.yml
                    $actionRef = [];
                    $$actions{$action}{$key} = $actionRef;
                }
                unshift @$actionRef, @$globalRef; # prepend _global to action
                @$actionRef = uniqueElements(@$actionRef); # remove duplicate elements while preserving order
                @$actionRef or delete $$actions{$action}{$key};
            }
        }
    }
    delete $$actions{$global}; # all paths delete the non-existent _global action
}
sub overrideActionModuleKeys {
    my ($actions) = @_; 
    my %overrideKeys = map { $_ => 1 } qw(description); # explicitly declare the config keys that can be overridden
    foreach my $actionName(keys %$actions){             # options defaults to override that match this list may not be handled as expected
        my $action = $$actions{$actionName};
        $$action{module} or next;
        $$action{override} or next;
        foreach my $key(keys %{$$action{override}}){
            if($overrideKeys{$key}){
               $$action{$key} = $$action{override}{$key};
               $$action{override}{$key} = undef; # remaining keys are potentially used to override _default_ values defined by the module
            }
        }
    }
}

#------------------------------------------------------------------------------
# parse data.yml to compile the YAML block for one requested pipeline (with potentially multiple actions)
# this simply assembles a set of YAML lines, variable substitution is not handled yet
#------------------------------------------------------------------------------
sub extractPipelineJobConfigYml {
    my ($ymlFile, $force) = @_;
    !$force and $jobConfigYml and return;
    ($ymlFile and $ymlFile =~ m/\.yml$/) or return;
    $jobConfigYml = "\n".slurpFile($ymlFile);
    $jobConfigYml =~ s/\n\.\.\.\s+/\n/g; # for convenience, remove all unrequired YAML end lines
    $jobConfigYml =~ s/\n---\s+/\n__BEGIN_YML_CHUNK__\n/g; # and replace all YAML begin lines
    my ($prefixYml, $yaml) = ("");
    foreach my $ymlChunk(split("__BEGIN_YML_CHUNK__", $jobConfigYml)){
        if($ymlChunk =~ m/\npipeline:\s*(\S+)/){
            my $chunkPipelineName = $1;
            $chunkPipelineName =~ m/(\S+):/  and $chunkPipelineName = $1; # strip ':suiteVersion', only [suiteName/]pipelineName persists
            $chunkPipelineName =~ m/\/(\S+)/ and $chunkPipelineName = $1; # strip 'suiteName/', only pipelineName persists
            if($pipelineName eq $chunkPipelineName){ # execute only the first YAML chunk for the requested pipeline
                $jobConfigYml = "---\n$prefixYml\n$ymlChunk\n";
                last;
            }
        } else { # a YAML chunk without a root 'pipeline' key is prefixed to all subsequent pipeline YAML chunks
            $prefixYml = "$prefixYml\n$ymlChunk\n";
        }
    }
    $jobConfigYml or throwError("job configuration file has no definitions for pipeline '$pipelineName':\n    $ymlFile\n");
}

#------------------------------------------------------------------------------
# print configuration to log stream, i.e., all option values/dependencies for all tasks
#     this output is read by job manager to make scheduler queuing decisions
# expand options get the set of option values for each required task
#------------------------------------------------------------------------------
sub reportAssembledConfig {
    my ($action, $cnd, $showMissingConda) = @_;
    my $cmd = getCmdHash($action);
    my $indent = "    ";
    
    # print the config header, top-level metadata
    my $desc = getTemplateValue($$config{pipeline}{description});
    my @externalSuiteDirs = map { $_ eq $pipelineSuiteDir ? () : $_ } keys %workingSuiteVersions;
    my $thread = $$cmd{thread}[0] || "default";
    my $version = $ENV{RUDI_IS_CONTAINER} ? $ENV{SUITE_VERSION} : $workingSuiteVersions{$pipelineSuiteDir};
    my $report = "";
    $report .= "---\n";
    $report .= "pipeline: $pipelineSuite/$pipelineName:$version\n";
    $report .= "description: \"$desc\"\n";
    if(@externalSuiteDirs){
        $report .= "suiteVersions:\n";
        foreach my $suiteDir(@externalSuiteDirs){
            my @parts = split("/", $suiteDir); 
            my $version = $ENV{RUDI_IS_CONTAINER} ? "" : ":$workingSuiteVersions{$suiteDir}";
            $report .= $indent."$parts[$#parts]$version\n";
        }
    }
    $report .= "execute: $action\n";
    $report .= "thread: $thread\n";
    $report .= "nTasks: $nTasks{$action}\n";
    $report .= "$action:\n";
    
    # print the options
    my @taskOptions;
    assembleActionYaml($action, $cmd, $indent, \@taskOptions, \$report);
    
    # print the conda environment channels and dependencies
    $report .= $indent."conda:\n";
    my $suffix = $showMissingConda ? (-d $$cnd{dir} ? "" : "*** NOT PRESENT LOCALLY ***") : "";
    $report .= "$indent$indent"."prefix: $$cnd{dir} $suffix\n";
    foreach my $key(qw(channels dependencies)){
        ($conda{$key} and ref($conda{$key}) eq 'ARRAY' and @{$conda{$key}}) or next;
        $report .= "$indent$indent$key:\n";
        $report .= join("\n", map { "$indent$indent$indent- $_" } @{$conda{$key}})."\n";
    } 

    # finish up
    # $report .= "...\n"; # defer closure of yaml block to execute.pl, after container metadata
    {taskOptions => \@taskOptions, report => $report};
}
sub assembleActionYaml {
    my ($action, $cmd, $indent, $taskOptions, $report, $useFullFamilyNames) = @_;
    my %familySeen;
    foreach my $family(sort { getFamilyOrder($a) <=> getFamilyOrder($b) } getAllOptionFamilies($cmd)){
        $familySeen{$family} and next;
        $familySeen{$family}++;
        my $options = getFamilyOptions($family);   
        $useFullFamilyNames or ($family =~ m|//(.+)| and $family = $1);     
        %$options and $$report .= "$indent$family:\n";
        foreach my $longOption(sort { getOptionOrder($a, $options) <=> getOptionOrder($b, $options) }
                                     keys %$options){
            my $option = $$options{$longOption};
            my $values = $optionArrays{$longOption};
            if(!defined $values){ # used by valuesYaml
                my $value = applyVariablesToYamlValue($$option{default}[0]);
                !defined $value and $value = "__REQUIRED__";
                $$option{type}[0] eq 'string' and $value =~ m/,/ and $value = "\"$value\"";
                $$report .= "$indent$indent$longOption: $value\n";
            } elsif (@$values > 1) {
                $$option{hidden}[0] or $$report .= "$indent$indent$longOption:\n";
                foreach my $i(0..$#$values){
                    my $value = getReportOptionValue($option, $$values[$i]);
                    $$option{type}[0] eq 'string' and $value =~ m/,/ and $value = "\"$value\"";
                    $$option{hidden}[0] or $$report .= "$indent$indent$indent- $value\n";
                    $$taskOptions[$i]{$longOption} = $$values[$i];
                }
            } else {
                my $leftLength = length($longOption);
                my $nSpaces = 15 - $leftLength;
                my $spaces = (" ") x ($nSpaces > 1 ? $nSpaces : 1);
                my $value = getReportOptionValue($option, $$values[0]);
                $$option{type}[0] eq 'string' and $value =~ m/,/ and $value = "\"$value\"";
                $$option{hidden}[0] or $$report .= "$indent$indent$longOption:$spaces$value\n";
                foreach my $i(1..$nTasks{$action}){
                    $$taskOptions[$i-1]{$longOption} = $$values[0];
                }
            }
        }
    }
}
sub getReportOptionValue {
    my ($option, $value) = @_;
    if($$option{type}[0] eq "boolean"){
        $value ? 'true' : 'false';
    } elsif(!defined $value){
        "null";
    } else {
        $value;   
    }
}

1;
