#!/usr/bin/perl
use strict;
use warnings;
use Cwd(qw(abs_path));
			
#========================================================================
# main execution block
#========================================================================
use vars qw($jobManagerDir $jobManagerName %commands @options 
            %pipelineLevelCommands $parsedYamls);
our ($command, @args) = @ARGV;
our ($isContainer, $dataYmlFile, $pipelineOptions, $pipelineName);
our %containerCommands = map { $_ => 1 } qw(
    inspect
    list
);
#------------------------------------------------------------------------
map { $_ !~ m/main.pl$/ and require $_ } glob("$jobManagerDir/lib/main/*.pl");
#------------------------------------------------------------------------
sub jobManagerMain {
    $isContainer = $ENV{RUDI_IS_CONTAINER} ? 1 : 0;

    # parse the various arguments provided on the job manager command line
    checkCommand();
    my $isAppCommand = $commands{$command}[2];
    @args or $isAppCommand or (reportOptionHelp($command) and exit);

    my @pipelineOptions = setOptions();
    checkRequiredOptions();    
    $isAppCommand and return executeCommand(); # shortcut to app execution
    my @dataYmlFiles; # our target file(s) that specific data jobs
    while (defined $pipelineOptions[0] and $pipelineOptions[0] =~ m/\.yml$/) {
        my $dataYmlFile = shift @pipelineOptions;
        push @dataYmlFiles, $dataYmlFile;
    }
    $pipelineOptions = join(" ", @pipelineOptions); # option values provided to override data.yml    
    
    # job manager requires a data.yml config file for job queuing (i.e., when not acting as a surrogate)
    @dataYmlFiles == 0 and throwError("'$jobManagerName $command' requires a <data.yml> configuration file");
    
    # if multiple config files, recall the job manager once for each file, with the same options
    if (@dataYmlFiles > 1){ 
        my $jobManagerOptions = join(" ", @options); # option values provided to guide job queuing
        foreach $dataYmlFile (@dataYmlFiles){
            my $perl = "perl $0 $command $jobManagerOptions $dataYmlFile $pipelineOptions";
            system($perl) and exit 1;  # abort if any run dies
        }
        exit;
    } 
    
    # finish a terminal call on a single file
    # for pipeline-level commands, execute the command once for every chained pipeline YAML chunk in data.yml
    ($dataYmlFile) = @dataYmlFiles;
    $parsedYamls = checkConfigFile();
    if($pipelineLevelCommands{$command}){
        foreach my $ymlChunk(@$parsedYamls){ 
            $$ymlChunk{pipeline} or next;
            $pipelineName = $$ymlChunk{pipeline}[0] or next; # [suiteName/]pipelineName[:suiteVersion]
            $pipelineName =~ m/(\S+):/ and $pipelineName = $1; # strip ':suiteVersion', only [suiteName/]pipelineName persists
            executeCommand();
        }

    # for job-file-level commands, only one execution is needed
    } else {
        executeCommand();
    }
}
#========================================================================

1;
