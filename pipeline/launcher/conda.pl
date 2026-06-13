use strict;
use warnings;
use Digest::MD5 qw(md5 md5_hex md5_base64);
use File::Path qw(remove_tree make_path);
use File::Copy;

# subs for loading available environment families
# for speed and efficiency, use micromamba to create conda environments

use vars qw(@args $environmentsDir $config %conda %optionArrays);

#------------------------------------------------------------------------------
# set the program dependencies list for a pipeline action from its config
#------------------------------------------------------------------------------
sub parseAllDependencies {
    my ($subjectAction) = @_;
    
    # determine if action has program dependencies
    %conda = (channels => [], dependencies => []);
    my $cmd = getCmdHash($subjectAction) or return;
    $$cmd{condaFamilies} or return;
    $$cmd{condaFamilies}[0] or return;
    
    # collect the environment family dependencies, in precedence order
    my %found;
    foreach my $family(@{$$cmd{condaFamilies}}){
        $found{$family} = loadSharedEnvironments($family);
    }
    foreach my $family(@{$$cmd{condaFamilies}}){ # thus, pipeline.yml overrides shared environment files, since reversed below        
        $found{$family} = loadPipelineEnvironments($family) || $found{$family};
    }
    foreach my $family(@{$$cmd{condaFamilies}}){
        $found{$family} or throwError("pipeline configuration error\ncould not find conda family:\n    $family");
    }

    # purge duplicate entries by dependency (not version)
    foreach my $key(qw(channels dependencies)){
        my %seen;
        my @out;
        foreach my $value(reverse(@{$conda{$key}})){ # thus, pipeline.yml overrides a shared environment file
            my ($item, $version) = split('=', $value, 2);
            $seen{$item} and next;
            $seen{$item}++;
            unshift @out, $value;  
        }
        @{$conda{$key}} = @out;
    }
}
sub loadSharedEnvironments { # first load environment configs from shared files
    my ($family) = @_;
    my $file = getSharedFile($environmentsDir, "$family.yml", 'environment'); # either shared or external
    ($file and -e $file) or return;
    addEnvironmentFamily(loadYamlFile($file));
}
sub loadPipelineEnvironments { # then load environment configs from pipeline config (overrides shared)
    my ($family) = @_;
    $$config{condaFamilies} or return;
    $family =~ m|//(.+)| and $family = $1;
    addEnvironmentFamily($$config{condaFamilies}{$family});
}
sub addEnvironmentFamily {
    my ($yml) = @_;
    $yml or return;
    my (@deps, $inPipSection);
    foreach my $dep(@{$$yml{dependencies}}){ # support installation from pip
        $dep eq "pip:" and $inPipSection = 1 and next; # pip section must come last in any given dependencies list
        push @deps, $inPipSection ? "pip:$dep" : $dep; # pip: prefix to record depenency, reparsed by getEnvironmentYml
    }
    $$yml{channels}     and push @{$conda{channels}},     @{$$yml{channels}};
    $$yml{dependencies} and push @{$conda{dependencies}}, @deps;  
    return 1;
}

#------------------------------------------------------------------------------
# get the path to an environment directory, based on either:
#    - an environment name forced by config key 'action:<action>:environment'
#    - an identifying hash for a standardized, sharable environment (not pipeline specific)
#    - a name provided by the caller
#------------------------------------------------------------------------------
sub getEnvironmentPaths {
    my ($configYml, $subjectAction, $envName, $envType) = @_;
    
    # check the path where environments are installed
    my $baseDir = "$ENV{RUDI_DIR}/environments";
    -d $baseDir or throwError("environments directory does not exist:\n    $baseDir");
    
    # establish the proper name for the environment if not provided by caller
    if(!$envType){
        my $cmd = getCmdHash($subjectAction);
        ($envName, $envType) = ($$cmd{environment});
        if($envName and ref($envName) eq 'ARRAY'){
            # a name forced by pipeline.yml, especially useful during pipeline developement
            $envName = $$envName[0];
            $envType = "named";
        } else {
            # assemble an MD5 hash for a standardized, sharable environment
            my @digest;
            push @digest, ('channels:', @{$conda{channels}}); # channel order is important, do not reorder
            push @digest, ('dependencies:', sort @{$conda{dependencies}});
            my $digest = md5_hex(join(" ", @digest));
            $envName = substr($digest, 0, 10); # shorten it for a bit nicer display
            $envType = "sharable";
        }
    }

    # set environment paths
    my $envDir   = "$baseDir/$envName";
    my $initFile = "$baseDir/$envName.yml"; # used to create the environment
    my $showFile = "$envDir/$envName.yml";  # permanent store to show what was created
    
    # set micromamba paths
    my $binDir = "$ENV{RUDI_DIR}/bin";
    my $mmbDir = "$binDir/micromamba";
    my $micromamba = "$mmbDir/micromamba";

    # if missing, install micromamba as a drop-in replacement for conda
    ! -d $mmbDir and make_path($mmbDir);
    ! -f $micromamba and system( # TODO: add support for mac-os?
        "wget -qO- https://micro.mamba.pm/api/micromamba/linux-64/latest | ".
        "tar -xj -C $mmbDir --strip-components=1 bin/micromamba"
    ) and throwError("micromamba download failed");

    # return all paths and commands needed to manage environments
    {
        baseDir     => $baseDir,
        dir         => $envDir,
        initFile    => $initFile,
        showFile    => $showFile,
        name        => $envName,
        type        => $envType,
        mmbDir      => $mmbDir,
        micromamba  => $micromamba,
        shell_hook  => "eval \"\$($micromamba shell hook --shell bash)\""
    }
}

#------------------------------------------------------------------------------
# if missing, create environment(s)
# if present but named and out-of-date, update 
#------------------------------------------------------------------------------
sub showCreateEnvironments {
    my ($create, $force) = @_;
    my $cmds = $$config{actions}; 
    my @orderedActions = sort { $$cmds{$a}{order}[0] <=> $$cmds{$b}{order}[0] } keys %$cmds;
    my @argsBuffer = @args;
    foreach my $subjectAction(@orderedActions){
        $$cmds{$subjectAction}{universal}[0] and next;
        my $cmd = getCmdHash($subjectAction);
        loadActionOptions($cmd);
        my $configYml = assembleCompositeConfig($cmd, $subjectAction);
        setOptionsFromConfigComposite($configYml, $subjectAction);
        parseAllDependencies($subjectAction);
        my $cnd = getEnvironmentPaths($configYml, $subjectAction);
        print "---------------------------------\n";
        print "environment for: $$config{pipeline}{name}[0] $subjectAction\n";
        print "$$cnd{dir}\n";
        if ($create) {
            createEnvironment($cnd, 1, $force);
        } else {
            if($$cnd{type} eq 'named'){ # name forced by developer
                my $env = checkNamedEnvironment($cnd);
                if($$env{exists}){
                    print "$$cnd{showFile}\n";
                    if($$env{is_current}){
                        print "environment exists and is up to date\n";
                        print $$env{expected};
                    } else {
                        print "environment exists but is out of date\n";
                        print "---\ncurrent contents\n";
                        print $$env{current};
                        print "---\nexpected contents\n";
                        print $$env{expected};
                    }
                } else {
                    print "not created yet\n";
                }
            } else { # automated name suitable for generalized environment sharing
                if (-e $$cnd{showFile}) {
                    print "$$cnd{showFile}\n";
                    print slurpFile($$cnd{showFile});
                } else {
                    print "not created yet\n";
                }              
            }
        }
        print "---------------------------------\n";
        @args = @argsBuffer; # ensure that assembleCompositeConfig runs properly each time
    }
}
sub createEnvironment { # handles both create and update actions
    my ($cnd, $showExists, $force) = @_;

    # determine how to handle this call based on environment type
    my ($envAction, $outYml);
    if($$cnd{type} eq 'named'){ # name forced by developer
        my $env = checkNamedEnvironment($cnd);
        if($$env{exists}){
            if($$env{is_current}){
                $showExists and print "environment exists and is up to date\n";
                return;  
            }
            $envAction = 'update --prune';
        } else {
            $envAction = 'create';
        }
        $outYml = $$env{expected};
    } else { # automated name suitable for generalized environment sharing
        if(-d $$cnd{dir}){
            $showExists and print "environment already exists\n";
            return; # hashed name demands that the environment has all depedencies
        }
        $envAction = 'create';
    }

    # get permission to create/update the environment   
    my $isCreate = $envAction eq 'create';
    my $msg = $isCreate ? 
        "Missing environment, it will be created." : 
        "Environment exists, it will be updated.";
    getPermission($msg, $force) or throwError("Cannot proceed without the proper conda environment.");

    # write the required environment.yml file; moved into environment directory on successful create/update
    $outYml or $outYml = getEnvironmentYml();
    open my $outH, ">", $$cnd{initFile} or throwError("could not open:\n    $$cnd{initFile}\n$!");
    print $outH $outYml;
    close $outH;

    # execute the environment action
    my $bash = "bash -c '
$$cnd{shell_hook}
$$cnd{micromamba} env $envAction --prefix $$cnd{dir} --file $$cnd{initFile} --yes
'";
    print "executing command sequence: $bash\n";
    if(system($bash)){
        $isCreate and remove_tree $$cnd{dir};
        unlink $$cnd{initFile}; 
        throwError("environment create/update failed");
    }

    # move the environment.yml file into the environment directory 
    move($$cnd{initFile}, $$cnd{showFile});
}

#------------------------------------------------------------------------------
# determine if a named environment matches the current pipeline specifications
#------------------------------------------------------------------------------
sub checkNamedEnvironment {
    my ($cnd) = @_;
    my $expected = getEnvironmentYml();
    -d $$cnd{dir} or return { 
        exists   => 0,
        expected => $expected
    };
    my $current = slurpFile( $$cnd{showFile} );
    {
        exists      => 1,
        expected    => $expected,
        current     => $current,
        is_current  => $current eq $expected
    }
}
sub getEnvironmentYml {
    my $indent = "    ";
    my $yml = "---\n"; # do NOT put name or prefix in file (should work, but doesn't)
    foreach my $key(qw(channels dependencies)){
        ($conda{$key} and ref($conda{$key}) eq 'ARRAY' and @{$conda{$key}}) or next;
        $yml .= "$key:\n";
        if($key eq "channels"){
            $yml .= join("\n", map { "$indent- $_" } @{$conda{$key}})."\n";
        } else {
            my %deps = (conda => [], pip => []);
            foreach my $dep(@{$conda{$key}}){
                if($dep =~ m/pip:(.+)/){
                    push @{$deps{pip}}, $1;
                } else {
                    push @{$deps{conda}}, $dep;
                }
            }
            if(@{$deps{conda}}){
                $yml .= join("\n", map { "$indent- $_" } @{$deps{conda}})."\n";
            }
            if(@{$deps{pip}}){
                $yml .= "$indent- pip:\n";
                $yml .= join("\n", map { "$indent$indent- $_" } @{$deps{pip}})."\n";
            }
        }  
    }
    $yml
}

1;
