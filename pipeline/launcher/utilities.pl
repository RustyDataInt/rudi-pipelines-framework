use strict;
use warnings;

# utility functions that support the launcher

# working variables
use vars qw(%longOptions %optionValues);

#------------------------------------------------------------------------------
# confirm dangerous actions
#------------------------------------------------------------------------------
sub getPermission {
    my ($message, $force) = @_;
    ($optionValues{force} or $force or $ENV{IS_PIPELINE_RUNNER}) and return 1;
    print "$message\n";
    print "Agree to continue? [y|N] ";
    my $response = <STDIN>;
    chomp $response;
    $response = (uc(substr($response, 0, 1)) eq "Y");
    $response or print "aborting with no action taken\n";
    return $response;
}

#------------------------------------------------------------------------------
# prompt user for input
#------------------------------------------------------------------------------
sub getUserInput {
    my ($message, $required) = @_;
    print "$message ";
    my $response = <STDIN>;
    chomp $response;
    unless(!$required or $response){
        print "aborting with no input\n";
        releaseRudiGitLock(1);
    }
    return $response;
}

#------------------------------------------------------------------------------
# string conversions
#------------------------------------------------------------------------------
sub getIntRam { # convert string to integer RAM
    my ($ramStr) = @_;
    my ($ram, $scale) = ($ramStr =~ m/^(\d+)(\w*)/);
    my %ramScales = (
        B => 1,
        K => 1e3,
        M => 1e6,
        G => 1e9
    );    
    $scale = $ramScales{uc($scale)};
    if($scale){
        $ram *= $scale
    } else {
        showOptionsHelp("malformed RAM specification: $ramStr");
    }
    return $ram;
}
sub getStrRam {
    my ($ramInt) = @_;
    if($ramInt < 1e3){ return $ramInt."B" }
    elsif($ramInt < 1e6){ return int($ramInt/1e3+0.5)."K" }
    elsif($ramInt < 1e9){ return int($ramInt/1e6+0.5)."M" }
    else{ return int($ramInt/1e9+0.5)."G" }
}

#------------------------------------------------------------------------------
# check if a variable value is a valid directory or file
#------------------------------------------------------------------------------
sub checkIsDirectory {
    my ($optionLong) = @_;
    $longOptions{$optionLong} or return;
    -d $optionValues{$optionLong} or showOptionsHelp("'$optionLong' is not a directory: $optionValues{$optionLong}"); 
}
sub checkIsFile {
    my ($optionLong, $fileName) = @_;
    $optionLong and ($longOptions{$optionLong} or return);
    $fileName or $fileName = $optionValues{$optionLong};
    -e $fileName or showOptionsHelp("file not found: $fileName"); 
}

#------------------------------------------------------------------------------
# read an entire file (e.g. a template file)
#------------------------------------------------------------------------------
sub slurpFile {  # read the entire contents of a disk file into memory
    my ($file) = @_;
    local $/ = undef; 
    open my $inH, "<", $file or throwError("could not open $file for reading: $!\n");
    my $contents = <$inH>; 
    close $inH;
    return $contents;
}

#------------------------------------------------------------------------------
# remove duplicate elements from an array while preserving order
#------------------------------------------------------------------------------
sub uniqueElements { 
    my %seen; 
    grep !$seen{$_}++, @_;
}

1;
