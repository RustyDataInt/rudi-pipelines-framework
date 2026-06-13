---
title: Script Utilities
has_children: false
nav_order: 20
---

## {{page.title}}

All pipelines source shell scripts that expose functions
that can be useful in your action scripts. 
We only describe functions designed to be called by your pipeline actions.
See the following file for more information and for additional, mostly internal, functions:

- <https://github.com/RustyDataInt/mdi-pipelines-framework/blob/main/pipeline/workflow/workflow.sh>

## Support for MDI step-style workflows

The following function is the core of MDI step-style pipeline actions.

### runWorkflowStep

- **Usage**: runWorkflowStep $STEP_NUMBER $STEP_NAME $STEP_SCRIPT  
- **Action**: Execute a numbered pipeline step, with status checking to skip completed steps

## Check command success in a data stream

The following function is a very useful error trap for bash command streams, e.g.:

```
command1 | command2
checkPipe
```

### checkPipe

- **Usage**: checkPipe  
- **Action**: Check the exit status of every command in the prior bash command stream  
- **Result**: Dies if any handler had a non-zero exit status  

## Data integrity checks

The following functions aren't as commonly used but can help your pipeline
make sure it has appropriate data to work on.

### checkForData

- **Usage**: checkForData $COMMAND  
- **Action**: Ensure that a data stream will have at least one line of data  
- **Result**: Script exits quietly if stream is empty  

### waitForFile

- **Usage**: waitForFile $FILE [$TIME_OUT = 60]  
- **Action**: Wait for a file to appear on the file system  
- **Result**: Script dies if file does not appear within $TIME_OUT seconds  

### checkFileExists

- **Usage**: checkFileExists \<$FILE \| $GLOB\>  
- **Action**: Verify that $FILE, or the first file of $GLOB, exists and is not empty  
- **Result**: Script dies if file is empty or not found
