# Reading guide

This directory explains the platform. The READMEs next to the code are the
reference; these pages are the explanation that makes the reference
readable. Each page starts by saying who it is for and what you should be
able to do once you have read it, so you can skip what does not apply to
you.

## Suggested paths

**You have twenty minutes and want to know what this is.**
Read [why](01-why.md), then [the big picture](03-the-big-picture.md).
Afterwards you can explain the platform to someone else and draw it at
four levels of zoom.

**You are joining a team that ships here.**
[why](01-why.md), [building blocks](02-building-blocks.md) for the
vocabulary, [what we use](14-what-we-use.md) for the parts list, [the big picture](03-the-big-picture.md), then
[walkthroughs](06-walkthroughs.md) starting with "ship a change". Set up
your laptop with [local setup](12-local-setup.md). Read
[identity and access](07-identity-and-access.md) before the first time you
need a shell in a pod.

**You review changes for sec-ops or the platform team.**
[the big picture](03-the-big-picture.md), [guarantees](05-guarantees.md),
[edges](09-edges.md), [network and mesh](08-network-and-mesh.md),
[artifacts and promotion](10-artifacts-and-promotion.md),
[environments](11-environments.md).

**You are deciding whether this design is sound.**
[capabilities](04-capabilities.md) says what it covers and which security
practice each part implements. [guarantees](05-guarantees.md) turns that
into promises, each with the command that shows it holding on a running
cluster, so you can verify any claim instead of taking the page's word.

## All pages, in reading order

| Page | What it gives you |
| --- | --- |
| [01 Why](01-why.md) | The problem, the four ideas everything follows from, and what is a stand-in |
| [02 Building blocks](02-building-blocks.md) | Each technology in plain words: what it does, why it is here, what it means for you |
| [03 The big picture](03-the-big-picture.md) | Four levels of zoom, from the company to one change, with the build-up step by step |
| [04 Capabilities](04-capabilities.md) | What the platform covers, the security practice behind each part, and why that is a golden path |
| [05 Guarantees](05-guarantees.md) | Every promise, what enforces it, and the demo that proves it |
| [06 Walkthroughs](06-walkthroughs.md) | Common tasks told as stories with the commands, what you will see, and what refusal looks like |
| [07 Identity and access](07-identity-and-access.md) | Who you are to the cluster, what your group allows, and how to get more for an hour |
| [08 Network and mesh](08-network-and-mesh.md) | Why two systems, why port 15008, and how to read a drop |
| [09 Edges](09-edges.md) | The public door, the partner door, the egress door, and why sec-ops is a team |
| [10 Artifacts and promotion](10-artifacts-and-promotion.md) | What a push produces, why the cluster trusts it, and how a release moves between environments |
| [11 Environments](11-environments.md) | Units, base and envs, the roster, cluster variables, the sixteen checks, adding a cluster |
| [12 Local setup](12-local-setup.md) | Running it on a laptop, what each stage of `make up` does, running the demos |
| [13 Glossary](13-glossary.md) | The vocabulary, grouped by theme |
| [14 What we use](14-what-we-use.md) | Every component, its version, its job here, and the file that pins it |
