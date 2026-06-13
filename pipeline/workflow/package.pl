use strict;
use warnings;
use File::Copy;
use File::Path qw(remove_tree);
use File::Basename;

# Called automatically by a running pipeline to assemble a data package, 
# if configured in pipeline.yml. The resulting zip file contains the 
# small(ish) output files of a pipeline for loading into an app.

# optionally, also push the data package to an external server

#---------------------------------------------------------------
# preparative work
#---------------------------------------------------------------
# initalize first environment variables
my $jobManagerDir  = $ENV{JOB_MANAGER_DIR};
my $pipelineDir    = $ENV{PIPELINE_DIR};
my $pipelineAction = $ENV{PIPELINE_ACTION};

# load the pipeline config, which might contain the instructions for this script
require "$jobManagerDir/lib/main/yaml.pl"; # supports loading multiple YAML from same file
my $pipeline = loadYamlFromString( slurpFile("$pipelineDir/pipeline.yml"), 1 );
my $config = $$pipeline{parsed}[0]{package};

# check for something to do
$config or exit; # pipeline or action does not export data to app
$config = $$config{$pipelineAction} or exit;

# initialize additional environment variables
my $pipelineName    = $ENV{PIPELINE_NAME};
my $taskLogFile     = $ENV{TASK_LOG_FILE};
my $taskPipelineDir = $ENV{TASK_PIPELINE_DIR};
my $dataName        = $ENV{DATA_NAME};
my $dataFilePrefix  = $ENV{DATA_FILE_PREFIX};
print "\nwriting data package for $pipelineName $pipelineAction\n";

# load the user option values currently in force
# other needed environment variables (e.g., those set in code) must be added to pipeline config
my $options = loadYamlFromString( slurpFile("$taskLogFile"), 1 );
my $jobConfig  = $$options{parsed}[0]; # job-level option values common to all tasks (first YAML block in task log)

#---------------------------------------------------------------
# concatenate any job log files for downstream use by apps (e.g., summary counts, etc.)
#---------------------------------------------------------------
my $packagePrefix = "$dataFilePrefix.$pipelineName.$pipelineAction.rudi.package";
!-d $packagePrefix and mkdir $packagePrefix;
my $concatenatedLogFileName = "$dataName.$pipelineName.concatenatedLogs";
my $concatenatedLogFile = "$packagePrefix/$concatenatedLogFileName";
my $logFileGlob = "$taskPipelineDir/*/logs/*.log.txt"; # all actions, all steps
system("cat $logFileGlob 2>/dev/null > $concatenatedLogFile");

#---------------------------------------------------------------
# assemble the output yaml that becomes the package manifest
#---------------------------------------------------------------
my $taskConfig = getTaskConfig($$options{parsed}[1]); # argument carries any task-level option values, e.g., a task data name
my (@files, $prevPackageFile, @previousFiles); # filled by getOutputFiles
my %contents = (
    uploadType  => [$$config{uploadType} ? $$config{uploadType}[0] : "$pipelineName-$pipelineAction"],
    pipeline    => [$pipelineName],
    action      => [$pipelineAction],
    task        => $taskConfig,
    files       => getOutputFiles(),
    entropy     => [randomString()] # ensure a unique MD5 hash for every package file
);

#---------------------------------------------------------------
# write config and assembly package zip
#---------------------------------------------------------------
my $packageFile = "$packagePrefix.zip";
unlink $packageFile;
print "$packageFile\n";
printYAML(\%contents, "$packagePrefix/package.yml");
foreach my $file(@files){
    copy($file, $packagePrefix);
}
foreach my $file(@previousFiles){
    my $outFile = "$packagePrefix/$file";
    -e $outFile and next; # current action files take precedence
    system("unzip -p $prevPackageFile $file > $outFile");
}
system("zip -jr $packagePrefix.zip $packagePrefix");
remove_tree($packagePrefix);
print "data package created successfully\n\n";

#---------------------------------------------------------------
# if requested, push data packages to an external server for use apps
#---------------------------------------------------------------
if($ENV{PUSH_SERVER} and $ENV{PUSH_SERVER} =~ m/\./ and $ENV{PUSH_DIR} and $ENV{PUSH_USER} and $ENV{PUSH_KEY}){
    my $packageFileName = basename($packageFile);
    my $pushPath = "$ENV{PUSH_SERVER}:$ENV{PUSH_DIR}/$packageFileName";
    my $localIP = qx/hostname -I | awk '{print \$1}'/;
    if($localIP =~ m/^10\./ or $localIP =~ m/^172\./ or $localIP =~ m/^192\./){
        print "skipping push because this server is on a private network\n";
        print "to push, re-run your job directly on a host with a fully qualified public IP address\n\n";
    } else {

        # push the data package itself
        print "attempting to push package file to\n$pushPath\n";
        print "    external server must allow ssh access to host IP $localIP";
        print "    you must run 'ssh -i $ENV{PUSH_KEY} $ENV{PUSH_USER}\@$ENV{PUSH_SERVER}' to accept the server fingerprint\n";
        my $scpCommand = "scp -i $ENV{PUSH_KEY} $packageFile $ENV{PUSH_USER}\@$pushPath";
        my $error = system($scpCommand) or print "push was successful\n\n";

        # push any requested additional (large) files that live outside the package
        if(!$error and $$config{extraPushFiles}){
            foreach my $file(@{$$config{extraPushFiles}}){ # file can be a file or directory
                $file = applyVariablesToYamlValue($file);
                my $fileName = basename($file);
                my $pushPath = "$ENV{PUSH_SERVER}:$ENV{PUSH_DIR}/$fileName";
                my $recursive = '';
                if(-d $file){ # directory
                    $recursive = '-r';
                    $fileName .= '/'; # ensure the directory is created on the server
                }
                my $scpCommand = "scp -i $ENV{PUSH_KEY} $recursive $file $ENV{PUSH_USER}\@$pushPath";
                print "pushing extra file/directory to server: $fileName\n";
                my $error = system($scpCommand) or print "push was successful\n\n";
                $error and last;
            }
        }
    }
}

#---------------------------------------------------------------
# fill any task-specific option values into a single task options hash
#---------------------------------------------------------------
sub getTaskConfig {
    my ($taskConfig) = @_;
    $taskConfig or return $jobConfig;
    my $cmd = $$jobConfig{$pipelineAction};
    foreach my $optionFamily(keys %$cmd){
        foreach my $option(keys %{$$cmd{$optionFamily}}){
            defined $$taskConfig{task}{$option} and # set task-specific option values by reference
                $$cmd{$optionFamily}{$option} = $$taskConfig{task}{$option};
        }
    }
    $jobConfig;
}

#---------------------------------------------------------------
# parse the automatic and pipeline-specific files to be packaged
#---------------------------------------------------------------
sub getOutputFiles {

    # collect the actual file paths for pipeline-specific files
    my $files = $$config{files};
    foreach my $fileType(keys %$files){
        $$files{$fileType}{file} = [
            parsePackageFile( 
                applyVariablesToYamlValue($$files{$fileType}{file}[0]), 
                $$files{$fileType}{maxSize}
            )
        ];
    }

    # add automatic files
    $$files{statusFile} = {
        type => ['status-file'],
        file => [ parsePackageFile("$taskPipelineDir/$dataName.$pipelineName.status") ] # to match workflow.sh
    };
    $$files{concatenatedLogFile} = {
        type => ['log-file'],
        file => [ $concatenatedLogFileName ] 
    };

    # add any files from earlier actions, if this a package extension
    if($$config{extends}){
        $prevPackageFile = "$dataFilePrefix.$pipelineName.$$config{extends}[0].rudi.package.zip";
        my $yml = qx/unzip -p $prevPackageFile package.yml/;
        my $prevPackage = loadYamlFromString( $yml, 1 );
        my $prevFiles = $$prevPackage{parsed}[0]{files};
        foreach my $fileType(keys %$prevFiles){
            $$files{$fileType} and next; # current action files take precedence
            push @previousFiles, $$prevFiles{$fileType}{file}[0];    
            $$files{$fileType} = $$prevFiles{$fileType};
        }
    }
    return $files;
}
sub parsePackageFile { # get the file name as recorded in package.yml
    my ($path, $maxSize) = @_;
    -f $path or return "null";
    if($maxSize){ # reject this file if it exceeds the requested maximum size
        $maxSize = uc(applyVariablesToYamlValue($$maxSize[0]));
        if($maxSize =~ m/(\d+)M/){
            $maxSize = $1 * 1024 * 1024;
        } elsif($maxSize =~ m/(\d+)G/){
            $maxSize = $1 * 1024 * 1024 * 1024;
        }
        my $fileSize = -s $path;
        $fileSize > $maxSize and return "null";
    }
    push @files, $path;
    $path =~ m|(.+)/(.+)|;
    $2;
}
sub applyVariablesToYamlValue {
    my ($value) = @_;
    my ($varName, $useType);
    if($value =~ m/\$(\w+)/){
        ($varName, $useType) = ($1, 'plain');
    } elsif($value =~ m/\$\{(\w+)\}/){
        ($varName, $useType) = ($1, 'braces');
    }
    $varName or return $value; # nothing more to do
    defined $ENV{$varName} or die("\nerror creating data package:\nno value found for environment variable '$varName'\n\n");        
    my $target;
    if ($useType eq 'braces') {
        $value =~ s/\{/__OPEN_BRACE__/g; # avoids regex confusion
        $value =~ s/\}/__CLOSED_BRACE__/g;
        $target = "\\\$__OPEN_BRACE__$varName\__CLOSED_BRACE__";  
    } else {
        $target = "\\\$$varName";  
    }
    $value =~ s/$target/$ENV{$varName}/g;   
    $value =~ s/__OPEN_BRACE__/\{/g; # enable multiple different variables per line
    $value =~ s/__CLOSED_BRACE__/\}/g;
    return applyVariablesToYamlValue($value);
}

#---------------------------------------------------------------
# print YAML hash to a bare bones .yml file
#---------------------------------------------------------------
sub printYAML {
    my ($yaml, $ymlFile) = @_;
    open our $outH, ">", $ymlFile or throwError("could not open for writing:\n    $ymlFile\n$!");
    sub printYAML_ {
        my ($x, $indentLevel) = @_;
        my $indent = " " x ($indentLevel * 4);
        if (ref($x) eq "HASH") {
            foreach my $key(sort keys %$x){
                print $outH "\n", $indent, "$key:"; # keys
                printYAML_($$x{$key}, $indentLevel + 1);
            }
        } elsif(@$x == 0){     
            print $outH " null";
        } elsif(@$x == 1){ # single keyed values
            my $value = $$x[0];
            defined $value or $value = "null";
            $value eq '' and $value = "null";
            print $outH " $value";
        } else { # arrayed values
            foreach my $value(@$x){ print $outH "\n$indent- $value" }
        }  
    }
    print $outH "---";
    printYAML_($yaml, 0); # recursively write the revised lines
    print $outH "\n\n";
    close $outH;
}

#---------------------------------------------------------------
# utilities
#---------------------------------------------------------------
# read the entire contents of a disk file into memory
sub slurpFile {  
    my ($file) = @_;
    local $/ = undef; 
    open my $inH, "<", $file or die "could not open $file for reading: $!\n";
    my $contents = <$inH>; 
    close $inH;
    return $contents;
}
# generate a random string to ensure variation in package file hash
sub randomString {
    lc(join("", map { sprintf q|%X|, rand(16) } 1 .. 20))
}

1;
