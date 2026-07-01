#!/usr/bin/perl
use strict;
use warnings;
use File::Basename qw(dirname basename);

#========================================================================
# 'serve.pl' launches the web server on a Linux server to use interactive apps
#========================================================================

#========================================================================
# define variables
#------------------------------------------------------------------------
use vars qw(%options);
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
    $options{'data-dir'} or $options{'data-dir'} = "";
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
    $options{'tool-suite'} or $options{'tool-suite'} = "";
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
    $options{'address'} or $options{'address'} = "127.0.0.1";
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
    my $serverCrateDir  = "$suiteDir/apps/shared/server";

    my $singularityLoad = getSingularityLoadCommand();
    my $dixousContainer = getDioxusContainer($command, $singularityLoad);
    my ($rudiTimestamp, $fastTmpDir, $localArchive, $fastTmpArchive, $fastTmpDirEnv, $fastTmpDirBind) 
        = getFastTmpDir($command, $suiteName, $suiteDir);
    my $cargoHome = getCargoHome($command, $fastTmpDir);
    my $cargoTargetDir = getCargoTargetDir($command, $fastTmpDir, $suiteName, $suiteDir);

    populateFastTmpDir(
        $command, $rudiTimestamp, 
        $fastTmpDir, $localArchive, $fastTmpArchive, 
        ($ENV{REMOTE_MODE} and $ENV{REMOTE_MODE} eq "node")
    );

    my $dx = getDxCommandPrefix(
        $singularityLoad, $serverCrateDir,
        $cargoHome, $cargoTargetDir,
        $fastTmpDirEnv, $fastTmpDirBind,
        $dixousContainer
    );
    my $dxServe = "$dx serve ".
        "--open false ".
        "--interactive false ".
        "--hot-reload true ".
        "--hot-patch ".
        "--watch true ".
        "--addr $options{'address'} ".
        "--port $options{'port'}";

    # wait for any tmp directory archive to finish
    # dx server killed by archive-$rudiTimestamp.sh
    # sleep killed by remote-monitor.sh
    exec("$dxServe; sleep 1000;");  
} 
#========================================================================

# Usage: dx serve [OPTIONS] [COMMAND]
# Commands:
#   @client  Specify the arguments for the client build
#   @server  Specify the arguments for the server build
# Options:
#       --port <PORT>
#           The port the server will run on
#       --addr <ADDR>
#           The address the server will run on
#       --open [<OPEN>]
#           Open the app in the default browser [default: true - unless cli settings are set]
#           [possible values: true, false]
#       --hot-reload <HOT_RELOAD>
#           Enable full hot reloading for the app [default: true - unless cli settings are set]
#           [possible values: true, false]
#   -i, --interactive [<INTERACTIVE>]
#           Run the server in interactive mode
#           [possible values: true, false]
#       --hot-patch
#           Enable Rust hot-patching instead of full rebuilds [default: false]
#           This is quite experimental and may lead to unexpected segfaults or crashes in development.
#       --watch [<WATCH>]
#           Watch the filesystem for changes and trigger a rebuild [default: true]
#           [possible values: true, false]
#       --fullstack [<FULLSTACK>]
#           Enable fullstack mode [default: false]
#           This is automatically detected from `dx serve` if the "fullstack" feature is enabled by default.
#           [possible values: true, false]
#       --force-sequential [<FORCE_SEQUENTIAL>]
#           This flag only applies to fullstack builds. By default fullstack builds will run the server and client builds in parallel. This flag will force the build to run the
#           server build first, then the client build. [default: false]
#           If CI is enabled, this will be set to true by default.
#           [possible values: true, false]
#       --device [<DEVICE>]
#           The name of the device we are hoping to upload to. By default, dx tries to upload to the active simulator. If the device name is passed, we will upload to that device
#           instead.
#           This performs a search among devices, and fuzzy matches might be found.
#       --args <ARGS>
#           Additional arguments to pass to the executable
#           [default: ""]
# Platform:
#       --platform <PLATFORM>
#           Manually set the platform (web, macos, windows, linux, ios, android, server, liveview)
#           [possible values: web, macos, windows, linux, ios, android, server, liveview, desktop]
#       --renderer <RENDERER>
#           Which renderer to use? By default, this is usually inferred from the platform
#           - webview:  Targeting webview renderer
#           - native:   Targeting native renderer
#           - server:   Targeting the server platform using Axum and Dioxus-Fullstack
#           - liveview: Targeting the static generation platform using SSR and Dioxus-Fullstack
#           - web:      Targeting the web-sys renderer
#       --bundle <BUNDLE>
#           The bundle format to target for the build: supports web, macos, windows, linux, ios, android, and server
#   -r, --release
#           Build in release mode [default: false]
#       --cargo-args <CARGO_ARGS>
#           Extra arguments passed to `cargo`
#           To see a list of args, run `cargo rustc --help`
#           This can include stuff like, "--locked", "--frozen", etc. Note that `dx` sets many of these args directly from other args in this command.
#       --rustc-args <RUSTC_ARGS>
#           Extra arguments passed to `rustc`. This can be used to customize the linker, or other flags.
#           For example, specifign `dx build --rustc-args "-Clink-arg=-Wl,-blah"` will pass "-Clink-arg=-Wl,-blah" to the underlying the `cargo rustc` command:
#           cargo rustc -- -Clink-arg=-Wl,-blah
#       --wasm-split
#           Experimental: Bundle split the wasm binary into multiple chunks based on `#[wasm_split]` annotations [default: false]
#       --session-cache-dir <SESSION_CACHE_DIR>
#           The folder where DX stores its temporary artifacts for things like hotpatching, build caches, window position, etc. This is meant to be stable within an invocation of
#           the CLI, but you can persist it by setting this flag

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
