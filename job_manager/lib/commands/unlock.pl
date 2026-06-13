#!/usr/bin/perl
use strict;
use warnings;

#========================================================================
# remove all framework and suite repository locks, to reset after error
#========================================================================

#========================================================================
# main execution block
#------------------------------------------------------------------------
sub rudiUnlock { 
    getPermissionGeneral(
        "Remove all locks on framework and suite repositories?\n".
        "Only use this action if you need to recover from a prior command error."
    );
    system("rm -f $ENV{RUDI_DIR}/frameworks/*.lock");
    system("rm -f $ENV{RUDI_DIR}/suites/*.lock");
    print "done - all repos are unlocked\n";
    exit;
}
#========================================================================

1;
