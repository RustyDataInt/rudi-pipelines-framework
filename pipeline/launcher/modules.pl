use strict;
use warnings;

# subs for handling import of action modules into a pipeline's config

# working variables
use vars qw($rudiDir $modulesDir $pipelineSuite);

#------------------------------------------------------------------------------
# import a called action module
#   - imported action lines appear inline with pipeline.yml after module: key
#   - imported family lines appear at the end of the file
#------------------------------------------------------------------------------
sub addActionModule {
    my ($file, $line, $prevIndent, $parentIndentLen, $lines, $indents, $addenda) = @_;
    $line =~ m/\s*module:\s+(\S+)/ or throwError("malformed module call:\n    $file:\n    $line");
    my ($moduleFile) = getSharedFile($modulesDir, "$1/module.yml", 'module', 1);
    $moduleFile =~ m|suites/.+/(.+)/shared/modules| or throwError("malformed module file path:\n    $moduleFile:\n    $line");
    my $moduleSuite = $1;

    # discover the indent length of the module file (could be different than parent)
    open my $inH, "<", $moduleFile or throwError("could not open:\n    $moduleFile:\n$!");    
    my $moduleIndentLen;
    while (!$moduleIndentLen and my $line = <$inH>) {
        $line = trimYamlLine($line) or next; # ignore blank lines
        $line =~ m/^(\s*)/;
        my $indent = length($1);
        $indent > 0 and $moduleIndentLen = $indent;
    }
    close $inH;
    $moduleIndentLen or throwError("malformed module file, no indented lines:\n    $moduleFile");
    
    # read module.yml lines
    my ($inAction, $inActionFamilies);
    open $inH, "<", $moduleFile or throwError("could not open:\n    $moduleFile:\n$!");
    while (my $line = <$inH>) {
        
        # get this lines indentation
        $line = trimYamlLine($line) or next; # ignore blank lines
        $line =~ m/^(\s*)/;
        my $indent = length($1);
        $indent % $moduleIndentLen and throwError("inconsistent indenting in file:\n    $moduleFile");
        my $nIndent = $indent / $moduleIndentLen;    
    
        # determine which section we are in
        $line =~ s/^\s+//g;
        if($nIndent == 0){
            if($line =~ m/^version:/){ # ignore version key, used for internal tracking only
                $inAction = 0;
                next;  
            } elsif($line =~ m/^action:/){
                $inAction = 1;
                next; # don't need to process this line; parent sets the action name
            } else { # e.g., inline optionFamilies, condaFamilies definition sections
                $inAction = 0;
            }
        }
        if($nIndent == 1 and $inAction){
            if($line =~ m/^\S+Families:/){
                $inActionFamilies = 1;
            } else {
                $inActionFamilies = 0;
            }
        }

        # print action keys with revised indentation to match parent yml
        if ($inAction) {
            if($inActionFamilies and $line =~ m|^-| and $line !~ m|//|){
                $line =~ s|-\s+(\S+)|- $moduleSuite//$1|; # ensure that module families are interpreted relative to the module's suite
            } 
            my $revisedIndent = ($nIndent + 1) * $parentIndentLen; # +1 accounts for missing action name in module.yml
            push @$lines, $line;
            push @$indents, $revisedIndent;
            $$prevIndent = $revisedIndent;
            
        # store optionFamilies and condaFamilies for appending to end of parent yml file
        # can't do immediately, or we could disrupt the parent's actions list
        } else {
            push @$addenda, [$line, $nIndent * $parentIndentLen];
        }
    }
    close $inH;
}

1;
