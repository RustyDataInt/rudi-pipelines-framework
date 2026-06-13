use strict;
use warnings;
use File::Path qw(make_path remove_tree);
use File::Basename;

# subs for building, posting and using a Singularity container image of a pipeline or suite

# https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry
# https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/creating-a-personal-access-token

use vars qw($rudiDir $launcherDir $config %workingSuiteVersions @args
            $pipelineSuite $pipelineName $pipelineDir $pipelineSuiteDir);
my $silently = "> /dev/null 2>&1";

#------------------------------------------------------------------------------
# top level subs for building containers
#------------------------------------------------------------------------------

# build a pipeline-level container
sub buildSingularity {
    my ($sandbox, $force) = @_;
    my $suiteVersion = $workingSuiteVersions{$pipelineSuiteDir};

    # check to see if suite supports suite-level containers with pipelines installed
    # if so, no point in building pipeline-level containers
    suiteSupportsContainers() and getSuiteContainerStage('pipelines') and throwError(
        "suite '$pipelineSuite' supports a suite-level container with installed pipelines\n".
        "pipeline-level containers are superfluous and unnecessary\n".
        "aborting container build"
    );

    # get permission to create and post the Singularity image
    pipelineSupportsContainers() or throwError(
        "nothing to build\n".
        "pipeline $pipelineName does not support containers\n".
        "add/edit section 'container:' in pipeline.yml to enable container support"
    );
    $ENV{FORCE_CONTAINER_BUILD} or getPermission(
        "\n'build' will create and post a Singularity container image for pipeline:\n".
        "    $pipelineSuite/$pipelineName:$suiteVersion"
    ) or releaseMdiGitLock(1); 
  
    # parse the pipeline version to build
    # container labels only use major and minor versions; patches must not change software dependencies
    # we do NOT use suite versions to label containers as suite versions might change even when this pipeline hasn't   
    my $pipelineVersion = getPipelineMajorMinorVersion();

    # assemble the complete container definition
    my $containerLevel = "pipeline";
    my $containerType = "pipelines";
    my $containerDef = assembleContainerDef($pipelineDir, $containerLevel, $containerType, {
        # TODO: NEEDS GIT_USER!
        SUITE_VERSION    => $suiteVersion,
        PIPELINE_NAME    => $pipelineName,
        PIPELINE_VERSION => $pipelineVersion
    });

    # build and push    
    buildAndPushContainer($containerType, $containerDef, $pipelineVersion, $sandbox, $force)
}

# build a suite-level container, for either pipelines or apps, but not both
sub buildSuiteContainer {
    my ($suite, $containerType, $sandbox) = @_;
    my ($gitUser, $repoName) = split('/', $suite);
    $repoName or throwError(
        "bad value for option '--suite', expected 'GIT_USER/SUITE_NAME'"
    );
    $pipelineSuite = $repoName;

    # parse and check the suite version
    # only allow latest and v0.0.0 so that a suite release can be checked out
    my $version = getRequestedSuiteVersion();
    $version or $version = "latest";
    $version =~ m/^\d+\.\d+\.\d+$/ and $version = "v$version"; # help user out if they specified 0.0.0 instead of v0.0.0
    $version eq "latest" or $version =~ m/v\d+\.\d+\.\d+/ or throwError(
        "bad value for '--version', expected 'latest' or form 'v0.0.0'"
    );

    # clone a fresh copy of the suite repository
    my $lcPipelineSuite = lc($pipelineSuite); # container names must be lower case for registry
    my $containerDir = "$ENV{RUDI_DIR}/containers/$lcPipelineSuite";
    make_path $containerDir;
    my $tmpDir = "$ENV{RUDI_DIR}/containers/tmp";
    mkdir $tmpDir;
    $pipelineSuiteDir = "$tmpDir/$pipelineSuite";  
    remove_tree $pipelineSuiteDir;
    system("cd $tmpDir; git clone https://github.com/$suite.git") and throwError(
        "git clone failed"
    );

    # set the suite version
    setPipelineSuiteVersion($version);
    my $status = qx\cd $pipelineSuiteDir; git status\;
    $status =~ m/detached/ or throwError( # always expect head to be detached at a suite version tag
        "bad value for '--version', expected 'latest' or form 'v0.0.0'\n".
        "alternatively, perhaps suite '$suite' does not have any version tags?"
    );
    my ($suiteVersion, $suiteMajorMinorVersion);
    $status =~ m/(v\d+\.\d+\.\d+)/ and $suiteVersion = $1;
    $suiteVersion =~ m/(v\d+\.\d+)\.\d+/ and $suiteMajorMinorVersion = $1;

    # parse the suite config and check whether it supports containers of the requested type
    $config = loadYamlFile("$pipelineSuiteDir/_config.yml");
    (suiteSupportsContainers($config) and getSuiteContainerStage($containerType, $config)) or throwError(
        "nothing to build\n".
        "suite '$suite' does not support $containerType containers\n".
        "add/edit section 'container:' in _config.yml to enable container support"
    );

    # get permission to create and post the Singularity image
    $ENV{FORCE_CONTAINER_BUILD} or getPermission(
        "\n'build' will create and post a Singularity $containerType container image for suite:\n".
        "    $suite:$suiteVersion"
    ) or exit;

    # assemble the complete container definition
    my $containerLevel = "suite";
    my $addStage1 = $containerType eq "pipelines" ? 1 : 0;
    my $addStage2 = $containerType eq "apps"      ? 1 : 0;
    my $containerDef = assembleContainerDef($pipelineSuiteDir, $containerLevel, $containerType, {
        GIT_USER                 => $gitUser,
        SUITE_VERSION            => $suiteVersion,
        SUITE_CONTAINER_VERSION  => $suiteMajorMinorVersion,
        CONTAINER_TYPE           => $containerType,
        R_VERSION                => $ENV{R_VERSION} ? $ENV{R_VERSION} : "latest",
        RUDI_FORCE_GIT           => "true", # flags for single-suite install.sh
        RUDI_INSTALL_PIPELINES   => $addStage1 ? "true" : "",
        RUDI_FORCE_APPS          => $addStage2 ? "true" : "",
        RUDI_SKIP_APPS           => $addStage2 ? ""     : "true",
        HAS_PIPELINES            => $addStage1 ? "true" : "false",
        HAS_APPS                 => $addStage2 ? "true" : "false"
    });

    # build and push  
    buildAndPushContainer($containerType, $containerDef, $suiteMajorMinorVersion, $sandbox, "", 1)
}

#------------------------------------------------------------------------------
# actions subs shared by buildSingularity and buildSuiteContainer
#------------------------------------------------------------------------------

# assemble a complete singularity definition file
sub assembleContainerDef {
    my ($rootDir, $containerLevel, $containerType, $replace) = @_;

    # concatenate the complete Singularity container definition file
    my $def = "";
    if($containerLevel eq 'suite'){
        if($containerType eq 'pipelines'){
            $def = ContainerDef("$rootDir/singularity.def").
                   ContainerDef("$launcherDir/lib/build-suite-common.def");
        } else { # apps containers don't need a suite-specific def file
            $def = ContainerDef("$launcherDir/lib/build-suite-apps.def");
        }
    } else { # pipeline level
        $def = ContainerDef("$rootDir/singularity.def").
               ContainerDef("$launcherDir/lib/build-common.def");
    }

    # replace placeholders with pipeline-specific values (Singularity does not offer def file variables)
    my %vars = (
        SUITE_NAME => $pipelineSuite,
        INSTALLER  => $$config{container}{installer} ? $$config{container}{installer}[0] : 'apt-get',
        N_CPU => qx/nproc --all/
    );
    foreach my $varName(keys %vars){
        my $placeholder = "__".$varName."__";
        $def =~ s/$placeholder/$vars{$varName}/g;
    }
    foreach my $varName(keys %$replace){ # level-specific replacement, i.e., suite or pipeline
        my $placeholder = "__".$varName."__";
        $def =~ s/$placeholder/$$replace{$varName}/g;
    }
    $def;
}

# build and push a pipeline-level or suite-level container
sub buildAndPushContainer {
    my ($containerType, $containerDef, $majorMinorVersion, $sandbox, $force, $isSuite) = @_;

    # set the output file and registry paths
    my $uris = getContainerUris($majorMinorVersion, $isSuite, $containerType);

    # learn how to use Singularity on the system
    my $singularityLoad = getSingularityLoadCommand(1);
    my $singularity = "$singularityLoad; singularity";

    # run singularity build
    if(-e $$uris{imageFile} and !$force and $isSuite){ # for buildSuiteContainer
        print "\nSingularity container image already exists:\n";
        print "    $$uris{imageFile}\n";
        print "Should the container image be rebuilt?\n";
        print "Type 'y' for 'yes' to rebuild the container: (y|n) ";
        my $response = <STDIN>;
        chomp $response;
        $force = (uc(substr($response, 0, 1)) eq "Y");
        $force and $force = "--force";
    }
    if(! -e $$uris{imageFile} or $force){
        print "\nbuilding Singularity container image:\n    $$uris{imageFile}\nfrom:\n    $$uris{defFile}\n\n";
        make_path($$uris{imageDir});
        open my $outH, ">", $$uris{defFile} or throwError($!);
        print $outH $containerDef;
        close $outH; # use --force (not $force) in build to always allow container labels to be re-written
        system("cd $ENV{RUDI_DIR}; $singularity build --fakeroot $sandbox --force $$uris{imageFile} $$uris{defFile}") and throwError(
            "container build failed"
        );        
    } elsif(!$isSuite) { # for buildSingularity, i.e., pipeline
        print "\nSingularity container image already exists:\n    $$uris{imageFile}\nuse option --force to re-build it\n";
    }

    # push container image to registry
    # do this regardless of whether we just built it or it already existed
    $sandbox and return();
    $ENV{IS_GITHUB_ACTION} and return();
    print "\npushing Singularity container image:\n    $$uris{imageFile}\nto:\n    $$uris{container}\n\n";
    my $isLoggedIn = qx/$singularity remote list | grep '^$$uris{registry}'/; # singularity remote status does not work unless add is used
    chomp $isLoggedIn;
    if(!$isLoggedIn){
        print "Please log in: $$uris{owner}\@$$uris{registry}:\n";
        system("$singularity remote login --username $$uris{owner} $$uris{registry}") and throwError(
            "registry login failed"
        );
    }      
    system("$singularity push $$uris{imageFile} $$uris{container}") and throwError(
        "container push failed"
    );
}

#------------------------------------------------------------------------------
# pull a previously built pipeline container during job execution in multi-suite mode
#------------------------------------------------------------------------------
sub pullPipelineContainer {
    my ($uris, $singularity, $isSuite, $containerType, $majorMinorVersion) = @_;

    # do nothing if image was previously downloaded
    $uris or $uris = getContainerUris($majorMinorVersion, $isSuite, $containerType);
    -f $$uris{imageFile} and return;

    # # get permission  
    # getPermission(
    #     "\n'$pipelineSuite $pipelineName' wishes to download its Singularity container image:\n".
    #     "    $$uris{imageFile}\n".
    #     "from:\n".
    #     "    $$uris{container}"
    # ) or releaseMdiGitLock(1);  

    # learn how to use singularity
    if(!$singularity){
        my $singularityLoad = getSingularityLoadCommand(1);
        $singularity = "$singularityLoad; singularity";
    }      

    # create the target directory
    make_path(dirname($$uris{imageFile}));

    # pull the image
    print "\npulling required container image...\n"; 
    system("$singularity pull --disable-cache $$uris{imageFile} $$uris{container}") and throwError(
        "container pull failed"
    );
    print "\n";
}

#------------------------------------------------------------------------------
# general container build and usage support functions
#------------------------------------------------------------------------------

# determine whether the pipeline or suite supports containers, i.e., if there is something for build to do
sub suiteSupportsContainers {
    my ($config) = @_;
    $config or $config = loadYamlFile("$pipelineSuiteDir/_config.yml");
    $$config{container} and 
    $$config{container}{supported} and 
    $$config{container}{supported}[0]
}
sub pipelineSupportsContainers {
    $$config{container} and 
    $$config{container}{supported} and 
    $$config{container}{supported}[0]
}

# get a flag whether a suite-level container supports pipelines or apps
# presumes that suiteSupportsContainers has already been checked
sub getSuiteContainerStage {
    my ($stage, $config) = @_;
    $config or $config = loadYamlFile("$pipelineSuiteDir/_config.yml");
    my $default = 0; 
    my $x = $$config{container} or return $default;
    $x = $$x{stages} or return $default;
    $x = $$x{$stage} or return $default;
    $$x[0];
} 

#  a container definition file
sub ContainerDef {
    my ($defFile) = @_;
    -e $defFile or throwError("missing container definition file:\n    $defFile");
    slurpFile($defFile);
}

# construct the URI to push/pull a pipeline container to/from a registry server
sub getContainerUris { # pipelineSupportsContainers(), i.e.,  $$config{container}{supported}, must already have been checked
    my ($majorMinorVersion, $isSuite, $containerType) = @_;
    $majorMinorVersion or $majorMinorVersion = getPipelineMajorMinorVersion();
    my $cfg = $$config{container};
    if (!$cfg){
        if($isSuite){
            my $config = loadYamlFile("$pipelineSuiteDir/_config.yml");
            $cfg = $$config{container};
        } else {
            throwError("unexpected call to getContainerUris\n");
        }
    }
    my $registry = $$cfg{registry} ? $$cfg{registry}[0] : 'ghcr.io'; # default to GitHub Container Registry
    my $owner = $$cfg{owner} ? $$cfg{owner}[0] : '';
    my $configFileName = $isSuite ? "_config.yml" : "pipeline.yml";
    $owner or throwError(
        "missing owner for container registry $registry\n".
        "expected tag 'container: owner' in $configFileName"
    );
    my ($imageDir, $fileName, $packageName);
    my $lcPipelineSuite = lc($pipelineSuite); # container names must be lower case for registry
    if($isSuite){
        $imageDir = "$ENV{RUDI_DIR}/containers/$lcPipelineSuite";
        $fileName    = $containerType eq 'apps' ? "$lcPipelineSuite-apps" : $lcPipelineSuite;
        $packageName = $fileName;
    } else {
        my $lcPipelineName  = lc($pipelineName);
        $imageDir = "$ENV{RUDI_DIR}/containers/$lcPipelineSuite/$lcPipelineName";
        $fileName = $lcPipelineName;
        $packageName = "$lcPipelineSuite/$lcPipelineName";
    }
    {
        registry  => "oras://$registry",
        owner     => $owner,
        container => lc("oras://$registry/$owner/$packageName:$majorMinorVersion"),
        imageDir  => $imageDir,
        defFile   => "$imageDir/$fileName-$majorMinorVersion.def",
        imageFile => "$imageDir/$fileName-$majorMinorVersion.sif"
    }
}

# make sure singularity is available on the system
sub getSingularityLoadCommand {
    my ($failIfMissing) = @_;

    # first, see if singularity or apptainer command is already present and ready
    # NB: apptainer installations provide alias `singularity` to `apptainer`
    #     but commands report logs info as `apptainer`
    my $command = "echo $silently";
    checkForSingularity($command) and return $command; 
    
    # if not, attempt to use load-command from singularity.yml
    my $ymlFile = "$rudiDir/config/singularity.yml";
    if(-e $ymlFile){
        my $yml = loadYamlFile($ymlFile);
        if($$yml{'load-command'} and $$yml{'load-command'}[0]){
            my $command = "$$yml{'load-command'}[0] $silently";
            checkForSingularity($command) and return $command; 
        }
    }

    # if not, attempt to use "module load singularity" as the default singularity load command
    $command = "module load singularity $silently";
    checkForSingularity($command) and return $command; 

    # singularity failed, throw and error
    $failIfMissing and throwError(
        "could not find a way to load singularity from PATH or config/singularity.yml"
    );
    "";
}
sub checkForSingularity { # return TRUE if a proper singularity exists in system PATH after executing $command
    my ($command) = @_;
    system("$command; singularity --version $silently") and return; # command did not exist, system threw an error
    my $version = qx|$command; singularity --version|;
    $version =~ m/^(singularity|apptainer).+version.+/; # may fail if not a true singularity target (e.g., on greatlakes)
}

1;
