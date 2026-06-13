use strict;
use warnings;

# helper functions to locate environment, module, or option files that are
# external to a pipeline suite, i.e., to be read from a different suite 
# (which must therefore also be installed into the working installation)
#   suite_dependencies can be set in _config.yml
#   external suite version requirements can be specified in pipeline.yml

# working variables
use vars qw($rudiDir $definitiveSuitesDir $developerSuitesDir);

# return the path to a requested shared component file
sub getSharedFile {
    my ($suiteSharedDir, $sharedTarget, $sharedType, $throwError) = @_;
    my $ymlTarget = $sharedTarget;
    $ymlTarget =~ m/\.yml$/ or $ymlTarget = "$sharedTarget.yml";

    # simple case, shared file is in the calling pipeline 
    my $sharedFile = "$suiteSharedDir/$ymlTarget"; # could be a file or a directory
    -e $sharedFile and return $sharedFile;

    # syntax for calling an external shared file: suite//path/to/file
    if($sharedTarget =~ m|//|){ 
        my ($suite, $target) = split('//', $ymlTarget);
        $sharedFile = getExternalSharedFile($suite, $target, $sharedType);
        $sharedFile and return $sharedFile;
    } 

    # file not found
    $throwError and throwSharedFileError($sharedTarget, $sharedType);
    undef;
}
sub getExternalSharedSuiteDir {
    my ($suite) = @_;
    if($ENV{DEVELOPER_MODE}){ # in developer mode, use forked repo if available, otherwise fall back to definitive
        my $developerSuiteDir = "$developerSuitesDir/$suite";
        -d $developerSuiteDir and return $developerSuiteDir;
    } 
    return "$definitiveSuitesDir/$suite";
}
sub getExternalSharedFile {
    my ($suite, $ymlTarget, $sharedType) = @_;
    my $suiteDir = getExternalSharedSuiteDir($suite); 
    -d $suiteDir or return;
    setExternalSuiteVersion($suiteDir, $suite);
    my $suiteSharedDir = "$suiteDir/shared/$sharedType"."s";
    my $sharedFile = "$suiteSharedDir/$ymlTarget";
    -e $sharedFile and return $sharedFile;
    undef;
}
sub throwSharedFileError {
    my ($sharedTarget, $sharedType) = @_;
    throwError("missing $sharedType target: ".$sharedTarget);
}

1;
