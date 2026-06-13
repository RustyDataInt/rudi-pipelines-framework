---
published: false
---

The 'job-manager' folder carries a library of scripts that help 
submit jobs to a cluster server's job scheduler, either Slurm, 
Sun Grid Engine or Torque PBS.

Script 'initialize.pl' creates the executable target, as
called by the 'rudi' CLI.
             
Folder 'lib/main' carries scripts that set up the job manager 
interface.

Folder 'lib/commands' carries scripts that act on individual 
job manager commands, e.g. submit, delete, etc.

Folder 'lib/utilities.sh' carries bash functions to support 
job manager scripts.
