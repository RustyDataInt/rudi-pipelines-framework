#!/usr/bin/perl
use strict;
use warnings;
use File::Copy;

#========================================================================
# create an alias, i.e., named shortcut, to the CLI program target
# can have multiple aliases to the same target, but only one alias of a given name
#========================================================================

#========================================================================
# define variables
#------------------------------------------------------------------------
use vars qw(%options);
#========================================================================

#========================================================================
# main execution block
#------------------------------------------------------------------------
sub rudiAlias { 

    # parse the options and apply defaults
    my $alias = $options{'alias'} || "rudi";
    my $bashrc = "~/.bashrc";
    my $profileFile = glob($options{'profile'} || $bashrc);
    my $aliasCommand = "alias $alias=\"$ENV{RUDI_DIR}/rudi\"";
    my $outLine = "$aliasCommand # written by RuDI alias\n";

    # since we can't modify the user's shell, show them the command they could execute
    if($options{'get'}){
        print "$aliasCommand\n";

    } else {

        # get user permission to modify their profile
        getPermissionGeneral(
            "The following line:\n".
            "    $outLine".  
            "will be written to file:\n".
            "    $profileFile\n"
        );

        # check the profile file path
        if($profileFile eq $bashrc and !-f $profileFile){
            open HANDLE, ">>$profileFile" or die "touch failed: $profileFile: $!\n";
            close HANDLE;
        } 
        -f $profileFile or throwError("file not found:\n    $profileFile", 'alias');

        # collect the contents of the current file as an array of lines
        my ($replaced, @profile);    
        open my $inH, "<", $profileFile or die "could not read file: $profileFile: $!\n";
        while (my $line = <$inH>){
            $line =~ m/\n/ or $line = "$line\n"; # guard against incomplete final line
            $line eq $outLine and exit; # nothing to do, exit quietly
            if($line =~ m/^alias\s+$alias=/){ 
                getPermissionGeneral(
                    "Alias '$alias' already exists and will be overwritten from:\n". 
                    "    $line".
                    "to:\n".
                    "    $outLine"
                );
                push @profile, $outLine; 
                $replaced = 1;
            } else {
                push @profile, $line;
            }
        }
        close $inH;
        $replaced or push @profile, $outLine;  

        # print the new file
        my $buFile = "$profileFile.rudiAliasBackup";
        -e $buFile or copy($profileFile, $buFile);
        open my $outH, ">", $profileFile or die "could not write file: $profileFile: $!\n";
        print $outH join("", @profile);
        close $outH;
    }
    exit;
}
#========================================================================

1;
