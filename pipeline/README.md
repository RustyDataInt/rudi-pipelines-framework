---
published: false
---

The 'pipeline' folder carries a library of scripts that help knit 
a series of worker scripts together into a single coherent pipeline 
that can be called and shared as an executable.

Launcher scripts are called by executables.
They parse pipeline definitions and user options,
load environment variables, and run pipeline scripts

Workflow scripts are called by running pipeline scripts
to support various common actions taken by pipelines.
