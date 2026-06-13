# DECOY ground-truth (validator sidecar)

This file lives under memory/ and MUST NEVER be read or indexed by the reindex
sweep. If a brain-index entry ever references this path, the read-only boundary
is broken.
