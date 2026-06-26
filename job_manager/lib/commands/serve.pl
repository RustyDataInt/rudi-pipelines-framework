#!/usr/bin/perl
use strict;
use warnings;
use File::Path qw(make_path);
use File::Basename qw(dirname basename);

#========================================================================
# 'serve.pl' launches the web server on a Linux server to use interactive apps
#========================================================================

#========================================================================
# define variables
#------------------------------------------------------------------------
use vars qw(%options);
my $singularityLoad;
my $silently = "> /dev/null 2>&1";
my $command = 'serve';
my $IS_MULTI_SUITE  = "is-multi-suite";
my $IS_SINGLE_SUITE = "is-single-suite";
my $suiteMode = $IS_MULTI_SUITE;
my $suiteName = "";
my $suiteDir  = "";
#========================================================================

#========================================================================
# main execution block
#------------------------------------------------------------------------
sub rudiServe { 

    # remove trailing slash(es) on paths for consistent handling
    $ENV{RUDI_DIR} =~ m|(.+)/+$| and $ENV{RUDI_DIR} = $1;
    $options{'data-dir'} =~ s/^\s+|\s+$//g;
    $options{'data-dir'} and $options{'data-dir'} =~ m|(.+)/+$| and $options{'data-dir'} = $1; 

    # set the data directory
    $options{'data-dir'} eq "USE_DEFAULT" and $options{'data-dir'} = "";
    $ENV{RUDI_DATA_DIR} = $options{'data-dir'} || "$ENV{RUDI_DIR}/data";

    # respond to developer mode
    my $developerFlag = $ENV{DEVELOPER_MODE} ? "-d" : "";
    my $forksOption   = $ENV{DEVELOPER_MODE} ? "--forks" : "";

    # determine the installation type and default single suite
    my $suiteConfigFile = "$ENV{RUDI_DIR}/../_config.yml";
    $ENV{SUITE_MODE} = $suiteMode;
    $ENV{SUITE_NAME} = "";
    my $singleSuiteName = "";
    if(-f $suiteConfigFile){
        $ENV{SUITE_MODE} = $suiteMode = $IS_SINGLE_SUITE;
        $ENV{SUITE_NAME} = $suiteName = $singleSuiteName = basename(dirname($ENV{RUDI_DIR}));
        setSuiteDir($suiteName);
    }
    my $isSingleSuite = $suiteMode eq $IS_SINGLE_SUITE;

    # for multi-suite installations, require the user to specify a single tool suite
    $options{'tool-suite'} =~ s/^\s+|\s+$//g;
    if (!$isSingleSuite and (!$options{'tool-suite'} or $options{'tool-suite'} eq "USE_DEFAULT")){
        throwError("option --tool-suite is required for multi-suite installations", $command);
    }

    # process --tool-suite, if provided, to override the default single-suite installation
    if ($options{'tool-suite'} and $options{'tool-suite'} ne "USE_DEFAULT"){
        my ($owner, $repo) = split('/', $options{'tool-suite'});
        !$repo and $repo = $owner; # allow user to specify just the repo name, without owner
        $ENV{SUITE_NAME} = $suiteName = $repo;
        $suiteDir = "";
        setSuiteDir($suiteName);
    }

    # validate that a single tool suite was found to run the apps interface
    # or install it if not found and a multi-suite installation
    if (! -d $suiteDir){
        if ($isSingleSuite){
            throwError("tool suite '$suiteName' not found, expected a dependency of $singleSuiteName", $command); 
        } else { 
            system("$ENV{RUDI_DIR}/rudi $developerFlag add --suite $options{'tool-suite'} $forksOption");
            $suiteDir = "";
            setSuiteDir($suiteName);
            if (! -d $suiteDir){
                throwError("tool suite '$suiteName' not found after installation attempt from GitHub", $command); 
            }
        }
    }

    # launch the apps server, either in developer mode or standard mode
    $options{'port'} or $options{'port'} = 3839;
    $ENV{DEVELOPER_MODE} ? launchServerDev() : launchServer();
}
sub setSuiteDir {
    my ($suiteName) = @_;
    if ($ENV{DEVELOPER_MODE}){
        my $devSuiteDir = "$ENV{RUDI_DIR}/suites/developer-forks/$suiteName";
        -d $devSuiteDir and $suiteDir = $devSuiteDir;
    }
    if (!$suiteDir){
        $suiteDir = "$ENV{RUDI_DIR}/suites/definitive/$suiteName";
    }
}
#========================================================================

#========================================================================
# process different paths to launching the server
#------------------------------------------------------------------------

# launch directly on system
sub launchServer {
    # TODO: download suite bundle and launch directly on system
}

# launch via Singularity with suite-level container
sub launchServerDev {
    my ($suiteDir) = @_;
    $singularityLoad = getSingularityLoadCommand();
    my $serverDir = "$suiteDir/apps/shared/server";
    my $dioxusContainerDir = "$ENV{RUDI_DIR}/containers/dioxus";
    -d $dioxusContainerDir or make_path($dioxusContainerDir);
    $options{'dioxus-container'} or throwError("option '--dioxus-container' is required in developer mode", $command); 
    my $dixousContainer = "$dioxusContainerDir/$options{'dioxus-container'}.sif";
    if (! -f $dixousContainer){
        system(
            "$singularityLoad; ".
            "cd $dioxusContainerDir; ".
            "singularity pull docker://ghcr.io/rustydataint/rust-dioxus-dev-container:$options{'dioxus-container'}"
        ) and throwError("failed to pull Dioxus container image '$options{'dioxus-container'}'", $command);
    }
    exec(
        "$singularityLoad; ".
        "cd $serverDir; ".
        "PORT=$options{'port'} singularity exec $dixousContainer dx serve"
    );
} 
#========================================================================

#========================================================================
# discover Singularity on the system, if available
#------------------------------------------------------------------------
sub getSingularityLoadCommand {

    # first, see if singularity or apptainer command is already present and ready
    # NB: apptainer installations provide alias `singularity` to `apptainer`
    #     but commands report logs info as `apptainer`
    my $command = "echo $silently";
    checkForSingularity($command) and return $command; 
    
    # if not, attempt to use load-command from singularity.yml
    my $ymlFile = "$ENV{RUDI_DIR}/config/singularity.yml";
    if(-e $ymlFile){
        my $yamls = loadYamlFromString( slurpFile($ymlFile) );
        $command = $$yamls{parsed}[0]{'load-command'};
        if($command and $$command[0]){
            $command = "$$command[0] $silently";
            checkForSingularity($command) and return $command;
        }
    }

    # if not, attempt to use "module load singularity" as the default singularity load command
    $command = "module load singularity";
    checkForSingularity($command) and return $command;

    # no success
    undef;
}
sub checkForSingularity { # return TRUE if a proper singularity exists in system PATH after executing $command
    my ($command) = @_;
    system("$command; singularity --version $silently") and return; # command did not exist, system threw an error
    my $version = qx|$command; singularity --version|;
    $version =~ m/^(singularity|apptainer).+version.+/; # may fail if not a true singularity target (e.g., on greatlakes)
}
#========================================================================

# #========================================================================
# # get the requested/latest container version available
# #------------------------------------------------------------------------
# sub getTargetAppsImageFile {
#     my ($containerConfig) = @_;
#     my $majorMinorVersion = $options{'container-version'} || getSuiteLatestVersion();
#     $majorMinorVersion =~ m/^v/ or $majorMinorVersion = "v$majorMinorVersion"; # help user who type "0.0" instead of "v0.0"
#     my $imageGlob = lc("$suiteName/$suiteName-apps"); # container names always lower case
#     my $glob = "$ENV{RUDI_DIR}/containers/$imageGlob";
#     my $imageFile = "$glob-$majorMinorVersion.sif";
#     ! -f $imageFile and pullSuiteContainer($containerConfig, $imageFile, $majorMinorVersion);
#     return $imageFile;
# }
# sub getSuiteLatestVersion {
#     my $tags = qx\cd $suiteDir; git tag -l v*\; # tags that might be semantic version tags on main branch
#     chomp $tags;
#     my $error = "suite $suiteName does not have any semantic version tags to use to recover container images\n";
#     $tags or throwError($error, 'server');
#     my @versions;
#     foreach my $tag(split("\n", $tags)){
#         $tag =~ m/v(\d+)\.(\d+)\.\d+/ or next; # ignore non-semvar tags; note that developer must use v0.0.0 (not 0.0.0)
#         $versions[$1][$2]++;
#     }
#     @versions or throwError($error, 'server');
#     my $major = $#versions;
#     my $minor = $#{$versions[$major]};
#     "v$major.$minor";
# }

1;
