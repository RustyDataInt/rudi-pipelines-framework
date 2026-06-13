---
title: Snakemake Style
parent: Workflow Styles
has_children: false
nav_order: 20
---

## {{ page.title }}

We are fond of 
[Snakemake](https://snakemake.readthedocs.io/en/stable/), 
a Python-based utility that uses target file rules
for workflow control, and many Snakefiles exist in the wild
for various data analysis tasks. It is easy
to combine the best of the MDI and Snakemake when creating and 
distributing pipelines.

If you choose to create your workflow with Snakemake, you probably won't
use the MDI step style, but a few support
mechanisms help you bring Snakefiles effectively into MDI pipelines.

### Snakemake Workflow.sh structure

A typical action script might look like this:

```bash
# Workflow.sh

# propagate an MDI "force" request to Snakemake
if [ "$SN_FORCEALL" != "" ]; then rm -rf $TASK_DIR/.snakemake; fi

# let Snakemake handle the workflow
snakemake $SN_DRY_RUN $SN_FORCEALL \
    --cores $N_CPU \
    --snakefile $ACTION_DIR/Snakefile \
    --directory $TASK_DIR \
    $DATA_NAME.targetFile.txt

# fail if Snakemake failed
checkPipe

# continue with other Snakefiles, etc.
```

A detailed description of the snakemake command line and
Snakefiles is beyond our scope - if you are
reading this you probably already know something about it.

_Workflow.sh_ can do many things in sequence. A pipeline
action step could chain multiple Snakefiles, etc., if that makes
more sense to your work than creating one all-encompassing Snakefile.

Please see the demo pipeline for a 
[working example of an Snakemake-style workflow script](https://github.com/RustyDataInt/demo-mdi-tools/blob/main/pipelines/demo/snakemake/Workflow.sh).

### Config file support for Snakemake-style pipelines

The MDI provides predefined conda and option families within the 
[mdi-suite-template](https://github.com/RustyDataInt/mdi-suite-template)
to make it easy to use Snakemake in your pipeline.

```yml
# pipeline.yml
actions:
    actionName:
        condaFamilies:
            - snakemake
        optionFamilies:
            - snakemake
```

The first entry loads Snakemake into the job environment, the second 
exposes two options to help users control Snakemake in your pipeline action.
Option names are prefixed with "sn-" for clarity.

- **--sn-dry-run** = sets snakemake option '--dry-run'
- **--sn-forceall**  = forces snakemake to re-execute its Snakefile rules
even if target files exist
