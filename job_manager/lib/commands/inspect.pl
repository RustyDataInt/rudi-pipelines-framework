#!/usr/bin/perl
use strict;
use warnings;

#========================================================================
# print the parsed values of all job options in YAML format
# thus:
#   inspect <data.yml> [args]
# is equivalent to iterating:
#   <pipeline> <data.yml> --dry-run [args]
# for each pipeline chunk of <data.yml>
#========================================================================

#========================================================================
# define variables
#------------------------------------------------------------------------
use vars qw($pipelineName $dataYmlFile @args);
#========================================================================

#========================================================================
# main execution block
#------------------------------------------------------------------------
sub qInspect { 
    my $developerFlag = $ENV{DEVELOPER_MODE} ? "-d" : "";
    my $args = join(" ", @args);
    system("$ENV{RUDI_DIR}/rudi $developerFlag $pipelineName $dataYmlFile --dry-run $args");
}
#========================================================================

1;
