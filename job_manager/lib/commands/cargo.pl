#!/usr/bin/perl
use strict;
use warnings;

#========================================================================
# 'cargo.pl' uses a container to run a Rust `cargo` command
#========================================================================
use vars qw(@pipelineOptions);

sub rudiCargo { 
    my $command = "cargo";

    my $singularityLoad = getSingularityLoadCommand();
    my $dixousContainer = getDioxusContainer($command, $singularityLoad);
    my $cargoHome       = getCargoHome($command);

    my $commandArgs = join(" ", @pipelineOptions);
    
    my $cargo = 
        "$singularityLoad; ".
        "singularity exec ".
          "--env CARGO_HOME=$cargoHome ".
          "--bind $cargoHome ".
          "--bind $ENV{RUDI_DIR} ".
          "$dixousContainer $command $commandArgs";
    # print STDERR "$cargo\n";
    exec($cargo);
} 

1;
