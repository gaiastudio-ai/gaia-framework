# UX Design Artifact (harvest fixture)

A UX design document that references stories by key in its content. The `designs`
harvester scans for node-key references and emits a `designs` edge from the UX
artifact to each referenced node.

## Screen: Primary harvest flow

This screen designs the interaction for E777-S2 (the primary node). The reference
above is what the `designs` harvester matches.

The near-miss key E777-S20 also appears here to exercise whole-token matching:
the primary-node harvest must not fold the near-miss reference into its edge set.
