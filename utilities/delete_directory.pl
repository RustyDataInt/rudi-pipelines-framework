#!/usr/bin/perl
use strict;
use warnings;
use File::Copy;

# this utility script is written for use outside of a pipeline to improve the 
# experience of deleting a folder with many files in many nested directories
# it returns immediately while deleting a renamed directory in a forked background process

my ($directory, $startingLevel) = @ARGV;
!$directory and die "USAGE: perl delete_directory <DIRECTORY>\n";
-d $directory or die "not a directory:\n    $directory\n";
$directory =~ m/\/$/ and chop $directory;
!defined $startingLevel and $startingLevel = 4;
my $tmpDirectory = "DELETING_$directory";

unless($ENV{FORCE_DELETE_DIRECTORY}){
    print "\nDirectory:\n";
    print "    $directory\n";
    print "will be renamed to:\n";
    print "    $tmpDirectory\n";
    print "which will then be iteratively deleted of all contents,\n";
    print "and finally removed, all in the background.\n";
    print "\n!! Once started, you would have to kill the forked process to stop the deletion !!\n";
    print "\nDo you wish to continue? [y|N]\n";
    my $response = <STDIN>;
    uc($response) !~ /^Y/ and exit;
}

print "renaming directory...\n";
move($directory, $tmpDirectory);

print "forking to delete directory in the background...\n";
my $pid = fork;
if(!defined $pid){
   die "Failed to fork: $!";
} elsif ($pid == 0) {
    foreach my $n(reverse 1..$startingLevel){
        my $levelPath = join("/", ("*") x $n);
        system("ls -1d 2>/dev/null $tmpDirectory/$levelPath | xargs rm -rf 2>/dev/null {}"); # does not remove hidden files
    }
    system("rm -rf $tmpDirectory"); # remove directory and any remaining hidden files
} else {
   print "\nfork successful, directory is being deleted (PID = $pid)\n\n";
}
