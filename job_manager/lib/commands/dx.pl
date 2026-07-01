#!/usr/bin/perl
use strict;
use warnings;
use File::Basename qw(basename);

#========================================================================
# 'dx.pl' uses a container to run a Dioxus `dx` command
#========================================================================
use vars qw(@pipelineOptions);

sub rudiDx { 
    my $command = "dx";

    my $serverCrateDir = $ENV{PWD};
    $serverCrateDir =~ m/(.+)\/apps\/shared\/server$/ or 
        throwError("the `dx` command must run within apps/shared/server directory", $command);
    my $suiteDir  = $1;
    my $suiteName = basename($suiteDir);

    my $singularityLoad = getSingularityLoadCommand();
    my $dixousContainer = getDioxusContainer($command, $singularityLoad);
    my ($rudiTimestamp, $fastTmpDir, $localArchive, $fastTmpArchive, $fastTmpDirEnv, $fastTmpDirBind) 
        = getFastTmpDir($command, $suiteName, $suiteDir);
    my $cargoHome = getCargoHome($command, $fastTmpDir);
    my $cargoTargetDir = getCargoTargetDir($command, $fastTmpDir, $suiteName, $suiteDir);

    my $archiveScript = populateFastTmpDir(
        $command, $rudiTimestamp, 
        $fastTmpDir, $localArchive, $fastTmpArchive,
    );
    
    my $dx = getDxCommandPrefix(
        $singularityLoad, $serverCrateDir,
        $cargoHome, $cargoTargetDir,
        $fastTmpDirEnv, $fastTmpDirBind,
        $dixousContainer
    );
    my $commandArgs = join(" ", @pipelineOptions);
    # print STDERR "$dx $commandArgs\n";
    system("$dx $commandArgs");

    $archiveScript and system("sh $archiveScript");
}

1;
