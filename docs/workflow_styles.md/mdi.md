---
title: MDI Step Style
parent: Workflow Styles
has_children: false
nav_order: 10
---

## {{ page.title }}

The MDI workflow style uses a sequence of code steps within a pipeline
action. Think:

- **pipeline >> action >> step**

The pipeline/action
hierarchy is well known to users. They typically know less about the
steps within an action, but steps can be important to developers.

MDI steps establish success points along an action's
execution. Step success is recorded in a status file in a task's output 
directory. If a job task is restarted,
any previously successful steps will be skipped.
Users - usually developers - can "rollback" the success state to an earlier step, 
if desired, to force some steps to be repeated.

Steps also provide an easy to read, compartmentalized log/report structure.

### MDI Workflow.sh structure

A typical action script might look like this:

```bash
# Workflow.sh

# extend to derived environment variables
export VAR_NAME=${INPUT_OPTION}...

# other preparative actions, as needed

# execute the first action step
# 'runWorkflowStep' is an MDI-provided bash function
runWorkflowStep 1 stepName stepScript.sh

# execute step 2, 3, etc.

# clean up
rm -r any/tmp/files
```

We often nest step scripts into subfolders of the action folder,
so you might find a tree like:

```
pipelineName/actionName/stepName
|---stepScript.sh
|---supportingFile.txt
|---supportingScript.R (or py, or ....)
```

which would be called as:

```
runWorkflowStep 1 stepName stepName/stepScript.sh
```

Please see the demo pipeline for a 
[working example of an MDI-style workflow script](https://github.com/RustyDataInt/demo-mdi-tools/blob/main/pipelines/demo/do/Workflow.sh).

### Logic for breaking actions into steps

There are many logics by which you might break an action into steps:

- a desire to keep an interim file that was slow to create
- a desire to organize and modularize the log/report structure
- an inherently modular structure to the code called by each step
- steps use different modes of parallelization
- it helped you build a pipeline in an incremental fashion

### Commands and options relevant to actions steps

Less commonly used mechanisms of the mdi command line utility that deal with actions steps are:
- **Command**: mdi pipelineName status (not commonly used)
- **Command**: mdi pipelineName rollback (not commonly used)
- **Option**: --rollback \<int\> (helpful mainly for developers)

Do not confuse mechanisms that manipulate
a job submission sequence (e.g., `mdi rollback` ...) with mechanisms
that manipulate an action step sequence (e.g., `mdi pipelineName rollback`).
The former apply to a _data.yml_ file, the latter to a pipeline action.
