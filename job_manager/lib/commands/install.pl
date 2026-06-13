#!/usr/bin/perl
use strict;
use warnings;

#========================================================================
# 'install.pl' re-runs the installation process to add new suites, etc.
#========================================================================

#========================================================================
# define variables
#------------------------------------------------------------------------
use vars qw(%options);
#========================================================================

#========================================================================
# main execution block
#------------------------------------------------------------------------
sub rudiInstall { 

    # honor the request for installing developer forks of repos
    $ENV{INSTALL_RUDI_FORKS} = $options{'forks'} ? "TRUE" : "";

    # ensure that 'install.sh' script is present
    my $installScriptName = "install.sh";
    my $installScriptPath = "$ENV{RUDI_DIR}/$installScriptName";
    my $installScriptUrl  = "https://raw.githubusercontent.com/RustyDataInt/rudi/main/$installScriptName";
    !-f $installScriptPath and system("cd $ENV{RUDI_DIR}; wget $installScriptUrl");

    # pass the call to 'install.sh' script from repo
    $ENV{N_CPU} = 1;
    exec "N_CPU=$ENV{N_CPU} bash $installScriptPath";
}
#========================================================================

1;
