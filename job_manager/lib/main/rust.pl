use strict;
use warnings;
use File::Path qw(make_path);

#========================================================================
# define variables
#------------------------------------------------------------------------
use vars qw(%options);
my $defaultDioxusVersion = "rust-1.92.0-dx-0.7.9";
my $defaultCargoHome = "$ENV{HOME}/.cargo";
my $separator = "-" x 80;
#========================================================================

#========================================================================
# check for the requested Dioxus developer container, download if missing
#------------------------------------------------------------------------
sub getDioxusContainer {
    my ($command, $singularityLoad) = @_;
    my $dioxusContainerDir = "$ENV{RUDI_DIR}/containers/dioxus";
    -d $dioxusContainerDir or make_path($dioxusContainerDir);
    $options{'dioxus-version'} or $options{'dioxus-version'} = $defaultDioxusVersion;
    my $dixousContainerName = "$options{'dioxus-version'}.sif";
    my $dixousContainer = "$dioxusContainerDir/$dixousContainerName";
    if (! -f $dixousContainer){
        system(
            "$singularityLoad; ".
            "cd $dioxusContainerDir; ".
            "singularity pull $dixousContainerName docker://ghcr.io/rustydataint/rust-dioxus-dev-container:$options{'dioxus-version'}"
        ) and throwError("failed to pull Dioxus container image '$options{'dioxus-version'}'", $command);
    }
    return $dixousContainer;
}
#========================================================================

#========================================================================
# resolve the path the requested Dioxus fast tmp directory
#------------------------------------------------------------------------
sub getFastTmpDir {
    my ($command, $suiteName, $suiteDir) = @_;
    my $fastTmpDir = $options{'fast-tmp-dir'};
    $fastTmpDir and $fastTmpDir eq "NULL" and $fastTmpDir = "";
    my ($rudiTimestamp, $localArchive, $fastTmpArchive);
    if ($fastTmpDir){
        -d $fastTmpDir or throwError("--fast-tmp-dir not found: $fastTmpDir", $command);
        $rudiTimestamp = $ENV{RUDI_TIMESTAMP} || time();
        $localArchive = "$fastTmpDir/$ENV{USER}/$suiteName.tar.zst";
        $fastTmpArchive = "$suiteDir/apps/target.$ENV{USER}.tar.zst";
        $fastTmpDir = "$fastTmpDir/$ENV{USER}/$suiteName";
        -d $fastTmpDir or make_path($fastTmpDir);
    }
    return (
        $rudiTimestamp,
        $fastTmpDir,
        $localArchive,
        $fastTmpArchive,
        $fastTmpDir ? "--env TMPDIR=$fastTmpDir " : "",
        $fastTmpDir ? "--bind $fastTmpDir " : "",
    );
}
#========================================================================

#========================================================================
# resolve the path to the user's requested working cargo home
#------------------------------------------------------------------------
sub getCargoHome {
    my ($command, $fastTmpDir) = @_;
    $fastTmpDir and return "$fastTmpDir/cargo_home";
    my $cargoHome = $options{'cargo-home'};
    $cargoHome and $cargoHome eq "USE_DEFAULT" and $cargoHome = "";
    $cargoHome or $cargoHome = $ENV{CARGO_HOME};
    $cargoHome or $cargoHome = $defaultCargoHome;
    if (! -d $cargoHome){
        if($cargoHome eq $defaultCargoHome){
            make_path($cargoHome);
        } else {
            throwError("--cargo-home directory does not exist: $cargoHome", $command);
        }
    }
    return $cargoHome;
}
#========================================================================

#========================================================================
# resolve the path to the user's requested working targetDir
#------------------------------------------------------------------------
sub getCargoTargetDir {
    my ($command, $fastTmpDir, $suiteName, $suiteDir) = @_;
    $fastTmpDir and return "$fastTmpDir/target";
    my $cargoTargetDir = "$suiteDir/apps/target";
    -d $cargoTargetDir or make_path($cargoTargetDir);    
    return $cargoTargetDir;
}
#========================================================================

#========================================================================
# transfer data between cargo home and target and the fast tmp directory
#------------------------------------------------------------------------
sub populateFastTmpDir {
    my (
        $command, $rudiTimestamp, 
        $fastTmpDir, $localArchive, $fastTmpArchive,
        $isNode # false/undef unless call is from dxServe and REMOTE_MODE=node
    ) = @_;
    
    $rudiTimestamp or return;
    my $archiveScriptName = "archive-$rudiTimestamp.sh";
    my $archiveScript = "$ENV{RUDI_DIR}/$archiveScriptName";
    open my $outH, ">", $archiveScript or throwError(
        "could not open $archiveScript for writing", $command
    );

    if (-f $fastTmpArchive){
        print STDERR "Restoring server fast tmp directory from archive...\n";
        if(system("tar --atime-preserve -p -I 'zstd -d -T0' -xf $fastTmpArchive -C $fastTmpDir")){
            system("rm -rf $fastTmpDir"); 
            throwError("FAILED while unpacking tmp directory archive", $command);
        } 
    } else {
        make_path("$fastTmpDir/cargo_home");
        make_path("$fastTmpDir/target");
    }

    print $outH "\nrm -f $archiveScript\n\n"; # the script auto-deletes
    $isNode and print $outH "ssh -T $ENV{HOSTNAME} << 'EOF'\n\n";
    if($command eq "serve"){
        print $outH "echo \"$separator\nKilling the Dioxus server process\"\n";
        print $outH "killall -9 -u $ENV{USER} dx 2>/dev/null\n";
        print $outH "sleep 1\n";
    }
    print $outH "echo \"$separator\nArchiving fast tmp directory to tool suite directory...\"\n";
    print $outH "tar --remove-files -I 'zstd -T0' --atime-preserve -p -cf $localArchive -C $fastTmpDir .\n";
    print $outH "mv -f $localArchive $fastTmpArchive\n";
    $isNode and print $outH "\nEOF\n";
    close $outH;

    return $archiveScript;
}
#========================================================================

#========================================================================
# assemble a dx command sequence prefix
#------------------------------------------------------------------------
sub getDxCommandPrefix {
    my (
        $singularityLoad, $serverCrateDir,
        $cargoHome, $cargoTargetDir,
        $fastTmpDirEnv, $fastTmpDirBind,
        $dixousContainer
    ) = @_;
    "$singularityLoad; ".
    "cd $serverCrateDir; ".
    "singularity exec ".
        "--env CARGO_HOME=$cargoHome ".
        "--env CARGO_TARGET_DIR=$cargoTargetDir ".
        $fastTmpDirEnv.
        "--bind $cargoHome ".
        "--bind $cargoTargetDir ".
        $fastTmpDirBind.
        "--bind $ENV{RUDI_DIR} ".
        "$dixousContainer dx"
}
#========================================================================

1;
