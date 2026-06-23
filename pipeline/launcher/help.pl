use strict;
use warnings;

# functions that provide executable help feedback on the command line

# working variables
use vars qw($config %optionValues $helpAction $helpCmd $isContainer %pipelineContainerCommands);
my $jmName = $ENV{JOB_MANAGER_NAME} ? $ENV{JOB_MANAGER_NAME} : 'rudi';
my $actionTabLength = 15;
my $optionTabLength = 20;
my $optionTabLengthWide = 25;
our $leftPad = (" ") x 2;
our $errorSeparator = "!" x 100;

#------------------------------------------------------------------------------
# show a listing of the actions available for a pipeline
#------------------------------------------------------------------------------
sub showActionsHelp {
    my ($error, $exit) = @_;
    $error and print "\n".$errorSeparator."\n$error\n".$errorSeparator."\n";    
    !$error and print "\n>>> Rusty Data Interface (RuDI): Pipelines <<<\n";
    my $pName = $leftPad."$jmName $$config{pipeline}{name}[0]";
    my $desc = getTemplateValue($$config{pipeline}{description});
    my $usage =
        "$$config{pipeline}{name}[0]: $desc\n\n".
        "usage:\n".
        "$pName <data.yml> [options]  # run all pipeline actions in data.yml\n".
        "$pName <action> <data.yml> [options] # run one action from data.yml\n".
        "$pName <action> <options>    # run one action, all options from command line\n".
        "$pName <action> --help       # pipeline action help\n".
        "$pName --help                # summarize pipeline actions\n";
    print "\n$usage\n";
    my $actions = $$config{actions};
    my $prevLevel = -1;
    foreach my $name(sort {
        ($$actions{$a}{universal}[0] || 0) <=> ($$actions{$b}{universal}[0] || 0) or
        $$actions{$a}{order}[0] <=> $$actions{$b}{order}[0]
    } keys %$actions){
        my $level = $$actions{$name}{universal}[0] || 0;
        if($level != $prevLevel){
            print $level ? "\ngeneral workflow commands:\n" : "pipeline specific actions:\n";
            $prevLevel = $level;
        }
        my $action = $$actions{$name};
        $$action{hidden}[0] and next;
        my $actionLength = length($name);
        my $spaces = (" ") x ($actionTabLength - $actionLength);
        my $desc = getTemplateValue($$action{description});
        if(!$isContainer or $level == 0 or $pipelineContainerCommands{$name}){
            print  "$leftPad"."$name$spaces$desc\n";
        }
    }
    print  "\n"; 
    $error and print $errorSeparator."\n$error\n".$errorSeparator."\n\n";   
    $exit and releaseRudiGitLock(1);
}

#------------------------------------------------------------------------------
# show a listing of the options available for a pipeline action
# the list can show either descriptions or the values currently in use
#------------------------------------------------------------------------------
sub showOptionsHelp {
    my ($error, $useValues, $suppressExit) = @_;
    my $parsedError = $error ? "\n".$errorSeparator."\n$error\n".$errorSeparator."\n" : "";
    $parsedError and print $parsedError;
    my $pName = $$config{pipeline}{name}[0];
    my $pDesc = getTemplateValue($$config{pipeline}{description});
    print "\n$pName: $pDesc\n\n";
    if ($helpAction) {
        my $cDesc = $$config{actions}{$helpAction}{description}[0];
        $cDesc =~ s/^"//;
        $cDesc =~ s/"$//;
        print "$helpAction: $cDesc\n\n";
    } 
    my %familySeen;
    foreach my $family(sort { getFamilyOrder($a) <=> getFamilyOrder($b) } getAllOptionFamilies($helpCmd)){
        $familySeen{$family} and next;
        $familySeen{$family}++;
        my $options = getFamilyOptions($family);
        scalar(keys %$options) or next;
        $family =~ m|.+//(.+)| and $family = $1;
        print "$family:\n";  
        # print "$family options:\n";       
        foreach my $longOption(sort { getOptionOrder($a, $options) <=> getOptionOrder($b, $options) }
                                     keys %$options){
            my $option = $$options{$longOption};
            $$option{hidden}[0] and next;
            my $shortOption = $$option{short}[0];
            $shortOption = $shortOption eq 'null' ? "" : "-$$option{short}[0],";
            my $left = "$shortOption--$longOption";
            my $leftLength = length($left);
            my $otl = $leftLength > $optionTabLength ? $optionTabLengthWide : $optionTabLength;
            my $nSpaces = $otl - $leftLength;
            my $spaces = (" ") x ($nSpaces > 0 ? $nSpaces : 0);
            if($useValues){
                my $value = $optionValues{$longOption};
                if($$option{type}[0] eq "boolean"){
                    $value = $value ? 'true' : 'false';
                } elsif(!defined $value){
                    $value = "null";
                }
                print "$leftPad"."$left$spaces$value\n";
            } else {
                my $type = $$option{type}[0] ? "<$$option{type}[0]> " : "";
                my $required = 
                    $$option{required}[0] ? 
                    "*REQUIRED*" : (
                        (defined $$option{default}[0] and 
                            $$option{type}[0] ne 'boolean' and 
                            $$option{default}[0] ne 'null') ? 
                        "[".unmaskInterploatedSymbols($$option{default}[0])."]" : 
                        ""
                    );
                my $desc = getTemplateValue($$option{description});
                my $right = " $type$desc $required";
                print  "$leftPad"."$left$spaces$right\n";
            }
        }
        $useValues or print "\n";
    }
    $parsedError and print "$parsedError\n";
    $suppressExit or releaseRudiGitLock(1);
}
sub getFamilyOrder {
    my ($family) = @_;
    my $x = $$config{optionFamilies}{$family};
    $x or return 0;     
    ($$x{order}[0] || 0) + ($$x{universal}[0] ? 1000 : 0);
}
sub getOptionOrder {
    my ($optionName, $options) = @_;
    my $option = $$options{$optionName};     
    $option or return 0;
    $$option{order}[0] || 0;
}

#------------------------------------------------------------------------------
# throw an error message and exit
#------------------------------------------------------------------------------
sub throwError {
    print "\n$errorSeparator\n$_[0]\n$errorSeparator\n\n";
    releaseRudiGitLock(1);
}
sub throwConfigError { # thrown when a configuration file is malformed
    my ($message, @keys) = @_;
    $message or $message = "";
    my $key = join(" : ", @keys);
    my $pattern =
"\nexpected/allowed patterns are:

pipeline: name
variables:
    VAR_NAME: value
shared:
    optionFamily:
        option: value
action:
    optionFamily:
        option: value
execute:
    - action";
    showOptionsHelp("malformed config file near '$key'\n".$message.$pattern);
}

1;
