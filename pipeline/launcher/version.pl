use strict;
use warnings;
use Time::HiRes qw(usleep);

# subs for controlling the working version of pipeline suites
# through calls to git tag and git checkout

# working variables
use vars qw($target @args $config $jobConfigYml
            $pipelineDir $pipelineSuite $pipelineSuiteDir);
my $silently = "> /dev/null 2>&1"; # bash suffix to suppress git messages
my $main       = 'main';
my $latest     = "latest";
my $preRelease = "pre-release";
my %versionDirectives = ($preRelease => $main, $latest => ''); # key = option value, value = git tag/branch
our $pipelineSuiteVersions; # hash ref, filled by config.pl from pipeline.yml; can be undefined
our %workingSuiteVersions;  # the working version of all suites that have already been adjusted

# examine user options and set the primary pipeline suite version accordingly
sub setPipelineSuiteVersion { 
    my ($version) = @_;
    if($ENV{RUDI_IS_CONTAINER}){ # cannot change a read-only container version
        $version = $ENV{SUITE_VERSION};
    } else {
        $version or $version = getRequestedSuiteVersion();
        $version = convertSuiteVersion($pipelineSuiteDir, $version);
        setSuiteVersion($pipelineSuiteDir, $version, $pipelineSuite);
        $ENV{ACTIVE_SUITE_VERSION} = $version; # the suite version that will be loaded into a container's /srv/active/rudi
    }
    $ENV{SUITE_VERSION} = $version; # this version info will be overwritten by jobs running in a container
}

# parse and set the version for each newly encountered external suite that is invoked in pipeline.yml
sub setExternalSuiteVersion {
    my ($suiteDir, $suite) = @_;
    $workingSuiteVersions{$suiteDir} and return; # this suite was already handled on prior encounter
    $ENV{RUDI_IS_CONTAINER} and return; # cannot change a read-only container version
    my $version;
    if(!$pipelineSuiteVersions or !$$pipelineSuiteVersions{$suite}){
        $version = $latest; # apply the default directive when pipeline does not enforce external suite version
    } else {
        $version = $$pipelineSuiteVersions{$suite}[0];
    }
    $version = convertSuiteVersion($suiteDir, $version);
    setSuiteVersion($suiteDir, $version, $suite);
}

# examine user options for the requested pipeline suite version
sub getRequestedSuiteVersion {
    if($ENV{DEVELOPER_MODE} or $ENV{RUDI_IS_CONTAINER}){
        return getSuiteCurrentHead($pipelineSuiteDir); # developer mode and containers leave repos as we find them
    }
    my $version = getCommandLineVersionRequest();      # command line options take precedence
    $version or $version = getJobFileVersionRequest(); # otherwise, search data.yml for a version setting
    $version; # otherwise, will default to latest
}
sub getJobFileVersionRequest {
    my $ymlFile;
                  $target  and $target  =~ m/\.yml$/ and $ymlFile = $target;  # call format: pipeline <data.yml> ...
    !$ymlFile and $args[0] and $args[0] =~ m/\.yml$/ and $ymlFile = $args[0]; # call format: pipeline action <data.yml> ...
    $ymlFile or return;
    extractPipelineJobConfigYml($ymlFile);
    my $yaml = loadYamlFile(\$jobConfigYml, undef, undef, undef, 1);
    $$yaml{pipeline} or throwError("malformed data.yml: missing pipeline declaration\n    $ymlFile\n");
    $$yaml{pipeline}[0] =~ m/.+:(.+)/ or return; # format \[pipelineSuite/\]pipelineName\[:suiteVersion\]
    $1;
}

# change version requests to git tags or branches
# this sub always returns a value, never undefined
sub convertSuiteVersion {
    my ($suiteDir, $version) = @_;
    $version or $version = $latest; # apply the default directive when version is missing
    if($version eq $latest){
        $version = getSuiteLatestVersion($suiteDir);
    } elsif($versionDirectives{$version}) {
        $version = $versionDirectives{$version};
    } # else request is a branch or non-semvar tag name (so could be ~anything) 
    $version =~ m/^\d+\.\d+\.\d+$/ and $version = "v$version"; # help user out if they specified 0.0.0 instead of v0.0.0
    $workingSuiteVersions{$suiteDir} = $version;
    $version; 
}

# use git+perl to determine the most recent semantic version of a pipeline suite
# method is robust to vagaries of tagging, git versions, etc.
sub getSuiteLatestVersion {
    my ($suiteDir, $useDefinitive) = @_; 
    $useDefinitive and $suiteDir =~ s/developer-forks/definitive/; # only definitive repos have semantic version tags, developer-forks inherits from there when requested
    my $tags = qx\cd $suiteDir; git tag -l v*\; # tags that might be semantic version tags on main branch
    chomp $tags;
    $tags or return $main; # tags is empty string if suite has no semantic version tags -> use tip of main
    my @versions;
    foreach my $tag(split("\n", $tags)){
        $tag =~ m/v(\d+)\.(\d+)\.(\d+)/ or next; # ignore non-semvar tags; note that developer most use v0.0.0 (not 0.0.0)
        $versions[$1][$2][$3]++;
    }
    @versions or return $main; # there are tags on main, but none are semvar tags
    my $major = $#versions;
    my $minor = $#{$versions[$major]};
    my $patch = $#{$versions[$major][$minor]};
    "v$major.$minor.$patch";
}
sub getSuiteCurrentHead {
    my ($suiteDir) = @_; 
    my $head = qx\cd $suiteDir; git rev-parse --abbrev-ref HEAD\;
    chomp($head);
    $head;
}

# use git to check out the proper version of a pipelines suite
# will throw an error in a read-only pipeline container, but should never be called there
sub setSuiteVersion {
    my ($suiteDir, $version, $suite) = @_; # version might be a branch name or any valid tag
    my $gitCommand = "cd $suiteDir; git checkout $version"; # normally, we don't need to report git comments to user
    if(system("$gitCommand $silently")){
        print "\n";
        system($gitCommand); # repeat non-silently so user can see exactly what error git is reporting
        throwError(
            "unknown or unusable version directive for suite $suite: '$version'\n".
            "expected v#.#.#, a tag or branch, pre-release or latest (the default)"
        );        
    }
}

# get the version of a pipeline (not its suite) suitable for container tagging
sub getPipelineMajorMinorVersion {
    my $pipelineVersion = $$config{pipeline}{version};
    $pipelineVersion or throwError( # abort if no version found; it is required to build containers
        "missing pipeline version designation in configuration file:\n".
        "    $pipelineDir/pipeline.yml"
    );
    $$pipelineVersion[0] =~ m/v(\d+)\.(\d+)\.(\d+)/ or 
    $$pipelineVersion[0] =~ m/v(\d+)\.(\d+)/ or throwError(
        "malformed pipeline version designation in configuration file:\n".
        "    $$pipelineVersion[0]\n".
        "    $pipelineDir/pipeline.yml\n".
        "expected format: v0.0[.0]"
    );
    "v$1.$2"; 
}

1;
