#!/usr/bin/perl
use strict;
use warnings;

#========================================================================
# build one container with all of a suite's pipelines and apps
#========================================================================

#========================================================================
# define variables
#------------------------------------------------------------------------
use vars qw($rootDir $jobManagerName %options);
#========================================================================

#========================================================================
# main execution block
#------------------------------------------------------------------------
sub rudiBuild { 
    # pass this call to launcher, it already has support for building and versioning
    my $developerFlag = $ENV{DEVELOPER_MODE} ? "-d" : "";
    $options{'container-type'} or $options{'container-type'} = "pipelines";
    $options{'version'} or $options{'version'} = "latest";
    $options{'sandbox'} = $options{'sandbox'} ? "--sandbox" : "";
    exec "$rootDir/$jobManagerName $developerFlag buildSuite $options{'suite'} $options{'container-type'} --version $options{'version'} $options{'sandbox'}";
}
#========================================================================

1;
