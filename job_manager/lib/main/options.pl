use strict;
use warnings;

# working variables
use vars qw($jobManagerName $command %commands @args
            %optionInfo %longOptions %commandOptions
            $isContainer %containerCommands);
our (@options, %options);

#========================================================================
# get and check requested commands and options
#-----------------------------------------------------------------------
sub checkCommand { # check for help request or validity of requested command
    my $jmName = $ENV{JOB_MANAGER_NAME_FULL} ? $ENV{JOB_MANAGER_NAME_FULL} : $jobManagerName;
    my $descriptionString = "$jmName is a utility for:\n".
                            "  - submitting, monitoring and managing data analysis pipelines\n".
                            "  - launching the web interface that runs all interactive apps";
    $command or reportUsage($descriptionString);    
    ($command eq '-h' or $command eq '--help') and reportUsage("$descriptionString", "all");
    # NB: direct calls to <pipeline> are handled by the upstream shell script
    $isContainer and !$containerCommands{$command} and throwError("command '$command' cannot be executed from a pipeline container", "all");
    $commands{$command} or throwError("'$command' is not a valid command or pipeline name", "all");
}
#-----------------------------------------------------------------------
sub setOptions { # parse and check validity of options string
    while (my $optionList = shift @args){
        ($optionList and $optionList =~ m/^\-/) or return ($optionList, @args);
        push @options, $optionList;    
        if($optionList =~ m/^\-\-(.+)/){ # long option formatted request
            my $longOption = $1;
            defined $optionInfo{$longOption} or
                throwError("'--$longOption' is not a recognized option for command '$command'"); 
            setOption($longOption);
        } elsif ($optionList =~ m/^\-(.+)/){ # short option formatted request
            foreach my $shortOption(split('', $1)){
                my $longOption = $longOptions{$shortOption};
                defined $longOption or
                    throwError("'-$shortOption' is not a recognized option for command '$command'"); 
                setOption($longOption);
            }
        } else {
            throwError("malformed option list"); 
        }
    }
    return ();
}           
sub setOption { # check and set option request                
    my ($longOption) = @_;
    $longOption eq 'help' and reportUsage(undef, $command); 
    defined ${$commandOptions{$command}}{$longOption} or
        throwError("'$longOption' is not a valid option for command '$command'", $command);
    my $value; # boolean options set to value 1, otherwise use supplied value
    if(${$optionInfo{$longOption}}[1]){
        $value = shift @args;
        push @options, $value;    
    } else {
        $value = 1;
    }
    (!defined $value or $value =~ m/\.yml$/) and throwError("missing value for option '$longOption'", $command);
    $value =~ m/^\-/ and throwError("missing value for option '$longOption'", $command);    
    $options{$longOption} = $value;  
}
sub checkRequiredOptions { # make sure required value options have been supplied
    foreach my $longOption (keys %{$commandOptions{$command}}){
        ${$commandOptions{$command}}{$longOption} or next; # option is not required
        defined $options{$longOption} or throwError("option '$longOption' is required for command '$command'", $command);
    }
}
#========================================================================

1;
