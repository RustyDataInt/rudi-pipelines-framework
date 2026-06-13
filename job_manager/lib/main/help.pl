use strict;
use warnings;

# working variables
use vars qw($jobManagerName %commands %commandOptions %optionInfo $isContainer %containerCommands);
my $jmName = $ENV{JOB_MANAGER_NAME} ? $ENV{JOB_MANAGER_NAME} : $jobManagerName;
my $commandTabLength = 12; 
my $optionTabLength = 20;
our $separatorLength = 100;
our $leftPad = (" ") x 2;
our $errorHighlight = "!" x 80;
our @optionGroups = qw(main submit status job rollback install alias build server);  # ensure that similar options group together
my %useOptionGroupDelimiter = (submit=>1, extend=>1, resubmit=>1);  # break long options lists into separate groups

#========================================================================
# provide help feedback on command line
#------------------------------------------------------------------------
sub throwError {
    my ($message, $command, $noRepeatError) = @_;
    reportUsage("$errorHighlight\n$message\n$errorHighlight", $command, 1, $noRepeatError);
}
sub reportUsage { # program help, always exits 
    my ($message, $command, $die, $noRepeatError) = @_;
    print "\n>>> Rusty Data Interface (RuDI) <<<\n";
    print $message ? "\n$message\n\n" : "\n";
    my $jmName = "$leftPad$jmName";
    print 
        "usage:\n".
        "$jmName <pipeline> <data.yml> [options]  # run all pipeline actions in data.yml\n".
        "$jmName <pipeline> <action> <data.yml> [options] # run one action from data.yml\n".
        "$jmName <pipeline> <action> <options>    # run one action, all options from command line\n".
        "$jmName <data.yml> <command> [options]   # apply manager command to one data.yml\n".        
        "$jmName <command> [options] <data.yml ...> [options] # apply manager command to data.yml(s)\n".
        "$jmName <command> [options]              # additional manager command shortcuts\n".
        "$jmName <pipeline> <action> --help       # pipeline action help\n".
        "$jmName <pipeline> --help                # summarize pipeline actions\n". 
        "$jmName <command> --help                 # manager command help\n".
        "$jmName --help                           # summarize manager commands\n";           
    if($command){
        $commands{$command} ? reportOptionHelp($command) : reportCommandsHelp();
    } else {
        reportCommandsHelp();
    }
    $die and !$noRepeatError and print $message ? "$message\n\n" : "\n";
    my $exitStatus = $die ? 1 : 0;
    exit $exitStatus; 
}
sub reportCommandsHelp { # help on the set of available commands, organized by topic
    print "\navailable commands:\n\n";
    reportCommandChunk("job submission",              qw(inspect mkdir submit extend));  
    reportCommandChunk("status and result reporting", qw(status start script report));  
    reportCommandChunk("interacting with jobs",       qw(ssh top ls));           
    reportCommandChunk("pipeline management",         qw(delete rollback purge));  
    reportCommandChunk("server management",           qw(initialize install alias add list clean unlock build server));  
}
sub reportOptionHelp { 
    my ($command) = @_;
    print "\n";
    print "$jmName $command: ${$commands{$command}}[1]\n";
    print "\n";
    print "available options:\n";
    my @availableOptions = sort {$a cmp $b} keys %{$commandOptions{$command}};
    if(@availableOptions){
        my %parsedOptions;
        foreach my $longOption(@availableOptions){
            my ($shortOption, $valueString, $optionGroup, $groupOrder, $optionHelp, $internalOption) = @{$optionInfo{$longOption}};
            $internalOption and next; # no help for internal options           
            my $option = "-$shortOption,--$longOption";
            $valueString and $option .= " $valueString";
            ${$commandOptions{$command}}{$longOption} and $optionHelp = "**REQUIRED** $optionHelp";
            my $nSpaces = $optionTabLength - length($option);
            $nSpaces < 1 and $nSpaces = 1;
            $parsedOptions{$optionGroup}{$groupOrder} = "$leftPad$option".(" " x ($nSpaces))."$optionHelp\n";
        }
        my $delimiter = "";
        foreach my $optionGroup(@optionGroups){
            $parsedOptions{$optionGroup} or next;
            $useOptionGroupDelimiter{$command} and print "$delimiter";              
            foreach my $groupOrder(sort {$a <=> $b} keys %{$parsedOptions{$optionGroup}}){
                print $parsedOptions{$optionGroup}{$groupOrder};   
            }         
            $delimiter = "\n";
        }
    } else {
        print $leftPad."none\n";
    }
    print "\n";
}
sub reportCommandChunk {
    my ($header, @commands) = @_;
    my $out = "";
    foreach my $command (@commands){
        (!$isContainer or $containerCommands{$command}) and 
            $out .= $leftPad.$leftPad.getCommandLine($command);
    }
    $out or return;
    print $leftPad."$header:\n";
    print "$out\n";
}
sub getCommandLine {
    my ($command) = @_;
    return $command.(" " x ($commandTabLength - length($command))).${$commands{$command}}[1]."\n";
}
#========================================================================

1;
